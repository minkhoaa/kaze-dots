local ctx = require("kaze._ctx")
local hypr_user = require("kaze.hypr_user")
local cfg = ctx.cfg

local vis = hypr_user.visual_config(cfg)

-- Fallback neutral colors before Noctalia's built-in Hyprland template runs.
-- Once ~/.config/hypr/noctalia.lua exists, noctalia.apply_theme() overrides these live.
hl.config({
    general = {
        layout = "dwindle",
        allow_tearing = vis.general.allow_tearing,
        gaps_in = vis.general.gaps_in,
        gaps_out = vis.general.gaps_out,
        border_size = vis.general.border_size,
        ["col.active_border"] = "rgba(7aa2f7ee)",
        ["col.inactive_border"] = "rgba(414868aa)",
    },

    dwindle = {
        preserve_split = true,
        smart_split = false,
        smart_resizing = true,
    },

    decoration = {
        rounding = vis.decoration.rounding,
        active_opacity = vis.decoration.active_opacity,
        inactive_opacity = vis.decoration.inactive_opacity,
        fullscreen_opacity = 1.0,
        blur = {
            enabled = vis.decoration.blur.enabled,
            size = vis.decoration.blur.size,
            passes = vis.decoration.blur.passes,
            xray = vis.decoration.blur.xray,
            new_optimizations = true,
            ignore_opacity = true,
            popups = false,
        },
        shadow = vis.decoration.shadow,
    },

    group = {
        groupbar = {
            font_family = cfg.font or "JetBrainsMono Nerd Font",
            font_size = 11,
            height = 18,
            indicator_height = 2,
            gradients = false,
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
        close_special_on_empty = true,
    },

    render = {
        direct_scanout = 1,
    },

    xwayland = {
        force_zero_scaling = true,
    },

    ecosystem = {
        no_update_news = true,
        no_donation_nag = true,
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
