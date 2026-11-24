#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTO_YES=false

for arg in "$@"; do
    case "$arg" in
        --yes|-y)
            AUTO_YES=true
            ;;
        -h|--help)
            echo "Usage: $0 [--yes]"
            echo "Backs up existing configs, symlinks kaze-dots into \$HOME, and runs kaze-sync."
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 2
            ;;
    esac
done

if [ "$AUTO_YES" = false ]; then
    read -r -p "Apply kaze-dots symlinks and regenerate configs in $HOME? [y/N] " reply
    case "$reply" in
        [yY]|[yY][eE][sS]) ;;
        *)
            echo "Aborted."
            exit 1
            ;;
    esac
fi

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
BIN_HOME="$HOME/.local/bin"
BACKUP_DIR="$CONFIG_HOME/.kaze-backup-$(date +%Y%m%d-%H%M%S)"
BACKUP_CREATED=false

backup_and_link() {
    local src="$1"
    local dst="$2"
    local dst_dir
    dst_dir="$(dirname "$dst")"
    mkdir -p "$dst_dir"

    if [ -L "$dst" ] && [ "$(readlink -f "$dst" 2>/dev/null || true)" = "$(readlink -f "$src")" ]; then
        return 0
    fi

    if [ -e "$dst" ] || [ -L "$dst" ]; then
        if [ "$BACKUP_CREATED" = false ]; then
            mkdir -p "$BACKUP_DIR"
            BACKUP_CREATED=true
        fi
        local rel="${dst#"$HOME"/}"
        local bdir="$BACKUP_DIR/$(dirname "$rel")"
        mkdir -p "$bdir"
        mv "$dst" "$BACKUP_DIR/$rel"
    fi

    ln -s "$src" "$dst"
}

mkdir -p "$DATA_HOME/kaze-dots/lua" "$CONFIG_HOME/hypr" "$CONFIG_HOME/kaze" "$BIN_HOME"

backup_and_link "$REPO_DIR/lua/kaze" "$DATA_HOME/kaze-dots/lua/kaze"

for f in hyprland.lua env.lua core.lua rules.lua execs.lua keybinds.lua; do
    backup_and_link "$REPO_DIR/hypr/$f" "$CONFIG_HOME/hypr/$f"
done

backup_and_link "$REPO_DIR/templates/hypridle.conf" "$CONFIG_HOME/hypr/hypridle.conf"

for bin_file in "$REPO_DIR"/bin/kaze-*; do
    chmod +x "$bin_file"
    backup_and_link "$bin_file" "$BIN_HOME/$(basename "$bin_file")"
done

if [ ! -e "$CONFIG_HOME/kaze/user.lua" ]; then
    cat <<'EOF' > "$CONFIG_HOME/kaze/user.lua"
-- User overrides for kaze-dots (safe to edit; never overwritten by apply.sh)
return {}
EOF
fi

"$BIN_HOME/kaze-sync"

if [ "$BACKUP_CREATED" = true ]; then
    echo "Backed up previous configs to: $BACKUP_DIR"
fi
echo "Applied kaze-dots cleanly."
