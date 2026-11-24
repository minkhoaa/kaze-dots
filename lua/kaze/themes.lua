local M = {}

local ORDER = { "kaze", "lavender", "tokyonight", "carbon" }

local REQUIRED_KEYS = {
    "bg",
    "bg_alt",
    "surface",
    "border",
    "fg",
    "fg_muted",
    "accent",
    "accent_fg",
    "ok",
    "warn",
    "danger",
}

local PRESETS = {
    kaze = {
        name = "kaze",
        label = "Kaze (Slate & Sky)",
        bg = "111318",
        bg_alt = "181b22",
        surface = "252a36",
        border = "323846",
        fg = "e6edf7",
        fg_muted = "8b95a7",
        accent = "89b4fa",
        accent_fg = "111318",
        ok = "a6e3a1",
        warn = "f9e2af",
        danger = "f38ba8",
        term = {
            "181b22", "f38ba8", "a6e3a1", "f9e2af", "89b4fa", "cba6f7", "94e2d5", "cdd6f4",
            "45475a", "f38ba8", "a6e3a1", "f9e2af", "89b4fa", "cba6f7", "94e2d5", "e6edf7",
        },
    },
    lavender = {
        name = "lavender",
        label = "Lavender (Soft Indigo)",
        bg = "11111b",
        bg_alt = "181825",
        surface = "313244",
        border = "45475a",
        fg = "cdd6f4",
        fg_muted = "9399b2",
        accent = "b4befe",
        accent_fg = "11111b",
        ok = "a6e3a1",
        warn = "f9e2af",
        danger = "f38ba8",
        term = {
            "181825", "f38ba8", "a6e3a1", "f9e2af", "89b4fa", "b4befe", "94e2d5", "bac2de",
            "45475a", "f38ba8", "a6e3a1", "f9e2af", "89b4fa", "b4befe", "94e2d5", "cdd6f4",
        },
    },
    tokyonight = {
        name = "tokyonight",
        label = "Tokyo Night Storm",
        bg = "1a1b26",
        bg_alt = "24283b",
        surface = "343b58",
        border = "414868",
        fg = "c0caf5",
        fg_muted = "787c99",
        accent = "7aa2f7",
        accent_fg = "1a1b26",
        ok = "9ece6a",
        warn = "e0af68",
        danger = "f7768e",
        term = {
            "15161e", "f7768e", "9ece6a", "e0af68", "7aa2f7", "bb9af7", "7dcfff", "a9b1d6",
            "414868", "f7768e", "9ece6a", "e0af68", "7aa2f7", "bb9af7", "7dcfff", "c0caf5",
        },
    },
    carbon = {
        name = "carbon",
        label = "Carbon (Monochrome Black)",
        bg = "0c0c0e",
        bg_alt = "141417",
        surface = "232329",
        border = "303038",
        fg = "e4e4e7",
        fg_muted = "8a8a95",
        accent = "e4e4e7",
        accent_fg = "0c0c0e",
        ok = "86efac",
        warn = "fde047",
        danger = "f87171",
        term = {
            "141417", "f87171", "86efac", "fde047", "a1a1aa", "d4d4d8", "94e2d5", "d4d4d8",
            "3f3f46", "fca5a5", "bbf7d0", "fef08a", "d4d4d8", "e4e4e7", "a5f3fc", "fafafa",
        },
    },
}

local function is_hex6(v)
    return type(v) == "string" and #v == 6 and v:match("^%x%x%x%x%x%x$") ~= nil
end

local function copy_table(src)
    local out = {}
    for k, v in pairs(src) do
        if type(v) == "table" then
            out[k] = copy_table(v)
        else
            out[k] = v
        end
    end
    return out
end

local function derive_ansi(t)
    return {
        t.bg_alt, t.danger, t.ok, t.warn, t.accent, "cba6f7", "94e2d5", t.fg_muted,
        t.border, t.danger, t.ok, t.warn, t.accent, "cba6f7", "94e2d5", t.fg,
    }
end

function M.list()
    local out = {}
    for i, name in ipairs(ORDER) do
        out[i] = name
    end
    return out
end

function M.validate(t)
    assert(type(t) == "table", "theme must be a table")
    for _, key in ipairs(REQUIRED_KEYS) do
        local val = t[key]
        if not is_hex6(val) then
            error(string.format("invalid theme color '%s': expected 6-digit hex without '#', got %s", key, tostring(val)))
        end
    end
    if t.term ~= nil then
        assert(type(t.term) == "table" and #t.term == 16, "theme.term must be a 16-entry array")
        for i = 1, 16 do
            if not is_hex6(t.term[i]) then
                error(string.format("invalid theme.term[%d]: expected 6-digit hex without '#', got %s", i, tostring(t.term[i])))
            end
        end
    end
    return t
end

function M.get(name, overrides)
    local preset = PRESETS[name]
    if not preset then
        error(string.format("unknown theme '%s' (available: %s)", tostring(name), table.concat(ORDER, ", ")))
    end
    local theme = copy_table(preset)
    if type(overrides) == "table" then
        for k, v in pairs(overrides) do
            if type(v) == "table" then
                theme[k] = copy_table(v)
            else
                theme[k] = v
            end
        end
    end
    if theme.term == nil then
        theme.term = derive_ansi(theme)
    end
    return M.validate(theme)
end

function M.hex(c)
    assert(is_hex6(c), "themes.hex expects a 6-digit hex color")
    return "#" .. c
end

function M.hex_alpha(c, aa)
    assert(is_hex6(c), "themes.hex_alpha expects a 6-digit hex color")
    local alpha = aa or "ff"
    assert(type(alpha) == "string" and #alpha == 2 and alpha:match("^%x%x$") ~= nil,
        "themes.hex_alpha expects a 2-digit hex alpha")
    return c .. alpha
end

function M.hypr_rgba(c, aa)
    return "rgba(" .. M.hex_alpha(c, aa) .. ")"
end

function M.hypr_rgb(c)
    assert(is_hex6(c), "themes.hypr_rgb expects a 6-digit hex color")
    return "rgb(" .. c .. ")"
end

return M
