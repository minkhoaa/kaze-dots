# Spec 01 — Architecture & Lua Control Plane

## 1. High-Level Model

`kaze-dots` strictly separates **configuration & generation (Lua)** from **runtime rendering (native C/C++ Wayland daemons)**:

```text
  User Overrides (~/.config/kaze/user.lua)
         +
  Active State (~/.config/kaze/state.lua: layout, theme)
         +
  Built-in Presets (lua/kaze/defaults.lua, themes.lua, layouts/*.lua)
         │
         ▼  [kaze-sync (pure Lua 5.5, runs on boot & live switches, exits immediately)]
         │
   ┌─────┴──────────────────────────────────────────────────────────────┐
   │  Atomic Config Emitters (write .tmp -> os.rename)                  │
   ├──────────────────────────┬──────────────────────┬──────────────────┤
   ▼                          ▼                      ▼                  ▼
~/.config/waybar/       ~/.config/foot/       ~/.config/fuzzel/   ~/.config/fnott/
 - config.jsonc          - foot.ini            - fuzzel.ini        - fnott.ini
 - style.css                                                      ~/.config/hypr/
 - colors.css                                                      - hyprlock.conf
   │                                                               - (hyprland.lua reads
   │                                                                  state + presets live!)
   ▼
Live Reload (validate staging, reload Hyprland, refresh appearance, restart affected services, then commit state)
```

### Key Architectural Invariant
**Zero persistent Lua processes run in the background.** Lua runs in only two places:
1. Embedded inside **Hyprland `0.57+`** when loading/reloading `~/.config/hypr/hyprland.lua`.
2. On-demand **CLI invocations**, including session hooks (`kaze-session`) and watcher callbacks (`kaze-clipboard store`). There are no background Lua loops. The live compiler waits for Waybar readiness only while a switch is in progress.

## 2. Runtime Process Graph (Steady-State Idle)

The Kaze shell starts seven native processes in six roles. `kaze-session.target` pulls in `graphical-session.target` and owns their lifecycle (`PartOf=`). Before starting the target, the bootstrap renders configs, clears stale session clipboard history, and imports only `WAYLAND_DISPLAY`, `XDG_CURRENT_DESKTOP` and `HYPRLAND_INSTANCE_SIGNATURE` to D-Bus/systemd. Live reload stages `session.env` with the generated configs, retaining the login's locale. Changes restart swaybg only if the effective image path or fallback color changes; cursor changes are applied to the compositor. Logout stops the target before dispatching compositor exit. Portal services remain D-Bus-activatable. On the tested stock Arch packages, GTK3 requests portal activation on Waybar startup despite Kaze not starting a portal unit explicitly; see [Spec 05](05-verification-and-benchmarks.md).

Shell-only estimates from the previous VM baseline:

| Daemon | Role | Language | Expected Idle PSS (`1920×1080`) |
|---|---|---|---|
| `waybar` | Vertical left rail or top bar (`sidebar` / `islands` / `slim`) | C++ / GTK3 | ~36–39 MiB |
| `swaybg` | Static wallpaper rendering | Pure C | ~6.3 MiB |
| `foot --server` | Shared terminal daemon for instant `footclient` & `kaze-tui` windows | Pure C | ~4.9 MiB |
| `fnott` | Notification daemon + progress OSD renderer | Pure C | ~3.0 MiB |
| `hypridle` | Idle timeout & DPMS/lock automation | C++ | ~2.0 MiB |
| `wl-paste` (×2) | Event-driven text & image clipboard watcher into `cliphist` | Pure C | ~0.5 MiB |
| **Total** | **Full desktop shell stack** | **Native C/C++** | **~53–56 MiB (Budget ≤ 60 MiB)** |

Ephemeral processes (`fuzzel`, `hyprlock`, `grim`, `slurp`, `swappy`, `hyprpicker`, `footclient`, `nmtui`, `bluetui`, `wiremix`, `btop`) consume **`0 MiB`** when closed. Recording, Night Light and Caffeine are on-demand systemd user services, not target startup dependencies. Their `PartOf`, `Requisite` and `After` relationships bind them to the login. Logout first waits for the recorder's bounded `SIGINT` stop, then stops the session target. No Lua helper stays resident for these features.

## 3. Configuration Resolution Order

`lua/kaze/config.lua` resolves effective configuration deterministically by deep-merging tables in strict priority order:

1. **Built-in Defaults** (`lua/kaze/defaults.lua`):
   - `layout = "sidebar"`
   - `theme = "kaze"`
   - `font = "JetBrainsMono Nerd Font"`
   - `terminal = "kaze-footclient"` uses the packaged Foot server with per-window overrides from the generated `foot.ini`.
   - `browser = "firefox"`
   - `files = "kaze-footclient -e yazi"` (shows an installation/configuration hint if Yazi is missing)
   - `wallpaper = "~/Pictures/Wallpapers/wallpaper.png"`
   - `cursor_theme = "Adwaita"`, `cursor_size = 24`
   - `vol_step = 5`, `vol_max = 1.5`, `bright_step = 5`
   - `night_temp = 4500` K (on-demand `hyprsunset`; applied on next start)
   - `blur = { enabled = true, size = 3, passes = 1, xray = true }`
   - `shadow = false`
   - `opacity = { active = 0.96, inactive = 0.92 }`
2. **Active Persisted State** (`~/.config/kaze/state.lua`):
   - Committed by `kaze-sync` after successful layout/theme changes. The transaction holds `$XDG_RUNTIME_DIR/kaze/sync.lock`, stages and snapshots files, and uses a compositor-instance-local candidate state until reload succeeds. On failure it restores the previous files and reloads the previous configuration.
   - Contains only `{ layout = "...", theme = "..." }` so switching layout/theme never clobbers the user's manual overrides.
3. **User Overrides** (`~/.config/kaze/user.lua`, optional):
   - User-owned Lua table returning overrides (e.g., custom `wallpaper`, `font`, `kb_layout`, `monitors`, or custom `theme_overrides`).
   - Loaded safely via `pcall(dofile, ...)` — syntax errors log to `stderr` and fall back gracefully to defaults instead of breaking Hyprland startup.
4. **Layout Spec Overlay** (`lua/kaze/layouts/<layout>.lua`):
   - Supplies geometry defaults (`gaps_in`, `gaps_out`, `rounding`, `border_size`, `bar_*`, `fuzzel_radius`, `fnott_radius`) unless explicitly pinned by `user.lua`.

## 4. Planned Module Boundaries

```text
lua/kaze/
├── defaults.lua        # Base default configuration table
├── themes.lua          # Built-in color palettes + hex/rgba conversion helpers
├── layouts/
│   ├── init.lua        # Layout registry & validator ("sidebar", "islands", "slim")
│   ├── sidebar.lua     # 42px left vertical sidebar geometry + Waybar JSONC/CSS builders
│   ├── islands.lua     # Floating top pill islands geometry + Waybar JSONC/CSS builders
│   └── slim.lua        # 28px flat minimal top bar geometry + Waybar JSONC/CSS builders
├── config.lua          # Deep-merge loader (defaults -> state -> user -> layout)
├── state.lua           # Read/write ~/.config/kaze/state.lua atomically
├── fs.lua              # Atomic file write (.tmp -> os.rename), mkdir -p, shell_quote
├── emit_waybar.lua     # Pure emitter: (cfg, theme, layout) -> { config_jsonc, style_css, colors_css }
├── emit_foot.lua       # Pure emitter: (cfg, theme, layout) -> foot.ini
├── emit_fuzzel.lua     # Pure emitter: (cfg, theme, layout) -> fuzzel.ini
├── emit_fnott.lua      # Pure emitter: (cfg, theme, layout) -> fnott.ini
└── emit_hyprlock.lua   # Pure emitter: (cfg, theme, layout) -> hyprlock.conf
```

## 5. Installation & Symlink Map

`scripts/apply.sh` backs up existing configs to `~/.config/.kaze-backup-<timestamp>/`. Reapplying carries forward the active install's original files and tracks both existing and new Kaze paths. Run the rollback recorded in `kaze/last-backup` (under `$XDG_CONFIG_HOME`); `user.lua` is preserved.

| Target Path | Source / Type |
|---|---|
| `~/.local/share/kaze-dots/lua/kaze` | Symlink → `<repo>/lua/kaze` |
| `~/.config/hypr/{hyprland,core,env,rules,execs,keybinds}.lua` | Symlink → `<repo>/hypr/*.lua` |
| `~/.config/hypr/hypridle.conf` | Symlink → `<repo>/templates/hypridle.conf` |
| `~/.local/bin/kaze-*` | Symlink → `<repo>/bin/kaze-*` |
| `$XDG_CONFIG_HOME/systemd/user/` | Kaze units (including recorder, Night Light and Caffeine) and drop-ins for packaged `foot-server` and `fnott` |
| `$XDG_DATA_HOME/dbus-1/services/org.freedesktop.Notifications.service` | Activation routes to the same `fnott.service`, not a second daemon |
| `$XDG_RUNTIME_DIR/kaze/` | Private per-user runtime storage for the active session, including `cliphist.db` (default) |
| `~/.config/waybar/{config.jsonc,style.css,colors.css}` | Generated by `kaze-sync` |
| `~/.config/foot/foot.ini` | Generated by `kaze-sync` |
| `~/.config/fuzzel/fuzzel.ini` | Generated by `kaze-sync` |
| `~/.config/fnott/fnott.ini` | Generated by `kaze-sync` |
| `~/.config/hypr/hyprlock.conf` | Generated by `kaze-sync` |
| `~/.config/kaze/state.lua` | Managed by `kaze-sync` on behalf of `kaze-layout` and `kaze-theme` |
| `~/.config/kaze/user.lua` | Created once from template if absent; never overwritten |

## 6. Pure-Lua Path Resolution

Both `hypr/hyprland.lua` and `bin/kaze-*` prepend `~/.local/share/kaze-dots/lua/?.lua;~/.local/share/kaze-dots/lua/?/init.lua` (plus `<repo>/lua/` when invoked directly from the repo during testing) to `package.path`. This keeps all modules cleanly importable via `require("kaze.config")` with zero environment variable hacks.
