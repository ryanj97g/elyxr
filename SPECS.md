# How elyxr works

Everything you need to *use* elyxr is in the [README](README.md). This is the
"how," for when you want it.

## The three programs

- **lymnal** (Rust) — the background service. On a **server** it shares one
  folder (the trove) over your tailnet; on a **client** it stays connected to
  its server and keeps the device up to date. One binary does both roles and the
  command-line operations, so they can never disagree. It runs as a systemd
  *user* service and shows a system-tray icon while it's running.
- **trove** (Rust, FUSE) — mounts a served folder so it appears as a normal
  folder on your device. Entries list instantly; a file's contents download
  when you open it.
- **elyxr** (Flutter) — the app. A Server/Client toggle sets the device's role,
  and the app starts lymnal in server mode and stops it in client mode so the
  two roles never collide.

## Network

- **Tailscale only.** Everything runs over your private tailnet — never the open
  internet, no ports opened, no port forwarding.
- **Nothing is hardcoded to a device.** Each device resolves its own tailnet
  address at startup, and lymnal binds to that address on port `7749`. A first
  run just means entering the server's address by hand once.

## Where things live

- Binaries: `~/.local/bin/lymnal` and `~/.local/bin/trove`. User-space, which is
  why updates never need a password.
- Config: `~/.config/lymnal/config.toml`.
- A client's link to its server: `~/.config/lymnal/link.json`. Its presence is
  what marks a device as a client — lymnal reads it to know which server to
  follow. The app writes it on pairing and removes it on forget.
- The pairing token is kept in the system keyring, never written to disk in the
  clear and never shown on screen.

## One copy, one owner

- **The server holds the only real copy.** Clients show a live window onto it, so
  nothing drifts out of sync and there are no conflicts to resolve. When the
  server is unreachable the folder simply isn't live — there is no stale local
  copy to reconcile later.
- **One trove path per device.** The server *serves* the folder; a client
  *mounts* it at the same place. Because the app runs lymnal in exactly one role
  per device, a serve and a mount never fight over the same path.

## Pairing

- A client requests access by tailnet address, and someone at the server
  approves it **by device name**. Approving connects the device and closes
  pairing in one step. There is no shared phrase or code: Tailscale (only your
  devices can reach each other) plus a human saying yes *is* the trust.
- Approval can grant **owner** or **guest** access, and a guest can be capped to
  a byte budget.

## Updates

- You update once, on the server. lymnal announces "update now" to every
  connected client over a live event stream, and each client then **pulls its own
  code from this repository** and rebuilds. The server never sends code — it only
  says when.
- The installer (`elyxr.sh`) is also the updater: it rebuilds only what changed,
  re-installs a binary only when it differs, and restarts the service only when
  its binary changed.
- A restart first waits for any in-flight upload to finish (`lymnal drain`), so an
  update never cuts one off.
- Because **lymnal** — the always-on service, not the app — receives the
  announcement, a device updates itself even with the elyxr window closed. If the
  window happens to be open, the installer restarts it onto the fresh build.

## The tray icon and notifications

- lymnal registers a **StatusNotifierItem** over D-Bus. The lymnal mark is
  embedded in the binary (and also installed into the icon theme), and the
  icon's menu opens elyxr or starts an update. Showing it needs a tray host:
  KDE has one by default; GNOME and Zorin provide one through the "AppIndicator
  and KStatusNotifierItem Support" extension.
- Update progress shows as two desktop notifications — one at the start, one when
  it's done — sent through libnotify to the desktop's notification daemon. A
  headless server with no daemon simply shows none.

## Build from source

The installer sets all of this up for you; this is only for building by hand.

```sh
cargo build --release              # lymnal + trove (Rust)
cd elyxr && flutter build linux    # the app (Flutter)
```

Requirements: a Rust toolchain, FUSE 3, and — for the app — the Flutter SDK with
the Linux desktop build dependencies.
