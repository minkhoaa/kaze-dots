local fs = require("kaze.fs")

local M = {}
local target = "kaze-session.target"
local session_vars = "WAYLAND_DISPLAY XDG_CURRENT_DESKTOP HYPRLAND_INSTANCE_SIGNATURE"
local ctl = "systemctl --user "
local dbus_env = "dbus-update-activation-environment "

local function owns_environment()
    local signature = os.getenv("HYPRLAND_INSTANCE_SIGNATURE")
    if not signature or signature == "" then return false end
    local env = fs.capture(ctl .. "show-environment")
    if not env then return nil end
    return ("\n" .. env):match("\nHYPRLAND_INSTANCE_SIGNATURE=([^\n]*)") == signature
end

local function clear_clipboard()
    local dir = fs.runtime_dir()
    if not dir then return false end
    local path = fs.shell_quote(dir)
    return os.execute("[ ! -L " .. path .. " ] && rm -f -- " .. path .. "/cliphist.db " .. path .. "/cliphist.db.tmp")
end

local function clear_environment()
    -- The D-Bus activation API can overwrite values, but only systemd can unset them.
    local dbus_ok = os.execute(dbus_env .. "WAYLAND_DISPLAY= XDG_CURRENT_DESKTOP= HYPRLAND_INSTANCE_SIGNATURE=")
    local systemd_ok = os.execute(ctl .. "unset-environment " .. session_vars)
    return dbus_ok and systemd_ok
end

local entry, read_entry = fs.env_entry, fs.read_env_entry

function M.render_environment(cfg, theme, previous)
    local base = previous and previous:match("^(.-\n)XCURSOR_THEME=")
    if previous then assert(base, "invalid session.env; start a new Kaze login") end
    base = base or table.concat({
        entry("XDG_CONFIG_HOME", fs.config_dir()),
        entry("XDG_DATA_HOME", fs.data_dir()),
        entry("XDG_CACHE_HOME", fs.cache_dir()),
        entry("PATH", os.getenv("PATH") or fs.home() .. "/.local/bin:/usr/bin"),
    })
    -- Keep the login's locale and PATH, even when the reload is invoked over SSH.
    if not read_entry(base, "LC_CTYPE") then
        local lang, all, ctype = fs.utf8_locale()
        base = base .. entry("LANG", lang) .. entry("LC_ALL", all) .. entry("LC_CTYPE", ctype)
    end
    if not previous then
        local sid = os.getenv("XDG_SESSION_ID")
        if sid and sid:match("^[%w_-]+$") then
            base = base .. entry("KAZE_SESSION_ID", sid)
        end
    end

    local wallpaper = cfg.wallpaper_expanded
    if type(wallpaper) ~= "string" or wallpaper == "" or not fs.file_exists(wallpaper) then
        wallpaper = ""
    end
    local cursor_size = type(cfg.cursor_size) == "number" and math.tointeger(cfg.cursor_size)
    assert(cursor_size and cursor_size > 0, "cursor_size must be a positive integer")
    local profile = cfg.profile == "full" and "full" or "minimal"
    local enable_polkit = (cfg.polkit == true or (cfg.polkit ~= false and profile == "full")) and "1" or "0"
    local enable_fcitx5 = (cfg.fcitx5 == true or (cfg.fcitx5 ~= false and profile == "full")) and "1" or "0"
    local tail = {
        entry("XCURSOR_THEME", cfg.cursor_theme),
        entry("XCURSOR_SIZE", tostring(cursor_size)),
        entry("KAZE_WALLPAPER", wallpaper),
        entry("KAZE_WALLPAPER_COLOR", "#" .. theme.bg),
        entry("KAZE_NIGHT_TEMP", tostring(cfg.night_temp)),
        entry("KAZE_PROFILE", profile),
        entry("KAZE_ENABLE_POLKIT", enable_polkit),
        entry("KAZE_ENABLE_FCITX5", enable_fcitx5),
    }
    if enable_fcitx5 == "1" then
        tail[#tail + 1] = entry("XMODIFIERS", "@im=fcitx")
    end
    return base .. table.concat(tail)
end

function M.read_appearance(contents)
    local wallpaper = assert(read_entry(contents, "KAZE_WALLPAPER"), "session.env has no wallpaper setting")
    local color = assert(read_entry(contents, "KAZE_WALLPAPER_COLOR"), "session.env has no wallpaper color")
    return {
        wallpaper = wallpaper ~= "" and wallpaper or color,
        has_image = wallpaper ~= "",
        cursor_theme = assert(read_entry(contents, "XCURSOR_THEME"), "session.env has no cursor theme"),
        cursor_size = assert(read_entry(contents, "XCURSOR_SIZE"), "session.env has no cursor size"),
        enable_polkit = (read_entry(contents, "KAZE_ENABLE_POLKIT") or "0") == "1",
        enable_fcitx5 = (read_entry(contents, "KAZE_ENABLE_FCITX5") or "0") == "1",
    }
end

function M.set_cursor(appearance)
    local q = fs.shell_quote
    local out = fs.capture("timeout 3s hyprctl setcursor " .. q(appearance.cursor_theme) .. " " .. q(appearance.cursor_size))
    if not (out and out:match("^%s*ok%s*$")) then
        error("hyprctl setcursor failed" .. (out and (": " .. out) or ""), 0)
    end
end

function M.start(sync_cmd)
    for key in session_vars:gmatch("%S+") do
        local value = os.getenv(key)
        if not value or value == "" then
            return nil, "missing " .. key
        end
    end
    local active = fs.capture(ctl .. "show -p ActiveState --value " .. target)
    if not active then return nil, "cannot query " .. target end
    if active == "active\n" or active == "activating\n" then
        if owns_environment() then return true end
        return nil, target .. " already belongs to another session"
    end
    if not os.execute(fs.shell_quote(sync_cmd) .. " --session-start") then
        return nil, "could not generate session configs"
    end
    if not clear_clipboard() then return nil, "could not remove stale session clipboard" end
    if not os.execute(dbus_env .. "--systemd " .. session_vars) then
        clear_environment()
        return nil, "could not export the Wayland activation environment"
    end
    if not os.execute(ctl .. "start " .. target) then
        clear_environment()
        return nil, "could not start " .. target
    end
    return true
end

function M.is_active()
    return owns_environment() and os.execute(ctl .. "is-active --quiet " .. target)
end

function M.stop()
    local owns = owns_environment()
    if owns == nil then return nil, "cannot read systemd's activation environment" end
    if not owns then return true end
    -- Finish the MP4 while the compositor still exists. Do not take the
    -- recorder CLI's lock here: it may be held by an interactive slurp.
    local recorder = "kaze-record.service"
    local status = fs.capture(ctl .. "show -p ActiveState --value " .. recorder)
    if status and status ~= "inactive\n" and status ~= "failed\n" then
        if not os.execute(ctl .. "stop " .. recorder) then
            io.stderr:write("kaze-session: recorder stop failed; the recording may be incomplete\n")
        end
    end
    if not os.execute(ctl .. "stop " .. target) then
        return nil, "could not stop " .. target
    end
    local clipboard_ok = clear_clipboard()
    local env_ok = clear_environment()
    if not clipboard_ok then return nil, "could not remove the session clipboard" end
    if not env_ok then return nil, "could not clear the Wayland activation environment" end
    return true
end

function M.lock()
    -- A request from SSH must target the graphical login, not the SSH session.
    -- hypridle subscribes to the display session from its systemd user unit.
    local id = fs.capture('loginctl show-user "$(id -u)" -p Display --value')
    id = id and id:match("^([%w_-]+)\n?$")
    if not id then return nil, "could not find the display session in logind" end
    if not os.execute("loginctl lock-session " .. fs.shell_quote(id)) then
        return nil, "logind refused the lock request"
    end
    -- loginctl lock-session always exits 0 even if hypridle is dead; fall back
    -- directly to kaze-lock.service when hypridle is not active.
    if not os.execute(ctl .. "is-active --quiet kaze-hypridle.service") then
        if not os.execute(ctl .. "start kaze-lock.service") then
            return nil, "hypridle is inactive and direct lock failed"
        end
    end
    return true
end

function M.screen_off()
    -- Hyprland's native wake-on-key also handles releases. Don't let the key
    -- that accepted the Fuzzel selection immediately wake the displays again.
    local code = [[
local function turn_off()
    hl.dispatch(hl.dsp.dpms({ action = "off" }))
end
local function accept_key_held()
    for _, key in ipairs({ "Return", "KP_Enter", "Tab", "y", "Control_L", "Control_R", "Shift_L", "Shift_R" }) do
        if hl.is_key_down(key) then return true end
    end
    return false
end
if not accept_key_held() then
    turn_off()
else
    local release
    release = hl.on("input.keyboard.key", function(_, _, state)
        if state ~= 0 then return end
        -- Run after Hyprland processes the release and its DPMS wake handling.
        hl.timer(function()
            if release:is_active() and not accept_key_held() then
                release:remove()
                turn_off()
            end
        end, { timeout = 1, type = "oneshot" })
    end)
    hl.timer(function() release:remove() end, { timeout = 10000, type = "oneshot" })
end
]]
    local out = fs.capture("hyprctl eval " .. fs.shell_quote(code))
    if out and out:match("^%s*ok%s*$") then return true end
    return nil, "could not turn off the displays"
end

function M.wake_displays()
    local lid = fs.capture("busctl --system --timeout=1s get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager LidClosed 2>/dev/null")
    if lid ~= "b true\n" then
        return os.execute("hyprctl dispatch 'hl.dsp.dpms({ action = \"on\" })'")
    end
    local code = [[
for _, monitor in ipairs(hl.get_monitors({ all = true })) do
    local name = monitor.name
    if not (name:match("^eDP%-") or name:match("^LVDS%-") or name:match("^DSI%-")) then
        hl.dispatch(hl.dsp.dpms({ action = "on", monitor = name }))
    end
end
]]
    return os.execute("hyprctl eval " .. fs.shell_quote(code))
end

return M
