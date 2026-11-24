# Spec 05 — Verification, VM Testing & Benchmark Protocol

## 1. Environment Isolation Rules

All runtime testing, layout verification, screenshot capture, and RAM/CPU benchmarking MUST run exclusively inside the isolated Arch Linux KVM VM (`shell-bench-vm`):

- **VM Directory**: `/home/khoa/.local/share/shell-bench-vm/`
- **Disk**: `arch-bench.qcow2` (copy-on-write overlay on clean Arch base)
- **SSH**: `bench@127.0.0.1:22222` using `/home/khoa/.local/share/shell-bench-vm/bench_id_ed25519` (passwordless `sudo` inside VM only)
- **Display**: Single unified VirGL 3D GPU `-vga none -device virtio-vga-gl,xres=1920,yres=1080`
- **Host GPU Pinning**:
  - Headless automated tests: `-display egl-headless,rendernode=/dev/dri/renderD128`
  - Interactive GUI inspection: `__GLX_VENDOR_LIBRARY_NAME=mesa MESA_LOADER_DRIVER_OVERRIDE=iris` with `-display gtk,gl=on,zoom-to-fit=on`
- **Host Main Session**: NEVER touched, reloaded, or modified during development or verification.

## 2. Three-Tier Verification Gates

### Gate 1 — Local Static & Unit Tests (Fast, < 2s)
Run on host before every VM deployment or commit:
1. **Lua syntax check**: `luac -p` on every `.lua` file and `bin/omarch-*` executable → **0 errors**.
2. **Pure-Lua test suite (`lua tests/run.lua`)**:
   - Validates all 4 theme palettes (`themes.validate`).
   - Runs every emitter across the full **3 layouts × 4 themes = 12 combinations** and asserts non-empty output, balanced braces, valid JSON structure (for `config.jsonc`), and zero unresolved template placeholders.
   - Verifies `user.lua` merge precedence and graceful fallback on malformed user files.
3. **Shell script check**: `bash -n scripts/*.sh` (and `shellcheck` if installed).

### Gate 2 — Clean VM Cold-Boot & Live Hot-Switch Checks
Inside `shell-bench-vm` (`1920×1080`):
1. **Deploy**: Sync repo via `rsync` over SSH into `/home/bench/omarch-shell` and run `./scripts/apply.sh --yes`.
2. **Cold-Boot Check**: Reboot/cold-boot VM with zero keyboard interaction:
   - Boots to SSH in `< 15s` with **0 UEFI `failed to load`** lines.
   - `tty1` auto-starts `Hyprland -c ~/.config/hypr/hyprland.lua`.
   - `hyprctl configerrors` returns **empty**.
   - `hyprctl monitors` shows `1920x1080`.
   - `hyprctl layers` contains `wallpaper` (`swaybg`) and `waybar`.
3. **3-Layout Hot-Switch Verification**:
   For each layout in `{ noctalia, caelestia, omarchy }`:
   - Execute `omarch-layout <layout>` inside the Hyprland session.
   - Assert exit code `0` and `hyprctl configerrors` empty.
   - Assert Waybar layer geometry matches spec:
     - `noctalia`: top bar `h=34`, `y=6`, `w=1900` (`1920 - 2*10`).
     - `caelestia`: left bar `w=42`, `x=8`, `h=1064` (`1080 - 2*8`).
     - `omarchy`: top bar `h=28`, `x=0, y=0, w=1920`.
   - Capture real `1920×1080` screenshot via `grim` and visually inspect it (no clipped text, no broken Nerd Font icons, no overlapping borders, clean contrast).
4. **Interactive Feature Checks**:
   - Spawn `omarch-tui sysmon` → verify floating centered `om-tui` window in `hyprctl clients`, then close cleanly.
   - Trigger `omarch-osd vol-up` → verify `fnott` stays alive and exits `0`.
   - Switch theme across all 4 presets (`noctalia`, `lavender`, `tokyonight`, `carbon`) → verify exit `0` and updated `colors.css`.

### Gate 3 — Performance & Resource Regression Budgets
Measure steady-state idle telemetry inside the VM (after 10s settle window, 10s sampling interval) across all shell daemons (`waybar`, `swaybg`, `foot`, `fnott`, `hypridle`, `wl-paste`):

| Metric | Measurement Source | Pass Threshold |
|---|---|---|
| Total Stack PSS (`1920×1080`) | Sum of `Pss:` from `/proc/<pid>/smaps_rollup` | **≤ 60.0 MiB** |
| `waybar` PSS | `/proc/<waybar_pid>/smaps_rollup` | **≤ 40.0 MiB** |
| Total Idle CPU % | Delta `utime+stime` from `/proc/<pid>/stat` over 10s | **≤ 0.20%** |
| Total Context Switches/s | Delta `voluntary+nonvoluntary_ctxt_switches` from `/proc/<pid>/status` over 10s | **≤ 5.0 CS/s** |
| Resident Daemon Count | Exact set `{waybar, swaybg, foot, fnott, hypridle, wl-paste×2}` | No orphan/duplicate daemons |

## 3. VM Shutdown Discipline

Every automated VM test script MUST finish with:
```bash
ssh ... bench@127.0.0.1 "sudo poweroff" || true
# Wait until pgrep -x qemu-system-x86 returns empty
```
Never leave a headless QEMU process holding a write lock on `arch-bench.qcow2` after a verification run.
