# GOAL.md — Vision, Budgets, and Roadmap

## 1. Vision

Build a personal, production-grade **Arch Linux + Hyprland desktop shell configuration (`kaze-dots`)** that resolves the classic Wayland desktop trade-off between **visual polish** and **system efficiency**:

- Take the **discipline, cleanliness, keyboard-first ergonomics, and floating-TUI minimalism of Omarchy**.
- Rebuild the **visual layout flexibility of Noctalia (floating pill islands) and Caelestia (vertical left sidebar)** directly on top of **Waybar (C++/GTK3) + `dnkl` Pure-C Wayland tools**.
- Make **Lua the single control plane** so switching layouts (`noctalia` ↔ `caelestia` ↔ `omarchy`) or themes (`noctalia` ↔ `lavender` ↔ `tokyonight` ↔ `carbon`) is atomic, instant, and version-controllable.

## 2. Hard Performance & Quality Budgets

All targets are anchored against our isolated Arch Linux KVM VM benchmarks (`1920×1080`, VirGL 3D, zero host noise):

| Metric | Reference: Caelestia Stock | Reference: Noctalia v5.6 | **`kaze-dots` Target Budget** | Gate |
|---|---|---|---|---|
| Total shell stack idle PSS (`1920×1080`) | ~279–344 MiB | ~89 MiB | **≤ 60 MiB** *(target ~52–56 MiB)* | Hard fail if > 65 MiB |
| Bar (`waybar`) idle PSS | N/A | N/A | **≤ 40 MiB** | Warn if > 38 MiB |
| Background idle CPU (10s window) | ~0.0–1.5% | ~0.0% | **0.0% (`≤ 0.2%`)** | Hard fail if > 0.5% |
| Context switches/sec (idle) | ~0.2–30 CS/s | ~1.0 CS/s | **≤ 5 CS/s** | Warn if > 10 CS/s |
| Host dGPU (NVIDIA) wakeups | High (Vulkan/QML) | Low | **0 MiB VRAM / 0 wakeups** | Hard fail |
| Live layout/theme switch latency | N/A | < 500 ms | **≤ 500 ms** | Target |
| Hyprland `configerrors` count | 0 | 0 | **0 errors** | Hard fail |
| Terminal RAM (5 windows via `footclient`) | ~482 MiB (`kitty`) | ~482 MiB (`kitty`) | **≤ 20 MiB** | Verified (~13.9 MiB) |
| External AUR dependencies (core) | Several | CachyOS/AUR | **0** *(100% Arch `[extra]`)* | Hard fail |

## 3. Scope Boundaries

### In Scope
- Native **Hyprland `0.57+` Lua** configuration (`hypr/*.lua`) synchronized with active layout & theme.
- **Pure-Lua config compiler (`kaze-sync`)** generating deterministic configs for `waybar`, `foot`, `fuzzel`, `fnott`, and `hyprlock`.
- **3 complete, visually verified layouts**:
  1. `noctalia` *(default)*: Floating top pill/island bar with soft corners and subtle frosted glass.
  2. `caelestia`: Sleek `42px` vertical left sidebar with vertical workspace pills, rotated/stacked status modules, and cohesive Hyprland framing.
  3. `omarchy`: Flat `28px` edge-to-edge ultra-minimal top bar.
- **4 curated color presets**: `noctalia`, `lavender`, `tokyonight`, `carbon`, plus user override support via `~/.config/kaze/user.lua`.
- **Lua CLI utilities**: `kaze-sync`, `kaze-layout`, `kaze-theme`, `kaze-menu`, `kaze-power`, `kaze-tui`, `kaze-osd`.
- **On-demand floating TUIs** (`nmtui`, `bluetui`, `wiremix`, `btop`) via `footclient` (`0 MiB` when closed).
- **Progress-bar OSD** (volume & brightness) powered by `fnott` + `notify-send` (`0 MiB` extra daemon cost).
- **Clean Arch installer & symlink manager** (`scripts/install-packages.sh`, `scripts/apply.sh`) and clean Arch KVM VM test harness.

### Explicit Out of Scope (Non-Goals)
- **No custom Rust/C++/QML GUI renderer**: Waybar C++ is the chosen bar renderer; we will not rewrite a Wayland bar/compositor from scratch.
- **No heavy always-resident Control Center / Dashboard daemon** (no Quickshell, AGS/GTK4, Eww, or Electron widgets).
- **No automatic host system modification** (`sudo`, `/etc`, display manager configs, kernel parameters) without explicit user opt-in.
- **No X11 support**: Wayland + Hyprland only.
- **No multi-distro package abstraction** beyond Arch Linux / CachyOS `pacman`.

## 4. Milestone Roadmap

- **M0 — Specification & Documentation** *(Current)*
  - Repository initialized in `/home/khoa/Projects/kaze-dots`.
  - Complete `AGENTS.md`, `GOAL.md`, `DESIGN.md`, and `docs/specs/01..05`.
- **M1 — Core Lua Engine & Default `noctalia` Layout**
  - Implement `lua/kaze/` (schema, themes, `noctalia` layout, emitters, atomic writer).
  - Implement `hypr/*.lua` and `bin/kaze-sync`, `bin/kaze-tui`, `bin/kaze-osd`.
  - Pass `luac -p`, unit tests, and VM verification (`1920×1080` screenshot + PSS/CPU check).
- **M2 — Multi-Layout Engine (`caelestia` + `omarchy`) & Interactive Switchers**
  - Implement `caelestia` (vertical left sidebar) and `omarchy` (flat top bar) layouts.
  - Implement `kaze-layout`, `kaze-theme`, `kaze-menu`, `kaze-power`.
  - Verify live hot-switching across all 3 layouts × 4 themes inside VM and capture `1920×1080` screenshots of every layout.
- **M3 — Polish, Edge Cases & Arch Packaging Ergonomics**
  - Verify tray icons, MPRIS media pill, Fnott OSD progress bars, Hyprlock styling, multi-monitor fallback, and user override (`~/.config/kaze/user.lua`).
  - Finalize `scripts/install-packages.sh`, `scripts/apply.sh`, rollback script, and VM benchmark report.
- **M4 — Optional Host Adoption**
  - Only upon explicit user approval: apply cleanly to host with reversible backup/rollback.
