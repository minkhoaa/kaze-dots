# Spec 02 — Bar Layout & Geometry (Noctalia Shell v5.x Native)

## 1. Visual System (Omarchy-Inspired Flat Geometry)

Layout geometry is unified across Noctalia (`config/noctalia/config.toml`) and Hyprland (`hypr/core.lua`, `hypr/rules.lua`):

- **Sharp corners (`0px`):** `corner_radius_scale = 0.0` and `radius = 0` in Noctalia; `rounding = 0` in Hyprland.
- **Crisp `2px` borders, zero shadows:** `border_width = 2.0` (`outline_variant`), `shadow = false`, `popup_shadows = false` in Noctalia; `border_size = 2`, `decoration.shadow.enabled = false` in Hyprland.
- **No double animations:** `hypr/rules.lua` applies `no_anim = true` to `^noctalia-(bar-.+|notification|dock|panel|attached-panel|osd|window-switcher)$` so Noctalia's internal animations render cleanly without Hyprland layer double-animation.
- **Hyprland framing grid:** `gaps_in = 4`, `gaps_out = 8` matching Noctalia's `margin_edge = 8`, `margin_ends = 8`, `floating_offset = 8`. Optional native single-window smart gaps (`smart_gaps = true` in `user.lua`) collapse gaps/borders on `w[tv1]` and `f[1]`.

## 2. Default Layout: Vertical Left Rail (`42px`)

```text
 ┌────┐
 │ 󰀻  │  start:   launcher, ws (persistent 1..5, square capsules, 0px radius)
 │ 1  │
 │[2] │
 │ 3  │
 │ 4  │
 │ 5  │
 │    │
 │ 14 │  center:  vclock (stacked 24h vertical clock: {:%H\n%M})
 │ 32 │
 │    │
 │ 󰍹  │  end:     tray, display, net, vol, bat, notifications, control-center, session
 │ 󰤨  │
 │ 󰕾  │
 │ 󰁹  │
 │ 󰂚  │
 │ 󰒓  │
 │ ⏻  │
 └────┘
  position = "left", thickness = 42, margin_edge = 8, margin_ends = 8,
  background_opacity = 0.94, compositor_blur = true
```

### Custom Display Button (`[widget.display]`)
- `glyph = "device-desktop"`
- Left-click: `exec kaze-display --menu` (Mirror / Present Workspace / Virtual Share 1080p / Extend & Layout)
- Right-click: `exec kaze-display toggle-window-share` (push/pull focused window to shared workspace)

### Floating Panels & Overlays
- **Notifications & OSD:** anchored `top_right` (`offset_x = 12`, `offset_y = 12`, `width = 340`, `border_width = 2.0`, `background_opacity = 0.94`).
- **Control Center:** attached to the bar (`width = 580`, `sidebar = "compact"`), with disabled heavy tabs hidden (`hidden_tabs = [ "weather", "calendar", "monitor", "screen-time" ]`).
- **Launcher, Clipboard, Session:** floating centered (`launcher.width = 560`, `layout = "simple"`, `compact = true`).
- **Noctalia Settings GUI (`dev.noctalia.Noctalia`):** floats centered at `56.25% × 85%` of the active monitor.
- **Floating TUI Drawer (`^kaze-tui$`):** slides in from the left edge (`x = 58`, `y = 12`, `42%` width × `monitor_h - 24`), flush next to the `42px` bar (`8px + 42px + 8px = 58px`).
- **Virtual Share Preview (`^at\.yrlf\.wl_mirror$`):** pinned bottom-right PiP (`28% × 28%`, `keep_aspect_ratio = true`, `opaque = true`, `no_blur = true`).

## 3. Customization Without Re-Generating Configs

Users who prefer a top/bottom bar, rounded corners, different widget ordering, or different transparency edit directly in **Noctalia Settings (`Super + I`)** or `~/.config/noctalia/config.toml`:
- `scripts/apply.sh` preserves `~/.config/noctalia/config.toml` across re-applies.
- `kaze-doctor --diff` reports newly added upstream sections, keys, or bar widgets from `config/noctalia/config.toml` without overwriting user choices.
- Per-machine Hyprland geometry overrides (`gaps_in`, `gaps_out`, `border_size`, `rounding`, `smart_gaps`, `persistent_workspaces`, `blur`, `opacity`) live in `~/.config/hypr/user.lua`.
