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
        if not p then return "", false end
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

    test("install.sh: --dry-run includes noctalia, omits replaced legacy packages, and writes zero files", function()
        local tmp = make_tmp_dir()
        local ok_test, err_test = pcall(function()
            local home, cfg, data = tmp .. "/home", tmp .. "/cfg", tmp .. "/data"
            local env = string.format("HOME=%s XDG_CONFIG_HOME=%s XDG_DATA_HOME=%s", q(home), q(cfg), q(data))
            local installer = q(repo_dir .. "/scripts/install.sh")

            local min_out, min_ok = read_all(env .. " " .. installer .. " --profile minimal --dry-run 2>&1")
            assert_true(min_ok, "minimal --dry-run exit 0")
            assert_contains(min_out, "  noctalia\n", "minimal includes noctalia")
            assert_contains(min_out, "  hyprland\n", "minimal includes hyprland")
            assert_contains(min_out, "  foot\n", "minimal includes foot")
            assert_contains(min_out, "0 AUR", "zero AUR")

            local function has_word(text, word)
                local pat = "%f[%w_-]" .. word:gsub("%-", "%%-") .. "%f[^%w_-]"
                return text:find(pat) ~= nil
            end
            for _, removed in ipairs({ "waybar", "swaybg", "fuzzel", "fnott", "hypridle", "hyprlock", "cliphist", "hyprsunset", "matugen", "mate-polkit", "grim", "swappy" }) do
                assert_true(not has_word(min_out, removed), "removed package leaked into minimal: " .. removed)
            end

            local full_out, full_ok = read_all(env .. " " .. installer .. " --profile full --dry-run --yes 2>&1")
            assert_true(full_ok, "full --dry-run exit 0")
            for _, pkg in ipairs({ "noctalia", "slurp", "wf-recorder", "ffmpeg", "hyprpicker", "yazi", "fcitx5", "fcitx5-bamboo" }) do
                assert_contains(full_out, "  " .. pkg .. "\n", "full includes " .. pkg)
            end
            for _, removed in ipairs({ "waybar", "swaybg", "fuzzel", "fnott", "hypridle", "hyprlock", "cliphist", "hyprsunset", "matugen", "mate-polkit", "grim", "swappy" }) do
                assert_true(not has_word(full_out, removed), "removed package leaked into full: " .. removed)
            end

            for _, untouched in ipairs({ home, cfg, data }) do
                assert_true(os.execute("[ ! -e " .. q(untouched) .. " ] && [ ! -L " .. q(untouched) .. " ]"))
            end
            local _, bad_ok = read_all(env .. " " .. installer .. " --profile bogus --dry-run 2>&1")
            assert_true(not bad_ok)
        end)
        rm_rf(tmp)
        if not ok_test then error(err_test, 0) end
    end)

    test("install.sh: --skip-packages --yes deploys symlinks, seeds Noctalia config, persists profile, and rolls back cleanly", function()
        local tmp = make_tmp_dir()
        local ok_test, err_test = pcall(function()
            local home, cfg, data, cache, runtime = tmp .. "/home space", tmp .. "/cfg space", tmp .. "/data space", tmp .. "/cache space", tmp .. "/runtime"
            fs.mkdir_p(home)
            fs.mkdir_p(cfg .. "/hypr")
            fs.mkdir_p(runtime)

            local user_lua = cfg .. "/hypr/user.lua"
            local prof_file = cfg .. "/kaze/profile"
            fs.write_atomic(user_lua, "return { browser = 'firefox' } -- user marker\n")
            fs.write_atomic(cfg .. "/noctalia/config.toml", "# pre-existing user noctalia\n")

            local env = string.format(
                "HOME=%s XDG_CONFIG_HOME=%s XDG_DATA_HOME=%s XDG_CACHE_HOME=%s XDG_RUNTIME_DIR=%s HYPRLAND_INSTANCE_SIGNATURE='' WAYLAND_DISPLAY=''",
                q(home), q(cfg), q(data), q(cache), q(runtime)
            )
            local installer = q(repo_dir .. "/scripts/install.sh")

            local out, ok = read_all(env .. " " .. installer .. " --profile full --skip-packages --yes 2>&1")
            assert_true(ok, "install.sh failed: " .. out)
            assert_eq(fs.read_file(user_lua), "return { browser = 'firefox' } -- user marker\n")

            for _, link_path in ipairs({
                cfg .. "/systemd/user/kaze-noctalia.service",
                cfg .. "/systemd/user/kaze-fcitx5.service",
                cfg .. "/foot/foot.ini",
                home .. "/.local/bin/kaze-doctor",
                data .. "/kaze-dots/lua/kaze",
            }) do
                assert_true(os.execute("[ -L " .. q(link_path) .. " ] && [ -e " .. q(link_path) .. " ]"), "expected symlink: " .. link_path)
            end
            assert_eq(fs.read_file(prof_file), "full\n")
            assert_contains(assert(fs.read_file(cfg .. "/noctalia/config.toml")), "polkit_agent = true\n")

            local backup_dir = assert(fs.read_file(cfg .. "/kaze/last-backup")):gsub("\n$", "")
            local rb_out, rb_ok = read_all(env .. " " .. q(backup_dir .. "/rollback.sh") .. " --yes 2>&1")
            assert_true(rb_ok, "rollback failed: " .. rb_out)
            assert_eq(fs.read_file(user_lua), "return { browser = 'firefox' } -- user marker\n")
            assert_eq(fs.read_file(cfg .. "/noctalia/config.toml"), "# pre-existing user noctalia\n")
            for _, gone in ipairs({
                cfg .. "/systemd/user/kaze-noctalia.service",
                cfg .. "/systemd/user/kaze-fcitx5.service",
                cfg .. "/foot/foot.ini",
                home .. "/.local/bin/kaze-doctor",
                prof_file,
                cfg .. "/kaze/last-backup",
            }) do
                assert_true(os.execute("[ ! -e " .. q(gone) .. " ] && [ ! -L " .. q(gone) .. " ]"), "rollback must remove " .. gone)
            end
        end)
        rm_rf(tmp)
        if not ok_test then error(err_test, 0) end
    end)

    test("kaze-doctor: verifies Noctalia + Foot binaries, configs, symlinks, and singleton PIDs", function()
        local tmp = make_tmp_dir()
        local ok_test, err_test = pcall(function()
            local stub_bin, home, cfg, data, cache, runtime = tmp .. "/bin", tmp .. "/home", tmp .. "/cfg", tmp .. "/data", tmp .. "/cache", tmp .. "/runtime"
            for _, d in ipairs({ stub_bin, home, cfg .. "/kaze", data, cache, runtime }) do fs.mkdir_p(d) end

            link_host_bin(stub_bin, "lua")
            for _, b in ipairs({
                "hyprland", "hyprctl", "noctalia", "notify-send",
                "foot", "footclient", "wl-copy", "wl-paste",
                "wpctl", "brightnessctl", "playerctl",
                "busctl", "systemctl", "flock",
            }) do
                write_stub(stub_bin, b, "exit 0")
            end

            local base_env = string.format(
                "HOME=%s XDG_CONFIG_HOME=%s XDG_DATA_HOME=%s XDG_CACHE_HOME=%s XDG_RUNTIME_DIR=%s LANG=en_US.UTF-8 LC_ALL='' PATH=%s",
                q(home), q(cfg), q(data), q(cache), q(runtime), q(stub_bin)
            )
            local doctor = q(repo_dir .. "/bin/kaze-doctor")

            local min_out, min_ok = read_all(base_env .. " " .. doctor .. " --offline --profile minimal 2>&1")
            assert_true(min_ok, "minimal offline doctor pass:\n" .. min_out)
            assert_contains(min_out, "[OK]   binaries (minimal):")

            local sys_env = string.format(
                "HOME=%s XDG_CONFIG_HOME=%s XDG_DATA_HOME=%s XDG_CACHE_HOME=%s XDG_RUNTIME_DIR=%s HYPRLAND_INSTANCE_SIGNATURE='' WAYLAND_DISPLAY=''",
                q(home), q(cfg), q(data), q(cache), q(runtime)
            )
            assert_true(os.execute(sys_env .. " " .. q(repo_dir .. "/scripts/install.sh") .. " --profile minimal --skip-packages --yes >/dev/null 2>&1"))

            link_host_bin(stub_bin, "id")
            write_stub(stub_bin, "hyprctl", [[if [ "$1" = configerrors ]; then exit 0; fi; exit 2]])
            write_stub(stub_bin, "systemctl", [[
case "$*" in
  '--user show-environment')
    printf 'WAYLAND_DISPLAY=wayland-1\nHYPRLAND_INSTANCE_SIGNATURE=sig-live\nXDG_CURRENT_DESKTOP=Hyprland\n' ;;
  '--user is-active --quiet pipewire.service'|'--user is-active --quiet wireplumber.service') exit 0 ;;
  *) exit 2 ;;
esac
]])
            write_stub(stub_bin, "busctl", [[
if [ "$*" = '--user --activatable' ]; then
    printf 'org.freedesktop.portal.Desktop\norg.freedesktop.impl.portal.desktop.hyprland\norg.freedesktop.impl.portal.desktop.gtk\n'
    exit 0
fi
exit 2
]])
            write_stub(stub_bin, "ps", [[
printf '  101 noctalia /usr/bin/noctalia\n  102 foot /usr/bin/foot --server=3\n'
if [ "${DUP_NOC:-0}" = 1 ]; then printf '  199 noctalia /usr/bin/noctalia\n'; fi
]])

            local live_env = base_env .. " HYPRLAND_INSTANCE_SIGNATURE=sig-live WAYLAND_DISPLAY=wayland-1"
            local live_out, live_ok = read_all(live_env .. " " .. doctor .. " 2>&1")
            assert_true(live_ok, "live minimal doctor should pass:\n" .. live_out)
            assert_contains(live_out, "[OK]   noctalia: config.toml validated cleanly")
            assert_contains(live_out, "[OK]   foot: foot.ini validated cleanly")
            assert_contains(live_out, "[OK]   daemons (minimal):")

            local dup_out, dup_ok = read_all(live_env .. " DUP_NOC=1 " .. doctor .. " 2>&1")
            assert_true(not dup_ok, "duplicate noctalia PID must fail doctor")
            assert_contains(dup_out, "noctalia (expected 1, got 2)")
        end)
        rm_rf(tmp)
        if not ok_test then error(err_test, 0) end
    end)

    test("kaze-display: monitor parser, role selection, layout plans, and CLI execution", function()
        local display = require("kaze.display")
        local mons = display.parse_monitors([[
[
  {"name":"eDP-1","description":"Built-in Panel","width":1920,"height":1080,"refreshRate":60.0,"scale":1.0,"disabled":false,"focused":true},
  {"name":"HDMI-A-1","description":"External 4K","width":2560,"height":1440,"refreshRate":144.0,"scale":1.0,"disabled":false,"focused":false}
]
]])
        assert_eq(#mons, 2)
        local p_ext = assert(display.plan("extend-right", mons))
        assert_eq(p_ext.rules[1], "eDP-1,preferred,0x0,1")
        assert_eq(p_ext.rules[2], "HDMI-A-1,preferred,auto-right,1")
    end)
end

return run_suite
