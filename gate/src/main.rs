//! trove — mount the trove as a folder (default `~/elyxr`).
//!
//! Installed with elyxr; the folder is a switch in elyxr's settings. Reads the
//! server address and bearer token from the environment (elyxr passes them):
//!   ELYXR_SERVER   host:port on the tailnet (set by elyxr once paired)
//!   ELYXR_TOKEN    the bearer token (from the system keyring, via elyxr)
//!   ELYXR_MOUNT    where to mount (default ~/elyxr)
//!   ELYXR_CACHE    cache directory (default ~/.cache/trove)

use std::path::PathBuf;

use gate::{Cache, Lymnal, TroveFs};
use fuser::MountOption;

fn main() -> anyhow::Result<()> {
    let server = match std::env::var("ELYXR_SERVER") {
        Ok(s) if !s.is_empty() => s,
        _ => {
            eprintln!("trove: no server address. elyxr provides it via ELYXR_SERVER once paired.");
            std::process::exit(1);
        }
    };
    let token = match std::env::var("ELYXR_TOKEN") {
        Ok(t) if !t.is_empty() => t,
        _ => {
            eprintln!("trove: no token. elyxr provides it via ELYXR_TOKEN once paired.");
            std::process::exit(1);
        }
    };
    let mount = std::env::var("ELYXR_MOUNT")
        .map(PathBuf::from)
        .unwrap_or_else(|_| home().join("elyxr"));
    let cache_dir = std::env::var("ELYXR_CACHE")
        .map(PathBuf::from)
        .unwrap_or_else(|_| home().join(".cache/trove"));

    std::fs::create_dir_all(&mount)?;
    let budget = cache_budget(&cache_dir);
    let cache = Cache::open(&cache_dir, budget)?;
    let lymnal = Lymnal::new(format!("http://{server}"), token);

    let fs = TroveFs::new(lymnal, cache);
    // An interrupted save from last time finishes now.
    fs.flush_unsent();

    let options = vec![
        MountOption::FSName("elyxr".into()),
        MountOption::AutoUnmount,
        MountOption::DefaultPermissions,
    ];
    tracing::info!(mount = %mount.display(), %server, "mounting the trove");
    fuser::mount2(fs, &mount, &options)?;
    Ok(())
}

fn home() -> PathBuf {
    std::env::var("HOME").map(PathBuf::from).unwrap_or_else(|_| PathBuf::from("."))
}

/// 5 GB by default; where there isn't room, a quarter of free space with a
/// floor of 500 MB (§03).
fn cache_budget(dir: &std::path::Path) -> u64 {
    const DEFAULT: u64 = 5_000_000_000;
    const FLOOR: u64 = 500_000_000;
    let free = drive_free(dir);
    if free == 0 {
        return DEFAULT;
    }
    if free >= DEFAULT * 2 {
        DEFAULT
    } else {
        (free / 4).max(FLOOR)
    }
}

fn drive_free(path: &std::path::Path) -> u64 {
    use std::os::unix::ffi::OsStrExt;
    let target = if path.exists() { path } else { std::path::Path::new(".") };
    let Ok(c) = std::ffi::CString::new(target.as_os_str().as_bytes()) else {
        return 0;
    };
    // SAFETY: zeroed statvfs, read only on success.
    unsafe {
        let mut stat: libc::statvfs = std::mem::zeroed();
        if libc::statvfs(c.as_ptr(), &mut stat) == 0 {
            (stat.f_bavail as u64).saturating_mul(stat.f_frsize as u64)
        } else {
            0
        }
    }
}
