# Spec 04 — Helper CLIs & Hyprland Keybind Matrix

## 1. Helper CLIs (`bin/kaze-*`)

All 7 executables in `bin/` use `#!/usr/bin/env lua`, share `lua/kaze/*`, run strictly on demand (`0 MiB` resident background RAM), and follow POSIX exit codes (`0` success, `2` invalid CLI args, non-zero + `stderr` message on runtime errors).

### `kaze-session <start|stop|lock|wake-displays>`
- `start`: renders `$XDG_RUNTIME_DIR/kaze/session.env` from `hypr_user.load()`, imports only `WAYLAND_DISPLAY`, `XDG_CURRENT_DESKTOP`, and `HYPRLAND_INSTANCE_SIGNATURE` to `systemd --user` / D-Bus, and starts `kaze-session.target`.
- `stop`: tears down active virtual-share/presentation state (`kaze-display cleanup`), stops any running `kaze-record.service` gracefully, stops `kaze-session.target`, and unsets session Wayland vars.
- `lock`: triggers Noctalia lockscreen (`noctalia msg lock`).
- `wake-displays`: re-enables display power via Hyprland 0.57 `hl.dsp.dpms({ action = "on" })` (invoked by Noctalia's idle `resume_command`).

### `kaze-footclient [footclient-args...]`
- Connects to the packaged `foot-server.socket` (`footclient -E --server-socket=...`), reads live color overrides from `~/.config/foot/themes/noctalia`, passes them via `-o`, and propagates the exact child exit status.

### `kaze-display [COMMAND]`
- Zero-daemon Hyprland 0.57 multi-monitor, presentation, and virtual-share orchestrator powered by `lua/kaze/display.lua` and `noctalia dmenu` (`kaze.popups`).
- Interactive menu (`--menu`, bound to `Super + Shift + P` / `XF86Display` and bar `[widget.display]`):
  1. **Mirror Full Screen** (`mirror`, `mirror-scaled` via `wl-mirror`, `stop-mirror`)
  2. **Present Workspace** (`present [ws_id]`, `toggle-control` on `Ctrl + Super + P`, `stop-present`) — hides Noctalia bar on the external monitor and manages DND safely
  3. **Virtual Share (Meet/Discord 1080p)** (`virtual-share [ws_id]`, `switch-share [ws_id]`, `toggle-window-share` on `Super + Alt + P`, `toggle-preview`, `stop-virtual`) — creates a `1920x1080@60` headless `kaze-share` output at `9999x0` and safely rescues windows on stop/logout
  4. **Extend / Layout** (`extend-right`, `extend-left`, `extend-up`, `external`, `internal`, `auto`)
- Lifecycle hooks: `--hotplug <monitor>`, `--on-disconnect <monitor>`, `--list`, `cleanup`. Persists active monitor rules in `$XDG_RUNTIME_DIR/kaze/monitors.lua` so `hyprctl reload` preserves runtime layouts.

### `kaze-keys [--list]`
- Reads `lua/kaze/keybinds_data.lua` directly (single pure-Lua source of truth shared with `hypr/keybinds.lua`, zero compositor IPC needed for `--list`).
- Default mode opens `noctalia dmenu` (`Super + /`, Esc-safe).

### `kaze-tui <sysmon|wifi|bluetooth|audio>`
- Toggles a floating left-edge drawer (`-a kaze-tui`, matched by `hypr/rules.lua`) inside `kaze-footclient`. Primary hotkey is `Ctrl + Shift + Esc` → `kaze-tui sysmon` (`btop`, fallback `htop`/`top`). Focuses or closes an existing drawer cleanly on repeat press.

### `kaze-record [toggle|--region|stop|status]`
- Video-only `wf-recorder` capture managed via on-demand `kaze-record.service` with `flock` concurrency protection (`$XDG_RUNTIME_DIR/kaze/record.lock`).
- `--region` selects a single-output rectangle via `slurp` (`Esc` cancels without reserving a file).
- Writes unique `.mp4` files under XDG Videos `Recordings/`, stops cleanly via `SIGINT` with `ffprobe` packet verification, and notifies on completion.

### `kaze-doctor [--offline] [--profile minimal|full] [--diff [--template PATH]]`
- Validates required `PATH` binaries for the active profile (`minimal` vs `full`), deployed XDG symlinks (zero broken links), `noctalia config validate`, `foot --check-config`, `zsh -n` across `~/.zshrc`/`~/.zprofile`/`conf.d/*.zsh`, UTF-8 locale, empty `hyprctl configerrors`, matching `systemd --user` Wayland env, passive `busctl --user --activatable` portal check (never wakes portals), active PipeWire/WirePlumber, and singleton daemon counts (`noctalia`, `foot`, plus `fcitx5` on `full`).
- `--diff` (alias `--diff-noctalia`): pure-Lua drift check (`lua/kaze/toml_diff.lua`) comparing `~/.config/noctalia/config.toml` against `<repo>/config/noctalia/config.toml` to surface newly added upstream sections, keys, and bar/template list items without flagging user GUI edits. Normal `kaze-doctor` runs also emit a `[WARN]` hint when drift exists.

---

## 2. Hyprland Keybind Matrix (`lua/kaze/keybinds_data.lua`)

| Group | Keybind | Action |
|---|---|---|
| **Launchers** | `Super` (tap) / `Super + Space` | Toggle Noctalia app launcher |
| **Launchers** | `Super + A` / `Super + N` | Control Center / Notifications tab |
| **Launchers** | `Super + I` | Noctalia Settings GUI |
| **Launchers** | `Super + /` | Search Hyprland shortcuts (`kaze-keys`) |
| **Launchers** | `Super + Shift + T` | Toggle Dark / Light mode (Noctalia) |
| **Launchers** | `Super + Shift + W` | Noctalia wallpaper picker |
| **Launchers** | `Super + V` | Noctalia clipboard history |
| **System** | `Ctrl + Alt + Delete` | Noctalia session menu |
| **System** | `Super + L` | Lock screen (`kaze-session lock`) |
| **System** | `Ctrl + Alt + C` | Dismiss active notifications (`locked`) |
| **System** | `Super + Shift + D` | Toggle Do Not Disturb |
| **System** | `Super + Shift + N` | Toggle Night Light |
| **System** | `Super + Esc` | Enter/exit VM keybind `passthrough` submap |
| **System** | `Super + Shift + P` / `XF86Display` | Display / Present / Virtual Share menu (`kaze-display --menu`) |
| **System** | `Super + Alt + P` | Push/pull window to shared workspace (`kaze-display toggle-window-share`) |
| **System** | `Ctrl + Super + P` | Toggle control presented workspace on laptop (`kaze-display toggle-control`) |
| **System** | `Ctrl + Super + Alt + R` | Reload Noctalia & Hyprland (`noctalia msg config-reload && hyprctl reload`) |
| **Apps** | `Super + Return` / `Super + T` | Terminal (`kaze-footclient -N`) |
| **Apps** | `Super + W` / `Super + C` / `Super + E` | Browser / Editor (`codium`/`code`/`nvim`) / File manager (`yazi`) |
| **Tools** | `Super + Alt + W` / `Super + Alt + B` | Network / Bluetooth Control Center tab |
| **Tools** | `Ctrl + Alt + V` / `Super + Alt + A` | Audio Control Center tab |
| **Tools** | `Ctrl + Shift + Esc` | Floating `btop` drawer (`kaze-tui sysmon`) |
| **Capture** | `Print` / `Super + Shift + S` / `Super + Shift + Alt + S` | Full / Region / Annotate screenshot (Noctalia native) |
| **Capture** | `Super + Shift + C` | Pick screen color (`hyprpicker` → clipboard) |
| **Capture** | `Ctrl + Alt + R` / `Super + Shift + Alt + R` | Toggle Full / Region screen recording (`kaze-record`) |
| **Windows** | `Super + Q` | Close active window |
| **Windows** | `Super + F` / `Super + Alt + F` | Toggle fullscreen / maximize |
| **Windows** | `Super + Alt + Space` / `Super + P` | Toggle float / pin |
| **Windows** | `Ctrl + Super + \` / `Ctrl + Super + Alt + \` / `Super + Alt + \` | Center / Normalize (55%×70%) / Pin as PiP |
| **Windows** | `Super + Tab` / `Alt + Tab` | Noctalia window switcher / Cycle next window |
| **Windows** | `Super + ,` / `Super + Shift + ,` / `Super + U` / `Ctrl + Alt + Tab` | Toggle / Lock / Ungroup / Cycle window group |
| **Windows** | `Super + -/=` / `Super + Shift + -/=` / `Super + Alt + Arrows` | Resize active window (±10%) |
| **Windows** | `Super + Arrows / H J K` · `Super + Shift + Arrows` | Focus / Move window direction |
| **Windows** | `Super + LMB / Z` · `Super + RMB / X` | Drag / Resize window |
| **Workspaces** | `Super + 1..0` · `Super + Shift / Alt + 1..0` | Switch / Move window to workspace `1..10` |
| **Workspaces** | `Super + Scroll` / `Ctrl + Super + Left/Right` / `Super + Page_Up/Down` | Cycle workspaces (and `+Shift`/`+Alt` to move window) |
| **Workspaces** | `Super + S` / `Super + Alt + S` / `Ctrl + Super + Shift + Up/Down` | Toggle / Move in & out of `special:scratch` |
| **Workspaces** | `Super + M` / `Super + D` / `Super + R` | Toggle special workspaces (`music`, `communication`, `todo`) |
| **Media** | `XF86AudioRaise/LowerVolume`, `XF86AudioMute` (`Super + Shift + M`), `XF86AudioMicMute` | Noctalia native volume/mic OSD (`locked`) |
| **Media** | `XF86MonBrightnessUp/Down` | Noctalia native brightness OSD (`locked`) |
| **Media** | `XF86AudioPlay/Next/Prev/Stop` (`Ctrl + Super + Space / = / - / Backspace`) | Noctalia native media controls (`locked`) |
