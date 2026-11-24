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
    assert_eq(list[1], "noctalia", "first theme")
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

    local overridden = themes.get("noctalia", { accent = "ff00aa", term = nil })
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
    state.save({ layout = "noctalia", theme = "tokyonight" }, sp)
    local loaded = state.load(sp)
    assert_eq(loaded.layout, "noctalia", "state layout")
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

    state.save({ layout = "noctalia", theme = "lavender" }, state_path)
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

    assert_eq(cfg.layout, "noctalia", "layout preserved")
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
    assert_eq(cfg3.layout, "noctalia", "non-strict layout fallback")
    assert_eq(layout3.name, "noctalia", "non-strict layout spec fallback")
    assert_eq(theme3.name, "noctalia", "non-strict theme fallback")

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

test("emitters: noctalia x all 4 themes produce valid configs with zero polling", function()
    local tmp = make_tmp_dir()
    local has_foot = cmd_exists("foot")
    local has_fuzzel = cmd_exists("fuzzel")

    local layout = layouts.get("noctalia")
    for _, theme_name in ipairs(themes.list()) do
        local theme = themes.get(theme_name)
        local cfg = {
            layout = "noctalia",
            theme = theme_name,
            font = "JetBrainsMono Nerd Font",
            terminal = "footclient",
            cursor_theme = "Adwaita",
            wallpaper_expanded = "/home/bench/Pictures/Wallpapers/wallpaper.png",
            hypr = layout.hypr,
            ui = layout.ui,
        }

        local wb = emit_waybar.emit(cfg, theme, layout)
        assert_contains(wb.colors_css, "@define-color accent    #" .. theme.accent .. ";", "waybar colors.css")
        assert_contains(wb.style_css, '@import "colors.css";', "waybar style.css import")
        assert_balanced(wb.style_css, "{", "}", "waybar style.css")

        local stripped = strip_jsonc_comments(wb.config_jsonc)
        local parsed = parse_json(stripped)
        assert_eq(parsed.height, 34, "noctalia height")
        assert_eq(parsed["margin-top"], 6, "noctalia margin-top")
        assert_eq(parsed["margin-left"], 10, "noctalia margin-left")
        assert_eq(parsed["margin-right"], 10, "noctalia margin-right")
        assert_eq(parsed["custom/menu"].exec, nil, "custom/menu must have zero polling exec")
        assert_eq(parsed["custom/menu"].interval, nil, "custom/menu must have zero polling interval")
        assert_eq(parsed["custom/power"].exec, nil, "custom/power must have zero polling exec")
        assert_eq(parsed["custom/power"].interval, nil, "custom/power must have zero polling interval")

        local foot_ini = emit_foot.emit(cfg, theme, layout)
        assert_contains(foot_ini, "background=" .. theme.bg, "foot background")
        if has_foot then
            local fp = tmp .. "/foot-" .. theme_name .. ".ini"
            fs.write_atomic(fp, foot_ini)
            local ok = os.execute("foot --check-config -c " .. fs.shell_quote(fp) .. " >/dev/null 2>&1")
            assert_true(ok == true or ok == 0, "foot --check-config failed for " .. theme_name)
        end

        local fuzzel_ini = emit_fuzzel.emit(cfg, theme, layout)
        assert_contains(fuzzel_ini, "radius=12", "fuzzel radius")
        assert_contains(fuzzel_ini, "background=" .. theme.bg_alt .. "e8", "fuzzel bg")
        if has_fuzzel then
            local zp = tmp .. "/fuzzel-" .. theme_name .. ".ini"
            fs.write_atomic(zp, fuzzel_ini)
            local ok = os.execute("fuzzel --check-config --config " .. fs.shell_quote(zp) .. " >/dev/null 2>&1")
            assert_true(ok == true or ok == 0, "fuzzel --check-config failed for " .. theme_name)
        end

        local fnott_ini = emit_fnott.emit(cfg, theme, layout)
        assert_contains(fnott_ini, "progress-color=" .. theme.accent .. "ff", "fnott progress-color")
        assert_contains(fnott_ini, "border-radius=10", "fnott radius")
        assert_contains(fnott_ini, "edge-margin-vertical=48", "fnott vertical margin")

        local hl_conf = emit_hyprlock.emit(cfg, theme, layout)
        assert_contains(hl_conf, "rgb(" .. theme.accent .. ")", "hyprlock accent")
        assert_balanced(hl_conf, "{", "}", "hyprlock.conf")
    end

    rm_rf(tmp)
end)

test("CLI: kaze-sync writes isolated XDG_CONFIG_HOME and rejects bad args", function()
    local tmp = make_tmp_dir()
    local env_prefix = "HOME=" .. fs.shell_quote(tmp) .. " XDG_CONFIG_HOME=" .. fs.shell_quote(tmp .. "/cfg")

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

    local bad_sync = os.execute(env_prefix .. " " .. fs.shell_quote(repo_dir .. "/bin/kaze-sync") .. " --invalid >/dev/null 2>&1")
    assert_true(bad_sync ~= true and bad_sync ~= 0, "kaze-sync --invalid must fail")

    local bad_tui = os.execute(fs.shell_quote(repo_dir .. "/bin/kaze-tui") .. " bogus >/dev/null 2>&1")
    assert_true(bad_tui ~= true and bad_tui ~= 0, "kaze-tui bogus must fail")

    local bad_osd = os.execute(fs.shell_quote(repo_dir .. "/bin/kaze-osd") .. " bogus >/dev/null 2>&1")
    assert_true(bad_osd ~= true and bad_osd ~= 0, "kaze-osd bogus must fail")

    rm_rf(tmp)
end)

io.stdout:write(string.format("\nSummary: %d passed, %d failed\n", passed, failed))
if failed > 0 then
    os.exit(1)
end
