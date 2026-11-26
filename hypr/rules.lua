local ok_ctx, ctx = pcall(require, "kaze._ctx")
local cfg = (ok_ctx and type(ctx) == "table" and ctx.cfg) or require("kaze.hypr_user").defaults()
local noc_colors = (ok_ctx and type(ctx) == "table" and type(ctx.noctalia) == "table" and type(ctx.noctalia.colors) == "table")
    and ctx.noctalia.colors
    or {}

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

-- Context-aware state borders (pinned -> error/accent, fullscreen -> secondary)
hl.window_rule({
    name = "state-border-pinned",
    match = { pin = true },
    border_color = noc_colors.error or "rgba(e0af68dd)",
})

hl.window_rule({
    name = "state-border-fullscreen",
    match = { fullscreen = true },
    border_color = noc_colors.secondary or "rgba(9ece6acc)",
})

hl.window_rule({
    match = { class = "^(imv|mpv|org\\.pwmt\\.zathura)$" },
    opaque = true,
    no_blur = true,
})

hl.window_rule({
    match = { class = "^xdg-desktop-portal-gtk$" },
    float = true,
    center = true,
    size = "(monitor_w*0.58) (monitor_h*0.64)",
})

-- Noctalia GUI Settings floats centered
hl.window_rule({
    name = "noctalia-settings",
    match = { class = "^dev\\.noctalia\\.Noctalia$" },
    float = true,
    center = true,
    size = "(monitor_w*0.5625) (monitor_h*0.85)",
})

-- Floating TUI drawer (sysmon / btop) and top dropdown
hl.window_rule({
    name = "kaze-tui-drawer",
    match = { class = "^kaze-tui$" },
    float = true,
    size = "(monitor_w*0.42) (monitor_h-24)",
    move = "58 12",
    animation = "slide left",
})

hl.window_rule({
    name = "kaze-top-dropdown",
    match = { class = "^kaze-dropdown$" },
    float = true,
    size = "(monitor_w*0.66) (monitor_h*0.52)",
    move = "(monitor_w*0.17) 12",
    animation = "slide top",
})

if hl.workspace_rule then
    hl.workspace_rule({ workspace = "s[true]", animation = "slidevert" })
end

hl.window_rule({
    match = { title = "Picture(-| )in(-| )[Pp]icture" },
    float = true,
    pin = true,
    opaque = true,
    no_blur = true,
    keep_aspect_ratio = true,
    move = "(monitor_w*0.98-window_w) (monitor_h*0.97-window_h)",
})

-- Disable Hyprland layer animations on Noctalia surfaces so Noctalia's internal
-- animations never double-animate or tear.
hl.layer_rule({
    name = "noctalia-no-anim",
    match = {
        namespace = "^noctalia-(bar-.+|notification|dock|panel|attached-panel|osd|window-switcher)$",
    },
    no_anim = true,
})

hl.layer_rule({ match = { namespace = "^(selection|hyprpicker)$" }, no_anim = true })
