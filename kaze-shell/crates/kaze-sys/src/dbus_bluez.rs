use calloop::channel::Sender as CalloopSender;
use futures_util::StreamExt;
use kaze_core::{BluetoothDeviceInfo, BluetoothState, SystemEvent};
use std::collections::HashMap;
use tokio::sync::mpsc;
use zbus::fdo::DBusProxy;
use zbus::zvariant::{OwnedObjectPath, OwnedValue, Value};
use zbus::{Connection, MatchRule, MessageStream, Proxy};

const BLUEZ_DEST: &str = "org.bluez";
const ADAPTER_IFACE: &str = "org.bluez.Adapter1";
const DEVICE_IFACE: &str = "org.bluez.Device1";
const BATTERY_IFACE: &str = "org.bluez.Battery1";
const OBJ_MGR_IFACE: &str = "org.freedesktop.DBus.ObjectManager";

type ManagedObjects = HashMap<OwnedObjectPath, HashMap<String, HashMap<String, OwnedValue>>>;

#[derive(Debug, Clone)]
pub enum BluezCmd {
    TogglePower,
    SetDiscovery(bool),
    Pair(String),
    Trust { path: String, trusted: bool },
    Connect(String),
    Disconnect(String),
    Remove(String),
}

/// Event-driven BlueZ observer & controller on System Bus (0 polling).
/// Enforces idempotent `StopDiscovery` so background scanning is never left active.
pub async fn run_bluez_task(
    conn: Connection,
    event_tx: CalloopSender<SystemEvent>,
    mut cmd_rx: mpsc::UnboundedReceiver<BluezCmd>,
) {
    let mut last = BluetoothState::default();
    if let Some((st, _)) = query_bluez(&conn).await {
        if st != last {
            let _ = event_tx.send(SystemEvent::BluetoothChanged(st.clone()));
            last = st;
        }
    }

    let rule = MatchRule::builder()
        .msg_type(zbus::message::Type::Signal)
        .interface("org.freedesktop.DBus.Properties")
        .and_then(|b| b.member("PropertiesChanged"))
        .and_then(|b| b.path_namespace("/org/bluez"))
        .map(zbus::match_rule::Builder::build)
        .ok();
    let mut prop_stream = match rule {
        Some(r) => MessageStream::for_match_rule(r, &conn, Some(16)).await.ok(),
        None => None,
    };

    let mut owner_stream = match DBusProxy::new(&conn).await {
        Ok(dbus) => dbus.receive_name_owner_changed().await.ok(),
        Err(_) => None,
    };

    let mut we_started_discovery = false;

    loop {
        tokio::select! {
            msg = async {
                match prop_stream.as_mut() {
                    Some(s) => s.next().await,
                    None => std::future::pending().await,
                }
            } => {
                if msg.is_none() {
                    prop_stream = None;
                    continue;
                }
                let st = query_bluez(&conn).await.map(|(s, _)| s).unwrap_or_default();
                if st != last {
                    let _ = event_tx.send(SystemEvent::BluetoothChanged(st.clone()));
                    last = st;
                }
            }
            owner = async {
                match owner_stream.as_mut() {
                    Some(s) => s.next().await,
                    None => std::future::pending().await,
                }
            } => {
                let Some(sig) = owner else { break; };
                if sig.args().is_ok_and(|a| a.name().as_str() == BLUEZ_DEST) {
                    let st = query_bluez(&conn).await.map(|(s, _)| s).unwrap_or_default();
                    if st != last {
                        let _ = event_tx.send(SystemEvent::BluetoothChanged(st.clone()));
                        last = st;
                    }
                }
            }
            cmd = cmd_rx.recv() => {
                let Some(cmd) = cmd else {
                    break;
                };
                match cmd {
                    BluezCmd::TogglePower => {
                        if let Some((cur, adapter_path)) = query_bluez(&conn).await {
                            if let Ok(adapter) = Proxy::new(&conn, BLUEZ_DEST, adapter_path.as_str(), ADAPTER_IFACE).await {
                                let _ = adapter.set_property("Powered", !cur.powered).await;
                            }
                        }
                    }
                    BluezCmd::SetDiscovery(active) => {
                        if let Some((cur, adapter_path)) = query_bluez(&conn).await {
                            if let Ok(adapter) = Proxy::new(&conn, BLUEZ_DEST, adapter_path.as_str(), ADAPTER_IFACE).await {
                                if active && cur.powered && !cur.discovering {
                                    if adapter.call::<_, _, ()>("StartDiscovery", &()).await.is_ok() {
                                        we_started_discovery = true;
                                    }
                                } else if !active && (we_started_discovery || cur.discovering) {
                                    let _ = adapter.call::<_, _, ()>("StopDiscovery", &()).await;
                                    we_started_discovery = false;
                                }
                            }
                        } else {
                            we_started_discovery = false;
                        }
                    }
                    BluezCmd::Pair(path) => {
                        if let Ok(dev) = Proxy::new(&conn, BLUEZ_DEST, path.as_str(), DEVICE_IFACE).await {
                            let _: Result<(), _> = dev.call("Pair", &()).await;
                        }
                    }
                    BluezCmd::Trust { path, trusted } => {
                        if let Ok(dev) = Proxy::new(&conn, BLUEZ_DEST, path.as_str(), DEVICE_IFACE).await {
                            let _ = dev.set_property("Trusted", trusted).await;
                        }
                    }
                    BluezCmd::Connect(path) => {
                        if let Ok(dev) = Proxy::new(&conn, BLUEZ_DEST, path.as_str(), DEVICE_IFACE).await {
                            let _: Result<(), _> = dev.call("Connect", &()).await;
                        }
                    }
                    BluezCmd::Disconnect(path) => {
                        if let Ok(dev) = Proxy::new(&conn, BLUEZ_DEST, path.as_str(), DEVICE_IFACE).await {
                            let _: Result<(), _> = dev.call("Disconnect", &()).await;
                        }
                    }
                    BluezCmd::Remove(path) => {
                        if let Some((_, adapter_path)) = query_bluez(&conn).await {
                            if let (Ok(adapter), Ok(op)) = (
                                Proxy::new(&conn, BLUEZ_DEST, adapter_path.as_str(), ADAPTER_IFACE).await,
                                OwnedObjectPath::try_from(path),
                            ) {
                                let _: Result<(), _> = adapter.call("RemoveDevice", &(op,)).await;
                            }
                        }
                    }
                }
                let st = query_bluez(&conn).await.map(|(s, _)| s).unwrap_or_default();
                if st != last {
                    let _ = event_tx.send(SystemEvent::BluetoothChanged(st.clone()));
                    last = st;
                }
            }
        }
    }

    if we_started_discovery {
        if let Some((_, adapter_path)) = query_bluez(&conn).await {
            if let Ok(adapter) =
                Proxy::new(&conn, BLUEZ_DEST, adapter_path.as_str(), ADAPTER_IFACE).await
            {
                let _ = adapter.call::<_, _, ()>("StopDiscovery", &()).await;
            }
        }
    }
}

fn prop_bool(props: &HashMap<String, OwnedValue>, key: &str) -> bool {
    props
        .get(key)
        .and_then(|v| match &**v {
            Value::Bool(b) => Some(*b),
            _ => None,
        })
        .unwrap_or(false)
}

fn prop_str(props: &HashMap<String, OwnedValue>, key: &str) -> String {
    props
        .get(key)
        .and_then(|v| match &**v {
            Value::Str(s) => Some(s.to_string()),
            _ => None,
        })
        .unwrap_or_default()
}

async fn query_bluez(conn: &Connection) -> Option<(BluetoothState, String)> {
    let mgr = Proxy::new(conn, BLUEZ_DEST, "/", OBJ_MGR_IFACE)
        .await
        .ok()?;
    let objects: ManagedObjects = mgr.call("GetManagedObjects", &()).await.ok()?;

    let mut adapter_path: Option<String> = None;
    let mut powered = false;
    let mut discovering = false;
    let mut connected_device = String::new();
    let mut devices = Vec::new();

    for (path, ifaces) in &objects {
        if let Some(props) = ifaces.get(ADAPTER_IFACE) {
            if adapter_path.is_none() {
                adapter_path = Some(path.as_str().to_string());
                powered = prop_bool(props, "Powered");
                discovering = prop_bool(props, "Discovering");
            }
        }
        if let Some(props) = ifaces.get(DEVICE_IFACE) {
            let address = prop_str(props, "Address");
            let name = {
                let alias = prop_str(props, "Alias");
                if alias.is_empty() {
                    prop_str(props, "Name")
                } else {
                    alias
                }
            };
            let icon = prop_str(props, "Icon");
            let paired = prop_bool(props, "Paired");
            let trusted = prop_bool(props, "Trusted");
            let connected = prop_bool(props, "Connected");
            let battery_pct = ifaces.get(BATTERY_IFACE).and_then(|b| {
                b.get("Percentage").and_then(|v| match &**v {
                    Value::U8(p) => Some(*p),
                    _ => None,
                })
            });
            if connected && connected_device.is_empty() {
                connected_device = if name.is_empty() {
                    address.clone()
                } else {
                    name.clone()
                };
            }
            if !name.is_empty() || paired || connected {
                devices.push(BluetoothDeviceInfo {
                    path: path.as_str().to_string(),
                    address,
                    name,
                    icon,
                    paired,
                    trusted,
                    connected,
                    battery_pct,
                });
            }
        }
    }
    devices.sort_by(|a, b| {
        b.connected
            .cmp(&a.connected)
            .then_with(|| b.paired.cmp(&a.paired))
            .then_with(|| a.name.cmp(&b.name))
    });

    let path = adapter_path?;
    Some((
        BluetoothState {
            available: true,
            powered,
            discovering,
            connected_device,
            devices,
        },
        path,
    ))
}
