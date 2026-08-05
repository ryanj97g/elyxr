//! The change stream (§04 `GET /v1/events`).
//!
//! lymnal watches the trove itself, so changes made directly on the server are
//! announced too. Each emitted event gets a monotonic id so a client can carry
//! Last-Event-ID; the SSE handler adds a ping every 20 s to hold the line.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use notify::{RecursiveMode, Watcher};
use serde::Serialize;
use serde_json::json;
use tokio::sync::broadcast;

use crate::model::{child_count, entry_for, is_hidden};

/// One line on the stream. `id` is monotonic and becomes the SSE event id.
#[derive(Debug, Clone, Serialize)]
pub struct StreamEvent {
    #[serde(skip)]
    pub id: u64,
    #[serde(skip)]
    pub event: &'static str, // "change" | "usage" | "update"
    #[serde(skip)]
    pub data: serde_json::Value,
}

#[derive(Clone)]
pub struct EventBus {
    tx: broadcast::Sender<StreamEvent>,
    seq: Arc<AtomicU64>,
}

impl EventBus {
    pub fn new() -> EventBus {
        let (tx, _rx) = broadcast::channel(256);
        EventBus {
            tx,
            seq: Arc::new(AtomicU64::new(1)),
        }
    }

    pub fn subscribe(&self) -> broadcast::Receiver<StreamEvent> {
        self.tx.subscribe()
    }

    fn next_id(&self) -> u64 {
        self.seq.fetch_add(1, Ordering::Relaxed)
    }

    /// Emit a `change` event. `entry` is the fresh entry JSON for created and
    /// modified, and absent for removed.
    pub fn change(&self, kind: &'static str, path: &str, entry: Option<serde_json::Value>) {
        let mut data = json!({ "kind": kind, "path": path });
        if let Some(e) = entry {
            data.as_object_mut().unwrap().insert("entry".into(), e);
        }
        let _ = self.tx.send(StreamEvent {
            id: self.next_id(),
            event: "change",
            data,
        });
    }

    /// Tell connected clients an update is starting here, so they update
    /// themselves in step rather than waiting to notice a version gap. Carries
    /// the build this server is on for reference.
    pub fn announce_update(&self, build: u64) {
        let _ = self.tx.send(StreamEvent {
            id: self.next_id(),
            event: "update",
            data: json!({ "build": build }),
        });
    }

    /// Emit a `usage` event carrying the running total and any live warnings.
    pub fn usage(&self, used_bytes: u64, warnings: &[crate::limits::Warning]) {
        let _ = self.tx.send(StreamEvent {
            id: self.next_id(),
            event: "usage",
            data: json!({ "used_bytes": used_bytes, "warnings": warnings }),
        });
    }
}

impl Default for EventBus {
    fn default() -> Self {
        EventBus::new()
    }
}

/// Watch the trove for changes made outside the API (directly on the server)
/// and translate them into stream events. Returns the watcher, which must be
/// kept alive for the life of the process.
pub fn watch_trove(
    root: PathBuf,
    bus: EventBus,
) -> notify::Result<notify::RecommendedWatcher> {
    let watch_root = root.clone();
    let mut watcher =
        notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
            let event = match res {
                Ok(e) => e,
                Err(_) => return,
            };
            use notify::EventKind::*;
            let kind: &'static str = match event.kind {
                Create(_) => "created",
                Remove(_) => "removed",
                Modify(_) => "modified",
                _ => return,
            };
            for abs in event.paths {
                if let Some(rel) = to_rel(&root, &abs) {
                    if rel.split('/').any(is_hidden) {
                        continue; // hidden files are never listed or announced
                    }
                    let entry = if kind == "removed" {
                        None
                    } else {
                        fresh_entry(&abs)
                    };
                    bus.change(kind, &rel, entry);
                }
            }
        })?;
    watcher.watch(&watch_root, RecursiveMode::Recursive)?;
    Ok(watcher)
}

fn to_rel(root: &Path, abs: &Path) -> Option<String> {
    let rel = abs.strip_prefix(root).ok()?;
    let s = rel.to_string_lossy().replace('\\', "/");
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

fn fresh_entry(abs: &Path) -> Option<serde_json::Value> {
    let meta = std::fs::symlink_metadata(abs).ok()?;
    let name = abs.file_name()?.to_string_lossy().into_owned();
    let mut entry = entry_for(name, &meta);
    if entry.kind == "dir" {
        entry.child_count = Some(child_count(abs));
    }
    serde_json::to_value(entry).ok()
}
