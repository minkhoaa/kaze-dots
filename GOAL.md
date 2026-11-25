# GOAL.md — Vision, Budgets, and Roadmap

## 1. Vision

Build a personal, production-grade **Arch Linux + Hyprland desktop shell configuration (`kaze-dots`)** that resolves the classic Wayland desktop trade-off between **visual polish** and **system efficiency**:

- Rooted in a **personal vertical-first desktop workflow** (`sidebar` default `42px` left rail freeing full vertical screen space), combined with keyboard-driven floating-TUI minimalism and zero-polling native C/C++ rendering (`waybar`, `swaybg`, `fnott`, `fuzzel`, `foot --server`).
- Make **Lua the single control plane** so switching layouts (`sidebar` ↔ `islands` ↔ `slim`) or themes (`kaze` ↔ `lavender` ↔ `tokyonight` ↔ `carbon`) is atomic, instant, and version-controllable.

## 2. Hard Performance & Quality Budgets

All targets are anchored against our isolated Arch Linux KVM VM benchmarks (`1920×1080`, VirGL 3D, zero host noise):

| Metric | Typical Heavy QML Shell | Typical Light QML Bar | **`kaze-dots` Target Budget** | Gate |
|---|---|---|---|---|
| T0 shell stack idle PSS (`1920×1080`) | ~279–344 MiB | ~89 MiB | **≤ 60.0 MiB**, including any portal eagerly activated at login | Hard fail if > 60.0 MiB |
| Bar (`waybar`) idle PSS | N/A | N/A | **≤ 40.0 MiB** | Hard fail if > 40.0 MiB |
| Background idle CPU (120s window) | ~0.0–1.5% | ~0.0% | **≤ 0.20%** | Hard fail if > 0.20% |
| Context switches/sec (all shell threads) | ~0.2–30 CS/s | ~1.0 CS/s | **≤ 5.0 CS/s** | Hard fail if > 5.0 CS/s |
| Host dGPU (NVIDIA) wakeups | High (Vulkan/QML) | Low | **0 MiB VRAM / 0 wakeups** | Hard fail |
| Live layout/theme switch latency | N/A | < 500 ms | **≤ 500 ms** | Target |
| Hyprland `configerrors` count | 0 | 0 | **0 errors** | Hard fail |
| Terminal RAM (5 windows via `footclient`) | ~482 MiB (`kitty`) | ~482 MiB (`kitty`) | **≤ 20 MiB** | Verified (~13.9 MiB) |
| External AUR dependencies (core) | Several | AUR | **0** *(100% Arch `[extra]`)* | Hard fail |

**T0** is a cold login before opening an app, sending a toast, or probing a portal. The strict gate includes any early portal in the 60.0 MiB cap. The development harness can report the exact known GTK3 failure separately, but always enforces a 55.0 MiB shell-only regression guard. Report resource use after notifications (**T1**) and after using portals (**T2**) separately; the 60.0 MiB cap is not a claim about either warm sample. List the Kaze shell, session services, known out-of-budget components, and any unclassified same-UID processes. File picking and screen sharing remain in scope even when they increase memory use.

## 3. Scope Boundaries

### In Scope
- Native **Hyprland `0.57+` Lua** configuration (`hypr/*.lua`) synchronized with active layout & theme.
- **Pure-Lua config compiler (`kaze-sync`)** generating deterministic configs for `waybar`, `foot`, `fuzzel`, `fnott`, and `hyprlock`.
- **3 complete, visually verified layouts**:
  1. `sidebar` *(default)*: Sleek `42px` vertical left rail with vertical workspace pills, icon-only status stack, 2-line clock, and cohesive Hyprland framing.
  2. `islands`: Floating top pill islands with soft corners and subtle frosted glass.
  3. `slim`: Flat `28px` edge-to-edge ultra-minimal top bar.
- **4 curated color presets**: `kaze`, `lavender`, `tokyonight`, `carbon`, plus user override support via `~/.config/kaze/user.lua`.
- **On-demand Lua CLI utilities** for layout/theme, menus, Foot clients, OSD, session lifecycle, clipboard and screenshots; no custom resident helpers.
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

- **M0 — Specification & Documentation** *(Complete)*
  - Complete `AGENTS.md`, `GOAL.md`, `DESIGN.md`, and `docs/specs/01..05`.
- **M1 — Core Lua Engine & Initial Layout** *(Complete)*
  - Implement `lua/kaze/` (schema, themes, initial layout, emitters, atomic writer), `hypr/*.lua`, and `bin/kaze-{sync,tui,osd}`.
- **M2 — Multi-Layout Engine & Interactive Switchers** *(Complete)*
  - Implement all 3 layouts (`sidebar`, `islands`, `slim`) and `kaze-{layout,theme,menu,power}` with live hot-switch verification + `1920×1080` screenshots.
- **M3 — Polish, Edge Cases & Arch Packaging Ergonomics** *(Complete)*
  - Finalize `templates/user.lua.example`, `scripts/install-packages.sh`, `scripts/apply.sh`, rollback script, `scripts/launch-vm.sh`, and `tests/vm-verify.sh`.
- **M4 — Optional Host Adoption**
  - Only upon explicit user approval: apply cleanly to host with reversible backup/rollback.
