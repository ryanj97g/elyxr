# How elyxr works

Everything you need to *use* elyxr is in the [README](README.md). This is the
"how," for when you want it. The look-and-feel spec is in [DESIGN.md](DESIGN.md);
per-OS setup and fixes are in [docs/](docs/).

---

## The three programs

- **lymnal** (Rust); the always-on background service. One binary, both roles,
  chosen at startup by whether a `link.json` sits next to its config:
  - On a **server** (no `link.json`) it shares one folder; the trove; over your
    tailnet, binding its own Tailscale address on port `7749`.
  - On a **client** (`link.json` present) it does two jobs: it keeps the device
    updated, and it runs a small local proxy on `127.0.0.1:7749` that the app talks
    to; queuing your saves in **lymbo** and forwarding everything else to the
    trove; so the app never reaches across the tailnet itself. It runs as a
    systemd *user* service and shows a tray icon.
- **elyxr** (Flutter); the app, and the main way in on every device. It browses,
  opens, plays, and edits the trove; a Server/Client toggle sets the device's role.
  A single click selects a file (audio plays in a built-in player and its folder
  becomes a playlist); a double-click opens it in the default program;
  click-and-hold multi-selects. Terminal fonts dropped into
  `elyxr/assets/fonts/custom/` are registered at runtime, so adding a face needs no
  code change.
- **gate** (Rust, FUSE); optional, Linux-only. Surfaces the trove as a real folder
  in your file manager (off by default; Settings → *Use System File Browser*). It
  talks to the local lymnal proxy, so it rides the same write-back lymbo the app
  does; and it keeps its own FUSE-level read cache on top of that for the files
  you open through the folder. (Formerly the `trove` crate.)

---

## Network

- **Tailscale only.** Everything runs over your private tailnet; never the open
  internet, no ports opened, no port forwarding. lymnal uses the **OS-level**
  Tailscale (it shells out to `tailscale ip -4` to learn its own address); it does
  not embed Tailscale, and on Android you install and sign into the Tailscale app
  yourself.
- **Nothing is hardcoded to a device.** Each device resolves its own tailnet
  address at startup and lymnal binds it on port `7749`. A first run auto-discovers
  servers on the tailnet; entering an address by hand is only the fallback.

---

## Network configuration

lymnal binds the address set in `bind` in `~/.config/lymnal/config.toml`.

- `bind = "auto"` (or `"tailscale"`) is the default and the normal path: lymnal
  runs `tailscale ip -4` and binds this machine's tailnet address, so everything
  stays on your private tailnet.
- `bind = "<ip>:7749"` binds a specific address. Use this when the machine is
  reached over a private network that isn't Tailscale (for example a plain
  WireGuard tunnel, where you set the address by hand), or when the server sits
  behind a Tailscale subnet router and has no tailnet address of its own.
- Reaching a server through a Tailscale subnet router lets the trove run on a box
  that can't run Tailscale itself (a locked-down NAS, an appliance). Run a
  Tailscale subnet router on the same LAN (`tailscale up --advertise-routes=<lan-cidr>`),
  set the server's `bind` to its LAN address, and point clients at that LAN
  address on port 7749. Traffic still travels over your private tailnet to the
  router and only the last hop is local; nothing is exposed to the internet. The
  client you're using still has to be on the tailnet.
- `bind = "0.0.0.0:7749"` listens on every interface. This reaches past your
  tailnet, so the "only your own devices can reach the server" assumption that
  pairing depends on no longer holds; anything that can route to the machine can
  reach lymnal (still behind the bearer token, and pairing still needs a person
  to approve). Prefer `auto` or a specific private address.

Headscale works the same as Tailscale here, since it uses the same `tailscale`
client that `auto` calls.

## Architecture: one copy, one owner

- **The server holds the only real copy**: the trove, the source of truth. The
  trove is a security boundary: every request path is normalised and re-checked to
  stay inside it (no `..`, no absolute/home paths, symlinks resolved and
  re-validated).
- **A client routes through its own lymnal.** The app (and the gate) talk to
  `127.0.0.1:7749`, the local proxy, which forwards to the remote trove with the
  stored bearer token in front of lymbo. The app never holds the token.
- **The server works its own disk directly.** In server mode the app reads and
  writes the trove folder straight off local disk; no token, no network, no lymbo.
  It connects to the local lymnal's admin surface (with a machine-local admin
  token) only to manage pairing, devices, and limits.

---

## lymbo: write-back only

**lymbo is a write-back buffer, not a read cache.** Concretely:

- Opening/downloading a file streams straight from the trove and is **not** kept.
- The *only* thing lymbo serves on a read is a file that is still **held**: one
  you saved that hasn't landed on the trove yet; because its local bytes are the
  freshest.
- Once a held file is successfully pushed to the trove, it is **evicted
  immediately**. lymbo never grows into a mirror of what you've viewed.

A file in lymbo is therefore either **held** (unsynced, pinned, never evicted, the
only copy until it lands) or, briefly, a save **passing through** to the trove. It's
bounded by *leaving room*; free disk never falls below the larger of 15% or 2 GB; 
rather than a fixed size. A save that could only fit by dropping held work is
refused (`LYMBO_FULL`, HTTP 507) instead; held work is never sacrificed. lymbo lives
at `~/.cache/lymnal/lymbo` and is safe to delete except for anything still held.

### Editing and sync

Open a file in your default program and elyxr watches the working copy; both by
filesystem events and a periodic re-scan, so a save is caught even from editors that
write to a temp file and rename it into place. A real change (writes settled for a
moment, and the content actually different) uploads back through the proxy. It lands
on the trove at once when reachable; otherwise it stays **held**, where a background
pusher retries every few seconds until it lands. So a save made during a lapse is
never lost, and the refresh control (`lymnal drain` / the app) drains the queue on
demand. **Last writer wins:** each upload carries the edit's own save time, and the
most recent is the truth.

---

## Backup and recovery

elyxr keeps one copy of your files: the trove folder on the server. Clients keep
nothing, and lymbo empties as soon as a save lands. elyxr is a transport, not a
backup; it doesn't replicate the trove or keep versions. If the trove folder is
lost and you have no backup of it, it's gone.

Because the trove is an ordinary folder, back it up with whatever tool you already
use, pointed at that one folder. For example, with restic:

```sh
restic -r /path/to/backup backup ~/trove
```

rsync, borg, Time Machine, a scheduled tarball, or a second drive all work the
same way. Keeping that copy safe over time is the backup tool's job, the same as
backing up a database's data directory.

To recover: reinstall lymnal, restore the trove folder from your backup, run
`lymnal trove set <path>` if it moved, and re-pair the clients (they hold no data,
so they only need to request access again).

## Where things live

- **Binaries:** `~/.local/bin/lymnal`, and `~/.local/bin/gate` (the optional
  mount). User-space, which is why updates never need a password.
- **Config:** `~/.config/lymnal/config.toml` (see [config.example.toml](config.example.toml)).
- **Data dir:** `~/.local/share/lymnal/`; holds `admin.token` (machine-local,
  never sent over the network), `address` and `trove.path` (so local server-mode
  elyxr finds things), `tokens.db` (paired devices), `usage.db` (running total), and
  `staging/` (in-flight uploads, swept after 48h).
- **lymbo:** `~/.cache/lymnal/lymbo` (honors `XDG_CACHE_HOME`).
- **A client's link to its server:** `~/.config/lymnal/link.json`; its presence is
  what marks a device a client. The app writes it on pairing and removes it on
  forget. `repo.path` (the recorded checkout location) sits alongside it.
- The bearer token is kept in the system keyring, never written to disk in the clear
  and never shown on screen.

---

## Pairing

Pairing is off by default and only works while switched on in server mode; a request
times out after ~2 minutes.

1. **Open**: the server operator opens pairing (Settings → PAIRING, or
   `lymnal bind open`).
2. **Request**: a client sends its device name to the server's `/v1/pair` (auto on
   discovery, or `lymnal bind <address>`). The request blocks, waiting for a human.
3. **Approve / deny**: the operator sees it *by device name* and approves or
   denies. Approving mints a bearer token, records the device, and **closes pairing
   in one step**. There is no shared phrase or code: Tailscale (only your devices
   can reach each other) plus a human saying yes *is* the trust.
4. The client stores the token in its keyring and writes `link.json`.

Approval grants **owner** or **guest**, and a guest can be capped to a byte budget.

---

## Auth & roles

- Every request to the trove carries `Authorization: Bearer <token>`; only argon2id
  hashes are stored server-side, verified in constant time. Health and pairing are
  the only unauthenticated endpoints.
- Two roles: **owner** and **guest** (a guest defaults to a 10 GB cap; the effective
  upload ceiling is `min(trove limit, device cap)`).
- **Only an owner can trigger a fleet update.** Browsing, downloading, uploading,
  and **mutations (move/delete/mkdir) work for any approved device**, owner or
  guest; the role gates the fleet update, not day-to-day file operations. A guest
  cap limits bytes, not what a guest can change or delete.
- The **admin surface** (`/v1/admin/*`) is reached only with the machine-local admin
  token and is never exposed to the tailnet; it's how server-mode elyxr and the
  `lymnal bind` CLI manage the local service.

---

## Updates

- You update from **any device**. Only the server can reach every device, so a
  client's update simply asks the server to update the fleet: the server announces
  "update now" to every connected client over a live event stream *and* updates
  itself. Each device then **pulls its own code from this repository** (or, on
  Windows, fetches the published installer) and applies it; the server never sends
  code, it only says when.
- A device offline for the announcement still catches up: lymnal also polls the
  server's build number about once a minute and updates the moment the server is
  ahead. The build number is the git commit count, stamped in at build time so it
  advances on every change; including one that only touches the app.
- **Linux applies by rebuilding** from source via the installer; **Windows applies
  by fetching** the published `elyxr-setup.exe` and running it silently (there's no
  compiler on the device); **Android** downloads the new APK and hands it to the
  system installer (same signing key → in-place upgrade).
- The installer (`elyxr.sh`) is also the updater: it self-updates the checkout
  first, rebuilds only what changed, re-installs a binary only when it differs, and
  restarts the service only when its binary changed. If a fast-forward is impossible
  (upstream history was rewritten), it hard-resets the checkout to the published
  branch rather than silently building stale code.
- **A routine update needs no password.** Everything it does happens in your home
  directory. A background/tray/fleet update runs detached with no terminal, so if it
  ever finds a genuinely new *system* package (root, once) it skips that and asks
  you to run the installer once in a terminal to finish it. That first-time system
  setup is the only step that ever asks for a password.
- A restart first waits for any in-flight upload to finish (`lymnal drain`).

---

## Android

The phone runs the identical **client → local-lymnal → trove** model as desktop.
Since Dart can't shell out on Android, the app asks the native side (a MethodChannel)
to run a **foreground service** that execs the bundled `liblymnal.so` on
`127.0.0.1:7749`; so the app talks to its own local lymnal, never straight to the
server. The service runs only once paired (a `link.json` exists in the app's private
data dir) and shows an ongoing notification. A phone is **always a client**: it has
no local trove to host. Tracker modules render via a bundled `libmodrender.so`, and
compressed audio is decoded to PCM via the platform's `MediaCodec` (there's no
ffmpeg on a phone).

---

## Media pipeline

- **Playback** is via `audioplayers` (GStreamer on Linux). Accepted: ogg, mp3, wav,
  flac, m4a, aac, opus, plus tracker modules (xm/mod/s3m/it), which are rendered to
  WAV on load.
- **The visualizer reads raw PCM at the play head**: the real FFT of the real
  audio at the exact instant, computed on demand (a 1024-sample Hann-windowed FFT
  bucketed into 28 log-spaced bars), never a lagging speaker capture and never
  affecting playback. Getting PCM from compressed audio needs a decode to a
  throwaway WAV: **ffmpeg on desktop, native MediaCodec on Android**.
- **Video-in-disguise:** an `.m4a`/`.mp4`/`.mov` carrying a video track is stripped
  to audio before playback so no picture window appears; ffmpeg `-vn` on desktop,
  a native PCM decode on Android (which doubles as the visualizer's input).

---

## The tray icon and notifications

lymnal registers a **StatusNotifierItem** over D-Bus; its menu opens elyxr, starts
an update, or refreshes the connection. Showing it needs a tray host; KDE has one;
GNOME and Zorin need the "AppIndicator and KStatusNotifierItem Support" extension.
The Windows build shows an equivalent tray. Update progress shows as two desktop
notifications (start and done); a headless server with no daemon simply shows none.

---

## HTTP API reference

All routes are under `/v1`. Auth is per-endpoint: everything needs
`Authorization: Bearer <token>` except `/v1/health` and `/v1/pair`. Errors share one
JSON shape: `{ code, message, request_id, detail?, hint? }`, where `message` is
written for a person and shown verbatim. The client proxy mirrors this API on
loopback and adds `POST /v1/reconcile`.

### Browse

| Endpoint | Notes |
|---|---|
| `GET /v1/health` | *(no auth)* `{ version, build, commit, uptime_s, trove, used_bytes, max_bytes, drive_free_bytes, pairing_open }` |
| `GET /v1/list` | Query: `path`, `sort` (`name`\|`size`\|`mtime`), `order` (`asc`\|`desc`), `limit`, `cursor`. Returns `{ path, entries[], next_cursor, used_bytes, warnings[] }`. Folders sort first; the cursor is opaque. |
| `GET /v1/stat` | Query `path` → `{ path, name, kind, size_bytes, mtime, mime, etag }` (etag is a weak size:mtime tag, not a content hash). |
| `GET /v1/search` | Query `q` (≥2 chars), `path`, `limit`. Recursive filename substring; stops at the limit or a 3s deadline (`truncated`, `reason`). |

### Transfer

| Endpoint | Notes |
|---|---|
| `POST /v1/resolve` | `{ paths[] }` → flattened `{ files[], file_count, total_bytes, collisions[], mode }` (`mode` = `loose` or `zip`). |
| `GET /v1/download` | Query `path`. Streamed; supports `Range`/`If-Range` (206) and `If-None-Match` (304); `ETag`, `Content-Disposition`. |
| `POST /v1/zip` | `{ paths[], name? }` → streamed store-method zip, never staged to disk. |
| `POST /v1/upload/init` | `{ path, size_bytes, checksum?, mtime? }` → **201** `{ upload_id, chunk_bytes, received_bytes, target_exists, expires_at }`. Limits checked up front. |
| `PUT /v1/upload/:id` | One chunk; requires `Content-Range`. Out-of-order and idempotent. → `{ received_bytes, complete }`. |
| `GET /v1/upload/:id` | Progress for resume: `{ received_bytes, size_bytes, missing[[start,end]], expires_at }`. |
| `POST /v1/upload/:id/commit` | Verifies checksum, renames into place, emits a `change` event → `{ path, size_bytes, replaced, identical, used_bytes, warnings[] }`. |
| `DELETE /v1/upload/:id` | Discard staging. **204**. |

### Mutate

| Endpoint | Notes |
|---|---|
| `POST /v1/move` | `{ from, to, on_conflict? }` (`fail`\|`replace`\|`suffix`). Rename, not copy; emits removed + created. |
| `POST /v1/delete` | `{ paths[] }`. Permanent, recursive; partial success is normal → `{ deleted[], failed[], freed_bytes, used_bytes }`. |
| `POST /v1/mkdir` | `{ path }` → **201** new / **200** existing. |

### Stream, update, pairing

| Endpoint | Notes |
|---|---|
| `GET /v1/events` | SSE. Events: `change` (`created`/`modified`/`removed` + entry), `usage`, `update` (`build`), plus `ping`. Monotonic ids for `Last-Event-ID` resume. |
| `POST /v1/update` | **Owner only.** Announces `update` to clients and self-updates the server. |
| `POST /v1/pair` | *(no auth, tailnet-reachable)* `{ device, client }`. Blocks up to ~120s for approval → `{ token, label, role, max_bytes }`, or a `PAIRING_*` error. |

### Admin (`/v1/admin/*`, machine-local `X-Admin-Token` only)

`status`, `pairing` (open/close), `pending`, `approve` (`{device, role?, max_bytes?}`),
`deny`, `devices`, `revoke`, `space`, `limits`, `recount`, `problems`,
`announce-update`. Never exposed to the tailnet.

### Error codes

`BAD_TOKEN`/`TOKEN_REVOKED` (401), `PERMISSION_DENIED`/`PATH_ESCAPES_TROVE`/
`PAIRING_CLOSED`/`PAIRING_DENIED` (403), `BAD_PATH` (400), `NOT_FOUND` (404),
`TARGET_EXISTS`/`NOT_EMPTY`/`INCOMPLETE_UPLOAD` (409), `CHECKSUM_MISMATCH` (422),
`UPLOAD_EXPIRED` (410), `PAIRING_TIMEOUT` (408), `TROVE_FULL`/`DRIVE_FULL`/
`LYMBO_FULL` (507), `IO_ERROR` (500).

Three failures the app reports itself, because the request never reaches lymnal:
**timeout** → "Can't reach `<server>`. It may be asleep or off."; **no tailnet** →
"Tailscale isn't connected on this device."; **401** → "This device is no longer
approved."

---

## Build from source

The installer sets all of this up for you; this is only for building by hand.

```sh
cargo build --release              # lymnal + gate (Rust)
cd elyxr && flutter build linux    # the app (Flutter)
```

**Requirements**: a Rust toolchain, the Flutter SDK, and these system packages on
Linux (the installer lists them): `build-essential`, `pkg-config`, `git`, `fuse3`,
`libfuse3-dev`, `clang`, `cmake`, `ninja-build`, `libgtk-3-dev`, `liblzma-dev`,
`libsecret-1-dev`, `libjsoncpp-dev`, `libgstreamer1.0-dev`,
`libgstreamer-plugins-base1.0-dev`, `gstreamer1.0-plugins-base`,
`gstreamer1.0-plugins-good`, `gstreamer1.0-libav`, `libasound2-dev`, `libmpv-dev`,
`openmpt123`, `ffmpeg`. The build number comes from the git commit count, so build
from a full clone (a shallow clone reports `1`).
