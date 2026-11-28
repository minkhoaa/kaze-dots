use calloop::channel::Sender as CalloopSender;
use kaze_core::crypto::check_network_allowed;
use kaze_core::{SystemEvent, WeatherConfig, WeatherDaily, WeatherHourly, WeatherState};
use std::env;
use std::fs;
use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::process::Command;
use tokio::sync::mpsc;

#[derive(Debug, Clone)]
pub enum WeatherCmd {
    Configure {
        cfg: WeatherConfig,
        offline_mode: bool,
    },
    SetOfflineMode(bool),
    RefreshNow,
}

fn weather_cache_path() -> PathBuf {
    let base = env::var_os("XDG_CACHE_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| {
            env::var_os("HOME")
                .filter(|v| !v.is_empty())
                .map(|h| PathBuf::from(h).join(".cache"))
        })
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    base.join("kaze-shell").join("weather.json")
}

fn load_cached_weather() -> Option<WeatherState> {
    let raw = fs::read_to_string(weather_cache_path()).ok()?;
    let mut st: WeatherState = serde_json::from_str(&raw).ok()?;
    st.stale = true;
    Some(st)
}

fn save_cached_weather(state: &WeatherState) {
    let path = weather_cache_path();
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    if let Ok(json) = serde_json::to_string(state) {
        let _ = fs::write(path, json);
    }
}

pub fn wmo_condition_label(code: u32) -> String {
    match code {
        0 => "Clear".into(),
        1..=3 => "Partly Cloudy".into(),
        45 | 48 => "Fog".into(),
        51..=57 => "Drizzle".into(),
        61..=67 | 80..=82 => "Rain".into(),
        71..=77 | 85 | 86 => "Snow".into(),
        95..=99 => "Thunderstorm".into(),
        _ => "Cloudy".into(),
    }
}

pub fn parse_open_meteo_json(raw: &str, city: &str, now_secs: u64) -> Result<WeatherState, String> {
    let val: serde_json::Value =
        serde_json::from_str(raw).map_err(|e| format!("invalid open-meteo JSON: {e}"))?;
    let cur = val
        .get("current")
        .ok_or_else(|| "missing current weather block".to_string())?;
    let temp_c = cur
        .get("temperature_2m")
        .and_then(|v| v.as_f64())
        .unwrap_or(0.0) as f32;
    let feels_like_c = cur
        .get("apparent_temperature")
        .and_then(|v| v.as_f64())
        .unwrap_or(f64::from(temp_c)) as f32;
    let humidity_pct = cur
        .get("relative_humidity_2m")
        .and_then(|v| v.as_u64())
        .unwrap_or(0)
        .min(100) as u8;
    let wind_kph = cur
        .get("wind_speed_10m")
        .and_then(|v| v.as_f64())
        .unwrap_or(0.0) as f32;
    let code = cur
        .get("weather_code")
        .and_then(|v| v.as_u64())
        .unwrap_or(0) as u32;

    let mut hourly = Vec::new();
    if let Some(h) = val.get("hourly") {
        let times = h.get("time").and_then(|v| v.as_array());
        let temps = h.get("temperature_2m").and_then(|v| v.as_array());
        let codes = h.get("weather_code").and_then(|v| v.as_array());
        if let (Some(ts), Some(tmps), Some(cs)) = (times, temps, codes) {
            for i in 0..ts.len().min(tmps.len()).min(cs.len()).min(8) {
                let time_raw = ts[i].as_str().unwrap_or("");
                let label = time_raw
                    .split('T')
                    .nth(1)
                    .unwrap_or(time_raw)
                    .chars()
                    .take(5)
                    .collect();
                hourly.push(WeatherHourly {
                    time_label: label,
                    temp_c: tmps[i].as_f64().unwrap_or(0.0) as f32,
                    condition: wmo_condition_label(cs[i].as_u64().unwrap_or(0) as u32),
                });
            }
        }
    }

    let mut daily = Vec::new();
    if let Some(d) = val.get("daily") {
        let dates = d.get("time").and_then(|v| v.as_array());
        let mins = d.get("temperature_2m_min").and_then(|v| v.as_array());
        let maxs = d.get("temperature_2m_max").and_then(|v| v.as_array());
        let codes = d.get("weather_code").and_then(|v| v.as_array());
        if let (Some(ds), Some(mns), Some(mxs), Some(cs)) = (dates, mins, maxs, codes) {
            for i in 0..ds.len().min(mns.len()).min(mxs.len()).min(cs.len()).min(7) {
                let date_label = ds[i].as_str().unwrap_or("").to_string();
                daily.push(WeatherDaily {
                    date_label,
                    min_c: mns[i].as_f64().unwrap_or(0.0) as f32,
                    max_c: mxs[i].as_f64().unwrap_or(0.0) as f32,
                    condition: wmo_condition_label(cs[i].as_u64().unwrap_or(0) as u32),
                });
            }
        }
    }

    Ok(WeatherState {
        available: true,
        stale: false,
        offline_blocked: false,
        temp_c,
        feels_like_c,
        humidity_pct,
        wind_kph,
        condition: wmo_condition_label(code),
        location_name: city.to_string(),
        updated_epoch_secs: now_secs,
        error: None,
        hourly,
        daily,
    })
}

async fn fetch_open_meteo(cfg: &WeatherConfig) -> Result<WeatherState, String> {
    let url = format!(
        "https://api.open-meteo.com/v1/forecast?latitude={:.4}&longitude={:.4}&current=temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m&hourly=temperature_2m,weather_code&daily=weather_code,temperature_2m_max,temperature_2m_min&timezone=auto",
        cfg.latitude, cfg.longitude
    );
    let out = Command::new("curl")
        .args(["-fsSL", "--max-time", "10", &url])
        .output()
        .await
        .map_err(|e| format!("curl launch failed: {e}"))?;
    if !out.status.success() {
        return Err(format!("curl failed with status {}", out.status));
    }
    let body = String::from_utf8_lossy(&out.stdout);
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    parse_open_meteo_json(&body, &cfg.city, now)
}

/// Weather fetcher using Open-Meteo API over `curl`, respecting `offline_mode` (0 network calls when offline).
pub async fn run_weather_task(
    event_tx: CalloopSender<SystemEvent>,
    mut cmd_rx: mpsc::UnboundedReceiver<WeatherCmd>,
) {
    let mut cfg = WeatherConfig::default();
    let mut offline_mode = true;
    let mut failure_streak = 0u32;

    if let Some(cached) = load_cached_weather() {
        let _ = event_tx.send(SystemEvent::WeatherUpdated(cached));
    }

    loop {
        let sleep_dur = if !cfg.enabled {
            Duration::from_secs(86400 * 365)
        } else if failure_streak > 0 {
            Duration::from_secs((60u64 << failure_streak.min(5)).min(3600))
        } else {
            Duration::from_secs(cfg.refresh_interval_mins.max(5) * 60)
        };

        let trigger = tokio::select! {
            cmd = cmd_rx.recv() => {
                let Some(cmd) = cmd else { break; };
                match cmd {
                    WeatherCmd::Configure { cfg: next, offline_mode: om } => {
                        cfg = next;
                        offline_mode = om;
                        cfg.enabled
                    }
                    WeatherCmd::SetOfflineMode(om) => {
                        offline_mode = om;
                        cfg.enabled
                    }
                    WeatherCmd::RefreshNow => cfg.enabled,
                }
            }
            _ = tokio::time::sleep(sleep_dur), if cfg.enabled => true,
        };

        if !trigger {
            continue;
        }
        if let Err(err) = check_network_allowed(offline_mode) {
            let mut st = load_cached_weather().unwrap_or_default();
            st.offline_blocked = true;
            st.error = Some(err.to_string());
            let _ = event_tx.send(SystemEvent::WeatherUpdated(st));
            continue;
        }
        match fetch_open_meteo(&cfg).await {
            Ok(st) => {
                failure_streak = 0;
                save_cached_weather(&st);
                let _ = event_tx.send(SystemEvent::WeatherUpdated(st));
            }
            Err(err) => {
                failure_streak = failure_streak.saturating_add(1);
                let mut st = load_cached_weather().unwrap_or_default();
                st.stale = true;
                st.error = Some(err);
                let _ = event_tx.send(SystemEvent::WeatherUpdated(st));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_open_meteo_response_and_blocks_network_in_offline_mode() {
        let sample = r#"{
            "current": {
                "temperature_2m": 27.5,
                "apparent_temperature": 30.1,
                "relative_humidity_2m": 78,
                "wind_speed_10m": 12.3,
                "weather_code": 61
            },
            "hourly": {
                "time": ["2026-11-28T13:00", "2026-11-28T14:00"],
                "temperature_2m": [28.0, 27.0],
                "weather_code": [61, 2]
            },
            "daily": {
                "time": ["2026-11-28", "2026-11-29"],
                "temperature_2m_min": [21.0, 20.0],
                "temperature_2m_max": [29.0, 28.0],
                "weather_code": [61, 1]
            }
        }"#;
        let st = parse_open_meteo_json(sample, "Hanoi", 1_700_000_000).expect("parse open-meteo");
        assert!(st.available);
        assert!(!st.stale);
        assert_eq!(st.condition, "Rain");
        assert_eq!(st.hourly.len(), 2);
        assert_eq!(st.hourly[0].time_label, "13:00");
        assert_eq!(st.daily.len(), 2);
        assert!(check_network_allowed(true).is_err());
    }
}
