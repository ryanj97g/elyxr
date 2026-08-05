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
  GLD=$'\033[38;5;179m'
else
  CYN=""; GRN=""; RED=""; DIM=""; RST=""; GLD=""
fi

# The lymnal mark, in ASCII, printed in gold when everything succeeds — a small
# terminal splash. Only on a real terminal; skipped on pipes/logs.
splash() {
  [ -t 1 ] || return 0
  [ -f "$HERE/branding/splash.txt" ] || return 0
  printf '\n%s' "$GLD"
  cat "$HERE/branding/splash.txt"
  printf '%s\n' "$RST"
}

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

# Commands live in the user's own bin, and lymnal runs as a user service, so a
# routine update never touches anything owned by root — and never needs a
# password. Admin rights are only needed the first time (system libraries) and
# to migrate off any old system-wide setup and turn on boot-start.
BIN_DIR="$HOME/.local/bin"

SYS_PKGS=(build-essential pkg-config curl git ca-certificates fuse3 libfuse3-dev)
[ "$APP" = 1 ] && SYS_PKGS+=(clang cmake ninja-build libgtk-3-dev liblzma-dev libsecret-1-dev libjsoncpp-dev)
NEED=()
if command -v dpkg >/dev/null 2>&1; then
  for p in "${SYS_PKGS[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || NEED+=("$p"); done
fi

# What still needs root: missing packages, an old system service/binaries to
# clear, or turning on lingering so the user service starts at boot.
OLD_SERVICE=0; [ -f /etc/systemd/system/lymnal.service ] && OLD_SERVICE=1
OLD_BINS=0; { [ -e /usr/local/bin/lymnal ] || [ -e /usr/local/bin/trove ]; } && OLD_BINS=1
LINGER_ON=0
if command -v loginctl >/dev/null 2>&1 \
   && [ "$(loginctl show-user "$(id -un)" --property=Linger --value 2>/dev/null)" = "yes" ]; then
  LINGER_ON=1
fi
NEED_SUDO=0
[ "${#NEED[@]}" -gt 0 ] && NEED_SUDO=1
[ "$OLD_SERVICE" = 1 ] && NEED_SUDO=1
[ "$OLD_BINS" = 1 ] && NEED_SUDO=1
{ [ "$SERVICE" = 1 ] && [ "$LINGER_ON" = 0 ]; } && NEED_SUDO=1

SUDO_KEEPALIVE=""
cleanup() { [ -n "$SUDO_KEEPALIVE" ] && kill "$SUDO_KEEPALIVE" 2>/dev/null || true; }
trap cleanup EXIT

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
elif [ "$NEED_SUDO" = 1 ]; then
  SUDO="sudo"
  echo "elyxr needs your password once for setup. Updates after this won't ask."
  sudo -v || { echo "${RED}sudo is required for setup — nothing was installed.${RST}"; exit 1; }
  ( while true; do sudo -n true 2>/dev/null; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) &
  SUDO_KEEPALIVE=$!
else
  SUDO=""
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
  # Stamp the app with the same build number lymnal carries (git commit count),
  # so a client can tell when it's behind the server and offer to update.
  APP_BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
  APP_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  ( cd elyxr && sh_ flutter config --enable-linux-desktop && sh_ flutter pub get \
      && sh_ flutter build linux --release \
           --dart-define=ELYXR_BUILD="$APP_BUILD" \
           --dart-define=ELYXR_COMMIT="$APP_COMMIT" )
  done_
fi

# --- put the commands on PATH ----------------------------------------------
# Into the user's own bin (no root), so updates never need a password. Only copy
# a binary if it differs, and note when lymnal changed so we know to restart.
phase "installing commands"
mkdir -p "$BIN_DIR"
install_if_changed() {  # $1 built, $2 dest — returns 0 if it (re)installed
  if [ ! -f "$2" ] || ! cmp -s "$1" "$2"; then
    install -m 0755 "$1" "$2"
    return 0
  fi
  return 1
}
LYMNAL_CHANGED=0
if install_if_changed target/release/lymnal "$BIN_DIR/lymnal"; then LYMNAL_CHANGED=1; fi
if install_if_changed target/release/trove  "$BIN_DIR/trove";  then :; fi
# Ensure ~/.local/bin is on PATH now and in future login shells.
case ":$PATH:" in *":$BIN_DIR:"*) ;; *) export PATH="$BIN_DIR:$PATH" ;; esac
for rc in "$HOME/.profile" "$HOME/.bashrc"; do
  [ -f "$rc" ] || continue
  grep -q '.local/bin' "$rc" 2>/dev/null && continue
  printf '\n# elyxr: user-installed commands on PATH\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc"
done
done_

# --- app menu launcher (app only) ------------------------------------------
if [ "$APP" = 1 ]; then
  phase "menu launcher"
  APP_BIN="$HERE/elyxr/build/linux/x64/release/bundle/elyxr"
  APP_ID="com.elyxr.elyxr"   # must match APPLICATION_ID in the native runner
  APPS_DIR="$HOME/.local/share/applications"
  mkdir -p "$APPS_DIR"
  # Install the app icon into the user's icon theme, at every size, under the
  # app id so the desktop can tie the running window to its mark (not just the
  # menu entry). The window's app id is what GNOME matches on.
  ICONS_DIR="$HOME/.local/share/icons/hicolor"
  for sz in 16 32 48 64 128 256 512; do
    src="$HERE/branding/png/elyxr/elyxr-${sz}.png"
    [ -f "$src" ] || continue
    dest="$ICONS_DIR/${sz}x${sz}/apps"
    mkdir -p "$dest"
    cp "$src" "$dest/$APP_ID.png"
  done
  gtk-update-icon-cache -f -t "$ICONS_DIR" 2>/dev/null || true
  # The launcher's filename must match the app id so the window and the entry
  # are recognised as the same app. Remove the old mismatched entry.
  rm -f "$APPS_DIR/elyxr.desktop"
  cat > "$APPS_DIR/$APP_ID.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=elyxr
Comment=Reach your trove from anywhere
Exec=$APP_BIN
Icon=$APP_ID
Terminal=false
Categories=Utility;Network;
StartupWMClass=$APP_ID
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
# lymnal runs as a *user* service (systemctl --user), so starting, stopping, and
# updating it never needs root. It starts at boot via lingering. If it keeps
# dying it retries 5 minutes apart, up to 3 times (~15 min), then gives up so it
# isn't burning resources on a service that's plainly offline; a lone crash after
# healthy uptime gets a fresh 3 attempts (a 30-minute sliding window).
INSTALLED_SERVICE=0
if [ "$SERVICE" = 1 ] && command -v systemctl >/dev/null 2>&1; then
  phase "boot service"
  # One-time migration off the old system-wide setup, if present.
  if [ "$OLD_SERVICE" = 1 ]; then
    sh_ $SUDO systemctl disable --now lymnal.service || true
    sh_ $SUDO rm -f /etc/systemd/system/lymnal.service
    sh_ $SUDO systemctl daemon-reload || true
  fi
  [ "$OLD_BINS" = 1 ] && sh_ $SUDO rm -f /usr/local/bin/lymnal /usr/local/bin/trove

  USER_UNIT="$HOME/.config/systemd/user"
  had_unit=0; [ -f "$USER_UNIT/lymnal.service" ] && had_unit=1
  mkdir -p "$USER_UNIT"
  cat > "$USER_UNIT/lymnal.service" <<UNITEOF
[Unit]
Description=lymnal — serves the trove over your tailnet
Documentation=https://github.com/ryanj97g/elyxr
StartLimitIntervalSec=1800
StartLimitBurst=4

[Service]
Type=simple
ExecStart=$BIN_DIR/lymnal
Restart=on-failure
RestartSec=300

[Install]
WantedBy=default.target
UNITEOF
  sh_ systemctl --user daemon-reload
  # The app decides whether this device serves (server mode → on) or only mounts
  # (client mode → off), so we don't force the service on behind it. First
  # install starts it on (a fresh device is server-capable); later runs only
  # restart it if it's still enabled and its binary changed — a client that
  # turned it off stays off.
  if [ "$had_unit" = 0 ]; then
    sh_ systemctl --user enable --now lymnal.service
    # Start at boot without being logged in (one-time; the only sudo left).
    if [ "$LINGER_ON" = 0 ]; then sh_ $SUDO loginctl enable-linger "$(id -un)" || true; fi
  elif systemctl --user is-enabled --quiet lymnal.service 2>/dev/null; then
    [ "$LYMNAL_CHANGED" = 1 ] && sh_ systemctl --user restart lymnal.service
  fi
  INSTALLED_SERVICE=1
  done_
fi

splash
echo
echo "${GRN}elyxr is ready.${RST}"
echo
if [ "$APP" = 1 ]; then
  echo "  Open it from your apps menu — search \"elyxr\"."
fi
echo "  Update anytime:  lymnal update"
