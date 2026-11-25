local M = {}

M.REQUIRED_KEYS = {
    "bg",
    "bg_alt",
    "surface",
    "border",
    "fg",
    "fg_muted",
    "accent",
    "accent_fg",
    "ok",
    "warn",
    "danger",
}

function M.normalize_hex(v)
    if type(v) ~= "string" then
        return nil
    end
    local s = v:match("^%s*#?([%x]+)%s*$")
    if not s then
        return nil
    end
    s = s:lower()
    if #s == 3 then
        local r, g, b = s:sub(1, 1), s:sub(2, 2), s:sub(3, 3)
        return r .. r .. g .. g .. b .. b
    elseif #s == 6 then
        return s
    elseif #s == 8 then
        return s:sub(1, 6)
    end
    return nil
end

function M.hex_to_rgb(hex)
    local h = assert(M.normalize_hex(hex), "invalid hex color: " .. tostring(hex))
    local r = tonumber(h:sub(1, 2), 16)
    local g = tonumber(h:sub(3, 4), 16)
    local b = tonumber(h:sub(5, 6), 16)
    return r, g, b
end

local function clamp_byte(n)
    local v = math.floor(n + 0.5)
    if v < 0 then
        return 0
    elseif v > 255 then
        return 255
    end
    return v
end

function M.rgb_to_hex(r, g, b)
    return string.format("%02x%02x%02x", clamp_byte(r), clamp_byte(g), clamp_byte(b))
end

function M.rgb_to_hsl(r, g, b)
    local rn, gn, bn = r / 255.0, g / 255.0, b / 255.0
    local maxc = math.max(rn, gn, bn)
    local minc = math.min(rn, gn, bn)
    local l = 0.5 * (maxc + minc)
    local d = maxc - minc
    if d == 0 then
        return 0.0, 0.0, l
    end
    local s = d / (1.0 - math.abs(2.0 * l - 1.0))
    local h
    if maxc == rn then
        h = 60.0 * (((gn - bn) / d) % 6.0)
    elseif maxc == gn then
        h = 60.0 * (((bn - rn) / d) + 2.0)
    else
        h = 60.0 * (((rn - gn) / d) + 4.0)
    end
    if h < 0 then
        h = h + 360.0
    end
    return h, math.min(1.0, math.max(0.0, s)), math.min(1.0, math.max(0.0, l))
end

function M.hsl_to_rgb(h, s, l)
    local hn = (h or 0.0) % 360.0
    local sn = math.min(1.0, math.max(0.0, s or 0.0))
    local ln = math.min(1.0, math.max(0.0, l or 0.0))
    local c = (1.0 - math.abs(2.0 * ln - 1.0)) * sn
    local x = c * (1.0 - math.abs(((hn / 60.0) % 2.0) - 1.0))
    local m = ln - 0.5 * c
    local r1, g1, b1
    if hn < 60.0 then
        r1, g1, b1 = c, x, 0.0
    elseif hn < 120.0 then
        r1, g1, b1 = x, c, 0.0
    elseif hn < 180.0 then
        r1, g1, b1 = 0.0, c, x
    elseif hn < 240.0 then
        r1, g1, b1 = 0.0, x, c
    elseif hn < 300.0 then
        r1, g1, b1 = x, 0.0, c
    else
        r1, g1, b1 = c, 0.0, x
    end
    return clamp_byte((r1 + m) * 255.0), clamp_byte((g1 + m) * 255.0), clamp_byte((b1 + m) * 255.0)
end

function M.hex_to_hsl(hex)
    local r, g, b = M.hex_to_rgb(hex)
    return M.rgb_to_hsl(r, g, b)
end

function M.hsl_to_hex(h, s, l)
    return M.rgb_to_hex(M.hsl_to_rgb(h, s, l))
end

local function srgb_to_linear(channel_255)
    local c = channel_255 / 255.0
    if c <= 0.04045 then
        return c / 12.92
    end
    return ((c + 0.055) / 1.055) ^ 2.4
end

function M.relative_luminance(hex)
    local r, g, b = M.hex_to_rgb(hex)
    return 0.2126 * srgb_to_linear(r) + 0.7152 * srgb_to_linear(g) + 0.0722 * srgb_to_linear(b)
end

M.luminance = M.relative_luminance

function M.contrast_ratio(hex1, hex2)
    local l1 = M.relative_luminance(hex1)
    local l2 = M.relative_luminance(hex2)
    if l1 < l2 then
        l1, l2 = l2, l1
    end
    return (l1 + 0.05) / (l2 + 0.05)
end

local function min_contrast_all(cand_hex, bgs)
    local worst = math.huge
    for i = 1, #bgs do
        local ratio = M.contrast_ratio(cand_hex, bgs[i])
        if ratio < worst then
            worst = ratio
        end
    end
    return worst
end

function M.clamp_contrast(fg_hex, bg_hexes, min_ratio)
    local fg = assert(M.normalize_hex(fg_hex), "invalid foreground hex: " .. tostring(fg_hex))
    assert(type(min_ratio) == "number" and min_ratio >= 1.0, "min_ratio must be >= 1.0")

    local bgs = {}
    if type(bg_hexes) == "string" then
        bgs[1] = assert(M.normalize_hex(bg_hexes), "invalid background hex: " .. tostring(bg_hexes))
    elseif type(bg_hexes) == "table" and #bg_hexes > 0 then
        for i = 1, #bg_hexes do
            bgs[i] = assert(M.normalize_hex(bg_hexes[i]), "invalid background hex at index " .. i)
        end
    else
        error("bg_hexes must be a hex string or non-empty list of hex strings")
    end

    if min_contrast_all(fg, bgs) >= min_ratio then
        return fg
    end

    local h, s, l0 = M.hex_to_hsl(fg)
    local white_ratio = min_contrast_all("ffffff", bgs)
    local black_ratio = min_contrast_all("000000", bgs)

    local function search_lighter()
        if white_ratio < min_ratio then
            return nil
        end
        local lo, hi = l0, 1.0
        for _ = 1, 32 do
            local mid = 0.5 * (lo + hi)
            local cand = M.hsl_to_hex(h, s, mid)
            if min_contrast_all(cand, bgs) >= min_ratio then
                hi = mid
            else
                lo = mid
            end
        end
        local best = M.hsl_to_hex(h, s, hi)
        if min_contrast_all(best, bgs) >= min_ratio then
            return best, math.abs(hi - l0)
        end
        for step = 1, 512 do
            local lv = hi + (1.0 - hi) * (step / 512.0)
            local cand = M.hsl_to_hex(h, s, lv)
            if min_contrast_all(cand, bgs) >= min_ratio then
                return cand, math.abs(lv - l0)
            end
        end
        return "ffffff", 1.0 - l0
    end

    local function search_darker()
        if black_ratio < min_ratio then
            return nil
        end
        local lo, hi = 0.0, l0
        for _ = 1, 32 do
            local mid = 0.5 * (lo + hi)
            local cand = M.hsl_to_hex(h, s, mid)
            if min_contrast_all(cand, bgs) >= min_ratio then
                lo = mid
            else
                hi = mid
            end
        end
        local best = M.hsl_to_hex(h, s, lo)
        if min_contrast_all(best, bgs) >= min_ratio then
            return best, math.abs(l0 - lo)
        end
        for step = 1, 512 do
            local lv = lo * (1.0 - step / 512.0)
            local cand = M.hsl_to_hex(h, s, lv)
            if min_contrast_all(cand, bgs) >= min_ratio then
                return cand, math.abs(l0 - lv)
            end
        end
        return "000000", l0
    end

    local fg_lum = M.relative_luminance(fg)
    local bg_lum_sum = 0.0
    for i = 1, #bgs do
        bg_lum_sum = bg_lum_sum + M.relative_luminance(bgs[i])
    end
    local bg_lum_avg = bg_lum_sum / #bgs

    local prefer_light
    if math.abs(fg_lum - bg_lum_avg) < 1e-6 then
        prefer_light = white_ratio >= black_ratio
    else
        prefer_light = fg_lum > bg_lum_avg
    end

    local c_light, d_light = search_lighter()
    local c_dark, d_dark = search_darker()

    if prefer_light and c_light then
        return c_light
    elseif (not prefer_light) and c_dark then
        return c_dark
    elseif c_light and c_dark then
        return (d_light <= d_dark) and c_light or c_dark
    elseif c_light then
        return c_light
    elseif c_dark then
        return c_dark
    end

    -- Exotic multi-background span (e.g. black + white simultaneously): search middle lightnesses
    local best_hex = (white_ratio >= black_ratio) and "ffffff" or "000000"
    local best_ratio = math.max(white_ratio, black_ratio)
    for step = 0, 255 do
        local cand = M.hsl_to_hex(h, s, step / 255.0)
        local r = min_contrast_all(cand, bgs)
        if r > best_ratio then
            best_ratio = r
            best_hex = cand
        end
    end
    for step = 0, 255 do
        local cand = M.rgb_to_hex(step, step, step)
        local r = min_contrast_all(cand, bgs)
        if r > best_ratio then
            best_ratio = r
            best_hex = cand
        end
    end
    return best_hex
end

-- Pure-Lua JSON parser for matugen JSON output (zero external dependencies, zero I/O)
function M.parse_json(src)
    assert(type(src) == "string", "parse_json expects a string")
    local pos = 1
    local len = #src
    local parse_val

    local function skip_ws()
        while pos <= len do
            local b = src:byte(pos)
            if b == 32 or b == 9 or b == 10 or b == 13 then
                pos = pos + 1
            else
                break
            end
        end
    end

    local function utf8_from_codepoint(cp)
        if cp <= 0x7F then
            return string.char(cp)
        elseif cp <= 0x7FF then
            return string.char(0xC0 + math.floor(cp / 64), 0x80 + (cp % 64))
        elseif cp <= 0xFFFF then
            return string.char(
                0xE0 + math.floor(cp / 4096),
                0x80 + (math.floor(cp / 64) % 64),
                0x80 + (cp % 64)
            )
        end
        return "?"
    end

    local escapes = {
        ['"'] = '"',
        ["\\"] = "\\",
        ["/"] = "/",
        ["b"] = "\b",
        ["f"] = "\f",
        ["n"] = "\n",
        ["r"] = "\r",
        ["t"] = "\t",
    }

    local function parse_str()
        pos = pos + 1
        local out = {}
        while pos <= len do
            local c = src:sub(pos, pos)
            if c == '"' then
                pos = pos + 1
                return table.concat(out)
            elseif c == "\\" then
                pos = pos + 1
                local e = src:sub(pos, pos)
                if e == "u" then
                    local hex4 = src:sub(pos + 1, pos + 4)
                    local cp = tonumber(hex4, 16)
                    if not cp or #hex4 ~= 4 then
                        error("invalid unicode escape in JSON at " .. pos)
                    end
                    out[#out + 1] = utf8_from_codepoint(cp)
                    pos = pos + 5
                elseif escapes[e] then
                    out[#out + 1] = escapes[e]
                    pos = pos + 1
                else
                    error("invalid escape in JSON string at " .. pos)
                end
            else
                out[#out + 1] = c
                pos = pos + 1
            end
        end
        error("unterminated JSON string")
    end

    local function parse_num()
        local s = src:sub(pos):match("^-?%d+%.?%d*[eE]?[+-]?%d*")
        local n = tonumber(s)
        if not n then
            error("invalid JSON number at " .. pos)
        end
        pos = pos + #s
        return n
    end

    local function parse_arr()
        pos = pos + 1
        local arr = {}
        skip_ws()
        if src:sub(pos, pos) == "]" then
            pos = pos + 1
            return arr
        end
        while true do
            arr[#arr + 1] = parse_val()
            skip_ws()
            local c = src:sub(pos, pos)
            if c == "," then
                pos = pos + 1
            elseif c == "]" then
                pos = pos + 1
                return arr
            else
                error("expected ',' or ']' in JSON array at " .. pos)
            end
        end
    end

    local function parse_obj()
        pos = pos + 1
        local obj = {}
        skip_ws()
        if src:sub(pos, pos) == "}" then
            pos = pos + 1
            return obj
        end
        while true do
            skip_ws()
            if src:sub(pos, pos) ~= '"' then
                error("expected JSON string key at " .. pos)
            end
            local k = parse_str()
            skip_ws()
            if src:sub(pos, pos) ~= ":" then
                error("expected ':' after JSON key at " .. pos)
            end
            pos = pos + 1
            obj[k] = parse_val()
            skip_ws()
            local c = src:sub(pos, pos)
            if c == "," then
                pos = pos + 1
            elseif c == "}" then
                pos = pos + 1
                return obj
            else
                error("expected ',' or '}' in JSON object at " .. pos)
            end
        end
    end

    parse_val = function()
        skip_ws()
        local c = src:sub(pos, pos)
        if c == "{" then
            return parse_obj()
        elseif c == "[" then
            return parse_arr()
        elseif c == '"' then
            return parse_str()
        elseif c == "t" and src:sub(pos, pos + 3) == "true" then
            pos = pos + 4
            return true
        elseif c == "f" and src:sub(pos, pos + 4) == "false" then
            pos = pos + 5
            return false
        elseif c == "n" and src:sub(pos, pos + 3) == "null" then
            pos = pos + 4
            return nil
        elseif c == "-" or (c >= "0" and c <= "9") then
            return parse_num()
        end
        error("unexpected JSON token at " .. pos)
    end

    local res = parse_val()
    skip_ws()
    if pos <= len then
        error("trailing characters after JSON at " .. pos)
    end
    return res
end

local function extract_hex_node(node)
    if type(node) == "string" then
        return M.normalize_hex(node)
    elseif type(node) == "table" then
        if node.dark ~= nil then
            local d = extract_hex_node(node.dark)
            if d then
                return d
            end
        end
        if node.default ~= nil then
            local d = extract_hex_node(node.default)
            if d then
                return d
            end
        end
        if node.color ~= nil then
            local c = extract_hex_node(node.color)
            if c then
                return c
            end
        end
        if node.hex ~= nil then
            local h = extract_hex_node(node.hex)
            if h then
                return h
            end
        end
    end
    return nil
end

local function lookup_role(src, candidates)
    local colors = type(src.colors) == "table" and src.colors or nil
    local dark_map = (colors and type(colors.dark) == "table" and colors.dark)
        or (type(src.dark) == "table" and src.dark)
        or nil

    for i = 1, #candidates do
        local key = candidates[i]
        local direct = extract_hex_node(src[key])
        if direct then
            return direct
        end
        if colors then
            local from_role = extract_hex_node(colors[key])
            if from_role then
                return from_role
            end
        end
        if dark_map then
            local from_dark = extract_hex_node(dark_map[key])
            if from_dark then
                return from_dark
            end
        end
    end
    return nil
end

function M.build_dynamic_palette(raw_colors)
    local src = raw_colors
    if type(src) == "string" then
        src = M.parse_json(src)
    end
    if type(src) ~= "table" then
        error("build_dynamic_palette expects a table or JSON string", 0)
    end

    local is_kaze_map = extract_hex_node(src.bg) ~= nil or extract_hex_node(src.bg_alt) ~= nil

    local raw_bg = lookup_role(src, {
        "bg", "background", "surface_dim", "surface_container_lowest", "surface",
    })
    local raw_bg_alt = lookup_role(src, {
        "bg_alt", "surface_container_low", "surface_container", "surface_variant", "background",
    })
    local raw_surface = lookup_role(src, is_kaze_map
        and { "surface", "surface_container_high", "surface_container_highest", "surface_variant" }
        or { "surface_container_high", "surface_container_highest", "surface_bright", "surface_variant", "surface" })
    local raw_border = lookup_role(src, { "border", "outline_variant", "outline" })
    local raw_fg = lookup_role(src, { "fg", "on_surface", "on_background" })
    local raw_fg_muted = lookup_role(src, { "fg_muted", "on_surface_variant", "outline" })
    local raw_accent = lookup_role(src, { "accent", "primary", "primary_fixed", "secondary" })
    local raw_accent_fg = lookup_role(src, { "accent_fg", "on_primary", "on_primary_fixed" })
    local raw_ok = lookup_role(src, { "ok", "green", "tertiary" })
    local raw_warn = lookup_role(src, { "warn", "yellow", "secondary" })
    local raw_danger = lookup_role(src, { "danger", "error", "red" })

    if not (raw_bg or raw_accent or raw_fg) then
        error("matugen output contains no recognizable hex colors", 0)
    end

    local seed_h, seed_s = 220.0, 0.16
    if raw_accent then
        local ah, as = M.hex_to_hsl(raw_accent)
        seed_h, seed_s = ah, math.min(0.24, as)
    elseif raw_bg then
        local bh, bs = M.hex_to_hsl(raw_bg)
        seed_h, seed_s = bh, math.min(0.24, bs)
    end

    -- 1. Dark-first surface hierarchy: bg < bg_alt < surface
    local bg_h, bg_s, bg_l
    if raw_bg then
        bg_h, bg_s, bg_l = M.hex_to_hsl(raw_bg)
    else
        bg_h, bg_s, bg_l = seed_h, seed_s, 0.08
    end
    bg_s = math.min(bg_s, 0.35)
    if bg_l > 0.11 then
        bg_l = 0.08
    end
    local bg = M.hsl_to_hex(bg_h, bg_s, bg_l)

    local alt_h, alt_s, alt_l
    if raw_bg_alt then
        alt_h, alt_s, alt_l = M.hex_to_hsl(raw_bg_alt)
    else
        alt_h, alt_s, alt_l = bg_h, bg_s, bg_l + 0.04
    end
    alt_s = math.min(alt_s, 0.35)
    if alt_l < bg_l + 0.035 or alt_l > 0.16 then
        alt_l = math.min(0.16, math.max(bg_l + 0.04, 0.115))
    end
    local bg_alt = M.hsl_to_hex(alt_h, alt_s, alt_l)
    while M.relative_luminance(bg_alt) <= M.relative_luminance(bg) and alt_l < 0.20 do
        alt_l = alt_l + 0.01
        bg_alt = M.hsl_to_hex(alt_h, alt_s, alt_l)
    end

    local surf_h, surf_s, surf_l
    if raw_surface then
        surf_h, surf_s, surf_l = M.hex_to_hsl(raw_surface)
    else
        surf_h, surf_s, surf_l = alt_h, alt_s, alt_l + 0.06
    end
    surf_s = math.min(surf_s, 0.35)
    if surf_l < alt_l + 0.045 or surf_l > 0.25 then
        surf_l = math.min(0.25, math.max(alt_l + 0.06, 0.18))
    end
    local surface = M.hsl_to_hex(surf_h, surf_s, surf_l)
    while M.relative_luminance(surface) <= M.relative_luminance(bg_alt) and surf_l < 0.30 do
        surf_l = surf_l + 0.01
        surface = M.hsl_to_hex(surf_h, surf_s, surf_l)
    end

    local bgs = { bg, bg_alt }

    -- 2. Primary and muted foregrounds: >= 4.5:1 against BOTH bg and bg_alt
    local fg_seed = raw_fg or M.hsl_to_hex(seed_h, math.min(seed_s, 0.20), 0.92)
    local fg = M.clamp_contrast(fg_seed, bgs, 7.0)
    fg = M.clamp_contrast(fg, bgs, 4.5)

    local muted_seed = raw_fg_muted or M.hsl_to_hex(seed_h, math.min(seed_s, 0.18), 0.62)
    local mh, ms, ml = M.hex_to_hsl(muted_seed)
    local _, _, fgl = M.hex_to_hsl(fg)
    if ml > fgl - 0.10 then
        ml = math.max(0.50, fgl - 0.22)
        muted_seed = M.hsl_to_hex(mh, math.min(ms, 0.25), ml)
    end
    local fg_muted = M.clamp_contrast(muted_seed, bgs, 4.5)

    -- 3. Accent (>= 3.0:1 against bg/bg_alt) and accent_fg (>= 4.5:1 against accent)
    local accent_seed = raw_accent or "89b4fa"
    local accent = M.clamp_contrast(accent_seed, bgs, 3.0)
    local accent_fg_seed = raw_accent_fg or bg
    local accent_fg = M.clamp_contrast(accent_fg_seed, { accent }, 4.5)

    -- 4. Border and semantic tokens: >= 3.0:1 against BOTH bg and bg_alt
    local border_seed = raw_border or M.hsl_to_hex(surf_h, surf_s, surf_l + 0.12)
    local border = M.clamp_contrast(border_seed, bgs, 3.0)
    local ok = M.clamp_contrast(raw_ok or "a6e3a1", bgs, 3.0)
    local warn = M.clamp_contrast(raw_warn or "f9e2af", bgs, 3.0)
    local danger = M.clamp_contrast(raw_danger or "f38ba8", bgs, 3.0)

    local palette = {
        bg = bg,
        bg_alt = bg_alt,
        surface = surface,
        border = border,
        fg = fg,
        fg_muted = fg_muted,
        accent = accent,
        accent_fg = accent_fg,
        ok = ok,
        warn = warn,
        danger = danger,
    }

    for _, k in ipairs(M.REQUIRED_KEYS) do
        local v = palette[k]
        assert(type(v) == "string" and #v == 6 and v:match("^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$"),
            "invalid generated dynamic token " .. k)
    end

    return palette
end

return M
