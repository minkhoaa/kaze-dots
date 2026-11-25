local ctx = require("kaze._ctx")
local themes = require("kaze.themes")

local cfg = ctx.cfg
local theme = ctx.theme
local layout = ctx.layout

local blur = cfg.blur or {}

hl.config({
    general = {
        layout = "dwindle",
        allow_tearing = false,
        gaps_in = layout.hypr.gaps_in,
        gaps_out = layout.hypr.gaps_out,
        border_size = layout.hypr.border_size,
        ["col.active_border"] = themes.hypr_rgba(theme.accent, "cc"),
        ["col.inactive_border"] = themes.hypr_rgba(theme.border, "88"),
    },

    dwindle = {
        preserve_split = true,
        smart_split = false,
        smart_resizing = true,
    },

    decoration = {
        rounding = layout.hypr.rounding,
        blur = {
            enabled = blur.enabled ~= false,
            size = blur.size or 3,
            passes = blur.passes or 1,
            xray = blur.xray ~= false,
            new_optimizations = true,
            ignore_opacity = true,
            popups = false,
        },
        shadow = {
            enabled = cfg.shadow == true,
        },
    },

    animations = {
        enabled = true,
    },

    input = {
        kb_layout = cfg.kb_layout or "us",
        accel_profile = cfg.accel_profile or "flat",
        numlock_by_default = false,
        repeat_delay = 240,
        repeat_rate = 35,
        focus_on_close = 1,
        touchpad = {
            natural_scroll = true,
            disable_while_typing = true,
            scroll_factor = 0.35,
        },
    },

    misc = {
        disable_hyprland_logo = true,
        force_default_wallpaper = 0,
        animate_manual_resizes = false,
        animate_mouse_windowdragging = false,
        focus_on_activate = true,
        mouse_move_enables_dpms = true,
        key_press_enables_dpms = true,
        middle_click_paste = false,
        background_color = themes.hypr_rgb(theme.bg),
    },
})

if cfg.workspace_swipe ~= false then
    hl.gesture({
        fingers = 3,
        direction = "horizontal",
        action = "workspace",
    })
end

hl.curve("snappy", { type = "bezier", points = { { 0.08, 0.9 }, { 0.15, 1.0 } } })
hl.curve("fastOut", { type = "bezier", points = { { 0.2, 0.0 }, { 0.0, 1.0 } } })

hl.animation({ leaf = "windowsIn", enabled = true, speed = 2.5, bezier = "snappy", style = "popin 88%" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 2.0, bezier = "fastOut", style = "popin 90%" })
hl.animation({ leaf = "windowsMove", enabled = true, speed = 3.0, bezier = "snappy" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 2.5, bezier = "snappy", style = "slide" })
hl.animation({ leaf = "fade", enabled = true, speed = 2.5, bezier = "fastOut" })
hl.animation({ leaf = "border", enabled = true, speed = 3.0, bezier = "fastOut" })
hl.animation({ leaf = "layers", enabled = true, speed = 2.0, bezier = "snappy", style = "fade" })
