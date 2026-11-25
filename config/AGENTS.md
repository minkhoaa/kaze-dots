# Native app configuration

## Scope
Edit [Hyprland modules](../hypr/) and the [hypridle template](../templates/hypridle.conf) directly. Change generated app formats in `lua/kaze/emit_*.lua` and Waybar geometry in [layout sources](../lua/kaze/layouts/).

## Local rules
- Use the native `hl.*` API, not legacy compositor `.conf` rules. Write window matchers as C++ `std::regex`, not Lua patterns.
- Use native Waybar modules or event-driven IPC. Keep `custom/menu` and `custom/power` click-only: no `exec` or `interval`. Stateful indicators may execute a single state query at startup and on their dedicated RT signal (`interval: "once"`, `exec-on-event: false`). Return empty output when inactive; no persistent scripts or polling.
- Follow the [layout contract](../docs/specs/02-layouts.md) for bar geometry, [emitter formats](../docs/specs/03-theming.md) for app colors, and the [keybind matrix](../docs/specs/04-cli-and-keybinds.md) for shortcuts.

## Verify
In the guest session, run `kaze-sync --reload`. Require empty `hyprctl configerrors` output and the expected `wallpaper` and `waybar` geometry in `hyprctl layers`. Inspect a `grim` screenshot after visual changes, including all indicators active together (`--stage2` in the VM harness).
