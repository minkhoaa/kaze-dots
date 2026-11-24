# Spec 04 — Lua CLI Tools & Keybind Matrix

## 1. Pure-Lua CLI Tools (`bin/omarch-*`)

All executables in `bin/` use `#!/usr/bin/env lua`, share `lua/omarch/*`, have `chmod +x`, and follow strict POSIX exit codes (`0` success, non-zero + `stderr` error message on failure).

### `omarch-sync [--reload] [--check]`
- Reads resolved config (`defaults` + `state.lua` + `user.lua` + active `layout`).
- Generates all target configs atomically via `fs.write_atomic()`.
- `--check`: Dry-run validation only (verifies theme/layout/emitters without writing `~/.config/*` or reloading daemons).
- `--reload`: After writing, reloads Hyprland (`hyprctl reload`), restarts `waybar` and `fnott` cleanly (only when `HYPRLAND_INSTANCE_SIGNATURE` or `WAYLAND_DISPLAY` is active).

### `omarch-layout [noctalia|caelestia|omarchy|--menu|--current]`
- No args or `--menu`: Opens `fuzzel --dmenu -p "Layout > "` listing all layouts with `(active)` marker on the current one.
- `<name>`: Validates, persists to `~/.config/omarch/state.lua`, executes `omarch-sync --reload`, sends a confirmation notification.
- `--current`: Prints active layout name to `stdout`.

### `omarch-theme [noctalia|lavender|tokyonight|carbon|--menu|--current]`
- No args or `--menu`: Opens `fuzzel --dmenu -p "Theme > "` listing all themes with `(active)` marker.
- `<name>`: Validates, persists to `~/.config/omarch/state.lua`, executes `omarch-sync --reload`, sends a confirmation notification.
- `--current`: Prints active theme name to `stdout`.

### `omarch-menu`
- Opens the Omarchy command palette via `fuzzel --dmenu -p "Omarch > "` (toggles closed if `fuzzel` is already running):
  - `󰙵  Switch Layout` → calls `omarch-layout --menu`
  - `󰏘  Switch Theme` → calls `omarch-theme --menu`
  - `󰖩  Wi-Fi (nmtui)` → calls `omarch-tui wifi`
  - `󰂯  Bluetooth (bluetui)` → calls `omarch-tui bluetooth`
  - `󰕾  Audio Mixer (wiremix)` → calls `omarch-tui audio`
  - `󰍛  System Monitor (btop)` → calls `omarch-tui sysmon`
  - `󰅌  Clipboard History` → `cliphist list | fuzzel --dmenu | cliphist decode | wl-copy`
  - `󰄀  Screenshot Region` → `grim -g "$(slurp)" - | wl-copy`
  - `󰑓  Reload Shell` → `omarch-sync --reload`
  - `⏻  Power Menu` → calls `omarch-power`

### `omarch-power`
- Opens `fuzzel --dmenu -p "Power > "` with clean options:
  - `󰌾  Lock` → `pidof hyprlock || hyprlock`
  - `󰤄  Suspend` → `systemctl suspend`
  - `󰍃  Logout` → `hyprctl dispatch exit`
  - `󰜉  Reboot` → `systemctl reboot`
  - `⏻  Shutdown` → `systemctl poweroff`

### `omarch-tui <wifi|bluetooth|audio|sysmon>`
- Launches a centered floating `footclient` window (`-a om-tui`, matched by Hyprland `window_rule` `^om-tui$`):
  - `wifi` → `nmtui`
  - `bluetooth` → `bluetui`
  - `audio` → `wiremix` (falls back to `pulsemixer` or `alsamixer` if absent)
  - `sysmon` → `btop`
- If an `om-tui` window for the same tool is already focused/open, cleanly spawns or toggles without hanging.

### `omarch-osd <vol-up|vol-down|vol-mute|mic-mute|bright-up|bright-down>`
- Executes the exact hardware command (`wpctl` or `brightnessctl`), reads the updated percentage/mute state, and fires a synchronous replacing notification to `fnott`:
  ```bash
  notify-send -t 1400 -u low \
    -h string:x-canonical-private-synchronous:omarch-osd \
    -h int:value:<pct> \
    "<icon> <label>" "<pct>%"
  ```
- **Zero extra resident OSD daemon** (`0 MiB` idle RAM).

---

## 2. Hyprland Keybind Matrix (`hypr/keybinds.lua`)

| Keybind | Action | Flags |
|---|---|---|
| `Super + Space` / `Super + D` | Toggle App Launcher (`fuzzel`) | — |
| `Super + Shift + Space` | Open `omarch-menu` | — |
| `Super + Shift + L` | Quick Layout Switcher (`omarch-layout --menu`) | — |
| `Super + Shift + T` | Quick Theme Switcher (`omarch-theme --menu`) | — |
| `Super + Return` / `Super + T` | Open Terminal (`footclient`) | — |
| `Super + W` | Open Browser (`cfg.browser`) | — |
| `Super + E` | Open File Manager (`cfg.files`) | — |
| `Super + V` | Clipboard History (`cliphist` + `fuzzel`) | — |
| `Super + L` | Lock Screen (`hyprlock`) | — |
| `Ctrl + Alt + Delete` | Power Menu (`omarch-power`) | — |
| `Ctrl + Alt + C` | Dismiss All Notifications (`fnottctl dismiss all`) | `locked` |
| `Super + Alt + W` | Floating Wi-Fi TUI (`omarch-tui wifi`) | — |
| `Super + Alt + B` | Floating Bluetooth TUI (`omarch-tui bluetooth`) | — |
| `Super + Alt + A` | Floating Audio TUI (`omarch-tui audio`) | — |
| `Ctrl + Shift + Esc` | Floating System Monitor (`omarch-tui sysmon`) | — |
| `Print` | Fullscreen Screenshot → Clipboard | `locked` |
| `Super + Shift + S` | Region Screenshot (`slurp`) → Clipboard | — |
| `Ctrl + Super + Alt + R` | Sync & Reload Shell (`omarch-sync --reload`) | — |
| `Super + Q` | Close Active Window | — |
| `Super + F` / `Super + Alt + F` | Fullscreen / Maximize | — |
| `Super + Alt + Space` | Toggle Floating | — |
| `Super + P` | Toggle Pin | — |
| `Super + S` / `Super + Alt + S` | Toggle / Move to Scratchpad (`special:scratch`) | — |
| `Super + H/J/K/Arrows` | Focus Window Direction | — |
| `Super + Shift + Arrows` | Move Window Direction | — |
| `Super + 1..0` / `Super + Shift + 1..0` | Focus / Move to Workspace `1..10` | — |
| `Super + LMB / RMB` | Drag / Resize Window | `mouse` |
| `XF86AudioRaiseVolume` / `Lower` | `omarch-osd vol-up` / `vol-down` | `locked`, `repeating` |
| `XF86AudioMute` / `MicMute` | `omarch-osd vol-mute` / `mic-mute` | `locked` |
| `XF86MonBrightnessUp` / `Down` | `omarch-osd bright-up` / `bright-down` | `locked`, `repeating` |
| `XF86AudioPlay` / `Next` / `Prev` | `playerctl play-pause` / `next` / `previous` | `locked` |
