use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::config::Config;
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OutputInfo {
    pub name: String,
    pub width: i32,
    pub height: i32,
    pub scale: i32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct MonitorState {
    pub id: i32,
    pub name: String,
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
pub struct NetworkState {
    pub available: bool,
    pub connected: bool,
    pub kind: NetworkKind,
    pub ssid: String,
    pub strength: u8,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct BluetoothState {
    pub available: bool,
    pub powered: bool,
    pub connected_device: String,
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
pub struct BatteryState {
    pub present: bool,
    pub percentage: u8,
    pub charging: bool,
    pub low: bool,
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
    pub audio: AudioState,
    pub backlight: BacklightState,
    pub media: MediaState,
    pub dnd: bool,
    pub nightlight_enabled: bool,
    pub nightlight_temp_k: u32,
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
    pub clock: ClockTime,
    pub hypr_connected: bool,
}

impl AppState {
    pub fn new(config: Config) -> Self {
        let layout_preset = config.layout.preset;
        let theme_mode = config.theme.mode;
        let palette =
            ResolvedPalette::load(&config.theme.palette, config.theme.palettes_dir.as_deref());
        let (clock, _) = ClockTime::now_and_duration_to_next_minute();
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
            audio: AudioState::default(),
            backlight: BacklightState::default(),
            media: MediaState::default(),
            dnd: false,
            nightlight_enabled: false,
            nightlight_temp_k: 4000,
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
            clock,
            hypr_connected: false,
        }
    }

    pub fn is_bar_hidden(&self, output_name: &str) -> bool {
        self.hide_all_bars || self.hidden_bars.contains(output_name)
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
