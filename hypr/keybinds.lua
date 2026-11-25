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

local function resize_step(dx_pct, dy_pct)
    return function()
        local win = hl.get_active_window()
        if win and win.size then
            local dx = math.floor(win.size.x * (dx_pct / 100))
            local dy = math.floor(win.size.y * (dy_pct / 100))
            hl.dispatch(hl.dsp.window.resize({ x = dx, y = dy, relative = true }))
        end
    end
end

local function normalize_window()
    return function()
        local screen = hl.get_active_monitor()
        if screen and type(screen.width) == "number" and type(screen.height) == "number" then
            local scale = (type(screen.scale) == "number" and screen.scale > 0) and screen.scale or 1
            local w = math.floor((screen.width / scale) * 0.55)
            local h = math.floor((screen.height / scale) * 0.70)
            hl.dispatch(hl.dsp.window.resize({ x = w, y = h, relative = false }))
            hl.dispatch(hl.dsp.window.center())
        end
    end
end

local function pin_pip()
    return function()
        local win = hl.get_active_window()
        local screen = hl.get_active_monitor()
        if not (win and win.size and screen and screen.width and screen.height and win.size.y > 0) then
            return
        end
        local scale = (type(screen.scale) == "number" and screen.scale > 0) and screen.scale or 1
        local mw = screen.width / scale
        local mh = screen.height / scale
        local factor = (mh / 4) / win.size.y
        local rw = math.floor(math.max(200, win.size.x * factor))
        local rh = math.floor(math.max(150, win.size.y * factor))
        local offset = math.min(mw, mh) * 0.03
        local mx = math.floor((screen.x or 0) + mw - rw - offset)
        local my = math.floor((screen.y or 0) + mh - rh - offset)
        if not win.floating then
            hl.dispatch(hl.dsp.window.float())
        end
        hl.dispatch(hl.dsp.window.resize({ x = rw, y = rh, window = win }))
        hl.dispatch(hl.dsp.window.move({ x = mx, y = my, relative = false, window = win }))
        hl.dispatch(hl.dsp.window.set_prop({ prop = "keep_aspect_ratio", value = "true", window = win }))
        hl.dispatch(hl.dsp.window.pin({ action = "on", window = "address:" .. tostring(win.address) }))
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
    elseif kind == "window_center" then
        return hl.dsp.window.center()
    elseif kind == "window_resize_step" then
        return resize_step(entry.args.x, entry.args.y)
    elseif kind == "window_normalize" then
        return normalize_window()
    elseif kind == "window_pip" then
        return pin_pip()
    elseif kind == "cycle_next" then
        if entry.args then
            return hl.dsp.window.cycle_next(entry.args)
        end
        return hl.dsp.window.cycle_next()
    elseif kind == "group_toggle" then
        return hl.dsp.group.toggle()
    elseif kind == "group_lock" then
        return hl.dsp.group.lock()
    elseif kind == "group_next" then
        return hl.dsp.group.next()
    elseif kind == "group_prev" then
        return hl.dsp.group.prev()
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
    if entry.release then
        opts.release = true
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
