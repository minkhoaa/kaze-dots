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
    "kaze.defaults",
    "kaze.config",
    "kaze.state",
    "kaze.themes",
    "kaze.layouts",
    "kaze.layouts.noctalia",
    "kaze.layouts.caelestia",
    "kaze.layouts.omarchy",
    "env",
    "core",
    "rules",
    "execs",
    "keybinds",
}) do
    package.loaded[mod] = nil
end

local cfg, theme, layout = require("kaze.config").load({ strict = false })
package.loaded["kaze._ctx"] = {
    cfg = cfg,
    theme = theme,
    layout = layout,
}

local monitors = cfg.monitors
if type(monitors) == "table" and #monitors > 0 then
    for _, mon in ipairs(monitors) do
        hl.monitor({
            output = mon.output or "",
            mode = mon.mode or "preferred",
            position = mon.position or "auto",
            scale = mon.scale or 1,
        })
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
