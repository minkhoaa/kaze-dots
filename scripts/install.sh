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
DM_CHOICE="none"
AUR_HELPER="none"
AUTO_HYBRID_GPU=true
REPLACE_CONFLICTS=false
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
  --dm <none|ly|greetd>         Optional official display manager (default: none / TTY1)
  --aur <none|yay-bin|paru-bin> Opt-in AUR helper built after core install (default: none)
  --system-setup                Enable systemd/audio/group/font setup explicitly
  --skip-system-setup           Skip systemd/audio/group/font setup
  --no-hybrid-gpu               Do not seed drm_devices / prefer_mesa_egl in new user.lua
  --replace-conflicts           In --yes mode, remove hard conflicts (pulseaudio) with pacman -Rdd
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
                echo "install.sh: --dm requires an argument (none, ly, or greetd)" >&2
                exit 2
            fi
            DM_CHOICE="$2"
            shift 2
            ;;
        --dm=*)
            DM_CHOICE="${1#--dm=}"
            shift
            ;;
        --aur)
            if (( $# < 2 )) || [[ -z "${2:-}" ]]; then
                echo "install.sh: --aur requires an argument (none, yay-bin, or paru-bin)" >&2
                exit 2
            fi
            AUR_HELPER="$2"
            shift 2
            ;;
        --aur=*)
            AUR_HELPER="${1#--aur=}"
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

case "$DM_CHOICE" in
    none|ly|greetd) ;;
    *)
        echo "install.sh: invalid --dm '$DM_CHOICE' (expected: none, ly, or greetd)" >&2
        exit 2
        ;;
esac

case "$AUR_HELPER" in
    none|yay-bin|paru-bin) ;;
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

PACKAGES=()
ADDON_PACKAGES=()
ALL_PACMAN_PACKAGES=()

compute_pacman_packages() {
    get_packages_for_profile "$PROFILE"
    ADDON_PACKAGES=()
    if [[ "$DM_CHOICE" == "ly" ]]; then
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
    resolve_effective_defaults
    compute_pacman_packages
    PACMAN_FLAGS=(--needed)
    APPLY_FLAGS=()
    if [[ "$AUTO_YES" == true ]]; then
        PACMAN_FLAGS+=(--noconfirm)
        APPLY_FLAGS+=(--yes)
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

# ── Terminal & Omarchy-inspired Tokyo Night Styling ──────────────────────────
TERM_ROWS=24
TERM_COLS=80
TUI_BOX_W=66
TUI_MARGIN=""
ORIG_STTY=""
TUI_STTY_MODIFIED=false
TUI_ALT_ACTIVE=false
TUI_CURSOR_HIDDEN=false
HAS_UTF8=false
COLOR_MODE="none"

C_RESET=""
C_BOLD=""
C_DIM=""
C_BLUE=""
C_CYAN=""
C_PURPLE=""
C_GREEN=""
C_YELLOW=""
C_RED=""
C_FG=""
C_MUTED=""
C_BORDER=""
C_ACTIVE_BORDER=""
C_BG_SEL=""
C_BTN_ACTIVE=""
C_BTN_IDLE=""
C_LOGO_1=""
C_LOGO_2=""
C_LOGO_3=""
C_LOGO_4=""
C_LOGO_5=""

G_TL="+" G_TR="+" G_BL="+" G_BR="+" G_H="-" G_V="|" G_ML="+" G_MR="+"
G_BAR=">" G_CHECK="x" G_CROSS="x" G_DOT_ON="*" G_DOT_OFF="o"
G_ARROW_R="->" G_ARROW_L="<-" G_BULLET="."

init_style() {
    local locale="${LC_ALL:-${LC_CTYPE:-${LANG:-C}}}"
    if [[ "$locale" =~ [Uu][Tt][Ff]-?8 ]]; then
        HAS_UTF8=true
        G_TL="┌" G_TR="┐" G_BL="└" G_BR="┘" G_H="─" G_V="│" G_ML="├" G_MR="┤"
        G_BAR="▌" G_CHECK="✓" G_CROSS="✗" G_DOT_ON="●" G_DOT_OFF="○"
        G_ARROW_R="→" G_ARROW_L="←" G_BULLET="·"
    fi

    if [[ -n "${NO_COLOR:-}" ]] || [[ ! -t 1 ]] || [[ "${TERM:-dumb}" == "dumb" ]]; then
        COLOR_MODE="none"
        return 0
    fi

    if [[ "${COLORTERM:-}" == "truecolor" || "${COLORTERM:-}" == "24bit" ]]; then
        COLOR_MODE="truecolor"
    elif [[ "${TERM:-}" == *256color* || "${TERM:-}" == foot* || "${TERM:-}" == alacritty* || "${TERM:-}" == kitty* || "${TERM:-}" == wezterm* || "${TERM:-}" == xterm-ghostty* ]]; then
        COLOR_MODE="256"
    else
        COLOR_MODE="16"
    fi

    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'

    case "$COLOR_MODE" in
        truecolor)
            C_BLUE=$'\033[38;2;122;162;247m'
            C_CYAN=$'\033[38;2;125;207;255m'
            C_PURPLE=$'\033[38;2;187;154;247m'
            C_GREEN=$'\033[38;2;158;206;106m'
            C_YELLOW=$'\033[38;2;224;175;104m'
            C_RED=$'\033[38;2;247;118;142m'
            C_FG=$'\033[38;2;192;202;245m'
            C_MUTED=$'\033[38;2;120;130;170m'
            C_BORDER=$'\033[38;2;65;72;104m'
            C_ACTIVE_BORDER=$'\033[38;2;122;162;247m'
            C_BG_SEL=$'\033[48;2;36;40;59m'
            C_BTN_ACTIVE=$'\033[48;2;122;162;247m\033[38;2;26;27;38m\033[1m'
            C_BTN_IDLE=$'\033[48;2;36;40;59m\033[38;2;169;177;214m'
            C_LOGO_1=$'\033[38;2;125;207;255m'
            C_LOGO_2=$'\033[38;2;123;184;251m'
            C_LOGO_3=$'\033[38;2;122;162;247m'
            C_LOGO_4=$'\033[38;2;154;158;247m'
            C_LOGO_5=$'\033[38;2;187;154;247m'
            ;;
        256)
            C_BLUE=$'\033[38;5;111m'
            C_CYAN=$'\033[38;5;117m'
            C_PURPLE=$'\033[38;5;141m'
            C_GREEN=$'\033[38;5;149m'
            C_YELLOW=$'\033[38;5;179m'
            C_RED=$'\033[38;5;210m'
            C_FG=$'\033[38;5;252m'
            C_MUTED=$'\033[38;5;103m'
            C_BORDER=$'\033[38;5;60m'
            C_ACTIVE_BORDER=$'\033[38;5;111m'
            C_BG_SEL=$'\033[48;5;236m'
            C_BTN_ACTIVE=$'\033[48;5;111m\033[38;5;234m\033[1m'
            C_BTN_IDLE=$'\033[48;5;236m\033[38;5;250m'
            C_LOGO_1=$'\033[38;5;117m'
            C_LOGO_2=$'\033[38;5;111m'
            C_LOGO_3=$'\033[38;5;111m'
            C_LOGO_4=$'\033[38;5;147m'
            C_LOGO_5=$'\033[38;5;141m'
            ;;
        16)
            C_BLUE=$'\033[94m'
            C_CYAN=$'\033[96m'
            C_PURPLE=$'\033[95m'
            C_GREEN=$'\033[92m'
            C_YELLOW=$'\033[93m'
            C_RED=$'\033[91m'
            C_FG=$'\033[97m'
            C_MUTED=$'\033[90m'
            C_BORDER=$'\033[90m'
            C_ACTIVE_BORDER=$'\033[94m'
            C_BG_SEL=$'\033[44m'
            C_BTN_ACTIVE=$'\033[46m\033[30m\033[1m'
            C_BTN_IDLE=$'\033[40m\033[37m'
            C_LOGO_1=$'\033[96m'
            C_LOGO_2=$'\033[96m'
            C_LOGO_3=$'\033[94m'
            C_LOGO_4=$'\033[94m'
            C_LOGO_5=$'\033[95m'
            ;;
    esac
}

tui_cleanup() {
    if [[ "$TUI_STTY_MODIFIED" == true ]] && [[ -n "$ORIG_STTY" ]]; then
        stty "$ORIG_STTY" <&0 2>/dev/null || true
        TUI_STTY_MODIFIED=false
    fi
    if [[ "$TUI_CURSOR_HIDDEN" == true ]]; then
        printf '\033[?25h' >&1 2>/dev/null || true
        TUI_CURSOR_HIDDEN=false
    fi
    if [[ "$TUI_ALT_ACTIVE" == true ]]; then
        printf '\033[?1049l' >&1 2>/dev/null || true
        TUI_ALT_ACTIVE=false
    fi
}

cleanup() {
    tui_cleanup
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

tui_enter() {
    ORIG_STTY="$(stty -g <&0 2>/dev/null || true)"
    printf '\033[?1049h\033[?25l\033[2J\033[H' >&1
    TUI_ALT_ACTIVE=true
    TUI_CURSOR_HIDDEN=true
    stty -echo -icanon min 1 time 0 <&0 2>/dev/null || true
    TUI_STTY_MODIFIED=true
}

tui_leave() {
    tui_cleanup
}

tui_measure_term() {
    local sz=""
    sz="$(stty size <&0 2>/dev/null || true)"
    if [[ "$sz" =~ ^([0-9]+)[[:space:]]+([0-9]+)$ ]]; then
        TERM_ROWS="${BASH_REMATCH[1]}"
        TERM_COLS="${BASH_REMATCH[2]}"
    else
        TERM_ROWS="${LINES:-24}"
        TERM_COLS="${COLUMNS:-80}"
    fi
    (( TERM_ROWS < 10 )) && TERM_ROWS=24
    (( TERM_COLS < 40 )) && TERM_COLS=80

    if (( TERM_COLS >= 74 )); then
        TUI_BOX_W=66
    else
        TUI_BOX_W=$(( TERM_COLS - 6 ))
        (( TUI_BOX_W < 36 )) && TUI_BOX_W=36
    fi
    local outer_w=$(( TUI_BOX_W + 4 ))
    local margin_len=$(( (TERM_COLS - outer_w) / 2 ))
    (( margin_len < 0 )) && margin_len=0
    tui_spaces "$margin_len"
    TUI_MARGIN="$REPLY"
}

tui_repeat() {
    local ch="$1" n="$2" sp=""
    if (( n <= 0 )); then
        REPLY=""
        return 0
    fi
    printf -v sp '%*s' "$n" ""
    REPLY="${sp// /$ch}"
}

tui_spaces() {
    local n="$1"
    if (( n <= 0 )); then
        REPLY=""
        return 0
    fi
    printf -v REPLY '%*s' "$n" ""
}

tui_clip() {
    local text="$1" max="$2"
    if (( max <= 0 )); then
        REPLY=""
        return 0
    fi
    if (( ${#text} <= max )); then
        REPLY="$text"
        return 0
    fi
    if (( max <= 2 )); then
        REPLY="${text:0:max}"
        return 0
    fi
    local ell=".."
    [[ "$HAS_UTF8" == true ]] && ell="…"
    local cut=$(( max - ${#ell} ))
    REPLY="${text:0:cut}${ell}"
}

tui_read_key() {
    local key="" c1="" c2="" seq=""
    if ! IFS= read -rsn1 key <&0 2>/dev/null; then
        REPLY="EOF"
        return 0
    fi
    if [[ "$key" == $'\033' ]]; then
        IFS= read -rsn1 -t 0.03 c1 <&0 2>/dev/null || true
        if [[ "$c1" == "[" || "$c1" == "O" ]]; then
            IFS= read -rsn1 -t 0.03 c2 <&0 2>/dev/null || true
            seq="${c1}${c2}"
            case "$seq" in
                "[A"|"OA") REPLY="UP"; return 0 ;;
                "[B"|"OB") REPLY="DOWN"; return 0 ;;
                "[C"|"OC") REPLY="RIGHT"; return 0 ;;
                "[D"|"OD") REPLY="LEFT"; return 0 ;;
                "[Z")      REPLY="SHIFT_TAB"; return 0 ;;
                "[5")      IFS= read -rsn1 -t 0.03 _ <&0 2>/dev/null || true; REPLY="PGUP"; return 0 ;;
                "[6")      IFS= read -rsn1 -t 0.03 _ <&0 2>/dev/null || true; REPLY="PGDN"; return 0 ;;
            esac
            while IFS= read -rsn1 -t 0.01 _ <&0 2>/dev/null; do :; done
        fi
        REPLY="ESC"
        return 0
    fi
    case "$key" in
        "")            REPLY="ENTER" ;;
        " ")           REPLY="SPACE" ;;
        $'\t')         REPLY="TAB" ;;
        $'\x7f'|$'\b') REPLY="BACKSPACE" ;;
        "k"|"K")       REPLY="UP" ;;
        "j"|"J")       REPLY="DOWN" ;;
        "h"|"H")       REPLY="LEFT" ;;
        "l"|"L")       REPLY="RIGHT" ;;
        *)             REPLY="$key" ;;
    esac
}

FRAME_BUF=""
FRAME_LINES=0

frame_reset() {
    FRAME_BUF=""
    FRAME_LINES=0
}

frame_line() {
    local content="${1:-}"
    FRAME_BUF+="${content}"$'\033[K\n'
    FRAME_LINES=$(( FRAME_LINES + 1 ))
}

frame_flush() {
    local target_rows="${1:-22}"
    local top_pad=0
    if (( TERM_ROWS > target_rows + 2 )); then
        top_pad=$(( (TERM_ROWS - target_rows) / 2 ))
        (( top_pad > 6 )) && top_pad=6
    fi
    local pre=""
    local i
    for (( i=0; i<top_pad; i++ )); do
        pre+=$'\033[K\n'
    done
    local body="${FRAME_BUF%$'\n'}"
    printf '\033[?2026h\033[H%s%s\033[J\033[?2026l' "$pre" "$body" >&1
}

frame_center() {
    local plain="$1" style="${2:-}"
    tui_clip "$plain" "$(( TERM_COLS - 2 ))"
    local clipped="$REPLY"
    local pad=$(( (TERM_COLS - ${#clipped}) / 2 ))
    (( pad < 0 )) && pad=0
    tui_spaces "$pad"
    frame_line "${REPLY}${style}${clipped}${C_RESET}"
}

tui_box_rule() {
    local left_ch="$1" right_ch="$2"
    tui_repeat "$G_H" "$(( TUI_BOX_W + 2 ))"
    frame_line "${TUI_MARGIN}${C_BORDER}${left_ch}${REPLY}${right_ch}${C_RESET}"
}

tui_box_top()    { tui_box_rule "$G_TL" "$G_TR"; }
tui_box_mid()    { tui_box_rule "$G_ML" "$G_MR"; }
tui_box_bottom() { tui_box_rule "$G_BL" "$G_BR"; }

tui_box_empty() {
    tui_spaces "$TUI_BOX_W"
    frame_line "${TUI_MARGIN}${C_BORDER}${G_V}${C_RESET} ${REPLY} ${C_BORDER}${G_V}${C_RESET}"
}

tui_box_row() {
    local plain_len="$1" formatted="$2" bg="${3:-}"
    local pad_len=$(( TUI_BOX_W - plain_len ))
    (( pad_len < 0 )) && pad_len=0
    tui_spaces "$pad_len"
    if [[ -n "$bg" ]]; then
        frame_line "${TUI_MARGIN}${C_BORDER}${G_V}${C_RESET}${bg} ${formatted}${bg}${REPLY} ${C_RESET}${C_BORDER}${G_V}${C_RESET}"
    else
        frame_line "${TUI_MARGIN}${C_BORDER}${G_V}${C_RESET} ${formatted}${REPLY} ${C_BORDER}${G_V}${C_RESET}"
    fi
}

tui_box_text() {
    local text="$1" style="${2:-$C_FG}" bg="${3:-}"
    tui_clip "$text" "$TUI_BOX_W"
    local clipped="$REPLY"
    tui_box_row "${#clipped}" "${style}${bg}${clipped}${C_RESET}" "$bg"
}

tui_box_kv() {
    local key_w="$1" key="$2" val="$3" val_style="${4:-$C_FG}"
    local key_pad=$(( key_w - ${#key} ))
    (( key_pad < 0 )) && key_pad=0
    tui_spaces "$key_pad"
    local kp="$REPLY"
    local max_v=$(( TUI_BOX_W - key_w - 2 ))
    tui_clip "$val" "$max_v"
    local v="$REPLY"
    local plain_len=$(( key_w + 2 + ${#v} ))
    tui_box_row "$plain_len" "${C_MUTED}${key}${kp}  ${val_style}${v}${C_RESET}"
}

tui_render_header() {
    local active_step="$1"
    local min_logo_rows="${2:-23}"
    if (( TERM_ROWS >= min_logo_rows )) && (( TERM_COLS >= 40 )); then
        if [[ "$HAS_UTF8" == true ]]; then
            frame_center "██  ██   █████   ███████  ██████" "${C_LOGO_1}"
            frame_center "██ ██   ██   ██      ██   ██    " "${C_LOGO_2}"
            frame_center "████    ███████    ███    █████ " "${C_LOGO_3}"
            frame_center "██ ██   ██   ██   ██      ██    " "${C_LOGO_4}"
            frame_center "██  ██  ██   ██  ███████  ██████" "${C_LOGO_5}"
        else
            frame_center "K  A  Z  E" "${C_BOLD}${C_CYAN}"
        fi
        frame_center "Hyprland 0.57 + Noctalia v5.x ${G_BULLET} Arch [extra] (0 AUR)" "${C_MUTED}"
        frame_line ""
    else
        frame_center "KAZE ${G_BULLET} Hyprland 0.57 + Noctalia v5.x (0 AUR)" "${C_BOLD}${C_CYAN}"
    fi

    local labels=("1 Profile" "2 Style" "3 Options" "4 Review" "5 Install")
    local sep=" ${G_H}${G_H} "
    local plain="" formatted="" i idx marker
    for (( i=0; i<5; i++ )); do
        idx=$(( i + 1 ))
        if (( idx < active_step )); then
            marker="$G_CHECK"
            plain+="${marker} ${labels[$i]}"
            formatted+="${C_GREEN}${marker} ${labels[$i]}${C_RESET}"
        elif (( idx == active_step )); then
            marker="$G_DOT_ON"
            plain+="${marker} ${labels[$i]}"
            formatted+="${C_BOLD}${C_CYAN}${marker} ${labels[$i]}${C_RESET}"
        else
            marker="$G_DOT_OFF"
            plain+="${marker} ${labels[$i]}"
            formatted+="${C_MUTED}${marker} ${labels[$i]}${C_RESET}"
        fi
        if (( i < 4 )); then
            plain+="$sep"
            formatted+="${C_BORDER}${sep}${C_RESET}"
        fi
    done

    if (( ${#plain} <= TERM_COLS - 2 )); then
        local sp=$(( (TERM_COLS - ${#plain}) / 2 ))
        tui_spaces "$sp"
        frame_line "${REPLY}${formatted}"
    else
        frame_center "Step ${active_step}/5: ${labels[$((active_step - 1))]}" "${C_BOLD}${C_CYAN}"
    fi
}

tui_render_footer() {
    local hints="$1"
    if [[ -n "$TUI_STATUS_MSG" ]]; then
        frame_center "$TUI_STATUS_MSG" "${C_YELLOW}"
    else
        frame_center "$hints" "${C_MUTED}"
    fi
}

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
}

tui_host_summary_line() {
    local os_label="Non-Arch"
    local os_style="$C_YELLOW"
    if [[ "$HAS_ARCH" == true && "$HAS_PACMAN" == true ]]; then
        os_label="Arch/CachyOS (pacman)"
        os_style="$C_GREEN"
    elif [[ "$HAS_PACMAN" == true ]]; then
        os_label="pacman detected"
        os_style="$C_YELLOW"
    fi

    local state_label="Fresh install"
    local state_style="$C_CYAN"
    if [[ "$HAS_EXISTING_BACKUP" == true ]]; then
        state_label="Reapply (preserves GUI)"
        state_style="$C_PURPLE"
    fi

    local ulua_label="Absent"
    [[ "$HAS_USER_LUA" == true ]] && ulua_label="Preserved"

    local plain="Host: ${os_label} ${G_BULLET} ${state_label} ${G_BULLET} user.lua: ${ulua_label}"
    if (( ${#plain} > TUI_BOX_W )); then
        tui_clip "Host: ${os_label} ${G_BULLET} ${state_label}" "$TUI_BOX_W"
        tui_box_row "${#REPLY}" "${C_MUTED}${REPLY}${C_RESET}"
    else
        local fmt="${C_MUTED}Host: ${os_style}${os_label} ${C_BORDER}${G_BULLET} ${state_style}${state_label} ${C_BORDER}${G_BULLET} ${C_MUTED}user.lua: ${C_FG}${ulua_label}${C_RESET}"
        tui_box_row "${#plain}" "$fmt"
    fi

    local gpu_col="$C_CYAN"
    [[ "$GPU_MODE" == "single-nvidia" ]] && gpu_col="$C_YELLOW"
    [[ "$GPU_MODE" == "hybrid-laptop" ]] && gpu_col="$C_GREEN"

    local conf_label="0 conflicts" conf_col="$C_GREEN"
    local hc="${#CONFLICT_HARD[@]}" sc="${#CONFLICT_SOFT[@]}"
    if (( hc > 0 && sc > 0 )); then
        conf_label="${hc} hard, ${sc} soft conflict(s)"
        conf_col="$C_RED"
    elif (( hc > 0 )); then
        conf_label="${hc} hard conflict(s)"
        conf_col="$C_RED"
    elif (( sc > 0 )); then
        conf_label="${sc} soft conflict(s)"
        conf_col="$C_YELLOW"
    fi

    local hw_plain="GPU:  ${GPU_LABEL} ${G_BULLET} ${conf_label}"
    if [[ -n "$EXISTING_DM" ]]; then
        hw_plain+=" ${G_BULLET} DM: ${EXISTING_DM%.service}"
    fi
    if (( ${#hw_plain} > TUI_BOX_W )); then
        tui_clip "$hw_plain" "$TUI_BOX_W"
        tui_box_row "${#REPLY}" "${C_MUTED}${REPLY}${C_RESET}"
    else
        local hw_fmt="${C_MUTED}GPU:  ${gpu_col}${GPU_LABEL} ${C_BORDER}${G_BULLET} ${conf_col}${conf_label}"
        if [[ -n "$EXISTING_DM" ]]; then
            hw_fmt+=" ${C_BORDER}${G_BULLET} ${C_MUTED}DM: ${C_FG}${EXISTING_DM%.service}"
        fi
        hw_fmt+="${C_RESET}"
        tui_box_row "${#hw_plain}" "$hw_fmt"
    fi
}

# ── TUI Screens ──────────────────────────────────────────────────────────────
draw_screen_profile() {
    frame_reset
    tui_render_header 1 25
    tui_box_top
    tui_host_summary_line
    tui_box_mid
    tui_box_text "Select installation profile" "${C_BOLD}${C_FG}"
    tui_box_empty

    local min_count="${#MINIMAL_PACKAGES[@]}"
    local full_count=$(( ${#MINIMAL_PACKAGES[@]} + ${#FULL_EXTRA_PACKAGES[@]} ))

    # Card 1: Minimal
    local desc_max=$(( TUI_BOX_W - 6 ))
    if [[ "$PROFILE" == "minimal" ]]; then
        local bg="$C_BG_SEL"
        local h_plain="${G_BAR} ${G_DOT_ON} Minimal    ${min_count} pkgs ${G_BULLET} 0 AUR   [Recommended]"
        tui_clip "$h_plain" "$TUI_BOX_W"
        local hc="$REPLY"
        local fmt="${C_ACTIVE_BORDER}${bg}${G_BAR} ${C_CYAN}${bg}${G_DOT_ON} ${C_BOLD}${C_FG}${bg}Minimal    ${C_CYAN}${bg}${min_count} pkgs ${G_BULLET} 0 AUR   ${C_GREEN}${bg}[Recommended]${C_RESET}"
        if (( ${#hc} < ${#h_plain} )); then fmt="${C_BOLD}${C_CYAN}${bg}${hc}${C_RESET}"; fi
        tui_box_row "${#hc}" "$fmt" "$bg"
        tui_clip "Hyprland 0.57 + Noctalia v5.x + Foot + Zsh" "$desc_max"
        tui_box_row "$(( 6 + ${#REPLY} ))" "${C_ACTIVE_BORDER}${bg}${G_BAR}     ${C_FG}${bg}${REPLY}${C_RESET}" "$bg"
        tui_clip "Budget: <=100 MiB idle PSS, 2 resident daemons" "$desc_max"
        tui_box_row "$(( 6 + ${#REPLY} ))" "${C_ACTIVE_BORDER}${bg}${G_BAR}     ${C_MUTED}${bg}${REPLY}${C_RESET}" "$bg"
    else
        local h_plain="  ${G_DOT_OFF} Minimal    ${min_count} pkgs ${G_BULLET} 0 AUR   [Recommended]"
        tui_clip "$h_plain" "$TUI_BOX_W"
        tui_box_row "${#REPLY}" "${C_FG}${REPLY}${C_RESET}"
        tui_clip "Hyprland 0.57 + Noctalia v5.x + Foot + Zsh" "$desc_max"
        tui_box_row "$(( 6 + ${#REPLY} ))" "${C_MUTED}      ${REPLY}${C_RESET}"
        tui_clip "Budget: <=100 MiB idle PSS, 2 resident daemons" "$desc_max"
        tui_box_row "$(( 6 + ${#REPLY} ))" "${C_MUTED}      ${REPLY}${C_RESET}"
    fi

    tui_box_empty

    # Card 2: Full
    if [[ "$PROFILE" == "full" ]]; then
        local bg="$C_BG_SEL"
        local h_plain="${G_BAR} ${G_DOT_ON} Full       ${full_count} pkgs ${G_BULLET} 0 AUR"
        tui_clip "$h_plain" "$TUI_BOX_W"
        local hc="$REPLY"
        local fmt="${C_ACTIVE_BORDER}${bg}${G_BAR} ${C_PURPLE}${bg}${G_DOT_ON} ${C_BOLD}${C_FG}${bg}Full       ${C_PURPLE}${bg}${full_count} pkgs ${G_BULLET} 0 AUR${C_RESET}"
        if (( ${#hc} < ${#h_plain} )); then fmt="${C_BOLD}${C_PURPLE}${bg}${hc}${C_RESET}"; fi
        tui_box_row "${#hc}" "$fmt" "$bg"
        tui_clip "+ wf-recorder, hyprpicker, wl-mirror, thunar, imv, zathura" "$desc_max"
        tui_box_row "$(( 6 + ${#REPLY} ))" "${C_ACTIVE_BORDER}${bg}${G_BAR}     ${C_FG}${bg}${REPLY}${C_RESET}" "$bg"
        tui_clip "+ fcitx5-bamboo, keyring, polkit_agent, starship & CLI" "$desc_max"
        tui_box_row "$(( 6 + ${#REPLY} ))" "${C_ACTIVE_BORDER}${bg}${G_BAR}     ${C_MUTED}${bg}${REPLY}${C_RESET}" "$bg"
    else
        local h_plain="  ${G_DOT_OFF} Full       ${full_count} pkgs ${G_BULLET} 0 AUR"
        tui_clip "$h_plain" "$TUI_BOX_W"
        tui_box_row "${#REPLY}" "${C_FG}${REPLY}${C_RESET}"
        tui_clip "+ wf-recorder, hyprpicker, wl-mirror, thunar, imv, zathura" "$desc_max"
        tui_box_row "$(( 6 + ${#REPLY} ))" "${C_MUTED}      ${REPLY}${C_RESET}"
        tui_clip "+ fcitx5-bamboo, keyring, polkit_agent, starship & CLI" "$desc_max"
        tui_box_row "$(( 6 + ${#REPLY} ))" "${C_MUTED}      ${REPLY}${C_RESET}"
    fi

    tui_box_bottom
    tui_render_footer "Up/Down Move   Enter Next   p Inspect Packages   q Quit"
    frame_flush "$FRAME_LINES"
}

draw_style_card() {
    local id="$1" title="$2" tag="$3" desc="$4"
    local selected=false
    [[ "$STYLE" == "$id" ]] && selected=true
    local desc_max=$(( TUI_BOX_W - 6 ))
    local tag_suffix=""
    [[ -n "$tag" ]] && tag_suffix="   ${tag}"

    if [[ "$selected" == true ]]; then
        local bg="$C_BG_SEL"
        local h_plain="${G_BAR} ${G_DOT_ON} ${title}${tag_suffix}"
        tui_clip "$h_plain" "$TUI_BOX_W"
        local hc="$REPLY"
        local tag_fmt=""
        [[ -n "$tag" ]] && tag_fmt="   ${C_GREEN}${bg}${tag}"
        local fmt="${C_ACTIVE_BORDER}${bg}${G_BAR} ${C_CYAN}${bg}${G_DOT_ON} ${C_BOLD}${C_FG}${bg}${title}${tag_fmt}${C_RESET}"
        if (( ${#hc} < ${#h_plain} )); then fmt="${C_BOLD}${C_CYAN}${bg}${hc}${C_RESET}"; fi
        tui_box_row "${#hc}" "$fmt" "$bg"
        tui_clip "$desc" "$desc_max"
        tui_box_row "$(( 6 + ${#REPLY} ))" "${C_ACTIVE_BORDER}${bg}${G_BAR}     ${C_MUTED}${bg}${REPLY}${C_RESET}" "$bg"
    else
        local h_plain="  ${G_DOT_OFF} ${title}${tag_suffix}"
        tui_clip "$h_plain" "$TUI_BOX_W"
        tui_box_row "${#REPLY}" "${C_FG}${REPLY}${C_RESET}"
        tui_clip "$desc" "$desc_max"
        tui_box_row "$(( 6 + ${#REPLY} ))" "${C_MUTED}      ${REPLY}${C_RESET}"
    fi
}

STYLE_IDS=(
    "omarchy-rail"
    "swiss-grid"
    "corner-hud"
    "ghost-zero"
    "dynamic-island"
    "hardware-notch"
    "glass-studio"
    "floating-rail"
    "tui-hacker"
    "retro-90s"
    "cinema-frame"
)
STYLE_TITLES=(
    "Omarchy / Brutalist"
    "Swiss Grid"
    "Corner HUD"
    "Ghost / Zero-Bar"
    "Dynamic Island"
    "Hardware Notch"
    "Glass Studio"
    "Floating Rail"
    "TUI / Hacker Frame"
    "Retro 90s / Pixel OS"
    "Cinema Frame"
)
STYLE_GROUPS=(
    "Angular"
    "Angular"
    "Angular"
    "Angular"
    "Dynamic"
    "Dynamic"
    "Dynamic"
    "Dynamic"
    "Retro"
    "Retro"
    "Retro"
)
STYLE_TAGS=(
    ""
    ""
    ""
    ""
    "[Default]"
    ""
    ""
    ""
    ""
    ""
    ""
)
STYLE_DESCS=(
    "Flush left 42px industrial rail, 0px corners, 2px borders"
    "Warm paper light grid, 1px lines, text-only top bar"
    "Two corner clusters with empty center horizon"
    "0px edge-to-edge windows; hold Super or edge to peek bar"
    "Centered black pill expanding on media, record & share"
    "Flush top center hardware notch with concave corners"
    "28px frosted top bar + auto-hiding bottom dock"
    "Top window/clock pill + left workspace/app rail"
    "Monospace [ bracketed ] clusters & phosphor CRT palette"
    "Win95/BeOS bottom taskbar, Start button & 2-tone bevels"
    "Wide 28px gallery margins + slim 22px bottom subtitle"
)
STYLE_SCROLL=0

style_index_of() {
    local target="$1" i
    for (( i=0; i<${#STYLE_IDS[@]}; i++ )); do
        if [[ "${STYLE_IDS[$i]}" == "$target" ]]; then
            echo "$i"
            return 0
        fi
    done
    echo "4"
}

draw_screen_style() {
    frame_reset
    tui_render_header 2
    tui_box_top
    tui_box_text "Select visual preset (0 extra daemons, 0 polling)" "${C_BOLD}${C_FG}"
    tui_box_mid

    local total="${#STYLE_IDS[@]}"
    local sel_idx
    sel_idx="$(style_index_of "$STYLE")"
    local max_cards=$(( (TERM_ROWS - 14) / 2 ))
    if (( TERM_ROWS < 23 )); then
        max_cards=$(( (TERM_ROWS - 8) / 2 ))
    fi
    (( max_cards < 3 )) && max_cards=3
    (( max_cards > total )) && max_cards=$total

    if (( sel_idx < STYLE_SCROLL )); then
        STYLE_SCROLL=$sel_idx
    elif (( sel_idx >= STYLE_SCROLL + max_cards )); then
        STYLE_SCROLL=$(( sel_idx - max_cards + 1 ))
    fi
    local max_scroll=$(( total - max_cards ))
    (( max_scroll < 0 )) && max_scroll=0
    (( STYLE_SCROLL > max_scroll )) && STYLE_SCROLL=$max_scroll
    (( STYLE_SCROLL < 0 )) && STYLE_SCROLL=0

    local end=$(( STYLE_SCROLL + max_cards ))
    (( end > total )) && end=$total
    local i num tag_txt
    for (( i=STYLE_SCROLL; i<end; i++ )); do
        num=$(( i + 1 ))
        tag_txt="[${STYLE_GROUPS[$i]}]"
        if [[ -n "${STYLE_TAGS[$i]}" ]]; then
            tag_txt+=" ${STYLE_TAGS[$i]}"
        fi
        draw_style_card "${STYLE_IDS[$i]}" "${num}. ${STYLE_TITLES[$i]}" "$tag_txt" "${STYLE_DESCS[$i]}"
    done

    if (( max_scroll > 0 )); then
        tui_box_mid
        tui_box_text "Showing $(( STYLE_SCROLL + 1 ))-${end} of ${total} presets (Up/Down or PgUp/PgDn to scroll)" "$C_MUTED"
    fi

    tui_box_bottom
    tui_render_footer "Up/Down/PgUp/PgDn Move   1-9 Jump   Enter Next   Esc Back   p Packages"
    frame_flush "$FRAME_LINES"
}

draw_opt_row() {
    local idx="$1" box="$2" label="$3" note="${4:-}" enabled="${5:-true}"
    local focused=false
    (( OPT_IDX == idx )) && focused=true

    local bg="" bar=" " mark_col="$C_CYAN" text_col="$C_FG"
    if [[ "$focused" == true ]]; then
        bg="$C_BG_SEL"
        bar="$G_BAR"
    fi
    if [[ "$enabled" == false ]]; then
        mark_col="$C_MUTED"
        text_col="$C_MUTED"
    elif [[ "$focused" == true ]]; then
        text_col="${C_BOLD}${C_FG}"
    fi

    local max_lbl=$(( TUI_BOX_W - 6 ))
    tui_clip "$label" "$max_lbl"
    local lbl_c="$REPLY"
    local plain_len=$(( 6 + ${#lbl_c} ))
    local fmt=""
    if [[ "$focused" == true ]]; then
        fmt="${C_ACTIVE_BORDER}${bg}${bar} ${C_BORDER}${bg}[${mark_col}${bg}${box}${C_BORDER}${bg}] ${text_col}${bg}${lbl_c}${C_RESET}"
    else
        fmt="${bar} ${C_BORDER}[${mark_col}${box}${C_BORDER}] ${text_col}${lbl_c}${C_RESET}"
    fi
    tui_box_row "$plain_len" "$fmt" "$bg"

    if [[ -n "$note" ]]; then
        tui_clip "$note" "$max_lbl"
        local note_c="$REPLY"
        if [[ "$focused" == true ]]; then
            tui_box_row "$(( 6 + ${#note_c} ))" "${C_ACTIVE_BORDER}${bg}${bar}     ${C_MUTED}${bg}${note_c}${C_RESET}" "$bg"
        else
            tui_box_row "$(( 6 + ${#note_c} ))" "${C_MUTED}      ${note_c}${C_RESET}"
        fi
    fi
}

OPT_KEYS=()
OPT_SCROLL=0

build_options_list() {
    OPT_KEYS=(pkg noconfirm syssetup zsh dm aur)
    if [[ "$GPU_MODE" == "hybrid-laptop" && "$HAS_USER_LUA" == false ]]; then
        OPT_KEYS+=(hybrid_gpu)
    fi
    OPT_KEYS+=(reboot buttons)
}

draw_opt_cycle_row() {
    local idx="$1" label="$2" val="$3" val_col="${4:-$C_CYAN}"
    local focused=false
    (( OPT_IDX == idx )) && focused=true
    local rbg="" rbar=" "
    [[ "$focused" == true ]] && { rbg="$C_BG_SEL"; rbar="$G_BAR"; }
    local pad_spaces=""
    local key_w=20
    local pad_n=$(( key_w - ${#label} ))
    (( pad_n < 1 )) && pad_n=1
    tui_spaces "$pad_n"
    pad_spaces="$REPLY"
    local rplain="${rbar} [${G_DOT_ON}] ${label}${pad_spaces}< ${val} >"
    tui_clip "$rplain" "$TUI_BOX_W"
    local rc="$REPLY"
    if (( ${#rc} == ${#rplain} )); then
        local rfmt=""
        if [[ "$focused" == true ]]; then
            rfmt="${C_ACTIVE_BORDER}${rbg}${rbar} ${C_BORDER}${rbg}[${C_CYAN}${rbg}${G_DOT_ON}${C_BORDER}${rbg}] ${C_BOLD}${C_FG}${rbg}${label}${pad_spaces}${C_MUTED}${rbg}< ${val_col}${rbg}${val} ${C_MUTED}${rbg}>${C_RESET}"
        else
            rfmt="${rbar} ${C_BORDER}[${C_CYAN}${G_DOT_ON}${C_BORDER}] ${C_FG}${label}${pad_spaces}${C_MUTED}< ${val_col}${val} ${C_MUTED}>${C_RESET}"
        fi
        tui_box_row "${#rc}" "$rfmt" "$rbg"
    else
        tui_box_row "${#rc}" "${C_FG}${rbg}${rc}${C_RESET}" "$rbg"
    fi
}

draw_screen_options() {
    frame_reset
    tui_render_header 3
    tui_box_top

    build_options_list
    compute_pacman_packages
    local prof_upper="MINIMAL"
    local prof_col="$C_CYAN"
    if [[ "$PROFILE" == "full" ]]; then
        prof_upper="FULL"
        prof_col="$C_PURPLE"
    fi
    local pkg_total_lbl="${#ALL_PACMAN_PACKAGES[@]} pkgs"
    local hdr_plain="Profile: ${prof_upper} (${pkg_total_lbl}) ${G_BULLET} Style: ${STYLE}"
    tui_clip "$hdr_plain" "$TUI_BOX_W"
    local hc="$REPLY"
    if (( ${#hc} == ${#hdr_plain} )); then
        tui_box_row "${#hc}" "${C_MUTED}Profile: ${C_BOLD}${prof_col}${prof_upper} ${C_MUTED}(${pkg_total_lbl}) ${G_BULLET} Style: ${C_CYAN}${STYLE}${C_RESET}"
    else
        tui_box_row "${#hc}" "${prof_col}${hc}${C_RESET}"
    fi
    tui_box_mid

    local total_keys="${#OPT_KEYS[@]}"
    local opt_count=$(( total_keys - 1 ))
    local btn_idx="$opt_count"

    local max_vis=$(( TERM_ROWS - 18 ))
    (( TERM_ROWS < 23 )) && max_vis=$(( TERM_ROWS - 12 ))
    (( max_vis < 4 )) && max_vis=4
    local cur_item="$OPT_IDX"
    (( cur_item >= opt_count )) && cur_item=$(( opt_count - 1 ))
    if (( cur_item < OPT_SCROLL )); then
        OPT_SCROLL=$cur_item
    elif (( cur_item >= OPT_SCROLL + max_vis )); then
        OPT_SCROLL=$(( cur_item - max_vis + 1 ))
    fi
    local max_scroll=$(( opt_count - max_vis ))
    (( max_scroll < 0 )) && max_scroll=0
    (( OPT_SCROLL > max_scroll )) && OPT_SCROLL=$max_scroll
    (( OPT_SCROLL < 0 )) && OPT_SCROLL=0

    local end=$(( OPT_SCROLL + max_vis ))
    (( end > opt_count )) && end=$opt_count

    local i opt_key
    for (( i=OPT_SCROLL; i<end; i++ )); do
        opt_key="${OPT_KEYS[$i]}"
        case "$opt_key" in
            pkg)
                local pkg_mark="$G_CHECK" pkg_note=""
                if (( TERM_ROWS >= 26 )); then
                    pkg_note="Runs sudo pacman -Syu --needed (uncheck for dotfiles only)"
                fi
                if [[ "$SKIP_PACKAGES" == true ]]; then
                    pkg_mark=" "
                    if (( TERM_ROWS >= 26 )); then
                        if [[ "$HAS_ARCH" == false || "$HAS_PACMAN" == false ]]; then
                            pkg_note="Skipped (pacman unavailable — dotfiles-only mode)"
                        else
                            pkg_note="Skipped (--skip-packages, deploying dotfiles only)"
                        fi
                    fi
                fi
                draw_opt_row "$i" "$pkg_mark" "Install & sync official Arch packages (pacman -Syu)" "$pkg_note" "true"
                ;;
            noconfirm)
                local nc_mark=" " nc_enabled="true"
                [[ "$PACMAN_NOCONFIRM" == true ]] && nc_mark="$G_CHECK"
                [[ "$SKIP_PACKAGES" == true ]] && nc_enabled="false"
                draw_opt_row "$i" "$nc_mark" "Auto-confirm pacman prompts (--noconfirm)" "" "$nc_enabled"
                ;;
            syssetup)
                local sys_mark=" "
                [[ "$SYSTEM_SETUP" == "true" ]] && sys_mark="$G_CHECK"
                draw_opt_row "$i" "$sys_mark" "System setup (NM, Bluetooth, PipeWire, video, fc-cache)" "" "true"
                ;;
            zsh)
                local zsh_mark=" "
                [[ "$SET_ZSH" == "true" ]] && zsh_mark="$G_CHECK"
                local zsh_label="Set Zsh as default login shell (chsh)"
                if [[ "$CURRENT_SHELL_BIN" == */zsh ]]; then
                    zsh_label="Set Zsh as default login shell (already zsh)"
                fi
                draw_opt_row "$i" "$zsh_mark" "$zsh_label" "" "true"
                ;;
            dm)
                local dm_label="None (TTY1)" dm_col="$C_MUTED"
                case "$DM_CHOICE" in
                    ly)     dm_label="ly";               dm_col="$C_CYAN" ;;
                    greetd) dm_label="greetd + tuigreet"; dm_col="$C_CYAN" ;;
                esac
                draw_opt_cycle_row "$i" "Display Manager:" "$dm_label" "$dm_col"
                ;;
            aur)
                local aur_label="None (0 AUR)" aur_col="$C_GREEN"
                case "$AUR_HELPER" in
                    yay-bin)  aur_label="yay-bin";  aur_col="$C_PURPLE" ;;
                    paru-bin) aur_label="paru-bin"; aur_col="$C_PURPLE" ;;
                esac
                draw_opt_cycle_row "$i" "AUR Helper (opt-in):" "$aur_label" "$aur_col"
                ;;
            hybrid_gpu)
                local hgpu_mark=" "
                [[ "$AUTO_HYBRID_GPU" == true ]] && hgpu_mark="$G_CHECK"
                draw_opt_row "$i" "$hgpu_mark" "Seed Hybrid GPU (${GPU_IGPU_CARD} + Mesa EGL) in user.lua" "" "true"
                ;;
            reboot)
                local reb_label="Ask before rebooting" reb_col="$C_CYAN"
                case "$REBOOT" in
                    yes) reb_label="Reboot automatically"; reb_col="$C_YELLOW" ;;
                    no)  reb_label="Stay in shell";        reb_col="$C_MUTED" ;;
                esac
                draw_opt_cycle_row "$i" "After install:" "$reb_label" "$reb_col"
                ;;
        esac
    done

    if (( max_scroll > 0 )); then
        tui_box_text "Showing options $(( OPT_SCROLL + 1 ))-${end} of ${opt_count} (Up/Down to scroll)" "$C_MUTED"
    else
        tui_box_empty
    fi

    local b1=" Continue to Review ${G_ARROW_R} "
    local b2=" ${G_ARROW_L} Back "
    local b_plain="  [${b1}]   [${b2}]"
    local b1_s="$C_BTN_IDLE" b2_s="$C_BTN_IDLE"
    if (( OPT_IDX == btn_idx )); then
        if (( OPT_BTN == 0 )); then
            b1_s="$C_BTN_ACTIVE"
        else
            b2_s="$C_BTN_ACTIVE"
        fi
    else
        b1_s="${C_BG_SEL}${C_CYAN}"
    fi
    local bfmt="  ${b1_s}[${b1}]${C_RESET}   ${b2_s}[${b2}]${C_RESET}"
    tui_box_row "${#b_plain}" "$bfmt"

    tui_box_bottom
    tui_render_footer "Up/Down Move   Space Toggle   Left/Right Cycle   Enter Continue   Esc Back"
    frame_flush "$FRAME_LINES"
}

draw_screen_review() {
    frame_reset
    tui_render_header 4 31
    tui_box_top
    tui_box_text "Pre-flight review before writing changes" "${C_BOLD}${C_FG}"
    tui_box_mid

    compute_pacman_packages
    local prof_col="$C_CYAN"
    [[ "$PROFILE" == "full" ]] && prof_col="$C_PURPLE"
    local prof_extra=""
    (( ${#ADDON_PACKAGES[@]} > 0 )) && prof_extra=" + ${#ADDON_PACKAGES[@]} add-on"
    tui_box_kv 14 "Profile" "${PROFILE} (${#PACKAGES[@]} core${prof_extra} official pkgs, 0 AUR)" "$prof_col"
    tui_box_kv 14 "Visual style" "${STYLE} (switch anytime via kaze-style / Super+Shift+I)" "$C_CYAN"

    local pkg_desc="sudo pacman -Syu --needed"
    [[ "$PACMAN_NOCONFIRM" == true ]] && pkg_desc+=" --noconfirm"
    pkg_desc+=" (${#ALL_PACMAN_PACKAGES[@]} pkgs)"
    if [[ "$SKIP_PACKAGES" == true ]]; then
        pkg_desc="Skipped (--skip-packages, dotfiles only)"
        tui_box_kv 14 "Packages" "$pkg_desc" "$C_YELLOW"
    else
        tui_box_kv 14 "Packages" "$pkg_desc" "$C_FG"
    fi

    local sys_desc="Skipped"
    [[ "$SYSTEM_SETUP" == "true" ]] && sys_desc="Enable NM (if unused), BT, PipeWire, video, fc-cache"
    tui_box_kv 14 "System setup" "$sys_desc" "$C_FG"

    local dm_desc="None (TTY1 auto-start via ~/.zprofile)"
    case "$DM_CHOICE" in
        ly)     dm_desc="ly (ly@tty1.service)" ;;
        greetd) dm_desc="greetd + tuigreet (/etc/greetd/config.toml)" ;;
    esac
    tui_box_kv 14 "Display mgr" "$dm_desc" "$C_FG"

    local aur_desc="None (0 AUR)"
    [[ "$AUR_HELPER" != "none" ]] && aur_desc="${AUR_HELPER} (opt-in after core install)"
    tui_box_kv 14 "AUR helper" "$aur_desc" "$C_FG"

    if [[ "$GPU_MODE" == "hybrid-laptop" && "$HAS_USER_LUA" == false ]]; then
        local hgpu_desc="Disabled"
        [[ "$AUTO_HYBRID_GPU" == true ]] && hgpu_desc="Seed ${GPU_IGPU_CARD} + prefer_mesa_egl in new user.lua"
        tui_box_kv 14 "Hybrid GPU" "$hgpu_desc" "$C_GREEN"
    fi

    local zsh_desc="Keep current (${CURRENT_SHELL_BIN:-unchanged})"
    [[ "$SET_ZSH" == "true" ]] && zsh_desc="Switch to /usr/bin/zsh (if not already)"
    tui_box_kv 14 "Login shell" "$zsh_desc" "$C_FG"

    local reb_desc="Ask after installation"
    case "$REBOOT" in
        yes) reb_desc="Reboot automatically (sudo systemctl reboot)" ;;
        no)  reb_desc="Stay in shell" ;;
    esac
    tui_box_kv 14 "After install" "$reb_desc" "$C_FG"

    local log_desc="${LOG_FILE:-Disabled (--no-log)}"
    tui_box_kv 14 "Install log" "$log_desc" "$C_MUTED"

    if (( ${#CONFLICT_HARD[@]} > 0 )) || (( ${#CONFLICT_SOFT[@]} > 0 )); then
        tui_box_mid
        local warn_max=$(( TUI_BOX_W - 2 ))
        if (( ${#CONFLICT_HARD[@]} > 0 )); then
            tui_clip "Hard conflict (prompts pacman -Rdd): ${CONFLICT_HARD[*]}" "$warn_max"
            tui_box_row "$(( 2 + ${#REPLY} ))" "${C_RED}! ${REPLY}${C_RESET}"
        fi
        if (( ${#CONFLICT_SOFT[@]} > 0 )); then
            tui_clip "Soft conflict (manual pacman -Rns): ${CONFLICT_SOFT[*]}" "$warn_max"
            tui_box_row "$(( 2 + ${#REPLY} ))" "${C_YELLOW}! ${REPLY}${C_RESET}"
        fi
    fi

    tui_box_mid
    local chk_max=$(( TUI_BOX_W - 2 ))
    tui_clip "Automatic backup & reversible rollback.sh before replacing" "$chk_max"
    tui_box_row "$(( 2 + ${#REPLY} ))" "${C_GREEN}${G_CHECK} ${C_FG}${REPLY}${C_RESET}"
    tui_clip "Preserves hypr/user.lua, zsh/user.zsh & Noctalia GUI edits" "$chk_max"
    tui_box_row "$(( 2 + ${#REPLY} ))" "${C_GREEN}${G_CHECK} ${C_FG}${REPLY}${C_RESET}"
    if (( TERM_ROWS > 25 )); then
        tui_box_empty
    fi

    local a1=" Install kaze-dots " a2=" ${G_ARROW_L} Back " a3=" Abort "
    local s1="$C_BTN_IDLE" s2="$C_BTN_IDLE" s3="$C_BTN_IDLE"
    case "$REV_BTN" in
        0) s1="$C_BTN_ACTIVE" ;;
        1) s2="$C_BTN_ACTIVE" ;;
        2) s3="$C_BTN_ACTIVE" ;;
    esac
    local ap="  [${a1}]   [${a2}]   [${a3}]"
    local af="  ${s1}[${a1}]${C_RESET}   ${s2}[${a2}]${C_RESET}   ${s3}[${a3}]${C_RESET}"
    tui_box_row "${#ap}" "$af"

    tui_box_bottom
    tui_render_footer "Left/Right Select Action   Enter Confirm   p Inspect Packages   Esc Back"
    frame_flush "$FRAME_LINES"
}

PKG_MODAL_LINES=()
PKG_MODAL_STYLES=()

add_pkg_group() {
    local title="$1" style="$2"
    shift 2
    local pkgs=("$@")
    local prefix="  "
    local label_w=16
    local max_line=$(( TUI_BOX_W - label_w ))
    local cur="" p next
    local first=true

    tui_spaces "$(( label_w - ${#title} - 2 ))"
    local kpad="$REPLY"
    tui_spaces "$label_w"
    local blank_k="$REPLY"

    for p in "${pkgs[@]}"; do
        if [[ -z "$cur" ]]; then
            cur="$p"
        else
            next="${cur}, ${p}"
            if (( ${#next} <= max_line )); then
                cur="$next"
            else
                if [[ "$first" == true ]]; then
                    PKG_MODAL_LINES+=("${prefix}${title}${kpad}${cur}")
                    PKG_MODAL_STYLES+=("$style")
                    first=false
                else
                    PKG_MODAL_LINES+=("${blank_k}${cur}")
                    PKG_MODAL_STYLES+=("CONT")
                fi
                cur="$p"
            fi
        fi
    done
    if [[ -n "$cur" ]]; then
        if [[ "$first" == true ]]; then
            PKG_MODAL_LINES+=("${prefix}${title}${kpad}${cur}")
            PKG_MODAL_STYLES+=("$style")
        else
            PKG_MODAL_LINES+=("${blank_k}${cur}")
            PKG_MODAL_STYLES+=("CONT")
        fi
    fi
}

build_pkg_modal_lines() {
    PKG_MODAL_LINES=()
    PKG_MODAL_STYLES=()
    add_pkg_group "Desktop" "$C_CYAN" "${PKG_MIN_DESKTOP[@]}"
    add_pkg_group "Portals" "$C_CYAN" "${PKG_MIN_PORTALS[@]}"
    add_pkg_group "Terminal/Zsh" "$C_CYAN" "${PKG_MIN_TERM[@]}"
    add_pkg_group "Audio" "$C_CYAN" "${PKG_MIN_AUDIO[@]}"
    add_pkg_group "System" "$C_CYAN" "${PKG_MIN_SYS[@]}"
    add_pkg_group "Fonts/Lua" "$C_CYAN" "${PKG_MIN_FONTS[@]}"
    if [[ "$PROFILE" == "full" ]]; then
        PKG_MODAL_LINES+=("  Full Extras (+${#FULL_EXTRA_PACKAGES[@]} official Arch packages)")
        PKG_MODAL_STYLES+=("HDR")
        add_pkg_group "Capture/Share" "$C_PURPLE" "${PKG_FULL_CAPTURE[@]}"
        add_pkg_group "Apps/Docs" "$C_PURPLE" "${PKG_FULL_APPS[@]}"
        add_pkg_group "IME/Keyring" "$C_PURPLE" "${PKG_FULL_IME[@]}"
        add_pkg_group "Modern CLI" "$C_PURPLE" "${PKG_FULL_CLI[@]}"
    fi
    if [[ "$DM_CHOICE" != "none" || "$AUR_HELPER" != "none" ]]; then
        PKG_MODAL_LINES+=("  Optional Add-ons")
        PKG_MODAL_STYLES+=("HDR")
        if [[ "$DM_CHOICE" == "ly" ]]; then
            add_pkg_group "Display Mgr" "$C_CYAN" "${PKG_DM_LY[@]}"
        elif [[ "$DM_CHOICE" == "greetd" ]]; then
            add_pkg_group "Display Mgr" "$C_CYAN" "${PKG_DM_GREETD[@]}"
        fi
        if [[ "$AUR_HELPER" != "none" ]]; then
            add_pkg_group "AUR Prereqs" "$C_PURPLE" "${PKG_AUR_PREREQS[@]}"
        fi
    fi
}

draw_screen_packages() {
    frame_reset
    local step_num=1
    [[ "$TUI_PREV_SCREEN" == "style" ]] && step_num=2
    [[ "$TUI_PREV_SCREEN" == "options" ]] && step_num=3
    [[ "$TUI_PREV_SCREEN" == "review" ]] && step_num=4
    tui_render_header "$step_num"
    tui_box_top

    get_packages_for_profile "$PROFILE"
    build_pkg_modal_lines

    local max_vis=$(( TERM_ROWS - 15 ))
    if (( TERM_ROWS < 23 )); then
        max_vis=$(( TERM_ROWS - 9 ))
    fi
    (( max_vis < 5 )) && max_vis=5
    (( max_vis > 16 )) && max_vis=16
    local total="${#PKG_MODAL_LINES[@]}"
    local max_scroll=$(( total - max_vis ))
    (( max_scroll < 0 )) && max_scroll=0
    (( TUI_SCROLL > max_scroll )) && TUI_SCROLL=$max_scroll
    (( TUI_SCROLL < 0 )) && TUI_SCROLL=0

    local hdr_plain="Package Manifest: ${PROFILE} (${#PACKAGES[@]} official Arch pkgs ${G_BULLET} 0 AUR)"
    tui_clip "$hdr_plain" "$TUI_BOX_W"
    tui_box_row "${#REPLY}" "${C_BOLD}${C_FG}${REPLY}${C_RESET}"
    tui_box_mid

    local end=$(( TUI_SCROLL + max_vis ))
    (( end > total )) && end=$total
    local i line st
    for (( i=TUI_SCROLL; i<end; i++ )); do
        line="${PKG_MODAL_LINES[$i]}"
        st="${PKG_MODAL_STYLES[$i]}"
        if [[ "$st" == "HDR" ]]; then
            tui_clip "$line" "$TUI_BOX_W"
            tui_box_row "${#REPLY}" "${C_BOLD}${C_PURPLE}${REPLY}${C_RESET}"
        elif [[ "$st" == "CONT" ]]; then
            tui_clip "$line" "$TUI_BOX_W"
            tui_box_row "${#REPLY}" "${C_FG}${REPLY}${C_RESET}"
        else
            tui_clip "$line" "$TUI_BOX_W"
            local cl="$REPLY"
            local head="${cl:0:16}"
            local tail="${cl:16}"
            tui_box_row "${#cl}" "${st}${head}${C_FG}${tail}${C_RESET}"
        fi
    done

    while (( end - TUI_SCROLL < max_vis && end - TUI_SCROLL < 5 )); do
        tui_box_empty
        end=$(( end + 1 ))
    done

    if (( max_scroll > 0 )); then
        tui_box_mid
        local shown_from=$(( TUI_SCROLL + 1 ))
        local shown_to=$(( TUI_SCROLL + max_vis ))
        (( shown_to > total )) && shown_to=$total
        tui_box_text "Showing lines ${shown_from}-${shown_to} of ${total} (Up/Down or PgUp/PgDn to scroll)" "$C_MUTED"
    fi

    tui_box_bottom
    tui_render_footer "Up/Down Scroll   Esc / p / Enter Back"
    frame_flush "$FRAME_LINES"
}

run_tui_wizard() {
    TUI_SCREEN="profile"
    TUI_PREV_SCREEN="profile"
    TUI_STATUS_MSG=""
    TUI_SCROLL=0
    OPT_IDX=0
    OPT_BTN=0
    REV_BTN=0

    # Smart defaults when flags were not explicitly forced
    resolve_effective_defaults
    build_options_list

    tui_enter

    while true; do
        tui_measure_term
        case "$TUI_SCREEN" in
            profile)  draw_screen_profile ;;
            style)    draw_screen_style ;;
            options)  draw_screen_options ;;
            review)   draw_screen_review ;;
            packages) draw_screen_packages ;;
        esac
        TUI_STATUS_MSG=""

        tui_read_key
        local key="$REPLY"
        [[ "$key" == "EOF" ]] && { tui_leave; exit 1; }

        case "$TUI_SCREEN" in
            profile)
                case "$key" in
                    UP|DOWN)
                        if [[ "$PROFILE" == "minimal" ]]; then
                            PROFILE="full"
                        else
                            PROFILE="minimal"
                        fi
                        ;;
                    1) PROFILE="minimal" ;;
                    2) PROFILE="full" ;;
                    ENTER|RIGHT|TAB)
                        TUI_SCREEN="style"
                        ;;
                    p|P)
                        TUI_PREV_SCREEN="profile"
                        TUI_SCROLL=0
                        TUI_SCREEN="packages"
                        ;;
                    q|Q|ESC)
                        tui_leave
                        echo "Aborted."
                        exit 1
                        ;;
                esac
                ;;
            style)
                local s_idx s_total="${#STYLE_IDS[@]}"
                s_idx="$(style_index_of "$STYLE")"
                case "$key" in
                    UP)
                        s_idx=$(( (s_idx - 1 + s_total) % s_total ))
                        STYLE="${STYLE_IDS[$s_idx]}"
                        STYLE_EXPLICIT=true
                        ;;
                    DOWN)
                        s_idx=$(( (s_idx + 1) % s_total ))
                        STYLE="${STYLE_IDS[$s_idx]}"
                        STYLE_EXPLICIT=true
                        ;;
                    PGUP)
                        s_idx=$(( s_idx - 4 ))
                        (( s_idx < 0 )) && s_idx=0
                        STYLE="${STYLE_IDS[$s_idx]}"
                        STYLE_EXPLICIT=true
                        ;;
                    PGDN)
                        s_idx=$(( s_idx + 4 ))
                        (( s_idx >= s_total )) && s_idx=$(( s_total - 1 ))
                        STYLE="${STYLE_IDS[$s_idx]}"
                        STYLE_EXPLICIT=true
                        ;;
                    1|2|3|4|5|6|7|8|9)
                        STYLE="${STYLE_IDS[$(( key - 1 ))]}"
                        STYLE_EXPLICIT=true
                        ;;
                    0)
                        STYLE="${STYLE_IDS[9]}"
                        STYLE_EXPLICIT=true
                        ;;
                    ENTER|RIGHT|TAB)
                        TUI_SCREEN="options"
                        ;;
                    LEFT|b|B|ESC)
                        TUI_SCREEN="profile"
                        ;;
                    p|P)
                        TUI_PREV_SCREEN="style"
                        TUI_SCROLL=0
                        TUI_SCREEN="packages"
                        ;;
                    q|Q)
                        tui_leave
                        echo "Aborted."
                        exit 1
                        ;;
                esac
                ;;
            options)
                build_options_list
                local opt_total="${#OPT_KEYS[@]}"
                local btn_idx=$(( opt_total - 1 ))
                local cur_key="${OPT_KEYS[$OPT_IDX]}"
                case "$key" in
                    UP)
                        OPT_IDX=$(( (OPT_IDX + opt_total - 1) % opt_total ))
                        ;;
                    DOWN)
                        OPT_IDX=$(( (OPT_IDX + 1) % opt_total ))
                        ;;
                    TAB)
                        if (( OPT_IDX < btn_idx )); then
                            OPT_IDX=$btn_idx
                            OPT_BTN=0
                        else
                            OPT_BTN=$(( (OPT_BTN + 1) % 2 ))
                        fi
                        ;;
                    LEFT|RIGHT)
                        if [[ "$cur_key" == "dm" ]]; then
                            if [[ "$HAS_ARCH" == false || "$HAS_PACMAN" == false ]]; then
                                TUI_STATUS_MSG="pacman unavailable on this host; display manager setup requires Arch"
                            elif [[ "$key" == "RIGHT" ]]; then
                                case "$DM_CHOICE" in
                                    none)   DM_CHOICE="ly" ;;
                                    ly)     DM_CHOICE="greetd" ;;
                                    greetd) DM_CHOICE="none" ;;
                                esac
                            else
                                case "$DM_CHOICE" in
                                    none)   DM_CHOICE="greetd" ;;
                                    greetd) DM_CHOICE="ly" ;;
                                    ly)     DM_CHOICE="none" ;;
                                esac
                            fi
                        elif [[ "$cur_key" == "aur" ]]; then
                            if [[ "$HAS_ARCH" == false || "$HAS_PACMAN" == false ]]; then
                                TUI_STATUS_MSG="pacman unavailable on this host; AUR helper requires Arch"
                            elif [[ "$key" == "RIGHT" ]]; then
                                case "$AUR_HELPER" in
                                    none)     AUR_HELPER="yay-bin" ;;
                                    yay-bin)  AUR_HELPER="paru-bin" ;;
                                    paru-bin) AUR_HELPER="none" ;;
                                esac
                            else
                                case "$AUR_HELPER" in
                                    none)     AUR_HELPER="paru-bin" ;;
                                    paru-bin) AUR_HELPER="yay-bin" ;;
                                    yay-bin)  AUR_HELPER="none" ;;
                                esac
                            fi
                        elif [[ "$cur_key" == "reboot" ]]; then
                            if [[ "$key" == "RIGHT" ]]; then
                                case "$REBOOT" in
                                    auto) REBOOT="yes" ;;
                                    yes)  REBOOT="no" ;;
                                    no)   REBOOT="auto" ;;
                                esac
                            else
                                case "$REBOOT" in
                                    auto) REBOOT="no" ;;
                                    no)   REBOOT="yes" ;;
                                    yes)  REBOOT="auto" ;;
                                esac
                            fi
                        elif [[ "$cur_key" == "buttons" ]]; then
                            OPT_BTN=$(( (OPT_BTN + 1) % 2 ))
                        elif [[ "$key" == "LEFT" ]]; then
                            TUI_SCREEN="style"
                        fi
                        ;;
                    SPACE)
                        case "$cur_key" in
                            pkg)
                                if [[ "$SKIP_PACKAGES" == true ]]; then
                                    if [[ "$HAS_ARCH" == false || "$HAS_PACMAN" == false ]]; then
                                        TUI_STATUS_MSG="pacman unavailable on this host; dotfiles-only mode required"
                                    else
                                        SKIP_PACKAGES=false
                                        [[ "$SYSTEM_SETUP_EXPLICIT" == false ]] && SYSTEM_SETUP="true"
                                        [[ "$SET_ZSH_EXPLICIT" == false ]] && SET_ZSH="true"
                                    fi
                                else
                                    SKIP_PACKAGES=true
                                    [[ "$SYSTEM_SETUP_EXPLICIT" == false ]] && SYSTEM_SETUP="false"
                                    [[ "$SET_ZSH_EXPLICIT" == false ]] && SET_ZSH="false"
                                fi
                                ;;
                            noconfirm)
                                if [[ "$SKIP_PACKAGES" == true ]]; then
                                    TUI_STATUS_MSG="Enable package installation first to toggle --noconfirm"
                                else
                                    if [[ "$PACMAN_NOCONFIRM" == true ]]; then
                                        PACMAN_NOCONFIRM=false
                                    else
                                        PACMAN_NOCONFIRM=true
                                    fi
                                fi
                                ;;
                            syssetup)
                                SYSTEM_SETUP_EXPLICIT=true
                                if [[ "$SYSTEM_SETUP" == "true" ]]; then
                                    SYSTEM_SETUP="false"
                                else
                                    SYSTEM_SETUP="true"
                                fi
                                ;;
                            zsh)
                                SET_ZSH_EXPLICIT=true
                                if [[ "$SET_ZSH" == "true" ]]; then
                                    SET_ZSH="false"
                                else
                                    SET_ZSH="true"
                                fi
                                ;;
                            dm)
                                if [[ "$HAS_ARCH" == false || "$HAS_PACMAN" == false ]]; then
                                    TUI_STATUS_MSG="pacman unavailable on this host; display manager setup requires Arch"
                                else
                                    case "$DM_CHOICE" in
                                        none)   DM_CHOICE="ly" ;;
                                        ly)     DM_CHOICE="greetd" ;;
                                        greetd) DM_CHOICE="none" ;;
                                    esac
                                fi
                                ;;
                            aur)
                                if [[ "$HAS_ARCH" == false || "$HAS_PACMAN" == false ]]; then
                                    TUI_STATUS_MSG="pacman unavailable on this host; AUR helper requires Arch"
                                else
                                    case "$AUR_HELPER" in
                                        none)     AUR_HELPER="yay-bin" ;;
                                        yay-bin)  AUR_HELPER="paru-bin" ;;
                                        paru-bin) AUR_HELPER="none" ;;
                                    esac
                                fi
                                ;;
                            hybrid_gpu)
                                if [[ "$AUTO_HYBRID_GPU" == true ]]; then
                                    AUTO_HYBRID_GPU=false
                                else
                                    AUTO_HYBRID_GPU=true
                                fi
                                ;;
                            reboot)
                                case "$REBOOT" in
                                    auto) REBOOT="yes" ;;
                                    yes)  REBOOT="no" ;;
                                    no)   REBOOT="auto" ;;
                                esac
                                ;;
                            buttons)
                                if (( OPT_BTN == 0 )); then
                                    TUI_SCREEN="review"
                                else
                                    TUI_SCREEN="style"
                                fi
                                ;;
                        esac
                        ;;
                    ENTER)
                        if [[ "$cur_key" == "buttons" ]] && (( OPT_BTN == 1 )); then
                            TUI_SCREEN="style"
                        else
                            TUI_SCREEN="review"
                        fi
                        ;;
                    b|B|ESC)
                        TUI_SCREEN="style"
                        ;;
                    p|P)
                        TUI_PREV_SCREEN="options"
                        TUI_SCROLL=0
                        TUI_SCREEN="packages"
                        ;;
                    q|Q)
                        tui_leave
                        echo "Aborted."
                        exit 1
                        ;;
                esac
                ;;
            review)
                case "$key" in
                    LEFT|UP|SHIFT_TAB)
                        REV_BTN=$(( (REV_BTN + 2) % 3 ))
                        ;;
                    RIGHT|DOWN|TAB)
                        REV_BTN=$(( (REV_BTN + 1) % 3 ))
                        ;;
                    ENTER|SPACE)
                        case "$REV_BTN" in
                            0)
                                tui_leave
                                return 0
                                ;;
                            1)
                                TUI_SCREEN="options"
                                ;;
                            2)
                                tui_leave
                                echo "Aborted."
                                exit 1
                                ;;
                        esac
                        ;;
                    b|B|ESC)
                        TUI_SCREEN="options"
                        ;;
                    p|P)
                        TUI_PREV_SCREEN="review"
                        TUI_SCROLL=0
                        TUI_SCREEN="packages"
                        ;;
                    q|Q)
                        tui_leave
                        echo "Aborted."
                        exit 1
                        ;;
                esac
                ;;
            packages)
                case "$key" in
                    UP)        TUI_SCROLL=$(( TUI_SCROLL - 1 )) ;;
                    DOWN)      TUI_SCROLL=$(( TUI_SCROLL + 1 )) ;;
                    PGUP)      TUI_SCROLL=$(( TUI_SCROLL - 6 )) ;;
                    PGDN)      TUI_SCROLL=$(( TUI_SCROLL + 6 )) ;;
                    ESC|q|Q|p|P|ENTER|LEFT|SPACE)
                        TUI_SCREEN="$TUI_PREV_SCREEN"
                        ;;
                esac
                ;;
        esac
    done
}

# ── Styled Execution Output Helpers ──────────────────────────────────────────
PRINT_STYLED=false

log_exec_header() {
    if [[ "$PRINT_STYLED" == true ]]; then
        printf '\033[2J\033[H' >&1
        if [[ "$HAS_UTF8" == true ]]; then
            printf '%s██  ██   █████   ███████  ██████%s\n' "$C_LOGO_1" "$C_RESET"
            printf '%s██ ██   ██   ██      ██   ██    %s\n' "$C_LOGO_2" "$C_RESET"
            printf '%s████    ███████    ███    █████ %s\n' "$C_LOGO_3" "$C_RESET"
            printf '%s██ ██   ██   ██   ██      ██    %s\n' "$C_LOGO_4" "$C_RESET"
            printf '%s██  ██  ██   ██  ███████  ██████%s\n' "$C_LOGO_5" "$C_RESET"
        else
            printf '%sK A Z E%s\n' "${C_BOLD}${C_CYAN}" "$C_RESET"
        fi
        local hdr_pkgs="${#PACKAGES[@]} core"
        (( ${#ADDON_PACKAGES[@]} > 0 )) && hdr_pkgs+=" + ${#ADDON_PACKAGES[@]} add-on"
        local hdr_aur="0 AUR"
        [[ "$AUR_HELPER" != "none" ]] && hdr_aur="0 AUR core + opt-in ${AUR_HELPER}"
        printf '%sHyprland 0.57 + Noctalia v5.x %s profile=%s (%s pkgs, %s)%s\n\n' \
            "$C_MUTED" "$G_BULLET" "$PROFILE" "$hdr_pkgs" "$hdr_aur" "$C_RESET"
    fi
}

log_step() {
    local idx="$1" total="$2" title="$3"
    if [[ "$PRINT_STYLED" == true ]]; then
        tui_repeat "$G_H" 64
        printf '%s%s%s\n' "$C_BORDER" "$REPLY" "$C_RESET"
        printf '%s==> [%d/%d] %s%s\n' "${C_BOLD}${C_BLUE}" "$idx" "$total" "$title" "$C_RESET"
        tui_repeat "$G_H" 64
        printf '%s%s%s\n' "$C_BORDER" "$REPLY" "$C_RESET"
    else
        printf '==> [%d/%d] %s\n' "$idx" "$total" "$title"
    fi
}

log_ok() {
    if [[ "$PRINT_STYLED" == true ]]; then
        printf '  %s%s%s %s\n' "$C_GREEN" "$G_CHECK" "$C_RESET" "$1"
    else
        printf '  [OK] %s\n' "$1"
    fi
}

log_info() {
    if [[ "$PRINT_STYLED" == true ]]; then
        printf '  %s%s%s %s\n' "$C_MUTED" "$G_BULLET" "$C_RESET" "$1"
    else
        printf '  %s\n' "$1"
    fi
}

log_warn() {
    if [[ "$PRINT_STYLED" == true ]]; then
        printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$1"
    else
        printf '  [WARN] %s\n' "$1"
    fi
}

prompt_reboot_tui() {
    local choice=0
    local stty_saved=""
    stty_saved="$(stty -g <&0 2>/dev/null || true)"
    printf '\033[?25l' >&1
    stty -echo -icanon min 1 time 0 <&0 2>/dev/null || true

    printf '\n%sReboot now to enter Kaze Hyprland?%s\n' "${C_BOLD}${C_FG}" "$C_RESET"
    while true; do
        local b1_s="$C_BTN_IDLE" b2_s="$C_BTN_IDLE"
        if (( choice == 0 )); then
            b1_s="$C_BTN_ACTIVE"
        else
            b2_s="$C_BTN_ACTIVE"
        fi
        printf '\r\033[K  %s[ Reboot now ]%s   %s[ Stay in shell ]%s   %s(Left/Right, Enter, or y/n)%s' \
            "$b1_s" "$C_RESET" "$b2_s" "$C_RESET" "$C_MUTED" "$C_RESET" >&1
        tui_read_key
        case "$REPLY" in
            LEFT|RIGHT|TAB|UP|DOWN)
                choice=$(( (choice + 1) % 2 ))
                ;;
            y|Y)
                choice=0
                break
                ;;
            n|N|q|Q|ESC)
                choice=1
                break
                ;;
            ENTER|SPACE)
                break
                ;;
            EOF)
                choice=1
                break
                ;;
        esac
    done
    printf '\n' >&1
    if [[ -n "$stty_saved" ]]; then
        stty "$stty_saved" <&0 2>/dev/null || true
    fi
    printf '\033[?25h' >&1
    (( choice == 0 ))
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

REMOVE_HARD_CONFLICTS=false
if [[ "$SKIP_PACKAGES" == false ]] && (( ${#CONFLICT_HARD[@]} > 0 )); then
    log_warn "Hard package conflict(s) detected: ${CONFLICT_HARD[*]}"
    if [[ "$AUTO_YES" == true ]]; then
        if [[ "$REPLACE_CONFLICTS" == true ]]; then
            REMOVE_HARD_CONFLICTS=true
        else
            echo "install.sh: hard package conflicts detected (${CONFLICT_HARD[*]}) that block PipeWire installation." >&2
            echo "install.sh: re-run interactively or pass --replace-conflicts to remove them with 'pacman -Rdd --noconfirm'." >&2
            exit 1
        fi
    else
        read -r -p "Remove conflicting package(s) (${CONFLICT_HARD[*]}) via 'sudo pacman -Rdd --noconfirm' before installing PipeWire? [y/N] " conf_reply
        case "$conf_reply" in
            [yY]|[yY][eE][sS])
                REMOVE_HARD_CONFLICTS=true
                ;;
            *)
                echo "Aborted due to conflicting packages: ${CONFLICT_HARD[*]}"
                exit 1
                ;;
        esac
    fi
fi

if (( ${#CONFLICT_SOFT[@]} > 0 )); then
    log_warn "Soft runtime conflict(s) installed: ${CONFLICT_SOFT[*]}"
    log_info "Noctalia/Hyprland already provide portals & notifications; consider: sudo pacman -Rns ${CONFLICT_SOFT[*]}"
fi

if [[ "$NEEDS_SUDO" == true ]]; then
    if ! kaze_start_sudo_keepalive; then
        echo "install.sh: sudo authentication failed." >&2
        exit 1
    fi
    log_ok "sudo session verified (keepalive active)"
fi
log_ok "Targets ready (CONFIG_HOME=$CONFIG_HOME, DATA_HOME=$DATA_HOME)"

# Step 2: Pacman packages (-Syu --needed)
if [[ "$SKIP_PACKAGES" == false ]]; then
    echo ""
    log_step "$STEP_NUM" "$TOTAL_STEPS" "Syncing & installing official Arch packages (${#ALL_PACMAN_PACKAGES[@]} pkgs)"
    STEP_NUM=$(( STEP_NUM + 1 ))
    if [[ "$REMOVE_HARD_CONFLICTS" == true ]] && (( ${#CONFLICT_HARD[@]} > 0 )); then
        log_info "Removing hard conflict(s): ${CONFLICT_HARD[*]}"
        sudo pacman -Rdd --noconfirm "${CONFLICT_HARD[@]}"
    fi
    sudo pacman -Syu "${PACMAN_FLAGS[@]}" "${ALL_PACMAN_PACKAGES[@]}"
    log_ok "Packages installed cleanly"
fi

# Step 3: System Setup (NetworkManager, Bluetooth, PipeWire, video group, fc-cache)
if [[ "$SYSTEM_SETUP" == "true" ]]; then
    echo ""
    log_step "$STEP_NUM" "$TOTAL_STEPS" "Configuring system services, audio & font cache"
    STEP_NUM=$(( STEP_NUM + 1 ))
    kaze_run_system_setup "$TARGET_USER"
fi

# Step 4: Optional Display Manager (ly / greetd)
if [[ "$DM_CHOICE" != "none" ]]; then
    echo ""
    log_step "$STEP_NUM" "$TOTAL_STEPS" "Configuring Display Manager ($DM_CHOICE)"
    STEP_NUM=$(( STEP_NUM + 1 ))
    kaze_setup_display_manager "$DM_CHOICE"
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
        printf '  %sRollback:%s %s/rollback.sh\n' \
            "$C_MUTED" "$C_RESET" "$(<"$LAST_BACKUP")"
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
