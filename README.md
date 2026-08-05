# elyxr

Reach a folder on one of your machines from any of your others — over your
[Tailscale](https://tailscale.com) network — and have it feel like a drive you
plugged in.

One machine **serves** a folder. Your other machines **browse** it live. Every
machine runs the same thing; a toggle in the app decides which role it plays.

## The pieces

You don't install these separately — one command sets up all three:

- **elyxr** — the app. The only thing you actually click.
- **lymnal** — the background service that serves a folder over your tailnet.
- **trove** — mounts a served folder on your Desktop, like a plugged-in drive.

## Install

On each device (Ubuntu / Zorin / Debian):

```sh
git clone https://github.com/ryanj97g/elyxr.git
cd elyxr
./elyxr.sh
```

That's the whole install. One command sets up everything, puts **elyxr** in your
applications menu, and starts the background service.

- **Tailscale is set up for you.** If it isn't already on the machine, the
  installer installs it and walks you through the one browser sign-in. Use the
  **same account on every device** — that's what lets them see each other.
- **Setup asks for your password once** (system libraries, first-time service
  setup). After that, **updates never ask again.**
- Headless server with no screen? Add `--no-app` to skip building the UI.
- Nothing is hardcoded to anyone's machine — each device finds its own tailnet
  address automatically.

## Connect two machines

Say you want to reach your desktop's files from your laptop.

**On the desktop (the one with the files):**

1. Open elyxr → **hold the wordmark** (the "ELYXR" text) to open settings.
2. Set **THIS DEVICE** to **Server**.
3. In the server panel, open **PAIRING** so it starts accepting a device.

**On the laptop:**

1. Open elyxr — it starts as a **Client**.
2. Enter the desktop's Tailscale address (like `100.x.y.z:7749`).
3. It shows **four words** and waits.

**Back on the desktop:** the waiting laptop appears in the server panel with the
same four words. Check they match, then tap **APPROVE**.

The laptop connects. Flip the **TROVE** switch and the shared folder appears on
its Desktop as `~/Desktop/trove` — open it and the desktop's files are right
there, downloaded only as you open them.

Prefer the terminal, or the server has no screen? The same thing from the CLI:

```sh
lymnal bind open     # accept a device; shows its four-word phrase and asks y/N
lymnal bind seal     # or: approve the one device that's waiting, no name needed
```

## Using it

The trove is a live window into the server, not a copy:

- **Open a file** and it downloads just that file, right then.
- **Drop a file in** (or use the app's upload button) and it's saved to the
  server — every device sees it.
- **Delete a file** and it's gone from the server, so it's gone everywhere. The
  app confirms first, since the folder is shared.
- Nothing to sync by hand; using files *is* the sync. When the server is
  unreachable the folder isn't live — there's no stale copy to reconcile later.

## Updates

Update **once, on the server** — the button in its panel, or `lymnal update` in
a terminal — and everything follows:

- The server tells connected clients the moment it starts, and they update
  themselves in step.
- Each device rebuilds in the background while you keep using it, then **closes
  and reopens on its own** when it's done. No password, no confirmation.
- The only thing that pauses a restart is a file mid-upload — it waits for that
  to finish, then restarts immediately.

Each device always pulls its own code from this repository; the server only ever
says "update now," never sends code.

## Terminal commands

elyxr does all of this from the app — these exist for when you want the
terminal, or the machine has no screen.

```sh
lymnal status                      # what's configured, and how full the trove is
lymnal update                      # update this device (and announce to clients)

lymnal bind open                   # accept a device (shows its phrase, asks y/N)
lymnal bind seal                   # approve the lone waiting device, no name
lymnal bind list                   # devices waiting, with their four-word phrase
lymnal bind approve <device> [--guest]
lymnal bind deny <device>
lymnal bind close                  # stop accepting devices

lymnal trove set <path>            # change which folder is served
```

## How it works

- **Tailscale only.** Everything runs over your private tailnet — never the open
  internet, no ports opened, no port forwarding.
- **The server holds the only real copy.** Clients show a live window, so
  nothing drifts out of sync and there are no sync conflicts to resolve.
- **One trove path, one owner per device.** The server *serves* the folder; a
  client *mounts* it at the same place. The app runs lymnal in server mode and
  stops it in client mode, so the two never collide.
- **User-space install.** Binaries live in `~/.local/bin` and lymnal runs as a
  user service, which is why updates never need a password.

## Build from source

```sh
cargo build --release              # lymnal + trove (Rust)
cd elyxr && flutter build linux    # the app (Flutter)
```
