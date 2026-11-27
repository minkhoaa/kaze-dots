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
- **Mirror Optimizer TUI (`^kaze-mirror-tui$`):** centered floating Foot window (`62% × 78%`, `center = true`) with responsive wide/medium/compact table breakpoints.
- **Noctalia Mirror Widget (`[widget.mirror]`):** `glyph = "server"` (switches to `"refresh"` + `"primary"` while a scan runs, zero polling), Left-click `kaze-mirror --menu`, Right-click `kaze-mirror --tui-window`.
- **Theme Hub Window (`^kaze-theme-hub$`):** centered floating Foot window (`64% × 74%`, `center = true`) rendering a 2-column illustrated TrueColor grid for all 11 visual styles and 17 color palettes with real-time live desktop preview and atomic `Esc` rollback (`lua/kaze/theme_hub_tui.lua`).
- **Theme Hub Widget (`[widget.theme]`):** `glyph = "palette"` (placed right beside `notifications` on every style with notifications, and on the status tray—or text-only `THEME` / `[ THEME ]` in `swiss-grid` / `tui-hacker`—across all 11 styles), Left-click `kaze-style --hub` (opens/toggles `kaze-theme-hub`), Right-click `kaze-style --menu`, Middle-click `noctalia msg theme-mode-toggle`.
- **Virtual Share Preview (`^at\.yrlf\.wl_mirror$`):** pinned bottom-right PiP (`28% × 28%`, `keep_aspect_ratio = true`, `opaque = true`, `no_blur = true`).

## 3. 11-Preset Visual Theme Suite (`kaze-style` + `lua/kaze/styles.lua`)

`kaze-style` switches across **11 canonical presets** in 3 groups (plus backwards-compatible aliases `floating-islands` → `corner-hud`, `concave-notch` → `hardware-notch`, etc.) by updating Noctalia (`~/.config/noctalia/config.toml`), Hyprland geometry overlay (`~/.config/hypr/kaze-style.lua`, always overridden by `~/.config/hypr/user.lua`), and GTK3/Thunar CSS (`~/.config/gtk-3.0/kaze-style.css`) with **0 extra daemons and 0 polling**:

| Group | Preset ID | Bar / Dock / Hyprland Behavior |
|---|---|---|
| **Angular & Minimal** | `omarchy-rail` | Flush left `42px` rail, `0px` corners, `2px` borders, `0` shadow, `tui_drawer_x = 50` |
| | `swiss-grid` | `Kaze-Swiss` light palette, `1px` rules, text-only top bar (`ws` `minimal` with `" / "`, `show_glyph = false`), `gaps_out = 16` |
| | `corner-hud` | Transparent top bar with 2 corner islands (`group:corner_left`, `group:corner_right`) and open center (`center = []`) |
| | `ghost-zero` | Auto-hide top bar (`auto_hide = true`, `reserve_space = false`), `0px` window gaps, `Super_L` hold-to-peek (`<0.25s` tap toggles launcher) |
| **Dynamic & Modern** | `dynamic-island` *(Default)* | 3-cluster top bar (`group:island_left` launcher + `focus_hint` workspace dots, centered theme-synced Live Activity `group:island` (`surface_container`) with `island_clock` + event-driven `media`/`record`/`present` + `notifications` + `control-center`, and `group:island_right` quick controls `tray`/`display`/`mirror`/`net`/`bt`/`vol`/`bat`/`session`); notif/OSD anchored `top_right` |
| | `hardware-notch` | Flush top center notch (`margin_edge = 0`, `concave_edge_corners = true`) with `focus_hint` dots, clock, and conditional media/live indicators |
| | `glass-studio` | `28px` frosted top menu bar (`active_window` + clock) + auto-hiding bottom `[dock]`, `transparency_mode = "glass"`, `rounding = 14`, soft shadows |
| | `floating-rail` | Two-tier bars (`[bar] order = [ "default", "rail" ]`): top `active_window` + status pill + left workspace/app launcher pill |
| **Retro & Editorial** | `tui-hacker` | `Kaze-Phosphor` CRT palette, `JetBrainsMono Nerd Font`, bracketed text-only `[ WS ... ] [ ... ]` clusters, `0px` / `1px` |
| | `retro-90s` | `Kaze-Retro90s` warm gray palette, bottom `36px` taskbar with `Start` button + `taskbar`, 2-layer GTK bevels & 45° Hyprland bevel borders |
| | `cinema-frame` | Wide gallery margins (`gaps_out = 28`), ultra-slim `22px` bottom subtitle strip, bottom-right notif/OSD |

Users who prefer manual adjustments edit directly in **Noctalia Settings (`Super + I`)** or `~/.config/noctalia/config.toml` and `~/.config/hypr/user.lua`:
- `scripts/apply.sh` preserves `~/.config/noctalia/config.toml` and `~/.config/hypr/user.lua` across re-applies.
- `kaze-doctor --diff` reports newly added upstream sections, keys, or bar widgets from `config/noctalia/config.toml` without overwriting user choices.
- Per-machine Hyprland geometry overrides (`gaps_in`, `gaps_out`, `border_size`, `rounding`, `smart_gaps`, `persistent_workspaces`, `blur`, `opacity`) live in `~/.config/hypr/user.lua` and take precedence over `kaze-style.lua`.
