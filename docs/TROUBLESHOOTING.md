# Troubleshooting

Problems grouped by where they show up: connecting, updating, building (Linux),
Android, and the media player. Each entry is *symptom → why → fix*.

---

## Connecting & pairing

### "Tailscale isn't connected on this device."
**Why:** elyxr reaches your devices over Tailscale, and this device isn't on the
tailnet. (Internally: the OS reported the network as unreachable.)
**Fix:** open Tailscale and sign in — **the same account on every device**. On
Android, Tailscale is a separate app you must install and sign into yourself.

### "Can't reach `<server>`. It may be asleep or off."
**Why:** the server's lymnal didn't answer — it may be powered off/asleep, not
running the service, or you have the wrong address.
**Fix:** confirm the server is on and `lymnal status` shows it serving; confirm the
address is the server's Tailscale IP with elyxr's port, `100.x.y.z:7749`. elyxr
keeps retrying and resumes on its own once the server answers.

### "This device is no longer approved."
**Why:** the server revoked or forgot this device's access (a 401 from the trove).
**Fix:** on the client, request access again; on the server, approve it
(Settings → PAIRING, or `lymnal bind seal`).

### The client can't find the server at all
- The server must be in **Server** mode *and* have **pairing open** (Settings →
  PAIRING, or `lymnal bind open`). Pairing auto-closes after ~2 minutes and the
  moment a device is approved.
- Auto-discovery only lists servers reachable on your tailnet right now. If yours
  doesn't appear, enter its address by hand (`100.x.y.z:7749`).
- Both devices must be signed into Tailscale on the **same account**.

### The server won't bind / exits at startup
**Why:** lymnal resolves its own Tailscale address at startup (`tailscale ip -4`);
if Tailscale isn't up, there's no address to bind.
**Fix:** connect Tailscale, then restart the service (`systemctl --user restart
lymnal`, or the tray's "refresh connection").

---

## Updating

### `lymnal update` runs but keeps building the old code
Symptom: the log prints **"couldn't fast-forward to the latest (local changes?)"**
(older builds) and nothing changes.
**Why:** the checkout's git history diverged from the published branch (this
happens if upstream history was ever rewritten/force-pushed), so a fast-forward is
impossible.
**Fix:** current builds self-heal — the updater now fetches and hard-resets to the
published branch automatically. If you're on a build from *before* that fix, do it
once by hand on that device:

```sh
# find the checkout (it's recorded, usually ~/Elyxr — capital E, case-sensitive)
REPO="$(find ~ -maxdepth 4 -name elyxr.sh 2>/dev/null | head -1 | xargs -r dirname)"
cd "$REPO"
git fetch origin
git reset --hard origin/main   # only tracked files; your dropped music/fonts are kept
lymnal update
```

lymnal finds its repo via `~/.config/lymnal/repo.path` (written on the first
`./elyxr.sh` run), then `~/elyxr` / `~/Elyxr`.

### An update said it needs a password and skipped a step
Symptom: **"A one-time setup step needs a password; skipping it for now. Run
./elyxr.sh in a terminal once to finish it."**
**Why:** background/tray/fleet updates run detached with no terminal, so they can't
prompt for a password. Everything that doesn't need root is done; a genuinely new
**system package** (which needs root, once) is deferred.
**Fix:** run the installer attached, in a terminal, once:

```sh
cd ~/Elyxr && ./elyxr.sh
```

It'll prompt for your password normally, install the package, and build. After
that, `lymnal update` works detached again.

### The tray icon / update button is missing (GNOME, Zorin)
**Why:** lymnal publishes a StatusNotifierItem; GNOME/Zorin need a tray host.
**Fix:** enable the **"AppIndicator and KStatusNotifierItem Support"** extension.
(KDE has a tray by default.) You can always update from the app or `lymnal update`
instead.

---

## Building (Linux)

The installer builds from source and installs the system libraries it needs. If a
build fails on a missing library, here's the map. Current `elyxr.sh` already lists
all of these — if you hit one, you're likely on an older installer; re-run
`./elyxr.sh` (it self-updates first).

### `CMake Error: Could NOT find ALSA (missing: ALSA_LIBRARY ...)`
**Why:** a plugin in the dependency tree runs `find_package(ALSA)`; Flutter builds
every plugin's native code, so the ALSA dev headers must be present.
**Fix:** `sudo apt-get install libasound2-dev` (now in the installer's list).

### `Target links to: PkgConfig::mpv but the target was not found`
**Why:** media_kit (inline video preview) links the **system libmpv** on Linux.
**Fix:** `sudo apt-get install libmpv-dev` (now in the installer's list).

### Some other `Could NOT find <X>` / `PkgConfig::<x>` error
**Why:** a build machine missing a `-dev` package. The installer auto-heals missing
C **headers** (it reads the missing `.h`, finds the owning package with `apt-file`,
installs it, retries) — but a CMake `find_package`/`pkg_check_modules` failure is
*not* caught by that.
**Fix:** install the matching `-dev` package by hand, or report the exact line so
it can be added to the installer. For reference, the app build needs: `clang`,
`cmake`, `ninja-build`, `libgtk-3-dev`, `liblzma-dev`, `libsecret-1-dev`,
`libjsoncpp-dev`, `libgstreamer1.0-dev`, `libgstreamer-plugins-base1.0-dev`,
`gstreamer1.0-plugins-base`, `gstreamer1.0-plugins-good`, `gstreamer1.0-libav`,
`libasound2-dev`, `libmpv-dev`, `openmpt123`, `ffmpeg` (plus `build-essential`,
`pkg-config`, `git`, `fuse3`, `libfuse3-dev`).

### "elyxr needs an apt-based Linux…"
**Why:** the installer only supports apt distributions (Ubuntu, Zorin, Debian, and
relatives).
**Fix:** use a supported distro, or install the prerequisites and build by hand
(`cargo build --release`; `cd elyxr && flutter build linux`).

### "No space left on device" mid-build
**Fix:** free some disk (old build artifacts, caches) and re-run. Debug/decoded
media temp files live under the system temp dir and are safe to clear.

---

## Android

### A black bar at the top of the screen (over the camera)
**Why:** older APKs didn't declare that the app draws under the display cutout, so
Android letterboxed the cutout strip black.
**Fix:** install a current APK. Recent builds go edge-to-edge and draw under the
punch-hole (immersive + `layoutInDisplayCutoutMode`), so the chassis reaches the
top pixel.

### An update fails with "App not installed" / signature mismatch
**Why:** the installed APK was signed with a different key than the new one (only
happens coming from a very old build).
**Fix:** uninstall elyxr once, install the current APK. Every build since is signed
with the same key, so future updates install in place with no uninstall.

### The persistent elyxr notification
That's the on-device lymnal foreground service — it's what lets the phone keep its
connection and receive updates. It's expected; it isn't a bug.

---

## Media player

### An `.m4a` (or `.mp4`) opens a video window instead of just playing audio
**Why:** the file is really an MP4 container carrying a video track; the media
backend renders the picture too.
**Fix:** current builds strip the video track before playback (audio-only), so no
picture window appears. On **Linux desktop** this needs `ffmpeg` on `PATH`
(Windows bundles it; Android does it natively). If a video window still appears on
Linux, install ffmpeg: `sudo apt-get install ffmpeg`.

### The lightshow (visualizer) is dead for a streamed track
**Why:** the visualizer reads raw PCM, so compressed audio must be decoded first.
**Fix:** Android decodes natively (works out of the box). **Linux/Windows desktop**
decode with `ffmpeg` — if the bars are dead for `.m4a`/`.mp3` but alive for the
built-in tracker soundtrack, `ffmpeg` is missing from `PATH`
(`sudo apt-get install ffmpeg`).

### The easter-egg soundtrack keeps hijacking the player
**Why:** "2000's DEMO MODE" (under Nostalgia Mode in Settings) auto-plays the
built-in keygen soundtrack.
**Fix:** turn **2000's DEMO MODE** off (it's off by default). With it off, only the
files you stream from the trove play, and a finished song advances to the next file
in that folder rather than an easter-egg track.

### Custom fonts don't show up after I drop them in
**Why:** the **SCAN** button (Settings → TYPEFACE) rescans the on-disk fonts folder
and is **desktop-only** (a phone has no repo folder to scan).
**Fix:** drop `.ttf`/`.otf` files into `elyxr/assets/fonts/custom/` in your
checkout, then tap **SCAN** on a desktop device. Committed fonts are picked up
automatically on the next build.

---

## For developers

### CI fails on the Android job referencing `packaging/android/...`
The Android workflow copies `packaging/android/MainActivity.kt`, `LymnalService.kt`,
`modrender.c`, `debug.keystore`, and `assets/branding/elyxr_icon*.png` into the
scaffolded project. These must exist at build time or the job fails.

### The build number / "am I behind the server?" check is wrong
The build stamp is the git commit count (`git rev-list --count HEAD`), computed at
build time. A shallow clone reports `1`; CI uses `fetch-depth: 0` for full history.
Build by hand with full history, or the version comparison misbehaves.
