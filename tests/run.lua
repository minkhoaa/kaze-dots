#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local repo_dir = script_dir .. "/.."
package.path = table.concat({
    repo_dir .. "/lua/?.lua",
    repo_dir .. "/lua/?/init.lua",
    package.path,
}, ";")

local fs = require("kaze.fs")
local hypr_user = require("kaze.hypr_user")
local json = require("kaze.json")
local session = require("kaze.session")

local passed = 0
local failed = 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        io.stdout:write("  [PASS] " .. name .. "\n")
    else
        failed = failed + 1
        io.stderr:write("  [FAIL] " .. name .. ": " .. tostring(err) .. "\n")
    end
end

local function assert_eq(a, b, msg)
    if a ~= b then
        error(string.format("%s: expected %s, got %s", msg or "mismatch", tostring(b), tostring(a)), 2)
    end
end

local function assert_true(cond, msg)
    if not cond then
        error(msg or "assertion failed", 2)
    end
end

local function assert_contains(str, substr, msg)
    if type(str) ~= "string" or not str:find(substr, 1, true) then
        error(string.format("%s: missing %q", msg or "substring check", tostring(substr)), 2)
    end
end

local function cmd_exists(bin)
    local ok = os.execute("command -v " .. fs.shell_quote(bin) .. " >/dev/null 2>&1")
    return ok == true or ok == 0
end

local function make_tmp_dir()
    local d = string.format("/tmp/kaze-test-%d-%d", os.time(), math.random(100000, 999999))
    fs.mkdir_p(d)
    return d
end

local function rm_rf(dir)
    os.execute("rm -rf " .. fs.shell_quote(dir))
end

local function with_stubs(fn)
    local tmp = make_tmp_dir()
    fs.mkdir_p(tmp .. "/bin")
    fs.mkdir_p(tmp .. "/runtime")
    local env = string.format(
        "env HOME=%s XDG_RUNTIME_DIR=%s XDG_CONFIG_HOME=%s XDG_DATA_HOME=%s XDG_CACHE_HOME=%s HYPRLAND_INSTANCE_SIGNATURE='' WAYLAND_DISPLAY='' PATH=%s:$PATH",
        fs.shell_quote(tmp),
        fs.shell_quote(tmp .. "/runtime"),
        fs.shell_quote(tmp .. "/cfg"),
        fs.shell_quote(tmp .. "/data"),
        fs.shell_quote(tmp .. "/cache"),
        fs.shell_quote(tmp .. "/bin")
    )
    local function stub(name, body)
        local path = tmp .. "/bin/" .. name
        fs.write_atomic(path, "#!/bin/sh\nset -eu\n" .. body .. "\n")
        assert(os.execute("chmod +x -- " .. fs.shell_quote(path)))
    end
    local function run(cli, args, vars, bin_path)
        local bin = bin_path or (repo_dir .. "/bin/" .. cli)
        return env .. " " .. (vars or "") .. " " .. fs.shell_quote(bin) .. (args and args ~= "" and (" " .. args) or "")
    end
    local ok, err = pcall(fn, tmp, stub, run)
    rm_rf(tmp)
    if not ok then
        error(err, 0)
    end
end

io.stdout:write("Running kaze-dots (Noctalia native) unit tests...\n")

test("fs: shell_quote and atomic write work safely", function()
    assert_eq(fs.shell_quote("simple"), "'simple'")
    assert_eq(fs.shell_quote("it's here"), "'it'\\''s here'")
    local tmp = make_tmp_dir()
    local target = tmp .. "/sub/file.txt"
    fs.write_atomic(target, "hello kaze\n")
    assert_eq(fs.read_file(target), "hello kaze\n")
    assert_eq(fs.exit_status(nil, nil, nil), 1, "spawn failure")
    assert_eq(fs.exit_status(nil, "signal", 15), 143, "signal status")
    rm_rf(tmp)
end)

test("hypr_user: loads defaults, merges hypr/user.lua + profile, and recovers from syntax error", function()
    local tmp = make_tmp_dir()
    local cfg_default = hypr_user.load({
        user_path = tmp .. "/hypr/user.lua",
        profile_path = tmp .. "/kaze/profile",
    })
    assert_eq(cfg_default.profile, "minimal")
    assert_eq(cfg_default.rounding, 0)
    assert_eq(cfg_default.border_size, 2)

    fs.write_atomic(tmp .. "/kaze/profile", "full\n")
    fs.write_atomic(tmp .. "/hypr/user.lua", 'return { kb_layout = "de", smart_gaps = true, blur = { passes = 2 } }\n')
    local cfg = hypr_user.load({
        user_path = tmp .. "/hypr/user.lua",
        profile_path = tmp .. "/kaze/profile",
    })
    assert_eq(cfg.profile, "full")
    assert_eq(cfg.kb_layout, "de")
    assert_eq(cfg.smart_gaps, true)
    assert_eq(cfg.blur.passes, 2)
    assert_eq(cfg.blur.size, 3, "deep merge keeps unset nested defaults")

    fs.write_atomic(tmp .. "/hypr/user.lua", "return { broken = ")
    local cfg_fb = hypr_user.load({
        user_path = tmp .. "/hypr/user.lua",
        profile_path = tmp .. "/kaze/profile",
    })
    assert_eq(cfg_fb.kb_layout, "us", "falls back cleanly on broken user.lua")
    rm_rf(tmp)
end)

test("native configs: config/noctalia/config.toml and config/foot/foot.ini validate cleanly", function()
    local noc_src = assert(fs.read_file(repo_dir .. "/config/noctalia/config.toml"))
    assert_contains(noc_src, "offline_mode = true\n", "offline mode")
    assert_contains(noc_src, "telemetry_enabled = false\n", "zero telemetry")
    assert_contains(noc_src, "external_ip_enabled = false\n", "no external ip checks")
    assert_contains(noc_src, "corner_radius_scale = 0.0\n", "sharp 0px corners")
    assert_contains(noc_src, "popup_shadows = false\n", "no popup shadows")
    assert_contains(noc_src, 'auto_update = "none"\n', "plugins auto_update none")
    assert_contains(noc_src, "[weather]\nenabled = false\n", "weather disabled")
    assert_contains(noc_src, "[calendar]\nenabled = false\n", "calendar disabled")
    assert_contains(noc_src, "[system.monitor]\nenabled = false\n", "sysmon disabled")
    assert_contains(noc_src, "[dock]\nenabled = false\n", "dock disabled")
    assert_contains(noc_src, "[desktop_widgets]\nenabled = false\n", "desktop widgets disabled")
    assert_contains(noc_src, 'position = "left"\n', "vertical sidebar default")
    assert_contains(noc_src, "thickness = 42\n", "42px sidebar")
    assert_contains(noc_src, "enable_builtin_templates = true\n", "Noctalia built-in templates enabled")
    assert_contains(noc_src, '"hyprland"', "Noctalia Hyprland template enabled")
    assert_contains(noc_src, '"foot"', "Noctalia Foot template enabled")

    local foot_src = assert(fs.read_file(repo_dir .. "/config/foot/foot.ini"))
    assert_contains(foot_src, "include=~/.config/foot/themes/noctalia\n", "foot includes Noctalia theme")

    assert_contains(noc_src, '"record"', "Noctalia bar includes record indicator widget")
    assert_contains(noc_src, "[widget.record]\n", "Noctalia config defines [widget.record]")
    assert_contains(noc_src, "[widget.mirror]\n", "Noctalia config defines [widget.mirror]")
    assert_contains(noc_src, "[widget.mirror.actions]\n", "Noctalia config defines [widget.mirror.actions]")
    assert_contains(noc_src, "left = \"exec kaze-record --bar\"\n", "Noctalia record widget supports click-to-stop/menu")
    assert_contains(noc_src, "[widget.hclock]\n", "Noctalia config defines horizontal clock widget")
    assert_contains(noc_src, "[widget.media]\n", "Noctalia config defines media widget")

    local yazi_src = assert(fs.read_file(repo_dir .. "/config/yazi/yazi.toml"))
    assert_contains(yazi_src, "[mgr]\n", "yazi.toml uses [mgr]")
    assert_contains(yazi_src, "sixel_fraction = 15\n", "yazi.toml tunes Sixel previews for Foot")
    assert_contains(yazi_src, "imv", "yazi.toml routes images to imv")
    assert_contains(yazi_src, "zathura", "yazi.toml routes PDFs to zathura")

    local yazi_theme = assert(fs.read_file(repo_dir .. "/config/yazi/theme.toml"))
    assert_true(not yazi_theme:find("#[0-9a-fA-F][0-9a-fA-F]"), "yazi theme.toml must use ANSI colors only, not hex")
    assert_contains(yazi_theme, "[status]\n", "yazi theme.toml defines [status]")

    local yazi_keys = assert(fs.read_file(repo_dir .. "/config/yazi/keymap.toml"))
    assert_contains(yazi_keys, "prepend_keymap", "yazi keymap.toml defines prepend_keymap")

    local zathura_src = assert(fs.read_file(repo_dir .. "/config/zathura/zathurarc"))
    assert_contains(zathura_src, 'set guioptions ""\n', "zathurarc hides extra GUI chrome")
    assert_contains(zathura_src, 'set selection-clipboard "clipboard"\n', "zathurarc copies directly to clipboard")
    assert_true(not zathura_src:find("smooth-scroll", 1, true), "zathurarc must not use removed smooth-scroll option")

    local imv_src = assert(fs.read_file(repo_dir .. "/config/imv/config"))
    assert_contains(imv_src, "overlay = false\n", "imv hides overlay bar by default")
    assert_contains(imv_src, "wl-copy", "imv binds clipboard copy via wl-copy")

    local mime_src = assert(fs.read_file(repo_dir .. "/config/mimeapps.list"))
    assert_contains(mime_src, "inode/directory=thunar.desktop;\n", "mimeapps routes directories to thunar")
    assert_contains(mime_src, "application/pdf=org.pwmt.zathura.desktop;\n", "mimeapps routes PDFs to zathura")
    assert_contains(mime_src, "image/png=imv.desktop;\n", "mimeapps routes PNGs to imv")

    local gtk_ini = assert(fs.read_file(repo_dir .. "/config/gtk-3.0/settings.ini"))
    assert_contains(gtk_ini, "gtk-theme-name=adw-gtk3-dark\n", "GTK3 pairs adw-gtk3-dark with Noctalia CSS")
    assert_contains(gtk_ini, "gtk-enable-animations=0\n", "GTK3 disables animations for snappy Thunar UI")

    local thunar_css = assert(fs.read_file(repo_dir .. "/config/gtk-3.0/kaze-thunar.css"))
    assert_true(not thunar_css:find("#[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]"), "kaze-thunar.css must use Noctalia @define-color variables, not hex")
    assert_contains(thunar_css, "@window_bg_color", "kaze-thunar.css binds Noctalia window background")
    assert_contains(thunar_css, "border-radius: 0px;", "kaze-thunar.css enforces sharp Omarchy corners")

    local thunar_xml = assert(fs.read_file(repo_dir .. "/config/xfce4/xfconf/xfce-perchannel-xml/thunar.xml"))
    assert_contains(thunar_xml, 'value="ThunarDetailsView"', "thunar.xml defaults to dense details view")
    assert_contains(thunar_xml, 'name="misc-use-csd" type="bool" value="false"', "thunar.xml disables CSD for Hyprland borders")
    assert_contains(thunar_xml, 'value="THUNAR_THUMBNAIL_MODE_NEVER"', "thunar.xml disables thumbnail daemon overhead")

    local thunar_uca = assert(fs.read_file(repo_dir .. "/config/Thunar/uca.xml"))
    assert_contains(thunar_uca, "kaze-thunar-action terminal %f", "uca.xml wires Foot terminal action")
    assert_contains(thunar_uca, "kaze-thunar-action wallpaper %f", "uca.xml wires Noctalia wallpaper action")
    assert_contains(thunar_uca, "kaze-thunar-action extract %f", "uca.xml wires safe bsdtar extraction")

    local thunar_accels = assert(fs.read_file(repo_dir .. "/config/Thunar/accels.scm"))
    assert_contains(thunar_accels, "toggle-split-view", "accels.scm configures split view shortcut")

    local yazi_desktop = assert(fs.read_file(repo_dir .. "/config/applications/yazi.desktop"))
    assert_contains(yazi_desktop, "TryExec=yazi\n", "yazi.desktop hides when yazi is uninstalled")
    assert_contains(yazi_desktop, "Exec=kaze-footclient -N -e yazi %f\n", "yazi.desktop launches via kaze-footclient")

    local zshrc_src = assert(fs.read_file(repo_dir .. "/config/zsh/zshrc"))
    assert_contains(zshrc_src, "$XDG_CONFIG_HOME/zsh/conf.d", "zshrc loads conf.d modules")
    assert_contains(zshrc_src, "$XDG_CONFIG_HOME/zsh/user.zsh", "zshrc supports user.zsh overrides")
    assert_contains(zshrc_src, "zsh-syntax-highlighting.zsh", "zshrc loads syntax-highlighting when present")
    local user_pos = assert(zshrc_src:find("user.zsh", 1, true))
    local hl_pos = assert(zshrc_src:find("zsh-syntax-highlighting.zsh", 1, true))
    assert_true(user_pos < hl_pos, "zsh-syntax-highlighting must be sourced strictly after user.zsh")

    local zprof_src = assert(fs.read_file(repo_dir .. "/config/zsh/zprofile"))
    assert_contains(zprof_src, "EDITOR=", "zprofile sets default EDITOR")
    assert_contains(zprof_src, "zprofile.local", "zprofile supports zprofile.local")
    assert_contains(zprof_src, "exec start-hyprland -- -c", "zprofile launches Hyprland via start-hyprland")

    for _, mod in ipairs({ "10-options.zsh", "20-completion.zsh", "30-keybinds.zsh", "40-tools.zsh", "50-aliases.zsh", "60-prompt.zsh" }) do
        assert_true(fs.file_exists(repo_dir .. "/config/zsh/conf.d/" .. mod), "missing zsh module: " .. mod)
    end
    local tools_src = assert(fs.read_file(repo_dir .. "/config/zsh/conf.d/40-tools.zsh"))
    assert_contains(tools_src, "zsh-autosuggestions.zsh", "40-tools.zsh loads autosuggestions when present")
    for _, cmd in ipairs({ "fzf", "zoxide", "bat", "yazi" }) do
        assert_contains(tools_src, "$+commands[" .. cmd .. "]", "40-tools.zsh guards " .. cmd)
    end
    local prompt_src = assert(fs.read_file(repo_dir .. "/config/zsh/conf.d/60-prompt.zsh"))
    assert_contains(prompt_src, "$+commands[starship]", "60-prompt.zsh guards starship")
    assert_contains(prompt_src, "vcs_info", "60-prompt.zsh provides native vcs_info fallback")

    local starship_src = assert(fs.read_file(repo_dir .. "/config/starship/starship.toml"))
    assert_contains(starship_src, "add_newline = false\n", "starship single-line config")
    assert_contains(starship_src, "❯", "starship character symbol")
    assert_true(not starship_src:find("#[0-9a-fA-F][0-9a-fA-F]"), "starship.toml must use ANSI colors only, not hex")

    local tmp = make_tmp_dir()
    if cmd_exists("noctalia") then
        local val_out = assert(fs.capture("noctalia config validate " .. fs.shell_quote(repo_dir .. "/config/noctalia/config.toml") .. " 2>&1"))
        assert_true(not val_out:find("WARN"), "noctalia config validate must have 0 warnings:\n" .. val_out)
    end
    if cmd_exists("foot") then
        fs.write_atomic(tmp .. "/themes/noctalia", "")
        local test_foot = foot_src:gsub("~/.config/foot/themes/noctalia", tmp .. "/themes/noctalia")
        fs.write_atomic(tmp .. "/foot.ini", test_foot)
        local ok_foot = os.execute("foot --check-config --config " .. fs.shell_quote(tmp .. "/foot.ini") .. " >/dev/null 2>&1")
        assert_true(ok_foot == true or ok_foot == 0, "foot --check-config must succeed")
    end
    if cmd_exists("zsh") then
        local zsh_files = {
            repo_dir .. "/config/zsh/zshrc",
            repo_dir .. "/config/zsh/zprofile",
        }
        for _, mod in ipairs({ "10-options.zsh", "20-completion.zsh", "30-keybinds.zsh", "40-tools.zsh", "50-aliases.zsh", "60-prompt.zsh" }) do
            zsh_files[#zsh_files + 1] = repo_dir .. "/config/zsh/conf.d/" .. mod
        end
        for _, zf in ipairs(zsh_files) do
            local ok_zsh = os.execute("zsh -n " .. fs.shell_quote(zf) .. " >/dev/null 2>&1")
            assert_true(ok_zsh == true or ok_zsh == 0, "zsh -n must pass on " .. zf)
        end
    end
    local xdph_src = assert(fs.read_file(repo_dir .. "/config/hypr/xdph.conf"))
    assert_contains(xdph_src, "max_fps = 60\n", "xdph.conf caps screencopy framerate at 60 FPS")
    assert_contains(xdph_src, "allow_token_by_default = true\n", "xdph.conf enables restore tokens by default")
    rm_rf(tmp)
end)

test("apply: reapply preserves user Noctalia GUI edits, uninstall baseline, and hypr/user.lua", function()
    with_stubs(function(tmp)
        local q = fs.shell_quote
        local cfg = tmp .. "/config space"
        local data = tmp .. "/data space"
        local unit = cfg .. "/systemd/user/kaze-noctalia.service"
        local noc_cfg = cfg .. "/noctalia/config.toml"
        local foot = cfg .. "/foot/foot.ini"
        local starship = cfg .. "/starship.toml"
        local zshrc = tmp .. "/.zshrc"
        local user_zsh = cfg .. "/zsh/user.zsh"
        local zprof_local = cfg .. "/zsh/zprofile.local"
        local custom_conf = cfg .. "/zsh/conf.d/99-custom.zsh"
        local user_lua = cfg .. "/hypr/user.lua"
        local user_wall = tmp .. "/Pictures/Wallpapers/my-custom.jpg"

        fs.write_atomic(user_lua, "return {} -- original hypr user settings\n")
        fs.write_atomic(user_wall, "user-wallpaper-bytes\n")
        fs.write_atomic(unit, "original unit\n")
        fs.write_atomic(noc_cfg, "# pre-existing user noctalia config\n")
        fs.write_atomic(starship, "# pre-existing user starship config\n")
        fs.write_atomic(zshrc, "# pre-existing user zshrc\n")
        fs.write_atomic(user_zsh, "# user-owned zsh overrides\n")
        fs.write_atomic(zprof_local, "# user-owned zprofile overrides\n")
        fs.write_atomic(custom_conf, "# pre-existing user conf.d snippet\n")
        fs.mkdir_p(fs.dirname(foot))
        assert(os.execute("ln -s -- /nonexistent/fixture " .. q(foot)))

        local env = ("env HOME=%s XDG_CONFIG_HOME=%s XDG_DATA_HOME=%s XDG_CACHE_HOME=%s XDG_RUNTIME_DIR=%s"):format(
            q(tmp), q(cfg), q(data), q(tmp .. "/cache"), q(tmp .. "/runtime"))
        local apply = env .. " " .. q(repo_dir .. "/scripts/apply.sh") .. " --yes >/dev/null"
        local last = cfg .. "/kaze/last-backup"

        assert(os.execute(apply))
        local first = assert(fs.read_file(last)):gsub("\n$", "")
        local seeded_noc = assert(fs.read_file(noc_cfg))
        assert_contains(seeded_noc, "offline_mode = true\n")
        assert_contains(seeded_noc, 'directory = "' .. tmp .. '/Pictures/Wallpapers"\n', "expands wallpaper directory")
        assert_contains(seeded_noc, 'default = "' .. tmp .. '/Pictures/Wallpapers/05-kanagawa.jpg"\n', "expands default wallpaper path")
        assert_true(not seeded_noc:find("~/Pictures/Wallpapers", 1, true), "leaves no unexpanded ~/Pictures/Wallpapers")
        assert_eq(fs.read_file(user_wall), "user-wallpaper-bytes\n", "preserves pre-existing user wallpaper")
        assert_true(fs.file_exists(cfg .. "/foot/themes/noctalia"), "seeds empty Foot Noctalia theme")
        assert_true(os.execute("test -L " .. q(tmp .. "/.config/foot/themes/noctalia")), "links ~/.config/foot/themes/noctalia when XDG_CONFIG_HOME is custom")
        assert_eq(fs.read_file(user_zsh), "# user-owned zsh overrides\n")
        assert_eq(fs.read_file(zprof_local), "# user-owned zprofile overrides\n")

        -- Simulate user customizing Noctalia via Settings GUI between applies
        fs.write_atomic(noc_cfg, assert(fs.read_file(noc_cfg)) .. "# user GUI tweak\n")
        assert(os.execute(apply))
        local second = assert(fs.read_file(last)):gsub("\n$", "")
        assert_true(first ~= second)
        assert_contains(assert(fs.read_file(noc_cfg)), "# user GUI tweak\n", "reapply preserves user Noctalia GUI edits")
        assert_eq(fs.read_file(user_zsh), "# user-owned zsh overrides\n")
        assert_eq(fs.read_file(zprof_local), "# user-owned zprofile overrides\n")

        local manifest = assert(fs.read_file(second .. "/installed.list"))
        assert_contains(manifest, tmp .. "/.local/bin/kaze-session\n")
        assert_contains(manifest, tmp .. "/.local/bin/kaze-project\n")
        assert_contains(manifest, cfg .. "/hypr/xdph.conf\n")
        assert_contains(manifest, cfg .. "/systemd/user/kaze-noctalia.service\n")
        assert_contains(manifest, cfg .. "/foot/foot.ini\n")
        assert_contains(manifest, cfg .. "/starship.toml\n")
        assert_contains(manifest, cfg .. "/yazi/yazi.toml\n")
        assert_contains(manifest, cfg .. "/yazi/theme.toml\n")
        assert_contains(manifest, cfg .. "/yazi/keymap.toml\n")
        assert_contains(manifest, cfg .. "/zathura/zathurarc\n")
        assert_contains(manifest, cfg .. "/imv/config\n")
        assert_contains(manifest, cfg .. "/mimeapps.list\n")
        assert_contains(manifest, cfg .. "/gtk-3.0/settings.ini\n")
        assert_contains(manifest, cfg .. "/gtk-3.0/kaze-thunar.css\n")
        assert_contains(manifest, cfg .. "/gtk-3.0/kaze-style.css\n")
        assert_contains(manifest, cfg .. "/gtk-3.0/gtk.css\n")
        assert_contains(manifest, cfg .. "/noctalia/palettes/Kaze-Swiss.json\n")
        assert_contains(manifest, cfg .. "/noctalia/palettes/Kaze-Phosphor.json\n")
        assert_contains(manifest, cfg .. "/noctalia/palettes/Kaze-Amber.json\n")
        assert_contains(manifest, cfg .. "/noctalia/palettes/Kaze-Retro90s.json\n")
        assert_contains(manifest, cfg .. "/noctalia/palettes/Kaze-RosePine.json\n")
        assert_contains(manifest, cfg .. "/noctalia/palettes/Kaze-Everforest.json\n")
        assert_contains(manifest, cfg .. "/noctalia/palettes/Kaze-Monochrome.json\n")
        assert_contains(manifest, cfg .. "/noctalia/palettes/Kaze-Sakura.json\n")
        assert_contains(manifest, tmp .. "/Pictures/Wallpapers/05-kanagawa.jpg\n")
        assert_contains(manifest, tmp .. "/Pictures/Wallpapers/10-swiss-light.jpg\n")
        assert_contains(manifest, cfg .. "/Thunar/uca.xml\n")
        assert_contains(manifest, cfg .. "/Thunar/accels.scm\n")
        assert_contains(manifest, cfg .. "/xfce4/xfconf/xfce-perchannel-xml/thunar.xml\n")
        assert_contains(manifest, data .. "/applications/yazi.desktop\n")
        local gtk_css = assert(fs.read_file(cfg .. "/gtk-3.0/gtk.css"))
        assert_contains(gtk_css, '@import url("noctalia.css");\n', "gtk.css imports noctalia.css")
        assert_contains(gtk_css, '@import url("kaze-thunar.css");\n', "gtk.css imports kaze-thunar.css")
        assert_contains(gtk_css, '@import url("kaze-style.css");\n', "gtk.css imports kaze-style.css")
        assert_contains(manifest, cfg .. "/noctalia/config.toml\n")
        assert_contains(manifest, tmp .. "/.zshrc\n")
        assert_contains(manifest, tmp .. "/.zprofile\n")
        assert_contains(manifest, cfg .. "/zsh/conf.d\n")

        local function rollback(dir)
            return os.execute(env .. " " .. q(dir .. "/rollback.sh") .. " --yes >/dev/null 2>&1")
        end
        assert_true(not rollback(first), "stale rollback must be rejected")
        assert(rollback(second))
        assert_eq(fs.read_file(unit), "original unit\n")
        assert_eq(fs.read_file(noc_cfg), "# pre-existing user noctalia config\n")
        assert_eq(fs.read_file(starship), "# pre-existing user starship config\n")
        assert_eq(fs.read_file(zshrc), "# pre-existing user zshrc\n")
        assert_eq(fs.read_file(custom_conf), "# pre-existing user conf.d snippet\n")
        assert_eq(fs.read_file(user_zsh), "# user-owned zsh overrides\n")
        assert_eq(fs.read_file(zprof_local), "# user-owned zprofile overrides\n")
        assert_eq(fs.capture("readlink -- " .. q(foot)), "/nonexistent/fixture\n")
        assert_eq(fs.read_file(user_lua), "return {} -- original hypr user settings\n")
        assert_eq(fs.read_file(user_wall), "user-wallpaper-bytes\n", "rollback preserves user-owned wallpaper")
        assert_true(not fs.file_exists(last), "rollback unregisters active backup")
        for _, path in ipairs({
            tmp .. "/.local/bin/kaze-session",
            tmp .. "/.local/bin/kaze-project",
            tmp .. "/.zprofile",
            data .. "/kaze-dots/lua/kaze",
            data .. "/applications/yazi.desktop",
            cfg .. "/foot/themes/noctalia",
            tmp .. "/.config/foot/themes/noctalia",
            cfg .. "/yazi/yazi.toml",
            cfg .. "/zathura/zathurarc",
            cfg .. "/imv/config",
            cfg .. "/mimeapps.list",
            cfg .. "/gtk-3.0/settings.ini",
            cfg .. "/gtk-3.0/kaze-thunar.css",
            cfg .. "/gtk-3.0/kaze-style.css",
            cfg .. "/gtk-3.0/gtk.css",
            cfg .. "/noctalia/palettes/Kaze-Swiss.json",
            cfg .. "/noctalia/palettes/Kaze-Phosphor.json",
            cfg .. "/noctalia/palettes/Kaze-Amber.json",
            cfg .. "/noctalia/palettes/Kaze-Retro90s.json",
            cfg .. "/noctalia/palettes/Kaze-RosePine.json",
            cfg .. "/noctalia/palettes/Kaze-Everforest.json",
            cfg .. "/noctalia/palettes/Kaze-Monochrome.json",
            cfg .. "/noctalia/palettes/Kaze-Sakura.json",
            tmp .. "/Pictures/Wallpapers/05-kanagawa.jpg",
            tmp .. "/Pictures/Wallpapers/10-swiss-light.jpg",
            cfg .. "/Thunar/uca.xml",
            cfg .. "/Thunar/accels.scm",
            cfg .. "/xfce4/xfconf/xfce-perchannel-xml/thunar.xml",
        }) do
            assert(os.execute("test ! -e " .. q(path) .. " && test ! -L " .. q(path)))
        end
        assert_true(not rollback(second), "a second rollback cannot delete restored files")
    end)
end)

test("kaze-footclient & kaze-session: copied helpers pass live Noctalia theme overrides and propagate exit status", function()
    with_stubs(function(tmp, stub, run)
        local q = fs.shell_quote
        local target = tmp .. "/data/kaze-dots/lua"
        fs.mkdir_p(fs.dirname(target))
        local repo = assert(fs.capture("readlink -f -- " .. q(repo_dir))):gsub("\n$", "")
        assert(os.execute("ln -s -- " .. q(repo .. "/lua") .. " " .. q(target)))
        local tools = tmp .. "/outside 'bin'"
        fs.mkdir_p(tools)
        for _, cli in ipairs({ "kaze-footclient", "kaze-session" }) do
            assert(os.execute("cp -- " .. q(repo .. "/bin/" .. cli) .. " " .. q(tools .. "/" .. cli)))
        end
        fs.write_atomic(tmp .. "/cfg/foot/themes/noctalia", "[colors-dark]\nbackground=1a1b26\nforeground=c0caf5\n")
        stub("footclient", [[
[ "$1" = -E ]
printf '%s\n' "$@" > "$HOME/client-args"
exit "${CLIENT_STATUS:-0}"
]])
        assert(os.execute(run("", "-N /bin/true", nil, tools .. "/kaze-footclient")))
        local client_args = assert(fs.read_file(tmp .. "/client-args"))
        assert_contains(client_args, "-E\n")
        assert_contains(client_args, "--server-socket=")
        assert_contains(client_args, "colors-dark.background=1a1b26\n")
        assert_contains(client_args, "-N\n/bin/true\n")
        local _, _, st37 = os.execute(run("", "/bin/true", "CLIENT_STATUS=37", tools .. "/kaze-footclient"))
        assert_eq(st37, 37, "propagate exit code")

        -- Verify session.render_environment works cleanly without kaze-sync
        local env_text = session.render_environment(hypr_user.defaults())
        assert_contains(env_text, 'XCURSOR_THEME="Adwaita"\n')
        assert_contains(env_text, 'KAZE_PROFILE="minimal"\n')
        assert_contains(env_text, 'KAZE_ENABLE_FCITX5="0"\n')

        local hybrid_cfg = hypr_user.defaults()
        hybrid_cfg.drm_devices = "/dev/dri/card1"
        hybrid_cfg.prefer_mesa_egl = true
        local hybrid_env = session.render_environment(hybrid_cfg)
        assert_contains(hybrid_env, 'AQ_DRM_DEVICES="/dev/dri/card1"\n')
        assert_contains(hybrid_env, '__EGL_VENDOR_LIBRARY_FILENAMES="/usr/share/glvnd/egl_vendor.d/50_mesa.json"\n')
    end)
end)

test("rules: Noctalia layer no_anim, Settings float, smart_gaps, and TUI drawer rules", function()
    local function run_rules(cfg_override, noc_colors)
        local wins, ws_rules, layers = {}, {}, {}
        local prev_hl, prev_ctx = rawget(_G, "hl"), package.loaded["kaze._ctx"]
        local cfg = hypr_user.defaults()
        for k, v in pairs(cfg_override or {}) do cfg[k] = v end
        rawset(_G, "hl", {
            window_rule = function(r) wins[#wins + 1] = r end,
            workspace_rule = function(r) ws_rules[#ws_rules + 1] = r end,
            layer_rule = function(r) layers[#layers + 1] = r end,
        })
        package.loaded["kaze._ctx"] = { cfg = cfg, noctalia = noc_colors and { colors = noc_colors } or nil }
        local ok, err = pcall(dofile, repo_dir .. "/hypr/rules.lua")
        rawset(_G, "hl", prev_hl)
        package.loaded["kaze._ctx"] = prev_ctx
        if not ok then error(err, 0) end
        return wins, ws_rules, layers
    end

    local wins, ws_rules, layers = run_rules({ smart_gaps = true }, { error = "rgb(f7768e)", secondary = "rgb(9ece6a)" })
    local by_name = {}
    for _, r in ipairs(wins) do if r.name then by_name[r.name] = r end end
    assert_true(by_name["noctalia-settings"] ~= nil and by_name["noctalia-settings"].float == true)
    assert_true(by_name["kaze-tui-drawer"] ~= nil and by_name["kaze-tui-drawer"].float == true)
    assert_true(by_name["kaze-mirror-tui"] ~= nil and by_name["kaze-mirror-tui"].float == true and by_name["kaze-mirror-tui"].center == true)
    assert_eq(by_name["kaze-mirror-tui"].match.class, "^kaze-mirror-tui$")
    assert_true(by_name["kaze-share-preview"] ~= nil and by_name["kaze-share-preview"].float == true and by_name["kaze-share-preview"].pin == true)
    assert_eq(by_name["kaze-share-preview"].keep_aspect_ratio, true)
    assert_eq(by_name["kaze-share-preview"].match.class, "^at\\.yrlf\\.wl_mirror$")
    assert_true(by_name["kaze-share-control"] ~= nil and by_name["kaze-share-control"].no_focus == true and by_name["kaze-share-control"].opaque == true and by_name["kaze-share-control"].no_blur == true)
    assert_eq(by_name["kaze-share-control"].match.class, "^at\\.yrlf\\.wl_mirror$")
    assert_eq(by_name["kaze-share-control"].match.title, "^kaze-share-control$")
    assert_eq(by_name["state-border-pinned"].border_color, "rgb(f7768e)")
    assert_eq(by_name["state-border-fullscreen"].border_color, "rgb(9ece6a)")
    assert_true(#ws_rules >= 3, "smart_gaps + special workspace rules")

    local has_noctalia_layer = false
    for _, l in ipairs(layers) do
        if l.name == "noctalia-no-anim" and l.no_anim == true then
            has_noctalia_layer = true
        end
    end
    assert_true(has_noctalia_layer, "noctalia-no-anim layer rule must be present")
end)

test("kaze.json: strict decode and deterministic encode", function()
    local obj = json.decode('{"a":1,"n":null,"b":[true,false,"hi\\n\\u0041"],"s":"\\uD83D\\uDE00"}')
    assert_eq(obj.a, 1)
    assert_eq(obj.n, nil)
    assert_eq(obj.b[1], true)
    assert_eq(obj.b[2], false)
    assert_eq(obj.b[3], "hi\nA")
    assert_eq(obj.s, "\240\159\152\128")
    local encoded = json.encode({ z = 1, a = "hi" })
    assert_true(encoded:find('"a"') < encoded:find('"z"'), "encode sorts object keys")
    assert_eq(json.decode(encoded).a, "hi")
    for _, bad in ipairs({ "", "{", "[1,2", '{"a":}', "123 trailing" }) do
        assert_true(not pcall(json.decode, bad), "must reject invalid JSON: " .. bad)
    end
end)

test("kaze-tui: toggles floating btop via footclient", function()
    with_stubs(function(tmp, stub, run)
        stub("btop", "exit 0")
        stub("footclient", [[printf '%s\n' "$@" > "$HOME/tui-args"]])
        stub("hyprctl", [[
if [ "$1" = "-j" ] && [ "$2" = "clients" ]; then
    printf '[]\n'
elif [ "$1" = "-j" ] && [ "$2" = "activewindow" ]; then
    printf '{}\n'
fi
]])
        assert(os.execute(run("kaze-tui", "sysmon", "HYPRLAND_INSTANCE_SIGNATURE=sig-1")))
        local args = assert(fs.read_file(tmp .. "/tui-args"))
        assert_contains(args, "-a\nkaze-tui\n")
        assert_contains(args, "btop\n")
    end)
end)

test("kaze.projects & kaze-project: discovers zoxide/fd projects, compacts paths, and launches modes", function()
    local projects = require("kaze.projects")
    local tmp = make_tmp_dir()
    local ok_p, err_p = pcall(function()
        local home = tmp .. "/home"
        local p_alpha = home .. "/Projects/alpha"
        local p_beta = home .. "/Projects/beta"
        local p_z = home .. "/work/zeta"
        fs.mkdir_p(p_alpha .. "/.git")
        fs.mkdir_p(p_beta)
        fs.mkdir_p(p_z)

        local cmds_shell = projects.build_launch_cmds(p_alpha, "shell", { cmd_exists = function() return true end })
        assert_eq(#cmds_shell, 1)
        assert_contains(cmds_shell[1], "-N -D")
        local cmds_split = projects.build_launch_cmds(p_alpha, "split", { cmd_exists = function() return true end })
        assert_eq(#cmds_split, 2)
        assert_contains(cmds_split[1], "-e 'nvim' .")
        assert_contains(cmds_split[2], "-N -D")

        local discovered = projects.discover({ project_dirs = { "~/Projects" } }, {
            home = home,
            cmd_exists = function(bin) return bin == "zoxide" or bin == "fd" end,
            is_dir = function(d) return d == home .. "/Projects" or d == p_alpha or d == p_beta or d == p_z end,
            capture = function(cmd)
                if cmd:find("^zoxide query") then
                    return p_z .. "\n" .. p_alpha .. "\n" .. home .. "/missing\n"
                elseif cmd:find("'%.git%$'") then
                    return p_alpha .. "/.git\n"
                elseif cmd:find("max%-depth 1") then
                    return p_alpha .. "\n" .. p_beta .. "\n"
                end
                return ""
            end,
        })
        assert_eq(#discovered, 3)
        assert_eq(discovered[1].label, "~/work/zeta", "zoxide frecency first")
        assert_eq(discovered[2].label, "~/Projects/alpha", "deduplicated alpha second")
        assert_eq(discovered[3].label, "~/Projects/beta", "fd subdir third")
    end)
    rm_rf(tmp)
    if not ok_p then error(err_p, 0) end

    with_stubs(function(tmp2, stub, run)
        local q = fs.shell_quote
        for _, bin in ipairs({ "lua", "readlink", "mkdir", "find", "sort" }) do
            local actual = assert(fs.capture("command -v " .. bin)):gsub("\n$", "")
            assert(os.execute("ln -s -- " .. q(actual) .. " " .. q(tmp2 .. "/bin/" .. bin)))
        end
        fs.mkdir_p(tmp2 .. "/Projects/demo/.git")
        stub("zoxide", [[
if [ "$1" = "query" ]; then
    printf '%s/Projects/demo\n' "$HOME"
else
    printf '%s\n' "$*" >> "$HOME/zoxide-calls"
fi
]])
        stub("fd", "exit 0")
        stub("nvim", "exit 0")
        stub("footclient", [[printf '%s\n' "$@" >> "$HOME/foot-calls"]])
        stub("noctalia", [[
if [ "$1" = "dmenu" ]; then
    cat > "$HOME/proj-dmenu"
    head -n 1 "$HOME/proj-dmenu"
fi
]])
        local list_out = assert(fs.capture(run("kaze-project", "--list")))
        assert_eq(list_out, "~/Projects/demo\n")

        assert(os.execute(run("kaze-project", "--split")))
        assert_contains(assert(fs.read_file(tmp2 .. "/proj-dmenu")), "~/Projects/demo\n")
        assert_contains(assert(fs.read_file(tmp2 .. "/zoxide-calls")), "add -- " .. tmp2 .. "/Projects/demo\n")
        local fcalls
        for _ = 1, 40 do
            local raw = fs.read_file(tmp2 .. "/foot-calls")
            if raw and raw:find("-e\nnvim\n.\n", 1, true) and raw:find("-N\n-D\n" .. tmp2 .. "/Projects/demo\n", 1, true) then
                fcalls = raw
                break
            end
            os.execute("sleep 0.02")
        end
        assert_true(fcalls ~= nil, "kaze-project --split must spawn both nvim and shell footclient windows")
        assert_contains(fcalls, "-D\n" .. tmp2 .. "/Projects/demo\n-e\nnvim\n.\n")

        local ok_bad, _, code_bad = os.execute(run("kaze-project", "--mode=bogus") .. " 2>/dev/null")
        assert_true(not ok_bad and code_bad == 2)
    end)
end)

test("kaze-record: supports --menu, --bar, --audio, --gif, and Noctalia bar status", function()
    with_stubs(function(tmp, stub, run)
        local q = fs.shell_quote
        for _, bin in ipairs({ "lua", "readlink", "flock", "mkdir", "install", "mktemp", "rm", "test" }) do
            local actual = assert(fs.capture("command -v " .. bin)):gsub("\n$", "")
            assert(os.execute("ln -s -- " .. q(actual) .. " " .. q(tmp .. "/bin/" .. bin)))
        end
        stub("wf-recorder", "exit 0")
        stub("ffprobe", "exit 0")
        stub("ffmpeg", [[
out=""
for a in "$@"; do out="$a"; done
printf 'GIF89a' > "$out"
]])
        stub("notify-send", [[printf '%s\n' "$*" >> "$HOME/rec-notify"]])
        stub("pactl", [[
if [ "$1" = "get-default-sink" ]; then
    printf 'alsa_output.pci.stereo\n'
elif [ "$1" = "get-default-source" ]; then
    printf 'alsa_input.pci.mono\n'
fi
]])
        stub("hyprctl", [[
if [ "$1" = "-j" ] && [ "$2" = "monitors" ]; then
    printf '[{"name":"eDP-1","focused":true}]\n'
fi
]])
        stub("dbus-update-activation-environment", "exit 0")
        stub("systemctl", [[
case "$*" in
  *"show -p ActiveState --value kaze-session.target"*) printf 'active\n' ;;
  *"is-active --quiet kaze-session.target"*) exit 0 ;;
  *"show -p ActiveState kaze-record.service"*)
    if [ -f "$HOME/rec-active" ]; then printf 'ActiveState=active\n'; else printf 'ActiveState=inactive\n'; fi ;;
  *"start kaze-record.service"*) : > "$HOME/rec-active"; exit 0 ;;
  *"stop kaze-record.service"*)
    rm -f "$HOME/rec-active"
    rec=$(sed -n 's/^KAZE_RECORD_FILE="\(.*\)"$/\1/p' "$XDG_RUNTIME_DIR/kaze/record.env")
    printf '%s\n' "$rec" > "$XDG_RUNTIME_DIR/kaze/record.done"
    exit 0 ;;
  *) exit 0 ;;
esac
]])
        stub("noctalia", [[
if [ "$1" = "msg" ] && [ "$2" = "config-get" ]; then
    printf "'custom_button'\n"
elif [ "$1" = "msg" ] && [ "$2" = "config-set" ]; then
    printf '%s\n' "$*" >> "$HOME/noc-rec-set"
elif [ "$1" = "dmenu" ]; then
    cat > "$HOME/rec-menu"
    if [ -n "${TEST_REC_CHOICE:-}" ]; then
        grep -F -m1 "$TEST_REC_CHOICE" "$HOME/rec-menu"
    fi
fi
]])

        local vars = "HYPRLAND_INSTANCE_SIGNATURE=sig-1 WAYLAND_DISPLAY=wayland-1"
        assert(os.execute("env HOME=" .. q(tmp) .. " XDG_RUNTIME_DIR=" .. q(tmp .. "/runtime") .. " PATH=" .. q(tmp .. "/bin") .. " lua -e "
            .. q("package.path=" .. q(repo_dir .. "/lua/?.lua;") .. "..package.path; local fs=require('kaze.fs'); local s=require('kaze.session'); assert(os.execute('true'))")))

        -- Patch systemctl show-environment for session.is_active()
        stub("systemctl", [[
case "$*" in
  "--user show-environment")
    printf 'HYPRLAND_INSTANCE_SIGNATURE=sig-1\nWAYLAND_DISPLAY=wayland-1\n' ;;
  *"is-active --quiet kaze-session.target"*) exit 0 ;;
  *"show -p ActiveState kaze-record.service"*)
    if [ -f "$HOME/rec-active" ]; then printf 'ActiveState=active\n'; else printf 'ActiveState=inactive\n'; fi ;;
  *"start kaze-record.service"*) : > "$HOME/rec-active"; exit 0 ;;
  *"stop kaze-record.service"*)
    rm -f "$HOME/rec-active"
    rec=$(sed -n 's/^KAZE_RECORD_FILE="\(.*\)"$/\1/p' "$XDG_RUNTIME_DIR/kaze/record.env")
    printf '%s\n' "$rec" > "$XDG_RUNTIME_DIR/kaze/record.done"
    exit 0 ;;
  *) exit 0 ;;
esac
]])

        -- 1. Menu selection: Fullscreen + System Audio -> sets KAZE_RECORD_AUDIO=.monitor & Noctalia red indicator
        assert(os.execute(run("kaze-record", "--menu", vars .. " TEST_REC_CHOICE='Fullscreen + System Audio'")))
        local menu_txt = assert(fs.read_file(tmp .. "/rec-menu"))
        assert_contains(menu_txt, "Fullscreen + System Audio\n")
        assert_contains(menu_txt, "Region → GIF\n")
        local env_txt = assert(fs.read_file(tmp .. "/runtime/kaze/record.env"))
        assert_contains(env_txt, 'KAZE_RECORD_AUDIO="alsa_output.pci.stereo.monitor"\n')
        assert_contains(assert(fs.read_file(tmp .. "/noc-rec-set")), 'msg config-set widget.record.icon_color "error"\n')

        -- 2. Bar click while active (--bar) stops immediately and resets Noctalia indicator
        local stop_out = assert(fs.capture(run("kaze-record", "--bar", vars)))
        assert_contains(stop_out, ".mp4\n")
        assert_contains(assert(fs.read_file(tmp .. "/noc-rec-set")), 'msg config-set widget.record.icon_color "on_surface_variant"\n')

        -- 3. Fullscreen -> GIF mode produces .gif on stop
        assert(os.execute(run("kaze-record", "--gif", vars)))
        local gif_out = assert(fs.capture(run("kaze-record", "stop", vars)))
        assert_contains(gif_out, ".gif\n")
        assert_contains(assert(fs.read_file(tmp .. "/rec-notify")), "GIF saved")

        -- 4. Reject invalid --gif + --audio combination
        local ok_bad, _, code_bad = os.execute(run("kaze-record", "--gif --audio", vars) .. " 2>/dev/null")
        assert_true(not ok_bad and code_bad == 2)
    end)
end)

test("kaze.styles & kaze-style: renders all 11 presets safely, manages palettes/Hyprland/GTK3, and switches via CLI/menu", function()
    local styles = require("kaze.styles")
    local toml_diff = require("kaze.toml_diff")
    local base_tpl = assert(fs.read_file(repo_dir .. "/config/noctalia/config.toml"))
    local user_toml = base_tpl:gsub("polkit_agent = false", "polkit_agent = true")
        :gsub('directory = "~/Pictures/Wallpapers"', 'directory = "/home/user/Wallpapers"')

    -- Verify all 8 custom Version-2 palettes decode cleanly and contain strict 6-digit hex colors
    local required_roles = {
        "primary", "on_primary", "secondary", "on_secondary", "tertiary", "on_tertiary",
        "error", "on_error", "surface", "on_surface", "surface_container", "on_surface_container",
        "surface_variant", "on_surface_variant", "outline", "outline_variant",
    }
    local required_term = {
        "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
        "bright_black", "bright_red", "bright_green", "bright_yellow",
        "bright_blue", "bright_magenta", "bright_cyan", "bright_white",
        "foreground", "background", "selection_fg", "selection_bg", "cursor", "cursor_text",
    }
    for _, pal_name in ipairs({
        "Kaze-Swiss", "Kaze-Phosphor", "Kaze-Amber", "Kaze-Retro90s",
        "Kaze-RosePine", "Kaze-Everforest", "Kaze-Monochrome", "Kaze-Sakura",
    }) do
        local raw = assert(fs.read_file(repo_dir .. "/config/noctalia/palettes/" .. pal_name .. ".json"))
        local pal = json.decode(raw)
        assert_eq(pal.version, 2, pal_name .. " must be format version 2")
        assert_eq(pal.base, pal_name, pal_name .. " base matches filename")
        for _, mode_name in ipairs({ "dark", "light" }) do
            local v = assert(pal[mode_name], pal_name .. " missing " .. mode_name)
            for _, role in ipairs(required_roles) do
                assert_true(type(v[role]) == "string" and v[role]:match("^#%x%x%x%x%x%x$") ~= nil,
                    pal_name .. "." .. mode_name .. "." .. role .. " must be #rrggbb")
            end
            assert_true(type(v.terminal) == "table", pal_name .. "." .. mode_name .. " missing terminal")
            for _, tk in ipairs(required_term) do
                assert_true(type(v.terminal[tk]) == "string" and v.terminal[tk]:match("^#%x%x%x%x%x%x$") ~= nil,
                    pal_name .. "." .. mode_name .. ".terminal." .. tk .. " must be #rrggbb")
            end
        end
    end

    -- Verify 11 presets, groups, bar_names, and backwards-compatible aliases
    assert_eq(#styles.list(), 11, "11 canonical visual presets")
    assert_eq(#styles.groups(), 3, "3 style groups")
    assert_eq(styles.resolve("floating-islands"), "corner-hud")
    assert_eq(styles.resolve("concave-notch"), "hardware-notch")
    assert_eq(styles.resolve("brutalist"), "omarchy-rail")
    assert_eq(styles.resolve("win95"), "retro-90s")
    assert_eq(table.concat(styles.bar_names("floating-rail"), ","), "default,rail")
    assert_eq(table.concat(styles.bar_names("dynamic-island"), ","), "default")

    -- Render every preset and verify Hyprland Lua + zero-hex GTK3 CSS invariants
    for _, preset in ipairs(styles.list()) do
        local rendered = assert(styles.render_config(user_toml, preset.id), "render_config " .. preset.id)
        assert_contains(rendered, "polkit_agent = true\n", preset.id .. " preserves polkit_agent")
        assert_contains(rendered, 'directory = "/home/user/Wallpapers"\n', preset.id .. " preserves wallpaper dir")
        assert_contains(rendered, "offline_mode = true\n", preset.id .. " keeps offline_mode")
        assert_contains(rendered, "telemetry_enabled = false\n", preset.id .. " keeps telemetry disabled")
        assert_contains(rendered, "[weather]\nenabled = false\n", preset.id .. " keeps weather disabled")
        assert_contains(rendered, "[widget.record]\n", preset.id .. " keeps widget.record")

        local h_lua = assert(styles.render_hypr_lua(preset.id), "render_hypr_lua " .. preset.id)
        local chunk = assert(load(h_lua, "kaze-style:" .. preset.id, "t", {}), "valid Lua chunk for " .. preset.id)
        local h_tbl = chunk()
        assert_true(type(h_tbl) == "table" and type(h_tbl.gaps_out) == "number", preset.id .. " returns Hyprland table")

        local g_css = assert(styles.render_gtk_css(preset.id), "render_gtk_css " .. preset.id)
        assert_true(not g_css:find("#[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]"), preset.id .. " GTK CSS has 0 hardcoded hex")
    end

    local ch = assert(styles.render_config(user_toml, "floating-islands"))
    assert_contains(ch, 'start = [ "group:corner_left" ]\n', "corner-hud left group")
    assert_contains(ch, "center = []\n", "corner-hud leaves center open")
    assert_contains(ch, 'end = [ "group:corner_right" ]\n', "corner-hud right group")
    assert_contains(ch, 'id = "corner_left"\n')

    local gz = assert(styles.render_config(ch, "ghost-zero"))
    assert_contains(gz, "auto_hide = true\n", "ghost-zero enables auto_hide")
    assert_contains(gz, "reserve_space = false\n", "ghost-zero disables reserve_space")
    assert_contains(assert(styles.render_hypr_lua("ghost-zero")), "ghost_super_peek = true")
    assert_contains(assert(styles.render_hypr_lua("ghost-zero")), "gaps_out = 0")

    local di = assert(styles.render_config(gz, "dynamic-island"))
    assert_contains(di, 'start = [ "group:island_left" ]\n', "dynamic-island places launcher/workspaces top-left")
    assert_contains(di, 'center = [ "group:island" ]\n', "dynamic-island centers island group")
    assert_contains(di, 'end = [ "group:island_right" ]\n', "dynamic-island places full status top-right")
    assert_contains(di, 'id = "island_left"\n', "dynamic-island defines island_left group")
    assert_contains(di, 'id = "island"\n', "dynamic-island defines island group")
    assert_contains(di, 'members = [ "island_clock", "media", "record", "present", "notifications", "control-center" ]\n', "dynamic-island places notifications & full menu in center island")
    assert_contains(di, 'id = "island_right"\n', "dynamic-island defines island_right group")
    assert_contains(di, 'members = [ "tray", "display", "mirror", "net", "bt", "vol", "bat", "session" ]\n', "dynamic-island places quick Wi-Fi/BT/Audio/Tray/Session controls top-right")
    assert_contains(di, "[widget.bt]\ntype = \"bluetooth\"\nshow_label = false\n", "dynamic-island defines bluetooth widget")
    assert_contains(di, 'fill = "surface_container"\n', "dynamic-island unifies pill fill with theme surface_container")
    assert_true(not di:find("#0b0b0e", 1, true), "dynamic-island removes hardcoded black pill fill")
    assert_contains(di, 'control_center_placement = "floating"\n', "dynamic-island floats control center away from center island")
    assert_contains(di, 'control_center_position = "auto"\n', "dynamic-island keeps control_center_position auto so open_near_click triggers dynamically")
    assert_contains(di, 'launcher_position = "auto"\n', "dynamic-island keeps launcher_position auto for open_near_click")
    assert_contains(di, 'session_position = "auto"\n', "dynamic-island keeps session_position auto for open_near_click")
    assert_contains(di, "open_near_click_control_center = true\n", "dynamic-island opens panels near clicked bar widget")
    assert_contains(di, "open_near_click_launcher = true\n", "dynamic-island opens launcher near clicked launcher icon")
    assert_contains(di, "open_near_click_session = true\n", "dynamic-island opens session panel near clicked session icon")
    assert_contains(di, "hide_when_no_media = true\n", "dynamic-island hides media when idle")
    assert_contains(di, "[widget.present]\n", "dynamic-island defines widget.present")
    assert_contains(di, 'position = "top_right"\n', "dynamic-island anchors notif/OSD top_right")

    local hn = assert(styles.render_config(di, "concave-notch"))
    assert_contains(hn, "margin_edge = 0\n", "hardware-notch flushes bar to screen edge")
    assert_contains(hn, "concave_edge_corners = true\n", "hardware-notch enables concave corners")
    assert_true(not hn:find("[[bar.default.capsule_group]]", 1, true), "hardware-notch clears capsule_group tables")

    local with_pinned = hn:gsub("%[dock%]\nenabled = false\n", '[dock]\nenabled = false\npinned = [ "firefox" ]\n')
    local gs = assert(styles.render_config(with_pinned, "glass-studio"))
    assert_contains(gs, 'transparency_mode = "glass"\n', "glass-studio enables glass panels")
    assert_contains(gs, "[dock]\nenabled = true\n", "glass-studio enables dock")
    assert_contains(gs, 'pinned = [ "firefox" ]\n', "glass-studio preserves user pinned dock apps")
    assert_contains(gs, "[widget.active_window]\n", "glass-studio defines active_window")

    local fr = assert(styles.render_config(gs, "floating-rail"))
    assert_contains(fr, 'order = [ "default", "rail" ]\n', "floating-rail declares dual bars")
    assert_contains(fr, "[bar.rail]\n", "floating-rail defines secondary bar.rail")
    assert_contains(fr, "[[bar.rail.capsule_group]]\n", "floating-rail defines rail capsule_group")
    assert_contains(fr, "[dock]\nenabled = false\n", "floating-rail disables dock")

    local sg = assert(styles.render_config(fr, "swiss-grid"))
    assert_true(not sg:find("[bar.rail]", 1, true), "switching away from floating-rail drops bar.rail")
    assert_true(not sg:find("[[bar.rail.capsule_group]]", 1, true), "switching away drops rail capsule_group")
    assert_contains(sg, 'order = [ "default" ]\n', "single-bar order restored")
    assert_contains(sg, 'mode = "light"\n', "swiss-grid activates light mode")
    assert_contains(sg, 'custom_palette = "Kaze-Swiss"\n', "swiss-grid sets Kaze-Swiss palette")
    assert_contains(sg, 'separator = " / "\n', "swiss-grid uses slash workspace separator")
    assert_contains(sg, 'custom_label = "—  BAT "\n', "swiss-grid prefixes battery separator conditionally")
    assert_contains(sg, 'empty_color = "secondary"\n', "swiss-grid sets legible light-mode empty workspace color")

    local th = assert(styles.render_config(sg, "tui-hacker"))
    assert_contains(th, 'custom_palette = "Kaze-Phosphor"\n', "tui-hacker sets Kaze-Phosphor palette")
    assert_contains(th, 'font_family = "JetBrainsMono Nerd Font"\n', "tui-hacker sets monospace font")
    assert_contains(th, 'center = [ "tui_lbr", "tui_clock", "tui_rbr" ]\n', "tui-hacker wraps clock in brackets")
    assert_contains(th, 'format = "{:%H:%M}"\n', "tui-hacker keeps raw time format inside bracket widgets")
    assert_contains(th, "[widget.tui_vol]\n", "tui-hacker includes volume block")
    assert_contains(th, 'empty_color = "on_surface_variant"\n', "tui-hacker sets visible empty workspace CRT color")

    local r9 = assert(styles.render_config(th, "retro-90s"))
    assert_contains(r9, 'position = "bottom"\n', "retro-90s places taskbar at bottom")
    assert_contains(r9, 'custom_palette = "Kaze-Retro90s"\n', "retro-90s sets Kaze-Retro90s palette")
    assert_contains(r9, "[widget.taskbar]\n", "retro-90s includes taskbar widget")
    assert_contains(r9, 'control_center_position = "auto"\n', "retro-90s enables dynamic open_near_click anchoring")
    assert_contains(r9, 'launcher_position = "bottom_left"\n', "retro-90s anchors Start menu launcher bottom_left")
    local r9_lua = assert(styles.render_hypr_lua("retro-90s"))
    assert_contains(r9_lua, "angle = 45")
    local r9_tbl = assert(load(r9_lua, "kaze-style:retro-90s", "t", {}))()
    assert_eq(r9_tbl.border_override.active.angle, 45, "retro-90s parses border gradient angle")
    assert_contains(assert(styles.render_gtk_css("retro-90s")), "rgba(255, 255, 255, 0.72)")

    local cf = assert(styles.render_config(r9, "cinema-frame"))
    assert_contains(cf, 'position = "bottom"\nthickness = 22\n', "cinema-frame uses 22px bottom strip")
    assert_contains(assert(styles.render_hypr_lua("cinema-frame")), "gaps_out = 28")

    local back = assert(styles.render_config(cf, "omarchy-rail", {
        restore_theme = { mode = "dark", source = "builtin", builtin = "Tokyo-Night", pure_black_dark = false },
    }))
    assert_contains(back, 'position = "left"\n', "round-trip back to vertical rail")
    assert_contains(back, "corner_radius_scale = 0.0\n", "round-trip restores 0px corners")
    assert_contains(back, 'builtin = "Tokyo-Night"\n', "round-trip restores builtin theme")
    assert_true(not back:find("custom_palette", 1, true), "round-trip clears custom_palette")
    assert_contains(back, "polkit_agent = true\n", "round-trip preserves polkit_agent")
    local diff_back = toml_diff.diff(base_tpl, back)
    assert_true(not diff_back.has_drift, "round-trip to omarchy-rail leaves zero drift vs repo template")
    local diff_tpl_to_back = toml_diff.diff(styles.render_template_for_style(base_tpl, "omarchy-rail"), base_tpl)
    assert_true(not diff_tpl_to_back.has_drift, "omarchy-rail template causes zero false drift against base config.toml")

    with_stubs(function(tmp, stub, run)
        local q = fs.shell_quote
        fs.mkdir_p(tmp .. "/cfg/noctalia")
        fs.mkdir_p(tmp .. "/cfg/kaze")
        fs.mkdir_p(tmp .. "/cfg/hypr")
        fs.mkdir_p(tmp .. "/cfg/gtk-3.0")
        fs.write_atomic(tmp .. "/cfg/noctalia/config.toml", user_toml)

        stub("noctalia", [[
printf '%s\n' "$@" >> "$HOME/noc-calls"
case "${1:-}" in
  config)
    [ "${2:-}" = "validate" ] || exit 1
    grep -q '\[bar\.default\]' "${3:?}" || exit 1
    exit 0
    ;;
  dmenu)
    cat > "$HOME/style-menu"
    printf '%s\n' "${TEST_STYLE_CHOICE:-  dynamic-island   | [Dynamic & Modern] | Centered pill}"
    ;;
  msg)
    exit 0
    ;;
esac
]])

        local help_out = assert(fs.capture(run("kaze-style", "--help")))
        assert_contains(help_out, "Usage: kaze-style")
        assert_contains(help_out, "swiss-grid")
        assert_contains(help_out, "retro-90s")
        local ok_bad, _, code_bad = os.execute(run("kaze-style", "--bogus") .. " 2>/dev/null")
        assert_true(not ok_bad and code_bad == 2)
        local ok_bad_p, _, code_bad_p = os.execute(run("kaze-style", "not-a-style") .. " 2>/dev/null")
        assert_true(not ok_bad_p and code_bad_p == 2)

        assert_eq(assert(fs.capture(run("kaze-style", "--current"))), "dynamic-island\n")
        local list_out = assert(fs.capture(run("kaze-style", "--list")))
        assert_contains(list_out, "Angular & Minimal:")
        assert_contains(list_out, "* dynamic-island")
        assert_contains(list_out, "  cinema-frame")

        local env_base = "XDG_CONFIG_HOME=" .. q(tmp .. "/cfg") .. " XDG_STATE_HOME=" .. q(tmp .. "/state")
        fs.mkdir_p(tmp .. "/state/noctalia")
        fs.write_atomic(tmp .. "/state/noctalia/settings.toml", [[
[bar.default]
thickness = 40

[widget.present]
enabled = false
label = ""

[widget.record]
enabled = false
]])
        local ap_out = assert(fs.capture(run("kaze-style", "floating-islands", env_base)))
        assert_contains(ap_out, "Applied style 'corner-hud'")
        assert_eq(assert(fs.read_file(tmp .. "/cfg/kaze/style")), "corner-hud\n")
        assert_true(fs.file_exists(tmp .. "/cfg/hypr/kaze-style.lua"), "writes hypr/kaze-style.lua")
        assert_true(fs.file_exists(tmp .. "/cfg/gtk-3.0/kaze-style.css"), "writes gtk-3.0/kaze-style.css")
        local cleaned_state = assert(fs.read_file(tmp .. "/state/noctalia/settings.toml"))
        assert_contains(cleaned_state, "[bar.default]\nthickness = 40\n", "preserves unrelated user state overrides")
        assert_true(not cleaned_state:find("[widget.present]", 1, true), "clears stale widget.present from Noctalia state")
        assert_true(not cleaned_state:find("[widget.record]", 1, true), "clears stale widget.record from Noctalia state")

        assert(os.execute(run("kaze-style", "swiss-grid", env_base)))
        assert_true(fs.file_exists(tmp .. "/cfg/kaze/saved-theme.json"), "saves pre-palette theme")
        assert(os.execute(run("kaze-style", "tui-hacker", env_base)))
        local saved_json = json.decode(assert(fs.read_file(tmp .. "/cfg/kaze/saved-theme.json")))
        assert_eq(saved_json.builtin, "Kanagawa", "switching between palette-locked presets keeps original saved theme")
        assert(os.execute(run("kaze-style", "omarchy-rail", env_base)))
        assert_true(not fs.file_exists(tmp .. "/cfg/kaze/saved-theme.json"), "restoring theme removes saved-theme.json")
        local restored_cfg = assert(fs.read_file(tmp .. "/cfg/noctalia/config.toml"))
        assert_contains(restored_cfg, 'mode = "dark"\n')
        assert_contains(restored_cfg, 'builtin = "Kanagawa"\n')

        local noc_calls = assert(fs.read_file(tmp .. "/noc-calls"))
        assert_contains(noc_calls, "config\nvalidate\n")
        assert_contains(noc_calls, "msg\nconfig-reload\n")
        assert_contains(noc_calls, "msg\ntemplates-apply\n")

        -- --menu switches via dmenu
        assert(os.execute(run("kaze-style", "--menu", env_base)))
        assert_contains(assert(fs.read_file(tmp .. "/style-menu")), "* omarchy-rail")
        assert_eq(assert(fs.read_file(tmp .. "/cfg/kaze/style")), "dynamic-island\n")
        assert_contains(assert(fs.read_file(tmp .. "/cfg/noctalia/config.toml")), 'id = "island"\n')

        -- Cancel (empty dmenu selection) keeps active style intact
        assert(os.execute(run("kaze-style", "--menu", env_base .. " TEST_STYLE_CHOICE=''")))
        assert_eq(assert(fs.read_file(tmp .. "/cfg/kaze/style")), "dynamic-island\n")
    end)
end)

test("kaze-thunar-action: terminal, yazi, copy-path, checksum, wallpaper, compress, and tarbomb-safe extract", function()
    with_stubs(function(tmp, stub, run)
        local q = fs.shell_quote
        stub("notify-send", "printf '%s\\n' \"$*\" >> \"$HOME/notify.log\"")
        stub("wl-copy", "cat > \"$HOME/clipboard.out\"")
        stub("noctalia", "printf '%s\\n' \"$*\" >> \"$HOME/noc.log\"")
        stub("kaze-footclient", "printf '%s\\n' \"$*\" >> \"$HOME/foot.log\"")
        stub("yazi", "exit 0")

        local help_out = assert(fs.capture(run("kaze-thunar-action", "--help")))
        assert_contains(help_out, "Usage: kaze-thunar-action")
        local ok_bad, _, code_bad = os.execute(run("kaze-thunar-action", "bogus /tmp") .. " 2>/dev/null")
        assert_true(not ok_bad and code_bad == 2)

        local work = tmp .. "/work dir"
        fs.mkdir_p(work)
        local f1 = work .. "/hello world.txt"
        local f2 = work .. "/second.txt"
        local img = work .. "/wall.png"
        fs.write_atomic(f1, "kaze thunar test\n")
        fs.write_atomic(f2, "second file\n")
        fs.write_atomic(img, "\137PNG\r\n\26\n")

        -- copy-path (multi-selection)
        assert(os.execute(run("kaze-thunar-action", "copy-path " .. q(f1) .. " " .. q(f2))))
        assert_eq(fs.read_file(tmp .. "/clipboard.out"), f1 .. "\n" .. f2)

        -- checksum
        assert(os.execute(run("kaze-thunar-action", "checksum " .. q(f1))))
        local hash = assert(fs.read_file(tmp .. "/clipboard.out"))
        assert_true(hash:match("^[0-9a-f]+$") ~= nil and #hash == 64, "sha256 hex digest copied")

        -- wallpaper via Noctalia IPC
        assert(os.execute(run("kaze-thunar-action", "wallpaper " .. q(img))))
        assert_contains(assert(fs.read_file(tmp .. "/noc.log")), "msg wallpaper-set " .. img)

        -- terminal on file opens parent directory; yazi opens file in parent dir
        assert(os.execute(run("kaze-thunar-action", "terminal " .. q(f1))))
        assert_contains(assert(fs.read_file(tmp .. "/foot.log")), "-N -D " .. work)
        assert(os.execute(run("kaze-thunar-action", "yazi " .. q(f1))))
        assert_contains(assert(fs.read_file(tmp .. "/foot.log")), "-e yazi " .. f1)

        -- compress + tarbomb-safe extract round-trip (when bsdtar is available)
        if cmd_exists("bsdtar") then
            assert(os.execute(run("kaze-thunar-action", "compress " .. q(f1) .. " " .. q(f2))))
            local arc = work .. "/work dir-archive.tar.zst"
            assert_true(fs.file_exists(arc), "compress creates .tar.zst archive")

            local dest_dir = tmp .. "/extract-check"
            fs.mkdir_p(dest_dir)
            local copied_arc = dest_dir .. "/bundle.tar.zst"
            assert(os.execute("cp -- " .. q(arc) .. " " .. q(copied_arc)))
            assert(os.execute(run("kaze-thunar-action", "extract " .. q(copied_arc))))
            -- Multi-root archive must be wrapped in subdirectory (tarbomb protection)
            assert_eq(fs.read_file(dest_dir .. "/bundle/hello world.txt"), "kaze thunar test\n")
            assert_eq(fs.read_file(dest_dir .. "/bundle/second.txt"), "second file\n")
        end
    end)
end)

dofile(repo_dir .. "/tests/test_stage3_keys.lua")(test, assert_eq, assert_true, assert_contains, repo_dir)
dofile(repo_dir .. "/tests/test_stage3_profile_doctor.lua")(test, assert_eq, assert_true, assert_contains, repo_dir)

-- Modular blind black-box & brute-force behavioral suites (one file per functional domain)
for _, bb_suite in ipairs({
    "test_installer.lua",
    "test_display_share.lua",
    "test_record.lua",
    "test_style_theming.lua",
    "test_mirror.lua",
    "test_session_foot_tui.lua",
    "test_projects_keys_thunar.lua",
    "test_apply_doctor_hypr.lua",
}) do
    dofile(repo_dir .. "/tests/blackbox/" .. bb_suite)(test, assert_eq, assert_true, assert_contains, repo_dir)
end

io.stdout:write(string.format("\nSummary: %d passed, %d failed\n", passed, failed))
if failed > 0 then
    os.exit(1)
end
