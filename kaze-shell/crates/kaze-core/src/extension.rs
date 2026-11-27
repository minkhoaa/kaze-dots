use bitflags::bitflags;

use crate::state::{AppState, ClockTime, MonitorState, OutputInfo, ThemeMode, WorkspaceState};
use crate::surface::SurfaceSpec;

bitflags! {
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
    pub struct DirtyFlags: u32 {
        const NONE   = 0;
        const BAR    = 1 << 0;
        const ISLAND = 1 << 1;
        const OSD    = 1 << 2;
        const LAYOUT = 1 << 3;
        const THEME  = 1 << 4;
        const ALL    = 0b0001_1111;
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PointerButton {
    Left,
    Right,
    Middle,
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
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ShellAction {
    HyprDispatch(String),
    SpawnCommand { program: String, args: Vec<String> },
    ApplyTemplates,
    ReloadConfig,
    SyncSurfaces,
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
