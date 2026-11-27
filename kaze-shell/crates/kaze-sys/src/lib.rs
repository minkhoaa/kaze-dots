#![deny(clippy::unwrap_used)]

pub mod backlight;
mod dbus_mpris;
mod dbus_net;
mod dbus_notify;
mod dbus_upower;
pub mod pulse_native;

use calloop::channel::Sender as CalloopSender;
use kaze_core::SystemEvent;
use std::thread::{self, JoinHandle};
use tokio::sync::mpsc;

#[derive(Debug, Clone)]
pub enum SysCommand {
    AudioStepVolume(i32),
    AudioToggleMute,
    AudioToggleMicMute,
    BacklightStep(i32),
    MediaCommand(String),
    NotifyClosed { id: u32, reason: u32 },
    NotifyActionInvoked { id: u32, action_key: String },
    Shutdown,
}

/// Handle to the single background `tokio` `current_thread` runtime driving all
/// D-Bus (NetworkManager, UPower, MPRIS) and native `pipewire-pulse` audio events.
pub struct SysHandle {
    cmd_tx: mpsc::UnboundedSender<SysCommand>,
    join: Option<JoinHandle<()>>,
}

impl SysHandle {
    pub fn spawn(event_tx: CalloopSender<SystemEvent>) -> Result<Self, String> {
        let (cmd_tx, cmd_rx) = mpsc::unbounded_channel();
        let join = thread::Builder::new()
            .name("kaze-sys".to_string())
            .spawn(move || {
                run_sys_thread(event_tx, cmd_rx);
            })
            .map_err(|e| format!("failed spawning kaze-sys thread: {e}"))?;
        Ok(Self {
            cmd_tx,
            join: Some(join),
        })
    }

    pub fn send(&self, cmd: SysCommand) {
        let _ = self.cmd_tx.send(cmd);
    }
}

impl Drop for SysHandle {
    fn drop(&mut self) {
        let _ = self.cmd_tx.send(SysCommand::Shutdown);
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
    }
}

fn run_sys_thread(
    event_tx: CalloopSender<SystemEvent>,
    mut cmd_rx: mpsc::UnboundedReceiver<SysCommand>,
) {
    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_io()
        .enable_time()
        .build()
    {
        Ok(rt) => rt,
        Err(err) => {
            eprintln!("kaze-sys: failed building current_thread tokio runtime: {err}");
            return;
        }
    };

    rt.block_on(async move {
        let (audio_cmd_tx, audio_cmd_rx) = mpsc::unbounded_channel();
        let (media_cmd_tx, media_cmd_rx) = mpsc::unbounded_channel();
        let (notify_sig_tx, notify_sig_rx) = mpsc::unbounded_channel();

        let audio_task = tokio::spawn(pulse_native::run_audio_task(event_tx.clone(), audio_cmd_rx));
        let net_task = tokio::spawn(dbus_net::run_network_task(event_tx.clone()));
        let upower_task = tokio::spawn(dbus_upower::run_upower_task(event_tx.clone()));
        let mpris_task = tokio::spawn(dbus_mpris::run_mpris_task(event_tx.clone(), media_cmd_rx));
        let notify_task = tokio::spawn(dbus_notify::run_notify_task(
            event_tx.clone(),
            notify_sig_rx,
        ));

        while let Some(cmd) = cmd_rx.recv().await {
            match cmd {
                SysCommand::AudioStepVolume(delta) => {
                    let _ = audio_cmd_tx.send(pulse_native::AudioCmd::StepVolume(delta));
                }
                SysCommand::AudioToggleMute => {
                    let _ = audio_cmd_tx.send(pulse_native::AudioCmd::ToggleMute);
                }
                SysCommand::AudioToggleMicMute => {
                    let _ = audio_cmd_tx.send(pulse_native::AudioCmd::ToggleMicMute);
                }
                SysCommand::BacklightStep(delta) => {
                    if let Some(state) = backlight::step_backlight(delta) {
                        let _ = event_tx.send(SystemEvent::BacklightChanged {
                            state,
                            trigger_osd: true,
                        });
                    }
                }
                SysCommand::MediaCommand(action) => {
                    let _ = media_cmd_tx.send(action);
                }
                SysCommand::NotifyClosed { id, reason } => {
                    let _ = notify_sig_tx.send(dbus_notify::NotifySignal::Closed { id, reason });
                }
                SysCommand::NotifyActionInvoked { id, action_key } => {
                    let _ = notify_sig_tx
                        .send(dbus_notify::NotifySignal::ActionInvoked { id, action_key });
                }
                SysCommand::Shutdown => break,
            }
        }

        audio_task.abort();
        net_task.abort();
        upower_task.abort();
        mpris_task.abort();
        notify_task.abort();
    });
}
