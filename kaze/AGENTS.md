# Lua helpers and CLIs

## Scope
Keep minimal Hyprland/session helper modules in [lua/kaze/](../lua/kaze/) and executable entry points in [bin/](../bin/). Only add helpers for capabilities Noctalia does not natively provide (Hyprland session lifecycle, Foot server client, multi-monitor layouts, Hyprland keybind lookup, on-demand TUI drawer, Wayland screen recording, and dotfiles doctor).

## Local rules
- Use `snake_case` for Lua modules and keys; use `kebab-case` for executable names.
- Write runtime/state files atomically with `fs.write_atomic`. Quote shell arguments with `fs.shell_quote`.
- Route all picker UIs (`kaze-display --menu`, `kaze-keys`) through `noctalia dmenu` via `kaze.popups`.
- Reject invalid options and missing CLI dependencies with a clear message on stderr and a non-zero exit status.

## Verify
Run `lua tests/run.lua` and `bin/kaze-doctor --offline` from the repository root.
