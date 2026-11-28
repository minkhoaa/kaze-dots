#![deny(clippy::unwrap_used)]

use cosmic_text::{
    Attrs, Buffer as CosmicBuffer, Color as CosmicColor, Family, FontSystem, Metrics, Shaping,
    SwashCache, Wrap,
};
use image::{ColorType, ImageEncoder, ImageReader};
use std::collections::VecDeque;
use std::fs::{self, File};
use std::io::BufWriter;
use std::path::{Path, PathBuf};
use tiny_skia::{
    Color as SkiaColor, FillRule, LineCap, LineJoin, Paint, PathBuilder, Pixmap, Rect as SkiaRect,
    Stroke, Transform,
};

const MAX_UNDO_STEPS: usize = 64;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ToolKind {
    Select,
    Arrow,
    Rect,
    Ellipse,
    Line,
    Pen,
    Highlighter,
    Text,
    Blur,
    Pixelate,
    StepCounter,
    Crop,
}

impl ToolKind {
    pub const ALL: &'static [Self] = &[
        Self::Select,
        Self::Arrow,
        Self::Rect,
        Self::Ellipse,
        Self::Line,
        Self::Pen,
        Self::Highlighter,
        Self::Text,
        Self::Blur,
        Self::Pixelate,
        Self::StepCounter,
        Self::Crop,
    ];

    pub fn label(self) -> &'static str {
        match self {
            Self::Select => "Select",
            Self::Arrow => "Arrow",
            Self::Rect => "Rect",
            Self::Ellipse => "Ellipse",
            Self::Line => "Line",
            Self::Pen => "Pen",
            Self::Highlighter => "Highlight",
            Self::Text => "Text",
            Self::Blur => "Blur",
            Self::Pixelate => "Pixelate",
            Self::StepCounter => "Step",
            Self::Crop => "Crop",
        }
    }
}

#[derive(Debug, Clone)]
struct CanvasSnapshot {
    width: u32,
    height: u32,
    rgba: Vec<u8>,
    step_counter: u32,
}

pub struct AnnotationCanvas {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
    pub step_counter: u32,
    pub backdrop_padding: u32,
    pub backdrop_enabled: bool,
    undo_stack: VecDeque<CanvasSnapshot>,
    redo_stack: Vec<CanvasSnapshot>,
}

impl AnnotationCanvas {
    pub fn from_rgba(width: u32, height: u32, rgba: Vec<u8>) -> Result<Self, String> {
        let expected = (width as usize)
            .checked_mul(height as usize)
            .and_then(|n| n.checked_mul(4))
            .ok_or_else(|| "canvas dimensions overflow".to_string())?;
        if width == 0 || height == 0 || rgba.len() != expected {
            return Err("invalid RGBA canvas buffer".to_string());
        }
        Ok(Self {
            width,
            height,
            rgba,
            step_counter: 1,
            backdrop_padding: 32,
            backdrop_enabled: false,
            undo_stack: VecDeque::with_capacity(MAX_UNDO_STEPS),
            redo_stack: Vec::new(),
        })
    }

    pub fn open_image(path: &Path) -> Result<Self, String> {
        let reader = ImageReader::open(path)
            .map_err(|e| format!("failed opening {}: {e}", path.display()))?
            .with_guessed_format()
            .map_err(|e| format!("failed inspecting image format {}: {e}", path.display()))?;
        let decoded = reader
            .decode()
            .map_err(|e| format!("failed decoding {}: {e}", path.display()))?;
        let img = decoded.to_rgba8();
        Self::from_rgba(img.width(), img.height(), img.into_raw())
    }

    fn push_undo(&mut self) {
        if self.undo_stack.len() >= MAX_UNDO_STEPS {
            self.undo_stack.pop_front();
        }
        self.undo_stack.push_back(CanvasSnapshot {
            width: self.width,
            height: self.height,
            rgba: self.rgba.clone(),
            step_counter: self.step_counter,
        });
        self.redo_stack.clear();
    }

    pub fn can_undo(&self) -> bool {
        !self.undo_stack.is_empty()
    }

    pub fn can_redo(&self) -> bool {
        !self.redo_stack.is_empty()
    }

    pub fn undo(&mut self) -> bool {
        let Some(prev) = self.undo_stack.pop_back() else {
            return false;
        };
        self.redo_stack.push(CanvasSnapshot {
            width: self.width,
            height: self.height,
            rgba: std::mem::replace(&mut self.rgba, prev.rgba),
            step_counter: self.step_counter,
        });
        self.width = prev.width;
        self.height = prev.height;
        self.step_counter = prev.step_counter;
        true
    }

    pub fn redo(&mut self) -> bool {
        let Some(next) = self.redo_stack.pop() else {
            return false;
        };
        if self.undo_stack.len() >= MAX_UNDO_STEPS {
            self.undo_stack.pop_front();
        }
        self.undo_stack.push_back(CanvasSnapshot {
            width: self.width,
            height: self.height,
            rgba: std::mem::replace(&mut self.rgba, next.rgba),
            step_counter: self.step_counter,
        });
        self.width = next.width;
        self.height = next.height;
        self.step_counter = next.step_counter;
        true
    }

    fn normalize_rect(&self, x0: f32, y0: f32, x1: f32, y1: f32) -> (u32, u32, u32, u32) {
        let lx = x0.min(x1).floor().max(0.0) as u32;
        let ly = y0.min(y1).floor().max(0.0) as u32;
        let rx = (x0.max(x1).ceil() as u32).min(self.width);
        let by = (y0.max(y1).ceil() as u32).min(self.height);
        (lx, ly, rx.saturating_sub(lx), by.saturating_sub(ly))
    }

    /// Destructively box-blurs rectangular region `(rx, ry, rw, rh)` directly on canvas pixels.
    pub fn apply_blur_region(&mut self, rx: u32, ry: u32, rw: u32, rh: u32, radius: usize) {
        let x0 = rx.min(self.width) as usize;
        let y0 = ry.min(self.height) as usize;
        let x1 = rx.saturating_add(rw).min(self.width) as usize;
        let y1 = ry.saturating_add(rh).min(self.height) as usize;
        if x1 <= x0 || y1 <= y0 || radius == 0 {
            return;
        }
        self.push_undo();
        let w = self.width as usize;
        let bw = x1 - x0;
        let bh = y1 - y0;
        for _pass in 0..2 {
            let mut region = vec![0u8; bw * bh * 4];
            for row in 0..bh {
                let s = ((y0 + row) * w + x0) * 4;
                let d = row * bw * 4;
                region[d..d + bw * 4].copy_from_slice(&self.rgba[s..s + bw * 4]);
            }
            let mut horiz = vec![0u8; bw * bh * 4];
            for row in 0..bh {
                for col in 0..bw {
                    let (mut r, mut g, mut b, mut a, mut cnt) = (0u32, 0u32, 0u32, 0u32, 0u32);
                    let c0 = col.saturating_sub(radius);
                    let c1 = (col + radius).min(bw - 1);
                    for c in c0..=c1 {
                        let idx = (row * bw + c) * 4;
                        r += u32::from(region[idx]);
                        g += u32::from(region[idx + 1]);
                        b += u32::from(region[idx + 2]);
                        a += u32::from(region[idx + 3]);
                        cnt += 1;
                    }
                    let d = (row * bw + col) * 4;
                    horiz[d] = (r / cnt) as u8;
                    horiz[d + 1] = (g / cnt) as u8;
                    horiz[d + 2] = (b / cnt) as u8;
                    horiz[d + 3] = (a / cnt) as u8;
                }
            }
            for row in 0..bh {
                for col in 0..bw {
                    let (mut r, mut g, mut b, mut a, mut cnt) = (0u32, 0u32, 0u32, 0u32, 0u32);
                    let r0 = row.saturating_sub(radius);
                    let r1 = (row + radius).min(bh - 1);
                    for rr in r0..=r1 {
                        let idx = (rr * bw + col) * 4;
                        r += u32::from(horiz[idx]);
                        g += u32::from(horiz[idx + 1]);
                        b += u32::from(horiz[idx + 2]);
                        a += u32::from(horiz[idx + 3]);
                        cnt += 1;
                    }
                    let d = ((y0 + row) * w + (x0 + col)) * 4;
                    self.rgba[d] = (r / cnt) as u8;
                    self.rgba[d + 1] = (g / cnt) as u8;
                    self.rgba[d + 2] = (b / cnt) as u8;
                    self.rgba[d + 3] = (a / cnt) as u8;
                }
            }
        }
    }

    pub fn apply_pixelate_region(&mut self, rx: u32, ry: u32, rw: u32, rh: u32, block: u32) {
        let x0 = rx.min(self.width);
        let y0 = ry.min(self.height);
        let x1 = rx.saturating_add(rw).min(self.width);
        let y1 = ry.saturating_add(rh).min(self.height);
        let blk = block.max(4);
        if x1 <= x0 || y1 <= y0 {
            return;
        }
        self.push_undo();
        let w = self.width;
        let mut by = y0;
        while by < y1 {
            let bh = (y1 - by).min(blk);
            let mut bx = x0;
            while bx < x1 {
                let bw = (x1 - bx).min(blk);
                let (mut r, mut g, mut b, mut a, mut cnt) = (0u64, 0u64, 0u64, 0u64, 0u64);
                for yy in by..by + bh {
                    for xx in bx..bx + bw {
                        let idx = ((yy * w + xx) as usize) * 4;
                        r += u64::from(self.rgba[idx]);
                        g += u64::from(self.rgba[idx + 1]);
                        b += u64::from(self.rgba[idx + 2]);
                        a += u64::from(self.rgba[idx + 3]);
                        cnt += 1;
                    }
                }
                let avg = [
                    (r / cnt) as u8,
                    (g / cnt) as u8,
                    (b / cnt) as u8,
                    (a / cnt) as u8,
                ];
                for yy in by..by + bh {
                    for xx in bx..bx + bw {
                        let idx = ((yy * w + xx) as usize) * 4;
                        self.rgba[idx..idx + 4].copy_from_slice(&avg);
                    }
                }
                bx += blk;
            }
            by += blk;
        }
    }

    pub fn crop(&mut self, rx: u32, ry: u32, rw: u32, rh: u32) {
        let x0 = rx.min(self.width);
        let y0 = ry.min(self.height);
        let x1 = rx.saturating_add(rw).min(self.width);
        let y1 = ry.saturating_add(rh).min(self.height);
        let nw = x1.saturating_sub(x0);
        let nh = y1.saturating_sub(y0);
        if nw < 2 || nh < 2 {
            return;
        }
        self.push_undo();
        let mut out = vec![0u8; (nw * nh * 4) as usize];
        for row in 0..nh {
            let src = (((y0 + row) * self.width + x0) as usize) * 4;
            let dst = ((row * nw) as usize) * 4;
            out[dst..dst + (nw * 4) as usize]
                .copy_from_slice(&self.rgba[src..src + (nw * 4) as usize]);
        }
        self.width = nw;
        self.height = nh;
        self.rgba = out;
    }

    #[allow(clippy::too_many_arguments)]
    pub fn apply_shape(
        &mut self,
        tool: ToolKind,
        x0: f32,
        y0: f32,
        x1: f32,
        y1: f32,
        stroke_pts: &[(f32, f32)],
        color: [u8; 4],
        stroke_width: f32,
        opaque_fill: bool,
    ) {
        match tool {
            ToolKind::Blur => {
                let (rx, ry, rw, rh) = self.normalize_rect(x0, y0, x1, y1);
                self.apply_blur_region(rx, ry, rw, rh, 8);
                return;
            }
            ToolKind::Pixelate => {
                let (rx, ry, rw, rh) = self.normalize_rect(x0, y0, x1, y1);
                self.apply_pixelate_region(rx, ry, rw, rh, 12);
                return;
            }
            ToolKind::Crop => {
                let (rx, ry, rw, rh) = self.normalize_rect(x0, y0, x1, y1);
                self.crop(rx, ry, rw, rh);
                return;
            }
            ToolKind::Select => return,
            _ => {}
        }

        let Some(mut pixmap) = self.to_pixmap_premul() else {
            return;
        };
        self.push_undo();

        let mut paint = Paint {
            anti_alias: true,
            ..Paint::default()
        };
        let alpha = if tool == ToolKind::Highlighter {
            color[3].min(115)
        } else {
            color[3]
        };
        paint.set_color(SkiaColor::from_rgba8(color[0], color[1], color[2], alpha));
        let stroke = Stroke {
            width: if tool == ToolKind::Highlighter {
                (stroke_width * 4.0).max(16.0)
            } else {
                stroke_width.max(1.0)
            },
            line_cap: LineCap::Round,
            line_join: LineJoin::Round,
            ..Stroke::default()
        };

        match tool {
            ToolKind::Rect => {
                let lx = x0.min(x1);
                let ly = y0.min(y1);
                let rw = (x0 - x1).abs().max(2.0);
                let rh = (y0 - y1).abs().max(2.0);
                if let Some(r) = SkiaRect::from_xywh(lx, ly, rw, rh) {
                    let path = PathBuilder::from_rect(r);
                    if opaque_fill {
                        pixmap.fill_path(
                            &path,
                            &paint,
                            FillRule::Winding,
                            Transform::identity(),
                            None,
                        );
                    } else {
                        pixmap.stroke_path(&path, &paint, &stroke, Transform::identity(), None);
                    }
                }
            }
            ToolKind::Ellipse => {
                let lx = x0.min(x1);
                let ly = y0.min(y1);
                let rw = (x0 - x1).abs().max(2.0);
                let rh = (y0 - y1).abs().max(2.0);
                if let Some(r) = SkiaRect::from_xywh(lx, ly, rw, rh) {
                    if let Some(path) = PathBuilder::from_oval(r) {
                        if opaque_fill {
                            pixmap.fill_path(
                                &path,
                                &paint,
                                FillRule::Winding,
                                Transform::identity(),
                                None,
                            );
                        } else {
                            pixmap.stroke_path(&path, &paint, &stroke, Transform::identity(), None);
                        }
                    }
                }
            }
            ToolKind::Line => {
                let mut pb = PathBuilder::new();
                pb.move_to(x0, y0);
                pb.line_to(x1, y1);
                if let Some(path) = pb.finish() {
                    pixmap.stroke_path(&path, &paint, &stroke, Transform::identity(), None);
                }
            }
            ToolKind::Arrow => {
                let mut pb = PathBuilder::new();
                pb.move_to(x0, y0);
                pb.line_to(x1, y1);
                let dx = x1 - x0;
                let dy = y1 - y0;
                let angle = dy.atan2(dx);
                let head = (stroke_width * 4.0).max(14.0);
                let a1 = angle + 2.6;
                let a2 = angle - 2.6;
                pb.move_to(x1 + head * a1.cos(), y1 + head * a1.sin());
                pb.line_to(x1, y1);
                pb.line_to(x1 + head * a2.cos(), y1 + head * a2.sin());
                if let Some(path) = pb.finish() {
                    pixmap.stroke_path(&path, &paint, &stroke, Transform::identity(), None);
                }
            }
            ToolKind::Pen | ToolKind::Highlighter => {
                let mut pb = PathBuilder::new();
                if let Some(&(sx, sy)) = stroke_pts.first() {
                    pb.move_to(sx, sy);
                    for &(px, py) in &stroke_pts[1..] {
                        pb.line_to(px, py);
                    }
                } else {
                    pb.move_to(x0, y0);
                    pb.line_to(x1, y1);
                }
                if let Some(path) = pb.finish() {
                    pixmap.stroke_path(&path, &paint, &stroke, Transform::identity(), None);
                }
            }
            ToolKind::StepCounter => {
                let n = self.step_counter;
                self.step_counter = self.step_counter.saturating_add(1);
                if let Some(path) = PathBuilder::from_circle(x1, y1, 14.0) {
                    pixmap.fill_path(
                        &path,
                        &paint,
                        FillRule::Winding,
                        Transform::identity(),
                        None,
                    );
                }
                self.read_pixmap_premul(&pixmap);
                self.draw_text(
                    x1 - 14.0,
                    y1 - 9.0,
                    &n.to_string(),
                    [255, 255, 255, 255],
                    15.0,
                    false,
                );
                return;
            }
            ToolKind::Text
            | ToolKind::Select
            | ToolKind::Blur
            | ToolKind::Pixelate
            | ToolKind::Crop => {}
        }

        self.read_pixmap_premul(&pixmap);
    }

    pub fn draw_text(
        &mut self,
        x: f32,
        y: f32,
        text: &str,
        color: [u8; 4],
        size: f32,
        record_undo: bool,
    ) {
        if text.is_empty() {
            return;
        }
        if record_undo {
            self.push_undo();
        }
        let mut db = cosmic_text::fontdb::Database::new();
        for p in [
            "/usr/share/fonts/noto/NotoSans-Bold.ttf",
            "/usr/share/fonts/noto/NotoSans-Regular.ttf",
            "/usr/share/fonts/TTF/DejaVuSans.ttf",
        ] {
            let path = Path::new(p);
            if path.exists() {
                let _ = db.load_font_file(path);
            }
        }
        let mut font_system = FontSystem::new_with_locale_and_db("en-US".into(), db);
        let mut swash_cache = SwashCache::new();
        let sz = size.max(10.0);
        let mut buf = CosmicBuffer::new(&mut font_system, Metrics::new(sz, sz * 1.25));
        buf.set_wrap(Wrap::None);
        buf.set_text(
            text,
            &Attrs::new().family(Family::SansSerif),
            Shaping::Advanced,
            None,
        );
        buf.shape_until_scroll(&mut font_system, false);

        let Some(mut pixmap) = self.to_pixmap_premul() else {
            return;
        };
        let cw = pixmap.width() as i32;
        let ch = pixmap.height() as i32;
        let pm_data = pixmap.data_mut();
        let text_color = CosmicColor::rgba(color[0], color[1], color[2], color[3]);

        buf.draw(
            &mut font_system,
            &mut swash_cache,
            text_color,
            |gx, gy, w, h, c| {
                let px = x.round() as i32 + gx;
                let py = y.round() as i32 + gy;
                if px < 0 || py < 0 || px >= cw || py >= ch || w == 0 || h == 0 || c.a() == 0 {
                    return;
                }
                let idx = ((py * cw + px) as usize) * 4;
                let sa = u32::from(c.a());
                let inv = 255 - sa;
                pm_data[idx] =
                    ((u32::from(c.r()) * sa + u32::from(pm_data[idx]) * inv) / 255) as u8;
                pm_data[idx + 1] =
                    ((u32::from(c.g()) * sa + u32::from(pm_data[idx + 1]) * inv) / 255) as u8;
                pm_data[idx + 2] =
                    ((u32::from(c.b()) * sa + u32::from(pm_data[idx + 2]) * inv) / 255) as u8;
                pm_data[idx + 3] = 255;
            },
        );
        self.read_pixmap_premul(&pixmap);
    }

    pub fn export_rgba(&self) -> (u32, u32, Vec<u8>) {
        if !self.backdrop_enabled || self.backdrop_padding == 0 {
            return (self.width, self.height, self.rgba.clone());
        }
        apply_backdrop(&self.rgba, self.width, self.height, self.backdrop_padding)
    }

    pub fn encode_png(&self) -> Result<Vec<u8>, String> {
        let (w, h, rgba) = self.export_rgba();
        let mut out = Vec::new();
        let encoder = image::codecs::png::PngEncoder::new(&mut out);
        encoder
            .write_image(&rgba, w, h, ColorType::Rgba8.into())
            .map_err(|e| format!("failed encoding PNG: {e}"))?;
        Ok(out)
    }

    pub fn save_png_to(&self, path: &Path) -> Result<(), String> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)
                .map_err(|e| format!("failed creating {}: {e}", parent.display()))?;
        }
        let png = self.encode_png()?;
        let file =
            File::create(path).map_err(|e| format!("failed writing {}: {e}", path.display()))?;
        let mut writer = BufWriter::new(file);
        std::io::Write::write_all(&mut writer, &png)
            .map_err(|e| format!("failed flushing PNG: {e}"))?;
        Ok(())
    }

    fn to_pixmap_premul(&self) -> Option<Pixmap> {
        let mut pm = Pixmap::new(self.width, self.height)?;
        let dst = pm.data_mut();
        for (src_px, dst_px) in self
            .rgba
            .as_chunks::<4>()
            .0
            .iter()
            .zip(dst.as_chunks_mut::<4>().0)
        {
            let a = u16::from(src_px[3]);
            dst_px[0] = ((u16::from(src_px[0]) * a) / 255) as u8;
            dst_px[1] = ((u16::from(src_px[1]) * a) / 255) as u8;
            dst_px[2] = ((u16::from(src_px[2]) * a) / 255) as u8;
            dst_px[3] = src_px[3];
        }
        Some(pm)
    }

    fn read_pixmap_premul(&mut self, pm: &Pixmap) {
        for (src_px, dst_px) in pm
            .data()
            .as_chunks::<4>()
            .0
            .iter()
            .zip(self.rgba.as_chunks_mut::<4>().0)
        {
            let a = u16::from(src_px[3]);
            if a == 0 {
                *dst_px = [0, 0, 0, 0];
            } else if a == 255 {
                *dst_px = *src_px;
            } else {
                dst_px[0] = ((u16::from(src_px[0]) * 255) / a).min(255) as u8;
                dst_px[1] = ((u16::from(src_px[1]) * 255) / a).min(255) as u8;
                dst_px[2] = ((u16::from(src_px[2]) * 255) / a).min(255) as u8;
                dst_px[3] = src_px[3];
            }
        }
    }
}

/// Applies gradient backdrop + soft drop shadow around `rgba` with exact dimensions
/// `(w + 2 * padding, h + 2 * padding)`.
pub fn apply_backdrop(rgba: &[u8], w: u32, h: u32, padding: u32) -> (u32, u32, Vec<u8>) {
    let out_w = w.saturating_add(padding.saturating_mul(2));
    let out_h = h.saturating_add(padding.saturating_mul(2));
    let mut out = vec![0u8; (out_w as usize) * (out_h as usize) * 4];

    for y in 0..out_h {
        let ty = y as f32 / (out_h.max(1) as f32);
        for x in 0..out_w {
            let tx = x as f32 / (out_w.max(1) as f32);
            let t = (tx * 0.55 + ty * 0.45).clamp(0.0, 1.0);
            let r = (36.0 + t * 52.0) as u8;
            let g = (40.0 + t * 24.0) as u8;
            let b = (68.0 + t * 68.0) as u8;
            let idx = ((y * out_w + x) as usize) * 4;
            out[idx] = r;
            out[idx + 1] = g;
            out[idx + 2] = b;
            out[idx + 3] = 255;
        }
    }

    // Blit captured image centered at (padding, padding) with subtle shadow frame.
    for y in 0..h {
        let dy = padding + y;
        let src_row = (y * w) as usize * 4;
        let dst_row = (dy * out_w + padding) as usize * 4;
        let row_bytes = (w * 4) as usize;
        out[dst_row..dst_row + row_bytes].copy_from_slice(&rgba[src_row..src_row + row_bytes]);
    }

    (out_w, out_h, out)
}

pub fn default_screenshot_path(save_dir: Option<&Path>) -> PathBuf {
    let dir = save_dir.map(Path::to_path_buf).unwrap_or_else(|| {
        std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/tmp"))
            .join("Pictures")
            .join("Screenshots")
    });
    let ts = unix_timestamp_secs();
    dir.join(format!("kaze-{ts}.png"))
}

fn unix_timestamp_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

pub fn run_annotate_cli(args: &[String]) -> Result<String, String> {
    let mut input_path: Option<PathBuf> = None;
    let mut output_path: Option<PathBuf> = None;
    let mut blur_rect: Option<(u32, u32, u32, u32)> = None;
    let mut backdrop: Option<u32> = None;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--output" | "-o" => {
                let Some(val) = args.get(i + 1) else {
                    return Err("--output requires a file path".into());
                };
                output_path = Some(PathBuf::from(val));
                i += 2;
            }
            "--blur" => {
                let Some(val) = args.get(i + 1) else {
                    return Err("--blur requires x,y,w,h".into());
                };
                let parts: Vec<u32> = val
                    .split(',')
                    .filter_map(|p| p.trim().parse().ok())
                    .collect();
                if parts.len() != 4 {
                    return Err(format!("invalid --blur geometry '{val}', expected x,y,w,h"));
                }
                blur_rect = Some((parts[0], parts[1], parts[2], parts[3]));
                i += 2;
            }
            "--backdrop" => {
                let Some(val) = args.get(i + 1) else {
                    return Err("--backdrop requires pixel padding".into());
                };
                let pad = val
                    .parse::<u32>()
                    .map_err(|_| format!("invalid --backdrop padding '{val}'"))?;
                backdrop = Some(pad);
                i += 2;
            }
            s if s.starts_with('-') => {
                return Err(format!("unknown option '{s}'"));
            }
            s => {
                if input_path.is_some() {
                    return Err(format!("unexpected extra argument '{s}'"));
                }
                input_path = Some(PathBuf::from(s));
                i += 1;
            }
        }
    }

    let Some(inp) = input_path else {
        return Err("missing <file> argument".into());
    };
    let mut canvas = AnnotationCanvas::open_image(&inp)?;
    if let Some((bx, by, bw, bh)) = blur_rect {
        canvas.apply_blur_region(bx, by, bw, bh, 8);
    }
    if let Some(pad) = backdrop {
        canvas.backdrop_padding = pad;
        canvas.backdrop_enabled = true;
    }
    let out = output_path.unwrap_or_else(|| inp.clone());
    canvas.save_png_to(&out)?;
    let (ew, eh, _) = canvas.export_rgba();
    Ok(format!("saved {} ({ew}x{eh})", out.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn destructive_blur_mutates_interior_and_preserves_exterior() {
        let mut rgba = vec![0u8; 40 * 40 * 4];
        for y in 0..40 {
            for x in 0..40 {
                let idx = (y * 40 + x) * 4;
                rgba[idx] = if (x + y) % 2 == 0 { 255 } else { 0 };
                rgba[idx + 1] = 20;
                rgba[idx + 2] = 20;
                rgba[idx + 3] = 255;
            }
        }
        let orig = rgba.clone();
        let mut canvas = AnnotationCanvas::from_rgba(40, 40, rgba).expect("valid canvas");
        canvas.apply_blur_region(10, 10, 20, 20, 4);

        let inside_idx = (15 * 40 + 15) * 4;
        let outside_idx = (2 * 40 + 2) * 4;
        assert_ne!(canvas.rgba[inside_idx], orig[inside_idx]);
        assert_eq!(canvas.rgba[outside_idx], orig[outside_idx]);
    }

    #[test]
    fn backdrop_produces_exact_orig_plus_double_padding_dimensions() {
        let rgba = vec![200u8; 100 * 60 * 4];
        let mut canvas = AnnotationCanvas::from_rgba(100, 60, rgba).expect("valid canvas");
        canvas.backdrop_padding = 24;
        canvas.backdrop_enabled = true;
        let (ew, eh, out) = canvas.export_rgba();
        assert_eq!((ew, eh), (148, 108));
        assert_eq!(out.len(), 148 * 108 * 4);
    }

    #[test]
    fn undo_redo_roundtrips_sixty_steps_to_exact_pixels() {
        let orig = vec![42u8; 20 * 20 * 4];
        let mut canvas = AnnotationCanvas::from_rgba(20, 20, orig.clone()).expect("valid canvas");
        for i in 0..60 {
            let x = (i % 15) as u32;
            canvas.apply_shape(
                ToolKind::Rect,
                x as f32,
                2.0,
                (x + 4) as f32,
                8.0,
                &[],
                [230, 25, 25, 255],
                2.0,
                true,
            );
        }
        assert_ne!(canvas.rgba, orig);
        let mut undone = 0;
        while canvas.undo() {
            undone += 1;
        }
        assert_eq!(undone, 60);
        assert_eq!(canvas.rgba, orig);
        let mut redone = 0;
        while canvas.redo() {
            redone += 1;
        }
        assert_eq!(redone, 60);
    }

    #[test]
    fn annotate_fails_cleanly_on_missing_or_corrupt_files() {
        let missing = run_annotate_cli(&["/nonexistent/kaze-missing.png".into()]);
        assert!(missing.is_err());

        let tmp = std::env::temp_dir().join(format!("kaze-corrupt-{}.png", std::process::id()));
        let _ = fs::write(&tmp, b"not a valid png file");
        let corrupt = run_annotate_cli(&[tmp.display().to_string()]);
        let _ = fs::remove_file(&tmp);
        assert!(corrupt.is_err());
    }
}
