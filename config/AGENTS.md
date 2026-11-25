# Native app configuration

## Scope
Edit [Hyprland modules](../hypr/) and the [hypridle template](../templates/hypridle.conf) directly. Change generated app formats in `lua/kaze/emit_*.lua` and Waybar geometry in [layout sources](../lua/kaze/layouts/).

## Local rules
- Use the native `hl.*` API, not legacy compositor `.conf` rules. Write window matchers as C++ `std::regex`, not Lua patterns.
- Use native Waybar modules or event-driven IPC. Keep static `custom/*` launchers click-only: no `exec` or `interval`.
- Follow the [layout contract](../docs/specs/02-layouts.md) for bar geometry, [emitter formats](../docs/specs/03-theming.md) for app colors, and the [keybind matrix](../docs/specs/04-cli-and-keybinds.md) for shortcuts.

## Verify
In the guest session, run `kaze-sync --reload`. Require empty `hyprctl configerrors` output and the expected `wallpaper` and `waybar` geometry in `hyprctl layers`. Inspect a `grim` screenshot after visual changes.
