use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::config::Config;
use crate::dconf_read::read_gnome_text_scaling_factor;
use crate::desktop::DesktopApp;
use crate::extension::WindowGeometry;
use crate::i18n::Locale;
use crate::layout::LayoutPreset;
use crate::theme::ResolvedPalette;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum ThemeMode {
    #[default]
    Dark,
    Light,
}

impl ThemeMode {
    pub fn toggled(self) -> Self {
        match self {
            Self::Dark => Self::Light,
            Self::Light => Self::Dark,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Dark => "dark",
            Self::Light => "light",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct OutputInfo {
    pub name: String,
    pub width: i32,
    pub height: i32,
    pub scale: i32,
    pub make: String,
    pub model: String,
    pub serial: String,
}

impl OutputInfo {
    pub fn new(name: impl Into<String>, width: i32, height: i32, scale: i32) -> Self {
        Self {
            name: name.into(),
            width,
            height,
            scale,
            make: String::new(),
            model: String::new(),
            serial: String::new(),
        }
    }
}

/// Stable hardware monitor identifier `"<make>:<model>:<serial>"`, falling back to the
/// connector name (e.g. `"Virtual-1"`) when the EDID serial is empty.
pub fn monitor_id_for(name: &str, make: &str, model: &str, serial: &str) -> String {
    let ser = serial.trim();
    if ser.is_empty() {
        name.trim().to_string()
    } else {
        format!("{}:{}:{}", make.trim(), model.trim(), ser)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct MonitorState {
    pub id: i32,
    pub name: String,
    pub make: String,
    pub model: String,
    pub serial: String,
    pub width: i32,
    pub height: i32,
    pub scale: f32,
    pub focused: bool,
    pub disabled: bool,
    pub active_workspace_id: i32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct WorkspaceState {
    pub id: i32,
    pub name: String,
    pub monitor: String,
    pub windows: u32,
    pub urgent: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum NetworkKind {
    #[default]
    Disconnected,
    Ethernet,
    Wifi,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct WifiApInfo {
    pub ssid: String,
    pub strength: u8,
    pub secured: bool,
    pub active: bool,
    pub saved: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct VpnInfo {
    pub uuid: String,
    pub name: String,
    pub kind: String,
    pub active: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct NetworkState {
    pub available: bool,
    pub wifi_enabled: bool,
    pub connected: bool,
    pub kind: NetworkKind,
    pub ssid: String,
    pub strength: u8,
    pub access_points: Vec<WifiApInfo>,
    pub vpns: Vec<VpnInfo>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct BluetoothDeviceInfo {
    pub path: String,
    pub address: String,
    pub name: String,
    pub icon: String,
    pub paired: bool,
    pub trusted: bool,
    pub connected: bool,
    pub battery_pct: Option<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct BluetoothState {
    pub available: bool,
    pub powered: bool,
    pub discovering: bool,
    pub connected_device: String,
    pub devices: Vec<BluetoothDeviceInfo>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct KeyboardState {
    pub layout_raw: String,
    pub layout_label: String,
    pub caps_lock: bool,
    pub num_lock: bool,
    pub scroll_lock: bool,
}

pub fn resolve_keyboard_alias(raw: &str, aliases: &BTreeMap<String, String>) -> String {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return "EN".to_string();
    }
    let lower = trimmed.to_ascii_lowercase();
    for (k, v) in aliases {
        let kl = k.trim().to_ascii_lowercase();
        if !kl.is_empty() && (lower == kl || lower.contains(&kl)) {
            return v.clone();
        }
    }
    if lower.contains("bamboo")
        || lower.contains("unikey")
        || lower == "vi"
        || lower.contains("viet")
    {
        return "VI".to_string();
    }
    if lower == "keyboard-us" || lower == "us" || lower.starts_with("english") {
        return "EN".to_string();
    }
    let short: String = trimmed
        .strip_prefix("keyboard-")
        .unwrap_or(trimmed)
        .chars()
        .take(4)
        .collect();
    short.to_uppercase()
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct DiskMountInfo {
    pub mount: String,
    pub used_gib: f32,
    pub total_gib: f32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct SysmonState {
    pub active: bool,
    pub cpu_pct: f32,
    pub per_core_pct: Vec<f32>,
    pub cpu_history: Vec<f32>,
    pub ram_used_mib: u64,
    pub ram_total_mib: u64,
    pub swap_used_mib: u64,
    pub swap_total_mib: u64,
    pub zram_used_mib: u64,
    pub temp_c: Option<f32>,
    pub net_rx_bps: u64,
    pub net_tx_bps: u64,
    pub disks: Vec<DiskMountInfo>,
    pub distro: String,
    pub kernel: String,
    pub cpu_model: String,
    pub gpu_model: String,
    pub uptime_secs: u64,
    pub install_age_days: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct WeatherHourly {
    pub time_label: String,
    pub temp_c: f32,
    pub condition: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct WeatherDaily {
    pub date_label: String,
    pub min_c: f32,
    pub max_c: f32,
    pub condition: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct WeatherState {
    pub available: bool,
    pub stale: bool,
    pub offline_blocked: bool,
    pub temp_c: f32,
    pub feels_like_c: f32,
    pub humidity_pct: u8,
    pub wind_kph: f32,
    pub condition: String,
    pub location_name: String,
    pub updated_epoch_secs: u64,
    pub error: Option<String>,
    pub hourly: Vec<WeatherHourly>,
    pub daily: Vec<WeatherDaily>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct ScreenTimeAppUsage {
    pub app_id: String,
    pub seconds: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct ScreenTimeState {
    pub enabled: bool,
    pub paused: bool,
    pub today_total_secs: u64,
    pub today_hourly_secs: [u64; 24],
    pub three_day_secs: Vec<(String, u64)>,
    pub fourteen_day_secs: Vec<(String, u64)>,
    pub top_apps_today: Vec<ScreenTimeAppUsage>,
    pub top_apps_3d: Vec<ScreenTimeAppUsage>,
    pub top_apps_14d: Vec<ScreenTimeAppUsage>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct CalendarEvent {
    pub uid: String,
    pub source_id: String,
    pub title: String,
    pub location: String,
    pub start_epoch_secs: i64,
    pub end_epoch_secs: i64,
    pub all_day: bool,
    pub reminder_mins: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct CalendarSourceStatus {
    pub id: String,
    pub name: String,
    pub kind: String,
    pub ok: bool,
    pub last_sync_epoch_secs: u64,
    pub error: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct CalendarState {
    pub events: Vec<CalendarEvent>,
    pub sources: Vec<CalendarSourceStatus>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrayItem {
    pub id: String,
    pub service: String,
    pub object_path: String,
    pub title: String,
    pub icon_name: String,
    pub menu_path: String,
    pub icon_width: u32,
    pub icon_height: u32,
    /// Premultiplied RGBA pixels decoded once in `kaze-sys` (`Arc` avoids copies across specs).
    pub icon_rgba: Option<Arc<[u8]>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TrayMenuEntry {
    pub id: i32,
    pub label: String,
    pub enabled: bool,
    pub separator: bool,
    pub toggle_state: i32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrayMenuState {
    pub service: String,
    pub menu_path: String,
    pub items: Vec<TrayMenuEntry>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct BatteryDeviceDetail {
    pub name: String,
    pub kind: String,
    pub percentage: u8,
    pub charging: bool,
    pub capacity_pct: Option<u8>,
    pub charge_limit_pct: Option<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct BatteryState {
    pub present: bool,
    pub percentage: u8,
    pub charging: bool,
    pub low: bool,
    pub ac_online: bool,
    pub health_pct: Option<u8>,
    pub charge_limit_pct: Option<u8>,
    pub devices: Vec<BatteryDeviceDetail>,
    pub peripherals: Vec<BatteryDeviceDetail>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct AudioDeviceInfo {
    pub index: u32,
    pub name: String,
    pub description: String,
    pub volume_pct: u8,
    pub muted: bool,
    pub is_default: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct AudioStreamInfo {
    pub index: u32,
    pub app_name: String,
    pub media_name: String,
    pub volume_pct: u8,
    pub muted: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct AudioState {
    pub available: bool,
    pub volume_pct: u8,
    pub muted: bool,
    pub mic_muted: bool,
    pub sink_name: String,
    pub source_name: String,
    pub sinks: Vec<AudioDeviceInfo>,
    pub sources: Vec<AudioDeviceInfo>,
    pub streams: Vec<AudioStreamInfo>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct PowerProfileState {
    pub available: bool,
    pub active: String,
    pub available_profiles: Vec<String>,
    pub degraded_reason: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct PowerCapabilities {
    pub can_suspend: bool,
    pub can_hibernate: bool,
    pub can_reboot: bool,
    pub can_poweroff: bool,
    pub can_reboot_to_uefi: bool,
    pub uwsm_active: bool,
}

impl Default for PowerCapabilities {
    fn default() -> Self {
        let uwsm_active = std::env::var_os("UWSM_FINALIZE_VARNAMES").is_some();
        Self {
            can_suspend: true,
            can_hibernate: false,
            can_reboot: true,
            can_poweroff: true,
            can_reboot_to_uefi: false,
            uwsm_active,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct PrivacyState {
    pub mic_apps: Vec<String>,
    pub camera_apps: Vec<String>,
    pub screenshare_apps: Vec<String>,
    pub noscreenshare_active: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct BacklightState {
    pub present: bool,
    pub percentage: u8,
    pub device: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum MediaPlayback {
    #[default]
    Stopped,
    Paused,
    Playing,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct MediaState {
    pub active: bool,
    pub player: String,
    pub title: String,
    pub artist: String,
    pub status: MediaPlayback,
    pub position_us: i64,
    pub length_us: i64,
    /// Playback rate scaled by 1000 (`1000` = 1.0x) to preserve `Eq`.
    pub rate_milli: i32,
    pub updated_at_epoch_ms: u64,
}

impl MediaState {
    /// Computes interpolated playback progress `0.0..=1.0` without polling MPRIS.
    pub fn interpolated_progress(&self, now_epoch_ms: u64) -> Option<f32> {
        if self.length_us <= 0 {
            return None;
        }
        let elapsed_us = if self.status == MediaPlayback::Playing
            && self.updated_at_epoch_ms > 0
            && now_epoch_ms >= self.updated_at_epoch_ms
        {
            let dt_ms = (now_epoch_ms - self.updated_at_epoch_ms).min(3_600_000) as i64;
            let rate = if self.rate_milli > 0 {
                i64::from(self.rate_milli)
            } else {
                1000
            };
            dt_ms.saturating_mul(rate)
        } else {
            0
        };
        let pos = self
            .position_us
            .saturating_add(elapsed_us)
            .clamp(0, self.length_us);
        Some((pos as f64 / self.length_us as f64).clamp(0.0, 1.0) as f32)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct DisplayActivity {
    pub mode: String,
    pub ws: Option<i32>,
    pub control: bool,
    pub output: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct RecordActivity {
    pub active: bool,
    pub started_at: u64,
    pub audio: bool,
    pub gif: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct CustomActivity {
    pub id: String,
    pub badge: String,
    pub title: String,
    pub subtitle: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum NotificationUrgency {
    Low,
    #[default]
    Normal,
    Critical,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NotificationAction {
    pub key: String,
    pub label: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NotificationItem {
    pub id: u32,
    pub app_name: String,
    pub summary: String,
    pub body: String,
    pub app_icon: String,
    pub urgency: NotificationUrgency,
    pub actions: Vec<NotificationAction>,
    pub expire_timeout_ms: i32,
    pub resident: bool,
    pub transient: bool,
    pub sync_tag: Option<String>,
    pub timestamp_epoch_secs: u64,
    #[serde(default)]
    pub progress_value: Option<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum DisplayStatus {
    #[default]
    Idle,
    Present {
        detail: String,
    },
    VirtualShare {
        detail: String,
    },
    VirtualControl {
        detail: String,
    },
    Recording {
        detail: String,
    },
}

impl DisplayStatus {
    pub fn is_active(&self) -> bool {
        !matches!(self, Self::Idle)
    }

    pub fn kind_name(&self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Present { .. } => "present",
            Self::VirtualShare { .. } => "virtual-share",
            Self::VirtualControl { .. } => "virtual-control",
            Self::Recording { .. } => "recording",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ClockTime {
    pub hour: u8,
    pub minute: u8,
    pub second: u8,
}

impl ClockTime {
    /// Reads current local wall-clock time via `localtime_r` and returns both the
    /// formatted clock components and the exact duration until the next `:00` minute tick.
    pub fn now_and_duration_to_next_minute() -> (Self, Duration) {
        let now = SystemTime::now();
        let since_epoch = now.duration_since(UNIX_EPOCH).unwrap_or_default();
        let secs = since_epoch.as_secs() as libc::time_t;
        let subsec_nanos = since_epoch.subsec_nanos();

        let mut tm = std::mem::MaybeUninit::<libc::tm>::zeroed();
        // SAFETY: `localtime_r` writes into our valid stack-allocated `tm` struct.
        let ptr = unsafe { libc::localtime_r(&secs, tm.as_mut_ptr()) };
        let (hour, minute, second) = if ptr.is_null() {
            let s = (since_epoch.as_secs() % 86_400) as u32;
            ((s / 3600) as u8, ((s % 3600) / 60) as u8, (s % 60) as u8)
        } else {
            // SAFETY: `ptr` is non-null, so `tm` is initialized.
            let tm = unsafe { tm.assume_init() };
            (
                tm.tm_hour.clamp(0, 23) as u8,
                tm.tm_min.clamp(0, 59) as u8,
                tm.tm_sec.clamp(0, 59) as u8,
            )
        };

        let elapsed_in_minute_nanos = u64::from(second) * 1_000_000_000 + u64::from(subsec_nanos);
        let remaining_nanos = (60_000_000_000u64)
            .saturating_sub(elapsed_in_minute_nanos)
            .max(1_000_000);
        // Add 15ms slack past the exact second boundary so wall-clock jitter never wakes at :59.999.
        let wait = Duration::from_nanos(remaining_nanos + 15_000_000);

        (
            Self {
                hour,
                minute,
                second,
            },
            wait,
        )
    }

    pub fn format_hh(&self) -> String {
        format!("{:02}", self.hour)
    }

    pub fn format_mm(&self) -> String {
        format!("{:02}", self.minute)
    }

    pub fn format_hh_mm(&self) -> String {
        format!("{:02}:{:02}", self.hour, self.minute)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct UserAccountState {
    pub username: String,
    pub real_name: String,
    pub icon_path: Option<PathBuf>,
    pub initials: String,
}

impl UserAccountState {
    pub fn from_username(username: impl Into<String>, real_name: impl Into<String>) -> Self {
        let username = username.into();
        let real_name = real_name.into();
        let source = if real_name.trim().is_empty() {
            username.as_str()
        } else {
            real_name.as_str()
        };
        let initials = compute_initials(source);
        Self {
            username,
            real_name,
            icon_path: None,
            initials,
        }
    }
}

pub fn compute_initials(name: &str) -> String {
    let mut parts = name.split_whitespace().filter(|p| !p.is_empty());
    let first = parts.next().and_then(|s| s.chars().next());
    let second = parts.next().and_then(|s| s.chars().next());
    match (first, second) {
        (Some(a), Some(b)) => format!(
            "{}{}",
            a.to_uppercase().next().unwrap_or(a),
            b.to_uppercase().next().unwrap_or(b)
        ),
        (Some(a), None) => a.to_uppercase().collect(),
        _ => "?".to_string(),
    }
}

#[derive(Debug, Clone)]
pub struct AppState {
    pub config: Config,
    pub layout_preset: LayoutPreset,
    pub theme_mode: ThemeMode,
    pub palette: ResolvedPalette,
    pub outputs: BTreeMap<String, OutputInfo>,
    pub monitors: Vec<MonitorState>,
    pub workspaces: Vec<WorkspaceState>,
    pub active_workspace_id: i32,
    pub focused_monitor: Option<String>,
    pub hidden_bars: BTreeSet<String>,
    pub hide_all_bars: bool,
    pub display_status: DisplayStatus,
    pub display_activity: Option<DisplayActivity>,
    pub record_activity: Option<RecordActivity>,
    pub custom_activities: BTreeMap<String, CustomActivity>,
    pub island_expanded: bool,
    pub network: NetworkState,
    pub bluetooth: BluetoothState,
    pub battery: BatteryState,
    pub power_profile: PowerProfileState,
    pub power_capabilities: PowerCapabilities,
    pub privacy: PrivacyState,
    pub audio: AudioState,
    pub audio_spectrum: Vec<u8>,
    pub backlight: BacklightState,
    pub media: MediaState,
    pub dnd: bool,
    pub nightlight_enabled: bool,
    pub nightlight_temp_k: u32,
    pub nightlight_auto: bool,
    pub nightlight_manual_override: bool,
    pub caffeine_enabled: bool,
    pub cc_open: bool,
    pub tray_bus_owned: bool,
    pub tray_items: Vec<TrayItem>,
    pub notification_history: Vec<NotificationItem>,
    pub wallpaper_path: Option<PathBuf>,
    pub unread_notifications: u32,
    pub active_notifications: usize,
    pub history_notifications: usize,
    pub notifications_bus_owned: bool,
    pub polkit_bus_owned: bool,
    pub offline_mode: bool,
    pub locale: Locale,
    pub effective_font_scale: f32,
    pub user_account: UserAccountState,
    pub clock: ClockTime,
    pub hypr_connected: bool,
    pub windows: Vec<WindowGeometry>,
    pub window_mru: Vec<String>,
    pub active_window_address: Option<String>,
    pub fullscreen_outputs: BTreeSet<String>,
    pub desktop_apps: Vec<DesktopApp>,
    pub keyboard: KeyboardState,
    pub sysmon: SysmonState,
    pub weather: WeatherState,
    pub screentime: ScreenTimeState,
    pub calendar: CalendarState,
    pub widget_exec_outputs: BTreeMap<String, String>,
    pub last_settings_target: Option<String>,
    pub spectrum_subscribers: BTreeSet<String>,
    pub sysmon_subscribers: BTreeSet<String>,
    pub session_locked: bool,
    pub outputs_dpms_off: bool,
}

impl AppState {
    pub fn compute_effective_font_scale(config: &Config) -> f32 {
        let mut scale = config.accessibility.font_scale.clamp(0.75, 2.0);
        if config.accessibility.sync_gnome_text_scale {
            if let Ok(cfg_home) = crate::config::xdg_config_home() {
                if let Some(gnome_scale) =
                    read_gnome_text_scaling_factor(&cfg_home.join("dconf").join("user"))
                {
                    scale = gnome_scale;
                }
            }
        }
        scale.clamp(0.75, 2.0)
    }

    pub fn new(config: Config) -> Self {
        let layout_preset = config.layout.preset;
        let theme_mode = config.theme.mode;
        let offline_mode = config.network.offline_mode;
        let nightlight_auto = config.location.auto_nightlight;
        let locale = Locale::resolve(&config.general.locale);
        let effective_font_scale = Self::compute_effective_font_scale(&config);
        let palette =
            ResolvedPalette::load(&config.theme.palette, config.theme.palettes_dir.as_deref());
        let (clock, _) = ClockTime::now_and_duration_to_next_minute();
        let fallback_user = std::env::var("USER").unwrap_or_else(|_| "user".to_string());
        let user_account = UserAccountState::from_username(&fallback_user, "");
        Self {
            config,
            layout_preset,
            theme_mode,
            palette,
            outputs: BTreeMap::new(),
            monitors: Vec::new(),
            workspaces: Vec::new(),
            active_workspace_id: 1,
            focused_monitor: None,
            hidden_bars: BTreeSet::new(),
            hide_all_bars: false,
            display_status: DisplayStatus::Idle,
            display_activity: None,
            record_activity: None,
            custom_activities: BTreeMap::new(),
            island_expanded: false,
            network: NetworkState::default(),
            bluetooth: BluetoothState::default(),
            battery: BatteryState::default(),
            power_profile: PowerProfileState::default(),
            power_capabilities: PowerCapabilities::default(),
            privacy: PrivacyState::default(),
            audio: AudioState::default(),
            audio_spectrum: Vec::new(),
            backlight: BacklightState::default(),
            media: MediaState::default(),
            dnd: false,
            nightlight_enabled: false,
            nightlight_temp_k: 4000,
            nightlight_auto,
            nightlight_manual_override: false,
            caffeine_enabled: false,
            cc_open: false,
            tray_bus_owned: false,
            tray_items: Vec::new(),
            notification_history: Vec::new(),
            wallpaper_path: None,
            unread_notifications: 0,
            active_notifications: 0,
            history_notifications: 0,
            notifications_bus_owned: false,
            polkit_bus_owned: false,
            offline_mode,
            locale,
            effective_font_scale,
            user_account,
            clock,
            hypr_connected: false,
            windows: Vec::new(),
            window_mru: Vec::new(),
            active_window_address: None,
            fullscreen_outputs: BTreeSet::new(),
            desktop_apps: Vec::new(),
            keyboard: KeyboardState::default(),
            sysmon: SysmonState::default(),
            weather: WeatherState::default(),
            screentime: ScreenTimeState::default(),
            calendar: CalendarState::default(),
            widget_exec_outputs: BTreeMap::new(),
            last_settings_target: None,
            spectrum_subscribers: BTreeSet::new(),
            sysmon_subscribers: BTreeSet::new(),
            session_locked: false,
            outputs_dpms_off: false,
        }
    }

    pub fn is_bar_hidden(&self, output_name: &str) -> bool {
        self.hide_all_bars || self.hidden_bars.contains(output_name)
    }

    pub fn is_output_excluded(&self, output_name: &str) -> bool {
        if output_name == "kaze-share" {
            return true;
        }
        if let Some(ref act) = self.display_activity {
            if act.output.as_deref() == Some(output_name)
                && matches!(act.mode.as_str(), "present" | "virtual-share")
            {
                return true;
            }
        }
        false
    }

    pub fn monitor_id(&self, output_name: &str) -> String {
        if let Some(mon) = self.monitors.iter().find(|m| m.name == output_name) {
            if !mon.serial.trim().is_empty() {
                return monitor_id_for(&mon.name, &mon.make, &mon.model, &mon.serial);
            }
        }
        if let Some(out) = self.outputs.get(output_name) {
            return monitor_id_for(&out.name, &out.make, &out.model, &out.serial);
        }
        output_name.to_string()
    }

    pub fn matches_monitor(&self, output_name: &str, selector: &str) -> bool {
        let sel = selector.trim();
        sel.is_empty() || sel == "*" || sel == output_name || sel == self.monitor_id(output_name)
    }

    pub fn active_window(&self) -> Option<&WindowGeometry> {
        if let Some(ref addr) = self.active_window_address {
            if let Some(w) = self.windows.iter().find(|w| &w.address == addr) {
                return Some(w);
            }
        }
        self.windows
            .iter()
            .find(|w| w.focused)
            .or_else(|| self.windows.iter().min_by_key(|w| w.focus_history_id))
    }

    pub fn active_workspace_for_output(&self, output_name: &str) -> i32 {
        self.monitors
            .iter()
            .find(|m| m.name == output_name)
            .map(|m| m.active_workspace_id)
            .filter(|&id| id > 0)
            .unwrap_or(self.active_workspace_id)
    }

    pub fn island_always_visible(&self) -> bool {
        self.layout_preset == LayoutPreset::Island || self.config.island.enabled
    }

    pub fn island_absorbs_osd(&self) -> bool {
        self.island_always_visible() && self.config.island.absorb_osd
    }

    pub fn island_absorbs_notify(&self) -> bool {
        self.island_always_visible() && self.config.island.absorb_notify
    }

    pub fn active_live_activity_ids(&self) -> Vec<String> {
        let mut ids = Vec::new();
        if self.record_activity.as_ref().is_some_and(|r| r.active) {
            ids.push("record".to_string());
        }
        if self.display_activity.is_some() || self.display_status.is_active() {
            ids.push("display".to_string());
        }
        if self.media.active {
            ids.push("media".to_string());
        }
        for key in self.custom_activities.keys() {
            ids.push(key.clone());
        }
        ids
    }
}
