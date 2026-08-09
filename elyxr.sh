#!/usr/bin/env bash
#
# elyxr.sh — install it, and run it again to update it.
#
#   git clone https://github.com/ryanj97g/elyxr.git
#   cd elyxr
#   ./elyxr.sh
#
# Installs the whole stack on this device: lymnal (the service that can serve a
# folder over your tailnet), gate (the optional client-side folder mount), and the elyxr app
# (the UI). Every device gets all three — the app's Server/Client toggle decides
# what this device actually does. Running it again is an update: pull, rebuild
# only what changed, re-install a binary only if it differs, and restart the
# service only when its binary changed. Quiet unless something fails.
#
#   --no-app        skip the GUI app (for a headless server with no display)
#   --no-service    don't register/touch the lymnal boot service
#   --no-update     skip the self-update git pull (build exactly what's checked out)
#   --no-tailscale  skip the Tailscale install/sign-in step (you'll set it up yourself)
#   --verbose       watch every command
#
set -Eeuo pipefail

VERBOSE=0
SERVICE=1
UPDATE=1
APP=1
TAILSCALE=1
for a in "$@"; do
  case "$a" in
    --no-app)        APP=0 ;;
    --no-service)    SERVICE=0 ;;
    --no-update)     UPDATE=0 ;;
    --no-tailscale)  TAILSCALE=0 ;;
    --verbose|-v)    VERBOSE=1 ;;
    *) echo "unknown flag: $a (use --no-app, --no-service, --no-update, --no-tailscale, --verbose)"; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$HERE/$(basename "${BASH_SOURCE[0]}")"
cd "$HERE"

# Two desktop notifications, so an update the background agent runs is visible
# even with no terminal open and the elyxr window closed: one when it starts, one
# when it's done, wearing the lymnal mark. notify-send hands them to the desktop's
# notification daemon; with no daemon (a headless server) each is a silent no-op,
# and a cosmetic popup must never break an update, so failure is swallowed. Only
# shown for an *update*, never a first install (there's a terminal for that) —
# HAD_LYMNAL is how we tell them apart.
NOTIFY_ICON="com.elyxr.lymnal"
HAD_LYMNAL=0; [ -x "$HOME/.local/bin/lymnal" ] && HAD_LYMNAL=1
notify() {  # $1 body
  [ "$HAD_LYMNAL" = 1 ] || return 0
  command -v notify-send >/dev/null 2>&1 || return 0
  notify-send -a lymnal -i "$NOTIFY_ICON" -h "string:desktop-entry:$NOTIFY_ICON" \
    "lymnal" "$1" >/dev/null 2>&1 || true
}

# The start popup fires the instant an update begins — before the pull. Guarded
# to the pre-re-exec instance so a self-update that restarts this script doesn't
# show it twice.
[ -z "${ELYXR_REEXEC:-}" ] && notify "Updating in the background…"

# Self-update: if this is a git checkout, fast-forward to the latest published
# version before doing anything. If the pull changed anything — including this
# script itself — re-exec the fresh copy once (guarded so it can't loop) so an
# update always runs the newest installer against the newest code.
if [ "$UPDATE" = 1 ] && [ -z "${ELYXR_REEXEC:-}" ] \
   && command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  before="$(git rev-parse HEAD 2>/dev/null || true)"
  # Building regenerates tracked artifacts — Cargo.lock, but also Flutter's
  # pubspec.lock and linux/windows generated_plugins.cmake — which dirties the
  # tree and blocks a fast-forward, so updates silently rebuild stale code.
  # Discard all tracked drift (the committed versions are the source of truth);
  # untracked files, like dropped music/sounds, are left untouched.
  git checkout -- . 2>/dev/null || true
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
  [ "$branch" = "HEAD" ] && branch=main
  if git pull --ff-only >/dev/null 2>&1; then
    after="$(git rev-parse HEAD 2>/dev/null || true)"
    if [ "$before" != "$after" ]; then
      echo "updated to the latest version — restarting installer..."
      ELYXR_REEXEC=1 exec bash "$SELF" "$@"
    fi
  elif git fetch origin "$branch" >/dev/null 2>&1 \
       && git reset --hard "origin/$branch" >/dev/null 2>&1; then
    # A fast-forward is impossible when upstream history was rewritten (a
    # force-push) — the local checkout has diverged and would otherwise build
    # stale code forever. Reset hard to the published branch to recover. This
    # only touches tracked files; untracked drops (music/sounds) are left alone.
    after="$(git rev-parse HEAD 2>/dev/null || true)"
    if [ "$before" != "$after" ]; then
      echo "history had diverged from upstream — reset to the latest published build, restarting installer..."
      ELYXR_REEXEC=1 exec bash "$SELF" "$@"
    fi
  else
    echo "note: couldn't reach the latest (offline?) — building what's checked out."
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

# The packages are split in two so the handful that Tailscale needs in order to
# install itself (a downloader and the certificates that verify its download)
# go on first, before the Tailscale step. The heavier build tools follow it.
BASE_PKGS=(curl ca-certificates)
BUILD_PKGS=(build-essential pkg-config git fuse3 libfuse3-dev)
# The app plays audio through audioplayers, which on Linux uses the system's
# GStreamer: the -dev packages are needed to build the plugin, and the runtime
# plugin sets (base/good + libav) provide the codecs so mp3/ogg/flac/etc. play
# with the OS's own libraries — no bundled codec libs, so none of the glibc
# mismatch that made the previous engine fail to load. openmpt123 renders tracker
# modules (.xm/.mod/.s3m/.it) to PCM. ffmpeg decodes the current track to raw PCM
# so the visualizer can analyse it into a spectrogram (the bars are read off the
# play head — the real FFT of the real audio, with no capture lag).
# libasound2-dev: Flutter builds every plugin in the resolved dependency tree,
# and a transitive one (volume_controller) does find_package(ALSA) in its Linux
# CMake, which fails without the ALSA dev headers even though we don't use it.
# libmpv-dev: media_kit (inline video preview) links the system libmpv on Linux
# (it only bundles mpv on Windows/Android), so its plugin needs mpv's pkg-config.
[ "$APP" = 1 ] && BUILD_PKGS+=(clang cmake ninja-build libgtk-3-dev liblzma-dev libsecret-1-dev libjsoncpp-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-libav libasound2-dev libmpv-dev openmpt123 ffmpeg)
BASE_NEED=(); BUILD_NEED=()
if command -v dpkg >/dev/null 2>&1; then
  for p in "${BASE_PKGS[@]}";  do dpkg -s "$p" >/dev/null 2>&1 || BASE_NEED+=("$p"); done
  for p in "${BUILD_PKGS[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || BUILD_NEED+=("$p"); done
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
# Tailscale is how devices reach each other. If it isn't installed, or is
# installed but not connected to a tailnet, this run has to install it and/or
# walk you through signing in — both need root.
TS_NEED=0
if [ "$TAILSCALE" = 1 ]; then
  if ! command -v tailscale >/dev/null 2>&1; then
    TS_NEED=1
  elif ! tailscale ip -4 >/dev/null 2>&1; then
    TS_NEED=1
  fi
fi

NEED_SUDO=0
{ [ "${#BASE_NEED[@]}" -gt 0 ] || [ "${#BUILD_NEED[@]}" -gt 0 ]; } && NEED_SUDO=1
[ "$OLD_SERVICE" = 1 ] && NEED_SUDO=1
[ "$OLD_BINS" = 1 ] && NEED_SUDO=1
[ "$TS_NEED" = 1 ] && NEED_SUDO=1
{ [ "$SERVICE" = 1 ] && [ "$LINGER_ON" = 0 ]; } && NEED_SUDO=1

SUDO_KEEPALIVE=""
cleanup() { [ -n "$SUDO_KEEPALIVE" ] && kill "$SUDO_KEEPALIVE" 2>/dev/null || true; }
trap cleanup EXIT

# Decide whether we have root — or can get it *without ever hanging*. This is the
# heart of the fix. A routine update needs no root at all, so it skips this
# whole dance. When a root step IS needed, a background/tray/fleet update runs
# detached with no terminal to type a password into, so it must never block on
# sudo (that ~2-second hang was aborting every such update). We only prompt when
# stdin is a real terminal — i.e. a direct `./elyxr.sh` run.
# A terminal we can actually type into — not just one that's attached. A detached
# update (tray button, `lymnal update`, fleet) can have a tty on its stdin yet not
# be that tty's foreground process group, so a password read fails instantly with
# an I/O error (the very thing that broke those updates: sudo printed a prompt it
# could never read). Compare our process group to the terminal's foreground group;
# only a match is safe to prompt on. If the groups can't be read, fall back to the
# plain check rather than lock ourselves out of an SSH session.
_fg_tty() {
  [ -t 0 ] || return 1
  local tpgid pgid
  tpgid=$(ps -o tpgid= -p $$ 2>/dev/null | tr -d ' ')
  pgid=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
  { [ -z "$tpgid" ] || [ -z "$pgid" ]; } && return 0
  [ "$tpgid" = "$pgid" ]
}

SUDO=""
CAN_SUDO=1
if [ "$NEED_SUDO" = 1 ]; then
  CAN_SUDO=0
  if [ "$(id -u)" -eq 0 ]; then
    CAN_SUDO=1
  elif sudo -n true 2>/dev/null; then
    CAN_SUDO=1; SUDO="sudo"         # root with no prompt (cached creds / NOPASSWD)
  elif _fg_tty; then
    echo "elyxr needs your password once for setup. Updates after this won't ask."
    if sudo -v; then
      CAN_SUDO=1; SUDO="sudo"
      ( while true; do sudo -n true 2>/dev/null; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) &
      SUDO_KEEPALIVE=$!
    fi
  elif command -v pkexec >/dev/null 2>&1 && { [ -n "$DISPLAY" ] || [ -n "$WAYLAND_DISPLAY" ]; }; then
    # No usable terminal, but there's a graphical session: ask through polkit,
    # which pops the real system password dialog. This is the path a detached
    # update takes — it needs no tty. The one-time system packages go in as a
    # single elevated step, so it asks once, not once per package.
    echo "elyxr needs your password for a one-time setup step — a system dialog will appear."
    _pk=( "${BASE_NEED[@]}" "${BUILD_NEED[@]}" )
    if [ "${#_pk[@]}" -gt 0 ]; then
      if pkexec /bin/sh -c "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Use-Pty=0 ${_pk[*]}"; then
        CAN_SUDO=1; SUDO="pkexec"; BASE_NEED=(); BUILD_NEED=()   # packages done; later phases skip
      fi
    else
      CAN_SUDO=1; SUDO="pkexec"     # root needed for a non-package step (service, linger)
    fi
  fi
  # A root step is needed but we couldn't get root here (a detached update, no
  # terminal). Do NOT abort — that abort is what broke the tray button, `lymnal
  # update`, and the fleet update. Instead: do everything that doesn't need root
  # (pull, rebuild, install the user-space binaries, reopen the app), turn every
  # "$SUDO <root cmd>" into a harmless no-op (":"), and tell the user once that a
  # one-time terminal run is still pending for the root-only part (system packages).
  if [ "$CAN_SUDO" = 0 ]; then
    SUDO=":"
    echo "${RED}A one-time setup step needs a password; skipping it for now.${RST}"
    echo "Run ${GRN}./elyxr.sh${RST} in a terminal once to finish it."
    notify "elyxr updated. One-time setup pending — run ./elyxr.sh in a terminal once."
  fi
fi

# Record where the repo lives so `lymnal update` can find and re-run this
# installer later without being told the path.
mkdir -p "$HOME/.config/lymnal"
printf '%s\n' "$HERE" > "$HOME/.config/lymnal/repo.path"

# --- base packages ----------------------------------------------------------
# A downloader and the certificates that verify its downloads, which Tailscale
# needs to fetch and check its own installer. These are installed first so the
# Tailscale step can run early, before the long build.
phase "base packages"
command -v apt-get >/dev/null 2>&1 || { echo "elyxr needs an apt-based Linux, such as Ubuntu, Zorin, or Debian."; exit 1; }
if [ "${#BASE_NEED[@]}" -gt 0 ] || [ "${#BUILD_NEED[@]}" -gt 0 ]; then
  sh_ $SUDO apt-get update
fi
if [ "${#BASE_NEED[@]}" -gt 0 ]; then
  sh_ $SUDO apt-get install -y -o Dpkg::Use-Pty=0 "${BASE_NEED[@]}"
fi
done_

# --- tailscale --------------------------------------------------------------
# elyxr reaches your other devices over Tailscale, a private network meant only
# for them, so nothing is exposed to the open internet. Installing the software
# is automatic, but connecting this machine to your network requires you to sign
# in once in a browser, which no installer can do on your behalf. This step runs
# early, so the one part that needs you is finished before the long build
# begins, and it stays silent on every run once you are connected.
if [ "$TAILSCALE" = 1 ]; then
  phase "tailscale"
  if ! command -v tailscale >/dev/null 2>&1; then
    sh_ bash -c "curl -fsSL https://tailscale.com/install.sh | $SUDO sh"
  fi
  if tailscale ip -4 >/dev/null 2>&1; then
    done_                                   # already connected, so there is nothing to do
  else
    printf '\n'                             # end the "tailscale ... " line
    echo "  ${CYN}Connect this device to your Tailscale network.${RST}"
    echo "  A sign-in link will appear just below. Open it in a browser and sign in."
    echo "  ${DIM}Sign in with the same account on every device, because that is what lets them find each other.${RST}"
    echo
    $SUDO tailscale up                      # prints the link, then waits for you to sign in
    echo
    if tailscale ip -4 >/dev/null 2>&1; then
      echo "  ${GRN}Connected.${RST} This device is $(tailscale ip -4 | head -n1) on your tailnet."
    else
      echo "${RED}Tailscale is not connected yet. Run 'sudo tailscale up', finish the"
      echo "sign-in in your browser, then run elyxr.sh again.${RST}"
      exit 1
    fi
  fi
fi

# --- build tools ------------------------------------------------------------
# lymnal needs a C toolchain (for rusqlite and blake3). The app adds the GTK and
# related build dependencies unless you pass --no-app. FUSE is only for the
# optional gate; it isn't checked here, so a machine without it still installs
# elyxr fully — the gate just won't build.
phase "build tools"
if [ "${#BUILD_NEED[@]}" -gt 0 ]; then
  sh_ $SUDO apt-get install -y -o Dpkg::Use-Pty=0 "${BUILD_NEED[@]}"
fi
command -v cc >/dev/null 2>&1
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
# The build stamp (git commit count) is computed here, once, and handed to both
# lymnal (as an env var build.rs reads) and the app (as a dart-define). Passing
# it in — rather than letting build.rs rediscover it from git — guarantees the
# stamp advances on every update, even a docs- or Dart-only one, so a client's
# "am I behind the server?" check is reliable and doesn't depend on cargo
# noticing a moved git ref.
export ELYXR_BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
export ELYXR_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

phase "building lymnal"
sh_ cargo build --release -p lymnal
done_

# The gate (the optional file-browser mount) is best-effort: it's a Linux-only
# FUSE extra, and a build failure must never block the app or an update. elyxr
# works fully without it.
GATE_BUILT=0
phase "building gate"
if sh_ cargo build --release -p gate; then
  GATE_BUILT=1
  done_
else
  printf '%s\n' "${DIM}skipped — the optional file-browser mount didn't build; elyxr works without it${RST}"
fi

if [ "$APP" = 1 ]; then
  phase "building the app"
  # Flutter's incremental build cache can go stale across an update: it reports
  # success while leaving the compiled Dart (build/.../lib/libapp.so) on the old
  # build — so an update says "ok" while nothing changes on screen. When the
  # checked-out commit differs from the last one built, force a fresh Dart
  # compile — but NOT with `flutter clean`, which deletes build/ (the working
  # binary and all). If the new build then failed (a bad commit), clean would
  # leave no app at all. Instead drop only Flutter's assemble cache: that forces
  # the recompile while the last good bundle stays put until the new one
  # overwrites it, so a failed build can never brick the installed app.
  DART_STAMP="elyxr/build/.elyxr-built-commit"
  if [ "$(cat "$DART_STAMP" 2>/dev/null || true)" != "$ELYXR_COMMIT" ]; then
    rm -rf elyxr/.dart_tool/flutter_build 2>/dev/null || true
  fi
  # Build the app (carrying the same build number lymnal does). If it fails only
  # because a plugin needs a system -dev header that isn't installed, don't let a
  # hand-maintained package list be the thing that breaks: a plugin bump changes
  # what's needed, and a stale list dies with a cryptic "file not found". Instead,
  # on that specific failure, find the package that owns the missing header with
  # apt-file, install it, and retry — the dependency heals itself. (The toolchain
  # baseline still has to be present up front; you need a compiler before you can
  # compile. This covers the per-plugin libraries on top of it.)
  BUILD_LOG="$(mktemp -t elyxr-appbuild.XXXXXX.log)"
  build_app() {
    local rc
    ( cd elyxr && flutter config --enable-linux-desktop && flutter pub get \
        && flutter build linux --release \
             --dart-define=ELYXR_BUILD="$ELYXR_BUILD" \
             --dart-define=ELYXR_COMMIT="$ELYXR_COMMIT" ) >"$BUILD_LOG" 2>&1
    rc=$?
    cat "$BUILD_LOG" >>"$LOG"
    return $rc
  }
  app_tries=0
  until build_app; do
    app_tries=$((app_tries + 1))
    # Headers this attempt's compile couldn't find (clang and gcc word it
    # differently); empty if it failed for some other reason.
    miss="$(grep -oE "'[A-Za-z0-9_./+-]+\.h' file not found|[A-Za-z0-9_./+-]+\.h: No such file" "$BUILD_LOG" 2>/dev/null \
             | grep -oE "[A-Za-z0-9_./+-]+\.h" | sort -u || true)"
    if [ -z "$miss" ] || [ "$app_tries" -gt 3 ]; then
      echo "${RED}the app build failed — full output at $BUILD_LOG${RST}"
      false  # hand off to the error trap; the log is kept
    fi
    # apt-file maps a file path back to the package that ships it. Install it (and
    # its index) the first time we need it.
    if ! command -v apt-file >/dev/null 2>&1; then
      sudo -v || { echo "${RED}need sudo to install a missing build dependency${RST}"; false; }
      sh_ $SUDO apt-get install -y -o Dpkg::Use-Pty=0 apt-file
      sh_ $SUDO apt-file update
    fi
    pkgs=""
    for h in $miss; do
      p="$(apt-file search --package-only "$h" 2>/dev/null | head -n1 || true)"
      [ -n "$p" ] && pkgs="$pkgs $p"
    done
    if [ -z "$pkgs" ]; then
      echo "${RED}couldn't find a package providing:$miss${RST}"
      false
    fi
    echo "  a plugin needs a system library — installing:$pkgs"
    sudo -v || { echo "${RED}need sudo to install:$pkgs${RST}"; false; }
    sh_ $SUDO apt-get install -y -o Dpkg::Use-Pty=0 $pkgs
  done
  rm -f "$BUILD_LOG"
  mkdir -p "$(dirname "$DART_STAMP")"
  printf '%s\n' "$ELYXR_COMMIT" > "$DART_STAMP"
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
if [ "$GATE_BUILT" = 1 ] && install_if_changed target/release/gate "$BIN_DIR/gate"; then :; fi
rm -f "$BIN_DIR/trove"  # old name for the mount, now 'gate'
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
    dest="$ICONS_DIR/${sz}x${sz}/apps"
    mkdir -p "$dest"
    # The app's own mark, under its app id (ties the running window to it).
    src="$HERE/branding/png/elyxr/elyxr-${sz}.png"
    [ -f "$src" ] && cp "$src" "$dest/$APP_ID.png"
    # The lymnal mark, so the service's tray icon and its update popups wear it.
    lsrc="$HERE/branding/png/lymnal/lymnal-${sz}.png"
    [ -f "$lsrc" ] && cp "$lsrc" "$dest/com.elyxr.lymnal.png"
  done
  gtk-update-icon-cache -f -t "$ICONS_DIR" 2>/dev/null || true
  # The launcher's filename must match the app id so the window and the entry
  # are recognised as the same app. Remove the old mismatched entry.
  rm -f "$APPS_DIR/elyxr.desktop"
  # On X11, GTK capitalises the window's class (WM_CLASS = "com.elyxr.elyxr",
  # "Com.elyxr.elyxr"), and the taskbar matches on that capitalised class — so
  # StartupWMClass has to be the capitalised form or the window falls back to a
  # generic tile. On Wayland the match is by the .desktop's name, so this is
  # harmless there.
  WMCLASS="${APP_ID^}"
  cat > "$APPS_DIR/$APP_ID.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=elyxr
Comment=Reach your trove from anywhere
Exec=$APP_BIN
Icon=$APP_ID
Terminal=false
Categories=Utility;Network;
StartupWMClass=$WMCLASS
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
  # A client device (it has a link.json) must always keep the service up: it's
  # both the update-agent and the local proxy the app talks to. A server-capable
  # device that isn't a client can be left however the app set it.
  CLIENT=0; [ -f "$HOME/.config/lymnal/link.json" ] && CLIENT=1
  if [ "$had_unit" = 0 ]; then
    # First install: start it on (a fresh device is server-capable) and make it
    # survive a reboot.
    sh_ systemctl --user enable --now lymnal.service
    if [ "$LINGER_ON" = 0 ]; then sh_ $SUDO loginctl enable-linger "$(id -un)" || true; fi
  else
    # A client's service must be enabled (so it comes back after a reboot) and
    # running (so the proxy exists at all).
    if [ "$CLIENT" = 1 ]; then
      systemctl --user is-enabled --quiet lymnal.service 2>/dev/null \
        || sh_ systemctl --user enable lymnal.service || true
      if [ "$LINGER_ON" = 0 ]; then sh_ $SUDO loginctl enable-linger "$(id -un)" || true; fi
    fi
    # If the service is running and its binary changed, restart it onto the new
    # build. This is gated on *is-active*, not is-enabled: a running-but-disabled
    # service (which is how a client can end up) was being skipped here, so every
    # update rebuilt the binary but left the old process running — the app then
    # found nothing on the proxy port and sat on "READING…".
    if systemctl --user is-active --quiet lymnal.service 2>/dev/null; then
      if [ "$LYMNAL_CHANGED" = 1 ]; then
        # Hold the restart until any in-flight uploads finish, so an update never
        # cuts one off (the running service keeps upload state in memory).
        "$BIN_DIR/lymnal" drain || true
        sh_ systemctl --user restart lymnal.service
      fi
    elif [ "$CLIENT" = 1 ]; then
      # A client whose service somehow isn't running: bring it up.
      sh_ systemctl --user start lymnal.service || true
    fi
  fi
  INSTALLED_SERVICE=1
  done_
fi

# If the elyxr window was open when this ran, restart it onto the fresh build so
# an open window never lingers on the old version. This is the step that makes an
# update actually visible: without it the new binary sits on disk while the old
# window keeps running.
#
# The tricky case is a background update — the client's service agent runs this
# script, and a systemd --user service has no graphical session of its own (no
# DISPLAY / WAYLAND_DISPLAY / DBUS). Relaunching from there would kill the old
# window and fail to bring a new one up. So we lift those variables straight out
# of the running window's own environment (/proc/<pid>/environ) and hand them to
# the relaunch — the new window then appears on the user's screen no matter who
# triggered the update.
APP_RESTARTED=0
if [ "$APP" = 1 ] && [ -n "${APP_BIN:-}" ]; then
  app_pid="$(pgrep -f "$APP_BIN" | head -n1 || true)"
  if [ -n "$app_pid" ]; then
    app_env=()
    if [ -r "/proc/$app_pid/environ" ]; then
      while IFS= read -r -d '' kv; do
        case "$kv" in
          DISPLAY=*|WAYLAND_DISPLAY=*|XAUTHORITY=*|DBUS_SESSION_BUS_ADDRESS=*|XDG_RUNTIME_DIR=*)
            app_env+=("$kv") ;;
        esac
      done < "/proc/$app_pid/environ"
    fi
    pkill -f "$APP_BIN" 2>/dev/null || true
    sleep 1
    # Start the fresh window in its OWN transient unit, not as a child of this
    # update's systemd scope — otherwise, when this script ends and the scope is
    # torn down, systemd kills the window we just opened (which is why a
    # successful update stopped reopening the app). Fall back to setsid where
    # systemd-run isn't available.
    if command -v systemd-run >/dev/null 2>&1 \
       && systemd-run --user --collect --quiet \
            env "${app_env[@]}" "$APP_BIN" >/dev/null 2>&1; then
      :
    else
      ( setsid env "${app_env[@]}" "$APP_BIN" >/dev/null 2>&1 & ) 2>/dev/null || true
    fi
    APP_RESTARTED=1
  fi
fi

notify "Done — elyxr is up to date."
splash
echo
echo "${GRN}elyxr is ready.${RST}"
echo
if [ "$APP" = 1 ]; then
  if [ "$APP_RESTARTED" = 1 ]; then
    echo "  The open app was restarted onto the latest build."
  else
    echo "  Open it from your apps menu — search \"elyxr\"."
  fi
fi
echo "  Update anytime:  lymnal update"
