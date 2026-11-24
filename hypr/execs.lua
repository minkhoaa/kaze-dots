local ctx = require("kaze._ctx")
local fs = require("kaze.fs")

local cfg = ctx.cfg
local theme = ctx.theme

hl.on("hyprland.start", function()
    -- Ensure all generated daemon configs are fresh before launching daemons
    local sync_cmd = (os.getenv("HOME") or "") .. "/.local/bin/kaze-sync"
    if fs.file_exists(sync_cmd) then
        os.execute(fs.shell_quote(sync_cmd) .. " >/dev/null 2>&1")
    else
        os.execute("kaze-sync >/dev/null 2>&1")
    end

    hl.exec_cmd("foot --server")

    local wallpaper = cfg.wallpaper_expanded
    if type(wallpaper) == "string" and wallpaper ~= "" and fs.file_exists(wallpaper) then
        hl.exec_cmd("swaybg -i " .. fs.shell_quote(wallpaper) .. " -m fill")
    else
        hl.exec_cmd("swaybg -c " .. fs.shell_quote("#" .. theme.bg))
    end

    hl.exec_cmd("waybar")
    hl.exec_cmd("fnott")
    hl.exec_cmd("hypridle")

    hl.exec_cmd("wl-paste --type text --watch cliphist store")
    hl.exec_cmd("wl-paste --type image --watch cliphist store")

    hl.exec_cmd("hyprctl setcursor " .. fs.shell_quote(cfg.cursor_theme) .. " " .. tostring(cfg.cursor_size))
end)
