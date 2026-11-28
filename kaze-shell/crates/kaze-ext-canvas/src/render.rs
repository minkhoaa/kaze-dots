#![deny(clippy::unwrap_used)]

use image::imageops::FilterType;
use image::ImageReader;
use kaze_core::{
    AppState, CanvasLayer, CanvasWidget, CanvasWidgetKind, Color, IconKind, MediaPlayback,
    PaintCmd, Rect, TextAlign, ThemeMode, CANVAS_MIN_DIM,
};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

const MAX_CACHE_IMAGES: usize = 24;
const MAX_IMAGE_DIM: u32 = 512;

#[derive(Debug, Clone, Copy)]
pub struct CanvasPalette {
    pub primary: Color,
    pub secondary: Color,
    pub surface_0: Color,
    pub surface_1: Color,
    pub fg: Color,
    pub bg: Color,
    pub border: Color,
}

impl CanvasPalette {
    pub fn from_state(state: &AppState) -> Self {
        let p = match state.theme_mode {
            ThemeMode::Dark => &state.palette.dark,
            ThemeMode::Light => &state.palette.light,
        };
        let col = |s: &str, fb: Color| Color::from_hex(s).unwrap_or(fb);
        Self {
            primary: col(&p.primary, Color::rgba(126, 156, 216, 255)),
            secondary: col(&p.secondary, Color::rgba(152, 187, 108, 255)),
            surface_0: col(&p.surface, Color::rgba(31, 31, 40, 255)),
            surface_1: col(&p.surface_container, Color::rgba(42, 42, 55, 255)),
            fg: col(&p.on_surface, Color::rgba(220, 215, 186, 255)),
            bg: col(&p.on_primary, Color::rgba(22, 22, 29, 255)),
            border: col(&p.outline, Color::rgba(84, 84, 109, 255)),
        }
    }
}

type CachedRgba = (u32, u32, Arc<[u8]>);

#[derive(Default)]
pub struct ImageCache {
    entries: HashMap<PathBuf, Option<CachedRgba>>,
}

impl ImageCache {
    pub fn get_or_load(&mut self, path: &Path) -> Option<CachedRgba> {
        if let Some(cached) = self.entries.get(path) {
            return cached.clone();
        }
        if self.entries.len() >= MAX_CACHE_IMAGES {
            self.entries.clear();
        }
        let loaded = load_premultiplied_image(path);
        self.entries.insert(path.to_path_buf(), loaded.clone());
        loaded
    }
}

fn load_premultiplied_image(path: &Path) -> Option<(u32, u32, Arc<[u8]>)> {
    let reader = ImageReader::open(path).ok()?.with_guessed_format().ok()?;
    let decoded = reader.decode().ok()?;
    let resized = if decoded.width() > MAX_IMAGE_DIM || decoded.height() > MAX_IMAGE_DIM {
        decoded.resize(MAX_IMAGE_DIM, MAX_IMAGE_DIM, FilterType::Triangle)
    } else {
        decoded
    };
    let mut rgba = resized.to_rgba8();
    let w = rgba.width();
    let h = rgba.height();
    for px in rgba.as_mut().as_chunks_mut::<4>().0 {
        let a = u16::from(px[3]);
        px[0] = ((u16::from(px[0]) * a) / 255) as u8;
        px[1] = ((u16::from(px[1]) * a) / 255) as u8;
        px[2] = ((u16::from(px[2]) * a) / 255) as u8;
    }
    Some((w, h, Arc::<[u8]>::from(rgba.into_raw())))
}

pub fn render_lockscreen_widgets(
    widgets: &[CanvasWidget],
    state: &AppState,
    monitor_id: &str,
    output_name: &str,
    is_primary: bool,
    cache: &mut ImageCache,
) -> Vec<PaintCmd> {
    let pal = CanvasPalette::from_state(state);
    let mut filtered: Vec<(usize, &CanvasWidget)> = widgets
        .iter()
        .enumerate()
        .filter(|(_, w)| {
            w.layer == CanvasLayer::Lockscreen
                && w.matches_output(monitor_id, output_name, is_primary)
        })
        .collect();
    filtered.sort_by_key(|(idx, w)| (w.z_index, *idx));

    filtered
        .into_iter()
        .map(|(_, w)| render_widget_group(w, state, &pal, cache, false))
        .collect()
}

pub fn render_widget_group(
    widget: &CanvasWidget,
    state: &AppState,
    pal: &CanvasPalette,
    cache: &mut ImageCache,
    selected: bool,
) -> PaintCmd {
    let w = widget.width.max(CANVAS_MIN_DIM);
    let h = widget.height.max(CANVAS_MIN_DIM);
    let local_rect = Rect::new(0.0, 0.0, w, h);
    let mut commands = Vec::new();
    let accent = widget
        .color
        .as_deref()
        .and_then(Color::from_hex)
        .unwrap_or(pal.primary);

    match widget.kind {
        CanvasWidgetKind::Image | CanvasWidgetKind::Sticker => {
            render_media_widget_body(
                &mut commands,
                widget,
                local_rect,
                accent,
                pal,
                cache,
                selected,
            );
        }
        _ => {
            commands.push(PaintCmd::RoundedRect {
                rect: local_rect,
                radius: 16.0,
                fill: Some(Color::rgba(
                    pal.surface_0.r,
                    pal.surface_0.g,
                    pal.surface_0.b,
                    224,
                )),
                stroke: Some(if selected {
                    pal.primary
                } else {
                    Color::rgba(pal.border.r, pal.border.g, pal.border.b, 175)
                }),
                stroke_width: if selected { 2.0 } else { 1.0 },
            });
            render_standard_widget_body(&mut commands, widget, state, local_rect, accent, pal);
        }
    }

    PaintCmd::TransformedGroup {
        rect: Rect::new(widget.x, widget.y, w, h),
        rotation_deg: widget.rotation_deg,
        flip_x: widget.flip_x,
        flip_y: widget.flip_y,
        opacity: widget.opacity.clamp(0.1, 1.0),
        commands,
    }
}

fn render_standard_widget_body(
    commands: &mut Vec<PaintCmd>,
    widget: &CanvasWidget,
    state: &AppState,
    rect: Rect,
    accent: Color,
    pal: &CanvasPalette,
) {
    let w = rect.w;
    let h = rect.h;
    let pad = 12.0;
    let iw = (w - pad * 2.0).max(8.0);
    let muted = Color::rgba(pal.fg.r, pal.fg.g, pal.fg.b, 165);

    match widget.kind {
        CanvasWidgetKind::Clock => {
            let hhmm = state.clock.format_hh_mm();
            commands.push(PaintCmd::TabularText {
                rect: Rect::new(pad, 10.0, iw, (h * 0.56).max(28.0)),
                text: hhmm,
                color: pal.fg,
                size: (h * 0.34).clamp(18.0, 44.0),
                bold: true,
                align: TextAlign::Center,
            });
            let subtitle = if !widget.title.is_empty() {
                widget.title.clone()
            } else {
                format!(
                    "{:02}:{:02}:{:02}",
                    state.clock.hour, state.clock.minute, state.clock.second
                )
            };
            if h >= 68.0 {
                commands.push(PaintCmd::RichText {
                    rect: Rect::new(pad, (h * 0.64).min(h - 24.0), iw, 20.0),
                    text: subtitle,
                    color: accent,
                    size: 12.0,
                    bold: false,
                    align: TextAlign::Center,
                    max_lines: 1,
                });
            }
        }
        CanvasWidgetKind::SystemMonitor => {
            let sm = &state.sysmon;
            commands.push(PaintCmd::Icon {
                rect: Rect::new(pad, 10.0, 16.0, 16.0),
                kind: IconKind::Cpu,
                color: accent,
                stroke_width: 1.6,
                level: None,
            });
            let title = if widget.title.is_empty() {
                "SYSTEM"
            } else {
                widget.title.as_str()
            };
            commands.push(PaintCmd::Text {
                rect: Rect::new(pad + 22.0, 10.0, (iw - 22.0).max(8.0), 16.0),
                text: title.to_string(),
                color: muted,
                size: 10.5,
                bold: true,
                align: TextAlign::Left,
            });
            let cpu_pct = sm.cpu_pct.clamp(0.0, 100.0);
            commands.push(PaintCmd::TabularText {
                rect: Rect::new(pad, 34.0, iw, 22.0),
                text: format!("CPU {cpu_pct:.0}%"),
                color: pal.fg,
                size: 14.0,
                bold: true,
                align: TextAlign::Left,
            });
            let bar_w = (iw * (cpu_pct / 100.0)).round();
            commands.push(PaintCmd::RoundedRect {
                rect: Rect::new(pad, 58.0, iw, 6.0),
                radius: 3.0,
                fill: Some(pal.surface_1),
                stroke: None,
                stroke_width: 0.0,
            });
            if bar_w >= 1.0 {
                commands.push(PaintCmd::RoundedRect {
                    rect: Rect::new(pad, 58.0, bar_w, 6.0),
                    radius: 3.0,
                    fill: Some(accent),
                    stroke: None,
                    stroke_width: 0.0,
                });
            }
            if h >= 92.0 {
                let mem_line = format!("RAM {}/{} MiB", sm.ram_used_mib, sm.ram_total_mib);
                commands.push(PaintCmd::TabularText {
                    rect: Rect::new(pad, 72.0, iw, 18.0),
                    text: mem_line,
                    color: muted,
                    size: 11.0,
                    bold: false,
                    align: TextAlign::Left,
                });
            }
            if h >= 116.0 {
                let net_line = format!(
                    "↓{}K  ↑{}K  {}",
                    sm.net_rx_bps / 1024,
                    sm.net_tx_bps / 1024,
                    sm.temp_c
                        .map_or_else(|| "--".into(), |t| format!("{t:.0}°C"))
                );
                commands.push(PaintCmd::TabularText {
                    rect: Rect::new(pad, 94.0, iw, 18.0),
                    text: net_line,
                    color: muted,
                    size: 10.5,
                    bold: false,
                    align: TextAlign::Left,
                });
            }
        }
        CanvasWidgetKind::MediaPlayer => {
            commands.push(PaintCmd::Icon {
                rect: Rect::new(pad, 12.0, 18.0, 18.0),
                kind: IconKind::Music,
                color: accent,
                stroke_width: 1.6,
                level: None,
            });
            let title = if state.media.active && !state.media.title.is_empty() {
                state.media.title.clone()
            } else {
                "No media playing".to_string()
            };
            commands.push(PaintCmd::RichText {
                rect: Rect::new(pad + 24.0, 10.0, (iw - 24.0).max(8.0), 22.0),
                text: title,
                color: pal.fg,
                size: 12.5,
                bold: true,
                align: TextAlign::Left,
                max_lines: 1,
            });
            if state.media.active && !state.media.artist.is_empty() && h >= 68.0 {
                commands.push(PaintCmd::RichText {
                    rect: Rect::new(pad + 24.0, 32.0, (iw - 24.0).max(8.0), 18.0),
                    text: state.media.artist.clone(),
                    color: muted,
                    size: 11.0,
                    bold: false,
                    align: TextAlign::Left,
                    max_lines: 1,
                });
            }
            if h >= 88.0 {
                let cy = h - 32.0;
                let cx = w * 0.5;
                let play_icon = if matches!(state.media.status, MediaPlayback::Playing) {
                    IconKind::Pause
                } else {
                    IconKind::Play
                };
                commands.push(PaintCmd::Icon {
                    rect: Rect::new(cx - 40.0, cy, 18.0, 18.0),
                    kind: IconKind::Prev,
                    color: pal.fg,
                    stroke_width: 1.6,
                    level: None,
                });
                commands.push(PaintCmd::Icon {
                    rect: Rect::new(cx - 9.0, cy, 18.0, 18.0),
                    kind: play_icon,
                    color: accent,
                    stroke_width: 1.8,
                    level: None,
                });
                commands.push(PaintCmd::Icon {
                    rect: Rect::new(cx + 22.0, cy, 18.0, 18.0),
                    kind: IconKind::Next,
                    color: pal.fg,
                    stroke_width: 1.6,
                    level: None,
                });
            }
        }
        CanvasWidgetKind::Weather => {
            commands.push(PaintCmd::Icon {
                rect: Rect::new(pad, 12.0, 22.0, 22.0),
                kind: IconKind::Weather,
                color: accent,
                stroke_width: 1.6,
                level: None,
            });
            let temp = if state.weather.available {
                format!("{:.0}°C", state.weather.temp_c)
            } else {
                "--°C".to_string()
            };
            commands.push(PaintCmd::TabularText {
                rect: Rect::new(pad + 28.0, 10.0, (iw - 28.0).max(8.0), 28.0),
                text: temp,
                color: pal.fg,
                size: 21.0,
                bold: true,
                align: TextAlign::Left,
            });
            let cond = if state.weather.available {
                format!(
                    "{} • {}",
                    state.weather.condition, state.weather.location_name
                )
            } else if state.weather.offline_blocked {
                "Offline mode".to_string()
            } else {
                "Weather unavailable".to_string()
            };
            if h >= 68.0 {
                commands.push(PaintCmd::RichText {
                    rect: Rect::new(pad, 44.0, iw, 20.0),
                    text: cond,
                    color: muted,
                    size: 11.5,
                    bold: false,
                    align: TextAlign::Left,
                    max_lines: 1,
                });
            }
            if state.weather.available && h >= 92.0 {
                commands.push(PaintCmd::TabularText {
                    rect: Rect::new(pad, 68.0, iw, 18.0),
                    text: format!(
                        "H {}%  W {:.0} km/h",
                        state.weather.humidity_pct, state.weather.wind_kph
                    ),
                    color: muted,
                    size: 10.5,
                    bold: false,
                    align: TextAlign::Left,
                });
            }
        }
        CanvasWidgetKind::CalendarAgenda => {
            commands.push(PaintCmd::Icon {
                rect: Rect::new(pad, 10.0, 16.0, 16.0),
                kind: IconKind::Calendar,
                color: accent,
                stroke_width: 1.6,
                level: None,
            });
            let hdr = if widget.title.is_empty() {
                "AGENDA"
            } else {
                widget.title.as_str()
            };
            commands.push(PaintCmd::Text {
                rect: Rect::new(pad + 22.0, 10.0, (iw - 22.0).max(8.0), 16.0),
                text: hdr.to_string(),
                color: muted,
                size: 10.5,
                bold: true,
                align: TextAlign::Left,
            });
            let mut y = 34.0;
            if state.calendar.events.is_empty() {
                commands.push(PaintCmd::RichText {
                    rect: Rect::new(pad, y, iw, 20.0),
                    text: "No upcoming events".into(),
                    color: muted,
                    size: 11.5,
                    bold: false,
                    align: TextAlign::Left,
                    max_lines: 1,
                });
            } else {
                for ev in state.calendar.events.iter().take(4) {
                    if y + 20.0 > h - 8.0 {
                        break;
                    }
                    let line = if ev.location.is_empty() {
                        format!("• {}", ev.title)
                    } else {
                        format!("• {} ({})", ev.title, ev.location)
                    };
                    commands.push(PaintCmd::RichText {
                        rect: Rect::new(pad, y, iw, 20.0),
                        text: line,
                        color: pal.fg,
                        size: 11.5,
                        bold: false,
                        align: TextAlign::Left,
                        max_lines: 1,
                    });
                    y += 22.0;
                }
            }
        }
        CanvasWidgetKind::TodoNote => {
            let hdr = if widget.title.is_empty() {
                "NOTES"
            } else {
                widget.title.as_str()
            };
            commands.push(PaintCmd::RichText {
                rect: Rect::new(pad, 10.0, iw, 18.0),
                text: hdr.to_string(),
                color: accent,
                size: 11.5,
                bold: true,
                align: TextAlign::Left,
                max_lines: 1,
            });
            let body = if widget.text.trim().is_empty() {
                "- [ ] Add tasks in config"
            } else {
                widget.text.as_str()
            };
            let mut y = 34.0;
            for line in body.lines().take(5) {
                if y + 18.0 > h - 8.0 {
                    break;
                }
                let formatted = if let Some(rest) = line.strip_prefix("- [x] ") {
                    format!("✓ {rest}")
                } else if let Some(rest) = line.strip_prefix("- [ ] ") {
                    format!("○ {rest}")
                } else {
                    line.to_string()
                };
                commands.push(PaintCmd::RichText {
                    rect: Rect::new(pad, y, iw, 18.0),
                    text: formatted,
                    color: pal.fg,
                    size: 11.5,
                    bold: false,
                    align: TextAlign::Left,
                    max_lines: 1,
                });
                y += 20.0;
            }
        }
        CanvasWidgetKind::QuickLaunch => {
            let label = if !widget.title.is_empty() {
                widget.title.clone()
            } else if let Some(ref cmd) = widget.command {
                cmd.clone()
            } else if !widget.text.is_empty() {
                widget.text.clone()
            } else {
                "Launch Terminal".to_string()
            };
            commands.push(PaintCmd::RoundedRect {
                rect: Rect::new(pad, (h - 36.0) * 0.5, 36.0, 36.0),
                radius: 10.0,
                fill: Some(accent),
                stroke: None,
                stroke_width: 0.0,
            });
            commands.push(PaintCmd::Icon {
                rect: Rect::new(pad + 9.0, (h - 18.0) * 0.5, 18.0, 18.0),
                kind: IconKind::Windows,
                color: pal.bg,
                stroke_width: 1.8,
                level: None,
            });
            commands.push(PaintCmd::RichText {
                rect: Rect::new(pad + 46.0, (h - 22.0) * 0.5, (iw - 46.0).max(8.0), 22.0),
                text: label,
                color: pal.fg,
                size: 13.0,
                bold: true,
                align: TextAlign::Left,
                max_lines: 1,
            });
        }
        CanvasWidgetKind::HardwareStatus => {
            commands.push(PaintCmd::Icon {
                rect: Rect::new(pad, 10.0, 16.0, 16.0),
                kind: IconKind::Sliders,
                color: accent,
                stroke_width: 1.6,
                level: None,
            });
            commands.push(PaintCmd::Text {
                rect: Rect::new(pad + 22.0, 10.0, (iw - 22.0).max(8.0), 16.0),
                text: "HARDWARE".into(),
                color: muted,
                size: 10.5,
                bold: true,
                align: TextAlign::Left,
            });
            let bat = if state.battery.present {
                format!("Bat {}%", state.battery.percentage)
            } else {
                "AC Power".to_string()
            };
            let net = if state.network.connected {
                if state.network.ssid.is_empty() {
                    "LAN".to_string()
                } else {
                    state.network.ssid.clone()
                }
            } else {
                "Offline".to_string()
            };
            commands.push(PaintCmd::TabularText {
                rect: Rect::new(pad, 34.0, iw, 20.0),
                text: format!("{bat}  •  Vol {}%", state.audio.volume_pct),
                color: pal.fg,
                size: 12.0,
                bold: true,
                align: TextAlign::Left,
            });
            if h >= 76.0 {
                commands.push(PaintCmd::RichText {
                    rect: Rect::new(pad, 58.0, iw, 18.0),
                    text: format!(
                        "{net}{}{}",
                        if state.nightlight_enabled {
                            "  •  Night"
                        } else {
                            ""
                        },
                        if state.caffeine_enabled {
                            "  •  Caffeine"
                        } else {
                            ""
                        }
                    ),
                    color: muted,
                    size: 11.0,
                    bold: false,
                    align: TextAlign::Left,
                    max_lines: 1,
                });
            }
        }
        CanvasWidgetKind::Image | CanvasWidgetKind::Sticker => {}
    }
}

fn render_media_widget_body(
    commands: &mut Vec<PaintCmd>,
    widget: &CanvasWidget,
    rect: Rect,
    accent: Color,
    pal: &CanvasPalette,
    cache: &mut ImageCache,
    selected: bool,
) {
    let w = rect.w;
    let h = rect.h;
    let path_candidate = widget
        .path
        .as_deref()
        .or_else(|| (!widget.text.trim().is_empty()).then(|| Path::new(widget.text.trim())));

    if widget.kind == CanvasWidgetKind::Image {
        commands.push(PaintCmd::RoundedRect {
            rect,
            radius: 14.0,
            fill: Some(Color::rgba(
                pal.surface_0.r,
                pal.surface_0.g,
                pal.surface_0.b,
                200,
            )),
            stroke: Some(if selected {
                pal.primary
            } else {
                Color::rgba(pal.border.r, pal.border.g, pal.border.b, 140)
            }),
            stroke_width: if selected { 2.0 } else { 1.0 },
        });
        if let Some((iw, ih, rgba)) = path_candidate.and_then(|p| cache.get_or_load(p)) {
            commands.push(PaintCmd::Image {
                rect: Rect::new(4.0, 4.0, (w - 8.0).max(8.0), (h - 8.0).max(8.0)),
                width: iw,
                height: ih,
                rgba_premul: rgba,
            });
        } else {
            let icon_s = (w.min(h) * 0.35).clamp(16.0, 40.0);
            commands.push(PaintCmd::Icon {
                rect: Rect::new((w - icon_s) * 0.5, (h - icon_s) * 0.5, icon_s, icon_s),
                kind: IconKind::Camera,
                color: accent,
                stroke_width: 1.6,
                level: None,
            });
        }
        return;
    }

    let mut rendered_svg = false;
    if widget.text.trim_start().starts_with("<svg") {
        let cmds = parse_svg_sticker(&widget.text, rect, accent);
        if !cmds.is_empty() {
            commands.extend(cmds);
            rendered_svg = true;
        }
    } else if let Some(p) = path_candidate {
        let is_svg = p
            .extension()
            .and_then(|e| e.to_str())
            .is_some_and(|e| e.eq_ignore_ascii_case("svg"));
        if is_svg {
            if let Ok(svg_text) = std::fs::read_to_string(p) {
                let cmds = parse_svg_sticker(&svg_text, rect, accent);
                if !cmds.is_empty() {
                    commands.extend(cmds);
                    rendered_svg = true;
                }
            }
        } else if let Some((iw, ih, rgba)) = cache.get_or_load(p) {
            commands.push(PaintCmd::Image {
                rect,
                width: iw,
                height: ih,
                rgba_premul: rgba,
            });
            rendered_svg = true;
        }
    }

    if !rendered_svg {
        render_builtin_sticker(commands, &widget.text, rect, accent);
    }
    if selected {
        commands.push(PaintCmd::RoundedRect {
            rect,
            radius: 12.0,
            fill: None,
            stroke: Some(pal.primary),
            stroke_width: 2.0,
        });
    }
}

fn render_builtin_sticker(commands: &mut Vec<PaintCmd>, preset: &str, rect: Rect, accent: Color) {
    let cx = rect.x + rect.w * 0.5;
    let cy = rect.y + rect.h * 0.5;
    let r = (rect.w.min(rect.h) * 0.42).max(10.0);
    match preset.trim().to_ascii_lowercase().as_str() {
        "sparkle" | "diamond" => {
            let inner = r * 0.28;
            let pts = vec![
                (cx, cy - r),
                (cx + inner, cy - inner),
                (cx + r, cy),
                (cx + inner, cy + inner),
                (cx, cy + r),
                (cx - inner, cy + inner),
                (cx - r, cy),
                (cx - inner, cy - inner),
            ];
            commands.push(PaintCmd::Polyline {
                points: pts,
                color: accent,
                width: 2.0,
                closed: true,
                fill: Some(accent),
            });
        }
        "moon" => {
            commands.push(PaintCmd::Circle {
                cx,
                cy,
                radius: r * 0.85,
                fill: accent,
            });
            commands.push(PaintCmd::Circle {
                cx: cx + r * 0.35,
                cy: cy - r * 0.2,
                radius: r * 0.72,
                fill: Color::rgba(20, 22, 30, 240),
            });
        }
        "bolt" => {
            let pts = vec![
                (cx + r * 0.12, cy - r),
                (cx - r * 0.48, cy + r * 0.06),
                (cx - r * 0.04, cy + r * 0.06),
                (cx - r * 0.16, cy + r),
                (cx + r * 0.48, cy - r * 0.08),
                (cx + r * 0.04, cy - r * 0.08),
            ];
            commands.push(PaintCmd::Polyline {
                points: pts,
                color: accent,
                width: 2.0,
                closed: true,
                fill: Some(accent),
            });
        }
        _ => {
            let mut pts = Vec::with_capacity(10);
            for i in 0..10 {
                let rad = if i % 2 == 0 { r } else { r * 0.44 };
                let angle =
                    -std::f32::consts::FRAC_PI_2 + (i as f32) * (std::f32::consts::PI / 5.0);
                pts.push((cx + rad * angle.cos(), cy + rad * angle.sin()));
            }
            commands.push(PaintCmd::Polyline {
                points: pts,
                color: accent,
                width: 2.0,
                closed: true,
                fill: Some(accent),
            });
        }
    }
}

/// Lightweight pure-Rust subset SVG parser for stickers (viewBox, rect, circle, line, polygon, polyline, path M/L/H/V/Z).
pub fn parse_svg_sticker(svg: &str, bounds: Rect, fallback_color: Color) -> Vec<PaintCmd> {
    let mut cmds = Vec::new();
    let mut vb = (0.0f32, 0.0f32, 100.0f32, 100.0f32);
    if let Some(vb_raw) = extract_attr(svg, "viewBox") {
        let nums = parse_f32_list(&vb_raw);
        if nums.len() >= 4 && nums[2] > 0.0 && nums[3] > 0.0 {
            vb = (nums[0], nums[1], nums[2], nums[3]);
        }
    }
    let sx = bounds.w / vb.2.max(1.0);
    let sy = bounds.h / vb.3.max(1.0);
    let scale = sx.min(sy);
    let ox = bounds.x + (bounds.w - vb.2 * scale) * 0.5 - vb.0 * scale;
    let oy = bounds.y + (bounds.h - vb.3 * scale) * 0.5 - vb.1 * scale;
    let map_pt = |x: f32, y: f32| -> (f32, f32) { (ox + x * scale, oy + y * scale) };

    for seg in svg.split('<').skip(1) {
        let tag_end = seg
            .find([' ', '\t', '\n', '\r', '>', '/'])
            .unwrap_or(seg.len());
        let tag = &seg[..tag_end];
        let body = seg.split('>').next().unwrap_or(seg);
        let fill = extract_attr(body, "fill").and_then(|s| parse_svg_paint(&s, fallback_color));
        let stroke = extract_attr(body, "stroke").and_then(|s| parse_svg_paint(&s, fallback_color));
        let sw = extract_attr(body, "stroke-width")
            .and_then(|v| v.parse::<f32>().ok())
            .unwrap_or(2.0)
            * scale;

        match tag {
            "circle" => {
                let cx = extract_attr(body, "cx")
                    .and_then(|v| v.parse::<f32>().ok())
                    .unwrap_or(50.0);
                let cy = extract_attr(body, "cy")
                    .and_then(|v| v.parse::<f32>().ok())
                    .unwrap_or(50.0);
                let r = extract_attr(body, "r")
                    .and_then(|v| v.parse::<f32>().ok())
                    .unwrap_or(0.0);
                if r > 0.0 {
                    let (px, py) = map_pt(cx, cy);
                    cmds.push(PaintCmd::Circle {
                        cx: px,
                        cy: py,
                        radius: (r * scale).max(1.0),
                        fill: fill.or(stroke).unwrap_or(fallback_color),
                    });
                }
            }
            "rect" => {
                let x = extract_attr(body, "x")
                    .and_then(|v| v.parse::<f32>().ok())
                    .unwrap_or(0.0);
                let y = extract_attr(body, "y")
                    .and_then(|v| v.parse::<f32>().ok())
                    .unwrap_or(0.0);
                let w = extract_attr(body, "width")
                    .and_then(|v| v.parse::<f32>().ok())
                    .unwrap_or(0.0);
                let h = extract_attr(body, "height")
                    .and_then(|v| v.parse::<f32>().ok())
                    .unwrap_or(0.0);
                let rx = extract_attr(body, "rx")
                    .and_then(|v| v.parse::<f32>().ok())
                    .unwrap_or(0.0);
                if w > 0.0 && h > 0.0 {
                    let (px, py) = map_pt(x, y);
                    cmds.push(PaintCmd::RoundedRect {
                        rect: Rect::new(px, py, w * scale, h * scale),
                        radius: rx * scale,
                        fill: Some(fill.unwrap_or(fallback_color)),
                        stroke,
                        stroke_width: if stroke.is_some() { sw.max(1.0) } else { 0.0 },
                    });
                }
            }
            "line" => {
                let x1 = extract_attr(body, "x1")
                    .and_then(|v| v.parse::<f32>().ok())
                    .unwrap_or(0.0);
                let y1 = extract_attr(body, "y1")
                    .and_then(|v| v.parse::<f32>().ok())
                    .unwrap_or(0.0);
                let x2 = extract_attr(body, "x2")
                    .and_then(|v| v.parse::<f32>().ok())
                    .unwrap_or(0.0);
                let y2 = extract_attr(body, "y2")
                    .and_then(|v| v.parse::<f32>().ok())
                    .unwrap_or(0.0);
                let (px1, py1) = map_pt(x1, y1);
                let (px2, py2) = map_pt(x2, y2);
                cmds.push(PaintCmd::Line {
                    x1: px1,
                    y1: py1,
                    x2: px2,
                    y2: py2,
                    color: stroke.or(fill).unwrap_or(fallback_color),
                    width: sw.max(1.0),
                });
            }
            "polygon" | "polyline" => {
                if let Some(pts_raw) = extract_attr(body, "points") {
                    let nums = parse_f32_list(&pts_raw);
                    let pts: Vec<(f32, f32)> = nums
                        .as_chunks::<2>()
                        .0
                        .iter()
                        .map(|c| map_pt(c[0], c[1]))
                        .collect();
                    if pts.len() >= 2 {
                        let closed = tag == "polygon";
                        cmds.push(PaintCmd::Polyline {
                            points: pts,
                            color: stroke.or(fill).unwrap_or(fallback_color),
                            width: sw.max(1.0),
                            closed,
                            fill: if closed {
                                fill.or(Some(fallback_color))
                            } else {
                                fill
                            },
                        });
                    }
                }
            }
            "path" => {
                if let Some(d_raw) = extract_attr(body, "d") {
                    for (pts, closed) in parse_svg_path(&d_raw) {
                        if pts.len() >= 2 {
                            cmds.push(PaintCmd::Polyline {
                                points: pts.into_iter().map(|(x, y)| map_pt(x, y)).collect(),
                                color: stroke.or(fill).unwrap_or(fallback_color),
                                width: sw.max(1.0),
                                closed,
                                fill: fill.or_else(|| closed.then_some(fallback_color)),
                            });
                        }
                    }
                }
            }
            _ => {}
        }
    }
    cmds
}

fn parse_svg_paint(raw: &str, fallback_color: Color) -> Option<Color> {
    let s = raw.trim();
    if s.eq_ignore_ascii_case("none") || s.is_empty() {
        return None;
    }
    if s.eq_ignore_ascii_case("currentcolor") {
        return Some(fallback_color);
    }
    Color::from_hex(s)
}

fn extract_attr(tag_body: &str, name: &str) -> Option<String> {
    let needle_eq = format!("{name}=");
    let pos = tag_body.find(&needle_eq)?;
    let rest = tag_body[pos + needle_eq.len()..].trim_start();
    let quote = rest.chars().next().filter(|c| *c == '"' || *c == '\'')?;
    let inner = &rest[1..];
    let end = inner.find(quote)?;
    Some(inner[..end].to_string())
}

fn parse_f32_list(raw: &str) -> Vec<f32> {
    raw.replace(',', " ")
        .split_whitespace()
        .filter_map(|t| t.parse::<f32>().ok())
        .collect()
}

fn parse_svg_path(d: &str) -> Vec<(Vec<(f32, f32)>, bool)> {
    let mut subpaths = Vec::new();
    let mut cur_pts: Vec<(f32, f32)> = Vec::new();
    let mut cx = 0.0f32;
    let mut cy = 0.0f32;
    let mut sx = 0.0f32;
    let mut sy = 0.0f32;
    let mut cmd = 'M';

    let spaced = d
        .replace(',', " ")
        .chars()
        .flat_map(|c| {
            if matches!(c, 'M' | 'm' | 'L' | 'l' | 'H' | 'h' | 'V' | 'v' | 'Z' | 'z') {
                vec![' ', c, ' ']
            } else {
                vec![c]
            }
        })
        .collect::<String>();

    let tokens: Vec<&str> = spaced.split_whitespace().collect();
    let mut i = 0usize;
    while i < tokens.len() {
        let tok = tokens[i];
        if tok.len() == 1
            && matches!(
                tok.as_bytes()[0],
                b'M' | b'm' | b'L' | b'l' | b'H' | b'h' | b'V' | b'v' | b'Z' | b'z'
            )
        {
            cmd = tok.chars().next().unwrap_or('M');
            i += 1;
            if matches!(cmd, 'Z' | 'z') {
                if !cur_pts.is_empty() {
                    subpaths.push((std::mem::take(&mut cur_pts), true));
                }
                cx = sx;
                cy = sy;
            }
            continue;
        }
        match cmd {
            'M' | 'm' | 'L' | 'l' => {
                if i + 1 < tokens.len() {
                    if let (Ok(x), Ok(y)) = (tokens[i].parse::<f32>(), tokens[i + 1].parse::<f32>())
                    {
                        let rel = matches!(cmd, 'm' | 'l');
                        let nx = if rel { cx + x } else { x };
                        let ny = if rel { cy + y } else { y };
                        if matches!(cmd, 'M' | 'm') {
                            if !cur_pts.is_empty() {
                                subpaths.push((std::mem::take(&mut cur_pts), false));
                            }
                            sx = nx;
                            sy = ny;
                            cmd = if cmd == 'M' { 'L' } else { 'l' };
                        }
                        cx = nx;
                        cy = ny;
                        cur_pts.push((cx, cy));
                        i += 2;
                        continue;
                    }
                }
                i += 1;
            }
            'H' | 'h' => {
                if let Ok(x) = tok.parse::<f32>() {
                    cx = if cmd == 'h' { cx + x } else { x };
                    cur_pts.push((cx, cy));
                }
                i += 1;
            }
            'V' | 'v' => {
                if let Ok(y) = tok.parse::<f32>() {
                    cy = if cmd == 'v' { cy + y } else { y };
                    cur_pts.push((cx, cy));
                }
                i += 1;
            }
            _ => {
                i += 1;
            }
        }
    }
    if !cur_pts.is_empty() {
        subpaths.push((cur_pts, false));
    }
    subpaths
}
