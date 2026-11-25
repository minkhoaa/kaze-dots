-- Pure-Lua monitor parser and layout planner for `kaze-display` (0 I/O).
local M = {}

local function parse_string(src, pos)
    local out = {}
    local i = pos + 1
    local len = #src
    while i <= len do
        local c = src:sub(i, i)
        if c == '"' then
            return table.concat(out), i + 1
        elseif c == "\\" then
            local nxt = src:sub(i + 1, i + 1)
            local escapes = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", n = "\n", r = "\r", t = "\t" }
            if escapes[nxt] then
                out[#out + 1] = escapes[nxt]
                i = i + 2
            elseif nxt == "u" then
                out[#out + 1] = "?"
                i = i + 6
            else
                out[#out + 1] = nxt
                i = i + 2
            end
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return nil, i
end

local function skip_ws(src, i)
    while i <= #src and src:sub(i, i):match("%s") do
        i = i + 1
    end
    return i
end

local function parse_value(src, i)
    i = skip_ws(src, i)
    local c = src:sub(i, i)
    if c == '"' then
        return parse_string(src, i)
    elseif c == "{" then
        local obj = {}
        i = skip_ws(src, i + 1)
        if src:sub(i, i) == "}" then
            return obj, i + 1
        end
        while i <= #src do
            i = skip_ws(src, i)
            if src:sub(i, i) ~= '"' then
                return nil, i
            end
            local key
            key, i = parse_string(src, i)
            if not key then return nil, i end
            i = skip_ws(src, i)
            if src:sub(i, i) ~= ":" then return nil, i end
            local val
            val, i = parse_value(src, i + 1)
            obj[key] = val
            i = skip_ws(src, i)
            local sep = src:sub(i, i)
            if sep == "," then
                i = i + 1
            elseif sep == "}" then
                return obj, i + 1
            else
                return nil, i
            end
        end
        return nil, i
    elseif c == "[" then
        local arr = {}
        i = skip_ws(src, i + 1)
        if src:sub(i, i) == "]" then
            return arr, i + 1
        end
        while i <= #src do
            local val
            val, i = parse_value(src, i)
            arr[#arr + 1] = val
            i = skip_ws(src, i)
            local sep = src:sub(i, i)
            if sep == "," then
                i = i + 1
            elseif sep == "]" then
                return arr, i + 1
            else
                return nil, i
            end
        end
        return nil, i
    elseif src:sub(i, i + 3) == "true" then
        return true, i + 4
    elseif src:sub(i, i + 4) == "false" then
        return false, i + 5
    elseif src:sub(i, i + 3) == "null" then
        return nil, i + 4
    else
        local num_str = src:match("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
        if num_str and #num_str > 0 then
            return tonumber(num_str), i + #num_str
        end
        return nil, i + 1
    end
end

function M.parse_monitors(json_str)
    if type(json_str) ~= "string" or not json_str:find("%S") then
        return {}
    end
    local parsed = parse_value(json_str, 1)
    if type(parsed) ~= "table" then
        return {}
    end
    local out = {}
    for _, m in ipairs(parsed) do
        if type(m) == "table" and type(m.name) == "string" and m.name ~= "" then
            out[#out + 1] = {
                name = m.name,
                description = type(m.description) == "string" and m.description or "",
                width = tonumber(m.width) or 0,
                height = tonumber(m.height) or 0,
                refresh = tonumber(m.refreshRate) or 0,
                scale = tonumber(m.scale) or 1,
                disabled = m.disabled == true,
                focused = m.focused == true,
            }
        end
    end
    return out
end

local function is_internal_name(name)
    return name:match("^eDP%-") ~= nil or name:match("^LVDS%-") ~= nil or name:match("^DSI%-") ~= nil
end

function M.pick_roles(monitors)
    if #monitors == 0 then
        return nil, {}
    end
    local internal = nil
    for _, m in ipairs(monitors) do
        if is_internal_name(m.name) then
            internal = m
            break
        end
    end
    if not internal then
        internal = monitors[1]
    end
    local externals = {}
    for _, m in ipairs(monitors) do
        if m.name ~= internal.name then
            externals[#externals + 1] = m
        end
    end
    return internal, externals
end

function M.format_monitor(m)
    local state = m.disabled and "disabled" or (m.focused and "active*" or "active")
    local hz = m.refresh > 0 and string.format("@%.0fHz", m.refresh) or ""
    local geom = (m.width > 0 and m.height > 0) and string.format("%dx%d%s", m.width, m.height, hz) or "off"
    return string.format("%s  (%s, %s)", m.name, geom, state)
end

-- Returns { rules = { "<hyprctl monitor spec>", ... }, summary = "..." } or nil, err
function M.plan(mode, monitors)
    if type(monitors) ~= "table" or #monitors == 0 then
        return nil, "no monitors detected"
    end
    local internal, externals = M.pick_roles(monitors)
    local primary_ext = externals[1]

    if mode == "auto" then
        local rules = {}
        for _, m in ipairs(monitors) do
            rules[#rules + 1] = m.name .. ",preferred,auto,1"
        end
        return { rules = rules, summary = "Reset all monitors to auto" }
    end

    if mode == "internal" then
        local rules = { internal.name .. ",preferred,0x0,1" }
        for _, ext in ipairs(externals) do
            rules[#rules + 1] = ext.name .. ",disable"
        end
        return { rules = rules, summary = "Internal only (" .. internal.name .. ")" }
    end

    if not primary_ext then
        return nil, "no external monitor connected"
    end

    if mode == "external" then
        local rules = {}
        for _, ext in ipairs(externals) do
            rules[#rules + 1] = ext.name .. ",preferred,auto,1"
        end
        rules[#rules + 1] = internal.name .. ",disable"
        return { rules = rules, summary = "External only (" .. primary_ext.name .. ")" }
    elseif mode == "extend-right" then
        local rules = { internal.name .. ",preferred,0x0,1" }
        for _, ext in ipairs(externals) do
            rules[#rules + 1] = ext.name .. ",preferred,auto-right,1"
        end
        return { rules = rules, summary = "Extend right (" .. internal.name .. " -> " .. primary_ext.name .. ")" }
    elseif mode == "extend-left" then
        local rules = { internal.name .. ",preferred,0x0,1" }
        for _, ext in ipairs(externals) do
            rules[#rules + 1] = ext.name .. ",preferred,auto-left,1"
        end
        return { rules = rules, summary = "Extend left (" .. primary_ext.name .. " <- " .. internal.name .. ")" }
    elseif mode == "extend-up" then
        local rules = { internal.name .. ",preferred,0x0,1" }
        for _, ext in ipairs(externals) do
            rules[#rules + 1] = ext.name .. ",preferred,auto-up,1"
        end
        return { rules = rules, summary = "Extend above (" .. primary_ext.name .. " above " .. internal.name .. ")" }
    elseif mode == "mirror" then
        local rules = { internal.name .. ",preferred,0x0,1" }
        for _, ext in ipairs(externals) do
            rules[#rules + 1] = ext.name .. ",preferred,auto,1,mirror," .. internal.name
        end
        return { rules = rules, summary = "Mirror (" .. primary_ext.name .. " -> " .. internal.name .. ")" }
    end

    return nil, "unknown display mode: " .. tostring(mode)
end

return M
