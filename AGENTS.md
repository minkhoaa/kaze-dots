# AGENTS.md

Repository operating manual for AI coding agents working on `omarch-shell`. Keep changes tightly aligned with [GOAL.md](GOAL.md), [DESIGN.md](DESIGN.md), and [docs/specs/](docs/specs/01-architecture.md).

## 1. Project Purpose

`omarch-shell` is a modular, Lua-driven Arch Linux + Hyprland desktop configuration and layout engine. Users configure layout, theme, apps, and behavior in Lua; the Lua engine generates and hot-reloads native configs for Waybar, Foot, Fuzzel, Fnott, Hyprlock, and Hyprland while keeping total desktop idle overhead around `~53 MiB` PSS and `0.00%` CPU.

## 2. Technical Stack

- **Target OS**: Arch Linux / CachyOS (official `[extra]` packages only; zero AUR build dependencies for core stack).
- **Compositor**: Hyprland `0.57+` using its **native Lua config API** (`hyprland.lua`, `hl.*`), NOT legacy `hyprland.conf`.
- **Control Plane & CLI**: Lua `5.5+` (`lua`, `luac`) with zero external LuaRocks dependencies (pure Lua standard library).
- **Runtime Renderers (C/C++ Native)**:
  - Bar: `waybar` (C++ / GTK3 + Cairo, native C++ modules only)
  - Wallpaper: `swaybg`
  - Notifications & Progress OSD: `fnott` + `libnotify` (`notify-send`)
  - Launcher / Dmenu / Switchers: `fuzzel`
  - Terminal & Floating TUIs: `foot --server` + `footclient` hosting `nmtui`, `bluetui`, `wiremix`, `btop`
  - Idle / Lock / Clipboard / Screenshot: `hypridle`, `hyprlock`, `wl-clipboard`, `cliphist`, `grim`, `slurp`
  - Hardware Control: `wpctl` (WirePlumber), `brightnessctl`, `playerctl`, `nmcli`

## 3. Repository Structure (Target Architecture)

```text
omarch-shell/
├── AGENTS.md                   # This file (agent operating rules)
├── GOAL.md                     # Objectives, hard RAM/CPU budgets, milestones
├── DESIGN.md                   # Aesthetic & UX design system
├── docs/specs/                 # Detailed engineering specifications (01..05)
├── lua/omarch/                 # Pure Lua library (config, themes, layouts, emitters, state)
├── hypr/                       # Hyprland 0.57+ native Lua modules (hyprland.lua, core, rules, keybinds, execs)
├── bin/                        # Executable Lua CLI tools (omarch-sync, omarch-layout, omarch-theme, omarch-menu, omarch-power, omarch-tui, omarch-osd)
├── templates/                  # Static non-Lua fallbacks (hypridle.conf, default wallpaper assets)
├── scripts/                    # Installer, symlink applicator, VM sync/test helpers
└── tests/                      # Lua unit tests + VM verification & telemetry scripts
```

Read the specific spec before editing its area:
- Engine/pipeline changes → [docs/specs/01-architecture.md](docs/specs/01-architecture.md)
- Layout/Waybar CSS/JSONC changes → [docs/specs/02-layouts.md](docs/specs/02-layouts.md)
- Palette/emitter changes → [docs/specs/03-theming.md](docs/specs/03-theming.md)
- CLI/keybind changes → [docs/specs/04-cli-and-keybinds.md](docs/specs/04-cli-and-keybinds.md)
- Benchmarking/VM checks → [docs/specs/05-verification-and-benchmarks.md](docs/specs/05-verification-and-benchmarks.md)

## 4. Development & Verification Commands

Use these exact commands — do not guess alternatives.

### Local Static Checks (run before every VM deploy or commit)
```bash
# 1. Syntax-check every Lua module and executable
find lua hypr bin tests -type f \( -name '*.lua' -o -path 'bin/omarch-*' \) -print0 | xargs -0 -r -n1 luac -p

# 2. Run pure-Lua unit / emitter smoke tests (when tests/ exist)
lua tests/run.lua

# 3. Validate generated JSONC / shell scripts
shellcheck scripts/*.sh 2>/dev/null || bash -n scripts/*.sh
```

### Isolated Arch KVM VM Verification (mandatory for runtime/UI changes)
VM host: `bench@127.0.0.1:22222`, SSH key: `/home/khoa/.local/share/shell-bench-vm/bench_id_ed25519`.
```bash
# Check if VM is running (Linux /proc/comm truncates qemu-system-x86_64 to 15 chars!)
pgrep -x qemu-system-x86

# Verify Hyprland config errors, monitors, and layers inside VM
ssh -i /home/khoa/.local/share/shell-bench-vm/bench_id_ed25519 -p 22222 -o StrictHostKeyChecking=no bench@127.0.0.1 '
  SIG=$(ls -1t /run/user/1000/hypr/ | head -n1)
  HYPRLAND_INSTANCE_SIGNATURE="$SIG" XDG_RUNTIME_DIR=/run/user/1000 hyprctl configerrors
  HYPRLAND_INSTANCE_SIGNATURE="$SIG" XDG_RUNTIME_DIR=/run/user/1000 hyprctl layers
'
```
Full headless boot, screenshot capture, and PSS/CPU telemetry protocol are specified in [docs/specs/05-verification-and-benchmarks.md](docs/specs/05-verification-and-benchmarks.md).

## 5. Architecture & Design Rules

1. **Lua is the Single Source of Truth**: Users edit Lua (`config.lua`, `themes.lua`, `hypr/*.lua`). All Waybar (`config.jsonc`, `style.css`, `colors.css`), Foot, Fuzzel, Fnott, and Hyprlock configs are **generated deterministically** by `omarch-sync`.
2. **Zero Polling Rule**: Never add periodic `custom/*` bash/python polling scripts to Waybar (`interval: 1` shelling out to `awk`/`grep`/`curl`). Use Waybar's native C++ modules (`hyprland/workspaces`, `clock`, `network`, `wireplumber`, `battery`, `tray`, `mpris`) or event-driven IPC.
3. **Zero Heavy Runtimes**: Do not introduce Qt/QML (`quickshell`), Electron, GTK4/AGS, Rust `wgpu`/Iced, or background Python/Node daemons into the desktop stack.
4. **Hyprland 0.57+ Lua API Gotchas**:
   - `hl.window_rule({ match = { ... } })` uses **C++ `std::regex`**, NOT Lua `%` escapes (write `^om-tui$`, never `^om%-tui$`).
   - Do not use legacy `.conf` syntax or deprecated `windowrulev2` / `layerrule` string rules.
   - Always test reloads with `hyprctl configerrors` — output must be completely empty.
5. **Process Name Safety**: Never use `pkill -f` with a substring that appears in the invoking shell command. Use `pkill -x <exact_15char_comm>` (e.g., `pkill -x qemu-system-x86`, `pkill -x waybar`).

## 6. Coding & Naming Conventions

- **Files & CLI binaries**: `kebab-case` (`bin/omarch-sync`, `docs/specs/02-layouts.md`).
- **Lua modules & table keys**: `snake_case` (`lua/omarch/emit_waybar.lua`, `bar_height`, `gaps_out`).
- **Pure Emitters**: Every config emitter (`lua/omarch/emit_*.lua`) must be a pure function `(cfg, theme, layout_spec) -> string`. File I/O and atomic writes (`write .tmp` → `os.rename`) happen only in `lua/omarch/fs.lua` / `omarch-sync`.
- **Zero External Lua Dependencies**: Use standard Lua 5.5 libraries only (`io`, `os`, `string`, `table`, `math`). Quote all shell arguments safely via a shared `shell_quote(s)` helper.
- **No Silent Failures**: Every CLI tool exits non-zero with a clear `stderr` message when an invalid layout/theme or missing dependency is encountered.

## 7. Testing & Verification Expectations

Before marking any implementation task complete:
1. All modified `.lua` files pass `luac -p` with zero errors.
2. Pure-Lua emitter tests generate valid output for **all 3 layouts** (`noctalia`, `caelestia`, `omarchy`) × **all 4 themes** (`noctalia`, `lavender`, `tokyonight`, `carbon`).
3. Any runtime/Hyprland/Waybar/UI change is deployed and verified inside the clean Arch KVM VM (`1920×1080`):
   - `hyprctl configerrors` is empty.
   - All target layers (`wallpaper`, `waybar`) are present with expected geometry.
   - Idle stack PSS stays within budget (`≤ 60 MiB` at `1920×1080`) and idle CPU stays `≤ 0.2%`.
   - Visual layout changes include `grim` screenshot inspection in the VM.

## 8. Host Isolation & Safety Boundaries (STRICT)

- **NEVER** modify, reload, restart, or kill the user's live host Hyprland / `caelestia-shell` session.
- **NEVER** run `sudo`, modify `/etc` or `/usr`, or install/remove host packages.
- **NEVER** overwrite `~/.config/hypr`, `~/.config/waybar`, or `~/.config/quickshell` on the host unless the user explicitly asks to apply to host.
- **ALWAYS** pin QEMU GTK/EGL rendering to Intel iGPU (`__GLX_VENDOR_LIBRARY_NAME=mesa MESA_LOADER_DRIVER_OVERRIDE=iris` or `rendernode=/dev/dri/renderD128`) so the host NVIDIA dGPU stays asleep.
- **ALWAYS** power off the VM cleanly (`sudo poweroff` inside VM) after automated test runs so `arch-bench.qcow2` is never left locked.

## 9. Generated & Restricted Files

- **Generated (DO NOT hand-edit in `~/.config/` or `state/`)**:
  - `~/.config/waybar/{config.jsonc,style.css,colors.css}`
  - `~/.config/foot/foot.ini`
  - `~/.config/fuzzel/fuzzel.ini`
  - `~/.config/fnott/fnott.ini`
  - `~/.config/hypr/hyprlock.conf`
  - `~/.config/omarch/state.lua`
- **Source of Truth (edit here instead)**:
  - `lua/omarch/*.lua` and `~/.config/omarch/user.lua`
  - `hypr/*.lua`

## 10. Completion & Reporting Requirements

When finishing any task, report concisely:
1. **What changed**: List created/modified files with clickable paths.
2. **Verification run**: Exact commands executed and observed output (`luac -p`, `hyprctl configerrors`, VM telemetry/screenshots if applicable).
3. **Budget & regressions**: Confirm RAM/CPU budgets and host isolation were respected, and flag any open TODOs or assumptions.
