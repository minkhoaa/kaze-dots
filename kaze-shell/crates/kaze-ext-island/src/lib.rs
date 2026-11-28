#![deny(clippy::unwrap_used)]

use kaze_core::{
    Anchor, AppState, Color, CustomActivity, DirtyFlags, DisplayActivity, DisplayStatus,
    EdgeInsets, HitTarget, IconKind, IpcResult, IslandStyle, KazeExtension, KeyboardMode, Layer,
    MediaPlayback, NotificationItem, NotificationUrgency, OsdKind, PaintCmd, PointerButton,
    RecordActivity, Rect, ShellAction, ShellContext, Spring, SurfaceSpec, SystemEvent, TextAlign,
};
use std::time::{SystemTime, UNIX_EPOCH};

const SURFACE_ID: &str = "island:main";
const NAMESPACE: &str = "kaze-island";

const TIMER_OSD_EXPIRE: &str = "island:osd-expire";
const TIMER_NOTIFY_EXPIRE: &str = "island:notify-expire";
const TIMER_RECORD_TICK: &str = "island:record-tick";
const TIMER_MEDIA_TICK: &str = "island:media-tick";
const TIMER_AUTO_COLLAPSE: &str = "island:auto-collapse";

const ANIM_CANVAS_W: u32 = 448;
const ANIM_CANVAS_H: u32 = 216;
const NOTCH_FLARE: f32 = 12.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum IslandMode {
    Collapsed,
    Compact,
    Expanded,
    AbsorbedOsd,
    AbsorbedNotify,
}

/// Dynamic Island (`kaze-island`) with spring-morphing states (`Collapsed`, `Compact`, `Expanded`),
/// `floating` pill and `notch` concave-ear geometry, and native Kaze Live Activities
/// (MPRIS media, `kaze-display` share/present, `kaze-record` timer, absorbed OSD/notifications).
pub struct IslandExtension {
    expanded: bool,
    force_visible: bool,
    absorbed_osd: Option<OsdKind>,
    absorbed_notify: Option<NotificationItem>,
    width_spring: Spring,
    height_spring: Spring,
    radius_spring: Spring,
    record_timer_armed: bool,
    media_timer_armed: bool,
    cached_spec: Option<SurfaceSpec>,
}

impl Default for IslandExtension {
    fn default() -> Self {
        Self::new()
    }
}

impl IslandExtension {
    pub fn new() -> Self {
        Self {
            expanded: false,
            force_visible: false,
            absorbed_osd: None,
            absorbed_notify: None,
            width_spring: Spring::smooth(196.0),
            height_spring: Spring::smooth(34.0),
            radius_spring: Spring::smooth(18.0),
            record_timer_armed: false,
            media_timer_armed: false,
            cached_spec: None,
        }
    }

    fn has_live_activity(state: &AppState) -> bool {
        state.record_activity.as_ref().is_some_and(|r| r.active)
            || state.display_activity.is_some()
            || state.display_status.is_active()
            || state.media.active
            || !state.custom_activities.is_empty()
    }

    fn is_visible(&self, state: &AppState) -> bool {
        if state.island_always_visible() {
            return true;
        }
        self.force_visible
            || self.expanded
            || self.absorbed_osd.is_some()
            || self.absorbed_notify.is_some()
            || Self::has_live_activity(state)
    }

    fn visual_mode(&self, state: &AppState) -> IslandMode {
        if self.expanded {
            IslandMode::Expanded
        } else if self.absorbed_osd.is_some() {
            IslandMode::AbsorbedOsd
        } else if self.absorbed_notify.is_some() {
            IslandMode::AbsorbedNotify
        } else if Self::has_live_activity(state) {
            IslandMode::Compact
        } else {
            IslandMode::Collapsed
        }
    }

    fn target_geometry(state: &AppState, mode: IslandMode) -> (f32, f32, f32) {
        let base_r = state.config.island.corner_radius.clamp(16.0, 22.0);
        match mode {
            IslandMode::Collapsed => (196.0, 34.0, base_r.min(17.0)),
            IslandMode::Compact => (320.0, 38.0, base_r.min(19.0)),
            IslandMode::AbsorbedOsd => (296.0, 52.0, base_r.min(20.0)),
            IslandMode::AbsorbedNotify => (384.0, 96.0, base_r),
            IslandMode::Expanded => {
                let mut h = 92.0f32;
                if state.record_activity.as_ref().is_some_and(|r| r.active) {
                    h += 42.0;
                }
                if state.display_activity.is_some() || state.display_status.is_active() {
                    h += 50.0;
                }
                if state.media.active {
                    h += 68.0;
                }
                if !state.custom_activities.is_empty() {
                    h += 40.0;
                }
                (420.0, h.clamp(112.0, 208.0), base_r)
            }
        }
    }

    fn is_animating(&self) -> bool {
        !self.width_spring.is_settled()
            || !self.height_spring.is_settled()
            || !self.radius_spring.is_settled()
    }

    fn update_spring_targets(&mut self, state: &AppState, snap: bool) {
        let mode = self.visual_mode(state);
        let (tw, th, tr) = Self::target_geometry(state, mode);
        if snap {
            self.width_spring.snap(tw);
            self.height_spring.snap(th);
            self.radius_spring.snap(tr);
        } else {
            self.width_spring.set_target(tw);
            self.height_spring.set_target(th);
            self.radius_spring.set_target(tr);
        }
    }

    fn sync_timers(&mut self, ctx: &mut ShellContext) {
        let rec_active = ctx.state.record_activity.as_ref().is_some_and(|r| r.active);
        if rec_active && !self.record_timer_armed {
            self.record_timer_armed = true;
            ctx.push_action(ShellAction::ScheduleTimer {
                id: TIMER_RECORD_TICK.to_string(),
                after_ms: 1000,
            });
        } else if !rec_active && self.record_timer_armed {
            self.record_timer_armed = false;
            ctx.push_action(ShellAction::CancelTimer {
                id: TIMER_RECORD_TICK.to_string(),
            });
        }

        // Interpolate media progress ONLY while Expanded and actively Playing (0 polling when collapsed).
        let need_media_tick = self.expanded
            && ctx.state.media.active
            && ctx.state.media.status == MediaPlayback::Playing;
        if need_media_tick && !self.media_timer_armed {
            self.media_timer_armed = true;
            ctx.push_action(ShellAction::ScheduleTimer {
                id: TIMER_MEDIA_TICK.to_string(),
                after_ms: 1000,
            });
        } else if !need_media_tick && self.media_timer_armed {
            self.media_timer_armed = false;
            ctx.push_action(ShellAction::CancelTimer {
                id: TIMER_MEDIA_TICK.to_string(),
            });
        }
    }

    fn sync_auto_collapse_timer(&self, ctx: &mut ShellContext) {
        let ms = ctx.state.config.island.auto_collapse_ms;
        if self.expanded && ms > 0 {
            ctx.push_action(ShellAction::ScheduleTimer {
                id: TIMER_AUTO_COLLAPSE.to_string(),
                after_ms: ms,
            });
        } else {
            ctx.push_action(ShellAction::CancelTimer {
                id: TIMER_AUTO_COLLAPSE.to_string(),
            });
        }
    }

    fn rebuild(&mut self, state: &mut AppState) {
        state.island_expanded = self.expanded;
        if !self.is_visible(state) {
            self.cached_spec = None;
            return;
        }
        let Some(target_output) = select_primary_output(state) else {
            self.cached_spec = None;
            return;
        };
        let mode = self.visual_mode(state);
        self.cached_spec = Some(build_island_surface(
            state,
            &target_output,
            mode,
            self.width_spring.value,
            self.height_spring.value,
            self.radius_spring.value,
            self.is_animating(),
            self.absorbed_osd,
            self.absorbed_notify.as_ref(),
        ));
    }

    fn collapse(&mut self, ctx: &mut ShellContext) -> DirtyFlags {
        let had_anything = self.expanded
            || self.force_visible
            || self.absorbed_osd.is_some()
            || self.absorbed_notify.is_some();
        if !had_anything {
            return DirtyFlags::NONE;
        }
        self.expanded = false;
        self.force_visible = false;
        self.absorbed_osd = None;
        self.absorbed_notify = None;
        ctx.push_action(ShellAction::CancelTimer {
            id: TIMER_OSD_EXPIRE.to_string(),
        });
        ctx.push_action(ShellAction::CancelTimer {
            id: TIMER_NOTIFY_EXPIRE.to_string(),
        });
        ctx.push_action(ShellAction::CancelTimer {
            id: TIMER_AUTO_COLLAPSE.to_string(),
        });
        self.sync_timers(ctx);
        self.sync_auto_collapse_timer(ctx);
        let snap = !self.is_visible(ctx.state);
        self.update_spring_targets(ctx.state, snap);
        self.rebuild(ctx.state);
        DirtyFlags::ISLAND | DirtyFlags::LAYOUT
    }

    fn handle_activity_ipc(&mut self, args: &[String], ctx: &mut ShellContext) -> IpcResult {
        let Some(id) = args.first().map(String::as_str) else {
            return IpcResult::Handled {
                ok: false,
                message: "usage: island-activity <id> <json>".into(),
                dirty: DirtyFlags::NONE,
            };
        };
        let raw_json = args.get(1).map(String::as_str).unwrap_or("{}");
        let parsed: serde_json::Value = match serde_json::from_str(raw_json) {
            Ok(v) => v,
            Err(err) => {
                return IpcResult::Handled {
                    ok: false,
                    message: format!("invalid activity JSON: {err}"),
                    dirty: DirtyFlags::NONE,
                };
            }
        };

        match id {
            "display" => {
                let mode = parsed
                    .get("mode")
                    .and_then(|v| v.as_str())
                    .unwrap_or("virtual-share")
                    .to_string();
                if matches!(mode.as_str(), "idle" | "off" | "none" | "") {
                    ctx.state.display_activity = None;
                    ctx.state.display_status = DisplayStatus::Idle;
                } else {
                    let ws = parsed
                        .get("ws")
                        .and_then(|v| v.as_i64())
                        .and_then(|n| i32::try_from(n).ok());
                    let control = parsed
                        .get("control")
                        .and_then(|v| v.as_bool())
                        .unwrap_or(false);
                    let output = parsed
                        .get("output")
                        .and_then(|v| v.as_str())
                        .map(str::to_string);
                    let detail = ws.map(|w| format!("WS {w}")).unwrap_or_default();
                    ctx.state.display_status = match mode.as_str() {
                        "present" | "live" => DisplayStatus::Present { detail },
                        "virtual-control" | "control" => DisplayStatus::VirtualControl { detail },
                        _ => DisplayStatus::VirtualShare { detail },
                    };
                    ctx.state.display_activity = Some(DisplayActivity {
                        mode,
                        ws,
                        control,
                        output,
                    });
                }
            }
            "record" => {
                let active = parsed
                    .get("active")
                    .and_then(|v| v.as_bool())
                    .unwrap_or(true);
                if !active {
                    ctx.state.record_activity = None;
                } else {
                    let now_secs = now_epoch_secs();
                    let started_at = parsed
                        .get("started_at")
                        .and_then(|v| v.as_u64())
                        .filter(|&t| t > 0)
                        .unwrap_or(now_secs);
                    let audio = parsed
                        .get("audio")
                        .and_then(|v| v.as_bool())
                        .unwrap_or(false);
                    let gif = parsed.get("gif").and_then(|v| v.as_bool()).unwrap_or(false);
                    ctx.state.record_activity = Some(RecordActivity {
                        active: true,
                        started_at,
                        audio,
                        gif,
                    });
                }
            }
            custom_id => {
                let active = parsed
                    .get("active")
                    .and_then(|v| v.as_bool())
                    .unwrap_or(true);
                if !active {
                    ctx.state.custom_activities.remove(custom_id);
                } else {
                    let badge = parsed
                        .get("badge")
                        .and_then(|v| v.as_str())
                        .unwrap_or("LIVE")
                        .to_string();
                    let title = parsed
                        .get("title")
                        .and_then(|v| v.as_str())
                        .unwrap_or(custom_id)
                        .to_string();
                    let subtitle = parsed
                        .get("subtitle")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string();
                    ctx.state.custom_activities.insert(
                        custom_id.to_string(),
                        CustomActivity {
                            id: custom_id.to_string(),
                            badge,
                            title,
                            subtitle,
                        },
                    );
                }
            }
        }

        if self.expanded && !Self::has_live_activity(ctx.state) {
            self.expanded = false;
            self.force_visible = false;
        }
        let was_visible = self.cached_spec.is_some();
        self.sync_timers(ctx);
        self.sync_auto_collapse_timer(ctx);
        self.update_spring_targets(ctx.state, !was_visible);
        self.rebuild(ctx.state);
        IpcResult::Handled {
            ok: true,
            message: format!("activity '{id}' updated"),
            dirty: DirtyFlags::ISLAND | DirtyFlags::BAR | DirtyFlags::LAYOUT,
        }
    }

    fn handle_clear_ipc(&mut self, args: &[String], ctx: &mut ShellContext) -> IpcResult {
        let Some(id) = args.first().map(String::as_str) else {
            return IpcResult::Handled {
                ok: false,
                message: "usage: island-clear <id|all>".into(),
                dirty: DirtyFlags::NONE,
            };
        };
        match id {
            "all" => {
                ctx.state.display_activity = None;
                ctx.state.record_activity = None;
                ctx.state.custom_activities.clear();
                ctx.state.display_status = DisplayStatus::Idle;
                self.absorbed_osd = None;
                self.absorbed_notify = None;
                self.expanded = false;
                self.force_visible = false;
            }
            "display" => {
                ctx.state.display_activity = None;
                ctx.state.display_status = DisplayStatus::Idle;
            }
            "record" => {
                ctx.state.record_activity = None;
            }
            other => {
                ctx.state.custom_activities.remove(other);
            }
        }
        if self.expanded && !Self::has_live_activity(ctx.state) {
            self.expanded = false;
            self.force_visible = false;
        }
        self.sync_timers(ctx);
        self.sync_auto_collapse_timer(ctx);
        let snap = !self.is_visible(ctx.state);
        self.update_spring_targets(ctx.state, snap);
        self.rebuild(ctx.state);
        IpcResult::Handled {
            ok: true,
            message: format!("cleared '{id}'"),
            dirty: DirtyFlags::ISLAND | DirtyFlags::BAR | DirtyFlags::LAYOUT,
        }
    }

    fn handle_click(
        &mut self,
        target_id: &str,
        button: PointerButton,
        ctx: &mut ShellContext,
    ) -> DirtyFlags {
        if button == PointerButton::Right {
            return self.collapse(ctx);
        }
        if button != PointerButton::Left {
            return DirtyFlags::NONE;
        }
        match target_id {
            "island:pill" => {
                self.expanded = !self.expanded;
                if self.expanded {
                    self.absorbed_osd = None;
                    self.absorbed_notify = None;
                }
                self.sync_timers(ctx);
                self.sync_auto_collapse_timer(ctx);
                self.update_spring_targets(ctx.state, false);
                self.rebuild(ctx.state);
                DirtyFlags::ISLAND | DirtyFlags::LAYOUT
            }
            "island:collapse" => self.collapse(ctx),
            "island:media:prev" => {
                self.sync_auto_collapse_timer(ctx);
                ctx.push_action(ShellAction::MediaCommand("prev".into()));
                DirtyFlags::NONE
            }
            "island:media:play" => {
                self.sync_auto_collapse_timer(ctx);
                ctx.push_action(ShellAction::MediaCommand("play-pause".into()));
                DirtyFlags::NONE
            }
            "island:media:next" => {
                self.sync_auto_collapse_timer(ctx);
                ctx.push_action(ShellAction::MediaCommand("next".into()));
                DirtyFlags::NONE
            }
            "island:display:preview" => {
                self.sync_auto_collapse_timer(ctx);
                ctx.push_action(ShellAction::SpawnCommand {
                    program: "kaze-display".into(),
                    args: vec!["toggle-preview".into()],
                });
                DirtyFlags::NONE
            }
            "island:display:control" => {
                self.sync_auto_collapse_timer(ctx);
                ctx.push_action(ShellAction::SpawnCommand {
                    program: "kaze-display".into(),
                    args: vec!["toggle-control".into()],
                });
                DirtyFlags::NONE
            }
            "island:display:stop" => {
                let is_present = ctx
                    .state
                    .display_activity
                    .as_ref()
                    .is_some_and(|d| d.mode == "present")
                    || matches!(ctx.state.display_status, DisplayStatus::Present { .. });
                ctx.push_action(ShellAction::SpawnCommand {
                    program: "kaze-display".into(),
                    args: vec![if is_present {
                        "stop-present".into()
                    } else {
                        "stop-virtual".into()
                    }],
                });
                DirtyFlags::NONE
            }
            "island:record:stop" => {
                ctx.push_action(ShellAction::SpawnCommand {
                    program: "kaze-record".into(),
                    args: vec!["stop".into()],
                });
                DirtyFlags::NONE
            }
            "island:notify:dismiss" => {
                self.absorbed_notify = None;
                ctx.push_action(ShellAction::CancelTimer {
                    id: TIMER_NOTIFY_EXPIRE.to_string(),
                });
                self.update_spring_targets(ctx.state, false);
                self.rebuild(ctx.state);
                DirtyFlags::ISLAND | DirtyFlags::LAYOUT
            }
            _ => DirtyFlags::NONE,
        }
    }
}

impl KazeExtension for IslandExtension {
    fn id(&self) -> &'static str {
        "island"
    }

    fn on_init(&mut self, ctx: &mut ShellContext) {
        self.update_spring_targets(ctx.state, true);
        self.rebuild(ctx.state);
    }

    fn on_event(&mut self, event: &SystemEvent, ctx: &mut ShellContext) -> DirtyFlags {
        match event {
            SystemEvent::FrameTick {
                surface_id,
                dt_secs,
            } if surface_id == SURFACE_ID => {
                let mut changed = false;
                if !self.width_spring.is_settled() {
                    self.width_spring.step(*dt_secs);
                    changed = true;
                }
                if !self.height_spring.is_settled() {
                    self.height_spring.step(*dt_secs);
                    changed = true;
                }
                if !self.radius_spring.is_settled() {
                    self.radius_spring.step(*dt_secs);
                    changed = true;
                }
                if changed {
                    self.rebuild(ctx.state);
                    DirtyFlags::ISLAND
                } else {
                    DirtyFlags::NONE
                }
            }
            SystemEvent::LayoutPresetChanged(_)
            | SystemEvent::OutputAdded(_)
            | SystemEvent::OutputUpdated(_)
            | SystemEvent::OutputRemoved { .. }
            | SystemEvent::ConfigReloaded
            | SystemEvent::ThemeChanged(_) => {
                if !ctx.state.island_always_visible() && !Self::has_live_activity(ctx.state) {
                    self.expanded = false;
                    self.force_visible = false;
                    self.absorbed_osd = None;
                    self.absorbed_notify = None;
                }
                self.sync_timers(ctx);
                self.update_spring_targets(ctx.state, true);
                self.rebuild(ctx.state);
                DirtyFlags::ISLAND | DirtyFlags::LAYOUT
            }
            SystemEvent::ClockTick(_)
            | SystemEvent::HyprSynced { .. }
            | SystemEvent::HyprWorkspaceChanged { .. }
            | SystemEvent::HyprFocusedMonitor { .. }
            | SystemEvent::DndChanged(_)
            | SystemEvent::NotificationsCountChanged(_) => {
                if self.is_visible(ctx.state) {
                    self.rebuild(ctx.state);
                    DirtyFlags::ISLAND
                } else {
                    DirtyFlags::NONE
                }
            }
            SystemEvent::MediaChanged(_) => {
                if self.expanded && !Self::has_live_activity(ctx.state) {
                    self.expanded = false;
                    self.force_visible = false;
                    self.sync_auto_collapse_timer(ctx);
                }
                let was_visible = self.cached_spec.is_some();
                self.sync_timers(ctx);
                self.update_spring_targets(ctx.state, !was_visible);
                self.rebuild(ctx.state);
                DirtyFlags::ISLAND | DirtyFlags::LAYOUT
            }
            SystemEvent::AudioChanged {
                trigger_osd: Some(kind),
                ..
            } if ctx.state.island_absorbs_osd() => {
                self.absorbed_osd = Some(*kind);
                ctx.push_action(ShellAction::ScheduleTimer {
                    id: TIMER_OSD_EXPIRE.to_string(),
                    after_ms: ctx.state.config.osd.timeout_ms.max(400),
                });
                self.update_spring_targets(ctx.state, false);
                self.rebuild(ctx.state);
                DirtyFlags::ISLAND | DirtyFlags::LAYOUT
            }
            SystemEvent::BacklightChanged {
                trigger_osd: true, ..
            } if ctx.state.island_absorbs_osd() => {
                self.absorbed_osd = Some(OsdKind::Brightness);
                ctx.push_action(ShellAction::ScheduleTimer {
                    id: TIMER_OSD_EXPIRE.to_string(),
                    after_ms: ctx.state.config.osd.timeout_ms.max(400),
                });
                self.update_spring_targets(ctx.state, false);
                self.rebuild(ctx.state);
                DirtyFlags::ISLAND | DirtyFlags::LAYOUT
            }
            SystemEvent::NotificationReceived(item)
                if ctx.state.island_absorbs_notify()
                    && !ctx.state.dnd
                    && item.urgency != NotificationUrgency::Critical =>
            {
                let timeout_ms = if item.expire_timeout_ms > 0 {
                    (item.expire_timeout_ms as u64).max(500)
                } else {
                    match item.urgency {
                        NotificationUrgency::Low => ctx.state.config.notifications.low_timeout_ms,
                        _ => ctx.state.config.notifications.default_timeout_ms,
                    }
                    .max(1000)
                };
                self.absorbed_notify = Some(item.clone());
                ctx.push_action(ShellAction::ScheduleTimer {
                    id: TIMER_NOTIFY_EXPIRE.to_string(),
                    after_ms: timeout_ms,
                });
                self.update_spring_targets(ctx.state, false);
                self.rebuild(ctx.state);
                DirtyFlags::ISLAND | DirtyFlags::LAYOUT
            }
            SystemEvent::NotificationClearAll => {
                if self.absorbed_notify.take().is_some() {
                    ctx.push_action(ShellAction::CancelTimer {
                        id: TIMER_NOTIFY_EXPIRE.to_string(),
                    });
                    self.update_spring_targets(ctx.state, false);
                    self.rebuild(ctx.state);
                    DirtyFlags::ISLAND | DirtyFlags::LAYOUT
                } else {
                    DirtyFlags::NONE
                }
            }
            SystemEvent::TimerFired { id } => match id.as_str() {
                TIMER_OSD_EXPIRE => {
                    if self.absorbed_osd.take().is_some() {
                        self.update_spring_targets(ctx.state, false);
                        self.rebuild(ctx.state);
                        DirtyFlags::ISLAND | DirtyFlags::LAYOUT
                    } else {
                        DirtyFlags::NONE
                    }
                }
                TIMER_NOTIFY_EXPIRE => {
                    if self.absorbed_notify.take().is_some() {
                        self.update_spring_targets(ctx.state, false);
                        self.rebuild(ctx.state);
                        DirtyFlags::ISLAND | DirtyFlags::LAYOUT
                    } else {
                        DirtyFlags::NONE
                    }
                }
                TIMER_RECORD_TICK => {
                    if ctx.state.record_activity.as_ref().is_some_and(|r| r.active) {
                        ctx.push_action(ShellAction::ScheduleTimer {
                            id: TIMER_RECORD_TICK.to_string(),
                            after_ms: 1000,
                        });
                        self.rebuild(ctx.state);
                        DirtyFlags::ISLAND
                    } else {
                        self.record_timer_armed = false;
                        DirtyFlags::NONE
                    }
                }
                TIMER_MEDIA_TICK => {
                    if self.expanded
                        && ctx.state.media.active
                        && ctx.state.media.status == MediaPlayback::Playing
                    {
                        ctx.push_action(ShellAction::ScheduleTimer {
                            id: TIMER_MEDIA_TICK.to_string(),
                            after_ms: 1000,
                        });
                        self.rebuild(ctx.state);
                        DirtyFlags::ISLAND
                    } else {
                        self.media_timer_armed = false;
                        DirtyFlags::NONE
                    }
                }
                TIMER_AUTO_COLLAPSE => self.collapse(ctx),
                _ => DirtyFlags::NONE,
            },
            SystemEvent::PointerClick {
                surface_id,
                target_id,
                button,
            } if surface_id == SURFACE_ID => self.handle_click(target_id, *button, ctx),
            SystemEvent::SurfaceClosed { surface_id }
            | SystemEvent::KeyboardFocusLost { surface_id }
                if surface_id == SURFACE_ID && self.expanded =>
            {
                self.collapse(ctx)
            }
            _ => DirtyFlags::NONE,
        }
    }

    fn on_ipc(&mut self, cmd: &str, args: &[String], ctx: &mut ShellContext) -> IpcResult {
        match cmd {
            "island-toggle" => {
                let was_visible = self.cached_spec.is_some();
                if self.expanded {
                    self.expanded = false;
                    self.force_visible = false;
                } else {
                    self.expanded = true;
                    self.force_visible = true;
                    self.absorbed_osd = None;
                    self.absorbed_notify = None;
                }
                self.sync_timers(ctx);
                ctx.push_action(ShellAction::CancelTimer {
                    id: TIMER_AUTO_COLLAPSE.to_string(),
                });
                let snap = !was_visible && !self.is_visible(ctx.state);
                self.update_spring_targets(ctx.state, snap);
                self.rebuild(ctx.state);
                IpcResult::Handled {
                    ok: true,
                    message: if self.expanded {
                        "expanded".into()
                    } else {
                        "collapsed".into()
                    },
                    dirty: DirtyFlags::ISLAND | DirtyFlags::LAYOUT,
                }
            }
            "island-activity" => self.handle_activity_ipc(args, ctx),
            "island-clear" => self.handle_clear_ipc(args, ctx),
            "island-style" => {
                let Some(raw) = args.first().map(String::as_str) else {
                    return IpcResult::Handled {
                        ok: true,
                        message: ctx.state.config.island.style.as_str().into(),
                        dirty: DirtyFlags::NONE,
                    };
                };
                match IslandStyle::from_name(raw) {
                    Some(style) => {
                        ctx.state.config.island.style = style;
                        self.rebuild(ctx.state);
                        IpcResult::Handled {
                            ok: true,
                            message: style.as_str().into(),
                            dirty: DirtyFlags::ISLAND | DirtyFlags::LAYOUT,
                        }
                    }
                    None => IpcResult::Handled {
                        ok: false,
                        message: format!("unknown island-style '{raw}' (expected floating|notch)"),
                        dirty: DirtyFlags::NONE,
                    },
                }
            }
            _ => IpcResult::Unhandled,
        }
    }

    fn surfaces(&self) -> Vec<SurfaceSpec> {
        self.cached_spec.clone().into_iter().collect()
    }
}

/// Selects the primary non-virtual, non-presenting output for Dynamic Island.
/// Guarantees `kaze-share` and outputs actively running `present` never show an Island overlay.
fn select_primary_output(state: &AppState) -> Option<String> {
    let presenting_output = state
        .display_activity
        .as_ref()
        .filter(|d| d.mode == "present")
        .and_then(|d| d.output.as_deref());

    let is_eligible = |name: &str| -> bool {
        if name == "kaze-share" {
            return false;
        }
        if presenting_output == Some(name) {
            return false;
        }
        if state.hidden_bars.contains(name)
            && matches!(state.display_status, DisplayStatus::Present { .. })
        {
            return false;
        }
        true
    };

    if let Some(ref focused) = state.focused_monitor {
        if state.outputs.contains_key(focused) && is_eligible(focused) {
            return Some(focused.clone());
        }
    }
    state.outputs.keys().find(|name| is_eligible(name)).cloned()
}

fn now_epoch_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn now_epoch_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

fn ellipsize(text: &str, max_chars: usize) -> String {
    let count = text.chars().count();
    if count <= max_chars || max_chars < 4 {
        text.to_string()
    } else {
        let mut out: String = text.chars().take(max_chars - 1).collect();
        out.push('…');
        out
    }
}

fn format_mm_ss(total_secs: u64) -> String {
    let mins = total_secs / 60;
    let secs = total_secs % 60;
    format!("{mins:02}:{secs:02}")
}

#[allow(clippy::too_many_arguments)]
fn build_island_surface(
    state: &AppState,
    output_name: &str,
    mode: IslandMode,
    cur_w: f32,
    cur_h: f32,
    cur_r: f32,
    animating: bool,
    absorbed_osd: Option<OsdKind>,
    absorbed_notify: Option<&NotificationItem>,
) -> SurfaceSpec {
    let colors = state.palette.for_mode(state.theme_mode);
    let bg = colors
        .surface_color()
        .with_opacity(state.config.bar.background_opacity.max(0.95));
    let border_col = colors.outline_variant_color();
    let primary = colors.primary_color();
    let on_primary = colors.on_primary_color();
    let secondary = colors.secondary_color();
    let tertiary = colors.tertiary_color();
    let error_col = colors.error_color();
    let on_surface = colors.on_surface_color();
    let muted = colors.on_surface_variant_color();
    let surface_container = colors.surface_container_color();
    let surface_variant = colors.surface_variant_color();

    let is_notch = state.config.island.style == IslandStyle::Notch;
    let ear_extra = if is_notch { NOTCH_FLARE * 2.0 } else { 0.0 };
    let pill_w = (cur_w + ear_extra).clamp(160.0, ANIM_CANVAS_W as f32);
    let pill_h = cur_h.clamp(32.0, ANIM_CANVAS_H as f32);

    // Keep a fixed transparent canvas while animating (0 configure round-trips at 60-144Hz),
    // then snap tightly to exact pill dimensions when settled.
    let (surf_w, surf_h, pill_x) = if animating {
        let sw = ANIM_CANVAS_W.max(pill_w.ceil() as u32);
        let sh = ANIM_CANVAS_H.max(pill_h.ceil() as u32);
        (sw, sh, ((sw as f32) - pill_w) * 0.5)
    } else {
        (pill_w.ceil() as u32, pill_h.ceil() as u32, 0.0)
    };

    let pill_rect = Rect::new(pill_x, 0.0, pill_w, pill_h);
    let inner_x = pill_x + if is_notch { NOTCH_FLARE } else { 0.0 };
    let inner_w = (pill_w - ear_extra).max(120.0);

    let mut commands = Vec::with_capacity(24);
    let mut hit_targets = Vec::with_capacity(8);

    // 1. Pill / Hardware-Notch container silhouette
    if is_notch {
        commands.push(PaintCmd::NotchPill {
            rect: pill_rect,
            bottom_radius: cur_r,
            flare_radius: NOTCH_FLARE,
            fill: bg,
            stroke: Some(border_col),
            stroke_width: 1.5,
        });
    } else {
        commands.push(PaintCmd::RoundedRect {
            rect: pill_rect,
            radius: cur_r,
            fill: Some(bg),
            stroke: Some(border_col),
            stroke_width: 1.5,
        });
    }

    let ws_id = state.active_workspace_for_output(output_name);
    let now_secs = now_epoch_secs();

    match mode {
        IslandMode::Collapsed => {
            // Left: workspace badge
            let ws_rect = Rect::new(inner_x + 8.0, (pill_h - 22.0) * 0.5, 24.0, 22.0);
            commands.push(PaintCmd::RoundedRect {
                rect: ws_rect,
                radius: 11.0,
                fill: Some(primary),
                stroke: None,
                stroke_width: 0.0,
            });
            commands.push(PaintCmd::Text {
                rect: ws_rect,
                text: ws_id.to_string(),
                color: on_primary,
                size: 11.5,
                bold: true,
                align: TextAlign::Center,
            });

            // Center: 24h clock
            commands.push(PaintCmd::Text {
                rect: Rect::new(inner_x + 36.0, 0.0, inner_w - 72.0, pill_h),
                text: state.clock.format_hh_mm(),
                color: on_surface,
                size: 13.0,
                bold: true,
                align: TextAlign::Center,
            });

            // Right: up to 2 activity indicator dots
            let mut dots = Vec::new();
            if state.record_activity.as_ref().is_some_and(|r| r.active) {
                dots.push(error_col);
            }
            if state.display_activity.is_some() || state.display_status.is_active() {
                dots.push(secondary);
            }
            if state.media.active {
                dots.push(primary);
            }
            if state.dnd {
                dots.push(tertiary);
            }
            let mut dot_x = inner_x + inner_w - 14.0;
            for col in dots.into_iter().take(2) {
                commands.push(PaintCmd::Circle {
                    cx: dot_x,
                    cy: pill_h * 0.5,
                    radius: 4.0,
                    fill: col,
                });
                dot_x -= 12.0;
            }
        }
        IslandMode::Compact => {
            let cy = pill_h * 0.5;
            if let Some(rec) = state.record_activity.as_ref().filter(|r| r.active) {
                let elapsed = now_secs.saturating_sub(rec.started_at);
                let badge = if rec.gif { "GIF" } else { "REC" };
                commands.push(PaintCmd::Circle {
                    cx: inner_x + 16.0,
                    cy,
                    radius: 4.5,
                    fill: error_col,
                });
                commands.push(PaintCmd::Text {
                    rect: Rect::new(inner_x + 26.0, 0.0, 42.0, pill_h),
                    text: badge.into(),
                    color: error_col,
                    size: 11.5,
                    bold: true,
                    align: TextAlign::Left,
                });
                commands.push(PaintCmd::Text {
                    rect: Rect::new(inner_x + 70.0, 0.0, 64.0, pill_h),
                    text: format_mm_ss(elapsed),
                    color: on_surface,
                    size: 12.5,
                    bold: true,
                    align: TextAlign::Left,
                });
                let stop_rect =
                    Rect::new(inner_x + inner_w - 64.0, (pill_h - 24.0) * 0.5, 54.0, 24.0);
                commands.push(PaintCmd::RoundedRect {
                    rect: stop_rect,
                    radius: 12.0,
                    fill: Some(error_col),
                    stroke: None,
                    stroke_width: 0.0,
                });
                commands.push(PaintCmd::Text {
                    rect: stop_rect,
                    text: "STOP".into(),
                    color: on_primary,
                    size: 10.0,
                    bold: true,
                    align: TextAlign::Center,
                });
                hit_targets.push(HitTarget {
                    rect: stop_rect,
                    id: "island:record:stop".into(),
                });
            } else if state.display_activity.is_some() || state.display_status.is_active() {
                let (badge, col, detail) =
                    describe_display_activity(state, primary, secondary, tertiary);
                let badge_rect = Rect::new(inner_x + 10.0, (pill_h - 22.0) * 0.5, 56.0, 22.0);
                commands.push(PaintCmd::RoundedRect {
                    rect: badge_rect,
                    radius: 11.0,
                    fill: Some(col),
                    stroke: None,
                    stroke_width: 0.0,
                });
                commands.push(PaintCmd::Text {
                    rect: badge_rect,
                    text: badge,
                    color: on_primary,
                    size: 10.5,
                    bold: true,
                    align: TextAlign::Center,
                });
                commands.push(PaintCmd::RichText {
                    rect: Rect::new(inner_x + 74.0, (pill_h - 18.0) * 0.5, inner_w - 134.0, 20.0),
                    text: ellipsize(&detail, 20),
                    color: on_surface,
                    size: 12.0,
                    bold: false,
                    align: TextAlign::Left,
                    max_lines: 1,
                });
                commands.push(PaintCmd::Text {
                    rect: Rect::new(inner_x + inner_w - 56.0, 0.0, 46.0, pill_h),
                    text: state.clock.format_hh_mm(),
                    color: muted,
                    size: 12.0,
                    bold: true,
                    align: TextAlign::Right,
                });
            } else if state.media.active {
                let play_icon = if state.media.status == MediaPlayback::Playing {
                    IconKind::Pause
                } else {
                    IconKind::Play
                };
                let play_rect = Rect::new(inner_x + 10.0, (pill_h - 22.0) * 0.5, 22.0, 22.0);
                commands.push(PaintCmd::RoundedRect {
                    rect: play_rect,
                    radius: 11.0,
                    fill: Some(surface_container),
                    stroke: None,
                    stroke_width: 0.0,
                });
                commands.push(PaintCmd::Icon {
                    rect: Rect::new(play_rect.x + 5.0, play_rect.y + 5.0, 12.0, 12.0),
                    kind: play_icon,
                    color: primary,
                    stroke_width: 1.5,
                    level: None,
                });
                hit_targets.push(HitTarget {
                    rect: play_rect,
                    id: "island:media:play".into(),
                });

                let label = if state.media.artist.is_empty() {
                    state.media.title.clone()
                } else {
                    format!("{} — {}", state.media.title, state.media.artist)
                };
                commands.push(PaintCmd::RichText {
                    rect: Rect::new(inner_x + 38.0, (pill_h - 18.0) * 0.5, inner_w - 98.0, 20.0),
                    text: ellipsize(&label, 24),
                    color: on_surface,
                    size: 12.0,
                    bold: true,
                    align: TextAlign::Left,
                    max_lines: 1,
                });
                commands.push(PaintCmd::Text {
                    rect: Rect::new(inner_x + inner_w - 56.0, 0.0, 46.0, pill_h),
                    text: state.clock.format_hh_mm(),
                    color: muted,
                    size: 12.0,
                    bold: true,
                    align: TextAlign::Right,
                });
            } else if let Some(custom) = state.custom_activities.values().next() {
                let badge_rect = Rect::new(inner_x + 10.0, (pill_h - 22.0) * 0.5, 52.0, 22.0);
                commands.push(PaintCmd::RoundedRect {
                    rect: badge_rect,
                    radius: 11.0,
                    fill: Some(primary),
                    stroke: None,
                    stroke_width: 0.0,
                });
                commands.push(PaintCmd::Text {
                    rect: badge_rect,
                    text: ellipsize(&custom.badge, 6),
                    color: on_primary,
                    size: 10.0,
                    bold: true,
                    align: TextAlign::Center,
                });
                commands.push(PaintCmd::RichText {
                    rect: Rect::new(inner_x + 68.0, (pill_h - 18.0) * 0.5, inner_w - 80.0, 20.0),
                    text: ellipsize(&custom.title, 26),
                    color: on_surface,
                    size: 12.0,
                    bold: false,
                    align: TextAlign::Left,
                    max_lines: 1,
                });
            }
        }
        IslandMode::AbsorbedOsd => {
            let kind = absorbed_osd.unwrap_or(OsdKind::Volume);
            let (icon, pct, accent, label) = match kind {
                OsdKind::Volume => {
                    if state.audio.muted {
                        (IconKind::VolumeMuted, 0u8, error_col, "MUTE".into())
                    } else {
                        (
                            IconKind::Volume,
                            state.audio.volume_pct,
                            primary,
                            format!("{}%", state.audio.volume_pct),
                        )
                    }
                }
                OsdKind::Mic => {
                    if state.audio.mic_muted {
                        (IconKind::MicMuted, 0u8, error_col, "MIC OFF".into())
                    } else {
                        (IconKind::MicMuted, 100u8, primary, "MIC ON".into())
                    }
                }
                OsdKind::Brightness => (
                    IconKind::Brightness,
                    state.backlight.percentage,
                    tertiary,
                    format!("{}%", state.backlight.percentage),
                ),
            };
            commands.push(PaintCmd::Icon {
                rect: Rect::new(inner_x + 16.0, (pill_h - 18.0) * 0.5, 18.0, 18.0),
                kind: icon,
                color: accent,
                stroke_width: 1.7,
                level: Some(pct.min(100)),
            });
            let bar_x = inner_x + 44.0;
            let bar_w = (inner_w - 114.0).max(60.0);
            let bar_y = (pill_h - 8.0) * 0.5;
            commands.push(PaintCmd::RoundedRect {
                rect: Rect::new(bar_x, bar_y, bar_w, 8.0),
                radius: 4.0,
                fill: Some(surface_container),
                stroke: None,
                stroke_width: 0.0,
            });
            let fill_w = (bar_w * f32::from(pct.min(100)) / 100.0).round();
            if fill_w >= 2.0 {
                commands.push(PaintCmd::RoundedRect {
                    rect: Rect::new(bar_x, bar_y, fill_w, 8.0),
                    radius: 4.0,
                    fill: Some(accent),
                    stroke: None,
                    stroke_width: 0.0,
                });
            }
            commands.push(PaintCmd::Text {
                rect: Rect::new(inner_x + inner_w - 64.0, 0.0, 50.0, pill_h),
                text: label,
                color: on_surface,
                size: 12.0,
                bold: true,
                align: TextAlign::Right,
            });
        }
        IslandMode::AbsorbedNotify => {
            if let Some(item) = absorbed_notify {
                commands.push(PaintCmd::RoundedRect {
                    rect: Rect::new(inner_x + 12.0, 14.0, 3.0, (pill_h - 28.0).max(16.0)),
                    radius: 1.5,
                    fill: Some(primary),
                    stroke: None,
                    stroke_width: 0.0,
                });
                let app_label = if item.app_name.is_empty() {
                    "Notification"
                } else {
                    item.app_name.as_str()
                };
                commands.push(PaintCmd::RichText {
                    rect: Rect::new(inner_x + 24.0, 10.0, inner_w - 62.0, 16.0),
                    text: ellipsize(app_label, 30),
                    color: muted,
                    size: 10.5,
                    bold: false,
                    align: TextAlign::Left,
                    max_lines: 1,
                });
                let close_rect = Rect::new(inner_x + inner_w - 30.0, 10.0, 18.0, 18.0);
                commands.push(PaintCmd::Icon {
                    rect: Rect::new(close_rect.x + 3.0, close_rect.y + 3.0, 12.0, 12.0),
                    kind: IconKind::Close,
                    color: muted,
                    stroke_width: 1.5,
                    level: None,
                });
                hit_targets.push(HitTarget {
                    rect: close_rect,
                    id: "island:notify:dismiss".into(),
                });
                commands.push(PaintCmd::RichText {
                    rect: Rect::new(inner_x + 24.0, 28.0, inner_w - 38.0, 22.0),
                    text: ellipsize(&item.summary, 42),
                    color: on_surface,
                    size: 13.0,
                    bold: true,
                    align: TextAlign::Left,
                    max_lines: 1,
                });
                if !item.body.trim().is_empty() {
                    commands.push(PaintCmd::RichText {
                        rect: Rect::new(inner_x + 24.0, 52.0, inner_w - 38.0, 34.0),
                        text: ellipsize(item.body.trim(), 78),
                        color: muted,
                        size: 11.5,
                        bold: false,
                        align: TextAlign::Left,
                        max_lines: 2,
                    });
                }
            }
        }
        IslandMode::Expanded => {
            let pad = 14.0f32;
            let content_x = inner_x + pad;
            let content_w = (inner_w - pad * 2.0).max(120.0);
            let mut y = 6.0f32;

            // Header row (aligned to the 34px Collapsed baseline: y=6..28)
            commands.push(PaintCmd::Text {
                rect: Rect::new(content_x, y, 56.0, 22.0),
                text: state.clock.format_hh_mm(),
                color: on_surface,
                size: 13.5,
                bold: true,
                align: TextAlign::Left,
            });
            commands.push(PaintCmd::Text {
                rect: Rect::new(content_x + 58.0, y, 64.0, 22.0),
                text: format!("WS {ws_id}"),
                color: primary,
                size: 11.5,
                bold: true,
                align: TextAlign::Left,
            });
            if state.media.active {
                // Centered transport pills aligned to the Collapsed top strip so long titles
                // below get full width and controls stay anchored cleanly during morphs.
                let btn_size = 20.0f32;
                let btn_gap = 8.0f32;
                let group_w = btn_size * 3.0 + btn_gap * 2.0;
                let bx0 = inner_x + (inner_w - group_w) * 0.5;
                let by = y + 1.0;
                let play_kind = if state.media.status == MediaPlayback::Playing {
                    IconKind::Pause
                } else {
                    IconKind::Play
                };
                for (idx, (id, kind)) in [
                    ("island:media:prev", IconKind::Prev),
                    ("island:media:play", play_kind),
                    ("island:media:next", IconKind::Next),
                ]
                .iter()
                .enumerate()
                {
                    let r = Rect::new(
                        bx0 + idx as f32 * (btn_size + btn_gap),
                        by,
                        btn_size,
                        btn_size,
                    );
                    commands.push(PaintCmd::RoundedRect {
                        rect: r,
                        radius: btn_size * 0.5,
                        fill: Some(if idx == 1 { primary } else { surface_container }),
                        stroke: None,
                        stroke_width: 0.0,
                    });
                    commands.push(PaintCmd::Icon {
                        rect: Rect::new(r.x + 4.5, r.y + 4.5, 11.0, 11.0),
                        kind: *kind,
                        color: if idx == 1 { on_primary } else { on_surface },
                        stroke_width: 1.5,
                        level: None,
                    });
                    hit_targets.push(HitTarget {
                        rect: r,
                        id: (*id).to_string(),
                    });
                }
            }
            let collapse_rect = Rect::new(content_x + content_w - 22.0, y, 22.0, 22.0);
            commands.push(PaintCmd::RoundedRect {
                rect: collapse_rect,
                radius: 11.0,
                fill: Some(surface_container),
                stroke: None,
                stroke_width: 0.0,
            });
            commands.push(PaintCmd::Icon {
                rect: Rect::new(collapse_rect.x + 5.0, collapse_rect.y + 5.0, 12.0, 12.0),
                kind: IconKind::Close,
                color: muted,
                stroke_width: 1.5,
                level: None,
            });
            hit_targets.push(HitTarget {
                rect: collapse_rect,
                id: "island:collapse".into(),
            });
            y += 30.0;

            // Record section
            if let Some(rec) = state.record_activity.as_ref().filter(|r| r.active) {
                let elapsed = now_secs.saturating_sub(rec.started_at);
                let row = Rect::new(content_x, y, content_w, 34.0);
                commands.push(PaintCmd::RoundedRect {
                    rect: row,
                    radius: 10.0,
                    fill: Some(surface_container),
                    stroke: Some(error_col),
                    stroke_width: 1.0,
                });
                commands.push(PaintCmd::Circle {
                    cx: content_x + 14.0,
                    cy: y + 17.0,
                    radius: 4.5,
                    fill: error_col,
                });
                let rec_label = format!(
                    "{} {} {}",
                    if rec.gif { "GIF" } else { "REC" },
                    format_mm_ss(elapsed),
                    if rec.audio { "· AUDIO" } else { "" }
                );
                commands.push(PaintCmd::Text {
                    rect: Rect::new(content_x + 26.0, y, content_w - 110.0, 34.0),
                    text: rec_label.trim().to_string(),
                    color: on_surface,
                    size: 12.0,
                    bold: true,
                    align: TextAlign::Left,
                });
                let stop_btn = Rect::new(content_x + content_w - 76.0, y + 5.0, 68.0, 24.0);
                commands.push(PaintCmd::RoundedRect {
                    rect: stop_btn,
                    radius: 8.0,
                    fill: Some(error_col),
                    stroke: None,
                    stroke_width: 0.0,
                });
                commands.push(PaintCmd::Text {
                    rect: stop_btn,
                    text: "STOP".into(),
                    color: on_primary,
                    size: 10.5,
                    bold: true,
                    align: TextAlign::Center,
                });
                hit_targets.push(HitTarget {
                    rect: stop_btn,
                    id: "island:record:stop".into(),
                });
                y += 42.0;
            }

            // Display / Screen Share section
            if state.display_activity.is_some() || state.display_status.is_active() {
                let (badge, col, detail) =
                    describe_display_activity(state, primary, secondary, tertiary);
                commands.push(PaintCmd::Text {
                    rect: Rect::new(content_x, y, content_w, 18.0),
                    text: format!("{badge} · {detail}"),
                    color: col,
                    size: 11.5,
                    bold: true,
                    align: TextAlign::Left,
                });
                let btn_y = y + 20.0;
                let gap = 6.0f32;
                let btn_w = (content_w - gap * 2.0) / 3.0;
                let buttons = [
                    (
                        "island:display:preview",
                        "Preview PiP",
                        surface_container,
                        on_surface,
                    ),
                    (
                        "island:display:control",
                        "Control",
                        surface_container,
                        on_surface,
                    ),
                    ("island:display:stop", "Stop", error_col, on_primary),
                ];
                for (idx, (id, label, fill, fg)) in buttons.iter().enumerate() {
                    let rect =
                        Rect::new(content_x + idx as f32 * (btn_w + gap), btn_y, btn_w, 24.0);
                    commands.push(PaintCmd::RoundedRect {
                        rect,
                        radius: 8.0,
                        fill: Some(*fill),
                        stroke: None,
                        stroke_width: 0.0,
                    });
                    commands.push(PaintCmd::Text {
                        rect,
                        text: (*label).to_string(),
                        color: *fg,
                        size: 10.5,
                        bold: true,
                        align: TextAlign::Center,
                    });
                    hit_targets.push(HitTarget {
                        rect,
                        id: (*id).to_string(),
                    });
                }
                y += 50.0;
            }

            // Media MPRIS section (full-width metadata + interpolated progress bar)
            if state.media.active {
                let title = if state.media.title.is_empty() {
                    state.media.player.as_str()
                } else {
                    state.media.title.as_str()
                };
                commands.push(PaintCmd::RichText {
                    rect: Rect::new(content_x, y, content_w, 20.0),
                    text: ellipsize(title, 46),
                    color: on_surface,
                    size: 13.0,
                    bold: true,
                    align: TextAlign::Left,
                    max_lines: 1,
                });
                if !state.media.artist.is_empty() {
                    commands.push(PaintCmd::RichText {
                        rect: Rect::new(content_x, y + 20.0, content_w, 18.0),
                        text: ellipsize(&state.media.artist, 48),
                        color: muted,
                        size: 11.0,
                        bold: false,
                        align: TextAlign::Left,
                        max_lines: 1,
                    });
                }

                // Progress bar interpolated via `position + rate * elapsed`
                let prog_y = y + 46.0;
                commands.push(PaintCmd::RoundedRect {
                    rect: Rect::new(content_x, prog_y, content_w, 5.0),
                    radius: 2.5,
                    fill: Some(surface_variant),
                    stroke: None,
                    stroke_width: 0.0,
                });
                if let Some(frac) = state.media.interpolated_progress(now_epoch_ms()) {
                    let fw = (content_w * frac).round();
                    if fw >= 2.0 {
                        commands.push(PaintCmd::RoundedRect {
                            rect: Rect::new(content_x, prog_y, fw, 5.0),
                            radius: 2.5,
                            fill: Some(primary),
                            stroke: None,
                            stroke_width: 0.0,
                        });
                    }
                }
                y += 62.0;
            }

            if !IslandExtension::has_live_activity(state) {
                commands.push(PaintCmd::RichText {
                    rect: Rect::new(content_x, y + 4.0, content_w, 22.0),
                    text: "No active Live Activities".into(),
                    color: muted,
                    size: 12.0,
                    bold: false,
                    align: TextAlign::Center,
                    max_lines: 1,
                });
            }
        }
    }

    // Whole-pill click target pushed AFTER specific inner buttons so buttons win hit-testing.
    hit_targets.push(HitTarget {
        rect: pill_rect,
        id: "island:pill".into(),
    });

    let top_margin = if is_notch {
        0
    } else {
        state.config.island.margin_top.clamp(6, 12)
    };

    SurfaceSpec {
        id: SURFACE_ID.to_string(),
        namespace: NAMESPACE.to_string(),
        output: Some(output_name.to_string()),
        layer: Layer::Overlay,
        keyboard_interactivity: if mode == IslandMode::Expanded {
            KeyboardMode::OnDemand
        } else {
            KeyboardMode::None
        },
        anchor: Anchor::TOP,
        // -1 ignores the split top bar's exclusive zone so notch mode anchors flush at y=0
        // and floating mode sits cleanly at margin.top (8px).
        exclusive_zone: -1,
        width: surf_w,
        height: surf_h,
        margin: EdgeInsets {
            top: top_margin,
            ..EdgeInsets::default()
        },
        corner_radius: 0.0,
        background: Color::TRANSPARENT,
        border_color: Color::TRANSPARENT,
        border_width: 0.0,
        commands,
        hit_targets,
        animating,
        input_regions: if animating {
            Some(vec![pill_rect])
        } else {
            None
        },
    }
}

fn describe_display_activity(
    state: &AppState,
    primary: Color,
    secondary: Color,
    tertiary: Color,
) -> (String, Color, String) {
    if let Some(ref act) = state.display_activity {
        let ws_label = act
            .ws
            .map(|w| format!("WS {w}"))
            .unwrap_or_else(|| "Screen".into());
        let suffix = if act.control { " · CTRL" } else { "" };
        match act.mode.as_str() {
            "present" | "live" => ("LIVE".into(), primary, format!("{ws_label}{suffix}")),
            "virtual-control" | "control" => ("CTRL".into(), tertiary, ws_label),
            _ => ("SHARE".into(), secondary, format!("{ws_label}{suffix}")),
        }
    } else {
        match &state.display_status {
            DisplayStatus::Present { detail } => ("LIVE".into(), primary, detail.clone()),
            DisplayStatus::VirtualControl { detail } => ("CTRL".into(), tertiary, detail.clone()),
            DisplayStatus::VirtualShare { detail } => ("SHARE".into(), secondary, detail.clone()),
            DisplayStatus::Recording { detail } => ("REC".into(), primary, detail.clone()),
            DisplayStatus::Idle => ("IDLE".into(), secondary, String::new()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use kaze_core::{Config, LayoutPreset, MediaState, OutputInfo};

    fn state_with_outputs() -> AppState {
        let mut cfg = Config::default();
        cfg.layout.preset = LayoutPreset::Island;
        let mut st = AppState::new(cfg);
        st.outputs.insert(
            "Virtual-1".into(),
            OutputInfo {
                name: "Virtual-1".into(),
                width: 1920,
                height: 1080,
                scale: 1,
            },
        );
        st.outputs.insert(
            "kaze-share".into(),
            OutputInfo {
                name: "kaze-share".into(),
                width: 1920,
                height: 1080,
                scale: 1,
            },
        );
        st
    }

    #[test]
    fn island_targets_primary_output_never_kaze_share_and_supports_floating_and_notch() {
        let mut st = state_with_outputs();
        let mut ext = IslandExtension::new();
        {
            let mut ctx = ShellContext::new(&mut st);
            ext.on_init(&mut ctx);
        }
        let specs = ext.surfaces();
        assert_eq!(specs.len(), 1);
        assert_eq!(specs[0].namespace, "kaze-island");
        assert_eq!(specs[0].output.as_deref(), Some("Virtual-1"));
        assert_eq!(specs[0].margin.top, 8);

        {
            let mut ctx = ShellContext::new(&mut st);
            let res = ext.on_ipc("island-style", &["notch".into()], &mut ctx);
            assert!(matches!(res, IpcResult::Handled { ok: true, .. }));
        }
        let notch_specs = ext.surfaces();
        assert_eq!(notch_specs[0].margin.top, 0);
        assert_eq!(notch_specs[0].exclusive_zone, -1);
        assert!(notch_specs[0]
            .commands
            .iter()
            .any(|c| matches!(c, PaintCmd::NotchPill { .. })));
    }

    #[test]
    fn expanded_island_auto_collapses_when_mpris_exits() {
        let mut st = state_with_outputs();
        let mut ext = IslandExtension::new();
        {
            let mut ctx = ShellContext::new(&mut st);
            ext.on_init(&mut ctx);
        }
        st.media = MediaState {
            active: true,
            player: "mock".into(),
            title: "Song".into(),
            artist: "Artist".into(),
            status: MediaPlayback::Playing,
            position_us: 0,
            length_us: 60_000_000,
            rate_milli: 1000,
            updated_at_epoch_ms: now_epoch_ms(),
        };
        {
            let mut ctx = ShellContext::new(&mut st);
            ext.on_event(
                &SystemEvent::MediaChanged(ctx.state.media.clone()),
                &mut ctx,
            );
            ext.on_event(
                &SystemEvent::PointerClick {
                    surface_id: SURFACE_ID.into(),
                    target_id: "island:pill".into(),
                    button: PointerButton::Left,
                },
                &mut ctx,
            );
            assert_eq!(ext.visual_mode(ctx.state), IslandMode::Expanded);
        }
        st.media = MediaState::default();
        {
            let mut ctx = ShellContext::new(&mut st);
            ext.on_event(
                &SystemEvent::MediaChanged(ctx.state.media.clone()),
                &mut ctx,
            );
            assert_eq!(ext.visual_mode(ctx.state), IslandMode::Collapsed);
        }
    }

    #[test]
    fn island_toggle_springs_converge_and_stop_animating() {
        let mut st = state_with_outputs();
        let mut ext = IslandExtension::new();
        {
            let mut ctx = ShellContext::new(&mut st);
            ext.on_init(&mut ctx);
        }
        assert!(!ext.surfaces()[0].animating);

        {
            let mut ctx = ShellContext::new(&mut st);
            let res = ext.on_ipc("island-toggle", &[], &mut ctx);
            assert!(matches!(res, IpcResult::Handled { ok: true, .. }));
        }
        assert!(ext.surfaces()[0].animating);
        assert!(ext.surfaces()[0].input_regions.is_some());

        for _ in 0..160 {
            if !ext.surfaces()[0].animating {
                break;
            }
            let mut ctx = ShellContext::new(&mut st);
            ext.on_event(
                &SystemEvent::FrameTick {
                    surface_id: SURFACE_ID.into(),
                    dt_secs: 1.0 / 60.0,
                },
                &mut ctx,
            );
        }
        assert!(!ext.surfaces()[0].animating, "island springs must settle");
        assert!(ext.surfaces()[0].width >= 400);
    }

    #[test]
    fn record_and_media_timers_arm_only_when_active_and_cancel_on_clear() {
        let mut st = state_with_outputs();
        let mut ext = IslandExtension::new();
        {
            let mut ctx = ShellContext::new(&mut st);
            ext.on_init(&mut ctx);
        }

        // Start recording activity -> arms 1s timer
        {
            let mut ctx = ShellContext::new(&mut st);
            ext.on_ipc(
                "island-activity",
                &[
                    "record".into(),
                    r#"{"active":true,"started_at":1700000000,"audio":true}"#.into(),
                ],
                &mut ctx,
            );
            assert!(ctx.actions.iter().any(|a| matches!(
                a,
                ShellAction::ScheduleTimer { id, after_ms: 1000 } if id == TIMER_RECORD_TICK
            )));
        }
        // Clear recording -> immediately cancels 1s timer
        {
            let mut ctx = ShellContext::new(&mut st);
            ext.on_ipc("island-clear", &["record".into()], &mut ctx);
            assert!(ctx.actions.iter().any(|a| matches!(
                a,
                ShellAction::CancelTimer { id } if id == TIMER_RECORD_TICK
            )));
        }

        // Playing media while collapsed must NOT arm media progress timer (0 polling when collapsed)
        st.media = MediaState {
            active: true,
            player: "spotify".into(),
            title: "Nhạc Việt Nam 🎵".into(),
            artist: "Nghệ sĩ".into(),
            status: MediaPlayback::Playing,
            position_us: 30_000_000,
            length_us: 180_000_000,
            rate_milli: 1000,
            updated_at_epoch_ms: now_epoch_ms(),
        };
        {
            let mut ctx = ShellContext::new(&mut st);
            ext.on_event(
                &SystemEvent::MediaChanged(ctx.state.media.clone()),
                &mut ctx,
            );
            assert!(!ctx.actions.iter().any(|a| matches!(
                a,
                ShellAction::ScheduleTimer { id, .. } if id == TIMER_MEDIA_TICK
            )));
        }
        // Expanding arms media progress timer; collapsing cancels it immediately
        {
            let mut ctx = ShellContext::new(&mut st);
            ext.on_ipc("island-toggle", &[], &mut ctx);
            assert!(ctx.actions.iter().any(|a| matches!(
                a,
                ShellAction::ScheduleTimer { id, .. } if id == TIMER_MEDIA_TICK
            )));
        }
        {
            let mut ctx = ShellContext::new(&mut st);
            ext.on_ipc("island-toggle", &[], &mut ctx);
            assert!(ctx.actions.iter().any(|a| matches!(
                a,
                ShellAction::CancelTimer { id } if id == TIMER_MEDIA_TICK
            )));
        }
    }

    #[test]
    fn display_activity_buttons_emit_kaze_display_commands() {
        let mut st = state_with_outputs();
        let mut ext = IslandExtension::new();
        {
            let mut ctx = ShellContext::new(&mut st);
            ext.on_init(&mut ctx);
            ext.on_ipc(
                "island-activity",
                &[
                    "display".into(),
                    r#"{"mode":"virtual-share","ws":9,"control":false}"#.into(),
                ],
                &mut ctx,
            );
            ext.on_ipc("island-toggle", &[], &mut ctx);
        }
        let mut ctx = ShellContext::new(&mut st);
        ext.on_event(
            &SystemEvent::PointerClick {
                surface_id: SURFACE_ID.into(),
                target_id: "island:display:preview".into(),
                button: PointerButton::Left,
            },
            &mut ctx,
        );
        assert!(ctx.actions.contains(&ShellAction::SpawnCommand {
            program: "kaze-display".into(),
            args: vec!["toggle-preview".into()],
        }));
    }

    #[test]
    fn absorbs_normal_notification_and_osd_in_island_preset_while_critical_bypasses() {
        let mut st = state_with_outputs();
        let mut ext = IslandExtension::new();
        {
            let mut ctx = ShellContext::new(&mut st);
            ext.on_init(&mut ctx);
        }
        let notif = NotificationItem {
            id: 7,
            app_name: "Zalo".into(),
            summary: "Tiếng Việt 🚀".into(),
            body: "Nội dung tin nhắn".into(),
            app_icon: String::new(),
            urgency: NotificationUrgency::Normal,
            actions: vec![],
            expire_timeout_ms: -1,
            resident: false,
            transient: false,
            sync_tag: None,
            timestamp_epoch_secs: 1_700_000_000,
        };
        {
            let mut ctx = ShellContext::new(&mut st);
            let dirty = ext.on_event(&SystemEvent::NotificationReceived(notif), &mut ctx);
            assert!(dirty.contains(DirtyFlags::ISLAND));
            assert_eq!(ext.visual_mode(ctx.state), IslandMode::AbsorbedNotify);
        }
    }
}
