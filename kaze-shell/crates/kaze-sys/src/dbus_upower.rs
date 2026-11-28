use calloop::channel::Sender as CalloopSender;
use futures_util::StreamExt;
use kaze_core::{BatteryDeviceDetail, BatteryState, SystemEvent};
use std::fs;
use std::path::Path;
use zbus::fdo::DBusProxy;
use zbus::zvariant::OwnedObjectPath;
use zbus::{Connection, Proxy};

const UPOWER_DEST: &str = "org.freedesktop.UPower";
const UPOWER_PATH: &str = "/org/freedesktop/UPower";
const UPOWER_IFACE: &str = "org.freedesktop.UPower";
const DISPLAY_DEV_PATH: &str = "/org/freedesktop/UPower/devices/DisplayDevice";
const DEVICE_IFACE: &str = "org.freedesktop.UPower.Device";

/// Event-driven UPower multi-battery, AC, health, charge-limit & Bluetooth peripheral observer.
pub async fn run_upower_task(conn: Connection, event_tx: CalloopSender<SystemEvent>) {
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

fn read_sysfs_charge_threshold(native_path: &str) -> Option<u8> {
    if native_path.is_empty() {
        return None;
    }
    let bat_dir = Path::new("/sys/class/power_supply").join(native_path);
    for file in ["charge_control_end_threshold", "charge_stop_threshold"] {
        if let Ok(raw) = fs::read_to_string(bat_dir.join(file)) {
            if let Ok(v) = raw.trim().parse::<u8>() {
                return Some(v.min(100));
            }
        }
    }
    None
}

async fn query_battery(conn: &Connection) -> Option<BatteryState> {
    let mut ac_online = false;
    let mut devices = Vec::new();
    let mut peripherals = Vec::new();

    if let Ok(upower) = Proxy::new(conn, UPOWER_DEST, UPOWER_PATH, UPOWER_IFACE).await {
        if let Ok(paths) = upower.call::<_, _, Vec<OwnedObjectPath>>("EnumerateDevices", &()).await {
            for obj_path in paths {
                let Ok(d) = Proxy::new(conn, UPOWER_DEST, obj_path.as_str(), DEVICE_IFACE).await else {
                    continue;
                };
                let dev_type: u32 = d.get_property("Type").await.unwrap_or(0);
                if dev_type == 1 {
                    // LinePower
                    if d.get_property::<bool>("Online").await.unwrap_or(false) {
                        ac_online = true;
                    }
                    continue;
                }
                let is_present: bool = d.get_property("IsPresent").await.unwrap_or(false);
                if !is_present {
                    continue;
                }
                let pct = d.get_property::<f64>("Percentage").await.unwrap_or(0.0).round().clamp(0.0, 100.0) as u8;
                let st_u32: u32 = d.get_property("State").await.unwrap_or(0);
                let charging = matches!(st_u32, 1 | 4 | 5);
                let model: String = d.get_property("Model").await.unwrap_or_default();
                let native: String = d.get_property("NativePath").await.unwrap_or_default();
                let name = if !model.trim().is_empty() {
                    model
                } else if !native.trim().is_empty() {
                    native.clone()
                } else {
                    obj_path.as_str().rsplit('/').next().unwrap_or("device").to_string()
                };

                if dev_type == 2 {
                    let cap_f: f64 = d.get_property("Capacity").await.unwrap_or(0.0);
                    let capacity_pct = if cap_f > 0.0 {
                        Some(cap_f.round().clamp(0.0, 100.0) as u8)
                    } else {
                        None
                    };
                    let charge_limit_pct = read_sysfs_charge_threshold(&native);
                    devices.push(BatteryDeviceDetail {
                        name,
                        kind: "battery".into(),
                        percentage: pct,
                        charging,
                        capacity_pct,
                        charge_limit_pct,
                    });
                } else if matches!(dev_type, 5 | 6 | 7 | 8 | 12 | 17 | 19) {
                    let kind = match dev_type {
                        5 => "mouse",
                        6 => "keyboard",
                        7 => "pda",
                        8 => "phone",
                        12 => "headset",
                        17 => "headphones",
                        19 => "gaming-input",
                        _ => "peripheral",
                    };
                    peripherals.push(BatteryDeviceDetail {
                        name,
                        kind: kind.into(),
                        percentage: pct,
                        charging,
                        capacity_pct: None,
                        charge_limit_pct: None,
                    });
                }
            }
        }
    }

    let dev = Proxy::new(conn, UPOWER_DEST, DISPLAY_DEV_PATH, DEVICE_IFACE)
        .await
        .ok()?;
    let is_present: bool = dev.get_property("IsPresent").await.ok()?;
    let dev_type: u32 = dev.get_property("Type").await.ok()?;
    if !is_present || dev_type != 2 {
        return Some(BatteryState {
            present: false,
            percentage: 0,
            charging: false,
            low: false,
            ac_online: true,
            health_pct: None,
            charge_limit_pct: None,
            devices,
            peripherals,
        });
    }
    let pct_f: f64 = dev.get_property("Percentage").await.unwrap_or(0.0);
    let state: u32 = dev.get_property("State").await.unwrap_or(0);
    let charging = matches!(state, 1 | 4 | 5);
    let percentage = pct_f.round().clamp(0.0, 100.0) as u8;
    let low = !charging && percentage <= 15;
    let health_pct = devices.first().and_then(|b| b.capacity_pct);
    let charge_limit_pct = devices.first().and_then(|b| b.charge_limit_pct);

    Some(BatteryState {
        present: true,
        percentage,
        charging,
        low,
        ac_online: ac_online || charging,
        health_pct,
        charge_limit_pct,
        devices,
        peripherals,
    })
}
