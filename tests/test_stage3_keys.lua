#!/usr/bin/env lua

local function register_tests(test, assert_eq, assert_true, assert_contains, repo_dir)
    local fs = require("kaze.fs")
    local hypr_user = require("kaze.hypr_user")
    local keybinds_data = require("kaze.keybinds_data")

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

    test("keybinds_data: pure build routes shell actions to Noctalia IPC with no duplicate chords or Zen Mode", function()
        assert_eq(rawget(_G, "hl"), nil, "keybinds_data must run without compositor hl global")

        local defaults = hypr_user.defaults()
        local entries = keybinds_data.build(defaults)
        assert_true(#entries >= 95, "keybind table completeness")

        local by_chord = {}
        for _, entry in ipairs(entries) do
            assert_true(type(entry.group) == "string" and entry.group ~= "", "entry.group non-empty")
            assert_true(type(entry.chord) == "string" and entry.chord ~= "", "entry.chord non-empty")
            assert_true(type(entry.desc) == "string" and entry.desc ~= "", "entry.desc non-empty")
            assert_true(type(entry.kind) == "string" and entry.kind ~= "", "entry.kind non-empty")
            assert_eq(by_chord[entry.chord], nil, "duplicate chord in build: " .. entry.chord)
            by_chord[entry.chord] = entry
        end

        assert_eq(by_chord["SUPER + SPACE"].cmd, "noctalia msg panel-toggle launcher")
        assert_eq(by_chord["SUPER + SUPER_L"].release, true)
        assert_eq(by_chord["SUPER + A"].cmd, "noctalia msg panel-toggle control-center")
        assert_eq(by_chord["SUPER + N"].cmd, "noctalia msg panel-toggle control-center notifications")
        assert_eq(by_chord["SUPER + I"].cmd, "noctalia msg settings-toggle")
        assert_eq(by_chord["SUPER + SHIFT + T"].cmd, "noctalia msg theme-mode-toggle")
        assert_eq(by_chord["SUPER + V"].cmd, "noctalia msg panel-toggle clipboard")
        assert_eq(by_chord["SUPER + SHIFT + W"].cmd, "noctalia msg panel-toggle wallpaper")
        assert_eq(by_chord["CTRL + ALT + Delete"].cmd, "noctalia msg panel-toggle session")
        assert_eq(by_chord["CTRL + ALT + C"].cmd, "noctalia msg notification-clear-active")
        assert_eq(by_chord["SUPER + TAB"].cmd, "noctalia msg window-switcher hold")
        assert_eq(by_chord["XF86AudioRaiseVolume"].cmd, "noctalia msg volume-up")
        assert_eq(by_chord["XF86MonBrightnessUp"].cmd, "noctalia msg brightness-up")
        assert_eq(by_chord["XF86AudioPlay"].cmd, "noctalia msg media play-pause")
        assert_eq(by_chord["Print"].cmd, "noctalia msg screenshot-fullscreen")
        assert_eq(by_chord["SUPER + SHIFT + S"].cmd, "noctalia msg screenshot-region")
        assert_eq(by_chord["SUPER + SHIFT + ALT + S"].cmd, "noctalia msg screenshot-annotate")
        assert_contains(by_chord["SUPER + SHIFT + C"].cmd, "hyprpicker")
        assert_contains(by_chord["SUPER + E"].cmd, "exec thunar")
        assert_eq(by_chord["CTRL + ALT + R"].cmd, "kaze-record")
        assert_eq(by_chord["SUPER + SHIFT + R"].cmd, "kaze-record --menu")
        assert_eq(by_chord["SUPER + SHIFT + I"].cmd, "kaze-style --menu")
        assert_eq(by_chord["SUPER + O"].cmd, "kaze-project")
        assert_eq(by_chord["SUPER + SHIFT + O"].cmd, "kaze-project --split")
        assert_eq(by_chord["SUPER + slash"].cmd, "kaze-keys")
        assert_eq(by_chord["SUPER + ALT + P"].cmd, "kaze-display toggle-window-share")
        assert_eq(by_chord["CTRL + SUPER + P"].cmd, "kaze-display toggle-control")
        assert_eq(by_chord["SUPER + SHIFT + Z"].kind, "focus_mode", "Focus / Game Mode keybind registered")
        assert_eq(by_chord["SUPER + ALT + M"].kind, "window_move")
        assert_eq(by_chord["SUPER + ALT + D"].kind, "window_move")
        assert_eq(by_chord["SUPER + ALT + R"].kind, "window_move")
        assert_eq(by_chord["SUPER + SHIFT + L"], nil, "kaze-layout keybind must be removed")
        assert_eq(by_chord["SUPER + SHIFT + SPACE"], nil, "kaze-menu keybind must be removed")
        assert_eq(by_chord["CTRL + SUPER + ALT + R"].cmd, "noctalia msg config-reload && hyprctl reload")
        assert_eq(by_chord["SUPER + Escape"].kind, "submap")
        assert_eq(by_chord["SUPER + Escape"].submap, "passthrough")

        local rows = keybinds_data.format_rows(defaults)
        assert_true(#rows >= 25 and #rows < #entries, "display rows collapse repetitive binds")
        local joined = table.concat(rows, "\n")
        assert_contains(joined, "Search Hyprland keyboard shortcuts")
        assert_contains(joined, "Switch to workspace 1..10")
    end)

    test("kaze-keys CLI: --list, --help, unknown flags, and noctalia dmenu execution", function()
        with_stubs(function(tmp, stub, run)
            local q = fs.shell_quote
            local help_out = assert(fs.capture(run("--help")))
            assert_contains(help_out, "Usage: kaze-keys [--list]")
            assert_eq(assert(fs.capture(run("-h"))), help_out)

            local ok_bad, _, code_bad = os.execute(run("--bogus") .. " 2>/dev/null")
            assert_true(not ok_bad)
            assert_eq(code_bad, 2)

            for _, bin in ipairs({ "lua", "readlink" }) do
                local actual = assert(fs.capture("command -v " .. bin)):gsub("\n$", "")
                assert(os.execute("ln -s -- " .. q(actual) .. " " .. q(tmp .. "/bin/" .. bin)))
            end
            local list_out = assert(fs.capture(run("--list", "PATH=" .. q(tmp .. "/bin"))))
            assert_contains(list_out, "Search Hyprland keyboard shortcuts")
            assert_contains(list_out, "Open terminal")

            stub("noctalia", [[
printf '%s\n' "$@" > "$HOME/noc-args"
/usr/bin/cat > "$HOME/noc-stdin"
]])
            assert(os.execute(run("")))
            assert_eq(fs.read_file(tmp .. "/noc-args"), "dmenu\n-p\nKeys > \n")
            assert_eq(fs.read_file(tmp .. "/noc-stdin"), list_out)
        end)
    end)

    test("hypr/core.lua & hypr/keybinds.lua: registers binds, submap, smart scratchpad, and helpers", function()
        local cfg = hypr_user.defaults()

        local seen_core = { configs = {}, gestures = {} }
        with_mock_hl({ cfg = cfg }, function()
            rawset(_G, "hl", {
                config = function(tbl) seen_core.configs[#seen_core.configs + 1] = tbl end,
                gesture = function(spec) seen_core.gestures[#seen_core.gestures + 1] = spec end,
                curve = function() end,
                animation = function() end,
            })
            dofile(repo_dir .. "/hypr/core.lua")
        end)
        assert_eq(#seen_core.configs, 1)
        assert_eq(seen_core.configs[1].input.accel_profile, "flat")
        assert_eq(#seen_core.gestures, 1)

        local binds, by_chord, exec_calls, dispatches, submaps, ws_windows, hl_configs = {}, {}, {}, {}, {}, {}, {}
        with_mock_hl({ cfg = cfg }, function()
            rawset(_G, "hl", {
                config = function(tbl)
                    hl_configs[#hl_configs + 1] = tbl
                end,
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

            assert_eq(#binds, #keybinds_data.build(cfg))
            assert_eq(by_chord["XF86AudioRaiseVolume"].dispatcher.cmd, "noctalia msg volume-up")
            assert_eq(by_chord["XF86AudioRaiseVolume"].opts.locked, true)
            assert_eq(by_chord["XF86AudioRaiseVolume"].opts.repeating, true)
            assert_true(submaps.passthrough ~= nil and #submaps.passthrough == 1)

            by_chord["SUPER + S"].dispatcher()
            assert_eq(exec_calls[#exec_calls].cmd, "kaze-footclient -N")
            assert_eq(exec_calls[#exec_calls].opts.workspace, "special:scratch")
            local prev_len = #exec_calls
            ws_windows["special:scratch"] = { { address = "0x999" } }
            by_chord["SUPER + S"].dispatcher()
            assert_eq(#exec_calls, prev_len)

            -- Named special workspaces (music, communication, todo) spawn defaults when empty
            by_chord["SUPER + M"].dispatcher()
            assert_eq(exec_calls[#exec_calls].opts.workspace, "special:music")
            by_chord["SUPER + D"].dispatcher()
            assert_eq(exec_calls[#exec_calls].opts.workspace, "special:communication")
            by_chord["SUPER + R"].dispatcher()
            assert_eq(exec_calls[#exec_calls].opts.workspace, "special:todo")

            -- Focus / Game Mode (Super + Shift + Z) toggles gaps/blur/animations off and restores cleanly
            cfg.focus_mode = { allow_tearing = true, hide_bar = false }
            local cfg_before = #hl_configs
            by_chord["SUPER + SHIFT + Z"].dispatcher()
            assert_eq(#hl_configs, cfg_before + 1)
            assert_eq(hl_configs[#hl_configs].general.gaps_in, 0)
            assert_eq(hl_configs[#hl_configs].general.gaps_out, 0)
            assert_eq(hl_configs[#hl_configs].general.allow_tearing, true)
            assert_eq(hl_configs[#hl_configs].decoration.blur.enabled, false)
            assert_eq(hl_configs[#hl_configs].animations.enabled, false)

            by_chord["SUPER + SHIFT + Z"].dispatcher()
            assert_eq(#hl_configs, cfg_before + 2)
            assert_eq(hl_configs[#hl_configs].general.gaps_in, cfg.gaps_in)
            assert_eq(hl_configs[#hl_configs].general.gaps_out, cfg.gaps_out)
            assert_eq(hl_configs[#hl_configs].general.allow_tearing, false)
            assert_eq(hl_configs[#hl_configs].decoration.blur.enabled, true)
            assert_eq(hl_configs[#hl_configs].animations.enabled, true)
        end)
    end)
end

return register_tests
