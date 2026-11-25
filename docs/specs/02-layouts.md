# Spec 02 — Multi-Layout System (`sidebar`, `islands`, `slim`)

## 1. Layout Contract

Every layout module in `lua/kaze/layouts/<name>.lua` exports a deterministic table:

```lua
return {
    name = "sidebar",
    label = "Sidebar (Vertical Left Rail)",
    hypr = {
        gaps_in = 4,
        gaps_out = 8,
        rounding = 0,
        border_size = 2,
    },
    ui = {
        fuzzel_radius = 0,
        fnott_radius = 0,
        fnott_anchor = "top-right",
        fnott_edge_margin_vertical = 12,
        fnott_edge_margin_horizontal = 12,
    },
    build_waybar_config = function(cfg, theme) ... end, -- returns JSONC string
    build_waybar_css    = function(cfg, theme) ... end, -- returns CSS string
}
```

### Shared Rules Across All 3 Layouts
- **Zero polling scripts**: Prefer native Waybar modules (`hyprland/workspaces`, `hyprland/window`, `mpris`, `clock`, `network`, `wireplumber`, `battery`, `tray`). Static launchers `custom/menu` / `custom/power` are click-only, with **no `exec` or `interval`**. Stateful indicators use `interval: "once"`, `exec-on-event: false`, and a dedicated `signal`: the command queries the unit once at startup and on unit start/stop, including external kills and expiry. Empty output hides the whole widget (no blank padding). `pkill --require-handler` avoids signalling a Waybar that has not installed its RT handler yet.
- **Consistent click targets**:
  - `custom/menu` → left-click `kaze-menu` (Top drop-down), right-click `kaze-panel` (Right drawer)
  - `clock` → `kaze-dashboard` (Top drop-down Calendar & Media popup)
  - `network` → left-click `kaze-wifi` (Right popup), right-click `kaze-tui wifi` (Right TUI drawer)
  - `wireplumber` → left-click `kaze-audio-sink` (Right popup), middle-click `kaze-tui audio` (Right TUI drawer), right-click `kaze-osd vol-mute`, scroll up/down `kaze-osd vol-up` / `vol-down`
  - `battery` → left-click `kaze-panel` (Right Quick Control Drawer), right-click `kaze-tui sysmon` (Right TUI drawer)
  - `custom/power` → left-click `kaze-power` (Right popup), right-click `kaze-panel` (Right drawer)
  - `custom/recording` (`RTMIN+8`) → red dot while recording; click runs `kaze-record stop`
  - `custom/night` (`RTMIN+9`) → moon while Night Light is on; click runs `kaze-night off`
  - `custom/inhibit` (`RTMIN+11`) → coffee cup while Caffeine is on; click runs `kaze-inhibit off`
  - `hyprland/workspaces` → scroll up/down switches workspace (`hl.dsp.focus`)
- **Layer blur**: Hyprland applies `hl.layer_rule({ match = { namespace = "waybar" }, blur = true, ignore_alpha = 0.25 })`. Because `ignore_alpha = 0.25` skips fully transparent gaps (`alpha = 0.0`), floating pill layouts (`islands`) blur **only inside the visible pills**, never creating blurred boxes in empty spaces between islands.

---

## 2. Layout 1: `sidebar` *(Default — Vertical Left Rail)*

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
  - Background: `alpha(@bg_alt, 0.94)`
  - Border: `2px solid @border`
  - Border radius: `0px`
- Hyprland: `gaps_in = 4`, `gaps_out = 8`, `rounding = 0`, `border_size = 2` (flush `8px` sharp framing grid aligned with the `8px` sidebar margin while preserving full `1080px` vertical screen height).
- Fnott: `anchor = top-right`, `edge-margin-vertical = 12`, `edge-margin-horizontal = 12`, `border-radius = 0`.

### Waybar Module Slots
- **Top (`modules-left`)**: `["custom/menu"]`
- **Middle (`modules-center`)**: `["hyprland/workspaces"]`
  - Vertical stack; inactive `8px × 8px` dots, active expands vertically to **`8px × 24px` pill in `@accent`**.
- **Bottom (`modules-right`)**: `tray`, `network`, `wireplumber`, `battery`, recording/Night Light/Caffeine indicators, `clock`, `custom/power`
  - Every status module uses compact **icon-only** format (`󰤨`, `󰕾`, `󰁹`) with rich hover tooltips (exact percentage, SSID, device name) so nothing overflows the `42px` width.
  - `clock`: 2-line vertical format `"{:%H\n%M}"` (`font-weight: 700`, centered, tooltip shows full date + calendar).
  - `tray`: vertical stack, `icon-size: 14`, `spacing: 8`.

---

## 3. Layout 2: `islands` *(Floating Top Pill Islands)*

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
- Three distinct sharp floating island containers (`.modules-left`, `.modules-center`, `.modules-right`):
  - Background: `alpha(@bg_alt, 0.94)`
  - Border: `2px solid @border`
  - Border radius: `0px`
  - Padding: `0 3px`
- Hyprland: `gaps_in = 5`, `gaps_out = 10`, `rounding = 0`, `border_size = 2`.
- Fnott: `anchor = top-right`, `edge-margin-vertical = 48`, `border-radius = 0`.

### Waybar Module Slots
- **Left**: `["custom/menu", "hyprland/workspaces"]`
  - `custom/menu`: Arch icon (`󰣇`), subtle circular hover highlight (`border-radius: 10px`).
  - `hyprland/workspaces`: 5 persistent workspaces (`1..5`), inactive dots (`8px × 8px`), active workspace smoothly expands to **`24px × 8px` rounded pill in `@accent`**.
- **Center**: `["mpris", "clock"]`
  - `mpris`: Shows `󰎈 Artist - Title` (max-length 28) only when playing/paused; collapses cleanly when idle.
  - `clock`: `Tue 25 Nov · 00:15` (weight `600`, tooltip shows full monthly calendar).
- **Right**: `tray`, `network`, `wireplumber`, `battery`, recording/Night Light/Caffeine indicators, `custom/power`

---

## 4. Layout 3: `slim` *(Flat Ultra-Minimal Top Bar)*

### Visual Structure (`1920×1080`)
```text
 󰣇  1  [2]  3  4  5                Tue 25 Nov  14:32                󰤨  󰕾 64%  󰁹 92%  [tray]  ⏻
 ────────────────────────────────────────────────────────────────────────────────────────────────
  height: 28px, margin: 0, border-radius: 0, 1px bottom hairline border
```

### Geometry & Hyprland Sync
- Waybar: `position: "top"`, `height: 28`, `margin: 0`, `exclusive: true`.
- Full-width flush strip:
  - Background: `alpha(@bg_alt, 0.95)`
  - Border: `border-bottom: 2px solid @border`
  - Border radius: `0px`
- Hyprland: `gaps_in = 4`, `gaps_out = 6`, `rounding = 0`, `border_size = 2`.
- Fnott: `anchor = top-right`, `edge-margin-vertical = 36`, `edge-margin-horizontal = 10`, `border-radius = 0`.

### Waybar Module Slots
- **Left**: `["custom/menu", "hyprland/workspaces", "hyprland/window"]`
  - Numbered workspaces (`1..5`) with crisp `2px` bottom accent underline on active tab; subtle truncated active window title (`max-length: 42`).
- **Center**: `["clock"]`
- **Right**: `tray`, `network`, `wireplumber`, `battery`, recording/Night Light/Caffeine indicators, `custom/power`

---

## 5. Live Hot-Switch Contract (`kaze-layout <name>`)

Switching layout must execute cleanly in **`≤ 500 ms`** without restarting Hyprland:
1. Validate `<name>` ∈ `{ "sidebar", "islands", "slim" }`.
2. Ask `kaze-sync` to stage and validate the generated configs under its switch lock.
3. Reload Hyprland, restart the Waybar and Fnott user units, and wait for Waybar to map. Optional units are not restarted; the new bar queries their state at startup.
4. Commit `state.lua` atomically only after successful reload (restore the previous config on error). Send a confirmation toast unless `--quiet` is passed.

The all-on geometry gate uses all three indicators together, with MPRIS also visible in `islands` (the only layout that includes it). Exact layer rectangles at 1920×1080: `8 8 42 1064`, `10 6 1900 34`, and `0 0 1920 28`, respectively.
