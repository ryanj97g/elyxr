//! The shared application state every handler is given.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::Instant;

use serde::Serialize;

use crate::auth::{self, Identity};
use crate::config::{Config, Role, TokenCfg};
use crate::devices::{DeviceRecord, DeviceStore};
use crate::error::ApiError;
use crate::events::EventBus;
use crate::limits::Usage;
use crate::pairing::PairingState;
use crate::trove::Trove;
use crate::upload::UploadManager;

/// One recorded failure, for server mode's "recent problems" (§09).
#[derive(Debug, Clone, Serialize)]
pub struct ProblemLine {
    pub ts: i64,
    pub method: String,
    pub path: String,
    pub status: u16,
    pub code: Option<String>,
    pub message: Option<String>,
    pub request_id: Option<String>,
}

pub struct AppState {
    pub cfg: RwLock<Config>,
    pub config_path: Option<std::path::PathBuf>,
    pub trove: Trove,
    /// The live token set. Revoking removes a token here, so it takes effect
    /// on the next request without a restart.
    pub tokens: RwLock<Vec<TokenCfg>>,
    pub devices: DeviceStore,
    pub usage: Usage,
    pub uploads: UploadManager,
    pub events: EventBus,
    pub pairing: PairingState,
    pub started: Instant,
    pub version: String,
    /// Monotonic build number (git commit count) and short hash, stamped at
    /// compile time — how a client tells whether it's behind the server.
    pub build: u64,
    pub commit: String,
    /// A local secret that server-mode elyxr (on the same machine) presents to
    /// reach the admin surface. Never leaves the machine.
    pub admin_token: String,
    /// The last failures, newest last, capped at twenty.
    pub problems: Mutex<VecDeque<ProblemLine>>,
    pub bound_ok: AtomicBool,
}

pub type Shared = Arc<AppState>;

impl AppState {
    pub fn new(
        cfg: Config,
        trove: Trove,
        usage: Usage,
        uploads: UploadManager,
        devices: DeviceStore,
    ) -> Shared {
        // The live set is the config tokens plus the devices added by pairing.
        let mut tokens = cfg.tokens.clone();
        tokens.extend(devices.token_cfgs());
        Arc::new(AppState {
            cfg: RwLock::new(cfg),
            config_path: None,
            trove,
            tokens: RwLock::new(tokens),
            devices,
            usage,
            uploads,
            events: EventBus::new(),
            pairing: PairingState::new(),
            started: Instant::now(),
            version: env!("CARGO_PKG_VERSION").into(),
            build: env!("ELYXR_BUILD").parse().unwrap_or(0),
            commit: env!("ELYXR_COMMIT").into(),
            admin_token: mint_admin_token(),
            problems: Mutex::new(VecDeque::with_capacity(20)),
            bound_ok: AtomicBool::new(true),
        })
    }

    /// Attach the config path so server-mode edits can be written back.
    pub fn with_config_path(self: &mut Arc<Self>, path: std::path::PathBuf) {
        if let Some(inner) = Arc::get_mut(self) {
            inner.config_path = Some(path);
        }
    }

    pub fn uptime_s(&self) -> u64 {
        self.started.elapsed().as_secs()
    }

    pub fn trove_name(&self) -> String {
        self.cfg.read().unwrap().trove.name.clone()
    }

    pub fn bind_addr(&self) -> String {
        self.cfg.read().unwrap().bind.clone()
    }

    /// (default_limit, max_limit) for listings.
    pub fn list_limits(&self) -> (u32, u32) {
        let c = self.cfg.read().unwrap();
        (c.list.default_limit, c.list.max_limit)
    }

    /// More than this many files in a download arrives as a zip.
    pub fn max_loose_files(&self) -> u64 {
        self.cfg.read().unwrap().download.max_loose_files
    }

    /// Resolve the bearer token in an Authorization header to an identity, or
    /// the coded auth error. Used by every endpoint except health and pair.
    pub fn authenticate(&self, header: Option<&str>) -> Result<Identity, ApiError> {
        let raw = auth::parse_bearer(header)?;
        let tokens = self.tokens.read().unwrap();
        let id = auth::verify(&tokens, raw)?;
        // Best effort: note when this device was last seen.
        self.devices.touch(&id.label, now());
        Ok(id)
    }

    /// The effective ceiling for an uploading device: the smaller of the trove
    /// limit and the device's own cap (a guest's 10 GB is enforced this way).
    pub fn effective_max(&self, id: &Identity) -> u64 {
        self.usage.limits().max_bytes.min(id.max_bytes)
    }

    pub fn set_bound(&self, ok: bool) {
        self.bound_ok.store(ok, Ordering::Relaxed);
    }

    pub fn set_tokens(&self, tokens: Vec<TokenCfg>) {
        *self.tokens.write().unwrap() = tokens;
    }

    // ---- server-mode operations (§08, §09) ----

    /// Approve a paired device: mint a token, persist the device, add it to the
    /// live set, and hand the raw token back for the waiting pair call.
    pub fn approve_device(&self, device: &str, role: Role, max_bytes: u64) -> String {
        let raw = format!("lym_{}", ulid::Ulid::new());
        let hash = auth::hash_token(&raw);
        let rec = DeviceRecord {
            label: device.to_string(),
            hash: hash.clone(),
            role,
            max_bytes,
            approved_at: now(),
            last_seen: 0,
        };
        self.devices.add(&rec);
        self.tokens.write().unwrap().push(TokenCfg {
            label: device.to_string(),
            hash,
            role,
            max_bytes,
        });
        raw
    }

    /// Revoke a device: remove it from the store and the live set. Takes effect
    /// on the next request.
    pub fn revoke_device(&self, label: &str) -> bool {
        let removed = self.devices.remove(label);
        self.tokens.write().unwrap().retain(|t| t.label != label);
        removed
    }

    /// Record a failure for the recent-problems view, keeping the last twenty.
    pub fn record_problem(&self, line: ProblemLine) {
        let mut q = self.problems.lock().unwrap();
        if q.len() >= 20 {
            q.pop_front();
        }
        q.push_back(line);
    }

    pub fn recent_problems(&self) -> Vec<ProblemLine> {
        let q = self.problems.lock().unwrap();
        q.iter().rev().cloned().collect() // newest first
    }
}

fn mint_admin_token() -> String {
    format!("adm_{}", ulid::Ulid::new())
}

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}
