-- Blind black-box & brute-force behavioral test suite for:
--   1. scripts/apply.sh & generated rollback.sh
--   2. bin/kaze-doctor (full offline & live diagnostic matrix)
--   3. hypr/hyprland.lua (isolated Lua evaluation with mocked `hl`)
--
-- Derived strictly from the Behavioral Specification; uses only Lua stdlib.

local function sh_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function exec_code(cmd)
  local ok, why, code = os.execute(cmd)
  if ok == true then
    return 0
  end
  if why == "exit" and type(code) == "number" then
    return code
  end
  return 128 + (tonumber(code) or 1)
end

local function popen_read(cmd)
  local fh = assert(io.popen(cmd, "r"))
  local out = fh:read("*a") or ""
  local ok, why, code = fh:close()
  local rc = (ok == true) and 0 or ((why == "exit" and tonumber(code)) or 1)
  return out, rc
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
  local fh = io.open(path, "wb")
  if not fh then
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" then
      exec_code("/usr/bin/mkdir -p -- " .. sh_quote(parent))
    end
    fh = assert(io.open(path, "wb"))
  end
  fh:write(content)
  fh:close()
end

local function is_symlink(path)
  return exec_code("/usr/bin/test -L " .. sh_quote(path)) == 0
end

local function is_file(path)
  return exec_code("/usr/bin/test -f " .. sh_quote(path)) == 0
end

local function is_regular_non_symlink(path)
  return is_file(path) and not is_symlink(path)
end

local function is_dir(path)
  return exec_code("/usr/bin/test -d " .. sh_quote(path)) == 0
end

local function is_executable(path)
  return exec_code("/usr/bin/test -x " .. sh_quote(path)) == 0
end

local function path_exists(path)
  return exec_code("/usr/bin/test -e " .. sh_quote(path)) == 0
end

local function lexists(path)
  return path_exists(path) or is_symlink(path)
end

local function readlink_raw(path)
  local out, rc = popen_read("/usr/bin/readlink -- " .. sh_quote(path) .. " 2>/dev/null")
  if rc ~= 0 then
    return nil
  end
  return (out:gsub("\n$", ""))
end

local function list_entries(dir, prefix)
  if not is_dir(dir) then
    return {}
  end
  local out, rc = popen_read("/usr/bin/ls -A1 -- " .. sh_quote(dir) .. " 2>/dev/null")
  if rc ~= 0 then
    return {}
  end
  local items = {}
  for line in out:gmatch("[^\n]+") do
    if not prefix or line:sub(1, #prefix) == prefix then
      items[#items + 1] = line
    end
  end
  table.sort(items)
  return items
end

local function count_occurrences(haystack, needle)
  if type(haystack) ~= "string" or needle == "" then
    return 0
  end
  local count = 0
  local start = 1
  while true do
    local i, j = haystack:find(needle, start, true)
    if not i then
      break
    end
    count = count + 1
    start = j + 1
  end
  return count
end

local function resolve_abs_dir(dir)
  local out, rc = popen_read("cd -- " .. sh_quote(dir) .. " && pwd -P")
  assert(rc == 0, "failed to resolve repo_dir: " .. tostring(dir))
  return (out:gsub("\n$", ""))
end

local function create_unix_socket(path)
  local parent = path:match("^(.*)/[^/]+$")
  if parent and parent ~= "" then
    exec_code("/usr/bin/mkdir -p -- " .. sh_quote(parent))
  end
  local py = "import socket,sys; s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.bind(sys.argv[1]); s.close()"
  local rc = exec_code("/usr/bin/python3 -c " .. sh_quote(py) .. " " .. sh_quote(path))
  assert(rc == 0, "failed to create unix socket at " .. path)
end

local COREUTILS_WHITELIST = {
  "sh", "bash", "env", "readlink", "realpath", "diff", "cmp", "cat", "ls", "stat",
  "mkdir", "rm", "cp", "mv", "chmod", "ln", "grep", "sed", "awk", "sort", "tr",
  "cut", "head", "tail", "wc", "find", "basename", "dirname", "id", "uname",
  "mktemp", "date", "locale", "test", "[", "true", "false", "printf", "expr",
  "touch", "uniq", "tee", "xargs", "sleep", "pwd", "which", "dirname",
}

local MINIMAL_BINS = {
  "hyprland", "hyprctl", "noctalia", "notify-send", "foot", "footclient", "zsh",
  "wl-copy", "wl-paste", "wpctl", "brightnessctl", "playerctl", "lua", "busctl",
  "systemctl", "flock",
}

local FULL_EXTRA_BINS = {
  "slurp", "wf-recorder", "ffmpeg", "ffprobe", "hyprpicker", "thunar", "yazi",
  "imv", "zathura", "gnome-keyring-daemon", "fcitx5", "fzf", "zoxide", "eza",
  "bat", "rg", "fd", "starship", "wl-mirror",
}

local EXISTING_COREUTILS = nil

local function get_existing_coreutils()
  if EXISTING_COREUTILS then
    return EXISTING_COREUTILS
  end
  EXISTING_COREUTILS = {}
  local seen = {}
  for _, name in ipairs(COREUTILS_WHITELIST) do
    if not seen[name] then
      seen[name] = true
      local src = "/usr/bin/" .. name
      local fh = io.open(src, "rb")
      if fh then
        fh:close()
        EXISTING_COREUTILS[#EXISTING_COREUTILS + 1] = src
      end
    end
  end
  return EXISTING_COREUTILS
end

local function populate_corebin(corebin_dir)
  local cmd = { "/usr/bin/mkdir -p -- " .. sh_quote(corebin_dir), "&& /usr/bin/ln -sf -t " .. sh_quote(corebin_dir) .. " --" }
  for _, src in ipairs(get_existing_coreutils()) do
    cmd[#cmd + 1] = sh_quote(src)
  end
  assert(exec_code(table.concat(cmd, " ")) == 0, "failed to populate corebin")
end

local function install_safety_stubs(sb)
  local created = {}
  local function add_stub(name, content)
    local p = sb.bin .. "/" .. name
    write_file(p, content)
    created[#created + 1] = sh_quote(p)
  end

  -- Hard-block dangerous system commands so host mutation is impossible.
  for _, name in ipairs({ "sudo", "pacman", "usermod", "chsh", "makepkg", "curl" }) do
    add_stub(name, string.format([[#!/usr/bin/sh
echo "BLOCKED:%s:$*" >> %s
exit 99
]], name, sh_quote(sb.log)))
  end

  -- Benign no-op desktop refresh commands.
  for _, name in ipairs({ "fc-cache", "update-desktop-database", "xdg-mime", "notify-send" }) do
    add_stub(name, string.format([[#!/usr/bin/sh
echo "STUB:%s:$*" >> %s
exit 0
]], name, sh_quote(sb.log)))
  end

  -- Configurable systemctl stub (supports per-unit is-active list).
  write_file(sb.state_dir .. "/systemctl_active_units", "")
  write_file(sb.state_dir .. "/systemctl_env", "")
  write_file(sb.state_dir .. "/systemctl_env_rc", "0\n")
  add_stub("systemctl", string.format([[#!/usr/bin/sh
echo "STUB:systemctl:$*" >> %s
has_is_active=0
has_show_env=0
unit=""
for arg in "$@"; do
  case "$arg" in
    is-active) has_is_active=1 ;;
    show-environment) has_show_env=1 ;;
    -*) ;;
    *)
      if [ "$has_is_active" = "1" ]; then
        unit="$arg"
      fi
      ;;
  esac
done
if [ "$has_is_active" = "1" ]; then
  if [ -n "$unit" ] && /usr/bin/grep -Fxq -- "$unit" %s 2>/dev/null; then
    exit 0
  fi
  exit 3
fi
if [ "$has_show_env" = "1" ]; then
  rc=$(/usr/bin/cat %s 2>/dev/null || echo 0)
  /usr/bin/cat %s 2>/dev/null
  exit "$rc"
fi
exit 0
]], sh_quote(sb.log),
    sh_quote(sb.state_dir .. "/systemctl_active_units"),
    sh_quote(sb.state_dir .. "/systemctl_env_rc"),
    sh_quote(sb.state_dir .. "/systemctl_env")))

  -- Configurable hyprctl stub.
  write_file(sb.state_dir .. "/hyprctl_configerrors", "")
  write_file(sb.state_dir .. "/hyprctl_configerrors_rc", "0\n")
  add_stub("hyprctl", string.format([[#!/usr/bin/sh
echo "STUB:hyprctl:$*" >> %s
for arg in "$@"; do
  if [ "$arg" = "configerrors" ]; then
    /usr/bin/cat %s 2>/dev/null
    rc=$(/usr/bin/cat %s 2>/dev/null || echo 0)
    exit "$rc"
  fi
done
echo "ok"
exit 0
]], sh_quote(sb.log),
    sh_quote(sb.state_dir .. "/hyprctl_configerrors"),
    sh_quote(sb.state_dir .. "/hyprctl_configerrors_rc")))

  -- Configurable busctl stub.
  write_file(sb.state_dir .. "/busctl_activatable", "")
  write_file(sb.state_dir .. "/busctl_rc", "0\n")
  add_stub("busctl", string.format([[#!/usr/bin/sh
echo "STUB:busctl:$*" >> %s
/usr/bin/cat %s 2>/dev/null
rc=$(/usr/bin/cat %s 2>/dev/null || echo 0)
exit "$rc"
]], sh_quote(sb.log),
    sh_quote(sb.state_dir .. "/busctl_activatable"),
    sh_quote(sb.state_dir .. "/busctl_rc")))

  -- Configurable ps stub handling `-o comm=`, `-o args=`, `-o pid=,comm=`, `-C <name>`, etc.
  write_file(sb.state_dir .. "/ps_procs", "")
  add_stub("ps", string.format([[#!/usr/bin/sh
procs_file=%s
mode="table"
filter=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-C" ]; then
    filter="$arg"
    prev=""
    continue
  fi
  if [ "$prev" = "-o" ]; then
    case "$arg" in
      *pid*comm*|*pid*args*) mode="pid_comm" ;;
      *comm=*|*args=*|*cmd=*) mode="comm_bare" ;;
      *comm*|*args*|*cmd*) mode="comm_hdr" ;;
      *pid=*) mode="pid_bare" ;;
      *pid*) mode="pid_hdr" ;;
    esac
    prev=""
    continue
  fi
  case "$arg" in
    -C) prev="-C" ;;
    -o) prev="-o" ;;
    -o*)
      spec="${arg#-o}"
      case "$spec" in
        *pid*comm*|*pid*args*) mode="pid_comm" ;;
        *comm=*|*args=*|*cmd=*) mode="comm_bare" ;;
        *comm*|*args*|*cmd*) mode="comm_hdr" ;;
        *pid=*) mode="pid_bare" ;;
        *pid*) mode="pid_hdr" ;;
      esac
      ;;
  esac
done
if [ "$mode" = "comm_hdr" ]; then
  echo "COMMAND"
elif [ "$mode" = "pid_hdr" ]; then
  echo "PID"
elif [ "$mode" = "table" ]; then
  echo "  PID TTY          TIME CMD"
fi
pid=1000
while IFS= read -r proc; do
  [ -z "$proc" ] && continue
  if [ -n "$filter" ] && [ "$proc" != "$filter" ]; then
    continue
  fi
  pid=$((pid + 1))
  case "$mode" in
    comm_bare|comm_hdr) echo "$proc" ;;
    pid_bare|pid_hdr) echo "$pid" ;;
    pid_comm) echo "$pid $proc" ;;
    *) echo " $pid ?        00:00:00 $proc" ;;
  esac
done < "$procs_file"
exit 0
]], sh_quote(sb.state_dir .. "/ps_procs")))

  -- Configurable noctalia, foot, zsh config-check stubs.
  write_file(sb.state_dir .. "/noctalia_validate_rc", "0\n")
  add_stub("noctalia", string.format([[#!/usr/bin/sh
echo "STUB:noctalia:$*" >> %s
for arg in "$@"; do
  if [ "$arg" = "validate" ]; then
    rc=$(/usr/bin/cat %s 2>/dev/null || echo 0)
    if [ "$rc" != "0" ]; then
      echo "noctalia config invalid" >&2
    fi
    exit "$rc"
  fi
done
exit 0
]], sh_quote(sb.log), sh_quote(sb.state_dir .. "/noctalia_validate_rc")))

  write_file(sb.state_dir .. "/foot_check_rc", "0\n")
  add_stub("foot", string.format([[#!/usr/bin/sh
echo "STUB:foot:$*" >> %s
for arg in "$@"; do
  if [ "$arg" = "--check-config" ]; then
    rc=$(/usr/bin/cat %s 2>/dev/null || echo 0)
    if [ "$rc" != "0" ]; then
      echo "foot config invalid" >&2
    fi
    exit "$rc"
  fi
done
exit 0
]], sh_quote(sb.log), sh_quote(sb.state_dir .. "/foot_check_rc")))

  write_file(sb.state_dir .. "/zsh_check_rc", "0\n")
  add_stub("zsh", string.format([[#!/usr/bin/sh
echo "STUB:zsh:$*" >> %s
for arg in "$@"; do
  if [ "$arg" = "-n" ]; then
    rc=$(/usr/bin/cat %s 2>/dev/null || echo 0)
    if [ "$rc" != "0" ]; then
      echo "zsh syntax error" >&2
    fi
    exit "$rc"
  fi
done
exit 0
]], sh_quote(sb.log), sh_quote(sb.state_dir .. "/zsh_check_rc")))

  assert(exec_code("/usr/bin/chmod +x -- " .. table.concat(created, " ")) == 0, "batch chmod +x failed")
end

local function install_dummy_bins(sb, names)
  local to_chmod = {}
  for _, name in ipairs(names) do
    local p = sb.bin .. "/" .. name
    local fh = io.open(p, "rb")
    if fh then
      fh:close()
    else
      if name == "lua" then
        assert(exec_code("/usr/bin/ln -sf /usr/bin/lua " .. sh_quote(p)) == 0)
      else
        local out = assert(io.open(p, "wb"))
        out:write("#!/usr/bin/sh\nexit 0\n")
        out:close()
        to_chmod[#to_chmod + 1] = sh_quote(p)
      end
    end
  end
  if #to_chmod > 0 then
    assert(exec_code("/usr/bin/chmod +x -- " .. table.concat(to_chmod, " ")) == 0)
  end
end

local function create_sandbox(opts)
  opts = opts or {}
  local out, rc = popen_read("/usr/bin/mktemp -d /tmp/kaze-bb-adh-XXXXXX")
  assert(rc == 0, "mktemp failed")
  local root = (out:gsub("\n$", ""))
  local sb = {
    root = root,
    bin = root .. "/bin",
    corebin = root .. "/corebin",
    state_dir = root .. "/stub-state",
    log = root .. "/stub.log",
    fake_etc = root .. "/fake-etc",
    fake_drm = root .. "/fake-drm",
  }
  if opts.with_spaces then
    sb.home = root .. "/my home dir"
    sb.config = root .. "/my xdg config"
    sb.data = root .. "/my xdg data"
    sb.cache = root .. "/my xdg cache"
    sb.state = root .. "/my xdg state"
    sb.runtime = root .. "/my xdg run"
  else
    sb.home = root .. "/home"
    sb.config = sb.home .. "/.config"
    sb.data = sb.home .. "/.local/share"
    sb.cache = sb.home .. "/.cache"
    sb.state = sb.home .. "/.local/state"
    sb.runtime = root .. "/run"
  end

  local mkdirs = {
    sb.bin, sb.state_dir, sb.fake_etc, sb.fake_drm,
    sb.home, sb.config, sb.data, sb.cache, sb.state, sb.runtime,
  }
  local mkdir_cmd = { "/usr/bin/mkdir", "-p", "--" }
  for _, d in ipairs(mkdirs) do
    mkdir_cmd[#mkdir_cmd + 1] = sh_quote(d)
  end
  assert(exec_code(table.concat(mkdir_cmd, " ")) == 0, "mkdir failed")
  populate_corebin(sb.corebin)
  install_safety_stubs(sb)
  if opts.minimal_bins then
    install_dummy_bins(sb, MINIMAL_BINS)
  end
  if opts.full_bins then
    install_dummy_bins(sb, MINIMAL_BINS)
    install_dummy_bins(sb, FULL_EXTRA_BINS)
  end
  return sb
end

local function cleanup_dir(dir)
  if dir and dir:match("^/tmp/kaze%-bb%-adh%-") then
    exec_code("/usr/bin/rm -rf -- " .. sh_quote(dir))
  end
end

local function with_sandbox(opts, fn)
  local sb = create_sandbox(opts)
  local ok, err = pcall(fn, sb)
  cleanup_dir(sb.root)
  if not ok then
    error(err, 0)
  end
end

local function run_cmd(sb, argv, opts)
  opts = opts or {}
  local env_map = {
    HOME = sb.home,
    XDG_CONFIG_HOME = sb.config,
    XDG_DATA_HOME = sb.data,
    XDG_CACHE_HOME = sb.cache,
    XDG_STATE_HOME = sb.state,
    XDG_RUNTIME_DIR = sb.runtime,
    USER = "kazetest",
    LOGNAME = "kazetest",
    TERM = "xterm-256color",
    LANG = "en_US.UTF-8",
    PATH = sb.bin .. ":" .. sb.corebin,
    KAZE_ARCH_RELEASE_FILE = sb.fake_etc .. "/arch-release",
    KAZE_SYS_DRM_DIR = sb.fake_drm,
    KAZE_GREETD_CONFIG = sb.fake_etc .. "/greetd-config.toml",
    KAZE_SYSTEMD_ETC_DIR = sb.fake_etc .. "/systemd",
    KAZE_AUR_BASE_URL = "http://127.0.0.1:1/disabled",
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

  local out_file = sb.root .. "/cmd.out"
  local err_file = sb.root .. "/cmd.err"
  local in_redir = ""
  if opts.stdin ~= nil then
    local in_file = sb.root .. "/cmd.in"
    write_file(in_file, opts.stdin)
    in_redir = " < " .. sh_quote(in_file)
  else
    in_redir = " < /dev/null"
  end

  local parts = { "/usr/bin/env -i" }
  local keys = {}
  for k in pairs(env_map) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  for _, k in ipairs(keys) do
    parts[#parts + 1] = sh_quote(k .. "=" .. env_map[k])
  end
  for _, arg in ipairs(argv) do
    parts[#parts + 1] = sh_quote(arg)
  end

  local cmd = table.concat(parts, " ") .. in_redir
    .. " > " .. sh_quote(out_file) .. " 2> " .. sh_quote(err_file)
  if opts.cwd then
    cmd = "cd -- " .. sh_quote(opts.cwd) .. " && " .. cmd
  end

  local rc = exec_code(cmd)
  local stdout = read_file(out_file) or ""
  local stderr = read_file(err_file) or ""
  return {
    rc = rc,
    stdout = stdout,
    stderr = stderr,
    combined = stdout .. stderr,
  }
end

local function set_live_healthy(sb, opts)
  opts = opts or {}
  local sig = opts.sig or "kaze-live-sig-42"
  local display = opts.wayland_display or "wayland-1"
  local desktop = opts.xdg_current_desktop or "Hyprland"

  write_file(sb.state_dir .. "/hyprctl_configerrors", opts.configerrors or "")
  write_file(sb.state_dir .. "/hyprctl_configerrors_rc", tostring(opts.configerrors_rc or 0) .. "\n")

  local active_units = opts.active_units or {
    "pipewire.service",
    "wireplumber.service",
    "pipewire-pulse.socket",
  }
  write_file(sb.state_dir .. "/systemctl_active_units", table.concat(active_units, "\n") .. "\n")

  local sys_env_lines = opts.systemctl_env_lines or {
    "WAYLAND_DISPLAY=" .. display,
    "HYPRLAND_INSTANCE_SIGNATURE=" .. sig,
    "XDG_CURRENT_DESKTOP=" .. desktop,
  }
  write_file(sb.state_dir .. "/systemctl_env", table.concat(sys_env_lines, "\n") .. "\n")
  write_file(sb.state_dir .. "/systemctl_env_rc", tostring(opts.systemctl_env_rc or 0) .. "\n")

  local services = opts.bus_services or {
    "org.freedesktop.portal.Desktop",
    "org.freedesktop.impl.portal.desktop.hyprland",
    "org.freedesktop.impl.portal.desktop.gtk",
    "org.freedesktop.secrets",
  }
  local bus_lines = {}
  for _, svc in ipairs(services) do
    bus_lines[#bus_lines + 1] = svc .. " - - - (activatable) - - -"
  end
  write_file(sb.state_dir .. "/busctl_activatable", table.concat(bus_lines, "\n") .. "\n")
  write_file(sb.state_dir .. "/busctl_rc", tostring(opts.busctl_rc or 0) .. "\n")

  local procs = opts.procs or { "noctalia", "foot", "fcitx5" }
  write_file(sb.state_dir .. "/ps_procs", table.concat(procs, "\n") .. "\n")

  return {
    HYPRLAND_INSTANCE_SIGNATURE = sig,
    WAYLAND_DISPLAY = display,
    XDG_CURRENT_DESKTOP = desktop,
    LANG = opts.lang or "en_US.UTF-8",
  }
end

local function set_procs(sb, counts)
  local lines = {}
  for name, n in pairs(counts) do
    for _ = 1, n do
      lines[#lines + 1] = name
    end
  end
  table.sort(lines)
  write_file(sb.state_dir .. "/ps_procs", table.concat(lines, "\n") .. "\n")
end

-- Recursively inspect arbitrary captured `hl.*` arguments / tables.
local function value_contains_str(val, needle, exact)
  local t = type(val)
  if t == "string" then
    if exact then
      return val == needle
    end
    return val:find(needle, 1, true) ~= nil
  elseif t == "number" or t == "boolean" then
    return tostring(val) == tostring(needle)
  elseif t == "table" then
    for k, v in pairs(val) do
      if value_contains_str(k, needle, exact) or value_contains_str(v, needle, exact) then
        return true
      end
    end
  end
  return false
end

local function value_has_kv(val, target_k, target_v)
  if type(val) ~= "table" then
    return false
  end
  for k, v in pairs(val) do
    if k == target_k then
      if target_v == nil then
        return true
      end
      if v == target_v or tostring(v) == tostring(target_v) then
        return true
      end
    end
    if type(v) == "table" and value_has_kv(v, target_k, target_v) then
      return true
    end
  end
  return false
end

local function list_has_matching_entry(list, pred)
  for _, item in ipairs(list or {}) do
    if pred(item) then
      return true
    end
  end
  return false
end

local function eval_hyprland_lua(sb, abs_repo, extra_env)
  local result_file = sb.root .. "/hypr_capture.lua"
  local harness_file = sb.root .. "/hypr_harness.lua"
  local target_file = abs_repo .. "/hypr/hyprland.lua"

  local harness = [[
local result_path = arg[1]
local target_path = arg[2]

local state = {
  env = {},
  config = {},
  calls = {
    config = {},
    env = {},
    monitor = {},
    window_rule = {},
    workspace_rule = {},
    layer_rule = {},
    bind = {},
    bind_mouse = {},
    bind_release = {},
    submap = {},
    gesture = {},
    curve = {},
    animation = {},
    on = {},
    exec_cmd = {},
    dispatch = {},
    dsp = {},
  },
  markers = {},
}

local function merge_into(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" and type(dst[k]) == "table" then
      merge_into(dst[k], v)
    else
      dst[k] = v
    end
  end
end

local function record(kind)
  return function(...)
    local args = { ... }
    state.calls[kind][#state.calls[kind] + 1] = args
    return args
  end
end

local dsp_paths = {}
local function make_dsp_proxy(prefix)
  local proxy = {}
  dsp_paths[proxy] = prefix or "dsp"
  return setmetatable(proxy, {
    __index = function(_, key)
      local path = prefix and (prefix .. "." .. tostring(key)) or tostring(key)
      return make_dsp_proxy(path)
    end,
    __call = function(_, ...)
      local entry = { name = prefix or "", args = { ... } }
      state.calls.dsp[#state.calls.dsp + 1] = entry
      return entry
    end,
  })
end

hl = {
  config = function(a, b)
    state.calls.config[#state.calls.config + 1] = { a, b }
    if type(a) == "table" then
      merge_into(state.config, a)
    elseif a ~= nil then
      state.config[a] = b
    end
  end,
  env = function(a, b)
    state.calls.env[#state.calls.env + 1] = { a, b }
    if type(a) == "table" then
      for k, v in pairs(a) do
        if type(k) == "string" then
          state.env[k] = tostring(v)
        elseif type(v) == "string" then
          local ek, ev = v:match("^([^,=]+)[,=](.*)$")
          if ek then
            state.env[ek] = ev
          end
        end
      end
    elseif type(a) == "string" then
      if b ~= nil then
        state.env[a] = tostring(b)
      else
        local ek, ev = a:match("^([^,=]+)[,=](.*)$")
        if ek then
          state.env[ek] = ev
        end
      end
    end
  end,
  monitor = record("monitor"),
  window_rule = record("window_rule"),
  workspace_rule = record("workspace_rule"),
  layer_rule = record("layer_rule"),
  bind = record("bind"),
  bind_mouse = record("bind_mouse"),
  bind_release = record("bind_release"),
  submap = function(name, fn)
    state.calls.submap[#state.calls.submap + 1] = { name }
    if type(fn) == "function" then
      fn()
    end
  end,
  gesture = record("gesture"),
  curve = record("curve"),
  animation = record("animation"),
  on = function(ev, fn)
    state.calls.on[#state.calls.on + 1] = { event = ev, has_fn = (type(fn) == "function") }
  end,
  exec_cmd = record("exec_cmd"),
  dispatch = record("dispatch"),
  dsp = make_dsp_proxy(nil),
}

_G._KAZE_BB_MARKERS = state.markers

local ok, err = pcall(dofile, target_path)
state.ok = ok
state.err = ok and nil or tostring(err)

local function serialize(v, seen)
  local t = type(v)
  if t == "nil" then
    return "nil"
  elseif t == "boolean" or t == "number" then
    return tostring(v)
  elseif t == "string" then
    return string.format("%q", v)
  elseif t == "table" then
    if dsp_paths[v] then
      return string.format("%q", "<dsp:" .. dsp_paths[v] .. ">")
    end
    seen = seen or {}
    if seen[v] then
      return '"<cycle>"'
    end
    seen[v] = true
    local out = { "{" }
    for k, val in pairs(v) do
      local ks
      if type(k) == "string" then
        ks = "[" .. string.format("%q", k) .. "]"
      elseif type(k) == "number" then
        ks = "[" .. tostring(k) .. "]"
      else
        ks = "[" .. string.format("%q", tostring(k)) .. "]"
      end
      out[#out + 1] = ks .. "=" .. serialize(val, seen) .. ","
    end
    out[#out + 1] = "}"
    seen[v] = nil
    return table.concat(out)
  else
    return string.format("%q", "<" .. t .. ">")
  end
end

local fh = assert(io.open(result_path, "wb"))
fh:write("return " .. serialize(state) .. "\n")
fh:close()

if not ok then
  io.stderr:write(tostring(err) .. "\n")
  os.exit(1)
end
]]

  write_file(harness_file, harness)
  local res = run_cmd(sb, { "/usr/bin/lua", harness_file, result_file, target_file }, { env = extra_env })
  local data = nil
  if is_file(result_file) then
    local chunk, lerr = loadfile(result_file)
    assert(chunk, "failed to load serialized hypr capture: " .. tostring(lerr))
    data = chunk()
  end
  return res, data
end

local function count_persistent_workspaces(calls_ws)
  local count = 0
  for _, call in ipairs(calls_ws or {}) do
    if value_has_kv(call, "persistent", true) or value_contains_str(call, "persistent:true") then
      count = count + 1
    end
  end
  return count
end

local function run_suite(test, assert_eq, assert_true, assert_contains, repo_dir)
  local abs_repo = resolve_abs_dir(repo_dir or ".")
  local apply_sh = abs_repo .. "/scripts/apply.sh"
  local doctor_bin = abs_repo .. "/bin/kaze-doctor"

  local function run_apply(sb, args, opts)
    local argv = { "/usr/bin/sh", apply_sh }
    for _, a in ipairs(args or {}) do
      argv[#argv + 1] = a
    end
    return run_cmd(sb, argv, opts)
  end

  local function run_doctor(sb, args, opts)
    local argv = { "/usr/bin/lua", doctor_bin }
    for _, a in ipairs(args or {}) do
      argv[#argv + 1] = a
    end
    return run_cmd(sb, argv, opts)
  end

  -- =========================================================================
  -- 1. scripts/apply.sh & rollback.sh
  -- =========================================================================

  test("bb.apply.cli_and_prompt_guard", function()
    with_sandbox({}, function(sb)
      -- -h and --help -> exit 0
      local r1 = run_apply(sb, { "-h" })
      assert_eq(r1.rc, 0, "apply -h should exit 0: " .. r1.combined)
      local r2 = run_apply(sb, { "--help" })
      assert_eq(r2.rc, 0, "apply --help should exit 0: " .. r2.combined)

      -- Unknown flags -> exit 2 and $HOME/$XDG_CONFIG_HOME untouched
      local bad_invocations = {
        { "--unknown-flag" },
        { "-Z" },
        { "--yes=maybe" },
        { "unexpected-arg" },
      }
      for _, argv in ipairs(bad_invocations) do
        local r = run_apply(sb, argv)
        assert_eq(r.rc, 2, "apply invalid arg " .. argv[1] .. " must exit 2, got " .. tostring(r.rc))
      end

      -- Interactive `n` without --yes aborts with exit 1 leaving $HOME untouched
      local r_abort = run_apply(sb, {}, { stdin = "n\n" })
      assert_eq(r_abort.rc, 1, "interactive 'n' must exit 1: " .. r_abort.combined)

      -- Verify $HOME, $XDG_CONFIG_HOME, $XDG_DATA_HOME are completely untouched
      assert_eq(#list_entries(sb.config), 0, "XDG_CONFIG_HOME must be untouched after help/errors/abort")
      assert_eq(#list_entries(sb.data), 0, "XDG_DATA_HOME must be untouched after help/errors/abort")
      assert_true(not lexists(sb.home .. "/.zshrc"), "~/.zshrc must not exist after abort")
      assert_true(not lexists(sb.home .. "/.zprofile"), "~/.zprofile must not exist after abort")

      -- POSIX sh execution with --yes succeeds
      local r_ok = run_apply(sb, { "--yes" })
      assert_eq(r_ok.rc, 0, "POSIX sh apply.sh --yes must exit 0: " .. r_ok.combined)
      assert_true(is_symlink(sb.config .. "/hypr/hyprland.lua"), "hyprland.lua symlink must exist after POSIX sh apply")
    end)
  end)

  test("bb.apply.fresh_install_artifacts", function()
    with_sandbox({}, function(sb)
      local r = run_apply(sb, { "--yes" })
      assert_eq(r.rc, 0, "fresh apply --yes must exit 0: " .. r.combined)

      -- Timestamped backup dir and last-backup marker
      local backups = list_entries(sb.config, ".kaze-backup-")
      assert_eq(#backups, 1, "expected exactly 1 .kaze-backup-* directory")
      local backup_dir = sb.config .. "/" .. backups[1]
      assert_true(is_dir(backup_dir), "backup dir must exist")
      assert_true(is_file(backup_dir .. "/installed.list"), "installed.list must exist")
      assert_true(is_file(backup_dir .. "/backed_up.list"), "backed_up.list must exist")
      assert_true(is_dir(backup_dir .. "/files"), "backup files/ dir must exist")
      assert_true(is_executable(backup_dir .. "/rollback.sh"), "rollback.sh must be executable")

      local last_backup = read_file(sb.config .. "/kaze/last-backup")
      assert_true(type(last_backup) == "string", "kaze/last-backup must exist")
      assert_eq((last_backup:gsub("%s+$", "")), backup_dir, "kaze/last-backup must match created backup dir")

      -- All managed config symlinks
      local expected_symlinks = {
        sb.config .. "/hypr/hyprland.lua",
        sb.config .. "/hypr/env.lua",
        sb.config .. "/hypr/core.lua",
        sb.config .. "/hypr/rules.lua",
        sb.config .. "/hypr/execs.lua",
        sb.config .. "/hypr/keybinds.lua",
        sb.config .. "/hypr/xdph.conf",
        sb.config .. "/foot/foot.ini",
        sb.config .. "/starship.toml",
        sb.config .. "/yazi/yazi.toml",
        sb.config .. "/yazi/theme.toml",
        sb.config .. "/yazi/keymap.toml",
        sb.config .. "/zathura/zathurarc",
        sb.config .. "/imv/config",
        sb.config .. "/mimeapps.list",
        sb.config .. "/gtk-3.0/settings.ini",
        sb.config .. "/gtk-3.0/kaze-thunar.css",
        sb.config .. "/Thunar/uca.xml",
        sb.config .. "/noctalia/palettes/Kaze-Swiss.json",
        sb.config .. "/noctalia/palettes/Kaze-Phosphor.json",
        sb.config .. "/noctalia/palettes/Kaze-Amber.json",
        sb.config .. "/noctalia/palettes/Kaze-Retro90s.json",
        sb.home .. "/.zshrc",
        sb.home .. "/.zprofile",
        sb.config .. "/zsh/conf.d",
        sb.data .. "/applications/yazi.desktop",
        sb.data .. "/kaze-dots/lua/kaze",
      }
      for _, p in ipairs(expected_symlinks) do
        assert_true(is_symlink(p), "expected symlink: " .. p)
        assert_true(path_exists(p), "symlink target must exist: " .. p)
      end

      -- systemd/user/kaze-* symlinks
      local sd_entries = list_entries(sb.config .. "/systemd/user", "kaze-")
      assert_true(#sd_entries > 0, "expected at least one systemd/user/kaze-* symlink")
      for _, name in ipairs(sd_entries) do
        local p = sb.config .. "/systemd/user/" .. name
        assert_true(is_symlink(p) and path_exists(p), "invalid systemd symlink: " .. p)
      end

      -- ~/.local/bin/kaze-* symlinks
      local bin_entries = list_entries(sb.home .. "/.local/bin", "kaze-")
      assert_true(#bin_entries > 0, "expected ~/.local/bin/kaze-* symlinks")
      assert_true(is_symlink(sb.home .. "/.local/bin/kaze-doctor"), "expected ~/.local/bin/kaze-doctor symlink")
      for _, name in ipairs(bin_entries) do
        local p = sb.home .. "/.local/bin/" .. name
        assert_true(is_symlink(p) and path_exists(p), "invalid bin symlink: " .. p)
      end

      -- Seeded editable files (regular files, NOT symlinks!)
      local seeded_editable = {
        sb.config .. "/noctalia/config.toml",
        sb.config .. "/Thunar/accels.scm",
        sb.config .. "/xfce4/xfconf/xfce-perchannel-xml/thunar.xml",
        sb.config .. "/hypr/user.lua",
      }
      for _, p in ipairs(seeded_editable) do
        assert_true(is_regular_non_symlink(p), "seeded file must be regular file (not symlink): " .. p)
      end

      -- noctalia/config.toml expands ~/Pictures/Wallpapers to $HOME/Pictures/Wallpapers
      local noctalia_cfg = read_file(sb.config .. "/noctalia/config.toml") or ""
      assert_contains(noctalia_cfg, sb.home .. "/Pictures/Wallpapers", "noctalia/config.toml must expand ~/Pictures/Wallpapers to $HOME/Pictures/Wallpapers")
      assert_true(not noctalia_cfg:find("~/Pictures/Wallpapers", 1, true), "noctalia/config.toml must not leave unexpanded ~/Pictures/Wallpapers")

      -- Seeded empty placeholder files
      local placeholders = {
        sb.config .. "/foot/themes/noctalia",
        sb.config .. "/gtk-3.0/noctalia.css",
        sb.config .. "/gtk-3.0/kaze-style.css",
      }
      for _, p in ipairs(placeholders) do
        assert_true(is_regular_non_symlink(p), "placeholder must be regular file: " .. p)
        assert_eq(read_file(p), "", "newly seeded placeholder must be empty: " .. p)
      end

      -- gtk-3.0/gtk.css imports
      local gtk_css = read_file(sb.config .. "/gtk-3.0/gtk.css") or ""
      assert_eq(count_occurrences(gtk_css, "noctalia.css"), 1, "gtk.css must import noctalia.css once")
      assert_eq(count_occurrences(gtk_css, "kaze-thunar.css"), 1, "gtk.css must import kaze-thunar.css once")
      assert_eq(count_occurrences(gtk_css, "kaze-style.css"), 1, "gtk.css must import kaze-style.css once")

      -- Ensure no blocked system commands were invoked
      local log_data = read_file(sb.log) or ""
      assert_true(not log_data:find("BLOCKED:", 1, true), "apply.sh must never invoke sudo/pacman/etc:\n" .. log_data)
    end)

    -- Separate sandbox check: pre-existing hypr/user.lua and non-empty placeholders are NOT overwritten
    with_sandbox({}, function(sb)
      local custom_user = "-- pre-existing user.lua must not be clobbered\nreturn { kb_layout = 'fr' }\n"
      local custom_theme = "[colors]\nbackground=111111\n"
      local custom_noctalia_css = "@define-color accent #ff0000;\n"
      write_file(sb.config .. "/hypr/user.lua", custom_user)
      write_file(sb.config .. "/foot/themes/noctalia", custom_theme)
      write_file(sb.config .. "/gtk-3.0/noctalia.css", custom_noctalia_css)
      local r = run_apply(sb, { "--yes" })
      assert_eq(r.rc, 0, "apply with existing user.lua must exit 0: " .. r.combined)
      assert_true(is_regular_non_symlink(sb.config .. "/hypr/user.lua"), "existing user.lua must remain regular file")
      assert_eq(read_file(sb.config .. "/hypr/user.lua"), custom_user, "pre-existing user.lua must not be overwritten")
      assert_eq(read_file(sb.config .. "/foot/themes/noctalia"), custom_theme, "pre-existing foot/themes/noctalia must not be truncated")
      assert_eq(read_file(sb.config .. "/gtk-3.0/noctalia.css"), custom_noctalia_css, "pre-existing gtk-3.0/noctalia.css must not be truncated")
    end)
  end)

  test("bb.apply.reapply_idempotency_and_user_edits", function()
    with_sandbox({}, function(sb)
      -- Pre-existing custom CSS lines in gtk-3.0/gtk.css
      local custom_css_line = "/* kaze-bb-custom-css */ window.custom-box { margin: 3px; }"
      write_file(sb.config .. "/gtk-3.0/gtk.css", custom_css_line .. "\n")

      local r1 = run_apply(sb, { "--yes" })
      assert_eq(r1.rc, 0, "1st apply must exit 0: " .. r1.combined)
      local b1 = (read_file(sb.config .. "/kaze/last-backup") or ""):gsub("%s+$", "")
      assert_true(is_dir(b1), "1st backup dir must exist")

      -- Make user edits to all editable/user-owned files
      local edit_noctalia = (read_file(sb.config .. "/noctalia/config.toml") or "") .. "\n# kaze-bb-user-noctalia-edit\n"
      local edit_accels = (read_file(sb.config .. "/Thunar/accels.scm") or "") .. "\n; kaze-bb-user-accels-edit\n"
      local edit_user_lua = "-- kaze-bb-user-lua-edit\nreturn { smart_gaps = true }\n"
      local edit_user_zsh = "# kaze-bb-user-zsh-edit\nexport KAZE_BB_ZSH=1\n"
      local edit_zprofile_local = "# kaze-bb-zprofile-local-edit\nexport KAZE_BB_ZPROF=1\n"

      write_file(sb.config .. "/noctalia/config.toml", edit_noctalia)
      write_file(sb.config .. "/Thunar/accels.scm", edit_accels)
      write_file(sb.config .. "/hypr/user.lua", edit_user_lua)
      write_file(sb.config .. "/zsh/user.zsh", edit_user_zsh)
      write_file(sb.config .. "/zsh/zprofile.local", edit_zprofile_local)

      -- 2nd apply (immediately back-to-back to also test timestamp uniqueness)
      local r2 = run_apply(sb, { "--yes" })
      assert_eq(r2.rc, 0, "2nd apply must exit 0: " .. r2.combined)
      local b2 = (read_file(sb.config .. "/kaze/last-backup") or ""):gsub("%s+$", "")
      assert_true(is_dir(b2), "2nd backup dir must exist")
      assert_true(b1 ~= b2, "2nd apply must create a NEW backup dir (b1=" .. b1 .. ", b2=" .. b2 .. ")")

      -- 3rd apply
      local r3 = run_apply(sb, { "--yes" })
      assert_eq(r3.rc, 0, "3rd apply must exit 0: " .. r3.combined)
      local b3 = (read_file(sb.config .. "/kaze/last-backup") or ""):gsub("%s+$", "")
      assert_true(is_dir(b3), "3rd backup dir must exist")
      assert_true(b2 ~= b3 and b1 ~= b3, "3rd apply must create a distinct backup dir")

      -- Verify ALL user edits preserved after 2nd & 3rd re-apply
      assert_eq(read_file(sb.config .. "/noctalia/config.toml"), edit_noctalia, "noctalia/config.toml edits must be preserved")
      assert_eq(read_file(sb.config .. "/Thunar/accels.scm"), edit_accels, "Thunar/accels.scm edits must be preserved")
      assert_eq(read_file(sb.config .. "/hypr/user.lua"), edit_user_lua, "hypr/user.lua edits must be preserved")
      assert_eq(read_file(sb.config .. "/zsh/user.zsh"), edit_user_zsh, "zsh/user.zsh edits must be preserved")
      assert_eq(read_file(sb.config .. "/zsh/zprofile.local"), edit_zprofile_local, "zsh/zprofile.local edits must be preserved")

      -- Verify gtk.css preserved pre-existing custom lines AND did NOT duplicate imports
      local gtk_css = read_file(sb.config .. "/gtk-3.0/gtk.css") or ""
      assert_contains(gtk_css, custom_css_line, "gtk.css must preserve pre-existing custom CSS lines")
      assert_eq(count_occurrences(gtk_css, "noctalia.css"), 1, "gtk.css must not duplicate noctalia.css import")
      assert_eq(count_occurrences(gtk_css, "kaze-thunar.css"), 1, "gtk.css must not duplicate kaze-thunar.css import")
      assert_eq(count_occurrences(gtk_css, "kaze-style.css"), 1, "gtk.css must not duplicate kaze-style.css import")
    end)
  end)

  test("bb.apply.spaces_in_all_xdg_paths", function()
    with_sandbox({ with_spaces = true }, function(sb)
      -- Seed pre-existing file & pre-existing broken symlink with spaces in target
      local orig_zshrc = "# pre-existing zshrc with spaces\n"
      local broken_target = "/nonexistent/broken path with spaces/foot.ini"
      write_file(sb.home .. "/.zshrc", orig_zshrc)
      exec_code("/usr/bin/mkdir -p -- " .. sh_quote(sb.config .. "/foot"))
      assert_eq(exec_code("/usr/bin/ln -s -- " .. sh_quote(broken_target) .. " " .. sh_quote(sb.config .. "/foot/foot.ini")), 0)

      local r = run_apply(sb, { "--yes" })
      assert_eq(r.rc, 0, "apply with spaces in ALL XDG paths must exit 0: " .. r.combined)

      local backup_dir = (read_file(sb.config .. "/kaze/last-backup") or ""):gsub("%s+$", "")
      assert_true(is_dir(backup_dir), "backup dir with spaces must exist: " .. backup_dir)
      assert_true(is_executable(backup_dir .. "/rollback.sh"), "rollback.sh in spaced path must be executable")
      assert_true(is_symlink(sb.config .. "/hypr/hyprland.lua"), "hyprland.lua symlink must exist")
      assert_true(is_symlink(sb.data .. "/applications/yazi.desktop"), "yazi.desktop symlink must exist in spaced XDG_DATA_HOME")
      assert_true(is_symlink(sb.data .. "/kaze-dots/lua/kaze"), "lua/kaze symlink must exist in spaced XDG_DATA_HOME")

      local noctalia_cfg = read_file(sb.config .. "/noctalia/config.toml") or ""
      assert_contains(noctalia_cfg, sb.home .. "/Pictures/Wallpapers", "noctalia config must expand spaced $HOME/Pictures/Wallpapers")

      -- Reapply in spaced paths to verify spaced baseline preservation
      local r2 = run_apply(sb, { "--yes" })
      assert_eq(r2.rc, 0, "reapply with spaces in ALL XDG paths must exit 0: " .. r2.combined)
      local backup_dir2 = (read_file(sb.config .. "/kaze/last-backup") or ""):gsub("%s+$", "")
      assert_true(backup_dir ~= backup_dir2, "reapply with spaces must create a new backup dir")

      -- Rollback in spaced paths
      local rb = run_cmd(sb, { "/usr/bin/sh", backup_dir2 .. "/rollback.sh", "--yes" })
      assert_eq(rb.rc, 0, "rollback with spaces in ALL XDG paths must exit 0: " .. rb.combined)
      assert_eq(read_file(sb.home .. "/.zshrc"), orig_zshrc, "spaced ~/.zshrc must be restored")
      assert_true(is_symlink(sb.config .. "/foot/foot.ini"), "spaced broken symlink must be restored as symlink")
      assert_eq(readlink_raw(sb.config .. "/foot/foot.ini"), broken_target, "spaced broken symlink target must match exactly")
      assert_true(not lexists(sb.config .. "/hypr/hyprland.lua"), "hyprland.lua symlink must be removed")
      assert_true(not lexists(sb.config .. "/kaze/last-backup"), "last-backup must be removed after rollback")
      -- Even freshly-seeded hypr/user.lua must always be preserved by rollback
      assert_true(is_regular_non_symlink(sb.config .. "/hypr/user.lua"), "rollback must ALWAYS preserve hypr/user.lua even when newly seeded")
    end)
  end)

  test("bb.apply.rollback_guards_and_full_restore", function()
    with_sandbox({}, function(sb)
      -- Pre-populate pre-existing regular files, broken symlinks, valid symlink, and user files
      local orig_zshrc = "# original user zshrc before kaze\n"
      local orig_foot = "# original foot.ini before kaze\n"
      local orig_mime = "[Default Applications]\ntext/plain=orig.desktop\n"
      local orig_gtk_css = "/* original gtk.css before kaze */\n"
      local broken_starship_target = "/nonexistent/kaze/orig-starship.toml"
      local broken_imv_target = "../dangling/orig-imv.conf"
      local valid_zathura_target = sb.home .. "/my-zathurarc-source"
      local keep_user_lua = "-- keep user.lua forever\nreturn { kb_layout = 'us' }\n"
      local keep_user_zsh = "# keep user.zsh forever\n"
      local keep_zprof_local = "# keep zprofile.local forever\n"

      write_file(sb.home .. "/.zshrc", orig_zshrc)
      write_file(sb.config .. "/foot/foot.ini", orig_foot)
      write_file(sb.config .. "/mimeapps.list", orig_mime)
      write_file(sb.config .. "/gtk-3.0/gtk.css", orig_gtk_css)
      write_file(valid_zathura_target, "set selection-clipboard clipboard\n")
      exec_code("/usr/bin/mkdir -p -- " .. sh_quote(sb.config .. "/imv") .. " " .. sh_quote(sb.config .. "/zathura"))
      assert_eq(exec_code("/usr/bin/ln -s -- " .. sh_quote(broken_starship_target) .. " " .. sh_quote(sb.config .. "/starship.toml")), 0)
      assert_eq(exec_code("/usr/bin/ln -s -- " .. sh_quote(broken_imv_target) .. " " .. sh_quote(sb.config .. "/imv/config")), 0)
      assert_eq(exec_code("/usr/bin/ln -s -- " .. sh_quote(valid_zathura_target) .. " " .. sh_quote(sb.config .. "/zathura/zathurarc")), 0)

      write_file(sb.config .. "/hypr/user.lua", keep_user_lua)
      write_file(sb.config .. "/zsh/user.zsh", keep_user_zsh)
      write_file(sb.config .. "/zsh/zprofile.local", keep_zprof_local)

      -- Apply #1, then Apply #2 (reapply must preserve original uninstall baseline!)
      local r1 = run_apply(sb, { "--yes" })
      assert_eq(r1.rc, 0, "apply #1 must exit 0: " .. r1.combined)
      local b1 = (read_file(sb.config .. "/kaze/last-backup") or ""):gsub("%s+$", "")

      local r2 = run_apply(sb, { "--yes" })
      assert_eq(r2.rc, 0, "apply #2 must exit 0: " .. r2.combined)
      local b2 = (read_file(sb.config .. "/kaze/last-backup") or ""):gsub("%s+$", "")
      assert_true(b1 ~= b2, "reapply must produce a new backup dir")

      -- Guard 1: Stale rollback (b1/rollback.sh after reapply) MUST be refused (exit 1)
      local r_stale = run_cmd(sb, { "/usr/bin/sh", b1 .. "/rollback.sh", "--yes" })
      assert_eq(r_stale.rc, 1, "stale rollback must be refused with exit 1: " .. r_stale.combined)
      assert_true(is_symlink(sb.config .. "/hypr/hyprland.lua"), "stale rollback must not remove configs")
      assert_eq((read_file(sb.config .. "/kaze/last-backup") or ""):gsub("%s+$", ""), b2, "stale rollback must not touch last-backup")

      -- Guard 2: Active kaze-session.target (UNIX socket at $XDG_RUNTIME_DIR/bus + systemctl is-active rc=0) -> refused!
      create_unix_socket(sb.runtime .. "/bus")
      write_file(sb.state_dir .. "/systemctl_active_units", "kaze-session.target\n")
      local r_active = run_cmd(sb, { "/usr/bin/sh", b2 .. "/rollback.sh", "--yes" })
      assert_true(r_active.rc ~= 0, "rollback while kaze-session.target active must be refused: " .. r_active.combined)
      assert_true(is_symlink(sb.config .. "/hypr/hyprland.lua"), "blocked rollback must not remove configs")

      -- Now kaze-session.target is inactive (keep bus socket present to prove systemctl is checked)
      write_file(sb.state_dir .. "/systemctl_active_units", "")
      local r_rb = run_cmd(sb, { "/usr/bin/sh", b2 .. "/rollback.sh", "--yes" })
      assert_eq(r_rb.rc, 0, "active rollback must exit 0: " .. r_rb.combined)

      -- All Kaze-installed symlinks & seeded files absent before Apply #1 must be REMOVED
      local should_be_removed = {
        sb.config .. "/hypr/hyprland.lua",
        sb.config .. "/hypr/env.lua",
        sb.config .. "/hypr/core.lua",
        sb.config .. "/hypr/rules.lua",
        sb.config .. "/hypr/execs.lua",
        sb.config .. "/hypr/keybinds.lua",
        sb.config .. "/hypr/xdph.conf",
        sb.config .. "/noctalia/config.toml",
        sb.config .. "/noctalia/palettes/Kaze-Swiss.json",
        sb.config .. "/Thunar/accels.scm",
        sb.config .. "/Thunar/uca.xml",
        sb.config .. "/yazi/yazi.toml",
        sb.config .. "/foot/themes/noctalia",
        sb.config .. "/gtk-3.0/noctalia.css",
        sb.config .. "/gtk-3.0/kaze-style.css",
        sb.config .. "/gtk-3.0/kaze-thunar.css",
        sb.data .. "/applications/yazi.desktop",
        sb.data .. "/kaze-dots/lua/kaze",
        sb.home .. "/.local/bin/kaze-doctor",
        sb.home .. "/.zprofile",
        sb.config .. "/kaze/last-backup",
      }
      for _, p in ipairs(should_be_removed) do
        assert_true(not lexists(p), "rollback must remove Kaze-installed path: " .. p)
      end
      assert_eq(#list_entries(sb.config .. "/systemd/user", "kaze-"), 0, "rollback must remove systemd/user/kaze-* symlinks")

      -- Original pre-existing regular files restored to exact content
      assert_true(is_regular_non_symlink(sb.home .. "/.zshrc"), "restored ~/.zshrc must be regular file")
      assert_eq(read_file(sb.home .. "/.zshrc"), orig_zshrc, "restored ~/.zshrc content mismatch")
      assert_true(is_regular_non_symlink(sb.config .. "/foot/foot.ini"), "restored foot.ini must be regular file")
      assert_eq(read_file(sb.config .. "/foot/foot.ini"), orig_foot, "restored foot.ini content mismatch")
      assert_eq(read_file(sb.config .. "/mimeapps.list"), orig_mime, "restored mimeapps.list content mismatch")
      assert_eq(read_file(sb.config .. "/gtk-3.0/gtk.css"), orig_gtk_css, "restored gtk.css content mismatch")

      -- Original pre-existing broken & valid symlinks restored with exact readlink targets
      assert_true(is_symlink(sb.config .. "/starship.toml"), "broken starship.toml symlink must be restored")
      assert_eq(readlink_raw(sb.config .. "/starship.toml"), broken_starship_target, "starship.toml readlink target must match exactly")
      assert_true(is_symlink(sb.config .. "/imv/config"), "broken imv/config symlink must be restored")
      assert_eq(readlink_raw(sb.config .. "/imv/config"), broken_imv_target, "imv/config readlink target must match exactly")
      assert_true(is_symlink(sb.config .. "/zathura/zathurarc"), "valid zathurarc symlink must be restored")
      assert_eq(readlink_raw(sb.config .. "/zathura/zathurarc"), valid_zathura_target, "zathurarc readlink target must match exactly")

      -- Always-preserved user files remain intact
      assert_eq(read_file(sb.config .. "/hypr/user.lua"), keep_user_lua, "rollback must preserve hypr/user.lua")
      assert_eq(read_file(sb.config .. "/zsh/user.zsh"), keep_user_zsh, "rollback must preserve zsh/user.zsh")
      assert_eq(read_file(sb.config .. "/zsh/zprofile.local"), keep_zprof_local, "rollback must preserve zsh/zprofile.local")

      -- Guard 3: Double-rollback MUST be refused (exit 1) and never delete restored files
      local r_double = run_cmd(sb, { "/usr/bin/sh", b2 .. "/rollback.sh", "--yes" })
      assert_eq(r_double.rc, 1, "double-rollback must be refused with exit 1: " .. r_double.combined)
      assert_eq(read_file(sb.home .. "/.zshrc"), orig_zshrc, "double-rollback must not delete restored ~/.zshrc")
      assert_eq(read_file(sb.config .. "/foot/foot.ini"), orig_foot, "double-rollback must not delete restored foot.ini")
      assert_eq(readlink_raw(sb.config .. "/starship.toml"), broken_starship_target, "double-rollback must not delete restored broken symlink")
      assert_eq(read_file(sb.config .. "/hypr/user.lua"), keep_user_lua, "double-rollback must not delete hypr/user.lua")
    end)
  end)

  -- =========================================================================
  -- 2. bin/kaze-doctor Full Offline & Live Diagnostic Matrix
  -- =========================================================================

  test("bb.doctor.cli_validation", function()
    with_sandbox({ minimal_bins = true }, function(sb)
      assert_eq(run_doctor(sb, { "-h" }).rc, 0, "kaze-doctor -h must exit 0")
      assert_eq(run_doctor(sb, { "--help" }).rc, 0, "kaze-doctor --help must exit 0")

      local bad_cases = {
        { "--unknown-flag" },
        { "-Z" },
        { "positional-arg" },
        { "--profile" },
        { "--profile", "invalid" },
        { "--profile", "MINIMAL" },
        { "--profile", "" },
        { "--template" },
        { "--diff", "--template" },
      }
      for _, argv in ipairs(bad_cases) do
        local r = run_doctor(sb, argv)
        assert_eq(r.rc, 2, "invalid args [" .. table.concat(argv, " ") .. "] must exit 2, got " .. tostring(r.rc) .. ": " .. r.combined)
      end
    end)
  end)

  test("bb.doctor.offline_minimal_binaries_brute_force", function()
    with_sandbox({ minimal_bins = true }, function(sb)
      assert_eq(run_apply(sb, { "--yes" }).rc, 0, "apply failed")

      local base = run_doctor(sb, { "--offline", "--profile", "minimal" })
      assert_eq(base.rc, 0, "baseline offline minimal doctor must exit 0:\n" .. base.combined)
      assert_true(not base.combined:find("[FAIL]", 1, true), "baseline offline minimal must have no [FAIL]:\n" .. base.combined)

      -- Leave-one-out across all 16 minimal binaries
      local stash = sb.root .. "/stashed-bin"
      for _, bin_name in ipairs(MINIMAL_BINS) do
        local target = sb.bin .. "/" .. bin_name
        assert_eq(exec_code("/usr/bin/mv -- " .. sh_quote(target) .. " " .. sh_quote(stash)), 0)
        local r = run_doctor(sb, { "--offline", "--profile", "minimal" })
        assert_eq(exec_code("/usr/bin/mv -- " .. sh_quote(stash) .. " " .. sh_quote(target)), 0)

        assert_eq(r.rc, 1, "missing minimal binary '" .. bin_name .. "' must exit 1, got " .. tostring(r.rc) .. ":\n" .. r.combined)
        assert_contains(r.combined, "[FAIL]", "missing minimal binary '" .. bin_name .. "' must report [FAIL]")
        assert_contains(r.combined, bin_name, "missing minimal binary failure must mention '" .. bin_name .. "'")
      end
    end)
  end)

  test("bb.doctor.offline_full_binaries_brute_force", function()
    with_sandbox({ full_bins = true }, function(sb)
      assert_eq(run_apply(sb, { "--yes" }).rc, 0, "apply failed")

      local base = run_doctor(sb, { "--offline", "--profile", "full" })
      assert_eq(base.rc, 0, "baseline offline full doctor must exit 0:\n" .. base.combined)
      assert_true(not base.combined:find("[FAIL]", 1, true), "baseline offline full must have no [FAIL]:\n" .. base.combined)

      -- Leave-one-out across all 19 full-only binaries
      local stash = sb.root .. "/stashed-bin"
      for _, bin_name in ipairs(FULL_EXTRA_BINS) do
        local target = sb.bin .. "/" .. bin_name
        assert_eq(exec_code("/usr/bin/mv -- " .. sh_quote(target) .. " " .. sh_quote(stash)), 0)
        local r = run_doctor(sb, { "--offline", "--profile", "full" })
        assert_eq(exec_code("/usr/bin/mv -- " .. sh_quote(stash) .. " " .. sh_quote(target)), 0)

        assert_eq(r.rc, 1, "missing full binary '" .. bin_name .. "' must exit 1, got " .. tostring(r.rc) .. ":\n" .. r.combined)
        assert_contains(r.combined, "[FAIL]", "missing full binary '" .. bin_name .. "' must report [FAIL]")
        assert_contains(r.combined, bin_name, "missing full binary failure must mention '" .. bin_name .. "'")
      end

      -- Remove ALL 19 full-only binaries: minimal profile MUST still exit 0
      for _, bin_name in ipairs(FULL_EXTRA_BINS) do
        exec_code("/usr/bin/rm -f -- " .. sh_quote(sb.bin .. "/" .. bin_name))
      end
      local r_min = run_doctor(sb, { "--offline", "--profile", "minimal" })
      assert_eq(r_min.rc, 0, "minimal profile must not fail when full-only binaries are absent:\n" .. r_min.combined)
    end)
  end)

  test("bb.doctor.offline_symlinks_config_and_locale", function()
    -- Part A & B & D on an applied sandbox
    with_sandbox({ minimal_bins = true }, function(sb)
      assert_eq(run_apply(sb, { "--yes" }).rc, 0, "apply failed")

      -- Config validation: noctalia config validate failure -> [FAIL], exit 1
      write_file(sb.state_dir .. "/noctalia_validate_rc", "1\n")
      local rn = run_doctor(sb, { "--offline", "--profile", "minimal" })
      write_file(sb.state_dir .. "/noctalia_validate_rc", "0\n")
      assert_eq(rn.rc, 1, "failing noctalia config validate must exit 1:\n" .. rn.combined)
      assert_contains(rn.combined, "[FAIL]", "failing noctalia config validate must emit [FAIL]")

      -- Config validation: foot --check-config failure -> [FAIL], exit 1
      write_file(sb.state_dir .. "/foot_check_rc", "1\n")
      local rf = run_doctor(sb, { "--offline", "--profile", "minimal" })
      write_file(sb.state_dir .. "/foot_check_rc", "0\n")
      assert_eq(rf.rc, 1, "failing foot --check-config must exit 1:\n" .. rf.combined)
      assert_contains(rf.combined, "[FAIL]", "failing foot --check-config must emit [FAIL]")

      -- Config validation: zsh -n failure -> [FAIL], exit 1
      write_file(sb.state_dir .. "/zsh_check_rc", "1\n")
      local rz = run_doctor(sb, { "--offline", "--profile", "minimal" })
      write_file(sb.state_dir .. "/zsh_check_rc", "0\n")
      assert_eq(rz.rc, 1, "failing zsh -n must exit 1:\n" .. rz.combined)
      assert_contains(rz.combined, "[FAIL]", "failing zsh -n must emit [FAIL]")

      -- UTF-8 locale checks: LANG=en_US.UTF-8 -> [OK], exit 0
      local r_utf8 = run_doctor(sb, { "--offline", "--profile", "minimal" }, { env = { LANG = "en_US.UTF-8" } })
      assert_eq(r_utf8.rc, 0, "LANG=en_US.UTF-8 offline must exit 0:\n" .. r_utf8.combined)
      assert_contains(r_utf8.combined, "[OK]", "LANG=en_US.UTF-8 must report [OK]")

      -- LANG=C in --offline -> [WARN] and exit 0
      local r_c_off = run_doctor(sb, { "--offline", "--profile", "minimal" }, { env = { LANG = "C", LC_ALL = false, LC_CTYPE = false } })
      assert_eq(r_c_off.rc, 0, "LANG=C in --offline must warn and exit 0:\n" .. r_c_off.combined)
      assert_contains(r_c_off.combined, "[WARN]", "LANG=C in --offline must emit [WARN]")

      -- LANG=C in live mode -> [FAIL] and exit 1
      local live_env = set_live_healthy(sb, { lang = "C", procs = { "noctalia", "foot" } })
      local r_c_live = run_doctor(sb, { "--profile", "minimal" }, { env = live_env })
      assert_eq(r_c_live.rc, 1, "LANG=C in live mode must exit 1:\n" .. r_c_live.combined)
      assert_contains(r_c_live.combined, "[FAIL]", "LANG=C in live mode must emit [FAIL]")

      -- Broken symlink -> [FAIL] and exit 1
      exec_code("/usr/bin/rm -f -- " .. sh_quote(sb.config .. "/foot/foot.ini"))
      assert_eq(exec_code("/usr/bin/ln -s /nonexistent/broken-kaze-target " .. sh_quote(sb.config .. "/foot/foot.ini")), 0)
      local r_broken = run_doctor(sb, { "--offline", "--profile", "minimal" })
      assert_eq(r_broken.rc, 1, "broken symlink must exit 1:\n" .. r_broken.combined)
      assert_contains(r_broken.combined, "[FAIL]", "broken symlink must emit [FAIL]")
    end)

    -- Part C: Unapplied $HOME warns in --offline, fails in live mode
    with_sandbox({ minimal_bins = true }, function(sb)
      local r_off = run_doctor(sb, { "--offline", "--profile", "minimal" })
      assert_eq(r_off.rc, 0, "unapplied $HOME in --offline must warn and exit 0:\n" .. r_off.combined)
      assert_contains(r_off.combined, "[WARN]", "unapplied $HOME in --offline must emit [WARN]")

      local live_env = set_live_healthy(sb, { procs = { "noctalia", "foot" } })
      local r_live = run_doctor(sb, { "--profile", "minimal" }, { env = live_env })
      assert_eq(r_live.rc, 1, "unapplied $HOME in live mode must fail with exit 1:\n" .. r_live.combined)
      assert_contains(r_live.combined, "[FAIL]", "unapplied $HOME in live mode must emit [FAIL]")
    end)
  end)

  test("bb.doctor.live_hyprctl_env_and_dbus", function()
    with_sandbox({ full_bins = true }, function(sb)
      assert_eq(run_apply(sb, { "--yes" }).rc, 0, "apply failed")

      -- Healthy live baseline (minimal & full)
      local live_env = set_live_healthy(sb, { procs = { "noctalia", "foot", "fcitx5" } })
      local r_min = run_doctor(sb, { "--profile", "minimal" }, { env = live_env })
      assert_eq(r_min.rc, 0, "healthy live minimal must exit 0:\n" .. r_min.combined)
      assert_true(not r_min.combined:find("[FAIL]", 1, true), "healthy live minimal must have no [FAIL]")

      local r_full = run_doctor(sb, { "--profile", "full" }, { env = live_env })
      assert_eq(r_full.rc, 0, "healthy live full must exit 0:\n" .. r_full.combined)
      assert_true(not r_full.combined:find("[FAIL]", 1, true), "healthy live full must have no [FAIL]")

      -- Unset HYPRLAND_INSTANCE_SIGNATURE without --offline -> [WARN] skipping live checks
      local r_nosig = run_doctor(sb, { "--profile", "minimal" }, { env = { HYPRLAND_INSTANCE_SIGNATURE = false } })
      assert_eq(r_nosig.rc, 0, "unset HYPRLAND_INSTANCE_SIGNATURE must warn and exit 0:\n" .. r_nosig.combined)
      assert_contains(r_nosig.combined, "[WARN]", "unset HYPRLAND_INSTANCE_SIGNATURE must emit [WARN]")

      -- hyprctl configerrors: non-empty output -> [FAIL]
      live_env = set_live_healthy(sb, { configerrors = "Config error at line 7: bad option\n", configerrors_rc = 0 })
      local r_ce1 = run_doctor(sb, { "--profile", "minimal" }, { env = live_env })
      assert_eq(r_ce1.rc, 1, "non-empty hyprctl configerrors must exit 1:\n" .. r_ce1.combined)
      assert_contains(r_ce1.combined, "[FAIL]", "non-empty hyprctl configerrors must emit [FAIL]")

      -- hyprctl configerrors: non-zero exit -> [FAIL]
      live_env = set_live_healthy(sb, { configerrors = "", configerrors_rc = 1 })
      local r_ce2 = run_doctor(sb, { "--profile", "minimal" }, { env = live_env })
      assert_eq(r_ce2.rc, 1, "non-zero hyprctl configerrors must exit 1:\n" .. r_ce2.combined)
      assert_contains(r_ce2.combined, "[FAIL]", "non-zero hyprctl configerrors must emit [FAIL]")

      -- systemctl --user show-environment mismatches on EACH of the 3 required vars
      local env_mismatch_cases = {
        {
          name = "WAYLAND_DISPLAY mismatch",
          lines = { "WAYLAND_DISPLAY=wayland-wrong", "HYPRLAND_INSTANCE_SIGNATURE=kaze-live-sig-42", "XDG_CURRENT_DESKTOP=Hyprland" },
        },
        {
          name = "HYPRLAND_INSTANCE_SIGNATURE mismatch",
          lines = { "WAYLAND_DISPLAY=wayland-1", "HYPRLAND_INSTANCE_SIGNATURE=wrong-sig", "XDG_CURRENT_DESKTOP=Hyprland" },
        },
        {
          name = "XDG_CURRENT_DESKTOP mismatch",
          lines = { "WAYLAND_DISPLAY=wayland-1", "HYPRLAND_INSTANCE_SIGNATURE=kaze-live-sig-42", "XDG_CURRENT_DESKTOP=GNOME" },
        },
        {
          name = "missing WAYLAND_DISPLAY",
          lines = { "HYPRLAND_INSTANCE_SIGNATURE=kaze-live-sig-42", "XDG_CURRENT_DESKTOP=Hyprland" },
        },
        {
          name = "missing HYPRLAND_INSTANCE_SIGNATURE",
          lines = { "WAYLAND_DISPLAY=wayland-1", "XDG_CURRENT_DESKTOP=Hyprland" },
        },
        {
          name = "missing XDG_CURRENT_DESKTOP",
          lines = { "WAYLAND_DISPLAY=wayland-1", "HYPRLAND_INSTANCE_SIGNATURE=kaze-live-sig-42" },
        },
      }
      for _, tc in ipairs(env_mismatch_cases) do
        live_env = set_live_healthy(sb, { systemctl_env_lines = tc.lines })
        local r = run_doctor(sb, { "--profile", "minimal" }, { env = live_env })
        assert_eq(r.rc, 1, tc.name .. " must exit 1:\n" .. r.combined)
        assert_contains(r.combined, "[FAIL]", tc.name .. " must emit [FAIL]")
      end

      -- Passive busctl --user --activatable: missing ANY of the 3 required portals -> [FAIL]
      local required_portals = {
        "org.freedesktop.portal.Desktop",
        "org.freedesktop.impl.portal.desktop.hyprland",
        "org.freedesktop.impl.portal.desktop.gtk",
      }
      for idx, missing in ipairs(required_portals) do
        local subset = { "org.freedesktop.secrets" }
        for j, svc in ipairs(required_portals) do
          if j ~= idx then
            subset[#subset + 1] = svc
          end
        end
        live_env = set_live_healthy(sb, { bus_services = subset })
        local r = run_doctor(sb, { "--profile", "minimal" }, { env = live_env })
        assert_eq(r.rc, 1, "missing portal " .. missing .. " must exit 1:\n" .. r.combined)
        assert_contains(r.combined, "[FAIL]", "missing portal " .. missing .. " must emit [FAIL]")
      end

      -- In full profile, missing org.freedesktop.secrets emits [WARN] (NOT [FAIL], exit 0)
      live_env = set_live_healthy(sb, { bus_services = required_portals })
      local r_nosec = run_doctor(sb, { "--profile", "full" }, { env = live_env })
      assert_eq(r_nosec.rc, 0, "missing org.freedesktop.secrets in full must WARN (exit 0), not FAIL:\n" .. r_nosec.combined)
      assert_contains(r_nosec.combined, "[WARN]", "missing org.freedesktop.secrets in full must emit [WARN]")
      assert_true(not r_nosec.combined:find("[FAIL]", 1, true), "missing org.freedesktop.secrets must not emit [FAIL]")
    end)
  end)

  test("bb.doctor.live_singleton_daemons_matrix", function()
    with_sandbox({ full_bins = true }, function(sb)
      assert_eq(run_apply(sb, { "--yes" }).rc, 0, "apply failed")
      local live_env = set_live_healthy(sb)

      -- Minimal profile matrix: noctalia=1, foot=1 required; fcitx5 not required
      local minimal_cases = {
        { procs = { noctalia = 1, foot = 1, fcitx5 = 0 }, expect_rc = 0 },
        { procs = { noctalia = 0, foot = 1, fcitx5 = 0 }, expect_rc = 1 },
        { procs = { noctalia = 2, foot = 1, fcitx5 = 0 }, expect_rc = 1 },
        { procs = { noctalia = 1, foot = 0, fcitx5 = 0 }, expect_rc = 1 },
        { procs = { noctalia = 1, foot = 2, fcitx5 = 0 }, expect_rc = 1 },
      }
      for _, tc in ipairs(minimal_cases) do
        set_procs(sb, tc.procs)
        local r = run_doctor(sb, { "--profile", "minimal" }, { env = live_env })
        local desc = string.format("minimal noctalia=%d foot=%d", tc.procs.noctalia, tc.procs.foot)
        assert_eq(r.rc, tc.expect_rc, desc .. " expected rc=" .. tc.expect_rc .. ", got " .. r.rc .. ":\n" .. r.combined)
        if tc.expect_rc == 1 then
          assert_contains(r.combined, "[FAIL]", desc .. " must emit [FAIL]")
        end
      end

      -- Full profile matrix: noctalia=1, foot=1, fcitx5=1 required
      local full_cases = {
        { procs = { noctalia = 1, foot = 1, fcitx5 = 1 }, expect_rc = 0 },
        { procs = { noctalia = 1, foot = 1, fcitx5 = 0 }, expect_rc = 1 },
        { procs = { noctalia = 1, foot = 1, fcitx5 = 2 }, expect_rc = 1 },
        { procs = { noctalia = 0, foot = 1, fcitx5 = 1 }, expect_rc = 1 },
        { procs = { noctalia = 2, foot = 1, fcitx5 = 1 }, expect_rc = 1 },
        { procs = { noctalia = 1, foot = 0, fcitx5 = 1 }, expect_rc = 1 },
        { procs = { noctalia = 1, foot = 2, fcitx5 = 1 }, expect_rc = 1 },
      }
      for _, tc in ipairs(full_cases) do
        set_procs(sb, tc.procs)
        local r = run_doctor(sb, { "--profile", "full" }, { env = live_env })
        local desc = string.format("full noctalia=%d foot=%d fcitx5=%d", tc.procs.noctalia, tc.procs.foot, tc.procs.fcitx5)
        assert_eq(r.rc, tc.expect_rc, desc .. " expected rc=" .. tc.expect_rc .. ", got " .. r.rc .. ":\n" .. r.combined)
        if tc.expect_rc == 1 then
          assert_contains(r.combined, "[FAIL]", desc .. " must emit [FAIL]")
        end
      end

      -- Full profile with fcitx5 = false in hypr/user.lua -> fcitx5=0 must PASS
      write_file(sb.config .. "/hypr/user.lua", "return { fcitx5 = false }\n")
      set_procs(sb, { noctalia = 1, foot = 1, fcitx5 = 0 })
      local r_optout = run_doctor(sb, { "--profile", "full" }, { env = live_env })
      assert_eq(r_optout.rc, 0, "full profile with fcitx5=false in user.lua and fcitx5=0 must exit 0:\n" .. r_optout.combined)
      assert_true(not r_optout.combined:find("[FAIL]", 1, true), "fcitx5=false opt-out must have no [FAIL]")
    end)
  end)

  test("bb.doctor.diff_and_template_mode", function()
    with_sandbox({ minimal_bins = true }, function(sb)
      assert_eq(run_apply(sb, { "--yes" }).rc, 0, "apply failed")

      -- --diff against default template on freshly seeded config
      local r_clean = run_doctor(sb, { "--diff" })
      assert_eq(r_clean.rc, 0, "kaze-doctor --diff on freshly seeded config must exit 0:\n" .. r_clean.combined)

      -- --diff --template PATH with custom template that differs from config.toml
      local custom_tpl = sb.root .. "/custom-noctalia.toml"
      write_file(custom_tpl, "[kaze_bb_template_sentinel]\nsentinel_key = true\n")
      local r_custom = run_doctor(sb, { "--diff", "--template", custom_tpl })
      assert_eq(r_custom.rc, 0, "kaze-doctor --diff --template <path> must exit 0:\n" .. r_custom.combined)
      assert_contains(r_custom.combined, "kaze_bb_template_sentinel", "--diff --template must diff against the specified template")

      -- Missing explicit --template path must fail cleanly (non-zero, not silently fall back)
      local missing_tpl = sb.root .. "/no-such-template.toml"
      local r_missing = run_doctor(sb, { "--diff", "--template", missing_tpl })
      assert_true(
        r_missing.rc ~= 0,
        "--diff --template with missing file (" .. missing_tpl .. ") must exit non-zero, got rc="
          .. tostring(r_missing.rc) .. ":\n" .. r_missing.combined
      )
    end)
  end)

  -- =========================================================================
  -- 3. Hyprland Lua Config Evaluation (hypr/hyprland.lua)
  -- =========================================================================

  test("bb.hypr.minimal_default_profile", function()
    with_sandbox({ minimal_bins = true }, function(sb)
      assert_eq(run_apply(sb, { "--yes" }).rc, 0, "apply failed")

      local res, cap = eval_hyprland_lua(sb, abs_repo)
      assert_eq(res.rc, 0, "hypr/hyprland.lua must load with 0 errors under minimal profile:\n" .. res.combined)
      assert_true(cap ~= nil and cap.ok == true, "hyprland.lua capture must report ok=true")

      -- Required env vars
      assert_eq(cap.env["HYPRLAND_NO_SD_VARS"], "1", "must register HYPRLAND_NO_SD_VARS=1")
      assert_eq(cap.env["XDG_CURRENT_DESKTOP"], "Hyprland", "must register XDG_CURRENT_DESKTOP=Hyprland")
      assert_eq(cap.env["XDG_SESSION_TYPE"], "wayland", "must register XDG_SESSION_TYPE=wayland")

      -- Absent env vars under default minimal profile
      assert_eq(cap.env["XMODIFIERS"], nil, "minimal profile must NOT set XMODIFIERS")
      assert_eq(cap.env["AQ_DRM_DEVICES"], nil, "default minimal profile must NOT set AQ_DRM_DEVICES")

      -- dwindle layout
      assert_true(value_has_kv(cap.config, "layout", "dwindle"), "must configure dwindle layout")

      -- 3-finger horizontal workspace gesture
      local has_3f_gesture = list_has_matching_entry(cap.calls.gesture, function(g)
        return value_contains_str(g, "3", true)
          and value_contains_str(g, "horizontal")
          and value_contains_str(g, "workspace")
      end)
      assert_true(has_3f_gesture, "minimal profile must register 3-finger horizontal workspace gesture")

      -- Layer rule: noctalia-no-anim
      local has_noctalia_layer = list_has_matching_entry(cap.calls.layer_rule, function(lr)
        return value_contains_str(lr, "noctalia-no-anim")
      end)
      assert_true(has_noctalia_layer, "must register noctalia-no-anim layer rule")

      -- Required window rules
      local required_wr = {
        "kaze-share-preview",
        "kaze-share-control",
        "kaze-tui-drawer",
        "kaze-mirror-tui",
        "noctalia-settings",
      }
      for _, name in ipairs(required_wr) do
        local found = list_has_matching_entry(cap.calls.window_rule, function(wr)
          return value_contains_str(wr, name)
        end)
        assert_true(found, "must register window rule: " .. name)
      end

      -- Required event handlers
      local required_events = {
        "hyprland.start",
        "monitor.added",
        "monitor.removed",
        "hyprland.shutdown",
      }
      for _, ev in ipairs(required_events) do
        local found = list_has_matching_entry(cap.calls.on, function(entry)
          return entry.event == ev and entry.has_fn == true
        end)
        assert_true(found, "must register hl.on handler for: " .. ev)
      end

      -- Exactly 5 persistent workspaces
      assert_eq(count_persistent_workspaces(cap.calls.workspace_rule), 5, "default minimal profile must register 5 persistent workspaces")
    end)
  end)

  test("bb.hypr.full_profile_and_rich_user_config", function()
    with_sandbox({ full_bins = true }, function(sb)
      assert_eq(run_apply(sb, { "--yes" }).rc, 0, "apply failed")

      write_file(sb.config .. "/hypr/user.lua", [[
return {
  profile = "full",
  smart_gaps = true,
  workspace_swipe = false,
  persistent_workspaces = 7,
  drm_devices = "/dev/dri/card1",
  prefer_mesa_egl = true,
  kb_layout = "de",
  monitors = {
    { output = "eDP-1", mode = "1920x1080@60", position = "0x0", scale = 1 },
  },
}
]])

      local res, cap = eval_hyprland_lua(sb, abs_repo)
      assert_eq(res.rc, 0, "hypr/hyprland.lua with full profile + rich user.lua must exit 0:\n" .. res.combined)
      assert_true(cap ~= nil and cap.ok == true, "hyprland.lua capture must succeed")

      -- Env checks
      assert_eq(cap.env["XMODIFIERS"], "@im=fcitx", "full profile must set XMODIFIERS=@im=fcitx")
      assert_eq(cap.env["AQ_DRM_DEVICES"], "/dev/dri/card1", "drm_devices must set AQ_DRM_DEVICES=/dev/dri/card1")
      assert_true(type(cap.env["__EGL_VENDOR_LIBRARY_FILENAMES"]) == "string" and #cap.env["__EGL_VENDOR_LIBRARY_FILENAMES"] > 0,
        "prefer_mesa_egl must set __EGL_VENDOR_LIBRARY_FILENAMES")

      -- Smart-gap rules: w[tv1] and f[1]
      local has_wtv1 = value_contains_str(cap.calls.workspace_rule, "w[tv1]") or value_contains_str(cap.calls.window_rule, "w[tv1]")
      local has_f1 = value_contains_str(cap.calls.workspace_rule, "f[1]") or value_contains_str(cap.calls.window_rule, "f[1]")
      assert_true(has_wtv1, "smart_gaps=true must register w[tv1] rule")
      assert_true(has_f1, "smart_gaps=true must register f[1] rule")

      -- 7 persistent workspaces
      assert_eq(count_persistent_workspaces(cap.calls.workspace_rule), 7, "persistent_workspaces=7 must register 7 persistent workspaces")

      -- 0 gestures when workspace_swipe = false
      assert_eq(#cap.calls.gesture, 0, "workspace_swipe=false must register 0 gestures")

      -- Custom monitor rule
      local has_edp1 = list_has_matching_entry(cap.calls.monitor, function(m)
        return value_contains_str(m, "eDP-1")
          and value_contains_str(m, "1920x1080@60")
          and value_contains_str(m, "0x0")
          and (value_has_kv(m, "scale", 1) or value_contains_str(m, "1", true))
      end)
      assert_true(has_edp1, "monitors table must register custom eDP-1 monitor rule (mode/pos/scale)")

      -- Keyboard layout "de"
      assert_true(value_has_kv(cap.config, "kb_layout", "de"), "kb_layout='de' must be propagated into hl.config")
    end)
  end)

  test("bb.hypr.broken_user_lua_graceful_recovery", function()
    local broken_variants = {
      { name = "syntax error", content = "return { broken syntax ((( !!" },
      { name = "runtime error", content = "error('simulated crash in user.lua')" },
      { name = "non-table return", content = "return 'not-a-table'" },
    }
    for _, variant in ipairs(broken_variants) do
      with_sandbox({ minimal_bins = true }, function(sb)
        assert_eq(run_apply(sb, { "--yes" }).rc, 0, "apply failed")
        write_file(sb.config .. "/hypr/user.lua", variant.content)

        local res, cap = eval_hyprland_lua(sb, abs_repo)
        assert_eq(res.rc, 0, "broken user.lua (" .. variant.name .. ") must not crash hyprland.lua:\n" .. res.combined)
        assert_true(cap ~= nil and cap.ok == true, "broken user.lua (" .. variant.name .. ") must recover cleanly")

        -- Verify defaults are still loaded
        assert_eq(cap.env["HYPRLAND_NO_SD_VARS"], "1", "recovered defaults must set HYPRLAND_NO_SD_VARS=1")
        assert_eq(cap.env["XDG_CURRENT_DESKTOP"], "Hyprland", "recovered defaults must set XDG_CURRENT_DESKTOP=Hyprland")
        assert_true(value_has_kv(cap.config, "layout", "dwindle"), "recovered defaults must configure dwindle layout")
        assert_eq(count_persistent_workspaces(cap.calls.workspace_rule), 5, "recovered defaults must keep 5 persistent workspaces")
        assert_true(#cap.calls.gesture > 0, "recovered defaults must keep default workspace swipe gesture")
      end)
    end
  end)

  test("bb.hypr.runtime_monitors_and_noctalia_theme_hooks", function()
    with_sandbox({ minimal_bins = true }, function(sb)
      assert_eq(run_apply(sb, { "--yes" }).rc, 0, "apply failed")

      -- Write runtime $XDG_RUNTIME_DIR/kaze/monitors.lua overlay
      write_file(sb.runtime .. "/kaze/monitors.lua", [[
_G._KAZE_BB_MARKERS.monitors_loaded = true
hl.monitor({ output = "DP-9", mode = "2560x1440@144", position = "1920x0", scale = 1.25 })
]])

      -- Write ~/.config/hypr/noctalia.lua providing apply_theme()
      write_file(sb.config .. "/hypr/noctalia.lua", [[
local M = {}
function M.apply_theme()
  _G._KAZE_BB_MARKERS.noctalia_apply_theme_calls = (_G._KAZE_BB_MARKERS.noctalia_apply_theme_calls or 0) + 1
  hl.config({ general = { _kaze_bb_theme_applied = true } })
end
apply_theme = M.apply_theme
return M
]])

      local res, cap = eval_hyprland_lua(sb, abs_repo)
      assert_eq(res.rc, 0, "hyprland.lua with runtime monitors.lua + noctalia.lua must exit 0:\n" .. res.combined)
      assert_true(cap ~= nil and cap.ok == true, "hyprland.lua capture must succeed")

      -- Runtime monitors.lua overlay was applied
      assert_eq(cap.markers.monitors_loaded, true, "$XDG_RUNTIME_DIR/kaze/monitors.lua must be loaded when present")
      local has_dp9 = list_has_matching_entry(cap.calls.monitor, function(m)
        return value_contains_str(m, "DP-9") and value_contains_str(m, "2560x1440@144")
      end)
      assert_true(has_dp9, "runtime monitors.lua overlay must register DP-9 monitor rule")

      -- noctalia.lua's apply_theme() was invoked
      assert_eq(cap.markers.noctalia_apply_theme_calls, 1, "~/.config/hypr/noctalia.lua apply_theme() must be invoked once")
      assert_true(value_has_kv(cap.config, "_kaze_bb_theme_applied", true), "noctalia.lua apply_theme() effects must reach hl.config")
    end)
  end)
end

return run_suite
