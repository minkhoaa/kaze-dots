use bitflags::bitflags;
use std::path::PathBuf;

use crate::i18n::Locale;
use crate::layout::LayoutPreset;
use crate::state::{
    AppState, AudioState, BacklightState, BatteryState, BluetoothState, ClockTime, MediaState,
    MonitorState, NetworkState, NotificationItem, OutputInfo, PowerProfileState, PrivacyState,
    ThemeMode, TrayItem, TrayMenuState, UserAccountState, WorkspaceState,
};
use crate::surface::SurfaceSpec;
use crate::theme::ResolvedPalette;

bitflags! {
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
    pub struct DirtyFlags: u32 {
        const NONE      = 0;
        const BAR       = 1 << 0;
        const ISLAND    = 1 << 1;
        const OSD       = 1 << 2;
        const LAYOUT    = 1 << 3;
        const THEME     = 1 << 4;
        const NOTIFY    = 1 << 5;
        const LAUNCHER  = 1 << 6;
        const CC        = 1 << 7;
        const TRAY      = 1 << 8;
        const WALLPAPER = 1 << 9;
        const CLIPBOARD = 1 << 10;
        const ALL       = 0b0111_1111_1111;
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
    FrameTick {
        surface_id: String,
        dt_secs: f32,
    },
    LayoutPresetChanged(LayoutPreset),
    ConfigReloaded,
    ThemeChanged(ThemeMode),
    PointerClick {
        surface_id: String,
        target_id: String,
        button: PointerButton,
    },
    PointerClickAt {
        surface_id: String,
        target_id: String,
        button: PointerButton,
        x: f32,
        y: f32,
    },
    PointerDrag {
        surface_id: String,
        target_id: String,
        x: f32,
        y: f32,
    },
    PointerScroll {
        surface_id: String,
        target_id: String,
        delta_y: f64,
        modifiers: KeyModifiers,
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
    BluetoothChanged(BluetoothState),
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
    NotificationReceived(NotificationItem),
    NotificationCloseRequested {
        id: u32,
    },
    NotificationDismissHistory {
        id: u32,
    },
    NotificationClearAll,
    NotificationsBusStatus {
        owned: bool,
    },
    NotificationsCountChanged(u32),
    DndChanged(bool),
    NightLightChanged {
        enabled: bool,
        temp_k: u32,
    },
    CaffeineChanged(bool),
    ControlCenterChanged(bool),
    TrayBusStatus {
        owned: bool,
    },
    TrayItemsChanged(Vec<TrayItem>),
    TrayMenuLoaded(TrayMenuState),
    WallpaperReady {
        path: PathBuf,
        palette: Option<Box<ResolvedPalette>>,
        buffers: Vec<(String, u32, u32, Vec<u8>)>,
    },
    WallpaperFailed {
        error: String,
    },
    SurfaceClosed {
        surface_id: String,
    },
    KeyboardFocusLost {
        surface_id: String,
    },
    ApplicationsChanged,
    UserAccountChanged(UserAccountState),
    OfflineModeChanged(bool),
    LocaleChanged(Locale),
    ClipboardTextPasted {
        surface_id: String,
        text: String,
    },
    ClipboardOfferCaptured {
        mime: String,
        bytes: Vec<u8>,
        source_is_self: bool,
    },
    PowerProfileChanged(PowerProfileState),
    PrivacyChanged(PrivacyState),
    AudioSpectrum(Vec<u8>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ShellAction {
    HyprDispatch(String),
    SpawnCommand {
        program: String,
        args: Vec<String>,
    },
    SpawnDetachedApp {
        program: String,
        args: Vec<String>,
    },
    ApplyTemplates,
    ReloadConfig,
    SyncSurfaces,
    ScheduleTimer {
        id: String,
        after_ms: u64,
    },
    CancelTimer {
        id: String,
    },
    AudioStepVolume(i32),
    AudioSetVolume(u8),
    AudioToggleMute,
    AudioToggleMicMute,
    BacklightStep(i32),
    BacklightSet(u8),
    MediaCommand(String),
    WifiToggle,
    BluetoothToggle,
    SetNightLight {
        enabled: bool,
        temp_k: u32,
    },
    SetCaffeine(bool),
    ThemeModeToggle,
    LayoutCycle,
    ToggleControlCenter,
    SystemPower(String),
    NotifyClosed {
        id: u32,
        reason: u32,
    },
    NotifyActionInvoked {
        id: u32,
        action_key: String,
    },
    DismissHistoryNotification(u32),
    SetDnd(bool),
    ClearNotifications,
    TrayActivate {
        service: String,
        object_path: String,
        x: i32,
        y: i32,
        secondary: bool,
    },
    TrayOpenMenu {
        service: String,
        menu_path: String,
    },
    TrayMenuClick {
        service: String,
        menu_path: String,
        item_id: i32,
    },
    RequestWallpaperLoad {
        path: PathBuf,
        outputs: Vec<(String, u32, u32)>,
        extract_palette: bool,
    },
    ClearWallpaper,
    DmenuReply {
        selected: Option<String>,
    },
    RunHook {
        event: String,
        old: Option<String>,
        new: Option<String>,
        value: Option<String>,
    },
    SetClipboardText(String),
    SetClipboardSelection {
        mime: String,
        bytes: Vec<u8>,
    },
    RequestClipboardPaste {
        surface_id: String,
    },
    SetPowerProfile(String),
    SetBrightnessMonitor {
        monitor: String,
        pct: u8,
    },
    AudioSetDefaultSink(String),
    AudioSetDefaultSource(String),
    AudioSetStreamVolume {
        index: u32,
        pct: u8,
    },
    AudioSetStreamMute {
        index: u32,
        muted: bool,
    },
    AudioSetSpectrumSubscribed(usize),
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
