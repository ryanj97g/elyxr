#!/usr/bin/env bash
# Assemble the elyxr .deb from an already-built app bundle and lymnal binary.
# Nothing is compiled here: this only lays out files and works out dependencies.
#
#   packaging/linux/build-deb.sh <version>
#
# Run from the repo root, after `flutter build linux --release` and
# `cargo build --release -p lymnal`.
set -Eeuo pipefail

VER="${1:?usage: build-deb.sh <version>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

BUNDLE="elyxr/build/linux/x64/release/bundle"
LYMNAL="target/release/lymnal"
[ -x "$BUNDLE/elyxr" ] || { echo "no app bundle at $BUNDLE — build the app first" >&2; exit 1; }
[ -x "$LYMNAL" ]       || { echo "no lymnal at $LYMNAL — cargo build --release -p lymnal" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
chmod 0755 "$STAGE"

install -d "$STAGE/DEBIAN" \
           "$STAGE/usr/lib/elyxr" \
           "$STAGE/usr/bin" \
           "$STAGE/usr/libexec" \
           "$STAGE/usr/lib/systemd/user" \
           "$STAGE/usr/share/applications" \
           "$STAGE/usr/share/polkit-1/actions"

# The app: the whole Flutter bundle, kept together, with a launcher on the path.
cp -a "$BUNDLE/." "$STAGE/usr/lib/elyxr/"
cat > "$STAGE/usr/bin/elyxr" <<'LAUNCH'
#!/bin/sh
exec /usr/lib/elyxr/elyxr "$@"
LAUNCH
chmod 0755 "$STAGE/usr/bin/elyxr"

install -m 0755 "$LYMNAL" "$STAGE/usr/bin/lymnal"
install -m 0755 packaging/linux/elyxr-update "$STAGE/usr/libexec/elyxr-update"
install -m 0644 packaging/linux/org.elyxr.update.policy \
                "$STAGE/usr/share/polkit-1/actions/org.elyxr.update.policy"

# Icons, at every size the theme uses.
for sz in 16 32 48 64 128 256 512; do
  install -d "$STAGE/usr/share/icons/hicolor/${sz}x${sz}/apps"
  install -m 0644 "branding/png/elyxr/elyxr-${sz}.png" \
                  "$STAGE/usr/share/icons/hicolor/${sz}x${sz}/apps/com.elyxr.elyxr.png"
  [ -f "branding/png/lymnal/lymnal-${sz}.png" ] && install -m 0644 \
    "branding/png/lymnal/lymnal-${sz}.png" \
    "$STAGE/usr/share/icons/hicolor/${sz}x${sz}/apps/com.elyxr.lymnal.png"
done

cat > "$STAGE/usr/share/applications/com.elyxr.elyxr.desktop" <<'DESK'
[Desktop Entry]
Type=Application
Name=elyxr
Comment=Reach your trove from anywhere
Exec=/usr/bin/elyxr
Icon=com.elyxr.elyxr
Terminal=false
Categories=Network;
StartupWMClass=Com.elyxr.elyxr
DESK

# lymnal stays a per-user service: it serves your folder, as you, with your
# pairing. Shipping the unit here makes it available to every account; the
# postinst turns it on for the person installing.
cat > "$STAGE/usr/lib/systemd/user/lymnal.service" <<'UNIT'
[Unit]
Description=lymnal — serves the trove over your tailnet
Documentation=https://github.com/ryanj97g/elyxr
StartLimitIntervalSec=1800
StartLimitBurst=4

[Service]
Type=simple
ExecStart=/usr/bin/lymnal
Restart=on-failure
RestartSec=300

[Install]
WantedBy=default.target
UNIT

# Work out the library dependencies from the binaries themselves rather than
# guessing a list that goes stale every time a plugin changes.
mkdir -p "$STAGE/debian"
printf 'Source: elyxr\n' > "$STAGE/debian/control"
DEPS="$(cd "$STAGE" && dpkg-shlibdeps -O --ignore-missing-info \
          usr/lib/elyxr/elyxr usr/bin/lymnal usr/lib/elyxr/lib/*.so 2>/dev/null \
          | sed 's/^shlibs:Depends=//')"
rm -rf "$STAGE/debian"
[ -n "$DEPS" ] || { echo "couldn't work out dependencies" >&2; exit 1; }

# Things that aren't linked libraries: the programs the app runs, the codec
# plugins its audio goes through, and curl for the updater.
EXTRA="ffmpeg, openmpt123, curl, policykit-1 | polkitd, gstreamer1.0-plugins-base, gstreamer1.0-plugins-good, gstreamer1.0-libav"

cat > "$STAGE/DEBIAN/control" <<CONTROL
Package: elyxr
Version: $VER
Section: net
Priority: optional
Architecture: amd64
Maintainer: ryanj97g <ryanj97g@users.noreply.github.com>
Depends: $DEPS, $EXTRA
Description: Reach your trove from anywhere
 elyxr shows you every file on your trove device and downloads one only when you
 open it, so a laptop with no room can still reach a library that would never fit
 on it. Devices find each other over your own tailnet; nothing is exposed.
CONTROL

install -m 0755 packaging/linux/postinst "$STAGE/DEBIAN/postinst"
install -m 0755 packaging/linux/prerm    "$STAGE/DEBIAN/prerm"

# Normalise modes: files copied out of a checkout carry whatever the checkout
# had, and a package should not ship group-writable system files.
find "$STAGE/usr" -type d -exec chmod 0755 {} +
find "$STAGE/usr" -type f -exec chmod 0644 {} +
chmod 0755 "$STAGE/usr/bin/elyxr" "$STAGE/usr/bin/lymnal" \
           "$STAGE/usr/libexec/elyxr-update" "$STAGE/usr/lib/elyxr/elyxr"
find "$STAGE/usr/lib/elyxr/lib" -name '*.so' -exec chmod 0755 {} + 2>/dev/null || true

OUT="elyxr_${VER}_amd64.deb"
fakeroot dpkg-deb --build "$STAGE" "$OUT" >/dev/null
echo "built $OUT ($(du -h "$OUT" | cut -f1))"
