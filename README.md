# kaze-dots

My personal dotfiles for **Hyprland 0.57+ (Lua)** + **Noctalia Shell (v5.x)** + **Foot** on Arch Linux / CachyOS.

Built around official Arch `[extra]` packages (no AUR needed for the core setup) and keeping everything Noctalia already ships native instead of rewriting it.

- `main` — current setup powered by **Noctalia Shell v5.x**
- `legacy-waybar` — previous Waybar / swaybg / Fnott / Fuzzel / Hyprlock setup

## Stack

- **Compositor:** Hyprland 0.57+ configured in Lua (`hypr/*.lua`)
- **Shell:** Noctalia (`noctalia`) — bar, themes & wallpaper palettes, built-in templates (`hyprland`, `foot`, `gtk3`, `gtk4`, `btop`), launcher, Control Center, notifications, OSD, clipboard, idle/DPMS, lockscreen, Night Light, Polkit, screenshots, and window switcher
- **Terminal:** Foot (`foot --server` + `footclient`)
- **Login shell:** Zsh (`config/zsh/{zshrc,zprofile}` + `conf.d/*.zsh` with Arch `[extra]` plugins, and optional `starship` prompt)
- **Session:** systemd user units (`kaze-session.target`, `kaze-noctalia.service`, `foot-server`)

## Repo Layout

```text
hypr/                    Hyprland Lua config (env, rules, keybinds, execs)
config/noctalia/         Default Noctalia config (sharp/flat, offline, built-in templates)
config/foot/             Foot terminal config (includes Noctalia theme)
config/starship/         Minimal single-line ANSI Starship prompt config
config/zsh/              Modular Zsh config (~/.zprofile, ~/.zshrc, conf.d/*.zsh)
config/systemd/user/     Session target and user service units
lua/kaze/                Small Lua helpers (hypr_user, keybinds_data, popups, session, json)
bin/                     7 small helper CLIs for things Noctalia doesn't cover
scripts/                 Install, apply, backup/rollback, and VM test helpers
templates/               Example ~/.config/hypr/user.lua override file
```

### Helper CLIs (`bin/`)

- `kaze-session` — start/stop session, lock screen, wake displays
- `kaze-footclient` — launch `footclient` with live Noctalia theme colors
- `kaze-display` — Hyprland multi-monitor layout picker (`noctalia dmenu`)
- `kaze-keys` — searchable Hyprland shortcut list (`noctalia dmenu`)
- `kaze-tui` — toggle floating `btop` window
- `kaze-record` — full/region screen recording (`wf-recorder`)
- `kaze-doctor` — quick health check for packages, symlinks, configs, services, and Noctalia config drift (`--diff`)

## Setup

Preview first without touching anything:

```sh
./scripts/install.sh --profile minimal --dry-run
```

Install packages, set Zsh as default login shell, and apply configs (backs up existing dotfiles automatically):

```sh
./scripts/install.sh --profile minimal   # core setup (24 packages)
./scripts/install.sh --profile full      # adds recording, color picker, wl-mirror, yazi, imv, zathura, fcitx5, starship, and CLI tools
```

Apply dotfiles only (if packages are already installed):

```sh
./scripts/install.sh --skip-packages
```

Rollback to the previous backup:

```sh
"$(cat ~/.config/kaze/last-backup)/rollback.sh"
```

## Customization

- **Bar, themes, wallpaper, widgets:** edit directly in Noctalia Settings (`Super + I`) or `~/.config/noctalia/config.toml` — re-running `apply.sh` preserves your edits.
- **Per-machine Hyprland overrides:** edit `~/.config/hypr/user.lua` (see [templates/hypr-user.lua.example](templates/hypr-user.lua.example)) for monitors, default apps, gaps, or personal tweaks.
- **Per-machine Zsh overrides:** put custom aliases, env vars, or prompt tweaks in `~/.config/zsh/user.zsh` (and login-only tweaks in `~/.config/zsh/zprofile.local`).

## Main Keybinds

Press `Super + /` anytime to search the full list (`kaze-keys`).

| Keybind | Action |
| --- | --- |
| `Super` (tap) / `Super + Space` | App launcher |
| `Super + Return` / `Super + T` | Terminal (`foot`) |
| `Super + A` / `Super + N` | Control Center / Notifications |
| `Super + I` | Noctalia Settings |
| `Super + Shift + T` | Toggle Dark / Light mode |
| `Super + Shift + W` | Wallpaper picker |
| `Super + V` | Clipboard history |
| `Super + /` | Search keybinds |
| `Super + Shift + P` | Display / Present Workspace / Virtual Share (Meet/Discord 1080p) menu |
| `Ctrl + Super + P` | Toggle control presented workspace on laptop |
| `Super + Alt + P` | Push/pull focused window to shared workspace |
| `Ctrl + Shift + Esc` | Floating `btop` |
| `Print` / `Super + Shift + S` / `Super + Shift + Alt + S` | Full / Region / Annotate screenshot |
| `Super + Shift + C` | Pick color (`hyprpicker`) |
| `Ctrl + Alt + R` / `Super + Shift + Alt + R` | Full / Region screen recording |
| `Super + L` / `Ctrl + Alt + Del` | Lock / Session menu |
| `Ctrl + Super + Alt + R` | Reload Noctalia & Hyprland |

## Notes

- Run `kaze-doctor` inside a session if something looks off, or `kaze-doctor --diff` after updating the repo to see newly added sections/widgets in `config/noctalia/config.toml`.
- Personal setup tuned for my own workflow — feel free to fork or borrow parts, just review configs before applying blindly.
