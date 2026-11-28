#![deny(clippy::unwrap_used)]

use kaze_core::text_input::{TextInputOutcome, TextInputState};
use kaze_core::{
    t, Anchor, DirtyFlags, EdgeInsets, HitTarget, I18nKey, IpcResult, KazeExtension, KeyboardMode,
    Layer, PaintCmd, PointerButton, PolkitRequest, Rect, ShellAction, ShellContext, SurfaceSpec,
    SystemEvent, TextAlign,
};
use std::collections::VecDeque;
use unicode_segmentation::UnicodeSegmentation;
use zeroize::Zeroize;

const SURFACE_ID: &str = "polkit:modal";
const NAMESPACE: &str = "kaze-polkit";
const PANEL_W: u32 = 430;
const PANEL_H: u32 = 290;

const KEY_TAB: u32 = 0xff09;

#[derive(Debug, Clone)]
struct PolkitSessionState {
    request: PolkitRequest,
    selected_identity: usize,
    prompt: String,
    echo: bool,
    error: Option<String>,
    submitting: bool,
}

pub struct PolkitExtension {
    active: Option<PolkitSessionState>,
    queue: VecDeque<PolkitRequest>,
    input: TextInputState,
    cached_spec: Option<SurfaceSpec>,
}

impl Default for PolkitExtension {
    fn default() -> Self {
        Self::new()
    }
}

impl PolkitExtension {
    pub fn new() -> Self {
        Self {
            active: None,
            queue: VecDeque::new(),
            input: TextInputState::new(true),
            cached_spec: None,
        }
    }

    pub fn active_cookie(&self) -> Option<&str> {
        self.active.as_ref().map(|a| a.request.cookie.as_str())
    }

    pub fn queued_len(&self) -> usize {
        self.queue.len()
    }

    fn activate_next(&mut self, locale: kaze_core::Locale) {
        self.input.clear();
        if let Some(req) = self.queue.pop_front() {
            self.active = Some(PolkitSessionState {
                selected_identity: 0,
                prompt: t(locale, I18nKey::LockPasswordPlaceholder).to_string(),
                echo: false,
                error: None,
                submitting: false,
                request: req,
            });
        } else {
            self.active = None;
        }
    }

    fn current_user(sess: &PolkitSessionState, fallback_user: &str) -> String {
        sess.request
            .identities
            .get(sess.selected_identity)
            .cloned()
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| {
                if fallback_user.trim().is_empty() {
                    "root".to_string()
                } else {
                    fallback_user.to_string()
                }
            })
    }

    fn submit(&mut self, ctx: &mut ShellContext) -> DirtyFlags {
        let Some(ref mut sess) = self.active else {
            return DirtyFlags::NONE;
        };
        if sess.submitting {
            return DirtyFlags::NONE;
        }
        sess.submitting = true;
        sess.error = None;
        let cookie = sess.request.cookie.clone();
        let user = Self::current_user(sess, &ctx.state.user_account.username);
        let mut pw = std::mem::take(&mut self.input.text);
        self.input.clear();
        ctx.push_action(ShellAction::PolkitSubmitPassword {
            cookie,
            user,
            password: std::mem::take(&mut pw),
        });
        pw.zeroize();
        self.rebuild(ctx.state);
        DirtyFlags::POLKIT
    }

    fn cancel_active(&mut self, ctx: &mut ShellContext) -> DirtyFlags {
        let Some(sess) = self.active.take() else {
            return DirtyFlags::NONE;
        };
        self.input.clear();
        ctx.push_action(ShellAction::PolkitCancel {
            cookie: sess.request.cookie,
        });
        let next = self.queue.pop_front();
        if let Some(req) = next {
            self.active = Some(PolkitSessionState {
                selected_identity: 0,
                prompt: t(ctx.state.locale, I18nKey::LockPasswordPlaceholder).to_string(),
                echo: false,
                error: None,
                submitting: false,
                request: req,
            });
        }
        self.rebuild(ctx.state);
        DirtyFlags::POLKIT | DirtyFlags::LAYOUT
    }

    fn rebuild(&mut self, state: &kaze_core::AppState) {
        let Some(ref sess) = self.active else {
            self.cached_spec = None;
            return;
        };
        let colors = state.palette.for_mode(state.theme_mode);
        let bg = colors
            .surface_color()
            .with_opacity(state.config.bar.background_opacity.max(0.92));
        let fg = colors.on_surface_color();
        let muted = colors.on_surface_variant_color();
        let accent = colors.primary_color();
        let urgent = colors.error_color();
        let surface_alt = colors.surface_container_color();
        let border = colors.surface_variant_color();
        let on_accent = colors.on_primary_color();
        let loc = state.locale;
        let w = PANEL_W as f32;
        let h = PANEL_H as f32;

        let mut commands = Vec::new();
        let mut hit_targets = Vec::new();

        commands.push(PaintCmd::RichText {
            rect: Rect::new(22.0, 18.0, w - 44.0, 28.0),
            text: t(loc, I18nKey::PolkitAuthenticate).to_string(),
            color: fg,
            size: 17.0,
            bold: true,
            align: TextAlign::Left,
            max_lines: 1,
        });

        let msg = if sess.request.message.trim().is_empty() {
            sess.request.action_id.as_str()
        } else {
            sess.request.message.as_str()
        };
        commands.push(PaintCmd::RichText {
            rect: Rect::new(22.0, 48.0, w - 44.0, 44.0),
            text: msg.to_string(),
            color: muted,
            size: 13.0,
            bold: false,
            align: TextAlign::Left,
            max_lines: 2,
        });

        let user = Self::current_user(sess, &state.user_account.username);
        let id_label = if sess.request.identities.len() > 1 {
            format!("{user}  ▾  ({})", sess.request.action_id)
        } else {
            format!("{user}  •  {}", sess.request.action_id)
        };
        let id_rect = Rect::new(22.0, 96.0, w - 44.0, 26.0);
        commands.push(PaintCmd::RoundedRect {
            rect: id_rect,
            radius: 6.0,
            fill: Some(surface_alt),
            stroke: None,
            stroke_width: 0.0,
        });
        commands.push(PaintCmd::RichText {
            rect: Rect::new(30.0, 98.0, w - 60.0, 22.0),
            text: id_label,
            color: accent,
            size: 12.0,
            bold: true,
            align: TextAlign::Left,
            max_lines: 1,
        });
        if sess.request.identities.len() > 1 {
            hit_targets.push(HitTarget {
                rect: id_rect,
                id: "polkit:identity".into(),
            });
        }

        let input_rect = Rect::new(22.0, 134.0, w - 44.0, 40.0);
        commands.push(PaintCmd::RoundedRect {
            rect: input_rect,
            radius: 10.0,
            fill: Some(surface_alt),
            stroke: Some(if sess.error.is_some() { urgent } else { border }),
            stroke_width: 1.5,
        });

        let (display_text, cursor_byte) = if sess.echo {
            (self.input.text.clone(), self.input.cursor)
        } else {
            let count = self.input.text.graphemes(true).count();
            let c_g = self.input.text[..self.input.cursor.min(self.input.text.len())]
                .graphemes(true)
                .count();
            ("\u{2022}".repeat(count), c_g * 3)
        };

        commands.push(PaintCmd::TextInputField {
            rect: Rect::new(32.0, 134.0, w - 64.0, 40.0),
            text: display_text,
            preedit: String::new(),
            cursor_byte,
            selection: None,
            placeholder: if sess.submitting {
                t(loc, I18nKey::LockUnlocking).to_string()
            } else {
                sess.prompt.clone()
            },
            password_mode: !sess.echo,
            color: fg,
            preedit_color: accent,
            selection_color: surface_alt,
            placeholder_color: muted,
            size: 14.0,
        });

        if let Some(ref err) = sess.error {
            commands.push(PaintCmd::RichText {
                rect: Rect::new(22.0, 182.0, w - 44.0, 32.0),
                text: err.clone(),
                color: urgent,
                size: 12.0,
                bold: false,
                align: TextAlign::Left,
                max_lines: 2,
            });
        }

        let btn_y = h - 54.0;
        let btn_w = 132.0;
        let btn_h = 34.0;
        let cancel_rect = Rect::new(w - 22.0 - btn_w * 2.0 - 10.0, btn_y, btn_w, btn_h);
        let ok_rect = Rect::new(w - 22.0 - btn_w, btn_y, btn_w, btn_h);

        commands.push(PaintCmd::RoundedRect {
            rect: cancel_rect,
            radius: 8.0,
            fill: Some(surface_alt),
            stroke: Some(border),
            stroke_width: 1.0,
        });
        commands.push(PaintCmd::RichText {
            rect: cancel_rect,
            text: t(loc, I18nKey::PolkitCancel).to_string(),
            color: fg,
            size: 13.0,
            bold: true,
            align: TextAlign::Center,
            max_lines: 1,
        });
        hit_targets.push(HitTarget {
            rect: cancel_rect,
            id: "polkit:cancel".into(),
        });

        commands.push(PaintCmd::RoundedRect {
            rect: ok_rect,
            radius: 8.0,
            fill: Some(accent),
            stroke: None,
            stroke_width: 0.0,
        });
        commands.push(PaintCmd::RichText {
            rect: ok_rect,
            text: t(loc, I18nKey::PolkitAuthenticate).to_string(),
            color: on_accent,
            size: 13.0,
            bold: true,
            align: TextAlign::Center,
            max_lines: 1,
        });
        hit_targets.push(HitTarget {
            rect: ok_rect,
            id: "polkit:auth".into(),
        });

        self.cached_spec = Some(SurfaceSpec {
            id: SURFACE_ID.into(),
            namespace: NAMESPACE.into(),
            output: None,
            layer: Layer::Overlay,
            keyboard_interactivity: KeyboardMode::Exclusive,
            anchor: Anchor::empty(),
            exclusive_zone: 0,
            width: PANEL_W,
            height: PANEL_H,
            margin: EdgeInsets::default(),
            corner_radius: 16.0,
            background: bg,
            border_color: border,
            border_width: 1.5,
            commands,
            hit_targets,
            animating: false,
            input_regions: None,
            ime_cursor_rect: Some(Rect::new(32.0, 140.0, w - 64.0, 28.0)),
        });
    }
}

impl KazeExtension for PolkitExtension {
    fn id(&self) -> &'static str {
        "polkit"
    }

    fn on_init(&mut self, _ctx: &mut ShellContext) {}

    fn on_event(&mut self, event: &SystemEvent, ctx: &mut ShellContext) -> DirtyFlags {
        match event {
            SystemEvent::PolkitBegin(req) => {
                if let Some(ref cur) = self.active {
                    if cur.request.cookie != req.cookie
                        && !self.queue.iter().any(|q| q.cookie == req.cookie)
                    {
                        self.queue.push_back(req.clone());
                    }
                    return DirtyFlags::NONE;
                }
                self.queue.push_back(req.clone());
                self.activate_next(ctx.state.locale);
                self.rebuild(ctx.state);
                DirtyFlags::POLKIT | DirtyFlags::LAYOUT
            }
            SystemEvent::PolkitCancel { cookie } => {
                if self
                    .active
                    .as_ref()
                    .is_some_and(|a| &a.request.cookie == cookie)
                {
                    self.active = None;
                    self.activate_next(ctx.state.locale);
                    self.rebuild(ctx.state);
                    return DirtyFlags::POLKIT | DirtyFlags::LAYOUT;
                }
                self.queue.retain(|q| &q.cookie != cookie);
                DirtyFlags::NONE
            }
            SystemEvent::PolkitPrompt {
                cookie,
                prompt,
                echo,
            } => {
                if let Some(ref mut a) = self.active {
                    if &a.request.cookie == cookie {
                        a.prompt = prompt.clone();
                        a.echo = *echo;
                        a.submitting = false;
                        self.rebuild(ctx.state);
                        return DirtyFlags::POLKIT;
                    }
                }
                DirtyFlags::NONE
            }
            SystemEvent::PolkitError { cookie, message } => {
                if let Some(ref mut a) = self.active {
                    if &a.request.cookie == cookie {
                        a.error = Some(message.clone());
                        a.submitting = false;
                        self.input.clear();
                        self.rebuild(ctx.state);
                        return DirtyFlags::POLKIT;
                    }
                }
                DirtyFlags::NONE
            }
            SystemEvent::PolkitComplete { cookie, success } => {
                if let Some(ref mut a) = self.active {
                    if &a.request.cookie == cookie {
                        if *success {
                            self.active = None;
                            self.activate_next(ctx.state.locale);
                            self.rebuild(ctx.state);
                            return DirtyFlags::POLKIT | DirtyFlags::LAYOUT;
                        }
                        // Wrong password or helper error: keep modal open for retry with clear error.
                        a.submitting = false;
                        if a.error.is_none() {
                            a.error =
                                Some(t(ctx.state.locale, I18nKey::LockWrongPassword).to_string());
                        }
                        self.input.clear();
                        self.rebuild(ctx.state);
                        return DirtyFlags::POLKIT;
                    }
                }
                DirtyFlags::NONE
            }
            SystemEvent::KeyInput { surface_id, key }
                if surface_id == SURFACE_ID && key.pressed =>
            {
                if key.keysym == KEY_TAB {
                    if let Some(ref mut sess) = self.active {
                        if sess.request.identities.len() > 1 {
                            sess.selected_identity =
                                (sess.selected_identity + 1) % sess.request.identities.len();
                            self.rebuild(ctx.state);
                            return DirtyFlags::POLKIT;
                        }
                    }
                    return DirtyFlags::NONE;
                }
                match self.input.handle_key(key, &ctx.state.config.input.keybinds) {
                    TextInputOutcome::Cancel => self.cancel_active(ctx),
                    TextInputOutcome::Submit => self.submit(ctx),
                    TextInputOutcome::Changed => {
                        if let Some(ref mut a) = self.active {
                            a.error = None;
                        }
                        self.rebuild(ctx.state);
                        DirtyFlags::POLKIT
                    }
                    _ => DirtyFlags::NONE,
                }
            }
            SystemEvent::PointerClick {
                surface_id,
                target_id,
                button: PointerButton::Left,
            } if surface_id == SURFACE_ID => match target_id.as_str() {
                "polkit:cancel" => self.cancel_active(ctx),
                "polkit:auth" => self.submit(ctx),
                "polkit:identity" => {
                    if let Some(ref mut sess) = self.active {
                        if sess.request.identities.len() > 1 {
                            sess.selected_identity =
                                (sess.selected_identity + 1) % sess.request.identities.len();
                            self.rebuild(ctx.state);
                            return DirtyFlags::POLKIT;
                        }
                    }
                    DirtyFlags::NONE
                }
                _ => DirtyFlags::NONE,
            },
            SystemEvent::SurfaceClosed { surface_id } if surface_id == SURFACE_ID => {
                self.cancel_active(ctx)
            }
            SystemEvent::ConfigReloaded
            | SystemEvent::ThemeChanged(_)
            | SystemEvent::LocaleChanged(_)
                if self.active.is_some() =>
            {
                self.rebuild(ctx.state);
                DirtyFlags::POLKIT
            }
            _ => DirtyFlags::NONE,
        }
    }

    fn on_ipc(&mut self, _cmd: &str, _args: &[String], _ctx: &mut ShellContext) -> IpcResult {
        IpcResult::Unhandled
    }

    fn surfaces(&self) -> Vec<SurfaceSpec> {
        self.cached_spec.iter().cloned().collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use kaze_core::{AppState, Config, KeyEvent, KeyModifiers};

    fn make_req(cookie: &str) -> PolkitRequest {
        PolkitRequest {
            cookie: cookie.into(),
            action_id: "org.freedesktop.policykit.exec".into(),
            message: "Authentication is required".into(),
            icon_name: String::new(),
            identities: vec!["alice".into(), "root".into()],
            details: Vec::new(),
        }
    }

    #[test]
    fn fifo_queue_and_escape_cancel_drops_surface_immediately() {
        let mut state = AppState::new(Config::default());
        let mut ext = PolkitExtension::new();
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_event(&SystemEvent::PolkitBegin(make_req("c1")), &mut ctx);
            ext.on_event(&SystemEvent::PolkitBegin(make_req("c2")), &mut ctx);
            assert_eq!(ext.active_cookie(), Some("c1"));
            assert_eq!(ext.queued_len(), 1);
            assert_eq!(ext.surfaces().len(), 1);

            ext.on_event(
                &SystemEvent::KeyInput {
                    surface_id: SURFACE_ID.into(),
                    key: KeyEvent {
                        keysym: 0xff1b,
                        utf8: None,
                        modifiers: KeyModifiers::default(),
                        pressed: true,
                    },
                },
                &mut ctx,
            );
            assert!(ctx.actions.contains(&ShellAction::PolkitCancel {
                cookie: "c1".into(),
            }));
            assert_eq!(ext.active_cookie(), Some("c2"));
            assert_eq!(ext.queued_len(), 0);

            ext.on_event(
                &SystemEvent::PolkitComplete {
                    cookie: "c2".into(),
                    success: true,
                },
                &mut ctx,
            );
        }
        assert_eq!(ext.active_cookie(), None);
        assert!(ext.surfaces().is_empty());
    }

    #[test]
    fn wrong_password_keeps_modal_open_for_retry_and_clears_input() {
        let mut state = AppState::new(Config::default());
        let mut ext = PolkitExtension::new();
        let mut ctx = ShellContext::new(&mut state);
        ext.on_event(&SystemEvent::PolkitBegin(make_req("c1")), &mut ctx);
        ext.on_event(
            &SystemEvent::KeyInput {
                surface_id: SURFACE_ID.into(),
                key: KeyEvent {
                    keysym: 'x' as u32,
                    utf8: Some("x".into()),
                    modifiers: KeyModifiers::default(),
                    pressed: true,
                },
            },
            &mut ctx,
        );
        ext.on_event(
            &SystemEvent::KeyInput {
                surface_id: SURFACE_ID.into(),
                key: KeyEvent {
                    keysym: 0xff0d,
                    utf8: None,
                    modifiers: KeyModifiers::default(),
                    pressed: true,
                },
            },
            &mut ctx,
        );
        assert!(ext.input.text.is_empty());
        assert!(ctx.actions.iter().any(|a| matches!(
            a,
            ShellAction::PolkitSubmitPassword { cookie, .. } if cookie == "c1"
        )));

        ext.on_event(
            &SystemEvent::PolkitComplete {
                cookie: "c1".into(),
                success: false,
            },
            &mut ctx,
        );
        assert_eq!(ext.active_cookie(), Some("c1"));
        assert!(ext.active.as_ref().and_then(|a| a.error.as_ref()).is_some());
    }
}
