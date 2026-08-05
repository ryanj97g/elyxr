#!/usr/bin/env bash
#
# elyxr.sh — install it, and run it again to update it.
#
#   git clone https://github.com/ryanj97g/elyxr.git
#   cd elyxr
#   ./elyxr.sh
#
# Installs the whole stack on this device: lymnal (the service that can serve a
# folder over your tailnet), trove (the client-side mount), and the elyxr app
# (the UI). Every device gets all three — the app's Server/Client toggle decides
# what this device actually does. Running it again is an update: pull, rebuild
# only what changed, re-install a binary only if it differs, and restart the
# service only when its binary changed. Quiet unless something fails.
#
#   --no-app      skip the GUI app (for a headless server with no display)
#   --no-service  don't register/touch the lymnal boot service
#   --no-update   skip the self-update git pull (build exactly what's checked out)
#   --verbose     watch every command
#
set -Eeuo pipefail

VERBOSE=0
SERVICE=1
UPDATE=1
APP=1
for a in "$@"; do
  case "$a" in
    --no-app)      APP=0 ;;
    --no-service)  SERVICE=0 ;;
    --no-update)   UPDATE=0 ;;
    --verbose|-v)  VERBOSE=1 ;;
    *) echo "unknown flag: $a (use --no-app, --no-service, --no-update, --verbose)"; exit 2 ;;
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
  echo "elyxr needs sudo to install libraries, the app, and the boot service."
  sudo -v || { echo "${RED}sudo is required — nothing was installed.${RST}"; exit 1; }
  ( while true; do sudo -n true 2>/dev/null; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) &
  SUDO_KEEPALIVE=$!
fi

# Record where the repo lives so `lymnal update` can find and re-run this
# installer later without being told the path.
mkdir -p "$HOME/.config/lymnal"
printf '%s\n' "$HERE" > "$HOME/.config/lymnal/repo.path"

# --- system libraries -------------------------------------------------------
# lymnal/trove need a C toolchain (rusqlite/blake3) and FUSE. The app adds the
# GTK/clang/etc. build deps unless --no-app.
phase "system libraries"
command -v apt-get >/dev/null 2>&1 || { echo "needs an apt-based Linux (Ubuntu/Zorin/Debian)"; exit 1; }
SYS_PKGS=(build-essential pkg-config curl git ca-certificates fuse3 libfuse3-dev)
if [ "$APP" = 1 ]; then
  SYS_PKGS+=(clang cmake ninja-build libgtk-3-dev liblzma-dev libsecret-1-dev libjsoncpp-dev)
fi
NEED=()
for p in "${SYS_PKGS[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || NEED+=("$p"); done
if [ "${#NEED[@]}" -gt 0 ]; then
  sh_ $SUDO apt-get update
  sh_ $SUDO apt-get install -y "${NEED[@]}"
fi
command -v cc >/dev/null 2>&1 && pkg-config --exists fuse3
done_

# --- rust toolchain ---------------------------------------------------------
# Test that cargo actually *runs* (a rustup shim with no default toolchain
# exists but errors); install or set the stable toolchain as needed.
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

# --- flutter sdk (app only) -------------------------------------------------
if [ "$APP" = 1 ]; then
  phase "flutter sdk"
  # Flutter isn't an apt package, so if it's missing we clone the stable SDK
  # ourselves (into ~/.local/share/flutter) and put it on PATH for the build.
  # It's only needed to build — the finished app binary is self-contained.
  if ! command -v flutter >/dev/null 2>&1; then
    FLUTTER_DIR="$HOME/.local/share/flutter"
    [ -x "$FLUTTER_DIR/bin/flutter" ] || sh_ git clone --depth 1 -b stable https://github.com/flutter/flutter.git "$FLUTTER_DIR"
    export PATH="$FLUTTER_DIR/bin:$PATH"
  fi
  sh_ flutter --version
  done_
fi

# --- build ------------------------------------------------------------------
phase "building lymnal"
sh_ cargo build --release -p lymnal
done_

phase "building trove"
sh_ cargo build --release -p trove
done_

if [ "$APP" = 1 ]; then
  phase "building the app"
  ( cd elyxr && sh_ flutter config --enable-linux-desktop && sh_ flutter pub get && sh_ flutter build linux --release )
  done_
fi

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

# --- app menu launcher (app only) ------------------------------------------
if [ "$APP" = 1 ]; then
  phase "menu launcher"
  APP_BIN="$HERE/elyxr/build/linux/x64/release/bundle/elyxr"
  APPS_DIR="$HOME/.local/share/applications"
  mkdir -p "$APPS_DIR"
  cat > "$APPS_DIR/elyxr.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=elyxr
Comment=Reach your trove from anywhere
Exec=$APP_BIN
Terminal=false
Categories=Utility;Network;
StartupWMClass=elyxr
DESKTOP
  update-desktop-database "$APPS_DIR" 2>/dev/null || true
  done_
fi

# --- starter config ---------------------------------------------------------
phase "configuration"
if [ ! -f "$HOME/.config/lymnal/config.toml" ]; then
  cp config.example.toml "$HOME/.config/lymnal/config.toml"
fi
done_

# --- boot service -----------------------------------------------------------
# lymnal starts at boot and restarts if it dies. If it keeps dying, it retries
# 5 minutes apart, up to 3 times (~15 minutes), then stops so it isn't burning
# resources on a service that's plainly offline. A service that had been running
# fine and hits one crash gets a fresh 3 attempts (a 30-minute sliding window),
# so it only gives up on a sustained outage.
INSTALLED_SERVICE=0
if [ "$SERVICE" = 1 ] && command -v systemctl >/dev/null 2>&1; then
  phase "boot service"
  RUNUSER="$(id -un)"
  $SUDO tee /etc/systemd/system/lymnal.service >/dev/null <<UNITEOF
[Unit]
Description=lymnal — serves the trove over your tailnet
Documentation=https://github.com/ryanj97g/elyxr
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
  # if it was stopped). When nothing changed, enable --now just ensures it's up.
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
echo "${GRN}elyxr is installed.${RST}"
if [ "$APP" = 1 ]; then
  echo "  Open elyxr from your applications menu — search \"elyxr\"."
  echo "  In the app: hold the wordmark for settings, then flip THIS DEVICE"
  echo "  to SERVER (share a folder) or CLIENT (browse another device)."
fi
if [ "$INSTALLED_SERVICE" = 1 ]; then
  echo "  lymnal runs in the background and starts on boot (systemctl status lymnal)."
fi
echo "  update later with:  lymnal update"
