# DESIGN.md — Visual Language & Interaction System

## 1. Design Philosophy

`kaze-dots` is built around three personal design pillars:

1. **Vertical-First Ergonomics (`sidebar`, default)**: A sleek `42px` vertical left rail frees 100% of vertical screen height for code and terminals, with stacked workspace pills and unified Hyprland canvas framing.
2. **Calm Minimalism**: Restrained surfaces, crisp typography, keyboard-driven navigation, and ephemeral floating TUI utilities instead of bloated always-resident settings windows.
3. **Flexible Framing (`islands` & `slim`)**: Switchable between floating top pill islands (`islands`) with subtle `1px` hairline borders and frosted translucency, or a flush `28px` minimal strip (`slim`) when maximum simplicity is preferred.

### Visual Principles
- **Restraint over decoration**: Never use loud gradients, neon rainbow borders, pulsing animations, or cluttered widget badges.
- **One accent at a time**: Every theme exposes exactly one primary `accent` (active workspace, active window border, focus ring, OSD progress fill) and semantic colors (`ok`, `warn`, `danger`) reserved strictly for status transitions (charging, low battery, mute, critical alerts).
- **Consistent geometry**: Sharp rectangular `0px` corners (`border-radius: 0`, `rounding = 0`) paired with crisp `2px` frame borders (`border_size = 2`), consistent font metrics, and unified gaps derived from the active layout spec across Hyprland, Waybar, Fuzzel, Fnott, Hyprlock, and TUI widgets.
- **Compositor-owned blur**: Waybar, Fuzzel, and Fnott render semi-transparent alpha surfaces (`0.92–0.96`), while Hyprland's `layer_rule` applies cheap 1-pass `xray` blur.

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

| Dimension | `sidebar` *(Default)* | `islands` | `slim` |
|---|---|---|---|
| **Bar position** | Left, vertical (`margin: 8 0 8 8`) | Top, floating blocks (`margin: 6 10 0 10`) | Top, docked flush (`margin: 0`) |
| **Bar thickness** | `42px` vertical rail | `34px` modular top bar | `28px` flat solid/frosted strip |
| **Bar corner radius** | `0px` sharp rail (`2px` border) | `0px` sharp modules (`2px` border) | `0px` crisp edge (`2px` bottom border) |
| **Workspaces style** | Square `8px` blocks; active expands to `8×24px` bar | Square `8px` blocks; active expands to `24×8px` bar | Minimal numbered tabs with bottom accent indicator |
| **Window `gaps_in` / `gaps_out`** | `4px` / `8px` | `5px` / `10px` | `4px` / `6px` |
| **Window `rounding`** | `0px` | `0px` | `0px` |
| **Window `border_size`** | `2px` | `2px` | `2px` |
| **Popup (`fuzzel`) radius** | `0px` (`2px` border) | `0px` (`2px` border) | `0px` (`2px` border) |
| **Notification (`fnott`) radius** | `0px` (`2px` border) | `0px` (`2px` border) | `0px` (`2px` border) |
| **Best suited for** | Coding/reading needing full `1080px` vertical height | Balanced airy desktop with floating pill islands | Ultra-minimalist keyboard purists & compact displays |

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
1. **`kaze` *(default)***: Deep charcoal-slate (`#111318`) with elevated obsidian surfaces (`#181b22`), soft ice text (`#e6edf7`), and calm sky-indigo accent (`#89b4fa`).
2. **`lavender`**: Deep indigo (`#11111b` / `#181825`) with soft lavender accent (`#b4befe`).
3. **`tokyonight`**: Tokyo Night Storm (`#1a1b26` / `#24283b`) with crisp electric blue (`#7aa2f7`).
4. **`carbon`**: Monochrome matte black (`#0c0c0e` / `#141417`) with stark silver-white accent (`#e4e4e7`).
5. **`paper`**: Warm ivory light (`#f7f6f2` / `#efede7`) with crisp dark-ink text (`#1c1e24`) and cobalt-blue accent (`#2563eb`).

## 5. Interaction & Ephemeral UI Design

### Command-Palette First (`fuzzel`)
- `Super + Space`: App launcher (centered, max 8 visible lines, icon-enabled, instant fuzzy match).
- `Super + Shift + Space` (or clicking the OS/Logo button on the bar): **`kaze-menu`** — structured Kaze command palette:
  - `Switch Layout` (`sidebar` / `islands` / `slim`)
  - `Switch Theme` (`kaze` / `lavender` / `tokyonight` / `carbon` / `paper`)
  - `Wi-Fi` / `Bluetooth` / `Audio` / `System Monitor`
  - `Clipboard History` / `Screenshot Region` / `Reload Shell` / `Power Menu`

### Floating TUI Utilities (`kaze-tui`)
Clicking status pills on Waybar (or pressing `Super + Alt + W/B/A`, `Ctrl + Shift + Esc`) spawns a centered floating `footclient` window (`class = kaze-tui`, `56% × 62%` of monitor) running a native TUI:
- **Network** → `nmtui`
- **Bluetooth** → `bluetui`
- **Audio** → `wiremix`
- **System** → `btop`

Closing the window (`q` or `Esc` or `Super + Q`) returns RAM usage to `0 MiB`.

### Zero-Daemon Progress OSD (`kaze-osd`)
Volume and brightness keys call `kaze-osd`, which adjusts hardware via `wpctl` / `brightnessctl` and sends a synchronous replacing notification to `fnott` (`x-canonical-private-synchronous: kaze-osd` + `int:value:<0..100>`). Fnott renders a native accent-colored progress bar in the top-right corner for `1.4s` and disappears — **zero extra daemon, zero idle RAM**.

## 6. Motion & Blur Discipline

- **Animations**: Fast, damped cubic-bezier curves (`snappy`: `0.08, 0.9, 0.15, 1.0`, `fastOut`: `0.2, 0.0, 0.0, 1.0`), short durations (`2.0–3.0` Hyprland speed units), no bouncy overshoot.
- **Blur**: 1-pass lightweight `xray` blur (`size = 3`, `passes = 1`) applied to `waybar`, `launcher`, and `notifications` layers; `shadow.enabled = false` to maximize VirGL/iGPU smoothness and battery life.
