#!/usr/bin/env bash
#
# elyxr.sh — install it, and run it again to update it.
#
#   git clone https://github.com/ryanj97g/Elyxr.git
#   cd Elyxr
#   ./elyxr.sh
#
# First run: installs every toolchain and system library lymnal needs, builds
# the services, puts `lymnal` and `trove` on your PATH, writes a starter config,
# and registers the boot service. Every run after that is an update: it pulls
# the latest, rebuilds only what changed, re-installs a binary only if it
# actually differs, and restarts the service only when its binary changed.
# It checks before it touches anything, so re-running is safe and cheap, and
# stays quiet — the only time it prints detail is IF and WHERE something fails.
#
#   --verbose     watch every command
#   --no-service  build the binaries but don't register/touch the boot service
#   --no-update   skip the self-update git pull (build exactly what's checked out)
#
set -Eeuo pipefail

VERBOSE=0
SERVICE=1
UPDATE=1
for a in "$@"; do
  case "$a" in
    --verbose|-v)  VERBOSE=1 ;;
    --no-service)  SERVICE=0 ;;
    --no-update)   UPDATE=0 ;;
    *) echo "unknown flag: $a (use --verbose, --no-service, --no-update)"; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$HERE/$(basename "${BASH_SOURCE[0]}")"
cd "$HERE"

# Self-update: if this is a git checkout, fast-forward to the latest published
# version before doing anything. If the pull changed anything — including this
# script itself — re-exec the fresh copy once (guarded so it can't loop) so an
# update always runs the newest installer against the newest code.
if [ "$UPDATE" = 1 ] && [ -z "${ELYXR_REEXEC:-}" ] \
   && command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  before="$(git rev-parse HEAD 2>/dev/null || true)"
  # Building can regenerate Cargo.lock; discard that drift so an update can
  # always fast-forward (the committed lockfile is the source of truth).
  git checkout -- Cargo.lock 2>/dev/null || true
  if git pull --ff-only >/dev/null 2>&1; then
    after="$(git rev-parse HEAD 2>/dev/null || true)"
    if [ "$before" != "$after" ]; then
      echo "updated to the latest version — restarting installer..."
      ELYXR_REEXEC=1 exec bash "$SELF" "$@"
    fi
  else
    echo "note: couldn't fast-forward to the latest (local changes?) — building what's checked out."
  fi
fi

LOG="$(mktemp -t elyxr-install.XXXXXX.log)"
CUR="starting"

# Colour only on a real terminal.
if [ -t 1 ]; then
  CYN=$'\033[36m'; GRN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RST=$'\033[0m'
else
  CYN=""; GRN=""; RED=""; DIM=""; RST=""
fi

fail() {
  local code=$?
  printf '%s\n\n' "${RED}x${RST}"
  echo "${RED}elyxr: failed while: ${CUR}${RST}"
  echo "${RED}  command: ${BASH_COMMAND}${RST}"
  echo "${RED}  exit:    ${code}${RST}"
  echo "${DIM}  ---- last lines of output ----${RST}"
  tail -n 30 "$LOG" 2>/dev/null | sed 's/^/  /'
  echo "${DIM}  ------------------------------${RST}"
  echo "  full log kept at: $LOG"
  exit "$code"
}
trap fail ERR

phase() { CUR="$1"; printf '  %s%s%s ... ' "$CYN" "$1" "$RST"; }
done_() { printf '%s\n' "${GRN}ok${RST}"; }

# Run a command quietly (captured to the log); stream it when --verbose.
sh_() {
  if [ "$VERBOSE" = 1 ]; then "$@" 2>&1 | tee -a "$LOG"
  else "$@" >>"$LOG" 2>&1; fi
}

# Ask for sudo once, up front, and hold the grant for the whole run — so a
# long build never gets interrupted by a password prompt (and a fat-fingered
# password fails here, before anything is installed, instead of half-way in).
SUDO_KEEPALIVE=""
cleanup() { [ -n "$SUDO_KEEPALIVE" ] && kill "$SUDO_KEEPALIVE" 2>/dev/null || true; }
trap cleanup EXIT

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
  echo "elyxr needs sudo to install system libraries and register the boot service."
  sudo -v || { echo "${RED}sudo is required — nothing was installed.${RST}"; exit 1; }
  # Refresh the sudo timestamp every 60s until this script exits.
  ( while true; do sudo -n true 2>/dev/null; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) &
  SUDO_KEEPALIVE=$!
fi

# --- system libraries -------------------------------------------------------
# build-essential + pkg-config: C toolchain for rusqlite (bundled) and blake3.
# fuse3 + libfuse3-dev: what trove links against to mount the trove.
phase "system libraries"
command -v apt-get >/dev/null 2>&1 || { echo "needs an apt-based Linux (Ubuntu/Zorin/Debian)"; exit 1; }
SYS_PKGS=(build-essential pkg-config curl git ca-certificates fuse3 libfuse3-dev)
NEED=()
for p in "${SYS_PKGS[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || NEED+=("$p"); done
if [ "${#NEED[@]}" -gt 0 ]; then
  sh_ $SUDO apt-get update
  sh_ $SUDO apt-get install -y "${NEED[@]}"
fi
command -v cc >/dev/null 2>&1 && pkg-config --exists fuse3
done_

# --- rust toolchain ---------------------------------------------------------
# We test that cargo actually *runs*, not merely that it's on PATH: a rustup
# install with no default toolchain leaves a `cargo` shim that exists but
# errors ("could not choose a version of cargo to run"). So:
#   - cargo runs already            -> nothing to do
#   - rustup present, no default    -> pick the stable toolchain
#   - no rust at all                -> install rustup (which sets stable)
phase "rust toolchain"
if ! cargo --version >/dev/null 2>&1; then
  if command -v rustup >/dev/null 2>&1; then
    sh_ rustup default stable
  else
    sh_ bash -c "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path"
  fi
fi
# shellcheck disable=SC1091
[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"
cargo --version >/dev/null 2>&1
done_

# --- build ------------------------------------------------------------------
phase "building lymnal"
sh_ cargo build --release -p lymnal
done_

phase "building trove"
sh_ cargo build --release -p trove
done_

# --- put the commands on PATH ----------------------------------------------
# Only copy a binary if it actually differs from what's installed, and note
# when lymnal changed so we know whether the running service needs a restart.
phase "installing commands"
install_if_changed() {  # $1 built, $2 dest — returns 0 if it (re)installed
  if [ ! -f "$2" ] || ! cmp -s "$1" "$2"; then
    sh_ $SUDO install -m 0755 "$1" "$2"
    return 0
  fi
  return 1
}
LYMNAL_CHANGED=0
if install_if_changed target/release/lymnal /usr/local/bin/lymnal; then LYMNAL_CHANGED=1; fi
if install_if_changed target/release/trove  /usr/local/bin/trove;  then :; fi
done_

# --- starter config ---------------------------------------------------------
phase "configuration"
if [ ! -f "$HOME/.config/lymnal/config.toml" ]; then
  mkdir -p "$HOME/.config/lymnal"
  cp config.example.toml "$HOME/.config/lymnal/config.toml"
fi
done_

# --- boot service -----------------------------------------------------------
# lymnal starts at boot and restarts if it dies. If it keeps dying, it retries
# 5 minutes apart, up to 3 times (~15 minutes), then stops so it isn't burning
# resources on a service that's plainly offline. A service that had been
# running fine and hits one crash gets a fresh 3 attempts (the limit is a
# 30-minute sliding window), so it only gives up on a sustained outage.
INSTALLED_SERVICE=0
if [ "$SERVICE" = 1 ] && command -v systemctl >/dev/null 2>&1; then
  phase "boot service"
  RUNUSER="$(id -un)"
  $SUDO tee /etc/systemd/system/lymnal.service >/dev/null <<UNITEOF
[Unit]
Description=lymnal — serves the trove over your tailnet
Documentation=https://github.com/ryanj97g/Elyxr
After=network-online.target tailscaled.service
Wants=network-online.target
StartLimitIntervalSec=1800
StartLimitBurst=4

[Service]
Type=simple
User=$RUNUSER
ExecStart=/usr/local/bin/lymnal
Restart=on-failure
RestartSec=300

[Install]
WantedBy=multi-user.target
UNITEOF
  sh_ $SUDO systemctl daemon-reload
  # enable makes it start on boot; restart picks up a new binary (and starts it
  # if it was stopped). When nothing changed, enable --now just ensures it's up
  # without a needless restart.
  if [ "$LYMNAL_CHANGED" = 1 ]; then
    sh_ $SUDO systemctl enable lymnal.service
    sh_ $SUDO systemctl restart lymnal.service
  else
    sh_ $SUDO systemctl enable --now lymnal.service
  fi
  INSTALLED_SERVICE=1
  done_
fi

echo
echo "${GRN}Elyxr is installed.${RST}"
if [ "$INSTALLED_SERVICE" = 1 ]; then
  echo "  lymnal is running now and will start on boot."
  echo "  is it up?    systemctl status lymnal"
  echo "  its logs:    journalctl -u lymnal -f"
  echo "  restart it:  sudo systemctl restart lymnal"
else
  echo "  start the server:  lymnal"
  echo "  check it:          lymnal status"
fi
echo "  edit the config:   ~/.config/lymnal/config.toml"
