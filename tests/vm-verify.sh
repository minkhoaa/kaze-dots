#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VMDIR="${KAZE_VM_DIR:-/home/khoa/.local/share/shell-bench-vm}"
KEY="$VMDIR/bench_id_ed25519"
SSH_OPTS=(-i "$KEY" -p 22222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=2 -o LogLevel=ERROR)

cleanup_vm() {
    if pgrep -x qemu-system-x86 >/dev/null 2>&1; then
        ssh "${SSH_OPTS[@]}" bench@127.0.0.1 "sudo poweroff" >/dev/null 2>&1 || true
        for _ in $(seq 1 25); do
            pgrep -x qemu-system-x86 >/dev/null 2>&1 || break
            sleep 1
        done
    fi
}
trap cleanup_vm EXIT

if pgrep -x qemu-system-x86 >/dev/null 2>&1; then
    echo "vm-verify.sh: VM is already running; aborting to guarantee clean cold boot." >&2
    exit 1
fi

echo "==> [Gate 2.1] Cold-booting shell-bench-vm headless (Intel iGPU, 1920x1080)..."
boot_start=$(date +%s)
"$REPO_DIR/scripts/launch-vm.sh" --headless --vm-dir "$VMDIR"

ssh_ready=false
for i in $(seq 1 40); do
    if ssh "${SSH_OPTS[@]}" bench@127.0.0.1 "true" >/dev/null 2>&1; then
        boot_secs=$(( $(date +%s) - boot_start ))
        echo "    SSH ready in ${boot_secs}s (attempt $i)"
        ssh_ready=true
        break
    fi
    sleep 1
done

if [ "$ssh_ready" != true ]; then
    echo "vm-verify.sh: SSH did not come up in 40s" >&2
    exit 1
fi

if [ "$boot_secs" -ge 20 ]; then
    echo "vm-verify.sh: cold boot took ${boot_secs}s (>= 20s budget)" >&2
    exit 1
fi

if grep -qi "failed to load" "$VMDIR/serial.log" 2>/dev/null; then
    echo "vm-verify.sh: UEFI failed-to-load detected in serial.log" >&2
    grep -i "failed to load" "$VMDIR/serial.log" >&2
    exit 1
fi
echo "    UEFI serial.log: 0 'failed to load' errors"

echo "==> [Gate 2.2] Waiting for Hyprland socket, deploying kaze-dots, and applying..."
ssh "${SSH_OPTS[@]}" bench@127.0.0.1 '
mkdir -p ~/kaze-dots
rm -f ~/.config/kaze/state.lua
find ~/kaze-dots/lua/kaze/layouts -maxdepth 1 -type f ! -name 'init.lua' ! -name 'sidebar.lua' ! -name 'islands.lua' ! -name 'slim.lua' -delete 2>/dev/null || true
for _ in $(seq 1 30); do
    if ls -1 /run/user/1000/hypr/ >/dev/null 2>&1 && [ -n "$(ls -1 /run/user/1000/hypr/ 2>/dev/null)" ]; then
        exit 0
    fi
    sleep 0.5
done
echo "Timed out waiting for Hyprland instance socket" >&2
exit 1
'
tar -C "$REPO_DIR" --exclude='.git' -czf - . | ssh "${SSH_OPTS[@]}" bench@127.0.0.1 'tar xzf - -C ~/kaze-dots'

ssh "${SSH_OPTS[@]}" bench@127.0.0.1 '
set -euo pipefail
SIG=$(ls -1t /run/user/1000/hypr/ | head -n1)
export HYPRLAND_INSTANCE_SIGNATURE="$SIG"
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=wayland-1
export PATH="$HOME/.local/bin:$PATH"

~/kaze-dots/scripts/apply.sh --yes
~/.local/bin/kaze-sync --reload
sleep 1.5

errs=$(hyprctl configerrors || true)
[ -z "$errs" ] || { echo "hyprctl configerrors non-empty: $errs" >&2; exit 1; }
hyprctl monitors | grep -q "1920x1080" || { echo "Expected 1920x1080 monitor" >&2; exit 1; }
layers=$(hyprctl layers)
echo "$layers" | grep -q "namespace: wallpaper" || { echo "Missing wallpaper layer" >&2; exit 1; }
echo "$layers" | grep -q "namespace: waybar" || { echo "Missing waybar layer" >&2; exit 1; }
echo "    Cold-boot Hyprland check OK (0 configerrors, 1920x1080, wallpaper + waybar layers)"

echo "==> [Gate 2.3] Testing interactive 3-layout hot-switch & Waybar geometry..."
check_layout() {
    local l="$1"
    local expected_xywh="$2"
    kaze-layout "$l"
    sleep 1.0
    local e
    e=$(hyprctl configerrors || true)
    [ -z "$e" ] || { echo "configerrors on $l: $e" >&2; exit 1; }
    hyprctl layers | grep -F "$expected_xywh" | grep -q "namespace: waybar" || {
        echo "Layout $l geometry mismatch (expected $expected_xywh)" >&2
        hyprctl layers >&2
        exit 1
    }
    echo "    $l -> geometry OK ($expected_xywh)"
}
check_layout sidebar "xywh: 8 8 42 1064"
check_layout islands "xywh: 10 6 1900 34"
check_layout slim    "xywh: 0 0 1920 28"
kaze-layout --quiet sidebar

echo "==> [Gate 2.4] Testing 4 themes, kaze-tui sysmon, and kaze-osd vol-up..."
for t in kaze lavender tokyonight carbon kaze; do
    kaze-theme "$t"
    [ "$(kaze-theme --current)" = "$t" ] || { echo "Theme switch failed for $t" >&2; exit 1; }
done
echo "    4 themes switched cleanly"

kaze-tui sysmon
sleep 1.0
clients=$(hyprctl clients)
echo "$clients" | grep -q "class: kaze-tui" || { echo "kaze-tui window did not spawn" >&2; exit 1; }
echo "$clients" | grep -B3 "class: kaze-tui" | grep -q "floating: 1" || {
    echo "kaze-tui is not floating" >&2
    echo "$clients" >&2
    exit 1
}
kaze-tui sysmon
sleep 0.5
if hyprctl clients | grep -q "class: kaze-tui"; then
    echo "kaze-tui did not toggle-close" >&2
    exit 1
fi
echo "    kaze-tui floating spawn + toggle-close OK"

kaze-osd vol-up
sleep 0.5
pgrep -x fnott >/dev/null 2>&1 || { echo "fnott died after kaze-osd" >&2; exit 1; }
fnottctl dismiss all >/dev/null 2>&1 || true
echo "    kaze-osd vol-up + fnott alive OK"

echo "==> [Gate 2.5] Testing user.lua overrides, malformed fallback, and rollback.sh..."
cat << "EOF" > ~/.config/kaze/user.lua
return {
    hypr = { gaps_in = 9 },
    theme_overrides = { accent = "ff9e64" },
}
EOF
kaze-sync --reload
sleep 0.5
errs=$(hyprctl configerrors || true)
[ -z "$errs" ] || { echo "configerrors with user.lua override: $errs" >&2; exit 1; }
hyprctl getoption general:gaps_in | grep -q "9" || { echo "user.lua gaps_in=9 not applied" >&2; exit 1; }
grep -q "@define-color accent    #ff9e64;" ~/.config/waybar/colors.css || { echo "user.lua theme_overrides not applied" >&2; exit 1; }
echo "    user.lua override (gaps_in=9, accent=#ff9e64) OK"

printf "return { broken =\n" > ~/.config/kaze/user.lua
kaze-sync --reload 2>/tmp/kaze-malformed.err
grep -qi "warning" /tmp/kaze-malformed.err || { echo "Expected stderr warning for malformed user.lua" >&2; exit 1; }
rm -f /tmp/kaze-malformed.err
errs=$(hyprctl configerrors || true)
[ -z "$errs" ] || { echo "hyprctl configerrors non-empty on malformed user.lua: $errs" >&2; exit 1; }
echo "    malformed user.lua graceful fallback OK (0 configerrors)"

cp ~/kaze-dots/templates/user.lua.example ~/.config/kaze/user.lua
printf -- "-- sentinel-user-marker\n" >> ~/.config/kaze/user.lua

# Test backup + rollback.sh with sentinel non-kaze files
rm -f ~/.config/waybar/style.css ~/.config/hypr/hypridle.conf
printf "/* sentinel-style */\n" > ~/.config/waybar/style.css
printf "# sentinel-idle\n" > ~/.config/hypr/hypridle.conf

~/kaze-dots/scripts/apply.sh --yes >/dev/null
grep -q "sentinel-user-marker" ~/.config/kaze/user.lua || { echo "apply.sh overwrote existing user.lua!" >&2; exit 1; }
BACKUP_DIR=$(cat ~/.config/kaze/last-backup)
[ -x "$BACKUP_DIR/rollback.sh" ] || { echo "Missing executable rollback.sh in $BACKUP_DIR" >&2; exit 1; }

"$BACKUP_DIR/rollback.sh" --yes >/dev/null
grep -q "sentinel-style" ~/.config/waybar/style.css || { echo "rollback.sh failed to restore waybar/style.css" >&2; exit 1; }
grep -q "sentinel-idle" ~/.config/hypr/hypridle.conf || { echo "rollback.sh failed to restore hypridle.conf" >&2; exit 1; }
grep -q "sentinel-user-marker" ~/.config/kaze/user.lua || { echo "rollback.sh deleted/clobbered user.lua" >&2; exit 1; }
[ ! -e ~/.local/bin/kaze-sync ] || { echo "rollback.sh failed to remove kaze-sync symlink" >&2; exit 1; }
echo "    apply.sh backup + rollback.sh restoration OK (user.lua preserved)"

# Re-apply cleanly before Gate 3 benchmark
cp ~/kaze-dots/templates/user.lua.example ~/.config/kaze/user.lua
~/kaze-dots/scripts/apply.sh --yes >/dev/null
rm -f ~/.config/kaze/state.lua
'

echo "==> [Gate 3] Running steady-state idle benchmark (10s settle + 10s sample) across all 3 layouts..."
BENCH_OUT=$(ssh "${SSH_OPTS[@]}" bench@127.0.0.1 '
set -euo pipefail
SIG=$(ls -1t /run/user/1000/hypr/ | head -n1)
export HYPRLAND_INSTANCE_SIGNATURE="$SIG"
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=wayland-1
export PATH="$HOME/.local/bin:$PATH"

for l in sidebar islands slim; do
    kaze-layout --quiet "$l"
    sleep 10
    errs=$(hyprctl configerrors || true)
    [ -z "$errs" ] || { echo "configerrors during Gate 3 ($l): $errs" >&2; exit 1; }
    geom=$(hyprctl layers | awk "/namespace: waybar/{print \$4, \$5, \$6, \$7}" | tr -d ",")
    python3 - "$l" "$geom" << "PY"
import os, sys, time

layout, geom = sys.argv[1], sys.argv[2]
expected = {"foot": 1, "swaybg": 1, "hypridle": 1, "wl-paste": 2, "waybar": 1, "fnott": 1}

def find_pids():
    res = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            comm = open(f"/proc/{entry}/comm").read().strip()
            if comm in expected:
                res.append((int(entry), comm))
        except OSError:
            pass
    return sorted(res)

def read_stat(pid):
    s = open(f"/proc/{pid}/stat").read()
    fields = s[s.rfind(")")+2:].split()
    return int(fields[11]) + int(fields[12])

def read_ctx(pid):
    vol = nonvol = 0
    for line in open(f"/proc/{pid}/status"):
        if line.startswith("voluntary_ctxt_switches:"):
            vol = int(line.split()[1])
        elif line.startswith("nonvoluntary_ctxt_switches:"):
            nonvol = int(line.split()[1])
    return vol + nonvol

def read_pss_kb(pid):
    for line in open(f"/proc/{pid}/smaps_rollup"):
        if line.startswith("Pss:"):
            return int(line.split()[1])
    return 0

pids = find_pids()
clk = os.sysconf(os.sysconf_names["SC_CLK_TCK"])
t0 = time.monotonic()
s0 = {pid: (read_stat(pid), read_ctx(pid)) for pid, _ in pids}
time.sleep(10.0)
dt = time.monotonic() - t0

total_pss = waybar_pss = 0
cpu = cs = 0.0
counts = {}
for pid, comm in pids:
    counts[comm] = counts.get(comm, 0) + 1
    p = read_pss_kb(pid)
    total_pss += p
    if comm == "waybar":
        waybar_pss += p
    st1 = read_stat(pid)
    c1 = read_ctx(pid)
    st0, c0 = s0[pid]
    cpu += ((st1 - st0) / clk) / dt * 100.0
    cs += (c1 - c0) / dt

assert counts == expected, f"Unexpected daemon counts on {layout}: {counts}"
total_mib = total_pss / 1024.0
waybar_mib = waybar_pss / 1024.0
assert total_mib <= 60.0, f"{layout}: total PSS {total_mib:.2f} MiB > 60.0"
assert waybar_mib <= 40.0, f"{layout}: waybar PSS {waybar_mib:.2f} MiB > 40.0"
assert cpu <= 0.20, f"{layout}: idle CPU {cpu:.2f}% > 0.20%"
assert cs <= 5.0, f"{layout}: CS/s {cs:.2f} > 5.0"

print(f"| `{layout}` | `{geom}` | {total_mib:.2f} MiB | {waybar_mib:.2f} MiB | {cpu:.2f}% | {cs:.2f} | PASS |")
PY
done
kaze-layout --quiet sidebar
')

echo ""
echo "### VM Benchmark Results (1920x1080, Arch KVM VirGL, 10s Idle Window)"
echo ""
echo '| Layout | Waybar Geometry (`x y w h`) | Total PSS | Waybar PSS | Idle CPU | CS/s | Gate 3 |'
echo "|---|---|---:|---:|---:|---:|---|"
echo "$BENCH_OUT"
echo ""

cleanup_vm
if pgrep -x qemu-system-x86 >/dev/null 2>&1; then
    echo "vm-verify.sh: qemu-system-x86 still running after poweroff" >&2
    exit 1
fi
echo "==> VM powered off cleanly. All Gate 2 & Gate 3 checks passed."
