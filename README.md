# kaze-dots

Lightweight, keyboard-first dotfiles for **Hyprland 0.57+ (Lua)** + **Noctalia Shell v5.x (C++)** + **Foot** + **Zsh** on Arch Linux / CachyOS.

Built around official Arch `[core]`/`[extra]` packages (**0 AUR at core**, offline, zero-telemetry) with a clean one-command TUI installer, automatic backup/rollback, **11 visual styles**, **16 themes**, **10 curated 4K wallpapers**, and **Noctalia Greeter** styled to match out of the box.

- `main` — current setup powered by **Noctalia Shell v5.x (C++)**
- `legacy-waybar` — previous Waybar / swaybg / Fnott / Fuzzel / Hyprlock setup

## Quick Start

Fresh Arch Linux / CachyOS one-liner (installs `git` if missing, clones cleanly, and launches the interactive TUI installer):

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/minkhoaa/kaze-dots/main/scripts/bootstrap.sh)
```

Or pass flags directly through to `install.sh`:

```sh
# Preview exact packages and actions without writing anything
./scripts/install.sh --profile full --dry-run

# Default installs: Dynamic Island + Kanagawa (4K wallpaper & theme) + noctalia-greeter + yay-bin
./scripts/install.sh --profile minimal --style dynamic-island
./scripts/install.sh --profile full --style dynamic-island

# Customize Display Manager (--dm noctalia|ly|greetd|none) or AUR helper (--aur yay-bin|paru-bin|none)
./scripts/install.sh --profile full --dm ly --aur paru-bin
./scripts/install.sh --profile minimal --dm none --aur none

# Apply dotfiles only (skip pacman, system setup, DM, and AUR helper)
./scripts/install.sh --skip-packages
```

Rollback cleanly to your pre-install snapshot at any time (preserves `~/.config/hypr/user.lua`):

```sh
"$(cat ~/.config/kaze/last-backup)/rollback.sh"
```

## Highlights

- **Compositor & Session:** Hyprland 0.57+ configured natively in Lua (`hypr/*.lua`), systemd user session (`kaze-session.target`), automatic hybrid-GPU `user.lua` seeding, and on-demand XDG portals.
- **Noctalia Shell & Greeter:** Pure C++ shell (`noctalia`, offline/zero-telemetry) plus **`noctalia-greeter`** (via `greetd`, 0 Qt/GTK/Xorg) pre-seeded with the **Kanagawa** theme & 4K wallpaper. Built-in templates live-theme Hyprland, Foot, GTK3/4, and `btop`.
- **11 Visual Presets (`kaze-style` / `Super + Shift + I`):**
  - *Angular & Minimal:* `omarchy-rail`, `swiss-grid`, `corner-hud`, `ghost-zero`
  - *Dynamic & Modern:* `dynamic-island` *(default)*, `hardware-notch`, `glass-studio`, `floating-rail`
  - *Retro & Editorial:* `tui-hacker`, `retro-90s`, `cinema-frame`
- **16 Themes & 10 Curated 4K Wallpapers:** 8 Noctalia built-in themes (default **Kanagawa**) + 8 bundled Version-2 custom palettes (`Kaze-Swiss`, `Kaze-Phosphor`, `Kaze-Amber`, `Kaze-Retro90s`, `Kaze-RosePine`, `Kaze-Everforest`, `Kaze-Monochrome`, `Kaze-Sakura`) + 10 MIT-licensed 4K wallpapers in [assets/wallpapers/](assets/wallpapers/) linked into `~/Pictures/Wallpapers/` (`Super + Shift + W`).
- **Terminal & Shell:** Foot (`foot --server` + live-themed `kaze-footclient`), modular Zsh (`~/.zprofile`, `~/.zshrc`, `conf.d/*.zsh`), and pure-ANSI single-line Starship prompt.
- **Vietnamese IME (`full` profile):** `fcitx5` + `fcitx5-bamboo` (Telex) pre-configured with `Ctrl + Shift` and `Ctrl + Space` toggle and shared input state across apps.
- **Safe Installer:** Syncs via `pacman -Syu --needed`, detects hard/soft package conflicts, configures NetworkManager (without clobbering existing stacks), Bluetooth, PipeWire, `video` group, `fc-cache`, builds **`yay-bin`** after core dotfiles deploy, logs ANSI-clean output to `~/.local/state/kaze/install-*.log`, and verifies with `kaze-doctor --offline`.

## Profiles

| Profile | Official Packages | Included |
| --- | --- | --- |
| `minimal` | 27 core + add-ons | Hyprland, Noctalia, Foot, Zsh (+ plugins), PipeWire/WirePlumber, NetworkManager, BlueZ, `btop`, JetBrainsMono Nerd Font, Lua, XDG portals |
| `full` | 52 core + add-ons | Everything in `minimal` + Thunar, Yazi (Sixel), Zathura, `imv`, `wf-recorder`/`ffmpeg`/`slurp`, `hyprpicker`, `wl-mirror`, `gnome-keyring`, `fcitx5-bamboo`, Noto fonts/emoji, `fzf`, `zoxide`, `eza`, `bat`, `ripgrep`, `fd`, `starship`, `fastfetch` |

*(Default add-ons: `greetd` + `noctalia-greeter` for login screen and `base-devel` + `git` for `yay-bin`; disable with `--dm none --aur none`.)*

## Repo Layout

```text
hypr/                    Hyprland Lua config (env, core, rules, execs, keybinds)
config/noctalia/         Default Noctalia config (Kanagawa, offline, built-in templates) + 8 custom palettes
assets/wallpapers/       10 curated 4K MIT-licensed wallpapers (linked into ~/Pictures/Wallpapers/)
config/foot/             Foot terminal config (includes live Noctalia theme)
config/gtk-3.0/          GTK3 settings (adw-gtk3-dark) & Noctalia CSS for Thunar
config/Thunar/           Thunar custom actions (uca.xml) & keyboard shortcuts (accels.scm)
config/xfce4/            Seeded minimal Thunar xfconf defaults (thunar.xml)
config/yazi/             Yazi config (Foot Sixel previews, ANSI theme, Vim keymap)
config/zathura/          Minimal flat Zathura PDF viewer config
config/imv/              Minimal Wayland imv image viewer config
config/mimeapps.list     Default XDG file associations (thunar, imv, zathura)
config/starship/         Single-line ANSI Starship prompt config
config/fastfetch/        Minimal ANSI-colored Fastfetch system info config
config/zsh/              Modular Zsh config (~/.zprofile, ~/.zshrc, conf.d/*.zsh)
config/systemd/user/     Session target and user service units (Noctalia, Foot, Fcitx5, Recorder)
lua/kaze/                Pure-Lua helper modules (hypr_user, styles, display, projects, mirror, session)
bin/                     11 small Lua helper CLIs for things Noctalia doesn't cover
scripts/                 Bootstrap, TUI installer, apply/rollback, and VM test harness
templates/               Example ~/.config/hypr/user.lua override file
docs/specs/              Architecture, layout presets, theming, CLI/keybinds, and benchmark specs
```

### Helper CLIs (`bin/`)

- `kaze-session` — start/stop `kaze-session.target`, lock screen, wake displays
- `kaze-footclient` — launch `footclient` with live Noctalia theme overrides
- `kaze-style` — switch across 11 Noctalia + Hyprland + GTK3 visual presets
- `kaze-display` — multi-monitor layout picker, HDMI presentation, and Virtual Share 1080p (Meet/Discord)
- `kaze-record` — full/region screen, audio & GIF recording (`wf-recorder` + `ffmpeg`, `noctalia dmenu`)
- `kaze-mirror` — Arch/CachyOS HTTPS mirror ranker & `ParallelDownloads` benchmark (`--tui-window`, `--apply`, `--rollback`)
- `kaze-project` — `zoxide`/`fd` project switcher (Foot shell or Neovim + terminal split)
- `kaze-keys` — searchable Hyprland shortcut list (`noctalia dmenu`)
- `kaze-tui` — toggle floating `btop` window
- `kaze-thunar-action` — Thunar custom actions (`terminal`, `yazi`, `editor`, `copy-path`, `copy-image`, `wallpaper`, tarbomb-safe `extract`, `compress`, `checksum`)
- `kaze-doctor` — health check for binaries, symlinks, configs, portals, services, and config drift (`--diff`)

## Main Keybinds

Press `Super + /` anytime to search all bindings (`kaze-keys`).

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
| `Super + Shift + P` | Display / Present Workspace / Virtual Share (1080p) menu |
| `Ctrl + Super + P` / `Super + Alt + P` | Toggle control on presented workspace / Push-pull window to share |
| `Ctrl + Shift` / `Ctrl + Space` | Toggle Vietnamese IME (`fcitx5-bamboo`, `full` profile) |
| `Ctrl + Shift + Esc` | Floating `btop` |
| `Ctrl + Alt + M` | Mirror Optimizer TUI (`kaze-mirror --tui-window`) |
| `Print` / `Super + Shift + S` / `Super + Shift + Alt + S` | Full / Region / Annotate screenshot |
| `Super + Shift + C` | Color picker (`hyprpicker`) |
| `Ctrl + Alt + R` / `Super + Shift + Alt + R` / `Super + Shift + R` | Full / Region recording / Recording menu (`kaze-record`) |
| `Super + L` / `Ctrl + Alt + Del` | Lock / Session menu |
| `Ctrl + Super + Alt + R` | Reload Noctalia & Hyprland |

## Customization & Maintenance

- **Bar, themes, wallpaper, widgets:** edit directly in Noctalia Settings (`Super + I`) or `~/.config/noctalia/config.toml` — re-running `apply.sh` preserves your edits.
- **Per-machine Hyprland overrides:** edit `~/.config/hypr/user.lua` (see [templates/hypr-user.lua.example](templates/hypr-user.lua.example)) for monitors, default apps, hybrid GPU settings, or disabling `fcitx5`.
- **Per-machine Zsh overrides:** put aliases/env vars in `~/.config/zsh/user.zsh` (login-only tweaks in `~/.config/zsh/zprofile.local`).
- **Diagnostics:** run `kaze-doctor` inside a session or `kaze-doctor --diff` after pulling updates to inspect new Noctalia config sections.

## Credits

- Built around [Noctalia Shell](https://github.com/noctalia-dev) and [Hyprland](https://hypr.land/).
- Bundled 4K wallpapers in [assets/wallpapers/](assets/wallpapers/) are curated from [omacom/omarchy](https://github.com/omacom/omarchy) (MIT License).
