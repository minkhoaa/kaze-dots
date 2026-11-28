#![deny(clippy::unwrap_used)]

pub mod backlight;
pub mod dbus_accounts;
mod dbus_bluez;
mod dbus_logind;
mod dbus_mpris;
mod dbus_net;
mod dbus_notify;
pub mod dbus_secrets;
pub mod dbus_sni;
mod dbus_upower;
pub mod hooks;
pub mod pulse_native;

use calloop::channel::Sender as CalloopSender;
use kaze_core::{MasterKey, SystemEvent};
use std::path::PathBuf;
use std::thread::{self, JoinHandle};
use tokio::sync::{mpsc, oneshot};

#[derive(Debug)]
pub enum SysCommand {
    AudioStepVolume(i32),
    AudioSetVolume(u8),
    AudioToggleMute,
    AudioToggleMicMute,
    BacklightStep(i32),
    BacklightSet(u8),
    MediaCommand(String),
    WifiToggle,
    BluetoothToggle,
    SetCaffeineInhibit(bool),
    SystemPower(String),
    NotifyClosed {
        id: u32,
        reason: u32,
    },
    NotifyActionInvoked {
        id: u32,
        action_key: String,
    },
    TrayActivate {
        service: String,
        object_path: String,
        x: i32,
        y: i32,
        secondary: bool,
    },
    TrayOpenMenu {
        service: String,
        menu_path: String,
    },
    TrayMenuClick {
        service: String,
        menu_path: String,
        item_id: i32,
    },
    RunHook(hooks::HookRequest),
    ResolveMasterKey {
        fallback_path: PathBuf,
        reply: oneshot::Sender<Result<MasterKey, String>>,
    },
    Shutdown,
}

/// Handle to the single background `tokio` `current_thread` runtime driving all
/// D-Bus (NetworkManager, BlueZ, UPower, MPRIS, Notifications, SNI/DBusMenu, logind)
/// and native `pipewire-pulse` audio events.
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

    pub fn resolve_master_key(&self, fallback_path: PathBuf) -> Result<MasterKey, String> {
        let (tx, rx) = oneshot::channel();
        self.cmd_tx
            .send(SysCommand::ResolveMasterKey {
                fallback_path,
                reply: tx,
            })
            .map_err(|_| "kaze-sys channel closed".to_string())?;
        rx.blocking_recv()
            .map_err(|_| "kaze-sys master key resolution cancelled".to_string())?
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
        .max_blocking_threads(1)
        .thread_keep_alive(std::time::Duration::from_secs(1))
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
        let (net_cmd_tx, net_cmd_rx) = mpsc::unbounded_channel();
        let (bluez_cmd_tx, bluez_cmd_rx) = mpsc::unbounded_channel();
        let (tray_cmd_tx, tray_cmd_rx) = mpsc::unbounded_channel();

        // Share ONE System Bus and ONE Session Bus connection across all observers
        // (2 sockets total instead of 6; avoids spawning parallel zbus/tokio handshake threads).
        let sys_conn = zbus::Connection::system().await.ok();
        let sess_conn = zbus::Connection::session().await.ok();

        let audio_task = tokio::spawn(pulse_native::run_audio_task(event_tx.clone(), audio_cmd_rx));
        let net_task = sys_conn
            .clone()
            .map(|c| tokio::spawn(dbus_net::run_network_task(c, event_tx.clone(), net_cmd_rx)));
        let bluez_task = sys_conn.clone().map(|c| {
            tokio::spawn(dbus_bluez::run_bluez_task(
                c,
                event_tx.clone(),
                bluez_cmd_rx,
            ))
        });
        let upower_task = sys_conn
            .clone()
            .map(|c| tokio::spawn(dbus_upower::run_upower_task(c, event_tx.clone())));
        let mpris_task = sess_conn.clone().map(|c| {
            tokio::spawn(dbus_mpris::run_mpris_task(
                c,
                event_tx.clone(),
                media_cmd_rx,
            ))
        });
        let notify_task = tokio::spawn(dbus_notify::run_notify_task(
            sess_conn.clone(),
            event_tx.clone(),
            notify_sig_rx,
        ));
        let sni_task = sess_conn
            .clone()
            .map(|c| tokio::spawn(dbus_sni::run_sni_task(c, event_tx.clone(), tray_cmd_rx)));
        let accounts_task = tokio::spawn(dbus_accounts::run_accounts_task(
            sys_conn.clone(),
            event_tx.clone(),
        ));
        let mut caffeine_inhibit_fd: Option<zbus::zvariant::OwnedFd> = None;

        while let Some(cmd) = cmd_rx.recv().await {
            match cmd {
                SysCommand::AudioStepVolume(delta) => {
                    let _ = audio_cmd_tx.send(pulse_native::AudioCmd::StepVolume(delta));
                }
                SysCommand::AudioSetVolume(pct) => {
                    let _ = audio_cmd_tx.send(pulse_native::AudioCmd::SetVolume(pct));
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
                SysCommand::BacklightSet(pct) => {
                    if let Some(state) = backlight::set_backlight(pct) {
                        let _ = event_tx.send(SystemEvent::BacklightChanged {
                            state,
                            trigger_osd: false,
                        });
                    }
                }
                SysCommand::MediaCommand(action) => {
                    let _ = media_cmd_tx.send(action);
                }
                SysCommand::WifiToggle => {
                    let _ = net_cmd_tx.send(());
                }
                SysCommand::BluetoothToggle => {
                    let _ = bluez_cmd_tx.send(());
                }
                SysCommand::SetCaffeineInhibit(enabled) => {
                    if !enabled {
                        caffeine_inhibit_fd = None;
                    } else if caffeine_inhibit_fd.is_none() {
                        if let Some(ref c) = sys_conn {
                            caffeine_inhibit_fd = dbus_logind::acquire_idle_inhibit(c).await;
                        } else if let Ok(c) = zbus::Connection::system().await {
                            caffeine_inhibit_fd = dbus_logind::acquire_idle_inhibit(&c).await;
                        }
                    }
                }
                SysCommand::SystemPower(action) => {
                    let conn_opt = sys_conn.clone();
                    tokio::spawn(async move {
                        let conn = match conn_opt {
                            Some(c) => Some(c),
                            None => zbus::Connection::system().await.ok(),
                        };
                        if let Some(c) = conn {
                            dbus_logind::run_power_action(c, &action).await;
                        }
                    });
                }
                SysCommand::NotifyClosed { id, reason } => {
                    let _ = notify_sig_tx.send(dbus_notify::NotifySignal::Closed { id, reason });
                }
                SysCommand::NotifyActionInvoked { id, action_key } => {
                    let _ = notify_sig_tx
                        .send(dbus_notify::NotifySignal::ActionInvoked { id, action_key });
                }
                SysCommand::TrayActivate {
                    service,
                    object_path,
                    x,
                    y,
                    secondary,
                } => {
                    let _ = tray_cmd_tx.send(dbus_sni::TrayCmd::Activate {
                        service,
                        object_path,
                        x,
                        y,
                        secondary,
                    });
                }
                SysCommand::TrayOpenMenu { service, menu_path } => {
                    let _ = tray_cmd_tx.send(dbus_sni::TrayCmd::OpenMenu { service, menu_path });
                }
                SysCommand::TrayMenuClick {
                    service,
                    menu_path,
                    item_id,
                } => {
                    let _ = tray_cmd_tx.send(dbus_sni::TrayCmd::MenuClick {
                        service,
                        menu_path,
                        item_id,
                    });
                }
                SysCommand::RunHook(req) => {
                    tokio::spawn(hooks::run_hook(req));
                }
                SysCommand::ResolveMasterKey {
                    fallback_path,
                    reply,
                } => {
                    let sess = sess_conn.clone();
                    tokio::spawn(async move {
                        let res = dbus_secrets::resolve_master_key(sess.as_ref(), &fallback_path).await;
                        let _ = reply.send(res);
                    });
                }
                SysCommand::Shutdown => break,
            }
        }

        accounts_task.abort();

        audio_task.abort();
        if let Some(t) = net_task {
            t.abort();
        }
        if let Some(t) = bluez_task {
            t.abort();
        }
        if let Some(t) = upower_task {
            t.abort();
        }
        if let Some(t) = mpris_task {
            t.abort();
        }
        notify_task.abort();
        if let Some(t) = sni_task {
            t.abort();
        }
    });
}
