use crate::UiState;
use kaze_core::SystemEvent;
use smithay_client_toolkit::reexports::client::globals::GlobalList;
use smithay_client_toolkit::reexports::client::protocol::{wl_output::WlOutput, wl_seat::WlSeat};
use smithay_client_toolkit::reexports::client::{Connection, Dispatch, Proxy, QueueHandle};
use std::collections::HashMap;
use wayland_protocols::ext::idle_notify::v1::client::{
    ext_idle_notification_v1::{self, ExtIdleNotificationV1},
    ext_idle_notifier_v1::ExtIdleNotifierV1,
};
use wayland_protocols_wlr::output_power_management::v1::client::{
    zwlr_output_power_manager_v1::ZwlrOutputPowerManagerV1,
    zwlr_output_power_v1::{self, Mode as OutputPowerMode, ZwlrOutputPowerV1},
};

#[derive(Default)]
pub struct IdlePowerState {
    idle_notifier: Option<ExtIdleNotifierV1>,
    notifications: Vec<ExtIdleNotificationV1>,
    pending_stages: Option<Vec<(String, u64)>>,
    output_power_mgr: Option<ZwlrOutputPowerManagerV1>,
    output_powers: HashMap<String, ZwlrOutputPowerV1>,
}

impl IdlePowerState {
    pub fn bind_globals(globals: &GlobalList, qh: &QueueHandle<UiState>) -> Self {
        Self {
            idle_notifier: globals.bind::<ExtIdleNotifierV1, _, _>(qh, 1..=2, ()).ok(),
            notifications: Vec::new(),
            pending_stages: None,
            output_power_mgr: globals
                .bind::<ZwlrOutputPowerManagerV1, _, _>(qh, 1..=1, ())
                .ok(),
            output_powers: HashMap::new(),
        }
    }

    pub fn has_idle_notify(&self) -> bool {
        self.idle_notifier.is_some()
    }

    pub fn has_output_power(&self) -> bool {
        self.output_power_mgr.is_some()
    }

    pub fn set_pending_stages(&mut self, stages: &[(String, u64)]) {
        self.pending_stages = Some(stages.to_vec());
    }

    pub fn on_seat(&mut self, seat: &WlSeat, qh: &QueueHandle<UiState>) {
        if self.notifications.is_empty() {
            if let Some(stages) = self.pending_stages.clone() {
                self.configure_timeouts(&stages, seat, qh);
            }
        }
    }

    pub fn configure_timeouts(
        &mut self,
        stages: &[(String, u64)],
        seat: &WlSeat,
        qh: &QueueHandle<UiState>,
    ) -> bool {
        self.pending_stages = Some(stages.to_vec());
        for old in self.notifications.drain(..) {
            old.destroy();
        }
        let Some(ref notifier) = self.idle_notifier else {
            return false;
        };
        for (id, timeout_ms) in stages {
            let ms = (*timeout_ms).clamp(1000, u64::from(u32::MAX)) as u32;
            let notif = notifier.get_idle_notification(ms, seat, qh, id.clone());
            self.notifications.push(notif);
        }
        true
    }

    pub fn set_dpms<'a>(
        &mut self,
        on: bool,
        outputs: impl Iterator<Item = (&'a String, &'a WlOutput)>,
        qh: &QueueHandle<UiState>,
    ) -> bool {
        let Some(ref mgr) = self.output_power_mgr else {
            return false;
        };
        let mode = if on {
            OutputPowerMode::On
        } else {
            OutputPowerMode::Off
        };
        for (name, wl_out) in outputs {
            if name == "kaze-share" {
                continue;
            }
            let power = self
                .output_powers
                .entry(name.clone())
                .or_insert_with(|| mgr.get_output_power(wl_out, qh, name.clone()));
            power.set_mode(mode);
        }
        true
    }

    pub fn remove_output(&mut self, name: &str) {
        if let Some(p) = self.output_powers.remove(name) {
            p.destroy();
        }
    }
}

impl Dispatch<ExtIdleNotifierV1, ()> for UiState {
    fn event(
        _state: &mut Self,
        _proxy: &ExtIdleNotifierV1,
        _event: <ExtIdleNotifierV1 as Proxy>::Event,
        _data: &(),
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<ExtIdleNotificationV1, String> for UiState {
    fn event(
        state: &mut Self,
        _proxy: &ExtIdleNotificationV1,
        event: ext_idle_notification_v1::Event,
        stage_id: &String,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
        match event {
            ext_idle_notification_v1::Event::Idled => {
                state.pending_events.push(SystemEvent::IdleTimeout {
                    id: stage_id.clone(),
                });
            }
            ext_idle_notification_v1::Event::Resumed => {
                state.pending_events.push(SystemEvent::IdleResumed {
                    id: stage_id.clone(),
                });
            }
            _ => {}
        }
    }
}

impl Dispatch<ZwlrOutputPowerManagerV1, ()> for UiState {
    fn event(
        _state: &mut Self,
        _proxy: &ZwlrOutputPowerManagerV1,
        _event: <ZwlrOutputPowerManagerV1 as Proxy>::Event,
        _data: &(),
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<ZwlrOutputPowerV1, String> for UiState {
    fn event(
        state: &mut Self,
        proxy: &ZwlrOutputPowerV1,
        event: zwlr_output_power_v1::Event,
        output_name: &String,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
        if matches!(event, zwlr_output_power_v1::Event::Failed) {
            if let Some(p) = state.idle_power.output_powers.remove(output_name) {
                if p.id() == proxy.id() {
                    p.destroy();
                }
            }
        }
    }
}
