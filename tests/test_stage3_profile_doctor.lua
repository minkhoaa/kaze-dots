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
            assert_contains(min_out, "  zsh\n", "minimal includes zsh")
            assert_contains(min_out, "  zsh-autosuggestions\n", "minimal includes zsh-autosuggestions")
            assert_contains(min_out, "  zsh-syntax-highlighting\n", "minimal includes zsh-syntax-highlighting")
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
            for _, pkg in ipairs({
                "noctalia", "slurp", "wf-recorder", "ffmpeg", "hyprpicker",
                "yazi", "fcitx5", "fcitx5-bamboo",
                "fzf", "zoxide", "eza", "bat", "ripgrep", "fd", "starship", "wl-mirror",
            }) do
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
            local user_zsh = cfg .. "/zsh/user.zsh"
            local zprof_local = cfg .. "/zsh/zprofile.local"
            local prof_file = cfg .. "/kaze/profile"
            fs.write_atomic(user_lua, "return { browser = 'firefox' } -- user marker\n")
            fs.write_atomic(user_zsh, "# user zsh marker\n")
            fs.write_atomic(zprof_local, "# user zprofile marker\n")
            fs.write_atomic(cfg .. "/noctalia/config.toml", "# pre-existing user noctalia\n")

            local env = string.format(
                "HOME=%s XDG_CONFIG_HOME=%s XDG_DATA_HOME=%s XDG_CACHE_HOME=%s XDG_RUNTIME_DIR=%s HYPRLAND_INSTANCE_SIGNATURE='' WAYLAND_DISPLAY=''",
                q(home), q(cfg), q(data), q(cache), q(runtime)
            )
            local installer = q(repo_dir .. "/scripts/install.sh")

            local out, ok = read_all(env .. " " .. installer .. " --profile full --skip-packages --yes 2>&1")
            assert_true(ok, "install.sh failed: " .. out)
            assert_eq(fs.read_file(user_lua), "return { browser = 'firefox' } -- user marker\n")
            assert_eq(fs.read_file(user_zsh), "# user zsh marker\n")
            assert_eq(fs.read_file(zprof_local), "# user zprofile marker\n")

            for _, link_path in ipairs({
                cfg .. "/systemd/user/kaze-noctalia.service",
                cfg .. "/systemd/user/kaze-fcitx5.service",
                cfg .. "/foot/foot.ini",
                cfg .. "/starship.toml",
                home .. "/.zshrc",
                home .. "/.zprofile",
                cfg .. "/zsh/conf.d",
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
            assert_eq(fs.read_file(user_zsh), "# user zsh marker\n")
            assert_eq(fs.read_file(zprof_local), "# user zprofile marker\n")
            assert_eq(fs.read_file(cfg .. "/noctalia/config.toml"), "# pre-existing user noctalia\n")
            for _, gone in ipairs({
                cfg .. "/systemd/user/kaze-noctalia.service",
                cfg .. "/systemd/user/kaze-fcitx5.service",
                cfg .. "/foot/foot.ini",
                cfg .. "/starship.toml",
                home .. "/.zshrc",
                home .. "/.zprofile",
                cfg .. "/zsh/conf.d",
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
            write_stub(stub_bin, "zsh", [[
if [ "${1:-}" = "-n" ] && [ -n "${2:-}" ]; then
    printf '%s\n' "$2" >> "$HOME/zsh-checked"
fi
exit 0
]])

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
            assert_contains(live_out, "[OK]   zsh: ~/.zshrc, ~/.zprofile, and conf.d/*.zsh validated cleanly")
            assert_contains(live_out, "[OK]   daemons (minimal):")
            local checked_zsh = assert(fs.read_file(home .. "/zsh-checked"))
            assert_contains(checked_zsh, home .. "/.zshrc\n")
            assert_contains(checked_zsh, home .. "/.zprofile\n")
            assert_contains(checked_zsh, cfg .. "/zsh/conf.d/10-options.zsh\n")
            assert_contains(checked_zsh, cfg .. "/zsh/conf.d/60-prompt.zsh\n")

            local full_miss_out, full_miss_ok = read_all(base_env .. " " .. doctor .. " --offline --profile full 2>&1")
            assert_true(not full_miss_ok, "full offline doctor must fail when full binaries are missing")
            assert_contains(full_miss_out, "fzf, zoxide, eza, bat, rg, fd, starship, wl-mirror")

            for _, b in ipairs({
                "slurp", "wf-recorder", "ffprobe", "hyprpicker",
                "yazi", "imv", "zathura", "gnome-keyring-daemon", "fcitx5",
                "fzf", "zoxide", "eza", "bat", "rg", "fd", "starship", "wl-mirror",
            }) do
                write_stub(stub_bin, b, "exit 0")
            end
            local full_ok_out, full_ok = read_all(base_env .. " " .. doctor .. " --offline --profile full 2>&1")
            assert_true(full_ok, "full offline doctor pass with all binaries:\n" .. full_ok_out)
            assert_contains(full_ok_out, "[OK]   binaries (full): all full-profile tools found")

            local dup_out, dup_ok = read_all(live_env .. " DUP_NOC=1 " .. doctor .. " 2>&1")
            assert_true(not dup_ok, "duplicate noctalia PID must fail doctor")
            assert_contains(dup_out, "noctalia (expected 1, got 2)")
        end)
        rm_rf(tmp)
        if not ok_test then error(err_test, 0) end
    end)

    test("kaze-display: monitor/workspace parsers, hl.monitor planner, safety rules, and CLI workflows", function()
        local display = require("kaze.display")
        local json = require("kaze.json")

        local mons = display.parse_monitors([[
[
  {"id":0,"name":"eDP-1","description":"Built-in Panel","width":1920,"height":1080,"x":0,"y":0,"refreshRate":60.0,"scale":1.0,"disabled":false,"focused":true,"mirrorOf":"none","activeWorkspace":{"id":1,"name":"1"},"hardwareDetails":{"backend":"drm"}},
  {"id":1,"name":"HDMI-A-1","description":"External 4K","width":2560,"height":1440,"x":1920,"y":0,"refreshRate":144.0,"scale":1.0,"disabled":false,"focused":false,"mirrorOf":"none","activeWorkspace":{"id":3,"name":"3"},"hardwareDetails":{"backend":"drm"}},
  {"id":2,"name":"kaze-share","description":"Headless","width":1920,"height":1080,"x":9999,"y":0,"refreshRate":60.0,"scale":1.0,"disabled":false,"focused":false,"mirrorOf":"none","activeWorkspace":{"id":9,"name":"9"},"hardwareDetails":{"backend":"headless"}},
  {"id":3,"name":"HEADLESS-2","description":"Other Headless","width":1280,"height":720,"x":12000,"y":0,"refreshRate":60.0,"scale":1.0,"disabled":false,"focused":false,"mirrorOf":"none","hardwareDetails":{"backend":"headless"}}
]
]])
        assert_eq(#mons, 4)
        local internal, externals, virtuals = display.pick_roles(mons)
        assert_eq(internal.name, "eDP-1")
        assert_eq(#externals, 1)
        assert_eq(externals[1].name, "HDMI-A-1")
        assert_eq(#virtuals, 2)
        assert_true(display.is_virtual_monitor("kaze-share"))
        assert_true(display.is_virtual_monitor("HEADLESS-1"))
        assert_true(not display.is_virtual_monitor("HDMI-A-1"))

        -- Workspace parser, clean workspace selector, and formatter
        local wss = display.parse_workspaces(
            '[{"id":-99,"name":"special:scratch","monitor":"eDP-1","windows":1},{"id":1,"name":"1","monitor":"eDP-1","windows":2},{"id":2,"name":"2","monitor":"HDMI-A-1","windows":1}]',
            '[{"address":"0x1","class":"firefox","workspace":{"id":1}},{"address":"0x2","class":"foot","workspace":{"id":1}},{"address":"0x3","class":"firefox","workspace":{"id":1}},{"address":"0x4","class":"mpv","workspace":{"id":2}}]'
        )
        assert_eq(#wss, 2)
        assert_eq(wss[1].id, 1)
        assert_eq(#wss[1].apps, 2)
        assert_eq(display.format_workspace_entry(wss[1]), "WS 1  [firefox, foot]  (on eDP-1)")
        assert_eq(display.format_workspace_entry({ id = 9, windows = 0, apps = {} }), "WS 9  [new empty workspace]")
        local clean_ws = display.pick_clean_workspace_id(wss)
        assert_true(clean_ws ~= 1 and clean_ws ~= 2, "clean ws must avoid active workspaces")

        -- Planner generates valid Lua hl.monitor(...) calls for every mode
        local function assert_valid_lua_plan(p)
            assert_true(type(p.eval_cmds) == "table" and #p.eval_cmds >= 1)
            for _, expr in ipairs(p.eval_cmds) do
                assert_true(load(expr) ~= nil, "invalid Lua expr: " .. expr)
            end
        end

        local p_ext = assert(display.plan("extend-right", mons))
        assert_valid_lua_plan(p_ext)
        assert_eq(p_ext.needs_reload, false)
        assert_contains(p_ext.eval_cmds[1], 'output = "eDP-1"')
        assert_contains(p_ext.eval_cmds[1], 'position = "0x0"')
        assert_contains(p_ext.eval_cmds[2], 'output = "HDMI-A-1"')
        assert_contains(p_ext.eval_cmds[2], 'position = "auto-right"')

        for _, mode_name in ipairs({ "extend-left", "extend-up", "external", "internal", "auto", "present", "mirror-scaled" }) do
            local p = assert(display.plan(mode_name, mons))
            assert_valid_lua_plan(p)
        end

        local p_int = assert(display.plan("internal", mons))
        assert_contains(p_int.eval_cmds[2], "disabled = true")
        local p_mir = assert(display.plan("mirror", mons))
        assert_valid_lua_plan(p_mir)
        assert_contains(p_mir.eval_cmds[2], 'mirror = "eDP-1"')
        assert_true(not p_mir.eval_cmds[2]:find("kaze-share", 1, true), "mirror must never target kaze-share")

        local p_vs = assert(display.plan("virtual-share", { mons[1] }))
        assert_valid_lua_plan(p_vs)
        assert_contains(p_vs.eval_cmds[1], 'output = "eDP-1"')
        assert_contains(p_vs.eval_cmds[1], 'position = "0x0"')
        assert_contains(p_vs.eval_cmds[2], 'output = "kaze-share"')
        assert_contains(p_vs.eval_cmds[2], 'mode = "1920x1080@60"')
        assert_contains(p_vs.eval_cmds[2], 'position = "9999x0"')

        -- Reload required when exiting mirror mode
        local mirrored_mons = display.parse_monitors([[
[
  {"name":"eDP-1","width":1920,"height":1080,"scale":1.0,"disabled":false,"mirrorOf":"none"},
  {"name":"HDMI-A-1","width":1920,"height":1080,"scale":1.0,"disabled":false,"mirrorOf":"eDP-1"}
]
]])
        local p_unmirror = assert(display.plan("extend-right", mirrored_mons))
        assert_eq(p_unmirror.needs_reload, true, "exiting active mirror requires hyprctl reload")

        -- 5 safety rules
        assert_true(display.should_ignore_hotplug("kaze-share", { now = 100, started_at = 0 }))
        assert_true(display.should_ignore_hotplug("HEADLESS-1", { now = 100, started_at = 0 }))
        assert_true(display.should_ignore_hotplug("HDMI-A-1", { now = 100, started_at = 0, enabled = false }))
        assert_true(display.should_ignore_hotplug("HDMI-A-1", { now = 100, started_at = 0, locked = true }))
        assert_true(display.should_ignore_hotplug("HDMI-A-1", { now = 103, started_at = 100 }))
        assert_true(display.should_ignore_hotplug("HDMI-A-1", { now = 110, started_at = 100, last_event_at = 109.5 }))
        assert_true(not display.should_ignore_hotplug("HDMI-A-1", { now = 110, started_at = 100, last_event_at = 108 }))

        assert_true(display.should_restore_dnd({ dnd_managed = true, dnd_was_active = false }))
        assert_true(not display.should_restore_dnd({ dnd_managed = true, dnd_was_active = true }))
        assert_true(not display.should_restore_dnd({ dnd_managed = false, dnd_was_active = false }))

        local rec_ignored = display.plan_disconnect_recovery("kaze-share", mons, { external_monitor = "HDMI-A-1" })
        assert_eq(rec_ignored.ignored, true)

        local ext_only_mons = display.parse_monitors([[
[
  {"name":"eDP-1","width":1920,"height":1080,"scale":1.0,"disabled":true},
  {"name":"HDMI-A-1","width":2560,"height":1440,"scale":1.0,"disabled":false}
]
]])
        local rec_black = display.plan_disconnect_recovery("HDMI-A-1", ext_only_mons, {
            mode = "external",
            external_monitor = "HDMI-A-1",
        })
        assert_eq(rec_black.recover_internal, true)
        assert_contains(rec_black.eval_cmds[1], 'output = "eDP-1"')
        assert_contains(rec_black.eval_cmds[1], 'position = "0x0"')

        -- CLI integration tests with stubs
        local tmp = make_tmp_dir()
        local ok_cli, err_cli = pcall(function()
            local stub_bin = tmp .. "/bin"
            local home, cfg, data, cache, runtime = tmp .. "/home", tmp .. "/cfg", tmp .. "/data", tmp .. "/cache", tmp .. "/runtime"
            for _, d in ipairs({ stub_bin, home, cfg, data, cache, runtime }) do fs.mkdir_p(d) end
            for _, b in ipairs({ "lua", "readlink", "nohup", "rm", "mkdir", "kill", "cat", "id", "install", "sleep" }) do
                link_host_bin(stub_bin, b)
            end
            write_stub(stub_bin, "wl-mirror", [[
printf '%s\n' "$*" >> "$HOME/wlmirror-calls"
trap 'kill "${child:-0}" 2>/dev/null || true; exit 0' TERM
sleep 30 &
child=$!
wait "$child"
]])
            write_stub(stub_bin, "notify-send", "exit 0")
            write_stub(stub_bin, "loginctl", [[
if [ "${2:-}" = "s1" ] && [ "${3:-}" = "-p" ] && [ "${4:-}" = "LockedHint" ]; then
    printf '%s\n' "${TEST_LOCKED:-no}"
fi
]])
            write_stub(stub_bin, "noctalia", [[
if [ "$1" = "msg" ] && [ "$2" = "notification-dnd-status" ]; then
    printf '%s\n' "${TEST_DND:-off}"
    exit 0
fi
printf '%s\n' "$*" >> "$HOME/noc-calls"
]])
            write_stub(stub_bin, "hyprctl", [[
if [ "$1" = "-j" ] && [ "$2" = "monitors" ]; then
    cat "$HOME/mock-monitors.json"
elif [ "$1" = "-j" ] && [ "$2" = "workspaces" ]; then
    cat "$HOME/mock-workspaces.json"
elif [ "$1" = "-j" ] && [ "$2" = "clients" ]; then
    cat "$HOME/mock-clients.json"
elif [ "$1" = "-j" ] && [ "$2" = "activewindow" ]; then
    cat "$HOME/mock-activewindow.json"
elif [ "$1" = "-j" ] && [ "$2" = "layers" ]; then
    if [ -n "${TEST_LAYERS:-}" ]; then
        printf '%s\n' "$TEST_LAYERS"
    else
        printf '{}\n'
    fi
else
    printf '%s\n' "$*" >> "$HOME/hypr-calls"
fi
]])
            fs.write_atomic(home .. "/mock-monitors.json", [[
[
  {"id":0,"name":"eDP-1","width":1920,"height":1080,"x":0,"y":0,"refreshRate":60.0,"scale":1.0,"disabled":false,"focused":true,"mirrorOf":"none","activeWorkspace":{"id":1,"name":"1"}},
  {"id":1,"name":"HDMI-A-1","width":2560,"height":1440,"x":1920,"y":0,"refreshRate":144.0,"scale":1.0,"disabled":false,"focused":false,"mirrorOf":"none","activeWorkspace":{"id":2,"name":"2"}}
]
]])
            fs.write_atomic(home .. "/mock-workspaces.json", '[{"id":1,"name":"1","monitor":"eDP-1","windows":1},{"id":3,"name":"3","monitor":"eDP-1","windows":1}]')
            fs.write_atomic(home .. "/mock-clients.json", '[{"address":"0xabc","class":"firefox","workspace":{"id":3}}]')
            fs.write_atomic(home .. "/mock-activewindow.json", '{"address":"0xdef","monitor":0,"workspace":{"id":1}}')

            local cli_env = string.format(
                "HOME=%s XDG_CONFIG_HOME=%s XDG_DATA_HOME=%s XDG_CACHE_HOME=%s XDG_RUNTIME_DIR=%s XDG_SESSION_ID=s1 PATH=%s",
                q(home), q(cfg), q(data), q(cache), q(runtime), q(stub_bin)
            )
            local kdisplay = q(repo_dir .. "/bin/kaze-display")

            -- 1. --hotplug ignored silently when locked (loginctl or Noctalia lock layer), opens dmenu when unlocked
            local _, lock_ok = read_all(cli_env .. " TEST_LOCKED=yes " .. kdisplay .. " --hotplug HDMI-A-1 2>&1")
            assert_true(lock_ok, "--hotplug should exit 0 silently when locked")
            assert_true(not fs.file_exists(home .. "/noc-calls"), "locked hotplug must not invoke noctalia dmenu")

            local _, layer_lock_ok = read_all(cli_env .. ' TEST_LAYERS=\'{"eDP-1":{"levels":{"3":[{"namespace":"noctalia-lockscreen"}]}}}\' ' .. kdisplay .. " --hotplug HDMI-A-1 2>&1")
            assert_true(layer_lock_ok, "--hotplug should exit 0 silently on Noctalia lock layer")
            assert_true(not fs.file_exists(home .. "/noc-calls"), "lock-layer hotplug must not invoke noctalia dmenu")

            local _, unlock_ok = read_all(cli_env .. " " .. kdisplay .. " --hotplug HDMI-A-1 2>&1")
            assert_true(unlock_ok, "unlocked --hotplug with empty dmenu choice exits 0")
            assert_contains(assert(fs.read_file(home .. "/noc-calls")), "dmenu -p Display >")
            fs.write_atomic(home .. "/noc-calls", "")

            -- 2. present + stop-present conditional DND restore
            local p_out, p_ok = read_all(cli_env .. " TEST_DND=off " .. kdisplay .. " present 3 2>&1")
            assert_true(p_ok, "present 3 failed: " .. p_out)
            local noc_log = assert(fs.read_file(home .. "/noc-calls"))
            assert_contains(noc_log, "msg bar-hide default HDMI-A-1\n")
            assert_contains(noc_log, "msg notification-dnd-set on\n")
            local hypr_log = assert(fs.read_file(home .. "/hypr-calls"))
            assert_contains(hypr_log, 'workspace.move({ workspace = "3", monitor = "HDMI-A-1" })')
            local st = json.decode(assert(fs.read_file(runtime .. "/kaze/display-state.json")))
            assert_eq(st.mode, "present")
            assert_eq(st.dnd_managed, true)
            assert_eq(st.dnd_was_active, false)

            fs.write_atomic(home .. "/noc-calls", "")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " stop-present >/dev/null 2>&1"))
            local stop_noc = assert(fs.read_file(home .. "/noc-calls"))
            assert_contains(stop_noc, "msg bar-show default HDMI-A-1\n")
            assert_contains(stop_noc, "msg notification-dnd-set off\n")

            -- 3. present when user already had DND on must NOT disable DND on stop-present
            fs.write_atomic(home .. "/noc-calls", "")
            assert_true(os.execute(cli_env .. " TEST_DND=on " .. kdisplay .. " present 3 >/dev/null 2>&1"))
            fs.write_atomic(home .. "/noc-calls", "")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " stop-present >/dev/null 2>&1"))
            local keep_noc = assert(fs.read_file(home .. "/noc-calls"))
            assert_true(not keep_noc:find("notification-dnd-set off", 1, true), "must preserve pre-existing user DND")

            -- 4. virtual-share + toggle-preview + toggle-window-share + stop-virtual ordering
            fs.write_atomic(home .. "/hypr-calls", "")
            fs.write_atomic(home .. "/noc-calls", "")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " virtual-share 9 >/dev/null 2>&1"))
            local vs_log = assert(fs.read_file(home .. "/hypr-calls"))
            assert_contains(vs_log, "output create headless kaze-share\n")
            local p_pin = assert(vs_log:find('output = "eDP-1"', 1, true))
            local p_ks = assert(vs_log:find('output = "kaze-share"', 1, true))
            assert_true(p_pin < p_ks, "primary must be pinned at 0x0 before configuring kaze-share")
            assert_contains(assert(fs.read_file(home .. "/noc-calls")), "msg bar-hide default kaze-share\n")
            local vs_st = json.decode(assert(fs.read_file(runtime .. "/kaze/display-state.json")))
            assert_eq(vs_st.bar_hidden_monitors, nil, "virtual-share must not record kaze-share in bar_hidden_monitors")

            fs.write_atomic(home .. "/mock-monitors.json", [[
[
  {"id":0,"name":"eDP-1","width":1920,"height":1080,"x":0,"y":0,"refreshRate":60.0,"scale":1.0,"disabled":false,"focused":true,"activeWorkspace":{"id":1,"name":"1"}},
  {"id":2,"name":"kaze-share","width":1920,"height":1080,"x":9999,"y":0,"refreshRate":60.0,"scale":1.0,"disabled":false,"focused":false,"activeWorkspace":{"id":9,"name":"9"},"hardwareDetails":{"backend":"headless"}}
]
]])
            fs.write_atomic(home .. "/mock-workspaces.json", '[{"id":1,"name":"1","monitor":"eDP-1","windows":1},{"id":9,"name":"9","monitor":"kaze-share","windows":1}]')
            fs.write_atomic(home .. "/mock-clients.json", '[{"address":"0xshare1","class":"foot","monitor":2,"workspace":{"id":9}}]')

            assert_true(os.execute(cli_env .. " " .. kdisplay .. " toggle-preview >/dev/null 2>&1"))
            os.execute("sleep 0.05")
            local prev_st = json.decode(assert(fs.read_file(runtime .. "/kaze/display-state.json")))
            assert_true(type(prev_st.preview_pid) == "number" and prev_st.preview_pid > 0, "toggle-preview starts wl-mirror")
            assert_contains(assert(fs.read_file(home .. "/wlmirror-calls")), "--title kaze-share-preview kaze-share\n")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " toggle-preview >/dev/null 2>&1"))
            local closed_st = json.decode(assert(fs.read_file(runtime .. "/kaze/display-state.json")))
            assert_eq(closed_st.preview_pid, nil, "second toggle-preview closes preview")

            fs.write_atomic(home .. "/hypr-calls", "")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " toggle-window-share >/dev/null 2>&1"))
            assert_contains(assert(fs.read_file(home .. "/hypr-calls")), 'window.move({ workspace = "9", silent = true })')

            fs.write_atomic(home .. "/hypr-calls", "")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " stop-virtual >/dev/null 2>&1"))
            local sv_log = assert(fs.read_file(home .. "/hypr-calls"))
            local p_win_back = assert(sv_log:find("hl.get_windows()", 1, true))
            local p_silent_move = assert(sv_log:find("silent = true", 1, true))
            local p_ws_back = assert(sv_log:find('workspace.move({ workspace = "9", monitor = "eDP-1" })', 1, true))
            local p_remove = assert(sv_log:find("output remove kaze-share", 1, true))
            assert_true(p_win_back < p_remove and p_silent_move < p_remove and p_ws_back < p_remove, "windows and workspaces must move back before output remove")

            -- 5. --on-disconnect recovers disabled eDP-1 and cleans up presentation + DND
            fs.write_atomic(home .. "/mock-monitors.json", [[
[
  {"id":0,"name":"eDP-1","width":1920,"height":1080,"x":0,"y":0,"refreshRate":60.0,"scale":1.0,"disabled":false,"focused":true,"mirrorOf":"none","activeWorkspace":{"id":1,"name":"1"}},
  {"id":1,"name":"HDMI-A-1","width":2560,"height":1440,"x":1920,"y":0,"refreshRate":144.0,"scale":1.0,"disabled":false,"focused":false,"mirrorOf":"none","activeWorkspace":{"id":2,"name":"2"}}
]
]])
            fs.write_atomic(home .. "/noc-calls", "")
            assert_true(os.execute(cli_env .. " TEST_DND=off " .. kdisplay .. " present 3 >/dev/null 2>&1"))
            fs.write_atomic(home .. "/mock-monitors.json", '[{"id":0,"name":"eDP-1","width":1920,"height":1080,"scale":1.0,"disabled":true}]')
            fs.write_atomic(home .. "/hypr-calls", "")
            fs.write_atomic(home .. "/noc-calls", "")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " --on-disconnect HDMI-A-1 >/dev/null 2>&1"))
            local disc_hypr = assert(fs.read_file(home .. "/hypr-calls"))
            assert_contains(disc_hypr, 'output = "eDP-1"')
            assert_contains(disc_hypr, 'position = "0x0"')
            assert_contains(assert(fs.read_file(home .. "/noc-calls")), "msg notification-dnd-set off\n")

            -- 6. cleanup clears display-state.json and tears down active virtual-share
            fs.write_atomic(home .. "/mock-monitors.json", [[
[
  {"id":0,"name":"eDP-1","width":1920,"height":1080,"x":0,"y":0,"refreshRate":60.0,"scale":1.0,"disabled":false,"focused":true,"activeWorkspace":{"id":1,"name":"1"}},
  {"id":2,"name":"kaze-share","width":1920,"height":1080,"x":9999,"y":0,"refreshRate":60.0,"scale":1.0,"disabled":false,"focused":false,"activeWorkspace":{"id":9,"name":"9"},"hardwareDetails":{"backend":"headless"}}
]
]])
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " virtual-share 9 >/dev/null 2>&1"))
            assert_true(fs.file_exists(runtime .. "/kaze/display-state.json"))
            fs.write_atomic(home .. "/hypr-calls", "")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " cleanup >/dev/null 2>&1"))
            assert_true(not fs.file_exists(runtime .. "/kaze/display-state.json"), "cleanup must remove state file")
            assert_contains(assert(fs.read_file(home .. "/hypr-calls")), "output remove kaze-share\n")
        end)
        rm_rf(tmp)
        if not ok_cli then error(err_cli, 0) end

        -- Hyprland execs.lua hotplug & disconnect event handler test
        local hooks, execs = {}, {}
        local fake_now = 1000
        local prev_hl, prev_ctx, prev_time = rawget(_G, "hl"), package.loaded["kaze._ctx"], os.time
        local ok_exec, err_exec = pcall(function()
            os.time = function() return fake_now end
            package.loaded["kaze._ctx"] = { cfg = { cursor_theme = "Adwaita", cursor_size = 24, display_hotplug_menu = true } }
            rawset(_G, "hl", {
                on = function(ev, fn) hooks[ev] = fn end,
                exec_cmd = function(cmd) execs[#execs + 1] = cmd end,
            })
            dofile(repo_dir .. "/hypr/execs.lua")
            hooks["hyprland.start"]()
            assert_eq(#execs, 1)

            hooks["monitor.added"]({ name = "kaze-share" })
            hooks["monitor.added"]({ name = "HDMI-A-1" }) -- < 5s startup grace
            assert_eq(#execs, 1)

            fake_now = 1006
            hooks["monitor.added"]({ name = "HDMI-A-1" })
            assert_eq(#execs, 2)
            assert_contains(execs[2], "kaze-display' --hotplug 'HDMI-A-1'")

            hooks["monitor.added"]({ name = "DP-1" }) -- < 1s debounce
            assert_eq(#execs, 2)

            hooks["monitor.removed"]({ name = "kaze-share" })
            assert_eq(#execs, 2)
            hooks["monitor.removed"]({ name = "HDMI-A-1" })
            assert_eq(#execs, 3)
            assert_contains(execs[3], "kaze-display' --on-disconnect 'HDMI-A-1'")
        end)
        os.time = prev_time
        rawset(_G, "hl", prev_hl)
        package.loaded["kaze._ctx"] = prev_ctx
        if not ok_exec then error(err_exec, 0) end
    end)
end

return run_suite
