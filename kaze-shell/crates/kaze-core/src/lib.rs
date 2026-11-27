#![deny(clippy::unwrap_used)]

pub mod anim;
pub mod config;
pub mod extension;
pub mod layout;
pub mod state;
pub mod surface;
pub mod theme;

pub use anim::{Spring, SPRING_MAX_DT_SECS, SPRING_POS_EPSILON, SPRING_VEL_EPSILON};
pub use config::{
    BarConfig, BarPosition, Config, DisplayConfig, IslandConfig, IslandStyle, LauncherConfig,
    LayoutConfig, NotifyConfig, OsdConfig, ThemeConfig,
};
pub use extension::{
    DirtyFlags, ImeEvent, IpcResult, KazeExtension, KeyEvent, KeyModifiers, OsdKind, PointerButton,
    ShellAction, ShellContext, SystemEvent,
};
pub use layout::{
    layout_state_path, load_persisted_preset, save_persisted_preset, xdg_state_home,
    HyprGeometrySpec, LayoutPreset,
};
pub use state::{
    AppState, AudioState, BacklightState, BatteryState, ClockTime, CustomActivity, DisplayActivity,
    DisplayStatus, MediaPlayback, MediaState, MonitorState, NetworkKind, NetworkState,
    NotificationAction, NotificationItem, NotificationUrgency, OutputInfo, RecordActivity,
    ThemeMode, WorkspaceState,
};
pub use surface::{
    Anchor, Color, EdgeInsets, HitTarget, IconKind, KeyboardMode, Layer, PaintCmd, Rect,
    SurfaceSpec, TextAlign,
};
pub use theme::{GeneratedTheme, PaletteColors, ResolvedPalette, TerminalColors, ThemePaths};
