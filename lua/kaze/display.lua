-- Pure-Lua monitor parser and layout planner for `kaze-display` (0 I/O).
local M = {}

local json = require("kaze.json")

local function fmt_scale(m)
    local s = tonumber(m and m.scale) or 1
    if s <= 0 then s = 1 end
    if s % 1 == 0 then
        return tostring(math.floor(s))
    else
        return tostring(s)
    end
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
            rules[#rules + 1] = m.name .. ",preferred,auto," .. fmt_scale(m)
        end
        return { rules = rules, summary = "Reset all monitors to auto" }
    end

    if mode == "internal" then
        local rules = { internal.name .. ",preferred,0x0," .. fmt_scale(internal) }
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
            rules[#rules + 1] = ext.name .. ",preferred,auto," .. fmt_scale(ext)
        end
        rules[#rules + 1] = internal.name .. ",disable"
        return { rules = rules, summary = "External only (" .. primary_ext.name .. ")" }
    elseif mode == "extend-right" then
        local rules = { internal.name .. ",preferred,0x0," .. fmt_scale(internal) }
        for _, ext in ipairs(externals) do
            rules[#rules + 1] = ext.name .. ",preferred,auto-right," .. fmt_scale(ext)
        end
        return { rules = rules, summary = "Extend right (" .. internal.name .. " -> " .. primary_ext.name .. ")" }
    elseif mode == "extend-left" then
        local rules = { internal.name .. ",preferred,0x0," .. fmt_scale(internal) }
        for _, ext in ipairs(externals) do
            rules[#rules + 1] = ext.name .. ",preferred,auto-left," .. fmt_scale(ext)
        end
        return { rules = rules, summary = "Extend left (" .. primary_ext.name .. " <- " .. internal.name .. ")" }
    elseif mode == "extend-up" then
        local rules = { internal.name .. ",preferred,0x0," .. fmt_scale(internal) }
        for _, ext in ipairs(externals) do
            rules[#rules + 1] = ext.name .. ",preferred,auto-up," .. fmt_scale(ext)
        end
        return { rules = rules, summary = "Extend above (" .. primary_ext.name .. " above " .. internal.name .. ")" }
    elseif mode == "mirror" then
        local rules = { internal.name .. ",preferred,0x0," .. fmt_scale(internal) }
        for _, ext in ipairs(externals) do
            rules[#rules + 1] = ext.name .. ",preferred,auto," .. fmt_scale(ext) .. ",mirror," .. internal.name
        end
        return { rules = rules, summary = "Mirror (" .. primary_ext.name .. " -> " .. internal.name .. ")" }
    end

    return nil, "unknown display mode: " .. tostring(mode)
end

return M
