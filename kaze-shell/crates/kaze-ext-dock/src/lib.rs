#![deny(clippy::unwrap_used)]

use kaze_core::{
    find_desktop_app_for_class, resolve_icon_path, Anchor, AppState, BarPosition, Color,
    DesktopApp, DirtyFlags, DockHideMode, EdgeInsets, HitTarget, IpcResult, KazeExtension,
    KeyboardMode, Layer, OutputInfo, PaintCmd, PointerButton, Rect, ShellAction, ShellContext,
    Spring, SurfaceSpec, SystemEvent, TextAlign, WindowGeometry,
};
use std::collections::{BTreeSet, HashMap};
use std::sync::Arc;

const DOCK_REVEAL_TIMER_PREFIX: &str = "dock:reveal:";

type CachedIcon = (u32, u32, Arc<[u8]>);

#[derive(Debug, Clone)]
struct DockEntry {
    app_id: String,
    title: String,
    desktop: Option<DesktopApp>,
    window_addrs: Vec<String>,
    focused: bool,
    pinned: bool,
}

#[derive(Debug, Clone)]
struct DockMenuState {
    output_name: String,
    entry: DockEntry,
}

#[derive(Debug, Clone)]
struct DragState {
    surface_id: String,
    app_id: String,
    start_axis: f32,
    active: bool,
}

/// Standalone multi-edge application Dock extension (`kaze-dock-<output>`):
/// pinned + running app merge, cosine pointer magnification, `icon_shadow`/`icon_saturation`/
/// `app_icon_colorize`, drag-reorder persisted via `toml_edit`, right-click `.desktop` action
/// context menu, and smart auto-hide (`dodge_active` / `dodge_any`) with reveal delay.
pub struct DockExtension {
    cached_specs: Vec<SurfaceSpec>,
    icon_cache: HashMap<String, Option<CachedIcon>>,
    pointer_axis: HashMap<String, f32>,
    mag_springs: HashMap<String, Spring>,
    hide_springs: HashMap<String, Spring>,
    revealed_outputs: BTreeSet<String>,
    pending_reveal: BTreeSet<String>,
    manually_hidden: bool,
    menu: Option<DockMenuState>,
    drag: Option<DragState>,
}

impl Default for DockExtension {
    fn default() -> Self {
        Self::new()
    }
}

impl DockExtension {
    pub fn new() -> Self {
        Self {
            cached_specs: Vec::new(),
            icon_cache: HashMap::new(),
            pointer_axis: HashMap::new(),
            mag_springs: HashMap::new(),
            hide_springs: HashMap::new(),
            revealed_outputs: BTreeSet::new(),
            pending_reveal: BTreeSet::new(),
            manually_hidden: false,
            menu: None,
            drag: None,
        }
    }

    fn effective_hide_mode(state: &AppState) -> DockHideMode {
        if state.config.dock.smart_auto_hide && state.config.dock.hide_mode == DockHideMode::Never {
            DockHideMode::DodgeActive
        } else {
            state.config.dock.hide_mode
        }
    }

    fn should_hide_on_output(
        &self,
        state: &AppState,
        output: &OutputInfo,
        entries: &[DockEntry],
    ) -> bool {
        if self.revealed_outputs.contains(&output.name) {
            return false;
        }
        match Self::effective_hide_mode(state) {
            DockHideMode::Never => false,
            DockHideMode::Always => true,
            DockHideMode::DodgeActive => {
                let dock_rect = estimated_dock_screen_rect(state, output, entries.len());
                state.active_window().is_some_and(|w| {
                    (w.monitor.is_empty() || w.monitor == output.name)
                        && (w.fullscreen || rects_overlap(dock_rect, window_rect(w)))
                })
            }
            DockHideMode::DodgeAny => {
                let dock_rect = estimated_dock_screen_rect(state, output, entries.len());
                state.windows.iter().any(|w| {
                    (w.monitor.is_empty() || w.monitor == output.name)
                        && (w.fullscreen || rects_overlap(dock_rect, window_rect(w)))
                })
            }
        }
    }

    fn sync_springs(&mut self, state: &AppState, snap: bool) {
        self.mag_springs
            .retain(|name, _| state.outputs.contains_key(name));
        self.hide_springs
            .retain(|name, _| state.outputs.contains_key(name));
        let entries = build_dock_entries(state);
        for output in state.outputs.values() {
            let mag_target = if self.pointer_axis.contains_key(&output.name) {
                1.0
            } else {
                0.0
            };
            let msp = self
                .mag_springs
                .entry(output.name.clone())
                .or_insert_with(|| Spring::snappy(mag_target));
            if snap {
                msp.snap(mag_target);
            } else {
                msp.set_target(mag_target);
            }

            let hide_target = if self.should_hide_on_output(state, output, &entries) {
                1.0
            } else {
                0.0
            };
            let hsp = self
                .hide_springs
                .entry(output.name.clone())
                .or_insert_with(|| Spring::snappy(hide_target));
            if snap {
                hsp.snap(hide_target);
            } else {
                hsp.set_target(hide_target);
            }
        }
    }

    fn load_icon(&mut self, icon_name: &str) -> Option<CachedIcon> {
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

    fn rebuild(&mut self, state: &AppState) {
        self.cached_specs.clear();
        if !state.config.dock.enabled || self.manually_hidden || state.session_locked {
            return;
        }
        let entries = build_dock_entries(state);
        if entries.is_empty() {
            return;
        }

        for output in state.outputs.values() {
            if state.is_output_excluded(&output.name)
                || !state.matches_monitor(&output.name, &state.config.dock.monitor)
            {
                continue;
            }
            let hide_sp = self
                .hide_springs
                .get(&output.name)
                .copied()
                .unwrap_or_else(|| Spring::snappy(0.0));
            let mag_sp = self
                .mag_springs
                .get(&output.name)
                .copied()
                .unwrap_or_else(|| Spring::snappy(0.0));
            let ptr = self.pointer_axis.get(&output.name).copied();
            let hidden_settled = hide_sp.is_settled() && hide_sp.value >= 0.99;

            if hidden_settled {
                self.cached_specs
                    .push(build_dock_trigger_strip(state, output));
            } else {
                let spec = self.build_dock_surface(state, output, &entries, ptr, mag_sp, hide_sp);
                self.cached_specs.push(spec);
            }
        }

        if let Some(ref menu) = self.menu {
            if let Some(output) = state.outputs.get(&menu.output_name) {
                self.cached_specs
                    .push(build_dock_menu_surface(state, output, menu));
            }
        }
    }

    fn build_dock_surface(
        &mut self,
        state: &AppState,
        output: &OutputInfo,
        entries: &[DockEntry],
        pointer_axis: Option<f32>,
        mag_sp: Spring,
        hide_sp: Spring,
    ) -> SurfaceSpec {
        let dock = &state.config.dock;
        let colors = state.palette.for_mode(state.theme_mode);
        let bg = colors.surface_color().with_opacity(dock.background_opacity);
        let border = colors.outline_variant_color();
        let primary = colors.primary_color();
        let secondary = colors.secondary_color();
        let on_surface = colors.on_surface_color();
        let surface_container = colors.surface_container_color();
        let icon_sz = dock.icon_size.max(24) as f32;
        let spacing = 8.0f32;
        let pad = 10.0f32;
        let max_mag = dock.magnification.clamp(1.0, 2.2);
        let mag_headroom = (icon_sz * (max_mag - 1.0)).ceil();
        let depth = icon_sz + pad * 2.0 + mag_headroom;
        let main_len = (pad * 2.0
            + entries.len() as f32 * icon_sz
            + entries.len().saturating_sub(1) as f32 * spacing
            + mag_headroom * 0.5)
            .ceil() as u32;

        let is_vertical = dock.position.is_vertical();
        let (width, height) = if is_vertical {
            (depth.ceil() as u32, main_len)
        } else {
            (main_len, depth.ceil() as u32)
        };
        let anchor = match dock.position {
            BarPosition::Bottom => Anchor::BOTTOM,
            BarPosition::Top => Anchor::TOP,
            BarPosition::Left => Anchor::LEFT,
            BarPosition::Right => Anchor::RIGHT,
        };
        let shift = (hide_sp.value.clamp(0.0, 1.0) * depth).round() as i32;
        let edge_m = dock.margin_edge - shift;
        let margin = match dock.position {
            BarPosition::Bottom => EdgeInsets {
                bottom: edge_m,
                ..EdgeInsets::default()
            },
            BarPosition::Top => EdgeInsets {
                top: edge_m,
                ..EdgeInsets::default()
            },
            BarPosition::Left => EdgeInsets {
                left: edge_m,
                ..EdgeInsets::default()
            },
            BarPosition::Right => EdgeInsets {
                right: edge_m,
                ..EdgeInsets::default()
            },
        };

        let mut commands = Vec::new();
        let mut hit_targets = Vec::new();
        let panel_h = icon_sz + pad * 2.0;
        let panel_rect = match dock.position {
            BarPosition::Bottom => Rect::new(0.0, mag_headroom, width as f32, panel_h),
            BarPosition::Top => Rect::new(0.0, 0.0, width as f32, panel_h),
            BarPosition::Left => Rect::new(0.0, 0.0, panel_h, height as f32),
            BarPosition::Right => Rect::new(mag_headroom, 0.0, panel_h, height as f32),
        };
        commands.push(PaintCmd::RoundedRect {
            rect: panel_rect,
            radius: dock.corner_radius,
            fill: Some(bg),
            stroke: Some(border),
            stroke_width: 1.5,
        });

        let mag_radius = icon_sz * 2.4;
        let colorize = if dock.app_icon_colorize {
            Some(primary)
        } else {
            None
        };
        let saturation = dock.icon_saturation.clamp(0.0, 1.0);

        for (idx, entry) in entries.iter().enumerate() {
            let center_axis =
                pad + mag_headroom * 0.25 + idx as f32 * (icon_sz + spacing) + icon_sz * 0.5;
            let scale = if let Some(px) = pointer_axis {
                let d = (px - center_axis).abs();
                if d < mag_radius && mag_sp.value > 0.01 {
                    let bell = 0.5 * (1.0 + (std::f32::consts::PI * d / mag_radius).cos());
                    1.0 + (max_mag - 1.0) * bell * mag_sp.value
                } else {
                    1.0
                }
            } else {
                1.0
            };
            let item_sz = icon_sz * scale;
            let lift = (scale - 1.0) * icon_sz * 0.85;
            let item_rect = match dock.position {
                BarPosition::Bottom => Rect::new(
                    center_axis - item_sz * 0.5,
                    height as f32 - pad - item_sz - lift,
                    item_sz,
                    item_sz,
                ),
                BarPosition::Top => {
                    Rect::new(center_axis - item_sz * 0.5, pad + lift, item_sz, item_sz)
                }
                BarPosition::Left => {
                    Rect::new(pad + lift, center_axis - item_sz * 0.5, item_sz, item_sz)
                }
                BarPosition::Right => Rect::new(
                    width as f32 - pad - item_sz - lift,
                    center_axis - item_sz * 0.5,
                    item_sz,
                    item_sz,
                ),
            };

            let icon_img = entry.desktop.as_ref().and_then(|d| self.load_icon(&d.icon));

            if let Some((w, h, rgba)) = icon_img {
                commands.push(PaintCmd::StyledImage {
                    rect: item_rect,
                    width: w,
                    height: h,
                    rgba_premul: rgba,
                    saturation,
                    colorize,
                    shadow: dock.icon_shadow,
                    opacity: 1.0,
                    rotation_deg: 0.0,
                    flip_x: false,
                    flip_y: false,
                });
            } else {
                commands.push(PaintCmd::RoundedRect {
                    rect: item_rect,
                    radius: (item_sz * 0.25).min(12.0),
                    fill: Some(if entry.focused {
                        primary.with_opacity(0.25)
                    } else {
                        surface_container
                    }),
                    stroke: Some(if entry.focused { primary } else { border }),
                    stroke_width: 1.0,
                });
                let ch = entry
                    .title
                    .chars()
                    .find(|c| !c.is_whitespace())
                    .unwrap_or('A')
                    .to_ascii_uppercase();
                commands.push(PaintCmd::Text {
                    rect: item_rect,
                    text: ch.to_string(),
                    color: on_surface,
                    size: (item_sz * 0.42).clamp(12.0, 22.0),
                    bold: true,
                    align: TextAlign::Center,
                });
            }

            // Running indicator dots along outer dock edge
            let win_count = entry.window_addrs.len();
            if win_count > 0 {
                let dot_col = if entry.focused { primary } else { secondary };
                let dots = win_count.min(3);
                for di in 0..dots {
                    let offset = (di as f32 - (dots as f32 - 1.0) * 0.5) * 6.0;
                    let (cx, cy) = match dock.position {
                        BarPosition::Bottom => (center_axis + offset, height as f32 - 4.0),
                        BarPosition::Top => (center_axis + offset, 4.0),
                        BarPosition::Left => (4.0, center_axis + offset),
                        BarPosition::Right => (width as f32 - 4.0, center_axis + offset),
                    };
                    commands.push(PaintCmd::Circle {
                        cx,
                        cy,
                        radius: if entry.focused { 2.8 } else { 2.2 },
                        fill: dot_col,
                    });
                }
            }

            hit_targets.push(HitTarget {
                rect: item_rect,
                id: format!("dock:item:{}", entry.app_id),
            });
        }

        let exclusive_zone = if Self::effective_hide_mode(state) == DockHideMode::Never {
            (panel_h.round() as i32) + dock.margin_edge
        } else {
            0
        };

        let blur_enabled = dock
            .compositor_blur
            .get(&output.name)
            .or_else(|| dock.compositor_blur.get(&state.monitor_id(&output.name)))
            .or_else(|| dock.compositor_blur.get("*"))
            .copied()
            .unwrap_or(true);
        let namespace = if blur_enabled {
            format!("kaze-dock-{}", output.name)
        } else {
            format!("kaze-dock-noblur-{}", output.name)
        };

        SurfaceSpec {
            id: format!("dock:{}", output.name),
            namespace,
            output: Some(output.name.clone()),
            layer: Layer::Top,
            keyboard_interactivity: KeyboardMode::None,
            anchor,
            exclusive_zone,
            width,
            height,
            margin,
            corner_radius: 0.0,
            background: Color::TRANSPARENT,
            border_color: Color::TRANSPARENT,
            border_width: 0.0,
            commands,
            hit_targets,
            animating: !mag_sp.is_settled() || !hide_sp.is_settled(),
            input_regions: Some(vec![panel_rect]),
            ime_cursor_rect: None,
            track_pointer_motion: true,
        }
    }
}

impl KazeExtension for DockExtension {
    fn id(&self) -> &'static str {
        "dock"
    }

    fn on_init(&mut self, ctx: &mut ShellContext) {
        self.sync_springs(ctx.state, true);
        self.rebuild(ctx.state);
    }

    fn on_event(&mut self, event: &SystemEvent, ctx: &mut ShellContext) -> DirtyFlags {
        match event {
            SystemEvent::OutputAdded(_)
            | SystemEvent::OutputUpdated(_)
            | SystemEvent::OutputRemoved { .. }
            | SystemEvent::ConfigReloaded
            | SystemEvent::ThemeChanged(_)
            | SystemEvent::ApplicationsChanged => {
                self.icon_cache.clear();
                self.sync_springs(ctx.state, true);
                self.rebuild(ctx.state);
                DirtyFlags::DOCK | DirtyFlags::LAYOUT
            }
            SystemEvent::WindowsUpdated { .. }
            | SystemEvent::HyprSynced { .. }
            | SystemEvent::HyprWorkspaceChanged { .. }
            | SystemEvent::HyprFocusedMonitor { .. }
            | SystemEvent::SessionLockRequested
            | SystemEvent::SessionUnlockRequested
            | SystemEvent::LockWorkerCommitted
            | SystemEvent::LockWorkerExited => {
                self.sync_springs(ctx.state, false);
                self.rebuild(ctx.state);
                DirtyFlags::DOCK
            }
            SystemEvent::FrameTick {
                surface_id,
                dt_secs,
            } => {
                let Some(out) = surface_id.strip_prefix("dock:") else {
                    return DirtyFlags::NONE;
                };
                let mut changed = false;
                if let Some(sp) = self.mag_springs.get_mut(out) {
                    if !sp.is_settled() {
                        sp.step(*dt_secs);
                        changed = true;
                    }
                }
                if let Some(sp) = self.hide_springs.get_mut(out) {
                    if !sp.is_settled() {
                        sp.step(*dt_secs);
                        changed = true;
                    }
                }
                if changed {
                    self.rebuild(ctx.state);
                    DirtyFlags::DOCK
                } else {
                    DirtyFlags::NONE
                }
            }
            SystemEvent::PointerEnter { surface_id, x, y }
            | SystemEvent::PointerMotion { surface_id, x, y } => {
                if let Some(out) = surface_id.strip_prefix("dock:") {
                    if out == "menu" {
                        return DirtyFlags::NONE;
                    }
                    let axis = if ctx.state.config.dock.position.is_vertical() {
                        *y
                    } else {
                        *x
                    };
                    self.pointer_axis.insert(out.to_string(), axis);
                    let entries = build_dock_entries(ctx.state);
                    let should_reveal_delay = ctx
                        .state
                        .outputs
                        .get(out)
                        .is_some_and(|o| self.should_hide_on_output(ctx.state, o, &entries));
                    if should_reveal_delay && !self.pending_reveal.contains(out) {
                        self.pending_reveal.insert(out.to_string());
                        ctx.push_action(ShellAction::ScheduleTimer {
                            id: format!("{DOCK_REVEAL_TIMER_PREFIX}{out}"),
                            after_ms: ctx.state.config.dock.reveal_delay_ms,
                        });
                    }
                    self.sync_springs(ctx.state, false);
                    self.rebuild(ctx.state);
                    return DirtyFlags::DOCK;
                }
                DirtyFlags::NONE
            }
            SystemEvent::PointerLeave { surface_id } => {
                let Some(out) = surface_id.strip_prefix("dock:") else {
                    return DirtyFlags::NONE;
                };
                if out == "menu" {
                    return DirtyFlags::NONE;
                }
                self.pointer_axis.remove(out);
                if self.pending_reveal.remove(out) {
                    ctx.push_action(ShellAction::CancelTimer {
                        id: format!("{DOCK_REVEAL_TIMER_PREFIX}{out}"),
                    });
                }
                self.revealed_outputs.remove(out);
                self.sync_springs(ctx.state, false);
                self.rebuild(ctx.state);
                DirtyFlags::DOCK
            }
            SystemEvent::TimerFired { id } => {
                if let Some(out) = id.strip_prefix(DOCK_REVEAL_TIMER_PREFIX) {
                    if self.pending_reveal.remove(out) && self.pointer_axis.contains_key(out) {
                        self.revealed_outputs.insert(out.to_string());
                        self.sync_springs(ctx.state, false);
                        self.rebuild(ctx.state);
                        return DirtyFlags::DOCK;
                    }
                }
                DirtyFlags::NONE
            }
            SystemEvent::PointerClickAt {
                surface_id,
                target_id,
                button,
                x,
                y,
            } => {
                if surface_id == "dock:menu" {
                    return handle_menu_click(&mut self.menu, target_id, ctx, |ext_dirty| {
                        let _ = ext_dirty;
                    });
                }
                if surface_id.starts_with("dock:") && *button == PointerButton::Left {
                    if let Some(app_id) = target_id.strip_prefix("dock:item:") {
                        let axis = if ctx.state.config.dock.position.is_vertical() {
                            *y
                        } else {
                            *x
                        };
                        self.drag = Some(DragState {
                            surface_id: surface_id.clone(),
                            app_id: app_id.to_string(),
                            start_axis: axis,
                            active: false,
                        });
                    }
                }
                DirtyFlags::NONE
            }
            SystemEvent::PointerDrag {
                surface_id, x, y, ..
            } => {
                let Some(ref mut drag) = self.drag else {
                    return DirtyFlags::NONE;
                };
                if drag.surface_id != *surface_id {
                    return DirtyFlags::NONE;
                }
                let axis = if ctx.state.config.dock.position.is_vertical() {
                    *y
                } else {
                    *x
                };
                if !drag.active && (axis - drag.start_axis).abs() > 8.0 {
                    drag.active = true;
                }
                if drag.active {
                    let dragged_id = drag.app_id.clone();
                    if let Some(target_idx) = find_pin_drop_index(
                        ctx.state,
                        axis,
                        ctx.state.config.dock.pinned_apps.len(),
                    ) {
                        if let Some(cur_idx) = ctx
                            .state
                            .config
                            .dock
                            .pinned_apps
                            .iter()
                            .position(|p| p == &dragged_id)
                        {
                            if cur_idx != target_idx {
                                let item = ctx.state.config.dock.pinned_apps.remove(cur_idx);
                                ctx.state.config.dock.pinned_apps.insert(
                                    target_idx.min(ctx.state.config.dock.pinned_apps.len()),
                                    item,
                                );
                                self.rebuild(ctx.state);
                                return DirtyFlags::DOCK;
                            }
                        }
                    }
                }
                DirtyFlags::NONE
            }
            SystemEvent::PointerRelease { surface_id, .. } => {
                let Some(drag) = self.drag.take() else {
                    return DirtyFlags::NONE;
                };
                if drag.surface_id == *surface_id {
                    if drag.active {
                        persist_pinned_apps(ctx);
                        return DirtyFlags::DOCK;
                    }
                    activate_or_launch_dock_app(ctx, &drag.app_id);
                }
                DirtyFlags::NONE
            }
            SystemEvent::PointerClick {
                surface_id,
                target_id,
                button,
            } => {
                if surface_id == "dock:menu" {
                    let dirty = handle_menu_click(&mut self.menu, target_id, ctx, |_| {});
                    self.rebuild(ctx.state);
                    return dirty;
                }
                let Some(out) = surface_id.strip_prefix("dock:") else {
                    return DirtyFlags::NONE;
                };
                if let Some(app_id) = target_id.strip_prefix("dock:item:") {
                    let entries = build_dock_entries(ctx.state);
                    let Some(entry) = entries.into_iter().find(|e| e.app_id == app_id) else {
                        return DirtyFlags::NONE;
                    };
                    match button {
                        PointerButton::Left => {}
                        PointerButton::Middle => {
                            if let Some(ref d) = entry.desktop {
                                if let Some((program, args)) = d.build_command() {
                                    ctx.push_action(ShellAction::SpawnDetachedApp {
                                        program,
                                        args,
                                    });
                                }
                            }
                        }
                        PointerButton::Right => {
                            let same = self
                                .menu
                                .as_ref()
                                .is_some_and(|m| m.entry.app_id == entry.app_id);
                            self.menu = if same {
                                None
                            } else {
                                Some(DockMenuState {
                                    output_name: out.to_string(),
                                    entry,
                                })
                            };
                            self.rebuild(ctx.state);
                            return DirtyFlags::DOCK;
                        }
                    }
                }
                DirtyFlags::NONE
            }
            SystemEvent::SurfaceClosed { surface_id } => {
                if surface_id == "dock:menu" && self.menu.is_some() {
                    self.menu = None;
                    self.rebuild(ctx.state);
                    return DirtyFlags::DOCK;
                }
                DirtyFlags::NONE
            }
            _ => DirtyFlags::NONE,
        }
    }

    fn on_ipc(&mut self, cmd: &str, args: &[String], ctx: &mut ShellContext) -> IpcResult {
        match cmd {
            "dock-toggle" => {
                self.manually_hidden = !self.manually_hidden;
                self.rebuild(ctx.state);
                IpcResult::Handled {
                    ok: true,
                    message: if self.manually_hidden {
                        "dock hidden".into()
                    } else {
                        "dock shown".into()
                    },
                    dirty: DirtyFlags::DOCK | DirtyFlags::LAYOUT,
                }
            }
            "dock-show" => {
                self.manually_hidden = false;
                self.rebuild(ctx.state);
                IpcResult::Handled {
                    ok: true,
                    message: "dock shown".into(),
                    dirty: DirtyFlags::DOCK | DirtyFlags::LAYOUT,
                }
            }
            "dock-hide" => {
                self.manually_hidden = true;
                self.rebuild(ctx.state);
                IpcResult::Handled {
                    ok: true,
                    message: "dock hidden".into(),
                    dirty: DirtyFlags::DOCK | DirtyFlags::LAYOUT,
                }
            }
            "dock-pin" => {
                let Some(app_id) = args.first().map(|s| s.trim()).filter(|s| !s.is_empty()) else {
                    return IpcResult::Handled {
                        ok: false,
                        message: "usage: dock-pin <app.desktop>".into(),
                        dirty: DirtyFlags::NONE,
                    };
                };
                if !ctx
                    .state
                    .config
                    .dock
                    .pinned_apps
                    .iter()
                    .any(|p| p == app_id)
                {
                    ctx.state.config.dock.pinned_apps.push(app_id.to_string());
                    persist_pinned_apps(ctx);
                }
                self.rebuild(ctx.state);
                IpcResult::Handled {
                    ok: true,
                    message: format!("pinned {app_id}"),
                    dirty: DirtyFlags::DOCK,
                }
            }
            "dock-unpin" => {
                let Some(app_id) = args.first().map(|s| s.trim()).filter(|s| !s.is_empty()) else {
                    return IpcResult::Handled {
                        ok: false,
                        message: "usage: dock-unpin <app.desktop>".into(),
                        dirty: DirtyFlags::NONE,
                    };
                };
                ctx.state.config.dock.pinned_apps.retain(|p| p != app_id);
                persist_pinned_apps(ctx);
                self.rebuild(ctx.state);
                IpcResult::Handled {
                    ok: true,
                    message: format!("unpinned {app_id}"),
                    dirty: DirtyFlags::DOCK,
                }
            }
            "dock-reorder" => {
                let Some(from_idx) = args.first().and_then(|s| s.parse::<usize>().ok()) else {
                    return IpcResult::Handled {
                        ok: false,
                        message: "usage: dock-reorder <from> <to>".into(),
                        dirty: DirtyFlags::NONE,
                    };
                };
                let Some(to_idx) = args.get(1).and_then(|s| s.parse::<usize>().ok()) else {
                    return IpcResult::Handled {
                        ok: false,
                        message: "usage: dock-reorder <from> <to>".into(),
                        dirty: DirtyFlags::NONE,
                    };
                };
                let pins = &mut ctx.state.config.dock.pinned_apps;
                if from_idx < pins.len() && to_idx < pins.len() {
                    let item = pins.remove(from_idx);
                    pins.insert(to_idx, item);
                    persist_pinned_apps(ctx);
                    self.rebuild(ctx.state);
                }
                IpcResult::Handled {
                    ok: true,
                    message: format!("reordered dock {from_idx} -> {to_idx}"),
                    dirty: DirtyFlags::DOCK,
                }
            }
            "dock-menu-open" => {
                let app_id = args.first().map(String::as_str).unwrap_or_default();
                let entries = build_dock_entries(ctx.state);
                if let Some(entry) = entries.into_iter().find(|e| e.app_id == app_id) {
                    if let Some(out) = ctx
                        .state
                        .outputs
                        .keys()
                        .find(|o| !ctx.state.is_output_excluded(o))
                        .cloned()
                    {
                        self.menu = Some(DockMenuState {
                            output_name: out,
                            entry,
                        });
                        self.rebuild(ctx.state);
                        return IpcResult::Handled {
                            ok: true,
                            message: format!("opened dock menu for {app_id}"),
                            dirty: DirtyFlags::DOCK,
                        };
                    }
                }
                IpcResult::Handled {
                    ok: false,
                    message: format!("dock app '{app_id}' not found"),
                    dirty: DirtyFlags::NONE,
                }
            }
            "dock-menu-close" => {
                self.menu = None;
                self.rebuild(ctx.state);
                IpcResult::Handled {
                    ok: true,
                    message: "closed dock menu".into(),
                    dirty: DirtyFlags::DOCK,
                }
            }
            _ => IpcResult::Unhandled,
        }
    }

    fn surfaces(&self) -> Vec<SurfaceSpec> {
        self.cached_specs.clone()
    }
}

fn activate_or_launch_dock_app(ctx: &mut ShellContext, app_id: &str) {
    let entries = build_dock_entries(ctx.state);
    let Some(entry) = entries.into_iter().find(|e| e.app_id == app_id) else {
        return;
    };
    if !entry.window_addrs.is_empty() {
        let next_addr = match ctx.state.active_window_address.as_deref() {
            Some(cur) => {
                if let Some(pos) = entry.window_addrs.iter().position(|a| a == cur) {
                    &entry.window_addrs[(pos + 1) % entry.window_addrs.len()]
                } else {
                    &entry.window_addrs[0]
                }
            }
            None => &entry.window_addrs[0],
        };
        ctx.push_action(ShellAction::HyprDispatch(format!(
            "focuswindow address:{next_addr}"
        )));
    } else if let Some(ref d) = entry.desktop {
        if let Some((program, args)) = d.build_command() {
            ctx.push_action(ShellAction::SpawnDetachedApp { program, args });
        }
    }
}

fn persist_pinned_apps(ctx: &mut ShellContext) {
    let encoded = ctx
        .state
        .config
        .dock
        .pinned_apps
        .iter()
        .map(|s| format!("{s:?}"))
        .collect::<Vec<_>>()
        .join(", ");
    ctx.push_action(ShellAction::PersistSetting {
        key: "dock.pinned_apps".to_string(),
        value_toml: format!("[{encoded}]"),
    });
}

fn find_pin_drop_index(state: &AppState, axis: f32, pin_count: usize) -> Option<usize> {
    if pin_count == 0 {
        return None;
    }
    let icon_sz = state.config.dock.icon_size.max(24) as f32;
    let step = icon_sz + 8.0;
    let max_mag = state.config.dock.magnification.clamp(1.0, 2.2);
    let pad = 10.0 + (icon_sz * (max_mag - 1.0)).ceil() * 0.25;
    let idx = ((axis - pad) / step).floor().max(0.0) as usize;
    Some(idx.min(pin_count - 1))
}

fn handle_menu_click(
    menu_slot: &mut Option<DockMenuState>,
    target_id: &str,
    ctx: &mut ShellContext,
    _cb: fn(DirtyFlags),
) -> DirtyFlags {
    let Some(menu) = menu_slot.take() else {
        return DirtyFlags::NONE;
    };
    if target_id == "dockmenu:pin" {
        if menu.entry.pinned {
            ctx.state
                .config
                .dock
                .pinned_apps
                .retain(|p| p != &menu.entry.app_id);
        } else if !ctx
            .state
            .config
            .dock
            .pinned_apps
            .iter()
            .any(|p| p == &menu.entry.app_id)
        {
            ctx.state
                .config
                .dock
                .pinned_apps
                .push(menu.entry.app_id.clone());
        }
        persist_pinned_apps(ctx);
    } else if target_id == "dockmenu:new" {
        if let Some(ref d) = menu.entry.desktop {
            if let Some((program, args)) = d.build_command() {
                ctx.push_action(ShellAction::SpawnDetachedApp { program, args });
            }
        }
    } else if target_id == "dockmenu:close" {
        for addr in &menu.entry.window_addrs {
            ctx.push_action(ShellAction::HyprDispatch(format!(
                "closewindow address:{addr}"
            )));
        }
    } else if let Some(act_id) = target_id.strip_prefix("dockmenu:act:") {
        if let Some(ref d) = menu.entry.desktop {
            if let Some((program, args)) = d.build_action_command(act_id) {
                ctx.push_action(ShellAction::SpawnDetachedApp { program, args });
            }
        }
    }
    DirtyFlags::DOCK
}

fn build_dock_entries(state: &AppState) -> Vec<DockEntry> {
    let active_addr = state.active_window_address.as_deref();
    let mut entries: Vec<DockEntry> = Vec::new();
    let mut index_by_id: HashMap<String, usize> = HashMap::new();

    for pin in &state.config.dock.pinned_apps {
        let desktop = state
            .desktop_apps
            .iter()
            .find(|d| d.id == *pin || d.id.trim_end_matches(".desktop") == pin)
            .cloned();
        let title = desktop.as_ref().map_or_else(
            || pin.trim_end_matches(".desktop").to_string(),
            |d| d.name.clone(),
        );
        let idx = entries.len();
        index_by_id.insert(pin.clone(), idx);
        entries.push(DockEntry {
            app_id: pin.clone(),
            title,
            desktop,
            window_addrs: Vec::new(),
            focused: false,
            pinned: true,
        });
    }

    for win in &state.windows {
        let cls = if win.class.is_empty() {
            &win.initial_class
        } else {
            &win.class
        };
        let desktop = find_desktop_app_for_class(&state.desktop_apps, cls).cloned();
        let app_id = desktop
            .as_ref()
            .map_or_else(|| cls.to_ascii_lowercase(), |d| d.id.clone());
        let is_focused = win.focused || active_addr == Some(win.address.as_str());
        if let Some(&idx) = index_by_id.get(&app_id) {
            entries[idx].window_addrs.push(win.address.clone());
            entries[idx].focused |= is_focused;
        } else {
            let idx = entries.len();
            index_by_id.insert(app_id.clone(), idx);
            let title = desktop
                .as_ref()
                .map_or_else(|| cls.to_string(), |d| d.name.clone());
            entries.push(DockEntry {
                app_id,
                title,
                desktop,
                window_addrs: vec![win.address.clone()],
                focused: is_focused,
                pinned: false,
            });
        }
    }

    entries
}

fn estimated_dock_screen_rect(state: &AppState, output: &OutputInfo, count: usize) -> Rect {
    let dock = &state.config.dock;
    let icon_sz = dock.icon_size.max(24) as f32;
    let panel_depth = icon_sz + 20.0 + dock.margin_edge as f32;
    let panel_len = (20.0 + count.max(1) as f32 * (icon_sz + 8.0)).min(output.width as f32);
    let ow = output.width as f32;
    let oh = output.height as f32;
    match dock.position {
        BarPosition::Bottom => Rect::new(
            (ow - panel_len) * 0.5,
            oh - panel_depth,
            panel_len,
            panel_depth,
        ),
        BarPosition::Top => Rect::new((ow - panel_len) * 0.5, 0.0, panel_len, panel_depth),
        BarPosition::Left => Rect::new(0.0, (oh - panel_len) * 0.5, panel_depth, panel_len),
        BarPosition::Right => Rect::new(
            ow - panel_depth,
            (oh - panel_len) * 0.5,
            panel_depth,
            panel_len,
        ),
    }
}

fn window_rect(w: &WindowGeometry) -> Rect {
    Rect::new(w.x as f32, w.y as f32, w.w.max(0) as f32, w.h.max(0) as f32)
}

fn rects_overlap(a: Rect, b: Rect) -> bool {
    a.x < b.x + b.w && a.x + a.w > b.x && a.y < b.y + b.h && a.y + a.h > b.y
}

fn build_dock_trigger_strip(state: &AppState, output: &OutputInfo) -> SurfaceSpec {
    let pos = state.config.dock.position;
    let (anchor, width, height) = match pos {
        BarPosition::Bottom => (Anchor::BOTTOM | Anchor::LEFT | Anchor::RIGHT, 0, 2),
        BarPosition::Top => (Anchor::TOP | Anchor::LEFT | Anchor::RIGHT, 0, 2),
        BarPosition::Left => (Anchor::LEFT | Anchor::TOP | Anchor::BOTTOM, 2, 0),
        BarPosition::Right => (Anchor::RIGHT | Anchor::TOP | Anchor::BOTTOM, 2, 0),
    };
    SurfaceSpec {
        id: format!("dock:{}", output.name),
        namespace: format!("kaze-dock-trigger-{}", output.name),
        output: Some(output.name.clone()),
        layer: Layer::Overlay,
        keyboard_interactivity: KeyboardMode::None,
        anchor,
        exclusive_zone: 0,
        width,
        height,
        margin: EdgeInsets::default(),
        corner_radius: 0.0,
        background: Color::TRANSPARENT,
        border_color: Color::TRANSPARENT,
        border_width: 0.0,
        commands: Vec::new(),
        hit_targets: Vec::new(),
        animating: false,
        input_regions: None,
        ime_cursor_rect: None,
        track_pointer_motion: true,
    }
}

fn build_dock_menu_surface(
    state: &AppState,
    output: &OutputInfo,
    menu: &DockMenuState,
) -> SurfaceSpec {
    let colors = state.palette.for_mode(state.theme_mode);
    let bg = colors.surface_color().with_opacity(0.96);
    let border = colors.outline_variant_color();
    let hover = colors.surface_container_color();
    let on_surface = colors.on_surface_color();
    let primary = colors.primary_color();
    let error = colors.error_color();

    let mut rows: Vec<(String, String, Color)> = Vec::new();
    if let Some(ref d) = menu.entry.desktop {
        for act in d.actions.iter().take(4) {
            rows.push((
                format!("dockmenu:act:{}", act.id),
                act.name.clone(),
                on_surface,
            ));
        }
    }
    rows.push(("dockmenu:new".into(), "New Window".into(), on_surface));
    rows.push((
        "dockmenu:pin".into(),
        if menu.entry.pinned {
            "Unpin from Dock".into()
        } else {
            "Pin to Dock".into()
        },
        primary,
    ));
    if !menu.entry.window_addrs.is_empty() {
        let label = if menu.entry.window_addrs.len() > 1 {
            format!("Close All ({})", menu.entry.window_addrs.len())
        } else {
            "Close Window".into()
        };
        rows.push(("dockmenu:close".into(), label, error));
    }

    let w = 210u32;
    let row_h = 28.0f32;
    let h = 12 + rows.len() as u32 * 28;
    let mut commands = Vec::new();
    let mut hit_targets = Vec::new();
    for (idx, (id, label, col)) in rows.into_iter().enumerate() {
        let rect = Rect::new(6.0, 6.0 + idx as f32 * row_h, w as f32 - 12.0, row_h - 2.0);
        commands.push(PaintCmd::RoundedRect {
            rect,
            radius: 6.0,
            fill: Some(hover),
            stroke: None,
            stroke_width: 0.0,
        });
        commands.push(PaintCmd::Text {
            rect: Rect::new(rect.x + 8.0, rect.y, rect.w - 16.0, rect.h),
            text: label,
            color: col,
            size: 12.0,
            bold: false,
            align: TextAlign::Left,
        });
        hit_targets.push(HitTarget { rect, id });
    }

    let anchor = match state.config.dock.position {
        BarPosition::Bottom => Anchor::BOTTOM,
        BarPosition::Top => Anchor::TOP,
        BarPosition::Left => Anchor::LEFT,
        BarPosition::Right => Anchor::RIGHT,
    };
    let margin = match state.config.dock.position {
        BarPosition::Bottom => EdgeInsets {
            bottom: 72,
            ..EdgeInsets::default()
        },
        BarPosition::Top => EdgeInsets {
            top: 72,
            ..EdgeInsets::default()
        },
        BarPosition::Left => EdgeInsets {
            left: 72,
            ..EdgeInsets::default()
        },
        BarPosition::Right => EdgeInsets {
            right: 72,
            ..EdgeInsets::default()
        },
    };

    SurfaceSpec {
        id: "dock:menu".to_string(),
        namespace: "kaze-dock-menu".to_string(),
        output: Some(output.name.clone()),
        layer: Layer::Overlay,
        keyboard_interactivity: KeyboardMode::None,
        anchor,
        exclusive_zone: 0,
        width: w,
        height: h,
        margin,
        corner_radius: 10.0,
        background: bg,
        border_color: border,
        border_width: 1.0,
        commands,
        hit_targets,
        animating: false,
        input_regions: None,
        ime_cursor_rect: None,
        track_pointer_motion: false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use kaze_core::{Config, DesktopAction};

    fn virtual_out(name: &str) -> OutputInfo {
        OutputInfo {
            name: name.into(),
            width: 1920,
            height: 1080,
            scale: 1,
            ..OutputInfo::default()
        }
    }

    #[test]
    fn dock_excludes_kaze_share_and_merges_pinned_with_running() {
        let mut cfg = Config::default();
        cfg.dock.enabled = true;
        cfg.dock.pinned_apps = vec!["foot.desktop".into()];
        let mut state = AppState::new(cfg);
        state.desktop_apps.push(DesktopApp {
            id: "foot.desktop".into(),
            name: "Foot".into(),
            generic_name: String::new(),
            comment: String::new(),
            keywords: String::new(),
            exec: "foot".into(),
            icon: String::new(),
            startup_wm_class: "foot".into(),
            terminal: false,
            categories: vec![],
            actions: vec![DesktopAction {
                id: "new-window".into(),
                name: "New Terminal".into(),
                exec: "foot".into(),
            }],
        });
        state.outputs.insert("DP-1".into(), virtual_out("DP-1"));
        state
            .outputs
            .insert("kaze-share".into(), virtual_out("kaze-share"));
        state.windows.push(WindowGeometry {
            address: "0x1".into(),
            class: "firefox".into(),
            focused: true,
            ..WindowGeometry::default()
        });
        state.active_window_address = Some("0x1".into());

        let mut ext = DockExtension::new();
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_init(&mut ctx);
        }
        let specs = ext.surfaces();
        assert_eq!(specs.len(), 1);
        assert_eq!(specs[0].namespace, "kaze-dock-DP-1");
        assert!(specs[0]
            .hit_targets
            .iter()
            .any(|t| t.id == "dock:item:foot.desktop"));
        assert!(specs[0]
            .hit_targets
            .iter()
            .any(|t| t.id == "dock:item:firefox"));
    }

    #[test]
    fn dock_compositor_blur_false_uses_noblur_namespace() {
        let mut cfg = Config::default();
        cfg.dock.enabled = true;
        cfg.dock.pinned_apps = vec!["foot.desktop".into()];
        cfg.dock.compositor_blur.insert("DP-1".into(), false);
        let mut state = AppState::new(cfg);
        state.outputs.insert("DP-1".into(), virtual_out("DP-1"));
        let mut ext = DockExtension::new();
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_init(&mut ctx);
        }
        assert_eq!(ext.surfaces()[0].namespace, "kaze-dock-noblur-DP-1");
    }

    #[test]
    fn smart_auto_hide_dodges_overlapping_window_and_reveals_after_delay() {
        let mut cfg = Config::default();
        cfg.dock.enabled = true;
        cfg.dock.smart_auto_hide = true;
        cfg.dock.reveal_delay_ms = 150;
        cfg.dock.pinned_apps = vec!["foot.desktop".into()];

        let mut state = AppState::new(cfg);
        state.outputs.insert("DP-1".into(), virtual_out("DP-1"));
        // Floating window in center of screen -> does not touch bottom dock
        state.windows.push(WindowGeometry {
            address: "0x1".into(),
            class: "foot".into(),
            monitor: "DP-1".into(),
            x: 600,
            y: 300,
            w: 500,
            h: 400,
            focused: true,
            ..WindowGeometry::default()
        });
        state.active_window_address = Some("0x1".into());

        let mut ext = DockExtension::new();
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_init(&mut ctx);
        }
        assert_eq!(ext.surfaces()[0].namespace, "kaze-dock-DP-1");

        // Maximize window so it reaches bottom dock edge -> hides to 2px trigger strip
        state.windows[0] = WindowGeometry {
            address: "0x1".into(),
            class: "foot".into(),
            monitor: "DP-1".into(),
            x: 0,
            y: 0,
            w: 1920,
            h: 1080,
            focused: true,
            ..WindowGeometry::default()
        };
        {
            let wins = state.windows.clone();
            let mut ctx = ShellContext::new(&mut state);
            ext.on_event(
                &SystemEvent::WindowsUpdated {
                    windows: wins,
                    active_address: Some("0x1".into()),
                    fullscreen_outputs: vec![],
                },
                &mut ctx,
            );
            for _ in 0..90 {
                if ext.surfaces()[0].namespace == "kaze-dock-trigger-DP-1" {
                    break;
                }
                ext.on_event(
                    &SystemEvent::FrameTick {
                        surface_id: "dock:DP-1".into(),
                        dt_secs: 1.0 / 60.0,
                    },
                    &mut ctx,
                );
            }
        }
        assert_eq!(ext.surfaces()[0].namespace, "kaze-dock-trigger-DP-1");
        assert_eq!(ext.surfaces()[0].height, 2);

        // Hover edge schedules reveal delay and timer brings dock back
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_event(
                &SystemEvent::PointerEnter {
                    surface_id: "dock:DP-1".into(),
                    x: 960.0,
                    y: 1.0,
                },
                &mut ctx,
            );
            assert!(ctx.actions.contains(&ShellAction::ScheduleTimer {
                id: "dock:reveal:DP-1".into(),
                after_ms: 150,
            }));
            ext.on_event(
                &SystemEvent::TimerFired {
                    id: "dock:reveal:DP-1".into(),
                },
                &mut ctx,
            );
        }
        assert_eq!(ext.surfaces()[0].namespace, "kaze-dock-DP-1");
    }

    #[test]
    fn dock_drag_reorder_persists_settings_override() {
        let mut cfg = Config::default();
        cfg.dock.enabled = true;
        cfg.dock.pinned_apps = vec!["a.desktop".into(), "b.desktop".into()];
        let mut state = AppState::new(cfg);
        state.outputs.insert("DP-1".into(), virtual_out("DP-1"));

        let mut ext = DockExtension::new();
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_init(&mut ctx);
        }
        let mut ctx = ShellContext::new(&mut state);
        ext.on_event(
            &SystemEvent::PointerClickAt {
                surface_id: "dock:DP-1".into(),
                target_id: "dock:item:a.desktop".into(),
                button: PointerButton::Left,
                x: 20.0,
                y: 25.0,
            },
            &mut ctx,
        );
        ext.on_event(
            &SystemEvent::PointerDrag {
                surface_id: "dock:DP-1".into(),
                target_id: "dock:item:a.desktop".into(),
                x: 95.0,
                y: 25.0,
            },
            &mut ctx,
        );
        ext.on_event(
            &SystemEvent::PointerRelease {
                surface_id: "dock:DP-1".into(),
                target_id: "dock:item:a.desktop".into(),
                x: 95.0,
                y: 25.0,
            },
            &mut ctx,
        );
        assert_eq!(
            ctx.state.config.dock.pinned_apps,
            vec!["b.desktop", "a.desktop"]
        );
        assert!(ctx.actions.iter().any(|a| matches!(
            a,
            ShellAction::PersistSetting { key, value_toml }
                if key == "dock.pinned_apps" && value_toml == "[\"b.desktop\", \"a.desktop\"]"
        )));
        assert!(!ctx.actions.iter().any(|a| matches!(
            a,
            ShellAction::SpawnDetachedApp { .. } | ShellAction::HyprDispatch(_)
        )));
    }
}
