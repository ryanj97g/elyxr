// Stamp the build with the git commit it was built from, so a client can tell
// whether it's behind the server. `build` is the commit count on the current
// history — it only goes up as we ship to main, so "server build > my build"
// means "I'm behind." `commit` is the short hash, for humans. Both are read at
// compile time; if this isn't a git checkout, they fall back to 0/"unknown"
// and the update prompt simply never fires (no false "you're behind").

use std::process::Command;

fn git(args: &[&str]) -> Option<String> {
    let out = Command::new("git").args(args).output().ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8(out.stdout).ok()?.trim().to_string();
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

fn main() {
    // The installer (elyxr.sh) passes the stamp in as ELYXR_BUILD/ELYXR_COMMIT,
    // computed once from git for the whole stack. Prefer that: it guarantees the
    // stamp advances on every update, even a Dart-only one, without depending on
    // cargo noticing a moved git ref. Fall back to reading git directly (a plain
    // `cargo build`, or a CI release build with no env set).
    let env_nonempty = |k: &str| std::env::var(k).ok().filter(|s| !s.is_empty());
    let build = env_nonempty("ELYXR_BUILD")
        .or_else(|| git(&["rev-list", "--count", "HEAD"]))
        .unwrap_or_else(|| "0".into());
    let commit = env_nonempty("ELYXR_COMMIT")
        .or_else(|| git(&["rev-parse", "--short", "HEAD"]))
        .unwrap_or_else(|| "unknown".into());
    println!("cargo:rustc-env=ELYXR_BUILD={build}");
    println!("cargo:rustc-env=ELYXR_COMMIT={commit}");
    // Re-stamp when the installer hands us a new number (the reliable trigger),
    // and still re-run if HEAD moves for a plain `cargo build`.
    println!("cargo:rerun-if-env-changed=ELYXR_BUILD");
    println!("cargo:rerun-if-env-changed=ELYXR_COMMIT");
    println!("cargo:rerun-if-changed=../.git/HEAD");
    println!("cargo:rerun-if-changed=../.git/refs/heads");
}
