#!/usr/bin/env bash
set -euo pipefail

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
VMDIR=""
if [ -n "${KAZE_VM_DIR:-}" ]; then
    VMDIR="$KAZE_VM_DIR"
else
    for cand in "$DATA_HOME/kaze-try-vm" "$DATA_HOME/shell-bench-vm"; do
        if [ -f "$cand/vm.pid" ] && kill -0 "$(<"$cand/vm.pid")" 2>/dev/null; then
            VMDIR="$cand"
            break
        fi
    done
    if [ -z "$VMDIR" ]; then
        if [ -f "$DATA_HOME/kaze-try-vm/bench_id_ed25519" ]; then
            VMDIR="$DATA_HOME/kaze-try-vm"
        else
            VMDIR="$DATA_HOME/shell-bench-vm"
        fi
    fi
fi

MONITOR="Virtual-2"
ACTION="plug"
MAX_FPS=30

usage() {
    cat <<EOF
Usage: $0 [--vm-dir <path>] [--replug|--unplug] [--fps <n>] [monitor-name]

Low-latency damage-driven viewer & HDMI hotplug simulator for the Arch VM:
  default     Plug Virtual-2 if disconnected (triggers kaze-display --hotplug
              menu on Virtual-1) and open a zero-buffer live viewer window.
  --replug    Unplug then re-plug Virtual-2 to re-trigger the HDMI hotplug menu
              even if Virtual-2 is already connected, then stream live.
  --unplug    Unplug Virtual-2 (triggers --on-disconnect recovery) and exit.
  --fps <n>   Max capture FPS when pixels change (default: 30; 0 FPS when idle).
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --vm-dir)
            if [ "$#" -lt 2 ]; then
                echo "watch-vm-monitor.sh: --vm-dir requires a path" >&2
                exit 2
            fi
            VMDIR="$2"
            shift 2
            ;;
        --replug|--hotplug)
            ACTION="replug"
            shift
            ;;
        --unplug|--disconnect)
            ACTION="unplug"
            shift
            ;;
        --fps)
            if [ "$#" -lt 2 ] || [[ ! "$2" =~ ^[0-9]+$ ]] || [ "$2" -lt 1 ] || [ "$2" -gt 120 ]; then
                echo "watch-vm-monitor.sh: --fps requires an integer between 1 and 120" >&2
                exit 2
            fi
            MAX_FPS="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "watch-vm-monitor.sh: unknown option '$1'" >&2
            usage >&2
            exit 2
            ;;
        *)
            MONITOR="$1"
            shift
            ;;
    esac
done

if [[ ! "$MONITOR" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "watch-vm-monitor.sh: invalid monitor name '$MONITOR'" >&2
    exit 2
fi

VIEWER=""
if command -v gst-launch-1.0 >/dev/null 2>&1 \
    && gst-inspect-1.0 --exists jpegparse 2>/dev/null \
    && gst-inspect-1.0 --exists jpegdec 2>/dev/null \
    && gst-inspect-1.0 --exists glimagesink 2>/dev/null; then
    VIEWER="gst"
elif command -v ffplay >/dev/null 2>&1; then
    VIEWER="ffplay"
else
    echo "watch-vm-monitor.sh: gst-launch-1.0 (or ffplay) is required on the host" >&2
    exit 1
fi

KEY="$VMDIR/bench_id_ed25519"
if [ ! -f "$KEY" ]; then
    echo "watch-vm-monitor.sh: missing SSH key at $KEY" >&2
    exit 1
fi

SSH_OPTS=(
    -T
    -i "$KEY"
    -p 22222
    -c aes128-gcm@openssh.com
    -o BatchMode=yes
    -o Compression=no
    -o IPQoS=lowdelay
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=5
    -o ServerAliveInterval=3
    -o ServerAliveCountMax=2
    -o LogLevel=ERROR
)

if [ "$ACTION" = "unplug" ]; then
    echo "Unplugging $MONITOR inside VM ($VMDIR)..."
    ssh "${SSH_OPTS[@]}" bench@127.0.0.1 bash -s -- "$MONITOR" <<'REMOTE_UNPLUG'
set -euo pipefail
MON="$1"
shopt -s nullglob
for status_file in /sys/class/drm/card*-"${MON}"/status; do
    if [ -f "$status_file" ]; then
        echo off | sudo tee "$status_file" >/dev/null
        sudo udevadm trigger --subsystem-match=drm --action=change
        break
    fi
done
REMOTE_UNPLUG
    echo "Unplugged $MONITOR."
    exit 0
fi

# Single-connection remote worker:
# 1. Plugs (or replugs) Virtual-2 via DRM sysfs so Hyprland fires `monitor.added`
#    and pops up `kaze-display --hotplug` natively on Virtual-1 (no manual
#    hl.monitor override that would race the hotplug menu or clobber mirror).
# 2. Streams damage-only slice-threaded MJPEG (`image2pipe`, 0% CPU & 0 VirGL
#    stalls when static; ~10-18ms latency on updates) and auto-reconnects across
#    mode switches / `hyprctl reload` until the host viewer window closes.
REMOTE_CMD=$(cat <<'EOF'
set -euo pipefail
MON="$1"
ACT="$2"
FPS="$3"

if ! command -v wf-recorder >/dev/null 2>&1; then
    sudo pacman -S --needed --noconfirm wf-recorder >/dev/null 2>&1
fi

shopt -s nullglob
for status_file in /sys/class/drm/card*-"${MON}"/status; do
    if [ -f "$status_file" ]; then
        cur="$(cat "$status_file" 2>/dev/null || echo disconnected)"
        if [ "$ACT" = "replug" ] && [ "$cur" = "connected" ]; then
            echo off | sudo tee "$status_file" >/dev/null
            sudo udevadm trigger --subsystem-match=drm --action=change
            sleep 0.5
            cur="disconnected"
        fi
        if [ "$cur" != "connected" ]; then
            echo on | sudo tee "$status_file" >/dev/null
            sudo udevadm trigger --subsystem-match=drm --action=change
        fi
        break
    fi
done
shopt -u nullglob

export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-1}"
HYPRLAND_INSTANCE_SIGNATURE="$(ls -1t "$XDG_RUNTIME_DIR/hypr" 2>/dev/null | head -n1 || true)"
export HYPRLAND_INSTANCE_SIGNATURE

# Wait briefly (polling every 100ms, max 3s) for Hyprland to enable the output.
for _ in $(seq 1 30); do
    if hyprctl -j monitors 2>/dev/null | grep -q "\"name\": *\"${MON}\""; then
        break
    fi
    sleep 0.1
done

FIFO="$(mktemp -u /tmp/kaze-vmon.XXXXXX.mjpeg)"
STOP_FILE="/tmp/kaze-vmon-stop.$$"
WPID_FILE="/tmp/kaze-vmon-wpid.$$"
mkfifo "$FIFO"
LOOP_PID=""

stop_recorder() {
    : > "$STOP_FILE"
    if [ -f "$WPID_FILE" ]; then
        local wpid
        wpid="$(cat "$WPID_FILE" 2>/dev/null || true)"
        if [ -n "$wpid" ]; then
            kill -INT "$wpid" 2>/dev/null || true
        fi
    fi
    if [ -n "$LOOP_PID" ]; then
        kill "$LOOP_PID" 2>/dev/null || true
    fi
}

cleanup() {
    stop_recorder
    rm -f "$FIFO" "$STOP_FILE" "$WPID_FILE"
}
trap cleanup EXIT INT TERM

# Keep write-end of FIFO open across wf-recorder restarts (e.g. mirror / hyprctl reload)
# so the host viewer window stays open seamlessly without EOF.
(
    exec 9<&- 2>/dev/null || true
    exec 4>"$FIFO"
    while [ ! -e "$STOP_FILE" ]; do
        if hyprctl -j monitors 2>/dev/null | grep -q "\"name\": *\"${MON}\""; then
            wf-recorder -y -r "$FPS" -o "$MON" \
                -c mjpeg -m image2pipe -x yuv420p \
                -p thread_type=slice -p threads=2 -p huffman=0 -p qmin=5 -p qmax=8 \
                -f "$FIFO" >/dev/null 2>&1 &
            rec_pid=$!
            printf '%s\n' "$rec_pid" > "$WPID_FILE"
            wait "$rec_pid" 2>/dev/null || true
            rm -f "$WPID_FILE"
        fi
        [ -e "$STOP_FILE" ] && break
        sleep 0.15
    done
) &
LOOP_PID=$!

# Instant teardown lifeline on FD 9 (SSH stdin): as soon as host closes viewer,
# unblock and terminate the capture loop even if 0 frames are moving.
(
    cat <&9 >/dev/null 2>&1 || true
    stop_recorder
    exec 3>"$FIFO" 2>/dev/null || true
    exec 3>&- 2>/dev/null || true
) &
WATCH_PID=$!
exec 9<&-

cat "$FIFO" || true
kill "$WATCH_PID" 2>/dev/null || true
EOF
)

REMOTE_B64="$(printf '%s' "$REMOTE_CMD" | base64 -w0)"
HOST_FIFO="$(mktemp -u "${TMPDIR:-/tmp}/kaze-host-vmon.XXXXXX")"
LIFE_FIFO="$(mktemp -u "${TMPDIR:-/tmp}/kaze-host-life.XXXXXX")"
mkfifo "$HOST_FIFO"
mkfifo "$LIFE_FIFO"
SSH_PID=""
LIFE_FD_OPEN=false

cleanup_host() {
    if [ "$LIFE_FD_OPEN" = true ]; then
        exec 3>&- 2>/dev/null || true
        LIFE_FD_OPEN=false
    fi
    if [ -n "$SSH_PID" ]; then
        kill "$SSH_PID" 2>/dev/null || true
    fi
    rm -f "$HOST_FIFO" "$LIFE_FIFO"
}
trap cleanup_host EXIT INT TERM

echo "Streaming $MONITOR from VM ($VMDIR, action=$ACTION, viewer=$VIEWER; close window to stop)..."
ssh "${SSH_OPTS[@]}" bench@127.0.0.1 \
    "exec 9<&0; printf '%s' '$REMOTE_B64' | base64 -d | bash -s -- '$MONITOR' '$ACTION' '$MAX_FPS'" \
    <"$LIFE_FIFO" >"$HOST_FIFO" &
SSH_PID=$!
exec 3>"$LIFE_FIFO"
LIFE_FD_OPEN=true

if [ "$VIEWER" = "gst" ]; then
    gst-launch-1.0 -q \
        fdsrc fd=0 blocksize=65536 ! \
        jpegparse ! \
        jpegdec ! \
        queue leaky=downstream max-size-buffers=1 ! \
        videoconvertscale ! \
        glimagesink force-aspect-ratio=true sync=false \
        <"$HOST_FIFO" || true
else
    ffplay -fflags nobuffer -flags low_delay -framedrop -vf setpts=0 -threads 1 -loglevel warning \
        -window_title "VM External Monitor ($MONITOR)" -f mjpeg -i "$HOST_FIFO" || true
fi
