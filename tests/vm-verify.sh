#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/vm-common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/vm-common.sh"

samples=3
mode=
while (( $# )); do
    case "$1" in
        --functional-only|--samples)
            if [[ -n "$mode" ]]; then echo 'Choose only one of --functional-only and --samples.' >&2; exit 2; fi
            mode=$1
            samples=0
            if [[ "$mode" == --samples ]]; then
                samples=${2:-}
                if [[ ! "$samples" =~ ^[1-9][0-9]*$ ]]; then echo '--samples requires a positive integer.' >&2; exit 2; fi
                shift
            fi ;;
        -h|--help) echo "Usage: $0 [--functional-only | --samples N]"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

require_vm_off
trap stop_vm EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "==> Deploying kaze-dots (Noctalia native) to isolated Arch guest (Intel iGPU, 1920x1080)"
boot_vm staging
ssh_guest 'pacman -Q hyprland noctalia foot xdg-desktop-portal xdg-desktop-portal-hyprland xdg-desktop-portal-gtk dconf'
stage_guest
ssh_guest 'bash -s' <<'GUEST'
set -euo pipefail
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/home" "$fixture/config/hypr" "$fixture/config/systemd/user" "$fixture/config/noctalia"
printf 'return {} -- user-file-marker\n' > "$fixture/config/hypr/user.lua"
printf 'unit-marker\n' > "$fixture/config/systemd/user/kaze-noctalia.service"
printf '# custom-marker\n' > "$fixture/config/noctalia/config.toml"
export HOME_ORIG="$HOME"
(
    export HOME="$fixture/home" XDG_CONFIG_HOME="$fixture/config" XDG_DATA_HOME="$fixture/data" XDG_CACHE_HOME="$fixture/cache"
    "$HOME_ORIG/kaze-dots/scripts/apply.sh" --yes
    test -L "$XDG_CONFIG_HOME/systemd/user/kaze-noctalia.service"
    test -L "$XDG_CONFIG_HOME/systemd/user/kaze-session.target"
    test -L "$XDG_CONFIG_HOME/foot/foot.ini"
    noctalia config validate "$XDG_CONFIG_HOME/noctalia/config.toml"
    foot --check-config --config "$XDG_CONFIG_HOME/foot/foot.ini"
    first=$(<"$XDG_CONFIG_HOME/kaze/last-backup")
    "$HOME_ORIG/kaze-dots/scripts/apply.sh" --yes
    backup=$(<"$XDG_CONFIG_HOME/kaze/last-backup")
    test "$backup" != "$first"
    "$backup/rollback.sh" --yes
    grep -Fxq 'return {} -- user-file-marker' "$XDG_CONFIG_HOME/hypr/user.lua"
    grep -Fxq unit-marker "$XDG_CONFIG_HOME/systemd/user/kaze-noctalia.service"
    grep -Fxq '# custom-marker' "$XDG_CONFIG_HOME/noctalia/config.toml"
    test ! -L "$HOME/.local/bin/kaze-session"
    test ! -L "$XDG_CONFIG_HOME/systemd/user/kaze-session.target"
    test ! -e "$XDG_CONFIG_HOME/kaze/last-backup"
)
"$HOME/kaze-dots/scripts/apply.sh" --yes
GUEST
stop_vm

bench_status=0
if (( samples > 0 )); then
    for (( i=1; i<=samples; i++ )); do
        stop_vm
        echo "==> [Gate 3] Cold T0 sample $i/$samples"
        boot_vm cold
        wait_session
        if ! ssh_guest 'python3 -u ~/kaze-dots/tests/vm-idle.py --phase T0 --guest-sudo-pss'; then
            bench_status=1
        fi
    done
else
    boot_vm cold
    wait_session
fi

echo "==> [Gate 2] Session, Noctalia native templates, portal routing, and restart checks"
ssh_guest 'bash -s' <<'GUEST'
set -euo pipefail
export XDG_RUNTIME_DIR="/run/user/$(id -u)" PATH="$HOME/.local/bin:$PATH" LC_ALL=C.UTF-8
qa=$(mktemp -d)
trap 'rm -rf -- "$qa"' EXIT
read_env() { systemctl --user show-environment | awk -F= -v k="$1" '$1 == k {print $2}'; }
export HYPRLAND_INSTANCE_SIGNATURE=$(read_env HYPRLAND_INSTANCE_SIGNATURE)
export WAYLAND_DISPLAY=$(read_env WAYLAND_DISPLAY)
test "$(read_env XDG_CURRENT_DESKTOP)" = Hyprland
test -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
test -z "$(hyprctl configerrors)"
noctalia config validate
foot --check-config
grep -q '1920x1080' <<< "$(hyprctl monitors)"
grep -q 'namespace: noctalia-bar-' <<< "$(hyprctl layers)"

# Passive portal check + live kaze-doctor
kaze-doctor

# Verify Noctalia built-in templates applied to Hyprland & Foot
noctalia msg templates-apply
sleep 0.5
test -s "$HOME/.config/hypr/noctalia.lua"
test -s "$HOME/.config/foot/themes/noctalia"

# Native Noctalia dark/light toggle
noctalia msg theme-mode-toggle
sleep 0.4
noctalia msg theme-mode-toggle
sleep 0.4
test -z "$(hyprctl configerrors)"

# DPMS wake test
hyprctl dispatch 'hl.dsp.dpms({ action="off" })'
grep -Eq '"dpmsStatus":[[:space:]]*false' <<< "$(hyprctl -j monitors all)"
kaze-session wake-displays
grep -Eq '"dpmsStatus":[[:space:]]*true' <<< "$(hyprctl -j monitors all)"

# Crash recovery for kaze-noctalia.service and foot-server.service
unit_pid() { systemctl --user show -p MainPID --value "$1"; }
for unit in kaze-noctalia.service foot-server.service; do
    old=$(unit_pid "$unit")
    kill -SEGV "$old"
    for _ in {1..30}; do
        new=$(unit_pid "$unit")
        if [[ "$new" != 0 && "$new" != "$old" ]]; then break; fi
        sleep .2
    done
    [[ "$new" != 0 && "$new" != "$old" ]]
    printf '    %s recovered: %s -> %s\n' "$unit" "$old" "$new"
done

# Foot client exit code propagation
kaze-footclient -N /usr/bin/true
client_status=0
kaze-footclient -e /usr/bin/sh -c 'sleep .25; touch "$1"; exit 37' sh "$qa/foot-done" || client_status=$?
test "$client_status" = 37
test -f "$qa/foot-done"

# Singleton daemon check
test "$(pgrep -xc noctalia)" = 1
test "$(pgrep -xc foot)" = 1

# Floating TUI toggle
kaze-tui sysmon
sleep .5
grep -q 'class: kaze-tui' <<< "$(hyprctl clients)"
kaze-tui sysmon
GUEST

echo '==> Gate 2 session checks passed.'
stop_vm
if (( boot_status || bench_status )); then exit 1; fi
