use calloop::channel::Sender as CalloopSender;
use futures_util::StreamExt;
use kaze_core::{BatteryState, SystemEvent};
use zbus::fdo::DBusProxy;
use zbus::{Connection, Proxy};

const UPOWER_DEST: &str = "org.freedesktop.UPower";
const DISPLAY_DEV_PATH: &str = "/org/freedesktop/UPower/devices/DisplayDevice";
const DEVICE_IFACE: &str = "org.freedesktop.UPower.Device";

/// Event-driven UPower DisplayDevice observer on the System Bus (0 polling).
/// Automatically reports `present = false` on desktops/VMs without a battery.
pub async fn run_upower_task(event_tx: CalloopSender<SystemEvent>) {
    let Ok(conn) = Connection::system().await else {
        return;
    };

    let mut last = BatteryState::default();
    if let Some(st) = query_battery(&conn).await {
        if st != last {
            let _ = event_tx.send(SystemEvent::BatteryChanged(st.clone()));
            last = st;
        }
    }

    let Ok(proxy) = Proxy::new(&conn, UPOWER_DEST, DISPLAY_DEV_PATH, DEVICE_IFACE).await else {
        return;
    };
    let mut prop_stream = proxy.receive_property_changed::<f64>("Percentage").await;
    let mut state_stream = proxy.receive_property_changed::<u32>("State").await;
    let mut present_stream = proxy.receive_property_changed::<bool>("IsPresent").await;

    let mut owner_stream = match DBusProxy::new(&conn).await {
        Ok(dbus) => dbus.receive_name_owner_changed().await.ok(),
        Err(_) => None,
    };

    loop {
        let changed = tokio::select! {
            ev = prop_stream.next() => ev.is_some(),
            ev = state_stream.next() => ev.is_some(),
            ev = present_stream.next() => ev.is_some(),
            owner = async {
                match owner_stream.as_mut() {
                    Some(s) => s.next().await,
                    None => std::future::pending().await,
                }
            } => {
                match owner {
                    Some(sig) => sig.args().is_ok_and(|a| a.name().as_str() == UPOWER_DEST),
                    None => false,
                }
            }
        };
        if !changed {
            continue;
        }
        let st = query_battery(&conn).await.unwrap_or_default();
        if st != last {
            let _ = event_tx.send(SystemEvent::BatteryChanged(st.clone()));
            last = st;
        }
    }
}

async fn query_battery(conn: &Connection) -> Option<BatteryState> {
    let dev = Proxy::new(conn, UPOWER_DEST, DISPLAY_DEV_PATH, DEVICE_IFACE)
        .await
        .ok()?;
    let is_present: bool = dev.get_property("IsPresent").await.ok()?;
    let dev_type: u32 = dev.get_property("Type").await.ok()?;
    // UPower DeviceType::Battery == 2
    if !is_present || dev_type != 2 {
        return Some(BatteryState::default());
    }
    let pct_f: f64 = dev.get_property("Percentage").await.unwrap_or(0.0);
    let state: u32 = dev.get_property("State").await.unwrap_or(0);
    // UPower DeviceState: 1 = Charging, 4 = FullyCharged, 5 = PendingCharge
    let charging = matches!(state, 1 | 4 | 5);
    let percentage = pct_f.round().clamp(0.0, 100.0) as u8;
    let low = !charging && percentage <= 15;

    Some(BatteryState {
        present: true,
        percentage,
        charging,
        low,
    })
}
