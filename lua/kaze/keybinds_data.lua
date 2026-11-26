local hypr_user = require("kaze.hypr_user")

local M = {}

function M.build(cfg)
    local defaults = hypr_user.defaults()
    cfg = cfg or defaults
    local terminal = cfg.terminal or defaults.terminal
    -- Hotkeys do not need an exit status; $TERMINAL keeps footclient's wait semantics.
    local terminal_cmd = terminal == "kaze-footclient" and "kaze-footclient -N" or terminal
    local browser_cmd = cfg.browser or defaults.browser
    local editor_cmd = cfg.editor or defaults.editor
    if editor_cmd == defaults.editor then
        editor_cmd = "if command -v codium >/dev/null; then exec codium; "
            .. "elif command -v code >/dev/null; then exec code; "
            .. "elif command -v nvim >/dev/null; then exec kaze-footclient -N -e nvim; "
            .. "else notify-send 'Editor unavailable' 'Install codium or set editor in hypr/user.lua'; fi"
    end
    local files_cmd = cfg.files or defaults.files
    if files_cmd == defaults.files then
        files_cmd = "if command -v thunar >/dev/null; then exec thunar; "
            .. "elif command -v yazi >/dev/null; then exec kaze-footclient -N -e yazi; "
            .. "else notify-send 'File manager unavailable' 'Install thunar or set files in hypr/user.lua'; fi"
    end

    local entries = {
        -- Noctalia Native Launchers, Panels & Settings
        {
            group = "Launchers",
            chord = "SUPER + SUPER_L",
            display = "Super (tap) / Super + Space",
            desc = "Toggle Noctalia app launcher",
            kind = "exec",
            cmd = "noctalia msg panel-toggle launcher",
            release = true,
        },
        {
            group = "Launchers",
            chord = "SUPER + SPACE",
            display = false,
            desc = "Toggle Noctalia app launcher",
            kind = "exec",
            cmd = "noctalia msg panel-toggle launcher",
        },
        {
            group = "Launchers",
            chord = "SUPER + A",
            display = "Super + A",
            desc = "Toggle Noctalia Control Center",
            kind = "exec",
            cmd = "noctalia msg panel-toggle control-center",
        },
        {
            group = "Launchers",
            chord = "SUPER + N",
            display = "Super + N",
            desc = "Toggle Noctalia Notifications tab",
            kind = "exec",
            cmd = "noctalia msg panel-toggle control-center notifications",
        },
        {
            group = "Launchers",
            chord = "SUPER + I",
            display = "Super + I",
            desc = "Toggle Noctalia Settings",
            kind = "exec",
            cmd = "noctalia msg settings-toggle",
        },
        {
            group = "Launchers",
            chord = "SUPER + SHIFT + I",
            display = "Super + Shift + I",
            desc = "Visual style switcher",
            kind = "exec",
            cmd = "kaze-style --menu",
        },
        {
            group = "Launchers",
            chord = "SUPER + slash",
            display = "Super + /",
            desc = "Search Hyprland keyboard shortcuts",
            kind = "exec",
            cmd = "kaze-keys",
        },
        {
            group = "Launchers",
            chord = "SUPER + SHIFT + T",
            display = "Super + Shift + T",
            desc = "Toggle dark / light mode (Noctalia)",
            kind = "exec",
            cmd = "noctalia msg theme-mode-toggle",
        },
        {
            group = "Launchers",
            chord = "SUPER + SHIFT + W",
            display = "Super + Shift + W",
            desc = "Open Noctalia wallpaper picker",
            kind = "exec",
            cmd = "noctalia msg panel-toggle wallpaper",
        },
        {
            group = "Launchers",
            chord = "SUPER + V",
            display = "Super + V",
            desc = "Toggle Noctalia clipboard history",
            kind = "exec",
            cmd = "noctalia msg panel-toggle clipboard",
        },

        -- Session & Shell Controls
        {
            group = "System",
            chord = "CTRL + ALT + Delete",
            display = "Ctrl + Alt + Delete",
            desc = "Toggle Noctalia session menu",
            kind = "exec",
            cmd = "noctalia msg panel-toggle session",
        },
        {
            group = "System",
            chord = "SUPER + L",
            display = "Super + L",
            desc = "Lock screen",
            kind = "exec",
            cmd = "kaze-session lock",
        },
        {
            group = "System",
            chord = "CTRL + ALT + C",
            display = "Ctrl + Alt + C",
            desc = "Dismiss all notifications",
            kind = "exec",
            cmd = "noctalia msg notification-clear-active",
            locked = true,
        },
        {
            group = "System",
            chord = "SUPER + SHIFT + D",
            display = "Super + Shift + D",
            desc = "Toggle Do Not Disturb",
            kind = "exec",
            cmd = "noctalia msg notification-dnd-toggle",
        },
        {
            group = "System",
            chord = "SUPER + SHIFT + N",
            display = "Super + Shift + N",
            desc = "Toggle Night Light",
            kind = "exec",
            cmd = "noctalia msg nightlight-force-toggle",
        },
        {
            group = "System",
            chord = "SUPER + SHIFT + Z",
            display = "Super + Shift + Z",
            desc = "Toggle Focus / Game Mode",
            kind = "focus_mode",
        },
        {
            group = "System",
            chord = "SUPER + Escape",
            display = "Super + Esc",
            desc = "Enter VM keybind passthrough",
            kind = "submap",
            submap = "passthrough",
        },
        {
            group = "System",
            chord = "SUPER + SHIFT + P",
            display = "Super + Shift + P / XF86Display",
            desc = "Display layout menu",
            kind = "exec",
            cmd = "kaze-display --menu",
        },
        {
            group = "System",
            chord = "XF86Display",
            display = false,
            desc = "Display layout menu",
            kind = "exec",
            cmd = "kaze-display --menu",
        },
        {
            group = "System",
            chord = "SUPER + ALT + P",
            display = "Super + Alt + P",
            desc = "Push/pull window to shared workspace",
            kind = "exec",
            cmd = "kaze-display toggle-window-share",
        },
        {
            group = "System",
            chord = "CTRL + SUPER + P",
            display = "Ctrl + Super + P",
            desc = "Toggle control presented workspace on laptop",
            kind = "exec",
            cmd = "kaze-display toggle-control",
        },
        {
            group = "System",
            chord = "CTRL + SUPER + ALT + R",
            display = "Ctrl + Super + Alt + R",
            desc = "Reload Noctalia and Hyprland",
            kind = "exec",
            cmd = "noctalia msg config-reload && hyprctl reload",
            release = true,
        },

        -- Core Applications
        {
            group = "Apps",
            chord = "SUPER + T",
            display = "Super + Return / T",
            desc = "Open terminal",
            kind = "exec",
            cmd = terminal_cmd,
        },
        {
            group = "Apps",
            chord = "SUPER + Return",
            display = false,
            desc = "Open terminal",
            kind = "exec",
            cmd = terminal_cmd,
        },
        {
            group = "Apps",
            chord = "SUPER + W",
            display = "Super + W",
            desc = "Open browser",
            kind = "exec",
            cmd = browser_cmd,
        },
        {
            group = "Apps",
            chord = "SUPER + C",
            display = "Super + C",
            desc = "Open editor",
            kind = "exec",
            cmd = editor_cmd,
        },
        {
            group = "Apps",
            chord = "SUPER + E",
            display = "Super + E",
            desc = "Open file manager",
            kind = "exec",
            cmd = files_cmd,
        },
        {
            group = "Apps",
            chord = "SUPER + O",
            display = "Super + O",
            desc = "Open project switcher (zoxide / fd)",
            kind = "exec",
            cmd = "kaze-project",
        },
        {
            group = "Apps",
            chord = "SUPER + SHIFT + O",
            display = "Super + Shift + O",
            desc = "Open project (Neovim + terminal split)",
            kind = "exec",
            cmd = "kaze-project --split",
        },

        -- Control Center Quick Tabs & On-Demand System Monitor
        {
            group = "Tools",
            chord = "SUPER + ALT + W",
            display = "Super + Alt + W",
            desc = "Network settings (Noctalia)",
            kind = "exec",
            cmd = "noctalia msg panel-toggle control-center network",
        },
        {
            group = "Tools",
            chord = "SUPER + ALT + B",
            display = "Super + Alt + B",
            desc = "Bluetooth settings (Noctalia)",
            kind = "exec",
            cmd = "noctalia msg panel-toggle control-center bluetooth",
        },
        {
            group = "Tools",
            chord = "CTRL + ALT + V",
            display = "Ctrl + Alt + V / Super + Alt + A",
            desc = "Audio settings (Noctalia)",
            kind = "exec",
            cmd = "noctalia msg panel-toggle control-center audio",
        },
        {
            group = "Tools",
            chord = "SUPER + ALT + A",
            display = false,
            desc = "Audio settings (Noctalia)",
            kind = "exec",
            cmd = "noctalia msg panel-toggle control-center audio",
        },
        {
            group = "Tools",
            chord = "CTRL + SHIFT + Escape",
            display = "Ctrl + Shift + Esc",
            desc = "Floating system monitor (btop)",
            kind = "exec",
            cmd = "kaze-tui sysmon",
        },
        {
            group = "Tools",
            chord = "CTRL + ALT + M",
            display = "Ctrl + Alt + M",
            desc = "Mirror optimizer (TUI)",
            kind = "exec",
            cmd = "kaze-mirror --tui-window",
        },

        -- Screenshots, Recording & Color Picker
        {
            group = "Capture",
            chord = "Print",
            display = "Print",
            desc = "Fullscreen screenshot (Noctalia)",
            kind = "exec",
            cmd = "noctalia msg screenshot-fullscreen",
            locked = true,
        },
        {
            group = "Capture",
            chord = "SUPER + SHIFT + S",
            display = "Super + Shift + S",
            desc = "Region screenshot (Noctalia)",
            kind = "exec",
            cmd = "noctalia msg screenshot-region",
        },
        {
            group = "Capture",
            chord = "SUPER + SHIFT + ALT + S",
            display = "Super + Shift + Alt + S",
            desc = "Annotate screenshot (Noctalia)",
            kind = "exec",
            cmd = "noctalia msg screenshot-annotate",
        },
        {
            group = "Capture",
            chord = "SUPER + SHIFT + C",
            display = "Super + Shift + C",
            desc = "Pick screen color (hyprpicker)",
            kind = "exec",
            cmd = "sh -c 'c=$(hyprpicker --no-fancy --format=hex) && [ -n \"$c\" ] && printf %s \"$c\" | wl-copy && notify-send -a Color -t 2000 Color \"$c\"'",
        },
        {
            group = "Capture",
            chord = "CTRL + ALT + R",
            display = "Ctrl + Alt + R",
            desc = "Toggle screen recording",
            kind = "exec",
            cmd = "kaze-record",
        },
        {
            group = "Capture",
            chord = "SUPER + SHIFT + ALT + R",
            display = "Super + Shift + Alt + R",
            desc = "Toggle region recording",
            kind = "exec",
            cmd = "kaze-record --region",
        },
        {
            group = "Capture",
            chord = "SUPER + SHIFT + R",
            display = "Super + Shift + R",
            desc = "Open screen recording menu",
            kind = "exec",
            cmd = "kaze-record --menu",
        },

        -- Window Management & Groups
        {
            group = "Windows",
            chord = "SUPER + Q",
            display = "Super + Q",
            desc = "Close active window",
            kind = "window_close",
        },
        {
            group = "Windows",
            chord = "SUPER + F",
            display = "Super + F",
            desc = "Toggle fullscreen",
            kind = "fullscreen",
            args = { mode = "fullscreen" },
        },
        {
            group = "Windows",
            chord = "SUPER + ALT + F",
            display = "Super + Alt + F",
            desc = "Toggle maximize",
            kind = "fullscreen",
            args = { mode = "maximized" },
        },
        {
            group = "Windows",
            chord = "SUPER + ALT + Space",
            display = "Super + Alt + Space",
            desc = "Toggle floating window",
            kind = "float",
        },
        {
            group = "Windows",
            chord = "SUPER + P",
            display = "Super + P",
            desc = "Toggle window pin",
            kind = "pin",
        },
        {
            group = "Windows",
            chord = "CTRL + SUPER + Backslash",
            display = "Ctrl + Super + \\",
            desc = "Center floating window",
            kind = "window_center",
        },
        {
            group = "Windows",
            chord = "CTRL + SUPER + ALT + Backslash",
            display = "Ctrl + Super + Alt + \\",
            desc = "Normalize and center window",
            kind = "window_normalize",
        },
        {
            group = "Windows",
            chord = "SUPER + ALT + Backslash",
            display = "Super + Alt + \\",
            desc = "Pin window as Picture-in-Picture",
            kind = "window_pip",
        },
        {
            group = "Windows",
            chord = "SUPER + TAB",
            display = "Super + Tab",
            desc = "Noctalia window switcher",
            kind = "exec",
            cmd = "noctalia msg window-switcher hold",
        },
        {
            group = "Windows",
            chord = "ALT + TAB",
            display = "Alt + Tab",
            desc = "Cycle next window",
            kind = "cycle_next",
            repeating = true,
        },
        {
            group = "Windows",
            chord = "SHIFT + ALT + TAB",
            display = "Shift + Alt + Tab",
            desc = "Cycle previous window",
            kind = "cycle_next",
            args = { next = false },
            repeating = true,
        },
        {
            group = "Windows",
            chord = "SUPER + Comma",
            display = "Super + ,",
            desc = "Toggle window group",
            kind = "group_toggle",
        },
        {
            group = "Windows",
            chord = "SUPER + SHIFT + Comma",
            display = "Super + Shift + ,",
            desc = "Lock active window group",
            kind = "group_lock",
        },
        {
            group = "Windows",
            chord = "SUPER + U",
            display = "Super + U",
            desc = "Move window out of group",
            kind = "window_move",
            args = { out_of_group = true },
        },
        {
            group = "Windows",
            chord = "CTRL + ALT + TAB",
            display = "Ctrl + Alt + Tab",
            desc = "Next window in group",
            kind = "group_next",
            repeating = true,
        },
        {
            group = "Windows",
            chord = "CTRL + SHIFT + ALT + TAB",
            display = "Ctrl + Shift + Alt + Tab",
            desc = "Previous window in group",
            kind = "group_prev",
            repeating = true,
        },
        {
            group = "Windows",
            chord = "SUPER + Minus",
            display = "Super + - / = (or Super + Alt + Arrows)",
            display_desc = "Resize active window",
            desc = "Decrease window width",
            kind = "window_resize_step",
            args = { x = -10, y = 0 },
            repeating = true,
        },
        {
            group = "Windows",
            chord = "SUPER + ALT + left",
            display = false,
            desc = "Decrease window width",
            kind = "window_resize_step",
            args = { x = -10, y = 0 },
            repeating = true,
        },
        {
            group = "Windows",
            chord = "SUPER + Equal",
            display = false,
            desc = "Increase window width",
            kind = "window_resize_step",
            args = { x = 10, y = 0 },
            repeating = true,
        },
        {
            group = "Windows",
            chord = "SUPER + ALT + right",
            display = false,
            desc = "Increase window width",
            kind = "window_resize_step",
            args = { x = 10, y = 0 },
            repeating = true,
        },
        {
            group = "Windows",
            chord = "SUPER + SHIFT + Minus",
            display = false,
            desc = "Decrease window height",
            kind = "window_resize_step",
            args = { x = 0, y = -10 },
            repeating = true,
        },
        {
            group = "Windows",
            chord = "SUPER + ALT + up",
            display = false,
            desc = "Decrease window height",
            kind = "window_resize_step",
            args = { x = 0, y = -10 },
            repeating = true,
        },
        {
            group = "Windows",
            chord = "SUPER + SHIFT + Equal",
            display = false,
            desc = "Increase window height",
            kind = "window_resize_step",
            args = { x = 0, y = 10 },
            repeating = true,
        },
        {
            group = "Windows",
            chord = "SUPER + ALT + down",
            display = false,
            desc = "Increase window height",
            kind = "window_resize_step",
            args = { x = 0, y = 10 },
            repeating = true,
        },
    }

    for idx, dir in ipairs({ "left", "right", "up", "down" }) do
        entries[#entries + 1] = {
            group = "Windows",
            chord = "SUPER + " .. dir,
            display = idx == 1 and "Super + Arrows / H J K" or false,
            display_desc = idx == 1 and "Focus window in direction" or nil,
            desc = "Focus window " .. dir,
            kind = "focus",
            args = { direction = dir },
        }
        entries[#entries + 1] = {
            group = "Windows",
            chord = "SUPER + SHIFT + " .. dir,
            display = idx == 1 and "Super + Shift + Arrows" or false,
            display_desc = idx == 1 and "Move window in direction" or nil,
            desc = "Move window " .. dir,
            kind = "window_move",
            args = { direction = dir },
        }
    end

    for _, vim_bind in ipairs({
        { key = "H", dir = "left" },
        { key = "J", dir = "down" },
        { key = "K", dir = "up" },
    }) do
        entries[#entries + 1] = {
            group = "Windows",
            chord = "SUPER + " .. vim_bind.key,
            display = false,
            desc = "Focus window " .. vim_bind.dir,
            kind = "focus",
            args = { direction = vim_bind.dir },
        }
    end

    entries[#entries + 1] = {
        group = "Windows",
        chord = "SUPER + mouse:272",
        display = "Super + LMB / Z",
        desc = "Drag window",
        kind = "window_drag",
        mouse = true,
    }
    entries[#entries + 1] = {
        group = "Windows",
        chord = "SUPER + Z",
        display = false,
        desc = "Drag window",
        kind = "window_drag",
        mouse = true,
    }
    entries[#entries + 1] = {
        group = "Windows",
        chord = "SUPER + mouse:273",
        display = "Super + RMB / X",
        desc = "Resize window",
        kind = "window_resize",
        mouse = true,
    }
    entries[#entries + 1] = {
        group = "Windows",
        chord = "SUPER + X",
        display = false,
        desc = "Resize window",
        kind = "window_resize",
        mouse = true,
    }

    -- Workspaces 1..10
    for i = 1, 10 do
        local key = tostring(i % 10)
        local ws = tostring(i)
        entries[#entries + 1] = {
            group = "Workspaces",
            chord = "SUPER + " .. key,
            display = i == 1 and "Super + 1..0" or false,
            display_desc = i == 1 and "Switch to workspace 1..10" or nil,
            desc = "Switch to workspace " .. ws,
            kind = "focus",
            args = { workspace = ws },
        }
        entries[#entries + 1] = {
            group = "Workspaces",
            chord = "SUPER + SHIFT + " .. key,
            display = i == 1 and "Super + Shift / Alt + 1..0" or false,
            display_desc = i == 1 and "Move window to workspace 1..10" or nil,
            desc = "Move window to workspace " .. ws,
            kind = "window_move",
            args = { workspace = ws },
        }
        entries[#entries + 1] = {
            group = "Workspaces",
            chord = "SUPER + ALT + " .. key,
            display = false,
            desc = "Move window to workspace " .. ws,
            kind = "window_move",
            args = { workspace = ws },
        }
    end

    -- Relative workspace navigation & moves
    local rel_ws = {
        { chord = "SUPER + mouse_down", display = "Super + Scroll / Ctrl+Super+Left/Right", display_desc = "Cycle workspaces", desc = "Next workspace", kind = "focus", args = { workspace = "+1" } },
        { chord = "SUPER + mouse_up", display = false, desc = "Previous workspace", kind = "focus", args = { workspace = "-1" } },
        { chord = "CTRL + SUPER + right", display = false, desc = "Next workspace", kind = "focus", args = { workspace = "+1" }, repeating = true },
        { chord = "CTRL + SUPER + left", display = false, desc = "Previous workspace", kind = "focus", args = { workspace = "-1" }, repeating = true },
        { chord = "SUPER + Page_Down", display = false, desc = "Next workspace", kind = "focus", args = { workspace = "+1" }, repeating = true },
        { chord = "SUPER + Page_Up", display = false, desc = "Previous workspace", kind = "focus", args = { workspace = "-1" }, repeating = true },
        { chord = "SUPER + ALT + mouse_down", display = "Ctrl + Super + Shift + Left/Right", display_desc = "Move window to prev/next workspace", desc = "Move window to next workspace", kind = "window_move", args = { workspace = "+1" } },
        { chord = "SUPER + ALT + mouse_up", display = false, desc = "Move window to previous workspace", kind = "window_move", args = { workspace = "-1" } },
        { chord = "SUPER + ALT + Page_Down", display = false, desc = "Move window to next workspace", kind = "window_move", args = { workspace = "+1" }, repeating = true },
        { chord = "SUPER + ALT + Page_Up", display = false, desc = "Move window to previous workspace", kind = "window_move", args = { workspace = "-1" }, repeating = true },
        { chord = "CTRL + SUPER + SHIFT + right", display = false, desc = "Move window to next workspace", kind = "window_move", args = { workspace = "+1" }, repeating = true },
        { chord = "CTRL + SUPER + SHIFT + left", display = false, desc = "Move window to previous workspace", kind = "window_move", args = { workspace = "-1" }, repeating = true },
    }
    for _, item in ipairs(rel_ws) do
        item.group = "Workspaces"
        entries[#entries + 1] = item
    end

    -- Special workspaces (scratchpad + named specials)
    local specials = {
        { chord = "SUPER + S", display = "Super + S", desc = "Toggle scratchpad", kind = "toggle_special", workspace = "scratch" },
        { chord = "SUPER + ALT + S", display = "Super + Alt + S / Ctrl+Super+Shift+Up", desc = "Move window to scratchpad", kind = "window_move", args = { workspace = "special:scratch" } },
        { chord = "CTRL + SUPER + SHIFT + up", display = false, desc = "Move window to scratchpad", kind = "window_move", args = { workspace = "special:scratch" } },
        { chord = "CTRL + SUPER + SHIFT + down", display = "Ctrl + Super + Shift + Down", desc = "Move window out of scratchpad", kind = "window_move", args = { workspace = "e+0" } },
        { chord = "SUPER + M", display = "Super + M", desc = "Toggle music workspace", kind = "toggle_special", workspace = "music" },
        { chord = "SUPER + ALT + M", display = "Super + Alt + M", desc = "Move window to music workspace", kind = "window_move", args = { workspace = "special:music" } },
        { chord = "SUPER + D", display = "Super + D", desc = "Toggle communication workspace", kind = "toggle_special", workspace = "communication" },
        { chord = "SUPER + ALT + D", display = "Super + Alt + D", desc = "Move window to communication workspace", kind = "window_move", args = { workspace = "special:communication" } },
        { chord = "SUPER + R", display = "Super + R", desc = "Toggle todo workspace", kind = "toggle_special", workspace = "todo" },
        { chord = "SUPER + ALT + R", display = "Super + Alt + R", desc = "Move window to todo workspace", kind = "window_move", args = { workspace = "special:todo" } },
    }
    for _, item in ipairs(specials) do
        item.group = "Workspaces"
        entries[#entries + 1] = item
    end

    -- Hardware OSD & Media via Noctalia native IPC
    local media = {
        {
            chord = "XF86AudioRaiseVolume",
            display = "XF86AudioRaiseVolume",
            desc = "Raise volume",
            kind = "exec",
            cmd = "noctalia msg volume-up",
            locked = true,
            repeating = true,
        },
        {
            chord = "XF86AudioLowerVolume",
            display = "XF86AudioLowerVolume",
            desc = "Lower volume",
            kind = "exec",
            cmd = "noctalia msg volume-down",
            locked = true,
            repeating = true,
        },
        {
            chord = "XF86AudioMute",
            display = "XF86AudioMute / Super + Shift + M",
            desc = "Toggle audio mute",
            kind = "exec",
            cmd = "noctalia msg volume-mute",
            locked = true,
        },
        {
            chord = "SUPER + SHIFT + M",
            display = false,
            desc = "Toggle audio mute",
            kind = "exec",
            cmd = "noctalia msg volume-mute",
            locked = true,
        },
        {
            chord = "XF86AudioMicMute",
            display = "XF86AudioMicMute",
            desc = "Toggle microphone mute",
            kind = "exec",
            cmd = "noctalia msg mic-mute",
            locked = true,
        },
        {
            chord = "XF86MonBrightnessUp",
            display = "XF86MonBrightnessUp",
            desc = "Raise screen brightness",
            kind = "exec",
            cmd = "noctalia msg brightness-up",
            locked = true,
            repeating = true,
        },
        {
            chord = "XF86MonBrightnessDown",
            display = "XF86MonBrightnessDown",
            desc = "Lower screen brightness",
            kind = "exec",
            cmd = "noctalia msg brightness-down",
            locked = true,
            repeating = true,
        },
        {
            chord = "XF86AudioPlay",
            display = "XF86AudioPlay / Ctrl + Super + Space",
            desc = "Play or pause media",
            kind = "exec",
            cmd = "noctalia msg media play-pause",
            locked = true,
        },
        {
            chord = "XF86AudioPause",
            display = false,
            desc = "Play or pause media",
            kind = "exec",
            cmd = "noctalia msg media play-pause",
            locked = true,
        },
        {
            chord = "CTRL + SUPER + Space",
            display = false,
            desc = "Play or pause media",
            kind = "exec",
            cmd = "noctalia msg media play-pause",
            locked = true,
        },
        {
            chord = "XF86AudioNext",
            display = "XF86AudioNext / Ctrl + Super + =",
            desc = "Next media track",
            kind = "exec",
            cmd = "noctalia msg media next",
            locked = true,
        },
        {
            chord = "CTRL + SUPER + Equal",
            display = false,
            desc = "Next media track",
            kind = "exec",
            cmd = "noctalia msg media next",
            locked = true,
        },
        {
            chord = "XF86AudioPrev",
            display = "XF86AudioPrev / Ctrl + Super + -",
            desc = "Previous media track",
            kind = "exec",
            cmd = "noctalia msg media previous",
            locked = true,
        },
        {
            chord = "CTRL + SUPER + Minus",
            display = false,
            desc = "Previous media track",
            kind = "exec",
            cmd = "noctalia msg media previous",
            locked = true,
        },
        {
            chord = "XF86AudioStop",
            display = "XF86AudioStop / Ctrl + Super + Backspace",
            desc = "Stop media playback",
            kind = "exec",
            cmd = "noctalia msg media stop",
            locked = true,
        },
        {
            chord = "CTRL + SUPER + Backspace",
            display = false,
            desc = "Stop media playback",
            kind = "exec",
            cmd = "noctalia msg media stop",
            locked = true,
        },
    }
    for _, item in ipairs(media) do
        item.group = "Media"
        entries[#entries + 1] = item
    end

    return entries
end

function M.format_rows(cfg)
    local rows = {}
    for _, entry in ipairs(M.build(cfg)) do
        if entry.display ~= false then
            local chord = type(entry.display) == "string" and entry.display or entry.chord
            local desc = entry.display_desc or entry.desc or ""
            rows[#rows + 1] = string.format("[%s]  %-36s  %s", entry.group or "Other", chord, desc)
        end
    end
    return rows
end

return M
