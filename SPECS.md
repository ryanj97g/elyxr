# How elyxr works

Everything you need to *use* elyxr is in the [README](README.md). This is the
"how," for when you want it.

## The three programs

- **lymnal** (Rust) — the background service, one binary, both roles. On a
  **server** it shares one folder (the trove) over your tailnet. On a **client**
  it does two jobs: it keeps the device updated, and it runs a small local proxy
  the app talks to — caching reads and queuing writes in **limbo** — so the app
  never reaches across the tailnet itself. It runs as a systemd *user* service
  and shows a system-tray icon.
- **elyxr** (Flutter) — the app, and the main way in on every device. It browses,
  opens, and edits the trove; a Server/Client toggle sets the device's role.
- **gate** (Rust, FUSE) — optional, Linux-only. Surfaces the trove as a real
  folder in your file manager (off by default; Settings → *Use System File
  Browser*). It's a thin window onto the local lymnal proxy, so it rides the same
  limbo the app does. (Formerly the `trove` crate.)

## Network

- **Tailscale only.** Everything runs over your private tailnet — never the open
  internet, no ports opened, no port forwarding.
- **Nothing is hardcoded to a device.** Each device resolves its own tailnet
  address at startup, and lymnal binds to that address on port `7749`. A first
  run just means entering the server's address by hand once.

## Where things live

- Binaries: `~/.local/bin/lymnal`, and `~/.local/bin/gate` (the optional mount).
  User-space, which is why updates never need a password.
- Config: `~/.config/lymnal/config.toml`.
- limbo (a client's cache and queue): `~/.cache/lymnal/limbo`. Ephemeral — safe
  to delete, costs only a re-fetch, except for anything still *held*.
- A client's link to its server: `~/.config/lymnal/link.json`. Its presence is
  what marks a device as a client — lymnal reads it to know which server to
  follow. The app writes it on pairing and removes it on forget.
- The pairing token is kept in the system keyring, never written to disk in the
  clear and never shown on screen.

## One copy, one owner

- **The server holds the only real copy** — the trove, the source of truth. A
  client keeps no copy; its lymnal caches only what you've opened, in limbo,
  bounded so it can never become a full mirror.
- **The client routes through its own lymnal.** The app (and the gate) talk to
  `127.0.0.1:7749`, the local proxy, which forwards to the remote trove with limbo
  in front. The **server** works its own disk directly — browsing, opening, adding,
  and editing all land straight on the local folder, with no token and no limbo;
  routing the server through its own lymnal would be a loop with no purpose.

## limbo, editing, and sync

- **limbo** is the client's lobby: a capped working-set and outbound queue, owned
  by lymnal. It's bounded by *leaving room* — free disk never falls below 15% of
  the disk or 2 GB, whichever is larger — rather than a fixed size. A file in it
  is either **held** (unsynced, never evicted, the only copy until it lands) or
  **passing through** (synced, ordinary LRU). It is never the trove and never a
  user-facing folder.
- **Editing syncs back.** Open a file in your default program and elyxr watches
  the copy; a real change — writes settled for a moment, and the content actually
  different — uploads back through the proxy. It lands on the trove at once when
  reachable, and otherwise stays *held*, where a background pusher retries every
  few seconds until it lands. So a save made during a lapse is never lost, and the
  refresh control drains the queue on demand.
- **Last writer wins.** A write is a deliberate act, so the most recent upload is
  the truth; each carries the edit's own save time. A commit that could only fit
  in limbo by dropping held work is refused instead — held work is never
  sacrificed.

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
cargo build --release              # lymnal + gate (Rust)
cd elyxr && flutter build linux    # the app (Flutter)
```

Requirements: a Rust toolchain, the Flutter SDK with the Linux desktop build
dependencies, and — only for the optional gate — FUSE 3.
