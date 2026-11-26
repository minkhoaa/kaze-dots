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
DRY_RUN=false
SKIP_PACKAGES=false
SKIP_PACKAGES_EXPLICIT=false
AUTO_YES=false
REBOOT="auto"
SET_ZSH="auto"
PACMAN_NOCONFIRM=false
USE_TUI="auto"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Installs official Arch Linux [core]/[extra] packages for the chosen Kaze + Noctalia profile
(zero AUR dependencies), applies symlinks and default Noctalia/Foot configs via scripts/apply.sh,
and records the active profile in ~/.config/kaze/profile without overwriting hypr/user.lua.

Options:
  --profile <minimal|full>  Select installation profile (default: minimal)
  --dry-run, --check        Print installation plan without writing any files
  --skip-packages           Skip pacman package installation and apply dotfiles only
  --no-zsh                  Do not change the default login shell to Zsh
  --yes, -y                 Non-interactive mode (--noconfirm for pacman, --yes for apply.sh)
  --tui                     Launch the interactive Omarchy-inspired TUI installer
  --no-tui                  Use plain CLI prompts instead of the TUI installer
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
            PROFILE_EXPLICIT=true
            shift 2
            ;;
        --profile=*)
            PROFILE="${1#--profile=}"
            PROFILE_EXPLICIT=true
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

# shellcheck source=scripts/packages.sh
source "$REPO_DIR/scripts/packages.sh"

PACKAGES=()
get_packages_for_profile "$PROFILE"

DATA_HOME=$(realpath -ms -- "${XDG_DATA_HOME:-$HOME/.local/share}")
CONFIG_HOME=$(realpath -ms -- "${XDG_CONFIG_HOME:-$HOME/.config}")
BIN_HOME="$HOME/.local/bin"
PROFILE_FILE="$CONFIG_HOME/kaze/profile"
LAST_BACKUP="$CONFIG_HOME/kaze/last-backup"

if [[ "$DRY_RUN" == true ]]; then
    PACMAN_FLAGS=(--needed)
    APPLY_FLAGS=()
    if [[ "$AUTO_YES" == true ]]; then
        PACMAN_FLAGS+=(--noconfirm)
        APPLY_FLAGS+=(--yes)
    fi
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
    echo "  PROFILE_FILE=$PROFILE_FILE (profile=$PROFILE, preserving hypr/user.lua)"
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

on_signal_exit() {
    local code="$1"
    tui_cleanup
    printf '\n%s\n' "Aborted." >&2
    exit "$code"
}

trap 'tui_cleanup' EXIT
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
    printf '\033[?2026h\033[H%s%s\033[J\033[?2026l' "$pre" "$FRAME_BUF" >&1
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
    if (( TERM_ROWS >= 23 )) && (( TERM_COLS >= 40 )); then
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

    local labels=("1 Profile" "2 Options" "3 Review" "4 Install")
    local sep=" ${G_H}${G_H} "
    local plain="" formatted="" i idx marker
    for (( i=0; i<4; i++ )); do
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
        if (( i < 3 )); then
            plain+="$sep"
            formatted+="${C_BORDER}${sep}${C_RESET}"
        fi
    done

    if (( ${#plain} <= TERM_COLS - 2 )); then
        local sp=$(( (TERM_COLS - ${#plain}) / 2 ))
        tui_spaces "$sp"
        frame_line "${REPLY}${formatted}"
    else
        frame_center "Step ${active_step}/4: ${labels[$((active_step - 1))]}" "${C_BOLD}${C_CYAN}"
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
    [[ -f /etc/arch-release ]] && HAS_ARCH=true
    command -v pacman >/dev/null 2>&1 && HAS_PACMAN=true
    [[ -f "$LAST_BACKUP" ]] && HAS_EXISTING_BACKUP=true
    if [[ -e "$CONFIG_HOME/hypr/user.lua" || -L "$CONFIG_HOME/hypr/user.lua" ]]; then
        HAS_USER_LUA=true
    fi
    CURRENT_SHELL_BIN="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f7 || true)"
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
        return 0
    fi
    local fmt="${C_MUTED}Host: ${os_style}${os_label} ${C_BORDER}${G_BULLET} ${state_style}${state_label} ${C_BORDER}${G_BULLET} ${C_MUTED}user.lua: ${C_FG}${ulua_label}${C_RESET}"
    tui_box_row "${#plain}" "$fmt"
}

# ── TUI Screens ──────────────────────────────────────────────────────────────
draw_screen_profile() {
    frame_reset
    tui_render_header 1
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
        tui_clip "+ wf-recorder, hyprpicker, wl-mirror, yazi, imv, zathura" "$desc_max"
        tui_box_row "$(( 6 + ${#REPLY} ))" "${C_ACTIVE_BORDER}${bg}${G_BAR}     ${C_FG}${bg}${REPLY}${C_RESET}" "$bg"
        tui_clip "+ fcitx5-bamboo, keyring, polkit_agent, starship & CLI" "$desc_max"
        tui_box_row "$(( 6 + ${#REPLY} ))" "${C_ACTIVE_BORDER}${bg}${G_BAR}     ${C_MUTED}${bg}${REPLY}${C_RESET}" "$bg"
    else
        local h_plain="  ${G_DOT_OFF} Full       ${full_count} pkgs ${G_BULLET} 0 AUR"
        tui_clip "$h_plain" "$TUI_BOX_W"
        tui_box_row "${#REPLY}" "${C_FG}${REPLY}${C_RESET}"
        tui_clip "+ wf-recorder, hyprpicker, wl-mirror, yazi, imv, zathura" "$desc_max"
        tui_box_row "$(( 6 + ${#REPLY} ))" "${C_MUTED}      ${REPLY}${C_RESET}"
        tui_clip "+ fcitx5-bamboo, keyring, polkit_agent, starship & CLI" "$desc_max"
        tui_box_row "$(( 6 + ${#REPLY} ))" "${C_MUTED}      ${REPLY}${C_RESET}"
    fi

    tui_box_bottom
    tui_render_footer "Up/Down Move   Enter Next   p Inspect Packages   q Quit"
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

draw_screen_options() {
    frame_reset
    tui_render_header 2
    tui_box_top

    get_packages_for_profile "$PROFILE"
    local prof_upper="MINIMAL"
    local prof_col="$C_CYAN"
    if [[ "$PROFILE" == "full" ]]; then
        prof_upper="FULL"
        prof_col="$C_PURPLE"
    fi
    local hdr_plain="Profile: ${prof_upper} (${#PACKAGES[@]} Arch [core]/[extra] packages ${G_BULLET} 0 AUR)"
    tui_clip "$hdr_plain" "$TUI_BOX_W"
    local hc="$REPLY"
    if (( ${#hc} == ${#hdr_plain} )); then
        tui_box_row "${#hc}" "${C_MUTED}Profile: ${C_BOLD}${prof_col}${prof_upper} ${C_MUTED}(${#PACKAGES[@]} Arch [core]/[extra] packages ${G_BULLET} 0 AUR)${C_RESET}"
    else
        tui_box_row "${#hc}" "${prof_col}${hc}${C_RESET}"
    fi
    tui_box_mid

    local pkg_mark="$G_CHECK" pkg_note="Runs sudo pacman -S --needed (uncheck for dotfiles only)"
    if [[ "$SKIP_PACKAGES" == true ]]; then
        pkg_mark=" "
        if [[ "$HAS_ARCH" == false || "$HAS_PACMAN" == false ]]; then
            pkg_note="Skipped (pacman unavailable — dotfiles-only mode)"
        else
            pkg_note="Skipped (--skip-packages, deploying dotfiles only)"
        fi
    fi
    draw_opt_row 0 "$pkg_mark" "Install official Arch packages via pacman" "$pkg_note" "true"

    local nc_mark=" " nc_enabled="true"
    [[ "$PACMAN_NOCONFIRM" == true ]] && nc_mark="$G_CHECK"
    [[ "$SKIP_PACKAGES" == true ]] && nc_enabled="false"
    draw_opt_row 1 "$nc_mark" "Auto-confirm pacman prompts (--noconfirm)" "" "$nc_enabled"

    local zsh_mark=" "
    [[ "$SET_ZSH" == "true" ]] && zsh_mark="$G_CHECK"
    local zsh_label="Set Zsh as default login shell (chsh)"
    if [[ "$CURRENT_SHELL_BIN" == */zsh ]]; then
        zsh_label="Set Zsh as default login shell (already zsh)"
    fi
    draw_opt_row 2 "$zsh_mark" "$zsh_label" "" "true"

    local reb_label="Ask before rebooting"
    local reb_col="$C_CYAN"
    case "$REBOOT" in
        yes) reb_label="Reboot automatically"; reb_col="$C_YELLOW" ;;
        no)  reb_label="Stay in shell";        reb_col="$C_MUTED" ;;
    esac
    local reb_focused=false
    (( OPT_IDX == 3 )) && reb_focused=true
    local rbg="" rbar=" "
    [[ "$reb_focused" == true ]] && { rbg="$C_BG_SEL"; rbar="$G_BAR"; }
    local rplain="${rbar} [${G_DOT_ON}] After install:  < ${reb_label} >"
    tui_clip "$rplain" "$TUI_BOX_W"
    local rc="$REPLY"
    if (( ${#rc} == ${#rplain} )); then
        local rfmt=""
        if [[ "$reb_focused" == true ]]; then
            rfmt="${C_ACTIVE_BORDER}${rbg}${rbar} ${C_BORDER}${rbg}[${C_CYAN}${rbg}${G_DOT_ON}${C_BORDER}${rbg}] ${C_BOLD}${C_FG}${rbg}After install:  ${C_MUTED}${rbg}< ${reb_col}${rbg}${reb_label} ${C_MUTED}${rbg}>${C_RESET}"
        else
            rfmt="${rbar} ${C_BORDER}[${C_CYAN}${G_DOT_ON}${C_BORDER}] ${C_FG}After install:  ${C_MUTED}< ${reb_col}${reb_label} ${C_MUTED}>${C_RESET}"
        fi
        tui_box_row "${#rc}" "$rfmt" "$rbg"
    else
        tui_box_row "${#rc}" "${C_FG}${rbg}${rc}${C_RESET}" "$rbg"
    fi

    tui_box_empty

    local b1=" Continue to Review ${G_ARROW_R} "
    local b2=" ${G_ARROW_L} Back "
    local b_plain="  [${b1}]   [${b2}]"
    local b1_s="$C_BTN_IDLE" b2_s="$C_BTN_IDLE"
    if (( OPT_IDX == 4 )); then
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
    tui_render_header 3
    tui_box_top
    tui_box_text "Pre-flight review before writing changes" "${C_BOLD}${C_FG}"
    tui_box_mid

    get_packages_for_profile "$PROFILE"
    local prof_col="$C_CYAN"
    [[ "$PROFILE" == "full" ]] && prof_col="$C_PURPLE"
    tui_box_kv 14 "Profile" "${PROFILE} (${#PACKAGES[@]} official Arch packages, 0 AUR)" "$prof_col"

    local pkg_desc="sudo pacman -S --needed"
    [[ "$PACMAN_NOCONFIRM" == true ]] && pkg_desc+=" --noconfirm"
    pkg_desc+=" (${#PACKAGES[@]} pkgs)"
    if [[ "$SKIP_PACKAGES" == true ]]; then
        pkg_desc="Skipped (--skip-packages, dotfiles only)"
        tui_box_kv 14 "Packages" "$pkg_desc" "$C_YELLOW"
    else
        tui_box_kv 14 "Packages" "$pkg_desc" "$C_FG"
    fi

    tui_box_kv 14 "Config home" "$CONFIG_HOME" "$C_FG"
    tui_box_kv 14 "Data & bins" "$DATA_HOME/kaze-dots + ~/.local/bin" "$C_FG"

    local zsh_desc="Keep current (${CURRENT_SHELL_BIN:-unchanged})"
    [[ "$SET_ZSH" == "true" ]] && zsh_desc="Switch to /usr/bin/zsh (if not already)"
    tui_box_kv 14 "Login shell" "$zsh_desc" "$C_FG"

    local reb_desc="Ask after installation"
    case "$REBOOT" in
        yes) reb_desc="Reboot automatically (sudo systemctl reboot)" ;;
        no)  reb_desc="Stay in shell" ;;
    esac
    tui_box_kv 14 "After install" "$reb_desc" "$C_FG"

    tui_box_mid
    local chk_max=$(( TUI_BOX_W - 2 ))
    tui_clip "Automatic backup & reversible rollback.sh before replacing" "$chk_max"
    tui_box_row "$(( 2 + ${#REPLY} ))" "${C_GREEN}${G_CHECK} ${C_FG}${REPLY}${C_RESET}"
    tui_clip "Preserves hypr/user.lua, zsh/user.zsh & Noctalia GUI edits" "$chk_max"
    tui_box_row "$(( 2 + ${#REPLY} ))" "${C_GREEN}${G_CHECK} ${C_FG}${REPLY}${C_RESET}"
    tui_box_empty

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
    add_pkg_group "System/Audio" "$C_CYAN" "${PKG_MIN_SYS[@]}"
    add_pkg_group "Fonts/Lua" "$C_CYAN" "${PKG_MIN_FONTS[@]}"
    if [[ "$PROFILE" == "full" ]]; then
        PKG_MODAL_LINES+=("  Full Extras (+${#FULL_EXTRA_PACKAGES[@]} official Arch packages)")
        PKG_MODAL_STYLES+=("HDR")
        add_pkg_group "Capture/Share" "$C_PURPLE" "${PKG_FULL_CAPTURE[@]}"
        add_pkg_group "Apps/Docs" "$C_PURPLE" "${PKG_FULL_APPS[@]}"
        add_pkg_group "IME/Keyring" "$C_PURPLE" "${PKG_FULL_IME[@]}"
        add_pkg_group "Modern CLI" "$C_PURPLE" "${PKG_FULL_CLI[@]}"
    fi
}

draw_screen_packages() {
    frame_reset
    local step_num=1
    [[ "$TUI_PREV_SCREEN" == "options" ]] && step_num=2
    [[ "$TUI_PREV_SCREEN" == "review" ]] && step_num=3
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
    if [[ "$SKIP_PACKAGES_EXPLICIT" == false ]] && [[ "$HAS_ARCH" == false || "$HAS_PACMAN" == false ]]; then
        SKIP_PACKAGES=true
    fi
    if [[ "$SET_ZSH" == "auto" ]]; then
        if [[ "$SKIP_PACKAGES" == true ]]; then
            SET_ZSH="false"
        else
            SET_ZSH="true"
        fi
    fi
    if [[ "$REBOOT" == "auto" ]] && [[ "$SKIP_PACKAGES" == true ]]; then
        REBOOT="no"
    fi

    tui_enter

    while true; do
        tui_measure_term
        case "$TUI_SCREEN" in
            profile)  draw_screen_profile ;;
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
                        TUI_SCREEN="options"
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
            options)
                case "$key" in
                    UP)
                        OPT_IDX=$(( (OPT_IDX + 4) % 5 ))
                        ;;
                    DOWN)
                        OPT_IDX=$(( (OPT_IDX + 1) % 5 ))
                        ;;
                    TAB)
                        if (( OPT_IDX < 4 )); then
                            OPT_IDX=4
                            OPT_BTN=0
                        else
                            OPT_BTN=$(( (OPT_BTN + 1) % 2 ))
                        fi
                        ;;
                    LEFT|RIGHT)
                        if (( OPT_IDX == 3 )); then
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
                        elif (( OPT_IDX == 4 )); then
                            OPT_BTN=$(( (OPT_BTN + 1) % 2 ))
                        elif [[ "$key" == "LEFT" ]]; then
                            TUI_SCREEN="profile"
                        fi
                        ;;
                    SPACE)
                        case "$OPT_IDX" in
                            0)
                                if [[ "$SKIP_PACKAGES" == true ]]; then
                                    if [[ "$HAS_ARCH" == false || "$HAS_PACMAN" == false ]]; then
                                        TUI_STATUS_MSG="pacman unavailable on this host; dotfiles-only mode required"
                                    else
                                        SKIP_PACKAGES=false
                                    fi
                                else
                                    SKIP_PACKAGES=true
                                fi
                                ;;
                            1)
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
                            2)
                                if [[ "$SET_ZSH" == "true" ]]; then
                                    SET_ZSH="false"
                                else
                                    SET_ZSH="true"
                                fi
                                ;;
                            3)
                                case "$REBOOT" in
                                    auto) REBOOT="yes" ;;
                                    yes)  REBOOT="no" ;;
                                    no)   REBOOT="auto" ;;
                                esac
                                ;;
                            4)
                                if (( OPT_BTN == 0 )); then
                                    TUI_SCREEN="review"
                                else
                                    TUI_SCREEN="profile"
                                fi
                                ;;
                        esac
                        ;;
                    ENTER)
                        if (( OPT_IDX == 4 && OPT_BTN == 1 )); then
                            TUI_SCREEN="profile"
                        else
                            TUI_SCREEN="review"
                        fi
                        ;;
                    b|B|ESC)
                        TUI_SCREEN="profile"
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
        printf '%sHyprland 0.57 + Noctalia v5.x %s profile=%s (%d pkgs, 0 AUR)%s\n\n' \
            "$C_MUTED" "$G_BULLET" "$PROFILE" "${#PACKAGES[@]}" "$C_RESET"
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
    if [[ "$SET_ZSH" == "auto" ]]; then
        if [[ "$SKIP_PACKAGES" == false ]]; then
            SET_ZSH="true"
        else
            SET_ZSH="false"
        fi
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
    [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]] && PRINT_STYLED=true
fi

get_packages_for_profile "$PROFILE"

PACMAN_FLAGS=(--needed)
if [[ "$AUTO_YES" == true ]] || [[ "$PACMAN_NOCONFIRM" == true ]]; then
    PACMAN_FLAGS+=(--noconfirm)
fi

TOTAL_STEPS=2
[[ "$SKIP_PACKAGES" == false ]] && TOTAL_STEPS=$(( TOTAL_STEPS + 1 ))
[[ "$SET_ZSH" == "true" ]] && TOTAL_STEPS=$(( TOTAL_STEPS + 1 ))
STEP_NUM=1

log_exec_header

# Step 1: Preflight
log_step "$STEP_NUM" "$TOTAL_STEPS" "Preflight & configuration check"
STEP_NUM=$(( STEP_NUM + 1 ))
if [[ "$SKIP_PACKAGES" == false ]]; then
    if [[ "$HAS_ARCH" == false ]] || [[ "$HAS_PACMAN" == false ]]; then
        echo "install.sh: Arch Linux (pacman) is required (or pass --skip-packages)." >&2
        exit 1
    fi
    log_ok "Arch Linux & pacman verified (${#PACKAGES[@]} ${PROFILE} packages, 0 AUR)"
else
    log_info "Skipping package installation (--skip-packages)"
fi
log_ok "Targets ready (CONFIG_HOME=$CONFIG_HOME, DATA_HOME=$DATA_HOME)"

# Step 2: Pacman packages
if [[ "$SKIP_PACKAGES" == false ]]; then
    echo ""
    log_step "$STEP_NUM" "$TOTAL_STEPS" "Installing official Arch [core]/[extra] packages (${#PACKAGES[@]} pkgs)"
    STEP_NUM=$(( STEP_NUM + 1 ))
    sudo pacman -S "${PACMAN_FLAGS[@]}" "${PACKAGES[@]}"
    log_ok "Packages installed cleanly"
fi

# Step 3: Apply dotfiles, profile, polkit & backup manifest
echo ""
log_step "$STEP_NUM" "$TOTAL_STEPS" "Backing up & deploying kaze-dots configs"
STEP_NUM=$(( STEP_NUM + 1 ))

HAD_PREINSTALL_PROFILE=false
PREINSTALL_PROFILE_CONTENT=""
if [[ ! -f "$LAST_BACKUP" ]] && { [[ -f "$PROFILE_FILE" ]] || [[ -L "$PROFILE_FILE" ]]; }; then
    HAD_PREINSTALL_PROFILE=true
    PREINSTALL_PROFILE_CONTENT="$(cat -- "$PROFILE_FILE")"
fi

"$REPO_DIR/scripts/apply.sh" ${APPLY_FLAGS[@]+"${APPLY_FLAGS[@]}"}

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
log_ok "Profile '${PROFILE}' recorded in $PROFILE_FILE"

# Step 4: Default login shell
if [[ "$SET_ZSH" == "true" ]]; then
    echo ""
    log_step "$STEP_NUM" "$TOTAL_STEPS" "Configuring default login shell"
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

# Completion Summary
echo ""
if [[ "$PRINT_STYLED" == true ]]; then
    tui_repeat "$G_H" 64
    rule_line="$REPLY"
    printf '%s%s%s\n' "$C_GREEN" "$rule_line" "$C_RESET"
    printf '  %s%s Installed kaze-dots (profile: %s)%s\n' \
        "${C_BOLD}${C_GREEN}" "$G_CHECK" "$PROFILE" "$C_RESET"
    if [[ -f "$LAST_BACKUP" ]]; then
        printf '  %sRollback:%s %s/rollback.sh\n' \
            "$C_MUTED" "$C_RESET" "$(<"$LAST_BACKUP")"
    fi
    printf '  %sKeys:%s     Super+Space Launcher %s Super+Return Foot %s Super+/ Keys\n' \
        "$C_MUTED" "$C_RESET" "$G_BULLET" "$G_BULLET"
    printf '  %sSettings:%s Super+I Noctalia GUI %s Health: kaze-doctor\n' \
        "$C_MUTED" "$C_RESET" "$G_BULLET"
    printf '%s%s%s\n' "$C_GREEN" "$rule_line" "$C_RESET"
else
    echo "Installed kaze-dots profile: $PROFILE"
fi

if [[ "$PROFILE" == "full" ]]; then
    echo "Note: fcitx5-configtool is an optional on-demand Qt GUI if you want a GUI to switch Bamboo between Telex and VNI."
fi

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
