//! The same operations as commands, for troubleshooting (§08). Reached as
//! `lymnal <command>`; the service itself is `lymnal` with no command. These
//! call the same code paths as the service and Elyxr's server mode, so the
//! three cannot disagree.

use lymnal::auth::hash_token;
use lymnal::config::{expand_tilde, resolve_bind, Config, Role};
use lymnal::devices::{DeviceRecord, DeviceStore};
use lymnal::limits::Usage;

/// Dispatch a troubleshooting command. `args` is the full argument list, with
/// the subcommand first.
pub fn run(args: &[String]) -> anyhow::Result<()> {
    let mut args = args.to_vec();

    // Optional --config <path> anywhere.
    let mut config_path = std::env::var("LYMNAL_CONFIG")
        .ok()
        .map(expand_tilde)
        .unwrap_or_else(|| expand_tilde("~/.config/lymnal/config.toml"));
    if let Some(i) = args.iter().position(|a| a == "--config") {
        if i + 1 < args.len() {
            config_path = expand_tilde(args.remove(i + 1));
        }
        args.remove(i);
    }

    match args.first().map(String::as_str).unwrap_or("") {
        "status" => status(&config_path),
        "recount" => recount(&config_path),
        "token" => token(&config_path, &args[1..]),
        "trove" => trove(&config_path, &args[1..]),
        "bind" => bind(&config_path, &args[1..]),
        "update" => update(&config_path, &args[1..]),
        "help" | "-h" | "--help" | "" => {
            print_usage();
            Ok(())
        }
        other => anyhow::bail!("unknown command '{other}'. Try: lymnal help"),
    }
}

fn load(config_path: &std::path::Path) -> anyhow::Result<Config> {
    Config::load(config_path).map_err(|e| anyhow::anyhow!("{e}"))
}

fn status(config_path: &std::path::Path) -> anyhow::Result<()> {
    let cfg = load(config_path)?;
    let devices = DeviceStore::open(&cfg.data_dir)?;
    let usage = Usage::open(&cfg.data_dir, cfg.limits.clone(), cfg.trove.path.clone())?;
    println!("trove     {} at {}", cfg.trove.name, cfg.trove.path.display());
    let shown = resolve_bind(&cfg.bind).unwrap_or_else(|_| cfg.bind.clone());
    println!("bind      {}", shown);
    println!("data_dir  {}", cfg.data_dir.display());
    println!(
        "used      {:.1} GB of {:.1} GB",
        usage.used() as f64 / 1e9,
        cfg.limits.max_bytes as f64 / 1e9
    );
    println!("devices   {}", devices.all().len());
    Ok(())
}

fn recount(config_path: &std::path::Path) -> anyhow::Result<()> {
    let cfg = load(config_path)?;
    let usage = Usage::open(&cfg.data_dir, cfg.limits.clone(), cfg.trove.path.clone())?;
    let total = usage.recount()?;
    println!("recounted: {:.1} GB in use", total as f64 / 1e9);
    Ok(())
}

fn token(config_path: &std::path::Path, args: &[String]) -> anyhow::Result<()> {
    let cfg = load(config_path)?;
    let devices = DeviceStore::open(&cfg.data_dir)?;
    match args.first().map(String::as_str) {
        Some("list") => {
            let all = devices.all();
            if all.is_empty() {
                println!("(no devices approved)");
            }
            for d in all {
                println!(
                    "{:<16} {:<6} {:.0} GB",
                    d.label,
                    role_str(d.role),
                    d.max_bytes as f64 / 1e9
                );
            }
            Ok(())
        }
        Some("new") => {
            let label = args
                .get(1)
                .ok_or_else(|| {
                    anyhow::anyhow!(
                        "usage: lymnal token new <label> [--role owner|guest] [--max-bytes N]"
                    )
                })?
                .clone();
            let role = flag(args, "--role")
                .map(|r| if r == "guest" { Role::Guest } else { Role::Owner })
                .unwrap_or(Role::Owner);
            let max_bytes = flag(args, "--max-bytes")
                .and_then(|v| v.parse::<u64>().ok())
                .unwrap_or(match role {
                    Role::Owner => cfg.limits.max_bytes,
                    Role::Guest => 10_000_000_000,
                });
            let raw = format!("lym_{}", ulid_like());
            devices.add(&DeviceRecord {
                label: label.clone(),
                hash: hash_token(&raw),
                role,
                max_bytes,
                approved_at: now(),
                last_seen: 0,
            });
            println!("Approved {label}. The token is shown once — copy it now:");
            println!("{raw}");
            Ok(())
        }
        Some("revoke") => {
            let label = args
                .get(1)
                .ok_or_else(|| anyhow::anyhow!("usage: lymnal token revoke <label>"))?;
            if devices.remove(label) {
                println!("Revoked {label}. It stops working on its next request.");
            } else {
                println!("No device named {label}.");
            }
            Ok(())
        }
        _ => anyhow::bail!("usage: lymnal token list | new <label> | revoke <label>"),
    }
}

fn trove(config_path: &std::path::Path, args: &[String]) -> anyhow::Result<()> {
    match args.first().map(String::as_str) {
        Some("set") => {
            let path = args
                .get(1)
                .ok_or_else(|| anyhow::anyhow!("usage: lymnal trove set <path>"))?;
            let mut cfg = load(config_path)?;
            cfg.trove.path = expand_tilde(path);
            cfg.save(config_path)
                .map_err(|e| anyhow::anyhow!("couldn't write config: {e}"))?;
            println!(
                "Trove path set to {}. Existing files are not moved for you; restart lymnal to use it.",
                cfg.trove.path.display()
            );
            Ok(())
        }
        _ => anyhow::bail!("usage: lymnal trove set <path>"),
    }
}

/// Bind devices to the trove against the running service's admin surface (§08).
/// Unlike the other commands, these can't touch the on-disk stores directly —
/// pending requests live in the running process — so they speak to the local
/// admin surface over HTTP with the machine-local admin token.
fn bind(config_path: &std::path::Path, args: &[String]) -> anyhow::Result<()> {
    let cfg = load(config_path)?;
    let addr = resolve_bind(&cfg.bind).map_err(|e| anyhow::anyhow!("{e}"))?;
    let base = format!("http://{addr}");
    let token = read_admin_token(&cfg.data_dir)?;

    match args.first().map(String::as_str) {
        Some("open") => {
            admin_post(&base, &token, "/v1/admin/pairing", serde_json::json!({ "open": true }))?;
            println!("Ready to bind. Open Elyxr on the other device and request access.");
            println!("Waiting for a device...  (Ctrl+C to stop)");
            // Poll until a device shows up, then show its phrase and ask.
            let mut waited = 0;
            let (device, phrase) = loop {
                std::thread::sleep(std::time::Duration::from_secs(1));
                waited += 1;
                let v = admin_get(&base, &token, "/v1/admin/pending")?;
                let list = v.get("pending").and_then(|p| p.as_array()).cloned().unwrap_or_default();
                if let Some(p) = list.first() {
                    let s = |k: &str| p.get(k).and_then(|x| x.as_str()).unwrap_or("").to_string();
                    break (s("device"), s("phrase"));
                }
                if waited >= 300 {
                    println!("No device asked to connect in time. Run 'lymnal bind open' again when ready.");
                    return Ok(());
                }
            };
            println!("\n  device:  {device}\n  phrase:  {phrase}\n");
            print!("Do these four words match the other screen? Approve {device}? [y/N]: ");
            use std::io::Write;
            std::io::stdout().flush().ok();
            let mut ans = String::new();
            std::io::stdin().read_line(&mut ans).ok();
            if matches!(ans.trim().to_lowercase().as_str(), "y" | "yes") {
                admin_post(&base, &token, "/v1/admin/approve",
                    serde_json::json!({ "device": device, "role": "owner" }))?;
                println!("Sealed. {device} is connected now.");
            } else {
                admin_post(&base, &token, "/v1/admin/deny", serde_json::json!({ "device": device }))?;
                println!("Turned away {device}.");
            }
            // Stop accepting once we've handled one.
            admin_post(&base, &token, "/v1/admin/pairing", serde_json::json!({ "open": false }))?;
            Ok(())
        }
        Some("seal") => {
            // Approve the one device that's waiting — no name to type.
            let v = admin_get(&base, &token, "/v1/admin/pending")?;
            let list = v.get("pending").and_then(|p| p.as_array()).cloned().unwrap_or_default();
            match list.len() {
                0 => anyhow::bail!(
                    "no device is waiting. Run 'lymnal bind open' and request access on the other device first."
                ),
                1 => {
                    let device = list[0].get("device").and_then(|d| d.as_str()).unwrap_or("").to_string();
                    admin_post(&base, &token, "/v1/admin/approve",
                        serde_json::json!({ "device": device, "role": "owner" }))?;
                    println!("Sealed. {device} is connected now.");
                    Ok(())
                }
                _ => {
                    println!("More than one device is waiting — approve the one you mean by name:");
                    for p in &list {
                        let s = |k: &str| p.get(k).and_then(|x| x.as_str()).unwrap_or("");
                        println!("  {}  ({})", s("device"), s("phrase"));
                    }
                    anyhow::bail!("run: lymnal bind approve <device>")
                }
            }
        }
        Some("close") => {
            admin_post(&base, &token, "/v1/admin/pairing", serde_json::json!({ "open": false }))?;
            println!("No longer accepting new devices.");
            Ok(())
        }
        Some("list") | Some("pending") => {
            let v = admin_get(&base, &token, "/v1/admin/pending")?;
            let list = v.get("pending").and_then(|p| p.as_array()).cloned().unwrap_or_default();
            if list.is_empty() {
                println!("(no devices are waiting to be bound)");
                println!("If you haven't yet: lymnal bind open");
                return Ok(());
            }
            println!("{:<18} {:<14} {}", "device", "client", "phrase");
            for p in list {
                let s = |k: &str| p.get(k).and_then(|x| x.as_str()).unwrap_or("").to_string();
                println!("{:<18} {:<14} {}", s("device"), s("client"), s("phrase"));
            }
            println!("\nBind it with:  lymnal bind seal   (or: lymnal bind approve <device>)");
            Ok(())
        }
        Some("approve") => {
            let device = args
                .get(1)
                .filter(|a| !a.starts_with("--"))
                .ok_or_else(|| {
                    anyhow::anyhow!(
                        "usage: lymnal bind approve <device> [--guest] [--max-bytes N]"
                    )
                })?
                .clone();
            let guest = args.iter().any(|a| a == "--guest")
                || flag(args, "--role").as_deref() == Some("guest");
            let role = if guest { "guest" } else { "owner" };
            let mut body = serde_json::json!({ "device": device, "role": role });
            if let Some(mb) = flag(args, "--max-bytes").and_then(|v| v.parse::<u64>().ok()) {
                body["max_bytes"] = serde_json::json!(mb);
            }
            let v = admin_post(&base, &token, "/v1/admin/approve", body)?;
            let gb = v.get("max_bytes").and_then(|m| m.as_u64()).unwrap_or(0) as f64 / 1e9;
            println!("Bound {device} as {role} ({gb:.0} GB). It's connected now.");
            Ok(())
        }
        Some("deny") => {
            let device = args
                .get(1)
                .ok_or_else(|| anyhow::anyhow!("usage: lymnal bind deny <device>"))?
                .clone();
            admin_post(&base, &token, "/v1/admin/deny", serde_json::json!({ "device": device }))?;
            println!("Turned away {device}.");
            Ok(())
        }
        _ => anyhow::bail!(
            "usage: lymnal bind open | list | seal | approve <device> [--guest] | deny <device> | close"
        ),
    }
}

/// Run the installer, which self-updates: pulls the latest, rebuilds only what
/// changed, and restarts the service if its binary changed. Extra args (e.g.
/// --verbose) are forwarded to the installer.
fn update(config_path: &std::path::Path, args: &[String]) -> anyhow::Result<()> {
    let repo = find_repo(config_path)?;
    let script = repo.join("elyxr.sh");
    if !script.exists() {
        anyhow::bail!(
            "found a recorded repo at {} but no elyxr.sh there. Re-run ./elyxr.sh from the repo once.",
            repo.display()
        );
    }
    let status = std::process::Command::new("bash")
        .arg(&script)
        .args(args)
        .current_dir(&repo)
        .status()
        .map_err(|e| anyhow::anyhow!("couldn't launch the installer at {}: {e}", script.display()))?;
    if !status.success() {
        anyhow::bail!("the installer reported a problem (see its output above).");
    }
    Ok(())
}

/// Find the Elyxr repo: first the path the installer recorded next to the
/// config, then the conventional `~/Elyxr`.
fn find_repo(config_path: &std::path::Path) -> anyhow::Result<std::path::PathBuf> {
    if let Some(dir) = config_path.parent() {
        if let Ok(s) = std::fs::read_to_string(dir.join("repo.path")) {
            let p = std::path::PathBuf::from(s.trim());
            if p.join("elyxr.sh").exists() {
                return Ok(p);
            }
        }
    }
    if let Ok(home) = std::env::var("HOME") {
        for name in ["elyxr", "Elyxr"] {
            let p = std::path::Path::new(&home).join(name);
            if p.join("elyxr.sh").exists() {
                return Ok(p);
            }
        }
    }
    anyhow::bail!(
        "couldn't find the Elyxr repo. Clone it and run ./elyxr.sh once so it's recorded."
    )
}

/// Read the machine-local admin token lymnal wrote at startup.
fn read_admin_token(data_dir: &std::path::Path) -> anyhow::Result<String> {
    let path = data_dir.join("admin.token");
    let raw = std::fs::read_to_string(&path).map_err(|e| {
        anyhow::anyhow!(
            "couldn't read the admin token at {} ({e}). Is lymnal running on this machine?",
            path.display()
        )
    })?;
    Ok(raw.trim().to_string())
}

fn admin_get(base: &str, token: &str, path: &str) -> anyhow::Result<serde_json::Value> {
    handle_admin(
        ureq::get(&format!("{base}{path}"))
            .set("X-Admin-Token", token)
            .call(),
    )
}

fn admin_post(
    base: &str,
    token: &str,
    path: &str,
    body: serde_json::Value,
) -> anyhow::Result<serde_json::Value> {
    handle_admin(
        ureq::post(&format!("{base}{path}"))
            .set("X-Admin-Token", token)
            .send_json(body),
    )
}

/// Turn a ureq result into JSON or a readable error, surfacing lymnal's own
/// coded message (§09) when the request was refused.
fn handle_admin(
    resp: Result<ureq::Response, ureq::Error>,
) -> anyhow::Result<serde_json::Value> {
    match resp {
        Ok(r) => Ok(r.into_json().unwrap_or(serde_json::json!({}))),
        Err(ureq::Error::Status(code, r)) => {
            let body: serde_json::Value = r.into_json().unwrap_or(serde_json::json!({}));
            let msg = body
                .get("message")
                .and_then(|m| m.as_str())
                .unwrap_or("the service refused the request");
            anyhow::bail!("{msg} (HTTP {code})")
        }
        Err(e) => anyhow::bail!(
            "couldn't reach lymnal's admin surface: {e}. Is the service running? (systemctl status lymnal)"
        ),
    }
}

fn flag(args: &[String], name: &str) -> Option<String> {
    args.iter()
        .position(|a| a == name)
        .and_then(|i| args.get(i + 1).cloned())
}

fn role_str(role: Role) -> &'static str {
    match role {
        Role::Owner => "owner",
        Role::Guest => "guest",
    }
}

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// A time-ordered random-ish id without pulling ulid into this path.
fn ulid_like() -> String {
    let ns = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{ns:x}")
}

fn print_usage() {
    println!(
        "lymnal — the service, and its troubleshooting commands\n\
         (Elyxr does all of this without a terminal)\n\n\
         lymnal                    run the service\n\
         lymnal serve <config>     run the service with a specific config\n\
         lymnal status\n\
         lymnal token list\n\
         lymnal token new <label> [--role owner|guest] [--max-bytes N]\n\
         lymnal token revoke <label>\n\
         lymnal bind open           wait for a device, show its words, ask to approve\n\
         lymnal bind seal           approve the one device that's waiting\n\
         lymnal bind list\n\
         lymnal bind approve <device> [--guest] [--max-bytes N]\n\
         lymnal bind deny <device>\n\
         lymnal bind close\n\
         lymnal trove set <path>\n\
         lymnal recount\n\
         lymnal update              pull the latest and rebuild/restart\n\n\
         --config <path>   use a different config file"
    );
}
