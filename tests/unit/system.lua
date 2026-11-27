#!/usr/bin/env lua

local function run_suite(test, assert_eq, assert_true, assert_contains, repo_dir)
    package.path = table.concat({
        repo_dir .. "/lua/?.lua",
        repo_dir .. "/lua/?/init.lua",
        package.path,
    }, ";")

    local fs = require("kaze.fs")
    local q = fs.shell_quote

    local function make_tmp_dir()
        local d = string.format("/tmp/kaze-stage3-c-%d-%d", os.time(), math.random(100000, 999999))
        fs.mkdir_p(d)
        return d
    end

    local function rm_rf(dir)
        os.execute("rm -rf -- " .. q(dir))
    end

    local function read_all(cmd)
        local p = io.popen(cmd)
        if not p then return "", false end
        local out = p:read("*a") or ""
        local ok = p:close()
        return out, (ok == true or ok == 0)
    end

    local function write_stub(dir, name, body)
        local path = dir .. "/" .. name
        fs.write_atomic(path, "#!/bin/sh\nset -eu\n" .. (body or "exit 0") .. "\n")
        assert_true(os.execute("chmod +x -- " .. q(path)), "chmod stub " .. name)
        return path
    end

    local function link_host_bin(dir, name)
        local actual = assert(fs.capture("command -v " .. q(name) .. " || echo /usr/bin/" .. name)):gsub("\n$", "")
        assert_true(os.execute("ln -sf -- " .. q(actual) .. " " .. q(dir .. "/" .. name)), "link " .. name)
    end

    test("install.sh: --dry-run includes noctalia, omits replaced legacy packages, and writes zero files", function()
        local tmp = make_tmp_dir()
        local ok_test, err_test = pcall(function()
            local home, cfg, data, state = tmp .. "/home", tmp .. "/cfg", tmp .. "/data", tmp .. "/state"
            local env = string.format("HOME=%s XDG_CONFIG_HOME=%s XDG_DATA_HOME=%s XDG_STATE_HOME=%s", q(home), q(cfg), q(data), q(state))
            local installer = q(repo_dir .. "/scripts/install.sh")

            local min_out, min_ok = read_all(env .. " " .. installer .. " --profile minimal --dry-run 2>&1")
            assert_true(min_ok, "minimal --dry-run exit 0")
            assert_contains(min_out, "  noctalia\n", "minimal includes noctalia")
            assert_contains(min_out, "  hyprland\n", "minimal includes hyprland")
            assert_contains(min_out, "  pipewire\n", "minimal includes pipewire")
            assert_contains(min_out, "  pipewire-pulse\n", "minimal includes pipewire-pulse")
            assert_contains(min_out, "  pipewire-alsa\n", "minimal includes pipewire-alsa")
            assert_contains(min_out, "  wireplumber\n", "minimal includes wireplumber")
            assert_contains(min_out, "  foot\n", "minimal includes foot")
            assert_contains(min_out, "  zsh\n", "minimal includes zsh")
            assert_contains(min_out, "  zsh-autosuggestions\n", "minimal includes zsh-autosuggestions")
            assert_contains(min_out, "  zsh-syntax-highlighting\n", "minimal includes zsh-syntax-highlighting")
            assert_contains(min_out, "sudo pacman -Syu --needed", "uses pacman -Syu")
            assert_contains(min_out, "Display manager: noctalia\n", "defaults display manager to noctalia")
            assert_contains(min_out, "AUR helper: yay-bin\n", "defaults AUR helper to yay-bin")
            assert_contains(min_out, "greetd noctalia-greeter base-devel git", "default dry-run includes noctalia-greeter + AUR prereqs")
            assert_contains(min_out, "0 AUR", "zero AUR at core")

            local function has_word(text, word)
                local pat = "%f[%w_-]" .. word:gsub("%-", "%%-") .. "%f[^%w_-]"
                return text:find(pat) ~= nil
            end
            for _, removed in ipairs({ "waybar", "swaybg", "fuzzel", "fnott", "hypridle", "hyprlock", "cliphist", "hyprsunset", "matugen", "mate-polkit", "grim", "swappy" }) do
                assert_true(not has_word(min_out, removed), "removed package leaked into minimal: " .. removed)
            end

            local full_out, full_ok = read_all(env .. " " .. installer .. " --profile full --dry-run --yes 2>&1")
            assert_true(full_ok, "full --dry-run exit 0")
            for _, pkg in ipairs({
                "noctalia", "slurp", "wf-recorder", "ffmpeg", "hyprpicker",
                "thunar", "adw-gtk-theme", "yazi", "zathura", "zathura-pdf-poppler", "fcitx5", "fcitx5-bamboo",
                "fzf", "zoxide", "eza", "bat", "ripgrep", "fd", "starship", "wl-mirror",
            }) do
                assert_contains(full_out, "  " .. pkg .. "\n", "full includes " .. pkg)
            end
            for _, removed in ipairs({ "waybar", "swaybg", "fuzzel", "fnott", "hypridle", "hyprlock", "cliphist", "hyprsunset", "matugen", "mate-polkit", "grim", "swappy", "gst-plugin-pipewire", "zathura-pdf-mupdf" }) do
                assert_true(not has_word(full_out, removed), "removed package leaked into full: " .. removed)
            end

            local dm_out, dm_ok = read_all(env .. " " .. installer .. " --dm ly --aur yay-bin --dry-run 2>&1")
            assert_true(dm_ok, "--dm ly --aur yay-bin --dry-run exit 0")
            assert_contains(dm_out, "Display manager: ly\n")
            assert_contains(dm_out, "AUR helper: yay-bin\n")
            assert_contains(dm_out, "ly base-devel git")

            local gr_out, gr_ok = read_all(env .. " " .. installer .. " --dm greetd --aur paru-bin --dry-run 2>&1")
            assert_true(gr_ok, "--dm greetd --aur paru-bin --dry-run exit 0")
            assert_contains(gr_out, "Display manager: greetd\n")
            assert_contains(gr_out, "AUR helper: paru-bin\n")
            assert_contains(gr_out, "greetd greetd-tuigreet base-devel git")

            for _, untouched in ipairs({ home, cfg, data, state }) do
                assert_true(os.execute("[ ! -e " .. q(untouched) .. " ] && [ ! -L " .. q(untouched) .. " ]"))
            end
            local _, bad_ok = read_all(env .. " " .. installer .. " --profile bogus --dry-run 2>&1")
            assert_true(not bad_ok)
            local _, bad_dm_ok = read_all(env .. " " .. installer .. " --dm bogus --dry-run 2>&1")
            assert_true(not bad_dm_ok)
            local _, bad_aur_ok = read_all(env .. " " .. installer .. " --aur bogus --dry-run 2>&1")
            assert_true(not bad_aur_ok)

            -- Invoking via POSIX `sh scripts/install.sh` re-execs cleanly under bash and resolves style alias
            local sh_out, sh_ok = read_all(env .. " sh " .. installer .. " --profile minimal --style floating-islands --dry-run 2>&1")
            assert_true(sh_ok, "sh scripts/install.sh --dry-run should succeed: " .. sh_out)
            assert_contains(sh_out, "Kaze profile: minimal")
            assert_contains(sh_out, "Kaze style: corner-hud")
            assert_contains(sh_out, "style=corner-hud")
            local _, bad_style_ok = read_all(env .. " " .. installer .. " --style bogus --dry-run 2>&1")
            assert_true(not bad_style_ok)
        end)
        rm_rf(tmp)
        if not ok_test then error(err_test, 0) end
    end)

    test("install.sh: --skip-packages --yes deploys symlinks, seeds Noctalia config, persists profile, and rolls back cleanly", function()
        local tmp = make_tmp_dir()
        local ok_test, err_test = pcall(function()
            local home, cfg, data, cache, runtime = tmp .. "/home space", tmp .. "/cfg space", tmp .. "/data space", tmp .. "/cache space", tmp .. "/runtime"
            fs.mkdir_p(home)
            fs.mkdir_p(cfg .. "/hypr")
            fs.mkdir_p(runtime)

            local user_lua = cfg .. "/hypr/user.lua"
            local user_zsh = cfg .. "/zsh/user.zsh"
            local zprof_local = cfg .. "/zsh/zprofile.local"
            local prof_file = cfg .. "/kaze/profile"
            fs.write_atomic(user_lua, "return { browser = 'firefox' } -- user marker\n")
            fs.write_atomic(user_zsh, "# user zsh marker\n")
            fs.write_atomic(zprof_local, "# user zprofile marker\n")
            fs.write_atomic(cfg .. "/noctalia/config.toml", "# pre-existing user noctalia\n")

            local env = string.format(
                "HOME=%s XDG_CONFIG_HOME=%s XDG_DATA_HOME=%s XDG_CACHE_HOME=%s XDG_STATE_HOME=%s XDG_RUNTIME_DIR=%s HYPRLAND_INSTANCE_SIGNATURE='' WAYLAND_DISPLAY=''",
                q(home), q(cfg), q(data), q(cache), q(tmp .. "/state"), q(runtime)
            )
            local installer = q(repo_dir .. "/scripts/install.sh")

            local out, ok = read_all(env .. " " .. installer .. " --profile full --skip-packages --yes 2>&1")
            assert_true(ok, "install.sh failed: " .. out)
            assert_eq(fs.read_file(user_lua), "return { browser = 'firefox' } -- user marker\n")
            assert_eq(fs.read_file(user_zsh), "# user zsh marker\n")
            assert_eq(fs.read_file(zprof_local), "# user zprofile marker\n")

            for _, link_path in ipairs({
                cfg .. "/systemd/user/kaze-noctalia.service",
                cfg .. "/systemd/user/kaze-fcitx5.service",
                cfg .. "/hypr/xdph.conf",
                cfg .. "/foot/foot.ini",
                cfg .. "/starship.toml",
                cfg .. "/yazi/yazi.toml",
                cfg .. "/yazi/theme.toml",
                cfg .. "/yazi/keymap.toml",
                cfg .. "/zathura/zathurarc",
                cfg .. "/imv/config",
                cfg .. "/mimeapps.list",
                cfg .. "/noctalia/palettes/Kaze-Swiss.json",
                cfg .. "/noctalia/palettes/Kaze-Phosphor.json",
                cfg .. "/noctalia/palettes/Kaze-Amber.json",
                cfg .. "/noctalia/palettes/Kaze-Retro90s.json",
                data .. "/applications/yazi.desktop",
                home .. "/.zshrc",
                home .. "/.zprofile",
                cfg .. "/zsh/conf.d",
                home .. "/.local/bin/kaze-doctor",
                home .. "/.local/bin/kaze-project",
                home .. "/.local/bin/kaze-style",
                data .. "/kaze-dots/lua/kaze",
            }) do
                assert_true(os.execute("[ -L " .. q(link_path) .. " ] && [ -e " .. q(link_path) .. " ]"), "expected symlink: " .. link_path)
            end
            assert_eq(fs.read_file(prof_file), "full\n")
            assert_eq(fs.read_file(cfg .. "/kaze/style"), "dynamic-island\n")
            assert_true(fs.file_exists(cfg .. "/hypr/kaze-style.lua"), "install creates hypr/kaze-style.lua")
            assert_true(fs.file_exists(cfg .. "/gtk-3.0/kaze-style.css"), "install creates gtk-3.0/kaze-style.css")
            assert_contains(assert(fs.read_file(cfg .. "/noctalia/config.toml")), "polkit_agent = true\n")
            assert_contains(assert(fs.read_file(cfg .. "/noctalia/config.toml")), 'id = "island"\n')

            local backup_dir = assert(fs.read_file(cfg .. "/kaze/last-backup")):gsub("\n$", "")
            local rb_out, rb_ok = read_all(env .. " " .. q(backup_dir .. "/rollback.sh") .. " --yes 2>&1")
            assert_true(rb_ok, "rollback failed: " .. rb_out)
            assert_eq(fs.read_file(user_lua), "return { browser = 'firefox' } -- user marker\n")
            assert_eq(fs.read_file(user_zsh), "# user zsh marker\n")
            assert_eq(fs.read_file(zprof_local), "# user zprofile marker\n")
            assert_eq(fs.read_file(cfg .. "/noctalia/config.toml"), "# pre-existing user noctalia\n")
            for _, gone in ipairs({
                cfg .. "/systemd/user/kaze-noctalia.service",
                cfg .. "/systemd/user/kaze-fcitx5.service",
                cfg .. "/hypr/xdph.conf",
                cfg .. "/foot/foot.ini",
                cfg .. "/starship.toml",
                cfg .. "/yazi/yazi.toml",
                cfg .. "/zathura/zathurarc",
                cfg .. "/imv/config",
                cfg .. "/mimeapps.list",
                cfg .. "/noctalia/palettes/Kaze-Swiss.json",
                cfg .. "/noctalia/palettes/Kaze-Phosphor.json",
                cfg .. "/noctalia/palettes/Kaze-Amber.json",
                cfg .. "/noctalia/palettes/Kaze-Retro90s.json",
                data .. "/applications/yazi.desktop",
                home .. "/.zshrc",
                home .. "/.zprofile",
                cfg .. "/zsh/conf.d",
                home .. "/.local/bin/kaze-doctor",
                home .. "/.local/bin/kaze-project",
                home .. "/.local/bin/kaze-style",
                prof_file,
                cfg .. "/kaze/style",
                cfg .. "/kaze/last-backup",
            }) do
                assert_true(os.execute("[ ! -e " .. q(gone) .. " ] && [ ! -L " .. q(gone) .. " ]"), "rollback must remove " .. gone)
            end

            -- Non-default --style installs active preset + rollback restores pre-existing style file
            fs.write_atomic(cfg .. "/kaze/style", "concave-notch\n")
            local st_out, st_ok = read_all(env .. " " .. installer .. " --profile full --style dynamic-island --skip-packages --yes 2>&1")
            assert_true(st_ok, "install.sh --style dynamic-island failed: " .. st_out)
            assert_eq(fs.read_file(cfg .. "/kaze/style"), "dynamic-island\n")
            local st_cfg = assert(fs.read_file(cfg .. "/noctalia/config.toml"))
            assert_contains(st_cfg, "polkit_agent = true\n")
            assert_contains(st_cfg, 'id = "island"\n')
            assert_contains(st_cfg, 'position = "top_right"\n')
            assert_contains(st_cfg, "offset_y = 12\n")

            local doc = q(repo_dir .. "/bin/kaze-doctor")
            local diff_dyn, diff_dyn_ok = read_all(env .. " " .. doc .. " --diff --template " .. q(repo_dir .. "/config/noctalia/config.toml") .. " 2>&1")
            assert_true(diff_dyn_ok, "kaze-doctor --diff failed on dynamic-island: " .. diff_dyn)
            assert_contains(diff_dyn, "Status: up to date")

            -- kaze-doctor --diff stays clean across all 11 presets
            local styles = require("kaze.styles")
            for _, preset in ipairs(styles.list()) do
                local st_res = read_all(env .. " KAZE_DOTS_DIR=" .. q(repo_dir) .. " " .. q(home .. "/.local/bin/kaze-style") .. " --no-reload " .. preset.id .. " 2>&1")
                assert_contains(st_res, "Applied style '" .. preset.id .. "'")
                local d_out, d_ok = read_all(env .. " " .. doc .. " --diff --template " .. q(repo_dir .. "/config/noctalia/config.toml") .. " 2>&1")
                assert_true(d_ok, "kaze-doctor --diff failed on " .. preset.id .. ": " .. d_out)
                assert_contains(d_out, "Status: up to date", "0 drift for preset " .. preset.id)
            end

            local rb2_dir = assert(fs.read_file(cfg .. "/kaze/last-backup")):gsub("\n$", "")
            assert(read_all(env .. " " .. q(rb2_dir .. "/rollback.sh") .. " --yes 2>&1"))
            assert_eq(fs.read_file(cfg .. "/kaze/style"), "concave-notch\n")
        end)
        rm_rf(tmp)
        if not ok_test then error(err_test, 0) end
    end)

    test("kaze-doctor: verifies Noctalia + Foot binaries, configs, symlinks, and singleton PIDs", function()
        local tmp = make_tmp_dir()
        local ok_test, err_test = pcall(function()
            local stub_bin, home, cfg, data, cache, runtime = tmp .. "/bin", tmp .. "/home", tmp .. "/cfg", tmp .. "/data", tmp .. "/cache", tmp .. "/runtime"
            for _, d in ipairs({ stub_bin, home, cfg .. "/kaze", data, cache, runtime }) do fs.mkdir_p(d) end

            link_host_bin(stub_bin, "lua")
            for _, b in ipairs({
                "hyprland", "hyprctl", "noctalia", "notify-send",
                "foot", "footclient", "wl-copy", "wl-paste",
                "wpctl", "brightnessctl", "playerctl",
                "busctl", "systemctl", "flock",
            }) do
                write_stub(stub_bin, b, "exit 0")
            end
            write_stub(stub_bin, "zsh", [[
if [ "${1:-}" = "-n" ] && [ -n "${2:-}" ]; then
    printf '%s\n' "$2" >> "$HOME/zsh-checked"
fi
exit 0
]])

            local base_env = string.format(
                "HOME=%s XDG_CONFIG_HOME=%s XDG_DATA_HOME=%s XDG_CACHE_HOME=%s XDG_RUNTIME_DIR=%s LANG=en_US.UTF-8 LC_ALL='' PATH=%s",
                q(home), q(cfg), q(data), q(cache), q(runtime), q(stub_bin)
            )
            local doctor = q(repo_dir .. "/bin/kaze-doctor")

            local min_out, min_ok = read_all(base_env .. " " .. doctor .. " --offline --profile minimal 2>&1")
            assert_true(min_ok, "minimal offline doctor pass:\n" .. min_out)
            assert_contains(min_out, "[OK]   binaries (minimal):")

            local sys_env = string.format(
                "HOME=%s XDG_CONFIG_HOME=%s XDG_DATA_HOME=%s XDG_CACHE_HOME=%s XDG_STATE_HOME=%s XDG_RUNTIME_DIR=%s HYPRLAND_INSTANCE_SIGNATURE='' WAYLAND_DISPLAY=''",
                q(home), q(cfg), q(data), q(cache), q(tmp .. "/state"), q(runtime)
            )
            assert_true(os.execute(sys_env .. " " .. q(repo_dir .. "/scripts/install.sh") .. " --profile minimal --skip-packages --yes >/dev/null 2>&1"))

            link_host_bin(stub_bin, "id")
            write_stub(stub_bin, "hyprctl", [[if [ "$1" = configerrors ]; then exit 0; fi; exit 2]])
            write_stub(stub_bin, "systemctl", [[
case "$*" in
  '--user show-environment')
    printf 'WAYLAND_DISPLAY=wayland-1\nHYPRLAND_INSTANCE_SIGNATURE=sig-live\nXDG_CURRENT_DESKTOP=Hyprland\n' ;;
  '--user is-active --quiet pipewire.service'|'--user is-active --quiet wireplumber.service') exit 0 ;;
  '--user is-active --quiet pipewire-pulse.socket')
    [ "${TEST_PULSE_MODE:-socket}" = "socket" ] && exit 0 || exit 1 ;;
  '--user is-active --quiet pipewire-pulse.service')
    [ "${TEST_PULSE_MODE:-socket}" = "service" ] && exit 0 || exit 1 ;;
  *) exit 2 ;;
esac
]])
            write_stub(stub_bin, "busctl", [[
if [ "$*" = '--user --activatable' ]; then
    printf 'org.freedesktop.portal.Desktop\norg.freedesktop.impl.portal.desktop.hyprland\norg.freedesktop.impl.portal.desktop.gtk\n'
    exit 0
fi
exit 2
]])
            write_stub(stub_bin, "ps", [[
printf '  101 noctalia /usr/bin/noctalia\n  102 foot /usr/bin/foot --server=3\n'
if [ "${DUP_NOC:-0}" = 1 ]; then printf '  199 noctalia /usr/bin/noctalia\n'; fi
]])

            local live_env = base_env .. " HYPRLAND_INSTANCE_SIGNATURE=sig-live WAYLAND_DISPLAY=wayland-1"
            local live_out, live_ok = read_all(live_env .. " " .. doctor .. " 2>&1")
            assert_true(live_ok, "live minimal doctor should pass:\n" .. live_out)
            assert_contains(live_out, "[OK]   noctalia: config.toml validated cleanly")
            assert_contains(live_out, "[OK]   foot: foot.ini validated cleanly")
            assert_contains(live_out, "[OK]   zsh: ~/.zshrc, ~/.zprofile, and conf.d/*.zsh validated cleanly")
            assert_contains(live_out, "[OK]   daemons (minimal):")
            local checked_zsh = assert(fs.read_file(home .. "/zsh-checked"))
            assert_contains(checked_zsh, home .. "/.zshrc\n")
            assert_contains(checked_zsh, home .. "/.zprofile\n")
            assert_contains(checked_zsh, cfg .. "/zsh/conf.d/10-options.zsh\n")
            assert_contains(checked_zsh, cfg .. "/zsh/conf.d/60-prompt.zsh\n")

            local full_miss_out, full_miss_ok = read_all(base_env .. " " .. doctor .. " --offline --profile full 2>&1")
            assert_true(not full_miss_ok, "full offline doctor must fail when full binaries are missing")
            assert_contains(full_miss_out, "fzf, zoxide, eza, bat, rg, fd, starship, wl-mirror")

            for _, b in ipairs({
                "slurp", "wf-recorder", "ffmpeg", "ffprobe", "hyprpicker",
                "thunar", "yazi", "imv", "zathura", "gnome-keyring-daemon", "fcitx5",
                "fzf", "zoxide", "eza", "bat", "rg", "fd", "starship", "wl-mirror",
            }) do
                write_stub(stub_bin, b, "exit 0")
            end
            local full_ok_out, full_ok = read_all(base_env .. " " .. doctor .. " --offline --profile full 2>&1")
            assert_true(full_ok, "full offline doctor pass with all binaries:\n" .. full_ok_out)
            assert_contains(full_ok_out, "[OK]   binaries (full): all full-profile tools found")

            local dup_out, dup_ok = read_all(live_env .. " DUP_NOC=1 " .. doctor .. " 2>&1")
            assert_true(not dup_ok, "duplicate noctalia PID must fail doctor")
            assert_contains(dup_out, "noctalia (expected 1, got 2)")

            -- pipewire-pulse.service active (even if socket inactive) passes; both inactive fails
            local psvc_out, psvc_ok = read_all(live_env .. " TEST_PULSE_MODE=service " .. doctor .. " 2>&1")
            assert_true(psvc_ok, "pipewire-pulse.service active should pass doctor:\n" .. psvc_out)
            local pnone_out, pnone_ok = read_all(live_env .. " TEST_PULSE_MODE=none " .. doctor .. " 2>&1")
            assert_true(not pnone_ok, "inactive pipewire-pulse socket and service must fail doctor")
            assert_contains(pnone_out, "pipewire-pulse.socket")
        end)
        rm_rf(tmp)
        if not ok_test then error(err_test, 0) end
    end)

    test("kaze-display: monitor/workspace parsers, hl.monitor planner, safety rules, and CLI workflows", function()
        local display = require("kaze.display")
        local json = require("kaze.json")

        local mons = display.parse_monitors([[
[
  {"id":0,"name":"eDP-1","description":"Built-in Panel","width":1920,"height":1080,"x":0,"y":0,"refreshRate":60.0,"scale":1.0,"disabled":false,"focused":true,"mirrorOf":"none","activeWorkspace":{"id":1,"name":"1"},"hardwareDetails":{"backend":"drm"}},
  {"id":1,"name":"HDMI-A-1","description":"External 4K","width":2560,"height":1440,"x":1920,"y":0,"refreshRate":144.0,"scale":1.0,"disabled":false,"focused":false,"mirrorOf":"none","activeWorkspace":{"id":3,"name":"3"},"hardwareDetails":{"backend":"drm"}},
  {"id":2,"name":"kaze-share","description":"Headless","width":1920,"height":1080,"x":9999,"y":0,"refreshRate":60.0,"scale":1.0,"disabled":false,"focused":false,"mirrorOf":"none","activeWorkspace":{"id":9,"name":"9"},"hardwareDetails":{"backend":"headless"}},
  {"id":3,"name":"HEADLESS-2","description":"Other Headless","width":1280,"height":720,"x":12000,"y":0,"refreshRate":60.0,"scale":1.0,"disabled":false,"focused":false,"mirrorOf":"none","hardwareDetails":{"backend":"headless"}}
]
]])
        assert_eq(#mons, 4)
        local internal, externals, virtuals = display.pick_roles(mons)
        assert_eq(internal.name, "eDP-1")
        assert_eq(#externals, 1)
        assert_eq(externals[1].name, "HDMI-A-1")
        assert_eq(#virtuals, 2)
        assert_true(display.is_virtual_monitor("kaze-share"))
        assert_true(display.is_virtual_monitor("HEADLESS-1"))
        assert_true(not display.is_virtual_monitor("HDMI-A-1"))

        -- Workspace parser, clean workspace selector, and formatter
        local wss = display.parse_workspaces(
            '[{"id":-99,"name":"special:scratch","monitor":"eDP-1","windows":1},{"id":1,"name":"1","monitor":"eDP-1","windows":2},{"id":2,"name":"2","monitor":"HDMI-A-1","windows":1}]',
            '[{"address":"0x1","class":"firefox","workspace":{"id":1}},{"address":"0x2","class":"foot","workspace":{"id":1}},{"address":"0x3","class":"firefox","workspace":{"id":1}},{"address":"0x4","class":"mpv","workspace":{"id":2}}]'
        )
        assert_eq(#wss, 2)
        assert_eq(wss[1].id, 1)
        assert_eq(#wss[1].apps, 2)
        assert_eq(display.format_workspace_entry(wss[1]), "WS 1  [firefox, foot]  (on eDP-1)")
        assert_eq(display.format_workspace_entry(wss[1], 1), "★ WS 1  [firefox, foot]  (current, on eDP-1)")
        assert_eq(display.format_workspace_entry({ id = 2, monitor = "Virtual-2", windows = 0, apps = {} }, 1), "WS 2  [empty]  (on Virtual-2)")
        assert_eq(display.format_workspace_entry({ id = 9, windows = 0, apps = {} }), "WS 9  [new empty workspace]")
        assert_eq(display.format_workspace_brief(1, wss), "WS 1: firefox, foot")
        assert_eq(display.format_workspace_brief(9, wss), "WS 9")
        local wss_order = display.order_workspaces_for_picker({
            { id = 3, monitor = "eDP-1", windows = 2, apps = { "chromium", "nvim", "foot" } },
            { id = 1, monitor = "eDP-1", windows = 1, apps = { "foot" } },
            { id = 5, monitor = "HDMI-A-1", windows = 1, apps = { "mpv" } },
            { id = 2, monitor = "eDP-1", windows = 0, apps = {} },
            { id = 4, monitor = "HDMI-A-1", windows = 0, apps = {} },
        }, 3)
        assert_eq(#wss_order, 5)
        assert_eq(wss_order[1].id, 1)
        assert_eq(wss_order[2].id, 2)
        assert_eq(wss_order[3].id, 3)
        assert_eq(wss_order[4].id, 4)
        assert_eq(wss_order[5].id, 5)
        assert_eq(display.format_workspace_brief(3, wss_order), "WS 3: chromium, nvim")
        local clean_ws = display.pick_clean_workspace_id(wss)
        assert_true(clean_ws ~= 1 and clean_ws ~= 2, "clean ws must avoid active workspaces")

        -- Planner generates valid Lua hl.monitor(...) calls for every mode
        local function assert_valid_lua_plan(p)
            assert_true(type(p.eval_cmds) == "table" and #p.eval_cmds >= 1)
            for _, expr in ipairs(p.eval_cmds) do
                assert_true(load(expr) ~= nil, "invalid Lua expr: " .. expr)
            end
        end

        local p_ext = assert(display.plan("extend-right", mons))
        assert_valid_lua_plan(p_ext)
        assert_eq(p_ext.needs_reload, false)
        assert_contains(p_ext.eval_cmds[1], 'output = "eDP-1"')
        assert_contains(p_ext.eval_cmds[1], 'position = "0x0"')
        assert_contains(p_ext.eval_cmds[1], 'disabled = false, mirror = ""')
        assert_contains(p_ext.eval_cmds[2], 'output = "HDMI-A-1"')
        assert_contains(p_ext.eval_cmds[2], 'position = "auto-right"')
        assert_contains(p_ext.eval_cmds[2], 'disabled = false, mirror = ""')

        for _, mode_name in ipairs({ "extend-left", "extend-up", "external", "internal", "auto", "present", "mirror-scaled" }) do
            local p = assert(display.plan(mode_name, mons))
            assert_valid_lua_plan(p)
        end

        local p_int = assert(display.plan("internal", mons))
        assert_contains(p_int.eval_cmds[2], "disabled = true")
        local p_mir = assert(display.plan("mirror", mons))
        assert_valid_lua_plan(p_mir)
        assert_contains(p_mir.eval_cmds[2], 'mirror = "eDP-1"')
        assert_true(not p_mir.eval_cmds[2]:find("kaze-share", 1, true), "mirror must never target kaze-share")

        local p_vs = assert(display.plan("virtual-share", { mons[1] }))
        assert_valid_lua_plan(p_vs)
        assert_contains(p_vs.eval_cmds[1], 'output = "eDP-1"')
        assert_contains(p_vs.eval_cmds[1], 'position = "0x0"')
        assert_contains(p_vs.eval_cmds[2], 'output = "kaze-share"')
        assert_contains(p_vs.eval_cmds[2], 'mode = "1920x1080@60"')
        assert_contains(p_vs.eval_cmds[2], 'position = "9999x0"')

        -- Reload required when exiting mirror mode + re-pins kaze-share when active
        local mirrored_mons = display.parse_monitors([[
[
  {"name":"eDP-1","width":1920,"height":1080,"scale":1.0,"disabled":false,"mirrorOf":"none"},
  {"name":"HDMI-A-1","width":1920,"height":1080,"scale":1.0,"disabled":false,"mirrorOf":"eDP-1"},
  {"name":"kaze-share","width":1920,"height":1080,"x":9999,"y":0,"refreshRate":60.0,"scale":1.0,"disabled":false,"hardwareDetails":{"backend":"headless"}}
]
]])
        local p_unmirror = assert(display.plan("extend-right", mirrored_mons))
        assert_eq(p_unmirror.needs_reload, true, "exiting active mirror requires hyprctl reload")
        assert_contains(table.concat(p_unmirror.eval_cmds, "\n"), 'output = "kaze-share", mode = "1920x1080@60", position = "9999x0", scale = 1', "reload plan must re-pin kaze-share at 9999x0")

        -- Starting virtual-share while mirror is active must NOT reload or break HDMI mirror
        local p_vs_during_mirror = assert(display.plan("virtual-share", { mirrored_mons[1], mirrored_mons[2] }))
        assert_eq(p_vs_during_mirror.needs_reload, false, "virtual-share must not reload active HDMI mirror")

        -- Clamshell virtual-share pins enabled external monitor instead of disabled eDP-1
        local clamshell_mons = display.parse_monitors([[
[
  {"name":"eDP-1","width":1920,"height":1080,"scale":1.0,"disabled":true},
  {"name":"DP-1","width":2560,"height":1440,"refreshRate":60.0,"scale":1.0,"disabled":false}
]
]])
        local p_clamshell = assert(display.plan("virtual-share", clamshell_mons))
        assert_contains(p_clamshell.eval_cmds[1], 'output = "DP-1"', "clamshell virtual-share must pin enabled external monitor")

        -- Extend Left / Above virtual-share preserves both physical monitor coordinates (never overlaps at 0x0)
        local extend_left_mons = display.parse_monitors([[
[
  {"name":"eDP-1","width":1920,"height":1080,"x":2560,"y":0,"refreshRate":60.0,"scale":1.0,"disabled":false},
  {"name":"HDMI-A-1","width":2560,"height":1440,"x":0,"y":0,"refreshRate":144.0,"scale":1.0,"disabled":false}
]
]])
        local p_ext_left_vs = assert(display.plan("virtual-share", extend_left_mons))
        assert_contains(p_ext_left_vs.eval_cmds[1], 'output = "eDP-1"')
        assert_contains(p_ext_left_vs.eval_cmds[1], 'position = "2560x0"')
        assert_contains(p_ext_left_vs.eval_cmds[2], 'output = "HDMI-A-1"')
        assert_contains(p_ext_left_vs.eval_cmds[2], 'position = "0x0"')
        assert_contains(p_ext_left_vs.eval_cmds[3], 'output = "kaze-share", mode = "1920x1080@60", position = "9999x0", scale = 1')

        -- 5 safety rules (including internal panel ignore on lid re-open)
        assert_true(display.should_ignore_hotplug("kaze-share", { now = 100, started_at = 0 }))
        assert_true(display.should_ignore_hotplug("HEADLESS-1", { now = 100, started_at = 0 }))
        assert_true(display.should_ignore_hotplug("eDP-1", { now = 100, started_at = 0 }))
        assert_true(display.should_ignore_hotplug("HDMI-A-1", { now = 100, started_at = 0, enabled = false }))
        assert_true(display.should_ignore_hotplug("HDMI-A-1", { now = 100, started_at = 0, locked = true }))
        assert_true(display.should_ignore_hotplug("HDMI-A-1", { now = 103, started_at = 100 }))
        assert_true(display.should_ignore_hotplug("HDMI-A-1", { now = 110, started_at = 100, last_event_at = 109.5 }))
        assert_true(display.should_ignore_hotplug("HDMI-A-1", { now = 111, started_at = 100, last_event_at = 110 }))
        assert_true(not display.should_ignore_hotplug("HDMI-A-1", { now = 110, started_at = 100, last_event_at = 108 }))

        -- Multi-external disconnect: unplugging idle HDMI-A-1 must NOT tear down active presentation on DP-1
        local multi_ext_mons = display.parse_monitors([[
[
  {"name":"eDP-1","width":1920,"height":1080,"scale":1.0,"disabled":false},
  {"name":"DP-1","width":2560,"height":1440,"scale":1.0,"disabled":false},
  {"name":"HDMI-A-1","width":1920,"height":1080,"scale":1.0,"disabled":false}
]
]])
        local rec_unrelated = display.plan_disconnect_recovery("HDMI-A-1", multi_ext_mons, {
            mode = "present",
            external_monitor = "DP-1",
            present_workspace = 3,
            dnd_managed = true,
            dnd_was_active = false,
            bar_hidden_monitors = { "DP-1" },
        })
        assert_eq(rec_unrelated.clear_present, false, "unplugging unrelated HDMI-A-1 must not clear DP-1 presentation")
        assert_eq(rec_unrelated.restore_bar, false)
        assert_eq(rec_unrelated.restore_dnd, false)
        assert_eq(rec_unrelated.ext_affected, false)

        assert_true(display.should_restore_dnd({ dnd_managed = true, dnd_was_active = false }))
        assert_true(not display.should_restore_dnd({ dnd_managed = true, dnd_was_active = true }))
        assert_true(not display.should_restore_dnd({ dnd_managed = false, dnd_was_active = false }))

        local rec_ignored = display.plan_disconnect_recovery("kaze-share", mons, { external_monitor = "HDMI-A-1" })
        assert_eq(rec_ignored.ignored, true)

        local ext_only_mons = display.parse_monitors([[
[
  {"name":"eDP-1","width":1920,"height":1080,"scale":1.0,"disabled":true},
  {"name":"HDMI-A-1","width":2560,"height":1440,"scale":1.0,"disabled":false}
]
]])
        local rec_black = display.plan_disconnect_recovery("HDMI-A-1", ext_only_mons, {
            mode = "external",
            external_monitor = "HDMI-A-1",
        })
        assert_eq(rec_black.recover_internal, true)
        assert_contains(rec_black.eval_cmds[1], 'output = "eDP-1"')
        assert_contains(rec_black.eval_cmds[1], 'position = "0x0"')
        assert_contains(rec_black.eval_cmds[1], 'disabled = false, mirror = ""', "recover_internal must clear disabled = true on Hyprland 0.57+")

        -- Numeric mirrorOf string ("0") reported by Hyprland 0.57+ is recognized in disconnect recovery
        local num_mirror_mons = display.parse_monitors([[
[
  {"id":0,"name":"eDP-1","width":1920,"height":1080,"scale":1.0,"disabled":false,"mirrorOf":"none"},
  {"id":1,"name":"HDMI-A-1","width":1920,"height":1080,"scale":1.0,"disabled":false,"mirrorOf":"0"}
]
]])
        local p_num_unmirror = assert(display.plan("extend-right", num_mirror_mons))
        assert_eq(p_num_unmirror.needs_reload, true, "numeric mirrorOf string must trigger un-mirror reload")

        local rec_ctrl = display.plan_disconnect_recovery("HDMI-A-1", mons, {
            mode = "present",
            external_monitor = "HDMI-A-1",
            present_workspace = 3,
            control_on_laptop = true,
            dnd_managed = true,
            dnd_was_active = false,
            bar_hidden_monitors = { "HDMI-A-1" },
        })
        assert_eq(rec_ctrl.needs_reload, true)
        assert_eq(rec_ctrl.clear_present, true)
        assert_eq(rec_ctrl.restore_bar, true)
        assert_eq(rec_ctrl.restore_dnd, true)

        -- plan_external_revert restores exact prior layout, clears mirror_of, and preserves kaze-share
        local rev_left = assert(display.plan_external_revert(mons, { mode = "extend-left" }, { target = "HDMI-A-1" }))
        assert_eq(rev_left.mode, "extend-left")
        assert_eq(rev_left.needs_reload, false)
        assert_eq(rev_left.internal_name, "eDP-1")
        assert_contains(table.concat(rev_left.eval_cmds, "\n"), 'output = "eDP-1"')
        assert_contains(table.concat(rev_left.eval_cmds, "\n"), 'position = "auto-left"')
        assert_contains(table.concat(rev_left.eval_cmds, "\n"), 'output = "kaze-share"')

        local rev_mir = assert(display.plan_external_revert(mirrored_mons, { mode = "mirror" }, { target = "HDMI-A-1" }))
        assert_eq(rev_mir.mode, "extend-right")
        assert_eq(rev_mir.needs_reload, false, "external revert must not trigger unnecessary mirror reload")
        assert_contains(table.concat(rev_mir.eval_cmds, "\n"), 'output = "eDP-1"')
        assert_contains(table.concat(rev_mir.eval_cmds, "\n"), 'output = "kaze-share"')

        local ext_disabled_mons = display.parse_monitors([[
[
  {"name":"eDP-1","width":1920,"height":1080,"scale":1.0,"disabled":false},
  {"name":"HDMI-A-1","width":2560,"height":1440,"scale":1.0,"disabled":true}
]
]])
        local rev_int = assert(display.plan_external_revert(ext_disabled_mons, { mode = "internal" }, { target = "HDMI-A-1" }))
        assert_eq(rev_int.mode, "internal")
        assert_contains(table.concat(rev_int.eval_cmds, "\n"), 'output = "HDMI-A-1", disabled = true')

        -- CLI integration tests with stubs
        local tmp = make_tmp_dir()
        local ok_cli, err_cli = pcall(function()
            local stub_bin = tmp .. "/bin"
            local home, cfg, data, cache, runtime = tmp .. "/home", tmp .. "/cfg", tmp .. "/data", tmp .. "/cache", tmp .. "/runtime"
            for _, d in ipairs({ stub_bin, home, cfg, data, cache, runtime }) do fs.mkdir_p(d) end
            for _, b in ipairs({ "lua", "readlink", "nohup", "rm", "mkdir", "kill", "cat", "id", "install", "sleep", "grep", "flock", "timeout", "env" }) do
                link_host_bin(stub_bin, b)
            end
            write_stub(stub_bin, "wl-mirror", [[
printf '%s\n' "$*" >> "$HOME/wlmirror-calls"
trap 'kill "${child:-0}" 2>/dev/null || true; exit 0' TERM
sleep 30 &
child=$!
wait "$child"
]])
            write_stub(stub_bin, "notify-send", "exit 0")
            write_stub(stub_bin, "loginctl", [[
if [ "${2:-}" = "s1" ] && [ "${3:-}" = "-p" ] && [ "${4:-}" = "LockedHint" ]; then
    printf '%s\n' "${TEST_LOCKED:-no}"
fi
]])
            write_stub(stub_bin, "noctalia", [[
if [ "$1" = "msg" ] && [ "$2" = "notification-dnd-status" ]; then
    printf '%s\n' "${TEST_DND:-off}"
    exit 0
elif [ "$1" = "msg" ] && [ "$2" = "config-get" ] && [ "${3:-}" = "widget.present.type" ]; then
    if [ "${TEST_PRESENT_WIDGET:-0}" = "1" ]; then
        printf "'custom_button'\n"
    fi
    exit 0
fi
printf '%s\n' "$*" >> "$HOME/noc-calls"
if [ "$1" = "dmenu" ]; then
    cat > "$HOME/dmenu-items"
    printf '=== DMENU ===\n' >> "$HOME/dmenu-all"
    cat "$HOME/dmenu-items" >> "$HOME/dmenu-all"
    if [ -n "${TEST_DMENU_SLEEP:-}" ]; then
        sleep "$TEST_DMENU_SLEEP" &
        sp=$!
        trap 'kill "$sp" 2>/dev/null || true; exit 143' TERM INT
        wait "$sp"
    fi
    if [ -f "$HOME/dmenu-seq-2" ] && [ -n "${TEST_DMENU_SELECT_3:-}" ]; then
        grep -F -m1 "$TEST_DMENU_SELECT_3" "$HOME/dmenu-items" || true
    elif [ -f "$HOME/dmenu-seq" ] && [ -n "${TEST_DMENU_SELECT_2:-}" ]; then
        : > "$HOME/dmenu-seq-2"
        grep -F -m1 "$TEST_DMENU_SELECT_2" "$HOME/dmenu-items" || true
    elif [ -n "${TEST_DMENU_SELECT:-}" ]; then
        : > "$HOME/dmenu-seq"
        grep -F -m1 "$TEST_DMENU_SELECT" "$HOME/dmenu-items" || true
    fi
fi
]])
            write_stub(stub_bin, "hyprctl", [[
if [ "$1" = "-j" ] && [ "$2" = "monitors" ]; then
    cat "$HOME/mock-monitors.json"
elif [ "$1" = "-j" ] && [ "$2" = "workspaces" ]; then
    cat "$HOME/mock-workspaces.json"
elif [ "$1" = "-j" ] && [ "$2" = "clients" ]; then
    cat "$HOME/mock-clients.json"
elif [ "$1" = "-j" ] && [ "$2" = "activewindow" ]; then
    cat "$HOME/mock-activewindow.json"
elif [ "$1" = "-j" ] && [ "$2" = "locked" ]; then
    if [ "${TEST_HYPR_LOCKED:-0}" = "1" ]; then
        printf '{"locked": true}\n'
    else
        printf '{"locked": false}\n'
    fi
elif [ "$1" = "-j" ] && [ "$2" = "layers" ]; then
    if [ -n "${TEST_LAYERS:-}" ]; then
        printf '%s\n' "$TEST_LAYERS"
    else
        printf '{}\n'
    fi
else
    printf '%s\n' "$*" >> "$HOME/hypr-calls"
fi
]])
            fs.write_atomic(home .. "/mock-monitors.json", [[
[
  {"id":0,"name":"eDP-1","width":1920,"height":1080,"x":0,"y":0,"refreshRate":60.0,"scale":1.0,"disabled":false,"focused":true,"mirrorOf":"none","activeWorkspace":{"id":1,"name":"1"}},
  {"id":1,"name":"HDMI-A-1","width":2560,"height":1440,"x":1920,"y":0,"refreshRate":144.0,"scale":1.0,"disabled":false,"focused":false,"mirrorOf":"none","activeWorkspace":{"id":2,"name":"2"}}
]
]])
            fs.write_atomic(home .. "/mock-workspaces.json", '[{"id":1,"name":"1","monitor":"eDP-1","windows":1},{"id":3,"name":"3","monitor":"eDP-1","windows":1}]')
            fs.write_atomic(home .. "/mock-clients.json", '[{"address":"0xabc","class":"firefox","workspace":{"id":3}}]')
            fs.write_atomic(home .. "/mock-activewindow.json", '{"address":"0xdef","monitor":0,"workspace":{"id":1}}')

            local cli_env = string.format(
                "HOME=%s XDG_CONFIG_HOME=%s XDG_DATA_HOME=%s XDG_CACHE_HOME=%s XDG_RUNTIME_DIR=%s XDG_SESSION_ID=s1 PATH=%s",
                q(home), q(cfg), q(data), q(cache), q(runtime), q(stub_bin)
            )
            local kdisplay = q(repo_dir .. "/bin/kaze-display")

            -- 1. --hotplug ignored silently when locked (loginctl or Noctalia lock layer), opens dmenu when unlocked
            local _, lock_ok = read_all(cli_env .. " TEST_LOCKED=yes " .. kdisplay .. " --hotplug HDMI-A-1 2>&1")
            assert_true(lock_ok, "--hotplug should exit 0 silently when locked")
            assert_true(not fs.file_exists(home .. "/noc-calls"), "locked hotplug must not invoke noctalia dmenu")

            local _, layer_lock_ok = read_all(cli_env .. ' TEST_LAYERS=\'{"eDP-1":{"levels":{"3":[{"namespace":"noctalia-lockscreen"}]}}}\' ' .. kdisplay .. " --hotplug HDMI-A-1 2>&1")
            assert_true(layer_lock_ok, "--hotplug should exit 0 silently on Noctalia lock layer")
            assert_true(not fs.file_exists(home .. "/noc-calls"), "lock-layer hotplug must not invoke noctalia dmenu")

            local _, hypr_lock_ok = read_all(cli_env .. " TEST_HYPR_LOCKED=1 " .. kdisplay .. " --hotplug HDMI-A-1 2>&1")
            assert_true(hypr_lock_ok, "--hotplug should exit 0 silently when hyprctl -j locked is true")
            assert_true(not fs.file_exists(home .. "/noc-calls"), "ext-session-lock-v1 hotplug must not invoke noctalia dmenu")

            local _, unlock_ok = read_all(cli_env .. " " .. kdisplay .. " --hotplug HDMI-A-1 2>&1")
            assert_true(unlock_ok, "unlocked --hotplug with empty dmenu choice exits 0")
            assert_contains(assert(fs.read_file(home .. "/noc-calls")), "dmenu -p Display >")
            fs.write_atomic(home .. "/noc-calls", "")

            -- 2. present + stop-present conditional DND restore
            local p_out, p_ok = read_all(cli_env .. " TEST_DND=off " .. kdisplay .. " present 3 2>&1")
            assert_true(p_ok, "present 3 failed: " .. p_out)
            local noc_log = assert(fs.read_file(home .. "/noc-calls"))
            assert_contains(noc_log, "msg bar-hide default HDMI-A-1\n")
            assert_contains(noc_log, "msg notification-dnd-set on\n")
            local hypr_log = assert(fs.read_file(home .. "/hypr-calls"))
            assert_contains(hypr_log, 'workspace.move({ workspace = "3", monitor = "HDMI-A-1" })')
            local st = json.decode(assert(fs.read_file(runtime .. "/kaze/display-state.json")))
            assert_eq(st.mode, "present")
            assert_eq(st.dnd_managed, true)
            assert_eq(st.dnd_was_active, false)

            fs.write_atomic(home .. "/noc-calls", "")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " stop-present >/dev/null 2>&1"))
            local stop_noc = assert(fs.read_file(home .. "/noc-calls"))
            assert_contains(stop_noc, "msg bar-show default HDMI-A-1\n")
            assert_contains(stop_noc, "msg notification-dnd-set off\n")

            -- 3. present when user already had DND on must NOT disable DND on stop-present
            fs.write_atomic(home .. "/noc-calls", "")
            assert_true(os.execute(cli_env .. " TEST_DND=on " .. kdisplay .. " present 3 >/dev/null 2>&1"))
            fs.write_atomic(home .. "/noc-calls", "")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " stop-present >/dev/null 2>&1"))
            local keep_noc = assert(fs.read_file(home .. "/noc-calls"))
            assert_true(not keep_noc:find("notification-dnd-set off", 1, true), "must preserve pre-existing user DND")

            -- 4. virtual-share + toggle-preview + toggle-window-share + stop-virtual ordering
            fs.write_atomic(home .. "/hypr-calls", "")
            fs.write_atomic(home .. "/noc-calls", "")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " virtual-share 9 >/dev/null 2>&1"))
            local vs_log = assert(fs.read_file(home .. "/hypr-calls"))
            assert_contains(vs_log, "output create headless kaze-share\n")
            local p_pin = assert(vs_log:find('output = "eDP-1"', 1, true))
            local p_ks = assert(vs_log:find('output = "kaze-share"', 1, true))
            assert_true(p_pin < p_ks, "primary must be pinned at 0x0 before configuring kaze-share")
            assert_contains(assert(fs.read_file(home .. "/noc-calls")), "msg bar-hide default kaze-share\n")
            local vs_st = json.decode(assert(fs.read_file(runtime .. "/kaze/display-state.json")))
            assert_eq(vs_st.bar_hidden_monitors, nil, "virtual-share must not record kaze-share in bar_hidden_monitors")

            fs.write_atomic(home .. "/mock-monitors.json", [[
[
  {"id":0,"name":"eDP-1","width":1920,"height":1080,"x":0,"y":0,"refreshRate":60.0,"scale":1.0,"disabled":false,"focused":true,"activeWorkspace":{"id":1,"name":"1"}},
  {"id":2,"name":"kaze-share","width":1920,"height":1080,"x":9999,"y":0,"refreshRate":60.0,"scale":1.0,"disabled":false,"focused":false,"activeWorkspace":{"id":9,"name":"9"},"hardwareDetails":{"backend":"headless"}}
]
]])
            fs.write_atomic(home .. "/mock-workspaces.json", '[{"id":1,"name":"1","monitor":"eDP-1","windows":1},{"id":9,"name":"9","monitor":"kaze-share","windows":1}]')
            fs.write_atomic(home .. "/mock-clients.json", '[{"address":"0xshare1","class":"foot","monitor":2,"workspace":{"id":9}}]')

            assert_true(os.execute(cli_env .. " " .. kdisplay .. " toggle-preview >/dev/null 2>&1"))
            os.execute("sleep 0.05")
            local prev_st = json.decode(assert(fs.read_file(runtime .. "/kaze/display-state.json")))
            assert_true(type(prev_st.preview_pid) == "number" and prev_st.preview_pid > 0, "toggle-preview starts wl-mirror")
            assert_contains(assert(fs.read_file(home .. "/wlmirror-calls")), "--title kaze-share-preview kaze-share\n")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " toggle-preview >/dev/null 2>&1"))
            local closed_st = json.decode(assert(fs.read_file(runtime .. "/kaze/display-state.json")))
            assert_eq(closed_st.preview_pid, nil, "second toggle-preview closes preview")

            fs.write_atomic(home .. "/hypr-calls", "")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " toggle-window-share >/dev/null 2>&1"))
            assert_contains(assert(fs.read_file(home .. "/hypr-calls")), 'window.move({ workspace = "9", silent = true })')

            fs.write_atomic(home .. "/hypr-calls", "")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " stop-virtual >/dev/null 2>&1"))
            local sv_log = assert(fs.read_file(home .. "/hypr-calls"))
            local p_win_back = assert(sv_log:find("hl.get_windows()", 1, true))
            local p_silent_move = assert(sv_log:find("silent = true", 1, true))
            local p_ws_back = assert(sv_log:find('workspace.move({ workspace = "9", monitor = "eDP-1" })', 1, true))
            local p_remove = assert(sv_log:find("output remove kaze-share", 1, true))
            assert_true(p_win_back < p_remove and p_silent_move < p_remove and p_ws_back < p_remove, "windows and workspaces must move back before output remove")

            -- 5. --on-disconnect recovers disabled eDP-1 and cleans up presentation + DND
            fs.write_atomic(home .. "/mock-monitors.json", [[
[
  {"id":0,"name":"eDP-1","width":1920,"height":1080,"x":0,"y":0,"refreshRate":60.0,"scale":1.0,"disabled":false,"focused":true,"mirrorOf":"none","activeWorkspace":{"id":1,"name":"1"}},
  {"id":1,"name":"HDMI-A-1","width":2560,"height":1440,"x":1920,"y":0,"refreshRate":144.0,"scale":1.0,"disabled":false,"focused":false,"mirrorOf":"none","activeWorkspace":{"id":2,"name":"2"}}
]
]])
            fs.write_atomic(home .. "/noc-calls", "")
            assert_true(os.execute(cli_env .. " TEST_DND=off " .. kdisplay .. " present 3 >/dev/null 2>&1"))
            fs.write_atomic(home .. "/mock-monitors.json", '[{"id":0,"name":"eDP-1","width":1920,"height":1080,"scale":1.0,"disabled":true}]')
            fs.write_atomic(home .. "/hypr-calls", "")
            fs.write_atomic(home .. "/noc-calls", "")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " --on-disconnect HDMI-A-1 >/dev/null 2>&1"))
            local disc_hypr = assert(fs.read_file(home .. "/hypr-calls"))
            assert_contains(disc_hypr, 'output = "eDP-1"')
            assert_contains(disc_hypr, 'position = "0x0"')
            assert_contains(assert(fs.read_file(home .. "/noc-calls")), "msg notification-dnd-set off\n")

            -- 6. cleanup clears display-state.json and tears down active virtual-share
            fs.write_atomic(home .. "/mock-monitors.json", [[
[
  {"id":0,"name":"eDP-1","width":1920,"height":1080,"x":0,"y":0,"refreshRate":60.0,"scale":1.0,"disabled":false,"focused":true,"activeWorkspace":{"id":1,"name":"1"}},
  {"id":2,"name":"kaze-share","width":1920,"height":1080,"x":9999,"y":0,"refreshRate":60.0,"scale":1.0,"disabled":false,"focused":false,"activeWorkspace":{"id":9,"name":"9"},"hardwareDetails":{"backend":"headless"}}
]
]])
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " virtual-share 9 >/dev/null 2>&1"))
            assert_true(fs.file_exists(runtime .. "/kaze/display-state.json"))
            assert_true(fs.file_exists(runtime .. "/kaze/monitors.lua"), "active virtual-share writes runtime monitors.lua")
            fs.write_atomic(home .. "/hypr-calls", "")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " cleanup >/dev/null 2>&1"))
            assert_true(not fs.file_exists(runtime .. "/kaze/display-state.json"), "cleanup must remove state file")
            assert_true(not fs.file_exists(runtime .. "/kaze/monitors.lua"), "cleanup must remove runtime monitors.lua")
            assert_contains(assert(fs.read_file(home .. "/hypr-calls")), "output remove kaze-share\n")

            -- 7. Clean 4-branch --menu, Layout submenu (including External Only & Laptop Only), Virtual Share with HDMI, and ascending workspace picker
            fs.write_atomic(home .. "/mock-monitors.json", [[
[
  {"id":0,"name":"eDP-1","width":1920,"height":1080,"x":0,"y":0,"refreshRate":60.0,"scale":1.0,"disabled":false,"focused":true,"mirrorOf":"none","activeWorkspace":{"id":3,"name":"3"}},
  {"id":1,"name":"HDMI-A-1","width":2560,"height":1440,"x":1920,"y":0,"refreshRate":144.0,"scale":1.0,"disabled":false,"focused":false,"mirrorOf":"none","activeWorkspace":{"id":2,"name":"2"}}
]
]])
            fs.write_atomic(home .. "/mock-workspaces.json", '[{"id":3,"name":"3","monitor":"eDP-1","windows":2},{"id":1,"name":"1","monitor":"eDP-1","windows":1},{"id":2,"name":"2","monitor":"HDMI-A-1","windows":0}]')
            fs.write_atomic(home .. "/mock-clients.json", '[{"address":"0x1","class":"foot","workspace":{"id":1}},{"address":"0x2","class":"chromium","workspace":{"id":3}},{"address":"0x3","class":"nvim","workspace":{"id":3}}]')

            -- Dual-monitor idle menu has exact 4 branches: Mirror, Present Workspace, Virtual Share, Extend / Layout
            fs.write_atomic(home .. "/dmenu-all", "")
            os.remove(home .. "/dmenu-seq")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " --menu >/dev/null 2>&1"))
            local menu_dump = assert(fs.read_file(home .. "/dmenu-items"))
            assert_contains(menu_dump, "Mirror Full Screen\n")
            assert_contains(menu_dump, "Present Workspace…\n")
            assert_contains(menu_dump, "Virtual Share (Meet / Discord 1080p)…\n")
            assert_contains(menu_dump, "Extend / Layout…\n")
            assert_true(not menu_dump:find("Share Window", 1, true), "menu must omit Share Window / Region")
            assert_true(not menu_dump:find("Laptop Only", 1, true), "top menu keeps Laptop Only inside Layout submenu")
            assert_true(not menu_dump:find("External Only", 1, true), "top menu keeps External Only inside Layout submenu")
            local line_count = 0
            for _ in menu_dump:gmatch("[^\n]+") do line_count = line_count + 1 end
            assert_eq(line_count, 4, "dual-monitor idle menu must have exactly 4 branches")

            -- Extend / Layout... opens Layout submenu with Extend + External Only + Laptop Only + Auto
            fs.write_atomic(home .. "/dmenu-all", "")
            fs.write_atomic(home .. "/hypr-calls", "")
            os.remove(home .. "/dmenu-seq")
            assert_true(os.execute(cli_env .. " TEST_DMENU_SELECT='Extend / Layout…' TEST_DMENU_SELECT_2='Extend Right' " .. kdisplay .. " --menu >/dev/null 2>&1"))
            local ext_sub = assert(fs.read_file(home .. "/dmenu-items"))
            assert_contains(ext_sub, "Extend Right  (eDP-1 → HDMI-A-1)")
            assert_contains(ext_sub, "Extend Left   (HDMI-A-1 ← eDP-1)")
            assert_contains(ext_sub, "Extend Above  (HDMI-A-1 ↑ eDP-1)")
            assert_contains(ext_sub, "External Only (HDMI-A-1)")
            assert_contains(ext_sub, "Laptop Only   (eDP-1)")
            assert_contains(ext_sub, "Auto Reset All Monitors")
            assert_contains(assert(fs.read_file(home .. "/hypr-calls")), 'position = "auto-right"')

            -- External Only (confirmed via 3rd dmenu) and Laptop Only work from Layout submenu
            fs.write_atomic(home .. "/hypr-calls", "")
            os.remove(home .. "/dmenu-seq")
            os.remove(home .. "/dmenu-seq-2")
            assert_true(os.execute(cli_env .. " TEST_DMENU_SELECT='Extend / Layout…' TEST_DMENU_SELECT_2='External Only' TEST_DMENU_SELECT_3='Keep External Only' " .. kdisplay .. " --menu >/dev/null 2>&1"))
            assert_contains(assert(fs.read_file(home .. "/hypr-calls")), 'output = "eDP-1", disabled = true')
            local ext_conf_items = assert(fs.read_file(home .. "/dmenu-items"))
            local p_rev = assert(ext_conf_items:find("Revert to Laptop (eDP-1)", 1, true))
            local p_keep = assert(ext_conf_items:find("Keep External Only (HDMI-A-1)", 1, true))
            assert_true(p_rev < p_keep, "Revert must be first option in External Only confirmation dialog")
            assert_true(not fs.file_exists(runtime .. "/kaze/external-revert.json"), "confirmed External Only cleans up external-revert.json")
            fs.write_atomic(home .. "/hypr-calls", "")
            os.remove(home .. "/dmenu-seq")
            os.remove(home .. "/dmenu-seq-2")
            assert_true(os.execute(cli_env .. " TEST_DMENU_SELECT='Extend / Layout…' TEST_DMENU_SELECT_2='Laptop Only' " .. kdisplay .. " --menu >/dev/null 2>&1"))
            assert_contains(assert(fs.read_file(home .. "/hypr-calls")), 'output = "HDMI-A-1", disabled = true')

            -- Present Workspace... opens ascending picker (WS 1 -> WS 2 -> ★ WS 3 -> New clean) and presents WS 3
            fs.write_atomic(home .. "/dmenu-all", "")
            fs.write_atomic(home .. "/noc-calls", "")
            os.remove(home .. "/dmenu-seq")
            assert_true(os.execute(cli_env .. " TEST_DND=off TEST_DMENU_SELECT='Present Workspace…' TEST_DMENU_SELECT_2='★ WS 3' " .. kdisplay .. " --menu >/dev/null 2>&1"))
            local picker_dump = assert(fs.read_file(home .. "/dmenu-items"))
            local p_ws1 = assert(picker_dump:find("WS 1  [foot]  (on eDP-1)", 1, true))
            local p_ws2 = assert(picker_dump:find("WS 2  [empty]  (on HDMI-A-1)", 1, true))
            local p_ws3 = assert(picker_dump:find("★ WS 3  [chromium, nvim]  (current, on eDP-1)", 1, true))
            local p_new = assert(picker_dump:find("New clean workspace (WS ", 1, true))
            assert_true(p_ws1 < p_ws2 and p_ws2 < p_ws3 and p_ws3 < p_new, "picker must sort strictly ascending 1 -> 2 -> 3 -> new")
            local m_st = json.decode(assert(fs.read_file(runtime .. "/kaze/display-state.json")))
            assert_eq(m_st.mode, "present")
            assert_eq(m_st.present_workspace, 3)

            -- Active status controls when presenting
            fs.write_atomic(home .. "/dmenu-all", "")
            os.remove(home .. "/dmenu-seq")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " --menu >/dev/null 2>&1"))
            local active_menu = assert(fs.read_file(home .. "/dmenu-items"))
            assert_contains(active_menu, "Control WS 3 on Laptop (Mirror)")
            assert_contains(active_menu, "Stop Presentation (WS 3)")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " stop-present >/dev/null 2>&1"))

            -- Active Stop Mirror control when Mirror Full Screen is active
            assert_true(os.execute(cli_env .. " TEST_DND=off " .. kdisplay .. " mirror >/dev/null 2>&1"))
            fs.write_atomic(home .. "/dmenu-all", "")
            fs.write_atomic(home .. "/hypr-calls", "")
            fs.write_atomic(home .. "/noc-calls", "")
            os.remove(home .. "/dmenu-seq")
            assert_true(os.execute(cli_env .. " TEST_DMENU_SELECT='Stop Mirror' " .. kdisplay .. " --menu >/dev/null 2>&1"))
            assert_contains(assert(fs.read_file(home .. "/dmenu-items")), "Stop Mirror (HDMI-A-1)")
            assert_contains(assert(fs.read_file(home .. "/hypr-calls")), "reload\n")
            assert_contains(assert(fs.read_file(home .. "/hypr-calls")), 'position = "auto-right"')
            assert_contains(assert(fs.read_file(home .. "/noc-calls")), "msg notification-dnd-set off\n")
            local after_stop_mir = json.decode(assert(fs.read_file(runtime .. "/kaze/display-state.json")))
            assert_eq(after_stop_mir.mode, "extend-right")

            -- Single-monitor menu shows Virtual Share and Auto Reset Monitors
            fs.write_atomic(home .. "/mock-monitors.json", '[{"id":0,"name":"eDP-1","width":1920,"height":1080,"x":0,"y":0,"refreshRate":60.0,"scale":1.0,"disabled":false,"focused":true,"activeWorkspace":{"id":1,"name":"1"}}]')
            fs.write_atomic(home .. "/dmenu-all", "")
            os.remove(home .. "/dmenu-seq")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " --menu >/dev/null 2>&1"))
            local single_menu = assert(fs.read_file(home .. "/dmenu-items"))
            assert_contains(single_menu, "Virtual Share (Meet / Discord 1080p)…")
            assert_contains(single_menu, "Auto Reset Monitors")

            -- 9. toggle-control, toggle-preview, and toggle-window-share during HDMI present mode
            fs.write_atomic(home .. "/mock-monitors.json", [[
[
  {"id":0,"name":"eDP-1","width":1920,"height":1080,"x":0,"y":0,"refreshRate":60.0,"scale":1.0,"disabled":false,"focused":true,"mirrorOf":"none","activeWorkspace":{"id":1,"name":"1"}},
  {"id":1,"name":"HDMI-A-1","width":2560,"height":1440,"x":1920,"y":0,"refreshRate":144.0,"scale":1.0,"disabled":false,"focused":false,"mirrorOf":"none","activeWorkspace":{"id":3,"name":"3"}}
]
]])
            fs.write_atomic(home .. "/mock-workspaces.json", '[{"id":1,"name":"1","monitor":"eDP-1","windows":1},{"id":3,"name":"3","monitor":"HDMI-A-1","windows":1}]')
            fs.write_atomic(home .. "/mock-activewindow.json", '{"address":"0xp1","monitor":0,"workspace":{"id":1}}')
            assert_true(os.execute(cli_env .. " TEST_DND=off " .. kdisplay .. " present 3 >/dev/null 2>&1"))

            -- toggle-preview in present mode mirrors HDMI-A-1
            fs.write_atomic(home .. "/wlmirror-calls", "")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " toggle-preview >/dev/null 2>&1"))
            os.execute("sleep 0.05")
            assert_contains(assert(fs.read_file(home .. "/wlmirror-calls")), "--title kaze-share-preview HDMI-A-1\n")
            local hp_st = json.decode(assert(fs.read_file(runtime .. "/kaze/display-state.json")))
            assert_eq(hp_st.preview_target, "HDMI-A-1")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " toggle-preview >/dev/null 2>&1"))
            local hp_st2 = json.decode(assert(fs.read_file(runtime .. "/kaze/display-state.json")))
            assert_eq(hp_st2.preview_pid, nil)
            assert_eq(hp_st2.preview_target, nil)

            -- toggle-window-share pushes focused window to presented WS 3 and pulls back
            fs.write_atomic(home .. "/hypr-calls", "")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " toggle-window-share >/dev/null 2>&1"))
            assert_contains(assert(fs.read_file(home .. "/hypr-calls")), 'window.move({ workspace = "3", silent = true })')
            fs.write_atomic(home .. "/mock-activewindow.json", '{"address":"0xp1","monitor":1,"workspace":{"id":3}}')
            fs.write_atomic(home .. "/hypr-calls", "")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " toggle-window-share >/dev/null 2>&1"))
            assert_contains(assert(fs.read_file(home .. "/hypr-calls")), 'window.move({ workspace = "1", silent = true })')

            -- toggle-control enter: moves WS 3 onto eDP-1 and focuses BEFORE mirroring HDMI-A-1
            fs.write_atomic(home .. "/hypr-calls", "")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " toggle-control >/dev/null 2>&1"))
            local ctrl_hypr = assert(fs.read_file(home .. "/hypr-calls"))
            local p_move_int = assert(ctrl_hypr:find('workspace.move({ workspace = "3", monitor = "eDP-1" })', 1, true))
            local p_focus_ws = assert(ctrl_hypr:find('focus({ workspace = "3" })', 1, true))
            local p_mirror = assert(ctrl_hypr:find('mirror = "eDP-1"', 1, true))
            assert_true(p_move_int < p_focus_ws and p_focus_ws < p_mirror, "must move and focus WS 3 on laptop BEFORE mirror")
            local ctrl_st = json.decode(assert(fs.read_file(runtime .. "/kaze/display-state.json")))
            assert_eq(ctrl_st.control_on_laptop, true)
            assert_eq(ctrl_st.saved_laptop_workspace, 1)

            -- Menu shows Back to Private Laptop when control_on_laptop is active
            fs.write_atomic(home .. "/dmenu-items", "")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " --menu >/dev/null 2>&1"))
            assert_contains(assert(fs.read_file(home .. "/dmenu-items")), "Back to Private Laptop (return WS 3 → HDMI-A-1)")

            -- toggle-control exit: reloads to clear mirror, re-hides bar, returns WS 3 to HDMI-A-1, restores WS 1
            fs.write_atomic(home .. "/hypr-calls", "")
            fs.write_atomic(home .. "/noc-calls", "")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " toggle-control >/dev/null 2>&1"))
            local ret_hypr = assert(fs.read_file(home .. "/hypr-calls"))
            local p_reload = assert(ret_hypr:find("reload\n", 1, true))
            local p_ext_pos = assert(ret_hypr:find('position = "auto-right"', 1, true))
            local p_ws_back = assert(ret_hypr:find('workspace.move({ workspace = "3", monitor = "HDMI-A-1" })', 1, true))
            local p_ws_restore = assert(ret_hypr:find('focus({ workspace = "1" })', 1, true))
            assert_true(p_reload < p_ext_pos and p_ext_pos < p_ws_back and p_ws_back < p_ws_restore)
            assert_contains(assert(fs.read_file(home .. "/noc-calls")), "msg bar-hide default HDMI-A-1\n")
            local ret_st = json.decode(assert(fs.read_file(runtime .. "/kaze/display-state.json")))
            assert_eq(ret_st.control_on_laptop, false)
            assert_eq(ret_st.saved_laptop_workspace, nil)
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " stop-present >/dev/null 2>&1"))

            -- 9. Multi-step chaining: present -> mirror -> extend-right (preserves smart_gaps & persistent = true, evacuates WS 3)
            fs.write_atomic(home .. "/hypr-calls", "")
            fs.write_atomic(home .. "/noc-calls", "")
            assert_true(os.execute(cli_env .. " TEST_DND=off " .. kdisplay .. " present 3 >/dev/null 2>&1"))
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " mirror >/dev/null 2>&1"))
            local chain_hypr = assert(fs.read_file(home .. "/hypr-calls"))
            assert_contains(chain_hypr, 'r:set_enabled(false)', "present -> mirror must disable per-workspace rule via set_enabled(false)")
            assert_contains(chain_hypr, 'hl.workspace_rule({ workspace = "3", persistent = true })', "present -> mirror must preserve persistent = true on WS 3")
            assert_contains(chain_hypr, 'workspace.move({ workspace = "3", monitor = "eDP-1" })', "present -> mirror must evacuate WS 3 back to eDP-1")
            assert_contains(chain_hypr, 'hl.window_rule({ name = "kaze-present-edge", enabled = false })', "present -> mirror must disable kaze-present-edge")
            fs.write_atomic(home .. "/noc-calls", "")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " extend-right >/dev/null 2>&1"))
            assert_contains(assert(fs.read_file(home .. "/noc-calls")), "msg notification-dnd-set off\n", "present -> mirror -> extend-right must restore DND")

            -- 12. Dynamic Island widget.present live indicator + floating-rail dual-bar hide/show
            fs.write_atomic(cfg .. "/kaze/style", "floating-rail\n")
            fs.write_atomic(home .. "/noc-calls", "")
            assert_true(os.execute(cli_env .. " TEST_PRESENT_WIDGET=1 TEST_DND=off " .. kdisplay .. " present 3 >/dev/null 2>&1"))
            local multi_noc = assert(fs.read_file(home .. "/noc-calls"))
            assert_contains(multi_noc, "msg bar-hide default HDMI-A-1\n")
            assert_contains(multi_noc, "msg bar-hide rail HDMI-A-1\n")
            assert_contains(multi_noc, "msg config-set widget.present.enabled true\n")
            assert_contains(multi_noc, 'msg config-set widget.present.label "LIVE"\n')
            fs.write_atomic(home .. "/noc-calls", "")
            assert_true(os.execute(cli_env .. " TEST_PRESENT_WIDGET=1 " .. kdisplay .. " stop-present >/dev/null 2>&1"))
            local multi_stop = assert(fs.read_file(home .. "/noc-calls"))
            assert_contains(multi_stop, "msg bar-show default HDMI-A-1\n")
            assert_contains(multi_stop, "msg bar-show rail HDMI-A-1\n")
            assert_contains(multi_stop, "msg config-set widget.present.enabled false\n")
            assert_contains(multi_stop, 'msg config-set widget.present.label ""\n')
            os.remove(cfg .. "/kaze/style")

            -- switch-share evacuates previous virtual workspace back to primary monitor
            fs.write_atomic(home .. "/mock-monitors.json", [[
[
  {"id":0,"name":"eDP-1","width":1920,"height":1080,"x":0,"y":0,"refreshRate":60.0,"scale":1.0,"disabled":false,"focused":true,"activeWorkspace":{"id":1,"name":"1"}},
  {"id":2,"name":"kaze-share","width":1920,"height":1080,"x":9999,"y":0,"refreshRate":60.0,"scale":1.0,"disabled":false,"focused":false,"activeWorkspace":{"id":9,"name":"9"},"hardwareDetails":{"backend":"headless"}}
]
]])
            fs.write_atomic(home .. "/mock-workspaces.json", '[{"id":1,"name":"1","monitor":"eDP-1","windows":1},{"id":9,"name":"9","monitor":"kaze-share","windows":1}]')
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " virtual-share 9 >/dev/null 2>&1"))
            fs.write_atomic(home .. "/hypr-calls", "")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " switch-share 8 >/dev/null 2>&1"))
            local sw_hypr = assert(fs.read_file(home .. "/hypr-calls"))
            assert_contains(sw_hypr, 'workspace.move({ workspace = "9", monitor = "eDP-1" })', "switch-share must evacuate old WS 9 back to eDP-1")

            -- External Only + Virtual Share + unplugging HDMI-A-1 rescues non-virtual workspaces from kaze-share onto recovered eDP-1
            fs.write_atomic(home .. "/mock-monitors.json", [[
[
  {"id":0,"name":"eDP-1","width":1920,"height":1080,"scale":1.0,"disabled":true},
  {"id":2,"name":"kaze-share","width":1920,"height":1080,"x":9999,"y":0,"refreshRate":60.0,"scale":1.0,"disabled":false,"activeWorkspace":{"id":9,"name":"9"},"hardwareDetails":{"backend":"headless"}}
]
]])
            fs.write_atomic(home .. "/mock-workspaces.json", '[{"id":2,"name":"2","monitor":"kaze-share","windows":2},{"id":8,"name":"8","monitor":"kaze-share","windows":1}]')
            fs.write_atomic(runtime .. "/kaze/display-state.json", json.encode({
                mode = "external",
                external_monitor = "HDMI-A-1",
                virtual_monitor = "kaze-share",
                virtual_workspace = 8,
            }))
            fs.write_atomic(home .. "/hypr-calls", "")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " --on-disconnect HDMI-A-1 >/dev/null 2>&1"))
            local ext_vs_disc = assert(fs.read_file(home .. "/hypr-calls"))
            assert_contains(ext_vs_disc, 'output = "eDP-1", mode = "preferred", position = "0x0", scale = 1')
            assert_contains(ext_vs_disc, 'workspace.move({ workspace = "2", monitor = "eDP-1" })', "must rescue stranded WS 2 off kaze-share")
            assert_true(not ext_vs_disc:find('workspace.move({ workspace = "8", monitor = "eDP-1" })', 1, true), "must keep virtual WS 8 on kaze-share")

            -- 10. Virtual Share survives mirror -> extend-right reload (kaze-share stays at 9999x0 + bar hidden + edge rule)
            fs.write_atomic(home .. "/mock-monitors.json", [[
[
  {"id":0,"name":"eDP-1","width":1920,"height":1080,"x":0,"y":0,"refreshRate":60.0,"scale":1.0,"disabled":false,"focused":true,"mirrorOf":"none","activeWorkspace":{"id":1,"name":"1"}},
  {"id":1,"name":"HDMI-A-1","width":2560,"height":1440,"x":1920,"y":0,"refreshRate":144.0,"scale":1.0,"disabled":false,"focused":false,"mirrorOf":"none","activeWorkspace":{"id":2,"name":"2"}}
]
]])
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " virtual-share 9 >/dev/null 2>&1"))
            fs.write_atomic(home .. "/mock-monitors.json", [[
[
  {"id":0,"name":"eDP-1","width":1920,"height":1080,"x":0,"y":0,"refreshRate":60.0,"scale":1.0,"disabled":false,"focused":true,"mirrorOf":"none","activeWorkspace":{"id":1,"name":"1"}},
  {"id":1,"name":"HDMI-A-1","width":2560,"height":1440,"x":1920,"y":0,"refreshRate":144.0,"scale":1.0,"disabled":false,"focused":false,"mirrorOf":"eDP-1","activeWorkspace":{"id":1,"name":"1"}},
  {"id":2,"name":"kaze-share","width":1920,"height":1080,"x":9999,"y":0,"refreshRate":60.0,"scale":1.0,"disabled":false,"focused":false,"activeWorkspace":{"id":9,"name":"9"},"hardwareDetails":{"backend":"headless"}}
]
]])
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " mirror >/dev/null 2>&1"))
            fs.write_atomic(home .. "/hypr-calls", "")
            fs.write_atomic(home .. "/noc-calls", "")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " extend-right >/dev/null 2>&1"))
            local vs_reload_hypr = assert(fs.read_file(home .. "/hypr-calls"))
            assert_contains(vs_reload_hypr, "reload\n")
            assert_contains(vs_reload_hypr, 'output = "kaze-share", mode = "1920x1080@60", position = "9999x0", scale = 1')
            assert_contains(vs_reload_hypr, 'name = "kaze-share-edge"')
            assert_contains(assert(fs.read_file(home .. "/noc-calls")), "msg bar-hide default kaze-share\n")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " stop-virtual >/dev/null 2>&1"))

            -- 11. Zero-monitor --on-disconnect still cleans up active present + restores DND
            fs.write_atomic(home .. "/mock-monitors.json", [[
[
  {"id":0,"name":"eDP-1","width":1920,"height":1080,"x":0,"y":0,"refreshRate":60.0,"scale":1.0,"disabled":false,"focused":true,"mirrorOf":"none","activeWorkspace":{"id":1,"name":"1"}},
  {"id":1,"name":"HDMI-A-1","width":2560,"height":1440,"x":1920,"y":0,"refreshRate":144.0,"scale":1.0,"disabled":false,"focused":false,"mirrorOf":"none","activeWorkspace":{"id":2,"name":"2"}}
]
]])
            assert_true(os.execute(cli_env .. " TEST_DND=off " .. kdisplay .. " present 3 >/dev/null 2>&1"))
            fs.write_atomic(home .. "/mock-monitors.json", "[]")
            fs.write_atomic(home .. "/noc-calls", "")
            fs.write_atomic(home .. "/hypr-calls", "")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " --on-disconnect HDMI-A-1 >/dev/null 2>&1"))
            assert_contains(assert(fs.read_file(home .. "/noc-calls")), "msg notification-dnd-set off\n")
            assert_contains(assert(fs.read_file(home .. "/hypr-calls")), 'hl.window_rule({ name = "kaze-present-edge", enabled = false })')
            local zero_st = json.decode(assert(fs.read_file(runtime .. "/kaze/display-state.json")))
            assert_eq(zero_st.present_workspace, nil)

            -- 13. External Only 15s auto-revert confirmation (Esc/cancel, real timeout expiry, --no-confirm, and stale-generation guard)
            fs.write_atomic(home .. "/mock-monitors.json", [[
[
  {"id":0,"name":"eDP-1","width":1920,"height":1080,"x":0,"y":0,"refreshRate":60.0,"scale":1.0,"disabled":false,"focused":true,"mirrorOf":"none","activeWorkspace":{"id":1,"name":"1"}},
  {"id":1,"name":"HDMI-A-1","width":2560,"height":1440,"x":1920,"y":0,"refreshRate":144.0,"scale":1.0,"disabled":false,"focused":false,"mirrorOf":"none","activeWorkspace":{"id":2,"name":"2"}}
]
]])
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " extend-left >/dev/null 2>&1"))
            -- 13a. Esc/empty confirm reverts automatically to prior extend-left layout and focuses eDP-1
            fs.write_atomic(home .. "/hypr-calls", "")
            os.remove(home .. "/dmenu-seq")
            os.remove(home .. "/dmenu-seq-2")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " external >/dev/null 2>&1"))
            local rev_hypr = assert(fs.read_file(home .. "/hypr-calls"))
            local p_dis = assert(rev_hypr:find('output = "eDP-1", disabled = true', 1, true))
            local p_res = assert(rev_hypr:find('output = "eDP-1", mode = "1920x1080@60.00", position = "0x0"', p_dis, true))
            local p_foc = assert(rev_hypr:find('focus({ monitor = "eDP-1" })', p_res, true))
            assert_true(p_dis < p_res and p_res < p_foc, "unconfirmed External Only must re-enable and focus eDP-1")
            local after_rev_st = json.decode(assert(fs.read_file(runtime .. "/kaze/display-state.json")))
            assert_eq(after_rev_st.mode, "extend-left", "External Only revert must restore prior extend-left mode")

            -- 13b. Real GNU timeout expiry (0.25s) triggers automatic revert AND closes Noctalia launcher panel
            fs.write_atomic(home .. "/hypr-calls", "")
            fs.write_atomic(home .. "/noc-calls", "")
            assert_true(os.execute(cli_env .. " KAZE_DISPLAY_CONFIRM_SEC=0.25 TEST_DMENU_SLEEP=5 " .. kdisplay .. " external >/dev/null 2>&1"))
            local to_hypr = assert(fs.read_file(home .. "/hypr-calls"))
            assert_contains(to_hypr, 'output = "eDP-1", disabled = true')
            assert_contains(to_hypr, 'focus({ monitor = "eDP-1" })')
            assert_contains(assert(fs.read_file(home .. "/noc-calls")), "msg panel-close launcher\n", "timed-out dmenu must dismiss Noctalia launcher overlay")
            local after_to_st = json.decode(assert(fs.read_file(runtime .. "/kaze/display-state.json")))
            assert_eq(after_to_st.mode, "extend-left", "timed-out External Only must auto-revert")

            -- 13c. --no-confirm skips dmenu confirmation completely, and a no-op --on-disconnect eDP-1 does NOT bump generation
            fs.write_atomic(home .. "/noc-calls", "")
            fs.write_atomic(home .. "/hypr-calls", "")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " external --no-confirm >/dev/null 2>&1"))
            assert_true(not (fs.read_file(home .. "/noc-calls") or ""):find("dmenu", 1, true), "external --no-confirm must not open dmenu")
            local noconf_st = json.decode(assert(fs.read_file(runtime .. "/kaze/display-state.json")))
            assert_eq(noconf_st.mode, "external")
            local stale_gen = noconf_st.generation
            -- Simulate Hyprland firing monitor.removed for disabled eDP-1 while HDMI-A-1 is active
            fs.write_atomic(home .. "/mock-monitors.json", [[
[
  {"id":0,"name":"eDP-1","width":1920,"height":1080,"x":0,"y":0,"refreshRate":60.0,"scale":1.0,"disabled":true,"focused":false,"mirrorOf":"none"},
  {"id":1,"name":"HDMI-A-1","width":2560,"height":1440,"x":0,"y":0,"refreshRate":144.0,"scale":1.0,"disabled":false,"focused":true,"mirrorOf":"none","activeWorkspace":{"id":2,"name":"2"}}
]
]])
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " --on-disconnect eDP-1 >/dev/null 2>&1"))
            local after_noop_disc = json.decode(assert(fs.read_file(runtime .. "/kaze/display-state.json")))
            assert_eq(after_noop_disc.generation, stale_gen, "no-op --on-disconnect for disabled internal panel must not bump state.generation")
            fs.write_atomic(home .. "/mock-monitors.json", [[
[
  {"id":0,"name":"eDP-1","width":1920,"height":1080,"x":0,"y":0,"refreshRate":60.0,"scale":1.0,"disabled":false,"focused":true,"mirrorOf":"none","activeWorkspace":{"id":1,"name":"1"}},
  {"id":1,"name":"HDMI-A-1","width":2560,"height":1440,"x":1920,"y":0,"refreshRate":144.0,"scale":1.0,"disabled":false,"focused":false,"mirrorOf":"none","activeWorkspace":{"id":2,"name":"2"}}
]
]])

            -- 13d. Stale generation guard: if state already changed (e.g. --on-disconnect), late --revert-external does nothing
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " internal >/dev/null 2>&1"))
            fs.write_atomic(home .. "/hypr-calls", "")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " --revert-external " .. tostring(stale_gen) .. " timeout >/dev/null 2>&1"))
            assert_eq(fs.read_file(home .. "/hypr-calls") or "", "", "stale --revert-external must be ignored after newer state transition")

            -- 14. Split flock concurrency protection (display.lock & display-menu.lock)
            -- 14a. Held display.lock drops overlapping non-critical mutation cleanly without touching hyprctl
            fs.write_atomic(home .. "/hypr-calls", "")
            local lock_drop_ok = os.execute(string.format(
                "flock -x %s sh -c %s >/dev/null 2>&1",
                q(runtime .. "/kaze/display.lock"),
                q(cli_env .. " " .. kdisplay .. " extend-right")
            ))
            assert_true(lock_drop_ok, "overlapping mutation under held display.lock exits 0 cleanly")
            assert_eq(fs.read_file(home .. "/hypr-calls") or "", "", "dropped mutation must not execute hyprctl")

            -- 14b. Held display-menu.lock drops overlapping --hotplug / --menu cleanly without spawning second dmenu
            fs.write_atomic(home .. "/noc-calls", "")
            local menu_drop_ok = os.execute(string.format(
                "flock -x %s sh -c %s >/dev/null 2>&1",
                q(runtime .. "/kaze/display-menu.lock"),
                q(cli_env .. " " .. kdisplay .. " --hotplug HDMI-A-1")
            ))
            assert_true(menu_drop_ok, "overlapping hotplug under held display-menu.lock exits 0 cleanly")
            assert_eq(fs.read_file(home .. "/noc-calls") or "", "", "dropped hotplug must not spawn second dmenu")

            -- 14c. Critical --on-disconnect runs IMMEDIATELY even while display-menu.lock is held (menu open)
            fs.write_atomic(home .. "/mock-monitors.json", '[{"id":0,"name":"eDP-1","width":1920,"height":1080,"scale":1.0,"disabled":true}]')
            fs.write_atomic(home .. "/hypr-calls", "")
            local disc_menu_ok = os.execute(string.format(
                "flock -x %s sh -c %s >/dev/null 2>&1",
                q(runtime .. "/kaze/display-menu.lock"),
                q(cli_env .. " " .. kdisplay .. " --on-disconnect HDMI-A-1")
            ))
            assert_true(disc_menu_ok, "--on-disconnect must succeed while display-menu.lock is held")
            assert_contains(assert(fs.read_file(home .. "/hypr-calls")), 'output = "eDP-1", mode = "preferred", position = "0x0"')

            -- 14d. Critical --on-disconnect waits for brief display.lock release and still recovers
            fs.write_atomic(home .. "/hypr-calls", "")
            local disc_wait_ok = os.execute(string.format(
                "(flock -x %s sleep 0.25) & lp=$!; sleep 0.05; %s %s --on-disconnect HDMI-A-1 >/dev/null 2>&1; rc=$?; wait $lp; exit $rc",
                q(runtime .. "/kaze/display.lock"),
                cli_env,
                kdisplay
            ))
            assert_true(disc_wait_ok, "--on-disconnect must wait for brief display.lock instead of dropping")
            assert_contains(assert(fs.read_file(home .. "/hypr-calls")), 'output = "eDP-1", mode = "preferred", position = "0x0"')

            -- 15. Direct kaze-share control via Ctrl+Super+P (toggle-control): fullscreen wl-mirror + focus jump, 0 reload, suspends/restores PiP preview
            fs.write_atomic(home .. "/mock-monitors.json", [[
[
  {"id":0,"name":"eDP-1","width":1920,"height":1080,"x":0,"y":0,"refreshRate":60.0,"scale":1.0,"disabled":false,"focused":true,"activeWorkspace":{"id":1,"name":"1"}},
  {"id":2,"name":"kaze-share","width":1920,"height":1080,"x":9999,"y":0,"refreshRate":60.0,"scale":1.0,"disabled":false,"focused":false,"activeWorkspace":{"id":9,"name":"9"},"hardwareDetails":{"backend":"headless"}}
]
]])
            fs.write_atomic(home .. "/mock-workspaces.json", '[{"id":1,"name":"1","monitor":"eDP-1","windows":1},{"id":9,"name":"9","monitor":"kaze-share","windows":1}]')
            fs.write_atomic(home .. "/mock-activewindow.json", '{"address":"0xshare1","monitor":2,"workspace":{"id":9}}')
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " virtual-share 9 >/dev/null 2>&1"))
            -- Open PiP preview first so we verify toggle-control suspends and later restores it
            fs.write_atomic(home .. "/wlmirror-calls", "")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " toggle-preview >/dev/null 2>&1"))
            os.execute("sleep 0.05")

            -- Menu shows Control kaze-share Directly when share_active and not yet controlling
            fs.write_atomic(home .. "/dmenu-items", "")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " --menu >/dev/null 2>&1"))
            assert_contains(assert(fs.read_file(home .. "/dmenu-items")), "Control kaze-share Directly (WS 9)")

            -- Enter direct kaze-share control via toggle-control
            fs.write_atomic(home .. "/hypr-calls", "")
            fs.write_atomic(home .. "/noc-calls", "")
            fs.write_atomic(home .. "/wlmirror-calls", "")
            assert_true(os.execute(cli_env .. " TEST_PRESENT_WIDGET=1 " .. kdisplay .. " toggle-control >/dev/null 2>&1"))
            os.execute("sleep 0.05")
            local vc_wlm = assert(fs.read_file(home .. "/wlmirror-calls"))
            assert_contains(vc_wlm, "--title kaze-share-control --fullscreen-output eDP-1 --show-cursor kaze-share\n")
            local vc_hypr = assert(fs.read_file(home .. "/hypr-calls"))
            assert_contains(vc_hypr, 'focus({ monitor = "kaze-share" })')
            assert_true(not vc_hypr:find("reload", 1, true), "kaze-share direct control must NEVER reload Hyprland")
            assert_true(not vc_hypr:find("window.move", 1, true), "kaze-share direct control must NEVER move windows off kaze-share")
            assert_contains(assert(fs.read_file(home .. "/noc-calls")), 'msg config-set widget.present.label "CTRL"\n')
            local vc_st = json.decode(assert(fs.read_file(runtime .. "/kaze/display-state.json")))
            assert_eq(vc_st.control_virtual, true)
            assert_true(type(vc_st.control_pid) == "number" and vc_st.control_pid > 0)
            assert_eq(vc_st.preview_pid, nil, "entering direct control suspends redundant PiP preview")
            assert_eq(vc_st.virtual_preview_suspended, true)

            -- Menu shows Exit kaze-share Control while active
            fs.write_atomic(home .. "/dmenu-items", "")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " --menu >/dev/null 2>&1"))
            assert_contains(assert(fs.read_file(home .. "/dmenu-items")), "Exit kaze-share Control (return to eDP-1)")

            -- Pulling a window off kaze-share while in control_virtual keeps focus on kaze-share
            fs.write_atomic(home .. "/hypr-calls", "")
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " toggle-window-share >/dev/null 2>&1"))
            local vc_pull = assert(fs.read_file(home .. "/hypr-calls"))
            assert_contains(vc_pull, 'window.move({ workspace = "1", silent = true })')
            assert_contains(vc_pull, 'focus({ monitor = "kaze-share" })')

            -- Exit direct kaze-share control via second toggle-control: returns focus to eDP-1, restores PiP preview, resets badge to SHARE
            fs.write_atomic(home .. "/hypr-calls", "")
            fs.write_atomic(home .. "/noc-calls", "")
            fs.write_atomic(home .. "/wlmirror-calls", "")
            assert_true(os.execute(cli_env .. " TEST_PRESENT_WIDGET=1 " .. kdisplay .. " toggle-control >/dev/null 2>&1"))
            os.execute("sleep 0.05")
            local vc_exit_hypr = assert(fs.read_file(home .. "/hypr-calls"))
            assert_contains(vc_exit_hypr, 'focus({ monitor = "eDP-1" })')
            assert_contains(vc_exit_hypr, 'focus({ workspace = "1" })')
            assert_true(not vc_exit_hypr:find("reload", 1, true), "exiting kaze-share direct control must NEVER reload Hyprland")
            assert_contains(assert(fs.read_file(home .. "/wlmirror-calls")), "--title kaze-share-preview kaze-share\n")
            assert_contains(assert(fs.read_file(home .. "/noc-calls")), 'msg config-set widget.present.label "SHARE"\n')
            local vc_exit_st = json.decode(assert(fs.read_file(runtime .. "/kaze/display-state.json")))
            assert_eq(vc_exit_st.control_virtual, nil)
            assert_eq(vc_exit_st.control_pid, nil)
            assert_true(type(vc_exit_st.preview_pid) == "number" and vc_exit_st.preview_pid > 0, "exiting direct control restores suspended PiP preview")

            -- Clean up virtual-share (stops restored preview too)
            assert_true(os.execute(cli_env .. " " .. kdisplay .. " stop-virtual >/dev/null 2>&1"))
        end)
        rm_rf(tmp)
        if not ok_cli then error(err_cli, 0) end

        -- Hyprland execs.lua hotplug & disconnect event handler test
        local hooks, execs = {}, {}
        local fake_now = 1000
        local prev_hl, prev_ctx, prev_time = rawget(_G, "hl"), package.loaded["kaze._ctx"], os.time
        local ok_exec, err_exec = pcall(function()
            os.time = function() return fake_now end
            package.loaded["kaze._ctx"] = { cfg = { cursor_theme = "Adwaita", cursor_size = 24, display_hotplug_menu = true } }
            rawset(_G, "hl", {
                on = function(ev, fn) hooks[ev] = fn end,
                exec_cmd = function(cmd) execs[#execs + 1] = cmd end,
            })
            dofile(repo_dir .. "/hypr/execs.lua")
            hooks["hyprland.start"]()
            assert_eq(#execs, 1)

            hooks["monitor.added"]({ name = "kaze-share" })
            hooks["monitor.added"]({ name = "eDP-1" }) -- internal panel ignored
            hooks["monitor.added"]({ name = "HDMI-A-1" }) -- < 5s startup grace
            assert_eq(#execs, 1)

            fake_now = 1006
            hooks["monitor.added"]({ name = "HDMI-A-1" })
            assert_eq(#execs, 2)
            assert_contains(execs[2], "kaze-display' --hotplug 'HDMI-A-1'")

            fake_now = 1007
            hooks["monitor.added"]({ name = "DP-1" }) -- <= 1s integer debounce
            assert_eq(#execs, 2)

            -- Simulated hyprctl reload (re-runs execs.lua without hyprland.start) must NOT re-arm 5s grace
            hooks = {}
            dofile(repo_dir .. "/hypr/execs.lua")
            hooks["monitor.added"]({ name = "DP-1" })
            assert_eq(#execs, 3)

            hooks["monitor.removed"]({ name = "kaze-share" })
            assert_eq(#execs, 3)
            hooks["monitor.removed"]({ name = "HDMI-A-1" })
            assert_eq(#execs, 4)
            assert_contains(execs[4], "kaze-display' --on-disconnect 'HDMI-A-1'")
        end)
        os.time = prev_time
        rawset(_G, "hl", prev_hl)
        package.loaded["kaze._ctx"] = prev_ctx
        if not ok_exec then error(err_exec, 0) end
    end)

    test("packages.sh: install-packages.sh and install.sh share the exact package manifest for minimal & full", function()
        local pkg_script = q(repo_dir .. "/scripts/install-packages.sh")
        local inst_script = q(repo_dir .. "/scripts/install.sh")

        local function extract_pkgs(text)
            local list = {}
            for line in (text .. "\n"):gmatch("(.-)\n") do
                local pkg = line:match("^  ([%w%+%._%-]+)$")
                if pkg then
                    list[#list + 1] = pkg
                end
            end
            return table.concat(list, "\n"), #list
        end

        for _, prof in ipairs({ { name = "minimal", count = 27 }, { name = "full", count = 55 } }) do
            local p_out, p_ok = read_all(pkg_script .. " --profile " .. prof.name .. " --dry-run 2>&1")
            local i_out, i_ok = read_all(inst_script .. " --profile " .. prof.name .. " --dry-run 2>&1")
            assert_true(p_ok, "install-packages.sh --dry-run failed for " .. prof.name .. ": " .. p_out)
            assert_true(i_ok, "install.sh --dry-run failed for " .. prof.name .. ": " .. i_out)
            local p_list, p_n = extract_pkgs(p_out)
            local i_list, i_n = extract_pkgs(i_out)
            assert_eq(p_n, prof.count, "expected exact package count for " .. prof.name)
            assert_eq(p_n, i_n, "package count mismatch for " .. prof.name)
            assert_eq(p_list, i_list, "package list mismatch for " .. prof.name)
            assert_contains(p_out, "0 AUR", "install-packages.sh reports 0 AUR")
            assert_contains(p_out, "sudo pacman -Syu", "install-packages.sh uses pacman -Syu")
        end

        local _, bad_ok = read_all(pkg_script .. " --profile bogus --dry-run 2>&1")
        assert_true(not bad_ok, "install-packages.sh must reject invalid profile")
    end)

    test("kaze.toml_diff & kaze-doctor --diff: detects missing Noctalia sections, keys, and bar widgets without flagging user edits", function()
        local toml_diff = require("kaze.toml_diff")
        local tpl = assert(fs.read_file(repo_dir .. "/config/noctalia/config.toml"))

        -- Modified values (user GUI edits + full profile polkit_agent) must produce zero drift
        local edited = tpl
            :gsub('mode = "dark"', 'mode = "light"')
            :gsub('builtin = "Kanagawa"', 'builtin = "Catppuccin"')
            :gsub('polkit_agent = false', 'polkit_agent = true')
            :gsub('directory = "~/Pictures/Wallpapers"', 'directory = "/home/tester/Pictures/Wallpapers"')
        local clean = toml_diff.diff(tpl, edited)
        assert_true(not clean.has_drift, "user value edits must not be reported as drift")
        local cs, ck, ci = toml_diff.summary_counts(clean)
        assert_eq(cs, 0)
        assert_eq(ck, 0)
        assert_eq(ci, 0)

        -- Simulated older user config missing [widget.display], [widget.display.actions], popup_shadows, and "display" widget
        local older = tpl
            :gsub('popup_shadows = false\n', '')
            :gsub('"tray", "display", "mirror"', '"tray",\n  "mirror"')
            :gsub('%[widget%.display%].-%[widget%.vclock%]', '[widget.vclock]')
        local drifted = toml_diff.diff(tpl, older)
        assert_true(drifted.has_drift, "older config must report drift")
        local ds, dk, di = toml_diff.summary_counts(drifted)
        assert_eq(ds, 2, "missing [widget.display] and [widget.display.actions]")
        assert_eq(dk, 1, "missing popup_shadows key")
        assert_eq(di, 1, "missing display bar widget")

        local report = toml_diff.format_report(drifted)
        assert_contains(report, "[widget.display]")
        assert_contains(report, 'glyph = "device-desktop"')
        assert_contains(report, "[shell] popup_shadows = false")
        assert_contains(report, '[bar.default] end: missing "display"')

        -- End-to-end CLI test for kaze-doctor --diff and normal [WARN] hint
        local tmp = make_tmp_dir()
        local ok_cli, err_cli = pcall(function()
            local home, cfg, data, cache, runtime = tmp .. "/home", tmp .. "/cfg", tmp .. "/data", tmp .. "/cache", tmp .. "/runtime"
            local stub_bin = tmp .. "/bin"
            for _, d in ipairs({ home, cfg .. "/noctalia", data, cache, runtime, stub_bin }) do fs.mkdir_p(d) end
            link_host_bin(stub_bin, "lua")
            for _, b in ipairs({
                "hyprland", "hyprctl", "noctalia", "notify-send",
                "foot", "footclient", "zsh", "wl-copy", "wl-paste",
                "wpctl", "brightnessctl", "playerctl",
                "busctl", "systemctl", "flock",
            }) do
                write_stub(stub_bin, b, "exit 0")
            end

            local doctor = q(repo_dir .. "/bin/kaze-doctor")
            local env = string.format(
                "HOME=%s XDG_CONFIG_HOME=%s XDG_DATA_HOME=%s XDG_CACHE_HOME=%s XDG_RUNTIME_DIR=%s LANG=en_US.UTF-8 LC_ALL='' PATH=%s",
                q(home), q(cfg), q(data), q(cache), q(runtime), q(stub_bin)
            )

            -- Missing config.toml -> non-zero exit
            local miss_out, miss_ok = read_all(env .. " " .. doctor .. " --diff 2>&1")
            assert_true(not miss_ok, "--diff must fail when user config.toml is absent")
            assert_contains(miss_out, "user Noctalia config not found")

            -- Up-to-date config -> exit 0, Status: up to date
            fs.write_atomic(cfg .. "/noctalia/config.toml", edited)
            local ok_out, ok_st = read_all(env .. " " .. doctor .. " --diff 2>&1")
            assert_true(ok_st, "--diff on up-to-date config failed: " .. ok_out)
            assert_contains(ok_out, "Status: up to date")

            -- Drifted config -> --diff prints snippet; normal --offline emits WARN hint
            fs.write_atomic(cfg .. "/noctalia/config.toml", older)
            local diff_out, diff_st = read_all(env .. " " .. doctor .. " --diff 2>&1")
            assert_true(diff_st, "--diff on drifted config failed: " .. diff_out)
            assert_contains(diff_out, "Status: drift detected (2 missing section(s), 1 missing key(s), 1 missing list item(s)).")
            assert_contains(diff_out, "[widget.display]")
            assert_contains(diff_out, '[bar.default] end: missing "display"')

            local off_out, off_st = read_all(env .. " " .. doctor .. " --offline 2>&1")
            assert_true(off_st, "--offline doctor should still exit 0 on drift warning:\n" .. off_out)
            assert_contains(off_out, "[WARN] noctalia: config.toml drift vs repo template")
            assert_contains(off_out, "kaze-doctor --diff")

            -- Invalid --template flag without value -> exit 2
            local _, bad_tpl_ok = read_all(env .. " " .. doctor .. " --diff --template 2>&1")
            assert_true(not bad_tpl_ok, "--template without path must fail")
        end)
        rm_rf(tmp)
        if not ok_cli then error(err_cli, 0) end
    end)

    test("kaze.mirror, kaze.mirror_tui & kaze-mirror: saturation math, edge cases, security commit/rollback, TUI & menu", function()
        local mirror = require("kaze.mirror")
        local mirror_tui = require("kaze.mirror_tui")
        local json = require("kaze.json")

        -- 1. Parse /etc/pacman.conf: Arch + CachyOS (incl. znver4), multi-arch first token, unmanaged & conflict skips
        local conf = mirror.parse_pacman_conf([[
[options]
Architecture = x86_64 x86_64_v3
ParallelDownloads = 15
[cachyos-v3]
Include = /etc/pacman.d/cachyos-v3-mirrorlist
[cachyos-extra-v3]
Include = /etc/pacman.d/cachyos-v3-mirrorlist
[cachyos-znver4]
Include = /etc/pacman.d/cachyos-v4-mirrorlist
[cachyos-extra-znver4]
Include = /etc/pacman.d/cachyos-v4-mirrorlist
[cachyos]
Include = /etc/pacman.d/cachyos-mirrorlist
[core]
Include = /etc/pacman.d/mirrorlist
[extra]
Include = /etc/pacman.d/mirrorlist
[multilib]
Include = /etc/pacman.d/mirrorlist
[chaotic-aur]
Include = /etc/pacman.d/chaotic-mirrorlist
[custom-inline]
Server = https://inline.example/$repo
Include = /etc/pacman.d/custom-mirrorlist
[extra-testing]
Include = /etc/pacman.d/mirror*
]], { arch = "x86_64" })
        assert_eq(conf.architecture, "x86_64", "extracts first Architecture token only")
        assert_eq(conf.parallel_downloads, 15)
        assert_eq(#conf.groups, 4, "only managed non-conflicting mirrorlists (v3, v4/znver4, cachyos, arch)")
        assert_eq(conf.groups[1].basename, "cachyos-v3-mirrorlist")
        assert_eq(conf.groups[1].arch_var, "$arch_v3")
        assert_eq(conf.groups[1].representative_repo, "cachyos-extra-v3")
        assert_eq(conf.groups[2].basename, "cachyos-v4-mirrorlist")
        assert_eq(conf.groups[2].arch_var, "$arch_v4")
        assert_eq(conf.groups[2].representative_repo, "cachyos-extra-znver4")
        assert_eq(conf.groups[4].basename, "mirrorlist")
        assert_eq(conf.groups[4].representative_repo, "extra")
        assert_true(#conf.skipped_repos >= 3, "chaotic-aur, custom-inline, and glob extra-testing must be skipped")

        -- 2. URL safety (blocks private/loopback/traversal/http) + libalpm exact $arch expansion
        assert_true(mirror.is_safe_https_url("https://mirrors.aliyun.com/archlinux/$repo/os/$arch"))
        assert_true(not mirror.is_safe_https_url("http://insecure.example/$repo/os/$arch"))
        assert_true(not mirror.is_safe_https_url("https://127.0.0.1/arch/$repo/os/$arch"))
        assert_true(not mirror.is_safe_https_url("https://192.168.1.1/arch/$repo/os/$arch"))
        assert_true(not mirror.is_safe_https_url("https://localhost/arch/$repo/os/$arch"))
        assert_true(not mirror.is_safe_https_url("https://bad.example/foo/../bar"))
        assert_eq(mirror.expand_db_url("https://cdn77.cachyos.org/repo/$arch_v3/$repo", "cachyos-extra-v3", "x86_64"),
            "https://cdn77.cachyos.org/repo/x86_64_v3/cachyos-extra-v3/cachyos-extra-v3.db")

        -- Single-# alternates included, ## maintainer-disabled excluded
        local act_s, comm_s = mirror.parse_mirrorlist_servers("Server = https://a.example/$arch/$repo\n# Server = https://b.example/$arch/$repo\n## Server = https://broken.example/$arch/$repo\n")
        assert_eq(#act_s, 1)
        assert_eq(#comm_s, 1)
        assert_eq(comm_s[1], "https://b.example/$arch/$repo")

        -- 3. Dynamic bsdtar */desc parsing & large package selection (zero hardcoded names)
        local now_ts = 1795700000
        local old_bd = now_ts - (20 * 86400)
        local new_bd = now_ts - 3600
        local fake_desc = table.concat({
            "%FILENAME%\npkg-big-64m-1-x86_64.pkg.tar.zst\n\n%NAME%\npkg-big-64m\n\n%CSIZE%\n67108864\n\n%BUILDDATE%\n" .. old_bd .. "\n",
            "%FILENAME%\npkg-fresh-64m-1-x86_64.pkg.tar.zst\n\n%NAME%\npkg-fresh-64m\n\n%CSIZE%\n67108864\n\n%BUILDDATE%\n" .. new_bd .. "\n",
            "%FILENAME%\npkg-m1-32m-1-x86_64.pkg.tar.zst\n\n%NAME%\npkg-m1\n\n%CSIZE%\n33554432\n\n%BUILDDATE%\n" .. old_bd .. "\n",
            "%FILENAME%\npkg-m2-30m-1-x86_64.pkg.tar.zst\n\n%NAME%\npkg-m2\n\n%CSIZE%\n31457280\n\n%BUILDDATE%\n" .. old_bd .. "\n",
            "%FILENAME%\npkg-m3-28m-1-x86_64.pkg.tar.zst\n\n%NAME%\npkg-m3\n\n%CSIZE%\n29360128\n\n%BUILDDATE%\n" .. old_bd .. "\n",
            "%FILENAME%\npkg-m4-26m-1-x86_64.pkg.tar.zst\n\n%NAME%\npkg-m4\n\n%CSIZE%\n27262976\n\n%BUILDDATE%\n" .. old_bd .. "\n",
        }, "\n")
        local parsed_pkgs = mirror.parse_bsdtar_desc(fake_desc)
        assert_eq(#parsed_pkgs, 6)
        local sel_pkgs = mirror.select_probe_packages(parsed_pkgs, now_ts)
        assert_eq(sel_pkgs.singles[1].name, "pkg-big-64m", "prefers stable >=7d 64 MiB pkg over 1h-old pkg")
        assert_eq(#sel_pkgs.multis, 4)

        -- 4. Extended 18-field curl probe validation (rejects exitcode=63 chunked truncation & bad SSL)
        local ext_ok = assert(mirror.parse_probe_line(
            "1\t0\t206\t0\t0.010\t0.020\t0.040\t0.060\t0.080\t0.180\t131072\t2\t1.2.3.4\thttps://m1.example/extra.db\t131072\tbytes 0-131071/8000000\t\tThu, 26 Nov 2026 14:22:10 GMT"
        ))
        local good_s = assert(mirror.validate_probe_sample(ext_ok, 131072, "\40\181\47\253xxxx", 131072, 5))
        assert_eq(good_s.total_bytes, 8000000)
        assert_true(good_s.wire_mbps > good_s.mbps, "wire_mbps excludes handshake/TTFB")

        local ext_trunc63 = assert(mirror.parse_probe_line(
            "1\t63\t200\t0\t0.000\t0.010\t0.020\t0.040\t0.050\t0.100\t131072\t2\t1.2.3.4\thttps://m1.example/extra.db\t\t\t\tThu, 26 Nov 2026 14:22:10 GMT"
        ))
        assert_true(mirror.validate_probe_sample(ext_trunc63, 131072, "\40\181\47\253xxxx", 131072, 5) == nil, "must reject exitcode=63 chunked truncation")

        local ext_timeout28 = assert(mirror.parse_probe_line(
            "1\t28\t200\t0\t0.000\t0.010\t0.020\t0.040\t0.050\t4.000\t40000000\t2\t1.2.3.4\thttps://m1.example/pkg.zst\t67108864\t\t\tThu, 26 Nov 2026 14:22:10 GMT"
        ))
        assert_true(mirror.validate_probe_sample(ext_timeout28, 40000000, "\40\181\47\253xxxx", nil, 4.0, { allow_timeout = false }) == nil)
        assert_true(mirror.validate_probe_sample(ext_timeout28, 40000000, "\40\181\47\253xxxx", nil, 4.0, { allow_timeout = true }) ~= nil, "accepts exitcode=28 on timed stream")
        local p_cfg = mirror.build_parallel_curl_config({ { id = 1, url = "https://a.example/extra.db", output = "/tmp/a" } }, { speed_time = 2.5 })
        assert_contains(p_cfg, "speed-time = 3\n", "curl speed-time must be integer")

        -- 5. Q1..Q4 quartile decomposition: discards slow-start Q1 AND detects burst-shaping!
        local steady_cps = {
            { t = 0.5, bytes = 2 * 1024 * 1024 },   -- Q1 slow-start (~33 Mbps)
            { t = 1.0, bytes = 6 * 1024 * 1024 },
            { t = 2.0, bytes = 56 * 1024 * 1024 },  -- Q2 (~419 Mbps)
            { t = 3.0, bytes = 106 * 1024 * 1024 }, -- Q3 (~419 Mbps)
            { t = 4.0, bytes = 156 * 1024 * 1024 }, -- Q4 (~419 Mbps)
        }
        local q_steady = mirror.analyze_stream_quartiles(steady_cps, 4.0, 156 * 1024 * 1024)
        assert_true(not q_steady.burst_throttled)
        assert_true(q_steady.steady_mbps > 380, "steady_mbps discards slow-start Q1")

        local burst_cps = {
            { t = 1.0, bytes = 30 * 1024 * 1024 }, -- Q1 burst (~251 Mbps)
            { t = 2.0, bytes = 34 * 1024 * 1024 }, -- Q2 throttled (~33 Mbps)
            { t = 3.0, bytes = 37 * 1024 * 1024 }, -- Q3 throttled (~25 Mbps)
            { t = 4.0, bytes = 40 * 1024 * 1024 }, -- Q4 throttled (~25 Mbps)
        }
        local q_burst = mirror.analyze_stream_quartiles(burst_cps, 4.0, 40 * 1024 * 1024)
        assert_true(q_burst.burst_throttled, "must detect CDN burst-shaping after Q1")
        assert_true(q_burst.steady_mbps < 40)

        -- 6. Future clock-skew guard + B1/B4 weighted scoring + urgent incumbent replacement
        local ts1 = assert(mirror.parse_http_date("Thu, 26 Nov 2026 14:22:10 GMT"))
        local ts2 = assert(mirror.parse_http_date("Thu, 26 Nov 2026 15:22:10 GMT"))
        local ts_future = ts2 + (365 * 86400) -- bogus +1 year clock skew
        local u_cur = "https://cur.example/$repo/os/$arch"
        local u_fast = "https://fast.example/$repo/os/$arch"
        local u_skew = "https://skew.example/$repo/os/$arch"
        local sl, meta = mirror.filter_and_shortlist({
            [u_cur]  = { wire_mbps = 80, ttfb_ms = 30, total_bytes = 8000000, modified = ts2 },
            [u_fast] = { wire_mbps = 95, ttfb_ms = 25, total_bytes = 8050000, modified = ts1 },
            [u_skew] = { wire_mbps = 90, ttfb_ms = 20, total_bytes = 8000000, modified = ts_future },
        }, { shortlist = 4, now_ts = ts2 + 60 })
        assert_eq(meta.freshest, ts2, "future clock skew must not poison freshest timestamp")
        assert_eq(#sl, 3)

        -- Urgent switch when incumbent is missing/dead from verified_deep
        local urg_res = mirror.rank_deep_results({
            [u_fast] = { { steady_mbps = 400, ttfb_ms = 40, total_bytes = 64000000 }, { steady_mbps = 420, ttfb_ms = 38, total_bytes = 64000000 } },
        }, { u_cur }, { multi_by_url = { [u_fast] = { 580, 600 } }, parallel_downloads = 8 })
        assert_true(urg_res.urgent and urg_res.changed, "dead incumbent triggers urgent switch")
        assert_eq(urg_res.ranked[1].url, u_fast)
        assert_true(urg_res.ranked[1].b4_mbps > 550)

        -- 7. Strict commit path allowlist & backup rotation
        assert_true(mirror.is_allowed_commit_path("/etc/pacman.d/mirrorlist"))
        assert_true(mirror.is_allowed_commit_path("/etc/pacman.conf"))
        for _, bad_p in ipairs({
            "/etc/pacman.d/.", "/etc/pacman.d/.hidden", "/etc/pacman.d/mirrorlist.pacnew",
            "/etc/pacman.d/mirrorlist.kaze-bak-20261127_010000", "/etc/pacman.d/gnupg",
            "/etc/pacman.d/../shadow", "/tmp/mirrorlist",
        }) do
            assert_true(not mirror.is_allowed_commit_path(bad_p), "must refuse path: " .. bad_p)
        end

        local prunable = mirror.select_prunable_backups("mirrorlist", {
            "mirrorlist.kaze-bak-20261127_010001", "mirrorlist.kaze-bak-20261127_010002",
            "mirrorlist.kaze-bak-20261127_010003", "mirrorlist.kaze-bak-20261127_010004",
            "mirrorlist.kaze-bak-20261127_010005", "mirrorlist.kaze-bak-20261127_010006",
            "mirrorlist.pacnew", "mirrorlist.bak-20261120_010000",
        }, 5)
        assert_eq(#prunable, 1)
        assert_eq(prunable[1], "mirrorlist.kaze-bak-20261127_010001", "only prunes oldest .kaze-bak-* beyond 5")

        -- 8. Pure-Lua 5-screen Omarchy TUI state machine, key parser, and responsive ANSI invariants
        assert_eq(mirror_tui.parse_key_sequence("\27[A"), "UP")
        assert_eq(mirror_tui.parse_key_sequence("\27[Z"), "SHIFT_TAB")
        assert_eq(mirror_tui.parse_key_sequence("\27"), "ESC")
        assert_eq(mirror_tui.parse_key_sequence("j"), "DOWN")

        local tstate = mirror_tui.initial_state({
            groups = { { basename = "mirrorlist", path = "/etc/pacman.d/mirrorlist", primary_host = "cur.example", server_count = 3 } },
            parallel_downloads = 5,
            backup_count = 2,
            rollback_tx = { tx_id = "20261127_010000", state = "active", files = { { path = "/etc/pacman.d/mirrorlist", backup_path = "/etc/pacman.d/mirrorlist.kaze-bak-20261127_010000" } } },
        })
        local _, eff1 = mirror_tui.reduce(tstate, { type = "key", key = "1" })
        assert_eq(tstate.screen, "progress")
        assert_eq(eff1.kind, "start_scan")
        mirror_tui.reduce(tstate, { type = "progress", pct = 50, phase = "Phase 2A", log_line = "fast.example: 420 Mbps" })
        -- Guard against malformed non-numeric pct (regression for Stage 3 table-vs-number crash)
        mirror_tui.reduce(tstate, { type = "progress", pct = { phase = "bad", pct = 80 }, phase = "Stage 3" })
        assert_eq(tstate.progress.pct, 50)
        mirror_tui.reduce(tstate, { type = "progress", pct = 86, phase = "Stage 3: ParallelDownloads=8 (round 1/3)" })
        assert_eq(tstate.progress.pct, 86)
        mirror_tui.reduce(tstate, {
            type = "scan_complete",
            raw_groups = {
                {
                    group = conf.groups[4],
                    current_servers = { u_cur },
                    deep_by_url = {
                        [u_cur]  = { { steady_mbps = 100, ttfb_ms = 30, total_bytes = 64000000 }, { steady_mbps = 100, ttfb_ms = 30, total_bytes = 64000000 } },
                        [u_fast] = { { steady_mbps = 105, ttfb_ms = 30, total_bytes = 64000000 }, { steady_mbps = 105, ttfb_ms = 30, total_bytes = 64000000 } },
                    },
                    min_samples = 2,
                },
            },
        })
        assert_eq(tstate.screen, "results")
        assert_true(not tstate.results.tabs[1].rank_res.changed, "5% gain kept before force")

        -- mirrorlist_servers_changed detects fallback/order refreshes even when #1 stays same
        local kept_render = mirror.render_mirrorlist(conf.groups[4], {
            ranked = {
                { url = u_cur, score = 100, b1_mbps = 100, ttfb_ms = 30 },
                { url = u_fast, score = 105, b1_mbps = 105, ttfb_ms = 30 },
            },
        }, { u_cur })
        assert_true(mirror.mirrorlist_servers_changed(kept_render, { u_cur }), "detects new verified fallback servers")
        assert_true(not mirror.mirrorlist_servers_changed(kept_render, { u_cur, u_fast }), "idempotent when servers & order match")

        -- auto_applied flag displays 'v 4 Applied', removes manual checkboxes/Apply prompt, and ignores redundant 'a'
        local auto_state = mirror_tui.initial_state({ groups = {} })
        mirror_tui.reduce(auto_state, {
            type = "scan_complete",
            auto_applied = true,
            auto_done = true,
            msg = "Auto-applied 2 file(s) atomically (backup saved).",
            kind = "ok",
            raw_groups = {},
            pd_result = { ok = true, current_pd = 5, recommended_pd = 8, best_mbps = 500, changed = true, results = { { pd = 8, mbps = 500 } } },
        })
        local _, auto_frame = mirror_tui.render(auto_state, { cols = 100, rows = 32 }, { no_color = true, ascii_only = true })
        assert_contains(auto_frame, "v 3 Results")
        assert_contains(auto_frame, "v 4 Applied")
        assert_contains(auto_frame, "[1:ParallelDL*]")
        assert_contains(auto_frame, "v Applied ParallelDownloads: 5 -> 8")
        assert_true(not auto_frame:find("Space Toggle", 1, true), "auto-applied results must not prompt manual Space Toggle")
        assert_true(not auto_frame:find("a Apply", 1, true), "auto-applied results must not prompt manual Apply")
        mirror_tui.reduce(auto_state, { type = "key", key = "a" })
        assert_eq(auto_state.screen, "results", "auto-applied results must not open redundant confirm screen")

        -- auto_done (already optimal) shows 'v 4 Up-to-date'; sudo_skipped shows 'o 4 Dry-run'
        local opt_state = mirror_tui.initial_state({ groups = {} })
        mirror_tui.reduce(opt_state, {
            type = "scan_complete",
            auto_applied = false,
            auto_done = true,
            msg = "Scan complete — already optimal (no file changes needed).",
            kind = "ok",
            raw_groups = {},
            pd_result = { ok = true, current_pd = 5, recommended_pd = 5, best_mbps = 500, changed = false, results = { { pd = 5, mbps = 500 } } },
        })
        local _, opt_frame = mirror_tui.render(opt_state, { cols = 100, rows = 32 }, { no_color = true, ascii_only = true })
        assert_contains(opt_frame, "v 4 Up-to-date")

        local dry_state = mirror_tui.initial_state({ groups = {} })
        mirror_tui.reduce(dry_state, {
            type = "scan_complete",
            sudo_skipped = true,
            msg = "Dry-run complete (sudo skipped — no system files modified).",
            kind = "warn",
            raw_groups = {},
            pd_result = { ok = true, current_pd = 5, recommended_pd = 8, best_mbps = 500, changed = true, results = { { pd = 8, mbps = 500 } } },
        })
        local _, dry_frame = mirror_tui.render(dry_state, { cols = 100, rows = 32 }, { no_color = true, ascii_only = true })
        assert_contains(dry_frame, "o 4 Dry-run")
        assert_contains(dry_frame, "sudo skipped")
        -- Pressing 'f' re-ranks in memory immediately without re-probing!
        mirror_tui.reduce(tstate, { type = "key", key = "f" })
        assert_true(tstate.force and tstate.results.tabs[1].rank_res.changed, "in-memory force toggle flips changed=true")
        mirror_tui.reduce(tstate, { type = "key", key = "a" })
        assert_eq(tstate.screen, "confirm")
        mirror_tui.reduce(tstate, { type = "commit_failed", err = "sudo cancelled" })
        assert_eq(tstate.screen, "confirm", "commit_failed preserves results for retry")
        assert_contains(tstate.confirm.error_msg, "sudo cancelled")

        -- Render invariant checks across all 3 breakpoints (wide, medium, compact)
        for _, dim in ipairs({ { cols = 140, rows = 42 }, { cols = 84, rows = 30 }, { cols = 64, rows = 24 } }) do
            local flushed, raw_frame = mirror_tui.render(tstate, dim, { no_color = false, ascii_only = false })
            assert_contains(flushed, "\27[?2026h\27[H")
            assert_contains(flushed, "\27[J\27[?2026l")
            assert_true(not raw_frame:find("\27%[38;") and not raw_frame:find("\27%[48;"), "16-color ANSI only (no 24-bit/256)")
            local expected_w = nil
            for line in raw_frame:gmatch("[^\n]+") do
                local w = mirror_tui.display_width(line)
                if not expected_w then expected_w = w else assert_eq(w, expected_w, "exact UTF-8 box width alignment") end
            end
            local _, plain_ascii = mirror_tui.render(tstate, dim, { no_color = true, ascii_only = true })
            assert_true(not plain_ascii:find("\27%["), "NO_COLOR has zero ANSI escapes")
            assert_true(not plain_ascii:find("[\128-\255]"), "ASCII fallback has zero non-ASCII bytes")
        end

        -- 9. End-to-end CLI tests in isolated --test-root: atomic commit, symlink/db.lck refusal, rollback & double-rollback, --menu, --tui-window
        local tmp = make_tmp_dir()
        local ok_cli, err_cli = pcall(function()
            local root = tmp .. "/root"
            local pd = root .. "/etc/pacman.d"
            local vdb = root .. "/var/lib/pacman"
            fs.mkdir_p(pd)
            fs.mkdir_p(vdb)
            local ml_path = pd .. "/mirrorlist"
            local pc_path = root .. "/etc/pacman.conf"
            fs.write_atomic(ml_path, "Server = https://cur.example/$repo/os/$arch\n")
            fs.write_atomic(pc_path, "[options]\nArchitecture = x86_64\nParallelDownloads = 5\n[extra]\nInclude = " .. ml_path .. "\n")

            local bin = q(repo_dir .. "/bin/kaze-mirror")
            local rendered = mirror.render_mirrorlist(conf.groups[4], urg_res, { u_cur })
            local plan_path = tmp .. "/plan.json"
            fs.write_atomic(plan_path, json.encode({
                files = {
                    { path = ml_path, kind = "mirrorlist", content = rendered },
                    { path = pc_path, kind = "pacman_conf", parallel_downloads = 10 },
                },
            }))

            -- Refuse when db.lck exists
            fs.write_atomic(vdb .. "/db.lck", "")
            local lck_out, lck_ok = read_all(bin .. " --commit-plan " .. q(plan_path) .. " --test-root " .. q(root) .. " 2>&1")
            assert_true(not lck_ok, "must refuse commit while db.lck exists")
            assert_contains(lck_out, "db.lck")
            os.remove(vdb .. "/db.lck")

            -- Atomic commit succeeds for mirrorlist + least-privilege pacman_conf
            local c_out, c_ok = read_all(bin .. " --commit-plan " .. q(plan_path) .. " --test-root " .. q(root) .. " 2>&1")
            assert_true(c_ok, "--commit-plan failed: " .. c_out)
            assert_contains(assert(fs.read_file(ml_path)), "Server = " .. u_fast)
            assert_contains(assert(fs.read_file(pc_path)), "ParallelDownloads = 10\n")
            assert_true(fs.file_exists(root .. "/var/lib/kaze-mirror/last-commit.json"), "writes transactional manifest")
            local mdir_mode = read_all("LC_ALL=C stat -c '%a' -- " .. q(root .. "/var/lib/kaze-mirror") .. " 2>/dev/null"):gsub("%s+", "")
            assert_eq(mdir_mode, "755", "manifest directory must remain readable by unprivileged user for rollback detection")

            -- Refuse symlink target
            local sym_path = pd .. "/sym-mirrorlist"
            os.execute("ln -s /etc/hosts " .. q(sym_path))
            local sym_plan = tmp .. "/sym-plan.json"
            fs.write_atomic(sym_plan, json.encode({ files = { { path = sym_path, kind = "mirrorlist", content = rendered } } }))
            local sym_out, sym_ok = read_all(bin .. " --commit-plan " .. q(sym_plan) .. " --test-root " .. q(root) .. " 2>&1")
            assert_true(not sym_ok, "must refuse symlink target")
            assert_contains(sym_out, "symlink")

            -- Transactional rollback restores both files & refuses double-rollback
            local rb_out, rb_ok = read_all(bin .. " --commit-rollback --test-root " .. q(root) .. " 2>&1")
            assert_true(rb_ok, "--commit-rollback failed: " .. rb_out)
            assert_eq(fs.read_file(ml_path), "Server = https://cur.example/$repo/os/$arch\n")
            assert_contains(assert(fs.read_file(pc_path)), "ParallelDownloads = 5\n")

            local rb2_out, rb2_ok = read_all(bin .. " --commit-rollback --test-root " .. q(root) .. " 2>&1")
            assert_true(not rb2_ok, "double-rollback must be refused")
            assert_contains(rb2_out, "double-rollback")

            -- Stubbed --menu and --tui-window integration
            local stub_bin = tmp .. "/stubs"
            fs.mkdir_p(stub_bin)
            link_host_bin(stub_bin, "lua")
            write_stub(stub_bin, "noctalia", [[
if [ "$1" = "dmenu" ]; then
    cat > "$HOME/mirror-menu.txt"
    exit 0
fi
exit 0
]])
            write_stub(stub_bin, "hyprctl", [[
if [ "$1" = "-j" ] && [ "$2" = "clients" ]; then printf '[]\n';
elif [ "$1" = "-j" ] && [ "$2" = "activewindow" ]; then printf '{}\n'; fi
]])
            write_stub(stub_bin, "footclient", [[printf '%s\n' "$@" > "$HOME/mirror-tui-args"]])
            local senv = string.format("HOME=%s XDG_RUNTIME_DIR=%s HYPRLAND_INSTANCE_SIGNATURE=sig-1 PATH=%s:$PATH",
                q(tmp), q(tmp .. "/rt"), q(stub_bin))
            fs.mkdir_p(tmp .. "/rt")
            local _, m_ok = read_all(senv .. " " .. bin .. " --menu --pacman-conf " .. q(pc_path) .. " 2>&1")
            assert_true(m_ok, "--menu Esc cancel exits 0")
            assert_contains(assert(fs.read_file(tmp .. "/mirror-menu.txt")), "Open Mirror Optimizer (TUI)")

            local _, tw_ok = read_all(senv .. " " .. bin .. " --tui-window --auto-run fast-dry --pacman-conf " .. q(pc_path) .. " 2>&1")
            assert_true(tw_ok, "--tui-window launch exits 0")
            local tw_args = assert(fs.read_file(tmp .. "/mirror-tui-args"))
            assert_contains(tw_args, "-a\nkaze-mirror-tui\n")
            assert_contains(tw_args, "--tui\n--auto-run\nfast-dry\n")
        end)
        rm_rf(tmp)
        if not ok_cli then error(err_cli, 0) end
    end)

    test("install-lib.sh: GPU detection across 5 sysfs fixtures and safe hybrid user.lua seeding", function()
        local tmp = make_tmp_dir()
        local ok_test, err_test = pcall(function()
            local lib = q(repo_dir .. "/scripts/install-lib.sh")
            local hypr_user = require("kaze.hypr_user")

            local function run_gpu_probe(drm_dir)
                local cmd = string.format(
                    "KAZE_SYS_DRM_DIR=%s bash -c %s 2>&1",
                    q(drm_dir),
                    q("source " .. lib .. " && kaze_detect_gpu && printf 'MODE=%s\\nLABEL=%s\\nIGPU=%s\\nNVIDIA=%s\\n' \"$GPU_MODE\" \"$GPU_LABEL\" \"$GPU_IGPU_CARD\" \"$GPU_NVIDIA_CARD\"")
                )
                local out, ok = read_all(cmd)
                assert_true(ok, "kaze_detect_gpu failed: " .. out)
                return out
            end

            -- 1. Hybrid Laptop: Intel iGPU (card1 + eDP-1) + NVIDIA dGPU (card0)
            local drm_hybrid = tmp .. "/drm-hybrid"
            fs.mkdir_p(drm_hybrid .. "/card0/device")
            fs.mkdir_p(drm_hybrid .. "/card1/device")
            fs.mkdir_p(drm_hybrid .. "/card1-eDP-1")
            fs.write_atomic(drm_hybrid .. "/card0/device/vendor", "0x10de\n")
            fs.write_atomic(drm_hybrid .. "/card1/device/vendor", "0x8086\n")
            fs.write_atomic(drm_hybrid .. "/card1-eDP-1/status", "connected\n")
            local hyb_out = run_gpu_probe(drm_hybrid)
            assert_contains(hyb_out, "MODE=hybrid-laptop\n")
            assert_contains(hyb_out, "LABEL=Hybrid Intel+NVIDIA\n")
            assert_contains(hyb_out, "IGPU=/dev/dri/card1\n")
            assert_contains(hyb_out, "NVIDIA=/dev/dri/card0\n")

            -- 2. Multi-GPU Desktop: AMD iGPU (card0 + DP-1, NO eDP) + NVIDIA (card1)
            local drm_desk = tmp .. "/drm-desk"
            fs.mkdir_p(drm_desk .. "/card0/device")
            fs.mkdir_p(drm_desk .. "/card0-DP-1")
            fs.mkdir_p(drm_desk .. "/card1/device")
            fs.write_atomic(drm_desk .. "/card0/device/vendor", "0x1002\n")
            fs.write_atomic(drm_desk .. "/card1/device/vendor", "0x10de\n")
            local desk_out = run_gpu_probe(drm_desk)
            assert_contains(desk_out, "MODE=multi-gpu-desktop\n")
            assert_contains(desk_out, "LABEL=Desktop AMD+NVIDIA\n")

            -- 3. Single NVIDIA
            local drm_nv = tmp .. "/drm-nv"
            fs.mkdir_p(drm_nv .. "/card0/device")
            fs.write_atomic(drm_nv .. "/card0/device/vendor", "0x10de\n")
            local nv_out = run_gpu_probe(drm_nv)
            assert_contains(nv_out, "MODE=single-nvidia\n")
            assert_contains(nv_out, "LABEL=NVIDIA\n")

            -- 4. Single Intel
            local drm_intel = tmp .. "/drm-intel"
            fs.mkdir_p(drm_intel .. "/card0/device")
            fs.mkdir_p(drm_intel .. "/card0-eDP-1")
            fs.write_atomic(drm_intel .. "/card0/device/vendor", "0x8086\n")
            local int_out = run_gpu_probe(drm_intel)
            assert_contains(int_out, "MODE=single-igpu\n")
            assert_contains(int_out, "LABEL=Intel\n")

            -- 5. VirtIO VM
            local drm_vm = tmp .. "/drm-vm"
            fs.mkdir_p(drm_vm .. "/card0/device")
            fs.write_atomic(drm_vm .. "/card0/device/vendor", "0x1af4\n")
            local vm_out = run_gpu_probe(drm_vm)
            assert_contains(vm_out, "MODE=vm\n")
            assert_contains(vm_out, "LABEL=VM (VirtIO)\n")

            -- End-to-end hybrid GPU seeding via install.sh --skip-packages --yes
            local home, cfg, data, cache, state, runtime = tmp .. "/h1", tmp .. "/c1", tmp .. "/d1", tmp .. "/ca1", tmp .. "/st1", tmp .. "/rt1"
            fs.mkdir_p(home)
            fs.mkdir_p(runtime)
            local base_env = string.format(
                "HOME=%s XDG_CONFIG_HOME=%s XDG_DATA_HOME=%s XDG_CACHE_HOME=%s XDG_STATE_HOME=%s XDG_RUNTIME_DIR=%s HYPRLAND_INSTANCE_SIGNATURE='' WAYLAND_DISPLAY=''",
                q(home), q(cfg), q(data), q(cache), q(state), q(runtime)
            )
            local installer = q(repo_dir .. "/scripts/install.sh")

            -- Desktop AMD+NVIDIA must NOT seed drm_devices
            local desk_ins, desk_ok = read_all(base_env .. " KAZE_SYS_DRM_DIR=" .. q(drm_desk) .. " " .. installer .. " --profile minimal --skip-packages --yes 2>&1")
            assert_true(desk_ok, "desktop install failed: " .. desk_ins)
            local desk_ulua = assert(fs.read_file(cfg .. "/hypr/user.lua"))
            assert_true(not desk_ulua:match("\n%s*drm_devices%s*="), "desktop AMD+NVIDIA must not uncomment drm_devices")
            local rb_desk = assert(fs.read_file(cfg .. "/kaze/last-backup")):gsub("\n$", "")
            assert_true(os.execute(base_env .. " " .. q(rb_desk .. "/rollback.sh") .. " --yes >/dev/null 2>&1"))
            os.remove(cfg .. "/hypr/user.lua")

            -- Hybrid Laptop + --no-hybrid-gpu must NOT seed drm_devices
            local noh_out, noh_ok = read_all(base_env .. " KAZE_SYS_DRM_DIR=" .. q(drm_hybrid) .. " " .. installer .. " --profile minimal --skip-packages --no-hybrid-gpu --yes 2>&1")
            assert_true(noh_ok, "--no-hybrid-gpu failed: " .. noh_out)
            local noh_ulua = assert(fs.read_file(cfg .. "/hypr/user.lua"))
            assert_true(not noh_ulua:match("\n%s*drm_devices%s*="), "--no-hybrid-gpu must keep drm_devices commented")
            local rb_noh = assert(fs.read_file(cfg .. "/kaze/last-backup")):gsub("\n$", "")
            assert_true(os.execute(base_env .. " " .. q(rb_noh .. "/rollback.sh") .. " --yes >/dev/null 2>&1"))
            os.remove(cfg .. "/hypr/user.lua")

            -- Hybrid Laptop with absent user.lua seeds drm_devices + prefer_mesa_egl cleanly and survives rollback
            local hyb_ins, hyb_ins_ok = read_all(base_env .. " KAZE_SYS_DRM_DIR=" .. q(drm_hybrid) .. " " .. installer .. " --profile minimal --skip-packages --yes 2>&1")
            assert_true(hyb_ins_ok, "hybrid install failed: " .. hyb_ins)
            local seeded_ulua = assert(fs.read_file(cfg .. "/hypr/user.lua"))
            assert_contains(seeded_ulua, 'drm_devices = "/dev/dri/card1",')
            assert_contains(seeded_ulua, "prefer_mesa_egl = true,")
            assert_true(os.execute("luac -p -- " .. q(cfg .. "/hypr/user.lua") .. " >/dev/null 2>&1"), "seeded user.lua must pass luac -p")
            local loaded_cfg = hypr_user.load({ home = home, user_path = cfg .. "/hypr/user.lua", style_path = cfg .. "/hypr/kaze-style.lua", profile_path = cfg .. "/kaze/profile" })
            assert_eq(loaded_cfg.drm_devices, "/dev/dri/card1")
            assert_eq(loaded_cfg.prefer_mesa_egl, true)

            -- Rollback preserves seeded user.lua
            local rb_hyb = assert(fs.read_file(cfg .. "/kaze/last-backup")):gsub("\n$", "")
            assert_true(os.execute(base_env .. " " .. q(rb_hyb .. "/rollback.sh") .. " --yes >/dev/null 2>&1"))
            assert_eq(fs.read_file(cfg .. "/hypr/user.lua"), seeded_ulua)

            -- Pre-existing user.lua must NEVER be overwritten on hybrid laptop
            fs.write_atomic(cfg .. "/hypr/user.lua", "return { browser = 'vivaldi' } -- keep-me\n")
            local keep_out, keep_ok = read_all(base_env .. " KAZE_SYS_DRM_DIR=" .. q(drm_hybrid) .. " " .. installer .. " --profile minimal --skip-packages --yes 2>&1")
            assert_true(keep_ok, "pre-existing user.lua install failed: " .. keep_out)
            assert_eq(fs.read_file(cfg .. "/hypr/user.lua"), "return { browser = 'vivaldi' } -- keep-me\n")
        end)
        rm_rf(tmp)
        if not ok_test then error(err_test, 0) end
    end)

    test("install.sh: conflict detection, system setup, DM (ly/greetd), opt-in AUR, ANSI-clean logging & kaze-doctor", function()
        local tmp = make_tmp_dir()
        local ok_test, err_test = pcall(function()
            local stub_bin = tmp .. "/bin"
            local home, cfg, data, cache, state, runtime = tmp .. "/home", tmp .. "/cfg", tmp .. "/data", tmp .. "/cache", tmp .. "/state", tmp .. "/rt"
            local etc_greetd = tmp .. "/etc/greetd"
            for _, d in ipairs({ stub_bin, home, cfg, data, cache, state, runtime, etc_greetd }) do
                fs.mkdir_p(d)
            end
            fs.write_atomic(tmp .. "/arch-release", "Arch Linux\n")
            fs.write_atomic(etc_greetd .. "/config.toml", "# previous greetd\n")

            -- Create a real UNIX socket at $XDG_RUNTIME_DIR/bus so [ -S "$runtime/bus" ] succeeds
            local sock_ok = os.execute("python3 -c " .. q("import socket; s=socket.socket(socket.AF_UNIX); s.bind('" .. runtime .. "/bus')") .. " >/dev/null 2>&1")
            assert_true(sock_ok, "create mock dbus unix socket")

            for _, b in ipairs({ "bash", "sh", "env", "lua", "luac", "realpath", "readlink", "find", "ln", "ls", "wc", "mktemp", "mkfifo", "tee", "sed", "grep", "cat", "cp", "mv", "rm", "mkdir", "install", "date", "sleep", "kill", "tr", "head", "paste", "cut", "basename", "dirname", "chmod", "touch" }) do
                link_host_bin(stub_bin, b)
            end

            write_stub(stub_bin, "sudo", [[
if [ "${1:-}" = "-v" ] || { [ "${1:-}" = "-n" ] && [ "${2:-}" = "-v" ]; } || { [ "${1:-}" = "-n" ] && [ "${2:-}" = "true" ]; }; then
    exit 0
fi
printf '%s\n' "$*" >> "$HOME/sudo-calls"
exec "$@"
]])
            write_stub(stub_bin, "pacman", [[
if [ "${1:-}" = "-Qq" ]; then
    printf '%s\n' "${TEST_PACMAN_QQ:-}"
    exit 0
fi
printf 'pacman %s\n' "$*" >> "$HOME/pacman-calls"
exit 0
]])
            write_stub(stub_bin, "systemctl", [[
printf 'systemctl %s\n' "$*" >> "$HOME/systemctl-calls"
case "$*" in
  'is-enabled --quiet systemd-networkd.service'|'is-active --quiet systemd-networkd.service')
    [ "${TEST_OTHER_NET:-}" = "systemd-networkd" ] && exit 0 || exit 1 ;;
  'is-enabled --quiet iwd.service'|'is-active --quiet iwd.service')
    [ "${TEST_OTHER_NET:-}" = "iwd" ] && exit 0 || exit 1 ;;
  'is-enabled --quiet sddm.service'|'is-active --quiet sddm.service')
    [ "${TEST_EXISTING_DM:-}" = "sddm" ] && exit 0 || exit 1 ;;
  'is-enabled --quiet getty@tty1.service')
    exit 0 ;;
  'is-enabled --quiet '*)
    exit 1 ;;
  'is-active --quiet '*)
    exit 1 ;;
  'list-unit-files '*)
    exit 0 ;;
  'list-units '*)
    exit 0 ;;
  'cat NetworkManager.service'|'cat bluetooth.service'|'cat ly@.service'|'cat greetd.service')
    exit 0 ;;
  'cat '*)
    exit 1 ;;
  *)
    exit 0 ;;
esac
]])
            write_stub(stub_bin, "getent", [[
if [ "${1:-}" = "group" ] && [ "${2:-}" = "video" ]; then
    printf 'video:x:985:\n'
    exit 0
fi
if [ "${1:-}" = "passwd" ]; then
    printf '%s:x:1000:1000::%s:/bin/bash\n' "$2" "$HOME"
    exit 0
fi
exit 2
]])
            write_stub(stub_bin, "id", [[
case "${1:-}" in
  -u)  printf '1000\n' ;;
  -un) printf 'tester\n' ;;
  -nG) printf 'tester wheel\n' ;;
  *)   /usr/bin/id "$@" ;;
esac
]])
            write_stub(stub_bin, "usermod", [[printf 'usermod %s\n' "$*" >> "$HOME/usermod-calls"]])
            write_stub(stub_bin, "fc-cache", [[printf 'fc-cache %s\n' "$*" >> "$HOME/fccache-calls"]])
            write_stub(stub_bin, "chsh", [[printf 'chsh %s\n' "$*" >> "$HOME/chsh-calls"]])
            write_stub(stub_bin, "zsh", [[exit 0]])
            write_stub(stub_bin, "git", [[
if [ "${1:-}" = "clone" ]; then
    dest=""
    for a in "$@"; do
        dest="$a"
    done
    mkdir -p "$dest"
    printf 'clone %s\n' "$*" >> "$HOME/git-calls"
    exit 0
fi
exit 0
]])
            write_stub(stub_bin, "makepkg", [[printf 'makepkg %s\n' "$*" >> "$HOME/makepkg-calls"]])

            for _, b in ipairs({ "hyprland", "hyprctl", "noctalia", "notify-send", "foot", "footclient", "wl-copy", "wl-paste", "wpctl", "brightnessctl", "playerctl", "busctl", "flock" }) do
                write_stub(stub_bin, b, "exit 0")
            end

            local installer = q(repo_dir .. "/scripts/install.sh")
            local env = string.format(
                "HOME=%s USER=tester XDG_CONFIG_HOME=%s XDG_DATA_HOME=%s XDG_CACHE_HOME=%s XDG_STATE_HOME=%s XDG_RUNTIME_DIR=%s LANG=en_US.UTF-8 LC_ALL='' HYPRLAND_INSTANCE_SIGNATURE='' WAYLAND_DISPLAY='' KAZE_ARCH_RELEASE_FILE=%s KAZE_GREETD_CONFIG=%s KAZE_NOCTALIA_GREETER_DIR=%s KAZE_NOCTALIA_GREETER_SETUP=%s KAZE_SYSTEMD_ETC_DIR=%s PATH=%s",
                q(home), q(cfg), q(data), q(cache), q(state), q(runtime), q(tmp .. "/arch-release"), q(etc_greetd .. "/config.toml"), q(tmp .. "/var/lib/noctalia-greeter"), q(tmp .. "/no-greeter-setup.sh"), q(tmp .. "/etc/systemd/system"), q(stub_bin)
            )

            -- 1. Hard conflict in --yes mode without --replace-conflicts MUST abort before pacman -Syu
            local conf_fail_out, conf_fail_ok = read_all(env .. " TEST_PACMAN_QQ='pulseaudio\nxdg-desktop-portal-wlr\ndunst' " .. installer .. " --profile minimal --yes 2>&1")
            assert_true(not conf_fail_ok, "hard conflict without --replace-conflicts must fail in --yes mode")
            assert_contains(conf_fail_out, "--replace-conflicts")
            assert_true(not fs.file_exists(home .. "/pacman-calls"), "aborted conflict check must not run pacman -Syu")

            -- 2. --yes --replace-conflicts + --dm ly + --aur yay-bin runs full pipeline, removes ONLY hard conflict, logs cleanly
            local ok_out, ok_st = read_all(env .. " TEST_PACMAN_QQ='pulseaudio\nxdg-desktop-portal-wlr\ndunst' " .. installer .. " --profile minimal --dm ly --aur yay-bin --replace-conflicts --yes 2>&1")
            assert_true(ok_st, "full stubbed install failed:\n" .. ok_out)

            local pac_log = assert(fs.read_file(home .. "/pacman-calls"))
            local p_rdd = assert(pac_log:find("pacman -Rdd --noconfirm pulseaudio\n", 1, true), "must remove hard conflict pulseaudio")
            local p_syu = assert(pac_log:find("pacman -Syu --needed --noconfirm", 1, true), "must run pacman -Syu")
            assert_true(p_rdd < p_syu, "pacman -Rdd must run before pacman -Syu")
            assert_true(not pac_log:find("xdg-desktop-portal-wlr", 1, true), "must never remove soft conflict portal-wlr")
            assert_true(not pac_log:find("dunst", 1, true), "must never remove soft conflict dunst")
            assert_contains(pac_log, "ly base-devel git")

            local sys_log = assert(fs.read_file(home .. "/systemctl-calls"))
            assert_contains(sys_log, "systemctl enable NetworkManager.service\n")
            assert_contains(sys_log, "systemctl enable bluetooth.service\n")
            assert_contains(sys_log, "systemctl --user enable pipewire.socket pipewire-pulse.socket wireplumber.service\n")
            assert_contains(sys_log, "systemctl disable getty@tty1.service\n")
            assert_contains(sys_log, "systemctl enable ly@tty1.service\n")

            assert_contains(assert(fs.read_file(home .. "/usermod-calls")), "usermod -aG video tester\n")
            assert_contains(assert(fs.read_file(home .. "/fccache-calls")), "fc-cache -f\n")
            assert_contains(assert(fs.read_file(home .. "/chsh-calls")), "chsh -s " .. stub_bin .. "/zsh tester\n")
            assert_contains(assert(fs.read_file(home .. "/git-calls")), "https://aur.archlinux.org/yay-bin.git")
            assert_contains(assert(fs.read_file(home .. "/makepkg-calls")), "makepkg -si --needed --noconfirm\n")

            -- Log file exists, is ANSI-free, and includes kaze-doctor --offline output
            local log_path = assert(fs.capture("ls -1 " .. q(state .. "/kaze") .. "/install-*.log 2>/dev/null | head -n1")):gsub("\n$", "")
            assert_true(log_path ~= "", "install log file must be created")
            local log_txt = assert(fs.read_file(log_path))
            assert_true(not log_txt:find("\27%["), "install log must have zero ANSI CSI escapes")
            assert_contains(log_txt, "Doctor summary:")
            assert_contains(log_txt, "sudo pacman -Rns xdg-desktop-portal-wlr dunst")

            -- 3. Existing network stack (systemd-networkd) skips NetworkManager.service; existing DM (sddm) refuses overwrite
            fs.write_atomic(home .. "/systemctl-calls", "")
            local keep_out, keep_ok = read_all(env .. " TEST_OTHER_NET=systemd-networkd TEST_EXISTING_DM=sddm " .. installer .. " --profile minimal --dm greetd --skip-packages --system-setup --no-log --yes 2>&1")
            assert_true(keep_ok, "skip-NM & refuse-DM install failed:\n" .. keep_out)
            local sys_keep = assert(fs.read_file(home .. "/systemctl-calls"))
            assert_true(not sys_keep:find("enable NetworkManager.service", 1, true), "must skip NetworkManager when systemd-networkd is active")
            assert_true(not sys_keep:find("enable greetd.service", 1, true), "must refuse to overwrite active sddm.service")
            assert_contains(keep_out, "Existing Display Manager detected (sddm.service)")

            -- 4. --dm greetd with no existing DM backs up /etc/greetd/config.toml and writes new config
            fs.write_atomic(home .. "/systemctl-calls", "")
            local gr_out, gr_ok = read_all(env .. " " .. installer .. " --profile minimal --dm greetd --skip-packages --no-log --yes 2>&1")
            assert_true(gr_ok, "--dm greetd install failed:\n" .. gr_out)
            local gr_cfg = assert(fs.read_file(etc_greetd .. "/config.toml"))
            assert_contains(gr_cfg, "tuigreet --time --remember --remember-session --asterisks --sessions /usr/share/wayland-sessions --cmd start-hyprland")
            assert_contains(gr_cfg, 'user = "greeter"')
            assert_contains(assert(fs.read_file(home .. "/systemctl-calls")), "systemctl enable greetd.service\n")
            local bak_cnt = assert(fs.capture("ls -1 " .. q(etc_greetd) .. "/config.toml.kaze-bak-* 2>/dev/null | wc -l")):gsub("%s+", "")
            assert_eq(bak_cnt, "1", "greetd backup file must be created")
        end)
        rm_rf(tmp)
        if not ok_test then error(err_test, 0) end
    end)

    test("bootstrap.sh: --dry-run flag forwarding and target directory safety validation", function()
        local tmp = make_tmp_dir()
        local ok_test, err_test = pcall(function()
            local boot = q(repo_dir .. "/scripts/bootstrap.sh")
            local non_git = tmp .. "/existing-non-git"
            fs.mkdir_p(non_git)
            fs.write_atomic(non_git .. "/keep.txt", "important\n")

            -- Refuses non-git directory
            local ng_out, ng_ok = read_all(boot .. " --dry-run --dir " .. q(non_git) .. " 2>&1")
            assert_true(not ng_ok, "bootstrap.sh must refuse existing non-git directory")
            assert_contains(ng_out, "not a kaze-dots git repository")

            -- Refuses dirty kaze-dots git checkout
            local dirty_dir = tmp .. "/dirty-repo"
            assert_true(os.execute("git init -q " .. q(dirty_dir) .. " && git -C " .. q(dirty_dir) .. " remote add origin https://github.com/minkhoaa/kaze-dots.git"))
            fs.write_atomic(dirty_dir .. "/untracked.txt", "dirty\n")
            local dirty_out, dirty_ok = read_all(boot .. " --dry-run --dir " .. q(dirty_dir) .. " 2>&1")
            assert_true(not dirty_ok, "bootstrap.sh must refuse dirty git checkout")
            assert_contains(dirty_out, "uncommitted local changes")

            -- Clean --dry-run forwards flags to install.sh
            local target = tmp .. "/fresh-kaze"
            local dry_out, dry_ok = read_all(boot .. " --dir " .. q(target) .. " --branch dev --repo https://example.com/kaze-dots.git --dry-run --profile full --dm ly 2>&1")
            assert_true(dry_ok, "bootstrap.sh --dry-run failed: " .. dry_out)
            assert_contains(dry_out, "Repo:       https://example.com/kaze-dots.git\n")
            assert_contains(dry_out, "Branch:     dev\n")
            assert_contains(dry_out, "Target dir: " .. target .. "\n")
            assert_contains(dry_out, "git clone --branch dev https://example.com/kaze-dots.git " .. target)
            assert_contains(dry_out, target .. "/scripts/install.sh --dry-run --profile full --dm ly")
            assert_true(not fs.file_exists(target), "bootstrap.sh --dry-run must not create target dir")
        end)
        rm_rf(tmp)
        if not ok_test then error(err_test, 0) end
    end)
end

return run_suite
