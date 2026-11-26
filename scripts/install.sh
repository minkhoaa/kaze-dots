#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="minimal"
DRY_RUN=false
SKIP_PACKAGES=false
AUTO_YES=false
REBOOT="auto"

usage() {
    cat <<EOF
Usage: $0 [--profile minimal|full] [--dry-run] [--skip-packages] [--yes] [--reboot|--no-reboot]

Installs official Arch Linux [core]/[extra] packages for the chosen Kaze + Noctalia profile
(zero AUR dependencies), applies symlinks and default Noctalia/Foot configs via scripts/apply.sh,
and records the active profile in ~/.config/kaze/profile without overwriting hypr/user.lua.

Options:
  --profile <minimal|full>  Select installation profile (default: minimal)
  --dry-run, --check        Print installation plan without writing any files
  --skip-packages           Skip pacman package installation and apply dotfiles only
  --yes, -y                 Non-interactive mode (--noconfirm for pacman, --yes for apply.sh)
  --reboot                  Reboot automatically after installation completes
  --no-reboot               Do not prompt to reboot after installation completes
  -h, --help                Show this help message
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --profile)
            if (( $# < 2 )) || [[ -z "${2:-}" ]]; then
                echo "install.sh: --profile requires an argument (minimal or full)" >&2
                exit 2
            fi
            PROFILE="$2"
            shift 2
            ;;
        --profile=*)
            PROFILE="${1#--profile=}"
            shift
            ;;
        --dry-run|--check)
            DRY_RUN=true
            shift
            ;;
        --skip-packages)
            SKIP_PACKAGES=true
            shift
            ;;
        --yes|-y)
            AUTO_YES=true
            shift
            ;;
        --reboot)
            REBOOT="yes"
            shift
            ;;
        --no-reboot)
            REBOOT="no"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "install.sh: unknown option: $1" >&2
            exit 2
            ;;
    esac
done

case "$PROFILE" in
    minimal|full) ;;
    *)
        echo "install.sh: invalid profile '$PROFILE' (expected: minimal or full)" >&2
        exit 2
        ;;
esac

# 100% official Arch Linux [core]/[extra] packages — 0 AUR dependencies
MINIMAL_PACKAGES=(
    hyprland
    noctalia
    xdg-desktop-portal
    xdg-desktop-portal-hyprland
    xdg-desktop-portal-gtk
    dconf
    libnotify
    foot
    wl-clipboard
    xdg-utils
    wireplumber
    brightnessctl
    playerctl
    networkmanager
    bluez
    bluez-utils
    btop
    ttf-jetbrains-mono-nerd
    adwaita-cursors
    lua
)

FULL_EXTRA_PACKAGES=(
    slurp
    wf-recorder
    ffmpeg
    hyprpicker
    yazi
    imv
    zathura
    zathura-pdf-mupdf
    gnome-keyring
    fcitx5
    fcitx5-bamboo
    fcitx5-gtk
    noto-fonts
    noto-fonts-emoji
)

PACKAGES=("${MINIMAL_PACKAGES[@]}")
if [[ "$PROFILE" == "full" ]]; then
    PACKAGES+=("${FULL_EXTRA_PACKAGES[@]}")
fi

PACMAN_FLAGS=(--needed)
APPLY_FLAGS=()
if [[ "$AUTO_YES" == true ]]; then
    PACMAN_FLAGS+=(--noconfirm)
    APPLY_FLAGS+=(--yes)
fi

DATA_HOME=$(realpath -ms -- "${XDG_DATA_HOME:-$HOME/.local/share}")
CONFIG_HOME=$(realpath -ms -- "${XDG_CONFIG_HOME:-$HOME/.config}")

if [[ "$DRY_RUN" == true ]]; then
    echo "Kaze profile: $PROFILE"
    echo "kaze-dots official Arch packages (${#PACKAGES[@]} total, 0 AUR):"
    printf '  %s\n' "${PACKAGES[@]}"
    if [[ "$SKIP_PACKAGES" == true ]]; then
        echo "Pacman command: (skipped via --skip-packages)"
    else
        echo "Pacman command: sudo pacman -S ${PACMAN_FLAGS[*]} ${PACKAGES[*]}"
    fi
    echo "Apply plan: $REPO_DIR/scripts/apply.sh${APPLY_FLAGS[*]:+ ${APPLY_FLAGS[*]}}"
    echo "  CONFIG_HOME=$CONFIG_HOME"
    echo "  DATA_HOME=$DATA_HOME"
    echo "  PROFILE_FILE=$CONFIG_HOME/kaze/profile (profile=$PROFILE, preserving hypr/user.lua)"
    if [[ "$REBOOT" == "yes" ]]; then
        echo "Post-install: sudo systemctl reboot"
    fi
    if [[ "$PROFILE" == "full" ]]; then
        echo "Note: fcitx5-configtool is an optional on-demand Qt GUI if you want a GUI to switch Bamboo between Telex and VNI."
    fi
    exit 0
fi

if [[ "$AUTO_YES" == false ]] && [[ -t 0 ]]; then
    read -r -p "Install kaze-dots (profile: $PROFILE) into $HOME? [Y/n] " reply
    case "$reply" in
        ""|[yY]|[yY][eE][sS])
            APPLY_FLAGS=(--yes)
            ;;
        *)
            echo "Aborted."
            exit 1
            ;;
    esac
fi

if [[ "$SKIP_PACKAGES" == false ]]; then
    if [[ ! -f /etc/arch-release ]] || ! command -v pacman >/dev/null 2>&1; then
        echo "install.sh: Arch Linux (pacman) is required (or pass --skip-packages)." >&2
        exit 1
    fi
    sudo pacman -S "${PACMAN_FLAGS[@]}" "${PACKAGES[@]}"
fi

PROFILE_FILE="$CONFIG_HOME/kaze/profile"
LAST_BACKUP="$CONFIG_HOME/kaze/last-backup"
HAD_PREINSTALL_PROFILE=false
PREINSTALL_PROFILE_CONTENT=""
if [[ ! -f "$LAST_BACKUP" ]] && { [[ -f "$PROFILE_FILE" ]] || [[ -L "$PROFILE_FILE" ]]; }; then
    HAD_PREINSTALL_PROFILE=true
    PREINSTALL_PROFILE_CONTENT="$(cat -- "$PROFILE_FILE")"
fi

"$REPO_DIR/scripts/apply.sh" "${APPLY_FLAGS[@]}"

mkdir -p -- "$(dirname -- "$PROFILE_FILE")"
printf '%s\n' "$PROFILE" > "$PROFILE_FILE"

if [[ "$PROFILE" == "full" ]] && [[ -f "$CONFIG_HOME/noctalia/config.toml" ]]; then
    sed -i 's/^polkit_agent = false$/polkit_agent = true/' "$CONFIG_HOME/noctalia/config.toml"
fi

# Record profile file in active backup manifest so rollback restores or cleans it.
if [[ -f "$LAST_BACKUP" ]]; then
    BACKUP_DIR="$(<"$LAST_BACKUP")"
    if [[ -d "$BACKUP_DIR" ]] && [[ -f "$BACKUP_DIR/installed.list" ]]; then
        if ! grep -Fxq "$PROFILE_FILE" "$BACKUP_DIR/installed.list" 2>/dev/null; then
            printf '%s\n' "$PROFILE_FILE" >> "$BACKUP_DIR/installed.list"
            if [[ "$HAD_PREINSTALL_PROFILE" == true ]] && [[ -f "$BACKUP_DIR/backed_up.list" ]]; then
                rel_prof="${PROFILE_FILE#"$HOME"/}"
                if [[ "$rel_prof" == "$PROFILE_FILE" ]]; then
                    rel_prof="_abs/${PROFILE_FILE#/}"
                fi
                saved_prof="$BACKUP_DIR/files/$rel_prof"
                if [[ ! -e "$saved_prof" ]] && [[ ! -L "$saved_prof" ]]; then
                    mkdir -p -- "$(dirname -- "$saved_prof")"
                    printf '%s\n' "$PREINSTALL_PROFILE_CONTENT" > "$saved_prof"
                    printf '%s\t%s\n' "$rel_prof" "$PROFILE_FILE" >> "$BACKUP_DIR/backed_up.list"
                fi
            fi
        fi
    fi
fi

if [[ "$PROFILE" == "full" ]]; then
    echo "Note: fcitx5-configtool is an optional on-demand Qt GUI if you want a GUI to switch Bamboo between Telex and VNI."
fi
echo "Installed kaze-dots profile: $PROFILE"

if [[ "$REBOOT" == "yes" ]]; then
    echo "Rebooting into Kaze Hyprland..."
    exec sudo systemctl reboot
elif [[ "$REBOOT" == "auto" ]] && [[ "$AUTO_YES" == false ]] && [[ "$SKIP_PACKAGES" == false ]] && [[ -t 0 ]]; then
    read -r -p "Reboot now to enter Kaze Hyprland? [Y/n] " reboot_reply
    case "$reboot_reply" in
        ""|[yY]|[yY][eE][sS])
            echo "Rebooting into Kaze Hyprland..."
            exec sudo systemctl reboot
            ;;
    esac
fi
