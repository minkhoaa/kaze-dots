local fs = require("kaze.fs")

local M = {}

M.DEFAULT = "dynamic-island"

M.ORDER = {
    "dynamic-island",
    "omarchy-rail",
    "floating-islands",
    "concave-notch",
}

local INT_KEYS = {
    thickness = true,
    padding = true,
    widget_spacing = true,
    margin_edge = true,
    margin_ends = true,
    margin_opposite_edge = true,
    radius = true,
    radius_top_left = true,
    radius_top_right = true,
    radius_bottom_left = true,
    radius_bottom_right = true,
    capsule_radius = true,
    offset_x = true,
    offset_y = true,
}

local FLOAT_KEYS = {
    corner_radius_scale = true,
    border_width = true,
    background_opacity = true,
    capsule_border_width = true,
    opacity = true,
}

local CAP_FLOAT_KEYS = {
    border_width = true,
    padding = true,
    widget_spacing = true,
    opacity = true,
}

local CAP_INT_KEYS = {
    radius = true,
    accordion_duration = true,
    accordion_delay_ms = true,
}

M.PRESETS = {
    ["omarchy-rail"] = {
        id = "omarchy-rail",
        title = "Omarchy Rail",
        summary = "Left vertical 42px bar, 0px sharp corners, 2px borders",
        shell = {
            order = { "corner_radius_scale", "button_borders", "card_borders", "input_borders", "popup_borders", "popup_shadows" },
            values = {
                corner_radius_scale = 0.0,
                button_borders = true,
                card_borders = true,
                input_borders = true,
                popup_borders = true,
                popup_shadows = false,
            },
        },
        shell_panel = {
            order = { "borders", "border_width", "shadow" },
            values = {
                borders = true,
                border_width = 2.0,
                shadow = false,
            },
        },
        bar_default = {
            order = {
                "position", "thickness", "padding", "widget_spacing",
                "margin_edge", "margin_ends", "margin_opposite_edge",
                "background_opacity", "compositor_blur", "border", "border_width",
                "radius", "radius_top_left", "radius_top_right", "radius_bottom_left", "radius_bottom_right",
                "concave_edge_corners", "shadow", "contact_shadow", "capsule", "capsule_border_width",
                "start", "center", "end",
            },
            values = {
                position = "left",
                thickness = 42,
                padding = 6,
                widget_spacing = 6,
                margin_edge = 8,
                margin_ends = 8,
                margin_opposite_edge = 0,
                background_opacity = 0.94,
                compositor_blur = true,
                border = "outline_variant",
                border_width = 2.0,
                radius = 0,
                radius_top_left = 0,
                radius_top_right = 0,
                radius_bottom_left = 0,
                radius_bottom_right = 0,
                concave_edge_corners = false,
                shadow = false,
                contact_shadow = false,
                capsule = false,
                capsule_border_width = 1.0,
                start = { "launcher", "ws" },
                center = { "vclock" },
                ["end"] = { "record", "tray", "display", "mirror", "net", "vol", "bat", "notifications", "control-center", "session" },
            },
        },
        capsule_groups = {},
        widget_ws = {
            order = { "style", "capsule_radius" },
            values = {
                style = "regular",
                capsule_radius = 0,
            },
        },
        notification = {
            order = { "position", "border", "border_width", "offset_x", "offset_y" },
            values = {
                position = "top_right",
                border = true,
                border_width = 2.0,
                offset_x = 12,
                offset_y = 12,
            },
        },
        osd = {
            order = { "position", "border", "border_width", "offset_x", "offset_y" },
            values = {
                position = "top_right",
                border = true,
                border_width = 2.0,
                offset_x = 12,
                offset_y = 12,
            },
        },
    },
    ["floating-islands"] = {
        id = "floating-islands",
        title = "Floating Islands",
        summary = "Transparent top bar with 3 independent capsule_group islands",
        shell = {
            order = { "corner_radius_scale", "button_borders", "card_borders", "input_borders", "popup_borders", "popup_shadows" },
            values = {
                corner_radius_scale = 1.0,
                button_borders = true,
                card_borders = true,
                input_borders = true,
                popup_borders = true,
                popup_shadows = false,
            },
        },
        shell_panel = {
            order = { "borders", "border_width", "shadow" },
            values = {
                borders = true,
                border_width = 1.5,
                shadow = false,
            },
        },
        bar_default = {
            order = {
                "position", "thickness", "padding", "widget_spacing",
                "margin_edge", "margin_ends", "margin_opposite_edge",
                "background_opacity", "compositor_blur", "border", "border_width",
                "radius", "radius_top_left", "radius_top_right", "radius_bottom_left", "radius_bottom_right",
                "concave_edge_corners", "shadow", "contact_shadow", "capsule", "capsule_border_width",
                "start", "center", "end",
            },
            values = {
                position = "top",
                thickness = 40,
                padding = 4,
                widget_spacing = 8,
                margin_edge = 8,
                margin_ends = 12,
                margin_opposite_edge = 0,
                background_opacity = 0.0,
                compositor_blur = false,
                border = "outline_variant",
                border_width = 0.0,
                radius = 0,
                radius_top_left = 0,
                radius_top_right = 0,
                radius_bottom_left = 0,
                radius_bottom_right = 0,
                concave_edge_corners = false,
                shadow = false,
                contact_shadow = false,
                capsule = false,
                capsule_border_width = 1.0,
                start = { "group:left" },
                center = { "group:center" },
                ["end"] = { "group:right" },
            },
        },
        capsule_groups = {
            {
                id = "left",
                members = { "launcher", "ws" },
                fill = "surface_container",
                border = "outline_variant",
                border_width = 1.5,
                radius = 14,
                padding = 6.0,
                widget_spacing = 6.0,
                opacity = 0.94,
            },
            {
                id = "center",
                members = { "hclock", "media" },
                fill = "surface_container",
                border = "outline_variant",
                border_width = 1.5,
                radius = 14,
                padding = 8.0,
                widget_spacing = 8.0,
                opacity = 0.94,
            },
            {
                id = "right",
                members = { "record", "tray", "display", "mirror", "net", "vol", "bat", "notifications", "control-center", "session" },
                fill = "surface_container",
                border = "outline_variant",
                border_width = 1.5,
                radius = 14,
                padding = 6.0,
                widget_spacing = 6.0,
                opacity = 0.94,
            },
        },
        widget_ws = {
            order = { "style", "capsule_radius" },
            values = {
                style = "regular",
                capsule_radius = 10,
            },
        },
        notification = {
            order = { "position", "border", "border_width", "offset_x", "offset_y" },
            values = {
                position = "top_right",
                border = true,
                border_width = 1.5,
                offset_x = 12,
                offset_y = 12,
            },
        },
        osd = {
            order = { "position", "border", "border_width", "offset_x", "offset_y" },
            values = {
                position = "top_right",
                border = true,
                border_width = 1.5,
                offset_x = 12,
                offset_y = 12,
            },
        },
    },
    ["concave-notch"] = {
        id = "concave-notch",
        title = "Concave Notch",
        summary = "Flush top bar (margin_edge=0) with Caelestia concave corners",
        shell = {
            order = { "corner_radius_scale", "button_borders", "card_borders", "input_borders", "popup_borders", "popup_shadows" },
            values = {
                corner_radius_scale = 1.0,
                button_borders = true,
                card_borders = true,
                input_borders = true,
                popup_borders = true,
                popup_shadows = false,
            },
        },
        shell_panel = {
            order = { "borders", "border_width", "shadow" },
            values = {
                borders = true,
                border_width = 1.5,
                shadow = false,
            },
        },
        bar_default = {
            order = {
                "position", "thickness", "padding", "widget_spacing",
                "margin_edge", "margin_ends", "margin_opposite_edge",
                "background_opacity", "compositor_blur", "border", "border_width",
                "radius", "radius_top_left", "radius_top_right", "radius_bottom_left", "radius_bottom_right",
                "concave_edge_corners", "shadow", "contact_shadow", "capsule", "capsule_border_width",
                "start", "center", "end",
            },
            values = {
                position = "top",
                thickness = 38,
                padding = 12,
                widget_spacing = 8,
                margin_edge = 0,
                margin_ends = 120,
                margin_opposite_edge = 0,
                background_opacity = 0.96,
                compositor_blur = true,
                border = "outline_variant",
                border_width = 0.0,
                radius = 16,
                radius_top_left = 0,
                radius_top_right = 0,
                radius_bottom_left = 16,
                radius_bottom_right = 16,
                concave_edge_corners = true,
                shadow = false,
                contact_shadow = false,
                capsule = false,
                capsule_border_width = 1.0,
                start = { "launcher", "ws" },
                center = { "hclock" },
                ["end"] = { "record", "tray", "display", "mirror", "net", "vol", "bat", "notifications", "control-center", "session" },
            },
        },
        capsule_groups = {},
        widget_ws = {
            order = { "style", "capsule_radius" },
            values = {
                style = "regular",
                capsule_radius = 10,
            },
        },
        notification = {
            order = { "position", "border", "border_width", "offset_x", "offset_y" },
            values = {
                position = "top_right",
                border = true,
                border_width = 1.5,
                offset_x = 12,
                offset_y = 12,
            },
        },
        osd = {
            order = { "position", "border", "border_width", "offset_x", "offset_y" },
            values = {
                position = "top_right",
                border = true,
                border_width = 1.5,
                offset_x = 12,
                offset_y = 12,
            },
        },
    },
    ["dynamic-island"] = {
        id = "dynamic-island",
        title = "Dynamic Island",
        badge = "Default",
        summary = "3 top islands + hover-expanding center Dynamic Island (accordion)",
        note = "Hover the center island to expand media, clipboard, screenshot, record, display, mirror & wallpaper utilities natively (0 extra RAM).",
        shell = {
            order = { "corner_radius_scale", "button_borders", "card_borders", "input_borders", "popup_borders", "popup_shadows" },
            values = {
                corner_radius_scale = 1.0,
                button_borders = true,
                card_borders = true,
                input_borders = true,
                popup_borders = true,
                popup_shadows = false,
            },
        },
        shell_panel = {
            order = { "borders", "border_width", "shadow" },
            values = {
                borders = true,
                border_width = 1.5,
                shadow = false,
            },
        },
        bar_default = {
            order = {
                "position", "thickness", "padding", "widget_spacing",
                "margin_edge", "margin_ends", "margin_opposite_edge",
                "background_opacity", "compositor_blur", "border", "border_width",
                "radius", "radius_top_left", "radius_top_right", "radius_bottom_left", "radius_bottom_right",
                "concave_edge_corners", "shadow", "contact_shadow", "capsule", "capsule_border_width",
                "start", "center", "end",
            },
            values = {
                position = "top",
                thickness = 38,
                padding = 4,
                widget_spacing = 6,
                margin_edge = 8,
                margin_ends = 12,
                margin_opposite_edge = 0,
                background_opacity = 0.0,
                compositor_blur = false,
                border = "outline_variant",
                border_width = 0.0,
                radius = 0,
                radius_top_left = 0,
                radius_top_right = 0,
                radius_bottom_left = 0,
                radius_bottom_right = 0,
                concave_edge_corners = false,
                shadow = false,
                contact_shadow = false,
                capsule = false,
                capsule_border_width = 1.0,
                start = { "group:left" },
                center = { "group:island" },
                ["end"] = { "group:right" },
            },
        },
        capsule_groups = {
            {
                id = "left",
                members = { "launcher", "ws" },
                fill = "surface_container",
                border = "outline_variant",
                border_width = 1.5,
                radius = 18,
                padding = 8.0,
                widget_spacing = 6.0,
                opacity = 0.96,
            },
            {
                id = "island",
                members = { "hclock", "media", "clipboard", "screenshot", "record", "display", "mirror", "wallpaper" },
                fill = "surface_container",
                border = "outline_variant",
                border_width = 1.5,
                radius = 19,
                padding = 10.0,
                widget_spacing = 8.0,
                opacity = 0.96,
                accordion = true,
                accordion_direction = "end",
                accordion_duration = 240,
                accordion_delay_ms = 60,
            },
            {
                id = "right",
                members = { "tray", "net", "vol", "bat", "notifications", "control-center", "session" },
                fill = "surface_container",
                border = "outline_variant",
                border_width = 1.5,
                radius = 18,
                padding = 8.0,
                widget_spacing = 6.0,
                opacity = 0.96,
            },
        },
        widget_ws = {
            order = { "style", "capsule_radius" },
            values = {
                style = "regular",
                capsule_radius = 12,
            },
        },
        notification = {
            order = { "position", "border", "border_width", "offset_x", "offset_y" },
            values = {
                position = "top_center",
                border = true,
                border_width = 1.5,
                offset_x = 0,
                offset_y = 6,
            },
        },
        osd = {
            order = { "position", "border", "border_width", "offset_x", "offset_y" },
            values = {
                position = "top_center",
                border = true,
                border_width = 1.5,
                offset_x = 0,
                offset_y = 6,
            },
        },
    },
}

local EXTRA_WIDGETS = {
    {
        name = "widget.hclock",
        lines = {
            "[widget.hclock]",
            'type = "clock"',
            'format = "{:%a %d %b · %H:%M}"',
        },
    },
    {
        name = "widget.media",
        lines = {
            "[widget.media]",
            'type = "media"',
            "art_size = 16.0",
            "min_length = 80.0",
            "max_length = 180.0",
            'title_scroll = "none"',
        },
    },
    {
        name = "widget.mirror",
        lines = {
            "[widget.mirror]",
            'type = "custom_button"',
            'glyph = "server"',
            'icon_color = "on_surface_variant"',
            'tooltip = "Mirror Optimizer (Left: Menu, Right: TUI)"',
        },
    },
    {
        name = "widget.mirror.actions",
        lines = {
            "[widget.mirror.actions]",
            'left = "exec kaze-mirror --menu"',
            'right = "exec kaze-mirror --tui-window"',
        },
    },
}

local CAP_ORDER = {
    "id",
    "members",
    "fill",
    "border",
    "border_width",
    "radius",
    "padding",
    "widget_spacing",
    "opacity",
    "accordion",
    "accordion_direction",
    "accordion_duration",
    "accordion_delay_ms",
}

local function escape_toml_str(s)
    return s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
end

local function format_num(val, is_float, is_int)
    if is_int then
        return string.format("%d", math.floor(val + 0.5))
    end
    if is_float then
        if val == math.floor(val) then
            return string.format("%.1f", val)
        end
        return tostring(val)
    end
    return tostring(val)
end

local function format_value(key, val, float_map, int_map)
    local t = type(val)
    if t == "boolean" then
        return val and "true" or "false"
    elseif t == "string" then
        return '"' .. escape_toml_str(val) .. '"'
    elseif t == "number" then
        return format_num(val, float_map and float_map[key], int_map and int_map[key])
    elseif t == "table" then
        if #val == 0 then
            return "[]"
        end
        local items = {}
        for i = 1, #val do
            items[i] = '"' .. escape_toml_str(tostring(val[i])) .. '"'
        end
        return "[ " .. table.concat(items, ", ") .. " ]"
    end
    error("unsupported TOML value type for key '" .. tostring(key) .. "': " .. t)
end

--- Track TOML multiline string and array nesting across lines so headers
--- inside multiline values are never treated as new sections.
local function scan_line_state(line, state)
    local i, len = 1, #line
    local ml = state.ml
    local depth = state.depth
    local q = nil

    while i <= len do
        local c = line:sub(i, i)
        if ml then
            if line:sub(i, i + 2) == ml then
                ml = nil
                i = i + 3
            elseif ml == '"""' and c == "\\" then
                i = i + 2
            else
                i = i + 1
            end
        elseif q then
            if q == '"' and c == "\\" then
                i = i + 2
            elseif c == q then
                q = nil
                i = i + 1
            else
                i = i + 1
            end
        else
            if c == "#" then
                break
            elseif line:sub(i, i + 2) == '"""' or line:sub(i, i + 2) == "'''" then
                ml = line:sub(i, i + 2)
                i = i + 3
            elseif c == '"' or c == "'" then
                q = c
                i = i + 1
            elseif c == "[" or c == "{" then
                depth = depth + 1
                i = i + 1
            elseif c == "]" or c == "}" then
                if depth > 0 then
                    depth = depth - 1
                end
                i = i + 1
            else
                i = i + 1
            end
        end
    end

    return { ml = ml, depth = depth }
end

local function parse_header_line(line)
    local no_comment = line:gsub("#.*$", "")
    local arr = no_comment:match("^%s*%[%[%s*([^%]]-)%s*%]%]%s*$")
    if arr and arr ~= "" then
        return arr, true
    end
    local sec = no_comment:match("^%s*%[%s*([^%[%]]-)%s*%]%s*$")
    if sec and sec ~= "" then
        return sec, false
    end
    return nil, false
end

local function split_lines(text)
    local lines = {}
    local pos = 1
    while pos <= #text do
        local nl = text:find("\n", pos, true)
        if nl then
            lines[#lines + 1] = text:sub(pos, nl - 1):gsub("\r$", "")
            pos = nl + 1
        else
            lines[#lines + 1] = text:sub(pos):gsub("\r$", "")
            break
        end
    end
    return lines
end

local function split_blocks(text)
    local lines = split_lines(text)
    local blocks = {}
    local cur = { sec = nil, is_array = false, lines = {} }
    local state = { ml = nil, depth = 0 }

    for _, line in ipairs(lines) do
        if not state.ml and state.depth == 0 then
            local sec, is_arr = parse_header_line(line)
            if sec then
                if cur.sec ~= nil or #cur.lines > 0 then
                    blocks[#blocks + 1] = cur
                end
                cur = { sec = sec, is_array = is_arr, lines = { line } }
                state = scan_line_state(line, state)
                state.depth = 0
                goto continue
            end
        end
        cur.lines[#cur.lines + 1] = line
        state = scan_line_state(line, state)
        ::continue::
    end
    if cur.sec ~= nil or #cur.lines > 0 then
        blocks[#blocks + 1] = cur
    end
    return blocks
end

local function patch_section_block(block, spec, drop_keys)
    local out = {}
    local seen = {}
    local state = { ml = nil, depth = 0 }
    local lines = block.lines
    local i = 1

    if #lines > 0 and block.sec ~= nil then
        out[#out + 1] = lines[1]
        i = 2
    end

    while i <= #lines do
        local line = lines[i]
        if not state.ml and state.depth == 0 then
            local key = line:match("^%s*([A-Za-z0-9_%-]+)%s*=")
            if key and (spec.values[key] ~= nil or (drop_keys and drop_keys[key])) then
                -- Advance past any multiline continuation of the replaced assignment.
                local st = scan_line_state(line, state)
                while (st.ml ~= nil or st.depth > 0) and i < #lines do
                    i = i + 1
                    st = scan_line_state(lines[i], st)
                end
                state = st
                if spec.values[key] ~= nil and not seen[key] then
                    out[#out + 1] = key .. " = " .. format_value(key, spec.values[key], FLOAT_KEYS, INT_KEYS)
                    seen[key] = true
                end
                i = i + 1
                goto next_stmt
            end
        end
        out[#out + 1] = line
        state = scan_line_state(line, state)
        i = i + 1
        ::next_stmt::
    end

    -- Preserve trailing blank lines at the bottom of the section when appending missing keys.
    local trailing_blanks = {}
    while #out > 1 and out[#out]:match("^%s*$") do
        trailing_blanks[#trailing_blanks + 1] = table.remove(out)
    end
    for _, key in ipairs(spec.order) do
        if spec.values[key] ~= nil and not seen[key] then
            out[#out + 1] = key .. " = " .. format_value(key, spec.values[key], FLOAT_KEYS, INT_KEYS)
            seen[key] = true
        end
    end
    for j = #trailing_blanks, 1, -1 do
        out[#out + 1] = trailing_blanks[j]
    end

    block.lines = out
end

local function build_section_block(sec, spec)
    local lines = { "[" .. sec .. "]" }
    for _, key in ipairs(spec.order) do
        local val = spec.values[key]
        if val ~= nil then
            lines[#lines + 1] = key .. " = " .. format_value(key, val, FLOAT_KEYS, INT_KEYS)
        end
    end
    return { sec = sec, is_array = false, lines = lines }
end

local function build_capsule_group_block(group)
    local lines = { "[[bar.default.capsule_group]]" }
    for _, key in ipairs(CAP_ORDER) do
        if group[key] ~= nil then
            lines[#lines + 1] = key .. " = " .. format_value(key, group[key], CAP_FLOAT_KEYS, CAP_INT_KEYS)
        end
    end
    return { sec = "bar.default.capsule_group", is_array = true, lines = lines }
end

local function ensure_trailing_blank(block)
    if #block.lines > 0 and not block.lines[#block.lines]:match("^%s*$") then
        block.lines[#block.lines + 1] = ""
    end
end

function M.is_valid(name)
    return type(name) == "string" and M.PRESETS[name] ~= nil
end

function M.get(name)
    return M.PRESETS[name]
end

function M.list()
    local items = {}
    for _, id in ipairs(M.ORDER) do
        items[#items + 1] = M.PRESETS[id]
    end
    return items
end

function M.state_file(opts)
    if opts and opts.state_file then
        return opts.state_file
    end
    return fs.config_dir() .. "/kaze/style"
end

function M.read_style(opts)
    local path = M.state_file(opts)
    local raw = fs.read_file(path)
    if not raw then
        return M.DEFAULT, false
    end
    local trimmed = raw:match("^%s*(.-)%s*$")
    if trimmed == "" then
        return M.DEFAULT, false
    end
    if not M.is_valid(trimmed) then
        return nil, string.format("invalid saved style '%s' in %s", trimmed, path)
    end
    return trimmed, true
end

function M.detect_style(toml_text)
    if type(toml_text) ~= "string" or toml_text == "" then
        return nil
    end
    if toml_text:find('id%s*=%s*"island"') then
        return "dynamic-island"
    end
    if toml_text:find('id%s*=%s*"left"') and toml_text:find('id%s*=%s*"right"') then
        return "floating-islands"
    end
    if toml_text:find("concave_edge_corners%s*=%s*true") then
        return "concave-notch"
    end
    if toml_text:find('position%s*=%s*"left"') then
        return "omarchy-rail"
    end
    return nil
end

function M.current_style(opts)
    local style, err = M.read_style(opts)
    if not style then
        return nil, err
    end
    return style
end

--- Return an updated Noctalia config.toml string for the given style preset
--- while preserving user settings outside style-managed keys.
function M.render_config(toml_text, style_name)
    local preset = M.PRESETS[style_name]
    if not preset then
        return nil, "unknown style preset: " .. tostring(style_name)
    end
    if type(toml_text) ~= "string" then
        return nil, "expected config.toml text"
    end

    local blocks = split_blocks(toml_text)
    local filtered = {}
    local seen_sec = {}

    local section_specs = {
        ["shell"] = { spec = preset.shell },
        ["shell.panel"] = { spec = preset.shell_panel },
        ["bar.default"] = { spec = preset.bar_default, drop = { capsule_group = true } },
        ["widget.ws"] = { spec = preset.widget_ws },
        ["notification"] = { spec = preset.notification },
        ["osd"] = { spec = preset.osd },
    }

    for _, blk in ipairs(blocks) do
        if blk.is_array and blk.sec == "bar.default.capsule_group" then
            -- Replace all existing capsule_group tables with the active preset's list.
        else
            if not blk.is_array and blk.sec and section_specs[blk.sec] then
                patch_section_block(blk, section_specs[blk.sec].spec, section_specs[blk.sec].drop)
                seen_sec[blk.sec] = true
            elseif not blk.is_array and blk.sec then
                seen_sec[blk.sec] = true
            end
            filtered[#filtered + 1] = blk
        end
    end

    local function insert_after(target_sec, new_blocks)
        if #new_blocks == 0 then
            return
        end
        local pos = #filtered + 1
        for idx, blk in ipairs(filtered) do
            if not blk.is_array and blk.sec == target_sec then
                pos = idx + 1
                ensure_trailing_blank(blk)
                break
            end
        end
        for offset, nb in ipairs(new_blocks) do
            ensure_trailing_blank(nb)
            table.insert(filtered, pos + offset - 1, nb)
        end
    end

    local function insert_before(target_sec, new_block)
        local pos = #filtered + 1
        for idx, blk in ipairs(filtered) do
            if not blk.is_array and blk.sec == target_sec then
                pos = idx
                break
            end
        end
        if pos > 1 then
            ensure_trailing_blank(filtered[pos - 1])
        end
        ensure_trailing_blank(new_block)
        table.insert(filtered, pos, new_block)
    end

    if not seen_sec["shell"] then
        insert_before("bar.default", build_section_block("shell", preset.shell))
    end
    if not seen_sec["shell.panel"] then
        insert_after("shell", { build_section_block("shell.panel", preset.shell_panel) })
    end
    if not seen_sec["bar.default"] then
        insert_after("shell.panel", { build_section_block("bar.default", preset.bar_default) })
    end
    if not seen_sec["widget.ws"] then
        insert_after("bar.default", { build_section_block("widget.ws", preset.widget_ws) })
    end

    if #preset.capsule_groups > 0 then
        local cap_blocks = {}
        for _, grp in ipairs(preset.capsule_groups) do
            cap_blocks[#cap_blocks + 1] = build_capsule_group_block(grp)
        end
        insert_after("bar.default", cap_blocks)
    end

    for _, w in ipairs(EXTRA_WIDGETS) do
        if not seen_sec[w.name] then
            local copy_lines = {}
            for i = 1, #w.lines do
                copy_lines[i] = w.lines[i]
            end
            insert_before("notification", { sec = w.name, is_array = false, lines = copy_lines })
        end
    end

    for _, tail_sec in ipairs({ "notification", "osd" }) do
        if not seen_sec[tail_sec] then
            local spec = section_specs[tail_sec].spec
            local nb = build_section_block(tail_sec, spec)
            if #filtered > 0 then
                ensure_trailing_blank(filtered[#filtered])
            end
            filtered[#filtered + 1] = nb
        end
    end

    local rendered_lines = {}
    for _, blk in ipairs(filtered) do
        for _, ln in ipairs(blk.lines) do
            rendered_lines[#rendered_lines + 1] = ln
        end
    end
    while #rendered_lines > 0 and rendered_lines[#rendered_lines]:match("^%s*$") do
        table.remove(rendered_lines)
    end
    return table.concat(rendered_lines, "\n") .. "\n"
end

function M.render_template_for_style(base_template_text, style_name)
    local name = style_name or M.DEFAULT
    if not M.is_valid(name) then
        return base_template_text
    end
    return M.render_config(base_template_text, name)
end

local function cmd_exists(cmd)
    local ok = os.execute("command -v " .. fs.shell_quote(cmd) .. " >/dev/null 2>&1")
    return ok == true or ok == 0
end

local function validate_noctalia_text(config_path, text)
    if not cmd_exists("noctalia") then
        return true
    end
    local dir = fs.dirname(config_path)
    local ok_dir, dir_err = fs.mkdir_p(dir)
    if not ok_dir then
        return nil, dir_err
    end
    local probe = dir .. "/.kaze-style-validate.toml"
    local fh, err = io.open(probe, "w")
    if not fh then
        return nil, err
    end
    fh:write(text)
    fh:close()
    local ok_val = os.execute("noctalia config validate " .. fs.shell_quote(probe) .. " >/dev/null 2>&1")
    os.remove(probe)
    if not (ok_val == true or ok_val == 0) then
        return nil, "noctalia config validate rejected rendered style config"
    end
    return true
end

function M.apply(style_name, opts)
    opts = opts or {}
    if not M.is_valid(style_name) then
        return nil, string.format("unknown visual style '%s' (expected: %s)", tostring(style_name), table.concat(M.ORDER, ", "))
    end

    local cfg_path = opts.config_path or (fs.config_dir() .. "/noctalia/config.toml")
    local src_text = fs.read_file(cfg_path)
    if not src_text and opts.template_path then
        src_text = fs.read_file(opts.template_path)
    end
    if not src_text then
        return nil, "Noctalia config not found: " .. cfg_path
    end

    local rendered, render_err = M.render_config(src_text, style_name)
    if not rendered then
        return nil, render_err
    end

    if opts.validate ~= false then
        local ok_val, val_err = validate_noctalia_text(cfg_path, rendered)
        if not ok_val then
            return nil, val_err
        end
    end

    local ok_cfg, cfg_err = fs.write_atomic(cfg_path, rendered)
    if not ok_cfg then
        return nil, cfg_err
    end

    local st_path = M.state_file(opts)
    local ok_st, st_err = fs.write_atomic(st_path, style_name .. "\n")
    if not ok_st then
        return nil, st_err
    end

    if opts.reload ~= false and cmd_exists("noctalia") then
        os.execute("noctalia msg config-reload >/dev/null 2>&1")
    end

    return {
        style = style_name,
        config_path = cfg_path,
        state_file = st_path,
    }
end

return M
