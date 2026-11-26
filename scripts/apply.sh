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
            echo "Backs up existing configs, writes a reversible rollback.sh, symlinks Hyprland/Foot/Zsh/Starship/systemd/CLI files, and seeds editable Noctalia config."
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 2
            ;;
    esac
done

if [ "$AUTO_YES" = false ]; then
    read -r -p "Apply kaze-dots symlinks and seed default Noctalia config in $HOME? [y/N] " reply
    case "$reply" in
        [yY]|[yY][eE][sS]) ;;
        *)
            echo "Aborted."
            exit 1
            ;;
    esac
fi

DATA_HOME=$(realpath -ms -- "${XDG_DATA_HOME:-$HOME/.local/share}")
CONFIG_HOME=$(realpath -ms -- "${XDG_CONFIG_HOME:-$HOME/.config}")
BIN_HOME="$HOME/.local/bin"
LAST_BACKUP="$CONFIG_HOME/kaze/last-backup"

BASE_BACKUP="$CONFIG_HOME/.kaze-backup-$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BASE_BACKUP"
suffix=2
while [ -e "$BACKUP_DIR" ]; do
    BACKUP_DIR="${BASE_BACKUP}-${suffix}"
    suffix=$((suffix + 1))
done

mkdir -p "$BACKUP_DIR/files" "$DATA_HOME/kaze-dots/lua" "$CONFIG_HOME/hypr" "$CONFIG_HOME/kaze" "$BIN_HOME"
INSTALLED_LIST="$BACKUP_DIR/installed.list"
BACKED_UP_LIST="$BACKUP_DIR/backed_up.list"
: > "$INSTALLED_LIST"
: > "$BACKED_UP_LIST"

# A reapply is an update to the current installation, not a new uninstall
# baseline. Keep its original backups and include any newly installed paths.
REAPPLY=false
if [ -f "$LAST_BACKUP" ]; then
    previous=$(<"$LAST_BACKUP")
    if [[ "$(dirname -- "$previous")" == "$CONFIG_HOME" && "$(basename -- "$previous")" == .kaze-backup-* ]] &&
        [ -f "$previous/installed.list" ] && [ -f "$previous/backed_up.list" ] && [ -d "$previous/files" ] &&
        { [ -f "$previous/active-install" ] || [ -L "$BIN_HOME/kaze-session" ]; }; then
        cp -a -- "$previous/files/." "$BACKUP_DIR/files/"
        cp -- "$previous/installed.list" "$INSTALLED_LIST"
        cp -- "$previous/backed_up.list" "$BACKED_UP_LIST"
        REAPPLY=true
    fi
fi

record_installed() {
    local dst="$1"
    if ! grep -Fxq "$dst" "$INSTALLED_LIST" 2>/dev/null; then
        printf '%s\n' "$dst" >> "$INSTALLED_LIST"
    fi
}

backup_existing() {
    local dst="$1"
    if [ ! -e "$dst" ] && [ ! -L "$dst" ]; then
        return 0
    fi
    local rel="${dst#"$HOME"/}"
    if [ "$rel" = "$dst" ]; then
        rel="_abs/${dst#/}"
    fi
    local saved="$BACKUP_DIR/files/$rel"
    if [ -e "$saved" ] || [ -L "$saved" ]; then
        saved="$BACKUP_DIR/reapply/$rel"
        mkdir -p -- "$(dirname -- "$saved")"
        mv -- "$dst" "$saved"
        return 0
    fi
    mkdir -p -- "$(dirname -- "$saved")"
    mv -- "$dst" "$saved"
    printf '%s\t%s\n' "$rel" "$dst" >> "$BACKED_UP_LIST"
}

backup_and_link() {
    local src="$1"
    local dst="$2"
    record_installed "$dst"
    if [ -L "$dst" ] && [ "$(readlink -f "$dst" 2>/dev/null || true)" = "$(readlink -f "$src")" ]; then
        return 0
    fi

    mkdir -p -- "$(dirname -- "$dst")"
    backup_existing "$dst"
    ln -s -- "$src" "$dst"
}

seed_editable_noctalia_config() {
    local src="$1"
    local dst="$2"
    local already_managed=false
    if [ "$REAPPLY" = true ] && grep -Fxq "$dst" "$INSTALLED_LIST" 2>/dev/null; then
        already_managed=true
    fi
    record_installed "$dst"
    # Preserve user edits made in Noctalia Settings GUI across re-applies.
    if [ "$already_managed" = true ] && [ -f "$dst" ] && [ ! -L "$dst" ]; then
        return 0
    fi
    mkdir -p -- "$(dirname -- "$dst")"
    backup_existing "$dst"
    local home_escaped
    home_escaped=$(printf '%s\n' "$HOME" | sed 's/[&|\\]/\\&/g')
    sed "s|directory = \"~/Pictures/Wallpapers\"|directory = \"${home_escaped}/Pictures/Wallpapers\"|" "$src" > "$dst"
}

backup_and_link "$REPO_DIR/lua/kaze" "$DATA_HOME/kaze-dots/lua/kaze"

for f in hyprland.lua env.lua core.lua rules.lua execs.lua keybinds.lua; do
    backup_and_link "$REPO_DIR/hypr/$f" "$CONFIG_HOME/hypr/$f"
done
backup_and_link "$REPO_DIR/config/hypr/xdph.conf" "$CONFIG_HOME/hypr/xdph.conf"

backup_and_link "$REPO_DIR/config/foot/foot.ini" "$CONFIG_HOME/foot/foot.ini"
backup_and_link "$REPO_DIR/config/starship/starship.toml" "$CONFIG_HOME/starship.toml"
backup_and_link "$REPO_DIR/config/zsh/zshrc" "$HOME/.zshrc"
backup_and_link "$REPO_DIR/config/zsh/zprofile" "$HOME/.zprofile"
backup_and_link "$REPO_DIR/config/zsh/conf.d" "$CONFIG_HOME/zsh/conf.d"

# Ensure Foot's included Noctalia theme file exists before Noctalia runs its first template pass.
FOOT_THEME="$CONFIG_HOME/foot/themes/noctalia"
if [ ! -e "$FOOT_THEME" ] && [ ! -L "$FOOT_THEME" ]; then
    mkdir -p -- "$(dirname -- "$FOOT_THEME")"
    : > "$FOOT_THEME"
    record_installed "$FOOT_THEME"
fi

# Includes on-demand units; linking them does not enable or start them.
UNIT_SRC="$REPO_DIR/config/systemd/user"
while IFS= read -r -d '' unit; do
    backup_and_link "$unit" "$CONFIG_HOME/systemd/user/${unit#"$UNIT_SRC"/}"
done < <(find "$UNIT_SRC" -type f -print0)

for bin_file in "$REPO_DIR"/bin/kaze-*; do
    backup_and_link "$bin_file" "$BIN_HOME/$(basename "$bin_file")"
done

seed_editable_noctalia_config "$REPO_DIR/config/noctalia/config.toml" "$CONFIG_HOME/noctalia/config.toml"

if [ ! -e "$CONFIG_HOME/hypr/user.lua" ] && [ ! -L "$CONFIG_HOME/hypr/user.lua" ]; then
    cp "$REPO_DIR/templates/hypr-user.lua.example" "$CONFIG_HOME/hypr/user.lua"
fi

cat <<'ROLLBACK_EOF' > "$BACKUP_DIR/rollback.sh"
#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAST_BACKUP="$(dirname -- "$BACKUP_DIR")/kaze/last-backup"
AUTO_YES=false

for arg in "$@"; do
    case "$arg" in
        --yes|-y)
            AUTO_YES=true
            ;;
        -h|--help)
            echo "Usage: $0 [--yes]"
            echo "Removes kaze-dots symlinks/seeded files and restores backed-up configs from $BACKUP_DIR."
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 2
            ;;
    esac
done

if [ "$AUTO_YES" = false ]; then
    read -r -p "Rollback kaze-dots and restore configs from $BACKUP_DIR? [y/N] " reply
    case "$reply" in
        [yY]|[yY][eE][sS]) ;;
        *)
            echo "Aborted."
            exit 1
            ;;
    esac
fi

if [ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus" ] && systemctl --user is-active --quiet kaze-session.target; then
    echo "Log out of Kaze and run rollback from a TTY or SSH session." >&2
    exit 1
fi

if [ ! -f "$LAST_BACKUP" ] || [[ "$(<"$LAST_BACKUP")" != "$BACKUP_DIR" ]]; then
    echo "This is not the current Kaze backup. Use the path recorded in $LAST_BACKUP." >&2
    exit 1
fi

if [ -f "$BACKUP_DIR/installed.list" ]; then
    while IFS= read -r target; do
        [ -n "$target" ] || continue
        if [ -L "$target" ] || [ -f "$target" ]; then
            rm -f "$target"
        fi
    done < "$BACKUP_DIR/installed.list"
fi

if [ -f "$BACKUP_DIR/backed_up.list" ]; then
    while IFS=$'\t' read -r rel dst; do
        [ -n "$rel" ] && [ -n "$dst" ] || continue
        src="$BACKUP_DIR/files/$rel"
        if [ -e "$src" ] || [ -L "$src" ]; then
            mkdir -p "$(dirname "$dst")"
            if [ -e "$dst" ] || [ -L "$dst" ]; then
                rm -f "$dst"
            fi
            cp -aT -- "$src" "$dst"
        fi
    done < "$BACKUP_DIR/backed_up.list"
fi
rm -- "$LAST_BACKUP"

if [ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus" ]; then
    systemctl --user daemon-reload
fi

echo "Rolled back kaze-dots using $BACKUP_DIR (hypr/user.lua preserved)."
ROLLBACK_EOF
chmod +x "$BACKUP_DIR/rollback.sh"
: > "$BACKUP_DIR/active-install"
pointer=$(mktemp -- "$LAST_BACKUP.XXXXXXXX")
printf '%s\n' "$BACKUP_DIR" > "$pointer"
mv -fT -- "$pointer" "$LAST_BACKUP"

if [ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus" ]; then
    systemctl --user daemon-reload
fi

echo "Backup & rollback script: $BACKUP_DIR/rollback.sh"
echo "Applied kaze-dots. Start a new Hyprland login to load the session services."
