use std::fs;
use std::path::Path;

/// Minimal read-only GVDB parser for `~/.config/dconf/user` reading
/// `/org/gnome/desktop/interface/text-scaling-factor` (`f64`) without spawning
/// `dconf` or activating any XDG desktop portal.
pub fn read_gnome_text_scaling_factor(dconf_user_path: &Path) -> Option<f32> {
    let data = fs::read(dconf_user_path).ok()?;
    parse_gvdb_f64(&data, "/org/gnome/desktop/interface/text-scaling-factor")
        .filter(|v| v.is_finite() && *v > 0.0)
        .map(|v| (v as f32).clamp(0.75, 2.0))
}

fn read_u32_le(data: &[u8], off: usize) -> Option<u32> {
    let b: [u8; 4] = data.get(off..off + 4)?.try_into().ok()?;
    Some(u32::from_le_bytes(b))
}

fn read_u64_le(data: &[u8], off: usize) -> Option<u64> {
    let b: [u8; 8] = data.get(off..off + 8)?.try_into().ok()?;
    Some(u64::from_le_bytes(b))
}

fn djb_hash(s: &[u8]) -> u32 {
    let mut h: u32 = 5381;
    for &b in s {
        h = h.wrapping_mul(33).wrapping_add(u32::from(b));
    }
    h
}

pub fn parse_gvdb_f64(data: &[u8], key: &str) -> Option<f64> {
    // GVDB signature: "GVariant" (8 bytes), version (u32), options (u32), root ptr (start u32, end u32)
    if data.len() < 24 || &data[0..8] != b"GVariant" {
        return None;
    }
    let version = read_u32_le(data, 8)?;
    if version != 0 {
        return None;
    }
    let root_start = read_u32_le(data, 16)? as usize;
    let root_end = read_u32_le(data, 20)? as usize;
    let root = data.get(root_start..root_end)?;
    if root.len() < 8 {
        return None;
    }

    let n_bloom_words = (read_u32_le(root, 0)? & 0x07ff_ffff) as usize;
    let n_buckets = read_u32_le(root, 4)? as usize;
    if n_buckets == 0 {
        return None;
    }
    let header_len = 8usize
        .checked_add(n_bloom_words.checked_mul(4)?)?
        .checked_add(n_buckets.checked_mul(4)?)?;
    if root.len() < header_len {
        return None;
    }
    let buckets_off = 8 + n_bloom_words * 4;
    let target_hash = djb_hash(key.as_bytes());
    let bucket = (target_hash as usize) % n_buckets;
    let start_item = read_u32_le(root, buckets_off + bucket * 4)? as usize;
    let end_item = if bucket + 1 < n_buckets {
        read_u32_le(root, buckets_off + (bucket + 1) * 4)? as usize
    } else {
        (root.len() - header_len) / 24
    };

    let total_items = (root.len() - header_len) / 24;
    let reconstruct_key = |mut idx: usize| -> Option<Vec<u8>> {
        let mut parts: Vec<&[u8]> = Vec::new();
        for _ in 0..16 {
            if idx >= total_items {
                return None;
            }
            let item_off = header_len.checked_add(idx.checked_mul(24)?)?;
            let item = root.get(item_off..item_off + 24)?;
            let parent = read_u32_le(item, 4)?;
            let key_start = read_u32_le(item, 8)? as usize;
            let key_size = u16::from_le_bytes([item[12], item[13]]) as usize;
            let seg = data.get(key_start..key_start + key_size)?;
            parts.push(seg);
            if parent == 0xffff_ffff {
                break;
            }
            idx = parent as usize;
        }
        parts.reverse();
        let total_len: usize = parts.iter().map(|p| p.len()).sum();
        let mut out = Vec::with_capacity(total_len);
        for p in parts {
            out.extend_from_slice(p);
        }
        Some(out)
    };

    for idx in start_item..end_item.min(start_item + 64) {
        if idx >= total_items {
            break;
        }
        let item_off = header_len.checked_add(idx.checked_mul(24)?)?;
        let item = root.get(item_off..item_off + 24)?;
        let typ = item[14];
        if typ != b'v' {
            continue;
        }
        let hash = read_u32_le(item, 0)?;
        let parent = read_u32_le(item, 4)?;
        if parent == 0xffff_ffff && hash != target_hash {
            continue;
        }
        let Some(full_key) = reconstruct_key(idx) else {
            continue;
        };
        if full_key != key.as_bytes() {
            continue;
        }
        let val_start = read_u32_le(item, 16)? as usize;
        let val_end = read_u32_le(item, 20)? as usize;
        let val_slice = data.get(val_start..val_end)?;
        // GVariant boxed value: 8-byte f64 + 0x00 + 'd'
        if val_slice.len() >= 10 && val_slice[8] == 0 && val_slice[9] == b'd' {
            let bits = read_u64_le(val_slice, 0)?;
            return Some(f64::from_le_bytes(bits.to_le_bytes()));
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn handles_missing_or_corrupt_dconf_gracefully() {
        assert_eq!(
            read_gnome_text_scaling_factor(Path::new("/nonexistent/dconf")),
            None
        );
        assert_eq!(
            parse_gvdb_f64(
                b"not-gvdb",
                "/org/gnome/desktop/interface/text-scaling-factor"
            ),
            None
        );
    }

    #[test]
    fn parses_hierarchical_gvdb_text_scaling_factor() {
        // Synthetic GVDB with parent link ("/org/gnome/desktop/interface/" -> "text-scaling-factor")
        let mut buf = vec![0u8; 256];
        buf[0..8].copy_from_slice(b"GVariant");
        buf[8..12].copy_from_slice(&0u32.to_le_bytes());

        let prefix = b"/org/gnome/desktop/interface/";
        let suffix = b"text-scaling-factor";
        let prefix_off = 24usize;
        buf[prefix_off..prefix_off + prefix.len()].copy_from_slice(prefix);
        let suffix_off = prefix_off + prefix.len();
        buf[suffix_off..suffix_off + suffix.len()].copy_from_slice(suffix);
        let val_off = suffix_off + suffix.len();
        buf[val_off..val_off + 8].copy_from_slice(&1.25f64.to_le_bytes());
        buf[val_off + 8] = 0;
        buf[val_off + 9] = b'd';

        let root_start = val_off + 12;
        buf[16..20].copy_from_slice(&(root_start as u32).to_le_bytes());

        // n_bloom_words = 0, n_buckets = 1
        buf[root_start..root_start + 4].copy_from_slice(&0u32.to_le_bytes());
        buf[root_start + 4..root_start + 8].copy_from_slice(&1u32.to_le_bytes());
        // bucket[0] = 0..2
        buf[root_start + 8..root_start + 12].copy_from_slice(&0u32.to_le_bytes());

        // item 0: parent segment
        let item0 = root_start + 12;
        buf[item0..item0 + 4].copy_from_slice(&djb_hash(prefix).to_le_bytes());
        buf[item0 + 4..item0 + 8].copy_from_slice(&0xffff_ffffu32.to_le_bytes());
        buf[item0 + 8..item0 + 12].copy_from_slice(&(prefix_off as u32).to_le_bytes());
        buf[item0 + 12..item0 + 14].copy_from_slice(&(prefix.len() as u16).to_le_bytes());
        buf[item0 + 14] = b'L';

        // item 1: leaf value
        let item1 = item0 + 24;
        buf[item1..item1 + 4].copy_from_slice(&djb_hash(suffix).to_le_bytes());
        buf[item1 + 4..item1 + 8].copy_from_slice(&0u32.to_le_bytes());
        buf[item1 + 8..item1 + 12].copy_from_slice(&(suffix_off as u32).to_le_bytes());
        buf[item1 + 12..item1 + 14].copy_from_slice(&(suffix.len() as u16).to_le_bytes());
        buf[item1 + 14] = b'v';
        buf[item1 + 16..item1 + 20].copy_from_slice(&(val_off as u32).to_le_bytes());
        buf[item1 + 20..item1 + 24].copy_from_slice(&((val_off + 10) as u32).to_le_bytes());

        let root_end = item1 + 24;
        buf[20..24].copy_from_slice(&(root_end as u32).to_le_bytes());

        assert_eq!(
            parse_gvdb_f64(
                &buf[..root_end],
                "/org/gnome/desktop/interface/text-scaling-factor"
            ),
            Some(1.25)
        );
    }
}
