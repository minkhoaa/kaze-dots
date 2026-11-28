use calloop::channel::Sender as CalloopSender;
use futures_util::StreamExt;
use kaze_core::{NetworkKind, NetworkState, SystemEvent, VpnInfo, WifiApInfo};
use std::collections::{HashMap, HashSet};
use tokio::sync::mpsc;
use zbus::fdo::DBusProxy;
use zbus::zvariant::{OwnedObjectPath, OwnedValue, Value};
use zbus::{Connection, Proxy};

const NM_DEST: &str = "org.freedesktop.NetworkManager";
const NM_PATH: &str = "/org/freedesktop/NetworkManager";
const NM_IFACE: &str = "org.freedesktop.NetworkManager";
const NM_DEVICE_IFACE: &str = "org.freedesktop.NetworkManager.Device";
const NM_WIRELESS_IFACE: &str = "org.freedesktop.NetworkManager.Device.Wireless";
const NM_ACTIVE_IFACE: &str = "org.freedesktop.NetworkManager.Connection.Active";
const NM_AP_IFACE: &str = "org.freedesktop.NetworkManager.AccessPoint";
const NM_SETTINGS_PATH: &str = "/org/freedesktop/NetworkManager/Settings";
const NM_SETTINGS_IFACE: &str = "org.freedesktop.NetworkManager.Settings";
const NM_CONN_IFACE: &str = "org.freedesktop.NetworkManager.Settings.Connection";

#[derive(Debug, Clone)]
pub enum NetCmd {
    ToggleWifi,
    RequestScan,
    ConnectWifi { ssid: String, password: String },
    DisconnectWifi,
    ForgetWifi(String),
    ToggleVpn(String),
}

/// Event-driven NetworkManager observer & Wi-Fi/VPN controller on System Bus (0 polling).
pub async fn run_network_task(
    conn: Connection,
    event_tx: CalloopSender<SystemEvent>,
    mut cmd_rx: mpsc::UnboundedReceiver<NetCmd>,
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
            cmd = cmd_rx.recv() => {
                let Some(cmd) = cmd else {
                    break;
                };
                handle_net_cmd(&conn, &nm_proxy, cmd).await;
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

async fn handle_net_cmd(conn: &Connection, nm_proxy: &Proxy<'_>, cmd: NetCmd) {
    match cmd {
        NetCmd::ToggleWifi => {
            if let Ok(enabled) = nm_proxy.get_property::<bool>("WirelessEnabled").await {
                let _ = nm_proxy.set_property("WirelessEnabled", !enabled).await;
            }
        }
        NetCmd::RequestScan => {
            if let Some(wdev) = find_wifi_device_path(conn, nm_proxy).await {
                if let Ok(wp) = Proxy::new(conn, NM_DEST, wdev.as_str(), NM_WIRELESS_IFACE).await {
                    let opts: HashMap<&str, Value<'_>> = HashMap::new();
                    let _: Result<(), _> = wp.call("RequestScan", &(opts,)).await;
                }
            }
        }
        NetCmd::DisconnectWifi => {
            if let Some(wdev) = find_wifi_device_path(conn, nm_proxy).await {
                if let Ok(dp) = Proxy::new(conn, NM_DEST, wdev.as_str(), NM_DEVICE_IFACE).await {
                    let _: Result<(), _> = dp.call("Disconnect", &()).await;
                }
            }
        }
        NetCmd::ConnectWifi { ssid, password } => {
            if let Some(wdev) = find_wifi_device_path(conn, nm_proxy).await {
                let Ok(wdev_path) = OwnedObjectPath::try_from(wdev) else {
                    return;
                };
                if let Some(saved_path) = find_saved_wifi_connection(conn, &ssid).await {
                    if let Ok(sp) = OwnedObjectPath::try_from("/") {
                        let _: Result<(OwnedObjectPath,), _> = nm_proxy
                            .call("ActivateConnection", &(saved_path, wdev_path, sp))
                            .await;
                        return;
                    }
                }
                let mut conn_sec: HashMap<&str, Value<'_>> = HashMap::new();
                conn_sec.insert("id", Value::from(ssid.as_str()));
                conn_sec.insert("type", Value::from("802-11-wireless"));
                let mut wifi_sec: HashMap<&str, Value<'_>> = HashMap::new();
                wifi_sec.insert("ssid", Value::from(ssid.as_bytes().to_vec()));
                wifi_sec.insert("mode", Value::from("infrastructure"));
                let mut root: HashMap<&str, HashMap<&str, Value<'_>>> = HashMap::new();
                root.insert("connection", conn_sec);
                root.insert("802-11-wireless", wifi_sec);
                if !password.is_empty() {
                    let mut wsec: HashMap<&str, Value<'_>> = HashMap::new();
                    wsec.insert("key-mgmt", Value::from("wpa-psk"));
                    wsec.insert("psk", Value::from(password.as_str()));
                    root.insert("802-11-wireless-security", wsec);
                }
                if let Ok(sp) = OwnedObjectPath::try_from("/") {
                    let _: Result<(OwnedObjectPath, OwnedObjectPath), _> = nm_proxy
                        .call("AddAndActivateConnection", &(root, wdev_path, sp))
                        .await;
                }
            }
        }
        NetCmd::ForgetWifi(ssid) => {
            if let Some(path) = find_saved_wifi_connection(conn, &ssid).await {
                if let Ok(cp) = Proxy::new(conn, NM_DEST, path.as_str(), NM_CONN_IFACE).await {
                    let _: Result<(), _> = cp.call("Delete", &()).await;
                }
            }
        }
        NetCmd::ToggleVpn(uuid) => {
            if let Ok(active_paths) = nm_proxy
                .get_property::<Vec<OwnedObjectPath>>("ActiveConnections")
                .await
            {
                for apath in active_paths {
                    if let Ok(ap) = Proxy::new(conn, NM_DEST, apath.as_str(), NM_ACTIVE_IFACE).await
                    {
                        if ap.get_property::<String>("Uuid").await.ok().as_deref() == Some(&uuid) {
                            let _: Result<(), _> =
                                nm_proxy.call("DeactivateConnection", &(apath,)).await;
                            return;
                        }
                    }
                }
            }
            if let Some(conn_path) = find_connection_by_uuid(conn, &uuid).await {
                if let (Ok(dev), Ok(sp)) = (
                    OwnedObjectPath::try_from("/"),
                    OwnedObjectPath::try_from("/"),
                ) {
                    let _: Result<(OwnedObjectPath,), _> = nm_proxy
                        .call("ActivateConnection", &(conn_path, dev, sp))
                        .await;
                }
            }
        }
    }
}

async fn find_wifi_device_path(conn: &Connection, nm: &Proxy<'_>) -> Option<String> {
    let devs: Vec<OwnedObjectPath> = nm.call("GetAllDevices", &()).await.ok()?;
    for d in devs {
        if let Ok(dp) = Proxy::new(conn, NM_DEST, d.as_str(), NM_DEVICE_IFACE).await {
            if dp.get_property::<u32>("DeviceType").await.ok() == Some(2) {
                return Some(d.to_string());
            }
        }
    }
    None
}

async fn find_saved_wifi_connection(
    conn: &Connection,
    target_ssid: &str,
) -> Option<OwnedObjectPath> {
    let sp = Proxy::new(conn, NM_DEST, NM_SETTINGS_PATH, NM_SETTINGS_IFACE)
        .await
        .ok()?;
    let paths: Vec<OwnedObjectPath> = sp.call("ListConnections", &()).await.ok()?;
    for p in paths {
        if let Ok(cp) = Proxy::new(conn, NM_DEST, p.as_str(), NM_CONN_IFACE).await {
            if let Ok(settings) = cp
                .call::<_, _, HashMap<String, HashMap<String, OwnedValue>>>("GetSettings", &())
                .await
            {
                if let Some(wifi) = settings.get("802-11-wireless") {
                    if let Some(raw) = wifi.get("ssid").and_then(|v| match &**v {
                        Value::Array(arr) => {
                            let bytes: Vec<u8> = arr
                                .iter()
                                .filter_map(|x| match x {
                                    Value::U8(b) => Some(*b),
                                    _ => None,
                                })
                                .collect();
                            Some(String::from_utf8_lossy(&bytes).into_owned())
                        }
                        _ => None,
                    }) {
                        if raw == target_ssid {
                            return Some(p);
                        }
                    }
                }
            }
        }
    }
    None
}

async fn find_connection_by_uuid(conn: &Connection, uuid: &str) -> Option<OwnedObjectPath> {
    let sp = Proxy::new(conn, NM_DEST, NM_SETTINGS_PATH, NM_SETTINGS_IFACE)
        .await
        .ok()?;
    let paths: Vec<OwnedObjectPath> = sp.call("ListConnections", &()).await.ok()?;
    for p in paths {
        if let Ok(cp) = Proxy::new(conn, NM_DEST, p.as_str(), NM_CONN_IFACE).await {
            if let Ok(settings) = cp
                .call::<_, _, HashMap<String, HashMap<String, OwnedValue>>>("GetSettings", &())
                .await
            {
                if settings
                    .get("connection")
                    .and_then(|c| c.get("uuid"))
                    .and_then(|v| match &**v {
                        Value::Str(s) => Some(s.as_str()),
                        _ => None,
                    })
                    == Some(uuid)
                {
                    return Some(p);
                }
            }
        }
    }
    None
}

async fn query_network_state(conn: &Connection) -> Option<NetworkState> {
    let nm = Proxy::new(conn, NM_DEST, NM_PATH, NM_IFACE).await.ok()?;
    let nm_state: u32 = nm.get_property("State").await.ok()?;
    let wifi_enabled: bool = nm.get_property("WirelessEnabled").await.unwrap_or(true);
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

    let mut saved_ssids = HashSet::new();
    let mut active_vpns = HashSet::new();
    if let Ok(active_paths) = nm
        .get_property::<Vec<OwnedObjectPath>>("ActiveConnections")
        .await
    {
        for apath in active_paths {
            if let Ok(ap) = Proxy::new(conn, NM_DEST, apath.as_str(), NM_ACTIVE_IFACE).await {
                if let Ok(uuid) = ap.get_property::<String>("Uuid").await {
                    active_vpns.insert(uuid);
                }
            }
        }
    }

    let mut vpns = Vec::new();
    if let Ok(sp) = Proxy::new(conn, NM_DEST, NM_SETTINGS_PATH, NM_SETTINGS_IFACE).await {
        if let Ok(paths) = sp
            .call::<_, _, Vec<OwnedObjectPath>>("ListConnections", &())
            .await
        {
            for p in paths {
                if let Ok(cp) = Proxy::new(conn, NM_DEST, p.as_str(), NM_CONN_IFACE).await {
                    if let Ok(settings) = cp
                        .call::<_, _, HashMap<String, HashMap<String, OwnedValue>>>(
                            "GetSettings",
                            &(),
                        )
                        .await
                    {
                        if let Some(csec) = settings.get("connection") {
                            let ctype = csec
                                .get("type")
                                .and_then(|v| match &**v {
                                    Value::Str(s) => Some(s.as_str()),
                                    _ => None,
                                })
                                .unwrap_or("");
                            if ctype == "vpn" || ctype == "wireguard" {
                                let uuid = csec
                                    .get("uuid")
                                    .and_then(|v| match &**v {
                                        Value::Str(s) => Some(s.to_string()),
                                        _ => None,
                                    })
                                    .unwrap_or_default();
                                let name = csec
                                    .get("id")
                                    .and_then(|v| match &**v {
                                        Value::Str(s) => Some(s.to_string()),
                                        _ => None,
                                    })
                                    .unwrap_or_else(|| uuid.clone());
                                let active = active_vpns.contains(&uuid);
                                vpns.push(VpnInfo {
                                    uuid,
                                    name,
                                    kind: ctype.to_string(),
                                    active,
                                });
                            }
                        }
                        if let Some(wifi) = settings.get("802-11-wireless") {
                            if let Some(Value::Array(arr)) = wifi.get("ssid").map(|v| &**v) {
                                let bytes: Vec<u8> = arr
                                    .iter()
                                    .filter_map(|x| match x {
                                        Value::U8(b) => Some(*b),
                                        _ => None,
                                    })
                                    .collect();
                                let s = String::from_utf8_lossy(&bytes).into_owned();
                                if !s.is_empty() {
                                    saved_ssids.insert(s);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    let mut aps_by_ssid: HashMap<String, WifiApInfo> = HashMap::new();
    if let Some(wdev) = find_wifi_device_path(conn, &nm).await {
        if let Ok(wp) = Proxy::new(conn, NM_DEST, wdev.as_str(), NM_WIRELESS_IFACE).await {
            if let Ok(ap_paths) = wp
                .call::<_, _, Vec<OwnedObjectPath>>("GetAllAccessPoints", &())
                .await
            {
                for ap_path in ap_paths.into_iter().take(32) {
                    if let Ok(ap) = Proxy::new(conn, NM_DEST, ap_path.as_str(), NM_AP_IFACE).await {
                        let raw_ssid = ap.get_property::<Vec<u8>>("Ssid").await.unwrap_or_default();
                        let ap_ssid = String::from_utf8_lossy(&raw_ssid).trim().to_string();
                        if ap_ssid.is_empty() {
                            continue;
                        }
                        let strg = ap
                            .get_property::<u8>("Strength")
                            .await
                            .unwrap_or(0)
                            .min(100);
                        let flags = ap.get_property::<u32>("Flags").await.unwrap_or(0);
                        let wpa_flags = ap.get_property::<u32>("WpaFlags").await.unwrap_or(0);
                        let rsn_flags = ap.get_property::<u32>("RsnFlags").await.unwrap_or(0);
                        let secured = (flags & 1 != 0) || wpa_flags != 0 || rsn_flags != 0;
                        let active = connected && kind == NetworkKind::Wifi && ap_ssid == ssid;
                        let saved = saved_ssids.contains(&ap_ssid);
                        aps_by_ssid
                            .entry(ap_ssid.clone())
                            .and_modify(|e| {
                                if strg > e.strength {
                                    e.strength = strg;
                                }
                                e.active |= active;
                            })
                            .or_insert(WifiApInfo {
                                ssid: ap_ssid,
                                strength: strg,
                                secured,
                                active,
                                saved,
                            });
                    }
                }
            }
        }
    }
    let mut access_points: Vec<WifiApInfo> = aps_by_ssid.into_values().collect();
    access_points.sort_by(|a, b| {
        b.active
            .cmp(&a.active)
            .then_with(|| b.strength.cmp(&a.strength))
    });
    access_points.truncate(16);

    Some(NetworkState {
        available: true,
        wifi_enabled,
        connected,
        kind,
        ssid,
        strength,
        access_points,
        vpns,
    })
}
