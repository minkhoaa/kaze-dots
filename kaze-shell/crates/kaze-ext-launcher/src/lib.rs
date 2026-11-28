#![deny(clippy::unwrap_used)]

pub mod calc;
pub mod desktop;
pub mod emoji;
pub mod frecency;

use calc::{evaluate_calculator, looks_like_math_expression};
use desktop::{scan_applications, AppCategory, DesktopApp};
use emoji::{load_recent_emojis, recent_emoji_path, record_recent_emoji, search_emojis};
use frecency::FrecencyStore;
use kaze_core::text_input::matches_binding;
use kaze_core::{
    t, Anchor, AppState, DirtyFlags, EdgeInsets, HitTarget, I18nKey, ImeEvent, IpcResult,
    KazeExtension, KeyEvent, KeyboardMode, Layer, PaintCmd, PointerButton, Rect, ShellAction,
    ShellContext, SurfaceSpec, SystemEvent, TextAlign, TextInputOutcome, TextInputState,
};
use std::fs;
use std::path::PathBuf;

const SURFACE_ID: &str = "launcher:main";
const NAMESPACE: &str = "kaze-launcher";

const KEY_HOME: u32 = 0xff50;
const KEY_UP: u32 = 0xff52;
const KEY_DOWN: u32 = 0xff54;
const KEY_PAGE_UP: u32 = 0xff55;
const KEY_PAGE_DOWN: u32 = 0xff56;
const KEY_END: u32 = 0xff57;
const KEY_TAB: u32 = 0xff09;

#[derive(Debug, Clone, PartialEq, Eq)]
enum LauncherMode {
    Closed,
    Apps,
    Dmenu { prompt: String, items: Vec<String> },
}

#[derive(Debug, Clone)]
enum ItemKind {
    App(usize),
    Dmenu(usize),
    Calc { copy_value: String, is_error: bool },
    Emoji(String),
    Panel(&'static str),
    Wallpaper(PathBuf),
}

#[derive(Debug, Clone)]
struct FilteredItem {
    kind: ItemKind,
    title: String,
    subtitle: String,
    score: i32,
}

#[derive(Debug, Clone, Copy)]
struct PanelItem {
    id: &'static str,
    title_en: &'static str,
    title_vi: &'static str,
    subtitle: &'static str,
}

const PANELS: &[PanelItem] = &[
    PanelItem {
        id: "cc",
        title_en: "Control Center",
        title_vi: "Trung tâm điều khiển",
        subtitle: "Open quick toggles, sliders & notifications",
    },
    PanelItem {
        id: "clip",
        title_en: "Clipboard History",
        title_vi: "Lịch sử bảng tạm",
        subtitle: "Browse pinned & encrypted clipboard entries",
    },
    PanelItem {
        id: "session",
        title_en: "Session Power Menu",
        title_vi: "Menu nguồn phiên",
        subtitle: "Lock, Suspend, Hibernate, Logout, Reboot, Shutdown",
    },
    PanelItem {
        id: "theme",
        title_en: "Toggle Light / Dark Theme",
        title_vi: "Đổi giao diện Sáng / Tối",
        subtitle: "Switch active Noctalia color mode & apply templates",
    },
    PanelItem {
        id: "layout",
        title_en: "Cycle Bar Layout Preset",
        title_vi: "Chuyển bố cục thanh Bar",
        subtitle: "Cycle Omarchy -> Island -> Swiss -> Ghost",
    },
    PanelItem {
        id: "offline",
        title_en: "Toggle Offline Mode",
        title_vi: "Bật / Tắt Chế độ Ngoại tuyến",
        subtitle: "Block all outbound network queries globally",
    },
    PanelItem {
        id: "settings",
        title_en: "Reload Configuration",
        title_vi: "Tải lại cấu hình",
        subtitle: "Reload config.toml & settings.toml overrides",
    },
];

/// Unified multi-provider Launcher (`Apps`, `Calculator`, `Emoji`, `Panels`, `Wallpaper`, `dmenu`).
///
/// Zero T0 overhead: `.desktop` scanning, wallpaper discovery, and Wayland surface creation
/// remain completely dormant until opened; closing drops the surface down to 0 KiB SHM.
pub struct LauncherExtension {
    mode: LauncherMode,
    apps: Vec<DesktopApp>,
    apps_loaded: bool,
    apps_dirty: bool,
    wallpapers: Vec<PathBuf>,
    wallpapers_loaded: bool,
    frecency: FrecencyStore,
    frecency_path: Option<PathBuf>,
    recent_emojis: Vec<String>,
    recent_emoji_path: Option<PathBuf>,
    category: AppCategory,
    grid_mode: bool,
    input: TextInputState,
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
        let frecency_path = FrecencyStore::default_path();
        let frecency = frecency_path
            .as_deref()
            .map(FrecencyStore::load)
            .unwrap_or_default();
        let recent_emoji_path = recent_emoji_path();
        let recent_emojis = recent_emoji_path
            .as_deref()
            .map(load_recent_emojis)
            .unwrap_or_default();
        Self {
            mode: LauncherMode::Closed,
            apps: Vec::new(),
            apps_loaded: false,
            apps_dirty: false,
            wallpapers: Vec::new(),
            wallpapers_loaded: false,
            frecency,
            frecency_path,
            recent_emojis,
            recent_emoji_path,
            category: AppCategory::All,
            grid_mode: false,
            input: TextInputState::new(false),
            filtered: Vec::new(),
            selected: 0,
            scroll_offset: 0,
            cached_spec: None,
        }
    }

    pub fn is_open(&self) -> bool {
        !matches!(self.mode, LauncherMode::Closed)
    }

    pub fn is_grid_mode(&self) -> bool {
        self.grid_mode
    }

    pub fn active_category(&self) -> AppCategory {
        self.category
    }

    pub fn set_apps_for_test(&mut self, apps: Vec<DesktopApp>) {
        self.apps = apps;
        self.apps_loaded = true;
        self.apps_dirty = false;
    }

    pub fn set_wallpapers_for_test(&mut self, walls: Vec<PathBuf>) {
        self.wallpapers = walls;
        self.wallpapers_loaded = true;
    }

    fn ensure_apps_loaded(&mut self) {
        if !self.apps_loaded || self.apps_dirty {
            self.apps = scan_applications();
            self.apps_loaded = true;
            self.apps_dirty = false;
        }
    }

    fn ensure_wallpapers_loaded(&mut self, state: &AppState) {
        if self.wallpapers_loaded {
            return;
        }
        self.wallpapers_loaded = true;
        self.wallpapers.clear();
        let mut dirs = Vec::new();
        if let Some(ref cfg_dir) = state.config.wallpaper.directory {
            dirs.push(expand_tilde_path(&cfg_dir.to_string_lossy()));
        }
        dirs.push(expand_tilde_path("~/Pictures/Wallpapers"));
        dirs.push(expand_tilde_path("~/.local/share/wallpapers"));

        for dir in dirs {
            let Ok(rd) = fs::read_dir(&dir) else {
                continue;
            };
            for entry in rd.flatten() {
                let p = entry.path();
                if p.is_file() {
                    let is_img = p.extension().and_then(|e| e.to_str()).is_some_and(|e| {
                        matches!(
                            e.to_ascii_lowercase().as_str(),
                            "png" | "jpg" | "jpeg" | "webp"
                        )
                    });
                    if is_img && !self.wallpapers.contains(&p) {
                        self.wallpapers.push(p);
                    }
                }
            }
        }
        self.wallpapers.sort();
    }

    fn effective_query(&self) -> String {
        if self.input.preedit.is_empty() {
            self.input.text.clone()
        } else {
            let safe_cur = self.input.cursor.min(self.input.text.len());
            format!(
                "{}{}{}",
                &self.input.text[..safe_cur],
                self.input.preedit,
                &self.input.text[safe_cur..]
            )
        }
    }

    fn refilter(&mut self, state: &AppState) {
        let max_rows = state.config.launcher.max_rows;
        let q = self.effective_query();
        let trimmed = q.trim();
        self.filtered.clear();

        match &self.mode {
            LauncherMode::Closed => {}
            LauncherMode::Dmenu { items, .. } => {
                for (index, line) in items.iter().enumerate() {
                    if let Some(score) = fuzzy_score(&q, line) {
                        self.filtered.push(FilteredItem {
                            kind: ItemKind::Dmenu(index),
                            title: line.clone(),
                            subtitle: String::new(),
                            score,
                        });
                    }
                }
                if !trimmed.is_empty() {
                    self.filtered.sort_by_key(|a| std::cmp::Reverse(a.score));
                }
            }
            LauncherMode::Apps => {
                if let Some(sub) = trimmed.strip_prefix("/emoji") {
                    for (entry, score) in search_emojis(sub.trim(), &self.recent_emojis) {
                        self.filtered.push(FilteredItem {
                            kind: ItemKind::Emoji(entry.glyph.to_string()),
                            title: format!("{}  {}", entry.glyph, entry.keywords),
                            subtitle: "Enter copy emoji".into(),
                            score,
                        });
                    }
                } else if let Some(sub) = trimmed.strip_prefix("/pan") {
                    let sub_q = sub.trim();
                    for p in PANELS {
                        let title = match state.locale {
                            kaze_core::Locale::Vi => p.title_vi,
                            kaze_core::Locale::En => p.title_en,
                        };
                        if let Some(score) = fuzzy_score(sub_q, &format!("{title} {}", p.id)) {
                            self.filtered.push(FilteredItem {
                                kind: ItemKind::Panel(p.id),
                                title: title.to_string(),
                                subtitle: p.subtitle.to_string(),
                                score,
                            });
                        }
                    }
                    self.filtered.sort_by_key(|a| std::cmp::Reverse(a.score));
                } else if let Some(sub) = trimmed.strip_prefix("/wall") {
                    self.ensure_wallpapers_loaded(state);
                    let sub_q = sub.trim();
                    for wp in &self.wallpapers {
                        let name = wp
                            .file_name()
                            .and_then(|n| n.to_str())
                            .unwrap_or("wallpaper");
                        if let Some(score) = fuzzy_score(sub_q, name) {
                            self.filtered.push(FilteredItem {
                                kind: ItemKind::Wallpaper(wp.clone()),
                                title: name.to_string(),
                                subtitle: wp.display().to_string(),
                                score,
                            });
                        }
                    }
                    self.filtered.sort_by_key(|a| std::cmp::Reverse(a.score));
                } else {
                    if looks_like_math_expression(trimmed) {
                        let calc = evaluate_calculator(trimmed, state.offline_mode);
                        self.filtered.push(FilteredItem {
                            kind: ItemKind::Calc {
                                copy_value: calc.copy_value,
                                is_error: calc.is_error,
                            },
                            title: calc.display,
                            subtitle: if calc.is_error {
                                "Calculator error".into()
                            } else {
                                "Calculator · Enter copies result".into()
                            },
                            score: 10_000,
                        });
                    }
                    if !trimmed.starts_with('=') && !trimmed.starts_with("/calc") {
                        for (index, app) in self.apps.iter().enumerate() {
                            if !self.category.matches_app(app) {
                                continue;
                            }
                            if let Some(score) = score_desktop_app(&q, app) {
                                let frec = self.frecency.score(&app.id);
                                self.filtered.push(FilteredItem {
                                    kind: ItemKind::App(index),
                                    title: app.name.clone(),
                                    subtitle: app.subtitle().to_string(),
                                    score: score + frec,
                                });
                            }
                        }
                        self.filtered.sort_by_key(|a| std::cmp::Reverse(a.score));
                    }
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

    fn visible_capacity(&self, max_rows: usize) -> usize {
        let rows = max_rows.max(1);
        if self.grid_mode && matches!(self.mode, LauncherMode::Apps) {
            rows * 3
        } else {
            rows
        }
    }

    fn clamp_scroll(&mut self, max_rows: usize) {
        let cap = self.visible_capacity(max_rows);
        if self.selected < self.scroll_offset {
            self.scroll_offset = self.selected;
        } else if self.selected >= self.scroll_offset + cap {
            self.scroll_offset = self.selected + 1 - cap;
        }
        let max_offset = self.filtered.len().saturating_sub(cap);
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

    fn open_apps(&mut self, prefix: Option<&str>, ctx: &mut ShellContext) -> DirtyFlags {
        if matches!(self.mode, LauncherMode::Dmenu { .. }) {
            ctx.push_action(ShellAction::DmenuReply { selected: None });
        }
        self.ensure_apps_loaded();
        self.mode = LauncherMode::Apps;
        self.input.clear();
        if let Some(p) = prefix {
            let trimmed = p.trim();
            if !trimmed.is_empty() {
                let text = if trimmed.starts_with('/') || trimmed.starts_with('=') {
                    format!("{trimmed} ")
                } else {
                    trimmed.to_string()
                };
                self.input.set_text(&text);
            }
        }
        self.selected = 0;
        self.scroll_offset = 0;
        self.refilter(ctx.state);
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
        self.grid_mode = false;
        self.input.clear();
        self.selected = 0;
        self.scroll_offset = 0;
        self.refilter(ctx.state);
        self.rebuild(ctx.state);
        DirtyFlags::LAUNCHER | DirtyFlags::LAYOUT
    }

    fn close_cancel(&mut self, ctx: &mut ShellContext) -> DirtyFlags {
        if !self.is_open() {
            return DirtyFlags::NONE;
        }
        let was_dmenu = matches!(self.mode, LauncherMode::Dmenu { .. });
        self.mode = LauncherMode::Closed;
        self.input.clear();
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

        match chosen.kind {
            ItemKind::Dmenu(idx) => {
                let selected_line = match &self.mode {
                    LauncherMode::Dmenu { items, .. } => items.get(idx).cloned(),
                    _ => None,
                };
                self.mode = LauncherMode::Closed;
                self.input.clear();
                self.filtered.clear();
                self.selected = 0;
                self.scroll_offset = 0;
                self.cached_spec = None;
                ctx.push_action(ShellAction::DmenuReply {
                    selected: selected_line,
                });
                DirtyFlags::LAUNCHER | DirtyFlags::LAYOUT
            }
            ItemKind::App(idx) => {
                let (cmd, app_id) = match self.apps.get(idx) {
                    Some(app) => (app.build_command(), Some(app.id.clone())),
                    None => (None, None),
                };
                if let Some(id) = app_id {
                    self.frecency.record_launch(&id);
                    if let Some(ref p) = self.frecency_path {
                        self.frecency.save(p);
                    }
                }
                self.mode = LauncherMode::Closed;
                self.input.clear();
                self.filtered.clear();
                self.selected = 0;
                self.scroll_offset = 0;
                self.cached_spec = None;
                if let Some((program, args)) = cmd {
                    ctx.push_action(ShellAction::SpawnDetachedApp { program, args });
                }
                DirtyFlags::LAUNCHER | DirtyFlags::LAYOUT
            }
            ItemKind::Calc {
                copy_value,
                is_error,
            } => {
                if is_error || copy_value.is_empty() {
                    return DirtyFlags::NONE;
                }
                ctx.push_action(ShellAction::SetClipboardText(copy_value));
                self.close_cancel(ctx)
            }
            ItemKind::Emoji(glyph) => {
                self.recent_emojis.retain(|g| g != &glyph);
                self.recent_emojis.insert(0, glyph.clone());
                self.recent_emojis.truncate(24);
                if let Some(ref p) = self.recent_emoji_path {
                    record_recent_emoji(p, &glyph);
                }
                ctx.push_action(ShellAction::SetClipboardText(glyph));
                self.close_cancel(ctx)
            }
            ItemKind::Panel(id) => {
                self.mode = LauncherMode::Closed;
                self.input.clear();
                self.filtered.clear();
                self.selected = 0;
                self.scroll_offset = 0;
                self.cached_spec = None;
                match id {
                    "cc" => ctx.push_action(ShellAction::ToggleControlCenter),
                    "clip" => {
                        ctx.push_action(ShellAction::SpawnCommand {
                            program: "kaze-shell".into(),
                            args: vec!["msg".into(), "clipboard-toggle".into()],
                        });
                    }
                    "session" => {
                        ctx.push_action(ShellAction::SpawnCommand {
                            program: "kaze-shell".into(),
                            args: vec!["msg".into(), "session-menu-toggle".into()],
                        });
                    }
                    "theme" => ctx.push_action(ShellAction::ThemeModeToggle),
                    "layout" => ctx.push_action(ShellAction::LayoutCycle),
                    "offline" => {
                        ctx.push_action(ShellAction::SpawnCommand {
                            program: "kaze-shell".into(),
                            args: vec!["msg".into(), "offline-mode-toggle".into()],
                        });
                    }
                    "settings" => ctx.push_action(ShellAction::ReloadConfig),
                    _ => {}
                }
                DirtyFlags::LAUNCHER | DirtyFlags::LAYOUT
            }
            ItemKind::Wallpaper(path) => {
                let outputs: Vec<(String, u32, u32)> = ctx
                    .state
                    .outputs
                    .values()
                    .filter(|o| o.name != "kaze-share" && o.width > 0 && o.height > 0)
                    .map(|o| (o.name.clone(), o.width as u32, o.height as u32))
                    .collect();
                let extract = ctx.state.config.wallpaper.dynamic_palette;
                self.mode = LauncherMode::Closed;
                self.input.clear();
                self.filtered.clear();
                self.selected = 0;
                self.scroll_offset = 0;
                self.cached_spec = None;
                ctx.push_action(ShellAction::RequestWallpaperLoad {
                    path,
                    outputs,
                    extract_palette: extract,
                });
                DirtyFlags::LAUNCHER | DirtyFlags::LAYOUT
            }
        }
    }

    fn handle_key(&mut self, key: &KeyEvent, ctx: &mut ShellContext) -> DirtyFlags {
        if !self.is_open() || !key.pressed {
            return DirtyFlags::NONE;
        }
        let max_rows = ctx.state.config.launcher.max_rows;

        if matches!(self.mode, LauncherMode::Apps)
            && (key.keysym == KEY_TAB
                || matches_binding(key, &ctx.state.config.input.keybinds.toggle_layout))
        {
            if key.modifiers.shift {
                let idx = AppCategory::ALL
                    .iter()
                    .position(|c| *c == self.category)
                    .unwrap_or(0);
                self.category = AppCategory::ALL[(idx + 1) % AppCategory::ALL.len()];
                self.selected = 0;
                self.refilter(ctx.state);
            } else {
                self.grid_mode = !self.grid_mode;
                self.clamp_scroll(max_rows);
            }
            self.rebuild(ctx.state);
            return DirtyFlags::LAUNCHER | DirtyFlags::LAYOUT;
        }

        if key.modifiers.ctrl {
            match key.keysym {
                0x006e | 0x004e => {
                    self.move_selection(1, max_rows);
                    self.rebuild(ctx.state);
                    return DirtyFlags::LAUNCHER;
                }
                0x0070 | 0x0050 => {
                    self.move_selection(-1, max_rows);
                    self.rebuild(ctx.state);
                    return DirtyFlags::LAUNCHER;
                }
                0x0067 | 0x0047 => {
                    return self.close_cancel(ctx);
                }
                0x0063 | 0x0043 if self.input.selection_range().is_none() => {
                    return self.close_cancel(ctx);
                }
                _ => {}
            }
        }

        match key.keysym {
            KEY_DOWN => {
                let step = if self.grid_mode && matches!(self.mode, LauncherMode::Apps) {
                    3
                } else {
                    1
                };
                self.move_selection(step, max_rows);
                self.rebuild(ctx.state);
                DirtyFlags::LAUNCHER
            }
            KEY_UP => {
                let step = if self.grid_mode && matches!(self.mode, LauncherMode::Apps) {
                    -3
                } else {
                    -1
                };
                self.move_selection(step, max_rows);
                self.rebuild(ctx.state);
                DirtyFlags::LAUNCHER
            }
            KEY_PAGE_DOWN => {
                self.move_selection(self.visible_capacity(max_rows) as isize, max_rows);
                self.rebuild(ctx.state);
                DirtyFlags::LAUNCHER
            }
            KEY_PAGE_UP => {
                self.move_selection(-(self.visible_capacity(max_rows) as isize), max_rows);
                self.rebuild(ctx.state);
                DirtyFlags::LAUNCHER
            }
            KEY_HOME if self.input.text.is_empty() && !self.filtered.is_empty() => {
                self.selected = 0;
                self.clamp_scroll(max_rows);
                self.rebuild(ctx.state);
                DirtyFlags::LAUNCHER
            }
            KEY_END if self.input.text.is_empty() && !self.filtered.is_empty() => {
                self.selected = self.filtered.len() - 1;
                self.clamp_scroll(max_rows);
                self.rebuild(ctx.state);
                DirtyFlags::LAUNCHER
            }
            _ => match self.input.handle_key(key, &ctx.state.config.input.keybinds) {
                TextInputOutcome::Cancel => self.close_cancel(ctx),
                TextInputOutcome::Submit => self.activate_selected(ctx),
                TextInputOutcome::Copy(s) => {
                    ctx.push_action(ShellAction::SetClipboardText(s));
                    DirtyFlags::NONE
                }
                TextInputOutcome::Cut(s) => {
                    ctx.push_action(ShellAction::SetClipboardText(s));
                    self.selected = 0;
                    self.refilter(ctx.state);
                    self.rebuild(ctx.state);
                    DirtyFlags::LAUNCHER
                }
                TextInputOutcome::RequestPaste => {
                    ctx.push_action(ShellAction::RequestClipboardPaste {
                        surface_id: SURFACE_ID.to_string(),
                    });
                    DirtyFlags::NONE
                }
                TextInputOutcome::Changed => {
                    self.selected = 0;
                    self.refilter(ctx.state);
                    self.rebuild(ctx.state);
                    DirtyFlags::LAUNCHER
                }
                TextInputOutcome::None => DirtyFlags::NONE,
            },
        }
    }

    fn handle_ime(&mut self, ime: &ImeEvent, ctx: &mut ShellContext) -> DirtyFlags {
        if !self.is_open() {
            return DirtyFlags::NONE;
        }
        if !self.input.handle_ime(ime) {
            return DirtyFlags::NONE;
        }
        if matches!(
            ime,
            ImeEvent::Commit(_) | ImeEvent::DeleteSurrounding { .. }
        ) {
            self.selected = 0;
        }
        self.refilter(ctx.state);
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
            self.category,
            self.grid_mode,
            &self.input,
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
                    if target_id == "launcher:view-toggle" {
                        self.grid_mode = !self.grid_mode;
                        self.clamp_scroll(ctx.state.config.launcher.max_rows);
                        self.rebuild(ctx.state);
                        return DirtyFlags::LAUNCHER | DirtyFlags::LAYOUT;
                    }
                    if let Some(cat_idx) = target_id
                        .strip_prefix("launcher:cat:")
                        .and_then(|s| s.parse::<usize>().ok())
                    {
                        if let Some(&cat) = AppCategory::ALL.get(cat_idx) {
                            self.category = cat;
                            self.selected = 0;
                            self.refilter(ctx.state);
                            self.rebuild(ctx.state);
                            return DirtyFlags::LAUNCHER | DirtyFlags::LAYOUT;
                        }
                    }
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
                    self.refilter(ctx.state);
                    self.rebuild(ctx.state);
                    return DirtyFlags::LAUNCHER;
                }
                DirtyFlags::NONE
            }
            SystemEvent::ClipboardTextPasted { surface_id, text }
                if surface_id == SURFACE_ID && self.is_open() =>
            {
                if self.input.paste_text(text) {
                    self.selected = 0;
                    self.refilter(ctx.state);
                    self.rebuild(ctx.state);
                    DirtyFlags::LAUNCHER
                } else {
                    DirtyFlags::NONE
                }
            }
            SystemEvent::ConfigReloaded
            | SystemEvent::LocaleChanged(_)
            | SystemEvent::OfflineModeChanged(_)
            | SystemEvent::ThemeChanged(_)
            | SystemEvent::LayoutPresetChanged(_) => {
                if !ctx.state.config.launcher.enabled {
                    return self.close_cancel(ctx);
                }
                if self.is_open() {
                    self.refilter(ctx.state);
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
                    let prefix = args.first().map(String::as_str);
                    let dirty = self.open_apps(prefix, ctx);
                    IpcResult::Handled {
                        ok: true,
                        message: "opened".into(),
                        dirty,
                    }
                }
            }
            "launcher-open" | "launcher" => {
                if !ctx.state.config.launcher.enabled {
                    return IpcResult::Handled {
                        ok: false,
                        message: "launcher disabled in config".into(),
                        dirty: DirtyFlags::NONE,
                    };
                }
                let prefix = args.first().map(String::as_str);
                let dirty = self.open_apps(prefix, ctx);
                IpcResult::Handled {
                    ok: true,
                    message: "opened".into(),
                    dirty,
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
                    self.input.set_text(q);
                    self.selected = 0;
                    self.refilter(ctx.state);
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

fn expand_tilde_path(raw: &str) -> PathBuf {
    if let Some(rest) = raw.strip_prefix("~/") {
        if let Some(home) = std::env::var_os("HOME") {
            return PathBuf::from(home).join(rest);
        }
    }
    PathBuf::from(raw)
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
        let tok_chars: Vec<char> = tok_lower.chars().collect();
        if tok_chars.is_empty() {
            continue;
        }
        total += fuzzy_token_score(&tok_chars, &cand_chars)?;
    }

    Some(total)
}

fn fuzzy_token_score(needle: &[char], haystack: &[char]) -> Option<i32> {
    if needle.len() > haystack.len() {
        return None;
    }

    if haystack.len() >= needle.len() {
        for start in 0..=haystack.len() - needle.len() {
            if haystack[start..start + needle.len()] == *needle {
                let mut score = 420 - (start as i32 * 4).min(120);
                if start == 0 {
                    score += 180;
                } else if !haystack[start - 1].is_alphanumeric() {
                    score += 110;
                }
                if haystack.len() == needle.len() {
                    score += 120;
                }
                return Some(score);
            }
        }
    }

    let mut score = 120i32;
    let mut h_idx = 0usize;
    let mut prev_match: Option<usize> = None;

    for &nc in needle {
        let mut found = None;
        while h_idx < haystack.len() {
            if haystack[h_idx] == nc {
                found = Some(h_idx);
                h_idx += 1;
                break;
            }
            h_idx += 1;
        }
        let pos = found?;
        if let Some(prev) = prev_match {
            if pos == prev + 1 {
                score += 24;
            } else {
                score -= ((pos - prev - 1) as i32).min(12);
            }
        } else {
            score -= (pos as i32).min(30);
        }
        if pos == 0 || !haystack[pos - 1].is_alphanumeric() {
            score += 22;
        }
        prev_match = Some(pos);
    }

    Some(score)
}

#[allow(clippy::too_many_arguments)]
fn build_launcher_surface(
    state: &AppState,
    mode: &LauncherMode,
    category: AppCategory,
    grid_mode: bool,
    input: &TextInputState,
    filtered: &[FilteredItem],
    selected: usize,
    scroll_offset: usize,
) -> SurfaceSpec {
    let cfg = &state.config.launcher;
    let bar = &state.config.bar;
    let colors = state.palette.for_mode(state.theme_mode);
    let loc = state.locale;

    let bg = colors.surface_color().with_opacity(bar.background_opacity);
    let primary = colors.primary_color();
    let tertiary = colors.tertiary_color();
    let on_surface = colors.on_surface_color();
    let muted = colors.on_surface_variant_color();
    let outline_variant = colors.outline_variant_color();
    let surface_container = colors.surface_container_color();
    let surface_variant = colors.surface_variant_color();
    let selection_color = colors.secondary_color().with_opacity(0.35);

    let is_apps = matches!(mode, LauncherMode::Apps);
    let prompt = match mode {
        LauncherMode::Apps => t(loc, I18nKey::LauncherPromptApps).to_string(),
        LauncherMode::Dmenu { prompt, .. } => prompt.clone(),
        LauncherMode::Closed => String::new(),
    };
    let total_count = match mode {
        LauncherMode::Apps => filtered.len(),
        LauncherMode::Dmenu { items, .. } => items.len(),
        LauncherMode::Closed => 0,
    };

    let border_w = bar.border_width.max(2.0);
    let w = cfg.width.clamp(420, 960) as f32;
    let pad_x = border_w + 14.0;
    let input_h = 44.0f32;
    let cat_bar_h = if is_apps { 28.0f32 } else { 0.0f32 };
    let divider_h = 1.0f32;
    let row_h = if is_apps { 40.0f32 } else { 34.0f32 };
    let max_rows = cfg.max_rows.max(1);
    let grid_active = is_apps && grid_mode && !filtered.is_empty();
    let visible_rows = if grid_active {
        let vis_items = filtered
            .len()
            .saturating_sub(scroll_offset)
            .min(max_rows * 3);
        vis_items.div_ceil(3).max(1)
    } else {
        filtered.len().clamp(1, max_rows)
    };
    let tile_h = 62.0f32;
    let list_h = if grid_active {
        visible_rows as f32 * tile_h
    } else {
        visible_rows as f32 * row_h
    };
    let list_pad_y = 6.0f32;
    let total_h = (border_w * 2.0 + input_h + cat_bar_h + divider_h + list_pad_y * 2.0 + list_h)
        .ceil() as u32;

    let mut commands = Vec::with_capacity(visible_rows * 6 + 24);
    let mut hit_targets = Vec::with_capacity(visible_rows * 3 + 8);

    // 1. Input bar
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
    let input_y = border_w + 10.0;

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
    let placeholder = if is_apps {
        t(loc, I18nKey::LauncherPlaceholderApps)
    } else {
        t(loc, I18nKey::LauncherPlaceholderFilter)
    };
    commands.push(PaintCmd::TextInputField {
        rect: Rect::new(query_x, input_y, query_w, 24.0),
        text: input.text.clone(),
        preedit: input.preedit.clone(),
        cursor_byte: input.cursor,
        selection: input.selection_range(),
        placeholder: placeholder.to_string(),
        password_mode: false,
        color: on_surface,
        preedit_color: tertiary,
        selection_color,
        placeholder_color: muted,
        size: 13.5,
    });
    let safe_cur = input.cursor.min(input.text.len());
    let chars_before = input.text[..safe_cur].chars().count() + input.preedit.chars().count();
    let caret_x = (query_x + (chars_before as f32) * 8.0).min(query_x + query_w - 4.0);
    let ime_cursor_rect = Some(Rect::new(caret_x, input_y, 2.0, 24.0));

    commands.push(PaintCmd::Text {
        rect: Rect::new(w - pad_x - count_w, border_w, count_w, input_h),
        text: count_text,
        color: muted,
        size: 11.0,
        bold: false,
        align: TextAlign::Right,
    });

    // Optional Category & List/Grid bar in Apps mode
    let mut div_y = border_w + input_h;
    if is_apps {
        let mut cx = pad_x;
        for (idx, cat) in AppCategory::ALL.iter().enumerate() {
            let active = *cat == category;
            let tab_w = 50.0f32;
            let tab_rect = Rect::new(cx, div_y + 3.0, tab_w, cat_bar_h - 6.0);
            if active {
                commands.push(PaintCmd::RoundedRect {
                    rect: tab_rect,
                    radius: 4.0,
                    fill: Some(surface_variant),
                    stroke: None,
                    stroke_width: 0.0,
                });
            }
            commands.push(PaintCmd::Text {
                rect: tab_rect,
                text: cat.label().to_string(),
                color: if active { primary } else { muted },
                size: 10.5,
                bold: active,
                align: TextAlign::Center,
            });
            hit_targets.push(HitTarget {
                rect: tab_rect,
                id: format!("launcher:cat:{idx}"),
            });
            cx += tab_w + 4.0;
        }
        let view_rect = Rect::new(w - pad_x - 56.0, div_y + 3.0, 56.0, cat_bar_h - 6.0);
        commands.push(PaintCmd::RoundedRect {
            rect: view_rect,
            radius: 4.0,
            fill: Some(surface_variant),
            stroke: None,
            stroke_width: 0.0,
        });
        commands.push(PaintCmd::Text {
            rect: view_rect,
            text: if grid_mode { "Grid" } else { "List" }.to_string(),
            color: on_surface,
            size: 10.5,
            bold: true,
            align: TextAlign::Center,
        });
        hit_targets.push(HitTarget {
            rect: view_rect,
            id: "launcher:view-toggle".into(),
        });
        div_y += cat_bar_h;
    }

    commands.push(PaintCmd::RoundedRect {
        rect: Rect::new(border_w, div_y, w - border_w * 2.0, divider_h),
        radius: 0.0,
        fill: Some(outline_variant),
        stroke: None,
        stroke_width: 0.0,
    });

    let list_y = div_y + divider_h + list_pad_y;
    if filtered.is_empty() {
        commands.push(PaintCmd::RichText {
            rect: Rect::new(pad_x, list_y + 6.0, w - pad_x * 2.0, row_h - 8.0),
            text: t(loc, I18nKey::LauncherNoMatches).to_string(),
            color: muted,
            size: 12.5,
            bold: false,
            align: TextAlign::Center,
            max_lines: 1,
        });
    } else if grid_active {
        let cap = max_rows * 3;
        let end = (scroll_offset + cap).min(filtered.len());
        let inner_w = w - border_w * 2.0 - 16.0;
        let col_gap = 8.0f32;
        let tile_w = (inner_w - col_gap * 2.0) / 3.0;
        for (vis_idx, item_idx) in (scroll_offset..end).enumerate() {
            let item = &filtered[item_idx];
            let col = vis_idx % 3;
            let row = vis_idx / 3;
            let tx = border_w + 8.0 + col as f32 * (tile_w + col_gap);
            let ty = list_y + row as f32 * tile_h;
            let tile_rect = Rect::new(tx, ty, tile_w, tile_h - 6.0);
            let is_sel = item_idx == selected;
            commands.push(PaintCmd::RoundedRect {
                rect: tile_rect,
                radius: 6.0,
                fill: Some(if is_sel {
                    surface_variant
                } else {
                    surface_container
                }),
                stroke: if is_sel { Some(primary) } else { None },
                stroke_width: if is_sel { 1.5 } else { 0.0 },
            });
            commands.push(PaintCmd::RichText {
                rect: Rect::new(tx + 8.0, ty + 8.0, tile_w - 16.0, 22.0),
                text: item.title.clone(),
                color: on_surface,
                size: 12.0,
                bold: is_sel,
                align: TextAlign::Center,
                max_lines: 1,
            });
            commands.push(PaintCmd::RichText {
                rect: Rect::new(tx + 8.0, ty + 32.0, tile_w - 16.0, 16.0),
                text: item.subtitle.clone(),
                color: muted,
                size: 9.5,
                bold: false,
                align: TextAlign::Center,
                max_lines: 1,
            });
            hit_targets.push(HitTarget {
                rect: tile_rect,
                id: format!("launcher:row:{item_idx}"),
            });
        }
    } else {
        let end = (scroll_offset + max_rows).min(filtered.len());
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
        width: cfg.width.clamp(420, 960),
        height: total_h,
        margin: EdgeInsets {
            top: cfg.offset_y,
            ..EdgeInsets::default()
        },
        corner_radius: bar
            .corner_radius
            .max(state.layout_preset.overlay_corner_radius()),
        background: bg,
        border_color: primary,
        border_width: border_w,
        commands,
        hit_targets,
        animating: false,
        input_regions: None,
        ime_cursor_rect,
        track_pointer_motion: false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use kaze_core::{Config, KeyModifiers};

    const KEY_RETURN: u32 = 0xff0d;
    const KEY_ESCAPE: u32 = 0xff1b;

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

    fn sample_apps() -> Vec<DesktopApp> {
        vec![
            DesktopApp {
                id: "firefox.desktop".into(),
                name: "Firefox".into(),
                generic_name: "Web Browser".into(),
                comment: "Browse the Web".into(),
                keywords: "internet".into(),
                exec: "firefox %u".into(),
                icon: String::new(),
                startup_wm_class: String::new(),
                terminal: false,
                categories: vec!["Network".into(), "WebBrowser".into()],
                actions: vec![],
            },
            DesktopApp {
                id: "yazi.desktop".into(),
                name: "Yazi".into(),
                generic_name: "File Manager".into(),
                comment: "Terminal files".into(),
                keywords: "files".into(),
                exec: "yazi %u".into(),
                icon: String::new(),
                startup_wm_class: String::new(),
                terminal: true,
                categories: vec!["System".into(), "Utility".into()],
                actions: vec![],
            },
        ]
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
        assert_eq!(ext.surfaces().len(), 1);
        {
            let mut ctx = ShellContext::new(&mut state);
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
    }

    #[test]
    fn app_launcher_supports_categories_grid_toggle_calculator_and_emoji() {
        let mut state = AppState::new(Config::default());
        state.offline_mode = true;
        let mut ext = LauncherExtension::new();
        ext.set_apps_for_test(sample_apps());

        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_ipc("launcher-toggle", &[], &mut ctx);
            assert_eq!(ext.filtered.len(), 2);

            // Tab toggles List <-> Grid.
            assert!(!ext.is_grid_mode());
            ext.on_event(&key(KEY_TAB, None, false), &mut ctx);
            assert!(ext.is_grid_mode());

            // Category filter narrows to System.
            ext.on_event(
                &SystemEvent::PointerClick {
                    surface_id: SURFACE_ID.into(),
                    target_id: "launcher:cat:4".into(),
                    button: PointerButton::Left,
                },
                &mut ctx,
            );
            assert_eq!(ext.active_category(), AppCategory::System);
            assert_eq!(ext.filtered.len(), 1);
            assert_eq!(ext.filtered[0].title, "Yazi");

            // Calculator copies `70` cleanly on Enter.
            ext.on_event(
                &SystemEvent::ImeInput {
                    surface_id: SURFACE_ID.into(),
                    ime: ImeEvent::Commit("= (12 + 8) * 3.5".into()),
                },
                &mut ctx,
            );
            ext.on_event(&key(KEY_RETURN, None, false), &mut ctx);
            assert!(ctx
                .actions
                .contains(&ShellAction::SetClipboardText("70".into())));
        }
        assert!(ext.surfaces().is_empty());

        // Emoji provider opened via `launcher-open /emoji` copies selected glyph.
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_ipc("launcher-open", &["/emoji".into()], &mut ctx);
            ext.on_event(
                &SystemEvent::ImeInput {
                    surface_id: SURFACE_ID.into(),
                    ime: ImeEvent::Commit("lua".into()),
                },
                &mut ctx,
            );
            ext.on_event(&key(KEY_RETURN, None, false), &mut ctx);
            assert!(ctx
                .actions
                .contains(&ShellAction::SetClipboardText("🔥".into())));
        }
    }
}
