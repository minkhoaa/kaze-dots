local ctx = require("kaze._ctx")
local cfg = ctx.cfg

local locked = { locked = true }
local repeating = { repeating = true }
local locked_repeating = { locked = true, repeating = true }
local mouse = { mouse = true }

-- Launchers & Kaze Command Palette
hl.bind("SUPER + SPACE",         hl.dsp.exec_cmd("pkill -x fuzzel || fuzzel"))
hl.bind("SUPER + D",             hl.dsp.exec_cmd("pkill -x fuzzel || fuzzel"))
hl.bind("SUPER + SHIFT + SPACE", hl.dsp.exec_cmd("kaze-menu"))
hl.bind("SUPER + SHIFT + L",     hl.dsp.exec_cmd("kaze-layout --menu"))
hl.bind("SUPER + SHIFT + T",     hl.dsp.exec_cmd("kaze-theme --menu"))
hl.bind("SUPER + V",             hl.dsp.exec_cmd("pkill -x fuzzel || kaze-clipboard pick"))
hl.bind("CTRL + ALT + Delete",   hl.dsp.exec_cmd("kaze-power"))
hl.bind("SUPER + L",             hl.dsp.exec_cmd("kaze-session lock"))
hl.bind("CTRL + ALT + C",        hl.dsp.exec_cmd("fnottctl dismiss all"), locked)

-- The hotkeys do not need an exit status. $TERMINAL keeps footclient's wait semantics.
local terminal_cmd = cfg.terminal == "kaze-footclient" and "kaze-footclient -N" or cfg.terminal
hl.bind("SUPER + T",             hl.dsp.exec_cmd(terminal_cmd))
hl.bind("SUPER + Return",        hl.dsp.exec_cmd(terminal_cmd))
hl.bind("SUPER + W",             hl.dsp.exec_cmd(cfg.browser))
local files_cmd = cfg.files
if files_cmd == require("kaze.defaults").files then
    files_cmd = "if command -v yazi >/dev/null; then exec kaze-footclient -N -e yazi; "
        .. "else notify-send 'File manager unavailable' 'Install yazi or set files in kaze/user.lua'; fi"
end
hl.bind("SUPER + E",             hl.dsp.exec_cmd(files_cmd))

-- Ephemeral Floating TUIs
hl.bind("SUPER + ALT + W",       hl.dsp.exec_cmd("kaze-tui wifi"))
hl.bind("SUPER + ALT + B",       hl.dsp.exec_cmd("kaze-tui bluetooth"))
hl.bind("SUPER + ALT + A",       hl.dsp.exec_cmd("kaze-tui audio"))
hl.bind("CTRL + SHIFT + Escape", hl.dsp.exec_cmd("kaze-tui sysmon"))

-- Screenshots
hl.bind("Print",                 hl.dsp.exec_cmd("kaze-screenshot screen"), locked)
hl.bind("SUPER + SHIFT + S",     hl.dsp.exec_cmd("kaze-screenshot region"))

-- Sync & Reload Shell
hl.bind("CTRL + SUPER + ALT + R", hl.dsp.exec_cmd("kaze-sync --reload"))

-- Window Management
hl.bind("SUPER + Q",             hl.dsp.window.close())
hl.bind("SUPER + F",             hl.dsp.window.fullscreen({ mode = "fullscreen" }))
hl.bind("SUPER + ALT + F",       hl.dsp.window.fullscreen({ mode = "maximized" }))
hl.bind("SUPER + ALT + Space",   hl.dsp.window.float())
hl.bind("SUPER + P",             hl.dsp.window.pin())
hl.bind("ALT + TAB",             hl.dsp.window.cycle_next(), repeating)
hl.bind("SHIFT + ALT + TAB",     hl.dsp.window.cycle_next({ next = false }), repeating)

for _, dir in ipairs({ "left", "right", "up", "down" }) do
    hl.bind("SUPER + " .. dir,         hl.dsp.focus({ direction = dir }))
    hl.bind("SUPER + SHIFT + " .. dir, hl.dsp.window.move({ direction = dir }))
end
hl.bind("SUPER + H", hl.dsp.focus({ direction = "left" }))
hl.bind("SUPER + J", hl.dsp.focus({ direction = "down" }))
hl.bind("SUPER + K", hl.dsp.focus({ direction = "up" }))

-- Workspaces 1..10
for i = 1, 10 do
    local key = tostring(i % 10)
    hl.bind("SUPER + " .. key,         hl.dsp.focus({ workspace = tostring(i) }))
    hl.bind("SUPER + SHIFT + " .. key, hl.dsp.window.move({ workspace = tostring(i) }))
    hl.bind("SUPER + ALT + " .. key,   hl.dsp.window.move({ workspace = tostring(i) }))
end
hl.bind("SUPER + mouse_down", hl.dsp.focus({ workspace = "+1" }))
hl.bind("SUPER + mouse_up",   hl.dsp.focus({ workspace = "-1" }))
hl.bind("SUPER + S",          hl.dsp.workspace.toggle_special("scratch"))
hl.bind("SUPER + ALT + S",    hl.dsp.window.move({ workspace = "special:scratch" }))

-- Mouse Drag / Resize
hl.bind("SUPER + mouse:272", hl.dsp.window.drag(), mouse)
hl.bind("SUPER + mouse:273", hl.dsp.window.resize(), mouse)

-- Hardware OSD & Media. Drop hardware repeats before spawning a process.
local osd_busy = {}
local function repeat_osd(action, channel)
    return function()
        if osd_busy[channel] then return end
        osd_busy[channel] = true
        hl.timer(function() osd_busy[channel] = nil end, { timeout = 80, type = "oneshot" })
        hl.exec_cmd("kaze-osd " .. action)
    end
end
hl.bind("XF86AudioRaiseVolume",  repeat_osd("vol-up", "volume"), locked_repeating)
hl.bind("XF86AudioLowerVolume",  repeat_osd("vol-down", "volume"), locked_repeating)
hl.bind("XF86AudioMute",         hl.dsp.exec_cmd("kaze-osd vol-mute"), locked)
hl.bind("XF86AudioMicMute",      hl.dsp.exec_cmd("kaze-osd mic-mute"), locked)
hl.bind("XF86MonBrightnessUp",   repeat_osd("bright-up", "backlight"), locked_repeating)
hl.bind("XF86MonBrightnessDown", repeat_osd("bright-down", "backlight"), locked_repeating)
hl.bind("XF86AudioPlay",         hl.dsp.exec_cmd("playerctl play-pause"), locked)
hl.bind("XF86AudioNext",         hl.dsp.exec_cmd("playerctl next"), locked)
hl.bind("XF86AudioPrev",         hl.dsp.exec_cmd("playerctl previous"), locked)
