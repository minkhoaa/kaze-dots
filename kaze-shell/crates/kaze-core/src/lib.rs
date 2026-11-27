pub mod config;
pub mod extension;
pub mod state;
pub mod surface;
pub mod theme;

pub use config::{BarConfig, BarPosition, Config, DisplayConfig, ThemeConfig};
pub use extension::{
    DirtyFlags, IpcResult, KazeExtension, PointerButton, ShellAction, ShellContext, SystemEvent,
};
pub use state::{
    AppState, ClockTime, DisplayStatus, MonitorState, OutputInfo, ThemeMode, WorkspaceState,
};
pub use surface::{
    Anchor, Color, EdgeInsets, HitTarget, Layer, PaintCmd, Rect, SurfaceSpec, TextAlign,
};
pub use theme::{GeneratedTheme, PaletteColors, ResolvedPalette, TerminalColors, ThemePaths};
