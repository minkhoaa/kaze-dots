-- Strict pure-Lua JSON decoder (0 I/O) supporting UTF-16 surrogate pairs.
local M = {}

local function utf8_from_codepoint(cp)
    if cp <= 0x7F then
        return string.char(cp)
    elseif cp <= 0x7FF then
        return string.char(
            0xC0 + math.floor(cp / 0x40),
            0x80 + (cp % 0x40)
        )
    elseif cp <= 0xFFFF then
        return string.char(
            0xE0 + math.floor(cp / 0x1000),
            0x80 + (math.floor(cp / 0x40) % 0x40),
            0x80 + (cp % 0x40)
        )
    elseif cp <= 0x10FFFF then
        return string.char(
            0xF0 + math.floor(cp / 0x40000),
            0x80 + (math.floor(cp / 0x1000) % 0x40),
            0x80 + (math.floor(cp / 0x40) % 0x40),
            0x80 + (cp % 0x40)
        )
    end
    error("unicode codepoint out of range: " .. tostring(cp), 0)
end

local ESCAPES = {
    ['"'] = '"',
    ["\\"] = "\\",
    ["/"] = "/",
    ["b"] = "\b",
    ["f"] = "\f",
    ["n"] = "\n",
    ["r"] = "\r",
    ["t"] = "\t",
}

function M.decode(src)
    assert(type(src) == "string", "json.decode expects a string")
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
                    local cp = (#hex4 == 4) and tonumber(hex4, 16) or nil
                    if not cp then
                        error("invalid unicode escape in JSON at " .. pos, 0)
                    end
                    pos = pos + 5
                    if cp >= 0xD800 and cp <= 0xDBFF and src:sub(pos, pos + 1) == "\\u" then
                        local low_hex = src:sub(pos + 2, pos + 5)
                        local low_cp = (#low_hex == 4) and tonumber(low_hex, 16) or nil
                        if low_cp and low_cp >= 0xDC00 and low_cp <= 0xDFFF then
                            cp = 0x10000 + (cp - 0xD800) * 0x400 + (low_cp - 0xDC00)
                            pos = pos + 6
                        end
                    end
                    out[#out + 1] = utf8_from_codepoint(cp)
                elseif ESCAPES[e] then
                    out[#out + 1] = ESCAPES[e]
                    pos = pos + 1
                else
                    error("invalid escape in JSON string at " .. pos, 0)
                end
            else
                out[#out + 1] = c
                pos = pos + 1
            end
        end
        error("unterminated JSON string", 0)
    end

    local function parse_num()
        local s = src:sub(pos):match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*")
        local n = s and tonumber(s) or nil
        if not n then
            error("invalid JSON number at " .. pos, 0)
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
                error("expected ',' or ']' in JSON array at " .. pos, 0)
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
                error("expected JSON string key at " .. pos, 0)
            end
            local k = parse_str()
            skip_ws()
            if src:sub(pos, pos) ~= ":" then
                error("expected ':' after JSON key at " .. pos, 0)
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
                error("expected ',' or '}' in JSON object at " .. pos, 0)
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
        error("unexpected JSON token at " .. pos, 0)
    end

    local res = parse_val()
    skip_ws()
    if pos <= len then
        error("trailing characters after JSON at " .. pos, 0)
    end
    return res
end

local function escape_str(s)
    local out = s:gsub('[\\"\b\f\n\r\t%z\1-\31]', function(c)
        local b = c:byte(1)
        if c == '"' then return '\\"'
        elseif c == "\\" then return "\\\\"
        elseif c == "\b" then return "\\b"
        elseif c == "\f" then return "\\f"
        elseif c == "\n" then return "\\n"
        elseif c == "\r" then return "\\r"
        elseif c == "\t" then return "\\t"
        else return string.format("\\u%04x", b)
        end
    end)
    return '"' .. out .. '"'
end

local function is_array(tbl)
    local count = 0
    local max_i = 0
    for k in pairs(tbl) do
        if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
            return false, 0
        end
        count = count + 1
        if k > max_i then max_i = k end
    end
    return count > 0 and count == max_i, count
end

local function encode_val(v, indent, level)
    local t = type(v)
    if v == nil then
        return "null"
    elseif t == "boolean" then
        return v and "true" or "false"
    elseif t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then
            error("json.encode cannot serialize non-finite number", 0)
        end
        return tostring(v)
    elseif t == "string" then
        return escape_str(v)
    elseif t == "table" then
        local arr, n = is_array(v)
        if arr then
            local parts = {}
            for i = 1, n do
                parts[i] = encode_val(v[i], indent, level + 1)
            end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do
            if type(k) ~= "string" then
                error("json.encode object keys must be strings", 0)
            end
            keys[#keys + 1] = k
        end
        table.sort(keys)
        if #keys == 0 then
            return "{}"
        end
        local pad = indent and string.rep(" ", indent * (level + 1)) or ""
        local close_pad = indent and string.rep(" ", indent * level) or ""
        local sep = indent and ",\n" or ","
        local colon = indent and ": " or ":"
        local parts = {}
        for i = 1, #keys do
            local k = keys[i]
            parts[i] = pad .. escape_str(k) .. colon .. encode_val(v[k], indent, level + 1)
        end
        if indent then
            return "{\n" .. table.concat(parts, sep) .. "\n" .. close_pad .. "}"
        end
        return "{" .. table.concat(parts, sep) .. "}"
    end
    error("json.encode unsupported type: " .. t, 0)
end

function M.encode(v, opts)
    local indent = type(opts) == "table" and opts.indent or 2
    return encode_val(v, indent, 0)
end

return M
