#!/usr/bin/env bash
# Shared host-side plumbing; callers use strict mode and own all launched VMs.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VMDIR="${KAZE_VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/shell-bench-vm}"

ssh_guest() {
    ssh -i "$VMDIR/bench_id_ed25519" -p 22222 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=2 -o ServerAliveInterval=2 -o ServerAliveCountMax=3 -o LogLevel=ERROR bench@127.0.0.1 "$@"
}

require_vm_off() {
    if pgrep -x qemu-system-x86 >/dev/null; then
        echo 'A QEMU instance is already running; leaving it untouched.' >&2
        return 1
    fi
}

vm_pid=
boot_status=0
stop_vm() {
    [ -n "$vm_pid" ] || return 0
    if kill -0 "$vm_pid" 2>/dev/null; then
        ssh_guest 'sudo systemctl poweroff' >/dev/null 2>&1 || true
        for _ in {1..30}; do
            kill -0 "$vm_pid" 2>/dev/null || break
            sleep 1
        done
    fi
    if kill -0 "$vm_pid" 2>/dev/null; then
        echo "Guest PID $vm_pid still running after requesting poweroff" >&2
        return 1
    fi
    vm_pid=
    echo '==> Guest powered off cleanly'
}

boot_vm() {
    local phase=${1:-cold} start now
    if (( $# )); then shift; fi
    require_vm_off
    start=$(date +%s)
    "$REPO_DIR/scripts/launch-vm.sh" --headless --vm-dir "$VMDIR" "$@"
    vm_pid=$(<"$VMDIR/vm.pid")
    for _ in {1..40}; do
        if ssh_guest true >/dev/null 2>&1; then
            now=$(date +%s)
            printf '    SSH available in %ds (%s boot)\n' "$(( now - start ))" "$phase"
            if [[ "$phase" == cold ]] && (( now - start >= 20 )); then
                echo 'Guest SSH startup missed the <20s boot gate (continuing other checks)' >&2
                boot_status=1
            fi
            if grep -qi 'failed to load' "$VMDIR/serial.log"; then
                grep -i 'failed to load' "$VMDIR/serial.log" >&2
                return 1
            fi
            return 0
        fi
        sleep 1
    done
    echo 'Guest SSH did not become available' >&2
    return 1
}

wait_session() {
    for _ in {1..30}; do
        # Keep each SSH probe short-lived so an early SSH login never pins
        # logind's User.Display ahead of the graphical tty1 session.
        if ssh_guest 'bash -s' <<'GUEST'
set -euo pipefail
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
systemctl --user is-active --quiet kaze-waybar.service &&
    systemctl --user is-active --quiet kaze-hypridle.service &&
    [ -S "$XDG_RUNTIME_DIR/foot.sock" ] || exit 1
sig=$(systemctl --user show-environment | awk -F= '$1=="HYPRLAND_INSTANCE_SIGNATURE" {print $2}')
[[ -n "$sig" ]] && layers=$(hyprctl -i "$sig" layers 2>/dev/null) &&
    grep -q 'namespace: wallpaper' <<< "$layers" && grep -q 'namespace: waybar' <<< "$layers" || exit 1
errors=$(hyprctl -i "$sig" configerrors)
if [[ -n "$errors" ]]; then printf '%s\n' "$errors" >&2; exit 2; fi
monitors=$(hyprctl -i "$sig" monitors)
grep -q 1920x1080 <<< "$monitors"
GUEST
        then
            return 0
        fi
        sleep .5
    done
    ssh_guest 'journalctl --user -b -n 80 --no-pager >&2' || true
    return 1
}

in_session() { ssh_guest '~/kaze-dots/tests/vm-in-session.sh' "$@"; }
qmp() { python3 "$REPO_DIR/tests/vm-input.py" "$VMDIR/qmp.sock" "$@"; }

stage_guest() {
    # Avoid drawing with files being replaced and never mutate the backing image.
    ssh_guest 'bash -s' <<'GUEST'
set -euo pipefail
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
if systemctl --user is-active --quiet kaze-session.target; then
    export HYPRLAND_INSTANCE_SIGNATURE=$(systemctl --user show-environment | awk -F= '$1=="HYPRLAND_INSTANCE_SIGNATURE" {print $2}')
    "$HOME/.local/bin/kaze-session" stop
fi
sudo systemctl stop getty@tty1.service
mkdir -p ~/kaze-dots
GUEST
    tar -C "$REPO_DIR" --exclude=.git --exclude=.pi -czf - . | ssh_guest 'tar xzf - -C ~/kaze-dots'
}

make_overlay() {
    local parent=$1 child=$2
    mkdir -m 700 -- "$child"
    qemu-img create -q -f qcow2 -F qcow2 -b "$(realpath -- "$parent/arch-bench.qcow2")" "$child/arch-bench.qcow2"
    cp -- "$parent/OVMF_VARS.fd" "$child/OVMF_VARS.fd"
    ln -s -- "$(realpath -- "$parent/bench_id_ed25519")" "$child/bench_id_ed25519"
}
