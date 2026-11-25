local ok_ctx, ctx = pcall(require, "kaze._ctx")
local cfg = (ok_ctx and type(ctx) == "table" and ctx.cfg) or require("kaze.defaults")
local theme = (ok_ctx and type(ctx) == "table" and ctx.theme) or require("kaze.themes").get("kaze")
local layout = (ok_ctx and type(ctx) == "table" and ctx.layout) or require("kaze.layouts").get("sidebar")
local themes = require("kaze.themes")

hl.window_rule({
    name = "suppress-maximize-events",
    match = { class = ".*" },
    suppress_event = "maximize",
})

hl.window_rule({
    name = "fix-xwayland-drags",
    match = { class = "^$", title = "^$", xwayland = true, float = true, fullscreen = false, pin = false },
    no_focus = true,
})

-- Optional C++ native Smart Gaps ("no gaps when only 1 tiled window")
if cfg.smart_gaps == true and hl.workspace_rule then
    hl.workspace_rule({ workspace = "w[tv1]", gaps_out = 0, gaps_in = 0 })
    hl.workspace_rule({ workspace = "f[1]", gaps_out = 0, gaps_in = 0 })
    hl.window_rule({
        name = "smart-gaps-wtv1",
        match = { float = false, workspace = "w[tv1]" },
        border_size = 0,
        rounding = 0,
    })
    hl.window_rule({
        name = "smart-gaps-f1",
        match = { float = false, workspace = "f[1]" },
        border_size = 0,
        rounding = 0,
    })
end

-- Context-aware state borders (pinned -> warn, fullscreen -> ok)
hl.window_rule({
    name = "state-border-pinned",
    match = { pin = true },
    border_color = themes.hypr_rgba(theme.warn, "dd"),
})

hl.window_rule({
    name = "state-border-fullscreen",
    match = { fullscreen = true },
    border_color = themes.hypr_rgba(theme.ok, "cc"),
})

hl.window_rule({
    match = { class = "^(imv|mpv|swappy|org\\.pwmt\\.zathura)$" },
    opaque = true,
    no_blur = true,
})

hl.window_rule({
    match = { class = "^xdg-desktop-portal-gtk$" },
    float = true,
    center = true,
    size = "(monitor_w*0.58) (monitor_h*0.64)",
})

hl.window_rule({
    match = { class = "^polkit-mate-authentication-agent-1$" },
    float = true,
    center = true,
})

-- Spatial origin-matched popovers & drawers:
-- On `sidebar` (left vertical bar), status/clock widgets and TUI drawers emerge
-- directly from the left rail (`x = 58`, `slide left`) right beside the clicked icon.
-- On `islands` / `slim` (top horizontal bars), clock/control widgets drop straight
-- down out of the bar (`slide top`), while full TUI drawers slide from the right edge.
local is_sidebar = (layout.name == "sidebar")
local ui = type(layout.ui) == "table" and layout.ui or {}
local dr_x = tonumber(ui.drawer_right_x) or 12
local dr_y = tonumber(ui.drawer_top_y) or 12
local dr_h_sub = tonumber(ui.drawer_height_sub) or 24

local dash_move = is_sidebar
    and "58 (monitor_h-window_h-44)"
    or string.format("(monitor_w*0.5-window_w*0.5) %d", dr_y)
local dash_anim = is_sidebar and "slide left" or "slide top"

local panel_move = is_sidebar
    and "58 (monitor_h-window_h-8)"
    or string.format("(monitor_w-window_w-%d) %d", dr_x, dr_y)
local panel_anim = is_sidebar and "slide left" or "slide top"

local tui_move = is_sidebar
    and string.format("58 %d", dr_y)
    or string.format("(monitor_w-window_w-%d) %d", dr_x, dr_y)
local tui_anim = is_sidebar and "slide left" or "slide right"

hl.window_rule({
    name = "kaze-widget-dash",
    match = { class = "^kaze-widget-dash$" },
    float = true,
    move = dash_move,
    animation = dash_anim,
})

hl.window_rule({
    name = "kaze-widget-panel",
    match = { class = "^kaze-widget-panel$" },
    float = true,
    move = panel_move,
    animation = panel_anim,
})

hl.window_rule({
    name = "kaze-right-drawer",
    match = { class = "^kaze-tui$" },
    float = true,
    size = string.format("(monitor_w*0.42) (monitor_h-%d)", dr_h_sub),
    move = tui_move,
    animation = tui_anim,
})

hl.window_rule({
    name = "kaze-top-dropdown",
    match = { class = "^kaze-dropdown$" },
    float = true,
    size = "(monitor_w*0.66) (monitor_h*0.52)",
    move = string.format("(monitor_w*0.17) %d", dr_y),
    animation = "slide top",
})

if hl.workspace_rule then
    hl.workspace_rule({ workspace = "s[true]", animation = "slidevert" })
end

hl.window_rule({
    match = { class = "^(com\\.saivert\\.pwvucontrol|org\\.pulseaudio\\.pavucontrol|pwvucontrol|pavucontrol)$" },
    float = true,
    size = string.format("(monitor_w*0.42) (monitor_h-%d)", dr_h_sub),
    move = tui_move,
    animation = tui_anim,
})

hl.window_rule({
    match = { title = "Picture(-| )in(-| )[Pp]icture" },
    float = true,
    pin = true,
    opaque = true,
    no_blur = true,
    keep_aspect_ratio = true,
    move = "(monitor_w*0.98-window_w) (monitor_h*0.97-window_h)",
})

local notif_anim = is_sidebar and "slide right" or "slide top"
hl.layer_rule({ match = { namespace = "^waybar$" }, blur = true, ignore_alpha = 0.25 })
hl.layer_rule({ match = { namespace = "^(launcher|kaze-popup-top)$" }, blur = true, ignore_alpha = 0.25, animation = "slide top" })
hl.layer_rule({ match = { namespace = "^kaze-popup-left$" }, blur = true, ignore_alpha = 0.25, animation = "slide left" })
hl.layer_rule({ match = { namespace = "^kaze-popup-right$" }, blur = true, ignore_alpha = 0.25, animation = "slide right" })
hl.layer_rule({ match = { namespace = "^notifications$" }, blur = true, ignore_alpha = 0.25, animation = notif_anim })
hl.layer_rule({ match = { namespace = "^(selection|hyprpicker)$" }, no_anim = true })
