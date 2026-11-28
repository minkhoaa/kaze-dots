use calloop::channel;
use calloop::generic::Generic;
use calloop::signals::{Signal, Signals};
use calloop::timer::{TimeoutAction, Timer};
use calloop::{EventLoop, Interest, LoopHandle, LoopSignal, Mode, PostAction, RegistrationToken};
use calloop_wayland_source::WaylandSource;
use kaze_core::desktop::scan_applications;
use kaze_core::layout::{layout_state_path, load_persisted_preset, save_persisted_preset};
use kaze_core::solar::evaluate_solar_now;
use kaze_core::theme::generate_all_templates;
use kaze_core::{
    resolve_keyboard_alias, AppState, ClockTime, Config, DirtyFlags, IpcResult, KazeExtension,
    LayoutPreset, Locale, NotificationItem, NotificationUrgency, ResolvedPalette, SettingsStore,
    ShellAction, ShellContext, SystemEvent, ThemePaths,
};
use kaze_ext_bar::BarExtension;
use kaze_ext_canvas::CanvasExtension;
use kaze_ext_capture::CaptureExtension;
use kaze_ext_cc::ControlCenterExtension;
use kaze_ext_clipboard::{default_clipboard_store_path, ClipboardExtension};
use kaze_ext_corners::CornersExtension;
use kaze_ext_dock::DockExtension;
use kaze_ext_idle::IdleExtension;
use kaze_ext_island::IslandExtension;
use kaze_ext_launcher::{desktop as launcher_desktop, LauncherExtension};
use kaze_ext_notify::NotifyExtension;
use kaze_ext_osd::OsdExtension;
use kaze_ext_polkit::PolkitExtension;
use kaze_ext_session::SessionMenuExtension;
use kaze_ext_switcher::SwitcherExtension;
use kaze_ext_tray::TrayExtension;
use kaze_ext_wallpaper::{
    expand_tilde, load_wallpaper_job, validate_wallpaper_file, WallpaperExtension,
};
use kaze_hypr::{HyprClient, HyprEvent, ReconnectBackoff};
use kaze_ipc::{default_socket_path, IpcRequest, IpcResponder, IpcResponse, IpcServer};
use kaze_sys::calendar::next_reminder_fire;
use kaze_sys::hooks::HookRequest;
use kaze_sys::screentime::ScreenTimeTracker;
use kaze_sys::{backlight, SysCommand, SysHandle};
use kaze_ui::UiState;
use notify::{EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use smithay_client_toolkit::reexports::client::Connection;
use std::collections::HashMap;
use std::fs;
use std::io::Read;
use std::os::unix::io::{FromRawFd, IntoRawFd, OwnedFd};
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

enum WatchNotice {
    Config,
    Backlight,
    Applications,
}

struct Daemon {
    loop_handle: LoopHandle<'static, Self>,
    loop_signal: LoopSignal,
    wayland_conn: Connection,
    ui: UiState,
    state: AppState,
    config_path: PathBuf,
    settings_path: Option<PathBuf>,
    layout_state_file: Option<PathBuf>,
    backlight_dir: Option<PathBuf>,
    theme_paths: ThemePaths,
    extensions: Vec<Box<dyn KazeExtension>>,
    hypr_client: Option<HyprClient>,
    hypr_token: Option<RegistrationToken>,
    hypr_backoff: ReconnectBackoff,
    hypr_reconnect_armed: bool,
    config_reload_armed: bool,
    timers: HashMap<String, RegistrationToken>,
    pending_dmenu: Option<IpcResponder>,
    pending_wallpaper_set: Option<IpcResponder>,
    pending_capture_reply: Option<IpcResponder>,
    event_tx: channel::Sender<SystemEvent>,
    sys: Option<SysHandle>,
    fs_watcher: Option<RecommendedWatcher>,
    watched_symlink_dir: Option<PathBuf>,
    watched_config_target: Arc<Mutex<Option<PathBuf>>>,
    children: Vec<Child>,
    active_lock_pid: Option<u32>,
    lock_committed: bool,
    pre_lock_dnd: Option<bool>,
    lock_pipe_token: Option<RegistrationToken>,
    screentime: ScreenTimeTracker,
    last_cal_reminder_uid: Option<String>,
}

fn epoch_secs_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

impl Daemon {
    fn sync_wave2_services(&mut self) {
        self.screentime.configure(
            self.state.config.screentime.enabled,
            self.state.config.screentime.retention_days,
        );
        self.state.screentime = self.screentime.snapshot(epoch_secs_now());
        if let Some(ref sys) = self.sys {
            sys.send(SysCommand::ConfigureWeather {
                cfg: self.state.config.weather.clone(),
                offline_mode: self.state.offline_mode,
            });
            sys.send(SysCommand::ConfigureCalendar {
                cfg: self.state.config.calendar.clone(),
                offline_mode: self.state.offline_mode,
            });
        }
    }

    fn arm_next_calendar_reminder(&mut self) {
        let now = epoch_secs_now();
        let lead = self.state.config.calendar.reminder_lead_mins;
        if let Some(rem) = next_reminder_fire(&self.state.calendar, now, lead) {
            if self.last_cal_reminder_uid.as_deref() != Some(rem.event_uid.as_str()) {
                let wait_secs = rem.fire_epoch_secs.saturating_sub(now).max(1);
                self.schedule_named_timer(
                    "cal:reminder".to_string(),
                    Duration::from_secs(wait_secs),
                );
                return;
            }
        }
        self.cancel_named_timer("cal:reminder");
    }

    fn fire_hook(
        &self,
        event: &str,
        old: Option<String>,
        new: Option<String>,
        value: Option<String>,
    ) {
        let Some(cmd) = self.state.config.hooks.command_for(event) else {
            return;
        };
        if let Some(ref sys) = self.sys {
            sys.send(SysCommand::RunHook(HookRequest {
                command: cmd.to_string(),
                timeout_secs: self.state.config.hooks.timeout_secs,
                event: event.to_string(),
                old,
                new,
                value,
            }));
        }
    }

    fn init_extensions(&mut self) {
        let mut ctx = ShellContext::new(&mut self.state);
        for ext in &mut self.extensions {
            ext.on_init(&mut ctx);
        }
        let actions = std::mem::take(&mut ctx.actions);
        let dirty = ctx.dirty | DirtyFlags::ALL;
        self.execute_actions(actions);
        self.sync_ui_surfaces(dirty);
    }

    fn dispatch_system_event(&mut self, event: SystemEvent) {
        let mut wallpaper_updated_palette = false;
        let event = match event {
            SystemEvent::WallpaperReady {
                path,
                palette,
                buffers,
            } => {
                let prev_wall = self
                    .state
                    .wallpaper_path
                    .as_ref()
                    .map(|p| p.display().to_string());
                let next_wall = path.display().to_string();
                self.state.wallpaper_path = Some(path.clone());
                if prev_wall.as_deref() != Some(next_wall.as_str()) {
                    self.fire_hook(
                        "wallpaper_changed",
                        prev_wall,
                        Some(next_wall.clone()),
                        Some(next_wall),
                    );
                }
                let mut uploaded_meta = Vec::with_capacity(buffers.len());
                for (out_name, w, h, bgra) in buffers {
                    self.ui.set_wallpaper_buffer(&out_name, w, h, bgra);
                    uploaded_meta.push((out_name, w, h, Vec::new()));
                }
                let _ = self.wayland_conn.flush();
                if let Some(pal) = palette {
                    self.state.palette = *pal;
                    if let Err(err) = self.apply_templates() {
                        eprintln!("kaze-shell: dynamic wallpaper template apply failed: {err}");
                    }
                    wallpaper_updated_palette = true;
                }
                if let Some(resp) = self.pending_wallpaper_set.take() {
                    resp.send(&IpcResponse::ok(path.display().to_string()));
                }
                SystemEvent::WallpaperReady {
                    path,
                    palette: None,
                    buffers: uploaded_meta,
                }
            }
            SystemEvent::WallpaperFailed { error } => {
                if let Some(resp) = self.pending_wallpaper_set.take() {
                    resp.send(&IpcResponse::err(error.clone()));
                }
                SystemEvent::WallpaperFailed { error }
            }
            SystemEvent::ScreencopyReady {
                request_id,
                frames,
                mut windows,
            } => {
                if windows.is_empty() {
                    if let Some(ref client) = self.hypr_client {
                        if let Ok(list) = client.clients() {
                            windows = list;
                        }
                    }
                }
                SystemEvent::ScreencopyReady {
                    request_id,
                    frames,
                    windows,
                }
            }
            other => other,
        };

        match &event {
            SystemEvent::OutputAdded(info) | SystemEvent::OutputUpdated(info) => {
                self.state.outputs.insert(info.name.clone(), info.clone());
            }
            SystemEvent::OutputRemoved { name } => {
                self.state.outputs.remove(name);
            }
            SystemEvent::HyprSynced {
                monitors,
                workspaces,
                active_workspace_id,
                focused_monitor,
            } => {
                self.state.monitors = monitors.clone();
                self.state.workspaces = workspaces.clone();
                self.state.active_workspace_id = *active_workspace_id;
                self.state.focused_monitor = focused_monitor.clone();
            }
            SystemEvent::HyprWorkspaceChanged { id, .. } => {
                if *id > 0 {
                    self.state.active_workspace_id = *id;
                    if let Some(ref focused) = self.state.focused_monitor {
                        if let Some(mon) =
                            self.state.monitors.iter_mut().find(|m| &m.name == focused)
                        {
                            mon.active_workspace_id = *id;
                        }
                    }
                }
            }
            SystemEvent::HyprFocusedMonitor {
                monitor,
                workspace_id,
            } => {
                self.state.focused_monitor = Some(monitor.clone());
                for mon in &mut self.state.monitors {
                    mon.focused = mon.name == *monitor;
                    if mon.focused {
                        if let Some(ws_id) = workspace_id {
                            if *ws_id > 0 {
                                mon.active_workspace_id = *ws_id;
                                self.state.active_workspace_id = *ws_id;
                            }
                        }
                    }
                }
            }
            SystemEvent::HyprConnectionChanged { connected } => {
                self.state.hypr_connected = *connected;
            }
            SystemEvent::ClockTick(clock) => {
                self.state.clock = *clock;
            }
            SystemEvent::ThemeChanged(mode) => {
                let prev_mode = self.state.theme_mode;
                self.state.theme_mode = *mode;
                if prev_mode != *mode {
                    self.fire_hook(
                        "theme_mode_changed",
                        Some(prev_mode.as_str().to_string()),
                        Some(mode.as_str().to_string()),
                        Some(mode.as_str().to_string()),
                    );
                }
            }
            SystemEvent::LayoutPresetChanged(preset) => {
                let prev_preset = self.state.layout_preset;
                self.state.layout_preset = *preset;
                if prev_preset != *preset {
                    self.fire_hook(
                        "layout_changed",
                        Some(prev_preset.as_str().to_string()),
                        Some(preset.as_str().to_string()),
                        Some(preset.as_str().to_string()),
                    );
                }
            }
            SystemEvent::NetworkChanged(net) => {
                self.state.network = net.clone();
            }
            SystemEvent::BluetoothChanged(bt) => {
                self.state.bluetooth = bt.clone();
            }
            SystemEvent::BatteryChanged(bat) => {
                let prev_pct = self.state.battery.percentage;
                let prev_present = self.state.battery.present;
                let prev_charging = self.state.battery.charging;
                self.state.battery = bat.clone();
                if bat.present && (!prev_present || prev_pct != bat.percentage) {
                    self.fire_hook(
                        "battery_percentage_changed",
                        prev_present.then(|| prev_pct.to_string()),
                        Some(bat.percentage.to_string()),
                        Some(bat.percentage.to_string()),
                    );
                }
                if bat.present && (!prev_present || prev_charging != bat.charging) {
                    self.fire_hook(
                        "ac_state_changed",
                        prev_present
                            .then(|| if prev_charging { "ac" } else { "battery" }.to_string()),
                        Some(if bat.charging { "ac" } else { "battery" }.to_string()),
                        Some(if bat.charging { "ac" } else { "battery" }.to_string()),
                    );
                }
            }
            SystemEvent::AudioChanged { state, .. } => {
                self.state.audio = state.clone();
            }
            SystemEvent::BacklightChanged { state, .. } => {
                self.state.backlight = state.clone();
            }
            SystemEvent::MediaChanged(media) => {
                self.state.media = media.clone();
            }
            SystemEvent::NotificationsBusStatus { owned } => {
                self.state.notifications_bus_owned = *owned;
            }
            SystemEvent::DndChanged(dnd) => {
                let prev_dnd = self.state.dnd;
                self.state.dnd = *dnd;
                if prev_dnd != *dnd {
                    self.fire_hook(
                        "dnd_changed",
                        Some(if prev_dnd { "on" } else { "off" }.to_string()),
                        Some(if *dnd { "on" } else { "off" }.to_string()),
                        Some(if *dnd { "on" } else { "off" }.to_string()),
                    );
                }
            }
            SystemEvent::NightLightChanged { enabled, temp_k } => {
                self.state.nightlight_enabled = *enabled;
                self.state.nightlight_temp_k = *temp_k;
            }
            SystemEvent::CaffeineChanged(enabled) => {
                self.state.caffeine_enabled = *enabled;
            }
            SystemEvent::ControlCenterChanged(open) => {
                self.state.cc_open = *open;
            }
            SystemEvent::TrayBusStatus { owned } => {
                self.state.tray_bus_owned = *owned;
            }
            SystemEvent::TrayItemsChanged(items) => {
                self.state.tray_items = items.clone();
            }
            SystemEvent::ConfigReloaded
            | SystemEvent::FrameTick { .. }
            | SystemEvent::PointerClick { .. }
            | SystemEvent::PointerClickAt { .. }
            | SystemEvent::PointerDrag { .. }
            | SystemEvent::PointerScroll { .. }
            | SystemEvent::KeyInput { .. }
            | SystemEvent::ImeInput { .. }
            | SystemEvent::TimerFired { .. }
            | SystemEvent::NotificationReceived(_)
            | SystemEvent::NotificationCloseRequested { .. }
            | SystemEvent::NotificationDismissHistory { .. }
            | SystemEvent::NotificationClearAll
            | SystemEvent::NotificationsCountChanged(_)
            | SystemEvent::TrayMenuLoaded(_)
            | SystemEvent::WallpaperReady { .. }
            | SystemEvent::WallpaperFailed { .. }
            | SystemEvent::SurfaceClosed { .. }
            | SystemEvent::KeyboardFocusLost { .. } => {}
            SystemEvent::ApplicationsChanged => {
                self.state.desktop_apps = scan_applications();
            }
            SystemEvent::UserAccountChanged(acct) => {
                self.state.user_account = acct.clone();
            }
            SystemEvent::OfflineModeChanged(offline) => {
                self.state.offline_mode = *offline;
                self.sync_wave2_services();
            }
            SystemEvent::LocaleChanged(locale) => {
                self.state.locale = *locale;
            }
            SystemEvent::ClipboardTextPasted { .. } => {}
            SystemEvent::ClipboardOfferCaptured {
                mime,
                bytes,
                source_is_self,
            } => {
                if !*source_is_self {
                    self.ui.note_clipboard_captured(mime, bytes);
                }
            }
            SystemEvent::PowerProfileChanged(pp) => {
                let prev = self.state.power_profile.active.clone();
                self.state.power_profile = pp.clone();
                if !prev.is_empty() && !pp.active.is_empty() && prev != pp.active {
                    self.fire_hook(
                        "power_profile_changed",
                        Some(prev),
                        Some(pp.active.clone()),
                        Some(pp.active.clone()),
                    );
                }
            }
            SystemEvent::PrivacyChanged(priv_st) => {
                let was_sharing = !self.state.privacy.screenshare_apps.is_empty();
                let is_sharing = !priv_st.screenshare_apps.is_empty();
                let mut next = priv_st.clone();
                if was_sharing != is_sharing {
                    if let Some(ref client) = self.hypr_client {
                        client.set_privacy_noscreenshare(
                            &self.state.config.privacy.hide_on_share,
                            is_sharing,
                        );
                    }
                    next.noscreenshare_active = is_sharing;
                } else {
                    next.noscreenshare_active = self.state.privacy.noscreenshare_active;
                }
                self.state.privacy = next;
            }
            SystemEvent::AudioSpectrum(bars) => {
                self.state.audio_spectrum = bars.clone();
            }
            SystemEvent::PowerCapabilitiesChanged(caps) => {
                self.state.power_capabilities = caps.clone();
            }
            SystemEvent::SessionUnlockRequested => {
                if let Some(pid) = self.active_lock_pid {
                    // SAFETY: signal our own active lock-worker child to unlock on logind Unlock.
                    unsafe {
                        libc::kill(pid as i32, libc::SIGTERM);
                    }
                }
            }
            SystemEvent::IdleTimeout { .. } => {
                self.state.screentime = self.screentime.set_paused(true, epoch_secs_now());
            }
            SystemEvent::IdleResumed { .. } => {
                self.state.screentime = self.screentime.set_paused(false, epoch_secs_now());
            }
            SystemEvent::PrepareForSleep(_)
            | SystemEvent::SessionLockRequested
            | SystemEvent::PolkitBegin(_)
            | SystemEvent::PolkitCancel { .. }
            | SystemEvent::PolkitPrompt { .. }
            | SystemEvent::PolkitError { .. }
            | SystemEvent::PolkitComplete { .. } => {}
            SystemEvent::LockWorkerCommitted => {
                self.state.session_locked = true;
                self.state.screentime = self.screentime.set_paused(true, epoch_secs_now());
            }
            SystemEvent::LockWorkerExited => {
                self.state.session_locked = false;
                self.state.screentime = self.screentime.set_paused(false, epoch_secs_now());
            }
            SystemEvent::PolkitBusOwned(owned) => {
                self.state.polkit_bus_owned = *owned;
            }
            SystemEvent::WindowsUpdated {
                windows,
                active_address,
                fullscreen_outputs,
            } => {
                self.state.windows = windows.clone();
                self.state.active_window_address = active_address.clone();
                self.state.fullscreen_outputs = fullscreen_outputs.iter().cloned().collect();
                let live_addrs: std::collections::HashSet<&str> =
                    windows.iter().map(|w| w.address.as_str()).collect();
                self.state
                    .window_mru
                    .retain(|a| live_addrs.contains(a.as_str()));
                if let Some(ref active) = active_address {
                    if live_addrs.contains(active.as_str()) {
                        self.state.window_mru.retain(|a| a != active);
                        self.state.window_mru.insert(0, active.clone());
                    }
                }
                let mut rest: Vec<_> = windows
                    .iter()
                    .filter(|w| !self.state.window_mru.contains(&w.address))
                    .collect();
                rest.sort_by_key(|w| w.focus_history_id);
                for w in rest {
                    self.state.window_mru.push(w.address.clone());
                }
                let active_cls = self.state.active_window().map(|w| {
                    if w.class.is_empty() {
                        w.initial_class.clone()
                    } else {
                        w.class.clone()
                    }
                });
                self.state.screentime = self
                    .screentime
                    .on_focus_change(active_cls.as_deref(), epoch_secs_now());
            }
            SystemEvent::KeyboardLayoutChanged { raw_name, .. } => {
                self.state.keyboard.layout_raw = raw_name.clone();
                self.state.keyboard.layout_label =
                    resolve_keyboard_alias(raw_name, &self.state.config.bar.keyboard_aliases);
            }
            SystemEvent::LockKeysChanged {
                caps_lock,
                num_lock,
                scroll_lock,
            } => {
                self.state.keyboard.caps_lock = *caps_lock;
                self.state.keyboard.num_lock = *num_lock;
                self.state.keyboard.scroll_lock = *scroll_lock;
            }
            SystemEvent::ModifiersChanged {
                caps_lock,
                num_lock,
                scroll_lock,
                ..
            } => {
                if self.state.keyboard.caps_lock != *caps_lock
                    || self.state.keyboard.num_lock != *num_lock
                    || self.state.keyboard.scroll_lock != *scroll_lock
                {
                    self.state.keyboard.caps_lock = *caps_lock;
                    self.state.keyboard.num_lock = *num_lock;
                    self.state.keyboard.scroll_lock = *scroll_lock;
                }
            }
            SystemEvent::WidgetExecOutput {
                instance_id,
                output,
            } => {
                self.state
                    .widget_exec_outputs
                    .insert(instance_id.clone(), output.clone());
            }
            SystemEvent::SettingsOpenRequested { target } => {
                self.state.last_settings_target = Some(target.clone());
            }
            SystemEvent::SysmonUpdated(s) => {
                self.state.sysmon = s.clone();
            }
            SystemEvent::WeatherUpdated(w) => {
                self.state.weather = w.clone();
            }
            SystemEvent::ScreenTimeUpdated(st) => {
                self.state.screentime = st.clone();
            }
            SystemEvent::CalendarUpdated(c) => {
                self.state.calendar = c.clone();
                self.arm_next_calendar_reminder();
            }
            SystemEvent::PointerEnter { .. }
            | SystemEvent::PointerLeave { .. }
            | SystemEvent::PointerMotion { .. }
            | SystemEvent::PointerRelease { .. }
            | SystemEvent::WindowPreviewReady { .. }
            | SystemEvent::ScreencopyReady { .. }
            | SystemEvent::ScreencopyFailed { .. } => {}
        }
        if matches!(&event, SystemEvent::TimerFired { id } if id == "kaze:solar") {
            self.state.nightlight_manual_override = false;
            self.sync_solar_schedule(true);
        } else if matches!(&event, SystemEvent::TimerFired { id } if id == "cal:reminder") {
            let now = epoch_secs_now();
            let lead = self.state.config.calendar.reminder_lead_mins;
            if let Some(rem) = next_reminder_fire(&self.state.calendar, now, lead) {
                self.last_cal_reminder_uid = Some(rem.event_uid.clone());
                self.execute_actions(vec![ShellAction::SendNotification {
                    app_name: "kaze-calendar".to_string(),
                    summary: rem.title,
                    body: format!("Starts in {}m", rem.mins_before),
                }]);
            }
            self.arm_next_calendar_reminder();
        }

        let prev_unread = self.state.unread_notifications;
        let prev_cc_open = self.state.cc_open;
        let mut dirty = DirtyFlags::NONE;
        let mut actions = Vec::new();
        {
            let mut ctx = ShellContext::new(&mut self.state);
            for ext in &mut self.extensions {
                dirty |= ext.on_event(&event, &mut ctx);
            }
            dirty |= ctx.dirty;
            actions.extend(ctx.actions);
        }

        self.execute_actions(actions);
        if !dirty.is_empty() {
            self.sync_ui_surfaces(dirty);
        }
        if wallpaper_updated_palette {
            self.dispatch_system_event(SystemEvent::ThemeChanged(self.state.theme_mode));
        }

        if !matches!(event, SystemEvent::ControlCenterChanged(_))
            && self.state.cc_open != prev_cc_open
        {
            self.dispatch_system_event(SystemEvent::ControlCenterChanged(self.state.cc_open));
        }

        if !matches!(event, SystemEvent::NotificationsCountChanged(_))
            && self.state.unread_notifications != prev_unread
        {
            self.dispatch_system_event(SystemEvent::NotificationsCountChanged(
                self.state.unread_notifications,
            ));
        }
    }

    fn sync_ui_surfaces(&mut self, dirty: DirtyFlags) {
        let mut specs = Vec::new();
        for ext in &self.extensions {
            specs.extend(ext.surfaces());
        }
        let has_capture_surface = specs
            .iter()
            .any(|s| s.id.starts_with("capture:") || s.id.starts_with("picker:"));
        self.ui.sync_surfaces(specs, dirty);
        let _ = self.wayland_conn.flush();
        if dirty.contains(DirtyFlags::CAPTURE) && !has_capture_surface {
            #[cfg(target_env = "gnu")]
            // SAFETY: immediately returns freed capture RGBA/SlotPool heap pages to kernel.
            unsafe {
                libc::malloc_trim(0);
            }
        }
    }

    fn execute_actions(&mut self, actions: Vec<ShellAction>) {
        for action in actions {
            match action {
                ShellAction::HyprDispatch(cmd) => {
                    if let Some(ref client) = self.hypr_client {
                        let res = if let Some(ws_id) = cmd
                            .strip_prefix("workspace ")
                            .and_then(|s| s.trim().parse::<i32>().ok())
                        {
                            client.switch_workspace(ws_id)
                        } else {
                            client.dispatch(&cmd)
                        };
                        if let Err(err) = res {
                            eprintln!("kaze-shell: hypr dispatch '{cmd}' failed: {err}");
                        }
                    }
                }
                ShellAction::SpawnCommand { program, args } => {
                    self.spawn_child(&program, &args);
                }
                ShellAction::SpawnDetachedApp { program, args } => {
                    self.spawn_detached_scope(&program, &args);
                }
                ShellAction::ApplyTemplates => {
                    if let Err(err) = self.apply_templates() {
                        eprintln!("kaze-shell: template apply failed: {err}");
                    }
                }
                ShellAction::ReloadConfig => {
                    let _ = self.reload_config();
                }
                ShellAction::SyncSurfaces => {
                    self.sync_ui_surfaces(DirtyFlags::ALL);
                }
                ShellAction::ScheduleTimer { id, after_ms } => {
                    self.schedule_named_timer(id, Duration::from_millis(after_ms));
                }
                ShellAction::CancelTimer { id } => {
                    self.cancel_named_timer(&id);
                }
                ShellAction::AudioStepVolume(delta) => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::AudioStepVolume(delta));
                    }
                }
                ShellAction::AudioSetVolume(pct) => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::AudioSetVolume(pct));
                    }
                }
                ShellAction::AudioToggleMute => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::AudioToggleMute);
                    }
                }
                ShellAction::AudioToggleMicMute => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::AudioToggleMicMute);
                    }
                }
                ShellAction::BacklightStep(delta) => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::BacklightStep(delta));
                    }
                }
                ShellAction::BacklightSet(pct) => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::BacklightSet(pct));
                    }
                }
                ShellAction::MediaCommand(cmd) => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::MediaCommand(cmd));
                    }
                }
                ShellAction::WifiToggle => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::WifiToggle);
                    }
                }
                ShellAction::BluetoothToggle => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::BluetoothToggle);
                    }
                }
                ShellAction::SetNightLight { enabled, temp_k } => {
                    self.apply_nightlight(enabled, temp_k);
                }
                ShellAction::SetCaffeine(enabled) => {
                    self.apply_caffeine(enabled);
                }
                ShellAction::ThemeModeToggle => {
                    let next = self.state.theme_mode.toggled();
                    self.state.theme_mode = next;
                    if let Err(err) = self.apply_templates() {
                        eprintln!("kaze-shell: theme toggle template apply failed: {err}");
                    }
                    self.dispatch_system_event(SystemEvent::ThemeChanged(next));
                }
                ShellAction::LayoutCycle => {
                    let next = self.state.layout_preset.next();
                    let _ = self.apply_layout_preset(next, true);
                }
                ShellAction::ToggleControlCenter => {
                    self.invoke_extension_ipc("cc-toggle", &[]);
                }
                ShellAction::SystemPower(action) => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::SystemPower(action));
                    }
                }
                ShellAction::NotifyClosed { id, reason } => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::NotifyClosed { id, reason });
                    }
                }
                ShellAction::NotifyActionInvoked { id, action_key } => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::NotifyActionInvoked { id, action_key });
                    }
                }
                ShellAction::DismissHistoryNotification(id) => {
                    self.dispatch_system_event(SystemEvent::NotificationDismissHistory { id });
                }
                ShellAction::SetDnd(dnd) => {
                    self.dispatch_system_event(SystemEvent::DndChanged(dnd));
                }
                ShellAction::ClearNotifications => {
                    self.dispatch_system_event(SystemEvent::NotificationClearAll);
                }
                ShellAction::TrayActivate {
                    service,
                    object_path,
                    x,
                    y,
                    secondary,
                } => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::TrayActivate {
                            service,
                            object_path,
                            x,
                            y,
                            secondary,
                        });
                    }
                }
                ShellAction::TrayOpenMenu { service, menu_path } => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::TrayOpenMenu { service, menu_path });
                    }
                }
                ShellAction::TrayMenuClick {
                    service,
                    menu_path,
                    item_id,
                } => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::TrayMenuClick {
                            service,
                            menu_path,
                            item_id,
                        });
                    }
                }
                ShellAction::RequestWallpaperLoad {
                    path,
                    outputs,
                    extract_palette,
                } => {
                    let tx = self.event_tx.clone();
                    let _ = std::thread::Builder::new()
                        .name("kaze-wallpaper".to_string())
                        .spawn(move || {
                            match load_wallpaper_job(&path, &outputs, extract_palette) {
                                Ok((palette, buffers)) => {
                                    let _ = tx.send(SystemEvent::WallpaperReady {
                                        path,
                                        palette: palette.map(Box::new),
                                        buffers,
                                    });
                                }
                                Err(err) => {
                                    eprintln!("kaze-shell: wallpaper load failed: {err}");
                                    let _ = tx.send(SystemEvent::WallpaperFailed { error: err });
                                }
                            }
                            #[cfg(target_env = "gnu")]
                            // SAFETY: releases decoded source image arena pages back to the kernel.
                            unsafe {
                                libc::malloc_trim(0);
                            }
                        });
                }
                ShellAction::ClearWallpaper => {
                    self.ui.clear_wallpapers();
                    let _ = self.wayland_conn.flush();
                }
                ShellAction::DmenuReply { selected } => {
                    if let Some(responder) = self.pending_dmenu.take() {
                        match selected {
                            Some(line) => responder.send(&IpcResponse::ok(line)),
                            None => responder.send(&IpcResponse::err("cancelled")),
                        }
                    }
                }
                ShellAction::RunHook {
                    event,
                    old,
                    new,
                    value,
                } => {
                    self.fire_hook(&event, old, new, value);
                }
                ShellAction::SetClipboardText(text) => {
                    self.ui.set_clipboard_selection(
                        "text/plain;charset=utf-8".into(),
                        text.into_bytes(),
                    );
                    self.pump_clipboard_pipes();
                    let _ = self.wayland_conn.flush();
                }
                ShellAction::SetClipboardSelection { mime, bytes } => {
                    self.ui.set_clipboard_selection(mime, bytes);
                    self.pump_clipboard_pipes();
                    let _ = self.wayland_conn.flush();
                }
                ShellAction::RequestClipboardPaste { surface_id } => {
                    if self.ui.request_clipboard_paste_text(surface_id) {
                        self.pump_clipboard_pipes();
                        let _ = self.wayland_conn.flush();
                    }
                }
                ShellAction::SetPowerProfile(prof) => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::SetPowerProfile(prof));
                    }
                }
                ShellAction::SetBrightnessMonitor { monitor, pct } => {
                    self.apply_monitor_brightness(&monitor, pct);
                }
                ShellAction::AudioSetDefaultSink(name) => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::AudioSetDefaultSink(name));
                    }
                }
                ShellAction::AudioSetDefaultSource(name) => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::AudioSetDefaultSource(name));
                    }
                }
                ShellAction::AudioSetStreamVolume { index, pct } => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::AudioSetStreamVolume { index, pct });
                    }
                }
                ShellAction::AudioSetStreamMute { index, muted } => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::AudioSetStreamMute { index, muted });
                    }
                }
                ShellAction::AudioSetSpectrumSubscribed(count) => {
                    if count > 0 {
                        self.state.spectrum_subscribers.insert("ipc".to_string());
                    } else {
                        self.state.spectrum_subscribers.remove("ipc");
                    }
                    let effective = count.max(self.state.spectrum_subscribers.len());
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::AudioSetSpectrumSubscribers {
                            count: effective,
                            fps: self.state.config.audio.spectrum_frame_rate,
                        });
                    }
                }
                ShellAction::SetSpectrumSubscriber { owner, active } => {
                    if active {
                        self.state.spectrum_subscribers.insert(owner);
                    } else {
                        self.state.spectrum_subscribers.remove(&owner);
                    }
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::AudioSetSpectrumSubscribers {
                            count: self.state.spectrum_subscribers.len(),
                            fps: self.state.config.audio.spectrum_frame_rate,
                        });
                    }
                }
                ShellAction::SetSysmonSubscriber { owner, active } => {
                    if active {
                        self.state.sysmon_subscribers.insert(owner);
                    } else {
                        self.state.sysmon_subscribers.remove(&owner);
                    }
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::SetSysmonSubscribers(
                            self.state.sysmon_subscribers.len(),
                        ));
                    }
                }
                ShellAction::RunWidgetExec {
                    instance_id,
                    command,
                } => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::RunWidgetExec {
                            instance_id,
                            command,
                        });
                    }
                }
                ShellAction::SettingsOpen(target) => {
                    self.state.last_settings_target = Some(target.clone());
                    self.dispatch_system_event(SystemEvent::SettingsOpenRequested { target });
                }
                ShellAction::PersistSetting { key, value_toml } => {
                    if let Some(ref sp) = self.settings_path {
                        if let Err(err) = SettingsStore::set_override(sp, &key, &value_toml) {
                            eprintln!("kaze-shell: persist setting '{key}' failed: {err}");
                        } else {
                            let _ = self.reload_config();
                        }
                    }
                }
                ShellAction::PersistCanvasWidgets(widgets) => {
                    if let Some(ref sp) = self.settings_path {
                        if let Err(err) = SettingsStore::set_canvas_widgets(sp, &widgets) {
                            eprintln!("kaze-shell: persist canvas widgets failed: {err}");
                        } else {
                            let _ = self.reload_config();
                        }
                    }
                }
                ShellAction::ConfigureIdleTimeouts(stages) => {
                    self.ui.configure_idle_timeouts(&stages);
                    let _ = self.wayland_conn.flush();
                }
                ShellAction::SetOutputsDpms(on) => {
                    self.state.outputs_dpms_off = !on;
                    self.ui.set_outputs_dpms(on);
                    let _ = self.wayland_conn.flush();
                }
                ShellAction::ReleaseSleepInhibitor => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::ReleaseSleepInhibitor);
                    }
                }
                ShellAction::LockSession => {
                    self.spawn_lock_worker();
                }
                ShellAction::PolkitSubmitPassword {
                    cookie,
                    user,
                    password,
                } => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::PolkitSubmitPassword {
                            cookie,
                            user,
                            password: zeroize::Zeroizing::new(password),
                        });
                    }
                }
                ShellAction::PolkitCancel { cookie } => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::PolkitCancel { cookie });
                    }
                }
                ShellAction::RequestScreencopy { request_id } => {
                    if let Err(err) = self.ui.request_screencopy(request_id) {
                        if let Some(resp) = self.pending_capture_reply.take() {
                            resp.send(&IpcResponse::err(err.clone()));
                        }
                        self.dispatch_system_event(SystemEvent::ScreencopyFailed {
                            request_id,
                            error: err,
                        });
                    } else {
                        let _ = self.wayland_conn.flush();
                    }
                }
                ShellAction::CaptureReply { text } => {
                    if let Some(resp) = self.pending_capture_reply.take() {
                        match text {
                            Some(t) => resp.send(&IpcResponse::ok(t)),
                            None => resp.send(&IpcResponse::err("cancelled")),
                        }
                    }
                }
                ShellAction::SendNotification {
                    app_name,
                    summary,
                    body,
                } => {
                    let secs = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map(|d| d.as_secs())
                        .unwrap_or(0);
                    self.dispatch_system_event(SystemEvent::NotificationReceived(
                        NotificationItem {
                            id: 0x8000_0000 | ((secs as u32) & 0x00ff_ffff),
                            app_name,
                            summary,
                            body,
                            app_icon: String::new(),
                            urgency: NotificationUrgency::Normal,
                            actions: Vec::new(),
                            expire_timeout_ms: 3000,
                            resident: false,
                            transient: true,
                            sync_tag: None,
                            timestamp_epoch_secs: secs,
                            progress_value: None,
                        },
                    ));
                }
                ShellAction::RequestWindowPreviews {
                    request_id,
                    windows,
                } => {
                    self.ui.request_window_previews(
                        request_id,
                        &windows,
                        self.state.config.switcher.max_preview_width,
                    );
                    let _ = self.wayland_conn.flush();
                }
                ShellAction::NetworkRequestScan => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::NetworkRequestScan);
                    }
                }
                ShellAction::WifiConnect { ssid, password } => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::WifiConnect { ssid, password });
                    }
                }
                ShellAction::WifiDisconnect => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::WifiDisconnect);
                    }
                }
                ShellAction::WifiForget(ssid) => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::WifiForget(ssid));
                    }
                }
                ShellAction::VpnToggle(uuid) => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::VpnToggle(uuid));
                    }
                }
                ShellAction::BluetoothSetDiscovery(active) => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::BluetoothSetDiscovery(active));
                    }
                }
                ShellAction::BluetoothPair(path) => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::BluetoothPair(path));
                    }
                }
                ShellAction::BluetoothTrust { path, trusted } => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::BluetoothTrust { path, trusted });
                    }
                }
                ShellAction::BluetoothConnect(path) => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::BluetoothConnect(path));
                    }
                }
                ShellAction::BluetoothDisconnect(path) => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::BluetoothDisconnect(path));
                    }
                }
                ShellAction::BluetoothRemove(path) => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::BluetoothRemove(path));
                    }
                }
                ShellAction::WeatherRefresh => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::WeatherRefresh);
                    }
                }
                ShellAction::ScreenTimeReset => {
                    let st = self.screentime.reset(epoch_secs_now());
                    self.dispatch_system_event(SystemEvent::ScreenTimeUpdated(st));
                }
                ShellAction::CalendarSyncNow => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::CalendarSyncNow);
                    }
                }
            }
        }
    }

    fn schedule_named_timer(&mut self, id: String, duration: Duration) {
        self.cancel_named_timer(&id);
        let timer = Timer::from_duration(duration);
        let fired_id = id.clone();
        if let Ok(token) = self.loop_handle.insert_source(timer, move |_, _, daemon| {
            daemon.timers.remove(&fired_id);
            daemon.dispatch_system_event(SystemEvent::TimerFired {
                id: fired_id.clone(),
            });
            TimeoutAction::Drop
        }) {
            self.timers.insert(id, token);
        }
    }

    fn cancel_named_timer(&mut self, id: &str) {
        if let Some(token) = self.timers.remove(id) {
            self.loop_handle.remove(token);
        }
    }

    fn spawn_child(&mut self, program: &str, args: &[String]) {
        self.reap_children();
        match Command::new(program)
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
        {
            Ok(child) => self.children.push(child),
            Err(err) => eprintln!("kaze-shell: failed spawning '{program}': {err}"),
        }
    }

    /// Launches user apps in a separate systemd user scope so restarting `kaze-shell.service`
    /// never terminates windows opened from the bar or launcher.
    fn spawn_detached_scope(&mut self, program: &str, args: &[String]) {
        self.reap_children();
        let mut scope_args = vec![
            "--user".to_string(),
            "--scope".to_string(),
            "--quiet".to_string(),
            "--".to_string(),
            program.to_string(),
        ];
        scope_args.extend(args.iter().cloned());
        match Command::new("systemd-run")
            .args(&scope_args)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
        {
            Ok(child) => self.children.push(child),
            Err(_) => self.spawn_setsid(program, args),
        }
    }

    fn spawn_setsid(&mut self, program: &str, args: &[String]) {
        let mut cmd = Command::new(program);
        cmd.args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        // SAFETY: `setsid` is async-signal-safe and detaches the launched app into its own session.
        unsafe {
            cmd.pre_exec(|| {
                libc::setsid();
                Ok(())
            });
        }
        match cmd.spawn() {
            Ok(child) => self.children.push(child),
            Err(err) => eprintln!("kaze-shell: failed spawning detached '{program}': {err}"),
        }
    }

    fn reap_children(&mut self) {
        let mut lock_exited = false;
        self.children.retain_mut(|child| {
            let pid = child.id();
            match child.try_wait() {
                Ok(None) => true,
                _ => {
                    if self.active_lock_pid == Some(pid) {
                        lock_exited = true;
                    }
                    false
                }
            }
        });
        if lock_exited {
            self.handle_lock_worker_exit();
        }
    }

    fn handle_lock_worker_exit(&mut self) {
        if let Some(token) = self.lock_pipe_token.take() {
            self.loop_handle.remove(token);
        }
        if self.active_lock_pid.take().is_some() {
            self.lock_committed = false;
            if let Some(prev_dnd) = self.pre_lock_dnd.take() {
                self.dispatch_system_event(SystemEvent::DndChanged(prev_dnd));
            }
            self.fire_hook("session_unlocked", None, None, None);
            self.dispatch_system_event(SystemEvent::LockWorkerExited);
        }
    }

    fn spawn_lock_worker(&mut self) {
        self.reap_children();
        if self.active_lock_pid.is_some() {
            if self.lock_committed {
                self.dispatch_system_event(SystemEvent::LockWorkerCommitted);
            }
            return;
        }
        let Ok(exe) = std::env::current_exe() else {
            eprintln!("kaze-shell: unable to locate current_exe for lock-worker");
            return;
        };
        let Ok((parent_sock, child_sock)) = UnixStream::pair() else {
            eprintln!("kaze-shell: failed creating lock-worker socketpair");
            return;
        };
        let _ = parent_sock.set_nonblocking(true);
        let child_raw = child_sock.into_raw_fd();

        let cfg = &self.state.config.lockscreen;
        let mut args = vec![
            "lock-worker".to_string(),
            "--ipc-fd".to_string(),
            child_raw.to_string(),
            "--pam-service".to_string(),
            cfg.pam_service.clone(),
            "--grace-secs".to_string(),
            cfg.grace_secs.to_string(),
            "--bg".to_string(),
            cfg.background_color.clone(),
            "--font".to_string(),
            self.state.config.bar.font.clone(),
            "--font-scale".to_string(),
            format!("{:.2}", self.state.effective_font_scale),
            "--locale".to_string(),
            self.state.locale.as_str().to_string(),
        ];
        if !self.state.user_account.username.is_empty() {
            args.push("--username".into());
            args.push(self.state.user_account.username.clone());
        }
        if !self.state.user_account.real_name.is_empty() {
            args.push("--real-name".into());
            args.push(self.state.user_account.real_name.clone());
        }
        if let Some(ref avatar) = self.state.user_account.icon_path {
            args.push("--avatar".into());
            args.push(avatar.display().to_string());
        }
        if let Some(ref wall) = self.state.wallpaper_path {
            args.push("--wallpaper".into());
            args.push(wall.display().to_string());
        }
        if !cfg.fprintd {
            args.push("--no-fprintd".into());
        }
        if !cfg.blur {
            args.push("--no-blur".into());
        }
        if self.state.config.accessibility.high_contrast {
            args.push("--high-contrast".into());
        }

        let mut cmd = Command::new(exe);
        cmd.args(&args)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::inherit());
        // SAFETY: `setsid` and `fcntl(F_SETFD)` are async-signal-safe; clears FD_CLOEXEC only in child.
        unsafe {
            cmd.pre_exec(move || {
                libc::setsid();
                let flags = libc::fcntl(child_raw, libc::F_GETFD);
                if flags >= 0 {
                    libc::fcntl(child_raw, libc::F_SETFD, flags & !libc::FD_CLOEXEC);
                }
                Ok(())
            });
        }

        let spawned = cmd.spawn();
        // SAFETY: parent always closes its copy of `child_raw` after fork/exec.
        unsafe {
            drop(OwnedFd::from_raw_fd(child_raw));
        }

        let child = match spawned {
            Ok(c) => c,
            Err(err) => {
                eprintln!("kaze-shell: failed spawning lock-worker: {err}");
                return;
            }
        };
        self.active_lock_pid = Some(child.id());
        self.lock_committed = false;
        self.children.push(child);

        if let Some(old_token) = self.lock_pipe_token.take() {
            self.loop_handle.remove(old_token);
        }
        let mut buf_acc = Vec::<u8>::new();
        let source = Generic::new(parent_sock, Interest::READ, Mode::Level);
        if let Ok(token) = self
            .loop_handle
            .insert_source(source, move |_, sock, daemon| {
                let mut tmp = [0u8; 128];
                let sock_ref = unsafe { sock.get_mut() };
                loop {
                    match sock_ref.read(&mut tmp) {
                        Ok(0) => {
                            daemon.lock_pipe_token = None;
                            daemon.handle_lock_worker_exit();
                            return Ok(PostAction::Remove);
                        }
                        Ok(n) => {
                            buf_acc.extend_from_slice(&tmp[..n]);
                            if !daemon.lock_committed
                                && buf_acc.windows(22).any(|w| w == b"LOCKED_FRAME_COMMITTED")
                            {
                                daemon.lock_committed = true;
                                if daemon.state.config.lockscreen.dnd
                                    && daemon.pre_lock_dnd.is_none()
                                {
                                    daemon.pre_lock_dnd = Some(daemon.state.dnd);
                                    if !daemon.state.dnd {
                                        daemon.dispatch_system_event(SystemEvent::DndChanged(true));
                                    }
                                }
                                daemon.fire_hook("session_locked", None, None, None);
                                daemon.dispatch_system_event(SystemEvent::LockWorkerCommitted);
                            }
                        }
                        Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {
                            return Ok(PostAction::Continue);
                        }
                        Err(_) => {
                            daemon.lock_pipe_token = None;
                            daemon.handle_lock_worker_exit();
                            return Ok(PostAction::Remove);
                        }
                    }
                }
            })
        {
            self.lock_pipe_token = Some(token);
        }
    }

    fn apply_templates(&mut self) -> Result<String, String> {
        let generated = generate_all_templates(
            &self.state.palette,
            self.state.theme_mode,
            &self.theme_paths,
            true,
        )?;
        self.push_live_hypr_colors(
            &generated.hypr_active_border,
            &generated.hypr_inactive_border,
            &generated.hypr_eval_lua,
        );
        Ok(format!(
            "applied {} ({}, btop_signaled={})",
            self.state.palette.name,
            self.state.theme_mode.as_str(),
            generated.btop_signaled
        ))
    }

    fn push_live_hypr_colors(&self, active: &str, inactive: &str, eval_lua: &str) {
        let Some(ref client) = self.hypr_client else {
            return;
        };
        let eval_ok = client
            .eval(eval_lua)
            .is_ok_and(|resp| !resp.contains("unknown request") && !resp.contains("error"));
        if !eval_ok {
            let _ = client.keyword("general:col.active_border", active);
            let _ = client.keyword("general:col.inactive_border", inactive);
        }
    }

    fn apply_layout_preset(&mut self, preset: LayoutPreset, persist: bool) -> Result<(), String> {
        self.state.layout_preset = preset;
        if persist {
            if let Some(ref path) = self.layout_state_file {
                if let Err(err) = save_persisted_preset(path, preset) {
                    eprintln!("kaze-shell: failed persisting layout preset: {err}");
                }
            }
        }
        self.push_live_hypr_layout(preset);
        self.dispatch_system_event(SystemEvent::LayoutPresetChanged(preset));
        Ok(())
    }

    fn push_live_hypr_layout(&self, preset: LayoutPreset) {
        let Some(ref client) = self.hypr_client else {
            return;
        };
        let geom = preset.hypr_geometry();
        if let Err(err) = client.apply_layout_geometry(&geom) {
            eprintln!("kaze-shell: applying Hyprland layout geometry failed: {err}");
        }
    }

    fn apply_nightlight(&mut self, enabled: bool, temp_k: u32) {
        let clamped = temp_k.clamp(2500, 6500);
        let _applied_native = self.ui.set_nightlight(enabled, clamped);
        let _ = self.wayland_conn.flush();
        self.dispatch_system_event(SystemEvent::NightLightChanged {
            enabled,
            temp_k: clamped,
        });
    }

    fn apply_monitor_brightness(&mut self, monitor: &str, pct: u8) {
        let clamped = pct.clamp(1, 100);
        if monitor == "all" || monitor == "internal" {
            if let Some(ref sys) = self.sys {
                sys.send(SysCommand::BacklightSet(clamped));
            }
        }
        if monitor != "internal" {
            if let Some(ref sys) = self.sys {
                sys.send(SysCommand::DdcSetBrightness {
                    monitor: monitor.to_string(),
                    pct: clamped,
                    cfg: self.state.config.brightness.clone(),
                });
            }
        }
    }

    fn sync_solar_schedule(&mut self, apply_now: bool) {
        let loc = self.state.config.location.clone();
        if !loc.auto_nightlight && !loc.auto_brightness && !self.state.nightlight_auto {
            self.cancel_named_timer("kaze:solar");
            return;
        }
        let tr = evaluate_solar_now(
            loc.lat,
            loc.lon,
            &loc.fallback_sunrise,
            &loc.fallback_sunset,
        );
        if (apply_now || !self.state.nightlight_manual_override)
            && (loc.auto_nightlight || self.state.nightlight_auto)
        {
            if tr.is_daytime {
                self.apply_nightlight(loc.day_temp_k < 6500, loc.day_temp_k);
            } else {
                self.apply_nightlight(true, loc.night_temp_k);
            }
        }
        if loc.auto_brightness && !self.state.nightlight_manual_override {
            let target_pct = if tr.is_daytime {
                loc.day_brightness
            } else {
                loc.night_brightness
            };
            self.apply_monitor_brightness("all", target_pct);
        }
        self.schedule_named_timer("kaze:solar".to_string(), tr.next_transition_in);
    }

    fn apply_caffeine(&mut self, enabled: bool) {
        let _ = self.ui.set_caffeine(enabled);
        let _ = self.wayland_conn.flush();
        if let Some(ref sys) = self.sys {
            sys.send(SysCommand::SetCaffeineInhibit(enabled));
        }
        self.dispatch_system_event(SystemEvent::CaffeineChanged(enabled));
    }

    fn invoke_extension_ipc(&mut self, cmd: &str, args: &[String]) {
        let prev_cc_open = self.state.cc_open;
        let mut dirty = DirtyFlags::NONE;
        let mut actions = Vec::new();
        {
            let mut ctx = ShellContext::new(&mut self.state);
            for ext in &mut self.extensions {
                if let IpcResult::Handled {
                    dirty: ext_dirty, ..
                } = ext.on_ipc(cmd, args, &mut ctx)
                {
                    dirty |= ext_dirty | ctx.dirty;
                    break;
                }
            }
            actions.extend(ctx.actions);
        }
        self.execute_actions(actions);
        if !dirty.is_empty() {
            self.sync_ui_surfaces(dirty);
        }
        if self.state.cc_open != prev_cc_open {
            self.dispatch_system_event(SystemEvent::ControlCenterChanged(self.state.cc_open));
        }
    }

    fn pump_clipboard_pipes(&mut self) {
        let Some(ref sys) = self.sys else {
            return;
        };
        for read_job in self.ui.drain_clipboard_pipe_reads() {
            sys.send(SysCommand::ReadClipboardPipe {
                mime: read_job.mime,
                fd: read_job.fd,
                max_bytes: read_job.max_bytes,
                source_is_self: read_job.source_is_self,
                paste_surface_id: read_job.paste_surface_id,
            });
        }
        for write_job in self.ui.drain_clipboard_pipe_writes() {
            sys.send(SysCommand::WriteClipboardFd {
                fd: write_job.fd,
                bytes: write_job.bytes,
            });
        }
    }

    fn reload_config(&mut self) -> Result<(), String> {
        match Config::load_layered(&self.config_path, self.settings_path.as_deref()) {
            Ok(new_cfg) => {
                let mode = new_cfg.theme.mode;
                let offline = new_cfg.network.offline_mode;
                let prev_locale = self.state.locale;
                let new_locale = Locale::resolve(&new_cfg.general.locale);
                let new_font_scale = AppState::compute_effective_font_scale(&new_cfg);
                let high_contrast = new_cfg.accessibility.high_contrast;
                let palette = ResolvedPalette::load(
                    &new_cfg.theme.palette,
                    new_cfg.theme.palettes_dir.as_deref(),
                );
                self.ui.set_font(&new_cfg.bar.font);
                self.ui.set_accessibility(new_font_scale, high_contrast);
                self.ui.configure_clipboard(
                    new_cfg.clipboard.ignore_mimes.clone(),
                    new_cfg.clipboard.max_item_bytes,
                    new_cfg.clipboard.persist,
                );
                self.state.config = new_cfg;
                self.state.theme_mode = mode;
                self.state.offline_mode = offline;
                self.state.locale = new_locale;
                self.state.effective_font_scale = new_font_scale;
                self.state.palette = palette;
                if let Err(err) = self.apply_templates() {
                    eprintln!("kaze-shell: template regeneration after reload failed: {err}");
                }
                if prev_locale != new_locale {
                    self.dispatch_system_event(SystemEvent::LocaleChanged(new_locale));
                }
                self.dispatch_system_event(SystemEvent::ConfigReloaded);
                self.sync_solar_schedule(false);
                self.sync_wave2_services();
                Ok(())
            }
            Err(err) => {
                eprintln!("kaze-shell: config reload warning (keeping active config): {err}");
                Err(err)
            }
        }
    }

    fn handle_ipc(&mut self, req: IpcRequest, responder: IpcResponder) {
        if req.cmd == "dmenu-open" {
            if let Some(prev) = self.pending_dmenu.take() {
                prev.send(&IpcResponse::err("cancelled"));
            }
            self.pending_dmenu = Some(responder);

            let mut handled = false;
            let mut dirty = DirtyFlags::NONE;
            let mut actions = Vec::new();
            {
                let mut ctx = ShellContext::new(&mut self.state);
                for ext in &mut self.extensions {
                    if let IpcResult::Handled {
                        ok,
                        dirty: ext_dirty,
                        ..
                    } = ext.on_ipc(&req.cmd, &req.args, &mut ctx)
                    {
                        handled = ok;
                        dirty |= ext_dirty | ctx.dirty;
                        break;
                    }
                }
                actions.extend(ctx.actions);
            }
            self.execute_actions(actions);
            if !dirty.is_empty() {
                self.sync_ui_surfaces(dirty);
            }
            if !handled {
                if let Some(resp) = self.pending_dmenu.take() {
                    resp.send(&IpcResponse::err("launcher unavailable"));
                }
            }
            return;
        }

        if req.cmd == "capture"
            && req
                .args
                .iter()
                .any(|a| a == "--geom-only" || a == "--save-only")
        {
            if let Some(prev) = self.pending_capture_reply.take() {
                prev.send(&IpcResponse::err("cancelled"));
            }
            self.pending_capture_reply = Some(responder);

            let mut handled = false;
            let mut msg = String::new();
            let mut dirty = DirtyFlags::NONE;
            let mut actions = Vec::new();
            {
                let mut ctx = ShellContext::new(&mut self.state);
                for ext in &mut self.extensions {
                    if let IpcResult::Handled {
                        ok,
                        message,
                        dirty: ext_dirty,
                    } = ext.on_ipc(&req.cmd, &req.args, &mut ctx)
                    {
                        handled = ok;
                        msg = message;
                        dirty |= ext_dirty | ctx.dirty;
                        break;
                    }
                }
                actions.extend(ctx.actions);
            }
            self.execute_actions(actions);
            if !dirty.is_empty() {
                self.sync_ui_surfaces(dirty);
            }
            if !handled {
                if let Some(resp) = self.pending_capture_reply.take() {
                    resp.send(&IpcResponse::err(if msg.is_empty() {
                        "capture failed".into()
                    } else {
                        msg
                    }));
                }
            }
            return;
        }

        if req.cmd == "wallpaper-set" {
            let Some(raw) = req.args.first() else {
                responder.send(&IpcResponse::err("usage: wallpaper-set <path>"));
                return;
            };
            let path = expand_tilde(raw);
            if let Err(err) = validate_wallpaper_file(&path) {
                responder.send(&IpcResponse::err(err));
                return;
            }
            let outputs: Vec<(String, u32, u32)> = self
                .state
                .outputs
                .values()
                .filter(|o| o.name != "kaze-share" && o.width > 0 && o.height > 0)
                .map(|o| (o.name.clone(), o.width as u32, o.height as u32))
                .collect();
            if outputs.is_empty() {
                self.state.wallpaper_path = Some(path.clone());
                responder.send(&IpcResponse::ok(format!("queued {}", path.display())));
                return;
            }
            if let Some(prev) = self.pending_wallpaper_set.take() {
                prev.send(&IpcResponse::err("superseded by newer wallpaper-set"));
            }
            self.pending_wallpaper_set = Some(responder);
            self.execute_actions(vec![ShellAction::RequestWallpaperLoad {
                path,
                outputs,
                extract_palette: self.state.config.wallpaper.dynamic_palette,
            }]);
            return;
        }

        let resp = match req.cmd.as_str() {
            "ping" => IpcResponse::ok("pong"),
            "theme-mode-toggle" => {
                let next = self.state.theme_mode.toggled();
                self.state.theme_mode = next;
                match self.apply_templates() {
                    Ok(_) => {
                        self.dispatch_system_event(SystemEvent::ThemeChanged(next));
                        IpcResponse::ok(next.as_str())
                    }
                    Err(err) => IpcResponse::err(err),
                }
            }
            "templates-apply" => match self.apply_templates() {
                Ok(msg) => IpcResponse::ok(msg),
                Err(err) => IpcResponse::err(err),
            },
            "reload" => match self.reload_config() {
                Ok(()) => IpcResponse::ok("reloaded"),
                Err(err) => IpcResponse::err(err),
            },
            "layout-set" => {
                let Some(name) = req.args.first().map(String::as_str) else {
                    responder.send(&IpcResponse::err(
                        "usage: layout-set <omarchy|island|swiss|ghost>",
                    ));
                    return;
                };
                match LayoutPreset::from_name(name) {
                    Some(preset) => match self.apply_layout_preset(preset, true) {
                        Ok(()) => IpcResponse::ok(preset.as_str()),
                        Err(err) => IpcResponse::err(err),
                    },
                    None => IpcResponse::err(format!(
                        "unknown layout preset '{name}' (expected omarchy|island|swiss|ghost)"
                    )),
                }
            }
            "layout-next" => {
                let next = self.state.layout_preset.next();
                match self.apply_layout_preset(next, true) {
                    Ok(()) => IpcResponse::ok(next.as_str()),
                    Err(err) => IpcResponse::err(err),
                }
            }
            "layout-list" => {
                let lines: Vec<String> = LayoutPreset::ALL
                    .iter()
                    .map(|p| {
                        let mark = if *p == self.state.layout_preset {
                            "*"
                        } else {
                            " "
                        };
                        format!("{mark} {:<8} {}", p.as_str(), p.label())
                    })
                    .collect();
                IpcResponse::ok(lines.join("\n"))
            }
            "layout-status" => IpcResponse::ok(self.state.layout_preset.as_str()),
            "volume-up" => {
                let step = parse_step(&req.args, 5);
                self.execute_actions(vec![ShellAction::AudioStepVolume(step)]);
                IpcResponse::ok(format!("volume +{step}"))
            }
            "volume-down" => {
                let step = parse_step(&req.args, 5);
                self.execute_actions(vec![ShellAction::AudioStepVolume(-step)]);
                IpcResponse::ok(format!("volume -{step}"))
            }
            "volume-mute" => {
                self.execute_actions(vec![ShellAction::AudioToggleMute]);
                IpcResponse::ok("volume mute toggled")
            }
            "mic-mute" => {
                self.execute_actions(vec![ShellAction::AudioToggleMicMute]);
                IpcResponse::ok("mic mute toggled")
            }
            "brightness-up" => {
                let step = parse_step(&req.args, 5);
                self.execute_actions(vec![ShellAction::BacklightStep(step)]);
                IpcResponse::ok(format!("brightness +{step}"))
            }
            "brightness-down" => {
                let step = parse_step(&req.args, 5);
                self.execute_actions(vec![ShellAction::BacklightStep(-step)]);
                IpcResponse::ok(format!("brightness -{step}"))
            }
            "media" => {
                let action = req
                    .args
                    .first()
                    .map(String::as_str)
                    .unwrap_or("play-pause")
                    .to_string();
                self.execute_actions(vec![ShellAction::MediaCommand(action.clone())]);
                IpcResponse::ok(format!("media {action}"))
            }
            "dnd-status" => IpcResponse::ok(if self.state.dnd { "on" } else { "off" }),
            "dnd-on" => {
                self.dispatch_system_event(SystemEvent::DndChanged(true));
                IpcResponse::ok("on")
            }
            "dnd-off" => {
                self.dispatch_system_event(SystemEvent::DndChanged(false));
                IpcResponse::ok("off")
            }
            "dnd-toggle" => {
                let next = !self.state.dnd;
                self.dispatch_system_event(SystemEvent::DndChanged(next));
                IpcResponse::ok(if next { "on" } else { "off" })
            }
            "notify-clear" => {
                self.dispatch_system_event(SystemEvent::NotificationClearAll);
                IpcResponse::ok("cleared")
            }
            "nightlight-status" => IpcResponse::ok(if self.state.nightlight_enabled {
                format!("on {}K", self.state.nightlight_temp_k)
            } else {
                "off".into()
            }),
            "nightlight-toggle" => {
                let next = !self.state.nightlight_enabled;
                self.state.nightlight_manual_override = true;
                self.state.nightlight_auto = false;
                self.apply_nightlight(next, self.state.nightlight_temp_k);
                IpcResponse::ok(if next {
                    format!("on {}K", self.state.nightlight_temp_k)
                } else {
                    "off".into()
                })
            }
            "nightlight-set" => match req.args.first().map(String::as_str) {
                Some("auto") => {
                    self.state.nightlight_auto = true;
                    self.state.nightlight_manual_override = false;
                    self.sync_solar_schedule(true);
                    IpcResponse::ok(if self.state.nightlight_enabled {
                        format!("auto {}K", self.state.nightlight_temp_k)
                    } else {
                        "auto day".into()
                    })
                }
                Some("off" | "0" | "false") => {
                    self.state.nightlight_auto = false;
                    self.state.nightlight_manual_override = true;
                    self.apply_nightlight(false, self.state.nightlight_temp_k);
                    IpcResponse::ok("off")
                }
                Some("on" | "true") => {
                    self.state.nightlight_auto = false;
                    self.state.nightlight_manual_override = true;
                    self.apply_nightlight(true, self.state.nightlight_temp_k);
                    IpcResponse::ok(format!("on {}K", self.state.nightlight_temp_k))
                }
                Some(raw) => match raw.trim_end_matches(['K', 'k']).parse::<u32>() {
                    Ok(temp_k) => {
                        self.state.nightlight_auto = false;
                        self.state.nightlight_manual_override = true;
                        let enabled = temp_k < 6500;
                        self.apply_nightlight(enabled, temp_k);
                        IpcResponse::ok(if enabled {
                            format!("on {}K", self.state.nightlight_temp_k)
                        } else {
                            "off".into()
                        })
                    }
                    Err(_) => IpcResponse::err("usage: nightlight-set <on|off|auto|2500..6500>"),
                },
                None => IpcResponse::err("usage: nightlight-set <on|off|auto|2500..6500>"),
            },
            "brightness-set" => {
                let Some(target) = req.args.first().map(String::as_str) else {
                    responder.send(&IpcResponse::err(
                        "usage: brightness-set <mon|all> <1..=100>",
                    ));
                    return;
                };
                let Some(pct) = req.args.get(1).and_then(|v| v.parse::<u8>().ok()) else {
                    responder.send(&IpcResponse::err(
                        "usage: brightness-set <mon|all> <1..=100>",
                    ));
                    return;
                };
                self.state.nightlight_manual_override = true;
                self.apply_monitor_brightness(target, pct);
                IpcResponse::ok(format!("{target} {}%", pct.clamp(1, 100)))
            }
            "power-profile-status" => IpcResponse::ok_data(
                if self.state.power_profile.available {
                    self.state.power_profile.active.clone()
                } else {
                    "unavailable".into()
                },
                serde_json::to_value(&self.state.power_profile).unwrap_or(serde_json::Value::Null),
            ),
            "power-profile-set" => {
                let Some(prof) = req.args.first().cloned() else {
                    responder.send(&IpcResponse::err(
                        "usage: power-profile-set <power-saver|balanced|performance>",
                    ));
                    return;
                };
                if let Some(ref sys) = self.sys {
                    sys.send(SysCommand::SetPowerProfile(prof.clone()));
                }
                IpcResponse::ok(prof)
            }
            "power-profile-next" => {
                let profiles = if self.state.power_profile.available_profiles.is_empty() {
                    vec![
                        "power-saver".to_string(),
                        "balanced".to_string(),
                        "performance".to_string(),
                    ]
                } else {
                    self.state.power_profile.available_profiles.clone()
                };
                let cur_idx = profiles
                    .iter()
                    .position(|p| p == &self.state.power_profile.active)
                    .unwrap_or(0);
                let next = profiles[(cur_idx + 1) % profiles.len()].clone();
                if let Some(ref sys) = self.sys {
                    sys.send(SysCommand::SetPowerProfile(next.clone()));
                }
                IpcResponse::ok(next)
            }
            "privacy-status" => IpcResponse::ok_data(
                "ok",
                serde_json::to_value(&self.state.privacy).unwrap_or(serde_json::Value::Null),
            ),
            "audio-sinks" => IpcResponse::ok_data(
                "ok",
                serde_json::to_value(&self.state.audio.sinks).unwrap_or(serde_json::Value::Null),
            ),
            "audio-sources" => IpcResponse::ok_data(
                "ok",
                serde_json::to_value(&self.state.audio.sources).unwrap_or(serde_json::Value::Null),
            ),
            "audio-streams" => IpcResponse::ok_data(
                "ok",
                serde_json::to_value(&self.state.audio.streams).unwrap_or(serde_json::Value::Null),
            ),
            "audio-sink-set" => match req.args.first() {
                Some(name) => {
                    self.execute_actions(vec![ShellAction::AudioSetDefaultSink(name.clone())]);
                    IpcResponse::ok(name.clone())
                }
                None => IpcResponse::err("usage: audio-sink-set <name>"),
            },
            "audio-source-set" => match req.args.first() {
                Some(name) => {
                    self.execute_actions(vec![ShellAction::AudioSetDefaultSource(name.clone())]);
                    IpcResponse::ok(name.clone())
                }
                None => IpcResponse::err("usage: audio-source-set <name>"),
            },
            "audio-stream-volume" => {
                if let (Some(idx), Some(pct)) = (
                    req.args.first().and_then(|s| s.parse::<u32>().ok()),
                    req.args.get(1).and_then(|s| s.parse::<u8>().ok()),
                ) {
                    self.execute_actions(vec![ShellAction::AudioSetStreamVolume {
                        index: idx,
                        pct,
                    }]);
                    IpcResponse::ok(format!("stream {idx} {pct}%"))
                } else {
                    IpcResponse::err("usage: audio-stream-volume <index> <pct>")
                }
            }
            "audio-stream-mute" => {
                if let Some(idx) = req.args.first().and_then(|s| s.parse::<u32>().ok()) {
                    let muted = req
                        .args
                        .get(1)
                        .map(|s| matches!(s.as_str(), "on" | "true" | "1"))
                        .unwrap_or_else(|| {
                            !self
                                .state
                                .audio
                                .streams
                                .iter()
                                .find(|s| s.index == idx)
                                .is_some_and(|s| s.muted)
                        });
                    self.execute_actions(vec![ShellAction::AudioSetStreamMute {
                        index: idx,
                        muted,
                    }]);
                    IpcResponse::ok(format!("stream {idx} muted={muted}"))
                } else {
                    IpcResponse::err("usage: audio-stream-mute <index> [on|off]")
                }
            }
            "spectrum-subscribe" => {
                let count = req
                    .args
                    .first()
                    .and_then(|s| s.parse::<usize>().ok())
                    .unwrap_or(1);
                self.execute_actions(vec![ShellAction::AudioSetSpectrumSubscribed(count)]);
                IpcResponse::ok(format!("subscribers={count}"))
            }
            "caffeine-status" => IpcResponse::ok(if self.state.caffeine_enabled {
                "on"
            } else {
                "off"
            }),
            "caffeine-toggle" | "inhibit" => match req.args.first().map(String::as_str) {
                Some("on" | "true" | "1") => {
                    self.apply_caffeine(true);
                    IpcResponse::ok("on")
                }
                Some("off" | "false" | "0") => {
                    self.apply_caffeine(false);
                    IpcResponse::ok("off")
                }
                _ => {
                    let next = !self.state.caffeine_enabled;
                    self.apply_caffeine(next);
                    IpcResponse::ok(if next { "on" } else { "off" })
                }
            },
            "lock" => {
                self.spawn_lock_worker();
                IpcResponse::ok(format!("locked pid={}", self.active_lock_pid.unwrap_or(0)))
            }
            "unlock-status" => {
                if let Some(pid) = self.active_lock_pid {
                    IpcResponse::ok(format!(
                        "locked pid={pid} committed={}",
                        self.lock_committed
                    ))
                } else {
                    IpcResponse::ok("unlocked")
                }
            }
            "caffeine-set" => match req.args.first().map(String::as_str) {
                Some("on" | "true" | "1") => {
                    self.apply_caffeine(true);
                    IpcResponse::ok("on")
                }
                Some("off" | "false" | "0") => {
                    self.apply_caffeine(false);
                    IpcResponse::ok("off")
                }
                _ => IpcResponse::err("usage: caffeine-set <on|off>"),
            },
            "offline-mode-status" => {
                IpcResponse::ok(if self.state.offline_mode { "on" } else { "off" })
            }
            "offline-mode-toggle" => {
                let next = !self.state.offline_mode;
                self.dispatch_system_event(SystemEvent::OfflineModeChanged(next));
                IpcResponse::ok(if next { "on" } else { "off" })
            }
            "offline-mode-set" => match req.args.first().map(String::as_str) {
                Some("on" | "true" | "1") => {
                    self.dispatch_system_event(SystemEvent::OfflineModeChanged(true));
                    IpcResponse::ok("on")
                }
                Some("off" | "false" | "0") => {
                    self.dispatch_system_event(SystemEvent::OfflineModeChanged(false));
                    IpcResponse::ok("off")
                }
                _ => IpcResponse::err("usage: offline-mode-set <on|off>"),
            },
            "locale-status" => IpcResponse::ok(self.state.locale.as_str()),
            "locale-set" => {
                let Some(code) = req.args.first().map(String::as_str) else {
                    responder.send(&IpcResponse::err("usage: locale-set <en|vi>"));
                    return;
                };
                let next = Locale::from_code(code).unwrap_or(Locale::En);
                self.dispatch_system_event(SystemEvent::LocaleChanged(next));
                IpcResponse::ok(next.as_str())
            }
            "config-set" => {
                let (Some(key), Some(val)) = (req.args.first(), req.args.get(1)) else {
                    responder.send(&IpcResponse::err("usage: config-set <dotted_key> <value>"));
                    return;
                };
                let Some(ref sp) = self.settings_path else {
                    responder.send(&IpcResponse::err("settings.toml path unavailable"));
                    return;
                };
                match SettingsStore::set_override(sp, key, val) {
                    Ok(()) => match self.reload_config() {
                        Ok(()) => IpcResponse::ok(format!("set {key}")),
                        Err(err) => IpcResponse::err(err),
                    },
                    Err(err) => IpcResponse::err(err),
                }
            }
            "config-unset" => {
                let Some(key) = req.args.first() else {
                    responder.send(&IpcResponse::err("usage: config-unset <dotted_key>"));
                    return;
                };
                let Some(ref sp) = self.settings_path else {
                    responder.send(&IpcResponse::err("settings.toml path unavailable"));
                    return;
                };
                match SettingsStore::remove_override(sp, key) {
                    Ok(_) => match self.reload_config() {
                        Ok(()) => IpcResponse::ok(format!("unset {key}")),
                        Err(err) => IpcResponse::err(err),
                    },
                    Err(err) => IpcResponse::err(err),
                }
            }
            "settings-open" => {
                let target = req.args.join(" ");
                if target.trim().is_empty() {
                    IpcResponse::err("usage: settings-open <target>")
                } else {
                    self.execute_actions(vec![ShellAction::SettingsOpen(target.clone())]);
                    IpcResponse::ok(format!("settings-open {target}"))
                }
            }
            "status" | "inspect" => {
                let outputs: Vec<&String> = self.state.outputs.keys().collect();
                let hidden: Vec<&String> = self.state.hidden_bars.iter().collect();
                let mut data = serde_json::json!({
                    "pid": std::process::id(),
                    "version": env!("CARGO_PKG_VERSION"),
                    "layout_preset": self.state.layout_preset.as_str(),
                    "theme_mode": self.state.theme_mode.as_str(),
                    "palette": self.state.palette.name,
                    "offline_mode": self.state.offline_mode,
                    "user_account": self.state.user_account,
                    "hypr_connected": self.state.hypr_connected,
                    "active_workspace_id": self.state.active_workspace_id,
                    "display_status": self.state.display_status.kind_name(),
                    "island_expanded": self.state.island_expanded,
                    "live_activities": self.state.active_live_activity_ids(),
                    "dnd": self.state.dnd,
                    "cc_open": self.state.cc_open,
                    "nightlight_enabled": self.state.nightlight_enabled,
                    "nightlight_temp_k": self.state.nightlight_temp_k,
                    "caffeine_enabled": self.state.caffeine_enabled,
                    "wayland_idle_protocol": self.ui.has_idle_inhibit(),
                    "has_gamma_control": self.ui.has_gamma_control(),
                    "has_data_control": self.ui.has_data_control(),
                    "tray_bus_owned": self.state.tray_bus_owned,
                    "tray_items_count": self.state.tray_items.len(),
                    "wallpaper_path": self.state.wallpaper_path.as_ref().map(|p| p.display().to_string()),
                    "wallpaper_count": self.ui.wallpaper_count(),
                    "unread_notifications": self.state.unread_notifications,
                    "active_notifications": self.state.active_notifications,
                    "history_notifications": self.state.history_notifications,
                    "notifications_bus_owned": self.state.notifications_bus_owned,
                    "audio": self.state.audio,
                    "network": self.state.network,
                    "bluetooth": self.state.bluetooth,
                    "battery": self.state.battery,
                    "backlight": self.state.backlight,
                    "media": self.state.media,
                    "outputs": outputs,
                    "hidden_bars": hidden,
                    "hide_all_bars": self.state.hide_all_bars,
                    "surface_count": self.ui.surface_count(),
                    "animating_surfaces": self.ui.animating_surface_count(),
                    "namespaces": self.ui.active_namespaces(),
                });
                if let Some(obj) = data.as_object_mut() {
                    obj.insert(
                        "locale".into(),
                        serde_json::json!(self.state.locale.as_str()),
                    );
                    obj.insert(
                        "effective_font_scale".into(),
                        serde_json::json!(self.state.effective_font_scale),
                    );
                    obj.insert(
                        "high_contrast".into(),
                        serde_json::json!(self.state.config.accessibility.high_contrast),
                    );
                    obj.insert(
                        "power_profile".into(),
                        serde_json::json!(self.state.power_profile),
                    );
                    obj.insert("privacy".into(), serde_json::json!(self.state.privacy));
                    obj.insert(
                        "lock_active".into(),
                        serde_json::json!(self.active_lock_pid.is_some()),
                    );
                    obj.insert("lock_pid".into(), serde_json::json!(self.active_lock_pid));
                    obj.insert(
                        "has_idle_notify".into(),
                        serde_json::json!(self.ui.has_idle_notify()),
                    );
                    obj.insert(
                        "has_output_power".into(),
                        serde_json::json!(self.ui.has_output_power()),
                    );
                    obj.insert(
                        "power_capabilities".into(),
                        serde_json::json!(self.state.power_capabilities),
                    );
                    obj.insert(
                        "polkit_bus_owned".into(),
                        serde_json::json!(self.state.polkit_bus_owned),
                    );
                    obj.insert(
                        "has_screencopy".into(),
                        serde_json::json!(self.ui.has_screencopy()),
                    );
                    obj.insert(
                        "has_toplevel_capture".into(),
                        serde_json::json!(self.ui.has_toplevel_capture()),
                    );
                    obj.insert(
                        "spectrum_subscribers".into(),
                        serde_json::json!(self.state.spectrum_subscribers.len()),
                    );
                    obj.insert(
                        "sysmon_subscribers".into(),
                        serde_json::json!(self.state.sysmon_subscribers.len()),
                    );
                    obj.insert(
                        "last_settings_target".into(),
                        serde_json::json!(self.state.last_settings_target),
                    );
                    obj.insert("keyboard".into(), serde_json::json!(&self.state.keyboard));
                    obj.insert(
                        "windows_count".into(),
                        serde_json::json!(self.state.windows.len()),
                    );
                    obj.insert(
                        "bt_discovering".into(),
                        serde_json::json!(self.state.bluetooth.discovering),
                    );
                    obj.insert(
                        "weather_stale".into(),
                        serde_json::json!(self.state.weather.stale),
                    );
                    obj.insert(
                        "calendar_sources".into(),
                        serde_json::json!(self.state.calendar.sources.len()),
                    );
                    obj.insert(
                        "canvas_widget_count".into(),
                        serde_json::json!(self.state.config.canvas.widgets.len()),
                    );
                }
                IpcResponse::ok_data("ok", data)
            }
            _ => {
                let prev_cc_open = self.state.cc_open;
                let mut handled_resp: Option<IpcResponse> = None;
                let mut dirty = DirtyFlags::NONE;
                let mut actions = Vec::new();
                {
                    let mut ctx = ShellContext::new(&mut self.state);
                    for ext in &mut self.extensions {
                        match ext.on_ipc(&req.cmd, &req.args, &mut ctx) {
                            IpcResult::Handled {
                                ok,
                                message,
                                dirty: ext_dirty,
                            } => {
                                dirty |= ext_dirty | ctx.dirty;
                                handled_resp = Some(if ok {
                                    IpcResponse::ok(message)
                                } else {
                                    IpcResponse::err(message)
                                });
                                break;
                            }
                            IpcResult::Unhandled => {}
                        }
                    }
                    actions.extend(ctx.actions);
                }
                self.execute_actions(actions);
                if !dirty.is_empty() {
                    self.sync_ui_surfaces(dirty);
                }
                if self.state.cc_open != prev_cc_open {
                    self.dispatch_system_event(SystemEvent::ControlCenterChanged(
                        self.state.cc_open,
                    ));
                }
                handled_resp
                    .unwrap_or_else(|| IpcResponse::err(format!("unknown command '{}'", req.cmd)))
            }
        };
        responder.send(&resp);
    }

    fn connect_hypr_socket2(&mut self) {
        if self.hypr_client.is_none() {
            self.hypr_client = HyprClient::from_env().ok();
        }
        let Some(ref client) = self.hypr_client else {
            self.schedule_hypr_reconnect();
            return;
        };

        if let Some(old_token) = self.hypr_token.take() {
            self.loop_handle.remove(old_token);
        }

        match client.connect_event_stream() {
            Ok(stream) => {
                let source = Generic::new(stream, Interest::READ, Mode::Level);
                match self
                    .loop_handle
                    .insert_source(source, |_readiness, stream, daemon| {
                        // SAFETY: only reads from the existing socket FD without replacing or dropping it.
                        let stream_mut = unsafe { stream.get_mut() };
                        match stream_mut.read_events() {
                            Ok(Some(events)) => {
                                daemon.process_hypr_events(events);
                                Ok(PostAction::Continue)
                            }
                            Ok(None) => {
                                eprintln!("kaze-shell: Hyprland socket2 EOF; scheduling reconnect");
                                daemon.on_hypr_disconnected();
                                Ok(PostAction::Remove)
                            }
                            Err(err) => {
                                eprintln!(
                                    "kaze-shell: Hyprland socket2 error ({err}); scheduling reconnect"
                                );
                                daemon.on_hypr_disconnected();
                                Ok(PostAction::Remove)
                            }
                        }
                    }) {
                    Ok(token) => {
                        self.hypr_token = Some(token);
                        self.hypr_backoff.reset();
                        self.dispatch_system_event(SystemEvent::HyprConnectionChanged {
                            connected: true,
                        });
                        self.sync_hypr_snapshot();
                    }
                    Err(err) => {
                        eprintln!("kaze-shell: failed inserting Hyprland source: {err}");
                        self.schedule_hypr_reconnect();
                    }
                }
            }
            Err(_) => {
                self.schedule_hypr_reconnect();
            }
        }
    }

    fn on_hypr_disconnected(&mut self) {
        self.hypr_token = None;
        self.dispatch_system_event(SystemEvent::HyprConnectionChanged { connected: false });
        self.schedule_hypr_reconnect();
    }

    fn schedule_hypr_reconnect(&mut self) {
        if self.hypr_reconnect_armed {
            return;
        }
        self.hypr_reconnect_armed = true;
        let delay = self.hypr_backoff.next_delay();
        let timer = Timer::from_duration(delay);
        if self
            .loop_handle
            .insert_source(timer, |_, _, daemon| {
                daemon.hypr_reconnect_armed = false;
                daemon.connect_hypr_socket2();
                TimeoutAction::Drop
            })
            .is_err()
        {
            self.hypr_reconnect_armed = false;
        }
    }

    fn sync_hypr_snapshot(&mut self) {
        let (snap_res, kbd_raw) = {
            let Some(ref client) = self.hypr_client else {
                return;
            };
            (client.snapshot(), client.active_keyboard_layout())
        };
        match snap_res {
            Ok(snap) => {
                self.dispatch_system_event(SystemEvent::HyprSynced {
                    monitors: snap.monitors,
                    workspaces: snap.workspaces,
                    active_workspace_id: snap.active_workspace_id,
                    focused_monitor: snap.focused_monitor,
                });
            }
            Err(err) => {
                eprintln!("kaze-shell: Hyprland snapshot failed: {err}");
            }
        }
        self.sync_hypr_windows();
        if let Some(raw) = kbd_raw {
            if self.state.keyboard.layout_raw != raw {
                self.dispatch_system_event(SystemEvent::KeyboardLayoutChanged {
                    raw_name: raw,
                    source: "hypr".to_string(),
                });
            }
        }
    }

    fn sync_hypr_windows(&mut self) {
        let Some(ref client) = self.hypr_client else {
            return;
        };
        let Ok(windows) = client.clients() else {
            return;
        };
        let active_address = client.active_window_address();
        let fullscreen_outputs: Vec<String> = windows
            .iter()
            .filter(|w| w.fullscreen && !w.monitor.is_empty())
            .map(|w| w.monitor.clone())
            .collect();
        self.dispatch_system_event(SystemEvent::WindowsUpdated {
            windows,
            active_address,
            fullscreen_outputs,
        });
    }

    fn process_hypr_events(&mut self, events: Vec<HyprEvent>) {
        let mut need_resync = false;
        let mut need_windows_sync = false;
        let mut config_reloaded = false;
        for ev in events {
            if ev.requires_full_resync() {
                need_resync = true;
            }
            match ev {
                HyprEvent::WorkspaceV2 { id, name } => {
                    self.dispatch_system_event(SystemEvent::HyprWorkspaceChanged { id, name });
                }
                HyprEvent::Workspace { name } => {
                    if let Ok(id) = name.parse::<i32>() {
                        self.dispatch_system_event(SystemEvent::HyprWorkspaceChanged { id, name });
                    } else {
                        need_resync = true;
                    }
                }
                HyprEvent::FocusedMonV2 {
                    monitor,
                    workspace_id,
                } => {
                    self.dispatch_system_event(SystemEvent::HyprFocusedMonitor {
                        monitor,
                        workspace_id: Some(workspace_id),
                    });
                }
                HyprEvent::FocusedMon {
                    monitor,
                    workspace_name,
                } => {
                    self.dispatch_system_event(SystemEvent::HyprFocusedMonitor {
                        monitor,
                        workspace_id: workspace_name.parse::<i32>().ok(),
                    });
                }
                HyprEvent::WindowChanged
                | HyprEvent::ActiveWindow { .. }
                | HyprEvent::ActiveWindowV2 { .. }
                | HyprEvent::Fullscreen { .. } => {
                    need_windows_sync = true;
                }
                HyprEvent::ActiveLayout { layout, .. } => {
                    self.dispatch_system_event(SystemEvent::KeyboardLayoutChanged {
                        raw_name: layout,
                        source: "hypr".to_string(),
                    });
                }
                HyprEvent::ConfigReloaded => {
                    config_reloaded = true;
                }
                HyprEvent::Screencast { active, .. } => {
                    if let Some(ref sys) = self.sys {
                        sys.send(SysCommand::HyprScreencastUpdate(active));
                    }
                }
                _ => {}
            }
        }

        if need_resync {
            self.sync_hypr_snapshot();
        } else if need_windows_sync {
            self.sync_hypr_windows();
        }
        if config_reloaded {
            let colors = self.state.palette.for_mode(self.state.theme_mode);
            let (_, active, inactive, eval_lua) = kaze_core::theme::render_hyprland_lua(colors);
            self.push_live_hypr_colors(&active, &inactive, &eval_lua);
            if self.state.layout_preset != LayoutPreset::Omarchy
                || self.layout_state_file.as_ref().is_some_and(|p| p.exists())
            {
                self.push_live_hypr_layout(self.state.layout_preset);
            }
        }
    }

    fn sync_config_symlink_watch(&mut self) {
        let resolved = fs::canonicalize(&self.config_path).ok();
        let config_parent = self
            .config_path
            .parent()
            .and_then(|p| fs::canonicalize(p).ok().or_else(|| Some(p.to_path_buf())));
        let new_target = resolved.filter(|p| p != &self.config_path);
        let new_dir = new_target
            .as_ref()
            .and_then(|p| p.parent().map(Path::to_path_buf))
            .filter(|dir| config_parent.as_ref() != Some(dir));

        if let Ok(mut guard) = self.watched_config_target.lock() {
            *guard = new_target;
        }

        if self.watched_symlink_dir != new_dir {
            if let Some(ref mut watcher) = self.fs_watcher {
                if let Some(old_dir) = self.watched_symlink_dir.take() {
                    let _ = watcher.unwatch(&old_dir);
                }
                if let Some(ref dir) = new_dir {
                    if watcher.watch(dir, RecursiveMode::NonRecursive).is_ok() {
                        self.watched_symlink_dir = Some(dir.clone());
                    }
                }
            }
        }
    }

    fn schedule_config_reload(&mut self) {
        if self.config_reload_armed {
            return;
        }
        self.config_reload_armed = true;
        let timer = Timer::from_duration(Duration::from_millis(60));
        if self
            .loop_handle
            .insert_source(timer, |_, _, daemon| {
                daemon.config_reload_armed = false;
                let _ = daemon.reload_config();
                TimeoutAction::Drop
            })
            .is_err()
        {
            self.config_reload_armed = false;
        }
    }

    fn handle_backlight_fs_event(&mut self) {
        let Some(ref dir) = self.backlight_dir else {
            return;
        };
        if let Some(next) = backlight::read_backlight_from_dir(dir) {
            if next != self.state.backlight {
                self.dispatch_system_event(SystemEvent::BacklightChanged {
                    state: next,
                    trigger_osd: true,
                });
            }
        }
    }
}

fn parse_step(args: &[String], default: i32) -> i32 {
    args.first()
        .and_then(|s| s.parse::<i32>().ok())
        .map(|v| v.clamp(1, 50))
        .unwrap_or(default)
}

pub fn run(config_path: PathBuf) -> Result<(), String> {
    // Keep glibc M_MMAP_THRESHOLD fixed at 128 KiB so transient Pixmap/wallpaper buffers
    // munmap straight back to Linux on drop instead of inflating the brk heap arena.
    #[cfg(target_env = "gnu")]
    // SAFETY: standard glibc mallopt configuration before spawning worker threads.
    unsafe {
        libc::mallopt(libc::M_MMAP_THRESHOLD, 128 * 1024);
        libc::mallopt(libc::M_TRIM_THRESHOLD, 128 * 1024);
    }

    // Block SIGTERM/SIGINT/SIGCHLD on the main thread BEFORE spawning any worker threads
    // (`notify`, `kaze-sys`) so every child thread inherits the signal mask and shutdown
    // routes deterministically through `calloop::signals::Signals` with exit code 0.
    let signals = Signals::new(&[Signal::SIGTERM, Signal::SIGINT, Signal::SIGCHLD])
        .map_err(|e| format!("failed registering signal handler: {e}"))?;

    let settings_path = Config::settings_path().ok();
    let config = match Config::load_layered(&config_path, settings_path.as_deref()) {
        Ok(cfg) => cfg,
        Err(err) => {
            eprintln!("kaze-shell: initial config warning (using defaults): {err}");
            Config::default()
        }
    };

    let (wayland_conn, mut event_queue, mut ui) = UiState::connect(&config.bar.font)?;
    event_queue
        .roundtrip(&mut ui)
        .map_err(|e| format!("initial Wayland roundtrip failed: {e}"))?;
    event_queue
        .roundtrip(&mut ui)
        .map_err(|e| format!("second Wayland roundtrip failed: {e}"))?;
    ui.ensure_text_input();
    let _ = wayland_conn.flush();

    let initial_events = ui.drain_events();

    let sock_path = default_socket_path()?;
    let ipc_server = IpcServer::bind(sock_path)?;

    let mut event_loop: EventLoop<'static, Daemon> =
        EventLoop::try_new().map_err(|e| format!("failed creating calloop EventLoop: {e}"))?;
    let loop_handle = event_loop.handle();
    let loop_signal = event_loop.get_signal();

    // Shared single-thread `notify` watcher for `config.toml` (+ symlink target),
    // `settings.toml`, `/sys/class/backlight/*`, and `.desktop` application directories (1 thread total).
    let backlight_dir = backlight::discover_device();
    let app_dirs = launcher_desktop::existing_watch_dirs();
    let (fs_tx, fs_rx) = channel::channel::<WatchNotice>();
    let watched_config_target: Arc<Mutex<Option<PathBuf>>> = Arc::new(Mutex::new(None));
    let fs_watcher = start_shared_watcher(
        &config_path,
        settings_path.as_deref(),
        backlight_dir.as_deref(),
        &app_dirs,
        fs_tx,
        Arc::clone(&watched_config_target),
    );

    // Single background `tokio` current_thread runtime for D-Bus + native pipewire-pulse (1 thread).
    let (sys_tx, sys_rx) = channel::channel::<SystemEvent>();
    let event_tx = sys_tx.clone();
    let sys_handle = match SysHandle::spawn(sys_tx) {
        Ok(h) => Some(h),
        Err(err) => {
            eprintln!("kaze-shell: kaze-sys disabled: {err}");
            None
        }
    };

    let layout_state_file = layout_state_path().ok();
    let mut state = AppState::new(config);
    state.desktop_apps = scan_applications();
    ui.set_accessibility(
        state.effective_font_scale,
        state.config.accessibility.high_contrast,
    );
    ui.configure_clipboard(
        state.config.clipboard.ignore_mimes.clone(),
        state.config.clipboard.max_item_bytes,
        state.config.clipboard.persist,
    );
    let has_persisted_layout = if let Some(ref path) = layout_state_file {
        if let Some(saved) = load_persisted_preset(path) {
            state.layout_preset = saved;
            true
        } else {
            false
        }
    } else {
        false
    };
    if let Some(ref dir) = backlight_dir {
        if let Some(bl) = backlight::read_backlight_from_dir(dir) {
            state.backlight = bl;
        }
    }
    let theme_paths = ThemePaths::default_paths()?;
    let master_key = sys_handle.as_ref().and_then(|s| {
        kaze_core::crypto::default_master_key_path()
            .ok()
            .and_then(|kp| s.resolve_master_key(kp).ok())
    });
    let screentime = ScreenTimeTracker::new(
        state.config.screentime.enabled,
        state.config.screentime.retention_days,
        ScreenTimeTracker::default_store_path().ok(),
        master_key.clone(),
    );
    state.screentime = screentime.snapshot(epoch_secs_now());
    let clipboard_ext = {
        let store_path = default_clipboard_store_path().ok();
        ClipboardExtension::new(store_path, master_key)
    };
    let extensions: Vec<Box<dyn KazeExtension>> = vec![
        Box::new(BarExtension::new()),
        Box::new(DockExtension::new()),
        Box::new(SwitcherExtension::new()),
        Box::new(CornersExtension::new()),
        Box::new(IslandExtension::new()),
        Box::new(ControlCenterExtension::new()),
        Box::new(TrayExtension::new()),
        Box::new(WallpaperExtension::new()),
        Box::new(OsdExtension::new()),
        Box::new(NotifyExtension::new()),
        Box::new(clipboard_ext),
        Box::new(LauncherExtension::new()),
        Box::new(IdleExtension::new()),
        Box::new(SessionMenuExtension::new()),
        Box::new(PolkitExtension::new()),
        Box::new(CaptureExtension::new()),
        Box::new(CanvasExtension::new()),
    ];

    let mut daemon = Daemon {
        loop_handle: loop_handle.clone(),
        loop_signal: loop_signal.clone(),
        wayland_conn: wayland_conn.clone(),
        ui,
        state,
        config_path,
        settings_path,
        layout_state_file,
        backlight_dir,
        theme_paths,
        extensions,
        hypr_client: HyprClient::from_env().ok(),
        hypr_token: None,
        hypr_backoff: ReconnectBackoff::default(),
        hypr_reconnect_armed: false,
        config_reload_armed: false,
        timers: HashMap::new(),
        pending_dmenu: None,
        pending_wallpaper_set: None,
        pending_capture_reply: None,
        event_tx,
        sys: sys_handle,
        fs_watcher,
        watched_symlink_dir: None,
        watched_config_target,
        children: Vec::new(),
        active_lock_pid: None,
        lock_committed: false,
        pre_lock_dnd: None,
        lock_pipe_token: None,
        screentime,
        last_cal_reminder_uid: None,
    };
    daemon.sync_config_symlink_watch();

    // 1. Signals: clean shutdown on SIGTERM/SIGINT + child reaping on SIGCHLD (0 zombies).
    loop_handle
        .insert_source(signals, |event, _, daemon| match event.signal() {
            Signal::SIGTERM | Signal::SIGINT => {
                daemon.loop_signal.stop();
            }
            Signal::SIGCHLD => {
                daemon.reap_children();
            }
            _ => {}
        })
        .map_err(|e| format!("failed inserting signal source: {e}"))?;

    // 2. Wayland display FD source.
    let wayland_source = WaylandSource::new(wayland_conn, event_queue);
    loop_handle
        .insert_source(wayland_source, |_, queue, daemon| {
            let dispatched = queue.dispatch_pending(&mut daemon.ui)?;
            daemon.pump_clipboard_pipes();
            let events = daemon.ui.drain_events();
            for ev in events {
                daemon.dispatch_system_event(ev);
            }
            let _ = daemon.wayland_conn.flush();
            Ok(dispatched)
        })
        .map_err(|e| format!("failed inserting Wayland source: {e}"))?;

    // 3. Unix socket IPC source (`$XDG_RUNTIME_DIR/kaze/shell.sock`).
    let ipc_source = Generic::new(ipc_server, Interest::READ, Mode::Level);
    loop_handle
        .insert_source(ipc_source, |_, server, daemon| {
            server.accept_with_responder(|req, responder| daemon.handle_ipc(req, responder));
            Ok(PostAction::Continue)
        })
        .map_err(|e| format!("failed inserting IPC source: {e}"))?;

    // 4. Shared filesystem watcher channel (`notify` -> `calloop`: config.toml, backlight, .desktop dirs).
    loop_handle
        .insert_source(fs_rx, |ev, _, daemon| {
            if let channel::Event::Msg(notice) = ev {
                match notice {
                    WatchNotice::Config => {
                        daemon.sync_config_symlink_watch();
                        daemon.schedule_config_reload();
                    }
                    WatchNotice::Backlight => daemon.handle_backlight_fs_event(),
                    WatchNotice::Applications => {
                        daemon.dispatch_system_event(SystemEvent::ApplicationsChanged);
                    }
                }
            }
        })
        .map_err(|e| format!("failed inserting fs watcher channel: {e}"))?;

    // 5. System services channel (`kaze-sys` 1-thread tokio -> `calloop`).
    loop_handle
        .insert_source(sys_rx, |ev, _, daemon| {
            if let channel::Event::Msg(sys_ev) = ev {
                daemon.dispatch_system_event(sys_ev);
            }
        })
        .map_err(|e| format!("failed inserting kaze-sys channel: {e}"))?;

    // 6. Minute-boundary Clock timer (0 per-second polling).
    let (clock, first_wait) = ClockTime::now_and_duration_to_next_minute();
    daemon.state.clock = clock;
    let clock_timer = Timer::from_duration(first_wait);
    loop_handle
        .insert_source(clock_timer, |_, _, daemon| {
            let (now_clock, next_wait) = ClockTime::now_and_duration_to_next_minute();
            daemon.dispatch_system_event(SystemEvent::ClockTick(now_clock));
            TimeoutAction::ToDuration(next_wait)
        })
        .map_err(|e| format!("failed inserting clock timer: {e}"))?;

    if let Err(err) = daemon.apply_templates() {
        eprintln!("kaze-shell: initial template apply warning: {err}");
    }
    if has_persisted_layout || daemon.state.layout_preset != LayoutPreset::Omarchy {
        daemon.push_live_hypr_layout(daemon.state.layout_preset);
    }
    for ev in initial_events {
        daemon.dispatch_system_event(ev);
    }
    daemon.init_extensions();
    daemon.sync_solar_schedule(false);
    daemon.sync_wave2_services();
    daemon.connect_hypr_socket2();
    daemon.fire_hook("started", None, None, None);

    event_loop
        .run(None, &mut daemon, |_| {})
        .map_err(|e| format!("event loop exited with error: {e}"))?;

    daemon.fire_hook("stopping", None, None, None);
    Ok(())
}

fn start_shared_watcher(
    config_path: &Path,
    settings_path: Option<&Path>,
    backlight_dir: Option<&Path>,
    app_dirs: &[PathBuf],
    tx: channel::Sender<WatchNotice>,
    watched_config_target: Arc<Mutex<Option<PathBuf>>>,
) -> Option<RecommendedWatcher> {
    let config_parent = config_path.parent().map(Path::to_path_buf);
    if let Some(ref parent) = config_parent {
        let _ = fs::create_dir_all(parent);
    }
    let settings_parent = settings_path
        .and_then(|p| p.parent())
        .map(Path::to_path_buf);
    if let Some(ref parent) = settings_parent {
        let _ = fs::create_dir_all(parent);
    }

    let config_name = config_path.file_name().map(|n| n.to_os_string());
    let config_parent_for_cb = config_parent.clone();
    let settings_name = settings_path
        .and_then(|p| p.file_name())
        .map(|n| n.to_os_string());
    let settings_parent_for_cb = settings_parent.clone();
    let bl_dir_owned = backlight_dir.map(Path::to_path_buf);
    let app_dirs_owned: Vec<PathBuf> = app_dirs.to_vec();

    let mut watcher =
        match notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
            let Ok(ev) = res else {
                return;
            };
            let relevant_kind = matches!(
                ev.kind,
                EventKind::Modify(_) | EventKind::Create(_) | EventKind::Remove(_) | EventKind::Any
            );
            if !relevant_kind {
                return;
            }
            let symlink_target = watched_config_target.lock().ok().and_then(|g| g.clone());
            for path in &ev.paths {
                let matches_config = config_name.as_ref().is_some_and(|expected| {
                    path.file_name().is_some_and(|n| n == expected.as_os_str())
                        && config_parent_for_cb
                            .as_ref()
                            .is_none_or(|p| path.parent() == Some(p.as_path()))
                }) || settings_name.as_ref().is_some_and(|expected| {
                    path.file_name().is_some_and(|n| n == expected.as_os_str())
                        && settings_parent_for_cb
                            .as_ref()
                            .is_none_or(|p| path.parent() == Some(p.as_path()))
                }) || symlink_target.as_ref().is_some_and(|target| {
                    path == target
                        || path.file_name() == target.file_name()
                            && path.parent() == target.parent()
                });
                if matches_config {
                    let _ = tx.send(WatchNotice::Config);
                    continue;
                }
                if let Some(ref bl) = bl_dir_owned {
                    if path.starts_with(bl)
                        && path
                            .file_name()
                            .is_some_and(|n| n == "brightness" || n == "actual_brightness")
                    {
                        let _ = tx.send(WatchNotice::Backlight);
                        continue;
                    }
                }
                if app_dirs_owned.iter().any(|dir| path.starts_with(dir)) {
                    let _ = tx.send(WatchNotice::Applications);
                }
            }
        }) {
            Ok(w) => w,
            Err(err) => {
                eprintln!("kaze-shell: failed initializing shared notify watcher: {err}");
                return None;
            }
        };

    if let Some(ref parent) = config_parent {
        if let Err(err) = watcher.watch(parent, RecursiveMode::NonRecursive) {
            eprintln!("kaze-shell: failed watching {}: {err}", parent.display());
        }
    }
    if let Some(ref sp) = settings_parent {
        if config_parent.as_ref() != Some(sp) {
            if let Err(err) = watcher.watch(sp, RecursiveMode::NonRecursive) {
                eprintln!("kaze-shell: failed watching {}: {err}", sp.display());
            }
        }
    }
    if let Some(bl_dir) = backlight_dir {
        let _ = watcher.watch(bl_dir, RecursiveMode::NonRecursive);
    }
    for dir in app_dirs {
        let _ = watcher.watch(dir, RecursiveMode::NonRecursive);
    }
    Some(watcher)
}
