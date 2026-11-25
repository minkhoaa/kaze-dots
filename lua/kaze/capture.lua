local fs = require("kaze.fs")
local M = {}

function M.directory(xdg_name, fallback, subdir)
    local base = (fs.capture("xdg-user-dir " .. fs.shell_quote(xdg_name) .. " 2>/dev/null") or ""):gsub("\n$", "")
    local home = fs.home()
    if base:sub(1, 1) ~= "/" or base == home then base = home .. "/" .. fallback end
    return base .. "/" .. subdir
end

function M.reserve(dir, ext)
    local q = fs.shell_quote
    if not os.execute("mkdir -p -- " .. q(dir)) then return nil end
    local path = fs.capture("mktemp -- " .. q(dir .. "/" .. os.date("%Y-%m-%d_%H-%M-%S") .. ".XXXXXX." .. ext))
    return path and (path:gsub("\n$", ""))
end

-- Only the top-level name/focused keys in Hyprland's monitor records matter.
-- Walk strings as whole tokens so braces or escaped quotes in EDID descriptions
-- and nested data cannot masquerade as monitor records or properties.
function M.focused_output(json)
    if not json or not json:match("^%s*%[.*%]%s*$") then return nil end
    local depth, pos = 0, 1
    local name, focused, result
    while pos <= #json do
        local ch = json:sub(pos, pos)
        if ch == '"' then
            local stop = pos + 1
            while stop <= #json do
                local c = json:sub(stop, stop)
                if c == '"' then break end
                stop = stop + (c == "\\" and 2 or 1)
            end
            if stop > #json then return nil end
            if depth == 2 and json:match("^%s*:", stop + 1) then
                local key = json:sub(pos + 1, stop - 1)
                if key == "name" then
                    name = json:match('^%s*:%s*"([%w_.:%-]+)"%s*[,}]', stop + 1)
                elseif key == "focused" then
                    focused = json:match("^%s*:%s*true%s*[,}]", stop + 1) ~= nil
                end
            end
            pos = stop
        elseif ch == "{" or ch == "[" then
            depth = depth + 1
            if depth == 2 then name, focused = nil, false end
        elseif ch == "}" or ch == "]" then
            if depth == 2 and ch == "}" and focused then
                if result or not name then return nil end
                result = name
            end
            depth = depth - 1
        end
        pos = pos + 1
    end
    if depth == 0 then return result end
end

return M
