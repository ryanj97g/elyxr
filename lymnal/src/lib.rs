//! lymnal — a Rust service that owns one folder (the trove) and serves it over
//! Tailscale to clients that store nothing. See `specs/lymnal-spec.txt`.
//!
//! Milestone ONE is the service: every endpoint in §04 matching its contract,
//! the limits of §07, the error shape of §09, and the §11 path-refusal list.

pub mod auth;
pub mod config;
pub mod devices;
pub mod error;
pub mod events;
pub mod handlers;
pub mod limbo;
pub mod limits;
pub mod model;
pub mod pairing;
pub mod proxy;
pub mod state;
pub mod trove;
pub mod upload;

pub use state::{AppState, Shared};
