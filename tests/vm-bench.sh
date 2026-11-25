#!/usr/bin/env bash
# Matched cold-boot T0/T1/T2 notification comparison on disposable Arch overlays.
set -euo pipefail
# shellcheck source=tests/vm-common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/vm-common.sh"

runs=3
phases=(T1 T2)
seconds=120
while (( $# )); do
    case "$1" in
        --runs)
            runs=${2:-}
            [[ "$runs" =~ ^[1-9][0-9]*$ ]] || { echo '--runs needs a positive integer' >&2; exit 2; }
            shift ;;
        --phase)
            case "${2:-}" in T1|T2) phases=("$2") ;; *) echo '--phase needs T1 or T2' >&2; exit 2 ;; esac
            shift ;;
        --smoke) seconds=2 ;;
        -h|--help) echo "Usage: $0 [--runs N] [--phase T1|T2] [--smoke]"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
require_vm_off
base="$VMDIR"
out=$(mktemp -d /tmp/kaze-bench.XXXXXXXX)
echo "==> Evidence: $out (guest disk overlays are temporary)"
cleanup() {
    stop_vm || return 1
    rm -rf -- "$out/ready" "$out/mako" "$out/cold"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

make_overlay "$base" "$out/ready"
VMDIR="$out/ready"
boot_vm staging
stage_guest
ssh_guest 'bash -s' <<'GUEST' |& tee "$out/packages.log"
set -euo pipefail
export XDG_RUNTIME_DIR="/run/user/$(id -u)" PATH="$HOME/.local/bin:$PATH"
uname -rm
lscpu | grep -E '^CPU\(s\):|Model name:'
pacman -Q fnott mako waybar gtk3 gdk-pixbuf2 glycin bubblewrap libnotify hyprland hypridle gcc gst-plugin-pipewire
cd ~/kaze-dots
scripts/apply.sh --yes
kaze-layout --quiet sidebar
cc -O2 -Wall -Wextra -Werror -o tests/portal-probe tests/vm-portal.c $(pkg-config --cflags --libs gio-unix-2.0)
GUEST
stop_vm

# Both contenders share the exact same staged disk. Only the Mako fork changes
# notification routing; it never starts Mako in a boot with Fnott still running.
make_overlay "$out/ready" "$out/mako"
VMDIR="$out/mako"
boot_vm staging
ssh_guest 'bash -s' <<'GUEST'
set -euo pipefail
export XDG_RUNTIME_DIR="/run/user/$(id -u)" PATH="$HOME/.local/bin:$PATH"
if systemctl --user is-active --quiet kaze-session.target; then
    ~/kaze-dots/tests/vm-in-session.sh kaze-session stop
fi
sudo systemctl stop getty@tty1.service
systemctl --user mask fnott.service
units="$HOME/.config/systemd/user"
for name in kaze-session.target kaze-waybar.service; do
    rm -- "$units/$name"
    # Override the unit in the disposable image, not the symlinked repo source.
    awk '{gsub(/fnott\.service/, "mako.service"); print}' ~/kaze-dots/config/systemd/user/"$name" > "$units/$name"
done
mkdir -p "$units/mako.service.d" "$HOME/.config/mako"
printf '%s\n' '[Unit]' 'PartOf=kaze-session.target' 'Requisite=kaze-session.target' 'After=kaze-session.target' \
    '[Service]' 'EnvironmentFile=%t/kaze/session.env' 'TimeoutStartSec=8s' 'TimeoutStopSec=5s' \
    > "$units/mako.service.d/50-kaze-bench.conf"
activation="$HOME/.local/share/dbus-1/services/org.freedesktop.Notifications.service"
rm -- "$activation"
printf '%s\n' '[D-BUS Service]' 'Name=org.freedesktop.Notifications' 'SystemdService=mako.service' 'Exec=/usr/bin/false' > "$activation"
cd ~/kaze-dots
lua - > "$HOME/.config/mako/config" <<'LUA'
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path
io.write(require("kaze.emit_mako").emit(require("kaze.config").load()))
LUA
GUEST
stop_vm

sample() {
    local phase=$1 daemon=$2 log=$3
    local args=(--phase "$phase" --notifications "$daemon" --seconds "$seconds" --guest-sudo-pss)
    if [[ "$phase" == T0 ]]; then args+=(--allow-known-t0-portal); fi
    if in_session python3 -u '~/kaze-dots/tests/vm-idle.py' "${args[@]}" |& tee "$log"; then
        return 0
    elif [[ $? == 10 && "$phase" == T0 ]]; then
        return 0 # raw sample records the upstream failure, not a strict pass
    else
        return 1
    fi
}

run_failed=0
for phase in "${phases[@]}"; do
    for (( i=1; i<=runs; ++i )); do
        # AB, BA, AB: reduce ordering effects without changing workloads.
        daemons=(fnott mako)
        if (( i % 2 == 0 )); then daemons=(mako fnott); fi
        for daemon in "${daemons[@]}"; do
            parent="$out/$([[ "$daemon" == mako ]] && echo mako || echo ready)"
            log="$out/$phase-$i-$daemon"
            mkdir -m 700 -- "$log"
            echo "==> $phase / $daemon ($i/$runs)"
            make_overlay "$parent" "$out/cold"
            VMDIR="$out/cold"
            boot_vm cold --qmp
            wait_session
            [[ $(in_session kaze-layout --current) == sidebar ]]
            in_session python3 -u '~/kaze-dots/tests/vm-notify.py' owner "$daemon"
            if ! sample T0 "$daemon" "$log/T0.log"; then run_failed=1; fi
            # Fresh input after T0 keeps hypridle's 300s lock out of both windows.
            # Never synthesize input while the sampler itself is running.
            qmp key shift
            if [[ "$phase" == T1 ]]; then
                in_session python3 -u '~/kaze-dots/tests/vm-notify.py' payload "$daemon" |& tee "$log/workload.log"
                if ! sample T1_retained "$daemon" "$log/T1_retained.log"; then run_failed=1; fi
                if ! in_session python3 -u '~/kaze-dots/tests/vm-notify.py' reaped "$daemon"; then run_failed=1; fi
                if [[ "$daemon" == mako ]]; then
                    if ! in_session python3 -u '~/kaze-dots/tests/vm-notify.py' mako-correctness mako |& tee "$log/mako.log"; then
                        run_failed=1 # keep collecting data from the remaining pairs
                    fi
                fi
                in_session bash -c "'tar -cf - -C \"\$XDG_RUNTIME_DIR/kaze-qa\" .'" | tar -xf - -C "$log"
            else
                # shellcheck source=tests/vm-portal.sh
                source "$REPO_DIR/tests/vm-portal.sh"
                exercise_portals "$log"
                if ! sample T2 "$daemon" "$log/T2.log"; then run_failed=1; fi
            fi
            stop_vm
            rm -rf -- "$out/cold"
        done
    done
done
printf '==> Evidence: %s\n' "$out"
if (( run_failed || boot_status )); then exit 1; fi
