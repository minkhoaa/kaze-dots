#!/usr/bin/env bash
# Executed over SSH inside the guest, never on the host.
set -euo pipefail
export XDG_RUNTIME_DIR="/run/user/$(id -u)" PATH="$HOME/.local/bin:$PATH" LC_ALL=C.UTF-8
read_env() { systemctl --user show-environment | awk -F= -v k="$1" '$1 == k {print $2}'; }
export HYPRLAND_INSTANCE_SIGNATURE=$(read_env HYPRLAND_INSTANCE_SIGNATURE)
export WAYLAND_DISPLAY=$(read_env WAYLAND_DISPLAY)
export XDG_CURRENT_DESKTOP=$(read_env XDG_CURRENT_DESKTOP)
test -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
exec "$@"
