local ctx = require("kaze._ctx")
local cfg = ctx.cfg

local op = cfg.opacity or {}
local active_op = tonumber(op.active) or 0.96
local inactive_op = tonumber(op.inactive) or 0.92

hl.window_rule({
    match = { fullscreen = false },
    opacity = string.format("%.2f %.2f", active_op, inactive_op),
})

-- Floating centered Omarchy TUI popups (nmtui, bluetui, wiremix, btop)
-- Hyprland window_rule uses C++ std::regex (not Lua patterns)
hl.window_rule({
    match = { class = "^kaze-tui$" },
    float = true,
    center = true,
    size = "(monitor_w*0.56) (monitor_h*0.62)",
})

hl.window_rule({
    match = { class = "^(com\\.saivert\\.pwvucontrol|org\\.pulseaudio\\.pavucontrol)$" },
    float = true,
    center = true,
    size = "(monitor_w*0.52) (monitor_h*0.58)",
})

hl.window_rule({
    match = { title = "Picture(-| )in(-| )[Pp]icture" },
    float = true,
    pin = true,
    keep_aspect_ratio = true,
    move = "(monitor_w*0.98-window_w) (monitor_h*0.97-window_h)",
})

hl.layer_rule({ match = { namespace = "waybar" }, blur = true, ignore_alpha = 0.25 })
hl.layer_rule({ match = { namespace = "launcher" }, blur = true, ignore_alpha = 0.25, animation = "popin 88%" })
hl.layer_rule({ match = { namespace = "notifications" }, blur = true, ignore_alpha = 0.25, animation = "fade" })
