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
Live Reload (hyprctl reload + restart waybar + restart fnott; ~250–400ms total)
```

### Key Architectural Invariant
**Zero persistent Lua processes run in the background.** Lua runs in only two places:
1. Embedded inside **Hyprland `0.57+`** when loading/reloading `~/.config/hypr/hyprland.lua`.
2. Short-lived **CLI invocations** (`kaze-sync`, `kaze-layout`, `kaze-theme`, `kaze-menu`, `kaze-power`, `kaze-tui`, `kaze-osd`) that complete in milliseconds and exit.

## 2. Runtime Process Graph (Steady-State Idle)

Only 6 lightweight native daemons remain resident in memory:

| Daemon | Role | Language | Expected Idle PSS (`1920×1080`) |
|---|---|---|---|
| `waybar` | Top or vertical side bar (`noctalia` / `caelestia` / `omarchy`) | C++ / GTK3 | ~36–39 MiB |
| `swaybg` | Static wallpaper rendering | Pure C | ~6.3 MiB |
| `foot --server` | Shared terminal daemon for instant `footclient` & `kaze-tui` windows | Pure C | ~4.9 MiB |
| `fnott` | Notification daemon + progress OSD renderer | Pure C | ~3.0 MiB |
| `hypridle` | Idle timeout & DPMS/lock automation | C++ | ~2.0 MiB |
| `wl-paste` (×2) | Event-driven text & image clipboard watcher into `cliphist` | Pure C | ~0.5 MiB |
| **Total** | **Full desktop shell stack** | **Native C/C++** | **~53–56 MiB (Budget ≤ 60 MiB)** |

Ephemeral processes (`fuzzel`, `hyprlock`, `grim`, `slurp`, `footclient`, `nmtui`, `bluetui`, `wiremix`, `btop`) consume **`0 MiB`** when closed.

## 3. Configuration Resolution Order

`lua/kaze/config.lua` resolves effective configuration deterministically by deep-merging tables in strict priority order:

1. **Built-in Defaults** (`lua/kaze/defaults.lua`):
   - `layout = "noctalia"`
   - `theme = "noctalia"`
   - `font = "JetBrainsMono Nerd Font"`
   - `terminal = "footclient"`
   - `browser = "firefox"` (auto-fallback if unset)
   - `files = "footclient -e yazi"` (or `thunar` if present)
   - `wallpaper = "~/Pictures/Wallpapers/wallpaper.png"`
   - `cursor_theme = "Adwaita"`, `cursor_size = 24`
   - `vol_step = 5`, `vol_max = 1.5`, `bright_step = 5`
   - `blur = { enabled = true, size = 3, passes = 1, xray = true }`
   - `shadow = false`
   - `opacity = { active = 0.96, inactive = 0.92 }`
2. **Active Persisted State** (`~/.config/kaze/state.lua`):
   - Written by `kaze-layout` and `kaze-theme`.
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
│   ├── init.lua        # Layout registry & validator ("noctalia", "caelestia", "omarchy")
│   ├── noctalia.lua    # Noctalia floating pill layout geometry + Waybar JSONC/CSS builders
│   ├── caelestia.lua   # Caelestia 42px left vertical sidebar geometry + Waybar JSONC/CSS builders
│   └── omarchy.lua     # Omarchy 28px flat top bar geometry + Waybar JSONC/CSS builders
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

`scripts/apply.sh` deploys non-destructively (backing up existing configs to `~/.config/.kaze-backup-<timestamp>/`):

| Target Path | Source / Type |
|---|---|
| `~/.local/share/kaze-dots/lua/kaze` | Symlink → `<repo>/lua/kaze` |
| `~/.config/hypr/{hyprland,core,env,rules,execs,keybinds}.lua` | Symlink → `<repo>/hypr/*.lua` |
| `~/.config/hypr/hypridle.conf` | Symlink → `<repo>/templates/hypridle.conf` |
| `~/.local/bin/kaze-*` | Symlink → `<repo>/bin/kaze-*` |
| `~/.config/waybar/{config.jsonc,style.css,colors.css}` | Generated by `kaze-sync` |
| `~/.config/foot/foot.ini` | Generated by `kaze-sync` |
| `~/.config/fuzzel/fuzzel.ini` | Generated by `kaze-sync` |
| `~/.config/fnott/fnott.ini` | Generated by `kaze-sync` |
| `~/.config/hypr/hyprlock.conf` | Generated by `kaze-sync` |
| `~/.config/kaze/state.lua` | Managed by `kaze-layout` / `kaze-theme` |
| `~/.config/kaze/user.lua` | Created once from template if absent; never overwritten |

## 6. Pure-Lua Path Resolution

Both `hypr/hyprland.lua` and `bin/kaze-*` prepend `~/.local/share/kaze-dots/lua/?.lua;~/.local/share/kaze-dots/lua/?/init.lua` (plus `<repo>/lua/` when invoked directly from the repo during testing) to `package.path`. This keeps all modules cleanly importable via `require("kaze.config")` with zero environment variable hacks.
