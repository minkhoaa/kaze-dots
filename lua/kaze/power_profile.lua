local fs = require("kaze.fs")
local notify_store = require("kaze.notify")
local popups = require("kaze.popups")

local M = {}

local CANONICAL_PROFILES = { "power-saver", "balanced", "performance" }

local DBUS_BACKENDS = {
    {
        dest = "org.freedesktop.UPower.PowerProfiles",
        path = "/org/freedesktop/UPower/PowerProfiles",
        iface = "org.freedesktop.UPower.PowerProfiles",
    },
    {
        dest = "net.hadess.PowerProfiles",
        path = "/net/hadess/PowerProfiles",
        iface = "net.hadess.PowerProfiles",
    },
}

local function cmd_exists(bin)
    local ok = os.execute("command -v " .. fs.shell_quote(bin) .. " >/dev/null 2>&1")
    return ok == true or ok == 0
end

local function system_service_active(unit)
    if not cmd_exists("systemctl") then
        return false
    end
    local ok = os.execute("systemctl is-active --quiet " .. fs.shell_quote(unit) .. " >/dev/null 2>&1")
    return ok == true or ok == 0
end

-- Returns (bin, title) or (nil, nil).
-- Prefers impala only when standalone iwd is active (iwd active and NetworkManager inactive),
-- or as a fallback when nmtui is absent and iwd is active.
function M.wifi_tool()
    local has_impala = cmd_exists("impala")
    local has_nmtui = cmd_exists("nmtui")
    if not has_impala and not has_nmtui then
        return nil, nil
    end
    if has_impala and system_service_active("iwd.service") then
        if not system_service_active("NetworkManager.service") or not has_nmtui then
            return "impala", "Network (impala)"
        end
    end
    if has_nmtui then
        return "nmtui", "Network (nmtui)"
    end
    return nil, nil
end

local function busctl_get(backend, prop)
    local q = fs.shell_quote
    local cmd = string.format(
        "busctl --system --auto-start=no --timeout=1s get-property %s %s %s %s 2>/dev/null",
        q(backend.dest),
        q(backend.path),
        q(backend.iface),
        q(prop)
    )
    return fs.capture(cmd)
end

local function probe_backend()
    if not cmd_exists("busctl") then
        return nil, nil
    end
    if system_service_active("tlp.service") then
        return nil, nil
    end
    for _, backend in ipairs(DBUS_BACKENDS) do
        local out = busctl_get(backend, "ActiveProfile")
        local active = out and out:match('^s%s+"([^"]+)"')
        if active and active ~= "" then
            return backend, active
        end
    end
    return nil, nil
end

function M.available()
    local backend = probe_backend()
    return backend ~= nil
end

function M.current()
    local _, active = probe_backend()
    return active
end

function M.list()
    local backend = probe_backend()
    if not backend then
        return {}
    end
    local raw = busctl_get(backend, "Profiles")
    local seen = {}
    local extras = {}
    if raw then
        for name in raw:gmatch('"Profile"%s+s%s+"([^"]+)"') do
            if not seen[name] then
                seen[name] = true
                extras[#extras + 1] = name
            end
        end
        if #extras == 0 then
            for _, canon in ipairs(CANONICAL_PROFILES) do
                if raw:find('"' .. canon .. '"', 1, true) then
                    seen[canon] = true
                    extras[#extras + 1] = canon
                end
            end
        end
    end
    if #extras == 0 then
        return { "power-saver", "balanced", "performance" }
    end
    local ordered = {}
    local added = {}
    for _, canon in ipairs(CANONICAL_PROFILES) do
        if seen[canon] then
            ordered[#ordered + 1] = canon
            added[canon] = true
        end
    end
    for _, name in ipairs(extras) do
        if not added[name] then
            ordered[#ordered + 1] = name
            added[name] = true
        end
    end
    return ordered
end

function M.set(profile)
    if type(profile) ~= "string" or not profile:match("^[%w_-]+$") then
        return false, "invalid power profile name: " .. tostring(profile)
    end
    if system_service_active("tlp.service") then
        return false, "tlp.service is active; refusing to touch D-Bus power profiles"
    end
    local backend = probe_backend()
    if not backend then
        return false, "no active D-Bus PowerProfiles service found"
    end
    local q = fs.shell_quote
    local cmd = string.format(
        "busctl --system --auto-start=no --timeout=2s set-property %s %s %s ActiveProfile s %s >/dev/null 2>&1",
        q(backend.dest),
        q(backend.path),
        q(backend.iface),
        q(profile)
    )
    local ok = os.execute(cmd)
    if not (ok == true or ok == 0) then
        return false, "failed to set ActiveProfile to " .. profile
    end
    return true
end

function M.menu(opts)
    opts = opts or {}
    if popups.toggle_existing_fuzzel("kaze-power-profile") then
        return true
    end
    if not cmd_exists("fuzzel") then
        return false, "fuzzel not found in PATH"
    end
    local backend, current = probe_backend()
    if not backend then
        return false, "no active D-Bus PowerProfiles service (or tlp.service is active)"
    end
    local profiles = M.list()
    local lines = {}
    local valid = {}
    local active_idx = nil
    for idx, p in ipairs(profiles) do
        valid[p] = true
        local marker = (p == current) and " (active)" or ""
        lines[#lines + 1] = p .. marker
        if p == current and active_idx == nil then
            active_idx = idx - 1
        end
    end

    local trimmed, dmenu_err = popups.run_dmenu(lines, {
        flags = popups.active_right_flags(),
        width = 40,
        lines = #lines,
        minimal_lines = true,
        line_height = 32,
        select_index = active_idx,
        prompt = "Power Profile > ",
        tag = "kaze-power-profile",
    })
    if not trimmed then
        return false, dmenu_err or "failed to launch fuzzel"
    end
    if trimmed == "" then
        return true
    end
    local choice = trimmed:match("^(%S+)")
    if not choice or not valid[choice] then
        return false, "unrecognized power profile selection: " .. trimmed
    end
    local ok, err = M.set(choice)
    if not ok then
        return false, err
    end

    local hypr_sig = os.getenv("HYPRLAND_INSTANCE_SIGNATURE")
    local wl_disp = os.getenv("WAYLAND_DISPLAY")
    if not opts.quiet and ((hypr_sig and hypr_sig ~= "") or (wl_disp and wl_disp ~= "")) and cmd_exists("notify-send") then
        notify_store.record({
            app = "kaze-power-profile",
            icon = "󰓅",
            urgency = "low",
            summary = "Power profile",
            body = "Active: " .. choice,
        })
        os.execute(string.format(
            "notify-send -a kaze-power-profile -t 1800 -u low -h string:x-canonical-private-synchronous:kaze-switch %s %s >/dev/null 2>&1 || true",
            fs.shell_quote("Power profile"),
            fs.shell_quote("Active: " .. choice)
        ))
    end
    return true
end

return M
