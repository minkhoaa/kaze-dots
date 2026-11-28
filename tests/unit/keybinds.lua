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

        assert_eq(by_chord["SUPER + SPACE"].cmd, "kaze-shell msg launcher-toggle")
        assert_eq(by_chord["SUPER + SUPER_L"].release, true)
        assert_eq(by_chord["SUPER + A"].cmd, "kaze-shell msg cc-toggle")
        assert_eq(by_chord["SUPER + N"].cmd, "kaze-shell msg cc-toggle")
        assert_eq(by_chord["SUPER + I"].cmd, "kaze-shell msg cc-toggle")
        assert_eq(by_chord["SUPER + ALT + L"].cmd, "kaze-shell msg layout-next")
        assert_eq(by_chord["SUPER + ALT + I"].cmd, "kaze-shell msg island-toggle")
        assert_eq(by_chord["SUPER + SHIFT + T"].cmd, "kaze-shell msg theme-mode-toggle")
        assert_eq(by_chord["SUPER + V"].cmd, "kaze-shell msg clipboard-toggle")
        assert_contains(by_chord["SUPER + SHIFT + W"].cmd, "kaze-shell msg wallpaper-set")
        assert_eq(by_chord["CTRL + ALT + Delete"].cmd, "kaze-shell msg session-menu-toggle")
        assert_eq(by_chord["CTRL + ALT + C"].cmd, "kaze-shell msg notify-clear")
        assert_eq(by_chord["SUPER + SHIFT + N"].cmd, "kaze-shell msg dnd-toggle")
        assert_eq(by_chord["SUPER + SHIFT + D"].cmd, "kaze-shell msg nightlight-toggle")
        assert_contains(by_chord["SUPER + TAB"].cmd, "kaze-shell dmenu")
        assert_eq(by_chord["ALT + TAB"].cmd, "kaze-shell msg switcher-open next")
        assert_eq(by_chord["SHIFT + ALT + TAB"].cmd, "kaze-shell msg switcher-open prev")
        assert_eq(by_chord["SUPER + SHIFT + E"].cmd, "kaze-shell msg canvas-edit-toggle")
        assert_eq(by_chord["SUPER + SHIFT + B"].cmd, "kaze-shell msg dock-toggle")
        assert_eq(by_chord["XF86AudioRaiseVolume"].cmd, "kaze-shell msg volume-up")
        assert_eq(by_chord["XF86MonBrightnessUp"].cmd, "kaze-shell msg brightness-up")
        assert_eq(by_chord["XF86AudioPlay"].cmd, "kaze-shell msg media play-pause")
        assert_eq(by_chord["Print"].cmd, "kaze-shell msg capture full")
        assert_eq(by_chord["SUPER + SHIFT + S"].cmd, "kaze-shell msg capture region")
        assert_eq(by_chord["SUPER + SHIFT + ALT + S"].cmd, "kaze-shell msg capture window")
        assert_eq(by_chord["SUPER + SHIFT + C"].cmd, "kaze-shell msg color-picker")
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
        assert_eq(by_chord["CTRL + SUPER + ALT + R"].cmd, "kaze-shell msg reload && hyprctl reload")
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

            stub("kaze-shell", [[
if [ "$1" = "msg" ] && [ "$2" = "ping" ]; then
    printf 'pong\n'
    exit 0
fi
printf '%s\n' "$@" > "$HOME/kshell-args"
/usr/bin/cat > "$HOME/kshell-stdin"
]])
            assert(os.execute(run("")))
            assert_eq(fs.read_file(tmp .. "/kshell-args"), "dmenu\n-p\nKeys > \n")
            assert_eq(fs.read_file(tmp .. "/kshell-stdin"), list_out)
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
            assert_eq(by_chord["XF86AudioRaiseVolume"].dispatcher.cmd, "kaze-shell msg volume-up")
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

        -- Ghost Super-hold peek + precedence (DEFAULTS < kaze-style.lua < user.lua) + multi-bar Focus Mode
        local tmp_k = make_tmp_dir()
        local ok_k, err_k = pcall(function()
            local style_lua = tmp_k .. "/kaze-style.lua"
            local user_lua = tmp_k .. "/user.lua"
            fs.write_atomic(style_lua, [[
return {
    gaps_in = 0,
    gaps_out = 0,
    rounding = 14,
    ghost_super_peek = true,
    shadow = { enabled = true, range = 20, render_power = 3, color = "rgba(00000038)" },
}
]])
            fs.write_atomic(user_lua, [[
return {
    rounding = 4,
}
]])
            local merged = hypr_user.load({
                style_path = style_lua,
                user_path = user_lua,
                profile_path = tmp_k .. "/missing-profile",
            })
            assert_eq(merged.gaps_out, 0, "style overlay overrides DEFAULTS")
            assert_eq(merged.ghost_super_peek, true, "style overlay enables ghost_super_peek")
            assert_eq(merged.rounding, 4, "user.lua overrides style overlay")
            local vis_m = hypr_user.visual_config(merged)
            assert_eq(vis_m.decoration.shadow.enabled, true)
            assert_eq(vis_m.decoration.shadow.range, 20)

            -- Ghost Super tap (<0.25s) vs hold (>=0.25s)
            local g_by_chord, g_execs = {}, {}
            with_mock_hl({ cfg = merged }, function()
                rawset(_G, "hl", {
                    config = function() end,
                    bind = function(keys, dispatcher, opts)
                        g_by_chord[keys] = { keys = keys, dispatcher = dispatcher, opts = opts }
                    end,
                    define_submap = function() end,
                    exec_cmd = function(cmd) g_execs[#g_execs + 1] = cmd end,
                    dispatch = function() end,
                    dsp = {
                        exec_cmd = function(cmd) return { dsp = "exec_cmd", cmd = cmd } end,
                        focus = function(args) return { dsp = "focus", args = args } end,
                        submap = function(name) return { dsp = "submap", name = name } end,
                        group = { toggle = function() end, lock = function() end, next = function() end, prev = function() end },
                        window = {
                            close = function() end, fullscreen = function() end, float = function() end,
                            pin = function() end, center = function() end, set_prop = function() end,
                            cycle_next = function() end, move = function() end, drag = function() end, resize = function() end,
                        },
                        workspace = { toggle_special = function() end },
                    },
                })
                dofile(repo_dir .. "/hypr/keybinds.lua")
                assert_true(g_by_chord["SUPER_L"] ~= nil, "registers SUPER_L press bind in Ghost mode")
                assert_true(g_by_chord["SUPER_L"].opts.transparent and g_by_chord["SUPER_L"].opts.non_consuming)
                assert_true(g_by_chord["SUPER + SUPER_L"].opts.release and g_by_chord["SUPER + SUPER_L"].opts.ignore_mods)

                -- Quick tap opens launcher and hides peeked Ghost bar
                g_by_chord["SUPER_L"].dispatcher()
                assert_eq(g_execs[#g_execs], "kaze-shell msg bar-peek on >/dev/null 2>&1 || true")
                g_by_chord["SUPER + SUPER_L"].dispatcher()
                assert_eq(g_execs[#g_execs - 1], "kaze-shell msg bar-peek off >/dev/null 2>&1 || true")
                assert_eq(g_execs[#g_execs], "kaze-shell msg launcher-toggle")

                -- Hold >= 0.30s only hides Ghost peek without toggling launcher
                local before_hold = #g_execs
                g_by_chord["SUPER_L"].dispatcher()
                os.execute("sleep 0.30")
                g_by_chord["SUPER + SUPER_L"].dispatcher()
                assert_eq(#g_execs, before_hold + 2, "hold must not toggle launcher")
                assert_eq(g_execs[#g_execs], "kaze-shell msg bar-peek off >/dev/null 2>&1 || true")
            end)
        end)
        rm_rf(tmp_k)
        if not ok_k then error(err_k, 0) end
    end)
end

return register_tests
