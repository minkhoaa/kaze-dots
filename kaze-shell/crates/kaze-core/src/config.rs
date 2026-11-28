use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use crate::layout::{xdg_state_home, LayoutPreset};
use crate::state::ThemeMode;
use crate::surface::Color;
use crate::theme::write_atomic;

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
                "tray".to_string(),
                "display".to_string(),
                "net".to_string(),
                "vol".to_string(),
                "bat".to_string(),
                "notifications".to_string(),
                "cc".to_string(),
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

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct LauncherConfig {
    pub enabled: bool,
    pub width: u32,
    pub max_rows: usize,
    pub offset_y: i32,
}

impl Default for LauncherConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            width: 560,
            max_rows: 9,
            offset_y: 120,
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum IslandStyle {
    #[default]
    Floating,
    Notch,
}

impl IslandStyle {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Floating => "floating",
            Self::Notch => "notch",
        }
    }

    pub fn from_name(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "floating" | "pill" => Some(Self::Floating),
            "notch" | "concave" => Some(Self::Notch),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct IslandConfig {
    /// Forces Dynamic Island visible even outside the `island` layout preset.
    pub enabled: bool,
    pub style: IslandStyle,
    pub corner_radius: f32,
    pub margin_top: i32,
    pub absorb_osd: bool,
    pub absorb_notify: bool,
    pub auto_collapse_ms: u64,
}

impl Default for IslandConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            style: IslandStyle::Floating,
            corner_radius: 20.0,
            margin_top: 8,
            absorb_osd: true,
            absorb_notify: true,
            auto_collapse_ms: 4500,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct LayoutConfig {
    pub preset: LayoutPreset,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct WallpaperConfig {
    pub enabled: bool,
    pub path: Option<PathBuf>,
    pub directory: Option<PathBuf>,
    pub dynamic_palette: bool,
}

impl Default for WallpaperConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            path: None,
            directory: None,
            dynamic_palette: true,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct GeneralConfig {
    pub locale: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct NetworkConfig {
    pub offline_mode: bool,
}

impl Default for NetworkConfig {
    fn default() -> Self {
        Self { offline_mode: true }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct HooksConfig {
    pub timeout_secs: u64,
    pub started: Option<String>,
    pub stopping: Option<String>,
    pub wallpaper_changed: Option<String>,
    pub theme_mode_changed: Option<String>,
    pub layout_changed: Option<String>,
    pub session_locked: Option<String>,
    pub session_unlocked: Option<String>,
    pub battery_percentage_changed: Option<String>,
    pub ac_state_changed: Option<String>,
    pub power_profile_changed: Option<String>,
    pub dnd_changed: Option<String>,
    pub rebooting: Option<String>,
    pub suspending: Option<String>,
}

impl Default for HooksConfig {
    fn default() -> Self {
        Self {
            timeout_secs: 10,
            started: None,
            stopping: None,
            wallpaper_changed: None,
            theme_mode_changed: None,
            layout_changed: None,
            session_locked: None,
            session_unlocked: None,
            battery_percentage_changed: None,
            ac_state_changed: None,
            power_profile_changed: None,
            dnd_changed: None,
            rebooting: None,
            suspending: None,
        }
    }
}

impl HooksConfig {
    pub fn command_for(&self, event: &str) -> Option<&str> {
        let cmd = match event {
            "started" => self.started.as_deref(),
            "stopping" => self.stopping.as_deref(),
            "wallpaper_changed" => self.wallpaper_changed.as_deref(),
            "theme_mode_changed" => self.theme_mode_changed.as_deref(),
            "layout_changed" => self.layout_changed.as_deref(),
            "session_locked" => self.session_locked.as_deref(),
            "session_unlocked" => self.session_unlocked.as_deref(),
            "battery_percentage_changed" => self.battery_percentage_changed.as_deref(),
            "ac_state_changed" => self.ac_state_changed.as_deref(),
            "power_profile_changed" => self.power_profile_changed.as_deref(),
            "dnd_changed" => self.dnd_changed.as_deref(),
            "rebooting" => self.rebooting.as_deref(),
            "suspending" => self.suspending.as_deref(),
            _ => None,
        };
        cmd.map(str::trim).filter(|s| !s.is_empty())
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct AccessibilityConfig {
    pub font_scale: f32,
    pub high_contrast: bool,
    pub sync_gnome_text_scale: bool,
}

impl Default for AccessibilityConfig {
    fn default() -> Self {
        Self {
            font_scale: 1.0,
            high_contrast: false,
            sync_gnome_text_scale: false,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct InputKeybindsConfig {
    pub select_all: String,
    pub copy: String,
    pub paste: String,
    pub cut: String,
    pub word_left: String,
    pub word_right: String,
    pub clear_line: String,
    pub kill_to_end: String,
    pub delete_word: String,
    pub toggle_layout: String,
}

impl Default for InputKeybindsConfig {
    fn default() -> Self {
        Self {
            select_all: "Ctrl+A".into(),
            copy: "Ctrl+C".into(),
            paste: "Ctrl+V".into(),
            cut: "Ctrl+X".into(),
            word_left: "Ctrl+Left".into(),
            word_right: "Ctrl+Right".into(),
            clear_line: "Ctrl+U".into(),
            kill_to_end: "Ctrl+K".into(),
            delete_word: "Ctrl+W".into(),
            toggle_layout: "Tab".into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct InputConfig {
    pub keybinds: InputKeybindsConfig,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct ClipboardConfig {
    pub enabled: bool,
    pub persist: bool,
    pub max_items: usize,
    pub max_item_bytes: usize,
    pub ignore_mimes: Vec<String>,
}

impl Default for ClipboardConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            persist: true,
            max_items: 200,
            max_item_bytes: 10 * 1024 * 1024,
            ignore_mimes: vec![
                "x-kde-passwordManagerHint".into(),
                "application/x-keepassxc-secret".into(),
            ],
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct BrightnessMonitorConfig {
    pub min_pct: u8,
    pub max_pct: u8,
    pub i2c_bus: Option<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct BrightnessConfig {
    pub step_pct: u8,
    pub monitors: BTreeMap<String, BrightnessMonitorConfig>,
}

impl Default for BrightnessConfig {
    fn default() -> Self {
        Self {
            step_pct: 5,
            monitors: BTreeMap::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct LocationConfig {
    pub lat: f64,
    pub lon: f64,
    pub auto_nightlight: bool,
    pub auto_brightness: bool,
    pub day_temp_k: u32,
    pub night_temp_k: u32,
    pub day_brightness: u8,
    pub night_brightness: u8,
    pub fallback_sunrise: String,
    pub fallback_sunset: String,
}

impl Default for LocationConfig {
    fn default() -> Self {
        Self {
            lat: 21.0285,
            lon: 105.8542,
            auto_nightlight: false,
            auto_brightness: false,
            day_temp_k: 6500,
            night_temp_k: 4000,
            day_brightness: 90,
            night_brightness: 45,
            fallback_sunrise: "06:30".into(),
            fallback_sunset: "18:00".into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct AudioConfig {
    pub spectrum_frame_rate: u32,
}

impl Default for AudioConfig {
    fn default() -> Self {
        Self {
            spectrum_frame_rate: 30,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct PrivacyConfig {
    pub hide_on_share: Vec<String>,
}

impl Default for PrivacyConfig {
    fn default() -> Self {
        Self {
            hide_on_share: vec!["KeePassXC".into(), "org.keepassxc.KeePassXC".into()],
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct IdleCustomStage {
    pub timeout_secs: u64,
    pub on_timeout: String,
    pub on_resume: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct IdleStageProfileConfig {
    pub dim_timeout_secs: u64,
    pub dim_percent: u8,
    pub lock_timeout_secs: u64,
    pub dpms_timeout_secs: u64,
    pub suspend_timeout_secs: u64,
    pub custom_stages: Vec<IdleCustomStage>,
}

impl Default for IdleStageProfileConfig {
    fn default() -> Self {
        Self {
            dim_timeout_secs: 150,
            dim_percent: 15,
            lock_timeout_secs: 300,
            dpms_timeout_secs: 330,
            suspend_timeout_secs: 0,
            custom_stages: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct IdleBehaviorConfig {
    pub ac: IdleStageProfileConfig,
    pub battery: IdleStageProfileConfig,
}

impl Default for IdleBehaviorConfig {
    fn default() -> Self {
        Self {
            ac: IdleStageProfileConfig {
                dim_timeout_secs: 240,
                dim_percent: 20,
                lock_timeout_secs: 420,
                dpms_timeout_secs: 450,
                suspend_timeout_secs: 0,
                custom_stages: Vec::new(),
            },
            battery: IdleStageProfileConfig {
                dim_timeout_secs: 120,
                dim_percent: 15,
                lock_timeout_secs: 240,
                dpms_timeout_secs: 270,
                suspend_timeout_secs: 600,
                custom_stages: Vec::new(),
            },
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct IdleConfig {
    pub enabled: bool,
    pub lock_before_sleep: bool,
    pub inhibit_on_fullscreen: bool,
    pub inhibit_on_audio: bool,
    pub behavior: IdleBehaviorConfig,
}

impl Default for IdleConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            lock_before_sleep: true,
            inhibit_on_fullscreen: true,
            inhibit_on_audio: false,
            behavior: IdleBehaviorConfig::default(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct LockscreenConfig {
    pub pam_service: String,
    pub fprintd: bool,
    pub grace_secs: u64,
    pub dnd: bool,
    pub media_controls: bool,
    pub media_keys: bool,
    pub blur: bool,
    pub background_color: String,
}

impl Default for LockscreenConfig {
    fn default() -> Self {
        Self {
            pam_service: "kaze-shell".into(),
            fprintd: true,
            grace_secs: 0,
            dnd: true,
            media_controls: true,
            media_keys: true,
            blur: true,
            background_color: "#1f1f28".into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct SessionConfig {
    pub confirm: bool,
    pub countdown_secs: u64,
}

impl Default for SessionConfig {
    fn default() -> Self {
        Self {
            confirm: true,
            countdown_secs: 0,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct CaptureConfig {
    pub auto_copy_on_close: bool,
    pub save_dir: Option<PathBuf>,
    pub backdrop_padding: u32,
}

impl Default for CaptureConfig {
    fn default() -> Self {
        Self {
            auto_copy_on_close: false,
            save_dir: None,
            backdrop_padding: 32,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct Config {
    pub general: GeneralConfig,
    pub network: NetworkConfig,
    pub layout: LayoutConfig,
    pub theme: ThemeConfig,
    pub bar: BarConfig,
    pub island: IslandConfig,
    pub osd: OsdConfig,
    pub notifications: NotifyConfig,
    pub launcher: LauncherConfig,
    pub display: DisplayConfig,
    pub wallpaper: WallpaperConfig,
    pub hooks: HooksConfig,
    pub accessibility: AccessibilityConfig,
    pub input: InputConfig,
    pub clipboard: ClipboardConfig,
    pub brightness: BrightnessConfig,
    pub location: LocationConfig,
    pub audio: AudioConfig,
    pub privacy: PrivacyConfig,
    pub idle: IdleConfig,
    pub lockscreen: LockscreenConfig,
    pub session: SessionConfig,
    pub capture: CaptureConfig,
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ValidationSeverity {
    Error,
    Warning,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ValidationIssue {
    pub severity: ValidationSeverity,
    pub path: String,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ValidationReport {
    pub file: String,
    pub ok: bool,
    pub errors: Vec<ValidationIssue>,
    pub warnings: Vec<ValidationIssue>,
}

impl ValidationReport {
    pub fn has_errors(&self) -> bool {
        !self.errors.is_empty()
    }

    pub fn has_warnings(&self) -> bool {
        !self.warnings.is_empty()
    }
}

/// Comment- and order-preserving writer for `$XDG_STATE_HOME/kaze/settings.toml` (Layer 2).
pub struct SettingsStore;

impl SettingsStore {
    pub fn set_override(path: &Path, dotted_key: &str, value_raw: &str) -> Result<(), String> {
        let keys = parse_dotted_key(dotted_key)?;
        let existing = match fs::read_to_string(path) {
            Ok(s) => s,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => String::new(),
            Err(err) => return Err(format!("failed reading {}: {err}", path.display())),
        };
        let mut doc = existing
            .parse::<toml_edit::DocumentMut>()
            .map_err(|e| format!("invalid TOML in {}: {e}", path.display()))?;
        let item = parse_toml_edit_item(value_raw);
        set_dotted_item(doc.as_table_mut(), &keys, item)?;
        write_atomic(path, &doc.to_string())
    }

    pub fn remove_override(path: &Path, dotted_key: &str) -> Result<bool, String> {
        let keys = parse_dotted_key(dotted_key)?;
        let existing = match fs::read_to_string(path) {
            Ok(s) => s,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(false),
            Err(err) => return Err(format!("failed reading {}: {err}", path.display())),
        };
        let mut doc = existing
            .parse::<toml_edit::DocumentMut>()
            .map_err(|e| format!("invalid TOML in {}: {e}", path.display()))?;
        let removed = remove_dotted_item(doc.as_table_mut(), &keys);
        if removed {
            write_atomic(path, &doc.to_string())?;
        }
        Ok(removed)
    }
}

fn parse_dotted_key(dotted_key: &str) -> Result<Vec<&str>, String> {
    let parts: Vec<&str> = dotted_key.split('.').map(str::trim).collect();
    if parts.is_empty() || parts.iter().any(|p| p.is_empty()) {
        return Err(format!("invalid dotted config key '{dotted_key}'"));
    }
    Ok(parts)
}

fn parse_toml_edit_item(raw: &str) -> toml_edit::Item {
    let probe = format!("v = {raw}");
    if let Ok(doc) = probe.parse::<toml_edit::DocumentMut>() {
        if let Some(item) = doc.get("v") {
            return item.clone();
        }
    }
    toml_edit::value(raw)
}

fn set_dotted_item(
    table: &mut toml_edit::Table,
    keys: &[&str],
    item: toml_edit::Item,
) -> Result<(), String> {
    let Some((head, tail)) = keys.split_first() else {
        return Err("empty key path".to_string());
    };
    if tail.is_empty() {
        table.insert(head, item);
        return Ok(());
    }
    if !table.contains_key(head) {
        let mut sub = toml_edit::Table::new();
        sub.set_implicit(true);
        table.insert(head, toml_edit::Item::Table(sub));
    }
    let Some(entry) = table.get_mut(head) else {
        return Err(format!("failed accessing table '{head}'"));
    };
    let Some(sub_table) = entry.as_table_mut() else {
        return Err(format!("key '{head}' is not a table"));
    };
    set_dotted_item(sub_table, tail, item)
}

fn remove_dotted_item(table: &mut toml_edit::Table, keys: &[&str]) -> bool {
    let Some((head, tail)) = keys.split_first() else {
        return false;
    };
    if tail.is_empty() {
        return table.remove(head).is_some();
    }
    let Some(sub_table) = table.get_mut(head).and_then(|v| v.as_table_mut()) else {
        return false;
    };
    let removed = remove_dotted_item(sub_table, tail);
    if removed && sub_table.is_empty() {
        table.remove(head);
    }
    removed
}

fn merge_toml_tables(
    base: &mut toml::map::Map<String, toml::Value>,
    overlay: toml::map::Map<String, toml::Value>,
) {
    for (k, v) in overlay {
        match (base.get_mut(&k), v) {
            (Some(toml::Value::Table(base_sub)), toml::Value::Table(ov_sub)) => {
                merge_toml_tables(base_sub, ov_sub);
            }
            (_, ov_val) => {
                base.insert(k, ov_val);
            }
        }
    }
}

impl Config {
    pub fn default_dir() -> Result<PathBuf, String> {
        Ok(xdg_config_home()?.join("kaze-shell"))
    }

    pub fn default_path() -> Result<PathBuf, String> {
        Ok(Self::default_dir()?.join("config.toml"))
    }

    pub fn settings_path() -> Result<PathBuf, String> {
        Ok(xdg_state_home()?.join("kaze").join("settings.toml"))
    }

    pub fn load_from_path(path: &Path) -> Result<Self, String> {
        let raw = match fs::read_to_string(path) {
            Ok(s) => s,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(Self::default()),
            Err(err) => return Err(format!("failed reading {}: {err}", path.display())),
        };
        Self::parse_toml(&raw).map_err(|e| format!("invalid config {}: {e}", path.display()))
    }

    /// Loads the 2-layer stack (`Defaults < config.toml < settings.toml`).
    pub fn load_layered(config_path: &Path, settings_path: Option<&Path>) -> Result<Self, String> {
        let mut merged = match fs::read_to_string(config_path) {
            Ok(raw) => raw
                .parse::<toml::Table>()
                .map_err(|e| format!("invalid config {}: {e}", config_path.display()))?,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => toml::Table::new(),
            Err(err) => return Err(format!("failed reading {}: {err}", config_path.display())),
        };

        if let Some(sp) = settings_path {
            match fs::read_to_string(sp) {
                Ok(raw) => {
                    let overlay = raw
                        .parse::<toml::Table>()
                        .map_err(|e| format!("invalid settings {}: {e}", sp.display()))?;
                    merge_toml_tables(&mut merged, overlay);
                }
                Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
                Err(err) => return Err(format!("failed reading {}: {err}", sp.display())),
            }
        }

        let mut cfg: Self = toml::Value::Table(merged)
            .try_into()
            .map_err(|e: toml::de::Error| format!("invalid layered config: {e}"))?;
        cfg.validate()?;
        Ok(cfg)
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
        if !self.accessibility.font_scale.is_finite()
            || !(0.75..=2.0).contains(&self.accessibility.font_scale)
        {
            return Err(format!(
                "accessibility.font_scale={} out of range (0.75..=2.0)",
                self.accessibility.font_scale
            ));
        }
        if self.hooks.timeout_secs == 0 {
            return Err("hooks.timeout_secs must be > 0".to_string());
        }
        if Color::from_hex(&self.lockscreen.background_color).is_none() {
            return Err(format!(
                "lockscreen.background_color='{}' must be #RRGGBB or #RRGGBBAA",
                self.lockscreen.background_color
            ));
        }
        if !self.location.lat.is_finite() || !(-90.0..=90.0).contains(&self.location.lat) {
            return Err(format!(
                "location.lat={} out of range (-90.0..=90.0)",
                self.location.lat
            ));
        }
        if !self.location.lon.is_finite() || !(-180.0..=180.0).contains(&self.location.lon) {
            return Err(format!(
                "location.lon={} out of range (-180.0..=180.0)",
                self.location.lon
            ));
        }
        self.notifications.width = self.notifications.width.clamp(220, 640);
        self.notifications.gap = self.notifications.gap.clamp(0, 32);
        self.notifications.max_visible = self.notifications.max_visible.clamp(1, 10);
        self.notifications.history_limit = self.notifications.history_limit.clamp(1, 200);
        self.launcher.width = self.launcher.width.clamp(320, 960);
        self.launcher.max_rows = self.launcher.max_rows.clamp(4, 16);
        self.launcher.offset_y = self.launcher.offset_y.clamp(0, 600);
        if !self.island.corner_radius.is_finite() {
            self.island.corner_radius = 20.0;
        }
        self.island.corner_radius = self.island.corner_radius.clamp(12.0, 26.0);
        self.island.margin_top = self.island.margin_top.clamp(0, 32);
        self.audio.spectrum_frame_rate = self.audio.spectrum_frame_rate.clamp(5, 60);
        self.clipboard.max_items = self.clipboard.max_items.clamp(1, 2000);
        self.clipboard.max_item_bytes = self.clipboard.max_item_bytes.clamp(1024, 64 * 1024 * 1024);
        Ok(())
    }

    pub fn validate_file(path: &Path) -> ValidationReport {
        let mut errors = Vec::new();
        let mut warnings = Vec::new();
        let file = path.display().to_string();

        let raw = match fs::read_to_string(path) {
            Ok(s) => s,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
                return ValidationReport {
                    file,
                    ok: true,
                    errors,
                    warnings,
                };
            }
            Err(err) => {
                errors.push(ValidationIssue {
                    severity: ValidationSeverity::Error,
                    path: String::new(),
                    message: format!("failed reading {}: {err}", path.display()),
                });
                return ValidationReport {
                    file,
                    ok: false,
                    errors,
                    warnings,
                };
            }
        };

        let table: toml::Table = match raw.parse() {
            Ok(t) => t,
            Err(err) => {
                errors.push(ValidationIssue {
                    severity: ValidationSeverity::Error,
                    path: String::new(),
                    message: format!("TOML syntax error: {err}"),
                });
                return ValidationReport {
                    file,
                    ok: false,
                    errors,
                    warnings,
                };
            }
        };

        let mut cfg: Self = match toml::Value::Table(table.clone()).try_into() {
            Ok(c) => c,
            Err(err) => {
                errors.push(ValidationIssue {
                    severity: ValidationSeverity::Error,
                    path: String::new(),
                    message: format!("type/schema mismatch: {err}"),
                });
                return ValidationReport {
                    file,
                    ok: false,
                    errors,
                    warnings,
                };
            }
        };

        collect_schema_warnings(&table, "", &mut warnings);

        if !(0.0..=1.0).contains(&cfg.bar.background_opacity)
            && cfg.bar.background_opacity.is_finite()
        {
            warnings.push(ValidationIssue {
                severity: ValidationSeverity::Warning,
                path: "bar.background_opacity".into(),
                message: format!(
                    "bar.background_opacity={} out of range 0.0..=1.0 (clamped at runtime)",
                    cfg.bar.background_opacity
                ),
            });
        }
        if !(1..=20).contains(&cfg.bar.persistent_workspaces) {
            warnings.push(ValidationIssue {
                severity: ValidationSeverity::Warning,
                path: "bar.persistent_workspaces".into(),
                message: format!(
                    "bar.persistent_workspaces={} out of range 1..=20 (clamped at runtime)",
                    cfg.bar.persistent_workspaces
                ),
            });
        }

        if cfg.osd.timeout_ms == 0 {
            errors.push(ValidationIssue {
                severity: ValidationSeverity::Error,
                path: "osd.timeout_ms".into(),
                message: "osd.timeout_ms must be > 0".into(),
            });
        }
        if cfg.notifications.default_timeout_ms == 0 {
            errors.push(ValidationIssue {
                severity: ValidationSeverity::Error,
                path: "notifications.default_timeout_ms".into(),
                message: "notifications.default_timeout_ms must be > 0".into(),
            });
        }
        if cfg.bar.font.trim().is_empty() {
            errors.push(ValidationIssue {
                severity: ValidationSeverity::Error,
                path: "bar.font".into(),
                message: "bar.font must not be empty".into(),
            });
        }
        if let Some(ref p) = cfg.wallpaper.path {
            if p.as_os_str().is_empty() {
                errors.push(ValidationIssue {
                    severity: ValidationSeverity::Error,
                    path: "wallpaper.path".into(),
                    message: "wallpaper.path must not be empty".into(),
                });
            }
        }
        if let Some(ref dir) = cfg.wallpaper.directory {
            if dir.as_os_str().is_empty() {
                errors.push(ValidationIssue {
                    severity: ValidationSeverity::Error,
                    path: "wallpaper.directory".into(),
                    message: "wallpaper.directory must not be empty".into(),
                });
            }
        }

        if let Err(err) = cfg.validate() {
            errors.push(ValidationIssue {
                severity: ValidationSeverity::Error,
                path: String::new(),
                message: err,
            });
        }

        ValidationReport {
            file,
            ok: errors.is_empty(),
            errors,
            warnings,
        }
    }
}

fn collect_schema_warnings(
    table: &toml::map::Map<String, toml::Value>,
    prefix: &str,
    warnings: &mut Vec<ValidationIssue>,
) {
    let schema = toml::Value::try_from(Config::default()).ok();
    let Some(toml::Value::Table(ref root_schema)) = schema else {
        return;
    };
    walk_against_schema(table, root_schema, prefix, warnings);
}

fn walk_against_schema(
    actual: &toml::map::Map<String, toml::Value>,
    schema: &toml::map::Map<String, toml::Value>,
    prefix: &str,
    warnings: &mut Vec<ValidationIssue>,
) {
    for (k, val) in actual {
        let full = if prefix.is_empty() {
            k.clone()
        } else {
            format!("{prefix}.{k}")
        };
        if let Some(dep_msg) = deprecated_key_message(&full) {
            warnings.push(ValidationIssue {
                severity: ValidationSeverity::Warning,
                path: full,
                message: dep_msg.to_string(),
            });
            continue;
        }
        // `Option<T>` / dynamic map fields skip deep unknown-key traversal.
        if is_dynamic_section(&full) {
            continue;
        }
        match schema.get(k) {
            None => {
                if !is_optional_config_key(&full) {
                    warnings.push(ValidationIssue {
                        severity: ValidationSeverity::Warning,
                        path: full,
                        message: "unknown configuration key".into(),
                    });
                }
            }
            Some(toml::Value::Table(sub_schema)) => {
                if let toml::Value::Table(sub_actual) = val {
                    walk_against_schema(sub_actual, sub_schema, &full, warnings);
                }
            }
            Some(_) => {}
        }
    }
}

fn deprecated_key_message(full: &str) -> Option<&'static str> {
    match full {
        "theme.custom_palette" => Some("deprecated key: use `theme.palette` instead"),
        "bar.auto_hide" => Some("deprecated key: use `layout.preset = \"ghost\"` instead"),
        "bar.reserve_space" => Some("deprecated key: use `bar.exclusive` instead"),
        _ => None,
    }
}

fn is_dynamic_section(full: &str) -> bool {
    matches!(
        full,
        "brightness.monitors"
            | "idle.behavior.ac.custom_stages"
            | "idle.behavior.battery.custom_stages"
    )
}

fn is_optional_config_key(full: &str) -> bool {
    matches!(
        full,
        "theme.palettes_dir"
            | "wallpaper.path"
            | "wallpaper.directory"
            | "capture.save_dir"
            | "hooks.started"
            | "hooks.stopping"
            | "hooks.wallpaper_changed"
            | "hooks.theme_mode_changed"
            | "hooks.layout_changed"
            | "hooks.session_locked"
            | "hooks.session_unlocked"
            | "hooks.battery_percentage_changed"
            | "hooks.ac_state_changed"
            | "hooks.power_profile_changed"
            | "hooks.dnd_changed"
            | "hooks.rebooting"
            | "hooks.suspending"
    )
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

    #[test]
    fn layered_config_merges_and_unset_falls_back_preserving_comments() {
        let dir = std::env::temp_dir().join(format!("kaze-layered-cfg-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("mkdir");
        let cfg_path = dir.join("config.toml");
        let settings_path = dir.join("settings.toml");

        let original_cfg = "# Hand-written comment\n[theme]\nmode = \"dark\"\npalette = \"Kanagawa\"\n\n[bar]\nthickness = 48\n";
        fs::write(&cfg_path, original_cfg).expect("write config");
        fs::write(
            &settings_path,
            "# Runtime override\n[theme]\nmode = \"light\"\n\n[bar]\n# keep bar comment\nthickness = 36\n",
        )
        .expect("write settings");

        let merged = Config::load_layered(&cfg_path, Some(&settings_path)).expect("load layered");
        assert_eq!(merged.theme.mode, ThemeMode::Light);
        assert_eq!(merged.theme.palette, "Kanagawa");
        assert_eq!(merged.bar.thickness, 36);

        // Removing `bar.thickness` from settings.toml returns immediately to config.toml's 48
        // while preserving comments and untouched keys in both files.
        let removed = SettingsStore::remove_override(&settings_path, "bar.thickness")
            .expect("remove override");
        assert!(removed);
        assert_eq!(
            fs::read_to_string(&cfg_path).expect("read config"),
            original_cfg
        );
        let settings_after = fs::read_to_string(&settings_path).expect("read settings");
        assert!(settings_after.contains("# Runtime override"));
        assert!(settings_after.contains("mode = \"light\""));

        let after_unset =
            Config::load_layered(&cfg_path, Some(&settings_path)).expect("load after unset");
        assert_eq!(after_unset.bar.thickness, 48);
        assert_eq!(after_unset.theme.mode, ThemeMode::Light);

        SettingsStore::set_override(&settings_path, "network.offline_mode", "false")
            .expect("set override");
        let after_set =
            Config::load_layered(&cfg_path, Some(&settings_path)).expect("load after set");
        assert!(!after_set.network.offline_mode);

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn validate_file_detects_unknown_deprecated_and_range_issues() {
        let dir = std::env::temp_dir().join(format!("kaze-validate-cfg-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("mkdir");

        let clean = dir.join("clean.toml");
        fs::write(&clean, "[theme]\nmode = \"dark\"\n").expect("write clean");
        let rep = Config::validate_file(&clean);
        assert!(rep.ok && !rep.has_errors() && !rep.has_warnings());

        let warn = dir.join("warn.toml");
        fs::write(
            &warn,
            "[theme]\ncustom_palette = \"Old\"\nunknown_flag = 1\n",
        )
        .expect("write warn");
        let rep_warn = Config::validate_file(&warn);
        assert!(rep_warn.ok && !rep_warn.has_errors() && rep_warn.warnings.len() == 2);

        let bad = dir.join("bad.toml");
        fs::write(&bad, "[accessibility]\nfont_scale = 9.5\n").expect("write bad");
        let rep_bad = Config::validate_file(&bad);
        assert!(!rep_bad.ok && rep_bad.has_errors());

        let _ = fs::remove_dir_all(&dir);
    }
}
