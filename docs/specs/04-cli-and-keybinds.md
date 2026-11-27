# Spec 04 — Helper CLIs & Hyprland Keybind Matrix

## 1. Helper CLIs (`bin/kaze-*`)

All 11 executables in `bin/` use `#!/usr/bin/env lua`, share `lua/kaze/*`, run strictly on demand (`0 MiB` resident background RAM), and follow POSIX exit codes (`0` success, `2` invalid CLI args, non-zero + `stderr` message on runtime errors).

### `kaze-session <start|stop|lock|wake-displays>`
- `start`: renders `$XDG_RUNTIME_DIR/kaze/session.env` from `hypr_user.load()`, imports only `WAYLAND_DISPLAY`, `XDG_CURRENT_DESKTOP`, and `HYPRLAND_INSTANCE_SIGNATURE` to `systemd --user` / D-Bus, and starts `kaze-session.target`.
- `stop`: tears down active virtual-share/presentation state (`kaze-display cleanup`), stops any running `kaze-record.service` gracefully, stops `kaze-session.target`, and unsets session Wayland vars.
- `lock`: triggers Noctalia lockscreen (`noctalia msg lock`).
- `wake-displays`: re-enables display power via Hyprland 0.57 `hl.dsp.dpms({ action = "on" })` (invoked by Noctalia's idle `resume_command`).

### `kaze-footclient [footclient-args...]`
- Connects to the packaged `foot-server.socket` (`footclient -E --server-socket=...`), reads live color overrides from `~/.config/foot/themes/noctalia`, passes them via `-o`, and propagates the exact child exit status.

### `kaze-display [COMMAND]`
- Zero-daemon Hyprland 0.57 multi-monitor, presentation, and virtual-share orchestrator powered by `lua/kaze/display.lua` and `noctalia dmenu` (`kaze.popups`), guarded by split `flock` locks (`display-menu.lock` for popups, `display.lock` for state/Hyprland mutations with bounded wait for `--on-disconnect`/`cleanup`).
- Interactive menu (`--menu`, bound to `Super + Shift + P` / `XF86Display` and bar `[widget.display]`):
  1. **Mirror Full Screen** (`mirror`, `mirror-scaled` via `wl-mirror`, `stop-mirror`)
  2. **Present Workspace** (`present [ws_id]`, `toggle-control` on `Ctrl + Super + P`, `stop-present`) — hides Noctalia bar on the external monitor and manages DND safely
  3. **Virtual Share (Meet/Discord 1080p)** (`virtual-share [ws_id]`, `switch-share [ws_id]`, `toggle-window-share` on `Super + Alt + P`, `toggle-control` / `toggle-virtual-control` for fullscreen `wl-mirror` + direct focus/cursor control without moving windows or reloading Hyprland, `toggle-preview`, `stop-virtual`) — creates a `1920x1080@60` headless `kaze-share` output at `9999x0` and safely rescues windows on stop/logout
  4. **Extend / Layout** (`extend-right`, `extend-left`, `extend-up`, `external [--no-confirm]` with 15-second auto-revert confirmation against EDID-present/no-signal displays, `internal`, `auto`)
- Lifecycle hooks: `--hotplug <monitor>`, `--on-disconnect <monitor>`, `--list`, `cleanup`. Persists active monitor rules in `$XDG_RUNTIME_DIR/kaze/monitors.lua` so `hyprctl reload` preserves runtime layouts.

### `kaze-keys [--list]`
- Reads `lua/kaze/keybinds_data.lua` directly (single pure-Lua source of truth shared with `hypr/keybinds.lua`, zero compositor IPC needed for `--list`).
- Default mode opens `noctalia dmenu` (`Super + /`, Esc-safe).

### `kaze-project [--list] [--mode shell|nvim|split | --shell | --nvim | --split] [DIR]`
- Discovers project directories from `zoxide query -l` (frecent first) and `fd` across `cfg.project_dirs` (defaulting to existing `~/Projects`, `~/Code`, `~/src`, `~/dev`, `~/Workspace`), then prompts via `noctalia dmenu` (`Project > `).
- Updates `zoxide` frecency and opens the selected directory in `kaze-footclient` (`shell`, `nvim`, or `split` for Neovim + companion terminal split).

### `kaze-style [PRESET | --menu | --current | --list] [--no-reload]`
- Switches across all **11 visual presets** (`omarchy-rail`, `swiss-grid`, `corner-hud`, `ghost-zero`, `dynamic-island`, `hardware-notch`, `glass-studio`, `floating-rail`, `tui-hacker`, `retro-90s`, `cinema-frame`, plus aliases like `floating-islands` → `corner-hud` and `concave-notch` → `hardware-notch`) via `lua/kaze/styles.lua` with `0` extra resident daemons or polling, while preserving user edits outside style-managed TOML keys and preserving `~/.config/hypr/user.lua`.
- Synchronizes Noctalia (`~/.config/noctalia/config.toml`), Hyprland geometry (`~/.config/hypr/kaze-style.lua`), and GTK3/Thunar CSS (`~/.config/gtk-3.0/kaze-style.css`), plus saves/restores `[theme]` across palette-locked presets (`~/.config/kaze/saved-theme.json`).
- `dynamic-island` renders a 3-cluster top bar (`group:island_left` launcher + `focus_hint` workspace dots, centered theme-synced `surface_container` Live Activity `group:island` pill with clock, MPRIS media, `kaze-record`, `kaze-display`, notifications, and control-center, and `group:island_right` quick controls); `ghost-zero` enables `auto_hide = true`, `reserve_space = false`, `0px` gaps, and `Super_L` hold-to-peek; `glass-studio` enables the auto-hiding bottom `[dock]`; `floating-rail` runs dual bars (`default` + `rail`).
- Persists active selection in `~/.config/kaze/style`, validates before atomic swap, reloads live Noctalia (`noctalia msg config-reload`, plus `templates-apply` when `[theme]` changes) and Hyprland (`hyprctl reload`), and is selectable directly in `scripts/install.sh` (`--style` and scrollable TUI wizard step 2).

### `kaze-tui <sysmon|wifi|bluetooth|audio>`
- Toggles a floating left-edge drawer (`-a kaze-tui`, matched by `hypr/rules.lua`) inside `kaze-footclient`. Primary hotkey is `Ctrl + Shift + Esc` → `kaze-tui sysmon` (`btop`, fallback `htop`/`top`). Focuses or closes an existing drawer cleanly on repeat press.

### `kaze-record [toggle|start|stop|status|--menu|--bar] [--region] [--audio[=desktop|mic|off]] [--gif]`
- `wf-recorder` capture managed via on-demand `kaze-record.service` with `flock` concurrency protection (`$XDG_RUNTIME_DIR/kaze/record.lock`).
- `--menu` opens `noctalia dmenu` (`Record > `) for Fullscreen/Region video, system audio (`desktop` sink monitor via `pactl`), mic input, and `ffmpeg` palettegen GIF export (or converting the last MP4 to GIF). `--bar` stops immediately when active or opens `--menu` when idle.
- Updates Noctalia's `[widget.record]` bar indicator (`circle-dot` + `error` color while recording, reset cleanly via `ExecStopPost`).
- Writes unique `.mp4` / `.gif` files under XDG Videos `Recordings/`, stops cleanly via `SIGINT` with `ffprobe` packet verification, and notifies on completion.

### `kaze-doctor [--offline] [--profile minimal|full] [--diff [--template PATH]]`
- Validates required `PATH` binaries for the active profile (`minimal` vs `full`), deployed XDG symlinks (zero broken links), `noctalia config validate`, `foot --check-config`, `zsh -n` across `~/.zshrc`/`~/.zprofile`/`conf.d/*.zsh`, UTF-8 locale, empty `hyprctl configerrors`, matching `systemd --user` Wayland env, passive `busctl --user --activatable` portal check (never wakes portals), active PipeWire/WirePlumber, and singleton daemon counts (`noctalia`, `foot`, plus `fcitx5` on `full`).
- `--diff` (alias `--diff-noctalia`): pure-Lua drift check (`lua/kaze/toml_diff.lua`) comparing `~/.config/noctalia/config.toml` against `<repo>/config/noctalia/config.toml` to surface newly added upstream sections, keys, and bar/template list items without flagging user GUI edits. Normal `kaze-doctor` runs also emit a `[WARN]` hint when drift exists.

### `kaze-mirror [--dry-run|--apply] [--fast] [--bench] [--rollback] [--menu|--tui|--tui-window] [--json] [--force]`
- Pure-Lua + `curl`/`bsdtar`/`pacman` Arch & CachyOS mirror optimizer (`lua/kaze/mirror.lua`, `lua/kaze/mirror_tui.lua`, `0` Python, `0` AUR, `0` background daemons).
- Parses active `Include = /etc/pacman.d/...` groups directly from `/etc/pacman.conf` (strictly skips unmanaged third-party repos, globs, and inline `Server`/`CacheServer` conflicts).
- **3-stage saturation protocol:** Phase 1A (`128 KiB` single `curl -Z` screen, high-RTT safe) → dynamic large stable `.pkg.tar.zst` discovery via `bsdtar` → Phase 1B (`8 MiB` warm-up) → Phase 2A (sustained single-stream `256 KiB` Lua pipe with `Q1..Q4` slow-start discard & burst-shaping detection) → Phase 2B (`4×` parallel aggregate saturation via `curl -Z`) + secondary repo freshness/size check.
- **Stage 3 (`--bench`):** adaptive mixed-size real-package `ParallelDownloads` A/B (`{3, 5, 8, 12}`) via isolated `fakeroot pacman -Sw` against staged winning mirrorlists + Pre/Post comparison.
- **Security & rollback:** zero-network `root` boundary (`--commit-plan` / `--commit-rollback`), two-layer `flock`, `db.lck` & active-service guard, symlink/allowlist enforcement, same-filesystem atomic `mktemp` + `sync` + `0644` + `rename`, `pacman-conf` post-commit verification with auto-revert, backup rotation (last 5 `.kaze-bak-*`), and transactional manifest preventing double-rollback.
- **UI integration:** `[widget.mirror]` on Noctalia bar (Left: `--menu` via `noctalia dmenu`, Right: `--tui-window`), `Ctrl + Alt + M` keybind, and Omarchy ANSI TUI with upfront `sudo -v` authentication + automatic atomic commit on scan completion (pass `--tui --dry-run` to preview without committing).

### `kaze-thunar-action <terminal|yazi|editor|copy-path|copy-image|wallpaper|extract|compress|checksum> <path> [paths...]`
- Stateless pure-Lua Thunar custom-action helper invoked by `config/Thunar/uca.xml`: launches `kaze-footclient` / `yazi` / configured editor, copies paths or image MIME bytes via `wl-copy`, sets live Noctalia wallpapers, compresses to `.tar.zst`, performs tarbomb/traversal-safe `bsdtar` extraction, and computes SHA256 checksums.

---

## 2. Hyprland Keybind Matrix (`lua/kaze/keybinds_data.lua`)

| Group | Keybind | Action |
|---|---|---|
| **Launchers** | `Super` (tap) / `Super + Space` | Toggle Noctalia app launcher |
| **Launchers** | `Super + A` / `Super + N` | Control Center / Notifications tab |
| **Launchers** | `Super + I` / `Super + Shift + I` | Noctalia Settings GUI / Visual style switcher (`kaze-style`) |
| **Launchers** | `Super + /` | Search Hyprland shortcuts (`kaze-keys`) |
| **Launchers** | `Super + Shift + T` | Toggle Dark / Light mode (Noctalia) |
| **Launchers** | `Super + Shift + W` | Noctalia wallpaper picker |
| **Launchers** | `Super + V` | Noctalia clipboard history |
| **System** | `Ctrl + Alt + Delete` | Noctalia session menu |
| **System** | `Super + L` | Lock screen (`kaze-session lock`) |
| **System** | `Ctrl + Alt + C` | Dismiss active notifications (`locked`) |
| **System** | `Super + Shift + D` | Toggle Do Not Disturb |
| **System** | `Super + Shift + N` | Toggle Night Light |
| **System** | `Super + Shift + Z` | Toggle Focus / Game Mode (`hl.config` + DND, `0` extra processes) |
| **System** | `Super + Esc` | Enter/exit VM keybind `passthrough` submap |
| **System** | `Super + Shift + P` / `XF86Display` | Display / Present / Virtual Share menu (`kaze-display --menu`) |
| **System** | `Super + Alt + P` | Push/pull window to shared workspace (`kaze-display toggle-window-share`) |
| **System** | `Ctrl + Super + P` | Toggle control presented / virtual-share workspace (`kaze-display toggle-control`) |
| **System** | `Ctrl + Super + Alt + R` | Reload Noctalia & Hyprland (`noctalia msg config-reload && hyprctl reload`) |
| **Apps** | `Super + Return` / `Super + T` | Terminal (`kaze-footclient -N`) |
| **Apps** | `Super + W` / `Super + C` / `Super + E` | Browser / Editor (`codium`/`code`/`nvim`) / File manager (`thunar`, fallback `yazi`) |
| **Apps** | `Super + O` / `Super + Shift + O` | Project switcher (`kaze-project`) / Neovim + terminal split |
| **Tools** | `Super + Alt + W` / `Super + Alt + B` | Network / Bluetooth Control Center tab |
| **Tools** | `Ctrl + Alt + V` / `Super + Alt + A` | Audio Control Center tab |
| **Tools** | `Ctrl + Shift + Esc` | Floating `btop` drawer (`kaze-tui sysmon`) |
| **Tools** | `Ctrl + Alt + M` | Mirror Optimizer TUI (`kaze-mirror --tui-window`) |
| **Capture** | `Print` / `Super + Shift + S` / `Super + Shift + Alt + S` | Full / Region / Annotate screenshot (Noctalia native) |
| **Capture** | `Super + Shift + C` | Pick screen color (`hyprpicker` → clipboard) |
| **Capture** | `Ctrl + Alt + R` / `Super + Shift + Alt + R` / `Super + Shift + R` | Toggle Full / Region recording / Recording menu (`kaze-record`) |
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
| **Workspaces** | `Super + M` / `Super + D` / `Super + R` (+ `Super + Alt + M/D/R`) | Toggle / move window to special workspaces (`music`, `communication`, `todo`) |
| **Media** | `XF86AudioRaise/LowerVolume`, `XF86AudioMute` (`Super + Shift + M`), `XF86AudioMicMute` | Noctalia native volume/mic OSD (`locked`) |
| **Media** | `XF86MonBrightnessUp/Down` | Noctalia native brightness OSD (`locked`) |
| **Media** | `XF86AudioPlay/Next/Prev/Stop` (`Ctrl + Super + Space / = / - / Backspace`) | Noctalia native media controls (`locked`) |
