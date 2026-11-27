#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi
set +o posix 2>/dev/null || true
set -euo pipefail

usage() {
    cat <<EOF
Usage: $0 [BOOTSTRAP_OPTIONS] [--] [INSTALL_OPTIONS]

Stage 0 bootstrap wrapper for fresh Arch Linux / CachyOS installations.
Clones or fast-forwards kaze-dots, installs git via 'pacman -Syu --needed' if missing,
reattaches /dev/tty if piped, and hands off to scripts/install.sh.

Bootstrap options:
  --dir <path>      Target directory (default: \${KAZE_INSTALL_DIR:-\$HOME/kaze-dots})
  --repo <url>      Git repository URL (default: https://github.com/minkhoaa/kaze-dots.git)
  --branch <ref>    Git branch or tag to checkout (default: main)
  --dry-run         Print planned bootstrap actions without modifying files or network
  -h, --help        Show this help message

Any other options (or everything after '--') are forwarded unchanged to scripts/install.sh.
EOF
}

validate_existing_dir() {
    local dir="$1" repo_url="$2"
    if [[ ! -e "$dir" && ! -L "$dir" ]]; then
        return 0
    fi
    if [[ ! -d "$dir" ]] || ! command -v git >/dev/null 2>&1 || ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "bootstrap.sh: target '$dir' already exists and is not a kaze-dots git repository." >&2
        return 1
    fi

    local origin_url="" expected_clean="${repo_url%.git}" origin_clean=""
    origin_url="$(git -C "$dir" remote get-url origin 2>/dev/null || true)"
    origin_clean="${origin_url%.git}"
    if [[ "$origin_clean" != "$expected_clean" && "$origin_url" != *kaze-dots* ]]; then
        if [[ ! -f "$dir/scripts/install.sh" || ! -f "$dir/hypr/hyprland.lua" ]]; then
            echo "bootstrap.sh: target '$dir' is a different git repository ($origin_url), not kaze-dots." >&2
            return 1
        fi
    fi

    if [[ -n "$(git -C "$dir" status --porcelain 2>/dev/null || true)" ]]; then
        echo "bootstrap.sh: target '$dir' has uncommitted local changes; commit/stash or pick another --dir." >&2
        return 1
    fi
}

main() {
    if (( EUID == 0 )); then
        if [[ -z "${SUDO_USER:-}" || "$SUDO_USER" == "root" ]]; then
            echo "bootstrap.sh: do not run directly as root; log in as your regular desktop user first." >&2
            exit 1
        fi
        local target_home target_uid
        target_home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)"
        if [[ -z "$target_home" || ! -d "$target_home" ]]; then
            echo "bootstrap.sh: could not determine home directory for user '$SUDO_USER'." >&2
            exit 1
        fi
        target_uid="$(id -u "$SUDO_USER")"
        local user_env=(HOME="$target_home" USER="$SUDO_USER" LOGNAME="$SUDO_USER")
        if [[ -d "/run/user/$target_uid" ]]; then
            user_env+=(XDG_RUNTIME_DIR="/run/user/$target_uid")
        fi
        exec sudo -u "$SUDO_USER" -H env "${user_env[@]}" bash "$0" "$@"
    fi

    local TARGET_DIR="${KAZE_INSTALL_DIR:-$HOME/kaze-dots}"
    local REPO_URL="${KAZE_BOOTSTRAP_REPO:-https://github.com/minkhoaa/kaze-dots.git}"
    local BRANCH="${KAZE_BOOTSTRAP_BRANCH:-main}"
    local DRY_RUN=false
    local INSTALL_ARGS=()

    while (( $# > 0 )); do
        case "$1" in
            --)
                shift
                while (( $# > 0 )); do
                    if [[ "$1" == "--dry-run" || "$1" == "--check" ]]; then
                        DRY_RUN=true
                    fi
                    INSTALL_ARGS+=("$1")
                    shift
                done
                break
                ;;
            --dir)
                if (( $# < 2 )) || [[ -z "${2:-}" ]]; then
                    echo "bootstrap.sh: --dir requires a path" >&2
                    exit 2
                fi
                TARGET_DIR="$2"
                shift 2
                ;;
            --dir=*)
                TARGET_DIR="${1#--dir=}"
                shift
                ;;
            --repo)
                if (( $# < 2 )) || [[ -z "${2:-}" ]]; then
                    echo "bootstrap.sh: --repo requires a URL" >&2
                    exit 2
                fi
                REPO_URL="$2"
                shift 2
                ;;
            --repo=*)
                REPO_URL="${1#--repo=}"
                shift
                ;;
            --branch)
                if (( $# < 2 )) || [[ -z "${2:-}" ]]; then
                    echo "bootstrap.sh: --branch requires a ref" >&2
                    exit 2
                fi
                BRANCH="$2"
                shift 2
                ;;
            --branch=*)
                BRANCH="${1#--branch=}"
                shift
                ;;
            --dry-run|--check)
                DRY_RUN=true
                INSTALL_ARGS+=("$1")
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                INSTALL_ARGS+=("$1")
                shift
                ;;
        esac
    done

    if [[ "$DRY_RUN" == true ]]; then
        validate_existing_dir "$TARGET_DIR" "$REPO_URL"
        echo "Kaze bootstrap plan (Stage 0):"
        echo "  Repo:       $REPO_URL"
        echo "  Branch:     $BRANCH"
        echo "  Target dir: $TARGET_DIR"
        if [[ -d "$TARGET_DIR/.git" ]]; then
            echo "  Git action: git -C $TARGET_DIR fetch origin $BRANCH && checkout/ff-only"
        else
            echo "  Git action: git clone --branch $BRANCH $REPO_URL $TARGET_DIR"
        fi
        if (( ${#INSTALL_ARGS[@]} > 0 )); then
            echo "  Exec:       $TARGET_DIR/scripts/install.sh ${INSTALL_ARGS[*]}"
        else
            echo "  Exec:       $TARGET_DIR/scripts/install.sh"
        fi
        if [[ -x "$TARGET_DIR/scripts/install.sh" ]]; then
            echo ""
            exec "$TARGET_DIR/scripts/install.sh" ${INSTALL_ARGS[@]+"${INSTALL_ARGS[@]}"}
        fi
        exit 0
    fi

    if [[ ! -f "${KAZE_ARCH_RELEASE_FILE:-/etc/arch-release}" ]] || ! command -v pacman >/dev/null 2>&1; then
        echo "bootstrap.sh: Arch Linux (pacman) is required." >&2
        exit 1
    fi

    if [[ "${KAZE_SKIP_NET_CHECK:-0}" != "1" ]]; then
        if ! command -v curl >/dev/null 2>&1; then
            echo "bootstrap.sh: curl is required for connectivity check." >&2
            exit 1
        fi
        if ! curl -fsSI --connect-timeout 5 https://github.com >/dev/null; then
            echo "bootstrap.sh: HTTPS connectivity check to https://github.com failed." >&2
            exit 1
        fi
    fi

    local has_tty=false
    if [[ ! -t 0 ]] && { : </dev/tty; } 2>/dev/null; then
        has_tty=true
    fi

    if ! command -v git >/dev/null 2>&1; then
        echo "==> Installing git via full system sync (pacman -Syu --needed git)..."
        if [[ "$has_tty" == true ]]; then
            sudo pacman -Syu --needed git </dev/tty
        else
            sudo pacman -Syu --needed git
        fi
    fi

    validate_existing_dir "$TARGET_DIR" "$REPO_URL"

    if [[ -d "$TARGET_DIR/.git" ]]; then
        echo "==> Updating existing kaze-dots checkout in $TARGET_DIR ($BRANCH)..."
        git -C "$TARGET_DIR" fetch origin "$BRANCH"
        local cur_branch=""
        cur_branch="$(git -C "$TARGET_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
        if [[ "$cur_branch" == "$BRANCH" ]]; then
            git -C "$TARGET_DIR" merge --ff-only FETCH_HEAD
        elif git -C "$TARGET_DIR" show-ref --verify --quiet "refs/heads/$BRANCH"; then
            git -C "$TARGET_DIR" checkout "$BRANCH"
            git -C "$TARGET_DIR" merge --ff-only FETCH_HEAD
        else
            git -C "$TARGET_DIR" checkout --detach FETCH_HEAD
        fi
    else
        echo "==> Cloning kaze-dots ($BRANCH) into $TARGET_DIR..."
        mkdir -p -- "$(dirname -- "$TARGET_DIR")"
        git clone --branch "$BRANCH" -- "$REPO_URL" "$TARGET_DIR"
    fi

    if [[ ! -x "$TARGET_DIR/scripts/install.sh" ]]; then
        echo "bootstrap.sh: missing executable $TARGET_DIR/scripts/install.sh" >&2
        exit 1
    fi

    if [[ "$has_tty" == true ]]; then
        exec "$TARGET_DIR/scripts/install.sh" ${INSTALL_ARGS[@]+"${INSTALL_ARGS[@]}"} </dev/tty
    fi
    exec "$TARGET_DIR/scripts/install.sh" ${INSTALL_ARGS[@]+"${INSTALL_ARGS[@]}"}
}

main "$@"
