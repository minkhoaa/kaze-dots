use ab_glyph::{point, Font, FontRef, ScaleFont};
use cosmic_text::{
    fontdb, Align as CosmicAlign, Attrs, Buffer as CosmicBuffer, Family, FontSystem, Metrics,
    Shaping, SwashCache, SwashContent, Weight, Wrap,
};
use kaze_core::{Color, IconKind, PaintCmd, Rect, SurfaceSpec, TextAlign};
use memmap2::Mmap;
use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::path::PathBuf;
use std::process::Command;
use tiny_skia::{
    Color as SkiaColor, FillRule, LineCap, LineJoin, Paint, Path, PathBuilder, Pixmap,
    Rect as SkiaRect, Stroke, Transform,
};

const KAPPA: f32 = 0.552_284_8;

/// Read-only memory-mapped TTF/OTF font: zero eager outline unpacking and shared
/// clean file-backed pages so Nerd Fonts add <1 MiB PSS at T0.
struct MmappedFont {
    mmap: Mmap,
}

impl MmappedFont {
    fn open(path: &PathBuf) -> Option<Self> {
        let file = File::open(path).ok()?;
        // SAFETY: system font files under `/usr/share/fonts` are immutable read-only assets.
        let mmap = unsafe { Mmap::map(&file).ok()? };
        FontRef::try_from_slice(&mmap).ok()?;
        Some(Self { mmap })
    }

    fn as_font_ref(&self) -> Option<FontRef<'_>> {
        FontRef::try_from_slice(&self.mmap).ok()
    }
}

struct CachedGlyph {
    width: usize,
    height: usize,
    offset_x: f32,
    offset_y: f32,
    advance: f32,
    alpha: Vec<u8>,
}

/// Lazily initialized `cosmic-text` engine restricted to an explicit small font list
/// (no full-system font scan) for Vietnamese HarfBuzz shaping and Color Emoji bitmaps.
struct RichTextEngine {
    font_system: FontSystem,
    swash_cache: SwashCache,
}

impl RichTextEngine {
    fn new(font_hint: &str) -> Self {
        let mut db = fontdb::Database::new();
        let mut seen = HashSet::new();

        let queries = [
            "Noto Sans",
            "Noto Sans:weight=bold",
            font_hint,
            "JetBrainsMono Nerd Font",
            "Noto Color Emoji",
        ];

        for query in queries {
            if let Some(path) = resolve_font_path(query) {
                if seen.insert(path.clone()) {
                    let _ = db.load_font_file(&path);
                }
            }
        }

        // Static Arch fallback paths if `fc-match` is unavailable (e.g. minimal sandbox).
        for static_path in [
            "/usr/share/fonts/noto/NotoSans-Regular.ttf",
            "/usr/share/fonts/noto/NotoSans-Bold.ttf",
            "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
            "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Bold.ttf",
            "/usr/share/fonts/noto/NotoColorEmoji.ttf",
            "/usr/share/fonts/TTF/DejaVuSans.ttf",
        ] {
            let p = PathBuf::from(static_path);
            if p.exists() && seen.insert(p.clone()) {
                let _ = db.load_font_file(&p);
            }
        }

        db.set_sans_serif_family("Noto Sans");
        db.set_monospace_family(font_hint);

        Self {
            font_system: FontSystem::new_with_locale_and_db("en-US".to_string(), db),
            swash_cache: SwashCache::new(),
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn draw(
        &mut self,
        pixmap: &mut Pixmap,
        rect: Rect,
        text: &str,
        color: Color,
        px_size: f32,
        bold: bool,
        align: TextAlign,
        max_lines: u8,
        scale: f32,
    ) {
        let rx = rect.x * scale;
        let ry = rect.y * scale;
        let rw = (rect.w * scale).max(1.0);
        let rh = (rect.h * scale).max(1.0);
        let line_height = (px_size * 1.32).max(px_size + 2.0);

        let mut buffer =
            CosmicBuffer::new(&mut self.font_system, Metrics::new(px_size, line_height));
        buffer.set_wrap(Wrap::WordOrGlyph);
        buffer.set_size(Some(rw), Some(rh));

        let mut attrs = Attrs::new().family(Family::SansSerif);
        if bold {
            attrs = attrs.weight(Weight::BOLD);
        }
        let cosmic_align = match align {
            TextAlign::Left => CosmicAlign::Left,
            TextAlign::Center => CosmicAlign::Center,
            TextAlign::Right => CosmicAlign::Right,
        };
        buffer.set_text(text, &attrs, Shaping::Advanced, Some(cosmic_align));
        buffer.shape_until_scroll(&mut self.font_system, false);

        let pm_w = pixmap.width() as i32;
        let pm_h = pixmap.height() as i32;
        let clip_x0 = rx.floor() as i32;
        let clip_y0 = ry.floor() as i32;
        let clip_x1 = (rx + rw).ceil() as i32;
        let clip_y1 = (ry + rh).ceil() as i32;
        let data = pixmap.data_mut();

        let limit = if max_lines == 0 {
            usize::MAX
        } else {
            usize::from(max_lines)
        };

        for (line_idx, run) in buffer.layout_runs().enumerate() {
            if line_idx >= limit {
                break;
            }
            for glyph in run.glyphs.iter() {
                let physical = glyph.physical((rx, ry + run.line_y), 1.0);
                let Some(image) = self
                    .swash_cache
                    .get_image_uncached(&mut self.font_system, physical.cache_key)
                else {
                    continue;
                };

                let gw = image.placement.width as usize;
                let gh = image.placement.height as usize;
                if gw == 0 || gh == 0 {
                    continue;
                }
                let gx = physical.x + image.placement.left;
                let gy = physical.y - image.placement.top;

                match image.content {
                    SwashContent::Mask => {
                        for row in 0..gh {
                            let py = gy + row as i32;
                            if py < 0 || py >= pm_h || py < clip_y0 || py >= clip_y1 {
                                continue;
                            }
                            for col in 0..gw {
                                let px = gx + col as i32;
                                if px < 0 || px >= pm_w || px < clip_x0 || px >= clip_x1 {
                                    continue;
                                }
                                let cov = image.data[row * gw + col];
                                if cov == 0 {
                                    continue;
                                }
                                blend_pixel_premul(data, (py * pm_w + px) as usize * 4, color, cov);
                            }
                        }
                    }
                    SwashContent::Color => {
                        for row in 0..gh {
                            let py = gy + row as i32;
                            if py < 0 || py >= pm_h || py < clip_y0 || py >= clip_y1 {
                                continue;
                            }
                            for col in 0..gw {
                                let px = gx + col as i32;
                                if px < 0 || px >= pm_w || px < clip_x0 || px >= clip_x1 {
                                    continue;
                                }
                                let src_idx = (row * gw + col) * 4;
                                if src_idx + 3 >= image.data.len() {
                                    continue;
                                }
                                let src = Color::rgba(
                                    image.data[src_idx],
                                    image.data[src_idx + 1],
                                    image.data[src_idx + 2],
                                    image.data[src_idx + 3],
                                );
                                if src.a == 0 {
                                    continue;
                                }
                                blend_pixel_premul(
                                    data,
                                    (py * pm_w + px) as usize * 4,
                                    src,
                                    color.a,
                                );
                            }
                        }
                    }
                    SwashContent::SubpixelMask => {
                        for row in 0..gh {
                            let py = gy + row as i32;
                            if py < 0 || py >= pm_h || py < clip_y0 || py >= clip_y1 {
                                continue;
                            }
                            for col in 0..gw {
                                let px = gx + col as i32;
                                if px < 0 || px >= pm_w || px < clip_x0 || px >= clip_x1 {
                                    continue;
                                }
                                let s = (row * gw + col) * 3;
                                if s + 2 >= image.data.len() {
                                    continue;
                                }
                                let cov = ((u16::from(image.data[s])
                                    + u16::from(image.data[s + 1])
                                    + u16::from(image.data[s + 2]))
                                    / 3) as u8;
                                if cov == 0 {
                                    continue;
                                }
                                blend_pixel_premul(data, (py * pm_w + px) as usize * 4, color, cov);
                            }
                        }
                    }
                }
            }
        }
    }
}

pub struct Renderer {
    font_hint: String,
    regular_font: Option<MmappedFont>,
    bold_font: Option<MmappedFont>,
    glyph_cache: HashMap<(bool, char, u16), CachedGlyph>,
    rich_text: Option<RichTextEngine>,
}

impl Renderer {
    pub fn new(font_hint: &str) -> Self {
        let regular_font = load_system_font(font_hint, false);
        let bold_font = load_system_font(font_hint, true);
        Self {
            font_hint: font_hint.to_string(),
            regular_font,
            bold_font,
            glyph_cache: HashMap::new(),
            rich_text: None,
        }
    }

    pub fn has_rich_text_engine(&self) -> bool {
        self.rich_text.is_some()
    }

    pub fn reload_font_if_needed(&mut self, font_hint: &str) {
        if self.font_hint == font_hint {
            return;
        }
        self.font_hint = font_hint.to_string();
        self.regular_font = load_system_font(font_hint, false);
        self.bold_font = load_system_font(font_hint, true);
        self.glyph_cache.clear();
        self.rich_text = None;
    }

    pub fn render_spec(
        &mut self,
        spec: &SurfaceSpec,
        logical_w: u32,
        logical_h: u32,
        scale: i32,
        out_argb8888: &mut [u8],
    ) {
        let s = scale.max(1) as f32;
        let px_w = logical_w.saturating_mul(scale.max(1) as u32);
        let px_h = logical_h.saturating_mul(scale.max(1) as u32);
        let Some(mut pixmap) = Pixmap::new(px_w, px_h) else {
            out_argb8888.fill(0);
            return;
        };

        pixmap.fill(SkiaColor::TRANSPARENT);

        let w = logical_w as f32 * s;
        let h = logical_h as f32 * s;
        let radius = (spec.corner_radius * s).min(w * 0.5).min(h * 0.5);

        // Background frame
        if let Some(bg_path) = rounded_rect_path(0.0, 0.0, w, h, radius) {
            let mut paint = Paint::default();
            paint.set_color(to_skia_color(spec.background));
            paint.anti_alias = radius > 0.0;
            pixmap.fill_path(
                &bg_path,
                &paint,
                FillRule::Winding,
                Transform::identity(),
                None,
            );
        }

        // Border frame (inset by half stroke width so edges stay crisp and unclipped)
        if spec.border_width > 0.0 && spec.border_color.a > 0 {
            let bw = spec.border_width * s;
            let inset = bw * 0.5;
            if w > bw && h > bw {
                if let Some(border_path) =
                    rounded_rect_path(inset, inset, w - bw, h - bw, (radius - inset).max(0.0))
                {
                    let mut paint = Paint::default();
                    paint.set_color(to_skia_color(spec.border_color));
                    paint.anti_alias = radius > 0.0;
                    let stroke = Stroke {
                        width: bw,
                        line_cap: LineCap::Square,
                        line_join: LineJoin::Miter,
                        ..Stroke::default()
                    };
                    pixmap.stroke_path(&border_path, &paint, &stroke, Transform::identity(), None);
                }
            }
        }

        // Extension paint commands
        for cmd in &spec.commands {
            match cmd {
                PaintCmd::RoundedRect {
                    rect,
                    radius,
                    fill,
                    stroke,
                    stroke_width,
                } => {
                    let rx = rect.x * s;
                    let ry = rect.y * s;
                    let rw = rect.w * s;
                    let rh = rect.h * s;
                    let rr = (*radius * s).min(rw * 0.5).min(rh * 0.5);

                    if let Some(fill_col) = fill {
                        if let Some(path) = rounded_rect_path(rx, ry, rw, rh, rr) {
                            let mut paint = Paint::default();
                            paint.set_color(to_skia_color(*fill_col));
                            paint.anti_alias = rr > 0.0;
                            pixmap.fill_path(
                                &path,
                                &paint,
                                FillRule::Winding,
                                Transform::identity(),
                                None,
                            );
                        }
                    }

                    if let Some(stroke_col) = stroke {
                        if *stroke_width > 0.0 {
                            let sw = *stroke_width * s;
                            let inset = sw * 0.5;
                            if rw > sw && rh > sw {
                                if let Some(path) = rounded_rect_path(
                                    rx + inset,
                                    ry + inset,
                                    rw - sw,
                                    rh - sw,
                                    (rr - inset).max(0.0),
                                ) {
                                    let mut paint = Paint::default();
                                    paint.set_color(to_skia_color(*stroke_col));
                                    paint.anti_alias = rr > 0.0;
                                    let st = Stroke {
                                        width: sw,
                                        ..Stroke::default()
                                    };
                                    pixmap.stroke_path(
                                        &path,
                                        &paint,
                                        &st,
                                        Transform::identity(),
                                        None,
                                    );
                                }
                            }
                        }
                    }
                }
                PaintCmd::Circle {
                    cx,
                    cy,
                    radius,
                    fill,
                } => {
                    if let Some(path) = PathBuilder::from_circle(*cx * s, *cy * s, *radius * s) {
                        let mut paint = Paint::default();
                        paint.set_color(to_skia_color(*fill));
                        paint.anti_alias = true;
                        pixmap.fill_path(
                            &path,
                            &paint,
                            FillRule::Winding,
                            Transform::identity(),
                            None,
                        );
                    }
                }
                PaintCmd::MonitorIcon {
                    rect,
                    color,
                    stroke_width,
                } => {
                    draw_icon(
                        &mut pixmap,
                        IconKind::Display,
                        *rect,
                        *color,
                        *stroke_width,
                        None,
                        s,
                    );
                }
                PaintCmd::Icon {
                    rect,
                    kind,
                    color,
                    stroke_width,
                    level,
                } => {
                    draw_icon(&mut pixmap, *kind, *rect, *color, *stroke_width, *level, s);
                }
                PaintCmd::Text {
                    rect,
                    text,
                    color,
                    size,
                    bold,
                    align,
                } => {
                    self.draw_text(
                        &mut pixmap,
                        *rect,
                        text,
                        *color,
                        *size * s,
                        *bold,
                        *align,
                        s,
                    );
                }
                PaintCmd::RichText {
                    rect,
                    text,
                    color,
                    size,
                    bold,
                    align,
                    max_lines,
                } => {
                    let hint = self.font_hint.clone();
                    let engine = self
                        .rich_text
                        .get_or_insert_with(|| RichTextEngine::new(&hint));
                    engine.draw(
                        &mut pixmap,
                        *rect,
                        text,
                        *color,
                        *size * s,
                        *bold,
                        *align,
                        *max_lines,
                        s,
                    );
                }
            }
        }

        // Convert tiny-skia premultiplied RGBA -> Wayland ARGB8888 (little-endian BGRA).
        let src = pixmap.data();
        let len = src.len().min(out_argb8888.len());
        let (dst_chunks, _) = out_argb8888[..len].as_chunks_mut::<4>();
        let (src_chunks, _) = src[..len].as_chunks::<4>();
        for (dst_px, src_px) in dst_chunks.iter_mut().zip(src_chunks.iter()) {
            dst_px[0] = src_px[2];
            dst_px[1] = src_px[1];
            dst_px[2] = src_px[0];
            dst_px[3] = src_px[3];
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn draw_text(
        &mut self,
        pixmap: &mut Pixmap,
        rect: Rect,
        text: &str,
        color: Color,
        px_size: f32,
        bold: bool,
        align: TextAlign,
        scale: f32,
    ) {
        let rx = rect.x * scale;
        let ry = rect.y * scale;
        let rw = rect.w * scale;
        let rh = rect.h * scale;

        let font_available = if bold {
            self.bold_font.is_some() || self.regular_font.is_some()
        } else {
            self.regular_font.is_some()
        };

        if !font_available {
            draw_bitmap_fallback_text(pixmap, Rect::new(rx, ry, rw, rh), text, color, scale);
            return;
        }

        let size_key = (px_size * 4.0).round().clamp(16.0, 2000.0) as u16;
        let mut total_advance = 0.0f32;
        let mut ascent = px_size * 0.78;
        let mut descent = px_size * 0.22;

        if let Some(font) = self.select_font(bold).and_then(MmappedFont::as_font_ref) {
            let scaled = font.as_scaled(px_size);
            ascent = scaled.ascent();
            descent = (-scaled.descent()).max(0.0);
        }

        for ch in text.chars() {
            let key = (bold, ch, size_key);
            if !self.glyph_cache.contains_key(&key) {
                if let Some(cached) = self.rasterize_glyph(bold, ch, px_size) {
                    if self.glyph_cache.len() > 256 {
                        self.glyph_cache.clear();
                    }
                    self.glyph_cache.insert(key, cached);
                }
            }
            if let Some(g) = self.glyph_cache.get(&key) {
                total_advance += g.advance;
            }
        }

        let text_height = (ascent + descent).max(px_size * 0.7);
        let mut pen_x = match align {
            TextAlign::Left => rx,
            TextAlign::Center => rx + (rw - total_advance) * 0.5,
            TextAlign::Right => rx + rw - total_advance,
        };
        let baseline_y = ry + (rh - text_height) * 0.5 + ascent;

        let pm_w = pixmap.width() as i32;
        let pm_h = pixmap.height() as i32;
        let data = pixmap.data_mut();

        for ch in text.chars() {
            let key = (bold, ch, size_key);
            let Some(g) = self.glyph_cache.get(&key) else {
                continue;
            };
            let gx = (pen_x + g.offset_x).round() as i32;
            let gy = (baseline_y + g.offset_y).round() as i32;
            for row in 0..g.height {
                let py = gy + row as i32;
                if py < 0 || py >= pm_h {
                    continue;
                }
                for col in 0..g.width {
                    let px = gx + col as i32;
                    if px < 0 || px >= pm_w {
                        continue;
                    }
                    let cov = g.alpha[row * g.width + col];
                    if cov == 0 {
                        continue;
                    }
                    blend_pixel_premul(data, (py * pm_w + px) as usize * 4, color, cov);
                }
            }
            pen_x += g.advance;
        }
    }

    fn select_font(&self, bold: bool) -> Option<&MmappedFont> {
        if bold {
            self.bold_font.as_ref().or(self.regular_font.as_ref())
        } else {
            self.regular_font.as_ref()
        }
    }

    fn rasterize_glyph(&self, bold: bool, ch: char, px_size: f32) -> Option<CachedGlyph> {
        let font = self.select_font(bold)?.as_font_ref()?;
        let scaled = font.as_scaled(px_size);
        let glyph_id = font.glyph_id(ch);
        let advance = scaled.h_advance(glyph_id);
        let glyph = glyph_id.with_scale_and_position(px_size, point(0.0, 0.0));

        let Some(outlined) = font.outline_glyph(glyph) else {
            return Some(CachedGlyph {
                width: 0,
                height: 0,
                offset_x: 0.0,
                offset_y: 0.0,
                advance,
                alpha: Vec::new(),
            });
        };

        let bounds = outlined.px_bounds();
        let width = bounds.width().ceil().max(0.0) as usize;
        let height = bounds.height().ceil().max(0.0) as usize;
        let mut alpha = vec![0u8; width.saturating_mul(height)];
        outlined.draw(|x, y, cov| {
            let ux = x as usize;
            let uy = y as usize;
            if ux < width && uy < height {
                alpha[uy * width + ux] = (cov.clamp(0.0, 1.0) * 255.0).round() as u8;
            }
        });

        Some(CachedGlyph {
            width,
            height,
            offset_x: bounds.min.x,
            offset_y: bounds.min.y,
            advance,
            alpha,
        })
    }
}

fn blend_pixel_premul(buf: &mut [u8], idx: usize, color: Color, coverage: u8) {
    if idx + 3 >= buf.len() {
        return;
    }
    let sa = ((u32::from(color.a) * u32::from(coverage)) + 127) / 255;
    if sa == 0 {
        return;
    }
    let sr = (u32::from(color.r) * sa + 127) / 255;
    let sg = (u32::from(color.g) * sa + 127) / 255;
    let sb = (u32::from(color.b) * sa + 127) / 255;
    let inv = 255 - sa;

    buf[idx] = (sr + (u32::from(buf[idx]) * inv + 127) / 255).min(255) as u8;
    buf[idx + 1] = (sg + (u32::from(buf[idx + 1]) * inv + 127) / 255).min(255) as u8;
    buf[idx + 2] = (sb + (u32::from(buf[idx + 2]) * inv + 127) / 255).min(255) as u8;
    buf[idx + 3] = (sa + (u32::from(buf[idx + 3]) * inv + 127) / 255).min(255) as u8;
}

fn to_skia_color(c: Color) -> SkiaColor {
    SkiaColor::from_rgba8(c.r, c.g, c.b, c.a)
}

fn rounded_rect_path(x: f32, y: f32, w: f32, h: f32, r: f32) -> Option<Path> {
    if w <= 0.0 || h <= 0.0 {
        return None;
    }
    if r <= 0.01 {
        return SkiaRect::from_xywh(x, y, w, h).map(PathBuilder::from_rect);
    }
    let r = r.min(w * 0.5).min(h * 0.5);
    let k = r * KAPPA;
    let mut pb = PathBuilder::new();
    pb.move_to(x + r, y);
    pb.line_to(x + w - r, y);
    pb.cubic_to(x + w - r + k, y, x + w, y + r - k, x + w, y + r);
    pb.line_to(x + w, y + h - r);
    pb.cubic_to(x + w, y + h - r + k, x + w - r + k, y + h, x + w - r, y + h);
    pb.line_to(x + r, y + h);
    pb.cubic_to(x + r - k, y + h, x, y + h - r + k, x, y + h - r);
    pb.line_to(x, y + r);
    pb.cubic_to(x, y + r - k, x + r - k, y, x + r, y);
    pb.close();
    pb.finish()
}

fn draw_icon(
    pixmap: &mut Pixmap,
    kind: IconKind,
    rect: Rect,
    color: Color,
    stroke_width: f32,
    level: Option<u8>,
    s: f32,
) {
    let x = rect.x * s;
    let y = rect.y * s;
    let w = rect.w * s;
    let h = rect.h * s;
    let sw = (stroke_width * s).max(1.0);

    let mut paint = Paint::default();
    paint.set_color(to_skia_color(color));
    paint.anti_alias = true;

    let round_stroke = Stroke {
        width: sw,
        line_cap: LineCap::Round,
        line_join: LineJoin::Round,
        ..Stroke::default()
    };

    match kind {
        IconKind::Display => {
            let screen_h = (h * 0.72).max(4.0);
            if let Some(screen) = rounded_rect_path(
                x + sw * 0.5,
                y + sw * 0.5,
                (w - sw).max(2.0),
                (screen_h - sw).max(2.0),
                1.2 * s,
            ) {
                pixmap.stroke_path(&screen, &paint, &round_stroke, Transform::identity(), None);
            }
            let cx = x + w * 0.5;
            let base_y = y + h - sw * 0.5;
            let mut pb = PathBuilder::new();
            pb.move_to(cx, y + screen_h);
            pb.line_to(cx, base_y);
            pb.move_to(cx - w * 0.28, base_y);
            pb.line_to(cx + w * 0.28, base_y);
            if let Some(stand) = pb.finish() {
                pixmap.stroke_path(&stand, &paint, &round_stroke, Transform::identity(), None);
            }
        }
        IconKind::Wifi | IconKind::WifiOff => {
            let cx = x + w * 0.5;
            let cy = y + h * 0.82;
            let strength = level.unwrap_or(100);
            if let Some(dot) = PathBuilder::from_circle(cx, cy, (1.4 * s).max(1.2)) {
                pixmap.fill_path(&dot, &paint, FillRule::Winding, Transform::identity(), None);
            }
            let arcs = [(0.28f32, 20u8), (0.50, 55), (0.72, 80)];
            for (frac, threshold) in arcs {
                if kind == IconKind::Wifi && strength < threshold {
                    continue;
                }
                let r = w * frac;
                let mut pb = PathBuilder::new();
                pb.move_to(cx - r * 0.72, cy - r * 0.52);
                pb.quad_to(cx, cy - r * 1.15, cx + r * 0.72, cy - r * 0.52);
                if let Some(p) = pb.finish() {
                    pixmap.stroke_path(&p, &paint, &round_stroke, Transform::identity(), None);
                }
            }
            if kind == IconKind::WifiOff {
                let mut pb = PathBuilder::new();
                pb.move_to(x + sw, y + sw);
                pb.line_to(x + w - sw, y + h - sw);
                if let Some(slash) = pb.finish() {
                    pixmap.stroke_path(&slash, &paint, &round_stroke, Transform::identity(), None);
                }
            }
        }
        IconKind::Ethernet => {
            let mut pb = PathBuilder::new();
            let mid_y = y + h * 0.54;
            pb.move_to(x + w * 0.5, y + h * 0.34);
            pb.line_to(x + w * 0.5, mid_y);
            pb.move_to(x + w * 0.22, mid_y);
            pb.line_to(x + w * 0.78, mid_y);
            pb.move_to(x + w * 0.22, mid_y);
            pb.line_to(x + w * 0.22, y + h * 0.72);
            pb.move_to(x + w * 0.78, mid_y);
            pb.line_to(x + w * 0.78, y + h * 0.72);
            if let Some(lines) = pb.finish() {
                pixmap.stroke_path(&lines, &paint, &round_stroke, Transform::identity(), None);
            }
            for (bx, by) in [
                (x + w * 0.34, y + h * 0.08),
                (x + w * 0.06, y + h * 0.72),
                (x + w * 0.62, y + h * 0.72),
            ] {
                if let Some(box_rect) = SkiaRect::from_xywh(bx, by, w * 0.32, h * 0.26) {
                    pixmap.fill_rect(box_rect, &paint, Transform::identity(), None);
                }
            }
        }
        IconKind::Volume | IconKind::VolumeMuted => {
            let mut pb = PathBuilder::new();
            pb.move_to(x + w * 0.08, y + h * 0.36);
            pb.line_to(x + w * 0.30, y + h * 0.36);
            pb.line_to(x + w * 0.54, y + h * 0.14);
            pb.line_to(x + w * 0.54, y + h * 0.86);
            pb.line_to(x + w * 0.30, y + h * 0.64);
            pb.line_to(x + w * 0.08, y + h * 0.64);
            pb.close();
            if let Some(body) = pb.finish() {
                pixmap.fill_path(
                    &body,
                    &paint,
                    FillRule::Winding,
                    Transform::identity(),
                    None,
                );
            }
            if kind == IconKind::VolumeMuted {
                let mut xp = PathBuilder::new();
                xp.move_to(x + w * 0.68, y + h * 0.32);
                xp.line_to(x + w * 0.94, y + h * 0.68);
                xp.move_to(x + w * 0.94, y + h * 0.32);
                xp.line_to(x + w * 0.68, y + h * 0.68);
                if let Some(cross) = xp.finish() {
                    pixmap.stroke_path(&cross, &paint, &round_stroke, Transform::identity(), None);
                }
            } else {
                let vol = level.unwrap_or(60);
                if vol > 0 {
                    let mut wp = PathBuilder::new();
                    wp.move_to(x + w * 0.68, y + h * 0.34);
                    wp.quad_to(x + w * 0.82, y + h * 0.50, x + w * 0.68, y + h * 0.66);
                    if vol >= 50 {
                        wp.move_to(x + w * 0.80, y + h * 0.20);
                        wp.quad_to(x + w * 1.00, y + h * 0.50, x + w * 0.80, y + h * 0.80);
                    }
                    if let Some(waves) = wp.finish() {
                        pixmap.stroke_path(
                            &waves,
                            &paint,
                            &round_stroke,
                            Transform::identity(),
                            None,
                        );
                    }
                }
            }
        }
        IconKind::MicMuted => {
            if let Some(capsule) =
                rounded_rect_path(x + w * 0.34, y + h * 0.10, w * 0.32, h * 0.48, w * 0.16)
            {
                pixmap.stroke_path(&capsule, &paint, &round_stroke, Transform::identity(), None);
            }
            let mut pb = PathBuilder::new();
            pb.move_to(x + w * 0.22, y + h * 0.48);
            pb.quad_to(x + w * 0.50, y + h * 0.84, x + w * 0.78, y + h * 0.48);
            pb.move_to(x + w * 0.50, y + h * 0.72);
            pb.line_to(x + w * 0.50, y + h * 0.90);
            pb.move_to(x + w * 0.12, y + h * 0.12);
            pb.line_to(x + w * 0.88, y + h * 0.88);
            if let Some(p) = pb.finish() {
                pixmap.stroke_path(&p, &paint, &round_stroke, Transform::identity(), None);
            }
        }
        IconKind::Battery | IconKind::BatteryCharging => {
            let body_w = (w * 0.84).max(4.0);
            let body_h = (h * 0.66).max(4.0);
            let by = y + (h - body_h) * 0.5;
            if let Some(outline) = rounded_rect_path(
                x + sw * 0.5,
                by + sw * 0.5,
                (body_w - sw).max(2.0),
                (body_h - sw).max(2.0),
                1.0 * s,
            ) {
                pixmap.stroke_path(&outline, &paint, &round_stroke, Transform::identity(), None);
            }
            // Battery positive terminal nub
            if let Some(nub) = SkiaRect::from_xywh(
                x + body_w + 0.5 * s,
                by + body_h * 0.26,
                (w - body_w - 0.5 * s).max(1.5 * s),
                body_h * 0.48,
            ) {
                pixmap.fill_rect(nub, &paint, Transform::identity(), None);
            }
            // Inner charge fill
            let pct = f32::from(level.unwrap_or(50).min(100)) / 100.0;
            let pad = sw + 1.0 * s;
            let fill_max_w = (body_w - pad * 2.0).max(0.0);
            let fill_w = (fill_max_w * pct).max(if pct > 0.0 { 1.5 * s } else { 0.0 });
            if fill_w > 0.0 && body_h > pad * 2.0 {
                if let Some(inner) =
                    SkiaRect::from_xywh(x + pad, by + pad, fill_w, body_h - pad * 2.0)
                {
                    pixmap.fill_rect(inner, &paint, Transform::identity(), None);
                }
            }
        }
        IconKind::Brightness => {
            let cx = x + w * 0.5;
            let cy = y + h * 0.5;
            let core_r = w.min(h) * 0.22;
            if let Some(c) = PathBuilder::from_circle(cx, cy, core_r) {
                pixmap.fill_path(&c, &paint, FillRule::Winding, Transform::identity(), None);
            }
            let r_in = w.min(h) * 0.34;
            let r_out = w.min(h) * 0.48;
            let mut pb = PathBuilder::new();
            for i in 0..8 {
                let angle = (i as f32) * std::f32::consts::FRAC_PI_4;
                let (sin_a, cos_a) = angle.sin_cos();
                pb.move_to(cx + cos_a * r_in, cy + sin_a * r_in);
                pb.line_to(cx + cos_a * r_out, cy + sin_a * r_out);
            }
            if let Some(rays) = pb.finish() {
                pixmap.stroke_path(&rays, &paint, &round_stroke, Transform::identity(), None);
            }
        }
        IconKind::Bell | IconKind::BellOff => {
            let mut pb = PathBuilder::new();
            pb.move_to(x + w * 0.22, y + h * 0.68);
            pb.line_to(x + w * 0.22, y + h * 0.42);
            pb.cubic_to(
                x + w * 0.22,
                y + h * 0.14,
                x + w * 0.78,
                y + h * 0.14,
                x + w * 0.78,
                y + h * 0.42,
            );
            pb.line_to(x + w * 0.78, y + h * 0.68);
            pb.line_to(x + w * 0.90, y + h * 0.78);
            pb.line_to(x + w * 0.10, y + h * 0.78);
            pb.close();
            if let Some(bell) = pb.finish() {
                pixmap.stroke_path(&bell, &paint, &round_stroke, Transform::identity(), None);
            }
            if let Some(clapper) =
                PathBuilder::from_circle(x + w * 0.50, y + h * 0.88, (1.4 * s).max(1.2))
            {
                pixmap.fill_path(
                    &clapper,
                    &paint,
                    FillRule::Winding,
                    Transform::identity(),
                    None,
                );
            }
            if kind == IconKind::BellOff {
                let mut slash = PathBuilder::new();
                slash.move_to(x + w * 0.12, y + h * 0.14);
                slash.line_to(x + w * 0.88, y + h * 0.86);
                if let Some(p) = slash.finish() {
                    pixmap.stroke_path(&p, &paint, &round_stroke, Transform::identity(), None);
                }
            }
        }
    }
}

fn resolve_font_path(query: &str) -> Option<PathBuf> {
    let out = Command::new("fc-match")
        .args(["-f", "%{file}", query])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let p = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if p.is_empty() {
        None
    } else {
        Some(PathBuf::from(p))
    }
}

fn load_system_font(hint: &str, bold: bool) -> Option<MmappedFont> {
    let mut candidates: Vec<PathBuf> = Vec::new();
    let query = if bold {
        format!("{hint}:weight=bold")
    } else {
        hint.to_string()
    };
    if let Some(p) = resolve_font_path(&query) {
        candidates.push(p);
    }

    let static_paths = if bold {
        [
            "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Bold.ttf",
            "/usr/share/fonts/TTF/DejaVuSansMono-Bold.ttf",
            "/usr/share/fonts/noto/NotoSansMono-Bold.ttf",
            "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
        ]
    } else {
        [
            "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
            "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
            "/usr/share/fonts/noto/NotoSansMono-Regular.ttf",
            "/usr/share/fonts/TTF/DejaVuSans.ttf",
        ]
    };
    for p in static_paths {
        candidates.push(PathBuf::from(p));
    }

    for path in candidates {
        if let Some(font) = MmappedFont::open(&path) {
            return Some(font);
        }
    }
    None
}

/// Minimal 3x5 pixel fallback font for digits and `:` if no system TTF font exists.
fn draw_bitmap_fallback_text(
    pixmap: &mut Pixmap,
    rect: Rect,
    text: &str,
    color: Color,
    scale: f32,
) {
    let px = (2.0 * scale).max(1.0);
    let char_w = 4.0 * px;
    let total_w = text.len() as f32 * char_w;
    let start_x = rect.x + (rect.w - total_w) * 0.5;
    let start_y = rect.y + (rect.h - 5.0 * px) * 0.5;
    let mut paint = Paint::default();
    paint.set_color(to_skia_color(color));

    for (i, ch) in text.chars().enumerate() {
        let rows: [u8; 5] = match ch {
            '0' => [0b111, 0b101, 0b101, 0b101, 0b111],
            '1' => [0b010, 0b110, 0b010, 0b010, 0b111],
            '2' => [0b111, 0b001, 0b111, 0b100, 0b111],
            '3' => [0b111, 0b001, 0b111, 0b001, 0b111],
            '4' => [0b101, 0b101, 0b111, 0b001, 0b001],
            '5' => [0b111, 0b100, 0b111, 0b001, 0b111],
            '6' => [0b111, 0b100, 0b111, 0b101, 0b111],
            '7' => [0b111, 0b001, 0b010, 0b010, 0b010],
            '8' => [0b111, 0b101, 0b111, 0b101, 0b111],
            '9' => [0b111, 0b101, 0b111, 0b001, 0b111],
            ':' => [0b000, 0b010, 0b000, 0b010, 0b000],
            '%' => [0b101, 0b001, 0b010, 0b100, 0b101],
            _ => [0b111, 0b101, 0b101, 0b101, 0b111],
        };
        for (r, bits) in rows.iter().enumerate() {
            for c in 0..3 {
                if (bits >> (2 - c)) & 1 == 1 {
                    if let Some(rect) = SkiaRect::from_xywh(
                        start_x + i as f32 * char_w + c as f32 * px,
                        start_y + r as f32 * px,
                        px,
                        px,
                    ) {
                        pixmap.fill_rect(rect, &paint, Transform::identity(), None);
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use kaze_core::{Anchor, EdgeInsets, KeyboardMode, Layer};

    fn make_spec(commands: Vec<PaintCmd>) -> SurfaceSpec {
        SurfaceSpec {
            id: "test".into(),
            namespace: "kaze-osd".into(),
            output: None,
            layer: Layer::Overlay,
            keyboard_interactivity: KeyboardMode::None,
            anchor: Anchor::TOP,
            exclusive_zone: 0,
            width: 240,
            height: 60,
            margin: EdgeInsets::default(),
            corner_radius: 0.0,
            background: Color::rgba(0x1f, 0x1f, 0x28, 0xff),
            border_color: Color::rgba(0x36, 0x36, 0x46, 0xff),
            border_width: 2.0,
            commands,
            hit_targets: vec![],
        }
    }

    #[test]
    fn static_text_keeps_cosmic_text_lazy_and_uninitialized() {
        let mut renderer = Renderer::new("JetBrainsMono Nerd Font");
        let spec = make_spec(vec![PaintCmd::Text {
            rect: Rect::new(4.0, 4.0, 232.0, 52.0),
            text: "19:00".into(),
            color: Color::rgba(0xdc, 0xd7, 0xba, 0xff),
            size: 14.0,
            bold: true,
            align: TextAlign::Center,
        }]);
        let mut buf = vec![0u8; 240 * 60 * 4];
        renderer.render_spec(&spec, 240, 60, 1, &mut buf);
        assert!(!renderer.has_rich_text_engine());
    }

    #[test]
    fn rich_text_shapes_vietnamese_and_emoji_lazily() {
        let mut renderer = Renderer::new("JetBrainsMono Nerd Font");
        let spec = make_spec(vec![PaintCmd::RichText {
            rect: Rect::new(8.0, 8.0, 224.0, 44.0),
            text: "󰐕  Thông báo tiếng Việt ệ ơ ư đ 🔔✅".into(),
            color: Color::rgba(0xdc, 0xd7, 0xba, 0xff),
            size: 14.0,
            bold: false,
            align: TextAlign::Left,
            max_lines: 2,
        }]);
        let mut buf = vec![0u8; 240 * 60 * 4];
        renderer.render_spec(&spec, 240, 60, 1, &mut buf);
        assert!(renderer.has_rich_text_engine());
        // Verify foreground text pixels differ from pure background (0x28, 0x1f, 0x1f, 0xff in BGRA).
        let (chunks, _) = buf.as_chunks::<4>();
        let fg_pixels = chunks
            .iter()
            .filter(|px| px[0] != 0x28 || px[1] != 0x1f || px[2] != 0x1f)
            .count();
        assert!(fg_pixels > 50, "expected shaped Vietnamese/Emoji pixels");
    }
}
