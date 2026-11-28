#![deny(clippy::unwrap_used)]

pub mod render;

use kaze_core::{
    snap_rotation_15, Anchor, AppState, CanvasLayer, CanvasWidget, CanvasWidgetKind, Color,
    DirtyFlags, EdgeInsets, HitTarget, IpcResult, KazeExtension, KeyModifiers, KeyboardMode, Layer,
    OutputInfo, PaintCmd, PointerButton, Rect, ShellAction, ShellContext, SurfaceSpec, SystemEvent,
    TextAlign, UndoStack, CANVAS_MIN_DIM, CANVAS_UNDO_CAP,
};
use std::collections::{BTreeSet, HashMap};

pub use render::{render_lockscreen_widgets, render_widget_group, CanvasPalette, ImageCache};

const DESKTOP_ID_PREFIX: &str = "canvas:desktop:";
const EDIT_ID_PREFIX: &str = "canvas:edit:";
const SYSMON_OWNER: &str = "canvas";
const SMART_SNAP_THRESHOLD: f32 = 6.0;
const KEY_ESCAPE: u32 = 0xff1b;
const KEY_BACKSPACE: u32 = 0xff08;
const KEY_DELETE: u32 = 0xffff;
const KEY_LEFT: u32 = 0xff51;
const KEY_UP: u32 = 0xff52;
const KEY_RIGHT: u32 = 0xff53;
const KEY_DOWN: u32 = 0xff54;

type GuideLine = (f32, f32, f32, f32);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ResizeHandle {
    Nw,
    N,
    Ne,
    E,
    Se,
    S,
    Sw,
    W,
}

impl ResizeHandle {
    fn tag(self) -> &'static str {
        match self {
            Self::Nw => "nw",
            Self::N => "n",
            Self::Ne => "ne",
            Self::E => "e",
            Self::Se => "se",
            Self::S => "s",
            Self::Sw => "sw",
            Self::W => "w",
        }
    }

    fn parse(raw: &str) -> Option<Self> {
        match raw {
            "nw" => Some(Self::Nw),
            "n" => Some(Self::N),
            "ne" => Some(Self::Ne),
            "e" => Some(Self::E),
            "se" => Some(Self::Se),
            "s" => Some(Self::S),
            "sw" => Some(Self::Sw),
            "w" => Some(Self::W),
            _ => None,
        }
    }
}

#[derive(Debug, Clone)]
enum DragMode {
    Move {
        output: String,
        start_x: f32,
        start_y: f32,
        initial: Vec<(String, f32, f32)>,
        snapshot: Vec<CanvasWidget>,
    },
    Resize {
        widget_id: String,
        handle: ResizeHandle,
        start_x: f32,
        start_y: f32,
        orig: CanvasWidget,
        snapshot: Vec<CanvasWidget>,
    },
    Rotate {
        widget_id: String,
        orig: CanvasWidget,
        snapshot: Vec<CanvasWidget>,
    },
    Lasso {
        output: String,
        start_x: f32,
        start_y: f32,
        cur_x: f32,
        cur_y: f32,
    },
}

pub struct CanvasExtension {
    widgets: Vec<CanvasWidget>,
    edit_mode: bool,
    active_layer: CanvasLayer,
    selected_ids: BTreeSet<String>,
    undo: UndoStack<Vec<CanvasWidget>>,
    drag: Option<DragMode>,
    modifiers: KeyModifiers,
    guides: HashMap<String, Vec<GuideLine>>,
    cache: ImageCache,
    cached_specs: Vec<SurfaceSpec>,
    sysmon_subscribed: bool,
    next_seq: u64,
}

impl Default for CanvasExtension {
    fn default() -> Self {
        Self::new()
    }
}

impl CanvasExtension {
    pub fn new() -> Self {
        Self {
            widgets: Vec::new(),
            edit_mode: false,
            active_layer: CanvasLayer::Desktop,
            selected_ids: BTreeSet::new(),
            undo: UndoStack::new(CANVAS_UNDO_CAP),
            drag: None,
            modifiers: KeyModifiers::default(),
            guides: HashMap::new(),
            cache: ImageCache::default(),
            cached_specs: Vec::new(),
            sysmon_subscribed: false,
            next_seq: 1,
        }
    }

    pub fn widgets(&self) -> &[CanvasWidget] {
        &self.widgets
    }

    pub fn is_edit_mode(&self) -> bool {
        self.edit_mode
    }

    fn sync_from_config(&mut self, state: &AppState) {
        self.widgets = state.config.canvas.widgets.clone();
        for w in &mut self.widgets {
            w.normalize();
        }
    }

    fn next_widget_id(&mut self, kind: CanvasWidgetKind) -> String {
        loop {
            let candidate = format!("{}-{}", kind.as_str(), self.next_seq);
            self.next_seq += 1;
            if !self.widgets.iter().any(|w| w.id == candidate) {
                return candidate;
            }
        }
    }

    fn sync_sysmon_subscription(&mut self, ctx: &mut ShellContext) {
        let want = !ctx.state.outputs_dpms_off
            && !ctx.state.session_locked
            && (ctx.state.config.canvas.enabled || self.edit_mode)
            && self.any_visible_sysmon(ctx.state);
        if want != self.sysmon_subscribed {
            self.sysmon_subscribed = want;
            ctx.push_action(ShellAction::SetSysmonSubscriber {
                owner: SYSMON_OWNER.to_string(),
                active: want,
            });
        }
    }

    fn any_visible_sysmon(&self, state: &AppState) -> bool {
        let primary = primary_output_name(state);
        for out in state.outputs.values() {
            if state.is_output_excluded(&out.name) {
                continue;
            }
            let mid = state.monitor_id(&out.name);
            let is_primary = primary.as_deref() == Some(out.name.as_str());
            let layer = if self.edit_mode {
                self.active_layer
            } else {
                CanvasLayer::Desktop
            };
            if self.widgets.iter().any(|w| {
                w.kind.requires_sysmon()
                    && w.layer == layer
                    && w.matches_output(&mid, &out.name, is_primary)
            }) {
                return true;
            }
        }
        false
    }

    fn push_undo_and_commit(&mut self, snapshot: Vec<CanvasWidget>, ctx: &mut ShellContext) {
        self.undo.push(snapshot);
        self.persist_widgets(ctx);
    }

    fn persist_widgets(&mut self, ctx: &mut ShellContext) {
        for w in &mut self.widgets {
            w.normalize();
        }
        ctx.state.config.canvas.widgets = self.widgets.clone();
        ctx.push_action(ShellAction::PersistCanvasWidgets(self.widgets.clone()));
    }

    fn add_widget_on_primary(&mut self, kind: CanvasWidgetKind, ctx: &mut ShellContext) {
        let snapshot = self.widgets.clone();
        let out = primary_output_name(ctx.state)
            .and_then(|name| ctx.state.outputs.get(&name))
            .cloned();
        let (ow, oh, mid) = if let Some(ref o) = out {
            (
                o.width.max(320) as f32,
                o.height.max(240) as f32,
                Some(ctx.state.monitor_id(&o.name)),
            )
        } else {
            (1920.0, 1080.0, None)
        };
        let (dw, dh) = kind.default_size();
        let offset = (self.widgets.len() as f32 % 6.0) * 24.0;
        let mut w = CanvasWidget {
            id: self.next_widget_id(kind),
            monitor_id: mid,
            layer: self.active_layer,
            kind,
            x: ((ow - dw) * 0.5 + offset).max(24.0),
            y: ((oh - dh) * 0.5 + offset).max(64.0),
            width: dw,
            height: dh,
            z_index: self.max_z() + 1,
            title: kind.label().to_string(),
            ..CanvasWidget::default()
        };
        w.normalize();
        self.selected_ids.clear();
        self.selected_ids.insert(w.id.clone());
        self.widgets.push(w);
        self.push_undo_and_commit(snapshot, ctx);
        self.rebuild_and_sync(ctx);
    }

    fn max_z(&self) -> i32 {
        self.widgets.iter().map(|w| w.z_index).max().unwrap_or(0)
    }

    fn min_z(&self) -> i32 {
        self.widgets.iter().map(|w| w.z_index).min().unwrap_or(0)
    }

    fn delete_selected(&mut self, ctx: &mut ShellContext) {
        if self.selected_ids.is_empty() {
            return;
        }
        let snapshot = self.widgets.clone();
        self.widgets.retain(|w| !self.selected_ids.contains(&w.id));
        self.selected_ids.clear();
        self.push_undo_and_commit(snapshot, ctx);
        self.rebuild_and_sync(ctx);
    }

    fn duplicate_selected(&mut self, ctx: &mut ShellContext) {
        if self.selected_ids.is_empty() {
            return;
        }
        let snapshot = self.widgets.clone();
        let to_clone: Vec<CanvasWidget> = self
            .widgets
            .iter()
            .filter(|w| self.selected_ids.contains(&w.id))
            .cloned()
            .collect();
        self.selected_ids.clear();
        for (next_z, mut w) in (self.max_z() + 1..).zip(to_clone) {
            w.id = self.next_widget_id(w.kind);
            w.x += 24.0;
            w.y += 24.0;
            w.z_index = next_z;
            self.selected_ids.insert(w.id.clone());
            self.widgets.push(w);
        }
        self.push_undo_and_commit(snapshot, ctx);
        self.rebuild_and_sync(ctx);
    }

    fn transform_selected<F>(&mut self, ctx: &mut ShellContext, mut f: F)
    where
        F: FnMut(&mut CanvasWidget, i32, i32),
    {
        if self.selected_ids.is_empty() {
            return;
        }
        let snapshot = self.widgets.clone();
        let max_z = self.max_z();
        let min_z = self.min_z();
        for w in &mut self.widgets {
            if self.selected_ids.contains(&w.id) {
                f(w, min_z, max_z);
                w.normalize();
            }
        }
        self.push_undo_and_commit(snapshot, ctx);
        self.rebuild_and_sync(ctx);
    }

    fn undo_step(&mut self, ctx: &mut ShellContext) -> bool {
        let Some(prev) = self.undo.undo(self.widgets.clone()) else {
            return false;
        };
        self.widgets = prev;
        self.selected_ids
            .retain(|id| self.widgets.iter().any(|w| &w.id == id));
        self.persist_widgets(ctx);
        self.rebuild_and_sync(ctx);
        true
    }

    fn redo_step(&mut self, ctx: &mut ShellContext) -> bool {
        let Some(next) = self.undo.redo(self.widgets.clone()) else {
            return false;
        };
        self.widgets = next;
        self.selected_ids
            .retain(|id| self.widgets.iter().any(|w| &w.id == id));
        self.persist_widgets(ctx);
        self.rebuild_and_sync(ctx);
        true
    }

    fn set_edit_mode(&mut self, open: bool, ctx: &mut ShellContext) {
        if self.edit_mode == open {
            return;
        }
        self.edit_mode = open;
        if !open {
            self.drag = None;
            self.guides.clear();
            self.persist_widgets(ctx);
        }
        self.rebuild_and_sync(ctx);
    }

    fn rebuild_and_sync(&mut self, ctx: &mut ShellContext) {
        self.rebuild_surfaces(ctx.state);
        self.sync_sysmon_subscription(ctx);
    }

    fn rebuild_surfaces(&mut self, state: &AppState) {
        self.cached_specs.clear();
        if !state.config.canvas.enabled && !self.edit_mode {
            return;
        }
        let primary = primary_output_name(state);
        let mut ordered: Vec<&OutputInfo> = state.outputs.values().collect();
        ordered.sort_by(|a, b| a.name.cmp(&b.name));

        for out in ordered {
            if state.is_output_excluded(&out.name) {
                continue;
            }
            let mid = state.monitor_id(&out.name);
            let is_primary = primary.as_deref() == Some(out.name.as_str());
            if self.edit_mode {
                let spec = self.build_edit_surface(out, &mid, is_primary, state);
                self.cached_specs.push(spec);
            } else if let Some(spec) = self.build_desktop_surface(out, &mid, is_primary, state) {
                self.cached_specs.push(spec);
            }
        }
    }

    fn matching_widgets(
        &self,
        layer: CanvasLayer,
        mid: &str,
        output: &str,
        is_primary: bool,
    ) -> Vec<(usize, CanvasWidget)> {
        let mut items: Vec<(usize, CanvasWidget)> = self
            .widgets
            .iter()
            .enumerate()
            .filter(|(_, w)| w.layer == layer && w.matches_output(mid, output, is_primary))
            .map(|(i, w)| (i, w.clone()))
            .collect();
        items.sort_by_key(|(i, w)| (w.z_index, *i));
        items
    }

    fn build_desktop_surface(
        &mut self,
        out: &OutputInfo,
        mid: &str,
        is_primary: bool,
        state: &AppState,
    ) -> Option<SurfaceSpec> {
        let items = self.matching_widgets(CanvasLayer::Desktop, mid, &out.name, is_primary);
        if items.is_empty() {
            return None;
        }
        let pal = CanvasPalette::from_state(state);
        let mut commands = Vec::new();
        let mut hit_targets = Vec::new();
        let mut input_regions = Vec::new();

        for (_, w) in items {
            let rect = Rect::new(
                w.x,
                w.y,
                w.width.max(CANVAS_MIN_DIM),
                w.height.max(CANVAS_MIN_DIM),
            );
            commands.push(render_widget_group(&w, state, &pal, &mut self.cache, false));
            input_regions.push(rect);
            match w.kind {
                CanvasWidgetKind::QuickLaunch => {
                    hit_targets.push(HitTarget {
                        rect,
                        id: format!("canvas:quick:{}", w.id),
                    });
                }
                CanvasWidgetKind::MediaPlayer => {
                    let cy = w.y + w.height - 36.0;
                    let cx = w.x + w.width * 0.5;
                    hit_targets.push(HitTarget {
                        rect: Rect::new(cx - 46.0, cy, 26.0, 26.0),
                        id: format!("canvas:media:prev:{}", w.id),
                    });
                    hit_targets.push(HitTarget {
                        rect: Rect::new(cx - 13.0, cy, 26.0, 26.0),
                        id: format!("canvas:media:play:{}", w.id),
                    });
                    hit_targets.push(HitTarget {
                        rect: Rect::new(cx + 18.0, cy, 26.0, 26.0),
                        id: format!("canvas:media:next:{}", w.id),
                    });
                }
                _ => {}
            }
        }

        Some(SurfaceSpec {
            id: format!("{DESKTOP_ID_PREFIX}{}", out.name),
            namespace: format!("kaze-canvas-{}", out.name),
            output: Some(out.name.clone()),
            layer: Layer::Background,
            keyboard_interactivity: KeyboardMode::None,
            anchor: Anchor::TOP | Anchor::BOTTOM | Anchor::LEFT | Anchor::RIGHT,
            exclusive_zone: -1,
            width: out.width.max(1) as u32,
            height: out.height.max(1) as u32,
            margin: EdgeInsets::default(),
            corner_radius: 0.0,
            background: Color::TRANSPARENT,
            border_color: Color::TRANSPARENT,
            border_width: 0.0,
            commands,
            hit_targets,
            animating: false,
            input_regions: Some(input_regions),
            ime_cursor_rect: None,
            track_pointer_motion: false,
        })
    }

    fn build_edit_surface(
        &mut self,
        out: &OutputInfo,
        mid: &str,
        is_primary: bool,
        state: &AppState,
    ) -> SurfaceSpec {
        let pal = CanvasPalette::from_state(state);
        let ow = out.width.max(320) as f32;
        let oh = out.height.max(240) as f32;
        let mut commands = Vec::new();
        let mut hit_targets = Vec::new();

        commands.push(PaintCmd::RoundedRect {
            rect: Rect::new(0.0, 0.0, ow, oh),
            radius: 0.0,
            fill: Some(Color::rgba(8, 10, 14, 118)),
            stroke: None,
            stroke_width: 0.0,
        });
        if state.config.canvas.snap_to_grid {
            let g = state.config.canvas.grid_size.clamp(4, 64) as f32 * 2.0;
            let grid_col = Color::rgba(255, 255, 255, 16);
            let mut gx = g;
            while gx < ow {
                commands.push(PaintCmd::Line {
                    x1: gx,
                    y1: 54.0,
                    x2: gx,
                    y2: oh,
                    color: grid_col,
                    width: 1.0,
                });
                gx += g;
            }
            let mut gy = 54.0 + g;
            while gy < oh {
                commands.push(PaintCmd::Line {
                    x1: 0.0,
                    y1: gy,
                    x2: ow,
                    y2: gy,
                    color: grid_col,
                    width: 1.0,
                });
                gy += g;
            }
        }

        hit_targets.push(HitTarget {
            rect: Rect::new(0.0, 54.0, ow, (oh - 54.0).max(1.0)),
            id: "edit:bg".to_string(),
        });

        let items = self.matching_widgets(self.active_layer, mid, &out.name, is_primary);
        for (_, w) in &items {
            let selected = self.selected_ids.contains(&w.id);
            commands.push(render_widget_group(
                w,
                state,
                &pal,
                &mut self.cache,
                selected,
            ));
            let rect = Rect::new(w.x, w.y, w.width, w.height);
            hit_targets.push(HitTarget {
                rect,
                id: format!("edit:widget:{}", w.id),
            });
            if selected {
                commands.push(PaintCmd::RoundedRect {
                    rect,
                    radius: 8.0,
                    fill: None,
                    stroke: Some(pal.primary),
                    stroke_width: 2.0,
                });
                for (handle, hx, hy) in handle_positions(rect) {
                    let hrect = Rect::new(hx - 5.0, hy - 5.0, 10.0, 10.0);
                    commands.push(PaintCmd::RoundedRect {
                        rect: hrect,
                        radius: 2.0,
                        fill: Some(pal.bg),
                        stroke: Some(pal.primary),
                        stroke_width: 1.5,
                    });
                    hit_targets.push(HitTarget {
                        rect: hrect,
                        id: format!("edit:rs:{}:{}", handle.tag(), w.id),
                    });
                }
                let rcx = rect.x + rect.w * 0.5;
                let rcy = (rect.y - 22.0).max(58.0);
                commands.push(PaintCmd::Line {
                    x1: rcx,
                    y1: rect.y,
                    x2: rcx,
                    y2: rcy,
                    color: pal.primary,
                    width: 1.5,
                });
                commands.push(PaintCmd::Circle {
                    cx: rcx,
                    cy: rcy,
                    radius: 6.0,
                    fill: pal.primary,
                });
                hit_targets.push(HitTarget {
                    rect: Rect::new(rcx - 8.0, rcy - 8.0, 16.0, 16.0),
                    id: format!("edit:rot:{}", w.id),
                });
            }
        }

        if let Some(lines) = self.guides.get(&out.name) {
            for &(x1, y1, x2, y2) in lines {
                commands.push(PaintCmd::Line {
                    x1,
                    y1,
                    x2,
                    y2,
                    color: pal.secondary,
                    width: 1.5,
                });
            }
        }

        if let Some(DragMode::Lasso {
            output,
            start_x,
            start_y,
            cur_x,
            cur_y,
        }) = &self.drag
        {
            if output == &out.name {
                let lx = start_x.min(*cur_x);
                let ly = start_y.min(*cur_y);
                let lw = (cur_x - start_x).abs();
                let lh = (cur_y - start_y).abs();
                commands.push(PaintCmd::RoundedRect {
                    rect: Rect::new(lx, ly, lw, lh),
                    radius: 4.0,
                    fill: Some(Color::rgba(pal.primary.r, pal.primary.g, pal.primary.b, 48)),
                    stroke: Some(pal.primary),
                    stroke_width: 1.5,
                });
            }
        }

        render_edit_toolbar(
            &mut commands,
            &mut hit_targets,
            ow,
            &pal,
            self.active_layer,
            state.config.canvas.snap_to_grid,
            self.undo.can_undo(),
            self.undo.can_redo(),
            !self.selected_ids.is_empty(),
        );

        SurfaceSpec {
            id: format!("{EDIT_ID_PREFIX}{}", out.name),
            namespace: format!("kaze-canvas-edit-{}", out.name),
            output: Some(out.name.clone()),
            layer: Layer::Overlay,
            keyboard_interactivity: KeyboardMode::Exclusive,
            anchor: Anchor::TOP | Anchor::BOTTOM | Anchor::LEFT | Anchor::RIGHT,
            exclusive_zone: -1,
            width: out.width.max(1) as u32,
            height: out.height.max(1) as u32,
            margin: EdgeInsets::default(),
            corner_radius: 0.0,
            background: Color::TRANSPARENT,
            border_color: Color::TRANSPARENT,
            border_width: 0.0,
            commands,
            hit_targets,
            animating: false,
            input_regions: None,
            ime_cursor_rect: None,
            track_pointer_motion: true,
        }
    }

    fn handle_drag_motion(&mut self, output: &str, x: f32, y: f32, state: &AppState) -> bool {
        let grid = if state.config.canvas.snap_to_grid {
            state.config.canvas.grid_size.clamp(4, 64) as f32
        } else {
            1.0
        };
        let smart = state.config.canvas.smart_guides;
        let out_size = state
            .outputs
            .get(output)
            .map(|o| (o.width as f32, o.height as f32))
            .unwrap_or((1920.0, 1080.0));
        let mid = state.monitor_id(output);
        let is_primary = primary_output_name(state).as_deref() == Some(output);

        match &mut self.drag {
            Some(DragMode::Lasso {
                output: drag_out,
                start_x,
                start_y,
                cur_x,
                cur_y,
            }) if drag_out == output => {
                *cur_x = x;
                *cur_y = y;
                let lasso = Rect::new(
                    start_x.min(*cur_x),
                    start_y.min(*cur_y),
                    (*cur_x - *start_x).abs(),
                    (*cur_y - *start_y).abs(),
                );
                self.selected_ids.clear();
                for w in &self.widgets {
                    if w.layer == self.active_layer
                        && w.matches_output(&mid, output, is_primary)
                        && rects_intersect(lasso, Rect::new(w.x, w.y, w.width, w.height))
                    {
                        self.selected_ids.insert(w.id.clone());
                    }
                }
                true
            }
            Some(DragMode::Move {
                output: drag_out,
                start_x,
                start_y,
                initial,
                ..
            }) if drag_out == output => {
                let mut dx = x - *start_x;
                let mut dy = y - *start_y;
                if grid > 1.0 {
                    dx = (dx / grid).round() * grid;
                    dy = (dy / grid).round() * grid;
                }
                let mut new_guides = Vec::new();
                if let Some((first_id, ix, iy)) = initial.first() {
                    if let Some(first_w) = self.widgets.iter().find(|w| &w.id == first_id) {
                        let fw = first_w.width;
                        let fh = first_w.height;
                        let cand_x = if grid > 1.0 {
                            ((ix + dx) / grid).round() * grid
                        } else {
                            ix + dx
                        };
                        let cand_y = if grid > 1.0 {
                            ((iy + dy) / grid).round() * grid
                        } else {
                            iy + dy
                        };
                        dx = cand_x - ix;
                        dy = cand_y - iy;

                        if smart {
                            let (sx, sy, g) = compute_smart_snap(
                                cand_x,
                                cand_y,
                                fw,
                                fh,
                                first_id,
                                &self.widgets,
                                self.active_layer,
                                &mid,
                                output,
                                is_primary,
                                out_size,
                            );
                            dx += sx - cand_x;
                            dy += sy - cand_y;
                            new_guides = g;
                        }
                    }
                }
                self.guides.insert(output.to_string(), new_guides);
                for (id, ix, iy) in initial {
                    if let Some(w) = self.widgets.iter_mut().find(|w| &w.id == id) {
                        w.x = (*ix + dx).max(0.0);
                        w.y = (*iy + dy).max(56.0);
                    }
                }
                true
            }
            Some(DragMode::Resize {
                widget_id,
                handle,
                start_x,
                start_y,
                orig,
                ..
            }) => {
                let dx = x - *start_x;
                let dy = y - *start_y;
                if let Some(w) = self.widgets.iter_mut().find(|w| &w.id == widget_id) {
                    let mut nx = orig.x;
                    let mut ny = orig.y;
                    let mut nw = orig.width;
                    let mut nh = orig.height;
                    match handle {
                        ResizeHandle::E | ResizeHandle::Ne | ResizeHandle::Se => {
                            nw = snap_val(orig.width + dx, grid).max(CANVAS_MIN_DIM);
                        }
                        ResizeHandle::W | ResizeHandle::Nw | ResizeHandle::Sw => {
                            let right = orig.x + orig.width;
                            nw = snap_val(orig.width - dx, grid).max(CANVAS_MIN_DIM);
                            nx = right - nw;
                        }
                        _ => {}
                    }
                    match handle {
                        ResizeHandle::S | ResizeHandle::Se | ResizeHandle::Sw => {
                            nh = snap_val(orig.height + dy, grid).max(CANVAS_MIN_DIM);
                        }
                        ResizeHandle::N | ResizeHandle::Ne | ResizeHandle::Nw => {
                            let bottom = orig.y + orig.height;
                            nh = snap_val(orig.height - dy, grid).max(CANVAS_MIN_DIM);
                            ny = bottom - nh;
                        }
                        _ => {}
                    }
                    w.x = nx;
                    w.y = ny.max(56.0);
                    w.width = nw;
                    w.height = nh;
                    w.normalize();
                    return true;
                }
                false
            }
            Some(DragMode::Rotate {
                widget_id, orig, ..
            }) => {
                if let Some(w) = self.widgets.iter_mut().find(|w| &w.id == widget_id) {
                    let cx = orig.x + orig.width * 0.5;
                    let cy = orig.y + orig.height * 0.5;
                    let deg = (y - cy).atan2(x - cx).to_degrees() + 90.0;
                    w.rotation_deg = if self.modifiers.shift {
                        snap_rotation_15(deg)
                    } else {
                        deg
                    };
                    w.normalize();
                    return true;
                }
                false
            }
            _ => false,
        }
    }

    fn finish_drag(&mut self, ctx: &mut ShellContext) -> bool {
        let Some(drag) = self.drag.take() else {
            return false;
        };
        self.guides.clear();
        match drag {
            DragMode::Move { snapshot, .. }
            | DragMode::Resize { snapshot, .. }
            | DragMode::Rotate { snapshot, .. } => {
                if self.widgets != snapshot {
                    self.push_undo_and_commit(snapshot, ctx);
                }
                true
            }
            DragMode::Lasso { .. } => true,
        }
    }

    fn handle_toolbar_click(&mut self, id: &str, ctx: &mut ShellContext) -> DirtyFlags {
        match id {
            "edit:tb:done" => {
                self.set_edit_mode(false, ctx);
                return DirtyFlags::CANVAS;
            }
            "edit:tb:layer" => {
                self.active_layer = match self.active_layer {
                    CanvasLayer::Desktop => CanvasLayer::Lockscreen,
                    CanvasLayer::Lockscreen => CanvasLayer::Desktop,
                };
                self.selected_ids.clear();
                self.rebuild_and_sync(ctx);
                return DirtyFlags::CANVAS;
            }
            "edit:tb:snap" => {
                ctx.state.config.canvas.snap_to_grid = !ctx.state.config.canvas.snap_to_grid;
                let v = if ctx.state.config.canvas.snap_to_grid {
                    "true"
                } else {
                    "false"
                };
                ctx.push_action(ShellAction::PersistSetting {
                    key: "canvas.snap_to_grid".into(),
                    value_toml: v.into(),
                });
                self.rebuild_and_sync(ctx);
                return DirtyFlags::CANVAS;
            }
            "edit:tb:undo" => {
                self.undo_step(ctx);
                return DirtyFlags::CANVAS;
            }
            "edit:tb:redo" => {
                self.redo_step(ctx);
                return DirtyFlags::CANVAS;
            }
            "edit:tb:fliph" => {
                self.transform_selected(ctx, |w, _, _| w.flip_x = !w.flip_x);
                return DirtyFlags::CANVAS;
            }
            "edit:tb:flipv" => {
                self.transform_selected(ctx, |w, _, _| w.flip_y = !w.flip_y);
                return DirtyFlags::CANVAS;
            }
            "edit:tb:rot-" => {
                self.transform_selected(ctx, |w, _, _| {
                    w.rotation_deg = snap_rotation_15(w.rotation_deg - 15.0);
                });
                return DirtyFlags::CANVAS;
            }
            "edit:tb:rot+" => {
                self.transform_selected(ctx, |w, _, _| {
                    w.rotation_deg = snap_rotation_15(w.rotation_deg + 15.0);
                });
                return DirtyFlags::CANVAS;
            }
            "edit:tb:back" => {
                self.transform_selected(ctx, |w, min_z, _| w.z_index = min_z - 1);
                return DirtyFlags::CANVAS;
            }
            "edit:tb:front" => {
                self.transform_selected(ctx, |w, _, max_z| w.z_index = max_z + 1);
                return DirtyFlags::CANVAS;
            }
            "edit:tb:del" => {
                self.delete_selected(ctx);
                return DirtyFlags::CANVAS;
            }
            _ => {
                if let Some(kind_raw) = id.strip_prefix("edit:tb:add:") {
                    if let Some(kind) = CanvasWidgetKind::parse(kind_raw) {
                        self.add_widget_on_primary(kind, ctx);
                        return DirtyFlags::CANVAS;
                    }
                }
            }
        }
        DirtyFlags::NONE
    }
}

impl KazeExtension for CanvasExtension {
    fn id(&self) -> &'static str {
        "canvas"
    }

    fn on_init(&mut self, ctx: &mut ShellContext) {
        self.sync_from_config(ctx.state);
        self.rebuild_and_sync(ctx);
    }

    fn on_event(&mut self, event: &SystemEvent, ctx: &mut ShellContext) -> DirtyFlags {
        match event {
            SystemEvent::ConfigReloaded => {
                self.sync_from_config(ctx.state);
                self.rebuild_and_sync(ctx);
                DirtyFlags::CANVAS
            }
            SystemEvent::OutputAdded(_)
            | SystemEvent::OutputUpdated(_)
            | SystemEvent::OutputRemoved { .. }
            | SystemEvent::HyprSynced { .. }
            | SystemEvent::HyprFocusedMonitor { .. }
            | SystemEvent::ThemeChanged(_) => {
                self.rebuild_and_sync(ctx);
                DirtyFlags::CANVAS
            }
            SystemEvent::SessionLockRequested => {
                ctx.state.session_locked = true;
                self.sync_sysmon_subscription(ctx);
                DirtyFlags::NONE
            }
            SystemEvent::LockWorkerExited => {
                ctx.state.session_locked = false;
                self.sync_sysmon_subscription(ctx);
                DirtyFlags::NONE
            }
            SystemEvent::PrepareForSleep(sleeping) => {
                ctx.state.outputs_dpms_off = *sleeping;
                self.sync_sysmon_subscription(ctx);
                DirtyFlags::NONE
            }
            SystemEvent::ClockTick(_) => {
                if self.edit_mode
                    || (!self.cached_specs.is_empty()
                        && self
                            .widgets
                            .iter()
                            .any(|w| w.kind == CanvasWidgetKind::Clock))
                {
                    self.rebuild_surfaces(ctx.state);
                    DirtyFlags::CANVAS
                } else {
                    DirtyFlags::NONE
                }
            }
            SystemEvent::SysmonUpdated(_) => {
                if self.sysmon_subscribed {
                    self.rebuild_surfaces(ctx.state);
                    DirtyFlags::CANVAS
                } else {
                    DirtyFlags::NONE
                }
            }
            SystemEvent::MediaChanged(_)
            | SystemEvent::WeatherUpdated(_)
            | SystemEvent::CalendarUpdated(_)
            | SystemEvent::NetworkChanged(_)
            | SystemEvent::BatteryChanged(_)
            | SystemEvent::AudioChanged { .. } => {
                if self.edit_mode || !self.cached_specs.is_empty() {
                    self.rebuild_surfaces(ctx.state);
                    DirtyFlags::CANVAS
                } else {
                    DirtyFlags::NONE
                }
            }
            SystemEvent::ModifiersChanged {
                surface_id,
                modifiers,
                ..
            } if surface_id.starts_with(EDIT_ID_PREFIX) => {
                self.modifiers = *modifiers;
                DirtyFlags::NONE
            }
            SystemEvent::PointerClickAt {
                surface_id,
                target_id,
                button,
                x,
                y,
            } if surface_id.starts_with(DESKTOP_ID_PREFIX) && *button == PointerButton::Left => {
                let _ = (x, y);
                if let Some(wid) = target_id.strip_prefix("canvas:quick:") {
                    if let Some(w) = self.widgets.iter().find(|w| w.id == wid) {
                        let cmd_raw = w
                            .command
                            .as_deref()
                            .filter(|s| !s.trim().is_empty())
                            .or_else(|| (!w.text.trim().is_empty()).then_some(w.text.as_str()))
                            .unwrap_or("foot");
                        let parts: Vec<String> =
                            cmd_raw.split_whitespace().map(str::to_string).collect();
                        if let Some((prog, args)) = parts.split_first() {
                            ctx.push_action(ShellAction::SpawnCommand {
                                program: prog.clone(),
                                args: args.to_vec(),
                            });
                        }
                    }
                } else if target_id.starts_with("canvas:media:prev:") {
                    ctx.push_action(ShellAction::MediaCommand("previous".into()));
                } else if target_id.starts_with("canvas:media:play:") {
                    ctx.push_action(ShellAction::MediaCommand("play-pause".into()));
                } else if target_id.starts_with("canvas:media:next:") {
                    ctx.push_action(ShellAction::MediaCommand("next".into()));
                }
                DirtyFlags::NONE
            }
            SystemEvent::PointerClickAt {
                surface_id,
                target_id,
                button,
                x,
                y,
            } if surface_id.starts_with(EDIT_ID_PREFIX) && *button == PointerButton::Left => {
                let output = surface_id
                    .strip_prefix(EDIT_ID_PREFIX)
                    .unwrap_or("")
                    .to_string();
                if target_id.starts_with("edit:tb:") {
                    return self.handle_toolbar_click(target_id, ctx);
                }
                if let Some(wid) = target_id.strip_prefix("edit:rot:") {
                    if let Some(w) = self.widgets.iter().find(|w| w.id == wid).cloned() {
                        self.selected_ids.clear();
                        self.selected_ids.insert(w.id.clone());
                        self.drag = Some(DragMode::Rotate {
                            widget_id: w.id.clone(),
                            orig: w,
                            snapshot: self.widgets.clone(),
                        });
                        self.rebuild_surfaces(ctx.state);
                        return DirtyFlags::CANVAS;
                    }
                }
                if let Some(rest) = target_id.strip_prefix("edit:rs:") {
                    if let Some((h_raw, wid)) = rest.split_once(':') {
                        if let (Some(handle), Some(w)) = (
                            ResizeHandle::parse(h_raw),
                            self.widgets.iter().find(|w| w.id == wid).cloned(),
                        ) {
                            self.selected_ids.clear();
                            self.selected_ids.insert(w.id.clone());
                            self.drag = Some(DragMode::Resize {
                                widget_id: w.id.clone(),
                                handle,
                                start_x: *x,
                                start_y: *y,
                                orig: w,
                                snapshot: self.widgets.clone(),
                            });
                            self.rebuild_surfaces(ctx.state);
                            return DirtyFlags::CANVAS;
                        }
                    }
                }
                if let Some(wid) = target_id.strip_prefix("edit:widget:") {
                    if self.modifiers.shift {
                        if !self.selected_ids.remove(wid) {
                            self.selected_ids.insert(wid.to_string());
                        }
                    } else if !self.selected_ids.contains(wid) {
                        self.selected_ids.clear();
                        self.selected_ids.insert(wid.to_string());
                    }
                    let initial: Vec<(String, f32, f32)> = self
                        .widgets
                        .iter()
                        .filter(|w| self.selected_ids.contains(&w.id))
                        .map(|w| (w.id.clone(), w.x, w.y))
                        .collect();
                    self.drag = Some(DragMode::Move {
                        output,
                        start_x: *x,
                        start_y: *y,
                        initial,
                        snapshot: self.widgets.clone(),
                    });
                    self.rebuild_surfaces(ctx.state);
                    return DirtyFlags::CANVAS;
                }
                if !self.modifiers.shift {
                    self.selected_ids.clear();
                }
                self.drag = Some(DragMode::Lasso {
                    output,
                    start_x: *x,
                    start_y: *y,
                    cur_x: *x,
                    cur_y: *y,
                });
                self.rebuild_surfaces(ctx.state);
                DirtyFlags::CANVAS
            }
            SystemEvent::PointerDrag {
                surface_id, x, y, ..
            }
            | SystemEvent::PointerMotion { surface_id, x, y }
                if surface_id.starts_with(EDIT_ID_PREFIX) && self.drag.is_some() =>
            {
                let output = surface_id.strip_prefix(EDIT_ID_PREFIX).unwrap_or("");
                if self.handle_drag_motion(output, *x, *y, ctx.state) {
                    self.rebuild_surfaces(ctx.state);
                    DirtyFlags::CANVAS
                } else {
                    DirtyFlags::NONE
                }
            }
            SystemEvent::PointerRelease { surface_id, .. }
                if surface_id.starts_with(EDIT_ID_PREFIX) =>
            {
                if self.finish_drag(ctx) {
                    self.rebuild_surfaces(ctx.state);
                    DirtyFlags::CANVAS
                } else {
                    DirtyFlags::NONE
                }
            }
            SystemEvent::KeyInput { surface_id, key } if surface_id.starts_with(EDIT_ID_PREFIX) => {
                self.modifiers = key.modifiers;
                if !key.pressed {
                    return DirtyFlags::NONE;
                }
                if key.keysym == KEY_ESCAPE {
                    self.set_edit_mode(false, ctx);
                    return DirtyFlags::CANVAS;
                }
                if key.keysym == KEY_DELETE || key.keysym == KEY_BACKSPACE {
                    self.delete_selected(ctx);
                    return DirtyFlags::CANVAS;
                }
                if key.modifiers.ctrl {
                    if let Some(ch) = key.utf8.as_deref() {
                        let lower = ch.to_ascii_lowercase();
                        if lower == "z" {
                            if key.modifiers.shift {
                                self.redo_step(ctx);
                            } else {
                                self.undo_step(ctx);
                            }
                            return DirtyFlags::CANVAS;
                        }
                        if lower == "y" {
                            self.redo_step(ctx);
                            return DirtyFlags::CANVAS;
                        }
                        if lower == "d" {
                            self.duplicate_selected(ctx);
                            return DirtyFlags::CANVAS;
                        }
                    }
                    if key.keysym == b'z' as u32 || key.keysym == b'Z' as u32 {
                        if key.modifiers.shift {
                            self.redo_step(ctx);
                        } else {
                            self.undo_step(ctx);
                        }
                        return DirtyFlags::CANVAS;
                    }
                    if key.keysym == b'y' as u32 || key.keysym == b'Y' as u32 {
                        self.redo_step(ctx);
                        return DirtyFlags::CANVAS;
                    }
                    if key.keysym == b'd' as u32 || key.keysym == b'D' as u32 {
                        self.duplicate_selected(ctx);
                        return DirtyFlags::CANVAS;
                    }
                }
                let step = if key.modifiers.shift {
                    1.0
                } else {
                    ctx.state.config.canvas.grid_size.clamp(4, 64) as f32
                };
                match key.keysym {
                    KEY_LEFT => {
                        self.transform_selected(ctx, |w, _, _| w.x = (w.x - step).max(0.0));
                        DirtyFlags::CANVAS
                    }
                    KEY_RIGHT => {
                        self.transform_selected(ctx, |w, _, _| w.x += step);
                        DirtyFlags::CANVAS
                    }
                    KEY_UP => {
                        self.transform_selected(ctx, |w, _, _| w.y = (w.y - step).max(56.0));
                        DirtyFlags::CANVAS
                    }
                    KEY_DOWN => {
                        self.transform_selected(ctx, |w, _, _| w.y += step);
                        DirtyFlags::CANVAS
                    }
                    _ => DirtyFlags::NONE,
                }
            }
            _ => DirtyFlags::NONE,
        }
    }

    fn on_ipc(&mut self, cmd: &str, args: &[String], ctx: &mut ShellContext) -> IpcResult {
        match cmd {
            "canvas-edit-toggle" => {
                let next = !self.edit_mode;
                self.set_edit_mode(next, ctx);
                IpcResult::Handled {
                    ok: true,
                    message: if self.edit_mode {
                        "canvas edit mode opened".into()
                    } else {
                        "canvas edit mode closed".into()
                    },
                    dirty: DirtyFlags::CANVAS,
                }
            }
            "canvas-edit-open" => {
                if let Some(arg) = args.first() {
                    if let Some(layer) = CanvasLayer::parse(arg) {
                        self.active_layer = layer;
                    }
                }
                self.set_edit_mode(true, ctx);
                IpcResult::Handled {
                    ok: true,
                    message: "canvas edit mode opened".into(),
                    dirty: DirtyFlags::CANVAS,
                }
            }
            "canvas-edit-close" => {
                self.set_edit_mode(false, ctx);
                IpcResult::Handled {
                    ok: true,
                    message: "canvas edit mode closed".into(),
                    dirty: DirtyFlags::CANVAS,
                }
            }
            "canvas-layer" => {
                let Some(arg) = args.first() else {
                    return IpcResult::Handled {
                        ok: true,
                        message: self.active_layer.as_str().to_string(),
                        dirty: DirtyFlags::NONE,
                    };
                };
                let Some(layer) = CanvasLayer::parse(arg) else {
                    return IpcResult::Handled {
                        ok: false,
                        message: format!("unknown canvas layer '{arg}'"),
                        dirty: DirtyFlags::NONE,
                    };
                };
                self.active_layer = layer;
                self.selected_ids.clear();
                self.rebuild_and_sync(ctx);
                IpcResult::Handled {
                    ok: true,
                    message: layer.as_str().to_string(),
                    dirty: DirtyFlags::CANVAS,
                }
            }
            "canvas-add" => {
                let Some(raw) = args.first() else {
                    return IpcResult::Handled {
                        ok: false,
                        message: "usage: canvas-add <kind>".into(),
                        dirty: DirtyFlags::NONE,
                    };
                };
                let Some(kind) = CanvasWidgetKind::parse(raw) else {
                    return IpcResult::Handled {
                        ok: false,
                        message: format!("unknown widget kind '{raw}'"),
                        dirty: DirtyFlags::NONE,
                    };
                };
                self.add_widget_on_primary(kind, ctx);
                IpcResult::Handled {
                    ok: true,
                    message: format!("added {}", kind.as_str()),
                    dirty: DirtyFlags::CANVAS,
                }
            }
            "canvas-remove" => {
                let Some(id) = args.first() else {
                    return IpcResult::Handled {
                        ok: false,
                        message: "usage: canvas-remove <id>".into(),
                        dirty: DirtyFlags::NONE,
                    };
                };
                let snapshot = self.widgets.clone();
                let before = self.widgets.len();
                self.widgets.retain(|w| &w.id != id);
                self.selected_ids.remove(id);
                if self.widgets.len() == before {
                    return IpcResult::Handled {
                        ok: false,
                        message: format!("widget '{id}' not found"),
                        dirty: DirtyFlags::NONE,
                    };
                }
                self.push_undo_and_commit(snapshot, ctx);
                self.rebuild_and_sync(ctx);
                IpcResult::Handled {
                    ok: true,
                    message: format!("removed {id}"),
                    dirty: DirtyFlags::CANVAS,
                }
            }
            "canvas-clear" => {
                let snapshot = self.widgets.clone();
                self.widgets.retain(|w| w.layer != self.active_layer);
                self.selected_ids.clear();
                self.push_undo_and_commit(snapshot, ctx);
                self.rebuild_and_sync(ctx);
                IpcResult::Handled {
                    ok: true,
                    message: "cleared active layer".into(),
                    dirty: DirtyFlags::CANVAS,
                }
            }
            "canvas-undo" => {
                let ok = self.undo_step(ctx);
                IpcResult::Handled {
                    ok,
                    message: if ok {
                        "undone".into()
                    } else {
                        "nothing to undo".into()
                    },
                    dirty: if ok {
                        DirtyFlags::CANVAS
                    } else {
                        DirtyFlags::NONE
                    },
                }
            }
            "canvas-redo" => {
                let ok = self.redo_step(ctx);
                IpcResult::Handled {
                    ok,
                    message: if ok {
                        "redone".into()
                    } else {
                        "nothing to redo".into()
                    },
                    dirty: if ok {
                        DirtyFlags::CANVAS
                    } else {
                        DirtyFlags::NONE
                    },
                }
            }
            _ => IpcResult::Unhandled,
        }
    }

    fn surfaces(&self) -> Vec<SurfaceSpec> {
        self.cached_specs.clone()
    }
}

#[allow(clippy::too_many_arguments)]
fn render_edit_toolbar(
    commands: &mut Vec<PaintCmd>,
    hit_targets: &mut Vec<HitTarget>,
    screen_w: f32,
    pal: &CanvasPalette,
    layer: CanvasLayer,
    snap_on: bool,
    can_undo: bool,
    can_redo: bool,
    has_sel: bool,
) {
    let mut items: Vec<(&str, String, bool)> = vec![
        (
            "edit:tb:layer",
            match layer {
                CanvasLayer::Desktop => "Desktop".into(),
                CanvasLayer::Lockscreen => "Lockscreen".into(),
            },
            true,
        ),
        ("edit:tb:add:clock", "+Clock".into(), true),
        ("edit:tb:add:system_monitor", "+Sysmon".into(), true),
        ("edit:tb:add:weather", "+Weather".into(), true),
        ("edit:tb:add:todo_note", "+Note".into(), true),
        ("edit:tb:add:sticker", "+Sticker".into(), true),
        (
            "edit:tb:snap",
            if snap_on {
                "Snap:On".into()
            } else {
                "Snap:Off".into()
            },
            snap_on,
        ),
        ("edit:tb:undo", "Undo".into(), can_undo),
        ("edit:tb:redo", "Redo".into(), can_redo),
        ("edit:tb:fliph", "FlipX".into(), has_sel),
        ("edit:tb:flipv", "FlipY".into(), has_sel),
        ("edit:tb:rot-", "-15°".into(), has_sel),
        ("edit:tb:rot+", "+15°".into(), has_sel),
        ("edit:tb:back", "Back".into(), has_sel),
        ("edit:tb:front", "Front".into(), has_sel),
        ("edit:tb:del", "Del".into(), has_sel),
        ("edit:tb:done", "Done".into(), true),
    ];
    let btn_w = 68.0f32;
    let gap = 6.0f32;
    let max_fit = ((screen_w - 32.0) / (btn_w + gap)).floor().max(1.0) as usize;
    if items.len() > max_fit {
        items.truncate(max_fit);
    }
    let bar_w = (items.len() as f32) * (btn_w + gap) + 14.0;
    let bar_x = ((screen_w - bar_w) * 0.5).max(8.0);
    let bar_y = 10.0f32;
    commands.push(PaintCmd::RoundedRect {
        rect: Rect::new(bar_x, bar_y, bar_w, 38.0),
        radius: 12.0,
        fill: Some(Color::rgba(
            pal.surface_0.r,
            pal.surface_0.g,
            pal.surface_0.b,
            240,
        )),
        stroke: Some(pal.border),
        stroke_width: 1.0,
    });
    for (idx, (id, label, active)) in items.into_iter().enumerate() {
        let bx = bar_x + 8.0 + (idx as f32) * (btn_w + gap);
        let rect = Rect::new(bx, bar_y + 5.0, btn_w, 28.0);
        let fill = if id == "edit:tb:done" {
            pal.primary
        } else if active {
            pal.surface_1
        } else {
            Color::rgba(pal.surface_1.r, pal.surface_1.g, pal.surface_1.b, 90)
        };
        let fg = if id == "edit:tb:done" {
            pal.bg
        } else if active {
            pal.fg
        } else {
            Color::rgba(pal.fg.r, pal.fg.g, pal.fg.b, 100)
        };
        commands.push(PaintCmd::RoundedRect {
            rect,
            radius: 7.0,
            fill: Some(fill),
            stroke: None,
            stroke_width: 0.0,
        });
        commands.push(PaintCmd::Text {
            rect,
            text: label,
            color: fg,
            size: 10.5,
            bold: id == "edit:tb:done" || id == "edit:tb:layer",
            align: TextAlign::Center,
        });
        hit_targets.push(HitTarget {
            rect,
            id: id.to_string(),
        });
    }
}

fn handle_positions(r: Rect) -> [(ResizeHandle, f32, f32); 8] {
    let mx = r.x + r.w * 0.5;
    let my = r.y + r.h * 0.5;
    let rx = r.x + r.w;
    let by = r.y + r.h;
    [
        (ResizeHandle::Nw, r.x, r.y),
        (ResizeHandle::N, mx, r.y),
        (ResizeHandle::Ne, rx, r.y),
        (ResizeHandle::E, rx, my),
        (ResizeHandle::Se, rx, by),
        (ResizeHandle::S, mx, by),
        (ResizeHandle::Sw, r.x, by),
        (ResizeHandle::W, r.x, my),
    ]
}

fn snap_val(val: f32, grid: f32) -> f32 {
    if grid > 1.0 {
        (val / grid).round() * grid
    } else {
        val
    }
}

fn rects_intersect(a: Rect, b: Rect) -> bool {
    a.x < b.x + b.w && a.x + a.w > b.x && a.y < b.y + b.h && a.y + a.h > b.y
}

#[allow(clippy::too_many_arguments)]
fn compute_smart_snap(
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    self_id: &str,
    widgets: &[CanvasWidget],
    layer: CanvasLayer,
    mid: &str,
    output: &str,
    is_primary: bool,
    out_size: (f32, f32),
) -> (f32, f32, Vec<GuideLine>) {
    let mut best_dx = None::<(f32, f32)>;
    let mut best_dy = None::<(f32, f32)>;
    let mut cand_x = vec![out_size.0 * 0.5];
    let mut cand_y = vec![out_size.1 * 0.5];
    for other in widgets {
        if other.id != self_id
            && other.layer == layer
            && other.matches_output(mid, output, is_primary)
        {
            cand_x.extend([other.x, other.x + other.width * 0.5, other.x + other.width]);
            cand_y.extend([
                other.y,
                other.y + other.height * 0.5,
                other.y + other.height,
            ]);
        }
    }
    for anchor_x in [x, x + w * 0.5, x + w] {
        for &target_x in &cand_x {
            let diff = target_x - anchor_x;
            if diff.abs() <= SMART_SNAP_THRESHOLD
                && best_dx.is_none_or(|(d, _)| diff.abs() < d.abs())
            {
                best_dx = Some((diff, target_x));
            }
        }
    }
    for anchor_y in [y, y + h * 0.5, y + h] {
        for &target_y in &cand_y {
            let diff = target_y - anchor_y;
            if diff.abs() <= SMART_SNAP_THRESHOLD
                && best_dy.is_none_or(|(d, _)| diff.abs() < d.abs())
            {
                best_dy = Some((diff, target_y));
            }
        }
    }
    let mut guides = Vec::new();
    let nx = if let Some((diff, gx)) = best_dx {
        guides.push((gx, 54.0, gx, out_size.1));
        x + diff
    } else {
        x
    };
    let ny = if let Some((diff, gy)) = best_dy {
        guides.push((0.0, gy, out_size.0, gy));
        y + diff
    } else {
        y
    };
    (nx, ny, guides)
}

fn primary_output_name(state: &AppState) -> Option<String> {
    if let Some(ref f) = state.focused_monitor {
        if !state.is_output_excluded(f) && state.outputs.contains_key(f) {
            return Some(f.clone());
        }
    }
    state
        .outputs
        .keys()
        .find(|n| !state.is_output_excluded(n))
        .cloned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use kaze_core::{Config, KeyEvent, MonitorState};

    fn base_state() -> AppState {
        let mut cfg = Config::default();
        cfg.canvas.enabled = true;
        cfg.canvas.grid_size = 16;
        cfg.canvas.snap_to_grid = true;
        cfg.canvas.smart_guides = true;
        let mut state = AppState::new(cfg);
        state.outputs.insert(
            "DP-1".into(),
            OutputInfo {
                name: "DP-1".into(),
                width: 1920,
                height: 1080,
                scale: 1,
                make: "Dell".into(),
                model: "U2723QE".into(),
                serial: "SER1".into(),
            },
        );
        state.monitors.push(MonitorState {
            id: 1,
            name: "DP-1".into(),
            make: "Dell".into(),
            model: "U2723QE".into(),
            serial: "SER1".into(),
            width: 1920,
            height: 1080,
            scale: 1.0,
            focused: true,
            disabled: false,
            active_workspace_id: 1,
        });
        state.focused_monitor = Some("DP-1".into());
        state
    }

    #[test]
    fn renders_all_10_kinds_and_svg_sticker_and_excludes_kaze_share() {
        let mut state = base_state();
        state.outputs.insert(
            "kaze-share".into(),
            OutputInfo {
                name: "kaze-share".into(),
                width: 1920,
                height: 1080,
                scale: 1,
                ..Default::default()
            },
        );
        for (i, kind) in CanvasWidgetKind::ALL.into_iter().enumerate() {
            let mut w = CanvasWidget {
                id: format!("w-{i}"),
                kind,
                layer: CanvasLayer::Desktop,
                x: 40.0 + (i as f32) * 30.0,
                y: 80.0,
                text: if kind == CanvasWidgetKind::Sticker {
                    r##"<svg viewBox="0 0 100 100"><circle cx="50" cy="50" r="40" fill="#ff5500"/><path d="M10 10 L90 90"/></svg>"##.into()
                } else {
                    "Test note".into()
                },
                ..Default::default()
            };
            w.normalize();
            state.config.canvas.widgets.push(w);
        }

        let mut ext = CanvasExtension::new();
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_init(&mut ctx);
            assert!(ctx.actions.iter().any(|a| matches!(
                a,
                ShellAction::SetSysmonSubscriber {
                    owner,
                    active: true
                } if owner == "canvas"
            )));
        }

        let specs = ext.surfaces();
        assert_eq!(specs.len(), 1);
        assert_eq!(specs[0].namespace, "kaze-canvas-DP-1");
        assert_eq!(specs[0].layer, Layer::Background);
        assert_eq!(specs[0].commands.len(), 10);
        assert_eq!(specs[0].input_regions.as_ref().map(|r| r.len()), Some(10));

        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_event(&SystemEvent::SessionLockRequested, &mut ctx);
            assert!(ctx.actions.iter().any(|a| matches!(
                a,
                ShellAction::SetSysmonSubscriber {
                    owner,
                    active: false
                } if owner == "canvas"
            )));
        }
    }

    #[test]
    fn edit_mode_lasso_resize_rotate_snap_and_35_step_undo_redo_persist() {
        let mut state = base_state();
        let mut ext = CanvasExtension::new();
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_init(&mut ctx);
            assert!(ext.surfaces().is_empty());
            ext.on_ipc("canvas-edit-open", &[], &mut ctx);
        }
        assert_eq!(ext.surfaces().len(), 1);
        assert_eq!(ext.surfaces()[0].namespace, "kaze-canvas-edit-DP-1");

        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_ipc("canvas-add", &["clock".into()], &mut ctx);
            ext.on_ipc("canvas-add", &["todo_note".into()], &mut ctx);
            assert_eq!(ext.widgets().len(), 2);
            let w0_id = ext.widgets()[0].id.clone();
            let orig_w0 = ext.widgets()[0].clone();

            ext.on_event(
                &SystemEvent::PointerClickAt {
                    surface_id: "canvas:edit:DP-1".into(),
                    target_id: format!("edit:rs:se:{w0_id}"),
                    button: PointerButton::Left,
                    x: orig_w0.x + orig_w0.width,
                    y: orig_w0.y + orig_w0.height,
                },
                &mut ctx,
            );
            ext.on_event(
                &SystemEvent::PointerDrag {
                    surface_id: "canvas:edit:DP-1".into(),
                    target_id: format!("edit:rs:se:{w0_id}"),
                    x: orig_w0.x + 4.0,
                    y: orig_w0.y + 4.0,
                },
                &mut ctx,
            );
            ext.on_event(
                &SystemEvent::PointerRelease {
                    surface_id: "canvas:edit:DP-1".into(),
                    target_id: format!("edit:rs:se:{w0_id}"),
                    x: orig_w0.x + 4.0,
                    y: orig_w0.y + 4.0,
                },
                &mut ctx,
            );
            assert_eq!(ext.widgets()[0].width, CANVAS_MIN_DIM);
            assert_eq!(ext.widgets()[0].height, CANVAS_MIN_DIM);

            ext.on_event(
                &SystemEvent::ModifiersChanged {
                    surface_id: "canvas:edit:DP-1".into(),
                    modifiers: KeyModifiers {
                        shift: true,
                        ..Default::default()
                    },
                    caps_lock: false,
                    num_lock: false,
                    scroll_lock: false,
                    layout_idx: 0,
                },
                &mut ctx,
            );
            ext.on_event(
                &SystemEvent::PointerClickAt {
                    surface_id: "canvas:edit:DP-1".into(),
                    target_id: format!("edit:rot:{w0_id}"),
                    button: PointerButton::Left,
                    x: ext.widgets()[0].x + 16.0,
                    y: ext.widgets()[0].y - 22.0,
                },
                &mut ctx,
            );
            ext.on_event(
                &SystemEvent::PointerDrag {
                    surface_id: "canvas:edit:DP-1".into(),
                    target_id: format!("edit:rot:{w0_id}"),
                    x: ext.widgets()[0].x + 36.0,
                    y: ext.widgets()[0].y + 8.0,
                },
                &mut ctx,
            );
            ext.on_event(
                &SystemEvent::PointerRelease {
                    surface_id: "canvas:edit:DP-1".into(),
                    target_id: format!("edit:rot:{w0_id}"),
                    x: ext.widgets()[0].x + 36.0,
                    y: ext.widgets()[0].y + 8.0,
                },
                &mut ctx,
            );
            assert_eq!((ext.widgets()[0].rotation_deg % 15.0).round(), 0.0);

            for _ in 0..35 {
                ext.on_event(
                    &SystemEvent::KeyInput {
                        surface_id: "canvas:edit:DP-1".into(),
                        key: KeyEvent {
                            keysym: KEY_RIGHT,
                            utf8: None,
                            modifiers: KeyModifiers::default(),
                            pressed: true,
                        },
                    },
                    &mut ctx,
                );
            }
            let x_after_35 = ext.widgets()[0].x;
            for _ in 0..35 {
                let res = ext.on_ipc("canvas-undo", &[], &mut ctx);
                assert!(matches!(res, IpcResult::Handled { ok: true, .. }));
            }
            for _ in 0..35 {
                let res = ext.on_ipc("canvas-redo", &[], &mut ctx);
                assert!(matches!(res, IpcResult::Handled { ok: true, .. }));
            }
            assert_eq!(ext.widgets()[0].x, x_after_35);

            ext.on_event(
                &SystemEvent::PointerClickAt {
                    surface_id: "canvas:edit:DP-1".into(),
                    target_id: "edit:bg".into(),
                    button: PointerButton::Left,
                    x: 10.0,
                    y: 60.0,
                },
                &mut ctx,
            );
            ext.on_event(
                &SystemEvent::PointerDrag {
                    surface_id: "canvas:edit:DP-1".into(),
                    target_id: "edit:bg".into(),
                    x: 1900.0,
                    y: 1000.0,
                },
                &mut ctx,
            );
            ext.on_event(
                &SystemEvent::PointerRelease {
                    surface_id: "canvas:edit:DP-1".into(),
                    target_id: "edit:bg".into(),
                    x: 1900.0,
                    y: 1000.0,
                },
                &mut ctx,
            );
            assert_eq!(ext.selected_ids.len(), 2);

            ext.on_event(
                &SystemEvent::KeyInput {
                    surface_id: "canvas:edit:DP-1".into(),
                    key: KeyEvent {
                        keysym: KEY_ESCAPE,
                        utf8: None,
                        modifiers: KeyModifiers::default(),
                        pressed: true,
                    },
                },
                &mut ctx,
            );
            assert!(!ext.is_edit_mode());
            assert!(ctx
                .actions
                .iter()
                .any(|a| matches!(a, ShellAction::PersistCanvasWidgets(ws) if ws.len() == 2)));
        }
        assert_eq!(ext.surfaces().len(), 1);
        assert_eq!(ext.surfaces()[0].namespace, "kaze-canvas-DP-1");
    }
}
