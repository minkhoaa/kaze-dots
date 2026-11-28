use zbus::zvariant::OwnedFd;
use zbus::{Connection, Proxy};

const LOGIND_DEST: &str = "org.freedesktop.login1";
const LOGIND_PATH: &str = "/org/freedesktop/login1";
const LOGIND_IFACE: &str = "org.freedesktop.login1.Manager";

/// Acquires a logind `idle` block inhibitor FD for Caffeine; dropping the returned `OwnedFd`
/// immediately releases the inhibitor (reflected live in `systemd-inhibit --list`).
pub async fn acquire_idle_inhibit(conn: &Connection) -> Option<OwnedFd> {
    let proxy = Proxy::new(conn, LOGIND_DEST, LOGIND_PATH, LOGIND_IFACE)
        .await
        .ok()?;
    match proxy
        .call::<_, _, OwnedFd>(
            "Inhibit",
            &("idle", "kaze-shell", "Caffeine active", "block"),
        )
        .await
    {
        Ok(fd) => Some(fd),
        Err(err) => {
            eprintln!("kaze-sys: logind Inhibit(idle) failed: {err}");
            None
        }
    }
}

/// Invokes a logind power action (`suspend`, `reboot`, `poweroff`) over the System Bus.
pub async fn run_power_action(conn: Connection, action: &str) {
    let method = match action {
        "suspend" => "Suspend",
        "reboot" => "Reboot",
        "poweroff" | "shutdown" => "PowerOff",
        _ => return,
    };
    let Ok(proxy) = Proxy::new(&conn, LOGIND_DEST, LOGIND_PATH, LOGIND_IFACE).await else {
        return;
    };
    if let Err(err) = proxy.call::<_, _, ()>(method, &(false,)).await {
        eprintln!("kaze-sys: logind {method} failed: {err}");
    }
}
