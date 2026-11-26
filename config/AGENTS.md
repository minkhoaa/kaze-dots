# Native app configuration

## Scope
Edit [Hyprland modules](../hypr/), the default [Noctalia config](noctalia/config.toml), [Foot config](foot/foot.ini), [Zsh config](zsh/), and [systemd user units](systemd/user/) directly.

## Local rules
- Use Hyprland's native `hl.*` Lua API, not legacy compositor `.conf` rules. Write window matchers as C++ `std::regex`, not Lua patterns.
- Keep `require("noctalia")` in `hypr/hyprland.lua` and `include=~/.config/foot/themes/noctalia` in `config/foot/foot.ini` so Noctalia's built-in templates style Hyprland and Foot live without mutating symlinked repo files.
- Keep the `noctalia-no-anim` layer rule active in `hypr/rules.lua` so Hyprland never double-animates Noctalia layers.
- Keep `config/noctalia/config.toml` strictly offline and zero-polling (`offline_mode = true`, `telemetry_enabled = false`, `external_ip_enabled = false`, `[weather]`, `[calendar]`, `[system.monitor]`, `[dock]`, `[desktop_widgets]` disabled, `plugins.auto_update = "none"`).

## Verify
In the guest session, run `noctalia config validate`, `foot --check-config`, and check that `hyprctl configerrors` is empty and `noctalia-bar-*` is present in `hyprctl layers`. Inspect a `grim` screenshot after visual changes.
