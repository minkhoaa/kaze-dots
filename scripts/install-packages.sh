#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi
set +o posix 2>/dev/null || true
set -euo pipefail

DRY_RUN=false
AUTO_YES=false

for arg in "$@"; do
    case "$arg" in
        --dry-run|--check)
            DRY_RUN=true
            ;;
        --yes|-y)
            AUTO_YES=true
            ;;
        -h|--help)
            echo "Usage: $0 [--dry-run] [--yes]"
            echo "Installs official Arch Linux [core]/[extra] packages required by kaze-dots + Noctalia (zero AUR dependencies)."
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 2
            ;;
    esac
done

# 100% official Arch Linux [core]/[extra] packages — zero AUR dependencies
PACKAGES=(
    hyprland
    noctalia
    xdg-desktop-portal
    xdg-desktop-portal-hyprland
    xdg-desktop-portal-gtk
    dconf
    libnotify
    foot
    zsh
    zsh-autosuggestions
    zsh-syntax-highlighting
    zsh-completions
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

PACMAN_FLAGS=(--needed)
if [ "$AUTO_YES" = true ]; then
    PACMAN_FLAGS+=(--noconfirm)
fi

if [ "$DRY_RUN" = true ]; then
    echo "kaze-dots official Arch packages (${#PACKAGES[@]} total, 0 AUR):"
    printf '  %s\n' "${PACKAGES[@]}"
    echo "Command: sudo pacman -S ${PACMAN_FLAGS[*]} ${PACKAGES[*]}"
    exit 0
fi

if [ ! -f /etc/arch-release ] || ! command -v pacman >/dev/null 2>&1; then
    echo "install-packages.sh: Arch Linux (pacman) is required." >&2
    exit 1
fi

exec sudo pacman -S "${PACMAN_FLAGS[@]}" "${PACKAGES[@]}"
