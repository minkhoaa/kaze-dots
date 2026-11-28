#![deny(clippy::unwrap_used)]

mod widgets;

use kaze_core::{
    Anchor, AppState, BarLayerMode, BarMonitorOverride, BarPosition, Color, DirtyFlags,
    DisplayStatus, EdgeInsets, HitTarget, IpcResult, KazeExtension, KeyboardMode, Layer,
    LayoutPreset, NetworkKind, OutputInfo, PaintCmd, PointerButton, Rect, ShellAction,
    ShellContext, Spring, SurfaceSpec, SystemEvent, TextAlign,
};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use widgets::{build_widget_visuals, render_visualizer, resolve_widget, WidgetVisual};

const GHOST_PEEK_TIMER_ID: &str = "bar:ghost-peek-hide";
const GHOST_PEEK_MS: u64 = 2500;
const EXEC_TIMER_PREFIX: &str = "bar:exec:";

#[derive(Debug, Clone)]
struct WinMenuState {
    output_name: String,
    bar_position: BarPosition,
    window_addr: String,
    floating: bool,
    fullscreen: bool,
}

#[derive(Debug, Clone)]
struct EffectiveBar {
    #[allow(dead_code)]
    id: String,
    surface_id: String,
    namespace: String,
    output_name: String,
    enabled: bool,
    position: BarPosition,
    layer: BarLayerMode,
    section_mode: String,
    island_mode: bool,
    thickness: u32,
    length: u32,
    margin_edge: i32,
    margin_ends: i32,
    corner_radius: f32,
    border_width: f32,
    background_opacity: f32,
    exclusive: bool,
    start_slots: Vec<String>,
    center_slots: Vec<String>,
    end_slots: Vec<String>,
}

/// Production bar extension built strictly against the `KazeExtension` contract:
/// supports multi-bar 4-edge placement, per-monitor overrides, `layer = "auto"`,
/// click-through `input_regions`, `peek` hover springs, tabular digits, middle-click
/// Settings jump, and 30+ built-in widgets across all 4 layout presets.
pub struct BarExtension {
    cached_specs: Vec<SurfaceSpec>,
    ws_springs: HashMap<String, Spring>,
    peek_springs: HashMap<String, Spring>,
    hovered_targets: HashMap<String, String>,
    peeked_outputs: BTreeSet<String>,
    ghost_peeking: bool,
    ghost_spring: Spring,
    win_menu: Option<WinMenuState>,
    subscribed_spectrum: bool,
    subscribed_sysmon: bool,
    scheduled_exec_timers: BTreeMap<String, u64>,
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
            peek_springs: HashMap::new(),
            hovered_targets: HashMap::new(),
            peeked_outputs: BTreeSet::new(),
            ghost_peeking: false,
            ghost_spring: Spring::snappy(-42.0),
            win_menu: None,
            subscribed_spectrum: false,
            subscribed_sysmon: false,
            scheduled_exec_timers: BTreeMap::new(),
        }
    }

    fn ghost_should_show(&self, state: &AppState) -> bool {
        self.ghost_peeking || state.display_status.is_active() || state.active_notifications > 0
    }

    fn effective_bars(&self, state: &AppState) -> Vec<EffectiveBar> {
        if !state.config.bar.enabled || state.hide_all_bars {
            return Vec::new();
        }
        let mut out = Vec::new();
        for output in state.outputs.values() {
            if state.is_output_excluded(&output.name) || state.is_bar_hidden(&output.name) {
                continue;
            }
            let mon_override = find_monitor_override(state, &output.name);
            if state.config.bar.bars.is_empty() {
                let mut eff = EffectiveBar {
                    id: "main".to_string(),
                    surface_id: format!("bar:{}", output.name),
                    namespace: if state.config.bar.island_mode
                        && state.layout_preset != LayoutPreset::Ghost
                    {
                        "kaze-island".to_string()
                    } else {
                        format!("kaze-bar-{}", output.name)
                    },
                    output_name: output.name.clone(),
                    enabled: true,
                    position: state.config.bar.position,
                    layer: state.config.bar.layer,
                    section_mode: state.config.bar.section_mode.clone(),
                    island_mode: state.config.bar.island_mode,
                    thickness: state.config.bar.thickness,
                    length: state.config.bar.length,
                    margin_edge: state.config.bar.margin_edge,
                    margin_ends: state.config.bar.margin_ends,
                    corner_radius: state.config.bar.corner_radius,
                    border_width: state.config.bar.border_width,
                    background_opacity: state.config.bar.background_opacity,
                    exclusive: state.config.bar.exclusive,
                    start_slots: state.config.bar.start_slots.clone(),
                    center_slots: state.config.bar.center_slots.clone(),
                    end_slots: state.config.bar.end_slots.clone(),
                };
                if let Some(ov) = mon_override {
                    apply_monitor_override(&mut eff, ov);
                }
                if eff.enabled {
                    out.push(eff);
                }
            } else {
                for inst in &state.config.bar.bars {
                    if !state.matches_monitor(&output.name, &inst.monitor) {
                        continue;
                    }
                    let scoped_id = format!("{}:{}", inst.id, output.name);
                    if state.hidden_bars.contains(&scoped_id) {
                        continue;
                    }
                    let is_main = inst.id == "main";
                    let surface_id = if is_main {
                        format!("bar:{}", output.name)
                    } else {
                        format!("bar:{}:{}", inst.id, output.name)
                    };
                    let namespace =
                        if inst.island_mode && state.layout_preset != LayoutPreset::Ghost {
                            "kaze-island".to_string()
                        } else if is_main {
                            format!("kaze-bar-{}", output.name)
                        } else {
                            format!("kaze-bar-{}-{}", inst.id, output.name)
                        };
                    let mut eff = EffectiveBar {
                        id: inst.id.clone(),
                        surface_id,
                        namespace,
                        output_name: output.name.clone(),
                        enabled: inst.enabled,
                        position: inst.position,
                        layer: inst.layer,
                        section_mode: inst.section_mode.clone(),
                        island_mode: inst.island_mode,
                        thickness: inst.thickness,
                        length: inst.length,
                        margin_edge: inst.margin_edge,
                        margin_ends: inst.margin_ends,
                        corner_radius: inst.corner_radius,
                        border_width: inst.border_width,
                        background_opacity: inst.background_opacity,
                        exclusive: inst.exclusive,
                        start_slots: inst.start_slots.clone(),
                        center_slots: inst.center_slots.clone(),
                        end_slots: inst.end_slots.clone(),
                    };
                    if is_main {
                        if let Some(ov) = mon_override {
                            apply_monitor_override(&mut eff, ov);
                        }
                    }
                    if eff.enabled {
                        out.push(eff);
                    }
                }
            }
        }
        out
    }

    fn sync_demand(&mut self, ctx: &mut ShellContext) {
        let active_bars = if ctx.state.session_locked || ctx.state.outputs_dpms_off {
            Vec::new()
        } else {
            self.effective_bars(ctx.state)
        };
        let ghost_visible =
            ctx.state.layout_preset != LayoutPreset::Ghost || self.ghost_should_show(ctx.state);
        let visible_slots: Vec<String> = if ghost_visible {
            active_bars
                .iter()
                .flat_map(|b| {
                    b.start_slots
                        .iter()
                        .chain(b.center_slots.iter())
                        .chain(b.end_slots.iter())
                        .cloned()
                })
                .collect()
        } else {
            Vec::new()
        };

        let need_spectrum = visible_slots
            .iter()
            .any(|s| resolve_widget(ctx.state, s).kind == "audio_visualizer");
        if need_spectrum != self.subscribed_spectrum {
            self.subscribed_spectrum = need_spectrum;
            ctx.push_action(ShellAction::SetSpectrumSubscriber {
                owner: "bar".to_string(),
                active: need_spectrum,
            });
        }

        let need_sysmon = visible_slots
            .iter()
            .any(|s| resolve_widget(ctx.state, s).kind == "sysmon");
        if need_sysmon != self.subscribed_sysmon {
            self.subscribed_sysmon = need_sysmon;
            ctx.push_action(ShellAction::SetSysmonSubscriber {
                owner: "bar".to_string(),
                active: need_sysmon,
            });
        }

        let mut desired_exec: BTreeMap<String, u64> = BTreeMap::new();
        for slot in &visible_slots {
            let rw = resolve_widget(ctx.state, slot);
            if !rw.cfg.exec.trim().is_empty() && rw.cfg.exec_interval_secs >= 5 {
                desired_exec.insert(rw.instance_id, rw.cfg.exec_interval_secs);
            }
        }
        let stale: Vec<String> = self
            .scheduled_exec_timers
            .keys()
            .filter(|id| !desired_exec.contains_key(*id))
            .cloned()
            .collect();
        for id in stale {
            self.scheduled_exec_timers.remove(&id);
            ctx.push_action(ShellAction::CancelTimer {
                id: format!("{EXEC_TIMER_PREFIX}{id}"),
            });
        }
        for (id, secs) in desired_exec {
            if self.scheduled_exec_timers.get(&id).copied() != Some(secs) {
                self.scheduled_exec_timers.insert(id.clone(), secs);
                ctx.push_action(ShellAction::ScheduleTimer {
                    id: format!("{EXEC_TIMER_PREFIX}{id}"),
                    after_ms: secs * 1000,
                });
            }
        }
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

        let hovered_keys: BTreeSet<String> = self
            .hovered_targets
            .iter()
            .map(|(surf, tgt)| format!("{surf}|{tgt}"))
            .collect();
        for (key, sp) in &mut self.peek_springs {
            let target = if hovered_keys.contains(key) { 1.0 } else { 0.0 };
            if snap {
                sp.snap(target);
            } else {
                sp.set_target(target);
            }
        }
        for key in hovered_keys {
            let sp = self
                .peek_springs
                .entry(key)
                .or_insert_with(|| Spring::snappy(0.0));
            if snap {
                sp.snap(1.0);
            } else {
                sp.set_target(1.0);
            }
        }
        self.peek_springs
            .retain(|_, sp| sp.value > 0.01 || !sp.is_settled());
    }

    fn rebuild(&mut self, state: &AppState) {
        self.cached_specs.clear();
        let bars = self.effective_bars(state);
        if bars.is_empty() {
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

        for bar in &bars {
            let Some(output) = state.outputs.get(&bar.output_name) else {
                continue;
            };
            let ws_spring = self.ws_springs.get(&output.name).copied();
            let menu_open_on_out = self
                .win_menu
                .as_ref()
                .is_some_and(|m| m.output_name == output.name);
            let layer = resolve_bar_layer(
                bar.layer,
                state.layout_preset == LayoutPreset::Ghost && self.ghost_peeking,
                menu_open_on_out || state.cc_open,
                state.fullscreen_outputs.contains(&output.name)
                    && self.peeked_outputs.contains(&output.name),
            );
            let mut spec = match state.layout_preset {
                LayoutPreset::Omarchy => {
                    build_bar_surface(state, output, bar, ws_spring, None, &self.peek_springs)
                }
                LayoutPreset::Island => build_island_bar_surface(state, output, bar),
                LayoutPreset::Swiss => build_swiss_bar_surface(state, output, bar),
                LayoutPreset::Ghost => build_bar_surface(
                    state,
                    output,
                    bar,
                    ws_spring,
                    Some(&self.ghost_spring),
                    &self.peek_springs,
                ),
            };
            spec.layer = layer;
            self.cached_specs.push(spec);
        }

        if let Some(ref menu) = self.win_menu {
            if let Some(output) = state.outputs.get(&menu.output_name) {
                self.cached_specs
                    .push(build_win_menu_surface(state, output, menu));
            }
        }
    }

    fn update_hover(&mut self, state: &AppState, surface_id: &str, x: f32, y: f32) -> bool {
        let Some(spec) = self.cached_specs.iter().find(|s| s.id == surface_id) else {
            return false;
        };
        let hit = spec
            .hit_targets
            .iter()
            .rev()
            .find(|t| t.rect.contains(x, y))
            .map(|t| t.id.clone());
        let prev = self.hovered_targets.get(surface_id).cloned();
        if prev != hit {
            if let Some(tgt) = hit {
                self.hovered_targets.insert(surface_id.to_string(), tgt);
            } else {
                self.hovered_targets.remove(surface_id);
            }
            self.sync_springs(state, false);
            return true;
        }
        false
    }
}

impl KazeExtension for BarExtension {
    fn id(&self) -> &'static str {
        "bar"
    }

    fn on_init(&mut self, ctx: &mut ShellContext) {
        self.sync_springs(ctx.state, true);
        self.rebuild(ctx.state);
        self.sync_demand(ctx);
    }

    fn on_event(&mut self, event: &SystemEvent, ctx: &mut ShellContext) -> DirtyFlags {
        match event {
            SystemEvent::OutputAdded(_)
            | SystemEvent::OutputUpdated(_)
            | SystemEvent::OutputRemoved { .. } => {
                self.sync_springs(ctx.state, true);
                self.rebuild(ctx.state);
                self.sync_demand(ctx);
                DirtyFlags::BAR | DirtyFlags::LAYOUT
            }
            SystemEvent::FrameTick {
                surface_id,
                dt_secs,
            } => {
                if !surface_id.starts_with("bar:") {
                    return DirtyFlags::NONE;
                }
                let mut changed = false;
                if let Some(out_name) = surface_id.rsplit(':').next() {
                    if let Some(sp) = self.ws_springs.get_mut(out_name) {
                        if !sp.is_settled() {
                            sp.step(*dt_secs);
                            changed = true;
                        }
                    }
                }
                if ctx.state.layout_preset == LayoutPreset::Ghost && !self.ghost_spring.is_settled()
                {
                    self.ghost_spring.step(*dt_secs);
                    changed = true;
                }
                let prefix = format!("{surface_id}|");
                for (k, sp) in &mut self.peek_springs {
                    if k.starts_with(&prefix) && !sp.is_settled() {
                        sp.step(*dt_secs);
                        changed = true;
                    }
                }
                if changed {
                    self.rebuild(ctx.state);
                    DirtyFlags::BAR
                } else {
                    DirtyFlags::NONE
                }
            }
            SystemEvent::PointerEnter { surface_id, x, y }
            | SystemEvent::PointerMotion { surface_id, x, y } => {
                if !surface_id.starts_with("bar:") {
                    return DirtyFlags::NONE;
                }
                let mut changed = false;
                if let Some(out_name) = surface_id.rsplit(':').next() {
                    if ctx.state.fullscreen_outputs.contains(out_name)
                        && self.peeked_outputs.insert(out_name.to_string())
                    {
                        changed = true;
                    }
                }
                if self.update_hover(ctx.state, surface_id, *x, *y) {
                    changed = true;
                }
                if changed {
                    self.rebuild(ctx.state);
                    DirtyFlags::BAR
                } else {
                    DirtyFlags::NONE
                }
            }
            SystemEvent::PointerLeave { surface_id } => {
                if !surface_id.starts_with("bar:") {
                    return DirtyFlags::NONE;
                }
                let mut changed = self.hovered_targets.remove(surface_id).is_some();
                if let Some(out_name) = surface_id.rsplit(':').next() {
                    changed |= self.peeked_outputs.remove(out_name);
                }
                if changed {
                    self.sync_springs(ctx.state, false);
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
                self.sync_demand(ctx);
                DirtyFlags::BAR | DirtyFlags::LAYOUT
            }
            SystemEvent::HyprSynced { .. }
            | SystemEvent::HyprWorkspaceChanged { .. }
            | SystemEvent::HyprFocusedMonitor { .. }
            | SystemEvent::WindowsUpdated { .. } => {
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
            | SystemEvent::BacklightChanged { .. }
            | SystemEvent::MediaChanged(_)
            | SystemEvent::DndChanged(_)
            | SystemEvent::NightLightChanged { .. }
            | SystemEvent::CaffeineChanged(_)
            | SystemEvent::ControlCenterChanged(_)
            | SystemEvent::TrayItemsChanged(_)
            | SystemEvent::NotificationsCountChanged(_)
            | SystemEvent::NotificationClearAll
            | SystemEvent::PowerProfileChanged(_)
            | SystemEvent::PrivacyChanged(_)
            | SystemEvent::KeyboardLayoutChanged { .. }
            | SystemEvent::LockKeysChanged { .. }
            | SystemEvent::WidgetExecOutput { .. }
            | SystemEvent::SysmonUpdated(_)
            | SystemEvent::WeatherUpdated(_)
            | SystemEvent::ScreenTimeUpdated(_)
            | SystemEvent::CalendarUpdated(_) => {
                self.sync_springs(ctx.state, false);
                self.rebuild(ctx.state);
                DirtyFlags::BAR
            }
            SystemEvent::AudioSpectrum(_) => {
                if !self.subscribed_spectrum {
                    return DirtyFlags::NONE;
                }
                self.rebuild(ctx.state);
                DirtyFlags::BAR
            }
            SystemEvent::ConfigReloaded | SystemEvent::ThemeChanged(_) => {
                self.sync_springs(ctx.state, true);
                self.rebuild(ctx.state);
                self.sync_demand(ctx);
                DirtyFlags::BAR | DirtyFlags::LAYOUT | DirtyFlags::THEME
            }
            SystemEvent::SessionLockRequested
            | SystemEvent::LockWorkerCommitted
            | SystemEvent::LockWorkerExited
            | SystemEvent::SessionUnlockRequested
            | SystemEvent::PrepareForSleep(_) => {
                self.sync_demand(ctx);
                DirtyFlags::NONE
            }
            SystemEvent::TimerFired { id } => {
                if id == GHOST_PEEK_TIMER_ID {
                    let mut changed = false;
                    if self.ghost_peeking {
                        self.ghost_peeking = false;
                        changed = true;
                    }
                    if !self.peeked_outputs.is_empty() {
                        self.peeked_outputs.clear();
                        changed = true;
                    }
                    if changed {
                        self.sync_springs(ctx.state, false);
                        self.rebuild(ctx.state);
                        self.sync_demand(ctx);
                        DirtyFlags::BAR | DirtyFlags::LAYOUT
                    } else {
                        DirtyFlags::NONE
                    }
                } else if let Some(inst_id) = id.strip_prefix(EXEC_TIMER_PREFIX) {
                    if let Some(&secs) = self.scheduled_exec_timers.get(inst_id) {
                        let rw = resolve_widget(ctx.state, inst_id);
                        if !rw.cfg.exec.trim().is_empty() {
                            ctx.push_action(ShellAction::RunWidgetExec {
                                instance_id: inst_id.to_string(),
                                command: rw.cfg.exec,
                            });
                        }
                        ctx.push_action(ShellAction::ScheduleTimer {
                            id: id.clone(),
                            after_ms: secs * 1000,
                        });
                    }
                    DirtyFlags::NONE
                } else {
                    DirtyFlags::NONE
                }
            }
            SystemEvent::PointerClick {
                surface_id,
                target_id,
                button,
            } => {
                if surface_id == "bar:winmenu" {
                    match target_id.as_str() {
                        "winmenu:fullscreen" => {
                            ctx.push_action(ShellAction::HyprDispatch("fullscreen 1".into()));
                        }
                        "winmenu:float" => {
                            ctx.push_action(ShellAction::HyprDispatch("togglefloating".into()));
                        }
                        "winmenu:pin" => {
                            ctx.push_action(ShellAction::HyprDispatch("pin".into()));
                        }
                        "winmenu:close" => {
                            if let Some(ref m) = self.win_menu {
                                ctx.push_action(ShellAction::HyprDispatch(format!(
                                    "closewindow address:{}",
                                    m.window_addr
                                )));
                            }
                        }
                        _ => {}
                    }
                    self.win_menu = None;
                    self.rebuild(ctx.state);
                    return DirtyFlags::BAR;
                }

                if !surface_id.starts_with("bar:") {
                    return DirtyFlags::NONE;
                }
                let output_name = surface_id
                    .rsplit(':')
                    .next()
                    .unwrap_or_default()
                    .to_string();

                if let Some(ws_str) = target_id.strip_prefix("ws:") {
                    if *button == PointerButton::Left {
                        if let Ok(ws_id) = ws_str.parse::<i32>() {
                            ctx.push_action(ShellAction::HyprDispatch(format!(
                                "workspace {ws_id}"
                            )));
                        }
                    } else if *button == PointerButton::Middle {
                        ctx.push_action(ShellAction::SettingsOpen("widget:workspaces".into()));
                    }
                    return DirtyFlags::NONE;
                }

                if let Some(addr) = target_id.strip_prefix("taskbar:win:") {
                    match button {
                        PointerButton::Left => {
                            if ctx.state.active_window_address.as_deref() == Some(addr) {
                                ctx.push_action(ShellAction::HyprDispatch(format!(
                                    "movetoworkspacesilent special:minimized,address:{addr}"
                                )));
                            } else {
                                ctx.push_action(ShellAction::HyprDispatch(format!(
                                    "focuswindow address:{addr}"
                                )));
                            }
                        }
                        PointerButton::Right => {
                            ctx.push_action(ShellAction::HyprDispatch(format!(
                                "closewindow address:{addr}"
                            )));
                        }
                        PointerButton::Middle => {
                            ctx.push_action(ShellAction::SettingsOpen("widget:taskbar".into()));
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
                                    ctx.push_action(ShellAction::SettingsOpen(
                                        "widget:tray".into(),
                                    ));
                                }
                            }
                        }
                    }
                    return DirtyFlags::NONE;
                }

                if let Some(inst_id) = target_id.strip_prefix("widget:") {
                    let rw = resolve_widget(ctx.state, inst_id);
                    if rw.kind == "custom_button" {
                        let cmd = match button {
                            PointerButton::Left => rw.cfg.on_left_click.as_str(),
                            PointerButton::Right => rw.cfg.on_right_click.as_str(),
                            PointerButton::Middle => rw.cfg.on_middle_click.as_str(),
                        };
                        if !cmd.trim().is_empty() {
                            ctx.push_action(ShellAction::SpawnCommand {
                                program: "sh".to_string(),
                                args: vec!["-c".to_string(), cmd.to_string()],
                            });
                            return DirtyFlags::NONE;
                        }
                    }
                    if *button == PointerButton::Middle {
                        ctx.push_action(ShellAction::SettingsOpen(format!("widget:{inst_id}")));
                    } else if *button == PointerButton::Left {
                        match rw.kind.as_str() {
                            "calendar" => ctx.push_action(ShellAction::ToggleControlCenter),
                            "weather" => ctx.push_action(ShellAction::WeatherRefresh),
                            "sysmon" => ctx.push_action(ShellAction::ToggleControlCenter),
                            "screen_time" => ctx.push_action(ShellAction::ToggleControlCenter),
                            _ => {}
                        }
                    }
                    return DirtyFlags::NONE;
                }

                if *button == PointerButton::Middle {
                    ctx.push_action(ShellAction::SettingsOpen(format!("widget:{target_id}")));
                    return DirtyFlags::NONE;
                }

                match target_id.as_str() {
                    "cc" => {
                        if *button == PointerButton::Left {
                            ctx.push_action(ShellAction::ToggleControlCenter);
                        }
                    }
                    "launcher" => {
                        if *button == PointerButton::Left {
                            ctx.push_action(ShellAction::SpawnCommand {
                                program: "kaze-ctl".into(),
                                args: vec!["launcher-toggle".into()],
                            });
                        }
                    }
                    "window_switcher_btn" => {
                        if *button == PointerButton::Left {
                            ctx.push_action(ShellAction::SpawnCommand {
                                program: "kaze-ctl".into(),
                                args: vec!["switcher-open".into()],
                            });
                        }
                    }
                    "active_window" => {
                        if *button == PointerButton::Right {
                            if let Some(w) = ctx.state.active_window() {
                                if self.win_menu.is_some() {
                                    self.win_menu = None;
                                } else {
                                    let pos = self
                                        .effective_bars(ctx.state)
                                        .into_iter()
                                        .find(|b| b.output_name == output_name)
                                        .map_or(ctx.state.config.bar.position, |b| b.position);
                                    self.win_menu = Some(WinMenuState {
                                        output_name,
                                        bar_position: pos,
                                        window_addr: w.address.clone(),
                                        floating: w.floating,
                                        fullscreen: w.fullscreen,
                                    });
                                }
                                self.rebuild(ctx.state);
                                return DirtyFlags::BAR;
                            }
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
                    "net" => match button {
                        PointerButton::Left => {
                            ctx.push_action(ShellAction::SpawnDetachedApp {
                                program: "kaze-tui".to_string(),
                                args: vec!["wifi".to_string()],
                            });
                        }
                        PointerButton::Right => ctx.push_action(ShellAction::WifiToggle),
                        PointerButton::Middle => {}
                    },
                    "bluetooth" | "battery_peripherals" => match button {
                        PointerButton::Left => ctx.push_action(ShellAction::ToggleControlCenter),
                        PointerButton::Right => ctx.push_action(ShellAction::BluetoothToggle),
                        PointerButton::Middle => {}
                    },
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
                        PointerButton::Middle => {}
                    },
                    "mic" => {
                        if *button == PointerButton::Left || *button == PointerButton::Right {
                            ctx.push_action(ShellAction::AudioToggleMicMute);
                        }
                    }
                    "media" => match button {
                        PointerButton::Left => {
                            ctx.push_action(ShellAction::MediaCommand("PlayPause".into()));
                        }
                        PointerButton::Right => {
                            ctx.push_action(ShellAction::MediaCommand("Next".into()));
                        }
                        PointerButton::Middle => {}
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
                    "caffeine" => {
                        if *button == PointerButton::Left {
                            ctx.push_action(ShellAction::SetCaffeine(!ctx.state.caffeine_enabled));
                        }
                    }
                    "night_light" => {
                        if *button == PointerButton::Left {
                            ctx.push_action(ShellAction::SetNightLight {
                                enabled: !ctx.state.nightlight_enabled,
                                temp_k: ctx.state.nightlight_temp_k,
                            });
                        }
                    }
                    "power_profile" => {
                        if *button == PointerButton::Left {
                            let next = match ctx.state.power_profile.active.as_str() {
                                "power-saver" => "balanced",
                                "balanced" => "performance",
                                _ => "power-saver",
                            };
                            ctx.push_action(ShellAction::SetPowerProfile(next.to_string()));
                        }
                    }
                    "screenshot" => {
                        if *button == PointerButton::Left {
                            ctx.push_action(ShellAction::SpawnCommand {
                                program: "kaze-ctl".into(),
                                args: vec!["capture-area".into()],
                            });
                        }
                    }
                    "color_picker" => {
                        if *button == PointerButton::Left {
                            ctx.push_action(ShellAction::SpawnCommand {
                                program: "kaze-ctl".into(),
                                args: vec!["color-picker".into()],
                            });
                        }
                    }
                    "clipboard" => {
                        if *button == PointerButton::Left {
                            ctx.push_action(ShellAction::SpawnCommand {
                                program: "kaze-ctl".into(),
                                args: vec!["clipboard-toggle".into()],
                            });
                        }
                    }
                    "record" => {
                        if *button == PointerButton::Left {
                            ctx.push_action(ShellAction::SpawnCommand {
                                program: "kaze-screen".into(),
                                args: vec!["record-toggle".into()],
                            });
                        }
                    }
                    "session" if *button == PointerButton::Left => {
                        ctx.push_action(ShellAction::SpawnCommand {
                            program: "kaze-ctl".into(),
                            args: vec!["session-open".into()],
                        });
                    }
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
                if !surface_id.starts_with("bar:") {
                    return DirtyFlags::NONE;
                }
                let mag = if modifiers.shift { 1 } else { 5 };
                let step = if *delta_y < 0.0 { mag } else { -mag };
                if target_id == "vol" {
                    ctx.push_action(ShellAction::AudioStepVolume(step));
                } else if target_id == "brightness" {
                    ctx.push_action(ShellAction::BacklightStep(step));
                } else if target_id.starts_with("ws:") {
                    let dir = if *delta_y < 0.0 { "e-1" } else { "e+1" };
                    ctx.push_action(ShellAction::HyprDispatch(format!("workspace {dir}")));
                }
                DirtyFlags::NONE
            }
            SystemEvent::SurfaceClosed { surface_id } => {
                if surface_id == "bar:winmenu" && self.win_menu.is_some() {
                    self.win_menu = None;
                    self.rebuild(ctx.state);
                    DirtyFlags::BAR
                } else {
                    DirtyFlags::NONE
                }
            }
            _ => DirtyFlags::NONE,
        }
    }

    fn on_ipc(&mut self, cmd: &str, args: &[String], ctx: &mut ShellContext) -> IpcResult {
        match cmd {
            "bar-hide" => match args {
                [] => {
                    ctx.state.hide_all_bars = true;
                    self.rebuild(ctx.state);
                    self.sync_demand(ctx);
                    IpcResult::Handled {
                        ok: true,
                        message: "hidden all bars".into(),
                        dirty: DirtyFlags::BAR | DirtyFlags::LAYOUT,
                    }
                }
                [monitor] => {
                    ctx.state.hidden_bars.insert(monitor.clone());
                    self.rebuild(ctx.state);
                    self.sync_demand(ctx);
                    IpcResult::Handled {
                        ok: true,
                        message: format!("hidden bar on {monitor}"),
                        dirty: DirtyFlags::BAR | DirtyFlags::LAYOUT,
                    }
                }
                [bar_name, monitor, ..] => {
                    ctx.state
                        .hidden_bars
                        .insert(format!("{bar_name}:{monitor}"));
                    self.rebuild(ctx.state);
                    self.sync_demand(ctx);
                    IpcResult::Handled {
                        ok: true,
                        message: format!("hidden bar {bar_name} on {monitor}"),
                        dirty: DirtyFlags::BAR | DirtyFlags::LAYOUT,
                    }
                }
            },
            "bar-show" => match args {
                [] => {
                    ctx.state.hide_all_bars = false;
                    ctx.state.hidden_bars.clear();
                    self.rebuild(ctx.state);
                    self.sync_demand(ctx);
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
                    self.sync_demand(ctx);
                    IpcResult::Handled {
                        ok: true,
                        message: format!("shown bar on {monitor}"),
                        dirty: DirtyFlags::BAR | DirtyFlags::LAYOUT,
                    }
                }
                [bar_name, monitor, ..] => {
                    ctx.state.hide_all_bars = false;
                    ctx.state
                        .hidden_bars
                        .remove(&format!("{bar_name}:{monitor}"));
                    self.rebuild(ctx.state);
                    self.sync_demand(ctx);
                    IpcResult::Handled {
                        ok: true,
                        message: format!("shown bar {bar_name} on {monitor}"),
                        dirty: DirtyFlags::BAR | DirtyFlags::LAYOUT,
                    }
                }
            },
            "bar-peek" => {
                if ctx.state.layout_preset != LayoutPreset::Ghost {
                    if !ctx.state.fullscreen_outputs.is_empty() {
                        let should_peek = match args.first().map(String::as_str) {
                            Some("on" | "show") => true,
                            Some("off" | "hide") => false,
                            _ => self.peeked_outputs.is_empty(),
                        };
                        if should_peek {
                            self.peeked_outputs = ctx.state.fullscreen_outputs.clone();
                            ctx.push_action(ShellAction::ScheduleTimer {
                                id: GHOST_PEEK_TIMER_ID.to_string(),
                                after_ms: GHOST_PEEK_MS,
                            });
                        } else {
                            self.peeked_outputs.clear();
                            ctx.push_action(ShellAction::CancelTimer {
                                id: GHOST_PEEK_TIMER_ID.to_string(),
                            });
                        }
                        self.rebuild(ctx.state);
                        return IpcResult::Handled {
                            ok: true,
                            message: if should_peek {
                                "peeking fullscreen".into()
                            } else {
                                "restored top layer".into()
                            },
                            dirty: DirtyFlags::BAR,
                        };
                    }
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
                self.sync_demand(ctx);
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
                self.sync_demand(ctx);
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

fn find_monitor_override<'a>(
    state: &'a AppState,
    output_name: &str,
) -> Option<&'a BarMonitorOverride> {
    let mid = state.monitor_id(output_name);
    state
        .config
        .bar
        .monitors
        .get(output_name)
        .or_else(|| state.config.bar.monitors.get(&mid))
        .or_else(|| state.config.bar.monitors.get("*"))
}

fn apply_monitor_override(eff: &mut EffectiveBar, ov: &BarMonitorOverride) {
    if let Some(v) = ov.enabled {
        eff.enabled = v;
    }
    if let Some(v) = ov.position {
        eff.position = v;
    }
    if let Some(v) = ov.thickness {
        eff.thickness = v;
    }
    if let Some(v) = ov.length {
        eff.length = v;
    }
    if let Some(v) = ov.margin_edge {
        eff.margin_edge = v;
    }
    if let Some(v) = ov.margin_ends {
        eff.margin_ends = v;
    }
    if let Some(v) = ov.corner_radius {
        eff.corner_radius = v;
    }
    if let Some(v) = ov.exclusive {
        eff.exclusive = v;
    }
    if let Some(v) = ov.layer {
        eff.layer = v;
    }
    if let Some(ref v) = ov.section_mode {
        eff.section_mode = v.clone();
    }
    if let Some(ref v) = ov.start_slots {
        eff.start_slots = v.clone();
    }
    if let Some(ref v) = ov.center_slots {
        eff.center_slots = v.clone();
    }
    if let Some(ref v) = ov.end_slots {
        eff.end_slots = v.clone();
    }
}

fn resolve_bar_layer(
    mode: BarLayerMode,
    ghost_peeking: bool,
    menu_open: bool,
    fullscreen_peeking: bool,
) -> Layer {
    match mode {
        BarLayerMode::Top => Layer::Top,
        BarLayerMode::Overlay => Layer::Overlay,
        BarLayerMode::Auto => {
            if ghost_peeking || menu_open || fullscreen_peeking {
                Layer::Overlay
            } else {
                Layer::Top
            }
        }
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

fn collect_slot_visuals(
    state: &AppState,
    slot_names: &[String],
    output_name: &str,
) -> Vec<WidgetVisual> {
    let mut out = Vec::new();
    for name in slot_names {
        out.extend(build_widget_visuals(state, name, output_name));
    }
    out
}

fn push_widget_visual(
    commands: &mut Vec<PaintCmd>,
    slot: &WidgetVisual,
    slot_rect: Rect,
    icon_rect: Rect,
    label_rect: Option<Rect>,
    primary: Color,
    secondary: Color,
) {
    if let Some(vis_kind) = slot.visualizer {
        render_visualizer(
            commands,
            slot_rect,
            vis_kind,
            &state_free_spectrum_placeholder(slot),
            primary,
            secondary,
        );
        let _ = (icon_rect, label_rect);
        return;
    }

    if let Some((w, h, ref rgba)) = slot.image {
        let side = icon_rect.w.min(icon_rect.h).max(14.0);
        let img_rect = Rect::new(
            icon_rect.x + (icon_rect.w - side) * 0.5,
            icon_rect.y + (icon_rect.h - side) * 0.5,
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
            rect: icon_rect,
            text: mono.clone(),
            color: slot.icon_color,
            size: 11.0,
            bold: true,
            align: TextAlign::Center,
        });
    }

    if let (Some(lrect), Some(ref txt)) = (label_rect, &slot.label) {
        if lrect.w >= 4.0 && !txt.is_empty() {
            let align = if slot.icon.is_none() && slot.image.is_none() && slot.monogram.is_none() {
                TextAlign::Center
            } else {
                TextAlign::Left
            };
            if slot.tabular {
                commands.push(PaintCmd::TabularText {
                    rect: lrect,
                    text: txt.clone(),
                    color: slot.text_color,
                    size: 11.5,
                    bold: false,
                    align,
                });
            } else {
                commands.push(PaintCmd::Text {
                    rect: lrect,
                    text: txt.clone(),
                    color: slot.text_color,
                    size: 11.5,
                    bold: false,
                    align,
                });
            }
        }
    }

    if !slot.dots.is_empty() {
        for (i, dcol) in slot.dots.iter().take(3).enumerate() {
            commands.push(PaintCmd::Circle {
                cx: slot_rect.x + slot_rect.w - 5.0 - i as f32 * 5.5,
                cy: slot_rect.y + 5.0,
                radius: 2.3,
                fill: *dcol,
            });
        }
    } else if let Some(dot_color) = slot.dot {
        commands.push(PaintCmd::Circle {
            cx: slot_rect.x + slot_rect.w - 5.0,
            cy: slot_rect.y + 5.0,
            radius: 3.0,
            fill: dot_color,
        });
    } else if let Some(badge) = slot.badge_count.filter(|&c| c > 0) {
        commands.push(PaintCmd::Circle {
            cx: slot_rect.x + slot_rect.w - 5.0,
            cy: slot_rect.y + 6.0,
            radius: 4.5,
            fill: primary,
        });
        let _ = badge;
    }
}

fn state_free_spectrum_placeholder(slot: &WidgetVisual) -> Vec<u8> {
    if let Some(ref raw) = slot.label {
        // Widgets.rs puts bars fallback or we get actual spectrum in build_bar_surface.
        raw.as_bytes().to_vec()
    } else {
        Vec::new()
    }
}

fn workspace_focus_index(state: &AppState, output_name: &str) -> usize {
    collect_workspaces(state, output_name)
        .iter()
        .position(|(_, focused, _)| *focused)
        .unwrap_or(0)
}

fn widget_horizontal_width(slot: &WidgetVisual, cell_h: f32, peek_factor: f32) -> (f32, f32) {
    if slot.is_spacer {
        return (10.0, 0.0);
    }
    if slot.visualizer.is_some() {
        return ((cell_h * 1.6).max(40.0), 0.0);
    }
    let has_symbol = slot.icon.is_some() || slot.image.is_some() || slot.monogram.is_some();
    let base_w = if has_symbol { cell_h.max(26.0) } else { 8.0 };
    let full_label_w = slot.label.as_deref().map_or(0.0, |t| {
        (t.chars().count() as f32 * 7.1 + 8.0).clamp(18.0, 180.0)
    });
    let shown_label_w = if slot.peek {
        full_label_w * peek_factor.clamp(0.0, 1.0)
    } else {
        full_label_w
    };
    (
        (base_w + shown_label_w).max(cell_h.max(26.0)),
        shown_label_w,
    )
}

fn build_bar_surface(
    state: &AppState,
    output: &OutputInfo,
    bar: &EffectiveBar,
    ws_spring: Option<Spring>,
    ghost_spring: Option<&Spring>,
    peek_springs: &HashMap<String, Spring>,
) -> SurfaceSpec {
    let colors = state.palette.for_mode(state.theme_mode);
    let is_ghost = ghost_spring.is_some();
    let is_vertical = is_ghost || bar.position.is_vertical();
    let is_island_single = !is_ghost && (bar.island_mode || bar.length > 0);
    let click_through_sections = !is_ghost
        && !is_island_single
        && matches!(
            bar.section_mode.trim().to_ascii_lowercase().as_str(),
            "island" | "pills"
        );
    let shift_x = ghost_spring.map_or(0.0, |s| s.value);

    let (anchor, width, height, margin, logical_w, logical_h) = match bar.position {
        BarPosition::Left => {
            if is_island_single {
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
            if is_island_single {
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
            if is_island_single {
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
            if is_island_single {
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

    let exclusive_zone = if is_ghost || click_through_sections {
        0
    } else if bar.exclusive && !is_island_single {
        bar.thickness as i32
    } else {
        0
    };

    let mut commands = Vec::new();
    let mut hit_targets = Vec::new();
    let mut input_regions = if click_through_sections {
        Some(Vec::new())
    } else {
        None
    };

    let workspaces = collect_workspaces(state, &output.name);
    let start_slots = collect_slot_visuals(state, &bar.start_slots, &output.name);
    let center_slots = collect_slot_visuals(state, &bar.center_slots, &output.name);
    let end_slots = collect_slot_visuals(state, &bar.end_slots, &output.name);
    let has_peek = start_slots
        .iter()
        .chain(center_slots.iter())
        .chain(end_slots.iter())
        .any(|s| s.peek);

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
    let pill_r = if bar.corner_radius > 0.0 {
        bar.corner_radius
    } else {
        (bar.thickness as f32 * 0.45).min(14.0)
    };

    let render_slot_slice = |cmds: &mut Vec<PaintCmd>,
                             hits: &mut Vec<HitTarget>,
                             slot: &WidgetVisual,
                             slot_rect: Rect,
                             label_w: f32| {
        if slot.is_spacer {
            return;
        }
        if slot.fill.a > 0 {
            cmds.push(PaintCmd::RoundedRect {
                rect: slot_rect,
                radius: inner_radius,
                fill: Some(slot.fill),
                stroke: slot.stroke,
                stroke_width: if slot.stroke.is_some() { 1.0 } else { 0.0 },
            });
        }
        if let Some(vis_kind) = slot.visualizer {
            render_visualizer(
                cmds,
                slot_rect,
                vis_kind,
                &state.audio_spectrum,
                primary,
                secondary,
            );
            hits.push(HitTarget {
                rect: slot_rect,
                id: slot.target_id.clone(),
            });
            return;
        }
        let icon_zone_w = if label_w > 0.0 {
            slot_rect.h.max(24.0).min(slot_rect.w)
        } else {
            slot_rect.w
        };
        let icon_w = (icon_zone_w * 0.56).clamp(12.0, 17.0);
        let icon_h = (slot_rect.h * 0.54).clamp(10.0, 15.0);
        let icon_rect = Rect::new(
            slot_rect.x + (icon_zone_w - icon_w) * 0.5,
            slot_rect.y + (slot_rect.h - icon_h) * 0.5,
            icon_w,
            icon_h,
        );
        let label_rect = if label_w > 4.0 {
            let lx = if slot.icon.is_some() || slot.image.is_some() || slot.monogram.is_some() {
                slot_rect.x + icon_zone_w
            } else {
                slot_rect.x + 4.0
            };
            Some(Rect::new(
                lx,
                slot_rect.y,
                (slot_rect.x + slot_rect.w - lx - 4.0).max(0.0),
                slot_rect.h,
            ))
        } else {
            None
        };
        push_widget_visual(
            cmds, slot, slot_rect, icon_rect, label_rect, primary, secondary,
        );
        hits.push(HitTarget {
            rect: slot_rect,
            id: slot.target_id.clone(),
        });
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

        // Start cluster: Workspaces + start_slots
        let ws_start_y = pad + bar.border_width;
        let mut cur_y = ws_start_y;
        let start_cluster_top = cur_y - pad;
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
            commands.push(PaintCmd::TabularText {
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
        for slot in &start_slots {
            let slot_rect = Rect::new(pad + shift_x, cur_y, cell_w, cell_h);
            render_slot_slice(&mut commands, &mut hit_targets, slot, slot_rect, 0.0);
            cur_y += cell_h + spacing;
        }
        if let Some(ref mut regs) = input_regions {
            let h = (cur_y - start_cluster_top).max(cell_h + pad * 2.0);
            let pill = Rect::new(0.0, start_cluster_top.max(0.0), bw, h);
            commands.insert(
                0,
                PaintCmd::RoundedRect {
                    rect: pill,
                    radius: pill_r,
                    fill: Some(bg),
                    stroke: Some(border_color),
                    stroke_width: bar.border_width,
                },
            );
            regs.push(pill);
        }

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

        // Center cluster
        let center_y = bh * 0.5;
        if center_slots.is_empty() {
            let hh_rect = Rect::new(pad + shift_x, center_y - 18.0, cell_w, 17.0);
            let mm_rect = Rect::new(pad + shift_x, center_y + 1.0, cell_w, 17.0);
            if let Some(ref mut regs) = input_regions {
                let pill = Rect::new(0.0, center_y - 24.0, bw, 48.0);
                commands.push(PaintCmd::RoundedRect {
                    rect: pill,
                    radius: pill_r,
                    fill: Some(bg),
                    stroke: Some(border_color),
                    stroke_width: bar.border_width,
                });
                regs.push(pill);
            }
            commands.push(PaintCmd::TabularText {
                rect: hh_rect,
                text: state.clock.format_hh(),
                color: on_surface,
                size: 13.0,
                bold: true,
                align: TextAlign::Center,
            });
            commands.push(PaintCmd::TabularText {
                rect: mm_rect,
                text: state.clock.format_mm(),
                color: muted,
                size: 13.0,
                bold: false,
                align: TextAlign::Center,
            });
        } else {
            let total_ch = center_slots.len() as f32 * cell_h
                + center_slots.len().saturating_sub(1) as f32 * spacing;
            let mut cy = (center_y - total_ch * 0.5).max(cur_y + spacing);
            if let Some(ref mut regs) = input_regions {
                let pill = Rect::new(0.0, (cy - pad).max(0.0), bw, total_ch + pad * 2.0);
                commands.push(PaintCmd::RoundedRect {
                    rect: pill,
                    radius: pill_r,
                    fill: Some(bg),
                    stroke: Some(border_color),
                    stroke_width: bar.border_width,
                });
                regs.push(pill);
            }
            for slot in &center_slots {
                let slot_rect = Rect::new(pad + shift_x, cy, cell_w, cell_h);
                render_slot_slice(&mut commands, &mut hit_targets, slot, slot_rect, 0.0);
                cy += cell_h + spacing;
            }
        }

        // End cluster
        let slot_h = cell_w.min(30.0);
        let total_slots_h =
            end_slots.len() as f32 * slot_h + (end_slots.len().saturating_sub(1)) as f32 * spacing;
        let mut slot_y = (bh - pad - bar.border_width - total_slots_h).max(center_y + 24.0);
        if let Some(ref mut regs) = input_regions {
            if !end_slots.is_empty() {
                let pill = Rect::new(0.0, (slot_y - pad).max(0.0), bw, total_slots_h + pad * 2.0);
                commands.push(PaintCmd::RoundedRect {
                    rect: pill,
                    radius: pill_r,
                    fill: Some(bg),
                    stroke: Some(border_color),
                    stroke_width: bar.border_width,
                });
                regs.push(pill);
            }
        }
        for slot in &end_slots {
            let slot_rect = Rect::new(pad + shift_x, slot_y, cell_w, slot_h);
            render_slot_slice(&mut commands, &mut hit_targets, slot, slot_rect, 0.0);
            slot_y += slot_h + spacing;
        }
    } else {
        // Horizontal bar
        let bw = logical_w as f32;
        let bh = logical_h as f32;
        let cell_h = (bh - pad * 2.0).max(16.0);
        let ws_w = cell_h.min(28.0);

        let peek_factor_for = |slot: &WidgetVisual| -> f32 {
            let key = format!("{}|{}", bar.surface_id, slot.target_id);
            peek_springs.get(&key).map_or(0.0, |s| s.value)
        };

        // Start cluster
        let start_metrics: Vec<(f32, f32)> = start_slots
            .iter()
            .map(|s| widget_horizontal_width(s, cell_h, peek_factor_for(s)))
            .collect();
        let ws_total_w =
            workspaces.len() as f32 * ws_w + workspaces.len().saturating_sub(1) as f32 * spacing;
        let start_extra_w: f32 = start_metrics.iter().map(|(w, _)| *w + spacing).sum();
        if let Some(ref mut regs) = input_regions {
            let pill = Rect::new(
                0.0,
                0.0,
                (pad * 2.0 + ws_total_w + start_extra_w).max(40.0),
                bh,
            );
            commands.push(PaintCmd::RoundedRect {
                rect: pill,
                radius: pill_r,
                fill: Some(bg),
                stroke: Some(border_color),
                stroke_width: bar.border_width,
            });
            regs.push(pill);
        }

        let mut cur_x = pad + bar.border_width;
        for (ws_id, focused, occupied) in &workspaces {
            let rect = Rect::new(cur_x, pad, ws_w, cell_h);
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
            commands.push(PaintCmd::TabularText {
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
            cur_x += ws_w + spacing;
        }
        for (slot, &(w, label_w)) in start_slots.iter().zip(&start_metrics) {
            let slot_rect = Rect::new(cur_x, pad, w, cell_h);
            render_slot_slice(&mut commands, &mut hit_targets, slot, slot_rect, label_w);
            cur_x += w + spacing;
        }

        // Center cluster
        let center_metrics: Vec<(f32, f32)> = center_slots
            .iter()
            .map(|s| widget_horizontal_width(s, cell_h, peek_factor_for(s)))
            .collect();
        let center_right = if center_slots.is_empty() {
            let clock_w = 56.0;
            let clock_rect = Rect::new((bw - clock_w) * 0.5, pad, clock_w, cell_h);
            if let Some(ref mut regs) = input_regions {
                let pill = Rect::new(clock_rect.x - pad, 0.0, clock_w + pad * 2.0, bh);
                commands.push(PaintCmd::RoundedRect {
                    rect: pill,
                    radius: pill_r,
                    fill: Some(bg),
                    stroke: Some(border_color),
                    stroke_width: bar.border_width,
                });
                regs.push(pill);
            }
            commands.push(PaintCmd::TabularText {
                rect: clock_rect,
                text: state.clock.format_hh_mm(),
                color: on_surface,
                size: 13.0,
                bold: true,
                align: TextAlign::Center,
            });
            clock_rect.x + clock_rect.w
        } else {
            let total_cw: f32 = center_metrics.iter().map(|(w, _)| *w).sum::<f32>()
                + center_slots.len().saturating_sub(1) as f32 * spacing;
            let mut cx = ((bw - total_cw) * 0.5).max(cur_x + 8.0);
            if let Some(ref mut regs) = input_regions {
                let pill = Rect::new(cx - pad, 0.0, total_cw + pad * 2.0, bh);
                commands.push(PaintCmd::RoundedRect {
                    rect: pill,
                    radius: pill_r,
                    fill: Some(bg),
                    stroke: Some(border_color),
                    stroke_width: bar.border_width,
                });
                regs.push(pill);
            }
            for (slot, &(w, label_w)) in center_slots.iter().zip(&center_metrics) {
                let slot_rect = Rect::new(cx, pad, w, cell_h);
                render_slot_slice(&mut commands, &mut hit_targets, slot, slot_rect, label_w);
                cx += w + spacing;
            }
            cx
        };

        // End cluster
        let end_metrics: Vec<(f32, f32)> = end_slots
            .iter()
            .map(|s| widget_horizontal_width(s, cell_h, peek_factor_for(s)))
            .collect();
        let total_slots_w: f32 = end_metrics.iter().map(|(w, _)| *w).sum::<f32>()
            + (end_slots.len().saturating_sub(1)) as f32 * spacing;
        let mut slot_x = (bw - pad - bar.border_width - total_slots_w).max(center_right + 8.0);
        if let Some(ref mut regs) = input_regions {
            if !end_slots.is_empty() {
                let pill = Rect::new(
                    (slot_x - pad).max(0.0),
                    0.0,
                    (total_slots_w + pad * 2.0 + bar.border_width).min(bw),
                    bh,
                );
                commands.push(PaintCmd::RoundedRect {
                    rect: pill,
                    radius: pill_r,
                    fill: Some(bg),
                    stroke: Some(border_color),
                    stroke_width: bar.border_width,
                });
                regs.push(pill);
            }
        }
        for (slot, &(w, label_w)) in end_slots.iter().zip(&end_metrics) {
            let slot_rect = Rect::new(slot_x, pad, w, cell_h);
            render_slot_slice(&mut commands, &mut hit_targets, slot, slot_rect, label_w);
            slot_x += w + spacing;
        }
    }

    let surface_prefix = format!("{}|", bar.surface_id);
    let peek_animating = peek_springs
        .iter()
        .any(|(k, s)| k.starts_with(&surface_prefix) && !s.is_settled());
    let animating = ws_spring.is_some_and(|s| !s.is_settled())
        || ghost_spring.is_some_and(|s| !s.is_settled())
        || peek_animating;

    SurfaceSpec {
        id: bar.surface_id.clone(),
        namespace: bar.namespace.clone(),
        output: Some(output.name.clone()),
        layer: Layer::Top,
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
        corner_radius: if is_ghost || click_through_sections {
            0.0
        } else {
            bar.corner_radius
        },
        background: if is_ghost || click_through_sections {
            Color::TRANSPARENT
        } else {
            bg
        },
        border_color: if is_ghost || click_through_sections {
            Color::TRANSPARENT
        } else {
            border_color
        },
        border_width: if is_ghost || click_through_sections {
            0.0
        } else {
            bar.border_width
        },
        commands,
        hit_targets,
        animating,
        input_regions,
        ime_cursor_rect: None,
        track_pointer_motion: has_peek || state.fullscreen_outputs.contains(&output.name),
    }
}

/// Minimal split-corner top bar paired with Dynamic Island in the `island` preset.
fn build_island_bar_surface(
    state: &AppState,
    output: &OutputInfo,
    bar: &EffectiveBar,
) -> SurfaceSpec {
    let colors = state.palette.for_mode(state.theme_mode);
    let bg = colors.surface_color().with_opacity(bar.background_opacity);
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
    let end_slots = collect_slot_visuals(state, &bar.end_slots, &output.name);

    let mut commands = Vec::new();
    let mut hit_targets = Vec::new();
    let mut input_regions = Vec::new();

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
        commands.push(PaintCmd::TabularText {
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
    for slot in &end_slots {
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
        push_widget_visual(
            &mut commands,
            slot,
            slot_rect,
            icon_rect,
            None,
            primary,
            secondary,
        );
        hit_targets.push(HitTarget {
            rect: slot_rect,
            id: slot.target_id.clone(),
        });
        sx += slot_size + spacing;
    }

    SurfaceSpec {
        id: bar.surface_id.clone(),
        namespace: bar.namespace.clone(),
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
        track_pointer_motion: false,
    }
}

/// Slim 30px top text-only typographic bar (`swiss` preset).
fn build_swiss_bar_surface(
    state: &AppState,
    output: &OutputInfo,
    bar: &EffectiveBar,
) -> SurfaceSpec {
    let colors = state.palette.for_mode(state.theme_mode);
    let bg = colors.surface_color().with_opacity(bar.background_opacity);
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

    commands.push(PaintCmd::Line {
        x1: 0.0,
        y1: bh - 0.5,
        x2: bw,
        y2: bh - 0.5,
        color: hairline,
        width: 1.0,
    });

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
        commands.push(PaintCmd::TabularText {
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

    let clock_w = 96.0f32;
    let clock_rect = Rect::new((bw - clock_w) * 0.5, 0.0, clock_w, bh - 1.0);
    commands.push(PaintCmd::TabularText {
        rect: clock_rect,
        text: state.clock.format_hh_mm(),
        color: on_surface,
        size: 12.5,
        bold: true,
        align: TextAlign::Center,
    });

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
        id: bar.surface_id.clone(),
        namespace: bar.namespace.clone(),
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
        track_pointer_motion: false,
    }
}

fn build_win_menu_surface(
    state: &AppState,
    output: &OutputInfo,
    menu: &WinMenuState,
) -> SurfaceSpec {
    let colors = state.palette.for_mode(state.theme_mode);
    let bg = colors.surface_color().with_opacity(0.96);
    let border = colors.outline_variant_color();
    let on_surface = colors.on_surface_color();
    let primary = colors.primary_color();
    let error = colors.error_color();
    let hover = colors.surface_container_color();

    let w = 176u32;
    let items = [
        (
            "winmenu:fullscreen",
            if menu.fullscreen {
                "Exit Fullscreen"
            } else {
                "Fullscreen"
            },
            on_surface,
        ),
        (
            "winmenu:float",
            if menu.floating { "Tile" } else { "Float" },
            on_surface,
        ),
        ("winmenu:pin", "Toggle Pin", primary),
        ("winmenu:close", "Close Window", error),
    ];
    let row_h = 28.0f32;
    let h = 12 + (items.len() as u32) * 28;
    let mut commands = Vec::new();
    let mut hit_targets = Vec::new();
    for (idx, (id, label, col)) in items.iter().enumerate() {
        let rect = Rect::new(6.0, 6.0 + idx as f32 * row_h, w as f32 - 12.0, row_h - 2.0);
        commands.push(PaintCmd::RoundedRect {
            rect,
            radius: 6.0,
            fill: Some(hover),
            stroke: None,
            stroke_width: 0.0,
        });
        commands.push(PaintCmd::Text {
            rect: Rect::new(rect.x + 8.0, rect.y, rect.w - 16.0, rect.h),
            text: (*label).to_string(),
            color: *col,
            size: 12.0,
            bold: false,
            align: TextAlign::Left,
        });
        hit_targets.push(HitTarget {
            rect,
            id: (*id).to_string(),
        });
    }

    let (anchor, margin) = match menu.bar_position {
        BarPosition::Left => (
            Anchor::TOP | Anchor::LEFT,
            EdgeInsets {
                top: 56,
                left: 56,
                ..EdgeInsets::default()
            },
        ),
        BarPosition::Right => (
            Anchor::TOP | Anchor::RIGHT,
            EdgeInsets {
                top: 56,
                right: 56,
                ..EdgeInsets::default()
            },
        ),
        BarPosition::Bottom => (
            Anchor::BOTTOM | Anchor::LEFT,
            EdgeInsets {
                bottom: 56,
                left: 56,
                ..EdgeInsets::default()
            },
        ),
        BarPosition::Top => (
            Anchor::TOP | Anchor::LEFT,
            EdgeInsets {
                top: 56,
                left: 56,
                ..EdgeInsets::default()
            },
        ),
    };

    SurfaceSpec {
        id: "bar:winmenu".to_string(),
        namespace: "kaze-bar-menu".to_string(),
        output: Some(output.name.clone()),
        layer: Layer::Overlay,
        keyboard_interactivity: KeyboardMode::None,
        anchor,
        exclusive_zone: 0,
        width: w,
        height: h,
        margin,
        corner_radius: 10.0,
        background: bg,
        border_color: border,
        border_width: 1.0,
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
    use kaze_core::{BarInstanceConfig, Config, OutputInfo, WidgetInstanceConfig, WindowGeometry};

    fn virtual_out(name: &str) -> OutputInfo {
        OutputInfo {
            name: name.into(),
            width: 1920,
            height: 1080,
            scale: 1,
            ..OutputInfo::default()
        }
    }

    #[test]
    fn bar_hide_and_show_targets_exact_output_and_excludes_kaze_share() {
        let mut state = AppState::new(Config::default());
        state
            .outputs
            .insert("Virtual-1".into(), virtual_out("Virtual-1"));
        state
            .outputs
            .insert("HDMI-A-1".into(), virtual_out("HDMI-A-1"));
        state
            .outputs
            .insert("kaze-share".into(), virtual_out("kaze-share"));

        let mut ext = BarExtension::new();
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_init(&mut ctx);
        }
        // kaze-share is excluded automatically.
        assert_eq!(ext.surfaces().len(), 2);
        assert!(ext
            .surfaces()
            .iter()
            .all(|s| s.namespace != "kaze-bar-kaze-share"));

        {
            let mut ctx = ShellContext::new(&mut state);
            let res = ext.on_ipc("bar-hide", &["HDMI-A-1".into()], &mut ctx);
            assert!(matches!(res, IpcResult::Handled { ok: true, .. }));
        }
        let specs = ext.surfaces();
        assert_eq!(specs.len(), 1);
        assert_eq!(specs[0].namespace, "kaze-bar-Virtual-1");

        {
            let mut ctx = ShellContext::new(&mut state);
            let res = ext.on_ipc("bar-show", &["HDMI-A-1".into()], &mut ctx);
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

        // Middle-click jumps to settings for widget instance
        ctx.actions.clear();
        ext.on_event(
            &SystemEvent::PointerClick {
                surface_id: "bar:Virtual-1".into(),
                target_id: "widget:clock-utc".into(),
                button: PointerButton::Middle,
            },
            &mut ctx,
        );
        assert_eq!(
            ctx.actions,
            vec![ShellAction::SettingsOpen("widget:clock-utc".into())]
        );
    }

    #[test]
    fn multi_bar_and_click_through_section_mode_and_layer_auto() {
        let mut cfg = Config::default();
        cfg.bar.bars = vec![
            BarInstanceConfig {
                id: "top-pills".into(),
                position: BarPosition::Top,
                section_mode: "pills".into(),
                start_slots: vec!["launcher".into()],
                center_slots: vec!["clock-utc".into()],
                end_slots: vec!["keyboard_layout".into(), "cc".into()],
                ..BarInstanceConfig::default()
            },
            BarInstanceConfig {
                id: "bottom-bar".into(),
                position: BarPosition::Bottom,
                end_slots: vec!["notifications".into()],
                ..BarInstanceConfig::default()
            },
        ];
        cfg.bar
            .keyboard_aliases
            .insert("bamboo".into(), "VI".into());
        cfg.widget.insert(
            "clock-utc".into(),
            WidgetInstanceConfig {
                widget_type: "clock".into(),
                timezone: "UTC".into(),
                ..WidgetInstanceConfig::default()
            },
        );

        let mut state = AppState::new(cfg);
        state.outputs.insert("DP-1".into(), virtual_out("DP-1"));
        state.keyboard.layout_raw = "bamboo".into();
        state.keyboard.layout_label = "VI".into();

        let mut ext = BarExtension::new();
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_init(&mut ctx);
        }
        let specs = ext.surfaces();
        assert_eq!(specs.len(), 2);
        let top = specs
            .iter()
            .find(|s| s.id == "bar:top-pills:DP-1")
            .expect("top bar");
        let regs = top
            .input_regions
            .as_ref()
            .expect("pills mode exposes click-through regions");
        assert_eq!(regs.len(), 3);
        assert!(!regs.iter().any(|r| r.contains(500.0, 20.0)));
        assert_eq!(top.layer, Layer::Top);

        // TabularText used for clock widget
        assert!(top
            .commands
            .iter()
            .any(|c| matches!(c, PaintCmd::TabularText { .. })));

        // Keyboard alias "VI" appears
        assert!(top
            .commands
            .iter()
            .any(|c| matches!(c, PaintCmd::Text { text, .. } if text == "VI")));

        // Fullscreen + pointer enter elevates layer = "auto" to Overlay
        state.fullscreen_outputs.insert("DP-1".into());
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_event(
                &SystemEvent::PointerEnter {
                    surface_id: "bar:top-pills:DP-1".into(),
                    x: 10.0,
                    y: 10.0,
                },
                &mut ctx,
            );
        }
        let top_after = ext
            .surfaces()
            .into_iter()
            .find(|s| s.id == "bar:top-pills:DP-1")
            .expect("top bar overlay");
        assert_eq!(top_after.layer, Layer::Overlay);
    }

    #[test]
    fn visualizer_and_sysmon_dormant_on_hide() {
        let mut cfg = Config::default();
        cfg.bar.position = BarPosition::Top;
        cfg.bar.end_slots = vec!["audio_visualizer".into(), "sysmon".into()];
        let mut state = AppState::new(cfg);
        state.outputs.insert("DP-1".into(), virtual_out("DP-1"));

        let mut ext = BarExtension::new();
        let mut ctx = ShellContext::new(&mut state);
        ext.on_init(&mut ctx);
        assert!(ctx.actions.contains(&ShellAction::SetSpectrumSubscriber {
            owner: "bar".into(),
            active: true,
        }));
        assert!(ctx.actions.contains(&ShellAction::SetSysmonSubscriber {
            owner: "bar".into(),
            active: true,
        }));

        ctx.actions.clear();
        ext.on_ipc("bar-hide", &[], &mut ctx);
        assert!(ctx.actions.contains(&ShellAction::SetSpectrumSubscriber {
            owner: "bar".into(),
            active: false,
        }));
        assert!(ctx.actions.contains(&ShellAction::SetSysmonSubscriber {
            owner: "bar".into(),
            active: false,
        }));
    }

    #[test]
    fn active_window_right_click_opens_window_menu() {
        let mut cfg = Config::default();
        cfg.bar.position = BarPosition::Top;
        cfg.bar.start_slots = vec!["active_window".into()];
        let mut state = AppState::new(cfg);
        state.outputs.insert("DP-1".into(), virtual_out("DP-1"));
        state.windows.push(WindowGeometry {
            address: "0xdead".into(),
            title: "Editor".into(),
            class: "foot".into(),
            focused: true,
            ..WindowGeometry::default()
        });
        state.active_window_address = Some("0xdead".into());

        let mut ext = BarExtension::new();
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_init(&mut ctx);
        }
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_event(
                &SystemEvent::PointerClick {
                    surface_id: "bar:DP-1".into(),
                    target_id: "active_window".into(),
                    button: PointerButton::Right,
                },
                &mut ctx,
            );
        }
        assert!(ext.surfaces().iter().any(|s| s.id == "bar:winmenu"));
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
        state
            .outputs
            .insert("Virtual-1".into(), virtual_out("Virtual-1"));

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
        state
            .outputs
            .insert("Virtual-1".into(), virtual_out("Virtual-1"));
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
        state
            .outputs
            .insert("Virtual-1".into(), virtual_out("Virtual-1"));
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
        state
            .outputs
            .insert("Virtual-1".into(), virtual_out("Virtual-1"));
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
        state
            .outputs
            .insert("Virtual-1".into(), virtual_out("Virtual-1"));
        let mut ext = BarExtension::new();
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_init(&mut ctx);
        }
        assert!(ext.surfaces().is_empty(), "ghost idle must have 0 surfaces");

        {
            let mut ctx = ShellContext::new(&mut state);
            let res = ext.on_ipc("bar-peek", &[], &mut ctx);
            assert!(matches!(res, IpcResult::Handled { ok: true, .. }));
        }
        assert_eq!(ext.surfaces().len(), 1);
        assert_eq!(ext.surfaces()[0].exclusive_zone, 0);
        assert!(ext.surfaces()[0].animating);

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

    #[test]
    fn peek_widget_expands_on_pointer_motion_and_collapses_on_leave() {
        let mut cfg = Config::default();
        cfg.bar.position = BarPosition::Top;
        cfg.bar.end_slots = vec!["clock-peek".into()];
        cfg.widget.insert(
            "clock-peek".into(),
            WidgetInstanceConfig {
                widget_type: "clock".into(),
                peek: true,
                ..WidgetInstanceConfig::default()
            },
        );
        let mut state = AppState::new(cfg);
        state.outputs.insert("DP-1".into(), virtual_out("DP-1"));

        let mut ext = BarExtension::new();
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_init(&mut ctx);
        }
        let initial_spec = ext.surfaces()[0].clone();
        assert!(initial_spec.track_pointer_motion);
        let target = initial_spec
            .hit_targets
            .iter()
            .find(|t| t.id == "widget:clock-peek")
            .expect("peek clock target");
        let collapsed_w = target.rect.w;
        let cx = target.rect.x + target.rect.w * 0.5;
        let cy = target.rect.y + target.rect.h * 0.5;

        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_event(
                &SystemEvent::PointerMotion {
                    surface_id: "bar:DP-1".into(),
                    x: cx,
                    y: cy,
                },
                &mut ctx,
            );
            for _ in 0..90 {
                if !ext.surfaces()[0].animating {
                    break;
                }
                ext.on_event(
                    &SystemEvent::FrameTick {
                        surface_id: "bar:DP-1".into(),
                        dt_secs: 1.0 / 60.0,
                    },
                    &mut ctx,
                );
            }
        }
        let expanded_w = ext.surfaces()[0]
            .hit_targets
            .iter()
            .find(|t| t.id == "widget:clock-peek")
            .expect("peek target after expand")
            .rect
            .w;
        assert!(
            expanded_w > collapsed_w + 8.0,
            "peek widget must widen on hover ({collapsed_w} -> {expanded_w})"
        );

        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_event(
                &SystemEvent::PointerLeave {
                    surface_id: "bar:DP-1".into(),
                },
                &mut ctx,
            );
            for _ in 0..90 {
                if !ext.surfaces()[0].animating {
                    break;
                }
                ext.on_event(
                    &SystemEvent::FrameTick {
                        surface_id: "bar:DP-1".into(),
                        dt_secs: 1.0 / 60.0,
                    },
                    &mut ctx,
                );
            }
        }
        let final_w = ext.surfaces()[0]
            .hit_targets
            .iter()
            .find(|t| t.id == "widget:clock-peek")
            .expect("peek target after leave")
            .rect
            .w;
        assert!((final_w - collapsed_w).abs() < 1.0);
    }
}
