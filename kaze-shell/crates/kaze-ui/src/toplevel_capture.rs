#![deny(clippy::unwrap_used)]

use crate::screencopy::{
    create_transient_shm_buffer, normalize_screencopy_buffer, CapturePixelFormat, OutputTransform,
    TransientShmBuffer,
};
use crate::UiState;
use kaze_core::SystemEvent;
use smithay_client_toolkit::reexports::client::backend::ObjectId;
use smithay_client_toolkit::reexports::client::globals::GlobalList;
use smithay_client_toolkit::reexports::client::{Connection, Dispatch, Proxy, QueueHandle, WEnum};
use smithay_client_toolkit::shm::Shm;
use std::collections::HashMap;
use std::sync::Arc;
use wayland_protocols::ext::foreign_toplevel_list::v1::client::{
    ext_foreign_toplevel_handle_v1::{self, ExtForeignToplevelHandleV1},
    ext_foreign_toplevel_list_v1::{self, ExtForeignToplevelListV1},
};
use wayland_protocols::ext::image_capture_source::v1::client::{
    ext_foreign_toplevel_image_capture_source_manager_v1::ExtForeignToplevelImageCaptureSourceManagerV1,
    ext_image_capture_source_v1::ExtImageCaptureSourceV1,
};
use wayland_protocols::ext::image_copy_capture::v1::client::{
    ext_image_copy_capture_frame_v1::{self, ExtImageCopyCaptureFrameV1},
    ext_image_copy_capture_manager_v1::{ExtImageCopyCaptureManagerV1, Options},
    ext_image_copy_capture_session_v1::{self, ExtImageCopyCaptureSessionV1},
};

struct TrackedToplevel {
    handle: ExtForeignToplevelHandleV1,
    app_id: String,
    title: String,
    pending_app_id: String,
    pending_title: String,
}

impl Drop for TrackedToplevel {
    fn drop(&mut self) {
        self.handle.destroy();
    }
}

struct ActivePreviewSession {
    request_id: u64,
    address: String,
    source: ExtImageCaptureSourceV1,
    session: ExtImageCopyCaptureSessionV1,
    frame: Option<ExtImageCopyCaptureFrameV1>,
    width: u32,
    height: u32,
    format: Option<CapturePixelFormat>,
    transform: OutputTransform,
    max_width: u32,
    capture_sent: bool,
    shm_buf: Option<TransientShmBuffer>,
}

impl Drop for ActivePreviewSession {
    fn drop(&mut self) {
        self.shm_buf.take();
        if let Some(frame) = self.frame.take() {
            frame.destroy();
        }
        self.session.destroy();
        self.source.destroy();
    }
}

#[derive(Default)]
pub struct ToplevelCaptureState {
    list_global: Option<ExtForeignToplevelListV1>,
    source_mgr: Option<ExtForeignToplevelImageCaptureSourceManagerV1>,
    copy_mgr: Option<ExtImageCopyCaptureManagerV1>,
    toplevels: HashMap<ObjectId, TrackedToplevel>,
    sessions: HashMap<ObjectId, ActivePreviewSession>,
    session_by_frame: HashMap<ObjectId, ObjectId>,
}

impl ToplevelCaptureState {
    pub fn bind_globals(globals: &GlobalList, qh: &QueueHandle<UiState>) -> Self {
        let list_global = globals
            .bind::<ExtForeignToplevelListV1, _, _>(qh, 1..=1, ())
            .ok();
        let source_mgr = globals
            .bind::<ExtForeignToplevelImageCaptureSourceManagerV1, _, _>(qh, 1..=1, ())
            .ok();
        let copy_mgr = globals
            .bind::<ExtImageCopyCaptureManagerV1, _, _>(qh, 1..=1, ())
            .ok();
        Self {
            list_global,
            source_mgr,
            copy_mgr,
            toplevels: HashMap::new(),
            sessions: HashMap::new(),
            session_by_frame: HashMap::new(),
        }
    }

    pub fn is_available(&self) -> bool {
        self.list_global.is_some() && self.source_mgr.is_some() && self.copy_mgr.is_some()
    }

    pub fn clear_in_flight(&mut self) {
        self.session_by_frame.clear();
        self.sessions.clear();
    }

    pub fn request_previews(
        &mut self,
        request_id: u64,
        windows: &[(String, String, String)],
        max_width: u32,
        qh: &QueueHandle<UiState>,
    ) {
        // Drop any previous preview captures immediately so transient SHM buffers never accumulate.
        self.clear_in_flight();

        let (Some(src_mgr), Some(copy_mgr)) = (self.source_mgr.as_ref(), self.copy_mgr.as_ref())
        else {
            return;
        };

        let candidates: Vec<(ObjectId, &str, &str)> = self
            .toplevels
            .iter()
            .map(|(oid, t)| (oid.clone(), t.app_id.as_str(), t.title.as_str()))
            .collect();

        for (address, class, title) in windows.iter().take(12) {
            let Some(handle_oid) = match_toplevel_oid(&candidates, class, title) else {
                continue;
            };
            let Some(tracked) = self.toplevels.get(&handle_oid) else {
                continue;
            };
            let source = src_mgr.create_source(&tracked.handle, qh, ());
            let session = copy_mgr.create_session(&source, Options::empty(), qh, ());
            let sess_oid = session.id();
            self.sessions.insert(
                sess_oid,
                ActivePreviewSession {
                    request_id,
                    address: address.clone(),
                    source,
                    session,
                    frame: None,
                    width: 0,
                    height: 0,
                    format: None,
                    transform: OutputTransform::Normal,
                    max_width: max_width.clamp(64, 640),
                    capture_sent: false,
                    shm_buf: None,
                },
            );
        }
    }
}

pub fn match_toplevel_oid(
    candidates: &[(ObjectId, &str, &str)],
    class: &str,
    title: &str,
) -> Option<ObjectId> {
    let cls_l = class.trim().to_ascii_lowercase();
    let title_l = title.trim().to_ascii_lowercase();
    candidates
        .iter()
        .find(|(_, app, t)| {
            !cls_l.is_empty()
                && app.trim().to_ascii_lowercase() == cls_l
                && !title_l.is_empty()
                && t.trim().to_ascii_lowercase() == title_l
        })
        .or_else(|| {
            candidates
                .iter()
                .find(|(_, _, t)| !title_l.is_empty() && t.trim().to_ascii_lowercase() == title_l)
        })
        .or_else(|| {
            candidates
                .iter()
                .find(|(_, app, _)| !cls_l.is_empty() && app.trim().to_ascii_lowercase() == cls_l)
        })
        .map(|(oid, _, _)| oid.clone())
}

pub fn downscale_straight_rgba_to_premul(
    rgba: &[u8],
    src_w: u32,
    src_h: u32,
    max_width: u32,
) -> (u32, u32, Arc<[u8]>) {
    if src_w == 0 || src_h == 0 || rgba.len() < (src_w as usize) * (src_h as usize) * 4 {
        return (0, 0, Arc::from([]));
    }
    let target_w = if src_w <= max_width {
        src_w
    } else {
        max_width.max(1)
    };
    let target_h = ((u64::from(src_h) * u64::from(target_w)) / u64::from(src_w)).max(1) as u32;
    let mut out = vec![0u8; (target_w as usize) * (target_h as usize) * 4];
    for dy in 0..target_h {
        let sy = ((u64::from(dy) * u64::from(src_h)) / u64::from(target_h)) as usize;
        for dx in 0..target_w {
            let sx = ((u64::from(dx) * u64::from(src_w)) / u64::from(target_w)) as usize;
            let si = (sy * src_w as usize + sx) * 4;
            let di = (dy as usize * target_w as usize + dx as usize) * 4;
            let a = u16::from(rgba[si + 3]);
            out[di] = ((u16::from(rgba[si]) * a + 127) / 255) as u8;
            out[di + 1] = ((u16::from(rgba[si + 1]) * a + 127) / 255) as u8;
            out[di + 2] = ((u16::from(rgba[si + 2]) * a + 127) / 255) as u8;
            out[di + 3] = rgba[si + 3];
        }
    }
    (target_w, target_h, Arc::<[u8]>::from(out))
}

fn start_capture_for_session(
    sess: &mut ActivePreviewSession,
    shm: &Shm,
    qh: &QueueHandle<UiState>,
) -> Option<ObjectId> {
    if sess.capture_sent || sess.width == 0 || sess.height == 0 {
        return None;
    }
    let fmt = sess.format?;
    let stride = sess.width.checked_mul(4)?;
    let shm_buf = create_transient_shm_buffer(shm, qh, sess.width, sess.height, stride, fmt)?;
    let frame = sess.session.create_frame(qh, ());
    let frame_oid = frame.id();
    frame.attach_buffer(&shm_buf.wl_buf);
    frame.damage_buffer(0, 0, sess.width as i32, sess.height as i32);
    frame.capture();
    sess.shm_buf = Some(shm_buf);
    sess.frame = Some(frame);
    sess.capture_sent = true;
    Some(frame_oid)
}

impl Dispatch<ExtForeignToplevelListV1, ()> for UiState {
    fn event(
        state: &mut Self,
        _proxy: &ExtForeignToplevelListV1,
        event: ext_foreign_toplevel_list_v1::Event,
        _data: &(),
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
        match event {
            ext_foreign_toplevel_list_v1::Event::Toplevel { toplevel } => {
                let oid = toplevel.id();
                state.toplevel_capture.toplevels.insert(
                    oid,
                    TrackedToplevel {
                        handle: toplevel,
                        app_id: String::new(),
                        title: String::new(),
                        pending_app_id: String::new(),
                        pending_title: String::new(),
                    },
                );
            }
            ext_foreign_toplevel_list_v1::Event::Finished => {
                state.toplevel_capture.toplevels.clear();
            }
            _ => {}
        }
    }

    smithay_client_toolkit::reexports::client::event_created_child!(UiState, ExtForeignToplevelListV1, [
        ext_foreign_toplevel_list_v1::EVT_TOPLEVEL_OPCODE => (ExtForeignToplevelHandleV1, ())
    ]);
}

impl Dispatch<ExtForeignToplevelHandleV1, ()> for UiState {
    fn event(
        state: &mut Self,
        proxy: &ExtForeignToplevelHandleV1,
        event: ext_foreign_toplevel_handle_v1::Event,
        _data: &(),
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
        let oid = proxy.id();
        match event {
            ext_foreign_toplevel_handle_v1::Event::Title { title } => {
                if let Some(t) = state.toplevel_capture.toplevels.get_mut(&oid) {
                    t.pending_title = title;
                }
            }
            ext_foreign_toplevel_handle_v1::Event::AppId { app_id } => {
                if let Some(t) = state.toplevel_capture.toplevels.get_mut(&oid) {
                    t.pending_app_id = app_id;
                }
            }
            ext_foreign_toplevel_handle_v1::Event::Done => {
                if let Some(t) = state.toplevel_capture.toplevels.get_mut(&oid) {
                    t.title = t.pending_title.clone();
                    t.app_id = t.pending_app_id.clone();
                }
            }
            ext_foreign_toplevel_handle_v1::Event::Closed => {
                state.toplevel_capture.toplevels.remove(&oid);
            }
            _ => {}
        }
    }
}

impl Dispatch<ExtForeignToplevelImageCaptureSourceManagerV1, ()> for UiState {
    fn event(
        _state: &mut Self,
        _proxy: &ExtForeignToplevelImageCaptureSourceManagerV1,
        _event: <ExtForeignToplevelImageCaptureSourceManagerV1 as Proxy>::Event,
        _data: &(),
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<ExtImageCaptureSourceV1, ()> for UiState {
    fn event(
        _state: &mut Self,
        _proxy: &ExtImageCaptureSourceV1,
        _event: <ExtImageCaptureSourceV1 as Proxy>::Event,
        _data: &(),
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<ExtImageCopyCaptureManagerV1, ()> for UiState {
    fn event(
        _state: &mut Self,
        _proxy: &ExtImageCopyCaptureManagerV1,
        _event: <ExtImageCopyCaptureManagerV1 as Proxy>::Event,
        _data: &(),
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<ExtImageCopyCaptureSessionV1, ()> for UiState {
    fn event(
        state: &mut Self,
        proxy: &ExtImageCopyCaptureSessionV1,
        event: ext_image_copy_capture_session_v1::Event,
        _data: &(),
        conn: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        let sess_oid = proxy.id();
        match event {
            ext_image_copy_capture_session_v1::Event::BufferSize { width, height } => {
                if let Some(s) = state.toplevel_capture.sessions.get_mut(&sess_oid) {
                    s.width = width;
                    s.height = height;
                }
            }
            ext_image_copy_capture_session_v1::Event::ShmFormat { format } => {
                if let Some(parsed) = CapturePixelFormat::from_wl_shm(format) {
                    if let Some(s) = state.toplevel_capture.sessions.get_mut(&sess_oid) {
                        if s.format.is_none() {
                            s.format = Some(parsed);
                        }
                    }
                }
            }
            ext_image_copy_capture_session_v1::Event::Done => {
                let frame_oid = state
                    .toplevel_capture
                    .sessions
                    .get_mut(&sess_oid)
                    .and_then(|s| start_capture_for_session(s, &state.shm, qh));
                if let Some(fid) = frame_oid {
                    state
                        .toplevel_capture
                        .session_by_frame
                        .insert(fid, sess_oid);
                    let _ = conn.flush();
                } else {
                    state.toplevel_capture.sessions.remove(&sess_oid);
                }
            }
            ext_image_copy_capture_session_v1::Event::Stopped => {
                if let Some(s) = state.toplevel_capture.sessions.remove(&sess_oid) {
                    if let Some(ref f) = s.frame {
                        state.toplevel_capture.session_by_frame.remove(&f.id());
                    }
                }
            }
            _ => {}
        }
    }
}

impl Dispatch<ExtImageCopyCaptureFrameV1, ()> for UiState {
    fn event(
        state: &mut Self,
        proxy: &ExtImageCopyCaptureFrameV1,
        event: ext_image_copy_capture_frame_v1::Event,
        _data: &(),
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
        let frame_oid = proxy.id();
        match event {
            ext_image_copy_capture_frame_v1::Event::Transform {
                transform: WEnum::Value(t),
            } => {
                if let Some(sess_oid) = state.toplevel_capture.session_by_frame.get(&frame_oid) {
                    if let Some(s) = state.toplevel_capture.sessions.get_mut(sess_oid) {
                        s.transform = OutputTransform::from_wl(t);
                    }
                }
            }
            ext_image_copy_capture_frame_v1::Event::Ready => {
                if let Some(sess_oid) = state.toplevel_capture.session_by_frame.remove(&frame_oid) {
                    if let Some(s) = state.toplevel_capture.sessions.remove(&sess_oid) {
                        if let (Some(fmt), Some(shm)) = (s.format, s.shm_buf.as_ref()) {
                            let stride = s.width * 4;
                            let bytes = &shm.mmap[..shm.byte_len.min(shm.mmap.len())];
                            let (nw, nh, straight) = normalize_screencopy_buffer(
                                bytes,
                                s.width,
                                s.height,
                                stride,
                                fmt,
                                false,
                                s.transform,
                            );
                            let (pw, ph, premul) =
                                downscale_straight_rgba_to_premul(&straight, nw, nh, s.max_width);
                            if pw > 0 && ph > 0 {
                                state.pending_events.push(SystemEvent::WindowPreviewReady {
                                    request_id: s.request_id,
                                    address: s.address.clone(),
                                    width: pw,
                                    height: ph,
                                    rgba_premul: premul,
                                });
                            }
                        }
                        // Dropping `s` immediately destroys frame, session, source, wl_buffer, wl_shm_pool, memfd.
                    }
                }
            }
            ext_image_copy_capture_frame_v1::Event::Failed { .. } => {
                if let Some(sess_oid) = state.toplevel_capture.session_by_frame.remove(&frame_oid) {
                    state.toplevel_capture.sessions.remove(&sess_oid);
                }
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn downscale_premultiplies_and_preserves_aspect_ratio() {
        let mut src = Vec::with_capacity(400 * 200 * 4);
        for _ in 0..(400 * 200) {
            src.extend_from_slice(&[200, 100, 50, 128]);
        }
        let (w, h, out) = downscale_straight_rgba_to_premul(&src, 400, 200, 200);
        assert_eq!((w, h), (200, 100));
        assert_eq!(out.len(), 200 * 100 * 4);
        assert!(out[0] < 200 && out[3] == 128);
    }
}
