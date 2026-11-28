use kaze_core::BacklightState;
use std::fs;
use std::path::{Path, PathBuf};
use zbus::{Connection, Proxy};

const BACKLIGHT_ROOT: &str = "/sys/class/backlight";
const LOGIND_DEST: &str = "org.freedesktop.login1";
const LOGIND_AUTO_SESSION: &str = "/org/freedesktop/login1/session/auto";
const LOGIND_SESSION_IFACE: &str = "org.freedesktop.login1.Session";

pub fn discover_device() -> Option<PathBuf> {
    let entries = fs::read_dir(BACKLIGHT_ROOT).ok()?;
    let mut dirs: Vec<PathBuf> = entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.join("brightness").exists() && p.join("max_brightness").exists())
        .collect();
    dirs.sort();
    dirs.into_iter().next()
}

pub fn read_backlight_from_dir(dev_dir: &Path) -> Option<BacklightState> {
    let cur = fs::read_to_string(dev_dir.join("brightness"))
        .ok()?
        .trim()
        .parse::<u64>()
        .ok()?;
    let max = fs::read_to_string(dev_dir.join("max_brightness"))
        .ok()?
        .trim()
        .parse::<u64>()
        .ok()?;
    if max == 0 {
        return None;
    }
    let pct = ((cur.saturating_mul(100) + max / 2) / max).min(100) as u8;
    let device = dev_dir
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("backlight")
        .to_string();
    Some(BacklightState {
        present: true,
        percentage: pct,
        device,
    })
}

pub fn read_backlight() -> Option<BacklightState> {
    let dir = discover_device()?;
    read_backlight_from_dir(&dir)
}

async fn apply_raw_brightness(
    conn: Option<&Connection>,
    dir: &Path,
    raw_val: u32,
) -> Result<(), ()> {
    let device = dir
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("backlight");
    if let Some(c) = conn {
        if let Ok(proxy) = Proxy::new(c, LOGIND_DEST, LOGIND_AUTO_SESSION, LOGIND_SESSION_IFACE).await
        {
            if proxy
                .call::<_, _, ()>("SetBrightness", &("backlight", device, raw_val))
                .await
                .is_ok()
            {
                return Ok(());
            }
        }
    }
    fs::write(dir.join("brightness"), raw_val.to_string()).map_err(|_| ())
}

/// Steps screen brightness by `delta_pct` via `logind.Session.SetBrightness`
/// with direct sysfs fallback (0 `brightnessctl` dependency).
pub async fn step_backlight_async(conn: Option<&Connection>, delta_pct: i32) -> Option<BacklightState> {
    let dir = discover_device()?;
    let cur = fs::read_to_string(dir.join("brightness"))
        .ok()?
        .trim()
        .parse::<i64>()
        .ok()?;
    let max = fs::read_to_string(dir.join("max_brightness"))
        .ok()?
        .trim()
        .parse::<i64>()
        .ok()?;
    if max <= 0 {
        return None;
    }
    let step = (max * i64::from(delta_pct)) / 100;
    let next = (cur + step).clamp(1, max) as u32;
    let _ = apply_raw_brightness(conn, &dir, next).await;
    read_backlight_from_dir(&dir)
}

/// Sets absolute screen brightness percentage (`1..=100`) via `logind.Session.SetBrightness`
/// with direct sysfs fallback.
pub async fn set_backlight_async(conn: Option<&Connection>, pct: u8) -> Option<BacklightState> {
    let dir = discover_device()?;
    let max = fs::read_to_string(dir.join("max_brightness"))
        .ok()?
        .trim()
        .parse::<i64>()
        .ok()?;
    if max <= 0 {
        return None;
    }
    let clamped = pct.clamp(1, 100);
    let next = ((max * i64::from(clamped)) / 100).clamp(1, max) as u32;
    let _ = apply_raw_brightness(conn, &dir, next).await;
    read_backlight_from_dir(&dir)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_sysfs_backlight_percentage() {
        let dir = std::env::temp_dir().join(format!("kaze-sys-bl-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("mkdir");
        fs::write(dir.join("brightness"), "1200\n").expect("write brightness");
        fs::write(dir.join("max_brightness"), "2400\n").expect("write max");

        let st = read_backlight_from_dir(&dir).expect("backlight state");
        assert!(st.present);
        assert_eq!(st.percentage, 50);

        let _ = fs::remove_dir_all(&dir);
    }
}
