-- Minimal Hyprland-only settings loader (defaults + optional ~/.config/hypr/user.lua).
-- Noctalia natively owns bar layout, theme/palettes, wallpaper, idle, lockscreen, and Night Light.
local fs = require("kaze.fs")

local M = {}

local DEFAULT_SCRATCHPADS = {
    scratch = "kaze-footclient -N",
    music = "sh -c 'for app in spotify-launcher spotify ncspot rmpc cmus ncmpcpp amberol lollypop elisa; do "
        .. "if command -v \"$app\" >/dev/null 2>&1; then case \"$app\" in ncspot|rmpc|cmus|ncmpcpp) exec kaze-footclient -N -e \"$app\" ;; *) exec \"$app\" ;; esac; fi; "
        .. "done; command -v notify-send >/dev/null 2>&1 && notify-send -a kaze -t 3000 \"Music scratchpad\" \"Install a player or set scratchpads.music in ~/.config/hypr/user.lua\"'",
    communication = "sh -c 'for app in vesktop discord telegram-desktop signal-desktop element-desktop slack thunderbird; do "
        .. "if command -v \"$app\" >/dev/null 2>&1; then exec \"$app\"; fi; "
        .. "done; command -v notify-send >/dev/null 2>&1 && notify-send -a kaze -t 3000 \"Communication scratchpad\" \"Install a chat app or set scratchpads.communication in ~/.config/hypr/user.lua\"'",
    todo = "sh -c 'docs=$(xdg-user-dir DOCUMENTS 2>/dev/null || true); "
        .. "[ -n \"$docs\" ] && [ \"$docs\" != \"$HOME\" ] || docs=\"$HOME/Documents\"; "
        .. "mkdir -p -- \"$docs\"; todo=\"$docs/todo.md\"; ed=\"${EDITOR:-}\"; "
        .. "if [ -z \"$ed\" ] || ! command -v \"$ed\" >/dev/null 2>&1; then for c in nvim vim nano; do if command -v \"$c\" >/dev/null 2>&1; then ed=\"$c\"; break; fi; done; fi; "
        .. "if [ -n \"$ed\" ]; then exec kaze-footclient -N -e \"$ed\" \"$todo\"; "
        .. "else command -v notify-send >/dev/null 2>&1 && notify-send -a kaze -t 3000 \"Todo scratchpad\" \"Install nvim or set scratchpads.todo in ~/.config/hypr/user.lua\"; fi'",
}

local DEFAULTS = {
    profile = "minimal",
    font = "JetBrainsMono Nerd Font",
    terminal = "kaze-footclient",
    browser = "xdg-open https://",
    editor = "nvim",
    files = "thunar",
    cursor_theme = "Adwaita",
    cursor_size = 24,
    kb_layout = "us",
    accel_profile = "flat",
    workspace_swipe = true,
    persistent_workspaces = 5,
    display_hotplug_menu = true,
    drm_devices = nil,
    prefer_mesa_egl = false,
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
    focus_mode = {
        allow_tearing = false,
        hide_bar = false,
    },
    project_dirs = nil,
    project_mode = "shell",
    monitors = nil,
    scratchpads = DEFAULT_SCRATCHPADS,
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

-- Resolved visual settings shared between hypr/core.lua and Focus/Game Mode restore.
function M.visual_config(cfg)
    cfg = cfg or DEFAULTS
    local blur = type(cfg.blur) == "table" and cfg.blur or {}
    local op = type(cfg.opacity) == "table" and cfg.opacity or {}
    return {
        general = {
            allow_tearing = false,
            gaps_in = tonumber(cfg.gaps_in) or 4,
            gaps_out = tonumber(cfg.gaps_out) or 8,
        },
        decoration = {
            rounding = tonumber(cfg.rounding) or 0,
            active_opacity = tonumber(op.active) or 1.0,
            inactive_opacity = tonumber(op.inactive) or 1.0,
            blur = {
                enabled = blur.enabled ~= false,
                size = blur.size or 3,
                passes = blur.passes or 1,
                xray = blur.xray ~= false,
            },
            shadow = {
                enabled = cfg.shadow == true,
            },
        },
        animations = {
            enabled = true,
        },
    }
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
