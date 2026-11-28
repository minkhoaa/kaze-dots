use crate::theme::write_atomic;
use chacha20poly1305::aead::{Aead, KeyInit, OsRng};
use chacha20poly1305::{AeadCore, ChaCha20Poly1305, Key, Nonce};
use std::fmt;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use zeroize::Zeroizing;

const BLOB_MAGIC: &[u8; 8] = b"KZENC01\0";
const STORE_MAGIC: &[u8; 8] = b"KZSTORE1";
const NONCE_LEN: usize = 12;

#[derive(Clone)]
pub struct MasterKey(Zeroizing<[u8; 32]>);

impl fmt::Debug for MasterKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("MasterKey([REDACTED])")
    }
}

impl MasterKey {
    pub fn from_bytes(bytes: [u8; 32]) -> Self {
        Self(Zeroizing::new(bytes))
    }

    pub fn generate() -> Self {
        let key = ChaCha20Poly1305::generate_key(&mut OsRng);
        let mut raw = [0u8; 32];
        raw.copy_from_slice(&key);
        Self(Zeroizing::new(raw))
    }

    pub fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }
}

pub fn default_master_key_path() -> Result<PathBuf, String> {
    Ok(crate::layout::xdg_state_home()?
        .join("kaze")
        .join("master.key"))
}

/// Loads an existing `0600` master key file or generates a new 256-bit key with strict `0600` permissions.
/// Refuses to load any key file whose permissions expose bits to group or others (`mode & 0o077 != 0`).
pub fn load_or_create_keyfile(path: &Path) -> Result<MasterKey, String> {
    if let Some(parent) = path.parent() {
        if !parent.exists() {
            fs::DirBuilder::new()
                .mode(0o700)
                .recursive(true)
                .create(parent)
                .map_err(|e| format!("failed creating key dir {}: {e}", parent.display()))?;
        }
    }

    match fs::metadata(path) {
        Ok(meta) => {
            let mode = meta.permissions().mode() & 0o777;
            if mode & 0o077 != 0 {
                return Err(format!(
                    "refusing insecure master key {} (mode {:04o}, expected 0600)",
                    path.display(),
                    mode
                ));
            }
            let bytes = Zeroizing::new(
                fs::read(path)
                    .map_err(|e| format!("failed reading keyfile {}: {e}", path.display()))?,
            );
            if bytes.len() != 32 {
                return Err(format!(
                    "invalid master key length in {} (got {} bytes, expected 32)",
                    path.display(),
                    bytes.len()
                ));
            }
            let mut raw = [0u8; 32];
            raw.copy_from_slice(&bytes);
            Ok(MasterKey::from_bytes(raw))
        }
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            let key = MasterKey::generate();
            write_private_file(path, key.as_bytes())?;
            Ok(key)
        }
        Err(err) => Err(format!("failed inspecting {}: {err}", path.display())),
    }
}

pub fn write_private_file(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| format!("missing parent directory for {}", path.display()))?;
    if !parent.exists() {
        fs::DirBuilder::new()
            .mode(0o700)
            .recursive(true)
            .create(parent)
            .map_err(|e| format!("failed creating {}: {e}", parent.display()))?;
    }
    let tmp = parent.join(format!(
        ".{}.tmp.{}",
        path.file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("kaze"),
        std::process::id()
    ));
    let mut file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(&tmp)
        .map_err(|e| format!("failed creating {}: {e}", tmp.display()))?;
    file.write_all(bytes)
        .and_then(|_| file.sync_all())
        .map_err(|e| {
            let _ = fs::remove_file(&tmp);
            format!("failed writing {}: {e}", tmp.display())
        })?;
    drop(file);
    fs::set_permissions(&tmp, fs::Permissions::from_mode(0o600))
        .map_err(|e| format!("failed chmod 0600 on {}: {e}", tmp.display()))?;
    fs::rename(&tmp, path).map_err(|e| {
        let _ = fs::remove_file(&tmp);
        format!("failed replacing {}: {e}", path.display())
    })
}

pub fn seal(key: &MasterKey, plaintext: &[u8]) -> Result<Vec<u8>, String> {
    let cipher = ChaCha20Poly1305::new(Key::from_slice(key.as_bytes()));
    let nonce = ChaCha20Poly1305::generate_nonce(&mut OsRng);
    let ciphertext = cipher
        .encrypt(&nonce, plaintext)
        .map_err(|_| "AEAD encryption failed".to_string())?;
    let mut out = Vec::with_capacity(BLOB_MAGIC.len() + NONCE_LEN + ciphertext.len());
    out.extend_from_slice(BLOB_MAGIC);
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&ciphertext);
    Ok(out)
}

pub fn open(key: &MasterKey, blob: &[u8]) -> Result<Vec<u8>, String> {
    let min_len = BLOB_MAGIC.len() + NONCE_LEN + 16;
    if blob.len() < min_len || &blob[..BLOB_MAGIC.len()] != BLOB_MAGIC {
        return Err("invalid encrypted blob header".to_string());
    }
    let nonce_start = BLOB_MAGIC.len();
    let ct_start = nonce_start + NONCE_LEN;
    let nonce = Nonce::from_slice(&blob[nonce_start..ct_start]);
    let cipher = ChaCha20Poly1305::new(Key::from_slice(key.as_bytes()));
    cipher
        .decrypt(nonce, &blob[ct_start..])
        .map_err(|_| "AEAD authentication failed".to_string())
}

pub fn open_zeroizing(key: &MasterKey, blob: &[u8]) -> Result<Zeroizing<Vec<u8>>, String> {
    open(key, blob).map(Zeroizing::new)
}

/// Framed AEAD record store on disk. Each record is sealed independently with a fresh
/// random nonce; corrupted or truncated records are isolated and skipped on load without
/// panicking, and the store can be re-saved cleanly.
pub struct EncryptedRecordStore;

impl EncryptedRecordStore {
    pub fn save_records(
        path: &Path,
        key: &MasterKey,
        records: &[&[u8]],
    ) -> Result<(), String> {
        let mut raw = Vec::with_capacity(STORE_MAGIC.len() + records.len() * 64);
        raw.extend_from_slice(STORE_MAGIC);
        for rec in records {
            let sealed = seal(key, rec)?;
            let len = u32::try_from(sealed.len())
                .map_err(|_| "encrypted record exceeds 4 GiB limit".to_string())?;
            raw.extend_from_slice(&len.to_le_bytes());
            raw.extend_from_slice(&sealed);
        }
        write_private_file(path, &raw)
    }

    pub fn load_records(path: &Path, key: &MasterKey) -> (Vec<Vec<u8>>, usize) {
        let raw = match fs::read(path) {
            Ok(b) => b,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => return (Vec::new(), 0),
            Err(err) => {
                eprintln!(
                    "kaze-core::crypto: failed reading store {}: {err}",
                    path.display()
                );
                return (Vec::new(), 1);
            }
        };
        Self::decode_bytes(&raw, key)
    }

    pub fn decode_bytes(raw: &[u8], key: &MasterKey) -> (Vec<Vec<u8>>, usize) {
        if raw.len() < STORE_MAGIC.len() || &raw[..STORE_MAGIC.len()] != STORE_MAGIC {
            return (Vec::new(), usize::from(!raw.is_empty()));
        }
        let mut pos = STORE_MAGIC.len();
        let mut records = Vec::new();
        let mut corrupted = 0usize;

        while pos < raw.len() {
            let Some(len_bytes) = raw.get(pos..pos + 4) else {
                corrupted += 1;
                break;
            };
            pos += 4;
            let len = u32::from_le_bytes([len_bytes[0], len_bytes[1], len_bytes[2], len_bytes[3]])
                as usize;
            let Some(end) = pos.checked_add(len) else {
                corrupted += 1;
                break;
            };
            let Some(blob) = raw.get(pos..end) else {
                corrupted += 1;
                break;
            };
            pos = end;
            match open(key, blob) {
                Ok(plain) => records.push(plain),
                Err(_) => corrupted += 1,
            }
        }

        (records, corrupted)
    }

    /// Loads records, and if any corruption was detected, rewrites a clean store containing
    /// only the intact records so bad bytes are isolated immediately.
    pub fn load_or_repair(path: &Path, key: &MasterKey) -> (Vec<Vec<u8>>, usize) {
        let (records, corrupted) = Self::load_records(path, key);
        if corrupted > 0 && path.exists() {
            let refs: Vec<&[u8]> = records.iter().map(Vec::as_slice).collect();
            let _ = Self::save_records(path, key, &refs);
        }
        (records, corrupted)
    }
}

/// Global outbound network gate controlled by `[network] offline_mode`.
pub fn check_network_allowed(offline_mode: bool) -> Result<(), &'static str> {
    if offline_mode {
        Err("offline_mode is active: outbound network requests are blocked")
    } else {
        Ok(())
    }
}

#[allow(dead_code)]
fn _touch_write_atomic(_p: &Path, _s: &str) -> Result<(), String> {
    write_atomic(_p, _s)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seal_open_uses_unique_nonces_and_detects_tampering() {
        let key = MasterKey::generate();
        let secret = b"super-secret-token-tieng-viet";
        let b1 = seal(&key, secret).expect("seal 1");
        let b2 = seal(&key, secret).expect("seal 2");
        assert_ne!(b1, b2, "unique random nonce required per record");
        assert!(!b1.windows(secret.len()).any(|w| w == secret));
        assert_eq!(open(&key, &b1).expect("open 1"), secret);
        assert_eq!(open(&key, &b2).expect("open 2"), secret);

        let mut tampered = b1.clone();
        let last = tampered.len() - 1;
        tampered[last] ^= 0xff;
        assert!(open(&key, &tampered).is_err());
    }

    #[test]
    fn keyfile_enforces_strict_0600_permissions() {
        let dir = std::env::temp_dir().join(format!("kaze-crypto-key-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let key_path = dir.join("master.key");

        let k1 = load_or_create_keyfile(&key_path).expect("create keyfile");
        let mode = fs::metadata(&key_path)
            .expect("meta")
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o600);
        let k2 = load_or_create_keyfile(&key_path).expect("reload keyfile");
        assert_eq!(k1.as_bytes(), k2.as_bytes());

        fs::set_permissions(&key_path, fs::Permissions::from_mode(0o644)).expect("chmod 0644");
        let err = load_or_create_keyfile(&key_path).expect_err("must reject 0644");
        assert!(err.contains("0644"));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn encrypted_store_isolates_corrupted_and_truncated_records_without_plaintext() {
        let dir = std::env::temp_dir().join(format!("kaze-crypto-store-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("mkdir");
        let store_path = dir.join("store.enc");
        let key = MasterKey::generate();

        let rec1 = b"kaze-alpha-secret";
        let rec2 = b"kaze-beta-secret";
        EncryptedRecordStore::save_records(&store_path, &key, &[rec1, rec2]).expect("save");

        let disk_bytes = fs::read(&store_path).expect("read disk");
        assert!(!disk_bytes.windows(rec1.len()).any(|w| w == rec1));
        assert!(!disk_bytes.windows(rec2.len()).any(|w| w == rec2));

        let (loaded, corrupt) = EncryptedRecordStore::load_or_repair(&store_path, &key);
        assert_eq!(corrupt, 0);
        assert_eq!(loaded, vec![rec1.to_vec(), rec2.to_vec()]);

        // Corrupt a byte near the end (inside record 2) and test graceful recovery.
        let mut damaged = disk_bytes.clone();
        let idx = damaged.len() - 5;
        damaged[idx] ^= 0xaa;
        fs::write(&store_path, &damaged).expect("write damaged");
        let (repaired, corrupt_count) = EncryptedRecordStore::load_or_repair(&store_path, &key);
        assert_eq!(corrupt_count, 1);
        assert_eq!(repaired, vec![rec1.to_vec()]);

        // Truncated file yields clean empty store without panicking.
        fs::write(&store_path, &damaged[..15]).expect("write truncated");
        let (empty, trunc_corrupt) = EncryptedRecordStore::load_or_repair(&store_path, &key);
        assert!(empty.is_empty());
        assert_eq!(trunc_corrupt, 1);

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn offline_mode_blocks_outbound_network_immediately() {
        let t0 = std::time::Instant::now();
        assert!(check_network_allowed(true).is_err());
        assert!(t0.elapsed().as_millis() < 5);
        assert!(check_network_allowed(false).is_ok());
    }
}
