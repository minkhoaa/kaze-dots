#!/usr/bin/env lua

local function register_tests(test, assert_eq, assert_true, assert_contains, repo_dir)
    local config = require("kaze.config")
    local defaults = require("kaze.defaults")
    local fs = require("kaze.fs")
    local keybinds_data = require("kaze.keybinds_data")
    local layouts = require("kaze.layouts")
    local themes = require("kaze.themes")

    local function make_tmp_dir()
        local d = string.format("/tmp/kaze-stage3-keys-%d-%d", os.time(), math.random(100000, 999999))
        fs.mkdir_p(d)
        return d
    end

    local function rm_rf(dir)
        os.execute("rm -rf " .. fs.shell_quote(dir))
    end

    local function with_stubs(fn)
        local tmp = make_tmp_dir()
        fs.mkdir_p(tmp .. "/bin")
        fs.mkdir_p(tmp .. "/runtime")
        local env = string.format(
            "env HOME=%s XDG_RUNTIME_DIR=%s XDG_CONFIG_HOME=%s XDG_DATA_HOME=%s XDG_CACHE_HOME=%s HYPRLAND_INSTANCE_SIGNATURE='' WAYLAND_DISPLAY='' PATH=%s:$PATH",
            fs.shell_quote(tmp),
            fs.shell_quote(tmp .. "/runtime"),
            fs.shell_quote(tmp .. "/cfg"),
            fs.shell_quote(tmp .. "/data"),
            fs.shell_quote(tmp .. "/cache"),
            fs.shell_quote(tmp .. "/bin")
        )
        local function stub(name, body)
            local path = tmp .. "/bin/" .. name
            fs.write_atomic(path, "#!/bin/sh\nset -eu\n" .. body .. "\n")
            assert(os.execute("chmod +x -- " .. fs.shell_quote(path)))
        end
        local function run(args, vars, bin_path)
            return env .. " " .. (vars or "") .. " " .. fs.shell_quote(bin_path or (repo_dir .. "/bin/kaze-keys"))
                .. (args and args ~= "" and (" " .. args) or "")
        end
        local ok, err = pcall(fn, tmp, stub, run)
        rm_rf(tmp)
        if not ok then
            error(err, 0)
        end
    end

    local function with_mock_hl(ctx_tbl, fn)
        local prev_hl = rawget(_G, "hl")
        local prev_ctx = package.loaded["kaze._ctx"]
        local ok, err = pcall(function()
            package.loaded["kaze._ctx"] = ctx_tbl
            fn()
        end)
        rawset(_G, "hl", prev_hl)
        package.loaded["kaze._ctx"] = prev_ctx
        if not ok then
            error(err, 0)
        end
    end

    test("stage3 keybinds_data: pure build completeness, overrides, and deduplicated rows", function()
        assert_eq(rawget(_G, "hl"), nil, "keybinds_data must run without compositor hl global")

        local entries = keybinds_data.build(defaults)
        assert_true(#entries >= 115, "Caelestia-aligned keybind table completeness")

        local by_chord = {}
        for _, entry in ipairs(entries) do
            assert_true(type(entry.group) == "string" and entry.group ~= "", "entry.group non-empty")
            assert_true(type(entry.chord) == "string" and entry.chord ~= "", "entry.chord non-empty")
            assert_true(type(entry.desc) == "string" and entry.desc ~= "", "entry.desc non-empty")
            assert_true(type(entry.kind) == "string" and entry.kind ~= "", "entry.kind non-empty")
            assert_eq(by_chord[entry.chord], nil, "duplicate chord in build: " .. entry.chord)
            by_chord[entry.chord] = entry
        end

        local slash = assert(by_chord["SUPER + slash"], "missing SUPER + slash")
        assert_eq(slash.group, "Launchers", "SUPER + slash group")
        assert_eq(slash.desc, "Search keyboard shortcuts", "SUPER + slash desc")
        assert_eq(slash.kind, "exec", "SUPER + slash kind")
        assert_eq(slash.cmd, "kaze-keys", "SUPER + slash cmd")
        assert_eq(slash.display, "Super + /", "SUPER + slash display")

        assert_eq(by_chord["SUPER + T"].cmd, "kaze-footclient -N", "default kaze-footclient adds -N")
        assert_eq(by_chord["SUPER + Return"].cmd, "kaze-footclient -N", "default Return kaze-footclient adds -N")
        assert_eq(by_chord["SUPER + SUPER_L"].release, true, "Super tap launcher triggers on release")
        assert_contains(by_chord["SUPER + C"].cmd, "command -v codium", "default editor checks codium with fallback")
        assert_contains(by_chord["SUPER + E"].cmd, "command -v yazi", "default files keeps missing-yazi guard")
        assert_contains(by_chord["SUPER + E"].cmd, "File manager unavailable", "default files keeps notification hint")
        assert_eq(by_chord["SUPER + SHIFT + C"].cmd, "kaze-screenshot color", "color picker bind")
        assert_eq(by_chord["CTRL + ALT + R"].cmd, "kaze-record", "screen recording bind")
        assert_eq(by_chord["SUPER + SHIFT + ALT + R"].cmd, "kaze-record --region", "region recording bind")
        assert_eq(by_chord["SUPER + Comma"].kind, "group_toggle", "window group toggle")
        assert_eq(by_chord["SUPER + Minus"].kind, "window_resize_step", "window resize step")
        assert_eq(by_chord["SUPER + ALT + Backslash"].kind, "window_pip", "PiP bind")
        assert_eq(by_chord["SUPER + M"].workspace, "music", "music special workspace")
        assert_eq(by_chord["SUPER + D"].workspace, "communication", "communication special workspace")
        assert_eq(by_chord["SUPER + R"].workspace, "todo", "todo special workspace")
        assert_eq(by_chord["CTRL + SUPER + Space"].cmd, "playerctl play-pause", "keyboard media toggle")
        assert_eq(by_chord["SUPER + N"].cmd, "kaze-dashboard", "top calendar & media dashboard bind")
        assert_eq(by_chord["SUPER + A"].cmd, "kaze-panel", "right quick control panel bind")
        assert_eq(by_chord["SUPER + SHIFT + Z"].cmd, "kaze-perf", "Zen performance mode bind")
        assert_eq(by_chord["SUPER + Escape"].kind, "submap", "VM passthrough submap bind")
        assert_eq(by_chord["SUPER + Escape"].submap, "passthrough", "VM passthrough submap target")
        assert_eq(by_chord["SUPER + TAB"].cmd, "kaze-windows", "fuzzy window switcher bind")
        assert_eq(by_chord["SUPER + SHIFT + A"].cmd, "kaze-audio-sink", "audio output switcher bind")
        assert_eq(by_chord["CTRL + SUPER + N"].cmd, "kaze-osd media-info", "now playing toast bind")
        assert_eq(by_chord["SUPER + ALT + C"].cmd, "kaze-calc", "calculator bind")
        assert_eq(by_chord["XF86Calculator"].cmd, "kaze-calc", "hardware calculator key bind")

        for i = 1, 10 do
            local key = tostring(i % 10)
            local ws = tostring(i)
            assert_eq(by_chord["SUPER + " .. key].args.workspace, ws, "workspace focus " .. ws)
            assert_eq(by_chord["SUPER + SHIFT + " .. key].args.workspace, ws, "workspace shift move " .. ws)
            assert_eq(by_chord["SUPER + ALT + " .. key].args.workspace, ws, "workspace alt move " .. ws)
        end
        assert_eq(by_chord["SUPER + mouse:272"].mouse, true, "LMB drag mouse option")
        assert_eq(by_chord["SUPER + mouse:272"].kind, "window_drag", "LMB drag kind")
        assert_eq(by_chord["SUPER + mouse:273"].mouse, true, "RMB resize mouse option")
        assert_eq(by_chord["SUPER + mouse:273"].kind, "window_resize", "RMB resize kind")
        assert_eq(by_chord["Print"].locked, true, "Print locked")
        assert_eq(by_chord["CTRL + ALT + C"].locked, true, "dismiss notifications locked")
        assert_eq(by_chord["ALT + TAB"].repeating, true, "ALT + TAB repeating")
        assert_eq(by_chord["SHIFT + ALT + TAB"].args.next, false, "SHIFT + ALT + TAB reverse")

        local custom = keybinds_data.build({
            terminal = "foot",
            browser = "chromium",
            editor = "nvim",
            files = "thunar",
        })
        local custom_by_chord = {}
        for _, entry in ipairs(custom) do
            custom_by_chord[entry.chord] = entry
        end
        assert_eq(custom_by_chord["SUPER + T"].cmd, "foot", "custom terminal preserved without -N")
        assert_eq(custom_by_chord["SUPER + W"].cmd, "chromium", "custom browser preserved")
        assert_eq(custom_by_chord["SUPER + C"].cmd, "nvim", "custom editor preserved")
        assert_eq(custom_by_chord["SUPER + E"].cmd, "thunar", "custom file manager bypasses yazi fallback")

        local rows = keybinds_data.format_rows(defaults)
        assert_true(#rows >= 30 and #rows < #entries, "display rows collapse repetitive binds")
        local seen_rows = {}
        for _, line in ipairs(rows) do
            assert_true(line:match("^%[[^%]]+%]  .+  —  .+$") ~= nil, "malformed row: " .. line)
            assert_eq(seen_rows[line], nil, "duplicate formatted row: " .. line)
            seen_rows[line] = true
        end
        local joined = table.concat(rows, "\n")
        assert_contains(joined, "[Launchers]  Super + /  —  Search keyboard shortcuts")
        assert_contains(joined, "[Workspaces]  Super + 1..0  —  Switch to workspace 1..10")
    end)

    test("stage3 kaze-keys CLI: --list, --help, unknown flags, XDG fallback, and fuzzel Enter/Esc/toggle", function()
        with_stubs(function(tmp, stub, run)
            local q = fs.shell_quote

            local help_out = assert(fs.capture(run("--help")))
            assert_contains(help_out, "Usage: kaze-keys [--list]")
            local short_help = assert(fs.capture(run("-h")))
            assert_eq(short_help, help_out, "-h matches --help")

            local ok_bad, why_bad, code_bad = os.execute(run("--bogus") .. " 2>" .. q(tmp .. "/err"))
            assert_true(not ok_bad, "--bogus must fail")
            assert_eq(why_bad, "exit", "--bogus exit reason")
            assert_eq(code_bad, 2, "--bogus exit status 2")
            assert_contains(assert(fs.read_file(tmp .. "/err")), "unknown option '--bogus'")

            local ok_extra, _, code_extra = os.execute(run("--list extra") .. " 2>/dev/null")
            assert_true(not ok_extra, "extra args must fail")
            assert_eq(code_extra, 2, "extra args exit status 2")

            -- --list must work with minimal PATH (no fuzzel, no compositor)
            for _, bin in ipairs({ "lua", "readlink" }) do
                local actual = assert(fs.capture("command -v " .. bin)):gsub("\n$", "")
                assert(os.execute("ln -s -- " .. q(actual) .. " " .. q(tmp .. "/bin/" .. bin)))
            end
            local list_out = assert(fs.capture(run("--list", "PATH=" .. q(tmp .. "/bin"))))
            assert_contains(list_out, "[Launchers]  Super + /  —  Search keyboard shortcuts\n")
            assert_contains(list_out, "[Apps]  Super + Return / T  —  Open terminal\n")

            -- Copied binary outside repo resolves modules via XDG_DATA_HOME/kaze-dots/lua
            local repo_real = assert(fs.capture("readlink -f -- " .. q(repo_dir))):gsub("\n$", "")
            fs.mkdir_p(tmp .. "/data/kaze-dots")
            assert(os.execute("ln -s -- " .. q(repo_real .. "/lua") .. " " .. q(tmp .. "/data/kaze-dots/lua")))
            local copied_bin = tmp .. "/outside-bin/kaze-keys"
            fs.mkdir_p(fs.dirname(copied_bin))
            assert(os.execute("cp -- " .. q(repo_real .. "/bin/kaze-keys") .. " " .. q(copied_bin)))
            assert(os.execute("chmod +x -- " .. q(copied_bin)))
            local copied_out = assert(fs.capture(run("--list", nil, copied_bin)))
            assert_eq(copied_out, list_out, "copied kaze-keys via XDG_DATA_HOME matches repo --list")

            -- Stubbed fuzzel: Enter (exit 0 with selection) and Esc (exit 1/2 empty) both exit 0
            stub("pgrep", [[
[ "$1" = -x ] && [ "$2" = fuzzel ]
[ "${FUZZEL_RUNNING:-0}" = 1 ]
]])
            stub("pkill", [[
printf '%s\n' "$*" > "$HOME/pkill-args"
]])
            stub("fuzzel", [[
printf '%s\n' "$*" > "$HOME/fuzzel-args"
/usr/bin/cat > "$HOME/fuzzel-stdin"
if [ "${FUZZEL_ESC:-0}" != 0 ]; then
    exit "${FUZZEL_ESC}"
fi
printf '[Launchers]  Super + /  —  Search keyboard shortcuts\n'
]])

            local enter_ok, enter_why, enter_code = os.execute(run("") .. " >" .. q(tmp .. "/stdout"))
            assert_true(enter_ok == true or enter_ok == 0, "Enter selection exits 0")
            assert_eq(enter_why, "exit")
            assert_eq(enter_code, 0)
            assert_eq(fs.read_file(tmp .. "/stdout"), "", "Enter lookup prints nothing to stdout")
            assert_eq(fs.read_file(tmp .. "/fuzzel-args"), "--dmenu -w 86 --lines 14 --minimal-lines --line-height=28 -p Keys > \n", "fuzzel invocation flags")
            assert_eq(fs.read_file(tmp .. "/fuzzel-stdin"), list_out, "fuzzel receives exact formatted rows")

            for _, esc_code in ipairs({ 1, 2 }) do
                local esc_ok, esc_why, got_code = os.execute(run("", "FUZZEL_ESC=" .. esc_code))
                assert_true(esc_ok == true or esc_ok == 0, "Esc exit " .. esc_code .. " must still exit 0")
                assert_eq(esc_why, "exit")
                assert_eq(got_code, 0)
            end

            -- Toggle-close when fuzzel is already running
            os.remove(tmp .. "/fuzzel-args")
            assert(os.execute(run("", "FUZZEL_RUNNING=1")))
            assert_eq(fs.read_file(tmp .. "/pkill-args"), "-x fuzzel\n", "pkill uses exact -x fuzzel")
            assert_true(not fs.file_exists(tmp .. "/fuzzel-args"), "toggle-close must not spawn a new fuzzel")
        end)
    end)

    test("stage3 hypr/core.lua: flat mouse accel default, override, and 3-finger workspace gesture", function()
        local tmp = make_tmp_dir()
        local cfg, theme, layout = config.load({ home = tmp, strict = true })
        rm_rf(tmp)

        local function eval_core(custom_cfg)
            local merged = config.deep_merge(cfg, custom_cfg or {})
            local seen = { configs = {}, gestures = {}, curves = 0, animations = 0 }
            with_mock_hl({ cfg = merged, theme = theme, layout = layout }, function()
                rawset(_G, "hl", {
                    config = function(tbl) seen.configs[#seen.configs + 1] = tbl end,
                    gesture = function(spec) seen.gestures[#seen.gestures + 1] = spec end,
                    curve = function() seen.curves = seen.curves + 1 end,
                    animation = function() seen.animations = seen.animations + 1 end,
                })
                dofile(repo_dir .. "/hypr/core.lua")
            end)
            return seen
        end

        local default_seen = eval_core()
        assert_eq(#default_seen.configs, 1, "hl.config called once")
        assert_eq(default_seen.configs[1].input.accel_profile, "flat", "default accel_profile is flat")
        assert_eq(default_seen.configs[1].input.touchpad.natural_scroll, true, "touchpad natural_scroll preserved")
        assert_eq(default_seen.configs[1].decoration.active_opacity, 1.0, "default active_opacity is 1.0")
        assert_eq(default_seen.configs[1].decoration.inactive_opacity, 1.0, "default inactive_opacity is 1.0")
        assert_eq(default_seen.configs[1].decoration.fullscreen_opacity, 1.0, "fullscreen_opacity is 1.0")
        assert_true(type(default_seen.configs[1].group) == "table", "group config block defined")
        assert_eq(default_seen.configs[1].group.groupbar.gradients, false, "groupbar flat minimalism")
        assert_eq(default_seen.configs[1].misc.close_special_on_empty, true, "scratchpad closes on empty")
        assert_eq(default_seen.configs[1].render.direct_scanout, 1, "direct_scanout enabled")
        assert_eq(default_seen.configs[1].xwayland.force_zero_scaling, true, "xwayland zero scaling")
        assert_eq(default_seen.configs[1].ecosystem.no_update_news, true, "ecosystem update news suppressed")
        assert_eq(#default_seen.gestures, 1, "default enables 3-finger swipe gesture")
        assert_eq(default_seen.gestures[1].fingers, 3, "gesture fingers")
        assert_eq(default_seen.gestures[1].direction, "horizontal", "gesture direction")
        assert_eq(default_seen.gestures[1].action, "workspace", "gesture action")

        local custom_seen = eval_core({ accel_profile = "adaptive", workspace_swipe = false })
        assert_eq(custom_seen.configs[1].input.accel_profile, "adaptive", "cfg.accel_profile override respected")
        assert_eq(#custom_seen.gestures, 0, "workspace_swipe = false disables gesture")
    end)

    test("stage3 hypr/keybinds.lua: registers all binds with descriptions and 80ms OSD repeat throttle", function()
        local theme = themes.get("kaze")
        local layout = layouts.get("sidebar")
        local binds = {}
        local by_chord = {}
        local exec_calls = {}
        local timers = {}

        local dispatches = {}
        local submaps = {}
        local events = {}
        local ws_windows = {}
        with_mock_hl({ cfg = defaults, theme = theme, layout = layout }, function()
            rawset(_G, "hl", {
                bind = function(keys, dispatcher, opts)
                    local rec = { keys = keys, dispatcher = dispatcher, opts = opts }
                    binds[#binds + 1] = rec
                    by_chord[keys] = rec
                end,
                define_submap = function(name, fn)
                    local sub_binds = {}
                    local orig_bind = hl.bind
                    hl.bind = function(keys, dispatcher, opts)
                        sub_binds[#sub_binds + 1] = { keys = keys, dispatcher = dispatcher, opts = opts }
                    end
                    fn()
                    hl.bind = orig_bind
                    submaps[name] = sub_binds
                end,
                on = function(ev, cb)
                    events[ev] = cb
                end,
                timer = function(cb, opts)
                    timers[#timers + 1] = { cb = cb, opts = opts }
                end,
                exec_cmd = function(cmd, opts)
                    exec_calls[#exec_calls + 1] = opts and { cmd = cmd, opts = opts } or cmd
                end,
                dispatch = function(action)
                    dispatches[#dispatches + 1] = action
                end,
                get_workspace_windows = function(ws_name)
                    return ws_windows[ws_name] or {}
                end,
                get_active_window = function()
                    return { address = "0x1234", floating = false, size = { x = 1000, y = 800 } }
                end,
                get_active_monitor = function()
                    return { x = 0, y = 0, width = 1920, height = 1080, scale = 1 }
                end,
                dsp = {
                    exec_cmd = function(cmd) return { dsp = "exec_cmd", cmd = cmd } end,
                    focus = function(args) return { dsp = "focus", args = args } end,
                    submap = function(name) return { dsp = "submap", name = name } end,
                    group = {
                        toggle = function() return { dsp = "group.toggle" } end,
                        lock = function() return { dsp = "group.lock" } end,
                        next = function() return { dsp = "group.next" } end,
                        prev = function() return { dsp = "group.prev" } end,
                    },
                    window = {
                        close = function() return { dsp = "window.close" } end,
                        fullscreen = function(args) return { dsp = "window.fullscreen", args = args } end,
                        float = function() return { dsp = "window.float" } end,
                        pin = function(args) return { dsp = "window.pin", args = args } end,
                        center = function() return { dsp = "window.center" } end,
                        set_prop = function(args) return { dsp = "window.set_prop", args = args } end,
                        cycle_next = function(args) return { dsp = "window.cycle_next", args = args } end,
                        move = function(args) return { dsp = "window.move", args = args } end,
                        drag = function() return { dsp = "window.drag" } end,
                        resize = function(args) return { dsp = "window.resize", args = args } end,
                    },
                    workspace = {
                        toggle_special = function(ws) return { dsp = "workspace.toggle_special", ws = ws } end,
                    },
                },
            })
            dofile(repo_dir .. "/hypr/keybinds.lua")

            assert_eq(#binds, #keybinds_data.build(defaults), "every bind registered via hl.bind")
            local super_tap = assert(by_chord["SUPER + SUPER_L"], "SUPER + SUPER_L bound")
            assert_eq(super_tap.opts.release, true, "SUPER_L launcher uses release option")
            assert_eq(by_chord["SUPER + Comma"].dispatcher.dsp, "group.toggle")
            assert_eq(by_chord["CTRL + SUPER + Backslash"].dispatcher.dsp, "window.center")

            -- Exercise dynamic window helpers (resize step, normalize, PiP)
            by_chord["SUPER + Minus"].dispatcher()
            assert_eq(dispatches[#dispatches].dsp, "window.resize")
            assert_eq(dispatches[#dispatches].args.x, -100)
            assert_eq(dispatches[#dispatches].args.relative, true)

            by_chord["CTRL + SUPER + ALT + Backslash"].dispatcher()
            assert_eq(dispatches[#dispatches].dsp, "window.center")

            by_chord["SUPER + ALT + Backslash"].dispatcher()
            assert_eq(dispatches[#dispatches].dsp, "window.pin")
            assert_eq(dispatches[#dispatches].args.action, "on")
            local slash = assert(by_chord["SUPER + slash"], "SUPER + slash bound")
            assert_eq(slash.dispatcher.dsp, "exec_cmd")
            assert_eq(slash.dispatcher.cmd, "kaze-keys")
            assert_eq(slash.opts.description, "Search keyboard shortcuts")

            local drag = assert(by_chord["SUPER + mouse:272"], "LMB drag bound")
            assert_eq(drag.dispatcher.dsp, "window.drag")
            assert_eq(drag.opts.mouse, true)
            assert_eq(drag.opts.description, "Drag window")

            local vol_up = assert(by_chord["XF86AudioRaiseVolume"], "volume up bound")
            local vol_down = assert(by_chord["XF86AudioLowerVolume"], "volume down bound")
            local bright_up = assert(by_chord["XF86MonBrightnessUp"], "brightness up bound")
            assert_eq(vol_up.opts.locked, true)
            assert_eq(vol_up.opts.repeating, true)
            assert_eq(type(vol_up.dispatcher), "function", "OSD bind uses repeat throttle closure")

            -- Trigger volume up; rapid repeat on same channel must be dropped until 80ms timer fires
            vol_up.dispatcher()
            assert_eq(#exec_calls, 1)
            assert_eq(exec_calls[1], "kaze-osd vol-up")
            assert_eq(#timers, 1)
            assert_eq(timers[1].opts.timeout, 80)
            assert_eq(timers[1].opts.type, "oneshot")

            vol_up.dispatcher()
            vol_down.dispatcher()
            assert_eq(#exec_calls, 1, "busy volume channel drops repeats within 80ms")

            -- Independent backlight channel is not blocked by volume channel
            bright_up.dispatcher()
            assert_eq(#exec_calls, 2, "backlight channel fires independently")
            assert_eq(exec_calls[2], "kaze-osd bright-up")

            -- Expiring the 80ms volume timer re-arms the volume channel
            timers[1].cb()
            vol_down.dispatcher()
            assert_eq(#exec_calls, 3, "volume channel unlocked after 80ms timer")
            assert_eq(exec_calls[3], "kaze-osd vol-down")

            -- Verify passthrough submap and Waybar RTMIN+12 hook
            assert_eq(by_chord["SUPER + Escape"].dispatcher.dsp, "submap")
            assert_eq(by_chord["SUPER + Escape"].dispatcher.name, "passthrough")
            assert_true(submaps.passthrough ~= nil and #submaps.passthrough == 1, "passthrough submap has reset bind")
            assert_eq(submaps.passthrough[1].keys, "SUPER + Escape")
            assert_eq(submaps.passthrough[1].dispatcher.name, "reset")
            assert_true(type(events["keybinds.submap"]) == "function", "keybinds.submap listener registered")
            events["keybinds.submap"]()
            assert_contains(exec_calls[#exec_calls], "pkill -RTMIN+12 -x --require-handler waybar")

            -- Verify Smart Scratchpad auto-spawns when empty, and only toggles when populated
            by_chord["SUPER + S"].dispatcher()
            local spawn_rec = exec_calls[#exec_calls]
            assert_eq(type(spawn_rec), "table", "empty scratchpad calls hl.exec_cmd with workspace opts")
            assert_eq(spawn_rec.cmd, "kaze-footclient -N -a kaze-dropdown")
            assert_eq(spawn_rec.opts.workspace, "special:scratch")
            assert_eq(dispatches[#dispatches].dsp, "workspace.toggle_special")
            assert_eq(dispatches[#dispatches].ws, "scratch")

            local prev_exec_len = #exec_calls
            ws_windows["special:scratch"] = { { address = "0x999" } }
            by_chord["SUPER + S"].dispatcher()
            assert_eq(#exec_calls, prev_exec_len, "populated scratchpad does not spawn another terminal")
        end)
    end)

    test("stage3 hypr/keybinds.lua: outside-click & focus-shift auto-dismiss controller", function()
        local theme = themes.get("kaze")
        local layout = layouts.get("sidebar")
        with_stubs(function(tmp)
            with_mock_hl({ cfg = defaults, theme = theme, layout = layout }, function()
                local events = {}
                local dyn_binds = {}
                local unbinds = {}
                local dispatches = {}
                local execs = {}
                local cursor = { x = 100, y = 100 }
                local windows = {}
                local layers = {}

                rawset(_G, "hl", {
                    bind = function(keys, dispatcher, opts)
                        dyn_binds[keys] = { dispatcher = dispatcher, opts = opts }
                    end,
                    unbind = function(keys)
                        unbinds[#unbinds + 1] = keys
                        dyn_binds[keys] = nil
                    end,
                    define_submap = function() end,
                    on = function(ev, cb)
                        events[ev] = cb
                    end,
                    timer = function() end,
                    exec_cmd = function(cmd)
                        execs[#execs + 1] = cmd
                    end,
                    dispatch = function(action)
                        dispatches[#dispatches + 1] = action
                    end,
                    get_windows = function()
                        return windows
                    end,
                    get_layers = function(filter)
                        if filter and filter.namespace == "waybar" then
                            local wb = {}
                            for _, l in ipairs(layers) do
                                if l.namespace == "waybar" then wb[#wb + 1] = l end
                            end
                            return wb
                        end
                        return layers
                    end,
                    get_cursor_pos = function()
                        return cursor
                    end,
                    get_workspace_windows = function() return {} end,
                    get_active_window = function() return nil end,
                    get_active_monitor = function() return { x = 0, y = 0, width = 1920, height = 1080, scale = 1 } end,
                    dsp = {
                        exec_cmd = function(cmd) return { dsp = "exec_cmd", cmd = cmd } end,
                        focus = function(args) return { dsp = "focus", args = args } end,
                        submap = function(name) return { dsp = "submap", name = name } end,
                        group = {
                            toggle = function() return {} end,
                            lock = function() return {} end,
                            next = function() return {} end,
                            prev = function() return {} end,
                        },
                        window = {
                            close = function(args) return { dsp = "window.close", args = args } end,
                            fullscreen = function() return {} end,
                            float = function() return {} end,
                            pin = function() return {} end,
                            center = function() return {} end,
                            set_prop = function() return {} end,
                            cycle_next = function() return {} end,
                            move = function() return {} end,
                            drag = function() return {} end,
                            resize = function() return {} end,
                        },
                        workspace = {
                            toggle_special = function() return {} end,
                        },
                    },
                })
                dofile(repo_dir .. "/hypr/keybinds.lua")

                assert_eq(dyn_binds["mouse:272"], nil, "mouse:272 unbound while no popover open")
                windows = {
                    { class = "kaze-widget-panel", address = "0xabc", mapped = true, at = { x = 58, y = 500 }, size = { x = 400, y = 500 } },
                }
                layers = {
                    { namespace = "waybar", mapped = true, x = 8, y = 8, w = 42, h = 1064 },
                }
                events["window.open"]()
                assert_true(dyn_binds["mouse:272"] ~= nil, "opening popover arms mouse:272")
                assert_eq(dyn_binds["mouse:272"].opts.non_consuming, true, "click bind passes through cleanly")

                -- Click inside popover keeps it open
                cursor = { x = 150, y = 600 }
                dyn_binds["mouse:272"].dispatcher()
                assert_eq(#dispatches, 0, "click inside popover must not close it")

                -- Click on empty desktop outside closes popover and disarms binds
                cursor = { x = 900, y = 400 }
                dyn_binds["mouse:272"].dispatcher()
                assert_eq(#dispatches, 1, "outside click closes open popover")
                assert_eq(dispatches[1].args.window, "address:0xabc")
                assert_eq(dyn_binds["mouse:272"], nil, "mouse:272 disarmed after close")

                -- Clicking Waybar outside open fuzzel layer closes fuzzel + records dismiss guard
                layers = {
                    { namespace = "waybar", mapped = true, x = 8, y = 8, w = 42, h = 1064 },
                    { namespace = "kaze-popup-left", mapped = true, x = 58, y = 8, w = 320, h = 420 },
                }
                windows = {}
                events["layer.opened"]()
                assert_true(dyn_binds["mouse:272"] ~= nil, "opening fuzzel layer arms mouse:272")
                cursor = { x = 20, y = 20 }
                dyn_binds["mouse:272"].dispatcher()
                assert_true(#execs >= 1 and execs[#execs]:find("pkill %-x fuzzel") ~= nil, "outside click dismisses open fuzzel")

                -- When layer reports exact PID, dismiss targets that PID so a newly spawned fuzzel is never killed
                layers = {
                    { namespace = "waybar", mapped = true, x = 8, y = 8, w = 42, h = 1064 },
                    { namespace = "kaze-popup-left", mapped = true, pid = 4321, x = 58, y = 8, w = 320, h = 420 },
                }
                events["layer.opened"]()
                cursor = { x = 20, y = 20 }
                dyn_binds["mouse:272"].dispatcher()
                assert_true(execs[#execs]:find("kill 4321") ~= nil, "outside click kills exact fuzzel layer PID when available")

                -- Focusing another non-widget window closes open popover
                windows = {
                    { class = "kaze-widget-dash", address = "0xdef", mapped = true, at = { x = 58, y = 400 }, size = { x = 420, y = 420 } },
                }
                local before_disp = #dispatches
                events["window.active"]({ class = "foot", address = "0x111" })
                assert_eq(#dispatches, before_disp + 1, "window focus shift closes open popover")
                assert_eq(dispatches[#dispatches].args.window, "address:0xdef")
            end)
            local _ = tmp
        end)
    end)
end

if arg and type(arg[0]) == "string" and arg[0]:match("test_stage3_keys%.lua$") and not debug.getinfo(3, "f") then
    local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
    local repo_dir = script_dir .. "/.."
    package.path = table.concat({
        repo_dir .. "/lua/?.lua",
        repo_dir .. "/lua/?/init.lua",
        package.path,
    }, ";")

    local passed = 0
    local failed = 0

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

    io.stdout:write("Running Stage 3 keybinds & input tests...\n")
    register_tests(test, assert_eq, assert_true, assert_contains, repo_dir)
    io.stdout:write(string.format("\nSummary: %d passed, %d failed\n", passed, failed))
    if failed > 0 then
        os.exit(1)
    end
end

return register_tests
