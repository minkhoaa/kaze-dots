-- Blind black-box & brute-force behavioral test suite for:
--   bin/kaze-session
--   bin/kaze-footclient
--   bin/kaze-tui
--
-- Derived strictly from the Behavioral Specification using Lua stdlib only.
-- Every test executes in an isolated /tmp/kaze-bb-sft-* sandbox with a
-- hermetic PATH and scrubbed environment (`env -i`).

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
    error("write_file failed for " .. tostring(path) .. ": " .. tostring(err))
  end
  f:write(content)
  f:close()
end

local function mkdir_p(path)
  local ok = os.execute("mkdir -p -- " .. sh_quote(path))
  if not ok then
    error("mkdir -p failed for " .. tostring(path))
  end
end

local function chmod(path, mode)
  local ok = os.execute("chmod " .. mode .. " -- " .. sh_quote(path))
  if not ok then
    error("chmod failed for " .. tostring(path))
  end
end

local function capture_cmd(cmd)
  local p = io.popen(cmd, "r")
  if not p then
    error("io.popen failed: " .. cmd)
  end
  local out = p:read("*a") or ""
  local ok, why, code = p:close()
  return out, ok, why, code
end

local function resolve_abs_dir(dir)
  local out = capture_cmd("cd " .. sh_quote(dir) .. " && pwd -P")
  return (out:gsub("[\r\n]+$", ""))
end

local function current_uid()
  local out = capture_cmd("/usr/bin/id -u")
  return (out:gsub("%s+", ""))
end

local function stat_mode(path)
  local out = capture_cmd("/usr/bin/stat -c '%04a' -- " .. sh_quote(path))
  return (out:gsub("%s+", ""))
end

-- Safe POSIX utilities symlinked into each sandbox's sysbin so PATH NEVER
-- includes /usr/bin or /bin directly (preventing any host binary leakage).
local SAFE_SYS_TOOLS = {
  "lua", "sh", "bash", "env", "id", "mkdir", "rmdir", "rm", "mv", "cp",
  "chmod", "install", "stat", "mktemp", "tr", "sed", "grep", "awk", "cat",
  "dirname", "basename", "readlink", "realpath", "touch", "date", "uname",
  "ls", "ln", "head", "tail", "cut", "sort", "uniq", "wc", "printf", "true",
  "false", "test", "[", "tee", "find", "xargs", "sleep", "dd", "od", "which",
  "pwd", "echo", "kill", "expr", "flock", "timeout", "locale", "getent",
  "whoami", "seq", "cmp", "diff",
}

local function discover_sys_tools()
  local found = {}
  for i = 1, #SAFE_SYS_TOOLS do
    local name = SAFE_SYS_TOOLS[i]
    local candidates = { "/usr/bin/" .. name, "/bin/" .. name }
    for j = 1, #candidates do
      local f = io.open(candidates[j], "rb")
      if f then
        f:close()
        found[name] = candidates[j]
        break
      end
    end
  end
  return found
end

local SYS_TOOL_PATHS = discover_sys_tools()
local HOST_UID = current_uid()

-- Parse \x1e-delimited records (octal \036) and \x1f-delimited fields (octal \037) from calls.log.
-- Each entry: { cmd = <name>, args = { arg1, arg2, ... } }
local function parse_call_log(path)
  local raw = read_file(path)
  if not raw or raw == "" then
    return {}
  end
  local calls = {}
  local pos = 1
  local len = #raw
  while pos <= len do
    local rec_start = raw:find("\x1e", pos, true)
    if not rec_start then
      break
    end
    local next_rec = raw:find("\x1e", rec_start + 1, true)
    local rec = raw:sub(rec_start + 1, next_rec and (next_rec - 1) or len)
    local fields = {}
    local fpos = 1
    local rlen = #rec
    while true do
      local sep = rec:find("\x1f", fpos, true)
      if sep then
        fields[#fields + 1] = rec:sub(fpos, sep - 1)
        fpos = sep + 1
      else
        fields[#fields + 1] = rec:sub(fpos, rlen)
        break
      end
    end
    local cmd = fields[1] or ""
    local args = {}
    for i = 2, #fields do
      args[#args + 1] = fields[i]
    end
    calls[#calls + 1] = { cmd = cmd, args = args }
    if not next_rec then
      break
    end
    pos = next_rec
  end
  return calls
end

local function args_equal(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

local function format_call(c)
  local parts = { c.cmd }
  for i = 1, #c.args do
    parts[#parts + 1] = string.format("%q", c.args[i])
  end
  return table.concat(parts, " ")
end

local function format_calls(calls)
  if #calls == 0 then
    return "<none>"
  end
  local lines = {}
  for i = 1, #calls do
    lines[#lines + 1] = string.format("  [%d] %s", i, format_call(calls[i]))
  end
  return "\n" .. table.concat(lines, "\n")
end

local function find_calls(calls, cmd)
  local out = {}
  for i = 1, #calls do
    if calls[i].cmd == cmd then
      out[#out + 1] = calls[i]
    end
  end
  return out
end

local function has_call(calls, cmd, expected_args)
  for i = 1, #calls do
    if calls[i].cmd == cmd then
      if not expected_args or args_equal(calls[i].args, expected_args) then
        return i
      end
    end
  end
  return nil
end

local function list_contains(list, val)
  for i = 1, #list do
    if list[i] == val then
      return i
    end
  end
  return nil
end

-- Parse KEY=VALUE lines from systemd EnvironmentFile (handles optional quoting).
local function parse_env_file(content)
  local env = {}
  if not content then
    return env
  end
  for line in (content .. "\n"):gmatch("(.-)\n") do
    local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
      local k, v = trimmed:match("^([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
      if k then
        if #v >= 2 and v:sub(1, 1) == '"' and v:sub(-1) == '"' then
          v = v:sub(2, -2):gsub('\\"', '"'):gsub("\\\\", "\\")
        elseif #v >= 2 and v:sub(1, 1) == "'" and v:sub(-1) == "'" then
          v = v:sub(2, -2)
        end
        env[k] = v
      end
    end
  end
  return env
end

local function create_sandbox(abs_repo)
  local root = capture_cmd("/usr/bin/mktemp -d /tmp/kaze-bb-sft-XXXXXX"):gsub("[\r\n]+$", "")
  if root == "" or root:sub(1, 17) ~= "/tmp/kaze-bb-sft-" then
    error("mktemp returned unexpected sandbox path: " .. tostring(root))
  end

  local sb = {
    root = root,
    repo = abs_repo,
    home = root .. "/home",
    config = root .. "/config",
    data = root .. "/data",
    cache = root .. "/cache",
    state = root .. "/state",
    runtime = root .. "/runtime",
    stub_bin = root .. "/stub_bin",
    sys_bin = root .. "/sys_bin",
    tmp = root .. "/tmp",
    call_log = root .. "/calls.log",
    run_seq = 0,
  }

  local dirs = {
    sb.home,
    sb.config,
    sb.data,
    sb.cache,
    sb.state,
    sb.runtime,
    sb.stub_bin,
    sb.sys_bin,
    sb.tmp,
  }
  local mkdir_parts = { "mkdir -p --" }
  for i = 1, #dirs do
    mkdir_parts[#mkdir_parts + 1] = sh_quote(dirs[i])
  end
  assert(os.execute(table.concat(mkdir_parts, " ")))
  chmod(sb.runtime, "0700")

  -- Populate curated sys_bin with symlinks in a single shell invocation.
  local ln_cmds = {}
  for name, target in pairs(SYS_TOOL_PATHS) do
    ln_cmds[#ln_cmds + 1] = "ln -sf -- " .. sh_quote(target) .. " " .. sh_quote(sb.sys_bin .. "/" .. name)
  end
  assert(os.execute(table.concat(ln_cmds, " && ")))

  write_file(sb.call_log, "")

  function sb:clear_calls()
    write_file(self.call_log, "")
  end

  function sb:calls()
    return parse_call_log(self.call_log)
  end

  function sb:stub_preamble(name)
    return table.concat({
      "#!/usr/bin/bash",
      "{",
      "  printf '\\036%s' " .. sh_quote(name),
      "  for __kaze_a in \"$@\"; do",
      "    printf '\\037%s' \"$__kaze_a\"",
      "  done",
      "} >> " .. sh_quote(self.call_log),
    }, "\n") .. "\n"
  end

  function sb:add_stub(name, body, dir_override)
    local dir = dir_override or self.stub_bin
    mkdir_p(dir)
    local path = dir .. "/" .. name
    write_file(path, self:stub_preamble(name) .. (body or "exit 0\n"))
    chmod(path, "0755")
    return path
  end

  function sb:remove_stub(name, dir_override)
    local dir = dir_override or self.stub_bin
    os.remove(dir .. "/" .. name)
  end

  function sb:add_passthrough_wrapper(name, target_path)
    local path = self.stub_bin .. "/" .. name
    write_file(path, "#!/usr/bin/bash\nexec " .. sh_quote(target_path) .. " \"$@\"\n")
    chmod(path, "0755")
    return path
  end

  function sb:install_systemctl_stub()
    self:add_stub("systemctl", [==[
# Handle --user queries/actions deterministically via TEST_* env vars.
if [[ "${1:-}" == "--user" ]]; then
  shift
fi
cmd="${1:-}"
shift || true
case "$cmd" in
  show)
    unit=""
    for a in "$@"; do
      case "$a" in
        -p|-P|--property|--value|ActiveState) ;;
        -*) ;;
        *) unit="$a" ;;
      esac
    done
    case "$unit" in
      kaze-session.target)
        printf '%s\n' "${TEST_TARGET_STATE:-inactive}"
        exit "${TEST_TARGET_SHOW_EXIT:-0}"
        ;;
      kaze-record.service)
        printf '%s\n' "${TEST_RECORD_STATE:-inactive}"
        exit "${TEST_RECORD_SHOW_EXIT:-0}"
        ;;
      *)
        printf '%s\n' "inactive"
        exit 0
        ;;
    esac
    ;;
  show-environment)
    if [[ -n "${TEST_SYSTEMD_ENV_FILE:-}" && -f "${TEST_SYSTEMD_ENV_FILE}" ]]; then
      cat "${TEST_SYSTEMD_ENV_FILE}"
    elif [[ -n "${TEST_SYSTEMD_ENV:-}" ]]; then
      printf '%s\n' "${TEST_SYSTEMD_ENV}"
    fi
    exit "${TEST_SHOW_ENV_EXIT:-0}"
    ;;
  start)
    exit "${TEST_START_TARGET_EXIT:-0}"
    ;;
  stop)
    exit "${TEST_STOP_EXIT:-0}"
    ;;
  unset-environment)
    exit "${TEST_UNSET_ENV_EXIT:-0}"
    ;;
  *)
    exit "${TEST_SYSTEMCTL_OTHER_EXIT:-0}"
    ;;
esac
]==])
  end

  function sb:install_dbus_stub()
    self:add_stub("dbus-update-activation-environment", [==[
if [[ -n "${TEST_DBUS_ENV_LOG:-}" ]]; then
  printf 'W=%s|D=%s|H=%s\n' "${WAYLAND_DISPLAY-<unset>}" "${XDG_CURRENT_DESKTOP-<unset>}" "${HYPRLAND_INSTANCE_SIGNATURE-<unset>}" >> "$TEST_DBUS_ENV_LOG"
fi
exit "${TEST_DBUS_EXIT:-0}"
]==])
  end

  function sb:install_hyprctl_stub()
    self:add_stub("hyprctl", [==[
if [[ "${1:-}" == "-j" ]]; then
  case "${2:-}" in
    clients)
      if [[ -n "${TEST_HYPR_CLIENTS_FILE:-}" && -f "${TEST_HYPR_CLIENTS_FILE}" ]]; then
        cat "${TEST_HYPR_CLIENTS_FILE}"
      elif [[ -n "${TEST_HYPR_CLIENTS+x}" ]]; then
        printf '%s\n' "${TEST_HYPR_CLIENTS}"
      else
        printf '[]\n'
      fi
      exit "${TEST_HYPR_CLIENTS_EXIT:-0}"
      ;;
    activewindow)
      if [[ -n "${TEST_HYPR_ACTIVE_FILE:-}" && -f "${TEST_HYPR_ACTIVE_FILE}" ]]; then
        cat "${TEST_HYPR_ACTIVE_FILE}"
      elif [[ -n "${TEST_HYPR_ACTIVE+x}" ]]; then
        printf '%s\n' "${TEST_HYPR_ACTIVE}"
      else
        printf '{}\n'
      fi
      exit "${TEST_HYPR_ACTIVE_EXIT:-0}"
      ;;
  esac
elif [[ "${1:-}" == "dispatch" ]]; then
  exit "${TEST_HYPR_DISPATCH_EXIT:-0}"
elif [[ "${1:-}" == "eval" ]]; then
  exit "${TEST_HYPR_EVAL_EXIT:-0}"
fi
exit 0
]==])
  end

  function sb:install_footclient_stub()
    self:add_stub("footclient", [==[
exit "${TEST_FOOT_EXIT:-0}"
]==])
  end

  function sb:run_bin(bin_rel, args, env_overrides)
    self.run_seq = self.run_seq + 1
    local out_file = self.tmp .. "/out." .. self.run_seq
    local err_file = self.tmp .. "/err." .. self.run_seq

    local env_map = {
      HOME = self.home,
      USER = "kaze-test",
      PATH = self.stub_bin .. ":" .. self.sys_bin,
      XDG_CONFIG_HOME = self.config,
      XDG_DATA_HOME = self.data,
      XDG_CACHE_HOME = self.cache,
      XDG_STATE_HOME = self.state,
      XDG_RUNTIME_DIR = self.runtime,
      KAZE_ARCH_RELEASE_FILE = self.root .. "/etc/arch-release",
      KAZE_SYS_DRM_DIR = self.root .. "/sys/class/drm",
      KAZE_GREETD_CONFIG = self.root .. "/etc/greetd/config.toml",
      KAZE_SYSTEMD_ETC_DIR = self.root .. "/etc/systemd",
      KAZE_AUR_BASE_URL = "http://127.0.0.1:1/disabled",
    }

    if env_overrides then
      for k, v in pairs(env_overrides) do
        if v == false then
          env_map[k] = nil
        else
          env_map[k] = tostring(v)
        end
      end
    end

    local keys = {}
    for k in pairs(env_map) do
      keys[#keys + 1] = k
    end
    table.sort(keys)

    local parts = { "/usr/bin/env", "-i" }
    for i = 1, #keys do
      local k = keys[i]
      parts[#parts + 1] = sh_quote(k .. "=" .. env_map[k])
    end

    local bin_path = self.repo .. "/" .. bin_rel
    parts[#parts + 1] = sh_quote(bin_path)
    if args then
      for i = 1, #args do
        parts[#parts + 1] = sh_quote(args[i])
      end
    end

    local cmd = table.concat(parts, " ")
      .. " >" .. sh_quote(out_file)
      .. " 2>" .. sh_quote(err_file)

    local _, why, code = os.execute(cmd)
    local exit_code
    if why == "exit" then
      exit_code = code
    elseif why == "signal" then
      exit_code = 128 + (code or 0)
    else
      exit_code = -1
    end

    return {
      code = exit_code,
      why = why,
      stdout = read_file(out_file) or "",
      stderr = read_file(err_file) or "",
    }
  end

  return sb
end

local function run_suite(test, assert_eq, assert_true, assert_contains, repo_dir)
  local abs_repo = resolve_abs_dir(repo_dir or ".")

  local function with_sandbox(fn)
    local sb = create_sandbox(abs_repo)
    local ok, err = pcall(fn, sb)
    os.execute("rm -rf -- " .. sh_quote(sb.root))
    if not ok then
      error(err, 0)
    end
  end

  -- =========================================================================
  -- 1. bin/kaze-session
  -- =========================================================================

  test("bb.session.cli_validation", function()
    with_sandbox(function(sb)
      sb:install_systemctl_stub()
      sb:install_dbus_stub()
      sb:install_hyprctl_stub()
      sb:add_stub("noctalia", "exit 0\n")
      sb:add_stub("loginctl", "exit 0\n")
      sb:add_stub("busctl", "exit 0\n")

      -- -h and --help -> exit 0
      for _, flag in ipairs({ "-h", "--help" }) do
        sb:clear_calls()
        local r = sb:run_bin("bin/kaze-session", { flag })
        assert_eq(r.code, 0, "kaze-session " .. flag .. " should exit 0")
        assert_true((r.stdout .. r.stderr) ~= "", "help should produce output")
        assert_eq(#sb:calls(), 0, "help must not invoke external tools")
      end

      -- Missing arg, extra args, unknown/bogus actions -> exit 2
      local bad_invocations = {
        {},
        { "start", "extra" },
        { "stop", "extra" },
        { "lock", "extra" },
        { "wake-displays", "extra" },
        { "start", "a", "b" },
        { "restart" },
        { "--bogus" },
        { "-x" },
        { "status" },
        { "START" },
        { "" },
        { "--" },
      }
      for _, argv in ipairs(bad_invocations) do
        sb:clear_calls()
        local r = sb:run_bin("bin/kaze-session", argv, {
          WAYLAND_DISPLAY = "wayland-1",
          XDG_CURRENT_DESKTOP = "Hyprland",
          HYPRLAND_INSTANCE_SIGNATURE = "sig-cli",
        })
        assert_eq(r.code, 2, "expected exit 2 for args: " .. table.concat(argv, " "))
        assert_eq(#sb:calls(), 0, "invalid CLI must not invoke side-effect binaries: " .. format_calls(sb:calls()))
      end
    end)
  end)

  test("bb.session.start_missing_required_env", function()
    with_sandbox(function(sb)
      sb:install_systemctl_stub()
      sb:install_dbus_stub()

      local req = {
        { "WAYLAND_DISPLAY", "wayland-1" },
        { "XDG_CURRENT_DESKTOP", "Hyprland" },
        { "HYPRLAND_INSTANCE_SIGNATURE", "sig-req" },
      }

      -- All 7 incomplete subsets (unset) + 3 empty-string cases
      local cases = {}
      for mask = 0, 6 do
        local env = {}
        local label = {}
        for i = 1, 3 do
          local bit = 1 << (i - 1)
          if (mask & bit) ~= 0 then
            env[req[i][1]] = req[i][2]
            label[#label + 1] = req[i][1] .. "=set"
          else
            env[req[i][1]] = false
            label[#label + 1] = req[i][1] .. "=unset"
          end
        end
        cases[#cases + 1] = { name = table.concat(label, ","), env = env }
      end

      for i = 1, 3 do
        local env = {
          WAYLAND_DISPLAY = "wayland-1",
          XDG_CURRENT_DESKTOP = "Hyprland",
          HYPRLAND_INSTANCE_SIGNATURE = "sig-req",
        }
        env[req[i][1]] = ""
        cases[#cases + 1] = { name = req[i][1] .. "=empty", env = env }
      end

      for _, c in ipairs(cases) do
        sb:clear_calls()
        local r = sb:run_bin("bin/kaze-session", { "start" }, c.env)
        assert_eq(r.code, 1, "start must exit 1 when " .. c.name)
        assert_eq(#sb:calls(), 0, "start must not touch systemd/D-Bus when " .. c.name .. ", got:" .. format_calls(sb:calls()))
      end
    end)
  end)

  test("bb.session.start_ownership_and_idempotency", function()
    with_sandbox(function(sb)
      sb:install_systemctl_stub()
      sb:install_dbus_stub()

      local base_env = {
        WAYLAND_DISPLAY = "wayland-1",
        XDG_CURRENT_DESKTOP = "Hyprland",
        HYPRLAND_INSTANCE_SIGNATURE = "sig-alpha",
      }

      -- 1) active & matching signature -> idempotent exit 0, no restart/start
      for _, state in ipairs({ "active", "activating" }) do
        sb:clear_calls()
        local env = {
          WAYLAND_DISPLAY = base_env.WAYLAND_DISPLAY,
          XDG_CURRENT_DESKTOP = base_env.XDG_CURRENT_DESKTOP,
          HYPRLAND_INSTANCE_SIGNATURE = base_env.HYPRLAND_INSTANCE_SIGNATURE,
          TEST_TARGET_STATE = state,
          TEST_SYSTEMD_ENV = "FOO=bar\nHYPRLAND_INSTANCE_SIGNATURE=sig-alpha\nWAYLAND_DISPLAY=wayland-1",
        }
        local r = sb:run_bin("bin/kaze-session", { "start" }, env)
        assert_eq(r.code, 0, "matching " .. state .. " session must be idempotent exit 0, stderr=" .. r.stderr)
        local calls = sb:calls()
        assert_true(
          has_call(calls, "systemctl", { "--user", "show", "-p", "ActiveState", "--value", "kaze-session.target" }) ~= nil,
          "must query ActiveState of kaze-session.target:" .. format_calls(calls)
        )
        assert_true(
          has_call(calls, "systemctl", { "--user", "show-environment" }) ~= nil,
          "must query systemctl --user show-environment:" .. format_calls(calls)
        )
        for _, sc in ipairs(find_calls(calls, "systemctl")) do
          assert_true(not list_contains(sc.args, "start"), "idempotent start must NOT start target again")
          assert_true(not list_contains(sc.args, "restart"), "idempotent start must NOT restart target")
        end
        assert_eq(#find_calls(calls, "dbus-update-activation-environment"), 0, "idempotent start should not re-export D-Bus")
      end

      -- 2) active/activating & different (or absent) signature -> exit 1 ("already belongs to another session")
      local foreign_cases = {
        { state = "active", sysenv = "HYPRLAND_INSTANCE_SIGNATURE=sig-other" },
        { state = "activating", sysenv = "HYPRLAND_INSTANCE_SIGNATURE=sig-other" },
        { state = "active", sysenv = "WAYLAND_DISPLAY=wayland-9" },
      }
      for _, fc in ipairs(foreign_cases) do
        sb:clear_calls()
        local r = sb:run_bin("bin/kaze-session", { "start" }, {
          WAYLAND_DISPLAY = base_env.WAYLAND_DISPLAY,
          XDG_CURRENT_DESKTOP = base_env.XDG_CURRENT_DESKTOP,
          HYPRLAND_INSTANCE_SIGNATURE = base_env.HYPRLAND_INSTANCE_SIGNATURE,
          TEST_TARGET_STATE = fc.state,
          TEST_SYSTEMD_ENV = fc.sysenv,
        })
        assert_eq(r.code, 1, "foreign " .. fc.state .. " session must fail exit 1")
        assert_contains(r.stderr .. r.stdout, "already belongs to another session", "must report foreign ownership")
        local calls = sb:calls()
        for _, sc in ipairs(find_calls(calls, "systemctl")) do
          assert_true(not list_contains(sc.args, "start"), "must NOT start target on foreign session conflict")
        end
        assert_eq(#find_calls(calls, "dbus-update-activation-environment"), 0, "must NOT mutate D-Bus on foreign session conflict")
      end
    end)
  end)

  test("bb.session.start_env_render_and_profile_matrix", function()
    with_sandbox(function(sb)
      sb:install_systemctl_stub()
      sb:install_dbus_stub()

      local session_env_path = sb.runtime .. "/kaze/session.env"
      local profile_path = sb.config .. "/kaze/profile"
      local user_lua_path = sb.config .. "/hypr/user.lua"

      local function run_start(extra_env)
        sb:clear_calls()
        local env = {
          WAYLAND_DISPLAY = "wayland-1",
          XDG_CURRENT_DESKTOP = "Hyprland",
          HYPRLAND_INSTANCE_SIGNATURE = "sig-matrix",
          TEST_TARGET_STATE = "inactive",
        }
        if extra_env then
          for k, v in pairs(extra_env) do
            env[k] = v
          end
        end
        local r = sb:run_bin("bin/kaze-session", { "start" }, env)
        assert_eq(r.code, 0, "kaze-session start failed: " .. r.stderr)
        local raw = read_file(session_env_path)
        assert_true(raw ~= nil and raw ~= "", "session.env must be rendered at " .. session_env_path)
        return parse_env_file(raw), sb:calls(), raw
      end

      -- Case 1: minimal (default), non-UTF-8 locale normalized for UTF-8 LC_CTYPE & cleared non-UTF-8 LC_ALL, valid XDG_SESSION_ID
      local env1, calls1 = run_start({ LANG = "C", LC_ALL = "POSIX", XDG_SESSION_ID = "c7" })
      assert_eq(stat_mode(sb.runtime .. "/kaze"), "0700", "runtime/kaze dir must have mode 0700")
      assert_eq(env1.XDG_CONFIG_HOME, sb.config, "XDG_CONFIG_HOME")
      assert_eq(env1.XDG_DATA_HOME, sb.data, "XDG_DATA_HOME")
      assert_eq(env1.XDG_CACHE_HOME, sb.cache, "XDG_CACHE_HOME")
      assert_true(env1.PATH ~= nil and env1.PATH ~= "", "PATH must be rendered")
      assert_true(env1.LANG ~= nil, "LANG key must be present in session.env")
      assert_true(env1.LC_ALL ~= nil, "LC_ALL key must be present in session.env")
      assert_eq(env1.LC_ALL, "", "non-UTF-8 LC_ALL=POSIX must be cleared so it cannot break UTF-8")
      assert_true(env1.LC_CTYPE ~= nil and env1.LC_CTYPE:lower():find("utf", 1, true) ~= nil, "LC_CTYPE must be UTF-8, got: " .. tostring(env1.LC_CTYPE))
      assert_true(env1.XCURSOR_THEME ~= nil and env1.XCURSOR_THEME ~= "", "XCURSOR_THEME must be set")
      assert_true(env1.XCURSOR_SIZE ~= nil and env1.XCURSOR_SIZE:match("^%d+$") ~= nil, "XCURSOR_SIZE must be numeric")
      assert_eq(env1.KAZE_PROFILE, "minimal", "default profile must be minimal")
      assert_eq(env1.KAZE_ENABLE_FCITX5, "0", "minimal profile disables fcitx5")
      assert_eq(env1.XMODIFIERS, nil, "minimal profile must NOT export XMODIFIERS")
      assert_eq(env1.KAZE_SESSION_ID, "c7", "valid XDG_SESSION_ID must be exported as KAZE_SESSION_ID")

      -- Case 1b: UTF-8 LANG and UTF-8 LC_ALL are preserved cleanly
      local env1b = run_start({ LANG = "en_US.UTF-8" })
      assert_eq(env1b.LANG, "en_US.UTF-8", "UTF-8 LANG preserved")
      assert_eq(env1b.LC_CTYPE, "en_US.UTF-8", "UTF-8 LC_CTYPE inherits UTF-8 LANG")
      local env1c = run_start({ LC_ALL = "en_US.UTF-8" })
      assert_eq(env1c.LC_ALL, "en_US.UTF-8", "UTF-8 LC_ALL preserved")
      assert_eq(env1c.LC_CTYPE, "en_US.UTF-8", "UTF-8 LC_CTYPE inherits UTF-8 LC_ALL")

      -- Verify D-Bus activation update and systemctl start order
      local dbus_idx = has_call(calls1, "dbus-update-activation-environment", {
        "--systemd", "WAYLAND_DISPLAY", "XDG_CURRENT_DESKTOP", "HYPRLAND_INSTANCE_SIGNATURE",
      })
      local start_idx = has_call(calls1, "systemctl", { "--user", "start", "kaze-session.target" })
      assert_true(dbus_idx ~= nil, "must call dbus-update-activation-environment --systemd ...:" .. format_calls(calls1))
      assert_true(start_idx ~= nil, "must call systemctl --user start kaze-session.target:" .. format_calls(calls1))
      assert_true(dbus_idx < start_idx, "dbus-update-activation-environment must precede systemctl start")

      -- Case 2: invalid XDG_SESSION_ID omitted, full profile enables fcitx5 + XMODIFIERS
      mkdir_p(sb.config .. "/kaze")
      write_file(profile_path, "full\n")
      local env2 = run_start({ XDG_SESSION_ID = "bad;id space" })
      assert_eq(env2.KAZE_PROFILE, "full", "profile file should select full")
      assert_eq(env2.KAZE_ENABLE_FCITX5, "1", "full profile enables fcitx5")
      assert_eq(env2.XMODIFIERS, "@im=fcitx", "full profile sets XMODIFIERS=@im=fcitx")
      assert_eq(env2.KAZE_SESSION_ID, nil, "invalid XDG_SESSION_ID must not be exported")

      -- Case 3: user.lua with fcitx5 = false on full profile
      mkdir_p(sb.config .. "/hypr")
      write_file(user_lua_path, "return { fcitx5 = false }\n")
      local env3 = run_start({})
      assert_eq(env3.KAZE_PROFILE, "full", "profile remains full")
      assert_eq(env3.KAZE_ENABLE_FCITX5, "0", "user.lua fcitx5=false must disable fcitx5 on full")
      assert_eq(env3.XMODIFIERS, nil, "XMODIFIERS must not be exported when fcitx5 disabled")

      -- Case 4: user.lua with drm_devices & prefer_mesa_egl
      write_file(user_lua_path, 'return { drm_devices = "/dev/dri/card1", prefer_mesa_egl = true }\n')
      local env4 = run_start({})
      assert_eq(env4.AQ_DRM_DEVICES, "/dev/dri/card1", "drm_devices must export AQ_DRM_DEVICES")
      assert_eq(
        env4.__EGL_VENDOR_LIBRARY_FILENAMES,
        "/usr/share/glvnd/egl_vendor.d/50_mesa.json",
        "prefer_mesa_egl must export mesa EGL vendor filename"
      )
      assert_eq(env4.KAZE_ENABLE_FCITX5, "1", "fcitx5 returns to full default")

      -- Case 5: user.lua with invalid Lua syntax, runtime error, or non-table return -> graceful fallback
      os.remove(profile_path)
      local bad_user_luas = {
        { label = "syntax error", code = "return { syntax === broken ((((\n" },
        { label = "runtime error", code = 'error("kaboom")\n' },
        { label = "non-table return", code = "return 42\n" },
      }
      for _, bad in ipairs(bad_user_luas) do
        write_file(user_lua_path, bad.code)
        local env5 = run_start({})
        assert_eq(env5.KAZE_PROFILE, "minimal", bad.label .. ": falls back cleanly")
        assert_eq(env5.KAZE_ENABLE_FCITX5, "0", bad.label .. ": uses minimal fcitx5 default")
        assert_eq(env5.AQ_DRM_DEVICES, nil, bad.label .. ": does not leak AQ_DRM_DEVICES")
        assert_eq(env5.__EGL_VENDOR_LIBRARY_FILENAMES, nil, bad.label .. ": does not leak EGL override")
      end
    end)
  end)

  test("bb.session.start_rollback_on_target_failure", function()
    with_sandbox(function(sb)
      sb:install_systemctl_stub()
      sb:install_dbus_stub()

      -- Case 1: systemctl start kaze-session.target fails -> exit 1 + rollback exported vars
      sb:clear_calls()
      local r = sb:run_bin("bin/kaze-session", { "start" }, {
        WAYLAND_DISPLAY = "wayland-1",
        XDG_CURRENT_DESKTOP = "Hyprland",
        HYPRLAND_INSTANCE_SIGNATURE = "sig-fail",
        TEST_TARGET_STATE = "inactive",
        TEST_START_TARGET_EXIT = "1",
      })
      assert_eq(r.code, 1, "start must exit 1 when kaze-session.target fails to start")
      local calls = sb:calls()
      local start_idx = has_call(calls, "systemctl", { "--user", "start", "kaze-session.target" })
      assert_true(start_idx ~= nil, "should have attempted systemctl start:" .. format_calls(calls))

      local cleared_dbus = false
      local unset_systemd = false
      for i = start_idx + 1, #calls do
        local c = calls[i]
        if c.cmd == "dbus-update-activation-environment" then
          if list_contains(c.args, "WAYLAND_DISPLAY=")
            and list_contains(c.args, "XDG_CURRENT_DESKTOP=")
            and list_contains(c.args, "HYPRLAND_INSTANCE_SIGNATURE=")
          then
            cleared_dbus = true
          end
        elseif c.cmd == "systemctl" then
          if list_contains(c.args, "unset-environment")
            and list_contains(c.args, "WAYLAND_DISPLAY")
            and list_contains(c.args, "XDG_CURRENT_DESKTOP")
            and list_contains(c.args, "HYPRLAND_INSTANCE_SIGNATURE")
          then
            unset_systemd = true
          end
        end
      end
      assert_true(
        cleared_dbus or unset_systemd,
        "must roll back activation vars after target start failure, calls:" .. format_calls(calls)
      )
      assert_true(
        cleared_dbus,
        "rollback should clear D-Bus activation vars (WAYLAND_DISPLAY= ...), calls:" .. format_calls(calls)
      )
      assert_true(
        unset_systemd,
        "rollback should unset systemd user environment vars, calls:" .. format_calls(calls)
      )

      -- Case 2: dbus-update-activation-environment fails -> exit 1, does NOT start target
      sb:clear_calls()
      local r2 = sb:run_bin("bin/kaze-session", { "start" }, {
        WAYLAND_DISPLAY = "wayland-1",
        XDG_CURRENT_DESKTOP = "Hyprland",
        HYPRLAND_INSTANCE_SIGNATURE = "sig-dbus-fail",
        TEST_TARGET_STATE = "inactive",
        TEST_DBUS_EXIT = "1",
      })
      assert_eq(r2.code, 1, "start must exit 1 when dbus-update-activation-environment fails")
      assert_true(
        has_call(sb:calls(), "systemctl", { "--user", "start", "kaze-session.target" }) == nil,
        "must not start target if dbus export failed"
      )
    end)
  end)

  test("bb.session.stop_ownership_and_cleanup", function()
    with_sandbox(function(sb)
      sb:install_systemctl_stub()
      sb:install_dbus_stub()

      local local_bin = sb.home .. "/.local/bin"
      sb:add_stub("kaze-display", "exit 0\n", local_bin)

      -- Case 1: Not owned (different signature or missing signature) -> safe no-op exit 0
      local non_owner_cases = {
        { sig = "sig-mine", sysenv = "HYPRLAND_INSTANCE_SIGNATURE=sig-other" },
        { sig = false, sysenv = "HYPRLAND_INSTANCE_SIGNATURE=sig-other" },
        { sig = "sig-mine", sysenv = "WAYLAND_DISPLAY=wayland-1" },
      }
      for _, nc in ipairs(non_owner_cases) do
        sb:clear_calls()
        local r = sb:run_bin("bin/kaze-session", { "stop" }, {
          HYPRLAND_INSTANCE_SIGNATURE = nc.sig,
          TEST_SYSTEMD_ENV = nc.sysenv,
          TEST_RECORD_STATE = "active",
        })
        assert_eq(r.code, 0, "stop for non-owned session must be safe no-op exit 0")
        local calls = sb:calls()
        assert_eq(#find_calls(calls, "kaze-display"), 0, "non-owner stop must not call kaze-display")
        assert_eq(#find_calls(calls, "dbus-update-activation-environment"), 0, "non-owner stop must not clear D-Bus")
        for _, sc in ipairs(find_calls(calls, "systemctl")) do
          assert_true(not list_contains(sc.args, "stop"), "non-owner stop must not stop units")
          assert_true(not list_contains(sc.args, "unset-environment"), "non-owner stop must not unset env")
        end
      end

      -- Case 2: Owned + kaze-record.service active -> full cleanup via $HOME/.local/bin/kaze-display
      sb:clear_calls()
      local r2 = sb:run_bin("bin/kaze-session", { "stop" }, {
        HYPRLAND_INSTANCE_SIGNATURE = "sig-owned",
        TEST_SYSTEMD_ENV = "HYPRLAND_INSTANCE_SIGNATURE=sig-owned",
        TEST_RECORD_STATE = "active",
      })
      assert_eq(r2.code, 0, "owned stop must exit 0, stderr=" .. r2.stderr)
      local calls2 = sb:calls()
      assert_true(
        has_call(calls2, "kaze-display", { "cleanup" }) ~= nil,
        "owned stop must invoke kaze-display cleanup from ~/.local/bin:" .. format_calls(calls2)
      )
      assert_true(
        has_call(calls2, "systemctl", { "--user", "stop", "kaze-record.service" }) ~= nil,
        "owned stop must stop active kaze-record.service:" .. format_calls(calls2)
      )
      assert_true(
        has_call(calls2, "systemctl", { "--user", "stop", "kaze-session.target" }) ~= nil,
        "owned stop must stop kaze-session.target:" .. format_calls(calls2)
      )
      local dbus_clear = find_calls(calls2, "dbus-update-activation-environment")
      assert_true(#dbus_clear >= 1, "owned stop must clear D-Bus vars:" .. format_calls(calls2))
      assert_true(
        list_contains(dbus_clear[1].args, "WAYLAND_DISPLAY=") ~= nil
          and list_contains(dbus_clear[1].args, "XDG_CURRENT_DESKTOP=") ~= nil
          and list_contains(dbus_clear[1].args, "HYPRLAND_INSTANCE_SIGNATURE=") ~= nil,
        "owned stop must clear WAYLAND_DISPLAY=, XDG_CURRENT_DESKTOP=, HYPRLAND_INSTANCE_SIGNATURE=:" .. format_calls(calls2)
      )
      assert_true(
        has_call(calls2, "systemctl", {
          "--user", "unset-environment", "WAYLAND_DISPLAY", "XDG_CURRENT_DESKTOP", "HYPRLAND_INSTANCE_SIGNATURE",
        }) ~= nil,
        "owned stop must unset systemd env vars:" .. format_calls(calls2)
      )

      -- Case 3: Owned + kaze-record.service inactive/failed -> does NOT stop kaze-record.service;
      -- also verify kaze-display fallback via PATH when ~/.local/bin/kaze-display is absent
      sb:remove_stub("kaze-display", local_bin)
      sb:add_stub("kaze-display", "exit 0\n") -- in PATH (stub_bin)
      for _, rec_state in ipairs({ "inactive", "failed" }) do
        sb:clear_calls()
        local r3 = sb:run_bin("bin/kaze-session", { "stop" }, {
          HYPRLAND_INSTANCE_SIGNATURE = "sig-owned",
          TEST_SYSTEMD_ENV = "HYPRLAND_INSTANCE_SIGNATURE=sig-owned",
          TEST_RECORD_STATE = rec_state,
        })
        assert_eq(r3.code, 0, "owned stop with record=" .. rec_state .. " must exit 0")
        local calls3 = sb:calls()
        assert_true(
          has_call(calls3, "kaze-display", { "cleanup" }) ~= nil,
          "must invoke kaze-display cleanup from PATH:" .. format_calls(calls3)
        )
        assert_true(
          has_call(calls3, "systemctl", { "--user", "stop", "kaze-record.service" }) == nil,
          "must NOT stop kaze-record.service when state=" .. rec_state .. ":" .. format_calls(calls3)
        )
        assert_true(
          has_call(calls3, "systemctl", { "--user", "stop", "kaze-session.target" }) ~= nil,
          "must still stop kaze-session.target"
        )
      end

      -- Case 4: Owned + kaze-record.service activating + kaze-display completely absent -> still stops record & target
      sb:remove_stub("kaze-display")
      sb:clear_calls()
      local r4 = sb:run_bin("bin/kaze-session", { "stop" }, {
        HYPRLAND_INSTANCE_SIGNATURE = "sig-owned",
        TEST_SYSTEMD_ENV = "HYPRLAND_INSTANCE_SIGNATURE=sig-owned",
        TEST_RECORD_STATE = "activating",
      })
      assert_eq(r4.code, 0, "owned stop without kaze-display must exit 0, stderr=" .. r4.stderr)
      local calls4 = sb:calls()
      assert_true(
        has_call(calls4, "systemctl", { "--user", "stop", "kaze-record.service" }) ~= nil,
        "must stop activating kaze-record.service:" .. format_calls(calls4)
      )
      assert_true(
        has_call(calls4, "systemctl", { "--user", "stop", "kaze-session.target" }) ~= nil,
        "must stop kaze-session.target even without kaze-display"
      )
    end)
  end)

  test("bb.session.lock_fallback_chain", function()
    with_sandbox(function(sb)
      sb:add_stub("hyprlock", [[
exit "${TEST_HYPRLOCK_EXIT:-0}"
]])
      sb:add_stub("loginctl", [[
case "${1:-}" in
  show-user)
    printf '%s\n' "${TEST_DISPLAY_SESSION:-}"
    exit "${TEST_SHOW_USER_EXIT:-0}"
    ;;
  lock-session)
    exit "${TEST_LOCK_SESSION_EXIT:-0}"
    ;;
esac
exit 1
]])

      -- Case 1: hyprlock succeeds -> does NOT call loginctl
      sb:clear_calls()
      local r1 = sb:run_bin("bin/kaze-session", { "lock" }, { TEST_HYPRLOCK_EXIT = "0" })
      assert_eq(r1.code, 0, "lock via hyprlock should exit 0")
      local c1 = sb:calls()
      assert_true(has_call(c1, "hyprlock", {}) ~= nil, "must call hyprlock:" .. format_calls(c1))
      assert_eq(#find_calls(c1, "loginctl"), 0, "must not call loginctl when hyprlock succeeds")

      -- Case 2: hyprlock fails -> falls back to loginctl show-user <uid> -p Display --value -> lock-session <id>
      sb:clear_calls()
      local r2 = sb:run_bin("bin/kaze-session", { "lock" }, {
        TEST_HYPRLOCK_EXIT = "1",
        TEST_DISPLAY_SESSION = "c4",
        TEST_LOCK_SESSION_EXIT = "0",
      })
      assert_eq(r2.code, 0, "lock fallback via loginctl should exit 0, stderr=" .. r2.stderr)
      local c2 = sb:calls()
      assert_true(has_call(c2, "hyprlock", {}) ~= nil, "should try hyprlock first")
      assert_true(
        has_call(c2, "loginctl", { "show-user", HOST_UID, "-p", "Display", "--value" }) ~= nil,
        "must query loginctl show-user <uid> -p Display --value:" .. format_calls(c2)
      )
      assert_true(
        has_call(c2, "loginctl", { "lock-session", "c4" }) ~= nil,
        "must invoke loginctl lock-session c4:" .. format_calls(c2)
      )

      -- Case 3: hyprlock missing -> falls back to loginctl
      sb:remove_stub("hyprlock")
      sb:clear_calls()
      local r3 = sb:run_bin("bin/kaze-session", { "lock" }, {
        TEST_DISPLAY_SESSION = "9",
        TEST_LOCK_SESSION_EXIT = "0",
      })
      assert_eq(r3.code, 0, "lock fallback when hyprlock missing should exit 0")
      local c3 = sb:calls()
      assert_true(has_call(c3, "loginctl", { "lock-session", "9" }) ~= nil, "must lock session 9:" .. format_calls(c3))

      -- Case 4: hyprlock missing & loginctl returns empty display -> exit 1
      sb:clear_calls()
      local r4 = sb:run_bin("bin/kaze-session", { "lock" }, { TEST_DISPLAY_SESSION = "" })
      assert_eq(r4.code, 1, "lock must fail exit 1 when Display session is empty")
      for _, lc in ipairs(find_calls(sb:calls(), "loginctl")) do
        assert_true(lc.args[1] ~= "lock-session", "must not invoke loginctl lock-session with empty session id")
      end

      -- Case 5: hyprlock missing & loginctl lock-session fails -> exit 1
      sb:clear_calls()
      local r5 = sb:run_bin("bin/kaze-session", { "lock" }, {
        TEST_DISPLAY_SESSION = "c4",
        TEST_LOCK_SESSION_EXIT = "1",
      })
      assert_eq(r5.code, 1, "lock must fail exit 1 when loginctl lock-session fails")

      -- Case 6: BOTH noctalia and loginctl missing -> exit 1
      sb:remove_stub("loginctl")
      sb:clear_calls()
      local r6 = sb:run_bin("bin/kaze-session", { "lock" })
      assert_eq(r6.code, 1, "lock must fail exit 1 when both noctalia and loginctl are missing")
    end)
  end)

  test("bb.session.wake_displays_lid_matrix", function()
    with_sandbox(function(sb)
      sb:install_hyprctl_stub()
      sb:add_stub("busctl", [==[
if [[ -n "${TEST_BUSCTL_OUT:-}" ]]; then
  printf '%s\n' "${TEST_BUSCTL_OUT}"
fi
exit "${TEST_BUSCTL_EXIT:-0}"
]==])

      local expected_busctl_args = {
        "--system", "--timeout=1s", "get-property",
        "org.freedesktop.login1", "/org/freedesktop/login1",
        "org.freedesktop.login1.Manager", "LidClosed",
      }
      local expected_dpms_all = { "dispatch", 'hl.dsp.dpms({ action = "on" })' }

      -- Case 1: LidClosed == "b false" -> global dpms on
      sb:clear_calls()
      local r1 = sb:run_bin("bin/kaze-session", { "wake-displays" }, {
        TEST_BUSCTL_OUT = "b false",
        TEST_BUSCTL_EXIT = "0",
      })
      assert_eq(r1.code, 0, "wake-displays (lid open) should exit 0, stderr=" .. r1.stderr)
      local c1 = sb:calls()
      assert_true(has_call(c1, "busctl", expected_busctl_args) ~= nil, "must query LidClosed via busctl:" .. format_calls(c1))
      assert_true(has_call(c1, "hyprctl", expected_dpms_all) ~= nil, "lid open must run global dpms on:" .. format_calls(c1))

      -- Case 2: busctl fails -> global dpms on
      sb:clear_calls()
      local r2 = sb:run_bin("bin/kaze-session", { "wake-displays" }, {
        TEST_BUSCTL_OUT = "",
        TEST_BUSCTL_EXIT = "1",
      })
      assert_eq(r2.code, 0, "wake-displays (busctl error) should exit 0")
      assert_true(has_call(sb:calls(), "hyprctl", expected_dpms_all) ~= nil, "busctl failure must fall back to global dpms on")

      -- Case 3: LidClosed == "b true" -> hyprctl eval skipping internal panels (eDP-*, LVDS-*, DSI-*)
      sb:clear_calls()
      local r3 = sb:run_bin("bin/kaze-session", { "wake-displays" }, {
        TEST_BUSCTL_OUT = "b true",
        TEST_BUSCTL_EXIT = "0",
      })
      assert_eq(r3.code, 0, "wake-displays (lid closed) should exit 0, stderr=" .. r3.stderr)
      local c3 = sb:calls()
      assert_true(has_call(c3, "hyprctl", expected_dpms_all) == nil, "lid closed must NOT wake internal panel via global dpms on")
      local hcalls = find_calls(c3, "hyprctl")
      assert_eq(#hcalls, 1, "lid closed should make 1 hyprctl eval call:" .. format_calls(c3))
      assert_eq(hcalls[1].args[1], "eval", "lid closed must invoke hyprctl eval")
      local eval_code = hcalls[1].args[2] or ""
      assert_true(eval_code ~= "", "hyprctl eval payload must be non-empty")
      local chunk, compile_err = load(eval_code)
      assert_true(chunk ~= nil, "hyprctl eval payload must be valid Lua syntax: " .. tostring(compile_err))
      assert_contains(eval_code, "eDP", "lid-closed eval must filter eDP-*")
      assert_contains(eval_code, "LVDS", "lid-closed eval must filter LVDS-*")
      assert_contains(eval_code, "DSI", "lid-closed eval must filter DSI-*")
      assert_contains(eval_code, "dpms", "lid-closed eval must call dpms")

      -- Case 4: busctl unavailable (not in PATH) -> global dpms on
      sb:remove_stub("busctl")
      sb:clear_calls()
      local r4 = sb:run_bin("bin/kaze-session", { "wake-displays" })
      assert_eq(r4.code, 0, "wake-displays (busctl missing) should exit 0")
      assert_true(has_call(sb:calls(), "hyprctl", expected_dpms_all) ~= nil, "missing busctl must run global dpms on")
    end)
  end)

  -- =========================================================================
  -- 2. bin/kaze-footclient
  -- =========================================================================

  test("bb.footclient.socket_and_missing_configs", function()
    with_sandbox(function(sb)
      sb:install_footclient_stub()

      -- Case 1: XDG_RUNTIME_DIR set, both foot.ini and themes/noctalia missing
      sb:clear_calls()
      local r1 = sb:run_bin("bin/kaze-footclient", {})
      assert_eq(r1.code, 0, "missing foot configs must succeed, stderr=" .. r1.stderr)
      local c1 = find_calls(sb:calls(), "footclient")
      assert_eq(#c1, 1, "must invoke footclient once")
      assert_eq(c1[1].args[1], "-E", "must pass -E")
      assert_eq(c1[1].args[2], "--server-socket=" .. sb.runtime .. "/foot.sock", "must pass runtime foot.sock")
      assert_eq(#c1[1].args, 2, "no -o flags when configs missing")

      -- Case 2: Only foot.ini present (missing themes/noctalia)
      mkdir_p(sb.config .. "/foot")
      write_file(sb.config .. "/foot/foot.ini", "[main]\nfont=monospace:size=10\n")
      sb:clear_calls()
      local r2 = sb:run_bin("bin/kaze-footclient", {})
      assert_eq(r2.code, 0, "missing noctalia theme alone must succeed")
      local c2 = find_calls(sb:calls(), "footclient")
      assert_eq(#c2, 1, "must invoke footclient once")
      assert_true(list_contains(c2[1].args, "main.font=monospace:size=10") ~= nil, "must apply foot.ini font")

      -- Case 3: Only themes/noctalia present (missing foot.ini)
      os.remove(sb.config .. "/foot/foot.ini")
      mkdir_p(sb.config .. "/foot/themes")
      write_file(sb.config .. "/foot/themes/noctalia", "[colors-dark]\nbackground=101010\n")
      sb:clear_calls()
      local r3 = sb:run_bin("bin/kaze-footclient", {})
      assert_eq(r3.code, 0, "missing foot.ini alone must succeed")
      local c3 = find_calls(sb:calls(), "footclient")
      assert_eq(#c3, 1, "must invoke footclient once")
      assert_true(list_contains(c3[1].args, "colors-dark.background=101010") ~= nil, "must apply noctalia theme")

      -- Case 4: Empty/comment-only configs + XDG_RUNTIME_DIR unset or empty -> no broken --server-socket
      write_file(sb.config .. "/foot/foot.ini", "\n# comment only\n   \n")
      write_file(sb.config .. "/foot/themes/noctalia", "# empty theme\n")
      for _, rt_val in ipairs({ false, "" }) do
        sb:clear_calls()
        local r4 = sb:run_bin("bin/kaze-footclient", { "-N" }, { XDG_RUNTIME_DIR = rt_val })
        assert_eq(r4.code, 0, "unset/empty XDG_RUNTIME_DIR must still succeed")
        local c4 = find_calls(sb:calls(), "footclient")
        assert_eq(#c4, 1, "must invoke footclient once")
        assert_eq(c4[1].args[1], "-E", "must still pass -E")
        for _, a in ipairs(c4[1].args) do
          assert_true(a:sub(1, 16) ~= "--server-socket=", "must not pass --server-socket when XDG_RUNTIME_DIR unset/empty: " .. a)
          assert_true(a ~= "-o", "comment-only configs must not emit -o overrides")
        end
        assert_true(list_contains(c4[1].args, "-N") ~= nil, "must still forward -N")
      end
    end)
  end)

  test("bb.footclient.ini_and_theme_override_parsing", function()
    with_sandbox(function(sb)
      sb:install_footclient_stub()
      mkdir_p(sb.config .. "/foot/themes")

      write_file(sb.config .. "/foot/foot.ini", table.concat({
        "# Top-level comment",
        "",
        "[main]",
        "include=themes/noctalia",
        "font=JetBrainsMono Nerd Font:size=11:dpi-aware=yes",
        "pad=12x12",
        "shell=/bin/zsh",
        "term=foot",
        "# font=commented-out-font",
        "",
        "[scrollback]",
        "lines=10000",
        "multiplier=3.0",
        "",
        "[cursor]",
        "style=beam",
        "",
        "[colors-dark]",
        "alpha=0.95",
        "background=11111b",
        "# foreground=ignored-comment",
        "",
        "[colors-light]",
        "background=eff1f5",
      }, "\n") .. "\n")

      write_file(sb.config .. "/foot/themes/noctalia", table.concat({
        "# Noctalia generated colors",
        "[bell]",
        "urgent=yes",
        "",
        "[colors-dark]",
        "foreground=cdd6f4",
        "regular0=45475a",
        "bright1=f38ba8",
        "",
        "[colors-light]",
        "foreground=4c4f69",
        "regular2=40a02b",
      }, "\n") .. "\n")

      sb:clear_calls()
      local r = sb:run_bin("bin/kaze-footclient", { "-e", "true" })
      assert_eq(r.code, 0, "kaze-footclient should exit 0, stderr=" .. r.stderr)
      local calls = find_calls(sb:calls(), "footclient")
      assert_eq(#calls, 1, "must invoke footclient once")
      local argv = calls[1].args

      -- Collect all -o <override> flags (supports both `-o k=v` and `-ok=v`)
      local overrides = {}
      local overrides_set = {}
      local last_override_idx = 0
      local i = 1
      while i <= #argv do
        if argv[i] == "-o" and argv[i + 1] then
          overrides[#overrides + 1] = argv[i + 1]
          overrides_set[argv[i + 1]] = true
          last_override_idx = i + 1
          i = i + 2
        elseif argv[i]:sub(1, 2) == "-o" and #argv[i] > 2 then
          local val = argv[i]:sub(3)
          overrides[#overrides + 1] = val
          overrides_set[val] = true
          last_override_idx = i
          i = i + 1
        else
          i = i + 1
        end
      end

      local expected_overrides = {
        "main.font=JetBrainsMono Nerd Font:size=11:dpi-aware=yes",
        "colors-dark.alpha=0.95",
        "colors-dark.background=11111b",
        "colors-dark.foreground=cdd6f4",
        "colors-dark.regular0=45475a",
        "colors-dark.bright1=f38ba8",
        "colors-light.background=eff1f5",
        "colors-light.foreground=4c4f69",
        "colors-light.regular2=40a02b",
      }
      for _, exp in ipairs(expected_overrides) do
        assert_true(overrides_set[exp], "missing expected -o override: " .. exp .. " (got: " .. table.concat(overrides, ", ") .. ")")
      end
      assert_eq(#overrides, #expected_overrides, "unexpected extra -o overrides: " .. table.concat(overrides, ", "))

      -- Explicitly verify forbidden sections/keys were ignored
      local all_joined = table.concat(argv, "\n")
      for _, forbidden in ipairs({
        "main.include", "main.pad", "main.shell", "main.term",
        "scrollback.", "cursor.", "bell.", "commented-out-font", "ignored-comment",
      }) do
        assert_true(not all_joined:find(forbidden, 1, true), "must ignore " .. forbidden .. " in foot overrides")
      end

      -- User args `-e true` must come strictly AFTER all overrides
      local e_idx = list_contains(argv, "-e")
      assert_true(e_idx ~= nil and e_idx > last_override_idx, "user args must appear after -o overrides")
      assert_eq(argv[e_idx + 1], "true", "user arg after -e preserved")
    end)
  end)

  test("bb.footclient.arg_forwarding_adversarial", function()
    with_sandbox(function(sb)
      sb:install_footclient_stub()
      mkdir_p(sb.config .. "/foot")
      write_file(sb.config .. "/foot/foot.ini", "[colors-dark]\nbackground=000000\n")

      local tricky_args = {
        "-N",
        "-o", "main.locked-title=yes",
        "-a", "kaze-tui",
        "-T", "Wi-Fi (nmtui) & \"Quotes\" 'Single'",
        "-e", "sh", "-c", "printf '%s\\n' \"$HOME\" `uname` *; echo 'a  b'",
        "--custom-flag=x y=z",
        "",
      }

      sb:clear_calls()
      local r = sb:run_bin("bin/kaze-footclient", tricky_args)
      assert_eq(r.code, 0, "forwarding adversarial args failed: " .. r.stderr)
      local calls = find_calls(sb:calls(), "footclient")
      assert_eq(#calls, 1, "must invoke footclient once")
      local argv = calls[1].args

      -- Verify prefix contains -E, --server-socket=..., and -o colors-dark.background=000000
      assert_eq(argv[1], "-E", "prefix arg 1 must be -E")
      assert_eq(argv[2], "--server-socket=" .. sb.runtime .. "/foot.sock", "prefix arg 2 must be server socket")

      -- Tail of argv must match tricky_args byte-for-byte
      local offset = #argv - #tricky_args
      assert_true(offset >= 3, "overrides must precede forwarded args")
      for idx = 1, #tricky_args do
        assert_eq(
          argv[offset + idx],
          tricky_args[idx],
          string.format("forwarded arg #%d corrupted", idx)
        )
      end
    end)
  end)

  test("bb.footclient.exit_code_propagation_bruteforce", function()
    with_sandbox(function(sb)
      sb:install_footclient_stub()

      local codes = { 0, 1, 2, 13, 37, 42, 126, 127, 255 }
      for _, code in ipairs(codes) do
        local r = sb:run_bin("bin/kaze-footclient", { "-e", "dummy" }, {
          TEST_FOOT_EXIT = tostring(code),
        })
        assert_eq(r.code, code, "kaze-footclient must propagate exact exit code " .. tostring(code))
      end
    end)
  end)

  -- =========================================================================
  -- 3. bin/kaze-tui
  -- =========================================================================

  test("bb.tui.cli_validation", function()
    with_sandbox(function(sb)
      sb:install_hyprctl_stub()
      sb:install_footclient_stub()
      sb:add_passthrough_wrapper("kaze-footclient", abs_repo .. "/bin/kaze-footclient")
      sb:add_stub("btop", "exit 0\n")

      -- -h and --help -> exit 0
      for _, flag in ipairs({ "-h", "--help" }) do
        sb:clear_calls()
        local r = sb:run_bin("bin/kaze-tui", { flag }, { HYPRLAND_INSTANCE_SIGNATURE = "sig-tui" })
        assert_eq(r.code, 0, "kaze-tui " .. flag .. " must exit 0")
        assert_true((r.stdout .. r.stderr) ~= "", "kaze-tui help must print usage")
        assert_eq(#sb:calls(), 0, "help must not invoke hyprctl or footclient")
      end

      -- >1 args -> exit 2
      local too_many = {
        { "sysmon", "extra" },
        { "wifi", "a", "b" },
        { "bluetooth", "extra" },
        { "audio", "extra" },
        { "mirror", "--tui" },
        { "bogus", "extra" },
      }
      for _, argv in ipairs(too_many) do
        sb:clear_calls()
        local r = sb:run_bin("bin/kaze-tui", argv, { HYPRLAND_INSTANCE_SIGNATURE = "sig-tui" })
        assert_eq(r.code, 2, "expected exit 2 for >1 args: " .. table.concat(argv, " "))
        assert_eq(#sb:calls(), 0, "must not spawn anything on exit 2")
      end

      -- Missing / invalid mode -> exit 1
      local invalid_modes = {
        {},
        { "invalid" },
        { "network" },
        { "SYSMON" },
        { "" },
        { "--bogus" },
        { "-x" },
      }
      for _, argv in ipairs(invalid_modes) do
        sb:clear_calls()
        local r = sb:run_bin("bin/kaze-tui", argv, { HYPRLAND_INSTANCE_SIGNATURE = "sig-tui" })
        assert_eq(r.code, 1, "expected exit 1 for missing/invalid mode: " .. table.concat(argv, " "))
        assert_eq(#sb:calls(), 0, "must not spawn anything on invalid mode")
      end
    end)
  end)

  test("bb.tui.candidate_fallback_chains_exhaustive", function()
    with_sandbox(function(sb)
      sb:install_hyprctl_stub()
      sb:install_footclient_stub()
      sb:add_passthrough_wrapper("kaze-footclient", abs_repo .. "/bin/kaze-footclient")

      local modes = {
        {
          mode = "sysmon",
          title = "System Monitor",
          app_id = "kaze-tui",
          candidates = { "btop", "htop", "top" },
          extra_args = {},
        },
        {
          mode = "wifi",
          title = "Wi-Fi (nmtui)",
          app_id = "kaze-tui",
          candidates = { "impala", "nmtui" },
          extra_args = {},
        },
        {
          mode = "bluetooth",
          title = "Bluetooth",
          app_id = "kaze-tui",
          candidates = { "bluetui", "bluetoothctl" },
          extra_args = {},
        },
        {
          mode = "audio",
          title = "Audio Mixer",
          app_id = "kaze-tui",
          candidates = { "wiremix", "pulsemixer", "alsamixer" },
          extra_args = {},
        },
        {
          mode = "mirror",
          title = "Mirror Optimizer",
          app_id = "kaze-mirror-tui",
          candidates = { "kaze-mirror" },
          extra_args = { "--tui" },
          bundled_sibling = true,
        },
      }

      local function assert_spawn_args(argv, app_id, title, expected_tool, extra_args, label)
        -- Verify -N, -o main.locked-title=yes, -a <app_id>, -T <title>, <tool> [extra_args...]
        local n_idx = list_contains(argv, "-N")
        assert_true(n_idx ~= nil, label .. ": missing -N in " .. table.concat(argv, " "))

        local has_locked_title = false
        for i = 1, #argv do
          if argv[i] == "-o" and argv[i + 1] == "main.locked-title=yes" then
            has_locked_title = true
          elseif argv[i] == "-omain.locked-title=yes" then
            has_locked_title = true
          end
        end
        assert_true(has_locked_title, label .. ": missing -o main.locked-title=yes")

        local a_idx = list_contains(argv, "-a")
        assert_true(a_idx ~= nil and argv[a_idx + 1] == app_id, label .. ": expected -a " .. app_id)

        local t_idx = list_contains(argv, "-T")
        assert_true(t_idx ~= nil and argv[t_idx + 1] == title, label .. ": expected -T " .. title)

        -- Tool command and optional extra args appear at the end of argv
        local tail_start = #argv - #extra_args
        local tool_arg = argv[tail_start] or ""
        local matches_tool = (tool_arg == expected_tool)
          or (tool_arg:sub(-(#expected_tool + 1)) == "/" .. expected_tool)
        assert_true(
          matches_tool,
          label .. ": expected tool " .. expected_tool .. " at tail, got " .. tostring(tool_arg)
        )
        for j = 1, #extra_args do
          assert_eq(argv[tail_start + j], extra_args[j], label .. ": extra arg #" .. j)
        end
      end

      for _, m in ipairs(modes) do
        -- Install all candidates for this mode
        for _, cand in ipairs(m.candidates) do
          sb:add_stub(cand, "exit 0\n")
        end

        -- Peel off candidates from highest priority to lowest
        for step = 1, #m.candidates do
          local expected = m.candidates[step]
          sb:clear_calls()
          local r = sb:run_bin("bin/kaze-tui", { m.mode }, {
            HYPRLAND_INSTANCE_SIGNATURE = "sig-fallback",
            TEST_HYPR_CLIENTS = "[]",
          })
          assert_eq(r.code, 0, m.mode .. " step " .. step .. " (" .. expected .. ") failed: " .. r.stderr)
          local fcalls = find_calls(sb:calls(), "footclient")
          assert_eq(#fcalls, 1, m.mode .. " step " .. step .. " must spawn footclient once")
          assert_spawn_args(fcalls[1].args, m.app_id, m.title, expected, m.extra_args, m.mode .. "/" .. expected)

          -- Remove current top candidate before next step
          sb:remove_stub(expected)
        end

        -- With NO candidates left in PATH -> exit 1 with clear stderr and NO footclient call
        -- (Skip for bundled_sibling modes like `mirror`, where <repo>/bin/kaze-mirror co-exists with bin/kaze-tui.)
        if not m.bundled_sibling then
          sb:clear_calls()
          local r_none = sb:run_bin("bin/kaze-tui", { m.mode }, {
            HYPRLAND_INSTANCE_SIGNATURE = "sig-fallback",
            TEST_HYPR_CLIENTS = "[]",
          })
          assert_eq(r_none.code, 1, m.mode .. " with no candidates must exit 1")
          assert_true(r_none.stderr ~= "", m.mode .. " with no candidates must print clear stderr message")
          assert_eq(#find_calls(sb:calls(), "footclient"), 0, m.mode .. " with no candidates must not spawn footclient")
        end
      end

      -- Edge case: non-executable higher-priority binary must be skipped in favor of executable fallback
      local non_exec = sb:add_stub("btop", "exit 0\n")
      chmod(non_exec, "0644")
      sb:add_stub("htop", "exit 0\n")
      sb:clear_calls()
      local r_ne = sb:run_bin("bin/kaze-tui", { "sysmon" }, {
        HYPRLAND_INSTANCE_SIGNATURE = "sig-fallback",
        TEST_HYPR_CLIENTS = "[]",
      })
      assert_eq(r_ne.code, 0, "should skip non-executable btop and run htop, stderr=" .. r_ne.stderr)
      local fne = find_calls(sb:calls(), "footclient")
      assert_eq(#fne, 1, "must spawn footclient once")
      assert_spawn_args(fne[1].args, "kaze-tui", "System Monitor", "htop", {}, "sysmon/non-exec-skip")
    end)
  end)

  test("bb.tui.hyprland_toggle_state_machine", function()
    with_sandbox(function(sb)
      sb:install_hyprctl_stub()
      sb:install_footclient_stub()
      sb:add_passthrough_wrapper("kaze-footclient", abs_repo .. "/bin/kaze-footclient")
      sb:add_stub("btop", "exit 0\n")
      sb:add_stub("impala", "exit 0\n")
      sb:add_stub("kaze-mirror", "exit 0\n")

      local targets = {
        { mode = "sysmon", app_id = "kaze-tui", title = "System Monitor", tool = "btop", addr = "0x55aa1111" },
        { mode = "wifi", app_id = "kaze-tui", title = "Wi-Fi (nmtui)", tool = "impala", addr = "0x55aa2222" },
        { mode = "mirror", app_id = "kaze-mirror-tui", title = "Mirror Optimizer", tool = "kaze-mirror", addr = "0x55aa3333" },
      }

      for _, t in ipairs(targets) do
        -- State 1: Only distractors (same class/wrong title, wrong class/same title, unrelated) -> spawn!
        local distractors_json = string.format(
          '[{"address":"0x1001","class":"%s","title":"Other Title"},'
            .. '{"address":"0x1002","class":"foot","title":"%s"},'
            .. '{"address":"0x1003","class":"firefox","title":"ArchWiki"}]',
          t.app_id, t.title
        )
        sb:clear_calls()
        local r1 = sb:run_bin("bin/kaze-tui", { t.mode }, {
          HYPRLAND_INSTANCE_SIGNATURE = "sig-toggle",
          TEST_HYPR_CLIENTS = distractors_json,
          TEST_HYPR_ACTIVE = '{"address":"0x1003","class":"firefox","title":"ArchWiki"}',
        })
        assert_eq(r1.code, 0, t.mode .. " state 1 (no match) must exit 0, stderr=" .. r1.stderr)
        assert_eq(#find_calls(sb:calls(), "footclient"), 1, t.mode .. " state 1 must spawn footclient")
        for _, hc in ipairs(find_calls(sb:calls(), "hyprctl")) do
          assert_true(hc.args[1] ~= "dispatch", t.mode .. " state 1 must not dispatch focus/close")
        end

        -- State 2: Matching window exists, NOT active (test both different active window and empty `{}`) -> focus!
        local with_match_json = string.format(
          '[{"address":"0x1001","class":"%s","title":"Other Title"},'
            .. '{"address":"%s","class":"%s","title":"%s"},'
            .. '{"address":"0x1002","class":"foot","title":"%s"}]',
          t.app_id, t.addr, t.app_id, t.title, t.title
        )
        for _, active_json in ipairs({
          '{"address":"0xdeadbeef","class":"foot","title":"shell"}',
          '{}',
        }) do
          sb:clear_calls()
          local r2 = sb:run_bin("bin/kaze-tui", { t.mode }, {
            HYPRLAND_INSTANCE_SIGNATURE = "sig-toggle",
            TEST_HYPR_CLIENTS = with_match_json,
            TEST_HYPR_ACTIVE = active_json,
          })
          assert_eq(r2.code, 0, t.mode .. " state 2 (focus) must exit 0, stderr=" .. r2.stderr)
          local expected_focus = string.format("hl.dsp.focus({ window = 'address:%s' })", t.addr)
          assert_true(
            has_call(sb:calls(), "hyprctl", { "dispatch", expected_focus }) ~= nil,
            t.mode .. " state 2 must focus " .. t.addr .. ", got:" .. format_calls(sb:calls())
          )
          assert_eq(#find_calls(sb:calls(), "footclient"), 0, t.mode .. " state 2 must NOT spawn new Foot")
        end

        -- State 3: Matching window exists AND IS active -> close!
        local active_match_json = string.format(
          '{"address":"%s","class":"%s","title":"%s"}',
          t.addr, t.app_id, t.title
        )
        sb:clear_calls()
        local r3 = sb:run_bin("bin/kaze-tui", { t.mode }, {
          HYPRLAND_INSTANCE_SIGNATURE = "sig-toggle",
          TEST_HYPR_CLIENTS = with_match_json,
          TEST_HYPR_ACTIVE = active_match_json,
        })
        assert_eq(r3.code, 0, t.mode .. " state 3 (close) must exit 0, stderr=" .. r3.stderr)
        local expected_close = string.format("hl.dsp.window.close({ window = 'address:%s' })", t.addr)
        assert_true(
          has_call(sb:calls(), "hyprctl", { "dispatch", expected_close }) ~= nil,
          t.mode .. " state 3 must close " .. t.addr .. ", got:" .. format_calls(sb:calls())
        )
        assert_eq(#find_calls(sb:calls(), "footclient"), 0, t.mode .. " state 3 must NOT spawn new Foot")
      end

      -- Outside Hyprland (HYPRLAND_INSTANCE_SIGNATURE unset or empty): skips hyprctl and spawns directly
      for _, sig_val in ipairs({ false, "" }) do
        sb:clear_calls()
        local r_no_hypr = sb:run_bin("bin/kaze-tui", { "sysmon" }, {
          HYPRLAND_INSTANCE_SIGNATURE = sig_val,
        })
        assert_eq(r_no_hypr.code, 0, "kaze-tui without HYPRLAND_INSTANCE_SIGNATURE must spawn cleanly")
        assert_eq(#find_calls(sb:calls(), "hyprctl"), 0, "must not invoke hyprctl when HYPRLAND_INSTANCE_SIGNATURE unset/empty")
        assert_eq(#find_calls(sb:calls(), "footclient"), 1, "must spawn footclient directly outside Hyprland")
      end
    end)
  end)

  test("bb.tui.hyprctl_failure_and_malformed_json_resilience", function()
    with_sandbox(function(sb)
      sb:install_hyprctl_stub()
      sb:install_footclient_stub()
      sb:add_passthrough_wrapper("kaze-footclient", abs_repo .. "/bin/kaze-footclient")
      sb:add_stub("wiremix", "exit 0\n")

      -- Case 1: hyprctl -j clients fails (exit 1) -> gracefully spawns footclient
      sb:clear_calls()
      local r1 = sb:run_bin("bin/kaze-tui", { "audio" }, {
        HYPRLAND_INSTANCE_SIGNATURE = "sig-resil",
        TEST_HYPR_CLIENTS = "",
        TEST_HYPR_CLIENTS_EXIT = "1",
      })
      assert_eq(r1.code, 0, "hyprctl clients failure must fall back to spawning, stderr=" .. r1.stderr)
      assert_eq(#find_calls(sb:calls(), "footclient"), 1, "must spawn footclient when hyprctl clients fails")

      -- Case 2: hyprctl -j clients outputs malformed JSON -> gracefully spawns without Lua error
      sb:clear_calls()
      local r2 = sb:run_bin("bin/kaze-tui", { "audio" }, {
        HYPRLAND_INSTANCE_SIGNATURE = "sig-resil",
        TEST_HYPR_CLIENTS = "{{not valid json",
        TEST_HYPR_CLIENTS_EXIT = "0",
      })
      assert_eq(r2.code, 0, "malformed clients JSON must not crash, stderr=" .. r2.stderr)
      assert_eq(#find_calls(sb:calls(), "footclient"), 1, "must spawn footclient on malformed clients JSON")

      -- Case 3: Matching window exists, activewindow fails -> focuses existing window without crashing
      sb:clear_calls()
      local r3 = sb:run_bin("bin/kaze-tui", { "audio" }, {
        HYPRLAND_INSTANCE_SIGNATURE = "sig-resil",
        TEST_HYPR_CLIENTS = '[{"address":"0x7777","class":"kaze-tui","title":"Audio Mixer"}]',
        TEST_HYPR_ACTIVE = "",
        TEST_HYPR_ACTIVE_EXIT = "1",
      })
      assert_eq(r3.code, 0, "activewindow failure should still focus matching window, stderr=" .. r3.stderr)
      assert_true(
        has_call(sb:calls(), "hyprctl", { "dispatch", "hl.dsp.focus({ window = 'address:0x7777' })" }) ~= nil,
        "must focus 0x7777 when activewindow fails, got:" .. format_calls(sb:calls())
      )
      assert_eq(#find_calls(sb:calls(), "footclient"), 0, "must not spawn duplicate window when match exists")
    end)
  end)
end

return run_suite
