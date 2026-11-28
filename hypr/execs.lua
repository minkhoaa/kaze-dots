local ctx = require("kaze._ctx")
local display = require("kaze.display")
local fs = require("kaze.fs")

local bin_dir = fs.home() .. "/.local/bin/"
local cli = fs.shell_quote(bin_dir .. "kaze-session")
local display_cli = fs.shell_quote(bin_dir .. "kaze-display")
local signature = os.getenv("HYPRLAND_INSTANCE_SIGNATURE") or ""
-- Persist initial boot timestamp across `hyprctl reload` so early `monitor.added`
-- events fired before `hyprland.start` still observe the 5s startup grace, while
-- `hyprctl reload` never re-arms it.
_G._kaze_boot_at = _G._kaze_boot_at or os.time()
local last_added_at = nil

hl.on("hyprland.start", function()
    local cfg = ctx.cfg
    _G._kaze_boot_at = os.time()
    hl.exec_cmd(cli .. " start && hyprctl setcursor " .. fs.shell_quote(cfg.cursor_theme) .. " " .. tostring(cfg.cursor_size))
end)

hl.on("monitor.added", function(mon)
    local name = mon and mon.name
    local now = os.time()
    local cfg = ctx.cfg or {}
    if display.should_ignore_hotplug(name, {
        monitor = mon,
        now = now,
        started_at = _G._kaze_boot_at,
        last_event_at = last_added_at,
        enabled = cfg.display_hotplug_menu ~= false,
    }) then
        return
    end
    last_added_at = now
    hl.exec_cmd(display_cli .. " --hotplug " .. fs.shell_quote(name))
end)

hl.on("monitor.removed", function(mon)
    local name = mon and mon.name
    if not name or name == "" or display.is_virtual_monitor(name, mon) then
        return
    end
    hl.exec_cmd(display_cli .. " --on-disconnect " .. fs.shell_quote(name))
end)

hl.on("hyprland.shutdown", function()
    local cmd = "HYPRLAND_INSTANCE_SIGNATURE=" .. fs.shell_quote(signature) .. " " .. cli .. " stop 2>&1"
    local proc = io.popen(cmd, "r")
    if not proc then return end
    local out = proc:read("*a")
    proc:close()
    if out and out ~= "" then io.stderr:write(out) end
end)
