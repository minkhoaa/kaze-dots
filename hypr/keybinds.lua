local ctx = require("kaze._ctx")
local keybinds_data = require("kaze.keybinds_data")

local cfg = ctx.cfg

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

local function make_dispatcher(entry)
    local kind = entry.kind
    if kind == "exec" then
        return hl.dsp.exec_cmd(entry.cmd)
    elseif kind == "osd" then
        return repeat_osd(entry.action, entry.channel)
    elseif kind == "window_close" then
        return hl.dsp.window.close()
    elseif kind == "fullscreen" then
        return hl.dsp.window.fullscreen(entry.args)
    elseif kind == "float" then
        return hl.dsp.window.float()
    elseif kind == "pin" then
        return hl.dsp.window.pin()
    elseif kind == "cycle_next" then
        if entry.args then
            return hl.dsp.window.cycle_next(entry.args)
        end
        return hl.dsp.window.cycle_next()
    elseif kind == "focus" then
        return hl.dsp.focus(entry.args)
    elseif kind == "window_move" then
        return hl.dsp.window.move(entry.args)
    elseif kind == "toggle_special" then
        return hl.dsp.workspace.toggle_special(entry.workspace)
    elseif kind == "window_drag" then
        return hl.dsp.window.drag()
    elseif kind == "window_resize" then
        return hl.dsp.window.resize()
    end
    error("unknown keybind kind: " .. tostring(kind))
end

for _, entry in ipairs(keybinds_data.build(cfg)) do
    local opts = {}
    if entry.desc and entry.desc ~= "" then
        opts.description = entry.desc
    end
    if entry.locked then
        opts.locked = true
    end
    if entry.repeating then
        opts.repeating = true
    end
    if entry.mouse then
        opts.mouse = true
    end
    if next(opts) then
        hl.bind(entry.chord, make_dispatcher(entry), opts)
    else
        hl.bind(entry.chord, make_dispatcher(entry))
    end
end
