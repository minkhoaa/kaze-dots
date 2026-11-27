# kaze-dots

Build a lightweight, vertical-first Hyprland desktop powered natively by **Noctalia Shell (C++ v5.x)**.
Keep the idle shell stack at ≤100 MiB PSS, ≤0.20% CPU, and 0 early portals at 1920×1080.
Use [docs/specs/05-verification-and-benchmarks.md](docs/specs/05-verification-and-benchmarks.md) for budgets and [docs/specs/02-layouts.md](docs/specs/02-layouts.md) / [docs/specs/03-theming.md](docs/specs/03-theming.md) for visual decisions.

## Core stack

- Target Arch Linux / CachyOS with official `[extra]` packages; keep the core AUR-free.
- Configure Hyprland 0.57+ with native Lua (`hypr/*.lua`) and optional `~/.config/hypr/user.lua`. Use Lua 5.5+ and its standard library for the small Hyprland helper CLIs.
- Use **Noctalia** (`noctalia`) natively for bar layout, themes/palettes, app theming templates (`hyprland`, `foot`, `gtk3`, `gtk4`, `btop`), wallpaper, launcher (`noctalia dmenu`), Control Center, Settings GUI, notifications, OSD, clipboard history, idle, lockscreen, Night Light, Caffeine, Polkit, screenshots/annotation, and window switcher; use **Foot** (`foot --server` / `footclient`) for terminals.

## Repo map

Read the matching guide before editing the source paths below. Add a nested guide only for distinct local rules or checks.

| Guide | Change | Current source paths |
| --- | --- | --- |
| [config/AGENTS.md](config/AGENTS.md) | Native Hyprland, Noctalia, Foot, and systemd configs | `hypr/`, `config/noctalia/`, `config/foot/`, `config/systemd/` |
| [kaze/AGENTS.md](kaze/AGENTS.md) | Lua helper libraries and CLIs | `lua/kaze/`, `bin/`, `templates/hypr-user.lua.example`, `tests/run.lua` |
| [scripts/AGENTS.md](scripts/AGENTS.md) | Installation, backups and VM testing | `scripts/`, `tests/vm/verify.sh` |

## Global constraints

- NEVER add Qt/QML, Electron, GTK4/AGS, wgpu/Iced or Node/Python runtimes to the desktop stack.
- NEVER add polling scripts or resident helpers. Keep Noctalia offline/zero-telemetry (`offline_mode = true`, `telemetry_enabled = false`, `[weather]`, `[calendar]`, `[system.monitor]`, `[dock]`, `[desktop_widgets]` disabled).
- NEVER duplicate features Noctalia already provides natively (bar/theme/wallpaper/screenshot/launcher/idle/lock/OSD/clipboard/Night Light/Polkit).
- NEVER modify, reload, restart or kill the live host Hyprland or Quickshell session.
- NEVER run host `sudo`, modify host `/etc` or `/usr`, or install/remove host packages.
- NEVER apply changes to host dotfiles without an explicit request.
- NEVER use `pkill -f`; match the exact process name with `pkill -x`.
- Keep edits within the requested scope.

## Common checks

Run from the repository root before every VM deployment or commit:

```sh
find lua hypr bin tests -type f \( -name '*.lua' -o -path 'bin/kaze-*' \) -print0 | xargs -0 -r -n1 luac -p
lua tests/run.lua
python3 -m unittest tests/vm/test_idle_sampler.py
shellcheck scripts/*.sh tests/vm/verify.sh tests/vm/common.sh 2>/dev/null || bash -n scripts/*.sh tests/vm/verify.sh tests/vm/common.sh
```

For runtime/UI changes, use [tests/vm/verify.sh](tests/vm/verify.sh) and the [VM gates](docs/specs/05-verification-and-benchmarks.md).
Test only in the isolated Arch guest. Pin QEMU to the Intel iGPU and power off the guest cleanly after automated runs.
Report changed paths, exact checks and results, and any unverified budgets or regressions.
