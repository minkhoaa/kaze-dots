#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi
set +o posix 2>/dev/null || true
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
    if [ -z "${SUDO_USER:-}" ] || [ "$SUDO_USER" = "root" ]; then
        echo "apply.sh: do not run directly as root; run as your regular desktop user." >&2
        exit 1
    fi
    target_home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)"
    if [ -z "$target_home" ] || [ ! -d "$target_home" ]; then
        echo "apply.sh: could not determine home directory for user '$SUDO_USER'." >&2
        exit 1
    fi
    target_uid="$(id -u "$SUDO_USER")"
    user_env=(HOME="$target_home" USER="$SUDO_USER" LOGNAME="$SUDO_USER")
    if [ -d "/run/user/$target_uid" ]; then
        user_env+=(XDG_RUNTIME_DIR="/run/user/$target_uid")
    fi
    exec sudo -u "$SUDO_USER" -H env "${user_env[@]}" bash "$0" "$@"
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTO_YES=false

for arg in "$@"; do
    case "$arg" in
        --yes|-y)
            AUTO_YES=true
            ;;
        -h|--help)
            echo "Usage: $0 [--yes]"
            echo "Backs up existing configs, writes a reversible rollback.sh, symlinks Hyprland/Foot/Zsh/Starship/App/MIME/systemd/CLI files, and seeds editable Noctalia config."
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
        [ -f "$previous/system-changes.env" ] && cp -- "$previous/system-changes.env" "$BACKUP_DIR/system-changes.env"
        [ -f "$previous/packages-added.list" ] && cp -- "$previous/packages-added.list" "$BACKUP_DIR/packages-added.list"
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
    sed "s|~/Pictures/Wallpapers|${home_escaped}/Pictures/Wallpapers|g" "$src" > "$dst"
}

seed_editable_file() {
    local src="$1"
    local dst="$2"
    local already_managed=false
    if [ "$REAPPLY" = true ] && grep -Fxq "$dst" "$INSTALLED_LIST" 2>/dev/null; then
        already_managed=true
    fi
    record_installed "$dst"
    if [ "$already_managed" = true ] && [ -f "$dst" ] && [ ! -L "$dst" ]; then
        return 0
    fi
    mkdir -p -- "$(dirname -- "$dst")"
    backup_existing "$dst"
    cp -- "$src" "$dst"
}

ensure_gtk3_css_imports() {
    local dst="$CONFIG_HOME/gtk-3.0/gtk.css"
    local already_managed=false
    if [ "$REAPPLY" = true ] && grep -Fxq "$dst" "$INSTALLED_LIST" 2>/dev/null; then
        already_managed=true
    fi
    record_installed "$dst"
    mkdir -p -- "$(dirname -- "$dst")"

    local existing=""
    if [ -f "$dst" ] && [ ! -L "$dst" ]; then
        existing=$(cat -- "$dst")
    fi
    if [ "$already_managed" = false ] && { [ -e "$dst" ] || [ -L "$dst" ]; }; then
        backup_existing "$dst"
    fi

    if [ -n "$existing" ]; then
        printf '%s\n' "$existing" > "$dst"
    elif [ ! -f "$dst" ]; then
        : > "$dst"
    fi
    if ! grep -Fq 'noctalia.css' "$dst" 2>/dev/null; then
        local tmp_css
        tmp_css=$(mktemp -- "$dst.XXXXXXXX")
        {
            printf '@import url("noctalia.css");\n'
            cat -- "$dst"
        } > "$tmp_css"
        mv -fT -- "$tmp_css" "$dst"
    fi
    if ! grep -Fq 'kaze-thunar.css' "$dst" 2>/dev/null; then
        printf '@import url("kaze-thunar.css");\n' >> "$dst"
    fi
    if ! grep -Fq 'kaze-style.css' "$dst" 2>/dev/null; then
        printf '@import url("kaze-style.css");\n' >> "$dst"
    fi
}

backup_and_link "$REPO_DIR/lua/kaze" "$DATA_HOME/kaze-dots/lua/kaze"

for f in hyprland.lua env.lua core.lua rules.lua execs.lua keybinds.lua; do
    backup_and_link "$REPO_DIR/hypr/$f" "$CONFIG_HOME/hypr/$f"
done
backup_and_link "$REPO_DIR/config/hypr/xdph.conf" "$CONFIG_HOME/hypr/xdph.conf"

backup_and_link "$REPO_DIR/config/foot/foot.ini" "$CONFIG_HOME/foot/foot.ini"
backup_and_link "$REPO_DIR/config/starship/starship.toml" "$CONFIG_HOME/starship.toml"
backup_and_link "$REPO_DIR/config/fastfetch/config.jsonc" "$CONFIG_HOME/fastfetch/config.jsonc"
backup_and_link "$REPO_DIR/config/zsh/zshrc" "$HOME/.zshrc"
backup_and_link "$REPO_DIR/config/zsh/zprofile" "$HOME/.zprofile"
backup_and_link "$REPO_DIR/config/zsh/conf.d" "$CONFIG_HOME/zsh/conf.d"

for yazi_cfg in yazi.toml theme.toml keymap.toml; do
    backup_and_link "$REPO_DIR/config/yazi/$yazi_cfg" "$CONFIG_HOME/yazi/$yazi_cfg"
done
backup_and_link "$REPO_DIR/config/zathura/zathurarc" "$CONFIG_HOME/zathura/zathurarc"
backup_and_link "$REPO_DIR/config/imv/config" "$CONFIG_HOME/imv/config"
backup_and_link "$REPO_DIR/config/mimeapps.list" "$CONFIG_HOME/mimeapps.list"
backup_and_link "$REPO_DIR/config/xdg-terminals.list" "$CONFIG_HOME/xdg-terminals.list"
for browser_flags in chrome-flags.conf chromium-flags.conf brave-flags.conf microsoft-edge-stable-flags.conf vivaldi-stable.conf; do
    backup_and_link "$REPO_DIR/config/browsers/chromium-flags.conf" "$CONFIG_HOME/$browser_flags"
done
backup_and_link "$REPO_DIR/config/applications/yazi.desktop" "$DATA_HOME/applications/yazi.desktop"

backup_and_link "$REPO_DIR/config/gtk-3.0/settings.ini" "$CONFIG_HOME/gtk-3.0/settings.ini"
backup_and_link "$REPO_DIR/config/gtk-3.0/kaze-thunar.css" "$CONFIG_HOME/gtk-3.0/kaze-thunar.css"
backup_and_link "$REPO_DIR/config/Thunar/uca.xml" "$CONFIG_HOME/Thunar/uca.xml"
seed_editable_file "$REPO_DIR/config/Thunar/accels.scm" "$CONFIG_HOME/Thunar/accels.scm"
seed_editable_file "$REPO_DIR/config/xfce4/xfconf/xfce-perchannel-xml/thunar.xml" "$CONFIG_HOME/xfce4/xfconf/xfce-perchannel-xml/thunar.xml"
ensure_gtk3_css_imports

GTK3_NOCTALIA="$CONFIG_HOME/gtk-3.0/noctalia.css"
if [ ! -e "$GTK3_NOCTALIA" ] && [ ! -L "$GTK3_NOCTALIA" ]; then
    mkdir -p -- "$(dirname -- "$GTK3_NOCTALIA")"
    : > "$GTK3_NOCTALIA"
    record_installed "$GTK3_NOCTALIA"
fi

GTK3_STYLE="$CONFIG_HOME/gtk-3.0/kaze-style.css"
if [ ! -e "$GTK3_STYLE" ] && [ ! -L "$GTK3_STYLE" ]; then
    mkdir -p -- "$(dirname -- "$GTK3_STYLE")"
    : > "$GTK3_STYLE"
    record_installed "$GTK3_STYLE"
fi

# Ensure Foot's included Noctalia theme file exists before Noctalia runs its first template pass.
FOOT_THEME="$CONFIG_HOME/foot/themes/noctalia"
if [ ! -e "$FOOT_THEME" ] && [ ! -L "$FOOT_THEME" ]; then
    mkdir -p -- "$(dirname -- "$FOOT_THEME")"
    : > "$FOOT_THEME"
    record_installed "$FOOT_THEME"
fi
DEFAULT_FOOT_THEME="$(realpath -ms -- "$HOME/.config/foot/themes/noctalia")"
if [ "$FOOT_THEME" != "$DEFAULT_FOOT_THEME" ]; then
    # foot.ini uses include=~/.config/foot/themes/noctalia (Foot expands ~ via $HOME, not XDG_CONFIG_HOME).
    backup_and_link "$FOOT_THEME" "$DEFAULT_FOOT_THEME"
fi

if [ -d "$REPO_DIR/config/noctalia/palettes" ]; then
    for pal_file in "$REPO_DIR"/config/noctalia/palettes/*.json; do
        [ -e "$pal_file" ] || continue
        backup_and_link "$pal_file" "$CONFIG_HOME/noctalia/palettes/$(basename "$pal_file")"
    done
fi

if [ -d "$REPO_DIR/assets/wallpapers" ]; then
    for wall_file in "$REPO_DIR"/assets/wallpapers/*; do
        [ -f "$wall_file" ] || continue
        backup_and_link "$wall_file" "$HOME/Pictures/Wallpapers/$(basename "$wall_file")"
    done
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
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi
set +o posix 2>/dev/null || true
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
    if [ -z "${SUDO_USER:-}" ] || [ "$SUDO_USER" = "root" ]; then
        echo "rollback.sh: do not run directly as root; run as your regular desktop user." >&2
        exit 1
    fi
    target_home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)"
    if [ -z "$target_home" ] || [ ! -d "$target_home" ]; then
        echo "rollback.sh: could not determine home directory for user '$SUDO_USER'." >&2
        exit 1
    fi
    target_uid="$(id -u "$SUDO_USER")"
    user_env=(HOME="$target_home" USER="$SUDO_USER" LOGNAME="$SUDO_USER")
    if [ -d "/run/user/$target_uid" ]; then
        user_env+=(XDG_RUNTIME_DIR="/run/user/$target_uid")
    fi
    exec sudo -u "$SUDO_USER" -H env "${user_env[@]}" bash "$0" "$@"
fi

BACKUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAST_BACKUP="$(dirname -- "$BACKUP_DIR")/kaze/last-backup"
AUTO_YES=false
ROLLBACK_SYSTEM=false

for arg in "$@"; do
    case "$arg" in
        --yes|-y)
            AUTO_YES=true
            ;;
        --system)
            ROLLBACK_SYSTEM=true
            ;;
        -h|--help)
            echo "Usage: $0 [--yes] [--system]"
            echo "Removes kaze-dots symlinks/seeded files and restores backed-up configs from $BACKUP_DIR."
            echo "Pass --system to also revert recorded login shell, systemd/DM units, and greetd config (uses sudo)."
            echo "Packages are never auto-removed; use Snapper undochange or packages-added.list for package changes."
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 2
            ;;
    esac
done

if [ "$AUTO_YES" = false ]; then
    prompt_msg="Rollback kaze-dots and restore configs from $BACKUP_DIR? [y/N] "
    if [ "$ROLLBACK_SYSTEM" = true ]; then
        prompt_msg="Rollback kaze-dots configs AND recorded system changes (shell/services/DM via sudo) from $BACKUP_DIR? [y/N] "
    fi
    read -r -p "$prompt_msg" reply
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

DO_DOTFILES=true
if [ ! -f "$LAST_BACKUP" ] || [[ "$(<"$LAST_BACKUP")" != "$BACKUP_DIR" ]]; then
    if [ "$ROLLBACK_SYSTEM" = true ] && [ -f "$BACKUP_DIR/system-changes.env" ] && [ ! -f "$BACKUP_DIR/system-rolled-back" ]; then
        DO_DOTFILES=false
    else
        echo "This is not the current Kaze backup. Use the path recorded in $LAST_BACKUP." >&2
        exit 1
    fi
fi

if [ "$DO_DOTFILES" = true ]; then
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

    echo "Rolled back kaze-dots user configs using $BACKUP_DIR (hypr/user.lua preserved)."
fi

if [ -f "$BACKUP_DIR/system-changes.env" ]; then
    # shellcheck disable=SC1091
    source "$BACKUP_DIR/system-changes.env"
    if [ "$ROLLBACK_SYSTEM" = true ]; then
        if [ -n "${PREV_SHELL:-}" ] && [ -n "${TARGET_USER:-}" ] && command -v chsh >/dev/null 2>&1; then
            sudo chsh -s "$PREV_SHELL" "$TARGET_USER"
            echo "Restored login shell for $TARGET_USER -> $PREV_SHELL"
        fi
        if [ -n "${ENABLED_DM_UNIT:-}" ] && command -v systemctl >/dev/null 2>&1; then
            sudo systemctl disable "$ENABLED_DM_UNIT" || true
            echo "Disabled display manager unit: $ENABLED_DM_UNIT"
        fi
        if [ "${DISABLED_GETTY:-false}" = true ] && command -v systemctl >/dev/null 2>&1; then
            sudo systemctl enable getty@tty1.service || true
            echo "Re-enabled getty@tty1.service"
        fi
        if [ -n "${GREETD_BACKUP:-}" ] && [ -n "${GREETD_CONFIG:-}" ] && [ -e "$GREETD_BACKUP" ]; then
            sudo cp -a -- "$GREETD_BACKUP" "$GREETD_CONFIG"
            echo "Restored $GREETD_CONFIG from $GREETD_BACKUP"
        fi
        if [ -n "${ENABLED_SYS_UNITS:-}" ] && command -v systemctl >/dev/null 2>&1; then
            for u in $ENABLED_SYS_UNITS; do
                sudo systemctl disable "$u" || true
                echo "Disabled system unit: $u"
            done
        fi
        if [ "${ADDED_VIDEO_GROUP:-false}" = true ] && [ -n "${TARGET_USER:-}" ]; then
            echo "Note: '$TARGET_USER' was added to group 'video' (remove manually if desired: sudo gpasswd -d $TARGET_USER video)."
        fi
        : > "$BACKUP_DIR/system-rolled-back"
    else
        echo "Note: System-level changes (packages/services/DM/shell) are NOT reverted by default."
        echo "  Revert shell/services/DM: $BACKUP_DIR/rollback.sh --system"
    fi
    if [ -n "${SNAPSHOT_PRE:-}" ] && [ -n "${SNAPSHOT_POST:-}" ]; then
        echo "  Full OS rollback (Snapper): sudo snapper -c ${SNAPPER_CONFIG:-root} undochange ${SNAPSHOT_PRE}..${SNAPSHOT_POST}"
    elif [ -n "${SNAPSHOT_PRE:-}" ]; then
        echo "  Pre-install Snapper snapshot: #${SNAPSHOT_PRE} (config=${SNAPPER_CONFIG:-root})"
    fi
    if [ -f "$BACKUP_DIR/packages-added.list" ]; then
        echo "  Newly installed packages recorded in: $BACKUP_DIR/packages-added.list"
    fi
fi
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
