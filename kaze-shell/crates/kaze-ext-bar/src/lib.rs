#![deny(clippy::unwrap_used)]

use kaze_core::{
    Anchor, AppState, BarPosition, Color, DirtyFlags, DisplayStatus, EdgeInsets, HitTarget,
    IconKind, IpcResult, KazeExtension, KeyboardMode, Layer, LayoutPreset,
    NetworkKind, OutputInfo, PaintCmd, PointerButton, Rect, ShellAction, ShellContext, Spring,
    SurfaceSpec, SystemEvent, TextAlign,
};
use std::collections::{BTreeMap, HashMap};

const GHOST_PEEK_TIMER_ID: &str = "bar:ghost-peek-hide";
const GHOST_PEEK_MS: u64 = 2500;

/// Production bar extension built strictly against the `KazeExtension` contract:
/// adapts live across all 4 layout presets (`omarchy`, `island`, `swiss`, `ghost`)
/// with spring-animated workspace/peek transitions that auto-stop on convergence.
pub struct BarExtension {
    cached_specs: Vec<SurfaceSpec>,
    ws_springs: HashMap<String, Spring>,
    ghost_peeking: bool,
    ghost_spring: Spring,
}

impl Default for BarExtension {
    fn default() -> Self {
        Self::new()
    }
}

impl BarExtension {
    pub fn new() -> Self {
        Self {
            cached_specs: Vec::new(),
            ws_springs: HashMap::new(),
            ghost_peeking: false,
            ghost_spring: Spring::snappy(-42.0),
        }
    }

    fn ghost_should_show(&self, state: &AppState) -> bool {
        self.ghost_peeking || state.display_status.is_active() || state.active_notifications > 0
    }

    fn sync_springs(&mut self, state: &AppState, snap: bool) {
        let hide_offset = -(state.config.bar.thickness as f32);
        let ghost_target = if self.ghost_should_show(state) {
            0.0
        } else {
            hide_offset
        };
        if state.layout_preset == LayoutPreset::Ghost {
            if snap {
                self.ghost_spring.snap(ghost_target);
            } else {
                self.ghost_spring.set_target(ghost_target);
            }
        } else {
            self.ghost_spring.snap(hide_offset);
        }

        self.ws_springs
            .retain(|name, _| state.outputs.contains_key(name));
        for output in state.outputs.values() {
            let target_idx = workspace_focus_index(state, &output.name) as f32;
            let entry = self
                .ws_springs
                .entry(output.name.clone())
                .or_insert_with(|| Spring::snappy(target_idx));
            if snap {
                entry.snap(target_idx);
            } else {
                entry.set_target(target_idx);
            }
        }
    }

    fn rebuild(&mut self, state: &AppState) {
        self.cached_specs.clear();
        if !state.config.bar.enabled || state.hide_all_bars {
            return;
        }

        if state.layout_preset == LayoutPreset::Ghost {
            let hide_offset = -(state.config.bar.thickness as f32);
            let show_now = self.ghost_should_show(state);
            if !show_now
                && self.ghost_spring.is_settled()
                && self.ghost_spring.value <= hide_offset + 0.5
            {
                return;
            }
        }

        for output in state.outputs.values() {
            if state.is_bar_hidden(&output.name) {
                continue;
            }
            let ws_spring = self.ws_springs.get(&output.name).copied();
            let spec = match state.layout_preset {
                LayoutPreset::Omarchy => build_bar_surface(state, output, ws_spring, None),
                LayoutPreset::Island => build_island_bar_surface(state, output),
                LayoutPreset::Swiss => build_swiss_bar_surface(state, output),
                LayoutPreset::Ghost => {
                    build_bar_surface(state, output, ws_spring, Some(&self.ghost_spring))
                }
            };
            self.cached_specs.push(spec);
        }
    }
}

impl KazeExtension for BarExtension {
    fn id(&self) -> &'static str {
        "bar"
    }

    fn on_init(&mut self, ctx: &mut ShellContext) {
        self.sync_springs(ctx.state, true);
        self.rebuild(ctx.state);
    }

    fn on_event(&mut self, event: &SystemEvent, ctx: &mut ShellContext) -> DirtyFlags {
        match event {
            SystemEvent::OutputAdded(_)
            | SystemEvent::OutputUpdated(_)
            | SystemEvent::OutputRemoved { .. } => {
                self.sync_springs(ctx.state, true);
                self.rebuild(ctx.state);
                DirtyFlags::BAR | DirtyFlags::LAYOUT
            }
            SystemEvent::FrameTick {
                surface_id,
                dt_secs,
            } => {
                let Some(out_name) = surface_id.strip_prefix("bar:") else {
                    return DirtyFlags::NONE;
                };
                let mut changed = false;
                if let Some(sp) = self.ws_springs.get_mut(out_name) {
                    if !sp.is_settled() {
                        sp.step(*dt_secs);
                        changed = true;
                    }
                }
                if ctx.state.layout_preset == LayoutPreset::Ghost && !self.ghost_spring.is_settled()
                {
                    self.ghost_spring.step(*dt_secs);
                    changed = true;
                }
                if changed {
                    self.rebuild(ctx.state);
                    DirtyFlags::BAR
                } else {
                    DirtyFlags::NONE
                }
            }
            SystemEvent::LayoutPresetChanged(_) => {
                self.ghost_peeking = false;
                ctx.push_action(ShellAction::CancelTimer {
                    id: GHOST_PEEK_TIMER_ID.to_string(),
                });
                self.sync_springs(ctx.state, true);
                self.rebuild(ctx.state);
                DirtyFlags::BAR | DirtyFlags::LAYOUT
            }
            SystemEvent::HyprSynced { .. }
            | SystemEvent::HyprWorkspaceChanged { .. }
            | SystemEvent::HyprFocusedMonitor { .. } => {
                self.sync_springs(ctx.state, false);
                self.rebuild(ctx.state);
                DirtyFlags::BAR
            }
            SystemEvent::HyprConnectionChanged { .. }
            | SystemEvent::ClockTick(_)
            | SystemEvent::NetworkChanged(_)
            | SystemEvent::BluetoothChanged(_)
            | SystemEvent::BatteryChanged(_)
            | SystemEvent::AudioChanged { .. }
            | SystemEvent::MediaChanged(_)
            | SystemEvent::DndChanged(_)
            | SystemEvent::NightLightChanged { .. }
            | SystemEvent::CaffeineChanged(_)
            | SystemEvent::ControlCenterChanged(_)
            | SystemEvent::TrayItemsChanged(_)
            | SystemEvent::NotificationsCountChanged(_)
            | SystemEvent::NotificationClearAll => {
                self.sync_springs(ctx.state, false);
                self.rebuild(ctx.state);
                DirtyFlags::BAR
            }
            SystemEvent::TimerFired { id } if id == GHOST_PEEK_TIMER_ID => {
                if self.ghost_peeking {
                    self.ghost_peeking = false;
                    self.sync_springs(ctx.state, false);
                    self.rebuild(ctx.state);
                    DirtyFlags::BAR | DirtyFlags::LAYOUT
                } else {
                    DirtyFlags::NONE
                }
            }
            SystemEvent::ConfigReloaded | SystemEvent::ThemeChanged(_) => {
                self.sync_springs(ctx.state, true);
                self.rebuild(ctx.state);
                DirtyFlags::BAR | DirtyFlags::LAYOUT | DirtyFlags::THEME
            }
            SystemEvent::PointerClick {
                surface_id,
                target_id,
                button,
            } => {
                if !surface_id.starts_with("bar:") {
                    return DirtyFlags::NONE;
                }
                if let Some(ws_str) = target_id.strip_prefix("ws:") {
                    if *button == PointerButton::Left {
                        if let Ok(ws_id) = ws_str.parse::<i32>() {
                            ctx.push_action(ShellAction::HyprDispatch(format!(
                                "workspace {ws_id}"
                            )));
                        }
                    }
                    return DirtyFlags::NONE;
                }
                if let Some(idx_str) = target_id.strip_prefix("tray:item:") {
                    if let Ok(idx) = idx_str.parse::<usize>() {
                        if let Some(item) = ctx.state.tray_items.get(idx) {
                            match button {
                                PointerButton::Left => {
                                    ctx.push_action(ShellAction::TrayActivate {
                                        service: item.service.clone(),
                                        object_path: item.object_path.clone(),
                                        x: 0,
                                        y: 0,
                                        secondary: false,
                                    });
                                }
                                PointerButton::Right => {
                                    if !item.menu_path.is_empty() {
                                        ctx.push_action(ShellAction::TrayOpenMenu {
                                            service: item.service.clone(),
                                            menu_path: item.menu_path.clone(),
                                        });
                                    } else {
                                        ctx.push_action(ShellAction::TrayActivate {
                                            service: item.service.clone(),
                                            object_path: item.object_path.clone(),
                                            x: 0,
                                            y: 0,
                                            secondary: true,
                                        });
                                    }
                                }
                                PointerButton::Middle => {
                                    ctx.push_action(ShellAction::TrayActivate {
                                        service: item.service.clone(),
                                        object_path: item.object_path.clone(),
                                        x: 0,
                                        y: 0,
                                        secondary: true,
                                    });
                                }
                            }
                        }
                    }
                    return DirtyFlags::NONE;
                }
                match target_id.as_str() {
                    "cc" => {
                        if *button == PointerButton::Left {
                            ctx.push_action(ShellAction::ToggleControlCenter);
                        }
                    }
                    "display" => {
                        let cmd = match button {
                            PointerButton::Left => Some(&ctx.state.config.display.left_click_cmd),
                            PointerButton::Right => Some(&ctx.state.config.display.right_click_cmd),
                            PointerButton::Middle => None,
                        };
                        if let Some(parts) = cmd {
                            if let Some((program, args)) = parts.split_first() {
                                ctx.push_action(ShellAction::SpawnCommand {
                                    program: program.clone(),
                                    args: args.to_vec(),
                                });
                            }
                        }
                    }
                    "net" => {
                        if *button == PointerButton::Left {
                            ctx.push_action(ShellAction::SpawnDetachedApp {
                                program: "kaze-tui".to_string(),
                                args: vec!["wifi".to_string()],
                            });
                        }
                    }
                    "vol" => match button {
                        PointerButton::Left => {
                            ctx.push_action(ShellAction::SpawnDetachedApp {
                                program: "kaze-tui".to_string(),
                                args: vec!["audio".to_string()],
                            });
                        }
                        PointerButton::Right => {
                            ctx.push_action(ShellAction::AudioToggleMute);
                        }
                        PointerButton::Middle => {
                            ctx.push_action(ShellAction::AudioToggleMicMute);
                        }
                    },
                    "notifications" => match button {
                        PointerButton::Left => {
                            ctx.push_action(ShellAction::SetDnd(!ctx.state.dnd));
                        }
                        PointerButton::Right => {
                            ctx.push_action(ShellAction::ClearNotifications);
                        }
                        PointerButton::Middle => {}
                    },
                    _ => {}
                }
                DirtyFlags::NONE
            }
            SystemEvent::PointerScroll {
                surface_id,
                target_id,
                delta_y,
                modifiers,
            } => {
                if surface_id.starts_with("bar:") && target_id == "vol" {
                    // Wayland negative delta_y = scroll up (raise volume), positive = scroll down.
                    let mag = if modifiers.shift { 1 } else { 5 };
                    let step = if *delta_y < 0.0 { mag } else { -mag };
                    ctx.push_action(ShellAction::AudioStepVolume(step));
                }
                DirtyFlags::NONE
            }
            SystemEvent::KeyInput { .. }
            | SystemEvent::ImeInput { .. }
            | SystemEvent::PointerClickAt { .. }
            | SystemEvent::PointerDrag { .. }
            | SystemEvent::TimerFired { .. }
            | SystemEvent::BacklightChanged { .. }
            | SystemEvent::NotificationReceived(_)
            | SystemEvent::NotificationCloseRequested { .. }
            | SystemEvent::NotificationDismissHistory { .. }
            | SystemEvent::NotificationsBusStatus { .. }
            | SystemEvent::TrayBusStatus { .. }
            | SystemEvent::TrayMenuLoaded(_)
            | SystemEvent::WallpaperReady { .. }
            | SystemEvent::WallpaperFailed { .. }
            | SystemEvent::SurfaceClosed { .. }
            | SystemEvent::KeyboardFocusLost { .. }
            | SystemEvent::ApplicationsChanged
            | SystemEvent::UserAccountChanged(_)
            | SystemEvent::OfflineModeChanged(_)
            | SystemEvent::LocaleChanged(_)
            | SystemEvent::ClipboardTextPasted { .. }
            | SystemEvent::ClipboardOfferCaptured { .. }
            | SystemEvent::PowerProfileChanged(_)
            | SystemEvent::PrivacyChanged(_)
            | SystemEvent::AudioSpectrum(_)
            | SystemEvent::IdleTimeout { .. }
            | SystemEvent::IdleResumed { .. }
            | SystemEvent::PrepareForSleep(_)
            | SystemEvent::SessionLockRequested
            | SystemEvent::SessionUnlockRequested
            | SystemEvent::LockWorkerCommitted
            | SystemEvent::LockWorkerExited
            | SystemEvent::PowerCapabilitiesChanged(_) => DirtyFlags::NONE,
        }
    }

    fn on_ipc(&mut self, cmd: &str, args: &[String], ctx: &mut ShellContext) -> IpcResult {
        match cmd {
            "bar-hide" => match args {
                [] => {
                    ctx.state.hide_all_bars = true;
                    self.rebuild(ctx.state);
                    IpcResult::Handled {
                        ok: true,
                        message: "hidden all bars".into(),
                        dirty: DirtyFlags::BAR | DirtyFlags::LAYOUT,
                    }
                }
                [monitor] => {
                    ctx.state.hidden_bars.insert(monitor.clone());
                    self.rebuild(ctx.state);
                    IpcResult::Handled {
                        ok: true,
                        message: format!("hidden bar on {monitor}"),
                        dirty: DirtyFlags::BAR | DirtyFlags::LAYOUT,
                    }
                }
                [_bar_name, monitor, ..] => {
                    ctx.state.hidden_bars.insert(monitor.clone());
                    self.rebuild(ctx.state);
                    IpcResult::Handled {
                        ok: true,
                        message: format!("hidden bar on {monitor}"),
                        dirty: DirtyFlags::BAR | DirtyFlags::LAYOUT,
                    }
                }
            },
            "bar-show" => match args {
                [] => {
                    ctx.state.hide_all_bars = false;
                    ctx.state.hidden_bars.clear();
                    self.rebuild(ctx.state);
                    IpcResult::Handled {
                        ok: true,
                        message: "shown all bars".into(),
                        dirty: DirtyFlags::BAR | DirtyFlags::LAYOUT,
                    }
                }
                [monitor] => {
                    ctx.state.hide_all_bars = false;
                    ctx.state.hidden_bars.remove(monitor);
                    self.rebuild(ctx.state);
                    IpcResult::Handled {
                        ok: true,
                        message: format!("shown bar on {monitor}"),
                        dirty: DirtyFlags::BAR | DirtyFlags::LAYOUT,
                    }
                }
                [_bar_name, monitor, ..] => {
                    ctx.state.hide_all_bars = false;
                    ctx.state.hidden_bars.remove(monitor);
                    self.rebuild(ctx.state);
                    IpcResult::Handled {
                        ok: true,
                        message: format!("shown bar on {monitor}"),
                        dirty: DirtyFlags::BAR | DirtyFlags::LAYOUT,
                    }
                }
            },
            "bar-peek" => {
                if ctx.state.layout_preset != LayoutPreset::Ghost {
                    return IpcResult::Handled {
                        ok: true,
                        message: format!(
                            "bar visible in {} preset",
                            ctx.state.layout_preset.as_str()
                        ),
                        dirty: DirtyFlags::NONE,
                    };
                }
                let next = match args.first().map(String::as_str) {
                    Some("on" | "show") => true,
                    Some("off" | "hide") => false,
                    _ => !self.ghost_peeking,
                };
                self.ghost_peeking = next;
                if next {
                    ctx.push_action(ShellAction::ScheduleTimer {
                        id: GHOST_PEEK_TIMER_ID.to_string(),
                        after_ms: GHOST_PEEK_MS,
                    });
                } else {
                    ctx.push_action(ShellAction::CancelTimer {
                        id: GHOST_PEEK_TIMER_ID.to_string(),
                    });
                }
                self.sync_springs(ctx.state, false);
                self.rebuild(ctx.state);
                IpcResult::Handled {
                    ok: true,
                    message: if next {
                        "peeking".into()
                    } else {
                        "hidden".into()
                    },
                    dirty: DirtyFlags::BAR | DirtyFlags::LAYOUT,
                }
            }
            "display-status" => {
                let mode = args.first().map(String::as_str).unwrap_or("idle");
                let detail = args.get(1).cloned().unwrap_or_default();
                ctx.state.display_status = match mode {
                    "idle" | "off" | "none" | "clear" => DisplayStatus::Idle,
                    "present" | "live" => DisplayStatus::Present { detail },
                    "virtual-share" | "share" => DisplayStatus::VirtualShare { detail },
                    "virtual-control" | "control" => DisplayStatus::VirtualControl { detail },
                    "recording" | "rec" => DisplayStatus::Recording { detail },
                    other => {
                        return IpcResult::Handled {
                            ok: false,
                            message: format!(
                                "unknown display-status '{other}' (expected idle|present|virtual-share|virtual-control|recording)"
                            ),
                            dirty: DirtyFlags::NONE,
                        };
                    }
                };
                self.sync_springs(ctx.state, false);
                self.rebuild(ctx.state);
                IpcResult::Handled {
                    ok: true,
                    message: format!("display-status={}", ctx.state.display_status.kind_name()),
                    dirty: DirtyFlags::BAR,
                }
            }
            _ => IpcResult::Unhandled,
        }
    }

    fn surfaces(&self) -> Vec<SurfaceSpec> {
        self.cached_specs.clone()
    }
}

fn collect_workspaces(state: &AppState, output_name: &str) -> Vec<(i32, bool, bool)> {
    let active_ws = state.active_workspace_for_output(output_name);
    let mut entries: BTreeMap<i32, bool> = BTreeMap::new();
    for id in 1..=(state.config.bar.persistent_workspaces as i32) {
        entries.insert(id, false);
    }
    for ws in &state.workspaces {
        if ws.id <= 0 {
            continue;
        }
        let on_this_output = ws.monitor.is_empty() || ws.monitor == output_name;
        if on_this_output || entries.contains_key(&ws.id) {
            let entry = entries.entry(ws.id).or_insert(false);
            if ws.windows > 0 {
                *entry = true;
            }
        }
    }
    if active_ws > 0 {
        entries.entry(active_ws).or_insert(false);
    }

    entries
        .into_iter()
        .map(|(id, occupied)| (id, id == active_ws, occupied))
        .collect()
}

struct SlotVisual {
    id: String,
    icon: Option<IconKind>,
    image: Option<(u32, u32, std::sync::Arc<[u8]>)>,
    monogram: Option<String>,
    icon_color: Color,
    fill: Color,
    stroke: Option<Color>,
    level: Option<u8>,
    dot: Option<Color>,
}

fn active_end_slots(state: &AppState) -> Vec<SlotVisual> {
    let colors = state.palette.for_mode(state.theme_mode);
    let primary = colors.primary_color();
    let secondary = colors.secondary_color();
    let tertiary = colors.tertiary_color();
    let error_col = colors.error_color();
    let on_surface = colors.on_surface_color();
    let muted = colors.on_surface_variant_color();
    let surface_container = colors.surface_container_color();
    let surface_variant = colors.surface_variant_color();

    let mut slots = Vec::new();
    for name in &state.config.bar.end_slots {
        match name.as_str() {
            "tray" => {
                for (idx, item) in state.tray_items.iter().take(6).enumerate() {
                    let image = item
                        .icon_rgba
                        .as_ref()
                        .filter(|_| item.icon_width > 0 && item.icon_height > 0)
                        .map(|buf| {
                            (
                                item.icon_width,
                                item.icon_height,
                                std::sync::Arc::clone(buf),
                            )
                        });
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
                    slots.push(SlotVisual {
                        id: format!("tray:item:{idx}"),
                        icon: None,
                        image,
                        monogram,
                        icon_color: on_surface,
                        fill: surface_container,
                        stroke: None,
                        level: None,
                        dot: None,
                    });
                }
            }
            "display" => {
                let active = state.display_status.is_active();
                slots.push(SlotVisual {
                    id: "display".into(),
                    icon: Some(IconKind::Display),
                    image: None,
                    monogram: None,
                    icon_color: if active { primary } else { on_surface },
                    fill: if active {
                        surface_variant
                    } else {
                        surface_container
                    },
                    stroke: if active { Some(primary) } else { None },
                    level: None,
                    dot: status_dot_color(&state.display_status, primary, secondary, error_col),
                });
            }
            "net" => {
                let (icon, icon_color, level) =
                    if !state.network.available || !state.network.connected {
                        (IconKind::WifiOff, muted, None)
                    } else {
                        match state.network.kind {
                            NetworkKind::Wifi => {
                                (IconKind::Wifi, on_surface, Some(state.network.strength))
                            }
                            NetworkKind::Ethernet => (IconKind::Ethernet, on_surface, None),
                            NetworkKind::Disconnected => (IconKind::WifiOff, muted, None),
                        }
                    };
                slots.push(SlotVisual {
                    id: "net".into(),
                    icon: Some(icon),
                    image: None,
                    monogram: None,
                    icon_color,
                    fill: surface_container,
                    stroke: None,
                    level,
                    dot: None,
                });
            }
            "vol" => {
                let (icon, icon_color, level) = if state.audio.muted || state.audio.volume_pct == 0
                {
                    (IconKind::VolumeMuted, error_col, Some(0))
                } else {
                    (IconKind::Volume, on_surface, Some(state.audio.volume_pct))
                };
                slots.push(SlotVisual {
                    id: "vol".into(),
                    icon: Some(icon),
                    image: None,
                    monogram: None,
                    icon_color,
                    fill: surface_container,
                    stroke: None,
                    level,
                    dot: if state.audio.mic_muted {
                        Some(tertiary)
                    } else {
                        None
                    },
                });
            }
            "bat" => {
                if !state.battery.present {
                    continue;
                }
                let (icon, icon_color) = if state.battery.charging {
                    (IconKind::BatteryCharging, secondary)
                } else if state.battery.low {
                    (IconKind::Battery, error_col)
                } else {
                    (IconKind::Battery, on_surface)
                };
                slots.push(SlotVisual {
                    id: "bat".into(),
                    icon: Some(icon),
                    image: None,
                    monogram: None,
                    icon_color,
                    fill: surface_container,
                    stroke: if state.battery.low {
                        Some(error_col)
                    } else {
                        None
                    },
                    level: Some(state.battery.percentage),
                    dot: None,
                });
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
                    let badge = if state.unread_notifications > 0 {
                        Some(primary)
                    } else {
                        None
                    };
                    (IconKind::Bell, on_surface, surface_container, None, badge)
                };
                slots.push(SlotVisual {
                    id: "notifications".into(),
                    icon: Some(icon),
                    image: None,
                    monogram: None,
                    icon_color,
                    fill,
                    stroke,
                    level: None,
                    dot,
                });
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
                slots.push(SlotVisual {
                    id: "cc".into(),
                    icon: Some(IconKind::Sliders),
                    image: None,
                    monogram: None,
                    icon_color: if state.cc_open { primary } else { on_surface },
                    fill: if active {
                        surface_variant
                    } else {
                        surface_container
                    },
                    stroke: if state.cc_open { Some(primary) } else { None },
                    level: None,
                    dot,
                });
            }
            _ => {}
        }
    }
    slots
}

fn push_slot_visual(
    commands: &mut Vec<PaintCmd>,
    slot: &SlotVisual,
    icon_rect: Rect,
    slot_rect: Rect,
) {
    if let Some((w, h, ref rgba)) = slot.image {
        let side = icon_rect.w.min(icon_rect.h).max(14.0);
        let img_rect = Rect::new(
            slot_rect.x + (slot_rect.w - side) * 0.5,
            slot_rect.y + (slot_rect.h - side) * 0.5,
            side,
            side,
        );
        commands.push(PaintCmd::Image {
            rect: img_rect,
            width: w,
            height: h,
            rgba_premul: std::sync::Arc::clone(rgba),
        });
    } else if let Some(kind) = slot.icon {
        commands.push(PaintCmd::Icon {
            rect: icon_rect,
            kind,
            color: slot.icon_color,
            stroke_width: 1.5,
            level: slot.level,
        });
    } else if let Some(ref mono) = slot.monogram {
        commands.push(PaintCmd::Text {
            rect: slot_rect,
            text: mono.clone(),
            color: slot.icon_color,
            size: 11.0,
            bold: true,
            align: TextAlign::Center,
        });
    }
}

fn workspace_focus_index(state: &AppState, output_name: &str) -> usize {
    collect_workspaces(state, output_name)
        .iter()
        .position(|(_, focused, _)| *focused)
        .unwrap_or(0)
}

fn build_bar_surface(
    state: &AppState,
    output: &OutputInfo,
    ws_spring: Option<Spring>,
    ghost_spring: Option<&Spring>,
) -> SurfaceSpec {
    let bar = &state.config.bar;
    let colors = state.palette.for_mode(state.theme_mode);
    let is_ghost = ghost_spring.is_some();
    let is_vertical = is_ghost || bar.position.is_vertical();
    let is_island = !is_ghost && (bar.island_mode || bar.length > 0);
    let shift_x = ghost_spring.map_or(0.0, |s| s.value);

    let (anchor, width, height, margin, logical_w, logical_h) = match bar.position {
        BarPosition::Left => {
            if is_island {
                let h = if bar.length > 0 {
                    bar.length
                } else {
                    (output.height - bar.margin_ends * 2).max(200) as u32
                };
                (
                    Anchor::LEFT,
                    bar.thickness,
                    h,
                    EdgeInsets {
                        left: bar.margin_edge,
                        ..EdgeInsets::default()
                    },
                    bar.thickness,
                    h,
                )
            } else {
                let lh = (output.height - bar.margin_ends * 2).max(200) as u32;
                (
                    Anchor::LEFT | Anchor::TOP | Anchor::BOTTOM,
                    bar.thickness,
                    0,
                    EdgeInsets {
                        top: bar.margin_ends,
                        bottom: bar.margin_ends,
                        left: bar.margin_edge,
                        right: 0,
                    },
                    bar.thickness,
                    lh,
                )
            }
        }
        BarPosition::Right => {
            if is_island {
                let h = if bar.length > 0 {
                    bar.length
                } else {
                    (output.height - bar.margin_ends * 2).max(200) as u32
                };
                (
                    Anchor::RIGHT,
                    bar.thickness,
                    h,
                    EdgeInsets {
                        right: bar.margin_edge,
                        ..EdgeInsets::default()
                    },
                    bar.thickness,
                    h,
                )
            } else {
                let lh = (output.height - bar.margin_ends * 2).max(200) as u32;
                (
                    Anchor::RIGHT | Anchor::TOP | Anchor::BOTTOM,
                    bar.thickness,
                    0,
                    EdgeInsets {
                        top: bar.margin_ends,
                        bottom: bar.margin_ends,
                        left: 0,
                        right: bar.margin_edge,
                    },
                    bar.thickness,
                    lh,
                )
            }
        }
        BarPosition::Top => {
            if is_island {
                let w = if bar.length > 0 { bar.length } else { 440 };
                (
                    Anchor::TOP,
                    w,
                    bar.thickness,
                    EdgeInsets {
                        top: bar.margin_edge,
                        ..EdgeInsets::default()
                    },
                    w,
                    bar.thickness,
                )
            } else {
                let lw = (output.width - bar.margin_ends * 2).max(320) as u32;
                (
                    Anchor::TOP | Anchor::LEFT | Anchor::RIGHT,
                    0,
                    bar.thickness,
                    EdgeInsets {
                        top: bar.margin_edge,
                        bottom: 0,
                        left: bar.margin_ends,
                        right: bar.margin_ends,
                    },
                    lw,
                    bar.thickness,
                )
            }
        }
        BarPosition::Bottom => {
            if is_island {
                let w = if bar.length > 0 { bar.length } else { 440 };
                (
                    Anchor::BOTTOM,
                    w,
                    bar.thickness,
                    EdgeInsets {
                        bottom: bar.margin_edge,
                        ..EdgeInsets::default()
                    },
                    w,
                    bar.thickness,
                )
            } else {
                let lw = (output.width - bar.margin_ends * 2).max(320) as u32;
                (
                    Anchor::BOTTOM | Anchor::LEFT | Anchor::RIGHT,
                    0,
                    bar.thickness,
                    EdgeInsets {
                        top: 0,
                        bottom: bar.margin_edge,
                        left: bar.margin_ends,
                        right: bar.margin_ends,
                    },
                    lw,
                    bar.thickness,
                )
            }
        }
    };

    let exclusive_zone = if is_ghost {
        0
    } else if bar.exclusive && !is_island {
        bar.thickness as i32
    } else {
        0
    };

    let namespace = if !is_ghost && bar.island_mode {
        "kaze-island".to_string()
    } else {
        format!("kaze-bar-{}", output.name)
    };

    let mut commands = Vec::new();
    let mut hit_targets = Vec::new();
    let workspaces = collect_workspaces(state, &output.name);
    let end_slots = active_end_slots(state);

    let bg = colors.surface_color().with_opacity(bar.background_opacity);
    let border_color = colors.outline_variant_color();
    let primary = colors.primary_color();
    let on_primary = colors.on_primary_color();
    let secondary = colors.secondary_color();
    let on_surface = colors.on_surface_color();
    let muted = colors.on_surface_variant_color();
    let surface_container = colors.surface_container_color();
    let surface_variant = colors.surface_variant_color();

    let pad = 6.0f32;
    let spacing = 5.0f32;
    let inner_radius = if bar.corner_radius > 0.0 {
        (bar.corner_radius * 0.4).min(10.0)
    } else {
        0.0
    };

    if is_vertical {
        let bw = logical_w as f32;
        let bh = logical_h as f32;
        let cell_w = (bw - pad * 2.0).max(16.0);
        let cell_h = cell_w.min(30.0);

        if is_ghost {
            commands.push(PaintCmd::RoundedRect {
                rect: Rect::new(shift_x, 0.0, bw, bh),
                radius: 0.0,
                fill: Some(bg),
                stroke: Some(border_color),
                stroke_width: bar.border_width.max(1.0),
            });
        }

        // 1. Start cluster: Workspaces
        let ws_start_y = pad + bar.border_width;
        let mut cur_y = ws_start_y;
        for (ws_id, focused, occupied) in &workspaces {
            let rect = Rect::new(pad + shift_x, cur_y, cell_w, cell_h);
            let (fill, text_col, stroke) = if *focused {
                (Some(primary), on_primary, None)
            } else if *occupied {
                (Some(surface_variant), on_surface, Some(secondary))
            } else {
                (Some(surface_container), muted, None)
            };
            commands.push(PaintCmd::RoundedRect {
                rect,
                radius: inner_radius,
                fill,
                stroke,
                stroke_width: if stroke.is_some() { 1.0 } else { 0.0 },
            });
            commands.push(PaintCmd::Text {
                rect,
                text: ws_id.to_string(),
                color: text_col,
                size: 12.0,
                bold: *focused,
                align: TextAlign::Center,
            });
            hit_targets.push(HitTarget {
                rect,
                id: format!("ws:{ws_id}"),
            });
            cur_y += cell_h + spacing;
        }

        // Spring-animated crisp active-workspace indicator rail along the inner left edge
        if let Some(sp) = ws_spring {
            let ind_y = ws_start_y + sp.value * (cell_h + spacing) + 4.0;
            commands.push(PaintCmd::RoundedRect {
                rect: Rect::new(
                    shift_x + bar.border_width,
                    ind_y,
                    2.5,
                    (cell_h - 8.0).max(8.0),
                ),
                radius: inner_radius.min(1.5),
                fill: Some(primary),
                stroke: None,
                stroke_width: 0.0,
            });
        }

        // 2. Center cluster: Stacked vertical 24h Clock (HH / MM)
        let center_y = bh * 0.5;
        let hh_rect = Rect::new(pad + shift_x, center_y - 18.0, cell_w, 17.0);
        let mm_rect = Rect::new(pad + shift_x, center_y + 1.0, cell_w, 17.0);
        commands.push(PaintCmd::Text {
            rect: hh_rect,
            text: state.clock.format_hh(),
            color: on_surface,
            size: 13.0,
            bold: true,
            align: TextAlign::Center,
        });
        commands.push(PaintCmd::Text {
            rect: mm_rect,
            text: state.clock.format_mm(),
            color: muted,
            size: 13.0,
            bold: false,
            align: TextAlign::Center,
        });

        // 3. End cluster: Configurable status slots stacked from bottom upward
        let slot_h = cell_w.min(30.0);
        let total_slots_h =
            end_slots.len() as f32 * slot_h + (end_slots.len().saturating_sub(1)) as f32 * spacing;
        let mut slot_y = (bh - pad - bar.border_width - total_slots_h).max(center_y + 24.0);

        for slot in end_slots {
            let slot_rect = Rect::new(pad + shift_x, slot_y, cell_w, slot_h);
            commands.push(PaintCmd::RoundedRect {
                rect: slot_rect,
                radius: inner_radius,
                fill: Some(slot.fill),
                stroke: slot.stroke,
                stroke_width: if slot.stroke.is_some() { 1.0 } else { 0.0 },
            });

            let icon_w = (cell_w * 0.56).clamp(12.0, 17.0);
            let icon_h = (slot_h * 0.52).clamp(10.0, 15.0);
            let icon_rect = Rect::new(
                slot_rect.x + (slot_rect.w - icon_w) * 0.5,
                slot_rect.y + (slot_rect.h - icon_h) * 0.5,
                icon_w,
                icon_h,
            );
            push_slot_visual(&mut commands, &slot, icon_rect, slot_rect);

            if let Some(dot_color) = slot.dot {
                commands.push(PaintCmd::Circle {
                    cx: slot_rect.x + slot_rect.w - 5.0,
                    cy: slot_rect.y + 5.0,
                    radius: 3.0,
                    fill: dot_color,
                });
            }

            hit_targets.push(HitTarget {
                rect: slot_rect,
                id: slot.id,
            });
            slot_y += slot_h + spacing;
        }
    } else {
        // Horizontal bar / floating Island layout
        let bw = logical_w as f32;
        let bh = logical_h as f32;
        let cell_h = (bh - pad * 2.0).max(16.0);
        let cell_w = cell_h.min(28.0);

        // 1. Start cluster: Workspaces
        let mut cur_x = pad + bar.border_width;
        for (ws_id, focused, occupied) in &workspaces {
            let rect = Rect::new(cur_x, pad, cell_w, cell_h);
            let (fill, text_col, stroke) = if *focused {
                (Some(primary), on_primary, None)
            } else if *occupied {
                (Some(surface_variant), on_surface, Some(secondary))
            } else {
                (Some(surface_container), muted, None)
            };
            commands.push(PaintCmd::RoundedRect {
                rect,
                radius: inner_radius,
                fill,
                stroke,
                stroke_width: if stroke.is_some() { 1.0 } else { 0.0 },
            });
            commands.push(PaintCmd::Text {
                rect,
                text: ws_id.to_string(),
                color: text_col,
                size: 12.0,
                bold: *focused,
                align: TextAlign::Center,
            });
            hit_targets.push(HitTarget {
                rect,
                id: format!("ws:{ws_id}"),
            });
            cur_x += cell_w + spacing;
        }

        // 2. Center cluster: Horizontal Clock (HH:MM)
        let clock_w = 56.0;
        let clock_rect = Rect::new((bw - clock_w) * 0.5, pad, clock_w, cell_h);
        commands.push(PaintCmd::Text {
            rect: clock_rect,
            text: state.clock.format_hh_mm(),
            color: on_surface,
            size: 13.0,
            bold: true,
            align: TextAlign::Center,
        });

        // 3. End cluster: Status slots laid out left-to-right anchored to right edge
        let slot_w = cell_h.max(26.0);
        let total_slots_w =
            end_slots.len() as f32 * slot_w + (end_slots.len().saturating_sub(1)) as f32 * spacing;
        let mut slot_x =
            (bw - pad - bar.border_width - total_slots_w).max(clock_rect.x + clock_rect.w + 8.0);

        for slot in end_slots {
            let slot_rect = Rect::new(slot_x, pad, slot_w, cell_h);
            commands.push(PaintCmd::RoundedRect {
                rect: slot_rect,
                radius: inner_radius,
                fill: Some(slot.fill),
                stroke: slot.stroke,
                stroke_width: if slot.stroke.is_some() { 1.0 } else { 0.0 },
            });
            let icon_w = (slot_w * 0.56).clamp(12.0, 17.0);
            let icon_h = (cell_h * 0.54).clamp(10.0, 15.0);
            let icon_rect = Rect::new(
                slot_rect.x + (slot_rect.w - icon_w) * 0.5,
                slot_rect.y + (slot_rect.h - icon_h) * 0.5,
                icon_w,
                icon_h,
            );
            push_slot_visual(&mut commands, &slot, icon_rect, slot_rect);
            if let Some(dot_color) = slot.dot {
                commands.push(PaintCmd::Circle {
                    cx: slot_rect.x + slot_rect.w - 5.0,
                    cy: slot_rect.y + 5.0,
                    radius: 3.0,
                    fill: dot_color,
                });
            }
            hit_targets.push(HitTarget {
                rect: slot_rect,
                id: slot.id,
            });
            slot_x += slot_w + spacing;
        }
    }

    let animating =
        ws_spring.is_some_and(|s| !s.is_settled()) || ghost_spring.is_some_and(|s| !s.is_settled());

    SurfaceSpec {
        id: format!("bar:{}", output.name),
        namespace,
        output: Some(output.name.clone()),
        layer: if is_ghost { Layer::Overlay } else { Layer::Top },
        keyboard_interactivity: KeyboardMode::None,
        anchor,
        exclusive_zone,
        width,
        height,
        margin: if is_ghost {
            EdgeInsets {
                top: 8,
                bottom: 8,
                left: 0,
                right: 0,
            }
        } else {
            margin
        },
        corner_radius: if is_ghost { 0.0 } else { bar.corner_radius },
        background: if is_ghost { Color::TRANSPARENT } else { bg },
        border_color: if is_ghost {
            Color::TRANSPARENT
        } else {
            border_color
        },
        border_width: if is_ghost { 0.0 } else { bar.border_width },
        commands,
        hit_targets,
        animating,
        input_regions: None,
        ime_cursor_rect: None,
    }
}

/// Minimal split-corner top bar paired with Dynamic Island in the `island` preset.
/// Leaves the top-center completely open and click-through via explicit `input_regions`.
fn build_island_bar_surface(state: &AppState, output: &OutputInfo) -> SurfaceSpec {
    let colors = state.palette.for_mode(state.theme_mode);
    let bg = colors
        .surface_color()
        .with_opacity(state.config.bar.background_opacity);
    let border_color = colors.outline_variant_color();
    let primary = colors.primary_color();
    let on_primary = colors.on_primary_color();
    let secondary = colors.secondary_color();
    let on_surface = colors.on_surface_color();
    let muted = colors.on_surface_variant_color();
    let surface_container = colors.surface_container_color();
    let surface_variant = colors.surface_variant_color();

    let bar_h = 34u32;
    let margin_x = 10i32;
    let margin_top = 8i32;
    let logical_w = (output.width - margin_x * 2).max(400) as f32;
    let bh = bar_h as f32;
    let pill_r = bh * 0.5;
    let pad = 6.0f32;
    let spacing = 4.0f32;

    let workspaces = collect_workspaces(state, &output.name);
    let end_slots = active_end_slots(state);

    let mut commands = Vec::new();
    let mut hit_targets = Vec::new();
    let mut input_regions = Vec::new();

    // Left pill: Workspaces
    let ws_size = 24.0f32;
    let left_w = pad * 2.0
        + workspaces.len() as f32 * ws_size
        + workspaces.len().saturating_sub(1) as f32 * spacing;
    let left_pill = Rect::new(0.0, 0.0, left_w, bh);
    commands.push(PaintCmd::RoundedRect {
        rect: left_pill,
        radius: pill_r,
        fill: Some(bg),
        stroke: Some(border_color),
        stroke_width: 1.5,
    });
    input_regions.push(left_pill);

    let mut cur_x = pad;
    let cell_y = (bh - ws_size) * 0.5;
    for (ws_id, focused, occupied) in &workspaces {
        let rect = Rect::new(cur_x, cell_y, ws_size, ws_size);
        let (fill, text_col, stroke) = if *focused {
            (Some(primary), on_primary, None)
        } else if *occupied {
            (Some(surface_variant), on_surface, Some(secondary))
        } else {
            (Some(surface_container), muted, None)
        };
        commands.push(PaintCmd::RoundedRect {
            rect,
            radius: ws_size * 0.5,
            fill,
            stroke,
            stroke_width: if stroke.is_some() { 1.0 } else { 0.0 },
        });
        commands.push(PaintCmd::Text {
            rect,
            text: ws_id.to_string(),
            color: text_col,
            size: 11.5,
            bold: *focused,
            align: TextAlign::Center,
        });
        hit_targets.push(HitTarget {
            rect,
            id: format!("ws:{ws_id}"),
        });
        cur_x += ws_size + spacing;
    }

    // Right pill: Status slots (top center remains untouched for Dynamic Island)
    let slot_size = 24.0f32;
    let right_w = pad * 2.0
        + end_slots.len().max(1) as f32 * slot_size
        + end_slots.len().saturating_sub(1) as f32 * spacing;
    let right_x = (logical_w - right_w).max(left_w + 160.0);
    let right_pill = Rect::new(right_x, 0.0, right_w, bh);
    commands.push(PaintCmd::RoundedRect {
        rect: right_pill,
        radius: pill_r,
        fill: Some(bg),
        stroke: Some(border_color),
        stroke_width: 1.5,
    });
    input_regions.push(right_pill);

    let mut sx = right_x + pad;
    let sy = (bh - slot_size) * 0.5;
    for slot in end_slots {
        let slot_rect = Rect::new(sx, sy, slot_size, slot_size);
        commands.push(PaintCmd::RoundedRect {
            rect: slot_rect,
            radius: slot_size * 0.5,
            fill: Some(slot.fill),
            stroke: slot.stroke,
            stroke_width: if slot.stroke.is_some() { 1.0 } else { 0.0 },
        });
        let icon_w = 13.0f32;
        let icon_h = 12.0f32;
        let icon_rect = Rect::new(
            slot_rect.x + (slot_rect.w - icon_w) * 0.5,
            slot_rect.y + (slot_rect.h - icon_h) * 0.5,
            icon_w,
            icon_h,
        );
        push_slot_visual(&mut commands, &slot, icon_rect, slot_rect);
        if let Some(dot_color) = slot.dot {
            commands.push(PaintCmd::Circle {
                cx: slot_rect.x + slot_rect.w - 4.0,
                cy: slot_rect.y + 4.0,
                radius: 2.8,
                fill: dot_color,
            });
        }
        hit_targets.push(HitTarget {
            rect: slot_rect,
            id: slot.id,
        });
        sx += slot_size + spacing;
    }

    SurfaceSpec {
        id: format!("bar:{}", output.name),
        namespace: format!("kaze-bar-{}", output.name),
        output: Some(output.name.clone()),
        layer: Layer::Top,
        keyboard_interactivity: KeyboardMode::None,
        anchor: Anchor::TOP | Anchor::LEFT | Anchor::RIGHT,
        exclusive_zone: (bar_h as i32) + 4,
        width: 0,
        height: bar_h,
        margin: EdgeInsets {
            top: margin_top,
            bottom: 0,
            left: margin_x,
            right: margin_x,
        },
        corner_radius: 0.0,
        background: Color::TRANSPARENT,
        border_color: Color::TRANSPARENT,
        border_width: 0.0,
        commands,
        hit_targets,
        animating: false,
        input_regions: Some(input_regions),
        ime_cursor_rect: None,
    }
}

/// Slim 30px top text-only typographic bar (`swiss` preset):
/// pure monospace labels and 1px hairline rules (`01 / 02 / 03 — 10:06 — VOL 72% | BAT 84%`).
fn build_swiss_bar_surface(state: &AppState, output: &OutputInfo) -> SurfaceSpec {
    let colors = state.palette.for_mode(state.theme_mode);
    let bg = colors
        .surface_color()
        .with_opacity(state.config.bar.background_opacity);
    let hairline = colors.outline_variant_color();
    let primary = colors.primary_color();
    let secondary = colors.secondary_color();
    let tertiary = colors.tertiary_color();
    let error_col = colors.error_color();
    let on_surface = colors.on_surface_color();
    let muted = colors.on_surface_variant_color();

    let bar_h = 30u32;
    let bh = bar_h as f32;
    let bw = output.width.max(480) as f32;

    let mut commands = Vec::new();
    let mut hit_targets = Vec::new();

    // 1px bottom structural rule
    commands.push(PaintCmd::Line {
        x1: 0.0,
        y1: bh - 0.5,
        x2: bw,
        y2: bh - 0.5,
        color: hairline,
        width: 1.0,
    });

    // Left: `01 / 02 / 03 / ...`
    let workspaces = collect_workspaces(state, &output.name);
    let mut cur_x = 14.0f32;
    for (idx, (ws_id, focused, occupied)) in workspaces.iter().enumerate() {
        if idx > 0 {
            let sep_rect = Rect::new(cur_x, 0.0, 14.0, bh - 1.0);
            commands.push(PaintCmd::Text {
                rect: sep_rect,
                text: "/".to_string(),
                color: hairline,
                size: 11.5,
                bold: false,
                align: TextAlign::Center,
            });
            cur_x += 14.0;
        }
        let label = format!("{ws_id:02}");
        let cell_w = 24.0f32;
        let rect = Rect::new(cur_x, 0.0, cell_w, bh - 1.0);
        let color = if *focused {
            primary
        } else if *occupied {
            on_surface
        } else {
            muted
        };
        commands.push(PaintCmd::Text {
            rect,
            text: label,
            color,
            size: 12.0,
            bold: *focused,
            align: TextAlign::Center,
        });
        if *focused {
            commands.push(PaintCmd::Line {
                x1: cur_x + 2.0,
                y1: bh - 2.0,
                x2: cur_x + cell_w - 2.0,
                y2: bh - 2.0,
                color: primary,
                width: 2.0,
            });
        }
        hit_targets.push(HitTarget {
            rect,
            id: format!("ws:{ws_id}"),
        });
        cur_x += cell_w;
    }

    // Center: crisp typographic clock (`— HH:MM —`)
    let clock_w = 96.0f32;
    let clock_rect = Rect::new((bw - clock_w) * 0.5, 0.0, clock_w, bh - 1.0);
    commands.push(PaintCmd::Text {
        rect: clock_rect,
        text: state.clock.format_hh_mm(),
        color: on_surface,
        size: 12.5,
        bold: true,
        align: TextAlign::Center,
    });

    // Right: text-only status cells separated by 1px vertical rules
    let mut tokens: Vec<(String, String, Color)> = Vec::new();
    if state.display_status.is_active() {
        let (txt, col) = match &state.display_status {
            DisplayStatus::Present { .. } => ("LIVE", primary),
            DisplayStatus::VirtualShare { .. } => ("SHARE", secondary),
            DisplayStatus::VirtualControl { .. } => ("CTRL", primary),
            DisplayStatus::Recording { .. } => ("REC", error_col),
            DisplayStatus::Idle => ("", muted),
        };
        if !txt.is_empty() {
            tokens.push(("display".into(), txt.into(), col));
        }
    }
    if state.network.available && state.network.connected {
        let txt = match state.network.kind {
            NetworkKind::Wifi => format!("WIFI {}%", state.network.strength),
            NetworkKind::Ethernet => "ETH".into(),
            NetworkKind::Disconnected => "OFFLINE".into(),
        };
        tokens.push(("net".into(), txt, on_surface));
    } else {
        tokens.push(("net".into(), "NET OFF".into(), muted));
    }
    if state.audio.muted {
        tokens.push(("vol".into(), "VOL MUTE".into(), error_col));
    } else {
        tokens.push((
            "vol".into(),
            format!("VOL {}%", state.audio.volume_pct),
            on_surface,
        ));
    }
    if state.battery.present {
        let col = if state.battery.charging {
            secondary
        } else if state.battery.low {
            error_col
        } else {
            on_surface
        };
        let chg = if state.battery.charging { "+" } else { "" };
        tokens.push((
            "bat".into(),
            format!("BAT {}%{chg}", state.battery.percentage),
            col,
        ));
    }
    if state.dnd {
        tokens.push(("notifications".into(), "DND".into(), tertiary));
    } else if state.unread_notifications > 0 {
        tokens.push((
            "notifications".into(),
            format!("MSG {}", state.unread_notifications),
            primary,
        ));
    }
    if !state.tray_items.is_empty() {
        tokens.push((
            "tray:item:0".into(),
            format!("TRAY {}", state.tray_items.len()),
            on_surface,
        ));
    }
    tokens.push((
        "cc".into(),
        "CC".into(),
        if state.cc_open { primary } else { muted },
    ));

    let mut right_edge = bw - 14.0;
    for (idx, (id, text, color)) in tokens.into_iter().rev().enumerate() {
        if idx > 0 {
            right_edge -= 8.0;
            commands.push(PaintCmd::Line {
                x1: right_edge,
                y1: 7.0,
                x2: right_edge,
                y2: bh - 8.0,
                color: hairline,
                width: 1.0,
            });
            right_edge -= 8.0;
        }
        let token_w = (text.len() as f32 * 7.6 + 6.0).max(34.0);
        let x = (right_edge - token_w).max(clock_rect.x + clock_rect.w + 8.0);
        let rect = Rect::new(x, 0.0, token_w, bh - 1.0);
        commands.push(PaintCmd::Text {
            rect,
            text,
            color,
            size: 11.5,
            bold: id == "display",
            align: TextAlign::Center,
        });
        hit_targets.push(HitTarget { rect, id });
        right_edge = x;
    }

    SurfaceSpec {
        id: format!("bar:{}", output.name),
        namespace: format!("kaze-bar-{}", output.name),
        output: Some(output.name.clone()),
        layer: Layer::Top,
        keyboard_interactivity: KeyboardMode::None,
        anchor: Anchor::TOP | Anchor::LEFT | Anchor::RIGHT,
        exclusive_zone: bar_h as i32,
        width: 0,
        height: bar_h,
        margin: EdgeInsets::default(),
        corner_radius: 0.0,
        background: bg,
        border_color: Color::TRANSPARENT,
        border_width: 0.0,
        commands,
        hit_targets,
        animating: false,
        input_regions: None,
        ime_cursor_rect: None,
    }
}

fn status_dot_color(
    status: &DisplayStatus,
    primary: Color,
    secondary: Color,
    error: Color,
) -> Option<Color> {
    match status {
        DisplayStatus::Idle => None,
        DisplayStatus::Present { .. } | DisplayStatus::VirtualControl { .. } => Some(primary),
        DisplayStatus::VirtualShare { .. } => Some(secondary),
        DisplayStatus::Recording { .. } => Some(error),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use kaze_core::{Config, OutputInfo};

    #[test]
    fn bar_hide_and_show_targets_exact_output() {
        let mut state = AppState::new(Config::default());
        state.outputs.insert(
            "Virtual-1".into(),
            OutputInfo {
                name: "Virtual-1".into(),
                width: 1920,
                height: 1080,
                scale: 1,
            },
        );
        state.outputs.insert(
            "kaze-share".into(),
            OutputInfo {
                name: "kaze-share".into(),
                width: 1920,
                height: 1080,
                scale: 1,
            },
        );

        let mut ext = BarExtension::new();
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_init(&mut ctx);
        }
        assert_eq!(ext.surfaces().len(), 2);

        {
            let mut ctx = ShellContext::new(&mut state);
            let res = ext.on_ipc("bar-hide", &["kaze-share".into()], &mut ctx);
            assert!(matches!(res, IpcResult::Handled { ok: true, .. }));
        }
        let specs = ext.surfaces();
        assert_eq!(specs.len(), 1);
        assert_eq!(specs[0].namespace, "kaze-bar-Virtual-1");

        {
            let mut ctx = ShellContext::new(&mut state);
            let res = ext.on_ipc("bar-show", &["kaze-share".into()], &mut ctx);
            assert!(matches!(res, IpcResult::Handled { ok: true, .. }));
        }
        assert_eq!(ext.surfaces().len(), 2);
    }

    #[test]
    fn pointer_clicks_and_scroll_emit_expected_actions() {
        use kaze_core::KeyModifiers;
        let mut state = AppState::new(Config::default());
        let mut ext = BarExtension::new();
        let mut ctx = ShellContext::new(&mut state);

        ext.on_event(
            &SystemEvent::PointerClick {
                surface_id: "bar:Virtual-1".into(),
                target_id: "ws:3".into(),
                button: PointerButton::Left,
            },
            &mut ctx,
        );
        assert_eq!(
            ctx.actions,
            vec![ShellAction::HyprDispatch("workspace 3".into())]
        );

        ctx.actions.clear();
        ext.on_event(
            &SystemEvent::PointerClick {
                surface_id: "bar:Virtual-1".into(),
                target_id: "net".into(),
                button: PointerButton::Left,
            },
            &mut ctx,
        );
        assert_eq!(
            ctx.actions,
            vec![ShellAction::SpawnDetachedApp {
                program: "kaze-tui".into(),
                args: vec!["wifi".into()],
            }]
        );

        ctx.actions.clear();
        ext.on_event(
            &SystemEvent::PointerScroll {
                surface_id: "bar:Virtual-1".into(),
                target_id: "vol".into(),
                delta_y: -1.0,
                modifiers: KeyModifiers::default(),
            },
            &mut ctx,
        );
        assert_eq!(ctx.actions, vec![ShellAction::AudioStepVolume(5)]);

        ctx.actions.clear();
        ext.on_event(
            &SystemEvent::PointerClick {
                surface_id: "bar:Virtual-1".into(),
                target_id: "vol".into(),
                button: PointerButton::Right,
            },
            &mut ctx,
        );
        assert_eq!(ctx.actions, vec![ShellAction::AudioToggleMute]);
    }

    #[test]
    fn island_config_switches_geometry_and_namespace_without_code_changes() {
        let mut cfg = Config::default();
        cfg.bar.position = BarPosition::Top;
        cfg.bar.island_mode = true;
        cfg.bar.length = 460;
        cfg.bar.thickness = 36;
        cfg.bar.corner_radius = 18.0;

        let mut state = AppState::new(cfg);
        state.outputs.insert(
            "Virtual-1".into(),
            OutputInfo {
                name: "Virtual-1".into(),
                width: 1920,
                height: 1080,
                scale: 1,
            },
        );

        let mut ext = BarExtension::new();
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_init(&mut ctx);
        }
        let specs = ext.surfaces();
        assert_eq!(specs.len(), 1);
        assert_eq!(specs[0].namespace, "kaze-island");
        assert_eq!(specs[0].anchor, Anchor::TOP);
        assert_eq!(specs[0].width, 460);
        assert_eq!(specs[0].height, 36);
        assert_eq!(specs[0].corner_radius, 18.0);
        assert_eq!(specs[0].exclusive_zone, 0);
    }

    #[test]
    fn hides_battery_slot_on_desktop_or_vm_without_battery() {
        let mut state = AppState::new(Config::default());
        state.outputs.insert(
            "Virtual-1".into(),
            OutputInfo {
                name: "Virtual-1".into(),
                width: 1920,
                height: 1080,
                scale: 1,
            },
        );
        let mut ext = BarExtension::new();
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_init(&mut ctx);
        }
        let has_bat = ext.surfaces()[0].hit_targets.iter().any(|t| t.id == "bat");
        assert!(!has_bat);

        state.battery.present = true;
        state.battery.percentage = 82;
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_event(
                &SystemEvent::BatteryChanged(ctx.state.battery.clone()),
                &mut ctx,
            );
        }
        let has_bat_after = ext.surfaces()[0].hit_targets.iter().any(|t| t.id == "bat");
        assert!(has_bat_after);
    }

    #[test]
    fn swiss_preset_renders_30px_text_only_bar_without_icons() {
        let mut state = AppState::new(Config::default());
        state.layout_preset = LayoutPreset::Swiss;
        state.battery.present = true;
        state.battery.percentage = 84;
        state.outputs.insert(
            "Virtual-1".into(),
            OutputInfo {
                name: "Virtual-1".into(),
                width: 1920,
                height: 1080,
                scale: 1,
            },
        );
        let mut ext = BarExtension::new();
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_init(&mut ctx);
        }
        let specs = ext.surfaces();
        assert_eq!(specs.len(), 1);
        assert_eq!(specs[0].height, 30);
        assert_eq!(specs[0].exclusive_zone, 30);
        assert_eq!(specs[0].corner_radius, 0.0);
        assert!(
            !specs[0]
                .commands
                .iter()
                .any(|c| matches!(c, PaintCmd::Icon { .. })),
            "swiss preset must be strictly text-only without icons"
        );
        assert!(specs[0]
            .commands
            .iter()
            .any(|c| matches!(c, PaintCmd::Text { text, .. } if text == "BAT 84%")));
    }

    #[test]
    fn island_preset_leaves_center_click_through_with_two_corner_pills() {
        let mut state = AppState::new(Config::default());
        state.layout_preset = LayoutPreset::Island;
        state.outputs.insert(
            "Virtual-1".into(),
            OutputInfo {
                name: "Virtual-1".into(),
                width: 1920,
                height: 1080,
                scale: 1,
            },
        );
        let mut ext = BarExtension::new();
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_init(&mut ctx);
        }
        let specs = ext.surfaces();
        assert_eq!(specs.len(), 1);
        let regions = specs[0]
            .input_regions
            .as_ref()
            .expect("island bar splits input regions");
        assert_eq!(regions.len(), 2);
        assert!(!regions.iter().any(|r| r.contains(960.0, 17.0)));
    }

    #[test]
    fn ghost_preset_hides_bar_at_idle_and_peeks_with_converging_spring() {
        let mut state = AppState::new(Config::default());
        state.layout_preset = LayoutPreset::Ghost;
        state.outputs.insert(
            "Virtual-1".into(),
            OutputInfo {
                name: "Virtual-1".into(),
                width: 1920,
                height: 1080,
                scale: 1,
            },
        );
        let mut ext = BarExtension::new();
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_init(&mut ctx);
        }
        assert!(ext.surfaces().is_empty(), "ghost idle must have 0 surfaces");

        // Trigger bar-peek
        {
            let mut ctx = ShellContext::new(&mut state);
            let res = ext.on_ipc("bar-peek", &[], &mut ctx);
            assert!(matches!(res, IpcResult::Handled { ok: true, .. }));
        }
        assert_eq!(ext.surfaces().len(), 1);
        assert_eq!(ext.surfaces()[0].exclusive_zone, 0);
        assert!(ext.surfaces()[0].animating);

        // Advance frame ticks until spring settles
        for _ in 0..120 {
            if !ext.surfaces()[0].animating {
                break;
            }
            let mut ctx = ShellContext::new(&mut state);
            ext.on_event(
                &SystemEvent::FrameTick {
                    surface_id: "bar:Virtual-1".into(),
                    dt_secs: 1.0 / 60.0,
                },
                &mut ctx,
            );
        }
        assert!(!ext.surfaces()[0].animating, "peek reveal must converge");

        // Fire auto-hide timer -> slides back out and drops surface completely
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_event(
                &SystemEvent::TimerFired {
                    id: GHOST_PEEK_TIMER_ID.into(),
                },
                &mut ctx,
            );
        }
        for _ in 0..120 {
            if ext.surfaces().is_empty() {
                break;
            }
            let mut ctx = ShellContext::new(&mut state);
            ext.on_event(
                &SystemEvent::FrameTick {
                    surface_id: "bar:Virtual-1".into(),
                    dt_secs: 1.0 / 60.0,
                },
                &mut ctx,
            );
        }
        assert!(
            ext.surfaces().is_empty(),
            "ghost bar must destroy surface once hide spring settles"
        );
    }
}
