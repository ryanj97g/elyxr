//! Staging, offsets, commit, replacement (§05).
//!
//! Three calls: `init` declares the whole file so limits are checked before
//! any bytes move; chunks of 8 MiB arrive at declared offsets, in any order,
//! idempotent per offset; `commit` verifies the checksum then renames staging
//! into place in one filesystem operation. Staging lives in `data_dir`, never
//! in the trove, and is swept after 48 hours.

use std::collections::HashMap;
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::error::{ApiError, ErrCode};

/// The staged state of one in-flight upload.
struct Upload {
    id: String,
    target_rel: String,
    target_abs: PathBuf,
    size: u64,
    checksum: Option<String>,
    mtime: i64,
    staging: PathBuf,
    /// Received byte ranges, merged and sorted, half-open [start, end).
    received: Vec<(u64, u64)>,
    expires_at: i64,
}

impl Upload {
    fn received_bytes(&self) -> u64 {
        self.received.iter().map(|(a, b)| b - a).sum()
    }

    fn complete(&self) -> bool {
        self.size == 0 || (self.received.len() == 1 && self.received[0] == (0, self.size))
    }

    /// Gaps still missing within [0, size), as [start, end) pairs.
    fn missing(&self) -> Vec<(u64, u64)> {
        let mut gaps = Vec::new();
        let mut cursor = 0u64;
        for &(a, b) in &self.received {
            if a > cursor {
                gaps.push((cursor, a));
            }
            cursor = cursor.max(b);
        }
        if cursor < self.size {
            gaps.push((cursor, self.size));
        }
        gaps
    }

    fn add_range(&mut self, start: u64, end: u64) {
        self.received.push((start, end));
        self.received.sort_by_key(|r| r.0);
        let mut merged: Vec<(u64, u64)> = Vec::with_capacity(self.received.len());
        for &(a, b) in &self.received {
            if let Some(last) = merged.last_mut() {
                if a <= last.1 {
                    last.1 = last.1.max(b);
                    continue;
                }
            }
            merged.push((a, b));
        }
        self.received = merged;
    }
}

/// The outcome of a successful commit.
#[derive(Debug)]
pub struct Committed {
    pub path: String,
    pub size_bytes: u64,
    pub replaced: bool,
    pub identical: bool,
}

pub struct UploadManager {
    staging_dir: PathBuf,
    chunk_bytes: u64,
    stale_after: Duration,
    uploads: Mutex<HashMap<String, Upload>>,
}

impl UploadManager {
    pub fn new(data_dir: &std::path::Path, chunk_bytes: u64, stale_after_hrs: u64) -> UploadManager {
        let staging_dir = data_dir.join("staging");
        let _ = std::fs::create_dir_all(&staging_dir);
        UploadManager {
            staging_dir,
            chunk_bytes,
            stale_after: Duration::from_secs(stale_after_hrs * 3600),
            uploads: Mutex::new(HashMap::new()),
        }
    }

    /// How many uploads are actively mid-transfer — received some data but not
    /// yet complete. Used to hold a service restart until in-flight uploads
    /// finish, so an update never cuts one off (upload state is in memory).
    pub fn active_count(&self) -> usize {
        self.uploads
            .lock()
            .unwrap()
            .values()
            .filter(|u| u.received_bytes() > 0 && !u.complete())
            .count()
    }

    pub fn chunk_bytes(&self) -> u64 {
        self.chunk_bytes
    }

    /// Begin an upload. The target has already been resolved (parent inside the
    /// trove) by the caller; limits have already been checked. Returns
    /// (upload_id, received_bytes, target_exists, expires_at).
    pub fn init(
        &self,
        target_rel: String,
        target_abs: PathBuf,
        size: u64,
        checksum: Option<String>,
        mtime: i64,
    ) -> Result<(String, u64, bool, i64), ApiError> {
        let id = ulid::Ulid::new().to_string();
        let staging = self.staging_dir.join(&id);
        // Create an empty staging file up front so a chunk can seek into it.
        std::fs::File::create(&staging)
            .map_err(|e| ApiError::io(format!("Couldn't open staging space: {e}")))?;
        let target_exists = target_abs.exists();
        let expires_at = now() + self.stale_after.as_secs() as i64;
        let up = Upload {
            id: id.clone(),
            target_rel,
            target_abs,
            size,
            checksum,
            mtime,
            staging,
            received: Vec::new(),
            expires_at,
        };
        self.uploads.lock().unwrap().insert(id.clone(), up);
        Ok((id, 0, target_exists, expires_at))
    }

    /// Write one chunk at `offset`. Idempotent per offset: re-sending a chunk
    /// already held changes nothing. Returns (received_bytes, complete).
    pub fn chunk(&self, id: &str, offset: u64, bytes: &[u8]) -> Result<(u64, bool), ApiError> {
        let (staging, size, expired) = {
            let map = self.uploads.lock().unwrap();
            let up = map.get(id).ok_or_else(|| expired_err(id))?;
            (up.staging.clone(), up.size, up.expires_at < now())
        };
        if expired {
            self.discard(id);
            return Err(expired_err(id));
        }
        let end = offset + bytes.len() as u64;
        if end > size {
            return Err(ApiError::new(
                ErrCode::BadPath,
                "This chunk runs past the end of the declared file size.",
            ));
        }
        // Write outside the map lock.
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .open(&staging)
            .map_err(|e| ApiError::io(format!("Couldn't write staging: {e}")))?;
        f.seek(SeekFrom::Start(offset))
            .and_then(|_| f.write_all(bytes))
            .map_err(|e| ApiError::io(format!("Couldn't write staging: {e}")))?;

        let mut map = self.uploads.lock().unwrap();
        let up = map.get_mut(id).ok_or_else(|| expired_err(id))?;
        up.add_range(offset, end);
        Ok((up.received_bytes(), up.complete()))
    }

    /// Report progress: (received_bytes, size_bytes, missing ranges, expires_at).
    pub fn status(&self, id: &str) -> Result<(u64, u64, Vec<(u64, u64)>, i64), ApiError> {
        let map = self.uploads.lock().unwrap();
        let up = map.get(id).ok_or_else(|| expired_err(id))?;
        Ok((
            up.received_bytes(),
            up.size,
            up.missing(),
            up.expires_at,
        ))
    }

    /// Verify and install. Returns the committed result plus the on-disk size
    /// delta to apply to the running total (0 when identical or when only
    /// replacing same-size bytes is not the case — the caller adds it).
    pub fn commit(&self, id: &str) -> Result<(Committed, i64), ApiError> {
        // Take the upload out; on any failure below we must not leave it half-done.
        let up = {
            let mut map = self.uploads.lock().unwrap();
            map.remove(id).ok_or_else(|| expired_err(id))?
        };
        if up.expires_at < now() {
            let _ = std::fs::remove_file(&up.staging);
            return Err(expired_err(id));
        }
        if !up.complete() {
            // Put it back so the client can fill the gaps and retry commit.
            let staging = up.staging.clone();
            let _ = staging;
            let mut map = self.uploads.lock().unwrap();
            map.insert(up.id.clone(), up);
            return Err(ApiError::new(
                ErrCode::IncompleteUpload,
                "Some of this file hasn't arrived yet. It will finish and then install.",
            ));
        }

        // Verify the checksum, if one was declared.
        let staging_hash = hash_file(&up.staging)
            .map_err(|e| ApiError::io(format!("Couldn't read staging to verify: {e}")))?;
        if let Some(expected) = &up.checksum {
            if !hash_eq(expected, &staging_hash) {
                let _ = std::fs::remove_file(&up.staging); // discard, leave target untouched
                return Err(ApiError::new(
                    ErrCode::ChecksumMismatch,
                    "This file arrived corrupted and was not saved. Try the upload again.",
                ));
            }
        }

        let old_size = up
            .target_abs
            .metadata()
            .ok()
            .filter(|m| m.is_file())
            .map(|m| m.len());
        let replaced = old_size.is_some();

        // Identical bytes: discard staging, do not write, mtime unchanged.
        if replaced {
            if let Ok(existing_hash) = hash_file(&up.target_abs) {
                if hash_eq(&existing_hash, &staging_hash) {
                    let _ = std::fs::remove_file(&up.staging);
                    return Ok((
                        Committed {
                            path: up.target_rel,
                            size_bytes: up.size,
                            replaced: true,
                            identical: true,
                        },
                        0,
                    ));
                }
            }
        }

        // Install: create parents, rename staging into place, set mtime.
        if let Some(parent) = up.target_abs.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| ApiError::from_io(&e, &up.target_rel))?;
        }
        std::fs::rename(&up.staging, &up.target_abs).map_err(|e| {
            let _ = std::fs::remove_file(&up.staging);
            ApiError::from_io(&e, &up.target_rel)
        })?;
        set_mtime(&up.target_abs, up.mtime);
        // Best effort: uploaded files take 0644.
        set_mode_0644(&up.target_abs);

        let delta = up.size as i64 - old_size.unwrap_or(0) as i64;
        Ok((
            Committed {
                path: up.target_rel,
                size_bytes: up.size,
                replaced,
                identical: false,
            },
            delta,
        ))
    }

    /// Abandon an upload and delete its staging file (§04 DELETE upload/{id}).
    pub fn discard(&self, id: &str) {
        if let Some(up) = self.uploads.lock().unwrap().remove(id) {
            let _ = std::fs::remove_file(&up.staging);
        }
    }

    /// Sweep uploads whose expiry has passed, deleting their staging files.
    pub fn sweep(&self) {
        let now = now();
        let mut map = self.uploads.lock().unwrap();
        let dead: Vec<String> = map
            .iter()
            .filter(|(_, u)| u.expires_at < now)
            .map(|(k, _)| k.clone())
            .collect();
        for id in dead {
            if let Some(up) = map.remove(&id) {
                let _ = std::fs::remove_file(&up.staging);
            }
        }
    }
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn expired_err(id: &str) -> ApiError {
    ApiError::new(
        ErrCode::UploadExpired,
        "This upload is no longer being held. Start it again.",
    )
    .with_detail(serde_json::json!({ "upload_id": id }))
}

/// BLAKE3 of a file as `b3:<lowercase hex>`.
pub fn hash_file(path: &std::path::Path) -> std::io::Result<String> {
    let mut f = std::fs::File::open(path)?;
    let mut hasher = blake3::Hasher::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(format!("b3:{}", hasher.finalize().to_hex()))
}

/// Compare two checksums, tolerating a missing/present `b3:` prefix on either.
pub(crate) fn hash_eq(a: &str, b: &str) -> bool {
    let strip = |s: &str| s.strip_prefix("b3:").unwrap_or(s).to_ascii_lowercase();
    strip(a) == strip(b)
}

fn set_mtime(path: &std::path::Path, mtime: i64) {
    if mtime <= 0 {
        return;
    }
    // Cross-platform mtime (utimensat on Unix, SetFileTime on Windows).
    let ft = filetime::FileTime::from_unix_time(mtime, 0);
    let _ = filetime::set_file_mtime(path, ft);
}

/// Make a committed file world-readable (0644). Unix-only; on other platforms
/// files don't carry a Unix mode, so this is a no-op.
#[cfg(unix)]
fn set_mode_0644(path: &std::path::Path) {
    use std::os::unix::fs::PermissionsExt;
    let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o644));
}

#[cfg(not(unix))]
fn set_mode_0644(_path: &std::path::Path) {}

#[cfg(test)]
mod tests {
    use super::*;

    fn manager() -> (tempfile::TempDir, UploadManager) {
        let d = tempfile::tempdir().unwrap();
        let m = UploadManager::new(d.path(), 8, 48);
        (d, m)
    }

    #[test]
    fn resend_same_chunk_does_not_change_received() {
        let (d, m) = manager();
        let target = d.path().join("out.bin");
        let (id, _, exists, _) = m
            .init("out.bin".into(), target, 16, None, 0)
            .unwrap();
        assert!(!exists);
        let (r1, done1) = m.chunk(&id, 0, &[1u8; 8]).unwrap();
        assert_eq!(r1, 8);
        assert!(!done1);
        let (r2, _) = m.chunk(&id, 0, &[1u8; 8]).unwrap();
        assert_eq!(r2, 8, "re-sending the same chunk must not change received_bytes");
    }

    #[test]
    fn out_of_order_chunks_and_commit() {
        let (d, m) = manager();
        let target = d.path().join("sub/out.bin");
        let data = b"0123456789ABCDEF"; // 16 bytes
        let checksum = {
            let mut h = blake3::Hasher::new();
            h.update(data);
            format!("b3:{}", h.finalize().to_hex())
        };
        let (id, _, _, _) = m
            .init("sub/out.bin".into(), target.clone(), 16, Some(checksum), 1_700_000_000)
            .unwrap();
        // Second half first.
        m.chunk(&id, 8, &data[8..]).unwrap();
        let (_, done) = m.chunk(&id, 0, &data[..8]).unwrap();
        assert!(done);
        let (committed, delta) = m.commit(&id).unwrap();
        assert!(!committed.identical);
        assert_eq!(delta, 16);
        assert_eq!(std::fs::read(&target).unwrap(), data);
    }

    #[test]
    fn wrong_checksum_leaves_target_untouched() {
        let (d, m) = manager();
        let target = d.path().join("out.bin");
        std::fs::write(&target, b"original").unwrap();
        let (id, _, _, _) = m
            .init("out.bin".into(), target.clone(), 4, Some("b3:deadbeef".into()), 0)
            .unwrap();
        m.chunk(&id, 0, b"new!").unwrap();
        let err = m.commit(&id).unwrap_err();
        assert_eq!(err.code, ErrCode::ChecksumMismatch);
        assert_eq!(std::fs::read(&target).unwrap(), b"original");
        // Staging gone.
        assert_eq!(std::fs::read_dir(d.path().join("staging")).unwrap().count(), 0);
    }

    #[test]
    fn identical_bytes_report_identical() {
        let (d, m) = manager();
        let target = d.path().join("out.bin");
        std::fs::write(&target, b"same").unwrap();
        let mtime_before = std::fs::metadata(&target).unwrap().modified().unwrap();
        let (id, _, exists, _) = m.init("out.bin".into(), target.clone(), 4, None, 0).unwrap();
        assert!(exists);
        m.chunk(&id, 0, b"same").unwrap();
        let (committed, delta) = m.commit(&id).unwrap();
        assert!(committed.identical);
        assert!(committed.replaced);
        assert_eq!(delta, 0);
        assert_eq!(std::fs::metadata(&target).unwrap().modified().unwrap(), mtime_before);
    }

    #[test]
    fn incomplete_commit_refuses() {
        let (d, m) = manager();
        let target = d.path().join("out.bin");
        let (id, _, _, _) = m.init("out.bin".into(), target, 16, None, 0).unwrap();
        m.chunk(&id, 0, &[1u8; 8]).unwrap();
        let err = m.commit(&id).unwrap_err();
        assert_eq!(err.code, ErrCode::IncompleteUpload);
        // Still resumable.
        assert!(m.status(&id).is_ok());
    }
}

