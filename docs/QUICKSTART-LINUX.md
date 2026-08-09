# Quickstart — Linux

elyxr's home turf. One script installs everything, builds it from source, adds
elyxr to your apps menu, and starts the background service. This is the device
that's usually your **trove** (the one holding the files), but the same steps set
up a client too.

> **Supported:** apt-based distributions — Ubuntu, Zorin, Debian, and their
> relatives. The installer stops early with a clear message on anything else.

---

## 1. Install

```sh
git clone https://github.com/ryanj97g/elyxr.git
cd elyxr
./elyxr.sh
```

That's the whole install. The script runs in phases and prints each one:

- **base packages / build tools** — the system libraries needed to build (GTK,
  GStreamer, libmpv, ALSA headers, FUSE, a C toolchain, and the media helpers
  `openmpt123` + `ffmpeg`). Installed with your package manager.
- **tailscale** — installed for you; the one part it can't automate is the
  sign-in, so it opens your browser once (see step 2).
- **rust toolchain / flutter sdk** — fetched into your home if missing; nothing
  system-wide.
- **building lymnal / gate / the app** — compiled from the checkout.
- **installing commands / menu launcher / boot service** — puts `lymnal` (and the
  optional `gate`) in `~/.local/bin`, adds **elyxr** to your applications menu,
  and starts lymnal as a **user** systemd service that also runs at boot.

**You're asked for your password once**, for that first-time system setup. After
that, updates never ask again — everything lives in your home directory.

Headless box with no screen? Add `--no-app` to build just the service:

```sh
./elyxr.sh --no-app
```

Other flags: `--no-service` (don't install/enable the boot service),
`--no-update` (build exactly what's checked out, skip the git self-update),
`--no-tailscale` (skip Tailscale), `--verbose` (stream the full build log).

---

## 2. Sign in to Tailscale

Your devices find each other over **Tailscale** — a private network of only your
own machines, with nothing exposed to the internet. When the installer opens your
browser, sign in. **Use the same account on every device** — that's what pairs
them into one tailnet.

The installer prints this machine's Tailscale address (like `100.x.y.z`) while it
sets up — that's the address other devices connect to, on port `7749`.

---

## 3. Make this device the trove (server)

1. Open **elyxr**, then **hold the wordmark** (the "ELYXR" text on the top rail)
   for a moment to open Settings.
2. Set **THIS DEVICE → Server**.
3. Open **PAIRING** so it starts accepting a device.

Prefer the terminal (or no screen)?

```sh
lymnal bind open           # start accepting a device
lymnal bind list           # see who's waiting
lymnal bind seal           # approve the one device waiting
lymnal bind close          # stop accepting
```

Point which folder is served with `lymnal trove set <path>`.

---

## 4. Connect this device to a trove (client)

If instead this Linux box is reaching *another* device's files:

1. Open **elyxr** — it starts as a **Client** and **looks for servers on your
   tailnet automatically**.
2. Tap your server in the list and **REQUEST ACCESS ▸**. If it doesn't appear,
   choose to enter the address by hand (`100.x.y.z:7749`).
3. Approve the request on the server. You're in.

Terminal equivalent: `lymnal bind 100.x.y.z:7749`.

Want the trove as a real folder in your file manager too? Settings → **Use System
File Browser** (Linux-only, off by default). It mounts the trove via the optional
**gate** and rides the same connection the app does.

---

## 5. Using and updating

- **Click** a file to select it (audio starts in the built-in player, and the
  folder it's in becomes the playlist). **Double-click** to open it in your
  default program — edits save back to the trove on their own.
- **Update** from the app's button or `lymnal update` — it updates this device and
  tells the rest of your fleet to follow, in the background.

Full command list: `lymnal status`, `lymnal update`, `lymnal bind …`,
`lymnal trove set …`. Stuck? See [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
