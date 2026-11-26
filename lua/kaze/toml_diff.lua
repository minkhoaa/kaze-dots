-- Pure-Lua TOML section/key/list drift checker for Noctalia config.toml.
-- Zero I/O: compares repo default template against a user's editable config.toml
-- to surface newly added upstream sections, keys, and default bar/template items
-- without flagging intentional user value edits.

local M = {}

local LIST_DIFF_KEYS = {
    ["bar.default"] = { start = true, center = true, ["end"] = true },
    ["theme.templates"] = { builtin_ids = true },
}

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function strip_comment(line)
    local in_double = false
    local in_single = false
    local escaped = false
    for i = 1, #line do
        local ch = line:sub(i, i)
        if in_double then
            if escaped then
                escaped = false
            elseif ch == "\\" then
                escaped = true
            elseif ch == '"' then
                in_double = false
            end
        elseif in_single then
            if ch == "'" then
                in_single = false
            end
        else
            if ch == '"' then
                in_double = true
            elseif ch == "'" then
                in_single = true
            elseif ch == "#" then
                return line:sub(1, i - 1)
            end
        end
    end
    return line
end

local function bracket_delta(s)
    local delta = 0
    local in_double = false
    local in_single = false
    local escaped = false
    for i = 1, #s do
        local ch = s:sub(i, i)
        if in_double then
            if escaped then
                escaped = false
            elseif ch == "\\" then
                escaped = true
            elseif ch == '"' then
                in_double = false
            end
        elseif in_single then
            if ch == "'" then
                in_single = false
            end
        else
            if ch == '"' then
                in_double = true
            elseif ch == "'" then
                in_single = true
            elseif ch == "[" then
                delta = delta + 1
            elseif ch == "]" then
                delta = delta - 1
            end
        end
    end
    return delta
end

function M.parse_string_array(val)
    if type(val) ~= "string" then
        return nil
    end
    local s = trim(val)
    if s:sub(1, 1) ~= "[" or s:sub(-1) ~= "]" then
        return nil
    end
    local inner = s:sub(2, -2)
    local items = {}
    local i = 1
    local n = #inner
    while i <= n do
        local ch = inner:sub(i, i)
        if ch:match("[%s,]") then
            i = i + 1
        elseif ch == '"' then
            local j = i + 1
            local buf = {}
            local closed = false
            while j <= n do
                local c = inner:sub(j, j)
                if c == "\\" and j < n then
                    buf[#buf + 1] = inner:sub(j + 1, j + 1)
                    j = j + 2
                elseif c == '"' then
                    closed = true
                    j = j + 1
                    break
                else
                    buf[#buf + 1] = c
                    j = j + 1
                end
            end
            if not closed then
                return nil
            end
            items[#items + 1] = table.concat(buf)
            i = j
        elseif ch == "'" then
            local close_pos = inner:find("'", i + 1, true)
            if not close_pos then
                return nil
            end
            items[#items + 1] = inner:sub(i + 1, close_pos - 1)
            i = close_pos + 1
        else
            return nil
        end
    end
    return items
end

function M.parse(text)
    local sections = {}
    local section_order = {}
    local current_name = ""
    local current = {
        name = "",
        is_array = false,
        keys = {},
        key_order = {},
        raw_lines = {},
    }
    sections[""] = current

    local function ensure_section(name, is_array)
        local sec = sections[name]
        if not sec then
            sec = {
                name = name,
                is_array = is_array,
                keys = {},
                key_order = {},
                raw_lines = {},
            }
            sections[name] = sec
            section_order[#section_order + 1] = name
        end
        return sec
    end

    local pending_key = nil
    local pending_val = nil
    local pending_depth = 0

    for raw_line in (tostring(text or "") .. "\n"):gmatch("(.-)\r?\n") do
        local clean = trim(strip_comment(raw_line))
        if pending_key then
            if clean ~= "" then
                pending_val = pending_val .. " " .. clean
                pending_depth = pending_depth + bracket_delta(clean)
                if current.name ~= "" then
                    current.raw_lines[#current.raw_lines + 1] = raw_line
                end
            end
            if pending_depth <= 0 then
                if not current.is_array then
                    if current.keys[pending_key] == nil then
                        current.key_order[#current.key_order + 1] = pending_key
                    end
                    current.keys[pending_key] = trim(pending_val)
                end
                pending_key = nil
                pending_val = nil
                pending_depth = 0
            end
        elseif clean == "" then
            -- ignore blank/comment lines
        elseif clean:sub(1, 2) == "[[" and clean:sub(-2) == "]]" then
            local name = trim(clean:sub(3, -3))
            current_name = "[[" .. name .. "]]"
            current = ensure_section(current_name, true)
            current.raw_lines[#current.raw_lines + 1] = raw_line
        elseif clean:sub(1, 1) == "[" and clean:sub(-1) == "]" then
            local name = trim(clean:sub(2, -2))
            current_name = name
            current = ensure_section(current_name, false)
            current.raw_lines[#current.raw_lines + 1] = raw_line
        else
            local eq = clean:find("=", 1, true)
            if eq then
                local k = trim(clean:sub(1, eq - 1))
                local v = trim(clean:sub(eq + 1))
                if current.name ~= "" then
                    current.raw_lines[#current.raw_lines + 1] = raw_line
                end
                local depth = bracket_delta(v)
                if depth > 0 then
                    pending_key = k
                    pending_val = v
                    pending_depth = depth
                elseif not current.is_array and k ~= "" then
                    if current.keys[k] == nil then
                        current.key_order[#current.key_order + 1] = k
                    end
                    current.keys[k] = v
                end
            end
        end
    end

    if pending_key and not current.is_array then
        if current.keys[pending_key] == nil then
            current.key_order[#current.key_order + 1] = pending_key
        end
        current.keys[pending_key] = trim(pending_val)
    end

    return {
        sections = sections,
        section_order = section_order,
    }
end

function M.diff(template_text, user_text)
    local tpl = M.parse(template_text)
    local usr = M.parse(user_text)

    local missing_sections = {}
    local missing_keys = {}
    local missing_list_items = {}

    -- Top-level keys (outside any [section])
    local tpl_root = tpl.sections[""]
    local usr_root = usr.sections[""]
    for _, k in ipairs(tpl_root.key_order) do
        if usr_root.keys[k] == nil then
            missing_keys[#missing_keys + 1] = {
                section = "",
                key = k,
                default = tpl_root.keys[k],
            }
        end
    end

    for _, sec_name in ipairs(tpl.section_order) do
        local tpl_sec = tpl.sections[sec_name]
        local usr_sec = usr.sections[sec_name]
        if not usr_sec then
            missing_sections[#missing_sections + 1] = {
                name = sec_name,
                is_array = tpl_sec.is_array,
                snippet = table.concat(tpl_sec.raw_lines, "\n"),
            }
        elseif not tpl_sec.is_array then
            for _, k in ipairs(tpl_sec.key_order) do
                local tpl_val = tpl_sec.keys[k]
                local usr_val = usr_sec.keys[k]
                if usr_val == nil then
                    missing_keys[#missing_keys + 1] = {
                        section = sec_name,
                        key = k,
                        default = tpl_val,
                    }
                elseif LIST_DIFF_KEYS[sec_name] and LIST_DIFF_KEYS[sec_name][k] then
                    local tpl_items = M.parse_string_array(tpl_val)
                    local usr_items = M.parse_string_array(usr_val)
                    if tpl_items and usr_items then
                        local have = {}
                        for _, item in ipairs(usr_items) do
                            have[item] = true
                        end
                        local missing = {}
                        for _, item in ipairs(tpl_items) do
                            if not have[item] then
                                missing[#missing + 1] = item
                            end
                        end
                        if #missing > 0 then
                            missing_list_items[#missing_list_items + 1] = {
                                section = sec_name,
                                key = k,
                                missing = missing,
                                default = tpl_val,
                            }
                        end
                    end
                end
            end
        end
    end

    local has_drift = (#missing_sections > 0) or (#missing_keys > 0) or (#missing_list_items > 0)
    return {
        has_drift = has_drift,
        missing_sections = missing_sections,
        missing_keys = missing_keys,
        missing_list_items = missing_list_items,
    }
end

function M.summary_counts(result)
    local item_count = 0
    for _, entry in ipairs(result.missing_list_items or {}) do
        item_count = item_count + #(entry.missing or {})
    end
    return #(result.missing_sections or {}), #(result.missing_keys or {}), item_count
end

function M.format_report(result, opts)
    opts = opts or {}
    local lines = {}
    if opts.user_path then
        lines[#lines + 1] = "User config:   " .. opts.user_path
    end
    if opts.template_path then
        lines[#lines + 1] = "Repo template: " .. opts.template_path
    end

    local sec_n, key_n, item_n = M.summary_counts(result)
    if not result.has_drift then
        lines[#lines + 1] = "Status: up to date (0 missing sections, 0 missing keys, 0 missing list items)."
        lines[#lines + 1] = "Note: user value edits made in Noctalia Settings GUI are intentionally preserved."
        return table.concat(lines, "\n") .. "\n"
    end

    lines[#lines + 1] = string.format(
        "Status: drift detected (%d missing section(s), %d missing key(s), %d missing list item(s)).",
        sec_n, key_n, item_n
    )

    if sec_n > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Missing sections (copy any you want into your config.toml):"
        for _, sec in ipairs(result.missing_sections) do
            lines[#lines + 1] = ""
            lines[#lines + 1] = sec.snippet
        end
    end

    if key_n > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Missing keys in existing sections:"
        for _, entry in ipairs(result.missing_keys) do
            local header = entry.section ~= "" and ("[" .. entry.section .. "] ") or ""
            lines[#lines + 1] = string.format("  %s%s = %s", header, entry.key, entry.default)
        end
    end

    if #result.missing_list_items > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "New default list items not present in your config:"
        for _, entry in ipairs(result.missing_list_items) do
            local quoted = {}
            for _, item in ipairs(entry.missing) do
                quoted[#quoted + 1] = string.format("%q", item)
            end
            lines[#lines + 1] = string.format(
                "  [%s] %s: missing %s",
                entry.section,
                entry.key,
                table.concat(quoted, ", ")
            )
        end
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "After merging desired changes, reload live with: noctalia msg config-reload"
    return table.concat(lines, "\n") .. "\n"
end

return M
