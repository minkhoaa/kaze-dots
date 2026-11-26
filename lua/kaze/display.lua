-- Pure-Lua monitor, workspace, and presentation planner for `kaze-display` (0 I/O).
local M = {}

local json = require("kaze.json")

local function scale_num(m)
    local s = tonumber(m and m.scale) or 1
    if s <= 0 then s = 1 end
    if s % 1 == 0 then
        return math.floor(s)
    end
    return s
end

local function quote_lua(s)
    return string.format("%q", tostring(s))
end

local function format_hl_monitor(spec)
    local parts = {
        "output = " .. quote_lua(spec.output or ""),
    }
    if spec.disabled == true then
        parts[#parts + 1] = "disabled = true"
    else
        if spec.mode ~= nil then
            parts[#parts + 1] = "mode = " .. quote_lua(spec.mode)
        end
        if spec.position ~= nil then
            parts[#parts + 1] = "position = " .. quote_lua(spec.position)
        end
        if spec.scale ~= nil then
            parts[#parts + 1] = "scale = " .. tostring(spec.scale)
        end
        if spec.mirror ~= nil then
            parts[#parts + 1] = "mirror = " .. quote_lua(spec.mirror)
        end
    end
    return "hl.monitor({ " .. table.concat(parts, ", ") .. " })"
end

function M.is_virtual_monitor(name, mon)
    if type(name) == "table" and mon == nil then
        mon = name
        name = mon.name
    end
    local n = type(name) == "string" and name or ""
    if n:match("^HEADLESS%-") ~= nil or n == "kaze-share" then
        return true
    end
    if type(mon) == "table" then
        if mon.virtual == true or mon.backend == "headless" then
            return true
        end
        if type(mon.hardwareDetails) == "table" and mon.hardwareDetails.backend == "headless" then
            return true
        end
    end
    return false
end

local function is_mirror_active(m)
    local mo = type(m) == "table" and m.mirror_of or nil
    return type(mo) == "string" and mo ~= "" and mo ~= "none"
end

function M.parse_monitors(json_str)
    if type(json_str) ~= "string" or not json_str:find("%S") then
        return {}
    end
    local ok, parsed = pcall(json.decode, json_str)
    if not ok or type(parsed) ~= "table" then
        return {}
    end
    local out = {}
    for _, m in ipairs(parsed) do
        if type(m) == "table" and type(m.name) == "string" and m.name ~= "" then
            local mirror_of = type(m.mirrorOf) == "string" and m.mirrorOf or "none"
            if mirror_of == "" then
                mirror_of = "none"
            end
            local backend = (type(m.hardwareDetails) == "table" and type(m.hardwareDetails.backend) == "string")
                and m.hardwareDetails.backend
                or ""
            local active_ws = (type(m.activeWorkspace) == "table" and tonumber(m.activeWorkspace.id)) or nil
            local active_ws_name = (type(m.activeWorkspace) == "table" and type(m.activeWorkspace.name) == "string")
                and m.activeWorkspace.name
                or nil
            out[#out + 1] = {
                id = tonumber(m.id),
                name = m.name,
                description = type(m.description) == "string" and m.description or "",
                width = tonumber(m.width) or 0,
                height = tonumber(m.height) or 0,
                x = tonumber(m.x) or 0,
                y = tonumber(m.y) or 0,
                refresh = tonumber(m.refreshRate) or 0,
                scale = tonumber(m.scale) or 1,
                disabled = m.disabled == true,
                focused = m.focused == true,
                mirror_of = mirror_of,
                active_workspace = active_ws,
                active_workspace_name = active_ws_name,
                backend = backend,
                virtual = M.is_virtual_monitor(m.name, { backend = backend, hardwareDetails = m.hardwareDetails }),
            }
        end
    end
    return out
end

local function is_internal_name(name)
    return name:match("^eDP%-") ~= nil or name:match("^LVDS%-") ~= nil or name:match("^DSI%-") ~= nil
end

function M.pick_roles(monitors)
    if type(monitors) ~= "table" or #monitors == 0 then
        return nil, {}, {}
    end
    local physical = {}
    local virtuals = {}
    for _, m in ipairs(monitors) do
        if M.is_virtual_monitor(m.name, m) then
            virtuals[#virtuals + 1] = m
        else
            physical[#physical + 1] = m
        end
    end
    if #physical == 0 then
        return nil, {}, virtuals
    end
    local internal = nil
    for _, m in ipairs(physical) do
        if is_internal_name(m.name) then
            internal = m
            break
        end
    end
    if not internal then
        internal = physical[1]
    end
    local externals = {}
    for _, m in ipairs(physical) do
        if m.name ~= internal.name then
            externals[#externals + 1] = m
        end
    end
    return internal, externals, virtuals
end

function M.parse_workspaces(ws_json, clients_json)
    local raw_ws = {}
    if type(ws_json) == "string" and ws_json:find("%S") then
        local ok, parsed = pcall(json.decode, ws_json)
        if ok and type(parsed) == "table" then
            raw_ws = parsed
        end
    end
    local raw_clients = {}
    if type(clients_json) == "string" and clients_json:find("%S") then
        local ok, parsed = pcall(json.decode, clients_json)
        if ok and type(parsed) == "table" then
            raw_clients = parsed
        end
    end

    local apps_by_ws = {}
    local seen_by_ws = {}
    for _, c in ipairs(raw_clients) do
        if type(c) == "table" then
            local ws_id = type(c.workspace) == "table" and tonumber(c.workspace.id) or nil
            if ws_id and ws_id >= 0 then
                local label = (type(c.class) == "string" and c.class ~= "" and c.class)
                    or (type(c.initialClass) == "string" and c.initialClass ~= "" and c.initialClass)
                    or (type(c.title) == "string" and c.title ~= "" and c.title)
                    or nil
                if label then
                    apps_by_ws[ws_id] = apps_by_ws[ws_id] or {}
                    seen_by_ws[ws_id] = seen_by_ws[ws_id] or {}
                    if not seen_by_ws[ws_id][label] and #apps_by_ws[ws_id] < 3 then
                        seen_by_ws[ws_id][label] = true
                        apps_by_ws[ws_id][#apps_by_ws[ws_id] + 1] = label
                    end
                end
            end
        end
    end

    local out = {}
    for _, w in ipairs(raw_ws) do
        if type(w) == "table" then
            local id = tonumber(w.id)
            if id and id >= 0 then
                out[#out + 1] = {
                    id = id,
                    name = type(w.name) == "string" and w.name or tostring(id),
                    monitor = type(w.monitor) == "string" and w.monitor or "",
                    windows = tonumber(w.windows) or 0,
                    apps = apps_by_ws[id] or {},
                }
            end
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

function M.pick_clean_workspace_id(workspaces)
    local used = {}
    for _, w in ipairs(workspaces or {}) do
        local id = type(w) == "table" and tonumber(w.id) or tonumber(w)
        if id and id > 0 then
            used[math.floor(id)] = true
        end
    end
    for _, candidate in ipairs({ 9, 8, 7, 6, 5, 4, 3, 2, 1, 10 }) do
        if not used[candidate] then
            return candidate
        end
    end
    local n = 11
    while used[n] do
        n = n + 1
    end
    return n
end

function M.format_workspace_entry(ws)
    local id = tonumber(ws and ws.id) or 0
    local apps = type(ws and ws.apps) == "table" and ws.apps or {}
    local windows = tonumber(ws and ws.windows) or 0
    local mon = type(ws and ws.monitor) == "string" and ws.monitor or ""
    if #apps > 0 then
        local loc = mon ~= "" and ("  (on " .. mon .. ")") or ""
        return string.format("WS %d  [%s]%s", id, table.concat(apps, ", "), loc)
    elseif windows > 0 then
        local loc = mon ~= "" and ("  (on " .. mon .. ")") or ""
        return string.format("WS %d  [%d %s]%s", id, windows, windows == 1 and "window" or "windows", loc)
    end
    return string.format("WS %d  [new empty workspace]", id)
end

function M.format_monitor(m)
    local state = m.disabled and "disabled" or (m.focused and "active*" or "active")
    local hz = m.refresh > 0 and string.format("@%.0fHz", m.refresh) or ""
    local geom = (m.width > 0 and m.height > 0) and string.format("%dx%d%s", m.width, m.height, hz) or "off"
    local tag = m.virtual and ", virtual" or ""
    return string.format("%s  (%s, %s%s)", m.name, geom, state, tag)
end

-- Returns { eval_cmds = { "hl.monitor({ ... })", ... }, needs_reload = bool, summary = "...", target_ext = ... } or nil, err
function M.plan(mode, monitors, opts)
    if type(monitors) ~= "table" or #monitors == 0 then
        return nil, "no monitors detected"
    end
    opts = opts or {}
    local internal, externals = M.pick_roles(monitors)
    if not internal then
        return nil, "no physical monitors detected"
    end

    local target_ext = externals[1]
    if type(opts.target) == "string" and opts.target ~= "" then
        target_ext = nil
        for _, ext in ipairs(externals) do
            if ext.name == opts.target then
                target_ext = ext
                break
            end
        end
        if not target_ext then
            return nil, "external monitor not found: " .. opts.target
        end
    end

    local mirror_active = opts.was_mirror == true
    if not mirror_active then
        for _, m in ipairs(monitors) do
            if is_mirror_active(m) then
                mirror_active = true
                break
            end
        end
    end
    local needs_reload = mirror_active and mode ~= "mirror"

    if mode == "auto" then
        local cmds = {}
        local phys = { internal }
        for _, ext in ipairs(externals) do
            phys[#phys + 1] = ext
        end
        for _, m in ipairs(phys) do
            cmds[#cmds + 1] = format_hl_monitor({
                output = m.name,
                mode = "preferred",
                position = "auto",
                scale = scale_num(m),
            })
        end
        return {
            eval_cmds = cmds,
            needs_reload = needs_reload,
            summary = "Reset all monitors to auto",
            target_ext = target_ext and target_ext.name or nil,
        }
    end

    if mode == "internal" then
        local cmds = {
            format_hl_monitor({
                output = internal.name,
                mode = "preferred",
                position = "0x0",
                scale = scale_num(internal),
            }),
        }
        for _, ext in ipairs(externals) do
            cmds[#cmds + 1] = format_hl_monitor({ output = ext.name, disabled = true })
        end
        return {
            eval_cmds = cmds,
            needs_reload = needs_reload,
            summary = "Internal only (" .. internal.name .. ")",
            target_ext = nil,
        }
    end

    if mode == "virtual-share" then
        local cmds = {
            format_hl_monitor({
                output = internal.name,
                mode = "preferred",
                position = "0x0",
                scale = scale_num(internal),
            }),
            format_hl_monitor({
                output = "kaze-share",
                mode = "1920x1080@60",
                position = "9999x0",
                scale = 1,
            }),
        }
        return {
            eval_cmds = cmds,
            needs_reload = needs_reload,
            summary = "Virtual Share 1080p (kaze-share)",
            target_ext = nil,
        }
    end

    if not target_ext then
        return nil, "no external monitor connected"
    end

    local function ordered_externals()
        local list = { target_ext }
        for _, ext in ipairs(externals) do
            if ext.name ~= target_ext.name then
                list[#list + 1] = ext
            end
        end
        return list
    end

    if mode == "external" then
        local cmds = {}
        for _, ext in ipairs(ordered_externals()) do
            cmds[#cmds + 1] = format_hl_monitor({
                output = ext.name,
                mode = "preferred",
                position = "auto",
                scale = scale_num(ext),
            })
        end
        cmds[#cmds + 1] = format_hl_monitor({ output = internal.name, disabled = true })
        return {
            eval_cmds = cmds,
            needs_reload = needs_reload,
            summary = "External only (" .. target_ext.name .. ")",
            target_ext = target_ext.name,
        }
    elseif mode == "extend-right" or mode == "present" or mode == "mirror-scaled" then
        local cmds = {
            format_hl_monitor({
                output = internal.name,
                mode = "preferred",
                position = "0x0",
                scale = scale_num(internal),
            }),
        }
        for _, ext in ipairs(ordered_externals()) do
            cmds[#cmds + 1] = format_hl_monitor({
                output = ext.name,
                mode = "preferred",
                position = "auto-right",
                scale = scale_num(ext),
            })
        end
        local summary = "Extend right (" .. internal.name .. " -> " .. target_ext.name .. ")"
        if mode == "present" then
            summary = "Presenting on " .. target_ext.name
        elseif mode == "mirror-scaled" then
            summary = "Scaled mirror (" .. target_ext.name .. " <- " .. internal.name .. ")"
        end
        return {
            eval_cmds = cmds,
            needs_reload = needs_reload,
            summary = summary,
            target_ext = target_ext.name,
        }
    elseif mode == "extend-left" then
        local cmds = {
            format_hl_monitor({
                output = internal.name,
                mode = "preferred",
                position = "0x0",
                scale = scale_num(internal),
            }),
        }
        for _, ext in ipairs(ordered_externals()) do
            cmds[#cmds + 1] = format_hl_monitor({
                output = ext.name,
                mode = "preferred",
                position = "auto-left",
                scale = scale_num(ext),
            })
        end
        return {
            eval_cmds = cmds,
            needs_reload = needs_reload,
            summary = "Extend left (" .. target_ext.name .. " <- " .. internal.name .. ")",
            target_ext = target_ext.name,
        }
    elseif mode == "extend-up" then
        local cmds = {
            format_hl_monitor({
                output = internal.name,
                mode = "preferred",
                position = "0x0",
                scale = scale_num(internal),
            }),
        }
        for _, ext in ipairs(ordered_externals()) do
            cmds[#cmds + 1] = format_hl_monitor({
                output = ext.name,
                mode = "preferred",
                position = "auto-up",
                scale = scale_num(ext),
            })
        end
        return {
            eval_cmds = cmds,
            needs_reload = needs_reload,
            summary = "Extend above (" .. target_ext.name .. " above " .. internal.name .. ")",
            target_ext = target_ext.name,
        }
    elseif mode == "mirror" then
        local cmds = {
            format_hl_monitor({
                output = internal.name,
                mode = "preferred",
                position = "0x0",
                scale = scale_num(internal),
            }),
        }
        for _, ext in ipairs(ordered_externals()) do
            cmds[#cmds + 1] = format_hl_monitor({
                output = ext.name,
                mode = "preferred",
                position = "auto",
                scale = scale_num(ext),
                mirror = internal.name,
            })
        end
        return {
            eval_cmds = cmds,
            needs_reload = false,
            summary = "Mirror (" .. target_ext.name .. " = " .. internal.name .. ")",
            target_ext = target_ext.name,
        }
    end

    return nil, "unknown display mode: " .. tostring(mode)
end

-- Safety rules

function M.should_ignore_hotplug(mon_name, ctx)
    if type(mon_name) ~= "string" or mon_name == "" or M.is_virtual_monitor(mon_name) then
        return true, "virtual"
    end
    ctx = type(ctx) == "table" and ctx or {}
    if ctx.enabled == false then
        return true, "disabled"
    end
    if ctx.locked == true then
        return true, "locked"
    end
    if type(ctx.now) == "number" and type(ctx.started_at) == "number" and (ctx.now - ctx.started_at) < 5 then
        return true, "startup"
    end
    if type(ctx.now) == "number" and type(ctx.last_event_at) == "number" and (ctx.now - ctx.last_event_at) < 1 then
        return true, "debounce"
    end
    return false, nil
end

function M.should_restore_dnd(state)
    return type(state) == "table" and state.dnd_managed == true and state.dnd_was_active == false
end

function M.plan_disconnect_recovery(removed_name, monitors, state)
    if type(removed_name) ~= "string" or removed_name == "" or M.is_virtual_monitor(removed_name) then
        return {
            ignored = true,
            eval_cmds = {},
            needs_reload = false,
            recover_internal = false,
            clear_present = false,
            cleanup_mirror = false,
            restore_bar = false,
            restore_dnd = false,
        }
    end

    state = type(state) == "table" and state or {}
    local remaining = {}
    for _, m in ipairs(monitors or {}) do
        if m.name ~= removed_name and not M.is_virtual_monitor(m.name, m) then
            remaining[#remaining + 1] = m
        end
    end

    local internal, externals = M.pick_roles(remaining)
    local any_enabled = false
    for _, m in ipairs(remaining) do
        if not m.disabled then
            any_enabled = true
            break
        end
    end

    local matches_ext = state.external_monitor == removed_name
    local was_mirror = state.mode == "mirror"
    if not was_mirror then
        for _, m in ipairs(remaining) do
            if is_mirror_active(m) then
                was_mirror = true
                break
            end
        end
    end

    local eval_cmds = {}
    local recover_internal = false
    if internal and (not any_enabled or (internal.disabled and (matches_ext or state.mode == "external" or #externals == 0))) then
        recover_internal = true
        eval_cmds[#eval_cmds + 1] = format_hl_monitor({
            output = internal.name,
            mode = "preferred",
            position = "0x0",
            scale = scale_num(internal),
        })
    end

    local cleanup_mirror = (matches_ext or state.mirror_pid ~= nil)
        and (state.mode == "mirror" or state.mode == "mirror-scaled" or state.mirror_pid ~= nil)
    local clear_present = (matches_ext or state.present_workspace ~= nil)
        and (state.mode == "present" or state.present_workspace ~= nil)
    local restore_bar = type(state.bar_hidden_monitors) == "table" and #state.bar_hidden_monitors > 0
        and (matches_ext or state.mode == "present" or state.mode == "mirror-scaled")
    local restore_dnd = M.should_restore_dnd(state)
        and (matches_ext or clear_present or cleanup_mirror)

    return {
        ignored = false,
        eval_cmds = eval_cmds,
        needs_reload = was_mirror,
        recover_internal = recover_internal,
        internal_name = internal and internal.name or nil,
        clear_present = clear_present,
        cleanup_mirror = cleanup_mirror,
        restore_bar = restore_bar,
        restore_dnd = restore_dnd,
    }
end

return M
