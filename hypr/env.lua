local ctx = require("kaze._ctx")
local cfg = ctx.cfg

local home = os.getenv("HOME") or ""
local local_bin = home .. "/.local/bin"
local cur_path = os.getenv("PATH") or "/usr/local/bin:/usr/bin:/bin"
if not (":" .. cur_path .. ":"):find(":" .. local_bin .. ":", 1, true) then
    hl.env("PATH", local_bin .. ":" .. cur_path)
end

-- Kaze owns the systemd target and exports only its Wayland activation variables.
hl.env("HYPRLAND_NO_SD_VARS", "1")
hl.env("XDG_CURRENT_DESKTOP", "Hyprland")
hl.env("XDG_SESSION_TYPE", "wayland")
hl.env("XDG_SESSION_DESKTOP", "Hyprland")

hl.env("GDK_BACKEND", "wayland,x11")
hl.env("QT_QPA_PLATFORM", "wayland;xcb")
hl.env("QT_WAYLAND_DISABLE_WINDOWDECORATION", "1")
hl.env("QT_AUTO_SCREEN_SCALE_FACTOR", "1")
hl.env("SDL_VIDEODRIVER", "wayland,x11")
hl.env("CLUTTER_BACKEND", "wayland")
hl.env("ELECTRON_OZONE_PLATFORM_HINT", "auto")
hl.env("_JAVA_AWT_WM_NONREPARENTING", "1")

local _, all, ctype = require("kaze.fs").utf8_locale()
if all ~= (os.getenv("LC_ALL") or "") then hl.env("LC_ALL", all) end
if ctype ~= os.getenv("LC_CTYPE") then hl.env("LC_CTYPE", ctype) end

hl.env("XCURSOR_THEME", cfg.cursor_theme)
hl.env("XCURSOR_SIZE", tostring(cfg.cursor_size))
hl.env("TERMINAL", cfg.terminal)

if cfg.fcitx5 == true or (cfg.fcitx5 ~= false and cfg.profile == "full") then
    hl.env("XMODIFIERS", "@im=fcitx")
end

if type(cfg.drm_devices) == "string" and cfg.drm_devices ~= "" then
    hl.env("AQ_DRM_DEVICES", cfg.drm_devices)
end

if cfg.prefer_mesa_egl == true then
    hl.env("__EGL_VENDOR_LIBRARY_FILENAMES", "/usr/share/glvnd/egl_vendor.d/50_mesa.json")
end

