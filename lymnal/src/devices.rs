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
    /// The tailnet address this device paired from. A device that reinstalls
    /// loses its token; this is what lets it be recognised coming back.
    pub addr: Option<String>,
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
        // Older stores predate the column; adding it to an existing table is
        // the whole migration, and failing means it is already there.
        let _ = db.execute("ALTER TABLE devices ADD COLUMN addr TEXT", []);
        Ok(DeviceStore { db: Mutex::new(db) })
    }

    pub fn all(&self) -> Vec<DeviceRecord> {
        let db = self.db.lock().unwrap();
        let mut stmt = db
            .prepare(
                "SELECT label, hash, role, max_bytes, approved_at, last_seen, addr FROM devices",
            )
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
                    addr: r.get(6).ok(),
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
                 (label, hash, role, max_bytes, approved_at, last_seen, addr)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            rusqlite::params![
                rec.label,
                rec.hash,
                role,
                rec.max_bytes as i64,
                rec.approved_at,
                rec.last_seen,
                rec.addr
            ],
        );
    }

    /// The device on file under this label, if any.
    pub fn get(&self, label: &str) -> Option<DeviceRecord> {
        self.all().into_iter().find(|d| d.label == label)
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

#[cfg(test)]
mod tests {
    use super::*;

    fn rec(label: &str, addr: Option<&str>) -> DeviceRecord {
        DeviceRecord {
            label: label.into(),
            hash: format!("hash-of-{label}"),
            role: Role::Owner,
            max_bytes: 42,
            approved_at: 100,
            last_seen: 0,
            addr: addr.map(str::to_string),
        }
    }

    #[test]
    fn the_address_a_device_paired_from_survives_a_restart() {
        let dir = tempfile::tempdir().unwrap();
        {
            let store = DeviceStore::open(dir.path()).unwrap();
            store.add(&rec("phone", Some("100.0.0.9")));
        }
        let reopened = DeviceStore::open(dir.path()).unwrap();
        let got = reopened.get("phone").expect("device is on file");
        assert_eq!(got.addr.as_deref(), Some("100.0.0.9"));
    }

    #[test]
    fn a_store_written_before_the_column_existed_still_opens() {
        let dir = tempfile::tempdir().unwrap();
        {
            let db = Connection::open(dir.path().join("tokens.db")).unwrap();
            db.execute_batch(
                "CREATE TABLE devices (
                     label TEXT PRIMARY KEY, hash TEXT NOT NULL, role TEXT NOT NULL,
                     max_bytes INTEGER NOT NULL, approved_at INTEGER NOT NULL,
                     last_seen INTEGER NOT NULL);
                 INSERT INTO devices VALUES ('old','h','owner',1,2,3);",
            )
            .unwrap();
        }
        let store = DeviceStore::open(dir.path()).unwrap();
        let got = store.get("old").expect("the old row is still readable");
        assert_eq!(got.addr, None, "an older device simply has no address yet");
    }

    #[test]
    fn an_unknown_device_is_not_on_file() {
        let dir = tempfile::tempdir().unwrap();
        let store = DeviceStore::open(dir.path()).unwrap();
        store.add(&rec("phone", Some("100.0.0.9")));
        assert!(store.get("someone-elses-phone").is_none());
    }
}
