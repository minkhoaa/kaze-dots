# kaze-dots

[![Arch Linux](https://img.shields.io/badge/Arch%20Linux-%5Bcore%5D%20%2B%20%5Bextra%5D-1793D1?logo=archlinux&logoColor=white)](https://archlinux.org/)
[![AUR Dependencies](https://img.shields.io/badge/AUR%20Dependencies-0-2ea043)](#installation-profiles)
[![Hyprland](https://img.shields.io/badge/Hyprland-0.57%2B%20Native%20Lua-58E1FF)](https://hypr.land/)
[![Lua](https://img.shields.io/badge/Lua-5.5%2B%20Stdlib-2C2D72?logo=lua&logoColor=white)](https://www.lua.org/)
[![Shell Idle PSS](https://img.shields.io/badge/Shell%20Idle%20PSS-~48%20MiB-89b4fa)](#measured-vm-benchmarks)
[![Idle CPU](https://img.shields.io/badge/Idle%20CPU-0.00%25%20%7C%200.56%20CS%2Fs-a6e3a1)](#measured-vm-benchmarks)

> An ultra-lightweight, **Lua-driven Arch Linux + Hyprland (`0.57+`)** desktop shell built around a **vertical-first left rail (`sidebar`)**, with atomic live-switchable **`islands`** and **`slim`** layouts — rendered exclusively by native C/C++ Wayland daemons (`waybar`, `swaybg`, `fnott`, `fuzzel`, `foot --server`).

---

## Highlights

- **~48 MiB shell-only idle PSS, `0.00%` CPU, `~0.56 CS/s`** at `1920×1080` — zero polling scripts, zero custom background helpers, zero resident GL/Vulkan/QML shell runtimes.
- **100% official Arch `[core]`/`[extra]` packages (0 AUR)** with two clean profiles (`minimal` and `full`), atomic backups, and a generated reversible `rollback.sh`.
- **Single-source Lua control plane (`lua/kaze/`)**: one config (`~/.config/kaze/user.lua`) + persistent state (`state.lua`) compiles atomic configs for Hyprland, Waybar, Foot, Fuzzel, Fnott, and Hyprlock via `kaze-sync`.
- **3 live-switchable layouts** (`sidebar`, `islands`, `slim`) and **4 curated palettes** (`kaze`, `lavender`, `tokyonight`, `carbon`) + optional **`dynamic`** wallpaper theming (`matugen` + pure-Lua WCAG 2.1 contrast clamping).
- **Clean `systemd --user` session lifecycle (`kaze-session.target`)**: automatic crash recovery (`Restart=on-failure`), serialized atomic switches under `flock`, zero-flash `swaybg` wallpaper swaps, and safe logout teardown.
- **Caelestia-aligned ergonomics**: tap `Super` to launch apps, `Super + /` fuzzy shortcut lookup, Window Groups, `±10%` keyboard resize, PiP pinning, special workspaces (`scratch`, `music`, `communication`, `todo`), and floating on-demand TUIs (`nmtui`/`impala`, `bluetui`, `wiremix`, `btop`).

---

## Architecture

```text
~/.config/kaze/user.lua  +  state.lua
                │
                ▼  (pure-Lua compiler, 0 MiB resident)
           kaze-sync  ──►  atomic write + validate + flock transaction
                │
                ▼  (systemd --user: kaze-session.target)
  ┌─────────────┼─────────────┬──────────────┬─────────────┬──────────────┐
  │             │             │              │             │              │
waybar       swaybg         fnott       foot-server    hypridle      wl-paste ×2
(bar + RT)  (wallpaper)  (toasts+OSD)  (terminal srv) (idle/lock)  (ephemeral DB)
                                              │
                              on-demand 0 MiB when closed:
                   fuzzel · kaze-tui (nmtui/bluetui/wiremix/btop) · yazi
                   kaze-screenshot · swappy · hyprpicker · wf-recorder
                   hyprsunset (Night Light) · systemd-inhibit (Caffeine)
```

---

## Layouts & Themes

### 3 Live-Switchable Layouts (`kaze-layout`)

| Layout | Position & Geometry (`1920×1080`) | Window Framing | Best For |
|---|---|---|---|
| **`sidebar`** *(default)* | Left vertical rail (`42px` wide, `8 8 42 1064`, `14px` radius) | `gaps 4/8`, `rounding 12` | Coding & reading with full `1080px` vertical height |
| **`islands`** | Floating top pills (`34px` tall, `10 6 1900 34`, `14px` radius) | `gaps 5/10`, `rounding 10` | Airy desktop with frosted glass pills & MPRIS slot |
| **`slim`** | Flush top strip (`28px` tall, `0 0 1920 28`, `0px` radius) | `gaps 4/6`, `rounding 6` | Ultra-minimalist compact displays & window title bar |

### 4 Built-in Palettes + Dynamic (`kaze-theme`)

| Theme | Base (`bg` / `bg_alt`) | Primary Accent | Character |
|---|---|---|---|
| **`kaze`** *(default)* | `#111318` / `#181b22` | `#89b4fa` | Deep charcoal-slate with calm sky-indigo accent |
| **`lavender`** | `#11111b` / `#181825` | `#b4befe` | Deep indigo with soft lavender highlights |
| **`tokyonight`** | `#1a1b26` / `#24283b` | `#7aa2f7` | Tokyo Night Storm electric blue |
| **`carbon`** | `#0c0c0e` / `#141417` | `#e4e4e7` | Matte monochrome with stark silver-white accent |
| **`dynamic`** *(optional)* | Extracted via `matugen` | WCAG 2.1 clamped | Adapts to active wallpaper (`≥ 4.5:1` text, `≥ 3.0:1` UI) |

---

## Quick Start (Arch Linux / CachyOS)

```bash
git clone https://github.com/minkhoaa/kaze-dots.git
cd kaze-dots

# Preview the exact package list and target paths (writes zero files):
./scripts/install.sh --profile full --dry-run

# Install official Arch [core]/[extra] packages + apply symlinks:
./scripts/install.sh --profile minimal   # lean core shell (30 packages, 0 AUR)
# or:
./scripts/install.sh --profile full      # + capture, recorder, dynamic theme, yazi, polkit, fcitx5-bamboo (44 packages, 0 AUR)

# Unattended install + automatic reboot straight into Kaze Hyprland:
./scripts/install.sh --profile full --yes --reboot
```

After logging into a fresh Hyprland session (`Hyprland -c ~/.config/hypr/hyprland.lua`):
- Run **`kaze-doctor`** to verify binaries, symlinks, UTF-8 locale, portals, PipeWire, and singleton daemons.
- Edit **`~/.config/kaze/user.lua`** (seeded once from [templates/user.lua.example](templates/user.lua.example), never overwritten) and apply with **`kaze-sync --reload`**.
- To uninstall and restore your exact pre-install dotfiles (preserving `user.lua`), log out of Kaze and run `"$(<~/.config/kaze/last-backup)/rollback.sh"` from a TTY or SSH session.

---

## Installation Profiles

| Feature | `minimal` (30 pkgs) | `full` (44 pkgs) | Idle RAM Overhead |
|---|:---:|:---:|---|
| Hyprland Lua + Waybar + swaybg + Fnott + Fuzzel + Foot + hypridle + hyprlock | ✅ | ✅ | ~48 MiB PSS (shell core) |
| Portals (`xdg-desktop-portal`, `-hyprland`, `-gtk`, `dconf`) | ✅ | ✅ | On-demand *(see T0 note below)* |
| Clipboard (`cliphist`, `wl-clipboard`), Screenshots (`grim`, `slurp`) | ✅ | ✅ | Included in core |
| Floating TUIs (`nmtui`/`impala`, `bluetui`, `wiremix`, `btop`) | ✅ | ✅ | **0 MiB** when closed |
| Annotation (`swappy`), Color Picker (`hyprpicker`), Recorder (`wf-recorder` + `ffmpeg`), Night Light (`hyprsunset`), Dynamic Theme (`matugen`), File Manager (`yazi`) | — | ✅ | **0 MiB** at idle (on-demand) |
| Polkit Auth Agent (`mate-polkit`) + Vietnamese IME (`fcitx5`, `fcitx5-bamboo`, `fcitx5-gtk`) + `noto-fonts` / `noto-fonts-emoji` | — | ✅ | ~37.6 MiB PSS (`0.10 CS/s`, toggleable via `user.lua`) |

> **Opt-in user integrations (never forced):** Secret Service keyring (`gnome-keyring`/`keepassxc`), Bluetooth media keys (`mpris-proxy`), USB automounting (`udisks2`), and `fcitx5-configtool` (optional Qt GUI to switch Bamboo Telex/VNI).

---

## CLI Tools (`bin/kaze-*`)

| Command | Purpose |
|---|---|
| `kaze-menu` | Flat Fuzzel command palette (App Launcher, Terminal, Layout/Theme/Wallpaper, TUIs, Capture, Doctor, Power); auto-hides missing backends |
| `kaze-keys [--list]` | Fuzzy keyboard shortcut lookup (`Super + /`) generated directly from `lua/kaze/keybinds_data.lua` |
| `kaze-layout [sidebar\|islands\|slim\|--menu\|--current]` | Atomic live layout switch (`≤ 500 ms`) with rollback on error |
| `kaze-theme [kaze\|lavender\|tokyonight\|carbon\|dynamic\|--menu]` | Atomic live theme switch (updates Foot palettes for new windows without restarting `foot --server`) |
| `kaze-wall [<path>\|--random\|--menu\|--preview\|--current]` | Zero-flash `swaybg` wallpaper switcher with image magic-byte validation and auto-`dynamic` palette refresh |
| `kaze-tui <wifi\|bluetooth\|audio\|sysmon\|power-profile>` | Ephemeral centered floating TUI (`nmtui`/`impala`, `bluetui`, `wiremix`, `btop`, zero-Python `busctl` power profiles) |
| `kaze-screenshot <screen\|region [--save\|--annotate]\|color>` | Esc-safe capture (`grim`/`slurp`), annotation (`swappy`), and hex picker (`hyprpicker`) |
| `kaze-record [toggle\|--region\|stop\|status]` | On-demand 30 fps MP4 recorder (`wf-recorder --no-damage`, `SIGINT` finalize + `ffprobe` check, Waybar `RTMIN+8` dot) |
| `kaze-night [on\|off\|toggle\|status]` | On-demand Night Light (`hyprsunset`, default `4500 K`, Waybar `RTMIN+9`) |
| `kaze-inhibit [on\|off\|toggle\|status]` | On-demand Caffeine via `systemd-inhibit --what=idle` (2-hour cap, Waybar `RTMIN+11`) |
| `kaze-clipboard [pick\|list\|store\|wipe]` | Ephemeral `$XDG_RUNTIME_DIR/kaze/cliphist.db` (skips `CLIPBOARD_STATE=sensitive`, streams up to 2 MiB cap, Esc-safe) |
| `kaze-osd <vol-up\|vol-down\|vol-mute\|mic-mute\|bright-up\|bright-down>` | Zero-daemon progress OSD via `fnott` (80 ms repeat throttle, safe `ceil(2%)` backlight floor) |
| `kaze-power` | Power menu: Lock, **Screen Off** (DPMS only, no suspend), Logout (stops recorder + session cleanly), Reboot, Shutdown |
| `kaze-doctor [--offline] [--profile minimal\|full]` | Passive health check for binaries, symlinks, UTF-8 locale, Hyprland errors, portals, audio, and singleton PIDs |
| `kaze-sync [--reload\|--check\|--set-*]` | Pure-Lua config compiler & transactional live reloader |

---

## Keybinds Quick Reference

Press **`Super + /`** inside Hyprland to search all 130 registered bindings live.

| Category | Keybind | Action |
|---|---|---|
| **Launchers** | `Super` *(tap release)* / `Super + Space` | Toggle App Launcher (`fuzzel`) |
| | `Super + Shift + Space` | Open Kaze Command Menu (`kaze-menu`) |
| | `Super + /` | Search Keyboard Shortcuts (`kaze-keys`) |
| | `Super + Shift + L` / `Super + Shift + T` | Switch Layout / Switch Theme |
| | `Super + V` | Clipboard History (`kaze-clipboard pick`) |
| **Apps & TUIs** | `Super + T` / `Super + Return` | Terminal (`kaze-footclient`) |
| | `Super + W` / `Super + C` / `Super + E` | Browser / Editor (`codium`→`code`→`nvim`) / Files (`yazi`) |
| | `Super + Alt + W` / `B` / `A` · `Ctrl + Alt + V` | Floating Wi-Fi / Bluetooth / Audio TUI |
| | `Ctrl + Shift + Esc` | Floating System Monitor (`btop`) |
| **Windows** | `Super + Q` · `Super + F` / `Super + Alt + F` | Close / Fullscreen / Maximize |
| | `Super + Alt + Space` · `Super + P` | Float / Pin |
| | `Super + Arrows` (`H/J/K`) · `Super + Shift + Arrows` | Focus / Move window |
| | `Super + - / =` · `Super + Shift + - / =` · `Super + Alt + Arrows` | Resize active window (`±10%`) |
| | `Super + LMB / Z` · `Super + RMB / X` | Drag / Resize window |
| | `Ctrl + Super + \` · `Ctrl + Super + Alt + \` · `Super + Alt + \` | Center / Normalize (`55%×70%`) / Picture-in-Picture |
| | `Super + ,` / `Shift + ,` / `Super + U` · `Ctrl + Alt + Tab` | Window Group toggle / lock / ungroup / cycle tabs |
| **Workspaces** | `Super + 1..0` · `Super + Shift/Alt + 1..0` | Focus / Move window to workspace `1..10` |
| | `Ctrl + Super + Left/Right` · `Super + Page_Up/Down` · `Scroll` | Prev / Next workspace |
| | `Ctrl + Super + Shift + Left/Right` · `Super + Alt + Page_Up/Down` | Move window to prev / next workspace |
| | `Super + S` · `Super + Alt + S` · `Ctrl + Super + Shift + Up/Down` | Scratchpad toggle / move in / move out |
| | `Super + M` / `Super + D` / `Super + R` | Special workspaces: `music` / `communication` / `todo` |
| **Capture & Media** | `Print` · `Super + Shift + S` · `Super + Shift + Alt + S` | Fullscreen / Region / Annotate screenshot |
| | `Super + Shift + C` · `Ctrl + Alt + R` / `Super + Shift + Alt + R` | Color Picker · Record Screen / Region |
| | `Ctrl + Super + Space` / `=` / `-` / `Backspace` · `Super + Shift + M` | Media Play-Pause / Next / Prev / Stop · Mute |
| **Session** | `Super + L` · `Ctrl + Alt + Delete` · `Ctrl + Alt + C` | Lock / Power Menu / Dismiss notifications |
| | `Ctrl + Super + Alt + R` | Sync & Reload Shell (`kaze-sync --reload`) |

---

## Measured VM Benchmarks

All measurements run inside an isolated Arch Linux KVM guest (`4 vCPU`, `6 GiB RAM`, `1920×1080`, VirtIO-GPU-GL VirGL pinned to Intel iGPU) with zero host interference.

### 1. Idle Shell Stack (`1920×1080`, cold login, 120s window)

| Component / Metric | Measured (`minimal`) | Measured (`full`) | Target Budget |
|---|---:|---:|---:|
| **Kaze Shell Core PSS** (`waybar`, `swaybg`, `fnott`, `foot`, `hypridle`, `wl-paste` ×2) | **47.93–48.37 MiB** | **48.05 MiB** | `≤ 55.0 MiB` guard |
| **`waybar` PSS** | **32.53–35.30 MiB** | **35.30 MiB** | `≤ 40.0 MiB` |
| **Shell Idle CPU / Context Switches** | **0.00% / 0.56–0.57 CS/s** | **0.00% / ~0.6 CS/s** | `≤ 0.20% / ≤ 5.0 CS/s` |
| **Optional `full` Services** (`fcitx5-bamboo` + `mate-polkit`) | **0.00 MiB** *(inactive)* | **37.59 MiB** *(0.10 CS/s)* | Transparently reported |

> **Honest T0 Portal Blocker Note:** On stock Arch `gtk3 1:3.24.52-2` + `waybar 0.16.0-3`, `GtkApplication` calls `StartServiceByName` for `org.freedesktop.portal.Inhibit` during Waybar startup, waking `xdg-desktop-portal` + backends (`~31–37 MiB`) before any app requests them (bringing stock cold combined PSS to `~85.28 MiB`). In a VM-only diagnostic preventing that single early Inhibit activation, combined cold PSS dropped to **`~53.91 MiB`** while FileChooser and ScreenCast still worked on demand. Kaze refuses to mask or break portals to game benchmarks; see [Spec 05](docs/specs/05-verification-and-benchmarks.md).

### 2. Head-to-Head Under Real Browser Load: `kaze-dots` vs Noctalia v5.6.0

Interleaved `AB/BA/AB` (3 trials each, `linux 7.3.5-arch1-1`, `hyprland 0.57.2-1`, `chromium 158.0.8127.88-1` Wayland, deterministic local DOM + Canvas + JS tabs, fresh browser profile per trial; zero range overlap on loaded workloads):

#### A. Minimal Shell (`kaze minimal` vs `Noctalia v5.6.0`)

| Workload (`1920×1080`) | **`kaze-dots`** (`minimal`) Total System RAM | **Noctalia v5.6.0** Total System RAM | Delta (`Noctalia - Kaze`) | Shell CPU / CS/s (`Kaze` vs `Noctalia`) |
|---|---:|---:|---:|---|
| **0 tabs (Idle)** | **618.16 MiB** *(615.4–633.0)* | **633.32 MiB** *(628.3–649.3)* | **+15.2 MiB** | `0.00% / 0.50` vs `0.25% / 9.12` |
| **1 Chromium tab** *(14 PIDs)* | **844.62 MiB** *(841.7–867.0)* | **888.96 MiB** *(883.0–896.4)* | **+44.3 MiB** | `0.00% / 0.50` vs `0.12% / 8.62` |
| **8 Chromium tabs** *(22 PIDs)* | **1,032.61 MiB** *(1,026.9–1,035.5)* | **1,070.33 MiB** *(1,068.3–1,079.6)* | **+37.7 MiB** | `0.00% / 0.25` vs `0.25% / 8.75` |

#### B. Full Desktop Parity (`kaze full` vs `Noctalia v5.6.0` + `fcitx5-bamboo` + `mate-polkit`)

| Workload (`1920×1080`) | **`kaze full`** Total RAM (`Shell + IME/Polkit PSS`) | **Noctalia + IME/Polkit** Total RAM (`Shell + IME/Polkit PSS`) | Delta (`Noctalia - Kaze`) | Shell CPU / CS/s (`Kaze` vs `Noctalia`) |
|---|---:|---:|---:|---|
| **0 tabs (Idle)** | **645.86 MiB** *(635.6–648.3)* · `97.42 MiB`* | **674.06 MiB** *(672.2–676.8)* · `122.38 MiB` | **+28.2 MiB** | `0.00% / 0.25` vs `0.12% / 6.12` |
| **1 Chromium tab** *(14 PIDs)* | **884.28 MiB** *(877.7–885.3)* · **`80.09 MiB`** | **923.89 MiB** *(914.9–933.8)* · **`118.56 MiB`** | **+39.6 MiB** | `0.00% / 2.50` vs `0.12% / 6.87` |
| **8 Chromium tabs** *(22 PIDs)* | **1,062.59 MiB** *(1,061.2–1,068.4)* · **`81.52 MiB`** | **1,102.73 MiB** *(1,095.8–1,120.6)* · **`118.90 MiB`** | **+40.1 MiB** | `0.00% / 0.75` vs `0.25% / 7.37` |

*Chromium PSS itself was identical on both shells (`~434–437 MiB` for 1 tab, `~609–610 MiB` for 8 tabs). Under 1–8 tabs, `kaze-dots` shell-only PSS dropped to **`43.5–45.1 MiB`** (vs **`83.5–83.9 MiB`** for `noctalia`) due to shared Cairo/Pango/fontconfig pages with Chromium. \*At 0 tabs, `kaze full` still included short-lived `glycin` image-decode workers right after restarting Waybar/swaybg; once settled (`tabs_1`/`tabs_8`), shell + IME/Polkit held steady at **`80.1–81.5 MiB`**.*

---

## Design Discipline & Explicit Non-Goals

- **No Qt/QML, Electron, GTK4/AGS, wgpu/Iced, or Node/Python runtimes** in the desktop stack.
- **No polling scripts or custom resident helpers** — Waybar indicators use `interval: "once"` + `RTMIN` signals (`+8` recording, `+9` Night Light, `+11` Caffeine).
- **No hijacking external app themes** — Kaze does not overwrite your GTK3/GTK4/Qt6/btop/Neovim configs (optional `sync_prefer_dark = true` in `user.lua` only toggles `color-scheme`).
- **No forced suspend or silent lock recovery** — **Screen Off** uses DPMS only; crashed lock recovery requires authenticated physical TTY action (`hyprctl -i <sig> eval 'hl.clear_crashed_lockscreen()'`).

---

## Verification & Documentation

Run the host check suite from the repository root:

```bash
find lua hypr bin tests -type f \( -name '*.lua' -o -path 'bin/kaze-*' \) -print0 | xargs -0 -r -n1 luac -p
lua tests/run.lua
shellcheck scripts/*.sh 2>/dev/null || bash -n scripts/*.sh
```

| Document | Purpose |
|---|---|
| [GOAL.md](GOAL.md) | Vision, measurable RAM/CPU budgets, scope boundaries, and roadmap |
| [DESIGN.md](DESIGN.md) | Visual language, layout geometry, color token system, typography, OSD & TUI UX |
| [CHECKLIST.md](CHECKLIST.md) | Complete Stage 1–3 implementation & empirical verification record |
| [docs/specs/01-architecture.md](docs/specs/01-architecture.md) | Lua compiler pipeline, atomic transactions, and runtime process graph |
| [docs/specs/02-layouts.md](docs/specs/02-layouts.md) | Exact Waybar geometry & CSS contracts for `sidebar`, `islands`, and `slim` |
| [docs/specs/03-theming.md](docs/specs/03-theming.md) | Token schema, built-in palettes, WCAG clamping, and app emitter specs |
| [docs/specs/04-cli-and-keybinds.md](docs/specs/04-cli-and-keybinds.md) | Full `kaze-*` CLI contracts and Hyprland keybind matrix |
| [docs/specs/05-verification-and-benchmarks.md](docs/specs/05-verification-and-benchmarks.md) | Isolated KVM VM harness, T0/T1/T2 protocol, and empirical benchmark logs |
| [AGENTS.md](AGENTS.md) | Repository rules, boundaries, and verification gates for coding agents |
