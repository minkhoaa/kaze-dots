# Spec 01 — Architecture & Runtime Model (Noctalia Shell v5.x Native)

## 1. High-Level Model

`kaze-dots` separates **native C/C++ desktop rendering** from **lightweight Hyprland Lua configuration and on-demand CLI helpers**:

```text
  ~/.config/noctalia/config.toml   (User-editable; managed live via Noctalia Settings GUI)
         │
         ▼  [noctalia (C++ v5.x, kaze-noctalia.service)]
         │   ├─ Bar, Launcher (dmenu), Control Center, Notifications, OSD
         │   ├─ Wallpaper, Idle/DPMS, Lockscreen, Night Light, Caffeine, Polkit, Screenshots
         │   └─ Built-in Theme Templates:
         │        ├─ ~/.config/hypr/noctalia.lua        (required live by hypr/hyprland.lua)
         │        ├─ ~/.config/foot/themes/noctalia     (included by foot.ini & kaze-footclient)
         │        ├─ ~/.config/gtk-{3,4}.0/noctalia.css (imported without waking portals)
         │        └─ ~/.config/btop/themes/noctalia.theme

  ~/.config/hypr/user.lua          (Optional per-machine Hyprland overrides)
         +
  ~/.config/kaze/profile           ("minimal" or "full")
         │
         ▼  [Hyprland 0.57+ native Lua engine: hypr/hyprland.lua]
             ├─ env.lua      (Wayland/toolkit env, UTF-8 locale, optional fcitx5 & hybrid GPU)
             ├─ core.lua     (dwindle, 0px rounding, 2px border, animations, input, 3-finger swipe)
             ├─ rules.lua    (window/workspace rules, smart_gaps, noctalia-no-anim layer rule)
             ├─ execs.lua    (kaze-session start/stop, monitor.added/removed hotplug hooks)
             └─ keybinds.lua (single-source bindings from lua/kaze/keybinds_data.lua)
```

### Key Architectural Invariant
- **Zero persistent Lua, Python, or Node processes run in the background.**
- Lua runs only inside Hyprland 0.57+ during config load/reload and as short-lived CLI commands (`bin/kaze-*`).
- Noctalia runs strictly offline with zero telemetry and zero polling modules (`offline_mode = true`, `telemetry_enabled = false`, `[weather]`/`[calendar]`/`[system.monitor]`/`[dock]`/`[desktop_widgets]` disabled).

## 2. Runtime Process Graph (Steady-State Idle)

In the `minimal` profile, `kaze-session.target` runs **2 resident native daemons**:

| Service / Unit | Process | Role | Notes |
|---|---|---|---|
| `kaze-noctalia.service` | `noctalia` | Native C++ v5.x shell (bar, launcher, notifications, OSD, idle, lock, wallpaper, screenshots, clipboard, Control Center) | Tuned jemalloc (`MALLOC_CONF=background_thread:false,narenas:1,dirty_decay_ms:1000,muzzy_decay_ms:5000,lg_tcache_max:10`) |
| `foot-server.service` + `foot-server.socket` | `foot --server=3` | Shared terminal daemon for instant `kaze-footclient` and `kaze-tui` windows | Uses Arch's packaged unit via systemd drop-ins; never restarted on theme switches |

Optional / on-demand units:
- `kaze-fcitx5.service`: enabled via `ExecCondition` when `profile = "full"` (or `fcitx5 = true` in `user.lua`), running `fcitx5` + `fcitx5-bamboo` (`XMODIFIERS=@im=fcitx`; native Wayland `text-input-v3` preferred without forcing global `GTK_IM_MODULE`/`QT_IM_MODULE`). Seeds `fcitx5/profile` (`keyboard-us` + `bamboo`) and `fcitx5/config` (`Ctrl+Space` & `Ctrl+Shift` toggle, `ShareInputState=All`) when absent. Adds `0 MiB` in `minimal`.
- `kaze-record.service`: on-demand `wf-recorder` unit started/stopped by `bin/kaze-record`, bound to `kaze-session.target` and finalized gracefully with `SIGINT` on logout.
- Portal services (`xdg-desktop-portal`, `xdg-desktop-portal-hyprland`, `xdg-desktop-portal-gtk`): strictly D-Bus-activatable on demand (`0` early portals at `T0`). Hyprland sets `HYPRLAND_NO_SD_VARS=1` so `kaze-session start` exports only the minimal Wayland activation variables (`WAYLAND_DISPLAY`, `XDG_CURRENT_DESKTOP=Hyprland`, `HYPRLAND_INSTANCE_SIGNATURE`) to `systemd --user` / D-Bus.

## 3. Configuration Resolution & Ownership

1. **Noctalia Shell (`~/.config/noctalia/config.toml`)**:
   - Seeded once as an editable copy from `config/noctalia/config.toml` on first `scripts/apply.sh`.
   - User edits made via Noctalia Settings GUI (`Super + I`) or directly in TOML are preserved across `apply.sh` re-runs.
   - Run `kaze-doctor --diff` after updating the repo to inspect any newly added upstream sections, keys, or bar widgets.
2. **Hyprland Settings (`lua/kaze/hypr_user.lua`)**:
   - Deep-merges built-in defaults → `~/.config/kaze/profile` → optional `~/.config/hypr/user.lua` (loaded in an isolated environment via `loadfile(..., "t", {})` with `pcall` fallback so syntax errors never break Hyprland startup).
   - Runtime display overrides (from `kaze-display`) are persisted per session in `$XDG_RUNTIME_DIR/kaze/monitors.lua` and re-applied on `hyprctl reload`.
3. **Zsh & Daily-Driver Apps (`config/zsh/`, `config/starship/`, `config/yazi/`, `config/zathura/`, `config/imv/`, `config/mimeapps.list`)**:
   - Modular `conf.d/*.zsh` (`10-options`, `20-completion`, `30-keybinds`, `40-tools`, `50-aliases`, `60-prompt`) with guarded optional tool integration (`fzf`, `zoxide`, `eza`, `bat`, `ripgrep`, `fd`, `starship`).
   - Personal machine overrides live in `~/.config/zsh/user.zsh` and `~/.config/zsh/zprofile.local` (never overwritten by `apply.sh`).
   - Omarchy-sharp flat configs for `yazi` (Foot Sixel previews, ANSI theme, Vim keymap), `zathura`, `imv`, `mimeapps.list`, and `applications/yazi.desktop`.

## 4. Module Boundaries

```text
lua/kaze/
├── capture.lua        # Output/region geometry & XDG target path helpers for kaze-record
├── display.lua        # Pure-Lua monitor/workspace parser, hl.monitor planner, hotplug guards
├── fs.lua             # Atomic writes (.tmp -> os.rename), mkdir_p, shell_quote, UTF-8 locale
├── hypr_user.lua      # Defaults + ~/.config/kaze/profile + safe ~/.config/hypr/user.lua loader
├── json.lua           # Strict pure-Lua JSON decoder (UTF-16 surrogates) & deterministic encoder
├── keybinds_data.lua  # Single pure-Lua shortcut registry shared by hypr/keybinds.lua & kaze-keys
├── mirror.lua         # Pure-Lua pacman.conf parser, saturation math (Q1..Q4, B1/B4), validators
├── mirror_tui.lua     # Pure-Lua 5-screen Omarchy ANSI TUI & sudo TTY handoff adapter
├── popups.lua         # Shared `noctalia dmenu` picker wrapper
├── projects.lua       # Pure-Lua zoxide/fd project discovery & launch command builder
├── session.lua        # kaze-session.target lifecycle, session.env renderer, lock/DPMS helpers
├── styles.lua         # Pure-Lua Noctalia v5 visual preset definitions & surgical TOML updater
├── theme_hub_tui.lua  # Pure-Lua 2-column visual Theme Hub with TrueColor illustrations & live preview
├── toml_diff.lua      # Pure-Lua Noctalia config.toml section/key/widget drift checker
└── utility.lua        # Shared systemd user unit query/start/stop helpers
```

## 5. Installation & Symlink Map

`scripts/apply.sh` backs up any overwritten pre-existing files into `$XDG_CONFIG_HOME/.kaze-backup-<timestamp>/`, writes a manifest (`installed.list`, `backed_up.list`) and a reversible `rollback.sh`, and updates `$XDG_CONFIG_HOME/kaze/last-backup`.

| Target Path | Source / Type |
|---|---|
| `$XDG_DATA_HOME/kaze-dots/lua/kaze` | Symlink → `<repo>/lua/kaze` |
| `$XDG_DATA_HOME/applications/yazi.desktop` | Symlink → `<repo>/config/applications/yazi.desktop` |
| `$XDG_CONFIG_HOME/hypr/{hyprland,env,core,rules,execs,keybinds}.lua` | Symlink → `<repo>/hypr/*.lua` |
| `$XDG_CONFIG_HOME/hypr/xdph.conf` | Symlink → `<repo>/config/hypr/xdph.conf` |
| `$XDG_CONFIG_HOME/hypr/user.lua` | Seeded once from `templates/hypr-user.lua.example` (auto-seeding `drm_devices` + `prefer_mesa_egl` on hybrid laptops when absent); never overwritten or deleted on rollback |
| `$XDG_CONFIG_HOME/noctalia/config.toml` | Seeded editable file from `config/noctalia/config.toml`; preserved across re-applies |
| `$XDG_CONFIG_HOME/noctalia/palettes/*.json` | Symlinks → `<repo>/config/noctalia/palettes/*.json` (8 Version-2 custom palettes) |
| `~/Pictures/Wallpapers/*.jpg` | Symlinks → `<repo>/assets/wallpapers/*.jpg` (10 bundled 4K MIT-licensed wallpapers; user-owned wallpapers preserved) |
| `$XDG_CONFIG_HOME/foot/foot.ini` | Symlink → `<repo>/config/foot/foot.ini` |
| `$XDG_CONFIG_HOME/foot/themes/noctalia` | Empty placeholder created on first apply (plus symlink at `~/.config/foot/themes/noctalia` when `XDG_CONFIG_HOME` is customized); populated live by Noctalia's `foot` template |
| `$XDG_CONFIG_HOME/gtk-3.0/{settings.ini,kaze-thunar.css,gtk.css,noctalia.css,kaze-style.css}` | Symlinks + managed `gtk.css` imports and preset CSS overlay for GTK3/Thunar |
| `$XDG_CONFIG_HOME/Thunar/{uca.xml,accels.scm}` & `$XDG_CONFIG_HOME/xfce4/xfconf/xfce-perchannel-xml/thunar.xml` | Symlinked custom actions (`uca.xml`) + editable seeded shortcuts & xfconf defaults |
| `$XDG_CONFIG_HOME/starship.toml` | Symlink → `<repo>/config/starship/starship.toml` |
| `$XDG_CONFIG_HOME/fastfetch/config.jsonc` | Symlink → `<repo>/config/fastfetch/config.jsonc` |
| `$XDG_CONFIG_HOME/yazi/{yazi,theme,keymap}.toml` | Symlinks → `<repo>/config/yazi/*.toml` |
| `$XDG_CONFIG_HOME/zathura/zathurarc` | Symlink → `<repo>/config/zathura/zathurarc` |
| `$XDG_CONFIG_HOME/imv/config` | Symlink → `<repo>/config/imv/config` |
| `$XDG_CONFIG_HOME/mimeapps.list` | Symlink → `<repo>/config/mimeapps.list` |
| `$XDG_CONFIG_HOME/xdg-terminals.list` | Symlink → `<repo>/config/xdg-terminals.list` |
| `$XDG_CONFIG_HOME/{chrome,chromium,brave,microsoft-edge-stable}-flags.conf`, `vivaldi-stable.conf` | Symlinks → `<repo>/config/browsers/chromium-flags.conf` (comment-free `ParallelDownloading` + `QUIC`) |
| `~/.zshrc`, `~/.zprofile`, `$XDG_CONFIG_HOME/zsh/conf.d` | Symlinks → `<repo>/config/zsh/{zshrc,zprofile,conf.d}` |
| `$XDG_CONFIG_HOME/systemd/user/` | Symlinks → `<repo>/config/systemd/user/` units and `foot-server` drop-ins |
| `~/.local/bin/kaze-*` | Symlinks → `<repo>/bin/kaze-*` (11 helper CLIs) |
| `$XDG_CONFIG_HOME/kaze/{profile,style,saved-theme.json}` | Active profile (`minimal`/`full`), active visual preset (11 presets, default `dynamic-island`), and saved `[theme]` for palette-locked presets |
| `$XDG_STATE_HOME/kaze/install-*.log` | ANSI-stripped installation logs written by `scripts/install.sh` |
| `$XDG_RUNTIME_DIR/kaze/` | Private (`0700`) per-session runtime state (`session.env`, `display-state.json`, `monitors.lua`, `record.*`) |
