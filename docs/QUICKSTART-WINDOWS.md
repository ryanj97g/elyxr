# Quickstart — Windows

Windows installs from a normal `.exe` — no compiler, no terminal, no admin. A
Windows machine is usually a **client** (reaching another device's trove), but a
desktop can also serve its own folder.

---

## 1. Install

1. Go to the releases page: **https://github.com/ryanj97g/elyxr/releases**
2. Download **`elyxr-setup.exe`** (from the release tagged **`windows-latest`** —
   it's the one marked *Latest*).
3. Run it. It's a **per-user install — no administrator prompt.** It installs to
   `%LOCALAPPDATA%\Programs\elyxr`, adds a Start-menu shortcut, seeds a starter
   config, and sets **lymnal** (the background service) to start hidden at every
   login.

Windows may warn about an unrecognized app (it's an unsigned build) — choose
**More info → Run anyway**.

---

## 2. Tailscale

elyxr reaches your other devices over **Tailscale**. The installer installs it for
you (via `winget`; if that isn't available it opens Tailscale's download page).
**Sign in with the same account you use on your other devices** — that's what puts
them on one private network.

---

## 3. Connect

1. Open **elyxr** from the Start menu. It starts as a **Client** and **looks for
   servers on your tailnet automatically**.
2. Tap your server and **REQUEST ACCESS ▸**. If it doesn't show up, enter its
   address by hand (`100.x.y.z:7749` — the `100.x.y.z` is the server's Tailscale
   address; `7749` is always elyxr's port).
3. On the **server**, approve the waiting device (Settings → PAIRING → APPROVE, or
   `lymnal bind seal`). Approving also closes pairing.

The trove's files are now right there in elyxr — browse, open, add, delete. Each
file downloads only when you open it; nothing is mirrored onto this PC.

> Want this Windows desktop to be the **trove** instead? Hold the wordmark →
> Settings → **THIS DEVICE → Server**, then open **PAIRING**. (The optional
> system-file-browser mount is Linux-only; everything else works.)

---

## 4. Using and updating

- **Click** a file to select it — an audio file starts in the built-in player, and
  its folder becomes the playlist. **Double-click** to open it in your default
  program; edits save back to the trove on their own.
- **Updates** happen in the background. On Windows there's no compiler on the
  device, so an update **downloads the published installer and runs it silently** —
  the same end state as any Windows app updating itself. Start one from the app's
  update button or `lymnal update`, and the rest of your fleet follows.

Stuck? See [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
