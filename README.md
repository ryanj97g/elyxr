# Elyxr

Reach a folder on your server from anywhere on your tailnet, and have it feel
like a flash drive you plugged in.

- `lymnald/` — lymnal, the server service (Rust)
- `elyxr/` — the desktop app (Flutter, Linux)
- `elyxr-trove/` — mounts the trove as `~/Elyxr` (Rust, FUSE)
- `lymnal-cli/` — the same operations as commands

## Build

```sh
cargo build && cargo test                                  # the Rust services
cd elyxr && flutter pub get && flutter test && flutter build linux
```

To run lymnal directly, copy `config.example.toml` to
`~/.config/lymnal/config.toml` and set `bind` to this machine's Tailscale
address.
