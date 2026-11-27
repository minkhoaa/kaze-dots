#![deny(clippy::unwrap_used)]

pub mod desktop;

use desktop::{scan_applications, DesktopApp};
use kaze_core::{
    Anchor, AppState, DirtyFlags, EdgeInsets, HitTarget, ImeEvent, IpcResult, KazeExtension,
    KeyEvent, KeyboardMode, Layer, PaintCmd, PointerButton, Rect, ShellAction, ShellContext,
    SurfaceSpec, SystemEvent, TextAlign,
};

const SURFACE_ID: &str = "launcher:main";
const NAMESPACE: &str = "kaze-launcher";

// Standard X11 / XKB keysym raw values (`xkbcommon`)
const KEY_BACKSPACE: u32 = 0xff08;
const KEY_TAB: u32 = 0xff09;
const KEY_RETURN: u32 = 0xff0d;
const KEY_ESCAPE: u32 = 0xff1b;
const KEY_HOME: u32 = 0xff50;
const KEY_UP: u32 = 0xff52;
const KEY_DOWN: u32 = 0xff54;
const KEY_PAGE_UP: u32 = 0xff55;
const KEY_PAGE_DOWN: u32 = 0xff56;
const KEY_END: u32 = 0xff57;
const KEY_KP_ENTER: u32 = 0xff8d;
const KEY_ISO_LEFT_TAB: u32 = 0xfe20;

#[derive(Debug, Clone, PartialEq, Eq)]
enum LauncherMode {
    Closed,
    Apps,
    Dmenu { prompt: String, items: Vec<String> },
}

#[derive(Debug, Clone)]
struct FilteredItem {
    index: usize,
    title: String,
    subtitle: String,
    score: i32,
}

/// Unified App Launcher (`.desktop` scanner + lazy cache) and `dmenu` overlay (`kaze-launcher`).
///
/// Zero T0 overhead: `.desktop` scanning and surface creation stay completely dormant until
/// `launcher-toggle` or `kaze-shell dmenu` opens the overlay; closing returns `Vec::new()` so
/// `kaze-ui` immediately drops the layer surface and releases SHM down to 0 KiB.
pub struct LauncherExtension {
    mode: LauncherMode,
    apps: Vec<DesktopApp>,
    apps_loaded: bool,
    apps_dirty: bool,
    query: String,
    preedit: String,
    filtered: Vec<FilteredItem>,
    selected: usize,
    scroll_offset: usize,
    cached_spec: Option<SurfaceSpec>,
}

impl Default for LauncherExtension {
    fn default() -> Self {
        Self::new()
    }
}

impl LauncherExtension {
    pub fn new() -> Self {
        Self {
            mode: LauncherMode::Closed,
            apps: Vec::new(),
            apps_loaded: false,
            apps_dirty: false,
            query: String::new(),
            preedit: String::new(),
            filtered: Vec::new(),
            selected: 0,
            scroll_offset: 0,
            cached_spec: None,
        }
    }

    pub fn is_open(&self) -> bool {
        !matches!(self.mode, LauncherMode::Closed)
    }

    pub fn set_apps_for_test(&mut self, apps: Vec<DesktopApp>) {
        self.apps = apps;
        self.apps_loaded = true;
        self.apps_dirty = false;
    }

    fn ensure_apps_loaded(&mut self) {
        if !self.apps_loaded || self.apps_dirty {
            self.apps = scan_applications();
            self.apps_loaded = true;
            self.apps_dirty = false;
        }
    }

    fn effective_query(&self) -> String {
        if self.preedit.is_empty() {
            self.query.clone()
        } else {
            format!("{}{}", self.query, self.preedit)
        }
    }

    fn refilter(&mut self, max_rows: usize) {
        let q = self.effective_query();
        self.filtered.clear();

        match &self.mode {
            LauncherMode::Closed => {}
            LauncherMode::Apps => {
                for (index, app) in self.apps.iter().enumerate() {
                    if let Some(score) = score_desktop_app(&q, app) {
                        self.filtered.push(FilteredItem {
                            index,
                            title: app.name.clone(),
                            subtitle: app.subtitle().to_string(),
                            score,
                        });
                    }
                }
                if !q.trim().is_empty() {
                    self.filtered
                        .sort_by(|a, b| b.score.cmp(&a.score).then_with(|| a.index.cmp(&b.index)));
                }
            }
            LauncherMode::Dmenu { items, .. } => {
                for (index, line) in items.iter().enumerate() {
                    if let Some(score) = fuzzy_score(&q, line) {
                        self.filtered.push(FilteredItem {
                            index,
                            title: line.clone(),
                            subtitle: String::new(),
                            score,
                        });
                    }
                }
                if !q.trim().is_empty() {
                    self.filtered
                        .sort_by(|a, b| b.score.cmp(&a.score).then_with(|| a.index.cmp(&b.index)));
                }
            }
        }

        if self.filtered.is_empty() {
            self.selected = 0;
            self.scroll_offset = 0;
        } else {
            self.selected = self.selected.min(self.filtered.len() - 1);
            self.clamp_scroll(max_rows);
        }
    }

    fn clamp_scroll(&mut self, max_rows: usize) {
        let rows = max_rows.max(1);
        if self.selected < self.scroll_offset {
            self.scroll_offset = self.selected;
        } else if self.selected >= self.scroll_offset + rows {
            self.scroll_offset = self.selected + 1 - rows;
        }
        let max_offset = self.filtered.len().saturating_sub(rows);
        self.scroll_offset = self.scroll_offset.min(max_offset);
    }

    fn move_selection(&mut self, delta: isize, max_rows: usize) {
        if self.filtered.is_empty() {
            return;
        }
        let len = self.filtered.len() as isize;
        let next = (self.selected as isize + delta).rem_euclid(len) as usize;
        self.selected = next;
        self.clamp_scroll(max_rows);
    }

    fn open_apps(&mut self, ctx: &mut ShellContext) -> DirtyFlags {
        if matches!(self.mode, LauncherMode::Dmenu { .. }) {
            ctx.push_action(ShellAction::DmenuReply { selected: None });
        }
        self.ensure_apps_loaded();
        self.mode = LauncherMode::Apps;
        self.query.clear();
        self.preedit.clear();
        self.selected = 0;
        self.scroll_offset = 0;
        self.refilter(ctx.state.config.launcher.max_rows);
        self.rebuild(ctx.state);
        DirtyFlags::LAUNCHER | DirtyFlags::LAYOUT
    }

    fn open_dmenu(&mut self, prompt: String, payload: &str, ctx: &mut ShellContext) -> DirtyFlags {
        let items: Vec<String> = payload
            .lines()
            .map(|l| l.trim_end_matches('\r').to_string())
            .filter(|l| !l.is_empty())
            .collect();
        self.mode = LauncherMode::Dmenu { prompt, items };
        self.query.clear();
        self.preedit.clear();
        self.selected = 0;
        self.scroll_offset = 0;
        self.refilter(ctx.state.config.launcher.max_rows);
        self.rebuild(ctx.state);
        DirtyFlags::LAUNCHER | DirtyFlags::LAYOUT
    }

    fn close_cancel(&mut self, ctx: &mut ShellContext) -> DirtyFlags {
        if !self.is_open() {
            return DirtyFlags::NONE;
        }
        let was_dmenu = matches!(self.mode, LauncherMode::Dmenu { .. });
        self.mode = LauncherMode::Closed;
        self.query.clear();
        self.preedit.clear();
        self.filtered.clear();
        self.selected = 0;
        self.scroll_offset = 0;
        self.cached_spec = None;
        if was_dmenu {
            ctx.push_action(ShellAction::DmenuReply { selected: None });
        }
        DirtyFlags::LAUNCHER | DirtyFlags::LAYOUT
    }

    fn activate_selected(&mut self, ctx: &mut ShellContext) -> DirtyFlags {
        let Some(chosen) = self.filtered.get(self.selected).cloned() else {
            return DirtyFlags::NONE;
        };

        match &self.mode {
            LauncherMode::Closed => DirtyFlags::NONE,
            LauncherMode::Dmenu { items, .. } => {
                let selected_line = items.get(chosen.index).cloned();
                self.mode = LauncherMode::Closed;
                self.query.clear();
                self.preedit.clear();
                self.filtered.clear();
                self.selected = 0;
                self.scroll_offset = 0;
                self.cached_spec = None;
                ctx.push_action(ShellAction::DmenuReply {
                    selected: selected_line,
                });
                DirtyFlags::LAUNCHER | DirtyFlags::LAYOUT
            }
            LauncherMode::Apps => {
                let cmd = self
                    .apps
                    .get(chosen.index)
                    .and_then(DesktopApp::build_command);
                self.mode = LauncherMode::Closed;
                self.query.clear();
                self.preedit.clear();
                self.filtered.clear();
                self.selected = 0;
                self.scroll_offset = 0;
                self.cached_spec = None;
                if let Some((program, args)) = cmd {
                    ctx.push_action(ShellAction::SpawnDetachedApp { program, args });
                }
                DirtyFlags::LAUNCHER | DirtyFlags::LAYOUT
            }
        }
    }

    fn handle_key(&mut self, key: &KeyEvent, ctx: &mut ShellContext) -> DirtyFlags {
        if !self.is_open() || !key.pressed {
            return DirtyFlags::NONE;
        }
        let max_rows = ctx.state.config.launcher.max_rows;

        if key.modifiers.ctrl {
            match key.keysym {
                0x006e | 0x004e => {
                    // Ctrl+N
                    self.move_selection(1, max_rows);
                    self.rebuild(ctx.state);
                    return DirtyFlags::LAUNCHER;
                }
                0x0070 | 0x0050 => {
                    // Ctrl+P
                    self.move_selection(-1, max_rows);
                    self.rebuild(ctx.state);
                    return DirtyFlags::LAUNCHER;
                }
                0x0075 | 0x0055 => {
                    // Ctrl+U: clear query
                    self.query.clear();
                    self.preedit.clear();
                    self.selected = 0;
                    self.refilter(max_rows);
                    self.rebuild(ctx.state);
                    return DirtyFlags::LAUNCHER;
                }
                0x0077 | 0x0057 => {
                    // Ctrl+W: delete previous word
                    delete_prev_word(&mut self.query);
                    self.preedit.clear();
                    self.selected = 0;
                    self.refilter(max_rows);
                    self.rebuild(ctx.state);
                    return DirtyFlags::LAUNCHER;
                }
                0x0063 | 0x0043 | 0x0067 | 0x0047 => {
                    // Ctrl+C / Ctrl+G: cancel
                    return self.close_cancel(ctx);
                }
                _ => return DirtyFlags::NONE,
            }
        }

        match key.keysym {
            KEY_ESCAPE => self.close_cancel(ctx),
            KEY_RETURN | KEY_KP_ENTER => self.activate_selected(ctx),
            KEY_DOWN => {
                self.move_selection(1, max_rows);
                self.rebuild(ctx.state);
                DirtyFlags::LAUNCHER
            }
            KEY_UP => {
                self.move_selection(-1, max_rows);
                self.rebuild(ctx.state);
                DirtyFlags::LAUNCHER
            }
            KEY_TAB => {
                let delta = if key.modifiers.shift { -1 } else { 1 };
                self.move_selection(delta, max_rows);
                self.rebuild(ctx.state);
                DirtyFlags::LAUNCHER
            }
            KEY_ISO_LEFT_TAB => {
                self.move_selection(-1, max_rows);
                self.rebuild(ctx.state);
                DirtyFlags::LAUNCHER
            }
            KEY_PAGE_DOWN => {
                self.move_selection(max_rows as isize, max_rows);
                self.rebuild(ctx.state);
                DirtyFlags::LAUNCHER
            }
            KEY_PAGE_UP => {
                self.move_selection(-(max_rows as isize), max_rows);
                self.rebuild(ctx.state);
                DirtyFlags::LAUNCHER
            }
            KEY_HOME => {
                if !self.filtered.is_empty() {
                    self.selected = 0;
                    self.clamp_scroll(max_rows);
                    self.rebuild(ctx.state);
                    DirtyFlags::LAUNCHER
                } else {
                    DirtyFlags::NONE
                }
            }
            KEY_END => {
                if !self.filtered.is_empty() {
                    self.selected = self.filtered.len() - 1;
                    self.clamp_scroll(max_rows);
                    self.rebuild(ctx.state);
                    DirtyFlags::LAUNCHER
                } else {
                    DirtyFlags::NONE
                }
            }
            KEY_BACKSPACE => {
                if !self.preedit.is_empty() {
                    self.preedit.pop();
                } else {
                    self.query.pop();
                }
                self.selected = 0;
                self.refilter(max_rows);
                self.rebuild(ctx.state);
                DirtyFlags::LAUNCHER
            }
            _ => {
                if key.modifiers.alt || key.modifiers.logo {
                    return DirtyFlags::NONE;
                }
                if let Some(ref text) = key.utf8 {
                    let printable: String = text.chars().filter(|c| !c.is_control()).collect();
                    if !printable.is_empty() {
                        self.query.push_str(&printable);
                        self.selected = 0;
                        self.refilter(max_rows);
                        self.rebuild(ctx.state);
                        return DirtyFlags::LAUNCHER;
                    }
                }
                DirtyFlags::NONE
            }
        }
    }

    fn handle_ime(&mut self, ime: &ImeEvent, ctx: &mut ShellContext) -> DirtyFlags {
        if !self.is_open() {
            return DirtyFlags::NONE;
        }
        let max_rows = ctx.state.config.launcher.max_rows;
        match ime {
            ImeEvent::Preedit { text, .. } => {
                self.preedit = text.clone();
            }
            ImeEvent::Commit(text) => {
                self.preedit.clear();
                let printable: String = text.chars().filter(|c| !c.is_control()).collect();
                self.query.push_str(&printable);
                self.selected = 0;
            }
            ImeEvent::DeleteSurrounding { before, .. } => {
                let target_len = self.query.len().saturating_sub(*before as usize);
                let mut boundary = target_len;
                while boundary > 0 && !self.query.is_char_boundary(boundary) {
                    boundary -= 1;
                }
                self.query.truncate(boundary);
                self.selected = 0;
            }
        }
        self.refilter(max_rows);
        self.rebuild(ctx.state);
        DirtyFlags::LAUNCHER
    }

    fn rebuild(&mut self, state: &AppState) {
        if !self.is_open() || !state.config.launcher.enabled {
            self.cached_spec = None;
            return;
        }
        self.cached_spec = Some(build_launcher_surface(
            state,
            &self.mode,
            &self.query,
            &self.preedit,
            &self.filtered,
            self.selected,
            self.scroll_offset,
        ));
    }
}

impl KazeExtension for LauncherExtension {
    fn id(&self) -> &'static str {
        "launcher"
    }

    fn on_init(&mut self, _ctx: &mut ShellContext) {}

    fn on_event(&mut self, event: &SystemEvent, ctx: &mut ShellContext) -> DirtyFlags {
        match event {
            SystemEvent::KeyInput { surface_id, key } if surface_id == SURFACE_ID => {
                self.handle_key(key, ctx)
            }
            SystemEvent::ImeInput { surface_id, ime } if surface_id == SURFACE_ID => {
                self.handle_ime(ime, ctx)
            }
            SystemEvent::PointerClick {
                surface_id,
                target_id,
                button,
            } if surface_id == SURFACE_ID => {
                if *button == PointerButton::Right {
                    return self.close_cancel(ctx);
                }
                if *button == PointerButton::Left {
                    if let Some(idx_str) = target_id.strip_prefix("launcher:row:") {
                        if let Ok(idx) = idx_str.parse::<usize>() {
                            if idx < self.filtered.len() {
                                self.selected = idx;
                                return self.activate_selected(ctx);
                            }
                        }
                    }
                }
                DirtyFlags::NONE
            }
            SystemEvent::PointerScroll {
                surface_id,
                delta_y,
                ..
            } if surface_id == SURFACE_ID => {
                let delta = if *delta_y > 0.0 { 1 } else { -1 };
                self.move_selection(delta, ctx.state.config.launcher.max_rows);
                self.rebuild(ctx.state);
                DirtyFlags::LAUNCHER
            }
            SystemEvent::SurfaceClosed { surface_id }
            | SystemEvent::KeyboardFocusLost { surface_id }
                if surface_id == SURFACE_ID =>
            {
                self.close_cancel(ctx)
            }
            SystemEvent::ApplicationsChanged => {
                self.apps_dirty = true;
                if matches!(self.mode, LauncherMode::Apps) {
                    self.ensure_apps_loaded();
                    self.refilter(ctx.state.config.launcher.max_rows);
                    self.rebuild(ctx.state);
                    return DirtyFlags::LAUNCHER;
                }
                DirtyFlags::NONE
            }
            SystemEvent::ConfigReloaded | SystemEvent::ThemeChanged(_) => {
                if !ctx.state.config.launcher.enabled {
                    return self.close_cancel(ctx);
                }
                if self.is_open() {
                    self.clamp_scroll(ctx.state.config.launcher.max_rows);
                    self.rebuild(ctx.state);
                    return DirtyFlags::LAUNCHER | DirtyFlags::THEME;
                }
                DirtyFlags::NONE
            }
            _ => DirtyFlags::NONE,
        }
    }

    fn on_ipc(&mut self, cmd: &str, args: &[String], ctx: &mut ShellContext) -> IpcResult {
        match cmd {
            "launcher-toggle" => {
                if !ctx.state.config.launcher.enabled {
                    return IpcResult::Handled {
                        ok: false,
                        message: "launcher disabled in config".into(),
                        dirty: DirtyFlags::NONE,
                    };
                }
                if self.is_open() {
                    let dirty = self.close_cancel(ctx);
                    IpcResult::Handled {
                        ok: true,
                        message: "closed".into(),
                        dirty,
                    }
                } else {
                    let dirty = self.open_apps(ctx);
                    IpcResult::Handled {
                        ok: true,
                        message: "opened".into(),
                        dirty,
                    }
                }
            }
            "launcher-close" => {
                let dirty = self.close_cancel(ctx);
                IpcResult::Handled {
                    ok: true,
                    message: "closed".into(),
                    dirty,
                }
            }
            "launcher-accept" => {
                if !self.is_open() {
                    return IpcResult::Handled {
                        ok: false,
                        message: "launcher not open".into(),
                        dirty: DirtyFlags::NONE,
                    };
                }
                if let Some(q) = args.first() {
                    self.query = q.clone();
                    self.preedit.clear();
                    self.selected = 0;
                    self.refilter(ctx.state.config.launcher.max_rows);
                }
                let dirty = self.activate_selected(ctx);
                IpcResult::Handled {
                    ok: !dirty.is_empty(),
                    message: if dirty.is_empty() {
                        "no match".into()
                    } else {
                        "accepted".into()
                    },
                    dirty,
                }
            }
            "dmenu-open" => {
                let prompt = args
                    .first()
                    .cloned()
                    .filter(|p| !p.is_empty())
                    .unwrap_or_else(|| "Select > ".to_string());
                let payload = args.get(1).map(String::as_str).unwrap_or("");
                let dirty = self.open_dmenu(prompt, payload, ctx);
                IpcResult::Handled {
                    ok: true,
                    message: "opened".into(),
                    dirty,
                }
            }
            _ => IpcResult::Unhandled,
        }
    }

    fn surfaces(&self) -> Vec<SurfaceSpec> {
        self.cached_spec.clone().into_iter().collect()
    }
}

fn delete_prev_word(s: &mut String) {
    while s.ends_with(char::is_whitespace) {
        s.pop();
    }
    while let Some(c) = s.chars().last() {
        if c.is_whitespace() {
            break;
        }
        s.pop();
    }
}

fn score_desktop_app(query: &str, app: &DesktopApp) -> Option<i32> {
    if query.trim().is_empty() {
        return Some(0);
    }
    let mut best: Option<i32> = None;
    if let Some(s) = fuzzy_score(query, &app.name) {
        best = Some(s + 200);
    }
    if !app.generic_name.is_empty() {
        if let Some(s) = fuzzy_score(query, &app.generic_name) {
            best = Some(best.map_or(s + 80, |cur| cur.max(s + 80)));
        }
    }
    if !app.keywords.is_empty() {
        if let Some(s) = fuzzy_score(query, &app.keywords) {
            best = Some(best.map_or(s + 40, |cur| cur.max(s + 40)));
        }
    }
    let combined = format!("{} {} {}", app.name, app.comment, app.exec);
    if let Some(s) = fuzzy_score(query, &combined) {
        best = Some(best.map_or(s, |cur| cur.max(s)));
    }
    best
}

/// Case-insensitive multi-token fuzzy matcher (supports full Unicode / Vietnamese lowercase).
pub fn fuzzy_score(query: &str, candidate: &str) -> Option<i32> {
    let q_trimmed = query.trim();
    if q_trimmed.is_empty() {
        return Some(0);
    }
    let cand_lower = candidate.to_lowercase();
    let cand_chars: Vec<char> = cand_lower.chars().collect();
    let mut total = 0i32;

    for token in q_trimmed.split_whitespace() {
        let tok_lower = token.to_lowercase();
        let tok_score = score_single_token(&tok_lower, &cand_lower, &cand_chars)?;
        total = total.saturating_add(tok_score);
    }
    Some(total)
}

fn score_single_token(tok: &str, cand_lower: &str, cand_chars: &[char]) -> Option<i32> {
    if cand_lower == tok {
        return Some(1000);
    }
    if cand_lower.starts_with(tok) {
        return Some(600 - (cand_chars.len() as i32).min(100));
    }
    if let Some(byte_pos) = cand_lower.find(tok) {
        let at_word = byte_pos == 0
            || cand_lower[..byte_pos]
                .chars()
                .last()
                .is_some_and(|c| !c.is_alphanumeric());
        let bonus = if at_word { 420 } else { 300 };
        return Some(bonus - (byte_pos as i32).min(150));
    }

    // Subsequence match with consecutive and word-boundary bonuses.
    let mut score = 100i32;
    let mut c_idx = 0usize;
    let mut prev_match: Option<usize> = None;

    for qch in tok.chars() {
        let mut found = None;
        while c_idx < cand_chars.len() {
            if cand_chars[c_idx] == qch {
                found = Some(c_idx);
                c_idx += 1;
                break;
            }
            c_idx += 1;
        }
        let pos = found?;
        if let Some(prev) = prev_match {
            if pos == prev + 1 {
                score += 18;
            } else {
                score -= ((pos - prev - 1) as i32).min(12);
            }
        } else {
            score -= (pos as i32).min(30);
        }
        if pos == 0 || !cand_chars[pos - 1].is_alphanumeric() {
            score += 22;
        }
        prev_match = Some(pos);
    }

    Some(score)
}

fn build_launcher_surface(
    state: &AppState,
    mode: &LauncherMode,
    query: &str,
    preedit: &str,
    filtered: &[FilteredItem],
    selected: usize,
    scroll_offset: usize,
) -> SurfaceSpec {
    let cfg = &state.config.launcher;
    let bar = &state.config.bar;
    let colors = state.palette.for_mode(state.theme_mode);

    let bg = colors.surface_color().with_opacity(bar.background_opacity);
    let primary = colors.primary_color();
    let tertiary = colors.tertiary_color();
    let on_surface = colors.on_surface_color();
    let muted = colors.on_surface_variant_color();
    let outline_variant = colors.outline_variant_color();
    let surface_container = colors.surface_container_color();
    let surface_variant = colors.surface_variant_color();

    let is_apps = matches!(mode, LauncherMode::Apps);
    let prompt = match mode {
        LauncherMode::Apps => "Apps > ".to_string(),
        LauncherMode::Dmenu { prompt, .. } => prompt.clone(),
        LauncherMode::Closed => String::new(),
    };
    let total_count = match mode {
        LauncherMode::Apps => filtered.len(),
        LauncherMode::Dmenu { items, .. } => items.len(),
        LauncherMode::Closed => 0,
    };

    let border_w = bar.border_width.max(2.0);
    let w = cfg.width.clamp(320, 960) as f32;
    let pad_x = border_w + 14.0;
    let input_h = 44.0f32;
    let divider_h = 1.0f32;
    let row_h = if is_apps { 40.0f32 } else { 34.0f32 };
    let visible_rows = filtered.len().clamp(1, cfg.max_rows.max(1));
    let list_pad_y = 6.0f32;
    let total_h =
        (border_w * 2.0 + input_h + divider_h + list_pad_y * 2.0 + visible_rows as f32 * row_h)
            .ceil() as u32;

    let mut commands = Vec::with_capacity(visible_rows * 4 + 8);
    let mut hit_targets = Vec::with_capacity(visible_rows);

    // 1. Input bar background strip
    commands.push(PaintCmd::RoundedRect {
        rect: Rect::new(border_w, border_w, w - border_w * 2.0, input_h),
        radius: 0.0,
        fill: Some(surface_container),
        stroke: None,
        stroke_width: 0.0,
    });

    let count_text = if is_apps {
        format!("{}", filtered.len())
    } else {
        format!("{}/{total_count}", filtered.len())
    };
    let count_w = 56.0f32;
    let prompt_w = ((prompt.chars().count() as f32) * 8.4 + 8.0).clamp(44.0, 180.0);
    let input_y = border_w + 11.0;

    commands.push(PaintCmd::RichText {
        rect: Rect::new(pad_x, input_y, prompt_w, 24.0),
        text: prompt,
        color: primary,
        size: 13.5,
        bold: true,
        align: TextAlign::Left,
        max_lines: 1,
    });

    let query_x = pad_x + prompt_w + 4.0;
    let query_w = (w - query_x - count_w - pad_x - 6.0).max(80.0);
    if query.is_empty() && preedit.is_empty() {
        let placeholder = if is_apps {
            "Type to launch..."
        } else {
            "Type to filter..."
        };
        commands.push(PaintCmd::RichText {
            rect: Rect::new(query_x, input_y, query_w, 24.0),
            text: placeholder.to_string(),
            color: muted,
            size: 13.5,
            bold: false,
            align: TextAlign::Left,
            max_lines: 1,
        });
    } else {
        let display_query = if preedit.is_empty() {
            format!("{query}|")
        } else {
            format!("{query}[{preedit}]")
        };
        commands.push(PaintCmd::RichText {
            rect: Rect::new(query_x, input_y, query_w, 24.0),
            text: display_query,
            color: if preedit.is_empty() {
                on_surface
            } else {
                tertiary
            },
            size: 13.5,
            bold: false,
            align: TextAlign::Left,
            max_lines: 1,
        });
    }

    commands.push(PaintCmd::Text {
        rect: Rect::new(w - pad_x - count_w, border_w, count_w, input_h),
        text: count_text,
        color: muted,
        size: 11.0,
        bold: false,
        align: TextAlign::Right,
    });

    // 2. Divider line
    let div_y = border_w + input_h;
    commands.push(PaintCmd::RoundedRect {
        rect: Rect::new(border_w, div_y, w - border_w * 2.0, divider_h),
        radius: 0.0,
        fill: Some(outline_variant),
        stroke: None,
        stroke_width: 0.0,
    });

    // 3. Results list
    let list_y = div_y + divider_h + list_pad_y;
    if filtered.is_empty() {
        commands.push(PaintCmd::RichText {
            rect: Rect::new(pad_x, list_y + 6.0, w - pad_x * 2.0, row_h - 8.0),
            text: "No matches".to_string(),
            color: muted,
            size: 12.5,
            bold: false,
            align: TextAlign::Center,
            max_lines: 1,
        });
    } else {
        let end = (scroll_offset + visible_rows).min(filtered.len());
        for (vis_idx, item_idx) in (scroll_offset..end).enumerate() {
            let item = &filtered[item_idx];
            let ry = list_y + vis_idx as f32 * row_h;
            let row_rect = Rect::new(border_w + 4.0, ry, w - border_w * 2.0 - 8.0, row_h - 2.0);
            let is_sel = item_idx == selected;

            if is_sel {
                commands.push(PaintCmd::RoundedRect {
                    rect: row_rect,
                    radius: if bar.corner_radius > 0.0 { 4.0 } else { 0.0 },
                    fill: Some(surface_variant),
                    stroke: None,
                    stroke_width: 0.0,
                });
                commands.push(PaintCmd::RoundedRect {
                    rect: Rect::new(row_rect.x, row_rect.y, 3.0, row_rect.h),
                    radius: 0.0,
                    fill: Some(primary),
                    stroke: None,
                    stroke_width: 0.0,
                });
            }

            let text_x = row_rect.x + 12.0;
            let text_w = (row_rect.w - 22.0).max(80.0);
            if is_apps && !item.subtitle.is_empty() {
                commands.push(PaintCmd::RichText {
                    rect: Rect::new(text_x, ry + 3.0, text_w, 19.0),
                    text: item.title.clone(),
                    color: on_surface,
                    size: 13.0,
                    bold: is_sel,
                    align: TextAlign::Left,
                    max_lines: 1,
                });
                commands.push(PaintCmd::RichText {
                    rect: Rect::new(text_x, ry + 21.0, text_w, 16.0),
                    text: item.subtitle.clone(),
                    color: muted,
                    size: 10.5,
                    bold: false,
                    align: TextAlign::Left,
                    max_lines: 1,
                });
            } else {
                let text_y = ry + (row_h - 20.0) * 0.5;
                commands.push(PaintCmd::RichText {
                    rect: Rect::new(text_x, text_y, text_w, 22.0),
                    text: item.title.clone(),
                    color: on_surface,
                    size: 13.0,
                    bold: is_sel,
                    align: TextAlign::Left,
                    max_lines: 1,
                });
            }

            hit_targets.push(HitTarget {
                rect: row_rect,
                id: format!("launcher:row:{item_idx}"),
            });
        }
    }

    SurfaceSpec {
        id: SURFACE_ID.to_string(),
        namespace: NAMESPACE.to_string(),
        output: None,
        layer: Layer::Overlay,
        keyboard_interactivity: KeyboardMode::Exclusive,
        anchor: Anchor::TOP,
        exclusive_zone: 0,
        width: cfg.width.clamp(320, 960),
        height: total_h,
        margin: EdgeInsets {
            top: cfg.offset_y,
            ..EdgeInsets::default()
        },
        corner_radius: bar.corner_radius,
        background: bg,
        border_color: primary,
        border_width: border_w,
        commands,
        hit_targets,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use kaze_core::{Config, KeyModifiers};

    fn key(keysym: u32, utf8: Option<&str>, ctrl: bool) -> SystemEvent {
        SystemEvent::KeyInput {
            surface_id: SURFACE_ID.into(),
            key: KeyEvent {
                keysym,
                utf8: utf8.map(str::to_string),
                modifiers: KeyModifiers {
                    ctrl,
                    ..KeyModifiers::default()
                },
                pressed: true,
            },
        }
    }

    #[test]
    fn dmenu_filters_navigates_selects_and_frees_surface() {
        let mut state = AppState::new(Config::default());
        let mut ext = LauncherExtension::new();
        assert!(ext.surfaces().is_empty());

        {
            let mut ctx = ShellContext::new(&mut state);
            let res = ext.on_ipc(
                "dmenu-open",
                &[
                    "Display > ".into(),
                    "󰍹  Extend Right\n󰐕  New clean workspace (WS 2)\n󰈈  Tiếng Việt có dấu\n".into(),
                ],
                &mut ctx,
            );
            assert!(matches!(res, IpcResult::Handled { ok: true, .. }));
        }
        let specs = ext.surfaces();
        assert_eq!(specs.len(), 1);
        assert_eq!(specs[0].namespace, "kaze-launcher");
        assert_eq!(specs[0].keyboard_interactivity, KeyboardMode::Exclusive);

        // Type Vietnamese via IME commit to filter to the 3rd row.
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_event(
                &SystemEvent::ImeInput {
                    surface_id: SURFACE_ID.into(),
                    ime: ImeEvent::Preedit {
                        text: "việ".into(),
                        cursor_begin: 0,
                        cursor_end: 4,
                    },
                },
                &mut ctx,
            );
            ext.on_event(
                &SystemEvent::ImeInput {
                    surface_id: SURFACE_ID.into(),
                    ime: ImeEvent::Commit("việt".into()),
                },
                &mut ctx,
            );
            ext.on_event(&key(KEY_RETURN, None, false), &mut ctx);
            assert_eq!(
                ctx.actions,
                vec![ShellAction::DmenuReply {
                    selected: Some("󰈈  Tiếng Việt có dấu".into()),
                }]
            );
        }
        assert!(ext.surfaces().is_empty());
    }

    #[test]
    fn dmenu_cancels_on_escape_and_focus_loss() {
        let mut state = AppState::new(Config::default());
        let mut ext = LauncherExtension::new();

        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_ipc(
                "dmenu-open",
                &["Test > ".into(), "Alpha\nBeta\n".into()],
                &mut ctx,
            );
            ext.on_event(&key(KEY_ESCAPE, None, false), &mut ctx);
            assert_eq!(
                ctx.actions,
                vec![ShellAction::DmenuReply { selected: None }]
            );
        }
        assert!(ext.surfaces().is_empty());

        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_ipc(
                "dmenu-open",
                &["Test > ".into(), "Alpha\nBeta\n".into()],
                &mut ctx,
            );
            ext.on_event(
                &SystemEvent::KeyboardFocusLost {
                    surface_id: SURFACE_ID.into(),
                },
                &mut ctx,
            );
            assert_eq!(
                ctx.actions,
                vec![ShellAction::DmenuReply { selected: None }]
            );
        }
        assert!(ext.surfaces().is_empty());
    }

    #[test]
    fn app_launcher_launches_detached_and_respects_ctrl_n_ctrl_p() {
        let mut state = AppState::new(Config::default());
        let mut ext = LauncherExtension::new();
        ext.set_apps_for_test(vec![
            DesktopApp {
                id: "firefox.desktop".into(),
                name: "Firefox".into(),
                generic_name: "Web Browser".into(),
                comment: "Browse the Web".into(),
                keywords: "internet".into(),
                exec: "firefox %u".into(),
                terminal: false,
            },
            DesktopApp {
                id: "yazi.desktop".into(),
                name: "Yazi".into(),
                generic_name: "File Manager".into(),
                comment: "Terminal files".into(),
                keywords: "files".into(),
                exec: "yazi %u".into(),
                terminal: true,
            },
        ]);

        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_ipc("launcher-toggle", &[], &mut ctx);
            ext.on_event(&key(0x006e, None, true), &mut ctx); // Ctrl+N -> Yazi
            ext.on_event(&key(KEY_RETURN, None, false), &mut ctx);
            assert_eq!(
                ctx.actions,
                vec![ShellAction::SpawnDetachedApp {
                    program: "kaze-footclient".into(),
                    args: vec!["-N".into(), "-e".into(), "yazi".into()],
                }]
            );
        }
        assert!(ext.surfaces().is_empty());
    }

    #[test]
    fn fuzzy_score_ranks_prefix_above_subsequence() {
        let exact = fuzzy_score("foot", "Foot").expect("exact");
        let prefix = fuzzy_score("foo", "Foot Terminal").expect("prefix");
        let subseq = fuzzy_score("ftl", "Foot Terminal").expect("subseq");
        assert!(exact > prefix && prefix > subseq);
        assert!(fuzzy_score("xyz", "Foot").is_none());
    }
}
