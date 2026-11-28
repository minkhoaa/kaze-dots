#!/usr/bin/env bash
set -euo pipefail

# Comprehensive Black-Box Blind Test Orchestrator for standalone kaze-shell (A01..I03)
# Runs strictly inside an isolated disposable Arch KVM CoW overlay (zero Noctalia, Intel iGPU).

SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=tests/vm/common.sh
source "$REPO_DIR/tests/vm/common.sh"

only_filter=""
skip_t0=false

while (( $# )); do
    case "$1" in
        --only)
            only_filter=${2:-}
            if [[ -z "$only_filter" ]]; then
                echo "run.sh: --only requires a comma-separated list of suites/IDs (e.g. A,B02)" >&2
                exit 2
            fi
            shift ;;
        --skip-t0)
            skip_t0=true ;;
        -h|--help)
            echo "Usage: $0 [--only SUITES_OR_IDS] [--skip-t0]"
            exit 0 ;;
        *)
            echo "run.sh: unknown option '$1'" >&2
            exit 2 ;;
    esac
    shift
done

# 1. Host Preflight
for bin in qemu-img qemu-system-x86_64 python3 ssh scp; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "PREFLIGHT FAIL: missing host binary: $bin" >&2
        exit 1
    fi
done

if [[ ! -x "$REPO_DIR/kaze-shell/target/release/kaze-shell" ]]; then
    echo "PREFLIGHT FAIL: compiled binary missing at $REPO_DIR/kaze-shell/target/release/kaze-shell" >&2
    exit 1
fi

BASE_VMDIR="$VMDIR"
for req in "$BASE_VMDIR/arch-bench.qcow2" "$BASE_VMDIR/OVMF_VARS.fd" "$BASE_VMDIR/bench_id_ed25519"; do
    if [[ ! -f "$req" ]]; then
        echo "PREFLIGHT FAIL: missing VM asset: $req" >&2
        exit 1
    fi
done

require_vm_off

OVERLAY_PARENT=$(mktemp -d --tmpdir kaze-blind-vm.XXXXXX)
chmod 700 -- "$OVERLAY_PARENT"
make_overlay "$BASE_VMDIR" "$OVERLAY_PARENT/vm"
VMDIR="$OVERLAY_PARENT/vm"

QMP_BRIDGE_PID=""
cleanup() {
    if [[ -n "$QMP_BRIDGE_PID" ]] && kill -0 "$QMP_BRIDGE_PID" 2>/dev/null; then
        kill "$QMP_BRIDGE_PID" 2>/dev/null || true
        wait "$QMP_BRIDGE_PID" 2>/dev/null || true
    fi
    stop_vm || true
    rm -rf -- "$OVERLAY_PARENT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Boot 1: Staging disposable CoW overlay (zero Noctalia + harness deps) ---
echo "==> [Boot 1/3] Staging standalone kaze-shell & blind harness in disposable Arch KVM overlay"
boot_vm staging
stage_guest
ssh_guest 'bash -s' <<'GUEST'
set -euo pipefail
export XDG_RUNTIME_DIR="/run/user/$(id -u)" LC_ALL=C.UTF-8

sudo pacman -Rns --noconfirm noctalia 2>/dev/null || true
sudo pacman -Rns --noconfirm noctalia-greeter 2>/dev/null || true

pkgs=(
    hyprlock hypridle hyprpolkitagent cliphist grim slurp wl-clipboard libnotify
    python-dbus python-gobject python-pillow wtype tesseract tesseract-data-eng
    fcitx5 fcitx5-bamboo noto-fonts noto-fonts-cjk noto-fonts-emoji wl-mirror binutils
)
missing=()
for p in "${pkgs[@]}"; do
    if ! pacman -Qq "$p" >/dev/null 2>&1; then
        missing+=("$p")
    fi
done
if (( ${#missing[@]} > 0 )); then
    echo "    installing blind-test harness packages: ${missing[*]}"
    sudo pacman -Sy --noconfirm --needed "${missing[@]}" >/dev/null
fi
if command -v noctalia >/dev/null 2>&1; then
    echo "PREFLIGHT FAIL: noctalia still present in PATH" >&2
    exit 1
fi

sudo systemctl disable --now greetd.service >/dev/null 2>&1 || true
sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf >/dev/null <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --noclear --autologin bench %I $TERM
EOF
sudo systemctl enable getty@tty1.service >/dev/null 2>&1 || true

mkdir -p "$HOME/.config/kaze" "$HOME/.config/hypr"
printf 'minimal\n' > "$HOME/.config/kaze/profile"
printf 'return {}\n' > "$HOME/.config/hypr/user.lua"
rm -f "$HOME/.config/kaze-shell/config.toml" "$HOME/.config/systemd/user/kaze-noctalia.service"
rm -f "$HOME/.local/state/kaze/layout-state.toml"
"$HOME/kaze-dots/scripts/apply.sh" --yes
GUEST
stop_vm

T0_JSON="$OVERLAY_PARENT/blind-t0.json"
FULL_JSON="$OVERLAY_PARENT/blind-full.json"

run_t0=true
if [[ "$skip_t0" == true ]]; then
    run_t0=false
elif [[ -n "$only_filter" ]] && [[ ! ",$only_filter," =~ ,(B|B01), ]]; then
    run_t0=false
fi

# --- Boot 2: Pristine Cold T0 Budget Gate (B01) ---
if [[ "$run_t0" == true ]]; then
    echo "==> [Boot 2/3] Cold T0 Blind Check (B01)"
    boot_vm cold
    wait_session
    ssh_guest 'bash -s' <<'GUEST'
set -euo pipefail
export XDG_RUNTIME_DIR="/run/user/$(id -u)" PATH="$HOME/.local/bin:$PATH" LC_ALL=C.UTF-8
read_env() { systemctl --user show-environment | awk -F= -v k="$1" '$1 == k {print $2}'; }
export HYPRLAND_INSTANCE_SIGNATURE=$(read_env HYPRLAND_INSTANCE_SIGNATURE)
export WAYLAND_DISPLAY=$(read_env WAYLAND_DISPLAY)
python3 -u ~/kaze-dots/tests/blind/runner.py --preflight
python3 -u ~/kaze-dots/tests/blind/runner.py --phase t0 --out /tmp/blind-t0.json || true
GUEST
    scp -i "$VMDIR/bench_id_ed25519" -P 22222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        bench@127.0.0.1:/tmp/blind-t0.json "$T0_JSON"
    stop_vm
fi

# --- Boot 3: Full Black-Box Suites (A01..I03) with Real QMP Input + Dual Monitor ---
run_full=true
if [[ -n "$only_filter" ]] && [[ "$only_filter" == "B01" ]]; then
    run_full=false
fi

ARTIFACTS_DIR="$SCRIPT_DIR/artifacts"
mkdir -p -- "$ARTIFACTS_DIR"

if [[ "$run_full" == true ]]; then
    echo "==> [Boot 3/3] Full Black-Box Blind Suite (QMP + Dual Monitor)"
    boot_vm cold --qmp --dual-monitor
    wait_session

    QMP_PORT_FILE="$OVERLAY_PARENT/qmp.port"
    python3 "$SCRIPT_DIR/harness/mock_input.py" --serve-qmp "$VMDIR/qmp.sock" --port-file "$QMP_PORT_FILE" &
    QMP_BRIDGE_PID=$!
    for _ in {1..40}; do
        if [[ -s "$QMP_PORT_FILE" ]]; then break; fi
        sleep 0.05
    done
    if [[ ! -s "$QMP_PORT_FILE" ]]; then
        echo "PREFLIGHT FAIL: QMP bridge failed to bind port" >&2
        exit 1
    fi
    QMP_HOST_PORT=$(<"$QMP_PORT_FILE")

    ssh -i "$VMDIR/bench_id_ed25519" -p 22222 -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -R "127.0.0.1:19876:127.0.0.1:${QMP_HOST_PORT}" \
        bench@127.0.0.1 "bash -s -- $(printf '%q' "$only_filter")" <<'GUEST'
set -euo pipefail
ONLY_FILTER="$1"
export XDG_RUNTIME_DIR="/run/user/$(id -u)" PATH="$HOME/.local/bin:$PATH" LC_ALL=C.UTF-8
export KAZE_BLIND_QMP_PORT=19876
read_env() { systemctl --user show-environment | awk -F= -v k="$1" '$1 == k {print $2}'; }
export HYPRLAND_INSTANCE_SIGNATURE=$(read_env HYPRLAND_INSTANCE_SIGNATURE)
export WAYLAND_DISPLAY=$(read_env WAYLAND_DISPLAY)

# Ensure Virtual-2 starts unplugged for clean single-monitor baseline until D07
for s in /sys/class/drm/card*-Virtual-2/status; do
    if [[ -f "$s" ]]; then
        echo off | sudo -n tee "$s" >/dev/null
        sudo -n udevadm trigger --subsystem-match=drm --action=change
    fi
done
sleep 0.3

python3 -u ~/kaze-dots/tests/blind/runner.py --preflight --require-qmp
python3 -u ~/kaze-dots/tests/blind/runner.py --phase full --only "$ONLY_FILTER" --out /tmp/blind-full.json --artifacts-dir /tmp/kaze-blind-artifacts || true
GUEST

    scp -i "$VMDIR/bench_id_ed25519" -P 22222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        bench@127.0.0.1:/tmp/blind-full.json "$FULL_JSON"
    scp -i "$VMDIR/bench_id_ed25519" -P 22222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "bench@127.0.0.1:/tmp/kaze-blind-artifacts/*.png" "$ARTIFACTS_DIR/" 2>/dev/null || true

    kill "$QMP_BRIDGE_PID" 2>/dev/null || true
    wait "$QMP_BRIDGE_PID" 2>/dev/null || true
    QMP_BRIDGE_PID=""
    stop_vm
fi

merge_inputs=()
[[ -f "$T0_JSON" ]] && merge_inputs+=("$T0_JSON")
[[ -f "$FULL_JSON" ]] && merge_inputs+=("$FULL_JSON")
if (( ${#merge_inputs[@]} == 0 )); then
    echo "FAIL: no blind test result files produced" >&2
    exit 1
fi

python3 "$SCRIPT_DIR/runner.py" --merge-reports "${merge_inputs[@]}" --artifacts-dir "$ARTIFACTS_DIR" --only "$only_filter"
