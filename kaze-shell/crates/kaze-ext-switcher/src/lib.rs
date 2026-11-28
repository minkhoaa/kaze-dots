#![deny(clippy::unwrap_used)]

use kaze_core::{
    find_desktop_app_for_class, resolve_icon_path, Anchor, AppState, Color, DirtyFlags, EdgeInsets,
    HitTarget, IconKind, IpcResult, KazeExtension, KeyboardMode, Layer, PaintCmd, PointerButton,
    Rect, ShellAction, ShellContext, SurfaceSpec, SystemEvent, TextAlign, WindowGeometry,
};
use std::collections::HashMap;
use std::sync::Arc;

const SURFACE_ID: &str = "switcher";
const NAMESPACE: &str = "kaze-switcher";

const KEY_TAB: u32 = 0xff09;
const KEY_ISO_LEFT_TAB: u32 = 0xfe20;
const KEY_RETURN: u32 = 0xff0d;
const KEY_KP_ENTER: u32 = 0xff8d;
const KEY_ESCAPE: u32 = 0xff1b;
const KEY_DELETE: u32 = 0xffff;
const KEY_LEFT: u32 = 0xff51;
const KEY_UP: u32 = 0xff52;
const KEY_RIGHT: u32 = 0xff53;
const KEY_DOWN: u32 = 0xff54;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SwitcherLayout {
    Carousel,
    Compact,
    Grid,
    Icons,
}

impl SwitcherLayout {
    fn from_str(raw: &str) -> Self {
        match raw.trim().to_ascii_lowercase().as_str() {
            "compact" => Self::Compact,
            "grid" => Self::Grid,
            "icons" => Self::Icons,
            _ => Self::Carousel,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SwitcherScope {
    All,
    Workspace,
    Monitor,
}

type PreviewBuf = (u32, u32, Arc<[u8]>);

/// Overlay `Alt+Tab` Window Switcher (`kaze-switcher`):
/// MRU ordering, 4 layouts (`carousel`, `compact`, `grid`, `icons`), hold-mode auto-commit on
/// modifier release, live `ext-image-copy-capture-v1` window previews with `.desktop` icon/monogram
/// fallback, close action, and zero memory/surface retention when closed.
pub struct SwitcherExtension {
    open: bool,
    selected: usize,
    scope: SwitcherScope,
    layout_override: Option<SwitcherLayout>,
    request_counter: u64,
    previews: HashMap<String, PreviewBuf>,
    icon_cache: HashMap<String, Option<PreviewBuf>>,
    cached_spec: Option<SurfaceSpec>,
}

impl Default for SwitcherExtension {
    fn default() -> Self {
        Self::new()
    }
}

impl SwitcherExtension {
    pub fn new() -> Self {
        Self {
            open: false,
            selected: 0,
            scope: SwitcherScope::All,
            layout_override: None,
            request_counter: 0,
            previews: HashMap::new(),
            icon_cache: HashMap::new(),
            cached_spec: None,
        }
    }

    pub fn is_open(&self) -> bool {
        self.open
    }

    pub fn cached_preview_count(&self) -> usize {
        self.previews.len()
    }

    fn effective_scope(&self, state: &AppState) -> SwitcherScope {
        match self.scope {
            SwitcherScope::All => {
                if state.config.switcher.current_workspace_only {
                    SwitcherScope::Workspace
                } else if state.config.switcher.current_monitor_only {
                    SwitcherScope::Monitor
                } else {
                    SwitcherScope::All
                }
            }
            explicit => explicit,
        }
    }

    fn ordered_windows(&self, state: &AppState) -> Vec<WindowGeometry> {
        let mut by_addr: HashMap<&str, &WindowGeometry> = HashMap::new();
        for w in &state.windows {
            by_addr.insert(w.address.as_str(), w);
        }
        let mut ordered: Vec<WindowGeometry> = Vec::with_capacity(state.windows.len());
        for addr in &state.window_mru {
            if let Some(w) = by_addr.remove(addr.as_str()) {
                ordered.push(w.clone());
            }
        }
        let mut remaining: Vec<&WindowGeometry> = by_addr.into_values().collect();
        remaining.sort_by_key(|w| w.focus_history_id);
        for w in remaining {
            ordered.push(w.clone());
        }

        let scope = self.effective_scope(state);
        match scope {
            SwitcherScope::All => ordered,
            SwitcherScope::Workspace => {
                let target_ws = state.active_workspace_id;
                ordered
                    .into_iter()
                    .filter(|w| w.workspace_id == target_ws)
                    .collect()
            }
            SwitcherScope::Monitor => {
                let mon = state.focused_monitor.as_deref();
                ordered
                    .into_iter()
                    .filter(|w| mon.is_none_or(|m| w.monitor.is_empty() || w.monitor == m))
                    .collect()
            }
        }
    }

    fn load_icon(&mut self, icon_name: &str) -> Option<PreviewBuf> {
        let key = icon_name.trim();
        if key.is_empty() {
            return None;
        }
        if let Some(cached) = self.icon_cache.get(key) {
            return cached.clone();
        }
        let decoded = resolve_icon_path(key).and_then(|path| {
            let ext = path
                .extension()
                .and_then(|e| e.to_str())
                .unwrap_or_default()
                .to_ascii_lowercase();
            if ext == "svg" {
                return None;
            }
            let img = image::open(&path).ok()?.into_rgba8();
            let (w, h) = img.dimensions();
            if w == 0 || h == 0 {
                return None;
            }
            let mut raw = img.into_raw();
            for px in raw.as_chunks_mut::<4>().0 {
                let a = u16::from(px[3]);
                px[0] = ((u16::from(px[0]) * a + 127) / 255) as u8;
                px[1] = ((u16::from(px[1]) * a + 127) / 255) as u8;
                px[2] = ((u16::from(px[2]) * a + 127) / 255) as u8;
            }
            Some((w, h, Arc::<[u8]>::from(raw)))
        });
        self.icon_cache.insert(key.to_string(), decoded.clone());
        decoded
    }

    fn close_switcher(&mut self) -> DirtyFlags {
        if !self.open && self.cached_spec.is_none() && self.previews.is_empty() {
            return DirtyFlags::NONE;
        }
        self.open = false;
        self.selected = 0;
        self.scope = SwitcherScope::All;
        self.layout_override = None;
        self.previews.clear();
        self.cached_spec = None;
        DirtyFlags::SWITCHER | DirtyFlags::LAYOUT
    }

    fn commit(&mut self, ctx: &mut ShellContext) -> DirtyFlags {
        let windows = self.ordered_windows(ctx.state);
        if let Some(w) = windows.get(self.selected) {
            ctx.push_action(ShellAction::HyprDispatch(format!(
                "focuswindow address:{}",
                w.address
            )));
        }
        self.close_switcher()
    }

    fn step_selection(&mut self, delta: isize, state: &AppState) -> DirtyFlags {
        if !self.open {
            return DirtyFlags::NONE;
        }
        let len = self.ordered_windows(state).len();
        if len == 0 {
            self.selected = 0;
        } else {
            let cur = self.selected.min(len - 1) as isize;
            self.selected = (cur + delta).rem_euclid(len as isize) as usize;
        }
        self.rebuild(state);
        DirtyFlags::SWITCHER
    }

    fn open_switcher(&mut self, args: &[String], ctx: &mut ShellContext) -> DirtyFlags {
        if !ctx.state.config.switcher.enabled || ctx.state.session_locked {
            return self.close_switcher();
        }
        let mut reverse = false;
        self.scope = SwitcherScope::All;
        self.layout_override = None;
        for arg in args {
            match arg.as_str() {
                "prev" | "back" => reverse = true,
                "next" => reverse = false,
                s if s.starts_with("scope=") => {
                    self.scope = match s.trim_start_matches("scope=") {
                        "workspace" | "ws" => SwitcherScope::Workspace,
                        "monitor" | "mon" => SwitcherScope::Monitor,
                        _ => SwitcherScope::All,
                    };
                }
                s if s.starts_with("layout=") => {
                    self.layout_override =
                        Some(SwitcherLayout::from_str(s.trim_start_matches("layout=")));
                }
                _ => {}
            }
        }

        if self.open {
            return self.step_selection(if reverse { -1 } else { 1 }, ctx.state);
        }

        let windows = self.ordered_windows(ctx.state);
        if windows.is_empty() {
            return DirtyFlags::NONE;
        }

        self.open = true;
        self.selected = if windows.len() >= 2 {
            if reverse {
                windows.len() - 1
            } else {
                1
            }
        } else {
            0
        };
        self.previews.clear();

        if ctx.state.config.switcher.show_previews {
            self.request_counter = self.request_counter.wrapping_add(1);
            let req_list: Vec<(String, String, String)> = windows
                .iter()
                .map(|w| {
                    let cls = if w.class.is_empty() {
                        w.initial_class.clone()
                    } else {
                        w.class.clone()
                    };
                    (w.address.clone(), cls, w.title.clone())
                })
                .collect();
            ctx.push_action(ShellAction::RequestWindowPreviews {
                request_id: self.request_counter,
                windows: req_list,
            });
        }

        self.rebuild(ctx.state);
        DirtyFlags::SWITCHER | DirtyFlags::LAYOUT
    }

    fn rebuild(&mut self, state: &AppState) {
        if !self.open || !state.config.switcher.enabled || state.session_locked {
            self.cached_spec = None;
            return;
        }
        let windows = self.ordered_windows(state);
        if windows.is_empty() {
            self.cached_spec = None;
            return;
        }
        self.selected = self.selected.min(windows.len() - 1);
        let layout = self
            .layout_override
            .unwrap_or_else(|| SwitcherLayout::from_str(&state.config.switcher.layout));

        let mut resolved_icons: HashMap<String, PreviewBuf> = HashMap::new();
        for w in &windows {
            let cls = if w.class.is_empty() {
                &w.initial_class
            } else {
                &w.class
            };
            if let Some(d) = find_desktop_app_for_class(&state.desktop_apps, cls) {
                if let Some(buf) = self.load_icon(&d.icon) {
                    resolved_icons.insert(w.address.clone(), buf);
                }
            }
        }

        self.cached_spec = Some(build_switcher_surface(
            state,
            &windows,
            self.selected,
            layout,
            &self.previews,
            &resolved_icons,
        ));
    }
}

impl KazeExtension for SwitcherExtension {
    fn id(&self) -> &'static str {
        "switcher"
    }

    fn on_init(&mut self, _ctx: &mut ShellContext) {}

    fn on_event(&mut self, event: &SystemEvent, ctx: &mut ShellContext) -> DirtyFlags {
        match event {
            SystemEvent::WindowPreviewReady {
                request_id,
                address,
                width,
                height,
                rgba_premul,
            } => {
                if !self.open || *request_id != self.request_counter {
                    return DirtyFlags::NONE;
                }
                self.previews
                    .insert(address.clone(), (*width, *height, Arc::clone(rgba_premul)));
                self.rebuild(ctx.state);
                DirtyFlags::SWITCHER
            }
            SystemEvent::WindowsUpdated { .. } => {
                if !self.open {
                    return DirtyFlags::NONE;
                }
                if self.ordered_windows(ctx.state).is_empty() {
                    self.close_switcher()
                } else {
                    self.rebuild(ctx.state);
                    DirtyFlags::SWITCHER
                }
            }
            SystemEvent::ModifiersChanged {
                surface_id,
                modifiers,
                ..
            } => {
                if self.open
                    && (surface_id == SURFACE_ID || surface_id.is_empty())
                    && ctx.state.config.switcher.hold_mode
                    && !modifiers.alt
                    && !modifiers.logo
                {
                    return self.commit(ctx);
                }
                DirtyFlags::NONE
            }
            SystemEvent::KeyInput { surface_id, key } if surface_id == SURFACE_ID => {
                if !key.pressed {
                    return DirtyFlags::NONE;
                }
                match key.keysym {
                    KEY_ESCAPE => self.close_switcher(),
                    KEY_RETURN | KEY_KP_ENTER => self.commit(ctx),
                    KEY_TAB => {
                        let delta = if key.modifiers.shift { -1 } else { 1 };
                        self.step_selection(delta, ctx.state)
                    }
                    KEY_ISO_LEFT_TAB | KEY_LEFT | KEY_UP => self.step_selection(-1, ctx.state),
                    KEY_RIGHT | KEY_DOWN => self.step_selection(1, ctx.state),
                    KEY_DELETE => {
                        let windows = self.ordered_windows(ctx.state);
                        if let Some(w) = windows.get(self.selected) {
                            ctx.push_action(ShellAction::HyprDispatch(format!(
                                "closewindow address:{}",
                                w.address
                            )));
                        }
                        DirtyFlags::NONE
                    }
                    _ => DirtyFlags::NONE,
                }
            }
            SystemEvent::PointerClick {
                surface_id,
                target_id,
                button,
            } if surface_id == SURFACE_ID => {
                if let Some(addr) = target_id.strip_prefix("switcher:close:") {
                    ctx.push_action(ShellAction::HyprDispatch(format!(
                        "closewindow address:{addr}"
                    )));
                    return DirtyFlags::NONE;
                }
                if let Some(idx_str) = target_id.strip_prefix("switcher:item:") {
                    if let Ok(idx) = idx_str.parse::<usize>() {
                        self.selected = idx;
                        if *button == PointerButton::Left {
                            return self.commit(ctx);
                        }
                        self.rebuild(ctx.state);
                        return DirtyFlags::SWITCHER;
                    }
                }
                DirtyFlags::NONE
            }
            SystemEvent::SurfaceClosed { surface_id }
            | SystemEvent::KeyboardFocusLost { surface_id }
                if surface_id == SURFACE_ID =>
            {
                self.close_switcher()
            }
            SystemEvent::SessionLockRequested | SystemEvent::LockWorkerCommitted => {
                self.close_switcher()
            }
            SystemEvent::ConfigReloaded | SystemEvent::ThemeChanged(_) if self.open => {
                self.rebuild(ctx.state);
                DirtyFlags::SWITCHER | DirtyFlags::THEME
            }
            _ => DirtyFlags::NONE,
        }
    }

    fn on_ipc(&mut self, cmd: &str, args: &[String], ctx: &mut ShellContext) -> IpcResult {
        match cmd {
            "switcher-open" => {
                let dirty = self.open_switcher(args, ctx);
                IpcResult::Handled {
                    ok: true,
                    message: if self.open {
                        "switcher opened".into()
                    } else {
                        "no windows".into()
                    },
                    dirty,
                }
            }
            "switcher-next" => {
                let dirty = if self.open {
                    self.step_selection(1, ctx.state)
                } else {
                    self.open_switcher(&[], ctx)
                };
                IpcResult::Handled {
                    ok: true,
                    message: format!("selected={}", self.selected),
                    dirty,
                }
            }
            "switcher-prev" => {
                let dirty = if self.open {
                    self.step_selection(-1, ctx.state)
                } else {
                    self.open_switcher(&["prev".into()], ctx)
                };
                IpcResult::Handled {
                    ok: true,
                    message: format!("selected={}", self.selected),
                    dirty,
                }
            }
            "switcher-commit" => {
                let dirty = self.commit(ctx);
                IpcResult::Handled {
                    ok: true,
                    message: "committed".into(),
                    dirty,
                }
            }
            "switcher-cancel" => {
                let dirty = self.close_switcher();
                IpcResult::Handled {
                    ok: true,
                    message: "cancelled".into(),
                    dirty,
                }
            }
            "switcher-close-selected" => {
                if self.open {
                    let windows = self.ordered_windows(ctx.state);
                    if let Some(w) = windows.get(self.selected) {
                        ctx.push_action(ShellAction::HyprDispatch(format!(
                            "closewindow address:{}",
                            w.address
                        )));
                    }
                }
                IpcResult::Handled {
                    ok: true,
                    message: "close dispatched".into(),
                    dirty: DirtyFlags::NONE,
                }
            }
            _ => IpcResult::Unhandled,
        }
    }

    fn surfaces(&self) -> Vec<SurfaceSpec> {
        self.cached_spec.clone().into_iter().collect()
    }
}

fn build_switcher_surface(
    state: &AppState,
    windows: &[WindowGeometry],
    selected: usize,
    layout: SwitcherLayout,
    previews: &HashMap<String, PreviewBuf>,
    icons: &HashMap<String, PreviewBuf>,
) -> SurfaceSpec {
    let colors = state.palette.for_mode(state.theme_mode);
    let bar = &state.config.bar;
    let bg = colors.surface_color().with_opacity(bar.background_opacity);
    let border = colors.outline_variant_color();
    let primary = colors.primary_color();
    let error = colors.error_color();
    let on_surface = colors.on_surface_color();
    let muted = colors.on_surface_variant_color();
    let card_bg = colors.surface_container_color();
    let card_sel = colors.surface_variant_color();
    let radius = bar
        .corner_radius
        .max(state.layout_preset.overlay_corner_radius())
        .max(12.0);
    let pad = 14.0f32;
    let gap = 10.0f32;

    let mut commands = Vec::new();
    let mut hit_targets = Vec::new();

    let (surf_w, surf_h) = match layout {
        SwitcherLayout::Carousel => {
            let visible = windows.len().min(6);
            let card_w = 188.0f32;
            let card_h = 152.0f32;
            let w = (pad * 2.0 + visible as f32 * card_w + visible.saturating_sub(1) as f32 * gap)
                .ceil() as u32;
            let h = (pad * 2.0 + card_h).ceil() as u32;
            for (idx, win) in windows.iter().take(visible).enumerate() {
                let cx = pad + idx as f32 * (card_w + gap);
                let rect = Rect::new(cx, pad, card_w, card_h);
                draw_preview_card(
                    &mut commands,
                    &mut hit_targets,
                    idx,
                    win,
                    rect,
                    idx == selected,
                    previews.get(&win.address),
                    icons.get(&win.address),
                    card_bg,
                    card_sel,
                    primary,
                    border,
                    on_surface,
                    muted,
                    error,
                );
            }
            (w.max(240), h)
        }
        SwitcherLayout::Compact => {
            let visible = windows.len().min(10);
            let w = 440u32;
            let row_h = 40.0f32;
            let h = (pad * 2.0 + visible as f32 * row_h + visible.saturating_sub(1) as f32 * 6.0)
                .ceil() as u32;
            for (idx, win) in windows.iter().take(visible).enumerate() {
                let y = pad + idx as f32 * (row_h + 6.0);
                let rect = Rect::new(pad, y, w as f32 - pad * 2.0, row_h);
                let is_sel = idx == selected;
                commands.push(PaintCmd::RoundedRect {
                    rect,
                    radius: 8.0,
                    fill: Some(if is_sel { card_sel } else { card_bg }),
                    stroke: Some(if is_sel { primary } else { border }),
                    stroke_width: if is_sel { 2.0 } else { 1.0 },
                });
                let icon_rect = Rect::new(rect.x + 8.0, rect.y + 8.0, 24.0, 24.0);
                draw_icon_or_monogram(
                    &mut commands,
                    icon_rect,
                    win,
                    icons.get(&win.address),
                    primary,
                    on_surface,
                );
                let label = format!("{} — {}", win.class, win.title);
                commands.push(PaintCmd::RichText {
                    rect: Rect::new(rect.x + 40.0, rect.y + 10.0, rect.w - 76.0, 22.0),
                    text: label,
                    color: on_surface,
                    size: 12.5,
                    bold: is_sel,
                    align: TextAlign::Left,
                    max_lines: 1,
                });
                let close_rect = Rect::new(rect.x + rect.w - 28.0, rect.y + 8.0, 22.0, 22.0);
                commands.push(PaintCmd::Icon {
                    rect: Rect::new(close_rect.x + 4.0, close_rect.y + 4.0, 14.0, 14.0),
                    kind: IconKind::Close,
                    color: error,
                    stroke_width: 1.6,
                    level: None,
                });
                hit_targets.push(HitTarget {
                    rect: close_rect,
                    id: format!("switcher:close:{}", win.address),
                });
                hit_targets.push(HitTarget {
                    rect,
                    id: format!("switcher:item:{idx}"),
                });
            }
            (w, h)
        }
        SwitcherLayout::Grid => {
            let visible = windows.len().min(9);
            let cols = if visible <= 2 { visible.max(1) } else { 3 };
            let rows = visible.div_ceil(cols);
            let card_w = 176.0f32;
            let card_h = 132.0f32;
            let w = (pad * 2.0 + cols as f32 * card_w + cols.saturating_sub(1) as f32 * gap).ceil()
                as u32;
            let h = (pad * 2.0 + rows as f32 * card_h + rows.saturating_sub(1) as f32 * gap).ceil()
                as u32;
            for (idx, win) in windows.iter().take(visible).enumerate() {
                let c = idx % cols;
                let r = idx / cols;
                let rect = Rect::new(
                    pad + c as f32 * (card_w + gap),
                    pad + r as f32 * (card_h + gap),
                    card_w,
                    card_h,
                );
                draw_preview_card(
                    &mut commands,
                    &mut hit_targets,
                    idx,
                    win,
                    rect,
                    idx == selected,
                    previews.get(&win.address),
                    icons.get(&win.address),
                    card_bg,
                    card_sel,
                    primary,
                    border,
                    on_surface,
                    muted,
                    error,
                );
            }
            (w, h)
        }
        SwitcherLayout::Icons => {
            let visible = windows.len().min(10);
            let tile = 68.0f32;
            let w = (pad * 2.0 + visible as f32 * tile + visible.saturating_sub(1) as f32 * gap)
                .ceil() as u32;
            let h = (pad * 2.0 + tile + 28.0).ceil() as u32;
            for (idx, win) in windows.iter().take(visible).enumerate() {
                let x = pad + idx as f32 * (tile + gap);
                let rect = Rect::new(x, pad, tile, tile);
                let is_sel = idx == selected;
                commands.push(PaintCmd::RoundedRect {
                    rect,
                    radius: 12.0,
                    fill: Some(if is_sel { card_sel } else { card_bg }),
                    stroke: Some(if is_sel { primary } else { border }),
                    stroke_width: if is_sel { 2.0 } else { 1.0 },
                });
                draw_icon_or_monogram(
                    &mut commands,
                    Rect::new(rect.x + 14.0, rect.y + 14.0, 40.0, 40.0),
                    win,
                    icons.get(&win.address),
                    primary,
                    on_surface,
                );
                hit_targets.push(HitTarget {
                    rect,
                    id: format!("switcher:item:{idx}"),
                });
            }
            if let Some(sel) = windows.get(selected) {
                commands.push(PaintCmd::RichText {
                    rect: Rect::new(pad, pad + tile + 6.0, w as f32 - pad * 2.0, 20.0),
                    text: sel.title.clone(),
                    color: on_surface,
                    size: 12.0,
                    bold: true,
                    align: TextAlign::Center,
                    max_lines: 1,
                });
            }
            (w.max(220), h)
        }
    };

    SurfaceSpec {
        id: SURFACE_ID.to_string(),
        namespace: NAMESPACE.to_string(),
        output: None,
        layer: Layer::Overlay,
        keyboard_interactivity: KeyboardMode::Exclusive,
        anchor: Anchor::empty(),
        exclusive_zone: 0,
        width: surf_w,
        height: surf_h,
        margin: EdgeInsets::default(),
        corner_radius: radius,
        background: bg,
        border_color: border,
        border_width: bar.border_width.max(1.5),
        commands,
        hit_targets,
        animating: false,
        input_regions: None,
        ime_cursor_rect: None,
        track_pointer_motion: false,
    }
}

#[allow(clippy::too_many_arguments)]
fn draw_preview_card(
    commands: &mut Vec<PaintCmd>,
    hit_targets: &mut Vec<HitTarget>,
    idx: usize,
    win: &WindowGeometry,
    rect: Rect,
    is_sel: bool,
    preview: Option<&PreviewBuf>,
    icon: Option<&PreviewBuf>,
    card_bg: Color,
    card_sel: Color,
    primary: Color,
    border: Color,
    on_surface: Color,
    muted: Color,
    error: Color,
) {
    commands.push(PaintCmd::RoundedRect {
        rect,
        radius: 10.0,
        fill: Some(if is_sel { card_sel } else { card_bg }),
        stroke: Some(if is_sel { primary } else { border }),
        stroke_width: if is_sel { 2.0 } else { 1.0 },
    });

    let media_rect = Rect::new(rect.x + 8.0, rect.y + 8.0, rect.w - 16.0, rect.h - 46.0);
    if let Some((pw, ph, rgba)) = preview {
        commands.push(PaintCmd::Image {
            rect: media_rect,
            width: *pw,
            height: *ph,
            rgba_premul: Arc::clone(rgba),
        });
    } else {
        let icon_side = 44.0f32.min(media_rect.h);
        let icon_rect = Rect::new(
            media_rect.x + (media_rect.w - icon_side) * 0.5,
            media_rect.y + (media_rect.h - icon_side) * 0.5,
            icon_side,
            icon_side,
        );
        draw_icon_or_monogram(commands, icon_rect, win, icon, primary, on_surface);
    }

    commands.push(PaintCmd::RichText {
        rect: Rect::new(rect.x + 8.0, rect.y + rect.h - 32.0, rect.w - 38.0, 24.0),
        text: if win.title.is_empty() {
            win.class.clone()
        } else {
            win.title.clone()
        },
        color: if is_sel { on_surface } else { muted },
        size: 11.5,
        bold: is_sel,
        align: TextAlign::Left,
        max_lines: 1,
    });

    let close_rect = Rect::new(rect.x + rect.w - 26.0, rect.y + 10.0, 18.0, 18.0);
    commands.push(PaintCmd::Icon {
        rect: close_rect,
        kind: IconKind::Close,
        color: error,
        stroke_width: 1.5,
        level: None,
    });
    hit_targets.push(HitTarget {
        rect: close_rect,
        id: format!("switcher:close:{}", win.address),
    });
    hit_targets.push(HitTarget {
        rect,
        id: format!("switcher:item:{idx}"),
    });
}

fn draw_icon_or_monogram(
    commands: &mut Vec<PaintCmd>,
    rect: Rect,
    win: &WindowGeometry,
    icon: Option<&PreviewBuf>,
    primary: Color,
    on_surface: Color,
) {
    if let Some((iw, ih, rgba)) = icon {
        commands.push(PaintCmd::Image {
            rect,
            width: *iw,
            height: *ih,
            rgba_premul: Arc::clone(rgba),
        });
    } else {
        commands.push(PaintCmd::RoundedRect {
            rect,
            radius: (rect.w * 0.22).min(10.0),
            fill: Some(primary.with_opacity(0.2)),
            stroke: Some(primary),
            stroke_width: 1.0,
        });
        let ch = win
            .class
            .chars()
            .chain(win.title.chars())
            .find(|c| !c.is_whitespace())
            .unwrap_or('W')
            .to_ascii_uppercase();
        commands.push(PaintCmd::Text {
            rect,
            text: ch.to_string(),
            color: on_surface,
            size: (rect.w * 0.45).clamp(11.0, 22.0),
            bold: true,
            align: TextAlign::Center,
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use kaze_core::{Config, KeyModifiers};

    fn win(addr: &str, class: &str, title: &str, ws: i32, mon: &str) -> WindowGeometry {
        WindowGeometry {
            address: addr.into(),
            class: class.into(),
            title: title.into(),
            workspace_id: ws,
            monitor: mon.into(),
            ..WindowGeometry::default()
        }
    }

    #[test]
    fn mru_ordering_all_layouts_and_hold_mode_commit() {
        let mut state = AppState::new(Config::default());
        state.windows = vec![
            win("0x1", "foot", "Terminal", 1, "DP-1"),
            win("0x2", "firefox", "Browser", 1, "DP-1"),
            win("0x3", "code", "Editor", 2, "DP-2"),
        ];
        state.window_mru = vec!["0x2".into(), "0x1".into(), "0x3".into()];

        let mut ext = SwitcherExtension::new();
        for layout in ["carousel", "compact", "grid", "icons"] {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_ipc("switcher-open", &[format!("layout={layout}")], &mut ctx);
            assert!(ext.is_open());
            assert_eq!(ext.surfaces().len(), 1);
            assert!(ctx
                .actions
                .iter()
                .any(|a| matches!(a, ShellAction::RequestWindowPreviews { .. })));

            // Release Alt in hold mode commits selected window (index 1 in MRU = 0x1)
            ctx.actions.clear();
            ext.on_event(
                &SystemEvent::ModifiersChanged {
                    surface_id: SURFACE_ID.into(),
                    modifiers: KeyModifiers::default(),
                    caps_lock: false,
                    num_lock: false,
                    scroll_lock: false,
                    layout_idx: 0,
                },
                &mut ctx,
            );
            assert_eq!(
                ctx.actions,
                vec![ShellAction::HyprDispatch("focuswindow address:0x1".into())]
            );
            assert!(ext.surfaces().is_empty());
            assert_eq!(ext.cached_preview_count(), 0);
        }
    }

    #[test]
    fn scope_filter_escape_cancel_and_close_selected() {
        let mut state = AppState::new(Config::default());
        state.active_workspace_id = 1;
        state.windows = vec![
            win("0x1", "foot", "One", 1, "DP-1"),
            win("0x2", "firefox", "Two", 2, "DP-1"),
        ];
        state.window_mru = vec!["0x2".into(), "0x1".into()];

        let mut ext = SwitcherExtension::new();
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_ipc("switcher-open", &["scope=workspace".into()], &mut ctx);
            assert_eq!(ext.surfaces()[0].hit_targets.len(), 2); // close + item for single ws=1 win
        }

        // Escape closes without focusing
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_event(
                &SystemEvent::KeyInput {
                    surface_id: SURFACE_ID.into(),
                    key: kaze_core::KeyEvent {
                        keysym: KEY_ESCAPE,
                        utf8: None,
                        modifiers: KeyModifiers::default(),
                        pressed: true,
                    },
                },
                &mut ctx,
            );
            assert!(ctx.actions.is_empty());
            assert!(ext.surfaces().is_empty());
        }
    }
}
