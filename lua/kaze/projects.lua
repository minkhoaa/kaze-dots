-- Pure-Lua project discovery and launch command builder for `kaze-project`.
local fs = require("kaze.fs")

local M = {}

local DEFAULT_ROOT_SUFFIXES = {
    "/Projects",
    "/Code",
    "/src",
    "/dev",
    "/Workspace",
}

local function normalize_dir(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    if path ~= "/" then
        path = path:gsub("/+$", "")
    end
    if path == "" then
        return "/"
    end
    return path
end

local function is_dir_default(path)
    local ok = os.execute("test -d " .. fs.shell_quote(path) .. " >/dev/null 2>&1")
    return ok == true or ok == 0
end

function M.compact_path(path, home)
    local h = normalize_dir(home or fs.home())
    local p = normalize_dir(path)
    if not p then
        return ""
    end
    if p == h then
        return "~"
    end
    if h and p:sub(1, #h + 1) == h .. "/" then
        return "~" .. p:sub(#h + 1)
    end
    return p
end

function M.resolve_roots(cfg, opts)
    opts = opts or {}
    local home = normalize_dir(opts.home or fs.home())
    local is_dir = opts.is_dir or is_dir_default
    local candidates = {}

    if type(cfg) == "table" and type(cfg.project_dirs) == "table" and #cfg.project_dirs > 0 then
        for _, raw in ipairs(cfg.project_dirs) do
            if type(raw) == "string" and raw ~= "" then
                candidates[#candidates + 1] = normalize_dir(fs.expand_home(raw, home))
            end
        end
    else
        for _, suffix in ipairs(DEFAULT_ROOT_SUFFIXES) do
            candidates[#candidates + 1] = home .. suffix
        end
    end

    local roots = {}
    local seen = {}
    for _, dir in ipairs(candidates) do
        if dir and not seen[dir] and is_dir(dir) then
            seen[dir] = true
            roots[#roots + 1] = dir
        end
    end
    return roots
end

function M.discover(cfg, opts)
    opts = opts or {}
    local home = normalize_dir(opts.home or fs.home())
    local capture = opts.capture or fs.capture
    local cmd_exists = opts.cmd_exists or fs.command_exists
    local is_dir = opts.is_dir or is_dir_default
    local q = fs.shell_quote

    local ordered = {}
    local seen = {}
    local function add_dir(raw_path)
        local dir = normalize_dir(raw_path)
        if not dir or dir == "/" or dir == home or seen[dir] then
            return
        end
        if is_dir(dir) then
            seen[dir] = true
            ordered[#ordered + 1] = {
                path = dir,
                label = M.compact_path(dir, home),
            }
        end
    end

    -- 1. Frecent directories from zoxide first
    if cmd_exists("zoxide") then
        local z_out = capture("zoxide query -l 2>/dev/null") or ""
        for line in z_out:gmatch("[^\r\n]+") do
            add_dir(line)
        end
    end

    -- 2. Git repositories & direct subdirectories under configured project roots
    local roots = M.resolve_roots(cfg, { home = home, is_dir = is_dir })
    if #roots > 0 then
        if cmd_exists("fd") then
            local quoted_roots = {}
            for _, r in ipairs(roots) do
                quoted_roots[#quoted_roots + 1] = q(r)
            end
            local root_args = table.concat(quoted_roots, " ")

            local git_out = capture("fd --hidden --no-ignore-vcs --max-depth 4 --type d '^\\.git$' " .. root_args .. " 2>/dev/null") or ""
            local git_dirs = {}
            for line in git_out:gmatch("[^\r\n]+") do
                local repo_dir = line:gsub("/%.git/?$", "")
                git_dirs[#git_dirs + 1] = repo_dir
            end
            table.sort(git_dirs)
            for _, d in ipairs(git_dirs) do
                add_dir(d)
            end

            local sub_out = capture("fd --max-depth 1 --type d . " .. root_args .. " 2>/dev/null") or ""
            local sub_dirs = {}
            for line in sub_out:gmatch("[^\r\n]+") do
                sub_dirs[#sub_dirs + 1] = line
            end
            table.sort(sub_dirs)
            for _, d in ipairs(sub_dirs) do
                add_dir(d)
            end
        else
            for _, r in ipairs(roots) do
                local find_out = capture("find " .. q(r) .. " -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort") or ""
                for line in find_out:gmatch("[^\r\n]+") do
                    add_dir(line)
                end
            end
        end
    end

    return ordered
end

function M.build_launch_cmds(dir, mode, opts)
    opts = opts or {}
    local q = fs.shell_quote
    local cmd_exists = opts.cmd_exists or fs.command_exists
    local terminal_bin = opts.terminal_bin or "kaze-footclient"

    local editor = opts.editor
    if not editor or editor == "" then
        local candidates = {}
        local env_ed = os.getenv("EDITOR")
        if env_ed and env_ed ~= "" then
            candidates[#candidates + 1] = env_ed
        end
        for _, cand in ipairs({ "nvim", "vim", "nano" }) do
            candidates[#candidates + 1] = cand
        end
        for _, cand in ipairs(candidates) do
            if cmd_exists(cand) then
                editor = cand
                break
            end
        end
    elseif not cmd_exists(editor) then
        editor = nil
    end

    local shell_cmd = q(terminal_bin) .. " -N -D " .. q(dir)
    if mode == "nvim" and editor then
        return { q(terminal_bin) .. " -N -D " .. q(dir) .. " -e " .. q(editor) .. " ." }
    elseif mode == "split" and editor then
        return {
            q(terminal_bin) .. " -N -D " .. q(dir) .. " -e " .. q(editor) .. " .",
            shell_cmd,
        }
    end
    return { shell_cmd }
end

return M
