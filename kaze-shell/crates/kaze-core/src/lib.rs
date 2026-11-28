#![deny(clippy::unwrap_used)]

pub mod anim;
pub mod config;
pub mod crypto;
pub mod dconf_read;
pub mod desktop;
pub mod extension;
pub mod i18n;
pub mod layout;
pub mod solar;
pub mod state;
pub mod surface;
pub mod text_input;
pub mod theme;

pub use anim::{Spring, SPRING_MAX_DT_SECS, SPRING_POS_EPSILON, SPRING_VEL_EPSILON};
pub use config::{
    AccessibilityConfig, AudioConfig, BarConfig, BarInstanceConfig, BarLayerMode,
    BarMonitorOverride, BarPosition, BrightnessConfig, CaptureConfig, ClipboardConfig, Config,
    DisplayConfig, DockConfig, DockHideMode, GeneralConfig, HooksConfig, IdleConfig, InputConfig,
    InputKeybindsConfig, IslandConfig, IslandStyle, LauncherConfig, LayoutConfig, LocationConfig,
    LockscreenConfig, NetworkConfig, NotifyConfig, OsdConfig, PrivacyConfig, SessionConfig,
    SettingsStore, ThemeConfig, ValidationIssue, ValidationReport, ValidationSeverity,
    WallpaperConfig, WidgetInstanceConfig,
};
pub use crypto::{check_network_allowed, EncryptedRecordStore, MasterKey};
pub use dconf_read::read_gnome_text_scaling_factor;
pub use desktop::{
    find_desktop_app_for_class, resolve_icon_path, scan_applications, DesktopAction, DesktopApp,
};
pub use extension::{
    CapturedOutputFrame, DirtyFlags, ImeEvent, IpcResult, KazeExtension, KeyEvent, KeyModifiers,
    OsdKind, PointerButton, PolkitRequest, ShellAction, ShellContext, SystemEvent, WindowGeometry,
};
pub use i18n::{t, I18nKey, Locale};
pub use layout::{
    layout_state_path, load_persisted_preset, save_persisted_preset, xdg_state_home,
    HyprGeometrySpec, LayoutPreset,
};
pub use state::{
    monitor_id_for, resolve_keyboard_alias, AppState, AudioDeviceInfo, AudioState, AudioStreamInfo,
    BacklightState, BatteryDeviceDetail, BatteryState, BluetoothDeviceInfo, BluetoothState,
    CalendarEvent, CalendarSourceStatus, CalendarState, ClockTime, CustomActivity, DiskMountInfo,
    DisplayActivity, DisplayStatus, KeyboardState, MediaPlayback, MediaState, MonitorState,
    NetworkKind, NetworkState, NotificationAction, NotificationItem, NotificationUrgency,
    OutputInfo, PowerCapabilities, PowerProfileState, PrivacyState, RecordActivity,
    ScreenTimeAppUsage, ScreenTimeState, SysmonState, ThemeMode, TrayItem, TrayMenuEntry,
    TrayMenuState, UserAccountState, VpnInfo, WeatherDaily, WeatherHourly, WeatherState,
    WifiApInfo, WorkspaceState,
};
pub use surface::{
    Anchor, Color, CornerPos, EdgeInsets, HitTarget, IconKind, KeyboardMode, Layer, PaintCmd, Rect,
    SurfaceSpec, TextAlign,
};
pub use text_input::{TextDirection, TextInputOutcome, TextInputState};
pub use theme::{GeneratedTheme, PaletteColors, ResolvedPalette, TerminalColors, ThemePaths};
