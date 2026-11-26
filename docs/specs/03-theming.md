# Spec 03 — Theming Pipeline (Noctalia Built-in Templates)

## 1. Single Source of Truth

`kaze-dots` does **not** maintain a custom Lua theme compiler or palette emitter. **Noctalia Shell v5.x's native template engine** (`[theme.templates] enable_builtin_templates = true`) is the sole color source across the desktop.

Default theme seed in [config/noctalia/config.toml](../../config/noctalia/config.toml):
- `mode = "dark"` (instant Dark/Light toggle via `Super + Shift + T` → `noctalia msg theme-mode-toggle`)
- `source = "builtin"`, `builtin = "Tokyo-Night"` (users can switch to any built-in theme or wallpaper-derived `m3-content` palette inside Noctalia Settings `Super + I`)
- `sync_color_scheme = true` (syncs `prefer-dark` / `prefer-light` natively)
- `enable_community_templates = false` (strictly offline, built-in templates only)

## 2. Built-in App Theming Matrix

| Target App | Template ID | Generated Output | How `kaze-dots` Integrates It |
|---|---|---|---|
| **Hyprland** | `hyprland` | `~/.config/hypr/noctalia.lua` | Loaded dynamically by [hypr/hyprland.lua](../../hypr/hyprland.lua) via `pcall(require, "noctalia")` and `noctalia_theme.apply_theme()`. Fallback Tokyo-Night borders live in `hypr/core.lua` before the first template run. State borders in `hypr/rules.lua` read `noc_colors.error` (pinned) and `noc_colors.secondary` (fullscreen). |
| **Foot** | `foot` | `~/.config/foot/themes/noctalia` | Static `include=~/.config/foot/themes/noctalia` in [config/foot/foot.ini](../../config/foot/foot.ini) (seeded empty on first apply so `foot --check-config` always passes), plus live per-window `-o` overrides passed by [bin/kaze-footclient](../../bin/kaze-footclient) so open `foot --server` sessions stay intact while new windows pick up theme changes immediately. |
| **GTK 3 / 4** | `gtk3`, `gtk4` | `~/.config/gtk-{3,4}.0/noctalia.css` | Managed natively by Noctalia templates without triggering early portal startup. |
| **btop** | `btop` | `~/.config/btop/themes/noctalia.theme` | Auto-configured and live-reloaded (`SIGUSR2`) when opened via `Ctrl + Shift + Esc` (`kaze-tui sysmon`). |

## 3. Terminal Prompt & Shell Palette Alignment

- [config/starship/starship.toml](../../config/starship/starship.toml) uses **ANSI named colors only** (zero hardcoded `#RRGGBB` hex values), verified by `tests/run.lua`.
- Because Starship and Zsh (`config/zsh/`) inherit the terminal's 16-color ANSI palette from Foot, switching themes or toggling Dark/Light mode in Noctalia automatically harmonizes the shell prompt and CLI tools (`eza`, `bat`, `fzf`, `btop`) with zero extra config generation.
