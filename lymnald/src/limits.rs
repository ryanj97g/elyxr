//! Running total, recounts, warnings, drive space (§07).
//!
//! The total lives in `data_dir/usage.db`, adjusted on every write and delete,
//! recounted at startup and at 4am. Every list and commit carries it. Each
//! warning fires once per threshold, rides along on the next response, and
//! resets when usage drops back below.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use rusqlite::Connection;
use serde::Serialize;

use crate::config::Limits;
use crate::error::{ApiError, ErrCode};

/// A limit warning, carried in the `warnings` array of list/commit responses
/// and the events stream. Not an error and never presented as one.
#[derive(Debug, Clone, Serialize)]
pub struct Warning {
    pub code: String,
    pub message: String,
}

struct WarnState {
    /// Highest warn threshold (in bytes) already reported. 0 = none pending.
    last_reported: u64,
}

pub struct Usage {
    db: Mutex<Connection>,
    limits: std::sync::RwLock<Limits>,
    trove_root: PathBuf,
    warns: Mutex<WarnState>,
}

impl Usage {
    /// Open (creating) usage.db and recount the trove once at startup.
    pub fn open(data_dir: &Path, limits: Limits, trove_root: PathBuf) -> anyhow::Result<Usage> {
        let db = Connection::open(data_dir.join("usage.db"))?;
        db.execute_batch(
            "CREATE TABLE IF NOT EXISTS usage (
                 id INTEGER PRIMARY KEY CHECK (id = 1),
                 used_bytes INTEGER NOT NULL
             );
             INSERT OR IGNORE INTO usage (id, used_bytes) VALUES (1, 0);",
        )?;
        let usage = Usage {
            db: Mutex::new(db),
            limits: std::sync::RwLock::new(limits),
            trove_root,
            warns: Mutex::new(WarnState { last_reported: 0 }),
        };
        usage.recount()?;
        Ok(usage)
    }

    /// Replace the limits at runtime (server mode edits them, §09 Space).
    pub fn set_limits(&self, limits: Limits) {
        *self.limits.write().unwrap() = limits;
    }

    /// Walk the trove and store the true total. Run at startup and at 4am.
    pub fn recount(&self) -> anyhow::Result<u64> {
        let total = dir_size(&self.trove_root);
        let db = self.db.lock().unwrap();
        db.execute("UPDATE usage SET used_bytes = ?1 WHERE id = 1", [total as i64])?;
        Ok(total)
    }

    pub fn used(&self) -> u64 {
        let db = self.db.lock().unwrap();
        db.query_row("SELECT used_bytes FROM usage WHERE id = 1", [], |r| {
            r.get::<_, i64>(0)
        })
        .map(|v| v.max(0) as u64)
        .unwrap_or(0)
    }

    /// Adjust the running total on a write (positive) or delete (negative).
    pub fn adjust(&self, delta: i64) -> u64 {
        let db = self.db.lock().unwrap();
        let _ = db.execute(
            "UPDATE usage SET used_bytes = MAX(0, used_bytes + ?1) WHERE id = 1",
            [delta],
        );
        db.query_row("SELECT used_bytes FROM usage WHERE id = 1", [], |r| {
            r.get::<_, i64>(0)
        })
        .map(|v| v.max(0) as u64)
        .unwrap_or(0)
    }

    pub fn limits(&self) -> Limits {
        self.limits.read().unwrap().clone()
    }

    /// Free space on the drive holding the trove, in bytes.
    pub fn drive_free(&self) -> u64 {
        drive_free(&self.trove_root)
    }

    /// Refuse an upload before any bytes move (§07). `effective_max` is the
    /// smaller of the trove limit and the uploading device's own cap, so a
    /// guest's 10 GB is enforced here too. Checked at upload/init.
    pub fn check_can_accept(&self, incoming: u64, effective_max: u64) -> Result<(), ApiError> {
        let limits = self.limits();
        let used = self.used();
        if used + incoming > effective_max {
            let over = (used + incoming) - effective_max;
            return Err(ApiError::new(
                ErrCode::TroveFull,
                format!(
                    "This file won't fit. Your Elyxr folder holds up to {} and it's at {}, so this {} file is {} too big.",
                    gb1(effective_max),
                    gb1(used),
                    gb1(incoming),
                    gb1(over),
                ),
            )
            .with_detail(serde_json::json!({
                "used_bytes": used,
                "incoming_bytes": incoming,
                "max_bytes": effective_max,
            }))
            .with_hint("Delete something from Elyxr, or raise the limit in Elyxr's server settings."));
        }
        let free = self.drive_free();
        if free < incoming || free - incoming < limits.min_free_bytes {
            return Err(ApiError::new(
                ErrCode::DriveFull,
                format!(
                    "The drive is nearly full. It has {} free and Elyxr keeps at least {} clear, so this {} file can't be added.",
                    gb1(free),
                    gb1(limits.min_free_bytes),
                    gb1(incoming),
                ),
            )
            .with_detail(serde_json::json!({
                "drive_free_bytes": free,
                "incoming_bytes": incoming,
                "min_free_bytes": limits.min_free_bytes,
            }))
            .with_hint("Free space on the server's drive, then try again."));
        }
        Ok(())
    }

    /// Compute any warning that should ride along on this response, given the
    /// current total. Fires once per threshold; resets when usage drops back
    /// below a threshold already reported.
    pub fn warnings(&self) -> Vec<Warning> {
        let used = self.used();
        let max_bytes = self.limits().max_bytes;
        let mut w = self.warns.lock().unwrap();
        let current = self.threshold_for(used);
        if current > w.last_reported {
            w.last_reported = current;
            vec![Warning {
                code: "APPROACHING_MAX".into(),
                message: format!(
                    "Elyxr is at {} of {}.",
                    gb_round(used),
                    gb_round(max_bytes)
                ),
            }]
        } else {
            if current < w.last_reported {
                w.last_reported = current; // reset so it can fire again on the way up
            }
            Vec::new()
        }
    }

    /// The warn threshold band `used` currently sits in, in bytes. 0 means
    /// below the first warning (100 GB).
    fn threshold_for(&self, used: u64) -> u64 {
        let l = self.limits();
        if used < l.warn_at_bytes || l.warn_every == 0 {
            return 0;
        }
        let n = (used - l.warn_at_bytes) / l.warn_every;
        l.warn_at_bytes + n * l.warn_every
    }
}

/// Sum of every regular file's size below `root`, following no symlinks.
fn dir_size(root: &Path) -> u64 {
    let mut total = 0u64;
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let entries = match std::fs::read_dir(&dir) {
            Ok(e) => e,
            Err(_) => continue,
        };
        for entry in entries.flatten() {
            let meta = match entry.metadata() {
                Ok(m) => m,
                Err(_) => continue,
            };
            if meta.is_dir() && !meta.is_symlink() {
                stack.push(entry.path());
            } else if meta.is_file() {
                total += meta.len();
            }
        }
    }
    total
}

/// Free bytes on the filesystem holding `path`, via statvfs.
fn drive_free(path: &Path) -> u64 {
    use std::os::unix::ffi::OsStrExt;
    let c = match std::ffi::CString::new(path.as_os_str().as_bytes()) {
        Ok(c) => c,
        Err(_) => return 0,
    };
    // SAFETY: `stat` is zeroed and only read on a successful (0) return.
    unsafe {
        let mut stat: libc::statvfs = std::mem::zeroed();
        if libc::statvfs(c.as_ptr(), &mut stat) == 0 {
            (stat.f_bavail as u64).saturating_mul(stat.f_frsize as u64)
        } else {
            0
        }
    }
}

/// One-decimal GB, for the refusal wording ("149.1 GB").
fn gb1(bytes: u64) -> String {
    format!("{:.1} GB", bytes as f64 / 1e9)
}

/// GB rounded to a whole number when clean, else one decimal ("105 GB").
fn gb_round(bytes: u64) -> String {
    let v = bytes as f64 / 1e9;
    if (v.round() - v).abs() < 0.05 {
        format!("{} GB", v.round() as u64)
    } else {
        format!("{:.1} GB", v)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn usage(dir: &Path) -> Usage {
        let trove = dir.join("trove");
        std::fs::create_dir_all(&trove).unwrap();
        Usage::open(dir, Limits::default(), trove).unwrap()
    }

    #[test]
    fn warns_once_per_threshold_and_resets() {
        let d = tempfile::tempdir().unwrap();
        let u = usage(d.path());
        // Below 100 GB: silent.
        u.adjust(90_000_000_000);
        assert!(u.warnings().is_empty());
        // Cross 100 GB: one warning.
        u.adjust(15_000_000_000); // 105 GB
        let w = u.warnings();
        assert_eq!(w.len(), 1);
        assert_eq!(w[0].code, "APPROACHING_MAX");
        // Cross again within the same 5 GB band: silence.
        u.adjust(2_000_000_000); // 107 GB
        assert!(u.warnings().is_empty());
        // Next 5 GB band: one warning.
        u.adjust(4_000_000_000); // 111 GB
        assert_eq!(u.warnings().len(), 1);
        // Drop back below and rise again: fires once more.
        u.adjust(-20_000_000_000); // 91 GB
        assert!(u.warnings().is_empty());
        u.adjust(15_000_000_000); // 106 GB
        assert_eq!(u.warnings().len(), 1);
    }

    #[test]
    fn refuses_when_over_max() {
        let d = tempfile::tempdir().unwrap();
        let u = usage(d.path());
        u.adjust(149_000_000_000);
        let err = u
            .check_can_accept(2_000_000_000, u.limits().max_bytes)
            .unwrap_err();
        assert_eq!(err.code, ErrCode::TroveFull);
        assert!(err.message.contains("won't fit"));
    }
}
