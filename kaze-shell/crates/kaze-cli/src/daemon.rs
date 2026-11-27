use calloop::channel;
use calloop::generic::Generic;
use calloop::signals::{Signal, Signals};
use calloop::timer::{TimeoutAction, Timer};
use calloop::{EventLoop, Interest, LoopHandle, LoopSignal, Mode, PostAction, RegistrationToken};
use calloop_wayland_source::WaylandSource;
use kaze_core::theme::generate_all_templates;
use kaze_core::{
    AppState, ClockTime, Config, DirtyFlags, IpcResult, KazeExtension, ResolvedPalette,
    ShellAction, ShellContext, SystemEvent, ThemePaths,
};
use kaze_ext_bar::BarExtension;
use kaze_hypr::{HyprClient, HyprEvent, ReconnectBackoff};
use kaze_ipc::{default_socket_path, IpcRequest, IpcResponse, IpcServer};
use kaze_ui::UiState;
use notify::{EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use smithay_client_toolkit::reexports::client::Connection;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::Duration;

struct Daemon {
    loop_handle: LoopHandle<'static, Self>,
    loop_signal: LoopSignal,
    wayland_conn: Connection,
    ui: UiState,
    state: AppState,
    config_path: PathBuf,
    theme_paths: ThemePaths,
    extensions: Vec<Box<dyn KazeExtension>>,
    hypr_client: Option<HyprClient>,
    hypr_token: Option<RegistrationToken>,
    hypr_backoff: ReconnectBackoff,
    hypr_reconnect_armed: bool,
    config_reload_armed: bool,
    _config_watcher: Option<RecommendedWatcher>,
    children: Vec<Child>,
}

impl Daemon {
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
                self.state.theme_mode = *mode;
            }
            SystemEvent::ConfigReloaded | SystemEvent::PointerClick { .. } => {}
        }

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
    }

    fn sync_ui_surfaces(&mut self, dirty: DirtyFlags) {
        let mut specs = Vec::new();
        for ext in &self.extensions {
            specs.extend(ext.surfaces());
        }
        self.ui.sync_surfaces(specs, dirty);
        let _ = self.wayland_conn.flush();
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
                    self.spawn_detached(&program, &args);
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
            }
        }
    }

    fn spawn_detached(&mut self, program: &str, args: &[String]) {
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

    fn reap_children(&mut self) {
        self.children
            .retain_mut(|child| matches!(child.try_wait(), Ok(None)));
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

    fn reload_config(&mut self) -> Result<(), String> {
        match Config::load_from_path(&self.config_path) {
            Ok(new_cfg) => {
                let mode = new_cfg.theme.mode;
                let palette = ResolvedPalette::load(
                    &new_cfg.theme.palette,
                    new_cfg.theme.palettes_dir.as_deref(),
                );
                self.ui.set_font(&new_cfg.bar.font);
                self.state.config = new_cfg;
                self.state.theme_mode = mode;
                self.state.palette = palette;
                if let Err(err) = self.apply_templates() {
                    eprintln!("kaze-shell: template regeneration after reload failed: {err}");
                }
                self.dispatch_system_event(SystemEvent::ConfigReloaded);
                Ok(())
            }
            Err(err) => {
                eprintln!("kaze-shell: config reload warning (keeping active config): {err}");
                Err(err)
            }
        }
    }

    fn handle_ipc(&mut self, req: IpcRequest) -> IpcResponse {
        match req.cmd.as_str() {
            "ping" => IpcResponse::ok("pong"),
            "theme-mode-toggle" => {
                let next = self.state.theme_mode.toggled();
                self.state.theme_mode = next;
                if let Err(err) = self.apply_templates() {
                    return IpcResponse::err(err);
                }
                self.dispatch_system_event(SystemEvent::ThemeChanged(next));
                IpcResponse::ok(next.as_str())
            }
            "templates-apply" => match self.apply_templates() {
                Ok(msg) => IpcResponse::ok(msg),
                Err(err) => IpcResponse::err(err),
            },
            "reload" => match self.reload_config() {
                Ok(()) => IpcResponse::ok("reloaded"),
                Err(err) => IpcResponse::err(err),
            },
            "status" => {
                let outputs: Vec<&String> = self.state.outputs.keys().collect();
                let hidden: Vec<&String> = self.state.hidden_bars.iter().collect();
                let data = serde_json::json!({
                    "pid": std::process::id(),
                    "theme_mode": self.state.theme_mode.as_str(),
                    "palette": self.state.palette.name,
                    "hypr_connected": self.state.hypr_connected,
                    "active_workspace_id": self.state.active_workspace_id,
                    "display_status": self.state.display_status.kind_name(),
                    "outputs": outputs,
                    "hidden_bars": hidden,
                    "hide_all_bars": self.state.hide_all_bars,
                    "surface_count": self.ui.surface_count(),
                    "namespaces": self.ui.active_namespaces(),
                });
                IpcResponse::ok_data("ok", data)
            }
            _ => {
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
                handled_resp
                    .unwrap_or_else(|| IpcResponse::err(format!("unknown command '{}'", req.cmd)))
            }
        }
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
        let Some(ref client) = self.hypr_client else {
            return;
        };
        match client.snapshot() {
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
    }

    fn process_hypr_events(&mut self, events: Vec<HyprEvent>) {
        let mut need_resync = false;
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
                HyprEvent::ConfigReloaded => {
                    config_reloaded = true;
                }
                _ => {}
            }
        }

        if need_resync {
            self.sync_hypr_snapshot();
        }
        if config_reloaded {
            let colors = self.state.palette.for_mode(self.state.theme_mode);
            let (_, active, inactive, eval_lua) = kaze_core::theme::render_hyprland_lua(colors);
            self.push_live_hypr_colors(&active, &inactive, &eval_lua);
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
}

pub fn run(config_path: PathBuf) -> Result<(), String> {
    let theme_paths = ThemePaths::default_paths()?;
    let config = match Config::load_from_path(&config_path) {
        Ok(cfg) => cfg,
        Err(err) => {
            eprintln!("kaze-shell: initial config warning (using defaults): {err}");
            Config::default()
        }
    };

    let (wayland_conn, mut event_queue, mut ui) = UiState::connect(&config.bar.font)?;
    // Perform initial Wayland roundtrips so wl_output names & logical modes populate before first draw.
    event_queue
        .roundtrip(&mut ui)
        .map_err(|e| format!("initial Wayland roundtrip failed: {e}"))?;
    event_queue
        .roundtrip(&mut ui)
        .map_err(|e| format!("second Wayland roundtrip failed: {e}"))?;

    let initial_events = ui.drain_events();

    let sock_path = default_socket_path()?;
    let ipc_server = IpcServer::bind(sock_path)?;

    let mut event_loop: EventLoop<'static, Daemon> =
        EventLoop::try_new().map_err(|e| format!("failed creating calloop EventLoop: {e}"))?;
    let loop_handle = event_loop.handle();
    let loop_signal = event_loop.get_signal();

    // Config file watcher via `notify`, routed into calloop over a channel (0 polling).
    let (cfg_tx, cfg_rx) = channel::channel::<()>();
    let config_watcher = start_config_watcher(&config_path, cfg_tx);

    let state = AppState::new(config);
    let extensions: Vec<Box<dyn KazeExtension>> = vec![Box::new(BarExtension::new())];

    let mut daemon = Daemon {
        loop_handle: loop_handle.clone(),
        loop_signal: loop_signal.clone(),
        wayland_conn: wayland_conn.clone(),
        ui,
        state,
        config_path,
        theme_paths,
        extensions,
        hypr_client: HyprClient::from_env().ok(),
        hypr_token: None,
        hypr_backoff: ReconnectBackoff::default(),
        hypr_reconnect_armed: false,
        config_reload_armed: false,
        _config_watcher: config_watcher,
        children: Vec::new(),
    };

    // 1. Signals: clean shutdown on SIGTERM/SIGINT + child reaping on SIGCHLD (0 zombies).
    let signals = Signals::new(&[Signal::SIGTERM, Signal::SIGINT, Signal::SIGCHLD])
        .map_err(|e| format!("failed registering signal handler: {e}"))?;
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
            let events = daemon.ui.drain_events();
            for ev in events {
                daemon.dispatch_system_event(ev);
            }
            Ok(dispatched)
        })
        .map_err(|e| format!("failed inserting Wayland source: {e}"))?;

    // 3. Unix socket IPC source (`$XDG_RUNTIME_DIR/kaze/shell.sock`).
    let ipc_source = Generic::new(ipc_server, Interest::READ, Mode::Level);
    loop_handle
        .insert_source(ipc_source, |_, server, daemon| {
            server.accept_and_dispatch(|req| daemon.handle_ipc(req));
            Ok(PostAction::Continue)
        })
        .map_err(|e| format!("failed inserting IPC source: {e}"))?;

    // 4. Config hot-reload channel (`notify` -> `calloop`).
    loop_handle
        .insert_source(cfg_rx, |ev, _, daemon| {
            if matches!(ev, channel::Event::Msg(())) {
                daemon.schedule_config_reload();
            }
        })
        .map_err(|e| format!("failed inserting config watcher channel: {e}"))?;

    // 5. Minute-boundary Clock timer (0 per-second polling).
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

    // Generate initial theme files & bootstrap outputs + Hyprland + extensions.
    if let Err(err) = daemon.apply_templates() {
        eprintln!("kaze-shell: initial template apply warning: {err}");
    }
    for ev in initial_events {
        daemon.dispatch_system_event(ev);
    }
    daemon.init_extensions();
    daemon.connect_hypr_socket2();

    event_loop
        .run(None, &mut daemon, |_| {})
        .map_err(|e| format!("event loop exited with error: {e}"))?;

    Ok(())
}

fn start_config_watcher(config_path: &Path, tx: channel::Sender<()>) -> Option<RecommendedWatcher> {
    let parent = config_path.parent()?;
    if let Err(err) = fs::create_dir_all(parent) {
        eprintln!(
            "kaze-shell: unable to create config dir {} for watching: {err}",
            parent.display()
        );
        return None;
    }

    let target_name = config_path.file_name().map(|n| n.to_os_string());
    let mut watcher =
        match notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
            let Ok(ev) = res else {
                return;
            };
            let relevant_kind = matches!(
                ev.kind,
                EventKind::Modify(_) | EventKind::Create(_) | EventKind::Any
            );
            if !relevant_kind {
                return;
            }
            let matches_file = match &target_name {
                Some(expected) => ev
                    .paths
                    .iter()
                    .any(|p| p.file_name().is_some_and(|n| n == expected.as_os_str())),
                None => true,
            };
            if matches_file {
                let _ = tx.send(());
            }
        }) {
            Ok(w) => w,
            Err(err) => {
                eprintln!("kaze-shell: failed initializing notify watcher: {err}");
                return None;
            }
        };

    if let Err(err) = watcher.watch(parent, RecursiveMode::NonRecursive) {
        eprintln!("kaze-shell: failed watching {}: {err}", parent.display());
        return None;
    }
    Some(watcher)
}
