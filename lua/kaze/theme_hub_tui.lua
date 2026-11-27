-- Pure-Lua 2-column visual Theme Hub with TrueColor mini-desktop illustrations,
-- live desktop preview, instant Esc atomic rollback, and keyboard + SGR-1006 mouse UI.
-- Zero external dependencies beyond Lua 5.5 stdlib + Foot + Noctalia + Hyprland.

local fs = require("kaze.fs")
local json = require("kaze.json")
local styles = require("kaze.styles")

local M = {}

local ESC = "\27"

-- Authentic dark/light hex palettes for Noctalia's 8 built-in themes.
-- Custom palettes (~/.config/noctalia/palettes/*.json) are parsed live from disk.
M.BUILTIN_PALETTES = {
    Kanagawa = {
        dark  = { bg = "#1f1f28", bar = "#16161d", card = "#2a2a37", border = "#54546d", fg = "#dcd7ba", muted = "#727169", pri = "#7e9cd8", sec = "#957fb8", ter = "#76946a", err = "#c34043" },
        light = { bg = "#f2ecbc", bar = "#e7dba0", card = "#e5ddb0", border = "#b5a97c", fg = "#545464", muted = "#8a8980", pri = "#4d699b", sec = "#624c83", ter = "#6f894e", err = "#c84053" },
    },
    ["Tokyo-Night"] = {
        dark  = { bg = "#1a1b26", bar = "#16161e", card = "#24283b", border = "#414868", fg = "#c0caf5", muted = "#565f89", pri = "#7aa2f7", sec = "#bb9af7", ter = "#7dcfff", err = "#f7768e" },
        light = { bg = "#d5d6db", bar = "#cbccd1", card = "#e1e2e7", border = "#9699a3", fg = "#343b58", muted = "#6c6e75", pri = "#34548a", sec = "#5a4a78", ter = "#0f4b6e", err = "#8c4351" },
    },
    Catppuccin = {
        dark  = { bg = "#1e1e2e", bar = "#181825", card = "#313244", border = "#585b70", fg = "#cdd6f4", muted = "#7f849c", pri = "#cba6f7", sec = "#89b4fa", ter = "#94e2d5", err = "#f38ba8" },
        light = { bg = "#eff1f5", bar = "#e6e9ef", card = "#dce0e8", border = "#acb0be", fg = "#4c4f69", muted = "#7c7f93", pri = "#8839ef", sec = "#1e66f5", ter = "#179299", err = "#d20f39" },
    },
    Dracula = {
        dark  = { bg = "#282a36", bar = "#21222c", card = "#343746", border = "#6272a4", fg = "#f8f8f2", muted = "#6272a4", pri = "#bd93f9", sec = "#ff79c6", ter = "#8be9fd", err = "#ff5555" },
        light = { bg = "#f8f8f2", bar = "#ecece4", card = "#e2e2d8", border = "#9ca4c4", fg = "#282a36", muted = "#6272a4", pri = "#7c4dff", sec = "#d63384", ter = "#0097a7", err = "#d32f2f" },
    },
    Eldritch = {
        dark  = { bg = "#212337", bar = "#171928", card = "#292e42", border = "#50567a", fg = "#ebfafa", muted = "#7081d0", pri = "#37f499", sec = "#a48cf2", ter = "#04d1f9", err = "#f16c75" },
        light = { bg = "#eef6f6", bar = "#dfeaea", card = "#d6e4e4", border = "#8da3b0", fg = "#212337", muted = "#54658c", pri = "#14995c", sec = "#6c52c7", ter = "#0087a8", err = "#c93b47" },
    },
    Gruvbox = {
        dark  = { bg = "#282828", bar = "#1d2021", card = "#3c3836", border = "#665c54", fg = "#ebdbb2", muted = "#928374", pri = "#fabd2f", sec = "#fe8019", ter = "#8ec07c", err = "#fb4934" },
        light = { bg = "#fbf1c7", bar = "#f2e5bc", card = "#ebdbb2", border = "#a89984", fg = "#3c3836", muted = "#7c6f64", pri = "#b57614", sec = "#af3a03", ter = "#427b58", err = "#9d0006" },
    },
    Nord = {
        dark  = { bg = "#2e3440", bar = "#242933", card = "#3b4252", border = "#4c566a", fg = "#eceff4", muted = "#7b88a1", pri = "#88c0d0", sec = "#81a1c1", ter = "#a3be8c", err = "#bf616a" },
        light = { bg = "#eceff4", bar = "#e5e9f0", card = "#d8dee9", border = "#9aa5b8", fg = "#2e3440", muted = "#4c566a", pri = "#5e81ac", sec = "#4c6a92", ter = "#5f8554", err = "#bf616a" },
    },
    Pine = {
        dark  = { bg = "#191724", bar = "#1f1d2e", card = "#26233a", border = "#524f67", fg = "#e0def4", muted = "#908caa", pri = "#ebbcba", sec = "#c4a7e7", ter = "#9ccfd8", err = "#eb6f92" },
        light = { bg = "#faf4ed", bar = "#f2e9e1", card = "#fffaf3", border = "#cecacd", fg = "#575279", muted = "#797593", pri = "#d7827e", sec = "#907aa9", ter = "#56949f", err = "#b4637a" },
    },
}

local FALLBACK_DARK = M.BUILTIN_PALETTES.Kanagawa.dark
local FALLBACK_LIGHT = M.BUILTIN_PALETTES.Kanagawa.light

local STYLE_FALLBACK_PALETTES = {
    ["swiss-grid"] = { bg = "#f5f2eb", bar = "#eae5da", card = "#ffffff", border = "#2c2a26", fg = "#1e1d1a", muted = "#6e6a61", pri = "#c83e2b", sec = "#3a3833", ter = "#4f6d7a", err = "#b8292f" },
    ["tui-hacker"] = { bg = "#070c08", bar = "#0c140e", card = "#0d1a10", border = "#1f6e38", fg = "#33ff66", muted = "#1e8f3d", pri = "#33ff66", sec = "#17c94a", ter = "#66ff99", err = "#ff5555" },
    ["retro-90s"]  = { bg = "#c0c0c0", bar = "#d4d0c8", card = "#ffffff", border = "#404040", fg = "#101010", muted = "#585858", pri = "#000080", sec = "#008080", ter = "#808000", err = "#a80000" },
}

local function hex_to_rgb(hex)
    if type(hex) ~= "string" then
        return nil
    end
    local r, g, b = hex:match("^#?(%x%x)(%x%x)(%x%x)$")
    if not r then
        return nil
    end
    return tonumber(r, 16), tonumber(g, 16), tonumber(b, 16)
end

local function fg_hex(hex)
    local r, g, b = hex_to_rgb(hex)
    if not r then return "" end
    return string.format("%s[38;2;%d;%d;%dm", ESC, r, g, b)
end

local function bg_hex(hex)
    local r, g, b = hex_to_rgb(hex)
    if not r then return "" end
    return string.format("%s[48;2;%d;%d;%dm", ESC, r, g, b)
end

local RST = ESC .. "[0m"
local BOLD = ESC .. "[1m"
local DIM = ESC .. "[2m"

function M.strip_ansi(s)
    return (tostring(s or ""):gsub("\27%[[0-9;?]*[A-Za-z]", ""))
end

function M.display_width(s)
    local plain = M.strip_ansi(s)
    local n = utf8.len(plain)
    return n or #plain
end

function M.clip_utf8(s, max_cols)
    s = tostring(s or "")
    if max_cols <= 0 then return "" end
    local len = utf8.len(s)
    if not len then
        return #s <= max_cols and s or s:sub(1, max_cols)
    end
    if len <= max_cols then return s end
    if max_cols == 1 then
        local off = utf8.offset(s, 2)
        return off and s:sub(1, off - 1) or s:sub(1, 1)
    end
    local off = utf8.offset(s, max_cols)
    return (off and s:sub(1, off - 1) or s) .. "…"
end

local function pad_right(s, width)
    local w = M.display_width(s)
    if w >= width then
        return s
    end
    return s .. string.rep(" ", width - w)
end

local function fit_plain(s, width)
    local clipped = M.clip_utf8(s, width)
    local w = utf8.len(clipped) or #clipped
    if w < width then
        return clipped .. string.rep(" ", width - w)
    end
    return clipped
end

function M.load_palette_colors(theme_id, mode, opts, fallback)
    opts = opts or {}
    mode = (mode == "light") and "light" or "dark"
    if theme_id == "wallpaper" then
        if mode == "light" then
            return { bg = "#f4efe6", bar = "#e8dfd1", card = "#fbf8f3", border = "#c2b59e", fg = "#2a2723", muted = "#70685c", pri = "#3b6e8c", sec = "#9a5b4a", ter = "#5c7d5e", err = "#b84444" }
        end
        return { bg = "#1b2029", bar = "#141820", card = "#242b38", border = "#465269", fg = "#e6ecf5", muted = "#8896ad", pri = "#6eb5ff", sec = "#d99b66", ter = "#78c99a", err = "#e06c75" }
    end

    local b = M.BUILTIN_PALETTES[theme_id]
    if b and b[mode] then
        return b[mode]
    end

    local pal_dir = opts.palettes_dir or (fs.config_dir() .. "/noctalia/palettes")
    local raw = fs.read_file(pal_dir .. "/" .. tostring(theme_id) .. ".json")
    if raw then
        local ok, dec = pcall(json.decode, raw)
        if ok and type(dec) == "table" then
            local sec = type(dec[mode]) == "table" and dec[mode] or (type(dec.dark) == "table" and dec.dark or nil)
            if sec then
                local fb = fallback or (mode == "light" and FALLBACK_LIGHT or FALLBACK_DARK)
                return {
                    bg     = sec.surface or fb.bg,
                    bar    = sec.surface_container or sec.surface or fb.bar,
                    card   = sec.surface_variant or sec.surface_container or fb.card,
                    border = sec.outline_variant or sec.outline or fb.border,
                    fg     = sec.on_surface or fb.fg,
                    muted  = sec.on_surface_variant or fb.muted,
                    pri    = sec.primary or fb.pri,
                    sec    = sec.secondary or fb.sec,
                    ter    = sec.tertiary or fb.ter,
                    err    = sec.error or fb.err,
                }
            end
        end
    end

    return fallback or (mode == "light" and FALLBACK_LIGHT or FALLBACK_DARK)
end

-- Helper to paint a single miniature monitor line with exact width `w`,
-- painting background `bg` across the full monitor row.
local function paint_screen_line(bg, segments, w)
    local out = { bg_hex(bg) }
    local used = 0
    for _, seg in ipairs(segments) do
        local text = seg[1]
        local col = seg[2]
        local seg_bg = seg[3]
        local remain = w - used
        if remain <= 0 then break end
        local clipped = M.clip_utf8(text, remain)
        local cw = utf8.len(clipped) or #clipped
        if seg_bg then out[#out + 1] = bg_hex(seg_bg) end
        if col then out[#out + 1] = fg_hex(col) end
        out[#out + 1] = clipped
        if seg_bg then out[#out + 1] = bg_hex(bg) end
        used = used + cw
    end
    if used < w then
        out[#out + 1] = string.rep(" ", w - used)
    end
    out[#out + 1] = RST
    return table.concat(out)
end

-- Build 6-row bespoke TrueColor mini-desktop wireframe illustration for each of the 11 visual styles.
function M.render_style_illustration(style_id, sw, pal, opts)
    local p = STYLE_FALLBACK_PALETTES[style_id] or pal
    if style_id == "swiss-grid" then
        p = M.load_palette_colors("Kaze-Swiss", "light", opts, STYLE_FALLBACK_PALETTES["swiss-grid"])
    elseif style_id == "tui-hacker" then
        p = M.load_palette_colors("Kaze-Phosphor", "dark", opts, STYLE_FALLBACK_PALETTES["tui-hacker"])
    elseif style_id == "retro-90s" then
        p = M.load_palette_colors("Kaze-Retro90s", "light", opts, STYLE_FALLBACK_PALETTES["retro-90s"])
    end

    local half = math.max(8, math.floor((sw - 3) / 2))
    local right_w = math.max(8, sw - half - 3)
    local lfill = string.rep("─", math.max(0, half - 2))
    local rfill = string.rep("─", math.max(0, right_w - 2))

    if style_id == "dynamic-island" then
        local gap1 = math.max(1, math.floor((sw - 25) / 2))
        local gap2 = math.max(1, sw - 25 - gap1)
        return {
            paint_screen_line(p.bg, {
                { " ", p.bg },
                { " ●·· ", p.pri, p.bar },
                { string.rep(" ", gap1) },
                { " 12:34 ◆ ● ", p.fg, p.bar },
                { string.rep(" ", gap2) },
                { " ≡ ▮ ⏻ ", p.muted, p.bar },
                { " ", p.bg },
            }, sw),
            paint_screen_line(p.bg, {
                { " ╭" .. lfill .. "╮ ╭" .. rfill .. "╮", p.pri },
            }, sw),
            paint_screen_line(p.bg, {
                { " │", p.pri }, { fit_plain(" ▄▀█ arch", half - 2), p.fg, p.card }, { "│ │", p.border }, { fit_plain(" cpu ▂▃▅▂", right_w - 2), p.ter, p.card }, { "│", p.border },
            }, sw),
            paint_screen_line(p.bg, {
                { " │", p.pri }, { fit_plain(" ▀ ▀ hypr", half - 2), p.sec, p.card }, { "│ │", p.border }, { fit_plain(" mem ███░", right_w - 2), p.pri, p.card }, { "│", p.border },
            }, sw),
            paint_screen_line(p.bg, {
                { " ╰" .. lfill .. "╯ ╰" .. rfill .. "╯", p.border },
            }, sw),
            paint_screen_line(p.bg, {
                { "  ┄┄ ", p.muted }, { "●", p.pri }, { " ", p.bg }, { "●", p.sec }, { " ", p.bg }, { "●", p.ter }, { " ", p.bg }, { "3-cluster floating pills", p.muted },
            }, sw),
        }
    elseif style_id == "omarchy-rail" then
        local w1 = math.max(7, math.floor((sw - 6) / 2))
        local w2 = math.max(7, sw - w1 - 6)
        return {
            paint_screen_line(p.bg, {
                { "█", p.pri, p.bar }, { "1", p.fg, p.pri }, { "│", p.border }, { " ┌" .. string.rep("─", w1 - 2) .. "┐ ┌" .. string.rep("─", w2 - 2) .. "┐", p.pri },
            }, sw),
            paint_screen_line(p.bg, {
                { " 2", p.muted, p.bar }, { "│", p.border }, { " │", p.pri }, { fit_plain(" ▄▀█ zsh", w1 - 2), p.fg, p.card }, { "│ │", p.border }, { fit_plain(" ▂▄▆▃", w2 - 2), p.ter, p.card }, { "│", p.border },
            }, sw),
            paint_screen_line(p.bg, {
                { "12", p.fg, p.bar }, { "│", p.border }, { " │", p.pri }, { fit_plain(" ▀ ▀ 0px", w1 - 2), p.sec, p.card }, { "│ │", p.border }, { fit_plain(" ███░", w2 - 2), p.pri, p.card }, { "│", p.border },
            }, sw),
            paint_screen_line(p.bg, {
                { "34", p.muted, p.bar }, { "│", p.border }, { " │", p.pri }, { fit_plain(" sharp", w1 - 2), p.muted, p.card }, { "│ │", p.border }, { fit_plain(" btop", w2 - 2), p.muted, p.card }, { "│", p.border },
            }, sw),
            paint_screen_line(p.bg, {
                { "◆●", p.pri, p.bar }, { "│", p.border }, { " └" .. string.rep("─", w1 - 2) .. "┘ └" .. string.rep("─", w2 - 2) .. "┘", p.border },
            }, sw),
            paint_screen_line(p.bg, {
                { "⏻ ", p.muted, p.bar }, { "│", p.border }, { "  42px left rail · 0px flat", p.muted },
            }, sw),
        }
    elseif style_id == "swiss-grid" then
        local sw1 = math.max(7, math.floor((sw - 6) / 2))
        local sw2 = math.max(7, sw - 6 - sw1)
        return {
            paint_screen_line(p.bar, {
                { " 1 / 2 / 3", p.fg, p.bar }, { string.rep(" ", math.max(1, sw - 26)), p.bar, p.bar }, { "12:34  —  THEME ", p.pri, p.bar },
            }, sw),
            paint_screen_line(p.bg, {
                { string.rep("─", sw), p.border },
            }, sw),
            paint_screen_line(p.bg, {
                { "  ┌" .. string.rep("─", sw1 - 2) .. "┐  ┌" .. string.rep("─", sw2 - 2) .. "┐", p.border },
            }, sw),
            paint_screen_line(p.bg, {
                { "  │", p.border }, { fit_plain(" Swiss 1px", sw1 - 2), p.fg, p.card }, { "│  │", p.border }, { fit_plain(" Paper", sw2 - 2), p.muted, p.card }, { "│", p.border },
            }, sw),
            paint_screen_line(p.bg, {
                { "  └" .. string.rep("─", sw1 - 2) .. "┘  └" .. string.rep("─", sw2 - 2) .. "┘", p.border },
            }, sw),
            paint_screen_line(p.bg, {
                { "  Kaze-Swiss light · hairline grid", p.muted },
            }, sw),
        }
    elseif style_id == "corner-hud" then
        local mid_gap = math.max(2, sw - 20)
        return {
            paint_screen_line(p.bg, {
                { " ", p.bg }, { " 1 2 3 ", p.pri, p.bar }, { string.rep(" ", mid_gap) }, { " ◆ ● 12:34 ", p.fg, p.bar }, { " ", p.bg },
            }, sw),
            paint_screen_line(p.bg, {
                { " ╭" .. lfill .. "╮ ╭" .. rfill .. "╮", p.pri },
            }, sw),
            paint_screen_line(p.bg, {
                { " │", p.pri }, { fit_plain(" open", half - 2), p.fg, p.card }, { "│ │", p.border }, { fit_plain(" cpu ▂▃▅", right_w - 2), p.ter, p.card }, { "│", p.border },
            }, sw),
            paint_screen_line(p.bg, {
                { " │", p.pri }, { fit_plain(" horizon", half - 2), p.sec, p.card }, { "│ │", p.border }, { fit_plain(" mem ██░", right_w - 2), p.pri, p.card }, { "│", p.border },
            }, sw),
            paint_screen_line(p.bg, {
                { " ╰" .. lfill .. "╯ ╰" .. rfill .. "╯", p.border },
            }, sw),
            paint_screen_line(p.bg, {
                { "  2 corner pods · empty center top", p.muted },
            }, sw),
        }
    elseif style_id == "ghost-zero" then
        local w_in = sw - 2
        local lbl = " hold Super peek "
        local ldash = math.max(0, math.floor((sw - #lbl) / 2))
        local rdash = math.max(0, sw - #lbl - ldash)
        return {
            paint_screen_line(p.bg, {
                { string.rep("┄", ldash), p.muted },
                { lbl, p.pri },
                { string.rep("┄", rdash), p.muted },
            }, sw),
            paint_screen_line(p.card, {
                { "│", p.pri, p.card }, { fit_plain("  ▄▀█  0px gaps · edge-to-edge", w_in), p.fg, p.card }, { "│", p.pri, p.card },
            }, sw),
            paint_screen_line(p.card, {
                { "│", p.pri, p.card }, { fit_plain("  ▀ ▀  auto-hide bar · 100% focus", w_in), p.sec, p.card }, { "│", p.pri, p.card },
            }, sw),
            paint_screen_line(p.card, {
                { "│", p.pri, p.card }, { fit_plain("  ● ● ● ● ●  zero chrome canvas", w_in), p.ter, p.card }, { "│", p.pri, p.card },
            }, sw),
            paint_screen_line(p.card, {
                { "│", p.pri, p.card }, { string.rep(" ", w_in), p.card, p.card }, { "│", p.pri, p.card },
            }, sw),
            paint_screen_line(p.card, {
                { "└" .. string.rep("─", w_in) .. "┘", p.pri, p.card },
            }, sw),
        }
    elseif style_id == "hardware-notch" then
        local notch_w = 19
        local side = math.max(1, math.floor((sw - notch_w) / 2))
        return {
            paint_screen_line(p.bg, {
                { string.rep(" ", side) }, { "╰", p.bar }, { " ●··  12:34  ◆ ● ", p.fg, p.bar }, { "╯", p.bar },
            }, sw),
            paint_screen_line(p.bg, {
                { " ╭" .. lfill .. "╮ ╭" .. rfill .. "╮", p.pri },
            }, sw),
            paint_screen_line(p.bg, {
                { " │", p.pri }, { fit_plain(" concave", half - 2), p.fg, p.card }, { "│ │", p.border }, { fit_plain(" cpu ▂▄▆", right_w - 2), p.ter, p.card }, { "│", p.border },
            }, sw),
            paint_screen_line(p.bg, {
                { " │", p.pri }, { fit_plain(" notch", half - 2), p.sec, p.card }, { "│ │", p.border }, { fit_plain(" mem ██░", right_w - 2), p.pri, p.card }, { "│", p.border },
            }, sw),
            paint_screen_line(p.bg, {
                { " ╰" .. lfill .. "╯ ╰" .. rfill .. "╯", p.border },
            }, sw),
            paint_screen_line(p.bg, {
                { "  flush top notch · concave corners", p.muted },
            }, sw),
        }
    elseif style_id == "glass-studio" then
        local dock_s = " ╭─ ▪ ▪ ▪ ▪ ─╮ "
        local dock_pad = math.max(0, math.floor((sw - 15) / 2))
        local inner_win = math.max(12, sw - 6)
        return {
            paint_screen_line(p.bar, {
                { " ░ foot", p.fg, p.bar }, { string.rep(" ", math.max(1, sw - 20)), p.bar, p.bar }, { "12:34  ◆ ● ░ ", p.pri, p.bar },
            }, sw),
            paint_screen_line(p.bg, {
                { "   ╭" .. string.rep("─", inner_win - 2) .. "╮", p.pri },
            }, sw),
            paint_screen_line(p.bg, {
                { "   │", p.pri }, { fit_plain("  frosted glass · 14px blur", inner_win - 2), p.fg, p.card }, { "│", p.pri },
            }, sw),
            paint_screen_line(p.bg, {
                { "   ╰" .. string.rep("─", inner_win - 2) .. "╯", p.border },
            }, sw),
            paint_screen_line(p.bg, {
                { string.rep(" ", dock_pad) }, { dock_s, p.pri, p.bar },
            }, sw),
            paint_screen_line(p.bg, {
                { "  28px glass menu + auto-hide dock", p.muted },
            }, sw),
        }
    elseif style_id == "floating-rail" then
        local top_s = " foot · 12:34 ◆ ● "
        local tpad = math.max(1, math.floor((sw - 20) / 2))
        local rw = math.max(7, math.floor((sw - 7) / 2))
        local rw2 = math.max(7, sw - rw - 7)
        return {
            paint_screen_line(p.bg, {
                { string.rep(" ", tpad) }, { "╭", p.border }, { top_s, p.fg, p.bar }, { "╮", p.border },
            }, sw),
            paint_screen_line(p.bg, {
                { " ╭─╮", p.border }, { " ╭" .. string.rep("─", rw - 2) .. "╮ ╭" .. string.rep("─", rw2 - 2) .. "╮", p.pri },
            }, sw),
            paint_screen_line(p.bg, {
                { " │", p.border }, { "1", p.pri, p.bar }, { "│", p.border },
                { " │", p.pri }, { fit_plain(" dual", rw - 2), p.fg, p.card }, { "│ │", p.border }, { fit_plain(" ▂▃▅", rw2 - 2), p.ter, p.card }, { "│", p.border },
            }, sw),
            paint_screen_line(p.bg, {
                { " │", p.border }, { "2", p.muted, p.bar }, { "│", p.border },
                { " │", p.pri }, { fit_plain(" pill", rw - 2), p.sec, p.card }, { "│ │", p.border }, { fit_plain(" ██░", rw2 - 2), p.pri, p.card }, { "│", p.border },
            }, sw),
            paint_screen_line(p.bg, {
                { " ╰─╯", p.border }, { " ╰" .. string.rep("─", rw - 2) .. "╯ ╰" .. string.rep("─", rw2 - 2) .. "╯", p.border },
            }, sw),
            paint_screen_line(p.bg, {
                { "  top status pill + left app rail", p.muted },
            }, sw),
        }
    elseif style_id == "tui-hacker" then
        return {
            paint_screen_line(p.bar, {
                { " [WS 1 2 3]", p.pri, p.bar }, { string.rep(" ", math.max(1, sw - 27)), p.bar, p.bar }, { "[12:34] [THEME] ", p.pri, p.bar },
            }, sw),
            paint_screen_line(p.bg, {
                { " ┌" .. lfill .. "┐ ┌" .. rfill .. "┐", p.border },
            }, sw),
            paint_screen_line(p.bg, {
                { " │", p.border }, { fit_plain(" >_ crt", half - 2), p.pri, p.card }, { "│ │", p.border }, { fit_plain(" [OK] 0%", right_w - 2), p.ter, p.card }, { "│", p.border },
            }, sw),
            paint_screen_line(p.bg, {
                { " │", p.border }, { fit_plain(" phosphor", half - 2), p.muted, p.card }, { "│ │", p.border }, { fit_plain(" ████░░", right_w - 2), p.pri, p.card }, { "│", p.border },
            }, sw),
            paint_screen_line(p.bg, {
                { " └" .. lfill .. "┘ └" .. rfill .. "┘", p.border },
            }, sw),
            paint_screen_line(p.bg, {
                { "  Kaze-Phosphor · bracketed TUI", p.muted },
            }, sw),
        }
    elseif style_id == "retro-90s" then
        return {
            paint_screen_line(p.bg, {
                { " ┌" .. lfill .. "┐ ┌" .. rfill .. "┐", p.border },
            }, sw),
            paint_screen_line(p.bg, {
                { " │", p.border }, { fit_plain(" Bevel 3D", half - 2), p.fg, p.card }, { "│ │", p.border }, { fit_plain(" Win95", right_w - 2), p.pri, p.card }, { "│", p.border },
            }, sw),
            paint_screen_line(p.bg, {
                { " │", p.border }, { fit_plain(" 45deg", half - 2), p.muted, p.card }, { "│ │", p.border }, { fit_plain(" classic", right_w - 2), p.muted, p.card }, { "│", p.border },
            }, sw),
            paint_screen_line(p.bg, {
                { " └" .. lfill .. "┘ └" .. rfill .. "┘", p.border },
            }, sw),
            paint_screen_line(p.bg, {
                { string.rep("═", sw), p.border },
            }, sw),
            paint_screen_line(p.bar, {
                { " [Start]", p.fg, p.bar }, { " [1]", p.card, p.pri }, { " [2]", p.fg, p.bar },
                { string.rep(" ", math.max(1, sw - 24)), p.bar, p.bar }, { "◆ 12:34 ", p.fg, p.bar },
            }, sw),
        }
    else -- cinema-frame
        local cw = math.max(8, math.floor((sw - 8) / 2))
        local cw2 = math.max(8, sw - cw - 8)
        local cgap1 = math.max(1, math.floor((sw - 18) / 2))
        local cgap2 = math.max(1, sw - 18 - cgap1)
        return {
            paint_screen_line(p.bg, {
                { "   ┌" .. string.rep("─", cw - 2) .. "┐  ┌" .. string.rep("─", cw2 - 2) .. "┐", p.border },
            }, sw),
            paint_screen_line(p.bg, {
                { "   │", p.border }, { fit_plain(" 28px", cw - 2), p.fg, p.card }, { "│  │", p.border }, { fit_plain(" gallery", cw2 - 2), p.sec, p.card }, { "│", p.border },
            }, sw),
            paint_screen_line(p.bg, {
                { "   │", p.border }, { fit_plain(" frame", cw - 2), p.muted, p.card }, { "│  │", p.border }, { fit_plain(" wide", cw2 - 2), p.ter, p.card }, { "│", p.border },
            }, sw),
            paint_screen_line(p.bg, {
                { "   └" .. string.rep("─", cw - 2) .. "┘  └" .. string.rep("─", cw2 - 2) .. "┘", p.border },
            }, sw),
            paint_screen_line(p.bg, {
                { "   ", p.bg },
            }, sw),
            paint_screen_line(p.bar, {
                { " 1 · 2", p.muted, p.bar }, { string.rep(" ", cgap1), p.bar, p.bar },
                { "12:34", p.fg, p.bar }, { string.rep(" ", cgap2), p.bar, p.bar }, { "◆ 100% ", p.pri, p.bar },
            }, sw),
        }
    end
end

-- Build 5-row TrueColor mini-desktop + color-swatch illustration for a Color Palette card.
function M.render_palette_illustration(item, sw, mode, opts)
    local p = M.load_palette_colors(item.id, mode, opts)
    local half = math.max(8, math.floor((sw - 3) / 2))
    local right_w = math.max(8, sw - half - 3)
    local lfill = string.rep("─", math.max(0, half - 2))
    local rfill = string.rep("─", math.max(0, right_w - 2))

    if item.id == "wallpaper" then
        local hues = { "#3b6e8c", "#6eb5ff", "#78c99a", "#d99b66", "#e06c75", "#b48ead" }
        local avail = math.max(6, sw - 2)
        local band_w = math.floor(avail / #hues)
        local rem = avail - band_w * #hues
        local segs = { { " ", p.bg } }
        for idx, h in ipairs(hues) do
            local bw = band_w + (idx <= rem and 1 or 0)
            segs[#segs + 1] = { string.rep("▀", bw), h, p.bar }
        end
        return {
            paint_screen_line(p.bar, {
                { " ●··", p.pri, p.bar }, { string.rep(" ", math.max(1, sw - 15)), p.bar, p.bar }, { "12:34  ◆ ● ", p.fg, p.bar },
            }, sw),
            paint_screen_line(p.bg, segs, sw),
            paint_screen_line(p.bg, {
                { " ╭" .. string.rep("─", math.max(0, sw - 4)) .. "╮", p.pri },
            }, sw),
            paint_screen_line(p.bg, {
                { " │", p.pri }, { fit_plain("  Material 3 dynamic extraction", math.max(0, sw - 4)), p.fg, p.card }, { "│", p.pri },
            }, sw),
            paint_screen_line(p.bg, {
                { " ╰" .. string.rep("─", math.max(0, sw - 4)) .. "╯", p.border },
            }, sw),
        }, p
    end

    local lines = {
        paint_screen_line(p.bar, {
            { " ●··", p.pri, p.bar }, { string.rep(" ", math.max(1, sw - 15)), p.bar, p.bar }, { "12:34  ◆ ● ", p.fg, p.bar },
        }, sw),
        paint_screen_line(p.bg, {
            { " ╭" .. lfill .. "╮ ╭" .. rfill .. "╮", p.pri },
        }, sw),
        paint_screen_line(p.bg, {
            { " │", p.pri }, { fit_plain(" fn main()", half - 2), p.pri, p.card }, { "│ │", p.border }, { fit_plain(" ██ ", 4), p.pri, p.card }, { fit_plain("██ ", 3), p.sec, p.card }, { fit_plain("██", math.max(1, right_w - 9)), p.ter, p.card }, { "│", p.border },
        }, sw),
        paint_screen_line(p.bg, {
            { " │", p.pri }, { fit_plain("  \"kaze\"", half - 2), p.ter, p.card }, { "│ │", p.border }, { fit_plain(" ▂▄▆█ ", 6), p.sec, p.card }, { fit_plain("●", math.max(1, right_w - 8)), p.err, p.card }, { "│", p.border },
        }, sw),
        paint_screen_line(p.bg, {
            { " ╰" .. lfill .. "╯ ╰" .. rfill .. "╯", p.border },
        }, sw),
    }
    return lines, p
end

-- Snapshot current user theme/style files so Esc can atomically revert any live previews.
function M.capture_snapshot(opts)
    opts = opts or {}
    local cfg_path = opts.config_path or (fs.config_dir() .. "/noctalia/config.toml")
    local style_path = styles.state_file(opts)
    local saved_path = styles.theme_backup_file(opts)
    local hypr_path = styles.hypr_style_file(opts)
    local gtk_path = styles.gtk_style_file(opts)
    return {
        config_path = cfg_path,
        config_text = fs.read_file(cfg_path),
        style_path = style_path,
        style_text = fs.read_file(style_path),
        saved_path = saved_path,
        saved_text = fs.read_file(saved_path),
        hypr_path = hypr_path,
        hypr_text = fs.read_file(hypr_path),
        gtk_path = gtk_path,
        gtk_text = fs.read_file(gtk_path),
    }
end

function M.restore_snapshot(snap, opts)
    opts = opts or {}
    if type(snap) ~= "table" then return true end
    local pairs_list = {
        { snap.config_path, snap.config_text },
        { snap.style_path, snap.style_text },
        { snap.saved_path, snap.saved_text },
        { snap.hypr_path, snap.hypr_text },
        { snap.gtk_path, snap.gtk_text },
    }
    for _, item in ipairs(pairs_list) do
        local path, content = item[1], item[2]
        if path then
            if content ~= nil then
                fs.write_atomic(path, content)
            elseif fs.file_exists(path) then
                os.remove(path)
            end
        end
    end
    if opts.reload ~= false then
        if fs.command_exists("noctalia") then
            os.execute("noctalia msg config-reload >/dev/null 2>&1")
            os.execute("noctalia msg templates-apply >/dev/null 2>&1")
        end
        local sig = os.getenv("HYPRLAND_INSTANCE_SIGNATURE")
        if sig and sig ~= "" and fs.command_exists("hyprctl") then
            os.execute("hyprctl reload >/dev/null 2>&1")
        end
    end
    return true
end

function M.build_style_items()
    local items = {}
    for _, grp in ipairs(styles.groups()) do
        for _, preset in ipairs(grp.items) do
            items[#items + 1] = {
                id = preset.id,
                title = preset.title,
                group_title = grp.title,
                badge = preset.badge,
                summary = preset.summary,
                locked = preset.theme ~= nil,
            }
        end
    end
    return items
end

function M.initial_state(opts)
    opts = opts or {}
    local cur_style = styles.current_style(opts) or styles.DEFAULT
    local cur_theme = styles.current_theme(opts)
    local style_items = M.build_style_items()
    local theme_items = styles.list_themes(opts)

    local style_idx = 1
    for i, it in ipairs(style_items) do
        if it.id == cur_style then style_idx = i break end
    end
    local theme_idx = 1
    for i, it in ipairs(theme_items) do
        if it.id:lower() == (cur_theme.active_id or ""):lower() then theme_idx = i break end
    end

    return {
        tab = opts.initial_tab or "styles", -- "styles" | "palettes"
        style_items = style_items,
        theme_items = theme_items,
        style_idx = style_idx,
        theme_idx = theme_idx,
        active_style = cur_style,
        active_theme = cur_theme.active_id or "Kanagawa",
        mode = cur_theme.mode or "dark",
        live_preview = opts.live_preview ~= false,
        scroll_styles = 0,
        scroll_palettes = 0,
        dirty = false,
        committed = false,
        status_msg = "Browse with arrows / mouse · Live preview updates desktop behind window",
        hits = { cards = {}, controls = {} },
    }
end

function M.grid_columns(cols)
    return (cols >= 78) and 2 or 1
end

local function current_list(state)
    if state.tab == "palettes" then
        return state.theme_items, state.theme_idx, "theme_idx", "scroll_palettes"
    end
    return state.style_items, state.style_idx, "style_idx", "scroll_styles"
end

function M.move_selection(state, dir, cols, visible_rows)
    local items, idx, idx_key, scroll_key = current_list(state)
    local total = #items
    if total == 0 then return false end
    local gcols = M.grid_columns(cols)
    local next_idx = idx

    if dir == "LEFT" then
        if idx > 1 then next_idx = idx - 1 end
    elseif dir == "RIGHT" then
        if idx < total then next_idx = idx + 1 end
    elseif dir == "UP" then
        if idx - gcols >= 1 then next_idx = idx - gcols end
    elseif dir == "DOWN" then
        if idx + gcols <= total then
            next_idx = idx + gcols
        else
            local cur_row = math.floor((idx - 1) / gcols)
            local last_row = math.floor((total - 1) / gcols)
            if cur_row < last_row then
                next_idx = total
            end
        end
    elseif dir == "PGUP" then
        next_idx = math.max(1, idx - gcols * math.max(1, visible_rows))
    elseif dir == "PGDN" then
        next_idx = math.min(total, idx + gcols * math.max(1, visible_rows))
    elseif dir == "HOME" then
        next_idx = 1
    elseif dir == "END" then
        next_idx = total
    end

    state[idx_key] = next_idx
    local row = math.floor((next_idx - 1) / gcols)
    local scroll = state[scroll_key] or 0
    if row < scroll then
        scroll = row
    elseif row >= scroll + math.max(1, visible_rows) then
        scroll = row - math.max(1, visible_rows) + 1
    end
    local max_scroll = math.max(0, math.ceil(total / gcols) - math.max(1, visible_rows))
    state[scroll_key] = math.max(0, math.min(scroll, max_scroll))
    return next_idx ~= idx
end

local function build_card_lines(state, item, is_focused, is_active, card_w, active_pal, opts)
    local inner_w = card_w - 2
    local screen_w = inner_w - 2
    local bg_canvas = bg_hex(active_pal.bg)
    local CRST = RST .. bg_canvas
    local border_col = is_focused and active_pal.pri or active_pal.border
    local b_tl, b_tr, b_bl, b_br, b_h, b_v = "┌", "┐", "└", "┘", "─", "│"
    if is_focused then
        b_tl, b_tr, b_bl, b_br, b_h, b_v = "┏", "┓", "┗", "┛", "━", "┃"
    end

    local title_str
    local badge_str = ""
    if state.tab == "styles" then
        title_str = item.title
        if item.badge then
            badge_str = " [" .. item.badge .. "]"
        elseif item.locked then
            badge_str = " [Palette]"
        end
    else
        title_str = (item.id == "wallpaper") and "Wallpaper M3" or item.id
        badge_str = item.kind == "builtin" and " [Built-in]"
            or (item.kind == "custom" and " [Custom]" or " [Dynamic]")
    end

    local active_mark = is_active and "● " or (is_focused and "▸ " or "  ")
    local hdr_label = " " .. active_mark .. title_str .. badge_str .. " "
    hdr_label = M.clip_utf8(hdr_label, math.max(1, inner_w - 2))
    local hdr_w = utf8.len(hdr_label) or #hdr_label
    local rem_h = math.max(0, inner_w - 2 - hdr_w)

    local top_line = bg_canvas .. fg_hex(border_col) .. b_tl .. b_h .. b_h
        .. (is_focused and BOLD or "") .. fg_hex(is_focused and active_pal.pri or (is_active and active_pal.ter or active_pal.fg))
        .. hdr_label .. CRST .. fg_hex(border_col) .. string.rep(b_h, rem_h) .. b_tr .. CRST

    local lines = { top_line }

    if state.tab == "styles" then
        local illus = M.render_style_illustration(item.id, screen_w, active_pal, opts)
        for _, il in ipairs(illus) do
            lines[#lines + 1] = bg_canvas .. fg_hex(border_col) .. b_v .. CRST .. " " .. il .. bg_canvas .. " " .. fg_hex(border_col) .. b_v .. CRST
        end
        local caption = fit_plain(item.group_title .. " · " .. item.summary, screen_w)
        lines[#lines + 1] = bg_canvas .. fg_hex(border_col) .. b_v .. CRST .. " "
            .. fg_hex(is_focused and active_pal.fg or active_pal.muted) .. caption .. CRST
            .. " " .. fg_hex(border_col) .. b_v .. CRST
    else
        local illus, pal = M.render_palette_illustration(item, screen_w, state.mode, opts)
        for _, il in ipairs(illus) do
            lines[#lines + 1] = bg_canvas .. fg_hex(border_col) .. b_v .. CRST .. " " .. il .. bg_canvas .. " " .. fg_hex(border_col) .. b_v .. CRST
        end
        -- Swatch strip row (6 crisp color chips + bg hex)
        local chips = {
            fg_hex(pal.bg) .. "███",
            fg_hex(pal.card) .. "███",
            fg_hex(pal.pri) .. "███",
            fg_hex(pal.sec) .. "███",
            fg_hex(pal.ter) .. "███",
            fg_hex(pal.err) .. "███",
        }
        local swatch_str = bg_canvas .. table.concat(chips, " ")
        local swatch_w = 23
        local hex_lbl = (item.id == "wallpaper") and "m3-content" or (pal.bg or "")
        local sw_row
        if screen_w >= swatch_w + 2 then
            local hex_clipped = M.clip_utf8(hex_lbl, screen_w - swatch_w - 1)
            local hw = utf8.len(hex_clipped) or #hex_clipped
            local gap = math.max(1, screen_w - swatch_w - hw)
            sw_row = swatch_str .. CRST .. string.rep(" ", gap) .. fg_hex(active_pal.muted) .. hex_clipped .. CRST
        else
            sw_row = swatch_str .. CRST
        end
        lines[#lines + 1] = bg_canvas .. fg_hex(border_col) .. b_v .. CRST .. " " .. pad_right(sw_row, screen_w) .. " " .. fg_hex(border_col) .. b_v .. CRST
        -- Detail row
        local detail_txt = fit_plain(item.detail or "", screen_w)
        lines[#lines + 1] = bg_canvas .. fg_hex(border_col) .. b_v .. CRST .. " "
            .. fg_hex(is_focused and active_pal.fg or active_pal.muted) .. detail_txt .. CRST
            .. " " .. fg_hex(border_col) .. b_v .. CRST
    end

    lines[#lines + 1] = bg_canvas .. fg_hex(border_col) .. b_bl .. string.rep(b_h, inner_w) .. b_br .. CRST
    return lines
end

-- Render complete frame string (pure function; also populates state.hits for mouse clicks).
function M.render_frame(state, cols, rows, opts)
    cols = math.max(50, tonumber(cols) or 116)
    rows = math.max(18, tonumber(rows) or 38)
    opts = opts or {}

    local active_pal = M.load_palette_colors(state.active_theme, state.mode, opts)
    local bg_canvas = bg_hex(active_pal.bg)
    local CRST = RST .. bg_canvas
    local out = {}
    state.hits = { cards = {}, controls = {} }

    local inner = cols - 2
    local gcols = M.grid_columns(cols)
    local card_w = (gcols == 2) and math.min(64, math.floor((cols - 6) / 2)) or math.min(72, cols - 4)
    local total_grid_w = (gcols == 2) and (card_w * 2 + 2) or card_w
    local left_pad = math.max(1, math.floor((cols - total_grid_w) / 2))

    -- Row 1: Top border
    out[#out + 1] = bg_canvas .. fg_hex(active_pal.border) .. "┌" .. string.rep("─", inner) .. "┐" .. RST

    -- Row 2: Title + Tabs + Live Preview toggle (adaptive for narrow terminals >=50 cols)
    local compact = (cols < 74)
    local title_txt = compact and " HUB " or "  KAZE THEME HUB   "
    local tab1_lbl = compact and " 1 Styles " or string.format(" 1 Styles (%d) ", #state.style_items)
    local tab2_lbl = compact and " 2 Palettes " or string.format(" 2 Palettes (%d) ", #state.theme_items)
    local live_lbl = compact
        and (state.live_preview and " ● LIVE " or " ○ LIVE ")
        or (state.live_preview and " ● LIVE: ON " or " ○ LIVE: OFF ")

    local tab1_fmt = (state.tab == "styles")
        and (bg_hex(active_pal.pri) .. fg_hex(active_pal.bg) .. BOLD .. tab1_lbl .. CRST)
        or (bg_hex(active_pal.card) .. fg_hex(active_pal.muted) .. tab1_lbl .. CRST)
    local tab2_fmt = (state.tab == "palettes")
        and (bg_hex(active_pal.pri) .. fg_hex(active_pal.bg) .. BOLD .. tab2_lbl .. CRST)
        or (bg_hex(active_pal.card) .. fg_hex(active_pal.muted) .. tab2_lbl .. CRST)
    local live_fmt = state.live_preview
        and (bg_hex(active_pal.ter) .. fg_hex(active_pal.bg) .. BOLD .. live_lbl .. CRST)
        or (bg_hex(active_pal.card) .. fg_hex(active_pal.muted) .. live_lbl .. CRST)

    local c1_start = 2 + #title_txt
    local c1_end = c1_start + #tab1_lbl - 1
    local c2_start = c1_end + 2
    local c2_end = c2_start + #tab2_lbl - 1
    local live_w = M.display_width(live_lbl)
    local mid_gap = math.max(1, inner - #title_txt - #tab1_lbl - 1 - #tab2_lbl - live_w - 1)
    local live_start = c2_end + 1 + mid_gap + 1

    state.hits.controls[#state.hits.controls + 1] = { id = "tab_styles",   row = 2, col1 = c1_start,   col2 = c1_end }
    state.hits.controls[#state.hits.controls + 1] = { id = "tab_palettes", row = 2, col1 = c2_start,   col2 = c2_end }
    state.hits.controls[#state.hits.controls + 1] = { id = "toggle_live",  row = 2, col1 = live_start, col2 = live_start + live_w - 1 }

    local row2_body = BOLD .. fg_hex(active_pal.pri) .. title_txt .. CRST
        .. tab1_fmt .. " " .. tab2_fmt .. string.rep(" ", mid_gap) .. live_fmt .. " "
    out[#out + 1] = bg_canvas .. fg_hex(active_pal.border) .. "│" .. CRST .. pad_right(row2_body, inner) .. fg_hex(active_pal.border) .. "│" .. RST

    -- Row 3: Active status + Quick action chips ([d] Mode, [w] Wallpaper, [s] GUI)
    local cur_theme_lbl = state.active_theme == "wallpaper" and "Wallpaper M3" or state.active_theme
    local active_str = string.format("  Active: %s · %s (%s)", state.active_style, cur_theme_lbl, state.mode)
    local chip_d = " [d] " .. (state.mode == "dark" and "Light" or "Dark") .. " "
    local chip_w = " [w] Wall "
    local chip_s = " [s] GUI "
    local chips_plain_w = #chip_d + 1 + #chip_w + 1 + #chip_s + 1
    local act_max = math.max(1, inner - chips_plain_w - 1)
    local act_clipped = M.clip_utf8(active_str, act_max)
    local act_gap = math.max(1, inner - M.display_width(act_clipped) - chips_plain_w)

    local d_col1 = 2 + M.display_width(act_clipped) + act_gap
    local w_col1 = d_col1 + #chip_d + 1
    local s_col1 = w_col1 + #chip_w + 1
    state.hits.controls[#state.hits.controls + 1] = { id = "toggle_mode", row = 3, col1 = d_col1, col2 = d_col1 + #chip_d - 1 }
    state.hits.controls[#state.hits.controls + 1] = { id = "wallpaper",   row = 3, col1 = w_col1, col2 = w_col1 + #chip_w - 1 }
    state.hits.controls[#state.hits.controls + 1] = { id = "settings",    row = 3, col1 = s_col1, col2 = s_col1 + #chip_s - 1 }

    local row3_body = fg_hex(active_pal.muted) .. act_clipped .. CRST .. string.rep(" ", act_gap)
        .. bg_hex(active_pal.card) .. fg_hex(active_pal.fg) .. chip_d .. CRST .. " "
        .. bg_hex(active_pal.card) .. fg_hex(active_pal.fg) .. chip_w .. CRST .. " "
        .. bg_hex(active_pal.card) .. fg_hex(active_pal.fg) .. chip_s .. CRST .. " "
    out[#out + 1] = bg_canvas .. fg_hex(active_pal.border) .. "│" .. CRST .. pad_right(row3_body, inner) .. fg_hex(active_pal.border) .. "│" .. RST

    -- Row 4: Divider
    out[#out + 1] = bg_canvas .. fg_hex(active_pal.border) .. "├" .. string.rep("─", inner) .. "┤" .. RST

    -- Grid body rows
    local card_h = 9 -- top + 6 illus + caption + bottom (styles) or top + 5 illus + swatch + detail + bottom (palettes)
    local body_budget = math.max(card_h, rows - 8)
    local visible_rows = math.max(1, math.floor((body_budget + 1) / (card_h + 1)))

    local items, sel_idx, _, scroll_key = current_list(state)
    local total_grid_rows = math.max(1, math.ceil(#items / gcols))
    local scroll = state[scroll_key] or 0
    local max_scroll = math.max(0, total_grid_rows - visible_rows)
    if scroll > max_scroll then scroll = max_scroll end
    if scroll < 0 then scroll = 0 end
    state[scroll_key] = scroll
    state._visible_rows = visible_rows
    state._max_scroll = max_scroll

    local rendered_body = 0
    local screen_row = 5 -- 1-based terminal row index
    for r = 0, visible_rows - 1 do
        local gr = scroll + r
        if gr >= total_grid_rows then break end
        local idx_left = gr * gcols + 1
        local idx_right = (gcols == 2) and (idx_left + 1) or nil

        local item_l = items[idx_left]
        local item_r = idx_right and items[idx_right] or nil

        local active_id = (state.tab == "styles") and state.active_style or state.active_theme
        local lines_l = item_l and build_card_lines(state, item_l, idx_left == sel_idx, item_l.id:lower() == active_id:lower(), card_w, active_pal, opts) or nil
        local lines_r = item_r and build_card_lines(state, item_r, idx_right == sel_idx, item_r.id:lower() == active_id:lower(), card_w, active_pal, opts) or nil

        if item_l then
            state.hits.cards[#state.hits.cards + 1] = {
                idx = idx_left,
                row1 = screen_row,
                row2 = screen_row + card_h - 1,
                col1 = left_pad + 1,
                col2 = left_pad + card_w,
            }
        end
        if item_r then
            state.hits.cards[#state.hits.cards + 1] = {
                idx = idx_right,
                row1 = screen_row,
                row2 = screen_row + card_h - 1,
                col1 = left_pad + card_w + 3,
                col2 = left_pad + card_w * 2 + 2,
            }
        end

        local lpad_s = string.rep(" ", left_pad - 1)
        for li = 1, card_h do
            local seg = lpad_s .. (lines_l and lines_l[li] or string.rep(" ", card_w))
            if gcols == 2 then
                seg = seg .. "  " .. (lines_r and lines_r[li] or string.rep(" ", card_w))
            end
            out[#out + 1] = bg_canvas .. fg_hex(active_pal.border) .. "│" .. CRST .. pad_right(seg, inner) .. fg_hex(active_pal.border) .. "│" .. RST
            screen_row = screen_row + 1
            rendered_body = rendered_body + 1
        end

        if r < visible_rows - 1 and rendered_body < body_budget then
            out[#out + 1] = bg_canvas .. fg_hex(active_pal.border) .. "│" .. string.rep(" ", inner) .. "│" .. RST
            screen_row = screen_row + 1
            rendered_body = rendered_body + 1
        end
    end

    -- Pad remaining body rows cleanly
    while rendered_body < body_budget do
        out[#out + 1] = bg_canvas .. fg_hex(active_pal.border) .. "│" .. string.rep(" ", inner) .. "│" .. RST
        rendered_body = rendered_body + 1
    end

    -- Status + Scroll indicator line
    local scroll_lbl = string.format("Row %d-%d/%d ", scroll + 1, math.min(total_grid_rows, scroll + visible_rows), total_grid_rows)
    local dirty_tag = state.dirty and " [Unsaved Preview] " or ""
    local st_max = math.max(1, inner - #scroll_lbl - #dirty_tag - 1)
    local st_msg = M.clip_utf8("  " .. (state.status_msg or ""), st_max)
    local st_gap = math.max(1, inner - M.display_width(st_msg) - #dirty_tag - #scroll_lbl)
    local st_body = fg_hex(active_pal.muted) .. st_msg .. CRST .. string.rep(" ", st_gap)
        .. (state.dirty and (fg_hex(active_pal.sec) .. BOLD .. dirty_tag .. CRST) or "")
        .. fg_hex(active_pal.muted) .. scroll_lbl .. CRST
    out[#out + 1] = bg_canvas .. fg_hex(active_pal.border) .. "│" .. CRST .. pad_right(st_body, inner) .. fg_hex(active_pal.border) .. "│" .. RST

    -- Footer divider & keybind hints
    out[#out + 1] = bg_canvas .. fg_hex(active_pal.border) .. "├" .. string.rep("─", inner) .. "┤" .. RST
    local esc_hint = state.dirty and "Esc Revert & Close" or "Esc Close"
    local foot = string.format("  Arrows/Click Select · Enter Apply · Tab Styles/Palettes · p Live · d Mode · %s", esc_hint)
    out[#out + 1] = bg_canvas .. fg_hex(active_pal.border) .. "│" .. CRST .. fg_hex(active_pal.muted) .. fit_plain(foot, inner) .. CRST .. fg_hex(active_pal.border) .. "│" .. RST
    out[#out + 1] = bg_canvas .. fg_hex(active_pal.border) .. "└" .. string.rep("─", inner) .. "┘" .. RST

    return table.concat(out, "\r\n"), active_pal
end

-- Parse standard keyboard and SGR-1006 mouse events (\27[<b;x;yM / m).
function M.parse_input(raw)
    if type(raw) ~= "string" or raw == "" then
        return { kind = "EOF" }
    end
    local btn, mx, my, mtype = raw:match("^\27%[<(%d+);(%d+);(%d+)([Mm])$")
    if btn then
        return {
            kind = "MOUSE",
            button = tonumber(btn),
            col = tonumber(mx),
            row = tonumber(my),
            release = (mtype == "m"),
        }
    end
    if raw == "\27" then return { kind = "ESC" } end
    if raw == "\27[A" or raw == "\27OA" then return { kind = "UP" } end
    if raw == "\27[B" or raw == "\27OB" then return { kind = "DOWN" } end
    if raw == "\27[C" or raw == "\27OC" then return { kind = "RIGHT" } end
    if raw == "\27[D" or raw == "\27OD" then return { kind = "LEFT" } end
    if raw == "\27[5~" then return { kind = "PGUP" } end
    if raw == "\27[6~" then return { kind = "PGDN" } end
    if raw == "\27[H" or raw == "\27OH" then return { kind = "HOME" } end
    if raw == "\27[F" or raw == "\27OF" then return { kind = "END" } end
    if raw == "\27[Z" then return { kind = "TAB" } end
    if raw:sub(1, 1) == "\27" then return { kind = "IGNORE" } end
    if raw == "\r" or raw == "\n" then return { kind = "ENTER" } end
    if raw == "\t" then return { kind = "TAB" } end
    if raw == " " then return { kind = "SPACE" } end
    if raw == "\3" then return { kind = "CTRL_C" } end
    local lo = raw:lower()
    if lo == "k" then return { kind = "UP" } end
    if lo == "j" then return { kind = "DOWN" } end
    if lo == "h" then return { kind = "LEFT" } end
    if lo == "l" then return { kind = "RIGHT" } end
    if lo == "q" then return { kind = "ESC" } end
    return { kind = "CHAR", char = lo }
end

local function measure_term()
    local out = fs.capture("stty size </dev/tty 2>/dev/null") or ""
    local r, c = out:match("(%d+)%s+(%d+)")
    local rows = tonumber(r) or tonumber(os.getenv("LINES")) or 38
    local cols = tonumber(c) or tonumber(os.getenv("COLUMNS")) or 116
    return math.max(50, cols), math.max(18, rows)
end

-- Interactive TTY runner with zero-CPU blocking reader, live preview, OSC 11 bg sync, & atomic Esc rollback.
function M.run_interactive(opts)
    opts = opts or {}
    local tty_out = io.open("/dev/tty", "wb")
    if not tty_out then
        return nil, "interactive TTY (/dev/tty) unavailable"
    end

    local orig_stty = fs.capture("stty -g </dev/tty 2>/dev/null") or ""
    orig_stty = orig_stty:gsub("%s+$", "")

    local key_proc = nil
    local key_pid = nil

    local function close_key_reader()
        if key_pid then
            os.execute("kill -TERM " .. tostring(key_pid) .. " 2>/dev/null || true")
            key_pid = nil
        end
        if key_proc then
            pcall(function() key_proc:close() end)
            key_proc = nil
        end
    end

    -- Persistent pure-bash byte-packetizer (same zero-polling pattern as mirror_tui.lua,
    -- using bash builtins for 0% idle CPU and 0 per-key forks, handling CSI + SGR-1006 mouse).
    local function open_key_reader()
        close_key_reader()
        local reader_cmd = [[exec env LC_ALL=C bash -c '
printf "PID %s\n" "$$"
while IFS= read -rsn1 ch </dev/tty; do
    if [ -z "$ch" ]; then
        printf "0a\n"
        continue
    fi
    printf -v hex "%02x" "'"'"'$ch"
    if [ "$hex" = "1b" ]; then
        seq="1b"
        if IFS= read -rsn1 -t 0.03 c1 </dev/tty; then
            if [ -z "$c1" ]; then h1="0a"; else printf -v h1 "%02x" "'"'"'$c1"; fi
            seq="${seq}${h1}"
            if [ "$c1" = "[" ] || [ "$c1" = "O" ]; then
                while IFS= read -rsn1 -t 0.02 c2 </dev/tty; do
                    if [ -z "$c2" ]; then h2="0a"; else printf -v h2 "%02x" "'"'"'$c2"; fi
                    seq="${seq}${h2}"
                    case "$c2" in [A-Za-z~]) break ;; esac
                done
            fi
        fi
        printf "%s\n" "$seq"
    else
        printf "%s\n" "$hex"
    fi
done
' 2>/dev/null]]
        key_proc = io.popen(reader_cmd, "r")
        if key_proc then
            local hdr = key_proc:read("*l")
            local pid_s = hdr and hdr:match("^PID (%d+)$")
            if pid_s then
                key_pid = tonumber(pid_s)
            end
        end
    end

    local function read_tty_event()
        if not key_proc then return { kind = "EOF" } end
        local hex_line = key_proc:read("*l")
        if not hex_line or hex_line == "" then return { kind = "EOF" } end
        local raw = hex_line:gsub("%x%x", function(hh) return string.char(tonumber(hh, 16)) end)
        return M.parse_input(raw)
    end

    local function enter_raw()
        os.execute("stty -echo -icanon -isig min 1 time 0 </dev/tty 2>/dev/null")
        tty_out:write(ESC .. "[?1049h" .. ESC .. "[?25l" .. ESC .. "[?1000h" .. ESC .. "[?1006h")
        tty_out:flush()
        open_key_reader()
    end

    local function leave_raw()
        close_key_reader()
        tty_out:write(ESC .. "]111" .. ESC .. "\\" .. ESC .. "[?1006l" .. ESC .. "[?1000l" .. ESC .. "[?25h" .. ESC .. "[?1049l")
        tty_out:flush()
        if orig_stty ~= "" then
            os.execute("stty " .. fs.shell_quote(orig_stty) .. " </dev/tty 2>/dev/null")
        else
            os.execute("stty sane </dev/tty 2>/dev/null")
        end
        tty_out:close()
    end

    local snap = M.capture_snapshot(opts)
    local state = M.initial_state(opts)

    local function selection_already_active()
        if state.tab == "styles" then
            local it = state.style_items[state.style_idx]
            return it and it.id == state.active_style
        else
            local it = state.theme_items[state.theme_idx]
            return it and it.id:lower() == (state.active_theme or ""):lower()
        end
    end

    local function apply_current_selection(is_commit)
        if is_commit and selection_already_active() then
            state.dirty = false
            return true
        end
        local apply_opts = {
            reload = opts.reload ~= false,
            template_path = opts.template_path,
            config_path = opts.config_path,
        }
        if state.tab == "styles" then
            local it = state.style_items[state.style_idx]
            if not it then return true end
            local res, err = styles.apply(it.id, apply_opts)
            if not res then
                state.status_msg = "Error: " .. tostring(err)
                return false
            end
            state.active_style = res.style
            local ct = styles.current_theme(apply_opts)
            state.active_theme = ct.active_id
            state.mode = ct.mode
            state.dirty = not is_commit
            state.status_msg = is_commit
                and ("Applied style '" .. res.style .. "'")
                or ("Previewing style '" .. res.style .. "' · Enter to keep · Esc to revert")
            return true
        else
            local it = state.theme_items[state.theme_idx]
            if not it then return true end
            local res, err = styles.apply_theme(it.id, apply_opts)
            if not res then
                state.status_msg = "Error: " .. tostring(err)
                return false
            end
            state.active_theme = res.theme
            state.mode = res.mode
            state.dirty = not is_commit
            state.status_msg = is_commit
                and ("Applied theme '" .. res.theme .. "'")
                or ("Previewing theme '" .. res.theme .. "' · Enter to keep · Esc to revert")
            return true
        end
    end

    local function toggle_dark_light()
        local next_mode = (state.mode == "dark") and "light" or "dark"
        local cur_t = state.active_theme
        local res, err = styles.apply_theme(cur_t, {
            mode = next_mode,
            reload = opts.reload ~= false,
            template_path = opts.template_path,
            config_path = opts.config_path,
        })
        if res then
            state.mode = res.mode
            state.dirty = true
            state.status_msg = "Switched mode to " .. res.mode .. " · Enter to keep · Esc to revert"
        else
            state.status_msg = "Mode toggle error: " .. tostring(err)
        end
    end

    local function draw()
        local cols, rows = measure_term()
        local frame, pal = M.render_frame(state, cols, rows, opts)
        local osc11 = (pal and pal.bg) and (ESC .. "]11;" .. pal.bg .. ESC .. "\\") or ""
        tty_out:write(ESC .. "[?2026h" .. osc11 .. ESC .. "[H" .. frame .. ESC .. "[J" .. ESC .. "[?2026l")
        tty_out:flush()
        return cols, rows
    end

    local ok_run, run_err = pcall(function()
        enter_raw()
        local cols, rows = draw()

        while true do
            local ev = read_tty_event()
            if ev.kind == "EOF" or ev.kind == "ESC" or ev.kind == "CTRL_C" then
                if state.dirty and not state.committed then
                    M.restore_snapshot(snap, { reload = opts.reload ~= false })
                end
                break
            elseif ev.kind == "ENTER" then
                apply_current_selection(true)
                state.committed = true
                break
            elseif ev.kind == "TAB" then
                state.tab = (state.tab == "styles") and "palettes" or "styles"
                state.status_msg = (state.tab == "styles")
                    and "Visual Styles (11 layouts) · arrows or click to preview"
                    or ("Color Palettes (" .. #state.theme_items .. " themes) · arrows or click to preview")
                cols, rows = draw()
            elseif ev.kind == "UP" or ev.kind == "DOWN" or ev.kind == "LEFT" or ev.kind == "RIGHT"
                or ev.kind == "PGUP" or ev.kind == "PGDN" or ev.kind == "HOME" or ev.kind == "END" then
                local moved = M.move_selection(state, ev.kind, cols, state._visible_rows or 3)
                if moved then
                    cols, rows = draw()
                    if state.live_preview then
                        apply_current_selection(false)
                        cols, rows = draw()
                    end
                end
            elseif ev.kind == "SPACE" then
                apply_current_selection(false)
                cols, rows = draw()
            elseif ev.kind == "CHAR" then
                if ev.char == "1" then
                    state.tab = "styles"
                    cols, rows = draw()
                elseif ev.char == "2" then
                    state.tab = "palettes"
                    cols, rows = draw()
                elseif ev.char == "p" then
                    state.live_preview = not state.live_preview
                    state.status_msg = state.live_preview and "Live preview enabled" or "Live preview paused (press Space to preview, Enter to apply)"
                    cols, rows = draw()
                elseif ev.char == "d" then
                    toggle_dark_light()
                    cols, rows = draw()
                elseif ev.char == "w" then
                    os.execute("noctalia msg panel-toggle wallpaper >/dev/null 2>&1 &")
                    state.committed = true
                    break
                elseif ev.char == "s" then
                    os.execute("noctalia msg settings-toggle >/dev/null 2>&1 &")
                    state.committed = true
                    break
                end
            elseif ev.kind == "MOUSE" and not ev.release then
                local _, _, _, scroll_key = current_list(state)
                if ev.button == 64 then
                    local next_s = math.max(0, (state[scroll_key] or 0) - 1)
                    if next_s ~= state[scroll_key] then
                        state[scroll_key] = next_s
                        cols, rows = draw()
                    end
                elseif ev.button == 65 then
                    local next_s = math.min(state._max_scroll or 0, (state[scroll_key] or 0) + 1)
                    if next_s ~= state[scroll_key] then
                        state[scroll_key] = next_s
                        cols, rows = draw()
                    end
                elseif ev.button == 0 then
                    local handled = false
                    for _, ctrl in ipairs(state.hits.controls or {}) do
                        if ev.row == ctrl.row and ev.col >= ctrl.col1 and ev.col <= ctrl.col2 then
                            handled = true
                            if ctrl.id == "tab_styles" then
                                state.tab = "styles"
                            elseif ctrl.id == "tab_palettes" then
                                state.tab = "palettes"
                            elseif ctrl.id == "toggle_live" then
                                state.live_preview = not state.live_preview
                                state.status_msg = state.live_preview and "Live preview enabled" or "Live preview paused"
                            elseif ctrl.id == "toggle_mode" then
                                toggle_dark_light()
                            elseif ctrl.id == "wallpaper" then
                                os.execute("noctalia msg panel-toggle wallpaper >/dev/null 2>&1 &")
                                state.committed = true
                                return
                            elseif ctrl.id == "settings" then
                                os.execute("noctalia msg settings-toggle >/dev/null 2>&1 &")
                                state.committed = true
                                return
                            end
                            cols, rows = draw()
                            break
                        end
                    end
                    if not handled then
                        for _, card in ipairs(state.hits.cards or {}) do
                            if ev.row >= card.row1 and ev.row <= card.row2 and ev.col >= card.col1 and ev.col <= card.col2 then
                                local _, cur_idx, idx_key = current_list(state)
                                if card.idx == cur_idx then
                                    apply_current_selection(true)
                                    state.committed = true
                                    return
                                else
                                    state[idx_key] = card.idx
                                    cols, rows = draw()
                                    if state.live_preview then
                                        apply_current_selection(false)
                                        cols, rows = draw()
                                    end
                                end
                                break
                            end
                        end
                    end
                end
            end
        end
    end)

    leave_raw()
    if not ok_run then
        if state.dirty and not state.committed then
            pcall(M.restore_snapshot, snap, { reload = opts.reload ~= false })
        end
        return nil, run_err
    end

    return {
        committed = state.committed,
        style = state.active_style,
        theme = state.active_theme,
        mode = state.mode,
    }
end

return M
