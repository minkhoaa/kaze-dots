local ctx = require("kaze._ctx")
local fs = require("kaze.fs")

local cli = fs.shell_quote(fs.home() .. "/.local/bin/kaze-session")
local signature = os.getenv("HYPRLAND_INSTANCE_SIGNATURE") or ""

hl.on("hyprland.start", function()
    -- Inside the short-lived bootstrap, sync and the env import precede all units.
    local cfg = ctx.cfg
    hl.exec_cmd(cli .. " start && hyprctl setcursor " .. fs.shell_quote(cfg.cursor_theme) .. " " .. tostring(cfg.cursor_size))
end)

hl.on("hyprland.shutdown", function()
    -- Hyprland reaps children itself; pclose cannot reliably report their exit status.
    -- Reading to EOF still waits for teardown before closing the compositor.
    local cmd = "HYPRLAND_INSTANCE_SIGNATURE=" .. fs.shell_quote(signature) .. " " .. cli .. " stop 2>&1"
    local proc = io.popen(cmd, "r")
    if not proc then return end
    local out = proc:read("*a")
    proc:close()
    if out and out ~= "" then io.stderr:write(out) end
end)
