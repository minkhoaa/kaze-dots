# Spec 05 — Verification, VM Testing & Benchmark Protocol

## 1. Environment Isolation Rules

All runtime testing, layout verification, screenshot capture, and RAM/CPU benchmarking MUST run exclusively inside an isolated Arch Linux KVM guest (`shell-bench-vm`):

- **VM Directory**: `$KAZE_VM_DIR` (default `~/.local/share/shell-bench-vm/`)
- **Disk**: `arch-bench.qcow2` (copy-on-write overlay on clean Arch base)
- **SSH**: `bench@127.0.0.1:22222` using `$KAZE_VM_DIR/bench_id_ed25519` (passwordless `sudo` inside VM only)
- **Display**: VirGL 3D GPU `-vga none -device virtio-vga-gl,xres=1920,yres=1080` (supports `--dual-monitor` with `max_outputs=2` via `scripts/launch-vm.sh` and low-latency secondary viewer via `scripts/watch-vm-monitor.sh`)
- **Host GPU Pinning**:
  - Headless automated tests: `-display egl-headless,rendernode=/dev/dri/renderD128`
  - Interactive GUI inspection: `__GLX_VENDOR_LIBRARY_NAME=mesa MESA_LOADER_DRIVER_OVERRIDE=iris` with `-display gtk,gl=on,zoom-to-fit=on`
- **Host Main Session**: NEVER touched, reloaded, or modified during development or verification.

## 2. Three-Tier Verification Gates

### Gate 1 — Local Static & Unit Tests (Fast, < 2s; automated in GitHub Actions CI)
Run from the repository root before every VM deployment or commit (and enforced by `.github/workflows/ci.yml`):

```sh
find lua hypr bin tests -type f \( -name '*.lua' -o -path 'bin/kaze-*' \) -print0 | xargs -0 -r -n1 luac -p
lua tests/run.lua
python3 -m unittest tests/vm-idle-test.py
shellcheck scripts/*.sh tests/vm-verify.sh tests/vm-common.sh 2>/dev/null || bash -n scripts/*.sh tests/vm-verify.sh tests/vm-common.sh
```

What Gate 1 covers:
1. **Lua syntax (`luac -p`)**: every `.lua` file and `bin/kaze-*` executable → `0` errors.
2. **Lua unit suite (`lua tests/run.lua`)**:
   - `fs` quoting/atomic writes, `hypr_user` profile + `user.lua` merge/fallback, `json` strict decode/encode, `toml_diff` Noctalia config drift detection.
   - Native config invariants (`config/noctalia/config.toml` offline/zero-telemetry/sharp settings, `foot.ini` Noctalia include, `xdph.conf`, Zsh `conf.d` guards, ANSI-only `starship.toml`, plus live `noctalia config validate`, `foot --check-config`, and `zsh -n` when installed).
   - `scripts/apply.sh` reapply & rollback with spaces in XDG paths, Noctalia GUI edit preservation, and `hypr/user.lua` preservation.
   - `scripts/install.sh`, `scripts/install-packages.sh`, and `scripts/bootstrap.sh` dry-run checks, package manifest parity (`minimal` = 27 pkgs, `full` = 51 pkgs, 0 AUR core), `install-lib.sh` GPU/conflict/system-setup/DM/AUR/logging stubs, root/sh guards, and rollback.
   - `kaze-keys`, `kaze-tui`, `kaze-footclient`, `kaze-session`, `kaze-doctor` (including `--diff`), and `kaze-display` (monitor/workspace parsers, hotplug guards, Present Workspace, 1080p Virtual Share).
3. **Python sampler tests (`tests/vm-idle-test.py`)**: validates process classification, thread stability checks, and budget attribution without requiring a running VM.
4. **Shell checks (`bash -n` / `shellcheck`)**: verifies all scripts in `scripts/` and `tests/`.

### Gate 2 — Clean VM Cold-Boot & Live Session Checks (`tests/vm-verify.sh`)
Inside the isolated Arch KVM guest (`1920×1080`):
1. **Stage & Rollback Fixture**: verifies `pacman -Q` for core packages (`hyprland`, `noctalia`, `foot`, portals, `dconf`), runs `apply.sh --yes` → reapply → `rollback.sh --yes` in an isolated fixture confirming pre-existing files, Noctalia edits, and `hypr/user.lua` survive, then applies to the guest user.
2. **Cold Boot**: powers off and boots cleanly with zero keyboard interaction:
   - `HYPRLAND_INSTANCE_SIGNATURE`, `WAYLAND_DISPLAY`, and `XDG_CURRENT_DESKTOP=Hyprland` match in `systemd --user`.
   - `hyprctl configerrors` is empty; `noctalia config validate` and `foot --check-config` pass.
   - `hyprctl monitors` reports `1920x1080`; `hyprctl layers` contains `namespace: noctalia-bar-*`.
3. **Live Integration Checks**:
   - `kaze-doctor` passes live with `0 FAIL` (including passive portal check and singleton PID counts: `noctalia = 1`, `foot = 1`).
   - `noctalia msg templates-apply` populates `~/.config/hypr/noctalia.lua` and `~/.config/foot/themes/noctalia`.
   - `noctalia msg theme-mode-toggle` toggles Dark ↔ Light cleanly with empty `hyprctl configerrors`.
   - DPMS off → `kaze-session wake-displays` restores `dpmsStatus: true`.
   - Crash recovery: `kill -SEGV` on `kaze-noctalia.service` and `foot-server.service` recovers both units cleanly with new PIDs.
   - `kaze-footclient` waits and propagates exact child exit codes (`37`).
   - `kaze-tui sysmon` opens and toggles a floating `class: kaze-tui` window cleanly.

### Gate 3 — Performance & Resource Budgets (`tests/vm-idle.py`)
`tests/vm-verify.sh` defaults to 3 independent cold boots (`--samples N` overrides; `--functional-only` skips Gate 3). At **T0**, it waits for the Noctalia bar layer and Foot socket, settles for 45s, and samples for 60s **before** running interactive probes or portal checks.

`tests/vm-idle.py` partitions every same-UID process into:
- **Shell stack (`CORE` + `ON_DEMAND`)**: `kaze-noctalia.service` (`noctalia`), `foot-server.service` (`foot`), and on-demand `kaze-record.service` (`wf-recorder`).
- **Session services**: `dconf.service`, `kaze-fcitx5.service`, `xdg-desktop-portal*`, `at-spi-dbus-bus`, `gvfs-daemon`.
- **Outside budget (known)**: `Hyprland`, `start-hyprland`, `Xwayland`, `pipewire*`, `wireplumber`, `systemd`, `dbus-broker*`, `sshd*`.
- **Unclassified**: flagged explicitly so hidden workers are never silently dropped.

| Metric | Measurement Source | T0 Budget ([GOAL.md](../../GOAL.md)) |
|---|---|---|
| **Shell stack PSS** | Sum of `Pss:` from `/proc/<pid>/smaps_rollup` across `kaze-noctalia.service` + `foot-server.service` | **≤ 100 MiB** |
| **Shell + Session PSS** | Shell stack + passive session services | **≤ 105 MiB** |
| **Shell idle CPU** | Delta `utime+stime` from `/proc/<pid>/stat` over elapsed monotonic time | **≤ 0.20%** |
| **Shell context switches** | Per-thread delta of `voluntary+nonvoluntary_ctxt_switches` in `/proc/<pid>/task/*/status` | **≤ 8.0 CS/s** |
| **Early portals** | Live PIDs + current-boot user journal (`SD_MESSAGE_UNIT_STARTING`) without invoking portals | **0** |
| **Resident daemons (`minimal`)** | Singleton main PID per expected core unit | **2** (`noctalia`, `foot`) |

Physical laptop lid-switch sensors and `/sys/class/backlight` hardware behavior remain hardware-only checks outside the VM.

## 3. VM Shutdown Discipline

Every automated VM script MUST power off the guest cleanly and confirm no test QEMU process remains:

```bash
ssh ... bench@127.0.0.1 "sudo poweroff" || true
# Wait until the test VM PID (vm.pid / shell-bench-vm) exits cleanly
```

Never leave a headless QEMU process holding a write lock on `arch-bench.qcow2`, and never signal unrelated host QEMU processes (such as Android Emulator).
