local color = require("kaze.color")
local fs = require("kaze.fs")
local session = require("kaze.session")
local state = require("kaze.state")

local M = {}
local q = fs.shell_quote
local services = "kaze-waybar.service fnott.service"

local function run(cmd, err)
    if not os.execute(cmd) then error(err or ("command failed: " .. cmd), 0) end
end

local function has_image_magic(head)
    if head:sub(1, 8) == "\137PNG\r\n\26\n" then
        return true
    end
    if #head >= 4 and head:sub(1, 3) == "\255\216\255" then
        return true
    end
    if #head >= 12 and head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WEBP" then
        return true
    end
    local gif = head:sub(1, 6)
    if gif == "GIF87a" or gif == "GIF89a" then
        return true
    end
    if #head >= 14 and head:sub(1, 2) == "BM" then
        return true
    end
    local text = head
    if text:sub(1, 3) == "\239\187\191" then
        text = text:sub(4)
    end
    local trimmed = text:match("^%s*(.*)$") or ""
    if (trimmed:sub(1, 5) == "<?xml"
        or trimmed:sub(1, 9):upper() == "<!DOCTYPE"
        or trimmed:sub(1, 4) == "<!--"
        or trimmed:sub(1, 4):lower() == "<svg")
        and trimmed:lower():find("<svg[%s>]") ~= nil then
        return true
    end
    return false
end

function M.validate_wallpaper(path)
    if type(path) ~= "string" or path == "" then
        return nil, "wallpaper path must be a non-empty string"
    end
    if not os.execute("[ -f " .. q(path) .. " ] && [ -r " .. q(path) .. " ]") then
        return nil, "wallpaper file not found or not readable: " .. path
    end
    local f, open_err = io.open(path, "rb")
    if not f then
        return nil, "cannot open wallpaper file " .. path .. ": " .. tostring(open_err)
    end
    local head = f:read(4096)
    f:close()
    if not head or #head == 0 then
        return nil, "wallpaper file is empty: " .. path
    end
    if not has_image_magic(head) then
        return nil, "corrupt or unsupported wallpaper image: " .. path
    end
    return true
end

function M.extract_matugen_palette(wallpaper_path)
    local ok_wall, wall_err = M.validate_wallpaper(wallpaper_path)
    if not ok_wall then
        return nil, wall_err
    end
    if not fs.command_exists("matugen") then
        return nil, "matugen not found in PATH"
    end
    local attempts = {
        "matugen image " .. q(wallpaper_path) .. " --dry-run --json hex --source-color-index 0 </dev/null 2>/dev/null",
        "matugen image " .. q(wallpaper_path) .. " --dry-run -j hex </dev/null 2>/dev/null",
        "matugen image " .. q(wallpaper_path) .. " -j hex </dev/null 2>/dev/null",
        "matugen image " .. q(wallpaper_path) .. " --json hex </dev/null 2>/dev/null",
    }
    local raw
    for _, cmd in ipairs(attempts) do
        raw = fs.capture(cmd)
        if raw and raw:find("%S") then
            break
        end
    end
    if not raw or not raw:find("%S") then
        return nil, "matugen failed to extract colors from " .. wallpaper_path
    end
    local ok_pal, palette = pcall(color.build_dynamic_palette, raw)
    if not ok_pal then
        return nil, "failed to parse matugen palette: " .. tostring(palette)
    end
    return palette
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

local function spawn_zero_flash_candidate(wallpaper_path, stage)
    local monitors = fs.capture("timeout 1s hyprctl -j monitors")
    if not monitors then
        error("cannot query Hyprland outputs before wallpaper switch", 0)
    end
    local powered = 0
    for _ in monitors:gmatch('"dpmsStatus"%s*:%s*true') do
        powered = powered + 1
    end
    if powered == 0 then
        return nil
    end
    if not fs.command_exists("swaybg") then
        error("swaybg not found in PATH", 0)
    end
    local pid_file = stage .. "/candidate-swaybg.pid"
    run(
        "sh -c 'swaybg -i \"$1\" -m fill </dev/null >/dev/null 2>&1 & printf \"%s\\n\" \"$!\" > \"$2\"' -- "
            .. q(wallpaper_path) .. " " .. q(pid_file),
        "could not spawn candidate swaybg"
    )
    local raw_pid = fs.read_file(pid_file)
    local cand_pid = raw_pid and raw_pid:match("^([1-9]%d*)")
    if not cand_pid then
        error("candidate swaybg did not report a valid PID", 0)
    end
    local pattern = "namespace: wallpaper, pid: " .. cand_pid .. "%f[%D]"
    for _ = 1, 60 do
        if not os.execute("kill -0 " .. cand_pid .. " >/dev/null 2>&1") then
            error("candidate swaybg exited before mapping wallpaper", 0)
        end
        local layers = fs.capture("timeout 1s hyprctl layers")
        if layers then
            local count = 0
            for _ in layers:gmatch(pattern) do
                count = count + 1
            end
            if count >= powered then
                return cand_pid
            end
        end
        os.execute("sleep 0.05")
    end
    os.execute("kill " .. cand_pid .. " >/dev/null 2>&1 || true")
    error("candidate swaybg did not map wallpaper surface within 3s", 0)
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
    local reloaded, attempted_cursor, attempted_services, attempted_optional = false, false, false, false
    local changed_color_scheme = nil
    local cand_pid = nil
    local before, after = opts.appearance and opts.appearance.before, opts.appearance and opts.appearance.after
    local restart_wallpaper = before and (before.has_image ~= after.has_image or before.wallpaper ~= after.wallpaper)
    local change_cursor = before and (before.cursor_theme ~= after.cursor_theme or before.cursor_size ~= after.cursor_size)
    local change_optional = before and (before.enable_polkit ~= after.enable_polkit or before.enable_fcitx5 ~= after.enable_fcitx5)
    local pending = opts.pending
    local candidate = opts.candidate

    local function sync_optional_services(target_state)
        for _, item in ipairs({
            { key = "enable_polkit", unit = "kaze-polkit.service" },
            { key = "enable_fcitx5", unit = "kaze-fcitx5.service" },
        }) do
            if before[item.key] ~= target_state[item.key] then
                if target_state[item.key] then
                    os.execute("systemctl --user reset-failed " .. item.unit .. " >/dev/null 2>&1 || true")
                    run("systemctl --user start " .. item.unit)
                else
                    run("systemctl --user stop " .. item.unit)
                end
            end
        end
    end

    local ok, err = pcall(function()
        if pending then
            -- Discard a candidate abandoned by an interrupted switch in the same instance.
            run("rm -f -- " .. q(pending))
        end

        if opts.live and opts.zero_flash_wallpaper and restart_wallpaper then
            cand_pid = spawn_zero_flash_candidate(opts.zero_flash_wallpaper, stage)
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
            if candidate then state.save(candidate, pending) end
            reloaded = true
            reload_compositor()
            if change_cursor then
                attempted_cursor = true
                session.set_cursor(after)
            end
            attempted_services = true
            reload_services(restart_wallpaper)
            if change_optional then
                attempted_optional = true
                sync_optional_services(after)
            end
            if cand_pid then
                os.execute("kill " .. cand_pid .. " >/dev/null 2>&1 || true")
                cand_pid = nil
            end
            os.remove(opts.work_dir .. "/perf.state")
        end

        if opts.sync_prefer_dark and os.getenv("GSETTINGS_BACKEND") ~= "memory"
            and fs.command_exists("gsettings") and fs.command_exists("dconf") then
            local target_scheme = opts.is_light_theme and "'prefer-light'" or "'prefer-dark'"
            local cur_scheme = fs.capture("gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null")
            if cur_scheme then
                cur_scheme = cur_scheme:gsub("[\r\n]+$", "")
                if cur_scheme ~= "" then
                    local persisted = state.load()
                    if not (candidate and candidate.prev_color_scheme) and not persisted.prev_color_scheme then
                        candidate = candidate or persisted
                        candidate.prev_color_scheme = cur_scheme
                    end
                    if os.execute("gsettings set org.gnome.desktop.interface color-scheme " .. target_scheme .. " >/dev/null 2>&1") then
                        changed_color_scheme = cur_scheme
                    end
                end
            end
        end

        if candidate then state.save(candidate) end
    end)

    if cand_pid then
        os.execute("kill " .. cand_pid .. " >/dev/null 2>&1 || true")
    end
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
        if changed_color_scheme then
            restore(function()
                os.execute("gsettings set org.gnome.desktop.interface color-scheme "
                    .. q(changed_color_scheme) .. " >/dev/null 2>&1")
            end)
        end
        if reloaded then restore(reload_compositor) end
        if attempted_cursor then restore(function() session.set_cursor(before) end) end
        if attempted_services then restore(function() reload_services(restart_wallpaper) end) end
        if attempted_optional then restore(function() sync_optional_services(before) end) end
    end
    if cleanup then
        os.execute("rm -rf -- " .. q(stage))
    else
        io.stderr:write("kaze-sync: kept rollback snapshot at " .. stage .. "\n")
    end
    return ok, err
end

return M
