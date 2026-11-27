local ok_ctx, ctx = pcall(require, "kaze._ctx")
local cfg = (ok_ctx and type(ctx) == "table" and ctx.cfg) or require("kaze.hypr_user").defaults()
local theme_colors = (ok_ctx and type(ctx) == "table" and type(ctx.theme) == "table" and type(ctx.theme.colors) == "table")
    and ctx.theme.colors
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
    border_color = theme_colors.error or "rgba(e0af68dd)",
})

hl.window_rule({
    name = "state-border-fullscreen",
    match = { fullscreen = true },
    border_color = theme_colors.secondary or "rgba(9ece6acc)",
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

-- Thunar modal/progress/rename/properties dialogs float cleanly without disrupting tiled layouts
hl.window_rule({
    name = "thunar-dialogs",
    match = {
        class = "^[Tt]hunar$",
        title = "^(File Operation Progress|Confirm to replace files|Rename \".*\"|Create New Folder|Create Document|.* - Properties)$",
    },
    float = true,
    center = true,
})

-- Floating TUI drawer (sysmon / btop), centered Mirror Optimizer TUI, and top dropdown
local drawer_x = tonumber(cfg.tui_drawer_x) or 58
hl.window_rule({
    name = "kaze-tui-drawer",
    match = { class = "^kaze-tui$" },
    float = true,
    size = "(monitor_w*0.42) (monitor_h-24)",
    move = string.format("%d 12", drawer_x),
    animation = "slide left",
})

hl.window_rule({
    name = "kaze-mirror-tui",
    match = { class = "^kaze-mirror-tui$" },
    float = true,
    center = true,
    size = "(monitor_w*0.62) (monitor_h*0.78)",
})

hl.window_rule({
    name = "kaze-theme-hub",
    match = { class = "^kaze-theme-hub$" },
    float = true,
    center = true,
    size = "(monitor_w*0.64) (monitor_h*0.74)",
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
    local persist_count = tonumber(cfg.persistent_workspaces)
    if persist_count == nil then
        persist_count = 5
    end
    for i = 1, math.floor(persist_count) do
        hl.workspace_rule({ workspace = tostring(i), persistent = true })
    end
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

hl.window_rule({
    name = "kaze-share-preview",
    match = {
        class = "^at\\.yrlf\\.wl_mirror$",
        title = "^(kaze-share-preview|wl-mirror.*kaze-share)",
    },
    float = true,
    pin = true,
    opaque = true,
    no_blur = true,
    keep_aspect_ratio = true,
    size = "(monitor_w*0.28) (monitor_h*0.28)",
    move = "(monitor_w*0.98-window_w) (monitor_h*0.97-window_h)",
})

hl.window_rule({
    name = "kaze-share-control",
    match = {
        class = "^at\\.yrlf\\.wl_mirror$",
        title = "^kaze-share-control$",
    },
    opaque = true,
    no_blur = true,
    no_focus = true,
})

-- Disable Hyprland layer animations on kaze-shell surfaces so spring physics never double-animate or tear.
hl.layer_rule({
    name = "kaze-shell-no-anim",
    match = {
        namespace = "^(kaze-bar-.+|kaze-island|kaze-osd|kaze-notify|kaze-launcher|kaze-cc|kaze-tray-menu)$",
    },
    no_anim = true,
})

-- Subtle blur for Dynamic Island & Control Center when active preset enables blur.
hl.layer_rule({
    name = "kaze-shell-blur",
    match = {
        namespace = "^(kaze-island|kaze-cc)$",
    },
    blur = true,
    ignore_alpha = 0.25,
})

hl.layer_rule({ match = { namespace = "^(selection|hyprpicker)$" }, no_anim = true })
