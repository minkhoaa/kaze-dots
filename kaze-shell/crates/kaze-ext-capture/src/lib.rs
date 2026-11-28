#![deny(clippy::unwrap_used)]

pub mod color_picker;
pub mod editor;

use color_picker::{format_color, ColorFormat};
use editor::{default_screenshot_path, AnnotationCanvas, ToolKind};
use kaze_core::text_input::{TextInputOutcome, TextInputState};
use kaze_core::{
    t, Anchor, AppState, CapturedOutputFrame, Color, DirtyFlags, EdgeInsets, HitTarget, I18nKey,
    IpcResult, KazeExtension, KeyboardMode, Layer, PaintCmd, PointerButton, Rect, ShellAction,
    ShellContext, SurfaceSpec, SystemEvent, TextAlign, WindowGeometry,
};
use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::Arc;

const SURFACE_REGION: &str = "capture:region";
const SURFACE_EDITOR: &str = "capture:editor";
const SURFACE_PICKER: &str = "picker:main";

const KEY_ESCAPE: u32 = 0xff1b;
const KEY_TAB: u32 = 0xff09;

#[derive(Debug, Clone)]
enum PendingCaptureMode {
    Full {
        save_only: Option<PathBuf>,
    },
    Output {
        target: Option<String>,
        save_only: Option<PathBuf>,
    },
    Region {
        geom_only: bool,
    },
    Window,
    ColorPicker {
        format: ColorFormat,
    },
}

enum ActiveCaptureUi {
    None,
    Region {
        frames: Vec<CapturedOutputFrame>,
        windows: Vec<WindowGeometry>,
        geom_only: bool,
        window_snap: bool,
        drag_start: Option<(f32, f32)>,
        cursor: (f32, f32),
        hover_window: Option<WindowGeometry>,
    },
    ColorPicker {
        frames: Vec<CapturedOutputFrame>,
        format: ColorFormat,
        cursor: (f32, f32),
    },
    Editor {
        canvas: AnnotationCanvas,
        preview_premul: Arc<[u8]>,
        tool: ToolKind,
        color_idx: usize,
        stroke_width: f32,
        opaque_fill: bool,
        drag_start: Option<(f32, f32)>,
        cursor: (f32, f32),
        stroke_pts: Vec<(f32, f32)>,
        text_editing: Option<(f32, f32, TextInputState)>,
        status: Option<String>,
    },
}

const SWATCH_COLORS: &[[u8; 4]] = &[
    [243, 139, 168, 255],
    [122, 162, 247, 255],
    [166, 227, 161, 255],
    [249, 226, 175, 255],
    [255, 255, 255, 255],
    [230, 25, 25, 255],
];

pub struct CaptureExtension {
    next_req_id: u64,
    pending_req: Option<(u64, PendingCaptureMode)>,
    ui: ActiveCaptureUi,
    recent_swatches: VecDeque<String>,
    cached_specs: Vec<SurfaceSpec>,
}

impl Default for CaptureExtension {
    fn default() -> Self {
        Self::new()
    }
}

impl CaptureExtension {
    pub fn new() -> Self {
        Self {
            next_req_id: 1,
            pending_req: None,
            ui: ActiveCaptureUi::None,
            recent_swatches: VecDeque::with_capacity(8),
            cached_specs: Vec::new(),
        }
    }

    pub fn is_open(&self) -> bool {
        !matches!(self.ui, ActiveCaptureUi::None)
    }

    pub fn recent_swatches(&self) -> &VecDeque<String> {
        &self.recent_swatches
    }

    fn close_all(&mut self, ctx: &mut ShellContext, cancel_reply: bool) -> DirtyFlags {
        if cancel_reply {
            ctx.push_action(ShellAction::CaptureReply { text: None });
        }
        if matches!(self.ui, ActiveCaptureUi::None) && self.pending_req.is_none() {
            return DirtyFlags::NONE;
        }
        self.pending_req = None;
        self.ui = ActiveCaptureUi::None;
        self.cached_specs.clear();
        self.cached_specs.shrink_to_fit();
        DirtyFlags::CAPTURE | DirtyFlags::LAYOUT
    }

    fn start_capture(&mut self, mode: PendingCaptureMode, ctx: &mut ShellContext) -> IpcResult {
        let req_id = self.next_req_id;
        self.next_req_id = self.next_req_id.saturating_add(1);
        self.pending_req = Some((req_id, mode));
        ctx.push_action(ShellAction::RequestScreencopy { request_id: req_id });
        IpcResult::Handled {
            ok: true,
            message: format!("requested screencopy {req_id}"),
            dirty: DirtyFlags::NONE,
        }
    }

    fn focused_frame<'a>(
        frames: &'a [CapturedOutputFrame],
        state: &AppState,
        target: Option<&str>,
    ) -> Option<&'a CapturedOutputFrame> {
        if let Some(name) = target {
            if let Some(f) = frames.iter().find(|f| f.output_name == name) {
                return Some(f);
            }
        }
        if let Some(ref focused) = state.focused_monitor {
            if let Some(f) = frames.iter().find(|f| &f.output_name == focused) {
                return Some(f);
            }
        }
        frames.first()
    }

    fn crop_frame(
        frame: &CapturedOutputFrame,
        rx: i32,
        ry: i32,
        rw: i32,
        rh: i32,
    ) -> Option<AnnotationCanvas> {
        if frame.logical_w == 0 || frame.logical_h == 0 || frame.pixel_w == 0 || frame.pixel_h == 0
        {
            return None;
        }
        let sx_scale = frame.pixel_w as f32 / frame.logical_w as f32;
        let sy_scale = frame.pixel_h as f32 / frame.logical_h as f32;
        let px0 = (((rx - frame.logical_x).max(0) as f32) * sx_scale).round() as u32;
        let py0 = (((ry - frame.logical_y).max(0) as f32) * sy_scale).round() as u32;
        let pw = ((rw.max(1) as f32) * sx_scale).round().max(1.0) as u32;
        let ph = ((rh.max(1) as f32) * sy_scale).round().max(1.0) as u32;
        let x0 = px0.min(frame.pixel_w.saturating_sub(1));
        let y0 = py0.min(frame.pixel_h.saturating_sub(1));
        let cw = pw.min(frame.pixel_w - x0).max(1);
        let ch = ph.min(frame.pixel_h - y0).max(1);

        let mut rgba = vec![0u8; (cw * ch * 4) as usize];
        for row in 0..ch {
            let s = (((y0 + row) * frame.pixel_w + x0) as usize) * 4;
            let d = ((row * cw) as usize) * 4;
            rgba[d..d + (cw * 4) as usize].copy_from_slice(&frame.rgba[s..s + (cw * 4) as usize]);
        }
        AnnotationCanvas::from_rgba(cw, ch, rgba).ok()
    }

    fn open_editor(&mut self, mut canvas: AnnotationCanvas, ctx: &mut ShellContext) -> DirtyFlags {
        canvas.backdrop_padding = ctx.state.config.capture.backdrop_padding;
        let preview_premul = rgba_to_premul_arc(&canvas.rgba);
        self.ui = ActiveCaptureUi::Editor {
            canvas,
            preview_premul,
            tool: ToolKind::Arrow,
            color_idx: 0,
            stroke_width: 3.0,
            opaque_fill: false,
            drag_start: None,
            cursor: (0.0, 0.0),
            stroke_pts: Vec::new(),
            text_editing: None,
            status: None,
        };
        self.rebuild(ctx.state);
        DirtyFlags::CAPTURE | DirtyFlags::LAYOUT
    }

    fn refresh_editor_preview(&mut self) {
        if let ActiveCaptureUi::Editor {
            ref canvas,
            ref mut preview_premul,
            ..
        } = self.ui
        {
            *preview_premul = rgba_to_premul_arc(&canvas.rgba);
        }
    }

    fn sample_pixel_in_frame(frame: &CapturedOutputFrame, lx: f32, ly: f32) -> [u8; 4] {
        let nx = (lx / frame.logical_w.max(1) as f32).clamp(0.0, 0.999_999);
        let ny = (ly / frame.logical_h.max(1) as f32).clamp(0.0, 0.999_999);
        let px = ((nx * frame.pixel_w as f32).floor() as u32).min(frame.pixel_w.saturating_sub(1));
        let py = ((ny * frame.pixel_h as f32).floor() as u32).min(frame.pixel_h.saturating_sub(1));
        let idx = ((py * frame.pixel_w + px) as usize) * 4;
        if idx + 3 < frame.rgba.len() {
            [
                frame.rgba[idx],
                frame.rgba[idx + 1],
                frame.rgba[idx + 2],
                frame.rgba[idx + 3],
            ]
        } else {
            [0, 0, 0, 255]
        }
    }

    fn rebuild(&mut self, state: &AppState) {
        self.cached_specs.clear();
        let colors = state.palette.for_mode(state.theme_mode);
        let accent = colors.primary_color();
        let fg = colors.on_surface_color();
        let surface_bg = colors.surface_color().with_opacity(0.94);
        let border = colors.surface_variant_color();

        match &self.ui {
            ActiveCaptureUi::None => {}
            ActiveCaptureUi::Region {
                frames,
                geom_only: _,
                window_snap,
                drag_start,
                cursor,
                hover_window,
                ..
            } => {
                let Some(frame) = Self::focused_frame(frames, state, None) else {
                    return;
                };
                let w = frame.logical_w.max(1);
                let h = frame.logical_h.max(1);
                let lw = w as f32;
                let lh = h as f32;
                let mut commands = Vec::new();
                commands.push(PaintCmd::Image {
                    rect: Rect::new(0.0, 0.0, lw, lh),
                    width: frame.pixel_w,
                    height: frame.pixel_h,
                    rgba_premul: rgba_to_premul_arc(&frame.rgba),
                });
                commands.push(PaintCmd::RoundedRect {
                    rect: Rect::new(0.0, 0.0, lw, lh),
                    radius: 0.0,
                    fill: Some(Color::rgba(0, 0, 0, 88)),
                    stroke: None,
                    stroke_width: 0.0,
                });

                let active_rect = if let Some((sx, sy)) = *drag_start {
                    let rx = sx.min(cursor.0);
                    let ry = sy.min(cursor.1);
                    let rw = (cursor.0 - sx).abs().max(2.0);
                    let rh = (cursor.1 - sy).abs().max(2.0);
                    Some((rx, ry, rw, rh))
                } else if *window_snap {
                    hover_window.as_ref().map(|win| {
                        (
                            (win.x - frame.logical_x) as f32,
                            (win.y - frame.logical_y) as f32,
                            win.w as f32,
                            win.h as f32,
                        )
                    })
                } else {
                    None
                };

                if let Some((rx, ry, rw, rh)) = active_rect {
                    commands.push(PaintCmd::RoundedRect {
                        rect: Rect::new(rx, ry, rw, rh),
                        radius: 2.0,
                        fill: Some(Color::rgba(255, 255, 255, 18)),
                        stroke: Some(accent),
                        stroke_width: 2.0,
                    });
                    let dim_label = format!("{}×{}", rw.round() as i32, rh.round() as i32);
                    commands.push(PaintCmd::RoundedRect {
                        rect: Rect::new(rx, (ry - 28.0).max(4.0), 110.0, 24.0),
                        radius: 6.0,
                        fill: Some(surface_bg),
                        stroke: Some(accent),
                        stroke_width: 1.0,
                    });
                    commands.push(PaintCmd::Text {
                        rect: Rect::new(rx, (ry - 28.0).max(4.0), 110.0, 24.0),
                        text: dim_label,
                        color: fg,
                        size: 12.0,
                        bold: true,
                        align: TextAlign::Center,
                    });
                }

                // Pixel loupe near cursor
                let px = Self::sample_pixel_in_frame(frame, cursor.0, cursor.1);
                let lx = (cursor.0 + 18.0).min(lw - 148.0);
                let ly = (cursor.1 + 18.0).min(lh - 42.0);
                commands.push(PaintCmd::RoundedRect {
                    rect: Rect::new(lx, ly, 140.0, 32.0),
                    radius: 8.0,
                    fill: Some(surface_bg),
                    stroke: Some(border),
                    stroke_width: 1.0,
                });
                commands.push(PaintCmd::RoundedRect {
                    rect: Rect::new(lx + 6.0, ly + 6.0, 20.0, 20.0),
                    radius: 4.0,
                    fill: Some(Color::rgba(px[0], px[1], px[2], 255)),
                    stroke: Some(fg),
                    stroke_width: 1.0,
                });
                commands.push(PaintCmd::Text {
                    rect: Rect::new(lx + 32.0, ly + 4.0, 102.0, 24.0),
                    text: format!("#{:02X}{:02X}{:02X}", px[0], px[1], px[2]),
                    color: fg,
                    size: 12.0,
                    bold: true,
                    align: TextAlign::Left,
                });

                commands.push(PaintCmd::RichText {
                    rect: Rect::new(0.0, 14.0, lw, 26.0),
                    text: t(state.locale, I18nKey::CaptureHint).to_string(),
                    color: fg,
                    size: 13.0,
                    bold: true,
                    align: TextAlign::Center,
                    max_lines: 1,
                });

                self.cached_specs.push(SurfaceSpec {
                    id: SURFACE_REGION.into(),
                    namespace: "kaze-capture-region".into(),
                    output: Some(frame.output_name.clone()),
                    layer: Layer::Overlay,
                    keyboard_interactivity: KeyboardMode::Exclusive,
                    anchor: Anchor::TOP | Anchor::BOTTOM | Anchor::LEFT | Anchor::RIGHT,
                    exclusive_zone: -1,
                    width: w,
                    height: h,
                    margin: EdgeInsets::default(),
                    corner_radius: 0.0,
                    background: Color::rgba(0, 0, 0, 255),
                    border_color: Color::TRANSPARENT,
                    border_width: 0.0,
                    commands,
                    hit_targets: vec![HitTarget {
                        rect: Rect::new(0.0, 0.0, lw, lh),
                        id: "capture:canvas".into(),
                    }],
                    animating: false,
                    input_regions: None,
                    ime_cursor_rect: None,
                });
            }
            ActiveCaptureUi::ColorPicker {
                frames,
                format,
                cursor,
            } => {
                let Some(frame) = Self::focused_frame(frames, state, None) else {
                    return;
                };
                let w = frame.logical_w.max(1);
                let h = frame.logical_h.max(1);
                let lw = w as f32;
                let lh = h as f32;
                let px = Self::sample_pixel_in_frame(frame, cursor.0, cursor.1);
                let formatted = format_color(px[0], px[1], px[2], *format);

                let lx = (cursor.0 + 16.0).min(lw - 220.0);
                let ly = (cursor.1 + 16.0).min(lh - 52.0);
                let mut commands = vec![PaintCmd::Image {
                    rect: Rect::new(0.0, 0.0, lw, lh),
                    width: frame.pixel_w,
                    height: frame.pixel_h,
                    rgba_premul: rgba_to_premul_arc(&frame.rgba),
                }];
                commands.push(PaintCmd::RoundedRect {
                    rect: Rect::new(lx, ly, 210.0, 42.0),
                    radius: 10.0,
                    fill: Some(surface_bg),
                    stroke: Some(accent),
                    stroke_width: 1.5,
                });
                commands.push(PaintCmd::RoundedRect {
                    rect: Rect::new(lx + 8.0, ly + 8.0, 26.0, 26.0),
                    radius: 6.0,
                    fill: Some(Color::rgba(px[0], px[1], px[2], 255)),
                    stroke: Some(fg),
                    stroke_width: 1.0,
                });
                commands.push(PaintCmd::Text {
                    rect: Rect::new(lx + 42.0, ly + 8.0, 160.0, 26.0),
                    text: format!("{}  ({})", formatted, format.name()),
                    color: fg,
                    size: 12.5,
                    bold: true,
                    align: TextAlign::Left,
                });

                self.cached_specs.push(SurfaceSpec {
                    id: SURFACE_PICKER.into(),
                    namespace: "kaze-color-picker".into(),
                    output: Some(frame.output_name.clone()),
                    layer: Layer::Overlay,
                    keyboard_interactivity: KeyboardMode::Exclusive,
                    anchor: Anchor::TOP | Anchor::BOTTOM | Anchor::LEFT | Anchor::RIGHT,
                    exclusive_zone: -1,
                    width: w,
                    height: h,
                    margin: EdgeInsets::default(),
                    corner_radius: 0.0,
                    background: Color::rgba(0, 0, 0, 255),
                    border_color: Color::TRANSPARENT,
                    border_width: 0.0,
                    commands,
                    hit_targets: vec![HitTarget {
                        rect: Rect::new(0.0, 0.0, lw, lh),
                        id: "picker:canvas".into(),
                    }],
                    animating: false,
                    input_regions: None,
                    ime_cursor_rect: None,
                });
            }
            ActiveCaptureUi::Editor {
                canvas,
                preview_premul,
                tool,
                color_idx,
                opaque_fill,
                drag_start,
                cursor,
                text_editing,
                status,
                ..
            } => {
                let win_w = canvas.width.clamp(760, 1560);
                let win_h = (canvas.height + 84).clamp(480, 940);
                let fw = win_w as f32;
                let fh = win_h as f32;

                let mut commands = Vec::new();
                let mut hit_targets = Vec::new();

                // Top toolbar
                let bar_y = 10.0;
                let mut tx = 14.0;
                for (idx, tk) in ToolKind::ALL.iter().enumerate() {
                    let bw = 62.0;
                    let rect = Rect::new(tx, bar_y, bw, 28.0);
                    let active = *tk == *tool;
                    commands.push(PaintCmd::RoundedRect {
                        rect,
                        radius: 6.0,
                        fill: Some(if active {
                            accent
                        } else {
                            colors.surface_container_color()
                        }),
                        stroke: None,
                        stroke_width: 0.0,
                    });
                    commands.push(PaintCmd::Text {
                        rect,
                        text: tk.label().to_string(),
                        color: if active {
                            colors.on_primary_color()
                        } else {
                            fg
                        },
                        size: 11.0,
                        bold: active,
                        align: TextAlign::Center,
                    });
                    hit_targets.push(HitTarget {
                        rect,
                        id: format!("capture:tool:{idx}"),
                    });
                    tx += bw + 4.0;
                }

                // Right action buttons: Backdrop, Fill, Undo, Copy, Save
                let action_btns = [
                    (
                        "capture:backdrop",
                        if canvas.backdrop_enabled {
                            "Pad*"
                        } else {
                            "Pad"
                        },
                    ),
                    ("capture:fill", if *opaque_fill { "Fill*" } else { "Fill" }),
                    ("capture:undo", "Undo"),
                    ("capture:copy", "Copy"),
                    ("capture:save", "Save"),
                ];
                let mut bx = fw - 14.0;
                for (id, label) in action_btns.iter().rev() {
                    let bw = 54.0;
                    bx -= bw;
                    let rect = Rect::new(bx, bar_y, bw, 28.0);
                    commands.push(PaintCmd::RoundedRect {
                        rect,
                        radius: 6.0,
                        fill: Some(colors.surface_container_color()),
                        stroke: Some(border),
                        stroke_width: 1.0,
                    });
                    commands.push(PaintCmd::Text {
                        rect,
                        text: (*label).to_string(),
                        color: fg,
                        size: 11.0,
                        bold: true,
                        align: TextAlign::Center,
                    });
                    hit_targets.push(HitTarget {
                        rect,
                        id: (*id).to_string(),
                    });
                    bx -= 4.0;
                }

                // Canvas viewport
                let canvas_rect = Rect::new(14.0, 50.0, fw - 28.0, fh - 68.0);
                commands.push(PaintCmd::Image {
                    rect: canvas_rect,
                    width: canvas.width,
                    height: canvas.height,
                    rgba_premul: Arc::clone(preview_premul),
                });
                hit_targets.push(HitTarget {
                    rect: canvas_rect,
                    id: "capture:canvas".into(),
                });

                if let Some((sx, sy)) = *drag_start {
                    let rx = sx.min(cursor.0);
                    let ry = sy.min(cursor.1);
                    let rw = (cursor.0 - sx).abs().max(2.0);
                    let rh = (cursor.1 - sy).abs().max(2.0);
                    let sw = SWATCH_COLORS[*color_idx % SWATCH_COLORS.len()];
                    commands.push(PaintCmd::RoundedRect {
                        rect: Rect::new(rx, ry, rw, rh),
                        radius: 2.0,
                        fill: None,
                        stroke: Some(Color::rgba(sw[0], sw[1], sw[2], 220)),
                        stroke_width: 2.0,
                    });
                }

                if let Some((tx_pos, ty_pos, ref ti)) = *text_editing {
                    commands.push(PaintCmd::TextInputField {
                        rect: Rect::new(tx_pos, ty_pos, 260.0, 32.0),
                        text: ti.text.clone(),
                        preedit: ti.preedit.clone(),
                        cursor_byte: ti.cursor,
                        selection: ti.selection_range(),
                        placeholder: "Type annotation...".into(),
                        password_mode: false,
                        color: fg,
                        preedit_color: accent,
                        selection_color: colors.surface_container_color(),
                        placeholder_color: colors.on_surface_variant_color(),
                        size: 14.0,
                    });
                }

                if let Some(ref msg) = *status {
                    commands.push(PaintCmd::Text {
                        rect: Rect::new(14.0, fh - 18.0, fw - 28.0, 16.0),
                        text: msg.clone(),
                        color: accent,
                        size: 11.0,
                        bold: true,
                        align: TextAlign::Left,
                    });
                }

                self.cached_specs.push(SurfaceSpec {
                    id: SURFACE_EDITOR.into(),
                    namespace: "kaze-capture-editor".into(),
                    output: None,
                    layer: Layer::Overlay,
                    keyboard_interactivity: KeyboardMode::Exclusive,
                    anchor: Anchor::empty(),
                    exclusive_zone: 0,
                    width: win_w,
                    height: win_h,
                    margin: EdgeInsets::default(),
                    corner_radius: 12.0,
                    background: surface_bg,
                    border_color: border,
                    border_width: 1.5,
                    commands,
                    hit_targets,
                    animating: false,
                    input_regions: None,
                    ime_cursor_rect: None,
                });
            }
        }
    }
}

fn rgba_to_premul_arc(rgba: &[u8]) -> Arc<[u8]> {
    let mut out = rgba.to_vec();
    for px in out.as_chunks_mut::<4>().0 {
        let a = u16::from(px[3]);
        if a < 255 {
            px[0] = ((u16::from(px[0]) * a) / 255) as u8;
            px[1] = ((u16::from(px[1]) * a) / 255) as u8;
            px[2] = ((u16::from(px[2]) * a) / 255) as u8;
        }
    }
    Arc::<[u8]>::from(out)
}

impl KazeExtension for CaptureExtension {
    fn id(&self) -> &'static str {
        "capture"
    }

    fn on_init(&mut self, _ctx: &mut ShellContext) {}

    fn on_event(&mut self, event: &SystemEvent, ctx: &mut ShellContext) -> DirtyFlags {
        match event {
            SystemEvent::ScreencopyReady {
                request_id,
                frames,
                windows,
            } => {
                let Some((expected_id, mode)) = self.pending_req.take() else {
                    return DirtyFlags::NONE;
                };
                if expected_id != *request_id {
                    self.pending_req = Some((expected_id, mode));
                    return DirtyFlags::NONE;
                }
                match mode {
                    PendingCaptureMode::Full { save_only } => {
                        let Some(frame) = Self::focused_frame(frames, ctx.state, None) else {
                            return self.close_all(ctx, true);
                        };
                        let Ok(canvas) = AnnotationCanvas::from_rgba(
                            frame.pixel_w,
                            frame.pixel_h,
                            frame.rgba.to_vec(),
                        ) else {
                            return self.close_all(ctx, true);
                        };
                        if let Some(path) = save_only {
                            let res = canvas.save_png_to(&path);
                            ctx.push_action(ShellAction::CaptureReply {
                                text: res.ok().map(|()| path.display().to_string()),
                            });
                            return self.close_all(ctx, false);
                        }
                        self.open_editor(canvas, ctx)
                    }
                    PendingCaptureMode::Output { target, save_only } => {
                        let Some(frame) = Self::focused_frame(frames, ctx.state, target.as_deref())
                        else {
                            return self.close_all(ctx, true);
                        };
                        let Ok(canvas) = AnnotationCanvas::from_rgba(
                            frame.pixel_w,
                            frame.pixel_h,
                            frame.rgba.to_vec(),
                        ) else {
                            return self.close_all(ctx, true);
                        };
                        if let Some(path) = save_only {
                            let res = canvas.save_png_to(&path);
                            ctx.push_action(ShellAction::CaptureReply {
                                text: res.ok().map(|()| path.display().to_string()),
                            });
                            return self.close_all(ctx, false);
                        }
                        self.open_editor(canvas, ctx)
                    }
                    PendingCaptureMode::Region { geom_only } => {
                        self.ui = ActiveCaptureUi::Region {
                            frames: frames.clone(),
                            windows: windows.clone(),
                            geom_only,
                            window_snap: false,
                            drag_start: None,
                            cursor: (0.0, 0.0),
                            hover_window: None,
                        };
                        self.rebuild(ctx.state);
                        DirtyFlags::CAPTURE | DirtyFlags::LAYOUT
                    }
                    PendingCaptureMode::Window => {
                        self.ui = ActiveCaptureUi::Region {
                            frames: frames.clone(),
                            windows: windows.clone(),
                            geom_only: false,
                            window_snap: true,
                            drag_start: None,
                            cursor: (0.0, 0.0),
                            hover_window: windows.first().cloned(),
                        };
                        self.rebuild(ctx.state);
                        DirtyFlags::CAPTURE | DirtyFlags::LAYOUT
                    }
                    PendingCaptureMode::ColorPicker { format } => {
                        self.ui = ActiveCaptureUi::ColorPicker {
                            frames: frames.clone(),
                            format,
                            cursor: (0.0, 0.0),
                        };
                        self.rebuild(ctx.state);
                        DirtyFlags::CAPTURE | DirtyFlags::LAYOUT
                    }
                }
            }
            SystemEvent::ScreencopyFailed { request_id, error } => {
                if self
                    .pending_req
                    .as_ref()
                    .is_some_and(|(id, _)| id == request_id)
                {
                    eprintln!("kaze-ext-capture: screencopy failed: {error}");
                    return self.close_all(ctx, true);
                }
                DirtyFlags::NONE
            }
            SystemEvent::PointerMotion { surface_id, x, y } => match &mut self.ui {
                ActiveCaptureUi::Region {
                    frames,
                    windows,
                    cursor,
                    hover_window,
                    window_snap,
                    ..
                } if surface_id == SURFACE_REGION => {
                    *cursor = (*x, *y);
                    if *window_snap {
                        if let Some(frame) = Self::focused_frame(frames, ctx.state, None) {
                            let gx = frame.logical_x + x.round() as i32;
                            let gy = frame.logical_y + y.round() as i32;
                            *hover_window = windows
                                .iter()
                                .find(|w| {
                                    gx >= w.x && gx < w.x + w.w && gy >= w.y && gy < w.y + w.h
                                })
                                .cloned();
                        }
                    }
                    self.rebuild(ctx.state);
                    DirtyFlags::CAPTURE
                }
                ActiveCaptureUi::ColorPicker { cursor, .. } if surface_id == SURFACE_PICKER => {
                    *cursor = (*x, *y);
                    self.rebuild(ctx.state);
                    DirtyFlags::CAPTURE
                }
                _ => DirtyFlags::NONE,
            },
            SystemEvent::PointerDrag {
                surface_id,
                target_id,
                x,
                y,
            } if target_id == "capture:canvas" => match &mut self.ui {
                ActiveCaptureUi::Region { cursor, .. } if surface_id == SURFACE_REGION => {
                    *cursor = (*x, *y);
                    self.rebuild(ctx.state);
                    DirtyFlags::CAPTURE
                }
                ActiveCaptureUi::Editor {
                    cursor, stroke_pts, ..
                } if surface_id == SURFACE_EDITOR => {
                    *cursor = (*x, *y);
                    stroke_pts.push((*x - 14.0, *y - 50.0));
                    self.rebuild(ctx.state);
                    DirtyFlags::CAPTURE
                }
                _ => DirtyFlags::NONE,
            },
            SystemEvent::PointerClickAt {
                surface_id,
                target_id,
                button: PointerButton::Left,
                x,
                y,
            } => {
                if surface_id == SURFACE_PICKER {
                    if let ActiveCaptureUi::ColorPicker { frames, format, .. } = &self.ui {
                        if let Some(frame) = Self::focused_frame(frames, ctx.state, None) {
                            let px = Self::sample_pixel_in_frame(frame, *x, *y);
                            let formatted = format_color(px[0], px[1], px[2], *format);
                            if self.recent_swatches.len() >= 8 {
                                self.recent_swatches.pop_front();
                            }
                            self.recent_swatches.push_back(formatted.clone());
                            ctx.push_action(ShellAction::SetClipboardText(formatted.clone()));
                            ctx.push_action(ShellAction::SendNotification {
                                app_name: "kaze-shell".into(),
                                summary: t(ctx.state.locale, I18nKey::ColorCopied).to_string(),
                                body: formatted,
                            });
                        }
                    }
                    return self.close_all(ctx, false);
                }
                if surface_id == SURFACE_REGION && target_id == "capture:canvas" {
                    if let ActiveCaptureUi::Region {
                        ref mut drag_start,
                        ref mut cursor,
                        ..
                    } = self.ui
                    {
                        *drag_start = Some((*x, *y));
                        *cursor = (*x, *y);
                        self.rebuild(ctx.state);
                        return DirtyFlags::CAPTURE;
                    }
                }
                if surface_id == SURFACE_EDITOR {
                    if let Some(idx_str) = target_id.strip_prefix("capture:tool:") {
                        if let Ok(idx) = idx_str.parse::<usize>() {
                            if let Some(&tk) = ToolKind::ALL.get(idx) {
                                if let ActiveCaptureUi::Editor { ref mut tool, .. } = self.ui {
                                    *tool = tk;
                                }
                                self.rebuild(ctx.state);
                                return DirtyFlags::CAPTURE;
                            }
                        }
                    }
                    match target_id.as_str() {
                        "capture:canvas" => {
                            if let ActiveCaptureUi::Editor {
                                ref mut drag_start,
                                ref mut cursor,
                                ref mut stroke_pts,
                                ref tool,
                                ref mut text_editing,
                                ..
                            } = self.ui
                            {
                                if *tool == ToolKind::Text {
                                    *text_editing =
                                        Some((*x - 14.0, *y - 50.0, TextInputState::new(false)));
                                } else {
                                    *drag_start = Some((*x, *y));
                                    *cursor = (*x, *y);
                                    stroke_pts.clear();
                                    stroke_pts.push((*x - 14.0, *y - 50.0));
                                }
                                self.rebuild(ctx.state);
                                return DirtyFlags::CAPTURE;
                            }
                        }
                        "capture:backdrop" => {
                            if let ActiveCaptureUi::Editor { ref mut canvas, .. } = self.ui {
                                canvas.backdrop_enabled = !canvas.backdrop_enabled;
                            }
                            self.rebuild(ctx.state);
                            return DirtyFlags::CAPTURE;
                        }
                        "capture:fill" => {
                            if let ActiveCaptureUi::Editor {
                                ref mut opaque_fill,
                                ..
                            } = self.ui
                            {
                                *opaque_fill = !*opaque_fill;
                            }
                            self.rebuild(ctx.state);
                            return DirtyFlags::CAPTURE;
                        }
                        "capture:undo" => {
                            if let ActiveCaptureUi::Editor { ref mut canvas, .. } = self.ui {
                                if canvas.undo() {
                                    self.refresh_editor_preview();
                                }
                            }
                            self.rebuild(ctx.state);
                            return DirtyFlags::CAPTURE;
                        }
                        "capture:copy" => {
                            if let ActiveCaptureUi::Editor { ref canvas, .. } = self.ui {
                                if let Ok(png) = canvas.encode_png() {
                                    ctx.push_action(ShellAction::SetClipboardSelection {
                                        mime: "image/png".into(),
                                        bytes: png,
                                    });
                                }
                            }
                            return self.close_all(ctx, false);
                        }
                        "capture:save" => {
                            if let ActiveCaptureUi::Editor { ref canvas, .. } = self.ui {
                                let out = default_screenshot_path(
                                    ctx.state.config.capture.save_dir.as_deref(),
                                );
                                if canvas.save_png_to(&out).is_ok() {
                                    ctx.push_action(ShellAction::SendNotification {
                                        app_name: "kaze-shell".into(),
                                        summary: t(ctx.state.locale, I18nKey::AnnotateSaved)
                                            .to_string(),
                                        body: out.display().to_string(),
                                    });
                                }
                            }
                            return self.close_all(ctx, false);
                        }
                        _ => {}
                    }
                }
                DirtyFlags::NONE
            }
            SystemEvent::PointerRelease {
                surface_id,
                target_id,
                x,
                y,
            } if target_id == "capture:canvas" => {
                if surface_id == SURFACE_REGION {
                    let action_canvas = if let ActiveCaptureUi::Region {
                        ref frames,
                        geom_only,
                        window_snap,
                        drag_start,
                        ref hover_window,
                        ..
                    } = self.ui
                    {
                        let frame = Self::focused_frame(frames, ctx.state, None).cloned();
                        match (frame, drag_start, window_snap, hover_window) {
                            (Some(fr), Some((sx, sy)), _, _)
                                if (x - sx).abs() >= 4.0 && (y - sy).abs() >= 4.0 =>
                            {
                                let rx = fr.logical_x + sx.min(*x).round() as i32;
                                let ry = fr.logical_y + sy.min(*y).round() as i32;
                                let rw = (x - sx).abs().round() as i32;
                                let rh = (y - sy).abs().round() as i32;
                                if geom_only {
                                    ctx.push_action(ShellAction::CaptureReply {
                                        text: Some(format!(
                                            "{rx},{ry} {rw}x{rh}\n{}",
                                            fr.output_name
                                        )),
                                    });
                                    return self.close_all(ctx, false);
                                }
                                Self::crop_frame(&fr, rx, ry, rw, rh)
                            }
                            (Some(fr), _, true, Some(win)) => {
                                Self::crop_frame(&fr, win.x, win.y, win.w, win.h)
                            }
                            _ => None,
                        }
                    } else {
                        None
                    };
                    if let Some(canvas) = action_canvas {
                        return self.open_editor(canvas, ctx);
                    }
                    self.rebuild(ctx.state);
                    return DirtyFlags::CAPTURE;
                }
                if surface_id == SURFACE_EDITOR {
                    if let ActiveCaptureUi::Editor {
                        ref mut canvas,
                        ref mut drag_start,
                        ref stroke_pts,
                        tool,
                        color_idx,
                        stroke_width,
                        opaque_fill,
                        ..
                    } = self.ui
                    {
                        if let Some((sx, sy)) = drag_start.take() {
                            let c = SWATCH_COLORS[color_idx % SWATCH_COLORS.len()];
                            canvas.apply_shape(
                                tool,
                                sx - 14.0,
                                sy - 50.0,
                                *x - 14.0,
                                *y - 50.0,
                                stroke_pts,
                                c,
                                stroke_width,
                                opaque_fill,
                            );
                        }
                    }
                    self.refresh_editor_preview();
                    self.rebuild(ctx.state);
                    return DirtyFlags::CAPTURE;
                }
                DirtyFlags::NONE
            }
            SystemEvent::KeyInput { surface_id, key } if key.pressed => {
                if !self.is_open() {
                    return DirtyFlags::NONE;
                }
                if *surface_id == SURFACE_PICKER {
                    if key.keysym == KEY_ESCAPE {
                        return self.close_all(ctx, false);
                    }
                    if key.keysym == KEY_TAB {
                        if let ActiveCaptureUi::ColorPicker { ref mut format, .. } = self.ui {
                            *format = format.next();
                            self.rebuild(ctx.state);
                            return DirtyFlags::CAPTURE;
                        }
                    }
                    return DirtyFlags::NONE;
                }
                if *surface_id == SURFACE_REGION {
                    if key.keysym == KEY_ESCAPE {
                        return self.close_all(ctx, true);
                    }
                    return DirtyFlags::NONE;
                }
                if *surface_id == SURFACE_EDITOR {
                    if let ActiveCaptureUi::Editor {
                        ref mut canvas,
                        ref mut text_editing,
                        color_idx,
                        ..
                    } = self.ui
                    {
                        if let Some((tx_pos, ty_pos, mut ti)) = text_editing.take() {
                            match ti.handle_key(key, &ctx.state.config.input.keybinds) {
                                TextInputOutcome::Submit => {
                                    let c = SWATCH_COLORS[color_idx % SWATCH_COLORS.len()];
                                    canvas.draw_text(tx_pos, ty_pos, &ti.text, c, 18.0, true);
                                    self.refresh_editor_preview();
                                }
                                TextInputOutcome::Cancel => {}
                                _ => {
                                    *text_editing = Some((tx_pos, ty_pos, ti));
                                }
                            }
                            self.rebuild(ctx.state);
                            return DirtyFlags::CAPTURE;
                        }
                    }
                    if key.keysym == KEY_ESCAPE {
                        return self.close_all(ctx, false);
                    }
                    if key.modifiers.ctrl {
                        match key.utf8.as_deref() {
                            Some("z") | Some("\u{1a}") => {
                                if let ActiveCaptureUi::Editor { ref mut canvas, .. } = self.ui {
                                    let changed = if key.modifiers.shift {
                                        canvas.redo()
                                    } else {
                                        canvas.undo()
                                    };
                                    if changed {
                                        self.refresh_editor_preview();
                                        self.rebuild(ctx.state);
                                        return DirtyFlags::CAPTURE;
                                    }
                                }
                            }
                            Some("Z") => {
                                if let ActiveCaptureUi::Editor { ref mut canvas, .. } = self.ui {
                                    if canvas.redo() {
                                        self.refresh_editor_preview();
                                        self.rebuild(ctx.state);
                                        return DirtyFlags::CAPTURE;
                                    }
                                }
                            }
                            Some("c") | Some("\u{3}") => {
                                if let ActiveCaptureUi::Editor { ref canvas, .. } = self.ui {
                                    if let Ok(png) = canvas.encode_png() {
                                        ctx.push_action(ShellAction::SetClipboardSelection {
                                            mime: "image/png".into(),
                                            bytes: png,
                                        });
                                    }
                                }
                                return self.close_all(ctx, false);
                            }
                            Some("s") | Some("\u{13}") => {
                                if let ActiveCaptureUi::Editor { ref canvas, .. } = self.ui {
                                    let out = default_screenshot_path(
                                        ctx.state.config.capture.save_dir.as_deref(),
                                    );
                                    if canvas.save_png_to(&out).is_ok() {
                                        ctx.push_action(ShellAction::SendNotification {
                                            app_name: "kaze-shell".into(),
                                            summary: t(ctx.state.locale, I18nKey::AnnotateSaved)
                                                .to_string(),
                                            body: out.display().to_string(),
                                        });
                                    }
                                }
                                return self.close_all(ctx, false);
                            }
                            _ => {}
                        }
                    }
                }
                DirtyFlags::NONE
            }
            SystemEvent::SurfaceClosed { surface_id }
                if surface_id == SURFACE_REGION
                    || surface_id == SURFACE_EDITOR
                    || surface_id == SURFACE_PICKER =>
            {
                self.close_all(ctx, true)
            }
            _ => DirtyFlags::NONE,
        }
    }

    fn on_ipc(&mut self, cmd: &str, args: &[String], ctx: &mut ShellContext) -> IpcResult {
        match cmd {
            "color-picker" => {
                let fmt = args
                    .first()
                    .map(|s| ColorFormat::parse(s))
                    .unwrap_or(ColorFormat::Hex);
                self.start_capture(PendingCaptureMode::ColorPicker { format: fmt }, ctx)
            }
            "capture" => {
                let sub = args.first().map(String::as_str).unwrap_or("full");
                let mut save_only: Option<PathBuf> = None;
                let mut geom_only = false;
                let mut positional: Option<String> = None;
                let mut i = 1;
                while i < args.len() {
                    match args[i].as_str() {
                        "--save-only" => {
                            if let Some(p) = args.get(i + 1) {
                                save_only = Some(PathBuf::from(p));
                                i += 2;
                            } else {
                                return IpcResult::Handled {
                                    ok: false,
                                    message: "--save-only requires a path".into(),
                                    dirty: DirtyFlags::NONE,
                                };
                            }
                        }
                        "--geom-only" => {
                            geom_only = true;
                            i += 1;
                        }
                        other => {
                            positional = Some(other.to_string());
                            i += 1;
                        }
                    }
                }
                let mode = match sub {
                    "full" => PendingCaptureMode::Full { save_only },
                    "output" => PendingCaptureMode::Output {
                        target: positional,
                        save_only,
                    },
                    "region" => PendingCaptureMode::Region { geom_only },
                    "window" => PendingCaptureMode::Window,
                    _ => {
                        return IpcResult::Handled {
                            ok: false,
                            message: format!(
                                "unknown capture mode '{sub}' (expected full|output|region|window)"
                            ),
                            dirty: DirtyFlags::NONE,
                        };
                    }
                };
                self.start_capture(mode, ctx)
            }
            _ => IpcResult::Unhandled,
        }
    }

    fn surfaces(&self) -> Vec<SurfaceSpec> {
        self.cached_specs.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use kaze_core::{Config, KeyEvent};

    #[test]
    fn escape_cancels_editor_and_drops_all_capture_surfaces() {
        let mut state = AppState::new(Config::default());
        let mut ext = CaptureExtension::new();
        let mut ctx = ShellContext::new(&mut state);

        ext.on_ipc("capture", &["full".into()], &mut ctx);
        let req_id = ctx
            .actions
            .iter()
            .find_map(|a| match a {
                ShellAction::RequestScreencopy { request_id } => Some(*request_id),
                _ => None,
            })
            .expect("screencopy requested");

        ext.on_event(
            &SystemEvent::ScreencopyReady {
                request_id: req_id,
                frames: vec![CapturedOutputFrame {
                    output_name: "eDP-1".into(),
                    logical_x: 0,
                    logical_y: 0,
                    logical_w: 800,
                    logical_h: 600,
                    pixel_w: 800,
                    pixel_h: 600,
                    rgba: Arc::<[u8]>::from(vec![255u8; 800 * 600 * 4]),
                }],
                windows: Vec::new(),
            },
            &mut ctx,
        );
        assert_eq!(ext.surfaces().len(), 1);

        ext.on_event(
            &SystemEvent::KeyInput {
                surface_id: SURFACE_EDITOR.into(),
                key: KeyEvent {
                    keysym: KEY_ESCAPE,
                    utf8: None,
                    modifiers: Default::default(),
                    pressed: true,
                },
            },
            &mut ctx,
        );
        assert!(ext.surfaces().is_empty());
        assert!(!ext.is_open());
    }
}
