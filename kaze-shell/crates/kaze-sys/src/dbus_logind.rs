use zbus::{Connection, Proxy};

const LOGIND_DEST: &str = "org.freedesktop.login1";
const LOGIND_PATH: &str = "/org/freedesktop/login1";
const LOGIND_IFACE: &str = "org.freedesktop.login1.Manager";

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
