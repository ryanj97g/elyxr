# Elyxr

Reach a folder on your server from anywhere on your tailnet, and have it feel
like a flash drive you plugged in.

- `lymnal/` — lymnal, the server service (Rust). One binary: `lymnal` runs the
  service, `lymnal <command>` does the troubleshooting operations.
- `elyxr/` — the desktop app (Flutter, Linux)
- `trove/` — mounts the trove as `~/Elyxr` (Rust, FUSE)

## Build

```sh
cargo build && cargo test                                  # the Rust services
cd elyxr && flutter pub get && flutter test && flutter build linux
```

## Run lymnal

Copy `config.example.toml` to `~/.config/lymnal/config.toml`, set `bind` to this
machine's Tailscale address, then:

```sh
lymnal                 # run the service
lymnal status          # what's configured and how full the trove is
lymnal token list      # approved devices
lymnal recount         # recount the trove's usage
```

Elyxr does all of this without a terminal; the commands exist for
troubleshooting.
