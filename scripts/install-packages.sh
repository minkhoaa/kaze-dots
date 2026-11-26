#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi
set +o posix 2>/dev/null || true
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="minimal"
DRY_RUN=false
AUTO_YES=false

while (( $# > 0 )); do
    case "$1" in
        --profile)
            if (( $# < 2 )) || [[ -z "${2:-}" ]]; then
                echo "install-packages.sh: --profile requires an argument (minimal or full)" >&2
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
        --yes|-y)
            AUTO_YES=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--profile minimal|full] [--dry-run] [--yes]"
            echo "Installs official Arch Linux [core]/[extra] packages required by kaze-dots + Noctalia (zero AUR dependencies)."
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 2
            ;;
    esac
done

case "$PROFILE" in
    minimal|full) ;;
    *)
        echo "install-packages.sh: invalid profile '$PROFILE' (expected: minimal or full)" >&2
        exit 2
        ;;
esac

# shellcheck source=scripts/packages.sh
source "$REPO_DIR/scripts/packages.sh"

PACKAGES=()
get_packages_for_profile "$PROFILE"

PACMAN_FLAGS=(--needed)
if [ "$AUTO_YES" = true ]; then
    PACMAN_FLAGS+=(--noconfirm)
fi

if [ "$DRY_RUN" = true ]; then
    echo "kaze-dots official Arch packages (${PROFILE}: ${#PACKAGES[@]} total, 0 AUR):"
    printf '  %s\n' "${PACKAGES[@]}"
    echo "Command: sudo pacman -S ${PACMAN_FLAGS[*]} ${PACKAGES[*]}"
    exit 0
fi

if [ ! -f /etc/arch-release ] || ! command -v pacman >/dev/null 2>&1; then
    echo "install-packages.sh: Arch Linux (pacman) is required." >&2
    exit 1
fi

exec sudo pacman -S "${PACMAN_FLAGS[@]}" "${PACKAGES[@]}"
