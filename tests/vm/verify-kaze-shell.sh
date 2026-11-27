#!/usr/bin/env bash
set -euo pipefail

# Stage 1 & 2 KVM Acceptance Gate for kaze-shell (Rust native):
# - T0 cold-boot resource budget (idle_sampler.py): Shell PSS <= 100 MiB, CPU <= 0.20%, CS <= 8.0 CS/s, 0 early portals
# - Real IPC checks: ping, bar-hide/bar-show kaze-share, theme-mode-toggle (Hyprland + Foot + GTK + btop), display-status
# - Hot-reload resilience: broken config.toml preserves live daemon & recovers on valid config
# - Durability stress test: 20x kaze-share create/remove + 10x hyprctl reload -> 0 crash, 0 zombie surfaces, stable PSS

# shellcheck source=tests/vm/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

samples=1
screenshot_out=""
while (( $# )); do
    case "$1" in
        --samples)
            samples=${2:-}
            if [[ ! "$samples" =~ ^[0-9]+$ ]]; then echo '--samples requires a non-negative integer.' >&2; exit 2; fi
            shift ;;
        --screenshot)
            screenshot_out=${2:-}
            shift ;;
        -h|--help)
            echo "Usage: $0 [--samples N] [--screenshot PATH]"
            exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            exit 2 ;;
    esac
    shift
done

if [[ ! -x "$REPO_DIR/kaze-shell/target/release/kaze-shell" ]]; then
    echo "==> Building kaze-shell release binary..."
    (cd "$REPO_DIR/kaze-shell" && cargo build --release)
fi

require_vm_off

BASE_VMDIR="$VMDIR"
OVERLAY_PARENT=$(mktemp -d --tmpdir kaze-shell-vm.XXXXXX)
chmod 700 -- "$OVERLAY_PARENT"
make_overlay "$BASE_VMDIR" "$OVERLAY_PARENT/vm"
VMDIR="$OVERLAY_PARENT/vm"

cleanup() {
    stop_vm || true
    rm -rf -- "$OVERLAY_PARENT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "==> Staging kaze-dots + kaze-shell (Rust) in disposable Arch KVM overlay (1920x1080)"
boot_vm staging
stage_guest
ssh_guest 'bash -s' <<'GUEST'
set -euo pipefail
export XDG_RUNTIME_DIR="/run/user/$(id -u)" LC_ALL=C.UTF-8
# Ensure unattended tty1 autologin into Hyprland inside the disposable overlay
sudo systemctl disable --now greetd.service >/dev/null 2>&1 || true
sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf >/dev/null <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --noclear --autologin bench %I $TERM
EOF
sudo systemctl enable getty@tty1.service >/dev/null 2>&1 || true
# Reset overlay to clean minimal baseline so stale full-profile fcitx5/portals from prior VM runs don't pollute T0
mkdir -p "$HOME/.config/kaze" "$HOME/.config/hypr"
printf 'minimal\n' > "$HOME/.config/kaze/profile"
printf 'return {}\n' > "$HOME/.config/hypr/user.lua"
rm -f "$HOME/.config/kaze-shell/config.toml"
"$HOME/kaze-dots/scripts/apply.sh" --yes
test -x "$HOME/.local/bin/kaze-shell"
"$HOME/.local/bin/kaze-shell" config validate "$HOME/.config/kaze-shell/config.toml"
GUEST
stop_vm

bench_status=0
if (( samples > 0 )); then
    for (( i=1; i<=samples; i++ )); do
        stop_vm
        echo "==> [Gate 3] Cold T0 resource budget sample $i/$samples (kaze-shell)"
        boot_vm cold
        wait_session
        if ! ssh_guest 'python3 -u ~/kaze-dots/tests/vm/idle_sampler.py --phase T0 --guest-sudo-pss'; then
            bench_status=1
        fi
    done
else
    boot_vm cold
    wait_session
fi

echo "==> [Gate 2 + Acceptance] Real IPC, live templates, hot-reload resilience, and 20x/10x stress test"
ssh_guest 'bash -s' <<'GUEST'
set -euo pipefail
export XDG_RUNTIME_DIR="/run/user/$(id -u)" PATH="$HOME/.local/bin:$PATH" LC_ALL=C.UTF-8
read_env() { systemctl --user show-environment | awk -F= -v k="$1" '$1 == k {print $2}'; }
export HYPRLAND_INSTANCE_SIGNATURE=$(read_env HYPRLAND_INSTANCE_SIGNATURE)
export WAYLAND_DISPLAY=$(read_env WAYLAND_DISPLAY)

read_pss_kib() {
    sudo -n /usr/bin/awk '/^Pss:/ {print $2}' "/proc/$1/smaps_rollup"
}

wait_layer_present() {
    local ns=$1
    for _ in {1..40}; do
        if hyprctl layers | grep -Fq "namespace: $ns"; then
            return 0
        fi
        sleep 0.1
    done
    echo "FAIL: timed out waiting for layer namespace: $ns" >&2
    hyprctl layers >&2
    return 1
}

wait_layer_absent() {
    local ns=$1
    for _ in {1..40}; do
        if ! hyprctl layers | grep -Fq "namespace: $ns"; then
            return 0
        fi
        sleep 0.1
    done
    echo "FAIL: timed out waiting for layer removal: $ns" >&2
    hyprctl layers >&2
    return 1
}

# 1. Baseline checks
test -z "$(hyprctl configerrors)"
foot --check-config
test "$(kaze-shell msg ping)" = "pong"
wait_layer_present "kaze-bar-Virtual-1"
initial_pid=$(systemctl --user show -p MainPID --value kaze-shell.service)
test "$initial_pid" -gt 1
echo "    baseline PID=$initial_pid"

# 2. Real IPC: bar-hide / bar-show on kaze-share without touching Virtual-1
hyprctl output create headless kaze-share >/dev/null
wait_layer_present "kaze-bar-kaze-share"
kaze-shell msg bar-hide kaze-share >/dev/null
wait_layer_absent "kaze-bar-kaze-share"
wait_layer_present "kaze-bar-Virtual-1"
kaze-shell msg bar-show kaze-share >/dev/null
wait_layer_present "kaze-bar-kaze-share"
hyprctl output remove kaze-share >/dev/null
wait_layer_absent "kaze-bar-kaze-share"
echo "    [PASS] IPC bar-hide / bar-show kaze-share"

# 3. Real IPC: theme-mode-toggle updates Hyprland live + Foot + GTK3/4 + btop
before_border=$(hyprctl -j getoption general:col.active_border)
before_foot=$(cat "$HOME/.config/foot/themes/kaze-shell")
mode_after=$(kaze-shell msg theme-mode-toggle)
test "$mode_after" = "light"
sleep 0.25
after_border=$(hyprctl -j getoption general:col.active_border)
after_foot=$(cat "$HOME/.config/foot/themes/kaze-shell")
if [[ "$before_border" == "$after_border" ]]; then
    echo "FAIL: Hyprland active_border did not change on theme-mode-toggle: $before_border" >&2
    exit 1
fi
test "$before_foot" != "$after_foot"
test -s "$HOME/.config/hypr/kaze-theme.lua"
test -s "$HOME/.config/gtk-3.0/kaze-shell.css"
test -s "$HOME/.config/gtk-4.0/kaze-shell.css"
test -s "$HOME/.config/btop/themes/kaze-shell.theme"
foot --check-config
test -z "$(hyprctl configerrors)"
mode_back=$(kaze-shell msg theme-mode-toggle)
test "$mode_back" = "dark"
sleep 0.25
test -z "$(hyprctl configerrors)"
echo "    [PASS] IPC theme-mode-toggle live Hyprland + Foot + GTK3/4 + btop"

# 3b. Live Hyprland workspace event tracking via socket2 (Hyprland 0.57+ Lua API)
hyprctl eval 'hl.dispatch(hl.dsp.focus({ workspace = "3" }))' >/dev/null
sleep 0.15
kaze-shell msg status | grep -Fq '"active_workspace_id": 3'
hyprctl eval 'hl.dispatch(hl.dsp.focus({ workspace = "1" }))' >/dev/null
sleep 0.15
kaze-shell msg status | grep -Fq '"active_workspace_id": 1'
echo "    [PASS] Live Hyprland socket2 workspace sync"

# 4. Display slot IPC
kaze-shell msg display-status present "WS 4" >/dev/null
kaze-shell msg status | grep -Fq '"display_status": "present"'
kaze-shell msg display-status idle >/dev/null
echo "    [PASS] IPC display-status"

# 5. Config hot-reload resilience (broken TOML must NOT crash daemon)
cfg="$HOME/.config/kaze-shell/config.toml"
cp -- "$cfg" "$cfg.bak"
printf '[bar\nthickness = BROKEN_TOML\n' > "$cfg"
sleep 0.3
test "$(systemctl --user show -p MainPID --value kaze-shell.service)" = "$initial_pid"
test "$(kaze-shell msg ping)" = "pong"
mv -f -- "$cfg.bak" "$cfg"
sleep 0.3
test "$(systemctl --user show -p MainPID --value kaze-shell.service)" = "$initial_pid"
echo "    [PASS] Config hot-reload survived broken TOML"

# 6. Stress test: 20x kaze-share create/remove + 10x hyprctl reload
# Warm up 1 cycle first so allocator high-water mark stabilizes before measuring leak slope.
hyprctl output create headless kaze-share >/dev/null
wait_layer_present "kaze-bar-kaze-share"
hyprctl output remove kaze-share >/dev/null
wait_layer_absent "kaze-bar-kaze-share"
sleep 0.3

pss_start=$(read_pss_kib "$initial_pid")
echo "    stress start: PID=$initial_pid PSS=${pss_start} KiB"

for iter in $(seq 1 20); do
    hyprctl output create headless kaze-share >/dev/null
    wait_layer_present "kaze-bar-kaze-share"
    if (( iter % 2 == 0 )); then
        hyprctl reload >/dev/null
        sleep 0.2
    fi
    hyprctl output remove kaze-share >/dev/null
    wait_layer_absent "kaze-bar-kaze-share"
    if (( iter == 5 || iter == 10 || iter == 15 || iter == 20 )); then
        pss_cur=$(read_pss_kib "$initial_pid")
        printf '    iter %2d/20: PSS=%s KiB\n' "$iter" "$pss_cur"
    fi
done

sleep 0.5
final_pid=$(systemctl --user show -p MainPID --value kaze-shell.service)
test "$final_pid" = "$initial_pid"
test "$(pgrep -xc kaze-shell)" = 1
test "$(kaze-shell msg ping)" = "pong"
wait_layer_present "kaze-bar-Virtual-1"
wait_layer_absent "kaze-bar-kaze-share"
status_json=$(kaze-shell msg status)
echo "$status_json" | grep -Fq '"surface_count": 1'
echo "$status_json" | grep -Fq '"hypr_connected": true'
test -z "$(hyprctl configerrors)"

pss_end=$(read_pss_kib "$initial_pid")
pss_delta=$(( pss_end - pss_start ))
printf '    stress end:   PID=%s PSS=%s KiB (delta=%+d KiB)\n' "$final_pid" "$pss_end" "$pss_delta"
# Allow at most 4096 KiB allocator variance across 20 hotplugs + 10 reloads.
if (( pss_delta > 4096 )); then
    echo "FAIL: PSS grew by ${pss_delta} KiB during 20x hotplug + 10x reload stress test" >&2
    exit 1
fi
echo "    [PASS] Stress test: 20x kaze-share + 10x hyprctl reload -> 0 crash, 0 zombies, stable PSS"

# 7. Capture screenshot if grim is installed
if command -v grim >/dev/null 2>&1; then
    grim -o Virtual-1 /tmp/kaze-shell-vm.png
fi
GUEST

if [[ -n "$screenshot_out" ]]; then
    mkdir -p -- "$(dirname -- "$screenshot_out")"
    scp -i "$VMDIR/bench_id_ed25519" -P 22222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        bench@127.0.0.1:/tmp/kaze-shell-vm.png "$screenshot_out" || true
fi

stop_vm
if (( boot_status || bench_status )); then
    exit 1
fi
echo "==> ALL kaze-shell Stage 1-2 VM acceptance gates PASSED."
