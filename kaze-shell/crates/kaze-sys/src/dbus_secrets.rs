use kaze_core::crypto::{load_or_create_keyfile, MasterKey};
use std::collections::HashMap;
use std::path::Path;
use zbus::zvariant::{OwnedObjectPath, OwnedValue, Value};
use zbus::{Connection, Proxy};
use zeroize::Zeroizing;

const SECRETS_DEST: &str = "org.freedesktop.secrets";
const SECRETS_PATH: &str = "/org/freedesktop/secrets";
const SERVICE_IFACE: &str = "org.freedesktop.secrets.Service";
const COLLECTION_IFACE: &str = "org.freedesktop.secrets.Collection";
const DEFAULT_COLLECTION_PATH: &str = "/org/freedesktop/secrets/aliases/default";
const KEY_LABEL: &str = "kaze-shell-master-key";

type SecretTuple<'a> = (OwnedObjectPath, Vec<u8>, &'a [u8], &'a str);
type OwnedSecretTuple = (OwnedObjectPath, Vec<u8>, Vec<u8>, String);

/// Resolves the 256-bit `MasterKey` via `org.freedesktop.secrets` (GNOME Keyring / KWallet /
/// KeePassXC) under label `kaze-shell-master-key`, falling back to a strict `0600` local
/// keyfile when Secret Service is absent or locked.
pub async fn resolve_master_key(
    sess_conn: Option<&Connection>,
    fallback_path: &Path,
) -> Result<MasterKey, String> {
    if let Some(conn) = sess_conn {
        if let Some(key) = try_secret_service(conn).await {
            return Ok(key);
        }
    }
    load_or_create_keyfile(fallback_path)
}

async fn try_secret_service(conn: &Connection) -> Option<MasterKey> {
    let service = Proxy::new(conn, SECRETS_DEST, SECRETS_PATH, SERVICE_IFACE)
        .await
        .ok()?;
    let empty_in = Value::from("");
    let (_output, session_path): (OwnedValue, OwnedObjectPath) = service
        .call("OpenSession", &("plain", &empty_in))
        .await
        .ok()?;

    let mut attrs = HashMap::new();
    attrs.insert("application", "kaze-shell");
    attrs.insert("label", KEY_LABEL);

    let (unlocked, _locked): (Vec<OwnedObjectPath>, Vec<OwnedObjectPath>) =
        service.call("SearchItems", &(&attrs,)).await.ok()?;

    if let Some(item_path) = unlocked.first() {
        let items = vec![item_path.clone()];
        let secrets: HashMap<OwnedObjectPath, OwnedSecretTuple> = service
            .call("GetSecrets", &(&items, &session_path))
            .await
            .ok()?;
        if let Some((_sess, _params, secret_bytes, _ct)) = secrets.get(item_path) {
            let secret_z = Zeroizing::new(secret_bytes.clone());
            if let Some(key) = decode_secret_bytes(&secret_z) {
                return Some(key);
            }
        }
    }

    // Store a newly generated key only if the default collection exists and is unlocked.
    let collection = Proxy::new(conn, SECRETS_DEST, DEFAULT_COLLECTION_PATH, COLLECTION_IFACE)
        .await
        .ok()?;
    let is_locked: bool = collection.get_property("Locked").await.unwrap_or(true);
    if is_locked {
        return None;
    }

    let key = MasterKey::generate();
    let hex_secret = Zeroizing::new(encode_hex(key.as_bytes()));
    let mut item_attrs = HashMap::new();
    item_attrs.insert("application", "kaze-shell");
    item_attrs.insert("label", KEY_LABEL);

    let mut props: HashMap<&str, Value<'_>> = HashMap::new();
    props.insert("org.freedesktop.Secret.Item.Label", Value::from(KEY_LABEL));
    props.insert(
        "org.freedesktop.Secret.Item.Attributes",
        Value::from(item_attrs),
    );

    let secret: SecretTuple<'_> = (
        session_path,
        Vec::new(),
        hex_secret.as_bytes(),
        "text/plain",
    );
    let created: Result<(OwnedObjectPath, OwnedObjectPath), _> =
        collection.call("CreateItem", &(props, secret, true)).await;
    if created.is_ok() {
        Some(key)
    } else {
        None
    }
}

pub fn decode_secret_bytes(raw: &[u8]) -> Option<MasterKey> {
    if raw.len() == 32 {
        let mut out = [0u8; 32];
        out.copy_from_slice(raw);
        return Some(MasterKey::from_bytes(out));
    }
    let s = std::str::from_utf8(raw).ok()?.trim();
    if s.len() != 64 {
        return None;
    }
    let mut out = [0u8; 32];
    for (i, slot) in out.iter_mut().enumerate() {
        *slot = u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).ok()?;
    }
    Some(MasterKey::from_bytes(out))
}

fn encode_hex(bytes: &[u8; 32]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut s = String::with_capacity(64);
    for &b in bytes {
        s.push(char::from(HEX[usize::from(b >> 4)]));
        s.push(char::from(HEX[usize::from(b & 0x0f)]));
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_hex_and_raw_master_key_secrets() {
        let key = MasterKey::generate();
        let hex = encode_hex(key.as_bytes());
        let decoded_hex = decode_secret_bytes(hex.as_bytes()).expect("decode hex");
        assert_eq!(decoded_hex.as_bytes(), key.as_bytes());

        let decoded_raw = decode_secret_bytes(key.as_bytes()).expect("decode raw");
        assert_eq!(decoded_raw.as_bytes(), key.as_bytes());

        assert!(decode_secret_bytes(b"short").is_none());
    }

    #[tokio::test(flavor = "current_thread")]
    async fn falls_back_to_0600_keyfile_when_secret_service_unavailable() {
        let dir = std::env::temp_dir().join(format!("kaze-secrets-fb-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let key_path = dir.join("master.key");

        let k1 = resolve_master_key(None, &key_path)
            .await
            .expect("fallback keyfile");
        let k2 = resolve_master_key(None, &key_path)
            .await
            .expect("reload fallback keyfile");
        assert_eq!(k1.as_bytes(), k2.as_bytes());

        let _ = std::fs::remove_dir_all(&dir);
    }
}
