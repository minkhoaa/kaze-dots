# kaze-dots

Build a lightweight, vertical-first Hyprland desktop with switchable layouts and themes.
Keep the idle shell stack at ≤60 MiB PSS and ≤0.2% CPU at 1920×1080.
Use [GOAL.md](GOAL.md) for budgets and [DESIGN.md](DESIGN.md) for visual decisions.

## Core stack

- Target Arch Linux / CachyOS with official `[extra]` packages; keep the core AUR-free.
- Configure Hyprland 0.57+ with native Lua. Use Lua 5.5+ and its standard library for the compiler and CLI.
- Use Waybar, swaybg, Fnott/libnotify, Fuzzel and Foot for the UI; use hypridle and hyprlock for idle and lock.

## Repo map

Read the matching guide before editing the source paths below. Add a nested guide only for distinct local rules or checks.

| Guide | Change | Current source paths |
| --- | --- | --- |
| [config/AGENTS.md](config/AGENTS.md) | Native app settings, keybinds and output formats | `hypr/`, `templates/hypridle.conf`, `lua/kaze/layouts/`, `lua/kaze/emit_*.lua` |
| [kaze/AGENTS.md](kaze/AGENTS.md) | Lua compiler, state and CLI | `lua/kaze/`, `bin/`, `templates/user.lua.example`, `tests/run.lua` |
| [themes/AGENTS.md](themes/AGENTS.md) | Palette values and token schema | `lua/kaze/themes.lua` |
| [scripts/AGENTS.md](scripts/AGENTS.md) | Installation, backups and VM testing | `scripts/`, `tests/vm-verify.sh` |

## Global constraints

- NEVER add Qt/QML, Electron, GTK4/AGS, wgpu/Iced or Node/Python runtimes to the desktop stack.
- NEVER add polling scripts or resident helpers. Launch optional tools on demand.
- NEVER hardcode palette values in app configs or hand-edit generated configs or `state.lua`.
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
shellcheck scripts/*.sh 2>/dev/null || bash -n scripts/*.sh
```

For runtime/UI changes, use [tests/vm-verify.sh](tests/vm-verify.sh) and the [VM gates](docs/specs/05-verification-and-benchmarks.md).
Test only in the isolated Arch guest. Pin QEMU to the Intel iGPU and power off the guest cleanly after automated runs.
Report changed paths, exact checks and results, and any unverified budgets or regressions.
