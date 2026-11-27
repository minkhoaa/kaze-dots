# shellcheck shell=bash
# shellcheck disable=SC2034
# Shared helper library for scripts/install.sh.
# Pure Bash functions designed for standalone unit testing without touching the host.

KAZE_LOG_ACTIVE=false
KAZE_LOG_FIFO_DIR=""
KAZE_LOG_TEE_PID=""
KAZE_LOG_SED_PID=""
KAZE_SUDO_KEEPALIVE_PID=""
KAZE_AUR_TMPDIR=""

GPU_MODE="unknown"
GPU_LABEL="Unknown"
GPU_IGPU_CARD=""
GPU_IGPU_VENDOR=""
GPU_NVIDIA_CARD=""
GPU_HAS_NVIDIA=false
GPU_HAS_VM=false
GPU_DETAIL=""

CONFLICT_HARD=()
CONFLICT_SOFT=()
EXISTING_DM=""

_kaze_msg_ok() {
    if declare -F log_ok >/dev/null 2>&1; then
        log_ok "$1"
    else
        printf '  [OK] %s\n' "$1"
    fi
}

_kaze_msg_info() {
    if declare -F log_info >/dev/null 2>&1; then
        log_info "$1"
    else
        printf '  %s\n' "$1"
    fi
}

_kaze_msg_warn() {
    if declare -F log_warn >/dev/null 2>&1; then
        log_warn "$1"
    else
        printf '  [WARN] %s\n' "$1" >&2
    fi
}

kaze_default_log_path() {
    local state_home="${XDG_STATE_HOME:-$HOME/.local/state}"
    printf '%s/kaze/install-%s.log\n' "$state_home" "$(date +%Y%m%d-%H%M%S)"
}

kaze_start_logging() {
    local log_file="$1"
    if [[ -z "$log_file" || "$KAZE_LOG_ACTIVE" == true ]]; then
        return 0
    fi
    mkdir -p -- "$(dirname -- "$log_file")"
    : > "$log_file"

    local fifo_dir fifo_raw fifo_clean esc bel cr
    fifo_dir="$(mktemp -d "${TMPDIR:-/tmp}/kaze-log.XXXXXX")"
    fifo_raw="$fifo_dir/raw.fifo"
    fifo_clean="$fifo_dir/clean.fifo"
    mkfifo -m 600 -- "$fifo_raw" "$fifo_clean"

    esc=$'\033'
    bel=$'\007'
    cr=$'\r'

    exec 3>&1 4>&2
    LC_ALL=C sed -u -E "s|${esc}\\[[0-9;?]*[ -/]*[@-~]||g; s|${esc}\\][^${bel}]*${bel}||g; s|${cr}||g" < "$fifo_clean" >> "$log_file" &
    KAZE_LOG_SED_PID=$!
    tee "$fifo_clean" < "$fifo_raw" >&3 &
    KAZE_LOG_TEE_PID=$!
    exec > "$fifo_raw" 2>&1

    KAZE_LOG_FIFO_DIR="$fifo_dir"
    KAZE_LOG_ACTIVE=true
}

kaze_stop_logging() {
    if [[ "$KAZE_LOG_ACTIVE" != true ]]; then
        return 0
    fi
    KAZE_LOG_ACTIVE=false
    exec 1>&3 2>&4 3>&- 4>&-
    if [[ -n "$KAZE_LOG_TEE_PID" ]]; then
        wait "$KAZE_LOG_TEE_PID" 2>/dev/null || true
        KAZE_LOG_TEE_PID=""
    fi
    if [[ -n "$KAZE_LOG_SED_PID" ]]; then
        wait "$KAZE_LOG_SED_PID" 2>/dev/null || true
        KAZE_LOG_SED_PID=""
    fi
    if [[ -n "$KAZE_LOG_FIFO_DIR" && -d "$KAZE_LOG_FIFO_DIR" ]]; then
        rm -rf -- "$KAZE_LOG_FIFO_DIR"
        KAZE_LOG_FIFO_DIR=""
    fi
}

kaze_start_sudo_keepalive() {
    if [[ -n "$KAZE_SUDO_KEEPALIVE_PID" ]] && kill -0 "$KAZE_SUDO_KEEPALIVE_PID" 2>/dev/null; then
        return 0
    fi
    if ! sudo -v; then
        return 1
    fi
    local parent_pid="$$"
    (
        sleep_pid=""
        trap '[[ -n "$sleep_pid" ]] && kill "$sleep_pid" 2>/dev/null || true; exit 0' TERM INT EXIT
        while kill -0 "$parent_pid" 2>/dev/null; do
            sleep 50 &
            sleep_pid=$!
            wait "$sleep_pid" 2>/dev/null || true
            sleep_pid=""
            sudo -n -v 2>/dev/null || sudo -n true 2>/dev/null || break
        done
    ) </dev/null >/dev/null 2>&1 3>&- 4>&- &
    KAZE_SUDO_KEEPALIVE_PID=$!
}

kaze_stop_sudo_keepalive() {
    if [[ -n "$KAZE_SUDO_KEEPALIVE_PID" ]]; then
        if kill -0 "$KAZE_SUDO_KEEPALIVE_PID" 2>/dev/null; then
            kill "$KAZE_SUDO_KEEPALIVE_PID" 2>/dev/null || true
        fi
        wait "$KAZE_SUDO_KEEPALIVE_PID" 2>/dev/null || true
        KAZE_SUDO_KEEPALIVE_PID=""
    fi
}

kaze_cleanup_aur_tmp() {
    if [[ -n "$KAZE_AUR_TMPDIR" && -d "$KAZE_AUR_TMPDIR" ]]; then
        rm -rf -- "$KAZE_AUR_TMPDIR"
        KAZE_AUR_TMPDIR=""
    fi
}

kaze_detect_gpu() {
    local drm_dir="${KAZE_SYS_DRM_DIR:-/sys/class/drm}"
    GPU_MODE="unknown"
    GPU_LABEL="Unknown"
    GPU_IGPU_CARD=""
    GPU_IGPU_VENDOR=""
    GPU_NVIDIA_CARD=""
    GPU_HAS_NVIDIA=false
    GPU_HAS_VM=false
    GPU_DETAIL=""

    if [[ ! -d "$drm_dir" ]]; then
        return 0
    fi

    local first_igpu_card="" first_igpu_vendor=""
    local hybrid_igpu_card="" hybrid_igpu_vendor=""
    local vm_vendor=""
    local card_path card_name vendor_file vendor_id conn conn_status has_internal

    for card_path in "$drm_dir"/card[0-9]*; do
        [[ -e "$card_path" ]] || continue
        card_name="${card_path##*/}"
        [[ "$card_name" =~ ^card([0-9]+)$ ]] || continue
        vendor_file="$card_path/device/vendor"
        [[ -r "$vendor_file" ]] || continue

        vendor_id="$(<"$vendor_file")"
        vendor_id="${vendor_id,,}"
        vendor_id="${vendor_id//[[:space:]]/}"

        case "$vendor_id" in
            0x10de)
                GPU_HAS_NVIDIA=true
                if [[ -z "$GPU_NVIDIA_CARD" ]]; then
                    GPU_NVIDIA_CARD="/dev/dri/$card_name"
                fi
                ;;
            0x8086|0x1002)
                local vname="Intel"
                [[ "$vendor_id" == "0x1002" ]] && vname="AMD"
                if [[ -z "$first_igpu_card" ]]; then
                    first_igpu_card="/dev/dri/$card_name"
                    first_igpu_vendor="$vname"
                fi
                has_internal=false
                for conn in "$drm_dir/${card_name}-eDP-"* "$drm_dir/${card_name}-LVDS-"* "$drm_dir/${card_name}-DSI-"*; do
                    [[ -e "$conn" ]] || continue
                    if [[ -r "$conn/status" ]]; then
                        conn_status="$(<"$conn/status")"
                        conn_status="${conn_status//[[:space:]]/}"
                        [[ "$conn_status" == "disconnected" ]] && continue
                    fi
                    has_internal=true
                    break
                done
                if [[ "$has_internal" == true && -z "$hybrid_igpu_card" ]]; then
                    hybrid_igpu_card="/dev/dri/$card_name"
                    hybrid_igpu_vendor="$vname"
                fi
                ;;
            0x1af4|0x1b36|0x15ad|0x1234)
                GPU_HAS_VM=true
                if [[ -z "$vm_vendor" ]]; then
                    case "$vendor_id" in
                        0x1af4) vm_vendor="VirtIO" ;;
                        0x1b36) vm_vendor="QXL" ;;
                        0x15ad) vm_vendor="VMware" ;;
                        0x1234) vm_vendor="Bochs" ;;
                    esac
                fi
                ;;
        esac
    done

    if [[ "$GPU_HAS_NVIDIA" == true ]]; then
        if [[ -n "$hybrid_igpu_card" ]]; then
            GPU_MODE="hybrid-laptop"
            GPU_IGPU_CARD="$hybrid_igpu_card"
            GPU_IGPU_VENDOR="$hybrid_igpu_vendor"
            GPU_LABEL="Hybrid ${hybrid_igpu_vendor}+NVIDIA"
        elif [[ -n "$first_igpu_card" ]]; then
            GPU_MODE="multi-gpu-desktop"
            GPU_IGPU_CARD="$first_igpu_card"
            GPU_IGPU_VENDOR="$first_igpu_vendor"
            GPU_LABEL="Desktop ${first_igpu_vendor}+NVIDIA"
        else
            GPU_MODE="single-nvidia"
            GPU_LABEL="NVIDIA"
        fi
    elif [[ -n "$first_igpu_card" ]]; then
        GPU_MODE="single-igpu"
        GPU_IGPU_CARD="$first_igpu_card"
        GPU_IGPU_VENDOR="$first_igpu_vendor"
        GPU_LABEL="$first_igpu_vendor"
    elif [[ "$GPU_HAS_VM" == true ]]; then
        GPU_MODE="vm"
        GPU_LABEL="VM (${vm_vendor})"
    fi

    if command -v lspci >/dev/null 2>&1; then
        GPU_DETAIL="$(lspci 2>/dev/null | grep -iE 'vga|3d|display' | head -n 3 | paste -sd '; ' - || true)"
    fi
}

kaze_seed_hybrid_gpu_user_lua() {
    local user_lua="$1"
    if [[ "$GPU_MODE" != "hybrid-laptop" || -z "$GPU_IGPU_CARD" ]]; then
        return 0
    fi
    if [[ ! -f "$user_lua" || -L "$user_lua" ]]; then
        return 0
    fi
    if grep -Eq '^[[:space:]]*drm_devices[[:space:]]*=' "$user_lua"; then
        _kaze_msg_info "user.lua already configures drm_devices; leaving untouched"
        return 0
    fi

    local extra_hint=""
    if [[ -n "$GPU_NVIDIA_CARD" ]]; then
        extra_hint=" (append :${GPU_NVIDIA_CARD} if an external port is wired to NVIDIA)"
    fi
    local drm_line="    drm_devices = \"${GPU_IGPU_CARD}\", -- detected ${GPU_IGPU_VENDOR} iGPU${extra_hint}"
    local egl_line="    prefer_mesa_egl = true, -- prevents Chrome WebRTC EglDmaBuf from probing NVIDIA EGL"

    local tmp_lua
    tmp_lua="$(mktemp -- "${user_lua}.XXXXXXXX")"

    local replaced_drm=false replaced_egl=false line
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$replaced_drm" == false && "$line" =~ ^[[:space:]]*--[[:space:]]*drm_devices[[:space:]]*= ]]; then
            printf '%s\n' "$drm_line" >> "$tmp_lua"
            replaced_drm=true
        elif [[ "$replaced_egl" == false && "$line" =~ ^[[:space:]]*--[[:space:]]*prefer_mesa_egl[[:space:]]*= ]]; then
            printf '%s\n' "$egl_line" >> "$tmp_lua"
            replaced_egl=true
        else
            printf '%s\n' "$line" >> "$tmp_lua"
        fi
    done < "$user_lua"

    if [[ "$replaced_drm" == false || "$replaced_egl" == false ]]; then
        local tmp_ins
        tmp_ins="$(mktemp -- "${user_lua}.ins.XXXXXXXX")"
        local inserted=false
        local lines=()
        while IFS= read -r line || [[ -n "$line" ]]; do
            lines+=("$line")
        done < "$tmp_lua"
        local i last_brace=-1
        for (( i=${#lines[@]}-1; i>=0; i-- )); do
            if [[ "${lines[$i]}" =~ ^[[:space:]]*\}[[:space:]]*$ ]]; then
                last_brace=$i
                break
            fi
        done
        for (( i=0; i<${#lines[@]}; i++ )); do
            if (( i == last_brace )) && [[ "$inserted" == false ]]; then
                [[ "$replaced_drm" == false ]] && printf '%s\n' "$drm_line" >> "$tmp_ins"
                [[ "$replaced_egl" == false ]] && printf '%s\n' "$egl_line" >> "$tmp_ins"
                inserted=true
            fi
            printf '%s\n' "${lines[$i]}" >> "$tmp_ins"
        done
        if [[ "$inserted" == false ]]; then
            [[ "$replaced_drm" == false ]] && printf '%s\n' "$drm_line" >> "$tmp_ins"
            [[ "$replaced_egl" == false ]] && printf '%s\n' "$egl_line" >> "$tmp_ins"
        fi
        mv -fT -- "$tmp_ins" "$tmp_lua"
    fi

    if command -v luac >/dev/null 2>&1; then
        if ! luac -p -- "$tmp_lua" >/dev/null 2>&1; then
            rm -f -- "$tmp_lua"
            _kaze_msg_warn "Generated hybrid GPU user.lua failed luac -p validation; keeping template untouched"
            return 1
        fi
    fi

    mv -fT -- "$tmp_lua" "$user_lua"
    _kaze_msg_ok "Seeded hybrid GPU settings in user.lua (${GPU_IGPU_CARD}, prefer_mesa_egl = true)"
}

kaze_detect_conflicts() {
    CONFLICT_HARD=()
    CONFLICT_SOFT=()
    if ! command -v pacman >/dev/null 2>&1; then
        return 0
    fi

    local installed
    installed="$(pacman -Qq 2>/dev/null || true)"
    if [[ -z "$installed" ]]; then
        return 0
    fi

    local pkg
    for pkg in pulseaudio pipewire-media-session; do
        if grep -Fxq "$pkg" <<< "$installed"; then
            CONFLICT_HARD+=("$pkg")
        fi
    done

    for pkg in xdg-desktop-portal-wlr dunst mako fnott swaync; do
        if grep -Fxq "$pkg" <<< "$installed"; then
            CONFLICT_SOFT+=("$pkg")
        fi
    done
}

_kaze_unit_exists() {
    local unit="$1"
    systemctl cat "$unit" >/dev/null 2>&1
}

_kaze_unit_enabled_or_active() {
    local unit="$1"
    systemctl is-enabled --quiet "$unit" 2>/dev/null || systemctl is-active --quiet "$unit" 2>/dev/null
}

kaze_run_system_setup() {
    local target_user="${1:-${USER:-$(id -un)}}"

    # 1. NetworkManager (only if no other network manager/daemon is enabled or active)
    if command -v systemctl >/dev/null 2>&1; then
        local other_net="" unit netctl_match
        for unit in systemd-networkd.service iwd.service connman.service dhcpcd.service; do
            if _kaze_unit_enabled_or_active "$unit"; then
                other_net="$unit"
                break
            fi
        done
        if [[ -z "$other_net" ]]; then
            local pat
            for pat in 'netctl*.service' 'dhcpcd@*.service'; do
                netctl_match="$(systemctl list-unit-files --state=enabled --no-legend "$pat" 2>/dev/null | head -n 1 || true)"
                if [[ -z "$netctl_match" ]]; then
                    netctl_match="$(systemctl list-units --state=active --no-legend "$pat" 2>/dev/null | head -n 1 || true)"
                fi
                if [[ -n "$netctl_match" ]]; then
                    other_net="${netctl_match%%[[:space:]]*}"
                    break
                fi
            done
        fi

        if [[ -n "$other_net" ]]; then
            _kaze_msg_info "Keeping existing network stack (${other_net}); skipping NetworkManager.service"
        elif _kaze_unit_exists NetworkManager.service; then
            if systemctl is-enabled --quiet NetworkManager.service 2>/dev/null; then
                _kaze_msg_ok "NetworkManager.service already enabled"
            else
                sudo systemctl enable NetworkManager.service
                _kaze_msg_ok "Enabled NetworkManager.service (without --now to preserve active link)"
            fi
        else
            _kaze_msg_warn "NetworkManager.service unit not found; skipping"
        fi

        # 2. Bluetooth (safe on hardware without BT due to ConditionPathIsDirectory=/sys/class/bluetooth)
        if _kaze_unit_exists bluetooth.service; then
            if systemctl is-enabled --quiet bluetooth.service 2>/dev/null; then
                _kaze_msg_ok "bluetooth.service already enabled"
            else
                sudo systemctl enable bluetooth.service
                _kaze_msg_ok "Enabled bluetooth.service"
            fi
        else
            _kaze_msg_info "bluetooth.service unit not present; skipping"
        fi

        # 3. PipeWire user sockets/service
        local runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
        if [[ -S "$runtime_dir/bus" ]]; then
            if systemctl --user enable pipewire.socket pipewire-pulse.socket wireplumber.service >/dev/null 2>&1; then
                _kaze_msg_ok "Enabled user audio units (pipewire.socket, pipewire-pulse.socket, wireplumber.service)"
            else
                _kaze_msg_warn "Could not enable all PipeWire user units via systemctl --user"
            fi
        else
            _kaze_msg_warn "User D-Bus ($runtime_dir/bus) unavailable; skip user PipeWire enable (run 'systemctl --user enable pipewire.socket pipewire-pulse.socket wireplumber.service' on login)"
        fi
    else
        _kaze_msg_warn "systemctl not found; skipping service setup"
    fi

    # 4. video group (backlight fallback for brightnessctl; never add input group)
    if getent group video >/dev/null 2>&1; then
        if id -nG "$target_user" 2>/dev/null | tr ' ' '\n' | grep -Fxq "video"; then
            _kaze_msg_ok "User '$target_user' already in group 'video'"
        else
            sudo usermod -aG video "$target_user"
            _kaze_msg_ok "Added '$target_user' to group 'video'"
        fi
    fi

    # 5. Font cache refresh
    if command -v fc-cache >/dev/null 2>&1; then
        if fc-cache -f >/dev/null 2>&1; then
            _kaze_msg_ok "Font cache refreshed (fc-cache -f)"
        else
            _kaze_msg_warn "fc-cache -f returned non-zero; continuing"
        fi
    fi

    # 6. XDG user directories (~/Downloads, ~/Pictures, ~/Documents, ...)
    if command -v xdg-user-dirs-update >/dev/null 2>&1; then
        if xdg-user-dirs-update >/dev/null 2>&1; then
            _kaze_msg_ok "XDG user directories initialized (xdg-user-dirs-update)"
        else
            _kaze_msg_warn "xdg-user-dirs-update returned non-zero; continuing"
        fi
    fi
}

kaze_detect_existing_dm() {
    EXISTING_DM=""
    if ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi

    local unit ly_match link_path
    for unit in gdm.service sddm.service lightdm.service lxdm.service greetd.service ly.service ly@tty1.service ly@tty2.service; do
        if _kaze_unit_enabled_or_active "$unit"; then
            EXISTING_DM="$unit"
            return 0
        fi
    done

    ly_match="$(systemctl list-units --type=service --state=active --no-legend 'ly@*.service' 2>/dev/null | head -n 1 || true)"
    if [[ -n "$ly_match" ]]; then
        EXISTING_DM="${ly_match%%[[:space:]]*}"
        return 0
    fi

    local sys_etc="${KAZE_SYSTEMD_ETC_DIR:-/etc/systemd/system}"
    if [[ -d "$sys_etc" ]]; then
        for link_path in "$sys_etc"/*.wants/ly@*.service; do
            [[ -L "$link_path" || -e "$link_path" ]] || continue
            EXISTING_DM="${link_path##*/}"
            return 0
        done
    fi

    if _kaze_unit_enabled_or_active display-manager.service; then
        EXISTING_DM="display-manager.service"
    fi
}

kaze_setup_display_manager() {
    local dm_choice="${1:-none}"
    local target_user="${2:-${USER:-}}"
    if [[ "$dm_choice" == "none" ]]; then
        return 0
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        _kaze_msg_warn "systemctl unavailable; skipping Display Manager setup ($dm_choice)"
        return 0
    fi

    kaze_detect_existing_dm
    if [[ -n "$EXISTING_DM" ]]; then
        if [[ "$dm_choice" == "ly" && "$EXISTING_DM" == ly* ]]; then
            _kaze_msg_ok "Display Manager '$EXISTING_DM' is already enabled"
            return 0
        fi
        if [[ ("$dm_choice" == "greetd" || "$dm_choice" == "noctalia") && "$EXISTING_DM" == "greetd.service" ]]; then
            _kaze_msg_ok "Display Manager 'greetd.service' is already enabled; preserving existing config"
            return 0
        fi
        if [[ "$dm_choice" == "noctalia" ]]; then
            _kaze_msg_warn "Existing Display Manager detected ($EXISTING_DM); refusing to overwrite with noctalia-greeter (greetd)."
            _kaze_msg_info "To switch manually later: sudo systemctl disable $EXISTING_DM && sudo systemctl enable greetd.service"
            return 0
        fi
        if [[ "$dm_choice" == "greetd" ]]; then
            _kaze_msg_warn "Existing Display Manager detected ($EXISTING_DM); refusing to overwrite with greetd."
            _kaze_msg_info "To switch manually later: sudo systemctl disable $EXISTING_DM && sudo systemctl enable greetd.service"
            return 0
        fi
        if [[ "$dm_choice" == "ly" ]]; then
            _kaze_msg_warn "Existing Display Manager detected ($EXISTING_DM); refusing to overwrite with ly."
            _kaze_msg_info "To switch manually later: sudo systemctl disable $EXISTING_DM && sudo systemctl enable ly@tty1.service"
            return 0
        fi
    fi

    case "$dm_choice" in
        noctalia)
            if ! _kaze_unit_exists "greetd.service"; then
                _kaze_msg_warn "greetd.service unit not found; skipping noctalia-greeter configuration and enable"
                return 0
            fi
            local greeter_dir="${KAZE_NOCTALIA_GREETER_DIR:-/var/lib/noctalia-greeter}"
            local greeter_setup="${KAZE_NOCTALIA_GREETER_SETUP:-/usr/share/noctalia-greeter/setup_greeter_system.sh}"
            if [[ -x "$greeter_setup" ]]; then
                sudo "$greeter_setup" >/dev/null || _kaze_msg_warn "noctalia-greeter setup_greeter_system.sh returned non-zero; continuing"
            fi
            sudo mkdir -p -- "$greeter_dir"

            local greeter_toml="$greeter_dir/greeter.toml"
            if [[ ! -f "$greeter_toml" ]] || ! grep -Eq '^[[:space:]]*\[[a-zA-Z]' "$greeter_toml" 2>/dev/null; then
                local tmp_gt
                tmp_gt="$(mktemp "${TMPDIR:-/tmp}/kaze-greeter.XXXXXX")"
                cat > "$tmp_gt" <<'EOF'
# Kaze defaults for noctalia-greeter (declarative; UI and Sync never overwrite this)
[session]
default = "Hyprland"

[cursor]
theme = "Adwaita"
size = 24

[pointer]
accel_profile = "flat"

[clock]
enabled = true
time_format = "%H:%M"
date_format = "%A, %d %B"
EOF
                sudo install -m 0644 -- "$tmp_gt" "$greeter_toml"
                rm -f -- "$tmp_gt"
            fi

            local greeter_wall="/usr/share/noctalia/assets/noctalia-wallpaper.png"
            local wall_src="${REPO_DIR:-}/assets/wallpapers/05-kanagawa.jpg"
            if [[ -n "${REPO_DIR:-}" && -f "$wall_src" ]]; then
                greeter_wall="$greeter_dir/wallpaper.jpg"
                sudo install -m 0644 -- "$wall_src" "$greeter_wall"
            fi

            local sync_toml="$greeter_dir/sync.toml"
            if [[ ! -f "$sync_toml" ]] || ! grep -Eq '^\[appearance\.wallpaper\]' "$sync_toml" 2>/dev/null; then
                local tmp_st
                tmp_st="$(mktemp "${TMPDIR:-/tmp}/kaze-sync.XXXXXX")"
                cat > "$tmp_st" <<EOF
# Seeded Kaze appearance (Kanagawa + bundled 4K wallpaper; freely updated by UI & Noctalia Sync)
[appearance]
scheme = "Kanagawa"
theme_mode = "dark"
font_family = "JetBrainsMono Nerd Font"
corner_radius_scale = 1.0

[appearance.wallpaper]
path = "${greeter_wall}"
blur = 0.25
tint = 0.15

[session]
last = "Hyprland"
EOF
                sudo install -m 0644 -- "$tmp_st" "$sync_toml"
                rm -f -- "$tmp_st"
            fi

            if [[ -z "${KAZE_NOCTALIA_GREETER_DIR:-}" ]] && id greeter >/dev/null 2>&1; then
                local chown_targets=("$greeter_toml" "$sync_toml")
                [[ -f "$greeter_dir/wallpaper.jpg" ]] && chown_targets+=("$greeter_dir/wallpaper.jpg")
                sudo chown greeter:greeter -- "${chown_targets[@]}" 2>/dev/null || true
            fi
            if [[ -z "${KAZE_NOCTALIA_GREETER_DIR:-}" && -n "$target_user" ]] && command -v noctalia-greeter >/dev/null 2>&1; then
                sudo noctalia-greeter passwordless-sync enable "$target_user" >/dev/null 2>&1 || true
            fi

            local greetd_cfg="${KAZE_GREETD_CONFIG:-/etc/greetd/config.toml}"
            if [[ -e "$greetd_cfg" || -L "$greetd_cfg" ]]; then
                local bak_path
                bak_path="${greetd_cfg}.kaze-bak-$(date +%Y%m%d-%H%M%S)"
                sudo cp -a -- "$greetd_cfg" "$bak_path"
                _kaze_msg_info "Backed up existing $greetd_cfg -> $bak_path"
            fi
            local greeter_cmd="/usr/bin/noctalia-greeter-session --session Hyprland"
            if [[ "${GPU_MODE:-unknown}" == "vm" ]]; then
                # VirGL hardware cursor planes can flip vertically under wlroots in QEMU GTK GL.
                greeter_cmd="env WLR_NO_HARDWARE_CURSORS=1 ${greeter_cmd}"
            fi
            local tmp_cfg
            tmp_cfg="$(mktemp "${TMPDIR:-/tmp}/kaze-greetd.XXXXXX")"
            cat > "$tmp_cfg" <<EOF
[terminal]
vt = 1

[default_session]
command = "${greeter_cmd}"
user = "greeter"
EOF
            sudo mkdir -p -- "$(dirname -- "$greetd_cfg")"
            sudo install -m 0644 -- "$tmp_cfg" "$greetd_cfg"
            rm -f -- "$tmp_cfg"
            if ! systemctl is-enabled --quiet greetd.service 2>/dev/null; then
                sudo systemctl enable greetd.service
            fi
            _kaze_msg_ok "Configured $greetd_cfg and enabled greetd.service (noctalia-greeter, Kanagawa)"
            ;;
        ly)
            if _kaze_unit_exists "ly@.service"; then
                if systemctl is-enabled --quiet getty@tty1.service 2>/dev/null; then
                    sudo systemctl disable getty@tty1.service
                fi
                sudo systemctl enable ly@tty1.service
                _kaze_msg_ok "Enabled ly@tty1.service (TTY2-TTY6 kept as rescue shells)"
            elif _kaze_unit_exists "ly.service"; then
                sudo systemctl enable ly.service
                _kaze_msg_ok "Enabled ly.service"
            else
                _kaze_msg_warn "Neither ly@.service nor ly.service unit found; skipping ly enable"
            fi
            ;;
        greetd)
            if ! _kaze_unit_exists "greetd.service"; then
                _kaze_msg_warn "greetd.service unit not found; skipping greetd configuration and enable"
                return 0
            fi
            local greetd_cfg="${KAZE_GREETD_CONFIG:-/etc/greetd/config.toml}"
            if [[ -e "$greetd_cfg" || -L "$greetd_cfg" ]]; then
                local bak_path
                bak_path="${greetd_cfg}.kaze-bak-$(date +%Y%m%d-%H%M%S)"
                sudo cp -a -- "$greetd_cfg" "$bak_path"
                _kaze_msg_info "Backed up existing $greetd_cfg -> $bak_path"
            fi
            local tmp_cfg
            tmp_cfg="$(mktemp "${TMPDIR:-/tmp}/kaze-greetd.XXXXXX")"
            cat > "$tmp_cfg" <<'EOF'
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --remember --remember-session --asterisks --sessions /usr/share/wayland-sessions --cmd start-hyprland"
user = "greeter"
EOF
            sudo mkdir -p -- "$(dirname -- "$greetd_cfg")"
            sudo install -m 0644 -- "$tmp_cfg" "$greetd_cfg"
            rm -f -- "$tmp_cfg"
            if ! systemctl is-enabled --quiet greetd.service 2>/dev/null; then
                sudo systemctl enable greetd.service
            fi
            _kaze_msg_ok "Configured $greetd_cfg and enabled greetd.service (tuigreet)"
            ;;
        *)
            _kaze_msg_warn "Unknown display manager '$dm_choice'"
            return 1
            ;;
    esac
}

kaze_install_aur_helper() {
    local aur_pkg="${1:-none}"
    local noconfirm="${2:-false}"
    if [[ "$aur_pkg" == "none" ]]; then
        return 0
    fi

    local bin_name=""
    case "$aur_pkg" in
        yay-bin)  bin_name="yay" ;;
        paru-bin) bin_name="paru" ;;
        *)
            _kaze_msg_warn "Unsupported AUR helper '$aur_pkg' (expected yay-bin or paru-bin)"
            return 1
            ;;
    esac

    if command -v "$bin_name" >/dev/null 2>&1; then
        _kaze_msg_ok "AUR helper '$bin_name' already in PATH; skipping $aur_pkg"
        return 0
    fi

    if ! command -v git >/dev/null 2>&1 || ! command -v makepkg >/dev/null 2>&1; then
        _kaze_msg_warn "git and base-devel (makepkg) are required to build $aur_pkg"
        return 1
    fi

    local aur_base="${KAZE_AUR_BASE_URL:-https://aur.archlinux.org}"
    KAZE_AUR_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/kaze-aur.XXXXXX")" || return 1
    if ! git clone --depth 1 "${aur_base}/${aur_pkg}.git" "$KAZE_AUR_TMPDIR/$aur_pkg"; then
        kaze_cleanup_aur_tmp
        return 1
    fi

    local makepkg_flags=(-si --needed)
    if [[ "$noconfirm" == true ]]; then
        makepkg_flags+=(--noconfirm)
    fi

    if ! (
        cd -- "$KAZE_AUR_TMPDIR/$aur_pkg" || exit 1
        makepkg "${makepkg_flags[@]}"
    ); then
        kaze_cleanup_aur_tmp
        return 1
    fi
    kaze_cleanup_aur_tmp
    _kaze_msg_ok "Installed opt-in AUR helper $aur_pkg ($bin_name)"
}
