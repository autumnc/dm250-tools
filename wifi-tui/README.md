# wifi-tui

TUI WiFi manager using `wpa_supplicant` — a Rust rewrite of
[wifi-config](https://github.com/DennisSchulmeister/wifi-config).

Built for small ARM Linux systems (DM200/DM250, Raspberry Pi) with no desktop
environment.

<p float="left">
  <img src="https://raw.githubusercontent.com/DennisSchulmeister/wifi-config/main/docs/img/screenshot1.png" width="250"/>
  <img src="https://raw.githubusercontent.com/DennisSchulmeister/wifi-config/main/docs/img/screenshot2.png" width="250"/>
  <img src="https://raw.githubusercontent.com/DennisSchulmeister/wifi-config/main/docs/img/screenshot3.png" width="250"/>
</p>

## Features

- Scan for nearby WiFi networks
- Connect to open, WPA2-PSK, or WPA-Enterprise (PEAP) networks
- Manage saved networks (add, edit, delete)
- View connection status, IP addresses, and wpa_supplicant config
- Silent by default — all subprocess output goes to `/dev/null`

## Usage

```sh
wifi-tui            # silent mode
wifi-tui --debug    # verbose subprocess output
wifi-tui -d         # same as --debug
```

### Key bindings

| Key | Action |
|-----|--------|
| `j` / `k` or `Up` / `Down` | Navigate |
| `Enter` | Select / Confirm |
| `1`–`9` | Quick-select menu items |
| `Tab` / `Shift+Tab` | Switch form fields |
| `d` / `Delete` | Delete saved network |
| `Esc` | Back / Quit |
| `Ctrl+C` / `q` | Quit |

## Build

Requires Rust nightly for `panic = "immediate-abort"` with `build-std`.

```sh
# Native build
cargo build --release

# Cross-compile for ARM hard-float (glibc)
RUSTC=<nightly-rustc> rustup run <nightly> cargo build -Z build-std \
    --target armv7-unknown-linux-gnueabihf --release

# Cross-compile for ARM hard-float (static musl)
RUSTC=<nightly-rustc> rustup run <nightly> cargo build -Z build-std \
    --target armv7-unknown-linux-musleabihf --release
```

## License

© 2023 Dennis Schulmeister-Zimolong <dennis@wpvs.de>

GNU Affero General Public License v3.0 (see original
[wifi-config](https://github.com/DennisSchulmeister/wifi-config)).
