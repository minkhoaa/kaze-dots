local fs = require("kaze.fs")
local M = {}
local ctl = "systemctl --user "

function M.properties(unit, ...)
    local args = {}
    for _, property in ipairs({...}) do args[#args + 1] = " -p " .. property end
    local out = fs.capture(ctl .. "show" .. table.concat(args) .. " " .. unit)
    if not out then return nil end
    local state = {}
    for key, value in out:gmatch("([%w]+)=([^\n]*)\n") do state[key] = value end
    return state
end

function M.active(state)
    return state == "active" or state == "activating" or state == "reloading"
end

function M.change(unit, action)
    return os.execute(ctl .. action .. " " .. unit)
end

function M.fail(name, msg)
    io.stderr:write(name .. ": " .. msg .. "\n")
    os.exit(1)
end

function M.toggle(name, unit, dependency, args)
    local action = args[1] or "toggle"
    local help = #args == 1 and (action == "--help" or action == "-h")
    if help or #args > 1 or not ({ on = true, off = true, toggle = true, status = true })[action] then
        (help and io.stdout or io.stderr):write("Usage: " .. name .. " [on|off|toggle|status]\n")
        os.exit(help and 0 or 2)
    end
    local state = M.properties(unit, "ActiveState")
    if not state or not state.ActiveState then M.fail(name, "cannot query " .. unit) end
    local active = M.active(state.ActiveState)
    if action == "status" then
        print(active and "on" or "off")
        return
    end
    if action == "toggle" then action = active and "off" or "on" end
    if action == "on" and not fs.command_exists(dependency) then M.fail(name, dependency .. " not found in PATH") end
    if not M.change(unit, action == "on" and "start" or "stop") then
        M.fail(name, "could not turn " .. action .. " (requires a Kaze session; see journalctl --user -u " .. unit .. ")")
    end
end

return M
