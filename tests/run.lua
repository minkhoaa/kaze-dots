#!/usr/bin/env lua

local script_dir = (arg[0] or "tests/run.lua"):match("^(.*)/[^/]+$") or "."
local repo_dir = script_dir .. "/.."
package.path = table.concat({
    repo_dir .. "/lua/?.lua",
    repo_dir .. "/lua/?/init.lua",
    package.path,
}, ";")

local config = require("kaze.config")
local emit_fnott = require("kaze.emit_fnott")
local emit_foot = require("kaze.emit_foot")
local emit_fuzzel = require("kaze.emit_fuzzel")
local emit_hyprlock = require("kaze.emit_hyprlock")
local emit_waybar = require("kaze.emit_waybar")
local fs = require("kaze.fs")
local layouts = require("kaze.layouts")
local state = require("kaze.state")
local themes = require("kaze.themes")

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

local function assert_balanced(str, open_ch, close_ch, label)
    local depth = 0
    local in_str = false
    local esc = false
    for i = 1, #str do
        local c = str:sub(i, i)
        if in_str then
            if esc then
                esc = false
            elseif c == "\\" then
                esc = true
            elseif c == '"' then
                in_str = false
            end
        else
            if c == '"' then
                in_str = true
            elseif c == open_ch then
                depth = depth + 1
            elseif c == close_ch then
                depth = depth - 1
                if depth < 0 then
                    error(string.format("%s: unmatched %s at byte %d", label, close_ch, i), 2)
                end
            end
        end
    end
    if depth ~= 0 then
        error(string.format("%s: unclosed %s (depth=%d)", label, open_ch, depth), 2)
    end
end

-- Minimal strict JSON parser for validating stripped config.jsonc
local function parse_json(src)
    local pos = 1
    local len = #src
    local parse_val

    local function skip_ws()
        while pos <= len do
            local b = src:byte(pos)
            if b == 32 or b == 9 or b == 10 or b == 13 then
                pos = pos + 1
            else
                break
            end
        end
    end

    local function parse_str()
        pos = pos + 1
        local out = {}
        while pos <= len do
            local c = src:sub(pos, pos)
            if c == '"' then
                pos = pos + 1
                return table.concat(out)
            elseif c == "\\" then
                pos = pos + 1
                local e = src:sub(pos, pos)
                if e == "" then
                    error("unterminated escape in JSON string")
                end
                out[#out + 1] = e
                pos = pos + 1
            else
                out[#out + 1] = c
                pos = pos + 1
            end
        end
        error("unterminated JSON string")
    end

    local function parse_num()
        local s = src:sub(pos):match("^-?%d+%.?%d*[eE]?[+-]?%d*")
        local n = tonumber(s)
        if not n then
            error("invalid JSON number at " .. pos)
        end
        pos = pos + #s
        return n
    end

    local function parse_arr()
        pos = pos + 1
        local arr = {}
        skip_ws()
        if src:sub(pos, pos) == "]" then
            pos = pos + 1
            return arr
        end
        while true do
            arr[#arr + 1] = parse_val()
            skip_ws()
            local c = src:sub(pos, pos)
            if c == "," then
                pos = pos + 1
            elseif c == "]" then
                pos = pos + 1
                return arr
            else
                error("expected ',' or ']' in JSON array at " .. pos)
            end
        end
    end

    local function parse_obj()
        pos = pos + 1
        local obj = {}
        skip_ws()
        if src:sub(pos, pos) == "}" then
            pos = pos + 1
            return obj
        end
        while true do
            skip_ws()
            if src:sub(pos, pos) ~= '"' then
                error("expected JSON string key at " .. pos)
            end
            local k = parse_str()
            skip_ws()
            if src:sub(pos, pos) ~= ":" then
                error("expected ':' after JSON key at " .. pos)
            end
            pos = pos + 1
            obj[k] = parse_val()
            skip_ws()
            local c = src:sub(pos, pos)
            if c == "," then
                pos = pos + 1
            elseif c == "}" then
                pos = pos + 1
                return obj
            else
                error("expected ',' or '}' in JSON object at " .. pos)
            end
        end
    end

    parse_val = function()
        skip_ws()
        local c = src:sub(pos, pos)
        if c == "{" then
            return parse_obj()
        elseif c == "[" then
            return parse_arr()
        elseif c == '"' then
            return parse_str()
        elseif c == "t" and src:sub(pos, pos + 3) == "true" then
            pos = pos + 4
            return true
        elseif c == "f" and src:sub(pos, pos + 4) == "false" then
            pos = pos + 5
            return false
        elseif c == "n" and src:sub(pos, pos + 3) == "null" then
            pos = pos + 4
            return nil
        elseif c == "-" or (c >= "0" and c <= "9") then
            return parse_num()
        end
        error("unexpected JSON token at " .. pos .. ": " .. src:sub(pos, pos + 12))
    end

    local res = parse_val()
    skip_ws()
    if pos <= len then
        error("trailing garbage after JSON at " .. pos)
    end
    return res
end

local function strip_jsonc_comments(s)
    local lines = {}
    for line in (s .. "\n"):gmatch("([^\n]*)\n") do
        if not line:match("^%s*//") then
            lines[#lines + 1] = line
        end
    end
    return table.concat(lines, "\n")
end

local function make_tmp_dir()
    local d = string.format("/tmp/kaze-test-%d-%d", os.time(), math.random(100000, 999999))
    fs.mkdir_p(d)
    return d
end

local function rm_rf(dir)
    os.execute("rm -rf " .. fs.shell_quote(dir))
end

local function cmd_exists(bin)
    local ok = os.execute("command -v " .. fs.shell_quote(bin) .. " >/dev/null 2>&1")
    return ok == true or ok == 0
end

io.stdout:write("Running kaze-dots unit tests...\n")

test("themes: all 5 presets validate and helpers format properly", function()
    local list = themes.list()
    assert_eq(#list, 5, "preset count")
    assert_eq(list[1], "kaze", "first theme")
    assert_eq(list[2], "lavender", "second theme")
    assert_eq(list[3], "tokyonight", "third theme")
    assert_eq(list[4], "carbon", "fourth theme")
    assert_eq(list[5], "paper", "fifth theme")

    for _, name in ipairs(list) do
        local t = themes.get(name)
        assert_eq(t.name, name, "theme.name")
        assert_eq(#t.term, 16, "16 ANSI colors")
        assert_eq(themes.hex(t.bg), "#" .. t.bg, "hex")
        assert_eq(themes.hex_alpha(t.accent, "cc"), t.accent .. "cc", "hex_alpha")
        assert_eq(themes.hypr_rgba(t.accent, "cc"), "rgba(" .. t.accent .. "cc)", "hypr_rgba")
    end

    local overridden = themes.get("kaze", { accent = "ff00aa", term = nil })
    assert_eq(overridden.accent, "ff00aa", "theme override applied")

    local bad_ok = pcall(themes.validate, { bg = "#111318" })
    assert_true(not bad_ok, "themes.validate must reject '#' prefix or missing keys")
    local unk_ok = pcall(themes.get, "nonexistent")
    assert_true(not unk_ok, "themes.get must reject unknown preset")
end)

test("fs: shell_quote and atomic write work safely", function()
    assert_eq(fs.shell_quote("a'b c"), "'a'\\''b c'", "shell_quote")
    local tmp = make_tmp_dir()
    local target = tmp .. "/nested/dir/file.txt"
    fs.write_atomic(target, "hello kaze\n")
    local content = fs.read_file(target)
    assert_eq(content, "hello kaze\n", "atomic file readback")
    rm_rf(tmp)
end)

test("state: save, load, and corrupt file recovery", function()
    local tmp = make_tmp_dir()
    local sp = tmp .. "/kaze/state.lua"
    state.save({ layout = "sidebar", theme = "tokyonight" }, sp)
    local loaded = state.load(sp)
    assert_eq(loaded.layout, "sidebar", "state layout")
    assert_eq(loaded.theme, "tokyonight", "state theme")

    fs.write_atomic(sp, "this is invalid lua @@@")
    local recovered = state.load(sp)
    assert_eq(next(recovered), nil, "corrupt state recovers to empty table")
    rm_rf(tmp)
end)

test("config: precedence defaults -> layout -> state -> user.lua + malformed fallback", function()
    local tmp = make_tmp_dir()
    local cfg_dir = tmp .. "/config"
    local state_path = cfg_dir .. "/kaze/state.lua"
    local user_path = cfg_dir .. "/kaze/user.lua"

    state.save({ layout = "islands", theme = "lavender" }, state_path)
    fs.write_atomic(user_path, [[
return {
    theme = "tokyonight",
    font = "Iosevka Nerd Font",
    hypr = { gaps_in = 8 },
    theme_overrides = { accent = "ff9e64" },
}
]])

    local cfg, theme, layout = config.load({
        home = tmp,
        config_dir = cfg_dir,
        state_path = state_path,
        user_path = user_path,
        strict = true,
    })

    assert_eq(cfg.layout, "islands", "layout preserved")
    assert_eq(cfg.theme, "tokyonight", "user.lua overrides state.lua theme")
    assert_eq(cfg.font, "Iosevka Nerd Font", "user.lua overrides font")
    assert_eq(layout.hypr.gaps_in, 8, "user.lua overrides layout hypr.gaps_in")
    assert_eq(layout.hypr.gaps_out, 10, "layout supplies un-overridden hypr.gaps_out")
    assert_eq(theme.accent, "ff9e64", "theme_overrides applied")
    assert_eq(cfg.wallpaper_expanded, tmp .. "/Pictures/Wallpapers/wallpaper.png", "tilde expanded")

    -- Malformed user.lua must not crash config.load
    fs.write_atomic(user_path, "return { broken = ")
    local cfg2, theme2 = config.load({
        home = tmp,
        config_dir = cfg_dir,
        state_path = state_path,
        user_path = user_path,
        strict = true,
    })
    assert_eq(cfg2.theme, "lavender", "fallback to state.lua when user.lua has syntax error")
    assert_eq(theme2.name, "lavender", "fallback theme resolved")

    -- Non-strict fallback on unknown layout/theme in state
    state.save({ layout = "badlayout", theme = "badtheme" }, state_path)
    local cfg3, theme3, layout3 = config.load({
        home = tmp,
        config_dir = cfg_dir,
        state_path = state_path,
        user_path = user_path,
        strict = false,
    })
    assert_eq(cfg3.layout, "sidebar", "non-strict layout fallback")
    assert_eq(layout3.name, "sidebar", "non-strict layout spec fallback")
    assert_eq(theme3.name, "kaze", "non-strict theme fallback")

    local strict_ok = pcall(config.load, {
        home = tmp,
        config_dir = cfg_dir,
        state_path = state_path,
        user_path = user_path,
        strict = true,
    })
    assert_true(not strict_ok, "strict mode must fail on unknown layout/theme")

    rm_rf(tmp)
end)

test("layouts: registry contains sidebar, islands, and slim", function()
    local list = layouts.list()
    assert_eq(#list, 3, "layout count")
    assert_eq(list[1], "sidebar", "first layout")
    assert_eq(list[2], "islands", "second layout")
    assert_eq(list[3], "slim", "third layout")

    local unk_ok = pcall(layouts.get, "nonexistent")
    assert_true(not unk_ok, "layouts.get must reject unknown layout")
end)

local function assert_no_unresolved_tokens(text, label)
    assert_true(not text:find("{{", 1, true), label .. ": unresolved '{{' token")
    assert_true(not text:find("}}", 1, true), label .. ": unresolved '}}' token")
    assert_true(not text:find("%s", 1, true), label .. ": unresolved '%s' token")
    assert_true(not text:find("rgb(nil)", 1, true), label .. ": unresolved nil rgb")
    assert_true(not text:find("rgba(nil", 1, true), label .. ": unresolved nil rgba")
    assert_true(not text:find("=nil", 1, true), label .. ": unresolved nil value")
end

test("emitters: all 3 layouts x 5 themes (15 combinations) produce valid configs with zero polling", function()
    local tmp = make_tmp_dir()
    local has_foot = cmd_exists("foot")
    local has_fuzzel = cmd_exists("fuzzel")

    local expected = {
        sidebar = {
            position = "left",
            width = 42,
            margin_top = 8,
            margin_bottom = 8,
            margin_left = 8,
            margin_right = 0,
            fuzzel_radius = 0,
            fnott_radius = 0,
            fnott_vmargin = 8,
        },
        islands = {
            position = "top",
            height = 34,
            margin_top = 6,
            margin_left = 10,
            margin_right = 10,
            fuzzel_radius = 0,
            fnott_radius = 0,
            fnott_vmargin = 8,
        },
        slim = {
            position = "top",
            height = 28,
            margin_top = 0,
            margin_left = 0,
            margin_right = 0,
            fuzzel_radius = 0,
            fnott_radius = 0,
            fnott_vmargin = 8,
        },
    }

    local combo_count = 0
    for _, layout_name in ipairs(layouts.list()) do
        local layout = layouts.get(layout_name)
        local exp = expected[layout_name]
        assert_true(exp ~= nil, "missing expectation table for " .. layout_name)

        for _, theme_name in ipairs(themes.list()) do
            combo_count = combo_count + 1
            local theme = themes.get(theme_name)
            local tag = layout_name .. "/" .. theme_name
            local cfg = {
                layout = layout_name,
                theme = theme_name,
                font = "JetBrainsMono Nerd Font",
                terminal = "footclient",
                cursor_theme = "Adwaita",
                wallpaper_expanded = "/home/bench/Pictures/Wallpapers/wallpaper.png",
                hypr = layout.hypr,
                ui = layout.ui,
            }

            local wb = emit_waybar.emit(cfg, theme, layout)
            assert_true(#wb.colors_css > 0, tag .. ": colors.css non-empty")
            assert_true(#wb.config_jsonc > 0, tag .. ": config.jsonc non-empty")
            assert_true(#wb.style_css > 0, tag .. ": style.css non-empty")
            assert_contains(wb.colors_css, "@define-color accent    #" .. theme.accent .. ";", tag .. ": waybar colors.css")
            assert_contains(wb.style_css, '@import "colors.css";', tag .. ": waybar style.css import")
            assert_balanced(wb.style_css, "{", "}", tag .. ": waybar style.css")
            assert_no_unresolved_tokens(wb.colors_css, tag .. ": waybar colors.css")
            assert_no_unresolved_tokens(wb.config_jsonc, tag .. ": waybar config.jsonc")
            assert_no_unresolved_tokens(wb.style_css, tag .. ": waybar style.css")

            local stripped = strip_jsonc_comments(wb.config_jsonc)
            local parsed = parse_json(stripped)
            assert_eq(parsed.position, exp.position, tag .. ": position")
            if exp.height then
                assert_eq(parsed.height, exp.height, tag .. ": height")
            end
            if exp.width then
                assert_eq(parsed.width, exp.width, tag .. ": width")
            end
            assert_eq(parsed["margin-top"], exp.margin_top, tag .. ": margin-top")
            assert_eq(parsed["margin-left"], exp.margin_left, tag .. ": margin-left")
            assert_eq(parsed["margin-right"], exp.margin_right, tag .. ": margin-right")
            if exp.margin_bottom then
                assert_eq(parsed["margin-bottom"], exp.margin_bottom, tag .. ": margin-bottom")
            end
            assert_eq(parsed["custom/menu"].exec, nil, tag .. ": custom/menu must have zero polling exec")
            assert_eq(parsed["custom/menu"].interval, nil, tag .. ": custom/menu must have zero polling interval")
            assert_eq(parsed["custom/power"].exec, nil, tag .. ": custom/power must have zero polling exec")
            assert_eq(parsed["custom/power"].interval, nil, tag .. ": custom/power must have zero polling interval")
            assert_eq(parsed.clock["on-click"], "kaze-dashboard", tag .. ": clock opens top dashboard")
            assert_eq(parsed.clock["on-click-right"], "kaze-dashboard --perf", tag .. ": clock right-click opens perf tab")
            assert_eq(parsed.battery["on-click"], "kaze-panel", tag .. ": battery opens right control panel")
            assert_eq(parsed.network["on-click"], "kaze-panel --wifi", tag .. ": network opens inline wifi panel")
            assert_eq(parsed.network["on-click-right"], "kaze-tui wifi", tag .. ": network right-click opens nmtui")
            assert_eq(parsed.wireplumber["on-click"], "kaze-audio-sink", tag .. ": wireplumber opens right sink switcher")
            assert_contains(table.concat(parsed["modules-right"], " "), "custom/dnd", tag .. ": missing dnd indicator")
            local dnd_ind = assert(parsed["custom/dnd"])
            assert_eq(dnd_ind.interval, "once", "custom/dnd must not poll")
            assert_eq(dnd_ind.signal, 10, "custom/dnd signal 10")
            assert_eq(dnd_ind["on-click"], "kaze-dnd off")
            assert_eq(dnd_ind["on-click-right"], "kaze-dashboard --notifications")
            for _, feature in ipairs({ { "recording", "record", 8, "stop" }, { "night", "night", 9, "off" },
                { "inhibit", "inhibit", 11, "off" } }) do
                local name, unit, signal, action = table.unpack(feature)
                local mod = "custom/" .. name
                assert_contains(table.concat(parsed["modules-right"], " "), mod, tag .. ": missing indicator slot")
                local indicator = assert(parsed[mod])
                assert_eq(indicator.interval, "once", mod .. " must not poll")
                assert_eq(indicator.signal, signal)
                assert_eq(indicator["exec-on-event"], false)
                assert_eq(indicator["on-click"], "kaze-" .. unit .. " " .. action)
                assert_contains(indicator.exec, "show -p SubState --value kaze-" .. unit .. ".service")
                local service = assert(fs.read_file(repo_dir .. "/config/systemd/user/kaze-" .. unit .. ".service"))
                for _, phase in ipairs({ "Start", "Stop" }) do
                    assert_contains(service, "Exec" .. phase .. "Post=-/usr/bin/pkill -RTMIN+" .. signal .. " -x")
                end
            end
            assert_contains(table.concat(parsed["modules-right"], " "), "custom/passthrough", tag .. ": missing passthrough indicator")
            local pt_ind = assert(parsed["custom/passthrough"])
            assert_eq(pt_ind.interval, "once", "custom/passthrough must not poll")
            assert_eq(pt_ind.signal, 12, "custom/passthrough signal 12")
            assert_eq(pt_ind["exec-on-event"], false)
            assert_contains(pt_ind.exec, "hyprctl submap")
            assert_contains(pt_ind["on-click"], "hl.dsp.submap('reset')")

            local pal_out = require("kaze.emit_palette").emit(cfg, theme, layout)
            local pal_chunk = assert(load(pal_out.lua, "=palette.lua", "t", {}))
            local pal_tbl = pal_chunk()
            assert_eq(pal_tbl.name, theme_name)
            assert_eq(pal_tbl.polarity, theme_name == "paper" and "light" or "dark")
            assert_eq(pal_tbl.accent, "#" .. theme.accent)
            assert_eq(pal_tbl.raw.accent, theme.accent)
            local pal_json = require("kaze.json").decode(pal_out.json)
            assert_eq(pal_json.colors.bg, "#" .. theme.bg)
            assert_eq(#pal_json.term, 16)
            assert_contains(pal_out.sh, "KAZE_ACCENT='#" .. theme.accent .. "'")

            local foot_ini = emit_foot.emit(cfg, theme, layout)
            assert_contains(foot_ini, "background=" .. theme.bg, tag .. ": foot background")
            assert_no_unresolved_tokens(foot_ini, tag .. ": foot.ini")
            if has_foot then
                local fp = tmp .. "/foot-" .. layout_name .. "-" .. theme_name .. ".ini"
                fs.write_atomic(fp, foot_ini)
                local ok = os.execute("foot --check-config -c " .. fs.shell_quote(fp) .. " >/dev/null 2>&1")
                assert_true(ok == true or ok == 0, "foot --check-config failed for " .. tag)
            end

            local fuzzel_ini = emit_fuzzel.emit(cfg, theme, layout)
            assert_contains(fuzzel_ini, "anchor=top\n", tag .. ": fuzzel anchored top")
            assert_contains(fuzzel_ini, "y-margin=" .. tostring(layout.ui.popup_top_y) .. "\n", tag .. ": fuzzel y-margin")
            assert_contains(fuzzel_ini, "message=" .. theme.fg .. "ff\n", tag .. ": fuzzel message color")
            assert_contains(fuzzel_ini, "width=2\nradius=" .. exp.fuzzel_radius, tag .. ": fuzzel sharp border")
            assert_contains(
                fuzzel_ini,
                "selection-radius=0\n",
                tag .. ": fuzzel selection-radius"
            )
            assert_contains(fuzzel_ini, "background=" .. theme.bg_alt .. "e8", tag .. ": fuzzel bg")
            assert_no_unresolved_tokens(fuzzel_ini, tag .. ": fuzzel.ini")
            if has_fuzzel then
                local zp = tmp .. "/fuzzel-" .. layout_name .. "-" .. theme_name .. ".ini"
                fs.write_atomic(zp, fuzzel_ini)
                local ok = os.execute("fuzzel --check-config --config " .. fs.shell_quote(zp) .. " >/dev/null 2>&1")
                assert_true(ok == true or ok == 0, "fuzzel --check-config failed for " .. tag)
            end

            local fnott_ini = emit_fnott.emit(cfg, theme, layout)
            assert_contains(fnott_ini, "dpi-aware=no", tag .. ": fnott dpi-aware")
            assert_contains(fnott_ini, "icon-theme=hicolor", tag .. ": fnott icon-theme")
            assert_contains(fnott_ini, "stacking-order=top-down", tag .. ": fnott stacking-order")
            assert_contains(fnott_ini, "min-width=280", tag .. ": fnott min-width")
            assert_contains(fnott_ini, "max-width=360", tag .. ": fnott max-width")
            assert_contains(fnott_ini, "notification-margin=10", tag .. ": fnott notification-margin")
            assert_contains(fnott_ini, "max-icon-size=40", tag .. ": fnott max-icon-size")
            assert_contains(fnott_ini, "background=" .. theme.bg_alt .. "f2", tag .. ": fnott background")
            assert_contains(fnott_ini, "title-color=" .. theme.accent .. "dd", tag .. ": fnott title-color")
            assert_contains(fnott_ini, "summary-format=%s", tag .. ": fnott summary-format")
            assert_contains(fnott_ini, "progress-bar-height=6", tag .. ": fnott progress-bar-height")
            assert_contains(fnott_ini, "progress-color=" .. theme.accent .. "ff", tag .. ": fnott progress-color")
            assert_contains(fnott_ini, "border-radius=" .. exp.fnott_radius, tag .. ": fnott radius")
            assert_contains(fnott_ini, "edge-margin-vertical=" .. exp.fnott_vmargin, tag .. ": fnott vertical margin")
            assert_no_unresolved_tokens(fnott_ini:gsub("summary%-format=%%s", "summary-format=SUMMARY"), tag .. ": fnott.ini")

            local mako = require("kaze.emit_mako").emit(cfg, theme, layout)
            assert_contains(mako, "width=360", tag .. ": mako width")
            assert_contains(mako, "padding=14,18", tag .. ": mako padding")
            assert_contains(mako, "max-icon-size=40", tag .. ": mako max-icon-size")
            assert_contains(mako, "background-color=#" .. theme.bg_alt .. "f0")
            assert_contains(mako, "outer-margin=" .. exp.fnott_vmargin .. ",")
            assert_contains(mako, "[app-name=kaze-osd]\nhistory=0\n\n[mode=do-not-disturb]\ninvisible=1\n\n"
                .. "[mode=do-not-disturb app-name=kaze-osd]\ninvisible=0\n")
            assert_no_unresolved_tokens(mako, tag .. ": mako config")

            local hl_conf = emit_hyprlock.emit(cfg, theme, layout)
            assert_contains(hl_conf, "rgb(" .. theme.accent .. ")", tag .. ": hyprlock accent")
            assert_contains(hl_conf, "rgb(" .. theme.fg_muted .. ")", tag .. ": hyprlock fg_muted")
            assert_contains(hl_conf, "cmd[update:15000]", tag .. ": hyprlock bottom status updater")
            assert_contains(hl_conf, "valign = bottom", tag .. ": hyprlock bottom status valign")
            assert_balanced(hl_conf, "{", "}", tag .. ": hyprlock.conf")
            assert_no_unresolved_tokens(hl_conf, tag .. ": hyprlock.conf")
        end
    end
    assert_eq(combo_count, 15, "3 layouts x 5 themes combinations")

    rm_rf(tmp)
end)

local function read_cmd(cmd)
    local p = io.popen(cmd)
    if not p then
        return ""
    end
    local out = p:read("*a") or ""
    p:close()
    return out
end

test("CLI: kaze-sync, kaze-layout, kaze-theme, kaze-menu, kaze-power behave properly", function()
    local tmp = make_tmp_dir()
    local env_prefix = string.format(
        "HOME=%s XDG_CONFIG_HOME=%s XDG_RUNTIME_DIR=%s HYPRLAND_INSTANCE_SIGNATURE='' WAYLAND_DISPLAY=''",
        fs.shell_quote(tmp),
        fs.shell_quote(tmp .. "/cfg"),
        fs.shell_quote(tmp .. "/runtime")
    )

    local ok_check = os.execute(env_prefix .. " " .. fs.shell_quote(repo_dir .. "/bin/kaze-sync") .. " --check >/dev/null 2>&1")
    assert_true(ok_check == true or ok_check == 0, "kaze-sync --check exit 0")
    assert_true(not fs.file_exists(tmp .. "/cfg/waybar/config.jsonc"), "--check must not write files")

    local ok_run = os.execute(env_prefix .. " " .. fs.shell_quote(repo_dir .. "/bin/kaze-sync") .. " >/dev/null 2>&1")
    assert_true(ok_run == true or ok_run == 0, "kaze-sync exit 0")

    local expected_files = {
        "/cfg/waybar/colors.css",
        "/cfg/waybar/config.jsonc",
        "/cfg/waybar/style.css",
        "/cfg/foot/foot.ini",
        "/cfg/fuzzel/fuzzel.ini",
        "/cfg/fnott/fnott.ini",
        "/cfg/hypr/hyprlock.conf",
    }
    for _, rel in ipairs(expected_files) do
        assert_true(fs.file_exists(tmp .. rel), "missing generated file: " .. rel)
    end

    local cur_layout = read_cmd(env_prefix .. " " .. fs.shell_quote(repo_dir .. "/bin/kaze-layout") .. " --current"):gsub("[\r\n]+$", "")
    assert_eq(cur_layout, "sidebar", "default layout")

    for _, lname in ipairs({ "islands", "slim", "sidebar" }) do
        local ok_l = os.execute(env_prefix .. " " .. fs.shell_quote(repo_dir .. "/bin/kaze-layout") .. " " .. lname .. " >/dev/null 2>&1")
        assert_true(ok_l == true or ok_l == 0, "kaze-layout " .. lname .. " exit 0")
        local got_l = read_cmd(env_prefix .. " " .. fs.shell_quote(repo_dir .. "/bin/kaze-layout") .. " --current"):gsub("[\r\n]+$", "")
        assert_eq(got_l, lname, "layout persisted after switch")
    end

    for _, tname in ipairs({ "lavender", "tokyonight", "carbon", "kaze" }) do
        local ok_t = os.execute(env_prefix .. " " .. fs.shell_quote(repo_dir .. "/bin/kaze-theme") .. " " .. tname .. " >/dev/null 2>&1")
        assert_true(ok_t == true or ok_t == 0, "kaze-theme " .. tname .. " exit 0")
        local got_t = read_cmd(env_prefix .. " " .. fs.shell_quote(repo_dir .. "/bin/kaze-theme") .. " --current"):gsub("[\r\n]+$", "")
        assert_eq(got_t, tname, "theme persisted after switch")
        local colors_css = fs.read_file(tmp .. "/cfg/waybar/colors.css")
        assert_contains(colors_css, "#" .. themes.get(tname).accent, "colors.css updated for " .. tname)
    end

    local ok_q_layout = os.execute(env_prefix .. " " .. fs.shell_quote(repo_dir .. "/bin/kaze-layout") .. " --quiet islands >/dev/null 2>&1")
    assert_true(ok_q_layout == true or ok_q_layout == 0, "kaze-layout --quiet exit 0")
    local ok_q_theme = os.execute(env_prefix .. " " .. fs.shell_quote(repo_dir .. "/bin/kaze-theme") .. " --quiet carbon >/dev/null 2>&1")
    assert_true(ok_q_theme == true or ok_q_theme == 0, "kaze-theme --quiet exit 0")

    local bad_sync = os.execute(env_prefix .. " " .. fs.shell_quote(repo_dir .. "/bin/kaze-sync") .. " --invalid >/dev/null 2>&1")
    assert_true(bad_sync ~= true and bad_sync ~= 0, "kaze-sync --invalid must fail")

    local bad_layout = os.execute(env_prefix .. " " .. fs.shell_quote(repo_dir .. "/bin/kaze-layout") .. " bogus >/dev/null 2>&1")
    assert_true(bad_layout ~= true and bad_layout ~= 0, "kaze-layout bogus must fail")

    local bad_theme = os.execute(env_prefix .. " " .. fs.shell_quote(repo_dir .. "/bin/kaze-theme") .. " bogus >/dev/null 2>&1")
    assert_true(bad_theme ~= true and bad_theme ~= 0, "kaze-theme bogus must fail")

    local bad_tui = os.execute(fs.shell_quote(repo_dir .. "/bin/kaze-tui") .. " bogus >/dev/null 2>&1")
    assert_true(bad_tui ~= true and bad_tui ~= 0, "kaze-tui bogus must fail")

    local bad_osd = os.execute(fs.shell_quote(repo_dir .. "/bin/kaze-osd") .. " bogus >/dev/null 2>&1")
    assert_true(bad_osd ~= true and bad_osd ~= 0, "kaze-osd bogus must fail")

    local help_menu = os.execute(fs.shell_quote(repo_dir .. "/bin/kaze-menu") .. " --help >/dev/null 2>&1")
    assert_true(help_menu == true or help_menu == 0, "kaze-menu --help exit 0")
    local bad_menu = os.execute(fs.shell_quote(repo_dir .. "/bin/kaze-menu") .. " --bogus >/dev/null 2>&1")
    assert_true(bad_menu ~= true and bad_menu ~= 0, "kaze-menu --bogus must fail")

    local help_power = os.execute(fs.shell_quote(repo_dir .. "/bin/kaze-power") .. " --help >/dev/null 2>&1")
    assert_true(help_power == true or help_power == 0, "kaze-power --help exit 0")
    local bad_power = os.execute(fs.shell_quote(repo_dir .. "/bin/kaze-power") .. " --bogus >/dev/null 2>&1")
    assert_true(bad_power ~= true and bad_power ~= 0, "kaze-power --bogus must fail")

    rm_rf(tmp)
end)

local function with_stubs(fn)
    local tmp = make_tmp_dir()
    fs.mkdir_p(tmp .. "/bin")
    fs.mkdir_p(tmp .. "/runtime")
    local env = string.format("env -u CLIPBOARD_STATE HOME=%s XDG_RUNTIME_DIR=%s XDG_CONFIG_HOME=%s XDG_DATA_HOME=%s XDG_CACHE_HOME=%s PATH=%s:$PATH",
        fs.shell_quote(tmp), fs.shell_quote(tmp .. "/runtime"), fs.shell_quote(tmp .. "/cfg"), fs.shell_quote(tmp .. "/data"),
        fs.shell_quote(tmp .. "/cache"), fs.shell_quote(tmp .. "/bin"))
    local function stub(name, body)
        local path = tmp .. "/bin/" .. name
        fs.write_atomic(path, "#!/bin/sh\nset -eu\n" .. body .. "\n")
        assert(os.execute("chmod +x -- " .. fs.shell_quote(path)))
    end
    local function run(cli, args, vars, path)
        return env .. " " .. (vars or "") .. " " .. fs.shell_quote(path or (repo_dir .. "/bin/" .. cli)) .. " " .. args
    end
    local ok, err = pcall(fn, tmp, stub, run)
    rm_rf(tmp)
    if not ok then error(err, 0) end
end

test("menu: stage 2 actions appear only when their optional tools are available", function()
    with_stubs(function(tmp, stub, run)
        for _, bin in ipairs({ "lua", "readlink" }) do
            local actual = assert(fs.capture("command -v " .. bin)):gsub("\n$", "")
            assert(os.execute("ln -s " .. fs.shell_quote(actual) .. " " .. fs.shell_quote(tmp .. "/bin/" .. bin)))
        end
        stub("pgrep", "exit 1")
        stub("fuzzel", [[/usr/bin/cat > "$HOME/items"]])
        local function menu()
            assert(os.execute(run("kaze-menu", "", "PATH=" .. fs.shell_quote(tmp .. "/bin"))))
            return assert(fs.read_file(tmp .. "/items"))
        end
        local labels = { "Annotate Screenshot", "Pick Color", "Toggle Screen Recording", "Toggle Region Recording", "Toggle Night Light", "Toggle Caffeine" }
        local minimal = menu()
        for _, label in ipairs(labels) do assert_true(not minimal:find(label, 1, true), label .. " leaks into minimal") end
        for _, bin in ipairs({ "swappy", "grim", "slurp", "hyprpicker", "wl-copy", "wf-recorder", "ffprobe", "flock",
            "hyprsunset", "systemd-inhibit" }) do stub(bin, "exit 99") end
        local full = menu()
        for _, label in ipairs(labels) do assert_contains(full, label) end
    end)
end)

test("apply: reapply preserves the uninstall baseline, custom symlinks and user.lua", function()
    with_stubs(function(tmp)
        local q = fs.shell_quote
        local cfg, data = tmp .. "/config space", tmp .. "/data space"
        local unit, style = cfg .. "/systemd/user/kaze-waybar.service", cfg .. "/waybar/style.css"
        local foot = cfg .. "/foot/foot.ini"
        fs.write_atomic(cfg .. "/kaze/user.lua", "return {} -- original user settings\n")
        fs.write_atomic(unit, "original unit\n")
        fs.write_atomic(style, "/* custom */\n/* Auto-generated by kaze-sync — note in body */\n")
        fs.mkdir_p(fs.dirname(foot))
        assert(os.execute("ln -s -- /nonexistent/fixture " .. q(foot)))
        local env = ("env HOME=%s XDG_CONFIG_HOME=%s XDG_DATA_HOME=%s XDG_RUNTIME_DIR=%s"):format(
            q(tmp), q(cfg), q(data), q(tmp .. "/runtime"))
        local apply = env .. " " .. q(repo_dir .. "/scripts/apply.sh") .. " --yes >/dev/null"
        local last = cfg .. "/kaze/last-backup"
        assert(os.execute(apply))
        local first = assert(fs.read_file(last)):gsub("\n$", "")
        assert(os.execute(apply))
        local second = assert(fs.read_file(last)):gsub("\n$", "")
        assert_true(first ~= second)
        local manifest = assert(fs.read_file(second .. "/installed.list"))
        assert_contains(manifest, tmp .. "/.local/bin/kaze-sync\n", "unchanged symlink tracked on reapply")
        assert_contains(manifest, data .. "/dbus-1/services/org.freedesktop.Notifications.service\n")
        for _, name in ipairs({ "record", "night", "inhibit" }) do
            assert_contains(manifest, tmp .. "/.local/bin/kaze-" .. name .. "\n")
            assert_contains(manifest, cfg .. "/systemd/user/kaze-" .. name .. ".service\n")
        end
        assert_true(not fs.file_exists(second .. "/reapply/config space/waybar/style.css"), "generated file must not be backed up again")
        local function rollback(dir)
            return os.execute(env .. " " .. q(dir .. "/rollback.sh") .. " --yes >/dev/null 2>&1")
        end
        assert_true(not rollback(first), "stale rollback must be rejected")
        assert(rollback(second))
        assert_eq(fs.read_file(unit), "original unit\n")
        assert_contains(assert(fs.read_file(style)), "/* custom */")
        assert_eq(fs.capture("readlink -- " .. q(foot)), "/nonexistent/fixture\n")
        assert_eq(fs.read_file(cfg .. "/kaze/user.lua"), "return {} -- original user settings\n")
        assert_true(not fs.file_exists(last), "rollback unregisters active backup")
        for _, path in ipairs({ tmp .. "/.local/bin/kaze-sync", data .. "/kaze-dots/lua/kaze", cfg .. "/waybar/config.jsonc" }) do
            assert(os.execute("test ! -e " .. q(path) .. " && test ! -L " .. q(path)))
        end
        for _, name in ipairs({ "record", "night", "inhibit" }) do
            assert(os.execute("test ! -L " .. q(tmp .. "/.local/bin/kaze-" .. name)))
            assert(os.execute("test ! -L " .. q(cfg .. "/systemd/user/kaze-" .. name .. ".service")))
        end
        assert_true(not rollback(second), "a second rollback cannot delete restored files")
    end)
end)

test("CLIs: copied and symlinked helpers find XDG modules, retain wait and propagate status", function()
    assert_eq(fs.exit_status(nil, nil, nil), 1, "spawn failure")
    assert_eq(fs.exit_status(nil, "signal", 15), 143, "signal status")
    with_stubs(function(tmp, stub, run)
        local q = fs.shell_quote
        local target = tmp .. "/data/kaze-dots/lua"
        fs.mkdir_p(fs.dirname(target))
        local repo = assert(fs.capture("readlink -f -- " .. q(repo_dir))):gsub("\n$", "")
        assert(os.execute("ln -s -- " .. q(repo .. "/lua") .. " " .. q(target)))
        local tools = tmp .. "/outside 'bin'"
        fs.mkdir_p(tools)
        for _, cli in ipairs({ "kaze-footclient", "kaze-session", "kaze-clipboard", "kaze-screenshot" }) do
            assert(os.execute("cp -- " .. q(repo .. "/bin/" .. cli) .. " " .. q(tools .. "/" .. cli)))
        end
        stub("footclient", [[
[ "$1" = -E ]
printf '%s\n' "$@" > "$HOME/client-args"
if [ "${SIGNALLED:-0}" = 1 ]; then kill -TERM "$$"; fi
exit "${CLIENT_STATUS:-0}"
]])
        stub("loginctl", [[
case "$1" in
  show-user) test "$3 $4 $5" = '-p Display --value'; printf '11\n' ;;
  lock-session) test "$2" = 11; printf '%s\n' "$*" > "$HOME/lock-request" ;;
  *) exit 2 ;;
esac
]])
        stub("systemctl", [[
case "$*" in
  '--user is-active --quiet kaze-hypridle.service') [ "${HYPRIDLE_DEAD:-0}" = 0 ] ;;
  '--user start kaze-lock.service') printf '%s\n' "$*" > "$HOME/direct-lock" ;;
  *) exit 2 ;;
esac
]])
        stub("slurp", "exit 1")
        local function copied(cli, args, vars)
            return run(cli, args, vars, tools .. "/" .. cli)
        end
        assert(os.execute(copied("kaze-clipboard", "list"))) -- also loads kaze.layouts/init.lua
        assert(os.execute(copied("kaze-screenshot", "region")))
        assert(os.execute(copied("kaze-session", "lock")))
        assert_eq(fs.read_file(tmp .. "/lock-request"), "lock-session 11\n")
        assert_true(not fs.file_exists(tmp .. "/direct-lock"), "active hypridle handles D-Bus lock")
        assert(os.execute(copied("kaze-session", "lock", "HYPRIDLE_DEAD=1")))
        assert_eq(fs.read_file(tmp .. "/direct-lock"), "--user start kaze-lock.service\n", "fallback starts kaze-lock directly")
        local _, why, code = os.execute(copied("kaze-footclient", "-e editor", "CLIENT_STATUS=37"))
        assert_eq(why, "exit")
        assert_eq(code, 37)
        local client_args = assert(fs.read_file(tmp .. "/client-args"))
        assert_true(not client_args:find("\n-N\n", 1, true), "no hidden no-wait flag")
        assert_contains(client_args, "\n-e\neditor\n")
        assert(os.execute(copied("kaze-footclient", "-N -e editor")))
        assert_contains(fs.read_file(tmp .. "/client-args"), "\n-N\n")
        local _, _, signal = os.execute(copied("kaze-footclient", "", "SIGNALLED=1"))
        assert_eq(signal, 143)
        stub("flock", [[kill -TERM "$$"]])
        local _, _, sync_signal = os.execute(run("kaze-sync", ""))
        assert_eq(sync_signal, 143)
        local alias = tools .. "/link"
        assert(os.execute("ln -s -- " .. q(repo .. "/bin/kaze-screenshot") .. " " .. q(alias)))
        assert(os.execute(run("kaze-screenshot", "region", nil, alias)))
    end)
end)

test("switch: layout and theme serialize; appearance and configs roll back together", function()
    with_stubs(function(tmp, stub, run)
        local signature = "fixture-session_0"
        local live = "HYPRLAND_INSTANCE_SIGNATURE=" .. signature
        local pending = tmp .. "/runtime/hypr/" .. signature .. "/kaze-pending-state.lua"
        fs.mkdir_p(fs.dirname(pending))
        stub("foot", "exit 0")
        stub("fuzzel", "exit 0")
        stub("systemctl", [[
case "$*" in
  '--user show-environment') printf 'HYPRLAND_INSTANCE_SIGNATURE=%s\n' "$HYPRLAND_INSTANCE_SIGNATURE" ;;
  '--user show -p MainPID --value kaze-waybar.service') printf '123\n' ;;
  '--user show -p MainPID --value kaze-wallpaper.service') printf '456\n' ;;
  '--user restart kaze-waybar.service fnott.service'*)
    printf '%s\n' "$*" >> "$HOME/restarts"
    if [ -f "$HOME/checkpoint" ] && [ ! -f "$HOME/failed" ]; then
      test -f "$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/kaze-pending-state.lua"
      cmp "$XDG_CONFIG_HOME/kaze/state.lua" "$HOME/checkpoint"
      : > "$HOME/failed"
      exit 1
    fi ;;
  '--user is-active --quiet '*|'--user reset-failed '*) : ;;
  *) exit 2 ;;
esac
]])
        stub("hyprctl", [[
case "$1" in
  reload) sleep 0.1; printf 'ok\n' ;;
  configerrors) : ;;
  layers) printf 'namespace: waybar, pid: 123\nnamespace: wallpaper, pid: 456\n' ;;
  -j) test "$2" = monitors; printf '[{"dpmsStatus":true}]\n' ;;
  setcursor) printf '%s %s\n' "$2" "$3" >> "$HOME/cursors"; printf 'ok\n' ;;
  *) exit 2 ;;
esac
]])
        local env_file = tmp .. "/runtime/kaze/session.env"
        assert(os.execute(run("kaze-sync", "--session-start", "LC_ALL=C LC_CTYPE= LANG=vi_VN.UTF-8")))
        assert_contains(fs.read_file(env_file), 'LC_ALL=""\nLC_CTYPE="C.UTF-8"\n', "LC_ALL=C must not override fallback")
        assert(os.execute(run("kaze-sync", "--session-start", "LC_ALL= LC_CTYPE=vi_VN.UTF-8 LANG=en_US.UTF-8")))
        assert_contains(fs.read_file(env_file), 'LANG="en_US.UTF-8"\nLC_ALL=""\nLC_CTYPE="vi_VN.UTF-8"\n')
        local layout = run("kaze-layout", "--quiet islands", live)
        local theme = run("kaze-theme", "--quiet lavender", live)
        assert(os.execute("(" .. layout .. ") & a=$!; (" .. theme .. ") & b=$!; wait \"$a\" && wait \"$b\""))
        local state_file = tmp .. "/cfg/kaze/state.lua"
        local committed = state.load(state_file)
        assert_eq(committed.layout, "islands", "parallel layout setting")
        assert_eq(committed.theme, "lavender", "parallel theme setting")
        assert_true(not fs.file_exists(pending), "no candidate after success")
        local colors = tmp .. "/cfg/waybar/colors.css"
        local before = assert(fs.read_file(colors))
        local before_env = assert(fs.read_file(env_file))
        assert_contains(before_env, 'KAZE_WALLPAPER_COLOR="#' .. themes.get("lavender").bg .. '"')
        assert_contains(before_env, 'LC_CTYPE="vi_VN.UTF-8"', "live reload preserves the login locale")
        assert_contains(fs.read_file(tmp .. "/restarts"), "restart kaze-waybar.service fnott.service kaze-wallpaper.service\n")
        assert_contains(fs.read_file(tmp .. "/restarts"), "restart kaze-waybar.service fnott.service\n")
        fs.write_atomic(tmp .. "/checkpoint", assert(fs.read_file(state_file)))
        local wallpaper = tmp .. '/A "quoted" \\wallpaper.png'
        fs.write_atomic(wallpaper, "fixture")
        fs.write_atomic(tmp .. "/cfg/kaze/user.lua", ('return { wallpaper=%q, cursor_theme="fixture", cursor_size=48 }\n'):format(wallpaper))
        assert_true(not os.execute(run("kaze-theme", "--quiet carbon", live) .. " 2>/dev/null"))
        assert_true(fs.file_exists(tmp .. "/failed"), "stub injected an error before commit")
        assert_eq(fs.read_file(state_file), fs.read_file(tmp .. "/checkpoint"), "committed state unchanged")
        assert_eq(fs.read_file(colors), before, "output restored")
        assert_eq(fs.read_file(env_file), before_env, "environment restored")
        assert_eq(fs.read_file(tmp .. "/cursors"), "fixture 48\nAdwaita 24\n", "cursor restored")
        assert_true(not fs.file_exists(pending), "no candidate after rollback")
        assert(os.execute(run("kaze-sync", "--reload", live)))
        local appearance = require("kaze.session").read_appearance(assert(fs.read_file(env_file)))
        assert_eq(appearance.wallpaper, wallpaper, "quoted wallpaper path round-trips")
        assert_eq(appearance.cursor_size, "48")
        os.remove(tmp .. "/restarts")
        assert(os.execute(run("kaze-theme", "--quiet carbon", live)))
        assert_eq(fs.read_file(tmp .. "/restarts"), "--user restart kaze-waybar.service fnott.service\n", "same image is not restarted on theme switch")
    end)
end)

test("switch: absent or powered-off displays don't require mapped layers, but still require running daemons", function()
    with_stubs(function(tmp, stub, run)
        local signature = "dark-session_0"
        local live = "HYPRLAND_INSTANCE_SIGNATURE=" .. signature
        fs.mkdir_p(tmp .. "/runtime/hypr/" .. signature)
        stub("foot", "exit 0")
        stub("fuzzel", "exit 0")
        stub("systemctl", [[
case "$*" in
  '--user show-environment') printf 'HYPRLAND_INSTANCE_SIGNATURE=%s\n' "$HYPRLAND_INSTANCE_SIGNATURE" ;;
  '--user show -p MainPID --value kaze-waybar.service') printf '123\n' ;;
  '--user is-active --quiet kaze-waybar.service')
    if [ "${FAILED_BAR:-0}" = 1 ] && [ ! -f "$HOME/failed-bar" ]; then
      : > "$HOME/failed-bar"; exit 1
    fi ;;
  '--user is-active --quiet '*|'--user reset-failed '*|'--user restart '*) : ;;
  *) exit 2 ;;
esac
]])
        stub("hyprctl", [[
case "$1" in
  reload) printf 'ok\n' ;;
  configerrors) : ;;
  -j) printf '%s\n' "$MONITOR_JSON" ;;
  layers) : > "$HOME/layers-queried"; exit 1 ;;
  *) exit 2 ;;
esac
]])
        assert(os.execute(run("kaze-sync", "--session-start")))
        local function switch(layout, json, extra)
            return os.execute(run("kaze-layout", "--quiet " .. layout,
                live .. " MONITOR_JSON=" .. fs.shell_quote(json) .. " " .. (extra or "")) .. " 2>/dev/null")
        end
        assert(switch("islands", '[]'))
        assert(switch("slim", '[{"dpmsStatus":false}]'))
        assert_true(not fs.file_exists(tmp .. "/layers-queried"))
        assert_true(not switch("sidebar", '[{"dpmsStatus":false}]', "FAILED_BAR=1"))
        assert_true(not switch("sidebar", '[{"dpmsStatus":true}]'))
        assert_true(fs.file_exists(tmp .. "/layers-queried"), "a powered output still requires a mapped layer")
        assert_eq(state.load(tmp .. "/cfg/kaze/state.lua").layout, "slim")
    end)
end)

test("clipboard: ignores sensitive, clear and oversized events; Escape and decode failures don't copy", function()
    with_stubs(function(tmp, stub, run)
        stub("cliphist", [[
[ "$1" = -config-path ] && [ "$2" = /dev/null ] && [ "$3" = -db-path ]
[ "$4" = "$XDG_RUNTIME_DIR/kaze/cliphist.db" ] && [ "$5" = -max-items ] && [ "$6" = 100 ]
case "$7" in
  store) cat > "$4" ;;
  list) printf '1\tfixture\n' ;;
  decode) [ "${DECODE_FAIL:-0}" = 0 ] && cat "$4" ;;
  wipe) : > "$4" ;;
  *) exit 2 ;;
esac
]])
        stub("pgrep", "exit 1")
        stub("fuzzel", [[
cat >/dev/null
[ "${CANCEL:-0}" = 0 ] && printf '1\tfixture\n'
]])
        stub("wl-copy", [[printf '%s' "$*" > "$HOME/mime"; cat > "$HOME/copied"]])
        local db = tmp .. "/runtime/kaze/cliphist.db"
        for _, ignored in ipairs({ "", "CLIPBOARD_STATE=sensitive", "CLIPBOARD_STATE=nil", "CLIPBOARD_STATE=clear" }) do
            assert(os.execute("printf secret | " .. run("kaze-clipboard", "store", ignored)))
        end
        assert_true(not fs.file_exists(db), "non-data states must not create a history DB")
        assert(os.execute("printf test | " .. run("kaze-clipboard", "store", "CLIPBOARD_STATE=data")))
        assert_eq(fs.read_file(db), "test", "bounded payload stored")
        assert_eq(fs.capture("stat -c %a " .. fs.shell_quote(db)), "600\n", "private DB")
        assert_eq(fs.capture("stat -c %a " .. fs.shell_quote(fs.dirname(db))), "700\n", "private runtime directory")
        assert(os.execute("(head -c 20971520 /dev/zero && touch " .. fs.shell_quote(tmp .. "/drained") .. ") | "
            .. run("kaze-clipboard", "store", "CLIPBOARD_STATE=data")))
        assert_true(not fs.file_exists(tmp .. "/drained"), "the oversized stream must be closed early")
        assert_eq(fs.read_file(db), "test", "oversized clipboard left DB untouched")
        assert(os.execute(run("kaze-clipboard", "pick", "CANCEL=1")))
        assert_true(not os.execute(run("kaze-clipboard", "pick", "DECODE_FAIL=1") .. " 2>/dev/null"), "failed decode exits nonzero")
        assert_true(not fs.file_exists(tmp .. "/copied"), "wl-copy not opened on cancel or decode failure")
        assert(os.execute(run("kaze-clipboard", "pick")))
        assert_eq(fs.read_file(tmp .. "/copied"), "test", "successful pick writes clipboard")
        assert_eq(fs.read_file(tmp .. "/mime"), "", "non-PNG keeps MIME inference")
        local png = "\137PNG\r\n\26\n\0fixture"
        fs.write_atomic(db, png)
        assert(os.execute(run("kaze-clipboard", "pick")))
        assert_eq(fs.read_file(tmp .. "/copied"), png, "PNG pick preserves binary data")
        assert_eq(fs.read_file(tmp .. "/mime"), "--type image/png")
        assert(os.execute(run("kaze-clipboard", "wipe")))
        assert_eq(fs.read_file(db), "", "wipe uses the same DB")
    end)
end)

test("screenshots: cancel or grim failure never replaces clipboard or announces success", function()
    with_stubs(function(tmp, stub, run)
        stub("slurp", [=[
[ "${CANCEL:-0}" = 0 ] && printf '5,7 100x80\n'
]=])
        stub("grim", [[
test "$1" = -t && test "$2" = png
if [ "$3" = -g ]; then test "$4" = '5,7 100x80'; fi
for dest do :; done
printf image > "$dest"
[ "${FAIL_GRIM:-0}" = 0 ]
]])
        stub("wl-copy", [[
test "$1" = --type
printf '%s' "$2" > "$HOME/mime"
cat > "$HOME/copied"
]])
        stub("swappy", [[
test "$1" = -f && test -s "$2"
printf '%s' "$2" > "$HOME/annotated"
]])
        stub("hyprpicker", [[
printf '%s' "${HEX:-}"
exit "${PICK_STATUS:-0}"
]])
        stub("notify-send", [[printf '%s\n' "$@" > "$HOME/toast"]])
        stub("xdg-user-dir", [[printf '%s\n' "$HOME"]])
        assert(os.execute(run("kaze-screenshot", "region", "CANCEL=1")))
        assert(os.execute(run("kaze-screenshot", "region --save", "CANCEL=1")))
        assert(os.execute(run("kaze-screenshot", "region --annotate", "CANCEL=1")))
        assert_true(not fs.file_exists(tmp .. "/annotated"), "cancel does not open swappy")
        assert_true(not fs.file_exists(tmp .. "/runtime/kaze"), "cancel must not even prepare capture storage")
        assert_true(not os.execute(run("kaze-screenshot", "region", "FAIL_GRIM=1") .. " 2>/dev/null"), "grim failure exits nonzero")
        assert_true(not fs.file_exists(tmp .. "/copied") and not fs.file_exists(tmp .. "/toast"))
        assert(os.execute(run("kaze-screenshot", "region")))
        assert_eq(fs.read_file(tmp .. "/copied"), "image", "successful region copy")
        assert_contains(fs.read_file(tmp .. "/toast"), "Region copied")
        os.remove(tmp .. "/copied")
        local saved = assert(fs.capture(run("kaze-screenshot", "screen --save"))):gsub("\n$", "")
        assert_contains(saved, tmp .. "/Pictures/Screenshots/")
        assert_eq(fs.read_file(saved), "image", "saved image")
        assert_true(not fs.file_exists(tmp .. "/copied"), "save-only mode leaves clipboard intact")
        os.remove(tmp .. "/toast")
        assert(os.execute(run("kaze-screenshot", "region --annotate")))
        local annotated = assert(fs.read_file(tmp .. "/annotated"))
        assert_true(not fs.file_exists(annotated), "swappy temporary file is removed")
        assert_true(not fs.file_exists(tmp .. "/copied") and not fs.file_exists(tmp .. "/toast"))
        for _, vars in ipairs({ "", "HEX=abc", "HEX='#AA8877' PICK_STATUS=1" }) do
            assert(os.execute(run("kaze-screenshot", "color", vars)))
            assert_true(not fs.file_exists(tmp .. "/copied") and not fs.file_exists(tmp .. "/toast"))
        end
        assert(os.execute(run("kaze-screenshot", "color", "HEX='#Aa8877'")))
        assert_eq(fs.read_file(tmp .. "/mime"), "text/plain")
        assert_eq(fs.read_file(tmp .. "/copied"), "#Aa8877")
        assert_contains(fs.read_file(tmp .. "/toast"), "#Aa8877")
    end)
end)

test("night temperature validates, and monitor selection ignores quoted/nested lookalikes", function()
    local focus = require("kaze.capture").focused_output
    assert_eq(focus([[ [{"name":"DP-1","focused":false,"description":"name"},
        {"name":"eDP-1","nested":[{"name":"Fake-1","focused":false}], "description":"} \" {", "focused":true}] ]]), "eDP-1")
    assert_eq(focus([[ [{"name":"DP-1","focused":true},{"name":"eDP-1","focused":true}] ]]), nil)
    assert_eq(focus([[ [{"name":"DP-1","focused":false}] ]]), nil)
    assert_eq(focus("invalid query"), nil)
    with_stubs(function(tmp)
        local user = tmp .. "/user.lua"
        fs.write_atomic(user, "return { night_temp = 3900 }")
        local cfg, theme = config.load({ home = tmp, user_path = user })
        assert_eq(cfg.night_temp, 3900)
        assert_contains(require("kaze.session").render_environment(cfg, theme), 'KAZE_NIGHT_TEMP="3900"')
        fs.write_atomic(user, "return { night_temp = 4500.5 }")
        assert_true(not pcall(config.load, { home = tmp, user_path = user }), "must reject fractional Kelvin")
        assert_eq(config.load({ home = tmp, user_path = user, strict = false }).night_temp, 4500)
    end)
end)

test("recording: lock excludes double taps, wait for exact completion receipt, and stop before target", function()
    with_stubs(function(tmp, stub, run)
        local dir = tmp .. "/runtime/kaze"
        local dest = tmp .. "/Video Space/Recordings/"
        stub("xdg-user-dir", [[test "$1" = VIDEOS; printf '%s/Video Space\n' "$HOME"]])
        for _, name in ipairs({ "wf-recorder", "ffprobe" }) do stub(name, "exit 0") end
        stub("slurp", [[test "$1" = -f; exit 1]])
        stub("hyprctl", [[test "$*" = '-j monitors'; printf '[{"name":"DP-2","focused":true}]\n']])
        stub("notify-send", [[printf '%s\n' "$@" > "$HOME/toast"]])
        stub("dbus-update-activation-environment", "exit 0")
        stub("systemctl", [[
record="$XDG_RUNTIME_DIR/kaze/record.env"
state="$HOME/recording"
case "$*" in
  '--user show -p ActiveState kaze-record.service')
    if [ -f "$state" ]; then echo ActiveState=active; else echo ActiveState=inactive; fi ;;
  '--user show -p ActiveState --value kaze-record.service')
    if [ -f "$state" ]; then echo active; else echo inactive; fi ;;
  '--user start kaze-record.service')
    grep -Fx 'KAZE_RECORD_OUTPUT="DP-2"' "$record" >&2
    grep -Fx 'KAZE_RECORD_REGION=""' "$record" >&2
    touch "$state" ;;
  '--user stop kaze-record.service')
    printf 'recorder\n' >> "$HOME/stop-order"
    [ -f "$state" ]
    if [ "${FAIL_RECORD:-0}" = 0 ]; then
        awk -F'"' '/^KAZE_RECORD_FILE=/{print $2}' "$record" > "$XDG_RUNTIME_DIR/kaze/record.done"
    fi
    rm "$state" "$record" ;;
  '--user show-environment') echo HYPRLAND_INSTANCE_SIGNATURE=test-hyprland ;;
  '--user is-active --quiet kaze-session.target') exit 0 ;;
  '--user stop kaze-session.target')
    test ! -e "$state"
    printf 'target\n' >> "$HOME/stop-order" ;;
  '--user unset-environment '*) exit 0 ;;
  *) exit 2 ;;
esac
]])
        local function rec(args, vars)
            return run("kaze-record", args, "HYPRLAND_INSTANCE_SIGNATURE=test-hyprland " .. (vars or ""))
        end
        assert(os.execute(rec("--region")))
        assert_true(not fs.file_exists(dest), "Esc must not reserve an MP4")
        local locked = "flock --close " .. fs.shell_quote(dir .. "/record.lock") .. " sh -c " .. fs.shell_quote(rec("toggle"))
        assert(os.execute(locked))
        assert_true(not fs.file_exists(dir .. "/record.env"), "second toggle skipped under held lock")
        assert_eq(fs.capture(rec("status")), "off\n")
        assert(os.execute(rec("toggle")))
        assert_eq(fs.capture(rec("status")), "on\n")
        local output = assert(fs.capture(rec("stop")))
        assert_contains(output, dest)
        assert_contains(fs.read_file(tmp .. "/toast"), "Recording saved")
        os.remove(tmp .. "/toast")
        assert(os.execute(rec("toggle")))
        assert_true(not os.execute(rec("stop", "FAIL_RECORD=1") .. " 2>/dev/null"), "no receipt = no success")
        assert_true(not fs.file_exists(tmp .. "/toast"), "no saved toast on failure")
        assert(os.execute(rec("toggle")))
        os.remove(tmp .. "/stop-order")
        for _, fname in ipairs({ "notifications.json", "dnd.state", "perf.state", "dismiss-guard", "active-fuzzel" }) do
            fs.write_atomic(dir .. "/" .. fname, "ephemeral\n")
        end
        assert(os.execute(run("kaze-session", "stop", "HYPRLAND_INSTANCE_SIGNATURE=test-hyprland")))
        assert_eq(fs.read_file(tmp .. "/stop-order"), "recorder\ntarget\n")
        for _, fname in ipairs({ "notifications.json", "dnd.state", "perf.state", "dismiss-guard", "active-fuzzel" }) do
            assert_true(not fs.file_exists(dir .. "/" .. fname), "session stop removes ephemeral " .. fname)
        end
    end)
end)

test("power: Screen Off dispatches DPMS only and the old Suspend entry is gone", function()
    with_stubs(function(tmp, stub, run)
        stub("pgrep", "exit 1")
        stub("fuzzel", [[
cat > "$HOME/power-items"
printf '%s\n' "$POWER_CHOICE"
]])
        stub("hyprctl", [[printf '%s\n' "$@" >> "$HOME/dispatches"; printf 'ok\n']])
        stub("systemctl", [[
if [ "$*" = '--user is-active --quiet kaze-hypridle.service' ]; then exit 0; fi
printf '%s\n' "$@" >> "$HOME/systemctl-calls"
exit 1
]])
        stub("loginctl", [[
case "$1" in
  show-user) printf '11\n' ;;
  lock-session) printf '%s\n' "$*" >> "$HOME/logind-calls" ;;
  *) exit 2 ;;
esac
]])
        local function pick(label)
            return os.execute(run("kaze-power", "", "POWER_CHOICE=" .. fs.shell_quote(label)) .. " 2>/dev/null")
        end

        assert(pick("󰍹  Screen Off"))
        local menu = assert(fs.read_file(tmp .. "/power-items"))
        assert_contains(menu, "󰍹  Screen Off")
        assert_true(not menu:find("Suspend", 1, true), "Suspend must not be offered")
        local request = assert(fs.read_file(tmp .. "/dispatches"))
        local lua_code = assert(request:match("^eval\n(.*)\n$"))
        local function emulate(held)
            local seen = { off = 0, timers = {} }
            assert(load(lua_code, "=screen-off", "t", { ipairs = ipairs, hl = {
                dsp = { dpms = function(opts) return opts.action end },
                dispatch = function(action)
                    assert_eq(action, "off", "Screen Off only dispatches DPMS off")
                    seen.off = seen.off + 1
                end,
                is_key_down = function(key) return held[key] end,
                on = function(event, cb)
                    assert_eq(event, "input.keyboard.key")
                    seen.active, seen.input = true, cb
                    return {
                        is_active = function() return seen.active end,
                        remove = function() seen.active = false end,
                    }
                end,
                timer = function(cb, opts)
                    assert_eq(opts.type, "oneshot")
                    seen.timers[opts.timeout] = cb
                end,
            } }))()
            return seen
        end
        assert_eq(emulate({}).off, 1, "turn off directly if no key is held")
        local held = { Return = true, Shift_L = true }
        local waiting = emulate(held)
        assert_eq(waiting.off, 0, "wait for the accept keys to be released")
        waiting.input(36, 0, 0)
        held.Return = false
        waiting.timers[1]()
        assert_eq(waiting.off, 0, "wait for the held modifier too")
        waiting.input(50, 0, 0)
        held.Shift_L = false
        waiting.timers[1]()
        assert_eq(waiting.off, 1, "turn off after Hyprland has handled the release")
        assert_eq(waiting.active, false, "release subscription removed")
        local expired = emulate({ Return = true })
        expired.timers[10000]()
        assert_eq(expired.active, false, "release subscription has a deadline")
        assert_eq(expired.off, 0, "timeout does not blank the displays")
        os.remove(tmp .. "/dispatches")

        assert(pick(""))
        assert_true(not pick("󰤄  Suspend"), "old Suspend selection must be rejected")
        assert_true(not fs.file_exists(tmp .. "/dispatches"), "cancel or stale selection must not dispatch")
        assert_true(not fs.file_exists(tmp .. "/systemctl-calls"), "Screen Off must not request lock or sleep")
        assert_true(not fs.file_exists(tmp .. "/logind-calls"), "Screen Off does not call logind")
        assert(pick("󰌾  Lock"))
        assert_eq(fs.read_file(tmp .. "/logind-calls"), "lock-session 11\n")
    end)
end)

test("brightness OSD: uses ceil(2% of device max) and ignores missing backlight", function()
    with_stubs(function(tmp, stub, run)
        stub("brightnessctl", [[
[ "$1" = -c ] && [ "$2" = backlight ]
if [ "$3" = -m ]; then
  [ "${NO_BACKLIGHT:-0}" = 0 ] && printf 'panel,backlight,40,20%%,%s\n' "$MAX_BRIGHTNESS"
else
  [ "$3" = -d ] && [ "$4" = panel ] && [ "$5" = -n ] && [ "$7" = -m ] && [ "$8" = set ] && [ "$9" = 5%- ]
  printf '%s' "$6" > "$HOME/floor"
  printf 'panel,backlight,%s,2%%,%s\n' "$6" "$MAX_BRIGHTNESS"
fi
]])
        stub("notify-send", [[printf '%s\n' "$@" > "$HOME/toast"]])
        assert(os.execute(run("kaze-osd", "bright-down", "NO_BACKLIGHT=1")))
        assert_true(not fs.file_exists(tmp .. "/floor") and not fs.file_exists(tmp .. "/toast"))
        for max, floor in pairs({ [1] = "1", [255] = "6", [120000] = "2400" }) do
            assert(os.execute(run("kaze-osd", "bright-down", "MAX_BRIGHTNESS=" .. max)))
            assert_eq(fs.read_file(tmp .. "/floor"), floor, "brightness floor at " .. max)
            assert_contains(fs.read_file(tmp .. "/toast"), "int:value:2")
        end
    end)
end)

do
    local json = require("kaze.json")
    test("kaze.json: strict decode of objects, arrays, escapes, surrogate pairs, and invalid inputs", function()
        local parsed = json.decode('{"hello": "world", "num": 123.45, "esc": "\\b\\f\\n\\t", "arr": [true, false, null], "surrogate": "\\uD83D\\uDE00"}')
        assert_eq(parsed.hello, "world")
        assert_eq(parsed.num, 123.45)
        assert_eq(parsed.esc, "\b\f\n\t")
        assert_eq(parsed.arr[1], true)
        assert_eq(parsed.arr[2], false)
        assert_eq(parsed.arr[3], nil)
        assert_eq(parsed.surrogate, "😀")

        assert_true(not pcall(json.decode, '{"a": 1} trailing'), "must reject trailing garbage")
        assert_true(not pcall(json.decode, '{"unterminated'), "must reject unterminated string")
        assert_true(not pcall(json.decode, '{"bad": \\x}'), "must reject invalid token")
        assert_true(not pcall(json.decode, '"\\u12G4"'), "must reject invalid hex escape")
    end)

    local display = require("kaze.display")
    test("display.plan: preserves HiDPI scale and formats whole scale as integer", function()
        local monitors = {
            { name = "eDP-1", width = 2880, height = 1800, refresh = 60, scale = 2.0, focused = true },
            { name = "HDMI-A-1", width = 1920, height = 1080, refresh = 60, scale = 1.0, focused = false },
            { name = "DP-1", width = 3840, height = 2160, refresh = 60, scale = 1.5, focused = false },
        }
        local p_auto = display.plan("auto", monitors)
        assert_eq(p_auto.rules[1], "eDP-1,preferred,auto,2")
        assert_eq(p_auto.rules[2], "HDMI-A-1,preferred,auto,1")
        assert_eq(p_auto.rules[3], "DP-1,preferred,auto,1.5")

        local p_ext = display.plan("extend-right", monitors)
        assert_eq(p_ext.rules[1], "eDP-1,preferred,0x0,2")
        assert_eq(p_ext.rules[2], "HDMI-A-1,preferred,auto-right,1")
    end)

    test("optimizations: fuzzel icon-theme & -N, foot bell/mouse/csd, hyprlock, rules, kaze-tui locked-title, clipboard MIME", function()
        local theme = themes.get("kaze")
        local layout = layouts.get("sidebar")
        local cfg_def = config.load({ home = "/tmp/nonexistent-kaze-home", strict = false })
        local fz = emit_fuzzel.emit(cfg_def, theme, layout)
        assert_contains(fz, "terminal=kaze-footclient -N\n", "fuzzel default terminal uses -N")
        assert_contains(fz, "icon-theme=hicolor\n", "fuzzel uses icon_theme instead of cursor_theme")
        assert_contains(fz, "[dmenu]\nexit-immediately-if-empty=yes\n", "fuzzel dmenu empty guard")

        local ft = emit_foot.emit(cfg_def, theme, layout)
        assert_contains(ft, "[bell]\nurgent=yes\n", "foot urgent bell")
        assert_contains(ft, "[mouse]\nhide-when-typing=yes\n", "foot hide mouse")
        assert_contains(ft, "[csd]\npreferred=none\n", "foot csd none")

        local lk = emit_hyprlock.emit(cfg_def, theme, layout)
        assert_contains(lk, "immediate_render = true", "hyprlock immediate_render")
        assert_contains(lk, "capslock_color = rgb(" .. theme.warn .. ")", "hyprlock capslock_color")

        -- Verify hypr/rules.lua registers suppress-maximize, xwayland-drags, dialog floats, and selection no_anim
        local win_rules, layer_rules = {}, {}
        local prev_hl = rawget(_G, "hl")
        rawset(_G, "hl", {
            window_rule = function(r) win_rules[#win_rules + 1] = r end,
            layer_rule = function(r) layer_rules[#layer_rules + 1] = r end,
        })
        local ok_rules, rules_err = pcall(dofile, repo_dir .. "/hypr/rules.lua")
        rawset(_G, "hl", prev_hl)
        assert_true(ok_rules, tostring(rules_err))
        assert_true(#win_rules >= 7, "expected >= 7 window rules")
        local saw_selection_no_anim = false
        for _, lr in ipairs(layer_rules) do
            if lr.match and lr.match.namespace == "^(selection|hyprpicker)$" and lr.no_anim == true then
                saw_selection_no_anim = true
            end
        end
        assert_true(saw_selection_no_anim, "selection/hyprpicker layer rule disables animation")

        -- Verify kaze-tui passes -o main.locked-title=yes and matches JSON hyprctl clients
        with_stubs(function(tmp, stub, run)
            stub("btop", "exit 0")
            stub("footclient", [[printf '%s\n' "$@" > "$HOME/tui-foot-args"]])
            stub("hyprctl", [[
if [ "$1" = "-j" ] && [ "$2" = "activewindow" ]; then
    printf '{"address":"0xdeadbeef","class":"kaze-tui","title":"System Monitor"}\n'
    exit 0
elif [ "$1" = "-j" ] && [ "$2" = "clients" ]; then
    if [ "${TUI_OPEN:-0}" = "1" ]; then
        printf '[{"address":"0xdeadbeef","class":"kaze-tui","title":"System Monitor"}]\n'
    else
        printf '[]\n'
    fi
    exit 0
elif [ "$1" = "dispatch" ]; then
    printf '%s\n' "$2" > "$HOME/tui-dispatch"
    exit 0
fi
exit 1
]])
            assert(os.execute(run("kaze-tui", "sysmon", "HYPRLAND_INSTANCE_SIGNATURE=live TUI_OPEN=0")))
            local fargs = assert(fs.read_file(tmp .. "/tui-foot-args"))
            assert_contains(fargs, "-o\nmain.locked-title=yes\n-a\nkaze-tui\n-T\nSystem Monitor\nbtop\n")

            assert(os.execute(run("kaze-tui", "sysmon", "HYPRLAND_INSTANCE_SIGNATURE=live TUI_OPEN=1")))
            assert_contains(assert(fs.read_file(tmp .. "/tui-dispatch")), "window.close")

            -- Verify kaze-clipboard JPEG & WebP MIME inference
            stub("pgrep", "exit 1")
            stub("cliphist", [[
case "$7" in
  list) printf '1\timg\n' ;;
  decode) cat "$4" ;;
  *) exit 0 ;;
esac
]])
            stub("fuzzel", [[cat >/dev/null; printf '1\timg\n']])
            stub("wl-copy", [[printf '%s' "$*" > "$HOME/clip-mime"; cat >/dev/null]])
            local db = tmp .. "/runtime/kaze/cliphist.db"
            fs.write_atomic(db, "\255\216\255\224jpegdata")
            assert(os.execute(run("kaze-clipboard", "pick")))
            assert_eq(fs.read_file(tmp .. "/clip-mime"), "--type image/jpeg")
            fs.write_atomic(db, "RIFF\16\0\0\0WEBPdata")
            assert(os.execute(run("kaze-clipboard", "pick")))
            assert_eq(fs.read_file(tmp .. "/clip-mime"), "--type image/webp")
        end)
    end)

    test("rules: smart_gaps C++ rules, state borders, and layout-directional notification slide", function()
        local prev_hl = rawget(_G, "hl")
        local prev_ctx = package.loaded["kaze._ctx"]
        local function eval_rules(custom_cfg, layout_name)
            local seen = { win = {}, ws = {}, layer = {} }
            package.loaded["kaze._ctx"] = {
                cfg = custom_cfg,
                theme = themes.get("kaze"),
                layout = layouts.get(layout_name),
            }
            rawset(_G, "hl", {
                window_rule = function(r) seen.win[#seen.win + 1] = r end,
                workspace_rule = function(r) seen.ws[#seen.ws + 1] = r end,
                layer_rule = function(r) seen.layer[#seen.layer + 1] = r end,
            })
            dofile(repo_dir .. "/hypr/rules.lua")
            return seen
        end
        local ok, err = pcall(function()
            local off_sidebar = eval_rules({ smart_gaps = false }, "sidebar")
            assert_eq(#off_sidebar.ws, 1, "smart_gaps=false registers s[true] special workspace rule")
            local notif_sb, top_layer, left_layer, right_layer = nil, nil, nil, nil
            local saw_pin, saw_fs, saw_sb_drawer, saw_sb_dash, saw_sb_panel, saw_top_dd = false, false, false, false, false, false
            for _, lr in ipairs(off_sidebar.layer) do
                if lr.match and lr.match.namespace == "^notifications$" then notif_sb = lr.animation end
                if lr.match and lr.match.namespace == "^(launcher|kaze-popup-top)$" then top_layer = lr.animation end
                if lr.match and lr.match.namespace == "^kaze-popup-left$" then left_layer = lr.animation end
                if lr.match and lr.match.namespace == "^kaze-popup-right$" then right_layer = lr.animation end
            end
            for _, wr in ipairs(off_sidebar.win) do
                if wr.name == "state-border-pinned" and wr.match.pin == true then saw_pin = true end
                if wr.name == "state-border-fullscreen" and wr.match.fullscreen == true then saw_fs = true end
                if wr.name == "kaze-right-drawer" and wr.animation == "slide left" then saw_sb_drawer = true end
                if wr.name == "kaze-widget-dash" and wr.animation == "slide left" then saw_sb_dash = true end
                if wr.name == "kaze-widget-panel" and wr.animation == "slide left" then saw_sb_panel = true end
                if wr.name == "kaze-top-dropdown" and wr.animation == "slide top" then saw_top_dd = true end
            end
            assert_eq(notif_sb, "slide right", "sidebar notifications slide right")
            assert_eq(top_layer, "slide top", "top popups slide top")
            assert_eq(left_layer, "slide left", "left sidebar popups slide left")
            assert_eq(right_layer, "slide right", "right popups slide right")
            assert_true(saw_pin and saw_fs, "pinned and fullscreen state borders registered")
            assert_true(saw_sb_drawer and saw_sb_dash and saw_sb_panel and saw_top_dd, "sidebar spatial rules registered")

            local on_islands = eval_rules({ smart_gaps = true }, "islands")
            assert_eq(#on_islands.ws, 3, "smart_gaps=true registers s[true], w[tv1], and f[1] workspace rules")
            local notif_is, saw_is_drawer, saw_is_dash, saw_is_panel = nil, false, false, false
            for _, lr in ipairs(on_islands.layer) do
                if lr.match and lr.match.namespace == "^notifications$" then notif_is = lr.animation end
            end
            for _, wr in ipairs(on_islands.win) do
                if wr.name == "kaze-right-drawer" and wr.animation == "slide right" then saw_is_drawer = true end
                if wr.name == "kaze-widget-dash" and wr.animation == "slide top" then saw_is_dash = true end
                if wr.name == "kaze-widget-panel" and wr.animation == "slide top" then saw_is_panel = true end
            end
            assert_eq(notif_is, "slide top", "islands notifications slide top")
            assert_true(saw_is_drawer and saw_is_dash and saw_is_panel, "islands spatial rules registered")
        end)
        rawset(_G, "hl", prev_hl)
        package.loaded["kaze._ctx"] = prev_ctx
        assert_true(ok, tostring(err))
    end)

    test("workflow CLIs: kaze-perf, kaze-windows, kaze-audio-sink, kaze-wifi, kaze-osd media-info, and kaze-calc", function()
        with_stubs(function(tmp, stub, run)
            -- 1. kaze-calc --eval + sandbox security + Fuzzel copy
            assert_eq(fs.capture(run("kaze-calc", "--eval '2^10 + sqrt(144)'")), "1036\n")
            assert_eq(fs.capture(run("kaze-calc", "--eval '0.1 + 0.2'")), "0.3\n")
            assert_eq(fs.capture(run("kaze-calc", "--eval 'hex(255)'")), "0xff\n")
            for _, unsafe in ipairs({ "while true do end", "function() end", "os.execute(1)", "'a'..'b'", "1/0", "0/0" }) do
                local bad = os.execute(run("kaze-calc", "--eval " .. fs.shell_quote(unsafe)) .. " 2>/dev/null")
                assert_true(bad ~= true and bad ~= 0, "kaze-calc must reject: " .. unsafe)
            end
            stub("pgrep", "exit 1")
            stub("wl-copy", [[cat > "$HOME/calc-copied"]])
            stub("notify-send", [[printf '%s\n' "$@" > "$HOME/toast"]])
            stub("fuzzel", [[
cat > "$HOME/calc-rows"
if [ ! -f "$HOME/calc-step1" ]; then
    : > "$HOME/calc-step1"
    printf '6 * 7\n'
else
    printf '= 42   (Enter to copy)\n'
fi
]])
            assert(os.execute(run("kaze-calc", "")))
            assert_eq(fs.read_file(tmp .. "/calc-copied"), "42")

            -- Pressing Enter on the initial UTF-8 hint row must exit 0 cleanly without error or copy
            os.remove(tmp .. "/calc-copied")
            stub("fuzzel", [[cat > "$HOME/calc-hint-rows"; head -n 1 "$HOME/calc-hint-rows"]])
            assert(os.execute(run("kaze-calc", "")))
            assert_true(not fs.file_exists(tmp .. "/calc-copied"), "hint row Enter must not copy or evaluate")

            -- 2. kaze-perf status / toggle (systemd unit stop/start + fallback pkill)
            assert_eq(fs.capture(run("kaze-perf", "status")), "off\n")
            stub("systemctl", [[
case "$*" in
  '--user show -p LoadState --value kaze-waybar.service') printf 'loaded\n' ;;
  '--user is-active --quiet kaze-waybar.service') [ "${BAR_ACTIVE:-1}" = 1 ] ;;
  '--user stop kaze-waybar.service') printf 'stop\n' >> "$HOME/perf-bar" ;;
  '--user reset-failed kaze-waybar.service') : ;;
  '--user start kaze-waybar.service') printf 'start\n' >> "$HOME/perf-bar" ;;
  *) exit 1 ;;
esac
]])
            stub("hyprctl", [[
case "$1" in
  eval) printf '%s' "$2" > "$HOME/perf-eval"; printf 'ok\n' ;;
  reload) printf 'ok\n' ;;
  layers) printf 'namespace: waybar\n' ;;
  *) exit 1 ;;
esac
]])
            assert(os.execute(run("kaze-perf", "--quiet toggle")))
            assert_eq(fs.capture(run("kaze-perf", "status")), "on\n")
            assert_contains(assert(fs.read_file(tmp .. "/perf-eval")), "animations = { enabled = false }")
            assert_eq(fs.read_file(tmp .. "/perf-bar"), "stop\n")
            assert(os.execute(run("kaze-perf", "--quiet toggle", "BAR_ACTIVE=0")))
            assert_eq(fs.capture(run("kaze-perf", "status")), "off\n")
            assert_eq(fs.read_file(tmp .. "/perf-bar"), "stop\nstart\n")

            -- 3. kaze-windows --list & special workspace focus
            stub("pgrep", "exit 1")
            stub("hyprctl", [[
if [ "$1" = "-j" ] && [ "$2" = "clients" ]; then
    printf '[{"address":"0xbbb","class":"foot","title":"scratch-sh","workspace":{"id":-99,"name":"special:scratch"},"focusHistoryID":1},{"address":"0xaaa","class":"firefox","title":"Docs","workspace":{"id":2,"name":"2"},"focusHistoryID":0}]\n'
elif [ "$1" = "-j" ] && [ "$2" = "monitors" ]; then
    printf '[{"name":"eDP-1","specialWorkspace":{"id":0,"name":""}}]\n'
elif [ "$1" = "dispatch" ]; then
    printf '%s\n' "$2" >> "$HOME/win-dispatches"
fi
]])
            local wlist = assert(fs.capture(run("kaze-windows", "--list")))
            assert_eq(wlist, "1. [2]  firefox  —  Docs\n2. [S:scratch]  foot  —  scratch-sh\n")
            stub("fuzzel", [[cat >/dev/null; printf '2. [S:scratch]  foot  —  scratch-sh\n']])
            assert(os.execute(run("kaze-windows", "")))
            local wdisp = assert(fs.read_file(tmp .. "/win-dispatches"))
            assert_contains(wdisp, 'hl.dsp.workspace.toggle_special("scratch")')
            assert_contains(wdisp, "hl.dsp.focus({ window = 'address:0xbbb' })")

            -- 4. kaze-audio-sink --list & set-default
            stub("wpctl", [[
if [ "$1" = "status" ]; then
cat <<'EOF'
Audio
 ├─ Devices:
 │      40. Built-in Audio [alsa]
 ├─ Sinks:
 │  *   48. Analog Stereo [vol: 0.45]
 │      54. USB DAC [vol: 0.80 MUTED]
 ├─ Sources:
 │  *   49. Mic [vol: 1.00]
EOF
elif [ "$1" = "set-default" ]; then
    printf '%s\n' "$2" > "$HOME/sink-set"
fi
]])
            local slist = assert(fs.capture(run("kaze-audio-sink", "--list")))
            assert_contains(slist, "48. Analog Stereo  [45%] (active)")
            assert_contains(slist, "54. USB DAC  [Muted]")
            stub("fuzzel", [[cat >/dev/null; printf '󰓄  54. USB DAC  [Muted]\n']])
            assert(os.execute(run("kaze-audio-sink", "--quiet")))
            assert_eq(fs.read_file(tmp .. "/sink-set"), "54\n")

            -- 5. kaze-wifi --list & escaped SSID connect
            stub("systemctl", "exit 1")
            stub("nmtui", "exit 0")
            stub("nmcli", [[
if [ "$1" = "-t" ]; then
    printf '*:Home\\:5G:WPA2:88\n :Cafe\\:Free:--:62\n :Home\\:5G:WPA2:50\n'
elif [ "$3" = "device" ] && [ "$4" = "wifi" ] && [ "$5" = "connect" ]; then
    printf '%s\n' "$6" > "$HOME/wifi-conn"
fi
]])
            local net_list = assert(fs.capture(run("kaze-wifi", "--list")))
            assert_contains(net_list, "Home:5G  (88%, WPA2) (connected)")
            assert_contains(net_list, "Cafe:Free  (62%)")
            stub("fuzzel", [[cat >/dev/null; printf '󰤨  Cafe:Free  (62%%)\n']])
            assert(os.execute(run("kaze-wifi", "")))
            assert_eq(fs.read_file(tmp .. "/wifi-conn"), "Cafe:Free\n")

            -- 6. kaze-osd media-info
            stub("playerctl", [[printf 'Playing\tNujabes\tFeather\t60000000\t180000000\n']])
            os.remove(tmp .. "/toast")
            assert(os.execute(run("kaze-osd", "media-info")))
            local mtoast = assert(fs.read_file(tmp .. "/toast"))
            assert_contains(mtoast, "int:value:33")
            assert_contains(mtoast, "󰎈  Feather")
            assert_contains(mtoast, "Nujabes · 1:00 / 3:00")

            -- 7. popups.lua, widget.lua, kaze-dashboard, and kaze-panel
            local popups = require("kaze.popups")
            assert_contains(popups.menu_flags(layouts.get("sidebar")), "--namespace=kaze-popup-left --anchor=top-left")
            assert_contains(popups.status_flags(layouts.get("sidebar")), "--namespace=kaze-popup-left --anchor=bottom-left")
            assert_contains(popups.status_flags(layouts.get("islands")), "--namespace=kaze-popup-top --anchor=top-right --x-margin=10")
            local leap_ts = os.time({ year = 2024, month = 2, day = 29, hour = 14, min = 30 })
            local cal = popups.render_calendar(leap_ts)
            assert_contains(cal, "February 2024")
            assert_contains(cal, " Mo  Tu  We  Th  Fr  Sa  Su ")
            assert_contains(cal, "[29]")

            local dash_print = assert(fs.capture(run("kaze-dashboard", "--print")))
            assert_contains(dash_print, "Mo  Tu  We  Th  Fr  Sa  Su")
            assert_contains(dash_print, "Nujabes — Feather [1:00/3:00]")
            assert_contains(dash_print, "󰻠 CPU ")
            assert_contains(dash_print, "󰍛 RAM ")
            assert_contains(dash_print, "Notifications: ")
            assert_contains(dash_print, "DND: off")

            assert_eq(fs.capture(run("kaze-dnd", "status")), "off\n")
            assert(os.execute(run("kaze-dnd", "--quiet toggle")))
            assert_eq(fs.capture(run("kaze-dnd", "status")), "on\n")
            local dash_print_dnd = assert(fs.capture(run("kaze-dashboard", "--print")))
            assert_contains(dash_print_dnd, "DND: on")
            assert(os.execute(run("kaze-dnd", "--quiet off")))
            assert_eq(fs.capture(run("kaze-dnd", "status")), "off\n")

            stub("footclient", [[printf '%s\n' "$@" > "$HOME/widget-foot-args"]])
            stub("hyprctl", [[
if [ "$1" = "-j" ] && [ "$2" = "clients" ]; then
    if [ "${WIDGET_OPEN:-0}" = "1" ]; then
        printf '[{"address":"0xfeed","class":"kaze-widget-dash","title":"Kaze Dashboard"}]\n'
    else
        printf '[]\n'
    fi
elif [ "$1" = "dispatch" ]; then
    printf '%s\n' "$2" > "$HOME/widget-close"
fi
]])
            assert(os.execute(run("kaze-dashboard", "", "HYPRLAND_INSTANCE_SIGNATURE=live WIDGET_OPEN=0")))
            local wf_args = assert(fs.read_file(tmp .. "/widget-foot-args"))
            assert_contains(wf_args, "-W\n50x21\n-a\nkaze-widget-dash\n")
            assert(os.execute(run("kaze-dashboard", "", "HYPRLAND_INSTANCE_SIGNATURE=live WIDGET_OPEN=1")))
            assert_contains(assert(fs.read_file(tmp .. "/widget-close")), "window.close")
            assert(os.execute(run("kaze-dashboard", "--perf", "HYPRLAND_INSTANCE_SIGNATURE=live WIDGET_OPEN=1")))
            assert_contains(assert(fs.read_file(tmp .. "/widget-foot-args")), "--ui\n--perf\n")
            assert(os.execute(run("kaze-dashboard", "--notifications", "HYPRLAND_INSTANCE_SIGNATURE=live WIDGET_OPEN=1")))
            assert_contains(assert(fs.read_file(tmp .. "/widget-foot-args")), "--ui\n--notifications\n")
            assert(os.execute(run("kaze-dashboard", "--notifs", "HYPRLAND_INSTANCE_SIGNATURE=live WIDGET_OPEN=0")))
            assert_contains(assert(fs.read_file(tmp .. "/widget-foot-args")), "--ui\n--notifications\n")

            stub("wpctl", [[printf 'Volume: 0.65\n']])
            local panel_st = assert(fs.capture(run("kaze-panel", "--status")))
            assert_contains(panel_st, "󰕾 65%")
            assert_contains(panel_st, "Keep awake")
            assert_contains(panel_st, "󰓃  Audio Output  —  65%")
            assert_contains(panel_st, "󰔎 Appearance")
            assert(os.execute(run("kaze-panel", "", "HYPRLAND_INSTANCE_SIGNATURE=live WIDGET_OPEN=0")))
            assert_contains(assert(fs.read_file(tmp .. "/widget-foot-args")), "-W\n45x23\n-a\nkaze-widget-panel\n")
            assert(os.execute(run("kaze-panel", "--wifi", "HYPRLAND_INSTANCE_SIGNATURE=live WIDGET_OPEN=0")))
            assert_contains(assert(fs.read_file(tmp .. "/widget-foot-args")), "--ui\n--wifi\n")
        end)
    end)

    test("kaze.notify: 0-daemon store, 25-item cap, kaze-osd skip, fnottctl merge/dismiss/clear, missing XDG_RUNTIME_DIR", function()
        with_stubs(function(tmp, stub, run)
            local q = fs.shell_quote
            local lua_bin = assert(fs.capture("command -v lua")):gsub("\n$", "")
            assert(os.execute("ln -s -- " .. q(lua_bin) .. " " .. q(tmp .. "/bin/lua")))

            stub("systemctl", [[
case "$*" in
  '--user is-active --quiet fnott.service') [ "${FNOTT_ACTIVE:-0}" = 1 ] ;;
  *) exit 1 ;;
esac
]])
            local fstate = tmp .. "/fnott-live"
            fs.write_atomic(fstate, "77: 󰕾  Volume\n78: 󰃠  Brightness\n42: Alert 30\n99: Firefox Download\n")
            stub("fnottctl", [[
printf '%s\n' "$*" >> "$HOME/fnottctl-calls"
case "$1" in
  list) [ -f "$HOME/fnott-live" ] && /usr/bin/cat "$HOME/fnott-live" ;;
  dismiss)
    if [ "${2:-}" = "all" ]; then
        : > "$HOME/fnott-live"
    elif [ -n "${2:-}" ] && [ -f "$HOME/fnott-live" ]; then
        /usr/bin/grep -v "^$2:" "$HOME/fnott-live" > "$HOME/fnott-live.tmp" || true
        mv "$HOME/fnott-live.tmp" "$HOME/fnott-live"
    fi ;;
esac
]])

            local function eval_notify(vars, code)
                local env = string.format(
                    "env HOME=%s XDG_RUNTIME_DIR=%s PATH=%s:$PATH %s",
                    q(tmp), q(tmp .. "/runtime"), q(tmp .. "/bin"), vars or ""
                )
                local full = string.format(
                    "package.path=%q..package.path; %s",
                    repo_dir .. "/lua/?.lua;" .. repo_dir .. "/lua/?/init.lua;",
                    code
                )
                return assert(fs.capture(env .. " lua -e " .. q(full)))
            end

            -- 1. Recording 30 items caps at 25; kaze-osd is skipped; rel_time formats cleanly
            local out1 = eval_notify("FNOTT_ACTIVE=0", [[
                local notify = require("kaze.notify")
                assert(notify.record({ app = "kaze-osd", summary = "Volume", body = "50%" }) == false)
                for i = 1, 30 do
                    assert(notify.record({ app = "kaze-theme", summary = "Alert " .. i, body = "Body " .. i }))
                end
                local items = notify.list()
                assert(#items == 25, "expected 25 items, got " .. #items)
                assert(items[1].summary == "Alert 30", "newest at index 1")
                assert(items[25].summary == "Alert 6", "oldest retained is Alert 6")
                local now = os.time()
                assert(notify.rel_time(now - 5, "00:00") == "now")
                assert(notify.rel_time(now - 120, "00:00") == "2m ago")
                assert(notify.rel_time(now - 3700, "00:00") == "1h ago")
                assert(notify.rel_time(now - 90000, "09:15") == "09:15")
                io.write("ok1\n")
            ]])
            assert_eq(out1, "ok1\n")
            assert_true(not fs.file_exists(tmp .. "/fnottctl-calls"), "fnottctl must not be called when fnott.service is inactive")

            -- 2. Active fnott.service merges fnott_id onto Alert 30 and prepends 3rd-party popup
            local out2 = eval_notify("FNOTT_ACTIVE=1", [[
                local notify = require("kaze.notify")
                local items = notify.list()
                assert(items[1].id == "fnott:99" and items[1].fnott_id == 99 and items[1].summary == "Firefox Download")
                assert(items[2].summary == "Alert 30" and items[2].fnott_id == 42)
                for _, item in ipairs(items) do
                    assert(item.summary ~= "󰕾  Volume" and item.summary ~= "󰃠  Brightness", "OSD must be filtered out")
                end
                notify.dismiss(items[2].id, items[2].fnott_id)
                local after = notify.list()
                assert(after[2].summary == "Alert 29", "Alert 30 dismissed from store")
                notify.clear_all()
                io.write("ok2\n")
            ]])
            assert_eq(out2, "ok2\n")
            local fcalls = assert(fs.read_file(tmp .. "/fnottctl-calls"))
            assert_contains(fcalls, "list\n")
            assert_contains(fcalls, "dismiss 42\n")
            assert_contains(fcalls, "dismiss all\n")

            -- 3. Empty XDG_RUNTIME_DIR must safely no-op without throwing
            local out3 = eval_notify("XDG_RUNTIME_DIR='' FNOTT_ACTIVE=0", [[
                local notify = require("kaze.notify")
                assert(notify.record({ app = "kaze-theme", summary = "Noop", body = "Safe" }) == false)
                local items = notify.list()
                assert(type(items) == "table" and #items == 0)
                notify.dismiss("1", 1)
                notify.clear_all()
                io.write("ok3\n")
            ]])
            assert_eq(out3, "ok3\n")

            -- 4. CLI integration: kaze-screenshot and kaze-dashboard --print reflect stored notifications
            stub("notify-send", [[exit 0]])
            stub("grim", [[
for dest do :; done
printf image > "$dest"
]])
            stub("wl-copy", [[cat >/dev/null]])
            assert(os.execute(run("kaze-screenshot", "screen")))
            local dp = assert(fs.capture(run("kaze-dashboard", "--print")))
            assert_contains(dp, "Notifications: 1")
            assert_contains(dp, "kaze-screenshot: Screenshot — Full screen copied")

            -- 5. kaze-menu includes Notification Center
            stub("pgrep", "exit 1")
            stub("fuzzel", [[/usr/bin/cat > "$HOME/menu-out"]])
            assert(os.execute(run("kaze-menu", "")))
            assert_contains(assert(fs.read_file(tmp .. "/menu-out")), "󰂚  Notification Center")
        end)
    end)

    test("fuzzel UI polish: popups.run_dmenu NUL icons, SVG swatches, pickers, and widget stadium pills + 1/8 meters", function()
        with_stubs(function(tmp, stub, run)
            local q = fs.shell_quote
            local lua_bin = assert(fs.capture("command -v lua")):gsub("\n$", "")
            assert(os.execute("ln -s -- " .. q(lua_bin) .. " " .. q(tmp .. "/bin/lua")))

            stub("pgrep", "exit 1")
            stub("fuzzel", [[
printf '%s\n' "$@" > "$HOME/dmenu-args"
/usr/bin/cat > "$HOME/dmenu-stdin"
printf '%s\n' "${DMENU_OUT:-}"
]])

            local function eval_popups(vars, code)
                local env = string.format(
                    "env HOME=%s XDG_RUNTIME_DIR=%s XDG_CONFIG_HOME=%s PATH=%s:$PATH %s",
                    q(tmp), q(tmp .. "/runtime"), q(tmp .. "/cfg"), q(tmp .. "/bin"), vars or ""
                )
                local full = string.format(
                    "package.path=%q..package.path; %s",
                    repo_dir .. "/lua/?.lua;" .. repo_dir .. "/lua/?/init.lua;",
                    code
                )
                return assert(fs.capture(env .. " lua -e " .. q(full)))
            end

            -- 1. popups.run_dmenu keeps plain text when WAYLAND_DISPLAY="" and attaches real NUL+0x1f icon bytes on Wayland
            local out_plain = eval_popups("WAYLAND_DISPLAY='' DMENU_OUT='Alpha'", [[
                local popups = require("kaze.popups")
                local pick = popups.run_dmenu({
                    { text = "Alpha", icon = "/tmp/a.png" },
                    { text = "Beta", icon = "firefox" },
                }, {
                    width = 44,
                    lines = 2,
                    minimal_lines = true,
                    hide_prompt = true,
                    line_height = 36,
                    image_size_ratio = 0.72,
                    select_index = 0,
                    prompt = "Pick > ",
                })
                assert(pick == "Alpha", "unexpected pick: " .. tostring(pick))
                io.write("plain_ok\n")
            ]])
            assert_eq(out_plain, "plain_ok\n")
            assert_eq(fs.read_file(tmp .. "/dmenu-stdin"), "Alpha\nBeta\n", "plain dmenu stdin without WAYLAND_DISPLAY")
            local dargs = assert(fs.read_file(tmp .. "/dmenu-args"))
            assert_contains(dargs, "--hide-prompt\n")
            assert_contains(dargs, "--minimal-lines\n")
            assert_contains(dargs, "--line-height=36\n")
            assert_contains(dargs, "--override=main.image-size-ratio=0.72\n")
            assert_contains(dargs, "--select-index=0\n")

            local out_wl = eval_popups("WAYLAND_DISPLAY=wayland-1 DMENU_OUT='Beta'", [[
                local popups = require("kaze.popups")
                local pick = popups.run_dmenu({
                    { text = "Alpha", icon = "/tmp/a.png" },
                    { text = "Beta", icon = "firefox" },
                }, { line_height = 30 })
                assert(pick == "Beta", "unexpected pick: " .. tostring(pick))
                io.write("wl_ok\n")
            ]])
            assert_eq(out_wl, "wl_ok\n")
            assert_eq(
                fs.read_file(tmp .. "/dmenu-stdin"),
                "Alpha\0icon\x1f/tmp/a.png\nBeta\0icon\x1ffirefox\n",
                "Wayland dmenu stdin preserves real NUL and 0x1f icon bytes"
            )
            local leftover = fs.capture("find " .. q(tmp .. "/runtime/kaze") .. " -maxdepth 1 -name 'dmenu-*.in' 2>/dev/null || true")
            assert_eq(leftover, "", "dmenu temp file cleaned up immediately")

            -- 2. popups.ensure_theme_swatch and popups.ensure_layout_swatch write valid SVGs with theme hexes
            local swatch_out = eval_popups("WAYLAND_DISPLAY=''", [[
                local popups = require("kaze.popups")
                local themes = require("kaze.themes")
                local pal = themes.get("tokyonight")
                local sp = assert(popups.ensure_theme_swatch("tokyonight", pal))
                local lp = assert(popups.ensure_layout_swatch("sidebar", pal))
                local lp2 = assert(popups.ensure_layout_swatch("islands", pal))
                local lp3 = assert(popups.ensure_layout_swatch("slim", pal))
                io.write(sp .. "|" .. lp .. "|" .. lp2 .. "|" .. lp3 .. "\n")
            ]]):gsub("\n$", "")
            local t_svg_path, l1_path, l2_path, l3_path = swatch_out:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
            local tn = themes.get("tokyonight")
            local t_svg = assert(fs.read_file(t_svg_path))
            assert_contains(t_svg, "<svg ")
            assert_contains(t_svg, 'rx="0"')
            for _, k in ipairs({ "bg_alt", "border", "accent", "ok", "warn", "danger" }) do
                assert_contains(t_svg, "#" .. tn[k], "theme swatch includes #" .. k)
            end
            for _, lp in ipairs({ l1_path, l2_path, l3_path }) do
                local lsvg = assert(fs.read_file(lp))
                assert_contains(lsvg, "<svg ")
                assert_contains(lsvg, "#" .. tn.accent)
            end

            -- 3. kaze-windows attaches resolved app icons under WAYLAND_DISPLAY=wayland-1, never on --list
            stub("hyprctl", [[
if [ "$1" = "-j" ] && [ "$2" = "clients" ]; then
    printf '[{"address":"0x111","class":"org.pwmt.zathura","title":"Spec.pdf","workspace":{"id":1,"name":"1"},"focusHistoryID":1},{"address":"0x222","class":"kaze-dropdown","title":"Drop","workspace":{"id":1,"name":"1"},"focusHistoryID":2}]\n'
fi
]])
            local win_list = assert(fs.capture(run("kaze-windows", "--list", "WAYLAND_DISPLAY=wayland-1")))
            assert_true(not win_list:find("\0icon\x1f", 1, true), "--list must not emit icon protocol bytes")
            assert(os.execute(run("kaze-windows", "", "WAYLAND_DISPLAY=wayland-1 DMENU_OUT=''")))
            local win_stdin = assert(fs.read_file(tmp .. "/dmenu-stdin"))
            assert_contains(win_stdin, "\0icon\x1forg.pwmt.zathura\n")
            assert_contains(win_stdin, "\0icon\x1ffoot\n")
            local win_args = assert(fs.read_file(tmp .. "/dmenu-args"))
            assert_contains(win_args, "--line-height=30\n")
            assert_contains(win_args, "--override=main.image-size-ratio=0.65\n")

            -- 4. kaze-layout --menu and kaze-theme --menu pass SVG icons + --hide-prompt + --select-index
            assert(os.execute(run("kaze-layout", "--quiet islands", "HYPRLAND_INSTANCE_SIGNATURE='' WAYLAND_DISPLAY=''") .. " >/dev/null 2>&1"))
            assert(os.execute(run("kaze-layout", "--menu", "HYPRLAND_INSTANCE_SIGNATURE='' WAYLAND_DISPLAY=wayland-1 DMENU_OUT=''")))
            local lay_stdin = assert(fs.read_file(tmp .. "/dmenu-stdin"))
            assert_contains(lay_stdin, "islands  —  Islands (Floating Top Pills) (active)\0icon\x1f")
            assert_contains(lay_stdin, "layout-sidebar.svg")
            local lay_args = assert(fs.read_file(tmp .. "/dmenu-args"))
            assert_contains(lay_args, "--hide-prompt\n")
            assert_contains(lay_args, "--select-index=1\n")

            assert(os.execute(run("kaze-theme", "--quiet lavender", "HYPRLAND_INSTANCE_SIGNATURE='' WAYLAND_DISPLAY=''") .. " >/dev/null 2>&1"))
            assert(os.execute(run("kaze-theme", "--menu", "HYPRLAND_INSTANCE_SIGNATURE='' WAYLAND_DISPLAY=wayland-1 DMENU_OUT=''")))
            local thm_stdin = assert(fs.read_file(tmp .. "/dmenu-stdin"))
            assert_contains(thm_stdin, "lavender  —  Lavender (Soft Indigo) (active)\0icon\x1f")
            assert_contains(thm_stdin, "lavender.svg")
            local thm_args = assert(fs.read_file(tmp .. "/dmenu-args"))
            assert_contains(thm_args, "--hide-prompt\n")
            assert_contains(thm_args, "--select-index=1\n")
            assert_contains(thm_args, "--override=main.image-size-ratio=0.72\n")

            -- 5. kaze-audio-sink selects active sink index cleanly with --hide-prompt
            stub("wpctl", [[
if [ "$1" = "status" ]; then
cat <<'EOF'
Audio
 ├─ Sinks:
 │      48. Analog Stereo [vol: 0.45]
 │  *   54. USB DAC [vol: 0.80]
EOF
fi
]])
            assert(os.execute(run("kaze-audio-sink", "--quiet", "WAYLAND_DISPLAY=wayland-1 DMENU_OUT=''")))
            local sink_args = assert(fs.read_file(tmp .. "/dmenu-args"))
            assert_contains(sink_args, "--hide-prompt\n")
            assert_contains(sink_args, "--minimal-lines\n")
            assert_contains(sink_args, "--line-height=32\n")
            assert_contains(sink_args, "--select-index=1\n")

            -- 6. widget.lua cell_bg tracking, stadium pills (bg_alt & surface), switch, and 1/8th meter
            local widget = require("kaze.widget")
            local t = themes.get("kaze")
            local ui = widget.create_canvas(45, 23, t.bg_alt, t.fg)
            ui:begin_frame(t.bg_alt, t.fg)
            assert_eq(ui.cell_bg[1][3], t.bg_alt, "begin_frame sets base cell_bg")
            ui:card(3, 3, 41, 6, t.surface)
            assert_eq(ui.cell_bg[3][2], t.bg_alt, "outside card keeps bg_alt")
            assert_eq(ui.cell_bg[3][4], t.surface, "inside card updates cell_bg to surface")

            local w_pill_out = ui:pill(1, 3, " Back ", t.fg, t.surface, true)
            assert_eq(w_pill_out, 6, "pill width preserved on bg_alt")
            local w_pill_in = ui:pill(4, 4, " Rescan ", t.accent_fg, t.accent, true)
            assert_eq(w_pill_in, 8, "pill width preserved inside card")
            local w_sw_out = ui:switch(1, 35, false, t)
            local w_sw_in_off = ui:switch(3, 38, false, t)
            local w_sw_in_on = ui:switch(5, 38, true, t)
            assert_eq(w_sw_out, 5, "switch width outside card")
            assert_eq(w_sw_in_off, 5, "switch width off inside card")
            assert_eq(w_sw_in_on, 5, "switch width on inside card")
            ui:meter(6, 4, 20, 33, t.accent, t.bg_alt, t.surface)

            local frame = ui:render_string()
            assert_contains(frame, widget.style(t.fg, t.surface, true) .. " Back ", "sharp rectangular chip outside card blends on surface")
            assert_contains(frame, widget.style(t.accent_fg, t.accent, true) .. " Rescan ", "sharp rectangular chip inside card blends on accent")
            assert_contains(frame, widget.style(t.fg, t.bg_alt, true) .. " □   ", "off switch uses high-contrast square □ indicator inside card")
            assert_contains(frame, widget.style(t.accent_fg, t.accent, true) .. " ■ ✓ ", "on switch uses square ■ indicator inside card")
            assert_contains(frame, "█", "meter uses full block glyph")
            assert_true(
                frame:find("▏") or frame:find("▎") or frame:find("▍") or frame:find("▌")
                    or frame:find("▋") or frame:find("▊") or frame:find("▉"),
                "meter uses 1/8th partial block for smooth transition"
            )

            -- Display-width helpers handle wide emoji, VS16, CJK, and multi-byte 1-col chars
            assert_eq(widget.vis_len("a·b"), 3, "middle dot is 1 display column")
            assert_eq(widget.vis_len("🎧"), 2, "emoji occupies 2 display columns")
            assert_eq(widget.vis_len("⚠️"), 2, "VS16 emoji occupies 2 display columns")
            assert_eq(widget.vis_len("日本語"), 6, "CJK occupies 2 display columns per glyph")
            assert_eq(widget.vis_len(widget.trunc("🎧 Hello World", 8)), 8, "trunc respects wide display width")
            assert_eq(widget.vis_len(widget.pad_right("Wi-Fi 🎉", 12)), 12, "pad_right respects wide display width")

            -- Startup FocusOut guard ignores premature CSI O before activation, honors blur after FocusIn or grace
            assert_eq(widget.should_close_on_blur(true, false, 2), false, "ignore startup blur before activation")
            assert_eq(widget.should_close_on_blur(true, true, 2), true, "honor blur once FocusIn was received")
            assert_eq(widget.should_close_on_blur(true, false, 450), true, "honor blur after startup grace window")
            assert_eq(widget.should_close_on_blur(false, true, 1000), false, "respect close_on_blur=false")

            -- Inactive slider uses muted neutral knob rather than red danger highlight
            local ui_inact = widget.create_canvas(30, 5, t.bg_alt, t.fg)
            ui_inact:begin_frame(t.bg_alt, t.fg)
            ui_inact:slider(2, 3, 18, 0, "inactive", t)
            local inact_frame = ui_inact:render_string()
            assert_contains(inact_frame, widget.fg(t.fg_muted), "inactive slider uses muted color")
            assert_true(not inact_frame:find(widget.fg(t.danger), 1, true), "inactive slider must not show danger red")

            -- Hyprlock light theme adds frosted backing shape card; dark theme stays bare
            local emit_hyprlock = require("kaze.emit_hyprlock")
            local hl_cfg = { font = "JetBrainsMono Nerd Font", wallpaper_expanded = "/tmp/wall.png" }
            local hl_layout = layouts.get("sidebar")
            local hl_paper = emit_hyprlock.emit(hl_cfg, themes.get("paper"), hl_layout)
            assert_contains(hl_paper, "shape {", "paper hyprlock emits frosted backing card")
            assert_contains(hl_paper, "brightness = 0.85", "paper hyprlock uses bright wallpaper backdrop")
            assert_contains(hl_paper, "zindex = 0", "paper hyprlock places backing card behind clock")
            assert_contains(hl_paper, "zindex = 1", "paper hyprlock places text above backing card")
            assert_contains(hl_paper, "shadow_passes = 2", "paper hyprlock adds contrast shadow to status line")
            local hl_dark = emit_hyprlock.emit(hl_cfg, themes.get("kaze"), hl_layout)
            assert_true(not hl_dark:find("shape {", 1, true), "dark hyprlock omits light backing card")
            assert_contains(hl_dark, "brightness = 0.65", "dark hyprlock keeps dark wallpaper dimming")
        end)
    end)

    test("kaze-bluetooth, kaze-wall thumbnails, and dismiss guard", function()
        with_stubs(function(tmp, stub, run)
            local q = fs.shell_quote
            local lua_bin = assert(fs.capture("command -v lua")):gsub("\n$", "")
            assert(os.execute("ln -s -- " .. q(lua_bin) .. " " .. q(tmp .. "/bin/lua")))
            for _, util in ipairs({ "stat", "install" }) do
                local util_bin = assert(fs.capture("command -v " .. util)):gsub("\n$", "")
                assert(os.execute("ln -s -- " .. q(util_bin) .. " " .. q(tmp .. "/bin/" .. util)))
            end

            stub("pgrep", "exit 1")
            stub("notify-send", [[printf '%s\n' "$*" >> "$HOME/bt-toast"]])
            stub("bluetoothctl", [[
case "$1" in
  show)
    if [ "${BT_NO_CTRL:-0}" = "1" ]; then
      printf 'No default controller available\n'
      exit 1
    elif [ "${BT_POWERED:-1}" = "1" ]; then
      printf 'Controller AA:BB:CC:DD:EE:FF\n\tPowered: yes\n'
    else
      printf 'Controller AA:BB:CC:DD:EE:FF\n\tPowered: no\n'
    fi
    ;;
  devices)
    if [ "${2:-}" = "Connected" ]; then
      printf 'Device 11:22:33:44:55:66 Sony WH-1000XM5\n'
    elif [ "${2:-}" = "Paired" ]; then
      printf 'Device 11:22:33:44:55:66 Sony WH-1000XM5\nDevice AA:11:BB:22:CC:33 Keychron K2\n'
    else
      printf 'Device 11:22:33:44:55:66 Sony WH-1000XM5\nDevice AA:11:BB:22:CC:33 Keychron K2\n'
    fi
    ;;
  info)
    if [ "$2" = "11:22:33:44:55:66" ]; then
      printf 'Device 11:22:33:44:55:66\n\tPaired: yes\n\tTrusted: yes\n\tConnected: yes\n\tBattery Percentage: 0x55 (85)\n'
    else
      printf 'Device %s\n\tPaired: yes\n\tTrusted: yes\n\tConnected: no\n' "$2"
    fi
    ;;
  power)
    printf 'power:%s\n' "$2" > "$HOME/bt-action"
    ;;
  connect|disconnect|trust|pair)
    printf '%s:%s\n' "$1" "$2" >> "$HOME/bt-action"
    ;;
esac
]])
            assert(os.execute(run("kaze-bluetooth", "--help >/dev/null")))
            local bad_opt = os.execute(run("kaze-bluetooth", "--bogus >/dev/null 2>&1"))
            assert_true(bad_opt ~= true and bad_opt ~= 0, "kaze-bluetooth rejects unknown flag")
            local bad_mac = os.execute(run("kaze-bluetooth", "--connect 'not-a-mac;id' >/dev/null 2>&1"))
            assert_true(bad_mac ~= true and bad_mac ~= 0, "kaze-bluetooth rejects invalid MAC")

            local bt_list = assert(fs.capture(run("kaze-bluetooth", "--list")))
            local idx_sony = assert(bt_list:find("Sony WH%-1000XM5 %(connected, 85%%%)"))
            local idx_keychron = assert(bt_list:find("Keychron K2"))
            assert_true(idx_sony < idx_keychron, "connected device with battery sorts first")

            stub("fuzzel", [[/usr/bin/cat > "$HOME/bt-menu-in"; printf '󰂯  Keychron K2\n']])
            os.remove(tmp .. "/bt-action")
            assert(os.execute(run("kaze-bluetooth", "")))
            assert_contains(assert(fs.read_file(tmp .. "/bt-action")), "connect:AA:11:BB:22:CC:33")

            stub("fuzzel", [[/usr/bin/cat > "$HOME/bt-off-in"; printf '󰂯  Turn Bluetooth On\n']])
            os.remove(tmp .. "/bt-action")
            assert(os.execute(run("kaze-bluetooth", "", "BT_POWERED=0")))
            assert_contains(assert(fs.read_file(tmp .. "/bt-off-in")), "Turn Bluetooth On")
            assert_contains(assert(fs.read_file(tmp .. "/bt-action")), "power:on")

            stub("fuzzel", [[/usr/bin/cat > "$HOME/bt-none-in"; printf '󰂲  No Bluetooth adapter found\n']])
            assert(os.execute(run("kaze-bluetooth", "", "BT_NO_CTRL=1")))
            assert_contains(assert(fs.read_file(tmp .. "/bt-none-in")), "No Bluetooth adapter found")

            -- kaze-menu exposes Quick Bluetooth when bluetoothctl is present
            stub("fuzzel", [[/usr/bin/cat > "$HOME/menu-bt-in"]])
            assert(os.execute(run("kaze-menu", "")))
            assert_contains(assert(fs.read_file(tmp .. "/menu-bt-in")), "Quick Bluetooth")

            -- kaze-wall cached 96x96 PNG thumbnails + minimal SVG fallback
            local wall_dir = tmp .. "/Pictures/Wallpapers"
            fs.mkdir_p(wall_dir)
            local png_bytes = "\137PNG\r\n\26\n\0\0\0\rIHDR\0\0\0\1\0\0\0\1\8\6\0\0\0\31\21\196\137\0\0\0\nIDATx\156c`\0\0\0\2\0\1\226!\188\51\0\0\0\0IEND\174B`\130"
            fs.write_atomic(wall_dir .. "/alpha.png", png_bytes)
            fs.write_atomic(wall_dir .. "/beta.jpg", "\255\216\255\224\0\16JFIF\0\1\1\0\0\1\0\1\0\0\255\217")

            stub("ffmpeg", [[
out=""
for a in "$@"; do out="$a"; done
printf 'ffmpeg:%s\n' "$*" >> "$HOME/ffmpeg-calls"
printf '\211PNG\r\n\032\n' > "$out"
]])
            local wall_vars = "HYPRLAND_INSTANCE_SIGNATURE='' WAYLAND_DISPLAY='' KAZE_WALL_FORCE_THUMBS=1"
            stub("fuzzel", [[/usr/bin/cat > "$HOME/wall-dmenu-in"; printf 'beta.jpg\n']])
            assert(os.execute(run("kaze-wall", "--quiet --menu", wall_vars)))

            local ff1 = assert(fs.read_file(tmp .. "/ffmpeg-calls"))
            assert_contains(ff1, "crop=96:96")
            local wall_in = assert(fs.read_file(tmp .. "/wall-dmenu-in"))
            assert_contains(wall_in, "beta.jpg\0icon\x1f" .. tmp .. "/cache/kaze/wall-thumbs/")
            assert_eq(state.load(tmp .. "/cfg/kaze/state.lua").wallpaper, wall_dir .. "/beta.jpg")

            -- Second call hits existing cache without re-running ffmpeg
            os.remove(tmp .. "/ffmpeg-calls")
            stub("fuzzel", [[cat >/dev/null; printf 'alpha.png\n']])
            assert(os.execute(run("kaze-wall", "--quiet --menu", wall_vars)))
            assert_eq(fs.file_exists(tmp .. "/ffmpeg-calls"), false, "cached thumbnails avoid re-running ffmpeg")
            assert_eq(state.load(tmp .. "/cfg/kaze/state.lua").wallpaper, wall_dir .. "/alpha.png")

            -- On minimal (no ffmpeg/magick), cached thumbs stay cached, uncached PNG stays raw, JPG uses square SVG fallback
            os.remove(tmp .. "/bin/ffmpeg")
            fs.write_atomic(wall_dir .. "/gamma.jpg", "\255\216\255\224\0\16JFIF\0\1\1\0\0\1\0\1\0\0\255\217")
            fs.write_atomic(wall_dir .. "/delta.png", png_bytes)
            stub("fuzzel", [[/usr/bin/cat > "$HOME/wall-min-in"; printf 'gamma.jpg\n']])
            assert(os.execute(run("kaze-wall", "--quiet --menu", wall_vars)))
            local min_in = assert(fs.read_file(tmp .. "/wall-min-in"))
            assert_contains(min_in, "alpha.png\0icon\x1f" .. tmp .. "/cache/kaze/wall-thumbs/")
            assert_contains(min_in, "delta.png\0icon\x1f" .. wall_dir .. "/delta.png")
            assert_contains(min_in, "gamma.jpg\0icon\x1f" .. tmp .. "/runtime/kaze/swatches/wall-fallback.svg")

            -- Dismiss guard skips duplicate toggle on same widget within window, allows others
            stub("footclient", [[printf '%s\n' "$@" > "$HOME/guard-foot"]])
            stub("hyprctl", [[printf '[]\n']])
            os.execute(string.format(
                "env HOME=%s XDG_RUNTIME_DIR=%s lua -e %s",
                q(tmp),
                q(tmp .. "/runtime"),
                q(string.format("package.path=%q; require('kaze.popups').record_dismiss_guard('kaze-widget-dash')", repo_dir .. "/lua/?.lua;" .. package.path))
            ))
            -- Attempting to reopen kaze-dashboard right after Waybar outside-dismiss is a no-op
            assert(os.execute(run("kaze-dashboard", "", "HYPRLAND_INSTANCE_SIGNATURE=live")))
            assert_eq(fs.file_exists(tmp .. "/guard-foot"), false, "dismiss guard blocks same-widget flicker reopen")
            -- Different component opens cleanly even immediately after
            assert(os.execute(run("kaze-panel", "", "HYPRLAND_INSTANCE_SIGNATURE=live")))
            assert_eq(fs.file_exists(tmp .. "/guard-foot"), true, "different component opens normally")

            -- Subtarget dismiss guard: Main panel blocks Main flicker, but allows immediate switch to Wi-Fi sub-view
            os.remove(tmp .. "/guard-foot")
            os.execute(string.format(
                "env HOME=%s XDG_RUNTIME_DIR=%s lua -e %s",
                q(tmp),
                q(tmp .. "/runtime"),
                q(string.format("package.path=%q; require('kaze.popups').record_dismiss_guard('kaze-widget-panel', 'Kaze Control Center')", repo_dir .. "/lua/?.lua;" .. package.path))
            ))
            assert(os.execute(run("kaze-panel", "", "HYPRLAND_INSTANCE_SIGNATURE=live")))
            assert_eq(fs.file_exists(tmp .. "/guard-foot"), false, "same panel view blocked by subtarget dismiss guard")

            os.execute(string.format(
                "env HOME=%s XDG_RUNTIME_DIR=%s lua -e %s",
                q(tmp),
                q(tmp .. "/runtime"),
                q(string.format("package.path=%q; require('kaze.popups').record_dismiss_guard('kaze-widget-panel', 'Kaze Control Center')", repo_dir .. "/lua/?.lua;" .. package.path))
            ))
            assert(os.execute(run("kaze-panel", "--wifi", "HYPRLAND_INSTANCE_SIGNATURE=live")))
            assert_eq(fs.file_exists(tmp .. "/guard-foot"), true, "different panel sub-view opens on first click")

            -- Fuzzel subtarget dismiss guard: same menu blocked, different menu opens on first click
            local guard_res = assert(fs.capture(string.format(
                "env HOME=%s XDG_RUNTIME_DIR=%s lua -e %s",
                q(tmp),
                q(tmp .. "/runtime"),
                q(string.format(
                    "package.path=%q; local p=require('kaze.popups'); "
                        .. "p.record_dismiss_guard('fuzzel','kaze-power'); local same=p.consume_dismiss_guard('fuzzel','kaze-power'); "
                        .. "p.record_dismiss_guard('fuzzel','kaze-power'); local diff=p.consume_dismiss_guard('fuzzel','kaze-menu'); "
                        .. "print(tostring(same)..'|'..tostring(diff))",
                    repo_dir .. "/lua/?.lua;" .. package.path
                ))
            )))
            assert_eq(guard_res, "true|false\n", "fuzzel subtarget guard blocks same tag and allows cross-switch")
        end)
    end)
end

dofile(repo_dir .. "/tests/test_stage3_keys.lua")(test, assert_eq, assert_true, assert_contains, repo_dir)
dofile(repo_dir .. "/tests/test_stage3_theme_wall.lua")(test, assert_eq, assert_true, assert_contains, repo_dir)
dofile(repo_dir .. "/tests/test_stage3_profile_doctor.lua")(test, assert_eq, assert_true, assert_contains, repo_dir)

io.stdout:write(string.format("\nSummary: %d passed, %d failed\n", passed, failed))
if failed > 0 then
    os.exit(1)
end
