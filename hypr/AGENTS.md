# Hyprland Lua

## Reload and precedence

- Use the native `hl.*` API. Write class, title and layer matches as compositor regexes, not Lua patterns.
- [hyprland.lua](hyprland.lua) clears cached modules before rebuilding `kaze._ctx`.
  Include new reloadable config modules in that reset or edits may take effect only on a new login.
- Use the [settings loader](../lua/kaze/hypr_user.lua): defaults, style, profile, then user overrides.
  Keep `user.lua` optional and user-owned; edit the [seed template](../templates/hypr-user.lua.example), never the installed override.
- Load the generated `kaze-theme` with `pcall`; login must work before the first template exists.
  Apply the theme after base config and apply the user's `border_override` last.
- Replay `$XDG_RUNTIME_DIR/kaze/monitors.lua` **after** the base monitor rules. This is session state
  written by [kaze-display](../bin/kaze-display), not a file to install. Skip it if absent or the runtime root isn't absolute.

## Events and rules

- Keep session start/stop in the [compositor lifecycle hooks](execs.lua), not at module load:
  a reload is not a login. Pass the originating instance signature on shutdown.
- Keep the startup grace across reloads and filter virtual outputs before opening the hotplug menu;
  creating `kaze-share` must not prompt the user to configure a physical monitor.
- Define bindings in the [shared binding data](../lua/kaze/keybinds_data.lua) so the compositor and
  [key lookup](../bin/kaze-keys) agree. Map their actions to `hl` dispatchers in [keybinds.lua](keybinds.lua).
- Keep `kaze-shell-no-anim` in [rules.lua](rules.lua) matched to the shell's animated layer namespaces.
  The shell drives its own frames; a second compositor animation causes visible glitches.

## Verify

- Exercise config loading with the mock `hl` in [the Lua suite](../tests/run.lua); syntax checks alone don't exercise reload order.
- In the isolated guest, require empty `hyprctl configerrors` and inspect `hyprctl layers` for the affected surface.
- For monitor changes, reload with a display plan active and confirm it survives; disconnect and confirm recovery.
