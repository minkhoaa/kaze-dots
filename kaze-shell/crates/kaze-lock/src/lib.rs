#![deny(clippy::unwrap_used)]

pub mod fprintd;
pub mod pam;

use calloop::channel::{self, Sender as CalloopSender};
use calloop::timer::{TimeoutAction, Timer};
use calloop::{EventLoop, LoopSignal};
use calloop_wayland_source::WaylandSource;
use fprintd::{spawn_fprintd_listener, FingerprintEvent};
use image::imageops::FilterType;
use image::{DynamicImage, ImageReader, RgbaImage};
use kaze_core::config::InputKeybindsConfig;
use kaze_core::text_input::{TextInputOutcome, TextInputState};
use kaze_core::{
    t, Anchor, ClockTime, Color, EdgeInsets, I18nKey, KeyEvent, KeyModifiers, KeyboardMode, Layer,
    Locale, PaintCmd, Rect, SurfaceSpec, TextAlign,
};
use kaze_ui::render::Renderer;
use pam::{authenticate, current_username, PamOutcome};
use smithay_client_toolkit::compositor::{CompositorHandler, CompositorState};
use smithay_client_toolkit::output::{OutputHandler, OutputState};
use smithay_client_toolkit::reexports::client::backend::ObjectId;
use smithay_client_toolkit::reexports::client::globals::registry_queue_init;
use smithay_client_toolkit::reexports::client::protocol::{
    wl_keyboard, wl_output, wl_pointer, wl_seat, wl_shm, wl_surface,
};
use smithay_client_toolkit::reexports::client::{
    Connection, EventQueue, Proxy, QueueHandle,
};
use smithay_client_toolkit::registry::{ProvidesRegistryState, RegistryState};
use smithay_client_toolkit::seat::keyboard::{
    KeyEvent as SctkKeyEvent, KeyboardHandler, Keysym, Modifiers, RawModifiers,
};
use smithay_client_toolkit::seat::pointer::{PointerEvent, PointerEventKind, PointerHandler};
use smithay_client_toolkit::seat::{Capability, SeatHandler, SeatState};
use smithay_client_toolkit::session_lock::{
    SessionLock, SessionLockHandler, SessionLockState, SessionLockSurface,
    SessionLockSurfaceConfigure,
};
use smithay_client_toolkit::shm::slot::SlotPool;
use smithay_client_toolkit::shm::{Shm, ShmHandler};
use smithay_client_toolkit::{
    delegate_compositor, delegate_keyboard, delegate_output, delegate_pointer, delegate_registry,
    delegate_seat, delegate_session_lock, delegate_shm,
};
use std::collections::HashMap;
use std::os::unix::io::RawFd;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use unicode_segmentation::UnicodeSegmentation;
use zeroize::Zeroizing;

#[derive(Debug, Clone)]
pub struct LockWorkerConfig {
    pub ipc_fd: Option<RawFd>,
    pub pam_service: String,
    pub fprintd: bool,
    pub grace_secs: u64,
    pub media_controls: bool,
    pub media_keys: bool,
    pub blur: bool,
    pub background_color: String,
    pub wallpaper_path: Option<PathBuf>,
    pub username: String,
    pub real_name: String,
    pub avatar_path: Option<PathBuf>,
    pub font: String,
    pub font_scale: f32,
    pub high_contrast: bool,
    pub locale: Locale,
}

impl Default for LockWorkerConfig {
    fn default() -> Self {
        Self {
            ipc_fd: None,
            pam_service: "kaze-shell".to_string(),
            fprintd: true,
            grace_secs: 0,
            media_controls: true,
            media_keys: true,
            blur: true,
            background_color: "#1f1f28".to_string(),
            wallpaper_path: None,
            username: current_username(),
            real_name: String::new(),
            avatar_path: None,
            font: "JetBrainsMono Nerd Font".to_string(),
            font_scale: 1.0,
            high_contrast: false,
            locale: Locale::En,
        }
    }
}

pub enum LockAsyncMsg {
    PamResult(PamOutcome),
    Fingerprint(FingerprintEvent),
}

struct LockOutputSurface {
    lock_surface: SessionLockSurface,
    pool: SlotPool,
    logical_w: u32,
    logical_h: u32,
    scale: i32,
    configured: bool,
    dirty: bool,
}

#[derive(Clone)]
struct CachedWallpaper {
    width: u32,
    height: u32,
    rgba_premul: Arc<[u8]>,
}

pub fn mask_password_bullets(input: &str) -> String {
    let count = input.graphemes(true).count();
    "\u{2022}".repeat(count)
}

pub fn compute_shake_offset(elapsed_secs: f32) -> f32 {
    if !elapsed_secs.is_finite() || elapsed_secs <= 0.0 || elapsed_secs >= 0.45 {
        return 0.0;
    }
    (elapsed_secs * 46.0).sin() * (-elapsed_secs * 8.0).exp() * 14.0
}

pub fn is_within_grace(locked_at: Instant, now: Instant, grace_secs: u64) -> bool {
    grace_secs > 0 && now.saturating_duration_since(locked_at) < Duration::from_secs(grace_secs)
}

fn prepare_blurred_base(path: &Path, blur: bool) -> Option<RgbaImage> {
    let reader = ImageReader::open(path).ok()?.with_guessed_format().ok()?;
    let decoded = reader.decode().ok()?;
    let (w, h) = (decoded.width().max(1), decoded.height().max(1));
    let work_w = if blur { w.min(480) } else { w.min(1920) };
    let work_h = ((u64::from(h) * u64::from(work_w)) / u64::from(w)).max(1) as u32;
    let mut img = DynamicImage::ImageRgba8(decoded.to_rgba8())
        .resize_exact(work_w, work_h, FilterType::Triangle)
        .to_rgba8();

    if blur {
        box_blur_rgba(&mut img, 8);
        box_blur_rgba(&mut img, 8);
    }
    // Slight scrim darkening for crisp card contrast.
    for px in img.as_mut().as_chunks_mut::<4>().0 {
        px[0] = ((u16::from(px[0]) * 145) >> 8) as u8;
        px[1] = ((u16::from(px[1]) * 145) >> 8) as u8;
        px[2] = ((u16::from(px[2]) * 145) >> 8) as u8;
        px[3] = 255;
    }
    Some(img)
}

fn box_blur_rgba(img: &mut RgbaImage, radius: usize) {
    let w = img.width() as usize;
    let h = img.height() as usize;
    if w < 2 || h < 2 || radius == 0 {
        return;
    }
    let src = img.as_raw().clone();
    let mut tmp = vec![0u8; src.len()];
    let div = (radius * 2 + 1) as u32;

    // Horizontal pass
    for y in 0..h {
        let row_off = y * w * 4;
        for x in 0..w {
            let mut r = 0u32;
            let mut g = 0u32;
            let mut b = 0u32;
            let x0 = x.saturating_sub(radius);
            let x1 = (x + radius).min(w - 1);
            let left = x as isize - radius as isize;
            let right = x as isize + radius as isize;
            for sx in left..=right {
                let cx = sx.clamp(x0 as isize, x1 as isize) as usize;
                let idx = row_off + cx * 4;
                r += u32::from(src[idx]);
                g += u32::from(src[idx + 1]);
                b += u32::from(src[idx + 2]);
            }
            let out = row_off + x * 4;
            tmp[out] = (r / div) as u8;
            tmp[out + 1] = (g / div) as u8;
            tmp[out + 2] = (b / div) as u8;
            tmp[out + 3] = 255;
        }
    }

    // Vertical pass
    let dst = img.as_mut();
    for y in 0..h {
        let y0 = y.saturating_sub(radius);
        let y1 = (y + radius).min(h - 1);
        let top = y as isize - radius as isize;
        let bot = y as isize + radius as isize;
        for x in 0..w {
            let mut r = 0u32;
            let mut g = 0u32;
            let mut b = 0u32;
            for sy in top..=bot {
                let cy = sy.clamp(y0 as isize, y1 as isize) as usize;
                let idx = (cy * w + x) * 4;
                r += u32::from(tmp[idx]);
                g += u32::from(tmp[idx + 1]);
                b += u32::from(tmp[idx + 2]);
            }
            let out = (y * w + x) * 4;
            dst[out] = (r / div) as u8;
            dst[out + 1] = (g / div) as u8;
            dst[out + 2] = (b / div) as u8;
            dst[out + 3] = 255;
        }
    }
}

fn cover_scale_premul(base: &RgbaImage, out_w: u32, out_h: u32) -> Arc<[u8]> {
    let bw = base.width().max(1);
    let bh = base.height().max(1);
    let scale = (out_w as f32 / bw as f32).max(out_h as f32 / bh as f32);
    let sw = ((bw as f32 * scale).ceil() as u32).max(out_w);
    let sh = ((bh as f32 * scale).ceil() as u32).max(out_h);
    let scaled = DynamicImage::ImageRgba8(base.clone())
        .resize_exact(sw, sh, FilterType::Triangle)
        .to_rgba8();
    let ox = (sw - out_w) / 2;
    let oy = (sh - out_h) / 2;
    let cropped = image::imageops::crop_imm(&scaled, ox, oy, out_w, out_h).to_image();
    Arc::<[u8]>::from(cropped.into_raw())
}

fn load_circular_avatar(path: &Path, size: u32) -> Option<Arc<[u8]>> {
    let reader = ImageReader::open(path).ok()?.with_guessed_format().ok()?;
    let decoded = reader.decode().ok()?;
    let resized = decoded
        .resize_to_fill(size, size, FilterType::Triangle)
        .to_rgba8();
    let mut raw = resized.into_raw();
    let half = size as f32 * 0.5;
    let r2 = half * half;
    for y in 0..size {
        for x in 0..size {
            let dx = x as f32 + 0.5 - half;
            let dy = y as f32 + 0.5 - half;
            let idx = ((y * size + x) as usize) * 4;
            if dx * dx + dy * dy > r2 {
                raw[idx] = 0;
                raw[idx + 1] = 0;
                raw[idx + 2] = 0;
                raw[idx + 3] = 0;
            } else {
                let a = u16::from(raw[idx + 3]);
                raw[idx] = ((u16::from(raw[idx]) * a) / 255) as u8;
                raw[idx + 1] = ((u16::from(raw[idx + 1]) * a) / 255) as u8;
                raw[idx + 2] = ((u16::from(raw[idx + 2]) * a) / 255) as u8;
            }
        }
    }
    Some(Arc::<[u8]>::from(raw))
}

fn handle_media_keysym(keysym: u32) -> bool {
    let (prog, args): (&str, &[&str]) = match keysym {
        0x1008_ff14 => ("playerctl", &["play-pause"]),
        0x1008_ff15 => ("playerctl", &["stop"]),
        0x1008_ff16 => ("playerctl", &["previous"]),
        0x1008_ff17 => ("playerctl", &["next"]),
        0x1008_ff11 => ("wpctl", &["set-volume", "@DEFAULT_AUDIO_SINK@", "5%-"]),
        0x1008_ff12 => ("wpctl", &["set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"]),
        0x1008_ff13 => ("wpctl", &["set-volume", "@DEFAULT_AUDIO_SINK@", "5%+"]),
        _ => return false,
    };
    let _ = Command::new(prog).args(args).spawn();
    true
}

struct LockWorkerState {
    cfg: LockWorkerConfig,
    bg_color: Color,
    wallpaper_base: Option<RgbaImage>,
    wallpaper_cache: HashMap<(u32, u32), CachedWallpaper>,
    avatar_premul: Option<(u32, Arc<[u8]>)>,
    initials: String,
    registry_state: RegistryState,
    compositor_state: CompositorState,
    output_state: OutputState,
    seat_state: SeatState,
    shm: Shm,
    session_lock_state: SessionLockState,
    session_lock: Option<SessionLock>,
    locked: bool,
    locked_at: Instant,
    ipc_notified: bool,
    outputs: HashMap<ObjectId, wl_output::WlOutput>,
    lock_surfaces: HashMap<ObjectId, LockOutputSurface>,
    keyboard: Option<wl_keyboard::WlKeyboard>,
    pointer: Option<wl_pointer::WlPointer>,
    caps_lock: bool,
    layout_idx: u32,
    modifiers: KeyModifiers,
    input: TextInputState,
    keybinds: InputKeybindsConfig,
    authenticating: bool,
    error_message: Option<String>,
    shake_started: Option<Instant>,
    shake_timer_armed: bool,
    clock: ClockTime,
    renderer: Renderer,
    async_tx: CalloopSender<LockAsyncMsg>,
    cancel_fprintd: Arc<AtomicBool>,
    loop_signal: LoopSignal,
    should_unlock: bool,
}

impl LockWorkerState {
    fn notify_ipc_committed(&mut self) {
        if self.ipc_notified {
            return;
        }
        self.ipc_notified = true;
        if let Some(fd) = self.cfg.ipc_fd {
            let msg = b"LOCKED_FRAME_COMMITTED\n";
            // SAFETY: writing a small notification line; `SIGPIPE` is set to `SIG_IGN` and errors are ignored.
            unsafe {
                let _ = libc::write(fd, msg.as_ptr().cast(), msg.len());
                libc::close(fd);
            }
            self.cfg.ipc_fd = None;
        }
    }

    fn ensure_surfaces(&mut self, qh: &QueueHandle<Self>) {
        let Some(ref lock) = self.session_lock else {
            return;
        };
        for (oid, wl_output) in &self.outputs {
            if self.lock_surfaces.contains_key(oid) {
                continue;
            }
            let surface = self.compositor_state.create_surface(qh);
            let lock_surface = lock.create_lock_surface(surface, wl_output, qh);
            if let Ok(pool) = SlotPool::new(1920 * 1080 * 4, &self.shm) {
                self.lock_surfaces.insert(
                    oid.clone(),
                    LockOutputSurface {
                        lock_surface,
                        pool,
                        logical_w: 1920,
                        logical_h: 1080,
                        scale: 1,
                        configured: false,
                        dirty: true,
                    },
                );
            }
        }
    }

    fn mark_all_dirty(&mut self) {
        for s in self.lock_surfaces.values_mut() {
            s.dirty = true;
        }
    }

    fn build_spec(&mut self, logical_w: u32, logical_h: u32, scale: i32) -> SurfaceSpec {
        let lw = logical_w as f32;
        let lh = logical_h as f32;
        let px_w = logical_w.saturating_mul(scale.max(1) as u32);
        let px_h = logical_h.saturating_mul(scale.max(1) as u32);
        let mut commands = Vec::new();

        if let Some(ref base) = self.wallpaper_base {
            let key = (px_w, px_h);
            let cached = self
                .wallpaper_cache
                .entry(key)
                .or_insert_with(|| CachedWallpaper {
                    width: px_w,
                    height: px_h,
                    rgba_premul: cover_scale_premul(base, px_w, px_h),
                })
                .clone();
            commands.push(PaintCmd::Image {
                rect: Rect::new(0.0, 0.0, lw, lh),
                width: cached.width,
                height: cached.height,
                rgba_premul: cached.rgba_premul,
            });
        }

        let shake_dx = self
            .shake_started
            .map(|t| compute_shake_offset(t.elapsed().as_secs_f32()))
            .unwrap_or(0.0);

        let clock_str = self.clock.format_hh_mm();
        commands.push(PaintCmd::Text {
            rect: Rect::new(0.0, (lh * 0.16).max(40.0), lw, 88.0),
            text: clock_str,
            color: Color::rgba(235, 238, 245, 255),
            size: 72.0,
            bold: true,
            align: TextAlign::Center,
        });

        let card_w = 380.0_f32.min((lw - 48.0).max(260.0));
        let card_h = 250.0_f32;
        let card_x = (lw - card_w) * 0.5 + shake_dx;
        let card_y = (lh - card_h) * 0.52;

        commands.push(PaintCmd::RoundedRect {
            rect: Rect::new(card_x, card_y, card_w, card_h),
            radius: 20.0,
            fill: Some(Color::rgba(22, 22, 30, 225)),
            stroke: Some(if self.error_message.is_some() {
                Color::rgba(232, 85, 85, 255)
            } else {
                Color::rgba(255, 255, 255, 34)
            }),
            stroke_width: 1.5,
        });

        let avatar_size = 56.0_f32;
        let avatar_x = card_x + (card_w - avatar_size) * 0.5;
        let avatar_y = card_y + 20.0;
        if let Some((img_sz, ref rgba)) = self.avatar_premul {
            commands.push(PaintCmd::Image {
                rect: Rect::new(avatar_x, avatar_y, avatar_size, avatar_size),
                width: img_sz,
                height: img_sz,
                rgba_premul: Arc::clone(rgba),
            });
        } else {
            commands.push(PaintCmd::Circle {
                cx: avatar_x + avatar_size * 0.5,
                cy: avatar_y + avatar_size * 0.5,
                radius: avatar_size * 0.5,
                fill: Color::rgba(122, 162, 247, 255),
            });
            commands.push(PaintCmd::RichText {
                rect: Rect::new(avatar_x, avatar_y, avatar_size, avatar_size),
                text: self.initials.clone(),
                color: Color::rgba(22, 22, 30, 255),
                size: 20.0,
                bold: true,
                align: TextAlign::Center,
                max_lines: 1,
            });
        }

        let display_name = if self.cfg.real_name.trim().is_empty() {
            &self.cfg.username
        } else {
            &self.cfg.real_name
        };
        commands.push(PaintCmd::RichText {
            rect: Rect::new(card_x + 16.0, avatar_y + avatar_size + 10.0, card_w - 32.0, 26.0),
            text: display_name.to_string(),
            color: Color::rgba(235, 238, 245, 255),
            size: 16.0,
            bold: true,
            align: TextAlign::Center,
            max_lines: 1,
        });

        let field_x = card_x + 24.0;
        let field_y = card_y + 128.0;
        let field_w = card_w - 48.0;
        let field_h = 40.0;
        commands.push(PaintCmd::RoundedRect {
            rect: Rect::new(field_x, field_y, field_w, field_h),
            radius: 10.0,
            fill: Some(Color::rgba(36, 36, 50, 240)),
            stroke: Some(Color::rgba(140, 168, 255, 110)),
            stroke_width: 1.0,
        });

        let masked = mask_password_bullets(&self.input.text);
        let cursor_graphemes = self.input.text[..self.input.cursor.min(self.input.text.len())]
            .graphemes(true)
            .count();
        let placeholder = if self.authenticating {
            t(self.cfg.locale, I18nKey::LockUnlocking).to_string()
        } else {
            t(self.cfg.locale, I18nKey::LockPasswordPlaceholder).to_string()
        };
        commands.push(PaintCmd::TextInputField {
            rect: Rect::new(field_x + 12.0, field_y, field_w - 24.0, field_h),
            text: masked,
            preedit: String::new(),
            cursor_byte: cursor_graphemes * 3,
            selection: None,
            placeholder,
            password_mode: true,
            color: Color::rgba(238, 241, 248, 255),
            preedit_color: Color::rgba(122, 162, 247, 255),
            selection_color: Color::rgba(122, 162, 247, 90),
            placeholder_color: Color::rgba(200, 204, 220, 120),
            size: 15.0,
        });

        let status_text = if let Some(ref err) = self.error_message {
            err.clone()
        } else {
            let mut flags = Vec::new();
            if self.caps_lock {
                flags.push(t(self.cfg.locale, I18nKey::PolkitCapsLock).to_string());
            }
            if self.layout_idx > 0 {
                flags.push(format!("Layout #{}", self.layout_idx + 1));
            }
            if self.cfg.fprintd {
                flags.push("PAM / Fingerprint".to_string());
            }
            flags.join("  •  ")
        };
        if !status_text.is_empty() {
            commands.push(PaintCmd::RichText {
                rect: Rect::new(card_x + 16.0, field_y + field_h + 12.0, card_w - 32.0, 24.0),
                text: status_text,
                color: if self.error_message.is_some() {
                    Color::rgba(243, 139, 168, 255)
                } else {
                    Color::rgba(200, 205, 220, 180)
                },
                size: 12.5,
                bold: false,
                align: TextAlign::Center,
                max_lines: 1,
            });
        }

        SurfaceSpec {
            id: "lock:screen".into(),
            namespace: "kaze-lock".into(),
            output: None,
            layer: Layer::Overlay,
            keyboard_interactivity: KeyboardMode::Exclusive,
            anchor: Anchor::TOP | Anchor::BOTTOM | Anchor::LEFT | Anchor::RIGHT,
            exclusive_zone: -1,
            width: logical_w,
            height: logical_h,
            margin: EdgeInsets::default(),
            corner_radius: 0.0,
            background: self.bg_color,
            border_color: Color::TRANSPARENT,
            border_width: 0.0,
            commands,
            hit_targets: Vec::new(),
            animating: false,
            input_regions: None,
            ime_cursor_rect: None,
        }
    }

    fn redraw_dirty(&mut self, conn: &Connection) {
        let keys: Vec<ObjectId> = self
            .lock_surfaces
            .iter()
            .filter_map(|(oid, s)| (s.configured && s.dirty).then_some(oid.clone()))
            .collect();
        if keys.is_empty() {
            return;
        }
        let mut any_committed = false;
        for oid in keys {
            let Some((lw, lh, scale)) = self
                .lock_surfaces
                .get(&oid)
                .map(|s| (s.logical_w, s.logical_h, s.scale))
            else {
                continue;
            };
            let spec = self.build_spec(lw, lh, scale);
            let px_w = (lw.max(1)).saturating_mul(scale.max(1) as u32);
            let px_h = (lh.max(1)).saturating_mul(scale.max(1) as u32);
            let stride = (px_w * 4) as i32;
            let Some(s) = self.lock_surfaces.get_mut(&oid) else {
                continue;
            };
            let Ok((buf, canvas)) =
                s.pool
                    .create_buffer(px_w as i32, px_h as i32, stride, wl_shm::Format::Argb8888)
            else {
                continue;
            };
            self.renderer.render_spec(&spec, lw, lh, scale, canvas);
            let wl_surf = s.lock_surface.wl_surface();
            wl_surf.set_buffer_scale(scale.max(1));
            let _ = buf.attach_to(wl_surf);
            wl_surf.damage_buffer(0, 0, px_w as i32, px_h as i32);
            wl_surf.commit();
            s.dirty = false;
            any_committed = true;
        }
        let _ = conn.flush();
        if any_committed && self.locked {
            self.notify_ipc_committed();
        }
    }

    fn submit_password(&mut self) {
        if self.authenticating || self.input.text.is_empty() {
            return;
        }
        self.authenticating = true;
        self.error_message = None;
        let pw = Zeroizing::new(std::mem::take(&mut self.input.text));
        self.input.clear();
        self.mark_all_dirty();

        let service = self.cfg.pam_service.clone();
        let username = self.cfg.username.clone();
        let tx = self.async_tx.clone();
        let _ = std::thread::Builder::new()
            .name("kaze-pam".to_string())
            .spawn(move || {
                let outcome = authenticate(&service, &username, pw);
                let _ = tx.send(LockAsyncMsg::PamResult(outcome));
            });
    }

    fn trigger_unlock(&mut self) {
        self.cancel_fprintd.store(true, Ordering::Relaxed);
        self.input.clear();
        self.should_unlock = true;
        if let Some(ref lock) = self.session_lock {
            lock.unlock();
        }
        self.loop_signal.stop();
    }
}

pub fn run_lock_worker(cfg: LockWorkerConfig) -> Result<(), String> {
    // SAFETY: ignoring SIGPIPE guarantees `kill -9 <daemon>` cannot terminate lock-worker on pipe write.
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
    }

    let conn =
        Connection::connect_to_env().map_err(|e| format!("failed to connect Wayland: {e}"))?;
    let (globals, mut event_queue): (_, EventQueue<LockWorkerState>) =
        registry_queue_init(&conn).map_err(|e| format!("failed registry init: {e}"))?;
    let qh = event_queue.handle();

    let (async_tx, async_rx) = channel::channel::<LockAsyncMsg>();
    let mut event_loop: EventLoop<'static, LockWorkerState> =
        EventLoop::try_new().map_err(|e| format!("failed creating event loop: {e}"))?;
    let loop_handle = event_loop.handle();
    let loop_signal = event_loop.get_signal();

    let compositor_state =
        CompositorState::bind(&globals, &qh).map_err(|e| format!("no wl_compositor: {e}"))?;
    let shm = Shm::bind(&globals, &qh).map_err(|e| format!("no wl_shm: {e}"))?;
    let output_state = OutputState::new(&globals, &qh);
    let seat_state = SeatState::new(&globals, &qh);
    let session_lock_state = SessionLockState::new(&globals, &qh);

    let bg_color = Color::from_hex(&cfg.background_color).unwrap_or(Color::rgba(31, 31, 40, 255));
    let wallpaper_base = cfg
        .wallpaper_path
        .as_deref()
        .and_then(|p| prepare_blurred_base(p, cfg.blur));
    let avatar_premul = cfg
        .avatar_path
        .as_deref()
        .and_then(|p| load_circular_avatar(p, 96).map(|r| (96, r)));
    let display_name = if cfg.real_name.trim().is_empty() {
        cfg.username.as_str()
    } else {
        cfg.real_name.as_str()
    };
    let initials = kaze_core::state::compute_initials(display_name);
    let mut renderer = Renderer::new(&cfg.font);
    renderer.set_accessibility(cfg.font_scale, cfg.high_contrast);
    let (clock, first_min_wait) = ClockTime::now_and_duration_to_next_minute();
    let cancel_fprintd = Arc::new(AtomicBool::new(false));

    let mut state = LockWorkerState {
        cfg,
        bg_color,
        wallpaper_base,
        wallpaper_cache: HashMap::new(),
        avatar_premul,
        initials,
        registry_state: RegistryState::new(&globals),
        compositor_state,
        output_state,
        seat_state,
        shm,
        session_lock_state,
        session_lock: None,
        locked: false,
        locked_at: Instant::now(),
        ipc_notified: false,
        outputs: HashMap::new(),
        lock_surfaces: HashMap::new(),
        keyboard: None,
        pointer: None,
        caps_lock: false,
        layout_idx: 0,
        modifiers: KeyModifiers::default(),
        input: TextInputState::new(true),
        keybinds: InputKeybindsConfig::default(),
        authenticating: false,
        error_message: None,
        shake_started: None,
        shake_timer_armed: false,
        clock,
        renderer,
        async_tx: async_tx.clone(),
        cancel_fprintd: Arc::clone(&cancel_fprintd),
        loop_signal,
        should_unlock: false,
    };

    // Discover initial outputs and seats before locking.
    event_queue
        .roundtrip(&mut state)
        .map_err(|e| format!("initial Wayland roundtrip failed: {e}"))?;

    let lock = state
        .session_lock_state
        .lock(&qh)
        .map_err(|e| format!("ext-session-lock-v1 unavailable: {e}"))?;
    state.session_lock = Some(lock);
    state.ensure_surfaces(&qh);
    let _ = conn.flush();

    if state.cfg.fprintd {
        let fp_tx = async_tx;
        spawn_fprintd_listener(
            state.cfg.username.clone(),
            Arc::clone(&cancel_fprintd),
            move |ev| {
                let _ = fp_tx.send(LockAsyncMsg::Fingerprint(ev));
            },
        );
    }

    // Minute clock tick timer (0Hz idle polling between minute boundaries).
    loop_handle
        .insert_source(Timer::from_duration(first_min_wait), |_, _, st| {
            let (next_clock, next_wait) = ClockTime::now_and_duration_to_next_minute();
            st.clock = next_clock;
            st.mark_all_dirty();
            TimeoutAction::ToDuration(next_wait)
        })
        .map_err(|e| format!("failed clock timer: {e}"))?;

    // Async PAM + fprintd channel
    let loop_handle_for_async = loop_handle.clone();
    loop_handle
        .insert_source(async_rx, move |ev, _, st| match ev {
            channel::Event::Msg(LockAsyncMsg::PamResult(PamOutcome::Authenticated))
            | channel::Event::Msg(LockAsyncMsg::Fingerprint(FingerprintEvent::Matched)) => {
                st.authenticating = false;
                st.trigger_unlock();
            }
            channel::Event::Msg(LockAsyncMsg::PamResult(PamOutcome::Failed(msg))) => {
                st.authenticating = false;
                st.input.clear();
                st.error_message = Some(msg);
                st.shake_started = Some(Instant::now());
                st.mark_all_dirty();
                if !st.shake_timer_armed {
                    st.shake_timer_armed = true;
                    let _ = loop_handle_for_async.insert_source(
                        Timer::from_duration(Duration::from_millis(16)),
                        |_, _, state| {
                            let active = state
                                .shake_started
                                .is_some_and(|t| t.elapsed().as_secs_f32() < 0.45);
                            state.mark_all_dirty();
                            if active {
                                TimeoutAction::ToDuration(Duration::from_millis(16))
                            } else {
                                state.shake_started = None;
                                state.shake_timer_armed = false;
                                TimeoutAction::Drop
                            }
                        },
                    );
                }
            }
            channel::Event::Msg(LockAsyncMsg::Fingerprint(FingerprintEvent::NoMatch)) => {
                st.error_message = Some("Fingerprint not recognized".to_string());
                st.mark_all_dirty();
            }
            channel::Event::Closed => {}
        })
        .map_err(|e| format!("failed async channel: {e}"))?;

    let wayland_source = WaylandSource::new(conn.clone(), event_queue);
    loop_handle
        .insert_source(wayland_source, |_, queue, st| {
            let dispatched = queue.dispatch_pending(st)?;
            Ok(dispatched)
        })
        .map_err(|e| format!("failed wayland source: {e}"))?;

    while !state.should_unlock {
        event_loop
            .dispatch(None, &mut state)
            .map_err(|e| format!("event loop error: {e}"))?;
        state.redraw_dirty(&conn);
    }

    cancel_fprintd.store(true, Ordering::Relaxed);
    let _ = conn.roundtrip();
    Ok(())
}

impl ProvidesRegistryState for LockWorkerState {
    fn registry(&mut self) -> &mut RegistryState {
        &mut self.registry_state
    }
    smithay_client_toolkit::registry_handlers!(OutputState, SeatState);
}

impl CompositorHandler for LockWorkerState {
    fn scale_factor_changed(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        surface: &wl_surface::WlSurface,
        new_factor: i32,
    ) {
        let factor = new_factor.max(1);
        for s in self.lock_surfaces.values_mut() {
            if s.lock_surface.wl_surface().id() == surface.id() && s.scale != factor {
                s.scale = factor;
                s.dirty = true;
            }
        }
    }

    fn transform_changed(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        _surface: &wl_surface::WlSurface,
        _new_transform: wl_output::Transform,
    ) {
    }

    fn frame(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        _surface: &wl_surface::WlSurface,
        _time: u32,
    ) {
    }

    fn surface_enter(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        _surface: &wl_surface::WlSurface,
        _output: &wl_output::WlOutput,
    ) {
    }

    fn surface_leave(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        _surface: &wl_surface::WlSurface,
        _output: &wl_output::WlOutput,
    ) {
    }
}

impl OutputHandler for LockWorkerState {
    fn output_state(&mut self) -> &mut OutputState {
        &mut self.output_state
    }

    fn new_output(
        &mut self,
        conn: &Connection,
        qh: &QueueHandle<Self>,
        output: wl_output::WlOutput,
    ) {
        self.outputs.insert(output.id(), output);
        if self.session_lock.is_some() {
            self.ensure_surfaces(qh);
            let _ = conn.flush();
        }
    }

    fn update_output(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        _output: wl_output::WlOutput,
    ) {
    }

    fn output_destroyed(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        output: wl_output::WlOutput,
    ) {
        let id = output.id();
        self.outputs.remove(&id);
        self.lock_surfaces.remove(&id);
    }
}

impl ShmHandler for LockWorkerState {
    fn shm_state(&mut self) -> &mut Shm {
        &mut self.shm
    }
}

impl SeatHandler for LockWorkerState {
    fn seat_state(&mut self) -> &mut SeatState {
        &mut self.seat_state
    }

    fn new_seat(&mut self, _conn: &Connection, _qh: &QueueHandle<Self>, _seat: wl_seat::WlSeat) {}

    fn new_capability(
        &mut self,
        _conn: &Connection,
        qh: &QueueHandle<Self>,
        seat: wl_seat::WlSeat,
        capability: Capability,
    ) {
        if capability == Capability::Keyboard && self.keyboard.is_none() {
            if let Ok(kb) = self.seat_state.get_keyboard(qh, &seat, None) {
                self.keyboard = Some(kb);
            }
        }
        if capability == Capability::Pointer && self.pointer.is_none() {
            if let Ok(pt) = self.seat_state.get_pointer(qh, &seat) {
                self.pointer = Some(pt);
            }
        }
    }

    fn remove_capability(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        _seat: wl_seat::WlSeat,
        capability: Capability,
    ) {
        if capability == Capability::Keyboard {
            if let Some(kb) = self.keyboard.take() {
                kb.release();
            }
        }
        if capability == Capability::Pointer {
            if let Some(pt) = self.pointer.take() {
                pt.release();
            }
        }
    }

    fn remove_seat(&mut self, _conn: &Connection, _qh: &QueueHandle<Self>, _seat: wl_seat::WlSeat) {
    }
}

impl KeyboardHandler for LockWorkerState {
    fn enter(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        _keyboard: &wl_keyboard::WlKeyboard,
        _surface: &wl_surface::WlSurface,
        _serial: u32,
        _raw: &[u32],
        _keysyms: &[Keysym],
    ) {
    }

    fn leave(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        _keyboard: &wl_keyboard::WlKeyboard,
        _surface: &wl_surface::WlSurface,
        _serial: u32,
    ) {
    }

    fn press_key(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        _keyboard: &wl_keyboard::WlKeyboard,
        _serial: u32,
        event: SctkKeyEvent,
    ) {
        if self.locked && is_within_grace(self.locked_at, Instant::now(), self.cfg.grace_secs) {
            self.trigger_unlock();
            return;
        }
        if self.cfg.media_keys && handle_media_keysym(event.keysym.raw()) {
            return;
        }
        let key = KeyEvent {
            keysym: event.keysym.raw(),
            utf8: event.utf8,
            modifiers: self.modifiers,
            pressed: true,
        };
        match self.input.handle_key(&key, &self.keybinds) {
            TextInputOutcome::Submit => self.submit_password(),
            TextInputOutcome::Cancel => {
                if !self.authenticating && !self.input.text.is_empty() {
                    self.input.clear();
                    self.error_message = None;
                    self.mark_all_dirty();
                }
            }
            TextInputOutcome::Changed => {
                self.error_message = None;
                self.mark_all_dirty();
            }
            _ => {}
        }
    }

    fn repeat_key(
        &mut self,
        conn: &Connection,
        qh: &QueueHandle<Self>,
        keyboard: &wl_keyboard::WlKeyboard,
        serial: u32,
        event: SctkKeyEvent,
    ) {
        self.press_key(conn, qh, keyboard, serial, event);
    }

    fn release_key(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        _keyboard: &wl_keyboard::WlKeyboard,
        _serial: u32,
        _event: SctkKeyEvent,
    ) {
    }

    fn update_modifiers(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        _keyboard: &wl_keyboard::WlKeyboard,
        _serial: u32,
        modifiers: Modifiers,
        _raw_modifiers: RawModifiers,
        layout: u32,
    ) {
        let prev_caps = self.caps_lock;
        let prev_layout = self.layout_idx;
        self.caps_lock = modifiers.caps_lock;
        self.layout_idx = layout;
        self.modifiers = KeyModifiers {
            ctrl: modifiers.ctrl,
            alt: modifiers.alt,
            shift: modifiers.shift,
            logo: modifiers.logo,
        };
        if prev_caps != self.caps_lock || prev_layout != self.layout_idx {
            self.mark_all_dirty();
        }
    }
}

impl PointerHandler for LockWorkerState {
    fn pointer_frame(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        _pointer: &wl_pointer::WlPointer,
        events: &[PointerEvent],
    ) {
        if self.locked
            && events.iter().any(|e| {
                matches!(
                    e.kind,
                    PointerEventKind::Motion { .. } | PointerEventKind::Press { .. }
                )
            })
            && is_within_grace(self.locked_at, Instant::now(), self.cfg.grace_secs)
        {
            self.trigger_unlock();
        }
    }
}

impl SessionLockHandler for LockWorkerState {
    fn locked(&mut self, conn: &Connection, qh: &QueueHandle<Self>, session_lock: SessionLock) {
        if self.session_lock.as_ref().is_none() {
            self.session_lock = Some(session_lock);
        }
        self.locked = true;
        self.locked_at = Instant::now();
        self.ensure_surfaces(qh);
        let _ = conn.flush();
    }

    fn finished(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        _session_lock: SessionLock,
    ) {
        self.should_unlock = true;
        self.loop_signal.stop();
    }

    fn configure(
        &mut self,
        conn: &Connection,
        _qh: &QueueHandle<Self>,
        surface: SessionLockSurface,
        configure: SessionLockSurfaceConfigure,
        _serial: u32,
    ) {
        let w = configure.new_size.0.max(1);
        let h = configure.new_size.1.max(1);
        for s in self.lock_surfaces.values_mut() {
            if s.lock_surface.wl_surface().id() == surface.wl_surface().id() {
                s.logical_w = w;
                s.logical_h = h;
                s.configured = true;
                s.dirty = true;
            }
        }
        self.redraw_dirty(conn);
    }
}

delegate_compositor!(LockWorkerState);
delegate_output!(LockWorkerState);
delegate_shm!(LockWorkerState);
delegate_seat!(LockWorkerState);
delegate_keyboard!(LockWorkerState);
delegate_pointer!(LockWorkerState);
delegate_session_lock!(LockWorkerState);
delegate_registry!(LockWorkerState);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn password_bullets_match_grapheme_count() {
        assert_eq!(mask_password_bullets("abc"), "•••");
        assert_eq!(mask_password_bullets("Tiếng"), "•••••");
        assert_eq!(mask_password_bullets("a👨‍👩‍👧b"), "•••");
    }

    #[test]
    fn shake_offset_peaks_then_decays_to_exact_zero() {
        assert_eq!(compute_shake_offset(0.0), 0.0);
        assert!(compute_shake_offset(0.03).abs() > 2.0);
        assert_eq!(compute_shake_offset(0.45), 0.0);
        assert_eq!(compute_shake_offset(1.0), 0.0);
    }

    #[test]
    fn grace_period_respects_expiry() {
        let start = Instant::now();
        assert!(!is_within_grace(start, start, 0));
        assert!(is_within_grace(start, start + Duration::from_secs(2), 5));
        assert!(!is_within_grace(start, start + Duration::from_secs(5), 5));
    }

    #[test]
    fn password_text_input_clears_and_never_exposes_plaintext_when_masked() {
        let mut st = TextInputState::new(true);
        st.set_text("super-secret");
        assert_eq!(mask_password_bullets(&st.text), "••••••••••••");
        assert!(!mask_password_bullets(&st.text).contains("secret"));
        st.clear();
        assert!(st.text.is_empty());
    }
}
