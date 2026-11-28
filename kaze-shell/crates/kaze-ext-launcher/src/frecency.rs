use kaze_core::layout::xdg_state_home;
use kaze_core::theme::write_atomic;
use serde::Deserialize;
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Deserialize, Default)]
pub struct FrecencyEntry {
    pub count: u32,
    pub last_used_secs: u64,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct FrecencyStore {
    #[serde(default)]
    pub apps: HashMap<String, FrecencyEntry>,
}

impl FrecencyStore {
    pub fn default_path() -> Option<PathBuf> {
        xdg_state_home().ok().map(|d| d.join("frecency.toml"))
    }

    pub fn load(path: &Path) -> Self {
        let Ok(raw) = fs::read_to_string(path) else {
            return Self::default();
        };
        toml::from_str(&raw).unwrap_or_default()
    }

    pub fn save(&self, path: &Path) {
        let mut body = String::from("[apps]\n");
        let mut keys: Vec<&String> = self.apps.keys().collect();
        keys.sort();
        for k in keys {
            if let Some(e) = self.apps.get(k) {
                body.push_str(&format!(
                    "\"{}\" = {{ count = {}, last_used_secs = {} }}\n",
                    k.escape_default(),
                    e.count,
                    e.last_used_secs
                ));
            }
        }
        let _ = write_atomic(path, &body);
    }

    pub fn record_launch(&mut self, app_id: &str) {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        self.record_launch_at(app_id, now);
    }

    pub fn record_launch_at(&mut self, app_id: &str, now_secs: u64) {
        let entry = self.apps.entry(app_id.to_string()).or_default();
        entry.count = entry.count.saturating_add(1);
        entry.last_used_secs = now_secs;
    }

    pub fn score_at(&self, app_id: &str, now_secs: u64) -> i32 {
        let Some(entry) = self.apps.get(app_id) else {
            return 0;
        };
        let age_hours = now_secs.saturating_sub(entry.last_used_secs) as f64 / 3600.0;
        let recency = if age_hours <= 4.0 {
            100.0
        } else if age_hours <= 24.0 {
            70.0
        } else if age_hours <= 24.0 * 7.0 {
            40.0
        } else {
            15.0 * (0.5f64).powf(age_hours / (24.0 * 14.0))
        };
        ((f64::from(entry.count.min(50)) * recency) * 0.5).round() as i32
    }

    pub fn score(&self, app_id: &str) -> i32 {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        self.score_at(app_id, now)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frecency_decays_over_time_and_persists() {
        let mut store = FrecencyStore::default();
        store.record_launch_at("foot.desktop", 10_000_000);
        store.record_launch_at("firefox.desktop", 10_000_000 - 30 * 86_400);
        assert!(store.score_at("foot.desktop", 10_000_100) > store.score_at("firefox.desktop", 10_000_100));

        let dir = std::env::temp_dir().join("kaze-frecency-test");
        let _ = fs::create_dir_all(&dir);
        let file = dir.join("frecency.toml");
        store.save(&file);
        let loaded = FrecencyStore::load(&file);
        assert_eq!(loaded.apps.get("foot.desktop").map(|e| e.count), Some(1));
        let _ = fs::remove_dir_all(&dir);
    }
}
