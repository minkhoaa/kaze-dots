use calloop::channel::Sender as CalloopSender;
use futures_util::StreamExt;
use kaze_core::{PowerCapabilities, SystemEvent};
use std::process::Command;
use tokio::sync::mpsc;
use zbus::zvariant::{OwnedFd, OwnedObjectPath};
use zbus::{Connection, Proxy};

const LOGIND_DEST: &str = "org.freedesktop.login1";
const LOGIND_PATH: &str = "/org/freedesktop/login1";
const LOGIND_IFACE: &str = "org.freedesktop.login1.Manager";
const SESSION_IFACE: &str = "org.freedesktop.login1.Session";

pub async fn acquire_idle_inhibit(conn: &Connection) -> Option<OwnedFd> {
    let proxy = Proxy::new(conn, LOGIND_DEST, LOGIND_PATH, LOGIND_IFACE)
        .await
        .ok()?;
    proxy
        .call::<_, _, OwnedFd>(
            "Inhibit",
            &("idle", "kaze-shell", "Caffeine active", "block"),
        )
        .await
        .ok()
}

pub async fn acquire_sleep_delay_inhibit(conn: &Connection) -> Option<OwnedFd> {
    let proxy = Proxy::new(conn, LOGIND_DEST, LOGIND_PATH, LOGIND_IFACE)
        .await
        .ok()?;
    proxy
        .call::<_, _, OwnedFd>(
            "Inhibit",
            &("sleep", "kaze-shell", "Lock screen before sleep", "delay"),
        )
        .await
        .ok()
}

pub async fn query_power_capabilities(conn: &Connection) -> PowerCapabilities {
    let uwsm_active = std::env::var_os("UWSM_FINALIZE_VARNAMES").is_some()
        || Command::new("uwsm")
            .args(["check", "is-active"])
            .output()
            .is_ok_and(|o| o.status.success());

    let Ok(proxy) = Proxy::new(conn, LOGIND_DEST, LOGIND_PATH, LOGIND_IFACE).await else {
        return PowerCapabilities {
            uwsm_active,
            ..PowerCapabilities::default()
        };
    };

    let check = |method: &'static str| {
        let p = proxy.clone();
        async move {
            p.call::<_, _, String>(method, &())
                .await
                .is_ok_and(|s| s == "yes" || s == "challenge")
        }
    };

    let can_suspend = check("CanSuspend").await;
    let can_hibernate = check("CanHibernate").await;
    let can_reboot = check("CanReboot").await;
    let can_poweroff = check("CanPowerOff").await;
    let can_reboot_to_uefi = check("CanRebootToFirmwareSetup").await;

    PowerCapabilities {
        can_suspend,
        can_hibernate,
        can_reboot,
        can_poweroff,
        can_reboot_to_uefi,
        uwsm_active,
    }
}

pub async fn run_logind_task(
    conn: Connection,
    event_tx: CalloopSender<SystemEvent>,
    mut release_rx: mpsc::UnboundedReceiver<()>,
) {
    let caps = query_power_capabilities(&conn).await;
    let _ = event_tx.send(SystemEvent::PowerCapabilitiesChanged(caps));

    let Ok(mgr) = Proxy::new(&conn, LOGIND_DEST, LOGIND_PATH, LOGIND_IFACE).await else {
        return;
    };

    let mut sleep_fd = acquire_sleep_delay_inhibit(&conn).await;
    let mut sleep_stream = mgr.receive_signal("PrepareForSleep").await.ok();

    let session_path = mgr
        .call::<_, _, OwnedObjectPath>("GetSessionByPID", &(std::process::id(),))
        .await
        .ok();
    let sess_proxy = match session_path.as_ref() {
        Some(path) => Proxy::new(&conn, LOGIND_DEST, path.as_str(), SESSION_IFACE)
            .await
            .ok(),
        None => None,
    };
    let mut lock_stream = match sess_proxy {
        Some(ref s) => s.receive_signal("Lock").await.ok(),
        None => None,
    };
    let mut unlock_stream = match sess_proxy {
        Some(ref s) => s.receive_signal("Unlock").await.ok(),
        None => None,
    };

    loop {
        tokio::select! {
            _ = release_rx.recv() => {
                sleep_fd = None;
            }
            ev = async {
                match sleep_stream.as_mut() {
                    Some(s) => s.next().await,
                    None => std::future::pending().await,
                }
            } => {
                if let Some(msg) = ev {
                    if let Ok((sleeping,)) = msg.body().deserialize::<(bool,)>() {
                        let _ = event_tx.send(SystemEvent::PrepareForSleep(sleeping));
                        if !sleeping && sleep_fd.is_none() {
                            sleep_fd = acquire_sleep_delay_inhibit(&conn).await;
                        }
                    }
                }
            }
            ev = async {
                match lock_stream.as_mut() {
                    Some(s) => s.next().await,
                    None => std::future::pending().await,
                }
            } => {
                if ev.is_some() {
                    let _ = event_tx.send(SystemEvent::SessionLockRequested);
                }
            }
            ev = async {
                match unlock_stream.as_mut() {
                    Some(s) => s.next().await,
                    None => std::future::pending().await,
                }
            } => {
                if ev.is_some() {
                    let _ = event_tx.send(SystemEvent::SessionUnlockRequested);
                }
            }
        }
    }
}

/// Invokes a logind power action (`suspend`, `hibernate`, `reboot`, `reboot-uefi`, `poweroff`).
pub async fn run_power_action(conn: Connection, action: &str) {
    let Ok(proxy) = Proxy::new(&conn, LOGIND_DEST, LOGIND_PATH, LOGIND_IFACE).await else {
        return;
    };
    if action == "reboot-uefi" {
        let _ = proxy
            .call::<_, _, ()>("SetRebootToFirmwareSetup", &(true,))
            .await;
    }
    let method = match action {
        "suspend" => "Suspend",
        "hibernate" => "Hibernate",
        "reboot" | "reboot-uefi" => "Reboot",
        "poweroff" | "shutdown" => "PowerOff",
        _ => return,
    };
    if let Err(err) = proxy.call::<_, _, ()>(method, &(false,)).await {
        eprintln!("kaze-sys: logind {method} failed: {err}");
    }
}
