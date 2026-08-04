//! Approved devices, persisted across restarts (§08, §09 Devices).
//!
//! Tokens minted at pairing live here — the argon2id hash, never the token —
//! alongside the metadata server mode shows: role, limit, when approved, when
//! last seen. Config `[[token]]` entries are honoured too; this store holds the
//! ones added by pairing.

use std::path::Path;
use std::sync::Mutex;

use rusqlite::Connection;

use crate::config::{Role, TokenCfg};

#[derive(Debug, Clone)]
pub struct DeviceRecord {
    pub label: String,
    pub hash: String,
    pub role: Role,
    pub max_bytes: u64,
    pub approved_at: i64,
    pub last_seen: i64,
}

pub struct DeviceStore {
    db: Mutex<Connection>,
}

impl DeviceStore {
    pub fn open(data_dir: &Path) -> anyhow::Result<DeviceStore> {
        let db = Connection::open(data_dir.join("tokens.db"))?;
        db.execute_batch(
            "CREATE TABLE IF NOT EXISTS devices (
                 label       TEXT PRIMARY KEY,
                 hash        TEXT NOT NULL,
                 role        TEXT NOT NULL,
                 max_bytes   INTEGER NOT NULL,
                 approved_at INTEGER NOT NULL,
                 last_seen   INTEGER NOT NULL
             );",
        )?;
        Ok(DeviceStore { db: Mutex::new(db) })
    }

    pub fn all(&self) -> Vec<DeviceRecord> {
        let db = self.db.lock().unwrap();
        let mut stmt = db
            .prepare("SELECT label, hash, role, max_bytes, approved_at, last_seen FROM devices")
            .unwrap();
        let rows = stmt
            .query_map([], |r| {
                let role: String = r.get(2)?;
                Ok(DeviceRecord {
                    label: r.get(0)?,
                    hash: r.get(1)?,
                    role: if role == "guest" { Role::Guest } else { Role::Owner },
                    max_bytes: r.get::<_, i64>(3)? as u64,
                    approved_at: r.get(4)?,
                    last_seen: r.get(5)?,
                })
            })
            .unwrap();
        rows.filter_map(Result::ok).collect()
    }

    pub fn add(&self, rec: &DeviceRecord) {
        let role = match rec.role {
            Role::Owner => "owner",
            Role::Guest => "guest",
        };
        let db = self.db.lock().unwrap();
        let _ = db.execute(
            "INSERT OR REPLACE INTO devices
                 (label, hash, role, max_bytes, approved_at, last_seen)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            rusqlite::params![
                rec.label,
                rec.hash,
                role,
                rec.max_bytes as i64,
                rec.approved_at,
                rec.last_seen
            ],
        );
    }

    pub fn remove(&self, label: &str) -> bool {
        let db = self.db.lock().unwrap();
        db.execute("DELETE FROM devices WHERE label = ?1", [label])
            .map(|n| n > 0)
            .unwrap_or(false)
    }

    pub fn touch(&self, label: &str, ts: i64) {
        let db = self.db.lock().unwrap();
        let _ = db.execute(
            "UPDATE devices SET last_seen = ?1 WHERE label = ?2",
            rusqlite::params![ts, label],
        );
    }

    /// The token configs for auth (label, hash, role, max_bytes).
    pub fn token_cfgs(&self) -> Vec<TokenCfg> {
        self.all()
            .into_iter()
            .map(|d| TokenCfg {
                label: d.label,
                hash: d.hash,
                role: d.role,
                max_bytes: d.max_bytes,
            })
            .collect()
    }
}
