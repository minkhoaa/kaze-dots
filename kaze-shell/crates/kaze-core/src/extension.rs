use bitflags::bitflags;

use crate::state::{
    AppState, AudioState, BacklightState, BatteryState, ClockTime, MediaState, MonitorState,
    NetworkState, OutputInfo, ThemeMode, WorkspaceState,
};
use crate::surface::SurfaceSpec;

bitflags! {
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
    pub struct DirtyFlags: u32 {
        const NONE     = 0;
        const BAR      = 1 << 0;
        const ISLAND   = 1 << 1;
        const OSD      = 1 << 2;
        const LAYOUT   = 1 << 3;
        const THEME    = 1 << 4;
        const NOTIFY   = 1 << 5;
        const LAUNCHER = 1 << 6;
        const ALL      = 0b0111_1111;
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PointerButton {
    Left,
    Right,
    Middle,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct KeyModifiers {
    pub ctrl: bool,
    pub alt: bool,
    pub shift: bool,
    pub logo: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyEvent {
    pub keysym: u32,
    pub utf8: Option<String>,
    pub modifiers: KeyModifiers,
    pub pressed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ImeEvent {
    Preedit {
        text: String,
        cursor_begin: i32,
        cursor_end: i32,
    },
    Commit(String),
    DeleteSurrounding {
        before: u32,
        after: u32,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OsdKind {
    Volume,
    Mic,
    Brightness,
}

#[derive(Debug, Clone, PartialEq)]
pub enum SystemEvent {
    OutputAdded(OutputInfo),
    OutputUpdated(OutputInfo),
    OutputRemoved {
        name: String,
    },
    HyprSynced {
        monitors: Vec<MonitorState>,
        workspaces: Vec<WorkspaceState>,
        active_workspace_id: i32,
        focused_monitor: Option<String>,
    },
    HyprWorkspaceChanged {
        id: i32,
        name: String,
    },
    HyprFocusedMonitor {
        monitor: String,
        workspace_id: Option<i32>,
    },
    HyprConnectionChanged {
        connected: bool,
    },
    ClockTick(ClockTime),
    ConfigReloaded,
    ThemeChanged(ThemeMode),
    PointerClick {
        surface_id: String,
        target_id: String,
        button: PointerButton,
    },
    PointerScroll {
        surface_id: String,
        target_id: String,
        delta_y: f64,
    },
    KeyInput {
        surface_id: String,
        key: KeyEvent,
    },
    ImeInput {
        surface_id: String,
        ime: ImeEvent,
    },
    TimerFired {
        id: String,
    },
    NetworkChanged(NetworkState),
    BatteryChanged(BatteryState),
    AudioChanged {
        state: AudioState,
        trigger_osd: Option<OsdKind>,
    },
    BacklightChanged {
        state: BacklightState,
        trigger_osd: bool,
    },
    MediaChanged(MediaState),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ShellAction {
    HyprDispatch(String),
    SpawnCommand { program: String, args: Vec<String> },
    SpawnDetachedApp { program: String, args: Vec<String> },
    ApplyTemplates,
    ReloadConfig,
    SyncSurfaces,
    ScheduleTimer { id: String, after_ms: u64 },
    CancelTimer { id: String },
    AudioStepVolume(i32),
    AudioToggleMute,
    AudioToggleMicMute,
    BacklightStep(i32),
    MediaCommand(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IpcResult {
    Handled {
        ok: bool,
        message: String,
        dirty: DirtyFlags,
    },
    Unhandled,
}

pub struct ShellContext<'a> {
    pub state: &'a mut AppState,
    pub actions: Vec<ShellAction>,
    pub dirty: DirtyFlags,
}

impl<'a> ShellContext<'a> {
    pub fn new(state: &'a mut AppState) -> Self {
        Self {
            state,
            actions: Vec::new(),
            dirty: DirtyFlags::NONE,
        }
    }

    pub fn push_action(&mut self, action: ShellAction) {
        self.actions.push(action);
    }

    pub fn mark_dirty(&mut self, flags: DirtyFlags) {
        self.dirty |= flags;
    }
}

pub trait KazeExtension: Send {
    fn id(&self) -> &'static str;
    fn on_init(&mut self, ctx: &mut ShellContext);
    fn on_event(&mut self, event: &SystemEvent, ctx: &mut ShellContext) -> DirtyFlags;
    fn on_ipc(&mut self, cmd: &str, args: &[String], ctx: &mut ShellContext) -> IpcResult;
    fn surfaces(&self) -> Vec<SurfaceSpec>;
}
