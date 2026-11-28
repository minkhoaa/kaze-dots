use crate::UiState;
use smithay_client_toolkit::reexports::client::backend::ObjectId;
use smithay_client_toolkit::reexports::client::globals::GlobalList;
use smithay_client_toolkit::reexports::client::protocol::wl_seat::WlSeat;
use smithay_client_toolkit::reexports::client::{
    event_created_child, Connection, Dispatch, Proxy, QueueHandle,
};
use std::collections::HashMap;
use std::os::fd::{BorrowedFd, FromRawFd, OwnedFd};
use std::sync::Arc;
use wayland_protocols::ext::data_control::v1::client::{
    ext_data_control_device_v1::{self, ExtDataControlDeviceV1},
    ext_data_control_manager_v1::ExtDataControlManagerV1,
    ext_data_control_offer_v1::{self, ExtDataControlOfferV1},
    ext_data_control_source_v1::{self, ExtDataControlSourceV1},
};
use wayland_protocols_wlr::data_control::v1::client::{
    zwlr_data_control_device_v1::{self, ZwlrDataControlDeviceV1},
    zwlr_data_control_manager_v1::ZwlrDataControlManagerV1,
    zwlr_data_control_offer_v1::{self, ZwlrDataControlOfferV1},
    zwlr_data_control_source_v1::{self, ZwlrDataControlSourceV1},
};

pub struct ClipboardPipeRead {
    pub mime: String,
    pub fd: OwnedFd,
    pub max_bytes: usize,
    pub source_is_self: bool,
    pub paste_surface_id: Option<String>,
}

pub struct ClipboardPipeWrite {
    pub fd: OwnedFd,
    pub bytes: Arc<[u8]>,
}

enum ActiveOffer {
    Ext(ExtDataControlOfferV1, Vec<String>),
    Wlr(ZwlrDataControlOfferV1, Vec<String>),
}

impl ActiveOffer {
    fn mimes(&self) -> &[String] {
        match self {
            Self::Ext(_, m) | Self::Wlr(_, m) => m,
        }
    }

    fn receive(&self, mime: String, fd: BorrowedFd<'_>) {
        match self {
            Self::Ext(o, _) => o.receive(mime, fd),
            Self::Wlr(o, _) => o.receive(mime, fd),
        }
    }

    fn destroy(self) {
        match self {
            Self::Ext(o, _) => o.destroy(),
            Self::Wlr(o, _) => o.destroy(),
        }
    }
}

pub struct DataControlState {
    ext_mgr: Option<ExtDataControlManagerV1>,
    wlr_mgr: Option<ZwlrDataControlManagerV1>,
    ext_device: Option<ExtDataControlDeviceV1>,
    wlr_device: Option<ZwlrDataControlDeviceV1>,
    pending_offer_mimes: HashMap<ObjectId, Vec<String>>,
    current_offer: Option<ActiveOffer>,
    ext_source: Option<ExtDataControlSourceV1>,
    wlr_source: Option<ZwlrDataControlSourceV1>,
    active_source_payload: Option<(Vec<String>, Arc<[u8]>)>,
    last_non_secret: Option<(String, Vec<u8>)>,
    last_selection_was_secret: bool,
    self_owned_pending: bool,
    pub ignore_mimes: Vec<String>,
    pub max_item_bytes: usize,
    pub persist: bool,
    pub pending_reads: Vec<ClipboardPipeRead>,
    pub pending_writes: Vec<ClipboardPipeWrite>,
}

impl Default for DataControlState {
    fn default() -> Self {
        Self {
            ext_mgr: None,
            wlr_mgr: None,
            ext_device: None,
            wlr_device: None,
            pending_offer_mimes: HashMap::new(),
            current_offer: None,
            ext_source: None,
            wlr_source: None,
            active_source_payload: None,
            last_non_secret: None,
            last_selection_was_secret: false,
            self_owned_pending: false,
            ignore_mimes: vec![
                "x-kde-passwordManagerHint".into(),
                "application/x-keepassxc-secret".into(),
            ],
            max_item_bytes: 10 * 1024 * 1024,
            persist: true,
            pending_reads: Vec::new(),
            pending_writes: Vec::new(),
        }
    }
}

impl DataControlState {
    pub fn bind_globals(globals: &GlobalList, qh: &QueueHandle<UiState>) -> Self {
        let mut st = Self::default();
        if let Ok(mgr) = globals.bind::<ExtDataControlManagerV1, _, _>(qh, 1..=1, ()) {
            st.ext_mgr = Some(mgr);
        } else if let Ok(mgr) = globals.bind::<ZwlrDataControlManagerV1, _, _>(qh, 1..=2, ()) {
            st.wlr_mgr = Some(mgr);
        }
        st
    }

    pub fn has_protocol(&self) -> bool {
        self.ext_mgr.is_some() || self.wlr_mgr.is_some()
    }

    pub fn ensure_device(&mut self, seat: &WlSeat, qh: &QueueHandle<UiState>) {
        if let Some(ref mgr) = self.ext_mgr {
            if self.ext_device.is_none() {
                self.ext_device = Some(mgr.get_data_device(seat, qh, ()));
            }
        } else if let Some(ref mgr) = self.wlr_mgr {
            if self.wlr_device.is_none() {
                self.wlr_device = Some(mgr.get_data_device(seat, qh, ()));
            }
        }
    }

    pub fn configure(&mut self, ignore_mimes: Vec<String>, max_item_bytes: usize, persist: bool) {
        self.ignore_mimes = ignore_mimes;
        self.max_item_bytes = max_item_bytes.max(1024);
        self.persist = persist;
    }

    pub fn note_captured(&mut self, mime: &str, bytes: &[u8]) {
        self.last_selection_was_secret = false;
        self.last_non_secret = Some((mime.to_string(), bytes.to_vec()));
    }

    pub fn set_selection(&mut self, mime: String, bytes: Vec<u8>, qh: &QueueHandle<UiState>) -> bool {
        self.self_owned_pending = true;
        self.last_selection_was_secret = false;
        self.last_non_secret = Some((mime.clone(), bytes.clone()));

        let mut advertised = vec![mime.clone()];
        if mime.starts_with("text/plain") {
            for alias in ["text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "STRING"] {
                if !advertised.iter().any(|m| m == alias) {
                    advertised.push(alias.to_string());
                }
            }
        }
        let payload: Arc<[u8]> = Arc::from(bytes);

        if let (Some(ref mgr), Some(ref dev)) = (&self.ext_mgr, &self.ext_device) {
            if let Some(old) = self.ext_source.take() {
                old.destroy();
            }
            let src = mgr.create_data_source(qh, ());
            for m in &advertised {
                src.offer(m.clone());
            }
            dev.set_selection(Some(&src));
            self.ext_source = Some(src);
            self.active_source_payload = Some((advertised, payload));
            return true;
        }
        if let (Some(ref mgr), Some(ref dev)) = (&self.wlr_mgr, &self.wlr_device) {
            if let Some(old) = self.wlr_source.take() {
                old.destroy();
            }
            let src = mgr.create_data_source(qh, ());
            for m in &advertised {
                src.offer(m.clone());
            }
            dev.set_selection(Some(&src));
            self.wlr_source = Some(src);
            self.active_source_payload = Some((advertised, payload));
            return true;
        }
        false
    }

    pub fn request_paste_text(&mut self, surface_id: String) -> bool {
        if let Some((mime, bytes)) = &self.last_non_secret {
            if mime.starts_with("text/") || mime == "UTF8_STRING" {
                if let Some((read_fd, write_fd)) = create_nonblocking_pipe() {
                    let mut wfile = std::fs::File::from(write_fd);
                    let _ = std::io::Write::write_all(&mut wfile, bytes);
                    drop(wfile);
                    self.pending_reads.push(ClipboardPipeRead {
                        mime: mime.clone(),
                        fd: read_fd,
                        max_bytes: 1024 * 1024,
                        source_is_self: true,
                        paste_surface_id: Some(surface_id),
                    });
                    return true;
                }
            }
        }
        let Some(ref offer) = self.current_offer else {
            return false;
        };
        let Some(text_mime) = pick_text_mime(offer.mimes()) else {
            return false;
        };
        if let Some((read_fd, write_fd)) = create_nonblocking_pipe() {
            offer.receive(text_mime.clone(), unsafe {
                BorrowedFd::borrow_raw(std::os::fd::AsRawFd::as_raw_fd(&write_fd))
            });
            drop(write_fd);
            self.pending_reads.push(ClipboardPipeRead {
                mime: text_mime,
                fd: read_fd,
                max_bytes: 1024 * 1024,
                source_is_self: true,
                paste_surface_id: Some(surface_id),
            });
            return true;
        }
        false
    }

    fn handle_selection_offer(&mut self, offer_id: ObjectId, active: ActiveOffer) {
        if let Some(old) = self.current_offer.take() {
            old.destroy();
        }
        let mimes = self.pending_offer_mimes.remove(&offer_id).unwrap_or_default();
        let active = match active {
            ActiveOffer::Ext(o, _) => ActiveOffer::Ext(o, mimes.clone()),
            ActiveOffer::Wlr(o, _) => ActiveOffer::Wlr(o, mimes.clone()),
        };

        let is_secret = mimes.iter().any(|m| {
            let ml = m.trim().to_ascii_lowercase();
            self.ignore_mimes
                .iter()
                .any(|ig| ig.trim().to_ascii_lowercase() == ml)
        });
        if is_secret {
            self.last_selection_was_secret = true;
            self.self_owned_pending = false;
            // Secret MIME detected BEFORE `receive()`: read 0 bytes, retain offer handle only
            // for direct on-demand paste while it stays alive.
            self.current_offer = Some(active);
            return;
        }

        self.last_selection_was_secret = false;
        let source_is_self = std::mem::take(&mut self.self_owned_pending);
        if let Some(best_mime) = pick_capture_mime(&mimes) {
            if let Some((read_fd, write_fd)) = create_nonblocking_pipe() {
                active.receive(best_mime.clone(), unsafe {
                    BorrowedFd::borrow_raw(std::os::fd::AsRawFd::as_raw_fd(&write_fd))
                });
                drop(write_fd);
                self.pending_reads.push(ClipboardPipeRead {
                    mime: best_mime,
                    fd: read_fd,
                    max_bytes: self.max_item_bytes,
                    source_is_self,
                    paste_surface_id: None,
                });
            }
        }
        self.current_offer = Some(active);
    }

    fn handle_selection_cleared(&mut self, qh: &QueueHandle<UiState>) {
        if let Some(old) = self.current_offer.take() {
            old.destroy();
        }
        if self.persist && !self.last_selection_was_secret {
            if let Some((mime, bytes)) = self.last_non_secret.clone() {
                self.set_selection(mime, bytes, qh);
            }
        }
    }
}

fn create_nonblocking_pipe() -> Option<(OwnedFd, OwnedFd)> {
    let mut fds = [-1i32; 2];
    // SAFETY: valid 2-int array passed to `pipe2`.
    let rc = unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC | libc::O_NONBLOCK) };
    if rc != 0 {
        return None;
    }
    // SAFETY: both descriptors are freshly created owned pipe endpoints.
    unsafe { Some((OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1]))) }
}

fn pick_capture_mime(mimes: &[String]) -> Option<String> {
    for preferred in [
        "image/png",
        "image/jpeg",
        "image/webp",
        "text/plain;charset=utf-8",
        "UTF8_STRING",
        "text/plain",
        "STRING",
    ] {
        if let Some(found) = mimes.iter().find(|m| m.eq_ignore_ascii_case(preferred)) {
            return Some(found.clone());
        }
    }
    mimes
        .iter()
        .find(|m| m.starts_with("text/") || m.starts_with("image/"))
        .cloned()
}

fn pick_text_mime(mimes: &[String]) -> Option<String> {
    for preferred in ["text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "STRING"] {
        if let Some(found) = mimes.iter().find(|m| m.eq_ignore_ascii_case(preferred)) {
            return Some(found.clone());
        }
    }
    mimes.iter().find(|m| m.starts_with("text/")).cloned()
}

// --- ext-data-control-v1 Dispatch ---

impl Dispatch<ExtDataControlManagerV1, ()> for UiState {
    fn event(
        _state: &mut Self,
        _proxy: &ExtDataControlManagerV1,
        _event: <ExtDataControlManagerV1 as Proxy>::Event,
        _data: &(),
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<ExtDataControlDeviceV1, ()> for UiState {
    fn event(
        state: &mut Self,
        _proxy: &ExtDataControlDeviceV1,
        event: ext_data_control_device_v1::Event,
        _data: &(),
        conn: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        match event {
            ext_data_control_device_v1::Event::DataOffer { id } => {
                state.data_control.pending_offer_mimes.insert(id.id(), Vec::new());
            }
            ext_data_control_device_v1::Event::Selection { id: Some(offer) } => {
                let oid = offer.id();
                state
                    .data_control
                    .handle_selection_offer(oid, ActiveOffer::Ext(offer, Vec::new()));
                let _ = conn.flush();
            }
            ext_data_control_device_v1::Event::Selection { id: None } => {
                state.data_control.handle_selection_cleared(qh);
                let _ = conn.flush();
            }
            ext_data_control_device_v1::Event::Finished => {
                state.data_control.ext_device = None;
            }
            _ => {}
        }
    }

    event_created_child!(UiState, ExtDataControlDeviceV1, [
        ext_data_control_device_v1::EVT_DATA_OFFER_OPCODE => (ExtDataControlOfferV1, ())
    ]);
}

impl Dispatch<ExtDataControlOfferV1, ()> for UiState {
    fn event(
        state: &mut Self,
        proxy: &ExtDataControlOfferV1,
        event: ext_data_control_offer_v1::Event,
        _data: &(),
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
        if let ext_data_control_offer_v1::Event::Offer { mime_type } = event {
            state
                .data_control
                .pending_offer_mimes
                .entry(proxy.id())
                .or_default()
                .push(mime_type);
        }
    }
}

impl Dispatch<ExtDataControlSourceV1, ()> for UiState {
    fn event(
        state: &mut Self,
        proxy: &ExtDataControlSourceV1,
        event: ext_data_control_source_v1::Event,
        _data: &(),
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
        match event {
            ext_data_control_source_v1::Event::Send { mime_type, fd } => {
                if let Some((mimes, bytes)) = &state.data_control.active_source_payload {
                    if mimes.iter().any(|m| m == &mime_type) || !mimes.is_empty() {
                        state.data_control.pending_writes.push(ClipboardPipeWrite {
                            fd,
                            bytes: Arc::clone(bytes),
                        });
                    }
                }
            }
            ext_data_control_source_v1::Event::Cancelled => {
                if state
                    .data_control
                    .ext_source
                    .as_ref()
                    .is_some_and(|s| s.id() == proxy.id())
                {
                    state.data_control.ext_source = None;
                    state.data_control.active_source_payload = None;
                }
                proxy.destroy();
            }
            _ => {}
        }
    }
}

// --- zwlr_data_control_v1 Fallback Dispatch ---

impl Dispatch<ZwlrDataControlManagerV1, ()> for UiState {
    fn event(
        _state: &mut Self,
        _proxy: &ZwlrDataControlManagerV1,
        _event: <ZwlrDataControlManagerV1 as Proxy>::Event,
        _data: &(),
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<ZwlrDataControlDeviceV1, ()> for UiState {
    fn event(
        state: &mut Self,
        _proxy: &ZwlrDataControlDeviceV1,
        event: zwlr_data_control_device_v1::Event,
        _data: &(),
        conn: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        match event {
            zwlr_data_control_device_v1::Event::DataOffer { id } => {
                state.data_control.pending_offer_mimes.insert(id.id(), Vec::new());
            }
            zwlr_data_control_device_v1::Event::Selection { id: Some(offer) } => {
                let oid = offer.id();
                state
                    .data_control
                    .handle_selection_offer(oid, ActiveOffer::Wlr(offer, Vec::new()));
                let _ = conn.flush();
            }
            zwlr_data_control_device_v1::Event::Selection { id: None } => {
                state.data_control.handle_selection_cleared(qh);
                let _ = conn.flush();
            }
            zwlr_data_control_device_v1::Event::Finished => {
                state.data_control.wlr_device = None;
            }
            _ => {}
        }
    }

    event_created_child!(UiState, ZwlrDataControlDeviceV1, [
        zwlr_data_control_device_v1::EVT_DATA_OFFER_OPCODE => (ZwlrDataControlOfferV1, ())
    ]);
}

impl Dispatch<ZwlrDataControlOfferV1, ()> for UiState {
    fn event(
        state: &mut Self,
        proxy: &ZwlrDataControlOfferV1,
        event: zwlr_data_control_offer_v1::Event,
        _data: &(),
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
        if let zwlr_data_control_offer_v1::Event::Offer { mime_type } = event {
            state
                .data_control
                .pending_offer_mimes
                .entry(proxy.id())
                .or_default()
                .push(mime_type);
        }
    }
}

impl Dispatch<ZwlrDataControlSourceV1, ()> for UiState {
    fn event(
        state: &mut Self,
        proxy: &ZwlrDataControlSourceV1,
        event: zwlr_data_control_source_v1::Event,
        _data: &(),
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
        match event {
            zwlr_data_control_source_v1::Event::Send { mime_type, fd } => {
                if let Some((mimes, bytes)) = &state.data_control.active_source_payload {
                    if mimes.iter().any(|m| m == &mime_type) || !mimes.is_empty() {
                        state.data_control.pending_writes.push(ClipboardPipeWrite {
                            fd,
                            bytes: Arc::clone(bytes),
                        });
                    }
                }
            }
            zwlr_data_control_source_v1::Event::Cancelled => {
                if state
                    .data_control
                    .wlr_source
                    .as_ref()
                    .is_some_and(|s| s.id() == proxy.id())
                {
                    state.data_control.wlr_source = None;
                    state.data_control.active_source_payload = None;
                }
                proxy.destroy();
            }
            _ => {}
        }
    }
}
