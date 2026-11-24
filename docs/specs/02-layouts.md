# Spec 02 — Multi-Layout System (`noctalia`, `caelestia`, `omarchy`)

## 1. Layout Contract

Every layout module in `lua/omarch/layouts/<name>.lua` exports a deterministic table:

```lua
return {
    name = "noctalia",
    label = "Noctalia (Floating Pills)",
    hypr = {
        gaps_in = 5,
        gaps_out = 10,
        rounding = 10,
        border_size = 1,
    },
    ui = {
        fuzzel_radius = 12,
        fnott_radius = 10,
        fnott_anchor = "top-right",
        fnott_edge_margin_vertical = 46,
        fnott_edge_margin_horizontal = 12,
    },
    build_waybar_config = function(cfg, theme) ... end, -- returns JSONC string
    build_waybar_css    = function(cfg, theme) ... end, -- returns CSS string
}
```

### Shared Rules Across All 3 Layouts
- **Zero polling**: Only native Waybar C++ modules (`hyprland/workspaces`, `hyprland/window`, `mpris`, `clock`, `network`, `wireplumber`, `battery`, `tray`) plus static click-only launchers (`custom/menu`, `custom/power` with **no `exec`** and **no `interval`** — pure `format` + `on-click`).
- **Consistent click targets**:
  - `custom/menu` → `omarch-menu`
  - `network` → `omarch-tui wifi`
  - `wireplumber` → left-click `omarch-tui audio`, right-click `omarch-osd vol-mute`, scroll up/down `omarch-osd vol-up` / `vol-down`
  - `battery` → tooltip shows power draw & time remaining; click opens `omarch-tui sysmon`
  - `custom/power` → `omarch-power`
  - `hyprland/workspaces` → scroll up/down switches workspace (`hyprctl dispatch workspace e+1/-1`)
- **Layer blur**: Hyprland applies `hl.layer_rule({ match = { namespace = "waybar" }, blur = true, ignore_alpha = 0.25 })`. Because `ignore_alpha = 0.25` skips fully transparent gaps (`alpha = 0.0`), floating pill layouts (`noctalia`) blur **only inside the visible pills**, never creating ugly blurred boxes in empty spaces between islands.

---

## 2. Layout 1: `noctalia` *(Default — Floating Pill Islands)*

### Visual Structure (`1920×1080`)
```text
 ╭───┬───────────╮              ╭───────────────────╮              ╭──────────────────────────┬───╮
 │ 󰣇 │ • ━━ • •  │              │ 󰎈 Song · 14:32    │              │ 󰖩  󰕾 64%  󰁹 92%  [tray] │ ⏻ │
 ╰───┴───────────╯              ╰───────────────────╯              ╰──────────────────────────┴───╯
  margin-top: 6px, margin-left/right: 10px, height: 34px, outer window background: transparent
```

### Geometry & Hyprland Sync
- Waybar: `position: "top"`, `height: 34`, `margin-top: 6`, `margin-left: 10`, `margin-right: 10`, `margin-bottom: 0`, `exclusive: true`, `reload_style_on_change: false`.
- Outer `window#waybar`: `background: transparent; border: none;`.
- Three distinct floating island containers (`.modules-left`, `.modules-center`, `.modules-right`):
  - Background: `alpha(@bg_alt, 0.88)`
  - Border: `1px solid alpha(@border, 0.85)`
  - Border radius: `14px`
  - Padding: `0 6px`
- Hyprland: `gaps_in = 5`, `gaps_out = 10`, `rounding = 10`, `border_size = 1`.
- Fnott: `anchor = top-right`, `edge-margin-vertical = 48` (clears the floating bar cleanly), `border-radius = 10`.

### Waybar Module Slots
- **Left**: `["custom/menu", "hyprland/workspaces"]`
  - `custom/menu`: Arch icon (`󰣇`), subtle circular hover highlight (`border-radius: 10px`).
  - `hyprland/workspaces`: 5 persistent workspaces (`1..5`), inactive dots (`8px × 8px` circle in `@surface`), occupied workspaces (`8px × 8px` in `@fg_muted`), active workspace smoothly expands to **`24px × 8px` rounded pill in `@accent`** (classic Noctalia/Caelestia signature).
- **Center**: `["mpris", "clock"]`
  - `mpris`: Shows `󰎈 Artist - Title` (max-length 28) **only when playing/paused**; collapses to `0px` cleanly when nothing is playing so the center pill shrinks gracefully to just the clock.
  - `clock`: `Tue 25 Nov · 00:15` (weight `600`, tooltip shows full monthly calendar).
- **Right**: `["tray", "network", "wireplumber", "battery", "custom/power"]`
  - `tray`: `icon-size: 14`, `spacing: 6`.
  - `network`: Compact icon + SSID tooltip (`󰤨` Wi-Fi / `󰈀` Eth / `󰤭` Off).
  - `wireplumber`: Icon + percentage (`󰕾 64%`, turns `@danger` when muted).
  - `battery`: Icon + percentage (`󰁹 92%`; hidden gracefully on desktops/VMs with no battery, or displays AC/charging icon when present).
  - `custom/power`: Minimal `⏻` button with `@danger` hover tint.

---

## 3. Layout 2: `caelestia` *(Vertical Left Sidebar)*

### Visual Structure (`1920×1080`)
```text
 ╭────╮
 │ 󰣇  │  <- Top: Menu / OS icon
 │    │
 │ •  │
 │ ┃  │  <- Center: Vertical Workspace Pills (active = 24px tall vertical accent pill)
 │ •  │
 │ •  │
 │    │
 │ 󰖩  │  <- Bottom: Stacked status icons + vertical 2-line clock (HH / MM) + Power
 │ 󰕾  │
 │ 󰁹  │
 │ 14 │
 │ 32 │
 │ ⏻  │
 ╰────╯
  width: 42px, margin: 8px 0 8px 8px, border-radius: 14px
```

### Geometry & Hyprland Sync
- Waybar: `position: "left"`, `width: 42`, `margin-top: 8`, `margin-bottom: 8`, `margin-left: 8`, `margin-right: 0`, `exclusive: true`.
- Unified vertical rail on `window#waybar`:
  - Background: `alpha(@bg_alt, 0.90)`
  - Border: `1px solid alpha(@border, 0.85)`
  - Border radius: `14px`
- Hyprland: `gaps_in = 5`, `gaps_out = 10`, `rounding = 12`, `border_size = 1` (gives the Caelestia framed-canvas aesthetic while preserving full `1080px` vertical screen height!).
- Fnott: `anchor = top-right`, `edge-margin-vertical = 12`, `edge-margin-horizontal = 12`, `border-radius = 12`.

### Waybar Module Slots
- **Top (`modules-left`)**: `["custom/menu"]`
- **Middle (`modules-center`)**: `["hyprland/workspaces"]`
  - Vertical stack; inactive `8px × 8px` dots, active expands vertically to **`8px × 24px` pill in `@accent`**.
- **Bottom (`modules-right`)**: `["tray", "network", "wireplumber", "battery", "clock", "custom/power"]`
  - Every status module uses compact **icon-only** format (`󰤨`, `󰕾`, `󰁹`) with rich hover tooltips (exact percentage, SSID, device name) so nothing overflows the `42px` width!
  - `clock`: 2-line vertical format `"{:%H\n%M}"` (`font-weight: 700`, centered, tooltip shows full date + calendar).
  - `tray`: vertical stack, `icon-size: 14`, `spacing: 8`.

---

## 4. Layout 3: `omarchy` *(Flat Ultra-Minimal Top Bar)*

### Visual Structure (`1920×1080`)
```text
 󰣇  1  [2]  3  4  5                Tue 25 Nov  14:32                󰤨  󰕾 64%  󰁹 92%  [tray]  ⏻
 ────────────────────────────────────────────────────────────────────────────────────────────────
  height: 28px, margin: 0, border-radius: 0, 1px bottom hairline border
```

### Geometry & Hyprland Sync
- Waybar: `position: "top"`, `height: 28`, `margin: 0`, `exclusive: true`.
- Full-width flush strip:
  - Background: `alpha(@bg_alt, 0.92)`
  - Border: `border-bottom: 1px solid alpha(@border, 0.85)`
  - Border radius: `0px`
- Hyprland: `gaps_in = 4`, `gaps_out = 6`, `rounding = 6`, `border_size = 1`.
- Fnott: `anchor = top-right`, `edge-margin-vertical = 36`, `edge-margin-horizontal = 10`, `border-radius = 6`.

### Waybar Module Slots
- **Left**: `["custom/menu", "hyprland/workspaces", "hyprland/window"]`
  - Numbered workspaces (`1..5`) with crisp `2px` bottom accent underline on active tab; subtle truncated active window title (`max-length: 42`).
- **Center**: `["clock"]`
- **Right**: `["tray", "network", "wireplumber", "battery", "custom/power"]`

---

## 5. Live Hot-Switch Contract (`omarch-layout <name>`)

Switching layout must execute cleanly in **`≤ 500 ms`** without restarting Hyprland:
1. Validate `<name>` ∈ `{ "noctalia", "caelestia", "omarchy" }`.
2. Update `~/.config/omarch/state.lua` atomically (`layout = "<name>"`).
3. Invoke `omarch-sync --reload`:
   - Regenerates `waybar/{config.jsonc,style.css,colors.css}`, `fnott.ini`, `fuzzel.ini`, `foot.ini`, `hyprlock.conf`.
   - Runs `hyprctl reload` (applies new `gaps_in`, `gaps_out`, `rounding`, `border_size`).
   - Restarts `waybar` cleanly (`pkill -x waybar`, wait up to `300ms` for exit, launch `waybar` detached).
   - Restarts `fnott` cleanly (`pkill -x fnott`, relaunch detached) so notification anchor/radius/margins match the new layout immediately.
4. Send a brief confirmation toast via `notify-send` (`"Layout switched"` → `"Active: Noctalia"`).
