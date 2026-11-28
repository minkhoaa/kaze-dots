use kaze_core::{
    find_desktop_app_for_class, resolve_keyboard_alias, AppState, Color, DisplayStatus, IconKind,
    NetworkKind, PaintCmd, Rect, WidgetInstanceConfig, WindowGeometry,
};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Clone)]
pub struct ResolvedWidget {
    pub instance_id: String,
    pub kind: String,
    pub cfg: WidgetInstanceConfig,
}

pub fn resolve_widget(state: &AppState, slot_name: &str) -> ResolvedWidget {
    if let Some(cfg) = state.config.widget.get(slot_name) {
        let kind = if cfg.widget_type.trim().is_empty() {
            slot_name.to_string()
        } else {
            cfg.widget_type.trim().to_string()
        };
        ResolvedWidget {
            instance_id: slot_name.to_string(),
            kind,
            cfg: cfg.clone(),
        }
    } else {
        ResolvedWidget {
            instance_id: slot_name.to_string(),
            kind: slot_name.to_string(),
            cfg: WidgetInstanceConfig::default(),
        }
    }
}

pub struct WidgetVisual {
    pub target_id: String,
    #[allow(dead_code)]
    pub instance_id: String,
    #[allow(dead_code)]
    pub kind: String,
    pub icon: Option<IconKind>,
    pub image: Option<(u32, u32, Arc<[u8]>)>,
    pub monogram: Option<String>,
    pub label: Option<String>,
    pub tabular: bool,
    pub icon_color: Color,
    pub text_color: Color,
    pub fill: Color,
    pub stroke: Option<Color>,
    pub level: Option<u8>,
    pub dot: Option<Color>,
    pub dots: Vec<Color>,
    pub badge_count: Option<u32>,
    pub peek: bool,
    pub visualizer: Option<VisualizerKind>,
    pub is_spacer: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VisualizerKind {
    Bars,
    Wave,
    Rings,
}

impl VisualizerKind {
    pub fn from_str(raw: &str) -> Self {
        match raw.trim().to_ascii_lowercase().as_str() {
            "wave" => Self::Wave,
            "rings" => Self::Rings,
            _ => Self::Bars,
        }
    }
}

pub fn build_widget_visuals(
    state: &AppState,
    slot_id: &str,
    output_name: &str,
) -> Vec<WidgetVisual> {
    let resolved = resolve_widget(state, slot_id);
    let colors = state.palette.for_mode(state.theme_mode);
    let primary = colors.primary_color();
    let secondary = colors.secondary_color();
    let tertiary = colors.tertiary_color();
    let error_col = colors.error_color();
    let on_surface = colors.on_surface_color();
    let muted = colors.on_surface_variant_color();
    let surface_container = colors.surface_container_color();
    let surface_variant = colors.surface_variant_color();

    let make_base = |target_id: String, icon: Option<IconKind>| WidgetVisual {
        target_id,
        instance_id: resolved.instance_id.clone(),
        kind: resolved.kind.clone(),
        icon,
        image: None,
        monogram: None,
        label: None,
        tabular: false,
        icon_color: on_surface,
        text_color: on_surface,
        fill: surface_container,
        stroke: None,
        level: None,
        dot: None,
        dots: Vec::new(),
        badge_count: None,
        peek: resolved.cfg.peek,
        visualizer: None,
        is_spacer: false,
    };

    match resolved.kind.as_str() {
        "spacer" => {
            let mut w = make_base(format!("widget:{}", resolved.instance_id), None);
            w.fill = Color::TRANSPARENT;
            w.is_spacer = true;
            vec![w]
        }
        "text" => {
            let mut w = make_base(format!("widget:{}", resolved.instance_id), None);
            w.label = Some(if resolved.cfg.label.is_empty() {
                resolved.cfg.format.clone()
            } else {
                resolved.cfg.label.clone()
            });
            w.fill = Color::TRANSPARENT;
            vec![w]
        }
        "launcher" => {
            let mut w = make_base("launcher".into(), Some(IconKind::Search));
            w.icon_color = primary;
            vec![w]
        }
        "window_switcher_btn" => {
            let mut w = make_base("window_switcher_btn".into(), Some(IconKind::Windows));
            w.icon_color = on_surface;
            vec![w]
        }
        "active_window" => {
            let mut w = make_base("active_window".into(), Some(IconKind::Windows));
            if let Some(win) = state.active_window() {
                let app_label = find_desktop_app_for_class(&state.desktop_apps, &win.class)
                    .map(|a| a.name.clone())
                    .unwrap_or_else(|| win.class.clone());
                let title = if win.title.trim().is_empty() {
                    app_label
                } else {
                    truncate_chars(win.title.trim(), 24)
                };
                w.label = Some(title);
                w.stroke = Some(primary);
            } else {
                w.label = Some("Desktop".into());
                w.text_color = muted;
            }
            vec![w]
        }
        "taskbar" => {
            let active_ws = state.active_workspace_for_output(output_name);
            let wins: Vec<&WindowGeometry> = state
                .windows
                .iter()
                .filter(|win| {
                    if resolved.cfg.group_by_workspace {
                        win.workspace_id == active_ws
                    } else {
                        win.monitor.is_empty() || win.monitor == output_name
                    }
                })
                .take(8)
                .collect();
            wins.into_iter()
                .map(|win| {
                    let ch = win
                        .class
                        .chars()
                        .chain(win.title.chars())
                        .find(|c| c.is_alphanumeric())
                        .unwrap_or('W')
                        .to_ascii_uppercase();
                    let mut w = make_base(format!("taskbar:win:{}", win.address), None);
                    w.monogram = Some(ch.to_string());
                    w.label = Some(truncate_chars(
                        if win.title.is_empty() {
                            &win.class
                        } else {
                            &win.title
                        },
                        12,
                    ));
                    if win.focused {
                        w.fill = surface_variant;
                        w.stroke = Some(primary);
                        w.dot = Some(primary);
                    }
                    w
                })
                .collect()
        }
        "clock" => {
            let mut w = make_base(
                format!("widget:{}", resolved.instance_id),
                Some(IconKind::Clock),
            );
            w.tabular = true;
            w.label = Some(format_clock(
                state,
                &resolved.cfg.timezone,
                &resolved.cfg.format,
            ));
            vec![w]
        }
        "calendar" => {
            let mut w = make_base(
                format!("widget:{}", resolved.instance_id),
                Some(IconKind::Calendar),
            );
            w.tabular = true;
            let now_s = epoch_secs() as i64;
            let next = state
                .calendar
                .events
                .iter()
                .filter(|e| e.start_epoch_secs >= now_s)
                .min_by_key(|e| e.start_epoch_secs);
            w.label = Some(if let Some(ev) = next {
                let mins = ((ev.start_epoch_secs - now_s) / 60).max(0);
                if mins < 60 {
                    format!("{mins}m")
                } else {
                    format!("{}h", mins / 60)
                }
            } else {
                format_ymd_short(now_s)
            });
            vec![w]
        }
        "weather" => {
            let mut w = make_base(
                format!("widget:{}", resolved.instance_id),
                Some(IconKind::Weather),
            );
            w.tabular = true;
            w.label = Some(if state.weather.available {
                format!("{:.0}°", state.weather.temp_c)
            } else if state.offline_mode {
                "--°".into()
            } else {
                "...".into()
            });
            vec![w]
        }
        "sysmon" => {
            let mut w = make_base(
                format!("widget:{}", resolved.instance_id),
                Some(IconKind::Cpu),
            );
            w.tabular = true;
            let metric = resolved.cfg.sysmon_metric.trim().to_ascii_lowercase();
            let text = match metric.as_str() {
                "ram" => {
                    let pct = (state.sysmon.ram_used_mib * 100)
                        .checked_div(state.sysmon.ram_total_mib)
                        .unwrap_or(0)
                        .min(100);
                    format!("R{pct}%")
                }
                "swap" => {
                    let pct = (state.sysmon.swap_used_mib * 100)
                        .checked_div(state.sysmon.swap_total_mib)
                        .unwrap_or(0)
                        .min(100);
                    format!("S{pct}%")
                }
                "temp" => state
                    .sysmon
                    .temp_c
                    .map(|t| format!("{t:.0}°C"))
                    .unwrap_or_else(|| "--°C".into()),
                "net" => format!("{}K", state.sysmon.net_rx_bps / 1024),
                "disk" => state
                    .sysmon
                    .disks
                    .first()
                    .map(|d| format!("{:.0}G", d.used_gib))
                    .unwrap_or_else(|| "0G".into()),
                _ => format!("{:.0}%", state.sysmon.cpu_pct.round()),
            };
            w.label = Some(text);
            vec![w]
        }
        "screen_time" => {
            let mut w = make_base(
                format!("widget:{}", resolved.instance_id),
                Some(IconKind::Clock),
            );
            w.tabular = true;
            let mins = state.screentime.today_total_secs / 60;
            w.label = Some(if mins >= 60 {
                format!("{}h{:02}", mins / 60, mins % 60)
            } else {
                format!("{mins}m")
            });
            vec![w]
        }
        "tray" => state
            .tray_items
            .iter()
            .take(6)
            .enumerate()
            .map(|(idx, item)| {
                let image = item
                    .icon_rgba
                    .as_ref()
                    .filter(|_| item.icon_width > 0 && item.icon_height > 0)
                    .map(|buf| (item.icon_width, item.icon_height, Arc::clone(buf)));
                let monogram = if image.is_none() {
                    let ch = item
                        .title
                        .chars()
                        .chain(item.id.chars())
                        .find(|c| !c.is_whitespace())
                        .unwrap_or('•')
                        .to_ascii_uppercase();
                    Some(ch.to_string())
                } else {
                    None
                };
                let mut w = make_base(format!("tray:item:{idx}"), None);
                w.image = image;
                w.monogram = monogram;
                w
            })
            .collect(),
        "display" => {
            let active = state.display_status.is_active();
            let mut w = make_base("display".into(), Some(IconKind::Display));
            w.icon_color = if active { primary } else { on_surface };
            w.fill = if active {
                surface_variant
            } else {
                surface_container
            };
            w.stroke = if active { Some(primary) } else { None };
            w.dot = match state.display_status {
                DisplayStatus::Idle => None,
                DisplayStatus::Present { .. } | DisplayStatus::VirtualControl { .. } => {
                    Some(primary)
                }
                DisplayStatus::VirtualShare { .. } => Some(secondary),
                DisplayStatus::Recording { .. } => Some(error_col),
            };
            vec![w]
        }
        "net" => {
            let (icon, icon_color, level, lbl) = if !state.network.available
                || !state.network.connected
            {
                (IconKind::WifiOff, muted, None, "OFF".into())
            } else {
                match state.network.kind {
                    NetworkKind::Wifi => (
                        IconKind::Wifi,
                        on_surface,
                        Some(state.network.strength),
                        format!("{}%", state.network.strength),
                    ),
                    NetworkKind::Ethernet => (IconKind::Ethernet, on_surface, None, "ETH".into()),
                    NetworkKind::Disconnected => (IconKind::WifiOff, muted, None, "OFF".into()),
                }
            };
            let mut w = make_base("net".into(), Some(icon));
            w.icon_color = icon_color;
            w.level = level;
            w.label = Some(lbl);
            w.tabular = true;
            vec![w]
        }
        "bluetooth" => {
            if !state.bluetooth.available {
                return Vec::new();
            }
            let mut w = make_base("bluetooth".into(), Some(IconKind::Bluetooth));
            w.icon_color = if state.bluetooth.powered {
                primary
            } else {
                muted
            };
            if !state.bluetooth.connected_device.is_empty() {
                w.dot = Some(secondary);
                w.label = Some(truncate_chars(&state.bluetooth.connected_device, 10));
            }
            vec![w]
        }
        "vol" => {
            let (icon, icon_color, level) = if state.audio.muted || state.audio.volume_pct == 0 {
                (IconKind::VolumeMuted, error_col, Some(0))
            } else {
                (IconKind::Volume, on_surface, Some(state.audio.volume_pct))
            };
            let mut w = make_base("vol".into(), Some(icon));
            w.icon_color = icon_color;
            w.level = level;
            w.tabular = true;
            w.label = Some(if state.audio.muted {
                "MUTE".into()
            } else {
                format!("{}%", state.audio.volume_pct)
            });
            w.dot = if state.audio.mic_muted {
                Some(tertiary)
            } else {
                None
            };
            vec![w]
        }
        "mic" => {
            let mut w = make_base("mic".into(), Some(IconKind::MicMuted));
            w.icon_color = if state.audio.mic_muted {
                error_col
            } else {
                secondary
            };
            w.label = Some(if state.audio.mic_muted { "OFF" } else { "ON" }.into());
            vec![w]
        }
        "brightness" => {
            if !state.backlight.present {
                return Vec::new();
            }
            let mut w = make_base("brightness".into(), Some(IconKind::Brightness));
            w.tabular = true;
            w.label = Some(format!("{}%", state.backlight.percentage));
            vec![w]
        }
        "bat" => {
            if !state.battery.present {
                return Vec::new();
            }
            let (icon, icon_color) = if state.battery.charging {
                (IconKind::BatteryCharging, secondary)
            } else if state.battery.low {
                (IconKind::Battery, error_col)
            } else {
                (IconKind::Battery, on_surface)
            };
            let mut w = make_base("bat".into(), Some(icon));
            w.icon_color = icon_color;
            w.level = Some(state.battery.percentage);
            w.tabular = true;
            w.label = Some(format!("{}%", state.battery.percentage));
            if state.battery.low {
                w.stroke = Some(error_col);
            }
            vec![w]
        }
        "battery_peripherals" => {
            if state.battery.peripherals.is_empty() {
                return Vec::new();
            }
            let min_pct = state
                .battery
                .peripherals
                .iter()
                .map(|p| p.percentage)
                .min()
                .unwrap_or(0);
            let mut w = make_base("battery_peripherals".into(), Some(IconKind::Bluetooth));
            w.tabular = true;
            w.label = Some(format!("{min_pct}%"));
            vec![w]
        }
        "power_profile" => {
            let mut w = make_base("power_profile".into(), Some(IconKind::PowerProfile));
            let short = match state.power_profile.active.as_str() {
                "performance" => "PRF",
                "power-saver" => "SAV",
                "balanced" => "BAL",
                _ => "PWR",
            };
            w.icon_color = if state.power_profile.active == "performance" {
                error_col
            } else if state.power_profile.active == "power-saver" {
                secondary
            } else {
                primary
            };
            w.label = Some(short.into());
            vec![w]
        }
        "keyboard_layout" => {
            let mut w = make_base("keyboard_layout".into(), Some(IconKind::Keyboard));
            let label = resolve_keyboard_alias(
                &state.keyboard.layout_raw,
                &state.config.bar.keyboard_aliases,
            );
            w.label = Some(label);
            vec![w]
        }
        "lock_keys" => {
            let mut w = make_base("lock_keys".into(), Some(IconKind::LockKey));
            let active =
                state.keyboard.caps_lock || state.keyboard.num_lock || state.keyboard.scroll_lock;
            let mut tags = Vec::new();
            if state.keyboard.caps_lock {
                tags.push("C");
            }
            if state.keyboard.num_lock {
                tags.push("N");
            }
            if state.keyboard.scroll_lock {
                tags.push("S");
            }
            w.label = Some(if tags.is_empty() {
                "LK".into()
            } else {
                tags.join("")
            });
            if active {
                w.fill = surface_variant;
                w.stroke = Some(primary);
                w.icon_color = primary;
            } else {
                w.icon_color = muted;
            }
            vec![w]
        }
        "media" => {
            if !state.media.active {
                return Vec::new();
            }
            let mut w = make_base("media".into(), Some(IconKind::Music));
            w.icon_color = primary;
            let title = if state.media.title.trim().is_empty() {
                "Playing"
            } else {
                state.media.title.trim()
            };
            w.label = Some(truncate_chars(title, 18));
            vec![w]
        }
        "audio_visualizer" => {
            let mut w = make_base(format!("widget:{}", resolved.instance_id), None);
            w.visualizer = Some(VisualizerKind::from_str(&resolved.cfg.visualizer_style));
            vec![w]
        }
        "notifications" => {
            let (icon, icon_color, fill, stroke, dot) = if state.dnd {
                (
                    IconKind::BellOff,
                    tertiary,
                    surface_variant,
                    Some(tertiary),
                    None,
                )
            } else {
                let badge = (state.unread_notifications > 0).then_some(primary);
                (IconKind::Bell, on_surface, surface_container, None, badge)
            };
            let mut w = make_base("notifications".into(), Some(icon));
            w.icon_color = icon_color;
            w.fill = fill;
            w.stroke = stroke;
            w.dot = dot;
            if state.unread_notifications > 0 && !state.dnd {
                w.badge_count = Some(state.unread_notifications);
            }
            vec![w]
        }
        "privacy" => {
            let mut dots = Vec::new();
            if !state.privacy.mic_apps.is_empty() {
                dots.push(tertiary);
            }
            if !state.privacy.camera_apps.is_empty() {
                dots.push(secondary);
            }
            if !state.privacy.screenshare_apps.is_empty() {
                dots.push(error_col);
            }
            if dots.is_empty() {
                return Vec::new();
            }
            let mut w = make_base("privacy".into(), Some(IconKind::Shield));
            w.dots = dots;
            w.icon_color = error_col;
            w.fill = surface_variant;
            vec![w]
        }
        "caffeine" => {
            let mut w = make_base("caffeine".into(), Some(IconKind::Caffeine));
            if state.caffeine_enabled {
                w.fill = surface_variant;
                w.stroke = Some(secondary);
                w.icon_color = secondary;
            }
            vec![w]
        }
        "night_light" => {
            let mut w = make_base("night_light".into(), Some(IconKind::NightLight));
            if state.nightlight_enabled {
                w.fill = surface_variant;
                w.stroke = Some(tertiary);
                w.icon_color = tertiary;
            }
            vec![w]
        }
        "screenshot" => {
            vec![make_base("screenshot".into(), Some(IconKind::Camera))]
        }
        "color_picker" => {
            vec![make_base(
                "color_picker".into(),
                Some(IconKind::ColorPicker),
            )]
        }
        "clipboard" => {
            vec![make_base("clipboard".into(), Some(IconKind::Clipboard))]
        }
        "record" => {
            let active = state.record_activity.as_ref().is_some_and(|r| r.active);
            let mut w = make_base("record".into(), Some(IconKind::Record));
            if active {
                w.icon_color = error_col;
                w.stroke = Some(error_col);
                w.dot = Some(error_col);
            }
            vec![w]
        }
        "session" => {
            let mut w = make_base("session".into(), Some(IconKind::PowerOff));
            w.icon_color = error_col;
            vec![w]
        }
        "custom_button" => {
            let mut w = make_base(
                format!("custom:{}", resolved.instance_id),
                parse_icon_kind(&resolved.cfg.icon),
            );
            let dynamic = state
                .widget_exec_outputs
                .get(&resolved.instance_id)
                .filter(|s| !s.is_empty())
                .cloned();
            let text = dynamic
                .or_else(|| (!resolved.cfg.label.is_empty()).then(|| resolved.cfg.label.clone()));
            w.label = text;
            if w.icon.is_none() && w.label.is_none() {
                w.monogram = Some(
                    resolved
                        .instance_id
                        .chars()
                        .next()
                        .unwrap_or('B')
                        .to_ascii_uppercase()
                        .to_string(),
                );
            }
            vec![w]
        }
        "cc" => {
            let active = state.cc_open || state.caffeine_enabled || state.nightlight_enabled;
            let dot = if state.caffeine_enabled {
                Some(secondary)
            } else if state.nightlight_enabled {
                Some(tertiary)
            } else {
                None
            };
            let mut w = make_base("cc".into(), Some(IconKind::Sliders));
            w.icon_color = if state.cc_open { primary } else { on_surface };
            w.fill = if active {
                surface_variant
            } else {
                surface_container
            };
            w.stroke = if state.cc_open { Some(primary) } else { None };
            w.dot = dot;
            vec![w]
        }
        _ => Vec::new(),
    }
}

pub fn render_visualizer(
    commands: &mut Vec<PaintCmd>,
    rect: Rect,
    kind: VisualizerKind,
    spectrum: &[u8],
    primary: Color,
    secondary: Color,
) {
    if spectrum.is_empty() {
        commands.push(PaintCmd::Line {
            x1: rect.x + 4.0,
            y1: rect.y + rect.h * 0.5,
            x2: rect.x + rect.w - 4.0,
            y2: rect.y + rect.h * 0.5,
            color: primary.with_opacity(0.45),
            width: 1.5,
        });
        return;
    }
    match kind {
        VisualizerKind::Bars => {
            let n = spectrum.len().clamp(4, 16);
            let pad = 3.0;
            let gap = 1.5;
            let avail_w = (rect.w - pad * 2.0).max(4.0);
            let bar_w = ((avail_w - gap * (n as f32 - 1.0)) / n as f32).max(1.5);
            for (i, &val) in spectrum.iter().take(n).enumerate() {
                let frac = f32::from(val) / 255.0;
                let bh = (rect.h * 0.72 * frac).max(2.0);
                let bx = rect.x + pad + i as f32 * (bar_w + gap);
                let by = rect.y + rect.h - pad - bh;
                commands.push(PaintCmd::RoundedRect {
                    rect: Rect::new(bx, by, bar_w, bh),
                    radius: 0.75,
                    fill: Some(if i % 2 == 0 { primary } else { secondary }),
                    stroke: None,
                    stroke_width: 0.0,
                });
            }
        }
        VisualizerKind::Wave => {
            let n = spectrum.len().clamp(4, 20);
            let mut pts = Vec::with_capacity(n);
            let cy = rect.y + rect.h * 0.5;
            for (i, &val) in spectrum.iter().take(n).enumerate() {
                let frac = (f32::from(val) / 255.0) - 0.5;
                let px = rect.x + 3.0 + (i as f32 / (n - 1).max(1) as f32) * (rect.w - 6.0);
                let py = cy - frac * rect.h * 0.75;
                pts.push((px, py));
            }
            commands.push(PaintCmd::Polyline {
                points: pts,
                color: primary,
                width: 1.8,
                closed: false,
                fill: None,
            });
        }
        VisualizerKind::Rings => {
            let avg = spectrum.iter().map(|&v| f32::from(v)).sum::<f32>()
                / (spectrum.len().max(1) as f32 * 255.0);
            let cx = rect.x + rect.w * 0.5;
            let cy = rect.y + rect.h * 0.5;
            let max_r = (rect.w.min(rect.h) * 0.44).max(3.0);
            for (idx, mult) in [0.45f32, 0.72, 1.0].iter().enumerate() {
                let r = (max_r * mult * (0.45 + avg * 0.55)).max(2.0);
                commands.push(PaintCmd::Arc {
                    cx,
                    cy,
                    radius: r,
                    start_deg: 0.0,
                    sweep_deg: 360.0,
                    color: if idx % 2 == 0 { primary } else { secondary },
                    width: 1.6,
                });
            }
        }
    }
}

fn parse_icon_kind(raw: &str) -> Option<IconKind> {
    match raw.trim().to_ascii_lowercase().as_str() {
        "calendar" => Some(IconKind::Calendar),
        "weather" => Some(IconKind::Weather),
        "cpu" => Some(IconKind::Cpu),
        "clock" => Some(IconKind::Clock),
        "keyboard" => Some(IconKind::Keyboard),
        "camera" | "screenshot" => Some(IconKind::Camera),
        "clipboard" => Some(IconKind::Clipboard),
        "color_picker" => Some(IconKind::ColorPicker),
        "search" | "launcher" => Some(IconKind::Search),
        "windows" => Some(IconKind::Windows),
        "shield" | "privacy" => Some(IconKind::Shield),
        "music" | "media" => Some(IconKind::Music),
        "settings" => Some(IconKind::Settings),
        "display" => Some(IconKind::Display),
        "wifi" => Some(IconKind::Wifi),
        "vol" | "volume" => Some(IconKind::Volume),
        "bt" | "bluetooth" => Some(IconKind::Bluetooth),
        "power" => Some(IconKind::PowerOff),
        "" => None,
        _ => Some(IconKind::Sliders),
    }
}

fn truncate_chars(s: &str, max_chars: usize) -> String {
    let count = s.chars().count();
    if count <= max_chars {
        s.to_string()
    } else if max_chars <= 1 {
        "…".to_string()
    } else {
        let mut out: String = s.chars().take(max_chars - 1).collect();
        out.push('…');
        out
    }
}

fn epoch_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn format_clock(state: &AppState, timezone: &str, format: &str) -> String {
    let tz = timezone.trim();
    let (h, m, s) = if tz.eq_ignore_ascii_case("utc") || tz == "+0" || tz == "Z" {
        let secs = epoch_secs();
        let sod = (secs % 86_400) as u32;
        (
            (sod / 3600) as u8,
            ((sod % 3600) / 60) as u8,
            (sod % 60) as u8,
        )
    } else if let Some(offset_mins) = parse_tz_offset_mins(tz) {
        let secs = epoch_secs() as i64 + offset_mins * 60;
        let sod = secs.rem_euclid(86_400) as u32;
        (
            (sod / 3600) as u8,
            ((sod % 3600) / 60) as u8,
            (sod % 60) as u8,
        )
    } else {
        (state.clock.hour, state.clock.minute, state.clock.second)
    };
    if format.contains("%S") {
        format!("{h:02}:{m:02}:{s:02}")
    } else {
        format!("{h:02}:{m:02}")
    }
}

fn parse_tz_offset_mins(raw: &str) -> Option<i64> {
    let s = raw.strip_prefix("UTC").unwrap_or(raw).trim();
    let sign = if s.starts_with('+') {
        1
    } else if s.starts_with('-') {
        -1
    } else {
        return None;
    };
    let rest = &s[1..];
    if let Some((hh, mm)) = rest.split_once(':') {
        let h: i64 = hh.parse().ok()?;
        let m: i64 = mm.parse().ok()?;
        Some(sign * (h * 60 + m))
    } else {
        let h: i64 = rest.parse().ok()?;
        Some(sign * h * 60)
    }
}

fn format_ymd_short(epoch_s: i64) -> String {
    let days = epoch_s.div_euclid(86_400);
    let (y, m, d) = civil_from_days(days);
    let _ = y;
    format!("{m:02}/{d:02}")
}

fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = mp + if mp < 10 { 3 } else { -9 };
    (y + i64::from(m <= 2), m as u32, d as u32)
}
