-- Blind black-box & brute-force behavioral test suite for:
--   bin/kaze-style
--   bin/kaze-doctor --diff (and --diff-noctalia / --offline drift warnings)
--
-- Derived strictly from the behavioral specification.
-- Runs every test in a fresh, host-isolated /tmp/kaze-bb-style-* sandbox with
-- env -i and stubbed binaries, cleaning up all temporary files in pcall blocks.

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
    error("write_file failed for " .. tostring(path) .. ": " .. tostring(err), 2)
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

local function exec_exit_code(cmd)
  local ok, why, code = os.execute(cmd)
  if type(ok) == "number" then
    return ok
  end
  if why == "exit" then
    return code
  end
  if ok then
    return 0
  end
  return code or 1
end

local function resolve_abs_dir(dir)
  local p = io.popen("cd " .. sh_quote(dir) .. " && pwd", "r")
  if not p then
    error("failed to resolve repo_dir: " .. tostring(dir), 2)
  end
  local out = p:read("*l")
  p:close()
  if not out or out == "" then
    error("empty resolved repo_dir for: " .. tostring(dir), 2)
  end
  return out
end

local function mkdir_p(path)
  local rc = exec_exit_code("mkdir -p -- " .. sh_quote(path))
  if rc ~= 0 then
    error("mkdir -p failed for " .. tostring(path), 2)
  end
end

local function write_executable(path, content)
  write_file(path, content)
  local rc = exec_exit_code("chmod +x -- " .. sh_quote(path))
  if rc ~= 0 then
    error("chmod +x failed for " .. tostring(path), 2)
  end
end

local function split_lines(text)
  local lines = {}
  if not text or text == "" then
    return lines
  end
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  if text:sub(-1) == "\n" then
    lines[#lines] = nil
  end
  return lines
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--------------------------------------------------------------------------------
-- Minimal TOML parser & editor (Lua stdlib only)
--------------------------------------------------------------------------------

local function strip_toml_comment(line)
  local in_dq = false
  local in_sq = false
  local esc = false
  for i = 1, #line do
    local c = line:sub(i, i)
    if esc then
      esc = false
    elseif in_dq then
      if c == "\\" then
        esc = true
      elseif c == '"' then
        in_dq = false
      end
    elseif in_sq then
      if c == "'" then
        in_sq = false
      end
    else
      if c == '"' then
        in_dq = true
      elseif c == "'" then
        in_sq = true
      elseif c == "#" then
        return line:sub(1, i - 1)
      end
    end
  end
  return line
end

local function count_brackets(s)
  local depth = 0
  local in_dq = false
  local in_sq = false
  local esc = false
  for i = 1, #s do
    local c = s:sub(i, i)
    if esc then
      esc = false
    elseif in_dq then
      if c == "\\" then
        esc = true
      elseif c == '"' then
        in_dq = false
      end
    elseif in_sq then
      if c == "'" then
        in_sq = false
      end
    else
      if c == '"' then
        in_dq = true
      elseif c == "'" then
        in_sq = true
      elseif c == "[" then
        depth = depth + 1
      elseif c == "]" then
        depth = depth - 1
      end
    end
  end
  return depth
end

local function unquote_toml_string(val)
  val = trim(val)
  local dq = val:match('^"(.*)"$')
  if dq then
    return (dq:gsub('\\"', '"'):gsub("\\\\", "\\"))
  end
  local sq = val:match("^'(.*)'$")
  if sq then
    return sq
  end
  return nil
end

local function parse_toml_string_array(raw)
  if type(raw) ~= "string" then
    return nil
  end
  local inner = trim(raw):match("^%[(.*)%]$")
  if not inner then
    return nil
  end
  local items = {}
  local i = 1
  local n = #inner
  while i <= n do
    local c = inner:sub(i, i)
    if c == '"' then
      local j = i + 1
      local buf = {}
      while j <= n do
        local ch = inner:sub(j, j)
        if ch == "\\" and j < n then
          buf[#buf + 1] = inner:sub(j + 1, j + 1)
          j = j + 2
        elseif ch == '"' then
          break
        else
          buf[#buf + 1] = ch
          j = j + 1
        end
      end
      items[#items + 1] = table.concat(buf)
      i = j + 1
    elseif c == "'" then
      local j = inner:find("'", i + 1, true)
      if not j then
        break
      end
      items[#items + 1] = inner:sub(i + 1, j - 1)
      i = j + 1
    else
      i = i + 1
    end
  end
  return items
end

local function parse_toml(content)
  local doc = {
    sections = { [""] = {} },
    section_exists = { [""] = true },
    array_tables = {},
    all_keys = {},
  }
  local current_map = doc.sections[""]
  local current_sec_name = ""
  local lines = split_lines(content or "")
  local idx = 1

  while idx <= #lines do
    local clean = trim(strip_toml_comment(lines[idx]))
    if clean ~= "" then
      local arr_hdr = clean:match("^%[%[%s*([^%]]-)%s*%]%]$")
      local sec_hdr = (not arr_hdr) and clean:match("^%[%s*([^%]]-)%s*%]$") or nil
      if arr_hdr then
        doc.array_tables[arr_hdr] = doc.array_tables[arr_hdr] or {}
        local tbl = {}
        doc.array_tables[arr_hdr][#doc.array_tables[arr_hdr] + 1] = tbl
        current_map = tbl
        current_sec_name = "[[" .. arr_hdr .. "]]"
      elseif sec_hdr then
        doc.sections[sec_hdr] = doc.sections[sec_hdr] or {}
        doc.section_exists[sec_hdr] = true
        current_map = doc.sections[sec_hdr]
        current_sec_name = sec_hdr
      else
        local key, val = clean:match("^([%w_%-%.]+)%s*=%s*(.*)$")
        if key then
          local depth = count_brackets(val)
          while depth > 0 and idx < #lines do
            idx = idx + 1
            local next_clean = trim(strip_toml_comment(lines[idx]))
            val = val .. " " .. next_clean
            depth = depth + count_brackets(next_clean)
          end
          val = trim(val)
          current_map[key] = val
          doc.all_keys[key] = doc.all_keys[key] or {}
          doc.all_keys[key][#doc.all_keys[key] + 1] = {
            section = current_sec_name,
            raw = val,
          }
        end
      end
    end
    idx = idx + 1
  end

  return doc
end

local function toml_get_raw(doc, section, key)
  local sec = doc.sections[section]
  if not sec then
    return nil
  end
  return sec[key]
end

local function toml_get_str(doc, section, key)
  local raw = toml_get_raw(doc, section, key)
  if not raw then
    return nil
  end
  return unquote_toml_string(raw)
end

local function toml_get_num(doc, section, key)
  local raw = toml_get_raw(doc, section, key)
  if not raw then
    return nil
  end
  return tonumber(trim(raw))
end

local function toml_get_bool(doc, section, key)
  local raw = toml_get_raw(doc, section, key)
  if raw == "true" then
    return true
  elseif raw == "false" then
    return false
  end
  return nil
end

local function toml_has_key_value_anywhere(doc, key, predicate)
  local entries = doc.all_keys[key]
  if not entries then
    return false
  end
  for _, entry in ipairs(entries) do
    if predicate(entry.raw, entry.section) then
      return true
    end
  end
  return false
end

-- Set or insert a key inside a specific TOML section.
-- Replaces multi-line bracket values cleanly as well.
local function toml_set_in_section(content, target_section, key, new_val_literal)
  local lines = split_lines(content)
  local out = {}
  local in_target = (target_section == "")
  local found_section = (target_section == "")
  local replaced = false
  local i = 1

  while i <= #lines do
    local line = lines[i]
    local clean = trim(strip_toml_comment(line))
    local arr_hdr = clean:match("^%[%[%s*([^%]]-)%s*%]%]$")
    local sec_hdr = (not arr_hdr) and clean:match("^%[%s*([^%]]-)%s*%]$") or nil

    if arr_hdr or sec_hdr then
      if in_target and not replaced then
        out[#out + 1] = key .. " = " .. new_val_literal
        replaced = true
      end
      in_target = (sec_hdr == target_section)
      if in_target then
        found_section = true
      end
      out[#out + 1] = line
      i = i + 1
    elseif in_target then
      local k, v = clean:match("^([%w_%-%.]+)%s*=%s*(.*)$")
      if k == key then
        local depth = count_brackets(v)
        while depth > 0 and i < #lines do
          i = i + 1
          depth = depth + count_brackets(strip_toml_comment(lines[i]))
        end
        local indent = line:match("^(%s*)") or ""
        out[#out + 1] = indent .. key .. " = " .. new_val_literal
        replaced = true
        i = i + 1
      else
        out[#out + 1] = line
        i = i + 1
      end
    else
      out[#out + 1] = line
      i = i + 1
    end
  end

  if in_target and not replaced then
    out[#out + 1] = key .. " = " .. new_val_literal
    replaced = true
  elseif not found_section then
    if #out > 0 and out[#out] ~= "" then
      out[#out + 1] = ""
    end
    out[#out + 1] = "[" .. target_section .. "]"
    out[#out + 1] = key .. " = " .. new_val_literal
  end

  return table.concat(out, "\n") .. "\n"
end

-- Replace the first occurrence of key in whichever section defines it;
-- if absent, insert into fallback_section.
local function toml_set_existing_or_fallback(content, key, new_val_literal, fallback_section)
  local doc = parse_toml(content)
  local entries = doc.all_keys[key]
  if entries and #entries > 0 then
    local sec = entries[1].section
    if not sec:match("^%[%[") then
      return toml_set_in_section(content, sec, key, new_val_literal), sec
    end
  end
  return toml_set_in_section(content, fallback_section, key, new_val_literal), fallback_section
end

local function toml_delete_section(content, target_section)
  local lines = split_lines(content)
  local out = {}
  local skipping = false
  local removed = false
  for _, line in ipairs(lines) do
    local clean = trim(strip_toml_comment(line))
    local arr_hdr = clean:match("^%[%[%s*([^%]]-)%s*%]%]$")
    local sec_hdr = (not arr_hdr) and clean:match("^%[%s*([^%]]-)%s*%]$") or nil
    if arr_hdr or sec_hdr then
      if sec_hdr == target_section then
        skipping = true
        removed = true
      else
        skipping = false
      end
    end
    if not skipping then
      out[#out + 1] = line
    end
  end
  return table.concat(out, "\n") .. "\n", removed
end

local function toml_delete_key(content, target_key)
  local lines = split_lines(content)
  local out = {}
  local removed = false
  local i = 1
  while i <= #lines do
    local line = lines[i]
    local clean = trim(strip_toml_comment(line))
    local k, v = clean:match("^([%w_%-%.]+)%s*=%s*(.*)$")
    if k == target_key and not removed then
      local depth = count_brackets(v)
      while depth > 0 and i < #lines do
        i = i + 1
        depth = depth + count_brackets(strip_toml_comment(lines[i]))
      end
      removed = true
    else
      out[#out + 1] = line
    end
    i = i + 1
  end
  return table.concat(out, "\n") .. "\n", removed
end

local function format_toml_string_array(items)
  if #items == 0 then
    return "[]"
  end
  local quoted = {}
  for _, item in ipairs(items) do
    quoted[#quoted + 1] = '"' .. item:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
  end
  return "[ " .. table.concat(quoted, ", ") .. " ]"
end

local function array_equals(a, b)
  if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

--------------------------------------------------------------------------------
-- Sandbox harness
--------------------------------------------------------------------------------

local function create_sandbox(abs_repo)
  local p = io.popen("mktemp -d /tmp/kaze-bb-style-XXXXXX", "r")
  if not p then
    error("mktemp failed", 2)
  end
  local root = p:read("*l")
  p:close()
  if not root or not root:match("^/tmp/kaze%-bb%-style%-") then
    error("unexpected mktemp path: " .. tostring(root), 2)
  end

  local sb = {
    root = root,
    repo = abs_repo,
    home = root .. "/home",
    config = root .. "/config",
    data = root .. "/data",
    cache = root .. "/cache",
    state = root .. "/state",
    run = root .. "/run",
    stub_bin = root .. "/stub-bin",
    logs = root .. "/logs",
  }

  for _, d in ipairs({
    sb.home,
    sb.config,
    sb.data,
    sb.cache,
    sb.state,
    sb.run,
    sb.stub_bin,
    sb.logs,
  }) do
    mkdir_p(d)
  end

  sb.noctalia_log = sb.logs .. "/noctalia.log"
  sb.hyprctl_log = sb.logs .. "/hyprctl.log"
  sb.validate_log = sb.logs .. "/validate.log"
  sb.dmenu_stdin = sb.logs .. "/dmenu-stdin.txt"
  sb.dmenu_argv = sb.logs .. "/dmenu-argv.txt"
  sb.other_log = sb.logs .. "/other.log"

  -- Stub noctalia: logs every invocation, supports config validate, dmenu, msg
  write_executable(
    sb.stub_bin .. "/noctalia",
    table.concat({
      "#!/usr/bin/env bash",
      "set -euo pipefail",
      'log_file="${STUB_NOCTALIA_LOG:-' .. sb.noctalia_log .. '}"',
      'printf "%s\\n" "$*" >> "$log_file"',
      'cmd="${1:-}"',
      'sub="${2:-}"',
      'if [[ "$cmd" == "config" && "$sub" == "validate" ]]; then',
      '  val_log="${STUB_NOCTALIA_VALIDATE_LOG:-' .. sb.validate_log .. '}"',
      '  printf "%s\\n" "${3:-}" >> "$val_log"',
      '  rc="${STUB_NOCTALIA_VALIDATE_RC:-0}"',
      '  if [[ "$rc" != "0" ]]; then',
      '    printf "stub noctalia: validation failed for %s\\n" "${3:-}" >&2',
      '    exit "$rc"',
      "  fi",
      "  exit 0",
      "fi",
      'if [[ "$cmd" == "dmenu" ]]; then',
      '  argv_file="${STUB_DMENU_ARGV_FILE:-' .. sb.dmenu_argv .. '}"',
      '  stdin_file="${STUB_DMENU_STDIN_FILE:-' .. sb.dmenu_stdin .. '}"',
      '  : > "$argv_file"',
      '  for a in "$@"; do printf "%s\\n" "$a" >> "$argv_file"; done',
      '  cat > "$stdin_file"',
      '  mode="${STUB_DMENU_MODE:-empty}"',
      '  case "$mode" in',
      '    empty) exit "${STUB_DMENU_RC:-0}" ;;',
      '    garbage) printf "%s\\n" "${STUB_DMENU_OUT:-totally-invalid-garbage-entry}"; exit "${STUB_DMENU_RC:-0}" ;;',
      '    match)',
      '      line="$(grep -F -m1 -- "${STUB_DMENU_MATCH:-}" "$stdin_file" || true)"',
      '      if [[ -n "$line" ]]; then printf "%s\\n" "$line"; fi',
      '      exit "${STUB_DMENU_RC:-0}"',
      "      ;;",
      '    raw) printf "%s\\n" "${STUB_DMENU_OUT:-}"; exit "${STUB_DMENU_RC:-0}" ;;',
      '    *) exit "${STUB_DMENU_RC:-0}" ;;',
      "  esac",
      "fi",
      'exit "${STUB_NOCTALIA_RC:-0}"',
      "",
    }, "\n")
  )

  -- Stub hyprctl (supports -j clients / -j activewindow via env for window toggle tests)
  write_executable(
    sb.stub_bin .. "/hyprctl",
    table.concat({
      "#!/usr/bin/env bash",
      "set -euo pipefail",
      'log_file="${STUB_HYPRCTL_LOG:-' .. sb.hyprctl_log .. '}"',
      'printf "%s\\n" "$*" >> "$log_file"',
      'if [[ "${1:-}" == "-j" && "${2:-}" == "clients" ]]; then',
      '  printf "%s\\n" "${STUB_HYPRCTL_CLIENTS:-[]}"',
      '  exit "${STUB_HYPRCTL_RC:-0}"',
      "fi",
      'if [[ "${1:-}" == "-j" && "${2:-}" == "activewindow" ]]; then',
      '  default_obj="{}"',
      '  printf "%s\\n" "${STUB_HYPRCTL_ACTIVE:-$default_obj}"',
      '  exit "${STUB_HYPRCTL_RC:-0}"',
      "fi",
      'exit "${STUB_HYPRCTL_RC:-0}"',
      "",
    }, "\n")
  )

  -- Safety stubs for host-mutating or headless-unavailable commands
  local noop_tools = {
    "sudo",
    "pacman",
    "systemctl",
    "busctl",
    "usermod",
    "chsh",
    "fc-cache",
    "pkill",
    "killall",
    "notify-send",
    "gsettings",
    "dconf",
    "loginctl",
    "playerctl",
    "foot",
    "footclient",
    "hyprland",
    "wl-copy",
    "wl-paste",
    "wpctl",
    "brightnessctl",
  }
  for _, tool in ipairs(noop_tools) do
    write_executable(
      sb.stub_bin .. "/" .. tool,
      table.concat({
        "#!/usr/bin/env bash",
        'printf "%s %s\\n" "' .. tool .. '" "$*" >> "' .. sb.other_log .. '"',
        "exit 0",
        "",
      }, "\n")
    )
  end

  function sb:clear_logs()
    for _, f in ipairs({
      self.noctalia_log,
      self.hyprctl_log,
      self.validate_log,
      self.dmenu_stdin,
      self.dmenu_argv,
      self.other_log,
    }) do
      os.remove(f)
    end
  end

  function sb:exec(exe, args, opts)
    opts = opts or {}
    local env_map = {
      HOME = self.home,
      USER = "kazetest",
      LANG = "C.UTF-8",
      LC_ALL = "C.UTF-8",
      XDG_CONFIG_HOME = self.config,
      XDG_DATA_HOME = self.data,
      XDG_CACHE_HOME = self.cache,
      XDG_STATE_HOME = self.state,
      XDG_RUNTIME_DIR = self.run,
      KAZE_DOTS_DIR = self.repo,
      PATH = self.stub_bin .. ":/usr/local/bin:/usr/bin:/bin",
    }
    if opts.env then
      for k, v in pairs(opts.env) do
        if v == false then
          env_map[k] = nil
        else
          env_map[k] = tostring(v)
        end
      end
    end

    local env_parts = { "env", "-i" }
    local keys = {}
    for k in pairs(env_map) do
      keys[#keys + 1] = k
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
      env_parts[#env_parts + 1] = sh_quote(k .. "=" .. env_map[k])
    end

    local cmd_parts = { sh_quote(exe) }
    for _, a in ipairs(args or {}) do
      cmd_parts[#cmd_parts + 1] = sh_quote(a)
    end

    local out_file = self.root .. "/_cmd_stdout.tmp"
    local err_file = self.root .. "/_cmd_stderr.tmp"
    local cwd_prefix = ""
    if opts.cwd then
      cwd_prefix = "cd " .. sh_quote(opts.cwd) .. " && "
    end

    local full_cmd = cwd_prefix
      .. table.concat(env_parts, " ")
      .. " "
      .. table.concat(cmd_parts, " ")
      .. " >"
      .. sh_quote(out_file)
      .. " 2>"
      .. sh_quote(err_file)

    local rc = exec_exit_code(full_cmd)
    local stdout = read_file(out_file) or ""
    local stderr = read_file(err_file) or ""
    os.remove(out_file)
    os.remove(err_file)
    return {
      code = rc,
      stdout = stdout,
      stderr = stderr,
      combined = stdout .. stderr,
    }
  end

  function sb:apply_seed()
    local res = self:exec(self.repo .. "/scripts/apply.sh", { "--yes" })
    if res.code ~= 0 then
      error(
        "Failed to seed sandbox via scripts/apply.sh --yes (exit "
          .. tostring(res.code)
          .. "): "
          .. res.combined,
        2
      )
    end
    self:clear_logs()
    return res
  end

  function sb:style(args, opts)
    return self:exec(self.repo .. "/bin/kaze-style", args, opts)
  end

  function sb:doctor(args, opts)
    return self:exec(self.repo .. "/bin/kaze-doctor", args, opts)
  end

  function sb:config_toml_path()
    return self.config .. "/noctalia/config.toml"
  end

  function sb:style_state_path()
    return self.config .. "/kaze/style"
  end

  function sb:saved_theme_path()
    return self.config .. "/kaze/saved-theme.json"
  end

  function sb:hypr_style_path()
    return self.config .. "/hypr/kaze-style.lua"
  end

  function sb:gtk_style_path()
    return self.config .. "/gtk-3.0/kaze-style.css"
  end

  function sb:state_settings_path()
    return self.state .. "/noctalia/settings.toml"
  end

  function sb:template_path()
    return self.repo .. "/config/noctalia/config.toml"
  end

  return sb
end

local function with_sandbox(abs_repo, fn)
  local sb = create_sandbox(abs_repo)
  local ok, err = pcall(fn, sb)
  exec_exit_code("rm -rf -- " .. sh_quote(sb.root))
  if not ok then
    error(err, 0)
  end
end

--------------------------------------------------------------------------------
-- Specification constants & reusable invariant checkers
--------------------------------------------------------------------------------

local GROUPS = {
  "Angular & Minimal",
  "Dynamic & Modern",
  "Retro & Editorial",
}

local ALL_PRESETS = {
  "omarchy-rail",
  "swiss-grid",
  "corner-hud",
  "ghost-zero",
  "dynamic-island",
  "hardware-notch",
  "glass-studio",
  "floating-rail",
  "tui-hacker",
  "retro-90s",
  "cinema-frame",
}

local ALL_ALIASES = {
  { alias = "brutalist", canonical = "omarchy-rail" },
  { alias = "omarchy", canonical = "omarchy-rail" },
  { alias = "swiss", canonical = "swiss-grid" },
  { alias = "notion", canonical = "swiss-grid" },
  { alias = "floating-islands", canonical = "corner-hud" },
  { alias = "ghost", canonical = "ghost-zero" },
  { alias = "zero-bar", canonical = "ghost-zero" },
  { alias = "concave-notch", canonical = "hardware-notch" },
  { alias = "glass", canonical = "glass-studio" },
  { alias = "macos", canonical = "glass-studio" },
  { alias = "tui", canonical = "tui-hacker" },
  { alias = "hacker", canonical = "tui-hacker" },
  { alias = "retro", canonical = "retro-90s" },
  { alias = "win95", canonical = "retro-90s" },
  { alias = "pixel", canonical = "retro-90s" },
  { alias = "cinema", canonical = "cinema-frame" },
}

local function run_suite(test, assert_eq, assert_true, assert_contains, repo_dir)
  local abs_repo = resolve_abs_dir(repo_dir or ".")

  -- Shared helper: validate core artifacts & invariants after applying a preset
  local function assert_common_preset_artifacts(sb, canonical_id, ctx)
    local tag = "[" .. canonical_id .. (ctx and (" " .. ctx) or "") .. "] "

    -- 1. state file
    local state = read_file(sb:style_state_path())
    assert_eq(state, canonical_id .. "\n", tag .. "kaze/style state file")

    -- 2. hypr/kaze-style.lua syntax + runtime loadfile check
    local hypr_path = sb:hypr_style_path()
    assert_true(file_exists(hypr_path), tag .. "hypr/kaze-style.lua must exist")
    local luac_rc = exec_exit_code("luac -p -- " .. sh_quote(hypr_path) .. " >/dev/null 2>&1")
    assert_eq(luac_rc, 0, tag .. "hypr/kaze-style.lua must pass luac -p")
    local chunk, load_err = loadfile(hypr_path, "t", {})
    assert_true(chunk ~= nil, tag .. "loadfile(hypr/kaze-style.lua) failed: " .. tostring(load_err))
    local ok, tbl = pcall(chunk)
    assert_true(ok, tag .. "executing hypr/kaze-style.lua failed: " .. tostring(tbl))
    assert_eq(type(tbl), "table", tag .. "hypr/kaze-style.lua must return a table")
    assert_eq(type(tbl.gaps_out), "number", tag .. "hypr/kaze-style.lua must return numeric gaps_out")

    -- 3. gtk-3.0/kaze-style.css must exist & contain ZERO hardcoded hex colors
    local css_path = sb:gtk_style_path()
    local css = read_file(css_path)
    assert_true(css ~= nil, tag .. "gtk-3.0/kaze-style.css must exist")
    local bad_hex6 = css:match("#%x%x%x%x%x%x")
    assert_true(
      bad_hex6 == nil,
      tag .. "gtk-3.0/kaze-style.css must contain zero #rrggbb hex colors, found: " .. tostring(bad_hex6)
    )
    local bad_hex3 = css:match(":[^;\n]*#%x%x%x[^%w_-]")
    assert_true(
      bad_hex3 == nil,
      tag .. "gtk-3.0/kaze-style.css must contain zero #rgb hex colors, found: " .. tostring(bad_hex3)
    )

    -- 4. noctalia/config.toml offline / zero-telemetry invariants
    local toml_text = read_file(sb:config_toml_path())
    assert_true(toml_text ~= nil and #toml_text > 0, tag .. "noctalia/config.toml must exist")
    local doc = parse_toml(toml_text)

    assert_true(
      toml_has_key_value_anywhere(doc, "offline_mode", function(v)
        return v == "true"
      end),
      tag .. "offline_mode = true must be preserved"
    )
    assert_true(
      toml_has_key_value_anywhere(doc, "telemetry_enabled", function(v)
        return v == "false"
      end),
      tag .. "telemetry_enabled = false must be preserved"
    )
    assert_true(doc.section_exists["weather"], tag .. "[weather] section must exist")
    assert_eq(toml_get_bool(doc, "weather", "enabled"), false, tag .. "[weather] enabled = false")
    assert_true(doc.section_exists["widget.record"], tag .. "[widget.record] section must exist")

    return doc, tbl, toml_text
  end

  -- Shared helper: check preset-specific behavioral assertions
  local function assert_preset_specifics(preset_id, doc, hypr_tbl)
    local tag = "[" .. preset_id .. "] "
    if preset_id == "omarchy-rail" then
      assert_eq(toml_get_str(doc, "bar.default", "position"), "left", tag .. "position = left")
      assert_eq(toml_get_num(doc, "bar.default", "thickness"), 42, tag .. "thickness = 42")
      assert_true(
        toml_has_key_value_anywhere(doc, "corner_radius_scale", function(v)
          return tonumber(v) == 0
        end),
        tag .. "corner_radius_scale = 0.0"
      )
      local order = parse_toml_string_array(toml_get_raw(doc, "bar", "order"))
      assert_true(array_equals(order, { "default" }), tag .. 'order = [ "default" ]')
    elseif preset_id == "swiss-grid" then
      assert_eq(toml_get_str(doc, "theme", "mode"), "light", tag .. "theme.mode = light")
      assert_eq(
        toml_get_str(doc, "theme", "custom_palette"),
        "Kaze-Swiss",
        tag .. "custom_palette = Kaze-Swiss"
      )
    elseif preset_id == "corner-hud" then
      local center = parse_toml_string_array(toml_get_raw(doc, "bar.default", "center"))
      assert_true(center ~= nil and #center == 0, tag .. "bar.default center = []")
    elseif preset_id == "ghost-zero" then
      assert_eq(toml_get_bool(doc, "bar.default", "auto_hide"), true, tag .. "auto_hide = true")
      assert_eq(toml_get_bool(doc, "bar.default", "reserve_space"), false, tag .. "reserve_space = false")
      assert_eq(hypr_tbl.gaps_out, 0, tag .. "kaze-style.lua gaps_out = 0")
    elseif preset_id == "dynamic-island" then
      local groups = doc.array_tables["bar.default.capsule_group"] or {}
      local ids = {}
      for _, g in ipairs(groups) do
        local id = unquote_toml_string(g.id or "")
        if id then
          ids[id] = true
        end
      end
      assert_true(ids["island"], tag .. 'capsule_group id = "island"')
      assert_true(ids["island_left"], tag .. 'capsule_group id = "island_left"')
      assert_true(ids["island_right"], tag .. 'capsule_group id = "island_right"')
      assert_true(
        toml_has_key_value_anywhere(doc, "position", function(v)
          return unquote_toml_string(v) == "top_right"
        end),
        tag .. 'position = "top_right"'
      )
    elseif preset_id == "hardware-notch" then
      assert_eq(toml_get_num(doc, "bar.default", "margin_edge"), 0, tag .. "margin_edge = 0")
      assert_eq(
        toml_get_bool(doc, "bar.default", "concave_edge_corners"),
        true,
        tag .. "concave_edge_corners = true"
      )
      local groups = doc.array_tables["bar.default.capsule_group"]
      assert_true(
        groups == nil or #groups == 0,
        tag .. "hardware-notch must have NO [[bar.default.capsule_group]]"
      )
    elseif preset_id == "glass-studio" then
      assert_true(
        toml_has_key_value_anywhere(doc, "transparency_mode", function(v)
          return unquote_toml_string(v) == "glass"
        end),
        tag .. 'transparency_mode = "glass"'
      )
      assert_eq(toml_get_bool(doc, "dock", "enabled"), true, tag .. "[dock] enabled = true")
    elseif preset_id == "floating-rail" then
      local order = parse_toml_string_array(toml_get_raw(doc, "bar", "order"))
      assert_true(array_equals(order, { "default", "rail" }), tag .. 'order = [ "default", "rail" ]')
      assert_true(doc.section_exists["bar.rail"], tag .. "defines [bar.rail]")
    elseif preset_id == "tui-hacker" then
      assert_eq(
        toml_get_str(doc, "theme", "custom_palette"),
        "Kaze-Phosphor",
        tag .. "custom_palette = Kaze-Phosphor"
      )
    elseif preset_id == "retro-90s" then
      assert_eq(toml_get_str(doc, "bar.default", "position"), "bottom", tag .. "position = bottom")
      assert_eq(
        toml_get_str(doc, "theme", "custom_palette"),
        "Kaze-Retro90s",
        tag .. "custom_palette = Kaze-Retro90s"
      )
      assert_true(doc.section_exists["widget.taskbar"], tag .. "[widget.taskbar] present")
    elseif preset_id == "cinema-frame" then
      assert_eq(toml_get_str(doc, "bar.default", "position"), "bottom", tag .. "position = bottom")
      assert_eq(toml_get_num(doc, "bar.default", "thickness"), 22, tag .. "thickness = 22")
      assert_eq(hypr_tbl.gaps_out, 28, tag .. "kaze-style.lua gaps_out = 28")
    end
  end

  ------------------------------------------------------------------------------
  -- 1. CLI help output and invalid argument rejection (exit 2)
  ------------------------------------------------------------------------------
  test("bb.style.cli_help_and_invalid_args", function()
    with_sandbox(abs_repo, function(sb)
      sb:apply_seed()

      for _, flag in ipairs({ "-h", "--help" }) do
        local res = sb:style({ flag })
        assert_eq(res.code, 0, flag .. " must exit 0")
        for _, grp in ipairs(GROUPS) do
          assert_contains(res.stdout, grp, flag .. " must list group " .. grp)
        end
        for _, id in ipairs(ALL_PRESETS) do
          assert_contains(res.stdout, id, flag .. " must list preset " .. id)
        end
      end

      local before_toml = read_file(sb:config_toml_path())
      local before_state = read_file(sb:style_state_path())

      local invalid_cases = {
        { "--bogus" },
        { "-x" },
        { "omarchy-rail", "swiss-grid" },
        { "not-a-style" },
        { "dynamic-island", "--bogus" },
        { "../omarchy-rail" },
      }
      for _, argv in ipairs(invalid_cases) do
        local res = sb:style(argv)
        assert_eq(
          res.code,
          2,
          "invalid args (" .. table.concat(argv, " ") .. ") must exit 2, stderr=" .. res.stderr
        )
      end

      assert_eq(read_file(sb:config_toml_path()), before_toml, "invalid args must not modify config.toml")
      assert_eq(read_file(sb:style_state_path()), before_state, "invalid args must not modify kaze/style")
    end)
  end)

  ------------------------------------------------------------------------------
  -- 2. --current default & --list active/inactive marker formatting
  ------------------------------------------------------------------------------
  test("bb.style.current_and_list_contract", function()
    with_sandbox(abs_repo, function(sb)
      sb:apply_seed()
      os.remove(sb:style_state_path())

      local cur0 = sb:style({ "--current" })
      assert_eq(cur0.code, 0, "--current must exit 0 when state absent")
      assert_eq(cur0.stdout, "dynamic-island\n", "--current default must be dynamic-island")

      local function assert_list_active(expected_active)
        local res = sb:style({ "--list" })
        assert_eq(res.code, 0, "--list must exit 0")
        for _, grp in ipairs(GROUPS) do
          assert_contains(res.stdout, grp, "--list must print group " .. grp)
        end

        local active_found = 0
        local inactive_found = 0
        local lines = split_lines(res.stdout)
        for _, id in ipairs(ALL_PRESETS) do
          local matched_active = false
          local matched_inactive = false
          for _, line in ipairs(lines) do
            if line:match("^%* " .. id:gsub("%-", "%%-") .. "%f[%W]") or line == ("* " .. id) then
              matched_active = true
            elseif line:match("^  " .. id:gsub("%-", "%%-") .. "%f[%W]") or line == ("  " .. id) then
              matched_inactive = true
            end
          end
          if id == expected_active then
            assert_true(
              matched_active and not matched_inactive,
              "--list must prefix active preset '" .. id .. "' with '* '\nOutput:\n" .. res.stdout
            )
            active_found = active_found + 1
          else
            assert_true(
              matched_inactive and not matched_active,
              "--list must prefix inactive preset '" .. id .. "' with '  '\nOutput:\n" .. res.stdout
            )
            inactive_found = inactive_found + 1
          end
        end
        assert_eq(active_found, 1, "--list must have exactly 1 active preset")
        assert_eq(inactive_found, 10, "--list must have exactly 10 inactive presets")
      end

      assert_list_active("dynamic-island")

      for _, target in ipairs({ "omarchy-rail", "cinema-frame", "retro-90s" }) do
        local ap = sb:style({ target, "--no-reload" })
        assert_eq(ap.code, 0, "apply " .. target .. " must succeed: " .. ap.combined)
        local cur = sb:style({ "--current" })
        assert_eq(cur.code, 0, "--current after " .. target)
        assert_eq(cur.stdout, target .. "\n", "--current must return " .. target)
        assert_list_active(target)
      end
    end)
  end)

  ------------------------------------------------------------------------------
  -- 3. Brute-force ALL 11 canonical presets: artifacts, invariants & specifics
  ------------------------------------------------------------------------------
  test("bb.style.all_11_presets_artifacts_and_contracts", function()
    with_sandbox(abs_repo, function(sb)
      sb:apply_seed()

      -- Pre-seed pinned dock app so glass-studio preservation can also be checked
      local seeded = read_file(sb:config_toml_path())
      seeded = toml_set_in_section(seeded, "dock", "pinned", '[ "firefox" ]')
      write_file(sb:config_toml_path(), seeded)

      for _, id in ipairs(ALL_PRESETS) do
        local res = sb:style({ id, "--no-reload" })
        assert_eq(res.code, 0, "apply " .. id .. " failed: " .. res.combined)
        assert_contains(res.stdout, "Applied style '" .. id .. "'", "stdout for " .. id)

        local doc, hypr_tbl = assert_common_preset_artifacts(sb, id, "canonical")
        assert_preset_specifics(id, doc, hypr_tbl)

        if id == "glass-studio" then
          local pinned = parse_toml_string_array(toml_get_raw(doc, "dock", "pinned"))
          assert_true(array_equals(pinned, { "firefox" }), '[glass-studio] must preserve pinned = [ "firefox" ]')
        end
      end
    end)
  end)

  ------------------------------------------------------------------------------
  -- 4. Brute-force ALL 16 aliases -> canonical resolution & artifacts
  ------------------------------------------------------------------------------
  test("bb.style.all_16_aliases_resolution", function()
    with_sandbox(abs_repo, function(sb)
      sb:apply_seed()

      assert_eq(#ALL_ALIASES, 16, "spec defines 16 aliases")
      for _, entry in ipairs(ALL_ALIASES) do
        local res = sb:style({ entry.alias, "--no-reload" })
        assert_eq(
          res.code,
          0,
          "alias '" .. entry.alias .. "' -> '" .. entry.canonical .. "' failed: " .. res.combined
        )
        assert_contains(
          res.stdout,
          "Applied style '" .. entry.canonical .. "'",
          "alias '" .. entry.alias .. "' stdout must name canonical ID"
        )
        local cur = sb:style({ "--current" })
        assert_eq(cur.code, 0, "--current after alias " .. entry.alias)
        assert_eq(cur.stdout, entry.canonical .. "\n", "alias '" .. entry.alias .. "' --current")

        local doc, hypr_tbl = assert_common_preset_artifacts(sb, entry.canonical, "via " .. entry.alias)
        assert_preset_specifics(entry.canonical, doc, hypr_tbl)
      end
    end)
  end)

  ------------------------------------------------------------------------------
  -- 5. Transition matrix: floating-rail cleanup, notch/island round-trip,
  --    idempotency & reverse sweep
  ------------------------------------------------------------------------------
  test("bb.style.transition_matrix_and_cleanup", function()
    with_sandbox(abs_repo, function(sb)
      sb:apply_seed()

      -- floating-rail -> multiple other presets must cleanly drop [bar.rail] and restore order = ["default"]
      local targets_after_rail = { "omarchy-rail", "dynamic-island", "hardware-notch", "ghost-zero" }
      for _, next_id in ipairs(targets_after_rail) do
        local r1 = sb:style({ "floating-rail", "--no-reload" })
        assert_eq(r1.code, 0, "apply floating-rail failed: " .. r1.combined)
        local d1 = parse_toml(read_file(sb:config_toml_path()))
        assert_true(d1.section_exists["bar.rail"], "floating-rail must create [bar.rail]")
        assert_true(
          array_equals(parse_toml_string_array(toml_get_raw(d1, "bar", "order")), { "default", "rail" }),
          "floating-rail must set order = [default, rail]"
        )

        local r2 = sb:style({ next_id, "--no-reload" })
        assert_eq(r2.code, 0, "switch floating-rail -> " .. next_id .. " failed: " .. r2.combined)
        local d2, tbl2 = assert_common_preset_artifacts(sb, next_id, "after floating-rail")
        assert_preset_specifics(next_id, d2, tbl2)
        assert_true(
          not d2.section_exists["bar.rail"],
          "switching floating-rail -> " .. next_id .. " must remove [bar.rail]"
        )
        for sec_name in pairs(d2.section_exists) do
          assert_true(
            not sec_name:match("^bar%.rail%."),
            "switching floating-rail -> " .. next_id .. " left stale subtable [" .. sec_name .. "]"
          )
        end
        assert_true(
          array_equals(parse_toml_string_array(toml_get_raw(d2, "bar", "order")), { "default" }),
          "switching floating-rail -> " .. next_id .. ' must restore order = [ "default" ]'
        )
      end

      -- dynamic-island -> hardware-notch -> dynamic-island -> dynamic-island (idempotent capsule_group count!)
      assert_eq(sb:style({ "dynamic-island", "--no-reload" }).code, 0)
      local d_isl1 = parse_toml(read_file(sb:config_toml_path()))
      local count1 = #(d_isl1.array_tables["bar.default.capsule_group"] or {})
      assert_true(count1 >= 3, "dynamic-island must have at least 3 capsule_groups")

      assert_eq(sb:style({ "hardware-notch", "--no-reload" }).code, 0)
      local d_notch = parse_toml(read_file(sb:config_toml_path()))
      assert_eq(#(d_notch.array_tables["bar.default.capsule_group"] or {}), 0, "notch strips capsule_groups")

      assert_eq(sb:style({ "dynamic-island", "--no-reload" }).code, 0)
      local d_isl2 = parse_toml(read_file(sb:config_toml_path()))
      assert_eq(
        #(d_isl2.array_tables["bar.default.capsule_group"] or {}),
        count1,
        "round-trip dynamic-island restores exact capsule_group count"
      )

      -- Applying dynamic-island twice in a row must NOT duplicate capsule_group blocks
      assert_eq(sb:style({ "dynamic-island", "--no-reload" }).code, 0)
      local d_isl3 = parse_toml(read_file(sb:config_toml_path()))
      assert_eq(
        #(d_isl3.array_tables["bar.default.capsule_group"] or {}),
        count1,
        "re-applying dynamic-island must be idempotent (no duplicate capsule_groups)"
      )

      -- Reverse sweep across all 11 presets
      for i = #ALL_PRESETS, 1, -1 do
        local id = ALL_PRESETS[i]
        local r = sb:style({ id, "--no-reload" })
        assert_eq(r.code, 0, "reverse sweep " .. id .. " failed: " .. r.combined)
        local d, tbl = assert_common_preset_artifacts(sb, id, "reverse")
        assert_preset_specifics(id, d, tbl)
      end
    end)
  end)

  ------------------------------------------------------------------------------
  -- 6. User edits preserved across all styles + env hooks (QUIET, TEMPLATE, DOTS_DIR)
  ------------------------------------------------------------------------------
  test("bb.style.user_edits_and_env_hooks_preserved", function()
    with_sandbox(abs_repo, function(sb)
      sb:apply_seed()

      -- Inject user edits outside style keys
      local cfg = read_file(sb:config_toml_path())
      local polkit_sec
      cfg, polkit_sec = toml_set_existing_or_fallback(cfg, "polkit_agent", "true", "general")
      local wall_sec
      cfg, wall_sec = toml_set_existing_or_fallback(cfg, "directory", '"/custom/walls"', "wallpaper")
      cfg = toml_set_in_section(cfg, "dock", "pinned", '[ "firefox" ]')
      write_file(sb:config_toml_path(), cfg)

      -- Create hypr/user.lua sentinel
      mkdir_p(sb.config .. "/hypr")
      local user_lua_path = sb.config .. "/hypr/user.lua"
      local user_lua_sentinel = "-- custom user hypr config\nreturn { sentinel = 'do-not-touch' }\n"
      write_file(user_lua_path, user_lua_sentinel)

      for _, id in ipairs(ALL_PRESETS) do
        -- Run with cwd=/tmp to also verify KAZE_DOTS_DIR independence from cwd
        local res = sb:style({ id, "--no-reload" }, { cwd = "/tmp" })
        assert_eq(res.code, 0, "apply " .. id .. " failed: " .. res.combined)

        local doc = parse_toml(read_file(sb:config_toml_path()))
        assert_eq(
          toml_get_bool(doc, polkit_sec, "polkit_agent"),
          true,
          "[" .. id .. "] must preserve polkit_agent = true"
        )
        assert_eq(
          toml_get_str(doc, wall_sec, "directory"),
          "/custom/walls",
          "[" .. id .. '] must preserve wallpaper directory = "/custom/walls"'
        )
        assert_true(
          array_equals(parse_toml_string_array(toml_get_raw(doc, "dock", "pinned")), { "firefox" }),
          "[" .. id .. '] must preserve dock pinned = [ "firefox" ]'
        )
        assert_eq(
          read_file(user_lua_path),
          user_lua_sentinel,
          "[" .. id .. "] must never touch hypr/user.lua"
        )
      end

      -- Test KAZE_STYLE_QUIET=1 suppresses Note: line
      local note_preset = nil
      for _, candidate in ipairs({ "swiss-grid", "tui-hacker", "retro-90s", "omarchy-rail", "ghost-zero" }) do
        local loud = sb:style({ candidate, "--no-reload" })
        assert_eq(loud.code, 0)
        if loud.combined:find("Note:", 1, true) then
          note_preset = candidate
          break
        end
      end
      assert_true(
        note_preset ~= nil,
        "at least one preset should emit a 'Note:' line when KAZE_STYLE_QUIET is unset"
      )
      -- Reset to dynamic-island first so transitioning into note_preset performs the same transition
      assert_eq(sb:style({ "dynamic-island", "--no-reload" }).code, 0)
      local quiet = sb:style({ note_preset, "--no-reload" }, { env = { KAZE_STYLE_QUIET = "1" } })
      assert_eq(quiet.code, 0, "quiet apply must exit 0")
      assert_true(
        not quiet.combined:find("Note:", 1, true),
        "KAZE_STYLE_QUIET=1 must suppress 'Note:' line, got:\n" .. quiet.combined
      )

      -- Test KAZE_NOCTALIA_TEMPLATE override when user config.toml is absent
      local custom_tpl = sb.root .. "/custom-noctalia-template.toml"
      local tpl_content = read_file(sb:config_toml_path())
      tpl_content = toml_set_existing_or_fallback(tpl_content, "directory", '"/from/custom/template"', "wallpaper")
      write_file(custom_tpl, tpl_content)
      os.remove(sb:config_toml_path())

      local tpl_res = sb:style({ "omarchy-rail", "--no-reload" }, {
        env = { KAZE_NOCTALIA_TEMPLATE = custom_tpl },
      })
      assert_eq(tpl_res.code, 0, "apply with KAZE_NOCTALIA_TEMPLATE failed: " .. tpl_res.combined)
      local tpl_doc = parse_toml(read_file(sb:config_toml_path()))
      assert_eq(
        toml_get_str(tpl_doc, wall_sec, "directory"),
        "/from/custom/template",
        "KAZE_NOCTALIA_TEMPLATE must be used when seeding config.toml"
      )
    end)
  end)

  ------------------------------------------------------------------------------
  -- 7. Palette-locked theme save/restore (saved-theme.json)
  ------------------------------------------------------------------------------
  test("bb.style.palette_locked_save_and_restore", function()
    with_sandbox(abs_repo, function(sb)
      sb:apply_seed()

      -- Set explicit user theme
      local cfg = read_file(sb:config_toml_path())
      cfg = toml_set_in_section(cfg, "theme", "mode", '"dark"')
      cfg = toml_set_in_section(cfg, "theme", "source", '"builtin"')
      cfg = toml_set_in_section(cfg, "theme", "builtin", '"Catppuccin"')
      write_file(sb:config_toml_path(), cfg)

      -- Switching between theme-agnostic presets must NOT create saved-theme.json or alter theme
      for _, id in ipairs({ "omarchy-rail", "glass-studio", "dynamic-island" }) do
        assert_eq(sb:style({ id, "--no-reload" }).code, 0)
        assert_true(
          not file_exists(sb:saved_theme_path()),
          "theme-agnostic preset '" .. id .. "' must not create saved-theme.json"
        )
        local d = parse_toml(read_file(sb:config_toml_path()))
        assert_eq(toml_get_str(d, "theme", "mode"), "dark", id .. " preserves mode=dark")
        assert_eq(toml_get_str(d, "theme", "builtin"), "Catppuccin", id .. " preserves builtin=Catppuccin")
      end

      -- Enter palette-locked swiss-grid -> creates saved-theme.json
      assert_eq(sb:style({ "swiss-grid", "--no-reload" }).code, 0)
      local saved1 = read_file(sb:saved_theme_path())
      assert_true(saved1 ~= nil and #saved1 > 0, "entering swiss-grid must create saved-theme.json")
      assert_contains(saved1, "dark", "saved-theme.json must record original mode 'dark'")
      assert_contains(saved1, "Catppuccin", "saved-theme.json must record original builtin 'Catppuccin'")

      local d_swiss = parse_toml(read_file(sb:config_toml_path()))
      assert_eq(toml_get_str(d_swiss, "theme", "mode"), "light")
      assert_eq(toml_get_str(d_swiss, "theme", "custom_palette"), "Kaze-Swiss")

      -- Chain directly across all palette-locked presets: swiss-grid -> tui-hacker -> retro-90s
      for _, next_locked in ipairs({
        { id = "tui-hacker", palette = "Kaze-Phosphor" },
        { id = "retro-90s", palette = "Kaze-Retro90s" },
        { id = "swiss-grid", palette = "Kaze-Swiss" },
      }) do
        assert_eq(sb:style({ next_locked.id, "--no-reload" }).code, 0)
        local d_cur = parse_toml(read_file(sb:config_toml_path()))
        assert_eq(toml_get_str(d_cur, "theme", "custom_palette"), next_locked.palette)

        local saved_now = read_file(sb:saved_theme_path())
        assert_true(saved_now ~= nil, "saved-theme.json must remain during " .. next_locked.id)
        assert_contains(saved_now, "Catppuccin", "saved-theme.json must retain original Catppuccin")
        assert_true(
          not saved_now:find("Kaze-Swiss", 1, true)
            and not saved_now:find("Kaze-Phosphor", 1, true)
            and not saved_now:find("Kaze-Retro90s", 1, true),
          "chaining palette-locked presets must NOT overwrite saved-theme.json with locked palette: "
            .. saved_now
        )
      end

      -- Return to theme-agnostic preset -> restores original theme & removes saved-theme.json
      assert_eq(sb:style({ "omarchy-rail", "--no-reload" }).code, 0)
      assert_true(
        not file_exists(sb:saved_theme_path()),
        "leaving palette-locked preset must remove saved-theme.json"
      )
      local d_restored = parse_toml(read_file(sb:config_toml_path()))
      assert_eq(toml_get_str(d_restored, "theme", "mode"), "dark", "restored mode=dark")
      assert_eq(toml_get_str(d_restored, "theme", "source"), "builtin", "restored source=builtin")
      assert_eq(toml_get_str(d_restored, "theme", "builtin"), "Catppuccin", "restored builtin=Catppuccin")

      -- Second cycle with a different user theme (light / Nord) via retro-90s -> tui-hacker -> dynamic-island
      local cfg2 = read_file(sb:config_toml_path())
      cfg2 = toml_set_in_section(cfg2, "theme", "mode", '"light"')
      cfg2 = toml_set_in_section(cfg2, "theme", "builtin", '"Nord"')
      write_file(sb:config_toml_path(), cfg2)

      assert_eq(sb:style({ "retro-90s", "--no-reload" }).code, 0)
      assert_eq(sb:style({ "tui-hacker", "--no-reload" }).code, 0)
      assert_eq(sb:style({ "dynamic-island", "--no-reload" }).code, 0)

      assert_true(not file_exists(sb:saved_theme_path()), "second cycle must delete saved-theme.json")
      local d_restored2 = parse_toml(read_file(sb:config_toml_path()))
      assert_eq(toml_get_str(d_restored2, "theme", "mode"), "light", "second cycle restores mode=light")
      assert_eq(toml_get_str(d_restored2, "theme", "builtin"), "Nord", "second cycle restores builtin=Nord")
    end)
  end)

  ------------------------------------------------------------------------------
  -- 8. Noctalia state pruning ($XDG_STATE_HOME/noctalia/settings.toml)
  ------------------------------------------------------------------------------
  test("bb.style.state_pruning", function()
    with_sandbox(abs_repo, function(sb)
      sb:apply_seed()

      -- First verify applying when settings.toml is absent succeeds cleanly
      os.remove(sb:state_settings_path())
      assert_eq(sb:style({ "omarchy-rail", "--no-reload" }).code, 0)

      -- Seed stale [widget.present] and [widget.record] alongside unrelated state sections
      mkdir_p(sb.state .. "/noctalia")
      local state_toml = table.concat({
        "[bar.default]",
        "thickness = 40",
        "",
        "[widget.present]",
        "enabled = true",
        'format = "legacy"',
        "",
        "[general]",
        'custom_state = "keep-me"',
        "",
        "[widget.record]",
        "enabled = false",
        'output_dir = "/tmp/old"',
        "",
      }, "\n")
      write_file(sb:state_settings_path(), state_toml)

      local res = sb:style({ "cinema-frame", "--no-reload" })
      assert_eq(res.code, 0, "apply with state settings.toml failed: " .. res.combined)

      local pruned_text = read_file(sb:state_settings_path())
      assert_true(pruned_text ~= nil, "settings.toml must still exist after pruning")
      local doc = parse_toml(pruned_text)

      assert_true(not doc.section_exists["widget.present"], "[widget.present] must be pruned")
      assert_true(not doc.section_exists["widget.record"], "[widget.record] must be pruned")
      assert_true(doc.section_exists["bar.default"], "[bar.default] must be preserved")
      assert_eq(toml_get_num(doc, "bar.default", "thickness"), 40, "[bar.default] thickness = 40 preserved")
      assert_true(doc.section_exists["general"], "unrelated [general] section must be preserved")
      assert_eq(
        toml_get_str(doc, "general", "custom_state"),
        "keep-me",
        "unrelated [general] key must be preserved"
      )
    end)
  end)

  ------------------------------------------------------------------------------
  -- 9. Validation failure triggers rollback (leaves config.toml & kaze/style untouched)
  ------------------------------------------------------------------------------
  test("bb.style.validation_rollback", function()
    with_sandbox(abs_repo, function(sb)
      sb:apply_seed()
      assert_eq(sb:style({ "omarchy-rail", "--no-reload" }).code, 0)
      sb:clear_logs()

      local before_toml = read_file(sb:config_toml_path())
      local before_state = read_file(sb:style_state_path())

      local res = sb:style({ "swiss-grid" }, {
        env = {
          HYPRLAND_INSTANCE_SIGNATURE = "rollback-sig",
          STUB_NOCTALIA_VALIDATE_RC = "1",
        },
      })
      assert_true(res.code ~= 0, "kaze-style must exit non-zero when noctalia config validate fails")

      -- Verify validation ran on a staged temp file BEFORE swap
      local val_paths = split_lines(read_file(sb.validate_log) or "")
      assert_true(#val_paths >= 1, "noctalia config validate must have been invoked")
      assert_true(
        val_paths[1] ~= "" and val_paths[1] ~= sb:config_toml_path(),
        "noctalia config validate must run on temp file before swap, got: " .. tostring(val_paths[1])
      )

      -- Live config.toml and kaze/style MUST be byte-for-byte unmodified
      assert_eq(
        read_file(sb:config_toml_path()),
        before_toml,
        "failed validation must leave config.toml unmodified"
      )
      assert_eq(
        read_file(sb:style_state_path()),
        before_state,
        "failed validation must leave kaze/style unmodified"
      )

      -- Neither noctalia reload nor hyprctl reload should have fired
      local nlog = read_file(sb.noctalia_log) or ""
      assert_true(
        not nlog:find("msg config-reload", 1, true),
        "failed validation must not invoke noctalia msg config-reload"
      )
      assert_true(
        (read_file(sb.hyprctl_log) or "") == "",
        "failed validation must not invoke hyprctl reload"
      )

      -- Also verify rollback when --no-reload is passed (validation still gates swap!)
      sb:clear_logs()
      local res2 = sb:style({ "cinema-frame", "--no-reload" }, {
        env = { STUB_NOCTALIA_VALIDATE_RC = "1" },
      })
      assert_true(res2.code ~= 0, "validation failure with --no-reload must still exit non-zero")
      assert_eq(
        read_file(sb:config_toml_path()),
        before_toml,
        "failed validation with --no-reload must leave config.toml unmodified"
      )
      assert_eq(
        read_file(sb:style_state_path()),
        before_state,
        "failed validation with --no-reload must leave kaze/style unmodified"
      )
    end)
  end)

  ------------------------------------------------------------------------------
  -- 10. Live reload (config-reload, templates-apply on theme change, hyprctl)
  --     vs --no-reload suppression
  ------------------------------------------------------------------------------
  test("bb.style.live_reload_and_no_reload", function()
    with_sandbox(abs_repo, function(sb)
      sb:apply_seed()
      assert_eq(sb:style({ "dynamic-island", "--no-reload" }).code, 0)

      -- A) Theme-agnostic apply without --no-reload
      sb:clear_logs()
      local r1 = sb:style({ "omarchy-rail" }, {
        env = { HYPRLAND_INSTANCE_SIGNATURE = "live-sig-1" },
      })
      assert_eq(r1.code, 0, "live apply omarchy-rail failed: " .. r1.combined)
      local nlog1 = read_file(sb.noctalia_log) or ""
      local hlog1 = read_file(sb.hyprctl_log) or ""
      assert_contains(nlog1, "config validate", "must validate config before swap")
      assert_contains(nlog1, "msg config-reload", "must invoke noctalia msg config-reload")
      assert_contains(hlog1, "reload", "must invoke hyprctl reload")

      -- B) Palette-locked apply without --no-reload -> theme changes -> templates-apply
      sb:clear_logs()
      local r2 = sb:style({ "swiss-grid" }, {
        env = { HYPRLAND_INSTANCE_SIGNATURE = "live-sig-2" },
      })
      assert_eq(r2.code, 0, "live apply swiss-grid failed: " .. r2.combined)
      local nlog2 = read_file(sb.noctalia_log) or ""
      local hlog2 = read_file(sb.hyprctl_log) or ""
      assert_contains(nlog2, "config validate", "swiss-grid must validate config")
      assert_contains(nlog2, "msg config-reload", "swiss-grid must call msg config-reload")
      assert_contains(nlog2, "msg templates-apply", "theme change must call msg templates-apply")
      assert_contains(hlog2, "reload", "swiss-grid must call hyprctl reload")

      -- C) Switching back from palette-locked -> theme restored -> templates-apply
      sb:clear_logs()
      local r3 = sb:style({ "dynamic-island" }, {
        env = { HYPRLAND_INSTANCE_SIGNATURE = "live-sig-3" },
      })
      assert_eq(r3.code, 0, "restore apply dynamic-island failed: " .. r3.combined)
      local nlog3 = read_file(sb.noctalia_log) or ""
      assert_contains(nlog3, "msg config-reload", "theme restore must call msg config-reload")
      assert_contains(nlog3, "msg templates-apply", "theme restore must call msg templates-apply")

      -- D) --no-reload MUST NOT invoke msg config-reload or hyprctl reload (both flag positions)
      for _, argv in ipairs({
        { "retro-90s", "--no-reload" },
        { "--no-reload", "omarchy-rail" },
      }) do
        sb:clear_logs()
        local r4 = sb:style(argv, {
          env = { HYPRLAND_INSTANCE_SIGNATURE = "live-sig-4" },
        })
        assert_eq(r4.code, 0, "--no-reload apply (" .. table.concat(argv, " ") .. ") failed: " .. r4.combined)
        local nlog4 = read_file(sb.noctalia_log) or ""
        local hlog4 = read_file(sb.hyprctl_log) or ""
        assert_true(
          not nlog4:find("msg config-reload", 1, true),
          "--no-reload must NOT invoke noctalia msg config-reload, got:\n" .. nlog4
        )
        assert_true(
          not hlog4:find("reload", 1, true),
          "--no-reload must NOT invoke hyprctl reload, got:\n" .. hlog4
        )
      end
    end)
  end)

  ------------------------------------------------------------------------------
  -- 11. --menu mode: dmenu pipe (11 entries), selection, Esc cancel, garbage input
  ------------------------------------------------------------------------------
  test("bb.style.menu_dmenu_flow", function()
    with_sandbox(abs_repo, function(sb)
      sb:apply_seed()
      assert_eq(sb:style({ "dynamic-island", "--no-reload" }).code, 0)

      -- A) Select cinema-frame from dmenu
      sb:clear_logs()
      local sel = sb:style({ "--menu", "--no-reload" }, {
        env = {
          STUB_DMENU_MODE = "match",
          STUB_DMENU_MATCH = "cinema-frame",
        },
      })
      assert_eq(sel.code, 0, "--menu selecting cinema-frame must exit 0: " .. sel.combined)

      -- Verify exact dmenu invocation args: dmenu -p "Style > "
      local argv_lines = split_lines(read_file(sb.dmenu_argv) or "")
      assert_eq(argv_lines[1], "dmenu", "must invoke noctalia dmenu")
      local saw_prompt = false
      for i = 1, #argv_lines - 1 do
        if argv_lines[i] == "-p" and argv_lines[i + 1] == "Style > " then
          saw_prompt = true
          break
        end
      end
      assert_true(
        saw_prompt,
        "must invoke noctalia dmenu -p 'Style > ', got argv: " .. table.concat(argv_lines, " | ")
      )

      -- Verify exactly 11 entries piped to dmenu covering all 11 presets
      local piped = read_file(sb.dmenu_stdin) or ""
      local piped_lines = split_lines(piped)
      assert_eq(#piped_lines, 11, "--menu must pipe exactly 11 entries to dmenu")
      for _, id in ipairs(ALL_PRESETS) do
        assert_contains(piped, id, "--menu piped list must include " .. id)
      end

      -- Verify cinema-frame was actually applied
      local doc, hypr_tbl = assert_common_preset_artifacts(sb, "cinema-frame", "via --menu")
      assert_preset_specifics("cinema-frame", doc, hypr_tbl)

      -- B) Empty output (Esc cancel) -> exit 0, files untouched
      local before_toml = read_file(sb:config_toml_path())
      local before_state = read_file(sb:style_state_path())
      local cancel = sb:style({ "--menu", "--no-reload" }, {
        env = { STUB_DMENU_MODE = "empty" },
      })
      assert_eq(cancel.code, 0, "--menu empty output (Esc) must exit 0")
      assert_eq(read_file(sb:config_toml_path()), before_toml, "Esc cancel must not modify config.toml")
      assert_eq(read_file(sb:style_state_path()), before_state, "Esc cancel must not modify kaze/style")

      -- C) Invalid garbage output -> exit 1, files untouched
      local bad = sb:style({ "--menu", "--no-reload" }, {
        env = {
          STUB_DMENU_MODE = "garbage",
          STUB_DMENU_OUT = "not-a-valid-preset-entry-999",
        },
      })
      assert_eq(bad.code, 1, "--menu invalid garbage output must exit 1, stderr=" .. bad.stderr)
      assert_eq(read_file(sb:config_toml_path()), before_toml, "garbage output must not modify config.toml")
      assert_eq(read_file(sb:style_state_path()), before_state, "garbage output must not modify kaze/style")
    end)
  end)

  ------------------------------------------------------------------------------
  -- 12. kaze-doctor --diff (and --diff-noctalia): 0 drift across ALL 11 presets
  --     AND user GUI edits remain up to date
  ------------------------------------------------------------------------------
  test("bb.style.doctor_diff_zero_drift_and_user_edits", function()
    with_sandbox(abs_repo, function(sb)
      sb:apply_seed()
      local tpl = sb:template_path()

      -- Brute-force ALL 11 presets: every single preset must produce 0 drift
      for _, id in ipairs(ALL_PRESETS) do
        local ap = sb:style({ id, "--no-reload" })
        assert_eq(ap.code, 0, "apply " .. id .. " failed")

        local diff = sb:doctor({ "--diff", "--template", tpl })
        assert_eq(
          diff.code,
          0,
          "kaze-doctor --diff after '" .. id .. "' must exit 0:\n" .. diff.combined
        )
        assert_contains(
          diff.combined,
          "Status: up to date",
          "kaze-doctor --diff after '" .. id .. "' must report up to date"
        )
      end

      -- Verify --diff-noctalia alias works identically
      local alias_res = sb:doctor({ "--diff-noctalia", "--template", tpl })
      assert_eq(alias_res.code, 0, "--diff-noctalia must exit 0:\n" .. alias_res.combined)
      assert_contains(alias_res.combined, "Status: up to date", "--diff-noctalia must report up to date")

      -- User GUI value edits must NOT count as drift
      local cfg = read_file(sb:config_toml_path())
      cfg = toml_set_in_section(cfg, "theme", "mode", '"light"')
      cfg = toml_set_in_section(cfg, "theme", "builtin", '"Catppuccin"')
      cfg = toml_set_existing_or_fallback(cfg, "polkit_agent", "true", "general")
      cfg = toml_set_existing_or_fallback(cfg, "directory", '"/home/user/pictures/walls"', "wallpaper")
      write_file(sb:config_toml_path(), cfg)

      local edited_diff = sb:doctor({ "--diff", "--template", tpl })
      assert_eq(edited_diff.code, 0, "user GUI edits must exit 0:\n" .. edited_diff.combined)
      assert_contains(
        edited_diff.combined,
        "Status: up to date",
        "user GUI edits must still report Status: up to date"
      )
    end)
  end)

  ------------------------------------------------------------------------------
  -- 13. kaze-doctor --diff drift detection (section, key, list item),
  --     --offline [WARN], and error exit codes (1 & 2)
  ------------------------------------------------------------------------------
  test("bb.style.doctor_diff_drift_detection_and_errors", function()
    with_sandbox(abs_repo, function(sb)
      sb:apply_seed()
      local tpl = sb:template_path()
      local baseline = read_file(sb:config_toml_path())

      -- Baseline clean config: --offline exits 0 and emits NO drift warning
      local off_clean = sb:doctor({ "--offline" })
      assert_eq(off_clean.code, 0, "kaze-doctor --offline must exit 0 when clean:\n" .. off_clean.combined)
      assert_true(
        not off_clean.combined:find("kaze-doctor --diff", 1, true),
        "clean config must not emit drift warning:\n" .. off_clean.combined
      )

      -- A) Deleting a section ([widget.display]) -> drift detected + --offline [WARN]
      local no_sec, sec_removed = toml_delete_section(baseline, "widget.display")
      assert_true(sec_removed, "seeded config.toml must contain [widget.display]")
      write_file(sb:config_toml_path(), no_sec)

      local d_sec = sb:doctor({ "--diff", "--template", tpl })
      assert_contains(d_sec.combined, "Status: drift detected", "missing [widget.display] must report drift")
      assert_contains(d_sec.combined, "widget.display", "missing section drift must name widget.display")

      local off = sb:doctor({ "--offline" })
      assert_eq(off.code, 0, "kaze-doctor --offline must exit 0 on drift:\n" .. off.combined)
      assert_contains(off.combined, "[WARN]", "kaze-doctor --offline must emit [WARN] on drift")
      assert_contains(
        off.combined,
        "kaze-doctor --diff",
        "kaze-doctor --offline drift warning must mention kaze-doctor --diff"
      )

      -- B) Deleting a key (popup_shadows) -> drift detected naming popup_shadows
      local no_key, key_removed = toml_delete_key(baseline, "popup_shadows")
      assert_true(key_removed, "seeded config.toml must contain popup_shadows")
      write_file(sb:config_toml_path(), no_key)

      local d_key = sb:doctor({ "--diff", "--template", tpl })
      assert_contains(d_key.combined, "Status: drift detected", "missing popup_shadows must report drift")
      assert_contains(d_key.combined, "popup_shadows", "missing key drift must name popup_shadows")

      local off_key = sb:doctor({ "--offline" })
      assert_eq(off_key.code, 0, "kaze-doctor --offline must exit 0 on key drift:\n" .. off_key.combined)
      assert_contains(off_key.combined, "[WARN]", "kaze-doctor --offline must emit [WARN] on key drift")
      assert_contains(off_key.combined, "kaze-doctor --diff", "key drift warning must mention kaze-doctor --diff")

      -- C) Deleting a list item -> drift detected naming exact missing item
      -- Scan seeded config.toml for non-empty string arrays (non-[bar] / non-[dock] first)
      local base_doc = parse_toml(baseline)
      local candidates = {}
      for sec_name, sec_tbl in pairs(base_doc.sections) do
        for k, raw in pairs(sec_tbl) do
          local arr = parse_toml_string_array(raw)
          if arr and #arr >= 1 then
            local priority = (sec_name:match("^bar") or sec_name == "dock") and 2 or 1
            candidates[#candidates + 1] = {
              priority = priority,
              section = sec_name,
              key = k,
              items = arr,
            }
          end
        end
      end
      table.sort(candidates, function(a, b)
        if a.priority ~= b.priority then
          return a.priority < b.priority
        end
        if a.section ~= b.section then
          return a.section < b.section
        end
        return a.key < b.key
      end)
      assert_true(#candidates >= 1, "seeded config.toml must have at least one non-empty string list")

      local list_drift_verified = false
      local last_list_output = ""
      for _, c in ipairs(candidates) do
        local dropped_item = c.items[1]
        local remaining = {}
        for i = 2, #c.items do
          remaining[#remaining + 1] = c.items[i]
        end
        local mutated = toml_set_in_section(
          baseline,
          c.section,
          c.key,
          format_toml_string_array(remaining)
        )
        write_file(sb:config_toml_path(), mutated)
        local d_list = sb:doctor({ "--diff", "--template", tpl })
        last_list_output = d_list.combined
        if d_list.combined:find("Status: drift detected", 1, true)
          and d_list.combined:find(dropped_item, 1, true)
        then
          local off_list = sb:doctor({ "--offline" })
          assert_eq(off_list.code, 0, "kaze-doctor --offline must exit 0 on list drift:\n" .. off_list.combined)
          assert_contains(off_list.combined, "[WARN]", "list drift must emit [WARN]")
          assert_contains(off_list.combined, "kaze-doctor --diff", "list drift warning must mention kaze-doctor --diff")
          list_drift_verified = true
          break
        end
      end
      assert_true(
        list_drift_verified,
        "deleting a template list item must report 'Status: drift detected' with exact missing item; last output:\n"
          .. last_list_output
      )

      -- D) Missing --template path argument -> exit 2
      write_file(sb:config_toml_path(), baseline)
      local miss_arg = sb:doctor({ "--diff", "--template" })
      assert_eq(miss_arg.code, 2, "missing --template path arg must exit 2, got: " .. miss_arg.combined)

      -- E) Missing user config.toml -> exit 1
      os.remove(sb:config_toml_path())
      local miss_cfg = sb:doctor({ "--diff", "--template", tpl })
      assert_eq(miss_cfg.code, 1, "missing user config.toml must exit 1, got: " .. miss_cfg.combined)
    end)
  end)

  ------------------------------------------------------------------------------
  -- 14. Brute-force ALL 11x11 = 121 ordered preset transitions (Eulerian circuit)
  --     Verifies every single (A -> B) pair preserves invariants, cleans up
  --     bar.rail / capsule_group, honors palette save/restore, and keeps user edits.
  ------------------------------------------------------------------------------
  test("bb.style.brute_force_all_121_transitions", function()
    with_sandbox(abs_repo, function(sb)
      sb:apply_seed()

      -- Seed user edits and known baseline theme
      local cfg = read_file(sb:config_toml_path())
      local polkit_sec
      cfg, polkit_sec = toml_set_existing_or_fallback(cfg, "polkit_agent", "true", "general")
      local wall_sec
      cfg, wall_sec = toml_set_existing_or_fallback(cfg, "directory", '"/custom/walls"', "wallpaper")
      cfg = toml_set_in_section(cfg, "dock", "pinned", '[ "firefox" ]')
      cfg = toml_set_in_section(cfg, "theme", "mode", '"dark"')
      cfg = toml_set_in_section(cfg, "theme", "source", '"builtin"')
      cfg = toml_set_in_section(cfg, "theme", "builtin", '"Catppuccin"')
      write_file(sb:config_toml_path(), cfg)

      local palette_locked = {
        ["swiss-grid"] = true,
        ["tui-hacker"] = true,
        ["retro-90s"] = true,
      }

      -- Build Eulerian circuit over complete directed graph K_11 with self-loops (121 edges)
      local n = #ALL_PRESETS
      local next_edge = {}
      for u = 1, n do
        next_edge[u] = 1
      end
      local stack = { 1 }
      local circuit = {}
      while #stack > 0 do
        local u = stack[#stack]
        if next_edge[u] <= n then
          local v = next_edge[u]
          next_edge[u] = v + 1
          stack[#stack + 1] = v
        else
          circuit[#circuit + 1] = u
          stack[#stack] = nil
        end
      end
      -- Reverse circuit so edges follow traversal order
      local path = {}
      for i = #circuit, 1, -1 do
        path[#path + 1] = circuit[i]
      end
      assert_eq(#path, n * n + 1, "Eulerian circuit over K_11 + self-loops must have 122 vertices")

      -- Apply initial vertex
      local prev_id = ALL_PRESETS[path[1]]
      assert_eq(sb:style({ prev_id, "--no-reload" }).code, 0)

      local seen_pairs = {}
      local pair_count = 0

      for step = 2, #path do
        local cur_id = ALL_PRESETS[path[step]]
        local edge_key = prev_id .. "->" .. cur_id
        if not seen_pairs[edge_key] then
          seen_pairs[edge_key] = true
          pair_count = pair_count + 1
        end

        local res = sb:style({ cur_id, "--no-reload" })
        assert_eq(res.code, 0, "[" .. edge_key .. "] apply failed: " .. res.combined)

        -- State file
        assert_eq(read_file(sb:style_state_path()), cur_id .. "\n", "[" .. edge_key .. "] kaze/style")

        -- hypr/kaze-style.lua pure-Lua load + numeric gaps_out
        local chunk, lerr = loadfile(sb:hypr_style_path(), "t", {})
        assert_true(chunk ~= nil, "[" .. edge_key .. "] loadfile failed: " .. tostring(lerr))
        local ok, hypr_tbl = pcall(chunk)
        assert_true(ok and type(hypr_tbl) == "table" and type(hypr_tbl.gaps_out) == "number",
          "[" .. edge_key .. "] kaze-style.lua must return table with numeric gaps_out")

        -- gtk-3.0/kaze-style.css zero hardcoded hex
        local css = read_file(sb:gtk_style_path()) or ""
        assert_true(css:match("#%x%x%x%x%x%x") == nil, "[" .. edge_key .. "] hex color in CSS")

        -- Parse config.toml & verify core + preset-specific + transition invariants
        local doc = parse_toml(read_file(sb:config_toml_path()) or "")
        assert_true(
          toml_has_key_value_anywhere(doc, "offline_mode", function(v) return v == "true" end),
          "[" .. edge_key .. "] offline_mode = true"
        )
        assert_true(
          toml_has_key_value_anywhere(doc, "telemetry_enabled", function(v) return v == "false" end),
          "[" .. edge_key .. "] telemetry_enabled = false"
        )
        assert_eq(toml_get_bool(doc, "weather", "enabled"), false, "[" .. edge_key .. "] [weather] enabled=false")
        assert_true(doc.section_exists["widget.record"], "[" .. edge_key .. "] [widget.record] exists")

        -- User edits preserved
        assert_eq(toml_get_bool(doc, polkit_sec, "polkit_agent"), true, "[" .. edge_key .. "] polkit_agent=true")
        assert_eq(toml_get_str(doc, wall_sec, "directory"), "/custom/walls", "[" .. edge_key .. "] custom wallpaper")
        assert_true(
          array_equals(parse_toml_string_array(toml_get_raw(doc, "dock", "pinned")), { "firefox" }),
          "[" .. edge_key .. "] dock pinned preserved"
        )

        -- Preset-specific checks
        assert_preset_specifics(cur_id, doc, hypr_tbl)

        -- Non-floating-rail presets must NEVER carry over [bar.rail]
        if cur_id ~= "floating-rail" then
          assert_true(not doc.section_exists["bar.rail"], "[" .. edge_key .. "] stale [bar.rail]")
          assert_true(
            array_equals(parse_toml_string_array(toml_get_raw(doc, "bar", "order")), { "default" }),
            "[" .. edge_key .. '] order must be [ "default" ]'
          )
        end

        -- Palette-locked save/restore invariant on every single edge
        if palette_locked[cur_id] then
          local saved = read_file(sb:saved_theme_path())
          assert_true(saved ~= nil and saved:find("Catppuccin", 1, true) ~= nil,
            "[" .. edge_key .. "] saved-theme.json must keep original Catppuccin")
        else
          assert_true(not file_exists(sb:saved_theme_path()),
            "[" .. edge_key .. "] saved-theme.json must not exist in theme-agnostic preset")
          assert_eq(toml_get_str(doc, "theme", "mode"), "dark", "[" .. edge_key .. "] theme.mode restored")
          assert_eq(toml_get_str(doc, "theme", "builtin"), "Catppuccin", "[" .. edge_key .. "] theme.builtin restored")
        end

        prev_id = cur_id
      end

      assert_eq(pair_count, 121, "must have verified all 121 unique ordered (A -> B) transitions")

      -- After 121 consecutive transitions, kaze-doctor --diff must still report 0 drift
      local post_diff = sb:doctor({ "--diff", "--template", sb:template_path() })
      assert_eq(post_diff.code, 0, "post-121-transition kaze-doctor --diff must exit 0:\n" .. post_diff.combined)
      assert_contains(
        post_diff.combined,
        "Status: up to date",
        "post-121-transition kaze-doctor --diff must report Status: up to date"
      )
    end)
  end)

  ------------------------------------------------------------------------------
  -- 13. Theme Hub widget placement (all 11 styles) + --hub / --theme / --themes
  ------------------------------------------------------------------------------
  test("bb.style.theme_hub_widget_and_cli_flows", function()
    with_sandbox(abs_repo, function(sb)
      sb:apply_seed()

      -- A) Verify Theme Hub widget exists on every single one of the 11 styles,
      -- and sits directly adjacent to notifications wherever notifications is present.
      local notif_styles = {
        ["omarchy-rail"] = true,
        ["corner-hud"] = true,
        ["ghost-zero"] = true,
        ["dynamic-island"] = true,
        ["hardware-notch"] = true,
        ["glass-studio"] = true,
        ["floating-rail"] = true,
      }
      for _, preset_id in ipairs(ALL_PRESETS) do
        local r = sb:style({ preset_id, "--no-reload" })
        assert_eq(r.code, 0, "[" .. preset_id .. "] apply failed: " .. r.combined)
        local txt = read_file(sb:config_toml_path()) or ""
        local doc = parse_toml(txt)
        assert_true(doc.section_exists["widget.theme"], "[" .. preset_id .. "] [widget.theme] must exist")
        assert_true(doc.section_exists["widget.theme.actions"], "[" .. preset_id .. "] [widget.theme.actions] must exist")
        assert_eq(
          toml_get_str(doc, "widget.theme.actions", "left"),
          "exec kaze-style --hub",
          "[" .. preset_id .. "] widget.theme left action must launch Theme Hub"
        )
        if notif_styles[preset_id] then
          assert_true(
            txt:find('"theme", "notifications"', 1, true) ~= nil,
            "[" .. preset_id .. '] "theme" must be placed right next to "notifications"'
          )
        elseif preset_id == "swiss-grid" then
          assert_true(doc.section_exists["widget.swiss_theme"], "[swiss-grid] [widget.swiss_theme] must exist")
          assert_true(txt:find('"swiss_theme"', 1, true) ~= nil, '[swiss-grid] bar must include "swiss_theme"')
        elseif preset_id == "tui-hacker" then
          assert_true(doc.section_exists["widget.tui_theme"], "[tui-hacker] [widget.tui_theme] must exist")
          assert_true(txt:find('"tui_theme"', 1, true) ~= nil, '[tui-hacker] bar must include "tui_theme"')
        else
          assert_true(txt:find('"theme"', 1, true) ~= nil, "[" .. preset_id .. '] bar must include "theme"')
        end
      end

      -- B) --themes lists built-in, custom palettes, and wallpaper with * on active
      assert_eq(sb:style({ "dynamic-island", "--no-reload" }).code, 0)
      local lt = sb:style({ "--themes" })
      assert_eq(lt.code, 0, "--themes must exit 0: " .. lt.combined)
      assert_contains(lt.stdout, "* Kanagawa", "--themes marks active Kanagawa")
      assert_contains(lt.stdout, "Tokyo-Night", "--themes lists Tokyo-Night")
      assert_contains(lt.stdout, "Kaze-RosePine", "--themes discovers custom palette Kaze-RosePine")
      assert_contains(lt.stdout, "wallpaper", "--themes lists wallpaper M3 option")

      -- C) --theme <builtin|custom|wallpaper> updates [theme] cleanly + triggers reload
      sb:clear_logs()
      local t1 = sb:style({ "--theme", "catppuccin" }, {
        env = { HYPRLAND_INSTANCE_SIGNATURE = "sig-theme-test" },
      })
      assert_eq(t1.code, 0, "--theme catppuccin must exit 0: " .. t1.combined)
      local d1 = parse_toml(read_file(sb:config_toml_path()) or "")
      assert_eq(toml_get_str(d1, "theme", "source"), "builtin", "source = builtin")
      assert_eq(toml_get_str(d1, "theme", "builtin"), "Catppuccin", "builtin = Catppuccin")
      local nlog1 = read_file(sb.noctalia_log) or ""
      assert_contains(nlog1, "msg config-reload", "--theme reloads Noctalia")
      assert_contains(nlog1, "msg templates-apply", "--theme applies templates")
      assert_contains(read_file(sb.hyprctl_log) or "", "reload", "--theme reloads Hyprland")

      local t2 = sb:style({ "--theme=Kaze-RosePine", "--no-reload" })
      assert_eq(t2.code, 0, "--theme=Kaze-RosePine must exit 0: " .. t2.combined)
      local d2 = parse_toml(read_file(sb:config_toml_path()) or "")
      assert_eq(toml_get_str(d2, "theme", "source"), "custom", "source = custom")
      assert_eq(toml_get_str(d2, "theme", "custom_palette"), "Kaze-RosePine", "custom_palette = Kaze-RosePine")

      local t3 = sb:style({ "--theme", "wallpaper", "--no-reload" })
      assert_eq(t3.code, 0, "--theme wallpaper must exit 0: " .. t3.combined)
      local d3 = parse_toml(read_file(sb:config_toml_path()) or "")
      assert_eq(toml_get_str(d3, "theme", "source"), "wallpaper", "source = wallpaper")

      local tbad = sb:style({ "--theme", "nonexistent-palette", "--no-reload" })
      assert_eq(tbad.code, 2, "invalid --theme must exit 2")

      -- D) --hub dmenu flows (Toggle Dark/Light, Wallpaper Picker, Noctalia Settings, cancel)
      sb:clear_logs()
      local h_mode = sb:style({ "--hub" }, {
        env = { STUB_DMENU_MODE = "match", STUB_DMENU_MATCH = "Toggle Dark/Light" },
      })
      assert_eq(h_mode.code, 0, "--hub Toggle Dark/Light must exit 0: " .. h_mode.combined)
      assert_contains(read_file(sb.noctalia_log) or "", "msg theme-mode-toggle", "--hub Toggle Dark/Light invokes theme-mode-toggle")

      sb:clear_logs()
      local h_wall = sb:style({ "--hub" }, {
        env = { STUB_DMENU_MODE = "match", STUB_DMENU_MATCH = "Wallpaper Picker" },
      })
      assert_eq(h_wall.code, 0, "--hub Wallpaper Picker must exit 0: " .. h_wall.combined)
      assert_contains(read_file(sb.noctalia_log) or "", "msg panel-toggle wallpaper", "--hub Wallpaper Picker opens wallpaper panel")

      sb:clear_logs()
      local h_set = sb:style({ "--hub" }, {
        env = { STUB_DMENU_MODE = "match", STUB_DMENU_MATCH = "Noctalia Settings" },
      })
      assert_eq(h_set.code, 0, "--hub Noctalia Settings must exit 0: " .. h_set.combined)
      assert_contains(read_file(sb.noctalia_log) or "", "msg settings-toggle", "--hub Noctalia Settings opens settings GUI")

      local h_cancel = sb:style({ "--hub" }, { env = { STUB_DMENU_MODE = "empty" } })
      assert_eq(h_cancel.code, 0, "--hub cancel must exit 0 cleanly")

      -- E) --theme (interactive picker without arg) applies selected palette
      local tm = sb:style({ "--theme", "--no-reload" }, {
        env = { STUB_DMENU_MODE = "match", STUB_DMENU_MATCH = "Nord" },
      })
      assert_eq(tm.code, 0, "--theme interactive Nord must exit 0: " .. tm.combined)
      local dm = parse_toml(read_file(sb:config_toml_path()) or "")
      assert_eq(toml_get_str(dm, "theme", "builtin"), "Nord", "interactive --theme selected Nord")
    end)
  end)

  ------------------------------------------------------------------------------
  -- 14. Visual 2-Column Theme Hub: frame geometry, mouse/key input, rollback
  ------------------------------------------------------------------------------
  test("bb.style.theme_hub_visual_tui_render_and_rollback", function()
    with_sandbox(abs_repo, function(sb)
      sb:apply_seed()
      local script = [[
        package.path = os.getenv("KAZE_DOTS_DIR") .. "/lua/?.lua;" .. package.path
        local hub = require("kaze.theme_hub_tui")
        local styles = require("kaze.styles")
        local fs = require("kaze.fs")

        -- 1) Render every style & palette across multiple sizes and assert exact cols x rows geometry
        local sizes = { { 132, 42 }, { 96, 34 }, { 78, 26 }, { 56, 24 } }
        for _, sz in ipairs(sizes) do
          local cols, rows = sz[1], sz[2]
          for _, tab in ipairs({ "styles", "palettes" }) do
            local st = hub.initial_state({ initial_tab = tab })
            local gcols = hub.grid_columns(cols)
            local items = (tab == "styles") and st.style_items or st.theme_items
            local total_rows = math.ceil(#items / gcols)
            for sc = 0, math.max(0, total_rows - 1) do
              if tab == "styles" then st.scroll_styles = sc else st.scroll_palettes = sc end
              local frame = hub.render_frame(st, cols, rows)
              local lines = {}
              for ln in (frame .. "\r\n"):gmatch("(.-)\r\n") do
                lines[#lines + 1] = ln
              end
              assert(#lines == rows, string.format("%s %dx%d sc=%d: expected %d lines, got %d", tab, cols, rows, sc, rows, #lines))
              for idx, ln in ipairs(lines) do
                local w = hub.display_width(ln)
                assert(w == cols, string.format("%s %dx%d sc=%d line %d: width %d ~= %d (%s)", tab, cols, rows, sc, idx, w, cols, hub.strip_ansi(ln)))
              end
              for _, h in ipairs(st.hits.controls) do
                assert(h.row >= 1 and h.row <= rows and h.col1 >= 1 and h.col2 <= cols and h.col1 <= h.col2, "control hitbox out of bounds")
              end
              for _, c in ipairs(st.hits.cards) do
                assert(c.row1 >= 1 and c.row2 <= rows and c.col1 >= 1 and c.col2 <= cols and c.col1 <= c.col2, "card hitbox out of bounds")
              end
            end
          end
        end

        -- 2) Grid navigation & input parser (keyboard + SGR-1006 mouse)
        local st = hub.initial_state({ initial_tab = "styles" })
        st.style_idx = 1
        assert(hub.move_selection(st, "RIGHT", 116, 3) and st.style_idx == 2)
        assert(hub.move_selection(st, "DOWN", 116, 3) and st.style_idx == 4)
        assert(hub.move_selection(st, "LEFT", 116, 3) and st.style_idx == 3)
        assert(hub.move_selection(st, "UP", 116, 3) and st.style_idx == 1)
        assert(hub.move_selection(st, "END", 116, 3) and st.style_idx == 11)
        assert(hub.move_selection(st, "HOME", 116, 3) and st.style_idx == 1)

        local m = hub.parse_input("\27[<0;42;12M")
        assert(m.kind == "MOUSE" and m.button == 0 and m.col == 42 and m.row == 12 and not m.release)
        local mr = hub.parse_input("\27[<65;10;5m")
        assert(mr.kind == "MOUSE" and mr.button == 65 and mr.release)
        assert(hub.parse_input("\27").kind == "ESC")
        assert(hub.parse_input("\27[C").kind == "RIGHT")
        assert(hub.parse_input("\t").kind == "TAB")

        -- 3) Snapshot & atomic Esc rollback restores all 5 files byte-for-byte
        local snap = hub.capture_snapshot()
        assert(styles.apply("swiss-grid", { reload = false }))
        assert(fs.read_file(snap.style_path) == "swiss-grid\n")
        assert(fs.file_exists(snap.saved_path))
        assert(styles.apply_theme("Catppuccin", { reload = false }))
        hub.restore_snapshot(snap, { reload = false })
        assert(fs.read_file(snap.config_path) == snap.config_text, "config.toml not restored byte-for-byte")
        assert(fs.read_file(snap.style_path) == snap.style_text, "kaze/style not restored")
        assert(fs.read_file(snap.saved_path) == snap.saved_text, "saved-theme.json not restored")
        assert(fs.read_file(snap.hypr_path) == snap.hypr_text, "hypr/kaze-style.lua not restored")
        assert(fs.read_file(snap.gtk_path) == snap.gtk_text, "gtk-3.0/kaze-style.css not restored")
        print("THEME_HUB_TUI_UNIT_OK")
      ]]
      local r = sb:exec("lua", { "-e", script })
      assert_eq(r.code, 0, "theme_hub_tui unit checks failed:\n" .. r.combined)
      assert_contains(r.stdout, "THEME_HUB_TUI_UNIT_OK")
    end)
  end)

  ------------------------------------------------------------------------------
  -- 15. Visual Theme Hub window toggle (--hub-window) & real PTY live preview/Esc
  ------------------------------------------------------------------------------
  test("bb.style.theme_hub_window_toggle_and_pty_live_rollback", function()
    with_sandbox(abs_repo, function(sb)
      sb:apply_seed()

      -- A) --hub inside Hyprland launches floating kaze-theme-hub Foot window
      sb:clear_logs()
      local w1 = sb:style({ "--hub", "--tab", "palettes", "--no-live", "--no-reload" }, {
        env = { HYPRLAND_INSTANCE_SIGNATURE = "sig-hub-win" },
      })
      assert_eq(w1.code, 0, "--hub in Hyprland must launch kaze-theme-hub: " .. w1.combined)
      local olog = read_file(sb.other_log) or ""
      assert_contains(olog, "footclient", "must spawn via footclient")
      assert_contains(olog, "-a kaze-theme-hub", "must set app-id kaze-theme-hub")
      assert_contains(olog, "--hub-tui", "must invoke --hub-tui inside Foot window")
      assert_contains(olog, "--tab palettes", "must forward --tab palettes")
      assert_contains(olog, "--no-live", "must forward --no-live")

      -- B) Existing unfocused window -> focuses instead of spawning a second instance
      sb:clear_logs()
      local w2 = sb:style({ "--hub-window" }, {
        env = {
          HYPRLAND_INSTANCE_SIGNATURE = "sig-hub-win",
          STUB_HYPRCTL_CLIENTS = '[{"address":"0xdeadbeef","class":"kaze-theme-hub"}]',
          STUB_HYPRCTL_ACTIVE = '{"address":"0x11111111"}',
        },
      })
      assert_eq(w2.code, 0, "unfocused --hub-window must exit 0: " .. w2.combined)
      assert_contains(read_file(sb.hyprctl_log) or "", "hl.dsp.focus", "must focus existing hub window")
      assert_eq(read_file(sb.other_log) or "", "", "must not spawn second footclient when focusing")

      -- C) Existing focused window -> closes (toggle behavior)
      sb:clear_logs()
      local w3 = sb:style({ "--hub-window" }, {
        env = {
          HYPRLAND_INSTANCE_SIGNATURE = "sig-hub-win",
          STUB_HYPRCTL_CLIENTS = '[{"address":"0xdeadbeef","class":"kaze-theme-hub"}]',
          STUB_HYPRCTL_ACTIVE = '{"address":"0xdeadbeef"}',
        },
      })
      assert_eq(w3.code, 0, "focused --hub-window must exit 0: " .. w3.combined)
      assert_contains(read_file(sb.hyprctl_log) or "", "hl.dsp.window.close", "must close active hub window on toggle")

      -- D) Invalid --tab exits 2; --hub-dmenu forces dmenu even with HYPRLAND_INSTANCE_SIGNATURE
      local bad_tab = sb:style({ "--hub-window", "--tab", "nope" })
      assert_eq(bad_tab.code, 2, "invalid --tab must exit 2")
      sb:clear_logs()
      local dm_force = sb:style({ "--hub-dmenu" }, {
        env = {
          HYPRLAND_INSTANCE_SIGNATURE = "sig-hub-win",
          STUB_DMENU_MODE = "match",
          STUB_DMENU_MATCH = "Noctalia Settings",
        },
      })
      assert_eq(dm_force.code, 0, "--hub-dmenu must exit 0: " .. dm_force.combined)
      assert_contains(read_file(sb.noctalia_log) or "", "msg settings-toggle")

      -- E) Real PTY end-to-end: live preview on arrow move -> atomic Esc revert, then Tab -> Right -> Enter commit
      local orig_cfg = read_file(sb:config_toml_path())
      local orig_style = read_file(sb:style_state_path())
      local pty_script = [[
import fcntl, os, pty, select, struct, subprocess, sys, termios, time

exe, mode = sys.argv[1], sys.argv[2]
mfd, sfd = pty.openpty()
fcntl.ioctl(sfd, termios.TIOCSWINSZ, struct.pack("HHHH", 38, 116, 0, 0))

def child_setup():
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)

proc = subprocess.Popen(
    [exe, "--hub-tui", "--no-reload"],
    stdin=sfd, stdout=sfd, stderr=sfd,
    preexec_fn=child_setup, close_fds=True,
)
os.close(sfd)

def drain(timeout):
    buf = bytearray()
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        r, _, _ = select.select([mfd], [], [], max(0.02, end - time.monotonic()))
        if not r:
            continue
        try:
            chunk = os.read(mfd, 8192)
            if not chunk:
                break
            buf.extend(chunk)
        except OSError:
            break
    return bytes(buf)

out = drain(0.45)
assert b"KAZE THEME HUB" in out, "missing initial Theme Hub frame"
if mode == "revert":
    os.write(mfd, b"\x1b[C")  # Right arrow -> live preview next style
    out_r = drain(0.45)
    assert b"Previewing style" in out_r, "expected live preview status message"
    style_path = os.path.join(os.environ["XDG_CONFIG_HOME"], "kaze", "style")
    mid_style = open(style_path).read().strip()
    assert mid_style != "dynamic-island", f"live preview did not apply on arrow move: {mid_style}"
    os.write(mfd, b"\x1b")    # Esc -> atomic revert & exit
    drain(0.30)
else:
    os.write(mfd, b"\t")      # Tab -> Palettes
    out2 = drain(0.35)
    assert b"Tokyo-Night" in out2, "missing Palettes tab content"
    os.write(mfd, b"\x1b[C")  # Right arrow -> Tokyo-Night
    drain(0.40)
    os.write(mfd, b"\r")      # Enter -> commit & exit
    drain(0.30)

proc.wait(timeout=5)
os.close(mfd)
assert proc.returncode == 0, f"unexpected exit code: {proc.returncode}"
print("PTY_OK_" + mode)
]]
      local p1 = sb:exec("python3", { "-c", pty_script, abs_repo .. "/bin/kaze-style", "revert" })
      assert_eq(p1.code, 0, "PTY live-preview + Esc revert failed:\n" .. p1.combined)
      assert_contains(p1.stdout, "PTY_OK_revert")
      assert_eq(read_file(sb:config_toml_path()), orig_cfg, "Esc must revert config.toml byte-for-byte")
      assert_eq(read_file(sb:style_state_path()), orig_style, "Esc must revert kaze/style byte-for-byte")

      local p2 = sb:exec("python3", { "-c", pty_script, abs_repo .. "/bin/kaze-style", "commit" })
      assert_eq(p2.code, 0, "PTY Tab + Right + Enter commit failed:\n" .. p2.combined)
      assert_contains(p2.stdout, "PTY_OK_commit")
      local committed_doc = parse_toml(read_file(sb:config_toml_path()) or "")
      assert_eq(toml_get_str(committed_doc, "theme", "builtin"), "Tokyo-Night", "Enter must commit Tokyo-Night palette")
    end)
  end)
end

return run_suite
