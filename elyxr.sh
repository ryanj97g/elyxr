#!/usr/bin/env bash
#
# elyxr.sh — clone the repo, run this, done.
#
#   git clone https://github.com/ryanj97g/Elyxr.git
#   cd Elyxr
#   ./elyxr.sh
#
# It installs every toolchain and system library lymnal needs, builds the
# services, puts `lymnal` and `trove` on your PATH, and drops a starter config
# in place. It checks before it touches anything, so re-running is safe and
# cheap. It stays quiet: the only time it prints detail is IF and WHERE
# something fails. Pass --verbose to watch every command.
#
set -Eeuo pipefail

VERBOSE=0
SERVICE=1
for a in "$@"; do
  case "$a" in
    --verbose|-v)  VERBOSE=1 ;;
    --no-service)  SERVICE=0 ;;
    *) echo "unknown flag: $a (use --verbose and/or --no-service)"; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

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

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

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
phase "rust toolchain"
if ! command -v cargo >/dev/null 2>&1; then
  sh_ bash -c "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path"
fi
# shellcheck disable=SC1091
[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"
command -v cargo >/dev/null 2>&1
done_

# --- build ------------------------------------------------------------------
phase "building lymnal"
sh_ cargo build --release -p lymnal
done_

phase "building trove"
sh_ cargo build --release -p trove
done_

# --- put the commands on PATH ----------------------------------------------
phase "installing commands"
sh_ $SUDO install -m 0755 target/release/lymnal /usr/local/bin/lymnal
sh_ $SUDO install -m 0755 target/release/trove  /usr/local/bin/trove
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
  sh_ $SUDO systemctl enable --now lymnal.service
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
