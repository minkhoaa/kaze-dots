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
const USER_IFACE: &str = "org.freedesktop.login1.User";

/// Resolves the active `(session_id, object_path)` for the current user, handling both
/// direct session processes (`GetSessionByPID`) and `systemd --user` services (`User.Display` / `ListSessions`).
pub async fn resolve_active_session(conn: &Connection) -> Option<(String, OwnedObjectPath)> {
    let mgr = Proxy::new(conn, LOGIND_DEST, LOGIND_PATH, LOGIND_IFACE)
        .await
        .ok()?;

    if let Ok(sess_path) = mgr
        .call::<_, _, OwnedObjectPath>("GetSessionByPID", &(std::process::id(),))
        .await
    {
        if let Ok(sess) = Proxy::new(conn, LOGIND_DEST, sess_path.as_str(), SESSION_IFACE).await {
            if let Ok(id) = sess.get_property::<String>("Id").await {
                if !id.is_empty() {
                    return Some((id, sess_path));
                }
            }
        }
    }

    // SAFETY: `geteuid` is always valid and thread-safe.
    let uid = unsafe { libc::geteuid() };
    if let Ok(user_path) = mgr.call::<_, _, OwnedObjectPath>("GetUser", &(uid,)).await {
        if let Ok(user_proxy) = Proxy::new(conn, LOGIND_DEST, user_path.as_str(), USER_IFACE).await
        {
            if let Ok((id, sess_path)) = user_proxy
                .get_property::<(String, OwnedObjectPath)>("Display")
                .await
            {
                if !id.is_empty() && sess_path.as_str() != "/" {
                    return Some((id, sess_path));
                }
            }
        }
    }

    for env_key in ["XDG_SESSION_ID", "KAZE_SESSION_ID"] {
        if let Ok(id) = std::env::var(env_key) {
            let trimmed = id.trim();
            if !trimmed.is_empty() {
                if let Ok(sess_path) = mgr
                    .call::<_, _, OwnedObjectPath>("GetSession", &(trimmed,))
                    .await
                {
                    return Some((trimmed.to_string(), sess_path));
                }
            }
        }
    }

    if let Ok(list) = mgr
        .call::<_, _, Vec<(String, u32, String, String, OwnedObjectPath)>>("ListSessions", &())
        .await
    {
        if let Some((id, _, _, _, path)) =
            list.into_iter().find(|(_, s_uid, _, _, _)| *s_uid == uid)
        {
            return Some((id, path));
        }
    }

    None
}

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

    let session_path = resolve_active_session(&conn).await.map(|(_, p)| p);
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
