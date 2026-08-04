//! Answering the operating system (§03).
//!
//! elyxr-trove tells the OS it will answer for one folder. Every question about
//! that folder arrives here instead of at a drive: what's in it (list, cached),
//! open a file (download to the cache, then read from there), write (to the
//! cached copy), close (upload if changed), and rename/delete/mkdir (passed
//! through). The temp-file-and-swap save is recognised in `rename`.

use std::collections::HashMap;
use std::ffi::OsStr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use fuser::{
    FileAttr, FileType, Filesystem, ReplyAttr, ReplyCreate, ReplyData, ReplyDirectory,
    ReplyEmpty, ReplyEntry, ReplyOpen, ReplyWrite, Request,
};
use serde_json::Value;

use crate::cache::Cache;
use crate::client::{LymError, Lymnal};
use crate::errno::code_to_errno;
use crate::rename::is_save_swap;

const ROOT_INO: u64 = 1;
const TTL: Duration = Duration::from_secs(1);

struct Inodes {
    by_ino: HashMap<u64, String>,
    by_path: HashMap<String, u64>,
    next: u64,
}

struct OpenFile {
    path: String,
    dirty: bool,
}

pub struct TroveFs {
    lymnal: Lymnal,
    cache: Cache,
    inodes: Mutex<Inodes>,
    open: Mutex<HashMap<u64, OpenFile>>,
    next_fh: AtomicU64,
    uid: u32,
    gid: u32,
}

impl TroveFs {
    pub fn new(lymnal: Lymnal, cache: Cache) -> TroveFs {
        let mut by_ino = HashMap::new();
        let mut by_path = HashMap::new();
        by_ino.insert(ROOT_INO, String::new());
        by_path.insert(String::new(), ROOT_INO);
        // SAFETY: getuid/getgid are always safe.
        let (uid, gid) = unsafe { (libc::getuid(), libc::getgid()) };
        TroveFs {
            lymnal,
            cache,
            inodes: Mutex::new(Inodes {
                by_ino,
                by_path,
                next: 2,
            }),
            open: Mutex::new(HashMap::new()),
            next_fh: AtomicU64::new(1),
            uid,
            gid,
        }
    }

    /// Upload any unsent saves left from a previous run (§03: interrupted save
    /// stays in the cache marked unsent and is uploaded on next start).
    pub fn flush_unsent(&self) {
        for path in self.cache.unsent() {
            let local = self.cache.local_path(&path);
            if let Ok(bytes) = std::fs::read(&local) {
                if self.lymnal.upload(&path, &bytes, now()).is_ok() {
                    self.cache.set_unsent(&path, false);
                }
            }
        }
    }

    fn path_of(&self, ino: u64) -> Option<String> {
        self.inodes.lock().unwrap().by_ino.get(&ino).cloned()
    }

    fn ino_for(&self, path: &str) -> u64 {
        let mut t = self.inodes.lock().unwrap();
        if let Some(&ino) = t.by_path.get(path) {
            return ino;
        }
        let ino = t.next;
        t.next += 1;
        t.by_ino.insert(ino, path.to_string());
        t.by_path.insert(path.to_string(), ino);
        ino
    }

    fn join(&self, parent: &str, name: &str) -> String {
        if parent.is_empty() {
            name.to_string()
        } else {
            format!("{parent}/{name}")
        }
    }

    fn attr_from_stat(&self, ino: u64, v: &Value) -> FileAttr {
        let is_dir = v.get("kind").and_then(|k| k.as_str()) == Some("dir");
        let size = v.get("size_bytes").and_then(|s| s.as_u64()).unwrap_or(0);
        let mtime = v.get("mtime").and_then(|m| m.as_i64()).unwrap_or(0);
        self.attr(ino, is_dir, size, mtime)
    }

    fn attr(&self, ino: u64, is_dir: bool, size: u64, mtime: i64) -> FileAttr {
        let t = UNIX_EPOCH + Duration::from_secs(mtime.max(0) as u64);
        FileAttr {
            ino,
            size,
            blocks: size.div_ceil(512),
            atime: t,
            mtime: t,
            ctime: t,
            crtime: t,
            kind: if is_dir {
                FileType::Directory
            } else {
                FileType::RegularFile
            },
            perm: if is_dir { 0o755 } else { 0o644 },
            nlink: if is_dir { 2 } else { 1 },
            uid: self.uid,
            gid: self.gid,
            rdev: 0,
            blksize: 512,
            flags: 0,
        }
    }

    /// Ensure a file is in the cache, downloading it once. Returns its size.
    fn ensure_cached(&self, path: &str) -> Result<u64, LymError> {
        if self.cache.contains(path) {
            return Ok(std::fs::metadata(self.cache.local_path(path))
                .map(|m| m.len())
                .unwrap_or(0));
        }
        let bytes = self.lymnal.download(path)?;
        self.cache.store(path, &bytes, false).ok();
        Ok(bytes.len() as u64)
    }
}

/// Map a lymnal error to the errno a FUSE reply carries.
fn err_no(e: &LymError) -> i32 {
    code_to_errno(&e.code)
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

impl Filesystem for TroveFs {
    fn lookup(&mut self, _req: &Request, parent: u64, name: &OsStr, reply: ReplyEntry) {
        let Some(pp) = self.path_of(parent) else {
            return reply.error(libc::ENOENT);
        };
        let path = self.join(&pp, &name.to_string_lossy());
        match self.lymnal.stat(&path) {
            Ok(v) => {
                let ino = self.ino_for(&path);
                reply.entry(&TTL, &self.attr_from_stat(ino, &v), 0);
            }
            Err(e) => reply.error(err_no(&e)),
        }
    }

    fn getattr(&mut self, _req: &Request, ino: u64, reply: ReplyAttr) {
        if ino == ROOT_INO {
            return reply.attr(&TTL, &self.attr(ROOT_INO, true, 0, now()));
        }
        let Some(path) = self.path_of(ino) else {
            return reply.error(libc::ENOENT);
        };
        match self.lymnal.stat(&path) {
            Ok(v) => reply.attr(&TTL, &self.attr_from_stat(ino, &v)),
            Err(e) => reply.error(err_no(&e)),
        }
    }

    fn readdir(
        &mut self,
        _req: &Request,
        ino: u64,
        _fh: u64,
        offset: i64,
        mut reply: ReplyDirectory,
    ) {
        let Some(path) = self.path_of(ino) else {
            return reply.error(libc::ENOENT);
        };
        let entries = match self.lymnal.list(&path) {
            Ok(e) => e,
            Err(e) => return reply.error(err_no(&e)),
        };
        // Synthetic . and .. first.
        let mut rows: Vec<(u64, FileType, String)> = vec![
            (ino, FileType::Directory, ".".into()),
            (ROOT_INO, FileType::Directory, "..".into()),
        ];
        for v in &entries {
            let name = v.get("name").and_then(|n| n.as_str()).unwrap_or("").to_string();
            if name.is_empty() {
                continue;
            }
            let is_dir = v.get("kind").and_then(|k| k.as_str()) == Some("dir");
            let child = self.join(&path, &name);
            let cino = self.ino_for(&child);
            rows.push((
                cino,
                if is_dir {
                    FileType::Directory
                } else {
                    FileType::RegularFile
                },
                name,
            ));
        }
        for (i, (cino, kind, name)) in rows.into_iter().enumerate().skip(offset as usize) {
            // offset is the NEXT entry to read.
            if reply.add(cino, (i + 1) as i64, kind, name) {
                break;
            }
        }
        reply.ok();
    }

    fn open(&mut self, _req: &Request, ino: u64, _flags: i32, reply: ReplyOpen) {
        let Some(path) = self.path_of(ino) else {
            return reply.error(libc::ENOENT);
        };
        if let Err(e) = self.ensure_cached(&path) {
            return reply.error(err_no(&e));
        }
        let fh = self.next_fh.fetch_add(1, Ordering::Relaxed);
        self.open.lock().unwrap().insert(fh, OpenFile { path, dirty: false });
        reply.opened(fh, 0);
    }

    fn read(
        &mut self,
        _req: &Request,
        _ino: u64,
        fh: u64,
        offset: i64,
        size: u32,
        _flags: i32,
        _lock: Option<u64>,
        reply: ReplyData,
    ) {
        let path = match self.open.lock().unwrap().get(&fh) {
            Some(o) => o.path.clone(),
            None => return reply.error(libc::EBADF),
        };
        let local = self.cache.local_path(&path);
        match std::fs::read(&local) {
            Ok(bytes) => {
                let start = (offset as usize).min(bytes.len());
                let end = (start + size as usize).min(bytes.len());
                reply.data(&bytes[start..end]);
            }
            Err(_) => reply.error(libc::EIO),
        }
    }

    fn write(
        &mut self,
        _req: &Request,
        _ino: u64,
        fh: u64,
        offset: i64,
        data: &[u8],
        _write_flags: u32,
        _flags: i32,
        _lock: Option<u64>,
        reply: ReplyWrite,
    ) {
        let path = match self.open.lock().unwrap().get(&fh) {
            Some(o) => o.path.clone(),
            None => return reply.error(libc::EBADF),
        };
        let local = self.cache.local_path(&path);
        use std::io::{Seek, SeekFrom, Write};
        let res = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(&local)
            .and_then(|mut f| {
                f.seek(SeekFrom::Start(offset as u64))?;
                f.write_all(data)?;
                Ok(())
            });
        match res {
            Ok(()) => {
                // Applied to the cached copy; mark the save unsent until close.
                self.cache.set_unsent(&path, true);
                if let Some(o) = self.open.lock().unwrap().get_mut(&fh) {
                    o.dirty = true;
                }
                reply.written(data.len() as u32);
            }
            Err(_) => reply.error(libc::EIO),
        }
    }

    fn flush(&mut self, _req: &Request, _ino: u64, fh: u64, _lock: u64, reply: ReplyEmpty) {
        self.upload_if_dirty(fh, reply);
    }

    fn release(
        &mut self,
        _req: &Request,
        _ino: u64,
        fh: u64,
        _flags: i32,
        _lock: Option<u64>,
        _flush: bool,
        reply: ReplyEmpty,
    ) {
        // Upload if changed, then forget the handle.
        let uploaded = self.try_upload(fh);
        self.open.lock().unwrap().remove(&fh);
        match uploaded {
            Ok(()) => reply.ok(),
            Err(e) => reply.error(err_no(&e)),
        }
    }

    fn create(
        &mut self,
        _req: &Request,
        parent: u64,
        name: &OsStr,
        _mode: u32,
        _umask: u32,
        _flags: i32,
        reply: ReplyCreate,
    ) {
        let Some(pp) = self.path_of(parent) else {
            return reply.error(libc::ENOENT);
        };
        let path = self.join(&pp, &name.to_string_lossy());
        // Create an empty cached copy; the server file appears on close.
        if self.cache.store(&path, &[], true).is_err() {
            return reply.error(libc::EIO);
        }
        let ino = self.ino_for(&path);
        let fh = self.next_fh.fetch_add(1, Ordering::Relaxed);
        self.open
            .lock()
            .unwrap()
            .insert(fh, OpenFile { path, dirty: true });
        reply.created(&TTL, &self.attr(ino, false, 0, now()), 0, fh, 0);
    }

    fn mkdir(
        &mut self,
        _req: &Request,
        parent: u64,
        name: &OsStr,
        _mode: u32,
        _umask: u32,
        reply: ReplyEntry,
    ) {
        let Some(pp) = self.path_of(parent) else {
            return reply.error(libc::ENOENT);
        };
        let path = self.join(&pp, &name.to_string_lossy());
        match self.lymnal.mkdir(&path) {
            Ok(_) => {
                let ino = self.ino_for(&path);
                reply.entry(&TTL, &self.attr(ino, true, 0, now()), 0);
            }
            Err(e) => reply.error(err_no(&e)),
        }
    }

    fn unlink(&mut self, _req: &Request, parent: u64, name: &OsStr, reply: ReplyEmpty) {
        self.remove(parent, name, reply);
    }

    fn rmdir(&mut self, _req: &Request, parent: u64, name: &OsStr, reply: ReplyEmpty) {
        self.remove(parent, name, reply);
    }

    fn rename(
        &mut self,
        _req: &Request,
        parent: u64,
        name: &OsStr,
        newparent: u64,
        newname: &OsStr,
        _flags: u32,
        reply: ReplyEmpty,
    ) {
        let (Some(pp), Some(np)) = (self.path_of(parent), self.path_of(newparent)) else {
            return reply.error(libc::ENOENT);
        };
        let from_name = name.to_string_lossy().to_string();
        let to_name = newname.to_string_lossy().to_string();
        let from = self.join(&pp, &from_name);
        let to = self.join(&np, &to_name);

        // The temp-file-and-swap save: the temp's cached bytes become the new
        // version of the target, uploaded directly (§03).
        if is_save_swap(&pp, &from_name, &np, &to_name) && self.cache.contains(&from) {
            let local = self.cache.local_path(&from);
            match std::fs::read(&local) {
                Ok(bytes) => match self.lymnal.upload(&to, &bytes, now()) {
                    Ok(_) => {
                        // The temp is consumed; keep the new version cached.
                        self.cache.store(&to, &bytes, false).ok();
                        self.cache.empty(); // best-effort drop of the temp entry
                        return reply.ok();
                    }
                    Err(e) => return reply.error(err_no(&e)),
                },
                Err(_) => return reply.error(libc::EIO),
            }
        }

        // Otherwise a plain move on the server (replace, as rename semantics).
        match self.lymnal.move_(&from, &to, "replace") {
            Ok(_) => reply.ok(),
            Err(e) => reply.error(err_no(&e)),
        }
    }
}

impl TroveFs {
    fn remove(&self, parent: u64, name: &OsStr, reply: ReplyEmpty) {
        let Some(pp) = self.path_of(parent) else {
            return reply.error(libc::ENOENT);
        };
        let path = self.join(&pp, &name.to_string_lossy());
        match self.lymnal.delete(&[path]) {
            Ok(_) => reply.ok(),
            Err(e) => reply.error(err_no(&e)),
        }
    }

    fn upload_if_dirty(&self, fh: u64, reply: ReplyEmpty) {
        match self.try_upload(fh) {
            Ok(()) => reply.ok(),
            Err(e) => reply.error(err_no(&e)),
        }
    }

    /// Upload the cached copy if this handle wrote to it, and clear unsent.
    fn try_upload(&self, fh: u64) -> Result<(), LymError> {
        let (path, dirty) = match self.open.lock().unwrap().get(&fh) {
            Some(o) => (o.path.clone(), o.dirty),
            None => return Ok(()),
        };
        if !dirty {
            return Ok(());
        }
        let local = self.cache.local_path(&path);
        let bytes = std::fs::read(&local).map_err(|e| LymError {
            code: "IO_ERROR".into(),
            message: e.to_string(),
        })?;
        self.lymnal.upload(&path, &bytes, now())?;
        self.cache.set_unsent(&path, false);
        if let Some(o) = self.open.lock().unwrap().get_mut(&fh) {
            o.dirty = false;
        }
        Ok(())
    }
}
