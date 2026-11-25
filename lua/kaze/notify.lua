local fs = require("kaze.fs")
local json = require("kaze.json")

local M = {}

local MAX_ITEMS = 25
local seq = 0

local function clean_str(s)
    if s == nil then
        return ""
    end
    local str = tostring(s)
    str = str:gsub("[\r\n\t]+", " ")
    str = str:gsub("[%z\1-\31\127]", "")
    return (str:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function json_escape(s)
    return (tostring(s):gsub('[\\"%c]', function(c)
        if c == "\\" then return "\\\\" end
        if c == '"' then return '\\"' end
        if c == "\b" then return "\\b" end
        if c == "\f" then return "\\f" end
        if c == "\n" then return "\\n" end
        if c == "\r" then return "\\r" end
        if c == "\t" then return "\\t" end
        return string.format("\\u%04x", c:byte())
    end))
end

local function is_array(tbl)
    local count = 0
    local max_idx = 0
    for k, _ in pairs(tbl) do
        if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
            return false
        end
        count = count + 1
        if k > max_idx then
            max_idx = k
        end
    end
    return count == max_idx
end

function M.encode_json(val)
    local t = type(val)
    if val == nil then
        return "null"
    elseif t == "boolean" then
        return val and "true" or "false"
    elseif t == "number" then
        if val ~= val or val == math.huge or val == -math.huge then
            return "null"
        end
        if math.type and math.type(val) == "integer" then
            return string.format("%d", val)
        end
        return string.format("%.12g", val)
    elseif t == "string" then
        return '"' .. json_escape(val) .. '"'
    elseif t == "table" then
        if next(val) == nil then
            return "[]"
        end
        if is_array(val) then
            local parts = {}
            for i = 1, #val do
                parts[i] = M.encode_json(val[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k, _ in pairs(val) do
            if type(k) == "string" then
                keys[#keys + 1] = k
            end
        end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do
            parts[#parts + 1] = '"' .. json_escape(k) .. '":' .. M.encode_json(val[k])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

function M.path()
    local dir = fs.runtime_dir()
    if not dir then
        return nil
    end
    return dir .. "/notifications.json"
end

local function service_active(unit)
    if not fs.command_exists("systemctl") then
        return false
    end
    local ok = os.execute("systemctl --user is-active --quiet " .. fs.shell_quote(unit) .. " >/dev/null 2>&1")
    return ok == true or ok == 0
end

local function load_stored()
    local p = M.path()
    if not p then
        return {}
    end
    local raw = fs.read_file(p)
    if not raw or not raw:find("%S") then
        return {}
    end
    local ok, decoded = pcall(json.decode, raw)
    if not ok or type(decoded) ~= "table" then
        return {}
    end
    local items = {}
    for _, item in ipairs(decoded) do
        if type(item) == "table" and item.app ~= "kaze-osd" then
            items[#items + 1] = {
                id = tostring(item.id or ""),
                ts = tonumber(item.ts) or 0,
                time = clean_str(item.time or ""),
                app = clean_str(item.app or "kaze"),
                icon = clean_str(item.icon or ""),
                urgency = clean_str(item.urgency or "normal"),
                summary = clean_str(item.summary or ""),
                body = clean_str(item.body or ""),
            }
        end
        if #items >= MAX_ITEMS then
            break
        end
    end
    return items
end

local function save_stored(items)
    local ok_dir, dir = pcall(fs.private_runtime_dir)
    if not ok_dir or not dir then
        return false
    end
    local capped = {}
    for i = 1, math.min(MAX_ITEMS, #items) do
        capped[i] = items[i]
    end
    local encoded = M.encode_json(capped) .. "\n"
    local ok_write = pcall(fs.write_atomic, dir .. "/notifications.json", encoded)
    return ok_write == true
end

local function normalize_urgency(u)
    local s = clean_str(u):lower()
    if s == "low" or s == "normal" or s == "critical" then
        return s
    end
    return "normal"
end

function M.record(entry)
    if type(entry) ~= "table" then
        return false
    end
    local app = clean_str(entry.app or "kaze")
    if app == "kaze-osd" then
        return false
    end

    local ts = tonumber(entry.ts) or os.time()
    seq = seq + 1
    local id = entry.id
    if id == nil or tostring(id) == "" then
        id = string.format("%d-%d", ts, seq)
    else
        id = tostring(id)
    end

    local item = {
        id = id,
        ts = ts,
        time = clean_str(entry.time) ~= "" and clean_str(entry.time) or os.date("%H:%M", ts),
        app = app ~= "" and app or "kaze",
        icon = clean_str(entry.icon or ""),
        urgency = normalize_urgency(entry.urgency),
        summary = clean_str(entry.summary or ""),
        body = clean_str(entry.body or ""),
    }

    local items = load_stored()
    table.insert(items, 1, item)
    while #items > MAX_ITEMS do
        table.remove(items)
    end
    if not save_stored(items) then
        return false
    end
    return item
end

local OSD_SUMMARIES = {
    ["󰕿  Volume"] = true,
    ["󰖀  Volume"] = true,
    ["󰕾  Volume"] = true,
    ["󰖁  Volume Muted"] = true,
    ["󰍬  Microphone"] = true,
    ["󰍭  Microphone Muted"] = true,
    ["󰃠  Brightness"] = true,
    ["󰎊  Now Playing"] = true,
}

local function is_osd_summary(summary)
    return OSD_SUMMARIES[summary] == true
end

local function parse_fnott_list(raw)
    local out = {}
    if type(raw) ~= "string" then
        return out
    end
    for line in raw:gmatch("[^\r\n]+") do
        local fid_s, summary = line:match("^%s*(%d+):%s*(.-)%s*$")
        if fid_s then
            local clean = clean_str(summary)
            if clean ~= "" and not is_osd_summary(clean) then
                out[#out + 1] = {
                    fnott_id = tonumber(fid_s),
                    summary = clean,
                }
            end
        end
    end
    return out
end

local function parse_mako_list(raw)
    local out = {}
    if type(raw) ~= "string" then
        return out
    end
    local cur = nil
    local function flush()
        if cur and cur.app ~= "kaze-osd" then
            out[#out + 1] = cur
        end
        cur = nil
    end
    for line in raw:gmatch("[^\r\n]+") do
        local mid_s, summary = line:match("^Notification%s+(%d+):%s*(.-)%s*$")
        if mid_s then
            flush()
            cur = {
                fnott_id = tonumber(mid_s),
                summary = clean_str(summary),
                app = "Desktop",
                urgency = "normal",
                body = "",
            }
        elseif cur then
            local app = line:match("^%s+App name:%s*(.-)%s*$")
            local urg = line:match("^%s+Urgency:%s*(.-)%s*$")
            local body = line:match("^%s+Body:%s*(.-)%s*$")
            if app and app ~= "" then
                cur.app = clean_str(app)
            elseif urg and urg ~= "" then
                cur.urgency = normalize_urgency(urg)
            elseif body and body ~= "" then
                cur.body = clean_str(body)
            end
        end
    end
    flush()
    return out
end

local function merge_live(items, live_entries, id_prefix)
    local live_only = {}
    for _, live in ipairs(live_entries) do
        local matched = false
        for _, item in ipairs(items) do
            if not item.fnott_id and item.summary == live.summary then
                item.fnott_id = live.fnott_id
                matched = true
                break
            end
        end
        if not matched then
            local now_ts = os.time()
            live_only[#live_only + 1] = {
                id = id_prefix .. tostring(live.fnott_id),
                fnott_id = live.fnott_id,
                ts = now_ts,
                time = os.date("%H:%M", now_ts),
                app = (live.app and live.app ~= "") and live.app or "Desktop",
                icon = "",
                urgency = live.urgency or "normal",
                summary = live.summary,
                body = live.body or "",
                live = true,
            }
        end
    end

    if #live_only == 0 then
        return items
    end
    local merged = {}
    for _, entry in ipairs(live_only) do
        merged[#merged + 1] = entry
    end
    for _, item in ipairs(items) do
        merged[#merged + 1] = item
    end
    while #merged > MAX_ITEMS do
        table.remove(merged)
    end
    return merged
end

function M.list()
    local items = load_stored()

    if fs.command_exists("fnottctl") and service_active("fnott.service") then
        local raw = fs.capture("fnottctl list 2>/dev/null")
        local live = parse_fnott_list(raw)
        if #live > 0 then
            items = merge_live(items, live, "fnott:")
        end
    elseif fs.command_exists("makoctl") and service_active("mako.service") then
        local raw_list = fs.capture("makoctl list 2>/dev/null") or ""
        local raw_hist = fs.capture("makoctl history 2>/dev/null") or ""
        local live = parse_mako_list(raw_list .. "\n" .. raw_hist)
        if #live > 0 then
            items = merge_live(items, live, "mako:")
        end
    end

    return items
end

function M.dismiss(id, fnott_id)
    if id ~= nil then
        local sid = tostring(id)
        if fnott_id == nil then
            fnott_id = sid:match("^fnott:(%d+)$") or sid:match("^mako:(%d+)$")
        end
        local items = load_stored()
        local kept = {}
        local changed = false
        for _, item in ipairs(items) do
            if tostring(item.id) == sid then
                changed = true
            else
                kept[#kept + 1] = item
            end
        end
        if changed then
            save_stored(kept)
        end
    end

    if fnott_id ~= nil then
        local fid = tostring(fnott_id)
        if fid:match("^%d+$") then
            if fs.command_exists("fnottctl") and service_active("fnott.service") then
                os.execute("fnottctl dismiss " .. fid .. " >/dev/null 2>&1 || true")
            elseif fs.command_exists("makoctl") and service_active("mako.service") then
                os.execute("makoctl dismiss -n " .. fid .. " >/dev/null 2>&1 || true")
            end
        end
    end
end

function M.clear_all()
    save_stored({})
    if fs.command_exists("fnottctl") and service_active("fnott.service") then
        os.execute("fnottctl dismiss all >/dev/null 2>&1 || true")
    elseif fs.command_exists("makoctl") and service_active("mako.service") then
        os.execute("makoctl dismiss --all >/dev/null 2>&1 || true")
    end
end

function M.rel_time(ts, fallback_hhmm)
    local n = tonumber(ts)
    if not n or n <= 0 then
        return fallback_hhmm or ""
    end
    local diff = os.time() - n
    if diff < 60 then
        return "now"
    elseif diff < 3600 then
        return string.format("%dm ago", math.floor(diff / 60))
    elseif diff < 86400 then
        return string.format("%dh ago", math.floor(diff / 3600))
    end
    if fallback_hhmm and fallback_hhmm ~= "" then
        return fallback_hhmm
    end
    return os.date("%H:%M", n)
end

return M
