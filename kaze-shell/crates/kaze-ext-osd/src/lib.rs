#![deny(clippy::unwrap_used)]

use kaze_core::{
    Anchor, AppState, DirtyFlags, EdgeInsets, IconKind, IpcResult, KazeExtension, KeyboardMode,
    Layer, OsdKind, PaintCmd, Rect, ShellAction, ShellContext, SurfaceSpec, SystemEvent, TextAlign,
};

const OSD_TIMER_ID: &str = "osd:hide";

/// Ephemeral Overlay OSD (`kaze-osd`) for volume, mic mute, and screen brightness.
/// Returns `Vec::new()` when hidden so `kaze-ui` immediately drops the layer surface
/// and frees its SHM `SlotPool` down to 0 KiB.
pub struct OsdExtension {
    active_kind: Option<OsdKind>,
    cached_spec: Option<SurfaceSpec>,
}

impl Default for OsdExtension {
    fn default() -> Self {
        Self::new()
    }
}

impl OsdExtension {
    pub fn new() -> Self {
        Self {
            active_kind: None,
            cached_spec: None,
        }
    }

    fn show(&mut self, kind: OsdKind, ctx: &mut ShellContext) -> DirtyFlags {
        if !ctx.state.config.osd.enabled || ctx.state.island_absorbs_osd() {
            return self.hide(ctx);
        }
        self.active_kind = Some(kind);
        self.cached_spec = Some(build_osd_surface(ctx.state, kind));
        ctx.push_action(ShellAction::ScheduleTimer {
            id: OSD_TIMER_ID.to_string(),
            after_ms: ctx.state.config.osd.timeout_ms.max(250),
        });
        DirtyFlags::OSD
    }

    fn hide(&mut self, ctx: &mut ShellContext) -> DirtyFlags {
        if self.active_kind.is_none() && self.cached_spec.is_none() {
            return DirtyFlags::NONE;
        }
        self.active_kind = None;
        self.cached_spec = None;
        ctx.push_action(ShellAction::CancelTimer {
            id: OSD_TIMER_ID.to_string(),
        });
        DirtyFlags::OSD | DirtyFlags::LAYOUT
    }
}

impl KazeExtension for OsdExtension {
    fn id(&self) -> &'static str {
        "osd"
    }

    fn on_init(&mut self, _ctx: &mut ShellContext) {}

    fn on_event(&mut self, event: &SystemEvent, ctx: &mut ShellContext) -> DirtyFlags {
        match event {
            SystemEvent::AudioChanged {
                trigger_osd: Some(kind),
                ..
            } => self.show(*kind, ctx),
            SystemEvent::BacklightChanged {
                trigger_osd: true, ..
            } => self.show(OsdKind::Brightness, ctx),
            SystemEvent::TimerFired { id } if id == OSD_TIMER_ID => self.hide(ctx),
            SystemEvent::ConfigReloaded
            | SystemEvent::ThemeChanged(_)
            | SystemEvent::LayoutPresetChanged(_) => {
                if let Some(kind) = self.active_kind {
                    if ctx.state.config.osd.enabled && !ctx.state.island_absorbs_osd() {
                        self.cached_spec = Some(build_osd_surface(ctx.state, kind));
                        return DirtyFlags::OSD | DirtyFlags::THEME;
                    }
                    return self.hide(ctx);
                }
                DirtyFlags::NONE
            }
            _ => DirtyFlags::NONE,
        }
    }

    fn on_ipc(&mut self, cmd: &str, _args: &[String], ctx: &mut ShellContext) -> IpcResult {
        match cmd {
            "osd-hide" => {
                let dirty = self.hide(ctx);
                IpcResult::Handled {
                    ok: true,
                    message: "hidden".into(),
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

fn resolve_osd_anchor(position: &str, ox: i32, oy: i32) -> (Anchor, EdgeInsets) {
    match position {
        "top_left" => (
            Anchor::TOP | Anchor::LEFT,
            EdgeInsets {
                top: oy,
                left: ox,
                ..EdgeInsets::default()
            },
        ),
        "top_center" | "top" => (
            Anchor::TOP,
            EdgeInsets {
                top: oy,
                ..EdgeInsets::default()
            },
        ),
        "bottom_right" => (
            Anchor::BOTTOM | Anchor::RIGHT,
            EdgeInsets {
                bottom: oy,
                right: ox,
                ..EdgeInsets::default()
            },
        ),
        "bottom_center" | "bottom" => (
            Anchor::BOTTOM,
            EdgeInsets {
                bottom: oy,
                ..EdgeInsets::default()
            },
        ),
        _ => (
            Anchor::TOP | Anchor::RIGHT,
            EdgeInsets {
                top: oy,
                right: ox,
                ..EdgeInsets::default()
            },
        ),
    }
}

fn build_osd_surface(state: &AppState, kind: OsdKind) -> SurfaceSpec {
    let osd = &state.config.osd;
    let bar = &state.config.bar;
    let colors = state.palette.for_mode(state.theme_mode);

    let bg = colors.surface_color().with_opacity(bar.background_opacity);
    let border_color = colors.outline_variant_color();
    let primary = colors.primary_color();
    let error_col = colors.error_color();
    let on_surface = colors.on_surface_color();
    let track_bg = colors.surface_container_color();

    let (icon, pct, accent, label) = match kind {
        OsdKind::Volume => {
            if state.audio.muted {
                (IconKind::VolumeMuted, 0u8, error_col, "MUTE".to_string())
            } else {
                let p = state.audio.volume_pct;
                (IconKind::Volume, p, primary, format!("{p}%"))
            }
        }
        OsdKind::Mic => {
            if state.audio.mic_muted {
                (IconKind::MicMuted, 0u8, error_col, "MIC OFF".to_string())
            } else {
                (IconKind::MicMuted, 100u8, primary, "MIC ON".to_string())
            }
        }
        OsdKind::Brightness => {
            let p = state.backlight.percentage;
            (IconKind::Brightness, p, primary, format!("{p}%"))
        }
        OsdKind::KeyboardLayout => (
            IconKind::Keyboard,
            100u8,
            primary,
            state.keyboard.layout_label.clone(),
        ),
        OsdKind::LockKeys => {
            let txt = if state.keyboard.caps_lock {
                "CAPS"
            } else if state.keyboard.num_lock {
                "NUM"
            } else {
                "SCROLL"
            };
            (IconKind::LockKey, 100u8, primary, txt.to_string())
        }
    };

    let w = osd.width.max(160) as f32;
    let h = osd.height.max(36) as f32;
    let pad = 12.0f32;
    let icon_size = 18.0f32;
    let label_w = 50.0f32;
    let bar_x = pad + icon_size + 10.0;
    let bar_w = (w - bar_x - label_w - pad - 6.0).max(40.0);
    let bar_h = 8.0f32;
    let bar_y = (h - bar_h) * 0.5;
    let radius = bar
        .corner_radius
        .max(state.layout_preset.overlay_corner_radius());
    let border_w = state.layout_preset.overlay_border_width();
    let inner_r = if radius > 0.0 { 4.0 } else { 0.0 };

    let mut commands = Vec::with_capacity(4);
    commands.push(PaintCmd::Icon {
        rect: Rect::new(pad, (h - icon_size) * 0.5, icon_size, icon_size),
        kind: icon,
        color: accent,
        stroke_width: 1.7,
        level: Some(pct.min(100)),
    });

    // Progress track
    commands.push(PaintCmd::RoundedRect {
        rect: Rect::new(bar_x, bar_y, bar_w, bar_h),
        radius: inner_r,
        fill: Some(track_bg),
        stroke: None,
        stroke_width: 0.0,
    });

    // Progress fill
    let fill_frac = f32::from(pct.min(100)) / 100.0;
    let fill_w = (bar_w * fill_frac).round();
    if fill_w >= 1.0 {
        commands.push(PaintCmd::RoundedRect {
            rect: Rect::new(bar_x, bar_y, fill_w, bar_h),
            radius: inner_r,
            fill: Some(accent),
            stroke: None,
            stroke_width: 0.0,
        });
    }

    // Numeric / status label
    commands.push(PaintCmd::Text {
        rect: Rect::new(w - pad - label_w, 0.0, label_w, h),
        text: label,
        color: on_surface,
        size: 12.0,
        bold: true,
        align: TextAlign::Right,
    });

    let (anchor, margin) = resolve_osd_anchor(&osd.position, osd.offset_x, osd.offset_y);
    SurfaceSpec {
        id: "osd:main".to_string(),
        namespace: "kaze-osd".to_string(),
        output: None,
        layer: Layer::Overlay,
        keyboard_interactivity: KeyboardMode::None,
        anchor,
        exclusive_zone: 0,
        width: osd.width.max(160),
        height: osd.height.max(36),
        margin,
        corner_radius: radius,
        background: bg,
        border_color,
        border_width: border_w,
        commands,
        hit_targets: Vec::new(),
        animating: false,
        input_regions: None,
        ime_cursor_rect: None,
        track_pointer_motion: false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use kaze_core::{AudioState, Config};

    #[test]
    fn osd_starts_hidden_shows_on_volume_change_and_drops_surface_on_timer() {
        let mut state = AppState::new(Config::default());
        let mut ext = OsdExtension::new();
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_init(&mut ctx);
        }
        assert!(ext.surfaces().is_empty());

        let audio = AudioState {
            available: true,
            volume_pct: 65,
            muted: false,
            mic_muted: false,
            sink_name: "default".into(),
            source_name: String::new(),
            ..AudioState::default()
        };
        state.audio = audio.clone();
        {
            let mut ctx = ShellContext::new(&mut state);
            let dirty = ext.on_event(
                &SystemEvent::AudioChanged {
                    state: audio,
                    trigger_osd: Some(OsdKind::Volume),
                },
                &mut ctx,
            );
            assert!(dirty.contains(DirtyFlags::OSD));
            assert!(matches!(
                ctx.actions.as_slice(),
                [ShellAction::ScheduleTimer { id, after_ms: 1500 }] if id == OSD_TIMER_ID
            ));
        }
        let specs = ext.surfaces();
        assert_eq!(specs.len(), 1);
        assert_eq!(specs[0].namespace, "kaze-osd");
        assert_eq!(specs[0].layer, Layer::Overlay);

        {
            let mut ctx = ShellContext::new(&mut state);
            let dirty = ext.on_event(
                &SystemEvent::TimerFired {
                    id: OSD_TIMER_ID.into(),
                },
                &mut ctx,
            );
            assert!(dirty.contains(DirtyFlags::OSD));
        }
        assert!(ext.surfaces().is_empty());
    }
}
