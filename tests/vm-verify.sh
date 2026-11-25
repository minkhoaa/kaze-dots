#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/vm-common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/vm-common.sh"

samples=3
mode=
strict_t0=false
stage2=false
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
        --strict-t0-portal) strict_t0=true ;;
        --stage2) stage2=true ;;
        -h|--help) echo "Usage: $0 [--functional-only | --samples N] [--strict-t0-portal] [--stage2]"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
if (( samples == 0 )) && [[ "$strict_t0" == true ]]; then
    echo '--strict-t0-portal requires T0 samples.' >&2
    exit 2
fi

require_vm_off
trap stop_vm EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
boot_opts=()
if [[ "$stage2" == true ]]; then boot_opts=(--qmp); fi

echo "==> Deploying to the isolated Arch guest (Intel iGPU, 1920x1080)"
boot_vm staging
ssh_guest 'pacman -Q hyprland hypridle waybar fnott foot xdg-desktop-portal xdg-desktop-portal-hyprland xdg-desktop-portal-gtk dconf'
if [[ "$stage2" == true ]]; then
    ssh_guest 'pacman -Q hyprsunset wf-recorder hyprpicker swappy ffmpeg xdg-user-dirs'
fi
stage_guest
ssh_guest 'bash -s' <<'GUEST'
set -euo pipefail
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
# Exercise XDG paths and rollback without replacing the guest's user.lua.
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/home" "$fixture/config/kaze" "$fixture/config/systemd/user" "$fixture/config/waybar"
printf 'return {} -- user-file-marker\n' > "$fixture/config/kaze/user.lua"
printf 'unit-marker\n' > "$fixture/config/systemd/user/kaze-waybar.service"
printf 'style-marker\n' > "$fixture/config/waybar/style.css"
export HOME_ORIG="$HOME"
(
    export HOME="$fixture/home" XDG_CONFIG_HOME="$fixture/config" XDG_DATA_HOME="$fixture/data"
    "$HOME_ORIG/kaze-dots/scripts/apply.sh" --yes
    test -L "$XDG_CONFIG_HOME/systemd/user/kaze-waybar.service"
    test -L "$XDG_DATA_HOME/dbus-1/services/org.freedesktop.Notifications.service"
    for name in record night inhibit; do
        test -L "$XDG_CONFIG_HOME/systemd/user/kaze-$name.service"
        test -L "$HOME/.local/bin/kaze-$name"
    done
    first=$(<"$XDG_CONFIG_HOME/kaze/last-backup")
    "$HOME_ORIG/kaze-dots/scripts/apply.sh" --yes
    backup=$(<"$XDG_CONFIG_HOME/kaze/last-backup")
    test "$backup" != "$first"
    grep -Fxq "$XDG_CONFIG_HOME/systemd/user/kaze-waybar.service" "$backup/installed.list"
    "$backup/rollback.sh" --yes
    grep -Fxq 'return {} -- user-file-marker' "$XDG_CONFIG_HOME/kaze/user.lua"
    grep -Fxq unit-marker "$XDG_CONFIG_HOME/systemd/user/kaze-waybar.service"
    grep -Fxq style-marker "$XDG_CONFIG_HOME/waybar/style.css"
    test ! -L "$HOME/.local/bin/kaze-sync"
    for name in record night inhibit; do
        test ! -L "$XDG_CONFIG_HOME/systemd/user/kaze-$name.service"
        test ! -L "$HOME/.local/bin/kaze-$name"
    done
    test ! -L "$XDG_CONFIG_HOME/systemd/user/kaze-session.target"
    test ! -e "$XDG_CONFIG_HOME/waybar/config.jsonc"
    test ! -L "$XDG_DATA_HOME/dbus-1/services/org.freedesktop.Notifications.service"
    test ! -e "$XDG_CONFIG_HOME/kaze/last-backup"
)
"$HOME/kaze-dots/scripts/apply.sh" --yes
GUEST
stop_vm

bench_status=0
expected_t0=0
if (( samples > 0 )); then
    sample_cmd='python3 -u ~/kaze-dots/tests/vm-idle.py --phase T0 --guest-sudo-pss'
    if [[ "$strict_t0" == false ]]; then sample_cmd+=' --allow-known-t0-portal'; fi
    # Separate boots prevent warmed glyph caches, prior portal use, or the 300s
    # idle lock from contaminating any of the 120s windows.
    for (( i=1; i<=samples; i++ )); do
        stop_vm
        echo "==> [Gate 3] Cold T0 sample $i/$samples"
        boot_vm cold "${boot_opts[@]}"
        wait_session
        if ssh_guest "$sample_cmd"; then
            :
        elif [[ $? == 10 && "$strict_t0" == false ]]; then
            expected_t0=$(( expected_t0 + 1 ))
        else
            bench_status=1
        fi
    done
else
    boot_vm cold "${boot_opts[@]}"
    wait_session
fi

echo "==> [Gate 2] Session, layouts, portal routing, clipboard and restart checks"
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
grep -q '1920x1080' <<< "$(hyprctl monitors)"
grep -q 'namespace: wallpaper' <<< "$(hyprctl layers)"

# Passive query first (does not activate the portal).
grep -q '^org.freedesktop.portal.Desktop ' <<< "$(busctl --user --activatable)"
portal=org.freedesktop.portal.Desktop
obj=/org/freedesktop/portal/desktop
busctl --user --timeout=10s call "$portal" "$obj" org.freedesktop.portal.Settings ReadOne ss org.freedesktop.appearance color-scheme
busctl --user --timeout=8s call "$portal" "$obj" org.freedesktop.portal.FileChooser OpenFile 'ssa{sv}' '' 'Kaze QA File Picker' 0
sleep .5
grep -q 'class: xdg-desktop-portal-gtk' <<< "$(hyprctl clients)"
busctl --user --timeout=8s get-property "$portal" "$obj" org.freedesktop.portal.ScreenCast AvailableSourceTypes

hyprctl dispatch 'hl.dsp.dpms({ action="off" })'
grep -Eq '"dpmsStatus":[[:space:]]*false' <<< "$(hyprctl -j monitors all)"
kaze-session wake-displays
grep -Eq '"dpmsStatus":[[:space:]]*true' <<< "$(hyprctl -j monitors all)"

# Event-driven clipboard ingestion. Only the verification harness sleeps.
printf normal-kaze-qa | wl-copy >/dev/null 2>&1
sleep .5
grep -q normal-kaze-qa <<< "$(kaze-clipboard list)"
db="$XDG_RUNTIME_DIR/kaze/cliphist.db"
test "$(stat -c %a "$db")" = 600
printf tagged-fake-secret | wl-copy --sensitive >/dev/null 2>&1
sleep .5
if grep -q tagged-fake-secret <<< "$(kaze-clipboard list)"; then
    echo 'sensitive clipboard item leaked into history' >&2
    exit 1
fi
snapshot=$(sha256sum "$db")
head -c 20971520 /dev/zero | tr '\0' a | wl-copy --type text/plain >/dev/null 2>&1
sleep .5
test "$(sha256sum "$db")" = "$snapshot"

# Offer a real PNG, replace the clipboard, then restore through the actual
# cliphist decode and wl-copy pipeline. Only the picker selection is scripted.
printf %s 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/q9kAAAAASUVORK5CYII=' | base64 --decode > "$qa/one.png"
wl-copy --type image/png < "$qa/one.png" >/dev/null 2>&1
for ((i=0; i<20; ++i)); do
    if kaze-clipboard list | grep -qi 'png 1x1'; then break; fi
    sleep .1
done
kaze-clipboard list | grep -i 'png 1x1'
mkdir -- "$qa/bin"
printf '%s\n' '#!/bin/sh' "awk '/png 1x1/ && !found++ { print } END { if (!found) exit 1 }'" > "$qa/bin/fuzzel"
chmod 700 "$qa/bin/fuzzel"
printf 'not the image' | wl-copy --type text/plain >/dev/null 2>&1
PATH="$qa/bin:$PATH" kaze-clipboard pick
wl-paste --list-types | grep -Fx 'image/png'
wl-paste --no-newline --type image/png > "$qa/restored.png"
cmp "$qa/one.png" "$qa/restored.png"
shot=$(kaze-screenshot screen --save)
grep -q 'PNG image data, 1920 x 1080' <<< "$(file "$shot")"
rm -- "$shot"

unit_pid() { systemctl --user show -p MainPID --value "$1"; }
for unit in kaze-waybar.service foot-server.service; do
    old=$(unit_pid "$unit")
    kill -SEGV "$old"
    for _ in {1..20}; do
        new=$(unit_pid "$unit")
        if [[ "$new" != 0 && "$new" != "$old" ]]; then break; fi
        sleep .2
    done
    [[ "$new" != 0 && "$new" != "$old" ]]
    printf '    %s recovered: %s -> %s\n' "$unit" "$old" "$new"
done
kaze-footclient -N /usr/bin/true
client_status=0
kaze-footclient -e /usr/bin/sh -c 'sleep .25; touch "$1"; exit 37' sh "$qa/foot-done" || client_status=$?
test "$client_status" = 37
test -f "$qa/foot-done"
foot_before=$(unit_pid foot-server.service)
for i in {1..10}; do
    layouts=(sidebar islands slim)
    sizes=('8 8 42 1064' '10 6 1900 34' '0 0 1920 28')
    j=$(( i % 3 ))
    kaze-layout --quiet "${layouts[j]}"
    sleep .4
    grep -E "xywh: ${sizes[j]}, .*namespace: waybar" <<< "$(hyprctl layers)"
    test -z "$(hyprctl configerrors)"
done
kaze-layout --quiet sidebar & layout_job=$!
kaze-theme --quiet lavender & theme_job=$!
wait "$layout_job"
wait "$theme_job"
test "$(kaze-layout --current)" = sidebar
test "$(kaze-theme --current)" = lavender
for name in tokyonight carbon kaze; do
    kaze-theme --quiet "$name"
    test "$(kaze-theme --current)" = "$name"
done
# Reload via SSH with DPMS off. It must not wake the output or roll back.
env_file="$XDG_RUNTIME_DIR/kaze/session.env"
cp -- "$env_file" "$qa/env-before"
hyprctl dispatch 'hl.dsp.dpms({ action="off" })'
kaze-layout --quiet slim
test "$(kaze-layout --current)" = slim
grep -Eq '"dpmsStatus":[[:space:]]*false' <<< "$(hyprctl -j monitors all)"
kaze-session wake-displays
kaze-layout --quiet sidebar

# Test live wallpaper and cursor changes using only guest-local user overrides.
user_file="$HOME/.config/kaze/user.lua"
cp -a -- "$user_file" "$qa/user.lua"
trap 'cp -aT --remove-destination -- "$qa/user.lua" "$user_file"; rm -rf -- "$qa"' EXIT
orig_wall=$(unit_pid kaze-wallpaper.service)
rm -- "$user_file"
printf '%s\n' 'return { wallpaper="", cursor_size=32 }' > "$user_file"
kaze-sync --reload
grep -Fx 'XCURSOR_SIZE="32"' "$env_file"
grep -Fx 'KAZE_WALLPAPER=""' "$env_file"
solid_pid=$(unit_pid kaze-wallpaper.service)
# Verify the running process received the fallback color of the new theme.
kaze-theme --quiet carbon
wall_pid=$(unit_pid kaze-wallpaper.service)
test "$wall_pid" != "$solid_pid"
color=$(awk -F'"' '/^KAZE_WALLPAPER_COLOR=/{print $2}' "$env_file")
grep -Fx -- "$color" < <(tr '\0' '\n' < "/proc/$wall_pid/cmdline")
test "$wall_pid" != "$orig_wall"
cp -aT --remove-destination -- "$qa/user.lua" "$user_file"
trap 'rm -rf -- "$qa"' EXIT
kaze-theme --quiet kaze
if grep -q '^KAZE_WALLPAPER="[^"].*"' "$qa/env-before"; then
    grep -Fx -- "$(grep '^KAZE_WALLPAPER=' "$qa/env-before")" "$env_file"
    grep -Fx -- '-i' < <(tr '\0' '\n' < "/proc/$(unit_pid kaze-wallpaper.service)/cmdline")
fi
test "$(unit_pid foot-server.service)" = "$foot_before"
test "$(pgrep -xc waybar)" = 1
test "$(pgrep -xc wl-paste)" = 2
kaze-tui sysmon
sleep .5
grep -q 'class: kaze-tui' <<< "$(hyprctl clients)"
kaze-tui sysmon
kaze-osd vol-up
systemctl --user is-active --quiet fnott.service

# Lock through logind from SSH. Require both a compositor confirmation and the
# resulting lock hint (the hint on its own isn't proof of a Wayland lock).
display_session=$(loginctl show-user "$(id -u)" -p Display --value)
test "$(loginctl show-session "$display_session" -p LockedHint --value)" = no
kaze-session lock
locked= hint=
for _ in {1..20}; do
    locked=$(busctl --user --auto-start=no --timeout=1s call org.freedesktop.ScreenSaver /ScreenSaver org.freedesktop.ScreenSaver GetActive 2>/dev/null || true)
    hint=$(loginctl show-session "$display_session" -p LockedHint --value)
    if [[ "$locked" == 'b true' && "$hint" == yes ]]; then break; fi
    sleep .2
done
if [[ "$locked" != 'b true' || "$hint" != yes ]]; then
    journalctl --user -b -u kaze-lock.service -u kaze-hypridle.service --no-pager -n 40 >&2
    exit 1
fi
grep -F 'Got Lock from dbus' <<< "$(journalctl --user -b -u kaze-hypridle.service --no-pager)"
old_sig=$HYPRLAND_INSTANCE_SIGNATURE
old_bar=$(unit_pid kaze-waybar.service)
# Direct dispatcher (not the power menu) tests the shutdown hook.
hyprctl dispatch 'hl.dsp.exit()'
for _ in {1..30}; do
    new_sig=$(read_env HYPRLAND_INSTANCE_SIGNATURE)
    new_bar=$(unit_pid kaze-waybar.service)
    if [[ -n "$new_sig" && "$new_sig" != "$old_sig" && "$new_bar" != 0 && "$new_bar" != "$old_bar" ]]; then break; fi
    sleep .3
done
[[ -n "$new_sig" && "$new_sig" != "$old_sig" && "$new_bar" != 0 && "$new_bar" != "$old_bar" ]]
test ! -e "$db"
test ! -d "/proc/$old_bar"
test "$(read_env XDG_CURRENT_DESKTOP)" = Hyprland
echo '    Logout/login: new instance and bar PID; old process and clipboard removed'
GUEST

echo '==> Gate 2 session checks passed.'
if [[ "$stage2" == true ]]; then
    # shellcheck source=tests/vm-stage2.sh
    source "$REPO_DIR/tests/vm-stage2.sh"
    exercise_stage2
fi
stop_vm
if (( boot_status )); then
    echo 'vm-verify: at least one deployed cold boot missed the <20s SSH startup gate' >&2
fi
if (( samples > 0 )); then
    if (( bench_status )); then
        echo 'vm-verify: at least one cold T0 sample failed' >&2
    elif (( expected_t0 )); then
        echo "==> Gate 3 EXPECTED_UPSTREAM_FAIL ($expected_t0/$samples samples); the strict T0 gate has not passed."
    else
        echo "==> Gate 3 passed ($samples T0 samples; T1/T2 and hardware gates are separate)."
    fi
fi
if (( boot_status || bench_status )); then exit 1; fi
