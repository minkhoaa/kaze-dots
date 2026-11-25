#!/usr/bin/env lua

local function run_suite(test, assert_eq, assert_true, assert_contains, repo_dir)
    package.path = table.concat({
        repo_dir .. "/lua/?.lua",
        repo_dir .. "/lua/?/init.lua",
        package.path,
    }, ";")

    local fs = require("kaze.fs")
    local q = fs.shell_quote

    local function make_tmp_dir()
        local d = string.format("/tmp/kaze-stage3-c-%d-%d", os.time(), math.random(100000, 999999))
        fs.mkdir_p(d)
        return d
    end

    local function rm_rf(dir)
        os.execute("rm -rf -- " .. q(dir))
    end

    local function read_all(cmd)
        local p = io.popen(cmd)
        if not p then
            return "", false
        end
        local out = p:read("*a") or ""
        local ok = p:close()
        return out, (ok == true or ok == 0)
    end

    local function write_stub(dir, name, body)
        local path = dir .. "/" .. name
        fs.write_atomic(path, "#!/bin/sh\nset -eu\n" .. (body or "exit 0") .. "\n")
        assert_true(os.execute("chmod +x -- " .. q(path)), "chmod stub " .. name)
        return path
    end

    local function link_host_bin(dir, name)
        local actual = assert(fs.capture("command -v " .. q(name) .. " || echo /usr/bin/" .. name)):gsub("\n$", "")
        assert_true(os.execute("ln -sf -- " .. q(actual) .. " " .. q(dir .. "/" .. name)), "link " .. name)
    end

    test("install.sh: --dry-run validates minimal and full package sets and writes zero files", function()
        local tmp = make_tmp_dir()
        local ok_test, err_test = pcall(function()
            local home = tmp .. "/home"
            local cfg = tmp .. "/cfg"
            local data = tmp .. "/data"
            local env = string.format(
                "HOME=%s XDG_CONFIG_HOME=%s XDG_DATA_HOME=%s",
                q(home), q(cfg), q(data)
            )
            local installer = q(repo_dir .. "/scripts/install.sh")

            local min_out, min_ok = read_all(env .. " " .. installer .. " --profile minimal --dry-run 2>&1")
            assert_true(min_ok, "install.sh --profile minimal --dry-run must exit 0")
            assert_contains(min_out, "Kaze profile: minimal", "minimal header")
            assert_contains(min_out, "0 AUR", "minimal zero AUR")
            assert_contains(min_out, "  xdg-desktop-portal-hyprland\n", "minimal includes hyprland portal")
            assert_contains(min_out, "  xdg-desktop-portal-gtk\n", "minimal includes gtk portal")
            assert_contains(min_out, "  dconf\n", "minimal includes dconf")

            local function has_word(text, word)
                local pat = "%f[%w_-]" .. word:gsub("%-", "%%-") .. "%f[^%w_-]"
                return text:find(pat) ~= nil
            end

            -- Forbidden packages must never appear in minimal or full
            for _, forbidden in ipairs({ "power-profiles-daemon", "rofi", "libvips", "swaync", "wob", "hyprpaper", "hyprpolkitagent" }) do
                assert_true(not has_word(min_out, forbidden), "forbidden package in minimal: " .. forbidden)
            end
            for _, full_only in ipairs({ "fcitx5-bamboo", "mate-polkit", "swappy", "wf-recorder", "matugen", "yazi" }) do
                assert_true(not has_word(min_out, full_only), "full package leaked into minimal: " .. full_only)
            end

            local full_out, full_ok = read_all(env .. " " .. installer .. " --profile full --dry-run --yes 2>&1")
            assert_true(full_ok, "install.sh --profile full --dry-run --yes must exit 0")
            assert_contains(full_out, "Kaze profile: full", "full header")
            assert_contains(full_out, "0 AUR", "full zero AUR")
            assert_contains(full_out, "--noconfirm", "--yes adds --noconfirm")
            for _, pkg in ipairs({
                "swappy", "otf-font-awesome", "wf-recorder", "ffmpeg", "hyprpicker",
                "hyprsunset", "matugen", "yazi", "mate-polkit", "fcitx5",
                "fcitx5-bamboo", "fcitx5-gtk", "noto-fonts", "noto-fonts-emoji",
            }) do
                assert_contains(full_out, "  " .. pkg .. "\n", "full includes " .. pkg)
            end
            assert_contains(full_out, "fcitx5-configtool", "full mentions optional fcitx5-configtool note")
            for _, forbidden in ipairs({ "power-profiles-daemon", "rofi", "libvips", "swaync", "wob", "hyprpaper", "hyprpolkitagent" }) do
                assert_true(not has_word(full_out, forbidden), "forbidden package in full: " .. forbidden)
            end

            -- Verify zero files or directories written anywhere by --dry-run
            for _, untouched in ipairs({ home, cfg, data }) do
                local absent = os.execute("[ ! -e " .. q(untouched) .. " ] && [ ! -L " .. q(untouched) .. " ]")
                assert_true(absent == true or absent == 0, "--dry-run must not create " .. untouched)
            end

            local _, bad_ok = read_all(env .. " " .. installer .. " --profile bogus --dry-run 2>&1")
            assert_true(not bad_ok, "invalid profile must fail")
        end)
        rm_rf(tmp)
        if not ok_test then error(err_test, 0) end
    end)

    test("install.sh: --skip-packages --yes deploys symlinks, persists profile without clobbering state/user.lua, and rolls back cleanly", function()
        local tmp = make_tmp_dir()
        local ok_test, err_test = pcall(function()
            local home = tmp .. "/home space"
            local cfg = tmp .. "/cfg space"
            local data = tmp .. "/data space"
            local runtime = tmp .. "/runtime"
            fs.mkdir_p(home)
            fs.mkdir_p(cfg .. "/kaze")
            fs.mkdir_p(runtime)

            local user_lua = cfg .. "/kaze/user.lua"
            local state_lua = cfg .. "/kaze/state.lua"
            fs.write_atomic(user_lua, "return { browser = 'firefox' } -- user marker\n")
            fs.write_atomic(cfg .. "/waybar/style.css", "/* pre-existing user style */\n")

            local env = string.format(
                "HOME=%s XDG_CONFIG_HOME=%s XDG_DATA_HOME=%s XDG_RUNTIME_DIR=%s HYPRLAND_INSTANCE_SIGNATURE='' WAYLAND_DISPLAY=''",
                q(home), q(cfg), q(data), q(runtime)
            )
            local installer = q(repo_dir .. "/scripts/install.sh")

            -- Install full profile
            local out, ok = read_all(env .. " " .. installer .. " --profile full --skip-packages --yes 2>&1")
            assert_true(ok, "install.sh --profile full --skip-packages --yes failed: " .. out)
            assert_eq(fs.read_file(user_lua), "return { browser = 'firefox' } -- user marker\n", "user.lua preserved")

            for _, link_path in ipairs({
                cfg .. "/systemd/user/kaze-polkit.service",
                cfg .. "/systemd/user/kaze-fcitx5.service",
                home .. "/.local/bin/kaze-doctor",
                data .. "/kaze-dots/lua/kaze",
            }) do
                local is_link = os.execute("[ -L " .. q(link_path) .. " ] && [ -e " .. q(link_path) .. " ]")
                assert_true(is_link == true or is_link == 0, "expected valid symlink: " .. link_path)
            end

            local st_chunk = assert(loadfile(state_lua, "t", {}))
            local st_tbl = st_chunk()
            assert_eq(st_tbl.profile, "full", "state.lua persisted profile=full")

            -- Switch layout, then re-run install.sh --profile minimal --skip-packages --yes and verify layout is preserved
            assert_true(os.execute(env .. " " .. q(home .. "/.local/bin/kaze-layout") .. " --quiet islands >/dev/null 2>&1"))
            local out2, ok2 = read_all(env .. " " .. installer .. " --profile minimal --skip-packages --yes 2>&1")
            assert_true(ok2, "re-install minimal failed: " .. out2)
            local st_tbl2 = assert(loadfile(state_lua, "t", {}))()
            assert_eq(st_tbl2.profile, "minimal", "profile updated to minimal")
            assert_eq(st_tbl2.layout, "islands", "existing layout preserved across profile change")
            assert_eq(fs.read_file(user_lua), "return { browser = 'firefox' } -- user marker\n", "user.lua still untouched")

            -- Rollback using active backup script
            local backup_dir = assert(fs.read_file(cfg .. "/kaze/last-backup")):gsub("\n$", "")
            local rb_out, rb_ok = read_all(env .. " " .. q(backup_dir .. "/rollback.sh") .. " --yes 2>&1")
            assert_true(rb_ok, "rollback.sh failed: " .. rb_out)
            assert_eq(fs.read_file(user_lua), "return { browser = 'firefox' } -- user marker\n", "user.lua survives rollback")
            assert_eq(fs.read_file(cfg .. "/waybar/style.css"), "/* pre-existing user style */\n", "custom style restored")
            for _, gone in ipairs({
                cfg .. "/systemd/user/kaze-polkit.service",
                cfg .. "/systemd/user/kaze-fcitx5.service",
                home .. "/.local/bin/kaze-doctor",
                cfg .. "/kaze/state.lua",
                cfg .. "/kaze/last-backup",
            }) do
                local removed = os.execute("[ ! -e " .. q(gone) .. " ] && [ ! -L " .. q(gone) .. " ]")
                assert_true(removed == true or removed == 0, "rollback must remove " .. gone)
            end
        end)
        rm_rf(tmp)
        if not ok_test then error(err_test, 0) end
    end)

    test("systemd units: kaze-polkit.service and kaze-fcitx5.service respect session gating and preserve existing fcitx5 profile", function()
        local tmp = make_tmp_dir()
        local ok_test, err_test = pcall(function()
            local polkit_unit = assert(fs.read_file(repo_dir .. "/config/systemd/user/kaze-polkit.service"))
            local fcitx_unit = assert(fs.read_file(repo_dir .. "/config/systemd/user/kaze-fcitx5.service"))

            for name, unit in pairs({ polkit = polkit_unit, fcitx5 = fcitx_unit }) do
                assert_contains(unit, "PartOf=kaze-session.target", name .. " PartOf")
                assert_contains(unit, "Requisite=kaze-session.target", name .. " Requisite")
                assert_contains(unit, "After=kaze-session.target", name .. " After")
                assert_contains(unit, "StartLimitIntervalSec=30s", name .. " StartLimitIntervalSec")
                assert_contains(unit, "StartLimitBurst=5", name .. " StartLimitBurst")
                assert_contains(unit, "EnvironmentFile=%t/kaze/session.env", name .. " EnvironmentFile")
                assert_contains(unit, "Restart=on-failure", name .. " Restart")
                assert_contains(unit, "RestartSec=250ms", name .. " RestartSec")
                assert_contains(unit, "TimeoutStopSec=5s", name .. " TimeoutStopSec")
            end

            assert_contains(polkit_unit, "ConditionFileIsExecutable=/usr/lib/mate-polkit/polkit-mate-authentication-agent-1")
            assert_contains(polkit_unit, "ExecStart=/usr/lib/mate-polkit/polkit-mate-authentication-agent-1")
            assert_contains(fcitx_unit, "ConditionFileIsExecutable=/usr/bin/fcitx5")
            assert_contains(fcitx_unit, "ExecStart=/usr/bin/fcitx5\n")
            assert_true(not fcitx_unit:find(" -d", 1, true), "fcitx5 must run in foreground without -d")

            -- Extract and test ExecCondition shell snippets
            local polkit_cond = assert(polkit_unit:match("ExecCondition=:?/usr/bin/sh %-c '([^']+)'"))
            local fcitx_cond = assert(fcitx_unit:match("ExecCondition=:?/usr/bin/sh %-c '([^']+)'"))
            assert_true(not os.execute("KAZE_ENABLE_POLKIT='' /bin/sh -c " .. q(polkit_cond)), "polkit skipped when minimal")
            assert_true(os.execute("KAZE_ENABLE_POLKIT='1' /bin/sh -c " .. q(polkit_cond)), "polkit runs when full")
            assert_true(not os.execute("KAZE_ENABLE_FCITX5='' /bin/sh -c " .. q(fcitx_cond)), "fcitx5 skipped when minimal")
            assert_true(os.execute("KAZE_ENABLE_FCITX5='1' /bin/sh -c " .. q(fcitx_cond)), "fcitx5 runs when full")

            -- Extract and test ExecStartPre profile seeding (unnest systemd %% -> %)
            local seed_raw = assert(fcitx_unit:match("ExecStartPre=:?/usr/bin/sh %-c '([^']+)'"))
            local seed_sh = seed_raw:gsub("%%%%", "%%")
            local cfg_dir = tmp .. "/cfg"
            assert_true(os.execute("HOME=" .. q(tmp) .. " XDG_CONFIG_HOME=" .. q(cfg_dir) .. " /bin/sh -c " .. q(seed_sh)))
            local seeded = assert(fs.read_file(cfg_dir .. "/fcitx5/profile"))
            assert_contains(seeded, "Name=keyboard-us", "seeds keyboard-us")
            assert_contains(seeded, "Name=bamboo", "seeds bamboo")

            -- Existing user fcitx5 profile must never be overwritten
            local custom_profile = "# user custom fcitx5 profile (VNI)\n"
            fs.write_atomic(cfg_dir .. "/fcitx5/profile", custom_profile)
            assert_true(os.execute("HOME=" .. q(tmp) .. " XDG_CONFIG_HOME=" .. q(cfg_dir) .. " /bin/sh -c " .. q(seed_sh)))
            assert_eq(fs.read_file(cfg_dir .. "/fcitx5/profile"), custom_profile, "existing fcitx5 profile preserved")
        end)
        rm_rf(tmp)
        if not ok_test then error(err_test, 0) end
    end)

    test("kaze-doctor: minimal vs full binary gating, symlink checks, and passive live-session checks", function()
        local tmp = make_tmp_dir()
        local ok_test, err_test = pcall(function()
            local stub_bin = tmp .. "/bin"
            local home = tmp .. "/home"
            local cfg = tmp .. "/cfg"
            local data = tmp .. "/data"
            local runtime = tmp .. "/runtime"
            fs.mkdir_p(stub_bin)
            fs.mkdir_p(home)
            fs.mkdir_p(cfg .. "/kaze")
            fs.mkdir_p(data)
            fs.mkdir_p(runtime)

            link_host_bin(stub_bin, "lua")
            local minimal_bins = {
                "hyprland", "hyprctl", "hypridle", "hyprlock",
                "waybar", "swaybg", "fuzzel", "fnott", "notify-send",
                "foot", "footclient", "wl-copy", "wl-paste", "cliphist",
                "grim", "slurp", "wpctl", "brightnessctl", "playerctl",
                "busctl", "systemctl", "flock",
            }
            for _, b in ipairs(minimal_bins) do
                write_stub(stub_bin, b, "exit 0")
            end

            local base_env = string.format(
                "HOME=%s XDG_CONFIG_HOME=%s XDG_DATA_HOME=%s XDG_RUNTIME_DIR=%s LANG=en_US.UTF-8 LC_ALL='' KAZE_POLKIT_AGENT=%s PATH=%s",
                q(home), q(cfg), q(data), q(runtime), q(tmp .. "/polkit-agent"), q(stub_bin)
            )
            local doctor = q(repo_dir .. "/bin/kaze-doctor")

            -- 1. Minimal offline passes even when all full-only tools are absent from PATH
            local min_out, min_ok = read_all(base_env .. " " .. doctor .. " --offline --profile minimal 2>&1")
            assert_true(min_ok, "kaze-doctor --offline --profile minimal should pass:\n" .. min_out)
            assert_contains(min_out, "[OK]   profile: minimal", "reports minimal profile")
            assert_contains(min_out, "[OK]   binaries (minimal):", "minimal binaries OK")
            assert_contains(min_out, "Secret Service", "opt-in footer: Secret Service")
            assert_contains(min_out, "mpris-proxy", "opt-in footer: mpris-proxy")
            assert_contains(min_out, "udisks2", "opt-in footer: udisks2")
            assert_true(not min_out:find("[FAIL]", 1, true), "zero FAIL in minimal")

            -- 2. Full offline fails clearly when full-profile binaries are missing
            fs.write_atomic(cfg .. "/kaze/state.lua", 'return {\n    profile = "full",\n}\n')
            local fail_out, fail_ok = read_all(base_env .. " " .. doctor .. " --offline 2>&1")
            assert_true(not fail_ok, "kaze-doctor --offline must fail when full binaries are missing")
            assert_contains(fail_out, "[FAIL] binaries (full): missing:", "reports missing full binaries")
            assert_contains(fail_out, "fcitx5", "names missing fcitx5")
            assert_contains(fail_out, "swappy", "names missing swappy")

            -- 3. Stub full binaries + polkit agent -> full offline passes
            for _, b in ipairs({ "swappy", "wf-recorder", "ffprobe", "hyprpicker", "hyprsunset", "matugen", "yazi", "fcitx5" }) do
                write_stub(stub_bin, b, "exit 0")
            end
            write_stub(tmp, "polkit-agent", "exit 0")
            local full_out, full_ok = read_all(base_env .. " " .. doctor .. " --offline 2>&1")
            assert_true(full_ok, "kaze-doctor --offline in full must pass once full binaries exist:\n" .. full_out)
            assert_contains(full_out, "[OK]   binaries (full):", "full binaries OK")

            -- 4. Broken symlink must fail even in --offline mode
            fs.mkdir_p(cfg .. "/systemd/user")
            assert_true(os.execute("ln -s -- /nonexistent/kaze-target " .. q(cfg .. "/systemd/user/kaze-broken.service")))
            local brk_out, brk_ok = read_all(base_env .. " " .. doctor .. " --offline 2>&1")
            assert_true(not brk_ok, "broken symlink must fail kaze-doctor --offline")
            assert_contains(brk_out, "[FAIL] symlinks: broken symlink(s):", "reports broken symlink")
            os.remove(cfg .. "/systemd/user/kaze-broken.service")

            -- 5. Deploy symlinks and test live session checks (passive portal + singleton PIDs)
            local sys_env = string.format(
                "HOME=%s XDG_CONFIG_HOME=%s XDG_DATA_HOME=%s XDG_RUNTIME_DIR=%s HYPRLAND_INSTANCE_SIGNATURE='' WAYLAND_DISPLAY=''",
                q(home), q(cfg), q(data), q(runtime)
            )
            assert_true(os.execute(sys_env .. " " .. q(repo_dir .. "/scripts/install.sh") .. " --profile full --skip-packages --yes >/dev/null 2>&1"))

            link_host_bin(stub_bin, "id")
            write_stub(stub_bin, "hyprctl", [[
if [ "$1" = configerrors ]; then
    [ "${INJECT_CFG_ERR:-0}" = 0 ] || printf 'invalid field\n'
    exit 0
fi
exit 2
]])
            write_stub(stub_bin, "systemctl", [[
case "$*" in
  '--user show-environment')
    printf 'WAYLAND_DISPLAY=wayland-1\nHYPRLAND_INSTANCE_SIGNATURE=sig-live\nXDG_CURRENT_DESKTOP=Hyprland\n' ;;
  '--user is-active --quiet pipewire.service'|'--user is-active --quiet wireplumber.service')
    exit 0 ;;
  *) exit 2 ;;
esac
]])
            write_stub(stub_bin, "busctl", [[
printf '%s\n' "$*" >> "$HOME/busctl-calls"
if [ "$*" = '--user --activatable' ]; then
    printf 'org.freedesktop.portal.Desktop               - - - (activatable) - -\n'
    printf 'org.freedesktop.impl.portal.desktop.hyprland - - - (activatable) - -\n'
    printf 'org.freedesktop.impl.portal.desktop.gtk      - - - (activatable) - -\n'
    exit 0
fi
exit 2
]])
            write_stub(stub_bin, "ps", [[
printf '%s\n' \
  '  101 waybar          /usr/bin/waybar' \
  '  102 swaybg          /usr/bin/swaybg -c #111318' \
  '  103 foot            /usr/bin/foot --server=3' \
  '  104 fnott           /usr/bin/fnott' \
  '  105 hypridle        /usr/bin/hypridle' \
  '  106 wl-paste        /usr/bin/wl-paste --type text --watch kaze-clipboard store' \
  '  107 wl-paste        /usr/bin/wl-paste --type image --watch kaze-clipboard store' \
  '  108 polkit-mate-aut /usr/lib/mate-polkit/polkit-mate-authentication-agent-1' \
  '  109 fcitx5          /usr/bin/fcitx5'
if [ "${DUP_WAYBAR:-0}" = 1 ]; then
    printf '  199 waybar          /usr/bin/waybar\n'
fi
]])

            local live_env = base_env .. " HYPRLAND_INSTANCE_SIGNATURE=sig-live WAYLAND_DISPLAY=wayland-1"
            local live_out, live_ok = read_all(live_env .. " " .. doctor .. " 2>&1")
            assert_true(live_ok, "live full kaze-doctor should pass:\n" .. live_out)
            assert_eq(fs.read_file(home .. "/busctl-calls"), "--user --activatable\n", "portal check must strictly be passive")
            assert_contains(live_out, "[OK]   daemons (full):", "singleton daemons verified including truncated polkit comm")

            local dup_out, dup_ok = read_all(live_env .. " DUP_WAYBAR=1 " .. doctor .. " 2>&1")
            assert_true(not dup_ok, "duplicate waybar PID must fail kaze-doctor")
            assert_contains(dup_out, "waybar (expected 1, got 2)", "reports duplicate waybar")
        end)
        rm_rf(tmp)
        if not ok_test then error(err_test, 0) end
    end)

    test("power_profile, kaze-tui, and kaze-menu: standalone iwd -> impala vs NM -> nmtui, and zero-Python busctl power profiles", function()
        local tmp = make_tmp_dir()
        local ok_test, err_test = pcall(function()
            local stub_bin = tmp .. "/bin"
            local home = tmp .. "/home"
            fs.mkdir_p(stub_bin)
            fs.mkdir_p(home)
            link_host_bin(stub_bin, "lua")
            link_host_bin(stub_bin, "readlink")
            link_host_bin(stub_bin, "cat")
            write_stub(stub_bin, "pgrep", "exit 1")
            write_stub(stub_bin, "fuzzel", [[
cat > "$HOME/fuzzel-items"
printf '%s\n' "${FUZZEL_PICK:-}"
]])
            write_stub(stub_bin, "impala", "exit 0")
            write_stub(stub_bin, "nmtui", "exit 0")
            write_stub(stub_bin, "systemctl", [[
case "$*" in
  'is-active --quiet iwd.service') [ "${IWD_ACTIVE:-0}" = 1 ] ;;
  'is-active --quiet NetworkManager.service') [ "${NM_ACTIVE:-0}" = 1 ] ;;
  'is-active --quiet tlp.service') [ "${TLP_ACTIVE:-0}" = 1 ] ;;
  *) exit 1 ;;
esac
]])
            write_stub(stub_bin, "busctl", [[
printf '%s\n' "$*" >> "$HOME/busctl-log"
case "$*" in
  '--system --auto-start=no --timeout=1s get-property org.freedesktop.UPower.PowerProfiles /org/freedesktop/UPower/PowerProfiles org.freedesktop.UPower.PowerProfiles ActiveProfile')
    [ "${PPD_ACTIVE:-0}" = 1 ] || exit 1
    printf 's "balanced"\n' ;;
  '--system --auto-start=no --timeout=1s get-property org.freedesktop.UPower.PowerProfiles /org/freedesktop/UPower/PowerProfiles org.freedesktop.UPower.PowerProfiles Profiles')
    [ "${PPD_ACTIVE:-0}" = 1 ] || exit 1
    printf 'aa{sv} 3 2 "Profile" s "performance" "Driver" s "platform" 2 "Profile" s "balanced" "Driver" s "platform" 2 "Profile" s "power-saver" "Driver" s "platform"\n' ;;
  '--system --auto-start=no --timeout=2s set-property org.freedesktop.UPower.PowerProfiles /org/freedesktop/UPower/PowerProfiles org.freedesktop.UPower.PowerProfiles ActiveProfile s performance')
    [ "${PPD_ACTIVE:-0}" = 1 ] || exit 1
    printf 'performance\n' > "$HOME/ppd-set" ;;
  *) exit 1 ;;
esac
]])

            local function eval_lua(vars, code)
                local cmd = string.format(
                    "HOME=%s PATH=%s %s lua -e %s",
                    q(home), q(stub_bin), vars,
                    q("package.path=" .. q(repo_dir .. "/lua/?.lua;" .. repo_dir .. "/lua/?/init.lua;") .. "..package.path; " .. code)
                )
                local out, ok = read_all(cmd)
                assert_true(ok, "lua snippet failed: " .. out)
                return out:gsub("[\r\n]+$", "")
            end

            -- Wi-Fi backend selection: standalone iwd -> impala; NetworkManager -> nmtui
            assert_eq(
                eval_lua("IWD_ACTIVE=1 NM_ACTIVE=0", "local pp=require('kaze.power_profile'); local b,t=pp.wifi_tool(); print(b..'|'..t)"),
                "impala|Network (impala)",
                "standalone iwd selects impala"
            )
            assert_eq(
                eval_lua("IWD_ACTIVE=1 NM_ACTIVE=1", "local pp=require('kaze.power_profile'); local b,t=pp.wifi_tool(); print(b..'|'..t)"),
                "nmtui|Network (nmtui)",
                "NM + iwd backend still selects nmtui"
            )
            assert_eq(
                eval_lua("IWD_ACTIVE=0 NM_ACTIVE=1", "local pp=require('kaze.power_profile'); local b,t=pp.wifi_tool(); print(b..'|'..t)"),
                "nmtui|Network (nmtui)",
                "NM selects nmtui"
            )

            -- Power profile hidden when TLP is active, even if PPD D-Bus stub is up
            assert_eq(
                eval_lua("TLP_ACTIVE=1 PPD_ACTIVE=1", "print(tostring(require('kaze.power_profile').available()))"),
                "false",
                "TLP active disables power_profile"
            )
            local menu_tlp_cmd = string.format(
                "HOME=%s PATH=%s IWD_ACTIVE=1 NM_ACTIVE=0 TLP_ACTIVE=1 PPD_ACTIVE=1 %s",
                q(home), q(stub_bin), q(repo_dir .. "/bin/kaze-menu")
            )
            assert_true(os.execute(menu_tlp_cmd))
            local items_tlp = assert(fs.read_file(home .. "/fuzzel-items"))
            assert_contains(items_tlp, "Wi-Fi (impala)", "menu shows Wi-Fi (impala) for standalone iwd")
            assert_contains(items_tlp, "System Doctor", "menu shows System Doctor")
            assert_true(not items_tlp:find("Power Profile", 1, true), "Power Profile hidden when tlp is active")

            -- Power profile active when TLP is inactive and UPower.PowerProfiles responds
            assert_eq(
                eval_lua("TLP_ACTIVE=0 PPD_ACTIVE=1", "local pp=require('kaze.power_profile'); print(tostring(pp.available())..'|'..tostring(pp.current())..'|'..table.concat(pp.list(),','))"),
                "true|balanced|power-saver,balanced,performance",
                "UPower.PowerProfiles detected and ordered"
            )
            local menu_ppd_cmd = string.format(
                "HOME=%s PATH=%s IWD_ACTIVE=0 NM_ACTIVE=1 TLP_ACTIVE=0 PPD_ACTIVE=1 %s",
                q(home), q(stub_bin), q(repo_dir .. "/bin/kaze-menu")
            )
            assert_true(os.execute(menu_ppd_cmd))
            local items_ppd = assert(fs.read_file(home .. "/fuzzel-items"))
            assert_contains(items_ppd, "Wi-Fi (nmtui)", "menu shows Wi-Fi (nmtui)")
            assert_contains(items_ppd, "Power Profile", "menu shows Power Profile when active")

            -- Picking performance via kaze-tui power-profile calls busctl set-property
            local tui_ppd_cmd = string.format(
                "HOME=%s PATH=%s TLP_ACTIVE=0 PPD_ACTIVE=1 FUZZEL_PICK='performance' HYPRLAND_INSTANCE_SIGNATURE='' WAYLAND_DISPLAY='' %s power-profile",
                q(home), q(stub_bin), q(repo_dir .. "/bin/kaze-tui")
            )
            assert_true(os.execute(tui_ppd_cmd))
            local ppd_menu = assert(fs.read_file(home .. "/fuzzel-items"))
            assert_contains(ppd_menu, "balanced (active)", "marks active profile")
            assert_eq(fs.read_file(home .. "/ppd-set"), "performance\n", "sets ActiveProfile via busctl")
        end)
        rm_rf(tmp)
        if not ok_test then error(err_test, 0) end
    end)
end

if arg and arg[0] and arg[0]:match("test_stage3_profile_doctor%.lua$") and select("#", ...) == 0 then
    local script_dir = arg[0]:match("^(.*)/[^/]+$") or "tests"
    local repo_dir = script_dir .. "/.."
    local passed, failed = 0, 0

    local function test(name, fn)
        local ok, err = pcall(fn)
        if ok then
            passed = passed + 1
            io.stdout:write(string.format("  [PASS] %s\n", name))
        else
            failed = failed + 1
            io.stderr:write(string.format("  [FAIL] %s: %s\n", name, tostring(err)))
        end
    end

    local function assert_eq(actual, expected, msg)
        if actual ~= expected then
            error(string.format("%s: expected %s, got %s", msg or "mismatch", tostring(expected), tostring(actual)), 2)
        end
    end

    local function assert_true(cond, msg)
        if not cond then
            error(msg or "assertion failed", 2)
        end
    end

    local function assert_contains(haystack, needle, msg)
        if not haystack:find(needle, 1, true) then
            error(string.format("%s: missing %q", msg or "substring check", needle), 2)
        end
    end

    io.stdout:write("Running Stage 3 Slice C (profile, units, power_profile, doctor) tests...\n")
    run_suite(test, assert_eq, assert_true, assert_contains, repo_dir)
    io.stdout:write(string.format("\nSummary: %d passed, %d failed\n", passed, failed))
    if failed > 0 then
        os.exit(1)
    end
end

return run_suite
