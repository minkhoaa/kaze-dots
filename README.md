# omarch-shell

> An ultra-lightweight, Lua-driven Arch Linux + Hyprland desktop shell combining **Omarchy's clean minimal philosophy** with live-switchable **Noctalia**, **Caelestia**, and **Omarchy** layouts — rendered by native C/C++ Wayland daemons (`waybar`, `swaybg`, `fnott`, `fuzzel`, `foot --server`).

## Why omarch-shell?

Heavy QML/Qt and GPU-backed Wayland shells routinely consume `90–350 MiB` PSS and wake hybrid dGPUs even at idle. `omarch-shell` uses **Lua as the single source of truth** for configuration, theming, layout compilation, and CLI tooling while delegating runtime rendering exclusively to battle-tested native C/C++ Wayland binaries:

- **~53 MiB total stack PSS** at `1920×1080` (`0.00%` idle CPU, `0 MiB` dGPU VRAM)
- **3 live-switchable layouts** from one Lua config:
  - `noctalia` *(default)* — floating top pill islands with crisp frosted glass blur
  - `caelestia` — sleek `42px` vertical left sidebar with matched frame geometry
  - `omarchy` — flat `28px` ultra-minimal top bar for maximum vertical workspace
- **4 built-in themes** (`noctalia`, `lavender`, `tokyonight`, `carbon`) synced atomically to Hyprland, Waybar, Foot, Fuzzel, Fnott, and Hyprlock
- **Zero polling scripts**: 100% native C++ Waybar modules + Hyprland IPC + on-demand floating TUIs (`nmtui`, `bluetui`, `wiremix`, `btop`)

## Project Documentation

Read these documents in order before implementing or modifying code:

| Document | Purpose |
|---|---|
| [AGENTS.md](AGENTS.md) | Repository rules, commands, boundaries, and verification gates for AI coding agents |
| [GOAL.md](GOAL.md) | Vision, measurable performance/RAM budgets, scope boundaries, and milestone roadmap |
| [DESIGN.md](DESIGN.md) | Visual language, layout geometry, color token system, typography, OSD & TUI UX |
| [docs/specs/01-architecture.md](docs/specs/01-architecture.md) | Lua engine architecture, compile/generate pipeline, runtime process graph |
| [docs/specs/02-layouts.md](docs/specs/02-layouts.md) | Exact specs for `noctalia`, `caelestia`, and `omarchy` layouts & hot-switch contract |
| [docs/specs/03-theming.md](docs/specs/03-theming.md) | Theme token schema, built-in palettes, and per-app emitter specifications |
| [docs/specs/04-cli-and-keybinds.md](docs/specs/04-cli-and-keybinds.md) | Lua CLI tools contract (`omarch-*`) and Hyprland keybind matrix |
| [docs/specs/05-verification-and-benchmarks.md](docs/specs/05-verification-and-benchmarks.md) | Clean Arch KVM VM testing workflow, regression gates, and benchmark methodology |

## Current Status

- **Milestone M0 (Specification & Docs)**: Complete.
- **Next Milestone (M1)**: Implement core Lua config engine, Hyprland Lua modules, and `noctalia` default layout, then verify inside the clean Arch KVM VM.
