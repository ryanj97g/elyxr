//! Approval, minting, revocation (§08).
//!
//! Pairing only works while it is switched on in server mode, times out after
//! 120 seconds, and is refused from outside the tailnet. A pair request blocks
//! until a person at the server approves or denies it; both devices show the
//! same four-word phrase, derived from the request so they always agree.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

use tokio::sync::oneshot;

use crate::config::Role;

/// The word list. Mirrors elyxr/lib/util/phrase.dart exactly, so the client and
/// server derive the same phrase from the same {device, client}.
const WORDS: [&str; 24] = [
    "copper", "anchor", "violet", "moth", "cedar", "harbor", "ember", "quartz", "willow",
    "lantern", "marble", "otter", "saffron", "thistle", "cobalt", "raven", "meadow", "pewter",
    "cinder", "juniper", "beacon", "sable", "opal", "fern",
];

/// FNV-1a 32-bit of "device|client", then four distinct words chosen by an LCG.
/// Deterministic and identical to the Dart implementation.
pub fn phrase_for(device: &str, client: &str) -> String {
    let seed = format!("{device}|{client}");
    let mut h: u32 = 0x811c9dc5;
    for b in seed.bytes() {
        h ^= b as u32;
        h = h.wrapping_mul(0x0100_0193);
    }
    let mut state: u32 = if h == 0 { 1 } else { h };
    let mut chosen: Vec<usize> = Vec::with_capacity(4);
    while chosen.len() < 4 {
        state = state.wrapping_mul(1664525).wrapping_add(1013904223);
        let idx = (state as usize) % WORDS.len();
        if !chosen.contains(&idx) {
            chosen.push(idx);
        }
    }
    chosen
        .into_iter()
        .map(|i| WORDS[i])
        .collect::<Vec<_>>()
        .join(" ")
}

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
    phrase: String,
    tx: oneshot::Sender<Decision>,
}

/// A pending request as seen by server mode.
#[derive(Clone)]
pub struct PendingView {
    pub device: String,
    pub client: String,
    pub phrase: String,
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
        phrase: String,
    ) -> oneshot::Receiver<Decision> {
        let (tx, rx) = oneshot::channel();
        self.pending.lock().unwrap().insert(
            device,
            PendingEntry {
                client,
                phrase,
                tx,
            },
        );
        rx
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
                phrase: e.phrase.clone(),
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn phrase_is_deterministic_and_four_distinct_words() {
        let a = phrase_for("probookrjg", "elyxr/1.0.0");
        let b = phrase_for("probookrjg", "elyxr/1.0.0");
        assert_eq!(a, b);
        let words: Vec<&str> = a.split(' ').collect();
        assert_eq!(words.len(), 4);
        let unique: std::collections::HashSet<_> = words.iter().collect();
        assert_eq!(unique.len(), 4);
        for w in words {
            assert!(WORDS.contains(&w));
        }
    }

    #[test]
    fn phrase_matches_the_cross_language_vector() {
        // Must equal the Dart implementation for the same input.
        assert_eq!(
            phrase_for("probookrjg", "elyxr/1.0.0"),
            "fern violet anchor saffron"
        );
    }

    #[test]
    fn phrase_differs_by_device() {
        assert_ne!(
            phrase_for("probookrjg", "elyxr/1.0.0"),
            phrase_for("otherbox", "elyxr/1.0.0")
        );
    }
}
