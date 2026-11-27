-- Blind black-box & brute-force behavioral test suite for bin/kaze-mirror.
-- Derived strictly from the Behavioral Specification; uses Lua stdlib only.

local function sq(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function exec_code(cmd)
  local ok, why, code = os.execute(cmd)
  if type(ok) == "number" then
    return ok
  end
  if why == "exit" then
    return code
  end
  if why == "signal" then
    return 128 + (code or 0)
  end
  return ok and 0 or 1
end

local function popen_capture(cmd)
  local fh = assert(io.popen(cmd, "r"))
  local out = fh:read("*a") or ""
  fh:close()
  return out
end

local function read_file(path)
  local fh = io.open(path, "rb")
  if not fh then
    return nil
  end
  local data = fh:read("*a")
  fh:close()
  return data
end

local function write_file(path, content)
  local dir = path:match("^(.*)/[^/]+$")
  if dir and dir ~= "" then
    exec_code("mkdir -p -- " .. sq(dir))
  end
  local fh = assert(io.open(path, "wb"))
  fh:write(content)
  fh:close()
end

local function file_exists(path)
  return exec_code("test -e " .. sq(path) .. " || test -L " .. sq(path)) == 0
end

local function is_dir(path)
  return exec_code("test -d " .. sq(path)) == 0
end

local function stat_mode(path)
  local out = popen_capture("stat -c '%a' -- " .. sq(path) .. " 2>/dev/null")
  return out:gsub("%s+$", "")
end

local function list_dir(dir)
  local out = popen_capture("ls -A1 -- " .. sq(dir) .. " 2>/dev/null")
  local items = {}
  for line in out:gmatch("[^\r\n]+") do
    items[#items + 1] = line
  end
  return items
end

local function resolve_abs(dir)
  local out = popen_capture("cd -- " .. sq(dir) .. " && pwd -P")
  return out:gsub("%s+$", "")
end

local function json_str(s)
  local escaped = tostring(s)
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("\b", "\\b")
    :gsub("\f", "\\f")
    :gsub("\n", "\\n")
    :gsub("\r", "\\r")
    :gsub("\t", "\\t")
    :gsub("[%z\1-\31]", function(c)
      return string.format("\\u%04x", c:byte())
    end)
  return '"' .. escaped .. '"'
end

local function json_val(v)
  if v == "__NULL__" then
    return "null"
  elseif type(v) == "number" or type(v) == "boolean" then
    return tostring(v)
  else
    return json_str(v)
  end
end

local function build_plan_json(files)
  local parts = {}
  for i = 1, #files do
    local f = files[i]
    local fields = {}
    if f.path ~= nil then
      fields[#fields + 1] = '"path":' .. json_val(f.path)
    end
    if f.kind ~= nil then
      fields[#fields + 1] = '"kind":' .. json_val(f.kind)
    end
    if f.content ~= nil then
      fields[#fields + 1] = '"content":' .. json_val(f.content)
    end
    if f.parallel_downloads ~= nil then
      fields[#fields + 1] = '"parallel_downloads":' .. json_val(f.parallel_downloads)
    end
    parts[#parts + 1] = "{" .. table.concat(fields, ",") .. "}"
  end
  return '{"files":[' .. table.concat(parts, ",") .. "]}\n"
end

local function make_executable(path, content)
  write_file(path, content)
  assert(exec_code("chmod 0755 -- " .. sq(path)) == 0, "chmod failed for " .. path)
end

local function make_pacman_conf(ml_path, parallel_line)
  return table.concat({
    "#",
    "# /etc/pacman.conf - test fixture",
    "#",
    "[options]",
    "HoldPkg     = pacman glibc",
    "Architecture = auto",
    "Color",
    "CheckSpace",
    parallel_line or "ParallelDownloads = 5",
    "SigLevel    = Required DatabaseOptional",
    "LocalFileSigLevel = Optional",
    "",
    "[core]",
    "Include = " .. ml_path,
    "",
    "[extra]",
    "Include = " .. ml_path,
    "",
    "[multilib]",
    "Include = " .. ml_path,
    "",
  }, "\n")
end

local DEFAULT_MIRRORLIST = table.concat({
  "## Original test mirrorlist",
  "Server = https://mirror-old-1.example.invalid/$repo/os/$arch",
  "Server = https://mirror-old-2.example.invalid/$repo/os/$arch",
  "",
}, "\n")

local function create_sandbox(bin_path)
  local raw = popen_capture("mktemp -d /tmp/kaze-bb-mirror-XXXXXX")
  local dir = raw:gsub("%s+$", "")
  assert(dir ~= "" and dir:sub(1, 20) == "/tmp/kaze-bb-mirror-", "failed to create sandbox dir: " .. raw)
  dir = resolve_abs(dir)

  local sb = {
    dir = dir,
    bin_path = bin_path,
    home = dir .. "/home",
    xdg_config = dir .. "/xdg/config",
    xdg_data = dir .. "/xdg/data",
    xdg_cache = dir .. "/xdg/cache",
    xdg_state = dir .. "/xdg/state",
    xdg_runtime = dir .. "/xdg/runtime",
    stub_bin = dir .. "/stub_bin",
    logs = dir .. "/logs",
    root = dir .. "/root",
    run_seq = 0,
  }

  local mk = exec_code(
    "mkdir -p -- "
      .. sq(sb.home) .. " "
      .. sq(sb.xdg_config) .. " "
      .. sq(sb.xdg_data) .. " "
      .. sq(sb.xdg_cache) .. " "
      .. sq(sb.xdg_state) .. " "
      .. sq(sb.xdg_runtime) .. " "
      .. sq(sb.stub_bin) .. " "
      .. sq(sb.logs) .. " "
      .. sq(sb.root .. "/etc/pacman.d") .. " "
      .. sq(sb.root .. "/var/lib/pacman")
  )
  assert(mk == 0, "failed to create sandbox subdirectories")

  -- Hard-blocked tools: must NEVER execute in offline / test-root tests.
  local blocked_tools = { "sudo", "pkexec", "doas", "curl", "wget", "pacman", "reflector", "rate-mirrors" }
  for _, tool in ipairs(blocked_tools) do
    local log_path = sb.logs .. "/" .. tool .. ".log"
    make_executable(sb.stub_bin .. "/" .. tool, table.concat({
      "#!/bin/sh",
      "printf '%s\\n' \"$0 $*\" >> " .. sq(log_path),
      "printf 'BLOCKED_IN_BLACKBOX_TEST: %s %s\\n' \"$0\" \"$*\" >&2",
      "exit 99",
      "",
    }, "\n"))
  end

  -- notify-send stub (harmless logger)
  make_executable(sb.stub_bin .. "/notify-send", table.concat({
    "#!/bin/sh",
    "printf '%s\\n' \"$*\" >> " .. sq(sb.logs .. "/notify-send.log"),
    "exit 0",
    "",
  }, "\n"))

  -- noctalia stub (only reads stdin on dmenu subcommand; msg/other calls exit 0 immediately)
  make_executable(sb.stub_bin .. "/noctalia", table.concat({
    "#!/bin/sh",
    "{",
    "  printf 'CALL\\n'",
    "  for a in \"$@\"; do printf 'ARG:%s\\n' \"$a\"; done",
    "  printf 'END\\n'",
    "} >> " .. sq(sb.logs .. "/noctalia.argv.log"),
    "case \" $* \" in",
    "  *' dmenu '*)",
    "    cat > " .. sq(sb.logs .. "/noctalia.stdin.log"),
    "    if [ -f " .. sq(sb.dir .. "/mock_noctalia.out") .. " ]; then",
    "      cat " .. sq(sb.dir .. "/mock_noctalia.out"),
    "    fi",
    "    rc=0",
    "    if [ -f " .. sq(sb.dir .. "/mock_noctalia.rc") .. " ]; then",
    "      rc=$(cat " .. sq(sb.dir .. "/mock_noctalia.rc") .. ")",
    "    fi",
    "    exit \"$rc\"",
    "    ;;",
    "esac",
    "exit 0",
    "",
  }, "\n"))

  -- hyprctl stub
  make_executable(sb.stub_bin .. "/hyprctl", table.concat({
    "#!/bin/sh",
    "printf '%s\\n' \"$*\" >> " .. sq(sb.logs .. "/hyprctl.log"),
    "case \" $* \" in",
    "  *' clients '*)",
    "    if [ -f " .. sq(sb.dir .. "/mock_hypr_clients.json") .. " ]; then",
    "      cat " .. sq(sb.dir .. "/mock_hypr_clients.json"),
    "    else",
    "      printf '[]\\n'",
    "    fi",
    "    exit 0",
    "    ;;",
    "  *' activewindow '*)",
    "    if [ -f " .. sq(sb.dir .. "/mock_hypr_active.json") .. " ]; then",
    "      cat " .. sq(sb.dir .. "/mock_hypr_active.json"),
    "    else",
    "      printf '{}\\n'",
    "    fi",
    "    exit 0",
    "    ;;",
    "  *)",
    "    printf 'ok\\n'",
    "    exit 0",
    "    ;;",
    "esac",
    "",
  }, "\n"))

  -- footclient and foot stubs (record exact argv per call)
  for _, term in ipairs({ "footclient", "foot" }) do
    local log_path = sb.logs .. "/" .. term .. ".log"
    make_executable(sb.stub_bin .. "/" .. term, table.concat({
      "#!/bin/sh",
      "{",
      "  printf 'CALL\\n'",
      "  for a in \"$@\"; do printf 'ARG:%s\\n' \"$a\"; done",
      "  printf 'END\\n'",
      "} >> " .. sq(log_path),
      "exit 0",
      "",
    }, "\n"))
  end

  function sb:cleanup()
    if self.dir and self.dir:sub(1, 20) == "/tmp/kaze-bb-mirror-" then
      exec_code("rm -rf -- " .. sq(self.dir))
    end
  end

  function sb:default_pacman_conf()
    return make_pacman_conf(self.root .. "/etc/pacman.d/mirrorlist")
  end

  function sb:seed_root(opts)
    opts = opts or {}
    local pconf = opts.pacman_conf or self:default_pacman_conf()
    local mlist = opts.mirrorlist or DEFAULT_MIRRORLIST
    write_file(self.root .. "/etc/pacman.conf", pconf)
    write_file(self.root .. "/etc/pacman.d/mirrorlist", mlist)
    if opts.extra_files then
      for rel, content in pairs(opts.extra_files) do
        write_file(self.root .. "/" .. rel, content)
      end
    end
    return pconf, mlist
  end

  function sb:set_noctalia(out_str, rc)
    write_file(self.dir .. "/mock_noctalia.out", out_str or "")
    write_file(self.dir .. "/mock_noctalia.rc", tostring(rc or 0))
  end

  function sb:set_hyprctl(clients_json, active_json)
    write_file(self.dir .. "/mock_hypr_clients.json", clients_json or "[]")
    write_file(self.dir .. "/mock_hypr_active.json", active_json or "{}")
  end

  function sb:reset_logs()
    exec_code("rm -f -- " .. sq(self.logs) .. "/*.log")
  end

  function sb:log_content(name)
    return read_file(self.logs .. "/" .. name)
  end

  function sb:parse_arg_calls(log_name)
    local raw_log = self:log_content(log_name)
    if not raw_log then
      return {}
    end
    local calls = {}
    local cur = nil
    for line in raw_log:gmatch("[^\n]+") do
      if line == "CALL" then
        cur = {}
      elseif line == "END" then
        if cur then
          calls[#calls + 1] = cur
          cur = nil
        end
      elseif cur and line:sub(1, 4) == "ARG:" then
        cur[#cur + 1] = line:sub(5)
      end
    end
    return calls
  end

  function sb:env_prefix(extra_env)
    local env = {
      HOME = self.home,
      USER = "testuser",
      LOGNAME = "testuser",
      XDG_CONFIG_HOME = self.xdg_config,
      XDG_DATA_HOME = self.xdg_data,
      XDG_CACHE_HOME = self.xdg_cache,
      XDG_STATE_HOME = self.xdg_state,
      XDG_RUNTIME_DIR = self.xdg_runtime,
      PATH = self.stub_bin .. ":/usr/local/bin:/usr/bin:/bin",
      TERM = "xterm-256color",
      LANG = "C.UTF-8",
      LC_ALL = "C.UTF-8",
    }
    if extra_env then
      for k, v in pairs(extra_env) do
        if v == false then
          env[k] = nil
        else
          env[k] = v
        end
      end
    end
    local parts = { "env -i" }
    local keys = {}
    for k in pairs(env) do
      keys[#keys + 1] = k
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
      parts[#parts + 1] = sq(k .. "=" .. tostring(env[k]))
    end
    return table.concat(parts, " ")
  end

  function sb:run(args, extra_env)
    self.run_seq = self.run_seq + 1
    local out_f = string.format("%s/run_%d.out", self.dir, self.run_seq)
    local err_f = string.format("%s/run_%d.err", self.dir, self.run_seq)
    local argv = { self:env_prefix(extra_env), sq(self.bin_path) }
    for i = 1, #args do
      argv[#argv + 1] = sq(args[i])
    end
    local cmd = table.concat(argv, " ")
      .. " </dev/null >" .. sq(out_f) .. " 2>" .. sq(err_f)
    local code = exec_code(cmd)
    local stdout = read_file(out_f) or ""
    local stderr = read_file(err_f) or ""
    return {
      code = code,
      stdout = stdout,
      stderr = stderr,
      output = stdout .. stderr,
    }
  end

  function sb:blocked_summary()
    local hits = {}
    for _, tool in ipairs({ "sudo", "pkexec", "doas", "curl", "wget" }) do
      local log = self:log_content(tool .. ".log")
      if log then
        hits[#hits + 1] = tool
      end
    end
    return hits
  end

  function sb:assert_no_blocked(assert_eq, ctx)
    local must_not_run = { "sudo", "pkexec", "doas", "curl", "wget" }
    for _, tool in ipairs(must_not_run) do
      local log = self:log_content(tool .. ".log")
      assert_eq(log, nil, (ctx or "sandbox") .. ": forbidden tool '" .. tool .. "' was invoked: " .. tostring(log))
    end
  end

  return sb
end

local function with_sandbox(bin_path, fn)
  local sb = create_sandbox(bin_path)
  local ok, err = pcall(fn, sb)
  sb:cleanup()
  if not ok then
    error(err, 0)
  end
end

local function has_arg_pair(argv, flag, val)
  for i = 1, #argv do
    if argv[i] == flag and argv[i + 1] == val then
      return true
    end
    if argv[i] == (flag .. "=" .. val) then
      return true
    end
  end
  return false
end

local function has_arg(argv, target)
  for i = 1, #argv do
    if argv[i] == target then
      return true
    end
  end
  return false
end

local function run_suite(test, assert_eq, assert_true, assert_contains, repo_dir)
  local repo_abs = resolve_abs(repo_dir or ".")
  local bin_path = repo_abs .. "/bin/kaze-mirror"

  -- 1. CLI help and brute-force invalid flags / missing option values
  test("bb.mirror.cli_help_and_invalid_args", function()
    with_sandbox(bin_path, function(sb)
      for _, flag in ipairs({ "-h", "--help" }) do
        local r = sb:run({ flag })
        assert_eq(r.code, 0, flag .. " must exit 0 (stderr=" .. r.stderr .. ")")
        assert_contains(r.output, "Usage", flag .. " must print Usage")
      end
      sb:assert_no_blocked(assert_eq, "help")

      local invalid_cases = {
        { label = "unknown long flag", args = { "--bogus" } },
        { label = "unknown short flag", args = { "-x" } },
        { label = "positional arg", args = { "positional" } },
        { label = "trailing positional", args = { "--dry-run", "extra" } },
        { label = "auto-run missing", args = { "--auto-run" } },
        { label = "auto-run empty", args = { "--auto-run", "" } },
        { label = "auto-run= empty", args = { "--auto-run=" } },
        { label = "auto-run bogus", args = { "--auto-run", "bogus" } },
        { label = "auto-run=bogus", args = { "--auto-run=bogus" } },
        { label = "auto-run apply", args = { "--auto-run", "apply" } },
        { label = "auto-run=apply", args = { "--auto-run=apply" } },
        { label = "auto-run wrong case", args = { "--auto-run=FAST-DRY" } },
        { label = "auto-run flag as val", args = { "--auto-run", "--json" } },
        { label = "pacman-conf missing", args = { "--pacman-conf" } },
        { label = "pacman-conf empty", args = { "--pacman-conf", "" } },
        { label = "pacman-conf= empty", args = { "--pacman-conf=" } },
        { label = "commit-plan missing", args = { "--commit-plan" } },
        { label = "commit-plan empty", args = { "--commit-plan", "" } },
        { label = "commit-plan= empty", args = { "--commit-plan=" } },
        { label = "test-root missing", args = { "--test-root" } },
        { label = "test-root empty", args = { "--test-root", "" } },
        { label = "test-root= empty", args = { "--test-root=" } },
      }

      local failures = {}
      for _, c in ipairs(invalid_cases) do
        sb:reset_logs()
        local r = sb:run(c.args)
        local blocked = sb:blocked_summary()
        if r.code ~= 2 or #blocked > 0 then
          failures[#failures + 1] = string.format(
            "%s (%s): expected exit 2 & no external calls, got exit %d, blocked=[%s], stderr=%q",
            c.label,
            table.concat(c.args, " "),
            r.code,
            table.concat(blocked, ","),
            r.stderr:gsub("\n", " ")
          )
        end
      end
      assert_eq(#failures, 0, "invalid CLI args must exit 2:\n  " .. table.concat(failures, "\n  "))
    end)
  end)

  -- 2. Brute-force mutually exclusive mode pairs (both orders + triples)
  test("bb.mirror.cli_mutual_exclusion_matrix", function()
    with_sandbox(bin_path, function(sb)
      local pairs_matrix = {
        { "--menu", "--apply" },
        { "--menu", "--tui" },
        { "--menu", "--tui-window" },
        { "--menu", "--rollback" },
        { "--tui", "--apply" },
        { "--tui", "--tui-window" },
        { "--tui", "--rollback" },
        { "--tui-window", "--apply" },
        { "--tui-window", "--rollback" },
      }

      for _, pair in ipairs(pairs_matrix) do
        local a, b = pair[1], pair[2]
        local r1 = sb:run({ a, b })
        assert_eq(r1.code, 2, a .. " + " .. b .. " must exit 2 (stderr=" .. r1.stderr .. ")")
        local r2 = sb:run({ b, a })
        assert_eq(r2.code, 2, b .. " + " .. a .. " must exit 2 (stderr=" .. r2.stderr .. ")")
      end

      local triples = {
        { "--menu", "--tui", "--apply" },
        { "--tui", "--tui-window", "--rollback" },
        { "--menu", "--tui-window", "--rollback" },
      }
      for _, targs in ipairs(triples) do
        local r = sb:run(targs)
        assert_eq(r.code, 2, table.concat(targs, " ") .. " must exit 2")
      end

      sb:assert_no_blocked(assert_eq, "mutual exclusion")
      assert_eq(sb:log_content("noctalia.argv.log"), nil, "noctalia must not run on invalid mode combo")
      assert_eq(sb:log_content("hyprctl.log"), nil, "hyprctl must not run on invalid mode combo")
      assert_eq(sb:log_content("footclient.log"), nil, "footclient must not run on invalid mode combo")
    end)
  end)

  -- 3. Atomic commit invariants + pacman.conf preservation (active & commented ParallelDownloads)
  test("bb.mirror.commit_atomic_and_pacman_conf", function()
    with_sandbox(bin_path, function(sb)
      local orig_pc, orig_ml = sb:seed_root({
        extra_files = {
          ["etc/pacman.d/cachyos-mirrorlist"] = "Server = https://cachy-old.example.invalid/$repo/$arch\n",
        },
      })
      local ml_path = sb.root .. "/etc/pacman.d/mirrorlist"
      local cml_path = sb.root .. "/etc/pacman.d/cachyos-mirrorlist"
      local pc_path = sb.root .. "/etc/pacman.conf"
      local new_ml = "## Updated mirrorlist\nServer = https://fast-1.example.invalid/$repo/os/$arch\nServer = https://fast-2.example.invalid/$repo/os/$arch\n"
      local new_cml = "Server = https://cachy-fast.example.invalid/$repo/$arch\n"

      local plan1 = sb.dir .. "/plan1.json"
      write_file(plan1, build_plan_json({
        { path = ml_path, kind = "mirrorlist", content = new_ml },
        { path = cml_path, kind = "mirrorlist", content = new_cml },
        { path = pc_path, kind = "pacman_conf", parallel_downloads = 8 },
      }))

      local r1 = sb:run({ "--commit-plan", plan1, "--test-root", sb.root })
      assert_eq(r1.code, 0, "valid commit-plan must exit 0 (stderr=" .. r1.stderr .. ")")

      -- Verify updated mirrorlists
      assert_eq(read_file(ml_path), new_ml, "mirrorlist content must match plan")
      assert_eq(read_file(cml_path), new_cml, "cachyos-mirrorlist content must match plan")

      -- Verify pacman.conf updated ParallelDownloads and preserved all other lines
      local pc_after = read_file(pc_path)
      assert_contains(pc_after, "ParallelDownloads = 8", "ParallelDownloads must be updated to 8")
      assert_true(not pc_after:find("ParallelDownloads = 5", 1, true), "old ParallelDownloads = 5 must be replaced")
      assert_contains(pc_after, "# /etc/pacman.conf - test fixture", "comments must be preserved")
      assert_contains(pc_after, "HoldPkg     = pacman glibc", "HoldPkg must be preserved")
      assert_contains(pc_after, "CheckSpace", "CheckSpace must be preserved")
      assert_contains(pc_after, "[core]\nInclude = " .. ml_path, "[core] section must be preserved")
      assert_contains(pc_after, "[extra]\nInclude = " .. ml_path, "[extra] section must be preserved")
      assert_contains(pc_after, "[multilib]\nInclude = " .. ml_path, "[multilib] section must be preserved")

      -- Verify transactional manifest & directory permissions (mode 755)
      local state_dir = sb.root .. "/var/lib/kaze-mirror"
      local manifest = state_dir .. "/last-commit.json"
      assert_true(is_dir(state_dir), "state dir var/lib/kaze-mirror must exist")
      assert_eq(stat_mode(state_dir), "755", "var/lib/kaze-mirror directory mode must be 755")
      assert_true(file_exists(manifest), "last-commit.json manifest must exist")
      local manifest_mode = stat_mode(manifest)
      assert_true(
        manifest_mode == "644" or manifest_mode == "664" or manifest_mode == "444",
        "last-commit.json must be world-readable (got mode " .. manifest_mode .. ")"
      )
      local manifest_data = read_file(manifest) or ""
      assert_true(#manifest_data > 10 and manifest_data:find("{", 1, true) ~= nil, "manifest must contain JSON")

      -- Verify .kaze-bak-* backup files exist alongside modified files with exact pre-commit contents
      local ml_baks = {}
      for _, name in ipairs(list_dir(sb.root .. "/etc/pacman.d")) do
        if name:match("^mirrorlist%.kaze%-bak%-") then
          ml_baks[#ml_baks + 1] = name
        end
      end
      assert_true(#ml_baks >= 1, "mirrorlist .kaze-bak-* backup must be created")
      assert_eq(read_file(sb.root .. "/etc/pacman.d/" .. ml_baks[1]), orig_ml, "mirrorlist backup must hold exact pre-commit content")

      local pc_baks = {}
      for _, name in ipairs(list_dir(sb.root .. "/etc")) do
        if name:match("^pacman%.conf%.kaze%-bak%-") then
          pc_baks[#pc_baks + 1] = name
        end
      end
      assert_true(#pc_baks >= 1, "pacman.conf .kaze-bak-* backup must be created")
      assert_eq(read_file(sb.root .. "/etc/" .. pc_baks[1]), orig_pc, "pacman.conf backup must hold exact pre-commit content")

      -- Second case: commented #ParallelDownloads = 5 + --flag=value CLI form
      local commented_pc = orig_pc:gsub("ParallelDownloads = 5", "#ParallelDownloads = 5")
      write_file(pc_path, commented_pc)
      local new_ml2 = "Server = https://fast-3.example.invalid/$repo/os/$arch\n"
      local plan2 = sb.dir .. "/plan2.json"
      write_file(plan2, build_plan_json({
        { path = ml_path, kind = "mirrorlist", content = new_ml2 },
        { path = pc_path, kind = "pacman_conf", parallel_downloads = 12 },
      }))

      local r2 = sb:run({ "--commit-plan=" .. plan2, "--test-root=" .. sb.root })
      assert_eq(r2.code, 0, "commit-plan with commented #ParallelDownloads and = flags must exit 0 (stderr=" .. r2.stderr .. ")")
      local pc_after2 = read_file(pc_path)
      assert_true(pc_after2:find("\nParallelDownloads = 12\n", 1, true) ~= nil, "commented #ParallelDownloads must be uncommented and set to 12")
      assert_true(not pc_after2:find("#ParallelDownloads", 1, true), "commented #ParallelDownloads line should be replaced")
      assert_contains(pc_after2, "[multilib]\nInclude = " .. ml_path, "other sections still preserved")
      assert_eq(read_file(ml_path), new_ml2, "mirrorlist updated on second commit")

      sb:assert_no_blocked(assert_eq, "atomic commit")
    end)
  end)

  -- 4. Privileged commit security boundary refusals (db.lck, symlinks, traversal, outside root, disallowed names)
  test("bb.mirror.commit_security_paths_and_symlinks", function()
    with_sandbox(bin_path, function(sb)
      local orig_pc, orig_ml = sb:seed_root()
      local ml_path = sb.root .. "/etc/pacman.d/mirrorlist"
      local pc_path = sb.root .. "/etc/pacman.conf"
      local valid_content = "Server = https://evil.example.invalid/$repo/os/$arch\n"

      local function assert_commit_refused(label, plan_files, expect_stderr, extra_check)
        local plan_path = sb.dir .. "/sec_plan.json"
        write_file(plan_path, build_plan_json(plan_files))
        local r = sb:run({ "--commit-plan", plan_path, "--test-root", sb.root })
        assert_true(r.code ~= 0, label .. " must be refused (got exit 0, stdout=" .. r.stdout .. ")")
        if expect_stderr then
          assert_contains(r.stderr:lower(), expect_stderr:lower(), label .. " stderr must mention " .. expect_stderr)
        end
        assert_eq(read_file(ml_path), orig_ml, label .. ": mirrorlist must remain unchanged")
        assert_eq(read_file(pc_path), orig_pc, label .. ": pacman.conf must remain unchanged")
        if extra_check then
          extra_check(r)
        end
      end

      -- 4a. db.lck present
      local dblck = sb.root .. "/var/lib/pacman/db.lck"
      write_file(dblck, "locked\n")
      assert_commit_refused("db.lck present", {
        { path = ml_path, kind = "mirrorlist", content = valid_content },
      }, "db.lck")
      exec_code("rm -f -- " .. sq(dblck))

      -- 4b. Symlink target in etc/pacman.d/
      local victim = sb.dir .. "/symlink_victim.txt"
      write_file(victim, "DO_NOT_TOUCH\n")
      local sym_ml = sb.root .. "/etc/pacman.d/sym-mirrorlist"
      assert_eq(exec_code("ln -s -- " .. sq(victim) .. " " .. sq(sym_ml)), 0, "create mirrorlist symlink")
      assert_commit_refused("symlink mirrorlist", {
        { path = sym_ml, kind = "mirrorlist", content = valid_content },
      }, "symlink", function()
        assert_eq(read_file(victim), "DO_NOT_TOUCH\n", "symlink victim must not be modified")
      end)
      exec_code("rm -f -- " .. sq(sym_ml))

      -- 4c. Symlink pacman.conf
      exec_code("rm -f -- " .. sq(pc_path))
      assert_eq(exec_code("ln -s -- " .. sq(victim) .. " " .. sq(pc_path)), 0, "create pacman.conf symlink")
      do
        local plan_path = sb.dir .. "/sec_sym_pc.json"
        write_file(plan_path, build_plan_json({
          { path = pc_path, kind = "pacman_conf", parallel_downloads = 8 },
        }))
        local r = sb:run({ "--commit-plan", plan_path, "--test-root", sb.root })
        assert_true(r.code ~= 0, "symlink pacman.conf must be refused")
        assert_contains(r.stderr:lower(), "symlink", "symlink pacman.conf stderr must mention symlink")
        assert_eq(read_file(victim), "DO_NOT_TOUCH\n", "pacman.conf symlink victim must not be modified")
      end
      exec_code("rm -f -- " .. sq(pc_path))
      write_file(pc_path, orig_pc)

      -- 4d. Path traversal attacks
      local shadow_path = sb.root .. "/etc/shadow"
      write_file(shadow_path, "root:x:0\n")
      local traversals = {
        { label = "traversal ../shadow", path = sb.root .. "/etc/pacman.d/../shadow" },
        { label = "traversal ../../etc/passwd", path = sb.root .. "/etc/pacman.d/../../etc/passwd" },
        { label = "traversal ../pacman.conf as mirrorlist", path = sb.root .. "/etc/pacman.d/../pacman.conf" },
      }
      for _, t in ipairs(traversals) do
        assert_commit_refused(t.label, {
          { path = t.path, kind = "mirrorlist", content = valid_content },
        }, nil, function()
          assert_eq(read_file(shadow_path), "root:x:0\n", t.label .. ": shadow must remain untouched")
        end)
      end

      -- 4e. Targets outside test_root (including prefix-confusion sibling dir)
      local outside_file = sb.dir .. "/outside_mirrorlist"
      write_file(outside_file, "OUTSIDE_UNTOUCHED\n")
      local evil_prefix_file = sb.dir .. "/root-evil/etc/pacman.d/mirrorlist"
      write_file(evil_prefix_file, "EVIL_PREFIX_UNTOUCHED\n")
      local outside_cases = {
        { label = "outside sandbox sibling", path = outside_file },
        { label = "prefix-confusion root-evil", path = evil_prefix_file },
        { label = "host /etc/pacman.d/mirrorlist", path = "/etc/pacman.d/mirrorlist" },
      }
      for _, o in ipairs(outside_cases) do
        assert_commit_refused(o.label, {
          { path = o.path, kind = "mirrorlist", content = valid_content },
        }, nil, function()
          assert_eq(read_file(outside_file), "OUTSIDE_UNTOUCHED\n", "outside file untouched")
          assert_eq(read_file(evil_prefix_file), "EVIL_PREFIX_UNTOUCHED\n", "prefix-confusion file untouched")
        end)
      end

      -- 4f. Disallowed filenames under <root>/etc/pacman.d/
      local disallowed = {
        ".hidden",
        "mirrorlist.pacnew",
        "mirrorlist.kaze-bak-20261127_010000",
        "gnupg",
      }
      for _, fname in ipairs(disallowed) do
        local fpath = sb.root .. "/etc/pacman.d/" .. fname
        write_file(fpath, "KEEP_ME_" .. fname .. "\n")
        assert_commit_refused("disallowed name " .. fname, {
          { path = fpath, kind = "mirrorlist", content = valid_content },
        }, nil, function()
          assert_eq(read_file(fpath), "KEEP_ME_" .. fname .. "\n", fname .. " must remain unchanged")
        end)
      end

      -- 4g. Atomicity: mixed valid entry + malicious entry must fail without modifying the valid target
      assert_commit_refused("mixed valid + traversal atomicity", {
        { path = ml_path, kind = "mirrorlist", content = valid_content },
        { path = sb.root .. "/etc/pacman.d/../shadow", kind = "mirrorlist", content = valid_content },
      })

      -- 4h. Non-existent test_root directory
      do
        local plan_path = sb.dir .. "/nonexistent_root_plan.json"
        write_file(plan_path, build_plan_json({
          { path = sb.dir .. "/no-such-root/etc/pacman.d/mirrorlist", kind = "mirrorlist", content = valid_content },
        }))
        local r = sb:run({ "--commit-plan", plan_path, "--test-root", sb.dir .. "/no-such-root" })
        assert_true(r.code ~= 0, "non-existent test_root must be refused")
      end

      sb:assert_no_blocked(assert_eq, "security refusals")
    end)
  end)

  -- 5. Plan JSON schema & parallel_downloads fuzzing
  test("bb.mirror.commit_plan_validation_fuzz", function()
    with_sandbox(bin_path, function(sb)
      local orig_pc, orig_ml = sb:seed_root()
      local ml_path = sb.root .. "/etc/pacman.d/mirrorlist"
      local pc_path = sb.root .. "/etc/pacman.conf"

      -- Missing plan file
      local r_miss = sb:run({ "--commit-plan", sb.dir .. "/does-not-exist.json", "--test-root", sb.root })
      assert_true(r_miss.code ~= 0, "missing plan file must fail")

      -- Malformed / empty / wrong-shape JSON files
      local bad_jsons = {
        { label = "empty file", raw = "" },
        { label = "whitespace only", raw = "   \n\t  " },
        { label = "truncated object", raw = '{"files": [' },
        { label = "garbage text", raw = "not valid json at all" },
        { label = "top-level array", raw = "[]" },
        { label = "empty object", raw = "{}" },
        { label = "files not array", raw = '{"files":"bad"}' },
        { label = "empty files array", raw = '{"files":[]}' },
        { label = "unknown kind", raw = build_plan_json({ { path = ml_path, kind = "unknown_kind", content = "Server = https://a\n" } }) },
        { label = "mirrorlist missing content", raw = build_plan_json({ { path = ml_path, kind = "mirrorlist" } }) },
        { label = "mirrorlist numeric content", raw = build_plan_json({ { path = ml_path, kind = "mirrorlist", content = 12345 } }) },
        { label = "pacman_conf wrong path", raw = build_plan_json({ { path = ml_path, kind = "pacman_conf", parallel_downloads = 5 } }) },
      }

      for i, bj in ipairs(bad_jsons) do
        local pf = string.format("%s/bad_%d.json", sb.dir, i)
        write_file(pf, bj.raw)
        local r = sb:run({ "--commit-plan", pf, "--test-root", sb.root })
        assert_true(r.code ~= 0, bj.label .. " must be rejected")
        assert_eq(read_file(ml_path), orig_ml, bj.label .. ": mirrorlist untouched")
        assert_eq(read_file(pc_path), orig_pc, bj.label .. ": pacman.conf untouched")
      end

      -- Invalid parallel_downloads values (collect all failures so every case is verified)
      local bad_pds = {
        { label = "string abc", val = "abc" },
        { label = "zero", val = 0 },
        { label = "negative", val = -1 },
        { label = "too large 999", val = 999 },
        { label = "float 2.5", val = 2.5 },
        { label = "boolean true", val = true },
        { label = "null", val = "__NULL__" },
      }
      local pd_failures = {}
      for i, bp in ipairs(bad_pds) do
        write_file(ml_path, orig_ml)
        write_file(pc_path, orig_pc)
        local pf = string.format("%s/bad_pd_%d.json", sb.dir, i)
        write_file(pf, build_plan_json({
          { path = ml_path, kind = "mirrorlist", content = "Server = https://new.example.invalid/$repo/os/$arch\n" },
          { path = pc_path, kind = "pacman_conf", parallel_downloads = bp.val },
        }))
        local r = sb:run({ "--commit-plan", pf, "--test-root", sb.root })
        if r.code == 0 or read_file(ml_path) ~= orig_ml or read_file(pc_path) ~= orig_pc then
          pd_failures[#pd_failures + 1] = string.format(
            "parallel_downloads=%s: expected rejection & unchanged files, got exit %d",
            bp.label,
            r.code
          )
        end
      end

      -- Missing pacman.conf when pacman_conf entry is present
      exec_code("rm -f -- " .. sq(pc_path))
      local pf_nopc = sb.dir .. "/no_pacman_conf.json"
      write_file(pf_nopc, build_plan_json({
        { path = pc_path, kind = "pacman_conf", parallel_downloads = 6 },
      }))
      local r_nopc = sb:run({ "--commit-plan", pf_nopc, "--test-root", sb.root })
      assert_true(r_nopc.code ~= 0, "missing pacman.conf must be rejected for pacman_conf entry")
      assert_true(not file_exists(pc_path), "missing pacman.conf must not be fabricated")

      sb:assert_no_blocked(assert_eq, "plan fuzz")
      assert_eq(#pd_failures, 0, "invalid parallel_downloads values must be rejected:\n  " .. table.concat(pd_failures, "\n  "))
    end)
  end)

  -- 6. Backup rotation invariant (<= 5 .kaze-bak-* kept; .pacnew and .bak-manual untouched)
  test("bb.mirror.commit_backup_rotation", function()
    with_sandbox(bin_path, function(sb)
      local orig_pc, orig_ml = sb:seed_root()
      local ml_dir = sb.root .. "/etc/pacman.d"
      local etc_dir = sb.root .. "/etc"
      local ml_path = ml_dir .. "/mirrorlist"
      local pc_path = etc_dir .. "/pacman.conf"

      -- Pre-seed 6 older .kaze-bak-* files (both lex-older and mtime-older) + .pacnew + .bak-manual
      for i = 1, 6 do
        local ts = string.format("20200101_01000%d", i)
        local touch_ts = string.format("202001010100.0%d", i)
        local mbak = ml_dir .. "/mirrorlist.kaze-bak-" .. ts
        local pbak = etc_dir .. "/pacman.conf.kaze-bak-" .. ts
        write_file(mbak, "old-ml-bak-" .. i .. "\n")
        write_file(pbak, "old-pc-bak-" .. i .. "\n")
        exec_code("touch -t " .. touch_ts .. " -- " .. sq(mbak) .. " " .. sq(pbak))
      end

      local ml_pacnew = ml_dir .. "/mirrorlist.pacnew"
      local ml_manual = ml_dir .. "/mirrorlist.bak-manual"
      local pc_pacnew = etc_dir .. "/pacman.conf.pacnew"
      local pc_manual = etc_dir .. "/pacman.conf.bak-manual"
      write_file(ml_pacnew, "PACNEW_MIRRORLIST\n")
      write_file(ml_manual, "MANUAL_MIRRORLIST\n")
      write_file(pc_pacnew, "PACNEW_PACMAN_CONF\n")
      write_file(pc_manual, "MANUAL_PACMAN_CONF\n")

      local plan = sb.dir .. "/rot_plan.json"
      write_file(plan, build_plan_json({
        { path = ml_path, kind = "mirrorlist", content = "Server = https://rot.example.invalid/$repo/os/$arch\n" },
        { path = pc_path, kind = "pacman_conf", parallel_downloads = 9 },
      }))
      local r = sb:run({ "--commit-plan", plan, "--test-root", sb.root })
      assert_eq(r.code, 0, "commit with pre-seeded backups must exit 0 (stderr=" .. r.stderr .. ")")

      local ml_baks, pc_baks = {}, {}
      for _, name in ipairs(list_dir(ml_dir)) do
        if name:match("^mirrorlist%.kaze%-bak%-") then
          ml_baks[#ml_baks + 1] = name
        end
      end
      for _, name in ipairs(list_dir(etc_dir)) do
        if name:match("^pacman%.conf%.kaze%-bak%-") then
          pc_baks[#pc_baks + 1] = name
        end
      end

      assert_true(#ml_baks >= 1 and #ml_baks <= 5, "mirrorlist .kaze-bak-* count must be rotated to <= 5 (got " .. #ml_baks .. ")")
      assert_true(#pc_baks >= 1 and #pc_baks <= 5, "pacman.conf .kaze-bak-* count must be rotated to <= 5 (got " .. #pc_baks .. ")")

      -- Oldest pre-seeded backups must be evicted first
      assert_true(not file_exists(ml_dir .. "/mirrorlist.kaze-bak-20200101_010001"), "oldest mirrorlist backup 01 must be pruned")
      assert_true(not file_exists(ml_dir .. "/mirrorlist.kaze-bak-20200101_010002"), "second oldest mirrorlist backup 02 must be pruned")
      assert_true(not file_exists(etc_dir .. "/pacman.conf.kaze-bak-20200101_010001"), "oldest pacman.conf backup 01 must be pruned")

      -- Non-.kaze-bak-* files MUST NEVER be deleted
      assert_eq(read_file(ml_pacnew), "PACNEW_MIRRORLIST\n", "mirrorlist.pacnew must never be deleted")
      assert_eq(read_file(ml_manual), "MANUAL_MIRRORLIST\n", "mirrorlist.bak-manual must never be deleted")
      assert_eq(read_file(pc_pacnew), "PACNEW_PACMAN_CONF\n", "pacman.conf.pacnew must never be deleted")
      assert_eq(read_file(pc_manual), "MANUAL_PACMAN_CONF\n", "pacman.conf.bak-manual must never be deleted")

      -- Newest backup must remain intact so rollback still succeeds
      local r_rb = sb:run({ "--commit-rollback", "--test-root", sb.root })
      assert_eq(r_rb.code, 0, "rollback after backup rotation must succeed (stderr=" .. r_rb.stderr .. ")")
      assert_eq(read_file(ml_path), orig_ml, "mirrorlist restored after rotation")
      assert_eq(read_file(pc_path), orig_pc, "pacman.conf restored after rotation")

      sb:assert_no_blocked(assert_eq, "backup rotation")
    end)
  end)

  -- 7. Transactional rollback, double-rollback refusal, missing manifest, db.lck refusal
  test("bb.mirror.rollback_transactional_and_double_guard", function()
    with_sandbox(bin_path, function(sb)
      local orig_pc, orig_ml = sb:seed_root()
      local ml_path = sb.root .. "/etc/pacman.d/mirrorlist"
      local pc_path = sb.root .. "/etc/pacman.conf"

      -- 7a. No manifest yet -> rollback fails cleanly
      local r_none = sb:run({ "--commit-rollback", "--test-root", sb.root })
      assert_true(r_none.code ~= 0, "rollback without manifest must fail")
      assert_eq(read_file(ml_path), orig_ml, "mirrorlist unchanged when no manifest")
      assert_eq(read_file(pc_path), orig_pc, "pacman.conf unchanged when no manifest")

      -- 7b. Commit changes to both mirrorlist and pacman.conf
      local new_ml = "Server = https://committed.example.invalid/$repo/os/$arch\n"
      local plan = sb.dir .. "/rb_plan.json"
      write_file(plan, build_plan_json({
        { path = ml_path, kind = "mirrorlist", content = new_ml },
        { path = pc_path, kind = "pacman_conf", parallel_downloads = 10 },
      }))
      local r_commit = sb:run({ "--commit-plan", plan, "--test-root", sb.root })
      assert_eq(r_commit.code, 0, "commit before rollback must succeed")
      assert_eq(read_file(ml_path), new_ml)
      assert_contains(read_file(pc_path), "ParallelDownloads = 10")

      -- 7c. Rollback refused while db.lck exists
      local dblck = sb.root .. "/var/lib/pacman/db.lck"
      write_file(dblck, "locked\n")
      local r_lck = sb:run({ "--commit-rollback", "--test-root", sb.root })
      assert_true(r_lck.code ~= 0, "rollback with db.lck must be refused")
      assert_eq(read_file(ml_path), new_ml, "mirrorlist must not change when db.lck refuses rollback")
      assert_contains(read_file(pc_path), "ParallelDownloads = 10", "pacman.conf must not change when db.lck refuses rollback")
      exec_code("rm -f -- " .. sq(dblck))

      -- 7d. Valid rollback restores exact pre-commit contents for ALL modified files
      local r_rb1 = sb:run({ "--commit-rollback", "--test-root", sb.root })
      assert_eq(r_rb1.code, 0, "first rollback must exit 0 (stderr=" .. r_rb1.stderr .. ")")
      assert_eq(read_file(ml_path), orig_ml, "mirrorlist must be restored byte-for-byte")
      assert_eq(read_file(pc_path), orig_pc, "pacman.conf must be restored byte-for-byte")

      -- 7e. Second rollback MUST be refused (double-rollback guard)
      local r_rb2 = sb:run({ "--commit-rollback", "--test-root", sb.root })
      assert_true(r_rb2.code ~= 0, "second rollback (double rollback) must be refused")
      assert_eq(read_file(ml_path), orig_ml, "mirrorlist unchanged after refused double rollback")
      assert_eq(read_file(pc_path), orig_pc, "pacman.conf unchanged after refused double rollback")

      sb:assert_no_blocked(assert_eq, "transactional rollback")
    end)
  end)

  -- 8. Rollback external-edit guard (refused without --force, allowed with --force)
  test("bb.mirror.rollback_external_edit_guard_and_force", function()
    with_sandbox(bin_path, function(sb)
      local orig_pc, orig_ml = sb:seed_root()
      local ml_path = sb.root .. "/etc/pacman.d/mirrorlist"
      local pc_path = sb.root .. "/etc/pacman.conf"

      -- Case A: external edit on mirrorlist
      local committed_ml = "Server = https://committed-a.example.invalid/$repo/os/$arch\n"
      local plan_a = sb.dir .. "/plan_a.json"
      write_file(plan_a, build_plan_json({
        { path = ml_path, kind = "mirrorlist", content = committed_ml },
        { path = pc_path, kind = "pacman_conf", parallel_downloads = 7 },
      }))
      assert_eq(sb:run({ "--commit-plan", plan_a, "--test-root", sb.root }).code, 0, "commit A must succeed")
      local committed_pc = read_file(pc_path)

      local manual_ml = committed_ml .. "# manual user edit\n"
      write_file(ml_path, manual_ml)

      local r_refused = sb:run({ "--commit-rollback", "--test-root", sb.root })
      assert_true(r_refused.code ~= 0, "rollback without --force must refuse externally edited mirrorlist")
      assert_eq(read_file(ml_path), manual_ml, "externally edited mirrorlist must remain intact on refusal")
      assert_eq(read_file(pc_path), committed_pc, "pacman.conf must remain intact on atomic refusal")

      local r_forced = sb:run({ "--commit-rollback", "--force", "--test-root", sb.root })
      assert_eq(r_forced.code, 0, "rollback with --force must succeed (stderr=" .. r_forced.stderr .. ")")
      assert_eq(read_file(ml_path), orig_ml, "--force rollback must restore mirrorlist")
      assert_eq(read_file(pc_path), orig_pc, "--force rollback must restore pacman.conf")

      -- Case B: external edit on pacman.conf
      local committed_ml_b = "Server = https://committed-b.example.invalid/$repo/os/$arch\n"
      local plan_b = sb.dir .. "/plan_b.json"
      write_file(plan_b, build_plan_json({
        { path = ml_path, kind = "mirrorlist", content = committed_ml_b },
        { path = pc_path, kind = "pacman_conf", parallel_downloads = 6 },
      }))
      assert_eq(sb:run({ "--commit-plan", plan_b, "--test-root", sb.root }).code, 0, "commit B must succeed")
      local manual_pc = read_file(pc_path) .. "\n# manual pacman.conf edit\n"
      write_file(pc_path, manual_pc)

      local r_refused_b = sb:run({ "--commit-rollback", "--test-root", sb.root })
      assert_true(r_refused_b.code ~= 0, "rollback without --force must refuse externally edited pacman.conf")
      assert_eq(read_file(pc_path), manual_pc, "externally edited pacman.conf must remain intact on refusal")
      assert_eq(read_file(ml_path), committed_ml_b, "mirrorlist must remain intact on atomic refusal")

      local r_forced_b = sb:run({ "--commit-rollback", "--force", "--test-root", sb.root })
      assert_eq(r_forced_b.code, 0, "rollback --force must restore externally edited pacman.conf (stderr=" .. r_forced_b.stderr .. ")")
      assert_eq(read_file(ml_path), orig_ml, "mirrorlist restored after Case B --force")
      assert_eq(read_file(pc_path), orig_pc, "pacman.conf restored after Case B --force")

      sb:assert_no_blocked(assert_eq, "external edit guard")
    end)
  end)

  -- 9. --menu integration with noctalia dmenu
  test("bb.mirror.menu_noctalia_dmenu", function()
    with_sandbox(bin_path, function(sb)
      local sandbox_pc, orig_ml = sb:seed_root()
      local ml_path = sb.root .. "/etc/pacman.d/mirrorlist"
      local pc_path = sb.root .. "/etc/pacman.conf"

      -- Empty selection (Esc)
      sb:set_noctalia("", 0)
      local r = sb:run({ "--menu", "--pacman-conf", pc_path })
      assert_eq(r.code, 0, "--menu with empty selection must exit 0 (stderr=" .. r.stderr .. ")")

      local n_calls = sb:parse_arg_calls("noctalia.argv.log")
      assert_true(#n_calls >= 1, "noctalia must be invoked")
      assert_true(has_arg(n_calls[1], "dmenu"), "noctalia must be invoked with dmenu subcommand")

      local dmenu_stdin = sb:log_content("noctalia.stdin.log") or ""
      assert_contains(dmenu_stdin, "Open Mirror Optimizer (TUI)", "dmenu entries must contain 'Open Mirror Optimizer (TUI)'")

      -- Ensure files untouched and no network/sudo calls
      assert_eq(read_file(ml_path), orig_ml, "--menu Esc must not mutate mirrorlist")
      assert_eq(read_file(pc_path), sandbox_pc, "--menu Esc must not mutate pacman.conf")
      sb:assert_no_blocked(assert_eq, "--menu Esc")
    end)
  end)

  -- 10. --tui-window toggle lifecycle (without --auto-run: absent -> spawn, unfocused -> focus, active -> close)
  test("bb.mirror.tui_window_toggle_lifecycle", function()
    with_sandbox(bin_path, function(sb)
      sb:seed_root()
      local pc_path = sb.root .. "/etc/pacman.conf"

      local hypr_env = { HYPRLAND_INSTANCE_SIGNATURE = "sig-1" }
      local args = { "--tui-window", "--pacman-conf", pc_path }

      -- Absent -> launches footclient -a kaze-mirror-tui ... --tui
      sb:reset_logs()
      sb:set_hyprctl(
        '[{"address":"0x1001","class":"foot","initialClass":"foot","title":"foot","workspace":{"id":1,"name":"1"},"focusHistoryID":0,"mapped":true,"hidden":false}]',
        '{"address":"0x1001","class":"foot","initialClass":"foot","title":"foot","workspace":{"id":1,"name":"1"},"focusHistoryID":0}'
      )
      assert_eq(sb:run(args, hypr_env).code, 0, "--tui-window spawn must exit 0")
      local fc_calls = sb:parse_arg_calls("footclient.log")
      assert_eq(#fc_calls, 1, "footclient must be spawned once when window is absent")
      assert_true(
        has_arg_pair(fc_calls[1], "-a", "kaze-mirror-tui") or has_arg(fc_calls[1], "-akaze-mirror-tui"),
        "footclient must pass -a kaze-mirror-tui"
      )
      assert_true(has_arg(fc_calls[1], "--tui"), "footclient must launch --tui")

      -- Unfocused -> focuses via hyprctl dispatch, no second Foot window
      sb:reset_logs()
      sb:set_hyprctl(
        '[{"address":"0x1001","class":"foot","initialClass":"foot","title":"foot","workspace":{"id":1,"name":"1"},"focusHistoryID":0,"mapped":true,"hidden":false},{"address":"0x2002","class":"kaze-mirror-tui","initialClass":"kaze-mirror-tui","title":"Kaze Mirror Optimizer","workspace":{"id":2,"name":"2"},"focusHistoryID":1,"mapped":true,"hidden":false}]',
        '{"address":"0x1001","class":"foot","initialClass":"foot","title":"foot","workspace":{"id":1,"name":"1"},"focusHistoryID":0}'
      )
      assert_eq(sb:run(args, hypr_env).code, 0, "--tui-window focus must exit 0")
      assert_eq(#sb:parse_arg_calls("footclient.log"), 0, "must not spawn footclient when unfocused window exists")
      assert_eq(#sb:parse_arg_calls("foot.log"), 0, "must not spawn foot when unfocused window exists")
      local hlog_focus = sb:log_content("hyprctl.log") or ""
      assert_contains(hlog_focus, "dispatch", "must dispatch focus via hyprctl")
      assert_true(hlog_focus:lower():find("focus", 1, true) ~= nil, "hyprctl dispatch must focus window")

      -- Active -> closes cleanly via hyprctl dispatch, no Foot window
      sb:reset_logs()
      sb:set_hyprctl(
        '[{"address":"0x2002","class":"kaze-mirror-tui","initialClass":"kaze-mirror-tui","title":"Kaze Mirror Optimizer","workspace":{"id":2,"name":"2"},"focusHistoryID":0,"mapped":true,"hidden":false},{"address":"0x1001","class":"foot","initialClass":"foot","title":"foot","workspace":{"id":1,"name":"1"},"focusHistoryID":1,"mapped":true,"hidden":false}]',
        '{"address":"0x2002","class":"kaze-mirror-tui","initialClass":"kaze-mirror-tui","title":"Kaze Mirror Optimizer","workspace":{"id":2,"name":"2"},"focusHistoryID":0}'
      )
      assert_eq(sb:run(args, hypr_env).code, 0, "--tui-window close active must exit 0")
      assert_eq(#sb:parse_arg_calls("footclient.log"), 0, "must not spawn footclient when closing active window")
      assert_eq(#sb:parse_arg_calls("foot.log"), 0, "must not spawn foot when closing active window")
      local hlog_close = sb:log_content("hyprctl.log") or ""
      assert_contains(hlog_close, "dispatch", "must dispatch close via hyprctl")
      assert_true(
        hlog_close:lower():find("close", 1, true) ~= nil or hlog_close:lower():find("kill", 1, true) ~= nil,
        "hyprctl dispatch must close/kill active window (log=" .. hlog_close .. ")"
      )

      sb:assert_no_blocked(assert_eq, "--tui-window toggle")
    end)
  end)

  -- 11. --tui-window --auto-run fast-dry lifecycle (per Section 4 spec)
  test("bb.mirror.tui_window_autorun_lifecycle", function()
    with_sandbox(bin_path, function(sb)
      sb:seed_root()
      local pc_path = sb.root .. "/etc/pacman.conf"

      local hypr_env = { HYPRLAND_INSTANCE_SIGNATURE = "sig-1" }
      local args = { "--tui-window", "--auto-run", "fast-dry", "--pacman-conf", pc_path }

      -- 11a. Absent -> spawns footclient -a kaze-mirror-tui ... --tui --auto-run fast-dry
      sb:reset_logs()
      sb:set_hyprctl(
        '[{"address":"0x1001","class":"foot","initialClass":"foot","title":"foot","workspace":{"id":1,"name":"1"},"focusHistoryID":0,"mapped":true,"hidden":false}]',
        '{"address":"0x1001","class":"foot","initialClass":"foot","title":"foot","workspace":{"id":1,"name":"1"},"focusHistoryID":0}'
      )
      local r_spawn = sb:run(args, hypr_env)
      assert_eq(r_spawn.code, 0, "--tui-window --auto-run spawn must exit 0 (stderr=" .. r_spawn.stderr .. ")")

      local fc_calls = sb:parse_arg_calls("footclient.log")
      assert_eq(#fc_calls, 1, "footclient must be spawned exactly once when window is absent")
      local fc_argv = fc_calls[1]
      assert_true(
        has_arg_pair(fc_argv, "-a", "kaze-mirror-tui") or has_arg(fc_argv, "-akaze-mirror-tui"),
        "footclient must pass -a kaze-mirror-tui (got: " .. table.concat(fc_argv, " ") .. ")"
      )
      assert_true(has_arg(fc_argv, "--tui"), "footclient command must include --tui")
      assert_true(
        has_arg_pair(fc_argv, "--auto-run", "fast-dry"),
        "footclient command must include --auto-run fast-dry (got: " .. table.concat(fc_argv, " ") .. ")"
      )

      -- 11b. Exists & unfocused -> focuses via hyprctl dispatch (no second Foot window)
      sb:reset_logs()
      sb:set_hyprctl(
        '[{"address":"0x1001","class":"foot","initialClass":"foot","title":"foot","workspace":{"id":1,"name":"1"},"focusHistoryID":0,"mapped":true,"hidden":false},{"address":"0x2002","class":"kaze-mirror-tui","initialClass":"kaze-mirror-tui","title":"Kaze Mirror Optimizer","workspace":{"id":2,"name":"2"},"focusHistoryID":1,"mapped":true,"hidden":false}]',
        '{"address":"0x1001","class":"foot","initialClass":"foot","title":"foot","workspace":{"id":1,"name":"1"},"focusHistoryID":0}'
      )
      local r_focus = sb:run(args, hypr_env)
      assert_eq(r_focus.code, 0, "--tui-window --auto-run focus must exit 0")
      assert_eq(#sb:parse_arg_calls("footclient.log"), 0, "must NOT spawn second footclient")
      assert_eq(#sb:parse_arg_calls("foot.log"), 0, "must NOT spawn foot")
      local hlog_focus = sb:log_content("hyprctl.log") or ""
      assert_contains(hlog_focus, "dispatch", "must call hyprctl dispatch to focus existing window")
      assert_true(hlog_focus:lower():find("focus", 1, true) ~= nil, "hyprctl dispatch must focus window (log=" .. hlog_focus .. ")")

      -- 11c. Exists & IS active window with --auto-run -> focuses (does not close an explicit menu/auto-run action)
      sb:reset_logs()
      sb:set_hyprctl(
        '[{"address":"0x2002","class":"kaze-mirror-tui","initialClass":"kaze-mirror-tui","title":"Kaze Mirror Optimizer","workspace":{"id":2,"name":"2"},"focusHistoryID":0,"mapped":true,"hidden":false},{"address":"0x1001","class":"foot","initialClass":"foot","title":"foot","workspace":{"id":1,"name":"1"},"focusHistoryID":1,"mapped":true,"hidden":false}]',
        '{"address":"0x2002","class":"kaze-mirror-tui","initialClass":"kaze-mirror-tui","title":"Kaze Mirror Optimizer","workspace":{"id":2,"name":"2"},"focusHistoryID":0}'
      )
      local r_active = sb:run(args, hypr_env)
      assert_eq(r_active.code, 0, "--tui-window --auto-run active must exit 0")
      assert_eq(#sb:parse_arg_calls("footclient.log"), 0, "must NOT spawn footclient when active")
      assert_eq(#sb:parse_arg_calls("foot.log"), 0, "must NOT spawn foot when active")
      local hlog_active = sb:log_content("hyprctl.log") or ""
      assert_contains(hlog_active, "dispatch", "must call hyprctl dispatch when active")
      assert_true(
        hlog_active:lower():find("focus", 1, true) ~= nil,
        "--tui-window --auto-run when active focuses existing window instead of closing it (actual log=" .. hlog_active .. ")"
      )

      sb:assert_no_blocked(assert_eq, "--tui-window --auto-run")
    end)
  end)

  -- 12. Offline --pacman-conf parsing edge cases (nonexistent + skipped/unmanaged repos only)
  test("bb.mirror.offline_pacman_conf_errors_and_unmanaged", function()
    with_sandbox(bin_path, function(sb)
      -- 12a. Nonexistent pacman.conf fails cleanly
      local missing_pc = sb.dir .. "/nonexistent/pacman.conf"
      local r_miss = sb:run({ "--pacman-conf", missing_pc, "--dry-run" })
      assert_true(r_miss.code ~= 0, "nonexistent --pacman-conf must exit non-zero")
      assert_true(not r_miss.stderr:find("stack traceback:", 1, true), "nonexistent --pacman-conf must not Lua-crash")

      local r_miss_json = sb:run({ "--pacman-conf=" .. missing_pc, "--dry-run", "--json" })
      assert_true(r_miss_json.code ~= 0, "nonexistent --pacman-conf --json must exit non-zero")
      assert_true(not r_miss_json.stderr:find("stack traceback:", 1, true), "nonexistent --json must not Lua-crash")

      -- 12b. pacman.conf with ONLY skipped / unmanaged repos
      local ml_chaotic = sb.root .. "/etc/pacman.d/chaotic-mirrorlist"
      local ml_core = sb.root .. "/etc/pacman.d/mirrorlist"
      write_file(ml_chaotic, "Server = https://chaotic.example.invalid/$repo/$arch\n")
      write_file(ml_core, DEFAULT_MIRRORLIST)

      local unmanaged_pc = sb.dir .. "/unmanaged_pacman.conf"
      write_file(unmanaged_pc, table.concat({
        "[options]",
        "ParallelDownloads = 5",
        "",
        "[chaotic-aur]",
        "Include = " .. ml_chaotic,
        "",
        "[core]",
        "Include = " .. sb.root .. "/etc/pacman.d/mirror*",
        "",
        "[extra]",
        "Server = https://inline-conflict.example.invalid/$repo/os/$arch",
        "Include = " .. ml_core,
        "",
        "[multilib]",
        "Server = https://inline-only.example.invalid/$repo/os/$arch",
        "",
      }, "\n"))

      for _, mode_args in ipairs({
        { "--pacman-conf", unmanaged_pc, "--dry-run" },
        { "--pacman-conf", unmanaged_pc, "--fast", "--dry-run" },
        { "--pacman-conf", unmanaged_pc, "--dry-run", "--json" },
      }) do
        local r = sb:run(mode_args)
        assert_true(not r.stderr:find("stack traceback:", 1, true), "unmanaged-only pacman.conf must not crash: " .. r.stderr)
        assert_true(r.code == 0 or r.code == 1, "unmanaged-only pacman.conf must exit cleanly (0 or 1), got " .. tostring(r.code))
        assert_true(#r.output > 0, "unmanaged-only pacman.conf must report status/no managed groups")
      end

      -- 12c. Empty pacman.conf (no repos at all)
      local empty_pc = sb.dir .. "/empty_pacman.conf"
      write_file(empty_pc, "[options]\nParallelDownloads = 5\n")
      local r_empty = sb:run({ "--pacman-conf", empty_pc, "--dry-run" })
      assert_true(not r_empty.stderr:find("stack traceback:", 1, true), "empty-repos pacman.conf must not crash")
      assert_true(r_empty.code == 0 or r_empty.code == 1, "empty-repos pacman.conf must exit cleanly (0 or 1), got " .. tostring(r_empty.code))

      sb:assert_no_blocked(assert_eq, "offline pacman.conf edge cases")
    end)
  end)

  -- 13. --tui interactive PTY smoke test (real controlling /dev/tty via pty.fork, quits cleanly on 'q')
  test("bb.mirror.tui_pty_smoke_and_quit", function()
    with_sandbox(bin_path, function(sb)
      local sandbox_pc, orig_ml = sb:seed_root()
      local ml_path = sb.root .. "/etc/pacman.d/mirrorlist"
      local pc_path = sb.root .. "/etc/pacman.conf"

      local pty_driver = sb.dir .. "/pty_driver.py"
      write_file(pty_driver, table.concat({
        "import fcntl, os, pty, select, signal, struct, sys, termios, time",
        "cmd = sys.argv[1:]",
        "pid, master = pty.fork()",
        "if pid == 0:",
        "    try:",
        "        fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 100, 0, 0))",
        "    except OSError:",
        "        pass",
        "    os.execvp(cmd[0], cmd)",
        "    os._exit(127)",
        "try:",
        "    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 100, 0, 0))",
        "except OSError:",
        "    pass",
        "buf = bytearray()",
        "start = time.monotonic()",
        "deadline = start + 3.0",
        "last_rx = None",
        "last_q = 0.0",
        "exit_status = None",
        "while time.monotonic() < deadline:",
        "    wpid, status = os.waitpid(pid, os.WNOHANG)",
        "    if wpid == pid:",
        "        exit_status = status",
        "        while True:",
        "            r, _, _ = select.select([master], [], [], 0.05)",
        "            if not r: break",
        "            try:",
        "                chunk = os.read(master, 8192)",
        "                if not chunk: break",
        "                buf.extend(chunk)",
        "            except OSError:",
        "                break",
        "        break",
        "    r, _, _ = select.select([master], [], [], 0.05)",
        "    if r:",
        "        try:",
        "            chunk = os.read(master, 8192)",
        "            if chunk:",
        "                buf.extend(chunk)",
        "                last_rx = time.monotonic()",
        "        except OSError:",
        "            pass",
        "    now = time.monotonic()",
        "    rendered = (b'Dashboard' in buf) or (b'MIRROR' in buf) or (now - start >= 0.6)",
        "    settled = (last_rx is not None and (now - last_rx) >= 0.12) or (now - start >= 0.6)",
        "    if rendered and settled and (now - last_q) >= 0.25:",
        "        os.write(master, b'q')",
        "        last_q = now",
        "if exit_status is None:",
        "    try: os.killpg(pid, signal.SIGTERM)",
        "    except OSError: pass",
        "    time.sleep(0.1)",
        "    wpid, status = os.waitpid(pid, os.WNOHANG)",
        "    if wpid == 0:",
        "        try: os.killpg(pid, signal.SIGKILL)",
        "        except OSError: pass",
        "        os.waitpid(pid, 0)",
        "    rc = 124",
        "elif os.WIFEXITED(exit_status):",
        "    rc = os.WEXITSTATUS(exit_status)",
        "elif os.WIFSIGNALED(exit_status):",
        "    rc = 128 + os.WTERMSIG(exit_status)",
        "else:",
        "    rc = 1",
        "os.close(master)",
        "sys.stdout.buffer.write(buf)",
        "sys.exit(rc)",
        "",
      }, "\n"))

      local out_f = sb.dir .. "/pty.out"
      local cmd = sb:env_prefix()
        .. " python3 " .. sq(pty_driver)
        .. " " .. sq(bin_path)
        .. " --tui --pacman-conf " .. sq(pc_path)
        .. " --test-root " .. sq(sb.root)
        .. " >" .. sq(out_f) .. " 2>&1"
      local rc = exec_code(cmd)
      local transcript = read_file(out_f) or ""

      assert_true(rc ~= 124, "--tui in PTY hung after sending 'q' (output=" .. transcript:sub(1, 300) .. ")")
      assert_eq(rc, 0, "--tui in PTY must exit 0 cleanly on 'q' (got " .. tostring(rc) .. ", output=" .. transcript:sub(1, 300) .. ")")
      assert_true(#transcript > 20, "--tui must render initial UI output to PTY")
      assert_true(not transcript:find("stack traceback:", 1, true), "--tui must not emit Lua stack traceback")
      assert_true(not transcript:find("/dev/tty: No such device", 1, true), "PTY controlling terminal must be attached cleanly")

      -- Also verify headless (no controlling TTY, detached session) --tui exits promptly without hanging
      local nontty_cmd = sb:env_prefix()
        .. " timeout 2 setsid -w " .. sq(bin_path)
        .. " --tui --pacman-conf " .. sq(pc_path)
        .. " --test-root " .. sq(sb.root)
        .. " </dev/null >/dev/null 2>&1"
      local nontty_rc = exec_code(nontty_cmd)
      assert_true(nontty_rc ~= 124, "--tui without a controlling TTY must not hang (got timeout 124)")

      -- Ensure files were not mutated and no network/sudo occurred during idle TUI + quit
      assert_eq(read_file(ml_path), orig_ml, "--tui idle+quit must not mutate mirrorlist")
      assert_eq(read_file(pc_path), sandbox_pc, "--tui idle+quit must not mutate pacman.conf")
      sb:assert_no_blocked(assert_eq, "--tui PTY")
    end)
  end)
end

return run_suite
