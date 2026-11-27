local fs = require("kaze.fs")
local json = require("kaze.json")

local M = {}

M.DEFAULT = "dynamic-island"

M.BUILTIN_THEMES = {
    "Kanagawa",
    "Tokyo-Night",
    "Catppuccin",
    "Dracula",
    "Eldritch",
    "Gruvbox",
    "Nord",
    "Pine",
}

M.GROUPS = {
    {
        id = "angular",
        title = "Angular & Minimal",
        items = { "omarchy-rail", "swiss-grid", "corner-hud", "ghost-zero" },
    },
    {
        id = "dynamic",
        title = "Dynamic & Modern",
        items = { "dynamic-island", "hardware-notch", "glass-studio", "floating-rail" },
    },
    {
        id = "retro",
        title = "Retro & Editorial",
        items = { "tui-hacker", "retro-90s", "cinema-frame" },
    },
}

M.ORDER = {
    "omarchy-rail",
    "swiss-grid",
    "corner-hud",
    "ghost-zero",
    "dynamic-island",
    "hardware-notch",
    "glass-studio",
    "floating-rail",
    "tui-hacker",
    "retro-90s",
    "cinema-frame",
}

M.ALIASES = {
    brutalist = "omarchy-rail",
    omarchy = "omarchy-rail",
    swiss = "swiss-grid",
    notion = "swiss-grid",
    ["floating-islands"] = "corner-hud",
    ghost = "ghost-zero",
    ["zero-bar"] = "ghost-zero",
    ["concave-notch"] = "hardware-notch",
    glass = "glass-studio",
    macos = "glass-studio",
    tui = "tui-hacker",
    hacker = "tui-hacker",
    retro = "retro-90s",
    win95 = "retro-90s",
    pixel = "retro-90s",
    cinema = "cinema-frame",
}

local INT_KEYS = {
    thickness = true,
    padding = true,
    widget_spacing = true,
    margin_edge = true,
    margin_ends = true,
    margin_opposite_edge = true,
    radius = true,
    radius_top_left = true,
    radius_top_right = true,
    radius_bottom_left = true,
    radius_bottom_right = true,
    capsule_radius = true,
    offset_x = true,
    offset_y = true,
    auto_hide_delay_ms = true,
    icon_size = true,
    min_length = true,
    max_length = true,
    max_label_chars = true,
}

local FLOAT_KEYS = {
    corner_radius_scale = true,
    border_width = true,
    background_opacity = true,
    capsule_border_width = true,
    opacity = true,
    magnification_scale = true,
    art_size = true,
    scale = true,
    font_scale = true,
}

local CAP_FLOAT_KEYS = {
    border_width = true,
    padding = true,
    widget_spacing = true,
    opacity = true,
}

local CAP_INT_KEYS = {
    radius = true,
    accordion_duration = true,
    accordion_delay_ms = true,
}

local BAR_DEFAULT_ORDER = {
    "position", "thickness", "padding", "widget_spacing",
    "margin_edge", "margin_ends", "margin_opposite_edge",
    "auto_hide", "auto_hide_delay_ms", "smart_auto_hide", "show_on_workspace_switch",
    "reserve_space", "auto_hide_reserve_space",
    "font_family",
    "background_opacity", "compositor_blur", "border", "border_width",
    "radius", "radius_top_left", "radius_top_right", "radius_bottom_left", "radius_bottom_right",
    "concave_edge_corners", "shadow", "contact_shadow", "capsule", "capsule_border_width",
    "start", "center", "end",
}

local SHELL_ORDER = {
    "corner_radius_scale", "button_borders", "card_borders",
    "input_borders", "popup_borders", "popup_shadows",
}

local PANEL_ORDER = {
    "borders", "border_width", "shadow", "transparency_mode",
    "control_center_placement", "control_center_position",
    "launcher_placement", "launcher_position",
    "session_placement", "session_position",
    "wallpaper_placement", "wallpaper_position",
    "open_near_click_control_center", "open_near_click_launcher",
    "open_near_click_clipboard", "open_near_click_session", "open_near_click_wallpaper",
}

local NOTIF_OSD_ORDER = {
    "position", "border", "border_width", "offset_x", "offset_y",
}

local function make_shell(scale, popup_shadows)
    return {
        order = SHELL_ORDER,
        values = {
            corner_radius_scale = scale,
            button_borders = true,
            card_borders = true,
            input_borders = true,
            popup_borders = true,
            popup_shadows = popup_shadows == true,
        },
    }
end

local function make_panel(width, shadow, transparency_mode, overrides)
    local vals = {
        borders = true,
        border_width = width,
        shadow = shadow == true,
        transparency_mode = transparency_mode or "solid",
        control_center_placement = "attached",
        control_center_position = "auto",
        launcher_placement = "floating",
        launcher_position = "auto",
        session_placement = "floating",
        session_position = "auto",
        wallpaper_placement = "attached",
        wallpaper_position = "auto",
        open_near_click_control_center = true,
        open_near_click_launcher = true,
        open_near_click_clipboard = true,
        open_near_click_session = true,
        open_near_click_wallpaper = true,
    }
    for k, v in pairs(overrides or {}) do
        vals[k] = v
    end
    return {
        order = PANEL_ORDER,
        values = vals,
    }
end

local function make_bar(overrides)
    local vals = {
        position = "top",
        thickness = 36,
        padding = 6,
        widget_spacing = 6,
        margin_edge = 0,
        margin_ends = 0,
        margin_opposite_edge = 0,
        auto_hide = false,
        auto_hide_delay_ms = 0,
        smart_auto_hide = false,
        show_on_workspace_switch = true,
        reserve_space = true,
        auto_hide_reserve_space = false,
        font_family = "",
        background_opacity = 0.94,
        compositor_blur = true,
        border = "outline_variant",
        border_width = 1.5,
        radius = 0,
        radius_top_left = 0,
        radius_top_right = 0,
        radius_bottom_left = 0,
        radius_bottom_right = 0,
        concave_edge_corners = false,
        shadow = false,
        contact_shadow = false,
        capsule = false,
        capsule_border_width = 1.0,
        start = {},
        center = {},
        ["end"] = {},
    }
    for k, v in pairs(overrides or {}) do
        vals[k] = v
    end
    return {
        order = BAR_DEFAULT_ORDER,
        values = vals,
    }
end

local function make_notif(pos, border_w, ox, oy)
    return {
        order = NOTIF_OSD_ORDER,
        values = {
            position = pos,
            border = true,
            border_width = border_w,
            offset_x = ox,
            offset_y = oy,
        },
    }
end

local function make_present_widgets()
    return {
        ["widget.present"] = {
            order = { "type", "enabled", "glyph", "icon_color", "label", "tooltip" },
            values = {
                type = "custom_button",
                enabled = false,
                glyph = "presentation",
                icon_color = "on_surface_variant",
                label = "",
                tooltip = "Display Share Inactive",
            },
        },
        ["widget.present.actions"] = {
            order = { "left", "right" },
            values = {
                left = "exec kaze-display --menu",
                right = "exec kaze-display toggle-window-share",
            },
        },
    }
end

M.PRESETS = {
    ["omarchy-rail"] = {
        id = "omarchy-rail",
        group = "angular",
        title = "Omarchy / Brutalist",
        summary = "Flush left 42px industrial rail, 0px sharp corners, 2px borders",
        shell = make_shell(0.0, false),
        shell_panel = make_panel(2.0, false, "solid"),
        bar_order = { "default" },
        bar_default = {
            order = {
                "position", "thickness", "padding", "widget_spacing",
                "margin_edge", "margin_ends", "margin_opposite_edge",
                "background_opacity", "compositor_blur", "border", "border_width",
                "radius", "radius_top_left", "radius_top_right", "radius_bottom_left", "radius_bottom_right",
                "concave_edge_corners", "shadow", "contact_shadow", "capsule", "capsule_border_width",
                "start", "center", "end",
            },
            values = {
                position = "left",
                thickness = 42,
                padding = 6,
                widget_spacing = 6,
                margin_edge = 0,
                margin_ends = 0,
                margin_opposite_edge = 0,
                background_opacity = 1.0,
                compositor_blur = false,
                border = "outline_variant",
                border_width = 2.0,
                radius = 0,
                radius_top_left = 0,
                radius_top_right = 0,
                radius_bottom_left = 0,
                radius_bottom_right = 0,
                concave_edge_corners = false,
                shadow = false,
                contact_shadow = false,
                capsule = false,
                capsule_border_width = 1.0,
                start = { "launcher", "ws" },
                center = { "vclock" },
                ["end"] = { "record", "tray", "display", "mirror", "net", "vol", "bat", "theme", "notifications", "control-center", "session" },
            },
            drop = {
                capsule_group = true,
                auto_hide = true,
                auto_hide_delay_ms = true,
                smart_auto_hide = true,
                show_on_workspace_switch = true,
                reserve_space = true,
                auto_hide_reserve_space = true,
                font_family = true,
            },
        },
        capsule_groups = {},
        dock = {
            order = { "enabled" },
            values = { enabled = false },
        },
        widget_ws = {
            order = { "style", "show_labels", "capsule_radius", "focused_color", "occupied_color", "empty_color" },
            values = {
                style = "regular",
                show_labels = true,
                capsule_radius = 0,
                focused_color = "primary",
                occupied_color = "secondary",
                empty_color = "surface_container",
            },
            drop = { show_icons = true, separator = true },
        },
        widgets = {
            ["widget.record"] = {
                order = { "type", "glyph", "icon_color", "tooltip" },
                values = {
                    type = "custom_button",
                    glyph = "video",
                    icon_color = "on_surface_variant",
                    tooltip = "Screen Recorder (Left: Menu, Right: Toggle)",
                },
                drop = { enabled = true, label = true },
            },
            ["widget.media"] = {
                order = { "type", "art_size", "min_length", "max_length", "title_scroll" },
                values = {
                    type = "media",
                    art_size = 16.0,
                    min_length = 80.0,
                    max_length = 180.0,
                    title_scroll = "none",
                },
                drop = { hide_when_no_media = true },
            },
        },
        notification = make_notif("top_right", 2.0, 12, 12),
        osd = make_notif("top_right", 2.0, 12, 12),
        hypr = {
            gaps_in = 4,
            gaps_out = 8,
            border_size = 2,
            rounding = 0,
            shadow = false,
            blur = { enabled = false, size = 3, passes = 1, xray = true },
            tui_drawer_x = 50,
            ghost_super_peek = false,
        },
        gtk = { kind = "sharp" },
    },

    ["swiss-grid"] = {
        id = "swiss-grid",
        group = "angular",
        title = "Swiss Grid",
        summary = "Warm paper light grid, 1px hairline rules, text-only top bar",
        theme = {
            mode = "light",
            source = "custom",
            custom_palette = "Kaze-Swiss",
            pure_black_dark = false,
        },
        shell = make_shell(0.0, false),
        shell_panel = make_panel(1.0, false, "solid"),
        bar_order = { "default" },
        bar_default = make_bar({
            position = "top",
            thickness = 34,
            padding = 14,
            widget_spacing = 12,
            margin_edge = 0,
            margin_ends = 0,
            background_opacity = 1.0,
            compositor_blur = false,
            border = "outline_variant",
            border_width = 1.0,
            radius = 0,
            start = { "ws" },
            center = { "swiss_clock" },
            ["end"] = { "swiss_net", "swiss_sep", "swiss_vol", "swiss_bat", "swiss_sep", "swiss_theme" },
        }),
        capsule_groups = {},
        dock = {
            order = { "enabled" },
            values = { enabled = false },
        },
        widget_ws = {
            order = { "style", "show_labels", "show_icons", "label_source", "separator", "capsule_radius", "focused_color", "occupied_color", "empty_color" },
            values = {
                style = "minimal",
                show_labels = true,
                show_icons = false,
                label_source = "id",
                separator = " / ",
                capsule_radius = 0,
                focused_color = "primary",
                occupied_color = "on_surface_variant",
                empty_color = "secondary",
            },
        },
        widgets = {
            ["widget.swiss_clock"] = {
                order = { "type", "format", "show_glyph" },
                values = {
                    type = "clock",
                    format = "{:%a %d %b  —  %H:%M}",
                    show_glyph = false,
                },
            },
            ["widget.swiss_net"] = {
                order = { "type", "show_glyph", "show_label", "custom_label" },
                values = {
                    type = "network",
                    show_glyph = false,
                    show_label = true,
                    custom_label = "NET ",
                },
            },
            ["widget.swiss_vol"] = {
                order = { "type", "show_glyph", "show_label", "custom_label", "hide_label_when_muted" },
                values = {
                    type = "volume",
                    show_glyph = false,
                    show_label = true,
                    custom_label = "VOL ",
                    hide_label_when_muted = false,
                },
            },
            ["widget.swiss_bat"] = {
                order = { "type", "show_glyph", "show_label", "custom_label" },
                values = {
                    type = "battery",
                    show_glyph = false,
                    show_label = true,
                    custom_label = "—  BAT ",
                },
            },
            ["widget.swiss_sep"] = {
                order = { "type", "text" },
                values = {
                    type = "text",
                    text = "—",
                },
            },
            ["widget.swiss_theme"] = {
                order = { "type", "glyph", "label", "tooltip" },
                values = {
                    type = "custom_button",
                    glyph = "",
                    label = "THEME",
                    tooltip = "Theme Hub (Left: Hub, Right: Visual Styles, Middle: Dark/Light)",
                },
            },
            ["widget.swiss_theme.actions"] = {
                order = { "left", "right", "middle" },
                values = {
                    left = "exec kaze-style --hub",
                    right = "exec kaze-style --menu",
                    middle = "exec noctalia msg theme-mode-toggle",
                },
            },
        },
        notification = make_notif("top_right", 1.0, 16, 16),
        osd = make_notif("top_right", 1.0, 16, 16),
        hypr = {
            gaps_in = 8,
            gaps_out = 16,
            border_size = 1,
            rounding = 0,
            shadow = false,
            blur = { enabled = false, size = 3, passes = 1, xray = true },
            tui_drawer_x = 16,
            ghost_super_peek = false,
        },
        gtk = { kind = "sharp" },
    },

    ["corner-hud"] = {
        id = "corner-hud",
        group = "angular",
        title = "Corner HUD",
        summary = "Two separated corner clusters with empty center horizon",
        shell = make_shell(0.8, false),
        shell_panel = make_panel(2.0, false, "solid", {
            control_center_placement = "floating",
            wallpaper_placement = "floating",
        }),
        bar_order = { "default" },
        bar_default = make_bar({
            position = "top",
            thickness = 38,
            padding = 4,
            widget_spacing = 8,
            margin_edge = 8,
            margin_ends = 12,
            background_opacity = 0.0,
            compositor_blur = false,
            border = "outline_variant",
            border_width = 0.0,
            radius = 0,
            start = { "group:corner_left" },
            center = {},
            ["end"] = { "group:corner_right" },
        }),
        capsule_groups = {
            {
                id = "corner_left",
                members = { "launcher", "ws" },
                fill = "surface_container",
                border = "outline_variant",
                border_width = 1.5,
                radius = 12,
                padding = 6.0,
                widget_spacing = 6.0,
                opacity = 0.94,
            },
            {
                id = "corner_right",
                members = { "record", "present", "tray", "display", "mirror", "net", "vol", "bat", "theme", "notifications", "hclock", "control-center", "session" },
                fill = "surface_container",
                border = "outline_variant",
                border_width = 1.5,
                radius = 12,
                padding = 6.0,
                widget_spacing = 6.0,
                opacity = 0.94,
            },
        },
        dock = {
            order = { "enabled" },
            values = { enabled = false },
        },
        widget_ws = {
            order = { "style", "show_labels", "show_icons", "separator", "capsule_radius", "focused_color", "occupied_color", "empty_color" },
            values = {
                style = "regular",
                show_labels = true,
                show_icons = true,
                separator = "",
                capsule_radius = 8,
                focused_color = "primary",
                occupied_color = "secondary",
                empty_color = "surface_container",
            },
        },
        widgets = (function()
            local w = make_present_widgets()
            w["widget.record"] = {
                order = { "type", "enabled", "glyph", "icon_color", "label", "tooltip" },
                values = {
                    type = "custom_button",
                    enabled = true,
                    glyph = "video",
                    icon_color = "on_surface_variant",
                    label = "",
                    tooltip = "Screen Recorder (Left: Menu, Right: Toggle)",
                },
            }
            return w
        end)(),
        notification = make_notif("top_right", 1.5, 12, 12),
        osd = make_notif("top_right", 1.5, 12, 12),
        hypr = {
            gaps_in = 6,
            gaps_out = 10,
            border_size = 2,
            rounding = 8,
            shadow = false,
            blur = { enabled = true, size = 4, passes = 2, xray = true },
            tui_drawer_x = 12,
            ghost_super_peek = false,
        },
        gtk = { kind = "soft" },
    },

    ["ghost-zero"] = {
        id = "ghost-zero",
        group = "angular",
        title = "Ghost / Zero-Bar",
        summary = "0px edge-to-edge windows; hold Super or hit top edge to peek bar",
        note = "Hold Super_L or touch the top screen edge to reveal the status bar; tap Super to toggle Launcher.",
        shell = make_shell(0.0, false),
        shell_panel = make_panel(1.0, false, "solid", {
            control_center_placement = "floating",
            wallpaper_placement = "floating",
        }),
        bar_order = { "default" },
        bar_default = make_bar({
            position = "top",
            thickness = 32,
            padding = 8,
            widget_spacing = 8,
            margin_edge = 0,
            margin_ends = 0,
            auto_hide = true,
            auto_hide_delay_ms = 200,
            smart_auto_hide = false,
            show_on_workspace_switch = true,
            reserve_space = false,
            auto_hide_reserve_space = false,
            background_opacity = 0.94,
            compositor_blur = true,
            border = "outline_variant",
            border_width = 1.0,
            radius = 0,
            start = { "launcher", "ws" },
            center = { "hclock" },
            ["end"] = { "record", "present", "tray", "display", "mirror", "net", "vol", "bat", "theme", "notifications", "control-center", "session" },
        }),
        capsule_groups = {},
        dock = {
            order = { "enabled" },
            values = { enabled = false },
        },
        widget_ws = {
            order = { "style", "show_labels", "show_icons", "separator", "capsule_radius", "focused_color", "occupied_color", "empty_color" },
            values = {
                style = "regular",
                show_labels = true,
                show_icons = true,
                separator = "",
                capsule_radius = 0,
                focused_color = "primary",
                occupied_color = "secondary",
                empty_color = "surface_container",
            },
        },
        widgets = (function()
            local w = make_present_widgets()
            w["widget.record"] = {
                order = { "type", "enabled", "glyph", "icon_color", "label", "tooltip" },
                values = {
                    type = "custom_button",
                    enabled = true,
                    glyph = "video",
                    icon_color = "on_surface_variant",
                    label = "",
                    tooltip = "Screen Recorder (Left: Menu, Right: Toggle)",
                },
            }
            return w
        end)(),
        notification = make_notif("top_right", 1.0, 8, 8),
        osd = make_notif("top_right", 1.0, 8, 8),
        hypr = {
            gaps_in = 0,
            gaps_out = 0,
            border_size = 1,
            rounding = 0,
            shadow = false,
            blur = { enabled = false, size = 3, passes = 1, xray = true },
            tui_drawer_x = 12,
            ghost_super_peek = true,
        },
        gtk = { kind = "sharp" },
    },

    ["dynamic-island"] = {
        id = "dynamic-island",
        group = "dynamic",
        title = "Dynamic Island",
        badge = "Default",
        summary = "Top-left workspaces, center Dynamic Island (clock/live/noti/menu) & top-right quick controls",
        note = "Center island holds clock, notifications, full menu & live activity; top-right holds Wi-Fi, Bluetooth, audio, tray & power.",
        shell = make_shell(1.0, false),
        shell_panel = make_panel(1.5, false, "solid", {
            control_center_placement = "floating",
            wallpaper_placement = "floating",
        }),
        bar_order = { "default" },
        bar_default = make_bar({
            position = "top",
            thickness = 38,
            padding = 4,
            widget_spacing = 6,
            margin_edge = 8,
            margin_ends = 12,
            background_opacity = 0.0,
            compositor_blur = false,
            border = "outline_variant",
            border_width = 0.0,
            radius = 0,
            start = { "group:island_left" },
            center = { "group:island" },
            ["end"] = { "group:island_right" },
        }),
        capsule_groups = {
            {
                id = "island_left",
                members = { "launcher", "ws" },
                fill = "surface_container",
                border = "outline_variant",
                border_width = 1.0,
                radius = 19,
                padding = 8.0,
                widget_spacing = 6.0,
                opacity = 0.94,
            },
            {
                id = "island",
                members = { "island_clock", "media", "record", "present", "theme", "notifications", "control-center" },
                fill = "surface_container",
                border = "outline_variant",
                border_width = 1.0,
                radius = 19,
                padding = 8.0,
                widget_spacing = 6.0,
                opacity = 0.94,
                accordion = false,
            },
            {
                id = "island_right",
                members = { "tray", "display", "mirror", "net", "bt", "vol", "bat", "session" },
                fill = "surface_container",
                border = "outline_variant",
                border_width = 1.0,
                radius = 19,
                padding = 8.0,
                widget_spacing = 6.0,
                opacity = 0.94,
            },
        },
        dock = {
            order = { "enabled" },
            values = { enabled = false },
        },
        widget_ws = {
            order = { "style", "show_labels", "show_icons", "separator", "capsule_radius", "focused_color", "occupied_color", "empty_color" },
            values = {
                style = "focus_hint",
                show_labels = false,
                show_icons = false,
                separator = "",
                capsule_radius = 10,
                focused_color = "primary",
                occupied_color = "secondary",
                empty_color = "on_surface_variant",
            },
        },
        widgets = (function()
            local w = make_present_widgets()
            w["widget.island_clock"] = {
                order = { "type", "format", "show_glyph" },
                values = {
                    type = "clock",
                    format = "{:%H:%M}",
                    show_glyph = false,
                },
            }
            w["widget.bt"] = {
                order = { "type", "show_label" },
                values = {
                    type = "bluetooth",
                    show_label = false,
                },
            }
            w["widget.media"] = {
                order = { "type", "art_size", "min_length", "max_length", "title_scroll", "hide_when_no_media" },
                values = {
                    type = "media",
                    art_size = 16.0,
                    min_length = 60.0,
                    max_length = 140.0,
                    title_scroll = "none",
                    hide_when_no_media = true,
                },
            }
            w["widget.record"] = {
                order = { "type", "enabled", "glyph", "icon_color", "label", "tooltip" },
                values = {
                    type = "custom_button",
                    enabled = false,
                    glyph = "video",
                    icon_color = "on_surface_variant",
                    label = "",
                    tooltip = "Screen Recorder (Left: Menu, Right: Toggle)",
                },
            }
            return w
        end)(),
        notification = make_notif("top_right", 1.5, 12, 12),
        osd = make_notif("top_right", 1.5, 12, 12),
        hypr = {
            gaps_in = 6,
            gaps_out = 10,
            border_size = 2,
            rounding = 12,
            shadow = { enabled = true, range = 16, render_power = 3, color = "rgba(00000044)" },
            blur = { enabled = true, size = 5, passes = 2, xray = false },
            tui_drawer_x = 12,
            ghost_super_peek = false,
        },
        gtk = { kind = "soft" },
    },

    ["hardware-notch"] = {
        id = "hardware-notch",
        group = "dynamic",
        title = "Hardware Notch",
        summary = "Flush top center hardware notch with concave edge corners",
        shell = make_shell(1.0, false),
        shell_panel = make_panel(1.5, false, "solid", {
            control_center_placement = "floating",
            wallpaper_placement = "floating",
        }),
        bar_order = { "default" },
        bar_default = make_bar({
            position = "top",
            thickness = 34,
            padding = 10,
            widget_spacing = 8,
            margin_edge = 0,
            margin_ends = "28%",
            background_opacity = 1.0,
            compositor_blur = false,
            border = "outline_variant",
            border_width = 0.0,
            radius = 18,
            radius_top_left = 0,
            radius_top_right = 0,
            radius_bottom_left = 18,
            radius_bottom_right = 18,
            concave_edge_corners = true,
            start = { "ws" },
            center = { "notch_clock", "media" },
            ["end"] = { "record", "present", "net", "vol", "bat", "theme", "notifications" },
        }),
        capsule_groups = {},
        dock = {
            order = { "enabled" },
            values = { enabled = false },
        },
        widget_ws = {
            order = { "style", "show_labels", "show_icons", "separator", "capsule_radius", "focused_color", "occupied_color", "empty_color" },
            values = {
                style = "focus_hint",
                show_labels = false,
                show_icons = false,
                separator = "",
                capsule_radius = 10,
                focused_color = "primary",
                occupied_color = "secondary",
                empty_color = "on_surface_variant",
            },
        },
        widgets = (function()
            local w = make_present_widgets()
            w["widget.notch_clock"] = {
                order = { "type", "format", "show_glyph" },
                values = {
                    type = "clock",
                    format = "{:%H:%M}",
                    show_glyph = false,
                },
            }
            w["widget.media"] = {
                order = { "type", "art_size", "min_length", "max_length", "title_scroll", "hide_when_no_media" },
                values = {
                    type = "media",
                    art_size = 16.0,
                    min_length = 60.0,
                    max_length = 140.0,
                    title_scroll = "none",
                    hide_when_no_media = true,
                },
            }
            w["widget.record"] = {
                order = { "type", "enabled", "glyph", "icon_color", "label", "tooltip" },
                values = {
                    type = "custom_button",
                    enabled = false,
                    glyph = "video",
                    icon_color = "on_surface_variant",
                    label = "",
                    tooltip = "Screen Recorder (Left: Menu, Right: Toggle)",
                },
            }
            return w
        end)(),
        notification = make_notif("top_center", 1.5, 0, 8),
        osd = make_notif("top_center", 1.5, 0, 8),
        hypr = {
            gaps_in = 5,
            gaps_out = 8,
            border_size = 2,
            rounding = 10,
            shadow = false,
            blur = { enabled = true, size = 4, passes = 2, xray = true },
            tui_drawer_x = 12,
            ghost_super_peek = false,
        },
        gtk = { kind = "soft" },
    },

    ["glass-studio"] = {
        id = "glass-studio",
        group = "dynamic",
        title = "Glass Studio",
        summary = "macOS-inspired 28px frosted top menu bar + auto-hiding bottom dock",
        shell = make_shell(1.15, true),
        shell_panel = make_panel(1.0, true, "glass", {
            control_center_placement = "floating",
            wallpaper_placement = "floating",
        }),
        bar_order = { "default" },
        bar_default = make_bar({
            position = "top",
            thickness = 28,
            padding = 10,
            widget_spacing = 8,
            margin_edge = 0,
            margin_ends = 0,
            background_opacity = 0.62,
            compositor_blur = true,
            border = "outline_variant",
            border_width = 1.0,
            radius = 0,
            start = { "launcher", "active_window" },
            center = { "hclock" },
            ["end"] = { "record", "present", "tray", "net", "vol", "bat", "theme", "notifications", "control-center" },
        }),
        capsule_groups = {},
        dock = {
            order = {
                "enabled", "position", "auto_hide",
                "smart_auto_hide", "reserve_space", "background_opacity",
                "radius", "icon_size", "magnification", "magnification_scale",
                "pinned",
            },
            values = {
                enabled = true,
                position = "bottom",
                auto_hide = true,
                smart_auto_hide = false,
                reserve_space = false,
                background_opacity = 0.68,
                radius = 16,
                icon_size = 42,
                magnification = true,
                magnification_scale = 1.35,
                pinned = { "foot", "thunar" },
            },
            preserve_if_present = { pinned = true },
        },
        widget_ws = {
            order = { "style", "show_labels", "show_icons", "separator", "capsule_radius", "focused_color", "occupied_color", "empty_color" },
            values = {
                style = "regular",
                show_labels = true,
                show_icons = true,
                separator = "",
                capsule_radius = 10,
                focused_color = "primary",
                occupied_color = "secondary",
                empty_color = "surface_container",
            },
        },
        widgets = (function()
            local w = make_present_widgets()
            w["widget.active_window"] = {
                order = { "type", "display", "icon_size", "min_length", "max_length", "title_scroll", "show_empty_label", "empty_label" },
                values = {
                    type = "active_window",
                    display = "icon_and_text",
                    icon_size = 14,
                    min_length = 80,
                    max_length = 240,
                    title_scroll = "on_hover",
                    show_empty_label = true,
                    empty_label = "Desktop",
                },
            }
            w["widget.record"] = {
                order = { "type", "enabled", "glyph", "icon_color", "label", "tooltip" },
                values = {
                    type = "custom_button",
                    enabled = true,
                    glyph = "video",
                    icon_color = "on_surface_variant",
                    label = "",
                    tooltip = "Screen Recorder (Left: Menu, Right: Toggle)",
                },
            }
            return w
        end)(),
        notification = make_notif("top_right", 1.0, 14, 14),
        osd = make_notif("top_center", 1.0, 0, 14),
        hypr = {
            gaps_in = 6,
            gaps_out = 10,
            border_size = 1,
            rounding = 14,
            shadow = { enabled = true, range = 20, render_power = 3, color = "rgba(00000038)" },
            blur = { enabled = true, size = 7, passes = 3, xray = false },
            tui_drawer_x = 12,
            ghost_super_peek = false,
        },
        gtk = { kind = "glass" },
    },

    ["floating-rail"] = {
        id = "floating-rail",
        group = "dynamic",
        title = "Floating Rail",
        summary = "Two-tier floating pills: top active window + clock, left workspace + app rail",
        shell = make_shell(1.0, true),
        shell_panel = make_panel(1.5, true, "soft", {
            control_center_placement = "floating",
            wallpaper_placement = "floating",
        }),
        bar_order = { "default", "rail" },
        bar_default = make_bar({
            position = "top",
            thickness = 32,
            padding = 4,
            widget_spacing = 6,
            margin_edge = 8,
            margin_ends = 12,
            background_opacity = 0.0,
            compositor_blur = false,
            border = "outline_variant",
            border_width = 0.0,
            radius = 0,
            start = {},
            center = { "group:top_pill" },
            ["end"] = {},
        }),
        capsule_groups = {
            {
                id = "top_pill",
                members = { "active_window", "hclock", "record", "present", "net", "vol", "bat", "theme", "notifications" },
                fill = "surface_container",
                border = "outline_variant",
                border_width = 1.5,
                radius = 16,
                padding = 8.0,
                widget_spacing = 8.0,
                opacity = 0.94,
            },
        },
        bar_rail = make_bar({
            position = "left",
            thickness = 46,
            padding = 4,
            widget_spacing = 6,
            margin_edge = 10,
            margin_ends = 0,
            reserve_space = true,
            background_opacity = 0.0,
            compositor_blur = false,
            border = "outline_variant",
            border_width = 0.0,
            radius = 0,
            start = {},
            center = { "group:rail_pill" },
            ["end"] = {},
        }),
        rail_capsule_groups = {
            {
                id = "rail_pill",
                members = { "launcher", "ws", "rail_term", "rail_files", "control-center" },
                fill = "surface_container",
                border = "outline_variant",
                border_width = 1.5,
                radius = 18,
                padding = 6.0,
                widget_spacing = 6.0,
                opacity = 0.94,
            },
        },
        dock = {
            order = { "enabled" },
            values = { enabled = false },
        },
        widget_ws = {
            order = { "style", "show_labels", "show_icons", "separator", "capsule_radius", "focused_color", "occupied_color", "empty_color" },
            values = {
                style = "regular",
                show_labels = true,
                show_icons = true,
                separator = "",
                capsule_radius = 12,
                focused_color = "primary",
                occupied_color = "secondary",
                empty_color = "surface_container",
            },
        },
        widgets = (function()
            local w = make_present_widgets()
            w["widget.active_window"] = {
                order = { "type", "display", "icon_size", "min_length", "max_length", "title_scroll", "show_empty_label", "empty_label" },
                values = {
                    type = "active_window",
                    display = "icon_and_text",
                    icon_size = 15,
                    min_length = 80,
                    max_length = 220,
                    title_scroll = "on_hover",
                    show_empty_label = true,
                    empty_label = "Desktop",
                },
            }
            w["widget.record"] = {
                order = { "type", "enabled", "glyph", "icon_color", "label", "tooltip" },
                values = {
                    type = "custom_button",
                    enabled = true,
                    glyph = "video",
                    icon_color = "on_surface_variant",
                    label = "",
                    tooltip = "Screen Recorder (Left: Menu, Right: Toggle)",
                },
            }
            w["widget.rail_term"] = {
                order = { "type", "glyph", "icon_color", "tooltip" },
                values = {
                    type = "custom_button",
                    glyph = "terminal-2",
                    icon_color = "on_surface_variant",
                    tooltip = "Terminal (Foot)",
                },
            }
            w["widget.rail_term.actions"] = {
                order = { "left" },
                values = { left = "exec kaze-footclient -N" },
            }
            w["widget.rail_files"] = {
                order = { "type", "glyph", "icon_color", "tooltip" },
                values = {
                    type = "custom_button",
                    glyph = "folder",
                    icon_color = "on_surface_variant",
                    tooltip = "Files (Thunar)",
                },
            }
            w["widget.rail_files.actions"] = {
                order = { "left" },
                values = { left = "exec thunar" },
            }
            return w
        end)(),
        notification = make_notif("top_right", 1.5, 12, 12),
        osd = make_notif("top_center", 1.5, 0, 12),
        hypr = {
            gaps_in = 8,
            gaps_out = 12,
            border_size = 2,
            rounding = 12,
            shadow = { enabled = true, range = 14, render_power = 3, color = "rgba(00000033)" },
            blur = { enabled = true, size = 5, passes = 2, xray = true },
            tui_drawer_x = 64,
            ghost_super_peek = false,
        },
        gtk = { kind = "soft" },
    },

    ["tui-hacker"] = {
        id = "tui-hacker",
        group = "retro",
        title = "TUI / Hacker Frame",
        summary = "Monospace terminal frame with [ bracketed ] status and phosphor CRT palette",
        note = "Switch to Kaze-Amber anytime in Noctalia Settings -> Theme if you prefer amber phosphor.",
        theme = {
            mode = "dark",
            source = "custom",
            custom_palette = "Kaze-Phosphor",
            pure_black_dark = false,
        },
        shell = make_shell(0.0, false),
        shell_panel = make_panel(1.0, false, "solid"),
        bar_order = { "default" },
        bar_default = make_bar({
            position = "top",
            thickness = 30,
            padding = 10,
            widget_spacing = 4,
            margin_edge = 0,
            margin_ends = 0,
            font_family = "JetBrainsMono Nerd Font",
            background_opacity = 1.0,
            compositor_blur = false,
            border = "primary",
            border_width = 1.0,
            radius = 0,
            start = { "tui_lbr", "tui_ws_lbl", "ws", "tui_rbr" },
            center = { "tui_lbr", "tui_clock", "tui_rbr" },
            ["end"] = { "tui_lbr", "tui_net", "tui_rbr", "tui_lbr", "tui_vol", "tui_rbr", "tui_bat", "tui_lbr", "tui_theme", "tui_rbr" },
        }),
        capsule_groups = {},
        dock = {
            order = { "enabled" },
            values = { enabled = false },
        },
        widget_ws = {
            order = { "style", "show_labels", "show_icons", "label_source", "separator", "capsule_radius", "focused_color", "occupied_color", "empty_color" },
            values = {
                style = "minimal",
                show_labels = true,
                show_icons = false,
                label_source = "id",
                separator = " ",
                capsule_radius = 0,
                focused_color = "primary",
                occupied_color = "secondary",
                empty_color = "on_surface_variant",
            },
        },
        widgets = {
            ["widget.tui_lbr"] = {
                order = { "type", "text" },
                values = { type = "text", text = "[" },
            },
            ["widget.tui_rbr"] = {
                order = { "type", "text" },
                values = { type = "text", text = "]" },
            },
            ["widget.tui_ws_lbl"] = {
                order = { "type", "text" },
                values = { type = "text", text = "WS " },
            },
            ["widget.tui_clock"] = {
                order = { "type", "format", "show_glyph" },
                values = {
                    type = "clock",
                    format = "{:%H:%M}",
                    show_glyph = false,
                },
            },
            ["widget.tui_net"] = {
                order = { "type", "show_glyph", "show_label", "custom_label" },
                values = {
                    type = "network",
                    show_glyph = false,
                    show_label = true,
                    custom_label = "NET ",
                },
            },
            ["widget.tui_vol"] = {
                order = { "type", "show_glyph", "show_label", "custom_label", "hide_label_when_muted" },
                values = {
                    type = "volume",
                    show_glyph = false,
                    show_label = true,
                    custom_label = "VOL ",
                    hide_label_when_muted = false,
                },
            },
            ["widget.tui_bat"] = {
                order = { "type", "show_glyph", "show_label", "custom_label" },
                values = {
                    type = "battery",
                    show_glyph = false,
                    show_label = true,
                    custom_label = "BAT ",
                },
            },
            ["widget.tui_theme"] = {
                order = { "type", "glyph", "label", "tooltip" },
                values = {
                    type = "custom_button",
                    glyph = "",
                    label = "THEME",
                    tooltip = "Theme Hub (Left: Hub, Right: Visual Styles, Middle: Dark/Light)",
                },
            },
            ["widget.tui_theme.actions"] = {
                order = { "left", "right", "middle" },
                values = {
                    left = "exec kaze-style --hub",
                    right = "exec kaze-style --menu",
                    middle = "exec noctalia msg theme-mode-toggle",
                },
            },
        },
        notification = make_notif("top_right", 1.0, 8, 8),
        osd = make_notif("top_right", 1.0, 8, 8),
        hypr = {
            gaps_in = 2,
            gaps_out = 4,
            border_size = 1,
            rounding = 0,
            shadow = false,
            blur = { enabled = false, size = 3, passes = 1, xray = true },
            tui_drawer_x = 12,
            ghost_super_peek = false,
        },
        gtk = { kind = "sharp" },
    },

    ["retro-90s"] = {
        id = "retro-90s",
        group = "retro",
        title = "Retro 90s / Pixel OS",
        summary = "Win95/BeOS bottom taskbar, Start button, warm gray palette & 2-tone bevel borders",
        theme = {
            mode = "light",
            source = "custom",
            custom_palette = "Kaze-Retro90s",
            pure_black_dark = false,
        },
        shell = make_shell(0.0, false),
        shell_panel = make_panel(2.0, false, "solid", {
            launcher_placement = "attached",
            launcher_position = "bottom_left",
        }),
        bar_order = { "default" },
        bar_default = make_bar({
            position = "bottom",
            thickness = 36,
            padding = 4,
            widget_spacing = 6,
            margin_edge = 0,
            margin_ends = 0,
            font_family = "JetBrainsMono Nerd Font",
            background_opacity = 1.0,
            compositor_blur = false,
            border = "outline_variant",
            border_width = 2.0,
            radius = 0,
            capsule = true,
            capsule_border_width = 2.0,
            start = { "retro_start", "ws", "taskbar" },
            center = {},
            ["end"] = { "record", "tray", "net", "vol", "bat", "theme", "retro_clock" },
        }),
        capsule_groups = {},
        dock = {
            order = { "enabled" },
            values = { enabled = false },
        },
        widget_ws = {
            order = { "style", "show_labels", "show_icons", "separator", "capsule_radius", "focused_color", "occupied_color", "empty_color" },
            values = {
                style = "regular",
                show_labels = true,
                show_icons = true,
                separator = "",
                capsule_radius = 0,
                focused_color = "primary",
                occupied_color = "secondary",
                empty_color = "surface_container",
            },
        },
        widgets = {
            ["widget.retro_start"] = {
                order = { "type", "glyph", "label", "tooltip" },
                values = {
                    type = "custom_button",
                    glyph = "layout-grid",
                    label = "Start",
                    tooltip = "Application Launcher",
                },
            },
            ["widget.retro_start.actions"] = {
                order = { "left" },
                values = { left = "exec noctalia msg panel-toggle launcher" },
            },
            ["widget.taskbar"] = {
                order = { "type", "prefer_symbolic_icons" },
                values = {
                    type = "taskbar",
                    prefer_symbolic_icons = false,
                },
            },
            ["widget.retro_clock"] = {
                order = { "type", "format", "show_glyph" },
                values = {
                    type = "clock",
                    format = "{:%H:%M}",
                    show_glyph = false,
                },
            },
            ["widget.record"] = {
                order = { "type", "enabled", "glyph", "icon_color", "label", "tooltip" },
                values = {
                    type = "custom_button",
                    enabled = true,
                    glyph = "video",
                    icon_color = "on_surface_variant",
                    label = "",
                    tooltip = "Screen Recorder (Left: Menu, Right: Toggle)",
                },
            },
        },
        notification = make_notif("bottom_right", 2.0, 8, 44),
        osd = make_notif("bottom_right", 2.0, 8, 44),
        hypr = {
            gaps_in = 4,
            gaps_out = 6,
            border_size = 3,
            rounding = 0,
            shadow = false,
            blur = { enabled = false, size = 3, passes = 1, xray = true },
            tui_drawer_x = 12,
            ghost_super_peek = false,
            border_override = {
                active = { colors = { "rgba(ffffffdd)", "rgba(404040ee)" }, angle = 45 },
                inactive = { colors = { "rgba(dcdad5cc)", "rgba(686660cc)" }, angle = 45 },
            },
        },
        gtk = { kind = "bevel" },
    },

    ["cinema-frame"] = {
        id = "cinema-frame",
        group = "retro",
        title = "Cinema Frame",
        summary = "Wide gallery margins (28px) with ultra-slim 22px bottom subtitle strip",
        shell = make_shell(0.0, false),
        shell_panel = make_panel(1.0, true, "soft", {
            control_center_placement = "floating",
            wallpaper_placement = "floating",
        }),
        bar_order = { "default" },
        bar_default = make_bar({
            position = "bottom",
            thickness = 22,
            padding = 12,
            widget_spacing = 10,
            margin_edge = 0,
            margin_ends = 0,
            background_opacity = 0.58,
            compositor_blur = true,
            border = "outline_variant",
            border_width = 0.0,
            radius = 0,
            start = { "ws" },
            center = { "cinema_clock" },
            ["end"] = { "media", "record", "theme", "cinema_bat" },
        }),
        capsule_groups = {},
        dock = {
            order = { "enabled" },
            values = { enabled = false },
        },
        widget_ws = {
            order = { "style", "show_labels", "show_icons", "label_source", "separator", "capsule_radius", "focused_color", "occupied_color", "empty_color" },
            values = {
                style = "minimal",
                show_labels = true,
                show_icons = false,
                label_source = "id",
                separator = " · ",
                capsule_radius = 0,
                focused_color = "primary",
                occupied_color = "secondary",
                empty_color = "on_surface_variant",
            },
        },
        widgets = {
            ["widget.cinema_clock"] = {
                order = { "type", "format", "show_glyph" },
                values = {
                    type = "clock",
                    format = "{:%H:%M  ·  %a %d %b}",
                    show_glyph = false,
                },
            },
            ["widget.cinema_bat"] = {
                order = { "type", "show_glyph", "show_label" },
                values = {
                    type = "battery",
                    show_glyph = false,
                    show_label = true,
                },
            },
            ["widget.media"] = {
                order = { "type", "art_size", "min_length", "max_length", "title_scroll", "hide_when_no_media" },
                values = {
                    type = "media",
                    art_size = 14.0,
                    min_length = 60.0,
                    max_length = 160.0,
                    title_scroll = "none",
                    hide_when_no_media = true,
                },
            },
            ["widget.record"] = {
                order = { "type", "enabled", "glyph", "icon_color", "label", "tooltip" },
                values = {
                    type = "custom_button",
                    enabled = false,
                    glyph = "video",
                    icon_color = "on_surface_variant",
                    label = "",
                    tooltip = "Screen Recorder (Left: Menu, Right: Toggle)",
                },
            },
        },
        notification = make_notif("bottom_right", 1.0, 28, 32),
        osd = make_notif("bottom_right", 1.0, 28, 32),
        hypr = {
            gaps_in = 12,
            gaps_out = 28,
            border_size = 1,
            rounding = 0,
            shadow = { enabled = true, range = 24, render_power = 3, color = "rgba(00000040)" },
            blur = { enabled = true, size = 4, passes = 2, xray = true },
            tui_drawer_x = 28,
            ghost_super_peek = false,
        },
        gtk = { kind = "sharp" },
    },
}

local EXTRA_WIDGETS = {
    {
        name = "widget.hclock",
        lines = {
            "[widget.hclock]",
            'type = "clock"',
            'format = "{:%a %d %b · %H:%M}"',
        },
    },
    {
        name = "widget.media",
        lines = {
            "[widget.media]",
            'type = "media"',
            "art_size = 16.0",
            "min_length = 80.0",
            "max_length = 180.0",
            'title_scroll = "none"',
        },
    },
    {
        name = "widget.mirror",
        lines = {
            "[widget.mirror]",
            'type = "custom_button"',
            'glyph = "server"',
            'icon_color = "on_surface_variant"',
            'tooltip = "Mirror Optimizer (Left: Menu, Right: TUI)"',
        },
    },
    {
        name = "widget.mirror.actions",
        lines = {
            "[widget.mirror.actions]",
            'left = "exec kaze-mirror --menu"',
            'right = "exec kaze-mirror --tui-window"',
        },
    },
    {
        name = "widget.theme",
        lines = {
            "[widget.theme]",
            'type = "custom_button"',
            'glyph = "palette"',
            'icon_color = "on_surface_variant"',
            'tooltip = "Theme Hub (Left: Hub, Right: Visual Styles, Middle: Dark/Light)"',
        },
    },
    {
        name = "widget.theme.actions",
        lines = {
            "[widget.theme.actions]",
            'left = "exec kaze-style --hub"',
            'right = "exec kaze-style --menu"',
            'middle = "exec noctalia msg theme-mode-toggle"',
        },
    },
}

-- Preset-only widget sections removed when switching to a preset that does not declare them.
local MANAGED_PRESET_WIDGETS = {
    ["widget.present"] = true,
    ["widget.present.actions"] = true,
    ["widget.active_window"] = true,
    ["widget.taskbar"] = true,
    ["widget.swiss_clock"] = true,
    ["widget.swiss_net"] = true,
    ["widget.swiss_vol"] = true,
    ["widget.swiss_bat"] = true,
    ["widget.swiss_sep"] = true,
    ["widget.swiss_theme"] = true,
    ["widget.swiss_theme.actions"] = true,
    ["widget.island_clock"] = true,
    ["widget.bt"] = true,
    ["widget.notch_clock"] = true,
    ["widget.rail_term"] = true,
    ["widget.rail_term.actions"] = true,
    ["widget.rail_files"] = true,
    ["widget.rail_files.actions"] = true,
    ["widget.tui_lbr"] = true,
    ["widget.tui_rbr"] = true,
    ["widget.tui_ws_lbl"] = true,
    ["widget.tui_clock"] = true,
    ["widget.tui_net"] = true,
    ["widget.tui_vol"] = true,
    ["widget.tui_bat"] = true,
    ["widget.tui_theme"] = true,
    ["widget.tui_theme.actions"] = true,
    ["widget.retro_start"] = true,
    ["widget.retro_start.actions"] = true,
    ["widget.retro_clock"] = true,
    ["widget.cinema_clock"] = true,
    ["widget.cinema_bat"] = true,
}

local CAP_ORDER = {
    "id",
    "members",
    "fill",
    "border",
    "border_width",
    "radius",
    "padding",
    "widget_spacing",
    "opacity",
    "accordion",
    "accordion_direction",
    "accordion_duration",
    "accordion_delay_ms",
}

local function escape_toml_str(s)
    return s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
end

local function format_num(val, is_float, is_int)
    if is_int then
        return string.format("%d", math.floor(val + 0.5))
    end
    if is_float then
        if val == math.floor(val) then
            return string.format("%.1f", val)
        end
        return tostring(val)
    end
    return tostring(val)
end

local function format_value(key, val, float_map, int_map)
    local t = type(val)
    if t == "boolean" then
        return val and "true" or "false"
    elseif t == "string" then
        return '"' .. escape_toml_str(val) .. '"'
    elseif t == "number" then
        return format_num(val, float_map and float_map[key], int_map and int_map[key])
    elseif t == "table" then
        if #val == 0 then
            return "[]"
        end
        local items = {}
        for i = 1, #val do
            items[i] = '"' .. escape_toml_str(tostring(val[i])) .. '"'
        end
        return "[ " .. table.concat(items, ", ") .. " ]"
    end
    error("unsupported TOML value type for key '" .. tostring(key) .. "': " .. t)
end

--- Track TOML multiline string and array nesting across lines so headers
--- inside multiline values are never treated as new sections.
local function scan_line_state(line, state)
    local i, len = 1, #line
    local ml = state.ml
    local depth = state.depth
    local q = nil

    while i <= len do
        local c = line:sub(i, i)
        if ml then
            if line:sub(i, i + 2) == ml then
                ml = nil
                i = i + 3
            elseif ml == '"""' and c == "\\" then
                i = i + 2
            else
                i = i + 1
            end
        elseif q then
            if q == '"' and c == "\\" then
                i = i + 2
            elseif c == q then
                q = nil
                i = i + 1
            else
                i = i + 1
            end
        else
            if c == "#" then
                break
            elseif line:sub(i, i + 2) == '"""' or line:sub(i, i + 2) == "'''" then
                ml = line:sub(i, i + 2)
                i = i + 3
            elseif c == '"' or c == "'" then
                q = c
                i = i + 1
            elseif c == "[" or c == "{" then
                depth = depth + 1
                i = i + 1
            elseif c == "]" or c == "}" then
                if depth > 0 then
                    depth = depth - 1
                end
                i = i + 1
            else
                i = i + 1
            end
        end
    end

    return { ml = ml, depth = depth }
end

local function parse_header_line(line)
    local no_comment = line:gsub("#.*$", "")
    local arr = no_comment:match("^%s*%[%[%s*([^%]]-)%s*%]%]%s*$")
    if arr and arr ~= "" then
        return arr, true
    end
    local sec = no_comment:match("^%s*%[%s*([^%[%]]-)%s*%]%s*$")
    if sec and sec ~= "" then
        return sec, false
    end
    return nil, false
end

local function split_lines(text)
    local lines = {}
    local pos = 1
    while pos <= #text do
        local nl = text:find("\n", pos, true)
        if nl then
            lines[#lines + 1] = text:sub(pos, nl - 1):gsub("\r$", "")
            pos = nl + 1
        else
            lines[#lines + 1] = text:sub(pos):gsub("\r$", "")
            break
        end
    end
    return lines
end

local function split_blocks(text)
    local lines = split_lines(text)
    local blocks = {}
    local cur = { sec = nil, is_array = false, lines = {} }
    local state = { ml = nil, depth = 0 }

    for _, line in ipairs(lines) do
        if not state.ml and state.depth == 0 then
            local sec, is_arr = parse_header_line(line)
            if sec then
                if cur.sec ~= nil or #cur.lines > 0 then
                    blocks[#blocks + 1] = cur
                end
                cur = { sec = sec, is_array = is_arr, lines = { line } }
                state = scan_line_state(line, state)
                state.depth = 0
                goto continue
            end
        end
        cur.lines[#cur.lines + 1] = line
        state = scan_line_state(line, state)
        ::continue::
    end
    if cur.sec ~= nil or #cur.lines > 0 then
        blocks[#blocks + 1] = cur
    end
    return blocks
end

local function patch_section_block(block, spec, drop_keys)
    local out = {}
    local seen = {}
    local existing_keys = {}
    local state = { ml = nil, depth = 0 }
    local lines = block.lines
    local i = 1

    if #lines > 0 and block.sec ~= nil then
        out[#out + 1] = lines[1]
        i = 2
    end

    while i <= #lines do
        local line = lines[i]
        if not state.ml and state.depth == 0 then
            local key = line:match("^%s*([A-Za-z0-9_%-]+)%s*=")
            if key then
                existing_keys[key] = true
            end
            local preserve = spec.preserve_if_present and spec.preserve_if_present[key]
            if key and not preserve and (spec.values[key] ~= nil or (drop_keys and drop_keys[key])) then
                local st = scan_line_state(line, state)
                while (st.ml ~= nil or st.depth > 0) and i < #lines do
                    i = i + 1
                    st = scan_line_state(lines[i], st)
                end
                state = st
                if spec.values[key] ~= nil and not seen[key] then
                    out[#out + 1] = key .. " = " .. format_value(key, spec.values[key], FLOAT_KEYS, INT_KEYS)
                    seen[key] = true
                end
                i = i + 1
                goto next_stmt
            end
        end
        out[#out + 1] = line
        state = scan_line_state(line, state)
        i = i + 1
        ::next_stmt::
    end

    local trailing_blanks = {}
    while #out > 1 and out[#out]:match("^%s*$") do
        trailing_blanks[#trailing_blanks + 1] = table.remove(out)
    end
    for _, key in ipairs(spec.order) do
        local skip_preserve = spec.preserve_if_present and spec.preserve_if_present[key] and existing_keys[key]
        if not skip_preserve and spec.values[key] ~= nil and not seen[key] then
            out[#out + 1] = key .. " = " .. format_value(key, spec.values[key], FLOAT_KEYS, INT_KEYS)
            seen[key] = true
        end
    end
    for j = #trailing_blanks, 1, -1 do
        out[#out + 1] = trailing_blanks[j]
    end

    block.lines = out
end

local function build_section_block(sec, spec)
    local lines = { "[" .. sec .. "]" }
    for _, key in ipairs(spec.order) do
        local val = spec.values[key]
        if val ~= nil then
            lines[#lines + 1] = key .. " = " .. format_value(key, val, FLOAT_KEYS, INT_KEYS)
        end
    end
    return { sec = sec, is_array = false, lines = lines }
end

local function build_capsule_group_block(sec_name, group)
    local lines = { "[[" .. sec_name .. "]]" }
    for _, key in ipairs(CAP_ORDER) do
        if group[key] ~= nil then
            lines[#lines + 1] = key .. " = " .. format_value(key, group[key], CAP_FLOAT_KEYS, CAP_INT_KEYS)
        end
    end
    return { sec = sec_name, is_array = true, lines = lines }
end

local function ensure_trailing_blank(block)
    if #block.lines > 0 and not block.lines[#block.lines]:match("^%s*$") then
        block.lines[#block.lines + 1] = ""
    end
end

function M.resolve(name)
    if type(name) ~= "string" then
        return nil
    end
    if M.PRESETS[name] then
        return name
    end
    local canonical = M.ALIASES[name]
    if canonical and M.PRESETS[canonical] then
        return canonical
    end
    return nil
end

function M.is_valid(name)
    return M.resolve(name) ~= nil
end

function M.get(name)
    local canonical = M.resolve(name)
    return canonical and M.PRESETS[canonical] or nil
end

function M.list()
    local items = {}
    for _, id in ipairs(M.ORDER) do
        items[#items + 1] = M.PRESETS[id]
    end
    return items
end

function M.groups()
    local out = {}
    for _, g in ipairs(M.GROUPS) do
        local presets = {}
        for _, id in ipairs(g.items) do
            presets[#presets + 1] = M.PRESETS[id]
        end
        out[#out + 1] = {
            id = g.id,
            title = g.title,
            items = presets,
        }
    end
    return out
end

function M.bar_names(style_name)
    local preset = M.get(style_name) or M.PRESETS[M.DEFAULT]
    local names = {}
    local src = (preset and preset.bar_order) or { "default" }
    for i = 1, #src do
        names[i] = src[i]
    end
    return names
end

function M.state_file(opts)
    if opts and opts.state_file then
        return opts.state_file
    end
    return fs.config_dir() .. "/kaze/style"
end

function M.theme_backup_file(opts)
    if opts and opts.theme_backup_path then
        return opts.theme_backup_path
    end
    return fs.config_dir() .. "/kaze/saved-theme.json"
end

function M.hypr_style_file(opts)
    if opts and opts.hypr_style_path then
        return opts.hypr_style_path
    end
    return fs.config_dir() .. "/hypr/kaze-style.lua"
end

function M.gtk_style_file(opts)
    if opts and opts.gtk_style_path then
        return opts.gtk_style_path
    end
    return fs.config_dir() .. "/gtk-3.0/kaze-style.css"
end

function M.noctalia_state_file(opts)
    if opts and opts.noctalia_state_path then
        return opts.noctalia_state_path
    end
    local state_home = os.getenv("XDG_STATE_HOME")
    if not state_home or state_home == "" then
        state_home = fs.home() .. "/.local/state"
    end
    return state_home .. "/noctalia/settings.toml"
end

function M.read_style(opts)
    local path = M.state_file(opts)
    local raw = fs.read_file(path)
    if not raw then
        return M.DEFAULT, false
    end
    local trimmed = raw:match("^%s*(.-)%s*$")
    if trimmed == "" then
        return M.DEFAULT, false
    end
    local resolved = M.resolve(trimmed)
    if not resolved then
        return nil, string.format("invalid saved style '%s' in %s", trimmed, path)
    end
    return resolved, true
end

function M.detect_style(toml_text)
    if type(toml_text) ~= "string" or toml_text == "" then
        return nil
    end
    if toml_text:find("%[bar%.rail%]") then
        return "floating-rail"
    end
    if toml_text:find('id%s*=%s*"island"') then
        return "dynamic-island"
    end
    if toml_text:find('id%s*=%s*"corner_left"')
        or (toml_text:find('id%s*=%s*"left"') and toml_text:find('id%s*=%s*"right"')) then
        return "corner-hud"
    end
    if toml_text:find("concave_edge_corners%s*=%s*true") then
        return "hardware-notch"
    end
    if toml_text:find("%[dock%][^%[]-enabled%s*=%s*true") then
        return "glass-studio"
    end
    if toml_text:find("auto_hide%s*=%s*true") and toml_text:find("reserve_space%s*=%s*false") then
        return "ghost-zero"
    end
    if toml_text:find('custom_palette%s*=%s*"Kaze%-Swiss"') then
        return "swiss-grid"
    end
    if toml_text:find('custom_palette%s*=%s*"Kaze%-Phosphor"') then
        return "tui-hacker"
    end
    if toml_text:find('custom_palette%s*=%s*"Kaze%-Retro90s"') then
        return "retro-90s"
    end
    if toml_text:find("cinema_clock") then
        return "cinema-frame"
    end
    if toml_text:find('position%s*=%s*"left"') then
        return "omarchy-rail"
    end
    return nil
end

function M.current_style(opts)
    local style, err = M.read_style(opts)
    if not style then
        return nil, err
    end
    return style
end

local function unquote_toml_str(raw)
    local inner = raw:match('^"(.*)"$')
    if not inner then
        return nil
    end
    return (inner:gsub('\\(["\\])', "%1"))
end

function M.extract_theme(toml_text)
    if type(toml_text) ~= "string" then
        return {}
    end
    local blocks = split_blocks(toml_text)
    for _, blk in ipairs(blocks) do
        if not blk.is_array and blk.sec == "theme" then
            local out = {}
            for i = 2, #blk.lines do
                local k, v = blk.lines[i]:match("^%s*([A-Za-z0-9_%-]+)%s*=%s*(.-)%s*$")
                if k and (k == "mode" or k == "source" or k == "builtin" or k == "custom_palette" or k == "pure_black_dark") then
                    v = v:gsub("%s+#.*$", "")
                    if v == "true" then
                        out[k] = true
                    elseif v == "false" then
                        out[k] = false
                    else
                        local s = unquote_toml_str(v)
                        if s ~= nil then
                            out[k] = s
                        end
                    end
                end
            end
            return out
        end
    end
    return {}
end

local function themes_equal(a, b)
    for _, k in ipairs({ "mode", "source", "builtin", "custom_palette", "pure_black_dark" }) do
        if a[k] ~= b[k] then
            return false
        end
    end
    return true
end

local function make_theme_spec(theme_tbl)
    local order = {}
    local values = {}
    for _, k in ipairs({ "mode", "source", "builtin", "custom_palette", "pure_black_dark" }) do
        if theme_tbl[k] ~= nil then
            order[#order + 1] = k
            values[k] = theme_tbl[k]
        end
    end
    return { order = order, values = values }
end

--- Return an updated Noctalia config.toml string for the given style preset
--- while preserving user settings outside style-managed keys.
function M.render_config(toml_text, style_name, opts)
    opts = opts or {}
    local resolved = M.resolve(style_name)
    local preset = resolved and M.PRESETS[resolved] or nil
    if not preset then
        return nil, "unknown style preset: " .. tostring(style_name)
    end
    if type(toml_text) ~= "string" then
        return nil, "expected config.toml text"
    end

    local blocks = split_blocks(toml_text)
    local filtered = {}
    local seen_sec = {}

    local theme_spec = nil
    local drop_theme_keys = nil
    if preset.theme then
        theme_spec = make_theme_spec(preset.theme)
    elseif type(opts.restore_theme) == "table" and next(opts.restore_theme) ~= nil then
        theme_spec = make_theme_spec(opts.restore_theme)
        if opts.restore_theme.custom_palette == nil then
            drop_theme_keys = { custom_palette = true }
        end
    end

    local section_specs = {
        ["shell"] = { spec = preset.shell },
        ["shell.panel"] = { spec = preset.shell_panel },
        ["bar"] = { spec = { order = { "order" }, values = { order = preset.bar_order or { "default" } } } },
        ["bar.default"] = { spec = preset.bar_default, drop = preset.bar_default.drop or { capsule_group = true } },
        ["widget.ws"] = { spec = preset.widget_ws, drop = preset.widget_ws.drop },
        ["dock"] = { spec = preset.dock, drop = { auto_hide_delay_ms = true } },
        ["notification"] = { spec = preset.notification },
        ["osd"] = { spec = preset.osd },
    }
    if theme_spec then
        section_specs["theme"] = { spec = theme_spec, drop = drop_theme_keys }
    end
    if preset.bar_rail then
        section_specs["bar.rail"] = { spec = preset.bar_rail, drop = { capsule_group = true } }
    end
    local preset_widgets = preset.widgets or {}
    for sec_name, spec in pairs(preset_widgets) do
        section_specs[sec_name] = { spec = spec, drop = spec.drop }
    end

    for _, blk in ipairs(blocks) do
        if blk.is_array and (blk.sec == "bar.default.capsule_group" or blk.sec == "bar.rail.capsule_group") then
            -- Replace all existing capsule_group tables with the active preset's list.
        elseif not blk.is_array and blk.sec == "bar.rail" and not preset.bar_rail then
            -- Drop bar.rail when switching to single-bar presets.
        elseif not blk.is_array and blk.sec and MANAGED_PRESET_WIDGETS[blk.sec] and not preset_widgets[blk.sec] then
            -- Drop helper widgets owned strictly by other presets.
        else
            if not blk.is_array and blk.sec and section_specs[blk.sec] then
                patch_section_block(blk, section_specs[blk.sec].spec, section_specs[blk.sec].drop)
                seen_sec[blk.sec] = true
            elseif not blk.is_array and blk.sec then
                seen_sec[blk.sec] = true
            end
            filtered[#filtered + 1] = blk
        end
    end

    local function insert_after(target_sec, new_blocks)
        if #new_blocks == 0 then
            return
        end
        local pos = #filtered + 1
        for idx, blk in ipairs(filtered) do
            if not blk.is_array and blk.sec == target_sec then
                pos = idx + 1
                ensure_trailing_blank(blk)
                break
            end
        end
        for offset, nb in ipairs(new_blocks) do
            ensure_trailing_blank(nb)
            table.insert(filtered, pos + offset - 1, nb)
        end
    end

    local function insert_before(target_sec, new_block)
        local pos = #filtered + 1
        for idx, blk in ipairs(filtered) do
            if not blk.is_array and blk.sec == target_sec then
                pos = idx
                break
            end
        end
        if pos > 1 then
            ensure_trailing_blank(filtered[pos - 1])
        end
        ensure_trailing_blank(new_block)
        table.insert(filtered, pos, new_block)
    end

    if not seen_sec["shell"] then
        insert_before("bar.default", build_section_block("shell", preset.shell))
    end
    if not seen_sec["shell.panel"] then
        insert_after("shell", { build_section_block("shell.panel", preset.shell_panel) })
    end
    if theme_spec and not seen_sec["theme"] then
        insert_before("bar", build_section_block("theme", theme_spec))
    end
    if not seen_sec["bar"] then
        insert_before("bar.default", build_section_block("bar", section_specs["bar"].spec))
    end
    if not seen_sec["bar.default"] then
        insert_after("bar", { build_section_block("bar.default", preset.bar_default) })
    end

    if #(preset.capsule_groups or {}) > 0 then
        local cap_blocks = {}
        for _, grp in ipairs(preset.capsule_groups) do
            cap_blocks[#cap_blocks + 1] = build_capsule_group_block("bar.default.capsule_group", grp)
        end
        insert_after("bar.default", cap_blocks)
    end

    if preset.bar_rail then
        if not seen_sec["bar.rail"] then
            local anchor = "bar.default"
            for _, blk in ipairs(filtered) do
                if blk.is_array and blk.sec == "bar.default.capsule_group" then
                    anchor = nil
                end
            end
            if anchor then
                insert_after("bar.default", { build_section_block("bar.rail", preset.bar_rail) })
            else
                local last_cap = #filtered + 1
                for idx, blk in ipairs(filtered) do
                    if blk.is_array and blk.sec == "bar.default.capsule_group" then
                        last_cap = idx + 1
                    end
                end
                if last_cap > 1 then
                    ensure_trailing_blank(filtered[last_cap - 1])
                end
                local nb = build_section_block("bar.rail", preset.bar_rail)
                ensure_trailing_blank(nb)
                table.insert(filtered, last_cap, nb)
            end
        end
        if #(preset.rail_capsule_groups or {}) > 0 then
            local rcap_blocks = {}
            for _, grp in ipairs(preset.rail_capsule_groups) do
                rcap_blocks[#rcap_blocks + 1] = build_capsule_group_block("bar.rail.capsule_group", grp)
            end
            insert_after("bar.rail", rcap_blocks)
        end
    end

    if not seen_sec["widget.ws"] then
        insert_after("bar.default", { build_section_block("widget.ws", preset.widget_ws) })
    end

    for _, w in ipairs(EXTRA_WIDGETS) do
        if not seen_sec[w.name] then
            if section_specs[w.name] then
                insert_before("notification", build_section_block(w.name, section_specs[w.name].spec))
            else
                local copy_lines = {}
                for i = 1, #w.lines do
                    copy_lines[i] = w.lines[i]
                end
                insert_before("notification", { sec = w.name, is_array = false, lines = copy_lines })
            end
            seen_sec[w.name] = true
        end
    end

    local preset_widget_names = {}
    for sec_name in pairs(preset_widgets) do
        if not seen_sec[sec_name] then
            preset_widget_names[#preset_widget_names + 1] = sec_name
        end
    end
    table.sort(preset_widget_names)
    for _, sec_name in ipairs(preset_widget_names) do
        insert_before("notification", build_section_block(sec_name, preset_widgets[sec_name]))
        seen_sec[sec_name] = true
    end

    if not seen_sec["dock"] then
        insert_before("notification", build_section_block("dock", preset.dock))
    end

    for _, tail_sec in ipairs({ "notification", "osd" }) do
        if not seen_sec[tail_sec] then
            local spec = section_specs[tail_sec].spec
            local nb = build_section_block(tail_sec, spec)
            if #filtered > 0 then
                ensure_trailing_blank(filtered[#filtered])
            end
            filtered[#filtered + 1] = nb
        end
    end

    local rendered_lines = {}
    for _, blk in ipairs(filtered) do
        for _, ln in ipairs(blk.lines) do
            rendered_lines[#rendered_lines + 1] = ln
        end
    end
    while #rendered_lines > 0 and rendered_lines[#rendered_lines]:match("^%s*$") do
        table.remove(rendered_lines)
    end
    return table.concat(rendered_lines, "\n") .. "\n"
end

function M.render_template_for_style(base_template_text, style_name)
    local name = M.resolve(style_name or M.DEFAULT)
    if not name then
        return base_template_text
    end
    return M.render_config(base_template_text, name)
end

function M.render_hypr_lua(style_name)
    local resolved = M.resolve(style_name)
    local preset = resolved and M.PRESETS[resolved] or nil
    if not preset then
        return nil, "unknown style preset: " .. tostring(style_name)
    end
    local h = preset.hypr or {}
    local lines = {
        string.format("-- Generated by kaze-style for preset '%s'. Use ~/.config/hypr/user.lua for personal overrides.", preset.id),
        "return {",
        string.format("    gaps_in = %d,", math.floor(tonumber(h.gaps_in) or 4)),
        string.format("    gaps_out = %d,", math.floor(tonumber(h.gaps_out) or 8)),
        string.format("    border_size = %d,", math.floor(tonumber(h.border_size) or 2)),
        string.format("    rounding = %d,", math.floor(tonumber(h.rounding) or 0)),
        string.format("    tui_drawer_x = %d,", math.floor(tonumber(h.tui_drawer_x) or 58)),
        string.format("    ghost_super_peek = %s,", h.ghost_super_peek == true and "true" or "false"),
    }
    if type(h.blur) == "table" then
        lines[#lines + 1] = "    blur = {"
        lines[#lines + 1] = string.format("        enabled = %s,", h.blur.enabled ~= false and "true" or "false")
        lines[#lines + 1] = string.format("        size = %d,", math.floor(tonumber(h.blur.size) or 3))
        lines[#lines + 1] = string.format("        passes = %d,", math.floor(tonumber(h.blur.passes) or 1))
        lines[#lines + 1] = string.format("        xray = %s,", h.blur.xray ~= false and "true" or "false")
        lines[#lines + 1] = "    },"
    end
    if type(h.shadow) == "table" then
        lines[#lines + 1] = "    shadow = {"
        lines[#lines + 1] = string.format("        enabled = %s,", h.shadow.enabled == true and "true" or "false")
        if h.shadow.range ~= nil then
            lines[#lines + 1] = string.format("        range = %d,", math.floor(tonumber(h.shadow.range)))
        end
        if h.shadow.render_power ~= nil then
            lines[#lines + 1] = string.format("        render_power = %d,", math.floor(tonumber(h.shadow.render_power)))
        end
        if type(h.shadow.color) == "string" and h.shadow.color ~= "" then
            lines[#lines + 1] = string.format("        color = %q,", h.shadow.color)
        end
        lines[#lines + 1] = "    },"
    else
        lines[#lines + 1] = string.format("    shadow = %s,", h.shadow == true and "true" or "false")
    end
    local function format_border_val(val)
        if type(val) == "string" then
            return string.format("%q", val)
        elseif type(val) == "table" and type(val.colors) == "table" then
            local cs = {}
            for i = 1, #val.colors do
                cs[i] = string.format("%q", tostring(val.colors[i]))
            end
            if val.angle ~= nil then
                return string.format("{ colors = { %s }, angle = %d }", table.concat(cs, ", "), math.floor(tonumber(val.angle) or 0))
            end
            return string.format("{ colors = { %s } }", table.concat(cs, ", "))
        end
        return nil
    end
    if type(h.border_override) == "table" then
        lines[#lines + 1] = "    border_override = {"
        local act = format_border_val(h.border_override.active)
        if act then
            lines[#lines + 1] = string.format("        active = %s,", act)
        end
        local inact = format_border_val(h.border_override.inactive)
        if inact then
            lines[#lines + 1] = string.format("        inactive = %s,", inact)
        end
        lines[#lines + 1] = "    },"
    end
    lines[#lines + 1] = "}"
    return table.concat(lines, "\n") .. "\n"
end

function M.render_gtk_css(style_name)
    local resolved = M.resolve(style_name)
    local preset = resolved and M.PRESETS[resolved] or nil
    if not preset then
        return nil, "unknown style preset: " .. tostring(style_name)
    end
    local kind = (preset.gtk and preset.gtk.kind) or "sharp"
    local hdr = string.format("/* Generated by kaze-style for '%s' (uses Noctalia @define-color only; 0 hardcoded hex) */\n", preset.id)

    if kind == "bevel" then
        return hdr .. [[
window.thunar,
window.thunar *,
menu,
.menu,
.context-menu,
popover,
popover.background,
tooltip,
tooltip.background {
    border-radius: 0px;
}

window.thunar toolbar button,
window.thunar .path-bar button,
window.thunar .location-bar button,
window.thunar treeview header button {
    border-radius: 0px;
    border-style: solid;
    border-width: 2px;
    border-top-color: rgba(255, 255, 255, 0.72);
    border-left-color: rgba(255, 255, 255, 0.72);
    border-right-color: rgba(0, 0, 0, 0.45);
    border-bottom-color: rgba(0, 0, 0, 0.45);
    box-shadow: inset 1px 1px 0 rgba(255, 255, 255, 0.35), inset -1px -1px 0 rgba(0, 0, 0, 0.25);
}

window.thunar toolbar button:active,
window.thunar .path-bar button:checked,
window.thunar entry {
    border-radius: 0px;
    border-style: solid;
    border-width: 2px;
    border-top-color: rgba(0, 0, 0, 0.45);
    border-left-color: rgba(0, 0, 0, 0.45);
    border-right-color: rgba(255, 255, 255, 0.72);
    border-bottom-color: rgba(255, 255, 255, 0.72);
    box-shadow: inset 1px 1px 0 rgba(0, 0, 0, 0.20);
}

menu,
.menu,
.context-menu,
popover,
popover.background {
    border-style: solid;
    border-width: 2px;
    border-top-color: rgba(255, 255, 255, 0.72);
    border-left-color: rgba(255, 255, 255, 0.72);
    border-right-color: rgba(0, 0, 0, 0.50);
    border-bottom-color: rgba(0, 0, 0, 0.50);
    box-shadow: none;
}
]]
    elseif kind == "glass" then
        return hdr .. [[
window.thunar,
menu,
.menu,
.context-menu,
popover,
popover.background {
    border-radius: 10px;
}

window.thunar toolbar button,
window.thunar .path-bar button,
window.thunar .location-bar button,
window.thunar entry,
menu menuitem,
.menu menuitem {
    border-radius: 6px;
}

menu,
.menu,
.context-menu,
popover,
popover.background {
    box-shadow: 0 6px 18px rgba(0, 0, 0, 0.22);
}
]]
    elseif kind == "soft" then
        return hdr .. [[
window.thunar,
menu,
.menu,
.context-menu,
popover,
popover.background {
    border-radius: 8px;
}

window.thunar toolbar button,
window.thunar .path-bar button,
window.thunar .location-bar button,
window.thunar entry,
menu menuitem,
.menu menuitem {
    border-radius: 6px;
}

menu,
.menu,
.context-menu,
popover,
popover.background {
    box-shadow: 0 4px 12px rgba(0, 0, 0, 0.16);
}
]]
    end

    return hdr .. [[
window.thunar,
window.thunar *,
menu,
.menu,
.context-menu,
popover,
popover.background,
tooltip,
tooltip.background {
    border-radius: 0px;
    box-shadow: none;
}
]]
end

local function cmd_exists(cmd)
    local ok = os.execute("command -v " .. fs.shell_quote(cmd) .. " >/dev/null 2>&1")
    return ok == true or ok == 0
end

local function validate_noctalia_text(config_path, text)
    if not cmd_exists("noctalia") then
        return true
    end
    local dir = fs.dirname(config_path)
    local ok_dir, dir_err = fs.mkdir_p(dir)
    if not ok_dir then
        return nil, dir_err
    end
    local probe = dir .. "/.kaze-style-validate.toml"
    local fh, err = io.open(probe, "w")
    if not fh then
        return nil, err
    end
    fh:write(text)
    fh:close()
    local ok_val = os.execute("noctalia config validate " .. fs.shell_quote(probe) .. " >/dev/null 2>&1")
    os.remove(probe)
    if not (ok_val == true or ok_val == 0) then
        return nil, "noctalia config validate rejected rendered style config"
    end
    return true
end

local DYNAMIC_STATE_WIDGETS = {
    ["widget.present"] = true,
    ["widget.present.actions"] = true,
    ["widget.record"] = true,
    ["widget.record.actions"] = true,
}

local function clean_noctalia_state_overrides(state_path)
    local raw = fs.read_file(state_path)
    if not raw or not raw:find("%S") then
        return true
    end
    local blocks = split_blocks(raw)
    local kept = {}
    local changed = false
    for _, blk in ipairs(blocks) do
        if not blk.is_array and blk.sec and DYNAMIC_STATE_WIDGETS[blk.sec] then
            changed = true
        else
            for _, ln in ipairs(blk.lines) do
                kept[#kept + 1] = ln
            end
        end
    end
    if not changed then
        return true
    end
    while #kept > 0 and kept[#kept]:match("^%s*$") do
        table.remove(kept)
    end
    local out = #kept > 0 and (table.concat(kept, "\n") .. "\n") or ""
    return fs.write_atomic(state_path, out)
end

function M.apply(style_name, opts)
    opts = opts or {}
    local resolved = M.resolve(style_name)
    if not resolved then
        return nil, string.format("unknown visual style '%s' (expected: %s)", tostring(style_name), table.concat(M.ORDER, ", "))
    end
    local preset = M.PRESETS[resolved]

    local cfg_path = opts.config_path or (fs.config_dir() .. "/noctalia/config.toml")
    local src_text = fs.read_file(cfg_path)
    if not src_text and opts.template_path then
        src_text = fs.read_file(opts.template_path)
    end
    if not src_text then
        return nil, "Noctalia config not found: " .. cfg_path
    end

    local backup_path = M.theme_backup_file(opts)
    local existing_backup_raw = fs.read_file(backup_path)
    local existing_backup = nil
    if existing_backup_raw and existing_backup_raw:find("%S") then
        local ok_dec, dec = pcall(json.decode, existing_backup_raw)
        if ok_dec and type(dec) == "table" then
            existing_backup = dec
        end
    end

    local render_opts = {}
    local save_backup_tbl = nil
    local remove_backup = false
    if preset.theme then
        if not existing_backup then
            save_backup_tbl = M.extract_theme(src_text)
        end
    elseif existing_backup then
        render_opts.restore_theme = existing_backup
        remove_backup = true
    end

    local rendered, render_err = M.render_config(src_text, resolved, render_opts)
    if not rendered then
        return nil, render_err
    end

    if opts.validate ~= false then
        local ok_val, val_err = validate_noctalia_text(cfg_path, rendered)
        if not ok_val then
            return nil, val_err
        end
    end

    local hypr_text = assert(M.render_hypr_lua(resolved))
    local gtk_text = assert(M.render_gtk_css(resolved))

    if save_backup_tbl then
        local ok_bk, bk_err = fs.write_atomic(backup_path, json.encode(save_backup_tbl) .. "\n")
        if not ok_bk then
            return nil, bk_err
        end
    end

    local ok_cfg, cfg_err = fs.write_atomic(cfg_path, rendered)
    if not ok_cfg then
        return nil, cfg_err
    end

    if remove_backup then
        os.remove(backup_path)
    end

    local hypr_path = M.hypr_style_file(opts)
    local ok_hl, hl_err = fs.write_atomic(hypr_path, hypr_text)
    if not ok_hl then
        return nil, hl_err
    end

    local gtk_path = M.gtk_style_file(opts)
    local ok_gtk, gtk_err = fs.write_atomic(gtk_path, gtk_text)
    if not ok_gtk then
        return nil, gtk_err
    end

    local st_path = M.state_file(opts)
    local ok_st, st_err = fs.write_atomic(st_path, resolved .. "\n")
    if not ok_st then
        return nil, st_err
    end

    local noc_state_path = M.noctalia_state_file(opts)
    local ok_nst, nst_err = clean_noctalia_state_overrides(noc_state_path)
    if not ok_nst then
        return nil, nst_err
    end

    local theme_changed = not themes_equal(M.extract_theme(src_text), M.extract_theme(rendered))
    if opts.reload ~= false then
        if cmd_exists("noctalia") then
            os.execute("noctalia msg config-reload >/dev/null 2>&1")
            if theme_changed then
                os.execute("noctalia msg templates-apply >/dev/null 2>&1")
            end
        end
        local hypr_sig = os.getenv("HYPRLAND_INSTANCE_SIGNATURE")
        if hypr_sig and hypr_sig ~= "" and cmd_exists("hyprctl") then
            os.execute("hyprctl reload >/dev/null 2>&1")
        end
    end

    return {
        style = resolved,
        config_path = cfg_path,
        hypr_style_path = hypr_path,
        gtk_style_path = gtk_path,
        state_file = st_path,
        theme_changed = theme_changed,
    }
end

function M.list_custom_palettes(opts)
    opts = opts or {}
    local dir = opts.palettes_dir or (fs.config_dir() .. "/noctalia/palettes")
    local out = {}
    local p = io.popen("LC_ALL=C ls -1 -- " .. fs.shell_quote(dir) .. " 2>/dev/null")
    if p then
        for line in p:lines() do
            local name = line:match("^(.+)%.json$")
            if name and name ~= "" then
                out[#out + 1] = name
            end
        end
        p:close()
    end
    table.sort(out)
    return out
end

function M.list_themes(opts)
    local out = {}
    for _, name in ipairs(M.BUILTIN_THEMES) do
        out[#out + 1] = {
            id = name,
            kind = "builtin",
            detail = "Noctalia built-in scheme",
        }
    end
    for _, name in ipairs(M.list_custom_palettes(opts)) do
        out[#out + 1] = {
            id = name,
            kind = "custom",
            detail = "Custom palette (~/.config/noctalia/palettes)",
        }
    end
    out[#out + 1] = {
        id = "wallpaper",
        kind = "wallpaper",
        detail = "Material 3 palette from active wallpaper",
    }
    return out
end

function M.current_theme(opts)
    opts = opts or {}
    local cfg_path = opts.config_path or (fs.config_dir() .. "/noctalia/config.toml")
    local raw = fs.read_file(cfg_path)
    if not raw and opts.template_path then
        raw = fs.read_file(opts.template_path)
    end
    local tbl = raw and M.extract_theme(raw) or {}
    local mode = tbl.mode or "dark"
    local source = tbl.source or "builtin"
    local active_id
    if source == "custom" and type(tbl.custom_palette) == "string" and tbl.custom_palette ~= "" then
        active_id = tbl.custom_palette
    elseif source == "wallpaper" then
        active_id = "wallpaper"
    else
        active_id = tbl.builtin or "Kanagawa"
    end
    local label = active_id == "wallpaper" and "Wallpaper M3" or active_id
    return {
        mode = mode,
        source = source,
        builtin = tbl.builtin,
        custom_palette = tbl.custom_palette,
        pure_black_dark = tbl.pure_black_dark,
        active_id = active_id,
        display = string.format("%s (%s)", label, mode),
    }
end

function M.resolve_theme(target, opts)
    if type(target) ~= "string" then
        return nil
    end
    local key = target:match("^%s*(.-)%s*$")
    if key == "" then
        return nil
    end
    local low = key:lower()
    if low == "wallpaper" or low == "m3" or low == "wallpaper-m3" then
        return { id = "wallpaper", kind = "wallpaper" }
    end
    for _, item in ipairs(M.list_themes(opts)) do
        if item.id:lower() == low then
            return item
        end
    end
    return nil
end

function M.render_theme_config(toml_text, theme_tbl, drop_keys)
    if type(toml_text) ~= "string" then
        return nil, "expected config.toml text"
    end
    local spec = make_theme_spec(theme_tbl)
    local blocks = split_blocks(toml_text)
    local seen = false
    for _, blk in ipairs(blocks) do
        if not blk.is_array and blk.sec == "theme" then
            patch_section_block(blk, spec, drop_keys)
            seen = true
            break
        end
    end
    if not seen then
        local nb = build_section_block("theme", spec)
        ensure_trailing_blank(nb)
        table.insert(blocks, 1, nb)
    end
    local rendered_lines = {}
    for _, blk in ipairs(blocks) do
        for _, ln in ipairs(blk.lines) do
            rendered_lines[#rendered_lines + 1] = ln
        end
    end
    while #rendered_lines > 0 and rendered_lines[#rendered_lines]:match("^%s*$") do
        table.remove(rendered_lines)
    end
    return table.concat(rendered_lines, "\n") .. "\n"
end

function M.apply_theme(target, opts)
    opts = opts or {}
    local resolved = M.resolve_theme(target, opts)
    if not resolved then
        local names = {}
        for _, item in ipairs(M.list_themes(opts)) do
            names[#names + 1] = item.id
        end
        return nil, string.format("unknown color theme '%s' (available: %s)", tostring(target), table.concat(names, ", "))
    end

    local cfg_path = opts.config_path or (fs.config_dir() .. "/noctalia/config.toml")
    local src_text = fs.read_file(cfg_path)
    if not src_text and opts.template_path then
        src_text = fs.read_file(opts.template_path)
    end
    if not src_text then
        return nil, "Noctalia config not found: " .. cfg_path
    end

    local cur = M.extract_theme(src_text)
    local next_theme = {
        mode = opts.mode or cur.mode or "dark",
    }
    local drop_keys = nil
    if resolved.kind == "builtin" then
        next_theme.source = "builtin"
        next_theme.builtin = resolved.id
        drop_keys = { custom_palette = true }
    elseif resolved.kind == "custom" then
        next_theme.source = "custom"
        next_theme.custom_palette = resolved.id
    else
        next_theme.source = "wallpaper"
        drop_keys = { custom_palette = true }
    end

    local rendered, render_err = M.render_theme_config(src_text, next_theme, drop_keys)
    if not rendered then
        return nil, render_err
    end

    if opts.validate ~= false then
        local ok_val, val_err = validate_noctalia_text(cfg_path, rendered)
        if not ok_val then
            return nil, val_err
        end
    end

    local ok_cfg, cfg_err = fs.write_atomic(cfg_path, rendered)
    if not ok_cfg then
        return nil, cfg_err
    end

    -- Explicit color-theme choice supersedes any saved pre-locked-style theme backup.
    local backup_path = M.theme_backup_file(opts)
    if fs.file_exists(backup_path) then
        os.remove(backup_path)
    end

    if opts.reload ~= false then
        if cmd_exists("noctalia") then
            os.execute("noctalia msg config-reload >/dev/null 2>&1")
            os.execute("noctalia msg templates-apply >/dev/null 2>&1")
        end
        local hypr_sig = os.getenv("HYPRLAND_INSTANCE_SIGNATURE")
        if hypr_sig and hypr_sig ~= "" and cmd_exists("hyprctl") then
            os.execute("hyprctl reload >/dev/null 2>&1")
        end
    end

    return {
        theme = resolved.id,
        kind = resolved.kind,
        mode = next_theme.mode,
        config_path = cfg_path,
    }
end

return M
