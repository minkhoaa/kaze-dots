use calloop::channel::Sender as CalloopSender;
use futures_util::StreamExt;
use kaze_core::SystemEvent;
use zbus::fdo::DBusProxy;
use zbus::{Connection, MatchRule, MessageStream, Proxy};

const FCITX_DEST: &str = "org.fcitx.Fcitx.Controller1";
const FCITX_PATH: &str = "/controller";
const FCITX_IFACE: &str = "org.fcitx.Fcitx.Controller1";

/// Passive D-Bus listener for Fcitx5 input method changes.
/// Never D-Bus-activates Fcitx5 when it isn't running (`NameOwnerChanged` + passive checks only).
pub async fn run_input_method_task(conn: Connection, event_tx: CalloopSender<SystemEvent>) {
    let Ok(dbus) = DBusProxy::new(&conn).await else {
        return;
    };

    if dbus
        .name_has_owner(FCITX_DEST.try_into().expect("valid bus name"))
        .await
        .unwrap_or(false)
    {
        emit_fcitx_im(&conn, &event_tx).await;
    }

    let mut owner_stream = dbus.receive_name_owner_changed().await.ok();
    let rule = MatchRule::builder()
        .msg_type(zbus::message::Type::Signal)
        .interface(FCITX_IFACE)
        .map(zbus::match_rule::Builder::build)
        .ok();
    let mut sig_stream = match rule {
        Some(r) => MessageStream::for_match_rule(r, &conn, Some(8)).await.ok(),
        None => None,
    };

    loop {
        tokio::select! {
            sig = async {
                match sig_stream.as_mut() {
                    Some(s) => s.next().await,
                    None => std::future::pending().await,
                }
            } => {
                if sig.is_none() {
                    sig_stream = None;
                    continue;
                }
                emit_fcitx_im(&conn, &event_tx).await;
            }
            owner = async {
                match owner_stream.as_mut() {
                    Some(s) => s.next().await,
                    None => std::future::pending().await,
                }
            } => {
                let Some(ev) = owner else { break; };
                if let Ok(args) = ev.args() {
                    if args.name().as_str() == FCITX_DEST {
                        let new_owner = args.new_owner().as_ref().map(|n| n.as_str()).unwrap_or("");
                        if !new_owner.is_empty() {
                            emit_fcitx_im(&conn, &event_tx).await;
                        }
                    }
                }
            }
        }
    }
}

async fn emit_fcitx_im(conn: &Connection, event_tx: &CalloopSender<SystemEvent>) {
    let Ok(proxy) = Proxy::new(conn, FCITX_DEST, FCITX_PATH, FCITX_IFACE).await else {
        return;
    };
    if let Ok(im) = proxy.call::<_, _, String>("CurrentInputMethod", &()).await {
        let trimmed = im.trim();
        if !trimmed.is_empty() {
            let _ = event_tx.send(SystemEvent::KeyboardLayoutChanged {
                raw_name: trimmed.to_string(),
                source: "fcitx5".to_string(),
            });
        }
    }
}
