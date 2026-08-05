//! The same operations as commands, for troubleshooting (§08). Reached as
//! `lymnal <command>`; the service itself is `lymnal` with no command. These
//! call the same code paths as the service and Elyxr's server mode, so the
//! three cannot disagree.

use lymnal::auth::hash_token;
use lymnal::config::{expand_tilde, Config, Role};
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
    println!("bind      {}", cfg.bind);
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
    let base = format!("http://{}", cfg.bind);
    let token = read_admin_token(&cfg.data_dir)?;

    match args.first().map(String::as_str) {
        Some("open") => {
            admin_post(&base, &token, "/v1/admin/pairing", serde_json::json!({ "open": true }))?;
            println!("Ready to bind. Open Elyxr on the other device and request access,");
            println!("then run:  lymnal bind list");
            Ok(())
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
            println!("\nBind it with:  lymnal bind approve <device>");
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
            "usage: lymnal bind open | list | approve <device> [--guest] | deny <device> | close"
        ),
    }
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
         lymnal bind open\n\
         lymnal bind list\n\
         lymnal bind approve <device> [--guest] [--max-bytes N]\n\
         lymnal bind deny <device>\n\
         lymnal bind close\n\
         lymnal trove set <path>\n\
         lymnal recount\n\n\
         --config <path>   use a different config file"
    );
}
