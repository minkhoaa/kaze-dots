#!/usr/bin/env bash
set -euo pipefail

# Stage 4 Full Arch KVM Acceptance Gate for standalone kaze-shell (zero Noctalia):
# - Zero Noctalia in disposable CoW overlay; separate security units (hypridle, hyprpolkitagent, cliphist)
# - Gate 1 (T0 Cold Boot): kaze-shell PSS <= 45 MiB, shell+session <= 75 MiB, CPU <= 0.20%, CS <= 4.0/s, <= 5 threads, 0 portals
# - Gate 2 (Diagnostics): kaze-shell inspect, kaze-shell doctor, kaze-doctor (0 FAIL, 0 orphan noctalia)
# - Gate 3 (Animations & Zero-Idle): 20x layout-next + 50x island-toggle + 30x cc-toggle -> animating_surfaces=0, CPU <= 0.05%, 0 leak
# - Gate 4 (Wallpaper, 4 Layout Presets, Dynamic Island, MPRIS, kaze-display/record, Absorption & kaze-share isolation)
# - Gate 5 (Control Center, Caffeine, Night Light, System Tray SNI+DBusMenu, Clipboard, dmenu & detached App Launcher)
# - Gate 6 (Hot-Reload Resilience & 20x kaze-share + 10x hyprctl reload stress test)
# - Visual Audit: grim PNGs for omarchy, island, swiss, ghost-peek, cc, and tray-menu

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

echo "==> Staging standalone kaze-dots + kaze-shell (zero Noctalia) in disposable Arch KVM overlay (1920x1080)"
boot_vm staging
stage_guest
ssh_guest 'bash -s' <<'GUEST'
set -euo pipefail
export XDG_RUNTIME_DIR="/run/user/$(id -u)" LC_ALL=C.UTF-8

# 1. Remove Noctalia + all 9 replaced external helper binaries inside disposable overlay
for pkg in noctalia noctalia-shell noctalia-greeter hyprlock hypridle hyprpolkitagent cliphist grim slurp hyprpicker hyprsunset brightnessctl; do
    if pacman -Qq "$pkg" >/dev/null 2>&1; then
        sudo pacman -Rns --noconfirm "$pkg" >/dev/null 2>&1 || sudo pacman -Rdd --noconfirm "$pkg" >/dev/null 2>&1 || true
    fi
done
missing=()
for pkg in python-dbus python-gobject; do
    if ! pacman -Qq "$pkg" >/dev/null 2>&1; then
        missing+=("$pkg")
    fi
done
if (( ${#missing[@]} > 0 )); then
    echo "    installing test helpers in disposable overlay: ${missing[*]}"
    sudo pacman -Sy --noconfirm --needed "${missing[@]}" >/dev/null
fi
for removed in noctalia hyprlock hypridle hyprpolkitagent cliphist grim slurp hyprpicker hyprsunset brightnessctl; do
    if command -v "$removed" >/dev/null 2>&1; then
        echo "FAIL: replaced binary '$removed' still present in PATH" >&2
        exit 1
    fi
done

# 2. Ensure unattended tty1 autologin into Hyprland inside the disposable overlay
sudo systemctl disable --now greetd.service >/dev/null 2>&1 || true
sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf >/dev/null <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --noclear --autologin bench %I $TERM
EOF
sudo systemctl enable getty@tty1.service >/dev/null 2>&1 || true

# 3. Clean minimal baseline + apply.sh
mkdir -p "$HOME/.config/kaze" "$HOME/.config/hypr"
printf 'minimal\n' > "$HOME/.config/kaze/profile"
printf 'return {}\n' > "$HOME/.config/hypr/user.lua"
rm -f "$HOME/.config/kaze-shell/config.toml" "$HOME/.config/systemd/user/kaze-noctalia.service"
rm -f "$HOME/.local/state/kaze/layout-state.toml"
"$HOME/kaze-dots/scripts/apply.sh" --yes
test -x "$HOME/.local/bin/kaze-shell"
"$HOME/.local/bin/kaze-shell" doctor --offline
GUEST
stop_vm

bench_status=0
if (( samples > 0 )); then
    for (( i=1; i<=samples; i++ )); do
        stop_vm
        echo "==> [Gate 1] Cold T0 resource budget sample $i/$samples (standalone kaze-shell, zero Noctalia)"
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

echo "==> [Gates 2-6] Diagnostics, Animation Zero-Idle, Multi-Layout, Island, CC, Tray, Wallpaper, Stress & Grim Shots"
ssh_guest 'bash -s' <<'GUEST'
set -euo pipefail
trap 'rc=$?; echo "FAIL at guest line $LINENO (rc=$rc): $BASH_COMMAND" >&2; cat /tmp/mock_mpris.log /tmp/mock_sni.log 2>/dev/null || true' ERR
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

# --- Gate 2: Standalone Diagnostics & Security Boundary ---
for removed in noctalia hyprlock hypridle cliphist grim slurp hyprpicker hyprsunset brightnessctl; do
    ! command -v "$removed" >/dev/null 2>&1
    test "$(pgrep -xc "$removed" || true)" -eq 0
done
test -z "$(hyprctl configerrors)"
foot --check-config
test "$(kaze-shell msg ping)" = "pong"
wait_layer_present "kaze-bar-Virtual-1"

test "$(systemctl --user is-active kaze-shell.service)" = "active"

initial_pid=$(systemctl --user show -p MainPID --value kaze-shell.service)
test "$initial_pid" -gt 1
thread_count=$(ls "/proc/$initial_pid/task" | wc -l)
echo "    baseline PID=$initial_pid threads=$thread_count (budget <= 6)"
if (( thread_count > 6 )); then
    echo "FAIL: kaze-shell exceeded thread budget ($thread_count > 6)" >&2
    exit 1
fi

kaze-shell config validate "$HOME/.config/kaze-shell/config.toml"
inspect_json=$(kaze-shell inspect)
echo "$inspect_json" | grep -Fq '"hypr_connected": true'
echo "$inspect_json" | grep -Fq '"notifications_bus_owned": true'
echo "$inspect_json" | grep -Fq '"tray_bus_owned": true'
echo "$inspect_json" | grep -Fq '"polkit_bus_owned": true'
echo "$inspect_json" | grep -Fq '"has_data_control": true'
echo "$inspect_json" | grep -Fq '"has_idle_notify": true'
echo "$inspect_json" | grep -Fq '"has_screencopy": true'
echo "$inspect_json" | grep -Fq '"animating_surfaces": 0'
kaze-shell doctor
kaze-doctor
echo "    [PASS] Gate 2: zero Noctalia/helpers, single kaze-shell unit active, inspect + doctor PASS"

# --- Gate 3: Animation Zero-Idle & Leak Gate (20x layout-next + 50x island-toggle + 30x cc-toggle) ---
# Warm up once so lazy font/surface pools stabilize before leak measurement
kaze-shell msg layout-set island >/dev/null
wait_layer_present "kaze-island"
kaze-shell msg island-toggle >/dev/null
sleep 0.15
kaze-shell msg island-toggle >/dev/null
kaze-shell msg cc-toggle >/dev/null
wait_layer_present "kaze-cc"
kaze-shell msg cc-toggle >/dev/null
wait_layer_absent "kaze-cc"
kaze-shell msg layout-set omarchy >/dev/null
wait_layer_present "kaze-bar-Virtual-1"
sleep 0.5

anim_pss_start=$(read_pss_kib "$initial_pid")
for _ in $(seq 1 20); do
    kaze-shell msg layout-next >/dev/null
    sleep 0.03
done
kaze-shell msg layout-set island >/dev/null
wait_layer_present "kaze-island"
for _ in $(seq 1 50); do
    kaze-shell msg island-toggle >/dev/null
    sleep 0.02
done
kaze-shell msg layout-set omarchy >/dev/null
wait_layer_present "kaze-bar-Virtual-1"
for _ in $(seq 1 30); do
    kaze-shell msg cc-toggle >/dev/null
    sleep 0.02
done
kaze-shell msg cc-close >/dev/null
wait_layer_absent "kaze-cc"

# Wait 5s for damped springs to converge and stop requesting wl_surface.frame()
sleep 5
post_anim=$(kaze-shell inspect)
echo "$post_anim" | grep -Fq '"animating_surfaces": 0'
echo "$post_anim" | grep -Fq '"surface_count": 1'
anim_pss_end=$(read_pss_kib "$initial_pid")
anim_pss_delta=$(( anim_pss_end - anim_pss_start ))
printf '    animation cycle PSS: start=%s KiB end=%s KiB (delta=%+d KiB)\n' "$anim_pss_start" "$anim_pss_end" "$anim_pss_delta"
if (( anim_pss_delta > 4096 )); then
    echo "FAIL: PSS grew by ${anim_pss_delta} KiB across 20x layout + 50x island + 30x cc cycles" >&2
    exit 1
fi

# Verify post-animation CPU settles to <= 0.05% over 10s
cpu_post=$(python3 - "$initial_pid" <<'PY'
import os, sys, time
pid = int(sys.argv[1])
hz = os.sysconf(os.sysconf_names["SC_CLK_TCK"])
def ticks(p):
    with open(f"/proc/{p}/stat") as f:
        s = f.read()
    rest = s[s.rfind(")") + 2:].split()
    return int(rest[11]) + int(rest[12])
t0 = ticks(pid)
w0 = time.monotonic()
time.sleep(10.0)
dt = time.monotonic() - w0
pct = ((ticks(pid) - t0) / hz) / dt * 100.0
print(f"{pct:.3f}")
sys.exit(0 if pct <= 0.05 else 1)
PY
)
echo "    post-animation 10s idle CPU=${cpu_post}% (budget <= 0.05%)"
echo "    [PASS] Gate 3: 20x layout + 50x island + 30x cc -> 0 animating surfaces, ${cpu_post}% CPU, 0 leak"

# --- Gate 4: Wallpaper + Dynamic Palette + All 4 Presets + Dynamic Island + MPRIS + Absorption + kaze-share ---
wall_img="$HOME/Pictures/Wallpapers/05-kanagawa.jpg"
test -f "$wall_img"
kaze-shell msg wallpaper-set "$wall_img" >/dev/null
wait_layer_present "kaze-wallpaper-Virtual-1"
sleep 0.35
wall_inspect=$(kaze-shell inspect)
echo "$wall_inspect" | grep -Fq '"wallpaper_count": 1'
echo "$wall_inspect" | grep -Fq '"palette": "Dynamic:05-kanagawa"'
for target in \
    "$HOME/.config/hypr/kaze-theme.lua" \
    "$HOME/.config/foot/themes/kaze-shell" \
    "$HOME/.config/gtk-3.0/kaze-shell.css" \
    "$HOME/.config/gtk-4.0/kaze-shell.css" \
    "$HOME/.config/btop/themes/kaze-shell.theme"; do
    test -s "$target"
done
wall_pss_kib=$(read_pss_kib "$initial_pid")
echo "    1080p wallpaper PSS=${wall_pss_kib} KiB (budget <= 61440 KiB / 60 MiB)"
if (( wall_pss_kib > 61440 )); then
    echo "FAIL: 1080p wallpaper PSS exceeded 60 MiB (${wall_pss_kib} KiB)" >&2
    exit 1
fi

# Shot 1: omarchy preset with 1080p wallpaper + Vietnamese/Emoji notification
notify-send -a "Zalo" -u normal -t 15000 "Tin nhắn tiếng Việt 🎉" "Chào bạn! Dấu tiếng Việt ệ ồ ử ặ + Emoji 🚀🔥" >/dev/null
wait_layer_present "kaze-notify"
sleep 0.25
kaze-shell msg capture output Virtual-1 --save-only /tmp/shot-01-omarchy.png >/dev/null
kaze-shell msg notify-clear >/dev/null
wait_layer_absent "kaze-notify"

# Shot 2: island preset + mock MPRIS2 + kaze-display virtual-share + record activity + expanded Dynamic Island
kaze-shell msg layout-set island >/dev/null
wait_layer_present "kaze-island"
test "$(hyprctl -j getoption decoration:rounding | python3 -c 'import json,sys; print(json.load(sys.stdin)["int"])')" -eq 12

cat > /tmp/mock_mpris.py <<'PY'
import dbus, dbus.service, dbus.mainloop.glib
from gi.repository import GLib

dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
bus = dbus.SessionBus()
name = dbus.service.BusName("org.mpris.MediaPlayer2.kaze_demo", bus)

class Player(dbus.service.Object):
    def __init__(self):
        super().__init__(bus, "/org/mpris/MediaPlayer2")
        self.props = {
            "org.mpris.MediaPlayer2": {"Identity": "Kaze Demo Player"},
            "org.mpris.MediaPlayer2.Player": {
                "PlaybackStatus": "Playing",
                "Rate": dbus.Double(1.0),
                "Position": dbus.Int64(68_000_000),
                "Metadata": dbus.Dictionary({
                    "xesam:title": dbus.String("Lạc Trôi (Tiếng Việt) 🌊"),
                    "xesam:artist": dbus.Array([dbus.String("Sơn Tùng M-TP")], signature="s"),
                    "mpris:length": dbus.Int64(233_000_000),
                }, signature="sv"),
            },
        }
    @dbus.service.method("org.freedesktop.DBus.Properties", in_signature="ss", out_signature="v")
    def Get(self, iface, prop):
        return self.props[iface][prop]
    @dbus.service.method("org.freedesktop.DBus.Properties", in_signature="s", out_signature="a{sv}")
    def GetAll(self, iface):
        return self.props[iface]
    @dbus.service.method("org.mpris.MediaPlayer2.Player")
    def PlayPause(self):
        pass

Player()
GLib.MainLoop().run()
PY
python3 /tmp/mock_mpris.py </dev/null >/tmp/mock_mpris.log 2>&1 &
mpris_pid=$!

for _ in {1..30}; do
    if kaze-shell inspect | grep -Fq '"active": true'; then
        break
    fi
    sleep 0.1
done
kaze-shell inspect | grep -Fq 'Sơn Tùng'

kaze-display virtual-share 9
sleep 0.35
# kaze-share must NEVER have bar, island, or wallpaper
! hyprctl layers | grep -Fq "namespace: kaze-bar-kaze-share"
! hyprctl layers | grep -Fq "namespace: kaze-wallpaper-kaze-share"
now_s=$(date +%s)
kaze-shell msg island-activity record "{\"active\":true,\"started_at\":${now_s},\"audio\":true,\"gif\":false}" >/dev/null
sleep 0.3
kaze-shell msg island-toggle >/dev/null
sleep 0.55
island_inspect=$(kaze-shell inspect)
echo "$island_inspect" | grep -Fq '"island_expanded": true'
echo "$island_inspect" | grep -Fq '"display"'
echo "$island_inspect" | grep -Fq '"record"'
kaze-shell msg capture output Virtual-1 --save-only /tmp/shot-02-island.png >/dev/null

# Verify notification absorption in island preset (normal absorbed, critical bypasses DND)
kaze-shell msg island-toggle >/dev/null
sleep 0.35
notify-send -a "Mail" -u normal -t 4000 "Thư mới ✉️" "Hấp thụ vào Dynamic Island" >/dev/null
sleep 0.25
! hyprctl layers | grep -Fq "namespace: kaze-notify"
test "$(kaze-shell msg dnd-on)" = "on"
notify-send -a "Hệ thống" -u critical "Cảnh báo pin ⚠️" "Critical vượt qua DND 🔴" >/dev/null
wait_layer_present "kaze-notify"
kaze-shell msg notify-clear >/dev/null
wait_layer_absent "kaze-notify"
test "$(kaze-shell msg dnd-off)" = "off"

kaze-shell msg island-clear record >/dev/null
kaze-display stop-virtual
kill "$mpris_pid" 2>/dev/null || true
wait "$mpris_pid" 2>/dev/null || true
sleep 0.25

# Shot 3: swiss preset (30px text-only hairline bar, rounding=0)
kaze-shell msg layout-set swiss >/dev/null
wait_layer_present "kaze-bar-Virtual-1"
wait_layer_absent "kaze-island"
test "$(hyprctl -j getoption decoration:rounding | python3 -c 'import json,sys; print(json.load(sys.stdin)["int"])')" -eq 0
sleep 0.25
kaze-shell msg capture output Virtual-1 --save-only /tmp/shot-03-swiss.png >/dev/null

# Shot 4: ghost preset + bar-peek on/off
kaze-shell msg layout-set ghost >/dev/null
wait_layer_absent "kaze-bar-Virtual-1"
kaze-shell msg bar-peek on >/dev/null
wait_layer_present "kaze-bar-Virtual-1"
sleep 0.25
kaze-shell msg capture output Virtual-1 --save-only /tmp/shot-04-ghost-peek.png >/dev/null
kaze-shell msg bar-peek off >/dev/null
wait_layer_absent "kaze-bar-Virtual-1"

echo "    [PASS] Gate 4: Wallpaper/Dynamic palette + 4 presets + Island + MPRIS + Absorption + kaze-share isolation"

# --- Gate 5: Control Center, Caffeine, Night Light, Clipboard, System Tray (SNI+DBusMenu), dmenu & App Launcher ---
kaze-shell msg layout-set omarchy >/dev/null
wait_layer_present "kaze-bar-Virtual-1"
test "$(kaze-shell msg caffeine-toggle)" = "on"
test "$(kaze-shell msg nightlight-set 4000)" = "on 4000K"
test "$(kaze-shell msg nightlight-status)" = "on 4000K"
notify-send -a "Lịch" -u normal -t 15000 "Họp nhóm 10:00 📅" "Kiểm thử Control Center Tiếng Việt ✅" >/dev/null
notify-send -a "Git" -u low -t 15000 "Build thành công 🚀" "62/62 unit tests passed" >/dev/null
sleep 0.25
kaze-shell msg cc-open >/dev/null
wait_layer_present "kaze-cc"
sleep 0.3
kaze-shell msg capture output Virtual-1 --save-only /tmp/shot-05-cc.png >/dev/null
kaze-shell msg cc-close >/dev/null
wait_layer_absent "kaze-cc"
kaze-shell msg notify-clear >/dev/null
wait_layer_absent "kaze-notify"
test "$(kaze-shell msg nightlight-toggle)" = "off"
test "$(kaze-shell msg caffeine-toggle)" = "off"

# Native Wayland clipboard history + encrypted disk store + zero plaintext
wl-copy 'Kaze Stage 5C Tiếng Việt 🚀' </dev/null >/dev/null 2>&1
sleep 0.35
kaze-shell msg clipboard-list | grep -Fq 'Kaze Stage 5C'
enc_clip="${XDG_STATE_HOME:-$HOME/.local/state}/kaze/clipboard.enc"
if [[ -f "$enc_clip" ]]; then
    ! grep -Fq 'Kaze Stage 5C' "$enc_clip"
fi
kaze-shell msg clipboard-toggle >/dev/null
wait_layer_present "kaze-clipboard"
kaze-shell msg clipboard-toggle >/dev/null
wait_layer_absent "kaze-clipboard"
pkill -x wl-copy 2>/dev/null || true

# Offline mode toggle, session menu, annotate CLI (--blur + --backdrop)
off_init=$(kaze-shell msg offline-mode-status)
off_want=$([ "$off_init" = "on" ] && echo "off" || echo "on")
test "$(kaze-shell msg offline-mode-toggle)" = "$off_want"
test "$(kaze-shell msg offline-mode-toggle)" = "$off_init"
kaze-shell msg session-menu-toggle >/dev/null
wait_layer_present "kaze-session-menu"
kaze-shell msg session-menu-toggle >/dev/null
wait_layer_absent "kaze-session-menu"
test -s /tmp/shot-01-omarchy.png
kaze-shell annotate /tmp/shot-01-omarchy.png --blur 20,20,80,80 --backdrop 24 --output /tmp/shot-01-annotated.png >/dev/null
python3 - <<'PY'
import struct
def png_dims(p):
    with open(p, "rb") as f:
        hdr = f.read(24)
    return struct.unpack(">II", hdr[16:24])
ow, oh = png_dims("/tmp/shot-01-omarchy.png")
aw, ah = png_dims("/tmp/shot-01-annotated.png")
assert (aw, ah) == (ow + 48, oh + 48), f"expected ({ow+48},{oh+48}), got ({aw},{ah})"
PY
! kaze-shell annotate /nonexistent/kaze-missing.png >/dev/null 2>&1

# Real SNI (IconPixmap) + com.canonical.dbusmenu popup test
cat > /tmp/mock_sni.py <<'PY'
import dbus, dbus.service, dbus.mainloop.glib
from gi.repository import GLib

dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
bus = dbus.SessionBus()
bus_name = dbus.service.BusName("org.kde.StatusNotifierItem-kaze-demo", bus)

# 22x22 rounded cyan/teal badge in ARGB32 network byte order
w, h = 22, 22
buf = bytearray()
for y in range(h):
    for x in range(w):
        dx, dy = x - 10.5, y - 10.5
        r2 = dx * dx + dy * dy
        if r2 <= 81.0:
            if r2 <= 16.0:
                buf.extend((0xFF, 0x1F, 0x1F, 0x28))
            else:
                buf.extend((0xFF, 0x7E, 0x9C, 0xD8))
        else:
            buf.extend((0x00, 0x00, 0x00, 0x00))

class TrayItem(dbus.service.Object):
    def __init__(self):
        super().__init__(bus, "/StatusNotifierItem")
        self.props = {
            "Id": dbus.String("kaze-demo-tray"),
            "Category": dbus.String("ApplicationStatus"),
            "Title": dbus.String("Kaze Tray Demo"),
            "Status": dbus.String("Active"),
            "IconName": dbus.String(""),
            "IconThemePath": dbus.String(""),
            "Menu": dbus.ObjectPath("/MenuBar"),
            "IconPixmap": dbus.Array([dbus.Struct((dbus.Int32(w), dbus.Int32(h), dbus.ByteArray(bytes(buf))), signature="iiay")], signature="(iiay)"),
        }
    @dbus.service.method("org.freedesktop.DBus.Properties", in_signature="ss", out_signature="v")
    def Get(self, iface, prop):
        return self.props[prop]
    @dbus.service.method("org.freedesktop.DBus.Properties", in_signature="s", out_signature="a{sv}")
    def GetAll(self, iface):
        return self.props

class Menu(dbus.service.Object):
    def __init__(self):
        super().__init__(bus, "/MenuBar")
    @dbus.service.method("com.canonical.dbusmenu", in_signature="iias", out_signature="u(ia{sv}av)")
    def GetLayout(self, parent_id, recursion_depth, props):
        def item(mid, label, enabled=True, sep=False):
            d = dbus.Dictionary({"visible": dbus.Boolean(True), "enabled": dbus.Boolean(enabled)}, signature="sv")
            if sep:
                d["type"] = dbus.String("separator")
            else:
                d["label"] = dbus.String(label)
            return dbus.Struct((dbus.Int32(mid), d, dbus.Array([], signature="v")), signature="ia{sv}av")
        children = dbus.Array([
            item(1, "_Mở Bảng Điều Khiển"),
            item(2, "Trạng thái: Đang chạy ✓", enabled=False),
            item(3, "", sep=True),
            item(4, "_Thoát Ứng Dụng"),
        ], signature="v")
        root = dbus.Struct((dbus.Int32(0), dbus.Dictionary({"children-display": dbus.String("submenu")}, signature="sv"), children), signature="ia{sv}av")
        return (dbus.UInt32(1), root)
    @dbus.service.method("com.canonical.dbusmenu", in_signature="isvu", out_signature="")
    def Event(self, mid, event_id, data, ts):
        pass

TrayItem()
Menu()
watcher = bus.get_object("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher")
dbus.Interface(watcher, "org.kde.StatusNotifierWatcher").RegisterStatusNotifierItem("/StatusNotifierItem")
GLib.MainLoop().run()
PY
python3 /tmp/mock_sni.py </dev/null >/tmp/mock_sni.log 2>&1 &
sni_pid=$!

for _ in {1..30}; do
    if kaze-shell inspect | grep -Fq '"tray_items_count": 1'; then
        break
    fi
    sleep 0.1
done
kaze-shell inspect | grep -Fq '"tray_items_count": 1'
kaze-shell msg tray-open-menu kaze-demo-tray >/dev/null
wait_layer_present "kaze-tray-menu"
sleep 0.25
kaze-shell msg capture output Virtual-1 --save-only /tmp/shot-06-tray-menu.png >/dev/null
kaze-shell msg tray-menu-close >/dev/null
wait_layer_absent "kaze-tray-menu"
kill "$sni_pid" 2>/dev/null || true
wait "$sni_pid" 2>/dev/null || true
for _ in {1..30}; do
    if kaze-shell inspect | grep -Fq '"tray_items_count": 0'; then
        break
    fi
    sleep 0.1
done
kaze-shell inspect | grep -Fq '"tray_items_count": 0'

# Clear wallpaper & verify cleanup
kaze-shell msg wallpaper-clear >/dev/null
wait_layer_absent "kaze-wallpaper-Virtual-1"
kaze-shell inspect | grep -Fq '"wallpaper_count": 0'

# dmenu (0/1/2) + kaze-keys + kaze-display --menu + detached launcher survival across daemon restart
trap - ERR
set +e
kaze-shell dmenu --bogus-flag >/dev/null 2>&1
rc_bad=$?
set -e
trap 'rc=$?; echo "FAIL at guest line $LINENO (rc=$rc): $BASH_COMMAND" >&2; cat /tmp/mock_mpris.log /tmp/mock_sni.log 2>/dev/null || true' ERR
test "$rc_bad" -eq 2

printf '󰍹  Extend Right\n󰈈  Tiếng Việt 🚀\n' | kaze-shell dmenu --prompt "Display > " > /tmp/kaze-dmenu.out &
dm_pid=$!
wait_layer_present "kaze-launcher"
kaze-shell msg launcher-accept "Tiếng Việt" >/dev/null
wait "$dm_pid"
test "$(cat /tmp/kaze-dmenu.out)" = "󰈈  Tiếng Việt 🚀"
wait_layer_absent "kaze-launcher"
rm -f /tmp/kaze-dmenu.out

mkdir -p "$HOME/.local/share/applications"
cat > "$HOME/.local/share/applications/kaze-vm-detach-probe.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Kaze VM Detach Probe
Comment=Verifies launched apps survive kaze-shell restart
Exec=sleep 45
Terminal=false
EOF
kaze-shell msg launcher-toggle >/dev/null
wait_layer_present "kaze-launcher"
kaze-shell msg launcher-close >/dev/null
wait_layer_absent "kaze-launcher"
sleep 0.2
kaze-shell msg launcher-toggle >/dev/null
wait_layer_present "kaze-launcher"
kaze-shell msg launcher-accept "Kaze VM Detach Probe" >/dev/null
wait_layer_absent "kaze-launcher"
probe_pid=""
for _ in {1..20}; do
    probe_pid=$(pgrep -n -x sleep || true)
    [[ -n "$probe_pid" ]] && break
    sleep 0.1
done
test -n "$probe_pid"
grep -Fq '.scope' "/proc/$probe_pid/cgroup"
systemctl --user restart kaze-shell.service
for _ in {1..40}; do
    kaze-shell msg ping >/dev/null 2>&1 && break
    sleep 0.1
done
wait_layer_present "kaze-bar-Virtual-1"
kill -0 "$probe_pid"
kill "$probe_pid" 2>/dev/null || true
rm -f "$HOME/.local/share/applications/kaze-vm-detach-probe.desktop"
initial_pid=$(systemctl --user show -p MainPID --value kaze-shell.service)
test "$initial_pid" -gt 1
echo "    [PASS] Gate 5: CC, Caffeine, Night Light, Clipboard, SNI+DBusMenu Tray, dmenu & detached launcher"

# --- Gate 6: Hot-Reload Resilience & 20x kaze-share + 10x hyprctl reload Stress Test ---
cfg="$HOME/.config/kaze-shell/config.toml"
cp -- "$cfg" "$cfg.bak"
printf '[bar\nthickness = BROKEN_TOML\n' > "$cfg"
sleep 0.3
test "$(systemctl --user show -p MainPID --value kaze-shell.service)" = "$initial_pid"
test "$(kaze-shell msg ping)" = "pong"
mv -f -- "$cfg.bak" "$cfg"
sleep 0.3
test "$(systemctl --user show -p MainPID --value kaze-shell.service)" = "$initial_pid"

# Warm up 1 cycle so allocator high-water mark stabilizes before measuring leak slope
notify-send -a "warmup" -t 2000 "Warmup" "Stabilize font engine 🔔" >/dev/null || true
wait_layer_present "kaze-notify"
kaze-shell msg notify-clear >/dev/null
wait_layer_absent "kaze-notify"
hyprctl output create headless kaze-hotplug-test >/dev/null
wait_layer_present "kaze-bar-kaze-hotplug-test"
hyprctl output remove kaze-hotplug-test >/dev/null
wait_layer_absent "kaze-bar-kaze-hotplug-test"
sleep 0.3

# Verify virtual presentation output kaze-share spawns zero shell surfaces
hyprctl output create headless kaze-share >/dev/null
sleep 0.4
if hyprctl layers | grep -Eq 'kaze-(bar|dock|canvas|hot-corner|screen-corner)-.*kaze-share'; then
    echo "FAIL: kaze-share must remain excluded from shell surfaces" >&2
    exit 1
fi
hyprctl output remove kaze-share >/dev/null
sleep 0.2

pss_start=$(read_pss_kib "$initial_pid")
echo "    stress start: PID=$initial_pid PSS=${pss_start} KiB"
for iter in $(seq 1 20); do
    if (( iter == 1 || iter == 10 )); then
        notify-send -a "stress" -t 2500 "Stress #$iter" "Testing hotplug with active popup 🔔" >/dev/null || true
    fi
    hyprctl output create headless kaze-hotplug-test >/dev/null
    wait_layer_present "kaze-bar-kaze-hotplug-test"
    if (( iter % 2 == 0 )); then
        hyprctl reload >/dev/null
        sleep 0.2
    fi
    hyprctl output remove kaze-hotplug-test >/dev/null
    wait_layer_absent "kaze-bar-kaze-hotplug-test"
    if (( iter == 5 || iter == 10 || iter == 15 || iter == 20 )); then
        pss_cur=$(read_pss_kib "$initial_pid")
        printf '    iter %2d/20: PSS=%s KiB\n' "$iter" "$pss_cur"
    fi
done

kaze-shell msg notify-clear >/dev/null
wait_layer_absent "kaze-notify"
sleep 0.5
final_pid=$(systemctl --user show -p MainPID --value kaze-shell.service)
test "$final_pid" = "$initial_pid"
test "$(pgrep -xc kaze-shell)" = 1
test "$(kaze-shell msg ping)" = "pong"
wait_layer_present "kaze-bar-Virtual-1"
wait_layer_absent "kaze-bar-kaze-share"
status_json=$(kaze-shell inspect)
echo "$status_json" | grep -Fq '"surface_count": 1'
echo "$status_json" | grep -Fq '"hypr_connected": true'
test -z "$(hyprctl configerrors)"

pss_end=$(read_pss_kib "$initial_pid")
pss_delta=$(( pss_end - pss_start ))
printf '    stress end:   PID=%s PSS=%s KiB (delta=%+d KiB)\n' "$final_pid" "$pss_end" "$pss_delta"
if (( pss_delta > 4096 )); then
    echo "FAIL: PSS grew by ${pss_delta} KiB during 20x hotplug + 10x reload stress test" >&2
    exit 1
fi
kaze-shell doctor
kaze-doctor

# --- Gate 7: Wave 1 Security & Memory Reclamation (Single-Instance Lock Survival + 10x Overlay Reclamation) ---
# 1. Rapid 3x lock spawns exactly 1 lock-worker, and lock-worker survives kill -9 of daemon
for _ in 1 2 3; do
    kaze-shell msg lock >/dev/null
done
for _ in {1..40}; do
    if kaze-shell inspect | grep -Fq '"lock_active": true' && [ "$(pgrep -xc kaze-shell)" -eq 2 ]; then
        break
    fi
    sleep 0.1
done
test "$(pgrep -xc kaze-shell)" -eq 2
lock_pid=$(kaze-shell inspect | python3 -c 'import json,sys; print(json.load(sys.stdin)["lock_pid"] or "")')
test -n "$lock_pid" && test "$lock_pid" != "$final_pid"
kill -9 "$final_pid"
sleep 0.5
kill -0 "$lock_pid"
# Ensure daemon restarts cleanly, then end lock-worker cleanly
for _ in {1..30}; do
    kaze-shell msg ping >/dev/null 2>&1 && break
    systemctl --user start kaze-shell.service >/dev/null 2>&1 || true
    sleep 0.2
done
kill -TERM "$lock_pid" 2>/dev/null || true
for _ in {1..30}; do
    if ! kill -0 "$lock_pid" 2>/dev/null && kaze-shell inspect | grep -Fq '"lock_active": false'; then
        break
    fi
    sleep 0.1
done
test "$(pgrep -xc kaze-shell)" -eq 1
new_pid=$(systemctl --user show -p MainPID --value kaze-shell.service)
test "$new_pid" -gt 1

# 2. 10x transient overlay open/close memory & memfd reclamation gate
memfd_base=$(ls -l "/proc/$new_pid/fd" 2>/dev/null | grep -c 'memfd:' || true)
pss_rec_start=$(read_pss_kib "$new_pid")
for _ in $(seq 1 10); do
    kaze-shell msg cc-toggle >/dev/null
    wait_layer_present "kaze-cc"
    kaze-shell msg cc-close >/dev/null
    wait_layer_absent "kaze-cc"

    kaze-shell msg clipboard-toggle >/dev/null
    wait_layer_present "kaze-clipboard"
    kaze-shell msg clipboard-toggle >/dev/null
    wait_layer_absent "kaze-clipboard"

    kaze-shell msg session-menu-toggle >/dev/null
    wait_layer_present "kaze-session-menu"
    kaze-shell msg session-menu-toggle >/dev/null
    wait_layer_absent "kaze-session-menu"
done
sleep 0.5
memfd_end=$(ls -l "/proc/$new_pid/fd" 2>/dev/null | grep -c 'memfd:' || true)
pss_rec_end=$(read_pss_kib "$new_pid")
pss_rec_delta=$(( pss_rec_end - pss_rec_start ))
echo "    10x overlay cycle: PSS delta=${pss_rec_delta} KiB memfd=${memfd_base}->${memfd_end}"
if (( pss_rec_delta > 4096 )); then
    echo "FAIL: 10x overlay cycle PSS grew by ${pss_rec_delta} KiB" >&2
    exit 1
fi
if (( memfd_end > memfd_base + 2 )); then
    echo "FAIL: memfd count grew from ${memfd_base} to ${memfd_end}" >&2
    exit 1
fi

echo "    [PASS] Gate 6+7: Stress + Lock survival + 10x overlay memory & memfd reclamation PASS"

# --- Gate 8: Wave 2 Smoke (Dock, Switcher, Multi-Tab CC, Canvas Edit) & Zero-Leak Reclamation ---
echo "==> Gate 8: Wave 2 surfaces + dormant BT/Sysmon + zero-leak check"
memfd_w2_base=$(ls -l "/proc/$new_pid/fd" 2>/dev/null | grep -c 'memfd:' || true)
pss_w2_start=$(read_pss_kib "$new_pid")

foot -e sleep 30 >/dev/null 2>&1 &
sw_pid=$!
for _ in {1..40}; do
    win_cnt=$(kaze-shell inspect | python3 -c 'import json,sys; print(json.load(sys.stdin).get("windows_count", 0))' 2>/dev/null || echo 0)
    if (( win_cnt >= 1 )); then
        break
    fi
    sleep 0.1
done

kaze-shell msg config-set dock.enabled true >/dev/null
wait_layer_present "kaze-dock-Virtual-1"
kaze-shell msg dock-toggle >/dev/null
wait_layer_absent "kaze-dock-Virtual-1"
kaze-shell msg config-unset dock.enabled >/dev/null

kaze-shell msg switcher-open next >/dev/null
wait_layer_present "kaze-switcher"
kaze-shell msg switcher-cancel >/dev/null
wait_layer_absent "kaze-switcher"
kill "$sw_pid" 2>/dev/null || true
wait "$sw_pid" 2>/dev/null || true

kaze-shell msg cc-open bluetooth >/dev/null
wait_layer_present "kaze-cc"
kaze-shell msg cc-open sysmon >/dev/null
kaze-shell msg cc-close >/dev/null
wait_layer_absent "kaze-cc"
w2_inspect=$(kaze-shell inspect)
echo "$w2_inspect" | grep -Fq '"bt_discovering": false'
echo "$w2_inspect" | grep -Fq '"sysmon_subscribers": 0'

kaze-shell msg canvas-edit-open >/dev/null
wait_layer_present "kaze-canvas-edit-Virtual-1"
kaze-shell msg canvas-add clock >/dev/null
sleep 0.2
grim -t png /tmp/shot-07-canvas-edit.png 2>/dev/null || true
kaze-shell msg canvas-undo >/dev/null
kaze-shell msg canvas-edit-close >/dev/null
wait_layer_absent "kaze-canvas-edit-Virtual-1"

sleep 0.4
w2_inspect=$(kaze-shell inspect)
memfd_w2_end=$(ls -l "/proc/$new_pid/fd" 2>/dev/null | grep -c 'memfd:' || true)
pss_w2_end=$(read_pss_kib "$new_pid")
pss_w2_delta=$(( pss_w2_end - pss_w2_start ))
echo "    Wave 2 smoke: PSS delta=${pss_w2_delta} KiB memfd=${memfd_w2_base}->${memfd_w2_end}"
if (( pss_w2_delta > 4096 )); then
    echo "FAIL: Wave 2 cycle PSS grew by ${pss_w2_delta} KiB" >&2
    exit 1
fi
if (( memfd_w2_end > memfd_w2_base + 2 )); then
    echo "FAIL: Wave 2 memfd count grew from ${memfd_w2_base} to ${memfd_w2_end}" >&2
    exit 1
fi
test -z "$(hyprctl configerrors)"
echo "$w2_inspect" | grep -Fq '"surface_count": 1'
kaze-doctor
echo "    [PASS] Gate 8: Wave 2 smoke & dormant/zero-leak checks PASS"
GUEST

if [[ -n "$screenshot_out" ]]; then
    mkdir -p -- "$(dirname -- "$screenshot_out")"
    shot_dir=$(dirname -- "$screenshot_out")
    for name in shot-01-omarchy.png shot-02-island.png shot-03-swiss.png shot-04-ghost-peek.png shot-05-cc.png shot-06-tray-menu.png shot-07-canvas-edit.png; do
        scp -i "$VMDIR/bench_id_ed25519" -P 22222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            "bench@127.0.0.1:/tmp/$name" "$shot_dir/$name" 2>/dev/null || true
    done
    if [[ -f "$shot_dir/shot-01-omarchy.png" && "$screenshot_out" != "$shot_dir/shot-01-omarchy.png" ]]; then
        cp -f -- "$shot_dir/shot-01-omarchy.png" "$screenshot_out"
    fi
fi

stop_vm
if (( bench_status )); then
    exit 1
fi
echo "==> ALL kaze-shell Wave 1 KVM acceptance gates PASSED."
