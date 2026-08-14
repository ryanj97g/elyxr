# Quickstart

Devices reach each other over Tailscale. Install Tailscale on each device and sign
in with the **same account**: that puts them on one private network. Then set up
elyxr per the section for your OS.

A device is either a **server** (holds the trove folder and shares it) or a
**client** (reaches a server's trove). Desktops can be either; a phone is always a
client.

---

## Linux

Supported: apt-based distributions (Ubuntu, Zorin, Debian). The installer exits with
a message on anything else.

**Install:**

```sh
git clone https://github.com/ryanj97g/elyxr.git
cd elyxr
./elyxr.sh
```

`./elyxr.sh` installs the system build dependencies, installs Tailscale (it opens a
browser once for sign-in), fetches Rust and the Flutter SDK if missing, builds
lymnal and the app, puts `lymnal` in `~/.local/bin`, adds elyxr to the
applications menu, and starts lymnal as a user service that runs at boot. It
asks for your password once, for that first system-package step; after that,
updates run without root.

Flags: `--no-app` (build only the service, for a headless box), `--no-service`,
`--no-update`, `--no-tailscale`, `--verbose`.

**Serve the trove (server):** open elyxr, hold the wordmark to open Settings, set
THIS DEVICE → Server, then open PAIRING. Terminal: `lymnal bind open`, then
`lymnal bind seal` to approve. Change which folder is served with
`lymnal trove set <path>`.

**Reach a trove (client):** open elyxr; it starts as a client and lists servers it
finds on the tailnet. Pick yours and REQUEST ACCESS (or enter the address by hand,
`100.x.y.z:7749`, if it isn't listed). Approve the device on the server. Terminal:
`lymnal bind 100.x.y.z:7749`.

---

## Windows

**Install:** download `elyxr-setup.exe` from
https://github.com/ryanj97g/elyxr/releases (the `windows-latest` release, marked
Latest) and run it. It's a per-user install with no administrator prompt. It
installs to `%LOCALAPPDATA%\Programs\elyxr`, adds a Start-menu shortcut, seeds a
starter config, installs Tailscale (via winget, or opens the download page), and
starts lymnal hidden at each login. Windows may warn about an unrecognized app (the
build is unsigned); choose More info → Run anyway.

Sign into Tailscale with the same account as your other devices.

**Reach a trove (client):** open elyxr from the Start menu. It lists servers it
finds on the tailnet; pick yours and REQUEST ACCESS (or enter `100.x.y.z:7749`).
Approve the device on the server.

**Serve the trove:** a Windows desktop can also be a server; hold the wordmark →
Settings → THIS DEVICE → Server, then open PAIRING.

---

## Android

A phone is always a client. There's no build on the phone; you install a prebuilt
APK, and it runs its own on-device lymnal, so it behaves like a desktop client.

1. **Install Tailscale** from the Play Store and sign in with the same account as
   your other devices. This is not automated on Android; without it elyxr reports
   "Tailscale isn't connected on this device."
2. **Get the APK** from
   `https://github.com/ryanj97g/elyxr/releases/download/android-latest/elyxr.apk`
   (or the releases page → `android-latest` → `elyxr.apk`). Open it to install;
   allow "install unknown apps" for the app you downloaded with, then Install.
3. **Connect:** open elyxr. It lists servers on the tailnet; pick yours and REQUEST
   ACCESS (or enter `100.x.y.z:7749`). Approve the device on the server.

elyxr shows an ongoing notification while running; that's the on-device lymnal
service holding the connection.

**Updates:** the app downloads the new APK and opens the system installer; because
every build is signed with the same key, it installs over the top with no
uninstall. If an update ever reports a signature mismatch (only from a very old
build), uninstall once and install the current APK; updates after that install in
place.

---

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) if something doesn't work.
