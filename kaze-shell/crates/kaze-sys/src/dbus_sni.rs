use calloop::channel::Sender as CalloopSender;
use futures_util::StreamExt;
use kaze_core::{SystemEvent, TrayItem, TrayMenuEntry, TrayMenuState};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tokio::sync::mpsc;
use zbus::fdo::{DBusProxy, RequestNameFlags, RequestNameReply};
use zbus::message::Header;
use zbus::object_server::SignalEmitter;
use zbus::zvariant::{OwnedObjectPath, OwnedValue, Value};
use zbus::{Connection, Proxy};

const WATCHER_BUS_NAME: &str = "org.kde.StatusNotifierWatcher";
const WATCHER_OBJ_PATH: &str = "/StatusNotifierWatcher";
const SNI_IFACE: &str = "org.kde.StatusNotifierItem";
const DBUSMENU_IFACE: &str = "com.canonical.dbusmenu";

#[derive(Debug, Clone)]
pub enum TrayCmd {
    Activate {
        service: String,
        object_path: String,
        x: i32,
        y: i32,
        secondary: bool,
    },
    OpenMenu {
        service: String,
        menu_path: String,
    },
    MenuClick {
        service: String,
        menu_path: String,
        item_id: i32,
    },
}

enum WatcherEvent {
    ItemRegistered {
        service: String,
        object_path: String,
    },
    RefreshAll,
}

struct WatcherService {
    items: Arc<Mutex<Vec<String>>>,
    notify_tx: mpsc::UnboundedSender<WatcherEvent>,
}

#[zbus::interface(name = "org.kde.StatusNotifierWatcher")]
impl WatcherService {
    async fn register_status_notifier_item(
        &self,
        service_or_path: String,
        #[zbus(header)] header: Header<'_>,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) {
        let sender = header
            .sender()
            .map(|s| s.as_str().to_string())
            .unwrap_or_default();
        let (service, object_path) = resolve_sni_target(&service_or_path, &sender);
        if service.is_empty() {
            return;
        }
        let key = format!("{service}{object_path}");
        let inserted = {
            let Ok(mut list) = self.items.lock() else {
                return;
            };
            if list.contains(&key) {
                false
            } else {
                list.push(key.clone());
                true
            }
        };
        if inserted {
            let _ = Self::status_notifier_item_registered(&emitter, &key).await;
            let _ = self.notify_tx.send(WatcherEvent::ItemRegistered {
                service,
                object_path,
            });
        } else {
            let _ = self.notify_tx.send(WatcherEvent::RefreshAll);
        }
    }

    async fn register_status_notifier_host(
        &self,
        _service: String,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) {
        let _ = Self::status_notifier_host_registered(&emitter).await;
    }

    #[zbus(property)]
    async fn registered_status_notifier_items(&self) -> Vec<String> {
        self.items.lock().map(|g| g.clone()).unwrap_or_default()
    }

    #[zbus(property)]
    async fn is_status_notifier_host_registered(&self) -> bool {
        true
    }

    #[zbus(property)]
    async fn protocol_version(&self) -> i32 {
        0
    }

    #[zbus(signal)]
    async fn status_notifier_item_registered(
        emitter: &SignalEmitter<'_>,
        service: &str,
    ) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn status_notifier_item_unregistered(
        emitter: &SignalEmitter<'_>,
        service: &str,
    ) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn status_notifier_host_registered(emitter: &SignalEmitter<'_>) -> zbus::Result<()>;
}

/// Resolves both KDE-style (`org.example.App`) and AppIndicator-style (`/org/ayatana/NotificationItem/...`)
/// `RegisterStatusNotifierItem` arguments into `(bus_name, object_path)`.
pub fn resolve_sni_target(arg: &str, sender: &str) -> (String, String) {
    let trimmed = arg.trim();
    if trimmed.starts_with('/') {
        (sender.to_string(), trimmed.to_string())
    } else if let Some((svc, path)) = trimmed.split_once('/') {
        (svc.to_string(), format!("/{path}"))
    } else if !trimmed.is_empty() {
        (trimmed.to_string(), "/StatusNotifierItem".to_string())
    } else {
        (sender.to_string(), "/StatusNotifierItem".to_string())
    }
}

/// Converts a StatusNotifierItem `IconPixmap` (big-endian ARGB32 network byte order)
/// into premultiplied RGBA bytes for `tiny-skia`.
pub fn argb32_network_to_premul_rgba(width: i32, height: i32, data: &[u8]) -> Option<Arc<[u8]>> {
    if width <= 0 || height <= 0 || width > 512 || height > 512 {
        return None;
    }
    let expected = (width as usize)
        .checked_mul(height as usize)?
        .checked_mul(4)?;
    if data.len() < expected {
        return None;
    }
    let mut out = vec![0u8; expected];
    let (src_chunks, _) = data[..expected].as_chunks::<4>();
    let (dst_chunks, _) = out.as_chunks_mut::<4>();
    for (src, dst) in src_chunks.iter().zip(dst_chunks.iter_mut()) {
        let a = u32::from(src[0]);
        let r = u32::from(src[1]);
        let g = u32::from(src[2]);
        let b = u32::from(src[3]);
        dst[0] = ((r * a + 127) / 255) as u8;
        dst[1] = ((g * a + 127) / 255) as u8;
        dst[2] = ((b * a + 127) / 255) as u8;
        dst[3] = a as u8;
    }
    Some(Arc::from(out))
}

fn load_icon_from_theme(icon_name: &str, theme_path: &str) -> Option<(u32, u32, Arc<[u8]>)> {
    if icon_name.is_empty() {
        return None;
    }
    let mut candidates: Vec<PathBuf> = Vec::new();
    let direct = PathBuf::from(icon_name);
    if direct.is_absolute() && direct.is_file() {
        candidates.push(direct);
    }
    if !theme_path.is_empty() {
        let base = PathBuf::from(theme_path);
        candidates.push(base.join(format!("{icon_name}.png")));
        for size in ["24x24", "22x22", "32x32", "48x48", "16x16"] {
            for cat in ["apps", "status", "panel"] {
                candidates.push(base.join(size).join(cat).join(format!("{icon_name}.png")));
            }
        }
    }
    for theme in ["Papirus-Dark", "hicolor", "Adwaita"] {
        for size in ["24x24", "22x22", "32x32", "48x48", "16x16"] {
            for cat in ["apps", "status", "panel"] {
                candidates.push(PathBuf::from(format!(
                    "/usr/share/icons/{theme}/{size}/{cat}/{icon_name}.png"
                )));
            }
        }
    }
    candidates.push(PathBuf::from(format!("/usr/share/pixmaps/{icon_name}.png")));

    for path in candidates {
        if !path.is_file() {
            continue;
        }
        let Ok(img) = image::open(&path) else {
            continue;
        };
        let rgba = img.to_rgba8();
        let (w, h) = rgba.dimensions();
        if w == 0 || h == 0 {
            continue;
        }
        let mut premul = Vec::with_capacity((w as usize) * (h as usize) * 4);
        for px in rgba.pixels() {
            let a = u32::from(px[3]);
            premul.push(((u32::from(px[0]) * a + 127) / 255) as u8);
            premul.push(((u32::from(px[1]) * a + 127) / 255) as u8);
            premul.push(((u32::from(px[2]) * a + 127) / 255) as u8);
            premul.push(px[3]);
        }
        return Some((w, h, Arc::from(premul)));
    }
    None
}

async fn fetch_sni_item(conn: &Connection, service: &str, object_path: &str) -> Option<TrayItem> {
    let proxy = Proxy::new(conn, service, object_path, SNI_IFACE)
        .await
        .ok()?;
    let id: String = proxy
        .get_property("Id")
        .await
        .unwrap_or_else(|_| service.to_string());
    let title: String = proxy
        .get_property("Title")
        .await
        .unwrap_or_else(|_| id.clone());
    let icon_name: String = proxy.get_property("IconName").await.unwrap_or_default();
    let icon_theme_path: String = proxy
        .get_property("IconThemePath")
        .await
        .unwrap_or_default();
    let menu_path: String = proxy
        .get_property::<OwnedObjectPath>("Menu")
        .await
        .map(|p| p.as_str().to_string())
        .unwrap_or_default();

    let mut icon_width = 0u32;
    let mut icon_height = 0u32;
    let mut icon_rgba: Option<Arc<[u8]>> = None;

    if let Ok(pixmaps) = proxy
        .get_property::<Vec<(i32, i32, Vec<u8>)>>("IconPixmap")
        .await
    {
        // Pick the icon size closest to 22px (preferring >= 16px).
        if let Some((w, h, bytes)) = pixmaps
            .iter()
            .filter(|(w, h, _)| *w > 0 && *h > 0)
            .min_by_key(|(w, _, _)| (*w - 22).abs())
        {
            if let Some(rgba) = argb32_network_to_premul_rgba(*w, *h, bytes) {
                icon_width = *w as u32;
                icon_height = *h as u32;
                icon_rgba = Some(rgba);
            }
        }
    }

    if icon_rgba.is_none() && !icon_name.is_empty() {
        if let Some((w, h, rgba)) = load_icon_from_theme(&icon_name, &icon_theme_path) {
            icon_width = w;
            icon_height = h;
            icon_rgba = Some(rgba);
        }
    }

    Some(TrayItem {
        id,
        service: service.to_string(),
        object_path: object_path.to_string(),
        title,
        icon_name,
        menu_path,
        icon_width,
        icon_height,
        icon_rgba,
    })
}

/// Parses `com.canonical.dbusmenu` `GetLayout` result `(u32, (i32, a{sv}, av))` into flat menu entries.
fn parse_dbusmenu_children(children: &[OwnedValue]) -> Vec<TrayMenuEntry> {
    let mut out = Vec::new();
    for child in children {
        let Value::Structure(s) = &**child else {
            continue;
        };
        let fields = s.fields();
        if fields.len() < 2 {
            continue;
        }
        let id = match &fields[0] {
            Value::I32(n) => *n,
            Value::U32(n) => *n as i32,
            _ => continue,
        };
        let Value::Dict(dict) = &fields[1] else {
            continue;
        };

        let mut visible = true;
        let mut enabled = true;
        let mut separator = false;
        let mut label = String::new();
        let mut toggle_state = -1i32;

        for (k, v) in dict.iter() {
            let Value::Str(key) = k else { continue };
            let inner = match v {
                Value::Value(boxed) => boxed.as_ref(),
                other => other,
            };
            match key.as_str() {
                "visible" => {
                    if let Value::Bool(b) = inner {
                        visible = *b;
                    }
                }
                "enabled" => {
                    if let Value::Bool(b) = inner {
                        enabled = *b;
                    }
                }
                "type" => {
                    if let Value::Str(t) = inner {
                        separator = t.as_str() == "separator";
                    }
                }
                "label" => {
                    if let Value::Str(l) = inner {
                        label = strip_mnemonic(l.as_str());
                    }
                }
                "toggle-state" => {
                    if let Value::I32(n) = inner {
                        toggle_state = *n;
                    }
                }
                _ => {}
            }
        }
        if !visible {
            continue;
        }
        if !separator && label.trim().is_empty() {
            continue;
        }
        out.push(TrayMenuEntry {
            id,
            label,
            enabled,
            separator,
            toggle_state,
        });
    }
    out
}

fn strip_mnemonic(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut chars = raw.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '_' {
            if chars.peek() == Some(&'_') {
                out.push('_');
                chars.next();
            }
        } else {
            out.push(c);
        }
    }
    out
}

async fn fetch_dbusmenu(
    conn: &Connection,
    service: &str,
    menu_path: &str,
) -> Option<TrayMenuState> {
    let proxy = Proxy::new(conn, service, menu_path, DBUSMENU_IFACE)
        .await
        .ok()?;
    let props: Vec<&str> = Vec::new();
    type DbusMenuNode = (i32, HashMap<String, OwnedValue>, Vec<OwnedValue>);
    let (_rev, (_root_id, _root_props, children)): (u32, DbusMenuNode) =
        proxy.call("GetLayout", &(0i32, 1i32, props)).await.ok()?;
    let items = parse_dbusmenu_children(&children);
    Some(TrayMenuState {
        service: service.to_string(),
        menu_path: menu_path.to_string(),
        items,
    })
}

pub async fn run_sni_task(
    conn: Connection,
    event_tx: CalloopSender<SystemEvent>,
    mut cmd_rx: mpsc::UnboundedReceiver<TrayCmd>,
) {
    let registered_keys = Arc::new(Mutex::new(Vec::<String>::new()));
    let (watch_tx, mut watch_rx) = mpsc::unbounded_channel::<WatcherEvent>();
    let service = WatcherService {
        items: Arc::clone(&registered_keys),
        notify_tx: watch_tx,
    };

    if conn
        .object_server()
        .at(WATCHER_OBJ_PATH, service)
        .await
        .is_err()
    {
        return;
    }

    let flags = RequestNameFlags::DoNotQueue.into();
    let owned = matches!(
        conn.request_name_with_flags(WATCHER_BUS_NAME, flags).await,
        Ok(RequestNameReply::PrimaryOwner | RequestNameReply::AlreadyOwner)
    );
    let _ = event_tx.send(SystemEvent::TrayBusStatus { owned });

    let Ok(dbus) = DBusProxy::new(&conn).await else {
        return;
    };
    let Ok(mut owner_stream) = dbus.receive_name_owner_changed().await else {
        return;
    };

    let mut tracked: Vec<(String, String)> = Vec::new();

    loop {
        tokio::select! {
            ev = watch_rx.recv() => {
                let Some(ev) = ev else { break; };
                if let WatcherEvent::ItemRegistered { service, object_path } = ev {
                    if !tracked.iter().any(|(s, p)| s == &service && p == &object_path) {
                        tracked.push((service, object_path));
                    }
                }
                let mut items = Vec::with_capacity(tracked.len());
                for (svc, path) in &tracked {
                    if let Some(item) = fetch_sni_item(&conn, svc, path).await {
                        items.push(item);
                    }
                }
                let _ = event_tx.send(SystemEvent::TrayItemsChanged(items));
            }
            owner = owner_stream.next() => {
                let Some(sig) = owner else { break; };
                let Ok(args) = sig.args() else { continue; };
                let name = args.name().as_str();
                let new_owner = args.new_owner().as_ref().map(|n| n.as_str()).unwrap_or("");
                if name == WATCHER_BUS_NAME && new_owner.is_empty() {
                    let claimed = matches!(
                        conn.request_name_with_flags(WATCHER_BUS_NAME, flags).await,
                        Ok(RequestNameReply::PrimaryOwner | RequestNameReply::AlreadyOwner)
                    );
                    let _ = event_tx.send(SystemEvent::TrayBusStatus { owned: claimed });
                } else if new_owner.is_empty() && tracked.iter().any(|(s, _)| s == name) {
                    let removed_keys: Vec<String> = tracked
                        .iter()
                        .filter(|(s, _)| s == name)
                        .map(|(s, p)| format!("{s}{p}"))
                        .collect();
                    tracked.retain(|(s, _)| s != name);
                    if let Ok(mut list) = registered_keys.lock() {
                        list.retain(|k| !removed_keys.contains(k));
                    }
                    if let Ok(iface) = conn
                        .object_server()
                        .interface::<_, WatcherService>(WATCHER_OBJ_PATH)
                        .await
                    {
                        let emitter = iface.signal_emitter();
                        for k in &removed_keys {
                            let _ = WatcherService::status_notifier_item_unregistered(emitter, k).await;
                        }
                    }
                    let mut items = Vec::with_capacity(tracked.len());
                    for (svc, path) in &tracked {
                        if let Some(item) = fetch_sni_item(&conn, svc, path).await {
                            items.push(item);
                        }
                    }
                    let _ = event_tx.send(SystemEvent::TrayItemsChanged(items));
                }
            }
            cmd = cmd_rx.recv() => {
                let Some(cmd) = cmd else { break; };
                match cmd {
                    TrayCmd::Activate { service, object_path, x, y, secondary } => {
                        if let Ok(proxy) = Proxy::new(&conn, service.as_str(), object_path.as_str(), SNI_IFACE).await {
                            let primary_method = if secondary { "SecondaryActivate" } else { "Activate" };
                            if proxy.call::<_, _, ()>(primary_method, &(x, y)).await.is_err() && !secondary {
                                let _ = proxy.call::<_, _, ()>("SecondaryActivate", &(x, y)).await;
                            }
                        }
                    }
                    TrayCmd::OpenMenu { service, menu_path } => {
                        if let Some(menu) = fetch_dbusmenu(&conn, &service, &menu_path).await {
                            let _ = event_tx.send(SystemEvent::TrayMenuLoaded(menu));
                        }
                    }
                    TrayCmd::MenuClick { service, menu_path, item_id } => {
                        if let Ok(proxy) = Proxy::new(&conn, service.as_str(), menu_path.as_str(), DBUSMENU_IFACE).await {
                            let empty = Value::from("");
                            let _ = proxy
                                .call::<_, _, ()>("Event", &(item_id, "clicked", empty, 0u32))
                                .await;
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
    fn resolves_kde_and_appindicator_sni_targets() {
        assert_eq!(
            resolve_sni_target("org.fcitx.Fcitx5", ":1.42"),
            ("org.fcitx.Fcitx5".into(), "/StatusNotifierItem".into())
        );
        assert_eq!(
            resolve_sni_target("/org/ayatana/NotificationItem/discord1", ":1.99"),
            (
                ":1.99".into(),
                "/org/ayatana/NotificationItem/discord1".into()
            )
        );
    }

    #[test]
    fn converts_argb32_network_order_to_premultiplied_rgba() {
        // 1x1 pixel: A=128, R=255, G=100, B=50
        let raw = [128u8, 255, 100, 50];
        let rgba = argb32_network_to_premul_rgba(1, 1, &raw).expect("valid pixmap");
        assert_eq!(&*rgba, &[128, 50, 25, 128]);
    }

    #[test]
    fn strips_dbusmenu_mnemonics() {
        assert_eq!(strip_mnemonic("_Quit"), "Quit");
        assert_eq!(strip_mnemonic("Open __Settings"), "Open _Settings");
    }
}
