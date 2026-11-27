-- Blind black-box & brute-force behavioral test suite for bin/kaze-display
-- Derived strictly from the behavioral specification. Uses Lua stdlib only.

local function sh_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

local function write_file(path, content)
  local f, err = io.open(path, "wb")
  if not f then
    error("write_file(" .. tostring(path) .. ") failed: " .. tostring(err))
  end
  f:write(content)
  f:close()
end

local function file_exists(path)
  local f = io.open(path, "rb")
  if f then
    f:close()
    return true
  end
  return false
end

local function exec_code(cmd)
  local ok, why, code = os.execute(cmd)
  if type(ok) == "number" then
    return ok
  end
  if ok == true then
    return 0
  end
  if why == "exit" and type(code) == "number" then
    return code
  end
  if why == "signal" and type(code) == "number" then
    return 128 + code
  end
  return 1
end

local function pid_alive(pid)
  local n = tonumber(pid)
  if not n or n <= 1 then
    return false
  end
  return exec_code("/usr/bin/kill -0 " .. math.floor(n) .. " 2>/dev/null") == 0
end

local function wait_pid_dead(pid, max_iters)
  local n = tonumber(pid)
  if not n or n <= 1 then
    return true
  end
  for _ = 1, (max_iters or 25) do
    if not pid_alive(n) then
      return true
    end
    os.execute("/usr/bin/sleep 0.04")
  end
  return not pid_alive(n)
end

-- Pure-Lua JSON encoder & decoder (stdlib only)
local JSON_ARRAY_MT = { __json_type = "array" }
local JSON_OBJECT_MT = { __json_type = "object" }

local function jarray(t)
  return setmetatable(t or {}, JSON_ARRAY_MT)
end

local function jobject(t)
  return setmetatable(t or {}, JSON_OBJECT_MT)
end

local function json_escape_str(s)
  return '"' .. s:gsub('[%z\1-\31\\"]', function(c)
    if c == '"' then return '\\"' end
    if c == "\\" then return "\\\\" end
    if c == "\b" then return "\\b" end
    if c == "\f" then return "\\f" end
    if c == "\n" then return "\\n" end
    if c == "\r" then return "\\r" end
    if c == "\t" then return "\\t" end
    return string.format("\\u%04x", string.byte(c))
  end) .. '"'
end

local function is_json_array(t)
  local mt = getmetatable(t)
  if mt == JSON_ARRAY_MT then
    return true
  end
  if mt == JSON_OBJECT_MT then
    return false
  end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
      return false
    end
    n = n + 1
  end
  return n > 0 and n == #t
end

local function json_encode(v)
  local tv = type(v)
  if v == nil then
    return "null"
  elseif tv == "boolean" then
    return v and "true" or "false"
  elseif tv == "number" then
    if v ~= v or v == math.huge or v == -math.huge then
      return "null"
    end
    return tostring(v)
  elseif tv == "string" then
    return json_escape_str(v)
  elseif tv == "table" then
    if is_json_array(v) then
      local parts = {}
      for i = 1, #v do
        parts[i] = json_encode(v[i])
      end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local keys = {}
      for k in pairs(v) do
        keys[#keys + 1] = tostring(k)
      end
      table.sort(keys)
      local parts = {}
      for i = 1, #keys do
        local k = keys[i]
        parts[i] = json_escape_str(k) .. ":" .. json_encode(v[k])
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  error("json_encode unsupported type: " .. tv)
end

local function json_decode(s)
  if type(s) ~= "string" then
    return nil, "not a string"
  end
  local pos = 1
  local len = #s

  local function skip_ws()
    while pos <= len do
      local b = s:byte(pos)
      if b == 32 or b == 9 or b == 10 or b == 13 then
        pos = pos + 1
      else
        break
      end
    end
  end

  local parse_value

  local function parse_string()
    pos = pos + 1
    local out = {}
    while pos <= len do
      local c = s:sub(pos, pos)
      if c == '"' then
        pos = pos + 1
        return table.concat(out)
      elseif c == "\\" then
        pos = pos + 1
        local esc = s:sub(pos, pos)
        if esc == '"' or esc == "\\" or esc == "/" then
          out[#out + 1] = esc
          pos = pos + 1
        elseif esc == "b" then out[#out + 1] = "\b"; pos = pos + 1
        elseif esc == "f" then out[#out + 1] = "\f"; pos = pos + 1
        elseif esc == "n" then out[#out + 1] = "\n"; pos = pos + 1
        elseif esc == "r" then out[#out + 1] = "\r"; pos = pos + 1
        elseif esc == "t" then out[#out + 1] = "\t"; pos = pos + 1
        elseif esc == "u" then
          local hex = s:sub(pos + 1, pos + 4)
          local code = tonumber(hex, 16)
          if not code then
            return nil, "invalid \\u escape at " .. pos
          end
          if utf8 and utf8.char then
            out[#out + 1] = utf8.char(code)
          elseif code < 128 then
            out[#out + 1] = string.char(code)
          else
            out[#out + 1] = "?"
          end
          pos = pos + 5
        else
          return nil, "invalid escape \\" .. esc
        end
      else
        out[#out + 1] = c
        pos = pos + 1
      end
    end
    return nil, "unterminated string"
  end

  local function parse_number()
    local start = pos
    if s:sub(pos, pos) == "-" then pos = pos + 1 end
    while pos <= len and s:sub(pos, pos):match("%d") do pos = pos + 1 end
    if s:sub(pos, pos) == "." then
      pos = pos + 1
      while pos <= len and s:sub(pos, pos):match("%d") do pos = pos + 1 end
    end
    local e = s:sub(pos, pos)
    if e == "e" or e == "E" then
      pos = pos + 1
      local sign = s:sub(pos, pos)
      if sign == "+" or sign == "-" then pos = pos + 1 end
      while pos <= len and s:sub(pos, pos):match("%d") do pos = pos + 1 end
    end
    local num = tonumber(s:sub(start, pos - 1))
    if not num then
      return nil, "invalid number at " .. start
    end
    return num
  end

  local function parse_array()
    pos = pos + 1
    local arr = {}
    skip_ws()
    if s:sub(pos, pos) == "]" then
      pos = pos + 1
      return arr
    end
    while true do
      skip_ws()
      local val, err = parse_value()
      if err then return nil, err end
      arr[#arr + 1] = val
      skip_ws()
      local c = s:sub(pos, pos)
      if c == "]" then
        pos = pos + 1
        return arr
      elseif c == "," then
        pos = pos + 1
      else
        return nil, "expected ',' or ']' at " .. pos
      end
    end
  end

  local function parse_object()
    pos = pos + 1
    local obj = {}
    skip_ws()
    if s:sub(pos, pos) == "}" then
      pos = pos + 1
      return obj
    end
    while true do
      skip_ws()
      if s:sub(pos, pos) ~= '"' then
        return nil, "expected string key at " .. pos
      end
      local key, kerr = parse_string()
      if kerr then return nil, kerr end
      skip_ws()
      if s:sub(pos, pos) ~= ":" then
        return nil, "expected ':' at " .. pos
      end
      pos = pos + 1
      skip_ws()
      local val, verr = parse_value()
      if verr then return nil, verr end
      obj[key] = val
      skip_ws()
      local c = s:sub(pos, pos)
      if c == "}" then
        pos = pos + 1
        return obj
      elseif c == "," then
        pos = pos + 1
      else
        return nil, "expected ',' or '}' at " .. pos
      end
    end
  end

  parse_value = function()
    skip_ws()
    if pos > len then
      return nil, "unexpected EOF"
    end
    local c = s:sub(pos, pos)
    if c == '"' then return parse_string()
    elseif c == "{" then return parse_object()
    elseif c == "[" then return parse_array()
    elseif c == "-" or c:match("%d") then return parse_number()
    elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
    elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
    elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil
    end
    return nil, "unexpected token '" .. c .. "' at " .. pos
  end

  local val, err = parse_value()
  if err then return nil, err end
  skip_ws()
  if pos <= len then
    return nil, "trailing characters at " .. pos
  end
  return val
end

-- Universal Lua syntax & table inspector for monitors.lua (blind to exact DSL)
local function inspect_monitors_lua_source(raw, source_name)
  local chunk, load_err = load(raw, source_name or "monitors.lua", "t")
  if not chunk then
    return nil, (source_name or "monitors.lua") .. " is not valid Lua: " .. tostring(load_err)
  end

  local collected = {}
  local by_output = {}

  local function record_table(t, hint_name)
    if type(t) ~= "table" then return end
    local out_name = t.output or t.name or t.monitor or hint_name
    if type(out_name) == "string" and (t.position ~= nil or t.mode ~= nil or t.disabled ~= nil or t.mirror ~= nil or t.scale ~= nil) then
      local copy = {}
      for k, v in pairs(t) do
        copy[k] = v
      end
      copy._output = out_name
      collected[#collected + 1] = copy
      by_output[out_name] = copy
      return
    end
    for k, v in pairs(t) do
      if type(v) == "table" then
        record_table(v, type(k) == "string" and k or nil)
      end
    end
  end

  local make_proxy
  make_proxy = function()
    local p = {}
    setmetatable(p, {
      __index = function(_, _)
        return make_proxy()
      end,
      __newindex = function(_, k, v)
        if type(v) == "table" then
          record_table(v, type(k) == "string" and k or nil)
        end
      end,
      __call = function(_, ...)
        local args = { ... }
        local hint = nil
        for i = 1, #args do
          if type(args[i]) == "string" and not hint then
            hint = args[i]
          elseif type(args[i]) == "table" then
            record_table(args[i], hint)
          end
        end
        return make_proxy()
      end,
    })
    return p
  end

  local env = {
    pairs = pairs,
    ipairs = ipairs,
    next = next,
    tostring = tostring,
    tonumber = tonumber,
    type = type,
    table = table,
    string = string,
    math = math,
    require = function() return make_proxy() end,
  }
  setmetatable(env, {
    __index = function(_, _)
      return make_proxy()
    end,
    __newindex = function(t, k, v)
      rawset(t, k, v)
      if type(v) == "table" then
        record_table(v, type(k) == "string" and k or nil)
      end
    end,
  })

  local sb_chunk = load(raw, source_name or "monitors.lua", "t", env)
  if sb_chunk then
    local ok, ret = pcall(sb_chunk)
    if ok and type(ret) == "table" then
      record_table(ret, nil)
    end
  end

  return {
    raw = raw,
    list = collected,
    by_output = by_output,
  }
end

local function inspect_monitors_lua(path)
  local raw = read_file(path)
  if not raw then
    return nil, "monitors.lua does not exist: " .. tostring(path)
  end
  return inspect_monitors_lua_source(raw, path)
end

-- Embedded mock scripts written into each isolated sandbox
local MOCK_HYPRCTL_LUA = [=[#!/usr/bin/env lua
local mock_dir = os.getenv("MOCK_DIR")
if not mock_dir or mock_dir == "" then
  io.stderr:write("mock hyprctl: MOCK_DIR unset\n")
  os.exit(1)
end

local function read_all(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local d = f:read("*a")
  f:close()
  return d
end

local function write_all(p, s)
  local f = assert(io.open(p, "wb"))
  f:write(s)
  f:close()
end

local function append_line(p, line)
  local f = assert(io.open(p, "ab"))
  f:write(line .. "\n")
  f:close()
end

local function j_esc(s)
  return '"' .. s:gsub('[%z\1-\31\\"]', function(c)
    if c == '"' then return '\\"' end
    if c == "\\" then return "\\\\" end
    if c == "\n" then return "\\n" end
    if c == "\r" then return "\\r" end
    if c == "\t" then return "\\t" end
    return string.format("\\u%04x", string.byte(c))
  end) .. '"'
end

local function j_enc(v)
  local tv = type(v)
  if v == nil then return "null"
  elseif tv == "boolean" then return v and "true" or "false"
  elseif tv == "number" then return tostring(v)
  elseif tv == "string" then return j_esc(v)
  elseif tv == "table" then
    local mt = getmetatable(v)
    local is_arr = (mt and mt.__arr)
    if not is_arr then
      local n = 0
      is_arr = true
      for k in pairs(v) do
        if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
          is_arr = false
          break
        end
        n = n + 1
      end
      if n == 0 or n ~= #v then is_arr = false end
    end
    if is_arr then
      local p = {}
      for i = 1, #v do p[i] = j_enc(v[i]) end
      return "[" .. table.concat(p, ",") .. "]"
    else
      local ks = {}
      for k in pairs(v) do ks[#ks + 1] = tostring(k) end
      table.sort(ks)
      local p = {}
      for i = 1, #ks do p[i] = j_esc(ks[i]) .. ":" .. j_enc(v[ks[i]]) end
      return "{" .. table.concat(p, ",") .. "}"
    end
  end
  return "null"
end

local function j_dec(s)
  local pos, len = 1, #s
  local function ws()
    while pos <= len do
      local b = s:byte(pos)
      if b == 32 or b == 9 or b == 10 or b == 13 then pos = pos + 1 else break end
    end
  end
  local pv
  local function pstr()
    pos = pos + 1
    local o = {}
    while pos <= len do
      local c = s:sub(pos, pos)
      if c == '"' then pos = pos + 1; return table.concat(o)
      elseif c == "\\" then
        pos = pos + 1
        local e = s:sub(pos, pos)
        if e == "n" then o[#o + 1] = "\n"
        elseif e == "r" then o[#o + 1] = "\r"
        elseif e == "t" then o[#o + 1] = "\t"
        else o[#o + 1] = e end
        pos = pos + 1
      else
        o[#o + 1] = c
        pos = pos + 1
      end
    end
    return table.concat(o)
  end
  local function pnum()
    local st = pos
    if s:sub(pos, pos) == "-" then pos = pos + 1 end
    while pos <= len and s:sub(pos, pos):match("[%d%.eE%+%-]") do pos = pos + 1 end
    return tonumber(s:sub(st, pos - 1))
  end
  local function parr()
    pos = pos + 1
    local a = setmetatable({}, { __arr = true })
    ws()
    if s:sub(pos, pos) == "]" then pos = pos + 1; return a end
    while true do
      ws(); a[#a + 1] = pv(); ws()
      local c = s:sub(pos, pos)
      if c == "]" then pos = pos + 1; return a end
      pos = pos + 1
    end
  end
  local function pobj()
    pos = pos + 1
    local o = {}
    ws()
    if s:sub(pos, pos) == "}" then pos = pos + 1; return o end
    while true do
      ws(); local k = pstr(); ws(); pos = pos + 1; ws()
      o[k] = pv(); ws()
      local c = s:sub(pos, pos)
      if c == "}" then pos = pos + 1; return o end
      pos = pos + 1
    end
  end
  pv = function()
    ws()
    local c = s:sub(pos, pos)
    if c == '"' then return pstr()
    elseif c == "{" then return pobj()
    elseif c == "[" then return parr()
    elseif c == "-" or c:match("%d") then return pnum()
    elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
    elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
    elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil
    end
  end
  return pv()
end

local function load_monitors()
  local raw = read_all(mock_dir .. "/monitors_all.json") or "[]"
  return j_dec(raw) or setmetatable({}, { __arr = true })
end

local function save_monitors(mons)
  setmetatable(mons, { __arr = true })
  write_all(mock_dir .. "/monitors_all.json", j_enc(mons))
end

local function create_headless(name)
  local mons = load_monitors()
  for i = 1, #mons do
    if mons[i].name == name then
      return
    end
  end
  mons[#mons + 1] = {
    id = 99,
    name = name,
    description = "Headless output (" .. name .. ")",
    width = 1920,
    height = 1080,
    x = 0,
    y = 0,
    refreshRate = 60.0,
    scale = 1.0,
    disabled = false,
    focused = false,
    mirrorOf = "none",
    activeWorkspace = { id = 99, name = "99" },
    hardwareDetails = { backend = "headless" },
  }
  save_monitors(mons)
end

local function remove_output(name)
  local mons = load_monitors()
  local out = setmetatable({}, { __arr = true })
  for i = 1, #mons do
    if mons[i].name ~= name then
      out[#out + 1] = mons[i]
    end
  end
  save_monitors(out)
end

local function record_eval_chunk(code)
  local raw = read_all(mock_dir .. "/eval_chunks.json")
  local arr = (raw and j_dec(raw)) or setmetatable({}, { __arr = true })
  arr[#arr + 1] = code
  setmetatable(arr, { __arr = true })
  write_all(mock_dir .. "/eval_chunks.json", j_enc(arr))
end

local function handle_mutation(cmd_str)
  local created = cmd_str:match("^output%s+create%s+headless%s+(%S+)")
  if created then
    create_headless(created)
    return
  end
  local removed = cmd_str:match("^output%s+remove%s+(%S+)")
  if removed then
    remove_output(removed)
    return
  end
  local ws, mon = cmd_str:match("^dispatch%s+moveworkspacetomonitor%s+(%S+)%s+(%S+)")
  if ws and mon then
    local wsid = tonumber(ws)
    local mons = load_monitors()
    for i = 1, #mons do
      if mons[i].name == mon then
        mons[i].activeWorkspace = { id = wsid or 1, name = tostring(ws) }
      end
    end
    save_monitors(mons)
    local wraw = read_all(mock_dir .. "/workspaces.json")
    if wraw and wsid then
      local wss = j_dec(wraw) or setmetatable({}, { __arr = true })
      local found = false
      for i = 1, #wss do
        if wss[i].id == wsid then
          wss[i].monitor = mon
          found = true
          break
        end
      end
      if not found then
        wss[#wss + 1] = { id = wsid, name = tostring(wsid), monitor = mon, windows = 0 }
      end
      setmetatable(wss, { __arr = true })
      write_all(mock_dir .. "/workspaces.json", j_enc(wss))
    end
  end
end

local raw_args = {}
for i = 1, #arg do
  raw_args[i] = arg[i]
end
append_line(mock_dir .. "/hyprctl.log", table.concat(raw_args, " "))

local json_mode = false
local batch_mode = false
local pos_args = {}
for i = 1, #arg do
  local a = arg[i]
  if a == "-j" or a == "--json" then
    json_mode = true
  elseif a == "--batch" then
    batch_mode = true
  elseif a == "-q" then
    -- ignore quiet flag
  else
    pos_args[#pos_args + 1] = a
  end
end

if batch_mode then
  local batch = pos_args[1] or ""
  for part in batch:gmatch("[^;]+") do
    local trimmed = part:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed ~= "" then
      append_line(mock_dir .. "/hyprctl_ops.log", trimmed)
      handle_mutation(trimmed)
    end
  end
  io.write("ok\n")
  os.exit(0)
end

local cmd = pos_args[1] or ""
local sub = pos_args[2] or ""

if json_mode and cmd == "monitors" then
  local mons = load_monitors()
  if sub == "all" then
    io.write(j_enc(mons) .. "\n")
  else
    local enabled = setmetatable({}, { __arr = true })
    for i = 1, #mons do
      if not mons[i].disabled then
        enabled[#enabled + 1] = mons[i]
      end
    end
    io.write(j_enc(enabled) .. "\n")
  end
  os.exit(0)
elseif json_mode and cmd == "workspaces" then
  io.write((read_all(mock_dir .. "/workspaces.json") or "[]") .. "\n")
  os.exit(0)
elseif json_mode and cmd == "clients" then
  io.write((read_all(mock_dir .. "/clients.json") or "[]") .. "\n")
  os.exit(0)
elseif json_mode and cmd == "activewindow" then
  io.write((read_all(mock_dir .. "/activewindow.json") or "{}") .. "\n")
  os.exit(0)
elseif json_mode and cmd == "locked" then
  io.write((read_all(mock_dir .. "/locked.json") or '{"locked":false}') .. "\n")
  os.exit(0)
elseif json_mode and cmd == "layers" then
  io.write((read_all(mock_dir .. "/layers.json") or "{}") .. "\n")
  os.exit(0)
end

if cmd == "eval" then
  local code_parts = {}
  for i = 2, #pos_args do code_parts[#code_parts + 1] = pos_args[i] end
  record_eval_chunk(table.concat(code_parts, " "))
end

local op_line = table.concat(pos_args, " ")
append_line(mock_dir .. "/hyprctl_ops.log", op_line)
handle_mutation(op_line)
io.write("ok\n")
os.exit(0)
]=]

local MOCK_NOCTALIA_LUA = [=[#!/usr/bin/env lua
local mock_dir = os.getenv("MOCK_DIR")
if not mock_dir or mock_dir == "" then
  io.stderr:write("mock noctalia: MOCK_DIR unset\n")
  os.exit(1)
end

local function read_all(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local d = f:read("*a")
  f:close()
  return d
end

local function write_all(p, s)
  local f = assert(io.open(p, "wb"))
  f:write(s)
  f:close()
end

local function append_line(p, line)
  local f = assert(io.open(p, "ab"))
  f:write(line .. "\n")
  f:close()
end

local raw = {}
for i = 1, #arg do raw[i] = arg[i] end
append_line(mock_dir .. "/noctalia.log", table.concat(raw, " "))

if arg[1] == "msg" then
  local sub = arg[2] or ""
  if sub == "dnd-status" then
    local st = (read_all(mock_dir .. "/dnd_status") or "off"):gsub("%s+$", "")
    io.write(st .. "\n")
    os.exit(0)
  elseif sub == "dnd-on" then
    write_all(mock_dir .. "/dnd_status", "on\n")
    os.exit(0)
  elseif sub == "dnd-off" then
    write_all(mock_dir .. "/dnd_status", "off\n")
    os.exit(0)
  else
    os.exit(0)
  end
elseif arg[1] == "dmenu" then
  local stdin_data = io.read("*a") or ""
  local cnt = tonumber(read_all(mock_dir .. "/dmenu_count") or "0") or 0
  cnt = cnt + 1
  write_all(mock_dir .. "/dmenu_count", tostring(cnt))
  write_all(mock_dir .. "/dmenu_stdin_" .. cnt .. ".txt", stdin_data)
  append_line(mock_dir .. "/dmenu_calls.log", table.concat(raw, " "))

  local resp_raw = read_all(mock_dir .. "/dmenu_responses.txt") or ""
  local lines = {}
  for line in (resp_raw .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  if resp_raw == "" then
    lines = {}
  elseif resp_raw:sub(-1) == "\n" then
    table.remove(lines)
  end

  local choice = table.remove(lines, 1)
  if #lines > 0 then
    write_all(mock_dir .. "/dmenu_responses.txt", table.concat(lines, "\n") .. "\n")
  else
    write_all(mock_dir .. "/dmenu_responses.txt", "")
  end

  if not choice or choice == "" or choice == "<<CANCEL>>" then
    os.exit(1)
  elseif choice == "<<CANCEL_OK>>" then
    os.exit(0)
  else
    io.write(choice .. "\n")
    os.exit(0)
  end
end

os.exit(0)
]=]

local MOCK_WL_MIRROR_SH = [=[#!/bin/sh
mock_dir="${MOCK_DIR:-/tmp}"
printf '%s %s\n' "$$" "$*" >> "$mock_dir/wl_mirror.log"
printf '%s\n' "$$" >> "$mock_dir/wl_mirror_pids.txt"
exec </dev/null >/dev/null 2>&1
child=""
cleanup() {
  if [ -n "$child" ]; then
    kill "$child" 2>/dev/null || true
  fi
  printf '%s TERM\n' "$$" >> "$mock_dir/wl_mirror_events.log"
  exit 0
}
trap cleanup TERM INT HUP
sleep 30 &
child=$!
wait "$child"
exit 0
]=]

local MOCK_LOGINCTL_SH = [=[#!/bin/sh
mock_dir="${MOCK_DIR:-/tmp}"
printf '%s\n' "$*" >> "$mock_dir/loginctl.log"
if [ -f "$mock_dir/locked_hint" ]; then
  cat "$mock_dir/locked_hint"
else
  printf 'no\n'
fi
exit 0
]=]

local MOCK_NOTIFY_SH = [=[#!/bin/sh
mock_dir="${MOCK_DIR:-/tmp}"
printf '%s\n' "$*" >> "$mock_dir/notify.log"
exit 0
]=]

local COREUTILS = {
  "lua", "readlink", "flock", "env", "nohup", "rm", "mkdir", "kill",
  "cat", "id", "install", "sleep", "grep", "timeout", "ps", "sh", "bash",
  "mv", "cp", "dirname", "basename", "mktemp", "setsid", "tr", "sed",
  "awk", "head", "tail", "wc", "cut", "date", "chmod", "touch", "ln",
  "true", "false", "printf", "test", "[",
}

-- Monitor fixture builders
local function mon_edp(ov)
  local m = {
    id = 0,
    name = "eDP-1",
    description = "Built-in Panel",
    width = 1920,
    height = 1200,
    x = 0,
    y = 0,
    refreshRate = 60.0,
    scale = 1.0,
    disabled = false,
    focused = true,
    mirrorOf = "none",
    activeWorkspace = { id = 1, name = "1" },
    hardwareDetails = { backend = "drm" },
  }
  if ov then for k, v in pairs(ov) do m[k] = v end end
  return m
end

local function mon_ext(name, ov)
  local m = {
    id = 1,
    name = name or "HDMI-A-1",
    description = "External Monitor " .. (name or "HDMI-A-1"),
    width = 2560,
    height = 1440,
    x = 1920,
    y = 0,
    refreshRate = 60.0,
    scale = 1.0,
    disabled = false,
    focused = false,
    mirrorOf = "none",
    activeWorkspace = { id = 2, name = "2" },
    hardwareDetails = { backend = "drm" },
  }
  if ov then for k, v in pairs(ov) do m[k] = v end end
  return m
end

local function mon_share(ov)
  local m = {
    id = 99,
    name = "kaze-share",
    description = "Headless output (kaze-share)",
    width = 1920,
    height = 1080,
    x = 9999,
    y = 0,
    refreshRate = 60.0,
    scale = 1.0,
    disabled = false,
    focused = false,
    mirrorOf = "none",
    activeWorkspace = { id = 9, name = "9" },
    hardwareDetails = { backend = "headless" },
  }
  if ov then for k, v in pairs(ov) do m[k] = v end end
  return m
end

local function log_has_line(log_text, needle)
  if not log_text then return false end
  return log_text:find(needle, 1, true) ~= nil
end

local function log_lines(log_text)
  local out = {}
  if not log_text or log_text == "" then return out end
  for line in log_text:gmatch("[^\r\n]+") do
    out[#out + 1] = line
  end
  return out
end

local function run_suite(test, assert_eq, assert_true, assert_contains, repo_dir)
  local p = io.popen("/usr/bin/readlink -f -- " .. sh_quote(repo_dir))
  local abs_repo = p:read("*l")
  p:close()
  assert_true(abs_repo and abs_repo ~= "", "failed to resolve repo_dir")
  local kaze_display = abs_repo .. "/bin/kaze-display"
  assert_true(file_exists(kaze_display), "kaze-display executable missing at " .. kaze_display)

  local function with_sandbox(fn)
    local mk = io.popen("/usr/bin/mktemp -d /tmp/kaze-bb-display-XXXXXX")
    local root = mk:read("*l")
    mk:close()
    assert_true(root and root:match("^/tmp/kaze%-bb%-display%-"), "failed to create temp sandbox")

    local sb = {
      root = root,
      home = root .. "/home",
      config = root .. "/config",
      data = root .. "/data",
      cache = root .. "/cache",
      state = root .. "/state",
      runtime = root .. "/runtime",
      kaze_runtime = root .. "/runtime/kaze",
      bin = root .. "/bin",
      mock = root .. "/mock",
      extra_pids = {},
      run_seq = 0,
    }

    local function init_sandbox()
      assert_eq(exec_code("/usr/bin/mkdir -p "
        .. sh_quote(sb.home) .. " "
        .. sh_quote(sb.config .. "/hypr") .. " "
        .. sh_quote(sb.data) .. " "
        .. sh_quote(sb.cache) .. " "
        .. sh_quote(sb.state) .. " "
        .. sh_quote(sb.runtime) .. " "
        .. sh_quote(sb.bin) .. " "
        .. sh_quote(sb.mock)), 0, "mkdir sandbox dirs")

      for _, tool in ipairs(COREUTILS) do
        local target = "/usr/bin/" .. tool
        if file_exists(target) then
          exec_code("/usr/bin/ln -sf " .. sh_quote(target) .. " " .. sh_quote(sb.bin .. "/" .. tool))
        end
      end

      write_file(sb.bin .. "/hyprctl", MOCK_HYPRCTL_LUA)
      write_file(sb.bin .. "/kaze-shell", MOCK_NOCTALIA_LUA)
      write_file(sb.bin .. "/wl-mirror", MOCK_WL_MIRROR_SH)
      write_file(sb.bin .. "/loginctl", MOCK_LOGINCTL_SH)
      write_file(sb.bin .. "/notify-send", MOCK_NOTIFY_SH)
      assert_eq(exec_code("/usr/bin/chmod +x "
        .. sh_quote(sb.bin .. "/hyprctl") .. " "
        .. sh_quote(sb.bin .. "/kaze-shell") .. " "
        .. sh_quote(sb.bin .. "/wl-mirror") .. " "
        .. sh_quote(sb.bin .. "/loginctl") .. " "
        .. sh_quote(sb.bin .. "/notify-send")), 0, "chmod mock scripts")

      sb:set_monitors({ mon_edp(), mon_ext("HDMI-A-1") })
      sb:set_workspaces({
        { id = 1, name = "1", monitor = "eDP-1", windows = 1 },
        { id = 2, name = "2", monitor = "HDMI-A-1", windows = 0 },
      })
      sb:set_clients({})
      sb:set_activewindow(jobject({}))
      sb:set_locked(false)
      sb:set_layers(jobject({}))
      sb:set_dnd("off")
      sb:set_locked_hint("no")
    end

    function sb:set_monitors(mons)
      write_file(self.mock .. "/monitors_all.json", json_encode(jarray(mons)))
    end

    function sb:set_workspaces(wss)
      write_file(self.mock .. "/workspaces.json", json_encode(jarray(wss)))
    end

    function sb:set_clients(cls)
      write_file(self.mock .. "/clients.json", json_encode(jarray(cls)))
    end

    function sb:set_activewindow(win)
      write_file(self.mock .. "/activewindow.json", json_encode(win or jobject({})))
    end

    function sb:set_locked(is_locked)
      write_file(self.mock .. "/locked.json", json_encode({ locked = is_locked == true }))
    end

    function sb:set_layers(layers_obj)
      write_file(self.mock .. "/layers.json", json_encode(layers_obj or jobject({})))
    end

    function sb:set_dnd(val)
      write_file(self.mock .. "/dnd_status", tostring(val) .. "\n")
    end

    function sb:get_dnd()
      return (read_file(self.mock .. "/dnd_status") or ""):gsub("%s+$", "")
    end

    function sb:set_locked_hint(val)
      write_file(self.mock .. "/locked_hint", tostring(val) .. "\n")
    end

    function sb:set_dmenu_responses(list)
      if not list or #list == 0 then
        write_file(self.mock .. "/dmenu_responses.txt", "")
      else
        write_file(self.mock .. "/dmenu_responses.txt", table.concat(list, "\n") .. "\n")
      end
    end

    function sb:set_user_lua(content)
      write_file(self.config .. "/hypr/user.lua", content)
    end

    function sb:clear_logs()
      local logs = {
        "hyprctl.log", "hyprctl_ops.log", "eval_chunks.json", "noctalia.log",
        "dmenu_calls.log", "dmenu_count", "wl_mirror.log",
        "wl_mirror_events.log", "loginctl.log", "notify.log",
      }
      for _, name in ipairs(logs) do
        os.remove(self.mock .. "/" .. name)
      end
      for i = 1, 20 do
        os.remove(self.mock .. "/dmenu_stdin_" .. i .. ".txt")
      end
    end

    function sb:hypr_ops()
      return read_file(self.mock .. "/hyprctl_ops.log") or ""
    end

    function sb:eval_chunks()
      local raw = read_file(self.mock .. "/eval_chunks.json")
      if not raw then return {} end
      local arr, err = json_decode(raw)
      assert_true(err == nil, "eval_chunks.json decode error: " .. tostring(err))
      return arr or {}
    end

    function sb:noctalia_log()
      return read_file(self.mock .. "/noctalia.log") or ""
    end

    function sb:dmenu_calls()
      return read_file(self.mock .. "/dmenu_calls.log") or ""
    end

    function sb:dmenu_stdin(idx)
      return read_file(self.mock .. "/dmenu_stdin_" .. tostring(idx or 1) .. ".txt") or ""
    end

    function sb:wl_mirror_log()
      return read_file(self.mock .. "/wl_mirror.log") or ""
    end

    function sb:wl_mirror_pids()
      local out = {}
      local raw = read_file(self.mock .. "/wl_mirror_pids.txt") or ""
      for d in raw:gmatch("%d+") do
        out[#out + 1] = tonumber(d)
      end
      return out
    end

    function sb:state_path()
      return self.kaze_runtime .. "/display-state.json"
    end

    function sb:monitors_lua_path()
      return self.kaze_runtime .. "/monitors.lua"
    end

    function sb:external_revert_path()
      return self.kaze_runtime .. "/external-revert.json"
    end

    function sb:read_state()
      local raw = read_file(self:state_path())
      if not raw then return nil end
      local val, err = json_decode(raw)
      assert_true(err == nil, "display-state.json invalid JSON: " .. tostring(err) .. " raw=" .. raw)
      return val
    end

    function sb:inspect_monitors_lua()
      local info, err = inspect_monitors_lua(self:monitors_lua_path())
      assert_true(info ~= nil, tostring(err))
      return info
    end

    function sb:track_pid(pid)
      local n = tonumber(pid)
      if n and n > 1 then
        self.extra_pids[#self.extra_pids + 1] = n
      end
    end

    function sb:env_prefix(extra_env)
      local vars = {
        "PATH=" .. self.bin,
        "HOME=" .. self.home,
        "USER=kaze-bb",
        "LOGNAME=kaze-bb",
        "TERM=xterm-256color",
        "LC_ALL=C",
        "LANG=C",
        "XDG_CONFIG_HOME=" .. self.config,
        "XDG_DATA_HOME=" .. self.data,
        "XDG_CACHE_HOME=" .. self.cache,
        "XDG_STATE_HOME=" .. self.state,
        "XDG_RUNTIME_DIR=" .. self.runtime,
        "XDG_SESSION_ID=99",
        "WAYLAND_DISPLAY=wayland-bb-0",
        "HYPRLAND_INSTANCE_SIGNATURE=kaze-bb-sig",
        "MOCK_DIR=" .. self.mock,
      }
      if extra_env then
        for k, v in pairs(extra_env) do
          vars[#vars + 1] = tostring(k) .. "=" .. tostring(v)
        end
      end
      local parts = { "/usr/bin/env", "-i" }
      for _, kv in ipairs(vars) do
        parts[#parts + 1] = sh_quote(kv)
      end
      return table.concat(parts, " ")
    end

    function sb:run(args, opts)
      opts = opts or {}
      self.run_seq = self.run_seq + 1
      local out_f = self.root .. "/run_" .. self.run_seq .. ".out"
      local err_f = self.root .. "/run_" .. self.run_seq .. ".err"
      local timeout_sec = opts.timeout or 10

      local argv = { sh_quote(kaze_display) }
      for i = 1, #(args or {}) do
        argv[#argv + 1] = sh_quote(args[i])
      end

      local cmd = self:env_prefix(opts.env)
        .. " /usr/bin/timeout " .. tostring(timeout_sec)
        .. " " .. table.concat(argv, " ")
        .. " </dev/null >" .. sh_quote(out_f) .. " 2>" .. sh_quote(err_f)

      local code = exec_code(cmd)
      local stdout = read_file(out_f) or ""
      local stderr = read_file(err_f) or ""
      return {
        code = code,
        stdout = stdout,
        stderr = stderr,
        combined = stdout .. "\n" .. stderr,
      }
    end

    local function cleanup_sandbox()
      local pids_to_kill = {}
      local pid_file = read_file(sb.mock .. "/wl_mirror_pids.txt")
      if pid_file then
        for line in pid_file:gmatch("%d+") do
          pids_to_kill[tonumber(line)] = true
        end
      end
      for _, pid in ipairs(sb.extra_pids) do
        pids_to_kill[pid] = true
      end
      local raw_state = read_file(sb.kaze_runtime .. "/display-state.json")
      if raw_state then
        local ok_dec, st = pcall(json_decode, raw_state)
        if ok_dec and type(st) == "table" then
          for k, v in pairs(st) do
            if type(k) == "string" and k:find("pid", 1, true) and type(v) == "number" and v > 1 then
              pids_to_kill[v] = true
            end
          end
        end
      end
      local alive_any = false
      for pid in pairs(pids_to_kill) do
        if pid_alive(pid) then
          exec_code("/usr/bin/kill -TERM " .. math.floor(pid) .. " 2>/dev/null")
          alive_any = true
        end
      end
      if alive_any then
        os.execute("/usr/bin/sleep 0.08")
        for pid in pairs(pids_to_kill) do
          if pid_alive(pid) then
            exec_code("/usr/bin/kill -KILL " .. math.floor(pid) .. " 2>/dev/null")
          end
        end
      end
      exec_code("/usr/bin/rm -rf -- " .. sh_quote(sb.root))
    end

    local ok, err = pcall(function()
      init_sandbox()
      fn(sb)
    end)
    cleanup_sandbox()
    if not ok then
      error(err, 0)
    end
  end

  local function assert_mon_entry(info, mon_name, checks, label)
    local ctx = label and ("[" .. label .. "] ") or ""
    local e = info.by_output[mon_name]
    assert_true(e ~= nil, ctx .. "monitors missing entry for " .. mon_name .. "\nraw:\n" .. info.raw)
    for k, expected in pairs(checks) do
      if type(expected) == "function" then
        assert_true(
          expected(e[k], e),
          ctx .. "monitors[" .. mon_name .. "]." .. k .. " check failed; got=" .. tostring(e[k]) .. "\nraw:\n" .. info.raw
        )
      else
        assert_eq(e[k], expected, ctx .. "monitors[" .. mon_name .. "]." .. k)
      end
    end
  end

  -- =========================================================================
  -- 1. CLI validation, help, and --list
  -- =========================================================================
  test("bb.display.cli_validation_and_list", function()
    with_sandbox(function(sb)
      for _, flag in ipairs({ "-h", "--help" }) do
        local r = sb:run({ flag })
        assert_eq(r.code, 0, flag .. " must exit 0; stderr=" .. r.stderr)
        assert_true(#r.combined > 20, flag .. " must print usage text")
        assert_true(
          r.combined:lower():find("usage", 1, true) ~= nil
            or r.combined:find("extend-right", 1, true) ~= nil,
          flag .. " output should describe usage/commands: " .. r.combined
        )
      end

      -- --list with dual monitor + headless monitor
      sb:set_monitors({ mon_edp(), mon_ext("HDMI-A-1"), mon_share() })
      local r_list = sb:run({ "--list" })
      assert_eq(r_list.code, 0, "--list must exit 0; stderr=" .. r_list.stderr)
      assert_contains(r_list.stdout, "eDP-1", "--list must include eDP-1")
      assert_contains(r_list.stdout, "HDMI-A-1", "--list must include HDMI-A-1")

      -- --list with single monitor
      sb:set_monitors({ mon_edp() })
      local r_single = sb:run({ "--list" })
      assert_eq(r_single.code, 0, "single-monitor --list must exit 0")
      assert_contains(r_single.stdout, "eDP-1", "single-monitor --list must include eDP-1")

      -- Spec: Unknown commands/flags -> non-zero exit (exit 2)
      -- Restore dual monitors so CLI parsing is tested independent of monitor count
      sb:set_monitors({ mon_edp(), mon_ext("HDMI-A-1") })
      local invalid_invocations = {
        { "not-a-command" },
        { "--bogus-flag" },
        { "-Z" },
        { "foo", "bar" },
        { "--unknown" },
      }
      for _, argv in ipairs(invalid_invocations) do
        local r = sb:run(argv)
        assert_eq(r.code, 2, "unknown invocation '" .. table.concat(argv, " ") .. "' must exit 2; stderr=" .. r.stderr)
      end
    end)
  end)

  -- =========================================================================
  -- 2. Standard multi-monitor layouts & monitors.lua persistence
  -- =========================================================================
  test("bb.display.extend_layouts_and_monitors_lua", function()
    with_sandbox(function(sb)
      -- extend-right: pins internal at 0x0, external at auto-right, disabled=false, mirror=""
      local r = sb:run({ "extend-right" })
      assert_eq(r.code, 0, "extend-right failed: " .. r.stderr)
      local info = sb:inspect_monitors_lua()
      assert_mon_entry(info, "eDP-1", { position = "0x0", disabled = false, mirror = "" }, "extend-right")
      assert_mon_entry(info, "HDMI-A-1", { position = "auto-right", disabled = false, mirror = "" }, "extend-right")

      -- extend-left
      r = sb:run({ "extend-left" })
      assert_eq(r.code, 0, "extend-left failed: " .. r.stderr)
      info = sb:inspect_monitors_lua()
      assert_mon_entry(info, "eDP-1", { disabled = false, mirror = "" }, "extend-left")
      assert_mon_entry(info, "HDMI-A-1", { position = "auto-left", disabled = false, mirror = "" }, "extend-left")

      -- extend-up
      r = sb:run({ "extend-up" })
      assert_eq(r.code, 0, "extend-up failed: " .. r.stderr)
      info = sb:inspect_monitors_lua()
      assert_mon_entry(info, "eDP-1", { disabled = false, mirror = "" }, "extend-up")
      assert_mon_entry(info, "HDMI-A-1", { position = "auto-up", disabled = false, mirror = "" }, "extend-up")

      -- internal: disables external, enables internal
      r = sb:run({ "internal" })
      assert_eq(r.code, 0, "internal failed: " .. r.stderr)
      info = sb:inspect_monitors_lua()
      assert_mon_entry(info, "eDP-1", { disabled = false }, "internal")
      assert_mon_entry(info, "HDMI-A-1", { disabled = true }, "internal")

      -- external --no-confirm: enables external, disables internal WITHOUT confirmation dmenu
      sb:clear_logs()
      r = sb:run({ "external", "--no-confirm" })
      assert_eq(r.code, 0, "external --no-confirm failed: " .. r.stderr)
      assert_eq(sb:dmenu_calls(), "", "external --no-confirm must not open dmenu confirmation")
      info = sb:inspect_monitors_lua()
      assert_mon_entry(info, "eDP-1", { disabled = true }, "external --no-confirm")
      assert_mon_entry(info, "HDMI-A-1", { disabled = false }, "external --no-confirm")

      -- auto: resets physical monitors to auto (either via hyprctl eval + clearing monitors.lua, or valid monitors.lua)
      sb:clear_logs()
      r = sb:run({ "auto" })
      assert_eq(r.code, 0, "auto failed: " .. r.stderr)
      local auto_info
      if file_exists(sb:monitors_lua_path()) then
        auto_info = sb:inspect_monitors_lua()
      else
        local eval_src = table.concat(sb:eval_chunks(), "\n")
        local parsed, err = inspect_monitors_lua_source(eval_src, "auto_eval")
        assert_true(parsed ~= nil, "auto hyprctl eval invalid Lua: " .. tostring(err))
        auto_info = parsed
      end
      assert_mon_entry(auto_info, "eDP-1", {
        disabled = false,
        mirror = "",
        position = function(v) return tostring(v or ""):find("auto", 1, true) ~= nil end,
      }, "auto")
      assert_mon_entry(auto_info, "HDMI-A-1", {
        disabled = false,
        mirror = "",
        position = function(v) return tostring(v or ""):find("auto", 1, true) ~= nil end,
      }, "auto")
    end)
  end)

  -- =========================================================================
  -- 3. External-only confirmation dialog (revert on cancel vs keep on confirm)
  -- =========================================================================
  test("bb.display.external_confirm_and_revert", function()
    with_sandbox(function(sb)
      -- Cancel / Esc on confirmation dialog -> reverts to laptop enabled, clears revert file
      sb:set_dmenu_responses({ "<<CANCEL>>" })
      sb:clear_logs()
      local r = sb:run({ "external" })
      assert_eq(r.code, 0, "external (cancel/revert) failed: " .. r.stderr)
      assert_true(sb:dmenu_calls() ~= "", "external without --no-confirm must prompt confirmation via dmenu")
      local confirm_menu = sb:dmenu_stdin(1)
      assert_true(#confirm_menu > 0, "external confirmation menu must present options")
      local info = sb:inspect_monitors_lua()
      assert_mon_entry(info, "eDP-1", { disabled = false }, "external revert")
      assert_true(not file_exists(sb:external_revert_path()), "external-revert.json must be cleaned up after revert")

      -- Confirm "Keep External Only" -> keeps eDP-1 disabled and HDMI-A-1 enabled
      local keep_line
      for _, line in ipairs(log_lines(confirm_menu)) do
        if line:lower():find("keep", 1, true) then
          keep_line = line
          break
        end
      end
      assert_true(keep_line ~= nil, "confirmation menu should include a 'Keep' choice; got:\n" .. confirm_menu)
      sb:set_dmenu_responses({ keep_line })
      sb:clear_logs()
      r = sb:run({ "external" })
      assert_eq(r.code, 0, "external (confirm keep) failed: " .. r.stderr)
      info = sb:inspect_monitors_lua()
      assert_mon_entry(info, "eDP-1", { disabled = true }, "external keep")
      assert_mon_entry(info, "HDMI-A-1", { disabled = false }, "external keep")
      assert_true(not file_exists(sb:external_revert_path()), "external-revert.json must be cleaned up after confirm")
    end)
  end)

  -- =========================================================================
  -- 4. Single-monitor graceful handling (no physical external monitor)
  -- =========================================================================
  test("bb.display.single_monitor_graceful_handling", function()
    with_sandbox(function(sb)
      -- Case A: strictly eDP-1 only
      sb:set_monitors({ mon_edp() })
      local cmds = {
        { "extend-right" },
        { "extend-left" },
        { "extend-up" },
        { "mirror" },
        { "mirror-scaled" },
        { "present", "3" },
        { "external", "--no-confirm" },
      }
      for _, argv in ipairs(cmds) do
        local r = sb:run(argv)
        assert_true(r.code ~= 124, "command timed out on single monitor: " .. table.concat(argv, " "))
        assert_true(
          not r.stderr:find("stack traceback:", 1, true),
          "command crashed with Lua traceback on single monitor (" .. table.concat(argv, " ") .. "): " .. r.stderr
        )
        assert_true(
          r.code ~= 0 or #r.combined > 0,
          "single-monitor " .. table.concat(argv, " ") .. " should fail cleanly or emit safe notice"
        )
      end

      -- Case B: eDP-1 + kaze-share headless (still NO physical external!)
      sb:set_monitors({ mon_edp(), mon_share() })
      local r_mir = sb:run({ "mirror" })
      assert_true(not r_mir.stderr:find("stack traceback:", 1, true), "mirror crashed with eDP-1+kaze-share")
      if file_exists(sb:monitors_lua_path()) then
        local info = sb:inspect_monitors_lua()
        if info.by_output["kaze-share"] then
          assert_true(
            (info.by_output["kaze-share"].mirror or "") == "",
            "mirror MUST NEVER target kaze-share!"
          )
        end
      end
      local r_pres = sb:run({ "present", "3" })
      assert_true(not r_pres.stderr:find("stack traceback:", 1, true), "present crashed with eDP-1+kaze-share")
      assert_true(
        not log_has_line(sb:noctalia_log(), "bar-hide kaze-share"),
        "present must not treat headless kaze-share as external display"
      )
    end)
  end)

  -- =========================================================================
  -- 5. Mirror modes (native + scaled wl-mirror) & un-mirror reload
  -- =========================================================================
  test("bb.display.mirror_modes_and_unmirror_reload", function()
    with_sandbox(function(sb)
      -- Dual physical + active kaze-share: native mirror must target HDMI-A-1, NEVER kaze-share
      sb:set_monitors({ mon_edp(), mon_ext("HDMI-A-1"), mon_share() })
      local r = sb:run({ "mirror" })
      assert_eq(r.code, 0, "mirror failed: " .. r.stderr)
      local info = sb:inspect_monitors_lua()
      assert_mon_entry(info, "HDMI-A-1", { mirror = "eDP-1", disabled = false }, "mirror")
      if info.by_output["kaze-share"] then
        assert_true(
          (info.by_output["kaze-share"].mirror or "") ~= "eDP-1",
          "mirror must NEVER set mirror on kaze-share"
        )
      end

      -- mirror-scaled: extended physical layout + fullscreen wl-mirror targeting HDMI-A-1 from eDP-1
      sb:clear_logs()
      r = sb:run({ "mirror-scaled" })
      assert_eq(r.code, 0, "mirror-scaled failed: " .. r.stderr)
      info = sb:inspect_monitors_lua()
      assert_mon_entry(info, "eDP-1", { disabled = false, mirror = "" }, "mirror-scaled")
      assert_mon_entry(info, "HDMI-A-1", { disabled = false, mirror = "" }, "mirror-scaled")
      local wlog = sb:wl_mirror_log()
      assert_contains(wlog, "HDMI-A-1", "mirror-scaled must target HDMI-A-1 in wl-mirror")
      assert_contains(wlog, "eDP-1", "mirror-scaled must mirror eDP-1 in wl-mirror")
      assert_true(not wlog:find("kaze-share", 1, true), "mirror-scaled must NEVER mirror kaze-share")
      local scaled_pids = sb:wl_mirror_pids()
      assert_true(#scaled_pids >= 1 and pid_alive(scaled_pids[#scaled_pids]), "mirror-scaled wl-mirror must be running")

      -- Exiting mirror-scaled via stop-mirror kills the fullscreen wl-mirror process
      local scaled_pid = scaled_pids[#scaled_pids]
      r = sb:run({ "stop-mirror" })
      assert_eq(r.code, 0, "stop-mirror after mirror-scaled failed: " .. r.stderr)
      assert_true(wait_pid_dead(scaled_pid, 25), "stop-mirror must terminate mirror-scaled wl-mirror")

      -- Exiting active native mirror (mirrorOf = "eDP-1") via extend-right triggers hyprctl reload
      -- AND re-pins active kaze-share at 9999x0!
      sb:set_monitors({
        mon_edp(),
        mon_ext("HDMI-A-1", { mirrorOf = "eDP-1" }),
        mon_share({ x = 9999, y = 0 }),
      })
      sb:clear_logs()
      r = sb:run({ "extend-right" })
      assert_eq(r.code, 0, "extend-right from mirrorOf=eDP-1 failed: " .. r.stderr)
      assert_true(
        log_has_line(sb:hypr_ops(), "reload"),
        "exiting active mirror (mirrorOf='eDP-1') via extend-right must trigger hyprctl reload; ops=\n" .. sb:hypr_ops()
      )
      info = sb:inspect_monitors_lua()
      assert_mon_entry(info, "HDMI-A-1", { mirror = "", position = "auto-right", disabled = false }, "unmirror name")
      assert_mon_entry(info, "kaze-share", { position = "9999x0" }, "unmirror name kaze-share")

      -- Exiting active mirror with Hyprland 0.57+ numeric mirrorOf = "0" via stop-mirror
      sb:set_monitors({
        mon_edp({ id = 0 }),
        mon_ext("HDMI-A-1", { mirrorOf = "0" }),
        mon_share({ x = 9999, y = 0 }),
      })
      sb:clear_logs()
      r = sb:run({ "stop-mirror" })
      assert_eq(r.code, 0, "stop-mirror from numeric mirrorOf='0' failed: " .. r.stderr)
      assert_true(
        log_has_line(sb:hypr_ops(), "reload"),
        "exiting active mirror (numeric mirrorOf='0') via stop-mirror must trigger hyprctl reload; ops=\n" .. sb:hypr_ops()
      )
      info = sb:inspect_monitors_lua()
      assert_mon_entry(info, "HDMI-A-1", { mirror = "", disabled = false }, "unmirror numeric")
      assert_mon_entry(info, "kaze-share", { position = "9999x0" }, "unmirror numeric kaze-share")
    end)
  end)

  -- =========================================================================
  -- 6. Present workspace & DND-off restoration
  -- =========================================================================
  test("bb.display.present_workspace_and_dnd_off_restore", function()
    with_sandbox(function(sb)
      sb:set_dnd("off")
      sb:clear_logs()

      local r = sb:run({ "present", "3" })
      assert_eq(r.code, 0, "present 3 failed: " .. r.stderr)

      local hops = sb:hypr_ops()
      assert_true(
        hops:find("3", 1, true) ~= nil and hops:find("HDMI-A-1", 1, true) ~= nil,
        "present 3 must move workspace 3 to HDMI-A-1 via hyprctl; ops=\n" .. hops
      )

      local nlog = sb:noctalia_log()
      assert_contains(nlog, "msg bar-hide HDMI-A-1", "present must hide kaze-shell bar on external")
      assert_contains(nlog, "msg dnd-on", "present must enable DND")
      assert_eq(sb:get_dnd(), "on", "DND should now be on")

      local st = sb:read_state()
      assert_true(st ~= nil, "display-state.json must be created by present")
      assert_eq(st.mode, "present", "state.mode must be 'present'")
      assert_eq(st.dnd_managed, true, "state.dnd_managed must be true")
      assert_eq(st.dnd_was_active, false, "state.dnd_was_active must be false when DND was off")

      -- Stop presentation: must restore DND off and bar-show HDMI-A-1
      sb:clear_logs()
      r = sb:run({ "stop-present" })
      assert_eq(r.code, 0, "stop-present failed: " .. r.stderr)
      local nlog2 = sb:noctalia_log()
      assert_contains(nlog2, "msg dnd-off", "stop-present must restore DND off")
      assert_contains(nlog2, "msg bar-show HDMI-A-1", "stop-present must restore bar on external")
      assert_eq(sb:get_dnd(), "off", "DND must be restored to off")

      local st2 = sb:read_state()
      if st2 then
        assert_true(st2.mode ~= "present", "stop-present must clear mode='present'")
      end

      -- Default workspace argument omitted: `present` opens workspace picker dmenu
      sb:set_dmenu_responses({ "<<CANCEL>>" })
      sb:clear_logs()
      r = sb:run({ "present" })
      assert_eq(r.code, 0, "present without ws_id (Esc cancel) failed: " .. r.stderr)
      assert_contains(sb:dmenu_calls(), "dmenu", "present without ws_id must prompt workspace picker")
      local ws_menu = sb:dmenu_stdin(1)
      local pick_line = log_lines(ws_menu)[1]
      assert_true(pick_line ~= nil and #pick_line > 0, "workspace picker must offer selectable workspace lines")
      sb:set_dmenu_responses({ pick_line })
      r = sb:run({ "present" })
      assert_eq(r.code, 0, "present via workspace picker failed: " .. r.stderr)
      assert_eq(sb:read_state().mode, "present", "present via workspace picker must set mode='present'")
      assert_eq(sb:run({ "stop-present" }).code, 0, "stop-present cleanup failed")
    end)
  end)

  -- =========================================================================
  -- 7. Conditional DND safety when user already had DND ON
  -- =========================================================================
  test("bb.display.present_conditional_dnd_already_on", function()
    with_sandbox(function(sb)
      sb:set_monitors({ mon_edp(), mon_ext("DP-1") })
      sb:set_dnd("on")
      sb:clear_logs()

      local r = sb:run({ "present", "4" })
      assert_eq(r.code, 0, "present 4 with DND already on failed: " .. r.stderr)
      assert_contains(sb:noctalia_log(), "msg bar-hide DP-1", "present must hide bar on DP-1")

      local st = sb:read_state()
      assert_true(st ~= nil, "state must exist")
      assert_eq(st.mode, "present", "state.mode must be present")
      assert_eq(st.dnd_was_active, true, "state.dnd_was_active must record true when DND was already on")

      sb:clear_logs()
      r = sb:run({ "stop-present" })
      assert_eq(r.code, 0, "stop-present failed: " .. r.stderr)
      local nlog = sb:noctalia_log()
      assert_contains(nlog, "msg bar-show DP-1", "stop-present must restore bar on DP-1")
      assert_true(
        not log_has_line(nlog, "msg dnd-off"),
        "stop-present MUST NOT turn off DND when user already had DND on! log:\n" .. nlog
      )
      assert_eq(sb:get_dnd(), "on", "DND must remain on")
    end)
  end)

  -- =========================================================================
  -- 8. Present toggle-control lifecycle
  -- =========================================================================
  test("bb.display.present_toggle_control", function()
    with_sandbox(function(sb)
      local r = sb:run({ "present", "3" })
      assert_eq(r.code, 0, "present 3 failed: " .. r.stderr)

      sb:clear_logs()
      r = sb:run({ "toggle-control" })
      assert_eq(r.code, 0, "1st toggle-control failed: " .. r.stderr)
      local st1 = sb:read_state()
      assert_true(st1 ~= nil, "state missing after toggle-control")
      assert_eq(st1.control_on_laptop, true, "1st toggle-control must set control_on_laptop=true")
      assert_true(#sb:hypr_ops() > 0, "1st toggle-control must dispatch hyprctl actions")

      sb:clear_logs()
      r = sb:run({ "toggle-control" })
      assert_eq(r.code, 0, "2nd toggle-control failed: " .. r.stderr)
      local st2 = sb:read_state()
      assert_true(st2 ~= nil, "state missing after 2nd toggle-control")
      assert_eq(st2.control_on_laptop, false, "2nd toggle-control must set control_on_laptop=false")
      assert_true(#sb:hypr_ops() > 0, "2nd toggle-control must restore private laptop via hyprctl")

      assert_eq(sb:run({ "stop-present" }).code, 0, "stop-present failed")
      local r_inactive = sb:run({ "toggle-control" })
      assert_true(
        not r_inactive.stderr:find("stack traceback:", 1, true),
        "toggle-control when not presenting must not crash: " .. r_inactive.stderr
      )
    end)
  end)

  -- =========================================================================
  -- 9. Virtual share 1080p: coordinate preservation, extend-up, clamshell, mirror
  -- =========================================================================
  test("bb.display.virtual_share_coordinate_preservation", function()
    -- Topology A: extend-left (HDMI-A-1 at 0x0, eDP-1 at 2560x0)
    with_sandbox(function(sb)
      sb:set_monitors({
        mon_ext("HDMI-A-1", { id = 1, width = 2560, height = 1440, x = 0, y = 0, focused = false }),
        mon_edp({ id = 0, width = 1920, height = 1200, x = 2560, y = 0, focused = true }),
      })
      sb:clear_logs()

      local r = sb:run({ "virtual-share", "9" })
      assert_eq(r.code, 0, "virtual-share 9 (extend-left) failed: " .. r.stderr)
      assert_contains(sb:hypr_ops(), "output create headless kaze-share", "must create headless kaze-share output")

      local info = sb:inspect_monitors_lua()
      assert_mon_entry(info, "HDMI-A-1", { position = "0x0", disabled = false }, "extend-left")
      assert_mon_entry(info, "eDP-1", { position = "2560x0", disabled = false }, "extend-left")
      assert_mon_entry(info, "kaze-share", {
        position = "9999x0",
        mode = function(v) return tostring(v or ""):find("1920x1080@60", 1, true) ~= nil end,
      }, "extend-left")

      assert_contains(sb:noctalia_log(), "msg bar-hide kaze-share", "must hide bar on kaze-share")
      local st = sb:read_state()
      assert_true(st ~= nil, "state missing after virtual-share")
      if type(st.bar_hidden_monitors) == "table" then
        for _, m in ipairs(st.bar_hidden_monitors) do
          assert_true(m ~= "kaze-share", "kaze-share MUST NOT be added to bar_hidden_monitors")
        end
        assert_true(st.bar_hidden_monitors["kaze-share"] == nil, "kaze-share MUST NOT be keyed in bar_hidden_monitors")
      end
    end)

    -- Topology B: extend-up (negative Y coordinate: HDMI-A-1 at 0x-1440, eDP-1 at 0x0)
    with_sandbox(function(sb)
      sb:set_monitors({
        mon_ext("HDMI-A-1", { id = 1, width = 2560, height = 1440, x = 0, y = -1440, focused = false }),
        mon_edp({ id = 0, width = 1920, height = 1200, x = 0, y = 0, focused = true }),
      })
      local r = sb:run({ "virtual-share", "9" })
      assert_eq(r.code, 0, "virtual-share 9 (extend-up) failed: " .. r.stderr)
      local info = sb:inspect_monitors_lua()
      assert_mon_entry(info, "HDMI-A-1", { position = "0x-1440", disabled = false }, "extend-up")
      assert_mon_entry(info, "eDP-1", { position = "0x0", disabled = false }, "extend-up")
      assert_mon_entry(info, "kaze-share", { position = "9999x0" }, "extend-up")
    end)

    -- Topology C: clamshell (eDP-1 disabled, DP-1 enabled at 0x0)
    with_sandbox(function(sb)
      sb:set_monitors({
        mon_edp({ id = 0, disabled = true, focused = false }),
        mon_ext("DP-1", { id = 1, width = 2560, height = 1440, x = 0, y = 0, disabled = false, focused = true }),
      })
      sb:set_workspaces({
        { id = 1, name = "1", monitor = "DP-1", windows = 1 },
      })
      local r = sb:run({ "virtual-share", "9" })
      assert_eq(r.code, 0, "virtual-share 9 (clamshell) failed: " .. r.stderr)
      local info = sb:inspect_monitors_lua()
      assert_mon_entry(info, "DP-1", { position = "0x0", disabled = false }, "clamshell")
      assert_mon_entry(info, "kaze-share", {
        position = "9999x0",
        mode = function(v) return tostring(v or ""):find("1920x1080@60", 1, true) ~= nil end,
      }, "clamshell")
      if info.by_output["eDP-1"] then
        assert_eq(info.by_output["eDP-1"].disabled, true, "clamshell eDP-1 must stay disabled")
      end
    end)

    -- Topology D: active HDMI mirror (both name & numeric mirrorOf) -> MUST NOT reload Hyprland!
    for _, mir_val in ipairs({ "eDP-1", "0" }) do
      with_sandbox(function(sb)
        sb:set_monitors({
          mon_edp({ id = 0, x = 0, y = 0 }),
          mon_ext("HDMI-A-1", { id = 1, x = 0, y = 0, mirrorOf = mir_val }),
        })
        sb:clear_logs()
        local r = sb:run({ "virtual-share", "9" })
        assert_eq(r.code, 0, "virtual-share 9 during active HDMI mirror (" .. mir_val .. ") failed: " .. r.stderr)
        assert_true(
          not log_has_line(sb:hypr_ops(), "reload"),
          "virtual-share MUST NOT reload Hyprland when HDMI mirror (" .. mir_val .. ") is active! ops=\n" .. sb:hypr_ops()
        )
      end)
    end
  end)

  -- =========================================================================
  -- 10. Virtual share: switch-share & toggle-window-share
  -- =========================================================================
  test("bb.display.virtual_share_switch_and_window_toggle", function()
    with_sandbox(function(sb)
      sb:set_workspaces({
        { id = 1, name = "1", monitor = "eDP-1", windows = 2 },
        { id = 2, name = "2", monitor = "HDMI-A-1", windows = 1 },
        { id = -99, name = "special:scratch", monitor = "eDP-1", windows = 1 },
      })
      assert_eq(sb:run({ "virtual-share", "9" }).code, 0, "virtual-share 9 failed")

      -- switch-share 5
      sb:clear_logs()
      local r = sb:run({ "switch-share", "5" })
      assert_eq(r.code, 0, "switch-share 5 failed: " .. r.stderr)
      local ops = sb:hypr_ops()
      assert_true(
        ops:find("5", 1, true) ~= nil and ops:find("kaze-share", 1, true) ~= nil,
        "switch-share 5 must display workspace 5 on kaze-share; ops=\n" .. ops
      )

      -- toggle-window-share: push focused window on ws 1 -> shared ws 5
      sb:set_activewindow({
        address = "0xdeadbeef",
        class = "foot",
        title = "demo",
        monitor = 0,
        workspace = { id = 1, name = "1" },
      })
      sb:clear_logs()
      r = sb:run({ "toggle-window-share" })
      assert_eq(r.code, 0, "toggle-window-share (push) failed: " .. r.stderr)
      local push_ops = sb:hypr_ops()
      assert_true(
        (push_ops:find("window.move", 1, true) ~= nil or push_ops:find("movetoworkspace", 1, true) ~= nil)
          and push_ops:find("5", 1, true) ~= nil,
        "toggle-window-share must push focused window to shared workspace 5; ops=\n" .. push_ops
      )

      -- toggle-window-share: pull focused window ALREADY on shared ws 5 back to positive physical ws
      sb:set_activewindow({
        address = "0xdeadbeef",
        class = "foot",
        title = "demo",
        monitor = 99,
        workspace = { id = 5, name = "5" },
      })
      sb:clear_logs()
      r = sb:run({ "toggle-window-share" })
      assert_eq(r.code, 0, "toggle-window-share (pull) failed: " .. r.stderr)
      local pull_ops = sb:hypr_ops()
      assert_true(
        pull_ops:find("window.move", 1, true) ~= nil or pull_ops:find("movetoworkspace", 1, true) ~= nil,
        "toggle-window-share must pull window back off shared workspace; ops=\n" .. pull_ops
      )
      assert_true(
        not pull_ops:find("-99", 1, true) and not pull_ops:find("special:", 1, true),
        "toggle-window-share must not pull window into negative special workspace; ops=\n" .. pull_ops
      )
      assert_true(
        not pull_ops:find('workspace = "5"', 1, true),
        "toggle-window-share pull must target a physical workspace other than 5; ops=\n" .. pull_ops
      )

      -- Empty activewindow: must handle gracefully without crash
      sb:set_activewindow(jobject({}))
      local r_empty = sb:run({ "toggle-window-share" })
      assert_true(
        not r_empty.stderr:find("stack traceback:", 1, true),
        "toggle-window-share with empty activewindow must not crash: " .. r_empty.stderr
      )
    end)
  end)

  -- =========================================================================
  -- 11. Virtual share: toggle-preview & toggle-virtual-control lifecycle
  -- =========================================================================
  test("bb.display.virtual_share_preview_and_control_lifecycle", function()
    with_sandbox(function(sb)
      assert_eq(sb:run({ "virtual-share", "9" }).code, 0, "virtual-share 9 failed")

      -- 1st toggle-preview: spawns wl-mirror --title kaze-share-preview & records live preview_pid
      sb:clear_logs()
      local r = sb:run({ "toggle-preview" })
      assert_eq(r.code, 0, "1st toggle-preview failed: " .. r.stderr)
      local st1 = sb:read_state()
      assert_true(st1 ~= nil, "state missing after toggle-preview")
      assert_true(type(st1.preview_pid) == "number" and st1.preview_pid > 1, "preview_pid must be a positive PID")
      assert_true(pid_alive(st1.preview_pid), "preview wl-mirror PID must be alive")
      local wlog = sb:wl_mirror_log()
      assert_contains(wlog, "--title kaze-share-preview", "preview must spawn wl-mirror --title kaze-share-preview")
      assert_contains(wlog, "kaze-share", "preview wl-mirror must target kaze-share")

      -- 2nd toggle-preview: kills preview wl-mirror & clears preview_pid
      local prev_pid = st1.preview_pid
      r = sb:run({ "toggle-preview" })
      assert_eq(r.code, 0, "2nd toggle-preview failed: " .. r.stderr)
      assert_true(wait_pid_dead(prev_pid, 25), "2nd toggle-preview must kill wl-mirror preview process")
      local st2 = sb:read_state()
      assert_true(st2.preview_pid == nil or st2.preview_pid == 0, "2nd toggle-preview must clear preview_pid")

      -- 1st toggle-virtual-control: spawns fullscreen wl-mirror --title kaze-share-control WITHOUT reload
      sb:clear_logs()
      r = sb:run({ "toggle-virtual-control" })
      assert_eq(r.code, 0, "1st toggle-virtual-control failed: " .. r.stderr)
      assert_true(
        not log_has_line(sb:hypr_ops(), "reload"),
        "toggle-virtual-control MUST NOT reload Hyprland; ops=\n" .. sb:hypr_ops()
      )
      local wlog2 = sb:wl_mirror_log()
      assert_contains(wlog2, "--title kaze-share-control", "virtual control must spawn wl-mirror --title kaze-share-control")
      assert_contains(wlog2, "kaze-share", "virtual control wl-mirror must target kaze-share")

      local st3 = sb:read_state()
      assert_true(st3 ~= nil, "state missing after toggle-virtual-control")
      assert_eq(st3.control_virtual, true, "1st toggle-virtual-control must set control_virtual=true")
      local ctrl_pid = st3.control_pid or st3.virtual_control_pid or st3.control_mirror_pid
      assert_true(type(ctrl_pid) == "number" and ctrl_pid > 1, "control PID must be recorded in state")
      assert_true(pid_alive(ctrl_pid), "control wl-mirror PID must be alive")

      -- 2nd toggle-virtual-control: kills control wl-mirror & clears state WITHOUT reload
      sb:clear_logs()
      r = sb:run({ "toggle-virtual-control" })
      assert_eq(r.code, 0, "2nd toggle-virtual-control failed: " .. r.stderr)
      assert_true(
        not log_has_line(sb:hypr_ops(), "reload"),
        "2nd toggle-virtual-control MUST NOT reload Hyprland; ops=\n" .. sb:hypr_ops()
      )
      assert_true(wait_pid_dead(ctrl_pid, 25), "2nd toggle-virtual-control must kill control wl-mirror")
      local st4 = sb:read_state()
      assert_true(not st4.control_virtual, "2nd toggle-virtual-control must clear control_virtual")
      local ctrl_pid2 = st4.control_pid or st4.virtual_control_pid or st4.control_mirror_pid
      assert_true(ctrl_pid2 == nil or ctrl_pid2 == 0, "2nd toggle-virtual-control must clear control PID")
    end)
  end)

  -- =========================================================================
  -- 12. stop-virtual rescues windows, kills wl-mirror, removes kaze-share
  -- =========================================================================
  test("bb.display.stop_virtual_rescues_windows_and_cleans_up", function()
    with_sandbox(function(sb)
      sb:set_workspaces({
        { id = 1, name = "1", monitor = "eDP-1", windows = 1 },
        { id = -99, name = "special:scratch", monitor = "eDP-1", windows = 1 },
      })
      assert_eq(sb:run({ "virtual-share", "9" }).code, 0, "virtual-share 9 failed")
      assert_eq(sb:run({ "toggle-preview" }).code, 0, "toggle-preview failed")
      local st_before = sb:read_state()
      local prev_pid = st_before.preview_pid
      assert_true(pid_alive(prev_pid), "preview must be running before stop-virtual")

      sb:set_clients({
        { address = "0x1111", class = "foot", title = "win1", monitor = 99, workspace = { id = 9, name = "9" } },
        { address = "0x2222", class = "browser", title = "win2", monitor = 99, workspace = { id = 9, name = "9" } },
        { address = "0x3333", class = "editor", title = "win3", monitor = 0, workspace = { id = 1, name = "1" } },
      })
      sb:clear_logs()

      local r = sb:run({ "stop-virtual" })
      assert_eq(r.code, 0, "stop-virtual failed: " .. r.stderr)

      -- Preview killed
      assert_true(wait_pid_dead(prev_pid, 25), "stop-virtual must kill preview wl-mirror")

      -- Functionally verify window rescue (either via direct address moves OR via in-compositor eval over hl.get_windows())
      local ops = sb:hypr_ops()
      local rescued = {}
      if ops:find("0x1111", 1, true) and ops:find("0x2222", 1, true) then
        rescued["0x1111"] = "direct"
        rescued["0x2222"] = "direct"
      else
        local mock_windows = {
          { address = "0x1111", monitor = { name = "kaze-share" }, workspace = { id = 9 } },
          { address = "0x2222", monitor = { name = "kaze-share" }, workspace = { id = 9 } },
          { address = "0x3333", monitor = { name = "eDP-1" }, workspace = { id = 1 } },
        }
        local fake_hl = {
          get_windows = function() return mock_windows end,
          workspace_rule = function() return { set_enabled = function() end } end,
          window_rule = function() end,
          monitor = function() end,
          dispatch = function(act)
            if type(act) == "table" and act._kind == "move" and act.window then
              rescued[act.window.address] = tostring(act.workspace)
            end
          end,
          dsp = {
            focus = function(o) return { _kind = "focus", o = o } end,
            window = {
              move = function(o) return { _kind = "move", window = o.window, workspace = o.workspace } end,
            },
          },
        }
        for _, chunk_src in ipairs(sb:eval_chunks()) do
          local fn, lerr = load(chunk_src, "stop_virtual_eval", "t", {
            hl = fake_hl, ipairs = ipairs, pairs = pairs, tostring = tostring, tonumber = tonumber,
          })
          assert_true(fn ~= nil, "stop-virtual eval chunk invalid Lua: " .. tostring(lerr) .. "\n" .. chunk_src)
          local ok_exec, eerr = pcall(fn)
          assert_true(ok_exec, "stop-virtual eval execution failed: " .. tostring(eerr))
        end
      end

      assert_true(rescued["0x1111"] ~= nil and rescued["0x2222"] ~= nil, "stop-virtual must rescue both shared windows 0x1111 & 0x2222; ops=\n" .. ops)
      assert_true(rescued["0x3333"] == nil, "stop-virtual must NOT disturb physical window 0x3333 on eDP-1")
      if rescued["0x1111"] ~= "direct" then
        local dst = tonumber(rescued["0x1111"])
        assert_true(dst ~= nil and dst >= 1 and dst ~= 9, "rescued window must go to positive physical workspace (got " .. tostring(rescued["0x1111"]) .. ")")
      end
      assert_true(
        not ops:find("-99", 1, true) and not ops:find("special:", 1, true),
        "stop-virtual must rescue windows to a positive physical workspace, not special:-99; ops=\n" .. ops
      )

      -- Headless output removed
      assert_contains(ops, "output remove kaze-share", "stop-virtual must call hyprctl output remove kaze-share")

      -- kaze-share stripped from monitors.lua (still valid Lua)
      if file_exists(sb:monitors_lua_path()) then
        local info = sb:inspect_monitors_lua()
        assert_true(
          info.by_output["kaze-share"] == nil and not info.raw:find("kaze-share", 1, true),
          "stop-virtual must strip kaze-share from monitors.lua; raw:\n" .. info.raw
        )
      end

      -- Virtual state cleared
      local st_after = sb:read_state()
      if st_after then
        assert_true(not st_after.virtual_active and st_after.virtual_workspace == nil, "virtual state must be cleared")
        assert_true(st_after.preview_pid == nil, "preview_pid must be cleared")
      end
    end)
  end)

  -- =========================================================================
  -- 13. Hotplug lock guards, monitor filter guards, and unlocked menu open
  -- =========================================================================
  test("bb.display.hotplug_lock_and_filter_guards", function()
    -- (a) loginctl LockedHint=yes -> silent exit 0, no dmenu
    with_sandbox(function(sb)
      sb:set_locked_hint("yes")
      sb:clear_logs()
      local r = sb:run({ "--hotplug", "HDMI-A-1" })
      assert_eq(r.code, 0, "--hotplug with LockedHint=yes must exit 0")
      assert_eq(sb:dmenu_calls(), "", "--hotplug must NOT call dmenu when LockedHint=yes")
    end)

    -- (b) hyprctl -j layers has hyprlock -> silent exit 0, no dmenu
    with_sandbox(function(sb)
      sb:set_layers({
        ["eDP-1"] = {
          levels = {
            ["3"] = jarray({
              { address = "0x9", x = 0, y = 0, w = 1920, h = 1200, namespace = "hyprlock" },
            }),
          },
        },
      })
      sb:clear_logs()
      local r = sb:run({ "--hotplug", "HDMI-A-1" })
      assert_eq(r.code, 0, "--hotplug with hyprlock layer must exit 0")
      assert_eq(sb:dmenu_calls(), "", "--hotplug must NOT call dmenu when hyprlock layer exists")
    end)

    -- (c) hyprctl -j locked returns {"locked":true} -> silent exit 0, no dmenu
    with_sandbox(function(sb)
      sb:set_locked(true)
      sb:clear_logs()
      local r = sb:run({ "--hotplug", "HDMI-A-1" })
      assert_eq(r.code, 0, "--hotplug with locked=true must exit 0")
      assert_eq(sb:dmenu_calls(), "", "--hotplug must NOT call dmenu when hyprctl locked=true")
    end)

    -- (d) ignored monitor names: kaze-share, HEADLESS-1, HEADLESS-2, eDP-1
    with_sandbox(function(sb)
      for _, mon in ipairs({ "kaze-share", "HEADLESS-1", "HEADLESS-2", "eDP-1" }) do
        sb:clear_logs()
        local r = sb:run({ "--hotplug", mon })
        assert_eq(r.code, 0, "--hotplug " .. mon .. " must exit 0")
        assert_eq(sb:dmenu_calls(), "", "--hotplug must NOT call dmenu for " .. mon)
      end
    end)

    -- (e) display_hotplug_menu = false in $XDG_CONFIG_HOME/hypr/user.lua
    with_sandbox(function(sb)
      sb:set_user_lua("return { display_hotplug_menu = false }\n")
      sb:clear_logs()
      local r = sb:run({ "--hotplug", "HDMI-A-1" })
      assert_eq(r.code, 0, "--hotplug with display_hotplug_menu=false must exit 0")
      assert_eq(sb:dmenu_calls(), "", "--hotplug must NOT call dmenu when display_hotplug_menu=false in XDG_CONFIG_HOME/hypr/user.lua")
    end)

    -- Positive case: unlocked + external HDMI-A-1 opens noctalia dmenu -p Display >
    with_sandbox(function(sb)
      sb:set_dmenu_responses({ "<<CANCEL>>" })
      sb:clear_logs()
      local r = sb:run({ "--hotplug", "HDMI-A-1" })
      assert_eq(r.code, 0, "unlocked --hotplug HDMI-A-1 (Esc cancel) must exit 0; stderr=" .. r.stderr)
      local dcalls = sb:dmenu_calls()
      assert_contains(dcalls, "dmenu", "unlocked --hotplug HDMI-A-1 must invoke noctalia dmenu")
      assert_contains(dcalls, "-p", "unlocked --hotplug must pass -p prompt")
      assert_contains(dcalls, "Display >", "unlocked --hotplug prompt must be 'Display >'")
    end)
  end)

  -- =========================================================================
  -- 14. Disconnect recovery (black-screen guard) & presentation isolation
  -- =========================================================================
  test("bb.display.disconnect_recovery_and_isolation", function()
    -- Case A: unplugging kaze-share is ignored safely
    with_sandbox(function(sb)
      sb:clear_logs()
      local r = sb:run({ "--on-disconnect", "kaze-share" })
      assert_eq(r.code, 0, "--on-disconnect kaze-share must exit 0")
      assert_eq(sb:noctalia_log(), "", "--on-disconnect kaze-share must not touch Noctalia")
    end)

    -- Case B: unplugging sole external monitor in external mode (eDP-1 disabled=true)
    -- MUST recover eDP-1 (disabled=false, position="0x0") to prevent black screen!
    with_sandbox(function(sb)
      sb:set_monitors({
        mon_edp({ disabled = true, focused = false }),
        mon_ext("HDMI-A-1", { disabled = false, focused = true, x = 0, y = 0 }),
      })
      assert_eq(sb:run({ "external", "--no-confirm" }).code, 0, "setup external mode failed")

      sb:set_monitors({
        mon_edp({ disabled = true, focused = false }),
      })
      sb:clear_logs()
      local r = sb:run({ "--on-disconnect", "HDMI-A-1" })
      assert_eq(r.code, 0, "--on-disconnect HDMI-A-1 recovery failed: " .. r.stderr)
      local info = sb:inspect_monitors_lua()
      assert_mon_entry(info, "eDP-1", { disabled = false, position = "0x0" }, "disconnect recovery")
      assert_true(#sb:hypr_ops() > 0, "--on-disconnect recovery must apply eDP-1 enable via hyprctl")
    end)

    -- Case C: unplugging UNRELATED idle monitor HDMI-A-1 while presenting on DP-1
    -- MUST NOT tear down DP-1 presentation, bar-hide, or DND!
    with_sandbox(function(sb)
      sb:set_monitors({
        mon_edp({ id = 0 }),
        mon_ext("DP-1", { id = 1, x = 1920, y = 0 }),
        mon_ext("HDMI-A-1", { id = 2, x = 4480, y = 0 }),
      })
      sb:set_dnd("off")
      local r_p = sb:run({ "present", "3" })
      assert_eq(r_p.code, 0, "present 3 on DP-1 failed: " .. r_p.stderr)
      local st_p = sb:read_state()
      assert_eq(st_p.mode, "present", "must be in present mode")
      local presented_mon = st_p.present_monitor or st_p.external_monitor or st_p.monitor or "DP-1"
      local idle_mon = (presented_mon == "DP-1") and "HDMI-A-1" or "DP-1"

      sb:set_monitors({
        mon_edp({ id = 0 }),
        mon_ext(presented_mon, { id = 1, x = 1920, y = 0 }),
      })
      sb:clear_logs()
      local r_disc = sb:run({ "--on-disconnect", idle_mon })
      assert_eq(r_disc.code, 0, "--on-disconnect unrelated monitor failed: " .. r_disc.stderr)

      local nlog = sb:noctalia_log()
      assert_true(
        not log_has_line(nlog, "bar-show " .. presented_mon),
        "unplugging unrelated " .. idle_mon .. " MUST NOT restore bar on presented " .. presented_mon .. "; log:\n" .. nlog
      )
      assert_true(
        not log_has_line(nlog, "msg dnd-off"),
        "unplugging unrelated " .. idle_mon .. " MUST NOT disable DND; log:\n" .. nlog
      )
      local st_after = sb:read_state()
      assert_eq(st_after.mode, "present", "presentation on " .. presented_mon .. " must remain active")

      -- Case D (subcase 1, dnd_was_active=false): unplug the ACTIVELY presented monitor!
      sb:set_monitors({ mon_edp({ id = 0 }) })
      sb:clear_logs()
      local r_disc2 = sb:run({ "--on-disconnect", presented_mon })
      assert_eq(r_disc2.code, 0, "--on-disconnect active presented monitor failed: " .. r_disc2.stderr)
      local nlog2 = sb:noctalia_log()
      assert_contains(nlog2, "msg bar-show " .. presented_mon, "disconnecting presented monitor must restore bar")
      assert_contains(nlog2, "msg dnd-off", "disconnecting presented monitor must restore DND off when dnd_was_active=false")
      local st_cleared = sb:read_state()
      if st_cleared then
        assert_true(st_cleared.mode ~= "present", "disconnecting presented monitor must clear present mode")
      end
    end)

    -- Case D (subcase 2, dnd_was_active=true): unplugging presented monitor MUST preserve user's DND=on
    with_sandbox(function(sb)
      sb:set_monitors({ mon_edp(), mon_ext("DP-1") })
      sb:set_dnd("on")
      assert_eq(sb:run({ "present", "3" }).code, 0, "present 3 failed")
      sb:set_monitors({ mon_edp() })
      sb:clear_logs()
      assert_eq(sb:run({ "--on-disconnect", "DP-1" }).code, 0, "--on-disconnect DP-1 failed")
      local nlog = sb:noctalia_log()
      assert_contains(nlog, "msg bar-show DP-1", "must restore bar on DP-1")
      assert_true(
        not log_has_line(nlog, "msg dnd-off"),
        "disconnecting presented monitor MUST NOT turn off DND when user already had DND on! log:\n" .. nlog
      )
    end)
  end)

  -- =========================================================================
  -- 15. Interactive --menu state adaptation, submenu, & Esc cancel
  -- =========================================================================
  test("bb.display.interactive_menu_adaptation_and_cancel", function()
    with_sandbox(function(sb)
      -- State 1: Dual monitor idle -> shows Extend / Layout… submenu; Esc cancel exits 0 without mutating
      sb:set_dmenu_responses({ "<<CANCEL>>" })
      sb:clear_logs()
      local r = sb:run({ "--menu" })
      assert_eq(r.code, 0, "--menu Esc cancel must exit 0; stderr=" .. r.stderr)
      local menu1 = sb:dmenu_stdin(1)
      assert_true(
        menu1:find("Extend / Layout", 1, true) ~= nil,
        "dual-monitor --menu must offer 'Extend / Layout…' submenu; got:\n" .. menu1
      )
      assert_true(not file_exists(sb:monitors_lua_path()), "Esc cancel must not write monitors.lua")
      assert_eq(sb:hypr_ops(), "", "Esc cancel must not run mutating hyprctl ops")

      -- Navigate Extend / Layout… submenu
      local layout_line
      for _, line in ipairs(log_lines(menu1)) do
        if line:find("Extend / Layout", 1, true) then
          layout_line = line
          break
        end
      end
      assert_true(layout_line ~= nil, "failed to find Extend / Layout menu line")
      sb:set_dmenu_responses({ layout_line, "<<CANCEL>>" })
      sb:clear_logs()
      r = sb:run({ "--menu" })
      assert_eq(r.code, 0, "--menu submenu Esc cancel must exit 0")
      local submenu = sb:dmenu_stdin(2)
      assert_true(#submenu > 0, "selecting Extend / Layout… must open layout submenu")

      -- State 2: Active mirror -> menu shows Stop Mirror, selecting it un-mirrors
      sb:set_monitors({ mon_edp(), mon_ext("HDMI-A-1", { mirrorOf = "eDP-1" }) })
      sb:set_dmenu_responses({ "<<CANCEL>>" })
      sb:clear_logs()
      assert_eq(sb:run({ "--menu" }).code, 0, "--menu in mirror state failed")
      local menu_mir = sb:dmenu_stdin(1)
      assert_contains(menu_mir, "Stop Mirror", "active mirror menu must show 'Stop Mirror'")
      local stop_mir_line
      for _, line in ipairs(log_lines(menu_mir)) do
        if line:find("Stop Mirror", 1, true) then stop_mir_line = line; break end
      end
      sb:set_dmenu_responses({ stop_mir_line })
      sb:clear_logs()
      assert_eq(sb:run({ "--menu" }).code, 0, "selecting Stop Mirror failed")
      assert_contains(sb:hypr_ops(), "reload", "selecting Stop Mirror must trigger hyprctl reload")

      -- State 3: Active presentation -> menu shows Stop Presentation
      sb:set_monitors({ mon_edp(), mon_ext("HDMI-A-1") })
      assert_eq(sb:run({ "present", "3" }).code, 0, "present 3 failed")
      sb:set_dmenu_responses({ "<<CANCEL>>" })
      sb:clear_logs()
      assert_eq(sb:run({ "--menu" }).code, 0, "--menu in present state failed")
      local menu_pres = sb:dmenu_stdin(1)
      assert_contains(menu_pres, "Stop Presentation", "active present menu must show 'Stop Presentation'")
      assert_eq(sb:run({ "stop-present" }).code, 0, "stop-present failed")

      -- State 4: Active virtual share -> menu shows Stop Virtual Share, Toggle Share Preview, Control kaze-share Directly
      assert_eq(sb:run({ "virtual-share", "9" }).code, 0, "virtual-share 9 failed")
      sb:set_dmenu_responses({ "<<CANCEL>>" })
      sb:clear_logs()
      assert_eq(sb:run({ "--menu" }).code, 0, "--menu in virtual-share state failed")
      local menu_virt = sb:dmenu_stdin(1)
      assert_contains(menu_virt, "Stop Virtual Share", "virtual-share menu must show 'Stop Virtual Share'")
      assert_contains(menu_virt, "Toggle Share Preview", "virtual-share menu must show 'Toggle Share Preview'")
      assert_contains(menu_virt, "Control kaze-share Directly", "virtual-share menu must show 'Control kaze-share Directly'")
    end)
  end)

  -- =========================================================================
  -- 16. Full cleanup teardown & conditional DND preservation
  -- =========================================================================
  test("bb.display.cleanup_full_teardown_and_dnd_safety", function()
    -- Subcase A: DND originally off, active present + virtual-share + preview + control
    with_sandbox(function(sb)
      sb:set_dnd("off")
      assert_eq(sb:run({ "present", "3" }).code, 0, "present 3 failed")
      assert_eq(sb:run({ "virtual-share", "9" }).code, 0, "virtual-share 9 failed")
      assert_eq(sb:run({ "toggle-preview" }).code, 0, "toggle-preview failed")
      assert_eq(sb:run({ "toggle-virtual-control" }).code, 0, "toggle-virtual-control failed")

      local st = sb:read_state()
      local pids = {}
      if type(st.preview_pid) == "number" then pids[#pids + 1] = st.preview_pid end
      local cpid = st.control_pid or st.virtual_control_pid or st.control_mirror_pid
      if type(cpid) == "number" then pids[#pids + 1] = cpid end
      assert_true(#pids >= 1, "expected running wl-mirror PID(s) before cleanup")

      sb:clear_logs()
      local r = sb:run({ "cleanup" })
      assert_eq(r.code, 0, "cleanup failed: " .. r.stderr)

      for _, pid in ipairs(pids) do
        assert_true(wait_pid_dead(pid, 25), "cleanup must terminate wl-mirror PID " .. pid)
      end
      assert_contains(sb:hypr_ops(), "output remove kaze-share", "cleanup must remove kaze-share")
      local nlog = sb:noctalia_log()
      assert_contains(nlog, "msg bar-show HDMI-A-1", "cleanup must restore bar")
      assert_contains(nlog, "msg dnd-off", "cleanup must restore DND off when originally off")
      assert_eq(sb:get_dnd(), "off", "DND must be off after cleanup")

      if file_exists(sb:monitors_lua_path()) then
        local info = sb:inspect_monitors_lua()
        assert_true(not info.raw:find("kaze-share", 1, true), "cleanup must strip kaze-share from monitors.lua")
      end

      -- Idempotent second cleanup: exit 0, no crash, no spurious DND-off toggle
      sb:clear_logs()
      local r2 = sb:run({ "cleanup" })
      assert_eq(r2.code, 0, "idempotent cleanup failed: " .. r2.stderr)
      assert_true(
        not log_has_line(sb:noctalia_log(), "msg dnd-off"),
        "idempotent cleanup on clean state should not spuriously toggle DND off"
      )
    end)

    -- Subcase B: DND originally ON -> cleanup MUST NOT turn off DND
    with_sandbox(function(sb)
      sb:set_dnd("on")
      assert_eq(sb:run({ "present", "3" }).code, 0, "present 3 failed")
      assert_eq(sb:run({ "virtual-share", "9" }).code, 0, "virtual-share 9 failed")
      assert_eq(sb:run({ "toggle-preview" }).code, 0, "toggle-preview failed")

      sb:clear_logs()
      local r = sb:run({ "cleanup" })
      assert_eq(r.code, 0, "cleanup (DND originally on) failed: " .. r.stderr)
      local nlog = sb:noctalia_log()
      assert_contains(nlog, "msg bar-show HDMI-A-1", "cleanup must restore bar")
      assert_true(
        not log_has_line(nlog, "msg dnd-off"),
        "cleanup MUST NOT turn off DND when user already had DND on! log:\n" .. nlog
      )
      assert_eq(sb:get_dnd(), "on", "DND must stay on after cleanup")
    end)
  end)

  -- =========================================================================
  -- 17. Concurrency locking, lock contention, & corrupt state resilience
  -- =========================================================================
  test("bb.display.concurrency_locking_and_state_integrity", function()
    with_sandbox(function(sb)
      exec_code("/usr/bin/mkdir -p " .. sh_quote(sb.kaze_runtime))
      local lock_path = sb.kaze_runtime .. "/display-menu.lock"
      local pid_out = sb.root .. "/locker.pid"

      exec_code("/usr/bin/sh -c '(/usr/bin/flock -x 9; exec /usr/bin/sleep 1.5) 9>"
        .. sh_quote(lock_path) .. " </dev/null >/dev/null 2>&1 & printf \"%s\\n\" \"$!\" > "
        .. sh_quote(pid_out) .. "'")
      os.execute("/usr/bin/sleep 0.1")
      local locker_pid = tonumber((read_file(pid_out) or ""):match("%d+"))
      sb:track_pid(locker_pid)

      sb:set_dmenu_responses({ "<<CANCEL>>" })
      sb:clear_logs()
      local r_locked = sb:run({ "--menu" }, { timeout = 3 })
      assert_true(r_locked.code ~= 124, "--menu must not hang when display-menu.lock is already held")
      assert_eq(sb:dmenu_calls(), "", "--menu MUST NOT open duplicate dmenu while display-menu.lock is held")

      if locker_pid and pid_alive(locker_pid) then
        exec_code("/usr/bin/kill -TERM " .. locker_pid .. " 2>/dev/null")
      end

      -- Rapid concurrent layout commands: no hang, valid monitors.lua & display-state.json
      local p1 = sb.root .. "/c1.exit"
      local p2 = sb.root .. "/c2.exit"
      local p3 = sb.root .. "/c3.exit"
      local envp = sb:env_prefix()
      local parallel_cmd = "/usr/bin/sh -c '"
        .. "(" .. envp .. " /usr/bin/timeout 8 " .. sh_quote(kaze_display) .. " extend-right >/dev/null 2>&1; echo $? > " .. sh_quote(p1) .. ") & "
        .. "(" .. envp .. " /usr/bin/timeout 8 " .. sh_quote(kaze_display) .. " extend-left  >/dev/null 2>&1; echo $? > " .. sh_quote(p2) .. ") & "
        .. "(" .. envp .. " /usr/bin/timeout 8 " .. sh_quote(kaze_display) .. " extend-up    >/dev/null 2>&1; echo $? > " .. sh_quote(p3) .. ") & "
        .. "wait'"
      assert_eq(exec_code(parallel_cmd), 0, "parallel wrapper failed")
      for idx, pf in ipairs({ p1, p2, p3 }) do
        local c = tonumber((read_file(pf) or ""):match("%d+"))
        assert_eq(c, 0, "concurrent layout invocation #" .. idx .. " must exit 0 (not hang/corrupt)")
      end
      local info = sb:inspect_monitors_lua()
      assert_true(info.by_output["eDP-1"] ~= nil and info.by_output["HDMI-A-1"] ~= nil, "monitors.lua intact after concurrent runs")

      -- Corrupt / malformed display-state.json recovery
      for _, bad_json in ipairs({ "", "{broken json", "[]", "null", "12345" }) do
        write_file(sb:state_path(), bad_json)
        local r_rec = sb:run({ "--list" })
        assert_eq(r_rec.code, 0, "--list must survive corrupt display-state.json (" .. bad_json .. "): " .. r_rec.stderr)
        local r_cln = sb:run({ "cleanup" })
        assert_eq(r_cln.code, 0, "cleanup must survive corrupt display-state.json (" .. bad_json .. "): " .. r_cln.stderr)
        assert_true(
          not r_cln.stderr:find("stack traceback:", 1, true),
          "cleanup crashed with traceback on corrupt state: " .. r_cln.stderr
        )
      end
    end)
  end)

  -- =========================================================================
  -- 18. Adversarial injection safety & re-entrant present DND preservation
  -- =========================================================================
  test("bb.display.adversarial_inputs_and_edge_cases", function()
    with_sandbox(function(sb)
      -- Shell & Lua injection payloads must NEVER execute injected commands or produce unescaped Lua in hyprctl eval
      local canary = sb.root .. "/pwned"
      local payloads = {
        "1; touch " .. canary,
        "$(touch " .. canary .. ")",
        '1"}); os.execute("touch ' .. canary .. '"); --',
        "1\n2",
      }
      local noop_hl
      noop_hl = setmetatable({}, {
        __index = function() return noop_hl end,
        __call = function() return noop_hl end,
      })

      for _, payload in ipairs(payloads) do
        for _, cmd_name in ipairs({ "present", "virtual-share", "switch-share" }) do
          sb:clear_logs()
          local r = sb:run({ cmd_name, payload })
          assert_true(not file_exists(canary), "shell injection executed via " .. cmd_name .. " " .. payload)
          assert_true(
            not r.stderr:find("stack traceback:", 1, true),
            cmd_name .. " crashed with Lua traceback on adversarial input: " .. r.stderr
          )
          -- Every emitted hyprctl eval chunk must compile cleanly & never call os.execute
          for _, chunk_src in ipairs(sb:eval_chunks()) do
            local injected_called = false
            local env = {
              hl = noop_hl,
              ipairs = ipairs,
              pairs = pairs,
              tostring = tostring,
              tonumber = tonumber,
              os = { execute = function() injected_called = true end },
            }
            local fn, lerr = load(chunk_src, "adv_eval", "t", env)
            assert_true(fn ~= nil, "adversarial input broke Lua syntax in hyprctl eval: " .. tostring(lerr) .. "\nchunk:\n" .. chunk_src)
            pcall(fn)
            assert_true(not injected_called, "Lua code injection triggered os.execute via " .. cmd_name .. " " .. payload)
          end
        end
      end

      -- Clean up after fuzzing
      assert_eq(sb:run({ "cleanup" }).code, 0, "cleanup after fuzzing failed")

      -- Re-entrant present (present 3 -> present 4) while DND was originally OFF:
      -- Must preserve original dnd_was_active=false so stop-present still restores DND off!
      sb:set_dnd("off")
      assert_eq(sb:run({ "present", "3" }).code, 0, "1st present 3 failed")
      assert_eq(sb:get_dnd(), "on", "DND should be on after 1st present")
      assert_eq(sb:run({ "present", "4" }).code, 0, "2nd re-entrant present 4 failed")
      local st = sb:read_state()
      assert_eq(st.dnd_was_active, false, "re-entrant present MUST preserve original dnd_was_active=false!")
      sb:clear_logs()
      assert_eq(sb:run({ "stop-present" }).code, 0, "stop-present after re-entrant present failed")
      assert_contains(sb:noctalia_log(), "msg dnd-off", "stop-present after re-entrant present must restore DND off")
      assert_eq(sb:get_dnd(), "off", "DND must be restored to off")
    end)
  end)
end

return run_suite
