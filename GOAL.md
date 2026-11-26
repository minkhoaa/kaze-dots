# GOAL.md — kaze-dots (Noctalia Shell v5.x Native)

## Mission

Build a crisp, Omarchy-inspired, vertical-first **Hyprland 0.57+ + Noctalia Shell (C++ v5.x)** desktop for Arch Linux / CachyOS that stays minimal, fast, offline-first, and easy to maintain:

- **Native Noctalia for everything Noctalia already owns:** bar layout, themes/palettes, built-in app theming (`hyprland`, `foot`, `gtk3`, `gtk4`, `btop`), wallpaper, launcher (`noctalia dmenu`), Control Center, Settings GUI, notifications, OSD, clipboard history, idle, lockscreen, Night Light, Caffeine, Polkit, screenshots/annotation, and window switcher.
- **Minimal Hyprland + Lua helpers only for what Noctalia does not provide:** Hyprland native Lua config (`hypr/*.lua`), systemd session lifecycle (`kaze-session`), Foot server client (`kaze-footclient`), Hyprland multi-monitor switcher (`kaze-display`), Hyprland keybind cheat-sheet (`kaze-keys`), on-demand floating `btop` TUI (`kaze-tui`), Wayland screen recorder (`kaze-record`), and health checks (`kaze-doctor`).
- **Zero AUR core:** 20 official `[core]`/`[extra]` packages for `minimal` (+14 optional official packages for `full`).

## Resource Budgets (1920×1080, Intel iGPU Arch KVM Guest)

Measured at cold boot (`T0`: 45s settle + 60s sampling via `tests/vm-idle.py --phase T0 --guest-sudo-pss`):

| Metric | Budget | Scope |
| --- | --- | --- |
| **Shell stack PSS** | **≤ 100 MiB** | `kaze-noctalia.service` (`noctalia` with tuned `MALLOC_CONF`) + `foot-server.service` (`foot --server`) |
| **Shell + Session PSS** | **≤ 105 MiB** | Shell stack + passive session services (`dconf-service`) |
| **Idle CPU** | **≤ 0.20%** | Aggregate CPU across shell stack over 60s |
| **Context switches** | **≤ 8.0 CS/s** | Aggregate voluntary + non-voluntary CS/s across shell stack |
| **Early portals** | **0** | No `xdg-desktop-portal*` started before first client request |
| **Telemetry / Network** | **0** | `offline_mode = true`, `telemetry_enabled = false`, `external_ip_enabled = false`, `[weather]`/`[calendar]`/`[system.monitor]`/`[dock]`/`[desktop_widgets]` disabled, `plugins.auto_update = "none"` |
| **Resident daemons (minimal)** | **2** | `noctalia` (1) + `foot --server` (1) |

## Non-Goals

- No custom Lua theme compiler or layout generator duplicating Noctalia Settings GUI.
- No Zen Mode (`kaze-perf`) or custom command menu (`kaze-menu`) duplicating Noctalia Launcher/Control Center.
- No custom screenshot scripts (`grim`/`swappy`) duplicating Noctalia's built-in screenshot/annotation tool.
- No Qt/QML, Electron, GTK4/AGS, wgpu/Iced, Node, or Python desktop runtimes.
