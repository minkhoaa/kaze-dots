local home = os.getenv("HOME") or ""
local xdg_data = os.getenv("XDG_DATA_HOME")
if not xdg_data or xdg_data == "" then
    xdg_data = home .. "/.local/share"
end
local xdg_cfg = os.getenv("XDG_CONFIG_HOME")
if not xdg_cfg or xdg_cfg == "" then
    xdg_cfg = home .. "/.config"
end

package.path = table.concat({
    xdg_data .. "/kaze-dots/lua/?.lua",
    xdg_data .. "/kaze-dots/lua/?/init.lua",
    xdg_cfg .. "/hypr/?.lua",
    package.path,
}, ";")

for _, mod in ipairs({
    "kaze._ctx",
    "kaze.hypr_user",
    "kaze.fs",
    "kaze.json",
    "kaze.popups",
    "kaze.display",
    "kaze.keybinds_data",
    "kaze-theme",
    "env",
    "core",
    "rules",
    "execs",
    "keybinds",
}) do
    package.loaded[mod] = nil
end

local cfg = require("kaze.hypr_user").load()
local ok_kaze, kaze_theme = pcall(require, "kaze-theme")
if not (ok_kaze and type(kaze_theme) == "table") then
    kaze_theme = nil
end

package.loaded["kaze._ctx"] = {
    cfg = cfg,
    theme = kaze_theme,
}

local monitors = cfg.monitors
if type(monitors) == "table" and #monitors > 0 then
    for _, mon in ipairs(monitors) do
        local spec = {
            output = mon.output or "",
            mode = mon.mode or "preferred",
            position = mon.position or "auto",
            scale = mon.scale or 1,
        }
        if mon.disabled == true then
            spec.disabled = true
        else
            spec.disabled = false
            spec.mirror = ""
        end
        for _, k in ipairs({ "mirror", "bitdepth", "transform", "vrr", "cm", "sdrbrightness", "sdrsaturation", "reserved", "reserved_area" }) do
            if mon[k] ~= nil then
                spec[k] = mon[k]
            end
        end
        hl.monitor(spec)
    end
else
    hl.monitor({
        output = "",
        mode = "preferred",
        position = "auto",
        scale = 1,
    })
end

require("env")
require("core")
require("rules")
require("execs")
require("keybinds")

local xdg_runtime = os.getenv("XDG_RUNTIME_DIR")
if xdg_runtime and xdg_runtime:sub(1, 1) == "/" then
    local rt_monitors = xdg_runtime .. "/kaze/monitors.lua"
    local f = io.open(rt_monitors, "r")
    if f then
        f:close()
        pcall(dofile, rt_monitors)
    end
end

-- Apply kaze-shell generated Hyprland color template when present.
if kaze_theme and type(kaze_theme.apply_theme) == "function" then
    kaze_theme.apply_theme()
end

if type(cfg.border_override) == "table" and (cfg.border_override.active or cfg.border_override.inactive) then
    local col = {}
    if cfg.border_override.active then
        col.active_border = cfg.border_override.active
    end
    if cfg.border_override.inactive then
        col.inactive_border = cfg.border_override.inactive
    end
    hl.config({ general = { col = col } })
end
