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

test("themes: all 4 presets validate and helpers format properly", function()
    local list = themes.list()
    assert_eq(#list, 4, "preset count")
    assert_eq(list[1], "kaze", "first theme")
    assert_eq(list[2], "lavender", "second theme")
    assert_eq(list[3], "tokyonight", "third theme")
    assert_eq(list[4], "carbon", "fourth theme")

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

test("emitters: all 3 layouts x 4 themes (12 combinations) produce valid configs with zero polling", function()
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
            fuzzel_radius = 14,
            fnott_radius = 12,
            fnott_vmargin = 12,
        },
        islands = {
            position = "top",
            height = 34,
            margin_top = 6,
            margin_left = 10,
            margin_right = 10,
            fuzzel_radius = 12,
            fnott_radius = 10,
            fnott_vmargin = 48,
        },
        slim = {
            position = "top",
            height = 28,
            margin_top = 0,
            margin_left = 0,
            margin_right = 0,
            fuzzel_radius = 8,
            fnott_radius = 6,
            fnott_vmargin = 36,
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
            assert_contains(fuzzel_ini, "radius=" .. exp.fuzzel_radius, tag .. ": fuzzel radius")
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
            assert_contains(fnott_ini, "summary-format=%s", tag .. ": fnott summary-format")
            assert_contains(fnott_ini, "progress-color=" .. theme.accent .. "ff", tag .. ": fnott progress-color")
            assert_contains(fnott_ini, "border-radius=" .. exp.fnott_radius, tag .. ": fnott radius")
            assert_contains(fnott_ini, "edge-margin-vertical=" .. exp.fnott_vmargin, tag .. ": fnott vertical margin")
            assert_no_unresolved_tokens(fnott_ini:gsub("summary%-format=%%s", "summary-format=SUMMARY"), tag .. ": fnott.ini")

            local mako = require("kaze.emit_mako").emit(cfg, theme, layout)
            assert_contains(mako, "background-color=#" .. theme.bg_alt .. "f0")
            assert_contains(mako, "outer-margin=" .. exp.fnott_vmargin .. ",")
            assert_contains(mako, "[app-name=kaze-osd]\nhistory=0\n\n[mode=do-not-disturb]\ninvisible=1\n\n"
                .. "[mode=do-not-disturb app-name=kaze-osd]\ninvisible=0\n")
            assert_no_unresolved_tokens(mako, tag .. ": mako config")

            local hl_conf = emit_hyprlock.emit(cfg, theme, layout)
            assert_contains(hl_conf, "rgb(" .. theme.accent .. ")", tag .. ": hyprlock accent")
            assert_balanced(hl_conf, "{", "}", tag .. ": hyprlock.conf")
            assert_no_unresolved_tokens(hl_conf, tag .. ": hyprlock.conf")
        end
    end
    assert_eq(combo_count, 12, "3 layouts x 4 themes combinations")

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
        assert(os.execute(run("kaze-session", "stop", "HYPRLAND_INSTANCE_SIGNATURE=test-hyprland")))
        assert_eq(fs.read_file(tmp .. "/stop-order"), "recorder\ntarget\n")
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

io.stdout:write(string.format("\nSummary: %d passed, %d failed\n", passed, failed))
if failed > 0 then
    os.exit(1)
end
