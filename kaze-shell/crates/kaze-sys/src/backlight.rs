use kaze_core::BacklightState;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const BACKLIGHT_ROOT: &str = "/sys/class/backlight";

/// Returns the first usable `/sys/class/backlight/<dev>` directory, if any exists.
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

/// Steps screen brightness by `delta_pct` (e.g. +5 or -5) via `brightnessctl`
/// (with direct sysfs fallback) and returns the updated state if a backlight exists.
pub fn step_backlight(delta_pct: i32) -> Option<BacklightState> {
    let dir = discover_device()?;
    let arg = if delta_pct >= 0 {
        format!("+{}%", delta_pct.min(100))
    } else {
        format!("{}%-", delta_pct.unsigned_abs().min(100))
    };

    let ran_ctl = Command::new("brightnessctl")
        .args(["set", &arg])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success());

    if !ran_ctl {
        if let (Ok(cur_s), Ok(max_s)) = (
            fs::read_to_string(dir.join("brightness")),
            fs::read_to_string(dir.join("max_brightness")),
        ) {
            if let (Ok(cur), Ok(max)) = (cur_s.trim().parse::<i64>(), max_s.trim().parse::<i64>()) {
                if max > 0 {
                    let step = (max * i64::from(delta_pct)) / 100;
                    let next = (cur + step).clamp(1, max);
                    let _ = fs::write(dir.join("brightness"), next.to_string());
                }
            }
        }
    }

    read_backlight_from_dir(&dir)
}

/// Sets absolute screen brightness percentage (`1..=100`) via `brightnessctl`
/// (with direct sysfs fallback) and returns the updated state if a backlight exists.
pub fn set_backlight(pct: u8) -> Option<BacklightState> {
    let dir = discover_device()?;
    let clamped = pct.clamp(1, 100);
    let arg = format!("{clamped}%");

    let ran_ctl = Command::new("brightnessctl")
        .args(["set", &arg])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success());

    if !ran_ctl {
        if let Ok(max_s) = fs::read_to_string(dir.join("max_brightness")) {
            if let Ok(max) = max_s.trim().parse::<i64>() {
                if max > 0 {
                    let next = ((max * i64::from(clamped)) / 100).clamp(1, max);
                    let _ = fs::write(dir.join("brightness"), next.to_string());
                }
            }
        }
    }

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
