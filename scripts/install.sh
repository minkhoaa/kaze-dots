#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi
set +o posix 2>/dev/null || true
set -euo pipefail

if (( EUID == 0 )); then
    if [[ -z "${SUDO_USER:-}" || "$SUDO_USER" == "root" ]]; then
        echo "install.sh: do not run directly as root; log in as your regular desktop user first." >&2
        exit 1
    fi
    target_home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)"
    if [[ -z "$target_home" || ! -d "$target_home" ]]; then
        echo "install.sh: could not determine home directory for user '$SUDO_USER'." >&2
        exit 1
    fi
    target_uid="$(id -u "$SUDO_USER")"
    user_env=(HOME="$target_home" USER="$SUDO_USER" LOGNAME="$SUDO_USER")
    if [[ -d "/run/user/$target_uid" ]]; then
        user_env+=(XDG_RUNTIME_DIR="/run/user/$target_uid")
    fi
    exec sudo -u "$SUDO_USER" -H env "${user_env[@]}" bash "$0" "$@"
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="minimal"
PROFILE_EXPLICIT=false
STYLE="dynamic-island"
STYLE_EXPLICIT=false
DRY_RUN=false
SKIP_PACKAGES=false
SKIP_PACKAGES_EXPLICIT=false
AUTO_YES=false
REBOOT="auto"
SET_ZSH="auto"
SET_ZSH_EXPLICIT=false
SYSTEM_SETUP="auto"
SYSTEM_SETUP_EXPLICIT=false
DM_CHOICE="auto"
DM_EXPLICIT=false
AUR_HELPER="auto"
AUR_EXPLICIT=false
AUTO_HYBRID_GPU=true
REPLACE_CONFLICTS=false
SNAPSHOT="auto"
SNAPSHOT_EXPLICIT=false
NO_LOG=false
PACMAN_NOCONFIRM=false
USE_TUI="auto"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Installs official Arch Linux [core]/[extra] packages for the chosen Kaze + Noctalia profile
(zero AUR dependencies at core), applies symlinks and default Noctalia/Foot configs via
scripts/apply.sh, configures system services, and records the active profile and visual style
under ~/.config/kaze without overwriting existing hypr/user.lua.

Options:
  --profile <minimal|full>      Select installation profile (default: minimal)
  --style <preset>              Select visual preset (default: dynamic-island)
                                  Angular: omarchy-rail, swiss-grid, corner-hud, ghost-zero
                                  Dynamic: dynamic-island, hardware-notch, glass-studio, floating-rail
                                  Retro:   tui-hacker, retro-90s, cinema-frame
  --dm <none|noctalia|ly|greetd> Official display manager (default: noctalia; none = TTY1)
  --aur <none|yay-bin|paru-bin> AUR helper built after core install (default: yay-bin)
  --system-setup                Enable systemd/audio/group/font setup explicitly
  --skip-system-setup           Skip systemd/audio/group/font setup
  --no-hybrid-gpu               Do not seed drm_devices / prefer_mesa_egl in new user.lua
  --replace-conflicts           In --yes mode, replace hard conflicts (pulseaudio) atomically via pacman --ask=4
  --snapshot                    Require a Snapper pre/post Btrfs snapshot around system changes
  --no-snapshot                 Skip automatic Snapper pre/post snapshot even if configured
  --no-log                      Do not write \$XDG_STATE_HOME/kaze/install-*.log
  --dry-run, --check            Print installation plan without writing any files
  --skip-packages               Skip pacman package installation and apply dotfiles only
  --no-zsh                      Do not change the default login shell to Zsh
  --yes, -y                     Non-interactive mode (--noconfirm for pacman, --yes for apply.sh)
  --tui                         Launch the interactive Omarchy-inspired TUI installer
  --no-tui                      Use plain CLI prompts instead of the TUI installer
  --reboot                      Reboot automatically after installation completes
  --no-reboot                   Do not prompt to reboot after installation completes
  -h, --help                    Show this help message
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
            PROFILE_EXPLICIT=true
            shift 2
            ;;
        --profile=*)
            PROFILE="${1#--profile=}"
            PROFILE_EXPLICIT=true
            shift
            ;;
        --style)
            if (( $# < 2 )) || [[ -z "${2:-}" ]]; then
                echo "install.sh: --style requires a preset name (e.g. dynamic-island, omarchy-rail, swiss-grid)" >&2
                exit 2
            fi
            STYLE="$2"
            STYLE_EXPLICIT=true
            shift 2
            ;;
        --style=*)
            STYLE="${1#--style=}"
            STYLE_EXPLICIT=true
            shift
            ;;
        --dm)
            if (( $# < 2 )) || [[ -z "${2:-}" ]]; then
                echo "install.sh: --dm requires an argument (none, noctalia, ly, or greetd)" >&2
                exit 2
            fi
            DM_CHOICE="$2"
            DM_EXPLICIT=true
            shift 2
            ;;
        --dm=*)
            DM_CHOICE="${1#--dm=}"
            DM_EXPLICIT=true
            shift
            ;;
        --aur)
            if (( $# < 2 )) || [[ -z "${2:-}" ]]; then
                echo "install.sh: --aur requires an argument (none, yay-bin, or paru-bin)" >&2
                exit 2
            fi
            AUR_HELPER="$2"
            AUR_EXPLICIT=true
            shift 2
            ;;
        --aur=*)
            AUR_HELPER="${1#--aur=}"
            AUR_EXPLICIT=true
            shift
            ;;
        --system-setup)
            SYSTEM_SETUP="true"
            SYSTEM_SETUP_EXPLICIT=true
            shift
            ;;
        --skip-system-setup)
            SYSTEM_SETUP="false"
            SYSTEM_SETUP_EXPLICIT=true
            shift
            ;;
        --no-hybrid-gpu)
            AUTO_HYBRID_GPU=false
            shift
            ;;
        --replace-conflicts)
            REPLACE_CONFLICTS=true
            shift
            ;;
        --snapshot)
            SNAPSHOT="true"
            SNAPSHOT_EXPLICIT=true
            shift
            ;;
        --no-snapshot)
            SNAPSHOT="false"
            SNAPSHOT_EXPLICIT=true
            shift
            ;;
        --no-log)
            NO_LOG=true
            shift
            ;;
        --dry-run|--check)
            DRY_RUN=true
            shift
            ;;
        --skip-packages)
            SKIP_PACKAGES=true
            SKIP_PACKAGES_EXPLICIT=true
            shift
            ;;
        --no-zsh)
            SET_ZSH="false"
            SET_ZSH_EXPLICIT=true
            shift
            ;;
        --yes|-y)
            AUTO_YES=true
            shift
            ;;
        --tui)
            USE_TUI="true"
            shift
            ;;
        --no-tui)
            USE_TUI="false"
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

if [[ "$DM_EXPLICIT" == true && "$DM_CHOICE" == "auto" ]]; then
    echo "install.sh: invalid --dm '$DM_CHOICE' (expected: none, noctalia, ly, or greetd)" >&2
    exit 2
fi
case "$DM_CHOICE" in
    auto|none|noctalia|ly|greetd) ;;
    *)
        echo "install.sh: invalid --dm '$DM_CHOICE' (expected: none, noctalia, ly, or greetd)" >&2
        exit 2
        ;;
esac

case "$AUR_HELPER" in
    auto|none|yay-bin|paru-bin) ;;
    *)
        echo "install.sh: invalid --aur '$AUR_HELPER' (expected: none, yay-bin, or paru-bin)" >&2
        exit 2
        ;;
esac

case "$STYLE" in
    omarchy-rail|swiss-grid|corner-hud|ghost-zero|dynamic-island|hardware-notch|glass-studio|floating-rail|tui-hacker|retro-90s|cinema-frame) ;;
    brutalist|omarchy) STYLE="omarchy-rail" ;;
    swiss|notion)      STYLE="swiss-grid" ;;
    floating-islands)  STYLE="corner-hud" ;;
    ghost|zero-bar)    STYLE="ghost-zero" ;;
    concave-notch)     STYLE="hardware-notch" ;;
    glass|macos)       STYLE="glass-studio" ;;
    tui|hacker)        STYLE="tui-hacker" ;;
    retro|win95|pixel) STYLE="retro-90s" ;;
    cinema)            STYLE="cinema-frame" ;;
    *)
        echo "install.sh: invalid style '$STYLE' (expected: omarchy-rail, swiss-grid, corner-hud, ghost-zero, dynamic-island, hardware-notch, glass-studio, floating-rail, tui-hacker, retro-90s, cinema-frame)" >&2
        exit 2
        ;;
esac

# shellcheck source=scripts/packages.sh
source "$REPO_DIR/scripts/packages.sh"
# shellcheck source=scripts/install-lib.sh
source "$REPO_DIR/scripts/install-lib.sh"
# shellcheck source=scripts/install-tui.sh
source "$REPO_DIR/scripts/install-tui.sh"

PACKAGES=()
ADDON_PACKAGES=()
ALL_PACMAN_PACKAGES=()

compute_pacman_packages() {
    get_packages_for_profile "$PROFILE"
    ADDON_PACKAGES=()
    if [[ "$DM_CHOICE" == "noctalia" ]]; then
        ADDON_PACKAGES+=("${PKG_DM_NOCTALIA[@]}")
    elif [[ "$DM_CHOICE" == "ly" ]]; then
        ADDON_PACKAGES+=("${PKG_DM_LY[@]}")
    elif [[ "$DM_CHOICE" == "greetd" ]]; then
        ADDON_PACKAGES+=("${PKG_DM_GREETD[@]}")
    fi
    if [[ "$AUR_HELPER" != "none" ]]; then
        ADDON_PACKAGES+=("${PKG_AUR_PREREQS[@]}")
    fi
    ALL_PACMAN_PACKAGES=("${PACKAGES[@]}" "${ADDON_PACKAGES[@]}")
}

resolve_effective_defaults() {
    if [[ "$SKIP_PACKAGES_EXPLICIT" == false ]] && [[ "$HAS_ARCH" == false || "$HAS_PACMAN" == false ]]; then
        if [[ "$DRY_RUN" == false ]]; then
            SKIP_PACKAGES=true
        fi
    fi
    if [[ "$SET_ZSH" == "auto" ]]; then
        if [[ "$SKIP_PACKAGES" == true ]]; then
            SET_ZSH="false"
        else
            SET_ZSH="true"
        fi
    fi
    if [[ "$SYSTEM_SETUP" == "auto" ]]; then
        if [[ "$SKIP_PACKAGES" == true ]]; then
            SYSTEM_SETUP="false"
        else
            SYSTEM_SETUP="true"
        fi
    fi
    if [[ "$DM_CHOICE" == "auto" ]]; then
        if [[ "$SKIP_PACKAGES" == true ]]; then
            DM_CHOICE="none"
        else
            DM_CHOICE="noctalia"
        fi
    fi
    if [[ "$AUR_HELPER" == "auto" ]]; then
        if [[ "$SKIP_PACKAGES" == true ]]; then
            AUR_HELPER="none"
        else
            AUR_HELPER="yay-bin"
        fi
    fi
    if [[ "$REBOOT" == "auto" ]] && [[ "$SKIP_PACKAGES" == true ]]; then
        REBOOT="no"
    fi
}

DATA_HOME=$(realpath -ms -- "${XDG_DATA_HOME:-$HOME/.local/share}")
CONFIG_HOME=$(realpath -ms -- "${XDG_CONFIG_HOME:-$HOME/.config}")
BIN_HOME="$HOME/.local/bin"
PROFILE_FILE="$CONFIG_HOME/kaze/profile"
STYLE_FILE="$CONFIG_HOME/kaze/style"
LAST_BACKUP="$CONFIG_HOME/kaze/last-backup"
LOG_FILE=""
if [[ "$NO_LOG" == false ]]; then
    LOG_FILE="$(kaze_default_log_path)"
fi

if [[ "$DRY_RUN" == true ]]; then
    HAS_ARCH=false
    HAS_PACMAN=false
    [[ -f "${KAZE_ARCH_RELEASE_FILE:-/etc/arch-release}" ]] && HAS_ARCH=true
    command -v pacman >/dev/null 2>&1 && HAS_PACMAN=true
    kaze_detect_gpu
    kaze_detect_conflicts
    kaze_detect_snapper
    resolve_effective_defaults
    compute_pacman_packages
    PACMAN_FLAGS=(--needed)
    APPLY_FLAGS=()
    if [[ "$AUTO_YES" == true ]]; then
        PACMAN_FLAGS+=(--noconfirm)
        APPLY_FLAGS+=(--yes)
    fi
    if [[ "$REPLACE_CONFLICTS" == true ]] && (( ${#CONFLICT_HARD[@]} > 0 )); then
        PACMAN_FLAGS+=(--ask=4)
    fi
    echo "Kaze profile: $PROFILE"
    echo "Kaze style: $STYLE"
    echo "GPU detected: $GPU_LABEL ($GPU_MODE)"
    if (( ${#CONFLICT_HARD[@]} > 0 )); then
        echo "Hard conflicts: ${CONFLICT_HARD[*]}"
    fi
    if (( ${#CONFLICT_SOFT[@]} > 0 )); then
        echo "Soft conflicts: ${CONFLICT_SOFT[*]}"
    fi
    echo "kaze-dots official Arch packages (${#PACKAGES[@]} total, 0 AUR):"
    printf '  %s\n' "${PACKAGES[@]}"
    if (( ${#ADDON_PACKAGES[@]} > 0 )); then
        echo "Optional add-on packages (${#ADDON_PACKAGES[@]} official): ${ADDON_PACKAGES[*]}"
    fi
    if [[ "$SKIP_PACKAGES" == true ]]; then
        echo "Pacman command: (skipped via --skip-packages)"
    else
        echo "Pacman command: sudo pacman -Syu ${PACMAN_FLAGS[*]} ${ALL_PACMAN_PACKAGES[*]}"
    fi
    echo "System setup: $SYSTEM_SETUP"
    echo "Display manager: $DM_CHOICE"
    echo "AUR helper: $AUR_HELPER"
    if [[ "$SNAPSHOT" == "false" ]]; then
        echo "OS snapshot: disabled (--no-snapshot)"
    elif [[ "$SNAPPER_AVAILABLE" == true ]]; then
        echo "OS snapshot: snapper (${SNAPPER_CONFIG}) pre/post"
    else
        echo "OS snapshot: unavailable (no snapper ${SNAPPER_CONFIG} config)"
    fi
    if [[ "$GPU_MODE" == "hybrid-laptop" && "$AUTO_HYBRID_GPU" == true ]] && [[ ! -e "$CONFIG_HOME/hypr/user.lua" && ! -L "$CONFIG_HOME/hypr/user.lua" ]]; then
        echo "Hybrid GPU seed: enabled ($GPU_IGPU_CARD, prefer_mesa_egl=true in new user.lua)"
    else
        echo "Hybrid GPU seed: inactive (mode=$GPU_MODE, auto=$AUTO_HYBRID_GPU)"
    fi
    if [[ "$NO_LOG" == true ]]; then
        echo "Install log: (disabled via --no-log)"
    else
        echo "Install log: $LOG_FILE (skipped in --dry-run)"
    fi
    echo "Apply plan: $REPO_DIR/scripts/apply.sh${APPLY_FLAGS[*]:+ ${APPLY_FLAGS[*]}}"
    echo "  CONFIG_HOME=$CONFIG_HOME"
    echo "  DATA_HOME=$DATA_HOME"
    echo "  PROFILE_FILE=$PROFILE_FILE (profile=$PROFILE, preserving hypr/user.lua)"
    echo "  STYLE_FILE=$STYLE_FILE (style=$STYLE)"
    if [[ "$SKIP_PACKAGES" == false ]] && [[ "$SET_ZSH" != "false" ]]; then
        echo "Default shell: chsh -s /usr/bin/zsh ${USER:-$(id -un)} (if not already zsh)"
    fi
    if [[ "$REBOOT" == "yes" ]]; then
        echo "Post-install: sudo systemctl reboot"
    fi
    if [[ "$PROFILE" == "full" ]]; then
        echo "Note: fcitx5-configtool is an optional on-demand Qt GUI if you want a GUI to switch Bamboo between Telex and VNI."
    fi
    exit 0
fi

PRE_PKGS_TMP=""
ADDED_PKGS_TMP=""

cleanup() {
    tui_cleanup
    if [[ -n "$KAZE_SNAPSHOT_PRE_NUM" && -z "$KAZE_SNAPSHOT_POST_NUM" ]]; then
        kaze_snapshot_post "kaze-dots install (${PROFILE}, interrupted)" || true
    fi
    [[ -n "$PRE_PKGS_TMP" && -f "$PRE_PKGS_TMP" ]] && rm -f -- "$PRE_PKGS_TMP"
    [[ -n "$ADDED_PKGS_TMP" && -f "$ADDED_PKGS_TMP" ]] && rm -f -- "$ADDED_PKGS_TMP"
    kaze_stop_sudo_keepalive
    kaze_cleanup_aur_tmp
    kaze_stop_logging
}

on_signal_exit() {
    local code="$1"
    cleanup
    printf '\n%s\n' "Aborted." >&2
    exit "$code"
}

trap 'cleanup' EXIT
trap 'on_signal_exit 130' INT
trap 'on_signal_exit 143' TERM

# ── Host Detection (Read-Only) ───────────────────────────────────────────────
HAS_ARCH=false
HAS_PACMAN=false
HAS_EXISTING_BACKUP=false
HAS_USER_LUA=false
CURRENT_SHELL_BIN=""
TARGET_USER="${USER:-$(id -un)}"

detect_host() {
    [[ -f "${KAZE_ARCH_RELEASE_FILE:-/etc/arch-release}" ]] && HAS_ARCH=true
    command -v pacman >/dev/null 2>&1 && HAS_PACMAN=true
    [[ -f "$LAST_BACKUP" ]] && HAS_EXISTING_BACKUP=true
    if [[ -e "$CONFIG_HOME/hypr/user.lua" || -L "$CONFIG_HOME/hypr/user.lua" ]]; then
        HAS_USER_LUA=true
    fi
    CURRENT_SHELL_BIN="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f7 || true)"
    kaze_detect_gpu
    kaze_detect_conflicts
    kaze_detect_existing_dm
    kaze_detect_snapper
}

# ── Main Flow ────────────────────────────────────────────────────────────────
init_style
detect_host

if [[ "$USE_TUI" == "true" ]] && { [[ ! -t 0 ]] || [[ ! -t 1 ]]; }; then
    echo "install.sh: --tui requires an interactive terminal (TTY)." >&2
    exit 2
fi

TUI_ACTIVE=false
if [[ "$AUTO_YES" == false ]] && [[ "$USE_TUI" != "false" ]] && [[ -t 0 ]] && [[ -t 1 ]]; then
    TUI_ACTIVE=true
fi

APPLY_FLAGS=()
if [[ "$AUTO_YES" == true ]]; then
    APPLY_FLAGS+=(--yes)
fi

if [[ "$TUI_ACTIVE" == true ]]; then
    run_tui_wizard
    APPLY_FLAGS=(--yes)
    PRINT_STYLED=true
else
    resolve_effective_defaults
    if [[ "$AUTO_YES" == false ]] && [[ -t 0 ]]; then
        read -r -p "Install kaze-dots (profile: $PROFILE, style: $STYLE) into $HOME? [Y/n] " reply
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
    [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]] && PRINT_STYLED=true
fi

compute_pacman_packages

PACMAN_FLAGS=(--needed)
if [[ "$AUTO_YES" == true ]] || [[ "$PACMAN_NOCONFIRM" == true ]]; then
    PACMAN_FLAGS+=(--noconfirm)
fi

NEEDS_SUDO=false
if [[ "$SKIP_PACKAGES" == false || "$SYSTEM_SETUP" == "true" || "$SET_ZSH" == "true" || "$DM_CHOICE" != "none" || "$AUR_HELPER" != "none" ]]; then
    NEEDS_SUDO=true
fi

TOTAL_STEPS=3 # Preflight + Deploy + Doctor
[[ "$SKIP_PACKAGES" == false ]] && TOTAL_STEPS=$(( TOTAL_STEPS + 1 ))
[[ "$SYSTEM_SETUP" == "true" ]] && TOTAL_STEPS=$(( TOTAL_STEPS + 1 ))
[[ "$DM_CHOICE" != "none" ]] && TOTAL_STEPS=$(( TOTAL_STEPS + 1 ))
[[ "$AUR_HELPER" != "none" ]] && TOTAL_STEPS=$(( TOTAL_STEPS + 1 ))
[[ "$SET_ZSH" == "true" ]] && TOTAL_STEPS=$(( TOTAL_STEPS + 1 ))
STEP_NUM=1

if [[ "$NO_LOG" == false && -n "$LOG_FILE" ]]; then
    kaze_start_logging "$LOG_FILE"
fi

log_exec_header

# Step 1: Preflight, GPU/Conflict Check & sudo keepalive
log_step "$STEP_NUM" "$TOTAL_STEPS" "Preflight, hardware & conflict check"
STEP_NUM=$(( STEP_NUM + 1 ))
if [[ "$SKIP_PACKAGES" == false ]]; then
    if [[ "$HAS_ARCH" == false ]] || [[ "$HAS_PACMAN" == false ]]; then
        echo "install.sh: Arch Linux (pacman) is required (or pass --skip-packages)." >&2
        exit 1
    fi
    log_ok "Arch Linux & pacman verified (${#PACKAGES[@]} core + ${#ADDON_PACKAGES[@]} add-on pkgs, 0 AUR core)"
else
    log_info "Skipping package installation (--skip-packages)"
fi

log_ok "GPU detected: ${GPU_LABEL} (${GPU_MODE})"
if [[ -n "$GPU_DETAIL" ]]; then
    log_info "Display hardware: $GPU_DETAIL"
fi
if [[ "$GPU_MODE" == "single-nvidia" ]]; then
    log_warn "Single NVIDIA GPU detected: verify nvidia-open/nvidia driver and nvidia_drm.modeset=1 kernel parameter."
fi

ATOMIC_CONFLICT_SWAP=false
if [[ "$SKIP_PACKAGES" == false ]] && (( ${#CONFLICT_HARD[@]} > 0 )); then
    log_warn "Hard package conflict(s) detected: ${CONFLICT_HARD[*]}"
    if [[ "$AUTO_YES" == true ]]; then
        if [[ "$REPLACE_CONFLICTS" == true ]]; then
            ATOMIC_CONFLICT_SWAP=true
        else
            echo "install.sh: hard package conflicts detected (${CONFLICT_HARD[*]}) that block PipeWire installation." >&2
            echo "install.sh: re-run interactively or pass --replace-conflicts to replace them atomically via 'pacman -Syu --ask=4'." >&2
            exit 1
        fi
    else
        read -r -p "Replace conflicting package(s) (${CONFLICT_HARD[*]}) atomically inside 'sudo pacman -Syu'? [y/N] " conf_reply
        case "$conf_reply" in
            [yY]|[yY][eE][sS])
                ATOMIC_CONFLICT_SWAP=true
                ;;
            *)
                echo "Aborted due to conflicting packages: ${CONFLICT_HARD[*]}"
                exit 1
                ;;
        esac
    fi
fi

if [[ "$ATOMIC_CONFLICT_SWAP" == true ]]; then
    # ALPM_QUESTION_CONFLICT_PKG (1 << 2 = 4): resolves conflicts atomically inside one pacman -Syu transaction without -Rdd.
    PACMAN_FLAGS+=(--ask=4)
fi

if (( ${#CONFLICT_SOFT[@]} > 0 )); then
    log_warn "Soft runtime conflict(s) installed: ${CONFLICT_SOFT[*]}"
    log_info "Noctalia/Hyprland already provide portals & notifications; consider: sudo pacman -Rns ${CONFLICT_SOFT[*]}"
fi

if [[ "$SNAPSHOT" == "true" && "$SNAPPER_AVAILABLE" != true ]]; then
    echo "install.sh: --snapshot requested, but snapper with config '${SNAPPER_CONFIG}' was not found." >&2
    exit 1
fi

if [[ "$NEEDS_SUDO" == true ]]; then
    if ! kaze_start_sudo_keepalive; then
        echo "install.sh: sudo authentication failed." >&2
        exit 1
    fi
    log_ok "sudo session verified (keepalive active)"
    if [[ "$SNAPSHOT" != "false" && "$SNAPPER_AVAILABLE" == true ]]; then
        if ! kaze_snapshot_pre "kaze-dots install (profile=${PROFILE})"; then
            if [[ "$SNAPSHOT_EXPLICIT" == true ]]; then
                echo "install.sh: --snapshot failed to create Snapper pre-snapshot." >&2
                exit 1
            fi
        fi
    fi
fi
log_ok "Targets ready (CONFIG_HOME=$CONFIG_HOME, DATA_HOME=$DATA_HOME)"

# Step 2: Pacman packages (-Syu --needed; atomic conflict replacement via --ask=4 when approved)
if [[ "$SKIP_PACKAGES" == false ]]; then
    echo ""
    log_step "$STEP_NUM" "$TOTAL_STEPS" "Syncing & installing official Arch packages (${#ALL_PACMAN_PACKAGES[@]} pkgs)"
    STEP_NUM=$(( STEP_NUM + 1 ))
    PRE_PKGS_TMP="$(mktemp "${TMPDIR:-/tmp}/kaze-pkgs-pre.XXXXXX")"
    if command -v sort >/dev/null 2>&1; then
        pacman -Qq 2>/dev/null | LC_ALL=C sort -u > "$PRE_PKGS_TMP" || true
    fi
    if [[ "$ATOMIC_CONFLICT_SWAP" == true ]] && (( ${#CONFLICT_HARD[@]} > 0 )); then
        log_info "Replacing conflict(s) atomically inside pacman transaction: ${CONFLICT_HARD[*]}"
    fi
    sudo pacman -Syu "${PACMAN_FLAGS[@]}" "${ALL_PACMAN_PACKAGES[@]}"
    ADDED_PKGS_TMP="$(mktemp "${TMPDIR:-/tmp}/kaze-pkgs-added.XXXXXX")"
    if command -v sort >/dev/null 2>&1 && command -v comm >/dev/null 2>&1; then
        pacman -Qq 2>/dev/null | LC_ALL=C sort -u | LC_ALL=C comm -13 "$PRE_PKGS_TMP" - > "$ADDED_PKGS_TMP" || true
    fi
    log_ok "Packages installed cleanly"
fi

# Step 3: System Setup (NetworkManager, Bluetooth, PipeWire, video group, fc-cache)
if [[ "$SYSTEM_SETUP" == "true" ]]; then
    echo ""
    log_step "$STEP_NUM" "$TOTAL_STEPS" "Configuring system services, audio & font cache"
    STEP_NUM=$(( STEP_NUM + 1 ))
    kaze_run_system_setup "$TARGET_USER"
fi

# Step 4: Optional Display Manager (noctalia / ly / greetd)
if [[ "$DM_CHOICE" != "none" ]]; then
    echo ""
    log_step "$STEP_NUM" "$TOTAL_STEPS" "Configuring Display Manager ($DM_CHOICE)"
    STEP_NUM=$(( STEP_NUM + 1 ))
    kaze_setup_display_manager "$DM_CHOICE" "$TARGET_USER"
fi

# Step 5: Apply dotfiles, profile, visual style, polkit, hybrid GPU seed & backup manifest
echo ""
log_step "$STEP_NUM" "$TOTAL_STEPS" "Backing up & deploying kaze-dots configs"
STEP_NUM=$(( STEP_NUM + 1 ))

HAD_PREINSTALL_USER_LUA=false
if [[ -e "$CONFIG_HOME/hypr/user.lua" || -L "$CONFIG_HOME/hypr/user.lua" ]]; then
    HAD_PREINSTALL_USER_LUA=true
fi

HAD_PREINSTALL_PROFILE=false
PREINSTALL_PROFILE_CONTENT=""
if [[ ! -f "$LAST_BACKUP" ]] && { [[ -f "$PROFILE_FILE" ]] || [[ -L "$PROFILE_FILE" ]]; }; then
    HAD_PREINSTALL_PROFILE=true
    PREINSTALL_PROFILE_CONTENT="$(cat -- "$PROFILE_FILE")"
fi

HAD_PREINSTALL_STYLE=false
PREINSTALL_STYLE_CONTENT=""
if [[ ! -f "$LAST_BACKUP" ]] && { [[ -f "$STYLE_FILE" ]] || [[ -L "$STYLE_FILE" ]]; }; then
    HAD_PREINSTALL_STYLE=true
    PREINSTALL_STYLE_CONTENT="$(cat -- "$STYLE_FILE")"
fi

HYPR_STYLE_FILE="$CONFIG_HOME/hypr/kaze-style.lua"
HAD_PREINSTALL_HYPR_STYLE=false
PREINSTALL_HYPR_STYLE_CONTENT=""
if [[ ! -f "$LAST_BACKUP" ]] && { [[ -f "$HYPR_STYLE_FILE" ]] || [[ -L "$HYPR_STYLE_FILE" ]]; }; then
    HAD_PREINSTALL_HYPR_STYLE=true
    PREINSTALL_HYPR_STYLE_CONTENT="$(cat -- "$HYPR_STYLE_FILE")"
fi

GTK_STYLE_FILE="$CONFIG_HOME/gtk-3.0/kaze-style.css"
HAD_PREINSTALL_GTK_STYLE=false
PREINSTALL_GTK_STYLE_CONTENT=""
if [[ ! -f "$LAST_BACKUP" ]] && { [[ -f "$GTK_STYLE_FILE" ]] || [[ -L "$GTK_STYLE_FILE" ]]; }; then
    HAD_PREINSTALL_GTK_STYLE=true
    PREINSTALL_GTK_STYLE_CONTENT="$(cat -- "$GTK_STYLE_FILE")"
fi

THEME_BACKUP_FILE="$CONFIG_HOME/kaze/saved-theme.json"
HAD_PREINSTALL_THEME_BACKUP=false
PREINSTALL_THEME_BACKUP_CONTENT=""
if [[ ! -f "$LAST_BACKUP" ]] && { [[ -f "$THEME_BACKUP_FILE" ]] || [[ -L "$THEME_BACKUP_FILE" ]]; }; then
    HAD_PREINSTALL_THEME_BACKUP=true
    PREINSTALL_THEME_BACKUP_CONTENT="$(cat -- "$THEME_BACKUP_FILE")"
fi

"$REPO_DIR/scripts/apply.sh" ${APPLY_FLAGS[@]+"${APPLY_FLAGS[@]}"}

mkdir -p -- "$(dirname -- "$PROFILE_FILE")"
printf '%s\n' "$PROFILE" > "$PROFILE_FILE"

if [[ "$PROFILE" == "full" ]] && [[ -f "$CONFIG_HOME/noctalia/config.toml" ]]; then
    sed -i 's/^polkit_agent = false$/polkit_agent = true/' "$CONFIG_HOME/noctalia/config.toml"
fi

KAZE_DOTS_DIR="$REPO_DIR" KAZE_STYLE_QUIET=1 "$BIN_HOME/kaze-style" --no-reload "$STYLE" >/dev/null

record_state_file() {
    local dst="$1" had_pre="$2" pre_content="$3"
    if [[ ! -f "$LAST_BACKUP" ]]; then
        return 0
    fi
    local backup_dir rel_path saved_path
    backup_dir="$(<"$LAST_BACKUP")"
    if [[ -d "$backup_dir" ]] && [[ -f "$backup_dir/installed.list" ]]; then
        if ! grep -Fxq "$dst" "$backup_dir/installed.list" 2>/dev/null; then
            printf '%s\n' "$dst" >> "$backup_dir/installed.list"
            if [[ "$had_pre" == true ]] && [[ -f "$backup_dir/backed_up.list" ]]; then
                rel_path="${dst#"$HOME"/}"
                if [[ "$rel_path" == "$dst" ]]; then
                    rel_path="_abs/${dst#/}"
                fi
                saved_path="$backup_dir/files/$rel_path"
                if [[ ! -e "$saved_path" ]] && [[ ! -L "$saved_path" ]]; then
                    mkdir -p -- "$(dirname -- "$saved_path")"
                    printf '%s\n' "$pre_content" > "$saved_path"
                    printf '%s\t%s\n' "$rel_path" "$dst" >> "$backup_dir/backed_up.list"
                fi
            fi
        fi
    fi
}

record_state_file "$PROFILE_FILE" "$HAD_PREINSTALL_PROFILE" "$PREINSTALL_PROFILE_CONTENT"
record_state_file "$STYLE_FILE" "$HAD_PREINSTALL_STYLE" "$PREINSTALL_STYLE_CONTENT"
record_state_file "$HYPR_STYLE_FILE" "$HAD_PREINSTALL_HYPR_STYLE" "$PREINSTALL_HYPR_STYLE_CONTENT"
record_state_file "$GTK_STYLE_FILE" "$HAD_PREINSTALL_GTK_STYLE" "$PREINSTALL_GTK_STYLE_CONTENT"
if [[ -f "$THEME_BACKUP_FILE" ]] || [[ "$HAD_PREINSTALL_THEME_BACKUP" == true ]]; then
    record_state_file "$THEME_BACKUP_FILE" "$HAD_PREINSTALL_THEME_BACKUP" "$PREINSTALL_THEME_BACKUP_CONTENT"
fi
log_ok "Profile '${PROFILE}' and style '${STYLE}' recorded under $CONFIG_HOME/kaze"

HYBRID_GPU_SEEDED=false
if [[ "$HAD_PREINSTALL_USER_LUA" == false && "$GPU_MODE" == "hybrid-laptop" && "$AUTO_HYBRID_GPU" == true ]]; then
    if kaze_seed_hybrid_gpu_user_lua "$CONFIG_HOME/hypr/user.lua"; then
        HYBRID_GPU_SEEDED=true
    fi
fi

# Step 6: Default login shell
if [[ "$SET_ZSH" == "true" ]]; then
    echo ""
    log_step "$STEP_NUM" "$TOTAL_STEPS" "Configuring default login shell"
    STEP_NUM=$(( STEP_NUM + 1 ))
    if command -v zsh >/dev/null 2>&1; then
        ZSH_BIN="$(command -v zsh)"
        CURRENT_SHELL="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f7 || true)"
        if [[ "$CURRENT_SHELL" != "$ZSH_BIN" ]]; then
            log_info "Setting default login shell to $ZSH_BIN for $TARGET_USER..."
            sudo chsh -s "$ZSH_BIN" "$TARGET_USER"
            KAZE_PREV_SHELL="$CURRENT_SHELL"
            log_ok "Default login shell switched to $ZSH_BIN"
        else
            log_ok "Default login shell already set to $ZSH_BIN"
        fi
    else
        log_warn "zsh not found in PATH; skipping chsh"
    fi
fi

# Step 7: Opt-in AUR Helper (yay-bin / paru-bin) — runs after core dotfiles so AUR outages never block desktop deploy
AUR_FAILED=false
if [[ "$AUR_HELPER" != "none" ]]; then
    echo ""
    log_step "$STEP_NUM" "$TOTAL_STEPS" "Installing opt-in AUR helper ($AUR_HELPER)"
    STEP_NUM=$(( STEP_NUM + 1 ))
    AUR_NOCONFIRM=false
    if [[ "$AUTO_YES" == true || "$PACMAN_NOCONFIRM" == true ]]; then
        AUR_NOCONFIRM=true
    fi
    if ! kaze_install_aur_helper "$AUR_HELPER" "$AUR_NOCONFIRM"; then
        AUR_FAILED=true
        kaze_cleanup_aur_tmp
        log_warn "Opt-in AUR helper '$AUR_HELPER' failed; core kaze-dots desktop deployment is unaffected."
    fi
fi

if [[ -n "$KAZE_SNAPSHOT_PRE_NUM" ]]; then
    kaze_snapshot_post "kaze-dots install (profile=${PROFILE})" || true
fi

if [[ -f "$LAST_BACKUP" ]]; then
    kaze_write_system_changes_manifest "$(<"$LAST_BACKUP")" "$TARGET_USER" "$ADDED_PKGS_TMP"
fi

# Step 8: Post-install offline health verification (kaze-doctor)
echo ""
log_step "$STEP_NUM" "$TOTAL_STEPS" "Running post-install verification (kaze-doctor --offline)"
DOCTOR_OUT=""
DOCTOR_RC=0
if [[ -x "$BIN_HOME/kaze-doctor" ]]; then
    DOCTOR_OUT="$("$BIN_HOME/kaze-doctor" --offline --profile "$PROFILE" 2>&1)" || DOCTOR_RC=$?
    printf '%s\n' "$DOCTOR_OUT"
    if (( DOCTOR_RC == 0 )); then
        log_ok "kaze-doctor --offline passed"
    elif [[ "$SKIP_PACKAGES" == true ]]; then
        log_warn "kaze-doctor --offline reported missing runtime binaries (advisory in --skip-packages mode)"
    else
        log_warn "kaze-doctor --offline exited with status $DOCTOR_RC"
    fi
else
    log_warn "kaze-doctor not found at $BIN_HOME/kaze-doctor"
fi
DOCTOR_SUMMARY="$(printf '%s\n' "$DOCTOR_OUT" | grep -m1 '^Doctor summary:' || true)"

# Completion Summary
echo ""
if [[ "$PRINT_STYLED" == true ]]; then
    tui_repeat "$G_H" 64
    rule_line="$REPLY"
    printf '%s%s%s\n' "$C_GREEN" "$rule_line" "$C_RESET"
    printf '  %s%s Installed kaze-dots (profile: %s, style: %s)%s\n' \
        "${C_BOLD}${C_GREEN}" "$G_CHECK" "$PROFILE" "$STYLE" "$C_RESET"
    if [[ -f "$LAST_BACKUP" ]]; then
        printf '  %sRollback:%s %s/rollback.sh (add --system for shell/services/DM)\n' \
            "$C_MUTED" "$C_RESET" "$(<"$LAST_BACKUP")"
    fi
    if [[ -n "$KAZE_SNAPSHOT_PRE_NUM" && -n "$KAZE_SNAPSHOT_POST_NUM" ]]; then
        printf '  %sSnapshot:%s sudo snapper -c %s undochange %s..%s\n' \
            "$C_MUTED" "$C_RESET" "$SNAPPER_CONFIG" "$KAZE_SNAPSHOT_PRE_NUM" "$KAZE_SNAPSHOT_POST_NUM"
    fi
    if [[ "$NO_LOG" == false && -n "$LOG_FILE" ]]; then
        printf '  %sLog:%s      %s\n' "$C_MUTED" "$C_RESET" "$LOG_FILE"
    fi
    if [[ -n "$DOCTOR_SUMMARY" ]]; then
        printf '  %sDoctor:%s   %s\n' "$C_MUTED" "$C_RESET" "${DOCTOR_SUMMARY#Doctor summary: }"
    fi
    printf '  %sKeys:%s     Super+Space Launcher %s Super+Return Foot %s Super+/ Keys\n' \
        "$C_MUTED" "$C_RESET" "$G_BULLET" "$G_BULLET"
    printf '  %sStyle:%s    Super+Shift+I Switcher %s Super+I Settings %s Health: kaze-doctor\n' \
        "$C_MUTED" "$C_RESET" "$G_BULLET" "$G_BULLET"
    printf '%s%s%s\n' "$C_GREEN" "$rule_line" "$C_RESET"
else
    echo "Installed kaze-dots profile: $PROFILE (style: $STYLE)"
    if [[ -n "$KAZE_SNAPSHOT_PRE_NUM" && -n "$KAZE_SNAPSHOT_POST_NUM" ]]; then
        echo "Snapper undo: sudo snapper -c $SNAPPER_CONFIG undochange ${KAZE_SNAPSHOT_PRE_NUM}..${KAZE_SNAPSHOT_POST_NUM}"
    fi
    if [[ "$NO_LOG" == false && -n "$LOG_FILE" ]]; then
        echo "Install log: $LOG_FILE"
    fi
    if [[ -n "$DOCTOR_SUMMARY" ]]; then
        echo "$DOCTOR_SUMMARY"
    fi
fi

if [[ "$AUR_FAILED" == true ]]; then
    echo "Note: Opt-in AUR helper '$AUR_HELPER' did not complete; retry later or inspect $LOG_FILE."
fi
if [[ "$HYBRID_GPU_SEEDED" == true ]]; then
    echo "Note: Hybrid GPU seeded in $CONFIG_HOME/hypr/user.lua (${GPU_IGPU_CARD}, prefer_mesa_egl = true). If card0/card1 swap across reboots, pin a colon-free udev symlink (Aquamarine splits AQ_DRM_DEVICES on ':')."
fi
if (( ${#CONFLICT_SOFT[@]} > 0 )); then
    echo "Note: Optional soft conflict cleanup: sudo pacman -Rns ${CONFLICT_SOFT[*]}"
fi
if [[ "$PROFILE" == "full" ]]; then
    echo "Note: fcitx5-configtool is an optional on-demand Qt GUI if you want a GUI to switch Bamboo between Telex and VNI."
fi

kaze_stop_logging
kaze_stop_sudo_keepalive

if [[ "$REBOOT" == "yes" ]]; then
    echo "Rebooting into Kaze Hyprland..."
    exec sudo systemctl reboot
elif [[ "$REBOOT" == "auto" ]] && [[ "$AUTO_YES" == false ]] && [[ -t 0 ]] && [[ -t 1 ]]; then
    if [[ "$TUI_ACTIVE" == true ]]; then
        if prompt_reboot_tui; then
            echo "Rebooting into Kaze Hyprland..."
            exec sudo systemctl reboot
        fi
    elif [[ "$SKIP_PACKAGES" == false ]]; then
        read -r -p "Reboot now to enter Kaze Hyprland? [Y/n] " reboot_reply
        case "$reboot_reply" in
            ""|[yY]|[yY][eE][sS])
                echo "Rebooting into Kaze Hyprland..."
                exec sudo systemctl reboot
                ;;
        esac
    fi
fi
