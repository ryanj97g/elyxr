# Quickstart — Android

An Android phone is always a **client** — it reaches another device's trove; it
never hosts one. There's no build on the phone: you install a prebuilt APK, and it
runs its own on-device lymnal so it works exactly like a desktop client.

---

## 1. Install Tailscale first (required)

elyxr reaches your other devices over **Tailscale**, and on Android that part is
**not** automated — you set it up yourself, once:

1. Install **Tailscale** from the Play Store.
2. Sign in with the **same account** you use on your other elyxr devices.

Without Tailscale connected, elyxr will say *"Tailscale isn't connected on this
device."*

---

## 2. Get the APK

The APK lives on the GitHub releases page, under the release tagged
**`android-latest`**, as **`elyxr.apk`**. Direct link:

```
https://github.com/ryanj97g/elyxr/releases/download/android-latest/elyxr.apk
```

Or browse: **https://github.com/ryanj97g/elyxr/releases** → open **android-latest**
→ download **`elyxr.apk`**.

Open the downloaded file to install. Android will ask permission to *install
unknown apps* for whatever app you downloaded with (your browser or Files app) —
allow it, then tap **Install**.

---

## 3. Connect

1. Open **elyxr**. It runs as a **Client** and **looks for servers on your tailnet
   automatically**.
2. Tap your server and **REQUEST ACCESS ▸**. If it doesn't appear, enter its
   address by hand: `100.x.y.z:7749` (the server's Tailscale address, elyxr's port
   is always `7749`).
3. On the **server**, approve the waiting device (Settings → PAIRING → APPROVE, or
   `lymnal bind seal`).

You'll see a **persistent notification** for elyxr — that's the on-device lymnal
running as a foreground service, which is what lets the phone hold its connection
and updates. It's normal; leave it be.

---

## 4. Using and updating

- **Tap** a file to select it — audio starts in the built-in player, and its
  folder becomes the playlist (the lightshow reacts to it, too). **Double-tap** to
  open it in another app; edits sync back to the trove.
- The chassis draws **edge-to-edge, under the camera cutout** — full screen, no
  black bar.
- **Updates:** the app's update button (or an update triggered from any device in
  your fleet) downloads the new APK and hands it to the system installer — **one
  tap to install over the top, no uninstall**, because every build is signed with
  the same key.

### If an update ever says "App not installed / signatures don't match"

That only happens coming *from* a build made before consistent signing. Uninstall
elyxr once, install the fresh APK, and every update after that installs in place.

Stuck? See [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
