local ctx = require("kaze._ctx")
local hypr_user = require("kaze.hypr_user")
local keybinds_data = require("kaze.keybinds_data")

local cfg = ctx.cfg

local focus_state = {
    active = false,
    dnd_was_on = false,
    bar_hidden = false,
}

local function query_dnd_on()
    local p = io.popen("noctalia msg notification-dnd-status 2>/dev/null", "r")
    if not p then
        return nil
    end
    local out = p:read("*a") or ""
    p:close()
    local trimmed = out:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed == "on" then
        return true
    elseif trimmed == "off" then
        return false
    end
    return nil
end

local function toggle_focus_mode()
    return function()
        local fm = type(cfg.focus_mode) == "table" and cfg.focus_mode or {}
        if not focus_state.active then
            local dnd = query_dnd_on()
            focus_state.dnd_was_on = (dnd == true)
            hl.config({
                general = {
                    gaps_in = 0,
                    gaps_out = 0,
                    allow_tearing = (fm.allow_tearing == true),
                },
                decoration = {
                    rounding = 0,
                    active_opacity = 1.0,
                    inactive_opacity = 1.0,
                    blur = { enabled = false },
                    shadow = { enabled = false },
                },
                animations = { enabled = false },
            })
            if dnd == false then
                hl.exec_cmd("noctalia msg notification-dnd-set on >/dev/null 2>&1 || true")
            elseif dnd == nil then
                hl.exec_cmd("noctalia msg notification-dnd-toggle >/dev/null 2>&1 || true")
            end
            if fm.hide_bar == true then
                hl.exec_cmd("noctalia msg bar-hide default >/dev/null 2>&1 || true")
                focus_state.bar_hidden = true
            end
            focus_state.active = true
        else
            local vis = hypr_user.visual_config(cfg)
            hl.config({
                general = vis.general,
                decoration = vis.decoration,
                animations = vis.animations,
            })
            if not focus_state.dnd_was_on then
                local dnd = query_dnd_on()
                if dnd == true then
                    hl.exec_cmd("noctalia msg notification-dnd-set off >/dev/null 2>&1 || true")
                elseif dnd == nil then
                    hl.exec_cmd("noctalia msg notification-dnd-toggle >/dev/null 2>&1 || true")
                end
            end
            if focus_state.bar_hidden then
                hl.exec_cmd("noctalia msg bar-show default >/dev/null 2>&1 || true")
            end
            focus_state.active = false
            focus_state.dnd_was_on = false
            focus_state.bar_hidden = false
        end
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
        hl.dispatch(hl.dsp.window.pin({ action = "on", window = win }))
    end
end

local scratchpads = type(cfg.scratchpads) == "table" and cfg.scratchpads or {}

local function resolve_scratchpad_cmd(entry)
    if type(entry) == "string" and entry ~= "" then
        return entry
    elseif type(entry) == "table" and type(entry.cmd) == "string" and entry.cmd ~= "" then
        return entry.cmd
    end
    return nil
end

local function toggle_or_spawn_special(ws)
    local spawn_cmd = resolve_scratchpad_cmd(scratchpads[ws])
    if not spawn_cmd then
        return hl.dsp.workspace.toggle_special(ws)
    end
    return function()
        if hl.get_workspace_windows then
            local wins = hl.get_workspace_windows("special:" .. ws)
            if type(wins) == "table" and #wins == 0 then
                hl.exec_cmd(spawn_cmd, { workspace = "special:" .. ws })
            end
        end
        hl.dispatch(hl.dsp.workspace.toggle_special(ws))
    end
end

local function make_dispatcher(entry)
    local kind = entry.kind
    if kind == "exec" then
        return hl.dsp.exec_cmd(entry.cmd)
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
        return toggle_or_spawn_special(entry.workspace)
    elseif kind == "focus_mode" then
        return toggle_focus_mode()
    elseif kind == "submap" then
        if hl.dsp.submap then
            return hl.dsp.submap(entry.submap)
        end
        return hl.dsp.exec_cmd("hyprctl dispatch submap " .. tostring(entry.submap))
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

if hl.define_submap and hl.dsp.submap then
    hl.define_submap("passthrough", function()
        hl.bind("SUPER + Escape", hl.dsp.submap("reset"), {
            description = "Exit VM keybind passthrough mode",
        })
    end)
end
