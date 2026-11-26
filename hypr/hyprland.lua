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
    "kaze.keybinds_data",
    "noctalia",
    "env",
    "core",
    "rules",
    "execs",
    "keybinds",
}) do
    package.loaded[mod] = nil
end

local cfg = require("kaze.hypr_user").load()
local ok_noc, noctalia_theme = pcall(require, "noctalia")
if not (ok_noc and type(noctalia_theme) == "table") then
    noctalia_theme = nil
end

package.loaded["kaze._ctx"] = {
    cfg = cfg,
    noctalia = noctalia_theme,
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

-- Apply Noctalia built-in Hyprland color template when present.
-- Keeping require("noctalia") here ensures Noctalia's template apply script
-- never appends duplicate lines into this symlinked config.
if noctalia_theme and type(noctalia_theme.apply_theme) == "function" then
    noctalia_theme.apply_theme()
end
