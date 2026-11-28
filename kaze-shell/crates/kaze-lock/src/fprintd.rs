#![deny(clippy::unwrap_used)]

use futures_util::StreamExt;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::runtime::Builder;
use zbus::zvariant::OwnedObjectPath;
use zbus::{Connection, Proxy};

const FPRINT_DEST: &str = "net.reactivated.Fprint";
const FPRINT_MGR_PATH: &str = "/net/reactivated/Fprint/Manager";
const FPRINT_MGR_IFACE: &str = "net.reactivated.Fprint.Manager";
const FPRINT_DEV_IFACE: &str = "net.reactivated.Fprint.Device";

#[derive(Debug, Clone)]
pub enum FingerprintEvent {
    Matched,
    NoMatch,
}

pub fn spawn_fprintd_listener<F>(username: String, cancel: Arc<AtomicBool>, emit: F)
where
    F: Fn(FingerprintEvent) + Send + 'static,
{
    let _ = std::thread::Builder::new()
        .name("kaze-fprintd".to_string())
        .spawn(move || {
            let Ok(rt) = Builder::new_current_thread().enable_all().build() else {
                return;
            };
            rt.block_on(async move {
                let _ = run_fprintd(&username, &cancel, &emit).await;
            });
        });
}

async fn run_fprintd<F>(username: &str, cancel: &AtomicBool, emit: &F) -> zbus::Result<()>
where
    F: Fn(FingerprintEvent),
{
    let conn = Connection::system().await?;
    let mgr = Proxy::new(&conn, FPRINT_DEST, FPRINT_MGR_PATH, FPRINT_MGR_IFACE).await?;
    let dev_path: OwnedObjectPath = mgr.call("GetDefaultDevice", &()).await?;
    let dev = Proxy::new(&conn, FPRINT_DEST, dev_path.as_str(), FPRINT_DEV_IFACE).await?;
    dev.call::<_, _, ()>("Claim", &(username,)).await?;

    let mut status_stream = dev.receive_signal("VerifyStatus").await?;
    if let Err(err) = dev.call::<_, _, ()>("VerifyStart", &("any",)).await {
        let _ = dev.call::<_, _, ()>("Release", &()).await;
        return Err(err);
    }

    while let Some(msg) = status_stream.next().await {
        if cancel.load(Ordering::Relaxed) {
            break;
        }
        if let Ok((result, done)) = msg.body().deserialize::<(String, bool)>() {
            if result == "verify-match" {
                emit(FingerprintEvent::Matched);
                break;
            }
            if done {
                emit(FingerprintEvent::NoMatch);
                let _ = dev.call::<_, _, ()>("VerifyStop", &()).await;
                if cancel.load(Ordering::Relaxed) {
                    break;
                }
                if dev
                    .call::<_, _, ()>("VerifyStart", &("any",))
                    .await
                    .is_err()
                {
                    break;
                }
            }
        }
    }

    let _ = dev.call::<_, _, ()>("VerifyStop", &()).await;
    let _ = dev.call::<_, _, ()>("Release", &()).await;
    Ok(())
}
