#!/usr/bin/env bash
set -euo pipefail

VMDIR="${KAZE_VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/shell-bench-vm}"
HEADLESS=false
QMP=false

while [ "$#" -gt 0 ]; do
    case "$1" in
        --headless)
            HEADLESS=true
            shift
            ;;
        --qmp)
            QMP=true
            shift
            ;;
        --vm-dir)
            if [ "$#" -lt 2 ]; then
                echo "launch-vm.sh: --vm-dir requires a path" >&2
                exit 2
            fi
            VMDIR="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--headless] [--vm-dir <path>] [--qmp]"
            echo "Launches the isolated Arch KVM VM pinned to Intel iGPU (no seed.iso, single virtio-vga-gl 1920x1080)."
            exit 0
            ;;
        *)
            echo "launch-vm.sh: unknown option '$1'" >&2
            exit 2
            ;;
    esac
done

vm_is_running() {
    local pid cmdline
    if [ -f "$VMDIR/vm.pid" ]; then
        pid=$(<"$VMDIR/vm.pid")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    while read -r pid; do
        [ -n "$pid" ] || continue
        cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
        case "$cmdline" in
            *"-name shell-bench-vm"*|*"arch-bench.qcow2"*|*"127.0.0.1:22222"*)
                return 0
                ;;
        esac
    done < <(pgrep -x qemu-system-x86 2>/dev/null || true)
    return 1
}

if vm_is_running; then
    echo "launch-vm.sh: shell-bench-vm is already running" >&2
    exit 1
fi

for req in "$VMDIR/arch-bench.qcow2" "$VMDIR/OVMF_VARS.fd" "/usr/share/edk2/x64/OVMF_CODE.4m.fd"; do
    if [ ! -f "$req" ]; then
        echo "launch-vm.sh: missing required VM file: $req" >&2
        exit 1
    fi
done

export __GLX_VENDOR_LIBRARY_NAME=mesa
# Pin EGL's vendor as well as the render node: otherwise GLVND can open the
# NVIDIA render node during device enumeration even though VirGL uses Intel.
export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json
export MESA_LOADER_DRIVER_OVERRIDE=iris

DISPLAY_ARGS=()
if [ "$HEADLESS" = true ]; then
    DISPLAY_ARGS=(-display egl-headless,rendernode=/dev/dri/renderD128 -daemonize)
else
    DISPLAY_ARGS=(-display gtk,gl=on,zoom-to-fit=on)
fi

SHARE_ARGS=()
if [ -d "$VMDIR/share" ]; then
    SHARE_ARGS=(-virtfs "local,path=$VMDIR/share,mount_tag=hostshare,security_model=mapped-xattr,readonly=on")
fi

QEMU_ARGS=(
    -name shell-bench-vm
    -machine q35,accel=kvm
    -cpu host
    -smp 4
    -m 6144
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd
    -drive if=pflash,format=raw,file="$VMDIR/OVMF_VARS.fd"
    -drive file="$VMDIR/arch-bench.qcow2",if=none,id=hd0,format=qcow2,discard=unmap
    -device virtio-blk-pci,drive=hd0,bootindex=1
    -vga none
    -device virtio-vga-gl,xres=1920,yres=1080
    "${DISPLAY_ARGS[@]}"
    -device qemu-xhci
    -device usb-tablet
    -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:22222-:22
    "${SHARE_ARGS[@]}"
    -serial "file:$VMDIR/serial.log"
    -pidfile "$VMDIR/vm.pid"
)

if [ "$QMP" = true ]; then
    # Local input injection is only exposed in a private, disposable VM directory.
    if [[ $(stat -c '%u:%a' -- "$VMDIR") != "$(id -u):700" ]]; then
        echo 'launch-vm.sh: --qmp requires a VM directory owned by you with mode 700' >&2
        exit 1
    fi
    QEMU_ARGS+=(-qmp "unix:$VMDIR/qmp.sock,server=on,wait=off")
fi

if [ "$HEADLESS" = true ]; then
    exec qemu-system-x86_64 "${QEMU_ARGS[@]}"
else
    echo "Launching shell-bench-vm (Intel iGPU VirGL 3D, 1920x1080)..."
    echo "Tip: Press Ctrl+Alt+G to capture/release SUPER keys inside the QEMU window."
    exec qemu-system-x86_64 "${QEMU_ARGS[@]}"
fi
