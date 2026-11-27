local fs = require("kaze.fs")

local M = {}

local dmenu_seq = 0

function M.exec_detached(action_cmd)
    local cgroup = fs.read_file("/proc/self/cgroup")
    local in_bar = cgroup ~= nil
        and (cgroup:find("kaze%-shell%.service") ~= nil or cgroup:find("kaze%-noctalia%.service") ~= nil)
    local run_cmd = action_cmd
    if in_bar and fs.command_exists("systemd-run") then
        run_cmd = "systemd-run --user --scope --quiet -- /bin/sh -c " .. fs.shell_quote(action_cmd)
    else
        run_cmd = "nohup /bin/sh -c " .. fs.shell_quote(action_cmd) .. " >/dev/null 2>&1 &"
    end
    local ok = os.execute(run_cmd)
    return ok == true or ok == 0
end

local function select_dmenu_backend()
    if fs.command_exists("kaze-shell") then
        local live = os.execute("kaze-shell msg ping >/dev/null 2>&1")
        if (live == true or live == 0) or not fs.command_exists("noctalia") then
            return "kaze-shell"
        end
    end
    if fs.command_exists("noctalia") then
        return "noctalia"
    end
    return nil
end

-- Launches `kaze-shell dmenu` (falling back to `noctalia dmenu` when `kaze-shell` is not running)
-- via a private temp file so stdin payload is never mangled by shell quoting.
function M.run_dmenu(entries, opts)
    opts = opts or {}
    local backend = select_dmenu_backend()
    if not backend then
        return nil, "noctalia not found in PATH"
    end

    local lines = {}
    for _, entry in ipairs(entries or {}) do
        if type(entry) == "table" then
            lines[#lines + 1] = tostring(entry.text or ""):gsub("[%z\r\n]+", " ")
        else
            lines[#lines + 1] = tostring(entry):gsub("[%z\r\n]+", " ")
        end
    end

    local payload = (#lines > 0) and (table.concat(lines, "\n") .. "\n") or ""
    local tmp_path
    local rt_dir = fs.private_runtime_dir()
    if rt_dir then
        dmenu_seq = dmenu_seq + 1
        tmp_path = string.format(
            "%s/dmenu-%d-%d-%d.in",
            rt_dir,
            os.time(),
            dmenu_seq,
            math.floor((os.clock() * 1000000) % 1000000)
        )
    else
        tmp_path = os.tmpname()
    end

    local fh, open_err = io.open(tmp_path, "wb")
    if not fh then
        return nil, "failed to create dmenu input file: " .. tostring(open_err)
    end
    local w_ok, w_err = fh:write(payload)
    if w_ok then
        w_ok, w_err = fh:flush()
    end
    local c_ok, c_err = fh:close()
    if not w_ok or not c_ok then
        os.remove(tmp_path)
        return nil, "failed to write dmenu input file: " .. tostring(w_err or c_err)
    end

    local argv = { backend, "dmenu" }
    if opts.prompt and opts.prompt ~= "" then
        argv[#argv + 1] = "-p"
        argv[#argv + 1] = fs.shell_quote(opts.prompt)
    end

    local dmenu_cmd = table.concat(argv, " ")
    local timeout_sec = tonumber(opts.timeout)
    local flag_path = nil
    local utf8_guard = "case \"${LC_ALL:-${LC_CTYPE:-${LANG:-C}}}\" in *.UTF-8*|*.utf8*) ;; *) export LC_CTYPE=C.UTF-8 ;; esac; "
    local soft_close = (backend == "kaze-shell")
        and "kaze-shell msg launcher-close >/dev/null 2>&1 || true"
        or "noctalia msg panel-close launcher >/dev/null 2>&1 || true"
    local retry_close = (backend == "kaze-shell")
        and "kaze-shell msg launcher-close >/dev/null 2>&1 || true"
        or "noctalia msg panel-open launcher >/dev/null 2>&1 || true; noctalia msg panel-close launcher >/dev/null 2>&1 || true"
    local cmd
    if timeout_sec and timeout_sec > 0 then
        local dur = (timeout_sec == math.floor(timeout_sec))
            and tostring(math.floor(timeout_sec))
            or string.format("%.2f", timeout_sec)
        flag_path = tmp_path .. ".timeout"
        os.remove(flag_path)
        cmd = utf8_guard
            .. string.format(
                "%s < %s & dm_pid=$!; "
                    .. "( sleep %s & spid=$!; trap 'kill \"$spid\" 2>/dev/null || true; exit 0' TERM INT; "
                    .. "wait \"$spid\" 2>/dev/null || exit 0; "
                    .. "if kill -0 \"$dm_pid\" 2>/dev/null; then "
                    .. ": > %s; %s; "
                    .. "sleep 0.3; "
                    .. "if kill -0 \"$dm_pid\" 2>/dev/null; then "
                    .. "%s; "
                    .. "sleep 0.2; kill -TERM \"$dm_pid\" 2>/dev/null || true; "
                    .. "sleep 0.3; kill -KILL \"$dm_pid\" 2>/dev/null || true; "
                    .. "fi; "
                    .. "fi ) </dev/null >/dev/null 2>&1 & wd_pid=$!; "
                    .. "wait \"$dm_pid\"; rc=$?; "
                    .. "kill \"$wd_pid\" 2>/dev/null || true; wait \"$wd_pid\" 2>/dev/null || true; "
                    .. "exit \"$rc\"",
                dmenu_cmd,
                fs.shell_quote(tmp_path),
                dur,
                fs.shell_quote(flag_path),
                soft_close,
                retry_close
            )
    else
        cmd = utf8_guard .. dmenu_cmd .. " < " .. fs.shell_quote(tmp_path)
    end

    local proc = io.popen(cmd, "r")
    if not proc then
        os.remove(tmp_path)
        if flag_path then os.remove(flag_path) end
        return nil, "failed to launch " .. backend .. " dmenu"
    end
    local out = proc:read("*a") or ""
    local ok, why, code = proc:close()
    local rc = fs.exit_status(ok, why, code)
    os.remove(tmp_path)
    local timed_out = false
    if flag_path then
        timed_out = fs.file_exists(flag_path)
        os.remove(flag_path)
    end
    if timed_out then
        return "", nil, true
    end
    local trimmed = (out:gsub("[\r\n]+$", ""))
    if rc ~= 0 and not (rc == 1 and trimmed == "") then
        return nil, string.format("%s dmenu failed (exit %d)", backend, rc), false
    end
    return trimmed, nil, false
end

return M
