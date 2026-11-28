#![deny(clippy::unwrap_used)]

pub mod backlight;
pub mod calendar;
pub mod dbus_accounts;
mod dbus_bluez;
pub mod dbus_input;
mod dbus_logind;
mod dbus_mpris;
mod dbus_net;
mod dbus_notify;
mod dbus_polkit;
mod dbus_power;
pub mod dbus_secrets;
pub mod dbus_sni;
mod dbus_upower;
pub mod ddc;
pub mod hooks;
pub mod pipewire_privacy;
pub mod pulse_native;
pub mod screentime;
pub mod sysmon;
pub mod weather;

use calloop::channel::Sender as CalloopSender;
use kaze_core::{BrightnessConfig, CalendarConfig, MasterKey, SystemEvent, WeatherConfig};
use std::os::fd::OwnedFd;
use std::path::PathBuf;
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::Duration;
use tokio::io::unix::AsyncFd;
use tokio::sync::{mpsc, oneshot};

#[derive(Debug)]
pub enum SysCommand {
    AudioStepVolume(i32),
    AudioSetVolume(u8),
    AudioToggleMute,
    AudioToggleMicMute,
    AudioSetDefaultSink(String),
    AudioSetDefaultSource(String),
    AudioSetStreamVolume {
        index: u32,
        pct: u8,
    },
    AudioSetStreamMute {
        index: u32,
        muted: bool,
    },
    AudioSetSpectrumSubscribers {
        count: usize,
        fps: u32,
    },
    BacklightStep(i32),
    BacklightSet(u8),
    DdcSetBrightness {
        monitor: String,
        pct: u8,
        cfg: BrightnessConfig,
    },
    SetPowerProfile(String),
    HyprScreencastUpdate(bool),
    ReleaseSleepInhibitor,
    PolkitSubmitPassword {
        cookie: String,
        user: String,
        password: zeroize::Zeroizing<String>,
    },
    PolkitCancel {
        cookie: String,
    },
    MediaCommand(String),
    WifiToggle,
    NetworkRequestScan,
    WifiConnect {
        ssid: String,
        password: String,
    },
    WifiDisconnect,
    WifiForget(String),
    VpnToggle(String),
    BluetoothToggle,
    BluetoothSetDiscovery(bool),
    BluetoothPair(String),
    BluetoothTrust {
        path: String,
        trusted: bool,
    },
    BluetoothConnect(String),
    BluetoothDisconnect(String),
    BluetoothRemove(String),
    ConfigureWeather {
        cfg: WeatherConfig,
        offline_mode: bool,
    },
    WeatherRefresh,
    ConfigureCalendar {
        cfg: CalendarConfig,
        offline_mode: bool,
    },
    CalendarSyncNow,
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
    ReadClipboardPipe {
        mime: String,
        fd: OwnedFd,
        max_bytes: usize,
        source_is_self: bool,
        paste_surface_id: Option<String>,
    },
    WriteClipboardFd {
        fd: OwnedFd,
        bytes: Arc<[u8]>,
    },
    SetSysmonSubscribers(usize),
    RunWidgetExec {
        instance_id: String,
        command: String,
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
        let (power_cmd_tx, power_cmd_rx) = mpsc::unbounded_channel();
        let (ddc_cmd_tx, ddc_cmd_rx) = mpsc::unbounded_channel();
        let (privacy_tx, privacy_rx) = mpsc::unbounded_channel();
        let (sleep_rel_tx, sleep_rel_rx) = mpsc::unbounded_channel();
        let (polkit_cmd_tx, polkit_cmd_rx) = mpsc::unbounded_channel();
        let (sysmon_cmd_tx, sysmon_cmd_rx) = mpsc::unbounded_channel();
        let (weather_cmd_tx, weather_cmd_rx) = mpsc::unbounded_channel();
        let (cal_cmd_tx, cal_cmd_rx) = mpsc::unbounded_channel();

        // Share ONE System Bus and ONE Session Bus connection across all observers
        // (2 sockets total instead of 6; avoids spawning parallel zbus/tokio handshake threads).
        let sys_conn = zbus::Connection::system().await.ok();
        let sess_conn = zbus::Connection::session().await.ok();

        let audio_task = tokio::spawn(pulse_native::run_audio_task(
            event_tx.clone(),
            privacy_tx.clone(),
            audio_cmd_rx,
        ));
        let logind_task = sys_conn.clone().map(|c| {
            tokio::spawn(dbus_logind::run_logind_task(
                c,
                event_tx.clone(),
                sleep_rel_rx,
            ))
        });
        let privacy_task = tokio::spawn(pipewire_privacy::run_privacy_task(
            event_tx.clone(),
            privacy_rx,
        ));
        let ddc_task = tokio::spawn(ddc::run_ddc_task(ddc_cmd_rx));
        let power_task = sys_conn.clone().map(|c| {
            tokio::spawn(dbus_power::run_power_profiles_task(
                c,
                event_tx.clone(),
                power_cmd_rx,
            ))
        });
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
        let polkit_task = tokio::spawn(dbus_polkit::run_polkit_task(
            sys_conn.clone(),
            event_tx.clone(),
            polkit_cmd_rx,
        ));
        let input_task = sess_conn
            .clone()
            .map(|c| tokio::spawn(dbus_input::run_input_method_task(c, event_tx.clone())));
        let sysmon_task = tokio::spawn(sysmon::run_sysmon_task(event_tx.clone(), sysmon_cmd_rx));
        let weather_task =
            tokio::spawn(weather::run_weather_task(event_tx.clone(), weather_cmd_rx));
        let cal_cache_path = calendar::default_calendar_cache_path().ok();
        let calendar_task = tokio::spawn(calendar::run_calendar_task(
            event_tx.clone(),
            cal_cmd_rx,
            cal_cache_path,
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
                SysCommand::AudioSetDefaultSink(name) => {
                    let _ = audio_cmd_tx.send(pulse_native::AudioCmd::SetDefaultSink(name));
                }
                SysCommand::AudioSetDefaultSource(name) => {
                    let _ = audio_cmd_tx.send(pulse_native::AudioCmd::SetDefaultSource(name));
                }
                SysCommand::AudioSetStreamVolume { index, pct } => {
                    let _ =
                        audio_cmd_tx.send(pulse_native::AudioCmd::SetStreamVolume { index, pct });
                }
                SysCommand::AudioSetStreamMute { index, muted } => {
                    let _ =
                        audio_cmd_tx.send(pulse_native::AudioCmd::SetStreamMute { index, muted });
                }
                SysCommand::AudioSetSpectrumSubscribers { count, fps } => {
                    let _ = audio_cmd_tx
                        .send(pulse_native::AudioCmd::SetSpectrumSubscribers { count, fps });
                }
                SysCommand::BacklightStep(delta) => {
                    if let Some(state) =
                        backlight::step_backlight_async(sys_conn.as_ref(), delta).await
                    {
                        let _ = event_tx.send(SystemEvent::BacklightChanged {
                            state,
                            trigger_osd: true,
                        });
                    }
                }
                SysCommand::BacklightSet(pct) => {
                    if let Some(state) =
                        backlight::set_backlight_async(sys_conn.as_ref(), pct).await
                    {
                        let _ = event_tx.send(SystemEvent::BacklightChanged {
                            state,
                            trigger_osd: false,
                        });
                    }
                }
                SysCommand::DdcSetBrightness { monitor, pct, cfg } => {
                    let _ = ddc_cmd_tx.send(ddc::DdcRequest { monitor, pct, cfg });
                }
                SysCommand::SetPowerProfile(prof) => {
                    let _ = power_cmd_tx.send(prof);
                }
                SysCommand::HyprScreencastUpdate(active) => {
                    let _ =
                        privacy_tx.send(pipewire_privacy::PrivacyUpdate::HyprScreencast(active));
                }
                SysCommand::ReleaseSleepInhibitor => {
                    let _ = sleep_rel_tx.send(());
                }
                SysCommand::PolkitSubmitPassword {
                    cookie,
                    user,
                    password,
                } => {
                    let _ = polkit_cmd_tx.send(dbus_polkit::PolkitCmd::SubmitPassword {
                        cookie,
                        user,
                        password,
                    });
                }
                SysCommand::PolkitCancel { cookie } => {
                    let _ = polkit_cmd_tx.send(dbus_polkit::PolkitCmd::Cancel { cookie });
                }
                SysCommand::MediaCommand(action) => {
                    let _ = media_cmd_tx.send(action);
                }
                SysCommand::WifiToggle => {
                    let _ = net_cmd_tx.send(dbus_net::NetCmd::ToggleWifi);
                }
                SysCommand::NetworkRequestScan => {
                    let _ = net_cmd_tx.send(dbus_net::NetCmd::RequestScan);
                }
                SysCommand::WifiConnect { ssid, password } => {
                    let _ = net_cmd_tx.send(dbus_net::NetCmd::ConnectWifi { ssid, password });
                }
                SysCommand::WifiDisconnect => {
                    let _ = net_cmd_tx.send(dbus_net::NetCmd::DisconnectWifi);
                }
                SysCommand::WifiForget(ssid) => {
                    let _ = net_cmd_tx.send(dbus_net::NetCmd::ForgetWifi(ssid));
                }
                SysCommand::VpnToggle(uuid) => {
                    let _ = net_cmd_tx.send(dbus_net::NetCmd::ToggleVpn(uuid));
                }
                SysCommand::BluetoothToggle => {
                    let _ = bluez_cmd_tx.send(dbus_bluez::BluezCmd::TogglePower);
                }
                SysCommand::BluetoothSetDiscovery(active) => {
                    let _ = bluez_cmd_tx.send(dbus_bluez::BluezCmd::SetDiscovery(active));
                }
                SysCommand::BluetoothPair(path) => {
                    let _ = bluez_cmd_tx.send(dbus_bluez::BluezCmd::Pair(path));
                }
                SysCommand::BluetoothTrust { path, trusted } => {
                    let _ = bluez_cmd_tx.send(dbus_bluez::BluezCmd::Trust { path, trusted });
                }
                SysCommand::BluetoothConnect(path) => {
                    let _ = bluez_cmd_tx.send(dbus_bluez::BluezCmd::Connect(path));
                }
                SysCommand::BluetoothDisconnect(path) => {
                    let _ = bluez_cmd_tx.send(dbus_bluez::BluezCmd::Disconnect(path));
                }
                SysCommand::BluetoothRemove(path) => {
                    let _ = bluez_cmd_tx.send(dbus_bluez::BluezCmd::Remove(path));
                }
                SysCommand::ConfigureWeather { cfg, offline_mode } => {
                    let _ =
                        weather_cmd_tx.send(weather::WeatherCmd::Configure { cfg, offline_mode });
                }
                SysCommand::WeatherRefresh => {
                    let _ = weather_cmd_tx.send(weather::WeatherCmd::RefreshNow);
                }
                SysCommand::ConfigureCalendar { cfg, offline_mode } => {
                    let tok = if cfg.google_oauth_client_id.trim().is_empty() {
                        None
                    } else {
                        dbus_secrets::read_named_secret(
                            sess_conn.as_ref(),
                            "kaze-google-oauth-token",
                        )
                        .await
                        .map(|z| z.to_string())
                    };
                    let _ = cal_cmd_tx.send(calendar::CalendarCmd::Configure {
                        cfg,
                        offline_mode,
                        oauth_token: tok,
                    });
                }
                SysCommand::CalendarSyncNow => {
                    let _ = cal_cmd_tx.send(calendar::CalendarCmd::SyncNow);
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
                        let res =
                            dbus_secrets::resolve_master_key(sess.as_ref(), &fallback_path).await;
                        let _ = reply.send(res);
                    });
                }
                SysCommand::ReadClipboardPipe {
                    mime,
                    fd,
                    max_bytes,
                    source_is_self,
                    paste_surface_id,
                } => {
                    let tx = event_tx.clone();
                    tokio::spawn(async move {
                        if let Some(bytes) = read_nonblocking_pipe_bounded(fd, max_bytes).await {
                            if let Some(surface_id) = paste_surface_id {
                                let text = String::from_utf8_lossy(&bytes).into_owned();
                                let _ =
                                    tx.send(SystemEvent::ClipboardTextPasted { surface_id, text });
                            } else {
                                let _ = tx.send(SystemEvent::ClipboardOfferCaptured {
                                    mime,
                                    bytes,
                                    source_is_self,
                                });
                            }
                        }
                    });
                }
                SysCommand::WriteClipboardFd { fd, bytes } => {
                    tokio::spawn(async move {
                        write_nonblocking_pipe(fd, &bytes).await;
                    });
                }
                SysCommand::SetSysmonSubscribers(count) => {
                    let _ = sysmon_cmd_tx.send(count);
                }
                SysCommand::RunWidgetExec {
                    instance_id,
                    command,
                } => {
                    let tx = event_tx.clone();
                    tokio::spawn(async move {
                        let res = tokio::time::timeout(
                            Duration::from_secs(5),
                            tokio::process::Command::new("sh")
                                .arg("-c")
                                .arg(&command)
                                .output(),
                        )
                        .await;
                        if let Ok(Ok(out)) = res {
                            let text = String::from_utf8_lossy(&out.stdout).trim().to_string();
                            let _ = tx.send(SystemEvent::WidgetExecOutput {
                                instance_id,
                                output: text,
                            });
                        }
                    });
                }
                SysCommand::Shutdown => break,
            }
        }

        calendar_task.abort();
        weather_task.abort();
        sysmon_task.abort();
        if let Some(t) = input_task {
            t.abort();
        }
        accounts_task.abort();
        polkit_task.abort();
        if let Some(t) = logind_task {
            t.abort();
        }
        privacy_task.abort();
        ddc_task.abort();
        if let Some(t) = power_task {
            t.abort();
        }
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

async fn read_nonblocking_pipe_bounded(fd: OwnedFd, max_bytes: usize) -> Option<Vec<u8>> {
    use std::io::Read;
    use std::os::fd::AsRawFd;

    let raw = fd.as_raw_fd();
    // SAFETY: set O_NONBLOCK cleanly in case caller passed a blocking fd.
    unsafe {
        let flags = libc::fcntl(raw, libc::F_GETFL);
        if flags >= 0 {
            let _ = libc::fcntl(raw, libc::F_SETFL, flags | libc::O_NONBLOCK);
        }
    }
    let file = std::fs::File::from(fd);
    // SAFETY: `file` is owned exclusively by `async_fd` until dropped.
    let async_fd = unsafe { AsyncFd::register(file) }.ok()?;
    let mut out = Vec::new();
    let mut buf = [0u8; 8192];

    let read_fut = async {
        loop {
            let mut guard = async_fd.readable().await.ok()?;
            match guard.try_io(|inner| inner.get_ref().read(&mut buf)) {
                Ok(Ok(0)) => return Some(out),
                Ok(Ok(n)) => {
                    if out.len().saturating_add(n) > max_bytes {
                        // Oversized payload (e.g. 50 MiB): abort early and reclaim memory immediately.
                        return None;
                    }
                    out.extend_from_slice(&buf[..n]);
                }
                Ok(Err(_)) => return None,
                Err(_would_block) => continue,
            }
        }
    };

    tokio::time::timeout(Duration::from_millis(1200), read_fut)
        .await
        .ok()
        .flatten()
}

async fn write_nonblocking_pipe(fd: OwnedFd, bytes: &[u8]) {
    use std::io::Write;
    use std::os::fd::AsRawFd;

    let raw = fd.as_raw_fd();
    // SAFETY: set O_NONBLOCK so slow/closed readers never block the single tokio thread.
    unsafe {
        let flags = libc::fcntl(raw, libc::F_GETFL);
        if flags >= 0 {
            let _ = libc::fcntl(raw, libc::F_SETFL, flags | libc::O_NONBLOCK);
        }
    }
    let file = std::fs::File::from(fd);
    // SAFETY: `file` is owned exclusively by `async_fd` until dropped.
    let Ok(async_fd) = (unsafe { AsyncFd::register(file) }) else {
        return;
    };
    let mut written = 0usize;
    let _ = tokio::time::timeout(Duration::from_millis(2000), async {
        while written < bytes.len() {
            let Ok(mut guard) = async_fd.writable().await else {
                break;
            };
            match guard.try_io(|inner| inner.get_ref().write(&bytes[written..])) {
                Ok(Ok(0)) | Ok(Err(_)) => break,
                Ok(Ok(n)) => written += n,
                Err(_would_block) => continue,
            }
        }
    })
    .await;
}
