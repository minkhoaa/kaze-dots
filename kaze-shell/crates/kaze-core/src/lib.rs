#![deny(clippy::unwrap_used)]

pub mod anim;
pub mod config;
pub mod crypto;
pub mod dconf_read;
pub mod extension;
pub mod i18n;
pub mod layout;
pub mod state;
pub mod surface;
pub mod text_input;
pub mod theme;

pub use anim::{Spring, SPRING_MAX_DT_SECS, SPRING_POS_EPSILON, SPRING_VEL_EPSILON};
pub use config::{
    AccessibilityConfig, AudioConfig, BarConfig, BarPosition, BrightnessConfig, CaptureConfig,
    ClipboardConfig, Config, DisplayConfig, GeneralConfig, HooksConfig, IdleConfig, InputConfig,
    InputKeybindsConfig, IslandConfig, IslandStyle, LauncherConfig, LayoutConfig, LocationConfig,
    LockscreenConfig, NetworkConfig, NotifyConfig, OsdConfig, PrivacyConfig, SessionConfig,
    SettingsStore, ThemeConfig, ValidationIssue, ValidationReport, ValidationSeverity,
    WallpaperConfig,
};
pub use crypto::{check_network_allowed, EncryptedRecordStore, MasterKey};
pub use dconf_read::read_gnome_text_scaling_factor;
pub use extension::{
    DirtyFlags, ImeEvent, IpcResult, KazeExtension, KeyEvent, KeyModifiers, OsdKind, PointerButton,
    ShellAction, ShellContext, SystemEvent,
};
pub use i18n::{t, I18nKey, Locale};
pub use layout::{
    layout_state_path, load_persisted_preset, save_persisted_preset, xdg_state_home,
    HyprGeometrySpec, LayoutPreset,
};
pub use state::{
    AppState, AudioState, BacklightState, BatteryState, BluetoothState, ClockTime, CustomActivity,
    DisplayActivity, DisplayStatus, MediaPlayback, MediaState, MonitorState, NetworkKind,
    NetworkState, NotificationAction, NotificationItem, NotificationUrgency, OutputInfo,
    RecordActivity, ThemeMode, TrayItem, TrayMenuEntry, TrayMenuState, UserAccountState,
    WorkspaceState,
};
pub use surface::{
    Anchor, Color, EdgeInsets, HitTarget, IconKind, KeyboardMode, Layer, PaintCmd, Rect,
    SurfaceSpec, TextAlign,
};
pub use text_input::{TextDirection, TextInputOutcome, TextInputState};
pub use theme::{GeneratedTheme, PaletteColors, ResolvedPalette, TerminalColors, ThemePaths};
