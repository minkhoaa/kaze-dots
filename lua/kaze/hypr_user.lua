-- Minimal Hyprland-only settings loader (defaults + optional ~/.config/hypr/user.lua).
-- Noctalia natively owns bar layout, theme/palettes, wallpaper, idle, lockscreen, and Night Light.
local fs = require("kaze.fs")

local M = {}

local DEFAULTS = {
    profile = "minimal",
    font = "JetBrainsMono Nerd Font",
    terminal = "kaze-footclient",
    browser = "xdg-open https://",
    editor = "nvim",
    files = "yazi",
    cursor_theme = "Adwaita",
    cursor_size = 24,
    kb_layout = "us",
    accel_profile = "flat",
    workspace_swipe = true,
    smart_gaps = false,
    fcitx5 = nil,
    gaps_in = 4,
    gaps_out = 8,
    border_size = 2,
    rounding = 0,
    shadow = false,
    blur = {
        enabled = true,
        size = 3,
        passes = 1,
        xray = true,
    },
    opacity = {
        active = 1.0,
        inactive = 1.0,
    },
    monitors = nil,
    scratchpads = {
        scratch = "kaze-footclient -N",
    },
}

local function deepcopy(v)
    if type(v) ~= "table" then
        return v
    end
    local out = {}
    for k, val in pairs(v) do
        out[k] = deepcopy(val)
    end
    return out
end

local function deepmerge(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" and type(dst[k]) == "table" and #v == 0 and #dst[k] == 0 then
            deepmerge(dst[k], v)
        else
            dst[k] = deepcopy(v)
        end
    end
    return dst
end

function M.defaults()
    return deepcopy(DEFAULTS)
end

function M.user_path(home)
    return fs.config_dir(home) .. "/hypr/user.lua"
end

function M.profile_path(home)
    return fs.config_dir(home) .. "/kaze/profile"
end

function M.load(opts)
    opts = opts or {}
    local cfg = deepcopy(DEFAULTS)

    local prof_path = opts.profile_path or M.profile_path(opts.home)
    local raw_prof = fs.read_file(prof_path)
    if raw_prof then
        local p = raw_prof:match("^%s*(%S+)%s*$")
        if p == "minimal" or p == "full" then
            cfg.profile = p
        end
    end

    local upath = opts.user_path or M.user_path(opts.home)
    if fs.file_exists(upath) then
        local chunk, err = loadfile(upath, "t", {})
        if not chunk then
            io.stderr:write("kaze warning: failed to load " .. upath .. ": " .. tostring(err) .. "\n")
        else
            local ok, res = pcall(chunk)
            if ok and type(res) == "table" then
                deepmerge(cfg, res)
            elseif not ok then
                io.stderr:write("kaze warning: error running " .. upath .. ": " .. tostring(res) .. "\n")
            end
        end
    end

    return cfg
end

return M
