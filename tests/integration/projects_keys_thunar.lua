-- Blind black-box & brute-force behavioral test suite for:
--   bin/kaze-project
--   bin/kaze-keys
--   bin/kaze-thunar-action
--
-- Derived strictly from the Behavioral Specification using ONLY Lua stdlib.
-- Every test runs inside an isolated /tmp/kaze-bb-pkt-* sandbox with a hermetic
-- stub PATH and explicit env -i isolation; all temporary dirs are cleaned up in pcall.

local function sh_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function read_file(path)
  local fh = io.open(path, "rb")
  if not fh then
    return nil
  end
  local data = fh:read("a")
  fh:close()
  return data
end

local function write_file(path, data)
  local fh, err = io.open(path, "wb")
  if not fh then
    error("write_file failed for " .. tostring(path) .. ": " .. tostring(err), 2)
  end
  fh:write(data or "")
  fh:close()
end

local function path_exists(path)
  local ok = os.execute("test -e " .. sh_quote(path))
  return ok == true or ok == 0
end

local function is_dir(path)
  local ok = os.execute("test -d " .. sh_quote(path))
  return ok == true or ok == 0
end

local function is_file(path)
  local ok = os.execute("test -f " .. sh_quote(path))
  return ok == true or ok == 0
end

local function mkdir_p(path)
  local ok = os.execute("mkdir -p -- " .. sh_quote(path))
  if ok ~= true and ok ~= 0 then
    error("mkdir -p failed: " .. tostring(path), 2)
  end
end

local function chmod_x(path)
  local ok = os.execute("chmod +x -- " .. sh_quote(path))
  if ok ~= true and ok ~= 0 then
    error("chmod +x failed: " .. tostring(path), 2)
  end
end

local function find_host_bin(name)
  for _, dir in ipairs({ "/usr/bin", "/bin" }) do
    local candidate = dir .. "/" .. name
    local ok = os.execute("test -x " .. sh_quote(candidate))
    if ok == true or ok == 0 then
      return candidate
    end
  end
  return nil
end

local function exec_code(cmd)
  local ok, why, code = os.execute(cmd)
  if type(ok) == "number" then
    return ok
  end
  if ok == true then
    return 0
  end
  if why == "exit" then
    return code or 1
  end
  if why == "signal" then
    return 128 + (code or 1)
  end
  return 1
end

local function popen_capture(cmd)
  local ph = assert(io.popen(cmd, "r"))
  local out = ph:read("a") or ""
  local ok, why, code = ph:close()
  local rc = 0
  if type(ok) == "number" then
    rc = ok
  elseif ok ~= true then
    if why == "exit" then
      rc = code or 1
    elseif why == "signal" then
      rc = 128 + (code or 1)
    else
      rc = 1
    end
  end
  return out, rc
end

local function sleep_ms(ms)
  os.execute("sleep " .. string.format("%.3f", ms / 1000))
end

local function split_lines(text)
  local out = {}
  if not text or text == "" then
    return out
  end
  for line in (text .. "\n"):gmatch("(.-)\n") do
    out[#out + 1] = line
  end
  if #out > 0 and out[#out] == "" and text:sub(-1) == "\n" then
    table.remove(out)
  end
  return out
end

local function non_empty_lines(text)
  local out = {}
  for _, line in ipairs(split_lines(text)) do
    if line ~= "" then
      out[#out + 1] = line
    end
  end
  return out
end

local function list_dir_entries(dir)
  local out = popen_capture("ls -A1 -- " .. sh_quote(dir) .. " 2>/dev/null | sort")
  return non_empty_lines(out)
end

local function argv_equals(actual, expected)
  if type(actual) ~= "table" or #actual ~= #expected then
    return false
  end
  for i = 1, #expected do
    if actual[i] ~= expected[i] then
      return false
    end
  end
  return true
end

local function fmt_argv(argv)
  local parts = {}
  for i = 1, #(argv or {}) do
    parts[#parts + 1] = string.format("%q", tostring(argv[i]))
  end
  return "[" .. table.concat(parts, ", ") .. "]"
end

-- Safe coreutils symlinked into every hermetic sandbox PATH.
-- Intentionally EXCLUDES noctalia, zoxide, fd, footclient, kaze-footclient,
-- yazi, codium, code, nvim, vim, nano, wl-copy, notify-send, hyprctl, etc.
local BASE_COREUTILS = {
  "lua", "env", "sh", "bash", "mkdir", "rm", "mv", "cp", "ln", "cat",
  "chmod", "dirname", "basename", "realpath", "readlink", "stat", "test",
  "touch", "mktemp", "pwd", "printf", "echo", "true", "false", "sleep",
  "sort", "uniq", "head", "tail", "tr", "cut", "sed", "awk", "grep",
  "find", "xargs", "wc", "date", "ls", "id", "uname", "which",
  "setsid", "nohup", "zstd", "gzip", "gunzip", "bzip2", "xz", "unzip",
  "tar", "file",
}

-- Generic Lua stub source generator.
-- Logs every invocation atomically (write .tmp + os.rename) into sb.logs.
local function make_lua_stub_code(cmd_name, opts)
  opts = opts or {}
  local read_stdin_mode = opts.read_stdin or "never" -- "never" | "always" | "dmenu"
  local extra_body = opts.extra_body or ""
  local default_exit = opts.exit_code or 0
  return string.format([=[#!/usr/bin/env lua
local cmd_name = %q
local log_dir = %q
local read_stdin_mode = %q
local default_exit = %d

local function q(s)
  return string.format("%%q", tostring(s))
end

local function get_tag()
  local pid, start_tick = 0, 0
  local fh = io.open("/proc/self/stat", "r")
  if fh then
    local line = fh:read("l") or ""
    fh:close()
    pid = tonumber(line:match("^(%%d+)")) or 0
    local after_comm = line:match("%%) (.*)$")
    if after_comm then
      local idx = 3
      for tok in after_comm:gmatch("%%S+") do
        if idx == 22 then
          start_tick = tonumber(tok) or 0
          break
        end
        idx = idx + 1
      end
    end
  end
  return string.format("%%014d-%%07d-%%s", start_tick, pid, cmd_name)
end

local stdin_data = nil
local should_read = (read_stdin_mode == "always")
  or (read_stdin_mode == "dmenu" and arg[1] == "dmenu")
if should_read then
  stdin_data = io.stdin:read("a") or ""
end

local tag = get_tag()
local stdin_file = nil
if stdin_data ~= nil then
  stdin_file = log_dir .. "/stdin-" .. tag .. ".bin"
  local sf = assert(io.open(stdin_file, "wb"))
  sf:write(stdin_data)
  sf:close()
end

local argv_parts = {}
for i = 1, #arg do
  argv_parts[#argv_parts + 1] = q(arg[i])
end

local payload = "return {\n"
  .. "  cmd = " .. q(cmd_name) .. ",\n"
  .. "  argv = { " .. table.concat(argv_parts, ", ") .. " },\n"
  .. "  stdin_file = " .. (stdin_file and q(stdin_file) or "nil") .. ",\n"
  .. "}\n"

local tmp_path = log_dir .. "/.tmp-" .. tag .. ".lua"
local final_path = log_dir .. "/call-" .. tag .. ".lua"
local lf = assert(io.open(tmp_path, "wb"))
lf:write(payload)
lf:close()
os.rename(tmp_path, final_path)

local exit_code = default_exit
%s
os.exit(exit_code)
]=], cmd_name, opts.log_dir, read_stdin_mode, default_exit, extra_body)
end

-- Faithful Lua stub for `fd` (matches fd 10.x CLI flags and trailing `/` on dirs).
local function make_fd_stub_code(log_dir)
  return "#!/usr/bin/env lua\nlocal log_dir = " .. string.format("%q", log_dir) .. "\n" .. [=[
local function q(s)
  return string.format("%q", tostring(s))
end
local function shq(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Log invocation atomically
do
  local pid, start_tick = 0, 0
  local fh = io.open("/proc/self/stat", "r")
  if fh then
    local line = fh:read("l") or ""
    fh:close()
    pid = tonumber(line:match("^(%d+)")) or 0
    local after_comm = line:match("%) (.*)$")
    if after_comm then
      local idx = 3
      for tok in after_comm:gmatch("%S+") do
        if idx == 22 then
          start_tick = tonumber(tok) or 0
          break
        end
        idx = idx + 1
      end
    end
  end
  local tag = string.format("%014d-%07d-fd", start_tick, pid)
  local parts = {}
  for i = 1, #arg do parts[#parts + 1] = q(arg[i]) end
  local tmp = log_dir .. "/.tmp-" .. tag .. ".lua"
  local fin = log_dir .. "/call-" .. tag .. ".lua"
  local lf = assert(io.open(tmp, "wb"))
  lf:write("return { cmd = \"fd\", argv = { " .. table.concat(parts, ", ") .. " } }\n")
  lf:close()
  os.rename(tmp, fin)
end

local hidden = false
local glob_mode = false
local fixed_mode = false
local full_path = false
local ignore_case = false
local print0 = false
local prune = false
local min_depth = 1
local max_depth = nil
local max_results = nil
local types = {}
local excludes = {}
local search_paths = {}
local base_dir = nil
local pos = {}

local function add_type(t)
  if t == "d" or t == "directory" then types.d = true
  elseif t == "f" or t == "file" then types.f = true
  elseif t == "l" or t == "symlink" then types.l = true
  end
end

local i = 1
local stop_opts = false
while i <= #arg do
  local a = arg[i]
  if stop_opts or a == "-" or a:sub(1, 1) ~= "-" then
    pos[#pos + 1] = a
  elseif a == "--" then
    stop_opts = true
  elseif a == "--hidden" then hidden = true
  elseif a == "--no-ignore" or a == "--no-ignore-vcs" or a == "--unrestricted"
      or a == "--absolute-path" or a == "--follow" or a == "--strip-cwd-prefix" then
    -- accepted no-op
  elseif a == "--glob" then glob_mode = true
  elseif a == "--fixed-strings" then fixed_mode = true
  elseif a == "--full-path" then full_path = true
  elseif a == "--ignore-case" then ignore_case = true
  elseif a == "--case-sensitive" then ignore_case = false
  elseif a == "--print0" then print0 = true
  elseif a == "--prune" then prune = true
  elseif a == "--type" then i = i + 1; add_type(arg[i])
  elseif a:match("^%-%-type=") then add_type(a:match("^%-%-type=(.*)$"))
  elseif a == "--max-depth" or a == "--maxdepth" then i = i + 1; max_depth = tonumber(arg[i])
  elseif a:match("^%-%-max%-?depth=") then max_depth = tonumber(a:match("=(.*)$"))
  elseif a == "--min-depth" or a == "--mindepth" then i = i + 1; min_depth = tonumber(arg[i]) or 1
  elseif a:match("^%-%-min%-?depth=") then min_depth = tonumber(a:match("=(.*)$")) or 1
  elseif a == "--exact-depth" then i = i + 1; local n = tonumber(arg[i]); min_depth = n; max_depth = n
  elseif a:match("^%-%-exact%-depth=") then local n = tonumber(a:match("=(.*)$")); min_depth = n; max_depth = n
  elseif a == "--exclude" then i = i + 1; excludes[#excludes + 1] = arg[i]
  elseif a:match("^%-%-exclude=") then excludes[#excludes + 1] = a:match("=(.*)$")
  elseif a == "--color" then i = i + 1
  elseif a:match("^%-%-color=") then
  elseif a == "--search-path" then i = i + 1; search_paths[#search_paths + 1] = arg[i]
  elseif a:match("^%-%-search%-path=") then search_paths[#search_paths + 1] = a:match("=(.*)$")
  elseif a == "--base-directory" then i = i + 1; base_dir = arg[i]
  elseif a:match("^%-%-base%-directory=") then base_dir = a:match("=(.*)$")
  elseif a:sub(1, 2) ~= "--" then
    local flags = a:sub(2)
    local j = 1
    while j <= #flags do
      local ch = flags:sub(j, j)
      if ch == "H" then hidden = true
      elseif ch == "I" or ch == "u" or ch == "a" or ch == "L" then
      elseif ch == "g" then glob_mode = true
      elseif ch == "F" then fixed_mode = true
      elseif ch == "p" then full_path = true
      elseif ch == "i" then ignore_case = true
      elseif ch == "s" then ignore_case = false
      elseif ch == "0" then print0 = true
      elseif ch == "1" then max_results = 1
      elseif ch == "t" then
        local rest = flags:sub(j + 1)
        if rest ~= "" then add_type(rest); break
        else i = i + 1; add_type(arg[i]); break end
      elseif ch == "d" then
        local rest = flags:sub(j + 1)
        if rest ~= "" then max_depth = tonumber(rest); break
        else i = i + 1; max_depth = tonumber(arg[i]); break end
      elseif ch == "E" then
        local rest = flags:sub(j + 1)
        if rest ~= "" then excludes[#excludes + 1] = rest; break
        else i = i + 1; excludes[#excludes + 1] = arg[i]; break end
      elseif ch == "c" then
        local rest = flags:sub(j + 1)
        if rest == "" then i = i + 1 end
        break
      end
      j = j + 1
    end
  end
  i = i + 1
end

local pattern = ""
if #search_paths > 0 then
  pattern = pos[1] or ""
elseif #pos == 0 then
  pattern = ""
  search_paths = { "." }
elseif #pos == 1 then
  pattern = pos[1]
  search_paths = { "." }
else
  pattern = pos[1]
  for k = 2, #pos do
    search_paths[#search_paths + 1] = pos[k]
  end
end

local function glob_to_lua(g)
  local esc = g:gsub("([%^%$%(%)%%%.%[%]%+%-%?%*])", function(c)
    if c == "*" then return ".*" end
    if c == "?" then return "." end
    return "%" .. c
  end)
  return "^" .. esc .. "$"
end

local function regex_to_lua(r)
  -- Translate common Rust regex escapes (e.g. \.git, ^\.git$) to Lua pattern
  local out = {}
  local k = 1
  while k <= #r do
    local c = r:sub(k, k)
    if c == "\\" and k < #r then
      local nxt = r:sub(k + 1, k + 1)
      if nxt:match("[%p]") then
        out[#out + 1] = "%" .. nxt
      else
        out[#out + 1] = nxt
      end
      k = k + 2
    elseif c == "%" then
      out[#out + 1] = "%%"
      k = k + 1
    else
      out[#out + 1] = c
      k = k + 1
    end
  end
  return table.concat(out)
end

local lua_pat = nil
if pattern ~= "" and not (not glob_mode and not fixed_mode and pattern == ".") then
  local p = ignore_case and pattern:lower() or pattern
  if fixed_mode then
    lua_pat = p
  elseif glob_mode then
    lua_pat = glob_to_lua(p)
  else
    lua_pat = regex_to_lua(p)
  end
end

local function matches_pattern(name)
  if not lua_pat then return true end
  local hay = ignore_case and name:lower() or name
  if fixed_mode then
    return hay:find(lua_pat, 1, true) ~= nil
  end
  return hay:find(lua_pat) ~= nil
end

local function has_hidden_component(rel)
  for seg in rel:gmatch("[^/]+") do
    if seg:sub(1, 1) == "." then
      return true
    end
  end
  return false
end

local function is_excluded(rel)
  if #excludes == 0 then return false end
  local base = rel:match("([^/]+)$") or rel
  for _, ex in ipairs(excludes) do
    local ep = glob_to_lua(ex)
    if base:find(ep) or rel:find(ep) then
      return true
    end
  end
  return false
end

local has_type_filter = next(types) ~= nil
local results = {}

for _, sp in ipairs(search_paths) do
  local root = sp
  if base_dir and root:sub(1, 1) ~= "/" then
    root = base_dir .. "/" .. root
  end
  local clean_root = root:gsub("/+$", "")
  if clean_root == "" then clean_root = "/" end
  local cmd = "find " .. shq(clean_root) .. " -mindepth 1"
  if max_depth then
    cmd = cmd .. " -maxdepth " .. tostring(max_depth)
  end
  cmd = cmd .. " -printf '%y\t%P\n' 2>/dev/null | sort"
  local ph = io.popen(cmd, "r")
  if ph then
    local pruned_prefixes = {}
    for line in ph:lines() do
      local ftype, rel = line:match("^([^\t]+)\t(.*)$")
      if ftype and rel and rel ~= "" then
        local skip = false
        for _, pref in ipairs(pruned_prefixes) do
          if rel:sub(1, #pref) == pref then
            skip = true
            break
          end
        end
        if not skip then
          local depth = 1
          for _ in rel:gmatch("/") do depth = depth + 1 end
          if depth >= min_depth and (not max_depth or depth <= max_depth) then
            if (hidden or not has_hidden_component(rel)) and not is_excluded(rel) then
              if (not has_type_filter) or types[ftype] then
                local target = full_path and (clean_root .. "/" .. rel) or (rel:match("([^/]+)$") or rel)
                if matches_pattern(target) then
                  local out_path = clean_root .. "/" .. rel
                  if ftype == "d" then
                    out_path = out_path .. "/"
                  end
                  results[#results + 1] = out_path
                  if prune and ftype == "d" then
                    pruned_prefixes[#pruned_prefixes + 1] = rel .. "/"
                  end
                end
              end
            end
          end
        end
      end
    end
    ph:close()
  end
end

if max_results and #results > max_results then
  for k = #results, max_results + 1, -1 do
    results[k] = nil
  end
end

local sep = print0 and "\0" or "\n"
for _, r in ipairs(results) do
  io.stdout:write(r, sep)
end
]=]
end

local function create_sandbox(opts)
  opts = opts or {}
  local raw = popen_capture("mktemp -d /tmp/kaze-bb-pkt-XXXXXX")
  local root = raw:gsub("%s+$", "")
  assert(root ~= "" and root:match("^/tmp/kaze%-bb%-pkt%-"), "mktemp failed: " .. tostring(raw))

  local sb = {
    root = root,
    home = root .. "/home",
    xdg_config = root .. "/xdg/config",
    xdg_data = root .. "/xdg/data",
    xdg_cache = root .. "/xdg/cache",
    xdg_state = root .. "/xdg/state",
    xdg_runtime = root .. "/xdg/runtime",
    bin = root .. "/bin",
    logs = root .. "/logs",
    tmp = root .. "/tmp",
  }

  mkdir_p(sb.home)
  mkdir_p(sb.xdg_config)
  mkdir_p(sb.xdg_data)
  mkdir_p(sb.xdg_cache)
  mkdir_p(sb.xdg_state)
  mkdir_p(sb.xdg_runtime)
  mkdir_p(sb.bin)
  mkdir_p(sb.logs)
  mkdir_p(sb.tmp)

  -- Symlink safe base coreutils into hermetic sb.bin
  for _, tool in ipairs(BASE_COREUTILS) do
    local p = find_host_bin(tool)
    if p then
      os.execute("ln -sf -- " .. sh_quote(p) .. " " .. sh_quote(sb.bin .. "/" .. tool))
    end
  end

  -- Optionally symlink host bsdtar and sha256sum
  if opts.with_bsdtar ~= false then
    local p = find_host_bin("bsdtar")
    if p then
      os.execute("ln -sf -- " .. sh_quote(p) .. " " .. sh_quote(sb.bin .. "/bsdtar"))
      sb.has_bsdtar = true
    end
  end
  if opts.with_sha256sum ~= false then
    local p = find_host_bin("sha256sum")
    if p then
      os.execute("ln -sf -- " .. sh_quote(p) .. " " .. sh_quote(sb.bin .. "/sha256sum"))
      sb.has_sha256sum = true
    end
  end

  function sb:install_stub(name, cfg)
    cfg = cfg or {}
    cfg.log_dir = self.logs
    local code = make_lua_stub_code(name, cfg)
    local path = self.bin .. "/" .. name
    write_file(path, code)
    chmod_x(path)
    return path
  end

  function sb:install_fd_stub()
    local path = self.bin .. "/fd"
    write_file(path, make_fd_stub_code(self.logs))
    chmod_x(path)
    return path
  end

  function sb:install_zoxide_stub(query_lines, opts_z)
    opts_z = opts_z or {}
    local lines_code = {}
    for _, l in ipairs(query_lines or {}) do
      lines_code[#lines_code + 1] = string.format("%q", l)
    end
    local extra = string.format([[
local query_lines = { %s }
if arg[1] == "query" then
  for _, l in ipairs(query_lines) do
    io.stdout:write(l, "\n")
  end
  exit_code = %d
elseif arg[1] == "add" then
  exit_code = %d
end
]], table.concat(lines_code, ", "), opts_z.query_exit or 0, opts_z.add_exit or 0)
    return self:install_stub("zoxide", {
      read_stdin = "never",
      extra_body = extra,
    })
  end

  function sb:install_noctalia_stub(cfg)
    cfg = cfg or {}
    local dmenu_stdout = cfg.dmenu_stdout or ""
    local dmenu_stderr = cfg.dmenu_stderr or ""
    local dmenu_exit = cfg.dmenu_exit or 0
    local msg_stdout = cfg.msg_stdout or ""
    local msg_stderr = cfg.msg_stderr or ""
    local msg_exit = cfg.msg_exit or 0
    local extra = string.format([[
if arg[1] == "dmenu" then
  local out = %q
  local err = %q
  if out ~= "" then io.stdout:write(out) end
  if err ~= "" then io.stderr:write(err) end
  exit_code = %d
else
  local out = %q
  local err = %q
  if out ~= "" then io.stdout:write(out) end
  if err ~= "" then io.stderr:write(err) end
  exit_code = %d
end
]], dmenu_stdout, dmenu_stderr, dmenu_exit, msg_stdout, msg_stderr, msg_exit)
    return self:install_stub("kaze-shell", {
      read_stdin = "dmenu",
      extra_body = extra,
    })
  end

  function sb:remove_bin(name)
    os.remove(self.bin .. "/" .. name)
  end

  function sb:write_user_lua(content)
    mkdir_p(self.xdg_config .. "/hypr")
    write_file(self.xdg_config .. "/hypr/user.lua", content)
  end

  function sb:remove_user_lua()
    os.remove(self.xdg_config .. "/hypr/user.lua")
  end

  function sb:clear_logs()
    os.execute("rm -rf -- " .. sh_quote(self.logs) .. "/*")
  end

  function sb:read_calls(cmd_filter)
    local files = list_dir_entries(self.logs)
    local calls = {}
    for _, fname in ipairs(files) do
      if fname:match("^call%-.*%.lua$") then
        local chunk = loadfile(self.logs .. "/" .. fname, "t", {})
        if chunk then
          local ok, entry = pcall(chunk)
          if ok and type(entry) == "table" then
            if (not cmd_filter) or entry.cmd == cmd_filter then
              if entry.stdin_file then
                entry.stdin = read_file(entry.stdin_file) or ""
              end
              calls[#calls + 1] = entry
            end
          end
        end
      end
    end
    return calls
  end

  function sb:wait_for_calls(cmd_filter, min_count, timeout_ms)
    timeout_ms = timeout_ms or 1000
    local waited = 0
    local step = 20
    while true do
      local calls = self:read_calls(cmd_filter)
      if #calls >= min_count then
        return calls
      end
      if waited >= timeout_ms then
        return calls
      end
      sleep_ms(step)
      waited = waited + step
    end
  end

  function sb:run(exe_path, args, run_opts)
    run_opts = run_opts or {}
    local out_file = self.tmp .. "/stdout.txt"
    local err_file = self.tmp .. "/stderr.txt"
    os.remove(out_file)
    os.remove(err_file)

    local env_map = {
      PATH = self.bin,
      HOME = self.home,
      XDG_CONFIG_HOME = self.xdg_config,
      XDG_DATA_HOME = self.xdg_data,
      XDG_CACHE_HOME = self.xdg_cache,
      XDG_STATE_HOME = self.xdg_state,
      XDG_RUNTIME_DIR = self.xdg_runtime,
      TMPDIR = self.tmp,
      USER = "kaze_test",
      SHELL = self.bin .. "/sh",
      LC_ALL = "C",
    }
    if run_opts.env then
      for k, v in pairs(run_opts.env) do
        if v == false then
          env_map[k] = nil
        else
          env_map[k] = tostring(v)
        end
      end
    end

    local parts = { "env", "-i" }
    local keys = {}
    for k in pairs(env_map) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
      parts[#parts + 1] = sh_quote(k .. "=" .. env_map[k])
    end
    parts[#parts + 1] = sh_quote(exe_path)
    for _, a in ipairs(args or {}) do
      parts[#parts + 1] = sh_quote(a)
    end

    local cmd = table.concat(parts, " ")
      .. " >" .. sh_quote(out_file)
      .. " 2>" .. sh_quote(err_file)
      .. " </dev/null"
    if run_opts.cwd then
      cmd = "cd " .. sh_quote(run_opts.cwd) .. " && " .. cmd
    end

    local code = exec_code(cmd)
    return {
      code = code,
      stdout = read_file(out_file) or "",
      stderr = read_file(err_file) or "",
    }
  end

  return sb
end

local function with_sandbox(opts, fn)
  if type(opts) == "function" then
    fn = opts
    opts = {}
  end
  local sb = create_sandbox(opts)
  local ok, err = pcall(fn, sb)
  os.execute("rm -rf -- " .. sh_quote(sb.root))
  if not ok then
    error(err, 0)
  end
end

local function run_suite(test, assert_eq, assert_true, assert_contains, repo_dir)
  local abs_repo = popen_capture("cd " .. sh_quote(repo_dir or ".") .. " && pwd"):gsub("%s+$", "")
  local BIN_PROJECT = abs_repo .. "/bin/kaze-project"
  local BIN_KEYS = abs_repo .. "/bin/kaze-keys"
  local BIN_THUNAR = abs_repo .. "/bin/kaze-thunar-action"

  local function argv_has_seq(argv, seq)
    if type(argv) ~= "table" or #seq == 0 or #argv < #seq then
      return false
    end
    for start = 1, #argv - #seq + 1 do
      local match = true
      for j = 1, #seq do
        if argv[start + j - 1] ~= seq[j] then
          match = false
          break
        end
      end
      if match then
        return true
      end
    end
    return false
  end

  local function argv_has_token(argv, tok)
    for _, v in ipairs(argv or {}) do
      if v == tok then
        return true
      end
    end
    return false
  end

  local function assert_argv(call, expected, label)
    assert_true(
      argv_equals(call.argv, expected),
      (label or "argv mismatch")
        .. ": expected " .. fmt_argv(expected)
        .. ", got " .. fmt_argv(call and call.argv)
    )
  end

  local function assert_foot_shell(call, dir, label)
    assert_true(
      argv_has_seq(call.argv, { "-N", "-D", dir }) and not argv_has_token(call.argv, "-e"),
      (label or "footclient shell argv")
        .. ": expected contiguous [-N, -D, " .. string.format("%q", dir)
        .. "] without -e, got " .. fmt_argv(call and call.argv)
    )
  end

  local function assert_foot_editor(call, dir, editor, label)
    assert_true(
      argv_has_seq(call.argv, { "-N", "-D", dir, "-e", editor, "." }),
      (label or "footclient editor argv")
        .. ": expected contiguous [-N, -D, " .. string.format("%q", dir)
        .. ", -e, " .. string.format("%q", editor) .. ", \".\"], got " .. fmt_argv(call and call.argv)
    )
  end

  -- =========================================================================
  -- 1. bin/kaze-project: CLI validation
  -- =========================================================================
  test("bb.project.cli_validation", function()
    with_sandbox(function(sb)
      sb:install_stub("footclient")
      sb:install_zoxide_stub({})
      sb:install_fd_stub()
      sb:install_noctalia_stub({})

      local existing1 = sb.home .. "/Projects/dir1"
      local existing2 = sb.home .. "/Projects/dir2"
      mkdir_p(existing1)
      mkdir_p(existing2)

      -- -h and --help -> exit 0
      for _, flag in ipairs({ "-h", "--help" }) do
        local res = sb:run(BIN_PROJECT, { flag })
        assert_eq(res.code, 0, flag .. " must exit 0; stderr=" .. res.stderr)
        assert_true(#res.stdout > 0, flag .. " must print help text")
      end

      -- Usage/flag errors -> exit 2
      local exit2_cases = {
        { name = "unknown long flag", args = { "--bogus-flag" } },
        { name = "unknown short flag", args = { "-z" } },
        { name = "missing --mode value", args = { "--mode" } },
        { name = "invalid --mode value", args = { "--mode", "bogus" } },
        { name = "invalid --mode= value", args = { "--mode=invalid" } },
        { name = "empty --mode= value", args = { "--mode=" } },
        { name = "--list with DIR", args = { "--list", existing1 } },
        { name = "DIR with --list", args = { existing1, "--list" } },
        { name = "two positional DIRs", args = { existing1, existing2 } },
      }
      for _, tc in ipairs(exit2_cases) do
        local res = sb:run(BIN_PROJECT, tc.args)
        assert_eq(res.code, 2, tc.name .. " must exit 2; stdout=" .. res.stdout .. " stderr=" .. res.stderr)
      end

      -- Nonexistent target DIR -> exit 1
      local exit1_cases = {
        { sb.root .. "/does-not-exist-xyz" },
        { "--shell", sb.root .. "/does-not-exist-xyz" },
        { "~/nonexistent-project-dir" },
      }
      for _, args in ipairs(exit1_cases) do
        local res = sb:run(BIN_PROJECT, args)
        assert_eq(res.code, 1, "nonexistent DIR " .. fmt_argv(args) .. " must exit 1; stderr=" .. res.stderr)
      end

      sleep_ms(40)
      assert_eq(#sb:read_calls("footclient"), 0, "no footclient should launch on CLI errors")
    end)
  end)

  -- =========================================================================
  -- 2. bin/kaze-project: Discovery (--list)
  -- =========================================================================
  test("bb.project.discovery_list", function()
    with_sandbox(function(sb)
      sb:install_fd_stub()

      -- Create default project roots (~/dev intentionally omitted!)
      mkdir_p(sb.home .. "/Projects/alpha/.git")
      mkdir_p(sb.home .. "/Projects/group/beta/.git")
      mkdir_p(sb.home .. "/Projects/plain-dir")
      mkdir_p(sb.home .. "/Code/gamma/.git")
      mkdir_p(sb.home .. "/src/delta")
      mkdir_p(sb.home .. "/Workspace/eps")

      -- Also an existing project outside $HOME
      local outside_repo = sb.root .. "/external/outside-repo"
      mkdir_p(outside_repo .. "/.git")

      -- zoxide query -l returns frecency order with nonexistent + trailing-slash duplicate
      sb:install_zoxide_stub({
        sb.home .. "/Projects/ghost-missing-dir",
        sb.home .. "/Code/gamma",
        sb.home .. "/Projects/alpha",
        outside_repo,
        sb.home .. "/Projects/alpha/",
      })

      local res = sb:run(BIN_PROJECT, { "--list" })
      assert_eq(res.code, 0, "--list must exit 0; stderr=" .. res.stderr)

      local lines = non_empty_lines(res.stdout)
      assert_true(#lines >= 7, "expected >=7 discovered entries, got " .. #lines .. ":\n" .. res.stdout)

      -- Index map & duplicate check
      local index_of = {}
      for idx, line in ipairs(lines) do
        assert_true(index_of[line] == nil, "duplicate entry in --list: " .. line)
        assert_true(not line:find(sb.home .. "/", 1, true), "HOME prefix must be compacted to ~/: " .. line)
        index_of[line] = idx
      end

      -- Nonexistent zoxide entry must be ignored
      assert_true(index_of["~/Projects/ghost-missing-dir"] == nil, "nonexistent zoxide dir must be ignored")

      -- All valid projects discovered & HOME compacted
      local expected_entries = {
        "~/Code/gamma",
        "~/Projects/alpha",
        outside_repo,
        "~/Projects/group/beta",
        "~/Projects/plain-dir",
        "~/src/delta",
        "~/Workspace/eps",
      }
      for _, e in ipairs(expected_entries) do
        assert_true(index_of[e] ~= nil, "missing discovered project " .. e .. " in:\n" .. res.stdout)
      end

      -- Zoxide frecency order comes first, ahead of fd-only discoveries
      assert_true(index_of["~/Code/gamma"] < index_of["~/Projects/alpha"], "zoxide frecency order violated")
      assert_true(index_of["~/Projects/alpha"] < index_of[outside_repo], "zoxide frecency order violated (outside)")
      assert_true(index_of[outside_repo] < index_of["~/Projects/plain-dir"], "zoxide entries must precede fd-only entries")
      assert_true(index_of[outside_repo] < index_of["~/src/delta"], "zoxide entries must precede ~/src entries")

      -- Custom project_dirs from $XDG_CONFIG_HOME/hypr/user.lua overrides defaults
      local custom_home = sb.home .. "/CustomRoot/custom-repo"
      local custom_ext = sb.root .. "/alt-root/alt-proj"
      mkdir_p(custom_home .. "/.git")
      mkdir_p(custom_ext .. "/.git")

      sb:install_zoxide_stub({})
      sb:write_user_lua(string.format([[
return {
  project_dirs = { "~/CustomRoot", %q },
}
]], sb.root .. "/alt-root"))

      local res2 = sb:run(BIN_PROJECT, { "--list" })
      assert_eq(res2.code, 0, "custom project_dirs --list must exit 0; stderr=" .. res2.stderr)
      local idx2 = {}
      for i, l in ipairs(non_empty_lines(res2.stdout)) do
        assert_true(idx2[l] == nil, "duplicate in custom --list: " .. l)
        idx2[l] = i
      end
      assert_true(idx2["~/CustomRoot/custom-repo"] ~= nil, "custom ~/CustomRoot/custom-repo missing:\n" .. res2.stdout)
      assert_true(idx2[custom_ext] ~= nil, "custom external root project missing:\n" .. res2.stdout)
      assert_true(idx2["~/Projects/alpha"] == nil, "default ~/Projects must not appear when user.lua sets project_dirs")

      -- Works cleanly even when zoxide is absent from PATH
      sb:remove_bin("zoxide")
      local res3 = sb:run(BIN_PROJECT, { "--list" })
      assert_eq(res3.code, 0, "--list without zoxide must exit 0; stderr=" .. res3.stderr)
      assert_contains(res3.stdout, "~/CustomRoot/custom-repo", "fd discovery must still work without zoxide")
    end)
  end)

  -- =========================================================================
  -- 3. bin/kaze-project: Modes & Direct Launch (shell/nvim/split + user.lua)
  -- =========================================================================
  test("bb.project.modes_and_direct_launch", function()
    with_sandbox(function(sb)
      sb:install_stub("footclient")
      sb:install_stub("nvim")
      sb:install_zoxide_stub({})
      sb:install_fd_stub()

      -- Directory with spaces AND single quote (tested via both ~/... and abs path!)
      local space_dir = sb.home .. "/Projects/my's cool app"
      local tilde_dir = "~/Projects/my's cool app"
      mkdir_p(space_dir .. "/.git")

      local function assert_zoxide_added(expected_dir, ctx)
        local zcalls = sb:wait_for_calls("zoxide", 1, 500)
        local found = false
        for _, c in ipairs(zcalls) do
          if argv_equals(c.argv, { "add", "--", expected_dir }) then
            found = true
            break
          end
        end
        assert_true(found, ctx .. ": expected zoxide add -- " .. expected_dir)
      end

      -- All shell mode flag variants
      for _, flag_args in ipairs({
        { "--shell", tilde_dir },
        { "--mode", "shell", space_dir },
        { "--mode=shell", tilde_dir },
      }) do
        sb:clear_logs()
        local res = sb:run(BIN_PROJECT, flag_args)
        assert_eq(res.code, 0, "shell launch " .. fmt_argv(flag_args) .. " failed; stderr=" .. res.stderr)
        assert_zoxide_added(space_dir, "shell " .. fmt_argv(flag_args))
        local fc = sb:wait_for_calls("footclient", 1, 800)
        sleep_ms(30)
        fc = sb:read_calls("footclient")
        assert_eq(#fc, 1, "shell mode must launch exactly 1 footclient window")
        assert_foot_shell(fc[1], space_dir, "shell footclient argv")
      end

      -- All nvim mode flag variants
      for _, flag_args in ipairs({
        { "--nvim", tilde_dir },
        { "--mode", "nvim", space_dir },
        { "--mode=nvim", tilde_dir },
      }) do
        sb:clear_logs()
        local res = sb:run(BIN_PROJECT, flag_args)
        assert_eq(res.code, 0, "nvim launch " .. fmt_argv(flag_args) .. " failed; stderr=" .. res.stderr)
        assert_zoxide_added(space_dir, "nvim " .. fmt_argv(flag_args))
        local fc = sb:wait_for_calls("footclient", 1, 800)
        sleep_ms(30)
        fc = sb:read_calls("footclient")
        assert_eq(#fc, 1, "nvim mode must launch exactly 1 footclient window")
        assert_foot_editor(fc[1], space_dir, "nvim", "nvim footclient argv")
      end

      -- All split mode flag variants -> 2 footclient windows (editor + companion shell)
      for _, flag_args in ipairs({
        { "--split", tilde_dir },
        { "--mode", "split", space_dir },
        { "--mode=split", tilde_dir },
      }) do
        sb:clear_logs()
        local res = sb:run(BIN_PROJECT, flag_args)
        assert_eq(res.code, 0, "split launch " .. fmt_argv(flag_args) .. " failed; stderr=" .. res.stderr)
        assert_zoxide_added(space_dir, "split " .. fmt_argv(flag_args))
        local fc = sb:wait_for_calls("footclient", 2, 1000)
        sleep_ms(30)
        fc = sb:read_calls("footclient")
        assert_eq(#fc, 2, "split mode must launch exactly 2 footclient windows, got " .. #fc)
        local saw_shell, saw_editor = false, false
        for _, c in ipairs(fc) do
          if argv_has_seq(c.argv, { "-N", "-D", space_dir, "-e", "nvim", "." }) then
            saw_editor = true
          elseif argv_has_seq(c.argv, { "-N", "-D", space_dir }) and not argv_has_token(c.argv, "-e") then
            saw_shell = true
          end
        end
        assert_true(saw_editor, "split mode missing editor window; calls=" .. fmt_argv(fc[1].argv) .. " & " .. fmt_argv(fc[2].argv))
        assert_true(saw_shell, "split mode missing companion shell window; calls=" .. fmt_argv(fc[1].argv) .. " & " .. fmt_argv(fc[2].argv))
      end

      -- Default project_mode from user.lua (shell, nvim, split) + CLI override
      sb:write_user_lua('return { project_mode = "shell" }\n')
      sb:clear_logs()
      local r_u1 = sb:run(BIN_PROJECT, { space_dir })
      assert_eq(r_u1.code, 0, "user.lua project_mode=shell failed")
      local fc_u1 = sb:wait_for_calls("footclient", 1, 800)
      sleep_ms(30)
      fc_u1 = sb:read_calls("footclient")
      assert_eq(#fc_u1, 1, "user.lua project_mode=shell must open 1 window")
      assert_foot_shell(fc_u1[1], space_dir, "user.lua shell window")

      sb:write_user_lua('return { project_mode = "nvim" }\n')
      sb:clear_logs()
      local r_u1b = sb:run(BIN_PROJECT, { space_dir })
      assert_eq(r_u1b.code, 0, "user.lua project_mode=nvim failed")
      local fc_u1b = sb:wait_for_calls("footclient", 1, 800)
      sleep_ms(30)
      fc_u1b = sb:read_calls("footclient")
      assert_eq(#fc_u1b, 1, "user.lua project_mode=nvim must open 1 window")
      assert_foot_editor(fc_u1b[1], space_dir, "nvim", "user.lua nvim window")

      sb:write_user_lua('return { project_mode = "split" }\n')
      sb:clear_logs()
      local r_u2 = sb:run(BIN_PROJECT, { space_dir })
      assert_eq(r_u2.code, 0, "user.lua project_mode=split failed")
      local fc_u2 = sb:wait_for_calls("footclient", 2, 1000)
      assert_eq(#fc_u2, 2, "user.lua project_mode=split must open 2 windows")

      -- CLI flag overrides user.lua project_mode
      sb:clear_logs()
      local r_u3 = sb:run(BIN_PROJECT, { "--nvim", space_dir })
      assert_eq(r_u3.code, 0, "CLI --nvim override failed")
      local fc_u3 = sb:wait_for_calls("footclient", 1, 800)
      sleep_ms(30)
      fc_u3 = sb:read_calls("footclient")
      assert_eq(#fc_u3, 1, "CLI --nvim override must open 1 window")
      assert_foot_editor(fc_u3[1], space_dir, "nvim", "CLI --nvim override argv")

      -- Launching without zoxide on PATH still succeeds
      sb:remove_bin("zoxide")
      sb:clear_logs()
      local r_noz = sb:run(BIN_PROJECT, { "--shell", space_dir })
      assert_eq(r_noz.code, 0, "direct launch without zoxide must exit 0; stderr=" .. r_noz.stderr)
      local fc_noz = sb:wait_for_calls("footclient", 1, 800)
      assert_eq(#fc_noz, 1, "footclient must launch even when zoxide is absent")
    end)
  end)

  -- =========================================================================
  -- 4. bin/kaze-project: Interactive dmenu & zero-projects notify-send
  -- =========================================================================
  test("bb.project.interactive_dmenu", function()
    with_sandbox(function(sb)
      sb:install_stub("footclient")
      sb:install_stub("nvim")
      sb:install_stub("notify-send")
      sb:install_fd_stub()
      sb:install_zoxide_stub({})

      -- Case 1: 0 projects discovered -> notifies via notify-send and exits 0
      sb:install_noctalia_stub({ dmenu_stdout = "" })
      local r_empty = sb:run(BIN_PROJECT, {})
      assert_eq(r_empty.code, 0, "0 discovered projects must exit 0; stderr=" .. r_empty.stderr)
      local ns = sb:wait_for_calls("notify-send", 1, 600)
      assert_true(#ns >= 1, "0 discovered projects must notify via notify-send")
      assert_eq(#sb:read_calls("footclient"), 0, "0 discovered projects must not launch footclient")

      -- Create discovered projects + an unlisted existing dir
      local proj_a = sb.home .. "/Projects/alpha"
      local unlisted_dir = sb.root .. "/unlisted/my proj"
      mkdir_p(proj_a .. "/.git")
      mkdir_p(unlisted_dir)

      -- Case 2: Choosing a listed label launches that dir
      sb:clear_logs()
      sb:install_noctalia_stub({ dmenu_stdout = "~/Projects/alpha\n", dmenu_exit = 0 })
      local r_sel = sb:run(BIN_PROJECT, { "--shell" })
      assert_eq(r_sel.code, 0, "dmenu selection must exit 0; stderr=" .. r_sel.stderr)
      local noc = sb:read_calls("kaze-shell")
      assert_eq(#noc, 1, "expected 1 kaze-shell dmenu call")
      assert_argv(noc[1], { "dmenu", "-p", "Project > " }, "kaze-project dmenu argv")
      assert_contains(noc[1].stdin, "~/Projects/alpha", "dmenu stdin must include ~/Projects/alpha")
      local fc_sel = sb:wait_for_calls("footclient", 1, 800)
      assert_eq(#fc_sel, 1, "selecting project must launch footclient")
      assert_foot_shell(fc_sel[1], proj_a, "selected project footclient argv")

      -- Case 3: Empty selection (Esc cancel) exits 0 without launching anything
      sb:clear_logs()
      sb:install_noctalia_stub({ dmenu_stdout = "", dmenu_exit = 0 })
      local r_esc = sb:run(BIN_PROJECT, { "--shell" })
      assert_eq(r_esc.code, 0, "Esc cancel must exit 0; stderr=" .. r_esc.stderr)
      sleep_ms(40)
      assert_eq(#sb:read_calls("footclient"), 0, "Esc cancel must not launch footclient")

      -- Case 4: Typing a valid existing path not in the list launches it (abs & tilde)
      local unlisted_home = sb.home .. "/unlisted-home-dir"
      mkdir_p(unlisted_home)
      for _, typed_case in ipairs({
        { input = unlisted_dir .. "\n", expected = unlisted_dir },
        { input = "~/unlisted-home-dir\n", expected = unlisted_home },
      }) do
        sb:clear_logs()
        sb:install_noctalia_stub({ dmenu_stdout = typed_case.input, dmenu_exit = 0 })
        local r_typed = sb:run(BIN_PROJECT, { "--shell" })
        assert_eq(r_typed.code, 0, "typing valid unlisted path must exit 0; stderr=" .. r_typed.stderr)
        local fc_typed = sb:wait_for_calls("footclient", 1, 800)
        assert_eq(#fc_typed, 1, "typed valid dir must launch footclient")
        assert_foot_shell(fc_typed[1], typed_case.expected, "typed valid dir footclient argv")
      end

      -- Case 5: Typing a nonexistent garbage string exits 1 without launching
      sb:clear_logs()
      sb:install_noctalia_stub({ dmenu_stdout = "not-a-real-path-99999\n", dmenu_exit = 0 })
      local r_bad = sb:run(BIN_PROJECT, { "--shell" })
      assert_eq(r_bad.code, 1, "typing nonexistent garbage in dmenu must exit 1; stderr=" .. r_bad.stderr)
      sleep_ms(40)
      assert_eq(#sb:read_calls("footclient"), 0, "nonexistent garbage must not launch footclient")
    end)
  end)

  -- =========================================================================
  -- 5. bin/kaze-keys: CLI validation
  -- =========================================================================
  test("bb.keys.cli_validation", function()
    with_sandbox(function(sb)
      sb:install_noctalia_stub({})

      for _, flag in ipairs({ "-h", "--help" }) do
        local res = sb:run(BIN_KEYS, { flag })
        assert_eq(res.code, 0, flag .. " must exit 0; stderr=" .. res.stderr)
        assert_true(#res.stdout > 0, flag .. " must output usage text")
      end

      local bad_cases = {
        { "--bogus" },
        { "-x" },
        { "positional" },
        { "--list", "--extra" },
        { "--list", "--list" },
        { "a", "b" },
      }
      for _, args in ipairs(bad_cases) do
        local res = sb:run(BIN_KEYS, args)
        assert_eq(res.code, 2, "kaze-keys " .. fmt_argv(args) .. " must exit 2; stderr=" .. res.stderr)
      end

      assert_eq(#sb:read_calls("kaze-shell"), 0, "kaze-shell must not be called on CLI validation errors")
    end)
  end)

  -- =========================================================================
  -- 6. bin/kaze-keys: --list content, invariants, & empty/unset HOME
  -- =========================================================================
  test("bb.keys.list_content_and_invariants", function()
    with_sandbox(function(sb)
      -- No compositor IPC env vars (env -i has no HYPRLAND_INSTANCE_SIGNATURE / WAYLAND_DISPLAY)
      local res = sb:run(BIN_KEYS, { "--list" })
      assert_eq(res.code, 0, "kaze-keys --list must exit 0 without compositor IPC; stderr=" .. res.stderr)

      local lines = non_empty_lines(res.stdout)
      assert_true(#lines >= 10, "expected formatted shortcut rows, got " .. #lines)

      -- Core shortcuts required by specification
      local required_tokens = {
        "Super", "Space", "Return", "/",
        "Shift + P", "Alt + P", "Shift + R", "Shift + I",
        "Ctrl + Alt + M", "Super + O", "Shift + Z",
      }
      for _, tok in ipairs(required_tokens) do
        assert_contains(res.stdout, tok, "missing required shortcut token: " .. tok)
      end

      -- Zero duplicate identical lines
      local seen = {}
      for _, line in ipairs(lines) do
        assert_true(seen[line] == nil, "duplicate identical line in kaze-keys --list: " .. line)
        seen[line] = true
      end

      -- Zero legacy removed tools (case-insensitive)
      local lower_out = res.stdout:lower()
      for _, banned in ipairs({ "kaze-perf", "kaze-menu", "waybar", "fuzzel" }) do
        assert_true(
          lower_out:find(banned, 1, true) == nil,
          "legacy removed tool found in kaze-keys --list: " .. banned
        )
      end

      -- Works when HOME is empty string AND when HOME is completely unset
      local r_empty_home = sb:run(BIN_KEYS, { "--list" }, { env = { HOME = "" } })
      assert_eq(r_empty_home.code, 0, "kaze-keys --list with HOME='' must exit 0; stderr=" .. r_empty_home.stderr)
      assert_eq(r_empty_home.stdout, res.stdout, "HOME='' output should match standard --list output")

      local r_unset_home = sb:run(BIN_KEYS, { "--list" }, { env = { HOME = false } })
      assert_eq(r_unset_home.code, 0, "kaze-keys --list with unset HOME must exit 0; stderr=" .. r_unset_home.stderr)
      assert_eq(r_unset_home.stdout, res.stdout, "unset HOME output should match standard --list output")
    end)
  end)

  -- =========================================================================
  -- 7. bin/kaze-keys: Interactive dmenu & failure modes
  -- =========================================================================
  test("bb.keys.dmenu_interactive_and_errors", function()
    with_sandbox(function(sb)
      local list_res = sb:run(BIN_KEYS, { "--list" })
      assert_eq(list_res.code, 0, "baseline --list failed")

      -- Selection -> exits 0, passes exact dmenu args and shortcut rows on stdin
      sb:install_noctalia_stub({ dmenu_stdout = "Super + Return   Terminal\n", dmenu_exit = 0 })
      local r_sel = sb:run(BIN_KEYS, {})
      assert_eq(r_sel.code, 0, "selection in kaze-keys must exit 0; stderr=" .. r_sel.stderr)
      local calls = sb:read_calls("kaze-shell")
      assert_eq(#calls, 1, "expected 1 kaze-shell call")
      assert_argv(calls[1], { "dmenu", "-p", "Keys > " }, "kaze-keys kaze-shell dmenu argv")
      assert_contains(calls[1].stdin, "Shift + P", "dmenu stdin must include shortcut rows")
      assert_contains(calls[1].stdin, "Ctrl + Alt + M", "dmenu stdin must include Ctrl + Alt + M")
      assert_eq(calls[1].stdin, list_res.stdout, "dmenu stdin should match --list rows")

      -- Esc cancel (empty stdout, exit 0) -> exits 0
      sb:clear_logs()
      sb:install_noctalia_stub({ dmenu_stdout = "", dmenu_exit = 0 })
      local r_esc = sb:run(BIN_KEYS, {})
      assert_eq(r_esc.code, 0, "Esc cancel in kaze-keys must exit 0; stderr=" .. r_esc.stderr)

      -- kaze-shell absent from PATH -> exits 1
      sb:remove_bin("kaze-shell")
      local r_missing = sb:run(BIN_KEYS, {})
      assert_eq(r_missing.code, 1, "missing kaze-shell must cause kaze-keys to exit 1; stderr=" .. r_missing.stderr)

      -- kaze-shell fails unambiguously (exit 2, not Esc cancel) -> exits 1
      sb:clear_logs()
      sb:install_noctalia_stub({ dmenu_stdout = "", dmenu_stderr = "kaze-shell failed\n", dmenu_exit = 2 })
      local r_fail = sb:run(BIN_KEYS, {})
      assert_eq(r_fail.code, 1, "failing kaze-shell (exit 2) must cause kaze-keys to exit 1; stderr=" .. r_fail.stderr)
    end)
  end)

  -- =========================================================================
  -- 8. bin/kaze-thunar-action: CLI validation
  -- =========================================================================
  test("bb.thunar.cli_validation", function()
    with_sandbox(function(sb)
      for _, flag in ipairs({ "-h", "--help" }) do
        local res = sb:run(BIN_THUNAR, { flag })
        assert_eq(res.code, 0, flag .. " must exit 0; stderr=" .. res.stderr)
        assert_true(#res.stdout > 0, flag .. " must print help text")
      end

      -- Missing action
      local r_none = sb:run(BIN_THUNAR, {})
      assert_eq(r_none.code, 2, "missing action must exit 2")

      -- Missing path arg for all 9 actions
      local all_actions = {
        "terminal", "yazi", "editor", "copy-path", "copy-image",
        "wallpaper", "compress", "extract", "checksum",
      }
      for _, act in ipairs(all_actions) do
        local res = sb:run(BIN_THUNAR, { act })
        assert_eq(res.code, 2, "missing path for action '" .. act .. "' must exit 2; stderr=" .. res.stderr)
      end

      -- Unknown action
      for _, bad in ipairs({ "bogus-action", "delete-everything", "--unknown" }) do
        local res = sb:run(BIN_THUNAR, { bad, sb.root })
        assert_eq(res.code, 2, "unknown action '" .. bad .. "' must exit 2; stderr=" .. res.stderr)
      end
    end)
  end)

  -- =========================================================================
  -- 9. bin/kaze-thunar-action: terminal & yazi (with spaces + single quotes)
  -- =========================================================================
  test("bb.thunar.terminal_and_yazi", function()
    with_sandbox(function(sb)
      sb:install_stub("kaze-footclient")
      sb:install_stub("footclient")
      sb:install_stub("yazi")
      sb:install_stub("notify-send")

      local parent_dir = sb.root .. "/dir's space"
      local sub_dir = parent_dir .. "/sub's dir"
      local tricky_file = parent_dir .. "/it's a file.txt"
      mkdir_p(sub_dir)
      write_file(tricky_file, "hello")

      -- terminal <dir> -> kaze-footclient -N -D <dir>
      local r_td = sb:run(BIN_THUNAR, { "terminal", sub_dir })
      assert_eq(r_td.code, 0, "terminal <dir> failed; stderr=" .. r_td.stderr)
      local calls = sb:wait_for_calls("kaze-footclient", 1, 800)
      assert_eq(#calls, 1, "terminal <dir> must invoke kaze-footclient once")
      assert_argv(calls[1], { "-N", "-D", sub_dir }, "terminal <dir> argv")

      -- terminal <file> -> kaze-footclient -N -D <parent>
      sb:clear_logs()
      local r_tf = sb:run(BIN_THUNAR, { "terminal", tricky_file })
      assert_eq(r_tf.code, 0, "terminal <file> failed; stderr=" .. r_tf.stderr)
      calls = sb:wait_for_calls("kaze-footclient", 1, 800)
      assert_eq(#calls, 1, "terminal <file> must invoke kaze-footclient once")
      assert_argv(calls[1], { "-N", "-D", parent_dir }, "terminal <file> argv must open parent dir")

      -- yazi <file> -> kaze-footclient -N -D <parent> -e yazi <file>
      sb:clear_logs()
      local r_yf = sb:run(BIN_THUNAR, { "yazi", tricky_file })
      assert_eq(r_yf.code, 0, "yazi <file> failed; stderr=" .. r_yf.stderr)
      calls = sb:wait_for_calls("kaze-footclient", 1, 800)
      assert_eq(#calls, 1, "yazi <file> must invoke kaze-footclient once")
      assert_argv(calls[1], { "-N", "-D", parent_dir, "-e", "yazi", tricky_file }, "yazi <file> argv")

      -- yazi <dir> -> kaze-footclient -N -D <cwd> -e yazi <dir>
      sb:clear_logs()
      local r_yd = sb:run(BIN_THUNAR, { "yazi", sub_dir })
      assert_eq(r_yd.code, 0, "yazi <dir> failed; stderr=" .. r_yd.stderr)
      calls = sb:wait_for_calls("kaze-footclient", 1, 800)
      assert_eq(#calls, 1, "yazi <dir> must invoke kaze-footclient once")
      assert_true(
        #calls[1].argv == 6
          and calls[1].argv[1] == "-N"
          and calls[1].argv[2] == "-D"
          and is_dir(calls[1].argv[3])
          and calls[1].argv[4] == "-e"
          and calls[1].argv[5] == "yazi"
          and calls[1].argv[6] == sub_dir,
        "yazi <dir> expected [-N, -D, <cwd>, -e, yazi, <dir>], got " .. fmt_argv(calls[1].argv)
      )

      -- yazi missing -> exit 1 + notify-send + no kaze-footclient
      sb:remove_bin("yazi")
      sb:clear_logs()
      local r_ym = sb:run(BIN_THUNAR, { "yazi", tricky_file })
      assert_eq(r_ym.code, 1, "yazi missing must exit 1; stderr=" .. r_ym.stderr)
      local ns = sb:wait_for_calls("notify-send", 1, 600)
      assert_true(#ns >= 1, "yazi missing must notify via notify-send")
      sleep_ms(30)
      assert_eq(#sb:read_calls("kaze-footclient"), 0, "yazi missing must not open kaze-footclient")
    end)
  end)

  -- =========================================================================
  -- 10. bin/kaze-thunar-action: editor priority chain, custom user.lua, & error
  -- =========================================================================
  test("bb.thunar.editor_fallback_and_custom", function()
    with_sandbox(function(sb)
      sb:install_stub("kaze-footclient")
      sb:install_stub("notify-send")
      for _, ed in ipairs({ "codium", "code", "nvim", "vim", "nano", "my-custom-ed" }) do
        sb:install_stub(ed)
      end

      local dir = sb.root .. "/ed's dir"
      mkdir_p(dir)
      local f1 = dir .. "/it's one.txt"
      local f2 = dir .. "/two's file.txt"
      write_file(f1, "1")
      write_file(f2, "2")

      -- 1. Prefers codium (GUI, directly invoked)
      local r1 = sb:run(BIN_THUNAR, { "editor", f1, f2 })
      assert_eq(r1.code, 0, "editor with codium failed; stderr=" .. r1.stderr)
      local c1 = sb:wait_for_calls("codium", 1, 800)
      assert_eq(#c1, 1, "must prefer codium when all editors exist")
      assert_argv(c1[1], { f1, f2 }, "codium argv")
      assert_eq(#sb:read_calls("kaze-footclient"), 0, "GUI codium must not wrap in kaze-footclient")

      -- 2. Fallback to code (GUI)
      sb:remove_bin("codium")
      sb:clear_logs()
      local r2 = sb:run(BIN_THUNAR, { "editor", f1, f2 })
      assert_eq(r2.code, 0, "editor fallback to code failed; stderr=" .. r2.stderr)
      local c2 = sb:wait_for_calls("code", 1, 800)
      assert_eq(#c2, 1, "must fall back to code when codium absent")
      assert_argv(c2[1], { f1, f2 }, "code argv")
      assert_eq(#sb:read_calls("kaze-footclient"), 0, "GUI code must not wrap in kaze-footclient")

      -- 3. Fallback to TUI nvim inside kaze-footclient
      sb:remove_bin("code")
      sb:clear_logs()
      local r3 = sb:run(BIN_THUNAR, { "editor", f1, f2 })
      assert_eq(r3.code, 0, "editor fallback to nvim failed; stderr=" .. r3.stderr)
      local c3 = sb:wait_for_calls("kaze-footclient", 1, 800)
      assert_eq(#c3, 1, "TUI nvim must launch via kaze-footclient")
      assert_argv(c3[1], { "-N", "-D", dir, "-e", "nvim", f1, f2 }, "nvim kaze-footclient argv")

      -- 4. Fallback to TUI vim inside kaze-footclient
      sb:remove_bin("nvim")
      sb:clear_logs()
      local r4 = sb:run(BIN_THUNAR, { "editor", f1, f2 })
      assert_eq(r4.code, 0, "editor fallback to vim failed; stderr=" .. r4.stderr)
      local c4 = sb:wait_for_calls("kaze-footclient", 1, 800)
      assert_eq(#c4, 1, "TUI vim must launch via kaze-footclient")
      assert_argv(c4[1], { "-N", "-D", dir, "-e", "vim", f1, f2 }, "vim kaze-footclient argv")

      -- 5. Fallback to TUI nano inside kaze-footclient
      sb:remove_bin("vim")
      sb:clear_logs()
      local r5 = sb:run(BIN_THUNAR, { "editor", f1, f2 })
      assert_eq(r5.code, 0, "editor fallback to nano failed; stderr=" .. r5.stderr)
      local c5 = sb:wait_for_calls("kaze-footclient", 1, 800)
      assert_eq(#c5, 1, "TUI nano must launch via kaze-footclient")
      assert_argv(c5[1], { "-N", "-D", dir, "-e", "nano", f1, f2 }, "nano kaze-footclient argv")

      -- 6. Custom editor in user.lua takes precedence even when codium is installed
      sb:install_stub("codium")
      sb:write_user_lua('return { editor = "my-custom-ed" }\n')
      sb:clear_logs()
      local r6 = sb:run(BIN_THUNAR, { "editor", f1, f2 })
      assert_eq(r6.code, 0, "custom editor from user.lua failed; stderr=" .. r6.stderr)
      local c6 = sb:wait_for_calls("my-custom-ed", 1, 800)
      assert_eq(#c6, 1, "custom editor must be invoked directly")
      assert_argv(c6[1], { f1, f2 }, "custom editor argv")
      assert_eq(#sb:read_calls("codium"), 0, "codium must not run when custom editor is configured")

      -- 7. No editor found in PATH -> exit 1
      sb:remove_user_lua()
      sb:remove_bin("codium")
      sb:remove_bin("nano")
      sb:remove_bin("my-custom-ed")
      sb:clear_logs()
      local r7 = sb:run(BIN_THUNAR, { "editor", f1 })
      assert_eq(r7.code, 1, "no editor in PATH must exit 1; stderr=" .. r7.stderr)
    end)
  end)

  -- =========================================================================
  -- 11. bin/kaze-thunar-action: copy-path & wallpaper
  -- =========================================================================
  test("bb.thunar.copy_path_and_wallpaper", function()
    with_sandbox(function(sb)
      sb:install_stub("wl-copy", { read_stdin = "always" })
      sb:install_stub("notify-send")
      sb:install_noctalia_stub({ msg_exit = 0 })

      local d = sb.root .. "/dir's space"
      mkdir_p(d)
      local f1 = d .. "/it's a file.txt"
      local f2 = d .. "/second 'quoted' file.png"
      write_file(f1, "text")
      write_file(f2, "\137PNG\r\n\26\n")

      -- copy-path single
      local r1 = sb:run(BIN_THUNAR, { "copy-path", f1 })
      assert_eq(r1.code, 0, "copy-path single failed; stderr=" .. r1.stderr)
      local wc = sb:read_calls("wl-copy")
      assert_eq(#wc, 1, "expected 1 wl-copy call")
      assert_eq(wc[1].stdin, f1, "single copy-path must pipe exact path")

      -- copy-path multiple -> newline-joined
      sb:clear_logs()
      local r2 = sb:run(BIN_THUNAR, { "copy-path", f1, f2 })
      assert_eq(r2.code, 0, "copy-path multi failed; stderr=" .. r2.stderr)
      wc = sb:read_calls("wl-copy")
      assert_eq(#wc, 1, "expected 1 wl-copy call for multi path")
      assert_eq(wc[1].stdin, f1 .. "\n" .. f2, "multi copy-path must pipe newline-joined paths")

      -- copy-path missing wl-copy -> exit 1
      sb:remove_bin("wl-copy")
      local r3 = sb:run(BIN_THUNAR, { "copy-path", f1 })
      assert_eq(r3.code, 1, "copy-path without wl-copy must exit 1")

      -- wallpaper existing file -> kaze-shell msg wallpaper-set <path>
      sb:clear_logs()
      local r4 = sb:run(BIN_THUNAR, { "wallpaper", f2 })
      assert_eq(r4.code, 0, "wallpaper valid file failed; stderr=" .. r4.stderr)
      local nc = sb:read_calls("kaze-shell")
      assert_eq(#nc, 1, "expected 1 kaze-shell call for wallpaper")
      assert_argv(nc[1], { "msg", "wallpaper-set", f2 }, "wallpaper kaze-shell argv")

      -- wallpaper missing file -> exit 1 & no kaze-shell call
      sb:clear_logs()
      local r5 = sb:run(BIN_THUNAR, { "wallpaper", d .. "/missing.png" })
      assert_eq(r5.code, 1, "wallpaper missing file must exit 1")
      assert_eq(#sb:read_calls("kaze-shell"), 0, "missing file must not invoke kaze-shell")

      -- wallpaper failing kaze-shell -> exit 1
      sb:clear_logs()
      sb:install_noctalia_stub({ msg_exit = 1, msg_stderr = "ipc failed\n" })
      local r6 = sb:run(BIN_THUNAR, { "wallpaper", f2 })
      assert_eq(r6.code, 1, "failing kaze-shell must make wallpaper exit 1")

      -- wallpaper missing kaze-shell -> exit 1
      sb:remove_bin("kaze-shell")
      local r7 = sb:run(BIN_THUNAR, { "wallpaper", f2 })
      assert_eq(r7.code, 1, "missing kaze-shell must make wallpaper exit 1")
    end)
  end)

  -- =========================================================================
  -- 12. bin/kaze-thunar-action: copy-image brute-force all 11 extensions + .PNG
  -- =========================================================================
  test("bb.thunar.copy_image_all_mimes", function()
    with_sandbox(function(sb)
      sb:install_stub("wl-copy", { read_stdin = "always" })
      sb:install_stub("notify-send")

      local img_dir = sb.root .. "/img's folder"
      mkdir_p(img_dir)

      local cases = {
        { ext = "png",  mime = "image/png" },
        { ext = "PNG",  mime = "image/png" },
        { ext = "jpg",  mime = "image/jpeg" },
        { ext = "jpeg", mime = "image/jpeg" },
        { ext = "gif",  mime = "image/gif" },
        { ext = "webp", mime = "image/webp" },
        { ext = "bmp",  mime = "image/bmp" },
        { ext = "svg",  mime = "image/svg+xml" },
        { ext = "avif", mime = "image/avif" },
        { ext = "jxl",  mime = "image/jxl" },
        { ext = "tif",  mime = "image/tiff" },
        { ext = "tiff", mime = "image/tiff" },
      }

      for _, tc in ipairs(cases) do
        local fpath = img_dir .. "/it's pic." .. tc.ext
        local payload = "\137BIN\0\1\2\255\r\n" .. tc.ext .. "-bytes\0end"
        write_file(fpath, payload)

        sb:clear_logs()
        local res = sb:run(BIN_THUNAR, { "copy-image", fpath })
        assert_eq(res.code, 0, "copy-image ." .. tc.ext .. " failed; stderr=" .. res.stderr)

        local wc = sb:read_calls("wl-copy")
        assert_eq(#wc, 1, "copy-image ." .. tc.ext .. " must invoke wl-copy once")
        assert_argv(wc[1], { "--type", tc.mime }, "copy-image ." .. tc.ext .. " wl-copy argv")
        assert_eq(wc[1].stdin, payload, "copy-image ." .. tc.ext .. " must pipe exact file bytes")
      end

      -- Missing file -> exit 1
      sb:clear_logs()
      local r_miss = sb:run(BIN_THUNAR, { "copy-image", img_dir .. "/missing.png" })
      assert_eq(r_miss.code, 1, "copy-image missing file must exit 1")
      assert_eq(#sb:read_calls("wl-copy"), 0, "copy-image missing file must not invoke wl-copy")

      -- Missing wl-copy -> exit 1
      sb:remove_bin("wl-copy")
      local r_nowl = sb:run(BIN_THUNAR, { "copy-image", img_dir .. "/it's pic.png" })
      assert_eq(r_nowl.code, 1, "copy-image missing wl-copy must exit 1")
    end)
  end)

  -- =========================================================================
  -- 13. bin/kaze-thunar-action: compress (single, multi, collisions, diff parents)
  -- =========================================================================
  test("bb.thunar.compress", function()
    with_sandbox(function(sb)
      if not sb.has_bsdtar then
        return
      end
      sb:install_stub("notify-send")

      local box = sb.root .. "/my's box"
      local other = sb.root .. "/other dir"
      local sub = box .. "/it's dir"
      mkdir_p(sub)
      mkdir_p(other)

      local f_in_sub = sub .. "/nested.txt"
      local single_file = box .. "/it's notes.txt"
      local other_file = other .. "/stray.txt"
      write_file(f_in_sub, "v1-nested")
      write_file(single_file, "v1-single")
      write_file(other_file, "other")

      -- 1. Single directory -> <name>.tar.zst, then collision -> -1.tar.zst without overwriting
      local r1 = sb:run(BIN_THUNAR, { "compress", sub })
      assert_eq(r1.code, 0, "compress single dir failed; stderr=" .. r1.stderr)
      local arc1 = box .. "/it's dir.tar.zst"
      assert_true(is_file(arc1), "expected archive " .. arc1)
      local orig_arc1_bytes = read_file(arc1)
      local list1, rc1 = popen_capture("bsdtar -tf " .. sh_quote(arc1))
      assert_eq(rc1, 0, "bsdtar -tf failed on " .. arc1)
      assert_contains(list1, "nested.txt", "archive must contain nested.txt")

      -- Modify source & compress again -> collision auto-numbering -1.tar.zst, then -2.tar.zst
      write_file(f_in_sub, "v2-nested-updated-payload-longer")
      local r2 = sb:run(BIN_THUNAR, { "compress", sub })
      assert_eq(r2.code, 0, "second compress (collision) failed; stderr=" .. r2.stderr)
      local arc1_coll = box .. "/it's dir-1.tar.zst"
      assert_true(is_file(arc1_coll), "expected collision archive " .. arc1_coll)
      assert_eq(read_file(arc1), orig_arc1_bytes, "original archive must NOT be overwritten on collision")
      local orig_coll1_bytes = read_file(arc1_coll)

      local r3 = sb:run(BIN_THUNAR, { "compress", sub })
      assert_eq(r3.code, 0, "third compress (collision -2) failed; stderr=" .. r3.stderr)
      local arc1_coll2 = box .. "/it's dir-2.tar.zst"
      assert_true(is_file(arc1_coll2), "expected second collision archive " .. arc1_coll2)
      assert_eq(read_file(arc1_coll), orig_coll1_bytes, "-1 archive must NOT be overwritten on -2 collision")

      -- 2. Single file with spaces + single quote -> <name>.tar.zst
      local r_sf = sb:run(BIN_THUNAR, { "compress", single_file })
      assert_eq(r_sf.code, 0, "compress single file failed; stderr=" .. r_sf.stderr)
      local sf_arc = box .. "/it's notes.txt.tar.zst"
      assert_true(is_file(sf_arc), "expected single-file archive " .. sf_arc)
      local list_sf, rc_sf = popen_capture("bsdtar -tf " .. sh_quote(sf_arc))
      assert_eq(rc_sf, 0, "bsdtar -tf failed on single-file archive")
      assert_contains(list_sf, "it's notes.txt", "single-file archive missing member")

      -- 3. Multiple items in same folder -> <parent_basename>-archive.tar.zst + collision -1
      local r_m1 = sb:run(BIN_THUNAR, { "compress", single_file, sub })
      assert_eq(r_m1.code, 0, "compress multi failed; stderr=" .. r_m1.stderr)
      local multi_arc = box .. "/my's box-archive.tar.zst"
      assert_true(is_file(multi_arc), "expected multi archive " .. multi_arc)
      local orig_multi_bytes = read_file(multi_arc)
      local list_m, rc_m = popen_capture("bsdtar -tf " .. sh_quote(multi_arc))
      assert_eq(rc_m, 0, "bsdtar -tf failed on multi archive")
      assert_contains(list_m, "it's notes.txt", "multi archive missing file")
      assert_contains(list_m, "nested.txt", "multi archive missing dir member")

      local r_m2 = sb:run(BIN_THUNAR, { "compress", single_file, sub })
      assert_eq(r_m2.code, 0, "second compress multi (collision) failed; stderr=" .. r_m2.stderr)
      local multi_coll = box .. "/my's box-archive-1.tar.zst"
      assert_true(is_file(multi_coll), "expected multi collision archive " .. multi_coll)
      assert_eq(read_file(multi_arc), orig_multi_bytes, "multi archive must not be overwritten on collision")

      -- 4. Items from DIFFERENT parent folders -> refused with exit 1
      local before_other = #list_dir_entries(other)
      local r_diff = sb:run(BIN_THUNAR, { "compress", single_file, other_file })
      assert_eq(r_diff.code, 1, "compress across different parent dirs must exit 1; stderr=" .. r_diff.stderr)
      assert_eq(#list_dir_entries(other), before_other, "refused compress must not create archives")
    end)
  end)

  -- =========================================================================
  -- 14. bin/kaze-thunar-action: extract (single-root, collision wrap, tarbomb, errors)
  -- =========================================================================
  test("bb.thunar.extract_safe_and_tarbomb", function()
    with_sandbox(function(sb)
      if not sb.has_bsdtar then
        return
      end
      sb:install_stub("notify-send")

      -- Prepare source payloads
      local stage = sb.root .. "/stage"
      mkdir_p(stage .. "/proj/sub")
      write_file(stage .. "/proj/a.txt", "alpha-content")
      write_file(stage .. "/proj/sub/b.txt", "beta-content")
      write_file(stage .. "/loose1.txt", "bomb-one")
      write_file(stage .. "/loose2.txt", "bomb-two")

      -- Case A: Single-root archive extracts directly into parent (<work>/proj/a.txt)
      local w_single = sb.root .. "/w'single"
      mkdir_p(w_single)
      local arc_single = w_single .. "/my's pkg.tar.zst"
      assert_eq(
        exec_code("bsdtar -a -cf " .. sh_quote(arc_single) .. " -C " .. sh_quote(stage) .. " proj"),
        0, "failed creating single-root tar.zst"
      )

      local r1 = sb:run(BIN_THUNAR, { "extract", arc_single })
      assert_eq(r1.code, 0, "extract single-root failed; stderr=" .. r1.stderr)
      assert_eq(read_file(w_single .. "/proj/a.txt"), "alpha-content", "single-root should extract directly to parent/proj/a.txt")
      assert_eq(read_file(w_single .. "/proj/sub/b.txt"), "beta-content", "single-root should extract nested files")

      -- Case B: Single-root archive when <parent>/proj ALREADY EXISTS -> wraps into unique <stem>/
      write_file(w_single .. "/proj/existing.txt", "keep-me")
      local r2 = sb:run(BIN_THUNAR, { "extract", arc_single })
      assert_eq(r2.code, 0, "extract single-root with existing collision failed; stderr=" .. r2.stderr)
      assert_eq(read_file(w_single .. "/proj/existing.txt"), "keep-me", "existing proj/ must remain intact")
      assert_true(is_dir(w_single .. "/my's pkg"), "collision must wrap into <stem>/ (my's pkg)")
      assert_true(
        is_file(w_single .. "/my's pkg/proj/a.txt") or is_file(w_single .. "/my's pkg/a.txt"),
        "wrapped <stem>/ must contain extracted a.txt"
      )

      -- Second collision wraps into <stem>-1/
      local r2b = sb:run(BIN_THUNAR, { "extract", arc_single })
      assert_eq(r2b.code, 0, "second collision wrap failed; stderr=" .. r2b.stderr)
      assert_true(is_dir(w_single .. "/my's pkg-1"), "second collision must wrap into <stem>-1/")

      -- Case C: Multi-root tarbomb across .tar.zst, .tar.gz, .zip (+ collision numbering)
      local w_bomb = sb.root .. "/w'bomb"
      mkdir_p(w_bomb)

      local bomb_specs = {
        { file = "my's zst.tar.zst",     stem = "my's zst" },
        { file = "my's.v1.2.tar.zst",    stem = "my's.v1.2" },
        { file = "my's gz.tar.gz",       stem = "my's gz" },
        { file = "my's zip.zip",         stem = "my's zip" },
      }
      for _, bs in ipairs(bomb_specs) do
        local arc_path = w_bomb .. "/" .. bs.file
        assert_eq(
          exec_code("bsdtar -a -cf " .. sh_quote(arc_path) .. " -C " .. sh_quote(stage) .. " loose1.txt loose2.txt"),
          0, "failed creating tarbomb " .. bs.file
        )
        local rb = sb:run(BIN_THUNAR, { "extract", arc_path })
        assert_eq(rb.code, 0, "extract tarbomb " .. bs.file .. " failed; stderr=" .. rb.stderr)
        assert_true(not path_exists(w_bomb .. "/loose1.txt"), "tarbomb must NOT litter parent dir for " .. bs.file)
        assert_eq(read_file(w_bomb .. "/" .. bs.stem .. "/loose1.txt"), "bomb-one", bs.file .. " must wrap into " .. bs.stem)
        assert_eq(read_file(w_bomb .. "/" .. bs.stem .. "/loose2.txt"), "bomb-two", bs.file .. " missing loose2.txt")
      end

      -- Tarbomb collision -> <stem>-1/ without overwriting <stem>/
      write_file(w_bomb .. "/my's zst/loose1.txt", "edited-keep")
      local rb_coll = sb:run(BIN_THUNAR, { "extract", w_bomb .. "/my's zst.tar.zst" })
      assert_eq(rb_coll.code, 0, "tarbomb collision extract failed; stderr=" .. rb_coll.stderr)
      assert_eq(read_file(w_bomb .. "/my's zst/loose1.txt"), "edited-keep", "existing tarbomb dir must not be overwritten")
      assert_eq(read_file(w_bomb .. "/my's zst-1/loose1.txt"), "bomb-one", "tarbomb collision must create <stem>-1/")

      -- Case D: Missing archive & corrupted archive -> exit 1
      local r_miss = sb:run(BIN_THUNAR, { "extract", w_bomb .. "/nonexistent.tar.zst" })
      assert_eq(r_miss.code, 1, "missing archive must exit 1")

      local corrupt_arc = w_bomb .. "/corrupt.tar.zst"
      write_file(corrupt_arc, "this is definitely not a valid archive\0\255\128garbage")
      local r_bad = sb:run(BIN_THUNAR, { "extract", corrupt_arc })
      assert_eq(r_bad.code, 1, "corrupted archive must exit 1")
      assert_true(not path_exists(w_bomb .. "/corrupt"), "corrupted archive must not leave extracted folder")
    end)
  end)

  -- =========================================================================
  -- 15. bin/kaze-thunar-action: Adversarial Path Traversal Blocking
  -- =========================================================================
  test("bb.thunar.extract_traversal_blocking", function()
    with_sandbox(function(sb)
      if not sb.has_bsdtar then
        return
      end
      local py = find_host_bin("python3")
      assert_true(py ~= nil, "python3 required to craft adversarial tar archives")
      sb:install_stub("notify-send")

      local outer = sb.root .. "/outer"
      local work = outer .. "/work"
      mkdir_p(work)

      local py_maker = sb.tmp .. "/make_evil_tar.py"
      write_file(py_maker, [[
import io, json, sys, tarfile

out_path = sys.argv[1]
entries = json.loads(sys.argv[2])
with tarfile.open(out_path, "w") as tf:
    for item in entries:
        ti = tarfile.TarInfo(name=item["name"])
        if item.get("dir"):
            ti.type = tarfile.DIRTYPE
            ti.size = 0
            tf.addfile(ti)
        else:
            data = item.get("data", "PWNED").encode("utf-8")
            ti.size = len(data)
            tf.addfile(ti, io.BytesIO(data))
]])

      local writable_abs = sb.root .. "/evil-abs-escape.txt"
      local attacks = {
        {
          name = "absolute /etc/passwd",
          archive = work .. "/evil-etc.tar",
          json = '[{"name":"benign.txt","data":"ok"},{"name":"/etc/passwd","data":"root:x:0:0"}]',
        },
        {
          name = "writable absolute sandbox path",
          archive = work .. "/evil-abs.tar",
          json = string.format('[{"name":"benign.txt","data":"ok"},{"name":%q,"data":"PWNED"}]', writable_abs),
        },
        {
          name = "direct parent escape ../escape.txt",
          archive = work .. "/evil-parent.tar",
          json = '[{"name":"benign.txt","data":"ok"},{"name":"../escape.txt","data":"PWNED"}]',
        },
        {
          name = "dot-slash parent escape ./../escape.txt",
          archive = work .. "/evil-dotslash.tar",
          json = '[{"name":"benign.txt","data":"ok"},{"name":"./../escape.txt","data":"PWNED"}]',
        },
        {
          name = "nested traversal sub/../../escape.txt",
          archive = work .. "/evil-nested.tar",
          json = '[{"name":"sub/ok.txt","data":"ok"},{"name":"sub/../../escape.txt","data":"PWNED"}]',
        },
        {
          name = "deep traversal a/b/../../../escape.txt",
          archive = work .. "/evil-deep.tar",
          json = '[{"name":"a/b/ok.txt","data":"ok"},{"name":"a/b/../../../escape.txt","data":"PWNED"}]',
        },
        {
          name = "bare .. member",
          archive = work .. "/evil-dotdot.tar",
          json = '[{"name":"..","dir":true},{"name":"good.txt","data":"ok"}]',
        },
      }

      for _, atk in ipairs(attacks) do
        local mk_rc = exec_code(
          sh_quote(py) .. " " .. sh_quote(py_maker)
            .. " " .. sh_quote(atk.archive)
            .. " " .. sh_quote(atk.json)
        )
        assert_eq(mk_rc, 0, "failed crafting adversarial tar for " .. atk.name)

        local before = table.concat(list_dir_entries(work), "\n")
        local res = sb:run(BIN_THUNAR, { "extract", atk.archive })
        assert_eq(res.code, 1, "traversal attack (" .. atk.name .. ") MUST be rejected with exit 1")

        local after = table.concat(list_dir_entries(work), "\n")
        assert_eq(after, before, "traversal attack (" .. atk.name .. ") MUST extract ZERO files into work dir")
        assert_true(not path_exists(outer .. "/escape.txt"), "parent escape file was created by " .. atk.name)
        assert_true(not path_exists(writable_abs), "absolute escape file was created by " .. atk.name)
      end
    end)
  end)

  -- =========================================================================
  -- 16. bin/kaze-thunar-action: checksum (SHA256 verification & rejection)
  -- =========================================================================
  test("bb.thunar.checksum", function()
    with_sandbox(function(sb)
      sb:install_stub("wl-copy", { read_stdin = "always" })
      sb:install_stub("notify-send")

      local d = sb.root .. "/hash's dir"
      mkdir_p(d)
      local data_file = d .. "/it's payload.bin"
      local empty_file = d .. "/empty.bin"
      write_file(data_file, "hello kaze-dots\n\0\1\2\255binary-end")
      write_file(empty_file, "")

      -- Compute expected SHA256 using host sha256sum
      local sha_bin = find_host_bin("sha256sum")
      assert_true(sha_bin ~= nil, "sha256sum required to verify checksum")
      local expected_data_hash = popen_capture(sh_quote(sha_bin) .. " " .. sh_quote(data_file)):match("^(%x+)")
      assert_eq(#expected_data_hash, 64, "host sha256sum sanity check")
      local expected_empty_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

      -- 1. Binary file with spaces + single quote
      local r1 = sb:run(BIN_THUNAR, { "checksum", data_file })
      assert_eq(r1.code, 0, "checksum regular file failed; stderr=" .. r1.stderr)
      local wc1 = sb:read_calls("wl-copy")
      assert_eq(#wc1, 1, "checksum must invoke wl-copy once")
      local got1 = wc1[1].stdin:gsub("[\r\n]+$", "")
      assert_true(got1:match("^[0-9a-f]+$") ~= nil and #got1 == 64, "expected 64-char lowercase hex SHA256, got: " .. string.format("%q", wc1[1].stdin))
      assert_eq(got1, expected_data_hash, "SHA256 mismatch for binary file")

      -- 2. Empty file
      sb:clear_logs()
      local r2 = sb:run(BIN_THUNAR, { "checksum", empty_file })
      assert_eq(r2.code, 0, "checksum empty file failed; stderr=" .. r2.stderr)
      local wc2 = sb:read_calls("wl-copy")
      assert_eq(#wc2, 1, "checksum empty file must invoke wl-copy once")
      local got2 = wc2[1].stdin:gsub("[\r\n]+$", "")
      assert_eq(got2, expected_empty_hash, "SHA256 mismatch for empty file")

      -- 3. Directory -> rejected with exit 1 & no wl-copy
      sb:clear_logs()
      local r3 = sb:run(BIN_THUNAR, { "checksum", d })
      assert_eq(r3.code, 1, "checksum directory must exit 1")
      assert_eq(#sb:read_calls("wl-copy"), 0, "checksum directory must not invoke wl-copy")

      -- 4. Missing file -> rejected with exit 1 & no wl-copy
      sb:clear_logs()
      local r4 = sb:run(BIN_THUNAR, { "checksum", d .. "/missing.bin" })
      assert_eq(r4.code, 1, "checksum missing file must exit 1")
      assert_eq(#sb:read_calls("wl-copy"), 0, "checksum missing file must not invoke wl-copy")

      -- 5. Missing wl-copy -> exit 1
      sb:remove_bin("wl-copy")
      local r5 = sb:run(BIN_THUNAR, { "checksum", data_file })
      assert_eq(r5.code, 1, "checksum without wl-copy must exit 1")
    end)
  end)
end

return run_suite
