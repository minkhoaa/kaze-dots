#![deny(clippy::unwrap_used)]

pub mod config;
pub mod extension;
pub mod state;
pub mod surface;
pub mod theme;

pub use config::{
    BarConfig, BarPosition, Config, DisplayConfig, NotifyConfig, OsdConfig, ThemeConfig,
};
pub use extension::{
    DirtyFlags, ImeEvent, IpcResult, KazeExtension, KeyEvent, KeyModifiers, OsdKind, PointerButton,
    ShellAction, ShellContext, SystemEvent,
};
pub use state::{
    AppState, AudioState, BacklightState, BatteryState, ClockTime, DisplayStatus, MediaPlayback,
    MediaState, MonitorState, NetworkKind, NetworkState, NotificationAction, NotificationItem,
    NotificationUrgency, OutputInfo, ThemeMode, WorkspaceState,
};
pub use surface::{
    Anchor, Color, EdgeInsets, HitTarget, IconKind, KeyboardMode, Layer, PaintCmd, Rect,
    SurfaceSpec, TextAlign,
};
pub use theme::{GeneratedTheme, PaletteColors, ResolvedPalette, TerminalColors, ThemePaths};
