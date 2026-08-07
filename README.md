# elyxr

Your stuff lives on one device; elyxr lets you reach all of it from any of your
other devices.

"Oh, so a dropbox dupe?" NOPE. Dropbox and Syncthing keep you "in sync" by
putting a copy of everything on every device: 150 GB of files in your storage
device? You'd need 150 GB free on each device you want to retrieve from! Do you
have that much space to spare?? elyxr doesn't work that way. You see everything,
and a file only gets downloaded when you NEED it. Your files stay on the trove
device that ACTUALLY stores them, and your other devices download ONLY what you
need from your trove device, WHEN you need it on another device.

Open a file and it's just there now, wherever you put it. No danger of 2 out of
sync files! Ever!

## The pieces

- **elyxr** (the part that feels like magic)
- **lymnal** (the liminal service connecting your devices)
- **trove** (where your treasure is kept)

## Install

On each device (Ubuntu / Zorin / Debian):

```sh
git clone https://github.com/ryanj97g/elyxr.git
cd elyxr
./elyxr.sh
```

That's the whole install. It sets everything up, puts **elyxr** in your
applications menu, and starts the background service.

- **Your devices find each other over Tailscale.** It's a free app that puts
  just your own devices together on a private network of their own, so they can
  reach each other directly, with nothing open to the rest of the internet. The
  installer sets it up for you; the one part it can't handle is the sign-in, so
  it sends you to your browser to do that once. Use the **same account on every
  device** — that's what pairs them together.
- **You're asked for your password once**, for first-time setup. After that,
  updates never ask again.
- Headless server with no screen? Add `--no-app` to skip the app.

## Connect two devices

Say you want your laptop to reach your desktop's files.

**On the desktop (the one with the files):**

1. Open elyxr, then **hold the wordmark** (the "ELYXR" text) to open settings.
2. Set **THIS DEVICE** to **Server**.
3. Open **PAIRING** so it starts accepting a device.

**On the laptop:**

1. Open elyxr — it starts as a **Client**.
2. Enter the desktop's Tailscale address (like `100.x.y.z:7749`) and wait.

That `100.x.y.z` is nothing to go hunting for: the installer prints it to the
terminal while it sets the desktop up, so it's right there in what you already
ran. The `:7749` after it is always elyxr's port.

**Back on the desktop:** the laptop appears by name. Tap **APPROVE** and it
connects — approving also closes pairing, so nothing else can slip in.

The laptop is connected, and the desktop's files are **right there in elyxr** —
browse them, open them, add and delete — each one downloading only when you open
it. Nothing is copied to the laptop; the files stay the desktop's.

Want the trove as a real folder in your file manager too? On the laptop, hold the
wordmark → Settings → **Use System File Browser**. It's off by default and
Linux-only — the in-app browser is the main way in; the folder is an extra.

Rather stay in the terminal, or the server has no screen? The same thing:

```sh
# on the laptop — connect to the server:
lymnal bind 100.x.y.z:7749

# on the desktop — approve the waiting laptop:
lymnal bind seal
```

## Using it

The trove is a live window into the server, not a copy:

- **Open a file** and just that file downloads, right then. Images preview in the
  app; other files open in your default program, and any edits you save come back
  to the trove on their own.
- **Add a file** — the app's upload button, or drag one in — and it's saved to the
  server, so every device sees it.
- **Drag a file out** of the app's window and it downloads to wherever you drop it.
- **Delete a file** and it's gone everywhere. The app asks first, since the trove
  is shared.

No syncing by hand — using the files *is* the sync. A save made while the server
is unreachable waits on this device and lands the moment it's back.

## Updates

Update from **any device** — the button in the app, or `lymnal update` — and
every other device updates itself in step, whichever one you started from. It
happens in the background while you keep working: a popup when it starts, a popup
when it's done, and the app closes and reopens on its own when it's ready. No
password, no confirmation. The only thing that waits is a file mid-upload.

## Make it yours

Hold the wordmark to open settings. None of this changes what elyxr *does* —
it's just how it looks and feels on this device:

- **Accent** — eight phosphor colours; drag a swatch to push its glow (or the
  white one's brightness).
- **Tube** — dark glow, or light paper.
- **Density** — how large the text sits.
- **Typeface** — the terminal font, from VT323 to a dozen others.

And a few practical ones, in the same place:

- Where downloads land, and how many transfer at once.
- Whether deleting asks first.
- *(Linux)* whether the trove also shows up as a folder in your file manager,
  and where it mounts.

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

Curious how any of this works under the hood? See [SPECS.md](SPECS.md).
