local ctx = require("kaze._ctx")
local fs = require("kaze.fs")

local cli = fs.shell_quote(fs.home() .. "/.local/bin/kaze-session")
local signature = os.getenv("HYPRLAND_INSTANCE_SIGNATURE") or ""

hl.on("hyprland.start", function()
    local cfg = ctx.cfg
    hl.exec_cmd(cli .. " start && hyprctl setcursor " .. fs.shell_quote(cfg.cursor_theme) .. " " .. tostring(cfg.cursor_size))
end)

hl.on("hyprland.shutdown", function()
    local cmd = "HYPRLAND_INSTANCE_SIGNATURE=" .. fs.shell_quote(signature) .. " " .. cli .. " stop 2>&1"
    local proc = io.popen(cmd, "r")
    if not proc then return end
    local out = proc:read("*a")
    proc:close()
    if out and out ~= "" then io.stderr:write(out) end
end)
