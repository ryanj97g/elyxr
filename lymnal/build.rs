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
    let build = git(&["rev-list", "--count", "HEAD"]).unwrap_or_else(|| "0".into());
    let commit = git(&["rev-parse", "--short", "HEAD"]).unwrap_or_else(|| "unknown".into());
    println!("cargo:rustc-env=ELYXR_BUILD={build}");
    println!("cargo:rustc-env=ELYXR_COMMIT={commit}");
    // Rebuild the stamp when HEAD moves, so an update always re-stamps.
    println!("cargo:rerun-if-changed=../.git/HEAD");
    println!("cargo:rerun-if-changed=../.git/refs/heads");
}
