# DESIGN.md — Visual Language & Interaction System

## 1. Design Philosophy

`omarch-shell` fuses three complementary aesthetics into one coherent desktop:

1. **Omarchy Discipline (Core Ethos)**: Calm surfaces, restrained color, high information density without clutter, crisp typography, keyboard-driven navigation, and ephemeral floating TUI utilities instead of bloated settings windows.
2. **Noctalia Polish (Default Layout)**: Floating pill islands separated by breathing room, subtle `1px` hairline borders, soft frosted translucency (delegated to Hyprland's compositor blur — zero GPU overhead in Waybar), and pill-shaped active workspace indicators.
3. **Caelestia Ergonomics (Alternate Layout)**: Vertical left sidebar freeing 100% of vertical screen height for code/terminals, stacked workspace indicators, and a unified framed desktop feel.

### Visual Principles
- **Restraint over decoration**: Never use loud gradients, neon rainbow borders, pulsing animations, or cluttered widget badges.
- **One accent at a time**: Every theme exposes exactly one primary `accent` (active workspace, active window border, focus ring, OSD progress fill) and semantic colors (`ok`, `warn`, `danger`) reserved strictly for status transitions (charging, low battery, mute, critical alerts).
- **Consistent geometry**: Corner radii, border thickness (`1px`), font metrics, and gaps are derived from the active layout spec and shared across Hyprland, Waybar, Fuzzel, Fnott, and Hyprlock.
- **Compositor-owned blur**: Waybar, Fuzzel, and Fnott render semi-transparent alpha surfaces (`0.84–0.92`), while Hyprland's `layer_rule` applies cheap 1-pass `xray` blur.

## 2. Typography & Iconography

- **Primary Font**: `JetBrainsMono Nerd Font` (Arch package: `ttf-jetbrains-mono-nerd`).
  - Single font family across bar, terminal (`foot`), launcher (`fuzzel`), notifications (`fnott`), and lockscreen (`hyprlock`) eliminates font-fallback jank and minimizes glyph cache RAM.
- **Type Scale**:
  - Top/Side Bar labels: `12.5px` (`600` weight for clock/active pill, `500` for status metrics)
  - Bar icons (Nerd Font monochrome glyphs): `13.5px–14.5px`
  - Terminal (`foot`): `10.5pt`
  - Launcher (`fuzzel`): `11pt`
  - Notifications (`fnott`): Title `10.5pt Bold`, Body `10pt Regular`
  - Lockscreen (`hyprlock`): Clock `68px Bold`, Date `15px Medium`

## 3. The 3 Layouts at a Glance

| Dimension | `noctalia` *(Default)* | `caelestia` | `omarchy` |
|---|---|---|---|
| **Bar position** | Top, floating (`margin: 6 10 0 10`) | Left, vertical (`margin: 8 0 8 8`) | Top, docked flush (`margin: 0`) |
| **Bar thickness** | `34px` pill islands (transparent outer track) | `42px` vertical rail | `28px` flat solid/frosted strip |
| **Bar corner radius** | `14px` per island pill | `14px` unified rail | `0px` (crisp horizontal edge) |
| **Workspaces style** | Horizontal dots; active expands into `24px` accent pill | Vertical dots; active expands into `24px` tall accent pill | Minimal numbered/dot tabs with bottom accent indicator |
| **Window `gaps_in` / `gaps_out`** | `5px` / `10px` | `5px` / `10px` | `4px` / `6px` |
| **Window `rounding`** | `10px` | `12px` | `6px` |
| **Window `border_size`** | `1px` | `1px` | `1px` |
| **Popup (`fuzzel`) radius** | `12px` | `14px` | `8px` |
| **Notification (`fnott`) radius** | `10px` | `12px` | `6px` |
| **Best suited for** | Modern daily driver with balanced airy polish | Coding/reading needing full `1080px` vertical height | Ultra-minimalist keyboard purists & small screens |

Full pixel dimensions, Waybar module layouts, and CSS contracts are defined in [docs/specs/02-layouts.md](docs/specs/02-layouts.md).

## 4. Color Token System

Every theme defines a strict semantic palette (6-char hex without `#`, so Lua emitters can format `#RRGGBB`, `rgba(...)`, or `RRGGBBAA` cleanly):

| Token | Role |
|---|---|
| `bg` | Base desktop / lockscreen / terminal background |
| `bg_alt` | Elevated pill / bar / popup surface |
| `surface` | Hover state, inactive workspace dot, input field fill |
| `border` | Subtle `1px` hairline border & inactive Hyprland window border |
| `fg` | Primary text and crisp icons |
| `fg_muted` | Secondary metadata, inactive workspace labels, timestamps |
| `accent` | Active workspace pill, active window border, selected menu item, OSD bar |
| `accent_fg` | High-contrast text/icon placed on top of `accent` fills |
| `ok` | Connected Wi-Fi / charging battery / healthy status |
| `warn` | Battery ≤ 30% / medium alert |
| `danger` | Battery ≤ 15% / muted audio / destructive power action |

### Built-in Presets
1. **`noctalia` *(default)***: Deep charcoal-slate (`#111318`) with elevated obsidian pills (`#181b22`), soft ice text (`#e6edf7`), and calm sky-indigo accent (`#89b4fa`).
2. **`lavender`**: Catppuccin Mocha / Caelestia-inspired dark indigo (`#11111b` / `#181825`) with lavender accent (`#b4befe`).
3. **`tokyonight`**: Tokyo Night Storm (`#1a1b26` / `#24283b`) with crisp electric blue (`#7aa2f7`).
4. **`carbon`**: Pure Omarchy monochrome matte black (`#0c0c0e` / `#141417`) with stark silver-white accent (`#e4e4e7`).

## 5. Interaction & Ephemeral UI Design

### Command-Palette First (`fuzzel`)
- `Super + Space`: App launcher (centered, max 8 visible lines, icon-enabled, instant fuzzy match).
- `Super + Shift + Space` (or clicking the OS/Logo button on the bar): **`omarch-menu`** — structured Omarchy command menu:
  - `Switch Layout` (`noctalia` / `caelestia` / `omarchy`)
  - `Switch Theme` (`noctalia` / `lavender` / `tokyonight` / `carbon`)
  - `Wi-Fi` / `Bluetooth` / `Audio` / `System Monitor`
  - `Clipboard History` / `Screenshot Region` / `Reload Shell` / `Power Menu`

### Floating TUI Utilities (`omarch-tui`)
Clicking status pills on Waybar (or pressing `Super + Alt + W/B/A`, `Ctrl + Shift + Esc`) spawns a centered floating `footclient` window (`class = om-tui`, `56% × 62%` of monitor) running a native TUI:
- **Network** → `nmtui`
- **Bluetooth** → `bluetui`
- **Audio** → `wiremix`
- **System** → `btop`

Closing the window (`q` or `Esc` or `Super + Q`) returns RAM usage to `0 MiB`.

### Zero-Daemon Progress OSD (`omarch-osd`)
Volume and brightness keys call `omarch-osd`, which adjusts hardware via `wpctl` / `brightnessctl` and sends a synchronous replacing notification to `fnott` (`x-canonical-private-synchronous: omarch-osd` + `int:value:<0..100>`). Fnott renders a native accent-colored progress bar in the top-center/top-right corner for `1.4s` and disappears — **zero extra daemon, zero idle RAM**.

## 6. Motion & Blur Discipline

- **Animations**: Fast, damped cubic-bezier curves (`snappy`: `0.08, 0.9, 0.15, 1.0`, `fastOut`: `0.2, 0.0, 0.0, 1.0`), short durations (`2.0–3.0` Hyprland speed units), no bouncy overshoot.
- **Blur**: 1-pass lightweight `xray` blur (`size = 3`, `passes = 1`) applied to `waybar`, `launcher`, and `notifications` layers; `shadow.enabled = false` to maximize VirGL/iGPU smoothness and battery life.
