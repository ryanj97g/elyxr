//! limbo — the client's lobby.
//!
//! A capped working-set and outbound queue, owned by lymnal on a client. It is a
//! *place* work passes through, never storage. Every entry is in one of two
//! states:
//!
//!   HELD            — unsynced work. Pinned; never evicted. The only copy until
//!                     it reaches the trove.
//!   PASSING THROUGH — already synced. Ordinary LRU, free to leave the moment
//!                     the disk gets tight.
//!
//! It is not bounded by a fixed size but by *leaving room*: the cache may grow
//! until free disk would fall below a reserve of 15% of the disk, or 2 GB,
//! whichever is larger. Held work may cross that reserve — it is the only copy —
//! and that crossing is exactly what makes a new write fail instead (§ failsafe).

use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// Keep at least this fraction of the disk free…
const RESERVE_FRACTION: f64 = 0.15;
/// …or this many bytes, whichever is larger.
const RESERVE_FLOOR: u64 = 2_000_000_000;

struct Entry {
    size: u64,
    held: bool,
}

struct Inner {
    entries: HashMap<String, Entry>,
    /// Recency, oldest at the front (for LRU eviction of passing-through work).
    order: VecDeque<String>,
}

pub struct Limbo {
    dir: PathBuf,
    inner: Mutex<Inner>,
}

/// Why a store failed.
#[derive(Debug)]
pub enum StoreErr {
    /// The write couldn't be saved to disk.
    Io(std::io::Error),
    /// The only way to fit this was to drop unsynced (held) work, so the new
    /// write is refused instead — held work is never sacrificed (§ failsafe).
    NoRoomHeldBlocks,
}

impl Limbo {
    pub fn open(dir: impl AsRef<Path>) -> std::io::Result<Limbo> {
        let dir = dir.as_ref().to_path_buf();
        std::fs::create_dir_all(&dir)?;
        Ok(Limbo {
            dir,
            inner: Mutex::new(Inner {
                entries: HashMap::new(),
                order: VecDeque::new(),
            }),
        })
    }

    /// The on-disk path a cached key lives at (whether or not it's present). The
    /// trove path is flattened into one filename so the dir stays flat.
    pub fn local_path(&self, key: &str) -> PathBuf {
        let safe = key.replace(['/', '\\'], "%2f");
        self.dir.join(safe)
    }

    /// Is this key present? Touches its recency if so.
    pub fn contains(&self, key: &str) -> bool {
        let mut inner = self.inner.lock().unwrap();
        if inner.entries.contains_key(key) {
            touch(&mut inner, key);
            true
        } else {
            false
        }
    }

    /// Read a cached key's bytes, touching recency. `None` if it isn't present.
    pub fn read(&self, key: &str) -> Option<Vec<u8>> {
        if !self.contains(key) {
            return None;
        }
        std::fs::read(self.local_path(key)).ok()
    }

    /// Store bytes under a key. `held = true` marks unsynced work that must not
    /// be evicted. Evicts passing-through work (LRU) to leave the free-disk
    /// reserve; if only held work stands in the way, refuses (§ failsafe). A
    /// single item larger than the whole allowance is still stored (the caller
    /// syncs and unpins it right away).
    pub fn store(&self, key: &str, bytes: &[u8], held: bool) -> Result<(), StoreErr> {
        let size = bytes.len() as u64;
        {
            let mut inner = self.inner.lock().unwrap();
            // Make room before writing, so we don't briefly overshoot the disk.
            if !self.make_room(&mut inner, key, size, held) {
                return Err(StoreErr::NoRoomHeldBlocks);
            }
            std::fs::write(self.local_path(key), bytes).map_err(StoreErr::Io)?;
            self.remove_locked(&mut inner, key);
            inner.entries.insert(key.to_string(), Entry { size, held });
            inner.order.push_back(key.to_string());
        }
        Ok(())
    }

    /// Mark (or clear) a key as held. Clearing it (a successful sync) unpins the
    /// file — it becomes ordinary passing-through work, free to be evicted.
    pub fn set_held(&self, key: &str, held: bool) {
        let mut inner = self.inner.lock().unwrap();
        if let Some(e) = inner.entries.get_mut(key) {
            e.held = held;
        }
    }

    /// The keys still holding unsynced work, to push (in recency order, oldest
    /// first — the ones that have waited longest go first).
    pub fn held_keys(&self) -> Vec<String> {
        let inner = self.inner.lock().unwrap();
        inner
            .order
            .iter()
            .filter(|k| inner.entries.get(*k).map(|e| e.held).unwrap_or(false))
            .cloned()
            .collect()
    }

    /// Drop a key outright (after it's been synced and no longer needed, or when
    /// the trove says it's gone).
    pub fn drop(&self, key: &str) {
        let mut inner = self.inner.lock().unwrap();
        self.remove_locked(&mut inner, key);
    }

    // --- room-making --------------------------------------------------------

    /// Free bytes left on the disk holding limbo, plus the space the incoming
    /// key would reclaim if it's replacing an existing entry.
    fn free_after_replacing(&self, inner: &Inner, key: &str) -> u64 {
        let reclaimed = inner.entries.get(key).map(|e| e.size).unwrap_or(0);
        disk_free(&self.dir).saturating_add(reclaimed)
    }

    /// The reserve to keep free on this disk: the larger of 15% and 2 GB.
    fn reserve(&self) -> u64 {
        let total = disk_total(&self.dir);
        ((total as f64 * RESERVE_FRACTION) as u64).max(RESERVE_FLOOR)
    }

    /// Evict passing-through work (LRU) until `size` fits while still leaving the
    /// reserve free. Held work is never evicted to make room. When no
    /// passing-through work is left to evict:
    ///   - a `held` write is accepted anyway — it's the only copy, so it's
    ///     allowed to cross the reserve;
    ///   - a passing-through write is refused (§ failsafe), unless limbo is
    ///     otherwise empty, in which case a single oversized item is allowed
    ///     through (the caller syncs and unpins it right away).
    fn make_room(&self, inner: &mut Inner, incoming_key: &str, size: u64, held: bool) -> bool {
        let reserve = self.reserve();
        loop {
            let free = self.free_after_replacing(inner, incoming_key);
            // Fits if, after writing `size`, at least `reserve` is still free.
            if free >= size.saturating_add(reserve) {
                return true;
            }
            // Evict the oldest passing-through entry that isn't the one we're
            // about to replace.
            let victim = inner.order.iter().find(|k| {
                k.as_str() != incoming_key
                    && inner.entries.get(*k).map(|e| !e.held).unwrap_or(false)
            });
            match victim.cloned() {
                Some(k) => self.remove_locked(inner, &k),
                None => {
                    if held {
                        return true; // held work crosses the reserve
                    }
                    let only_incoming = inner
                        .entries
                        .keys()
                        .all(|k| k.as_str() == incoming_key);
                    return only_incoming;
                }
            }
        }
    }

    fn remove_locked(&self, inner: &mut Inner, key: &str) {
        if inner.entries.remove(key).is_some() {
            inner.order.retain(|k| k != key);
            let _ = std::fs::remove_file(self.local_path(key));
        }
    }
}

fn touch(inner: &mut Inner, key: &str) {
    inner.order.retain(|k| k != key);
    inner.order.push_back(key.to_string());
}

/// Free bytes on the filesystem holding `path` (cross-platform, via fs2).
fn disk_free(path: &Path) -> u64 {
    let target = if path.exists() { path } else { Path::new(".") };
    fs2::available_space(target).unwrap_or(0)
}

/// Total bytes on the filesystem holding `path` (cross-platform, via fs2).
fn disk_total(path: &Path) -> u64 {
    let target = if path.exists() { path } else { Path::new(".") };
    fs2::total_space(target).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn held_survives_and_lists_oldest_first() {
        let d = tempfile::tempdir().unwrap();
        let l = Limbo::open(d.path()).unwrap();
        l.store("a", &[0u8; 10], true).unwrap();
        l.store("b", &[0u8; 10], true).unwrap();
        assert_eq!(l.held_keys(), vec!["a".to_string(), "b".to_string()]);
        // Clearing held on a unpins it; it drops off the held list.
        l.set_held("a", false);
        assert_eq!(l.held_keys(), vec!["b".to_string()]);
    }

    #[test]
    fn read_round_trips() {
        let d = tempfile::tempdir().unwrap();
        let l = Limbo::open(d.path()).unwrap();
        l.store("k", b"hello", false).unwrap();
        assert_eq!(l.read("k").as_deref(), Some(&b"hello"[..]));
        l.drop("k");
        assert!(l.read("k").is_none());
    }
}
