# DESIGN.md — kaze-dots Visual & Architectural Decisions

## Aesthetic Direction (Omarchy-Inspired Flat Geometry)

- **Sharp corners everywhere:** `corner_radius_scale = 0.0` in Noctalia (`radius = 0` on bar, notifications, OSD, Control Center cards, and buttons) and `rounding = 0` in Hyprland.
- **Crisp borders, zero drop shadows:** `2px` solid borders (`border_width = 2.0`, `outline_variant` in Noctalia; `border_size = 2` in Hyprland), `shadow = false`, `popup_shadows = false`.
- **Vertical-first default sidebar:** Left `42px` floating rail (`margin_edge = 8`, `margin_ends = 8`, `background_opacity = 0.94`, `compositor_blur = true`) with Launcher + Workspaces at top, stacked 24h vertical clock (`%H\n%M`) in center, and Tray/Network/Volume/Battery/Notifications/Control Center/Session at bottom.
- **Native customization:** Users customize bar position (left/top/bottom), themes, wallpaper palettes, dark/light mode, and widgets directly in **Noctalia Settings (`Super + I`)** or `~/.config/noctalia/config.toml` — edits are preserved across `apply.sh` re-runs.

## Native App Theming Pipeline

Noctalia's built-in template engine (`[theme.templates] enable_builtin_templates = true`) is the single source of truth for colors across the desktop:

| App | Template ID | Output | Integration |
| --- | --- | --- | --- |
| **Hyprland** | `hyprland` | `~/.config/hypr/noctalia.lua` | Loaded automatically by `hypr/hyprland.lua` via `pcall(require, "noctalia")` |
| **Foot** | `foot` | `~/.config/foot/themes/noctalia` | Included by `config/foot/foot.ini` and passed live per-window by `kaze-footclient` |
| **GTK 3 / 4** | `gtk3`, `gtk4` | `~/.config/gtk-{3,4}.0/noctalia.css` | Imported cleanly into `gtk.css` without triggering early portals |
| **btop** | `btop` | `~/.config/btop/themes/noctalia.theme` | Auto-configured and live-reloaded (`SIGUSR2`) |

## Memory & Idle Tuning

- `kaze-noctalia.service` sets `MALLOC_CONF=background_thread:false,narenas:1,dirty_decay_ms:1000,muzzy_decay_ms:5000,lg_tcache_max:10` so jemalloc uses a single arena (saving ~6–12 MiB PSS) with zero background decay thread wakeups at idle.
- Heavy background modules (`[weather]`, `[calendar]`, `[system.monitor]`, `[dock]`, `[desktop_widgets]`) stay disabled by default; on-demand system metrics open as a floating `btop` drawer (`Ctrl + Shift + Esc` → `kaze-tui sysmon`).
