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
        hl.dispatch(hl.dsp.window.pin({ action = "on", window = win }))
    end
end

local scratchpads = type(cfg.scratchpads) == "table" and cfg.scratchpads or {}

local function toggle_or_spawn_special(ws)
    local spawn_cmd = scratchpads[ws]
    if type(spawn_cmd) ~= "string" or spawn_cmd == "" then
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
        return toggle_or_spawn_special(entry.workspace)
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

if hl.on then
    hl.on("keybinds.submap", function()
        hl.exec_cmd("pkill -RTMIN+12 -x --require-handler waybar || true")
    end)

    -- Click-outside and focus-loss auto-dismiss for open Kaze floating popovers
    -- (kaze-widget-* and fuzzel layers). Click binds are armed dynamically only
    -- while at least one popover is open (0 overhead during normal work).
    if hl.get_windows and hl.get_cursor_pos and hl.unbind and hl.dsp and hl.dsp.window and hl.dsp.window.close then
        local ok_popups, popups = pcall(require, "kaze.popups")
        local outside_armed = false
        local armed_binds = {}

        local function is_obj(v)
            local t = type(v)
            return t == "table" or t == "userdata"
        end

        local function get_field(obj, key)
            if not is_obj(obj) then
                return nil
            end
            local ok, val = pcall(function() return obj[key] end)
            if ok then
                return val
            end
            return nil
        end

        local function vec_xy(v)
            if not is_obj(v) then
                return nil, nil
            end
            local vx = get_field(v, "x")
            local vy = get_field(v, "y")
            if vx == nil then vx = get_field(v, 1) end
            if vy == nil then vy = get_field(v, 2) end
            return tonumber(vx), tonumber(vy)
        end

        local function is_popover_win(w)
            local cls = get_field(w, "class")
            return type(cls) == "string" and cls:match("^kaze%-widget%-") ~= nil
        end

        local function is_popover_layer(l)
            if not is_obj(l) then
                return false
            end
            if get_field(l, "mapped") == false then
                return false
            end
            local ns = get_field(l, "namespace")
            if type(ns) ~= "string" then
                return false
            end
            return ns == "launcher" or ns:match("^kaze%-popup%-") ~= nil
        end

        local function open_popovers()
            local wins = {}
            for _, w in ipairs(hl.get_windows({ mapped = true }) or {}) do
                local addr = get_field(w, "address")
                if is_popover_win(w) and type(addr) == "string" then
                    wins[#wins + 1] = w
                end
            end
            local layers = {}
            if hl.get_layers then
                for _, l in ipairs(hl.get_layers() or {}) do
                    if is_popover_layer(l) then
                        layers[#layers + 1] = l
                    end
                end
            end
            return wins, layers
        end

        local function point_in_win(cx, cy, w, pad)
            local wx, wy = vec_xy(get_field(w, "at"))
            local ww, wh = vec_xy(get_field(w, "size"))
            if not (wx and wy) then
                wx, wy = tonumber(get_field(w, "x")), tonumber(get_field(w, "y"))
            end
            if not (ww and wh) then
                ww, wh = tonumber(get_field(w, "w")), tonumber(get_field(w, "h"))
            end
            if not (wx and wy and ww and wh) then
                return false
            end
            local p = pad or 4
            return cx >= (wx - p) and cx <= (wx + ww + p) and cy >= (wy - p) and cy <= (wy + wh + p)
        end

        local function point_in_layer(cx, cy, l, pad)
            if not is_obj(l) then
                return false
            end
            local lx = tonumber(get_field(l, "x"))
            local ly = tonumber(get_field(l, "y"))
            local lw = tonumber(get_field(l, "w"))
            local lh = tonumber(get_field(l, "h"))
            if not (lx and ly) then
                lx, ly = vec_xy(get_field(l, "at"))
            end
            if not (lw and lh) then
                lw, lh = vec_xy(get_field(l, "size"))
            end
            if not (lx and ly and lw and lh and lw > 0 and lh > 0) then
                return false
            end
            local p = pad or 0
            return cx >= (lx - p) and cx <= (lx + lw + p) and cy >= (ly - p) and cy <= (ly + lh + p)
        end

        local function cursor_on_waybar(cx, cy)
            if not hl.get_layers then
                return false
            end
            for _, l in ipairs(hl.get_layers({ namespace = "waybar" }) or {}) do
                if get_field(l, "mapped") ~= false and point_in_layer(cx, cy, l, 2) then
                    return true
                end
            end
            return false
        end

        local function disarm_outside()
            if not outside_armed then
                return
            end
            outside_armed = false
            for _, kb in ipairs(armed_binds) do
                if type(kb) == "table" and kb.unbind then
                    pcall(kb.unbind, kb)
                elseif type(kb) == "userdata" and kb.unbind then
                    pcall(kb.unbind, kb)
                end
            end
            armed_binds = {}
            pcall(hl.unbind, "mouse:272")
            pcall(hl.unbind, "mouse:273")
        end

        local function on_outside_click()
            local wins, layers = open_popovers()
            if #wins == 0 and #layers == 0 then
                disarm_outside()
                return
            end
            local cx, cy = vec_xy(hl.get_cursor_pos())
            if not (cx and cy) then
                return
            end
            for _, w in ipairs(wins) do
                if point_in_win(cx, cy, w, 6) then
                    return
                end
            end
            for _, l in ipairs(layers) do
                if point_in_layer(cx, cy, l, 4) then
                    return
                end
            end

            local on_bar = cursor_on_waybar(cx, cy)
            if on_bar and ok_popups then
                local w_cls = #wins > 0 and get_field(wins[1], "class") or nil
                if type(w_cls) == "string" then
                    local w_title = get_field(wins[1], "title")
                    pcall(popups.record_dismiss_guard, w_cls, type(w_title) == "string" and w_title or "")
                elseif #layers > 0 then
                    local ok_tag, active_tag = pcall(popups.active_fuzzel_tag)
                    pcall(popups.record_dismiss_guard, "fuzzel", (ok_tag and type(active_tag) == "string") and active_tag or "")
                end
            end

            for _, w in ipairs(wins) do
                local raw_addr = get_field(w, "address")
                if type(raw_addr) == "string" then
                    local addr = raw_addr:match("^0x") and raw_addr or ("0x" .. raw_addr)
                    hl.dispatch(hl.dsp.window.close({ window = "address:" .. addr }))
                end
            end
            if #layers > 0 then
                local pids = {}
                for _, l in ipairs(layers) do
                    local pid = tonumber(get_field(l, "pid"))
                    if pid and pid > 0 and math.floor(pid) == pid then
                        pids[#pids + 1] = tostring(math.floor(pid))
                    end
                end
                if #pids > 0 then
                    -- Target exact dismissed layer PIDs so a newly launched fuzzel on cross-click is never killed.
                    hl.exec_cmd("kill " .. table.concat(pids, " ") .. " 2>/dev/null || true")
                else
                    hl.exec_cmd("pkill -x fuzzel || true")
                end
                if ok_popups then
                    pcall(popups.clear_active_fuzzel)
                end
            end
            disarm_outside()
        end

        local function sync_outside()
            local wins, layers = open_popovers()
            if #wins > 0 or #layers > 0 then
                if not outside_armed then
                    outside_armed = true
                    local bind_opts = {
                        non_consuming = true,
                        description = "Dismiss open Kaze popover on outside click",
                    }
                    armed_binds = {
                        hl.bind("mouse:272", on_outside_click, bind_opts),
                        hl.bind("mouse:273", on_outside_click, bind_opts),
                    }
                end
            else
                disarm_outside()
            end
        end

        local function close_on_focus_shift(active_win)
            if is_obj(active_win) and is_popover_win(active_win) then
                sync_outside()
                return
            end
            local act_cls = get_field(active_win, "class")
            if type(act_cls) == "string" and act_cls ~= "" then
                local wins = {}
                for _, w in ipairs(hl.get_windows({ mapped = true }) or {}) do
                    local addr = get_field(w, "address")
                    if is_popover_win(w) and type(addr) == "string" then
                        wins[#wins + 1] = addr
                    end
                end
                for _, raw_addr in ipairs(wins) do
                    local addr = raw_addr:match("^0x") and raw_addr or ("0x" .. raw_addr)
                    hl.dispatch(hl.dsp.window.close({ window = "address:" .. addr }))
                end
            end
            sync_outside()
        end

        hl.on("window.open", sync_outside)
        hl.on("window.close", sync_outside)
        hl.on("layer.opened", sync_outside)
        hl.on("layer.closed", sync_outside)
        hl.on("window.active", close_on_focus_shift)
    end
end
