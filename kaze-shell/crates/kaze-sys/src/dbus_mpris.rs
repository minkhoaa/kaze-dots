use calloop::channel::Sender as CalloopSender;
use futures_util::StreamExt;
use kaze_core::{MediaPlayback, MediaState, SystemEvent};
use std::collections::HashMap;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::mpsc;
use zbus::fdo::DBusProxy;
use zbus::zvariant::{OwnedValue, Value};
use zbus::{Connection, MatchRule, MessageStream, Proxy};

const MPRIS_PREFIX: &str = "org.mpris.MediaPlayer2.";
const MPRIS_PATH: &str = "/org/mpris/MediaPlayer2";
const MPRIS_PLAYER_IFACE: &str = "org.mpris.MediaPlayer2.Player";

/// Event-driven MPRIS2 observer & controller on the Session Bus (0 polling, 0 portals).
pub async fn run_mpris_task(
    event_tx: CalloopSender<SystemEvent>,
    mut cmd_rx: mpsc::UnboundedReceiver<String>,
) {
    let Ok(conn) = Connection::session().await else {
        return;
    };

    let Ok(dbus) = DBusProxy::new(&conn).await else {
        return;
    };

    let mut active_player = find_active_player(&dbus, &conn).await;
    let mut last_state = MediaState::default();
    if let Some(ref player) = active_player {
        if let Some(st) = query_player(&conn, player).await {
            if st != last_state {
                let _ = event_tx.send(SystemEvent::MediaChanged(st.clone()));
                last_state = st;
            }
        }
    }

    let Ok(mut owner_stream) = dbus.receive_name_owner_changed().await else {
        return;
    };

    let rule = MatchRule::builder()
        .msg_type(zbus::message::Type::Signal)
        .interface("org.freedesktop.DBus.Properties")
        .and_then(|b| b.member("PropertiesChanged"))
        .and_then(|b| b.path(MPRIS_PATH))
        .map(zbus::match_rule::Builder::build)
        .ok();
    let mut prop_stream = match rule {
        Some(r) => MessageStream::for_match_rule(r, &conn, Some(32)).await.ok(),
        None => None,
    };

    loop {
        tokio::select! {
            owner = owner_stream.next() => {
                let Some(ev) = owner else { break; };
                if let Ok(args) = ev.args() {
                    if args.name().as_str().starts_with(MPRIS_PREFIX) {
                        active_player = find_active_player(&dbus, &conn).await;
                        let st = match active_player.as_deref() {
                            Some(p) => query_player(&conn, p).await.unwrap_or_default(),
                            None => MediaState::default(),
                        };
                        if st != last_state {
                            let _ = event_tx.send(SystemEvent::MediaChanged(st.clone()));
                            last_state = st;
                        }
                    }
                }
            }
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
                active_player = find_active_player(&dbus, &conn).await;
                let st = match active_player.as_deref() {
                    Some(p) => query_player(&conn, p).await.unwrap_or_default(),
                    None => MediaState::default(),
                };
                if st != last_state {
                    let _ = event_tx.send(SystemEvent::MediaChanged(st.clone()));
                    last_state = st;
                }
            }
            cmd = cmd_rx.recv() => {
                let Some(action) = cmd else { break; };
                let target = match active_player.as_deref() {
                    Some(p) => Some(p.to_string()),
                    None => find_active_player(&dbus, &conn).await,
                };
                if let Some(player) = target {
                    let method = match action.as_str() {
                        "play-pause" => Some("PlayPause"),
                        "play" => Some("Play"),
                        "pause" => Some("Pause"),
                        "next" => Some("Next"),
                        "previous" | "prev" => Some("Previous"),
                        "stop" => Some("Stop"),
                        _ => None,
                    };
                    if let Some(m) = method {
                        if let Ok(proxy) = Proxy::new(&conn, player.as_str(), MPRIS_PATH, MPRIS_PLAYER_IFACE).await {
                            let _ = proxy.call_noreply(m, &()).await;
                        }
                    }
                }
            }
        }
    }
}

async fn find_active_player(dbus: &DBusProxy<'_>, conn: &Connection) -> Option<String> {
    let names = dbus.list_names().await.ok()?;
    let mut players: Vec<String> = names
        .into_iter()
        .map(|n| n.as_str().to_string())
        .filter(|n| n.starts_with(MPRIS_PREFIX))
        .collect();
    players.sort();

    // Prefer a player that is currently Playing; otherwise pick first registered player.
    let mut fallback: Option<String> = None;
    for p in players {
        if fallback.is_none() {
            fallback = Some(p.clone());
        }
        if let Some(st) = query_player(conn, &p).await {
            if st.status == MediaPlayback::Playing {
                return Some(p);
            }
        }
    }
    fallback
}

async fn query_player(conn: &Connection, dest: &str) -> Option<MediaState> {
    let proxy = Proxy::new(conn, dest, MPRIS_PATH, MPRIS_PLAYER_IFACE)
        .await
        .ok()?;
    let status_str: String = proxy.get_property("PlaybackStatus").await.ok()?;
    let status = match status_str.as_str() {
        "Playing" => MediaPlayback::Playing,
        "Paused" => MediaPlayback::Paused,
        _ => MediaPlayback::Stopped,
    };

    let mut title = String::new();
    let mut artist = String::new();
    let mut length_us = 0i64;
    if let Ok(meta) = proxy
        .get_property::<HashMap<String, OwnedValue>>("Metadata")
        .await
    {
        if let Some(v) = meta.get("xesam:title") {
            if let Ok(s) = <&str>::try_from(v) {
                title = s.to_string();
            }
        }
        if let Some(v) = meta.get("xesam:artist") {
            if let Ok(arr) = Vec::<String>::try_from(v.clone()) {
                artist = arr.join(", ");
            }
        }
        if let Some(v) = meta.get("mpris:length") {
            length_us = match &**v {
                Value::I64(n) => *n,
                Value::U64(n) => i64::try_from(*n).unwrap_or(0),
                Value::I32(n) => i64::from(*n),
                Value::U32(n) => i64::from(*n),
                _ => 0,
            };
        }
    }

    let position_us: i64 = proxy.get_property("Position").await.unwrap_or(0).max(0);
    let rate_f: f64 = proxy.get_property("Rate").await.unwrap_or(1.0);
    let rate_milli = if rate_f.is_finite() && rate_f > 0.0 {
        (rate_f * 1000.0).round().clamp(100.0, 4000.0) as i32
    } else {
        1000
    };
    let updated_at_epoch_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64;

    Some(MediaState {
        active: status != MediaPlayback::Stopped || !title.is_empty(),
        player: dest.strip_prefix(MPRIS_PREFIX).unwrap_or(dest).to_string(),
        title,
        artist,
        status,
        position_us,
        length_us,
        rate_milli,
        updated_at_epoch_ms,
    })
}
