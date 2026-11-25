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
1. **Lua syntax check**: `luac -p` on every `.lua` file and `bin/kaze-*` executable → **0 errors**.
2. **Pure-Lua test suite (`lua tests/run.lua`)**:
   - Validates all 4 theme palettes (`themes.validate`).
   - Runs every emitter across the full **3 layouts × 4 themes = 12 combinations** and asserts non-empty output, balanced braces, valid JSON structure (for `config.jsonc`), and zero unresolved template placeholders.
   - Verifies `user.lua` merge precedence and graceful fallback on malformed user files.
3. **Shell script check**: `bash -n` on each shell script (and `shellcheck` if installed).
4. **Sampler tests**: `python3 -B tests/vm-idle-test.py` checks the known-failure handling and process attribution without a running VM.

### Gate 2 — Clean VM Cold-Boot & Live Hot-Switch Checks
Inside `shell-bench-vm` (`1920×1080`):
1. **Deploy**: Install the official dependencies in the guest. `tests/vm-verify.sh` deploys via `tar` over SSH and applies from SSH while tty1 is stopped. It tests rollback with isolated XDG paths and preserves the guest's `user.lua`.
2. **Cold-Boot Check**: Power off after staging and cold-boot the deployed VM with zero keyboard interaction (also with `--functional-only`):
   - Boots to SSH in `< 20s` with **0 UEFI `failed to load`** lines. The pre-deploy staging time is reported separately.
   - `tty1` auto-starts `Hyprland -c ~/.config/hypr/hyprland.lua`.
   - `hyprctl configerrors` returns **empty**.
   - `hyprctl monitors` shows `1920x1080`.
   - `hyprctl layers` contains `wallpaper` (`swaybg`) and `waybar`.
3. **3-Layout Hot-Switch Verification**:
   For each layout in `{ sidebar, islands, slim }`:
   - Execute `kaze-layout <layout>` inside the Hyprland session.
   - Assert exit code `0` and `hyprctl configerrors` empty.
   - Assert Waybar layer geometry matches spec:
     - `sidebar`: left bar `w=42`, `x=8`, `h=1064` (`1080 - 2*8`).
     - `islands`: top bar `h=34`, `y=6`, `w=1900` (`1920 - 2*10`).
     - `slim`: top bar `h=28`, `x=0, y=0, w=1920`.
   - Capture real `1920×1080` screenshot via `grim` and visually inspect it (no clipped text, no broken Nerd Font icons, no overlapping borders, clean contrast).
4. **Interactive Feature Checks**:
   - Spawn `kaze-tui sysmon` → verify floating centered `kaze-tui` window in `hyprctl clients`, then close cleanly.
   - Trigger `kaze-osd vol-up` → verify `fnott` stays alive and exits `0`.
   - Switch theme across all 4 presets (`kaze`, `lavender`, `tokyonight`, `carbon`); verify the Foot server PID did not change.
   - Exercise Waybar/Foot crash recovery, Foot waiting and returning the child exit status, tagged and oversized clipboard offers, PNG clipboard restore, screen capture, live wallpaper/cursor and display-off reloads, logind and Wayland lock confirmation, and login after compositor exit.
   - Exercise **Screen Off** from the power menu. Check that DPMS goes off while the guest keeps running, then turns back on with keyboard and mouse input. Kaze does not request suspend.
   - The automated portal probe reads Settings, opens a GTK file chooser and verifies the ScreenCast interface. A full PipeWire stream, interactive cancellation, and physical lid/backlight checks are separate acceptance tests.

### Gate 3 — Performance & Resource Regression Budgets
`tests/vm-verify.sh` defaults to 3 independent cold boots of the deployed image. For **T0**, it waits for Waybar and wallpaper layers and the Foot socket, then settles for 45s and measures for 120s **before** layout changes, test toasts or portal probes. The old 10s settle caught short-lived swaybg image loaders and daemon threads as they exited. `--functional-only` skips Gate 3; `--samples 1` is a smoke measurement, not full acceptance.

`tests/vm-idle.py` lists same-UID PIDs with their systemd service/scope and separate shell, session, known out-of-budget, and unclassified subtotals. Inspect and attribute any unclassified cost before interpreting desktop usage; it is not silently dropped. Workers nested under a known service count with that service. The sampler rejects changes to shell/session PID or thread sets across the measurement endpoints and warns about churn in the other groups. The VM harness opts into passwordless guest sudo only for PSS reads denied to the session user (for example, the portal's nondumpable FUSE worker). The current boot's user journal is checked afterward, so a portal that started and stopped during settling still fails T0. A recorded Waybar start verifies that the harness can read the journal.

The default harness reports `EXPECTED_UPSTREAM_FAIL` (not a pass) only for the tested Waybar/GTK3 versions and matching early portal processes and journal records. It still fails on shell-only PSS >55 MiB, Waybar PSS, CPU/CS regressions, unstable shell/session samples, or excess combined PSS not attributable to those portal units. `--strict-t0-portal` makes early activation and combined PSS >60 MiB hard failures even for the known case.

| Metric | Measurement Source | T0 Pass Threshold |
|---|---|---|
| Cold-login PSS (`1920×1080`) | Sum of `Pss:` once per PID from `/proc/<pid>/smaps_rollup`; report Kaze shell and active session services separately and include any eagerly activated portals in the cold total | **≤ 60.0 MiB** |
| Shell-only regression guard | PSS summed over Kaze shell units, including their workers | **≤ 55.0 MiB** |
| `waybar` PSS | `/proc/<waybar_pid>/smaps_rollup` | **≤ 40.0 MiB** |
| Shell idle CPU | Delta `utime+stime` from `/proc/<pid>/stat`, divided by elapsed monotonic time | **≤ 0.20%** |
| Shell context switches/s | Sum per-thread deltas of `voluntary+nonvoluntary_ctxt_switches` in `/proc/<pid>/task/<tid>/status`, divided by elapsed monotonic time | **≤ 5.0 CS/s** |
| Resident shell processes | One native main PID per expected service (two `wl-paste` instances), plus all observed unit workers in the measured totals | No orphan/duplicate daemons |
| Portal activation | Check live PIDs and user-unit start records for the current boot without invoking portal methods | No portal started before or during T0 |

**Known regression:** [GTK3 3.24.52's `GtkApplication`](https://github.com/GNOME/gtk/blob/3.24.52/gtk/gtkapplication-dbus.c#L481-L495) requests `StartServiceByName` while creating its Inhibit proxy during Waybar 0.16.0 startup. [Waybar's own appearance watcher](https://github.com/Alexays/Waybar/blob/0.16.0/src/util/portal.cpp#L38-L53) already avoids activation. `GTK_USE_PORTAL=0` does not bypass GTK's Inhibit fallback; `GTK_USE_PORTAL=1` makes GDK query Settings at startup instead. Do not mask portal units, filter their PIDs out of the totals, or disable FileChooser or ScreenCast.

**Earlier stock rerun** (`./tests/vm-verify.sh`, November 25, 2026; `sidebar`, 1920×1080, Intel iGPU, Waybar `0.16.0-3`, GTK3 `1:3.24.52-2`, before same-UID process coverage):

| Cold boot | Shell PSS | Session PSS | Combined PSS | Outside PSS | Waybar PSS | Shell CPU | Shell CS/s | SSH ready |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 48.13 MiB | 33.86 MiB | 81.99 MiB | 179.26 MiB | 32.63 MiB | 0.01% | 0.57 | 12s |
| 2 | 48.13 MiB | 33.81 MiB | 81.94 MiB | 179.13 MiB | 32.73 MiB | 0.00% | 0.57 | 19s |
| 3 | 48.06 MiB | 33.95 MiB | 82.01 MiB | 179.43 MiB | 32.59 MiB | 0.01% | 0.57 | 10s |

No PID/thread-set change was detected in any of the three steady windows. The automated Gate 2 session checks passed. Gate 3 failed in all three boots for PSS and early portal activation; the Waybar PSS, shell CPU and shell CS/s limits passed.

**Latest stock smoke after the review** (`./tests/vm-verify.sh --samples 1`, same bar, GPU and package versions, 120s): 47.93 MiB shell (32.53 MiB Waybar), 37.35 MiB session, **85.28 MiB combined**, 189.79 MiB outside and 0.00 MiB unclassified. Shell idle CPU was 0.00% at displayed precision, with 0.57 CS/s. AT-SPI and the portal's FUSE worker are now counted. Gate 2 passed, and Gate 3 reported `EXPECTED_UPSTREAM_FAIL` for early portal activation and combined PSS; the strict T0 gate is still open.

**Diagnostic only, not a shipped fix:** One matched cold boot per variant (Arch KVM/VirGL, Intel iGPU, 4 vCPUs, `sidebar`, same wallpaper and packages, 45s settle + 120s measurement):

| Variant | Shell + session PSS | Waybar PSS | Shell CPU | Shell CS/s | Portal before client |
|---|---:|---:|---:|---:|---|
| Stock Waybar 0.16.0-3 / GTK3 3.24.52-2 | 81.89 MiB | 32.51 MiB | 0.01% | 0.57 | Started |
| Only Waybar's GTK Inhibit proxy construction prevented from auto-starting the portal | ~53.91 MiB | 36.25 MiB | 0.01% | 0.56 | Not started |

The VM-only intervention added `G_DBUS_PROXY_FLAGS_DO_NOT_AUTO_START_AT_CONSTRUCTION` to the exact Inhibit proxy call in Waybar. The tray still registered; an explicit Settings request then started the portal, a real FileChooser returned the expected file, and ScreenCast delivered five 1920×1080 PipeWire frames. The portal services' start records remained detectable after they stopped. Kaze does not install the experiment. A GTK fix should defer proxy creation until an app actually requests inhibition or a session monitor; flipping the flag globally is insufficient because GTK drops an unowned proxy and may not retry when an app actually needs it.

**T1/T2 (manual payloads for now):** use two separate boots with their own T0, same VM image, layout and wallpaper. For T1 send identical text and icon toasts, record the transient decode workers at peak, then 10s after the final toast closes take a 120s `vm-idle.py --phase T1_retained` sample. For T2 use Settings, a file picker and a PipeWire screen share, stop sharing and close the client, then measure `--phase T2` for 120s. Repeat at least 3 times and report package versions, variation and deltas. Neither warm sample is passed/failed against the 60 MiB T0 cap.

## 3. VM Shutdown Discipline

Every automated VM test script MUST finish with:
```bash
ssh ... bench@127.0.0.1 "sudo poweroff" || true
# Wait until pgrep -x qemu-system-x86 returns empty
```
Never leave a headless QEMU process holding a write lock on `arch-bench.qcow2` after a verification run.
