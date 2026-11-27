use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::config::Config;
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
    pub clock: ClockTime,
    pub hypr_connected: bool,
}

impl AppState {
    pub fn new(config: Config) -> Self {
        let theme_mode = config.theme.mode;
        let palette =
            ResolvedPalette::load(&config.theme.palette, config.theme.palettes_dir.as_deref());
        let (clock, _) = ClockTime::now_and_duration_to_next_minute();
        Self {
            config,
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
}
