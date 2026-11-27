-- Blind black-box & brute-force behavioral test suite for bin/kaze-record.
-- Derived strictly from the Behavioral Specification (no source inspection).

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
    error("write_file(" .. tostring(path) .. "): " .. tostring(err))
  end
  f:write(content or "")
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

local function file_size(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local sz = f:seek("end")
  f:close()
  return sz
end

local function exec_status(cmd)
  local ok, why, code = os.execute(cmd)
  if type(ok) == "number" then
    return ok
  end
  if why == "exit" then
    return code
  elseif why == "signal" then
    return 128 + (code or 0)
  end
  return ok and 0 or 1
end

local function popen_read(cmd)
  local p = io.popen(cmd, "r")
  if not p then
    return ""
  end
  local out = p:read("*a") or ""
  p:close()
  return out
end

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function strip_quotes(s)
  if type(s) ~= "string" then
    return s
  end
  if (#s >= 2 and s:sub(1, 1) == '"' and s:sub(-1) == '"') or
     (#s >= 2 and s:sub(1, 1) == "'" and s:sub(-1) == "'") then
    return s:sub(2, -2)
  end
  return s
end

local function split_lines(s)
  local lines = {}
  if not s or s == "" then
    return lines
  end
  for line in (s .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  if #lines > 0 and lines[#lines] == "" then
    table.remove(lines, #lines)
  end
  return lines
end

local function split_nonempty_lines(s)
  local lines = {}
  for _, line in ipairs(split_lines(s)) do
    if line ~= "" then
      lines[#lines + 1] = line
    end
  end
  return lines
end

local function parse_env_file(path)
  local raw = read_file(path)
  if not raw then
    return nil
  end
  local env = {}
  for _, line in ipairs(split_lines(raw)) do
    local k, v = line:match("^%s*([A-Za-z_][A-Za-z0-9_]*)%s*=%s*(.-)%s*$")
    if k then
      v = strip_quotes(v)
      v = v:gsub('\\"', '"'):gsub("\\\\", "\\")
      env[k] = v
    end
  end
  return env
end

local function list_dir_files(dir)
  local out = popen_read("/usr/bin/find " .. sh_quote(dir) .. " -type f 2>/dev/null")
  return split_nonempty_lines(out)
end

local COREUTILS = {
  "lua", "sh", "bash", "readlink", "flock", "env", "mkdir", "install",
  "mktemp", "rm", "test", "[", "timeout", "sed", "grep", "cat", "head",
  "tail", "dirname", "basename", "sleep", "cp", "mv", "touch", "tr",
  "wc", "awk", "cut", "sort", "printf", "date", "true", "false",
  "stat", "chmod", "ln", "realpath", "id",
}

local COREUTIL_SRCS = {}
for _, tool in ipairs(COREUTILS) do
  local src = "/usr/bin/" .. tool
  if file_exists(src) then
    COREUTIL_SRCS[#COREUTIL_SRCS + 1] = sh_quote(src)
  end
end
local COREUTIL_SRCS_STR = table.concat(COREUTIL_SRCS, " ")

local function resolve_abs_dir(dir)
  local out = popen_read("cd " .. sh_quote(dir) .. " && pwd")
  return trim(out)
end

local function create_sandbox(kaze_record_bin, opts)
  opts = opts or {}
  local root = trim(popen_read("/usr/bin/mktemp -d /tmp/kaze-bb-record-XXXXXX"))
  if root == "" then
    error("mktemp failed to create sandbox")
  end

  local sb = {
    root = root,
    home = root .. "/home",
    videos = root .. "/home/Videos",
    config = root .. "/config",
    data = root .. "/data",
    cache = root .. "/cache",
    state = root .. "/state",
    runtime = root .. "/runtime",
    runtime_kaze = root .. "/runtime/kaze",
    bin = root .. "/bin",
    mock = root .. "/mock",
    kaze_record_bin = kaze_record_bin,
    bg_pids = {},
  }

  -- Create sandbox directory tree and symlink whitelisted coreutils in one shell call.
  exec_status("/usr/bin/mkdir -p " ..
    sh_quote(sb.home) .. " " ..
    sh_quote(sb.videos) .. " " ..
    sh_quote(sb.config .. "/kaze") .. " " ..
    sh_quote(sb.data) .. " " ..
    sh_quote(sb.cache) .. " " ..
    sh_quote(sb.state) .. " " ..
    sh_quote(sb.runtime) .. " " ..
    sh_quote(sb.bin) .. " " ..
    sh_quote(sb.mock) ..
    " && /usr/bin/ln -s -t " .. sh_quote(sb.bin) .. " " .. COREUTIL_SRCS_STR)

  -- Default mock configuration files.
  write_file(sb.mock .. "/systemctl_state", opts.active_state or "inactive")
  write_file(sb.mock .. "/systemctl_session_active", opts.session_active == false and "0" or "1")
  write_file(sb.mock .. "/systemctl_show_env",
    opts.show_env or "HYPRLAND_INSTANCE_SIGNATURE=test-sig-1\nWAYLAND_DISPLAY=wayland-1\n")
  write_file(sb.mock .. "/systemctl_start_rc", tostring(opts.start_rc or 0))
  write_file(sb.mock .. "/systemctl_stop_rc", tostring(opts.stop_rc or 0))
  write_file(sb.mock .. "/systemctl_finalize_mode", opts.finalize_mode or "ok")
  write_file(sb.mock .. "/noctalia_widget_type", opts.widget_type or "'custom_button'\n")
  write_file(sb.mock .. "/dmenu_mode", opts.dmenu_mode or "esc")
  write_file(sb.mock .. "/dmenu_arg", opts.dmenu_arg or "")
  write_file(sb.mock .. "/slurp_stdout", opts.slurp_stdout or "100,200 800x600\neDP-1\n")
  write_file(sb.mock .. "/slurp_stderr", opts.slurp_stderr or "")
  write_file(sb.mock .. "/slurp_rc", tostring(opts.slurp_rc or 0))
  write_file(sb.mock .. "/hyprctl_monitors", opts.monitors_json or
    '[{"id":0,"name":"eDP-1","width":1920,"height":1080,"focused":true},{"id":1,"name":"HDMI-A-1","width":2560,"height":1440,"focused":false}]\n')
  write_file(sb.mock .. "/pactl_default_sink", opts.default_sink or "alsa_output.pci-0000_00_1f.3.analog-stereo\n")
  write_file(sb.mock .. "/pactl_sink_rc", tostring(opts.pactl_sink_rc or 0))
  write_file(sb.mock .. "/pactl_default_source", opts.default_source or "alsa_input.pci-0000_00_1f.3.analog-stereo\n")
  write_file(sb.mock .. "/pactl_source_rc", tostring(opts.pactl_source_rc or 0))
  write_file(sb.mock .. "/pactl_list_sources", opts.list_sources or
    "42\talsa_output.fallback.monitor\tPipeWire\tfloat32le 2ch 48000Hz\tIDLE\n43\talsa_input.mic\tPipeWire\tfloat32le 1ch 48000Hz\tSUSPENDED\n")
  write_file(sb.mock .. "/pactl_list_rc", tostring(opts.pactl_list_rc or 0))
  write_file(sb.mock .. "/ffmpeg_mode", opts.ffmpeg_mode or "ok")
  write_file(sb.mock .. "/ffprobe_rc", tostring(opts.ffprobe_rc or 0))

  if opts.style then
    write_file(sb.config .. "/kaze/style", opts.style .. "\n")
  end

  local mock_q = sh_quote(sb.mock)
  local rt_kaze_q = sh_quote(sb.runtime_kaze)
  local skip = opts.omit_tools or {}
  local stub_paths = {}

  local function add_stub(name, content)
    if skip[name] then
      return
    end
    local p = sb.bin .. "/" .. name
    write_file(p, content)
    stub_paths[#stub_paths + 1] = sh_quote(p)
  end

  -- systemctl stub
  add_stub("systemctl", string.format([=[#!/bin/sh
MOCK=%s
RT_KAZE=%s
printf '%%s\n' "$*" >> "$MOCK/systemctl.log"

if [ "$1" = "--user" ]; then
  shift
fi

cmd="$1"
shift || true

case "$cmd" in
  show-environment)
    cat "$MOCK/systemctl_show_env"
    exit 0
    ;;
  is-active)
    quiet=0
    unit=""
    for a in "$@"; do
      case "$a" in
        -q|--quiet) quiet=1 ;;
        *) unit="$a" ;;
      esac
    done
    if [ "$unit" = "kaze-session.target" ]; then
      active=$(cat "$MOCK/systemctl_session_active")
      if [ "$active" = "1" ]; then
        [ "$quiet" = "0" ] && echo "active"
        exit 0
      else
        [ "$quiet" = "0" ] && echo "inactive"
        exit 3
      fi
    elif [ "$unit" = "kaze-record.service" ]; then
      st=$(cat "$MOCK/systemctl_state")
      if [ "$st" = "active" ] || [ "$st" = "activating" ]; then
        [ "$quiet" = "0" ] && echo "$st"
        exit 0
      else
        [ "$quiet" = "0" ] && echo "$st"
        exit 3
      fi
    fi
    exit 0
    ;;
  show)
    val_only=0
    for a in "$@"; do
      if [ "$a" = "--value" ]; then
        val_only=1
      fi
    done
    st=$(cat "$MOCK/systemctl_state")
    if [ "$val_only" = "1" ]; then
      printf '%%s\n' "$st"
    else
      printf 'ActiveState=%%s\n' "$st"
    fi
    exit 0
    ;;
  start)
    rc=$(cat "$MOCK/systemctl_start_rc")
    if [ "$rc" != "0" ]; then
      echo "Job for kaze-record.service failed." >&2
      exit "$rc"
    fi
    printf 'active' > "$MOCK/systemctl_state"
    mode=$(cat "$MOCK/systemctl_finalize_mode")
    if [ -f "$RT_KAZE/record.env" ] && [ "$mode" != "empty_file" ]; then
      rec_file=$(sh -c '. "$1" >/dev/null 2>&1; printf "%%s" "$KAZE_RECORD_FILE"' _ "$RT_KAZE/record.env")
      if [ -n "$rec_file" ]; then
        mkdir -p "$(dirname "$rec_file")"
        printf 'MOCK_MP4_STREAM_DATA\n' > "$rec_file"
      fi
    fi
    exit 0
    ;;
  stop)
    rc=$(cat "$MOCK/systemctl_stop_rc")
    if [ "$rc" != "0" ]; then
      echo "Failed to stop kaze-record.service." >&2
      exit "$rc"
    fi
    prev=$(cat "$MOCK/systemctl_state")
    printf 'inactive' > "$MOCK/systemctl_state"
    mode=$(cat "$MOCK/systemctl_finalize_mode")
    if [ -f "$RT_KAZE/record.env" ] && { [ "$prev" = "active" ] || [ "$prev" = "activating" ]; }; then
      rec_file=$(sh -c '. "$1" >/dev/null 2>&1; printf "%%s" "$KAZE_RECORD_FILE"' _ "$RT_KAZE/record.env")
      if [ -n "$rec_file" ]; then
        if [ "$mode" = "ok" ]; then
          mkdir -p "$(dirname "$rec_file")"
          printf 'MOCK_MP4_FINALIZED_DATA\n' > "$rec_file"
          printf '%%s\n' "$rec_file" > "$RT_KAZE/record.done"
        elif [ "$mode" = "mismatch_done" ]; then
          mkdir -p "$(dirname "$rec_file")"
          printf 'MOCK_MP4_FINALIZED_DATA\n' > "$rec_file"
          printf '%%s\n' "${rec_file}.mismatched.mp4" > "$RT_KAZE/record.done"
        elif [ "$mode" = "blank_done" ]; then
          mkdir -p "$(dirname "$rec_file")"
          printf 'MOCK_MP4_FINALIZED_DATA\n' > "$rec_file"
          printf '   \n' > "$RT_KAZE/record.done"
        elif [ "$mode" = "no_done" ]; then
          mkdir -p "$(dirname "$rec_file")"
          printf 'MOCK_MP4_FINALIZED_DATA\n' > "$rec_file"
          rm -f "$RT_KAZE/record.done"
        elif [ "$mode" = "skip_done" ]; then
          mkdir -p "$(dirname "$rec_file")"
          printf 'MOCK_MP4_FINALIZED_DATA\n' > "$rec_file"
        elif [ "$mode" = "empty_file" ]; then
          mkdir -p "$(dirname "$rec_file")"
          : > "$rec_file"
          printf '%%s\n' "$rec_file" > "$RT_KAZE/record.done"
        fi
      fi
    fi
    exit 0
    ;;
  reset-failed|import-environment)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
]=], mock_q, rt_kaze_q))

  -- noctalia stub
  add_stub("noctalia", string.format([=[#!/bin/sh
MOCK=%s
printf '%%s\n' "$*" >> "$MOCK/noctalia_raw.log"

if [ "$1" = "msg" ] && [ "$2" = "config-get" ]; then
  printf 'GET\t%%s\n' "$3" >> "$MOCK/noctalia.log"
  if [ "$3" = "widget.record.type" ]; then
    cat "$MOCK/noctalia_widget_type"
    exit 0
  fi
  exit 1
elif [ "$1" = "msg" ] && [ "$2" = "config-set" ]; then
  printf 'SET\t%%s\t%%s\n' "$3" "$4" >> "$MOCK/noctalia.log"
  exit 0
elif [ "$1" = "dmenu" ]; then
  printf 'DMENU\t%%s\n' "$*" >> "$MOCK/noctalia.log"
  cat > "$MOCK/dmenu_items.txt"
  mode=$(cat "$MOCK/dmenu_mode")
  arg=$(cat "$MOCK/dmenu_arg")
  case "$mode" in
    esc)
      exit 1
      ;;
    esc0)
      exit 0
      ;;
    match)
      hit=$(grep -F -m1 -- "$arg" "$MOCK/dmenu_items.txt")
      if [ -n "$hit" ]; then
        printf '%%s\n' "$hit"
        exit 0
      fi
      exit 1
      ;;
    line)
      hit=$(sed -n "${arg}p" "$MOCK/dmenu_items.txt")
      if [ -n "$hit" ]; then
        printf '%%s\n' "$hit"
        exit 0
      fi
      exit 1
      ;;
    literal)
      printf '%%s\n' "$arg"
      exit 0
      ;;
  esac
  exit 1
fi
exit 0
]=], mock_q))

  -- slurp stub
  add_stub("slurp", string.format([=[#!/bin/sh
MOCK=%s
printf '%%s\n' "$*" >> "$MOCK/slurp.log"
cat "$MOCK/slurp_stdout"
cat "$MOCK/slurp_stderr" >&2
exit $(cat "$MOCK/slurp_rc")
]=], mock_q))

  -- hyprctl stub
  add_stub("hyprctl", string.format([=[#!/bin/sh
MOCK=%s
printf '%%s\n' "$*" >> "$MOCK/hyprctl.log"
case "$*" in
  *monitors*)
    cat "$MOCK/hyprctl_monitors"
    exit 0
    ;;
esac
exit 0
]=], mock_q))

  -- pactl stub
  add_stub("pactl", string.format([=[#!/bin/sh
MOCK=%s
printf '%%s\n' "$*" >> "$MOCK/pactl.log"
case "$1" in
  get-default-sink)
    cat "$MOCK/pactl_default_sink"
    exit $(cat "$MOCK/pactl_sink_rc")
    ;;
  get-default-source)
    cat "$MOCK/pactl_default_source"
    exit $(cat "$MOCK/pactl_source_rc")
    ;;
  list)
    cat "$MOCK/pactl_list_sources"
    exit $(cat "$MOCK/pactl_list_rc")
    ;;
esac
exit 0
]=], mock_q))

  -- ffmpeg stub
  add_stub("ffmpeg", string.format([=[#!/bin/sh
MOCK=%s
{
  first=1
  for a in "$@"; do
    if [ "$first" = "1" ]; then
      printf '%%s' "$a"
      first=0
    else
      printf '\t%%s' "$a"
    fi
  done
  printf '\n'
} >> "$MOCK/ffmpeg.log"

mode=$(cat "$MOCK/ffmpeg_mode")
last=""
for a in "$@"; do
  last="$a"
done

case "$mode" in
  fail)
    echo "ffmpeg mock conversion failed" >&2
    exit 1
    ;;
  empty)
    case "$last" in
      -*|"") ;;
      *)
        mkdir -p "$(dirname "$last")"
        : > "$last"
        ;;
    esac
    exit 0
    ;;
  ok)
    case "$last" in
      -*|"") ;;
      *)
        mkdir -p "$(dirname "$last")"
        printf 'GIF89aMOCKDATA\n' > "$last"
        ;;
    esac
    exit 0
    ;;
esac
exit 0
]=], mock_q))

  -- ffprobe stub
  add_stub("ffprobe", string.format([=[#!/bin/sh
MOCK=%s
printf '%%s\n' "$*" >> "$MOCK/ffprobe.log"
rc=$(cat "$MOCK/ffprobe_rc")
if [ "$rc" != "0" ]; then
  echo "ffprobe mock failure" >&2
  exit "$rc"
fi
last=""
for a in "$@"; do
  last="$a"
done
case "$last" in
  -*|"") ;;
  *)
    if [ ! -s "$last" ]; then
      echo "ffprobe: empty or missing file: $last" >&2
      exit 1
    fi
    ;;
esac
case "$*" in
  *json*)
    printf '{"streams":[{"codec_type":"video","width":1920,"height":1080}],"format":{"duration":"1.500000"}}\n'
    ;;
  *duration*)
    printf '1.500000\n'
    ;;
  *codec_type*)
    printf 'video\n'
    ;;
esac
exit 0
]=], mock_q))

  -- wf-recorder stub
  add_stub("wf-recorder", string.format([=[#!/bin/sh
MOCK=%s
printf '%%s\n' "$*" >> "$MOCK/wf_recorder.log"
exit 0
]=], mock_q))

  -- notify-send stub
  add_stub("notify-send", string.format([=[#!/bin/sh
MOCK=%s
{
  first=1
  for a in "$@"; do
    if [ "$first" = "1" ]; then
      printf '%%s' "$a"
      first=0
    else
      printf '\t%%s' "$a"
    fi
  done
  printf '\n'
} >> "$MOCK/notify.log"
exit 0
]=], mock_q))

  -- dbus-update-activation-environment stub
  add_stub("dbus-update-activation-environment", string.format([=[#!/bin/sh
MOCK=%s
printf '%%s\n' "$*" >> "$MOCK/dbus.log"
exit 0
]=], mock_q))

  -- xdg-user-dir stub
  add_stub("xdg-user-dir", string.format([=[#!/bin/sh
MOCK=%s
printf '%%s\n' "$*" >> "$MOCK/xdg_user_dir.log"
if [ "$1" = "VIDEOS" ]; then
  printf '%%s/Videos\n' "$HOME"
else
  printf '%%s\n' "$HOME"
fi
exit 0
]=], mock_q))

  if #stub_paths > 0 then
    local rc = exec_status("/usr/bin/chmod +x " .. table.concat(stub_paths, " "))
    if rc ~= 0 then
      error("chmod +x failed on mock stubs")
    end
  end

  function sb:set_mock(name, val)
    write_file(self.mock .. "/" .. name, tostring(val))
  end

  function sb:set_style(style)
    if style == nil then
      exec_status("/usr/bin/rm -f " .. sh_quote(self.config .. "/kaze/style"))
    else
      write_file(self.config .. "/kaze/style", style .. "\n")
    end
  end

  function sb:clear_logs()
    exec_status("/usr/bin/rm -f " ..
      sh_quote(self.mock .. "/systemctl.log") .. " " ..
      sh_quote(self.mock .. "/noctalia.log") .. " " ..
      sh_quote(self.mock .. "/noctalia_raw.log") .. " " ..
      sh_quote(self.mock .. "/slurp.log") .. " " ..
      sh_quote(self.mock .. "/hyprctl.log") .. " " ..
      sh_quote(self.mock .. "/pactl.log") .. " " ..
      sh_quote(self.mock .. "/ffmpeg.log") .. " " ..
      sh_quote(self.mock .. "/ffprobe.log") .. " " ..
      sh_quote(self.mock .. "/wf_recorder.log") .. " " ..
      sh_quote(self.mock .. "/notify.log") .. " " ..
      sh_quote(self.mock .. "/dbus.log") .. " " ..
      sh_quote(self.mock .. "/xdg_user_dir.log") .. " " ..
      sh_quote(self.mock .. "/dmenu_items.txt"))
  end

  function sb:read_log(name)
    return read_file(self.mock .. "/" .. name) or ""
  end

  function sb:noctalia_sets()
    local sets = {}
    local ordered = {}
    for _, line in ipairs(split_lines(self:read_log("noctalia.log"))) do
      local key, val = line:match("^SET\t([^\t]+)\t(.*)$")
      if key then
        local norm = strip_quotes(val)
        sets[key] = norm
        ordered[#ordered + 1] = { key = key, val = norm, raw = val }
      end
    end
    return sets, ordered
  end

  function sb:noctalia_dmenu_called()
    for _, line in ipairs(split_lines(self:read_log("noctalia.log"))) do
      if line:match("^DMENU\t") then
        return true
      end
    end
    return false
  end

  function sb:systemctl_calls()
    return split_nonempty_lines(self:read_log("systemctl.log"))
  end

  function sb:systemctl_called_with(substr)
    for _, line in ipairs(self:systemctl_calls()) do
      if line:find(substr, 1, true) then
        return true
      end
    end
    return false
  end

  function sb:run(args, env_overrides)
    args = args or {}
    local env = {
      PATH = self.bin,
      HOME = self.home,
      XDG_CONFIG_HOME = self.config,
      XDG_DATA_HOME = self.data,
      XDG_CACHE_HOME = self.cache,
      XDG_STATE_HOME = self.state,
      XDG_RUNTIME_DIR = self.runtime,
      HYPRLAND_INSTANCE_SIGNATURE = "test-sig-1",
      WAYLAND_DISPLAY = "wayland-1",
      USER = "tester",
      LANG = "C.UTF-8",
      LC_ALL = "C.UTF-8",
      TERM = "dumb",
    }
    if env_overrides then
      for k, v in pairs(env_overrides) do
        if v == false then
          env[k] = nil
        else
          env[k] = tostring(v)
        end
      end
    end

    local parts = { "/usr/bin/env", "-i" }
    local keys = {}
    for k in pairs(env) do
      keys[#keys + 1] = k
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
      parts[#parts + 1] = sh_quote(k .. "=" .. env[k])
    end
    parts[#parts + 1] = "/usr/bin/timeout"
    parts[#parts + 1] = "5"
    parts[#parts + 1] = sh_quote(self.kaze_record_bin)
    for _, a in ipairs(args) do
      parts[#parts + 1] = sh_quote(a)
    end

    local out_f = self.mock .. "/last.stdout"
    local err_f = self.mock .. "/last.stderr"
    local cmd = table.concat(parts, " ") ..
      " > " .. sh_quote(out_f) ..
      " 2> " .. sh_quote(err_f)

    local code = exec_status(cmd)
    local stdout = read_file(out_f) or ""
    local stderr = read_file(err_f) or ""
    return {
      code = code,
      stdout = stdout,
      stderr = stderr,
      out = stdout .. stderr,
    }
  end

  function sb:cleanup()
    for _, pid in ipairs(self.bg_pids) do
      exec_status("kill " .. tostring(pid) .. " 2>/dev/null || true")
    end
    exec_status("/usr/bin/rm -rf -- " .. sh_quote(self.root))
  end

  return sb
end

local function with_sandbox(kaze_record_bin, opts, fn)
  if type(opts) == "function" then
    fn = opts
    opts = {}
  end
  local sb = create_sandbox(kaze_record_bin, opts)
  local ok, err = pcall(fn, sb)
  sb:cleanup()
  if not ok then
    error(err, 0)
  end
end

local function run_suite(test, assert_eq, assert_true, assert_contains, repo_dir)
  local abs_repo = resolve_abs_dir(repo_dir or ".")
  local kaze_record_bin = abs_repo .. "/bin/kaze-record"

  -- 1. CLI Argument Matrix & Invalid Combinations (Exit 2)
  test("bb.record.cli_help_and_invalid_matrix", function()
    with_sandbox(kaze_record_bin, function(sb)
      for _, flag in ipairs({ "-h", "--help" }) do
        sb:clear_logs()
        local r = sb:run({ flag })
        assert_eq(r.code, 0, flag .. " should exit 0")
        assert_contains(r.out, "Usage", flag .. " should print Usage")
        assert_true(not sb:systemctl_called_with("start "), flag .. " must not start service")
      end

      local invalid_cases = {
        -- Invalid --audio values and duplicates
        { "--audio=bogus" },
        { "--audio=" },
        { "start", "--audio=invalid" },
        { "start", "--audio", "bogus" },
        { "--audio", "--audio" },
        { "start", "--audio=desktop", "--audio=mic" },
        { "start", "--audio=desktop", "--audio=desktop" },
        { "start", "--audio=off", "--audio=off" },
        { "start", "--audio", "--audio=off" },
        -- --gif combined with audio (all forms & verbs)
        { "--gif", "--audio" },
        { "--audio", "--gif" },
        { "--gif", "--audio=desktop" },
        { "--audio=desktop", "--gif" },
        { "--gif", "--audio", "desktop" },
        { "--audio", "desktop", "--gif" },
        { "--gif", "--audio=mic" },
        { "--audio=mic", "--gif" },
        { "--gif", "--audio", "mic" },
        { "--audio", "mic", "--gif" },
        { "start", "--gif", "--audio" },
        { "start", "--gif", "--audio=desktop" },
        { "start", "--gif", "--audio=mic" },
        { "toggle", "--gif", "--audio" },
        { "toggle", "--gif", "--audio=desktop" },
        { "toggle", "--gif", "--audio=mic" },
        -- Modifier before non-recording action
        { "--region", "stop" },
        { "--gif", "status" },
        { "--audio", "--menu" },
        { "--gif", "--bar" },
        { "--audio=desktop", "stop" },
        -- Unknown flags / verbs
        { "--bogus" },
        { "-x" },
        { "invalid-verb" },
        { "start", "--unknown-flag" },
      }

      -- Exhaustive pairs of two actions (all 6x6 pairs)
      local actions = { "toggle", "start", "stop", "status", "--menu", "--bar" }
      for _, a1 in ipairs(actions) do
        for _, a2 in ipairs(actions) do
          invalid_cases[#invalid_cases + 1] = { a1, a2 }
        end
      end

      -- Non-recording actions combined with recording modifiers
      for _, act in ipairs({ "stop", "status", "--menu", "--bar" }) do
        for _, mod in ipairs({
          { "--region" },
          { "--audio" },
          { "--audio=desktop" },
          { "--audio=mic" },
          { "--audio=off" },
          { "--gif" },
        }) do
          local combo = { act }
          for _, m in ipairs(mod) do
            combo[#combo + 1] = m
          end
          invalid_cases[#invalid_cases + 1] = combo
        end
      end

      for _, args in ipairs(invalid_cases) do
        sb:clear_logs()
        local label = table.concat(args, " ")
        local r = sb:run(args)
        assert_eq(r.code, 2, "invalid args '" .. label .. "' must exit 2 (out=" .. r.out .. ")")
        assert_true(not sb:systemctl_called_with("start "), "invalid args '" .. label .. "' must not start service")
        assert_true(not sb:systemctl_called_with("stop "), "invalid args '" .. label .. "' must not stop service")
      end
    end)

    -- Valid edge case: --gif --audio=off MUST be accepted (not exit 2).
    for _, args in ipairs({
      { "start", "--gif", "--audio=off" },
      { "start", "--audio=off", "--gif" },
      { "start", "--gif", "--audio", "off" },
    }) do
      with_sandbox(kaze_record_bin, function(sb)
        local r = sb:run(args)
        local label = table.concat(args, " ")
        assert_eq(r.code, 0, "valid edge case '" .. label .. "' should exit 0 (err=" .. r.stderr .. ")")
        local env = parse_env_file(sb.runtime_kaze .. "/record.env")
        assert_true(env ~= nil, label .. " should write record.env")
        assert_eq(env.KAZE_RECORD_FORMAT, "gif", label .. " should set format=gif")
        assert_eq(env.KAZE_RECORD_AUDIO, "", label .. " should leave audio empty")
      end)
    end
  end)

  -- 2. status Truth Table
  test("bb.record.status_truth_table", function()
    local table_cases = {
      { state = "active", expected = "on\n" },
      { state = "activating", expected = "on\n" },
      { state = "inactive", expected = "off\n" },
      { state = "failed", expected = "off\n" },
      { state = "deactivating", expected = "off\n" },
    }
    with_sandbox(kaze_record_bin, function(sb)
      for _, c in ipairs(table_cases) do
        sb:set_mock("systemctl_state", c.state)
        local r = sb:run({ "status" })
        assert_eq(r.code, 0, "status for ActiveState=" .. c.state .. " should exit 0")
        assert_eq(r.stdout, c.expected, "status output for ActiveState=" .. c.state)
      end
    end)
  end)

  -- 3. Start / Stop / Toggle State Machine
  test("bb.record.start_stop_toggle_lifecycle", function()
    with_sandbox(kaze_record_bin, {
      monitors_json = '[{"id":0,"name":"eDP-1","width":1920,"height":1080,"focused":false},{"id":1,"name":"HDMI-A-1","width":2560,"height":1440,"focused":true}]\n',
    }, function(sb)
      -- Start when inactive
      local r_start = sb:run({ "start" })
      assert_eq(r_start.code, 0, "start when inactive should exit 0 (err=" .. r_start.stderr .. ")")
      assert_true(sb:systemctl_called_with("start kaze-record.service"), "start must call systemctl start")

      local env_path = sb.runtime_kaze .. "/record.env"
      local env = parse_env_file(env_path)
      assert_true(env ~= nil, "start must write record.env")
      assert_eq(env.KAZE_RECORD_FORMAT, "mp4", "default format must be mp4")
      assert_true(env.KAZE_RECORD_FILE and env.KAZE_RECORD_FILE:match("%.mp4$") ~= nil,
        "KAZE_RECORD_FILE must end with .mp4, got " .. tostring(env.KAZE_RECORD_FILE))
      assert_eq(env.KAZE_RECORD_OUTPUT, "HDMI-A-1", "KAZE_RECORD_OUTPUT must match focused monitor")
      assert_eq(env.KAZE_RECORD_REGION, "", "KAZE_RECORD_REGION should be empty for full-screen")
      assert_eq(env.KAZE_RECORD_AUDIO, "", "KAZE_RECORD_AUDIO should be empty by default")

      local sets_start = sb:noctalia_sets()
      assert_eq(sets_start["widget.record.glyph"], "circle-dot", "start must set glyph=circle-dot")
      assert_eq(sets_start["widget.record.icon_color"], "error", "start must set icon_color=error")
      assert_true(sets_start["widget.record.tooltip"] ~= nil and sets_start["widget.record.tooltip"] ~= "",
        "start must update widget.record.tooltip")

      local orig_env_raw = read_file(env_path)
      local rec_file = env.KAZE_RECORD_FILE

      -- Start when already active or activating -> idempotent no-op
      for _, busy_state in ipairs({ "active", "activating" }) do
        sb:set_mock("systemctl_state", busy_state)
        sb:clear_logs()
        local r_dup = sb:run({ "start" })
        assert_eq(r_dup.code, 0, "duplicate start when " .. busy_state .. " must exit 0")
        assert_true(not sb:systemctl_called_with("start "), "duplicate start (" .. busy_state .. ") must not restart service")
        assert_true(not sb:systemctl_called_with("stop "), "duplicate start (" .. busy_state .. ") must not stop service")
        assert_eq(read_file(env_path), orig_env_raw, "duplicate start (" .. busy_state .. ") must not overwrite record.env")
      end
      sb:set_mock("systemctl_state", "active")

      -- Stop when active -> finalizes, updates record.last, prints path, notifies, resets indicator
      sb:clear_logs()
      local r_stop = sb:run({ "stop" })
      assert_eq(r_stop.code, 0, "stop when active should exit 0 (err=" .. r_stop.stderr .. ")")
      assert_true(sb:systemctl_called_with("stop kaze-record.service"), "stop must call systemctl stop")
      assert_eq(trim(r_stop.stdout), rec_file, "stop must print saved .mp4 path")
      assert_eq(trim(read_file(sb.runtime_kaze .. "/record.last")), rec_file,
        "stop must write saved .mp4 path to record.last")
      assert_true(trim(sb:read_log("notify.log")) ~= "", "stop must send notify-send notification")

      local sets_stop = sb:noctalia_sets()
      assert_eq(sets_stop["widget.record.glyph"], "video", "stop must reset glyph=video")
      assert_eq(sets_stop["widget.record.icon_color"], "on_surface_variant",
        "stop must reset icon_color=on_surface_variant")

      -- Toggle & default no-arg: idle -> start, active -> stop
      for _, toggle_args in ipairs({ { "toggle" }, {} }) do
        local tag = #toggle_args == 0 and "<default>" or "toggle"
        sb:clear_logs()
        local r_t1 = sb:run(toggle_args)
        assert_eq(r_t1.code, 0, tag .. " when idle should start (err=" .. r_t1.stderr .. ")")
        assert_true(sb:systemctl_called_with("start kaze-record.service"), tag .. " when idle must start service")
        local env2 = parse_env_file(env_path)
        assert_true(env2 ~= nil and env2.KAZE_RECORD_FILE ~= "", tag .. " start must write record.env")

        sb:clear_logs()
        local r_t2 = sb:run(toggle_args)
        assert_eq(r_t2.code, 0, tag .. " when active should stop (err=" .. r_t2.stderr .. ")")
        assert_true(sb:systemctl_called_with("stop kaze-record.service"), tag .. " when active must stop service")
        assert_eq(trim(r_t2.stdout), env2.KAZE_RECORD_FILE, tag .. " stop must print saved path")
      end
    end)
  end)

  -- 4. Stop Edge Cases & Incomplete-Recording Failures
  test("bb.record.stop_edge_and_incomplete_failures", function()
    -- 4a. stop when inactive: exits 0, does not start, resets indicator
    with_sandbox(kaze_record_bin, function(sb)
      sb:set_mock("systemctl_state", "inactive")
      local r = sb:run({ "stop" })
      assert_eq(r.code, 0, "stop when inactive must exit 0 (err=" .. r.stderr .. ")")
      assert_true(not sb:systemctl_called_with("start "), "stop when inactive must not start recording")
      local sets = sb:noctalia_sets()
      assert_eq(sets["widget.record.glyph"], "video", "stop when inactive must reset glyph=video")
      assert_eq(sets["widget.record.icon_color"], "on_surface_variant",
        "stop when inactive must reset icon_color=on_surface_variant")
    end)

    -- 4b. stop when ActiveState=failed (both with and without record.env): exits non-zero with incomplete warning
    with_sandbox(kaze_record_bin, function(sb)
      local r_s = sb:run({ "start" })
      assert_eq(r_s.code, 0, "pre-start failed")
      sb:set_mock("systemctl_state", "failed")
      sb:clear_logs()
      local r = sb:run({ "stop" })
      assert_true(r.code ~= 0, "stop when ActiveState=failed must exit non-zero")
      local combined = (r.out .. "\n" .. sb:read_log("notify.log")):lower()
      assert_contains(combined, "incomplete", "stop on failed unit must warn about incomplete recording")

      exec_status("/usr/bin/rm -f " .. sh_quote(sb.runtime_kaze .. "/record.env"))
      sb:set_mock("systemctl_state", "failed")
      sb:clear_logs()
      local r2 = sb:run({ "stop" })
      assert_true(r2.code ~= 0, "stop when ActiveState=failed without record.env must exit non-zero")
      local combined2 = (r2.out .. "\n" .. sb:read_log("notify.log")):lower()
      assert_contains(combined2, "incomplete", "stop on failed unit without record.env must warn incomplete")
    end)

    -- 4c. stop when record.done is missing, blank, or mismatched -> fails with "recording may be incomplete"
    for _, mode in ipairs({ "no_done", "blank_done", "mismatch_done" }) do
      with_sandbox(kaze_record_bin, { finalize_mode = mode }, function(sb)
        local r_s = sb:run({ "start" })
        assert_eq(r_s.code, 0, "start (" .. mode .. ") should succeed")
        sb:clear_logs()
        local r = sb:run({ "stop" })
        assert_true(r.code ~= 0, "stop (" .. mode .. ") must exit non-zero")
        local combined = r.out .. "\n" .. sb:read_log("notify.log")
        assert_contains(combined:lower(), "recording may be incomplete",
          mode .. " must report 'recording may be incomplete'")
        assert_true(not file_exists(sb.runtime_kaze .. "/record.last"),
          mode .. " must not populate record.last")
      end)
    end

    -- 4d. Stale record.done left before start must NOT mask an incomplete recording
    with_sandbox(kaze_record_bin, { finalize_mode = "skip_done" }, function(sb)
      exec_status("/usr/bin/mkdir -p " .. sh_quote(sb.runtime_kaze))
      write_file(sb.runtime_kaze .. "/record.done", sb.videos .. "/stale-previous.mp4\n")
      assert_eq(sb:run({ "start" }).code, 0, "start with stale record.done should succeed")
      sb:clear_logs()
      local r2 = sb:run({ "stop" })
      assert_true(r2.code ~= 0, "stop without fresh record.done must fail non-zero")
      local combined = (r2.out .. "\n" .. sb:read_log("notify.log")):lower()
      assert_contains(combined, "recording may be incomplete",
        "stale record.done must not satisfy a subsequent recording")
    end)

    -- 4e. stop when ActiveState=activating stops cleanly
    with_sandbox(kaze_record_bin, function(sb)
      assert_eq(sb:run({ "start" }).code, 0, "start failed")
      sb:set_mock("systemctl_state", "activating")
      sb:clear_logs()
      local r = sb:run({ "stop" })
      assert_eq(r.code, 0, "stop when activating should succeed (err=" .. r.stderr .. ")")
      assert_true(sb:systemctl_called_with("stop kaze-record.service"), "stop when activating must stop unit")
    end)
  end)

  -- 5. Region Capture (--region) & Slurp Validation
  test("bb.record.region_capture_and_slurp_validation", function()
    -- 5a. Valid slurp output sets KAZE_RECORD_REGION and KAZE_RECORD_OUTPUT (including with --audio)
    with_sandbox(kaze_record_bin, {
      slurp_stdout = "100,200 800x600\nHDMI-A-1\n",
      slurp_rc = 0,
      default_sink = "alsa_output.pci.stereo\n",
    }, function(sb)
      local r = sb:run({ "start", "--audio", "--region" })
      assert_eq(r.code, 0, "valid --audio --region start should exit 0 (err=" .. r.stderr .. ")")
      assert_true(sb:systemctl_called_with("start kaze-record.service"), "valid --region must start service")
      local env = parse_env_file(sb.runtime_kaze .. "/record.env")
      assert_true(env ~= nil, "--region must write record.env")
      assert_eq(env.KAZE_RECORD_REGION, "100,200 800x600", "KAZE_RECORD_REGION mismatch")
      assert_eq(env.KAZE_RECORD_OUTPUT, "HDMI-A-1", "KAZE_RECORD_OUTPUT must match slurp output")
      assert_eq(env.KAZE_RECORD_AUDIO, "alsa_output.pci.stereo.monitor",
        "--audio followed by --region must default to desktop monitor audio")
    end)

    -- 5b. Empty slurp output (Esc cancel: rc=1 with stderr, rc=1 silent, rc=0) exits 0 without starting or leaving temp files
    for _, c in ipairs({
      { name = "rc1_cancelled", rc = 1, stderr = "selection cancelled\n" },
      { name = "rc1_silent", rc = 1, stderr = "" },
      { name = "rc0_empty", rc = 0, stderr = "" },
    }) do
      with_sandbox(kaze_record_bin, {
        slurp_stdout = "",
        slurp_stderr = c.stderr,
        slurp_rc = c.rc,
      }, function(sb)
        local r = sb:run({ "start", "--region" })
        assert_eq(r.code, 0, "slurp Esc cancel (" .. c.name .. ") must exit 0 (err=" .. r.stderr .. ")")
        assert_true(not sb:systemctl_called_with("start "),
          "slurp Esc cancel (" .. c.name .. ") must not start service")
        assert_true(not file_exists(sb.runtime_kaze .. "/record.env"),
          "slurp Esc cancel must not leave record.env")
        assert_eq(#list_dir_files(sb.videos), 0,
          "slurp Esc cancel must not leave reserved/temp video files")
      end)
    end

    -- 5c. Malformed / multi-output slurp outputs fail cleanly with non-zero exit
    local bad_slurp_outputs = {
      { name = "missing_output_line", out = "100,200 800x600\n" },
      { name = "garbage_geometry", out = "not-a-region\neDP-1\n" },
      { name = "zero_width", out = "100,200 0x600\neDP-1\n" },
      { name = "zero_height", out = "100,200 800x0\neDP-1\n" },
      { name = "multi_output_unknown", out = "100,200 800x600\n<unknown>\n" },
      { name = "multi_output_two_lines", out = "100,200 800x600\neDP-1\nHDMI-A-1\n" },
    }
    for _, c in ipairs(bad_slurp_outputs) do
      with_sandbox(kaze_record_bin, {
        slurp_stdout = c.out,
        slurp_rc = 0,
      }, function(sb)
        local r = sb:run({ "start", "--region" })
        assert_true(r.code ~= 0, "malformed slurp (" .. c.name .. ") must exit non-zero")
        assert_true(not sb:systemctl_called_with("start "),
          "malformed slurp (" .. c.name .. ") must not start service")
        assert_true(not file_exists(sb.runtime_kaze .. "/record.env"),
          "malformed slurp (" .. c.name .. ") must not leave record.env")
      end)
    end
  end)

  -- 6. Missing Tool Dependencies
  test("bb.record.missing_dependencies", function()
    -- Missing wf-recorder
    with_sandbox(kaze_record_bin, { omit_tools = { ["wf-recorder"] = true } }, function(sb)
      local r = sb:run({ "start" })
      assert_true(r.code ~= 0, "missing wf-recorder must fail non-zero")
      assert_true(not sb:systemctl_called_with("start "), "missing wf-recorder must not start service")
      assert_contains(r.out:lower(), "wf-recorder", "missing wf-recorder should mention wf-recorder")
    end)

    -- Missing ffprobe
    with_sandbox(kaze_record_bin, { omit_tools = { ["ffprobe"] = true } }, function(sb)
      local r = sb:run({ "start" })
      assert_true(r.code ~= 0, "missing ffprobe must fail non-zero")
      assert_true(not sb:systemctl_called_with("start "), "missing ffprobe must not start service")
      assert_contains(r.out:lower(), "ffprobe", "missing ffprobe should mention ffprobe")
    end)

    -- Missing slurp (fails on --region, ok without --region)
    with_sandbox(kaze_record_bin, { omit_tools = { ["slurp"] = true } }, function(sb)
      local r_reg = sb:run({ "start", "--region" })
      assert_true(r_reg.code ~= 0, "missing slurp with --region must fail non-zero")
      assert_true(not sb:systemctl_called_with("start "), "missing slurp must not start service")
      assert_contains(r_reg.out:lower(), "slurp", "missing slurp should mention slurp")

      local r_full = sb:run({ "start" })
      assert_eq(r_full.code, 0, "full-screen start should not require slurp (err=" .. r_full.stderr .. ")")
    end)

    -- Missing ffmpeg (fails on --gif, ok for regular mp4)
    with_sandbox(kaze_record_bin, { omit_tools = { ["ffmpeg"] = true } }, function(sb)
      local r_gif = sb:run({ "start", "--gif" })
      assert_true(r_gif.code ~= 0, "missing ffmpeg with --gif must fail non-zero")
      assert_true(not sb:systemctl_called_with("start "), "missing ffmpeg with --gif must not start service")
      assert_contains(r_gif.out:lower(), "ffmpeg", "missing ffmpeg should mention ffmpeg")

      local r_mp4 = sb:run({ "start" })
      assert_eq(r_mp4.code, 0, "regular MP4 start should not require ffmpeg (err=" .. r_mp4.stderr .. ")")
    end)
  end)

  -- 7. Audio Modes Matrix
  test("bb.record.audio_modes_matrix", function()
    -- Off / default
    for _, args in ipairs({
      { "start" },
      { "start", "--audio=off" },
      { "start", "--audio", "off" },
    }) do
      with_sandbox(kaze_record_bin, function(sb)
        local r = sb:run(args)
        local label = table.concat(args, " ")
        assert_eq(r.code, 0, label .. " should exit 0 (err=" .. r.stderr .. ")")
        local env = parse_env_file(sb.runtime_kaze .. "/record.env")
        assert_eq(env.KAZE_RECORD_AUDIO, "", label .. " must set KAZE_RECORD_AUDIO=''")
      end)
    end

    -- Desktop audio via get-default-sink
    for _, args in ipairs({
      { "start", "--audio" },
      { "start", "--audio", "desktop" },
      { "start", "--audio=desktop" },
    }) do
      with_sandbox(kaze_record_bin, {
        default_sink = "alsa_output.pci.stereo\n",
      }, function(sb)
        local r = sb:run(args)
        local label = table.concat(args, " ")
        assert_eq(r.code, 0, label .. " should exit 0 (err=" .. r.stderr .. ")")
        local env = parse_env_file(sb.runtime_kaze .. "/record.env")
        assert_eq(env.KAZE_RECORD_AUDIO, "alsa_output.pci.stereo.monitor",
          label .. " must append .monitor to default sink")
      end)
    end

    -- Desktop audio fallback to pactl list sources short when get-default-sink is @DEFAULT_SINK@, empty, whitespace, or fails
    for _, case in ipairs({
      { name = "@DEFAULT_SINK@", sink = "@DEFAULT_SINK@\n", rc = 0 },
      { name = "empty", sink = "", rc = 0 },
      { name = "whitespace", sink = "   \n", rc = 0 },
      { name = "rc1", sink = "", rc = 1 },
    }) do
      with_sandbox(kaze_record_bin, {
        default_sink = case.sink,
        pactl_sink_rc = case.rc,
        list_sources = "41\talsa_input.mic\tPipeWire\ts16le\tIDLE\n42\talsa_output.fb_sink.monitor\tPipeWire\tfloat32le\tIDLE\n",
      }, function(sb)
        local r = sb:run({ "start", "--audio=desktop" })
        assert_eq(r.code, 0, "desktop fallback (" .. case.name .. ") should succeed (err=" .. r.stderr .. ")")
        local env = parse_env_file(sb.runtime_kaze .. "/record.env")
        assert_eq(env.KAZE_RECORD_AUDIO, "alsa_output.fb_sink.monitor",
          "desktop fallback (" .. case.name .. ") must pick *.monitor from pactl list sources short")
      end)
    end

    -- Desktop audio fails if no monitor source exists
    with_sandbox(kaze_record_bin, {
      default_sink = "",
      list_sources = "41\talsa_input.mic\tPipeWire\ts16le\tIDLE\n",
    }, function(sb)
      local r = sb:run({ "start", "--audio=desktop" })
      assert_true(r.code ~= 0, "desktop audio without any monitor source must fail non-zero")
      assert_true(not sb:systemctl_called_with("start "), "must not start service without monitor source")
    end)

    -- Desktop audio fails if pactl is missing
    with_sandbox(kaze_record_bin, { omit_tools = { ["pactl"] = true } }, function(sb)
      local r = sb:run({ "start", "--audio=desktop" })
      assert_true(r.code ~= 0, "desktop audio without pactl must fail non-zero")
      assert_true(not sb:systemctl_called_with("start "), "must not start service without pactl")
    end)

    -- Mic audio via get-default-source
    for _, args in ipairs({
      { "start", "--audio", "mic" },
      { "start", "--audio=mic" },
    }) do
      with_sandbox(kaze_record_bin, {
        default_source = "alsa_input.usb_mic\n",
      }, function(sb)
        local r = sb:run(args)
        local label = table.concat(args, " ")
        assert_eq(r.code, 0, label .. " should exit 0 (err=" .. r.stderr .. ")")
        local env = parse_env_file(sb.runtime_kaze .. "/record.env")
        assert_eq(env.KAZE_RECORD_AUDIO, "alsa_input.usb_mic", label .. " must use default mic source")
      end)
    end

    -- Mic audio falls back to "default" if get-default-source is empty or fails
    for _, case in ipairs({
      { name = "empty", src = "", rc = 0 },
      { name = "rc1", src = "", rc = 1 },
    }) do
      with_sandbox(kaze_record_bin, { default_source = case.src, pactl_source_rc = case.rc }, function(sb)
        local r = sb:run({ "start", "--audio=mic" })
        assert_eq(r.code, 0, "mic audio (" .. case.name .. ") should fall back to default (err=" .. r.stderr .. ")")
        local env = parse_env_file(sb.runtime_kaze .. "/record.env")
        assert_eq(env.KAZE_RECORD_AUDIO, "default", "mic audio (" .. case.name .. ") fallback must be 'default'")
      end)
    end

    -- Mic audio falls back to "default" if pactl is missing
    with_sandbox(kaze_record_bin, { omit_tools = { ["pactl"] = true } }, function(sb)
      local r = sb:run({ "start", "--audio=mic" })
      assert_eq(r.code, 0, "mic audio without pactl should fall back to default (err=" .. r.stderr .. ")")
      local env = parse_env_file(sb.runtime_kaze .. "/record.env")
      assert_eq(env.KAZE_RECORD_AUDIO, "default", "mic audio missing pactl fallback must be 'default'")
    end)
  end)

  -- 8. GIF Recording & Conversion
  test("bb.record.gif_recording_and_conversion", function()
    with_sandbox(kaze_record_bin, {
      slurp_stdout = "50,60 640x480\neDP-1\n",
    }, function(sb)
      local r_start = sb:run({ "start", "--region", "--gif" })
      assert_eq(r_start.code, 0, "start --region --gif should exit 0 (err=" .. r_start.stderr .. ")")

      local env = parse_env_file(sb.runtime_kaze .. "/record.env")
      assert_true(env ~= nil, "start --gif must write record.env")
      assert_eq(env.KAZE_RECORD_FORMAT, "gif", "KAZE_RECORD_FORMAT must be 'gif'")
      assert_eq(env.KAZE_RECORD_REGION, "50,60 640x480", "KAZE_RECORD_REGION must be recorded for region GIF")
      assert_eq(env.KAZE_RECORD_AUDIO, "", "GIF recording must have empty audio")
      assert_true(env.KAZE_RECORD_FILE and env.KAZE_RECORD_FILE ~= "", "temp MP4 path must be set")
      assert_true(env.KAZE_RECORD_GIF_PATH and env.KAZE_RECORD_GIF_PATH:match("%.gif$") ~= nil,
        "KAZE_RECORD_GIF_PATH must end with .gif, got " .. tostring(env.KAZE_RECORD_GIF_PATH))

      local tmp_mp4 = env.KAZE_RECORD_FILE
      local gif_path = env.KAZE_RECORD_GIF_PATH

      sb:clear_logs()
      local r_stop = sb:run({ "stop" })
      assert_eq(r_stop.code, 0, "stop after --gif should exit 0 (err=" .. r_stop.stderr .. ")")
      assert_true(trim(sb:read_log("ffmpeg.log")) ~= "", "stop --gif must invoke ffmpeg")
      assert_true(file_exists(gif_path) and (file_size(gif_path) or 0) > 0,
        "output GIF must exist and be non-empty: " .. gif_path)
      assert_true(not file_exists(tmp_mp4),
        "temp MP4 must be removed after successful GIF conversion: " .. tmp_mp4)
      assert_eq(trim(r_stop.stdout), gif_path, "stop --gif must print .gif path")
      assert_contains(sb:read_log("notify.log"), "GIF saved",
        "stop --gif must send 'GIF saved' notification")

      local sets = sb:noctalia_sets()
      assert_eq(sets["widget.record.glyph"], "video", "stop --gif must reset glyph=video")
      assert_eq(sets["widget.record.icon_color"], "on_surface_variant",
        "stop --gif must reset icon_color=on_surface_variant")
    end)
  end)

  -- 9. GIF Conversion Failure Safety (preserves source MP4)
  test("bb.record.gif_conversion_failure_preserves_mp4", function()
    for _, mode in ipairs({ "fail", "empty" }) do
      with_sandbox(kaze_record_bin, { ffmpeg_mode = mode }, function(sb)
        local r_start = sb:run({ "start", "--gif" })
        assert_eq(r_start.code, 0, "start --gif (" .. mode .. ") should exit 0")
        local env = parse_env_file(sb.runtime_kaze .. "/record.env")
        local tmp_mp4 = env.KAZE_RECORD_FILE
        assert_true(file_exists(tmp_mp4), "source MP4 must exist before stop (" .. mode .. ")")

        sb:clear_logs()
        local r_stop = sb:run({ "stop" })
        assert_true(r_stop.code ~= 0, "stop --gif with ffmpeg=" .. mode .. " must exit non-zero")
        assert_true(file_exists(tmp_mp4) and (file_size(tmp_mp4) or 0) > 0,
          "source MP4 MUST be preserved when ffmpeg=" .. mode .. ": " .. tmp_mp4)

        local sets = sb:noctalia_sets()
        assert_eq(sets["widget.record.glyph"], "video",
          "indicator must still reset on ffmpeg=" .. mode .. " failure")
      end)
    end
  end)

  -- 10. Live-Pill vs Omarchy-Rail Style Indicator Behavior
  test("bb.record.live_pill_style_indicators", function()
    local live_pill_styles = { "dynamic-island", "hardware-notch", "cinema-frame" }
    for _, style in ipairs(live_pill_styles) do
      -- MP4 flow
      with_sandbox(kaze_record_bin, { style = style }, function(sb)
        local r1 = sb:run({ "start" })
        assert_eq(r1.code, 0, style .. " mp4 start failed: " .. r1.stderr)
        local s1 = sb:noctalia_sets()
        assert_eq(s1["widget.record.enabled"], "true", style .. " mp4 start must enable widget.record")
        assert_eq(s1["widget.record.label"], "REC", style .. " mp4 start must set label='REC'")

        sb:clear_logs()
        local r2 = sb:run({ "stop" })
        assert_eq(r2.code, 0, style .. " mp4 stop failed: " .. r2.stderr)
        local s2 = sb:noctalia_sets()
        assert_eq(s2["widget.record.enabled"], "false", style .. " mp4 stop must disable widget.record")
        assert_eq(s2["widget.record.label"], "", style .. " mp4 stop must clear label")
      end)

      -- GIF flow
      with_sandbox(kaze_record_bin, { style = style }, function(sb)
        local r1 = sb:run({ "start", "--gif" })
        assert_eq(r1.code, 0, style .. " gif start failed: " .. r1.stderr)
        local s1 = sb:noctalia_sets()
        assert_eq(s1["widget.record.enabled"], "true", style .. " gif start must enable widget.record")
        assert_eq(s1["widget.record.label"], "GIF", style .. " gif start must set label='GIF'")

        sb:clear_logs()
        local r2 = sb:run({ "stop" })
        assert_eq(r2.code, 0, style .. " gif stop failed: " .. r2.stderr)
        local s2 = sb:noctalia_sets()
        assert_eq(s2["widget.record.enabled"], "false", style .. " gif stop must disable widget.record")
        assert_eq(s2["widget.record.label"], "", style .. " gif stop must clear label")
      end)
    end

    -- omarchy-rail: recording sets label "", stop does NOT disable widget.record.enabled
    for _, start_args in ipairs({ { "start" }, { "start", "--gif" } }) do
      local tag = table.concat(start_args, " ")
      with_sandbox(kaze_record_bin, { style = "omarchy-rail" }, function(sb)
        local r1 = sb:run(start_args)
        assert_eq(r1.code, 0, "omarchy-rail " .. tag .. " failed: " .. r1.stderr)
        local s1 = sb:noctalia_sets()
        assert_eq(s1["widget.record.label"], "",
          "omarchy-rail " .. tag .. " must set label=''")

        sb:clear_logs()
        local r2 = sb:run({ "stop" })
        assert_eq(r2.code, 0, "omarchy-rail stop (" .. tag .. ") failed: " .. r2.stderr)
        local s2 = sb:noctalia_sets()
        assert_true(s2["widget.record.enabled"] ~= "false",
          "omarchy-rail stop must NOT disable widget.record.enabled")
        assert_eq(s2["widget.record.glyph"], "video", "omarchy-rail stop must reset glyph")
      end)
    end

    -- Non-custom_button widget.record.type skips Noctalia widget mutations gracefully
    with_sandbox(kaze_record_bin, { widget_type = "'other'\n", style = "dynamic-island" }, function(sb)
      local r1 = sb:run({ "start" })
      assert_eq(r1.code, 0, "start with non-custom_button widget must still succeed")
      local _, ordered = sb:noctalia_sets()
      assert_eq(#ordered, 0, "must not call config-set when widget.record.type != 'custom_button'")
    end)
  end)

  -- 11. --menu Idle Workflows & Convert Last MP4 -> GIF
  test("bb.record.menu_idle_and_convert_last_gif", function()
    -- 11a. Idle without record.last -> 8 base items; Esc exits 0 cleanly (rc=1 and rc=0)
    for _, mode in ipairs({ "esc", "esc0" }) do
      with_sandbox(kaze_record_bin, { dmenu_mode = mode }, function(sb)
        local r = sb:run({ "--menu" })
        assert_eq(r.code, 0, "--menu " .. mode .. " when idle must exit 0 (err=" .. r.stderr .. ")")
        assert_true(sb:noctalia_dmenu_called(), "--menu must invoke noctalia dmenu")
        local items = split_nonempty_lines(sb:read_log("dmenu_items.txt"))
        assert_eq(#items, 8, "idle --menu without record.last must present 8 base items, got " .. #items)
        assert_true(not sb:systemctl_called_with("start "), "--menu Esc must not start recording")
      end)
    end

    -- 11b. Idle with empty record.last, missing target file, or missing ffmpeg -> only 8 items
    for _, c in ipairs({
      { name = "empty_record_last", content = "\n", create_mp4 = false, omit_ffmpeg = false },
      { name = "dangling_record_last", content = nil, create_mp4 = false, omit_ffmpeg = false },
      { name = "missing_ffmpeg", content = nil, create_mp4 = true, omit_ffmpeg = true },
    }) do
      with_sandbox(kaze_record_bin, {
        dmenu_mode = "esc",
        omit_tools = c.omit_ffmpeg and { ["ffmpeg"] = true } or {},
      }, function(sb)
        exec_status("/usr/bin/mkdir -p " .. sh_quote(sb.runtime_kaze))
        local last_mp4 = sb.videos .. "/prev-recording.mp4"
        if c.create_mp4 then
          write_file(last_mp4, "MOCK_MP4_BYTES\n")
        end
        write_file(sb.runtime_kaze .. "/record.last", c.content or (last_mp4 .. "\n"))

        local r = sb:run({ "--menu" })
        assert_eq(r.code, 0, "--menu (" .. c.name .. ") must exit 0")
        local items = split_nonempty_lines(sb:read_log("dmenu_items.txt"))
        assert_eq(#items, 8, "--menu (" .. c.name .. ") must only present 8 base items, got " .. #items)
      end)
    end

    -- 11c. Idle with non-empty record.last + ffmpeg -> 9th item 'Convert Last MP4 → GIF' & converts cleanly
    with_sandbox(kaze_record_bin, {
      dmenu_mode = "match",
      dmenu_arg = "Convert Last MP4 → GIF",
    }, function(sb)
      exec_status("/usr/bin/mkdir -p " .. sh_quote(sb.runtime_kaze))
      local last_mp4 = sb.videos .. "/prev-recording.mp4"
      write_file(last_mp4, "MOCK_MP4_BYTES\n")
      write_file(sb.runtime_kaze .. "/record.last", last_mp4 .. "\n")

      local r = sb:run({ "--menu" })
      assert_eq(r.code, 0, "--menu Convert Last MP4 → GIF must exit 0 (err=" .. r.stderr .. ")")
      local items = split_nonempty_lines(sb:read_log("dmenu_items.txt"))
      assert_eq(#items, 9, "idle --menu with record.last + ffmpeg must present 9 items, got " .. #items)
      assert_contains(items[9], "Convert Last MP4 → GIF", "9th menu item must be Convert Last MP4 → GIF")

      local ffmpeg_log = sb:read_log("ffmpeg.log")
      assert_contains(ffmpeg_log, last_mp4, "ffmpeg must be invoked with record.last MP4 path")
      assert_true(not sb:systemctl_called_with("start "), "converting last MP4 must not start recorder service")
      assert_true(file_exists(last_mp4), "converting last MP4 must preserve original MP4")
      assert_contains(sb:read_log("notify.log"), "GIF saved",
        "converting last MP4 to GIF must send 'GIF saved' notification")

      local expected_gif = sb.videos .. "/prev-recording.gif"
      local printed = trim(r.stdout)
      local gif_file = (printed ~= "" and printed:match("%.gif$")) and printed or expected_gif
      assert_true(file_exists(gif_file) and (file_size(gif_file) or 0) > 0,
        "converted GIF must exist and be non-empty: " .. gif_file)
    end)

    -- 11d. Convert Last MP4 -> GIF when ffmpeg fails still preserves original MP4 and exits non-zero
    for _, mode in ipairs({ "fail", "empty" }) do
      with_sandbox(kaze_record_bin, {
        dmenu_mode = "match",
        dmenu_arg = "Convert Last MP4 → GIF",
        ffmpeg_mode = mode,
      }, function(sb)
        exec_status("/usr/bin/mkdir -p " .. sh_quote(sb.runtime_kaze))
        local last_mp4 = sb.videos .. "/keep-me.mp4"
        write_file(last_mp4, "ORIGINAL_MP4_BYTES\n")
        write_file(sb.runtime_kaze .. "/record.last", last_mp4 .. "\n")

        local r = sb:run({ "--menu" })
        assert_true(r.code ~= 0, "Convert Last MP4 → GIF with ffmpeg=" .. mode .. " must exit non-zero")
        assert_eq(read_file(last_mp4), "ORIGINAL_MP4_BYTES\n",
          "Convert Last MP4 → GIF failure (" .. mode .. ") must preserve original MP4")
      end)
    end

    -- 11e. Idle choosing first base item starts recording
    with_sandbox(kaze_record_bin, {
      dmenu_mode = "line",
      dmenu_arg = "1",
    }, function(sb)
      local r = sb:run({ "--menu" })
      assert_eq(r.code, 0, "--menu choosing item 1 must exit 0 (err=" .. r.stderr .. ")")
      assert_true(sb:systemctl_called_with("start kaze-record.service"),
        "--menu choosing base item 1 must start recording")
    end)
  end)

  -- 12. --menu Active & --bar Workflows
  test("bb.record.menu_active_and_bar_workflows", function()
    -- 12a. --menu when active or activating: presents Stop Recording; Esc does not stop
    with_sandbox(kaze_record_bin, function(sb)
      assert_eq(sb:run({ "start" }).code, 0, "pre-start failed")

      for _, busy_state in ipairs({ "active", "activating" }) do
        sb:set_mock("systemctl_state", busy_state)
        sb:clear_logs()
        sb:set_mock("dmenu_mode", "esc")

        local r_esc = sb:run({ "--menu" })
        assert_eq(r_esc.code, 0, "--menu Esc when " .. busy_state .. " must exit 0 (err=" .. r_esc.stderr .. ")")
        assert_true(sb:noctalia_dmenu_called(), "--menu when " .. busy_state .. " must invoke dmenu")
        assert_contains(sb:read_log("dmenu_items.txt"), "Stop Recording",
          "--menu when " .. busy_state .. " must present 'Stop Recording'")
        assert_true(not sb:systemctl_called_with("stop "),
          "--menu Esc when " .. busy_state .. " must not stop recording")
      end

      -- Choosing Stop Recording stops cleanly
      sb:set_mock("systemctl_state", "active")
      sb:clear_logs()
      sb:set_mock("dmenu_mode", "match")
      sb:set_mock("dmenu_arg", "Stop Recording")
      local r_stop = sb:run({ "--menu" })
      assert_eq(r_stop.code, 0, "--menu choosing Stop Recording must exit 0 (err=" .. r_stop.stderr .. ")")
      assert_true(sb:systemctl_called_with("stop kaze-record.service"),
        "--menu choosing Stop Recording must stop service")
    end)

    -- 12b. --bar when active or activating stops immediately WITHOUT opening dmenu
    for _, busy_state in ipairs({ "active", "activating" }) do
      with_sandbox(kaze_record_bin, function(sb)
        local r_s = sb:run({ "start" })
        assert_eq(r_s.code, 0, "pre-start failed")
        local env = parse_env_file(sb.runtime_kaze .. "/record.env")
        sb:set_mock("systemctl_state", busy_state)
        sb:clear_logs()

        local r_bar = sb:run({ "--bar" })
        assert_eq(r_bar.code, 0, "--bar when " .. busy_state .. " must stop cleanly (err=" .. r_bar.stderr .. ")")
        assert_true(not sb:noctalia_dmenu_called(), "--bar when " .. busy_state .. " must NOT open dmenu")
        assert_true(sb:systemctl_called_with("stop kaze-record.service"),
          "--bar when " .. busy_state .. " must stop kaze-record.service")
        assert_eq(trim(r_bar.stdout), env.KAZE_RECORD_FILE, "--bar stop must print saved path")
      end)
    end

    -- 12c. --bar when idle opens --menu (Esc -> no start; line 1 -> starts recording)
    with_sandbox(kaze_record_bin, { dmenu_mode = "esc" }, function(sb)
      local r_bar = sb:run({ "--bar" })
      assert_eq(r_bar.code, 0, "--bar when idle + Esc must exit 0 (err=" .. r_bar.stderr .. ")")
      assert_true(sb:noctalia_dmenu_called(), "--bar when idle must open dmenu (--menu)")
      local items = split_nonempty_lines(sb:read_log("dmenu_items.txt"))
      assert_eq(#items, 8, "--bar when idle must show the 8 idle menu items")
      assert_true(not sb:systemctl_called_with("start "), "--bar Esc must not start service")

      sb:clear_logs()
      sb:set_mock("dmenu_mode", "line")
      sb:set_mock("dmenu_arg", "1")
      local r_pick = sb:run({ "--bar" })
      assert_eq(r_pick.code, 0, "--bar idle selecting item 1 must exit 0 (err=" .. r_pick.stderr .. ")")
      assert_true(sb:systemctl_called_with("start kaze-record.service"),
        "--bar idle selecting item 1 must start service")
    end)
  end)

  -- 13. Inactive Kaze Session Guards
  test("bb.record.session_guards", function()
    local guard_cases = {
      {
        name = "missing_hypr_sig",
        opts = {},
        env = { HYPRLAND_INSTANCE_SIGNATURE = false },
      },
      {
        name = "empty_hypr_sig",
        opts = {},
        env = { HYPRLAND_INSTANCE_SIGNATURE = "" },
      },
      {
        name = "mismatched_systemd_hypr_sig",
        opts = { show_env = "HYPRLAND_INSTANCE_SIGNATURE=other-sig\nWAYLAND_DISPLAY=wayland-1\n" },
        env = {},
      },
      {
        name = "missing_systemd_hypr_sig",
        opts = { show_env = "WAYLAND_DISPLAY=wayland-1\n" },
        env = {},
      },
      {
        name = "inactive_kaze_session_target",
        opts = { session_active = false },
        env = {},
      },
      {
        name = "missing_wayland_display",
        opts = { show_env = "HYPRLAND_INSTANCE_SIGNATURE=test-sig-1\n" },
        env = { WAYLAND_DISPLAY = false },
      },
      {
        name = "empty_wayland_display",
        opts = { show_env = "HYPRLAND_INSTANCE_SIGNATURE=test-sig-1\n" },
        env = { WAYLAND_DISPLAY = "" },
      },
    }

    local failures = {}
    for _, c in ipairs(guard_cases) do
      for _, verb in ipairs({ "start", "toggle" }) do
        with_sandbox(kaze_record_bin, c.opts, function(sb)
          local r = sb:run({ verb }, c.env)
          if r.code == 0 or sb:systemctl_called_with("start ") or file_exists(sb.runtime_kaze .. "/record.env") then
            failures[#failures + 1] = string.format(
              "%s/%s (code=%d, started=%s, env_created=%s)",
              c.name,
              verb,
              r.code,
              tostring(sb:systemctl_called_with("start ")),
              tostring(file_exists(sb.runtime_kaze .. "/record.env"))
            )
          end
        end)
      end
    end
    assert_eq(#failures, 0, "session guard failures: " .. table.concat(failures, "; "))
  end)

  -- 14. Start Failure Rollback & Concurrency Lock (flock)
  test("bb.record.start_failure_rollback_and_flock", function()
    -- 14a. Start failure (systemctl start exits 1) cleans up record.env, empty reserved file, resets indicator
    with_sandbox(kaze_record_bin, {
      start_rc = 1,
      style = "dynamic-island",
    }, function(sb)
      local r = sb:run({ "start" })
      assert_true(r.code ~= 0, "start failure must exit non-zero")
      assert_true(not file_exists(sb.runtime_kaze .. "/record.env"),
        "start failure must clean up record.env")
      assert_eq(#list_dir_files(sb.videos), 0,
        "start failure must clean up empty reserved file in Videos dir")
      local sets = sb:noctalia_sets()
      assert_eq(sets["widget.record.glyph"], "video",
        "start failure must reset bar indicator glyph=video")
      assert_eq(sets["widget.record.icon_color"], "on_surface_variant",
        "start failure must reset bar indicator icon_color=on_surface_variant")
      assert_eq(sets["widget.record.enabled"], "false",
        "start failure on live-pill style must disable widget.record")
    end)

    -- 14b. Overlapping call while record.lock is held via flock exits 0 silently without starting duplicate
    with_sandbox(kaze_record_bin, function(sb)
      exec_status("/usr/bin/mkdir -p " .. sh_quote(sb.runtime_kaze))
      local lock_path = sb.runtime_kaze .. "/record.lock"
      local ready_path = sb.mock .. "/lock.ready"
      local pid_path = sb.mock .. "/lock.pid"

      local holder_cmd = "/usr/bin/flock -x " .. sh_quote(lock_path) ..
        " /usr/bin/sh -c 'echo $$ > " .. sh_quote(pid_path) ..
        "; touch " .. sh_quote(ready_path) .. "; sleep 4' >/dev/null 2>&1 & echo $!"
      local bg_pid = trim(popen_read(holder_cmd))
      if bg_pid ~= "" then
        sb.bg_pids[#sb.bg_pids + 1] = bg_pid
      end

      local acquired = false
      for _ = 1, 40 do
        if file_exists(ready_path) then
          acquired = true
          break
        end
        exec_status("/usr/bin/sleep 0.05")
      end
      assert_true(acquired, "test harness failed to acquire record.lock")

      local inner_pid = trim(read_file(pid_path) or "")
      if inner_pid ~= "" then
        sb.bg_pids[#sb.bg_pids + 1] = inner_pid
      end

      for _, verb in ipairs({ "start", "toggle" }) do
        sb:clear_logs()
        local r = sb:run({ verb })
        assert_eq(r.code, 0, "overlapping '" .. verb .. "' under flock must exit 0 (err=" .. r.stderr .. ")")
        assert_eq(r.stdout, "", "overlapping '" .. verb .. "' under flock must be silent on stdout")
        assert_eq(r.stderr, "", "overlapping '" .. verb .. "' under flock must be silent on stderr")
        assert_true(not sb:systemctl_called_with("start "),
          "overlapping '" .. verb .. "' under flock must not start duplicate recording")
        assert_true(not file_exists(sb.runtime_kaze .. "/record.env"),
          "overlapping '" .. verb .. "' under flock must not write record.env")
      end

      -- Release lock and verify normal start works afterwards
      for _, p in ipairs(sb.bg_pids) do
        exec_status("kill " .. tostring(p) .. " 2>/dev/null || true")
      end
      sb.bg_pids = {}
      for _ = 1, 20 do
        if exec_status("/usr/bin/flock -n " .. sh_quote(lock_path) .. " /usr/bin/true") == 0 then
          break
        end
        exec_status("/usr/bin/sleep 0.05")
      end

      sb:clear_logs()
      local r_after = sb:run({ "start" })
      assert_eq(r_after.code, 0, "start after lock release must succeed (err=" .. r_after.stderr .. ")")
      assert_true(sb:systemctl_called_with("start kaze-record.service"),
        "start after lock release must start service")
    end)
  end)
end

return run_suite
