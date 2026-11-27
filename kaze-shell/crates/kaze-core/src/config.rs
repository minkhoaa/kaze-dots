use serde::{Deserialize, Serialize};
use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use crate::state::ThemeMode;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum BarPosition {
    #[default]
    Left,
    Right,
    Top,
    Bottom,
}

impl BarPosition {
    pub fn is_vertical(self) -> bool {
        matches!(self, Self::Left | Self::Right)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct ThemeConfig {
    pub mode: ThemeMode,
    pub palette: String,
    pub palettes_dir: Option<PathBuf>,
}

impl Default for ThemeConfig {
    fn default() -> Self {
        Self {
            mode: ThemeMode::Dark,
            palette: "Kanagawa".to_string(),
            palettes_dir: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct BarConfig {
    pub enabled: bool,
    pub position: BarPosition,
    /// When `true`, renders a floating island pill (`kaze-island` namespace) with explicit `length`.
    pub island_mode: bool,
    pub thickness: u32,
    /// Length along the main axis (`0` spans the full output edge; `> 0` centers a floating pill).
    pub length: u32,
    pub margin_edge: i32,
    pub margin_ends: i32,
    pub corner_radius: f32,
    pub border_width: f32,
    pub background_opacity: f32,
    pub exclusive: bool,
    pub persistent_workspaces: u32,
    pub font: String,
    pub end_slots: Vec<String>,
}

impl Default for BarConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            position: BarPosition::Left,
            island_mode: false,
            thickness: 42,
            length: 0,
            margin_edge: 8,
            margin_ends: 8,
            corner_radius: 0.0,
            border_width: 2.0,
            background_opacity: 0.94,
            exclusive: true,
            persistent_workspaces: 5,
            font: "JetBrainsMono Nerd Font".to_string(),
            end_slots: vec![
                "display".to_string(),
                "net".to_string(),
                "vol".to_string(),
                "bat".to_string(),
                "notifications".to_string(),
            ],
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct OsdConfig {
    pub enabled: bool,
    pub position: String,
    pub width: u32,
    pub height: u32,
    pub offset_x: i32,
    pub offset_y: i32,
    pub timeout_ms: u64,
}

impl Default for OsdConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            position: "top_right".to_string(),
            width: 224,
            height: 48,
            offset_x: 12,
            offset_y: 12,
            timeout_ms: 1500,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct NotifyConfig {
    pub enabled: bool,
    pub position: String,
    pub width: u32,
    pub offset_x: i32,
    pub offset_y: i32,
    pub gap: i32,
    pub max_visible: usize,
    pub history_limit: usize,
    pub default_timeout_ms: u64,
    pub low_timeout_ms: u64,
}

impl Default for NotifyConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            position: "top_right".to_string(),
            width: 340,
            offset_x: 12,
            offset_y: 12,
            gap: 8,
            max_visible: 4,
            history_limit: 50,
            default_timeout_ms: 5000,
            low_timeout_ms: 3500,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct DisplayConfig {
    pub left_click_cmd: Vec<String>,
    pub right_click_cmd: Vec<String>,
}

impl Default for DisplayConfig {
    fn default() -> Self {
        Self {
            left_click_cmd: vec!["kaze-display".to_string(), "--menu".to_string()],
            right_click_cmd: vec![
                "kaze-display".to_string(),
                "toggle-window-share".to_string(),
            ],
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct Config {
    pub theme: ThemeConfig,
    pub bar: BarConfig,
    pub osd: OsdConfig,
    pub notifications: NotifyConfig,
    pub display: DisplayConfig,
}

pub fn xdg_config_home() -> Result<PathBuf, String> {
    if let Some(xdg) = env::var_os("XDG_CONFIG_HOME").filter(|v| !v.is_empty()) {
        let path = PathBuf::from(xdg);
        return if path.is_absolute() {
            Ok(path)
        } else {
            Err("XDG_CONFIG_HOME must be an absolute path".into())
        };
    }
    env::var_os("HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .map(|p| p.join(".config"))
        .ok_or_else(|| "set HOME or XDG_CONFIG_HOME to an absolute path".into())
}

impl Config {
    pub fn default_dir() -> Result<PathBuf, String> {
        Ok(xdg_config_home()?.join("kaze-shell"))
    }

    pub fn default_path() -> Result<PathBuf, String> {
        Ok(Self::default_dir()?.join("config.toml"))
    }

    pub fn load_from_path(path: &Path) -> Result<Self, String> {
        let raw = match fs::read_to_string(path) {
            Ok(s) => s,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(Self::default()),
            Err(err) => return Err(format!("failed reading {}: {err}", path.display())),
        };
        Self::parse_toml(&raw).map_err(|e| format!("invalid config {}: {e}", path.display()))
    }

    pub fn parse_toml(raw: &str) -> Result<Self, String> {
        let mut cfg: Self = toml::from_str(raw).map_err(|e| e.to_string())?;
        cfg.validate()?;
        Ok(cfg)
    }

    pub fn validate(&mut self) -> Result<(), String> {
        if self.bar.thickness < 16 || self.bar.thickness > 256 {
            return Err(format!(
                "bar.thickness={} out of range (16..=256)",
                self.bar.thickness
            ));
        }
        if !self.bar.background_opacity.is_finite() {
            return Err("bar.background_opacity must be finite".to_string());
        }
        if !(0.0..=1.0).contains(&self.bar.background_opacity) {
            eprintln!("kaze-shell: clamping bar.background_opacity to 0..=1");
            self.bar.background_opacity = self.bar.background_opacity.clamp(0.0, 1.0);
        }
        if !self.bar.corner_radius.is_finite() || self.bar.corner_radius < 0.0 {
            return Err("bar.corner_radius must be finite and >= 0".to_string());
        }
        if !self.bar.border_width.is_finite() || self.bar.border_width < 0.0 {
            return Err("bar.border_width must be finite and >= 0".to_string());
        }
        if !(1..=20).contains(&self.bar.persistent_workspaces) {
            eprintln!("kaze-shell: clamping bar.persistent_workspaces to 1..=20");
            self.bar.persistent_workspaces = self.bar.persistent_workspaces.clamp(1, 20);
        }
        self.notifications.width = self.notifications.width.clamp(220, 640);
        self.notifications.gap = self.notifications.gap.clamp(0, 32);
        self.notifications.max_visible = self.notifications.max_visible.clamp(1, 10);
        self.notifications.history_limit = self.notifications.history_limit.clamp(1, 200);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_config_matches_omarchy_vertical_rail() {
        let cfg = Config::default();
        assert_eq!(cfg.bar.position, BarPosition::Left);
        assert_eq!(cfg.bar.thickness, 42);
        assert_eq!(cfg.bar.margin_edge, 8);
        assert_eq!(cfg.bar.corner_radius, 0.0);
        assert_eq!(cfg.theme.mode, ThemeMode::Dark);
        assert_eq!(cfg.theme.palette, "Kanagawa");
    }

    #[test]
    fn partial_and_unknown_keys_parse_cleanly() {
        let raw = r#"
[theme]
mode = "light"
future_option = true

[bar]
position = "top"
island_mode = true
thickness = 36
length = 480
corner_radius = 18.0

[display]
left_click_cmd = ["example"]
"#;
        let cfg = Config::parse_toml(raw).expect("valid partial config");
        assert_eq!(cfg.theme.mode, ThemeMode::Light);
        assert_eq!(cfg.bar.position, BarPosition::Top);
        assert!(cfg.bar.island_mode);
        assert_eq!(cfg.bar.length, 480);
        assert_eq!(cfg.bar.corner_radius, 18.0);
        assert_eq!(cfg.theme.palette, ThemeConfig::default().palette);
        assert_eq!(cfg.display.left_click_cmd, ["example"]);
        assert_eq!(
            cfg.display.right_click_cmd,
            DisplayConfig::default().right_click_cmd
        );
    }

    #[test]
    fn legacy_numeric_bounds_are_normalized() {
        let cfg = Config::parse_toml("[bar]\nbackground_opacity=2.0\npersistent_workspaces=0")
            .expect("normalized config");
        assert_eq!(cfg.bar.background_opacity, 1.0);
        assert_eq!(cfg.bar.persistent_workspaces, 1);
    }

    #[test]
    fn broken_toml_returns_err() {
        let err = Config::parse_toml("[bar\nthickness = oops");
        assert!(err.is_err());
    }
}
