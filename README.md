# elyxr

Your stuff lives on one device; elyxr lets you reach all of it from any of your
other devices.

"Oh, so a dropbox dupe?" NOPE. Dropbox and Syncthing keep you "in sync" by putting
a copy of everything on every device: 150 GB of files on your storage device? You'd
need 150 GB free on each device you want to retrieve from. elyxr doesn't work that
way. You **see** everything, and a file only downloads when you **need** it. Your
files stay on the **trove** device that actually stores them; your other devices
pull only what you open, when you open it.

Open a file and it's just there, wherever you put it. No two out-of-sync copies.
Ever.

---

## The pieces

- **elyxr**: the app; the part that feels like magic, and the main way in on every
  device.
- **lymnal**: the always-on background service that connects your devices. One
  binary, two roles: on the **server** it shares the trove; on a **client** it
  keeps the device updated and runs a small local proxy the app talks to.
- **trove**: the one real folder of files on the server. The source of truth.
- **lymbo**: a client's small **write-back buffer**: it holds a file you've *saved*
  only until it lands back on the trove. It is **not** a read cache; opening files
  never fills it.

Your devices reach each other over **Tailscale**: a private network of only your
own machines, nothing exposed to the internet. Use the **same account** on every
device; that's what pairs them.

---

## Install

Install Tailscale on each device and sign in with the **same account**: that puts
them on one private network. Then follow the section for your platform.

A device is either a **server** (holds the trove folder and shares it) or a
**client** (reaches a server's trove). Desktops can be either; a phone is always a
client.

| Platform | How |
|---|---|
| **Linux** (Ubuntu / Zorin / Debian) | [`git clone` + `./elyxr.sh`](#linux), builds from source |
| **Windows** | [Run `elyxr-setup.exe`](#windows), per-user, no admin |
| **Android** | [Install Tailscale, then `elyxr.apk`](#android) |

Prebuilt downloads live on the [releases page](https://github.com/ryanj97g/elyxr/releases):
`elyxr-setup.exe` (Windows) and `elyxr.apk` (Android).

### Linux

Supported: apt-based distributions (Ubuntu, Zorin, Debian). The installer exits
with a message on anything else.

```sh
git clone https://github.com/ryanj97g/elyxr.git
cd elyxr
./elyxr.sh
```

`./elyxr.sh` installs the system build dependencies, installs Tailscale (it opens
a browser once for sign-in), fetches Rust and the Flutter SDK if missing, builds
lymnal and the app, puts `lymnal` in `~/.local/bin`, adds elyxr to the
applications menu, and starts lymnal as a user service that runs at boot. It asks
for your password once, for that first system-package step; after that, updates
run without root.

Flags: `--no-app` (build only the service, for a headless box), `--no-service`,
`--no-update`, `--no-tailscale`, `--verbose`.

### Windows

Download `elyxr-setup.exe` from the
[releases page](https://github.com/ryanj97g/elyxr/releases) (the `windows-latest`
release, marked Latest) and run it. It's a per-user install with no administrator
prompt. It installs to `%LOCALAPPDATA%\Programs\elyxr`, adds a Start-menu
shortcut, seeds a starter config, installs Tailscale (via winget, or opens the
download page), and starts lymnal hidden at each login. Windows may warn about an
unrecognized app, since the build is unsigned; choose More info → Run anyway.

Sign into Tailscale with the same account as your other devices.

### Android

A phone is always a client. Nothing builds on the phone; you install a prebuilt
APK, and it runs its own on-device lymnal, so it behaves like a desktop client.

1. **Install Tailscale** from the Play Store and sign in with the same account as
   your other devices. This is not automated on Android; without it elyxr reports
   "Tailscale isn't connected on this device."
2. **Get the APK** from
   `https://github.com/ryanj97g/elyxr/releases/download/android-latest/elyxr.apk`
   (or the releases page → `android-latest` → `elyxr.apk`). Open it to install;
   allow "install unknown apps" for the app you downloaded with, then Install.

elyxr shows an ongoing notification while running; that's the on-device lymnal
service holding the connection.

Updates download the new APK and open the system installer; because every build is
signed with the same key, it installs over the top with no uninstall.

---

## Connect two devices

Say you want your laptop to reach your desktop's files.

**On the desktop (the one with the files):** open elyxr, **hold the wordmark** (the
"ELYXR" text) to open Settings, set **THIS DEVICE → Server**, and open **PAIRING**.

**On the laptop:** open elyxr; it starts as a **Client** and **looks for servers
on your tailnet automatically**. Tap the desktop in the list and **REQUEST
ACCESS ▸**. (If it doesn't appear, enter its address by hand; `100.x.y.z:7749`,
which the installer prints while setting the desktop up.)

**Back on the desktop:** the laptop appears by name. Tap **APPROVE**: that also
closes pairing, so nothing else can slip in.

The laptop is connected, and the desktop's files are right there in elyxr; browse,
open, add, delete, each downloading only when you open it. Nothing is copied to the
laptop.

Prefer the terminal, or the server has no screen?

```sh
lymnal bind 100.x.y.z:7749     # on the client; connect to the server
lymnal bind seal               # on the server; approve the waiting device
```

---

## Using it

elyxr is a live window into the trove, not a copy of it:

- **Click a file** and it opens: just that file downloads, right then, and opens in
  your default program. Edits you save come back to the trove on their own; even if
  the server is briefly unreachable, the change waits on this device and lands the
  moment it's back.
- **Click a folder** to go into it. The breadcrumbs and **▲ UP** walk back out.
- **Click an audio file** and it plays in the built-in player, with the rest of
  that folder queued up as a playlist.
- **Click and hold** to select several files at once; the actions (RENAME,
  DOWNLOAD, MOVE, DELETE) live permanently in the bar and light up when you have a
  selection.
- **Add a file**: the upload button, or drag one in; and every device sees it.
- **Drag a file out** of the window and it downloads to wherever you drop it.
- **Delete a file** and it's gone everywhere (the app asks first, since the trove is
  shared).

The music player tucks itself into a single bar 30 seconds after you pause it,
keeping the track loaded. Tap the bar to bring it back.

No syncing by hand; using the files *is* the sync.

**On Android:** the back button goes up one folder, and two presses at the top
level leave the app. You can also turn on **shake for Tailscale**, which opens the
Tailscale app when you shake the phone.

---

## Updates

Update from **any device**: the button in the app, or `lymnal update`; and every
other device updates itself in step. It happens in the background: a popup when it
starts, a popup when it's done, and the app reopens on its own when ready. No
password, no confirmation. The only thing that waits is a file mid-upload.

---

## Make it yours

Hold the wordmark to open Settings. None of this changes what elyxr *does*; just
how it looks and feels on this device:

- **Accent**: eight phosphor colours; drag a swatch to push its glow (or the white
  one's brightness).
- **Tube**: dark glow, or light paper.
- **Density**: how large the text sits.
- **Typeface**: the terminal font, VT323 and ten more. Drop your own `.ttf`/`.otf`
  into `elyxr/assets/fonts/custom/` and tap **SCAN** (desktop) to use them right
  away.

Filenames in other scripts — Cyrillic, Arabic, Japanese, Korean, Thai, Devanagari
— render properly whichever font you pick, so a mixed playlist doesn't come out
half in boxes.

And a few practical ones, same place: where downloads land, how many transfer at
once, and whether deleting asks first.

---

## The fun stuff

**Nostalgia Mode** is one toggle above the settings sections. It turns on a cursor
trail, a transfer log, retro sound effects, a hidden Snake game (tap the wordmark
×7), and an unmarked nonsense button.

It also reveals **DEMO MODE**, which reveals four more toggles: a matrix
**screensaver**, a music-reactive **lightshow** around the edge of the tube, an
**oscilloscope** in the strip between the speakers, and a keygen **soundtrack**.
Pick any combination — the screensaver without the lightshow, the oscilloscope
without either.

Everything here is off by default, and nothing in it will ever interrupt music you
started yourself.

Full details in [NOSTALGIA.md](NOSTALGIA.md).

---

## Terminal

Everything above lives in the app. These are for when you'd rather type, or the
device has no screen.

```sh
lymnal status                 # what's set up, and how full the trove is
lymnal update                 # update this device, and tell the others to follow

lymnal bind <address>         # (client) connect this device to a server
lymnal bind open              # (server) start accepting a device
lymnal bind seal              # (server) approve the one device waiting
lymnal bind list              # (server) show the devices waiting
lymnal bind approve <name> [--guest]
lymnal bind deny <name>
lymnal bind close             # (server) stop accepting devices

lymnal trove set <path>       # change which folder is served
```

---

## Troubleshooting

Problems grouped by where they show up, each one *symptom → why → fix*.

### Connecting & pairing

**"Tailscale isn't connected on this device."**
elyxr reaches your devices over Tailscale, and this device isn't on the tailnet.
(Internally: the OS reported the network as unreachable.) Open Tailscale and sign
in, **the same account on every device**. On Android, Tailscale is a separate app
you must install and sign into yourself.

**"Can't reach `<server>`. It may be asleep or off."**
The server's lymnal didn't answer; it may be powered off or asleep, not running
the service, or you have the wrong address. Confirm the server is on and
`lymnal status` shows it serving, and that the address is the server's Tailscale
IP with elyxr's port, `100.x.y.z:7749`. elyxr keeps retrying and resumes on its
own once the server answers.

**"This device is no longer approved."**
The server revoked or forgot this device's access (a 401 from the trove). On the
client, request access again; on the server, approve it (Settings → PAIRING, or
`lymnal bind seal`).

**The client can't find the server at all**
The server must be in **Server** mode *and* have **pairing open** (Settings →
PAIRING, or `lymnal bind open`). Pairing auto-closes after about two minutes and
the moment a device is approved. Auto-discovery only lists servers reachable on
your tailnet right now; if yours doesn't appear, enter its address by hand
(`100.x.y.z:7749`). Both devices must be signed into Tailscale on the **same
account**.

**The server won't bind, or exits at startup**
lymnal resolves its own Tailscale address at startup (`tailscale ip -4`); if
Tailscale isn't up, there's no address to bind. Connect Tailscale, then restart
the service (`systemctl --user restart lymnal`, or the tray's "refresh
connection").

### Updating

**`lymnal update` runs but keeps building the old code**
The log prints "couldn't fast-forward to the latest (local changes?)" on older
builds and nothing changes. The checkout's git history diverged from the published
branch, which happens if upstream history was ever rewritten, so a fast-forward is
impossible. Current builds self-heal by fetching and hard-resetting to the
published branch. On a build from *before* that fix, do it once by hand on that
device:

```sh
# find the checkout (it's recorded, usually ~/Elyxr: capital E, case-sensitive)
REPO="$(find ~ -maxdepth 4 -name elyxr.sh 2>/dev/null | head -1 | xargs -r dirname)"
cd "$REPO"
git fetch origin
git reset --hard origin/main   # only tracked files; your dropped music/fonts are kept
lymnal update
```

lymnal finds its repo via `~/.config/lymnal/repo.path` (written on the first
`./elyxr.sh` run), then `~/elyxr` / `~/Elyxr`.

**An update said it needs a password and skipped a step**
"A one-time setup step needs a password; skipping it for now." Background, tray,
and fleet updates run detached with no terminal, so they can't prompt for a
password. Everything that doesn't need root is done; a genuinely new **system
package** is deferred. Run the installer attached, in a terminal, once:

```sh
cd ~/Elyxr && ./elyxr.sh
```

After that, `lymnal update` works detached again.

**The tray icon or update button is missing (GNOME, Zorin)**
lymnal publishes a StatusNotifierItem; GNOME and Zorin need a tray host. Enable
the **"AppIndicator and KStatusNotifierItem Support"** extension. (KDE has a tray
by default.) You can always update from the app or `lymnal update` instead.

### Building (Linux)

The installer builds from source and installs the system libraries it needs.
Current `elyxr.sh` already lists all of these; if you hit one, you're likely on an
older installer, so re-run `./elyxr.sh` (it self-updates first).

**`CMake Error: Could NOT find ALSA (missing: ALSA_LIBRARY ...)`**
A plugin in the dependency tree runs `find_package(ALSA)`, and Flutter builds
every plugin's native code, so the ALSA dev headers must be present.
`sudo apt-get install libasound2-dev`.

**`Target links to: PkgConfig::mpv but the target was not found`**
media_kit (inline video preview) links the **system libmpv** on Linux.
`sudo apt-get install libmpv-dev`.

**Some other `Could NOT find <X>` / `PkgConfig::<x>` error**
A build machine missing a `-dev` package. The installer auto-heals missing C
**headers** (it reads the missing `.h`, finds the owning package with `apt-file`,
installs it, retries), but a CMake `find_package`/`pkg_check_modules` failure is
*not* caught by that. Install the matching `-dev` package by hand, or report the
exact line so it can be added to the installer. For reference, the app build
needs: `clang`, `cmake`, `ninja-build`, `libgtk-3-dev`, `liblzma-dev`,
`libsecret-1-dev`, `libjsoncpp-dev`, `libgstreamer1.0-dev`,
`libgstreamer-plugins-base1.0-dev`, `gstreamer1.0-plugins-base`,
`gstreamer1.0-plugins-good`, `gstreamer1.0-libav`, `libasound2-dev`,
`libmpv-dev`, `openmpt123`, `ffmpeg` (plus `build-essential`, `pkg-config`,
`git`).

**"elyxr needs an apt-based Linux…"**
The installer only supports apt distributions (Ubuntu, Zorin, Debian, and
relatives). Use a supported distro, or install the prerequisites and build by hand
(`cargo build --release`; `cd elyxr && flutter build linux`).

**"No space left on device" mid-build**
Free some disk (old build artifacts, caches) and re-run. Debug and decoded media
temp files live under the system temp dir and are safe to clear.

### Android

**A black bar at the top of the screen, over the camera**
Older APKs didn't declare that the app draws under the display cutout, so Android
letterboxed the cutout strip black. Install a current APK; recent builds go
edge-to-edge and draw under the punch-hole, so the chassis reaches the top pixel.

**An update fails with "App not installed" or a signature mismatch**
The installed APK was signed with a different key than the new one, which only
happens coming from a very old build. Uninstall elyxr once, install the current
APK. Every build since is signed with the same key, so future updates install in
place.

**The persistent elyxr notification**
That's the on-device lymnal foreground service; it's what lets the phone keep its
connection and receive updates. It's expected, not a bug.

### Media player

**An `.m4a` or `.mp4` opens a video window instead of just playing audio**
The file is really an MP4 container carrying a video track, and the media backend
renders the picture too. Current builds strip the video track before playback. On
**Linux desktop** this needs `ffmpeg` on `PATH` (Windows bundles it; Android does
it natively). `sudo apt-get install ffmpeg`.

**The lightshow is dead for a streamed track**
The visualizer reads raw PCM, so compressed audio must be decoded first. Android
decodes natively. **Linux and Windows desktop** decode with `ffmpeg`; if the bars
are dead for `.m4a`/`.mp3` but alive for the built-in tracker soundtrack, `ffmpeg`
is missing from `PATH`.

**The easter-egg soundtrack keeps hijacking the player**
"2000's DEMO MODE" (under Nostalgia Mode in Settings) auto-plays the built-in
keygen soundtrack. Turn it off; it's off by default. With it off, only the files
you stream from the trove play, and a finished song advances to the next file in
that folder.

**Custom fonts don't show up after I drop them in**
The **SCAN** button (Settings → TYPEFACE) rescans the on-disk fonts folder and is
**desktop-only**, since a phone has no repo folder to scan. Drop `.ttf`/`.otf`
files into `elyxr/assets/fonts/custom/` in your checkout, then tap **SCAN** on a
desktop device. Committed fonts are picked up automatically on the next build.

### For developers

**CI fails on the Android job referencing `packaging/android/...`**
The Android workflow copies `packaging/android/MainActivity.kt`,
`LymnalService.kt`, `modrender.c`, `debug.keystore`, and
`assets/branding/elyxr_icon*.png` into the scaffolded project. These must exist at
build time or the job fails.

**The build number, or the "am I behind the server?" check, is wrong**
The build stamp is the git commit count (`git rev-list --count HEAD`), computed at
build time. A shallow clone reports `1`; CI uses `fetch-depth: 0` for full
history. Build by hand with full history, or the version comparison misbehaves.

---

## Docs

- **[SPECS.md](SPECS.md)**: how it works (architecture, protocol, the HTTP API).
- **[DESIGN.md](DESIGN.md)**: the look and interaction model.
- **[NOSTALGIA.md](NOSTALGIA.md)**: the optional fun layer.
