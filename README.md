# kaze-dots

A minimal, Omarchy-inspired, vertical-first **Hyprland 0.57+ + Noctalia Shell (C++ v5.x)** desktop for Arch Linux / CachyOS — **zero AUR packages**, **offline/zero-telemetry**, **≤ 100 MiB idle PSS**, **≤ 0.20% CPU**, and **0 early portals**.

> **Note:** The previous Waybar/swaybg/Fnott/Fuzzel/Hyprlock stack (`48.01 MiB PSS`) is preserved on the `legacy-waybar` branch.

## Architecture

Everything Noctalia already provides stays **100% native** in Noctalia; `kaze-dots` only adds Hyprland's Lua configuration, systemd session management, Foot server integration, and the few utilities Noctalia does not cover:

- **Native Noctalia (`noctalia`):** bar (`42px` left sidebar by default, editable in Settings GUI), themes & wallpaper palettes, built-in app theming templates (`hyprland`, `foot`, `gtk3`, `gtk4`, `btop`), wallpaper, app launcher (`noctalia dmenu`), Control Center, notifications, OSD, clipboard history, idle/DPMS, lockscreen, Night Light, Caffeine, Polkit, screenshots & annotation, and window switcher.
- **Hyprland 0.57+ Lua (`hypr/*.lua`):** tiling rules, smart gaps (opt-in), named scratchpads, `noctalia-no-anim` layer rules, and keybinds calling `noctalia msg ...` directly. Optional user overrides live in `~/.config/hypr/user.lua`.
- **7 small CLIs (`bin/`):**
  - `kaze-session` — `start` / `stop` / `lock` / `wake-displays` for `kaze-session.target`
  - `kaze-footclient` — opens terminals via `foot --server` with live Noctalia colors
  - `kaze-display` — Hyprland multi-monitor layout menu (`noctalia dmenu` + `hyprctl`)
  - `kaze-keys` — searchable Hyprland shortcut sheet (`noctalia dmenu`)
  - `kaze-tui` — floating `btop` (sysmon) drawer toggle via `footclient`
  - `kaze-record` — Wayland full/region MP4 screen recording (`wf-recorder` + safe `SIGINT` finalization)
  - `kaze-doctor` — checks packages, symlinks, `noctalia config validate`, `foot --check-config`, `hyprctl configerrors`, portals, audio, and singleton PIDs

## Installation (Arch Linux / CachyOS)

```sh
# Preview packages and paths without touching disk
./scripts/install.sh --profile minimal --dry-run

# Install official [extra] packages (20 minimal / 34 full, 0 AUR) and apply with automatic backup/rollback
./scripts/install.sh --profile minimal   # or --profile full
```

To roll back cleanly to your pre-install state (preserving `~/.config/hypr/user.lua`):

```sh
"$(cat ~/.config/kaze/last-backup)/rollback.sh"
```

## Key Shortcuts

| Shortcut | Action |
| --- | --- |
| `Super` (tap) / `Super + Space` | Noctalia App Launcher |
| `Super + A` | Noctalia Control Center |
| `Super + N` | Noctalia Notifications |
| `Super + I` | Noctalia Settings GUI (bar, themes, widgets, wallpaper) |
| `Super + Shift + T` | Toggle Dark / Light Mode (`noctalia msg theme-mode-toggle`) |
| `Super + Shift + W` | Noctalia Wallpaper Picker |
| `Super + V` | Noctalia Clipboard History |
| `Super + /` | Search Hyprland Shortcuts (`kaze-keys`) |
| `Super + Shift + P` | Multi-Monitor Layout Menu (`kaze-display`) |
| `Super + Return` / `Super + T` | Foot Terminal (`kaze-footclient`) |
| `Ctrl + Shift + Esc` | Floating `btop` System Monitor (`kaze-tui sysmon`) |
| `Print` / `Super + Shift + S` / `Super + Shift + Alt + S` | Noctalia Fullscreen / Region / Annotate Screenshot |
| `Ctrl + Alt + R` / `Super + Shift + Alt + R` | Toggle Full / Region Screen Recording (`kaze-record`) |
| `Super + L` / `Ctrl + Alt + Del` | Lock Screen / Noctalia Session Menu |
| `Ctrl + Super + Alt + R` | Reload Noctalia & Hyprland |

## Verification

```sh
find lua hypr bin tests -type f \( -name '*.lua' -o -path 'bin/kaze-*' \) -print0 | xargs -0 -r -n1 luac -p
lua tests/run.lua
python3 -m unittest tests/vm-idle-test.py
shellcheck scripts/*.sh tests/vm-verify.sh tests/vm-common.sh
```
