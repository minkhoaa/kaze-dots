-- Blind Black-Box & Brute-Force QA Test Suite for kaze-dots installer stack
-- Derived strictly from the Behavioral Specification.
-- Covers:
--   1. Package Manifest & scripts/install-packages.sh
--   2. scripts/install.sh CLI Flags, Validation, Styles & --dry-run
--   3. Stage 0 Bootstrap (scripts/bootstrap.sh)
--   4. GPU Detection & Safe Hybrid Laptop user.lua Seeding
--   5. Package Conflict Detection & Handling
--   6. System Setup (--system-setup / --skip-system-setup)
--   7. Optional Display Manager (--dm none|ly|greetd)
--   8. Opt-In AUR Helper (--aur none|yay-bin|paru-bin)
--   9. Logging, sudo -v Keepalive, Post-Install kaze-doctor, Live Audio 16-State Matrix & PTY TUI

local function run_suite(test, assert_eq, assert_true, assert_contains, repo_dir)
    math.randomseed(os.time() + math.floor(os.clock() * 1000000))

    -- =========================================================================
    -- Core utilities (Lua standard library only)
    -- =========================================================================

    local function sh_quote(s)
        return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
    end

    local function read_file(path)
        local f = io.open(path, "rb")
        if not f then
            return nil
        end
        local data = f:read("*a")
        f:close()
        return data
    end

    local function write_file(path, content)
        local f, err = io.open(path, "wb")
        if not f then
            error("write_file failed for " .. tostring(path) .. ": " .. tostring(err))
        end
        f:write(content)
        f:close()
    end

    local function decode_exec(ok, why, code)
        if ok == true then
            return 0
        end
        if type(code) == "number" then
            if why == "signal" then
                return 128 + code
            end
            return code
        end
        if type(ok) == "number" then
            return ok
        end
        return 1
    end

    local function exec_sh(cmd)
        local ok, why, code = os.execute(cmd)
        return decode_exec(ok, why, code)
    end

    local function capture_sh(cmd)
        local p = io.popen(cmd, "r")
        if not p then
            return "", 1
        end
        local out = p:read("*a") or ""
        local ok, why, code = p:close()
        return out, decode_exec(ok, why, code)
    end

    local function trim(s)
        return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
    end

    local function split_lines(s)
        local out = {}
        for line in (tostring(s or "") .. "\n"):gmatch("(.-)\r?\n") do
            out[#out + 1] = line
        end
        if #out > 0 and out[#out] == "" then
            table.remove(out)
        end
        return out
    end

    local function safe_rm_rf(dir)
        if type(dir) == "string" and dir:sub(1, 13) == "/tmp/kaze-bb-" and not dir:find("%.%.", 1, true) then
            exec_sh("rm -rf -- " .. sh_quote(dir))
        end
    end

    local function mkdir_p_many(dirs)
        if #dirs == 0 then
            return
        end
        local parts = { "mkdir", "-p", "--" }
        for i = 1, #dirs do
            parts[#parts + 1] = sh_quote(dirs[i])
        end
        local rc = exec_sh(table.concat(parts, " "))
        if rc ~= 0 then
            error("mkdir -p failed for batch")
        end
    end

    local function mkdir_p(dir)
        mkdir_p_many({ dir })
    end

    local function path_exists(p)
        return exec_sh("test -e " .. sh_quote(p) .. " -o -L " .. sh_quote(p)) == 0
    end

    local function is_file(p)
        return exec_sh("test -f " .. sh_quote(p) .. " -a ! -L " .. sh_quote(p)) == 0
    end

    local function is_symlink(p)
        return exec_sh("test -L " .. sh_quote(p)) == 0
    end

    local function readlink(p)
        local out, rc = capture_sh("readlink -- " .. sh_quote(p))
        if rc ~= 0 then
            return nil
        end
        return trim(out)
    end

    local function list_tree(dir)
        if not path_exists(dir) then
            return "<MISSING>"
        end
        local out = capture_sh(
            "find " .. sh_quote(dir) .. " -mindepth 1 -printf '%P|%y|%l\\n' 2>/dev/null | LC_ALL=C sort"
        )
        return out
    end

    local function snapshot_paths(paths)
        local parts = {}
        for i = 1, #paths do
            parts[#parts + 1] = paths[i] .. "::\n" .. list_tree(paths[i])
        end
        return table.concat(parts, "\n---\n")
    end

    local function set_from_list(list)
        local s = {}
        for i = 1, #list do
            s[list[i]] = true
        end
        return s
    end

    local function sorted_keys(tbl)
        local keys = {}
        for k in pairs(tbl) do
            keys[#keys + 1] = k
        end
        table.sort(keys)
        return keys
    end

    -- Resolve absolute repo_dir without inspecting any repo contents
    local abs_repo_dir
    do
        local out, rc = capture_sh("realpath -- " .. sh_quote(repo_dir or "."))
        if rc == 0 and trim(out) ~= "" then
            abs_repo_dir = trim(out)
        else
            abs_repo_dir = repo_dir or "."
        end
    end

    local INSTALL_SH = abs_repo_dir .. "/scripts/install.sh"
    local INSTALL_PKGS_SH = abs_repo_dir .. "/scripts/install-packages.sh"
    local BOOTSTRAP_SH = abs_repo_dir .. "/scripts/bootstrap.sh"
    local DOCTOR_BIN = abs_repo_dir .. "/bin/kaze-doctor"

    -- =========================================================================
    -- Specification Constants (Strictly from Behavioral Specification)
    -- =========================================================================

    local MINIMAL_PKGS = {
        "hyprland", "noctalia", "xdg-desktop-portal", "xdg-desktop-portal-hyprland",
        "xdg-desktop-portal-gtk", "dconf", "libnotify", "foot", "zsh",
        "zsh-autosuggestions", "zsh-syntax-highlighting", "zsh-completions",
        "pipewire", "pipewire-pulse", "pipewire-alsa", "wireplumber",
        "wl-clipboard", "xdg-utils", "brightnessctl", "playerctl",
        "networkmanager", "bluez", "bluez-utils", "btop",
        "ttf-jetbrains-mono-nerd", "adwaita-cursors", "lua",
    }

    local FULL_EXTRA_PKGS = {
        "slurp", "wf-recorder", "ffmpeg", "hyprpicker", "wl-mirror",
        "thunar", "adw-gtk-theme", "yazi", "imv", "zathura",
        "zathura-pdf-poppler", "gnome-keyring", "fcitx5", "fcitx5-bamboo",
        "fcitx5-gtk", "noto-fonts", "noto-fonts-emoji", "fzf", "zoxide",
        "eza", "bat", "ripgrep", "fd", "starship",
    }

    local FULL_PKGS = {}
    for i = 1, #MINIMAL_PKGS do
        FULL_PKGS[#FULL_PKGS + 1] = MINIMAL_PKGS[i]
    end
    for i = 1, #FULL_EXTRA_PKGS do
        FULL_PKGS[#FULL_PKGS + 1] = FULL_EXTRA_PKGS[i]
    end

    local LEGACY_BANNED_PKGS = {
        "waybar", "swaybg", "fuzzel", "fnott", "hypridle", "hyprlock",
        "cliphist", "hyprsunset", "matugen", "mate-polkit", "grim", "swappy",
        "pulseaudio", "pipewire-media-session", "gst-plugin-pipewire",
        "zathura-pdf-mupdf",
    }

    local CANONICAL_STYLES = {
        "omarchy-rail", "swiss-grid", "corner-hud", "ghost-zero",
        "dynamic-island", "hardware-notch", "glass-studio", "floating-rail",
        "tui-hacker", "retro-90s", "cinema-frame",
    }

    local STYLE_ALIASES = {
        ["brutalist"] = "omarchy-rail",
        ["omarchy"] = "omarchy-rail",
        ["swiss"] = "swiss-grid",
        ["notion"] = "swiss-grid",
        ["floating-islands"] = "corner-hud",
        ["ghost"] = "ghost-zero",
        ["zero-bar"] = "ghost-zero",
        ["concave-notch"] = "hardware-notch",
        ["glass"] = "glass-studio",
        ["macos"] = "glass-studio",
        ["tui"] = "tui-hacker",
        ["hacker"] = "tui-hacker",
        ["retro"] = "retro-90s",
        ["win95"] = "retro-90s",
        ["pixel"] = "retro-90s",
        ["cinema"] = "cinema-frame",
    }

    -- =========================================================================
    -- Shared Safe Whitelisted PATH Builder (Prevents ANY host tool leakage)
    -- =========================================================================

    local suite_uid = string.format("%d-%d", os.time(), math.random(100000, 999999))
    local SAFE_BIN = "/tmp/kaze-bb-safebin-" .. suite_uid
    local REAL_GIT = trim(capture_sh("command -v git 2>/dev/null || true"))
    local HAS_PYTHON3 = exec_sh("command -v python3 >/dev/null 2>&1") == 0

    local SAFE_TOOLS = {
        "bash", "sh", "awk", "gawk", "sed", "grep", "egrep", "fgrep",
        "tr", "cut", "sort", "uniq", "head", "tail", "cat", "cp", "mv",
        "rm", "mkdir", "mktemp", "chmod", "chown", "ln", "readlink",
        "realpath", "dirname", "basename", "find", "xargs", "wc", "date",
        "sleep", "kill", "ps", "pgrep", "stat", "touch", "tee", "env",
        "tput", "stty", "timeout", "setsid", "diff", "cmp", "comm",
        "install", "ls", "rmdir", "pwd", "uname", "tty", "true", "false",
        "test", "[", "printf", "expr", "seq", "lua", "luac", "python3",
        "tar", "gzip", "od", "dd", "fold", "paste", "which", "flock",
        "mkfifo", "hostname", "nproc", "sync", "df", "du", "column",
        "infocmp", "reset", "clear",
    }

    local function build_safe_bin()
        mkdir_p(SAFE_BIN)
        local cmd_parts = {}
        for i = 1, #SAFE_TOOLS do
            local tool = SAFE_TOOLS[i]
            cmd_parts[#cmd_parts + 1] = string.format(
                "p=$(command -v %s 2>/dev/null || true); [ -n \"$p\" ] && ln -sf -- \"$p\" %s",
                sh_quote(tool),
                sh_quote(SAFE_BIN .. "/" .. tool)
            )
        end
        exec_sh(table.concat(cmd_parts, "; "))
    end

    -- =========================================================================
    -- Sandbox & Stub Harness
    -- =========================================================================

    local sandbox_seq = 0

    local function make_unix_socket(sock_path)
        if not HAS_PYTHON3 then
            return false
        end
        local rc = exec_sh(
            "python3 -c " .. sh_quote(
                "import os,socket,sys\np=sys.argv[1]\nif os.path.exists(p): os.unlink(p)\n"
                .. "s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)\ns.bind(p)\ns.close()\n"
            ) .. " " .. sh_quote(sock_path)
        )
        return rc == 0
    end

    local function write_drm_layout(drm_dir, cards)
        local dirs = { drm_dir }
        local files = {}
        for i = 1, #cards do
            local c = cards[i]
            local card_dir = drm_dir .. "/" .. c.name
            dirs[#dirs + 1] = card_dir
            if c.vendor ~= nil then
                dirs[#dirs + 1] = card_dir .. "/device"
                files[#files + 1] = { card_dir .. "/device/vendor", c.vendor .. "\n" }
            end
            if c.connectors then
                for j = 1, #c.connectors do
                    local conn = c.connectors[j]
                    local conn_dir = drm_dir .. "/" .. conn.name
                    local nested_dir = card_dir .. "/" .. conn.name
                    dirs[#dirs + 1] = conn_dir
                    dirs[#dirs + 1] = nested_dir
                    if conn.status ~= nil then
                        files[#files + 1] = { conn_dir .. "/status", conn.status .. "\n" }
                        files[#files + 1] = { nested_dir .. "/status", conn.status .. "\n" }
                    end
                end
            end
        end
        mkdir_p_many(dirs)
        for i = 1, #files do
            write_file(files[i][1], files[i][2])
        end
    end

    local function create_sandbox(opts)
        opts = opts or {}
        sandbox_seq = sandbox_seq + 1
        local root = string.format("/tmp/kaze-bb-%s-%04d", suite_uid, sandbox_seq)
        local home = root .. "/" .. (opts.home_rel or "home")
        local xdg_config = root .. "/" .. (opts.xdg_config_rel or "cfg")
        local xdg_data = root .. "/" .. (opts.xdg_data_rel or "data")
        local xdg_cache = root .. "/" .. (opts.xdg_cache_rel or "cache")
        local xdg_state = root .. "/" .. (opts.xdg_state_rel or "state")
        local xdg_runtime = root .. "/rt"
        local stub_bin = root .. "/stub_bin"
        local log_dir = root .. "/logs"
        local state_dir = root .. "/mock_state"
        local etc_dir = root .. "/etc"
        local arch_release = etc_dir .. "/arch-release"
        local sys_drm = opts.missing_drm and (root .. "/no_such_drm") or (root .. "/sys_drm")
        local greetd_cfg = etc_dir .. "/greetd/config.toml"
        local greeter_dir = root .. "/var/lib/noctalia-greeter"
        local greeter_setup = root .. "/no-such-greeter-setup.sh"
        local systemd_etc = etc_dir .. "/systemd/system"
        local aur_base = opts.aur_base_url or ("https://mock-aur.invalid")
        local tmpdir = root .. "/tmp"

        local init_dirs = { stub_bin, log_dir, state_dir, etc_dir, systemd_etc, xdg_runtime, tmpdir }
        if not opts.skip_xdg_mkdir then
            init_dirs[#init_dirs + 1] = home
            init_dirs[#init_dirs + 1] = xdg_config
            init_dirs[#init_dirs + 1] = xdg_data
            init_dirs[#init_dirs + 1] = xdg_cache
            init_dirs[#init_dirs + 1] = xdg_state
        end
        if not opts.missing_drm then
            init_dirs[#init_dirs + 1] = sys_drm
        end
        if opts.greetd_dir or opts.greetd_existing_content ~= nil then
            init_dirs[#init_dirs + 1] = etc_dir .. "/greetd"
        end
        mkdir_p_many(init_dirs)

        if opts.arch ~= false then
            write_file(arch_release, "Arch Linux\n")
        end
        if not opts.missing_drm and opts.drm_cards then
            write_drm_layout(sys_drm, opts.drm_cards)
        end
        if opts.greetd_existing_content ~= nil then
            write_file(greetd_cfg, opts.greetd_existing_content)
        end

        if opts.systemd_symlinks then
            local sym_dirs = {}
            for rel in pairs(opts.systemd_symlinks) do
                local full = systemd_etc .. "/" .. rel
                local parent = full:match("^(.*)/[^/]+$")
                if parent then
                    sym_dirs[#sym_dirs + 1] = parent
                end
            end
            mkdir_p_many(sym_dirs)
            for rel, target in pairs(opts.systemd_symlinks) do
                exec_sh("ln -sf -- " .. sh_quote(target) .. " " .. sh_quote(systemd_etc .. "/" .. rel))
            end
        end

        if opts.user_bus_socket then
            assert(make_unix_socket(xdg_runtime .. "/bus"), "failed to create mock UNIX socket")
        elseif opts.user_bus_regular_file then
            write_file(xdg_runtime .. "/bus", "not-a-socket\n")
        end

        local calls_log = log_dir .. "/calls.log"
        write_file(calls_log, "")

        local mock_user = opts.user or "testuser"
        local mock_shell = opts.login_shell or "/usr/bin/bash"
        if mock_shell == "mock_zsh" then
            mock_shell = stub_bin .. "/zsh"
        end
        local in_video = opts.in_video_group == true
        local video_group_exists = opts.video_group_exists ~= false

        local function write_list_state(name, list)
            list = list or {}
            write_file(state_dir .. "/" .. name, table.concat(list, "\n") .. (#list > 0 and "\n" or ""))
        end

        write_list_state("installed_pkgs", opts.installed_pkgs or {})
        write_list_state("sys_units_exist", opts.units_exist or { "NetworkManager.service", "bluetooth.service" })
        write_list_state("sys_units_enabled", opts.units_enabled or {})
        write_list_state("sys_units_active", opts.units_active or {})
        write_list_state("usr_units_exist", opts.user_units_exist or {
            "pipewire.service", "pipewire.socket", "pipewire-pulse.socket",
            "pipewire-pulse.service", "wireplumber.service",
        })
        write_list_state("usr_units_enabled", opts.user_units_enabled or {})
        write_list_state("usr_units_active", opts.user_units_active or {})

        -- ---------------------------------------------------------------------
        -- Stub: sudo (safety barrier + logging + executes command in sandbox)
        -- ---------------------------------------------------------------------
        write_file(stub_bin .. "/sudo", string.format([=[#!/usr/bin/env bash
set -u
CALLS=%s
SUDO_V_FAIL=%s
printf 'SUDO' >> "$CALLS"
for a in "$@"; do printf ' %%s' "$a" >> "$CALLS"; done
printf '\n' >> "$CALLS"

want_v=0
while [ $# -gt 0 ]; do
    case "$1" in
        -v|--validate) want_v=1; shift ;;
        -n|-k|-K|-E|-H|-S|-i|-s|-b|-A) shift ;;
        -u|-g|-p|-C|-T) shift 2 ;;
        --) shift; break ;;
        -*) shift ;;
        *) break ;;
    esac
done

if [ "$want_v" -eq 1 ]; then
    if [ "$SUDO_V_FAIL" = "1" ]; then
        exit 1
    fi
    if [ $# -eq 0 ]; then
        exit 0
    fi
fi

if [ $# -eq 0 ]; then
    exit 0
fi

cmd="$1"
shift

case "$cmd" in
    cp|mv|rm|tee|install|mkdir|chmod|chown|ln|touch|dd|sh|bash)
        for a in "$@"; do
            case "$a" in
                /etc/*|/usr/*|/var/*|/boot/*|/sys/*)
                    echo "SAFETY VIOLATION: mock sudo blocked host path: $cmd $*" >&2
                    exit 99
                    ;;
            esac
        done
        ;;
esac

exec "$cmd" "$@"
]=], sh_quote(calls_log), opts.sudo_v_fail and "1" or "0"))

        -- ---------------------------------------------------------------------
        -- Stub: pacman (unless opts.no_pacman)
        -- ---------------------------------------------------------------------
        if not opts.no_pacman then
            write_file(stub_bin .. "/pacman", string.format([=[#!/usr/bin/env bash
set -u
CALLS=%s
STATE=%s
STUB_BIN=%s
REAL_GIT=%s
INSTALLS_GIT=%s
RDD_RC=%s
SYU_RC=%s

printf 'PACMAN' >> "$CALLS"
for a in "$@"; do printf ' %%s' "$a" >> "$CALLS"; done
printf '\n' >> "$CALLS"

case "${1:-}" in
    -V|--version)
        echo "Pacman v7.0.0 - mock"
        exit 0
        ;;
    -Qq)
        if [ $# -eq 1 ]; then
            cat "$STATE/installed_pkgs"
            exit 0
        fi
        shift
        rc=0
        for p in "$@"; do
            if grep -Fxq -- "$p" "$STATE/installed_pkgs"; then
                echo "$p"
            else
                rc=1
            fi
        done
        exit "$rc"
        ;;
    -Q|-Qi|-Qe)
        shift
        if [ $# -eq 0 ]; then
            cat "$STATE/installed_pkgs"
            exit 0
        fi
        rc=0
        for p in "$@"; do
            if grep -Fxq -- "$p" "$STATE/installed_pkgs"; then
                echo "$p 1.0-1"
            else
                rc=1
            fi
        done
        exit "$rc"
        ;;
    -Rdd*|-R*)
        shift
        pkgs=()
        for a in "$@"; do
            case "$a" in
                -*) ;;
                *) pkgs+=("$a") ;;
            esac
        done
        if [ "${#pkgs[@]}" -gt 0 ] && [ "$RDD_RC" -eq 0 ]; then
            tmp="$STATE/installed_pkgs.tmp"
            cp "$STATE/installed_pkgs" "$tmp"
            for p in "${pkgs[@]}"; do
                grep -Fxv -- "$p" "$tmp" > "$tmp.2" || true
                mv "$tmp.2" "$tmp"
            done
            mv "$tmp" "$STATE/installed_pkgs"
        fi
        exit "$RDD_RC"
        ;;
    -S*)
        shift
        for a in "$@"; do
            case "$a" in
                -*) ;;
                *)
                    if [ "$SYU_RC" -eq 0 ]; then
                        if ! grep -Fxq -- "$a" "$STATE/installed_pkgs"; then
                            printf '%%s\n' "$a" >> "$STATE/installed_pkgs"
                        fi
                        if [ "$a" = "git" ] && [ "$INSTALLS_GIT" = "1" ] && [ -n "$REAL_GIT" ]; then
                            ln -sf -- "$REAL_GIT" "$STUB_BIN/git"
                        fi
                    fi
                    ;;
            esac
        done
        exit "$SYU_RC"
        ;;
esac
exit 0
]=],
                sh_quote(calls_log),
                sh_quote(state_dir),
                sh_quote(stub_bin),
                sh_quote(REAL_GIT),
                opts.pacman_installs_git and "1" or "0",
                tostring(opts.pacman_rdd_rc or 0),
                tostring(opts.pacman_syu_rc or 0)
            ))
        end

        -- ---------------------------------------------------------------------
        -- Stub: systemctl (comprehensive system + --user state machine)
        -- ---------------------------------------------------------------------
        write_file(stub_bin .. "/systemctl", string.format([=[#!/usr/bin/env bash
set -u
CALLS=%s
STATE=%s

scope="sys"
quiet=0
now_flag=0
val_only=0
prop=""
state_filter=""
subcmd=""
args=()

while [ $# -gt 0 ]; do
    case "$1" in
        --user) scope="usr"; shift ;;
        --system) scope="sys"; shift ;;
        -q|--quiet) quiet=1; shift ;;
        --now) now_flag=1; shift ;;
        --value) val_only=1; shift ;;
        -p) prop="$2"; shift 2 ;;
        --property=*) prop="${1#--property=}"; shift ;;
        --state=*) state_filter="${1#--state=}"; shift ;;
        --no-pager|--no-legend|--plain|--full|--all|-a|--runtime|--global) shift ;;
        --type=*|--output=*) shift ;;
        -t) shift 2 ;;
        --) shift; while [ $# -gt 0 ]; do args+=("$1"); shift; done ;;
        -*) shift ;;
        *)
            if [ -z "$subcmd" ]; then
                subcmd="$1"
            else
                args+=("$1")
            fi
            shift
            ;;
    esac
done

EXIST_F="$STATE/${scope}_units_exist"
ENABLED_F="$STATE/${scope}_units_enabled"
ACTIVE_F="$STATE/${scope}_units_active"

has_line() { grep -Fxq -- "$1" "$2" 2>/dev/null; }
add_line() { has_line "$1" "$2" || printf '%%s\n' "$1" >> "$2"; }
del_line() {
    local tmp="$2.tmp.$$"
    grep -Fxv -- "$1" "$2" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$2"
}

unit_exists() {
    local u="$1"
    if has_line "$u" "$EXIST_F"; then return 0; fi
    if [[ "$u" == *@*.service ]]; then
        local tmpl="${u%%@*}@.service"
        if has_line "$tmpl" "$EXIST_F"; then return 0; fi
    fi
    return 1
}

matches_patterns() {
    local u="$1"
    shift
    if [ $# -eq 0 ]; then return 0; fi
    local p
    for p in "$@"; do
        # shellcheck disable=SC2053
        if [[ "$u" == $p ]]; then return 0; fi
    done
    return 1
}

case "$subcmd" in
    is-enabled)
        rc=0
        for u in "${args[@]}"; do
            if has_line "$u" "$ENABLED_F"; then
                [ "$quiet" -eq 0 ] && echo "enabled"
            elif unit_exists "$u"; then
                [ "$quiet" -eq 0 ] && echo "disabled"
                rc=1
            else
                [ "$quiet" -eq 0 ] && echo "not-found"
                rc=1
            fi
        done
        exit "$rc"
        ;;
    is-active)
        rc=0
        for u in "${args[@]}"; do
            if has_line "$u" "$ACTIVE_F"; then
                [ "$quiet" -eq 0 ] && echo "active"
            else
                [ "$quiet" -eq 0 ] && echo "inactive"
                rc=3
            fi
        done
        exit "$rc"
        ;;
    cat)
        u="${args[0]:-}"
        if [ -n "$u" ] && unit_exists "$u"; then
            echo "# /usr/lib/systemd/system/$u"
            echo "[Unit]"
            echo "Description=Mock $u"
            exit 0
        fi
        exit 1
        ;;
    show)
        u="${args[0]:-}"
        load="not-found"
        unit_exists "$u" && load="loaded"
        ufstate="disabled"
        has_line "$u" "$ENABLED_F" && ufstate="enabled"
        astate="inactive"
        has_line "$u" "$ACTIVE_F" && astate="active"
        case "$prop" in
            LoadState)
                [ "$val_only" -eq 1 ] && echo "$load" || echo "LoadState=$load"
                ;;
            UnitFileState)
                [ "$val_only" -eq 1 ] && echo "$ufstate" || echo "UnitFileState=$ufstate"
                ;;
            ActiveState)
                [ "$val_only" -eq 1 ] && echo "$astate" || echo "ActiveState=$astate"
                ;;
            *)
                echo "LoadState=$load"
                echo "UnitFileState=$ufstate"
                echo "ActiveState=$astate"
                ;;
        esac
        exit 0
        ;;
    list-unit-files)
        while IFS= read -r u; do
            [ -z "$u" ] && continue
            if matches_patterns "$u" "${args[@]}"; then
                st="disabled"
                has_line "$u" "$ENABLED_F" && st="enabled"
                if [ -z "$state_filter" ] || [ "$state_filter" = "$st" ]; then
                    printf '%%s %%s\n' "$u" "$st"
                fi
            fi
        done < <(cat "$EXIST_F" "$ENABLED_F" | sort -u)
        exit 0
        ;;
    list-units)
        while IFS= read -r u; do
            [ -z "$u" ] && continue
            if matches_patterns "$u" "${args[@]}"; then
                if [ -z "$state_filter" ] || [ "$state_filter" = "active" ] || [ "$state_filter" = "running" ]; then
                    printf '%%s loaded active running Mock unit\n' "$u"
                fi
            fi
        done < "$ACTIVE_F"
        exit 0
        ;;
    enable|disable|start|stop|restart|mask|unmask|daemon-reload)
        printf 'SYSTEMCTL' >> "$CALLS"
        [ "$scope" = "usr" ] && printf ' --user' >> "$CALLS"
        printf ' %%s' "$subcmd" >> "$CALLS"
        [ "$now_flag" -eq 1 ] && printf ' --now' >> "$CALLS"
        for a in "${args[@]}"; do printf ' %%s' "$a" >> "$CALLS"; done
        printf '\n' >> "$CALLS"
        if [ "$subcmd" = "enable" ]; then
            for u in "${args[@]}"; do
                add_line "$u" "$ENABLED_F"
                [ "$now_flag" -eq 1 ] && add_line "$u" "$ACTIVE_F"
            done
        elif [ "$subcmd" = "disable" ]; then
            for u in "${args[@]}"; do
                del_line "$u" "$ENABLED_F"
                [ "$now_flag" -eq 1 ] && del_line "$u" "$ACTIVE_F"
            done
        fi
        exit 0
        ;;
esac
exit 0
]=], sh_quote(calls_log), sh_quote(state_dir)))

        -- ---------------------------------------------------------------------
        -- Stubs: getent, id, groups, whoami, usermod, chsh, fc-cache, curl, reboot
        -- ---------------------------------------------------------------------
        local user_groups_str = in_video and (mock_user .. " wheel video") or (mock_user .. " wheel")
        local video_members = in_video and mock_user or ""

        write_file(stub_bin .. "/getent", string.format([=[#!/usr/bin/env bash
db="${1:-}"
key="${2:-}"
case "$db" in
    group)
        if [ "$key" = "video" ]; then
            if [ %s = "1" ]; then
                echo "video:x:985:%s"
                exit 0
            fi
            exit 2
        fi
        if [ "$key" = "wheel" ]; then
            echo "wheel:x:998:%s"
            exit 0
        fi
        exit 2
        ;;
    passwd)
        if [ "$key" = %s ] || [ -z "$key" ]; then
            echo "%s:x:1000:1000::%s:%s"
            exit 0
        fi
        exit 2
        ;;
esac
exit 2
]=],
            video_group_exists and "'1'" or "'0'",
            video_members,
            mock_user,
            sh_quote(mock_user),
            mock_user,
            home,
            mock_shell
        ))

        write_file(stub_bin .. "/id", string.format([=[#!/usr/bin/env bash
case "${1:-}" in
    -u) echo "1000" ;;
    -un) echo %s ;;
    -g) echo "1000" ;;
    -gn) echo %s ;;
    -nG|-Gn) echo %s ;;
    *) echo "uid=1000(%s) gid=1000(%s) groups=1000(%s)" ;;
esac
]=], sh_quote(mock_user), sh_quote(mock_user), sh_quote(user_groups_str), mock_user, mock_user, mock_user))

        write_file(stub_bin .. "/groups", string.format("#!/usr/bin/env bash\necho %s\n", sh_quote(user_groups_str)))
        write_file(stub_bin .. "/whoami", string.format("#!/usr/bin/env bash\necho %s\n", sh_quote(mock_user)))

        write_file(stub_bin .. "/usermod", string.format([=[#!/usr/bin/env bash
CALLS=%s
printf 'USERMOD' >> "$CALLS"
for a in "$@"; do printf ' %%s' "$a" >> "$CALLS"; done
printf '\n' >> "$CALLS"
exit 0
]=], sh_quote(calls_log)))

        write_file(stub_bin .. "/chsh", string.format([=[#!/usr/bin/env bash
CALLS=%s
printf 'CHSH' >> "$CALLS"
for a in "$@"; do printf ' %%s' "$a" >> "$CALLS"; done
printf '\n' >> "$CALLS"
exit 0
]=], sh_quote(calls_log)))

        if not opts.no_zsh_bin then
            write_file(stub_bin .. "/zsh", "#!/usr/bin/env bash\nexit 0\n")
        end

        if not opts.no_fc_cache then
            write_file(stub_bin .. "/fc-cache", string.format([=[#!/usr/bin/env bash
CALLS=%s
printf 'FC_CACHE' >> "$CALLS"
for a in "$@"; do printf ' %%s' "$a" >> "$CALLS"; done
printf '\n' >> "$CALLS"
exit %s
]=], sh_quote(calls_log), tostring(opts.fc_cache_rc or 0)))
        end

        write_file(stub_bin .. "/curl", string.format([=[#!/usr/bin/env bash
CALLS=%s
printf 'CURL' >> "$CALLS"
for a in "$@"; do printf ' %%s' "$a" >> "$CALLS"; done
printf '\n' >> "$CALLS"
exit %s
]=], sh_quote(calls_log), tostring(opts.curl_rc or 0)))

        for _, dangerous in ipairs({ "reboot", "poweroff", "shutdown", "loginctl" }) do
            write_file(stub_bin .. "/" .. dangerous, string.format([=[#!/usr/bin/env bash
CALLS=%s
printf '%%s' %s >> "$CALLS"
for a in "$@"; do printf ' %%s' "$a" >> "$CALLS"; done
printf '\n' >> "$CALLS"
exit 0
]=], sh_quote(calls_log), sh_quote(dangerous:upper())))
        end

        write_file(stub_bin .. "/hyprctl", [=[#!/usr/bin/env bash
case "${1:-}" in
    version) echo "Hyprland 0.57.0 mock" ;;
    monitors) echo "[]" ;;
    *) echo "{}" ;;
esac
exit 0
]=])

        -- ---------------------------------------------------------------------
        -- Stub: git (modes: "mock", "real", "absent")
        -- ---------------------------------------------------------------------
        local git_mode = opts.git_mode or "mock"
        local git_order_log = log_dir .. "/git_order.log"
        local makepkg_order_log = log_dir .. "/makepkg_order.log"
        local aur_clone_dirs_log = log_dir .. "/aur_clone_dirs.log"

        if git_mode == "real" and REAL_GIT ~= "" then
            write_file(stub_bin .. "/git", string.format([=[#!/usr/bin/env bash
CALLS=%s
printf 'GIT' >> "$CALLS"
for a in "$@"; do printf ' %%s' "$a" >> "$CALLS"; done
printf '\n' >> "$CALLS"
exec %s "$@"
]=], sh_quote(calls_log), sh_quote(REAL_GIT)))
        elseif git_mode == "mock" then
            write_file(stub_bin .. "/git", string.format([=[#!/usr/bin/env bash
CALLS=%s
ORDER_LOG=%s
CLONE_DIRS=%s
CFG=%s
CLONE_RC=%s
printf 'GIT' >> "$CALLS"
for a in "$@"; do printf ' %%s' "$a" >> "$CALLS"; done
printf '\n' >> "$CALLS"

if [ "${1:-}" = "clone" ]; then
    prof_ex="no"; [ -e "$CFG/kaze/profile" ] && prof_ex="yes"
    hypr_ex="no"; [ -e "$CFG/hypr/hyprland.lua" ] && hypr_ex="yes"
    printf 'profile=%%s hyprland=%%s\n' "$prof_ex" "$hypr_ex" >> "$ORDER_LOG"
    if [ "$CLONE_RC" -ne 0 ]; then
        exit "$CLONE_RC"
    fi
    pos=()
    shift
    while [ $# -gt 0 ]; do
        case "$1" in
            --depth|--branch|-b|-o|--origin) shift 2 ;;
            -*) shift ;;
            *) pos+=("$1"); shift ;;
        esac
    done
    target="${pos[1]:-}"
    if [ -z "$target" ] && [ -n "${pos[0]:-}" ]; then
        base="${pos[0]##*/}"
        target="${base%%.git}"
    fi
    if [ -n "$target" ]; then
        mkdir -p -- "$target"
        printf 'pkgname=mock\n' > "$target/PKGBUILD"
        abs_t=$(realpath -- "$target" 2>/dev/null || echo "$target")
        printf '%%s\n' "$abs_t" >> "$CLONE_DIRS"
    fi
fi
exit 0
]=],
                sh_quote(calls_log),
                sh_quote(git_order_log),
                sh_quote(aur_clone_dirs_log),
                sh_quote(xdg_config),
                tostring(opts.git_clone_rc or 0)
            ))
        end

        write_file(stub_bin .. "/makepkg", string.format([=[#!/usr/bin/env bash
CALLS=%s
ORDER_LOG=%s
CFG=%s
RC=%s
printf 'MAKEPKG' >> "$CALLS"
for a in "$@"; do printf ' %%s' "$a" >> "$CALLS"; done
printf '\n' >> "$CALLS"
prof_ex="no"; [ -e "$CFG/kaze/profile" ] && prof_ex="yes"
hypr_ex="no"; [ -e "$CFG/hypr/hyprland.lua" ] && hypr_ex="yes"
printf 'profile=%%s hyprland=%%s pwd=%%s\n' "$prof_ex" "$hypr_ex" "$(pwd)" >> "$ORDER_LOG"
exit "$RC"
]=],
            sh_quote(calls_log),
            sh_quote(makepkg_order_log),
            sh_quote(xdg_config),
            tostring(opts.makepkg_rc or 0)
        ))

        if opts.has_yay then
            write_file(stub_bin .. "/yay", "#!/usr/bin/env bash\nexit 0\n")
        end
        if opts.has_paru then
            write_file(stub_bin .. "/paru", "#!/usr/bin/env bash\nexit 0\n")
        end
        if opts.desktop_bins then
            for _, b in ipairs(opts.desktop_bins) do
                write_file(stub_bin .. "/" .. b, "#!/usr/bin/env bash\nexit 0\n")
            end
        end

        -- Single batched chmod +x across all stubs
        exec_sh("chmod +x -- " .. sh_quote(stub_bin) .. "/*")

        local sb = {
            root = root,
            home = home,
            xdg_config = xdg_config,
            xdg_data = xdg_data,
            xdg_cache = xdg_cache,
            xdg_state = xdg_state,
            xdg_runtime = xdg_runtime,
            stub_bin = stub_bin,
            log_dir = log_dir,
            state_dir = state_dir,
            calls_log = calls_log,
            git_order_log = git_order_log,
            makepkg_order_log = makepkg_order_log,
            aur_clone_dirs_log = aur_clone_dirs_log,
            arch_release = arch_release,
            sys_drm = sys_drm,
            greetd_cfg = greetd_cfg,
            greeter_dir = greeter_dir,
            greeter_setup = greeter_setup,
            systemd_etc = systemd_etc,
            aur_base = aur_base,
            tmpdir = tmpdir,
            user = mock_user,
            login_shell = mock_shell,
            run_counter = 0,
        }

        function sb:set_state_list(name, list)
            write_file(self.state_dir .. "/" .. name, table.concat(list, "\n") .. (#list > 0 and "\n" or ""))
        end

        function sb:base_env(extra)
            local env = {
                HOME = self.home,
                USER = self.user,
                LOGNAME = self.user,
                SHELL = self.login_shell,
                XDG_CONFIG_HOME = self.xdg_config,
                XDG_DATA_HOME = self.xdg_data,
                XDG_CACHE_HOME = self.xdg_cache,
                XDG_STATE_HOME = self.xdg_state,
                XDG_RUNTIME_DIR = self.xdg_runtime,
                PATH = self.stub_bin .. ":" .. SAFE_BIN,
                LANG = "C",
                LC_ALL = "C",
                TERM = "xterm-256color",
                KAZE_ARCH_RELEASE_FILE = self.arch_release,
                KAZE_SYS_DRM_DIR = self.sys_drm,
                KAZE_GREETD_CONFIG = self.greetd_cfg,
                KAZE_NOCTALIA_GREETER_DIR = self.greeter_dir,
                KAZE_NOCTALIA_GREETER_SETUP = self.greeter_setup,
                KAZE_SYSTEMD_ETC_DIR = self.systemd_etc,
                KAZE_AUR_BASE_URL = self.aur_base,
                TMPDIR = self.tmpdir,
            }
            if extra then
                for k, v in pairs(extra) do
                    if v == false then
                        env[k] = nil
                    else
                        env[k] = v
                    end
                end
            end
            return env
        end

        function sb:run(argv, run_opts)
            run_opts = run_opts or {}
            self.run_counter = self.run_counter + 1
            local id = self.run_counter
            local out_f = string.format("%s/out_%d.txt", self.log_dir, id)
            local err_f = string.format("%s/err_%d.txt", self.log_dir, id)
            local in_f = string.format("%s/in_%d.txt", self.log_dir, id)

            local env = self:base_env(run_opts.env)
            local env_parts = { "env", "-i" }
            for _, k in ipairs(sorted_keys(env)) do
                env_parts[#env_parts + 1] = sh_quote(k .. "=" .. tostring(env[k]))
            end

            local cmd_parts = {}
            for i = 1, #argv do
                cmd_parts[#cmd_parts + 1] = sh_quote(argv[i])
            end

            local timeout_sec = run_opts.timeout or 20
            local redir_in
            if run_opts.stdin ~= nil then
                write_file(in_f, run_opts.stdin)
                redir_in = " < " .. sh_quote(in_f)
            else
                redir_in = " < /dev/null"
            end

            local cd_prefix = ""
            if run_opts.cwd then
                cd_prefix = "cd " .. sh_quote(run_opts.cwd) .. " && "
            end

            local full_cmd = string.format(
                "%stimeout %d %s %s%s > %s 2> %s",
                cd_prefix,
                timeout_sec,
                table.concat(env_parts, " "),
                table.concat(cmd_parts, " "),
                redir_in,
                sh_quote(out_f),
                sh_quote(err_f)
            )
            local rc = exec_sh(full_cmd)
            local stdout = read_file(out_f) or ""
            local stderr = read_file(err_f) or ""
            return {
                rc = rc,
                stdout = stdout,
                stderr = stderr,
                combined = stdout .. "\n" .. stderr,
            }
        end

        function sb:calls()
            return read_file(self.calls_log) or ""
        end

        function sb:call_lines()
            return split_lines(self:calls())
        end

        function sb:clear_calls()
            write_file(self.calls_log, "")
        end

        function sb:xdg_snapshot()
            return snapshot_paths({
                self.home, self.xdg_config, self.xdg_data,
                self.xdg_cache, self.xdg_state, self.root .. "/etc/greetd",
            })
        end

        return sb
    end

    local function with_sandbox(opts, fn)
        local sb = create_sandbox(opts)
        local ok, err = pcall(fn, sb)
        safe_rm_rf(sb.root)
        if not ok then
            error(err, 0)
        end
    end

    -- =========================================================================
    -- Package extraction & call inspection helpers
    -- =========================================================================

    local function strip_ansi(s)
        s = tostring(s or "")
        s = s:gsub("\27%][^\7\27]*\7", "")
        s = s:gsub("\27%][^\27]*\27\\", "")
        s = s:gsub("\27%[[0-9;?]*[ -/]*[@-~]", "")
        s = s:gsub("\r", "")
        return s
    end

    local function extract_pacman_pkgs_from_text(text)
        local clean = strip_ansi(text):gsub("\\\n%s*", " ")
        local lines = split_lines(clean)
        local best = nil
        for i = 1, #lines do
            local after = lines[i]:match("pacman%s+%-Syu%s+(.*)$")
            if after then
                local pkgs = {}
                for tok in after:gmatch("%S+") do
                    if tok:sub(1, 1) ~= "-" and tok ~= "\\" then
                        pkgs[#pkgs + 1] = tok
                    end
                end
                if #pkgs > 0 and (not best or #pkgs > #best) then
                    best = pkgs
                end
            end
        end
        return best
    end

    local function extract_pacman_syu_from_calls(call_lines)
        for i = 1, #call_lines do
            local line = call_lines[i]
            local after = line:match("^PACMAN%s+(.*)$")
            if after and after:find("-Syu", 1, true) then
                local pkgs = {}
                local flags = {}
                for tok in after:gmatch("%S+") do
                    if tok:sub(1, 1) == "-" then
                        flags[tok] = true
                    else
                        pkgs[#pkgs + 1] = tok
                    end
                end
                return pkgs, flags, line
            end
        end
        return nil, nil, nil
    end

    local function assert_pkg_set_eq(actual_list, expected_list, ctx)
        assert_true(actual_list ~= nil, ctx .. ": failed to extract package list")
        local actual_set = {}
        for i = 1, #actual_list do
            local p = actual_list[i]
            assert_true(not actual_set[p], ctx .. ": duplicate package " .. p)
            actual_set[p] = true
        end
        local expected_set = set_from_list(expected_list)
        assert_eq(#actual_list, #expected_list, ctx .. ": package count mismatch")
        for _, p in ipairs(expected_list) do
            assert_true(actual_set[p], ctx .. ": missing expected package " .. p)
        end
        for _, p in ipairs(actual_list) do
            assert_true(expected_set[p], ctx .. ": unexpected extra package " .. p)
        end
        for _, banned in ipairs(LEGACY_BANNED_PKGS) do
            assert_true(not actual_set[banned], ctx .. ": contains banned legacy package " .. banned)
        end
    end

    local function assert_no_bare_pacman_S(text, ctx)
        local clean = strip_ansi(text)
        for tok in clean:gmatch("pacman%s+(%-%S+)") do
            if tok:sub(1, 2) == "-S" then
                assert_true(
                    tok:find("y", 3, true) and tok:find("u", 3, true),
                    ctx .. ": forbidden bare/partial pacman sync flag '" .. tok .. "' (must be -Syu)"
                )
            end
        end
    end

    local function assert_no_mutating_calls(calls_str, ctx)
        for _, line in ipairs(split_lines(calls_str)) do
            if line ~= "" and not line:find("^PACMAN %-Q") then
                error(ctx .. ": unexpected mutating external call: " .. line, 2)
            end
        end
    end

    -- =========================================================================
    -- Bootstrap local bare git repository fixture builder
    -- =========================================================================

    local function create_mock_kaze_repo(base_dir)
        local bare = base_dir .. "/kaze-dots.git"
        local work = base_dir .. "/kaze-work"
        mkdir_p_many({ bare, work, work .. "/scripts", work .. "/hypr" })

        local git_env = "GIT_AUTHOR_NAME=Tester GIT_AUTHOR_EMAIL=t@example.com "
            .. "GIT_COMMITTER_NAME=Tester GIT_COMMITTER_EMAIL=t@example.com "

        assert_eq(exec_sh(sh_quote(REAL_GIT) .. " init --bare -b main -- " .. sh_quote(bare) .. " >/dev/null 2>&1"), 0, "git init bare")
        assert_eq(exec_sh(sh_quote(REAL_GIT) .. " init -b main -- " .. sh_quote(work) .. " >/dev/null 2>&1"), 0, "git init work")

        write_file(work .. "/hypr/hyprland.lua", "-- mock hyprland v1\n")
        write_file(work .. "/VERSION", "v1\n")
        write_file(work .. "/scripts/install.sh", [=[#!/usr/bin/env bash
set -euo pipefail
SPY="${KAZE_BB_INSTALL_SPY:-}"
if [ -n "$SPY" ]; then
    {
        printf 'PWD=%s\n' "$(pwd)"
        printf 'VERSION=%s\n' "$(cat "$(dirname "$0")/../VERSION" 2>/dev/null || echo unknown)"
        printf 'ARGC=%d\n' "$#"
        i=1
        for a in "$@"; do
            printf 'ARG%d=%s\n' "$i" "$a"
            i=$((i + 1))
        done
    } > "$SPY"
fi
echo "MOCK_INSTALL_EXECUTED:$#"
exit 0
]=])
        exec_sh("chmod +x -- " .. sh_quote(work .. "/scripts/install.sh"))

        local rc = exec_sh(
            "cd " .. sh_quote(work) .. " && "
            .. git_env .. sh_quote(REAL_GIT) .. " add -A && "
            .. git_env .. sh_quote(REAL_GIT) .. " commit -m 'v1' >/dev/null 2>&1 && "
            .. git_env .. sh_quote(REAL_GIT) .. " tag v1.0.0 && "
            .. sh_quote(REAL_GIT) .. " remote add origin " .. sh_quote("file://" .. bare) .. " && "
            .. sh_quote(REAL_GIT) .. " push -u origin main --tags >/dev/null 2>&1"
        )
        assert_eq(rc, 0, "push v1 to bare repo")

        write_file(work .. "/VERSION", "v2\n")
        rc = exec_sh(
            "cd " .. sh_quote(work) .. " && "
            .. git_env .. sh_quote(REAL_GIT) .. " add VERSION && "
            .. git_env .. sh_quote(REAL_GIT) .. " commit -m 'v2' >/dev/null 2>&1 && "
            .. sh_quote(REAL_GIT) .. " push origin main >/dev/null 2>&1"
        )
        assert_eq(rc, 0, "push v2 to bare repo")

        return "file://" .. bare, bare
    end

    -- =========================================================================
    -- Build shared safe_bin and run all black-box tests inside cleanup pcall
    -- =========================================================================

    build_safe_bin()

    local suite_ok, suite_err = pcall(function()

        -- =====================================================================
        -- DOMAIN 1: Package Manifest & scripts/install-packages.sh Contract
        -- =====================================================================

        test("bb.pkg.cli_invalid_flags_exit_2", function()
            with_sandbox({}, function(sb)
                local bad_cases = {
                    { "--unknown" },
                    { "-x" },
                    { "--profile" },
                    { "--profile=" },
                    { "--profile", "" },
                    { "--profile=invalid" },
                    { "--profile", "standard" },
                    { "--profile", "MINIMAL" },
                    { "--profile", "FULL" },
                    { "extra-positional" },
                    { "--dry-run", "--bogus" },
                    { "--check", "--unknown-flag" },
                }
                for _, args in ipairs(bad_cases) do
                    local argv = { INSTALL_PKGS_SH }
                    for _, a in ipairs(args) do argv[#argv + 1] = a end
                    local r = sb:run(argv)
                    assert_eq(r.rc, 2, "install-packages.sh " .. table.concat(args, " ") .. " should exit 2")
                end
            end)
        end)

        test("bb.pkg.help_flags", function()
            with_sandbox({}, function(sb)
                for _, flag in ipairs({ "-h", "--help" }) do
                    local before = sb:xdg_snapshot()
                    local r = sb:run({ INSTALL_PKGS_SH, flag })
                    assert_eq(r.rc, 0, "install-packages.sh " .. flag .. " exit 0")
                    assert_contains(r.combined, "--profile", "help mentions --profile")
                    assert_contains(r.combined, "--dry-run", "help mentions --dry-run")
                    assert_eq(sb:xdg_snapshot(), before, "help writes zero files")
                end
            end)
        end)

        test("bb.pkg.minimal_manifest_exact_27", function()
            with_sandbox({}, function(sb)
                local variants = {
                    { "--dry-run" },
                    { "--profile", "minimal", "--dry-run" },
                    { "--profile=minimal", "--dry-run" },
                    { "--profile", "minimal", "--check" },
                    { "--profile", "minimal", "--dry-run", "--yes" },
                    { "--profile", "minimal", "--dry-run", "-y" },
                }
                for _, args in ipairs(variants) do
                    local before = sb:xdg_snapshot()
                    local argv = { INSTALL_PKGS_SH }
                    for _, a in ipairs(args) do argv[#argv + 1] = a end
                    local r = sb:run(argv)
                    assert_eq(r.rc, 0, "minimal variant exit 0: " .. table.concat(args, " "))
                    assert_eq(sb:xdg_snapshot(), before, "dry-run/check writes zero files")
                    assert_no_bare_pacman_S(r.combined, "minimal dry-run " .. table.concat(args, " "))
                    assert_contains(r.combined, "pacman -Syu --needed", "must use pacman -Syu --needed")
                    local pkgs = extract_pacman_pkgs_from_text(r.combined)
                    assert_pkg_set_eq(pkgs, MINIMAL_PKGS, "install-packages minimal " .. table.concat(args, " "))
                    if args[#args] == "--yes" or args[#args] == "-y" then
                        assert_contains(r.combined, "--noconfirm", "--yes/-y adds --noconfirm")
                    else
                        assert_true(not r.combined:find("--noconfirm", 1, true), "no --noconfirm without --yes")
                    end
                    assert_no_mutating_calls(sb:calls(), "dry-run must execute zero mutating commands")
                end

                local r = sb:run({ INSTALL_PKGS_SH, "--profile", "minimal", "--yes" })
                assert_eq(r.rc, 0, "live minimal --yes exit 0: " .. r.combined)
                local pkgs, flags, line = extract_pacman_syu_from_calls(sb:call_lines())
                assert_true(line ~= nil, "live run invoked pacman -Syu")
                assert_true(flags["--needed"], "live run passed --needed")
                assert_true(flags["--noconfirm"], "live --yes passed --noconfirm")
                assert_contains(sb:calls(), "SUDO pacman -Syu", "pacman invoked via sudo")
                assert_pkg_set_eq(pkgs, MINIMAL_PKGS, "live minimal pacman argv")
            end)
        end)

        test("bb.pkg.full_manifest_exact_51", function()
            with_sandbox({}, function(sb)
                for _, args in ipairs({
                    { "--profile", "full", "--dry-run" },
                    { "--profile=full", "--dry-run" },
                }) do
                    local argv = { INSTALL_PKGS_SH }
                    for _, a in ipairs(args) do argv[#argv + 1] = a end
                    local r = sb:run(argv)
                    assert_eq(r.rc, 0, "full dry-run exit 0")
                    assert_no_bare_pacman_S(r.combined, "full dry-run")
                    assert_contains(r.combined, "pacman -Syu --needed", "full dry-run uses -Syu --needed")
                    local pkgs = extract_pacman_pkgs_from_text(r.combined)
                    assert_pkg_set_eq(pkgs, FULL_PKGS, "install-packages full dry-run")
                end

                local r = sb:run({ INSTALL_PKGS_SH, "--profile", "full" })
                assert_eq(r.rc, 0, "live full exit 0: " .. r.combined)
                local pkgs, flags, line = extract_pacman_syu_from_calls(sb:call_lines())
                assert_true(line ~= nil, "live full invoked pacman -Syu")
                assert_true(flags["--needed"], "live full passed --needed")
                assert_true(not flags["--noconfirm"], "live full without --yes must NOT pass --noconfirm")
                assert_pkg_set_eq(pkgs, FULL_PKGS, "live full pacman argv")
            end)
        end)

        test("bb.pkg.parity_with_install_sh", function()
            with_sandbox({}, function(sb)
                for _, prof in ipairs({ "minimal", "full" }) do
                    local expected = prof == "minimal" and MINIMAL_PKGS or FULL_PKGS
                    local r_pkg = sb:run({ INSTALL_PKGS_SH, "--profile", prof, "--dry-run" })
                    local r_ins_none = sb:run({ INSTALL_SH, "--profile", prof, "--dm", "none", "--dry-run" })
                    local r_ins_def = sb:run({ INSTALL_SH, "--profile", prof, "--dry-run" })
                    assert_eq(r_pkg.rc, 0, "install-packages dry-run " .. prof)
                    assert_eq(r_ins_none.rc, 0, "install.sh --dm none dry-run " .. prof)
                    assert_eq(r_ins_def.rc, 0, "install.sh default dry-run " .. prof)
                    local p1 = extract_pacman_pkgs_from_text(r_pkg.combined)
                    local p2 = extract_pacman_pkgs_from_text(r_ins_none.combined)
                    local p_def = extract_pacman_pkgs_from_text(r_ins_def.combined)
                    local expected_def = {}
                    for i = 1, #expected do expected_def[#expected_def + 1] = expected[i] end
                    expected_def[#expected_def + 1] = "greetd"
                    expected_def[#expected_def + 1] = "noctalia-greeter"
                    assert_pkg_set_eq(p1, expected, "install-packages " .. prof)
                    assert_pkg_set_eq(p2, expected, "install.sh --dm none " .. prof)
                    assert_eq(#p1, #p2, "exact count parity for " .. prof)
                    assert_pkg_set_eq(p_def, expected_def, "install.sh default includes greetd + noctalia-greeter for " .. prof)
                    assert_contains(r_ins_def.combined, "Display manager: noctalia", "default DM is noctalia for " .. prof)
                end
            end)

            -- Also verify live install.sh passes exact 55 pkgs for full + greetd + paru-bin
            with_sandbox({}, function(sb)
                local r = sb:run({
                    INSTALL_SH, "--profile", "full", "--dm", "greetd", "--aur", "paru-bin",
                    "--yes", "--skip-system-setup", "--no-zsh", "--no-log",
                })
                assert_eq(r.rc, 0, "live full+greetd+paru-bin exit 0: " .. r.combined)
                local pkgs, flags = extract_pacman_syu_from_calls(sb:call_lines())
                assert_true(flags and flags["--needed"] and flags["--noconfirm"], "live pacman flags")
                local expected = {}
                for i = 1, #FULL_PKGS do expected[#expected + 1] = FULL_PKGS[i] end
                expected[#expected + 1] = "greetd"
                expected[#expected + 1] = "greetd-tuigreet"
                expected[#expected + 1] = "base-devel"
                expected[#expected + 1] = "git"
                assert_pkg_set_eq(pkgs, expected, "live install.sh full+greetd+paru-bin pacman argv")
            end)
        end)

        test("bb.pkg.non_arch_fails", function()
            with_sandbox({ arch = false, no_pacman = true }, function(sb)
                local r = sb:run({ INSTALL_PKGS_SH, "--profile", "minimal", "--yes" })
                assert_true(r.rc ~= 0, "live install-packages.sh without pacman must fail")
            end)
        end)

        test("bb.pkg.posix_sh_reexec", function()
            with_sandbox({}, function(sb)
                local r1 = sb:run({ "/bin/sh", INSTALL_PKGS_SH, "--dry-run" })
                assert_eq(r1.rc, 0, "sh scripts/install-packages.sh --dry-run exit 0: " .. r1.combined)

                local r2 = sb:run({ "/bin/sh", INSTALL_SH, "--dry-run" })
                assert_eq(r2.rc, 0, "sh scripts/install.sh --dry-run exit 0: " .. r2.combined)

                local r3 = sb:run({ "/bin/sh", BOOTSTRAP_SH, "--dry-run", "--dir", sb.root .. "/bs-target" })
                assert_eq(r3.rc, 0, "sh scripts/bootstrap.sh --dry-run exit 0: " .. r3.combined)
            end)
        end)

        -- =====================================================================
        -- DOMAIN 2: scripts/install.sh CLI Flags, Validation, Styles & --dry-run
        -- =====================================================================

        test("bb.cli.invalid_flags_and_enums_exit_2", function()
            with_sandbox({}, function(sb)
                local bad_cases = {
                    { "--profile" },
                    { "--style" },
                    { "--dm" },
                    { "--aur" },
                    { "--profile=" },
                    { "--style=" },
                    { "--dm=" },
                    { "--aur=" },
                    { "--profile", "" },
                    { "--style", "" },
                    { "--dm", "" },
                    { "--aur", "" },
                    { "--profile", "standard" },
                    { "--profile", "FULL" },
                    { "--profile=minimal-plus" },
                    { "--style", "nonexistent" },
                    { "--style=default" },
                    { "--style", "foo;bar" },
                    { "--dm", "sddm" },
                    { "--dm", "auto" },
                    { "--dm", "NOCTALIA" },
                    { "--dm", "gdm" },
                    { "--dm=lightdm" },
                    { "--dm", "LY" },
                    { "--aur", "yay" },
                    { "--aur", "paru" },
                    { "--aur=aura" },
                    { "--unknown-flag" },
                    { "-z" },
                    { "unexpected-positional" },
                }
                for _, args in ipairs(bad_cases) do
                    local argv = { INSTALL_SH }
                    for _, a in ipairs(args) do argv[#argv + 1] = a end
                    local r = sb:run(argv)
                    assert_eq(r.rc, 2, "install.sh " .. table.concat(args, " ") .. " expected exit 2, got " .. r.rc .. "\n" .. r.combined)
                end
            end)
        end)

        test("bb.cli.tui_on_non_tty_exit_2", function()
            with_sandbox({}, function(sb)
                local r1 = sb:run({ INSTALL_SH, "--tui" })
                assert_eq(r1.rc, 2, "--tui on non-TTY must exit 2: " .. r1.combined)

                local r2 = sb:run({ INSTALL_SH, "--tui", "--no-tui", "--dry-run" })
                assert_eq(r2.rc, 0, "--tui --no-tui --dry-run should exit 0: " .. r2.combined)
            end)
        end)

        test("bb.cli.help_flags", function()
            with_sandbox({}, function(sb)
                for _, flag in ipairs({ "-h", "--help" }) do
                    local before = sb:xdg_snapshot()
                    local r = sb:run({ INSTALL_SH, flag })
                    assert_eq(r.rc, 0, "install.sh " .. flag .. " exit 0")
                    assert_contains(r.combined, "--profile", "help mentions --profile")
                    assert_contains(r.combined, "--style", "help mentions --style")
                    assert_contains(r.combined, "--dm", "help mentions --dm")
                    assert_contains(r.combined, "--aur", "help mentions --aur")
                    assert_eq(sb:xdg_snapshot(), before, "help writes zero files")
                end
            end)
        end)

        test("bb.cli.style_matrix_27_presets_and_aliases", function()
            with_sandbox({}, function(sb)
                local before = sb:xdg_snapshot()

                local r_def = sb:run({ INSTALL_SH, "--dry-run" })
                assert_eq(r_def.rc, 0, "default dry-run exit 0")
                assert_contains(r_def.combined, "dynamic-island", "default style resolves to dynamic-island")

                local cases = {}
                for _, c in ipairs(CANONICAL_STYLES) do
                    cases[#cases + 1] = { input = c, canonical = c }
                end
                for _, alias in ipairs(sorted_keys(STYLE_ALIASES)) do
                    cases[#cases + 1] = { input = alias, canonical = STYLE_ALIASES[alias] }
                end

                for _, tc in ipairs(cases) do
                    local r1 = sb:run({ INSTALL_SH, "--style", tc.input, "--dry-run" })
                    assert_eq(r1.rc, 0, "--style " .. tc.input .. " exit 0: " .. r1.combined)
                    assert_contains(r1.combined, tc.canonical, "--style " .. tc.input .. " resolves to " .. tc.canonical)

                    local r2 = sb:run({ INSTALL_SH, "--style=" .. tc.input, "--dry-run" })
                    assert_eq(r2.rc, 0, "--style=" .. tc.input .. " exit 0: " .. r2.combined)
                    assert_contains(r2.combined, tc.canonical, "--style=" .. tc.input .. " resolves to " .. tc.canonical)
                end

                assert_eq(sb:xdg_snapshot(), before, "55 dry-run invocations wrote zero files")
            end)
        end)

        test("bb.cli.dry_run_cartesian_18_matrix", function()
            with_sandbox({ skip_xdg_mkdir = true }, function(sb)
                local before = sb:xdg_snapshot()
                local profiles = { "minimal", "full" }
                local dms = { "none", "noctalia", "ly", "greetd" }
                local aurs = { "none", "yay-bin", "paru-bin" }

                for _, prof in ipairs(profiles) do
                    local base_pkgs = prof == "minimal" and MINIMAL_PKGS or FULL_PKGS
                    for _, dm in ipairs(dms) do
                        for _, aur in ipairs(aurs) do
                            local ctx = string.format("profile=%s dm=%s aur=%s", prof, dm, aur)
                            local r = sb:run({
                                INSTALL_SH,
                                "--profile=" .. prof,
                                "--dm=" .. dm,
                                "--aur=" .. aur,
                                "--dry-run",
                            })
                            assert_eq(r.rc, 0, ctx .. " exit 0: " .. r.combined)
                            assert_no_bare_pacman_S(r.combined, ctx)
                            assert_contains(r.combined, prof, ctx .. " mentions profile")
                            assert_contains(r.combined, "pacman -Syu --needed", ctx .. " prints pacman -Syu --needed")
                            assert_contains(r.combined, "install-", ctx .. " mentions install log path")

                            local expected = {}
                            for i = 1, #base_pkgs do expected[#expected + 1] = base_pkgs[i] end
                            if dm == "noctalia" then
                                expected[#expected + 1] = "greetd"
                                expected[#expected + 1] = "noctalia-greeter"
                            elseif dm == "ly" then
                                expected[#expected + 1] = "ly"
                            elseif dm == "greetd" then
                                expected[#expected + 1] = "greetd"
                                expected[#expected + 1] = "greetd-tuigreet"
                            end
                            if aur ~= "none" then
                                expected[#expected + 1] = "base-devel"
                                expected[#expected + 1] = "git"
                            end

                            local actual_pkgs = extract_pacman_pkgs_from_text(r.combined)
                            assert_pkg_set_eq(actual_pkgs, expected, ctx)
                        end
                    end
                end

                assert_eq(sb:xdg_snapshot(), before, "18-way dry-run cartesian matrix created ZERO files/dirs")
                assert_no_mutating_calls(sb:calls(), "dry-run invoked ZERO mutating commands (only read-only pacman -Qq allowed)")
            end)
        end)

        test("bb.cli.smart_defaults_and_overrides", function()
            -- Smart defaults with --skip-packages (SYSTEM_SETUP=false, SET_ZSH=false)
            with_sandbox({}, function(sb)
                local r_def = sb:run({ INSTALL_SH, "--dry-run" })
                assert_eq(r_def.rc, 0, "default dry-run")
                assert_contains(r_def.combined, "pacman -Syu --needed", "default runs pacman")

                local r_skip = sb:run({ INSTALL_SH, "--skip-packages", "--dry-run" })
                assert_eq(r_skip.rc, 0, "--skip-packages --dry-run")
                assert_true(not r_skip.combined:find("sudo pacman -Syu", 1, true), "--skip-packages skips pacman")

                sb:clear_calls()
                local r_live_skip = sb:run({ INSTALL_SH, "--skip-packages", "--yes", "--no-log" })
                assert_eq(r_live_skip.rc, 0, "live --skip-packages exit 0: " .. r_live_skip.combined)
                assert_no_mutating_calls(sb:calls(), "live --skip-packages defaults SYSTEM_SETUP=false & SET_ZSH=false (zero mutating calls)")
            end)

            -- --skip-packages + explicit --system-setup overrides SYSTEM_SETUP=true while keeping SET_ZSH=false
            with_sandbox({}, function(sb)
                local r = sb:run({ INSTALL_SH, "--skip-packages", "--system-setup", "--yes", "--no-log" })
                assert_eq(r.rc, 0, "--skip-packages --system-setup exit 0: " .. r.combined)
                assert_true(not sb:calls():find("PACMAN -S", 1, true), "pacman sync still skipped")
                assert_contains(sb:calls(), "SYSTEMCTL enable NetworkManager.service", "explicit --system-setup runs system setup")
                assert_true(not sb:calls():find("CHSH", 1, true), "SET_ZSH remains false under --skip-packages")
            end)

            -- Default Arch live run (no --skip-packages): SYSTEM_SETUP=true, SET_ZSH=true, AND DM=noctalia
            with_sandbox({
                login_shell = "/usr/bin/bash",
                units_exist = { "greetd.service", "NetworkManager.service", "bluetooth.service" },
            }, function(sb)
                local r = sb:run({ INSTALL_SH, "--yes", "--no-log" })
                assert_eq(r.rc, 0, "default Arch live run exit 0: " .. r.combined)
                assert_contains(sb:calls(), "PACMAN -Syu", "default Arch runs pacman -Syu")
                assert_contains(sb:calls(), "SYSTEMCTL enable NetworkManager.service", "default Arch enables system setup")
                assert_contains(sb:calls(), "SYSTEMCTL enable greetd.service", "default Arch enables greetd.service for noctalia-greeter")
                assert_contains(sb:calls(), "CHSH", "default Arch switches login shell to zsh")
                assert_contains(read_file(sb.greetd_cfg) or "", "/usr/bin/noctalia-greeter-session --session Hyprland", "writes noctalia-greeter greetd config")
                assert_contains(read_file(sb.greeter_dir .. "/sync.toml") or "", 'scheme = "Tokyo-Night"', "seeds Tokyo-Night greeter theme")
                assert_contains(read_file(sb.greeter_dir .. "/greeter.toml") or "", 'default = "Hyprland"', "seeds Hyprland default greeter session")
            end)

            -- VM GPU mode adds WLR_NO_HARDWARE_CURSORS=1 automatically to noctalia-greeter command
            with_sandbox({
                drm_cards = { { name = "card0", vendor = "0x1af4" } },
                units_exist = { "greetd.service" },
            }, function(sb)
                local r = sb:run({ INSTALL_SH, "--skip-packages", "--dm", "noctalia", "--yes", "--no-log" })
                assert_eq(r.rc, 0, "noctalia DM on VM GPU exit 0: " .. r.combined)
                assert_contains(read_file(sb.greetd_cfg) or "", "WLR_NO_HARDWARE_CURSORS=1", "VM mode sets WLR_NO_HARDWARE_CURSORS=1")
            end)

            -- Already using zsh -> idempotent (no chsh call); --no-zsh skips chsh
            with_sandbox({ login_shell = "mock_zsh" }, function(sb)
                local r = sb:run({ INSTALL_SH, "--yes", "--skip-system-setup", "--no-log" })
                assert_eq(r.rc, 0, "already-zsh live run exit 0")
                assert_true(not sb:calls():find("CHSH", 1, true), "skips chsh when shell is already zsh")
            end)

            -- Flag overrides & --check / --yes / -y / --no-log
            with_sandbox({ skip_xdg_mkdir = true }, function(sb)
                local before = sb:xdg_snapshot()
                local r_chk = sb:run({ INSTALL_SH, "--check", "--yes", "--no-log" })
                assert_eq(r_chk.rc, 0, "--check --yes --no-log exit 0")
                assert_contains(r_chk.combined, "--noconfirm", "--yes adds --noconfirm")

                local r_y = sb:run({ INSTALL_SH, "--dry-run", "-y" })
                assert_eq(r_y.rc, 0, "-y dry-run exit 0")
                assert_contains(r_y.combined, "--noconfirm", "-y adds --noconfirm")

                -- Contradictory flags: last wins cleanly
                local r_ov = sb:run({
                    INSTALL_SH, "--profile", "full", "--profile", "minimal",
                    "--dm", "greetd", "--dm", "none",
                    "--aur", "yay-bin", "--aur", "none",
                    "--reboot", "--no-reboot", "--dry-run",
                })
                assert_eq(r_ov.rc, 0, "contradictory flags resolved cleanly")
                assert_pkg_set_eq(extract_pacman_pkgs_from_text(r_ov.combined), MINIMAL_PKGS, "last-wins overrides")
                assert_eq(sb:xdg_snapshot(), before, "dry-run/check flags wrote zero files")
            end)
        end)

        -- =====================================================================
        -- DOMAIN 3: Stage 0 Bootstrap (scripts/bootstrap.sh)
        -- =====================================================================

        test("bb.bootstrap.missing_args_exit_2", function()
            with_sandbox({ git_mode = "real" }, function(sb)
                for _, flag in ipairs({ "--dir", "--repo", "--branch" }) do
                    local r = sb:run({ BOOTSTRAP_SH, flag })
                    assert_eq(r.rc, 2, "bootstrap.sh " .. flag .. " missing arg must exit 2")
                end
                for _, flag in ipairs({ "-h", "--help" }) do
                    local r = sb:run({ BOOTSTRAP_SH, flag })
                    assert_eq(r.rc, 0, "bootstrap.sh " .. flag .. " exit 0")
                end
            end)
        end)

        test("bb.bootstrap.dry_run_zero_writes_and_forwarding", function()
            with_sandbox({ git_mode = "real" }, function(sb)
                local target = sb.root .. "/fresh-target"
                local r = sb:run({
                    BOOTSTRAP_SH,
                    "--dry-run",
                    "--dir=" .. target,
                    "--repo=https://example.invalid/kaze-dots.git",
                    "--branch=dev",
                    "--profile", "full",
                    "--",
                    "--dir", "/forwarded-dir",
                    "--style", "glass",
                })
                assert_eq(r.rc, 0, "bootstrap --dry-run exit 0: " .. r.combined)
                assert_true(not path_exists(target), "bootstrap --dry-run creates ZERO target dirs")
                assert_contains(r.combined, target, "prints target dir")
                assert_contains(r.combined, "https://example.invalid/kaze-dots.git", "prints repo")
                assert_contains(r.combined, "dev", "prints branch")
                assert_contains(r.combined, "--profile", "forwards unrecognized option")
                assert_contains(r.combined, "--dir", "forwards --dir after --")
                assert_contains(r.combined, "/forwarded-dir", "forwards arg after --")
                assert_true(
                    not r.combined:find("install.sh -- ", 1, true),
                    "must NOT forward literal -- to install.sh:\n" .. r.combined
                )

                local target_env = sb.root .. "/env-target"
                local r2 = sb:run({ BOOTSTRAP_SH, "--check" }, {
                    env = {
                        KAZE_INSTALL_DIR = target_env,
                        KAZE_BOOTSTRAP_REPO = "https://env.invalid/kaze.git",
                        KAZE_BOOTSTRAP_BRANCH = "release",
                    },
                })
                assert_eq(r2.rc, 0, "bootstrap --check with env overrides exit 0")
                assert_true(not path_exists(target_env), "--check creates ZERO dirs")
                assert_contains(r2.combined, target_env, "honors KAZE_INSTALL_DIR")
                assert_contains(r2.combined, "https://env.invalid/kaze.git", "honors KAZE_BOOTSTRAP_REPO")
                assert_contains(r2.combined, "release", "honors KAZE_BOOTSTRAP_BRANCH")
            end)
        end)

        test("bb.bootstrap.target_safety_matrix", function()
            with_sandbox({ git_mode = "real" }, function(sb)
                local repo_url = create_mock_kaze_repo(sb.root)
                local git_env = "GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@e.com GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@e.com "

                local function assert_refused(name, target)
                    local r_dry = sb:run({
                        BOOTSTRAP_SH, "--dry-run", "--dir", target, "--repo", repo_url, "--branch", "main",
                    }, { env = { KAZE_SKIP_NET_CHECK = "1" } })
                    assert_true(r_dry.rc ~= 0, name .. " must fail in --dry-run: " .. r_dry.combined)

                    local r_live = sb:run({
                        BOOTSTRAP_SH, "--dir", target, "--repo", repo_url, "--branch", "main",
                    }, { env = { KAZE_SKIP_NET_CHECK = "1" } })
                    assert_true(r_live.rc ~= 0, name .. " must fail in live mode: " .. r_live.combined)
                end

                -- 1. Regular file at target
                local t_file = sb.root .. "/target_file"
                write_file(t_file, "SENTINEL_FILE\n")
                assert_refused("regular file target", t_file)
                assert_eq(read_file(t_file), "SENTINEL_FILE\n", "regular file left intact")

                -- 2. Non-git directory
                local t_dir = sb.root .. "/target_nongit"
                mkdir_p(t_dir)
                write_file(t_dir .. "/keep.txt", "DO_NOT_DELETE\n")
                assert_refused("non-git directory", t_dir)
                assert_eq(read_file(t_dir .. "/keep.txt"), "DO_NOT_DELETE\n", "non-git dir contents intact")

                -- 3. Foreign git repo (different origin, missing scripts/install.sh & hypr/hyprland.lua)
                local t_foreign = sb.root .. "/target_foreign"
                mkdir_p(t_foreign)
                assert_eq(exec_sh(
                    "cd " .. sh_quote(t_foreign) .. " && "
                    .. sh_quote(REAL_GIT) .. " init -b main >/dev/null 2>&1 && "
                    .. sh_quote(REAL_GIT) .. " remote add origin https://example.com/other-project.git && "
                    .. "echo hi > README.md && "
                    .. git_env .. sh_quote(REAL_GIT) .. " add README.md && "
                    .. git_env .. sh_quote(REAL_GIT) .. " commit -m init >/dev/null 2>&1"
                ), 0, "create foreign repo")
                assert_refused("foreign git repo", t_foreign)
                assert_eq(read_file(t_foreign .. "/README.md"), "hi\n", "foreign repo intact")

                -- 4. Foreign git repo with NO origin remote
                local t_noremote = sb.root .. "/target_noremote"
                mkdir_p(t_noremote)
                assert_eq(exec_sh(
                    "cd " .. sh_quote(t_noremote) .. " && "
                    .. sh_quote(REAL_GIT) .. " init -b main >/dev/null 2>&1 && "
                    .. "echo solo > FILE && "
                    .. git_env .. sh_quote(REAL_GIT) .. " add FILE && "
                    .. git_env .. sh_quote(REAL_GIT) .. " commit -m init >/dev/null 2>&1"
                ), 0, "create no-remote repo")
                assert_refused("git repo without origin", t_noremote)

                -- 5. Dirty kaze-dots repo (modified tracked file)
                local t_mod = sb.root .. "/target_dirty_mod"
                assert_eq(exec_sh(sh_quote(REAL_GIT) .. " clone -q " .. sh_quote(repo_url) .. " " .. sh_quote(t_mod)), 0)
                write_file(t_mod .. "/hypr/hyprland.lua", "-- local edit\n")
                assert_refused("dirty modified tracked file", t_mod)
                assert_eq(read_file(t_mod .. "/hypr/hyprland.lua"), "-- local edit\n", "modified file preserved")

                -- 6. Dirty kaze-dots repo (untracked file)
                local t_untracked = sb.root .. "/target_dirty_untracked"
                assert_eq(exec_sh(sh_quote(REAL_GIT) .. " clone -q " .. sh_quote(repo_url) .. " " .. sh_quote(t_untracked)), 0)
                write_file(t_untracked .. "/local_notes.txt", "untracked\n")
                assert_refused("dirty untracked file", t_untracked)
                assert_eq(read_file(t_untracked .. "/local_notes.txt"), "untracked\n", "untracked file preserved")

                -- 7. Diverged local branch (cannot --ff-only)
                local t_div = sb.root .. "/target_diverged"
                assert_eq(exec_sh(
                    sh_quote(REAL_GIT) .. " clone -q " .. sh_quote(repo_url) .. " " .. sh_quote(t_div) .. " && "
                    .. "cd " .. sh_quote(t_div) .. " && "
                    .. sh_quote(REAL_GIT) .. " reset --hard v1.0.0 >/dev/null 2>&1 && "
                    .. "echo local > LOCAL_ONLY && "
                    .. git_env .. sh_quote(REAL_GIT) .. " add LOCAL_ONLY && "
                    .. git_env .. sh_quote(REAL_GIT) .. " commit -m 'local diverge' >/dev/null 2>&1"
                ), 0, "create diverged repo")
                local r_div = sb:run({
                    BOOTSTRAP_SH, "--dir", t_div, "--repo", repo_url, "--branch", "main",
                }, { env = { KAZE_SKIP_NET_CHECK = "1" } })
                assert_true(r_div.rc ~= 0, "diverged branch must refuse safely: " .. r_div.combined)
                assert_eq(read_file(t_div .. "/LOCAL_ONLY"), "local\n", "diverged local commit preserved")
            end)
        end)

        test("bb.bootstrap.clean_update_states", function()
            with_sandbox({ git_mode = "real" }, function(sb)
                local repo_url = create_mock_kaze_repo(sb.root)
                local spy = sb.root .. "/spy.txt"

                -- Case 1: Clean repo on main behind upstream -> fast-forwards to v2
                local t1 = sb.root .. "/clean_behind"
                assert_eq(exec_sh(
                    sh_quote(REAL_GIT) .. " clone -q " .. sh_quote(repo_url) .. " " .. sh_quote(t1) .. " && "
                    .. "cd " .. sh_quote(t1) .. " && " .. sh_quote(REAL_GIT) .. " reset --hard v1.0.0 >/dev/null 2>&1"
                ), 0)
                local r1 = sb:run({
                    BOOTSTRAP_SH, "--dir", t1, "--repo", repo_url, "--branch", "main", "--profile", "full",
                }, { env = { KAZE_SKIP_NET_CHECK = "1", KAZE_BB_INSTALL_SPY = spy } })
                assert_eq(r1.rc, 0, "clean behind ff-only exit 0: " .. r1.combined)
                assert_eq(trim(read_file(t1 .. "/VERSION")), "v2", "fast-forwarded to v2")
                assert_contains(read_file(spy) or "", "VERSION=v2", "executed updated install.sh")
                assert_contains(read_file(spy) or "", "ARG1=--profile", "forwarded args")

                -- Case 2: Clean repo on different local branch -> switches to main and fast-forwards
                local t2 = sb.root .. "/clean_other_branch"
                assert_eq(exec_sh(
                    sh_quote(REAL_GIT) .. " clone -q " .. sh_quote(repo_url) .. " " .. sh_quote(t2) .. " && "
                    .. "cd " .. sh_quote(t2) .. " && "
                    .. sh_quote(REAL_GIT) .. " reset --hard v1.0.0 >/dev/null 2>&1 && "
                    .. sh_quote(REAL_GIT) .. " checkout -q -b other-branch"
                ), 0)
                local r2 = sb:run({
                    BOOTSTRAP_SH, "--dir", t2, "--repo", repo_url, "--branch", "main",
                }, { env = { KAZE_SKIP_NET_CHECK = "1", KAZE_BB_INSTALL_SPY = spy } })
                assert_eq(r2.rc, 0, "switch branch & ff exit 0: " .. r2.combined)
                assert_eq(trim(read_file(t2 .. "/VERSION")), "v2", "switched to main and fast-forwarded to v2")
                local cur_br = trim(capture_sh(sh_quote(REAL_GIT) .. " -C " .. sh_quote(t2) .. " rev-parse --abbrev-ref HEAD"))
                assert_eq(cur_br, "main", "HEAD is now on main")

                -- Case 3: Clean repo targeting tag v1.0.0 -> detaches cleanly to FETCH_HEAD at v1
                local t3 = sb.root .. "/clean_tag"
                assert_eq(exec_sh(sh_quote(REAL_GIT) .. " clone -q " .. sh_quote(repo_url) .. " " .. sh_quote(t3)), 0)
                local r3 = sb:run({
                    BOOTSTRAP_SH, "--dir", t3, "--repo", repo_url, "--branch", "v1.0.0",
                }, { env = { KAZE_SKIP_NET_CHECK = "1", KAZE_BB_INSTALL_SPY = spy } })
                assert_eq(r3.rc, 0, "tag checkout exit 0: " .. r3.combined)
                assert_eq(trim(read_file(t3 .. "/VERSION")), "v1", "detached to v1.0.0 tag")
                local head_ref = trim(capture_sh(sh_quote(REAL_GIT) .. " -C " .. sh_quote(t3) .. " rev-parse --abbrev-ref HEAD"))
                assert_eq(head_ref, "HEAD", "tag results in detached HEAD")
            end)
        end)

        test("bb.bootstrap.live_prereq_guards", function()
            with_sandbox({ arch = false, git_mode = "real" }, function(sb)
                local target = sb.root .. "/t"
                local r = sb:run({ BOOTSTRAP_SH, "--dir", target, "--repo", "file:///nope" }, {
                    env = { KAZE_SKIP_NET_CHECK = "1" },
                })
                assert_true(r.rc ~= 0, "non-Arch must fail")
                assert_true(not path_exists(target), "non-Arch must not create target")
            end)

            with_sandbox({ no_pacman = true, git_mode = "real" }, function(sb)
                local target = sb.root .. "/t"
                local r = sb:run({ BOOTSTRAP_SH, "--dir", target, "--repo", "file:///nope" }, {
                    env = { KAZE_SKIP_NET_CHECK = "1" },
                })
                assert_true(r.rc ~= 0, "missing pacman must fail")
                assert_true(not path_exists(target), "missing pacman must not create target")
            end)

            with_sandbox({ git_mode = "absent", curl_rc = 6 }, function(sb)
                local target = sb.root .. "/t"
                local r = sb:run({ BOOTSTRAP_SH, "--dir", target, "--repo", "https://example.invalid/kaze.git" }, {
                    env = { KAZE_SKIP_NET_CHECK = "0" },
                })
                assert_true(r.rc ~= 0, "network check failure must fail")
                assert_true(not sb:calls():find("PACMAN", 1, true), "must fail BEFORE calling pacman")
                assert_true(not sb:calls():find("GIT", 1, true), "must fail BEFORE calling git")
                assert_true(not path_exists(target), "must not create target on net fail")
            end)
        end)

        test("bb.bootstrap.missing_git_installs_via_syu", function()
            with_sandbox({ git_mode = "absent", pacman_installs_git = true }, function(sb)
                local repo_url = create_mock_kaze_repo(sb.root)
                local target = sb.root .. "/installed-via-auto-git"
                local spy = sb.root .. "/spy.txt"
                local r = sb:run({
                    BOOTSTRAP_SH, "--dir", target, "--repo", repo_url, "--branch", "main",
                }, { env = { KAZE_SKIP_NET_CHECK = "1", KAZE_BB_INSTALL_SPY = spy } })
                assert_eq(r.rc, 0, "missing git auto-install exit 0: " .. r.combined)
                assert_no_bare_pacman_S(sb:calls(), "bootstrap git install must use -Syu")
                assert_contains(sb:calls(), "PACMAN -Syu --needed", "bootstrap installs git via pacman -Syu --needed")
                assert_contains(sb:calls(), "git", "bootstrap installs git package")
                assert_contains(read_file(spy) or "", "VERSION=v2", "cloned and executed install.sh")
            end)
        end)

        test("bb.bootstrap.piped_stdin_and_spaces_in_dir", function()
            with_sandbox({ git_mode = "real" }, function(sb)
                local repo_url = create_mock_kaze_repo(sb.root)
                local target = sb.root .. "/my kaze dir/with spaces"
                local spy = sb.root .. "/spy.txt"
                local bs_script = read_file(BOOTSTRAP_SH)
                assert_true(bs_script ~= nil and #bs_script > 0, "bootstrap script readable as opaque stdin stream")

                local r = sb:run({
                    "bash", "-s", "--",
                    "--dir", target,
                    "--repo", repo_url,
                    "--branch", "main",
                    "--",
                    "--dir", "/should-forward-not-parse",
                    "--profile", "full",
                }, {
                    stdin = bs_script,
                    env = { KAZE_SKIP_NET_CHECK = "1", KAZE_BB_INSTALL_SPY = spy },
                })
                assert_eq(r.rc, 0, "piped bootstrap with spaces exit 0: " .. r.combined)
                local spy_txt = read_file(spy) or ""
                assert_contains(spy_txt, "VERSION=v2", "piped bootstrap cloned AND executed install.sh")
                assert_contains(spy_txt, "ARGC=4", "exact 4 forwarded args (no literal --):\n" .. spy_txt)
                assert_contains(spy_txt, "ARG1=--dir", "ARG1 is --dir (not --)")
                assert_contains(spy_txt, "ARG2=/should-forward-not-parse", "ARG2 preserved")
                assert_contains(spy_txt, "ARG3=--profile", "ARG3 preserved")
                assert_contains(spy_txt, "ARG4=full", "ARG4 preserved")
            end)
        end)

        -- =====================================================================
        -- DOMAIN 4: GPU Detection & Safe Hybrid Laptop user.lua Seeding
        -- =====================================================================

        test("bb.gpu.classification_22_topology_matrix", function()
            local topologies = {
                -- 8 hybrid-laptop variants
                {
                    name = "hybrid_intel_card0_edp_connected",
                    cards = {
                        { name = "card0", vendor = "0x8086", connectors = { { name = "card0-eDP-1", status = "connected" } } },
                        { name = "card1", vendor = "0x10de" },
                    },
                    expect_mode = "hybrid-laptop",
                    expect_seed_dev = "/dev/dri/card0",
                },
                {
                    name = "hybrid_reversed_nvidia_card0_intel_card1",
                    cards = {
                        { name = "card0", vendor = "0x10de" },
                        { name = "card1", vendor = "0x8086", connectors = { { name = "card1-eDP-1", status = "connected" } } },
                    },
                    expect_mode = "hybrid-laptop",
                    expect_seed_dev = "/dev/dri/card1",
                },
                {
                    name = "hybrid_amd_card1_nvidia_card0",
                    cards = {
                        { name = "card0", vendor = "0x10de" },
                        { name = "card1", vendor = "0x1002", connectors = { { name = "card1-eDP-1", status = "connected" } } },
                    },
                    expect_mode = "hybrid-laptop",
                    expect_seed_dev = "/dev/dri/card1",
                },
                {
                    name = "hybrid_lvds_and_simpledrm_ignored",
                    cards = {
                        { name = "card0", vendor = nil },
                        { name = "card1", vendor = "0x8086", connectors = { { name = "card1-LVDS-1", status = "connected" } } },
                        { name = "card2", vendor = "0x10de" },
                    },
                    expect_mode = "hybrid-laptop",
                    expect_seed_dev = "/dev/dri/card1",
                },
                {
                    name = "hybrid_dsi_unknown_status_not_disconnected",
                    cards = {
                        { name = "card0", vendor = "0x1002", connectors = { { name = "card0-DSI-1", status = "unknown" } } },
                        { name = "card1", vendor = "0x10de" },
                    },
                    expect_mode = "hybrid-laptop",
                    expect_seed_dev = "/dev/dri/card0",
                },
                {
                    name = "hybrid_uppercase_hex_unreadable_status",
                    cards = {
                        { name = "card0", vendor = "0X8086", connectors = { { name = "card0-eDP-2", status = nil } } },
                        { name = "card1", vendor = "0X10DE" },
                    },
                    expect_mode = "hybrid-laptop",
                    expect_seed_dev = "/dev/dri/card0",
                },
                {
                    name = "hybrid_two_edps_one_disconnected_one_connected",
                    cards = {
                        {
                            name = "card0",
                            vendor = "0x8086",
                            connectors = {
                                { name = "card0-eDP-1", status = "disconnected" },
                                { name = "card0-eDP-2", status = "connected" },
                            },
                        },
                        { name = "card1", vendor = "0x10de" },
                    },
                    expect_mode = "hybrid-laptop",
                    expect_seed_dev = "/dev/dri/card0",
                },
                {
                    name = "hybrid_multidigit_card10_igpu_card11_nvidia",
                    cards = {
                        { name = "card10", vendor = "0x8086", connectors = { { name = "card10-eDP-1", status = "connected" } } },
                        { name = "card11", vendor = "0x10de" },
                    },
                    expect_mode = "hybrid-laptop",
                    expect_seed_dev = "/dev/dri/card10",
                },

                -- 3 multi-gpu-desktop variants
                {
                    name = "desktop_amd_nvidia_dp_only",
                    cards = {
                        { name = "card0", vendor = "0x1002", connectors = { { name = "card0-DP-1", status = "connected" } } },
                        { name = "card1", vendor = "0x10de", connectors = { { name = "card1-HDMI-A-1", status = "connected" } } },
                    },
                    expect_mode = "multi-gpu-desktop",
                },
                {
                    name = "desktop_mux_dgpu_only_edp_disconnected",
                    cards = {
                        { name = "card0", vendor = "0x8086", connectors = { { name = "card0-eDP-1", status = "disconnected" } } },
                        { name = "card1", vendor = "0x10de" },
                    },
                    expect_mode = "multi-gpu-desktop",
                },
                {
                    name = "desktop_edp_on_nvidia_not_igpu",
                    cards = {
                        { name = "card0", vendor = "0x8086", connectors = { { name = "card0-HDMI-A-1", status = "connected" } } },
                        { name = "card1", vendor = "0x10de", connectors = { { name = "card1-eDP-1", status = "connected" } } },
                    },
                    expect_mode = "multi-gpu-desktop",
                },

                -- single-nvidia
                {
                    name = "single_nvidia",
                    cards = { { name = "card0", vendor = "0x10de" } },
                    expect_mode = "single-nvidia",
                },

                -- single-igpu (Intel + AMD)
                {
                    name = "single_intel",
                    cards = { { name = "card0", vendor = "0x8086" } },
                    expect_mode = "single-igpu",
                },
                {
                    name = "single_amd",
                    cards = { { name = "card0", vendor = "0x1002" } },
                    expect_mode = "single-igpu",
                },

                -- All 4 VM vendors
                { name = "vm_virtio", cards = { { name = "card0", vendor = "0x1af4" } }, expect_mode = "vm" },
                { name = "vm_qxl", cards = { { name = "card0", vendor = "0x1b36" } }, expect_mode = "vm" },
                { name = "vm_vmware", cards = { { name = "card0", vendor = "0x15ad" } }, expect_mode = "vm" },
                { name = "vm_bochs", cards = { { name = "card0", vendor = "0x1234" } }, expect_mode = "vm" },

                -- 4 unknown variants
                { name = "unknown_missing_dir", missing_drm = true, expect_mode = "unknown" },
                { name = "unknown_empty_dir", cards = {}, expect_mode = "unknown" },
                { name = "unknown_simpledrm_only", cards = { { name = "card0", vendor = nil } }, expect_mode = "unknown" },
                { name = "unknown_unrecognized_vendor", cards = { { name = "card0", vendor = "0x9999" } }, expect_mode = "unknown" },
            }

            assert_eq(#topologies, 22, "exact 22 GPU topology test cases")

            -- Reuse a single sandbox with 22 separate DRM directories for fast brute-force execution
            with_sandbox({}, function(sb)
                for idx, topo in ipairs(topologies) do
                    local drm_path
                    if topo.missing_drm then
                        drm_path = sb.root .. "/no_such_drm_" .. idx
                    else
                        drm_path = sb.root .. "/drm_" .. idx
                        write_drm_layout(drm_path, topo.cards or {})
                    end
                    local r = sb:run({ INSTALL_SH, "--dry-run" }, {
                        env = { KAZE_SYS_DRM_DIR = drm_path },
                    })
                    assert_eq(r.rc, 0, topo.name .. " dry-run exit 0")
                    assert_contains(r.combined, topo.expect_mode, topo.name .. " detected mode " .. topo.expect_mode)
                    if topo.expect_seed_dev then
                        assert_contains(r.combined, topo.expect_seed_dev, topo.name .. " reports seed device")
                    else
                        assert_true(
                            not r.combined:find("/dev/dri/card", 1, true),
                            topo.name .. " must NOT propose seeding /dev/dri/card*:\n" .. r.combined
                        )
                    end
                end
            end)
        end)

        test("bb.gpu.hybrid_seeding_valid_lua", function()
            with_sandbox({
                drm_cards = {
                    { name = "card0", vendor = "0x10de" },
                    { name = "card1", vendor = "0x8086", connectors = { { name = "card1-eDP-1", status = "connected" } } },
                },
            }, function(sb)
                local r = sb:run({ INSTALL_SH, "--skip-packages", "--yes", "--no-log" })
                assert_eq(r.rc, 0, "hybrid live install exit 0: " .. r.combined)

                local user_lua = sb.xdg_config .. "/hypr/user.lua"
                assert_true(is_file(user_lua), "user.lua created on hybrid-laptop")
                assert_eq(exec_sh("luac -p -- " .. sh_quote(user_lua)), 0, "seeded user.lua passes luac -p")

                local chunk, load_err = loadfile(user_lua, "t", {})
                assert_true(chunk ~= nil, "loadfile(user.lua) succeeded: " .. tostring(load_err))
                local cfg = chunk()
                assert_true(type(cfg) == "table", "user.lua returns a table")
                assert_eq(cfg.drm_devices, "/dev/dri/card1", "drm_devices matches iGPU card1")
                assert_eq(cfg.prefer_mesa_egl, true, "prefer_mesa_egl == true")
            end)
        end)

        test("bb.gpu.seeding_never_runs_when_forbidden_and_single_nvidia_warns", function()
            local forbidden_cases = {
                {
                    name = "hybrid_with_no_hybrid_gpu_flag",
                    cards = {
                        { name = "card0", vendor = "0x8086", connectors = { { name = "card0-eDP-1", status = "connected" } } },
                        { name = "card1", vendor = "0x10de" },
                    },
                    extra_args = { "--no-hybrid-gpu" },
                },
                {
                    name = "multi_gpu_desktop",
                    cards = {
                        { name = "card0", vendor = "0x1002", connectors = { { name = "card0-DP-1", status = "connected" } } },
                        { name = "card1", vendor = "0x10de" },
                    },
                },
                {
                    name = "single_nvidia",
                    cards = { { name = "card0", vendor = "0x10de" } },
                    expect_nvidia_warn = true,
                },
                {
                    name = "single_igpu",
                    cards = { { name = "card0", vendor = "0x8086" } },
                },
                {
                    name = "vm",
                    cards = { { name = "card0", vendor = "0x1af4" } },
                },
                {
                    name = "unknown",
                    missing_drm = true,
                },
            }

            local baseline_template = nil
            for _, tc in ipairs(forbidden_cases) do
                with_sandbox({ drm_cards = tc.cards, missing_drm = tc.missing_drm }, function(sb)
                    local argv = { INSTALL_SH, "--skip-packages", "--yes", "--no-log" }
                    if tc.extra_args then
                        for _, a in ipairs(tc.extra_args) do argv[#argv + 1] = a end
                    end
                    local r = sb:run(argv)
                    assert_eq(r.rc, 0, tc.name .. " exit 0: " .. r.combined)

                    if tc.expect_nvidia_warn then
                        assert_contains(r.combined, "nvidia_drm.modeset=1", "single-nvidia live run warns about nvidia_drm.modeset=1")
                        assert_true(
                            r.combined:find("nvidia-open", 1, true) or r.combined:find("nvidia", 1, true),
                            "single-nvidia live run mentions nvidia driver"
                        )
                    end

                    -- If apply.sh copied the default commented user.lua template, verify hybrid seeder NEVER touched it
                    local user_lua = sb.xdg_config .. "/hypr/user.lua"
                    if path_exists(user_lua) then
                        local content = read_file(user_lua)
                        assert_eq(exec_sh("luac -p -- " .. sh_quote(user_lua)), 0, tc.name .. " user.lua valid Lua")
                        local chunk = assert(loadfile(user_lua, "t", {}))
                        local cfg = chunk()
                        assert_true(type(cfg) == "table", tc.name .. " user.lua returns table")
                        assert_eq(cfg.drm_devices, nil, tc.name .. " MUST NOT seed drm_devices")
                        assert_eq(cfg.prefer_mesa_egl, nil, tc.name .. " MUST NOT seed prefer_mesa_egl")
                        if baseline_template == nil then
                            baseline_template = content
                        else
                            assert_eq(content, baseline_template, tc.name .. " user.lua matches untouched default template")
                        end
                    end
                end)
            end
        end)

        test("bb.gpu.existing_user_lua_preserved", function()
            local hybrid_cards = {
                { name = "card0", vendor = "0x8086", connectors = { { name = "card0-eDP-1", status = "connected" } } },
                { name = "card1", vendor = "0x10de" },
            }

            -- 1. Pre-existing regular file
            with_sandbox({ drm_cards = hybrid_cards }, function(sb)
                local user_lua = sb.xdg_config .. "/hypr/user.lua"
                mkdir_p(sb.xdg_config .. "/hypr")
                local orig = "return { custom_sentinel = 'keep-me-123' }\n"
                write_file(user_lua, orig)

                local r = sb:run({ INSTALL_SH, "--skip-packages", "--yes", "--no-log" })
                assert_eq(r.rc, 0, "install with existing regular user.lua exit 0")
                assert_eq(read_file(user_lua), orig, "pre-existing regular user.lua untouched")
            end)

            -- 2. Pre-existing symlink
            with_sandbox({ drm_cards = hybrid_cards }, function(sb)
                local user_lua = sb.xdg_config .. "/hypr/user.lua"
                local target = sb.root .. "/my_real_user.lua"
                mkdir_p(sb.xdg_config .. "/hypr")
                local orig = "return { symlink_sentinel = true }\n"
                write_file(target, orig)
                assert_eq(exec_sh("ln -s -- " .. sh_quote(target) .. " " .. sh_quote(user_lua)), 0)

                local r = sb:run({ INSTALL_SH, "--skip-packages", "--yes", "--no-log" })
                assert_eq(r.rc, 0, "install with symlink user.lua exit 0")
                assert_true(is_symlink(user_lua), "user.lua remains a symlink")
                assert_eq(readlink(user_lua), target, "user.lua symlink target unchanged")
                assert_eq(read_file(target), orig, "symlink target content untouched")
            end)

            -- 3. Re-run preserves custom edit made after initial seed
            with_sandbox({ drm_cards = hybrid_cards }, function(sb)
                local user_lua = sb.xdg_config .. "/hypr/user.lua"
                local r1 = sb:run({ INSTALL_SH, "--skip-packages", "--yes", "--no-log" })
                assert_eq(r1.rc, 0, "initial hybrid install exit 0")
                assert_true(is_file(user_lua), "initial seed created")

                local edited = "return { drm_devices = '/dev/dri/card0', prefer_mesa_egl = false, edited = true }\n"
                write_file(user_lua, edited)

                local r2 = sb:run({ INSTALL_SH, "--skip-packages", "--yes", "--no-log" })
                assert_eq(r2.rc, 0, "re-run hybrid install exit 0")
                assert_eq(read_file(user_lua), edited, "re-run preserves user edits to user.lua")
            end)
        end)

        test("bb.gpu.seeded_user_lua_survives_rollback", function()
            with_sandbox({
                drm_cards = {
                    { name = "card0", vendor = "0x8086", connectors = { { name = "card0-eDP-1", status = "connected" } } },
                    { name = "card1", vendor = "0x10de" },
                },
            }, function(sb)
                mkdir_p(sb.xdg_config .. "/hypr")
                write_file(sb.xdg_config .. "/hypr/hyprland.lua", "-- prior config\n")

                local r = sb:run({ INSTALL_SH, "--skip-packages", "--yes", "--no-log" })
                assert_eq(r.rc, 0, "hybrid install exit 0: " .. r.combined)

                local user_lua = sb.xdg_config .. "/hypr/user.lua"
                assert_true(is_file(user_lua), "user.lua seeded before rollback")
                local seeded_content = read_file(user_lua)

                local rollback_sh = trim(capture_sh(
                    "find " .. sh_quote(sb.root) .. " -maxdepth 6 -type f -name 'rollback.sh' 2>/dev/null | head -n1"
                ))
                assert_true(rollback_sh ~= "", "install created a rollback.sh script in sandbox")

                local rr = sb:run({ rollback_sh, "--yes" })
                assert_eq(rr.rc, 0, "rollback.sh --yes exit 0: " .. rr.combined)
                assert_true(is_file(user_lua), "seeded user.lua MUST survive rollback.sh --yes")
                assert_eq(read_file(user_lua), seeded_content, "seeded user.lua content unchanged after rollback")
            end)
        end)

        -- =====================================================================
        -- DOMAIN 5: Package Conflict Detection & Handling
        -- =====================================================================

        test("bb.conflicts.no_substring_false_positives", function()
            local decoys = {
                "pulseaudio-ctl", "libpulse", "pulseaudio-alsa",
                "pipewire-media-session-git", "dunstify", "my-mako",
                "fnott-git", "swaync-client", "xdg-desktop-portal-wlr-git",
                "hyprland", "foot",
            }
            with_sandbox({ installed_pkgs = decoys }, function(sb)
                local r = sb:run({ INSTALL_SH, "--yes", "--skip-system-setup", "--no-zsh", "--no-log" })
                assert_eq(r.rc, 0, "substring decoys must not trigger conflicts: " .. r.combined)
                assert_true(not sb:calls():find("PACMAN -Rdd", 1, true), "must NOT call pacman -Rdd on decoys")
                assert_contains(sb:calls(), "PACMAN -Syu", "proceeded to pacman -Syu")
                assert_true(not r.combined:find("pacman -Rns", 1, true), "no soft conflict warning on decoys")
            end)
        end)

        test("bb.conflicts.hard_power_set_yes_aborts", function()
            local hard_subsets = {
                { "pulseaudio" },
                { "pipewire-media-session" },
                { "pulseaudio", "pipewire-media-session" },
            }
            for _, subset in ipairs(hard_subsets) do
                with_sandbox({ installed_pkgs = subset }, function(sb)
                    local r = sb:run({ INSTALL_SH, "--yes", "--skip-system-setup", "--no-zsh", "--no-log" })
                    assert_true(r.rc ~= 0, "hard conflicts {" .. table.concat(subset, ",") .. "} without --replace-conflicts must abort")
                    assert_true(not sb:calls():find("PACMAN -Rdd", 1, true), "must NOT call pacman -Rdd when aborting")
                    assert_true(not sb:calls():find("PACMAN -Syu", 1, true), "must NOT call pacman -Syu when aborting")
                end)
            end
        end)

        test("bb.conflicts.hard_replace_conflicts_and_soft_preserved", function()
            local soft_all = { "xdg-desktop-portal-wlr", "dunst", "mako", "fnott", "swaync" }
            local hard_subsets = {
                { "pulseaudio" },
                { "pipewire-media-session" },
                { "pulseaudio", "pipewire-media-session" },
            }
            for _, hard in ipairs(hard_subsets) do
                local installed = {}
                for _, p in ipairs(hard) do installed[#installed + 1] = p end
                for _, p in ipairs(soft_all) do installed[#installed + 1] = p end

                with_sandbox({ installed_pkgs = installed }, function(sb)
                    local r = sb:run({
                        INSTALL_SH, "--yes", "--replace-conflicts", "--skip-system-setup", "--no-zsh", "--no-log",
                    })
                    assert_eq(r.rc, 0, "--replace-conflicts exit 0: " .. r.combined)

                    local lines = sb:call_lines()
                    local rdd_idx, syu_idx, rdd_line
                    for i, l in ipairs(lines) do
                        if l:find("^PACMAN %-Rdd") and not rdd_idx then
                            rdd_idx = i
                            rdd_line = l
                        elseif l:find("^PACMAN %-Syu") and not syu_idx then
                            syu_idx = i
                        end
                    end
                    assert_true(rdd_idx ~= nil, "pacman -Rdd was invoked")
                    assert_true(syu_idx ~= nil, "pacman -Syu was invoked")
                    assert_true(rdd_idx < syu_idx, "pacman -Rdd MUST run strictly BEFORE pacman -Syu")
                    assert_contains(rdd_line, "--noconfirm", "--yes adds --noconfirm to -Rdd")

                    for _, h in ipairs(hard) do
                        assert_contains(rdd_line, h, "-Rdd removes hard conflict " .. h)
                    end
                    for _, s in ipairs(soft_all) do
                        assert_true(not rdd_line:find(s, 1, true), "-Rdd MUST NEVER remove soft conflict " .. s)
                    end

                    assert_contains(r.combined, "sudo pacman -Rns", "warns with suggested sudo pacman -Rns")
                    for _, s in ipairs(soft_all) do
                        assert_contains(r.combined, s, "soft conflict warning mentions " .. s)
                    end
                end)
            end
        end)

        test("bb.conflicts.interactive_cli_prompt", function()
            with_sandbox({ installed_pkgs = { "pulseaudio" } }, function(sb)
                local r = sb:run({ INSTALL_SH, "--no-tui", "--skip-system-setup", "--no-zsh", "--no-log" }, {
                    stdin = "n\n",
                })
                assert_true(r.rc ~= 0, "interactive 'n' on hard conflict must abort")
                assert_true(not sb:calls():find("PACMAN -Rdd", 1, true), "interactive 'n' must not run -Rdd")
                assert_true(not sb:calls():find("PACMAN -Syu", 1, true), "interactive 'n' must not run -Syu")
            end)

            with_sandbox({ installed_pkgs = { "pulseaudio" } }, function(sb)
                local r = sb:run({ INSTALL_SH, "--no-tui", "--skip-system-setup", "--no-zsh", "--no-log" }, {
                    stdin = "y\ny\ny\n",
                })
                assert_eq(r.rc, 0, "interactive 'y' on hard conflict succeeds: " .. r.combined)
                assert_contains(sb:calls(), "PACMAN -Rdd", "interactive 'y' calls pacman -Rdd")
                assert_contains(sb:calls(), "pulseaudio", "interactive 'y' removes pulseaudio")
                assert_contains(sb:calls(), "PACMAN -Syu", "interactive 'y' proceeds to pacman -Syu")
            end)
        end)

        test("bb.conflicts.skip_packages_and_soft_only", function()
            with_sandbox({ installed_pkgs = { "pulseaudio", "pipewire-media-session" } }, function(sb)
                local r = sb:run({ INSTALL_SH, "--skip-packages", "--yes", "--no-log" })
                assert_eq(r.rc, 0, "--skip-packages ignores hard conflicts: " .. r.combined)
                assert_true(path_exists(sb.xdg_config .. "/hypr/hyprland.lua"), "dotfiles deployed")
                assert_true(path_exists(sb.xdg_config .. "/kaze/profile"), "profile deployed")
                assert_true(not sb:calls():find("PACMAN -Rdd", 1, true), "no -Rdd when --skip-packages")
            end)

            local soft_all = { "xdg-desktop-portal-wlr", "dunst", "mako", "fnott", "swaync" }
            with_sandbox({ installed_pkgs = soft_all }, function(sb)
                local r = sb:run({ INSTALL_SH, "--yes", "--skip-system-setup", "--no-zsh", "--no-log" })
                assert_eq(r.rc, 0, "soft-only conflicts must not abort: " .. r.combined)
                assert_true(not sb:calls():find("PACMAN -Rdd", 1, true), "soft-only must not call -Rdd")
                assert_contains(sb:calls(), "PACMAN -Syu", "soft-only proceeds to pacman -Syu")
                assert_contains(r.combined, "sudo pacman -Rns", "soft-only suggests sudo pacman -Rns")
                for _, s in ipairs(soft_all) do
                    assert_contains(r.combined, s, "soft-only warning lists " .. s)
                end
            end)
        end)

        -- =====================================================================
        -- DOMAIN 6: System Setup (--system-setup / --skip-system-setup)
        -- =====================================================================

        test("bb.syssetup.competing_network_14_case_matrix", function()
            local competitors = {
                "systemd-networkd.service",
                "iwd.service",
                "connman.service",
                "dhcpcd.service",
                "netctl@wlan0.service",
                "netctl-auto@wlan0.service",
                "dhcpcd@eth0.service",
            }
            -- Reuse one sandbox while resetting mock systemd state cleanly between all 14 cases
            with_sandbox({}, function(sb)
                for _, unit in ipairs(competitors) do
                    for _, mode in ipairs({ "enabled", "active" }) do
                        sb:set_state_list("sys_units_exist", { "NetworkManager.service", unit })
                        sb:set_state_list("sys_units_enabled", mode == "enabled" and { unit } or {})
                        sb:set_state_list("sys_units_active", mode == "active" and { unit } or {})
                        sb:clear_calls()

                        local r = sb:run({ INSTALL_SH, "--skip-packages", "--system-setup", "--yes", "--no-log" })
                        assert_eq(r.rc, 0, unit .. " (" .. mode .. ") exit 0: " .. r.combined)
                        assert_true(
                            not sb:calls():find("enable NetworkManager.service", 1, true),
                            "MUST NOT enable NetworkManager when " .. unit .. " is " .. mode .. "\ncalls:\n" .. sb:calls()
                        )
                    end
                end
            end)
        end)

        test("bb.syssetup.nm_and_bluetooth_enable_and_idempotent", function()
            with_sandbox({
                units_exist = { "NetworkManager.service", "bluetooth.service" },
            }, function(sb)
                local r = sb:run({ INSTALL_SH, "--skip-packages", "--system-setup", "--yes", "--no-log" })
                assert_eq(r.rc, 0, "syssetup happy path exit 0: " .. r.combined)
                assert_contains(sb:calls(), "SYSTEMCTL enable NetworkManager.service", "enables NetworkManager.service")
                assert_contains(sb:calls(), "SYSTEMCTL enable bluetooth.service", "enables bluetooth.service")
                assert_true(not sb:calls():find("--now", 1, true), "MUST NEVER use --now on system enable")
            end)

            with_sandbox({
                units_exist = { "NetworkManager.service", "bluetooth.service" },
                units_enabled = { "NetworkManager.service", "bluetooth.service" },
            }, function(sb)
                local r = sb:run({ INSTALL_SH, "--skip-packages", "--system-setup", "--yes", "--no-log" })
                assert_eq(r.rc, 0, "syssetup idempotent exit 0")
                assert_true(not sb:calls():find("enable NetworkManager.service", 1, true), "skips already-enabled NM")
                assert_true(not sb:calls():find("enable bluetooth.service", 1, true), "skips already-enabled bluetooth")
            end)

            with_sandbox({
                units_exist = { "NetworkManager.service" },
            }, function(sb)
                local r = sb:run({ INSTALL_SH, "--skip-packages", "--system-setup", "--yes", "--no-log" })
                assert_eq(r.rc, 0, "missing bluetooth unit exit 0")
                assert_true(not sb:calls():find("enable bluetooth.service", 1, true), "skips nonexistent bluetooth unit")
            end)
        end)

        test("bb.syssetup.pipewire_user_bus_present_vs_absent", function()
            if HAS_PYTHON3 then
                with_sandbox({ user_bus_socket = true }, function(sb)
                    local r = sb:run({ INSTALL_SH, "--skip-packages", "--system-setup", "--yes", "--no-log" })
                    assert_eq(r.rc, 0, "pipewire user bus present exit 0: " .. r.combined)
                    local calls = sb:calls()
                    assert_contains(calls, "SYSTEMCTL --user enable", "calls systemctl --user enable")
                    assert_contains(calls, "pipewire.socket", "enables pipewire.socket")
                    assert_contains(calls, "pipewire-pulse.socket", "enables pipewire-pulse.socket")
                    assert_contains(calls, "wireplumber.service", "enables wireplumber.service")
                end)
            end

            with_sandbox({ user_bus_socket = false }, function(sb)
                local r = sb:run({ INSTALL_SH, "--skip-packages", "--system-setup", "--yes", "--no-log" })
                assert_eq(r.rc, 0, "absent user bus must not fail: " .. r.combined)
                assert_true(not sb:calls():find("SYSTEMCTL --user enable", 1, true), "no --user enable without bus socket")
            end)

            with_sandbox({ user_bus_regular_file = true }, function(sb)
                local r = sb:run({ INSTALL_SH, "--skip-packages", "--system-setup", "--yes", "--no-log" })
                assert_eq(r.rc, 0, "non-socket bus file must not fail")
                assert_true(not sb:calls():find("SYSTEMCTL --user enable", 1, true), "no --user enable on non-socket bus")
            end)
        end)

        test("bb.syssetup.user_groups_video_never_input", function()
            with_sandbox({ video_group_exists = true, in_video_group = false }, function(sb)
                local r = sb:run({ INSTALL_SH, "--skip-packages", "--system-setup", "--yes", "--no-log" })
                assert_eq(r.rc, 0, "add video group exit 0")
                assert_contains(sb:calls(), "USERMOD -aG video testuser", "adds user to video group")
                assert_true(not sb:calls():find("input", 1, true), "MUST NEVER add user to input group")
            end)

            with_sandbox({ video_group_exists = true, in_video_group = true }, function(sb)
                local r = sb:run({ INSTALL_SH, "--skip-packages", "--system-setup", "--yes", "--no-log" })
                assert_eq(r.rc, 0, "already in video exit 0")
                assert_true(not sb:calls():find("USERMOD", 1, true), "skips usermod when already in video")
            end)

            with_sandbox({ video_group_exists = false, in_video_group = false }, function(sb)
                local r = sb:run({ INSTALL_SH, "--skip-packages", "--system-setup", "--yes", "--no-log" })
                assert_eq(r.rc, 0, "no video group exit 0")
                assert_true(not sb:calls():find("USERMOD", 1, true), "skips usermod when video group missing")
            end)
        end)

        test("bb.syssetup.fc_cache_failure_non_fatal_and_skip_flag", function()
            with_sandbox({ fc_cache_rc = 0 }, function(sb)
                local r = sb:run({ INSTALL_SH, "--skip-packages", "--system-setup", "--yes", "--no-log" })
                assert_eq(r.rc, 0, "fc-cache success exit 0")
                assert_contains(sb:calls(), "FC_CACHE -f", "runs fc-cache -f")
            end)

            with_sandbox({ fc_cache_rc = 1 }, function(sb)
                local r = sb:run({ INSTALL_SH, "--skip-packages", "--system-setup", "--yes", "--no-log" })
                assert_eq(r.rc, 0, "fc-cache failure MUST be non-fatal: " .. r.combined)
                assert_contains(sb:calls(), "FC_CACHE -f", "attempted fc-cache -f")
                assert_contains(r.combined:lower(), "fc-cache", "logs warning mentioning fc-cache")
            end)

            -- --skip-system-setup on full Arch run skips all system setup unit enables, usermod, and fc-cache
            with_sandbox({ user_bus_socket = HAS_PYTHON3 }, function(sb)
                local r = sb:run({ INSTALL_SH, "--yes", "--skip-system-setup", "--dm", "none", "--no-zsh", "--no-log" })
                assert_eq(r.rc, 0, "--skip-system-setup exit 0")
                assert_true(not sb:calls():find("SYSTEMCTL enable", 1, true), "--skip-system-setup skips system systemctl enable")
                assert_true(not sb:calls():find("SYSTEMCTL --user enable", 1, true), "--skip-system-setup skips PipeWire --user enable")
                assert_true(not sb:calls():find("USERMOD", 1, true), "--skip-system-setup skips usermod")
                assert_true(not sb:calls():find("FC_CACHE", 1, true), "--skip-system-setup skips fc-cache")
            end)
        end)

        -- =====================================================================
        -- DOMAIN 7: Optional Display Manager (--dm none|ly|greetd)
        -- =====================================================================

        test("bb.dm.competing_dm_guard_matrix", function()
            local guard_cases = {
                { dm = "noctalia", unit = "sddm.service", state = "enabled" },
                { dm = "noctalia", unit = "gdm.service", state = "enabled" },
                { dm = "noctalia", unit = "lightdm.service", state = "active" },
                { dm = "noctalia", unit = "ly@tty1.service", state = "enabled" },
                { dm = "ly", unit = "gdm.service", state = "enabled" },
                { dm = "ly", unit = "gdm.service", state = "active" },
                { dm = "ly", unit = "sddm.service", state = "enabled" },
                { dm = "ly", unit = "lightdm.service", state = "enabled" },
                { dm = "ly", unit = "lxdm.service", state = "active" },
                { dm = "ly", unit = "display-manager.service", state = "enabled" },
                { dm = "ly", unit = "greetd.service", state = "enabled" },
                { dm = "greetd", unit = "gdm.service", state = "enabled" },
                { dm = "greetd", unit = "sddm.service", state = "active" },
                { dm = "greetd", unit = "lightdm.service", state = "enabled" },
                { dm = "greetd", unit = "lxdm.service", state = "enabled" },
                { dm = "greetd", unit = "display-manager.service", state = "enabled" },
                { dm = "greetd", unit = "ly.service", state = "enabled" },
                { dm = "greetd", unit = "ly@tty1.service", state = "enabled" },
                { dm = "greetd", unit = "ly@tty2.service", state = "enabled" },
                { dm = "greetd", unit = "ly@tty3.service", state = "active" },
                {
                    dm = "greetd",
                    name = "ly_tty3_wants_symlink",
                    symlinks = { ["multi-user.target.wants/ly@tty3.service"] = "/usr/lib/systemd/system/ly@.service" },
                },
            }

            with_sandbox({}, function(sb)
                for _, tc in ipairs(guard_cases) do
                    local exist = { "ly@.service", "ly.service", "greetd.service", "getty@tty1.service" }
                    local enabled, active = {}, {}
                    if tc.unit then
                        exist[#exist + 1] = tc.unit
                        if tc.state == "enabled" then
                            enabled = { tc.unit }
                        elseif tc.state == "active" then
                            active = { tc.unit }
                        end
                    end
                    sb:set_state_list("sys_units_exist", exist)
                    sb:set_state_list("sys_units_enabled", enabled)
                    sb:set_state_list("sys_units_active", active)
                    exec_sh("rm -rf -- " .. sh_quote(sb.systemd_etc) .. "/* " .. sh_quote(sb.greetd_cfg))
                    if tc.symlinks then
                        for rel, target in pairs(tc.symlinks) do
                            local full = sb.systemd_etc .. "/" .. rel
                            mkdir_p(full:match("^(.*)/[^/]+$"))
                            exec_sh("ln -sf -- " .. sh_quote(target) .. " " .. sh_quote(full))
                        end
                    end
                    sb:clear_calls()

                    local label = tc.name or (tc.dm .. "_vs_" .. tc.unit .. "_" .. tc.state)
                    local r = sb:run({
                        INSTALL_SH, "--skip-packages", "--skip-system-setup", "--no-zsh", "--no-log", "--yes",
                        "--dm", tc.dm,
                    })
                    assert_eq(r.rc, 0, label .. " exits 0 cleanly: " .. r.combined)
                    assert_true(not sb:calls():find("SYSTEMCTL enable", 1, true), label .. " MUST make ZERO systemctl enable calls:\n" .. sb:calls())
                    assert_true(not path_exists(sb.greetd_cfg), label .. " MUST make ZERO greetd config writes")
                end
            end)
        end)

        test("bb.dm.ly_state_machine", function()
            with_sandbox({
                units_exist = { "ly@.service", "getty@tty1.service" },
                units_enabled = { "getty@tty1.service" },
            }, function(sb)
                local r = sb:run({
                    INSTALL_SH, "--skip-packages", "--skip-system-setup", "--no-zsh", "--no-log", "--yes", "--dm", "ly",
                })
                assert_eq(r.rc, 0, "ly@ happy path exit 0: " .. r.combined)
                assert_contains(sb:calls(), "SYSTEMCTL disable getty@tty1.service", "disables getty@tty1.service")
                assert_contains(sb:calls(), "SYSTEMCTL enable ly@tty1.service", "enables ly@tty1.service")
            end)

            with_sandbox({
                units_exist = { "ly.service" },
            }, function(sb)
                local r = sb:run({
                    INSTALL_SH, "--skip-packages", "--skip-system-setup", "--no-zsh", "--no-log", "--yes", "--dm", "ly",
                })
                assert_eq(r.rc, 0, "legacy ly.service exit 0: " .. r.combined)
                assert_contains(sb:calls(), "SYSTEMCTL enable ly.service", "enables legacy ly.service")
            end)

            with_sandbox({ units_exist = {} }, function(sb)
                local r = sb:run({
                    INSTALL_SH, "--skip-packages", "--skip-system-setup", "--no-zsh", "--no-log", "--yes", "--dm", "ly",
                })
                assert_eq(r.rc, 0, "missing ly unit exits 0 cleanly: " .. r.combined)
                assert_true(not sb:calls():find("SYSTEMCTL enable", 1, true), "no enable when ly unit missing")
            end)

            with_sandbox({
                units_exist = { "ly@.service" },
                systemd_symlinks = { ["multi-user.target.wants/ly@tty3.service"] = "/usr/lib/systemd/system/ly@.service" },
            }, function(sb)
                local r = sb:run({
                    INSTALL_SH, "--skip-packages", "--skip-system-setup", "--no-zsh", "--no-log", "--yes", "--dm", "ly",
                })
                assert_eq(r.rc, 0, "already-enabled ly@tty3 idempotent exit 0")
                assert_true(not sb:calls():find("SYSTEMCTL enable", 1, true), "idempotent: no redundant enable")
                assert_true(not sb:calls():find("SYSTEMCTL disable", 1, true), "idempotent: no redundant disable")
            end)
        end)

        test("bb.dm.greetd_state_machine", function()
            with_sandbox({
                units_exist = { "greetd.service" },
                greetd_dir = true,
            }, function(sb)
                local r = sb:run({
                    INSTALL_SH, "--skip-packages", "--skip-system-setup", "--no-zsh", "--no-log", "--yes", "--dm", "greetd",
                })
                assert_eq(r.rc, 0, "greetd fresh exit 0: " .. r.combined)
                local cfg = read_file(sb.greetd_cfg)
                assert_true(cfg ~= nil, "wrote KAZE_GREETD_CONFIG")
                assert_contains(cfg, "vt = 1", "greetd config has vt = 1")
                assert_contains(cfg, "tuigreet", "greetd config has tuigreet")
                assert_contains(cfg, "start-hyprland", "greetd config has start-hyprland")
                assert_contains(cfg, 'user = "greeter"', 'greetd config has user = "greeter"')
                assert_contains(sb:calls(), "SYSTEMCTL enable greetd.service", "enables greetd.service")
            end)

            with_sandbox({
                units_exist = { "greetd.service" },
                greetd_existing_content = "# OLD GREETD CONFIG\nvt = 7\n",
            }, function(sb)
                local r = sb:run({
                    INSTALL_SH, "--skip-packages", "--skip-system-setup", "--no-zsh", "--no-log", "--yes", "--dm", "greetd",
                })
                assert_eq(r.rc, 0, "greetd backup exit 0: " .. r.combined)
                local bak = trim(capture_sh("ls -1 " .. sh_quote(sb.greetd_cfg) .. ".kaze-bak-* 2>/dev/null | head -n1"))
                assert_true(bak ~= "", "created .kaze-bak-* backup of existing greetd config")
                assert_eq(read_file(bak), "# OLD GREETD CONFIG\nvt = 7\n", "backup preserves exact original config")
                assert_contains(read_file(sb.greetd_cfg) or "", "start-hyprland", "new greetd config written")
                assert_contains(sb:calls(), "SYSTEMCTL enable greetd.service", "enables greetd.service")
            end)

            with_sandbox({
                units_exist = { "greetd.service" },
                units_enabled = { "greetd.service" },
                greetd_existing_content = "# PRESERVE ME\n",
            }, function(sb)
                local r = sb:run({
                    INSTALL_SH, "--skip-packages", "--skip-system-setup", "--no-zsh", "--no-log", "--yes", "--dm", "greetd",
                })
                assert_eq(r.rc, 0, "greetd already enabled exit 0")
                assert_eq(read_file(sb.greetd_cfg), "# PRESERVE ME\n", "existing greetd config preserved untouched")
                assert_true(not sb:calls():find("SYSTEMCTL enable greetd.service", 1, true), "no redundant enable")
            end)

            with_sandbox({
                units_exist = {},
                greetd_dir = true,
            }, function(sb)
                local r = sb:run({
                    INSTALL_SH, "--skip-packages", "--skip-system-setup", "--no-zsh", "--no-log", "--yes", "--dm", "greetd",
                })
                assert_eq(r.rc, 0, "missing greetd unit exit 0: " .. r.combined)
                assert_true(not path_exists(sb.greetd_cfg), "MUST NOT write greetd config when unit does not exist")
                assert_true(not sb:calls():find("SYSTEMCTL enable", 1, true), "no enable when greetd unit missing")
            end)
        end)

        -- =====================================================================
        -- DOMAIN 8: Opt-In AUR Helper (--aur none|yay-bin|paru-bin)
        -- =====================================================================

        test("bb.aur.none_no_side_effects", function()
            with_sandbox({}, function(sb)
                local r = sb:run({ INSTALL_SH, "--yes", "--skip-system-setup", "--no-zsh", "--no-log", "--aur", "none" })
                assert_eq(r.rc, 0, "--aur none exit 0")
                assert_true(not sb:calls():find("GIT ", 1, true), "--aur none invokes zero git")
                assert_true(not sb:calls():find("MAKEPKG", 1, true), "--aur none invokes zero makepkg")
                local pkgs = extract_pacman_syu_from_calls(sb:call_lines())
                local pset = set_from_list(pkgs or {})
                assert_true(not pset["base-devel"], "--aur none does not add base-devel")
            end)
        end)

        test("bb.aur.yay_and_paru_ordering_and_flags", function()
            for _, tc in ipairs({
                { aur = "yay-bin", yes = true },
                { aur = "paru-bin", yes = true },
                { aur = "yay-bin", yes = false },
            }) do
                with_sandbox({ aur_base_url = "https://mock-aur.test" }, function(sb)
                    local argv = {
                        INSTALL_SH, "--skip-system-setup", "--no-zsh", "--no-log", "--aur", tc.aur,
                    }
                    local stdin_data = nil
                    if tc.yes then
                        argv[#argv + 1] = "--yes"
                    else
                        argv[#argv + 1] = "--no-tui"
                        stdin_data = "y\ny\ny\n"
                    end

                    local r = sb:run(argv, { stdin = stdin_data })
                    assert_eq(r.rc, 0, tc.aur .. " (yes=" .. tostring(tc.yes) .. ") exit 0: " .. r.combined)

                    local pkgs = extract_pacman_syu_from_calls(sb:call_lines())
                    local pset = set_from_list(pkgs or {})
                    assert_true(pset["base-devel"], tc.aur .. " adds base-devel to pacman")
                    assert_true(pset["git"], tc.aur .. " adds git to pacman")

                    local calls = sb:calls()
                    assert_contains(calls, "https://mock-aur.test/" .. tc.aur .. ".git", "clones from KAZE_AUR_BASE_URL")
                    assert_contains(calls, "MAKEPKG", "invokes makepkg")
                    assert_contains(calls, "-si", "makepkg has -si")
                    assert_contains(calls, "--needed", "makepkg has --needed")
                    if tc.yes then
                        assert_contains(calls, "MAKEPKG -si --needed --noconfirm", "makepkg has --noconfirm with --yes")
                    else
                        local mk_line = calls:match("(MAKEPKG[^\n]*)") or ""
                        assert_true(not mk_line:find("--noconfirm", 1, true), "no --noconfirm without --yes: " .. mk_line)
                    end

                    local git_ord = read_file(sb.git_order_log) or ""
                    local mk_ord = read_file(sb.makepkg_order_log) or ""
                    assert_contains(git_ord, "profile=yes hyprland=yes", "dotfiles deployed STRICTLY BEFORE git clone")
                    assert_contains(mk_ord, "profile=yes hyprland=yes", "dotfiles deployed STRICTLY BEFORE makepkg")
                end)
            end
        end)

        test("bb.aur.already_installed_skips", function()
            for _, tc in ipairs({
                { aur = "yay-bin", opts = { has_yay = true } },
                { aur = "paru-bin", opts = { has_paru = true } },
            }) do
                with_sandbox(tc.opts, function(sb)
                    local r = sb:run({
                        INSTALL_SH, "--skip-packages", "--skip-system-setup", "--no-zsh", "--no-log", "--yes",
                        "--aur", tc.aur,
                    })
                    assert_eq(r.rc, 0, "already installed " .. tc.aur .. " exit 0: " .. r.combined)
                    assert_true(not sb:calls():find("GIT ", 1, true), "skips git clone when binary exists")
                    assert_true(not sb:calls():find("MAKEPKG", 1, true), "skips makepkg when binary exists")
                end)
            end
        end)

        test("bb.aur.clone_and_makepkg_failures_non_fatal", function()
            with_sandbox({ git_clone_rc = 128 }, function(sb)
                local r = sb:run({
                    INSTALL_SH, "--skip-packages", "--skip-system-setup", "--no-zsh", "--no-log", "--yes",
                    "--aur", "yay-bin",
                })
                assert_eq(r.rc, 0, "git clone failure MUST be non-fatal (exit 0): " .. r.combined)
                assert_true(path_exists(sb.xdg_config .. "/kaze/profile"), "profile intact after clone failure")
                assert_true(path_exists(sb.xdg_config .. "/hypr/hyprland.lua"), "hyprland.lua intact after clone failure")
                assert_contains(r.combined, "Doctor summary:", "post-install kaze-doctor STILL runs after clone failure")
                local leftover = trim(capture_sh("find " .. sh_quote(sb.tmpdir) .. " -mindepth 1 2>/dev/null || true"))
                assert_eq(leftover, "", "temp AUR build dir cleaned up after clone failure")
            end)

            with_sandbox({ makepkg_rc = 1 }, function(sb)
                local r = sb:run({
                    INSTALL_SH, "--skip-packages", "--skip-system-setup", "--no-zsh", "--no-log", "--yes",
                    "--aur", "paru-bin",
                })
                assert_eq(r.rc, 0, "makepkg failure MUST be non-fatal (exit 0): " .. r.combined)
                assert_true(path_exists(sb.xdg_config .. "/kaze/profile"), "profile intact after makepkg failure")
                assert_true(path_exists(sb.xdg_config .. "/hypr/hyprland.lua"), "hyprland.lua intact after makepkg failure")
                assert_contains(r.combined, "Doctor summary:", "post-install kaze-doctor STILL runs after makepkg failure")
                local cloned = split_lines(read_file(sb.aur_clone_dirs_log) or "")
                for _, d in ipairs(cloned) do
                    assert_true(not path_exists(d), "temp AUR clone dir cleaned up after makepkg failure: " .. d)
                end
            end)
        end)

        -- =====================================================================
        -- DOMAIN 9: Logging, Keepalive, Post-Install Doctor, Audio Matrix & PTY TUI
        -- =====================================================================

        test("bb.log.sanitized_utf8_c_and_spaces", function()
            for _, locale in ipairs({ "C", "en_US.UTF-8" }) do
                with_sandbox({
                    home_rel = "my home",
                    xdg_config_rel = "my cfg/dir",
                    xdg_data_rel = "my data/dir",
                    xdg_cache_rel = "my cache/dir",
                    xdg_state_rel = "state dir/with spaces",
                }, function(sb)
                    local r = sb:run({ INSTALL_SH, "--skip-packages", "--yes" }, {
                        env = { LC_ALL = locale, LANG = locale, NO_COLOR = false, TERM = "xterm-256color" },
                    })
                    assert_eq(r.rc, 0, "logged install with spaces (" .. locale .. ") exit 0: " .. r.combined)
                    assert_true(path_exists(sb.xdg_config .. "/hypr/hyprland.lua"), "dotfiles deployed into spaced XDG_CONFIG_HOME")
                    local log_path = trim(capture_sh(
                        "find " .. sh_quote(sb.xdg_state .. "/kaze") .. " -maxdepth 1 -type f -name 'install-*.log' 2>/dev/null | head -n1"
                    ))
                    assert_true(log_path ~= "", "created install-*.log in path with spaces (" .. locale .. ")")
                    local log_data = read_file(log_path) or ""
                    assert_true(#log_data > 50, "log file is non-empty")
                    assert_true(not log_data:find("\27%[", 1, false), "log MUST contain ZERO ANSI CSI escapes (" .. locale .. ")")
                    assert_true(not log_data:find("\27%]", 1, false), "log MUST contain ZERO ANSI OSC escapes (" .. locale .. ")")
                    assert_true(not log_data:find("\r", 1, true), "log MUST contain ZERO \\r characters (" .. locale .. ")")
                    assert_contains(log_data, "Doctor summary:", "log contains Doctor summary:")
                end)
            end

            with_sandbox({}, function(sb)
                local r = sb:run({ INSTALL_SH, "--skip-packages", "--yes", "--no-log" })
                assert_eq(r.rc, 0, "--no-log exit 0")
                local found = trim(capture_sh(
                    "find " .. sh_quote(sb.xdg_state .. "/kaze") .. " -mindepth 1 2>/dev/null || true"
                ))
                assert_eq(found, "", "--no-log writes ZERO files under $XDG_STATE_HOME/kaze")
            end)
        end)

        test("bb.sudo.keepalive_gating_failure_and_no_leaks", function()
            with_sandbox({}, function(sb)
                local r = sb:run({ INSTALL_SH, "--skip-packages", "--no-zsh", "--yes", "--no-log" })
                assert_eq(r.rc, 0, "unprivileged install exit 0")
                assert_true(not sb:calls():find("SUDO", 1, true), "unprivileged run must NOT call sudo:\n" .. sb:calls())
            end)

            with_sandbox({ sudo_v_fail = true }, function(sb)
                local r = sb:run({ INSTALL_SH, "--yes", "--no-log" })
                assert_true(r.rc ~= 0, "sudo -v failure must exit non-zero")
                assert_contains(sb:calls(), "SUDO -v", "attempted sudo -v")
                assert_true(not sb:calls():find("PACMAN -Syu", 1, true), "aborted BEFORE pacman -Syu")
                assert_true(not path_exists(sb.xdg_config .. "/hypr/hyprland.lua"), "aborted BEFORE deploying dotfiles")
            end)

            with_sandbox({}, function(sb)
                local marker = "KAZE_BB_LEAK_" .. suite_uid .. "_" .. tostring(sandbox_seq)
                local r = sb:run({ INSTALL_SH, "--yes", "--skip-system-setup", "--no-zsh", "--no-log" }, {
                    env = { KAZE_BB_LEAK_MARKER = marker },
                })
                assert_eq(r.rc, 0, "privileged install exit 0: " .. r.combined)
                assert_contains(sb:calls(), "SUDO -v", "privileged run called sudo -v")

                if HAS_PYTHON3 then
                    local py = [[
import os, sys, signal
marker = ("KAZE_BB_LEAK_MARKER=" + sys.argv[1]).encode()
my_pid = os.getpid()
ppid = os.getppid()
leaks = []
for entry in os.listdir("/proc"):
    if not entry.isdigit():
        continue
    pid = int(entry)
    if pid in (my_pid, ppid):
        continue
    try:
        with open(f"/proc/{pid}/environ", "rb") as f:
            env = f.read()
        if marker in env:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                cmd = f.read().replace(b"\0", b" ").decode("utf-8", "replace").strip()
            leaks.append(f"{pid}:{cmd}")
            try:
                os.kill(pid, signal.SIGTERM)
            except OSError:
                pass
    except OSError:
        pass
if leaks:
    print("\n".join(leaks))
    sys.exit(1)
]]
                    local out, rc = capture_sh("python3 -c " .. sh_quote(py) .. " " .. sh_quote(marker))
                    assert_eq(rc, 0, "ZERO lingering sudo keepalive child processes allowed; leaked:\n" .. out)
                end
            end)
        end)

        test("bb.doctor.post_install_offline_non_fatal", function()
            with_sandbox({}, function(sb)
                local r = sb:run({ INSTALL_SH, "--skip-packages", "--yes", "--no-log" })
                assert_eq(r.rc, 0, "post-install doctor --offline is non-fatal: " .. r.combined)
                assert_contains(r.combined, "Doctor summary:", "post-install doctor summary emitted")
            end)
        end)

        test("bb.doctor.live_audio_16_state_truth_table", function()
            local ok_count = 0
            local fail_count = 0
            local bools = { false, true }

            with_sandbox({ user_bus_socket = HAS_PYTHON3 }, function(sb)
                for _, pw in ipairs(bools) do
                    for _, wp in ipairs(bools) do
                        for _, pwsock in ipairs(bools) do
                            for _, pwsvc in ipairs(bools) do
                                local active = {}
                                if pw then active[#active + 1] = "pipewire.service" end
                                if wp then active[#active + 1] = "wireplumber.service" end
                                if pwsock then active[#active + 1] = "pipewire-pulse.socket" end
                                if pwsvc then active[#active + 1] = "pipewire-pulse.service" end

                                local expected_ok = pw and wp and (pwsock or pwsvc)
                                if expected_ok then ok_count = ok_count + 1 else fail_count = fail_count + 1 end

                                sb:set_state_list("usr_units_active", active)
                                local r = sb:run({ DOCTOR_BIN }, {
                                    env = {
                                        HYPRLAND_INSTANCE_SIGNATURE = "mock-session",
                                        WAYLAND_DISPLAY = "wayland-1",
                                    },
                                })
                                local clean = strip_ansi(r.combined)
                                local audio_line = nil
                                for _, line in ipairs(split_lines(clean)) do
                                    local low = line:lower()
                                    if (line:find("%[OK%]") or line:find("%[FAIL%]") or line:find("%[WARN%]"))
                                        and (low:find("audio", 1, true) or low:find("pipewire", 1, true))
                                    then
                                        audio_line = line
                                        break
                                    end
                                end
                                local tag = string.format(
                                    "pw=%s wp=%s pwsock=%s pwsvc=%s",
                                    tostring(pw), tostring(wp), tostring(pwsock), tostring(pwsvc)
                                )
                                assert_true(audio_line ~= nil, tag .. ": could not find Audio check line in:\n" .. clean)
                                if expected_ok then
                                    assert_contains(audio_line, "[OK]", tag .. " expected [OK], got: " .. audio_line)
                                else
                                    assert_contains(audio_line, "[FAIL]", tag .. " expected [FAIL], got: " .. audio_line)
                                end
                            end
                        end
                    end
                end
            end)

            assert_eq(ok_count, 3, "exact 3 [OK] states in 16-state audio truth table")
            assert_eq(fail_count, 13, "exact 13 [FAIL] states in 16-state audio truth table")
        end)

        -- =====================================================================
        -- Interactive PTY TUI tests (requires python3 pty)
        -- =====================================================================

        if HAS_PYTHON3 then
            local PTY_DRIVER_PY = [=[
import fcntl, os, pty, re, select, signal, struct, sys, termios, time

cols = int(sys.argv[1])
rows = int(sys.argv[2])
mode = sys.argv[3]
cmd = sys.argv[4:]

pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)

fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
raw_chunks = []

def read_until_quiet(quiet_sec=0.09, max_sec=2.0):
    buf = b""
    deadline = time.monotonic() + max_sec
    last_data = time.monotonic()
    while time.monotonic() < deadline:
        rem = min(0.03, max(0.0, deadline - time.monotonic()))
        r, _, _ = select.select([fd], [], [], rem)
        if r:
            try:
                chunk = os.read(fd, 65536)
                if not chunk:
                    break
                buf += chunk
                raw_chunks.append(chunk)
                last_data = time.monotonic()
            except OSError:
                break
        elif buf and (time.monotonic() - last_data) >= quiet_sec:
            break
    return buf.decode("utf-8", "replace")

def send(data, quiet=0.09):
    os.write(fd, data.encode("utf-8"))
    return read_until_quiet(quiet_sec=quiet, max_sec=2.0)

def strip_ansi(s):
    s = re.sub(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)", "", s)
    s = re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]", "", s)
    return s

def emulate_frame(frame_bytes, cols, rows):
    s = frame_bytes.decode("utf-8", "replace")
    s = re.sub(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)", "", s)
    grid = [[" "] * cols for _ in range(rows)]
    r, c = 0, 0
    scrolls = 0
    max_row_used = 0
    i = 0
    n = len(s)
    while i < n:
        ch = s[i]
        if ch == "\x1b":
            if i + 1 < n and s[i + 1] == "[":
                j = i + 2
                while j < n and not ("@" <= s[j] <= "~"):
                    j += 1
                if j < n:
                    final = s[j]
                    params = s[i + 2:j]
                    if final in ("H", "f"):
                        parts = params.split(";") if params else []
                        rr = int(parts[0]) - 1 if len(parts) >= 1 and parts[0].isdigit() else 0
                        cc = int(parts[1]) - 1 if len(parts) >= 2 and parts[1].isdigit() else 0
                        r = max(0, min(rows - 1, rr))
                        c = max(0, min(cols - 1, cc))
                    elif final == "J":
                        if params in ("2", "3"):
                            grid = [[" "] * cols for _ in range(rows)]
                            scrolls = 0
                        elif params in ("", "0"):
                            for x in range(c, cols):
                                grid[r][x] = " "
                            for rr in range(r + 1, rows):
                                grid[rr] = [" "] * cols
                        elif params == "1":
                            for rr in range(0, r):
                                grid[rr] = [" "] * cols
                            for x in range(0, c + 1):
                                grid[r][x] = " "
                    elif final == "K":
                        if params in ("", "0"):
                            for x in range(c, cols):
                                grid[r][x] = " "
                    elif final == "A":
                        r = max(0, r - (int(params) if params.isdigit() else 1))
                    elif final == "B":
                        r = min(rows - 1, r + (int(params) if params.isdigit() else 1))
                    elif final == "C":
                        c = min(cols - 1, c + (int(params) if params.isdigit() else 1))
                    elif final == "D":
                        c = max(0, c - (int(params) if params.isdigit() else 1))
                    i = j + 1
                    continue
            i += 1
            continue
        if ch == "\r":
            c = 0
        elif ch == "\n":
            r += 1
            if r >= rows:
                scrolls += 1
                grid.pop(0)
                grid.append([" "] * cols)
                r = rows - 1
            max_row_used = max(max_row_used, r)
        elif ch >= " ":
            if c >= cols:
                c = 0
                r += 1
                if r >= rows:
                    scrolls += 1
                    grid.pop(0)
                    grid.append([" "] * cols)
                    r = rows - 1
            grid[r][c] = ch
            c += 1
            max_row_used = max(max_row_used, r)
        i += 1
    lines = ["".join(row).rstrip() for row in grid]
    return scrolls, max_row_used + 1, lines

try:
    s0 = read_until_quiet(quiet_sec=0.14, max_sec=2.5)
    if mode == "navigate":
        s1 = send("\r")     # Style
        s2 = send("\r")     # Options
        s3 = send("p")      # Package Modal
        s4 = send("\x1b")   # Close Package Modal
        s5 = send("\r")     # Review
        s6 = send("q")      # Abort
        def flat(x): return strip_ansi(x).replace("\r", "").replace("\n", " | ")
        print("STEP0=" + flat(s0))
        print("STEP1=" + flat(s1))
        print("STEP2=" + flat(s2))
        print("STEP3=" + flat(s3))
        print("STEP4=" + flat(s4))
        print("STEP5=" + flat(s5))
        print("STEP6=" + flat(s6))
    elif mode == "non_arch_options":
        send("\r")  # Style
        send("\r")  # Options
        # Navigate 4x Down to Display Manager row
        for _ in range(4):
            send("\x1b[B", quiet=0.06)
        s_dm_sp = strip_ansi(send(" ", quiet=0.10))
        s_dm_rt = strip_ansi(send("\x1b[C", quiet=0.10))
        # Navigate 1x Down to AUR Helper row
        send("\x1b[B", quiet=0.06)
        s_aur_sp = strip_ansi(send(" ", quiet=0.10))
        s_aur_rt = strip_ansi(send("\x1b[C", quiet=0.10))
        send("q", quiet=0.08)
        def flat(x): return x.replace("\r", "").replace("\n", " | ")
        print("DM_SPACE=" + flat(s_dm_sp))
        print("DM_RIGHT=" + flat(s_dm_rt))
        print("AUR_SPACE=" + flat(s_aur_sp))
        print("AUR_RIGHT=" + flat(s_aur_rt))
    elif mode == "review_80x24":
        send("\r")  # Style
        send("\r")  # Options
        raw_before_review = len(raw_chunks)
        send("\r", quiet=0.14)  # Review
        review_bytes = b"".join(raw_chunks[raw_before_review:])
        scrolls, used_rows, lines = emulate_frame(review_bytes, cols, rows)
        send("q", quiet=0.08)
        print(f"SCROLLS={scrolls}")
        print(f"USED_ROWS={used_rows}")
        print("VIEWPORT_START")
        for idx, ln in enumerate(lines, 1):
            print(f"{idx:02d}|{ln}")
        print("VIEWPORT_END")

    end_wait = time.monotonic() + 2.0
    exit_code = None
    while time.monotonic() < end_wait:
        wpid, status = os.waitpid(pid, os.WNOHANG)
        if wpid == pid:
            exit_code = os.waitstatus_to_exitcode(status)
            break
        time.sleep(0.02)
    if exit_code is None:
        try:
            os.kill(pid, signal.SIGTERM)
            _, status = os.waitpid(pid, 0)
            exit_code = os.waitstatus_to_exitcode(status)
        except OSError:
            exit_code = -1
    print(f"CHILD_RC={exit_code}")
finally:
    try:
        os.close(fd)
    except OSError:
        pass
]=]

            local function run_pty(sb, cols, rows, mode, script_args, env_extra)
                local py_path = sb.root .. "/pty_driver.py"
                write_file(py_path, PTY_DRIVER_PY)
                local argv = { "python3", py_path, tostring(cols), tostring(rows), mode }
                for _, a in ipairs(script_args) do argv[#argv + 1] = a end
                return sb:run(argv, { env = env_extra, timeout = 15 })
            end

            test("bb.tui.pty_navigation_three_geometries", function()
                for _, geom in ipairs({ { 80, 24 }, { 60, 18 }, { 120, 40 } }) do
                    with_sandbox({}, function(sb)
                        local before = sb:xdg_snapshot()
                        local tag = string.format("PTY %dx%d", geom[1], geom[2])
                        local r = run_pty(sb, geom[1], geom[2], "navigate", { INSTALL_SH, "--tui" })
                        assert_eq(r.rc, 0, tag .. " driver exit 0: " .. r.combined)

                        local step0 = r.stdout:match("STEP0=([^\n]*)") or ""
                        local step1 = r.stdout:match("STEP1=([^\n]*)") or ""
                        local step2 = r.stdout:match("STEP2=([^\n]*)") or ""
                        local step3 = r.stdout:match("STEP3=([^\n]*)") or ""
                        local step4 = r.stdout:match("STEP4=([^\n]*)") or ""
                        local step5 = r.stdout:match("STEP5=([^\n]*)") or ""
                        local step6 = r.stdout:match("STEP6=([^\n]*)") or ""

                        assert_contains(step0:lower(), "profile", tag .. " STEP0 renders Profile screen")
                        assert_contains(step1:lower(), "style", tag .. " STEP1 renders Style screen")
                        assert_contains(step2:lower(), "options", tag .. " STEP2 renders Options screen")
                        assert_contains(step3:lower(), "package", tag .. " STEP3 ('p') opens Package Modal")
                        assert_contains(step4:lower(), "options", tag .. " STEP4 (Esc) returns to Options screen")
                        assert_contains(step5:lower(), "review", tag .. " STEP5 renders Review screen")
                        assert_contains(step6:lower(), "abort", tag .. " STEP6 ('q') aborts cleanly")
                        assert_contains(r.stdout, "CHILD_RC=", tag .. " child exited cleanly")
                        assert_no_mutating_calls(sb:calls(), tag .. " aborted TUI made zero mutating calls")
                        assert_eq(sb:xdg_snapshot(), before, tag .. " aborted TUI wrote zero files")
                    end)
                end
            end)

            test("bb.tui.pty_non_arch_refuses_dm_aur", function()
                with_sandbox({ arch = false, no_pacman = true }, function(sb)
                    local r = run_pty(sb, 80, 24, "non_arch_options", { INSTALL_SH, "--tui" })
                    assert_eq(r.rc, 0, "non-Arch PTY driver exit 0: " .. r.combined)

                    local dm_sp = r.stdout:match("DM_SPACE=([^\n]*)") or ""
                    local dm_rt = r.stdout:match("DM_RIGHT=([^\n]*)") or ""
                    local aur_sp = r.stdout:match("AUR_SPACE=([^\n]*)") or ""
                    local aur_rt = r.stdout:match("AUR_RIGHT=([^\n]*)") or ""

                    -- Cycling DM on non-Arch must warn and stay None
                    assert_contains(dm_sp:lower(), "pacman unavailable", "DM Space emits non-Arch status warning")
                    assert_contains(dm_sp, "None", "DM stays None after Space")
                    assert_contains(dm_rt, "None", "DM stays None after Right arrow")

                    -- Cycling AUR on non-Arch must warn and stay None
                    assert_contains(aur_sp:lower(), "pacman unavailable", "AUR Space emits non-Arch status warning")
                    assert_contains(aur_sp, "None", "AUR stays None after Space")
                    assert_contains(aur_rt, "None", "AUR stays None after Right arrow")

                    assert_no_mutating_calls(sb:calls(), "non-Arch TUI made zero mutating calls")
                end)
            end)

            test("bb.tui.pty_80x24_review_no_vertical_overflow", function()
                with_sandbox({
                    drm_cards = {
                        { name = "card0", vendor = "0x8086", connectors = { { name = "card0-eDP-1", status = "connected" } } },
                        { name = "card1", vendor = "0x10de" },
                    },
                    installed_pkgs = {
                        "pulseaudio", "pipewire-media-session",
                        "xdg-desktop-portal-wlr", "dunst", "mako", "fnott", "swaync",
                    },
                }, function(sb)
                    local r = run_pty(sb, 80, 24, "review_80x24", {
                        INSTALL_SH, "--tui", "--dm", "greetd", "--aur", "yay-bin",
                    })
                    assert_eq(r.rc, 0, "80x24 review PTY driver exit 0: " .. r.combined)
                    local scrolls = tonumber(r.stdout:match("SCROLLS=(%d+)"))
                    local used_rows = tonumber(r.stdout:match("USED_ROWS=(%d+)"))
                    local viewport = r.stdout:match("VIEWPORT_START\n(.*)\nVIEWPORT_END") or ""
                    assert_true(scrolls ~= nil and used_rows ~= nil, "parsed viewport metrics:\n" .. r.stdout)
                    assert_eq(
                        scrolls, 0,
                        "80x24 Review screen overflowed vertically (scrolls=" .. tostring(scrolls) .. "):\n" .. viewport
                    )
                    assert_true(
                        used_rows <= 24,
                        "80x24 Review screen exceeded 24 rows (used=" .. tostring(used_rows) .. "):\n" .. viewport
                    )
                    -- Confirm Review screen top title, dense sections, and bottom footer ALL fit inside 24 rows
                    assert_contains(viewport, "KAZE", "Top title bar must NOT be scrolled/clipped off row 1")
                    assert_contains(viewport, "Review", "Review header visible inside 24 rows")
                    assert_contains(viewport, "greetd", "DM selection visible inside 24 rows")
                    assert_contains(viewport, "yay-bin", "AUR selection visible inside 24 rows")
                    assert_contains(viewport, "Hybrid", "Hybrid GPU info visible inside 24 rows")
                    assert_contains(viewport:lower(), "conflict", "Conflict info visible inside 24 rows")
                    assert_contains(viewport, "Left/Right", "Bottom footer visible inside 24 rows")
                end)
            end)
        end
    end)

    -- Always clean up shared SAFE_BIN
    safe_rm_rf(SAFE_BIN)

    if not suite_ok then
        error(suite_err, 0)
    end
end

return run_suite
