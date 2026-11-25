# kaze-dots

> An ultra-lightweight, Lua-driven personal Arch Linux + Hyprland desktop shell centered on a **vertical-first left rail (`sidebar`)**, with live-switchable **`islands`** and **`slim`** layouts — rendered by native C/C++ Wayland daemons (`waybar`, `swaybg`, `fnott`, `fuzzel`, `foot --server`).

## Why kaze-dots?

Heavy QML/Qt and GPU-backed Wayland shells routinely consume `90–350 MiB` PSS and wake hybrid dGPUs even at idle. `kaze-dots` uses **Lua as the single source of truth** for configuration, theming, layout compilation, and CLI tooling while delegating runtime rendering exclusively to battle-tested native C/C++ Wayland binaries:

- **~53 MiB historical shell-only baseline** at `1920×1080` before the portal/session-service changes below; see the benchmark notes for what is and isn't included.
- **3 live-switchable layouts** from one Lua config:
  - `sidebar` *(default)* — sleek `42px` vertical left rail with full vertical workspace height & matched frame geometry
  - `islands` — floating top pill islands with crisp frosted glass blur
  - `slim` — flat `28px` ultra-minimal top bar for compact displays
- **4 built-in themes** (`kaze`, `lavender`, `tokyonight`, `carbon`) synced atomically to Hyprland, Waybar, Foot, Fuzzel, Fnott, and Hyprlock
- **Zero polling scripts**: 100% native C++ Waybar modules + Hyprland IPC + on-demand floating TUIs (`nmtui`, `bluetui`, `wiremix`, `btop`)

## Project Documentation

Read these documents in order before implementing or modifying code:

| Document | Purpose |
|---|---|
| [AGENTS.md](AGENTS.md) | Repository rules, commands, boundaries, and verification gates for AI coding agents |
| [GOAL.md](GOAL.md) | Vision, measurable performance/RAM budgets, scope boundaries, and milestone roadmap |
| [DESIGN.md](DESIGN.md) | Visual language, layout geometry, color token system, typography, OSD & TUI UX |
| [docs/specs/01-architecture.md](docs/specs/01-architecture.md) | Lua engine architecture, compile/generate pipeline, runtime process graph |
| [docs/specs/02-layouts.md](docs/specs/02-layouts.md) | Exact specs for `sidebar`, `islands`, and `slim` layouts & hot-switch contract |
| [docs/specs/03-theming.md](docs/specs/03-theming.md) | Theme token schema, built-in palettes, and per-app emitter specifications |
| [docs/specs/04-cli-and-keybinds.md](docs/specs/04-cli-and-keybinds.md) | Lua CLI tools contract (`kaze-*`) and Hyprland keybind matrix |
| [docs/specs/05-verification-and-benchmarks.md](docs/specs/05-verification-and-benchmarks.md) | Clean Arch KVM VM testing workflow, regression gates, and benchmark methodology |

## Quick Start (Arch Linux)

```bash
# 1. Install official Arch [extra] dependencies (0 AUR packages)
./scripts/install-packages.sh

# 2. Back up existing configs, create ~/.config/kaze/user.lua (if absent),
#    symlink kaze-dots, and generate all daemon configs
./scripts/apply.sh
```

- **Start a new Hyprland login** after applying. `kaze-session.target` owns the native daemons and uses Arch's packaged Foot service/socket. Kaze expects one graphical session per user manager; do not run another bar, notification daemon or Foot server alongside it.
- **Customize**: Edit `~/.config/kaze/user.lua` (seeded from [templates/user.lua.example](templates/user.lua.example), never overwritten) and run `kaze-sync --reload` from the active session. Wallpaper and cursor settings update live; the services keep the login's locale, with a UTF-8 fallback only when needed.
- **Switch Layouts / Themes live**: Run `kaze-layout [sidebar|islands|slim|--menu]` or `kaze-theme [kaze|lavender|tokyonight|carbon|--menu]`. New Kaze terminal windows pick up the new palette without restarting the Foot server or touching open shells. `$TERMINAL` (`kaze-footclient` by default) waits for its command unless the caller passes `-N`.
- **Clipboard / screenshots**: `Super+V` opens session history; `kaze-clipboard wipe` clears it. The default history holds at most 100 items of ≤ 2 MiB each. Tagged sensitive content is excluded; passwords from apps that don't mark them can still be stored. `Print` copies the screen, `Super+Shift+S` copies a selected region, and `kaze-screenshot region --save` saves to `Pictures/Screenshots` (using the XDG Pictures location if set).
- **Screen Off**: Use `Ctrl+Alt+Delete` → **Screen Off** to turn off the displays without suspending or immediately locking the session. Press a key or move the mouse to turn the displays back on. Use `Super+L` to lock now; the 300s idle lock and 420s display-off timers still apply. Kaze does not change system-wide sleep or lid policy. To also block systemd suspend requests, an administrator can set `[Sleep]` with `AllowSuspend=no` in `/etc/systemd/sleep.conf.d/90-no-suspend.conf` (see `systemd-sleep.conf(5)`); the installer does not apply this setting.
- **Lock recovery**: If the locker crashes and the screen remains locked, authenticate as the same user on a physical TTY and terminate/restart the affected graphical session. If deliberately recovering that session, target the correct instance from the authenticated TTY using `hyprctl -i <signature> eval 'hl.clear_crashed_lockscreen()'`, then re-lock or log out before leaving it unattended. Kaze never clears a crashed lock automatically.
- **Rollback**: Log out of Kaze, then run `"$(<~/.config/kaze/last-backup)/rollback.sh"` from Bash in a TTY or SSH session (use `$XDG_CONFIG_HOME` if set). Reapplying retains the originals from the active install; it does not restore an intermediate Kaze config. The rollback leaves `user.lua` intact. If an older version already lost the rollback baseline on reapply, look for the originals in the first backup rather than relying on a new apply to infer them.
- **VM Testing**: Run `./tests/vm-verify.sh --functional-only` for login/hot-switch checks or omit the flag for three cold T0 samples. The known GTK3 portal failure is reported as `EXPECTED_UPSTREAM_FAIL`; use `--strict-t0-portal` for the 60 MiB/no-portal acceptance gate. See [Spec 05](docs/specs/05-verification-and-benchmarks.md).

## Measured VM Benchmarks (`1920×1080`, Arch KVM VirGL)

Historical results using the old VM harness: seven freshly (re)started shell processes (`waybar`, `swaybg`, `foot --server`, `fnott`, `hypridle`, `wl-paste` × 2), 10s settle + 10s sampling, before portal packages were added. These are not cold-login acceptance results for the current stack:

| Layout | Waybar Geometry (`x y w h`) | Total PSS | Waybar PSS | Idle CPU | CS/s | Gate 3 |
|---|---|---:|---:|---:|---:|---|
| `sidebar` | `8 8 42 1064` | `52.79 MiB` | `35.93 MiB` | `0.00%` | `0.80` | PASS |
| `islands` | `10 6 1900 34` | `53.03 MiB` | `36.18 MiB` | `0.00%` | `0.30` | PASS |
| `slim` | `0 0 1920 28` | `52.76 MiB` | `35.86 MiB` | `0.00%` | `0.40` | PASS |

> Fresh `fnott` was ~`2.9 MiB` PSS before rendering a toast. The old VM retained ~`66–67 MiB` total after the first toast due to glyph/font caches. The `60.0 MiB` cap is for T0, not warmed samples.

**Current T0 blocker:** The latest 120s cold-login smoke sample with stock Waybar 0.16.0 / GTK3 3.24.52 measured **85.28 MiB PSS** including services (**47.93 MiB** shell only). The sampler now counts AT-SPI and the portal's FUSE worker, which the previous 81.94–82.01 MiB measurements omitted. GTK's Inhibit proxy still activates the portal before a client uses it, so the strict 60 MiB gate fails. In a separate diagnostic using the earlier sampler, preventing only that request reduced PSS to **~53.91 MiB**, with FileChooser and ScreenCast still working. Kaze does not ship that intervention. See [Spec 05](docs/specs/05-verification-and-benchmarks.md).

## Current Status

- **Milestone M0 (Specification & Docs)**: Complete.
- **Milestone M1 (Core Lua Engine & Initial Layout)**: Complete.
- **Milestone M2 (`sidebar`, `islands` & `slim` Layouts, Interactive CLIs, 3×4 Test Matrix)**: Complete.
- **Milestone M3 (Arch Installer, Backup/Rollback, `user.lua`, VM Launcher & Benchmarks)**: Complete.
- **Milestone M4 (Optional Host Adoption)**: Deferred until explicit user approval.
