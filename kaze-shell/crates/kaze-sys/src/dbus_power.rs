use calloop::channel::Sender as CalloopSender;
use futures_util::StreamExt;
use kaze_core::{PowerProfileState, SystemEvent};
use std::collections::HashMap;
use zbus::zvariant::OwnedValue;
use zbus::{Connection, Proxy};

const UPOWER_PP_DEST: &str = "org.freedesktop.UPower.PowerProfiles";
const UPOWER_PP_PATH: &str = "/org/freedesktop/UPower/PowerProfiles";
const UPOWER_PP_IFACE: &str = "org.freedesktop.UPower.PowerProfiles";

const HADESS_DEST: &str = "net.hadess.PowerProfiles";
const HADESS_PATH: &str = "/net/hadess/PowerProfiles";
const HADESS_IFACE: &str = "net.hadess.PowerProfiles";

async fn connect_power_profiles(conn: &Connection) -> Option<Proxy<'_>> {
    for (dest, path, iface) in [
        (UPOWER_PP_DEST, UPOWER_PP_PATH, UPOWER_PP_IFACE),
        (HADESS_DEST, HADESS_PATH, HADESS_IFACE),
    ] {
        if let Ok(proxy) = Proxy::new(conn, dest, path, iface).await {
            if proxy.get_property::<String>("ActiveProfile").await.is_ok() {
                return Some(proxy);
            }
        }
    }
    None
}

async fn read_power_profile_state(proxy: &Proxy<'_>) -> Option<PowerProfileState> {
    let active: String = proxy.get_property("ActiveProfile").await.ok()?;
    let degraded_reason: String = proxy
        .get_property("PerformanceDegraded")
        .await
        .unwrap_or_default();
    let profiles_raw: Vec<HashMap<String, OwnedValue>> =
        proxy.get_property("Profiles").await.unwrap_or_default();
    let available_profiles: Vec<String> = profiles_raw
        .into_iter()
        .filter_map(|m| {
            m.get("Profile")
                .and_then(|v| v.downcast_ref::<zbus::zvariant::Str<'_>>().ok())
                .map(|s| s.as_str().to_string())
        })
        .collect();
    Some(PowerProfileState {
        available: true,
        active,
        available_profiles,
        degraded_reason,
    })
}

pub async fn run_power_profiles_task(
    conn: Connection,
    event_tx: CalloopSender<SystemEvent>,
    mut cmd_rx: tokio::sync::mpsc::UnboundedReceiver<String>,
) {
    let Some(proxy) = connect_power_profiles(&conn).await else {
        // Degrade silently on VMs/systems without power-profiles-daemon (0 polling).
        while cmd_rx.recv().await.is_some() {}
        return;
    };

    let mut last = PowerProfileState::default();
    if let Some(st) = read_power_profile_state(&proxy).await {
        if st != last {
            let _ = event_tx.send(SystemEvent::PowerProfileChanged(st.clone()));
            last = st;
        }
    }

    let mut active_stream = proxy
        .receive_property_changed::<String>("ActiveProfile")
        .await;
    let mut degraded_stream = proxy
        .receive_property_changed::<String>("PerformanceDegraded")
        .await;

    loop {
        tokio::select! {
            ev = active_stream.next() => {
                if ev.is_none() {
                    break;
                }
            }
            ev = degraded_stream.next() => {
                if ev.is_none() {
                    break;
                }
            }
            maybe_prof = cmd_rx.recv() => {
                let Some(prof) = maybe_prof else { return; };
                if let Err(err) = proxy.set_property("ActiveProfile", prof.as_str()).await {
                    eprintln!("kaze-sys: SetActiveProfile({prof}) failed: {err}");
                }
            }
        }
        if let Some(st) = read_power_profile_state(&proxy).await {
            if st != last {
                let _ = event_tx.send(SystemEvent::PowerProfileChanged(st.clone()));
                last = st;
            }
        }
    }
}
