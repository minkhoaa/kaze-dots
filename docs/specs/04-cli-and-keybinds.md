# Spec 04 — Lua CLI Tools & Keybind Matrix

## 1. Pure-Lua CLI Tools (`bin/kaze-*`)

All executables in `bin/` use `#!/usr/bin/env lua`, share `lua/kaze/*`, have `chmod +x`, and follow strict POSIX exit codes (`0` success, non-zero + `stderr` error message on failure).

### `kaze-sync [--reload] [--check]`
- Reads resolved config (`defaults` + `state.lua` + `user.lua` + active `layout`).
- Generates all target configs atomically via `fs.write_atomic()`.
- `--check`: Dry-run validation only (verifies theme/layout/emitters without writing `~/.config/*` or reloading daemons).
- `--reload`: Stage and validate, then reload the active Kaze session. Restart Waybar and Fnott; restart swaybg only if the effective wallpaper (image or solid color) changes, and apply any new cursor setting. Foot is not restarted. On failure restore generated files, `session.env`, and the previous runtime appearance. With no powered outputs use service/PID health instead of requiring a mapped layer. Startup uses `--session-start` with safe preset fallbacks and no live reload.

### `kaze-layout [--quiet] [sidebar|islands|slim|--menu|--current]`
- No args or `--menu`: Opens `fuzzel --dmenu -p "Layout > "` listing all layouts with `(active)` marker on the current one.
- `<name>`: Validates, delegates the serialized switch to `kaze-sync`, then sends a confirmation notification (suppressed with `--quiet`). State is committed only after the switch succeeds.
- `--current`: Prints active layout name to `stdout`.

### `kaze-theme [--quiet] [kaze|lavender|tokyonight|carbon|--menu|--current]`
- No args or `--menu`: Opens `fuzzel --dmenu -p "Theme > "` listing all themes with `(active)` marker.
- `<name>`: Validates, delegates the serialized switch to `kaze-sync`, then sends a confirmation notification (suppressed with `--quiet`). State is committed only after the switch succeeds.
- `--current`: Prints active theme name to `stdout`.

### `kaze-menu`
- Opens a flat command palette in `fuzzel` (toggles closed if `fuzzel` is already running). Entries without their backend binary are hidden:
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

### `kaze-tui <wifi|bluetooth|audio|sysmon>`
- Launches a centered floating `kaze-footclient` window (`-a kaze-tui`, matched by Hyprland `window_rule` `^kaze-tui$`):
  - `wifi` → `nmtui`
  - `bluetooth` → `bluetui`
  - `audio` → `wiremix` (falls back to `pulsemixer` or `alsamixer` if absent)
  - `sysmon` → `btop`
- If an `kaze-tui` window for the same tool is already focused/open, cleanly spawns or toggles without hanging.

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
| `Super + Space` / `Super + D` | Toggle App Launcher (`fuzzel`) | — |
| `Super + Shift + Space` | Open `kaze-menu` | — |
| `Super + Shift + L` | Quick Layout Switcher (`kaze-layout --menu`) | — |
| `Super + Shift + T` | Quick Theme Switcher (`kaze-theme --menu`) | — |
| `Super + Return` / `Super + T` | Open Terminal (`kaze-footclient`) | — |
| `Super + W` | Open Browser (`cfg.browser`) | — |
| `Super + E` | Open File Manager (`cfg.files`) | — |
| `Super + V` | Clipboard History (`cliphist` + `fuzzel`) | — |
| `Super + L` | Lock Screen (`kaze-session lock` → logind → hypridle/Hyprlock) | — |
| `Ctrl + Alt + Delete` | Power Menu (`kaze-power`) | — |
| `Ctrl + Alt + C` | Dismiss All Notifications (`fnottctl dismiss all`) | `locked` |
| `Super + Alt + W` | Floating Wi-Fi TUI (`kaze-tui wifi`) | — |
| `Super + Alt + B` | Floating Bluetooth TUI (`kaze-tui bluetooth`) | — |
| `Super + Alt + A` | Floating Audio TUI (`kaze-tui audio`) | — |
| `Ctrl + Shift + Esc` | Floating System Monitor (`kaze-tui sysmon`) | — |
| `Print` | Fullscreen Screenshot → Clipboard | `locked` |
| `Super + Shift + S` | Region Screenshot (`slurp`) → Clipboard | — |
| `Ctrl + Super + Alt + R` | Sync & Reload Shell (`kaze-sync --reload`) | — |
| `Super + Q` | Close Active Window | — |
| `Super + F` / `Super + Alt + F` | Fullscreen / Maximize | — |
| `Super + Alt + Space` | Toggle Floating | — |
| `Super + P` | Toggle Pin | — |
| `Super + S` / `Super + Alt + S` | Toggle / Move to Scratchpad (`special:scratch`) | — |
| `Super + H/J/K/Arrows` | Focus Window Direction | — |
| `Super + Shift + Arrows` | Move Window Direction | — |
| `Super + 1..0` / `Super + Shift + 1..0` | Focus / Move to Workspace `1..10` | — |
| `Super + LMB / RMB` | Drag / Resize Window | `mouse` |
| `XF86AudioRaiseVolume` / `Lower` | `kaze-osd vol-up` / `vol-down` | `locked`, `repeating` |
| `XF86AudioMute` / `MicMute` | `kaze-osd vol-mute` / `mic-mute` | `locked` |
| `XF86MonBrightnessUp` / `Down` | `kaze-osd bright-up` / `bright-down` | `locked`, `repeating` |
| `XF86AudioPlay` / `Next` / `Prev` | `playerctl play-pause` / `next` / `previous` | `locked` |
