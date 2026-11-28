use kaze_core::{
    t, AppState, Color, HitTarget, I18nKey, IconKind, MediaPlayback, NetworkKind, PaintCmd, Rect,
    TextAlign, TextInputState,
};

pub const SIDEBAR_FULL_W: f32 = 104.0;
pub const SIDEBAR_COMPACT_W: f32 = 46.0;
pub const SLIDER_TRACK_OFFSET: f32 = 36.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CcTab {
    Home,
    Network,
    Bluetooth,
    Audio,
    Sysmon,
    Weather,
    ScreenTime,
    Calendar,
    Notifications,
}

impl CcTab {
    pub const ALL: &'static [(Self, &'static str, &'static str, IconKind)] = &[
        (Self::Home, "home", "Home", IconKind::Sliders),
        (Self::Network, "network", "Network", IconKind::Wifi),
        (
            Self::Bluetooth,
            "bluetooth",
            "Bluetooth",
            IconKind::Bluetooth,
        ),
        (Self::Audio, "audio", "Audio", IconKind::Volume),
        (Self::Sysmon, "sysmon", "Sysmon", IconKind::Cpu),
        (Self::Weather, "weather", "Weather", IconKind::Weather),
        (Self::ScreenTime, "screentime", "Screen", IconKind::Clock),
        (Self::Calendar, "calendar", "Calendar", IconKind::Calendar),
        (
            Self::Notifications,
            "notifications",
            "Notify",
            IconKind::Bell,
        ),
    ];

    pub fn from_name(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "home" | "" => Some(Self::Home),
            "network" | "wifi" | "net" => Some(Self::Network),
            "bluetooth" | "bt" => Some(Self::Bluetooth),
            "audio" | "sound" | "mixer" => Some(Self::Audio),
            "sysmon" | "stats" | "system" => Some(Self::Sysmon),
            "weather" => Some(Self::Weather),
            "screentime" | "screen_time" | "screen-time" => Some(Self::ScreenTime),
            "calendar" | "cal" => Some(Self::Calendar),
            "notifications" | "notify" | "notif" => Some(Self::Notifications),
            _ => None,
        }
    }

    pub fn id_str(self) -> &'static str {
        match self {
            Self::Home => "home",
            Self::Network => "network",
            Self::Bluetooth => "bluetooth",
            Self::Audio => "audio",
            Self::Sysmon => "sysmon",
            Self::Weather => "weather",
            Self::ScreenTime => "screentime",
            Self::Calendar => "calendar",
            Self::Notifications => "notifications",
        }
    }
}

pub fn sidebar_width(state: &AppState) -> f32 {
    match state
        .config
        .control_center
        .sidebar_mode
        .trim()
        .to_ascii_lowercase()
        .as_str()
    {
        "none" => 0.0,
        "compact" => SIDEBAR_COMPACT_W,
        _ => SIDEBAR_FULL_W,
    }
}

pub fn surface_width(state: &AppState) -> f32 {
    state.config.control_center.width.clamp(368, 900) as f32
}

pub fn slider_bounds(state: &AppState) -> (f32, f32) {
    let sb = sidebar_width(state);
    let total_w = surface_width(state);
    let pad = 14.0f32;
    let content_x = sb + pad;
    let track_x = content_x + SLIDER_TRACK_OFFSET;
    let track_w = (total_w - track_x - pad - 42.0).max(80.0);
    (track_x, track_w)
}

pub struct PaletteTheme {
    pub primary: Color,
    pub on_primary: Color,
    pub secondary: Color,
    pub error: Color,
    pub on_error: Color,
    pub on_surface: Color,
    pub muted: Color,
    pub surface_container: Color,
    pub surface_variant: Color,
    pub outline_variant: Color,
    pub tile_r: f32,
}

impl PaletteTheme {
    pub fn from_state(state: &AppState) -> Self {
        let colors = state.palette.for_mode(state.theme_mode);
        let radius = state
            .config
            .bar
            .corner_radius
            .max(state.layout_preset.overlay_corner_radius());
        let tile_r = if radius > 0.0 {
            (radius * 0.55).min(10.0)
        } else {
            0.0
        };
        Self {
            primary: colors.primary_color(),
            on_primary: colors.on_primary_color(),
            secondary: colors.secondary_color(),
            error: colors.error_color(),
            on_error: colors.color(&colors.on_error, Color::rgba(0xff, 0xff, 0xff, 0xff)),
            on_surface: colors.on_surface_color(),
            muted: colors.on_surface_variant_color(),
            surface_container: colors.surface_container_color(),
            surface_variant: colors.surface_variant_color(),
            outline_variant: colors.outline_variant_color(),
            tile_r,
        }
    }
}

pub fn render_sidebar(
    commands: &mut Vec<PaintCmd>,
    hit_targets: &mut Vec<HitTarget>,
    state: &AppState,
    active_tab: CcTab,
    pal: &PaletteTheme,
    total_h: f32,
) -> f32 {
    let sb_w = sidebar_width(state);
    if sb_w <= 0.0 {
        return 0.0;
    }
    let compact = sb_w < 70.0;
    commands.push(PaintCmd::RoundedRect {
        rect: Rect::new(0.0, 0.0, sb_w, total_h),
        radius: 0.0,
        fill: Some(pal.surface_container.with_opacity(0.65)),
        stroke: None,
        stroke_width: 0.0,
    });
    commands.push(PaintCmd::Line {
        x1: sb_w - 0.5,
        y1: 0.0,
        x2: sb_w - 0.5,
        y2: total_h,
        color: pal.outline_variant,
        width: 1.0,
    });

    let mut y = 12.0f32;
    let btn_h = 30.0f32;
    for &(tab, id, label, icon) in CcTab::ALL {
        let is_sel = tab == active_tab;
        let rect = Rect::new(6.0, y, sb_w - 12.0, btn_h);
        commands.push(PaintCmd::RoundedRect {
            rect,
            radius: pal.tile_r.min(7.0),
            fill: Some(if is_sel {
                pal.primary
            } else {
                Color::TRANSPARENT
            }),
            stroke: None,
            stroke_width: 0.0,
        });
        let fg = if is_sel {
            pal.on_primary
        } else {
            pal.on_surface
        };
        let icon_x = if compact {
            rect.x + (rect.w - 15.0) * 0.5
        } else {
            rect.x + 8.0
        };
        commands.push(PaintCmd::Icon {
            rect: Rect::new(icon_x, y + 7.5, 15.0, 15.0),
            kind: icon,
            color: fg,
            stroke_width: 1.5,
            level: None,
        });
        if !compact {
            commands.push(PaintCmd::Text {
                rect: Rect::new(rect.x + 28.0, y, rect.w - 32.0, btn_h),
                text: label.to_string(),
                color: fg,
                size: 11.0,
                bold: is_sel,
                align: TextAlign::Left,
            });
        }
        hit_targets.push(HitTarget {
            rect,
            id: format!("cc:tab:{id}"),
        });
        y += btn_h + 4.0;
    }
    sb_w
}

struct ToggleTile {
    id: &'static str,
    icon: IconKind,
    title: &'static str,
    subtitle: String,
    active: bool,
}

#[allow(clippy::too_many_arguments)]
pub fn render_home_tab(
    commands: &mut Vec<PaintCmd>,
    hit_targets: &mut Vec<HitTarget>,
    state: &AppState,
    pal: &PaletteTheme,
    pending_power: Option<&str>,
    x0: f32,
    inner_w: f32,
    mut y: f32,
) -> f32 {
    let loc = state.locale;
    let gap = 8.0f32;
    let wifi_sub = if !state.network.available {
        t(loc, I18nKey::StateUnavailable).to_string()
    } else if state.network.connected {
        match state.network.kind {
            NetworkKind::Wifi if !state.network.ssid.is_empty() => state.network.ssid.clone(),
            NetworkKind::Wifi => format!("{}%", state.network.strength),
            NetworkKind::Ethernet => "Ethernet".to_string(),
            NetworkKind::Disconnected => t(loc, I18nKey::StateOff).to_string(),
        }
    } else {
        t(loc, I18nKey::StateOff).to_string()
    };
    let bt_sub = if !state.bluetooth.available {
        t(loc, I18nKey::StateUnavailable).to_string()
    } else if !state.bluetooth.powered {
        t(loc, I18nKey::StateOff).to_string()
    } else if !state.bluetooth.connected_device.is_empty() {
        state.bluetooth.connected_device.clone()
    } else {
        t(loc, I18nKey::StateOn).to_string()
    };

    let tiles = [
        ToggleTile {
            id: "cc:toggle:wifi",
            icon: if state.network.connected {
                if state.network.kind == NetworkKind::Ethernet {
                    IconKind::Ethernet
                } else {
                    IconKind::Wifi
                }
            } else {
                IconKind::WifiOff
            },
            title: t(loc, I18nKey::QuickWifi),
            subtitle: wifi_sub,
            active: state.network.connected,
        },
        ToggleTile {
            id: "cc:toggle:bt",
            icon: IconKind::Bluetooth,
            title: t(loc, I18nKey::QuickBluetooth),
            subtitle: bt_sub,
            active: state.bluetooth.available && state.bluetooth.powered,
        },
        ToggleTile {
            id: "cc:toggle:dnd",
            icon: if state.dnd {
                IconKind::BellOff
            } else {
                IconKind::Bell
            },
            title: t(loc, I18nKey::QuickDnd),
            subtitle: if state.dnd {
                t(loc, I18nKey::StateOn).into()
            } else {
                t(loc, I18nKey::StateOff).into()
            },
            active: state.dnd,
        },
        ToggleTile {
            id: "cc:toggle:nightlight",
            icon: IconKind::NightLight,
            title: t(loc, I18nKey::QuickNightLight),
            subtitle: if state.nightlight_enabled {
                format!("{}K", state.nightlight_temp_k)
            } else {
                t(loc, I18nKey::StateOff).into()
            },
            active: state.nightlight_enabled,
        },
        ToggleTile {
            id: "cc:toggle:caffeine",
            icon: IconKind::Caffeine,
            title: t(loc, I18nKey::QuickCaffeine),
            subtitle: if state.caffeine_enabled {
                t(loc, I18nKey::StateOn).into()
            } else {
                t(loc, I18nKey::StateOff).into()
            },
            active: state.caffeine_enabled,
        },
        ToggleTile {
            id: "cc:toggle:theme",
            icon: IconKind::ThemeMode,
            title: t(loc, I18nKey::QuickTheme),
            subtitle: if state.theme_mode == kaze_core::ThemeMode::Light {
                t(loc, I18nKey::StateLight).into()
            } else {
                t(loc, I18nKey::StateDark).into()
            },
            active: state.theme_mode == kaze_core::ThemeMode::Light,
        },
    ];

    let tile_w = (inner_w - gap * 2.0) / 3.0;
    let tile_h = 48.0f32;
    for (idx, tile) in tiles.iter().enumerate() {
        let col = (idx % 3) as f32;
        let row = (idx / 3) as f32;
        let tx = x0 + col * (tile_w + gap);
        let ty = y + row * (tile_h + gap);
        let rect = Rect::new(tx, ty, tile_w, tile_h);
        let (fill, fg, sub_fg) = if tile.active {
            (
                pal.primary,
                pal.on_primary,
                pal.on_primary.with_opacity(0.82),
            )
        } else {
            (pal.surface_container, pal.on_surface, pal.muted)
        };
        commands.push(PaintCmd::RoundedRect {
            rect,
            radius: pal.tile_r,
            fill: Some(fill),
            stroke: if tile.active {
                None
            } else {
                Some(pal.outline_variant)
            },
            stroke_width: if tile.active { 0.0 } else { 1.0 },
        });
        commands.push(PaintCmd::Icon {
            rect: Rect::new(tx + 8.0, ty + 9.0, 14.0, 14.0),
            kind: tile.icon,
            color: fg,
            stroke_width: 1.5,
            level: None,
        });
        commands.push(PaintCmd::RichText {
            rect: Rect::new(tx + 26.0, ty + 8.0, tile_w - 30.0, 16.0),
            text: tile.title.to_string(),
            color: fg,
            size: 10.5,
            bold: true,
            align: TextAlign::Left,
            max_lines: 1,
        });
        commands.push(PaintCmd::RichText {
            rect: Rect::new(tx + 8.0, ty + 27.0, tile_w - 14.0, 15.0),
            text: tile.subtitle.clone(),
            color: sub_fg,
            size: 9.5,
            bold: false,
            align: TextAlign::Left,
            max_lines: 1,
        });
        hit_targets.push(HitTarget {
            rect,
            id: tile.id.to_string(),
        });
    }
    y += tile_h * 2.0 + gap + 10.0;

    let (track_x, track_w) = slider_bounds(state);
    y = push_slider_row(
        commands,
        hit_targets,
        x0,
        track_x,
        track_w,
        y,
        if state.audio.muted || state.audio.volume_pct == 0 {
            IconKind::VolumeMuted
        } else {
            IconKind::Volume
        },
        if state.audio.muted {
            pal.error
        } else {
            pal.on_surface
        },
        Some("cc:mute"),
        "cc:slider:vol",
        state.audio.volume_pct,
        if state.audio.muted {
            pal.error
        } else {
            pal.primary
        },
        pal,
    );
    if state.backlight.present {
        y = push_slider_row(
            commands,
            hit_targets,
            x0,
            track_x,
            track_w,
            y,
            IconKind::Brightness,
            pal.on_surface,
            None,
            "cc:slider:bright",
            state.backlight.percentage,
            pal.secondary,
            pal,
        );
    }

    let ops = [
        ("cc:op:layout", IconKind::Layout, t(loc, I18nKey::OpLayout)),
        (
            "cc:op:display",
            IconKind::Display,
            t(loc, I18nKey::OpDisplay),
        ),
        ("cc:op:record", IconKind::Record, t(loc, I18nKey::OpRecord)),
        (
            "cc:op:settings",
            IconKind::Settings,
            t(loc, I18nKey::OpSettings),
        ),
    ];
    let op_w = (inner_w - gap * 3.0) / 4.0;
    let op_h = 32.0f32;
    for (idx, (id, icon, label)) in ops.iter().enumerate() {
        let ox = x0 + idx as f32 * (op_w + gap);
        let rect = Rect::new(ox, y, op_w, op_h);
        commands.push(PaintCmd::RoundedRect {
            rect,
            radius: pal.tile_r,
            fill: Some(pal.surface_container),
            stroke: Some(pal.outline_variant),
            stroke_width: 1.0,
        });
        commands.push(PaintCmd::Icon {
            rect: Rect::new(ox + 6.0, y + 9.0, 14.0, 14.0),
            kind: *icon,
            color: pal.on_surface,
            stroke_width: 1.5,
            level: None,
        });
        commands.push(PaintCmd::RichText {
            rect: Rect::new(ox + 22.0, y, op_w - 26.0, op_h),
            text: (*label).to_string(),
            color: pal.on_surface,
            size: 10.0,
            bold: false,
            align: TextAlign::Center,
            max_lines: 1,
        });
        hit_targets.push(HitTarget {
            rect,
            id: (*id).to_string(),
        });
    }
    y += op_h + 10.0;

    if state.media.active {
        let mrect = Rect::new(x0, y, inner_w, 44.0);
        commands.push(PaintCmd::RoundedRect {
            rect: mrect,
            radius: pal.tile_r,
            fill: Some(pal.surface_container),
            stroke: Some(pal.outline_variant),
            stroke_width: 1.0,
        });
        let title = if state.media.title.trim().is_empty() {
            "Media Playing"
        } else {
            state.media.title.as_str()
        };
        commands.push(PaintCmd::RichText {
            rect: Rect::new(x0 + 10.0, y + 5.0, inner_w - 104.0, 18.0),
            text: title.to_string(),
            color: pal.on_surface,
            size: 11.0,
            bold: true,
            align: TextAlign::Left,
            max_lines: 1,
        });
        let btns = [
            ("cc:media:prev", IconKind::Prev),
            (
                "cc:media:play-pause",
                if state.media.status == MediaPlayback::Playing {
                    IconKind::Pause
                } else {
                    IconKind::Play
                },
            ),
            ("cc:media:next", IconKind::Next),
        ];
        let mut bx = x0 + inner_w - 92.0;
        for (id, icon) in btns {
            let brect = Rect::new(bx, y + 8.0, 26.0, 28.0);
            commands.push(PaintCmd::RoundedRect {
                rect: brect,
                radius: pal.tile_r.min(6.0),
                fill: Some(pal.surface_variant),
                stroke: None,
                stroke_width: 0.0,
            });
            commands.push(PaintCmd::Icon {
                rect: Rect::new(bx + 7.0, y + 16.0, 12.0, 12.0),
                kind: icon,
                color: pal.on_surface,
                stroke_width: 1.5,
                level: None,
            });
            hit_targets.push(HitTarget {
                rect: brect,
                id: id.to_string(),
            });
            bx += 30.0;
        }
        y += 50.0;
    }

    y = render_notif_list(commands, hit_targets, state, pal, x0, inner_w, y, 2);

    // Power Bar
    let power_btns = [
        (
            "cc:power:lock",
            "lock",
            IconKind::Lock,
            t(loc, I18nKey::PowerLock),
        ),
        (
            "cc:power:suspend",
            "suspend",
            IconKind::Suspend,
            t(loc, I18nKey::PowerSuspend),
        ),
        (
            "cc:power:reboot",
            "reboot",
            IconKind::Reboot,
            t(loc, I18nKey::PowerReboot),
        ),
        (
            "cc:power:poweroff",
            "poweroff",
            IconKind::PowerOff,
            t(loc, I18nKey::PowerShutdown),
        ),
    ];
    let pw = (inner_w - gap * 3.0) / 4.0;
    let ph = 30.0f32;
    for (idx, (id, key, icon, label)) in power_btns.iter().enumerate() {
        let px = x0 + idx as f32 * (pw + gap);
        let rect = Rect::new(px, y, pw, ph);
        let confirming = pending_power == Some(*key);
        let (fill, fg) = if confirming {
            (pal.error, pal.on_error)
        } else {
            (pal.surface_container, pal.on_surface)
        };
        commands.push(PaintCmd::RoundedRect {
            rect,
            radius: pal.tile_r,
            fill: Some(fill),
            stroke: if confirming {
                None
            } else {
                Some(pal.outline_variant)
            },
            stroke_width: if confirming { 0.0 } else { 1.0 },
        });
        if confirming {
            commands.push(PaintCmd::RichText {
                rect,
                text: t(loc, I18nKey::ConfirmPrompt).to_string(),
                color: fg,
                size: 10.0,
                bold: true,
                align: TextAlign::Center,
                max_lines: 1,
            });
        } else {
            commands.push(PaintCmd::Icon {
                rect: Rect::new(px + 6.0, y + 8.0, 14.0, 14.0),
                kind: *icon,
                color: fg,
                stroke_width: 1.5,
                level: None,
            });
            commands.push(PaintCmd::RichText {
                rect: Rect::new(px + 22.0, y, pw - 24.0, ph),
                text: (*label).to_string(),
                color: fg,
                size: 10.0,
                bold: false,
                align: TextAlign::Center,
                max_lines: 1,
            });
        }
        hit_targets.push(HitTarget {
            rect,
            id: (*id).to_string(),
        });
    }
    y + ph + 10.0
}

#[allow(clippy::too_many_arguments)]
pub fn render_network_tab(
    commands: &mut Vec<PaintCmd>,
    hit_targets: &mut Vec<HitTarget>,
    state: &AppState,
    pal: &PaletteTheme,
    wifi_prompt_ssid: Option<&str>,
    wifi_input: &TextInputState,
    x0: f32,
    inner_w: f32,
    mut y: f32,
) -> f32 {
    y = push_action_header(
        commands,
        hit_targets,
        x0,
        inner_w,
        y,
        &format!(
            "Wi-Fi {}",
            if state.network.wifi_enabled {
                "On"
            } else {
                "Off"
            }
        ),
        "Scan",
        "cc:net:scan",
        pal,
    );
    y = push_pill_btn(
        commands,
        hit_targets,
        Rect::new(x0, y, inner_w * 0.48, 28.0),
        if state.network.wifi_enabled {
            "Disable Wi-Fi"
        } else {
            "Enable Wi-Fi"
        },
        "cc:toggle:wifi",
        state.network.wifi_enabled,
        pal,
    ) + 6.0;
    if state.network.connected && state.network.kind == NetworkKind::Wifi {
        push_pill_btn(
            commands,
            hit_targets,
            Rect::new(x0 + inner_w * 0.52, y - 34.0, inner_w * 0.48, 28.0),
            "Disconnect",
            "cc:net:disconnect",
            false,
            pal,
        );
    }

    if let Some(ssid) = wifi_prompt_ssid {
        commands.push(PaintCmd::Text {
            rect: Rect::new(x0, y, inner_w, 16.0),
            text: format!("Password for {ssid} (Enter to connect):"),
            color: pal.primary,
            size: 10.5,
            bold: true,
            align: TextAlign::Left,
        });
        y += 18.0;
        let box_rect = Rect::new(x0, y, inner_w, 28.0);
        commands.push(PaintCmd::RoundedRect {
            rect: box_rect,
            radius: pal.tile_r.min(6.0),
            fill: Some(pal.surface_container),
            stroke: Some(pal.primary),
            stroke_width: 1.5,
        });
        let masked = "•".repeat(wifi_input.text.chars().count());
        commands.push(PaintCmd::Text {
            rect: Rect::new(x0 + 8.0, y, inner_w - 16.0, 28.0),
            text: masked,
            color: pal.on_surface,
            size: 12.0,
            bold: false,
            align: TextAlign::Left,
        });
        y += 34.0;
    }

    for ap in state.network.access_points.iter().take(6) {
        let row_rect = Rect::new(x0, y, inner_w, 30.0);
        commands.push(PaintCmd::RoundedRect {
            rect: row_rect,
            radius: pal.tile_r.min(7.0),
            fill: Some(if ap.active {
                pal.surface_variant
            } else {
                pal.surface_container
            }),
            stroke: Some(if ap.active {
                pal.primary
            } else {
                pal.outline_variant
            }),
            stroke_width: 1.0,
        });
        let tag = format!(
            "{} ({}%{})",
            ap.ssid,
            ap.strength,
            if ap.secured { " 🔒" } else { "" }
        );
        commands.push(PaintCmd::RichText {
            rect: Rect::new(x0 + 8.0, y + 6.0, inner_w - 72.0, 18.0),
            text: tag,
            color: pal.on_surface,
            size: 11.0,
            bold: ap.active,
            align: TextAlign::Left,
            max_lines: 1,
        });
        if ap.saved {
            let frect = Rect::new(x0 + inner_w - 58.0, y + 4.0, 52.0, 22.0);
            push_pill_btn(
                commands,
                hit_targets,
                frect,
                "Forget",
                &format!("cc:net:forget:{}", ap.ssid),
                false,
                pal,
            );
        }
        hit_targets.push(HitTarget {
            rect: row_rect,
            id: format!("cc:net:ap:{}", ap.ssid),
        });
        y += 34.0;
    }

    if !state.network.vpns.is_empty() {
        y += 6.0;
        commands.push(PaintCmd::Text {
            rect: Rect::new(x0, y, inner_w, 16.0),
            text: "VPN PROFILES".into(),
            color: pal.muted,
            size: 10.0,
            bold: true,
            align: TextAlign::Left,
        });
        y += 18.0;
        for vpn in state.network.vpns.iter().take(4) {
            y = push_pill_btn(
                commands,
                hit_targets,
                Rect::new(x0, y, inner_w, 28.0),
                &format!(
                    "{} ({}) — {}",
                    vpn.name,
                    vpn.kind,
                    if vpn.active { "Connected" } else { "Off" }
                ),
                &format!("cc:net:vpn:{}", vpn.uuid),
                vpn.active,
                pal,
            ) + 4.0;
        }
    }
    y + 8.0
}

pub fn render_bluetooth_tab(
    commands: &mut Vec<PaintCmd>,
    hit_targets: &mut Vec<HitTarget>,
    state: &AppState,
    pal: &PaletteTheme,
    x0: f32,
    inner_w: f32,
    mut y: f32,
) -> f32 {
    y = push_action_header(
        commands,
        hit_targets,
        x0,
        inner_w,
        y,
        &format!(
            "Bluetooth · {}",
            if state.bluetooth.discovering {
                "Scanning…"
            } else if state.bluetooth.powered {
                "On"
            } else {
                "Off"
            }
        ),
        if state.bluetooth.powered { "Off" } else { "On" },
        "cc:toggle:bt",
        pal,
    );
    if state.bluetooth.devices.is_empty() {
        commands.push(PaintCmd::Text {
            rect: Rect::new(x0, y, inner_w, 24.0),
            text: "No Bluetooth devices discovered".into(),
            color: pal.muted,
            size: 11.0,
            bold: false,
            align: TextAlign::Center,
        });
        return y + 32.0;
    }
    for (idx, dev) in state.bluetooth.devices.iter().take(6).enumerate() {
        let r = Rect::new(x0, y, inner_w, 34.0);
        commands.push(PaintCmd::RoundedRect {
            rect: r,
            radius: pal.tile_r.min(7.0),
            fill: Some(if dev.connected {
                pal.surface_variant
            } else {
                pal.surface_container
            }),
            stroke: Some(if dev.connected {
                pal.primary
            } else {
                pal.outline_variant
            }),
            stroke_width: 1.0,
        });
        let bat = dev
            .battery_pct
            .map_or_else(String::new, |p| format!(" · {p}%"));
        let title = if dev.name.is_empty() {
            dev.address.clone()
        } else {
            dev.name.clone()
        };
        commands.push(PaintCmd::RichText {
            rect: Rect::new(x0 + 8.0, y + 8.0, inner_w - 134.0, 18.0),
            text: format!("{title}{bat}"),
            color: pal.on_surface,
            size: 11.0,
            bold: dev.connected,
            align: TextAlign::Left,
            max_lines: 1,
        });
        let act_label = if dev.connected {
            "Disc"
        } else if dev.paired {
            "Conn"
        } else {
            "Pair"
        };
        let act_id = if dev.connected || dev.paired {
            format!("cc:bt:conn:{idx}")
        } else {
            format!("cc:bt:pair:{idx}")
        };
        push_pill_btn(
            commands,
            hit_targets,
            Rect::new(x0 + inner_w - 122.0, y + 5.0, 56.0, 24.0),
            act_label,
            &act_id,
            dev.connected,
            pal,
        );
        push_pill_btn(
            commands,
            hit_targets,
            Rect::new(x0 + inner_w - 60.0, y + 5.0, 54.0, 24.0),
            "Forget",
            &format!("cc:bt:remove:{idx}"),
            false,
            pal,
        );
        y += 38.0;
    }
    y + 8.0
}

pub fn render_audio_tab(
    commands: &mut Vec<PaintCmd>,
    hit_targets: &mut Vec<HitTarget>,
    state: &AppState,
    pal: &PaletteTheme,
    x0: f32,
    inner_w: f32,
    mut y: f32,
) -> f32 {
    let (track_x, track_w) = slider_bounds(state);
    y = push_slider_row(
        commands,
        hit_targets,
        x0,
        track_x,
        track_w,
        y,
        if state.audio.muted {
            IconKind::VolumeMuted
        } else {
            IconKind::Volume
        },
        if state.audio.muted {
            pal.error
        } else {
            pal.on_surface
        },
        Some("cc:mute"),
        "cc:slider:vol",
        state.audio.volume_pct,
        if state.audio.muted {
            pal.error
        } else {
            pal.primary
        },
        pal,
    );
    commands.push(PaintCmd::Text {
        rect: Rect::new(x0, y, inner_w, 16.0),
        text: "APP STREAMS (PipeWire Mixer)".into(),
        color: pal.muted,
        size: 10.0,
        bold: true,
        align: TextAlign::Left,
    });
    y += 20.0;
    if state.audio.streams.is_empty() {
        commands.push(PaintCmd::Text {
            rect: Rect::new(x0, y, inner_w, 24.0),
            text: "No active playback streams".into(),
            color: pal.muted,
            size: 11.0,
            bold: false,
            align: TextAlign::Center,
        });
        return y + 30.0;
    }
    for stream in state.audio.streams.iter().take(6) {
        let name = if stream.app_name.is_empty() {
            stream.media_name.as_str()
        } else {
            stream.app_name.as_str()
        };
        commands.push(PaintCmd::RichText {
            rect: Rect::new(x0, y, inner_w, 16.0),
            text: name.to_string(),
            color: pal.on_surface,
            size: 10.5,
            bold: true,
            align: TextAlign::Left,
            max_lines: 1,
        });
        y += 16.0;
        y = push_slider_row(
            commands,
            hit_targets,
            x0,
            track_x,
            track_w,
            y,
            if stream.muted {
                IconKind::VolumeMuted
            } else {
                IconKind::Volume
            },
            if stream.muted {
                pal.error
            } else {
                pal.on_surface
            },
            Some(&format!("cc:audio:stream_mute:{}", stream.index)),
            &format!("cc:slider:stream:{}", stream.index),
            stream.volume_pct,
            if stream.muted {
                pal.error
            } else {
                pal.secondary
            },
            pal,
        );
    }
    y + 6.0
}

pub fn render_sysmon_tab(
    commands: &mut Vec<PaintCmd>,
    state: &AppState,
    pal: &PaletteTheme,
    x0: f32,
    inner_w: f32,
    mut y: f32,
) -> f32 {
    let sm = &state.sysmon;
    let ram_pct = (sm.ram_used_mib * 100)
        .checked_div(sm.ram_total_mib)
        .unwrap_or(0)
        .min(100) as f32;
    let swap_pct = (sm.swap_used_mib * 100)
        .checked_div(sm.swap_total_mib)
        .unwrap_or(0)
        .min(100) as f32;
    let rows = [
        (format!("CPU {:.1}%", sm.cpu_pct), sm.cpu_pct, pal.primary),
        (
            format!("RAM {}/{} MiB", sm.ram_used_mib, sm.ram_total_mib),
            ram_pct,
            pal.secondary,
        ),
        (
            format!("Swap {}/{} MiB", sm.swap_used_mib, sm.swap_total_mib),
            swap_pct,
            pal.secondary,
        ),
    ];
    for (label, pct, col) in rows {
        commands.push(PaintCmd::TabularText {
            rect: Rect::new(x0, y, inner_w, 16.0),
            text: label,
            color: pal.on_surface,
            size: 11.0,
            bold: true,
            align: TextAlign::Left,
        });
        y += 17.0;
        let track = Rect::new(x0, y, inner_w, 8.0);
        commands.push(PaintCmd::RoundedRect {
            rect: track,
            radius: 4.0,
            fill: Some(pal.surface_container),
            stroke: None,
            stroke_width: 0.0,
        });
        let fw = (inner_w * (pct.clamp(0.0, 100.0) / 100.0)).round();
        if fw >= 1.0 {
            commands.push(PaintCmd::RoundedRect {
                rect: Rect::new(x0, y, fw, 8.0),
                radius: 4.0,
                fill: Some(col),
                stroke: None,
                stroke_width: 0.0,
            });
        }
        y += 14.0;
    }
    let rx_kb = sm.net_rx_bps / 1024;
    let tx_kb = sm.net_tx_bps / 1024;
    let info_lines = [
        format!(
            "Temp: {}   Net: ↓{rx_kb} KB/s  ↑{tx_kb} KB/s",
            sm.temp_c
                .map_or_else(|| "--".into(), |t| format!("{t:.0}°C"))
        ),
        format!("OS: {} ({})", sm.distro, sm.kernel),
        format!("CPU: {}", sm.cpu_model),
        format!("Uptime: {}m", sm.uptime_secs / 60),
    ];
    for line in info_lines {
        commands.push(PaintCmd::TabularText {
            rect: Rect::new(x0, y, inner_w, 16.0),
            text: line,
            color: pal.muted,
            size: 10.0,
            bold: false,
            align: TextAlign::Left,
        });
        y += 17.0;
    }
    y + 8.0
}

pub fn render_weather_tab(
    commands: &mut Vec<PaintCmd>,
    hit_targets: &mut Vec<HitTarget>,
    state: &AppState,
    pal: &PaletteTheme,
    x0: f32,
    inner_w: f32,
    mut y: f32,
) -> f32 {
    let w = &state.weather;
    y = push_action_header(
        commands,
        hit_targets,
        x0,
        inner_w,
        y,
        if w.location_name.is_empty() {
            &state.config.weather.city
        } else {
            &w.location_name
        },
        "Refresh",
        "cc:weather:refresh",
        pal,
    );
    if !w.available {
        commands.push(PaintCmd::Text {
            rect: Rect::new(x0, y, inner_w, 28.0),
            text: if w.offline_blocked {
                "Offline mode active — network weather disabled".into()
            } else {
                w.error
                    .clone()
                    .unwrap_or_else(|| "Weather data unavailable".into())
            },
            color: pal.muted,
            size: 11.0,
            bold: false,
            align: TextAlign::Center,
        });
        return y + 36.0;
    }
    commands.push(PaintCmd::TabularText {
        rect: Rect::new(x0, y, inner_w, 26.0),
        text: format!(
            "{:.1}°C  ·  {}  {}",
            w.temp_c,
            w.condition,
            if w.stale { "(cached)" } else { "" }
        ),
        color: pal.on_surface,
        size: 15.0,
        bold: true,
        align: TextAlign::Left,
    });
    y += 28.0;
    commands.push(PaintCmd::TabularText {
        rect: Rect::new(x0, y, inner_w, 16.0),
        text: format!(
            "Feels {:.1}°C · Humidity {}% · Wind {:.1} km/h",
            w.feels_like_c, w.humidity_pct, w.wind_kph
        ),
        color: pal.muted,
        size: 10.5,
        bold: false,
        align: TextAlign::Left,
    });
    y += 22.0;
    for day in w.daily.iter().take(5) {
        commands.push(PaintCmd::TabularText {
            rect: Rect::new(x0, y, inner_w, 16.0),
            text: format!(
                "{}   {:.0}° / {:.0}°   {}",
                day.date_label, day.min_c, day.max_c, day.condition
            ),
            color: pal.on_surface,
            size: 10.5,
            bold: false,
            align: TextAlign::Left,
        });
        y += 18.0;
    }
    y + 8.0
}

pub fn render_screentime_tab(
    commands: &mut Vec<PaintCmd>,
    hit_targets: &mut Vec<HitTarget>,
    state: &AppState,
    pal: &PaletteTheme,
    x0: f32,
    inner_w: f32,
    mut y: f32,
) -> f32 {
    let st = &state.screentime;
    let mins = st.today_total_secs / 60;
    y = push_action_header(
        commands,
        hit_targets,
        x0,
        inner_w,
        y,
        &format!("Today: {}h {:02}m", mins / 60, mins % 60),
        "Reset",
        "cc:screentime:reset",
        pal,
    );
    let max_s = st
        .top_apps_today
        .iter()
        .map(|a| a.seconds)
        .max()
        .unwrap_or(1)
        .max(1);
    for app in st.top_apps_today.iter().take(6) {
        let m = app.seconds / 60;
        commands.push(PaintCmd::TabularText {
            rect: Rect::new(x0, y, inner_w, 15.0),
            text: format!("{} — {}m", app.app_id, m),
            color: pal.on_surface,
            size: 10.5,
            bold: false,
            align: TextAlign::Left,
        });
        y += 16.0;
        let fw = ((inner_w * app.seconds as f32) / max_s as f32).max(4.0);
        commands.push(PaintCmd::RoundedRect {
            rect: Rect::new(x0, y, fw, 6.0),
            radius: 3.0,
            fill: Some(pal.primary),
            stroke: None,
            stroke_width: 0.0,
        });
        y += 10.0;
    }
    y + 8.0
}

pub fn render_calendar_tab(
    commands: &mut Vec<PaintCmd>,
    hit_targets: &mut Vec<HitTarget>,
    state: &AppState,
    pal: &PaletteTheme,
    x0: f32,
    inner_w: f32,
    mut y: f32,
) -> f32 {
    y = push_action_header(
        commands,
        hit_targets,
        x0,
        inner_w,
        y,
        &format!("Agenda ({} events)", state.calendar.events.len()),
        "Sync",
        "cc:cal:sync",
        pal,
    );
    if state.calendar.events.is_empty() {
        commands.push(PaintCmd::Text {
            rect: Rect::new(x0, y, inner_w, 26.0),
            text: "No upcoming calendar events".into(),
            color: pal.muted,
            size: 11.0,
            bold: false,
            align: TextAlign::Center,
        });
        return y + 32.0;
    }
    for ev in state.calendar.events.iter().take(6) {
        let card = Rect::new(x0, y, inner_w, 30.0);
        commands.push(PaintCmd::RoundedRect {
            rect: card,
            radius: pal.tile_r.min(6.0),
            fill: Some(pal.surface_container),
            stroke: Some(pal.outline_variant),
            stroke_width: 1.0,
        });
        commands.push(PaintCmd::RichText {
            rect: Rect::new(x0 + 8.0, y + 6.0, inner_w - 16.0, 18.0),
            text: ev.title.clone(),
            color: pal.on_surface,
            size: 11.0,
            bold: true,
            align: TextAlign::Left,
            max_lines: 1,
        });
        y += 34.0;
    }
    y + 8.0
}

#[allow(clippy::too_many_arguments)]
pub fn render_notif_list(
    commands: &mut Vec<PaintCmd>,
    hit_targets: &mut Vec<HitTarget>,
    state: &AppState,
    pal: &PaletteTheme,
    x0: f32,
    inner_w: f32,
    mut y: f32,
    limit: usize,
) -> f32 {
    let loc = state.locale;
    let hist_count = state.notification_history.len();
    commands.push(PaintCmd::RichText {
        rect: Rect::new(x0, y, inner_w - 72.0, 18.0),
        text: format!(
            "{} ({hist_count})",
            t(loc, I18nKey::NotificationsHeader).to_uppercase()
        ),
        color: pal.muted,
        size: 10.0,
        bold: true,
        align: TextAlign::Left,
        max_lines: 1,
    });
    if hist_count > 0 || state.unread_notifications > 0 {
        let clear_rect = Rect::new(x0 + inner_w - 72.0, y - 2.0, 72.0, 20.0);
        commands.push(PaintCmd::RoundedRect {
            rect: clear_rect,
            radius: pal.tile_r.min(5.0),
            fill: Some(pal.surface_container),
            stroke: Some(pal.outline_variant),
            stroke_width: 1.0,
        });
        commands.push(PaintCmd::RichText {
            rect: clear_rect,
            text: t(loc, I18nKey::NotificationsClearAll).to_string(),
            color: pal.primary,
            size: 10.0,
            bold: true,
            align: TextAlign::Center,
            max_lines: 1,
        });
        hit_targets.push(HitTarget {
            rect: clear_rect,
            id: "cc:notif:clear".to_string(),
        });
    }
    y += 22.0;

    if state.notification_history.is_empty() {
        let empty_rect = Rect::new(x0, y, inner_w, 28.0);
        commands.push(PaintCmd::RoundedRect {
            rect: empty_rect,
            radius: pal.tile_r,
            fill: Some(pal.surface_container),
            stroke: None,
            stroke_width: 0.0,
        });
        commands.push(PaintCmd::RichText {
            rect: empty_rect,
            text: t(loc, I18nKey::NotificationsEmpty).to_string(),
            color: pal.muted,
            size: 10.5,
            bold: false,
            align: TextAlign::Center,
            max_lines: 1,
        });
        return y + 34.0;
    }

    for item in state.notification_history.iter().take(limit) {
        let nrect = Rect::new(x0, y, inner_w, 34.0);
        commands.push(PaintCmd::RoundedRect {
            rect: nrect,
            radius: pal.tile_r,
            fill: Some(pal.surface_container),
            stroke: Some(pal.outline_variant),
            stroke_width: 1.0,
        });
        let title = if item.summary.trim().is_empty() {
            item.app_name.as_str()
        } else {
            item.summary.as_str()
        };
        commands.push(PaintCmd::RichText {
            rect: Rect::new(x0 + 8.0, y + 4.0, inner_w - 34.0, 15.0),
            text: title.to_string(),
            color: pal.on_surface,
            size: 10.5,
            bold: true,
            align: TextAlign::Left,
            max_lines: 1,
        });
        commands.push(PaintCmd::RichText {
            rect: Rect::new(x0 + 8.0, y + 18.0, inner_w - 34.0, 13.0),
            text: item.body.trim().to_string(),
            color: pal.muted,
            size: 9.5,
            bold: false,
            align: TextAlign::Left,
            max_lines: 1,
        });
        let x_rect = Rect::new(x0 + inner_w - 24.0, y + 5.0, 20.0, 22.0);
        commands.push(PaintCmd::Icon {
            rect: Rect::new(x_rect.x + 5.0, x_rect.y + 6.0, 10.0, 10.0),
            kind: IconKind::Close,
            color: pal.muted,
            stroke_width: 1.4,
            level: None,
        });
        hit_targets.push(HitTarget {
            rect: x_rect,
            id: format!("cc:notif:dismiss:{}", item.id),
        });
        y += 38.0;
    }
    y + 4.0
}

#[allow(clippy::too_many_arguments)]
fn push_slider_row(
    commands: &mut Vec<PaintCmd>,
    hit_targets: &mut Vec<HitTarget>,
    x0: f32,
    track_x: f32,
    track_w: f32,
    y: f32,
    icon: IconKind,
    icon_color: Color,
    icon_target: Option<&str>,
    slider_target: &str,
    pct: u8,
    fill_color: Color,
    pal: &PaletteTheme,
) -> f32 {
    let row_h = 30.0f32;
    let icon_btn = Rect::new(x0, y + 2.0, 26.0, 26.0);
    commands.push(PaintCmd::RoundedRect {
        rect: icon_btn,
        radius: pal.tile_r.min(6.0),
        fill: Some(pal.surface_container),
        stroke: None,
        stroke_width: 0.0,
    });
    commands.push(PaintCmd::Icon {
        rect: Rect::new(icon_btn.x + 6.0, icon_btn.y + 6.0, 14.0, 14.0),
        kind: icon,
        color: icon_color,
        stroke_width: 1.5,
        level: Some(pct),
    });
    if let Some(tid) = icon_target {
        hit_targets.push(HitTarget {
            rect: icon_btn,
            id: tid.to_string(),
        });
    }

    let track_h = 8.0f32;
    let track_y = y + (row_h - track_h) * 0.5;
    let track_rect = Rect::new(track_x, track_y, track_w, track_h);
    let track_r = pal.tile_r.min(4.0);
    commands.push(PaintCmd::RoundedRect {
        rect: track_rect,
        radius: track_r,
        fill: Some(pal.surface_variant),
        stroke: None,
        stroke_width: 0.0,
    });
    let clamped = pct.min(100);
    let fill_w = track_w * (f32::from(clamped) / 100.0);
    if fill_w > 1.0 {
        commands.push(PaintCmd::RoundedRect {
            rect: Rect::new(track_x, track_y, fill_w, track_h),
            radius: track_r,
            fill: Some(fill_color),
            stroke: None,
            stroke_width: 0.0,
        });
    }
    hit_targets.push(HitTarget {
        rect: Rect::new(track_x - 4.0, y, track_w + 8.0, row_h),
        id: slider_target.to_string(),
    });
    commands.push(PaintCmd::TabularText {
        rect: Rect::new(track_x + track_w + 4.0, y, 36.0, row_h),
        text: format!("{clamped}%"),
        color: pal.on_surface,
        size: 10.5,
        bold: true,
        align: TextAlign::Right,
    });
    y + row_h + 4.0
}

#[allow(clippy::too_many_arguments)]
fn push_action_header(
    commands: &mut Vec<PaintCmd>,
    hit_targets: &mut Vec<HitTarget>,
    x0: f32,
    inner_w: f32,
    y: f32,
    title: &str,
    btn_label: &str,
    btn_id: &str,
    pal: &PaletteTheme,
) -> f32 {
    commands.push(PaintCmd::Text {
        rect: Rect::new(x0, y, inner_w - 72.0, 22.0),
        text: title.to_string(),
        color: pal.on_surface,
        size: 12.0,
        bold: true,
        align: TextAlign::Left,
    });
    push_pill_btn(
        commands,
        hit_targets,
        Rect::new(x0 + inner_w - 66.0, y, 66.0, 22.0),
        btn_label,
        btn_id,
        false,
        pal,
    );
    y + 28.0
}

fn push_pill_btn(
    commands: &mut Vec<PaintCmd>,
    hit_targets: &mut Vec<HitTarget>,
    rect: Rect,
    label: &str,
    id: &str,
    active: bool,
    pal: &PaletteTheme,
) -> f32 {
    commands.push(PaintCmd::RoundedRect {
        rect,
        radius: pal.tile_r.min(6.0),
        fill: Some(if active {
            pal.primary
        } else {
            pal.surface_container
        }),
        stroke: Some(if active {
            pal.primary
        } else {
            pal.outline_variant
        }),
        stroke_width: 1.0,
    });
    commands.push(PaintCmd::Text {
        rect,
        text: label.to_string(),
        color: if active {
            pal.on_primary
        } else {
            pal.on_surface
        },
        size: 10.5,
        bold: active,
        align: TextAlign::Center,
    });
    hit_targets.push(HitTarget {
        rect,
        id: id.to_string(),
    });
    rect.y + rect.h
}
