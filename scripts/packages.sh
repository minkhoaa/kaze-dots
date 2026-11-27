# shellcheck shell=bash
# shellcheck disable=SC2034
# Single source of truth for official Arch Linux [core]/[extra] packages (0 AUR).
# Sourced by scripts/install.sh and scripts/install-packages.sh.

PKG_MIN_DESKTOP=(hyprland noctalia)
PKG_MIN_PORTALS=(xdg-desktop-portal xdg-desktop-portal-hyprland xdg-desktop-portal-gtk dconf libnotify)
PKG_MIN_TERM=(foot zsh zsh-autosuggestions zsh-syntax-highlighting zsh-completions)
PKG_MIN_AUDIO=(pipewire pipewire-pulse pipewire-alsa wireplumber)
PKG_MIN_SYS=(wl-clipboard xdg-utils brightnessctl playerctl networkmanager bluez bluez-utils btop)
PKG_MIN_FONTS=(ttf-jetbrains-mono-nerd adwaita-cursors lua)

MINIMAL_PACKAGES=(
    "${PKG_MIN_DESKTOP[@]}"
    "${PKG_MIN_PORTALS[@]}"
    "${PKG_MIN_TERM[@]}"
    "${PKG_MIN_AUDIO[@]}"
    "${PKG_MIN_SYS[@]}"
    "${PKG_MIN_FONTS[@]}"
)

# Optional official Arch [extra] groups (noctalia-greeter via greetd is default DM in install.sh).
PKG_DM_NOCTALIA=(greetd noctalia-greeter)
PKG_DM_LY=(ly)
PKG_DM_GREETD=(greetd greetd-tuigreet)
PKG_AUR_PREREQS=(base-devel git)

PKG_FULL_CAPTURE=(slurp wf-recorder ffmpeg hyprpicker wl-mirror)
PKG_FULL_APPS=(thunar adw-gtk-theme yazi imv zathura zathura-pdf-poppler)
PKG_FULL_IME=(gnome-keyring fcitx5 fcitx5-bamboo fcitx5-gtk noto-fonts noto-fonts-emoji)
PKG_FULL_CLI=(fzf zoxide eza bat ripgrep fd starship fastfetch)

FULL_EXTRA_PACKAGES=(
    "${PKG_FULL_CAPTURE[@]}"
    "${PKG_FULL_APPS[@]}"
    "${PKG_FULL_IME[@]}"
    "${PKG_FULL_CLI[@]}"
)

get_packages_for_profile() {
    local prof="${1:-minimal}"
    PACKAGES=("${MINIMAL_PACKAGES[@]}")
    if [[ "$prof" == "full" ]]; then
        PACKAGES+=("${FULL_EXTRA_PACKAGES[@]}")
    fi
}
