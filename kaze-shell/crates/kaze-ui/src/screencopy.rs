#![deny(clippy::unwrap_used)]

use crate::UiState;
use kaze_core::{CapturedOutputFrame, SystemEvent};
use memmap2::MmapMut;
use smithay_client_toolkit::reexports::client::backend::ObjectId;
use smithay_client_toolkit::reexports::client::globals::GlobalList;
use smithay_client_toolkit::reexports::client::protocol::{
    wl_buffer,
    wl_output::{Transform as WlTransform, WlOutput},
    wl_shm, wl_shm_pool,
};
use smithay_client_toolkit::reexports::client::{Connection, Dispatch, Proxy, QueueHandle, WEnum};
use smithay_client_toolkit::shm::Shm;
use std::collections::HashMap;
use std::fs::File;
use std::os::fd::{AsFd, FromRawFd, OwnedFd};
use std::sync::Arc;
use wayland_protocols_wlr::screencopy::v1::client::{
    zwlr_screencopy_frame_v1::{self, Flags as FrameFlags, ZwlrScreencopyFrameV1},
    zwlr_screencopy_manager_v1::ZwlrScreencopyManagerV1,
};

pub struct ScreencopyShmMarker;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CapturePixelFormat {
    Argb8888,
    Xrgb8888,
    Abgr8888,
    Xbgr8888,
}

impl CapturePixelFormat {
    pub fn from_wl_shm(fmt: WEnum<wl_shm::Format>) -> Option<Self> {
        match fmt {
            WEnum::Value(wl_shm::Format::Argb8888) => Some(Self::Argb8888),
            WEnum::Value(wl_shm::Format::Xrgb8888) => Some(Self::Xrgb8888),
            WEnum::Value(wl_shm::Format::Abgr8888) => Some(Self::Abgr8888),
            WEnum::Value(wl_shm::Format::Xbgr8888) => Some(Self::Xbgr8888),
            _ => None,
        }
    }

    pub fn to_wl_shm(self) -> wl_shm::Format {
        match self {
            Self::Argb8888 => wl_shm::Format::Argb8888,
            Self::Xrgb8888 => wl_shm::Format::Xrgb8888,
            Self::Abgr8888 => wl_shm::Format::Abgr8888,
            Self::Xbgr8888 => wl_shm::Format::Xbgr8888,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OutputTransform {
    Normal,
    Rot90,
    Rot180,
    Rot270,
    Flipped,
    Flipped90,
    Flipped180,
    Flipped270,
}

impl OutputTransform {
    pub fn from_wl(t: WlTransform) -> Self {
        match t {
            WlTransform::_90 => Self::Rot90,
            WlTransform::_180 => Self::Rot180,
            WlTransform::_270 => Self::Rot270,
            WlTransform::Flipped => Self::Flipped,
            WlTransform::Flipped90 => Self::Flipped90,
            WlTransform::Flipped180 => Self::Flipped180,
            WlTransform::Flipped270 => Self::Flipped270,
            _ => Self::Normal,
        }
    }
}

pub fn should_capture_output(name: &str) -> bool {
    !name.trim().is_empty() && name != "kaze-share"
}

/// Normalizes a raw SHM screencopy buffer (`Argb8888`/`Xrgb8888`/`Abgr8888`/`Xbgr8888`)
/// accounting for `stride`, `YInvert`, and all 8 `wl_output::Transform` variants into
/// upright straight `RGBA8888` pixels `(out_w, out_h, Vec<u8>)`.
pub fn normalize_screencopy_buffer(
    src: &[u8],
    width: u32,
    height: u32,
    stride: u32,
    format: CapturePixelFormat,
    y_invert: bool,
    transform: OutputTransform,
) -> (u32, u32, Vec<u8>) {
    let w = width as usize;
    let h = height as usize;
    let st = (stride as usize).max(w * 4);
    if w == 0 || h == 0 || src.len() < (h - 1) * st + w * 4 {
        return (0, 0, Vec::new());
    }

    let mut upright = vec![0u8; w * h * 4];
    for sy in 0..h {
        let src_y = if y_invert { h - 1 - sy } else { sy };
        let row_off = src_y * st;
        let dst_off = sy * w * 4;
        for sx in 0..w {
            let s = row_off + sx * 4;
            let d = dst_off + sx * 4;
            let (r, g, b, a) = match format {
                CapturePixelFormat::Argb8888 => (src[s + 2], src[s + 1], src[s], src[s + 3]),
                CapturePixelFormat::Xrgb8888 => (src[s + 2], src[s + 1], src[s], 255),
                CapturePixelFormat::Abgr8888 => (src[s], src[s + 1], src[s + 2], src[s + 3]),
                CapturePixelFormat::Xbgr8888 => (src[s], src[s + 1], src[s + 2], 255),
            };
            upright[d] = r;
            upright[d + 1] = g;
            upright[d + 2] = b;
            upright[d + 3] = a;
        }
    }

    apply_transform(&upright, w, h, transform)
}

fn apply_transform(
    src: &[u8],
    bw: usize,
    bh: usize,
    transform: OutputTransform,
) -> (u32, u32, Vec<u8>) {
    let (out_w, out_h) = match transform {
        OutputTransform::Normal
        | OutputTransform::Rot180
        | OutputTransform::Flipped
        | OutputTransform::Flipped180 => (bw, bh),
        OutputTransform::Rot90
        | OutputTransform::Rot270
        | OutputTransform::Flipped90
        | OutputTransform::Flipped270 => (bh, bw),
    };
    if transform == OutputTransform::Normal {
        return (out_w as u32, out_h as u32, src.to_vec());
    }
    let mut dst = vec![0u8; out_w * out_h * 4];
    for dy in 0..out_h {
        for dx in 0..out_w {
            let (sx, sy) = match transform {
                OutputTransform::Normal => (dx, dy),
                OutputTransform::Rot90 => (bw - 1 - dy, dx),
                OutputTransform::Rot180 => (bw - 1 - dx, bh - 1 - dy),
                OutputTransform::Rot270 => (dy, bh - 1 - dx),
                OutputTransform::Flipped => (bw - 1 - dx, dy),
                OutputTransform::Flipped90 => (dy, dx),
                OutputTransform::Flipped180 => (dx, bh - 1 - dy),
                OutputTransform::Flipped270 => (bw - 1 - dy, bh - 1 - dx),
            };
            let s = (sy * bw + sx) * 4;
            let d = (dy * out_w + dx) * 4;
            dst[d..d + 4].copy_from_slice(&src[s..s + 4]);
        }
    }
    (out_w as u32, out_h as u32, dst)
}

/// Samples a straight RGBA pixel at global compositor logical coordinates across
/// multi-monitor frames (supporting negative coordinates and fractional scales `1.0..=2.0`).
pub fn sample_pixel_at_logical(
    frames: &[CapturedOutputFrame],
    logical_x: f32,
    logical_y: f32,
) -> Option<[u8; 4]> {
    for f in frames {
        let fx0 = f.logical_x as f32;
        let fy0 = f.logical_y as f32;
        let fx1 = fx0 + f.logical_w as f32;
        let fy1 = fy0 + f.logical_h as f32;
        if logical_x >= fx0 && logical_x < fx1 && logical_y >= fy0 && logical_y < fy1 {
            if f.logical_w == 0 || f.logical_h == 0 || f.pixel_w == 0 || f.pixel_h == 0 {
                continue;
            }
            let norm_x = ((logical_x - fx0) / f.logical_w as f32).clamp(0.0, 0.999_999);
            let norm_y = ((logical_y - fy0) / f.logical_h as f32).clamp(0.0, 0.999_999);
            let px = ((norm_x * f.pixel_w as f32).floor() as u32).min(f.pixel_w - 1);
            let py = ((norm_y * f.pixel_h as f32).floor() as u32).min(f.pixel_h - 1);
            let idx = ((py * f.pixel_w + px) as usize) * 4;
            if idx + 3 < f.rgba.len() {
                return Some([
                    f.rgba[idx],
                    f.rgba[idx + 1],
                    f.rgba[idx + 2],
                    f.rgba[idx + 3],
                ]);
            }
        }
    }
    None
}

#[derive(Clone)]
pub struct ScreencopyFrameTag {
    pub request_id: u64,
    pub output_name: String,
    pub logical_x: i32,
    pub logical_y: i32,
    pub logical_w: u32,
    pub logical_h: u32,
    pub transform: OutputTransform,
}

struct TransientShmBuffer {
    _file: File,
    mmap: MmapMut,
    wl_buf: wl_buffer::WlBuffer,
    wl_pool: wl_shm_pool::WlShmPool,
    byte_len: usize,
}

impl Drop for TransientShmBuffer {
    fn drop(&mut self) {
        self.wl_buf.destroy();
        self.wl_pool.destroy();
    }
}

fn create_transient_shm_buffer(
    shm: &Shm,
    qh: &QueueHandle<UiState>,
    width: u32,
    height: u32,
    stride: u32,
    fmt: CapturePixelFormat,
) -> Option<TransientShmBuffer> {
    let total = (stride as usize).checked_mul(height as usize)?;
    if total == 0 {
        return None;
    }
    // SAFETY: `memfd_create` creates a private anonymous CLOEXEC fd; return value checked `>= 0`.
    let raw_fd = unsafe {
        libc::memfd_create(
            c"kaze-screencopy".as_ptr(),
            libc::MFD_CLOEXEC | libc::MFD_ALLOW_SEALING,
        )
    };
    if raw_fd < 0 {
        return None;
    }
    // SAFETY: `raw_fd` is newly created and owned.
    let file = unsafe { File::from(OwnedFd::from_raw_fd(raw_fd)) };
    if file.set_len(total as u64).is_err() {
        return None;
    }
    // SAFETY: `file` is private and sized cleanly to `total`.
    let mmap = unsafe { MmapMut::map_mut(&file).ok()? };
    let wl_pool = shm
        .wl_shm()
        .create_pool(file.as_fd(), total as i32, qh, ScreencopyShmMarker);
    let wl_buf = wl_pool.create_buffer(
        0,
        width as i32,
        height as i32,
        stride as i32,
        fmt.to_wl_shm(),
        qh,
        ScreencopyShmMarker,
    );
    Some(TransientShmBuffer {
        _file: file,
        mmap,
        wl_buf,
        wl_pool,
        byte_len: total,
    })
}

struct ActiveFrame {
    frame: ZwlrScreencopyFrameV1,
    tag: ScreencopyFrameTag,
    format: Option<CapturePixelFormat>,
    width: u32,
    height: u32,
    stride: u32,
    y_invert: bool,
    copy_sent: bool,
    shm_buf: Option<TransientShmBuffer>,
}

impl Drop for ActiveFrame {
    fn drop(&mut self) {
        self.shm_buf.take();
        self.frame.destroy();
    }
}

struct PendingBatch {
    expected: usize,
    frames: Vec<CapturedOutputFrame>,
    error: Option<String>,
}

#[derive(Default)]
pub struct ScreencopyState {
    manager: Option<ZwlrScreencopyManagerV1>,
    batches: HashMap<u64, PendingBatch>,
    in_flight: HashMap<ObjectId, ActiveFrame>,
}

impl ScreencopyState {
    pub fn bind_globals(globals: &GlobalList, qh: &QueueHandle<UiState>) -> Self {
        Self {
            manager: globals
                .bind::<ZwlrScreencopyManagerV1, _, _>(qh, 1..=3, ())
                .ok(),
            batches: HashMap::new(),
            in_flight: HashMap::new(),
        }
    }

    pub fn has_screencopy(&self) -> bool {
        self.manager.is_some()
    }

    pub fn capture_outputs<'a>(
        &mut self,
        request_id: u64,
        targets: impl Iterator<Item = (ScreencopyFrameTag, &'a WlOutput)>,
        qh: &QueueHandle<UiState>,
    ) -> Result<(), String> {
        let Some(ref mgr) = self.manager else {
            return Err("zwlr_screencopy_manager_v1 unavailable".to_string());
        };
        let list: Vec<(ScreencopyFrameTag, &WlOutput)> = targets
            .filter(|(t, _)| should_capture_output(&t.output_name))
            .collect();
        if list.is_empty() {
            return Err("no physical outputs available to capture".to_string());
        }
        self.batches.insert(
            request_id,
            PendingBatch {
                expected: list.len(),
                frames: Vec::with_capacity(list.len()),
                error: None,
            },
        );
        for (tag, wl_out) in list {
            let frame = mgr.capture_output(0, wl_out, qh, tag.request_id);
            let oid = frame.id();
            self.in_flight.insert(
                oid,
                ActiveFrame {
                    frame,
                    tag,
                    format: None,
                    width: 0,
                    height: 0,
                    stride: 0,
                    y_invert: false,
                    copy_sent: false,
                    shm_buf: None,
                },
            );
        }
        Ok(())
    }

    fn finish_frame(
        &mut self,
        oid: &ObjectId,
        ok: bool,
        err_msg: Option<&str>,
        pending_events: &mut Vec<SystemEvent>,
    ) {
        let Some(active) = self.in_flight.remove(oid) else {
            return;
        };
        let req_id = active.tag.request_id;
        let mut out_frame: Option<CapturedOutputFrame> = None;

        if ok {
            if let (Some(fmt), Some(shm_buf)) = (active.format, active.shm_buf.as_ref()) {
                let raw = &shm_buf.mmap[..shm_buf.byte_len];
                let (pw, ph, rgba) = normalize_screencopy_buffer(
                    raw,
                    active.width,
                    active.height,
                    active.stride,
                    fmt,
                    active.y_invert,
                    active.tag.transform,
                );
                if pw > 0 && ph > 0 && !rgba.is_empty() {
                    out_frame = Some(CapturedOutputFrame {
                        output_name: active.tag.output_name.clone(),
                        logical_x: active.tag.logical_x,
                        logical_y: active.tag.logical_y,
                        logical_w: active.tag.logical_w,
                        logical_h: active.tag.logical_h,
                        pixel_w: pw,
                        pixel_h: ph,
                        rgba: Arc::<[u8]>::from(rgba),
                    });
                }
            }
        }
        drop(active);

        let Some(batch) = self.batches.get_mut(&req_id) else {
            return;
        };
        if let Some(frame) = out_frame {
            batch.frames.push(frame);
        } else if batch.error.is_none() {
            batch.error = Some(err_msg.unwrap_or("screencopy capture failed").to_string());
        }

        if batch.frames.len() >= batch.expected
            || (batch.error.is_some()
                && !self.in_flight.values().any(|a| a.tag.request_id == req_id))
        {
            if let Some(completed) = self.batches.remove(&req_id) {
                if completed.frames.is_empty() {
                    pending_events.push(SystemEvent::ScreencopyFailed {
                        request_id: req_id,
                        error: completed
                            .error
                            .unwrap_or_else(|| "screencopy produced 0 frames".to_string()),
                    });
                } else {
                    pending_events.push(SystemEvent::ScreencopyReady {
                        request_id: req_id,
                        frames: completed.frames,
                        windows: Vec::new(),
                    });
                }
            }
        }
    }
}

fn try_send_copy(
    active: &mut ActiveFrame,
    shm: &Shm,
    qh: &QueueHandle<UiState>,
) -> Result<(), String> {
    if active.copy_sent {
        return Ok(());
    }
    let Some(fmt) = active.format else {
        return Err("unsupported screencopy pixel format".to_string());
    };
    let Some(shm_buf) =
        create_transient_shm_buffer(shm, qh, active.width, active.height, active.stride, fmt)
    else {
        return Err("failed allocating screencopy memfd".to_string());
    };
    active.frame.copy(&shm_buf.wl_buf);
    active.shm_buf = Some(shm_buf);
    active.copy_sent = true;
    Ok(())
}

impl Dispatch<ZwlrScreencopyManagerV1, ()> for UiState {
    fn event(
        _state: &mut Self,
        _proxy: &ZwlrScreencopyManagerV1,
        _event: <ZwlrScreencopyManagerV1 as Proxy>::Event,
        _data: &(),
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<wl_shm_pool::WlShmPool, ScreencopyShmMarker> for UiState {
    fn event(
        _state: &mut Self,
        _proxy: &wl_shm_pool::WlShmPool,
        _event: wl_shm_pool::Event,
        _data: &ScreencopyShmMarker,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<wl_buffer::WlBuffer, ScreencopyShmMarker> for UiState {
    fn event(
        _state: &mut Self,
        _proxy: &wl_buffer::WlBuffer,
        _event: wl_buffer::Event,
        _data: &ScreencopyShmMarker,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<ZwlrScreencopyFrameV1, u64> for UiState {
    fn event(
        state: &mut Self,
        proxy: &ZwlrScreencopyFrameV1,
        event: zwlr_screencopy_frame_v1::Event,
        _req_id: &u64,
        conn: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        let oid = proxy.id();
        match event {
            zwlr_screencopy_frame_v1::Event::Buffer {
                format,
                width,
                height,
                stride,
            } => {
                let Some(parsed) = CapturePixelFormat::from_wl_shm(format) else {
                    return;
                };
                if let Some(active) = state.screencopy.in_flight.get_mut(&oid) {
                    if active.format.is_none() {
                        active.format = Some(parsed);
                        active.width = width;
                        active.height = height;
                        active.stride = stride;
                    }
                    if proxy.version() < 3 {
                        if let Err(err) = try_send_copy(active, &state.shm, qh) {
                            state.screencopy.finish_frame(
                                &oid,
                                false,
                                Some(&err),
                                &mut state.pending_events,
                            );
                        } else {
                            let _ = conn.flush();
                        }
                    }
                }
            }
            zwlr_screencopy_frame_v1::Event::BufferDone => {
                if let Some(active) = state.screencopy.in_flight.get_mut(&oid) {
                    if let Err(err) = try_send_copy(active, &state.shm, qh) {
                        state.screencopy.finish_frame(
                            &oid,
                            false,
                            Some(&err),
                            &mut state.pending_events,
                        );
                    } else {
                        let _ = conn.flush();
                    }
                }
            }
            zwlr_screencopy_frame_v1::Event::Flags {
                flags: WEnum::Value(f),
            } => {
                if let Some(active) = state.screencopy.in_flight.get_mut(&oid) {
                    active.y_invert = f.contains(FrameFlags::YInvert);
                }
            }
            zwlr_screencopy_frame_v1::Event::Ready { .. } => {
                state
                    .screencopy
                    .finish_frame(&oid, true, None, &mut state.pending_events);
            }
            zwlr_screencopy_frame_v1::Event::Failed => {
                state.screencopy.finish_frame(
                    &oid,
                    false,
                    Some("compositor rejected screencopy"),
                    &mut state.pending_events,
                );
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn encode_pixel(fmt: CapturePixelFormat, r: u8, g: u8, b: u8, a: u8) -> [u8; 4] {
        match fmt {
            CapturePixelFormat::Argb8888 | CapturePixelFormat::Xrgb8888 => [b, g, r, a],
            CapturePixelFormat::Abgr8888 | CapturePixelFormat::Xbgr8888 => [r, g, b, a],
        }
    }

    #[test]
    fn normalizes_all_formats_for_exact_e61919_and_y_invert() {
        for fmt in [
            CapturePixelFormat::Argb8888,
            CapturePixelFormat::Xrgb8888,
            CapturePixelFormat::Abgr8888,
            CapturePixelFormat::Xbgr8888,
        ] {
            let mut raw = Vec::new();
            // Row 0 = blue, Row 1 = #E61919
            raw.extend_from_slice(&encode_pixel(fmt, 0, 0, 255, 255));
            raw.extend_from_slice(&encode_pixel(fmt, 0, 0, 0, 255));
            raw.extend_from_slice(&encode_pixel(fmt, 230, 25, 25, 255));
            raw.extend_from_slice(&encode_pixel(fmt, 10, 20, 30, 255));

            let (w, h, rgba) =
                normalize_screencopy_buffer(&raw, 2, 2, 8, fmt, true, OutputTransform::Normal);
            assert_eq!((w, h), (2, 2));
            // With YInvert, row 1 becomes top row (y=0, x=0) -> #E61919
            assert_eq!(&rgba[0..4], &[230, 25, 25, 255]);
        }
    }

    #[test]
    fn handles_all_eight_output_transforms_cleanly() {
        // 2x3 image with unique pixels so every cell identifies its exact coordinates.
        let src: Vec<u8> = (0u8..6).flat_map(|i| [i * 30, i, 255 - i, 255]).collect();
        let all = [
            (OutputTransform::Normal, (2, 3), 0),
            (OutputTransform::Rot90, (3, 2), 1),
            (OutputTransform::Rot180, (2, 3), 5),
            (OutputTransform::Rot270, (3, 2), 4),
            (OutputTransform::Flipped, (2, 3), 1),
            (OutputTransform::Flipped90, (3, 2), 0),
            (OutputTransform::Flipped180, (2, 3), 4),
            (OutputTransform::Flipped270, (3, 2), 5),
        ];
        for (tr, expected_dims, expected_tl_id) in all {
            let (ow, oh, out) =
                normalize_screencopy_buffer(&src, 2, 3, 8, CapturePixelFormat::Abgr8888, false, tr);
            assert_eq!((ow, oh), expected_dims, "transform {tr:?}");
            assert_eq!(out[1], expected_tl_id, "top-left pixel mismatch for {tr:?}");
        }
    }

    #[test]
    fn samples_negative_multi_monitor_and_fractional_scales() {
        // Left monitor at x=-1536 (1.25 scale, 1920px -> 1536 logical)
        // Right monitor at x=0 (1.5 scale, 1920px -> 1280 logical)
        let mut left = vec![0u8; 4 * 4 * 4];
        left[0..4].copy_from_slice(&[230, 25, 25, 255]);
        let mut right = vec![0u8; 4 * 4 * 4];
        let br = (3 * 4 + 3) * 4;
        right[br..br + 4].copy_from_slice(&[10, 20, 30, 255]);

        let frames = vec![
            CapturedOutputFrame {
                output_name: "DP-1".into(),
                logical_x: -1536,
                logical_y: 0,
                logical_w: 1536,
                logical_h: 864,
                pixel_w: 4,
                pixel_h: 4,
                rgba: Arc::<[u8]>::from(left),
            },
            CapturedOutputFrame {
                output_name: "DP-2".into(),
                logical_x: 0,
                logical_y: 0,
                logical_w: 1280,
                logical_h: 720,
                pixel_w: 4,
                pixel_h: 4,
                rgba: Arc::<[u8]>::from(right),
            },
        ];

        assert_eq!(
            sample_pixel_at_logical(&frames, -1536.0, 0.0),
            Some([230, 25, 25, 255])
        );
        assert_eq!(
            sample_pixel_at_logical(&frames, 1279.0, 719.0),
            Some([10, 20, 30, 255])
        );
        assert!(!should_capture_output("kaze-share"));
        assert!(should_capture_output("DP-1"));
    }
}
