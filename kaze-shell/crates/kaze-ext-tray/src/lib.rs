#![deny(clippy::unwrap_used)]

use kaze_core::{
    Anchor, AppState, DirtyFlags, EdgeInsets, HitTarget, IpcResult, KazeExtension, KeyEvent,
    KeyboardMode, Layer, LayoutPreset, PaintCmd, PointerButton, Rect, ShellAction, ShellContext,
    SurfaceSpec, SystemEvent, TextAlign, TrayMenuState,
};

const SURFACE_ID: &str = "tray:menu";
const NAMESPACE: &str = "kaze-tray-menu";
const KEY_ESCAPE: u32 = 0xff1b;

/// Transient System Tray DBusMenu popup extension (`kaze-tray-menu`).
///
/// Opens strictly on demand when `SystemEvent::TrayMenuLoaded` arrives (right-click on an SNI
/// tray icon in the bar), dispatches `ShellAction::TrayMenuClick` on selection, and immediately
/// drops its Wayland layer surface & SHM `SlotPool` on close.
pub struct TrayExtension {
    menu: Option<TrayMenuState>,
    cached_spec: Option<SurfaceSpec>,
}

impl Default for TrayExtension {
    fn default() -> Self {
        Self::new()
    }
}

impl TrayExtension {
    pub fn new() -> Self {
        Self {
            menu: None,
            cached_spec: None,
        }
    }

    pub fn is_open(&self) -> bool {
        self.menu.is_some()
    }

    fn close(&mut self) -> DirtyFlags {
        if self.menu.take().is_some() {
            self.cached_spec = None;
            DirtyFlags::TRAY | DirtyFlags::LAYOUT
        } else {
            DirtyFlags::NONE
        }
    }

    fn rebuild(&mut self, state: &AppState) {
        self.cached_spec = self
            .menu
            .as_ref()
            .map(|m| build_tray_menu_surface(state, m));
    }
}

impl KazeExtension for TrayExtension {
    fn id(&self) -> &'static str {
        "tray"
    }

    fn on_init(&mut self, _ctx: &mut ShellContext) {}

    fn on_event(&mut self, event: &SystemEvent, ctx: &mut ShellContext) -> DirtyFlags {
        match event {
            SystemEvent::TrayMenuLoaded(menu) => {
                if menu.items.is_empty() {
                    return self.close();
                }
                self.menu = Some(menu.clone());
                self.rebuild(ctx.state);
                DirtyFlags::TRAY | DirtyFlags::LAYOUT
            }
            SystemEvent::PointerClick {
                surface_id,
                target_id,
                button,
            } if surface_id == SURFACE_ID => {
                if *button == PointerButton::Right {
                    return self.close();
                }
                if *button == PointerButton::Left {
                    if let Some(id_str) = target_id.strip_prefix("tray:menu-item:") {
                        if let Ok(item_id) = id_str.parse::<i32>() {
                            if let Some(ref menu) = self.menu {
                                let valid = menu
                                    .items
                                    .iter()
                                    .any(|it| it.id == item_id && it.enabled && !it.separator);
                                if valid {
                                    ctx.push_action(ShellAction::TrayMenuClick {
                                        service: menu.service.clone(),
                                        menu_path: menu.menu_path.clone(),
                                        item_id,
                                    });
                                    return self.close();
                                }
                            }
                        }
                    }
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
            } if surface_id == SURFACE_ID => self.close(),
            SystemEvent::SurfaceClosed { surface_id }
            | SystemEvent::KeyboardFocusLost { surface_id }
                if surface_id == SURFACE_ID =>
            {
                self.close()
            }
            SystemEvent::ConfigReloaded
            | SystemEvent::ThemeChanged(_)
            | SystemEvent::LayoutPresetChanged(_) => {
                if self.menu.is_some() {
                    self.rebuild(ctx.state);
                    DirtyFlags::TRAY
                } else {
                    DirtyFlags::NONE
                }
            }
            _ => DirtyFlags::NONE,
        }
    }

    fn on_ipc(&mut self, cmd: &str, args: &[String], ctx: &mut ShellContext) -> IpcResult {
        match cmd {
            "tray-menu-close" => {
                let dirty = self.close();
                IpcResult::Handled {
                    ok: true,
                    message: "closed".into(),
                    dirty,
                }
            }
            "tray-list" => {
                let list: Vec<String> = ctx
                    .state
                    .tray_items
                    .iter()
                    .map(|i| format!("{}\t{}\t{}", i.id, i.service, i.menu_path))
                    .collect();
                IpcResult::Handled {
                    ok: true,
                    message: list.join("\n"),
                    dirty: DirtyFlags::NONE,
                }
            }
            "tray-open-menu" => {
                let target = args.first().map(String::as_str);
                let found =
                    match target {
                        Some(query) => ctx.state.tray_items.iter().find(|i| {
                            (i.id == query || i.service == query) && !i.menu_path.is_empty()
                        }),
                        None => ctx
                            .state
                            .tray_items
                            .iter()
                            .find(|i| !i.menu_path.is_empty()),
                    }
                    .map(|it| (it.id.clone(), it.service.clone(), it.menu_path.clone()));
                if let Some((id, service, menu_path)) = found {
                    ctx.push_action(ShellAction::TrayOpenMenu { service, menu_path });
                    IpcResult::Handled {
                        ok: true,
                        message: format!("requested menu for {id}"),
                        dirty: DirtyFlags::NONE,
                    }
                } else {
                    IpcResult::Handled {
                        ok: false,
                        message: "no tray item with dbusmenu".into(),
                        dirty: DirtyFlags::NONE,
                    }
                }
            }
            _ => IpcResult::Unhandled,
        }
    }

    fn surfaces(&self) -> Vec<SurfaceSpec> {
        self.cached_spec.clone().into_iter().collect()
    }
}

fn build_tray_menu_surface(state: &AppState, menu: &TrayMenuState) -> SurfaceSpec {
    let colors = state.palette.for_mode(state.theme_mode);
    let bg = colors
        .surface_color()
        .with_opacity(state.config.bar.background_opacity.max(0.95));
    let primary = colors.primary_color();
    let on_surface = colors.on_surface_color();
    let muted = colors.on_surface_variant_color();
    let outline_variant = colors.outline_variant_color();
    let surface_container = colors.surface_container_color();

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

    let w = 232.0f32;
    let pad = 6.0f32;
    let row_h = 28.0f32;
    let sep_h = 9.0f32;

    let mut commands = Vec::with_capacity(menu.items.len() * 2 + 2);
    let mut hit_targets = Vec::with_capacity(menu.items.len());
    let mut y = border_w + pad;

    for item in menu.items.iter().take(18) {
        if item.separator {
            commands.push(PaintCmd::Line {
                x1: border_w + 10.0,
                y1: y + sep_h * 0.5,
                x2: w - border_w - 10.0,
                y2: y + sep_h * 0.5,
                color: outline_variant,
                width: 1.0,
            });
            y += sep_h;
            continue;
        }
        let rect = Rect::new(border_w + 4.0, y, w - border_w * 2.0 - 8.0, row_h - 2.0);
        if item.enabled {
            commands.push(PaintCmd::RoundedRect {
                rect,
                radius: if radius > 0.0 { 4.0 } else { 0.0 },
                fill: Some(surface_container.with_opacity(0.65)),
                stroke: None,
                stroke_width: 0.0,
            });
            hit_targets.push(HitTarget {
                rect,
                id: format!("tray:menu-item:{}", item.id),
            });
        }
        let label = if item.toggle_state == 1 {
            format!("✓ {}", item.label)
        } else {
            item.label.clone()
        };
        commands.push(PaintCmd::RichText {
            rect: Rect::new(rect.x + 10.0, rect.y + 4.0, rect.w - 18.0, row_h - 6.0),
            text: label,
            color: if item.enabled { on_surface } else { muted },
            size: 11.5,
            bold: false,
            align: TextAlign::Left,
            max_lines: 1,
        });
        y += row_h;
    }
    y += pad + border_w;

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
        width: w as u32,
        height: (y.ceil() as u32).max(40),
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

#[cfg(test)]
mod tests {
    use super::*;
    use kaze_core::{Config, TrayMenuEntry};

    #[test]
    fn opens_on_menu_loaded_dispatches_click_and_frees_surface() {
        let mut state = AppState::new(Config::default());
        let mut ext = TrayExtension::new();
        assert!(ext.surfaces().is_empty());

        let menu = TrayMenuState {
            service: ":1.99".into(),
            menu_path: "/MenuBar".into(),
            items: vec![
                TrayMenuEntry {
                    id: 1,
                    label: "Open App".into(),
                    enabled: true,
                    separator: false,
                    toggle_state: -1,
                },
                TrayMenuEntry {
                    id: 2,
                    label: String::new(),
                    enabled: false,
                    separator: true,
                    toggle_state: -1,
                },
                TrayMenuEntry {
                    id: 3,
                    label: "Quit".into(),
                    enabled: true,
                    separator: false,
                    toggle_state: -1,
                },
            ],
        };

        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_event(&SystemEvent::TrayMenuLoaded(menu), &mut ctx);
        }
        let specs = ext.surfaces();
        assert_eq!(specs.len(), 1);
        assert_eq!(specs[0].namespace, "kaze-tray-menu");
        assert_eq!(specs[0].hit_targets.len(), 2);

        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_event(
                &SystemEvent::PointerClick {
                    surface_id: SURFACE_ID.into(),
                    target_id: "tray:menu-item:3".into(),
                    button: PointerButton::Left,
                },
                &mut ctx,
            );
            assert_eq!(
                ctx.actions,
                vec![ShellAction::TrayMenuClick {
                    service: ":1.99".into(),
                    menu_path: "/MenuBar".into(),
                    item_id: 3,
                }]
            );
        }
        assert!(ext.surfaces().is_empty());
    }
}
