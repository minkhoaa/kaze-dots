local fs = require("kaze.fs")
local json = require("kaze.json")

local M = {}

M.BOLD = "\27[1m"
M.DIM = "\27[2m"
M.RESET = "\27[0m"

function M.hex_rgb(hex6)
    local s = tostring(hex6 or "000000"):gsub("^#", "")
    local r = tonumber(s:sub(1, 2), 16) or 0
    local g = tonumber(s:sub(3, 4), 16) or 0
    local b = tonumber(s:sub(5, 6), 16) or 0
    return r, g, b
end

function M.fg(hex6)
    local r, g, b = M.hex_rgb(hex6)
    return string.format("\27[38;2;%d;%d;%dm", r, g, b)
end

function M.bg(hex6)
    local r, g, b = M.hex_rgb(hex6)
    return string.format("\27[48;2;%d;%d;%dm", r, g, b)
end

function M.style(fg_hex, bg_hex, bold)
    local parts = { "\27[0m" }
    if bold then parts[#parts + 1] = M.BOLD end
    if fg_hex then parts[#parts + 1] = M.fg(fg_hex) end
    if bg_hex then parts[#parts + 1] = M.bg(bg_hex) end
    return table.concat(parts)
end

function M.clean_text(s)
    local str = tostring(s or "")
    str = str:gsub("\27%[[0-9;?]*[ -/]*[@-~]", "")
    str = str:gsub("[\r\n\t]+", " ")
    str = str:gsub("[%z\1-\31\127]", "")
    if utf8.len(str) then
        return str
    end
    local out = {}
    local i, n = 1, #str
    while i <= n do
        local ok_len, err_pos = utf8.len(str, i)
        if ok_len then
            out[#out + 1] = str:sub(i)
            break
        end
        if err_pos > i then
            out[#out + 1] = str:sub(i, err_pos - 1)
        end
        out[#out + 1] = ""
        i = err_pos + 1
    end
    return table.concat(out)
end

function M.vis_len(s)
    local clean = M.clean_text(s)
    return utf8.len(clean) or #clean
end

function M.trunc(s, max_len)
    s = M.clean_text(s)
    local len = utf8.len(s) or #s
    if len <= max_len then return s end
    if max_len <= 0 then return "" end
    if max_len == 1 then return "…" end
    local out = {}
    local n = 0
    for _, code in utf8.codes(s) do
        n = n + 1
        if n > max_len - 1 then break end
        out[#out + 1] = utf8.char(code)
    end
    return table.concat(out) .. "…"
end

function M.pad_right(s, width)
    s = M.trunc(s, width)
    local len = utf8.len(s) or #s
    if len < width then
        return s .. string.rep(" ", width - len)
    end
    return s
end

function M.wrap_lines(s, first_w, next_w)
    local clean = M.clean_text(s):gsub("^%s+", ""):gsub("%s+$", "")
    if clean == "" or first_w <= 0 then
        return "", M.trunc(clean, math.max(0, next_w or 0))
    end
    local chars = {}
    for _, code in utf8.codes(clean) do
        chars[#chars + 1] = utf8.char(code)
    end
    if #chars <= first_w then
        return clean, ""
    end
    local split = first_w
    for idx = first_w, math.max(1, first_w - 14), -1 do
        if chars[idx] == " " then
            split = idx
            break
        end
    end
    local line1 = table.concat(chars, "", 1, split):gsub("%s+$", "")
    local rest_start = split + 1
    while rest_start <= #chars and chars[rest_start] == " " do
        rest_start = rest_start + 1
    end
    local rest = (rest_start <= #chars) and table.concat(chars, "", rest_start) or ""
    return line1, M.trunc(rest, math.max(0, next_w or first_w))
end

-- Launch, switch view, or toggle off a floating footclient widget window.
function M.toggle_or_open(opts)
    local app_id = assert(opts.app_id, "missing app_id")
    local target_title = opts.title or app_id
    local popups = require("kaze.popups")
    if popups.consume_dismiss_guard(app_id) then
        return false
    end
    local running_fuzzel = os.execute("pgrep -x fuzzel >/dev/null 2>&1")
    if running_fuzzel == true or running_fuzzel == 0 then
        os.execute("pkill -x fuzzel >/dev/null 2>&1 || true")
    end

    local hypr_sig = os.getenv("HYPRLAND_INSTANCE_SIGNATURE")
    if hypr_sig and hypr_sig ~= "" and fs.command_exists("hyprctl") then
        local raw = fs.capture("hyprctl -j clients 2>/dev/null")
        local ok, clients = pcall(json.decode, raw or "")
        if ok and type(clients) == "table" then
            local closed_same_view = false
            for _, c in ipairs(clients) do
                if type(c) == "table" and type(c.class) == "string" and type(c.address) == "string" then
                    local addr = c.address:gsub("^0x", "")
                    if addr:match("^[0-9a-fA-F]+$") then
                        if c.class == app_id then
                            local expr = string.format("hl.dsp.window.close({ window = 'address:0x%s' })", addr)
                            os.execute("hyprctl dispatch " .. fs.shell_quote(expr) .. " >/dev/null 2>&1")
                            if c.title == nil or c.title == "" or c.title == target_title then
                                closed_same_view = true
                            end
                        elseif c.class:match("^kaze%-widget%-") then
                            local expr = string.format("hl.dsp.window.close({ window = 'address:0x%s' })", addr)
                            os.execute("hyprctl dispatch " .. fs.shell_quote(expr) .. " >/dev/null 2>&1")
                        end
                    end
                end
            end
            if closed_same_view then
                return false
            end
        end
    end

    local extra_args = ""
    if type(opts.ui_args) == "table" then
        for _, a in ipairs(opts.ui_args) do
            extra_args = extra_args .. " " .. fs.shell_quote(tostring(a))
        end
    end

    local foot_bin = opts.foot_bin or "kaze-footclient"
    local bg_alt = (opts.theme and opts.theme.bg_alt) or "181b22"
    local cmd = string.format(
        "%s -N -o main.locked-title=yes -o 'main.pad=14x12 center' -o 'text-bindings.\\x04=Escape'"
            .. " -o colors-dark.background=%s -o colors-dark.alpha=0.94"
            .. " -W %dx%d -a %s -T %s %s --ui%s",
        fs.shell_quote(foot_bin),
        fs.shell_quote(bg_alt),
        tonumber(opts.cols) or 38,
        tonumber(opts.rows) or 16,
        fs.shell_quote(app_id),
        fs.shell_quote(target_title),
        fs.shell_quote(opts.script_path),
        extra_args
    )
    local ok = os.execute(cmd)
    return ok == true or ok == 0
end

local METER_PARTIALS = { "▏", "▎", "▍", "▌", "▋", "▊", "▉" }

local function create_canvas(cols, rows, base_bg, base_fg)
    local canvas = {
        cols = cols,
        rows = rows,
        base_bg = base_bg,
        base_fg = base_fg,
        buf = {},
        cell_bg = {},
        hitboxes = {},
    }

    function canvas:begin_frame(bg_hex, fg_hex)
        if bg_hex then self.base_bg = bg_hex end
        if fg_hex then self.base_fg = fg_hex end
        self.hitboxes = {}
        self.cell_bg = {}
        for r = 1, self.rows do
            local row_cells = {}
            for c = 1, self.cols do
                row_cells[c] = self.base_bg
            end
            self.cell_bg[r] = row_cells
        end
        self.buf = { "\27[?2026h\27[H", M.style(self.base_fg, self.base_bg, false) }
        local blank = string.rep(" ", self.cols)
        for r = 1, self.rows do
            self.buf[#self.buf + 1] = string.format("\27[%d;1H%s", r, blank)
        end
    end

    function canvas:put(row, col, text, fg_hex, bg_hex, bold)
        if row < 1 or row > self.rows or col < 1 or col > self.cols then
            return
        end
        local fg_c = fg_hex or self.base_fg
        local bg_c = bg_hex or self.base_bg
        local row_cells = self.cell_bg[row]
        if row_cells then
            local span = M.vis_len(text)
            local max_c = math.min(self.cols, col + span - 1)
            for c = col, max_c do
                row_cells[c] = bg_c
            end
        end
        self.buf[#self.buf + 1] = string.format(
            "\27[%d;%dH%s%s%s",
            row,
            col,
            M.style(fg_c, bg_c, bold),
            text,
            M.style(self.base_fg, self.base_bg, false)
        )
    end

    function canvas:card(r1, c1, width, height, fill_hex)
        local fill = fill_hex or self.base_bg
        local blank = string.rep(" ", width)
        for r = r1, r1 + height - 1 do
            if r >= 1 and r <= self.rows then
                self:put(r, c1, blank, self.base_fg, fill, false)
            end
        end
    end

    function canvas:accent_card(r1, c1, width, height, fill_hex, stripe_hex, on_click)
        local fill = fill_hex or self.base_bg
        self:card(r1, c1, width, height, fill)
        if stripe_hex then
            for r = r1, r1 + height - 1 do
                if r >= 1 and r <= self.rows then
                    self:put(r, c1, "▎", stripe_hex, fill, true)
                end
            end
        end
        if on_click then
            self:hitbox(r1, c1, r1 + height - 1, c1 + width - 1, { click = on_click })
        end
    end

    function canvas:rule(row, col, width, color_hex, bg_hex)
        self:put(row, col, string.rep("─", width), color_hex or self.base_fg, bg_hex or self.base_bg, false)
    end

    function canvas:pill(row, col, label, fg_hex, bg_hex, bold, on_click, outer_bg_or_rc, on_right_click)
        local right_click = on_right_click
        if type(outer_bg_or_rc) == "function" then
            right_click = outer_bg_or_rc
        end

        local text = tostring(label or "")
        local vis_w = M.vis_len(text)
        -- Crisp sharp rectangular chip (Omarchy aesthetic, no rounded semicircles).
        self:put(row, col, text, fg_hex, bg_hex, bold)

        if on_click or right_click then
            self:hitbox(row, col, row, col + vis_w - 1, {
                click = on_click,
                right_click = right_click,
            })
        end
        return vis_w
    end

    function canvas:badge(row, col, text, fg_hex, bg_hex, bold, on_click, outer_bg_hex)
        return self:pill(row, col, " " .. M.clean_text(text) .. " ", fg_hex, bg_hex, bold, on_click, outer_bg_hex)
    end

    function canvas:scrollbar(r1, height, col, total, visible, offset, active_hex, track_hex, bg_hex)
        if not total or not visible or total <= visible or height < 1 then
            return
        end
        local max_off = math.max(1, total - visible)
        local clamped = math.max(0, math.min(max_off, tonumber(offset) or 0))
        local thumb_h = math.max(1, math.min(height, math.floor((height * visible) / total + 0.5)))
        local thumb_start = math.floor((clamped / max_off) * (height - thumb_h) + 0.5)
        local bg_c = bg_hex or self.base_bg
        for i = 0, height - 1 do
            local r = r1 + i
            local in_thumb = (i >= thumb_start and i < thumb_start + thumb_h)
            self:put(r, col, in_thumb and "┃" or "│", in_thumb and active_hex or track_hex, bg_c, in_thumb)
        end
    end

    function canvas:switch(row, col, active, theme, on_click, outer_bg_hex)
        local row_cells = self.cell_bg[row]
        local outer_bg = outer_bg_hex or (row_cells and row_cells[col]) or self.base_bg
        local inactive_bg = (outer_bg == theme.bg_alt) and theme.surface or theme.bg_alt
        local label = active and " ■ ✓ " or " □   "
        local fg_c = active and theme.accent_fg or theme.fg_muted
        local bg_c = active and theme.accent or inactive_bg
        return self:pill(row, col, label, fg_c, bg_c, true, on_click, outer_bg)
    end

    function canvas:squircle(row, col, width, glyph, caption, active, theme, on_click, active_color, on_right_click)
        local fill = active and (active_color or theme.accent) or theme.bg_alt
        local fg1 = active and theme.accent_fg or theme.fg
        local fg2 = active and theme.accent_fg or theme.fg_muted
        local function center_pad(s)
            local len = M.vis_len(s)
            if len >= width then return M.trunc(s, width) end
            local left = math.floor((width - len) / 2)
            local right = width - len - left
            return string.rep(" ", left) .. s .. string.rep(" ", right)
        end
        self:put(row, col, center_pad(glyph), fg1, fill, true)
        self:put(row + 1, col, center_pad(caption), fg2, fill, false)
        if on_click or on_right_click then
            self:hitbox(row, col, row + 1, col + width - 1, {
                click = on_click,
                right_click = on_right_click,
            })
        end
    end

    function canvas:meter(row, col, bar_w, pct, fill_hex, track_hex, bg_hex)
        local w = math.max(0, math.floor(tonumber(bar_w) or 0))
        if w == 0 then return end
        local clamped = math.max(0, math.min(100, tonumber(pct) or 0))
        local eighths = math.floor((clamped / 100) * (w * 8) + 0.5)
        local full = math.min(w, eighths // 8)
        local rem = (full < w) and (eighths % 8) or 0
        local row_cells = self.cell_bg[row]
        local bg_c = bg_hex or (row_cells and row_cells[col]) or self.base_bg
        local track_c = track_hex or bg_c

        if full > 0 then
            self:put(row, col, string.rep("█", full), fill_hex, bg_c, false)
        end
        local cursor = col + full
        if rem > 0 and full < w then
            self:put(row, cursor, METER_PARTIALS[rem], fill_hex, track_c, false)
            cursor = cursor + 1
        end
        local empty = w - full - ((rem > 0 and full < w) and 1 or 0)
        if empty > 0 then
            self:put(row, cursor, string.rep("█", empty), track_c, bg_c, false)
        end
    end

    function canvas:tile(row, col, width, line1, line2, active, theme, on_click)
        local fill = active and theme.accent or theme.surface
        local txt1 = active and theme.accent_fg or theme.fg
        local txt2 = active and theme.accent_fg or theme.fg_muted
        local function pad_cell(s)
            s = M.trunc(s, width - 2)
            local len = tonumber(utf8.len(s)) or #s
            return " " .. s .. string.rep(" ", math.max(0, width - 2 - len)) .. " "
        end
        self:put(row, col, pad_cell(line1), txt1, fill, true)
        self:put(row + 1, col, pad_cell(line2), txt2, fill, false)
        if on_click then
            self:hitbox(row, col, row + 1, col + width - 1, { click = on_click })
        end
    end

    function canvas:slider(row, col, bar_w, pct, muted, theme, handlers, bg_override)
        local bg_c = bg_override or self.base_bg
        local clamped = math.max(0, math.min(100, math.floor((tonumber(pct) or 0) + 0.5)))
        local knob_pos = math.floor((clamped / 100) * (bar_w - 1) + 0.5)
        local active_col = muted and theme.fg_muted or theme.accent
        local track_col = (bg_c == theme.surface) and theme.bg_alt or theme.surface
        for i = 0, bar_w - 1 do
            if i == knob_pos then
                self:put(row, col + i, "┃", muted and theme.danger or theme.fg, bg_c, true)
            elseif i < knob_pos then
                self:put(row, col + i, "━", active_col, bg_c, true)
            else
                self:put(row, col + i, "━", track_col, bg_c, false)
            end
        end
        if handlers then
            local function set_from_x(rel_x)
                local ratio = math.max(0, math.min(1, rel_x / math.max(1, bar_w - 1)))
                if handlers.set then
                    handlers.set(math.floor(ratio * 100 + 0.5))
                end
            end
            self:hitbox(row, col, row, col + bar_w - 1, {
                click = function(rx) set_from_x(rx) end,
                drag = function(rx) set_from_x(rx) end,
                scroll = handlers.scroll,
            })
        end
    end

    function canvas:hitbox(r1, c1, r2, c2, handlers)
        self.hitboxes[#self.hitboxes + 1] = {
            r1 = r1,
            c1 = c1,
            r2 = r2,
            c2 = c2,
            click = handlers.click,
            right_click = handlers.right_click,
            drag = handlers.drag,
            scroll = handlers.scroll,
        }
    end

    function canvas:render_string()
        local parts = {}
        for i = 1, #self.buf do
            parts[i] = self.buf[i]
        end
        parts[#parts + 1] = "\27[?2026l"
        return table.concat(parts)
    end

    function canvas:flush()
        self.buf[#self.buf + 1] = "\27[?2026l"
        io.stdout:write(table.concat(self.buf))
        io.stdout:flush()
    end

    return canvas
end

M.create_canvas = create_canvas

local function read_csi(tty)
    local seq = {}
    while true do
        local ch, read_err = tty:read(1)
        if not ch then
            if read_err then return nil end
            tty:seek("cur", 0)
            return table.concat(seq)
        end
        seq[#seq + 1] = ch
        local b = ch:byte()
        if b >= 0x40 and b <= 0x7E then
            return table.concat(seq)
        end
        if #seq > 32 then
            return table.concat(seq)
        end
    end
end

function M.run_loop(opts)
    local tty = io.open("/dev/tty", "rb")
    if not tty then
        io.stderr:write("widget: cannot open /dev/tty\n")
        os.exit(1)
    end
    tty:setvbuf("no")

    local saved_stty = fs.capture("stty -g </dev/tty 2>/dev/null")
    if saved_stty then
        saved_stty = saved_stty:gsub("[\r\n]+$", "")
    end
    local tick_ds = tonumber(opts.tick_ds)
    if tick_ds and tick_ds > 0 then
        os.execute(string.format("stty -icanon -echo -isig min 0 time %d </dev/tty 2>/dev/null", math.floor(tick_ds)))
    else
        os.execute("stty -icanon -echo -isig min 1 time 0 </dev/tty 2>/dev/null")
    end

    -- Enter alt screen, hide cursor, enable mouse click + drag + SGR + FocusIn/Out
    io.stdout:write("\27[?1049h\27[?25l\27[?1000h\27[?1002h\27[?1006h\27[?1004h")
    io.stdout:flush()

    local post_exit_cmd = nil
    local ok, err = pcall(function()
        local ui = create_canvas(opts.cols, opts.rows, opts.theme.bg_alt, opts.theme.fg)
        local active_drag_hb = nil

        local function redraw()
            opts.render(ui)
            ui:flush()
        end

        redraw()

        while true do
            local ch, read_err = tty:read(1)
            if not ch then
                if read_err or not tick_ds then
                    break
                end
                tty:seek("cur", 0)
                if opts.on_tick then
                    opts.on_tick()
                end
                redraw()
            else
                local byte = ch:byte()
                if byte == 4 or byte == 3 or ch == "q" or ch == "Q" then
                    break
                elseif ch == "\27" then
                    local nxt, nxt_err = tty:read(1)
                    if not nxt then
                        if nxt_err then break end
                        tty:seek("cur", 0)
                        break
                    end
                    if nxt == "[" then
                        local csi = read_csi(tty)
                        if not csi then break end
                        if csi == "I" then
                            -- Track focus regain cleanly; ignore nothing.
                        elseif csi == "O" then
                            if opts.close_on_blur ~= false then
                                break
                            end
                        elseif csi:sub(1, 1) == "<" then
                            local btn_s, col_s, row_s, kind = csi:match("^<(%d+);(%d+);(%d+)([Mm])$")
                            local btn = tonumber(btn_s)
                            local col = tonumber(col_s)
                            local row = tonumber(row_s)
                            if btn and col and row then
                                if kind == "m" and (btn == 0 or btn == 32) then
                                    active_drag_hb = nil
                                elseif btn == 0 and kind == "M" then
                                    active_drag_hb = nil
                                    for i = #ui.hitboxes, 1, -1 do
                                        local hb = ui.hitboxes[i]
                                        if row >= hb.r1 and row <= hb.r2 and col >= hb.c1 and col <= hb.c2 then
                                            if hb.drag then
                                                active_drag_hb = hb
                                            end
                                            if hb.click then
                                                local res = hb.click(col - hb.c1, row - hb.r1)
                                                if res == "close" then return end
                                                if type(res) == "table" and res.exec_and_close then
                                                    post_exit_cmd = res.exec_and_close
                                                    return
                                                end
                                                redraw()
                                            end
                                            break
                                        end
                                    end
                                elseif btn == 2 and kind == "M" then
                                    active_drag_hb = nil
                                    for i = #ui.hitboxes, 1, -1 do
                                        local hb = ui.hitboxes[i]
                                        if row >= hb.r1 and row <= hb.r2 and col >= hb.c1 and col <= hb.c2 and hb.right_click then
                                            local res = hb.right_click(col - hb.c1, row - hb.r1)
                                            if res == "close" then return end
                                            if type(res) == "table" and res.exec_and_close then
                                                post_exit_cmd = res.exec_and_close
                                                return
                                            end
                                            redraw()
                                            break
                                        end
                                    end
                                elseif btn == 32 and kind == "M" and active_drag_hb and active_drag_hb.drag then
                                    active_drag_hb.drag(col - active_drag_hb.c1)
                                    redraw()
                                elseif (btn == 64 or btn == 65) and kind == "M" then
                                    local dir = (btn == 64) and 1 or -1
                                    local handled = false
                                    for i = #ui.hitboxes, 1, -1 do
                                        local hb = ui.hitboxes[i]
                                        if row >= hb.r1 and row <= hb.r2 and col >= hb.c1 and col <= hb.c2 and hb.scroll then
                                            hb.scroll(dir)
                                            handled = true
                                            redraw()
                                            break
                                        end
                                    end
                                    if not handled and opts.on_scroll then
                                        opts.on_scroll(dir)
                                        redraw()
                                    end
                                end
                            end
                        elseif opts.on_key then
                            local res = opts.on_key("CSI:" .. csi)
                            if res == "close" then break end
                            if type(res) == "table" and res.exec_and_close then
                                post_exit_cmd = res.exec_and_close
                                break
                            end
                            if res == "redraw" then redraw() end
                        end
                    end
                elseif opts.on_key then
                    local res = opts.on_key(ch)
                    if res == "close" then break end
                    if type(res) == "table" and res.exec_and_close then
                        post_exit_cmd = res.exec_and_close
                        break
                    end
                    if res == "redraw" then redraw() end
                end
            end
        end
    end)

    io.stdout:write("\27[?1004l\27[?1006l\27[?1002l\27[?1000l\27[?25h\27[?1049l\27[0m")
    io.stdout:flush()
    if saved_stty and saved_stty ~= "" then
        os.execute("stty " .. fs.shell_quote(saved_stty) .. " </dev/tty 2>/dev/null")
    else
        os.execute("stty sane </dev/tty 2>/dev/null")
    end
    tty:close()

    if post_exit_cmd then
        require("kaze.popups").exec_detached(post_exit_cmd)
    end
    if not ok then
        io.stderr:write("widget error: " .. tostring(err) .. "\n")
        os.exit(1)
    end
end

return M
