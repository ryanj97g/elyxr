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
    // "update" event missed while reconnecting still lands within a minute.
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
        std::thread::sleep(Duration::from_secs(60));
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

/// Apply an update this device was told about. The trigger (the live event and
/// the build poll) is identical on every platform; only *how* an update is
/// applied differs — a source rebuild on Linux, a prebuilt fetch on Windows —
/// so the "update the server and every device follows" promise holds the same
/// on both.
/// Trigger an update now, the same one the server's announcement would — used by
/// the Windows tray's "Update now" (a prebuilt fetch). Guarded, so a click during
/// an in-flight update is a no-op.
#[cfg(target_os = "windows")]
pub fn update_now(config_path: &Path) {
    run_installer(config_path);
}

/// Update this device now, the same path an announced update takes — used by the
/// server when an owner device asks the whole fleet to update, so the server
/// follows an update triggered from a client. Guarded against an in-flight
/// install, and cross-platform (source rebuild on Linux, prebuilt fetch on
/// Windows).
pub fn trigger_local_update(config_path: PathBuf) {
    run_installer(&config_path);
}

/// Run the installer to update THIS device — the single code path every trigger
/// funnels through: the app's Update button and the tray's "Update now" (both via
/// `update_fleet_and_self`), the `lymnal update` command, and this agent's own
/// auto-update. Guarded so one process can't launch two at once.
fn run_installer(config_path: &Path) {
    if INSTALLING.swap(true, Ordering::SeqCst) {
        return;
    }
    tracing::info!("update: applying to this device");
    #[cfg(not(target_os = "windows"))]
    launch_local_installer(config_path);
    #[cfg(target_os = "windows")]
    {
        let _ = config_path; // the Windows update doesn't need the repo
        update_from_release();
    }
}

/// Linux/Unix: re-run the installer detached in its own systemd scope, so the
/// lymnal/app restart it performs can't kill the update midway. The scope carries
/// a fixed unit name (`elyxr-update`), so a second trigger while one is already
/// running is refused by systemd — no double builds, no matter how many places
/// (app, tray, command, agent) fire at once. Falls back to a plain detached run
/// where systemd-run isn't available.
#[cfg(not(target_os = "windows"))]
pub fn launch_local_installer(config_path: &Path) {
    let repo = match crate::cli::find_repo(config_path) {
        Ok(r) => r,
        Err(e) => {
            tracing::warn!(error = %e, "update: can't find the repo to update from");
            INSTALLING.store(false, Ordering::SeqCst);
            return;
        }
    };
    let script = repo.join("elyxr.sh");
    let started = std::process::Command::new("systemd-run")
        .args(["--user", "--scope", "--unit=elyxr-update", "--quiet", "bash"])
        .arg(&script)
        .current_dir(&repo)
        .spawn();
    if let Err(e) = started {
        tracing::warn!(error = %e, "update: systemd-run unavailable; running the installer detached");
        let _ = std::process::Command::new("setsid")
            .arg("bash")
            .arg(&script)
            .current_dir(&repo)
            .spawn()
            .or_else(|_| {
                std::process::Command::new("bash")
                    .arg(&script)
                    .current_dir(&repo)
                    .spawn()
            });
    }
}

/// A person triggered a full update on THIS device — the app's Update button, the
/// tray's "Update now", or `lymnal update`. All three call this, so they behave
/// identically: notify the rest of the fleet (best-effort — a client asks its
/// server to update everyone, a server broadcasts to its clients) and then update
/// this device. A duplicate install from the fleet broadcast echoing back is
/// refused by the installer's fixed scope name.
pub fn update_fleet_and_self(config_path: &Path) {
    // Reconnect BEFORE announcing — the same thing the tray's "Refresh
    // connection" does. The fleet update rides the server's live event stream,
    // which only reaches currently-connected agents; a stale stream is why the
    // fleet used to update piecemeal (each device waiting on its 60s build poll)
    // instead of all at once. Restarting the service re-establishes the link (and,
    // on the server, drops every client so they reconnect fresh), so the announce
    // that follows actually lands everywhere. Best-effort, then a moment to settle
    // before we announce. Only the manual trigger runs this — an agent applying an
    // update it was told about goes straight to run_installer, so there's no loop.
    #[cfg(not(target_os = "windows"))]
    refresh_connection_and_settle();
    if let Some(dir) = config_path.parent() {
        if let Some(link) = load_link(dir) {
            let _ = crate::cli::request_fleet_update(&link);
        } else {
            let _ = crate::cli::announce_update_to_clients(config_path);
        }
    }
    run_installer(config_path);
}

/// Restart the local service to refresh its connection, exactly as the tray's
/// "Refresh connection" button does — detached in its own scope so restarting the
/// service can't kill this updater process — then wait for it to reconnect.
#[cfg(not(target_os = "windows"))]
fn refresh_connection_and_settle() {
    tracing::info!("update: refreshing the connection before announcing the fleet update");
    let started = std::process::Command::new("systemd-run")
        .args([
            "--user", "--scope", "--quiet",
            "systemctl", "--user", "restart", "lymnal.service",
        ])
        .spawn();
    if started.is_err() {
        let _ = std::process::Command::new("systemctl")
            .args(["--user", "restart", "lymnal.service"])
            .spawn();
    }
    // Give the service time to come back up and its event stream to reconnect
    // (clients retry on a ~5s cadence) before the announce goes out.
    std::thread::sleep(Duration::from_secs(8));
}

/// Windows: there is no compiler on the device, so an update is a *fetch*, not a
/// rebuild. Download the published installer and run it silently; it stops
/// lymnal, swaps the binaries, and starts it again — the same end state as the
/// Linux rebuild, reached the way every Windows app updates itself.
#[cfg(target_os = "windows")]
fn update_from_release() {
    const INSTALLER_URL: &str =
        "https://github.com/ryanj97g/elyxr/releases/latest/download/elyxr-setup.exe";
    let dest = std::env::temp_dir().join("elyxr-setup.exe");
    let agent = ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(10))
        .timeout(Duration::from_secs(600))
        .build();
    let result = (|| -> anyhow::Result<()> {
        let resp = agent.get(INSTALLER_URL).call()?;
        let mut reader = resp.into_reader();
        let mut file = std::io::BufWriter::new(std::fs::File::create(&dest)?);
        std::io::copy(&mut reader, &mut file)?;
        std::io::Write::flush(&mut file)?;
        drop(file);
        // Inno Setup silent flags: no UI, no prompts, and never reboot the box.
        std::process::Command::new(&dest)
            .args(["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART"])
            .spawn()?;
        Ok(())
    })();
    if let Err(e) = result {
        tracing::warn!(error = %e, "client agent: Windows update failed; will retry later");
        // Let a later trigger try again, since the installer never launched.
        INSTALLING.store(false, Ordering::SeqCst);
    }
}
