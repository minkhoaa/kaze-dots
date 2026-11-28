#![deny(clippy::unwrap_used)]

mod tabs;

use kaze_core::{
    t, Anchor, AppState, DirtyFlags, EdgeInsets, I18nKey, IpcResult, KazeExtension, KeyboardMode,
    Layer, LayoutPreset, PaintCmd, PointerButton, Rect, ShellAction, ShellContext, SurfaceSpec,
    SystemEvent, TextAlign, TextInputOutcome, TextInputState,
};
use tabs::{
    render_audio_tab, render_bluetooth_tab, render_calendar_tab, render_home_tab,
    render_network_tab, render_notif_list, render_screentime_tab, render_sidebar,
    render_sysmon_tab, render_weather_tab, slider_bounds, surface_width, CcTab, PaletteTheme,
};

const SURFACE_ID: &str = "cc:main";
const NAMESPACE: &str = "kaze-cc";
const POWER_CONFIRM_TIMER: &str = "cc:power-confirm-reset";
const POWER_CONFIRM_MS: u64 = 4000;
const KEY_ESCAPE: u32 = 0xff1b;
const KEY_RETURN: u32 = 0xff0d;

const PAD_X: f32 = 14.0;

/// Multi-Tab Control Center (`kaze-cc`, `Layer::Overlay`):
/// Configurable sidebar (`full`, `compact`, `none`) across 9 sub-panels:
/// Home, Network (Wi-Fi APs + VPN), Bluetooth (strictly scoped discovery), Audio (Per-App
/// PipeWire Mixer), Sysmon (strictly scoped `/proc` subscriber), Weather, ScreenTime, Calendar,
/// and Notification History. Returns `Vec::new()` and stops discovery/sysmon when closed.
pub struct ControlCenterExtension {
    open: bool,
    active_tab: CcTab,
    pending_power_confirm: Option<String>,
    wifi_prompt_ssid: Option<String>,
    wifi_password: TextInputState,
    bt_discovery_active: bool,
    sysmon_active: bool,
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
            active_tab: CcTab::Home,
            pending_power_confirm: None,
            wifi_prompt_ssid: None,
            wifi_password: TextInputState::new(true),
            bt_discovery_active: false,
            sysmon_active: false,
            cached_spec: None,
        }
    }

    pub fn is_open(&self) -> bool {
        self.open
    }

    pub fn active_tab_name(&self) -> &'static str {
        self.active_tab.id_str()
    }

    fn sync_on_demand_services(&mut self, ctx: &mut ShellContext) {
        let want_bt = self.open && self.active_tab == CcTab::Bluetooth;
        if want_bt != self.bt_discovery_active {
            self.bt_discovery_active = want_bt;
            ctx.push_action(ShellAction::BluetoothSetDiscovery(want_bt));
        }

        let want_sysmon = self.open && self.active_tab == CcTab::Sysmon;
        if want_sysmon != self.sysmon_active {
            self.sysmon_active = want_sysmon;
            ctx.push_action(ShellAction::SetSysmonSubscriber {
                owner: "cc".to_string(),
                active: want_sysmon,
            });
        }
    }

    fn set_open(&mut self, open: bool, ctx: &mut ShellContext) -> DirtyFlags {
        if self.open == open {
            return DirtyFlags::NONE;
        }
        self.open = open;
        ctx.state.cc_open = open;
        if !open {
            self.pending_power_confirm = None;
            self.wifi_prompt_ssid = None;
            self.wifi_password.clear();
            ctx.push_action(ShellAction::CancelTimer {
                id: POWER_CONFIRM_TIMER.to_string(),
            });
            self.cached_spec = None;
        } else {
            self.rebuild(ctx.state);
        }
        self.sync_on_demand_services(ctx);
        DirtyFlags::CC | DirtyFlags::LAYOUT
    }

    fn set_tab(&mut self, tab: CcTab, ctx: &mut ShellContext) -> DirtyFlags {
        if self.active_tab == tab {
            return DirtyFlags::NONE;
        }
        self.active_tab = tab;
        self.wifi_prompt_ssid = None;
        self.wifi_password.clear();
        self.sync_on_demand_services(ctx);
        if self.open {
            self.rebuild(ctx.state);
            DirtyFlags::CC
        } else {
            DirtyFlags::NONE
        }
    }

    fn rebuild(&mut self, state: &AppState) {
        if !self.open {
            self.cached_spec = None;
            return;
        }
        self.cached_spec = Some(build_cc_surface(
            state,
            self.active_tab,
            self.pending_power_confirm.as_deref(),
            self.wifi_prompt_ssid.as_deref(),
            &self.wifi_password,
        ));
    }

    fn handle_slider(&self, target_id: &str, x: f32, ctx: &mut ShellContext) -> DirtyFlags {
        let (track_x, track_w) = slider_bounds(ctx.state);
        let ratio = ((x - track_x) / track_w).clamp(0.0, 1.0);
        let pct = (ratio * 100.0).round() as u8;
        if target_id == "cc:slider:vol" {
            ctx.push_action(ShellAction::AudioSetVolume(pct));
        } else if target_id == "cc:slider:bright" {
            ctx.push_action(ShellAction::BacklightSet(pct.max(5)));
        } else if let Some(idx_str) = target_id.strip_prefix("cc:slider:stream:") {
            if let Ok(index) = idx_str.parse::<u32>() {
                ctx.push_action(ShellAction::AudioSetStreamVolume { index, pct });
            }
        }
        DirtyFlags::NONE
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
        if target_id.starts_with("cc:slider:") {
            return DirtyFlags::NONE;
        }

        if let Some(tab_name) = target_id.strip_prefix("cc:tab:") {
            if let Some(tab) = CcTab::from_name(tab_name) {
                return self.set_tab(tab, ctx);
            }
            return DirtyFlags::NONE;
        }

        if let Some(ssid) = target_id.strip_prefix("cc:net:ap:") {
            let ap = ctx
                .state
                .network
                .access_points
                .iter()
                .find(|a| a.ssid == ssid)
                .cloned();
            if let Some(ap) = ap {
                if ap.saved || !ap.secured {
                    ctx.push_action(ShellAction::WifiConnect {
                        ssid: ap.ssid,
                        password: String::new(),
                    });
                } else {
                    self.wifi_prompt_ssid = Some(ap.ssid);
                    self.wifi_password.clear();
                    self.rebuild(ctx.state);
                    return DirtyFlags::CC;
                }
            }
            return DirtyFlags::NONE;
        }
        if let Some(ssid) = target_id.strip_prefix("cc:net:forget:") {
            ctx.push_action(ShellAction::WifiForget(ssid.to_string()));
            return DirtyFlags::NONE;
        }
        if let Some(uuid) = target_id.strip_prefix("cc:net:vpn:") {
            ctx.push_action(ShellAction::VpnToggle(uuid.to_string()));
            return DirtyFlags::NONE;
        }

        if let Some(idx_str) = target_id.strip_prefix("cc:bt:pair:") {
            if let Ok(idx) = idx_str.parse::<usize>() {
                if let Some(dev) = ctx.state.bluetooth.devices.get(idx) {
                    ctx.push_action(ShellAction::BluetoothPair(dev.path.clone()));
                }
            }
            return DirtyFlags::NONE;
        }
        if let Some(idx_str) = target_id.strip_prefix("cc:bt:conn:") {
            if let Ok(idx) = idx_str.parse::<usize>() {
                if let Some(dev) = ctx.state.bluetooth.devices.get(idx) {
                    if dev.connected {
                        ctx.push_action(ShellAction::BluetoothDisconnect(dev.path.clone()));
                    } else {
                        ctx.push_action(ShellAction::BluetoothConnect(dev.path.clone()));
                    }
                }
            }
            return DirtyFlags::NONE;
        }
        if let Some(idx_str) = target_id.strip_prefix("cc:bt:remove:") {
            if let Ok(idx) = idx_str.parse::<usize>() {
                if let Some(dev) = ctx.state.bluetooth.devices.get(idx) {
                    ctx.push_action(ShellAction::BluetoothRemove(dev.path.clone()));
                }
            }
            return DirtyFlags::NONE;
        }
        if let Some(idx_str) = target_id.strip_prefix("cc:audio:stream_mute:") {
            if let Ok(idx) = idx_str.parse::<u32>() {
                let cur_muted = ctx
                    .state
                    .audio
                    .streams
                    .iter()
                    .find(|s| s.index == idx)
                    .is_some_and(|s| s.muted);
                ctx.push_action(ShellAction::AudioSetStreamMute {
                    index: idx,
                    muted: !cur_muted,
                });
            }
            return DirtyFlags::NONE;
        }

        match target_id {
            "cc:toggle:wifi" => {
                ctx.push_action(ShellAction::WifiToggle);
                DirtyFlags::NONE
            }
            "cc:net:scan" => {
                ctx.push_action(ShellAction::NetworkRequestScan);
                DirtyFlags::NONE
            }
            "cc:net:disconnect" => {
                ctx.push_action(ShellAction::WifiDisconnect);
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
                ctx.push_action(ShellAction::SettingsOpen("control_center".to_string()));
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
            "cc:weather:refresh" => {
                ctx.push_action(ShellAction::WeatherRefresh);
                DirtyFlags::NONE
            }
            "cc:screentime:reset" => {
                ctx.push_action(ShellAction::ScreenTimeReset);
                DirtyFlags::NONE
            }
            "cc:cal:sync" => {
                ctx.push_action(ShellAction::CalendarSyncNow);
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
        self.active_tab =
            CcTab::from_name(&ctx.state.config.control_center.default_tab).unwrap_or(CcTab::Home);
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
                if target_id == "cc:slider:vol" {
                    ctx.push_action(ShellAction::AudioStepVolume(step));
                } else if target_id == "cc:slider:bright" {
                    ctx.push_action(ShellAction::BacklightStep(step));
                }
                DirtyFlags::NONE
            }
            SystemEvent::KeyInput { surface_id, key } if surface_id == SURFACE_ID => {
                if !key.pressed {
                    return DirtyFlags::NONE;
                }
                if key.keysym == KEY_ESCAPE {
                    if self.wifi_prompt_ssid.is_some() {
                        self.wifi_prompt_ssid = None;
                        self.wifi_password.clear();
                        self.rebuild(ctx.state);
                        return DirtyFlags::CC;
                    }
                    return self.set_open(false, ctx);
                }
                if let Some(ssid) = self.wifi_prompt_ssid.clone() {
                    if key.keysym == KEY_RETURN {
                        let pw = self.wifi_password.text.clone();
                        self.wifi_prompt_ssid = None;
                        self.wifi_password.clear();
                        ctx.push_action(ShellAction::WifiConnect { ssid, password: pw });
                        self.rebuild(ctx.state);
                        return DirtyFlags::CC;
                    }
                    if matches!(
                        self.wifi_password
                            .handle_key(key, &ctx.state.config.input.keybinds),
                        TextInputOutcome::Changed
                    ) {
                        self.rebuild(ctx.state);
                        return DirtyFlags::CC;
                    }
                }
                DirtyFlags::NONE
            }
            SystemEvent::ImeInput { surface_id, ime } if surface_id == SURFACE_ID => {
                if self.wifi_prompt_ssid.is_some() && self.wifi_password.handle_ime(ime) {
                    self.rebuild(ctx.state);
                    DirtyFlags::CC
                } else {
                    DirtyFlags::NONE
                }
            }
            SystemEvent::SurfaceClosed { surface_id }
            | SystemEvent::KeyboardFocusLost { surface_id }
                if surface_id == SURFACE_ID =>
            {
                self.set_open(false, ctx)
            }
            SystemEvent::SessionLockRequested | SystemEvent::LockWorkerCommitted => {
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
            | SystemEvent::SysmonUpdated(_)
            | SystemEvent::WeatherUpdated(_)
            | SystemEvent::ScreenTimeUpdated(_)
            | SystemEvent::CalendarUpdated(_)
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

    fn on_ipc(&mut self, cmd: &str, args: &[String], ctx: &mut ShellContext) -> IpcResult {
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
                let mut dirty = DirtyFlags::NONE;
                if let Some(tab_arg) = args.first() {
                    if let Some(tab) = CcTab::from_name(tab_arg) {
                        dirty |= self.set_tab(tab, ctx);
                    }
                }
                dirty |= self.set_open(true, ctx);
                IpcResult::Handled {
                    ok: true,
                    message: format!("opened tab={}", self.active_tab.id_str()),
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
            "cc-tab" => {
                let Some(tab) = args.first().and_then(|s| CcTab::from_name(s)) else {
                    return IpcResult::Handled {
                        ok: false,
                        message: "usage: cc-tab <home|network|bluetooth|audio|sysmon|weather|screentime|calendar|notifications>".into(),
                        dirty: DirtyFlags::NONE,
                    };
                };
                let dirty = self.set_tab(tab, ctx);
                IpcResult::Handled {
                    ok: true,
                    message: format!("tab={}", tab.id_str()),
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

fn build_cc_surface(
    state: &AppState,
    active_tab: CcTab,
    pending_power: Option<&str>,
    wifi_prompt_ssid: Option<&str>,
    wifi_input: &TextInputState,
) -> SurfaceSpec {
    let colors = state.palette.for_mode(state.theme_mode);
    let bg = colors
        .surface_color()
        .with_opacity(state.config.bar.background_opacity.max(0.94));
    let pal = PaletteTheme::from_state(state);
    let radius = state
        .config
        .bar
        .corner_radius
        .max(state.layout_preset.overlay_corner_radius());
    let border_w = state
        .config
        .bar
        .border_width
        .max(state.layout_preset.overlay_border_width());

    let total_w = surface_width(state);
    let sb_w = tabs::sidebar_width(state);
    let x0 = sb_w + PAD_X;
    let inner_w = (total_w - x0 - PAD_X).max(220.0);

    let mut commands = Vec::with_capacity(80);
    let mut hit_targets = Vec::with_capacity(32);

    let mut y = border_w + 12.0;
    let loc = state.locale;
    let header_left = format!(
        "{} · {}",
        t(loc, I18nKey::ControlCenterTitle),
        active_tab.id_str().to_uppercase()
    );
    commands.push(PaintCmd::RichText {
        rect: Rect::new(x0, y, inner_w - 86.0, 18.0),
        text: header_left,
        color: pal.muted,
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
    commands.push(PaintCmd::TabularText {
        rect: Rect::new(total_w - PAD_X - 86.0, y, 86.0, 18.0),
        text: header_right,
        color: pal.on_surface,
        size: 10.5,
        bold: true,
        align: TextAlign::Right,
    });
    y += 24.0;

    let end_y = match active_tab {
        CcTab::Home => render_home_tab(
            &mut commands,
            &mut hit_targets,
            state,
            &pal,
            pending_power,
            x0,
            inner_w,
            y,
        ),
        CcTab::Network => render_network_tab(
            &mut commands,
            &mut hit_targets,
            state,
            &pal,
            wifi_prompt_ssid,
            wifi_input,
            x0,
            inner_w,
            y,
        ),
        CcTab::Bluetooth => {
            render_bluetooth_tab(&mut commands, &mut hit_targets, state, &pal, x0, inner_w, y)
        }
        CcTab::Audio => {
            render_audio_tab(&mut commands, &mut hit_targets, state, &pal, x0, inner_w, y)
        }
        CcTab::Sysmon => render_sysmon_tab(&mut commands, state, &pal, x0, inner_w, y),
        CcTab::Weather => {
            render_weather_tab(&mut commands, &mut hit_targets, state, &pal, x0, inner_w, y)
        }
        CcTab::ScreenTime => {
            render_screentime_tab(&mut commands, &mut hit_targets, state, &pal, x0, inner_w, y)
        }
        CcTab::Calendar => {
            render_calendar_tab(&mut commands, &mut hit_targets, state, &pal, x0, inner_w, y)
        }
        CcTab::Notifications => render_notif_list(
            &mut commands,
            &mut hit_targets,
            state,
            &pal,
            x0,
            inner_w,
            y,
            8,
        ),
    };

    let min_sidebar_h = if sb_w > 0.0 { 330.0 } else { 200.0 };
    let total_h = (end_y + border_w).max(min_sidebar_h).ceil() as u32;
    render_sidebar(
        &mut commands,
        &mut hit_targets,
        state,
        active_tab,
        &pal,
        total_h as f32,
    );

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
        width: total_w as u32,
        height: total_h,
        margin,
        corner_radius: radius,
        background: bg,
        border_color: pal.primary,
        border_width: border_w,
        commands,
        hit_targets,
        animating: false,
        input_regions: None,
        ime_cursor_rect: None,
        track_pointer_motion: false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use kaze_core::{
        AudioStreamInfo, Config, KeyEvent, KeyModifiers, NotificationItem, NotificationUrgency,
    };

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
            let (tx, tw) = slider_bounds(ctx.state);
            ext.on_event(
                &SystemEvent::PointerDrag {
                    surface_id: SURFACE_ID.into(),
                    target_id: "cc:slider:vol".into(),
                    x: tx + tw * 0.5,
                    y: 170.0,
                },
                &mut ctx,
            );
            assert_eq!(ctx.actions, vec![ShellAction::AudioSetVolume(50)]);

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

    #[test]
    fn multi_tab_bluetooth_discovery_sysmon_dormant_and_per_app_mixer() {
        let mut state = AppState::new(Config::default());
        state.audio.streams.push(AudioStreamInfo {
            index: 7,
            app_name: "Firefox".into(),
            media_name: "Video".into(),
            volume_pct: 80,
            muted: false,
        });
        let mut ext = ControlCenterExtension::new();
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_ipc("cc-open", &["bluetooth".into()], &mut ctx);
            assert!(ctx
                .actions
                .contains(&ShellAction::BluetoothSetDiscovery(true)));

            // Switching to sysmon MUST stop Bluetooth discovery and subscribe sysmon
            ctx.actions.clear();
            ext.on_ipc("cc-tab", &["sysmon".into()], &mut ctx);
            assert!(ctx
                .actions
                .contains(&ShellAction::BluetoothSetDiscovery(false)));
            assert!(ctx.actions.contains(&ShellAction::SetSysmonSubscriber {
                owner: "cc".into(),
                active: true,
            }));

            // Closing MUST drop sysmon subscription
            ctx.actions.clear();
            ext.on_ipc("cc-close", &[], &mut ctx);
            assert!(ctx.actions.contains(&ShellAction::SetSysmonSubscriber {
                owner: "cc".into(),
                active: false,
            }));
            assert!(ext.surfaces().is_empty());

            // Audio tab per-app mixer slider adjusts stream index 7
            ctx.actions.clear();
            ext.on_ipc("cc-open", &["audio".into()], &mut ctx);
            let (tx, tw) = slider_bounds(ctx.state);
            ext.on_event(
                &SystemEvent::PointerDrag {
                    surface_id: SURFACE_ID.into(),
                    target_id: "cc:slider:stream:7".into(),
                    x: tx + tw * 0.25,
                    y: 120.0,
                },
                &mut ctx,
            );
            assert!(ctx
                .actions
                .contains(&ShellAction::AudioSetStreamVolume { index: 7, pct: 25 }));
        }
    }
}
