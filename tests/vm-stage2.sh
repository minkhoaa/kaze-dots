#!/usr/bin/env bash
# Sourced by vm-verify.sh --stage2 on a throwaway guest overlay.
# shellcheck source=tests/vm-portal.sh
source "$REPO_DIR/tests/vm-portal.sh" # wait_clients

wait_app() {
    local app=$1
    for _ in {1..20}; do
        if in_session pgrep -x "$app" >/dev/null; then
            sleep .25 # allow the Wayland surface and keyboard grab to map
            return
        fi
        sleep .12
    done
    echo "Guest app did not launch: $app" >&2
    return 1
}

restore_osd_probe() {
    in_session 'if test -L "$HOME/.local/bin/kaze-osd.qa-original"; then mv -fT -- "$HOME/.local/bin/kaze-osd.qa-original" "$HOME/.local/bin/kaze-osd"; fi'
}

exercise_osd_repeat() {
    # Replace only the disposable guest's symlink with a timestamping wrapper.
    # The real CLI still executes; the test counts processes spawned by Hyprland.
    in_session bash -s <<'GUEST'
set -euo pipefail
cli="$HOME/.local/bin/kaze-osd"
test -L "$cli"
mv -- "$cli" "$cli.qa-original"
{ printf '%s\n' '#!/bin/sh' 'date +%s%N >> "$XDG_RUNTIME_DIR/kaze/osd-qa.log"';
  printf '%s\n' 'exec "$HOME/.local/bin/kaze-osd.qa-original" "$@"'; } > "$cli"
chmod 700 "$cli"
rm -f -- "$XDG_RUNTIME_DIR/kaze/osd-qa.log"
GUEST
    if ! qmp key --seconds 3 volumeup; then restore_osd_probe; return 1; fi
    restore_osd_probe
    in_session bash -s <<'GUEST'
set -euo pipefail
python3 - "$XDG_RUNTIME_DIR/kaze/osd-qa.log" <<'PY'
import pathlib
import sys

stamps = sorted(map(int, pathlib.Path(sys.argv[1]).read_text().splitlines()))
assert 2 <= len(stamps) <= 38, stamps
minimum = min(b - a for a, b in zip(stamps, stamps[1:])) / 1e6
assert minimum >= 65, minimum  # Allow guest process-scheduling jitter, not 35 Hz respawn.
print(f"    Held volume key 3s: {len(stamps)} spawns, shortest gap {minimum:.1f} ms")
PY
GUEST
    sleep 1.6
}

record_qa() { in_session 'env XDG_CONFIG_HOME=$HOME/.cache/kaze-stage2-qa/xdg kaze-record' "$@"; }
verify_clip() {
    local path=$1 width=$2 height=$3 quoted
    printf -v quoted '%q' "$path"
    [[ $(in_session ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$quoted") == "$width,$height" ]]
    in_session timeout 15s ffmpeg -nostdin -v error -xerror -i "$quoted" -frames:v 5 -f null -
}

wait_next_session() {
    local old=$1 current
    for _ in {1..45}; do
        current=$(in_session printenv HYPRLAND_INSTANCE_SIGNATURE 2>/dev/null || true)
        if [[ -n "$current" && "$current" != "$old" ]]; then wait_session; return; fi
        sleep .3
    done
    echo 'Hyprland did not start a fresh session' >&2
    return 1
}

exercise_stage2() {
    local out cap bar layout shape clip session pending qpath key outcome invocation
    out=$(mktemp -d /tmp/kaze-utilities.XXXXXXXX)
    echo "==> [Stage 2] Capture/recording, optional services and all-on geometry: $out"
    in_session bash -s <<'GUEST'
set -euo pipefail
for unit in record night inhibit; do
    test "$(kaze-"$unit" status)" = off
    if systemctl --user is-active --quiet "kaze-$unit.service"; then exit 1; fi
done
if pgrep -x wf-recorder || pgrep -x hyprsunset; then exit 1; fi
fixture="$HOME/.cache/kaze-stage2-qa"
rm -rf -- "$fixture"
mkdir -p -- "$fixture/xdg"
printf 'XDG_VIDEOS_DIR="%s/Video Space"\n' "$fixture" > "$fixture/xdg/user-dirs.dirs"
printf 'cancel clipboard sentinel' | wl-copy --type text/plain >/dev/null 2>&1
GUEST

    # Real Escape in each selector. Failed/cancelled picks cannot change
    # clipboard ownership, leave a capture PNG/MP4, or send a success toast.
    for cap in annotate color record; do
        echo "    Checking Escape: $cap"
        case "$cap" in
            annotate) in_session timeout 15s kaze-screenshot region --annotate & ;;
            color) in_session timeout 15s kaze-screenshot color & ;;
            record) record_qa --region & ;;
        esac
        pending=$!
        if [[ "$cap" == color ]]; then wait_app hyprpicker; else wait_app slurp; fi
        if [[ "$cap" == record ]]; then
            record_qa # held flock: this second invocation must be a no-op
            [[ $(in_session kaze-record status) == off ]]
        fi
        qmp key esc
        wait "$pending"
        [[ $(in_session wl-paste -n --type text/plain) == 'cancel clipboard sentinel' ]]
        if in_session hyprctl layers | grep -q 'namespace: notifications'; then
            echo "Unexpected toast after cancel: $cap" >&2
            return 1
        fi
    done
    in_session 'test ! -e "$HOME/.cache/kaze-stage2-qa/Video Space"'
    [[ -z $(in_session 'find "$XDG_RUNTIME_DIR/kaze" -maxdepth 1 -name "screenshot.*.png" -print') ]]
    echo '    Esc: annotate, pick color, record region; overlapping recorder toggle ignored'

    in_session timeout 20s kaze-screenshot region --annotate & pending=$!
    wait_app slurp
    qmp drag 220 250 732 538
    wait_clients 'class: .*swappy'
    in_session grim - > "$out/swappy.png"
    qmp key meta_l q
    wait "$pending"
    [[ -z $(in_session 'find "$XDG_RUNTIME_DIR/kaze" -maxdepth 1 -name "screenshot.*.png" -print') ]]
    [[ $(in_session wl-paste -n --type text/plain) == 'cancel clipboard sentinel' ]]

    in_session timeout 15s kaze-screenshot color & pending=$!
    wait_app hyprpicker
    qmp click 640 320
    wait "$pending"
    [[ $(in_session wl-paste -n --type text/plain) =~ ^#[[:xdigit:]]{6}$ ]]
    in_session hyprctl layers | grep 'namespace: notifications'
    in_session grim - > "$out/color.png"
    sleep 2.3
    exercise_osd_repeat

    in_session bash -s <<'GUEST'
set -euo pipefail
qa="$HOME/.cache/kaze-stage2-qa"
cd ~/kaze-dots
cc -O2 -Wall -Wextra -Werror -o "$qa/mpris" tests/vm-mpris.c $(pkg-config --cflags --libs gio-2.0)
systemd-run --user --unit=kaze-qa-mpris "$qa/mpris"
kaze-night on
kaze-inhibit on
test "$(kaze-night status)" = on
test "$(kaze-inhibit status)" = on
systemd-inhibit --list --no-pager | grep -E '^Kaze[[:space:]].*[[:space:]]idle[[:space:]].*User inhibit.*block'
test "$(systemctl --user show kaze-inhibit.service -p RuntimeMaxUSec --value)" = 2h
night=$(systemctl --user show kaze-night.service -p MainPID --value)
tr '\0' '\n' < "/proc/$night/cmdline" | grep -Fx 4500
playerctl --player=kaze_qa status | grep -Fx Playing
GUEST
    record_qa
    [[ $(in_session kaze-record status) == on ]]
    for layout in sidebar islands slim; do
        case "$layout" in
            sidebar) shape='8 8 42 1064' ;;
            islands) shape='10 6 1900 34' ;;
            slim) shape='0 0 1920 28' ;;
        esac
        in_session kaze-layout --quiet "$layout"
        sleep .35
        in_session hyprctl layers | grep -E "xywh: $shape, .*namespace: waybar"
        [[ -z $(in_session hyprctl configerrors) ]]
        for cap in record night inhibit; do [[ $(in_session kaze-"$cap" status) == on ]]; done
        in_session grim - > "$out/$layout-on.png"
    done
    clip=$(record_qa stop)
    verify_clip "$clip" 1920 1080
    printf '    Finalized after SIGINT, decoded 1920x1080: %s\n' "$clip"
    [[ $clip == *'/Video Space/Recordings/'*.mp4 ]]

    # Select a real region and check the output differs from full-screen capture.
    record_qa --region & pending=$!
    wait_app slurp
    qmp drag 220 250 732 538
    wait "$pending"
    qmp move 745 550
    sleep 1
    clip=$(record_qa stop)
    printf -v qpath '%q' "$clip"
    shape=$(in_session ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$qpath")
    [[ $shape =~ ^[0-9]+,[0-9]+$ && $shape != '1920,1080' ]]
    verify_clip "$clip" "${shape%,*}" "${shape#*,}"
    echo "    Region video decoded ($shape)"

    in_session kaze-layout --quiet sidebar
    bar=$(in_session systemctl --user show -p MainPID --value kaze-waybar.service)
    record_qa
    sleep 1
    in_session kill -KILL '"$(systemctl --user show -p MainPID --value kaze-record.service)"'
    sleep .6
    [[ $(in_session kaze-record status) == off ]]
    if record_qa stop > "$out/crashed-stop.out" 2> "$out/crashed-stop.err"; then
        echo 'Stopping the crashed recorder spuriously succeeded' >&2
        return 1
    fi
    grep -i 'may be incomplete' "$out/crashed-stop.err"
    [[ ! -s "$out/crashed-stop.out" ]]
    in_session grim - > "$out/after-record-crash.png"
    in_session kill -KILL '"$(systemctl --user show -p MainPID --value kaze-night.service)"'
    sleep .35
    [[ $(in_session kaze-night status) == off ]]
    [[ $(in_session systemctl --user show -p MainPID --value kaze-waybar.service) == "$bar" ]]
    in_session grim - > "$out/after-night-crash.png"

    in_session bash -s < "$REPO_DIR/tests/vm-inhibit-qa.sh"
    in_session grim - > "$out/after-inhibit-expiry.png"
    in_session systemctl --user stop kaze-qa-mpris.service

    # Use a real second compositor output, not a mocked monitor response.
    in_session hyprctl output create headless KazeQA
    in_session hyprctl monitors | grep -F 'Monitor KazeQA '
    in_session "hyprctl dispatch 'hl.dsp.focus({ monitor=\"KazeQA\" })'"
    record_qa
    sleep .8
    in_session 'tr "\0" "\n" </proc/$(systemctl --user show -p MainPID --value kaze-record.service)/cmdline' | grep -Fx KazeQA
    in_session hyprctl output remove KazeQA
    sleep .5
    if clip=$(record_qa stop 2> "$out/output-removal.err"); then
        # The encoder may already have shut down after removing the output.
        if [[ -n "$clip" ]]; then
            printf -v qpath '%q' "$clip"
            in_session ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$qpath"
        fi
    else
        grep -i 'may be incomplete' "$out/output-removal.err"
    fi
    [[ $(in_session kaze-record status) == off ]]
    in_session 'journalctl --user -b -u kaze-record.service --no-pager -n 80' > "$out/output-removal-journal.log"
    echo '    Selected second output; removing it did not leave a recorder after stop'

    # Logout runs the recorder stop job before stopping the other target units.
    sleep .5
    record_qa
    qmp move 809 534
    sleep 1
    session=$(in_session printenv HYPRLAND_INSTANCE_SIGNATURE)
    # Read the real active file from argv, not a predicted timestamp.
    clip=$(in_session 'tr "\0" "\n" </proc/$(systemctl --user show -p MainPID --value kaze-record.service)/cmdline | tail -n 1')
    in_session kaze-night on
    in_session kaze-inhibit on
    in_session timeout 22s kaze-power & pending=$!
    wait_app fuzzel
    for key in l o g o u t; do qmp key "$key"; done
    qmp key ret
    wait "$pending"
    wait_next_session "$session"
    [[ $(in_session kaze-record status) == off && $(in_session kaze-night status) == off && $(in_session kaze-inhibit status) == off ]]
    verify_clip "$clip" 1920 1080
    echo '    Recording finalized at logout; on-demand units did not survive login'

    # Also use the direct compositor exit, which exercises the shutdown hook.
    record_qa
    qmp move 701 580
    sleep 1
    session=$(in_session printenv HYPRLAND_INSTANCE_SIGNATURE)
    clip=$(in_session 'tr "\0" "\n" </proc/$(systemctl --user show -p MainPID --value kaze-record.service)/cmdline | tail -n 1')
    invocation=$(in_session systemctl --user show -p InvocationID --value kaze-record.service)
    outcome=0
    in_session "timeout 18s hyprctl dispatch 'hl.dsp.exit()'" || outcome=$?
    wait_next_session "$session"
    [[ $(in_session kaze-record status) == off ]]
    verify_clip "$clip" 1920 1080
    # Direct IPC exit can pause Wayland dispatch while the hook runs. The
    # encoder can write the trailer on SIGINT even if the main thread times out.
    in_session journalctl --user -o cat --no-pager "_SYSTEMD_INVOCATION_ID=$invocation" > "$out/shutdown-recorder.log"
    if (( outcome )); then grep -F 'Recording may be incomplete' "$out/shutdown-recorder.log"; fi
    echo "    Shutdown hook left a decodable MP4 and no recorder (IPC status $outcome). Evidence: $out"
}
