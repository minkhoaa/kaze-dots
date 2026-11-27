use calloop::channel::Sender as CalloopSender;
use futures_util::StreamExt;
use kaze_core::{NetworkKind, NetworkState, SystemEvent};
use tokio::sync::mpsc;
use zbus::fdo::DBusProxy;
use zbus::zvariant::OwnedObjectPath;
use zbus::{Connection, Proxy};

const NM_DEST: &str = "org.freedesktop.NetworkManager";
const NM_PATH: &str = "/org/freedesktop/NetworkManager";
const NM_IFACE: &str = "org.freedesktop.NetworkManager";
const NM_ACTIVE_IFACE: &str = "org.freedesktop.NetworkManager.Connection.Active";
const NM_AP_IFACE: &str = "org.freedesktop.NetworkManager.AccessPoint";

/// Event-driven NetworkManager observer & Wi-Fi toggle controller on the System Bus (0 polling).
/// Treats absent NetworkManager cleanly as unavailable and only wakes on D-Bus signals.
pub async fn run_network_task(
    conn: Connection,
    event_tx: CalloopSender<SystemEvent>,
    mut cmd_rx: mpsc::UnboundedReceiver<()>,
) {
    let mut last = NetworkState::default();
    if let Some(st) = query_network_state(&conn).await {
        if st != last {
            let _ = event_tx.send(SystemEvent::NetworkChanged(st.clone()));
            last = st;
        }
    }

    let Ok(nm_proxy) = Proxy::new(&conn, NM_DEST, NM_PATH, NM_IFACE).await else {
        return;
    };
    let Ok(mut props_stream) = nm_proxy.receive_all_signals().await else {
        return;
    };

    let mut owner_stream = match DBusProxy::new(&conn).await {
        Ok(dbus) => dbus.receive_name_owner_changed().await.ok(),
        Err(_) => None,
    };

    loop {
        tokio::select! {
            sig = props_stream.next() => {
                if sig.is_none() {
                    break;
                }
                if let Some(st) = query_network_state(&conn).await {
                    if st != last {
                        let _ = event_tx.send(SystemEvent::NetworkChanged(st.clone()));
                        last = st;
                    }
                }
            }
            owner = async {
                match owner_stream.as_mut() {
                    Some(s) => s.next().await,
                    None => std::future::pending().await,
                }
            } => {
                let Some(ev) = owner else { break; };
                if let Ok(args) = ev.args() {
                    if args.name().as_str() == NM_DEST {
                        let st = query_network_state(&conn).await.unwrap_or_default();
                        if st != last {
                            let _ = event_tx.send(SystemEvent::NetworkChanged(st.clone()));
                            last = st;
                        }
                    }
                }
            }
            toggle = cmd_rx.recv() => {
                if toggle.is_none() {
                    break;
                }
                if let Ok(enabled) = nm_proxy.get_property::<bool>("WirelessEnabled").await {
                    let _ = nm_proxy.set_property("WirelessEnabled", !enabled).await;
                    if let Some(st) = query_network_state(&conn).await {
                        if st != last {
                            let _ = event_tx.send(SystemEvent::NetworkChanged(st.clone()));
                            last = st;
                        }
                    }
                }
            }
        }
    }
}

async fn query_network_state(conn: &Connection) -> Option<NetworkState> {
    let nm = Proxy::new(conn, NM_DEST, NM_PATH, NM_IFACE).await.ok()?;
    let nm_state: u32 = nm.get_property("State").await.ok()?;
    // NM_STATE_CONNECTED_LOCAL = 50, SITE = 60, GLOBAL = 70
    let connected = nm_state >= 50;
    let primary_type: String = nm
        .get_property("PrimaryConnectionType")
        .await
        .unwrap_or_default();

    let kind = if !connected {
        NetworkKind::Disconnected
    } else if primary_type.contains("wireless") || primary_type.contains("wifi") {
        NetworkKind::Wifi
    } else if !primary_type.is_empty() {
        NetworkKind::Ethernet
    } else {
        NetworkKind::Disconnected
    };

    let mut ssid = String::new();
    let mut strength = if connected { 100u8 } else { 0u8 };

    if kind == NetworkKind::Wifi {
        if let Ok(primary_path) = nm
            .get_property::<OwnedObjectPath>("PrimaryConnection")
            .await
        {
            if primary_path.as_str() != "/" {
                if let Ok(active_proxy) =
                    Proxy::new(conn, NM_DEST, primary_path.as_str(), NM_ACTIVE_IFACE).await
                {
                    if let Ok(ap_path) = active_proxy
                        .get_property::<OwnedObjectPath>("SpecificObject")
                        .await
                    {
                        if ap_path.as_str() != "/" {
                            if let Ok(ap_proxy) =
                                Proxy::new(conn, NM_DEST, ap_path.as_str(), NM_AP_IFACE).await
                            {
                                if let Ok(raw_ssid) = ap_proxy.get_property::<Vec<u8>>("Ssid").await
                                {
                                    ssid = String::from_utf8_lossy(&raw_ssid).into_owned();
                                }
                                if let Ok(s) = ap_proxy.get_property::<u8>("Strength").await {
                                    strength = s.min(100);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    Some(NetworkState {
        available: true,
        connected,
        kind,
        ssid,
        strength,
    })
}
