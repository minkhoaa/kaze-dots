use kaze_core::{
    Anchor, AppState, BarPosition, DirtyFlags, DisplayStatus, EdgeInsets, HitTarget, IpcResult,
    KazeExtension, Layer, OutputInfo, PaintCmd, PointerButton, Rect, ShellAction, ShellContext,
    SurfaceSpec, SystemEvent, TextAlign,
};
use std::collections::BTreeMap;

/// First production extension built strictly against the `KazeExtension` contract:
/// renders Workspaces, minute-boundary Clock, and interactive Display Slot.
pub struct BarExtension {
    cached_specs: Vec<SurfaceSpec>,
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
        }
    }

    fn rebuild(&mut self, state: &AppState) {
        self.cached_specs.clear();
        if !state.config.bar.enabled || state.hide_all_bars {
            return;
        }

        for output in state.outputs.values() {
            if state.is_bar_hidden(&output.name) {
                continue;
            }
            self.cached_specs.push(build_bar_surface(state, output));
        }
    }
}

impl KazeExtension for BarExtension {
    fn id(&self) -> &'static str {
        "bar"
    }

    fn on_init(&mut self, ctx: &mut ShellContext) {
        self.rebuild(ctx.state);
    }

    fn on_event(&mut self, event: &SystemEvent, ctx: &mut ShellContext) -> DirtyFlags {
        match event {
            SystemEvent::OutputAdded(_)
            | SystemEvent::OutputUpdated(_)
            | SystemEvent::OutputRemoved { .. } => {
                self.rebuild(ctx.state);
                DirtyFlags::BAR | DirtyFlags::LAYOUT
            }
            SystemEvent::HyprSynced { .. }
            | SystemEvent::HyprWorkspaceChanged { .. }
            | SystemEvent::HyprFocusedMonitor { .. }
            | SystemEvent::HyprConnectionChanged { .. }
            | SystemEvent::ClockTick(_) => {
                self.rebuild(ctx.state);
                DirtyFlags::BAR
            }
            SystemEvent::ConfigReloaded | SystemEvent::ThemeChanged(_) => {
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
                if target_id == "display" {
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
                DirtyFlags::NONE
            }
        }
    }

    fn on_ipc(&mut self, cmd: &str, args: &[String], ctx: &mut ShellContext) -> IpcResult {
        match cmd {
            "bar-hide" => {
                match args {
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
                    // Accept Noctalia-style `bar-hide <bar_name> <monitor>` seamlessly.
                    [_bar_name, monitor, ..] => {
                        ctx.state.hidden_bars.insert(monitor.clone());
                        self.rebuild(ctx.state);
                        IpcResult::Handled {
                            ok: true,
                            message: format!("hidden bar on {monitor}"),
                            dirty: DirtyFlags::BAR | DirtyFlags::LAYOUT,
                        }
                    }
                }
            }
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

fn build_bar_surface(state: &AppState, output: &OutputInfo) -> SurfaceSpec {
    let bar = &state.config.bar;
    let colors = state.palette.for_mode(state.theme_mode);
    let is_vertical = bar.position.is_vertical();
    let is_island = bar.island_mode || bar.length > 0;

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

    let exclusive_zone = if bar.exclusive && !is_island {
        bar.thickness as i32
    } else {
        0
    };

    let namespace = if bar.island_mode {
        "kaze-island".to_string()
    } else {
        format!("kaze-bar-{}", output.name)
    };

    let mut commands = Vec::new();
    let mut hit_targets = Vec::new();
    let workspaces = collect_workspaces(state, &output.name);

    let bg = colors.surface_color().with_opacity(bar.background_opacity);
    let border_color = colors.outline_variant_color();
    let primary = colors.primary_color();
    let on_primary = colors.on_primary_color();
    let secondary = colors.secondary_color();
    let error_col = colors.error_color();
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

        // 1. Start cluster: Workspaces
        let mut cur_y = pad + bar.border_width;
        for (ws_id, focused, occupied) in &workspaces {
            let rect = Rect::new(pad, cur_y, cell_w, cell_h);
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

        // 2. Center cluster: Stacked vertical 24h Clock (HH / MM)
        let center_y = bh * 0.5;
        let hh_rect = Rect::new(pad, center_y - 18.0, cell_w, 17.0);
        let mm_rect = Rect::new(pad, center_y + 1.0, cell_w, 17.0);
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

        // 3. End cluster: Display Slot (monitor icon + live status dot)
        let slot_h = cell_w.min(32.0);
        let slot_y = (bh - pad - bar.border_width - slot_h).max(center_y + 24.0);
        let slot_rect = Rect::new(pad, slot_y, cell_w, slot_h);
        commands.push(PaintCmd::RoundedRect {
            rect: slot_rect,
            radius: inner_radius,
            fill: Some(if state.display_status.is_active() {
                surface_variant
            } else {
                surface_container
            }),
            stroke: if state.display_status.is_active() {
                Some(primary)
            } else {
                None
            },
            stroke_width: 1.0,
        });

        let icon_w = (cell_w * 0.56).clamp(12.0, 18.0);
        let icon_h = (slot_h * 0.50).clamp(10.0, 15.0);
        let icon_rect = Rect::new(
            slot_rect.x + (slot_rect.w - icon_w) * 0.5,
            slot_rect.y + (slot_rect.h - icon_h) * 0.5,
            icon_w,
            icon_h,
        );
        commands.push(PaintCmd::MonitorIcon {
            rect: icon_rect,
            color: if state.display_status.is_active() {
                primary
            } else {
                on_surface
            },
            stroke_width: 1.6,
        });

        if let Some(dot_color) =
            status_dot_color(&state.display_status, primary, secondary, error_col)
        {
            commands.push(PaintCmd::Circle {
                cx: slot_rect.x + slot_rect.w - 5.5,
                cy: slot_rect.y + 5.5,
                radius: 3.2,
                fill: dot_color,
            });
        }

        hit_targets.push(HitTarget {
            rect: slot_rect,
            id: "display".to_string(),
        });
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

        // 3. End cluster: Display Slot
        let slot_w = cell_h.max(28.0);
        let slot_x = (bw - pad - bar.border_width - slot_w).max(clock_rect.x + clock_rect.w + 8.0);
        let slot_rect = Rect::new(slot_x, pad, slot_w, cell_h);
        commands.push(PaintCmd::RoundedRect {
            rect: slot_rect,
            radius: inner_radius,
            fill: Some(if state.display_status.is_active() {
                surface_variant
            } else {
                surface_container
            }),
            stroke: if state.display_status.is_active() {
                Some(primary)
            } else {
                None
            },
            stroke_width: 1.0,
        });

        let icon_w = (slot_w * 0.56).clamp(12.0, 18.0);
        let icon_h = (cell_h * 0.54).clamp(10.0, 15.0);
        let icon_rect = Rect::new(
            slot_rect.x + (slot_rect.w - icon_w) * 0.5,
            slot_rect.y + (slot_rect.h - icon_h) * 0.5,
            icon_w,
            icon_h,
        );
        commands.push(PaintCmd::MonitorIcon {
            rect: icon_rect,
            color: if state.display_status.is_active() {
                primary
            } else {
                on_surface
            },
            stroke_width: 1.6,
        });

        if let Some(dot_color) =
            status_dot_color(&state.display_status, primary, secondary, error_col)
        {
            commands.push(PaintCmd::Circle {
                cx: slot_rect.x + slot_rect.w - 5.0,
                cy: slot_rect.y + 5.0,
                radius: 3.0,
                fill: dot_color,
            });
        }

        hit_targets.push(HitTarget {
            rect: slot_rect,
            id: "display".to_string(),
        });
    }

    SurfaceSpec {
        id: format!("bar:{}", output.name),
        namespace,
        output: Some(output.name.clone()),
        layer: Layer::Top,
        anchor,
        exclusive_zone,
        width,
        height,
        margin,
        corner_radius: bar.corner_radius,
        background: bg,
        border_color,
        border_width: bar.border_width,
        commands,
        hit_targets,
    }
}

fn status_dot_color(
    status: &DisplayStatus,
    primary: kaze_core::Color,
    secondary: kaze_core::Color,
    error: kaze_core::Color,
) -> Option<kaze_core::Color> {
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
    fn pointer_clicks_emit_workspace_dispatch_and_display_commands() {
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
                target_id: "display".into(),
                button: PointerButton::Left,
            },
            &mut ctx,
        );
        assert_eq!(
            ctx.actions,
            vec![ShellAction::SpawnCommand {
                program: "kaze-display".into(),
                args: vec!["--menu".into()],
            }]
        );

        ctx.actions.clear();
        ext.on_event(
            &SystemEvent::PointerClick {
                surface_id: "bar:Virtual-1".into(),
                target_id: "display".into(),
                button: PointerButton::Right,
            },
            &mut ctx,
        );
        assert_eq!(
            ctx.actions,
            vec![ShellAction::SpawnCommand {
                program: "kaze-display".into(),
                args: vec!["toggle-window-share".into()],
            }]
        );
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
}
