#![deny(clippy::unwrap_used)]

use kaze_core::{
    t, Anchor, AppState, DirtyFlags, EdgeInsets, HitTarget, I18nKey, IpcResult, KazeExtension,
    KeyEvent, KeyboardMode, Layer, PaintCmd, PointerButton, Rect, ShellAction, ShellContext,
    SurfaceSpec, SystemEvent, TextAlign,
};

const SURFACE_ID: &str = "session:main";
const NAMESPACE: &str = "kaze-session-menu";

const KEY_ESCAPE: u32 = 0xff1b;
const KEY_RETURN: u32 = 0xff0d;
const KEY_KP_ENTER: u32 = 0xff8d;
const KEY_UP: u32 = 0xff52;
const KEY_DOWN: u32 = 0xff54;
const KEY_LEFT: u32 = 0xff51;
const KEY_RIGHT: u32 = 0xff53;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionActionKind {
    Lock,
    Suspend,
    Hibernate,
    Logout,
    Reboot,
    RebootUefi,
    Shutdown,
}

impl SessionActionKind {
    const ALL: &'static [Self] = &[
        Self::Lock,
        Self::Suspend,
        Self::Hibernate,
        Self::Logout,
        Self::Reboot,
        Self::RebootUefi,
        Self::Shutdown,
    ];

    pub fn shortcut_char(self) -> char {
        match self {
            Self::Lock => 'l',
            Self::Suspend => 's',
            Self::Hibernate => 'h',
            Self::Logout => 'e',
            Self::Reboot => 'r',
            Self::RebootUefi => 'u',
            Self::Shutdown => 'p',
        }
    }

    pub fn label(self, loc: kaze_core::Locale) -> &'static str {
        match self {
            Self::Lock => t(loc, I18nKey::PowerLock),
            Self::Suspend => t(loc, I18nKey::PowerSuspend),
            Self::Hibernate => t(loc, I18nKey::PowerHibernate),
            Self::Logout => t(loc, I18nKey::PowerLogout),
            Self::Reboot => t(loc, I18nKey::PowerReboot),
            Self::RebootUefi => t(loc, I18nKey::PowerRebootUefi),
            Self::Shutdown => t(loc, I18nKey::PowerShutdown),
        }
    }

    pub fn is_supported(self, state: &AppState) -> bool {
        let caps = &state.power_capabilities;
        match self {
            Self::Lock | Self::Logout => true,
            Self::Suspend => caps.can_suspend,
            Self::Hibernate => caps.can_hibernate,
            Self::Reboot => caps.can_reboot,
            Self::RebootUefi => caps.can_reboot_to_uefi,
            Self::Shutdown => caps.can_poweroff,
        }
    }

    pub fn id(self) -> &'static str {
        match self {
            Self::Lock => "lock",
            Self::Suspend => "suspend",
            Self::Hibernate => "hibernate",
            Self::Logout => "logout",
            Self::Reboot => "reboot",
            Self::RebootUefi => "reboot-uefi",
            Self::Shutdown => "poweroff",
        }
    }
}

pub struct SessionMenuExtension {
    open: bool,
    selected: usize,
    pending_confirm: Option<SessionActionKind>,
    cached_spec: Option<SurfaceSpec>,
}

impl Default for SessionMenuExtension {
    fn default() -> Self {
        Self::new()
    }
}

impl SessionMenuExtension {
    pub fn new() -> Self {
        Self {
            open: false,
            selected: 0,
            pending_confirm: None,
            cached_spec: None,
        }
    }

    pub fn visible_actions(state: &AppState) -> Vec<SessionActionKind> {
        SessionActionKind::ALL
            .iter()
            .copied()
            .filter(|a| a.is_supported(state))
            .collect()
    }

    fn open_menu(&mut self, state: &AppState) -> DirtyFlags {
        self.open = true;
        self.selected = 0;
        self.pending_confirm = None;
        self.rebuild(state);
        DirtyFlags::SESSION | DirtyFlags::LAYOUT
    }

    fn close_menu(&mut self) -> DirtyFlags {
        if !self.open {
            return DirtyFlags::NONE;
        }
        self.open = false;
        self.pending_confirm = None;
        self.cached_spec = None;
        DirtyFlags::SESSION | DirtyFlags::LAYOUT
    }

    fn trigger_action(&mut self, action: SessionActionKind, ctx: &mut ShellContext) -> DirtyFlags {
        if ctx.state.config.session.confirm
            && action != SessionActionKind::Lock
            && self.pending_confirm != Some(action)
        {
            self.pending_confirm = Some(action);
            self.rebuild(ctx.state);
            return DirtyFlags::SESSION;
        }

        self.close_menu();
        match action {
            SessionActionKind::Lock => ctx.push_action(ShellAction::LockSession),
            SessionActionKind::Suspend => {
                ctx.push_action(ShellAction::RunHook {
                    event: "suspending".into(),
                    old: None,
                    new: None,
                    value: None,
                });
                ctx.push_action(ShellAction::SystemPower("suspend".into()));
            }
            SessionActionKind::Hibernate => {
                ctx.push_action(ShellAction::RunHook {
                    event: "suspending".into(),
                    old: None,
                    new: None,
                    value: None,
                });
                ctx.push_action(ShellAction::SystemPower("hibernate".into()));
            }
            SessionActionKind::Logout => {
                ctx.push_action(ShellAction::RunHook {
                    event: "stopping".into(),
                    old: None,
                    new: None,
                    value: None,
                });
                if ctx.state.power_capabilities.uwsm_active {
                    ctx.push_action(ShellAction::SpawnCommand {
                        program: "uwsm".into(),
                        args: vec!["stop".into()],
                    });
                } else {
                    ctx.push_action(ShellAction::HyprDispatch("exit".into()));
                }
            }
            SessionActionKind::Reboot => {
                ctx.push_action(ShellAction::RunHook {
                    event: "rebooting".into(),
                    old: None,
                    new: None,
                    value: None,
                });
                ctx.push_action(ShellAction::SystemPower("reboot".into()));
            }
            SessionActionKind::RebootUefi => {
                ctx.push_action(ShellAction::RunHook {
                    event: "rebooting".into(),
                    old: None,
                    new: None,
                    value: None,
                });
                ctx.push_action(ShellAction::SystemPower("reboot-uefi".into()));
            }
            SessionActionKind::Shutdown => {
                ctx.push_action(ShellAction::RunHook {
                    event: "stopping".into(),
                    old: None,
                    new: None,
                    value: None,
                });
                ctx.push_action(ShellAction::SystemPower("poweroff".into()));
            }
        }
        DirtyFlags::SESSION | DirtyFlags::LAYOUT
    }

    fn handle_key(&mut self, key: &KeyEvent, ctx: &mut ShellContext) -> DirtyFlags {
        if !self.open || !key.pressed {
            return DirtyFlags::NONE;
        }
        let actions = Self::visible_actions(ctx.state);
        if actions.is_empty() {
            return self.close_menu();
        }
        if key.keysym == KEY_ESCAPE {
            if self.pending_confirm.is_some() {
                self.pending_confirm = None;
                self.rebuild(ctx.state);
                return DirtyFlags::SESSION;
            }
            return self.close_menu();
        }
        if matches!(key.keysym, KEY_RETURN | KEY_KP_ENTER) {
            let act = actions[self.selected.min(actions.len() - 1)];
            return self.trigger_action(act, ctx);
        }
        if matches!(key.keysym, KEY_DOWN | KEY_RIGHT) {
            self.selected = (self.selected + 1) % actions.len();
            self.pending_confirm = None;
            self.rebuild(ctx.state);
            return DirtyFlags::SESSION;
        }
        if matches!(key.keysym, KEY_UP | KEY_LEFT) {
            self.selected = (self.selected + actions.len() - 1) % actions.len();
            self.pending_confirm = None;
            self.rebuild(ctx.state);
            return DirtyFlags::SESSION;
        }
        if let Some(ref utf8) = key.utf8 {
            if let Some(ch) = utf8.chars().next().map(|c| c.to_ascii_lowercase()) {
                if let Some((idx, &act)) = actions
                    .iter()
                    .enumerate()
                    .find(|(_, a)| a.shortcut_char() == ch)
                {
                    self.selected = idx;
                    return self.trigger_action(act, ctx);
                }
            }
        }
        DirtyFlags::NONE
    }

    fn rebuild(&mut self, state: &AppState) {
        if !self.open {
            self.cached_spec = None;
            return;
        }
        self.cached_spec = Some(build_session_surface(
            state,
            self.selected,
            self.pending_confirm,
        ));
    }
}

impl KazeExtension for SessionMenuExtension {
    fn id(&self) -> &'static str {
        "session"
    }

    fn on_init(&mut self, _ctx: &mut ShellContext) {}

    fn on_event(&mut self, event: &SystemEvent, ctx: &mut ShellContext) -> DirtyFlags {
        match event {
            SystemEvent::KeyInput { surface_id, key } if surface_id == SURFACE_ID => {
                self.handle_key(key, ctx)
            }
            SystemEvent::PointerClick {
                surface_id,
                target_id,
                button,
            } if surface_id == SURFACE_ID => {
                if *button == PointerButton::Right {
                    return self.close_menu();
                }
                if *button == PointerButton::Left {
                    if let Some(act_id) = target_id.strip_prefix("session:act:") {
                        if let Some(act) = Self::visible_actions(ctx.state)
                            .into_iter()
                            .find(|a| a.id() == act_id)
                        {
                            return self.trigger_action(act, ctx);
                        }
                    }
                }
                DirtyFlags::NONE
            }
            SystemEvent::SurfaceClosed { surface_id }
            | SystemEvent::KeyboardFocusLost { surface_id }
                if surface_id == SURFACE_ID =>
            {
                self.close_menu()
            }
            SystemEvent::PowerCapabilitiesChanged(_)
            | SystemEvent::LocaleChanged(_)
            | SystemEvent::ThemeChanged(_)
            | SystemEvent::ConfigReloaded => {
                if self.open {
                    self.rebuild(ctx.state);
                    DirtyFlags::SESSION | DirtyFlags::THEME
                } else {
                    DirtyFlags::NONE
                }
            }
            _ => DirtyFlags::NONE,
        }
    }

    fn on_ipc(&mut self, cmd: &str, _args: &[String], ctx: &mut ShellContext) -> IpcResult {
        match cmd {
            "session-menu-toggle" => {
                let dirty = if self.open {
                    self.close_menu()
                } else {
                    self.open_menu(ctx.state)
                };
                IpcResult::Handled {
                    ok: true,
                    message: if self.open { "opened" } else { "closed" }.into(),
                    dirty,
                }
            }
            _ => IpcResult::Unhandled,
        }
    }

    fn surfaces(&self) -> Vec<SurfaceSpec> {
        self.cached_spec.iter().cloned().collect()
    }
}

fn build_session_surface(
    state: &AppState,
    selected: usize,
    pending_confirm: Option<SessionActionKind>,
) -> SurfaceSpec {
    let actions = SessionMenuExtension::visible_actions(state);
    let colors = state.palette.for_mode(state.theme_mode);
    let loc = state.locale;
    let bar = &state.config.bar;

    let bg = colors.surface_color().with_opacity(bar.background_opacity);
    let primary = colors.primary_color();
    let error = colors.error_color();
    let on_surface = colors.on_surface_color();
    let muted = colors.on_surface_variant_color();
    let surface_container = colors.surface_container_color();
    let surface_variant = colors.surface_variant_color();

    let border_w = bar.border_width.max(2.0);
    let w = 360u32;
    let pad = border_w + 14.0;
    let header_h = 34.0f32;
    let row_h = 40.0f32;
    let count = actions.len().max(1);
    let total_h = (border_w * 2.0 + header_h + count as f32 * row_h + 12.0).ceil() as u32;

    let mut commands = Vec::with_capacity(count * 4 + 4);
    let mut hit_targets = Vec::with_capacity(count);

    commands.push(PaintCmd::RichText {
        rect: Rect::new(pad, border_w + 8.0, w as f32 - pad * 2.0, 22.0),
        text: t(loc, I18nKey::SessionMenuTitle).to_string(),
        color: primary,
        size: 13.0,
        bold: true,
        align: TextAlign::Center,
        max_lines: 1,
    });

    for (idx, act) in actions.iter().enumerate() {
        let ry = border_w + header_h + idx as f32 * row_h;
        let rect = Rect::new(pad, ry, w as f32 - pad * 2.0, row_h - 4.0);
        let is_confirm = pending_confirm == Some(*act);
        let is_sel = idx == selected.min(actions.len().saturating_sub(1));

        commands.push(PaintCmd::RoundedRect {
            rect,
            radius: 6.0,
            fill: Some(if is_confirm {
                error.with_opacity(0.24)
            } else if is_sel {
                surface_variant
            } else {
                surface_container
            }),
            stroke: if is_confirm {
                Some(error)
            } else if is_sel {
                Some(primary)
            } else {
                None
            },
            stroke_width: if is_confirm || is_sel { 1.5 } else { 0.0 },
        });

        let label = if is_confirm {
            format!("{} — {}", act.label(loc), t(loc, I18nKey::ConfirmPrompt))
        } else {
            act.label(loc).to_string()
        };
        commands.push(PaintCmd::RichText {
            rect: Rect::new(rect.x + 12.0, ry + 7.0, rect.w - 48.0, 22.0),
            text: label,
            color: if is_confirm { error } else { on_surface },
            size: 13.0,
            bold: is_sel || is_confirm,
            align: TextAlign::Left,
            max_lines: 1,
        });
        commands.push(PaintCmd::Text {
            rect: Rect::new(rect.x + rect.w - 34.0, ry + 9.0, 24.0, 18.0),
            text: format!("[{}]", act.shortcut_char().to_ascii_uppercase()),
            color: muted,
            size: 10.5,
            bold: true,
            align: TextAlign::Right,
        });
        hit_targets.push(HitTarget {
            rect,
            id: format!("session:act:{}", act.id()),
        });
    }

    SurfaceSpec {
        id: SURFACE_ID.to_string(),
        namespace: NAMESPACE.to_string(),
        output: None,
        layer: Layer::Overlay,
        keyboard_interactivity: KeyboardMode::Exclusive,
        anchor: Anchor::empty(),
        exclusive_zone: 0,
        width: w,
        height: total_h,
        margin: EdgeInsets::default(),
        corner_radius: bar
            .corner_radius
            .max(state.layout_preset.overlay_corner_radius()),
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
    use kaze_core::{Config, KeyModifiers, PowerCapabilities};

    #[test]
    fn hides_unsupported_hibernate_and_uefi_and_uses_uwsm_logout() {
        let mut state = AppState::new(Config::default());
        state.power_capabilities = PowerCapabilities {
            can_suspend: true,
            can_hibernate: false,
            can_reboot: true,
            can_poweroff: true,
            can_reboot_to_uefi: false,
            uwsm_active: true,
        };
        let visible = SessionMenuExtension::visible_actions(&state);
        assert!(!visible.contains(&SessionActionKind::Hibernate));
        assert!(!visible.contains(&SessionActionKind::RebootUefi));
        assert!(visible.contains(&SessionActionKind::Logout));

        let mut ext = SessionMenuExtension::new();
        let mut ctx = ShellContext::new(&mut state);
        ext.on_ipc("session-menu-toggle", &[], &mut ctx);
        assert_eq!(ext.surfaces().len(), 1);

        // Two-step confirmation for Logout ('e' -> armed, 'e' -> executes `uwsm stop`)
        let key_e = SystemEvent::KeyInput {
            surface_id: SURFACE_ID.into(),
            key: KeyEvent {
                keysym: b'e' as u32,
                utf8: Some("e".into()),
                modifiers: KeyModifiers::default(),
                pressed: true,
            },
        };
        ext.on_event(&key_e, &mut ctx);
        assert!(ctx.actions.is_empty());
        ext.on_event(&key_e, &mut ctx);
        assert!(ctx.actions.contains(&ShellAction::SpawnCommand {
            program: "uwsm".into(),
            args: vec!["stop".into()],
        }));
        assert!(ext.surfaces().is_empty());
    }
}
