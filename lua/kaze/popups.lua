local fs = require("kaze.fs")

local M = {}

local dmenu_seq = 0

function M.exec_detached(action_cmd)
    local cgroup = fs.read_file("/proc/self/cgroup")
    local in_bar = cgroup ~= nil and cgroup:find("kaze%-noctalia%.service") ~= nil
    local run_cmd = action_cmd
    if in_bar and fs.command_exists("systemd-run") then
        run_cmd = "systemd-run --user --scope --quiet -- /bin/sh -c " .. fs.shell_quote(action_cmd)
    else
        run_cmd = "nohup /bin/sh -c " .. fs.shell_quote(action_cmd) .. " >/dev/null 2>&1 &"
    end
    local ok = os.execute(run_cmd)
    return ok == true or ok == 0
end

-- Launches `noctalia dmenu` via a private temp file so stdin payload is never
-- mangled by shell quoting.
function M.run_dmenu(entries, opts)
    opts = opts or {}
    if not fs.command_exists("noctalia") then
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

    local argv = { "noctalia", "dmenu" }
    if opts.prompt and opts.prompt ~= "" then
        argv[#argv + 1] = "-p"
        argv[#argv + 1] = fs.shell_quote(opts.prompt)
    end

    local utf8_guard = "case \"${LC_ALL:-${LC_CTYPE:-${LANG:-C}}}\" in *.UTF-8*|*.utf8*) ;; *) export LC_CTYPE=C.UTF-8 ;; esac; "
    local cmd = utf8_guard .. table.concat(argv, " ") .. " < " .. fs.shell_quote(tmp_path)
    local proc = io.popen(cmd, "r")
    if not proc then
        os.remove(tmp_path)
        return nil, "failed to launch noctalia dmenu"
    end
    local out = proc:read("*a") or ""
    proc:close()
    os.remove(tmp_path)
    return (out:gsub("[\r\n]+$", ""))
end

return M
