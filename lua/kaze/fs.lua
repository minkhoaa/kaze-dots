local M = {}

local seeded = false
local seq = 0

local function ensure_seed()
    if not seeded then
        math.randomseed(os.time() + math.floor(os.clock() * 1000000))
        seeded = true
    end
end

function M.shell_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

function M.home()
    local h = os.getenv("HOME")
    assert(h and h ~= "", "HOME environment variable is not set")
    return h
end

function M.config_dir(home)
    local xdg = os.getenv("XDG_CONFIG_HOME")
    if xdg and xdg ~= "" then
        return xdg
    end
    return (home or M.home()) .. "/.config"
end

function M.data_dir(home)
    local xdg = os.getenv("XDG_DATA_HOME")
    if xdg and xdg ~= "" then
        return xdg
    end
    return (home or M.home()) .. "/.local/share"
end

function M.cache_dir(home)
    local xdg = os.getenv("XDG_CACHE_HOME")
    if xdg and xdg ~= "" then
        return xdg
    end
    return (home or M.home()) .. "/.cache"
end

function M.runtime_dir()
    local runtime = os.getenv("XDG_RUNTIME_DIR")
    if runtime and runtime:sub(1, 1) == "/" then
        return runtime .. "/kaze"
    end
end

function M.private_runtime_dir()
    local dir = M.runtime_dir()
    if not dir then
        return nil
    end
    local q = M.shell_quote(dir)
    if os.execute("[ ! -L " .. q .. " ] && install -d -m 700 -- " .. q) then
        return dir
    end
end

-- Normalize Lua's os.execute/pclose tuple to a CLI status.
function M.exit_status(ok, why, code)
    if ok then return 0 end
    if why == "signal" and code then return 128 + code end
    return code and code ~= 0 and code or 1
end

-- systemd EnvironmentFile double quotes, not shell syntax.
function M.env_entry(key, value)
    assert(type(value) == "string" and not value:find("[%z\r\n]"), "invalid EnvironmentFile value for " .. key)
    return key .. '="' .. value:gsub('["\\]', '\\%0') .. '"\n'
end

function M.read_env_entry(contents, key)
    local value = ("\n" .. contents):match("\n" .. key .. '="([^\n]*)"\n')
    return value and value:gsub('\\(["\\])', '%1')
end

function M.command_exists(bin)
    return os.execute("command -v " .. M.shell_quote(bin) .. " >/dev/null 2>&1")
end

function M.utf8_locale()
    local function value(key)
        local setting = os.getenv(key)
        if setting and setting ~= "" then return setting end
    end
    local lang, all, ctype = value("LANG"), value("LC_ALL"), value("LC_CTYPE")
    local effective = all or ctype or lang or "C"
    if effective:lower():find("utf%-?8") then return lang or "", all or "", ctype or effective end
    -- An explicit non-UTF-8 LC_ALL would override the CTYPE fallback.
    return lang or "", "", "C.UTF-8"
end

function M.capture(cmd)
    local proc = io.popen(cmd, "r")
    if not proc then return nil end
    local out = proc:read("*a")
    if proc:close() then return out end
end

function M.expand_home(path, home)
    if type(path) ~= "string" then
        return path
    end
    local h = home or M.home()
    if path == "~" then
        return h
    end
    if path:sub(1, 2) == "~/" then
        return h .. path:sub(2)
    end
    return path
end

function M.dirname(path)
    return path:match("^(.*)/[^/]+$") or "."
end

function M.file_exists(path)
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

function M.read_file(path)
    local f, err = io.open(path, "rb")
    if not f then
        return nil, err
    end
    local data = f:read("*a")
    f:close()
    return data
end

function M.mkdir_p(dir)
    if not dir or dir == "" or dir == "." then
        return true
    end
    local ok, why, code = os.execute("mkdir -p " .. M.shell_quote(dir))
    if not ok then
        error(string.format("mkdir -p %s failed (%s: %s)", dir, tostring(why), tostring(code)))
    end
    return true
end

function M.write_atomic(path, content)
    assert(type(path) == "string" and path ~= "", "write_atomic: invalid path")
    assert(type(content) == "string", "write_atomic: content must be a string")

    local dir = M.dirname(path)
    M.mkdir_p(dir)

    ensure_seed()
    seq = seq + 1
    local tmp = string.format("%s.tmp.%d.%d.%d", path, os.time(), seq, math.random(100000, 999999))

    local f, open_err = io.open(tmp, "wb")
    if not f then
        error(string.format("write_atomic: cannot open temp file %s: %s", tmp, tostring(open_err)))
    end

    local ok, write_err = f:write(content)
    if ok then
        ok, write_err = f:flush()
    end
    local close_ok, close_err = f:close()
    if not ok or not close_ok then
        os.remove(tmp)
        error(string.format("write_atomic: write failed for %s: %s", path, tostring(write_err or close_err)))
    end

    local ren_ok, ren_err = os.rename(tmp, path)
    if not ren_ok then
        os.remove(tmp)
        error(string.format("write_atomic: rename failed for %s: %s", path, tostring(ren_err)))
    end
    return true
end

return M
