#![deny(clippy::unwrap_used)]

pub mod render;

use kaze_core::{
    Anchor, DirtyFlags, ImeEvent, KeyEvent as CoreKeyEvent, KeyModifiers, KeyboardMode, Layer,
    OutputInfo, PointerButton, SurfaceSpec, SystemEvent,
};
use render::Renderer;
use smithay_client_toolkit::compositor::{CompositorHandler, CompositorState};
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
use wayland_protocols::wp::text_input::zv3::client::zwp_text_input_manager_v3::ZwpTextInputManagerV3;
use wayland_protocols::wp::text_input::zv3::client::zwp_text_input_v3::{
    self, ContentHint, ContentPurpose, ZwpTextInputV3,
};

const BTN_LEFT: u32 = 0x110;
const BTN_RIGHT: u32 = 0x111;
const BTN_MIDDLE: u32 = 0x112;

struct TrackedOutput {
    wl_output: wl_output::WlOutput,
    info: Option<OutputInfo>,
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

pub struct UiState {
    registry_state: RegistryState,
    seat_state: SeatState,
    output_state: OutputState,
    compositor_state: CompositorState,
    shm: Shm,
    layer_shell: LayerShell,
    text_input_manager: Option<ZwpTextInputManagerV3>,
    text_input: Option<ZwpTextInputV3>,
    ime_surface: Option<ObjectId>,
    ime_pending: PendingIme,
    qh: QueueHandle<Self>,
    pointer: Option<wl_pointer::WlPointer>,
    pointer_surface: Option<ObjectId>,
    pointer_pos: (f64, f64),
    keyboard: Option<wl_keyboard::WlKeyboard>,
    keyboard_surface: Option<ObjectId>,
    modifiers: KeyModifiers,
    outputs_by_obj: HashMap<ObjectId, TrackedOutput>,
    output_obj_by_name: HashMap<String, ObjectId>,
    surfaces: HashMap<String, ManagedSurface>,
    surface_key_by_obj: HashMap<ObjectId, String>,
    renderer: Renderer,
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

        let state = Self {
            registry_state: RegistryState::new(&globals),
            seat_state: SeatState::new(&globals, &qh),
            output_state: OutputState::new(&globals, &qh),
            compositor_state,
            shm,
            layer_shell,
            text_input_manager,
            text_input: None,
            ime_surface: None,
            ime_pending: PendingIme::default(),
            qh,
            pointer: None,
            pointer_surface: None,
            pointer_pos: (0.0, 0.0),
            keyboard: None,
            keyboard_surface: None,
            modifiers: KeyModifiers::default(),
            outputs_by_obj: HashMap::new(),
            output_obj_by_name: HashMap::new(),
            surfaces: HashMap::new(),
            surface_key_by_obj: HashMap::new(),
            renderer: Renderer::new(font_hint),
            pending_events: Vec::new(),
        };

        Ok((conn, event_queue, state))
    }

    pub fn set_font(&mut self, font_hint: &str) {
        self.renderer.reload_font_if_needed(font_hint);
    }

    pub fn drain_events(&mut self) -> Vec<SystemEvent> {
        std::mem::take(&mut self.pending_events)
    }

    pub fn surface_count(&self) -> usize {
        self.surfaces.len()
    }

    pub fn active_namespaces(&self) -> Vec<String> {
        let mut names: Vec<String> = self
            .surfaces
            .values()
            .map(|s| s.spec.namespace.clone())
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
            if let Some(existing) = self.surfaces.get_mut(&spec.id) {
                let geom_changed = !existing.spec.geometry_eq(&spec);
                let content_changed = existing.spec != spec;
                let force_redraw = dirty.intersects(
                    DirtyFlags::BAR
                        | DirtyFlags::ISLAND
                        | DirtyFlags::OSD
                        | DirtyFlags::NOTIFY
                        | DirtyFlags::LAUNCHER
                        | DirtyFlags::THEME,
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
                    apply_layer_geometry(&existing.layer, &spec);
                    existing.spec = spec;
                    existing.dirty = true;
                    existing.layer.commit();
                } else if content_changed || force_redraw {
                    existing.spec = spec;
                    existing.dirty = true;
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
        }
    }

    fn remove_surfaces_for_output(&mut self, output_name: &str) {
        let matching: Vec<String> = self
            .surfaces
            .iter()
            .filter(|(_, s)| s.spec.output.as_deref() == Some(output_name))
            .map(|(id, _)| id.clone())
            .collect();
        for id in matching {
            self.remove_surface(&id);
        }
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

    fn extract_output_info(&self, output: &wl_output::WlOutput) -> Option<OutputInfo> {
        let info = self.output_state.info(output)?;
        let name = info.name.clone()?;
        let scale = info.scale_factor.max(1);
        let (width, height) = if let Some((w, h)) = info.logical_size {
            (w.max(1), h.max(1))
        } else if let Some(mode) = info
            .modes
            .iter()
            .find(|m| m.current)
            .or_else(|| info.modes.first())
        {
            (
                (mode.dimensions.0 / scale).max(1),
                (mode.dimensions.1 / scale).max(1),
            )
        } else {
            (1920, 1080)
        };
        Some(OutputInfo {
            name,
            width,
            height,
            scale,
        })
    }

    fn surface_accepts_keyboard(&self, obj_id: &ObjectId) -> bool {
        self.surface_key_by_obj
            .get(obj_id)
            .and_then(|k| self.surfaces.get(k))
            .is_some_and(|s| s.spec.keyboard_interactivity != KeyboardMode::None)
    }

    fn enable_ime(&self) {
        if let Some(ref ti) = self.text_input {
            ti.enable();
            ti.set_content_type(ContentHint::None, ContentPurpose::Normal);
            ti.commit();
        }
    }

    fn disable_ime(&self) {
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
        _time: u32,
    ) {
        let obj_id = surface.id();
        if let Some(id) = self.surface_key_by_obj.get(&obj_id).cloned() {
            let should_redraw = if let Some(managed) = self.surfaces.get_mut(&id) {
                managed.frame_in_flight = false;
                managed.configured && managed.dirty
            } else {
                false
            };
            if should_redraw {
                self.draw_surface(&id);
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
        let info = self.extract_output_info(&output);
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
        let Some(new_info) = self.extract_output_info(&output) else {
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
        } else {
            self.outputs_by_obj.insert(
                obj_id,
                TrackedOutput {
                    wl_output: output,
                    info: Some(new_info.clone()),
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
        if let Some(id) = self.surface_key_by_obj.get(&obj_id).cloned() {
            self.remove_surface(&id);
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

    fn new_seat(&mut self, _conn: &Connection, qh: &QueueHandle<Self>, seat: wl_seat::WlSeat) {
        if self.text_input.is_none() {
            if let Some(ref mgr) = self.text_input_manager {
                self.text_input = Some(mgr.get_text_input(&seat, qh, ()));
            }
        }
    }

    fn new_capability(
        &mut self,
        _conn: &Connection,
        qh: &QueueHandle<Self>,
        seat: wl_seat::WlSeat,
        capability: Capability,
    ) {
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
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        _keyboard: &wl_keyboard::WlKeyboard,
        surface: &wl_surface::WlSurface,
        _serial: u32,
        _raw: &[u32],
        _keysyms: &[Keysym],
    ) {
        let obj_id = surface.id();
        self.keyboard_surface = Some(obj_id.clone());
        if self.surface_accepts_keyboard(&obj_id) {
            self.enable_ime();
        }
    }

    fn leave(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        _keyboard: &wl_keyboard::WlKeyboard,
        surface: &wl_surface::WlSurface,
        _serial: u32,
    ) {
        if self.keyboard_surface.as_ref() == Some(&surface.id()) {
            self.keyboard_surface = None;
            self.disable_ime();
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
        _layout: u32,
    ) {
        self.modifiers = KeyModifiers {
            ctrl: modifiers.ctrl,
            alt: modifiers.alt,
            shift: modifiers.shift,
            logo: modifiers.logo,
        };
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
                    self.pointer_surface = Some(event.surface.id());
                    self.pointer_pos = event.position;
                }
                PointerEventKind::Leave { .. } => {
                    if self.pointer_surface.as_ref() == Some(&event.surface.id()) {
                        self.pointer_surface = None;
                    }
                }
                PointerEventKind::Motion { .. } => {
                    self.pointer_surface = Some(event.surface.id());
                    self.pointer_pos = event.position;
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
                                    self.pending_events.push(SystemEvent::PointerClick {
                                        surface_id: surface_id.clone(),
                                        target_id: target.id.clone(),
                                        button: btn,
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
                                    });
                                    break;
                                }
                            }
                        }
                    }
                }
                _ => {}
            }
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
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
        match event {
            zwp_text_input_v3::Event::Enter { surface } => {
                let obj_id = surface.id();
                state.ime_surface = Some(obj_id.clone());
                if state.surface_accepts_keyboard(&obj_id) {
                    state.enable_ime();
                }
            }
            zwp_text_input_v3::Event::Leave { surface } => {
                if state.ime_surface.as_ref() == Some(&surface.id()) {
                    state.ime_surface = None;
                    state.ime_pending = PendingIme::default();
                    state.disable_ime();
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
