local M = {}

local MONTH_NAMES = {
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
}

local WEEKDAY_NAMES = {
    "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
}

function M.top_flags(layout)
    local ui = (type(layout) == "table" and type(layout.ui) == "table") and layout.ui or {}
    local top_y = tonumber(ui.popup_top_y) or 10
    return string.format("--namespace=kaze-popup-top --anchor=top --y-margin=%d", top_y)
end

function M.menu_flags(layout)
    local name = type(layout) == "table" and layout.name or "sidebar"
    local ui = (type(layout) == "table" and type(layout.ui) == "table") and layout.ui or {}
    if name == "sidebar" then
        return "--namespace=kaze-popup-left --anchor=top-left --x-margin=8 --y-margin=8"
    end
    local x = tonumber(ui.popup_right_x) or 10
    local y = tonumber(ui.popup_top_y) or 8
    return string.format("--namespace=kaze-popup-top --anchor=top-left --x-margin=%d --y-margin=%d", x, y)
end

-- Status / quick-switcher popups align right next to the bar's status cluster:
-- bottom-left (sliding out from the left rail) on sidebar; top-right (dropping
-- straight down out of the top bar) on islands & slim.
function M.status_flags(layout)
    local name = type(layout) == "table" and layout.name or "sidebar"
    local ui = (type(layout) == "table" and type(layout.ui) == "table") and layout.ui or {}
    if name == "sidebar" then
        return "--namespace=kaze-popup-left --anchor=bottom-left --x-margin=8 --y-margin=8"
    end
    local right_x = tonumber(ui.popup_right_x) or 10
    local right_y = tonumber(ui.popup_right_y) or 8
    return string.format(
        "--namespace=kaze-popup-top --anchor=top-right --x-margin=%d --y-margin=%d",
        right_x,
        right_y
    )
end

-- Keep alias for callers & tests
M.right_flags = M.status_flags

function M.active_layout()
    local ok_cfg, config = pcall(require, "kaze.config")
    local ok_lay, layouts = pcall(require, "kaze.layouts")
    if ok_cfg and ok_lay then
        local ok, _, _, layout = pcall(config.load, { strict = false })
        if ok and type(layout) == "table" then
            return layout
        end
        return layouts.get("sidebar")
    end
    return { name = "sidebar", ui = { popup_top_y = 10, popup_right_x = 12, popup_right_y = 10 } }
end

function M.active_top_flags()
    return M.top_flags(M.active_layout())
end

function M.active_menu_flags()
    return M.menu_flags(M.active_layout())
end

function M.active_right_flags()
    return M.status_flags(M.active_layout())
end

function M.calendar_grid(year, month)
    local norm = os.date("*t", os.time({ year = year, month = month, day = 1, hour = 12 }))
    local last = os.date("*t", os.time({ year = norm.year, month = norm.month + 1, day = 0, hour = 12 }))
    local offset = (norm.wday + 5) % 7
    return {
        year = norm.year,
        month = norm.month,
        month_name = MONTH_NAMES[norm.month] or "",
        days = last.day,
        offset = offset,
    }
end

function M.render_calendar(ts)
    local now = ts or os.time()
    local d = os.date("*t", now)
    local g = M.calendar_grid(d.year, d.month)

    local wday_name = WEEKDAY_NAMES[d.wday] or ""
    local title = string.format("󰃭  %s, %02d %s %d  ·  %02d:%02d", wday_name, d.day, g.month_name, g.year, d.hour, d.min)
    local month_hdr = string.format("%s %d", g.month_name, g.year)
    local pad_left = math.max(0, math.floor((28 - #month_hdr) / 2))

    local lines = {
        title,
        "",
        string.rep(" ", pad_left) .. month_hdr,
        " Mo  Tu  We  Th  Fr  Sa  Su ",
    }

    local row = {}
    for _ = 1, g.offset do
        row[#row + 1] = "    "
    end
    for day = 1, g.days do
        if day == d.day then
            row[#row + 1] = string.format("[%2d]", day)
        else
            row[#row + 1] = string.format(" %2d ", day)
        end
        if #row == 7 then
            lines[#lines + 1] = table.concat(row)
            row = {}
        end
    end
    if #row > 0 then
        lines[#lines + 1] = (table.concat(row):gsub("%s+$", ""))
    end
    return table.concat(lines, "\n")
end

function M.exec_detached(action_cmd)
    local fs = require("kaze.fs")
    local cgroup = fs.read_file("/proc/self/cgroup")
    local in_bar = cgroup ~= nil and cgroup:find("kaze%-waybar%.service") ~= nil
    local run_cmd = action_cmd
    if in_bar and fs.command_exists("systemd-run") then
        run_cmd = "systemd-run --user --scope --quiet -- /bin/sh -c " .. fs.shell_quote(action_cmd)
    else
        run_cmd = "nohup /bin/sh -c " .. fs.shell_quote(action_cmd) .. " >/dev/null 2>&1 &"
    end
    local ok = os.execute(run_cmd)
    return ok == true or ok == 0
end

return M
