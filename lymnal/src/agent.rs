//! The client agent. On a device that has bound to a server (there's a
//! link.json next to the config), lymnal doesn't serve a trove — it stays
//! connected to that server's event stream and, when the server announces an
//! update, runs the installer. That's what makes "update the server, everything
//! follows" true even when the elyxr app is closed: the always-on service, not
//! the window, is what listens.

use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

/// Set while an install is running, so the two triggers (the live event and the
/// build poll) can't launch two at once. It resets on its own, because the
/// installer restarts lymnal into a fresh process.
static INSTALLING: AtomicBool = AtomicBool::new(false);

pub struct Link {
    pub server: String,
    pub token: String,
}

/// Read the link this device saved when it bound to a server. `None` means this
/// device is not a client (so lymnal serves instead).
pub fn load_link(config_dir: &Path) -> Option<Link> {
    let raw = std::fs::read_to_string(config_dir.join("link.json")).ok()?;
    let v: serde_json::Value = serde_json::from_str(&raw).ok()?;
    let server = v.get("server")?.as_str()?.to_string();
    let token = v.get("token")?.as_str()?.to_string();
    if server.is_empty() || token.is_empty() {
        return None;
    }
    Some(Link { server, token })
}

/// Stay connected to the server and act on its update announcements. Never
/// returns; reconnects whenever the stream drops (for example while the server
/// restarts during its own update).
pub fn run(link: Link, config_path: PathBuf) -> ! {
    tracing::info!(server = %link.server, "client agent: watching for updates");
    // A fallback next to the live event: poll the server's build number, so an
    // "update" event missed while reconnecting still lands within a few minutes.
    {
        let plink = Link { server: link.server.clone(), token: link.token.clone() };
        let pcfg = config_path.clone();
        std::thread::spawn(move || poll_build(&plink, &pcfg));
    }
    loop {
        if let Err(e) = listen(&link, &config_path) {
            tracing::warn!(error = %e, "client agent: lost the server, retrying");
        }
        std::thread::sleep(Duration::from_secs(5));
    }
}

/// Check the server's build every few minutes; if it's ahead of this device's,
/// run the installer. Covers the case where the live "update" event never
/// arrived (the watcher was between connections when the server announced).
fn poll_build(link: &Link, config_path: &Path) -> ! {
    let local: u64 = env!("ELYXR_BUILD").parse().unwrap_or(0);
    loop {
        std::thread::sleep(Duration::from_secs(180));
        let resp = ureq::get(&format!("http://{}/v1/health", link.server))
            .set("Authorization", &format!("Bearer {}", link.token))
            .call();
        if let Ok(r) = resp {
            if let Ok(v) = r.into_json::<serde_json::Value>() {
                let remote = v.get("build").and_then(|b| b.as_u64()).unwrap_or(0);
                if remote > local {
                    tracing::info!(remote, local, "server is ahead — updating this device");
                    run_installer(config_path);
                }
            }
        }
    }
}

fn listen(link: &Link, config_path: &Path) -> anyhow::Result<()> {
    let url = format!("http://{}/v1/events", link.server);
    let resp = ureq::get(&url)
        .set("Authorization", &format!("Bearer {}", link.token))
        .call()?;
    let reader = BufReader::new(resp.into_reader());
    let mut event = String::new();
    for line in reader.lines() {
        let line = line?;
        if let Some(rest) = line.strip_prefix("event:") {
            event = rest.trim().to_string();
        } else if line.is_empty() {
            // A blank line ends one server-sent event.
            if event == "update" {
                run_installer(config_path);
            }
            event.clear();
        }
    }
    Ok(())
}

/// Run the installer in its own systemd scope, so restarting lymnal partway
/// through (the installer does that) doesn't kill the update along with the
/// agent that started it.
fn run_installer(config_path: &Path) {
    // Only one install at a time, whichever trigger fires first.
    if INSTALLING.swap(true, Ordering::SeqCst) {
        return;
    }
    let repo = match crate::cli::find_repo(config_path) {
        Ok(r) => r,
        Err(e) => {
            tracing::warn!(error = %e, "client agent: can't find the repo to update from");
            return;
        }
    };
    let script = repo.join("elyxr.sh");
    tracing::info!("client agent: server announced an update, updating this device");
    let started = std::process::Command::new("systemd-run")
        .args(["--user", "--scope", "--quiet", "bash"])
        .arg(&script)
        .current_dir(&repo)
        .spawn();
    if let Err(e) = started {
        // No systemd-run (unusual): fall back to a plain detached run.
        tracing::warn!(error = %e, "client agent: systemd-run failed, running the installer directly");
        let _ = std::process::Command::new("bash")
            .arg(&script)
            .current_dir(&repo)
            .spawn();
    }
}
