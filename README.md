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
- **gate**: optional, Linux-only. Surfaces the trove as a real folder in your file
  manager.

Your devices reach each other over **Tailscale**: a private network of only your
own machines, nothing exposed to the internet. Use the **same account** on every
device; that's what pairs them.

---

## Install

Pick your platform; each has a short, exact guide:

| Platform | How | Guide |
|---|---|---|
| **Linux** (Ubuntu / Zorin / Debian) | `git clone` + `./elyxr.sh` (builds from source) | [Quickstart → Linux](docs/QUICKSTART.md#linux) |
| **Windows** | Run `elyxr-setup.exe` (per-user, no admin) | [Quickstart → Windows](docs/QUICKSTART.md#windows) |
| **Android** | Install the Tailscale app, then install `elyxr.apk` | [Quickstart → Android](docs/QUICKSTART.md#android) |

The short version on Linux:

```sh
git clone https://github.com/ryanj97g/elyxr.git
cd elyxr
./elyxr.sh
```

That sets everything up, puts **elyxr** in your applications menu, and starts the
background service. You're asked for your password once, for first-time setup;
after that, updates never ask again. Headless server with no screen? Add
`--no-app`.

Prebuilt downloads live on the [releases page](https://github.com/ryanj97g/elyxr/releases):
`elyxr-setup.exe` (Windows) and `elyxr.apk` (Android).

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

- **Click a file** to select it; its details show below. Click an **audio file**
  and it plays in the built-in player, with the rest of that **folder queued up as
  a playlist**.
- **Double-click a file** to open it: just that file downloads, right then, and
  opens in your default program. Edits you save come back to the trove on their
  own; even if the server is briefly unreachable, the change waits on this device
  and lands the moment it's back.
- **Click and hold** to select several files at once; the actions (RENAME,
  DOWNLOAD, MOVE, DELETE) live permanently in the bar and light up when you have a
  selection.
- **Add a file**: the upload button, or drag one in; and every device sees it.
- **Drag a file out** of the window and it downloads to wherever you drop it.
- **Delete a file** and it's gone everywhere (the app asks first, since the trove is
  shared).

No syncing by hand; using the files *is* the sync.

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
- **Typeface**: the terminal font, VT323 and a dozen more. Drop your own
  `.ttf`/`.otf` into `elyxr/assets/fonts/custom/` and tap **SCAN** (desktop) to use
  them right away.

And a few practical ones, same place: where downloads land, how many transfer at
once, whether deleting asks first, and *(Linux)* whether the trove also shows up as
a folder in your file manager.

**Nostalgia Mode** (a toggle above the settings sections) turns on the fun: a
matrix screensaver, a cursor trail, a transfer log, sound effects, a hidden Snake
game (tap the wordmark ×7), and **2000's DEMO MODE**: which, when *you* switch it
on, plays a built-in keygen soundtrack. It's off by default, so it never hijacks
your own music.

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

## Docs

- **[docs/QUICKSTART.md](docs/QUICKSTART.md)**: set up any device (Linux, Windows, Android).
- **[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)**: when something's off.
- **[SPECS.md](SPECS.md)**: how it works (architecture, protocol, the HTTP API).
- **[DESIGN.md](DESIGN.md)**: the look and interaction model.
