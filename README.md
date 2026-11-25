# kaze-dots

A vertical-first Hyprland desktop for **Arch Linux and CachyOS**. Kaze puts workspaces, status and the clock in a 42 px rail on the left, leaving the height of the screen for your windows. Prefer a top bar? Switch to floating `islands` or a flush `slim` strip without logging out.

Waybar draws the bar, swaybg sets the wallpaper, and Fnott handles notifications. Wi-Fi, Bluetooth and audio controls open in floating Foot terminals. A Lua command, `kaze-sync`, generates the app configs and exits; no Kaze daemon polls in the background.

[Install](#install) · [First session](#first-session) · [Customize](#customize) · [Roll back](#roll-back) · [Documentation](#documentation)

## Install

These dotfiles configure an existing Arch Linux or CachyOS installation. You’ll need Git and `sudo` access for `pacman`. Both profiles use official packages, including Hyprland 0.57+ (native Lua configuration) and Lua 5.5+. No AUR packages are required.

- **`minimal`** (default) includes the desktop, Fuzzel launcher, hypridle and hyprlock, clipboard history, screenshots, external display switching (`kaze-display`), and portals for file picking and screen sharing.
- **`full`** adds screen recording, screenshot annotation, a color picker, Night Light, wallpaper-derived themes, the Yazi file manager, lightweight image/PDF viewers (`imv`, `zathura`), and `gnome-keyring` (D-Bus activated on demand). It also starts a Polkit authentication agent and Fcitx5 with Bamboo Vietnamese input at login.

Log out of your graphical session and use a TTY as your regular user. Keep the clone in place: Kaze links back to it. Preview the package list and destination paths without applying anything:

```bash
git clone https://github.com/minkhoaa/kaze-dots.git
cd kaze-dots
./scripts/install.sh --profile minimal --dry-run
```

If the plan looks right, install the same profile. The [installer](scripts/install.sh) backs up conflicting configs before linking the dotfiles and generating app configs. For the larger profile, use `--profile full` for both the preview and install.

```bash
./scripts/install.sh --profile minimal --no-reboot
```

Already have the packages? `--skip-packages` applies just the dotfiles. Bluetooth media keys (`mpris-proxy`) and USB automounting (`udisks2`) remain user-managed (and `gnome-keyring` is optional for `minimal`).

## First session

Start a fresh Hyprland session from a login TTY, outside any running compositor:

```bash
Hyprland -c "${XDG_CONFIG_HOME:-$HOME/.config}/hypr/hyprland.lua"
```

Press **Super + Return** to open Foot and run `kaze-doctor`. It checks the installed tools, config links, portals, audio and session services. `Super` is usually the Windows key.

| Shortcut | Action |
| --- | --- |
| Tap `Super` or press `Super + Space` | Launch an app with Fuzzel |
| `Super + Shift + Space` | Open the Kaze menu for layouts, themes, displays, system tools and capture |
| `Super + Shift + P` / `XF86Display` | Switch external monitor layout (`kaze-display`) |
| `Super + /` | Search shortcuts by name |
| `Super + 1` … `Super + 0` | Select a workspace (1–10) |
| `Super + V` | Pick from clipboard history |
| `Super + L` | Lock the screen |
| `Ctrl + Alt + Delete` | Open the power menu, including logout |

## Customize

The default layout is `sidebar` and the default palette is `kaze`. Layouts and palettes are independent: for example, try the floating top bar with the monochrome palette. Both choices persist across logins.

```bash
kaze-layout islands
kaze-theme carbon
```

The other built-in palettes are `lavender` and `tokyonight`. To use colors from your own wallpaper, put an image in `~/Pictures/Wallpapers/`, select it with `kaze-wall --menu`, then run `kaze-theme dynamic` (requires `matugen`, included in `full`).

For personal settings, edit **`~/.config/kaze/user.lua`** (under `$XDG_CONFIG_HOME` if set). The installer creates it once from the [commented example](templates/user.lua.example). For a larger cursor and no blur, for instance:

```lua
return {
    cursor_size = 32,
    blur = { enabled = false },
}
```

Run `kaze-sync --check` to validate your changes, then `kaze-sync --reload` to apply them in Kaze. Leave `layout`, `theme` and `wallpaper` unset in `user.lua` if you want to use the switchers. They manage `state.lua` for you; there’s no need to edit it or the generated app configs.

## Roll back

Log out of Kaze first. From a TTY or SSH session as the same user, run the rollback script recorded by the installer:

```bash
backup_dir=$(cat "${XDG_CONFIG_HOME:-$HOME/.config}/kaze/last-backup") &&
    "$backup_dir/rollback.sh"
```

This removes the managed links and generated configs and restores the files they replaced. It preserves `user.lua` and does **not** uninstall packages.

## Footprint

In a [recorded cold login](docs/specs/05-verification-and-benchmarks.md) on the stock Arch VM at 1920×1080, the shell alone used **47.93 MiB PSS** over a 120-second idle sample (CPU rounded to **0.00%**). With session services included, the figure was **85.28 MiB PSS**: GTK3 started the desktop portals when Waybar launched. Neither figure is total system RAM. The stock setup did **not** meet the [60 MiB cold-login budget](GOAL.md).

## Documentation

- [Commands and keyboard shortcuts](docs/specs/04-cli-and-keybinds.md) — the full reference. Run `kaze-keys --list` for a printable shortcut list.
- [Desktop design](DESIGN.md) — the [three layouts](docs/specs/02-layouts.md) and [palette system](docs/specs/03-theming.md).
- [Architecture and installed paths](docs/specs/01-architecture.md) — how the Lua compiler, generated files and systemd user services fit together.
- [Verification and benchmarks](docs/specs/05-verification-and-benchmarks.md) — local checks, VM tests and measured results; see the [implementation checklist](CHECKLIST.md) for progress.
