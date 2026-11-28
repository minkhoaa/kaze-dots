local fs = require("kaze.fs")
local hypr_user = require("kaze.hypr_user")

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

local function clear_environment()
    -- The D-Bus activation API can overwrite values, but only systemd can unset them.
    local dbus_ok = os.execute(dbus_env .. "WAYLAND_DISPLAY= XDG_CURRENT_DESKTOP= HYPRLAND_INSTANCE_SIGNATURE=")
    local systemd_ok = os.execute(ctl .. "unset-environment " .. session_vars)
    return dbus_ok and systemd_ok
end

local entry, read_entry = fs.env_entry, fs.read_env_entry

function M.render_environment(cfg, previous)
    local base = previous and previous:match("^(.-\n)XCURSOR_THEME=")
    if previous then assert(base, "invalid session.env; start a new Kaze login") end
    base = base or table.concat({
        entry("XDG_CONFIG_HOME", fs.config_dir()),
        entry("XDG_DATA_HOME", fs.data_dir()),
        entry("XDG_CACHE_HOME", fs.cache_dir()),
        entry("PATH", os.getenv("PATH") or fs.home() .. "/.local/bin:/usr/bin"),
    })
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

    local cursor_size = type(cfg.cursor_size) == "number" and math.tointeger(cfg.cursor_size)
    assert(cursor_size and cursor_size > 0, "cursor_size must be a positive integer")
    local profile = cfg.profile == "full" and "full" or "minimal"
    local enable_fcitx5 = (cfg.fcitx5 == true or (cfg.fcitx5 ~= false and profile == "full")) and "1" or "0"
    local tail = {
        entry("XCURSOR_THEME", cfg.cursor_theme),
        entry("XCURSOR_SIZE", tostring(cursor_size)),
        entry("KAZE_PROFILE", profile),
        entry("KAZE_ENABLE_FCITX5", enable_fcitx5),
    }
    if enable_fcitx5 == "1" then
        tail[#tail + 1] = entry("XMODIFIERS", "@im=fcitx")
    end
    if type(cfg.drm_devices) == "string" and cfg.drm_devices ~= "" then
        tail[#tail + 1] = entry("AQ_DRM_DEVICES", cfg.drm_devices)
    end
    if cfg.prefer_mesa_egl == true then
        tail[#tail + 1] = entry("__EGL_VENDOR_LIBRARY_FILENAMES", "/usr/share/glvnd/egl_vendor.d/50_mesa.json")
    end
    return base .. table.concat(tail)
end

function M.write_environment(cfg)
    local rdir = fs.private_runtime_dir()
    if not rdir then
        return nil, "cannot prepare $XDG_RUNTIME_DIR/kaze"
    end
    local ok, err = pcall(fs.write_atomic, rdir .. "/session.env", M.render_environment(cfg or hypr_user.load()))
    if not ok then
        return nil, tostring(err)
    end
    return true
end

function M.start()
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
    local env_written, env_err = M.write_environment(hypr_user.load())
    if not env_written then
        return nil, env_err or "could not write session environment"
    end
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
    local display_cli = fs.home() .. "/.local/bin/kaze-display"
    if fs.file_exists(display_cli) then
        os.execute(fs.shell_quote(display_cli) .. " cleanup >/dev/null 2>&1 || true")
    elseif fs.command_exists("kaze-display") then
        os.execute("kaze-display cleanup >/dev/null 2>&1 || true")
    end
    -- Finish the MP4 while the compositor still exists.
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
    local env_ok = clear_environment()
    if not env_ok then return nil, "could not clear the Wayland activation environment" end
    return true
end

function M.lock()
    if fs.command_exists("kaze-shell") then
        local ok = os.execute("kaze-shell msg lock >/dev/null 2>&1")
        if ok == true or ok == 0 then
            return true
        end
    end
    local id = fs.capture('loginctl show-user "$(id -u)" -p Display --value')
    id = id and id:match("^([%w_-]+)\n?$")
    if not id then return nil, "could not lock session via kaze-shell or logind" end
    if not os.execute("loginctl lock-session " .. fs.shell_quote(id)) then
        return nil, "logind refused the lock request"
    end
    return true
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
