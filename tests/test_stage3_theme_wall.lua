#!/usr/bin/env lua

local function build_suite(test, assert_eq, assert_true, assert_contains, repo_dir)
    local color = require("kaze.color")
    local config = require("kaze.config")
    local emit_fnott = require("kaze.emit_fnott")
    local emit_foot = require("kaze.emit_foot")
    local emit_fuzzel = require("kaze.emit_fuzzel")
    local emit_hyprlock = require("kaze.emit_hyprlock")
    local emit_waybar = require("kaze.emit_waybar")
    local fs = require("kaze.fs")
    local layouts = require("kaze.layouts")
    local state = require("kaze.state")
    local themes = require("kaze.themes")

    local PNG_FIXTURE = "\137PNG\r\n\26\n\0\0\0\rIHDRfixture"
    local JPG_FIXTURE = "\255\216\255\224\0\16JFIFfixture"
    local WEBP_FIXTURE = "RIFF\36\0\0\0WEBPfixture"

    local function make_tmp_dir()
        local d = string.format("/tmp/kaze-stage3-test-%d-%d", os.time(), math.random(100000, 999999))
        fs.mkdir_p(d)
        return d
    end

    local function rm_rf(dir)
        os.execute("rm -rf -- " .. fs.shell_quote(dir))
    end

    local function with_stubs(fn)
        local tmp = make_tmp_dir()
        fs.mkdir_p(tmp .. "/bin")
        fs.mkdir_p(tmp .. "/runtime")
        local env = string.format(
            "env -u HYPRLAND_INSTANCE_SIGNATURE -u WAYLAND_DISPLAY -u GSETTINGS_BACKEND"
                .. " HOME=%s XDG_RUNTIME_DIR=%s XDG_CONFIG_HOME=%s XDG_DATA_HOME=%s XDG_CACHE_HOME=%s PATH=%s:$PATH",
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
        local function run(cli, args, vars)
            return env .. " " .. (vars or "") .. " " .. fs.shell_quote(repo_dir .. "/bin/" .. cli) .. " " .. (args or "")
        end
        local ok, err = pcall(fn, tmp, stub, run)
        rm_rf(tmp)
        if not ok then
            error(err, 0)
        end
    end

    local function assert_palette_wcag(pal, label)
        themes.validate(pal)
        local l_bg = color.relative_luminance(pal.bg)
        local l_alt = color.relative_luminance(pal.bg_alt)
        local l_surf = color.relative_luminance(pal.surface)
        assert_true(l_bg < l_alt, label .. ": bg must be darker than bg_alt")
        assert_true(l_alt < l_surf, label .. ": bg_alt must be darker than surface")
        assert_true(l_surf < 0.12, label .. ": surface must remain dark-first")

        for _, bg_key in ipairs({ "bg", "bg_alt" }) do
            local bg_hex = pal[bg_key]
            assert_true(color.contrast_ratio(pal.fg, bg_hex) >= 4.5,
                label .. ": fg vs " .. bg_key .. " must be >= 4.5")
            assert_true(color.contrast_ratio(pal.fg_muted, bg_hex) >= 4.5,
                label .. ": fg_muted vs " .. bg_key .. " must be >= 4.5")
            for _, tok in ipairs({ "border", "ok", "warn", "danger" }) do
                assert_true(color.contrast_ratio(pal[tok], bg_hex) >= 3.0,
                    label .. ": " .. tok .. " vs " .. bg_key .. " must be >= 3.0")
            end
        end

        assert_true(color.contrast_ratio(pal.accent_fg, pal.accent) >= 4.5,
            label .. ": accent_fg vs accent must be >= 4.5")
    end

    test("stage3 color: WCAG 2.1 luminance and contrast clamping hold on pastel, mid-gray, and pitch-black inputs", function()
        assert_eq(color.relative_luminance("000000"), 0.0, "black luminance")
        assert_true(math.abs(color.relative_luminance("ffffff") - 1.0) < 1e-9, "white luminance")
        assert_true(math.abs(color.contrast_ratio("ffffff", "000000") - 21.0) < 1e-9, "black/white contrast")
        assert_eq(color.contrast_ratio("89b4fa", "89b4fa"), 1.0, "identical color contrast")

        -- Ultra-pastel light inputs
        local pastel = color.build_dynamic_palette({
            bg = "#faf8ff",
            bg_alt = "#f4f0ff",
            surface = "#ece6fa",
            border = "#f2eefc",
            fg = "#ffffff",
            fg_muted = "#f7f4ff",
            accent = "#ffd8e4",
            accent_fg = "#ffffff",
            ok = "#eefbee",
            warn = "#fffde8",
            danger = "#ffecee",
        })
        assert_palette_wcag(pastel, "ultra-pastel")

        -- Mid-gray inputs across every token
        local mid_gray = color.build_dynamic_palette({
            bg = "808080",
            bg_alt = "808080",
            surface = "808080",
            border = "808080",
            fg = "808080",
            fg_muted = "767676",
            accent = "767676",
            accent_fg = "767676",
            ok = "808080",
            warn = "808080",
            danger = "808080",
        })
        assert_palette_wcag(mid_gray, "mid-gray")

        -- Pitch-black inputs across every token
        local pitch_black = color.build_dynamic_palette({
            bg = "000000",
            bg_alt = "000000",
            surface = "000000",
            border = "000000",
            fg = "000000",
            fg_muted = "000000",
            accent = "000000",
            accent_fg = "000000",
            ok = "000000",
            warn = "000000",
            danger = "000000",
        })
        assert_palette_wcag(pitch_black, "pitch-black")

        -- Matugen nested JSON shapes (v2 colors.dark.<role> and v3/v4 colors.<role>.dark.color)
        local v4_json = [[{
            "colors": {
                "background": { "dark": { "color": "#101418" }, "light": { "color": "#f8f9ff" } },
                "surface_container_low": { "dark": { "color": "#181c20" } },
                "surface_container_high": { "dark": { "color": "#272a2f" } },
                "outline_variant": { "dark": { "color": "#41474d" } },
                "on_surface": { "dark": { "color": "#e0e2e8" } },
                "on_surface_variant": { "dark": { "color": "#c1c7ce" } },
                "primary": { "dark": { "color": "#93cdf6" } },
                "on_primary": { "dark": { "color": "#00344c" } },
                "tertiary": { "dark": { "color": "#cac1e9" } },
                "secondary": { "dark": { "color": "#b8c8d9" } },
                "error": { "dark": { "color": "#ffb4ab" } }
            }
        }]]
        local from_v4 = color.build_dynamic_palette(v4_json)
        assert_palette_wcag(from_v4, "matugen-v4-json")

        local v2_json = [[{
            "colors": {
                "dark": {
                    "background": "#141218",
                    "surface_container": "#211f26",
                    "surface_container_high": "#2b2930",
                    "outline": "#938f99",
                    "on_surface": "#e6e0e9",
                    "on_surface_variant": "#cac4d0",
                    "primary": "#d0bcff",
                    "on_primary": "#381e72",
                    "error": "#f2b8b5"
                }
            }
        }]]
        local from_v2 = color.build_dynamic_palette(v2_json)
        assert_palette_wcag(from_v2, "matugen-v2-json")
    end)

    test("stage3 themes: dynamic theme stays pure, preserves 4 built-in presets, and emits cleanly", function()
        assert_eq(#themes.list(), 4, "themes.list() must keep 4 built-in presets")
        assert_eq(#themes.list_selectable(false), 4, "selectable without matugen")
        assert_eq(#themes.list_selectable(true), 5, "selectable with matugen")
        assert_eq(themes.list_selectable(true)[5], "dynamic", "5th selectable entry")

        for _, rel in ipairs({ "/lua/kaze/color.lua", "/lua/kaze/themes.lua" }) do
            local src = assert(fs.read_file(repo_dir .. rel))
            assert_true(not src:find("os%.execute"), rel .. " must not call os.execute")
            assert_true(not src:find("io%.popen"), rel .. " must not call io.popen")
            assert_true(not src:find("io%.open"), rel .. " must not call io.open")
        end

        local nil_ok = pcall(themes.get, "dynamic", nil, nil)
        assert_true(not nil_ok, "themes.get('dynamic') must fail without dynamic_palette")

        local bad_ok = pcall(themes.get, "dynamic", nil, { bg = "111318" })
        assert_true(not bad_ok, "themes.get('dynamic') must fail with incomplete dynamic_palette")

        local pal = color.build_dynamic_palette({ accent = "#7dcfff", bg = "#15161e" })
        local dyn = themes.get("dynamic", { warn = "e0af68" }, pal)
        assert_eq(dyn.name, "dynamic", "dynamic name")
        assert_eq(dyn.label, "Dynamic (Wallpaper)", "dynamic label")
        assert_eq(dyn.warn, "e0af68", "theme_overrides merged onto dynamic")
        assert_eq(#dyn.term, 16, "derived 16 ANSI colors")

        for _, lname in ipairs(layouts.list()) do
            local layout = layouts.get(lname)
            local cfg = {
                layout = lname,
                theme = "dynamic",
                font = "JetBrainsMono Nerd Font",
                terminal = "kaze-footclient",
                cursor_theme = "Adwaita",
                wallpaper_expanded = "/tmp/wall.png",
                hypr = layout.hypr,
                ui = layout.ui,
            }
            local wb = emit_waybar.emit(cfg, dyn, layout)
            assert_contains(wb.colors_css, "#" .. dyn.accent, "waybar dynamic accent")
            assert_contains(emit_foot.emit(cfg, dyn, layout), "background=" .. dyn.bg, "foot dynamic bg")
            assert_contains(emit_fuzzel.emit(cfg, dyn, layout), "prompt=" .. dyn.accent .. "ff", "fuzzel dynamic")
            assert_contains(emit_fnott.emit(cfg, dyn, layout), "progress-color=" .. dyn.accent .. "ff", "fnott dynamic")
            assert_contains(emit_hyprlock.emit(cfg, dyn, layout), "rgb(" .. dyn.accent .. ")", "hyprlock dynamic")
        end
    end)

    test("stage3 state & profile: persists new fields and validates --set-profile minimal|full", function()
        with_stubs(function(tmp, _, run)
            local sp = tmp .. "/cfg/kaze/state.lua"
            local pal = color.build_dynamic_palette({ accent = "#cba6f7", bg = "#11111b" })
            state.save({
                layout = "islands",
                theme = "dynamic",
                wallpaper = tmp .. "/wall.png",
                profile = "full",
                prev_color_scheme = "'default'",
                dynamic_palette = pal,
            }, sp)

            local loaded = state.load(sp)
            assert_eq(loaded.layout, "islands")
            assert_eq(loaded.theme, "dynamic")
            assert_eq(loaded.wallpaper, tmp .. "/wall.png")
            assert_eq(loaded.profile, "full")
            assert_eq(loaded.prev_color_scheme, "'default'")
            assert_eq(loaded.dynamic_palette.accent, pal.accent)

            local cfg, theme = config.load({
                home = tmp,
                config_dir = tmp .. "/cfg",
                state_path = sp,
                strict = true,
            })
            assert_eq(cfg.profile, "full")
            assert_eq(theme.name, "dynamic")
            assert_eq(theme.accent, pal.accent)

            -- CLI --set-profile minimal / full and invalid rejection
            assert(os.execute(run("kaze-sync", "--set-profile minimal") .. " >/dev/null 2>&1"))
            assert_eq(state.load(sp).profile, "minimal", "profile set to minimal")
            assert(os.execute(run("kaze-sync", "--set-profile full") .. " >/dev/null 2>&1"))
            assert_eq(state.load(sp).profile, "full", "profile set to full")

            local bad_prof = os.execute(run("kaze-sync", "--set-profile invalid") .. " >/dev/null 2>&1")
            assert_true(bad_prof ~= true and bad_prof ~= 0, "invalid profile must fail")
            assert_eq(state.load(sp).profile, "full", "failed profile leaves state intact")

            fs.write_atomic(tmp .. "/cfg/kaze/user.lua", 'return { profile = "minimal" }\n')
            local pinned_prof = os.execute(run("kaze-sync", "--set-profile full") .. " >/dev/null 2>&1")
            assert_true(pinned_prof ~= true and pinned_prof ~= 0, "pinned profile in user.lua must reject switch")
        end)
    end)

    test("stage3 kaze-theme dynamic & prefer-dark: stubbed matugen success, failure rollback, and gsettings sync", function()
        with_stubs(function(tmp, stub, run)
            local wall_dir = tmp .. "/Pictures/Wallpapers"
            fs.mkdir_p(wall_dir)
            local wall = wall_dir .. "/wallpaper.png"
            fs.write_atomic(wall, PNG_FIXTURE)

            assert(os.execute(run("kaze-theme", "--quiet lavender") .. " >/dev/null 2>&1"))
            assert_eq(fs.capture(run("kaze-theme", "--current")), "lavender\n")

            stub("matugen", [[
if [ "${FAIL_MATUGEN:-0}" = 1 ]; then
  exit 1
fi
if [ "${LEGACY_JSON_FLAG:-0}" = 1 ] && [ "$3" = "-j" ]; then
  exit 2
fi
test "$1" = image
printf '{"colors":{"primary":{"dark":{"color":"#7dcfff"}},"background":{"dark":{"color":"#12151c"}},"on_primary":{"dark":{"color":"#ffffff"}}}}\n'
]])
            -- Failure preserves lavender
            local fail_dyn = os.execute(run("kaze-theme", "--quiet dynamic", "FAIL_MATUGEN=1") .. " 2>/dev/null")
            assert_true(fail_dyn ~= true and fail_dyn ~= 0, "matugen failure must fail kaze-theme dynamic")
            assert_eq(fs.capture(run("kaze-theme", "--current")), "lavender\n", "previous theme preserved on matugen failure")
            assert_contains(assert(fs.read_file(tmp .. "/cfg/waybar/colors.css")), "#" .. themes.get("lavender").accent)

            -- Success (including --json hex fallback path)
            assert(os.execute(run("kaze-theme", "--quiet dynamic", "LEGACY_JSON_FLAG=1")))
            assert_eq(fs.capture(run("kaze-theme", "--current")), "dynamic\n")
            local st = state.load(tmp .. "/cfg/kaze/state.lua")
            assert_eq(st.theme, "dynamic")
            assert_true(type(st.dynamic_palette) == "table", "dynamic_palette saved in state.lua")
            assert_contains(assert(fs.read_file(tmp .. "/cfg/waybar/colors.css")), "#" .. st.dynamic_palette.accent)

            -- Menu includes dynamic when matugen exists
            stub("pgrep", "exit 1")
            stub("fuzzel", [[cat > "$HOME/theme-menu"]])
            assert(os.execute(run("kaze-theme", "--menu")))
            assert_contains(assert(fs.read_file(tmp .. "/theme-menu")), "dynamic  —  Dynamic (Wallpaper) (active)")

            -- Optional prefer-dark sync via gsettings
            stub("dconf", "exit 0")
            stub("gsettings", [[
case "$1 $2 $3" in
  'get org.gnome.desktop.interface color-scheme') printf "'default'\n" ;;
  'set org.gnome.desktop.interface color-scheme') printf '%s\n' "$4" >> "$HOME/gsettings-set" ;;
  *) exit 2 ;;
esac
]])
            fs.write_atomic(tmp .. "/cfg/kaze/user.lua", "return { sync_prefer_dark = true }\n")
            assert(os.execute(run("kaze-sync", "", "GSETTINGS_BACKEND=memory")))
            assert_true(not fs.file_exists(tmp .. "/gsettings-set"), "must skip when GSETTINGS_BACKEND=memory")

            assert(os.execute(run("kaze-sync", "")))
            assert_eq(fs.read_file(tmp .. "/gsettings-set"), "prefer-dark\n")
            assert_eq(state.load(tmp .. "/cfg/kaze/state.lua").prev_color_scheme, "'default'")
            for _, forbidden in ipairs({ "/cfg/gtk-3.0", "/cfg/gtk-4.0", "/cfg/qt6ct", "/cfg/btop", "/cfg/nvim" }) do
                assert_true(not fs.file_exists(tmp .. forbidden), "must never write " .. forbidden)
            end
        end)
    end)

    test("stage3 kaze-wall: --current, <path>, --random, --menu, --preview, corrupt & pinned rejection, zero-flash swap", function()
        with_stubs(function(tmp, stub, run)
            local wall_dir = tmp .. "/Pictures/Wallpapers"
            fs.mkdir_p(wall_dir .. "/sub")
            local w1 = wall_dir .. "/alpha.png"
            local w2 = wall_dir .. "/beta.jpg"
            local w3 = wall_dir .. "/sub/gamma.webp"
            local corrupt = tmp .. "/corrupt.png"
            fs.write_atomic(w1, PNG_FIXTURE)
            fs.write_atomic(w2, JPG_FIXTURE)
            fs.write_atomic(w3, WEBP_FIXTURE)
            fs.write_atomic(corrupt, "not-an-image-garbage-bytes")

            -- Direct <path> and --current
            assert(os.execute(run("kaze-wall", "--quiet " .. fs.shell_quote(w1))))
            assert_eq(fs.capture(run("kaze-wall", "--current")), w1 .. "\n")
            assert_eq(state.load(tmp .. "/cfg/kaze/state.lua").wallpaper, w1)

            -- Corrupt and missing image rejection
            local bad_corrupt = os.execute(run("kaze-wall", "--quiet " .. fs.shell_quote(corrupt)) .. " 2>/dev/null")
            assert_true(bad_corrupt ~= true and bad_corrupt ~= 0, "corrupt image must be rejected")
            assert_eq(fs.capture(run("kaze-wall", "--current")), w1 .. "\n", "corrupt image keeps previous wallpaper")

            local bad_missing = os.execute(run("kaze-wall", "--quiet " .. fs.shell_quote(tmp .. "/nope.png")) .. " 2>/dev/null")
            assert_true(bad_missing ~= true and bad_missing ~= 0, "missing image must be rejected")

            -- --random switches away from w1
            assert(os.execute(run("kaze-wall", "--quiet --random")))
            local after_rand = assert(fs.capture(run("kaze-wall", "--current"))):gsub("\n$", "")
            assert_true(after_rand == w2 or after_rand == w3, "--random selects another valid wallpaper")

            -- --menu lists sorted relative paths in fuzzel
            stub("pgrep", "exit 1")
            stub("fuzzel", [[cat > "$HOME/wall-menu"; printf 'sub/gamma.webp\n']])
            assert(os.execute(run("kaze-wall", "--quiet --menu")))
            assert_eq(fs.read_file(tmp .. "/wall-menu"), "alpha.png\nbeta.jpg\nsub/gamma.webp\n")
            assert_eq(fs.capture(run("kaze-wall", "--current")), w3 .. "\n")

            -- --preview opens yazi in kaze-footclient
            stub("yazi", "exit 0")
            stub("footclient", [[printf '%s\n' "$@" > "$HOME/preview-args"]])
            assert(os.execute(run("kaze-wall", "--preview")))
            local pargs = assert(fs.read_file(tmp .. "/preview-args"))
            assert_contains(pargs, "-a\nkaze-tui\n-T\nWallpapers (yazi)\nyazi\n" .. wall_dir .. "\n")

            -- Dynamic theme auto-updates on kaze-wall and aborts if matugen fails
            stub("matugen", [[
if [ "${FAIL_WALL_MATUGEN:-0}" = 1 ]; then exit 1; fi
case "$2" in
  *alpha.png) printf '{"colors":{"primary":{"dark":{"color":"#ff9e64"}},"background":{"dark":{"color":"#111318"}}}}\n' ;;
  *) printf '{"colors":{"primary":{"dark":{"color":"#9ece6a"}},"background":{"dark":{"color":"#111318"}}}}\n' ;;
esac
]])
            assert(os.execute(run("kaze-theme", "--quiet dynamic")))
            local before_pal = state.load(tmp .. "/cfg/kaze/state.lua").dynamic_palette
            local fail_dyn_wall = os.execute(run("kaze-wall", "--quiet " .. fs.shell_quote(w1), "FAIL_WALL_MATUGEN=1") .. " 2>/dev/null")
            assert_true(fail_dyn_wall ~= true and fail_dyn_wall ~= 0, "matugen failure must abort wallpaper switch under dynamic theme")
            assert_eq(state.load(tmp .. "/cfg/kaze/state.lua").wallpaper, w3, "old wallpaper kept when matugen fails")
            assert_eq(state.load(tmp .. "/cfg/kaze/state.lua").dynamic_palette.accent, before_pal.accent, "old palette kept")

            assert(os.execute(run("kaze-wall", "--quiet " .. fs.shell_quote(w1))))
            assert_eq(state.load(tmp .. "/cfg/kaze/state.lua").wallpaper, w1)
            assert_true(state.load(tmp .. "/cfg/kaze/state.lua").dynamic_palette.accent ~= before_pal.accent, "dynamic palette updated for new wallpaper")

            -- Pinned wallpaper in user.lua rejected with exit 1
            fs.write_atomic(tmp .. "/cfg/kaze/user.lua", string.format("return { wallpaper = %q }\n", w1))
            local pinned_direct = os.execute(run("kaze-wall", "--quiet " .. fs.shell_quote(w2)) .. " 2>/dev/null")
            assert_true(pinned_direct ~= true and pinned_direct ~= 0, "pinned user.lua must reject <path>")
            local pinned_rand = os.execute(run("kaze-wall", "--quiet --random") .. " 2>/dev/null")
            assert_true(pinned_rand ~= true and pinned_rand ~= 0, "pinned user.lua must reject --random")
            os.remove(tmp .. "/cfg/kaze/user.lua")

            -- Live zero-flash swap verification
            local sig = "wall-live_0"
            local live_vars = "HYPRLAND_INSTANCE_SIGNATURE=" .. sig
            fs.mkdir_p(tmp .. "/runtime/hypr/" .. sig)
            stub("foot", "exit 0")
            stub("fuzzel", "exit 0")
            stub("swaybg", [[
if [ "${CRASH_SWAYBG:-0}" = 1 ]; then
  exit 1
fi
echo "$$" > "$HOME/cand-pid"
trap 'echo "killed:$$" >> "$HOME/events"; exit 0' TERM INT
while :; do sleep 0.05; done
]])
            stub("systemctl", [[
case "$*" in
  '--user show-environment') printf 'HYPRLAND_INSTANCE_SIGNATURE=%s\n' "$HYPRLAND_INSTANCE_SIGNATURE" ;;
  '--user show -p MainPID --value kaze-waybar.service') printf '123\n' ;;
  '--user show -p MainPID --value kaze-wallpaper.service') printf '456\n' ;;
  '--user restart '*)
    if [ -f "$HOME/cand-pid" ]; then
      cpid=$(cat "$HOME/cand-pid")
      kill -0 "$cpid" 2>/dev/null && echo "cand-alive-at-restart:$cpid" >> "$HOME/events"
    fi
    echo "restart:$*" >> "$HOME/events" ;;
  '--user is-active --quiet '*|'--user reset-failed '*) : ;;
  *) exit 2 ;;
esac
]])
            stub("hyprctl", [[
case "$1" in
  reload) printf 'ok\n' ;;
  configerrors) : ;;
  -j) printf '[{"dpmsStatus":true}]\n' ;;
  layers)
    printf 'namespace: waybar, pid: 123\nnamespace: wallpaper, pid: 456\n'
    if [ -f "$HOME/cand-pid" ]; then
      printf 'namespace: wallpaper, pid: %s\n' "$(cat "$HOME/cand-pid")"
    fi ;;
  *) exit 2 ;;
esac
]])
            assert(os.execute(run("kaze-sync", "--session-start")))
            local env_file = tmp .. "/runtime/kaze/session.env"
            local env_before = assert(fs.read_file(env_file))

            -- Candidate crash aborts before touching kaze-wallpaper.service, session.env, or state.lua
            local crash_res = os.execute(run("kaze-wall", "--quiet " .. fs.shell_quote(w2), live_vars .. " CRASH_SWAYBG=1") .. " 2>/dev/null")
            assert_true(crash_res ~= true and crash_res ~= 0, "crashing candidate swaybg must abort")
            assert_true(not fs.file_exists(tmp .. "/events"), "service must not restart when candidate crashes")
            assert_eq(fs.read_file(env_file), env_before, "session.env untouched on candidate crash")
            assert_eq(state.load(tmp .. "/cfg/kaze/state.lua").wallpaper, w1, "state.lua untouched on candidate crash")

            -- Zero-flash success: candidate is alive during restart, then killed after service maps
            assert(os.execute(run("kaze-wall", "--quiet " .. fs.shell_quote(w2), live_vars)))
            local cpid = assert(fs.read_file(tmp .. "/cand-pid")):gsub("\n$", "")
            local events = assert(fs.read_file(tmp .. "/events"))
            assert_contains(events, "cand-alive-at-restart:" .. cpid .. "\n", "candidate covers screen while service restarts")
            assert_contains(events, "restart:--user restart kaze-waybar.service fnott.service kaze-wallpaper.service\n")
            assert_eq(state.load(tmp .. "/cfg/kaze/state.lua").wallpaper, w2)
            os.execute("sleep 0.1")
            assert_true(not os.execute("kill -0 " .. cpid .. " 2>/dev/null"), "transient candidate swaybg cleaned up")
        end)
    end)
end

local is_main = arg and type(arg[0]) == "string" and arg[0]:match("test_stage3_theme_wall%.lua$") and not debug.getinfo(3, "f")
if is_main then
    local script_dir = (arg and arg[0] or "tests/test_stage3_theme_wall.lua"):match("^(.*)/[^/]+$") or "."
    local repo_dir = script_dir .. "/.."
    package.path = table.concat({
        repo_dir .. "/lua/?.lua",
        repo_dir .. "/lua/?/init.lua",
        package.path,
    }, ";")

    local passed = 0
    local failed = 0

    local function test(name, fn)
        local ok, err = pcall(fn)
        if ok then
            passed = passed + 1
            io.stdout:write(string.format("  [PASS] %s\n", name))
        else
            failed = failed + 1
            io.stderr:write(string.format("  [FAIL] %s: %s\n", name, tostring(err)))
        end
    end

    local function assert_eq(actual, expected, msg)
        if actual ~= expected then
            error(string.format("%s: expected %s, got %s", msg or "mismatch", tostring(expected), tostring(actual)), 2)
        end
    end

    local function assert_true(cond, msg)
        if not cond then
            error(msg or "assertion failed", 2)
        end
    end

    local function assert_contains(haystack, needle, msg)
        if not haystack:find(needle, 1, true) then
            error(string.format("%s: missing %q", msg or "substring check", needle), 2)
        end
    end

    io.stdout:write("Running Stage 3 theme & wallpaper tests...\n")
    build_suite(test, assert_eq, assert_true, assert_contains, repo_dir)
    io.stdout:write(string.format("\nSummary: %d passed, %d failed\n", passed, failed))
    if failed > 0 then
        os.exit(1)
    end
end

return build_suite
