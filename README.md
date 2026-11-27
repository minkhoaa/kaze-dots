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
config/noctalia/         Default Noctalia config (sharp/flat, offline, built-in templates) + 8 custom palettes
assets/wallpapers/       10 curated 4K MIT-licensed wallpapers (linked into ~/Pictures/Wallpapers/)
config/foot/             Foot terminal config (includes Noctalia theme)
config/gtk-3.0/          GTK3 settings (adw-gtk3-dark) & sharp Noctalia CSS for Thunar
config/Thunar/           Thunar custom actions (uca.xml) & keyboard shortcuts (accels.scm)
config/xfce4/            Seeded fast/minimal Thunar xfconf defaults (thunar.xml)
config/yazi/             Yazi config (Foot Sixel previews, ANSI theme, Vim keymap)
config/zathura/          Minimal flat Zathura PDF viewer config
config/imv/              Minimal Wayland imv image viewer config
config/mimeapps.list     Default XDG file associations (thunar, imv, zathura)
config/starship/         Minimal single-line ANSI Starship prompt config
config/zsh/              Modular Zsh config (~/.zprofile, ~/.zshrc, conf.d/*.zsh)
config/systemd/user/     Session target and user service units
lua/kaze/                Small Lua helpers (hypr_user, keybinds_data, projects, popups, session, styles)
bin/                     11 small helper CLIs for things Noctalia doesn't cover
scripts/                 Install, apply, backup/rollback, and VM test helpers
templates/               Example ~/.config/hypr/user.lua override file
```

### Helper CLIs (`bin/`)

- `kaze-session` — start/stop session, lock screen, wake displays
- `kaze-footclient` — launch `footclient` with live Noctalia theme colors
- `kaze-display` — Hyprland multi-monitor layout picker (`noctalia dmenu`)
- `kaze-keys` — searchable Hyprland shortcut list (`noctalia dmenu`)
- `kaze-project` — `zoxide`/`fd` project switcher (`noctalia dmenu`, Foot shell / Neovim split)
- `kaze-style` — switch across 11 Noctalia + Hyprland + GTK3 visual presets (`omarchy-rail`, `swiss-grid`, `corner-hud`, `ghost-zero`, `dynamic-island`, `hardware-notch`, `glass-studio`, `floating-rail`, `tui-hacker`, `retro-90s`, `cinema-frame`)
- `kaze-tui` — toggle floating `btop` window
- `kaze-record` — full/region screen, audio & GIF recording (`wf-recorder` + `ffmpeg`, `noctalia dmenu`)
- `kaze-doctor` — quick health check for packages, symlinks, configs, services, and Noctalia config drift (`--diff`)
- `kaze-mirror` — Arch/CachyOS HTTPS mirror ranker & `ParallelDownloads` benchmark (`--dry-run`, `--apply`, `--bench`, `--rollback`)
- `kaze-thunar-action` — Thunar custom-action helper (`terminal`, `yazi`, `editor`, `copy-path`, `copy-image`, `wallpaper`, tarbomb-safe `extract`, `compress`, `checksum`)

## Setup

Fresh Arch Linux / CachyOS one-liner (clones `kaze-dots` safely, installs `git` via `pacman -Syu --needed` if needed, and launches the interactive TUI installer):

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/minkhoaa/kaze-dots/main/scripts/bootstrap.sh)
# Or pass flags straight through to install.sh:
bash <(curl -fsSL https://raw.githubusercontent.com/minkhoaa/kaze-dots/main/scripts/bootstrap.sh) --profile full --dm ly
```

Preview first without touching anything:

```sh
./scripts/install.sh --profile minimal --dry-run
```

Install packages (`pacman -Syu --needed`), configure system services (NetworkManager if no other stack is active, Bluetooth, PipeWire user sockets, `video` group, font cache), enable **`noctalia-greeter` (via `greetd`)** styled with Kanagawa theme + bundled 4K Kanagawa wallpaper by default (0 AUR at core, 0 Qt/GTK, preserves any existing DM such as SDDM/GDM; pass `--dm ly`, `--dm greetd` for `tuigreet`, or `--dm none` for TTY1), install **`yay-bin`** after the core desktop deploy (pass `--aur paru-bin` or `--aur none` to opt out), set Zsh as default login shell, choose a visual preset (11 presets across Angular, Dynamic, and Retro groups; default `dynamic-island`), and apply configs (backs up existing dotfiles automatically and logs to `~/.local/state/kaze/install-*.log`):

```sh
./scripts/install.sh --profile minimal --style dynamic-island   # default 3-island top bar + Noctalia Greeter + yay
./scripts/install.sh --profile full --style dynamic-island      # full profile + Dynamic Island + Noctalia Greeter + yay
./scripts/install.sh --profile full --dm ly --aur paru-bin      # switch DM to ly & AUR helper to paru
./scripts/install.sh --profile minimal --dm none --aur none     # plain TTY1 auto-start with 0 AUR helper
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
| `Super + O` / `Super + Shift + O` | Project switcher (`zoxide`/`fd`) / Neovim + terminal split |
| `Super + Shift + Z` | Focus / Game Mode (0 animations/blur/gaps + DND) |
| `Super + A` / `Super + N` | Control Center / Notifications |
| `Super + I` / `Super + Shift + I` | Noctalia Settings / Visual style switcher (`kaze-style`) |
| `Super + Shift + T` | Toggle Dark / Light mode |
| `Super + Shift + W` | Wallpaper picker |
| `Super + V` | Clipboard history |
| `Super + /` | Search keybinds |
| `Super + Shift + P` | Display / Present Workspace / Virtual Share (Meet/Discord 1080p) menu |
| `Ctrl + Super + P` | Toggle control presented workspace on laptop |
| `Super + Alt + P` | Push/pull focused window to shared workspace |
| `Ctrl + Shift + Esc` | Floating `btop` |
| `Ctrl + Alt + M` | Mirror Optimizer TUI (`kaze-mirror --tui-window`) |
| `Print` / `Super + Shift + S` / `Super + Shift + Alt + S` | Full / Region / Annotate screenshot |
| `Super + Shift + C` | Pick color (`hyprpicker`) |
| `Ctrl + Alt + R` / `Super + Shift + Alt + R` / `Super + Shift + R` | Full / Region recording / Recording menu (`kaze-record`) |
| `Super + L` / `Ctrl + Alt + Del` | Lock / Session menu |
| `Ctrl + Super + Alt + R` | Reload Noctalia & Hyprland |

## Notes

- Run `kaze-doctor` inside a session if something looks off, or `kaze-doctor --diff` after updating the repo to see newly added sections/widgets in `config/noctalia/config.toml`.
- Personal setup tuned for my own workflow — feel free to fork or borrow parts, just review configs before applying blindly.
