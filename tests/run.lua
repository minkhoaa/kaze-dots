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

        fs.write_atomic(user_lua, "return {} -- original hypr user settings\n")
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
        assert_contains(assert(fs.read_file(noc_cfg)), "offline_mode = true\n")
        assert_true(fs.file_exists(cfg .. "/foot/themes/noctalia"), "seeds empty Foot Noctalia theme")
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
        assert_contains(manifest, cfg .. "/hypr/xdph.conf\n")
        assert_contains(manifest, cfg .. "/systemd/user/kaze-noctalia.service\n")
        assert_contains(manifest, cfg .. "/foot/foot.ini\n")
        assert_contains(manifest, cfg .. "/starship.toml\n")
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
        assert_true(not fs.file_exists(last), "rollback unregisters active backup")
        for _, path in ipairs({ tmp .. "/.local/bin/kaze-session", tmp .. "/.zprofile", data .. "/kaze-dots/lua/kaze", cfg .. "/foot/themes/noctalia" }) do
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
    assert_true(by_name["kaze-share-preview"] ~= nil and by_name["kaze-share-preview"].float == true and by_name["kaze-share-preview"].pin == true)
    assert_eq(by_name["kaze-share-preview"].keep_aspect_ratio, true)
    assert_eq(by_name["kaze-share-preview"].match.class, "^at\\.yrlf\\.wl_mirror$")
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

dofile(repo_dir .. "/tests/test_stage3_keys.lua")(test, assert_eq, assert_true, assert_contains, repo_dir)
dofile(repo_dir .. "/tests/test_stage3_profile_doctor.lua")(test, assert_eq, assert_true, assert_contains, repo_dir)

io.stdout:write(string.format("\nSummary: %d passed, %d failed\n", passed, failed))
if failed > 0 then
    os.exit(1)
end
