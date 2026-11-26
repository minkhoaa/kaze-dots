-- Pure-Lua Elm/TEA 5-screen Omarchy ANSI TUI for kaze-mirror.
-- Uses 16-color ANSI only (zero hardcoded RGB/256), UTF-8 exact column width,
-- synchronized frame flush (\033[?2026h), and clean cooked-TTY handoff for sudo.

local mirror = require("kaze.mirror")

local M = {}

M.DASHBOARD_ACTIONS = {
    { id = "fast-dry", title = "Quick Mirror Scan & Apply",          desc = "Upfront sudo -> 128 KiB screen -> 4 MiB warmup -> 2x sustained -> auto-apply" },
    { id = "deep-dry", title = "Deep Saturation Scan & Apply",       desc = "Upfront sudo -> 128 KiB screen -> 8 MiB warmup -> 3x sustained -> auto-apply" },
    { id = "bench",    title = "Full Benchmark + ParallelDownloads", desc = "Upfront sudo -> deep scan + pacman -Sw A/B -> auto-apply full" },
    { id = "rollback", title = "Rollback Backup…",                   desc = "Inspect & atomically restore last committed transaction" },
}

function M.strip_ansi(s)
    return (tostring(s or ""):gsub("\27%[[0-9;?]*[A-Za-z]", ""))
end

function M.display_width(s)
    local plain = M.strip_ansi(s)
    local len = utf8.len(plain)
    if len then
        return len
    end
    return #plain
end

function M.clip_utf8(s, max_cols, ascii_only)
    s = tostring(s or "")
    if max_cols <= 0 then
        return ""
    end
    local len = utf8.len(s)
    if not len then
        if #s <= max_cols then return s end
        return s:sub(1, max_cols)
    end
    if len <= max_cols then
        return s
    end
    local ell = ascii_only and ".." or "…"
    local ell_w = ascii_only and 2 or 1
    if max_cols <= ell_w then
        local off = utf8.offset(s, max_cols + 1)
        return off and s:sub(1, off - 1) or s
    end
    local keep = max_cols - ell_w
    local off = utf8.offset(s, keep + 1)
    return (off and s:sub(1, off - 1) or s) .. ell
end

function M.parse_key_sequence(raw)
    if type(raw) ~= "string" or raw == "" then
        return "EOF"
    end
    if raw == "\27" then return "ESC" end
    if raw == "\27[A" or raw == "\27OA" then return "UP" end
    if raw == "\27[B" or raw == "\27OB" then return "DOWN" end
    if raw == "\27[C" or raw == "\27OC" then return "RIGHT" end
    if raw == "\27[D" or raw == "\27OD" then return "LEFT" end
    if raw == "\27[Z" then return "SHIFT_TAB" end
    if raw == "\27[5~" then return "PGUP" end
    if raw == "\27[6~" then return "PGDN" end
    if raw == "\27[H" or raw == "\27OH" then return "HOME" end
    if raw == "\27[F" or raw == "\27OF" then return "END" end
    if raw:sub(1, 1) == "\27" then return "IGNORE" end

    if raw == "\r" or raw == "\n" then return "ENTER" end
    if raw == " " then return "SPACE" end
    if raw == "\t" then return "TAB" end
    if raw == "\127" or raw == "\8" then return "BACKSPACE" end
    if raw == "\3" then return "CTRL_C" end
    if raw == "k" or raw == "K" then return "UP" end
    if raw == "j" or raw == "J" then return "DOWN" end
    if raw == "h" or raw == "H" then return "LEFT" end
    if raw == "l" or raw == "L" then return "RIGHT" end
    return raw:lower()
end

function M.initial_state(snapshot)
    snapshot = snapshot or {}
    return {
        screen = "dashboard",
        selected = 1,
        force = snapshot.force == true,
        groups = snapshot.groups or {},
        skipped_repos = snapshot.skipped_repos or {},
        parallel_downloads = snapshot.parallel_downloads or 5,
        timers = snapshot.timers or {},
        backup_count = snapshot.backup_count or 0,
        rollback_tx = snapshot.rollback_tx,
        status_msg = snapshot.status_msg or "",
        status_kind = snapshot.status_kind or "info", -- info | ok | warn | err
        -- Progress state
        scan_mode = nil,
        progress = {
            pct = 0,
            phase = "",
            group_status = {},
            leaders = {},
            logs = {},
            elapsed = 0,
        },
        -- Results state
        results = {
            tabs = {},
            active_tab = 1,
            scroll = 0,
            selected_apply = {}, -- [tab_idx] = bool
            raw_groups = {},
            pd_result = nil,
            bench_pre = nil,
            auto_applied = false,
        },
        -- Confirm state
        confirm = {
            is_rollback = false,
            items = {},
            error_msg = nil,
            return_screen = "results",
        },
        -- Rollback picker state
        rollback_selected = 1,
    }
end

local function deepcopy_shallow(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

local function rebuild_results_tabs(state)
    local tabs = {}
    local sel_apply = {}
    local prev_sel = state.results.selected_apply or {}
    for idx, g in ipairs(state.results.raw_groups or {}) do
        local reranked = g.deep_by_url
            and mirror.rank_deep_results(g.deep_by_url, g.current_servers, {
                force = state.force,
                min_samples = g.min_samples or 2,
                anchor_size = g.anchor_size,
                multi_by_url = g.multi_by_url,
                parallel_downloads = state.parallel_downloads,
            })
            or g.rank_res
        local tab = {
            kind = "mirrorlist",
            group = g.group,
            current_servers = g.current_servers,
            rank_res = reranked,
        }
        tabs[#tabs + 1] = tab
        if prev_sel[idx] ~= nil then
            sel_apply[idx] = prev_sel[idx] and (reranked and reranked.changed == true)
        else
            sel_apply[idx] = (reranked and reranked.changed == true) or false
        end
    end
    if state.results.pd_result and state.results.pd_result.ok then
        local pd = state.results.pd_result
        local pd_idx = #tabs + 1
        tabs[pd_idx] = {
            kind = "pacman_conf",
            pd = pd,
            pre = state.results.bench_pre,
        }
        if prev_sel[pd_idx] ~= nil then
            sel_apply[pd_idx] = prev_sel[pd_idx] and (pd.changed == true)
        else
            sel_apply[pd_idx] = (pd.changed == true)
        end
    end
    state.results.tabs = tabs
    state.results.selected_apply = sel_apply
    if state.results.active_tab > #tabs then
        state.results.active_tab = math.max(1, #tabs)
    end
end

local function build_confirm_items(state)
    local items = {}
    for idx, tab in ipairs(state.results.tabs or {}) do
        if state.results.selected_apply[idx] then
            if tab.kind == "mirrorlist" and tab.rank_res and tab.rank_res.changed and #tab.rank_res.ranked > 0 then
                local old_h = tab.rank_res.current_primary and mirror.canonical_host(tab.rank_res.current_primary) or "(none)"
                local new_h = mirror.canonical_host(tab.rank_res.ranked[1].url)
                items[#items + 1] = {
                    kind = "mirrorlist",
                    path = tab.group.path,
                    group = tab.group,
                    rank_res = tab.rank_res,
                    current_servers = tab.current_servers,
                    summary = string.format("%s -> %s", old_h, new_h),
                }
            elseif tab.kind == "pacman_conf" and tab.pd and tab.pd.changed then
                items[#items + 1] = {
                    kind = "pacman_conf",
                    path = "/etc/pacman.conf",
                    parallel_downloads = tab.pd.recommended_pd,
                    summary = string.format("ParallelDownloads: %d -> %d", tab.pd.current_pd, tab.pd.recommended_pd),
                }
            end
        end
    end
    return items
end

function M.reduce(state, event)
    if type(event) ~= "table" then
        return state, nil
    end
    local etype = event.type

    if etype == "snapshot" then
        local snap = event.snapshot or {}
        state.groups = snap.groups or state.groups
        state.skipped_repos = snap.skipped_repos or state.skipped_repos
        state.parallel_downloads = snap.parallel_downloads or state.parallel_downloads
        state.timers = snap.timers or state.timers
        state.backup_count = snap.backup_count or 0
        state.rollback_tx = snap.rollback_tx
        if event.msg then
            state.status_msg = event.msg
            state.status_kind = event.kind or "info"
        end
        return state, nil
    end

    if etype == "progress" then
        state.screen = "progress"
        local p = state.progress
        local pct_num = tonumber(event.pct)
        if pct_num ~= nil then p.pct = math.max(0, math.min(100, pct_num)) end
        if type(event.phase) == "string" then p.phase = event.phase end
        local el_num = tonumber(event.elapsed)
        if el_num ~= nil then p.elapsed = el_num end
        if type(event.group_status) == "table" then p.group_status = event.group_status end
        if type(event.leaders) == "table" then p.leaders = event.leaders end
        if type(event.log_line) == "string" then
            p.logs[#p.logs + 1] = event.log_line
            while #p.logs > 5 do
                table.remove(p.logs, 1)
            end
        end
        return state, nil
    end

    if etype == "scan_complete" then
        state.results.raw_groups = event.raw_groups or {}
        state.results.pd_result = event.pd_result
        state.results.bench_pre = event.bench_pre
        state.results.auto_applied = (event.auto_applied == true)
        state.results.auto_done = (event.auto_done == true) or (event.auto_applied == true)
        state.results.sudo_skipped = (event.sudo_skipped == true)
        state.results.selected_apply = {}
        state.results.active_tab = 1
        state.results.scroll = 0
        rebuild_results_tabs(state)
        state.screen = "results"
        state.status_msg = event.msg or ""
        state.status_kind = event.kind or "ok"
        return state, nil
    end

    if etype == "scan_failed" then
        state.screen = "dashboard"
        state.status_msg = event.err or "Scan failed or aborted."
        state.status_kind = "err"
        return state, nil
    end

    if etype == "commit_ok" then
        state.screen = "dashboard"
        state.confirm.error_msg = nil
        state.status_msg = event.msg or "Changes committed atomically."
        state.status_kind = "ok"
        return state, { kind = "refresh_snapshot" }
    end

    if etype == "commit_failed" then
        -- Keep confirm/results intact so user never loses benchmark results on typo/cancel!
        state.confirm.error_msg = event.err or "Commit failed or cancelled."
        return state, nil
    end

    if etype ~= "key" then
        return state, nil
    end

    local key = event.key
    if key == "CTRL_C" or key == "EOF" then
        return state, { kind = "quit" }
    end

    if state.screen == "dashboard" then
        local n = #M.DASHBOARD_ACTIONS
        if key == "UP" then
            state.selected = ((state.selected - 2) % n) + 1
        elseif key == "DOWN" then
            state.selected = (state.selected % n) + 1
        elseif key == "f" then
            state.force = not state.force
            state.status_msg = "Force switch (<10% margin): " .. (state.force and "ON" or "OFF")
            state.status_kind = "info"
        elseif key == "r" then
            return state, { kind = "refresh_snapshot" }
        elseif key == "q" or key == "ESC" then
            return state, { kind = "quit" }
        elseif key == "1" or key == "2" or key == "3" or key == "4" or key == "ENTER" then
            local idx = (key == "ENTER") and state.selected or tonumber(key)
            state.selected = idx
            local act = M.DASHBOARD_ACTIONS[idx]
            if not act then return state, nil end
            if act.id == "rollback" then
                if not state.rollback_tx or state.rollback_tx.state == "rolled_back" or #(state.rollback_tx.files or {}) == 0 then
                    state.status_msg = "No active committed transaction available to roll back."
                    state.status_kind = "warn"
                    return state, nil
                end
                state.screen = "rollback"
                state.rollback_selected = 1
                return state, nil
            end
            state.screen = "progress"
            state.scan_mode = act.id
            state.progress = { pct = 0, phase = "Initializing…", group_status = {}, leaders = {}, logs = {}, elapsed = 0 }
            state.status_msg = ""
            return state, { kind = "start_scan", mode = act.id, force = state.force }
        end
        return state, nil
    end

    if state.screen == "results" then
        local tabs = state.results.tabs or {}
        if key == "q" then
            return state, { kind = "quit" }
        elseif key == "b" or key == "ESC" then
            state.screen = "dashboard"
            return state, nil
        elseif key == "LEFT" or key == "SHIFT_TAB" then
            if #tabs > 0 then
                state.results.active_tab = ((state.results.active_tab - 2) % #tabs) + 1
                state.results.scroll = 0
            end
        elseif key == "RIGHT" or key == "TAB" then
            if #tabs > 0 then
                state.results.active_tab = (state.results.active_tab % #tabs) + 1
                state.results.scroll = 0
            end
        elseif key == "UP" then
            state.results.scroll = math.max(0, state.results.scroll - 1)
        elseif key == "DOWN" then
            state.results.scroll = state.results.scroll + 1
        elseif key == "PGUP" then
            state.results.scroll = math.max(0, state.results.scroll - 5)
        elseif key == "PGDN" then
            state.results.scroll = state.results.scroll + 5
        elseif key == "SPACE" then
            if state.results.auto_applied or state.results.auto_done then
                return state, nil
            end
            local idx = state.results.active_tab
            local tab = tabs[idx]
            if tab then
                local can_change = (tab.kind == "mirrorlist" and tab.rank_res and tab.rank_res.changed)
                    or (tab.kind == "pacman_conf" and tab.pd and tab.pd.changed)
                if can_change then
                    state.results.selected_apply[idx] = not state.results.selected_apply[idx]
                end
            end
        elseif key == "f" then
            -- Instant in-memory re-rank without re-probing the network!
            state.force = not state.force
            state.results.auto_applied = false
            state.results.auto_done = false
            state.results.selected_apply = {}
            rebuild_results_tabs(state)
            state.status_msg = "Re-ranked in memory with --force=" .. (state.force and "ON" or "OFF")
            state.status_kind = "info"
        elseif key == "r" then
            local mode = state.scan_mode or "fast-dry"
            state.screen = "progress"
            state.progress = { pct = 0, phase = "Re-scanning…", group_status = {}, leaders = {}, logs = {}, elapsed = 0 }
            return state, { kind = "start_scan", mode = mode, force = state.force }
        elseif key == "a" or key == "ENTER" then
            if state.results.auto_applied then
                state.status_msg = "Already applied automatically (press r to rescan or q to quit)."
                state.status_kind = "ok"
                return state, nil
            end
            local items = build_confirm_items(state)
            if #items == 0 then
                state.status_msg = "Nothing new selected (press 'f' to force <10% switch or Space to toggle)."
                state.status_kind = "warn"
                return state, nil
            end
            state.confirm = {
                is_rollback = false,
                items = items,
                error_msg = nil,
                return_screen = "results",
            }
            state.screen = "confirm"
        end
        return state, nil
    end

    if state.screen == "rollback" then
        if key == "q" then
            return state, { kind = "quit" }
        elseif key == "b" or key == "ESC" then
            state.screen = "dashboard"
        elseif key == "ENTER" or key == "y" then
            local tx = state.rollback_tx
            if not tx or #(tx.files or {}) == 0 then
                state.screen = "dashboard"
                return state, nil
            end
            local items = {}
            for _, f in ipairs(tx.files) do
                items[#items + 1] = {
                    kind = f.kind,
                    path = f.path,
                    summary = "Restore <- " .. tostring(f.backup_path or "backup"),
                }
            end
            state.confirm = {
                is_rollback = true,
                items = items,
                error_msg = nil,
                return_screen = "rollback",
            }
            state.screen = "confirm"
        end
        return state, nil
    end

    if state.screen == "confirm" then
        if key == "q" then
            return state, { kind = "quit" }
        elseif key == "n" or key == "ESC" or key == "b" then
            state.screen = state.confirm.return_screen or "results"
            state.confirm.error_msg = nil
        elseif key == "y" or key == "ENTER" then
            if state.confirm.is_rollback then
                return state, { kind = "commit_rollback", force = state.force }
            end
            return state, { kind = "commit_apply", items = deepcopy_shallow(state.confirm.items) }
        end
        return state, nil
    end

    return state, nil
end

local function make_palette(no_color)
    if no_color then
        return {
            rst = "", bold = "", dim = "", rev = "",
            cyan = "", blue = "", green = "", yellow = "", red = "",
        }
    end
    -- Strict 16-color ANSI palette only (adapts automatically to Foot/Noctalia Dark & Light themes)
    return {
        rst = "\27[0m",
        bold = "\27[1m",
        dim = "\27[2m",
        rev = "\27[7m",
        cyan = "\27[36m",
        blue = "\27[34m",
        green = "\27[32m",
        yellow = "\27[33m",
        red = "\27[31m",
    }
end

local function make_glyphs(ascii_only)
    if ascii_only then
        return {
            tl = "+", tr = "+", bl = "+", br = "+", h = "-", v = "|", ml = "+", mr = "+",
            bar = ">", ok = "v", dot = "*", off = "o", arrow = "->", bul = ".",
        }
    end
    return {
        tl = "┌", tr = "┐", bl = "└", br = "┘", h = "─", v = "│", ml = "├", mr = "┤",
        bar = "▌", ok = "✓", dot = "●", off = "○", arrow = "→", bul = "·",
    }
end

function M.render(state, dims, opts)
    dims = dims or {}
    opts = opts or {}
    local cols = math.max(56, tonumber(dims.cols) or 100)
    local rows = math.max(20, tonumber(dims.rows) or 32)
    local ascii_only = opts.ascii_only == true
    local no_color = opts.no_color == true
    local C = make_palette(no_color)
    local G = make_glyphs(ascii_only)

    local box_w = math.min(118, math.max(52, cols - 4))
    local margin = string.rep(" ", math.max(0, (cols - (box_w + 4)) // 2))
    local lines = {}

    local function rule(l, r)
        lines[#lines + 1] = margin .. C.dim .. l .. string.rep(G.h, box_w + 2) .. r .. C.rst
    end
    local function row(formatted)
        local w = M.display_width(formatted or "")
        local pad = math.max(0, box_w - w)
        lines[#lines + 1] = margin .. C.dim .. G.v .. C.rst .. " " .. (formatted or "") .. string.rep(" ", pad) .. " " .. C.dim .. G.v .. C.rst
    end
    local function text_row(plain, style)
        local clipped = M.clip_utf8(plain or "", box_w, ascii_only)
        if style and style ~= "" then
            row(style .. clipped .. C.rst)
        else
            row(clipped)
        end
    end

    -- Header
    local step_map = { dashboard = 1, progress = 2, results = 3, confirm = 4, rollback = 4 }
    local active_step = step_map[state.screen] or 1
    rule(G.tl, G.tr)
    local title = "KAZE MIRROR OPTIMIZER"
    local tag = "Lua 5.5 " .. G.bul .. " curl -Z " .. G.bul .. " unprivileged"
    local gap = box_w - M.display_width(title) - M.display_width(tag)
    if gap >= 2 then
        row(C.bold .. C.cyan .. title .. C.rst .. string.rep(" ", gap) .. C.dim .. tag .. C.rst)
    else
        text_row(title, C.bold .. C.cyan)
    end

    local step4_label = "4 Commit"
    local step4_done = false
    if state.screen == "results" then
        if state.results.auto_applied then
            step4_label = "4 Applied"
            step4_done = true
        elseif state.results.auto_done then
            step4_label = "4 Up-to-date"
            step4_done = true
        elseif state.results.sudo_skipped then
            step4_label = "4 Dry-run"
        end
    end
    local step_names = { "1 Dashboard", "2 Scan", "3 Results", step4_label }
    local step_parts = {}
    for i = 1, 4 do
        if i < active_step or (step4_done and (i == 3 or i == 4)) then
            step_parts[#step_parts + 1] = C.green .. G.ok .. " " .. step_names[i] .. C.rst
        elseif i == active_step then
            step_parts[#step_parts + 1] = C.bold .. C.cyan .. G.dot .. " " .. step_names[i] .. C.rst
        else
            step_parts[#step_parts + 1] = C.dim .. G.off .. " " .. step_names[i] .. C.rst
        end
    end
    local sep = " " .. C.dim .. G.h .. G.h .. C.rst .. " "
    local step_line = table.concat(step_parts, sep)
    if M.display_width(step_line) <= box_w then
        row(step_line)
    else
        text_row("Step " .. active_step .. "/4: " .. step_names[active_step], C.bold .. C.cyan)
    end
    rule(G.ml, G.mr)

    -- Screen body
    if state.screen == "dashboard" then
        local st_line = string.format("ParallelDownloads: %d  %s  Groups: %d  %s  Backups: %d  %s  Force: %s",
            state.parallel_downloads or 5, G.bul, #(state.groups or {}), G.bul,
            state.backup_count or 0, G.bul, state.force and "ON" or "OFF")
        text_row(st_line, C.blue)
        if #(state.timers or {}) > 0 then
            text_row("Timer active: " .. table.concat(state.timers, ", ") .. " (may overwrite mirrorlists)", C.yellow)
        end
        row("")
        text_row("Active Managed Mirrorlists (/etc/pacman.conf)", C.bold)
        if #(state.groups or {}) == 0 then
            text_row("  (none detected)", C.dim)
        else
            for _, g in ipairs(state.groups) do
                local host = (g.primary_host and g.primary_host ~= "") and g.primary_host or "(empty)"
                local gl = string.format("  %-22s %s %-26s (%d active)",
                    M.clip_utf8(g.basename, 22, ascii_only), G.arrow, M.clip_utf8(host, 26, ascii_only), g.server_count or 0)
                text_row(gl)
            end
        end
        if #(state.skipped_repos or {}) > 0 then
            local names = {}
            for i = 1, math.min(4, #state.skipped_repos) do
                names[#names + 1] = state.skipped_repos[i].repo
            end
            text_row("  Unmanaged/skipped: " .. table.concat(names, ", "), C.dim)
        end

        rule(G.ml, G.mr)
        text_row("Actions", C.bold)
        for idx, act in ipairs(M.DASHBOARD_ACTIONS) do
            local is_sel = (idx == state.selected)
            local pfx = is_sel and (G.bar .. " ") or "  "
            local main_s = string.format("%s%d. %s", pfx, idx, act.title)
            if is_sel then
                text_row(main_s, C.bold .. C.rev)
            else
                text_row(main_s)
            end
            text_row("     " .. act.desc, C.dim)
        end
        rule(G.ml, G.mr)
        if state.status_msg ~= "" then
            local col = state.status_kind == "err" and C.red
                or (state.status_kind == "warn" and C.yellow
                or (state.status_kind == "ok" and C.green or C.cyan))
            text_row(state.status_msg, col)
        end
        text_row("Up/Down Move  Enter Run  1-4 Quick  f Force  r Refresh  q Quit", C.dim)

    elseif state.screen == "progress" then
        local p = state.progress
        local bar_w = math.min(36, math.max(16, box_w - 22))
        local bar = mirror.format_mbps_bar(p.pct or 0, 100, bar_w, ascii_only)
        row(C.cyan .. "[" .. bar .. "]" .. C.rst .. string.format(" %3d%%  %s  %.1fs", p.pct or 0, G.bul, p.elapsed or 0))
        text_row("Phase: " .. (p.phase ~= "" and p.phase or "Running…"), C.bold)
        row("")
        if #(p.group_status or {}) > 0 then
            text_row("Groups", C.bold)
            for _, gs in ipairs(p.group_status) do
                local mk = gs.state == "done" and (C.green .. G.ok .. C.rst)
                    or (gs.state == "active" and (C.cyan .. G.dot .. C.rst) or (C.dim .. G.off .. C.rst))
                local detail = M.clip_utf8(string.format("%s  %s", gs.name, gs.detail or ""), box_w - 4, ascii_only)
                row("  " .. mk .. " " .. detail)
            end
            row("")
        end
        if #(p.leaders or {}) > 0 then
            text_row("Live Top Candidates", C.bold)
            for i, ld in ipairs(p.leaders) do
                text_row(string.format("  %d. %-30s  %6.1f Mbps  %4.0fms",
                    i, M.clip_utf8(ld.host, 30, ascii_only), ld.mbps or 0, ld.ttfb_ms or 0), C.green)
            end
            row("")
        end
        text_row("Recent Probe Log", C.dim)
        for _, lg in ipairs(p.logs or {}) do
            text_row("  " .. lg, C.dim)
        end
        rule(G.ml, G.mr)
        text_row("Ctrl+C Abort cleanly (restores bar & temp dir)", C.dim)

    elseif state.screen == "results" then
        local tabs = state.results.tabs or {}
        local active_idx = state.results.active_tab or 1
        local tab = tabs[active_idx]

        -- Tab header bar
        local tab_parts = {}
        for i, t in ipairs(tabs) do
            local lbl
            if t.kind == "mirrorlist" then
                lbl = t.group.basename:gsub("%-mirrorlist$", "")
                if t.rank_res and t.rank_res.changed then
                    lbl = lbl .. (t.rank_res.urgent and "!" or "*")
                end
            else
                lbl = "ParallelDL" .. ((t.pd and t.pd.changed) and "*" or "")
            end
            local chip = "[" .. i .. ":" .. lbl .. "]"
            if i == active_idx then
                tab_parts[#tab_parts + 1] = C.bold .. C.rev .. chip .. C.rst
            else
                tab_parts[#tab_parts + 1] = C.dim .. chip .. C.rst
            end
        end
        local tab_str = table.concat(tab_parts, " ")
        if M.display_width(tab_str) <= box_w then
            row(tab_str)
        else
            text_row(string.format("Tab %d/%d", active_idx, #tabs), C.bold)
        end
        rule(G.ml, G.mr)

        if not tab then
            text_row("No results available.", C.dim)
        elseif tab.kind == "mirrorlist" then
            local rr = tab.rank_res
            local cur_h = rr and rr.current_primary and mirror.canonical_host(rr.current_primary) or "(none)"
            local top_h = (rr and rr.ranked and rr.ranked[1]) and mirror.canonical_host(rr.ranked[1].url) or "(none)"
            local chk_line
            if state.results.auto_applied then
                chk_line = string.format("%s Applied %s   |   %s %s %s",
                    G.ok, tab.group.basename, M.clip_utf8(cur_h, 20, ascii_only), G.arrow, M.clip_utf8(top_h, 20, ascii_only))
            elseif state.results.auto_done then
                chk_line = string.format("%s Up to date: %s   |   %s",
                    G.ok, tab.group.basename, M.clip_utf8(cur_h, 28, ascii_only))
            else
                local inc_mark = state.results.selected_apply[active_idx] and (G.ok) or " "
                chk_line = string.format("[%s] Include %s in commit   |   %s %s %s",
                    inc_mark, tab.group.basename, M.clip_utf8(cur_h, 20, ascii_only), G.arrow, M.clip_utf8(top_h, 20, ascii_only))
            end
            text_row(chk_line, (state.results.auto_applied or (rr and rr.changed)) and C.green or C.blue)

            if rr and rr.urgent then
                text_row("URGENT: current #1 failed/stale — switching recommended", C.yellow)
            elseif rr and rr.kept_current and rr.gain_pct and rr.gain_pct > 0 then
                text_row(string.format("Kept current #1 (best +%.1f%% < 10%% margin; press f to force)", rr.gain_pct), C.yellow)
            elseif rr and rr.changed and rr.gain_pct then
                text_row(string.format("Gain: +%.1f%% score (%.1f -> %.1f Mbps eff)",
                    rr.gain_pct, rr.current_mbps or 0, rr.best_mbps or 0), C.green)
            end
            row("")

            -- Responsive 3-breakpoint table
            local ranked = (rr and rr.ranked) or {}
            local max_m = 1.0
            for _, item in ipairs(ranked) do
                local m = item.b_eff or item.mbps or 0
                if m > max_m then max_m = m end
            end

            local wide = box_w >= 96
            local med = box_w >= 74 and not wide
            if wide then
                text_row(string.format("%-3s %-28s %-18s %8s %7s %s", "#", "Host", "Saturation", "Mbps", "TTFB", "Status"), C.bold)
            elseif med then
                text_row(string.format("%-3s %-22s %-12s %8s %6s %s", "#", "Host", "Speed", "Mbps", "TTFB", "Tag"), C.bold)
            else
                text_row(string.format("%-3s %-24s %8s %6s %s", "#", "Host", "Mbps", "TTFB", "Tag"), C.bold)
            end

            local max_vis = math.max(4, rows - 16)
            local scroll = math.min(state.results.scroll or 0, math.max(0, #ranked - max_vis))
            for i = 1 + scroll, math.min(#ranked, scroll + max_vis) do
                local item = ranked[i]
                local h = mirror.canonical_host(item.url)
                local tag_s = ""
                if item.url == rr.current_primary then
                    tag_s = (i == 1) and "CURRENT" or "current"
                elseif i == 1 then
                    tag_s = rr.urgent and "URGENT" or (rr.changed and "NEW #1" or "top")
                end
                if item.burst_throttled then
                    tag_s = (tag_s ~= "" and (tag_s .. " ") or "") .. "BURST"
                end
                local m_val = item.b_eff or item.mbps or 0
                local line_s
                if wide then
                    local bar = mirror.format_mbps_bar(m_val, max_m, 18, ascii_only)
                    line_s = string.format("%-3d %-28s %s %7.1f %5.0fms %s",
                        i, M.clip_utf8(h, 28, ascii_only), bar, m_val, item.ttfb_ms or 0, M.clip_utf8(tag_s, 14, ascii_only))
                elseif med then
                    local bar = mirror.format_mbps_bar(m_val, max_m, 12, ascii_only)
                    line_s = string.format("%-3d %-22s %s %7.1f %4.0fms %s",
                        i, M.clip_utf8(h, 22, ascii_only), bar, m_val, item.ttfb_ms or 0, M.clip_utf8(tag_s, 10, ascii_only))
                else
                    line_s = string.format("%-3d %-24s %7.1f %4.0fms %s",
                        i, M.clip_utf8(h, 24, ascii_only), m_val, item.ttfb_ms or 0, M.clip_utf8(tag_s, 8, ascii_only))
                end
                text_row(line_s, i == 1 and C.cyan or "")
            end
        elseif tab.kind == "pacman_conf" then
            local pd = tab.pd
            local pd_line
            if state.results.auto_applied and pd.changed then
                pd_line = string.format("%s Applied ParallelDownloads: %d %s %d",
                    G.ok, pd.current_pd, G.arrow, pd.recommended_pd)
            elseif state.results.auto_done then
                pd_line = string.format("%s ParallelDownloads: %d (already optimal)", G.ok, pd.current_pd)
            else
                local inc_mark = state.results.selected_apply[active_idx] and G.ok or " "
                pd_line = string.format("[%s] Update ParallelDownloads: %d %s %d",
                    inc_mark, pd.current_pd, G.arrow, pd.recommended_pd)
            end
            text_row(pd_line, (state.results.auto_applied or pd.changed) and C.green or C.blue)
            if tab.pre and tab.pre.net_mbps then
                text_row(string.format("Pre-baseline (old mirrors, PD=%d): %.1f Mbps  |  Post (new mirrors, PD=%d): %.1f Mbps",
                    pd.current_pd, tab.pre.net_mbps, pd.recommended_pd, pd.best_mbps or 0), C.cyan)
            end
            row("")
            local max_m = 1.0
            for _, r in ipairs(pd.results or {}) do
                if r.mbps > max_m then max_m = r.mbps end
            end
            for _, r in ipairs(pd.results or {}) do
                local bar = mirror.format_mbps_bar(r.mbps, max_m, math.min(24, box_w - 34), ascii_only)
                local tag_s = (r.pd == pd.recommended_pd and "BEST" or "")
                    .. (r.pd == pd.current_pd and " (current)" or "")
                text_row(string.format("  PD=%-2d  %s  %6.1f Mbps  %s", r.pd, bar, r.mbps, tag_s),
                    r.pd == pd.recommended_pd and C.green or "")
            end
        end

        rule(G.ml, G.mr)
        if state.status_msg ~= "" then
            local col = state.status_kind == "err" and C.red
                or (state.status_kind == "warn" and C.yellow
                or (state.status_kind == "ok" and C.green or C.cyan))
            text_row(state.status_msg, col)
        end
        if state.results.auto_applied then
            text_row("Left/Right Tab  Up/Down Scroll  r Rescan  Esc Dashboard  q Quit", C.dim)
        elseif state.results.auto_done then
            text_row("Left/Right Tab  f Force Override  r Rescan  Esc Dashboard  q Quit", C.dim)
        else
            text_row("Left/Right Tab  Space Toggle  f Force  a Apply  r Rescan  Esc Back  q Quit", C.dim)
        end

    elseif state.screen == "rollback" then
        local tx = state.rollback_tx or {}
        text_row("Last Committed Transaction", C.bold)
        text_row("  Timestamp: " .. tostring(tx.timestamp or "unknown"), C.blue)
        text_row("  State:     " .. tostring(tx.state or "unknown"), C.cyan)
        row("")
        text_row("Files to restore atomically:", C.bold)
        for _, f in ipairs(tx.files or {}) do
            text_row(string.format("  %s  %s  %s", G.dot, f.path, f.backup_path or ""), "")
        end
        rule(G.ml, G.mr)
        text_row("Enter/y Proceed to Confirm   Esc/b Back   q Quit", C.dim)

    elseif state.screen == "confirm" then
        local verb = state.confirm.is_rollback and "Atomic Rollback" or "Atomic Commit"
        text_row(verb .. " (runs sudo --commit-" .. (state.confirm.is_rollback and "rollback" or "plan") .. ", zero network as root)", C.bold .. C.yellow)
        row("")
        for _, item in ipairs(state.confirm.items or {}) do
            text_row(string.format("  %s %s", G.dot, item.path), C.bold)
            text_row("      " .. tostring(item.summary or ""), C.cyan)
        end
        if state.confirm.error_msg then
            row("")
            text_row("Error: " .. state.confirm.error_msg, C.red)
        end
        rule(G.ml, G.mr)
        text_row("[ Enter / y ] Confirm & Run sudo     [ Esc / n ] Cancel (keep results)", C.bold)
    end

    rule(G.bl, G.br)

    local top_pad = 0
    if rows > #lines + 2 then
        top_pad = math.min(4, (rows - #lines) // 2)
    end
    local pre = string.rep("\27[K\n", top_pad)
    local body_lines = {}
    for i = 1, #lines do
        body_lines[i] = lines[i] .. "\27[K\n"
    end
    local raw_frame = table.concat(lines, "\n") .. "\n"
    local flushed = "\27[?2026h\27[H" .. pre .. table.concat(body_lines) .. "\27[J\27[?2026l"
    return flushed, raw_frame
end

-- Interactive TTY runner (used by `bin/kaze-mirror --tui`).
function M.run_interactive(hooks)
    local function non_empty_env(name)
        local v = os.getenv(name)
        return (v and v ~= "") and v or nil
    end
    local no_color = (non_empty_env("NO_COLOR") ~= nil)
        or (os.getenv("TERM") == "dumb")
    local locale = non_empty_env("LC_ALL") or non_empty_env("LC_CTYPE") or non_empty_env("LANG") or "C"
    local ascii_only = not locale:lower():find("utf%-?8")

    local function read_cmd_line(cmd)
        local p = io.popen(cmd, "r")
        if not p then return nil end
        local line = p:read("*l")
        p:close()
        return line
    end

    local function measure_tty()
        local sz = read_cmd_line("stty size </dev/tty 2>/dev/null")
        local r, c = sz and sz:match("^(%d+)%s+(%d+)$")
        return {
            rows = tonumber(r) or tonumber(os.getenv("LINES")) or 32,
            cols = tonumber(c) or tonumber(os.getenv("COLUMNS")) or 100,
        }
    end

    local orig_stty = read_cmd_line("stty -g </dev/tty 2>/dev/null")
    local tty_active = false
    local key_proc = nil
    local key_pid = nil

    local function close_key_reader()
        if key_pid then
            -- Default SIGTERM kills bash immediately even while blocked in `read -rsn1`,
            -- preventing pclose()/waitpid() from deadlocking until the next keypress.
            os.execute("kill -TERM " .. tostring(key_pid) .. " 2>/dev/null || true")
            key_pid = nil
        end
        if key_proc then
            pcall(function() key_proc:close() end)
            key_proc = nil
        end
    end

    local function open_key_reader()
        close_key_reader()
        -- Persistent bash byte-packetizer: blocks on read -rsn1 (0% idle CPU, 0 per-key forks),
        -- disambiguates CSI/SS3 arrow keys from bare Esc with 30ms timeout, emits hex line to Lua.
        local reader_cmd = [[exec bash -c '
printf "PID %s\n" "$$"
while IFS= read -rsn1 ch </dev/tty; do
    if [ -z "$ch" ]; then
        printf "0a\n"
        continue
    fi
    hex=$(printf "%s" "$ch" | od -An -tx1 | tr -d " \n")
    if [ "$hex" = "1b" ]; then
        seq="1b"
        if IFS= read -rsn1 -t 0.03 c1 </dev/tty; then
            h1=$(printf "%s" "$c1" | od -An -tx1 | tr -d " \n")
            seq="${seq}${h1}"
            if [ "$c1" = "[" ] || [ "$c1" = "O" ]; then
                while IFS= read -rsn1 -t 0.02 c2 </dev/tty; do
                    h2=$(printf "%s" "$c2" | od -An -tx1 | tr -d " \n")
                    seq="${seq}${h2}"
                    case "$c2" in [A-Za-z~]) break ;; esac
                done
            fi
        fi
        printf "%s\n" "$seq"
    else
        printf "%s\n" "$hex"
    fi
done
' 2>/dev/null]]
        key_proc = io.popen(reader_cmd, "r")
        if key_proc then
            local hdr = key_proc:read("*l")
            local pid_s = hdr and hdr:match("^PID (%d+)$")
            if pid_s then
                key_pid = tonumber(pid_s)
            end
        end
    end

    local function tty_enter()
        if tty_active then return end
        io.stdout:write("\27[?1049h\27[?25l\27[2J\27[H")
        io.stdout:flush()
        os.execute("stty -echo -icanon isig min 1 time 0 </dev/tty 2>/dev/null")
        tty_active = true
        open_key_reader()
    end

    local function tty_leave()
        close_key_reader()
        if orig_stty and orig_stty ~= "" then
            os.execute("stty " .. orig_stty .. " </dev/tty 2>/dev/null")
        end
        if tty_active then
            io.stdout:write("\27[?25h\27[?1049l\27[?2026l")
            io.stdout:flush()
            tty_active = false
        end
    end

    local function read_key()
        if not key_proc then return "EOF" end
        local hex_line = key_proc:read("*l")
        if not hex_line or hex_line == "" then return "EOF" end
        local raw = hex_line:gsub("%x%x", function(hh) return string.char(tonumber(hh, 16)) end)
        return M.parse_key_sequence(raw)
    end

    local state = M.initial_state(hooks.load_snapshot())
    local last_render_t = 0.0
    local function monotonic_s()
        local f = io.open("/proc/uptime", "r")
        if f then
            local l = f:read("*l")
            f:close()
            local v = l and tonumber(l:match("^(%d+%.?%d*)"))
            if v then return v end
        end
        return os.clock()
    end

    local function draw(force_draw)
        local now = monotonic_s()
        if not force_draw and (now - last_render_t) < 0.085 then
            return
        end
        last_render_t = now
        local flushed = M.render(state, measure_tty(), { no_color = no_color, ascii_only = ascii_only })
        io.stdout:write(flushed)
        io.stdout:flush()
    end

    local function handle_effect(eff)
        if not eff then return false end
        if eff.kind == "quit" then
            return true
        elseif eff.kind == "refresh_snapshot" then
            local snap = hooks.load_snapshot()
            M.reduce(state, { type = "snapshot", snapshot = snap })
            draw(true)
        elseif eff.kind == "start_scan" then
            local can_auto_commit = (not hooks.dry_run) and (type(hooks.auto_commit) == "function")
            local sudo_skipped = false
            if can_auto_commit and type(hooks.authenticate) == "function" then
                local need_prompt = (type(hooks.needs_sudo_prompt) ~= "function") or hooks.needs_sudo_prompt()
                if need_prompt then
                    tty_leave()
                    io.stdout:write("kaze-mirror: enter sudo password to auto-commit results (Ctrl+D to skip & run dry-run only):\n")
                    io.stdout:flush()
                end
                local ok_auth = hooks.authenticate()
                if need_prompt then
                    tty_enter()
                end
                if not ok_auth then
                    -- Never abort the benchmark if user skips/cancels sudo: run the full flow in dry-run mode!
                    can_auto_commit = false
                    sudo_skipped = true
                end
            end
            close_key_reader()
            draw(true)
            local last_phase = ""
            local last_keepalive_t = monotonic_s()
            local ok_s, res_or_err = pcall(hooks.run_scan, eff.mode, eff.force, function(pevt)
                pevt.type = "progress"
                local phase_changed = (pevt.phase ~= nil and pevt.phase ~= last_phase)
                if pevt.phase then last_phase = pevt.phase end
                if can_auto_commit and type(hooks.keepalive_sudo) == "function" then
                    local now = monotonic_s()
                    if (now - last_keepalive_t) >= 60.0 then
                        last_keepalive_t = now
                        hooks.keepalive_sudo()
                    end
                end
                M.reduce(state, pevt)
                draw(phase_changed)
            end)
            if ok_s and type(res_or_err) == "table" then
                if can_auto_commit then
                    M.reduce(state, { type = "progress", pct = 99, phase = "Applying updates atomically…" })
                    draw(true)
                    local cres = hooks.auto_commit(res_or_err, state.force, tty_leave, tty_enter)
                    if type(cres) == "table" then
                        res_or_err.auto_applied = (cres.applied == true)
                        res_or_err.auto_done = (cres.done == true) or (cres.applied == true)
                        if cres.msg then res_or_err.msg = cres.msg end
                        if cres.kind then res_or_err.kind = cres.kind end
                        if type(cres.snapshot) == "table" then
                            M.reduce(state, { type = "snapshot", snapshot = cres.snapshot })
                        end
                    end
                elseif sudo_skipped then
                    res_or_err.sudo_skipped = true
                    res_or_err.msg = "Dry-run complete (sudo skipped — no system files modified)."
                    res_or_err.kind = "warn"
                end
            end
            open_key_reader()
            if ok_s and type(res_or_err) == "table" then
                res_or_err.type = "scan_complete"
                M.reduce(state, res_or_err)
            else
                M.reduce(state, { type = "scan_failed", err = tostring(res_or_err or "scan aborted") })
            end
            draw(true)
        elseif eff.kind == "commit_apply" or eff.kind == "commit_rollback" then
            tty_leave()
            io.stdout:write("kaze-mirror: authenticating via sudo for atomic commit...\n")
            io.stdout:flush()
            local ok_c, err_c
            if eff.kind == "commit_rollback" then
                ok_c, err_c = hooks.commit_rollback(eff.force)
            else
                ok_c, err_c = hooks.commit_apply(eff.items)
            end
            tty_enter()
            if ok_c then
                local _, next_eff = M.reduce(state, { type = "commit_ok", msg = err_c or "Committed cleanly." })
                if next_eff then handle_effect(next_eff) end
            else
                M.reduce(state, { type = "commit_failed", err = tostring(err_c or "sudo commit failed") })
            end
            draw(true)
        end
        return false
    end

    local ok_loop, err_loop = pcall(function()
        tty_enter()
        draw(true)

        if hooks.auto_run then
            local map = { ["fast-dry"] = "1", ["deep-dry"] = "2", ["bench"] = "3", ["rollback"] = "4" }
            local k = map[hooks.auto_run]
            if k then
                local _, eff = M.reduce(state, { type = "key", key = k })
                draw(true)
                if handle_effect(eff) then return end
            end
        end

        while true do
            local k = read_key()
            if k == "IGNORE" then
                -- ignore unrecognized escape sequence
            else
                local _, eff = M.reduce(state, { type = "key", key = k })
                draw(true)
                if handle_effect(eff) then
                    break
                end
            end
        end
    end)

    tty_leave()
    if not ok_loop then
        io.stderr:write("kaze-mirror TUI error: " .. tostring(err_loop) .. "\n")
        return false
    end
    return true
end

return M
