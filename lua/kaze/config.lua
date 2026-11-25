local defaults = require("kaze.defaults")
local fs = require("kaze.fs")
local layouts = require("kaze.layouts")
local state = require("kaze.state")
local themes = require("kaze.themes")

local M = {}

local function is_array(t)
    if type(t) ~= "table" then
        return false
    end
    local count = 0
    for k, _ in pairs(t) do
        if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
            return false
        end
        count = count + 1
    end
    return count > 0 and count == #t
end

function M.deep_copy(v)
    if type(v) ~= "table" then
        return v
    end
    local out = {}
    for k, val in pairs(v) do
        out[k] = M.deep_copy(val)
    end
    return out
end

function M.deep_merge(...)
    local acc = {}
    local n = select("#", ...)
    for i = 1, n do
        local src = select(i, ...)
        if type(src) == "table" then
            for k, v in pairs(src) do
                if type(v) == "table" and not is_array(v) and type(acc[k]) == "table" and not is_array(acc[k]) then
                    acc[k] = M.deep_merge(acc[k], v)
                else
                    acc[k] = M.deep_copy(v)
                end
            end
        end
    end
    return acc
end

local function load_lua_table(path)
    if not fs.file_exists(path) then
        return {}
    end
    local env = setmetatable({}, { __index = _G })
    local chunk, load_err = loadfile(path, "t", env)
    if not chunk then
        io.stderr:write(string.format("kaze warning: failed to load %s: %s\n", path, tostring(load_err)))
        return {}
    end
    local ok, res = pcall(chunk)
    if not ok then
        io.stderr:write(string.format("kaze warning: runtime error in %s: %s\n", path, tostring(res)))
        return {}
    end
    if type(res) ~= "table" then
        io.stderr:write(string.format("kaze warning: %s must return a table (got %s)\n", path, type(res)))
        return {}
    end
    return res
end

function M.load(opts)
    opts = opts or {}
    local strict = opts.strict ~= false
    local home = opts.home or fs.home()
    local config_dir = opts.config_dir or fs.config_dir(home)
    local state_path = opts.state_path or state.path(config_dir)
    local user_path = opts.user_path or (config_dir .. "/kaze/user.lua")

    local state_tbl = opts.state or state.load(state_path)
    local user_tbl = load_lua_table(user_path)

    local layout_name = user_tbl.layout or state_tbl.layout or defaults.layout
    local ok_layout, layout_spec = pcall(layouts.get, layout_name)
    if not ok_layout then
        if strict then
            error(layout_spec)
        end
        io.stderr:write(string.format("kaze warning: %s; falling back to 'sidebar'\n", tostring(layout_spec)))
        layout_spec = layouts.get("sidebar")
    end

    local cfg = M.deep_merge(
        defaults,
        {
            hypr = layout_spec.hypr,
            ui = layout_spec.ui,
        },
        state_tbl,
        user_tbl
    )
    cfg.layout = layout_spec.name
    cfg.wallpaper_expanded = fs.expand_home(cfg.wallpaper, home)

    local theme_name = cfg.theme or defaults.theme
    local ok_theme, theme = pcall(themes.get, theme_name, cfg.theme_overrides)
    if not ok_theme then
        if strict then
            error(theme)
        end
        io.stderr:write(string.format("kaze warning: %s; falling back to 'kaze'\n", tostring(theme)))
        cfg.theme = "kaze"
        theme = themes.get("kaze")
    end

    local effective_layout = M.deep_copy(layout_spec)
    effective_layout.hypr = M.deep_copy(cfg.hypr)
    effective_layout.ui = M.deep_copy(cfg.ui)

    return cfg, theme, effective_layout
end

return M
