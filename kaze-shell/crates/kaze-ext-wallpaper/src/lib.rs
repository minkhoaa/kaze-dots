#![deny(clippy::unwrap_used)]

use image::imageops::FilterType;
use image::{DynamicImage, ImageReader};
use kaze_core::theme::{PaletteColors, ResolvedPalette, TerminalColors};
use kaze_core::{
    AppState, Color, DirtyFlags, IpcResult, KazeExtension, ShellAction, ShellContext, SurfaceSpec,
    SystemEvent,
};
use std::env;
use std::fs;
use std::path::{Path, PathBuf};

/// Wallpaper & Dynamic Palette extension:
/// decodes PNG/JPEG/WebP on a short-lived worker thread (invoked by daemon via
/// `ShellAction::RequestWallpaperLoad`), cover-scales to exact output pixels,
/// extracts a WCAG-compliant Dark/Light palette in `< 5ms` from a 64x64 downscale,
/// and uploads a single-slot SHM frame on `Layer::Background` (excluding `kaze-share`).
pub struct WallpaperExtension {
    loaded_outputs: Vec<String>,
}

impl Default for WallpaperExtension {
    fn default() -> Self {
        Self::new()
    }
}

impl WallpaperExtension {
    pub fn new() -> Self {
        Self {
            loaded_outputs: Vec::new(),
        }
    }

    fn collect_target_outputs(state: &AppState) -> Vec<(String, u32, u32)> {
        state
            .outputs
            .values()
            .filter(|o| o.name != "kaze-share" && o.width > 0 && o.height > 0)
            .map(|o| (o.name.clone(), o.width as u32, o.height as u32))
            .collect()
    }

    fn request_load(&self, path: PathBuf, extract_palette: bool, ctx: &mut ShellContext) {
        let outputs = Self::collect_target_outputs(ctx.state);
        if outputs.is_empty() {
            return;
        }
        ctx.push_action(ShellAction::RequestWallpaperLoad {
            path,
            outputs,
            extract_palette,
        });
    }
}

impl KazeExtension for WallpaperExtension {
    fn id(&self) -> &'static str {
        "wallpaper"
    }

    fn on_init(&mut self, ctx: &mut ShellContext) {
        if !ctx.state.config.wallpaper.enabled {
            return;
        }
        if let Some(path) = ctx.state.config.wallpaper.path.clone() {
            if path.is_file() {
                let extract = ctx.state.config.wallpaper.dynamic_palette;
                self.request_load(path, extract, ctx);
            }
        }
    }

    fn on_event(&mut self, event: &SystemEvent, ctx: &mut ShellContext) -> DirtyFlags {
        match event {
            SystemEvent::OutputAdded(info) => {
                if !ctx.state.config.wallpaper.enabled
                    || info.name == "kaze-share"
                    || info.width <= 0
                    || info.height <= 0
                {
                    return DirtyFlags::NONE;
                }
                let active_path = ctx
                    .state
                    .wallpaper_path
                    .clone()
                    .or_else(|| ctx.state.config.wallpaper.path.clone());
                if let Some(path) = active_path {
                    if path.is_file() {
                        let first_load = self.loaded_outputs.is_empty();
                        ctx.push_action(ShellAction::RequestWallpaperLoad {
                            path,
                            outputs: vec![(
                                info.name.clone(),
                                info.width as u32,
                                info.height as u32,
                            )],
                            extract_palette: first_load
                                && ctx.state.config.wallpaper.dynamic_palette,
                        });
                    }
                }
                DirtyFlags::NONE
            }
            SystemEvent::OutputRemoved { name } => {
                self.loaded_outputs.retain(|o| o != name);
                DirtyFlags::NONE
            }
            SystemEvent::WallpaperReady { buffers, .. } => {
                for (out, _, _, _) in buffers {
                    if !self.loaded_outputs.contains(out) {
                        self.loaded_outputs.push(out.clone());
                    }
                }
                DirtyFlags::WALLPAPER
            }
            _ => DirtyFlags::NONE,
        }
    }

    fn on_ipc(&mut self, cmd: &str, args: &[String], ctx: &mut ShellContext) -> IpcResult {
        match cmd {
            "wallpaper-set" => {
                let Some(raw) = args.first() else {
                    return IpcResult::Handled {
                        ok: false,
                        message: "usage: wallpaper-set <path>".into(),
                        dirty: DirtyFlags::NONE,
                    };
                };
                let path = expand_tilde(raw);
                if !path.is_file() {
                    return IpcResult::Handled {
                        ok: false,
                        message: format!("wallpaper file not found: {}", path.display()),
                        dirty: DirtyFlags::NONE,
                    };
                }
                if let Err(err) = validate_wallpaper_file(&path) {
                    return IpcResult::Handled {
                        ok: false,
                        message: err,
                        dirty: DirtyFlags::NONE,
                    };
                }
                let outputs = Self::collect_target_outputs(ctx.state);
                if outputs.is_empty() {
                    ctx.state.wallpaper_path = Some(path.clone());
                    return IpcResult::Handled {
                        ok: true,
                        message: format!("queued {}", path.display()),
                        dirty: DirtyFlags::NONE,
                    };
                }
                ctx.push_action(ShellAction::RequestWallpaperLoad {
                    path: path.clone(),
                    outputs,
                    extract_palette: ctx.state.config.wallpaper.dynamic_palette,
                });
                IpcResult::Handled {
                    ok: true,
                    message: path.display().to_string(),
                    dirty: DirtyFlags::WALLPAPER,
                }
            }
            "wallpaper-next" => {
                let dir = ctx
                    .state
                    .config
                    .wallpaper
                    .directory
                    .clone()
                    .or_else(default_wallpaper_dir);
                let Some(dir) = dir else {
                    return IpcResult::Handled {
                        ok: false,
                        message: "no wallpaper directory found".into(),
                        dirty: DirtyFlags::NONE,
                    };
                };
                let files = list_wallpapers(&dir);
                if files.is_empty() {
                    return IpcResult::Handled {
                        ok: false,
                        message: format!("no wallpapers in {}", dir.display()),
                        dirty: DirtyFlags::NONE,
                    };
                }
                let next_idx = match ctx.state.wallpaper_path.as_ref() {
                    Some(cur) => files
                        .iter()
                        .position(|p| p == cur)
                        .map(|i| (i + 1) % files.len())
                        .unwrap_or(0),
                    None => 0,
                };
                let next_path = files[next_idx].clone();
                ctx.state.wallpaper_path = Some(next_path.clone());
                self.request_load(
                    next_path.clone(),
                    ctx.state.config.wallpaper.dynamic_palette,
                    ctx,
                );
                IpcResult::Handled {
                    ok: true,
                    message: next_path.display().to_string(),
                    dirty: DirtyFlags::WALLPAPER,
                }
            }
            "wallpaper-clear" => {
                ctx.state.wallpaper_path = None;
                self.loaded_outputs.clear();
                ctx.push_action(ShellAction::ClearWallpaper);
                IpcResult::Handled {
                    ok: true,
                    message: "cleared".into(),
                    dirty: DirtyFlags::WALLPAPER,
                }
            }
            "wallpaper-status" => {
                let msg = ctx
                    .state
                    .wallpaper_path
                    .as_ref()
                    .map(|p| p.display().to_string())
                    .unwrap_or_else(|| "none".to_string());
                IpcResult::Handled {
                    ok: true,
                    message: msg,
                    dirty: DirtyFlags::NONE,
                }
            }
            _ => IpcResult::Unhandled,
        }
    }

    fn surfaces(&self) -> Vec<SurfaceSpec> {
        // Wallpaper surfaces are managed directly via `UiState::set_wallpaper_buffer`
        // to avoid keeping 8 MiB+ RGBA buffers inside `SurfaceSpec` / `PaintCmd` caches.
        Vec::new()
    }
}

pub fn expand_tilde(raw: &str) -> PathBuf {
    if let Some(rest) = raw.strip_prefix("~/") {
        if let Some(home) = env::var_os("HOME") {
            return PathBuf::from(home).join(rest);
        }
    }
    PathBuf::from(raw)
}

/// Fast header/format validation so corrupt or unsupported images are rejected immediately
/// without overwriting the active wallpaper.
pub fn validate_wallpaper_file(path: &Path) -> Result<(), String> {
    if !path.is_file() {
        return Err(format!("wallpaper file not found: {}", path.display()));
    }
    let reader = ImageReader::open(path)
        .map_err(|e| format!("failed opening {}: {e}", path.display()))?
        .with_guessed_format()
        .map_err(|e| format!("failed inspecting {}: {e}", path.display()))?;
    let (w, h) = reader
        .into_dimensions()
        .map_err(|e| format!("invalid image {}: {e}", path.display()))?;
    if w == 0 || h == 0 {
        return Err(format!("invalid empty image: {}", path.display()));
    }
    Ok(())
}

pub fn default_wallpaper_dir() -> Option<PathBuf> {
    let home = env::var_os("HOME")?;
    Some(PathBuf::from(home).join("Pictures").join("Wallpapers"))
}

pub fn list_wallpapers(dir: &Path) -> Vec<PathBuf> {
    let Ok(entries) = fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut files: Vec<PathBuf> = entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| {
            p.is_file()
                && p.extension()
                    .and_then(|e| e.to_str())
                    .map(|e| e.to_ascii_lowercase())
                    .is_some_and(|e| matches!(e.as_str(), "png" | "jpg" | "jpeg" | "webp"))
        })
        .collect();
    files.sort();
    files
}

pub type WallpaperFrame = (String, u32, u32, Vec<u8>);

/// Decodes a wallpaper image once, scales cover-fit BGRA8888 frames for each target output,
/// and optionally extracts a WCAG-compliant Dark/Light `ResolvedPalette` in `< 5ms`.
pub fn load_wallpaper_job(
    path: &Path,
    outputs: &[(String, u32, u32)],
    extract_palette: bool,
) -> Result<(Option<ResolvedPalette>, Vec<WallpaperFrame>), String> {
    let img = image::open(path).map_err(|e| format!("failed decoding {}: {e}", path.display()))?;
    let palette = if extract_palette {
        let name = path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("Wallpaper");
        Some(extract_dynamic_palette(&img, name))
    } else {
        None
    };

    let mut buffers = Vec::with_capacity(outputs.len());
    for (out_name, target_w, target_h) in outputs {
        if *target_w == 0 || *target_h == 0 || out_name == "kaze-share" {
            continue;
        }
        let bgra = cover_scale_to_bgra(&img, *target_w, *target_h);
        buffers.push((out_name.clone(), *target_w, *target_h, bgra));
    }
    Ok((palette, buffers))
}

/// Center-crops and scales `img` to cover `(target_w, target_h)` exactly, outputting
/// little-endian `ARGB8888` (`[B, G, R, A]` premultiplied opaque) bytes for `wl_shm`.
pub fn cover_scale_to_bgra(img: &DynamicImage, target_w: u32, target_h: u32) -> Vec<u8> {
    let (src_w, src_h) = (img.width().max(1), img.height().max(1));
    let src_ratio = f64::from(src_w) / f64::from(src_h);
    let dst_ratio = f64::from(target_w) / f64::from(target_h);

    let cropped = if (src_ratio - dst_ratio).abs() < 0.002 {
        img.resize_exact(target_w, target_h, FilterType::Triangle)
    } else if src_ratio > dst_ratio {
        let crop_w = ((f64::from(src_h) * dst_ratio).round() as u32).clamp(1, src_w);
        let x0 = (src_w - crop_w) / 2;
        img.crop_imm(x0, 0, crop_w, src_h)
            .resize_exact(target_w, target_h, FilterType::Triangle)
    } else {
        let crop_h = ((f64::from(src_w) / dst_ratio).round() as u32).clamp(1, src_h);
        let y0 = (src_h - crop_h) / 2;
        img.crop_imm(0, y0, src_w, crop_h)
            .resize_exact(target_w, target_h, FilterType::Triangle)
    };

    let rgb = cropped.to_rgb8();
    let mut bgra = Vec::with_capacity((target_w as usize) * (target_h as usize) * 4);
    for px in rgb.pixels() {
        bgra.push(px[2]);
        bgra.push(px[1]);
        bgra.push(px[0]);
        bgra.push(255);
    }
    bgra
}

/// Extracts a balanced, WCAG AA/AAA-compliant Dark & Light `ResolvedPalette` from `img`
/// via 64x64 downscaling + Median-Cut quantization (`< 5ms` pure Rust).
pub fn extract_dynamic_palette(img: &DynamicImage, name: &str) -> ResolvedPalette {
    let small = img.resize_exact(64, 64, FilterType::Nearest).to_rgb8();
    let pixels: Vec<[u8; 3]> = small.pixels().map(|p| [p[0], p[1], p[2]]).collect();
    let clusters = median_cut(&pixels, 8);

    // Pick primary seed: maximize chroma * sqrt(weight), skipping near-gray unless entire image is monochrome.
    let mut ranked: Vec<(f32, f32, f32, usize)> = clusters
        .into_iter()
        .map(|(rgb, count)| {
            let (h, s, l) = rgb_to_hsl(rgb[0], rgb[1], rgb[2]);
            (h, s, l, count)
        })
        .collect();
    ranked.sort_by(|a, b| {
        let score = |c: &(f32, f32, f32, usize)| {
            let l_penalty = 1.0 - (c.2 - 0.52).abs() * 1.1;
            c.1.powf(1.3) * l_penalty.max(0.15) * (c.3 as f32).sqrt()
        };
        score(b)
            .partial_cmp(&score(a))
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    let (primary_h, primary_s) = ranked
        .first()
        .map(|&(h, s, _, _)| (h, s.clamp(0.32, 0.78)))
        .unwrap_or((220.0, 0.52));

    let (secondary_h, secondary_s) = ranked
        .iter()
        .skip(1)
        .find(|&&(h, s, _, _)| hue_distance(h, primary_h) >= 42.0 && s >= 0.22)
        .map(|&(h, s, _, _)| (h, s.clamp(0.30, 0.72)))
        .unwrap_or((
            (primary_h + 110.0) % 360.0,
            (primary_s * 0.88).clamp(0.28, 0.68),
        ));

    let (tertiary_h, tertiary_s) = ranked
        .iter()
        .skip(1)
        .find(|&&(h, s, _, _)| {
            hue_distance(h, primary_h) >= 40.0 && hue_distance(h, secondary_h) >= 40.0 && s >= 0.20
        })
        .map(|&(h, s, _, _)| (h, s.clamp(0.30, 0.72)))
        .unwrap_or((
            (primary_h + 215.0) % 360.0,
            (primary_s * 0.85).clamp(0.28, 0.68),
        ));

    // Dominant hue for subtle tinted surfaces
    let bg_h = ranked
        .iter()
        .max_by_key(|c| c.3)
        .map(|c| c.0)
        .unwrap_or(primary_h);

    let dark = synthesize_mode(
        bg_h,
        primary_h,
        primary_s,
        secondary_h,
        secondary_s,
        tertiary_h,
        tertiary_s,
        true,
    );
    let light = synthesize_mode(
        bg_h,
        primary_h,
        primary_s,
        secondary_h,
        secondary_s,
        tertiary_h,
        tertiary_s,
        false,
    );

    ResolvedPalette {
        name: format!("Dynamic:{name}"),
        dark,
        light,
    }
}

#[allow(clippy::too_many_arguments)]
fn synthesize_mode(
    bg_h: f32,
    p_h: f32,
    p_s: f32,
    s_h: f32,
    s_s: f32,
    t_h: f32,
    t_s: f32,
    is_dark: bool,
) -> PaletteColors {
    let neutral_sat = if is_dark { 0.14 } else { 0.16 };
    let surface = hsl_to_color(bg_h, neutral_sat, if is_dark { 0.11 } else { 0.94 });
    let surface_container = hsl_to_color(bg_h, neutral_sat, if is_dark { 0.16 } else { 0.89 });
    let surface_variant = hsl_to_color(bg_h, neutral_sat, if is_dark { 0.22 } else { 0.83 });
    let outline = hsl_to_color(bg_h, neutral_sat * 0.8, if is_dark { 0.42 } else { 0.56 });
    let outline_variant = hsl_to_color(bg_h, neutral_sat * 0.8, if is_dark { 0.28 } else { 0.74 });

    let on_surface = ensure_contrast_hsl(
        bg_h,
        0.10,
        if is_dark { 0.90 } else { 0.14 },
        surface,
        7.5,
        is_dark,
    );
    let on_surface_variant = ensure_contrast_hsl(
        bg_h,
        0.14,
        if is_dark { 0.70 } else { 0.34 },
        surface,
        4.6,
        is_dark,
    );

    let primary = ensure_contrast_hsl(
        p_h,
        p_s,
        if is_dark { 0.68 } else { 0.40 },
        surface,
        4.6,
        is_dark,
    );
    let secondary = ensure_contrast_hsl(
        s_h,
        s_s,
        if is_dark { 0.66 } else { 0.38 },
        surface,
        4.6,
        is_dark,
    );
    let tertiary = ensure_contrast_hsl(
        t_h,
        t_s,
        if is_dark { 0.70 } else { 0.40 },
        surface,
        4.6,
        is_dark,
    );
    let error = ensure_contrast_hsl(
        355.0,
        0.72,
        if is_dark { 0.64 } else { 0.42 },
        surface,
        4.6,
        is_dark,
    );

    let on_primary = best_ink_for(primary);
    let on_secondary = best_ink_for(secondary);
    let on_tertiary = best_ink_for(tertiary);
    let on_error = best_ink_for(error);

    let term = synthesize_terminal(
        bg_h,
        surface,
        on_surface,
        surface_variant,
        primary,
        secondary,
        tertiary,
        error,
        is_dark,
    );

    PaletteColors {
        primary: primary.to_hex_rgb(),
        on_primary: on_primary.to_hex_rgb(),
        secondary: secondary.to_hex_rgb(),
        on_secondary: on_secondary.to_hex_rgb(),
        tertiary: tertiary.to_hex_rgb(),
        on_tertiary: on_tertiary.to_hex_rgb(),
        error: error.to_hex_rgb(),
        on_error: on_error.to_hex_rgb(),
        surface: surface.to_hex_rgb(),
        on_surface: on_surface.to_hex_rgb(),
        surface_container: surface_container.to_hex_rgb(),
        on_surface_container: on_surface.to_hex_rgb(),
        surface_variant: surface_variant.to_hex_rgb(),
        on_surface_variant: on_surface_variant.to_hex_rgb(),
        outline: outline.to_hex_rgb(),
        outline_variant: outline_variant.to_hex_rgb(),
        terminal: term,
    }
}

#[allow(clippy::too_many_arguments)]
fn synthesize_terminal(
    bg_h: f32,
    surface: Color,
    on_surface: Color,
    surface_variant: Color,
    primary: Color,
    secondary: Color,
    tertiary: Color,
    error: Color,
    is_dark: bool,
) -> TerminalColors {
    let base_l = if is_dark { 0.66 } else { 0.38 };
    let bright_l = if is_dark { 0.76 } else { 0.30 };
    let red = ensure_contrast_hsl(355.0, 0.68, base_l, surface, 4.5, is_dark);
    let green = ensure_contrast_hsl(125.0, 0.50, base_l, surface, 4.5, is_dark);
    let yellow = ensure_contrast_hsl(42.0, 0.64, base_l, surface, 4.5, is_dark);
    let blue = primary;
    let magenta = tertiary;
    let cyan = secondary;
    let bright_red = ensure_contrast_hsl(355.0, 0.78, bright_l, surface, 4.5, is_dark);
    let bright_green = ensure_contrast_hsl(125.0, 0.58, bright_l, surface, 4.5, is_dark);
    let bright_yellow = ensure_contrast_hsl(42.0, 0.72, bright_l, surface, 4.5, is_dark);
    let bright_black = hsl_to_color(bg_h, 0.08, if is_dark { 0.48 } else { 0.52 });

    TerminalColors {
        black: hsl_to_color(bg_h, 0.14, if is_dark { 0.08 } else { 0.14 }).to_hex_rgb(),
        red: red.to_hex_rgb(),
        green: green.to_hex_rgb(),
        yellow: yellow.to_hex_rgb(),
        blue: blue.to_hex_rgb(),
        magenta: magenta.to_hex_rgb(),
        cyan: cyan.to_hex_rgb(),
        white: on_surface.to_hex_rgb(),
        bright_black: bright_black.to_hex_rgb(),
        bright_red: bright_red.to_hex_rgb(),
        bright_green: bright_green.to_hex_rgb(),
        bright_yellow: bright_yellow.to_hex_rgb(),
        bright_blue: blue.to_hex_rgb(),
        bright_magenta: magenta.to_hex_rgb(),
        bright_cyan: cyan.to_hex_rgb(),
        bright_white: on_surface.to_hex_rgb(),
        foreground: on_surface.to_hex_rgb(),
        background: surface.to_hex_rgb(),
        selection_fg: on_surface.to_hex_rgb(),
        selection_bg: surface_variant.to_hex_rgb(),
        cursor: error.to_hex_rgb(),
        cursor_text: surface.to_hex_rgb(),
    }
}

fn median_cut(pixels: &[[u8; 3]], target_buckets: usize) -> Vec<([u8; 3], usize)> {
    if pixels.is_empty() {
        return Vec::new();
    }
    let mut buckets: Vec<Vec<[u8; 3]>> = vec![pixels.to_vec()];
    while buckets.len() < target_buckets {
        let Some((idx, _)) = buckets
            .iter()
            .enumerate()
            .filter(|(_, b)| b.len() > 4)
            .max_by_key(|(_, b)| channel_range(b).1)
        else {
            break;
        };
        let mut bucket = buckets.swap_remove(idx);
        let (chan, span) = channel_range(&bucket);
        if span < 8 {
            buckets.push(bucket);
            break;
        }
        bucket.sort_unstable_by_key(|p| p[chan]);
        let mid = bucket.len() / 2;
        let right = bucket.split_off(mid);
        buckets.push(bucket);
        buckets.push(right);
    }

    buckets
        .into_iter()
        .filter(|b| !b.is_empty())
        .map(|b| {
            let n = b.len() as u64;
            let (mut r, mut g, mut bl) = (0u64, 0u64, 0u64);
            for p in &b {
                r += u64::from(p[0]);
                g += u64::from(p[1]);
                bl += u64::from(p[2]);
            }
            ([(r / n) as u8, (g / n) as u8, (bl / n) as u8], b.len())
        })
        .collect()
}

fn channel_range(bucket: &[[u8; 3]]) -> (usize, u8) {
    let (mut min_v, mut max_v) = ([255u8; 3], [0u8; 3]);
    for p in bucket {
        for c in 0..3 {
            min_v[c] = min_v[c].min(p[c]);
            max_v[c] = max_v[c].max(p[c]);
        }
    }
    let mut best_c = 0usize;
    let mut best_r = 0u8;
    for c in 0..3 {
        let r = max_v[c].saturating_sub(min_v[c]);
        if r > best_r {
            best_r = r;
            best_c = c;
        }
    }
    (best_c, best_r)
}

fn hue_distance(a: f32, b: f32) -> f32 {
    let diff = (a - b).abs() % 360.0;
    if diff > 180.0 {
        360.0 - diff
    } else {
        diff
    }
}

pub fn relative_luminance(c: Color) -> f32 {
    let lin = |ch: u8| {
        let s = f32::from(ch) / 255.0;
        if s <= 0.03928 {
            s / 12.92
        } else {
            ((s + 0.055) / 1.055).powf(2.4)
        }
    };
    0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
}

pub fn contrast_ratio(a: Color, b: Color) -> f32 {
    let l1 = relative_luminance(a);
    let l2 = relative_luminance(b);
    let (hi, lo) = if l1 >= l2 { (l1, l2) } else { (l2, l1) };
    (hi + 0.05) / (lo + 0.05)
}

fn ensure_contrast_hsl(
    h: f32,
    s: f32,
    mut l: f32,
    bg: Color,
    min_ratio: f32,
    lighten: bool,
) -> Color {
    let step = if lighten { 0.025 } else { -0.025 };
    for _ in 0..40 {
        let c = hsl_to_color(h, s, l.clamp(0.04, 0.96));
        if contrast_ratio(c, bg) >= min_ratio {
            return c;
        }
        l += step;
    }
    if lighten {
        Color::rgba(0xf4, 0xf4, 0xf6, 0xff)
    } else {
        Color::rgba(0x10, 0x10, 0x14, 0xff)
    }
}

fn best_ink_for(bg: Color) -> Color {
    let dark = Color::rgba(0x12, 0x12, 0x18, 0xff);
    let light = Color::rgba(0xf6, 0xf6, 0xfa, 0xff);
    if contrast_ratio(dark, bg) >= contrast_ratio(light, bg) {
        dark
    } else {
        light
    }
}

fn rgb_to_hsl(r: u8, g: u8, b: u8) -> (f32, f32, f32) {
    let rf = f32::from(r) / 255.0;
    let gf = f32::from(g) / 255.0;
    let bf = f32::from(b) / 255.0;
    let max = rf.max(gf).max(bf);
    let min = rf.min(gf).min(bf);
    let l = (max + min) * 0.5;
    let d = max - min;
    if d < 1e-5 {
        return (0.0, 0.0, l);
    }
    let s = if l > 0.5 {
        d / (2.0 - max - min)
    } else {
        d / (max + min)
    };
    let mut h = if (max - rf).abs() < 1e-5 {
        (gf - bf) / d + if gf < bf { 6.0 } else { 0.0 }
    } else if (max - gf).abs() < 1e-5 {
        (bf - rf) / d + 2.0
    } else {
        (rf - gf) / d + 4.0
    };
    h *= 60.0;
    (h % 360.0, s, l)
}

fn hsl_to_color(h: f32, s: f32, l: f32) -> Color {
    let h = ((h % 360.0) + 360.0) % 360.0;
    let s = s.clamp(0.0, 1.0);
    let l = l.clamp(0.0, 1.0);
    let c = (1.0 - (2.0 * l - 1.0).abs()) * s;
    let x = c * (1.0 - ((h / 60.0) % 2.0 - 1.0).abs());
    let m = l - c * 0.5;
    let (r1, g1, b1) = match h as u32 {
        0..=59 => (c, x, 0.0),
        60..=119 => (x, c, 0.0),
        120..=179 => (0.0, c, x),
        180..=239 => (0.0, x, c),
        240..=299 => (x, 0.0, c),
        _ => (c, 0.0, x),
    };
    Color::rgba(
        ((r1 + m) * 255.0).round().clamp(0.0, 255.0) as u8,
        ((g1 + m) * 255.0).round().clamp(0.0, 255.0) as u8,
        ((b1 + m) * 255.0).round().clamp(0.0, 255.0) as u8,
        255,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{ImageBuffer, Rgb};
    use kaze_core::{Config, OutputInfo};
    use std::time::Instant;

    fn sample_gradient_image() -> DynamicImage {
        let buf = ImageBuffer::from_fn(256, 144, |x, y| {
            let r = ((x * 255) / 256) as u8;
            let g = ((y * 200) / 144) as u8;
            let b = 180u8.saturating_sub((x / 2) as u8);
            Rgb([r, g, b])
        });
        DynamicImage::ImageRgb8(buf)
    }

    #[test]
    fn dynamic_palette_meets_wcag_contrast_in_dark_and_light_under_budget() {
        let img = sample_gradient_image();
        let t0 = Instant::now();
        let pal = extract_dynamic_palette(&img, "sunset");
        let elapsed_ms = t0.elapsed().as_millis();
        assert!(
            elapsed_ms < 50,
            "palette extraction too slow: {elapsed_ms}ms"
        );

        for (label, colors) in [("dark", &pal.dark), ("light", &pal.light)] {
            let bg = colors.surface_color();
            assert!(
                contrast_ratio(colors.on_surface_color(), bg) >= 7.0,
                "{label} on_surface failed AAA"
            );
            assert!(
                contrast_ratio(colors.on_surface_variant_color(), bg) >= 4.5,
                "{label} on_surface_variant failed AA"
            );
            assert!(
                contrast_ratio(colors.primary_color(), bg) >= 4.5,
                "{label} primary failed AA"
            );
            assert!(
                contrast_ratio(colors.secondary_color(), bg) >= 4.5,
                "{label} secondary failed AA"
            );
            assert!(
                contrast_ratio(colors.error_color(), bg) >= 4.5,
                "{label} error failed AA"
            );
        }
    }

    #[test]
    fn cover_scales_to_exact_bgra_frame_and_excludes_kaze_share() {
        let img = sample_gradient_image();
        let bgra = cover_scale_to_bgra(&img, 320, 180);
        assert_eq!(bgra.len(), 320 * 180 * 4);
        assert_eq!(bgra[3], 255);

        let dir = std::env::temp_dir().join(format!("kaze-wp-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("mkdir");
        let p1 = dir.join("01.png");
        let p2 = dir.join("02.jpg");
        img.save(&p1).expect("save png");
        img.save(&p2).expect("save jpg");

        let mut cfg = Config::default();
        cfg.wallpaper.directory = Some(dir.clone());
        let mut state = AppState::new(cfg);
        state.outputs.insert(
            "Virtual-1".into(),
            OutputInfo {
                name: "Virtual-1".into(),
                width: 1920,
                height: 1080,
                scale: 1,
                ..OutputInfo::default()
            },
        );
        state.outputs.insert(
            "kaze-share".into(),
            OutputInfo {
                name: "kaze-share".into(),
                width: 1920,
                height: 1080,
                scale: 1,
                ..OutputInfo::default()
            },
        );

        let mut ext = WallpaperExtension::new();
        {
            let mut ctx = ShellContext::new(&mut state);
            let res = ext.on_ipc("wallpaper-next", &[], &mut ctx);
            assert!(matches!(res, IpcResult::Handled { ok: true, .. }));
            assert_eq!(
                ctx.actions,
                vec![ShellAction::RequestWallpaperLoad {
                    path: p1.clone(),
                    outputs: vec![("Virtual-1".into(), 1920, 1080)],
                    extract_palette: true,
                }]
            );
        }
        {
            let mut ctx = ShellContext::new(&mut state);
            let res = ext.on_ipc("wallpaper-next", &[], &mut ctx);
            assert!(matches!(res, IpcResult::Handled { ok: true, .. }));
            assert!(matches!(
                ctx.actions.first(),
                Some(ShellAction::RequestWallpaperLoad { path, .. }) if path == &p2
            ));
        }

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn corrupt_wallpaper_returns_error_and_preserves_existing_path() {
        let dir = std::env::temp_dir().join(format!("kaze-wp-corrupt-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("mkdir");
        let good = dir.join("good.png");
        let bad = dir.join("corrupt.png");
        sample_gradient_image().save(&good).expect("save good");
        fs::write(&bad, b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDRbroken").expect("write bad");

        let mut state = AppState::new(Config::default());
        state.wallpaper_path = Some(good.clone());
        let mut ext = WallpaperExtension::new();
        {
            let mut ctx = ShellContext::new(&mut state);
            let res = ext.on_ipc("wallpaper-set", &[bad.display().to_string()], &mut ctx);
            assert!(matches!(res, IpcResult::Handled { ok: false, .. }));
            assert!(ctx.actions.is_empty());
        }
        assert_eq!(state.wallpaper_path.as_ref(), Some(&good));
        let _ = fs::remove_dir_all(&dir);
    }
}
