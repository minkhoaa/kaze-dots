-- Pure-Lua mirror discovery, saturation math (Q1..Q4 burst-shaping + B1/B4),
-- pacman.conf parser, validators, and transactional commit/rollback helpers.
-- Strictly zero network/filesystem I/O inside pure functions.

local json = require("kaze.json")

local M = {}

M.VERSION = "2.0"
M.USER_AGENT = "kaze-mirror/" .. M.VERSION
M.ARCH_FEED_URL = "https://archlinux.org/mirrors/status/json/"
M.CACHYOS_FEED_URL = "https://raw.githubusercontent.com/CachyOS/CachyOS-PKGBUILDS/master/cachyos-mirrorlist/cachyos-mirrorlist"

M.SCREEN_BYTES = 128 * 1024
M.WARMUP_BYTES = 8 * 1024 * 1024
M.WARMUP_BYTES_FAST = 4 * 1024 * 1024
M.SINGLE_CAP_BYTES = 80 * 1024 * 1024
M.MULTI_CAP_BYTES = 24 * 1024 * 1024
M.STALE_WINDOW_SEC = 12 * 3600
M.SIZE_TOLERANCE = 0.05
M.IMPROVEMENT_MARGIN = 0.10
M.CANONICAL_WORKLOAD_MBIT = 201.3 -- 24 MiB in Mbit
M.MAX_BACKUPS = 5

local ARCH_REPOS = {
    core = 2,
    extra = 1,
    multilib = 3,
    ["extra-testing"] = 4,
    ["core-testing"] = 5,
    ["multilib-testing"] = 6,
    ["extra-staging"] = 7,
    ["core-staging"] = 8,
    ["multilib-staging"] = 9,
}

local CACHYOS_REPOS = {
    ["cachyos-extra-v3"] = 1,
    ["cachyos-extra-v4"] = 2,
    ["cachyos-extra-znver4"] = 3,
    cachyos = 4,
    ["cachyos-v3"] = 5,
    ["cachyos-v4"] = 6,
    ["cachyos-znver4"] = 7,
    ["cachyos-core-v3"] = 8,
    ["cachyos-core-v4"] = 9,
    ["cachyos-core-znver4"] = 10,
}

local MONTHS = {
    Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
    Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12,
}

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function strip_bom(s)
    if type(s) == "string" and s:sub(1, 3) == "\239\187\191" then
        return s:sub(4)
    end
    return tostring(s or "")
end

-- Howard Hinnant's civil-to-days algorithm (UTC, zero locale/TZ dependencies).
local function days_from_civil(y, m, d)
    if m <= 2 then
        y = y - 1
    end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = m + (m > 2 and -3 or 9)
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

function M.parse_http_date(str)
    if type(str) ~= "string" or str == "" then
        return nil
    end
    local day, mon_s, year, hour, min, sec =
        str:match("^%s*%a+,%s+(%d%d?)%s+(%a%a%a)%s+(%d%d%d%d)%s+(%d%d):(%d%d):(%d%d)%s+GMT%s*$")
    if not day then
        day, mon_s, year, hour, min, sec =
            str:match("^%s*%a+,%s+(%d%d?)%-(%a%a%a)%-(%d%d)%s+(%d%d):(%d%d):(%d%d)%s+GMT%s*$")
        if year then
            year = tostring(2000 + tonumber(year))
        end
    end
    if not day then
        return nil
    end
    local m = MONTHS[mon_s]
    local y = tonumber(year)
    local d = tonumber(day)
    local hh = tonumber(hour)
    local mm = tonumber(min)
    local ss = tonumber(sec)
    if not (m and y and d and hh and mm and ss) then
        return nil
    end
    if d < 1 or d > 31 or hh > 23 or mm > 59 or ss > 60 then
        return nil
    end
    return days_from_civil(y, m, d) * 86400 + hh * 3600 + mm * 60 + ss
end

function M.median(values)
    if type(values) ~= "table" or #values == 0 then
        return nil
    end
    local sorted = {}
    for i = 1, #values do
        sorted[i] = values[i]
    end
    table.sort(sorted)
    local n = #sorted
    if n % 2 == 1 then
        return sorted[(n + 1) // 2]
    end
    return (sorted[n // 2] + sorted[n // 2 + 1]) / 2.0
end

local function is_private_or_loopback_host(host)
    local h = host:lower():gsub(":%d+$", "")
    if h == "localhost" or h:match("%.localhost$") or h == "[::1]" or h == "::1" or h == "0.0.0.0" then
        return true
    end
    local a, b = h:match("^(%d+)%.(%d+)%.%d+%.%d+$")
    if a and b then
        a, b = tonumber(a), tonumber(b)
        if a == 127 or a == 10 or a == 0 then return true end
        if a == 192 and b == 168 then return true end
        if a == 169 and b == 254 then return true end
        if a == 172 and b >= 16 and b <= 31 then return true end
    end
    if h:match("^%[?[fF][cCdDeE][0-9a-fA-F]") then
        return true
    end
    return false
end

function M.is_safe_https_url(url)
    if type(url) ~= "string" or url == "" then
        return false
    end
    if url:find("[%s%c'\";`\\|&<>?#@]") then
        return false
    end
    if not url:match("^https://") then
        return false
    end
    local rest = url:sub(9)
    local host, path = rest:match("^([^/]+)(/.*)$")
    if not host or host == "" or not path or path == "" then
        return false
    end
    if path:find("/%.%./", 1, false) or path:match("/%.%.$") then
        return false
    end
    if host:find(":", 1, true) and not host:match("^[%w%.%-]+:%d+$") and not host:match("^%[[0-9a-fA-F:]+%]$") then
        return false
    end
    if is_private_or_loopback_host(host) then
        return false
    end
    return true
end

function M.url_host(url)
    if type(url) ~= "string" then
        return ""
    end
    return url:match("^https?://([^/]+)") or url
end

function M.canonical_host(url)
    return M.url_host(url):lower():gsub(":443$", "")
end

function M.classify_repo(repo)
    if ARCH_REPOS[repo] then
        return "arch", ARCH_REPOS[repo]
    end
    if CACHYOS_REPOS[repo] then
        return "cachyos", CACHYOS_REPOS[repo]
    end
    return "unmanaged", 999
end

local function discover_arch_var(mirrorlist_path, repos, read_file_fn)
    local function scan_text(txt)
        if type(txt) ~= "string" then return nil end
        for line in (txt .. "\n"):gmatch("(.-)\r?\n") do
            local s = trim(line)
            if not s:match("^##") then
                local url = s:match("^#?%s*Server%s*=%s*(%S+)$")
                if url then
                    local tok = url:match("(%$arch_[%w_]+)") or url:match("(%$arch)")
                    if tok then
                        return tok
                    end
                end
            end
        end
        return nil
    end

    if type(read_file_fn) == "function" then
        local found = scan_text(read_file_fn(mirrorlist_path)) or scan_text(read_file_fn(mirrorlist_path .. ".pacnew"))
        if found then
            return found
        end
    end

    for _, r in ipairs(repos) do
        if r:match("%-v3$") then return "$arch_v3" end
        if r:match("%-v4$") or r:match("%-znver4$") then return "$arch_v4" end
    end
    local base = mirrorlist_path:match("([^/]+)$") or mirrorlist_path
    if base:find("v3", 1, true) then return "$arch_v3" end
    if base:find("v4", 1, true) or base:find("znver4", 1, true) then return "$arch_v4" end
    return "$arch"
end

function M.parse_pacman_conf(text, opts)
    opts = opts or {}
    local default_arch = opts.arch or "x86_64"
    local read_file_fn = opts.read_file
    local architecture = default_arch
    local parallel_downloads = nil
    local db_path = "/var/lib/pacman/"

    local repo_order = {}
    local repos_by_name = {}

    local function ensure_repo(name)
        local r = repos_by_name[name]
        if not r then
            local kind, prio = M.classify_repo(name)
            r = {
                name = name,
                kind = kind,
                priority = prio,
                includes = {},
                glob_includes = {},
                inline_servers = {},
                cache_servers = {},
            }
            repos_by_name[name] = r
            repo_order[#repo_order + 1] = name
        end
        return r
    end

    local visited = {}
    local function parse_stream(src_text, current_section, depth)
        if depth > 8 then return current_section end
        local sec = current_section
        for raw_line in (strip_bom(src_text) .. "\n"):gmatch("(.-)\r?\n") do
            local line = trim(raw_line)
            -- Per pacman.conf(5), ONLY lines starting with '#' are comments; mid-line '#' is literal.
            if line ~= "" and line:sub(1, 1) ~= "#" then
                local new_sec = line:match("^%[([^%]]+)%]$")
                if new_sec then
                    sec = trim(new_sec)
                    if sec ~= "options" then
                        ensure_repo(sec)
                    end
                elseif sec == nil or sec == "options" then
                    local k, v = line:match("^([%w_%-]+)%s*=%s*(.+)$")
                    if k == "Architecture" then
                        local first_tok = trim(v):match("^(%S+)")
                        if first_tok and first_tok ~= "" and first_tok ~= "auto" then
                            architecture = first_tok
                        end
                    elseif k == "ParallelDownloads" then
                        local pd = tonumber(trim(v))
                        if pd and pd >= 1 then
                            parallel_downloads = math.floor(pd)
                        end
                    elseif k == "DBPath" then
                        local p = trim(v)
                        if p:sub(1, 1) == "/" then
                            db_path = p
                        end
                    elseif k == "Include" and type(read_file_fn) == "function" then
                        local inc = trim(v)
                        if inc:sub(1, 1) == "/" and not inc:find("[*?%[]") and not visited[inc] then
                            visited[inc] = true
                            local inc_txt = read_file_fn(inc)
                            if inc_txt then
                                sec = parse_stream(inc_txt, sec, depth + 1)
                            end
                        end
                    end
                else
                    local r = ensure_repo(sec)
                    local k, v = line:match("^([%w_%-]+)%s*=%s*(.+)$")
                    if k == "Include" then
                        local inc = trim(v)
                        if inc:sub(1, 1) == "/" then
                            if inc:find("[*?%[]") then
                                r.glob_includes[#r.glob_includes + 1] = inc
                            else
                                r.includes[#r.includes + 1] = inc
                            end
                        end
                    elseif k == "Server" then
                        r.inline_servers[#r.inline_servers + 1] = trim(v)
                    elseif k == "CacheServer" then
                        r.cache_servers[#r.cache_servers + 1] = trim(v)
                    end
                end
            end
        end
        return sec
    end

    parse_stream(text, nil, 0)

    local groups_by_path = {}
    local group_order = {}
    local skipped_repos = {}

    for _, rname in ipairs(repo_order) do
        local r = repos_by_name[rname]
        if r.kind == "unmanaged" then
            skipped_repos[#skipped_repos + 1] = { repo = rname, reason = "unmanaged third-party or custom repo" }
            for _, inc in ipairs(r.includes) do
                if groups_by_path[inc] then
                    groups_by_path[inc].mixed_unmanaged = true
                else
                    groups_by_path[inc] = { path = inc, repos = {}, kinds = {}, mixed_unmanaged = true }
                end
            end
        elseif #r.glob_includes > 0 then
            skipped_repos[#skipped_repos + 1] = { repo = rname, reason = "ambiguous glob Include (" .. r.glob_includes[1] .. ")" }
        elseif #r.inline_servers > 0 then
            skipped_repos[#skipped_repos + 1] = { repo = rname, reason = "inline Server= directive present" }
        elseif #r.cache_servers > 0 then
            skipped_repos[#skipped_repos + 1] = { repo = rname, reason = "CacheServer= directive present" }
        elseif #r.includes == 0 then
            skipped_repos[#skipped_repos + 1] = { repo = rname, reason = "no Include mirrorlist" }
        elseif #r.includes > 1 then
            skipped_repos[#skipped_repos + 1] = { repo = rname, reason = "multiple Include mirrorlists" }
        else
            local path = r.includes[1]
            local grp = groups_by_path[path]
            if not grp then
                grp = { path = path, repos = {}, kinds = {}, mixed_unmanaged = false, _seen = {} }
                groups_by_path[path] = grp
                group_order[#group_order + 1] = path
            elseif not grp._seen then
                grp._seen = {}
                group_order[#group_order + 1] = path
            end
            if not grp._seen[rname] then
                grp._seen[rname] = true
                grp.repos[#grp.repos + 1] = rname
                grp.kinds[r.kind] = true
            end
        end
    end

    local groups = {}
    for _, path in ipairs(group_order) do
        local grp = groups_by_path[path]
        local kind_list = {}
        for k in pairs(grp.kinds) do kind_list[#kind_list + 1] = k end
        if grp.mixed_unmanaged or #kind_list ~= 1 then
            for _, rn in ipairs(grp.repos) do
                skipped_repos[#skipped_repos + 1] = {
                    repo = rn,
                    reason = "mirrorlist " .. path .. " mixes incompatible or unmanaged repos",
                }
            end
        else
            local kind = kind_list[1]
            local rep = grp.repos[1]
            local best_prio = repos_by_name[rep].priority
            for _, rn in ipairs(grp.repos) do
                if repos_by_name[rn].priority < best_prio then
                    best_prio = repos_by_name[rn].priority
                    rep = rn
                end
            end
            local arch_var = discover_arch_var(path, grp.repos, read_file_fn)
            groups[#groups + 1] = {
                path = path,
                basename = path:match("([^/]+)$") or path,
                kind = kind,
                arch_var = arch_var,
                base_arch = architecture,
                repos = grp.repos,
                representative_repo = rep,
            }
        end
    end

    return {
        architecture = architecture,
        parallel_downloads = parallel_downloads,
        db_path = db_path,
        repos = repo_order,
        groups = groups,
        skipped_repos = skipped_repos,
    }
end

function M.parse_mirrorlist_servers(text)
    local active = {}
    local commented = {}
    local seen_active = {}
    local seen_commented = {}

    for raw_line in (strip_bom(text) .. "\n"):gmatch("(.-)\r?\n") do
        local line = trim(raw_line)
        local active_url = line:match("^Server%s*=%s*(%S+)$")
        if active_url and M.is_safe_https_url(active_url) then
            local norm = active_url:gsub("/+$", "")
            if not seen_active[norm] then
                seen_active[norm] = true
                active[#active + 1] = norm
            end
        elseif not line:match("^##") then
            -- Single-# commented Server = are alternates; ## marks maintainer-disabled mirrors.
            local comm_url = line:match("^#%s*Server%s*=%s*(%S+)$")
            if comm_url and M.is_safe_https_url(comm_url) then
                local norm = comm_url:gsub("/+$", "")
                if not seen_commented[norm] then
                    seen_commented[norm] = true
                    commented[#commented + 1] = norm
                end
            end
        end
    end

    return active, commented
end

function M.parse_arch_feed(json_text)
    local ok, data = pcall(json.decode, json_text)
    if not ok or type(data) ~= "table" or type(data.urls) ~= "table" then
        return nil, "invalid Arch mirror status JSON"
    end
    local out = {}
    local seen = {}
    for _, entry in ipairs(data.urls) do
        if type(entry) == "table"
            and entry.active == true
            and entry.protocol == "https"
            and type(entry.url) == "string"
            and not entry.url:find("$", 1, true)
        then
            local comp = tonumber(entry.completion_pct)
            if comp == nil or comp >= 0.95 then
                local base = entry.url:gsub("/+$", "")
                local tmpl = base .. "/$repo/os/$arch"
                if M.is_safe_https_url(tmpl) and not seen[tmpl] then
                    seen[tmpl] = true
                    out[#out + 1] = tmpl
                end
            end
        end
    end
    return out
end

function M.parse_cachyos_feed(text, arch_var)
    arch_var = arch_var or "$arch"
    local out = {}
    local seen = {}
    for raw_line in (strip_bom(text) .. "\n"):gmatch("(.-)\r?\n") do
        local line = trim(raw_line)
        if not line:match("^##") then
            local url = line:match("^#?%s*Server%s*=%s*(%S+)$")
            if url and url:sub(-12) == "/$arch/$repo" then
                local prefix = url:sub(1, -13)
                if not prefix:find("$", 1, true) then
                    local rewritten = prefix .. "/" .. arch_var .. "/$repo"
                    if M.is_safe_https_url(rewritten) and not seen[rewritten] then
                        seen[rewritten] = true
                        out[#out + 1] = rewritten
                    end
                end
            end
        end
    end
    return out
end

function M.merge_candidates(...)
    local out = {}
    local seen = {}
    local lists = { ... }
    for _, list in ipairs(lists) do
        if type(list) == "table" then
            for _, url in ipairs(list) do
                if type(url) == "string" then
                    local norm = url:gsub("/+$", "")
                    if M.is_safe_https_url(norm) and not seen[norm] then
                        seen[norm] = true
                        out[#out + 1] = norm
                    end
                end
            end
        end
    end
    return out
end

-- Exact libalpm substitution: $repo -> repo, $arch -> base_arch (so $arch_v3 -> x86_64_v3).
function M.expand_base_url(template, repo, base_arch)
    local url = tostring(template or "")
    url = url:gsub("%$repo", repo)
    url = url:gsub("%$arch", base_arch)
    return (url:gsub("/+$", ""))
end

function M.expand_db_url(template, repo, base_arch)
    return M.expand_base_url(template, repo, base_arch) .. "/" .. repo .. ".db"
end

function M.expand_pkg_url(template, repo, base_arch, filename)
    return M.expand_base_url(template, repo, base_arch) .. "/" .. filename
end

function M.is_valid_pacman_db_magic(bytes)
    if type(bytes) ~= "string" or #bytes < 4 then
        return false
    end
    if bytes:sub(1, 3) == "\31\139\8" then return true end
    if bytes:sub(1, 4) == "\40\181\47\253" then return true end
    if bytes:sub(1, 3) == "BZh" then return true end
    if #bytes >= 6 and bytes:sub(1, 6) == "\2537zXZ\0" then return true end
    if #bytes >= 262 and bytes:sub(258, 262) == "ustar" then return true end
    return false
end

function M.parse_content_range(header)
    if type(header) ~= "string" or header == "" then
        return nil, nil
    end
    local end_b, total_b = header:match("^%s*[bB][yY][tT][eE][sS]%s+0%-(%d+)/(%d+)%s*$")
    if not end_b then
        return nil, nil
    end
    return tonumber(end_b), tonumber(total_b)
end

-- Parse concatenated `*/desc` output from `bsdtar -xOf <repo>.db --include='*/desc'`.
function M.parse_bsdtar_desc(text)
    local pkgs = {}
    local cur = {}
    local field = nil

    local function flush()
        if cur.name and cur.filename and cur.csize and cur.csize > 0 then
            pkgs[#pkgs + 1] = cur
        end
        cur = {}
        field = nil
    end

    for raw_line in (tostring(text or "") .. "\n"):gmatch("(.-)\r?\n") do
        local line = trim(raw_line)
        if line == "" then
            field = nil
        elseif line:sub(1, 1) == "%" and line:sub(-1) == "%" then
            if line == "%FILENAME%" and cur.filename then
                flush()
            end
            field = line
        elseif field then
            if field == "%FILENAME%" then
                cur.filename = line
            elseif field == "%NAME%" then
                cur.name = line
            elseif field == "%CSIZE%" then
                cur.csize = tonumber(line)
            elseif field == "%BUILDDATE%" then
                cur.builddate = tonumber(line)
            elseif field == "%SHA256SUM%" then
                cur.sha256 = line
            end
            field = nil
        end
    end
    flush()
    return pkgs
end

-- Dynamically choose stable large packages for Phase 1B/2A/2B (zero hardcoded names).
function M.select_probe_packages(pkgs, now_ts)
    now_ts = now_ts or os.time()
    local week_ago = now_ts - (7 * 86400)
    local day_ago = now_ts - 86400

    local function filter_pool(min_b, max_b, min_age_cutoff)
        local out = {}
        for _, p in ipairs(pkgs or {}) do
            if p.filename and p.csize and p.csize >= min_b and p.csize <= max_b then
                local bd = p.builddate or 0
                if not min_age_cutoff or (bd > 0 and bd <= min_age_cutoff) then
                    out[#out + 1] = p
                end
            end
        end
        return out
    end

    -- Single-stream target: prefer ~64 MiB inside [48, 96] MiB, age >= 7d
    local target_single = 64 * 1024 * 1024
    local s_pool = filter_pool(48 * 1024 * 1024, 96 * 1024 * 1024, week_ago)
    if #s_pool < 2 then
        s_pool = filter_pool(32 * 1024 * 1024, 96 * 1024 * 1024, day_ago)
    end
    if #s_pool == 0 then
        s_pool = filter_pool(16 * 1024 * 1024, 128 * 1024 * 1024, nil)
    end
    table.sort(s_pool, function(a, b)
        local da = math.abs(a.csize - target_single)
        local db = math.abs(b.csize - target_single)
        if da ~= db then return da < db end
        return a.name < b.name
    end)

    local singles = {}
    for i = 1, math.min(3, #s_pool) do
        singles[#singles + 1] = s_pool[i]
    end

    -- Multi-stream targets: 4 distinct packages in [24, 64] MiB, age >= 7d
    local m_pool = filter_pool(24 * 1024 * 1024, 64 * 1024 * 1024, week_ago)
    if #m_pool < 4 then
        m_pool = filter_pool(16 * 1024 * 1024, 80 * 1024 * 1024, day_ago)
    end
    if #m_pool < 4 then
        m_pool = filter_pool(8 * 1024 * 1024, 96 * 1024 * 1024, nil)
    end
    table.sort(m_pool, function(a, b)
        if a.csize ~= b.csize then return a.csize > b.csize end
        return a.name < b.name
    end)
    local multis = {}
    local used = {}
    if #m_pool > 0 then
        local step = math.max(1, math.floor(#m_pool / 4))
        local idx = 1
        while #multis < 4 and idx <= #m_pool do
            local p = m_pool[idx]
            if not used[p.name] then
                used[p.name] = true
                multis[#multis + 1] = p
            end
            idx = idx + step
        end
        for _, p in ipairs(m_pool) do
            if #multis >= 4 then break end
            if not used[p.name] then
                used[p.name] = true
                multis[#multis + 1] = p
            end
        end
    end

    return {
        singles = singles,
        multis = multis,
    }
end

-- Adaptive mixed-size batch (4-6 large 10-20 MiB + 10-12 medium 2-5 MiB) for Stage 3 pacman -Sw A/B.
function M.select_bench_batch(pkgs_by_repo, target_bytes, now_ts)
    now_ts = now_ts or os.time()
    local week_ago = now_ts - (7 * 86400)
    target_bytes = math.max(32 * 1024 * 1024, math.min(96 * 1024 * 1024, tonumber(target_bytes) or (64 * 1024 * 1024)))

    local large, medium = {}, {}
    local seen = {}
    local repo_names = {}
    for r in pairs(pkgs_by_repo or {}) do repo_names[#repo_names + 1] = r end
    table.sort(repo_names)

    for _, repo in ipairs(repo_names) do
        for _, p in ipairs(pkgs_by_repo[repo] or {}) do
            local bd = p.builddate or 0
            if p.name and p.csize and not seen[p.name] and (bd == 0 or bd <= week_ago) then
                if p.csize >= 10 * 1024 * 1024 and p.csize <= 20 * 1024 * 1024 then
                    seen[p.name] = true
                    large[#large + 1] = { repo = repo, name = p.name, filename = p.filename, bytes = p.csize }
                elseif p.csize >= 2 * 1024 * 1024 and p.csize <= 5 * 1024 * 1024 then
                    seen[p.name] = true
                    medium[#medium + 1] = { repo = repo, name = p.name, filename = p.filename, bytes = p.csize }
                end
            end
        end
    end

    table.sort(large, function(a, b) if a.bytes ~= b.bytes then return a.bytes < b.bytes end return a.name < b.name end)
    table.sort(medium, function(a, b) if a.bytes ~= b.bytes then return a.bytes < b.bytes end return a.name < b.name end)

    local batch = {}
    local total = 0
    local function pick_even(pool, want_n, byte_cap)
        if #pool == 0 or want_n <= 0 then return end
        local step = #pool / want_n
        local picked_idx = {}
        for i = 0, want_n - 1 do
            local idx = math.min(#pool, math.floor(i * step) + 1)
            if not picked_idx[idx] then
                picked_idx[idx] = true
                local item = pool[idx]
                if total + item.bytes <= byte_cap or #batch < 8 then
                    batch[#batch + 1] = item
                    total = total + item.bytes
                end
            end
        end
    end

    pick_even(large, 5, target_bytes * 0.65)
    pick_even(medium, 12, target_bytes)
    if #batch < 14 then
        for _, item in ipairs(medium) do
            if #batch >= 16 or total >= target_bytes then break end
            local dup = false
            for _, b in ipairs(batch) do if b.name == item.name then dup = true break end end
            if not dup then
                batch[#batch + 1] = item
                total = total + item.bytes
            end
        end
    end
    return batch, total
end

local function curl_quote(s)
    return '"' .. tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

M.EXTENDED_WRITE_OUT_TEMPLATE =
    "%{exitcode}\\t%{response_code}\\t%{ssl_verify_result}\\t%{time_queue}\\t%{time_namelookup}\\t%{time_connect}\\t%{time_appconnect}\\t%{time_starttransfer}\\t%{time_total}\\t%{size_download}\\t%{http_version}\\t%{remote_ip}\\t%{url_effective}\\t%header{content-length}\\t%header{content-range}\\t%header{content-encoding}\\t%header{last-modified}\\n"

function M.build_parallel_curl_config(items, opts)
    opts = opts or {}
    local limit = opts.limit or M.SCREEN_BYTES
    local max_filesize = opts.max_filesize or limit
    local connect_timeout = opts.connect_timeout or 3
    local max_time = opts.max_time or 5
    local speed_time = math.max(1, math.floor((tonumber(opts.speed_time) or 3) + 0.5))
    local speed_limit = math.max(1, math.floor(tonumber(opts.speed_limit) or 16384))
    local ua = opts.user_agent or M.USER_AGENT
    local use_range = opts.use_range ~= false
    local ipv4_only = opts.ipv4_only == true
    local head_only = opts.head_only == true

    local lines = {}
    for i, item in ipairs(items) do
        if i > 1 then
            lines[#lines + 1] = "next"
        end
        lines[#lines + 1] = "silent"
        lines[#lines + 1] = "show-error"
        lines[#lines + 1] = "location"
        if ipv4_only then
            lines[#lines + 1] = "ipv4"
        end
        if head_only then
            lines[#lines + 1] = "head"
        end
        lines[#lines + 1] = 'proto = "=https"'
        lines[#lines + 1] = 'proto-redir = "=https"'
        lines[#lines + 1] = "max-redirs = 3"
        lines[#lines + 1] = "connect-timeout = " .. tostring(connect_timeout)
        lines[#lines + 1] = "max-time = " .. tostring(max_time)
        if not head_only then
            lines[#lines + 1] = "speed-time = " .. tostring(speed_time)
            lines[#lines + 1] = "speed-limit = " .. tostring(speed_limit)
            if use_range then
                lines[#lines + 1] = "range = " .. curl_quote("0-" .. tostring(limit - 1))
            end
            if max_filesize and max_filesize > 0 then
                lines[#lines + 1] = "max-filesize = " .. tostring(max_filesize)
            end
        end
        lines[#lines + 1] = "user-agent = " .. curl_quote(ua)
        lines[#lines + 1] = "url = " .. curl_quote(item.url)
        lines[#lines + 1] = "output = " .. curl_quote(item.output or "/dev/null")
        lines[#lines + 1] = 'write-out = "' .. tostring(item.id) .. "\\t" .. M.EXTENDED_WRITE_OUT_TEMPLATE .. '"'
    end
    return table.concat(lines, "\n") .. "\n"
end

function M.parse_probe_line(line)
    if type(line) ~= "string" or line == "" then
        return nil
    end
    local fields = {}
    local start = 1
    while true do
        local pos = line:find("\t", start, true)
        if not pos then
            fields[#fields + 1] = line:sub(start)
            break
        end
        fields[#fields + 1] = line:sub(start, pos - 1)
        start = pos + 1
    end

    if #fields >= 18 then
        local id = tonumber(fields[1])
        local exitcode = tonumber(fields[2])
        local code = tonumber(fields[3])
        local ssl_verify = tonumber(fields[4])
        local time_queue = tonumber(fields[5])
        local time_dns = tonumber(fields[6])
        local time_conn = tonumber(fields[7])
        local time_tls = tonumber(fields[8])
        local ttfb = tonumber(fields[9])
        local elapsed = tonumber(fields[10])
        local size_dl = tonumber(fields[11])
        if not (id and exitcode and code and ssl_verify and time_queue and time_dns and ttfb and elapsed and size_dl) then
            return nil
        end
        return {
            id = id,
            exitcode = exitcode,
            code = code,
            ssl_verify = ssl_verify,
            time_queue = time_queue,
            time_namelookup = time_dns,
            time_connect = time_conn or 0,
            time_appconnect = time_tls or 0,
            ttfb = ttfb,
            elapsed = elapsed,
            size_download = size_dl,
            http_version = trim(fields[12]),
            remote_ip = trim(fields[13]),
            url_effective = trim(fields[14]),
            content_length = tonumber(trim(fields[15])),
            content_range = trim(fields[16]),
            content_encoding = trim(fields[17]):lower(),
            last_modified = trim(fields[18]),
        }
    end

    -- Backward-compatible 8-field format
    if #fields >= 8 then
        local id = tonumber(fields[1])
        local code = tonumber(fields[2])
        local elapsed = tonumber(fields[3])
        local ttfb = tonumber(fields[4])
        local size_dl = tonumber(fields[5])
        if not (id and code and elapsed and ttfb and size_dl) then
            return nil
        end
        return {
            id = id,
            exitcode = 0,
            code = code,
            ssl_verify = 0,
            time_queue = 0,
            time_namelookup = 0,
            time_connect = 0,
            time_appconnect = 0,
            ttfb = ttfb,
            elapsed = elapsed,
            size_download = size_dl,
            http_version = "",
            remote_ip = "",
            url_effective = "",
            content_length = nil,
            content_range = trim(fields[6]),
            content_encoding = trim(fields[7]):lower(),
            last_modified = trim(fields[8]),
        }
    end
    return nil
end

function M.validate_probe_sample(parsed, payload_len, magic_bytes, limit, max_time, opts)
    opts = opts or {}
    if not parsed then
        return nil
    end
    local allow_timeout = opts.allow_timeout == true
    if parsed.exitcode ~= 0 and not (allow_timeout and parsed.exitcode == 28) then
        return nil
    end
    if parsed.ssl_verify ~= 0 then
        return nil
    end
    if payload_len <= 0 or (limit and not allow_timeout and payload_len > limit) then
        return nil
    end
    if parsed.content_encoding ~= "" and parsed.content_encoding ~= "identity" then
        return nil
    end

    local total = nil
    if parsed.code == 206 then
        local end_b, total_b = M.parse_content_range(parsed.content_range)
        if not (end_b and total_b) then
            return nil
        end
        if not allow_timeout then
            if end_b + 1 ~= payload_len or payload_len ~= math.min(limit, total_b) then
                return nil
            end
        end
        total = total_b
    elseif parsed.code == 200 then
        if parsed.content_range ~= "" then
            return nil
        end
        if allow_timeout then
            total = parsed.content_length or payload_len
        else
            -- Guard against chunked 200 OK truncated by --max-filesize (exit 63 caught above, double-checked here)
            if parsed.content_length and parsed.content_length ~= payload_len then
                return nil
            end
            if parsed.size_download ~= payload_len then
                return nil
            end
            if limit and payload_len == limit and parsed.content_length ~= limit then
                return nil
            end
            total = payload_len
        end
    else
        return nil
    end

    if magic_bytes ~= false and not M.is_valid_pacman_db_magic(magic_bytes) then
        return nil
    end

    local t_queue = math.max(0, parsed.time_queue or 0)
    local net_elapsed = math.max(0.002, (parsed.elapsed or 0) - t_queue)
    if parsed.elapsed <= 0 or net_elapsed > ((max_time or 12) + 2.0) then
        return nil
    end
    local t_start = math.max(0, (parsed.ttfb or 0) - t_queue)
    local pure_ttfb_s = math.max(0, (parsed.ttfb or 0) - math.max(t_queue, parsed.time_namelookup or 0))
    local wire_dt = math.max(0.002, (parsed.elapsed or 0) - (parsed.ttfb or 0))

    local wire_mbps = (payload_len * 8.0) / (wire_dt * 1e6)
    local eff_mbps = (payload_len * 8.0) / (net_elapsed * 1e6)

    return {
        elapsed = net_elapsed,
        wire_dt = wire_dt,
        ttfb_ms = pure_ttfb_s * 1000.0,
        start_ms = t_start * 1000.0,
        bytes = payload_len,
        total_bytes = total,
        modified = M.parse_http_date(parsed.last_modified),
        mbps = eff_mbps,
        wire_mbps = wire_mbps,
        url_effective = parsed.url_effective or "",
        http_version = parsed.http_version or "",
        remote_ip = parsed.remote_ip or "",
    }
end

-- Split streamed (t_i, bytes_i) checkpoints into 4 equal time quartiles Q1..Q4.
-- Discards Q1 (TCP slow-start / initial burst) and detects burst-shaping.
function M.analyze_stream_quartiles(checkpoints, total_wire_dt, total_bytes)
    local fallback_mbps = (total_bytes * 8.0) / (math.max(total_wire_dt or 0.01, 0.002) * 1e6)
    if type(checkpoints) ~= "table" or #checkpoints < 4 or not total_wire_dt or total_wire_dt < 0.25 then
        return {
            quartiles = { fallback_mbps, fallback_mbps, fallback_mbps, fallback_mbps },
            steady_mbps = fallback_mbps,
            burst_ratio = 1.0,
            burst_throttled = false,
            intra_jitter = 0.0,
        }
    end

    local t_end = checkpoints[#checkpoints].t
    if t_end < 0.25 then
        t_end = total_wire_dt
    end

    local function interp_bytes(target_t)
        if target_t <= 0 then return 0 end
        local prev_t, prev_b = 0.0, 0
        for _, cp in ipairs(checkpoints) do
            if cp.t >= target_t then
                local span = cp.t - prev_t
                if span <= 1e-6 then
                    return cp.bytes
                end
                local frac = (target_t - prev_t) / span
                return prev_b + (cp.bytes - prev_b) * frac
            end
            prev_t, prev_b = cp.t, cp.bytes
        end
        return total_bytes
    end

    local b0 = 0
    local b1 = interp_bytes(t_end * 0.25)
    local b2 = interp_bytes(t_end * 0.50)
    local b3 = interp_bytes(t_end * 0.75)
    local b4 = math.max(b3, total_bytes)
    local qdt = t_end * 0.25

    local r1 = math.max(0, (b1 - b0) * 8.0 / (qdt * 1e6))
    local r2 = math.max(0, (b2 - b1) * 8.0 / (qdt * 1e6))
    local r3 = math.max(0, (b3 - b2) * 8.0 / (qdt * 1e6))
    local r4 = math.max(0, (b4 - b3) * 8.0 / (qdt * 1e6))

    local steady = M.median({ r2, r3, r4 }) or fallback_mbps
    local tail_med = M.median({ r3, r4 }) or steady
    local burst_ratio = tail_med / math.max(r1, 0.001)
    local burst_throttled = (burst_ratio < 0.45) and (r1 > 2.0 * steady) and (steady > 0)

    local qmin = math.min(r2, r3, r4)
    local qmax = math.max(r2, r3, r4)
    local intra_jitter = (qmax - qmin) / (2.0 * math.max(steady, 0.01))

    return {
        quartiles = { r1, r2, r3, r4 },
        steady_mbps = steady,
        burst_ratio = burst_ratio,
        burst_throttled = burst_throttled,
        intra_jitter = intra_jitter,
    }
end

-- Determine freshest corroborated Last-Modified timestamp (protects against future clock skew).
function M.compute_freshest_timestamp(valid_list, now_ts)
    now_ts = now_ts or os.time()
    local all_ts = {}
    local sane_ts = {}
    for _, item in ipairs(valid_list) do
        local m = item.sample.modified
        if m then
            all_ts[#all_ts + 1] = { ts = m, host = M.canonical_host(item.url) }
            if m <= now_ts + 600 then
                sane_ts[#sane_ts + 1] = { ts = m, host = M.canonical_host(item.url) }
            end
        end
    end
    if #all_ts == 0 then
        return nil
    end
    -- If >= 80% appear "in the future", host clock is probably behind; use all_ts.
    local pool = (#sane_ts >= #all_ts * 0.20 and #sane_ts > 0) and sane_ts or all_ts
    table.sort(pool, function(a, b) return a.ts > b.ts end)

    -- Require >= 2 distinct hosts within 3600s if >= 2 distinct hosts exist
    local distinct_hosts = {}
    local host_count = 0
    for _, e in ipairs(pool) do
        if not distinct_hosts[e.host] then
            distinct_hosts[e.host] = true
            host_count = host_count + 1
        end
    end
    if host_count < 2 then
        return pool[1].ts
    end

    for i = 1, #pool do
        local cand = pool[i]
        for j = i + 1, #pool do
            if pool[j].host ~= cand.host and (cand.ts - pool[j].ts) <= 3600 then
                return cand.ts
            end
        end
    end
    return pool[1].ts
end

function M.filter_and_shortlist(samples_by_url, opts)
    opts = opts or {}
    local stale_window = opts.stale_window or M.STALE_WINDOW_SEC
    local size_tol = opts.size_tolerance or M.SIZE_TOLERANCE
    local limit = opts.shortlist or 24
    local force_include = opts.force_include or {}
    local now_ts = opts.now_ts or os.time()

    local valid_list = {}
    local totals = {}
    for url, s in pairs(samples_by_url) do
        if s and s.total_bytes and s.total_bytes > 0 then
            valid_list[#valid_list + 1] = { url = url, sample = s }
            totals[#totals + 1] = s.total_bytes
        end
    end

    if #valid_list == 0 then
        return {}, { freshest = nil, median_size = nil, eligible_count = 0, rejected_stale = 0, rejected_size = 0 }
    end

    local freshest = M.compute_freshest_timestamp(valid_list, now_ts)
    local med_size = M.median(totals)
    local lo_size = med_size * (1.0 - size_tol)
    local hi_size = med_size * (1.0 + size_tol)

    local eligible = {}
    local rejected_stale = 0
    local rejected_size = 0
    for _, item in ipairs(valid_list) do
        local s = item.sample
        local fresh_ok = true
        if freshest ~= nil then
            if s.modified == nil or s.modified < (freshest - stale_window) then
                fresh_ok = false
            end
        end
        local size_ok = (s.total_bytes >= lo_size and s.total_bytes <= hi_size)
        if not fresh_ok then
            rejected_stale = rejected_stale + 1
        elseif not size_ok then
            rejected_size = rejected_size + 1
        else
            local wire = s.wire_mbps or s.mbps or 0
            local ttfb_s = (s.ttfb_ms or 0) / 1000.0
            -- High-RTT / High-BW safe screening score
            item.screen_score = wire / (1.0 + ttfb_s / 0.25)
            eligible[#eligible + 1] = item
        end
    end

    table.sort(eligible, function(a, b)
        if math.abs(a.screen_score - b.screen_score) > 1e-6 then
            return a.screen_score > b.screen_score
        end
        if math.abs((a.sample.ttfb_ms or 0) - (b.sample.ttfb_ms or 0)) > 1e-6 then
            return (a.sample.ttfb_ms or 0) < (b.sample.ttfb_ms or 0)
        end
        return a.url < b.url
    end)

    -- Deduplicate by canonical host & effective redirect host
    local picked = {}
    local seen_url = {}
    local seen_host = {}
    local seen_eff = {}
    local eligible_by_url = {}
    for _, e in ipairs(eligible) do
        eligible_by_url[e.url] = e
    end

    local function try_add(e)
        if not e or seen_url[e.url] then return false end
        local h = M.canonical_host(e.url)
        local eh = (e.sample.url_effective and e.sample.url_effective ~= "")
            and M.canonical_host(e.sample.url_effective) or h
        if seen_host[h] or seen_eff[eh] then
            return false
        end
        seen_url[e.url] = true
        seen_host[h] = true
        seen_eff[eh] = true
        picked[#picked + 1] = e.url
        return true
    end

    for _, e in ipairs(eligible) do
        if #picked >= limit then break end
        try_add(e)
    end
    for _, inc_url in ipairs(force_include) do
        if inc_url and eligible_by_url[inc_url] and not seen_url[inc_url] then
            seen_url[inc_url] = true
            picked[#picked + 1] = inc_url
        end
    end

    return picked, {
        freshest = freshest,
        median_size = med_size,
        eligible_count = #eligible,
        rejected_stale = rejected_stale,
        rejected_size = rejected_size,
    }
end

function M.score_mirror(entry, opts)
    opts = opts or {}
    local pd = opts.parallel_downloads or 5
    local b1 = entry.b1_mbps or entry.mbps or 0
    local b4 = entry.b4_mbps
    local b_eff
    if pd >= 2 and type(b4) == "number" and b4 > 0 then
        b_eff = 0.35 * b1 + 0.65 * b4
    else
        b_eff = b1
    end
    local ttfb_ms = math.max(0, entry.ttfb_ms or 0)
    local b_workload = b_eff / (1.0 + (ttfb_ms / 1000.0) * (b_eff / M.CANONICAL_WORKLOAD_MBIT))

    local inter_j = entry.inter_jitter or 0
    local intra_j = entry.intra_jitter or 0
    local sigma_rel = math.min(0.50, math.max(inter_j, 0.5 * intra_j))
    local s_stab = 1.0 / (1.0 + 0.30 * math.max(0.0, sigma_rel - 0.10))
    local burst_pen = entry.burst_throttled and 0.85 or 1.00
    local score = b_workload * s_stab * burst_pen

    return {
        b_eff = b_eff,
        b_workload = b_workload,
        s_stab = s_stab,
        score = score,
        scaling_ratio = (b4 and b1 > 0) and (b4 / b1) or nil,
    }
end

function M.rank_deep_results(deep_by_url, current_servers, opts)
    opts = opts or {}
    local margin = opts.margin or M.IMPROVEMENT_MARGIN
    local force = opts.force == true
    local min_samples = opts.min_samples or 2
    local keep_top = opts.keep_top or 8
    local size_tol = opts.size_tolerance or M.SIZE_TOLERANCE
    local anchor_size = opts.anchor_size
    local multi_by_url = opts.multi_by_url or {}
    local pd = opts.parallel_downloads or 5

    local aggregated = {}
    local all_totals = {}
    for url, runs in pairs(deep_by_url) do
        if type(runs) == "table" and #runs >= min_samples then
            local steady_vals, ttfb_vals, size_vals, intra_vals = {}, {}, {}, {}
            local burst_hits = 0
            local eff_url = ""
            for _, r in ipairs(runs) do
                local sm = r.steady_mbps or r.mbps or 0
                steady_vals[#steady_vals + 1] = sm
                ttfb_vals[#ttfb_vals + 1] = r.ttfb_ms or 0
                if r.total_bytes and r.total_bytes > 0 then
                    size_vals[#size_vals + 1] = r.total_bytes
                end
                if r.intra_jitter then
                    intra_vals[#intra_vals + 1] = r.intra_jitter
                end
                if r.burst_throttled then
                    burst_hits = burst_hits + 1
                end
                if eff_url == "" and r.url_effective and r.url_effective ~= "" then
                    eff_url = r.url_effective
                end
            end
            local b1 = M.median(steady_vals) or 0
            local b1_min, b1_max = steady_vals[1], steady_vals[1]
            for _, v in ipairs(steady_vals) do
                if v < b1_min then b1_min = v end
                if v > b1_max then b1_max = v end
            end
            local inter_j = (b1_max - b1_min) / (2.0 * math.max(b1, 0.01))
            local intra_j = M.median(intra_vals) or 0
            local med_total = M.median(size_vals)
            if med_total then all_totals[#all_totals + 1] = med_total end

            local b4 = nil
            local mruns = multi_by_url[url]
            if type(mruns) == "table" and #mruns > 0 then
                b4 = M.median(mruns)
            end

            local entry = {
                url = url,
                url_effective = eff_url,
                mbps = b1,
                b1_mbps = b1,
                b4_mbps = b4,
                ttfb_ms = M.median(ttfb_vals) or 0,
                total_bytes = med_total,
                samples = #runs,
                inter_jitter = inter_j,
                intra_jitter = intra_j,
                burst_throttled = (burst_hits >= math.ceil(#runs / 2)),
            }
            local sc = M.score_mirror(entry, { parallel_downloads = pd })
            entry.b_eff = sc.b_eff
            entry.score = sc.score
            entry.scaling_ratio = sc.scaling_ratio
            aggregated[#aggregated + 1] = entry
        end
    end

    if #aggregated == 0 then
        return {
            ranked = {},
            changed = false,
            urgent = false,
            reason = "no mirrors passed saturation benchmark",
        }
    end

    -- Anchor size filter to Phase 1 median if supplied; otherwise filter only if >= 3 entries share a cluster
    local ref_size = anchor_size or (#all_totals >= 3 and M.median(all_totals) or nil)
    local filtered = {}
    if ref_size and ref_size > 0 then
        local lo, hi = ref_size * (1.0 - size_tol), ref_size * (1.0 + size_tol)
        for _, item in ipairs(aggregated) do
            if not item.total_bytes or (item.total_bytes >= lo and item.total_bytes <= hi) then
                filtered[#filtered + 1] = item
            end
        end
    else
        filtered = aggregated
    end

    table.sort(filtered, function(a, b)
        if math.abs(a.score - b.score) > 1e-6 then
            return a.score > b.score
        end
        if math.abs(a.ttfb_ms - b.ttfb_ms) > 1e-6 then
            return a.ttfb_ms < b.ttfb_ms
        end
        return a.url < b.url
    end)

    -- Deduplicate by canonical host & effective host
    local deduped = {}
    local seen_h, seen_eh = {}, {}
    for _, item in ipairs(filtered) do
        local h = M.canonical_host(item.url)
        local eh = (item.url_effective and item.url_effective ~= "") and M.canonical_host(item.url_effective) or h
        if not seen_h[h] and not seen_eh[eh] then
            seen_h[h] = true
            seen_eh[eh] = true
            deduped[#deduped + 1] = item
        end
    end
    filtered = deduped

    if #filtered == 0 then
        return {
            ranked = {},
            changed = false,
            urgent = false,
            reason = "no mirrors matched expected DB/package size",
        }
    end

    local current_primary = type(current_servers) == "table" and current_servers[1] or nil
    local current_entry = nil
    local current_idx = nil
    for i, item in ipairs(filtered) do
        if item.url == current_primary then
            current_entry = item
            current_idx = i
            break
        end
    end

    local best = filtered[1]
    local kept_current = false
    local urgent = false
    local gain_pct = nil

    if current_primary and not current_entry then
        -- Current #1 failed validation / freshness / secondary repos -> urgent replacement
        urgent = true
    elseif current_entry and best.url ~= current_primary then
        gain_pct = ((best.score - current_entry.score) / math.max(current_entry.score, 0.01)) * 100.0
        if not force and best.score < current_entry.score * (1.0 + margin) then
            table.remove(filtered, current_idx)
            table.insert(filtered, 1, current_entry)
            kept_current = true
        end
    elseif current_entry and best.url == current_primary then
        gain_pct = 0.0
        kept_current = true
    end

    local top = {}
    for i = 1, math.min(keep_top, #filtered) do
        top[#top + 1] = filtered[i]
    end

    local changed = urgent or ((not kept_current) and (top[1].url ~= current_primary))
    return {
        ranked = top,
        current_primary = current_primary,
        current_mbps = current_entry and current_entry.b_eff or nil,
        current_score = current_entry and current_entry.score or nil,
        best_mbps = top[1].b_eff,
        best_score = top[1].score,
        gain_pct = gain_pct,
        kept_current = kept_current,
        urgent = urgent,
        changed = changed,
    }
end

function M.render_mirrorlist(group, rank_res, current_servers, opts)
    opts = opts or {}
    local stamp = opts.timestamp or os.date("!%Y-%m-%d %H:%M:%S UTC")
    local lines = {
        "# Generated by kaze-mirror " .. M.VERSION .. " (" .. stamp .. ")",
        "# Group: " .. group.basename .. " (repos: " .. table.concat(group.repos, ", ") .. ")",
        "",
    }
    local seen_url = {}
    local seen_host = {}
    for _, item in ipairs(rank_res.ranked or {}) do
        local h = M.canonical_host(item.url)
        if M.is_safe_https_url(item.url) and not seen_url[item.url] and not seen_host[h] then
            seen_url[item.url] = true
            seen_host[h] = true
            local b4_part = item.b4_mbps and string.format(" | 4x %.1f Mbps", item.b4_mbps) or ""
            local burst_part = item.burst_throttled and " | BURST-THROTTLED" or ""
            lines[#lines + 1] = string.format(
                "# Score %.1f | 1x %.1f Mbps%s | TTFB %.0f ms%s",
                item.score or item.mbps or 0, item.b1_mbps or item.mbps or 0, b4_part, item.ttfb_ms or 0, burst_part
            )
            lines[#lines + 1] = "Server = " .. item.url
        end
    end

    local fallbacks = {}
    for _, url in ipairs(current_servers or {}) do
        local h = M.canonical_host(url)
        if M.is_safe_https_url(url) and not seen_url[url] and not seen_host[h] then
            seen_url[url] = true
            seen_host[h] = true
            fallbacks[#fallbacks + 1] = url
        end
    end
    if #fallbacks > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "# Previous mirrors kept as fallback"
        for i = 1, math.min(6, #fallbacks) do
            lines[#lines + 1] = "Server = " .. fallbacks[i]
        end
    end

    return table.concat(lines, "\n") .. "\n"
end

function M.mirrorlist_servers_changed(rendered_text, current_servers)
    local new_active = M.parse_mirrorlist_servers(rendered_text)
    local cur = type(current_servers) == "table" and current_servers or {}
    if #new_active ~= #cur then
        return true
    end
    for i = 1, #new_active do
        if new_active[i] ~= cur[i] then
            return true
        end
    end
    return false
end

function M.validate_mirrorlist_text(text)
    if type(text) ~= "string" or text == "" then
        return false, "mirrorlist content is empty"
    end
    if text:find("\0", 1, true) then
        return false, "mirrorlist contains NUL bytes"
    end
    local server_count = 0
    local line_no = 0
    for raw_line in (text .. "\n"):gmatch("(.-)\r?\n") do
        line_no = line_no + 1
        local line = trim(raw_line)
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local url = line:match("^Server%s*=%s*(%S+)$")
            if not url or not M.is_safe_https_url(url) then
                return false, string.format("invalid line %d: %s", line_no, line)
            end
            server_count = server_count + 1
        end
    end
    if server_count == 0 then
        return false, "mirrorlist contains zero active Server entries"
    end
    return true, server_count
end

-- Build isolated temp pacman.conf for Stage 3 fakeroot pacman -Sw trials.
-- Optionally redirects Include = <orig_path> to staged winning mirrorlist paths.
function M.build_temp_pacman_conf(base_conf_text, parallel_downloads, mirrorlist_overrides)
    mirrorlist_overrides = mirrorlist_overrides or {}
    local out = {}
    local set_pd = false
    for raw_line in (strip_bom(base_conf_text) .. "\n"):gmatch("(.-)\r?\n") do
        local s = trim(raw_line)
        if s:match("^#?%s*ParallelDownloads%s*=") then
            if not set_pd then
                out[#out + 1] = "ParallelDownloads = " .. tostring(parallel_downloads)
                set_pd = true
            end
        elseif s:match("^CheckSpace%s*$")
            or s:match("^DisableDownloadTimeout%s*$")
            or s:match("^UseSyslog%s*$")
            or s:match("^DownloadUser%s*=")
            or s:match("^XferCommand%s*=")
        then
            -- omitted for isolated temp cache benchmark
        elseif s:match("^SigLevel%s*=") then
            out[#out + 1] = "SigLevel = Never"
        else
            local inc = s:match("^Include%s*=%s*(.+)$")
            if inc and mirrorlist_overrides[trim(inc)] then
                out[#out + 1] = "Include = " .. mirrorlist_overrides[trim(inc)]
            else
                out[#out + 1] = raw_line
            end
        end
    end
    if not set_pd then
        local inserted = {}
        local done = false
        for _, line in ipairs(out) do
            inserted[#inserted + 1] = line
            if not done and trim(line) == "[options]" then
                inserted[#inserted + 1] = "ParallelDownloads = " .. tostring(parallel_downloads)
                done = true
            end
        end
        out = inserted
    end
    if #out > 0 and out[#out] == "" then
        out[#out] = nil
    end
    return table.concat(out, "\n") .. "\n"
end

-- Safely update ParallelDownloads inside [options] (comments out any duplicate active lines).
function M.update_pacman_conf_parallel_downloads(base_conf_text, new_pd)
    local pd = math.floor(tonumber(new_pd) or 0)
    if pd < 1 or pd > 32 then
        return nil, "ParallelDownloads must be between 1 and 32"
    end
    local out = {}
    local in_options = false
    local saw_options = false
    local replaced = false

    for raw_line in (strip_bom(base_conf_text) .. "\n"):gmatch("(.-)\r?\n") do
        local s = trim(raw_line)
        local sec = s:match("^%[([^%]]+)%]$")
        if sec then
            in_options = (trim(sec) == "options")
            if in_options then saw_options = true end
            out[#out + 1] = raw_line
        elseif in_options and s:match("^ParallelDownloads%s*=") then
            if not replaced then
                out[#out + 1] = "ParallelDownloads = " .. tostring(pd)
                replaced = true
            else
                out[#out + 1] = "# " .. s
            end
        elseif in_options and not replaced and s:match("^#%s*ParallelDownloads%s*=") then
            out[#out + 1] = "ParallelDownloads = " .. tostring(pd)
            replaced = true
        else
            out[#out + 1] = raw_line
        end
    end
    if #out > 0 and out[#out] == "" then
        out[#out] = nil
    end
    if not saw_options then
        return nil, "could not find [options] section in pacman.conf"
    end
    if not replaced then
        local inserted = {}
        local done = false
        for _, line in ipairs(out) do
            inserted[#inserted + 1] = line
            if not done and trim(line) == "[options]" then
                inserted[#inserted + 1] = "ParallelDownloads = " .. tostring(pd)
                done = true
            end
        end
        out = inserted
    end
    return table.concat(out, "\n") .. "\n"
end

-- Strict allowlist for root commit targets (blocks traversal, dotfiles, .pacnew, backups, subdirs).
function M.is_allowed_commit_path(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    if path:find("..", 1, true) or path:find("[%c%s]") then
        return false
    end
    if path == "/etc/pacman.conf" then
        return true
    end
    local base = path:match("^/etc/pacman%.d/([^/]+)$")
    if not base or base == "" then
        return false
    end
    if base:sub(1, 1) == "." or not base:match("^[%w][%w%._%-]*$") then
        return false
    end
    if base == "gnupg" or base == "hooks" then
        return false
    end
    if base:match("%.pacnew$") or base:match("%.pacsave$")
        or base:match("%.kaze%-bak%-") or base:match("%.bak%-")
        or base:match("%-backup$") or base:match("%.backup%-")
    then
        return false
    end
    return true
end

function M.escape_lua_pattern(s)
    return (tostring(s or ""):gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

-- Filter and sort backup filenames belonging strictly to `<base>.kaze-bak-<YYYYMMDD_HHMMSS>[.N]`.
function M.select_prunable_backups(base_name, filenames, keep_n)
    keep_n = keep_n or M.MAX_BACKUPS
    local pat = "^" .. M.escape_lua_pattern(base_name) .. "%.kaze%-bak%-%d%d%d%d%d%d%d%d_%d%d%d%d%d%d"
    local matched = {}
    for _, name in ipairs(filenames or {}) do
        if type(name) == "string" and name:match(pat) then
            matched[#matched + 1] = name
        end
    end
    table.sort(matched, function(a, b) return a > b end) -- newest first
    local prune = {}
    for i = keep_n + 1, #matched do
        prune[#prune + 1] = matched[i]
    end
    return prune, matched
end

function M.format_mbps_bar(mbps, max_mbps, width, ascii_only)
    width = width or 14
    local denom = (type(max_mbps) == "number" and max_mbps > 0) and max_mbps or 1.0
    local ratio = math.max(0.0, math.min(1.0, (tonumber(mbps) or 0) / denom))
    local filled = math.floor(ratio * width + 0.5)
    local full_ch = ascii_only and "#" or "█"
    local empty_ch = ascii_only and "." or "░"
    return string.rep(full_ch, filled) .. string.rep(empty_ch, width - filled)
end

function M.format_group_table(group, rank_res)
    local lines = {}
    lines[#lines + 1] = string.format("== %s (%s) ==", group.basename, table.concat(group.repos, ", "))
    if not rank_res or not rank_res.ranked or #rank_res.ranked == 0 then
        lines[#lines + 1] = "  (no eligible mirrors found: " .. tostring(rank_res and rank_res.reason or "unknown") .. ")"
        return table.concat(lines, "\n")
    end

    lines[#lines + 1] = string.format("  %-3s  %-30s  %8s  %8s  %8s  %7s  %s",
        "#", "Host", "1x Mbps", "4x Mbps", "Score", "TTFB", "Status")
    lines[#lines + 1] = "  " .. string.rep("-", 84)
    for idx, item in ipairs(rank_res.ranked) do
        local host = M.canonical_host(item.url)
        if #host > 30 then
            host = host:sub(1, 27) .. "..."
        end
        local b4_str = item.b4_mbps and string.format("%7.1f", item.b4_mbps) or "    -  "
        local tags = {}
        if item.url == rank_res.current_primary then
            tags[#tags + 1] = idx == 1 and "CURRENT" or "current"
        elseif idx == 1 then
            tags[#tags + 1] = rank_res.urgent and "URGENT #1" or (rank_res.changed and "NEW #1" or "top")
        end
        if item.burst_throttled then
            tags[#tags + 1] = "BURST"
        end
        lines[#lines + 1] = string.format(
            "  %-3d  %-30s  %7.1f   %s   %7.1f   %4.0fms  %s",
            idx, host, item.b1_mbps or item.mbps or 0, b4_str, item.score or 0, item.ttfb_ms or 0, table.concat(tags, " ")
        )
    end
    if rank_res.urgent then
        lines[#lines + 1] = "  Decision: URGENT UPDATE (current #1 failed/stale) -> " .. M.canonical_host(rank_res.ranked[1].url)
    elseif rank_res.kept_current and rank_res.gain_pct and rank_res.gain_pct > 0 then
        lines[#lines + 1] = string.format(
            "  Decision: keeping current #1 (best +%.1f%% < %.0f%% margin; pass --force to switch)",
            rank_res.gain_pct, M.IMPROVEMENT_MARGIN * 100
        )
    elseif rank_res.changed then
        local delta = rank_res.gain_pct and string.format(" (+%.1f%%)", rank_res.gain_pct) or ""
        lines[#lines + 1] = "  Decision: recommend switching #1 to " .. M.canonical_host(rank_res.ranked[1].url) .. delta
    else
        lines[#lines + 1] = "  Decision: current #1 is already the fastest verified mirror"
    end
    return table.concat(lines, "\n")
end

function M.menu_entries(opts)
    opts = opts or {}
    local entries = {}
    if opts.active_running then
        entries[#entries + 1] = { id = "focus", label = "󰆍  Focus Active Mirror Optimizer" }
    end
    entries[#entries + 1] = { id = "tui",      label = "󰆍  Open Mirror Optimizer (TUI)" }
    entries[#entries + 1] = { id = "fast-dry", label = "󰓅  Quick Mirror Scan & Auto-Apply (Fast)" }
    entries[#entries + 1] = { id = "deep-dry", label = "󰑓  Deep Saturation Scan & Auto-Apply" }
    entries[#entries + 1] = { id = "bench",    label = "󰔟  Full Benchmark & Auto-Apply (Mirrors + ParallelDownloads)" }
    local bak_n = tonumber(opts.backup_count) or 0
    local rb_label = bak_n > 0
        and string.format("󰕌  Rollback Mirror Backup… (%d available)", bak_n)
        or "󰕌  Rollback Mirror Backup…"
    entries[#entries + 1] = { id = "rollback", label = rb_label }
    return entries
end

return M
