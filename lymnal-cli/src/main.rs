//! lymnal-cli — the same operations as commands, for troubleshooting only.
//! Setup never requires a terminal; these call the same lymnal code paths so
//! the CLI and Elyxr's server mode cannot disagree.
//!
//!   lymnal status
//!   lymnal token list
//!   lymnal token new <label> [--role owner|guest] [--max-bytes N]
//!   lymnal token revoke <label>
//!   lymnal trove set <path>
//!   lymnal recount
//!
//! A different config file: LYMNAL_CONFIG=... or --config <path>.

use lymnal::auth::hash_token;
use lymnal::config::{expand_tilde, Config, Role};
use lymnal::devices::{DeviceRecord, DeviceStore};
use lymnal::limits::Usage;

fn main() {
    if let Err(e) = run() {
        eprintln!("lymnal: {e}");
        std::process::exit(1);
    }
}

fn run() -> anyhow::Result<()> {
    let mut args: Vec<String> = std::env::args().skip(1).collect();

    // Optional --config <path> anywhere.
    let mut config_path = std::env::var("LYMNAL_CONFIG")
        .ok()
        .map(expand_tilde)
        .unwrap_or_else(|| expand_tilde("~/.config/lymnal/config.toml"));
    if let Some(i) = args.iter().position(|a| a == "--config") {
        config_path = expand_tilde(args.remove(i + 1));
        args.remove(i);
    }

    let cmd = args.first().map(String::as_str).unwrap_or("");
    match cmd {
        "status" => status(&config_path),
        "recount" => recount(&config_path),
        "token" => token(&config_path, &args[1..]),
        "trove" => trove(&config_path, &args[1..]),
        "" | "help" | "-h" | "--help" => {
            print_usage();
            Ok(())
        }
        other => {
            anyhow::bail!("unknown command '{other}'. Try: lymnal help");
        }
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
                .ok_or_else(|| anyhow::anyhow!("usage: lymnal token new <label> [--role owner|guest] [--max-bytes N]"))?
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

fn flag(args: &[String], name: &str) -> Option<String> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1).cloned())
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

/// A time-ordered random-ish id without pulling ulid into this crate.
fn ulid_like() -> String {
    let ns = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{ns:x}")
}

fn print_usage() {
    println!(
        "lymnal — troubleshooting commands (Elyxr does all of this without a terminal)\n\n\
         lymnal status\n\
         lymnal token list\n\
         lymnal token new <label> [--role owner|guest] [--max-bytes N]\n\
         lymnal token revoke <label>\n\
         lymnal trove set <path>\n\
         lymnal recount\n\n\
         --config <path>   use a different config file"
    );
}
