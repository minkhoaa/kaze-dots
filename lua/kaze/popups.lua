local fs = require("kaze.fs")

local M = {}

local dmenu_seq = 0

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

local function norm_hex(v, fallback)
    local s = tostring(v or ""):gsub("^#", "")
    if s:match("^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$") then
        return "#" .. s:lower()
    end
    return "#" .. fallback
end

local function write_swatch(filename, svg)
    local rt = fs.private_runtime_dir()
    if not rt then
        return nil
    end
    local dir = rt .. "/swatches"
    local path = dir .. "/" .. filename
    if fs.read_file(path) ~= svg then
        fs.write_atomic(path, svg)
    end
    return path
end

function M.ensure_theme_swatch(name, palette)
    if type(name) ~= "string" or name == "" or type(palette) ~= "table" then
        return nil
    end
    local safe = name:gsub("[^%w_-]", "_")
    local svg = string.format(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48" width="48" height="48">'
            .. '<rect x="1.5" y="1.5" width="45" height="45" rx="0" fill="%s" stroke="%s" stroke-width="3"/>'
            .. '<rect x="8" y="8" width="14" height="14" rx="0" fill="%s"/>'
            .. '<rect x="26" y="8" width="14" height="14" rx="0" fill="%s"/>'
            .. '<rect x="8" y="26" width="14" height="14" rx="0" fill="%s"/>'
            .. '<rect x="26" y="26" width="14" height="14" rx="0" fill="%s"/>'
            .. '</svg>\n',
        norm_hex(palette.bg_alt, "181b22"),
        norm_hex(palette.border, "323846"),
        norm_hex(palette.accent, "89b4fa"),
        norm_hex(palette.ok, "a6e3a1"),
        norm_hex(palette.warn, "f9e2af"),
        norm_hex(palette.danger, "f38ba8")
    )
    return write_swatch(safe .. ".svg", svg)
end

function M.ensure_layout_swatch(name, palette)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    local pal = type(palette) == "table" and palette or {}
    local bg_alt = norm_hex(pal.bg_alt, "181b22")
    local border = norm_hex(pal.border, "323846")
    local surface = norm_hex(pal.surface, "252a36")
    local accent = norm_hex(pal.accent, "89b4fa")
    local muted = norm_hex(pal.fg_muted, "8b95a7")

    local inner
    if name == "sidebar" then
        inner = string.format(
            '<rect x="7" y="7" width="6" height="34" rx="0" fill="%s"/>'
                .. '<rect x="16" y="7" width="25" height="34" rx="0" fill="%s"/>',
            accent,
            surface
        )
    elseif name == "islands" then
        inner = string.format(
            '<rect x="7" y="7" width="9" height="5" rx="0" fill="%s"/>'
                .. '<rect x="19" y="7" width="10" height="5" rx="0" fill="%s"/>'
                .. '<rect x="32" y="7" width="9" height="5" rx="0" fill="%s"/>'
                .. '<rect x="7" y="15" width="34" height="26" rx="0" fill="%s"/>',
            accent,
            muted,
            surface,
            surface
        )
    else
        inner = string.format(
            '<rect x="3" y="3" width="42" height="6" rx="0" fill="%s"/>'
                .. '<rect x="7" y="13" width="34" height="28" rx="0" fill="%s"/>',
            accent,
            surface
        )
    end

    local safe = name:gsub("[^%w_-]", "_")
    local svg = string.format(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48" width="48" height="48">'
            .. '<rect x="1.5" y="1.5" width="45" height="45" rx="0" fill="%s" stroke="%s" stroke-width="3"/>'
            .. '%s</svg>\n',
        bg_alt,
        border,
        inner
    )
    return write_swatch("layout-" .. safe .. ".svg", svg)
end

local function hash64_hex(s)
    local h1 = 2166136261
    local h2 = 33554467
    for i = 1, #s do
        local b = s:byte(i)
        h1 = ((h1 ~ b) * 16777619) & 0xffffffff
        h2 = ((h2 ~ (b * (i % 31 + 1))) * 2654435761) & 0xffffffff
    end
    return string.format("%08x%08x", h1, h2)
end

function M.ensure_wallpaper_fallback_swatch(palette)
    local pal = type(palette) == "table" and palette or {}
    local bg_alt = norm_hex(pal.bg_alt, "181b22")
    local border = norm_hex(pal.border, "323846")
    local surface = norm_hex(pal.surface, "252a36")
    local accent = norm_hex(pal.accent, "89b4fa")
    local svg = string.format(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48" width="48" height="48">'
            .. '<rect x="1.5" y="1.5" width="45" height="45" rx="0" fill="%s" stroke="%s" stroke-width="3"/>'
            .. '<rect x="8" y="10" width="32" height="28" rx="0" fill="%s"/>'
            .. '<polygon points="10,36 20,22 28,31 33,26 38,36" fill="%s"/>'
            .. '<rect x="29" y="14" width="6" height="6" rx="0" fill="%s"/>'
            .. '</svg>\n',
        bg_alt,
        border,
        surface,
        accent,
        norm_hex(pal.warn, "f9e2af")
    )
    return write_swatch("wall-fallback.svg", svg) or "image-x-generic"
end

function M.ensure_wallpaper_thumb(src_path, opts)
    if type(src_path) ~= "string" or src_path == "" then
        return nil
    end
    opts = opts or {}
    local lower = src_path:lower()
    local native_fuzzel = (lower:match("%.png$") ~= nil or lower:match("%.svg$") ~= nil)

    local stat_line = fs.capture("stat -L -c '%Y-%s' -- " .. fs.shell_quote(src_path) .. " 2>/dev/null")
    local stamp = (stat_line and stat_line:match("^(%d+%-%d+)")) or "0-0"
    local cache_dir = fs.cache_dir() .. "/kaze/wall-thumbs"
    local out_path = string.format("%s/%s-%s.png", cache_dir, hash64_hex(src_path), stamp)

    if fs.file_exists(out_path) then
        return out_path, false
    end

    if opts.allow_generate == false then
        return (native_fuzzel and src_path) or M.ensure_wallpaper_fallback_swatch(opts.palette), false
    end

    local has_ffmpeg = opts.has_ffmpeg
    if has_ffmpeg == nil then
        has_ffmpeg = fs.command_exists("ffmpeg")
    end
    local magick_bin = opts.magick_bin
    if magick_bin == nil and not has_ffmpeg then
        if fs.command_exists("magick") then
            magick_bin = "magick"
        elseif fs.command_exists("convert") then
            magick_bin = "convert"
        else
            magick_bin = false
        end
    end

    if not has_ffmpeg and not magick_bin then
        return (native_fuzzel and src_path) or M.ensure_wallpaper_fallback_swatch(opts.palette), false
    end

    fs.mkdir_p(cache_dir)
    local tmp_path = out_path .. ".tmp.png"
    local cmd
    if has_ffmpeg then
        cmd = string.format(
            "ffmpeg -v error -y -i %s -vf %s -frames:v 1 %s >/dev/null 2>&1",
            fs.shell_quote(src_path),
            fs.shell_quote("scale=96:96:force_original_aspect_ratio=increase,crop=96:96"),
            fs.shell_quote(tmp_path)
        )
    else
        cmd = string.format(
            "%s %s -thumbnail 96x96^ -gravity center -extent 96x96 %s >/dev/null 2>&1",
            fs.shell_quote(magick_bin),
            fs.shell_quote(src_path .. "[0]"),
            fs.shell_quote(tmp_path)
        )
    end

    local ok = os.execute(cmd)
    if (ok == true or ok == 0) and fs.file_exists(tmp_path) then
        local renamed = os.rename(tmp_path, out_path)
        if renamed then
            return out_path, true
        end
    end
    os.remove(tmp_path)
    return (native_fuzzel and src_path) or M.ensure_wallpaper_fallback_swatch(opts.palette), false
end

local function monotonic_ms()
    local raw = fs.read_file("/proc/uptime")
    local sec = raw and tonumber(raw:match("^([%d%.]+)"))
    if sec then
        return math.floor(sec * 1000)
    end
    return os.time() * 1000
end

-- Atomic write inside $XDG_RUNTIME_DIR/kaze using pure Lua I/O first so callers
-- running inside Hyprland's embedded Lua engine never fork via os.execute.
local function write_runtime_file(filename, payload)
    local dir = fs.runtime_dir()
    if not dir then
        return false
    end
    local path = dir .. "/" .. filename
    dmenu_seq = dmenu_seq + 1
    local tmp = string.format("%s.tmp.%d.%d", path, os.time(), dmenu_seq)
    local f = io.open(tmp, "wb")
    if not f then
        local created = fs.private_runtime_dir()
        if not created then
            return false
        end
        fs.write_atomic(created .. "/" .. filename, payload)
        return true
    end
    local ok = f:write(payload) and f:flush()
    local c_ok = f:close()
    if not (ok and c_ok) then
        os.remove(tmp)
        return false
    end
    if not os.rename(tmp, path) then
        os.remove(tmp)
        return false
    end
    return true
end

function M.mark_active_fuzzel(tag)
    if type(tag) ~= "string" or tag == "" then
        return false
    end
    return write_runtime_file("active-fuzzel", tag:gsub("[\r\n\t]+", "") .. "\n")
end

function M.active_fuzzel_tag()
    local rt = fs.runtime_dir()
    local path = rt and (rt .. "/active-fuzzel") or nil
    if not path then
        return nil
    end
    local data = fs.read_file(path)
    if not data then
        return nil
    end
    local tag = data:match("^([^\r\n\t]+)")
    return (tag and tag ~= "") and tag or nil
end

function M.clear_active_fuzzel(expected_tag)
    local rt = fs.runtime_dir()
    local path = rt and (rt .. "/active-fuzzel") or nil
    if not path then
        return
    end
    if expected_tag and expected_tag ~= "" then
        local cur = M.active_fuzzel_tag()
        if cur and cur ~= expected_tag then
            return
        end
    end
    os.remove(path)
end

function M.record_dismiss_guard(target, subtarget)
    if type(target) ~= "string" or target == "" then
        return false
    end
    local clean_t = target:gsub("[\r\n\t]+", "")
    local clean_s = type(subtarget) == "string" and subtarget:gsub("[\r\n\t]+", "") or ""
    return write_runtime_file("dismiss-guard", string.format("%s\t%d\t%s\n", clean_t, monotonic_ms(), clean_s))
end

function M.consume_dismiss_guard(target, subtarget_or_window, window_ms)
    local subtarget = nil
    local win_ms = window_ms
    if type(subtarget_or_window) == "number" then
        win_ms = subtarget_or_window
    elseif type(subtarget_or_window) == "string" and subtarget_or_window ~= "" then
        subtarget = subtarget_or_window
    end
    local rt = fs.runtime_dir()
    local path = rt and (rt .. "/dismiss-guard") or nil
    if not path or type(target) ~= "string" or target == "" then
        return false
    end
    local data = fs.read_file(path)
    if not data or data == "" then
        return false
    end
    local guard_target, ts_s, guard_sub = data:match("^([^\t\r\n]+)\t(%d+)\t?([^\r\n]*)")
    local ts = tonumber(ts_s)
    local age = ts and (monotonic_ms() - ts) or nil
    if guard_target == target and age and age >= 0 and age <= (tonumber(win_ms) or 450) then
        if not subtarget or not guard_sub or guard_sub == "" or guard_sub == subtarget then
            os.remove(path)
            return true
        end
        os.remove(path)
    end
    return false
end

function M.toggle_existing_fuzzel(tag)
    local running = os.execute("pgrep -x fuzzel >/dev/null 2>&1")
    if running == true or running == 0 then
        local prev_tag = M.active_fuzzel_tag()
        os.execute("pkill -x fuzzel >/dev/null 2>&1")
        M.clear_active_fuzzel()
        if not tag or tag == "" or not prev_tag or prev_tag == "" or prev_tag == tag then
            return true
        end
        -- Switching directly from one fuzzel menu to another: wait briefly for old fuzzel to exit.
        for _ = 1, 10 do
            local still = os.execute("pgrep -x fuzzel >/dev/null 2>&1")
            if not (still == true or still == 0) then
                break
            end
            os.execute("sleep 0.02")
        end
        return false
    end
    return M.consume_dismiss_guard("fuzzel", tag)
end

-- Launches fuzzel --dmenu via a private temp file so NUL-delimited icon tags (\0icon\x1f...)
-- are never truncated by execve() or shell printf arguments.
function M.run_dmenu(entries, opts)
    opts = opts or {}
    local attach_icons = (opts.force_icons == true) or ((os.getenv("WAYLAND_DISPLAY") or "") ~= "")
    local lines = {}
    for _, entry in ipairs(entries or {}) do
        if type(entry) == "table" then
            local text = tostring(entry.text or ""):gsub("[%z\r\n]+", " ")
            local icon = entry.icon
            if attach_icons and type(icon) == "string" and icon ~= "" then
                icon = icon:gsub("[%z\r\n\x1f]+", "")
                if icon ~= "" then
                    lines[#lines + 1] = text .. "\0icon\x1f" .. icon
                else
                    lines[#lines + 1] = text
                end
            else
                lines[#lines + 1] = text
            end
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

    local argv = { "fuzzel", "--dmenu" }
    if opts.flags and opts.flags ~= "" then
        argv[#argv + 1] = opts.flags
    end
    if opts.width then
        argv[#argv + 1] = string.format("-w %d", math.floor(tonumber(opts.width)))
    end
    if opts.lines then
        argv[#argv + 1] = string.format("--lines %d", math.floor(tonumber(opts.lines)))
    end
    if opts.minimal_lines then
        argv[#argv + 1] = "--minimal-lines"
    end
    if opts.hide_prompt then
        argv[#argv + 1] = "--hide-prompt"
    end
    if opts.line_height then
        argv[#argv + 1] = string.format("--line-height=%d", math.floor(tonumber(opts.line_height)))
    end
    if opts.image_size_ratio ~= nil then
        argv[#argv + 1] = string.format("--override=main.image-size-ratio=%s", tostring(opts.image_size_ratio))
    end
    if opts.select_index ~= nil then
        local idx = math.floor(tonumber(opts.select_index))
        if idx >= 0 and (#lines == 0 or idx < #lines) then
            argv[#argv + 1] = string.format("--select-index=%d", idx)
        end
    elseif opts.select and opts.select ~= "" then
        argv[#argv + 1] = "--select=" .. fs.shell_quote(opts.select)
    end
    if opts.prompt and opts.prompt ~= "" then
        argv[#argv + 1] = "-p " .. fs.shell_quote(opts.prompt)
    end
    if opts.extra_args and opts.extra_args ~= "" then
        argv[#argv + 1] = opts.extra_args
    end

    local utf8_guard = "case \"${LC_ALL:-${LC_CTYPE:-${LANG:-C}}}\" in *.UTF-8*|*.utf8*) ;; *) export LC_CTYPE=C.UTF-8 ;; esac; "
    local cmd = utf8_guard .. table.concat(argv, " ") .. " < " .. fs.shell_quote(tmp_path)
    if opts.tag and opts.tag ~= "" then
        M.mark_active_fuzzel(opts.tag)
    end
    local proc = io.popen(cmd, "r")
    if not proc then
        if opts.tag and opts.tag ~= "" then
            M.clear_active_fuzzel(opts.tag)
        end
        os.remove(tmp_path)
        return nil, "failed to launch fuzzel"
    end
    local out = proc:read("*a") or ""
    proc:close()
    if opts.tag and opts.tag ~= "" then
        M.clear_active_fuzzel(opts.tag)
    end
    os.remove(tmp_path)
    return (out:gsub("[\r\n]+$", ""))
end

return M
