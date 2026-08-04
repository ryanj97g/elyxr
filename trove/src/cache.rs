//! The cache, making room, unsent changes (§03).
//!
//! A scratch area holding recently used files. When it is full the files
//! untouched longest are dropped. Nothing lives here that is not already on the
//! server, so it can be emptied at any moment and the only cost is fetching
//! again — EXCEPT files marked unsent (an interrupted save), which are never
//! evicted and are uploaded on next start. Deleting the cache costs time, never
//! data.

use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

struct Entry {
    size: u64,
    unsent: bool,
}

struct Inner {
    entries: HashMap<String, Entry>,
    /// Recency, oldest at the front.
    order: VecDeque<String>,
    used: u64,
}

pub struct Cache {
    dir: PathBuf,
    budget: Mutex<u64>,
    inner: Mutex<Inner>,
}

impl Cache {
    pub fn open(dir: impl AsRef<Path>, budget: u64) -> std::io::Result<Cache> {
        let dir = dir.as_ref().to_path_buf();
        std::fs::create_dir_all(&dir)?;
        Ok(Cache {
            dir,
            budget: Mutex::new(budget),
            inner: Mutex::new(Inner {
                entries: HashMap::new(),
                order: VecDeque::new(),
                used: 0,
            }),
        })
    }

    /// The on-disk path a cached file lives at (whether or not it's present).
    pub fn local_path(&self, key: &str) -> PathBuf {
        // Flatten the trove path into one filename so the cache is a flat dir.
        let safe = key.replace(['/', '\\'], "%2f");
        self.dir.join(safe)
    }

    pub fn used(&self) -> u64 {
        self.inner.lock().unwrap().used
    }

    pub fn budget(&self) -> u64 {
        *self.budget.lock().unwrap()
    }

    /// Is this file cached? Touches its recency if so.
    pub fn contains(&self, key: &str) -> bool {
        let mut inner = self.inner.lock().unwrap();
        if inner.entries.contains_key(key) {
            touch(&mut inner, key);
            true
        } else {
            false
        }
    }

    /// Store a file's bytes, evicting least-recently-used entries to fit. A
    /// file larger than the whole budget is still stored (the caller drops it
    /// when closed). Returns the local path.
    pub fn store(&self, key: &str, bytes: &[u8], unsent: bool) -> std::io::Result<PathBuf> {
        let path = self.local_path(key);
        std::fs::write(&path, bytes)?;
        let size = bytes.len() as u64;
        {
            let budget = *self.budget.lock().unwrap();
            let mut inner = self.inner.lock().unwrap();
            self.remove_locked(&mut inner, key);
            self.evict_locked(&mut inner, budget.saturating_sub(size));
            inner.entries.insert(key.to_string(), Entry { size, unsent });
            inner.order.push_back(key.to_string());
            inner.used += size;
        }
        Ok(path)
    }

    /// Mark (or clear) a file as an unsent save, which must not be evicted.
    pub fn set_unsent(&self, key: &str, unsent: bool) {
        let mut inner = self.inner.lock().unwrap();
        if let Some(e) = inner.entries.get_mut(key) {
            e.unsent = unsent;
        }
    }

    /// The files holding unsent changes, to upload on next start.
    pub fn unsent(&self) -> Vec<String> {
        let inner = self.inner.lock().unwrap();
        inner
            .entries
            .iter()
            .filter(|(_, e)| e.unsent)
            .map(|(k, _)| k.clone())
            .collect()
    }

    /// Empty the cache. Unsent files are kept (they are the only thing here not
    /// already safe on the server).
    pub fn empty(&self) {
        let mut inner = self.inner.lock().unwrap();
        let keys: Vec<String> = inner
            .entries
            .iter()
            .filter(|(_, e)| !e.unsent)
            .map(|(k, _)| k.clone())
            .collect();
        for k in keys {
            self.remove_locked(&mut inner, &k);
        }
    }

    /// Shrink to a new budget (free space fell), evicting to fit.
    pub fn shrink_to(&self, new_budget: u64) {
        *self.budget.lock().unwrap() = new_budget;
        let mut inner = self.inner.lock().unwrap();
        self.evict_locked(&mut inner, new_budget);
    }

    fn evict_locked(&self, inner: &mut Inner, target: u64) {
        while inner.used > target {
            // Find the oldest evictable (not unsent) key.
            let mut victim: Option<String> = None;
            for k in inner.order.iter() {
                if inner.entries.get(k).map(|e| !e.unsent).unwrap_or(false) {
                    victim = Some(k.clone());
                    break;
                }
            }
            match victim {
                Some(k) => self.remove_locked(inner, &k),
                None => break, // nothing left but unsent files
            }
        }
    }

    fn remove_locked(&self, inner: &mut Inner, key: &str) {
        if let Some(e) = inner.entries.remove(key) {
            inner.used = inner.used.saturating_sub(e.size);
            inner.order.retain(|k| k != key);
            let _ = std::fs::remove_file(self.local_path(key));
        }
    }
}

fn touch(inner: &mut Inner, key: &str) {
    inner.order.retain(|k| k != key);
    inner.order.push_back(key.to_string());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn evicts_least_recently_used_to_fit() {
        let d = tempfile::tempdir().unwrap();
        let c = Cache::open(d.path(), 30).unwrap();
        c.store("a", &[0u8; 10], false).unwrap();
        c.store("b", &[0u8; 10], false).unwrap();
        // Touch a so b is now the oldest.
        assert!(c.contains("a"));
        c.store("cc", &[0u8; 15], false).unwrap(); // needs to evict to fit within 30
        assert!(c.contains("a"), "a was touched, kept");
        assert!(!c.contains("b"), "b was oldest, evicted");
        assert!(c.used() <= 30);
    }

    #[test]
    fn unsent_files_are_never_evicted() {
        let d = tempfile::tempdir().unwrap();
        let c = Cache::open(d.path(), 20).unwrap();
        c.store("save", &[0u8; 15], true).unwrap(); // unsent
        c.store("big", &[0u8; 15], false).unwrap(); // would push over budget
        assert!(c.contains("save"), "unsent survives");
        assert_eq!(c.unsent(), vec!["save".to_string()]);
    }

    #[test]
    fn empty_keeps_unsent_only() {
        let d = tempfile::tempdir().unwrap();
        let c = Cache::open(d.path(), 100).unwrap();
        c.store("a", &[0u8; 10], false).unwrap();
        c.store("save", &[0u8; 10], true).unwrap();
        c.empty();
        assert!(!c.contains("a"));
        assert!(c.contains("save"));
    }

    #[test]
    fn a_file_larger_than_budget_is_still_stored() {
        let d = tempfile::tempdir().unwrap();
        let c = Cache::open(d.path(), 10).unwrap();
        let path = c.store("huge", &[0u8; 50], false).unwrap();
        assert!(path.exists());
        assert!(c.contains("huge"));
    }
}
