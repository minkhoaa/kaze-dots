local fs = require("kaze.fs")
local session = require("kaze.session")
local state = require("kaze.state")

local M = {}
local q = fs.shell_quote
local services = "kaze-waybar.service fnott.service"

local function run(cmd, err)
    if not os.execute(cmd) then error(err or ("command failed: " .. cmd), 0) end
end

local function reload_compositor()
    local response = fs.capture("timeout 3s hyprctl reload")
    if not (response and response:match("^%s*ok%s*$")) then
        error("hyprctl reload was not accepted", 0)
    end
    local errors = fs.capture("timeout 3s hyprctl configerrors")
    if not errors or errors:find("%S") then
        error("Hyprland configuration check failed: " .. (errors or "no response"), 0)
    end
end

local function main_pid(unit)
    local pid = fs.capture("timeout 2s systemctl --user show -p MainPID --value " .. unit)
    return pid and pid:match("^([1-9]%d*)\n$")
end

local function reload_services(restart_wallpaper)
    local waybar_unit, wall_unit = "kaze-waybar.service", "kaze-wallpaper.service"
    local units = restart_wallpaper and (services .. " " .. wall_unit) or services
    -- Intentional switches shouldn't consume the automatic crash-restart quota.
    run("systemctl --user reset-failed " .. units)
    run("systemctl --user restart " .. units)
    local bar_pid = main_pid(waybar_unit)
    local wall_pid = restart_wallpaper and main_pid(wall_unit)
    if not bar_pid or (restart_wallpaper and not wall_pid) then error("a restarted layer service has no main process", 0) end
    local function running(unit, pid)
        return os.execute("timeout 2s systemctl --user is-active --quiet " .. unit) and (not pid or main_pid(unit) == pid)
    end
    local function services_running()
        return running(waybar_unit, bar_pid) and running("fnott.service") and (not wall_pid or running(wall_unit, wall_pid))
    end
    local function mapped(layers, namespace, pid)
        return layers:find("namespace: " .. namespace .. ", pid: " .. pid .. "%f[%D]")
    end
    local dark_polls = 0
    for _ = 1, 30 do
        -- 'monitors' (without 'all') contains only enabled outputs.
        local monitors = fs.capture("timeout 1s hyprctl -j monitors")
        if not monitors then error("cannot query Hyprland outputs after restart", 0) end
        if monitors:find('"dpmsStatus"%s*:%s*true') then
            dark_polls = 0
            local layers = fs.capture("timeout 1s hyprctl layers")
            if not layers then error("cannot query Hyprland layers after restart", 0) end
            if mapped(layers, "waybar", bar_pid) and (not wall_pid or mapped(layers, "wallpaper", wall_pid)) and services_running() then
                return
            end
        elseif monitors:match("^%s*%[%s*%]%s*$") or monitors:find('"dpmsStatus"%s*:%s*false') then
            -- No powered output: don't expect a layer, but verify that the same
            -- new processes survive a brief startup window without crashing.
            if not services_running() then error("a restarted service exited with no powered output", 0) end
            dark_polls = dark_polls + 1
            if dark_polls >= 5 then return end
        else
            error("unexpected Hyprland monitor response after restart", 0)
        end
        os.execute("sleep 0.05")
    end
    error("a restarted layer did not map or its service is not running", 0)
end

local function restore_file(src, dst)
    local tmp = assert(fs.capture("mktemp -- " .. q(dst .. ".rollback.XXXXXXXX"))):gsub("\n$", "")
    local ok = os.execute("cp -aT --remove-destination -- " .. q(src) .. " " .. q(tmp) .. " && mv -fT -- " .. q(tmp) .. " " .. q(dst))
    if not ok then os.remove(tmp) end
    assert(ok, "could not restore " .. dst)
end

function M.apply(outputs, opts)
    local stage = assert(fs.capture("mktemp -d -- " .. q(opts.work_dir .. "/sync.XXXXXXXX")), "cannot make staging directory")
        :gsub("\n$", "")
    local touched = 0
    local backups = {}
    local reloaded, attempted_cursor, attempted_services = false, false, false
    local before, after = opts.appearance and opts.appearance.before, opts.appearance and opts.appearance.after
    local restart_wallpaper = before and (before.has_image ~= after.has_image or before.wallpaper ~= after.wallpaper)
    local change_cursor = before and (before.cursor_theme ~= after.cursor_theme or before.cursor_size ~= after.cursor_size)
    local pending = opts.pending
    local ok, err = pcall(function()
        if pending then
            -- Discard a candidate abandoned by an interrupted switch in the same instance.
            run("rm -f -- " .. q(pending))
        end
        for i, item in ipairs(outputs) do
            local path, content, validator = table.unpack(item)
            local staged = stage .. "/" .. i
            fs.write_atomic(staged, content)
            if validator and opts.live then
                run(validator .. " " .. q(staged), "validation failed for " .. path)
            end
            if os.execute("[ -e " .. q(path) .. " ] || [ -L " .. q(path) .. " ]") then
                run("[ -f " .. q(path) .. " ] || [ -L " .. q(path) .. " ]", "not a config file: " .. path)
                local backup = staged .. ".before"
                run("cp -aT -- " .. q(path) .. " " .. q(backup), "cannot snapshot " .. path)
                backups[i] = backup
            end
        end
        for i, item in ipairs(outputs) do
            fs.write_atomic(item[1], item[2])
            touched = i
        end
        if opts.live then
            if opts.candidate then state.save(opts.candidate, pending) end
            reloaded = true
            reload_compositor()
            if change_cursor then
                attempted_cursor = true
                session.set_cursor(after)
            end
            attempted_services = true
            reload_services(restart_wallpaper)
        end
        if opts.candidate then state.save(opts.candidate) end
    end)
    if pending then os.remove(pending) end
    local cleanup = true
    if not ok then
        local function restore(action)
            local restored, why = pcall(action)
            if not restored then
                cleanup = false
                io.stderr:write("kaze-sync: rollback: " .. tostring(why) .. "\n")
            end
        end
        for i = touched, 1, -1 do
            restore(function()
                if backups[i] then
                    restore_file(backups[i], outputs[i][1])
                else
                    run("rm -f -- " .. q(outputs[i][1]))
                end
            end)
        end
        if reloaded then restore(reload_compositor) end
        if attempted_cursor then restore(function() session.set_cursor(before) end) end
        if attempted_services then restore(function() reload_services(restart_wallpaper) end) end
    end
    if cleanup then
        os.execute("rm -rf -- " .. q(stage))
    else
        io.stderr:write("kaze-sync: kept rollback snapshot at " .. stage .. "\n")
    end
    return ok, err
end

return M
