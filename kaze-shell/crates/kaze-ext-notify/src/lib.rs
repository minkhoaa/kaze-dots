#![deny(clippy::unwrap_used)]

use kaze_core::{
    Anchor, AppState, Color, DirtyFlags, EdgeInsets, HitTarget, IpcResult, KazeExtension,
    KeyboardMode, Layer, NotificationItem, NotificationUrgency, PaintCmd, PointerButton, Rect,
    ShellAction, ShellContext, SurfaceSpec, SystemEvent, TextAlign,
};
use std::collections::VecDeque;

const SURFACE_ID: &str = "notify:stack";
const NAMESPACE: &str = "kaze-notify";
const EXPIRE_TIMER_PREFIX: &str = "notify:expire:";

// Freedesktop Desktop Notifications Specification v1.2 close reasons
const REASON_EXPIRED: u32 = 1;
const REASON_DISMISSED: u32 = 2;
const REASON_CLOSED_BY_CALL: u32 = 3;
const REASON_UNDEFINED: u32 = 4;

/// Notification daemon extension (`org.freedesktop.Notifications` consumer):
/// manages stacked `kaze-notify` popups, `replaces_id` / synchronous tag updates,
/// urgency styling, DND filtering, one-shot expiry timers, and an in-memory ring-buffer history.
///
/// When no popup is visible, `surfaces()` returns `Vec::new()` so `kaze-ui` immediately
/// drops the Wayland layer surface and frees its SHM `SlotPool` down to 0 KiB.
pub struct NotifyExtension {
    visible: Vec<NotificationItem>,
    history: VecDeque<NotificationItem>,
    cached_spec: Option<SurfaceSpec>,
}

impl Default for NotifyExtension {
    fn default() -> Self {
        Self::new()
    }
}

impl NotifyExtension {
    pub fn new() -> Self {
        Self {
            visible: Vec::new(),
            history: VecDeque::new(),
            cached_spec: None,
        }
    }

    pub fn visible_items(&self) -> &[NotificationItem] {
        &self.visible
    }

    pub fn history_items(&self) -> &VecDeque<NotificationItem> {
        &self.history
    }

    fn timer_id(id: u32) -> String {
        format!("{EXPIRE_TIMER_PREFIX}{id}")
    }

    fn sync_counts(&self, state: &mut AppState) {
        state.active_notifications = self.visible.len();
        state.history_notifications = self.history.len();
    }

    fn rebuild(&mut self, state: &mut AppState) {
        self.sync_counts(state);
        self.cached_spec = build_notify_surface(state, &self.visible);
    }

    fn record_history(&mut self, item: &NotificationItem, limit: usize) {
        if item.transient || limit == 0 {
            return;
        }
        if let Some(pos) = self.history.iter().position(|h| {
            h.id == item.id || (item.sync_tag.is_some() && h.sync_tag == item.sync_tag)
        }) {
            self.history.remove(pos);
        }
        self.history.push_front(item.clone());
        while self.history.len() > limit {
            self.history.pop_back();
        }
    }

    fn schedule_expiry(&self, item: &NotificationItem, ctx: &mut ShellContext) {
        let timer_id = Self::timer_id(item.id);
        let timeout_ms: Option<u64> = if item.expire_timeout_ms == 0 {
            None
        } else if item.expire_timeout_ms > 0 {
            Some((item.expire_timeout_ms as u64).max(250))
        } else {
            // expire_timeout_ms < 0: server default.
            // Critical notifications never auto-expire by default.
            match item.urgency {
                NotificationUrgency::Critical => None,
                NotificationUrgency::Low => {
                    Some(ctx.state.config.notifications.low_timeout_ms.max(500))
                }
                NotificationUrgency::Normal => {
                    Some(ctx.state.config.notifications.default_timeout_ms.max(500))
                }
            }
        };

        match timeout_ms {
            Some(after_ms) => ctx.push_action(ShellAction::ScheduleTimer {
                id: timer_id,
                after_ms,
            }),
            None => ctx.push_action(ShellAction::CancelTimer { id: timer_id }),
        }
    }

    fn handle_received(&mut self, item: &NotificationItem, ctx: &mut ShellContext) -> DirtyFlags {
        let cfg = ctx.state.config.notifications.clone();
        self.record_history(item, cfg.history_limit);

        if !cfg.enabled {
            self.sync_counts(ctx.state);
            return DirtyFlags::NONE;
        }

        // DND suppresses low/normal popups; critical notifications always bypass DND.
        if ctx.state.dnd && item.urgency != NotificationUrgency::Critical {
            if !item.transient {
                ctx.state.unread_notifications = ctx.state.unread_notifications.saturating_add(1);
            }
            self.sync_counts(ctx.state);
            return DirtyFlags::NONE;
        }

        let existing_idx = self.visible.iter().position(|n| {
            n.id == item.id || (item.sync_tag.is_some() && n.sync_tag == item.sync_tag)
        });

        if let Some(idx) = existing_idx {
            let old_id = self.visible[idx].id;
            if old_id != item.id {
                ctx.push_action(ShellAction::CancelTimer {
                    id: Self::timer_id(old_id),
                });
                ctx.push_action(ShellAction::NotifyClosed {
                    id: old_id,
                    reason: REASON_UNDEFINED,
                });
            }
            self.visible[idx] = item.clone();
        } else {
            self.visible.insert(0, item.clone());
            if !item.transient {
                ctx.state.unread_notifications = ctx.state.unread_notifications.saturating_add(1);
            }
            // Enforce max_visible stack size, preferring to evict oldest non-critical first.
            while self.visible.len() > cfg.max_visible {
                let evict_idx = self
                    .visible
                    .iter()
                    .rposition(|n| n.urgency != NotificationUrgency::Critical)
                    .unwrap_or(self.visible.len() - 1);
                let evicted = self.visible.remove(evict_idx);
                ctx.push_action(ShellAction::CancelTimer {
                    id: Self::timer_id(evicted.id),
                });
                ctx.push_action(ShellAction::NotifyClosed {
                    id: evicted.id,
                    reason: REASON_EXPIRED,
                });
            }
        }

        self.schedule_expiry(item, ctx);
        self.rebuild(ctx.state);
        DirtyFlags::NOTIFY
    }

    fn dismiss_by_id(
        &mut self,
        id: u32,
        reason: u32,
        decrement_unread: bool,
        ctx: &mut ShellContext,
    ) -> DirtyFlags {
        let Some(pos) = self.visible.iter().position(|n| n.id == id) else {
            return DirtyFlags::NONE;
        };
        let removed = self.visible.remove(pos);
        ctx.push_action(ShellAction::CancelTimer {
            id: Self::timer_id(removed.id),
        });
        ctx.push_action(ShellAction::NotifyClosed {
            id: removed.id,
            reason,
        });
        if decrement_unread && !removed.transient {
            ctx.state.unread_notifications = ctx.state.unread_notifications.saturating_sub(1);
        }
        self.rebuild(ctx.state);
        DirtyFlags::NOTIFY | DirtyFlags::LAYOUT
    }

    fn clear_all(&mut self, ctx: &mut ShellContext) -> DirtyFlags {
        let had_visible = !self.visible.is_empty();
        for item in self.visible.drain(..) {
            ctx.push_action(ShellAction::CancelTimer {
                id: Self::timer_id(item.id),
            });
            ctx.push_action(ShellAction::NotifyClosed {
                id: item.id,
                reason: REASON_DISMISSED,
            });
        }
        ctx.state.unread_notifications = 0;
        self.rebuild(ctx.state);
        if had_visible {
            DirtyFlags::NOTIFY | DirtyFlags::LAYOUT
        } else {
            DirtyFlags::NONE
        }
    }

    fn handle_click(
        &mut self,
        target_id: &str,
        button: PointerButton,
        ctx: &mut ShellContext,
    ) -> DirtyFlags {
        if let Some(rest) = target_id.strip_prefix("notify:action:") {
            let Some((id_str, action_key)) = rest.split_once(':') else {
                return DirtyFlags::NONE;
            };
            let Ok(id) = id_str.parse::<u32>() else {
                return DirtyFlags::NONE;
            };
            match button {
                PointerButton::Left => {
                    let resident = self
                        .visible
                        .iter()
                        .find(|n| n.id == id)
                        .is_some_and(|n| n.resident);
                    ctx.push_action(ShellAction::NotifyActionInvoked {
                        id,
                        action_key: action_key.to_string(),
                    });
                    if !resident {
                        return self.dismiss_by_id(id, REASON_DISMISSED, true, ctx);
                    }
                    return DirtyFlags::NONE;
                }
                PointerButton::Right => {
                    return self.dismiss_by_id(id, REASON_DISMISSED, true, ctx);
                }
                PointerButton::Middle => return DirtyFlags::NONE,
            }
        }

        if let Some(id_str) = target_id.strip_prefix("notify:card:") {
            let Ok(id) = id_str.parse::<u32>() else {
                return DirtyFlags::NONE;
            };
            match button {
                PointerButton::Left => {
                    let default_action = self.visible.iter().find(|n| n.id == id).and_then(|n| {
                        n.actions
                            .iter()
                            .find(|a| a.key == "default")
                            .map(|a| a.key.clone())
                    });
                    if let Some(action_key) = default_action {
                        ctx.push_action(ShellAction::NotifyActionInvoked { id, action_key });
                    }
                    return self.dismiss_by_id(id, REASON_DISMISSED, true, ctx);
                }
                PointerButton::Right => {
                    return self.dismiss_by_id(id, REASON_DISMISSED, true, ctx);
                }
                PointerButton::Middle => return DirtyFlags::NONE,
            }
        }

        DirtyFlags::NONE
    }
}

impl KazeExtension for NotifyExtension {
    fn id(&self) -> &'static str {
        "notify"
    }

    fn on_init(&mut self, ctx: &mut ShellContext) {
        self.sync_counts(ctx.state);
    }

    fn on_event(&mut self, event: &SystemEvent, ctx: &mut ShellContext) -> DirtyFlags {
        match event {
            SystemEvent::NotificationReceived(item) => self.handle_received(item, ctx),
            SystemEvent::NotificationCloseRequested { id } => {
                self.dismiss_by_id(*id, REASON_CLOSED_BY_CALL, true, ctx)
            }
            SystemEvent::NotificationClearAll => self.clear_all(ctx),
            SystemEvent::TimerFired { id } => {
                if let Some(raw_id) = id.strip_prefix(EXPIRE_TIMER_PREFIX) {
                    if let Ok(notif_id) = raw_id.parse::<u32>() {
                        // Expired popups leave unread_notifications intact until dismissed or cleared.
                        return self.dismiss_by_id(notif_id, REASON_EXPIRED, false, ctx);
                    }
                }
                DirtyFlags::NONE
            }
            SystemEvent::PointerClick {
                surface_id,
                target_id,
                button,
            } if surface_id == SURFACE_ID => self.handle_click(target_id, *button, ctx),
            SystemEvent::ConfigReloaded
            | SystemEvent::ThemeChanged(_)
            | SystemEvent::LayoutPresetChanged(_) => {
                if !ctx.state.config.notifications.enabled {
                    return self.clear_all(ctx);
                }
                while self.visible.len() > ctx.state.config.notifications.max_visible {
                    if let Some(evicted) = self.visible.pop() {
                        ctx.push_action(ShellAction::CancelTimer {
                            id: Self::timer_id(evicted.id),
                        });
                        ctx.push_action(ShellAction::NotifyClosed {
                            id: evicted.id,
                            reason: REASON_EXPIRED,
                        });
                    }
                }
                while self.history.len() > ctx.state.config.notifications.history_limit {
                    self.history.pop_back();
                }
                if !self.visible.is_empty() {
                    self.rebuild(ctx.state);
                    DirtyFlags::NOTIFY | DirtyFlags::THEME
                } else {
                    self.sync_counts(ctx.state);
                    DirtyFlags::NONE
                }
            }
            _ => DirtyFlags::NONE,
        }
    }

    fn on_ipc(&mut self, cmd: &str, _args: &[String], ctx: &mut ShellContext) -> IpcResult {
        match cmd {
            "notify-count" => IpcResult::Handled {
                ok: true,
                message: format!(
                    "active={} unread={} history={}",
                    self.visible.len(),
                    ctx.state.unread_notifications,
                    self.history.len()
                ),
                dirty: DirtyFlags::NONE,
            },
            _ => IpcResult::Unhandled,
        }
    }

    fn surfaces(&self) -> Vec<SurfaceSpec> {
        self.cached_spec.clone().into_iter().collect()
    }
}

fn resolve_notify_anchor(position: &str, ox: i32, oy: i32) -> (Anchor, EdgeInsets) {
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
        "bottom_left" => (
            Anchor::BOTTOM | Anchor::LEFT,
            EdgeInsets {
                bottom: oy,
                left: ox,
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

/// Estimates wrapped line count conservatively (accounting for wide Unicode/Emoji glyphs)
/// so stacked card heights never clip descenders or Vietnamese diacritics.
fn estimate_lines(text: &str, inner_width: f32, font_size: f32, max_lines: u8) -> u32 {
    if text.is_empty() {
        return 0;
    }
    let chars_per_line = (inner_width / (font_size * 0.58)).floor().max(10.0) as usize;
    let mut lines = 0usize;
    for paragraph in text.split('\n') {
        let len = paragraph.chars().count();
        let para_lines = if len == 0 {
            1
        } else {
            len.div_ceil(chars_per_line)
        };
        lines = lines.saturating_add(para_lines);
        if lines >= usize::from(max_lines) {
            return u32::from(max_lines);
        }
    }
    (lines as u32).clamp(1, u32::from(max_lines))
}

fn build_notify_surface(state: &AppState, visible: &[NotificationItem]) -> Option<SurfaceSpec> {
    if visible.is_empty() || !state.config.notifications.enabled {
        return None;
    }

    let cfg = &state.config.notifications;
    let bar = &state.config.bar;
    let colors = state.palette.for_mode(state.theme_mode);

    let bg = colors.surface_color().with_opacity(bar.background_opacity);
    let primary = colors.primary_color();
    let error_col = colors.error_color();
    let on_error = colors.color(&colors.on_error, Color::rgba(0xff, 0xff, 0xff, 0xff));
    let on_surface = colors.on_surface_color();
    let muted = colors.on_surface_variant_color();
    let outline_variant = colors.outline_variant_color();
    let surface_container = colors.surface_container_color();

    let card_w = cfg.width.clamp(220, 640) as f32;
    let gap = cfg.gap.max(0) as f32;
    let border_w = bar
        .border_width
        .max(state.layout_preset.overlay_border_width());
    let radius = bar
        .corner_radius
        .max(state.layout_preset.overlay_corner_radius());
    let inner_r = if radius > 0.0 {
        (radius * 0.4).min(6.0)
    } else {
        0.0
    };
    let accent_w = 3.0f32;
    let pad_left = border_w + accent_w + 10.0;
    let pad_right = border_w + 12.0;
    let pad_top = border_w + 8.0;
    let pad_bottom = border_w + 10.0;
    let content_w = (card_w - pad_left - pad_right).max(120.0);

    let mut commands = Vec::with_capacity(visible.len() * 6);
    let mut hit_targets = Vec::with_capacity(visible.len() * 2);
    let mut cur_y = 0.0f32;

    for (idx, item) in visible.iter().enumerate() {
        if idx > 0 {
            cur_y += gap;
        }

        let (card_border, accent_col) = match item.urgency {
            NotificationUrgency::Low => (outline_variant, muted),
            NotificationUrgency::Normal => (primary, primary),
            NotificationUrgency::Critical => (error_col, error_col),
        };

        let show_meta = !item.app_name.is_empty() || item.urgency == NotificationUrgency::Critical;
        let meta_h = if show_meta { 17.0f32 } else { 0.0 };

        let summary_text = if item.summary.trim().is_empty() {
            item.app_name.as_str()
        } else {
            item.summary.as_str()
        };
        let summary_lines = estimate_lines(summary_text, content_w, 13.5, 2).max(1);
        let summary_h = (summary_lines as f32 * 20.0) + 2.0;

        let body_lines = estimate_lines(item.body.trim(), content_w, 12.0, 4);
        let body_h = if body_lines > 0 {
            (body_lines as f32 * 18.0) + 4.0
        } else {
            0.0
        };

        let visible_actions: Vec<_> = item
            .actions
            .iter()
            .filter(|a| a.key != "default" && !a.label.trim().is_empty())
            .take(3)
            .collect();
        let actions_h = if visible_actions.is_empty() {
            0.0
        } else {
            30.0
        };

        let mut inner_h = summary_h;
        if show_meta {
            inner_h += meta_h + 2.0;
        }
        if body_h > 0.0 {
            inner_h += 4.0 + body_h;
        }
        if actions_h > 0.0 {
            inner_h += 6.0 + actions_h;
        }

        let card_h = (pad_top + inner_h + pad_bottom).ceil();
        let card_rect = Rect::new(0.0, cur_y, card_w, card_h);

        // Card background + urgency border
        commands.push(PaintCmd::RoundedRect {
            rect: card_rect,
            radius,
            fill: Some(bg),
            stroke: Some(card_border),
            stroke_width: border_w,
        });

        // Inner left urgency accent stripe
        commands.push(PaintCmd::RoundedRect {
            rect: Rect::new(
                border_w,
                cur_y + border_w,
                accent_w,
                (card_h - border_w * 2.0).max(4.0),
            ),
            radius: 0.0,
            fill: Some(accent_col),
            stroke: None,
            stroke_width: 0.0,
        });

        let mut row_y = cur_y + pad_top;

        if show_meta {
            let badge_w = if item.urgency == NotificationUrgency::Critical {
                64.0f32
            } else {
                0.0
            };
            let app_label = if item.app_name.is_empty() {
                "Alert"
            } else {
                item.app_name.as_str()
            };
            let app_w = (content_w - badge_w - if badge_w > 0.0 { 6.0 } else { 0.0 }).max(40.0);
            commands.push(PaintCmd::RichText {
                rect: Rect::new(pad_left, row_y, app_w, meta_h),
                text: app_label.to_string(),
                color: if item.urgency == NotificationUrgency::Critical {
                    error_col
                } else {
                    muted
                },
                size: 10.5,
                bold: item.urgency == NotificationUrgency::Critical,
                align: TextAlign::Left,
                max_lines: 1,
            });
            if item.urgency == NotificationUrgency::Critical {
                let badge_rect = Rect::new(pad_left + content_w - badge_w, row_y, badge_w, 15.0);
                commands.push(PaintCmd::RoundedRect {
                    rect: badge_rect,
                    radius: inner_r,
                    fill: Some(error_col),
                    stroke: None,
                    stroke_width: 0.0,
                });
                commands.push(PaintCmd::Text {
                    rect: badge_rect,
                    text: "CRITICAL".to_string(),
                    color: on_error,
                    size: 9.0,
                    bold: true,
                    align: TextAlign::Center,
                });
            }
            row_y += meta_h + 2.0;
        }

        // Summary (RichText for Vietnamese HarfBuzz shaping + Color Emoji)
        commands.push(PaintCmd::RichText {
            rect: Rect::new(pad_left, row_y, content_w, summary_h),
            text: summary_text.to_string(),
            color: on_surface,
            size: 13.5,
            bold: true,
            align: TextAlign::Left,
            max_lines: 2,
        });
        row_y += summary_h;

        // Body
        if body_h > 0.0 {
            row_y += 4.0;
            commands.push(PaintCmd::RichText {
                rect: Rect::new(pad_left, row_y, content_w, body_h),
                text: item.body.trim().to_string(),
                color: muted,
                size: 12.0,
                bold: false,
                align: TextAlign::Left,
                max_lines: 4,
            });
            row_y += body_h;
        }

        // Explicit action buttons (hit targets pushed BEFORE enclosing card target)
        if !visible_actions.is_empty() {
            row_y += 6.0;
            let btn_gap = 6.0f32;
            let count = visible_actions.len() as f32;
            let btn_w = ((content_w - btn_gap * (count - 1.0)) / count).max(48.0);
            let btn_h = 24.0f32;
            for (btn_idx, act) in visible_actions.iter().enumerate() {
                let bx = pad_left + btn_idx as f32 * (btn_w + btn_gap);
                let btn_rect = Rect::new(bx, row_y, btn_w, btn_h);
                commands.push(PaintCmd::RoundedRect {
                    rect: btn_rect,
                    radius: inner_r,
                    fill: Some(surface_container),
                    stroke: Some(outline_variant),
                    stroke_width: 1.0,
                });
                commands.push(PaintCmd::RichText {
                    rect: Rect::new(bx + 4.0, row_y + 3.0, (btn_w - 8.0).max(16.0), btn_h - 4.0),
                    text: act.label.clone(),
                    color: on_surface,
                    size: 11.0,
                    bold: false,
                    align: TextAlign::Center,
                    max_lines: 1,
                });
                hit_targets.push(HitTarget {
                    rect: btn_rect,
                    id: format!("notify:action:{}:{}", item.id, act.key),
                });
            }
        }

        // Whole-card hit target (fallback when click wasn't on a specific action button)
        hit_targets.push(HitTarget {
            rect: card_rect,
            id: format!("notify:card:{}", item.id),
        });

        cur_y += card_h;
    }

    let total_h = (cur_y.ceil() as u32).max(40);
    let (anchor, margin) = resolve_notify_anchor(&cfg.position, cfg.offset_x, cfg.offset_y);

    Some(SurfaceSpec {
        id: SURFACE_ID.to_string(),
        namespace: NAMESPACE.to_string(),
        output: None,
        layer: Layer::Overlay,
        keyboard_interactivity: KeyboardMode::None,
        anchor,
        exclusive_zone: 0,
        width: cfg.width.clamp(220, 640),
        height: total_h,
        margin,
        corner_radius: 0.0,
        background: Color::TRANSPARENT,
        border_color: Color::TRANSPARENT,
        border_width: 0.0,
        commands,
        hit_targets,
        animating: false,
        input_regions: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use kaze_core::{Config, NotificationAction};

    fn sample_notif(id: u32, urgency: NotificationUrgency, summary: &str) -> NotificationItem {
        NotificationItem {
            id,
            app_name: "kaze-test".into(),
            summary: summary.into(),
            body: "Nội dung tiếng Việt có dấu 🔔".into(),
            app_icon: String::new(),
            urgency,
            actions: Vec::new(),
            expire_timeout_ms: -1,
            resident: false,
            transient: false,
            sync_tag: None,
            timestamp_epoch_secs: 1_700_000_000,
        }
    }

    #[test]
    fn starts_empty_shows_stack_and_frees_surface_on_expiry() {
        let mut state = AppState::new(Config::default());
        let mut ext = NotifyExtension::new();
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_init(&mut ctx);
        }
        assert!(ext.surfaces().is_empty());

        let n1 = sample_notif(1, NotificationUrgency::Normal, "Xin chào Việt Nam");
        {
            let mut ctx = ShellContext::new(&mut state);
            let dirty = ext.on_event(&SystemEvent::NotificationReceived(n1), &mut ctx);
            assert!(dirty.contains(DirtyFlags::NOTIFY));
            assert!(ctx.actions.iter().any(|a| matches!(
                a,
                ShellAction::ScheduleTimer { id, after_ms: 5000 } if id == "notify:expire:1"
            )));
        }
        assert_eq!(state.active_notifications, 1);
        assert_eq!(state.unread_notifications, 1);
        let specs = ext.surfaces();
        assert_eq!(specs.len(), 1);
        assert_eq!(specs[0].namespace, "kaze-notify");
        assert_eq!(specs[0].layer, Layer::Overlay);

        {
            let mut ctx = ShellContext::new(&mut state);
            let dirty = ext.on_event(
                &SystemEvent::TimerFired {
                    id: "notify:expire:1".into(),
                },
                &mut ctx,
            );
            assert!(dirty.contains(DirtyFlags::NOTIFY));
            assert!(ctx.actions.contains(&ShellAction::NotifyClosed {
                id: 1,
                reason: REASON_EXPIRED,
            }));
        }
        assert!(ext.surfaces().is_empty());
        assert_eq!(state.active_notifications, 0);
        assert_eq!(state.history_notifications, 1);
    }

    #[test]
    fn dnd_suppresses_normal_but_allows_critical_without_default_timeout() {
        let mut state = AppState::new(Config::default());
        state.dnd = true;
        let mut ext = NotifyExtension::new();

        let normal = sample_notif(10, NotificationUrgency::Normal, "Muted message");
        {
            let mut ctx = ShellContext::new(&mut state);
            let dirty = ext.on_event(&SystemEvent::NotificationReceived(normal), &mut ctx);
            assert!(dirty.is_empty());
            assert!(ctx.actions.is_empty());
        }
        assert!(ext.surfaces().is_empty());
        assert_eq!(ext.history_items().len(), 1);
        assert_eq!(state.unread_notifications, 1);

        let crit = sample_notif(11, NotificationUrgency::Critical, "Pin yếu 5% ⚠️");
        {
            let mut ctx = ShellContext::new(&mut state);
            let dirty = ext.on_event(&SystemEvent::NotificationReceived(crit), &mut ctx);
            assert!(dirty.contains(DirtyFlags::NOTIFY));
            assert!(ctx.actions.contains(&ShellAction::CancelTimer {
                id: "notify:expire:11".into(),
            }));
            assert!(
                !ctx.actions
                    .iter()
                    .any(|a| matches!(a, ShellAction::ScheduleTimer { .. })),
                "critical notification must not auto-expire on default timeout"
            );
        }
        assert_eq!(ext.visible_items().len(), 1);
        assert_eq!(ext.surfaces().len(), 1);
    }

    #[test]
    fn replaces_id_and_sync_tag_update_card_in_place() {
        let mut state = AppState::new(Config::default());
        let mut ext = NotifyExtension::new();

        let mut n1 = sample_notif(5, NotificationUrgency::Normal, "Step 1");
        n1.sync_tag = Some("kaze-display".into());
        let mut n2 = sample_notif(5, NotificationUrgency::Normal, "Step 2");
        n2.sync_tag = Some("kaze-display".into());
        let mut n3 = sample_notif(6, NotificationUrgency::Normal, "Step 3");
        n3.sync_tag = Some("kaze-display".into());

        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_event(&SystemEvent::NotificationReceived(n1), &mut ctx);
            ext.on_event(&SystemEvent::NotificationReceived(n2), &mut ctx);
            ext.on_event(&SystemEvent::NotificationReceived(n3), &mut ctx);
        }
        assert_eq!(ext.visible_items().len(), 1);
        assert_eq!(ext.visible_items()[0].id, 6);
        assert_eq!(ext.visible_items()[0].summary, "Step 3");
        assert_eq!(ext.history_items().len(), 1);
    }

    #[test]
    fn left_click_invokes_default_action_and_clear_all_closes_stack() {
        let mut state = AppState::new(Config::default());
        let mut ext = NotifyExtension::new();

        let mut n1 = sample_notif(20, NotificationUrgency::Normal, "Có tin nhắn mới");
        n1.actions = vec![
            NotificationAction {
                key: "default".into(),
                label: "Mở".into(),
            },
            NotificationAction {
                key: "reply".into(),
                label: "Trả lời".into(),
            },
        ];
        let n2 = sample_notif(21, NotificationUrgency::Low, "Background done");

        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_event(&SystemEvent::NotificationReceived(n1), &mut ctx);
            ext.on_event(&SystemEvent::NotificationReceived(n2), &mut ctx);
        }
        assert_eq!(ext.visible_items().len(), 2);

        // Left click card 20 triggers default action and closes it.
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_event(
                &SystemEvent::PointerClick {
                    surface_id: SURFACE_ID.into(),
                    target_id: "notify:card:20".into(),
                    button: PointerButton::Left,
                },
                &mut ctx,
            );
            assert!(ctx.actions.contains(&ShellAction::NotifyActionInvoked {
                id: 20,
                action_key: "default".into(),
            }));
            assert!(ctx.actions.contains(&ShellAction::NotifyClosed {
                id: 20,
                reason: REASON_DISMISSED,
            }));
        }
        assert_eq!(ext.visible_items().len(), 1);

        // Clear all dismisses remaining popup and resets unread counter.
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_event(&SystemEvent::NotificationClearAll, &mut ctx);
            assert!(ctx.actions.contains(&ShellAction::NotifyClosed {
                id: 21,
                reason: REASON_DISMISSED,
            }));
        }
        assert!(ext.surfaces().is_empty());
        assert_eq!(state.unread_notifications, 0);
    }

    #[test]
    fn history_ring_buffer_caps_at_configured_limit() {
        let mut cfg = Config::default();
        cfg.notifications.history_limit = 5;
        cfg.notifications.max_visible = 3;
        let mut state = AppState::new(cfg);
        let mut ext = NotifyExtension::new();

        for id in 1..=12u32 {
            let n = sample_notif(id, NotificationUrgency::Normal, &format!("Msg {id}"));
            let mut ctx = ShellContext::new(&mut state);
            ext.on_event(&SystemEvent::NotificationReceived(n), &mut ctx);
        }

        assert_eq!(ext.visible_items().len(), 3);
        assert_eq!(ext.history_items().len(), 5);
        assert_eq!(ext.history_items()[0].id, 12);
        assert_eq!(ext.history_items()[4].id, 8);
    }
}
