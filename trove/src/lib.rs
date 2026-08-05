//! trove — answers for the trove folder on the client machine (§03).
//!
//! It tells the operating system it will answer for one folder (mounted at
//! `~/elyxr` by default) and turns every question about that folder into a
//! lymnal request, caching results so clicking around is instant.

pub mod cache;
pub mod client;
pub mod errno;
pub mod fs;
pub mod rename;

pub use cache::Cache;
pub use client::Lymnal;
pub use fs::TroveFs;
