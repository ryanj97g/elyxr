# Elyxr

Reach a folder on one of your machines from any of your others — over your
[Tailscale](https://tailscale.com) network — and have it feel like a flash
drive you plugged in.

One machine **serves** a folder. Your other machines **browse** it. Every
machine runs the same thing; a toggle in the app decides which role it plays.

## The pieces

You don't install these separately — the installer sets up all three:

- **Elyxr** — the app. The only thing you actually click.
- **lymnal** — the background service that serves a folder over your tailnet.
- **trove** — mounts a served folder as `~/Elyxr`, like a drive.

## Before you start

All your machines need to be on the **same Tailscale network**, with Tailscale
installed and connected. Everything runs over the tailnet — never the open
internet, no port forwarding.

## Install

On each device (Ubuntu / Zorin / Debian):

```sh
git clone https://github.com/ryanj97g/Elyxr.git
cd Elyxr
./elyxr.sh
```

That's the whole install. One command sets up everything, puts **Elyxr** in
your applications menu, and starts the background service.

- It asks for your password **once** at the start, then never interrupts again.
- Headless server with no screen? Add `--no-app` to skip building the UI.
- Nothing is hardcoded to anyone's machine — each device figures out its own
  address automatically.

## Connect two machines

Say you want to reach your desktop's files from your laptop.

**On the desktop (the one with the files):**

1. Open Elyxr → **hold the wordmark** (the "ELYXR" text) to open settings.
2. Set **THIS DEVICE** to **Server**.
3. Get ready to let your laptop in:
   ```sh
   lymnal bind open
   ```

**On the laptop:**

1. Open Elyxr — it starts as a **Client**.
2. Enter the desktop's Tailscale address (like `100.x.y.z:7749`).
3. It shows **four words** and waits.

**Back on the desktop:**

```sh
lymnal bind list                 # check the four words match, note the device name
lymnal bind approve <device>     # let it in
```

The laptop connects. Flip the **TROVE** switch in the app and the shared folder
appears as `~/Elyxr`.

## Keep it up to date

```sh
lymnal update
```

Pulls the latest, rebuilds only what changed, and restarts the service if it
needs it. Run it whenever.

## Terminal commands

Elyxr does all of this from the app — these exist for when you want the
terminal, or the machine has no screen.

```sh
lymnal status                      # what's configured, and how full the trove is
lymnal update                      # pull the latest and rebuild/restart

lymnal bind open                   # start accepting new devices
lymnal bind list                   # devices waiting, with their four-word phrase
lymnal bind approve <device> [--guest]
lymnal bind deny <device>
lymnal bind close                  # stop accepting devices

lymnal trove set <path>            # change which folder is served
```

## Build from source

```sh
cargo build --release              # lymnal + trove (Rust)
cd elyxr && flutter build linux    # the app (Flutter)
```
