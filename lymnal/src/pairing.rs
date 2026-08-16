//! Approval, minting, revocation (§08).
//!
//! Pairing only works while it is switched on in server mode, times out after
//! 120 seconds, and is refused from outside the tailnet. A pair request blocks
//! until a person at the server approves or denies it, recognising the device
//! by its name. Approving a device closes the pairing window.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

use tokio::sync::oneshot;

use crate::config::Role;

/// What a waiting pair request is told once a person decides.
pub enum Decision {
    Approve {
        token: String,
        role: Role,
        max_bytes: u64,
    },
    Deny,
}

struct PendingEntry {
    client: String,
    addr: Option<String>,
    tx: oneshot::Sender<Decision>,
}

/// A pending request as seen by server mode.
#[derive(Clone)]
pub struct PendingView {
    pub device: String,
    pub client: String,
}

/// Pairing window state plus the set of requests waiting for a decision.
pub struct PairingState {
    open: AtomicBool,
    pending: Mutex<HashMap<String, PendingEntry>>,
}

impl PairingState {
    pub fn new() -> PairingState {
        PairingState {
            open: AtomicBool::new(false),
            pending: Mutex::new(HashMap::new()),
        }
    }

    pub fn is_open(&self) -> bool {
        self.open.load(Ordering::Relaxed)
    }

    pub fn open(&self) {
        self.open.store(true, Ordering::Relaxed);
    }

    pub fn close(&self) {
        self.open.store(false, Ordering::Relaxed);
    }

    /// Register a waiting request and return the receiver the pair handler
    /// awaits. Keyed by device — a new request from the same device replaces
    /// the old one.
    pub fn register(
        &self,
        device: String,
        client: String,
        addr: Option<String>,
    ) -> oneshot::Receiver<Decision> {
        let (tx, rx) = oneshot::channel();
        self.pending
            .lock()
            .unwrap()
            .insert(device, PendingEntry { client, addr, tx });
        rx
    }

    /// The address a waiting request came from, recorded when it is approved.
    pub fn addr_of(&self, device: &str) -> Option<String> {
        self.pending.lock().unwrap().get(device).and_then(|e| e.addr.clone())
    }

    /// Drop a request that timed out or whose connection went away.
    pub fn forget(&self, device: &str) {
        self.pending.lock().unwrap().remove(device);
    }

    /// The requests currently waiting, for server mode to show.
    pub fn pending(&self) -> Vec<PendingView> {
        self.pending
            .lock()
            .unwrap()
            .iter()
            .map(|(device, e)| PendingView {
                device: device.clone(),
                client: e.client.clone(),
            })
            .collect()
    }

    /// Resolve a waiting request with a decision. Returns false if there was no
    /// such pending device (already resolved or gone).
    pub fn resolve(&self, device: &str, decision: Decision) -> bool {
        let entry = self.pending.lock().unwrap().remove(device);
        match entry {
            Some(e) => e.tx.send(decision).is_ok(),
            None => false,
        }
    }
}

impl Default for PairingState {
    fn default() -> Self {
        PairingState::new()
    }
}
