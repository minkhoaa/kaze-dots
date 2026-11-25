# Spec 04 — Lua CLI Tools & Keybind Matrix

## 1. Pure-Lua CLI Tools (`bin/kaze-*`)

All executables in `bin/` use `#!/usr/bin/env lua`, share `lua/kaze/*`, have `chmod +x`, and follow strict POSIX exit codes (`0` success, non-zero + `stderr` error message on failure).

### `kaze-sync [--reload | --check | --session-start | --set-layout NAME | --set-theme NAME | --set-dynamic-theme | --set-wallpaper PATH | --set-profile NAME]`
- Reads resolved config (`defaults` + `state.lua` + `user.lua` + active `layout`).
- Generates all target configs atomically via `fs.write_atomic()`.
- `--check`: Dry-run validation only (verifies theme/layout/emitters without writing `~/.config/*` or reloading daemons).
- `--reload` / `--set-*`: Stage and validate, then reload the active Kaze session. Restart Waybar and Fnott; pre-map a transient `swaybg` candidate before restarting `kaze-wallpaper.service` for zero-flash image transitions, apply any new cursor setting, and start/stop optional `full` profile services (`kaze-polkit.service`, `kaze-fcitx5.service`) when profile flags change. Foot is not restarted. On failure restore generated files, `session.env`, and the previous runtime appearance. With no powered outputs use service/PID health instead of requiring a mapped layer. Startup uses `--session-start` with safe preset fallbacks and no live reload.

### `kaze-layout [--quiet] [sidebar|islands|slim|--menu|--current]`
- No args or `--menu`: Opens `fuzzel --dmenu -p "Layout > "` listing all layouts with `(active)` marker on the current one.
- `<name>`: Validates, delegates the serialized switch to `kaze-sync`, then sends a confirmation notification (suppressed with `--quiet`). State is committed only after the switch succeeds.
- `--current`: Prints active layout name to `stdout`.

### `kaze-theme [--quiet] [kaze|lavender|tokyonight|carbon|paper|dynamic|toggle-polarity|--menu|--current]`
- No args or `--menu`: Opens `fuzzel --dmenu -p "Theme > "` listing all themes (including `paper` light mode and `dynamic` when `matugen` is installed or active) with `(active)` marker.
- `toggle-polarity`: Instant outdoor Light (`paper`) ↔ Dark (`last_dark_theme` or `kaze`, reusing cached `dynamic_palette` when returning to `dynamic`) switch.
- `<name>`: Validates (`dynamic` extracts colors via `matugen` and WCAG-clamps tokens before calling `kaze-sync --set-dynamic-theme`), delegates the serialized switch to `kaze-sync` (which also exports read-only `~/.cache/kaze/palette.{lua,json,sh}`), then sends a confirmation notification (suppressed with `--quiet`). State is committed only after the switch succeeds.
- `--current`: Prints active theme name to `stdout`.

### `kaze-perf [--quiet] [on|off|toggle|status]`
- Instant 0-MiB Zen / Gamemode toggle (`Super + Shift + Z`): uses `hyprctl eval` to disable animations, blur, shadow, rounding, gaps and translucency (`1.0` opacity) and hides Waybar (`SIGUSR1`); restores layout via `hyprctl reload` on exit.

### `kaze-dashboard [--print]` · `kaze-panel [--status]`
- Zero-daemon (`0 MiB` background RAM) Top Drop-down & Right Drawer popups synced to active layout margins:
  - `kaze-dashboard` (`Super + N` / click `clock` on Waybar): Top drop-down popup (`--namespace=kaze-popup-top --anchor=top`, `animation = "slide top"`) rendering a pure-Lua monthly calendar, date/time, active MPRIS track & playback actions, notification clear, and polarity switch.
  - `kaze-panel` (`Super + A` / click `battery` or right-click `menu`/`power` on Waybar): Right-side Quick Control Center drawer (`--namespace=kaze-popup-right --anchor=top-right`, `animation = "slide right"`) aggregating live Volume/Mute, Brightness, Battery, Wi-Fi SSID, Audio Sink, Bluetooth, Power Profile, Night Light, Caffeine, Polarity, Zen Mode, Layout/Theme, and Power Menu.
  - Floating TUIs (`kaze-tui`) dock flush along the right edge (`animation = "slide right"`), and the default `Super + S` scratchpad (`kaze-dropdown`) drops down from the top (`animation = "slide top"`).

### `kaze-windows [--list]` · `kaze-audio-sink [--quiet] [--list]` · `kaze-wifi [--list] [--rescan]` · `kaze-calc [--eval EXPR]`
- On-demand Fuzzel workflow helpers (`0 MiB` background footprint):
  - `kaze-windows` (`Super + Tab`): Fuzzy window switcher across all normal and `special:*` workspaces via `hyprctl -j clients`.
  - `kaze-audio-sink` (`Super + Shift + A`): 1-step PipeWire default sink switcher via `wpctl status` + `wpctl set-default`.
  - `kaze-wifi`: Fast `<20 ms` `nmcli --rescan no` Wi-Fi switcher with password prompt, rescan, and `nmtui`/`impala` fallback.
  - `kaze-calc` (`Super + Alt + C` / `XF86Calculator`): Pure-Lua 5.5 sandboxed expression calculator (`--eval` for CLI, interactive `fuzzel` + `wl-copy`).

### `kaze-wall [--quiet] [<path> | --random | --menu | --preview | --current]`
- Validates image magic bytes (PNG/JPEG/WebP/GIF/BMP/SVG), rejects pinned `user.lua` `wallpaper` overrides with exit `1`, serializes switches under `wall.lock` + `sync.lock`, updates `dynamic_palette` automatically when `theme == "dynamic"`, and transitions `swaybg` without flashing black.
- `--random` picks a different image from `cfg.wallpaper_dir` when ≥ 2 images exist; `--menu` lists relative paths in `fuzzel --dmenu`; `--preview` opens `yazi` in `kaze-footclient`.

### `kaze-display [--menu | --list | extend-right | extend-left | extend-up | mirror | external | internal | auto]`
- Pure-Lua external monitor manager powered by `lua/kaze/display.lua` and `hyprctl -j monitors all` + `hyprctl keyword monitor` (zero resident daemon, zero extra packages).
- Prefers `eDP-*` / `LVDS-*` / `DSI-*` as the internal laptop display; refuses `external` when no external monitor is connected so a single display is never blacked out. Bound to `Super + Shift + P` and `XF86Display`, and exposed in `kaze-menu`.

### `kaze-keys [--list]`
- Shares `lua/kaze/keybinds_data.lua` with `hypr/keybinds.lua` (single pure-Lua source of truth with zero compositor IPC needed to list shortcuts).
- `--list` prints `[Group]  Chord  —  Description` rows; no args opens `fuzzel --dmenu -p "Keys > "` (bound to `Super + /`, Esc-safe).

### `kaze-doctor [--offline] [--profile minimal|full]`
- Verifies required `PATH` binaries for the active profile (`minimal` never fails on absent `full` packages), deployed XDG symlink integrity (including systemd user units and drop-ins), UTF-8 locale, empty `hyprctl configerrors`, matching `systemd --user` Wayland activation vars, passive `busctl --user --activatable` portal check (never waking portals), active PipeWire/WirePlumber, and singleton daemon PID counts. Prints informational guidance on user-managed opt-ins (`gnome-keyring`/`keepassxc`, `mpris-proxy`, `udisks2`).

### `kaze-menu`
- Opens a flat command palette in `fuzzel` (toggles closed if `fuzzel` is already running). When launched from `kaze-waybar.service`, actions detach via `systemd-run --user --scope --quiet` so bar restarts never terminate switch transactions. Entries without their backend binary are hidden:
  - `󰀻  App Launcher` → calls `fuzzel`
  - `󰆍  Terminal` → calls `kaze-footclient -N`
  - `󰙵  Switch Layout` → calls `kaze-layout --menu`
  - `󰏘  Switch Theme` → calls `kaze-theme --menu`
  - `󰖩  Wi-Fi (nmtui)` → calls `kaze-tui wifi`
  - `󰂯  Bluetooth (bluetui)` → calls `kaze-tui bluetooth`
  - `󰕾  Audio Mixer (wiremix)` → calls `kaze-tui audio`
  - `󰍛  System Monitor (btop)` → calls `kaze-tui sysmon`
  - `󰅌  Clipboard History` → `kaze-clipboard pick`
  - `󰄀  Screenshot Region` → `kaze-screenshot region`
  - `󰆓  Save Screenshot Region` → `kaze-screenshot region --save`
  - `Annotate Screenshot` → `kaze-screenshot region --annotate` (`swappy`)
  - `Pick Color` → `kaze-screenshot color` (`hyprpicker`)
  - `Toggle Screen Recording` / `Toggle Region Recording` → `kaze-record [--region]` (`wf-recorder`)
  - `Toggle Night Light` → `kaze-night` (`hyprsunset`)
  - `Toggle Caffeine` → `kaze-inhibit` (`systemd-inhibit`)
  - `󰑓  Reload Shell` → `kaze-sync --reload`
  - `⏻  Power Menu` → calls `kaze-power`

### `kaze-power`
- Opens `fuzzel --dmenu -p "Power > "` with clean options:
  - `󰌾  Lock` → request a lock for the graphical login via logind; hypridle starts `kaze-lock.service` and updates `LockedHint` from Wayland confirmations
  - `󰍹  Screen Off` → turn the displays off via Hyprland DPMS, with no suspend or immediate lock. A key press or mouse movement turns them back on.
  - `󰍃  Logout` → finalize any active recording, stop the Kaze session, clear session clipboard and env, then dispatch `hl.dsp.exit()`
  - `󰜉  Reboot` → `systemctl reboot`
  - `⏻  Shutdown` → `systemctl poweroff`
- Kaze does not request system sleep. Lid events and suspend requests from outside Kaze are governed by system policy.

### `kaze-clipboard [pick|list|store|wipe]`
- Clipboard history is shared by both MIME watchers and picker, is private in `$XDG_RUNTIME_DIR/kaze` by default, and skips non-`data` events. `Esc` or a failed decode does not touch the clipboard.

### `kaze-screenshot <screen|region> [--save]` / `region --annotate` / `color`
- Screenshot capture is staged before copying. An interrupted selection or failed capture leaves the clipboard untouched and sends no success notification. `--save` writes a PNG to the XDG Pictures `Screenshots` subdirectory instead of copying it.
- `region --annotate` opens a private temporary PNG in `swappy` after a successful selection and removes it when the editor closes. Saving or copying annotations is left to the editor.
- `color` runs `hyprpicker` without autocopy. Only a valid `#RRGGBB` from a successful pick replaces the clipboard and triggers a color toast.

### `kaze-record [toggle|--region|stop|status]`
- No args / `toggle` starts video-only capture on the focused output. `--region` starts from a `slurp` selection cropped to one output. Either toggle stops an active recording; `stop` never starts one. `Esc` doesn't reserve a file. `status` prints `on` or `off`.
- Writes a unique MP4 under the XDG Videos `Recordings` subdirectory (`~/Videos/Recordings` fallback). A nonblocking `record.lock` ignores overlapping invocations.
- Captures at 30 fps with damage-only capture disabled so a static screen doesn't stall a normal stop. Stops via `kaze-record.service` (`SIGINT`, 10s stop timeout); announces the path only after the job completes, the encoder exited successfully, and a bounded `ffprobe` read found a video packet. Failures warn about incomplete video.
- Use the Kaze Power menu to log out: it stops the recorder before asking Hyprland to exit. The direct compositor shutdown hook also attempts a bounded stop; if Wayland is already blocked in shutdown or the recorded output disappears, the recorder's main thread can time out. Treat such a file as potentially incomplete even if the encoder got time to write the trailer.

### `kaze-night [on|off|toggle|status]` / `kaze-inhibit [on|off|toggle|status]`
- Both toggle by default; `status` reports `on` or `off`. They only run during the Kaze login and add no worker when off.
- Night Light runs `hyprsunset` at `night_temp` (default `4500` K, `1000..6500`). Run `kaze-sync --reload` after editing the setting and turn Night Light off/on to use it.
- Caffeine uses logind's `idle` inhibitor, honored by hypridle. It stops on demand, on logout, or after two hours, releasing the inhibitor without disabling manual lock or changing sleep/lid policy.

### `kaze-tui <wifi|bluetooth|audio|sysmon|power-profile>`
- Launches a centered floating `kaze-footclient` window (`-a kaze-tui`, matched by Hyprland `window_rule` `^kaze-tui$`):
  - `wifi` → `impala` when standalone `iwd.service` is active and `NetworkManager.service` is inactive; otherwise `nmtui`
  - `bluetooth` → `bluetui` (falls back to `bluetoothctl`)
  - `audio` → `wiremix` (falls back to `pulsemixer` or `alsamixer` if absent)
  - `sysmon` → `btop` (falls back to `htop` or `top`)
  - `power-profile` → Fuzzel selector communicating directly with an active D-Bus PowerProfiles daemon (`org.freedesktop.UPower.PowerProfiles` / `net.hadess.PowerProfiles`) via `busctl --system --auto-start=no` (zero Python; automatically hidden when absent or when `tlp.service` is active)
- If a `kaze-tui` window for the same tool is already focused/open, cleanly focuses or closes it without hanging.

### `kaze-osd <vol-up|vol-down|vol-mute|mic-mute|bright-up|bright-down>`
- Executes the exact hardware command (`wpctl` or `brightnessctl`), reads the updated percentage/mute state, and fires a synchronous replacing notification to `fnott`:
  ```bash
  notify-send -a kaze-osd -t 1400 -u low \
    -h string:x-canonical-private-synchronous:kaze-osd \
    -h int:value:<pct> \
    "<icon> <label>" "<pct>%"
  ```
- Hardware key auto-repeat is throttled inside Hyprland (80 ms per volume/backlight channel). Brightness changes only panel backlights and use a floor of `ceil(2% of max_brightness)`, at least one device unit.
- **Zero extra resident OSD daemon** (`0 MiB` idle RAM).

---

## 2. Hyprland Keybind Matrix (`hypr/keybinds.lua`)

| Keybind | Action | Flags |
|---|---|---|
| `Super` (tap release) / `Super + Space` | Toggle App Launcher (`fuzzel`) | `release` (`SUPER_L`) |
| `Super + Shift + Space` | Open `kaze-menu` | — |
| `Super + /` | Search Keyboard Shortcuts (`kaze-keys`) | — |
| `Super + Shift + L` | Quick Layout Switcher (`kaze-layout --menu`) | — |
| `Super + Shift + T` | Quick Theme Switcher (`kaze-theme --menu`) | — |
| `Super + Return` / `Super + T` | Open Terminal (`kaze-footclient`) | — |
| `Super + W` | Open Browser (`cfg.browser`) | — |
| `Super + C` | Open Editor (`cfg.editor`, fallback `code`/`nvim`) | — |
| `Super + E` | Open File Manager (`cfg.files`) | — |
| `Super + V` | Clipboard History (`cliphist` + `fuzzel`) | — |
| `Super + L` | Lock Screen (`kaze-session lock` → logind → hypridle/Hyprlock) | — |
| `Ctrl + Alt + Delete` | Power Menu (`kaze-power`) | — |
| `Ctrl + Alt + C` | Dismiss All Notifications (`fnottctl dismiss all`) | `locked` |
| `Super + Alt + W` | Floating Wi-Fi TUI (`kaze-tui wifi`) | — |
| `Super + Alt + B` | Floating Bluetooth TUI (`kaze-tui bluetooth`) | — |
| `Ctrl + Alt + V` / `Super + Alt + A` | Floating Audio TUI (`kaze-tui audio`) | — |
| `Ctrl + Shift + Esc` | Floating System Monitor (`kaze-tui sysmon`) | — |
| `Print` | Fullscreen Screenshot → Clipboard | `locked` |
| `Super + Shift + S` | Region Screenshot (`slurp`) → Clipboard | — |
| `Super + Shift + Alt + S` | Annotate Region Screenshot (`swappy`) | — |
| `Super + Shift + C` | Color Picker (`hyprpicker`) | — |
| `Ctrl + Alt + R` / `Super + Shift + Alt + R` | Toggle Screen / Region Recording (`kaze-record`) | — |
| `Ctrl + Super + Alt + R` | Sync & Reload Shell (`kaze-sync --reload`) | `release` |
| `Super + Q` | Close Active Window | — |
| `Super + F` / `Super + Alt + F` | Fullscreen / Maximize | — |
| `Super + Alt + Space` | Toggle Floating | — |
| `Super + P` | Toggle Pin | — |
| `Ctrl + Super + \` / `Ctrl + Super + Alt + \` | Center / Normalize (55%×70% + Center) Window | — |
| `Super + Alt + \` | Pin Window as Picture-in-Picture (bottom-right) | — |
| `Super + ,` / `Super + Shift + ,` / `Super + U` | Toggle / Lock / Ungroup Window Group | — |
| `Ctrl + Alt + Tab` / `Ctrl + Shift + Alt + Tab` | Cycle Window Group Tabs | `repeating` |
| `Super + -/=` / `Super + Shift + -/=` / `Super + Alt + Arrows` | Resize Active Window (±10%) | `repeating` |
| `Super + S` / `Super + Alt + S` / `Ctrl + Super + Shift + Up/Down` | Toggle / Move In & Out of Scratchpad (`special:scratch`) | — |
| `Super + M` / `Super + D` / `Super + R` | Toggle Special Workspaces (`music`, `communication`, `todo`) | — |
| `Super + H/J/K/Arrows` | Focus Window Direction | — |
| `Super + Shift + Arrows` | Move Window Direction | — |
| `Super + 1..0` / `Super + Shift/Alt + 1..0` | Focus / Move to Workspace `1..10` | — |
| `Ctrl + Super + Left/Right` / `Super + Page_Up/Down` / `Scroll` | Cycle Prev / Next Workspace | `repeating` |
| `Ctrl + Super + Shift + Left/Right` / `Super + Alt + Page_Up/Down` | Move Window to Prev / Next Workspace | `repeating` |
| `Super + LMB / Z` · `Super + RMB / X` | Drag / Resize Window | `mouse` |
| `XF86AudioRaiseVolume` / `Lower` | `kaze-osd vol-up` / `vol-down` | `locked`, `repeating` |
| `XF86AudioMute` / `Super + Shift + M` / `MicMute` | `kaze-osd vol-mute` / `mic-mute` | `locked` |
| `XF86MonBrightnessUp` / `Down` | `kaze-osd bright-up` / `bright-down` | `locked`, `repeating` |
| `XF86AudioPlay` / `Ctrl + Super + Space` | `playerctl play-pause` | `locked` |
| `XF86AudioNext` / `Prev` / `Stop` (`Ctrl + Super + = / - / Backspace`) | `playerctl next` / `previous` / `stop` | `locked` |
