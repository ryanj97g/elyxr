//! lymnal — one command for the whole service (§10).
//!
//! With no arguments (or `serve`) lymnal runs as the background service. With a
//! subcommand it does the same operations as commands, for troubleshooting —
//! setup never requires a terminal, and Elyxr calls the same code paths so the
//! two cannot disagree.
//!
//!   lymnal                    run the service (config: ~/.config/lymnal/config.toml)
//!   lymnal serve [config]     run the service with a specific config
//!   lymnal status
//!   lymnal token list | new <label> [--role owner|guest] [--max-bytes N] | revoke <label>
//!   lymnal trove set <path>
//!   lymnal recount

mod cli;

use std::path::PathBuf;
use std::time::Duration;

use lymnal::config::{expand_tilde, Config};
use lymnal::devices::DeviceStore;
use lymnal::events::watch_trove;
use lymnal::limits::Usage;
use lymnal::state::AppState;
use lymnal::trove::Trove;
use lymnal::upload::UploadManager;

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        // Troubleshooting commands.
        Some("status") | Some("token") | Some("trove") | Some("bind") | Some("recount")
        | Some("update") | Some("help") | Some("-h") | Some("--help") => cli::run(&args),
        // Explicitly run the service.
        Some("serve") => run_service(daemon_config(&args[1..])),
        // No command (or a bare config path) runs the service.
        _ => run_service(daemon_config(&args)),
    }
}

/// The config path for the service: first argument, then `LYMNAL_CONFIG`, then
/// the default.
fn daemon_config(args: &[String]) -> PathBuf {
    args.first()
        .cloned()
        .or_else(|| std::env::var("LYMNAL_CONFIG").ok())
        .map(expand_tilde)
        .unwrap_or_else(|| expand_tilde("~/.config/lymnal/config.toml"))
}

/// Build a runtime and run the service to shutdown.
fn run_service(config_path: PathBuf) -> anyhow::Result<()> {
    let rt = tokio::runtime::Runtime::new()?;
    rt.block_on(serve(config_path))
}

async fn serve(config_path: PathBuf) -> anyhow::Result<()> {
    let cfg = match Config::load(&config_path) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("lymnal can't start: {e}");
            std::process::exit(1);
        }
    };

    init_tracing(&cfg.log_level);

    if let Err(e) = cfg.prepare_dirs() {
        // A path that is a file or is not writable stops startup with a message
        // naming the path and the problem (§02).
        eprintln!("lymnal can't start: {e}");
        std::process::exit(1);
    }

    let trove = Trove::open(&cfg.trove.path, cfg.trove.follow_symlinks)?;
    let usage = Usage::open(&cfg.data_dir, cfg.limits.clone(), trove.root().to_path_buf())?;
    let uploads = UploadManager::new(&cfg.data_dir, cfg.upload.chunk_bytes, cfg.upload.stale_after_hrs);
    let devices = DeviceStore::open(&cfg.data_dir)?;
    let bind = cfg.bind.clone();
    let data_dir = cfg.data_dir.clone();
    let mut state = AppState::new(cfg, trove, usage, uploads, devices);
    state.with_config_path(config_path.clone());

    // The local admin token lets server-mode Elyxr on this machine reach the
    // admin surface. Written user-only; never sent over the tailnet.
    write_admin_token(&data_dir, &state.admin_token);

    // Watch the trove so changes made directly on the server are announced.
    let _watcher = match watch_trove(state.trove.root().to_path_buf(), state.events.clone()) {
        Ok(w) => Some(w),
        Err(e) => {
            tracing::warn!(error = %e, "could not watch the trove for changes");
            None
        }
    };

    spawn_maintenance(state.clone());

    let app = lymnal::handlers::router(state.clone());

    let listener = match tokio::net::TcpListener::bind(&bind).await {
        Ok(l) => {
            state.set_bound(true);
            l
        }
        Err(e) => {
            // lymnal binds to the Tailscale address only; if it is not up yet,
            // report and exit — Elyxr restarts the service once Tailscale is up.
            eprintln!("lymnal can't bind to {bind}: {e}");
            eprintln!("If this is the Tailscale address, it will exist once Tailscale is connected.");
            std::process::exit(1);
        }
    };

    tracing::info!(%bind, "lymnal listening");
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await?;
    Ok(())
}

fn init_tracing(level: &str) {
    use tracing_subscriber::EnvFilter;
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new(level));
    let _ = tracing_subscriber::fmt().with_env_filter(filter).try_init();
}

/// Background upkeep: sweep abandoned uploads hourly, and recount the trove at
/// startup drift and daily (the spec's 4am recount; a 24 h tick is close
/// enough without wall-clock scheduling in v1).
fn spawn_maintenance(state: lymnal::Shared) {
    let s = state.clone();
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_secs(3600));
        loop {
            tick.tick().await;
            s.uploads.sweep();
        }
    });
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_secs(24 * 3600));
        tick.tick().await; // consume the immediate first tick
        loop {
            tick.tick().await;
            if let Err(e) = state.usage.recount() {
                tracing::warn!(error = %e, "recount failed");
            }
        }
    });
}

/// Write the admin token where server-mode Elyxr on this machine can read it,
/// user-only (0600). Never sent over the network.
fn write_admin_token(data_dir: &std::path::Path, token: &str) {
    use std::os::unix::fs::PermissionsExt;
    let path = data_dir.join("admin.token");
    if std::fs::write(&path, token).is_ok() {
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    }
}

async fn shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
    tracing::info!("shutting down");
}
