# kaze-dots

> An ultra-lightweight, Lua-driven personal Arch Linux + Hyprland desktop shell centered on a **vertical-first left rail (`sidebar`)**, with live-switchable **`islands`** and **`slim`** layouts — rendered by native C/C++ Wayland daemons (`waybar`, `swaybg`, `fnott`, `fuzzel`, `foot --server`).

## Why kaze-dots?

Heavy QML/Qt and GPU-backed Wayland shells routinely consume `90–350 MiB` PSS and wake hybrid dGPUs even at idle. `kaze-dots` uses **Lua as the single source of truth** for configuration, theming, layout compilation, and CLI tooling while delegating runtime rendering exclusively to battle-tested native C/C++ Wayland binaries:

- **~53 MiB total stack PSS** at `1920×1080` (`0.00%` idle CPU, `0 MiB` dGPU VRAM)
- **3 live-switchable layouts** from one Lua config:
  - `sidebar` *(default)* — sleek `42px` vertical left rail with full vertical workspace height & matched frame geometry
  - `islands` — floating top pill islands with crisp frosted glass blur
  - `slim` — flat `28px` ultra-minimal top bar for compact displays
- **4 built-in themes** (`kaze`, `lavender`, `tokyonight`, `carbon`) synced atomically to Hyprland, Waybar, Foot, Fuzzel, Fnott, and Hyprlock
- **Zero polling scripts**: 100% native C++ Waybar modules + Hyprland IPC + on-demand floating TUIs (`nmtui`, `bluetui`, `wiremix`, `btop`)

## Project Documentation

Read these documents in order before implementing or modifying code:

| Document | Purpose |
|---|---|
| [AGENTS.md](AGENTS.md) | Repository rules, commands, boundaries, and verification gates for AI coding agents |
| [GOAL.md](GOAL.md) | Vision, measurable performance/RAM budgets, scope boundaries, and milestone roadmap |
| [DESIGN.md](DESIGN.md) | Visual language, layout geometry, color token system, typography, OSD & TUI UX |
| [docs/specs/01-architecture.md](docs/specs/01-architecture.md) | Lua engine architecture, compile/generate pipeline, runtime process graph |
| [docs/specs/02-layouts.md](docs/specs/02-layouts.md) | Exact specs for `sidebar`, `islands`, and `slim` layouts & hot-switch contract |
| [docs/specs/03-theming.md](docs/specs/03-theming.md) | Theme token schema, built-in palettes, and per-app emitter specifications |
| [docs/specs/04-cli-and-keybinds.md](docs/specs/04-cli-and-keybinds.md) | Lua CLI tools contract (`kaze-*`) and Hyprland keybind matrix |
| [docs/specs/05-verification-and-benchmarks.md](docs/specs/05-verification-and-benchmarks.md) | Clean Arch KVM VM testing workflow, regression gates, and benchmark methodology |

## Quick Start (Arch Linux)

```bash
# 1. Install official Arch [extra] dependencies (0 AUR packages)
./scripts/install-packages.sh

# 2. Back up existing configs, create ~/.config/kaze/user.lua (if absent),
#    symlink kaze-dots, and generate all daemon configs
./scripts/apply.sh
```

- **Customize**: Edit `~/.config/kaze/user.lua` (seeded from [templates/user.lua.example](templates/user.lua.example), never overwritten) and run `kaze-sync --reload`.
- **Switch Layouts / Themes live**: Run `kaze-layout [sidebar|islands|slim|--menu]` or `kaze-theme [kaze|lavender|tokyonight|carbon|--menu]` (or open `kaze-menu` with `Super + Shift + Space`).
- **Rollback**: Run the generated `~/.config/.kaze-backup-<timestamp>/rollback.sh` created by `scripts/apply.sh`.
- **VM Testing**: Boot the isolated Arch KVM test VM (`./scripts/launch-vm.sh`) or run the full automated Gate 2 + Gate 3 suite (`./tests/vm-verify.sh`).

## Measured VM Benchmarks (`1920×1080`, Arch KVM VirGL)

Measured via `./tests/vm-verify.sh` across all 7 steady-state daemons (`waybar`, `swaybg`, `foot --server`, `fnott`, `hypridle`, `wl-paste` × 2) after 10s settle + 10s sampling window:

| Layout | Waybar Geometry (`x y w h`) | Total PSS | Waybar PSS | Idle CPU | CS/s | Gate 3 |
|---|---|---:|---:|---:|---:|---|
| `sidebar` | `8 8 42 1064` | `52.79 MiB` | `35.93 MiB` | `0.00%` | `0.80` | PASS |
| `islands` | `10 6 1900 34` | `53.03 MiB` | `36.18 MiB` | `0.00%` | `0.30` | PASS |
| `slim` | `0 0 1920 28` | `52.76 MiB` | `35.86 MiB` | `0.00%` | `0.40` | PASS |

> *Note*: Steady-state idle reflects fresh daemon startup (`fnott` ~`2.9 MiB` PSS prior to rendering a toast); after rendering a notification, `fnott` retains ~`17.4 MiB` (`17,394 kB` measured) PSS for `fcft`/`fontconfig` glyph & font caches (`~66–67 MiB` combined until `kaze-sync --reload` restarts `fnott`).

## Current Status

- **Milestone M0 (Specification & Docs)**: Complete.
- **Milestone M1 (Core Lua Engine & Initial Layout)**: Complete.
- **Milestone M2 (`sidebar`, `islands` & `slim` Layouts, Interactive CLIs, 3×4 Test Matrix)**: Complete.
- **Milestone M3 (Arch Installer, Backup/Rollback, `user.lua`, VM Launcher & Benchmarks)**: Complete.
- **Milestone M4 (Optional Host Adoption)**: Deferred until explicit user approval.
