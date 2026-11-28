#![deny(clippy::unwrap_used)]

pub mod data_control;
pub mod idle_power;
pub mod render;
pub mod screencopy;
pub mod toplevel_capture;

use data_control::{ClipboardPipeRead, ClipboardPipeWrite, DataControlState};
use idle_power::IdlePowerState;
use screencopy::{OutputTransform, ScreencopyFrameTag, ScreencopyState};
use toplevel_capture::ToplevelCaptureState;

use kaze_core::{
    Anchor, DirtyFlags, ImeEvent, KeyEvent as CoreKeyEvent, KeyModifiers, KeyboardMode, Layer,
    OutputInfo, PointerButton, Rect, SurfaceSpec, SystemEvent, SPRING_MAX_DT_SECS,
};
use render::Renderer;
use smithay_client_toolkit::compositor::{CompositorHandler, CompositorState, Region};
use smithay_client_toolkit::output::{OutputHandler, OutputState};
use smithay_client_toolkit::reexports::client::backend::ObjectId;
use smithay_client_toolkit::reexports::client::globals::registry_queue_init;
use smithay_client_toolkit::reexports::client::protocol::{
    wl_keyboard, wl_output, wl_pointer, wl_seat, wl_shm, wl_surface,
};
use smithay_client_toolkit::reexports::client::{
    Connection, Dispatch, EventQueue, Proxy, QueueHandle,
};
use smithay_client_toolkit::registry::{ProvidesRegistryState, RegistryState};
use smithay_client_toolkit::seat::keyboard::{
    KeyEvent as SctkKeyEvent, KeyboardHandler, Keysym, Modifiers, RawModifiers,
};
use smithay_client_toolkit::seat::pointer::{PointerEvent, PointerEventKind, PointerHandler};
use smithay_client_toolkit::seat::{Capability, SeatHandler, SeatState};
use smithay_client_toolkit::shell::wlr_layer::{
    Anchor as LayerAnchor, KeyboardInteractivity, Layer as WlrLayer, LayerShell, LayerShellHandler,
    LayerSurface, LayerSurfaceConfigure,
};
use smithay_client_toolkit::shell::WaylandSurface;
use smithay_client_toolkit::shm::slot::SlotPool;
use smithay_client_toolkit::shm::{Shm, ShmHandler};
use smithay_client_toolkit::{
    delegate_compositor, delegate_keyboard, delegate_layer, delegate_output, delegate_pointer,
    delegate_registry, delegate_seat, delegate_shm, registry_handlers,
};
use std::collections::{HashMap, HashSet};
use std::io::Write;
use std::os::fd::{AsFd, FromRawFd, OwnedFd};
use wayland_protocols::wp::idle_inhibit::zv1::client::zwp_idle_inhibit_manager_v1::ZwpIdleInhibitManagerV1;
use wayland_protocols::wp::idle_inhibit::zv1::client::zwp_idle_inhibitor_v1::ZwpIdleInhibitorV1;
use wayland_protocols::wp::text_input::zv3::client::zwp_text_input_manager_v3::ZwpTextInputManagerV3;
use wayland_protocols::wp::text_input::zv3::client::zwp_text_input_v3::{
    self, ContentHint, ContentPurpose, ZwpTextInputV3,
};
use wayland_protocols_wlr::gamma_control::v1::client::zwlr_gamma_control_manager_v1::ZwlrGammaControlManagerV1;
use wayland_protocols_wlr::gamma_control::v1::client::zwlr_gamma_control_v1::{
    self, ZwlrGammaControlV1,
};

const BTN_LEFT: u32 = 0x110;
const BTN_RIGHT: u32 = 0x111;
const BTN_MIDDLE: u32 = 0x112;
const DEFAULT_REFRESH_MHZ: i32 = 60_000;

/// Per-surface frame clock driven exclusively by Wayland `wl_surface.frame()` callbacks.
/// Computes refresh-rate-accurate `dt` (clamped to `<= 33ms`) and cleans up all entries
/// immediately once animations converge so idle surfaces generate 0 wakeups.
#[derive(Default)]
pub struct AnimationClock {
    last_frame_ms: HashMap<String, u32>,
}

impl AnimationClock {
    pub fn tick(&mut self, surface_id: &str, time_ms: u32, refresh_mhz: i32) -> f32 {
        let fallback_dt = if refresh_mhz > 0 {
            (1000.0 / (refresh_mhz as f32)).clamp(0.004, SPRING_MAX_DT_SECS)
        } else {
            1.0 / 60.0
        };
        match self.last_frame_ms.insert(surface_id.to_string(), time_ms) {
            Some(prev_ms) => {
                let delta_ms = time_ms.wrapping_sub(prev_ms);
                if delta_ms == 0 {
                    fallback_dt
                } else {
                    (delta_ms as f32 / 1000.0).clamp(0.001, SPRING_MAX_DT_SECS)
                }
            }
            None => fallback_dt,
        }
    }

    pub fn stop(&mut self, surface_id: &str) {
        self.last_frame_ms.remove(surface_id);
    }

    pub fn active_count(&self) -> usize {
        self.last_frame_ms.len()
    }
}

struct TrackedOutput {
    wl_output: wl_output::WlOutput,
    info: Option<OutputInfo>,
    refresh_mhz: i32,
}

struct ManagedSurface {
    spec: SurfaceSpec,
    layer: LayerSurface,
    pool: SlotPool,
    configured: bool,
    logical_width: u32,
    logical_height: u32,
    scale: i32,
    dirty: bool,
    frame_in_flight: bool,
}

impl ManagedSurface {
    fn surface_id_obj(&self) -> ObjectId {
        self.layer.wl_surface().id()
    }
}

#[derive(Default)]
struct PendingIme {
    preedit: Option<(String, i32, i32)>,
    commit: Option<String>,
    delete_surrounding: Option<(u32, u32)>,
}

struct WallpaperSurface {
    layer: LayerSurface,
    pool: SlotPool,
    width: u32,
    height: u32,
    configured: bool,
    pending_bgra: Option<Vec<u8>>,
}

struct GammaEntry {
    control: ZwlrGammaControlV1,
    ramp_size: Option<u32>,
}

pub struct UiState {
    registry_state: RegistryState,
    seat_state: SeatState,
    output_state: OutputState,
    compositor_state: CompositorState,
    shm: Shm,
    layer_shell: LayerShell,
    text_input_manager: Option<ZwpTextInputManagerV3>,
    text_input: Option<ZwpTextInputV3>,
    idle_inhibit_manager: Option<ZwpIdleInhibitManagerV1>,
    idle_inhibitor: Option<ZwpIdleInhibitorV1>,
    idle_anchor_surface: Option<LayerSurface>,
    gamma_manager: Option<ZwlrGammaControlManagerV1>,
    gamma_controls: HashMap<String, GammaEntry>,
    nightlight_enabled: bool,
    nightlight_temp_k: u32,
    ime_surface: Option<ObjectId>,
    ime_pending: PendingIme,
    last_ime_cursor_rect: Option<(i32, i32, i32, i32)>,
    qh: QueueHandle<Self>,
    pointer: Option<wl_pointer::WlPointer>,
    pointer_surface: Option<ObjectId>,
    pointer_pos: (f64, f64),
    pointer_drag: Option<(String, String)>,
    keyboard: Option<wl_keyboard::WlKeyboard>,
    keyboard_surface: Option<ObjectId>,
    modifiers: KeyModifiers,
    outputs_by_obj: HashMap<ObjectId, TrackedOutput>,
    output_obj_by_name: HashMap<String, ObjectId>,
    surfaces: HashMap<String, ManagedSurface>,
    surface_key_by_obj: HashMap<ObjectId, String>,
    wallpapers: HashMap<String, WallpaperSurface>,
    wallpaper_output_by_obj: HashMap<ObjectId, String>,
    anim_clock: AnimationClock,
    renderer: Renderer,
    data_control: DataControlState,
    idle_power: IdlePowerState,
    screencopy: ScreencopyState,
    toplevel_capture: ToplevelCaptureState,
    pending_events: Vec<SystemEvent>,
}

impl UiState {
    pub fn connect(font_hint: &str) -> Result<(Connection, EventQueue<Self>, Self), String> {
        let conn = Connection::connect_to_env()
            .map_err(|e| format!("failed to connect to Wayland display: {e}"))?;
        let (globals, event_queue) = registry_queue_init::<Self>(&conn)
            .map_err(|e| format!("failed to initialize Wayland registry: {e}"))?;
        let qh = event_queue.handle();

        let compositor_state = CompositorState::bind(&globals, &qh)
            .map_err(|e| format!("wl_compositor unavailable: {e}"))?;
        let layer_shell = LayerShell::bind(&globals, &qh)
            .map_err(|e| format!("zwlr_layer_shell_v1 unavailable: {e}"))?;
        let shm = Shm::bind(&globals, &qh).map_err(|e| format!("wl_shm unavailable: {e}"))?;
        let text_input_manager = globals
            .bind::<ZwpTextInputManagerV3, _, _>(&qh, 1..=1, ())
            .ok();
        let idle_inhibit_manager = globals
            .bind::<ZwpIdleInhibitManagerV1, _, _>(&qh, 1..=1, ())
            .ok();
        let gamma_manager = globals
            .bind::<ZwlrGammaControlManagerV1, _, _>(&qh, 1..=1, ())
            .ok();
        let data_control = DataControlState::bind_globals(&globals, &qh);
        let idle_power = IdlePowerState::bind_globals(&globals, &qh);
        let screencopy = ScreencopyState::bind_globals(&globals, &qh);
        let toplevel_capture = ToplevelCaptureState::bind_globals(&globals, &qh);

        let state = Self {
            registry_state: RegistryState::new(&globals),
            seat_state: SeatState::new(&globals, &qh),
            output_state: OutputState::new(&globals, &qh),
            compositor_state,
            shm,
            layer_shell,
            text_input_manager,
            text_input: None,
            idle_inhibit_manager,
            idle_inhibitor: None,
            idle_anchor_surface: None,
            gamma_manager,
            gamma_controls: HashMap::new(),
            nightlight_enabled: false,
            nightlight_temp_k: 4000,
            ime_surface: None,
            ime_pending: PendingIme::default(),
            last_ime_cursor_rect: None,
            qh,
            pointer: None,
            pointer_surface: None,
            pointer_pos: (0.0, 0.0),
            pointer_drag: None,
            keyboard: None,
            keyboard_surface: None,
            modifiers: KeyModifiers::default(),
            outputs_by_obj: HashMap::new(),
            output_obj_by_name: HashMap::new(),
            surfaces: HashMap::new(),
            surface_key_by_obj: HashMap::new(),
            wallpapers: HashMap::new(),
            wallpaper_output_by_obj: HashMap::new(),
            anim_clock: AnimationClock::default(),
            renderer: Renderer::new(font_hint),
            data_control,
            idle_power,
            screencopy,
            toplevel_capture,
            pending_events: Vec::new(),
        };

        Ok((conn, event_queue, state))
    }

    pub fn set_font(&mut self, font_hint: &str) {
        self.renderer.reload_font_if_needed(font_hint);
    }

    pub fn set_accessibility(&mut self, font_scale: f32, high_contrast: bool) {
        self.renderer.set_accessibility(font_scale, high_contrast);
    }

    pub fn drain_events(&mut self) -> Vec<SystemEvent> {
        std::mem::take(&mut self.pending_events)
    }

    pub fn surface_count(&self) -> usize {
        self.surfaces.len() + self.wallpapers.len()
    }

    pub fn animating_surface_count(&self) -> usize {
        self.surfaces.values().filter(|s| s.spec.animating).count()
    }

    pub fn has_idle_inhibit(&self) -> bool {
        self.idle_inhibit_manager.is_some()
    }

    pub fn has_gamma_control(&self) -> bool {
        self.gamma_manager.is_some()
    }

    pub fn has_data_control(&self) -> bool {
        self.data_control.has_protocol()
    }

    pub fn has_idle_notify(&self) -> bool {
        self.idle_power.has_idle_notify()
    }

    pub fn has_output_power(&self) -> bool {
        self.idle_power.has_output_power()
    }

    pub fn has_screencopy(&self) -> bool {
        self.screencopy.has_screencopy()
    }

    pub fn has_toplevel_capture(&self) -> bool {
        self.toplevel_capture.is_available()
    }

    pub fn request_window_previews(
        &mut self,
        request_id: u64,
        windows: &[(String, String, String)],
        max_width: u32,
    ) {
        self.toplevel_capture
            .request_previews(request_id, windows, max_width, &self.qh);
    }

    pub fn request_screencopy(&mut self, request_id: u64) -> Result<(), String> {
        let targets: Vec<(ScreencopyFrameTag, wl_output::WlOutput)> = self
            .outputs_by_obj
            .values()
            .filter_map(|tracked| {
                let parsed = tracked.info.as_ref()?;
                let sctk_info = self.output_state.info(&tracked.wl_output);
                let (lx, ly) = sctk_info
                    .as_ref()
                    .and_then(|i| i.logical_position.or(Some(i.location)))
                    .unwrap_or((0, 0));
                let transform = sctk_info
                    .as_ref()
                    .map(|i| OutputTransform::from_wl(i.transform))
                    .unwrap_or(OutputTransform::Normal);
                Some((
                    ScreencopyFrameTag {
                        request_id,
                        output_name: parsed.name.clone(),
                        logical_x: lx,
                        logical_y: ly,
                        logical_w: parsed.width.max(1) as u32,
                        logical_h: parsed.height.max(1) as u32,
                        transform,
                    },
                    tracked.wl_output.clone(),
                ))
            })
            .collect();
        self.screencopy.capture_outputs(
            request_id,
            targets.iter().map(|(t, o)| (t.clone(), o)),
            &self.qh,
        )
    }

    pub fn configure_idle_timeouts(&mut self, stages: &[(String, u64)]) -> bool {
        let Some(seat) = self.seat_state.seats().next() else {
            self.idle_power.set_pending_stages(stages);
            return false;
        };
        self.idle_power.configure_timeouts(stages, &seat, &self.qh)
    }

    pub fn set_outputs_dpms(&mut self, on: bool) -> bool {
        let iter = self
            .output_obj_by_name
            .iter()
            .filter_map(|(name, oid)| self.outputs_by_obj.get(oid).map(|t| (name, &t.wl_output)));
        self.idle_power.set_dpms(on, iter, &self.qh)
    }

    pub fn configure_clipboard(
        &mut self,
        ignore_mimes: Vec<String>,
        max_item_bytes: usize,
        persist: bool,
    ) {
        self.data_control
            .configure(ignore_mimes, max_item_bytes, persist);
    }

    pub fn set_clipboard_selection(&mut self, mime: String, bytes: Vec<u8>) -> bool {
        self.data_control.set_selection(mime, bytes, &self.qh)
    }

    pub fn note_clipboard_captured(&mut self, mime: &str, bytes: &[u8]) {
        self.data_control.note_captured(mime, bytes);
    }

    pub fn request_clipboard_paste_text(&mut self, surface_id: String) -> bool {
        self.data_control.request_paste_text(surface_id)
    }

    pub fn drain_clipboard_pipe_reads(&mut self) -> Vec<ClipboardPipeRead> {
        std::mem::take(&mut self.data_control.pending_reads)
    }

    pub fn drain_clipboard_pipe_writes(&mut self) -> Vec<ClipboardPipeWrite> {
        std::mem::take(&mut self.data_control.pending_writes)
    }

    /// Ensures `zwp_text_input_v3` and `data_control` are bound for the active seat even if
    /// `wl_seat` was already present in the initial registry snapshot before `SeatHandler::new_seat`.
    pub fn ensure_text_input(&mut self) {
        if let Some(seat) = self.seat_state.seats().next() {
            if self.text_input.is_none() {
                if let Some(ref mgr) = self.text_input_manager {
                    self.text_input = Some(mgr.get_text_input(&seat, &self.qh, ()));
                }
            }
            self.data_control.ensure_device(&seat, &self.qh);
        }
    }

    pub fn wallpaper_count(&self) -> usize {
        self.wallpapers.len()
    }

    /// Enables or disables Wayland idle inhibition (`zwp_idle_inhibit_manager_v1`) for Caffeine.
    pub fn set_caffeine(&mut self, enabled: bool) -> bool {
        if !enabled {
            if let Some(inh) = self.idle_inhibitor.take() {
                inh.destroy();
            }
            self.idle_anchor_surface = None;
            return true;
        }
        if self.idle_inhibitor.is_some() {
            return true;
        }
        let Some(ref mgr) = self.idle_inhibit_manager else {
            return false;
        };
        let target_surface = if let Some(s) = self.surfaces.values().next() {
            s.layer.wl_surface().clone()
        } else {
            // In Ghost preset with 0 visible surfaces, bind a tiny 1x1 transparent anchor
            // strictly while Caffeine is enabled, and drop it immediately when disabled.
            let wl = self.compositor_state.create_surface(&self.qh);
            let layer = self.layer_shell.create_layer_surface(
                &self.qh,
                wl,
                WlrLayer::Background,
                Some("kaze-caffeine-anchor".to_string()),
                None,
            );
            layer.set_size(1, 1);
            layer.set_exclusive_zone(0);
            layer.commit();
            let s = layer.wl_surface().clone();
            self.idle_anchor_surface = Some(layer);
            s
        };
        self.idle_inhibitor = Some(mgr.create_inhibitor(&target_surface, &self.qh, ()));
        true
    }

    /// Applies color temperature via `zwlr_gamma_control_manager_v1` across physical outputs.
    /// Returns `false` if the protocol is unavailable so the daemon can invoke `hyprsunset` fallback.
    pub fn set_nightlight(&mut self, enabled: bool, temp_k: u32) -> bool {
        self.nightlight_enabled = enabled;
        self.nightlight_temp_k = temp_k.clamp(2500, 6500);
        if !enabled {
            for (_, entry) in self.gamma_controls.drain() {
                entry.control.destroy();
            }
            return true;
        }
        let Some(ref mgr) = self.gamma_manager else {
            return false;
        };
        let targets: Vec<(String, wl_output::WlOutput)> = self
            .outputs_by_obj
            .values()
            .filter_map(|t| {
                let info = t.info.as_ref()?;
                if info.name == "kaze-share" {
                    return None;
                }
                Some((info.name.clone(), t.wl_output.clone()))
            })
            .collect();
        for (name, wl_out) in targets {
            if let Some(existing) = self.gamma_controls.get(&name) {
                if let Some(size) = existing.ramp_size {
                    apply_gamma_ramp(&existing.control, size, self.nightlight_temp_k);
                }
            } else {
                let control = mgr.get_gamma_control(&wl_out, &self.qh, name.clone());
                self.gamma_controls.insert(
                    name,
                    GammaEntry {
                        control,
                        ramp_size: None,
                    },
                );
            }
        }
        true
    }

    /// Uploads a decoded, pre-scaled BGRA wallpaper frame into a single-slot SHM `Background`
    /// surface (`kaze-wallpaper-<output>`) and drops the heap pixel vector immediately.
    pub fn set_wallpaper_buffer(
        &mut self,
        output_name: &str,
        width: u32,
        height: u32,
        bgra_premul: Vec<u8>,
    ) {
        if output_name == "kaze-share" || width == 0 || height == 0 {
            return;
        }
        let Some(wl_out) = self
            .output_obj_by_name
            .get(output_name)
            .and_then(|obj| self.outputs_by_obj.get(obj))
            .map(|t| t.wl_output.clone())
        else {
            return;
        };

        let expected_len = (width as usize)
            .saturating_mul(height as usize)
            .saturating_mul(4);
        if bgra_premul.len() < expected_len {
            return;
        }

        if let Some(existing) = self.wallpapers.get_mut(output_name) {
            if existing.width == width
                && existing.height == height
                && existing.configured
                && write_wallpaper_frame(existing, &bgra_premul)
            {
                drop(bgra_premul);
                trim_glibc_heap();
                return;
            }
        }

        self.remove_wallpaper_for_output(output_name);
        let wl_surface = self.compositor_state.create_surface(&self.qh);
        let obj_id = wl_surface.id();
        let layer = self.layer_shell.create_layer_surface(
            &self.qh,
            wl_surface,
            WlrLayer::Background,
            Some(format!("kaze-wallpaper-{output_name}")),
            Some(&wl_out),
        );
        layer.set_anchor(
            LayerAnchor::TOP | LayerAnchor::BOTTOM | LayerAnchor::LEFT | LayerAnchor::RIGHT,
        );
        layer.set_exclusive_zone(-1);
        layer.set_keyboard_interactivity(KeyboardInteractivity::None);
        layer.commit();

        let Ok(pool) = SlotPool::new(expected_len.max(4096), &self.shm) else {
            eprintln!("kaze-ui: failed allocating wallpaper SHM pool for {output_name}");
            return;
        };

        self.wallpaper_output_by_obj
            .insert(obj_id, output_name.to_string());
        self.wallpapers.insert(
            output_name.to_string(),
            WallpaperSurface {
                layer,
                pool,
                width,
                height,
                configured: false,
                pending_bgra: Some(bgra_premul),
            },
        );
    }

    pub fn clear_wallpapers(&mut self) {
        self.wallpaper_output_by_obj.clear();
        self.wallpapers.clear();
        trim_glibc_heap();
    }

    fn remove_wallpaper_for_output(&mut self, output_name: &str) {
        if let Some(wp) = self.wallpapers.remove(output_name) {
            let obj_id = wp.layer.wl_surface().id();
            self.wallpaper_output_by_obj.remove(&obj_id);
            drop(wp);
        }
    }

    pub fn active_namespaces(&self) -> Vec<String> {
        let mut names: Vec<String> = self
            .surfaces
            .values()
            .map(|s| s.spec.namespace.clone())
            .chain(
                self.wallpapers
                    .keys()
                    .map(|out| format!("kaze-wallpaper-{out}")),
            )
            .collect();
        names.sort();
        names
    }

    pub fn sync_surfaces(&mut self, specs: Vec<SurfaceSpec>, dirty: DirtyFlags) {
        let desired_ids: HashSet<String> = specs.iter().map(|s| s.id.clone()).collect();

        // Destroy any surface no longer requested (e.g. bar-hide, OSD auto-hide, output removed).
        let stale_ids: Vec<String> = self
            .surfaces
            .keys()
            .filter(|id| !desired_ids.contains(*id))
            .cloned()
            .collect();
        for id in stale_ids {
            self.remove_surface(&id);
        }

        // Create new surfaces or update existing ones selectively.
        for spec in specs {
            let id_key = spec.id.clone();
            if let Some(existing) = self.surfaces.get_mut(&id_key) {
                let geom_changed = !existing.spec.geometry_eq(&spec);
                let content_changed = existing.spec != spec;
                let force_redraw = dirty.intersects(
                    DirtyFlags::BAR
                        | DirtyFlags::ISLAND
                        | DirtyFlags::OSD
                        | DirtyFlags::NOTIFY
                        | DirtyFlags::LAUNCHER
                        | DirtyFlags::CC
                        | DirtyFlags::TRAY
                        | DirtyFlags::THEME
                        | DirtyFlags::DOCK
                        | DirtyFlags::SWITCHER
                        | DirtyFlags::CORNERS
                        | DirtyFlags::CANVAS,
                );

                let recreate = existing.spec.namespace != spec.namespace
                    || existing.spec.output != spec.output;
                if recreate {
                    let id = spec.id.clone();
                    self.remove_surface(&id);
                    self.create_surface(spec);
                    continue;
                }

                if geom_changed {
                    let layer_geom_changed = existing.spec.layer != spec.layer
                        || existing.spec.keyboard_interactivity != spec.keyboard_interactivity
                        || existing.spec.anchor != spec.anchor
                        || existing.spec.exclusive_zone != spec.exclusive_zone
                        || existing.spec.width != spec.width
                        || existing.spec.height != spec.height
                        || existing.spec.margin != spec.margin;
                    let size_changed =
                        existing.spec.width != spec.width || existing.spec.height != spec.height;
                    let input_changed = existing.spec.input_regions != spec.input_regions;
                    if layer_geom_changed {
                        apply_layer_geometry(&existing.layer, &spec);
                    }
                    if input_changed {
                        apply_input_regions(
                            &self.compositor_state,
                            existing.layer.wl_surface(),
                            spec.input_regions.as_deref(),
                        );
                    }
                    existing.spec = spec;
                    existing.dirty = true;
                    if size_changed {
                        // Wait for compositor configure before attaching a resized buffer.
                        existing.configured = false;
                    }
                    if layer_geom_changed || input_changed {
                        existing.layer.commit();
                    }
                } else if content_changed || force_redraw || spec.animating {
                    existing.spec = spec;
                    existing.dirty = true;
                }
                if let Some(s) = self.surfaces.get(&id_key) {
                    if !s.spec.animating {
                        self.anim_clock.stop(&id_key);
                    }
                }
            } else {
                self.create_surface(spec);
            }
        }

        // Only draw surfaces that are configured, dirty, and not already waiting on a frame callback.
        let ids_to_draw: Vec<String> = self
            .surfaces
            .iter()
            .filter(|(_, s)| s.configured && s.dirty && !s.frame_in_flight)
            .map(|(id, _)| id.clone())
            .collect();
        for id in ids_to_draw {
            self.draw_surface(&id);
        }
        self.update_ime_cursor_rect_for_focused();
    }

    fn create_surface(&mut self, spec: SurfaceSpec) {
        let target_output = spec.output.as_deref().and_then(|name| {
            self.output_obj_by_name
                .get(name)
                .and_then(|obj_id| self.outputs_by_obj.get(obj_id))
                .map(|o| (o.wl_output.clone(), o.info.as_ref().map_or(1, |i| i.scale)))
        });

        // If the spec targets a specific output that does not exist yet, defer creation safely.
        if spec.output.is_some() && target_output.is_none() {
            return;
        }

        let (wl_out, scale) = match target_output {
            Some((o, s)) => (Some(o), s.max(1)),
            None => (None, 1),
        };

        let wl_surface = self.compositor_state.create_surface(&self.qh);
        let obj_id = wl_surface.id();
        let layer = self.layer_shell.create_layer_surface(
            &self.qh,
            wl_surface,
            to_wlr_layer(spec.layer),
            Some(spec.namespace.clone()),
            wl_out.as_ref(),
        );
        apply_layer_geometry(&layer, &spec);
        apply_input_regions(
            &self.compositor_state,
            layer.wl_surface(),
            spec.input_regions.as_deref(),
        );
        layer.commit();

        let init_w = spec.width.max(42);
        let init_h = spec.height.max(42);
        let initial_bytes = (init_w as usize)
            .saturating_mul(init_h as usize)
            .saturating_mul(4)
            .saturating_mul(2)
            .max(16 * 1024);
        let Ok(pool) = SlotPool::new(initial_bytes, &self.shm) else {
            eprintln!("kaze-ui: failed to allocate SHM pool for {}", spec.id);
            return;
        };

        let id = spec.id.clone();
        self.surface_key_by_obj.insert(obj_id, id.clone());
        self.surfaces.insert(
            id,
            ManagedSurface {
                logical_width: spec.width,
                logical_height: spec.height,
                spec,
                layer,
                pool,
                configured: false,
                scale,
                dirty: true,
                frame_in_flight: false,
            },
        );
    }

    fn remove_surface(&mut self, id: &str) {
        self.anim_clock.stop(id);
        if let Some(surface) = self.surfaces.remove(id) {
            let obj_id = surface.surface_id_obj();
            self.surface_key_by_obj.remove(&obj_id);
            if self.pointer_surface.as_ref() == Some(&obj_id) {
                self.pointer_surface = None;
            }
            if self.keyboard_surface.as_ref() == Some(&obj_id) {
                self.keyboard_surface = None;
                self.disable_ime();
            }
            if self.ime_surface.as_ref() == Some(&obj_id) {
                self.ime_surface = None;
                self.disable_ime();
            }
            // Dropping `surface` destroys `LayerSurface`, `wl_surface`, and `SlotPool` (munmaps SHM).
            drop(surface);
            self.renderer.trim_caches();
            trim_glibc_heap();
        }
    }

    fn remove_surfaces_for_output(&mut self, output_name: &str) {
        self.remove_wallpaper_for_output(output_name);
        if let Some(entry) = self.gamma_controls.remove(output_name) {
            entry.control.destroy();
        }
        let matching: Vec<String> = self
            .surfaces
            .iter()
            .filter(|(_, s)| s.spec.output.as_deref() == Some(output_name))
            .map(|(id, _)| id.clone())
            .collect();
        for id in matching {
            self.remove_surface(&id);
        }
        self.renderer.trim_caches();
        trim_glibc_heap();
    }

    fn draw_surface(&mut self, id: &str) {
        let Some(surface) = self.surfaces.get_mut(id) else {
            return;
        };
        if !surface.configured || !surface.dirty {
            return;
        }

        let logical_w = surface.logical_width.max(1);
        let logical_h = surface.logical_height.max(1);
        let scale = surface.scale.max(1);
        let px_w = logical_w.saturating_mul(scale as u32);
        let px_h = logical_h.saturating_mul(scale as u32);
        let stride = (px_w as i32).saturating_mul(4);

        let Ok((buffer, canvas)) =
            surface
                .pool
                .create_buffer(px_w as i32, px_h as i32, stride, wl_shm::Format::Argb8888)
        else {
            eprintln!("kaze-ui: failed creating SHM buffer for {id} ({px_w}x{px_h})");
            return;
        };

        self.renderer
            .render_spec(&surface.spec, logical_w, logical_h, scale, canvas);

        let wl_surface = surface.layer.wl_surface();
        wl_surface.set_buffer_scale(scale);
        if let Err(err) = buffer.attach_to(wl_surface) {
            eprintln!("kaze-ui: buffer attach failed for {id}: {err}");
            return;
        }
        wl_surface.damage_buffer(0, 0, px_w as i32, px_h as i32);
        wl_surface.frame(&self.qh, wl_surface.clone());
        wl_surface.commit();

        surface.dirty = false;
        surface.frame_in_flight = true;
    }

    fn extract_output_info(&self, output: &wl_output::WlOutput) -> Option<(OutputInfo, i32)> {
        let info = self.output_state.info(output)?;
        let name = info.name.clone()?;
        let scale = info.scale_factor.max(1);
        let current_mode = info
            .modes
            .iter()
            .find(|m| m.current)
            .or_else(|| info.modes.first());
        let refresh_mhz = current_mode
            .map(|m| m.refresh_rate)
            .filter(|&r| r > 0)
            .unwrap_or(DEFAULT_REFRESH_MHZ);
        let (width, height) = if let Some((w, h)) = info.logical_size {
            (w.max(1), h.max(1))
        } else if let Some(mode) = current_mode {
            (
                (mode.dimensions.0 / scale).max(1),
                (mode.dimensions.1 / scale).max(1),
            )
        } else {
            (1920, 1080)
        };
        Some((
            OutputInfo {
                name,
                width,
                height,
                scale,
                make: info.make,
                model: info.model,
                serial: String::new(),
            },
            refresh_mhz,
        ))
    }

    fn refresh_mhz_for_surface(&self, output_name: Option<&str>) -> i32 {
        if let Some(name) = output_name {
            if let Some(obj_id) = self.output_obj_by_name.get(name) {
                if let Some(tracked) = self.outputs_by_obj.get(obj_id) {
                    return tracked.refresh_mhz;
                }
            }
        }
        self.outputs_by_obj
            .values()
            .map(|o| o.refresh_mhz)
            .max()
            .unwrap_or(DEFAULT_REFRESH_MHZ)
    }

    fn surface_accepts_keyboard(&self, obj_id: &ObjectId) -> bool {
        self.surface_key_by_obj
            .get(obj_id)
            .and_then(|k| self.surfaces.get(k))
            .is_some_and(|s| s.spec.keyboard_interactivity != KeyboardMode::None)
    }

    fn enable_ime(&self) {
        if let Some(ref ti) = self.text_input {
            let (rx, ry, rw, rh) = self
                .ime_surface
                .as_ref()
                .and_then(|obj| self.surface_key_by_obj.get(obj))
                .and_then(|key| self.surfaces.get(key))
                .and_then(|s| s.spec.ime_cursor_rect)
                .map(|r| {
                    (
                        r.x.round() as i32,
                        r.y.round() as i32,
                        (r.w.round() as i32).max(2),
                        (r.h.round() as i32).max(16),
                    )
                })
                .unwrap_or((120, 14, 2, 20));
            ti.enable();
            ti.set_content_type(ContentHint::None, ContentPurpose::Normal);
            ti.set_cursor_rectangle(rx, ry, rw, rh);
            ti.commit();
        }
    }

    fn update_ime_cursor_rect_for_focused(&mut self) {
        let Some(ref ti) = self.text_input else {
            return;
        };
        let Some(ref obj) = self.ime_surface else {
            return;
        };
        let Some(key) = self.surface_key_by_obj.get(obj) else {
            return;
        };
        let Some(managed) = self.surfaces.get(key) else {
            return;
        };
        if managed.spec.keyboard_interactivity == KeyboardMode::None {
            return;
        }
        let Some(r) = managed.spec.ime_cursor_rect else {
            return;
        };
        let rect_tuple = (
            r.x.round() as i32,
            r.y.round() as i32,
            (r.w.round() as i32).max(2),
            (r.h.round() as i32).max(16),
        );
        if self.last_ime_cursor_rect != Some(rect_tuple) {
            self.last_ime_cursor_rect = Some(rect_tuple);
            ti.set_cursor_rectangle(rect_tuple.0, rect_tuple.1, rect_tuple.2, rect_tuple.3);
            ti.commit();
        }
    }

    fn disable_ime(&mut self) {
        self.last_ime_cursor_rect = None;
        if let Some(ref ti) = self.text_input {
            ti.disable();
            ti.commit();
        }
    }

    fn emit_key(&mut self, event: SctkKeyEvent, pressed: bool) {
        let Some(ref obj_id) = self.keyboard_surface else {
            return;
        };
        let Some(surface_id) = self.surface_key_by_obj.get(obj_id).cloned() else {
            return;
        };
        self.pending_events.push(SystemEvent::KeyInput {
            surface_id,
            key: CoreKeyEvent {
                keysym: event.keysym.raw(),
                utf8: event.utf8,
                modifiers: self.modifiers,
                pressed,
            },
        });
    }
}

fn to_wlr_layer(layer: Layer) -> WlrLayer {
    match layer {
        Layer::Background => WlrLayer::Background,
        Layer::Bottom => WlrLayer::Bottom,
        Layer::Top => WlrLayer::Top,
        Layer::Overlay => WlrLayer::Overlay,
    }
}

fn to_keyboard_interactivity(mode: KeyboardMode) -> KeyboardInteractivity {
    match mode {
        KeyboardMode::None => KeyboardInteractivity::None,
        KeyboardMode::OnDemand => KeyboardInteractivity::OnDemand,
        KeyboardMode::Exclusive => KeyboardInteractivity::Exclusive,
    }
}

fn to_layer_anchor(anchor: Anchor) -> LayerAnchor {
    let mut out = LayerAnchor::empty();
    if anchor.contains(Anchor::TOP) {
        out |= LayerAnchor::TOP;
    }
    if anchor.contains(Anchor::BOTTOM) {
        out |= LayerAnchor::BOTTOM;
    }
    if anchor.contains(Anchor::LEFT) {
        out |= LayerAnchor::LEFT;
    }
    if anchor.contains(Anchor::RIGHT) {
        out |= LayerAnchor::RIGHT;
    }
    out
}

fn apply_input_regions(
    compositor: &CompositorState,
    wl_surface: &wl_surface::WlSurface,
    regions: Option<&[Rect]>,
) {
    match regions {
        Some(rects) => {
            if let Ok(region) = Region::new(compositor) {
                for r in rects {
                    let x = r.x.floor() as i32;
                    let y = r.y.floor() as i32;
                    let w = r.w.ceil().max(0.0) as i32;
                    let h = r.h.ceil().max(0.0) as i32;
                    if w > 0 && h > 0 {
                        region.add(x, y, w, h);
                    }
                }
                wl_surface.set_input_region(Some(region.wl_region()));
            }
        }
        None => {
            wl_surface.set_input_region(None);
        }
    }
}

fn apply_layer_geometry(layer: &LayerSurface, spec: &SurfaceSpec) {
    layer.set_layer(to_wlr_layer(spec.layer));
    layer.set_anchor(to_layer_anchor(spec.anchor));
    layer.set_size(spec.width, spec.height);
    layer.set_exclusive_zone(spec.exclusive_zone);
    layer.set_margin(
        spec.margin.top,
        spec.margin.right,
        spec.margin.bottom,
        spec.margin.left,
    );
    layer.set_keyboard_interactivity(to_keyboard_interactivity(spec.keyboard_interactivity));
}

impl CompositorHandler for UiState {
    fn scale_factor_changed(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        surface: &wl_surface::WlSurface,
        new_factor: i32,
    ) {
        let obj_id = surface.id();
        if let Some(id) = self.surface_key_by_obj.get(&obj_id).cloned() {
            if let Some(managed) = self.surfaces.get_mut(&id) {
                let factor = new_factor.max(1);
                if managed.scale != factor {
                    managed.scale = factor;
                    managed.dirty = true;
                    if managed.configured && !managed.frame_in_flight {
                        self.draw_surface(&id);
                    }
                }
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
        surface: &wl_surface::WlSurface,
        time: u32,
    ) {
        let obj_id = surface.id();
        if let Some(id) = self.surface_key_by_obj.get(&obj_id).cloned() {
            let (animating, should_redraw, output_name) =
                if let Some(managed) = self.surfaces.get_mut(&id) {
                    managed.frame_in_flight = false;
                    (
                        managed.spec.animating,
                        managed.configured && managed.dirty,
                        managed.spec.output.clone(),
                    )
                } else {
                    (false, false, None)
                };

            if animating {
                let refresh_mhz = self.refresh_mhz_for_surface(output_name.as_deref());
                let dt_secs = self.anim_clock.tick(&id, time, refresh_mhz);
                self.pending_events.push(SystemEvent::FrameTick {
                    surface_id: id,
                    dt_secs,
                });
            } else {
                self.anim_clock.stop(&id);
                if should_redraw {
                    self.draw_surface(&id);
                    let _ = _conn.flush();
                }
            }
        }
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

impl OutputHandler for UiState {
    fn output_state(&mut self) -> &mut OutputState {
        &mut self.output_state
    }

    fn new_output(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        output: wl_output::WlOutput,
    ) {
        let obj_id = output.id();
        let extracted = self.extract_output_info(&output);
        let (info, refresh_mhz) = match extracted {
            Some((i, r)) => (Some(i), r),
            None => (None, DEFAULT_REFRESH_MHZ),
        };
        if let Some(ref parsed) = info {
            self.output_obj_by_name
                .insert(parsed.name.clone(), obj_id.clone());
            self.pending_events
                .push(SystemEvent::OutputAdded(parsed.clone()));
        }
        self.outputs_by_obj.insert(
            obj_id,
            TrackedOutput {
                wl_output: output,
                info,
                refresh_mhz,
            },
        );
    }

    fn update_output(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        output: wl_output::WlOutput,
    ) {
        let obj_id = output.id();
        let Some((new_info, refresh_mhz)) = self.extract_output_info(&output) else {
            return;
        };

        let prev_info = self
            .outputs_by_obj
            .get(&obj_id)
            .and_then(|t| t.info.clone());

        self.output_obj_by_name
            .insert(new_info.name.clone(), obj_id.clone());

        if let Some(tracked) = self.outputs_by_obj.get_mut(&obj_id) {
            tracked.info = Some(new_info.clone());
            tracked.refresh_mhz = refresh_mhz;
        } else {
            self.outputs_by_obj.insert(
                obj_id,
                TrackedOutput {
                    wl_output: output,
                    info: Some(new_info.clone()),
                    refresh_mhz,
                },
            );
        }

        match prev_info {
            None => self.pending_events.push(SystemEvent::OutputAdded(new_info)),
            Some(old) if old != new_info => self
                .pending_events
                .push(SystemEvent::OutputUpdated(new_info)),
            Some(_) => {}
        }
    }

    fn output_destroyed(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        output: wl_output::WlOutput,
    ) {
        let obj_id = output.id();
        if let Some(tracked) = self.outputs_by_obj.remove(&obj_id) {
            if let Some(info) = tracked.info {
                let is_current = self
                    .output_obj_by_name
                    .get(&info.name)
                    .is_some_and(|id| id == &obj_id);
                if is_current {
                    self.output_obj_by_name.remove(&info.name);
                    self.idle_power.remove_output(&info.name);
                    self.remove_surfaces_for_output(&info.name);
                    self.pending_events
                        .push(SystemEvent::OutputRemoved { name: info.name });
                }
            }
        }
    }
}

impl LayerShellHandler for UiState {
    fn closed(&mut self, _conn: &Connection, _qh: &QueueHandle<Self>, layer: &LayerSurface) {
        let obj_id = layer.wl_surface().id();
        if let Some(out_name) = self.wallpaper_output_by_obj.remove(&obj_id) {
            self.wallpapers.remove(&out_name);
            return;
        }
        if let Some(id) = self.surface_key_by_obj.get(&obj_id).cloned() {
            self.remove_surface(&id);
            self.pending_events
                .push(SystemEvent::SurfaceClosed { surface_id: id });
        }
    }

    fn configure(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        layer: &LayerSurface,
        configure: LayerSurfaceConfigure,
        _serial: u32,
    ) {
        let obj_id = layer.wl_surface().id();
        if let Some(out_name) = self.wallpaper_output_by_obj.get(&obj_id).cloned() {
            if let Some(wp) = self.wallpapers.get_mut(&out_name) {
                wp.configured = true;
                if let Some(bgra) = wp.pending_bgra.take() {
                    let _ = write_wallpaper_frame(wp, &bgra);
                    drop(bgra);
                    trim_glibc_heap();
                }
            }
            return;
        }
        let Some(id) = self.surface_key_by_obj.get(&obj_id).cloned() else {
            return;
        };
        let should_draw = if let Some(managed) = self.surfaces.get_mut(&id) {
            let new_w = if configure.new_size.0 > 0 {
                configure.new_size.0
            } else {
                managed.spec.width.max(1)
            };
            let new_h = if configure.new_size.1 > 0 {
                configure.new_size.1
            } else {
                managed.spec.height.max(1)
            };
            managed.logical_width = new_w;
            managed.logical_height = new_h;
            managed.configured = true;
            managed.dirty = true;
            !managed.frame_in_flight
        } else {
            false
        };
        if should_draw {
            self.draw_surface(&id);
            let _ = _conn.flush();
        }
    }
}

impl ShmHandler for UiState {
    fn shm_state(&mut self) -> &mut Shm {
        &mut self.shm
    }
}

impl SeatHandler for UiState {
    fn seat_state(&mut self) -> &mut SeatState {
        &mut self.seat_state
    }

    fn new_seat(&mut self, conn: &Connection, qh: &QueueHandle<Self>, seat: wl_seat::WlSeat) {
        self.data_control.ensure_device(&seat, qh);
        self.idle_power.on_seat(&seat, qh);
        if self.text_input.is_none() {
            if let Some(ref mgr) = self.text_input_manager {
                self.text_input = Some(mgr.get_text_input(&seat, qh, ()));
            }
        }
        let _ = conn.flush();
    }

    fn new_capability(
        &mut self,
        conn: &Connection,
        qh: &QueueHandle<Self>,
        seat: wl_seat::WlSeat,
        capability: Capability,
    ) {
        if self.text_input.is_none() {
            if let Some(ref mgr) = self.text_input_manager {
                self.text_input = Some(mgr.get_text_input(&seat, qh, ()));
                let _ = conn.flush();
            }
        }
        if capability == Capability::Pointer && self.pointer.is_none() {
            if let Ok(pointer) = self.seat_state.get_pointer(qh, &seat) {
                self.pointer = Some(pointer);
            }
        }
        if capability == Capability::Keyboard && self.keyboard.is_none() {
            if let Ok(keyboard) = self.seat_state.get_keyboard(qh, &seat, None) {
                self.keyboard = Some(keyboard);
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
        if capability == Capability::Pointer {
            if let Some(pointer) = self.pointer.take() {
                pointer.release();
            }
            self.pointer_surface = None;
        }
        if capability == Capability::Keyboard {
            if let Some(keyboard) = self.keyboard.take() {
                keyboard.release();
            }
            self.keyboard_surface = None;
            self.disable_ime();
        }
    }

    fn remove_seat(&mut self, _conn: &Connection, _qh: &QueueHandle<Self>, _seat: wl_seat::WlSeat) {
        if let Some(ti) = self.text_input.take() {
            ti.destroy();
        }
        self.ime_surface = None;
    }
}

impl KeyboardHandler for UiState {
    fn enter(
        &mut self,
        conn: &Connection,
        _qh: &QueueHandle<Self>,
        _keyboard: &wl_keyboard::WlKeyboard,
        surface: &wl_surface::WlSurface,
        _serial: u32,
        _raw: &[u32],
        keysyms: &[Keysym],
    ) {
        let obj_id = surface.id();
        self.keyboard_surface = Some(obj_id.clone());
        let accepts_kb = self.surface_accepts_keyboard(&obj_id);
        // Only enable zwp_text_input_v3 once the compositor has sent text_input.enter on this surface.
        if self.ime_surface.as_ref() == Some(&obj_id) && accepts_kb {
            self.enable_ime();
            let _ = conn.flush();
        }
        // If Escape was pressed in the brief window before the compositor sent wl_keyboard.enter,
        // Wayland delivers it in `enter.keysyms` rather than a separate press_key event.
        if accepts_kb && keysyms.contains(&Keysym::Escape) {
            if let Some(surface_id) = self.surface_key_by_obj.get(&obj_id).cloned() {
                self.pending_events.push(SystemEvent::KeyInput {
                    surface_id,
                    key: CoreKeyEvent {
                        keysym: Keysym::Escape.raw(),
                        utf8: None,
                        modifiers: self.modifiers,
                        pressed: true,
                    },
                });
            }
        }
    }

    fn leave(
        &mut self,
        conn: &Connection,
        _qh: &QueueHandle<Self>,
        _keyboard: &wl_keyboard::WlKeyboard,
        surface: &wl_surface::WlSurface,
        _serial: u32,
    ) {
        let obj_id = surface.id();
        if self.keyboard_surface.as_ref() == Some(&obj_id) {
            self.keyboard_surface = None;
            self.disable_ime();
            let _ = conn.flush();
            if self.surface_accepts_keyboard(&obj_id) {
                if let Some(surface_id) = self.surface_key_by_obj.get(&obj_id).cloned() {
                    self.pending_events
                        .push(SystemEvent::KeyboardFocusLost { surface_id });
                }
            }
        }
    }

    fn press_key(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        _keyboard: &wl_keyboard::WlKeyboard,
        _serial: u32,
        event: SctkKeyEvent,
    ) {
        self.emit_key(event, true);
    }

    fn repeat_key(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        _keyboard: &wl_keyboard::WlKeyboard,
        _serial: u32,
        event: SctkKeyEvent,
    ) {
        self.emit_key(event, true);
    }

    fn release_key(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        _keyboard: &wl_keyboard::WlKeyboard,
        _serial: u32,
        event: SctkKeyEvent,
    ) {
        self.emit_key(event, false);
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
        self.modifiers = KeyModifiers {
            ctrl: modifiers.ctrl,
            alt: modifiers.alt,
            shift: modifiers.shift,
            logo: modifiers.logo,
        };
        let surface_id = self
            .keyboard_surface
            .as_ref()
            .and_then(|id| self.surface_key_by_obj.get(id).cloned())
            .unwrap_or_default();
        self.pending_events.push(SystemEvent::ModifiersChanged {
            surface_id,
            modifiers: self.modifiers,
            caps_lock: modifiers.caps_lock,
            num_lock: modifiers.num_lock,
            scroll_lock: false,
            layout_idx: layout,
        });
    }
}

impl PointerHandler for UiState {
    fn pointer_frame(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        _pointer: &wl_pointer::WlPointer,
        events: &[PointerEvent],
    ) {
        for event in events {
            match event.kind {
                PointerEventKind::Enter { .. } => {
                    let obj = event.surface.id();
                    self.pointer_surface = Some(obj.clone());
                    self.pointer_pos = event.position;
                    if let Some(surf_id) = self.surface_key_by_obj.get(&obj) {
                        self.pending_events.push(SystemEvent::PointerEnter {
                            surface_id: surf_id.clone(),
                            x: event.position.0 as f32,
                            y: event.position.1 as f32,
                        });
                    }
                }
                PointerEventKind::Leave { .. } => {
                    let obj = event.surface.id();
                    if self.pointer_surface.as_ref() == Some(&obj) {
                        if let Some(surf_id) = self.surface_key_by_obj.get(&obj) {
                            self.pending_events.push(SystemEvent::PointerLeave {
                                surface_id: surf_id.clone(),
                            });
                        }
                        self.pointer_surface = None;
                        self.pointer_drag = None;
                    }
                }
                PointerEventKind::Motion { .. } => {
                    self.pointer_surface = Some(event.surface.id());
                    self.pointer_pos = event.position;
                    if let Some((ref surf_id, ref target_id)) = self.pointer_drag {
                        self.pending_events.push(SystemEvent::PointerDrag {
                            surface_id: surf_id.clone(),
                            target_id: target_id.clone(),
                            x: event.position.0 as f32,
                            y: event.position.1 as f32,
                        });
                    } else if let Some(surf_id) = self.surface_key_by_obj.get(&event.surface.id()) {
                        let wants_motion = surf_id.starts_with("capture:")
                            || surf_id.starts_with("picker:")
                            || self
                                .surfaces
                                .get(surf_id)
                                .is_some_and(|s| s.spec.track_pointer_motion);
                        if wants_motion {
                            self.pending_events.push(SystemEvent::PointerMotion {
                                surface_id: surf_id.clone(),
                                x: event.position.0 as f32,
                                y: event.position.1 as f32,
                            });
                        }
                    }
                }
                PointerEventKind::Release { .. } => {
                    if let Some((surf_id, target_id)) = self.pointer_drag.take() {
                        self.pending_events.push(SystemEvent::PointerRelease {
                            surface_id: surf_id,
                            target_id,
                            x: event.position.0 as f32,
                            y: event.position.1 as f32,
                        });
                    }
                }
                PointerEventKind::Press { button, .. } => {
                    let btn = match button {
                        BTN_LEFT => PointerButton::Left,
                        BTN_RIGHT => PointerButton::Right,
                        BTN_MIDDLE => PointerButton::Middle,
                        _ => continue,
                    };
                    let (px, py) = (event.position.0 as f32, event.position.1 as f32);
                    let surf_obj = event.surface.id();
                    if let Some(surface_id) = self.surface_key_by_obj.get(&surf_obj) {
                        if let Some(managed) = self.surfaces.get(surface_id) {
                            for target in &managed.spec.hit_targets {
                                if target.rect.contains(px, py) {
                                    if btn == PointerButton::Left
                                        && (target.id.contains(":slider:")
                                            || target.id.contains(":canvas")
                                            || target.id.starts_with("dock:item:")
                                            || target.id.starts_with("canvas:"))
                                    {
                                        self.pointer_drag =
                                            Some((surface_id.clone(), target.id.clone()));
                                    }
                                    self.pending_events.push(SystemEvent::PointerClick {
                                        surface_id: surface_id.clone(),
                                        target_id: target.id.clone(),
                                        button: btn,
                                    });
                                    self.pending_events.push(SystemEvent::PointerClickAt {
                                        surface_id: surface_id.clone(),
                                        target_id: target.id.clone(),
                                        button: btn,
                                        x: px,
                                        y: py,
                                    });
                                    break;
                                }
                            }
                        }
                    }
                }
                PointerEventKind::Axis { vertical, .. } => {
                    let delta = if vertical.discrete != 0 {
                        f64::from(vertical.discrete)
                    } else {
                        vertical.absolute
                    };
                    if delta.abs() < 0.01 {
                        continue;
                    }
                    let (px, py) = (event.position.0 as f32, event.position.1 as f32);
                    let surf_obj = event.surface.id();
                    if let Some(surface_id) = self.surface_key_by_obj.get(&surf_obj) {
                        if let Some(managed) = self.surfaces.get(surface_id) {
                            for target in &managed.spec.hit_targets {
                                if target.rect.contains(px, py) {
                                    self.pending_events.push(SystemEvent::PointerScroll {
                                        surface_id: surface_id.clone(),
                                        target_id: target.id.clone(),
                                        delta_y: delta,
                                        modifiers: self.modifiers,
                                    });
                                    break;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

fn trim_glibc_heap() {
    #[cfg(target_env = "gnu")]
    // SAFETY: `malloc_trim(0)` releases unused glibc arena pages back to the kernel.
    unsafe {
        libc::malloc_trim(0);
    }
}

fn write_wallpaper_frame(wp: &mut WallpaperSurface, bgra: &[u8]) -> bool {
    let stride = (wp.width as i32).saturating_mul(4);
    let Ok((buffer, canvas)) = wp.pool.create_buffer(
        wp.width as i32,
        wp.height as i32,
        stride,
        wl_shm::Format::Argb8888,
    ) else {
        return false;
    };
    let len = canvas.len().min(bgra.len());
    canvas[..len].copy_from_slice(&bgra[..len]);
    let wl_surface = wp.layer.wl_surface();
    wl_surface.set_buffer_scale(1);
    if buffer.attach_to(wl_surface).is_err() {
        return false;
    }
    wl_surface.damage_buffer(0, 0, wp.width as i32, wp.height as i32);
    wl_surface.commit();
    true
}

/// Computes normalized RGB multipliers for color temperature `temp_k` (Tanner approximation).
pub fn kelvin_to_rgb_multipliers(temp_k: u32) -> (f64, f64, f64) {
    let t = (f64::from(temp_k.clamp(2000, 6500))) / 100.0;
    let r = 1.0;
    let g = ((99.470_802_586_1 * t.ln() - 161.119_568_166_1) / 255.0).clamp(0.35, 1.0);
    let b = if t >= 65.0 {
        1.0
    } else {
        ((138.517_731_223_1 * (t - 10.0).max(1.0).ln() - 305.044_792_730_7) / 255.0)
            .clamp(0.15, 1.0)
    };
    (r, g, b)
}

fn apply_gamma_ramp(control: &ZwlrGammaControlV1, size: u32, temp_k: u32) {
    let n = size as usize;
    if n == 0 || n > 65_536 {
        return;
    }
    let (rm, gm, bm) = kelvin_to_rgb_multipliers(temp_k);
    let mut bytes = Vec::with_capacity(n * 3 * 2);
    for mult in [rm, gm, bm] {
        for i in 0..n {
            let frac = if n > 1 {
                i as f64 / (n - 1) as f64
            } else {
                1.0
            };
            let v = (frac * mult * 65_535.0).round().clamp(0.0, 65_535.0) as u16;
            bytes.extend_from_slice(&v.to_ne_bytes());
        }
    }
    let name = c"kaze-gamma-ramp";
    // SAFETY: valid C string pointer, MFD_CLOEXEC flag.
    let raw_fd = unsafe { libc::memfd_create(name.as_ptr(), libc::MFD_CLOEXEC) };
    if raw_fd < 0 {
        return;
    }
    // SAFETY: `raw_fd` is a fresh owned file descriptor from `memfd_create`.
    let owned = unsafe { OwnedFd::from_raw_fd(raw_fd) };
    let mut file = std::fs::File::from(owned);
    if file.write_all(&bytes).is_ok() {
        let _ = file.flush();
        control.set_gamma(file.as_fd());
    }
}

impl Dispatch<ZwpIdleInhibitManagerV1, ()> for UiState {
    fn event(
        _state: &mut Self,
        _proxy: &ZwpIdleInhibitManagerV1,
        _event: <ZwpIdleInhibitManagerV1 as Proxy>::Event,
        _data: &(),
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<ZwpIdleInhibitorV1, ()> for UiState {
    fn event(
        _state: &mut Self,
        _proxy: &ZwpIdleInhibitorV1,
        _event: <ZwpIdleInhibitorV1 as Proxy>::Event,
        _data: &(),
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<ZwlrGammaControlManagerV1, ()> for UiState {
    fn event(
        _state: &mut Self,
        _proxy: &ZwlrGammaControlManagerV1,
        _event: <ZwlrGammaControlManagerV1 as Proxy>::Event,
        _data: &(),
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<ZwlrGammaControlV1, String> for UiState {
    fn event(
        state: &mut Self,
        proxy: &ZwlrGammaControlV1,
        event: zwlr_gamma_control_v1::Event,
        output_name: &String,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
        match event {
            zwlr_gamma_control_v1::Event::GammaSize { size } => {
                if let Some(entry) = state.gamma_controls.get_mut(output_name) {
                    entry.ramp_size = Some(size);
                }
                if state.nightlight_enabled {
                    apply_gamma_ramp(proxy, size, state.nightlight_temp_k);
                }
            }
            zwlr_gamma_control_v1::Event::Failed => {
                if let Some(entry) = state.gamma_controls.remove(output_name) {
                    entry.control.destroy();
                }
            }
            _ => {}
        }
    }
}

impl Dispatch<ZwpTextInputManagerV3, ()> for UiState {
    fn event(
        _state: &mut Self,
        _proxy: &ZwpTextInputManagerV3,
        _event: <ZwpTextInputManagerV3 as Proxy>::Event,
        _data: &(),
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<ZwpTextInputV3, ()> for UiState {
    fn event(
        state: &mut Self,
        _proxy: &ZwpTextInputV3,
        event: zwp_text_input_v3::Event,
        _data: &(),
        conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
        match event {
            zwp_text_input_v3::Event::Enter { surface } => {
                let obj_id = surface.id();
                state.ime_surface = Some(obj_id.clone());
                if state.surface_accepts_keyboard(&obj_id) {
                    state.enable_ime();
                    let _ = conn.flush();
                }
            }
            zwp_text_input_v3::Event::Leave { surface } => {
                if state.ime_surface.as_ref() == Some(&surface.id()) {
                    state.ime_surface = None;
                    state.ime_pending = PendingIme::default();
                    state.disable_ime();
                    let _ = conn.flush();
                }
            }
            zwp_text_input_v3::Event::PreeditString {
                text,
                cursor_begin,
                cursor_end,
            } => {
                state.ime_pending.preedit =
                    Some((text.unwrap_or_default(), cursor_begin, cursor_end));
            }
            zwp_text_input_v3::Event::CommitString { text: Some(t) } => {
                state.ime_pending.commit = Some(t);
            }
            zwp_text_input_v3::Event::DeleteSurroundingText {
                before_length,
                after_length,
            } => {
                state.ime_pending.delete_surrounding = Some((before_length, after_length));
            }
            zwp_text_input_v3::Event::Done { .. } => {
                let pending = std::mem::take(&mut state.ime_pending);
                let Some(ref obj_id) = state.ime_surface else {
                    return;
                };
                let Some(surface_id) = state.surface_key_by_obj.get(obj_id).cloned() else {
                    return;
                };
                if let Some((before, after)) = pending.delete_surrounding {
                    state.pending_events.push(SystemEvent::ImeInput {
                        surface_id: surface_id.clone(),
                        ime: ImeEvent::DeleteSurrounding { before, after },
                    });
                }
                let had_commit = pending.commit.is_some();
                if let Some(text) = pending.commit {
                    state.pending_events.push(SystemEvent::ImeInput {
                        surface_id: surface_id.clone(),
                        ime: ImeEvent::Commit(text),
                    });
                }
                if let Some((text, cursor_begin, cursor_end)) = pending.preedit {
                    state.pending_events.push(SystemEvent::ImeInput {
                        surface_id,
                        ime: ImeEvent::Preedit {
                            text,
                            cursor_begin,
                            cursor_end,
                        },
                    });
                } else if !had_commit {
                    // Per zwp_text_input_v3 spec, omitted preedit_string before done clears preedit.
                    state.pending_events.push(SystemEvent::ImeInput {
                        surface_id,
                        ime: ImeEvent::Preedit {
                            text: String::new(),
                            cursor_begin: 0,
                            cursor_end: 0,
                        },
                    });
                }
            }
            _ => {}
        }
    }
}

impl ProvidesRegistryState for UiState {
    fn registry(&mut self) -> &mut RegistryState {
        &mut self.registry_state
    }
    registry_handlers![OutputState, SeatState];
}

delegate_compositor!(UiState);
delegate_output!(UiState);
delegate_shm!(UiState);
delegate_seat!(UiState);
delegate_keyboard!(UiState);
delegate_pointer!(UiState);
delegate_layer!(UiState);
delegate_registry!(UiState);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn animation_clock_paces_60_to_144hz_clamps_33ms_and_stops_cleanly() {
        let mut clock = AnimationClock::default();
        let dt_first_144 = clock.tick("island:main", 1000, 144_000);
        assert!((dt_first_144 - (1.0 / 144.0)).abs() < 0.001);

        let dt_next = clock.tick("island:main", 1007, 144_000);
        assert!((dt_next - 0.007).abs() < 0.0005);

        let dt_clamped = clock.tick("island:main", 1500, 60_000);
        assert_eq!(dt_clamped, SPRING_MAX_DT_SECS);

        // u32 wraparound handling
        clock.tick("wrap", u32::MAX - 5, 60_000);
        let dt_wrap = clock.tick("wrap", 10, 60_000);
        assert!((dt_wrap - 0.016).abs() < 0.001);

        clock.stop("island:main");
        clock.stop("wrap");
        assert_eq!(clock.active_count(), 0);
    }
}
