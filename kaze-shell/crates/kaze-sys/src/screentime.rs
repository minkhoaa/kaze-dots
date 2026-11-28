use kaze_core::crypto::{EncryptedRecordStore, MasterKey};
use kaze_core::layout::xdg_state_home;
use kaze_core::{ScreenTimeAppUsage, ScreenTimeState};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(default)]
struct PersistedDay {
    total_secs: u64,
    hourly_secs: [u64; 24],
    apps: BTreeMap<String, u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(default)]
struct PersistedScreenTime {
    days: BTreeMap<u64, PersistedDay>, // epoch_day -> usage
}

/// Pure event-delta screen time tracker (zero polling timers):
/// updates ONLY on focus switches, idle/lock pause edges, or explicit reset/flush.
pub struct ScreenTimeTracker {
    enabled: bool,
    retention_days: u32,
    paused: bool,
    active_app: Option<String>,
    active_since_secs: Option<u64>,
    data: PersistedScreenTime,
    store_path: Option<PathBuf>,
    key: Option<MasterKey>,
}

impl ScreenTimeTracker {
    pub fn new(
        enabled: bool,
        retention_days: u32,
        store_path: Option<PathBuf>,
        key: Option<MasterKey>,
    ) -> Self {
        let mut tracker = Self {
            enabled,
            retention_days: retention_days.clamp(1, 90),
            paused: false,
            active_app: None,
            active_since_secs: None,
            data: PersistedScreenTime::default(),
            store_path,
            key,
        };
        tracker.load();
        tracker
    }

    pub fn default_store_path() -> Result<PathBuf, String> {
        Ok(xdg_state_home()?.join("kaze").join("screentime.enc"))
    }

    pub fn configure(&mut self, enabled: bool, retention_days: u32) {
        self.enabled = enabled;
        self.retention_days = retention_days.clamp(1, 90);
    }

    pub fn on_focus_change(&mut self, app_id: Option<&str>, now_secs: u64) -> ScreenTimeState {
        self.flush_elapsed(now_secs);
        self.active_app = app_id
            .map(|s| s.trim().to_ascii_lowercase())
            .filter(|s| !s.is_empty());
        self.active_since_secs = if self.enabled && !self.paused && self.active_app.is_some() {
            Some(now_secs)
        } else {
            None
        };
        self.prune_old_days(now_secs / 86400);
        self.save();
        self.snapshot(now_secs)
    }

    pub fn set_paused(&mut self, paused: bool, now_secs: u64) -> ScreenTimeState {
        if self.paused != paused {
            self.flush_elapsed(now_secs);
            self.paused = paused;
            if !paused && self.enabled && self.active_app.is_some() {
                self.active_since_secs = Some(now_secs);
            } else {
                self.active_since_secs = None;
            }
            self.save();
        }
        self.snapshot(now_secs)
    }

    pub fn reset(&mut self, now_secs: u64) -> ScreenTimeState {
        self.data.days.clear();
        self.active_since_secs = if self.enabled && !self.paused && self.active_app.is_some() {
            Some(now_secs)
        } else {
            None
        };
        self.save();
        self.snapshot(now_secs)
    }

    fn flush_elapsed(&mut self, now_secs: u64) {
        if !self.enabled || self.paused {
            self.active_since_secs = None;
            return;
        }
        let (Some(ref app), Some(since)) = (&self.active_app, self.active_since_secs) else {
            return;
        };
        if now_secs <= since {
            return;
        }
        // Cap single transition delta at 4 hours cleanly against clock jumps
        let delta = (now_secs - since).min(14_400);
        let day = since / 86400;
        let hour = ((since % 86400) / 3600).min(23) as usize;
        let entry = self.data.days.entry(day).or_default();
        entry.total_secs = entry.total_secs.saturating_add(delta);
        entry.hourly_secs[hour] = entry.hourly_secs[hour].saturating_add(delta);
        *entry.apps.entry(app.clone()).or_insert(0) += delta;
        self.active_since_secs = Some(now_secs);
    }

    fn prune_old_days(&mut self, today_day: u64) {
        let min_day = today_day.saturating_sub(u64::from(self.retention_days));
        self.data.days.retain(|&d, _| d >= min_day);
    }

    pub fn snapshot(&self, now_secs: u64) -> ScreenTimeState {
        let today = now_secs / 86400;
        let today_entry = self.data.days.get(&today).cloned().unwrap_or_default();
        let top_apps_today = top_apps_for_range(&self.data.days, today, 1);
        let top_apps_3d = top_apps_for_range(&self.data.days, today, 3);
        let top_apps_14d = top_apps_for_range(&self.data.days, today, 14);
        let three_day_secs = day_series(&self.data.days, today, 3);
        let fourteen_day_secs = day_series(&self.data.days, today, 14);
        ScreenTimeState {
            enabled: self.enabled,
            paused: self.paused,
            today_total_secs: today_entry.total_secs,
            today_hourly_secs: today_entry.hourly_secs,
            three_day_secs,
            fourteen_day_secs,
            top_apps_today,
            top_apps_3d,
            top_apps_14d,
        }
    }

    fn load(&mut self) {
        let (Some(ref path), Some(ref key)) = (&self.store_path, &self.key) else {
            return;
        };
        let (records, _) = EncryptedRecordStore::load_records(path, key);
        if let Some(first) = records.first() {
            if let Ok(parsed) = serde_json::from_slice::<PersistedScreenTime>(first) {
                self.data = parsed;
            }
        }
    }

    fn save(&self) {
        let (Some(ref path), Some(ref key)) = (&self.store_path, &self.key) else {
            return;
        };
        save_encrypted_json(path, key, &self.data);
    }
}

fn save_encrypted_json(path: &Path, key: &MasterKey, val: &PersistedScreenTime) {
    if let Ok(bytes) = serde_json::to_vec(val) {
        let _ = EncryptedRecordStore::save_records(path, key, &[bytes.as_slice()]);
    }
}

fn top_apps_for_range(
    days: &BTreeMap<u64, PersistedDay>,
    today: u64,
    span: u64,
) -> Vec<ScreenTimeAppUsage> {
    let min_day = today.saturating_sub(span.saturating_sub(1));
    let mut totals: BTreeMap<String, u64> = BTreeMap::new();
    for (&day, entry) in days {
        if day >= min_day && day <= today {
            for (app, &secs) in &entry.apps {
                *totals.entry(app.clone()).or_insert(0) += secs;
            }
        }
    }
    let mut out: Vec<ScreenTimeAppUsage> = totals
        .into_iter()
        .map(|(app_id, seconds)| ScreenTimeAppUsage { app_id, seconds })
        .collect();
    out.sort_by_key(|a| std::cmp::Reverse(a.seconds));
    out.truncate(8);
    out
}

fn day_series(days: &BTreeMap<u64, PersistedDay>, today: u64, span: u64) -> Vec<(String, u64)> {
    let start = today.saturating_sub(span.saturating_sub(1));
    (start..=today)
        .map(|d| {
            let secs = days.get(&d).map_or(0, |e| e.total_secs);
            (format!("D{}", d % 100), secs)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn accumulates_focus_deltas_pauses_on_idle_and_persists_encrypted() {
        let dir = std::env::temp_dir().join(format!("kaze-st-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let path = dir.join("st.enc");
        let key = MasterKey::generate();
        let base_ts = 1_700_006_400u64; // divisible-ish epoch day

        let mut tracker = ScreenTimeTracker::new(true, 14, Some(path.clone()), Some(key.clone()));
        tracker.on_focus_change(Some("firefox"), base_ts);
        let st1 = tracker.on_focus_change(Some("foot"), base_ts + 120);
        assert_eq!(st1.today_total_secs, 120);
        assert_eq!(st1.top_apps_today[0].app_id, "firefox");

        // Pause skips elapsed time while idle/locked
        tracker.set_paused(true, base_ts + 180);
        let st2 = tracker.on_focus_change(Some("foot"), base_ts + 500);
        assert_eq!(st2.today_total_secs, 180);

        // Encrypted file reload preserves data
        let tracker2 = ScreenTimeTracker::new(true, 14, Some(path), Some(key));
        let reloaded = tracker2.snapshot(base_ts + 500);
        assert_eq!(reloaded.today_total_secs, 180);

        let _ = fs::remove_dir_all(&dir);
    }
}
