use calloop::channel::Sender as CalloopSender;
use futures_util::StreamExt;
use kaze_core::{NotificationAction, NotificationItem, NotificationUrgency, SystemEvent};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::sync::mpsc;
use zbus::fdo::{DBusProxy, RequestNameFlags, RequestNameReply};
use zbus::object_server::SignalEmitter;
use zbus::zvariant::{OwnedValue, Value};
use zbus::Connection;

const BUS_NAME: &str = "org.freedesktop.Notifications";
const OBJ_PATH: &str = "/org/freedesktop/Notifications";

#[derive(Debug, Clone)]
pub enum NotifySignal {
    Closed { id: u32, reason: u32 },
    ActionInvoked { id: u32, action_key: String },
}

struct NotificationsService {
    event_tx: CalloopSender<SystemEvent>,
    next_id: AtomicU32,
}

impl NotificationsService {
    fn new(event_tx: CalloopSender<SystemEvent>) -> Self {
        Self {
            event_tx,
            next_id: AtomicU32::new(1),
        }
    }

    fn alloc_id(&self, replaces_id: u32) -> u32 {
        allocate_notification_id(&self.next_id, replaces_id)
    }
}

fn allocate_notification_id(counter: &AtomicU32, replaces_id: u32) -> u32 {
    if replaces_id > 0 {
        return replaces_id;
    }
    loop {
        let candidate = counter.fetch_add(1, Ordering::Relaxed);
        if candidate > 0 {
            return candidate;
        }
    }
}

fn extract_u8_hint(value: &Value<'_>) -> Option<u8> {
    match value {
        Value::U8(v) => Some(*v),
        Value::U16(v) => u8::try_from(*v).ok(),
        Value::I16(v) => u8::try_from(*v).ok(),
        Value::U32(v) => u8::try_from(*v).ok(),
        Value::I32(v) => u8::try_from(*v).ok(),
        Value::U64(v) => u8::try_from(*v).ok(),
        Value::I64(v) => u8::try_from(*v).ok(),
        _ => None,
    }
}

fn parse_urgency(hints: &HashMap<String, OwnedValue>) -> NotificationUrgency {
    let raw = hints.get("urgency").and_then(|v| extract_u8_hint(v));
    match raw {
        Some(0) => NotificationUrgency::Low,
        Some(2) => NotificationUrgency::Critical,
        _ => NotificationUrgency::Normal,
    }
}

fn parse_bool_hint(hints: &HashMap<String, OwnedValue>, key: &str) -> bool {
    hints
        .get(key)
        .and_then(|v| match &**v {
            Value::Bool(b) => Some(*b),
            _ => None,
        })
        .unwrap_or(false)
}

fn parse_sync_tag(hints: &HashMap<String, OwnedValue>) -> Option<String> {
    for key in ["x-canonical-private-synchronous", "synchronous"] {
        if let Some(val) = hints.get(key) {
            if let Value::Str(s) = &**val {
                let tag = s.trim();
                if !tag.is_empty() {
                    return Some(tag.to_string());
                }
            }
        }
    }
    None
}

fn parse_actions(raw: Vec<String>) -> Vec<NotificationAction> {
    let mut actions = Vec::with_capacity(raw.len() / 2);
    let mut iter = raw.into_iter();
    while let (Some(key), Some(label)) = (iter.next(), iter.next()) {
        if !key.is_empty() {
            actions.push(NotificationAction { key, label });
        }
    }
    actions
}

#[zbus::interface(name = "org.freedesktop.Notifications")]
impl NotificationsService {
    async fn get_capabilities(&self) -> Vec<String> {
        vec![
            "body".to_string(),
            "actions".to_string(),
            "icon-static".to_string(),
            "persistence".to_string(),
        ]
    }

    async fn get_server_information(&self) -> (String, String, String, String) {
        (
            "kaze-shell".to_string(),
            "kaze-dots".to_string(),
            env!("CARGO_PKG_VERSION").to_string(),
            "1.2".to_string(),
        )
    }

    #[allow(clippy::too_many_arguments)]
    async fn notify(
        &self,
        app_name: String,
        replaces_id: u32,
        app_icon: String,
        summary: String,
        body: String,
        actions: Vec<String>,
        hints: HashMap<String, OwnedValue>,
        expire_timeout: i32,
    ) -> u32 {
        let id = self.alloc_id(replaces_id);
        let urgency = parse_urgency(&hints);
        let resident = parse_bool_hint(&hints, "resident");
        let transient = parse_bool_hint(&hints, "transient");
        let sync_tag = parse_sync_tag(&hints);
        let parsed_actions = parse_actions(actions);
        let timestamp_epoch_secs = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();

        let item = NotificationItem {
            id,
            app_name,
            summary,
            body,
            app_icon,
            urgency,
            actions: parsed_actions,
            expire_timeout_ms: expire_timeout,
            resident,
            transient,
            sync_tag,
            timestamp_epoch_secs,
        };
        let _ = self.event_tx.send(SystemEvent::NotificationReceived(item));
        id
    }

    async fn close_notification(&self, id: u32) {
        if id > 0 {
            let _ = self
                .event_tx
                .send(SystemEvent::NotificationCloseRequested { id });
        }
    }

    #[zbus(signal)]
    async fn notification_closed(
        emitter: &SignalEmitter<'_>,
        id: u32,
        reason: u32,
    ) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn action_invoked(
        emitter: &SignalEmitter<'_>,
        id: u32,
        action_key: &str,
    ) -> zbus::Result<()>;
}

async fn try_claim_name(conn: &Connection) -> bool {
    let flags = RequestNameFlags::DoNotQueue.into();
    match conn.request_name_with_flags(BUS_NAME, flags).await {
        Ok(RequestNameReply::PrimaryOwner | RequestNameReply::AlreadyOwner) => true,
        Ok(RequestNameReply::Exists | RequestNameReply::InQueue) => {
            eprintln!("kaze-sys: {BUS_NAME} already owned by another daemon; waiting for release");
            false
        }
        Err(err) => {
            eprintln!("kaze-sys: failed requesting {BUS_NAME}: {err}");
            false
        }
    }
}

pub async fn run_notify_task(
    mut initial_conn: Option<Connection>,
    event_tx: CalloopSender<SystemEvent>,
    mut sig_rx: mpsc::UnboundedReceiver<NotifySignal>,
) {
    let mut backoff = Duration::from_millis(500);
    loop {
        match run_notify_session(initial_conn.take(), event_tx.clone(), &mut sig_rx).await {
            Ok(()) => return,
            Err(err) => {
                eprintln!("kaze-sys: notifications D-Bus disconnected ({err}); reconnecting");
                let _ = event_tx.send(SystemEvent::NotificationsBusStatus { owned: false });
                tokio::time::sleep(backoff).await;
                backoff = (backoff * 2).min(Duration::from_secs(5));
            }
        }
    }
}

async fn run_notify_session(
    initial_conn: Option<Connection>,
    event_tx: CalloopSender<SystemEvent>,
    sig_rx: &mut mpsc::UnboundedReceiver<NotifySignal>,
) -> Result<(), String> {
    let conn = match initial_conn {
        Some(c) => c,
        None => Connection::session()
            .await
            .map_err(|e| format!("session bus connect: {e}"))?,
    };

    let service = NotificationsService::new(event_tx.clone());
    conn.object_server()
        .at(OBJ_PATH, service)
        .await
        .map_err(|e| format!("register {OBJ_PATH}: {e}"))?;

    let mut owned = try_claim_name(&conn).await;
    let _ = event_tx.send(SystemEvent::NotificationsBusStatus { owned });

    let dbus_proxy = DBusProxy::new(&conn)
        .await
        .map_err(|e| format!("DBusProxy: {e}"))?;
    let mut owner_stream = dbus_proxy
        .receive_name_owner_changed()
        .await
        .map_err(|e| format!("NameOwnerChanged stream: {e}"))?;

    let unique_name = conn
        .unique_name()
        .map(|n| n.as_str().to_string())
        .unwrap_or_default();

    loop {
        tokio::select! {
            sig = sig_rx.recv() => {
                let Some(sig) = sig else {
                    return Ok(());
                };
                if let Ok(iface) = conn
                    .object_server()
                    .interface::<_, NotificationsService>(OBJ_PATH)
                    .await
                {
                    let emitter = iface.signal_emitter();
                    match sig {
                        NotifySignal::Closed { id, reason } => {
                            let _ = NotificationsService::notification_closed(emitter, id, reason).await;
                        }
                        NotifySignal::ActionInvoked { id, action_key } => {
                            let _ = NotificationsService::action_invoked(emitter, id, &action_key).await;
                        }
                    }
                }
            }
            changed = owner_stream.next() => {
                let Some(msg) = changed else {
                    return Err("NameOwnerChanged stream closed".into());
                };
                if let Ok(args) = msg.args() {
                    if args.name().as_str() == BUS_NAME {
                        let new_owner = args.new_owner().as_ref().map(|n| n.as_str()).unwrap_or("");
                        if new_owner.is_empty() && !owned {
                            owned = try_claim_name(&conn).await;
                            let _ = event_tx.send(SystemEvent::NotificationsBusStatus { owned });
                        } else if !new_owner.is_empty() && new_owner != unique_name && owned {
                            owned = false;
                            let _ = event_tx.send(SystemEvent::NotificationsBusStatus { owned: false });
                        }
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allocates_nonzero_ids_and_honors_replaces_id() {
        let counter = AtomicU32::new(1);
        assert_eq!(allocate_notification_id(&counter, 0), 1);
        assert_eq!(allocate_notification_id(&counter, 0), 2);
        assert_eq!(allocate_notification_id(&counter, 42), 42);
        assert_eq!(allocate_notification_id(&counter, 0), 3);

        let wrapping = AtomicU32::new(u32::MAX);
        assert_eq!(allocate_notification_id(&wrapping, 0), u32::MAX);
        assert_eq!(allocate_notification_id(&wrapping, 0), 1);
    }

    #[test]
    fn parses_urgency_boolean_and_sync_hints_across_integer_widths() {
        let mut hints: HashMap<String, OwnedValue> = HashMap::new();
        hints.insert("urgency".into(), OwnedValue::from(2u8));
        hints.insert("resident".into(), OwnedValue::from(true));
        hints.insert(
            "x-canonical-private-synchronous".into(),
            OwnedValue::try_from(Value::from("kaze-display")).expect("string hint"),
        );
        assert_eq!(parse_urgency(&hints), NotificationUrgency::Critical);
        assert!(parse_bool_hint(&hints, "resident"));
        assert!(!parse_bool_hint(&hints, "transient"));
        assert_eq!(parse_sync_tag(&hints).as_deref(), Some("kaze-display"));

        hints.insert("urgency".into(), OwnedValue::from(0i32));
        assert_eq!(parse_urgency(&hints), NotificationUrgency::Low);

        hints.insert("urgency".into(), OwnedValue::from(1u32));
        assert_eq!(parse_urgency(&hints), NotificationUrgency::Normal);
    }

    #[test]
    fn parses_action_pairs_ignoring_trailing_orphan() {
        let actions = parse_actions(vec![
            "default".into(),
            "Open".into(),
            "reply".into(),
            "Trả lời".into(),
            "orphan".into(),
        ]);
        assert_eq!(actions.len(), 2);
        assert_eq!(actions[0].key, "default");
        assert_eq!(actions[1].label, "Trả lời");
    }
}
