#![deny(clippy::unwrap_used)]

use kaze_core::{
    Anchor, AppState, Color, CornerPos, DirtyFlags, EdgeInsets, HotCornerActionConfig, IpcResult,
    KazeExtension, KeyboardMode, Layer, OutputInfo, PaintCmd, ShellAction, ShellContext,
    SurfaceSpec, SystemEvent,
};
use std::collections::{HashMap, HashSet};
use std::time::Instant;

const DWELL_PREFIX: &str = "corners:dwell:";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct CornerDescriptor {
    key: &'static str,
    pos: CornerPos,
    anchor: Anchor,
}

const CORNERS: [CornerDescriptor; 4] = [
    CornerDescriptor {
        key: "tl",
        pos: CornerPos::TopLeft,
        anchor: Anchor::TOP.union(Anchor::LEFT),
    },
    CornerDescriptor {
        key: "tr",
        pos: CornerPos::TopRight,
        anchor: Anchor::TOP.union(Anchor::RIGHT),
    },
    CornerDescriptor {
        key: "bl",
        pos: CornerPos::BottomLeft,
        anchor: Anchor::BOTTOM.union(Anchor::LEFT),
    },
    CornerDescriptor {
        key: "br",
        pos: CornerPos::BottomRight,
        anchor: Anchor::BOTTOM.union(Anchor::RIGHT),
    },
];

/// Hot Corners (`kaze-hot-corner-*`) + Screen Corners (`kaze-screen-corner-*`) extension:
/// - Hot Corners spawn minimal 4x4 `Layer::Overlay` edge sensors only when configured, with
///   dwell timer cancellation on early leave, cooldown throttling, and fullscreen awareness.
/// - Screen Corners render pure concave bezel overlays with empty `wl_region` (`Some(vec![])`)
///   for 100% click-through input transparency.
/// - Always excludes `kaze-share` and outputs running `present`.
pub struct CornersExtension {
    cached_specs: Vec<SurfaceSpec>,
    pending_dwell: HashSet<String>,
    last_trigger: HashMap<String, Instant>,
    now_override: Option<Instant>,
}

impl Default for CornersExtension {
    fn default() -> Self {
        Self::new()
    }
}

impl CornersExtension {
    pub fn new() -> Self {
        Self {
            cached_specs: Vec::new(),
            pending_dwell: HashSet::new(),
            last_trigger: HashMap::new(),
            now_override: None,
        }
    }

    fn current_time(&self) -> Instant {
        self.now_override.unwrap_or_else(Instant::now)
    }

    fn action_for_corner<'a>(state: &'a AppState, key: &str) -> &'a HotCornerActionConfig {
        match key {
            "tl" => &state.config.corners.top_left,
            "tr" => &state.config.corners.top_right,
            "bl" => &state.config.corners.bottom_left,
            _ => &state.config.corners.bottom_right,
        }
    }

    fn corner_has_action(act: &HotCornerActionConfig) -> bool {
        !act.ipc.trim().is_empty() || !act.command.trim().is_empty()
    }

    fn execute_corner_action(
        &mut self,
        corner_id: &str,
        act: &HotCornerActionConfig,
        ctx: &mut ShellContext,
    ) {
        self.last_trigger
            .insert(corner_id.to_string(), self.current_time());
        if !act.ipc.trim().is_empty() {
            let mut args = vec!["msg".to_string()];
            args.extend(act.ipc.split_whitespace().map(str::to_string));
            if args.len() > 1 {
                ctx.push_action(ShellAction::SpawnCommand {
                    program: "kaze-shell".to_string(),
                    args,
                });
            }
        } else if !act.command.trim().is_empty() {
            ctx.push_action(ShellAction::SpawnCommand {
                program: "sh".to_string(),
                args: vec!["-c".to_string(), act.command.clone()],
            });
        }
    }

    fn rebuild(&mut self, state: &AppState) {
        self.cached_specs.clear();
        if state.session_locked {
            return;
        }
        let corners_cfg = &state.config.corners;
        let radius = corners_cfg.screen_corners_radius.clamp(0.0, 64.0);
        let mask_col = Color::rgba(0, 0, 0, 255);

        for output in state.outputs.values() {
            if state.is_output_excluded(&output.name) {
                continue;
            }
            if corners_cfg.screen_corners_enabled && radius >= 2.0 {
                let side = radius.ceil() as u32;
                for c in &CORNERS {
                    self.cached_specs.push(build_screen_corner_surface(
                        output, *c, side, radius, mask_col,
                    ));
                }
            }
            if corners_cfg.hot_enabled {
                for c in &CORNERS {
                    let act = Self::action_for_corner(state, c.key);
                    if !Self::corner_has_action(act) {
                        continue;
                    }
                    self.cached_specs.push(build_hot_corner_surface(output, *c));
                }
            }
        }
    }
}

impl KazeExtension for CornersExtension {
    fn id(&self) -> &'static str {
        "corners"
    }

    fn on_init(&mut self, ctx: &mut ShellContext) {
        self.rebuild(ctx.state);
    }

    fn on_event(&mut self, event: &SystemEvent, ctx: &mut ShellContext) -> DirtyFlags {
        match event {
            SystemEvent::OutputAdded(_)
            | SystemEvent::OutputUpdated(_)
            | SystemEvent::OutputRemoved { .. }
            | SystemEvent::ConfigReloaded
            | SystemEvent::ThemeChanged(_)
            | SystemEvent::SessionLockRequested
            | SystemEvent::SessionUnlockRequested
            | SystemEvent::LockWorkerCommitted
            | SystemEvent::LockWorkerExited => {
                self.rebuild(ctx.state);
                DirtyFlags::CORNERS
            }
            SystemEvent::PointerEnter { surface_id, .. } => {
                let Some(rest) = surface_id.strip_prefix("corners:hot:") else {
                    return DirtyFlags::NONE;
                };
                let Some((key, out)) = rest.split_once(':') else {
                    return DirtyFlags::NONE;
                };
                if !ctx.state.config.corners.hot_enabled {
                    return DirtyFlags::NONE;
                }
                let act = Self::action_for_corner(ctx.state, key).clone();
                if !Self::corner_has_action(&act) {
                    return DirtyFlags::NONE;
                }
                if act.disable_in_fullscreen && ctx.state.fullscreen_outputs.contains(out) {
                    return DirtyFlags::NONE;
                }
                if let Some(prev) = self.last_trigger.get(rest) {
                    let elapsed_ms = self
                        .current_time()
                        .saturating_duration_since(*prev)
                        .as_millis() as u64;
                    if elapsed_ms < act.cooldown_ms {
                        return DirtyFlags::NONE;
                    }
                }
                if act.dwell_ms == 0 {
                    self.execute_corner_action(rest, &act, ctx);
                } else {
                    self.pending_dwell.insert(rest.to_string());
                    ctx.push_action(ShellAction::ScheduleTimer {
                        id: format!("{DWELL_PREFIX}{rest}"),
                        after_ms: act.dwell_ms,
                    });
                }
                DirtyFlags::NONE
            }
            SystemEvent::PointerLeave { surface_id } => {
                if let Some(rest) = surface_id.strip_prefix("corners:hot:") {
                    if self.pending_dwell.remove(rest) {
                        ctx.push_action(ShellAction::CancelTimer {
                            id: format!("{DWELL_PREFIX}{rest}"),
                        });
                    }
                }
                DirtyFlags::NONE
            }
            SystemEvent::TimerFired { id } => {
                if let Some(rest) = id.strip_prefix(DWELL_PREFIX) {
                    if self.pending_dwell.remove(rest) {
                        if let Some((key, _)) = rest.split_once(':') {
                            let act = Self::action_for_corner(ctx.state, key).clone();
                            if Self::corner_has_action(&act) {
                                self.execute_corner_action(rest, &act, ctx);
                            }
                        }
                    }
                }
                DirtyFlags::NONE
            }
            _ => DirtyFlags::NONE,
        }
    }

    fn on_ipc(&mut self, _cmd: &str, _args: &[String], _ctx: &mut ShellContext) -> IpcResult {
        IpcResult::Unhandled
    }

    fn surfaces(&self) -> Vec<SurfaceSpec> {
        self.cached_specs.clone()
    }
}

fn build_hot_corner_surface(output: &OutputInfo, corner: CornerDescriptor) -> SurfaceSpec {
    SurfaceSpec {
        id: format!("corners:hot:{}:{}", corner.key, output.name),
        namespace: format!("kaze-hot-corner-{}-{}", corner.key, output.name),
        output: Some(output.name.clone()),
        layer: Layer::Overlay,
        keyboard_interactivity: KeyboardMode::None,
        anchor: corner.anchor,
        exclusive_zone: 0,
        width: 4,
        height: 4,
        margin: EdgeInsets::default(),
        corner_radius: 0.0,
        background: Color::TRANSPARENT,
        border_color: Color::TRANSPARENT,
        border_width: 0.0,
        commands: Vec::new(),
        hit_targets: Vec::new(),
        animating: false,
        input_regions: None,
        ime_cursor_rect: None,
        track_pointer_motion: false,
    }
}

fn build_screen_corner_surface(
    output: &OutputInfo,
    corner: CornerDescriptor,
    side: u32,
    radius: f32,
    color: Color,
) -> SurfaceSpec {
    SurfaceSpec {
        id: format!("corners:mask:{}:{}", corner.key, output.name),
        namespace: format!("kaze-screen-corner-{}-{}", corner.key, output.name),
        output: Some(output.name.clone()),
        layer: Layer::Overlay,
        keyboard_interactivity: KeyboardMode::None,
        anchor: corner.anchor,
        exclusive_zone: 0,
        width: side,
        height: side,
        margin: EdgeInsets::default(),
        corner_radius: 0.0,
        background: Color::TRANSPARENT,
        border_color: Color::TRANSPARENT,
        border_width: 0.0,
        commands: vec![PaintCmd::ConcaveCorner {
            corner: corner.pos,
            radius,
            color,
        }],
        hit_targets: Vec::new(),
        animating: false,
        // Pure click-through empty wl_region.
        input_regions: Some(Vec::new()),
        ime_cursor_rect: None,
        track_pointer_motion: false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use kaze_core::Config;
    use std::time::Duration;

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
    fn screen_corners_are_strictly_click_through_and_exclude_kaze_share() {
        let mut cfg = Config::default();
        cfg.corners.screen_corners_enabled = true;
        cfg.corners.screen_corners_radius = 16.0;
        let mut state = AppState::new(cfg);
        state.outputs.insert("DP-1".into(), virtual_out("DP-1"));
        state
            .outputs
            .insert("kaze-share".into(), virtual_out("kaze-share"));

        let mut ext = CornersExtension::new();
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_init(&mut ctx);
        }
        let specs = ext.surfaces();
        assert_eq!(specs.len(), 4);
        for s in &specs {
            assert_eq!(s.output.as_deref(), Some("DP-1"));
            assert_eq!(s.input_regions, Some(Vec::new()));
            assert!(matches!(
                s.commands.first(),
                Some(PaintCmd::ConcaveCorner { .. })
            ));
        }
    }

    #[test]
    fn hot_corner_dwell_cancel_cooldown_and_fullscreen_suppression() {
        let mut cfg = Config::default();
        cfg.corners.hot_enabled = true;
        cfg.corners.top_left.ipc = "launcher-toggle".into();
        cfg.corners.top_left.dwell_ms = 200;
        cfg.corners.top_left.cooldown_ms = 1000;
        cfg.corners.top_left.disable_in_fullscreen = true;

        let mut state = AppState::new(cfg);
        state.outputs.insert("DP-1".into(), virtual_out("DP-1"));
        let t0 = Instant::now();
        let mut ext = CornersExtension::new();
        ext.now_override = Some(t0);
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_init(&mut ctx);
        }
        assert_eq!(ext.surfaces().len(), 1);

        // Enter & leave early cancels dwell timer with zero commands run
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_event(
                &SystemEvent::PointerEnter {
                    surface_id: "corners:hot:tl:DP-1".into(),
                    x: 1.0,
                    y: 1.0,
                },
                &mut ctx,
            );
            assert!(ctx.actions.contains(&ShellAction::ScheduleTimer {
                id: "corners:dwell:tl:DP-1".into(),
                after_ms: 200,
            }));
            ctx.actions.clear();
            ext.on_event(
                &SystemEvent::PointerLeave {
                    surface_id: "corners:hot:tl:DP-1".into(),
                },
                &mut ctx,
            );
            assert!(ctx.actions.contains(&ShellAction::CancelTimer {
                id: "corners:dwell:tl:DP-1".into(),
            }));
            ctx.actions.clear();
            ext.on_event(
                &SystemEvent::TimerFired {
                    id: "corners:dwell:tl:DP-1".into(),
                },
                &mut ctx,
            );
            assert!(ctx.actions.is_empty());
        }

        // Fullscreen suppresses enter
        state.fullscreen_outputs.insert("DP-1".into());
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_event(
                &SystemEvent::PointerEnter {
                    surface_id: "corners:hot:tl:DP-1".into(),
                    x: 1.0,
                    y: 1.0,
                },
                &mut ctx,
            );
            assert!(ctx.actions.is_empty());
        }
        state.fullscreen_outputs.clear();

        // Successful dwell fires once then respects cooldown
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_event(
                &SystemEvent::PointerEnter {
                    surface_id: "corners:hot:tl:DP-1".into(),
                    x: 1.0,
                    y: 1.0,
                },
                &mut ctx,
            );
            ctx.actions.clear();
            ext.now_override = Some(t0 + Duration::from_millis(210));
            ext.on_event(
                &SystemEvent::TimerFired {
                    id: "corners:dwell:tl:DP-1".into(),
                },
                &mut ctx,
            );
            assert_eq!(
                ctx.actions,
                vec![ShellAction::SpawnCommand {
                    program: "kaze-shell".into(),
                    args: vec!["msg".into(), "launcher-toggle".into()],
                }]
            );
            ctx.actions.clear();
            ext.now_override = Some(t0 + Duration::from_millis(500));
            ext.on_event(
                &SystemEvent::PointerEnter {
                    surface_id: "corners:hot:tl:DP-1".into(),
                    x: 1.0,
                    y: 1.0,
                },
                &mut ctx,
            );
            assert!(ctx.actions.is_empty(), "cooldown must suppress re-trigger");
        }
    }
}
