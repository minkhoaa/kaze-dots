#![deny(clippy::unwrap_used)]

use kaze_core::{
    t, Anchor, AppState, Color, DirtyFlags, EdgeInsets, HitTarget, I18nKey, IconKind, IpcResult,
    KazeExtension, KeyEvent, KeyboardMode, Layer, LayoutPreset, MediaPlayback, NetworkKind,
    PaintCmd, PointerButton, Rect, ShellAction, ShellContext, SurfaceSpec, SystemEvent, TextAlign,
};

const SURFACE_ID: &str = "cc:main";
const NAMESPACE: &str = "kaze-cc";
const POWER_CONFIRM_TIMER: &str = "cc:power-confirm-reset";
const POWER_CONFIRM_MS: u64 = 4000;
const KEY_ESCAPE: u32 = 0xff1b;

const CC_WIDTH: f32 = 368.0;
const PAD_X: f32 = 14.0;
const SLIDER_TRACK_X: f32 = 46.0;
const SLIDER_TRACK_W: f32 = CC_WIDTH - SLIDER_TRACK_X - 54.0;

/// Control Center overlay (`kaze-cc`, `Layer::Overlay`):
/// 5 compact blocks matching the active layout preset's corner radius and theme palette:
/// 1) 2x3 Quick Toggles (Wi-Fi, Bluetooth, DND, Night Light, Caffeine, Dark/Light)
/// 2) Volume + optional Brightness sliders (click & drag)
/// 3) Quick Kaze Ops (Layout, Display, Record, Settings)
/// 4) Media (when active) + Notification History (dismiss / Clear All)
/// 5) Power Bar (Lock, Suspend, Reboot, Poweroff with inline 2-click confirm)
///
/// Returns `Vec::new()` when closed so `kaze-ui` immediately destroys the Wayland surface
/// and drops its SHM `SlotPool` back to 0 KiB.
pub struct ControlCenterExtension {
    open: bool,
    pending_power_confirm: Option<String>,
    cached_spec: Option<SurfaceSpec>,
}

impl Default for ControlCenterExtension {
    fn default() -> Self {
        Self::new()
    }
}

impl ControlCenterExtension {
    pub fn new() -> Self {
        Self {
            open: false,
            pending_power_confirm: None,
            cached_spec: None,
        }
    }

    pub fn is_open(&self) -> bool {
        self.open
    }

    fn set_open(&mut self, open: bool, ctx: &mut ShellContext) -> DirtyFlags {
        if self.open == open {
            return DirtyFlags::NONE;
        }
        self.open = open;
        ctx.state.cc_open = open;
        if !open {
            self.pending_power_confirm = None;
            ctx.push_action(ShellAction::CancelTimer {
                id: POWER_CONFIRM_TIMER.to_string(),
            });
            self.cached_spec = None;
        } else {
            self.rebuild(ctx.state);
        }
        DirtyFlags::CC | DirtyFlags::LAYOUT
    }

    fn rebuild(&mut self, state: &AppState) {
        if !self.open {
            self.cached_spec = None;
            return;
        }
        self.cached_spec = Some(build_cc_surface(
            state,
            self.pending_power_confirm.as_deref(),
        ));
    }

    fn handle_slider(&self, target_id: &str, x: f32, ctx: &mut ShellContext) -> DirtyFlags {
        let ratio = ((x - SLIDER_TRACK_X) / SLIDER_TRACK_W).clamp(0.0, 1.0);
        let pct = (ratio * 100.0).round() as u8;
        match target_id {
            "cc:slider:vol" => {
                ctx.push_action(ShellAction::AudioSetVolume(pct));
                DirtyFlags::NONE
            }
            "cc:slider:bright" => {
                ctx.push_action(ShellAction::BacklightSet(pct.max(5)));
                DirtyFlags::NONE
            }
            _ => DirtyFlags::NONE,
        }
    }

    fn handle_click(
        &mut self,
        target_id: &str,
        button: PointerButton,
        ctx: &mut ShellContext,
    ) -> DirtyFlags {
        if button == PointerButton::Right {
            return self.set_open(false, ctx);
        }
        if button != PointerButton::Left {
            return DirtyFlags::NONE;
        }

        // Sliders are handled via PointerClickAt / PointerDrag for exact X coordinates.
        if target_id.starts_with("cc:slider:") {
            return DirtyFlags::NONE;
        }

        match target_id {
            "cc:toggle:wifi" => {
                ctx.push_action(ShellAction::WifiToggle);
                DirtyFlags::NONE
            }
            "cc:toggle:bt" => {
                ctx.push_action(ShellAction::BluetoothToggle);
                DirtyFlags::NONE
            }
            "cc:toggle:dnd" => {
                ctx.push_action(ShellAction::SetDnd(!ctx.state.dnd));
                DirtyFlags::NONE
            }
            "cc:toggle:nightlight" => {
                ctx.push_action(ShellAction::SetNightLight {
                    enabled: !ctx.state.nightlight_enabled,
                    temp_k: ctx.state.nightlight_temp_k,
                });
                DirtyFlags::NONE
            }
            "cc:toggle:caffeine" => {
                ctx.push_action(ShellAction::SetCaffeine(!ctx.state.caffeine_enabled));
                DirtyFlags::NONE
            }
            "cc:toggle:theme" => {
                ctx.push_action(ShellAction::ThemeModeToggle);
                DirtyFlags::NONE
            }
            "cc:mute" => {
                ctx.push_action(ShellAction::AudioToggleMute);
                DirtyFlags::NONE
            }
            "cc:op:layout" => {
                ctx.push_action(ShellAction::LayoutCycle);
                DirtyFlags::NONE
            }
            "cc:op:display" => {
                ctx.push_action(ShellAction::SpawnCommand {
                    program: "kaze-display".to_string(),
                    args: vec!["--menu".to_string()],
                });
                self.set_open(false, ctx)
            }
            "cc:op:record" => {
                ctx.push_action(ShellAction::SpawnCommand {
                    program: "kaze-record".to_string(),
                    args: vec!["--menu".to_string()],
                });
                self.set_open(false, ctx)
            }
            "cc:op:settings" => {
                ctx.push_action(ShellAction::SpawnDetachedApp {
                    program: "kaze-footclient".to_string(),
                    args: vec![
                        "-e".to_string(),
                        "sh".to_string(),
                        "-c".to_string(),
                        "${EDITOR:-nvim} \"${XDG_CONFIG_HOME:-$HOME/.config}/kaze-shell/config.toml\""
                            .to_string(),
                    ],
                });
                self.set_open(false, ctx)
            }
            "cc:media:prev" => {
                ctx.push_action(ShellAction::MediaCommand("prev".to_string()));
                DirtyFlags::NONE
            }
            "cc:media:play-pause" => {
                ctx.push_action(ShellAction::MediaCommand("play-pause".to_string()));
                DirtyFlags::NONE
            }
            "cc:media:next" => {
                ctx.push_action(ShellAction::MediaCommand("next".to_string()));
                DirtyFlags::NONE
            }
            "cc:notif:clear" => {
                ctx.push_action(ShellAction::ClearNotifications);
                DirtyFlags::NONE
            }
            "cc:power:lock" => {
                ctx.push_action(ShellAction::SpawnCommand {
                    program: "kaze-session".to_string(),
                    args: vec!["lock".to_string()],
                });
                self.set_open(false, ctx)
            }
            "cc:power:suspend" | "cc:power:reboot" | "cc:power:poweroff" => {
                let action = target_id.trim_start_matches("cc:power:").to_string();
                if self.pending_power_confirm.as_deref() == Some(action.as_str()) {
                    self.pending_power_confirm = None;
                    ctx.push_action(ShellAction::CancelTimer {
                        id: POWER_CONFIRM_TIMER.to_string(),
                    });
                    ctx.push_action(ShellAction::SystemPower(action));
                    self.set_open(false, ctx)
                } else {
                    self.pending_power_confirm = Some(action);
                    ctx.push_action(ShellAction::ScheduleTimer {
                        id: POWER_CONFIRM_TIMER.to_string(),
                        after_ms: POWER_CONFIRM_MS,
                    });
                    self.rebuild(ctx.state);
                    DirtyFlags::CC
                }
            }
            other => {
                if let Some(id_str) = other.strip_prefix("cc:notif:dismiss:") {
                    if let Ok(id) = id_str.parse::<u32>() {
                        ctx.push_action(ShellAction::DismissHistoryNotification(id));
                    }
                }
                DirtyFlags::NONE
            }
        }
    }
}

impl KazeExtension for ControlCenterExtension {
    fn id(&self) -> &'static str {
        "cc"
    }

    fn on_init(&mut self, ctx: &mut ShellContext) {
        ctx.state.cc_open = false;
    }

    fn on_event(&mut self, event: &SystemEvent, ctx: &mut ShellContext) -> DirtyFlags {
        match event {
            SystemEvent::PointerClick {
                surface_id,
                target_id,
                button,
            } if surface_id == SURFACE_ID => self.handle_click(target_id, *button, ctx),
            SystemEvent::PointerClickAt {
                surface_id,
                target_id,
                button: PointerButton::Left,
                x,
                ..
            } if surface_id == SURFACE_ID && target_id.starts_with("cc:slider:") => {
                self.handle_slider(target_id, *x, ctx)
            }
            SystemEvent::PointerDrag {
                surface_id,
                target_id,
                x,
                ..
            } if surface_id == SURFACE_ID && target_id.starts_with("cc:slider:") => {
                self.handle_slider(target_id, *x, ctx)
            }
            SystemEvent::PointerScroll {
                surface_id,
                target_id,
                delta_y,
                modifiers,
            } if surface_id == SURFACE_ID && target_id.starts_with("cc:slider:") => {
                let mag = if modifiers.shift { 1 } else { 5 };
                let step = if *delta_y < 0.0 { mag } else { -mag };
                match target_id.as_str() {
                    "cc:slider:vol" => ctx.push_action(ShellAction::AudioStepVolume(step)),
                    "cc:slider:bright" => ctx.push_action(ShellAction::BacklightStep(step)),
                    _ => {}
                }
                DirtyFlags::NONE
            }
            SystemEvent::KeyInput {
                surface_id,
                key:
                    KeyEvent {
                        keysym: KEY_ESCAPE,
                        pressed: true,
                        ..
                    },
            } if surface_id == SURFACE_ID => self.set_open(false, ctx),
            SystemEvent::SurfaceClosed { surface_id }
            | SystemEvent::KeyboardFocusLost { surface_id }
                if surface_id == SURFACE_ID =>
            {
                self.set_open(false, ctx)
            }
            SystemEvent::TimerFired { id } if id == POWER_CONFIRM_TIMER => {
                if self.pending_power_confirm.take().is_some() && self.open {
                    self.rebuild(ctx.state);
                    DirtyFlags::CC
                } else {
                    DirtyFlags::NONE
                }
            }
            SystemEvent::NetworkChanged(_)
            | SystemEvent::BluetoothChanged(_)
            | SystemEvent::AudioChanged { .. }
            | SystemEvent::BacklightChanged { .. }
            | SystemEvent::BatteryChanged(_)
            | SystemEvent::MediaChanged(_)
            | SystemEvent::DndChanged(_)
            | SystemEvent::NightLightChanged { .. }
            | SystemEvent::CaffeineChanged(_)
            | SystemEvent::NotificationReceived(_)
            | SystemEvent::NotificationDismissHistory { .. }
            | SystemEvent::NotificationClearAll
            | SystemEvent::NotificationsCountChanged(_)
            | SystemEvent::LayoutPresetChanged(_)
            | SystemEvent::ThemeChanged(_)
            | SystemEvent::LocaleChanged(_)
            | SystemEvent::ConfigReloaded => {
                if self.open {
                    self.rebuild(ctx.state);
                    DirtyFlags::CC
                } else {
                    DirtyFlags::NONE
                }
            }
            _ => DirtyFlags::NONE,
        }
    }

    fn on_ipc(&mut self, cmd: &str, _args: &[String], ctx: &mut ShellContext) -> IpcResult {
        match cmd {
            "cc-toggle" => {
                let next = !self.open;
                let dirty = self.set_open(next, ctx);
                IpcResult::Handled {
                    ok: true,
                    message: if next {
                        "opened".into()
                    } else {
                        "closed".into()
                    },
                    dirty,
                }
            }
            "cc-open" => {
                let dirty = self.set_open(true, ctx);
                IpcResult::Handled {
                    ok: true,
                    message: "opened".into(),
                    dirty,
                }
            }
            "cc-close" => {
                let dirty = self.set_open(false, ctx);
                IpcResult::Handled {
                    ok: true,
                    message: "closed".into(),
                    dirty,
                }
            }
            _ => IpcResult::Unhandled,
        }
    }

    fn surfaces(&self) -> Vec<SurfaceSpec> {
        self.cached_spec.clone().into_iter().collect()
    }
}

struct ToggleTile {
    id: &'static str,
    icon: IconKind,
    title: &'static str,
    subtitle: String,
    active: bool,
}

fn build_cc_surface(state: &AppState, pending_power: Option<&str>) -> SurfaceSpec {
    let colors = state.palette.for_mode(state.theme_mode);
    let bg = colors
        .surface_color()
        .with_opacity(state.config.bar.background_opacity.max(0.94));
    let primary = colors.primary_color();
    let on_primary = colors.on_primary_color();
    let secondary = colors.secondary_color();
    let error_col = colors.error_color();
    let on_error = colors.color(&colors.on_error, Color::rgba(0xff, 0xff, 0xff, 0xff));
    let on_surface = colors.on_surface_color();
    let muted = colors.on_surface_variant_color();
    let surface_container = colors.surface_container_color();
    let surface_variant = colors.surface_variant_color();
    let outline_variant = colors.outline_variant_color();

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
    let border_w = state
        .config
        .bar
        .border_width
        .max(state.layout_preset.overlay_border_width());

    let inner_w = CC_WIDTH - PAD_X * 2.0;
    let mut commands = Vec::with_capacity(64);
    let mut hit_targets = Vec::with_capacity(28);
    let mut y = border_w + 12.0;

    let loc = state.locale;
    // Header strip: title + clock + battery summary
    let header_left = format!(
        "{} · {}",
        t(loc, I18nKey::ControlCenterTitle),
        state.layout_preset.as_str().to_uppercase()
    );
    commands.push(PaintCmd::RichText {
        rect: Rect::new(PAD_X, y, inner_w - 86.0, 18.0),
        text: header_left,
        color: muted,
        size: 10.5,
        bold: true,
        align: TextAlign::Left,
        max_lines: 1,
    });
    let header_right = if state.battery.present {
        format!(
            "{} · {}%",
            state.clock.format_hh_mm(),
            state.battery.percentage
        )
    } else {
        state.clock.format_hh_mm()
    };
    commands.push(PaintCmd::Text {
        rect: Rect::new(CC_WIDTH - PAD_X - 86.0, y, 86.0, 18.0),
        text: header_right,
        color: on_surface,
        size: 10.5,
        bold: true,
        align: TextAlign::Right,
    });
    y += 26.0;

    // 1. Quick Toggles (2x3 grid)
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

    let gap = 8.0f32;
    let tile_w = (inner_w - gap * 2.0) / 3.0;
    let tile_h = 50.0f32;
    for (idx, tile) in tiles.iter().enumerate() {
        let col = (idx % 3) as f32;
        let row = (idx / 3) as f32;
        let tx = PAD_X + col * (tile_w + gap);
        let ty = y + row * (tile_h + gap);
        let rect = Rect::new(tx, ty, tile_w, tile_h);
        let (fill, fg, sub_fg) = if tile.active {
            (primary, on_primary, on_primary.with_opacity(0.82))
        } else {
            (surface_container, on_surface, muted)
        };
        commands.push(PaintCmd::RoundedRect {
            rect,
            radius: tile_r,
            fill: Some(fill),
            stroke: if tile.active {
                None
            } else {
                Some(outline_variant)
            },
            stroke_width: if tile.active { 0.0 } else { 1.0 },
        });
        commands.push(PaintCmd::Icon {
            rect: Rect::new(tx + 9.0, ty + 10.0, 15.0, 14.0),
            kind: tile.icon,
            color: fg,
            stroke_width: 1.5,
            level: None,
        });
        commands.push(PaintCmd::RichText {
            rect: Rect::new(tx + 28.0, ty + 8.0, tile_w - 34.0, 16.0),
            text: tile.title.to_string(),
            color: fg,
            size: 11.0,
            bold: true,
            align: TextAlign::Left,
            max_lines: 1,
        });
        commands.push(PaintCmd::RichText {
            rect: Rect::new(tx + 9.0, ty + 28.0, tile_w - 16.0, 16.0),
            text: tile.subtitle.clone(),
            color: sub_fg,
            size: 10.0,
            bold: false,
            align: TextAlign::Left,
            max_lines: 1,
        });
        hit_targets.push(HitTarget {
            rect,
            id: tile.id.to_string(),
        });
    }
    y += tile_h * 2.0 + gap + 12.0;

    // 2. Sliders (Volume + optional Brightness)
    y = push_slider_row(
        &mut commands,
        &mut hit_targets,
        y,
        if state.audio.muted || state.audio.volume_pct == 0 {
            IconKind::VolumeMuted
        } else {
            IconKind::Volume
        },
        if state.audio.muted {
            error_col
        } else {
            on_surface
        },
        Some("cc:mute"),
        "cc:slider:vol",
        state.audio.volume_pct,
        if state.audio.muted {
            error_col
        } else {
            primary
        },
        surface_container,
        surface_variant,
        on_surface,
        tile_r,
    );

    if state.backlight.present {
        y = push_slider_row(
            &mut commands,
            &mut hit_targets,
            y,
            IconKind::Brightness,
            on_surface,
            None,
            "cc:slider:bright",
            state.backlight.percentage,
            secondary,
            surface_container,
            surface_variant,
            on_surface,
            tile_r,
        );
    }
    y += 4.0;

    // 3. Quick Kaze Ops (4 buttons)
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
    let op_h = 34.0f32;
    for (idx, (id, icon, label)) in ops.iter().enumerate() {
        let ox = PAD_X + idx as f32 * (op_w + gap);
        let rect = Rect::new(ox, y, op_w, op_h);
        commands.push(PaintCmd::RoundedRect {
            rect,
            radius: tile_r,
            fill: Some(surface_container),
            stroke: Some(outline_variant),
            stroke_width: 1.0,
        });
        commands.push(PaintCmd::Icon {
            rect: Rect::new(ox + 8.0, y + 10.0, 14.0, 14.0),
            kind: *icon,
            color: on_surface,
            stroke_width: 1.5,
            level: None,
        });
        commands.push(PaintCmd::RichText {
            rect: Rect::new(ox + 24.0, y, op_w - 28.0, op_h),
            text: (*label).to_string(),
            color: on_surface,
            size: 10.5,
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

    // 4a. Compact Media Controls (only when active)
    if state.media.active {
        let mrect = Rect::new(PAD_X, y, inner_w, 46.0);
        commands.push(PaintCmd::RoundedRect {
            rect: mrect,
            radius: tile_r,
            fill: Some(surface_container),
            stroke: Some(outline_variant),
            stroke_width: 1.0,
        });
        let title = if state.media.title.trim().is_empty() {
            "Media Playing"
        } else {
            state.media.title.as_str()
        };
        commands.push(PaintCmd::RichText {
            rect: Rect::new(PAD_X + 10.0, y + 6.0, inner_w - 110.0, 18.0),
            text: title.to_string(),
            color: on_surface,
            size: 11.5,
            bold: true,
            align: TextAlign::Left,
            max_lines: 1,
        });
        if !state.media.artist.trim().is_empty() {
            commands.push(PaintCmd::RichText {
                rect: Rect::new(PAD_X + 10.0, y + 24.0, inner_w - 110.0, 16.0),
                text: state.media.artist.clone(),
                color: muted,
                size: 10.0,
                bold: false,
                align: TextAlign::Left,
                max_lines: 1,
            });
        }
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
        let mut bx = PAD_X + inner_w - 92.0;
        for (id, icon) in btns {
            let brect = Rect::new(bx, y + 9.0, 26.0, 28.0);
            commands.push(PaintCmd::RoundedRect {
                rect: brect,
                radius: tile_r.min(6.0),
                fill: Some(surface_variant),
                stroke: None,
                stroke_width: 0.0,
            });
            commands.push(PaintCmd::Icon {
                rect: Rect::new(bx + 7.0, y + 17.0, 12.0, 12.0),
                kind: icon,
                color: on_surface,
                stroke_width: 1.5,
                level: None,
            });
            hit_targets.push(HitTarget {
                rect: brect,
                id: id.to_string(),
            });
            bx += 30.0;
        }
        y += 54.0;
    }

    // 4b. Notification History
    let hist_count = state.notification_history.len();
    commands.push(PaintCmd::RichText {
        rect: Rect::new(PAD_X, y, inner_w - 64.0, 18.0),
        text: format!(
            "{} ({hist_count})",
            t(loc, I18nKey::NotificationsHeader).to_uppercase()
        ),
        color: muted,
        size: 10.0,
        bold: true,
        align: TextAlign::Left,
        max_lines: 1,
    });
    if hist_count > 0 || state.unread_notifications > 0 {
        let clear_rect = Rect::new(PAD_X + inner_w - 72.0, y - 2.0, 72.0, 20.0);
        commands.push(PaintCmd::RoundedRect {
            rect: clear_rect,
            radius: tile_r.min(5.0),
            fill: Some(surface_container),
            stroke: Some(outline_variant),
            stroke_width: 1.0,
        });
        commands.push(PaintCmd::RichText {
            rect: clear_rect,
            text: t(loc, I18nKey::NotificationsClearAll).to_string(),
            color: primary,
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
    y += 24.0;

    if state.notification_history.is_empty() {
        let empty_rect = Rect::new(PAD_X, y, inner_w, 30.0);
        commands.push(PaintCmd::RoundedRect {
            rect: empty_rect,
            radius: tile_r,
            fill: Some(surface_container),
            stroke: None,
            stroke_width: 0.0,
        });
        commands.push(PaintCmd::RichText {
            rect: empty_rect,
            text: t(loc, I18nKey::NotificationsEmpty).to_string(),
            color: muted,
            size: 11.0,
            bold: false,
            align: TextAlign::Center,
            max_lines: 1,
        });
        y += 38.0;
    } else {
        for item in state.notification_history.iter().take(4) {
            let nrect = Rect::new(PAD_X, y, inner_w, 36.0);
            commands.push(PaintCmd::RoundedRect {
                rect: nrect,
                radius: tile_r,
                fill: Some(surface_container),
                stroke: Some(outline_variant),
                stroke_width: 1.0,
            });
            let title = if item.summary.trim().is_empty() {
                item.app_name.as_str()
            } else {
                item.summary.as_str()
            };
            commands.push(PaintCmd::RichText {
                rect: Rect::new(PAD_X + 10.0, y + 4.0, inner_w - 40.0, 16.0),
                text: title.to_string(),
                color: on_surface,
                size: 11.0,
                bold: true,
                align: TextAlign::Left,
                max_lines: 1,
            });
            let body = if item.body.trim().is_empty() {
                item.app_name.as_str()
            } else {
                item.body.trim()
            };
            commands.push(PaintCmd::RichText {
                rect: Rect::new(PAD_X + 10.0, y + 19.0, inner_w - 40.0, 14.0),
                text: body.to_string(),
                color: muted,
                size: 9.5,
                bold: false,
                align: TextAlign::Left,
                max_lines: 1,
            });
            let x_rect = Rect::new(PAD_X + inner_w - 26.0, y + 6.0, 22.0, 24.0);
            commands.push(PaintCmd::Icon {
                rect: Rect::new(x_rect.x + 6.0, x_rect.y + 7.0, 10.0, 10.0),
                kind: IconKind::Close,
                color: muted,
                stroke_width: 1.4,
                level: None,
            });
            hit_targets.push(HitTarget {
                rect: x_rect,
                id: format!("cc:notif:dismiss:{}", item.id),
            });
            y += 40.0;
        }
        y += 4.0;
    }

    // 5. Power Bar (Lock + 2-click inline-confirmed Suspend / Reboot / Poweroff)
    commands.push(PaintCmd::Line {
        x1: PAD_X,
        y1: y,
        x2: CC_WIDTH - PAD_X,
        y2: y,
        color: outline_variant,
        width: 1.0,
    });
    y += 10.0;

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
    let ph = 32.0f32;
    for (idx, (id, key, icon, label)) in power_btns.iter().enumerate() {
        let px = PAD_X + idx as f32 * (pw + gap);
        let rect = Rect::new(px, y, pw, ph);
        let confirming = pending_power == Some(*key);
        let (fill, fg) = if confirming {
            (error_col, on_error)
        } else {
            (surface_container, on_surface)
        };
        commands.push(PaintCmd::RoundedRect {
            rect,
            radius: tile_r,
            fill: Some(fill),
            stroke: if confirming {
                None
            } else {
                Some(outline_variant)
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
                rect: Rect::new(px + 8.0, y + 9.0, 14.0, 14.0),
                kind: *icon,
                color: fg,
                stroke_width: 1.5,
                level: None,
            });
            commands.push(PaintCmd::RichText {
                rect: Rect::new(px + 24.0, y, pw - 28.0, ph),
                text: (*label).to_string(),
                color: fg,
                size: 10.5,
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
    y += ph + 12.0 + border_w;

    let (anchor, margin) = match state.layout_preset {
        LayoutPreset::Omarchy => (
            Anchor::BOTTOM | Anchor::LEFT,
            EdgeInsets {
                bottom: 12,
                left: (state.config.bar.thickness as i32) + state.config.bar.margin_edge + 10,
                ..EdgeInsets::default()
            },
        ),
        LayoutPreset::Island | LayoutPreset::Swiss | LayoutPreset::Ghost => (
            Anchor::TOP | Anchor::RIGHT,
            EdgeInsets {
                top: 48,
                right: 12,
                ..EdgeInsets::default()
            },
        ),
    };

    SurfaceSpec {
        id: SURFACE_ID.to_string(),
        namespace: NAMESPACE.to_string(),
        output: None,
        layer: Layer::Overlay,
        keyboard_interactivity: KeyboardMode::Exclusive,
        anchor,
        exclusive_zone: 0,
        width: CC_WIDTH as u32,
        height: (y.ceil() as u32).max(160),
        margin,
        corner_radius: radius,
        background: bg,
        border_color: primary,
        border_width: border_w,
        commands,
        hit_targets,
        animating: false,
        input_regions: None,
        ime_cursor_rect: None,
        track_pointer_motion: false,
    }
}

#[allow(clippy::too_many_arguments)]
fn push_slider_row(
    commands: &mut Vec<PaintCmd>,
    hit_targets: &mut Vec<HitTarget>,
    y: f32,
    icon: IconKind,
    icon_color: Color,
    icon_target: Option<&str>,
    slider_target: &str,
    pct: u8,
    fill_color: Color,
    container_color: Color,
    track_bg: Color,
    text_color: Color,
    tile_r: f32,
) -> f32 {
    let row_h = 32.0f32;
    let icon_btn = Rect::new(PAD_X, y + 3.0, 26.0, 26.0);
    commands.push(PaintCmd::RoundedRect {
        rect: icon_btn,
        radius: tile_r.min(6.0),
        fill: Some(container_color),
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
    let track_rect = Rect::new(SLIDER_TRACK_X, track_y, SLIDER_TRACK_W, track_h);
    let track_r = tile_r.min(4.0);
    commands.push(PaintCmd::RoundedRect {
        rect: track_rect,
        radius: track_r,
        fill: Some(track_bg),
        stroke: None,
        stroke_width: 0.0,
    });
    let clamped = pct.min(100);
    let fill_w = SLIDER_TRACK_W * (f32::from(clamped) / 100.0);
    if fill_w > 1.0 {
        commands.push(PaintCmd::RoundedRect {
            rect: Rect::new(SLIDER_TRACK_X, track_y, fill_w, track_h),
            radius: track_r,
            fill: Some(fill_color),
            stroke: None,
            stroke_width: 0.0,
        });
    }
    hit_targets.push(HitTarget {
        rect: Rect::new(SLIDER_TRACK_X - 4.0, y, SLIDER_TRACK_W + 8.0, row_h),
        id: slider_target.to_string(),
    });

    commands.push(PaintCmd::Text {
        rect: Rect::new(SLIDER_TRACK_X + SLIDER_TRACK_W + 6.0, y, 36.0, row_h),
        text: format!("{clamped}%"),
        color: text_color,
        size: 10.5,
        bold: true,
        align: TextAlign::Right,
    });

    y + row_h + 6.0
}

#[cfg(test)]
mod tests {
    use super::*;
    use kaze_core::{Config, KeyModifiers, NotificationItem, NotificationUrgency};

    #[test]
    fn cc_toggle_creates_and_destroys_surface_cleanly() {
        let mut state = AppState::new(Config::default());
        let mut ext = ControlCenterExtension::new();
        assert!(ext.surfaces().is_empty());

        {
            let mut ctx = ShellContext::new(&mut state);
            let res = ext.on_ipc("cc-toggle", &[], &mut ctx);
            assert!(matches!(res, IpcResult::Handled { ok: true, .. }));
        }
        assert!(state.cc_open);
        let specs = ext.surfaces();
        assert_eq!(specs.len(), 1);
        assert_eq!(specs[0].namespace, "kaze-cc");
        assert_eq!(specs[0].layer, Layer::Overlay);

        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_event(
                &SystemEvent::KeyInput {
                    surface_id: SURFACE_ID.into(),
                    key: KeyEvent {
                        keysym: KEY_ESCAPE,
                        utf8: None,
                        modifiers: KeyModifiers::default(),
                        pressed: true,
                    },
                },
                &mut ctx,
            );
        }
        assert!(!state.cc_open);
        assert!(ext.surfaces().is_empty());
    }

    #[test]
    fn toggles_sliders_and_power_two_step_confirm_emit_expected_actions() {
        let mut state = AppState::new(Config::default());
        state.backlight.present = true;
        state.backlight.percentage = 60;
        let mut ext = ControlCenterExtension::new();

        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_ipc("cc-open", &[], &mut ctx);

            ext.on_event(
                &SystemEvent::PointerClick {
                    surface_id: SURFACE_ID.into(),
                    target_id: "cc:toggle:caffeine".into(),
                    button: PointerButton::Left,
                },
                &mut ctx,
            );
            assert!(ctx.actions.contains(&ShellAction::SetCaffeine(true)));

            ctx.actions.clear();
            ext.on_event(
                &SystemEvent::PointerDrag {
                    surface_id: SURFACE_ID.into(),
                    target_id: "cc:slider:vol".into(),
                    x: SLIDER_TRACK_X + SLIDER_TRACK_W * 0.5,
                    y: 170.0,
                },
                &mut ctx,
            );
            assert_eq!(ctx.actions, vec![ShellAction::AudioSetVolume(50)]);

            // First power click arms inline confirm; does NOT power off immediately.
            ctx.actions.clear();
            ext.on_event(
                &SystemEvent::PointerClick {
                    surface_id: SURFACE_ID.into(),
                    target_id: "cc:power:reboot".into(),
                    button: PointerButton::Left,
                },
                &mut ctx,
            );
            assert!(!ctx
                .actions
                .iter()
                .any(|a| matches!(a, ShellAction::SystemPower(_))));

            // Second click confirms and emits SystemPower + closes surface.
            ctx.actions.clear();
            ext.on_event(
                &SystemEvent::PointerClick {
                    surface_id: SURFACE_ID.into(),
                    target_id: "cc:power:reboot".into(),
                    button: PointerButton::Left,
                },
                &mut ctx,
            );
            assert!(ctx
                .actions
                .contains(&ShellAction::SystemPower("reboot".into())));

            // Scroll on sliders adjusts by 5%, or 1% when Shift is held.
            ctx.actions.clear();
            ext.on_event(
                &SystemEvent::PointerScroll {
                    surface_id: SURFACE_ID.into(),
                    target_id: "cc:slider:vol".into(),
                    delta_y: -1.0,
                    modifiers: KeyModifiers::default(),
                },
                &mut ctx,
            );
            ext.on_event(
                &SystemEvent::PointerScroll {
                    surface_id: SURFACE_ID.into(),
                    target_id: "cc:slider:bright".into(),
                    delta_y: 1.0,
                    modifiers: KeyModifiers {
                        shift: true,
                        ..KeyModifiers::default()
                    },
                },
                &mut ctx,
            );
            assert_eq!(
                ctx.actions,
                vec![
                    ShellAction::AudioStepVolume(5),
                    ShellAction::BacklightStep(-1),
                ]
            );
        }
        assert!(ext.surfaces().is_empty());
    }

    #[test]
    fn hides_brightness_slider_without_backlight_and_shows_notif_history() {
        let mut state = AppState::new(Config::default());
        state.backlight.present = false;
        state.notification_history.push(NotificationItem {
            id: 42,
            app_name: "kaze".into(),
            summary: "Thông báo mới 🔔".into(),
            body: "Xin chào".into(),
            app_icon: String::new(),
            urgency: NotificationUrgency::Normal,
            actions: Vec::new(),
            expire_timeout_ms: -1,
            resident: false,
            transient: false,
            sync_tag: None,
            timestamp_epoch_secs: 0,
            progress_value: None,
        });
        let mut ext = ControlCenterExtension::new();
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_ipc("cc-open", &[], &mut ctx);
        }
        let spec = &ext.surfaces()[0];
        assert!(!spec.hit_targets.iter().any(|t| t.id == "cc:slider:bright"));
        assert!(spec
            .hit_targets
            .iter()
            .any(|t| t.id == "cc:notif:dismiss:42"));
    }
}
