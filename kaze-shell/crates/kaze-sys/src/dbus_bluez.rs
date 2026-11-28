use calloop::channel::Sender as CalloopSender;
use futures_util::StreamExt;
use kaze_core::{BluetoothState, SystemEvent};
use std::collections::HashMap;
use tokio::sync::mpsc;
use zbus::fdo::DBusProxy;
use zbus::zvariant::{OwnedObjectPath, OwnedValue, Value};
use zbus::{Connection, MatchRule, MessageStream, Proxy};

const BLUEZ_DEST: &str = "org.bluez";
const ADAPTER_IFACE: &str = "org.bluez.Adapter1";
const DEVICE_IFACE: &str = "org.bluez.Device1";
const OBJ_MGR_IFACE: &str = "org.freedesktop.DBus.ObjectManager";

type ManagedObjects = HashMap<OwnedObjectPath, HashMap<String, HashMap<String, OwnedValue>>>;

/// Event-driven BlueZ observer & controller on the System Bus (0 polling).
/// Gracefully reports `available = false` on machines/VMs without Bluetooth hardware.
pub async fn run_bluez_task(
    conn: Connection,
    event_tx: CalloopSender<SystemEvent>,
    mut cmd_rx: mpsc::UnboundedReceiver<()>,
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
            toggle = cmd_rx.recv() => {
                if toggle.is_none() {
                    break;
                }
                if let Some((cur, adapter_path)) = query_bluez(&conn).await {
                    if let Ok(adapter) = Proxy::new(&conn, BLUEZ_DEST, adapter_path.as_str(), ADAPTER_IFACE).await {
                        let _ = adapter.set_property("Powered", !cur.powered).await;
                    }
                    let st = query_bluez(&conn).await.map(|(s, _)| s).unwrap_or(BluetoothState {
                        powered: !cur.powered,
                        ..cur
                    });
                    if st != last {
                        let _ = event_tx.send(SystemEvent::BluetoothChanged(st.clone()));
                        last = st;
                    }
                }
            }
        }
    }
}

async fn query_bluez(conn: &Connection) -> Option<(BluetoothState, String)> {
    let mgr = Proxy::new(conn, BLUEZ_DEST, "/", OBJ_MGR_IFACE)
        .await
        .ok()?;
    let objects: ManagedObjects = mgr.call("GetManagedObjects", &()).await.ok()?;

    let mut adapter_path: Option<String> = None;
    let mut powered = false;
    let mut connected_device = String::new();

    for (path, ifaces) in &objects {
        if let Some(props) = ifaces.get(ADAPTER_IFACE) {
            if adapter_path.is_none() {
                adapter_path = Some(path.as_str().to_string());
                powered = props
                    .get("Powered")
                    .and_then(|v| match &**v {
                        Value::Bool(b) => Some(*b),
                        _ => None,
                    })
                    .unwrap_or(false);
            }
        }
        if connected_device.is_empty() {
            if let Some(props) = ifaces.get(DEVICE_IFACE) {
                let is_conn = props
                    .get("Connected")
                    .and_then(|v| match &**v {
                        Value::Bool(b) => Some(*b),
                        _ => None,
                    })
                    .unwrap_or(false);
                if is_conn {
                    if let Some(name) = props.get("Alias").or_else(|| props.get("Name")) {
                        if let Value::Str(s) = &**name {
                            connected_device = s.to_string();
                        }
                    }
                }
            }
        }
    }

    let path = adapter_path?;
    Some((
        BluetoothState {
            available: true,
            powered,
            connected_device,
            ..BluetoothState::default()
        },
        path,
    ))
}
