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

-- Launch or toggle off a floating footclient widget window.
function M.toggle_or_open(opts)
    local app_id = assert(opts.app_id, "missing app_id")
    local running_fuzzel = os.execute("pgrep -x fuzzel >/dev/null 2>&1")
    if running_fuzzel == true or running_fuzzel == 0 then
        os.execute("pkill -x fuzzel >/dev/null 2>&1 || true")
    end

    local hypr_sig = os.getenv("HYPRLAND_INSTANCE_SIGNATURE")
    if hypr_sig and hypr_sig ~= "" and fs.command_exists("hyprctl") then
        local raw = fs.capture("hyprctl -j clients 2>/dev/null")
        local ok, clients = pcall(json.decode, raw or "")
        if ok and type(clients) == "table" then
            local closed_self = false
            for _, c in ipairs(clients) do
                if type(c) == "table" and type(c.class) == "string" and type(c.address) == "string" then
                    local addr = c.address:gsub("^0x", "")
                    if addr:match("^[0-9a-fA-F]+$") then
                        if c.class == app_id then
                            local expr = string.format("hl.dsp.window.close({ window = 'address:0x%s' })", addr)
                            os.execute("hyprctl dispatch " .. fs.shell_quote(expr) .. " >/dev/null 2>&1")
                            closed_self = true
                        elseif c.class:match("^kaze%-widget%-") then
                            local expr = string.format("hl.dsp.window.close({ window = 'address:0x%s' })", addr)
                            os.execute("hyprctl dispatch " .. fs.shell_quote(expr) .. " >/dev/null 2>&1")
                        end
                    end
                end
            end
            if closed_self then
                return false
            end
        end
    end

    local foot_bin = opts.foot_bin or "kaze-footclient"
    local bg_alt = (opts.theme and opts.theme.bg_alt) or "181b22"
    local cmd = string.format(
        "%s -N -o main.locked-title=yes -o 'main.pad=14x12 center' -o 'text-bindings.\\x04=Escape'"
            .. " -o colors-dark.background=%s -o colors-dark.alpha=0.94"
            .. " -W %dx%d -a %s -T %s %s --ui",
        fs.shell_quote(foot_bin),
        fs.shell_quote(bg_alt),
        tonumber(opts.cols) or 38,
        tonumber(opts.rows) or 16,
        fs.shell_quote(app_id),
        fs.shell_quote(opts.title or app_id),
        fs.shell_quote(opts.script_path)
    )
    local ok = os.execute(cmd)
    return ok == true or ok == 0
end

local function create_canvas(cols, rows, base_bg, base_fg)
    local canvas = {
        cols = cols,
        rows = rows,
        base_bg = base_bg,
        base_fg = base_fg,
        buf = {},
        hitboxes = {},
    }

    function canvas:begin_frame(bg_hex, fg_hex)
        if bg_hex then self.base_bg = bg_hex end
        if fg_hex then self.base_fg = fg_hex end
        self.hitboxes = {}
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
        self.buf[#self.buf + 1] = string.format(
            "\27[%d;%dH%s%s%s",
            row,
            col,
            M.style(fg_hex or self.base_fg, bg_hex or self.base_bg, bold),
            text,
            M.style(self.base_fg, self.base_bg, false)
        )
    end

    function canvas:rule(row, col, width, color_hex)
        self:put(row, col, string.rep("─", width), color_hex or self.base_fg, self.base_bg, false)
    end

    function canvas:pill(row, col, label, fg_hex, bg_hex, bold, on_click)
        self:put(row, col, label, fg_hex, bg_hex, bold)
        local vis_w = tonumber(utf8.len(label)) or #label
        if on_click then
            self:hitbox(row, col, row, col + vis_w - 1, { click = on_click })
        end
        return vis_w
    end

    function canvas:tile(row, col, width, line1, line2, active, theme, on_click)
        local fill = active and theme.accent or theme.surface
        local txt1 = active and theme.accent_fg or theme.fg
        local txt2 = active and theme.accent_fg or theme.fg_muted
        local function pad_cell(s)
            local len = tonumber(utf8.len(s)) or #s
            if len > width - 2 then
                -- Truncate cleanly by UTF-8 characters
                local out = {}
                local count = 0
                for _, code in utf8.codes(s) do
                    count = count + 1
                    if count > width - 3 then break end
                    out[#out + 1] = utf8.char(code)
                end
                s = table.concat(out) .. "…"
                len = width - 2
            end
            return " " .. s .. string.rep(" ", math.max(0, width - 2 - len)) .. " "
        end
        self:put(row, col, pad_cell(line1), txt1, fill, true)
        self:put(row + 1, col, pad_cell(line2), txt2, fill, false)
        if on_click then
            self:hitbox(row, col, row + 1, col + width - 1, { click = on_click })
        end
    end

    function canvas:slider(row, col, bar_w, pct, muted, theme, handlers)
        local clamped = math.max(0, math.min(100, math.floor((tonumber(pct) or 0) + 0.5)))
        local knob_pos = math.floor((clamped / 100) * (bar_w - 1) + 0.5)
        local active_col = muted and theme.fg_muted or theme.accent
        local track_col = theme.surface
        for i = 0, bar_w - 1 do
            if i == knob_pos then
                self:put(row, col + i, "●", muted and theme.danger or theme.fg, self.base_bg, true)
            elseif i < knob_pos then
                self:put(row, col + i, "━", active_col, self.base_bg, true)
            else
                self:put(row, col + i, "━", track_col, self.base_bg, false)
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
            drag = handlers.drag,
            scroll = handlers.scroll,
        }
    end

    function canvas:flush()
        self.buf[#self.buf + 1] = "\27[?2026l"
        io.stdout:write(table.concat(self.buf))
        io.stdout:flush()
    end

    return canvas
end

local function read_csi(tty)
    local seq = {}
    while true do
        local ch = tty:read(1)
        if not ch then return nil end
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
    os.execute("stty -icanon -echo -isig min 1 time 0 </dev/tty 2>/dev/null")

    -- Enter alt screen, hide cursor, enable mouse click + drag + SGR + FocusIn/Out
    io.stdout:write("\27[?1049h\27[?25l\27[?1000h\27[?1002h\27[?1006h\27[?1004h")
    io.stdout:flush()

    local post_exit_cmd = nil
    local ok, err = pcall(function()
        local ui = create_canvas(opts.cols, opts.rows, opts.theme.bg_alt, opts.theme.fg)
        local seen_focus_in = false
        local active_drag_hb = nil

        local function redraw()
            opts.render(ui)
            ui:flush()
        end

        redraw()

        while true do
            local ch = tty:read(1)
            if not ch then break end
            local byte = ch:byte()
            if byte == 4 or byte == 3 or ch == "q" or ch == "Q" then
                break
            elseif ch == "\27" then
                local nxt = tty:read(1)
                if not nxt then break end
                if nxt == "[" then
                    local csi = read_csi(tty)
                    if not csi then break end
                    if csi == "I" then
                        seen_focus_in = true
                    elseif csi == "O" then
                        if seen_focus_in then
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
