use bitflags::bitflags;
use std::path::PathBuf;
use std::sync::Arc;

use crate::i18n::Locale;
use crate::layout::LayoutPreset;
use crate::state::{
    AppState, AudioState, BacklightState, BatteryState, BluetoothState, CalendarState, ClockTime,
    MediaState, MonitorState, NetworkState, NotificationItem, OutputInfo, PowerCapabilities,
    PowerProfileState, PrivacyState, ScreenTimeState, SysmonState, ThemeMode, TrayItem,
    TrayMenuState, UserAccountState, WeatherState, WorkspaceState,
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
        const IDLE      = 1 << 11;
        const SESSION   = 1 << 12;
        const POLKIT    = 1 << 13;
        const CAPTURE   = 1 << 14;
        const DOCK      = 1 << 15;
        const SWITCHER  = 1 << 16;
        const CORNERS   = 1 << 17;
        const CANVAS    = 1 << 18;
        const ALL       = 0b0111_1111_1111_1111_1111;
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
    KeyboardLayout,
    LockKeys,
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
    PointerMotion {
        surface_id: String,
        x: f32,
        y: f32,
    },
    PointerEnter {
        surface_id: String,
        x: f32,
        y: f32,
    },
    PointerLeave {
        surface_id: String,
    },
    PointerRelease {
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
    ModifiersChanged {
        surface_id: String,
        modifiers: KeyModifiers,
        caps_lock: bool,
        num_lock: bool,
        scroll_lock: bool,
        layout_idx: u32,
    },
    WindowsUpdated {
        windows: Vec<WindowGeometry>,
        active_address: Option<String>,
        fullscreen_outputs: Vec<String>,
    },
    KeyboardLayoutChanged {
        raw_name: String,
        source: String,
    },
    LockKeysChanged {
        caps_lock: bool,
        num_lock: bool,
        scroll_lock: bool,
    },
    WidgetExecOutput {
        instance_id: String,
        output: String,
    },
    SettingsOpenRequested {
        target: String,
    },
    SysmonUpdated(SysmonState),
    WeatherUpdated(WeatherState),
    ScreenTimeUpdated(ScreenTimeState),
    CalendarUpdated(CalendarState),
    WindowPreviewReady {
        request_id: u64,
        address: String,
        width: u32,
        height: u32,
        rgba_premul: Arc<[u8]>,
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
    IdleTimeout {
        id: String,
    },
    IdleResumed {
        id: String,
    },
    PrepareForSleep(bool),
    SessionLockRequested,
    SessionUnlockRequested,
    LockWorkerCommitted,
    LockWorkerExited,
    PowerCapabilitiesChanged(PowerCapabilities),
    PolkitBusOwned(bool),
    PolkitBegin(PolkitRequest),
    PolkitCancel {
        cookie: String,
    },
    PolkitPrompt {
        cookie: String,
        prompt: String,
        echo: bool,
    },
    PolkitError {
        cookie: String,
        message: String,
    },
    PolkitComplete {
        cookie: String,
        success: bool,
    },
    ScreencopyReady {
        request_id: u64,
        frames: Vec<CapturedOutputFrame>,
        windows: Vec<WindowGeometry>,
    },
    ScreencopyFailed {
        request_id: u64,
        error: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CapturedOutputFrame {
    pub output_name: String,
    pub logical_x: i32,
    pub logical_y: i32,
    pub logical_w: u32,
    pub logical_h: u32,
    pub pixel_w: u32,
    pub pixel_h: u32,
    /// Upright straight RGBA8888 pixels.
    pub rgba: Arc<[u8]>,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct WindowGeometry {
    pub address: String,
    pub title: String,
    pub class: String,
    pub initial_class: String,
    pub workspace_id: i32,
    pub monitor: String,
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
    pub floating: bool,
    pub fullscreen: bool,
    pub focused: bool,
    pub pid: i32,
    pub focus_history_id: i32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PolkitRequest {
    pub cookie: String,
    pub action_id: String,
    pub message: String,
    pub icon_name: String,
    pub identities: Vec<String>,
    pub details: Vec<(String, String)>,
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
    ConfigureIdleTimeouts(Vec<(String, u64)>),
    SetOutputsDpms(bool),
    ReleaseSleepInhibitor,
    LockSession,
    PolkitSubmitPassword {
        cookie: String,
        user: String,
        password: String,
    },
    PolkitCancel {
        cookie: String,
    },
    RequestScreencopy {
        request_id: u64,
    },
    CaptureReply {
        text: Option<String>,
    },
    SendNotification {
        app_name: String,
        summary: String,
        body: String,
    },
    SettingsOpen(String),
    PersistSetting {
        key: String,
        value_toml: String,
    },
    SetSpectrumSubscriber {
        owner: String,
        active: bool,
    },
    SetSysmonSubscriber {
        owner: String,
        active: bool,
    },
    RunWidgetExec {
        instance_id: String,
        command: String,
    },
    RequestWindowPreviews {
        request_id: u64,
        windows: Vec<(String, String, String)>,
    },
    NetworkRequestScan,
    WifiConnect {
        ssid: String,
        password: String,
    },
    WifiDisconnect,
    WifiForget(String),
    VpnToggle(String),
    BluetoothSetDiscovery(bool),
    BluetoothPair(String),
    BluetoothTrust {
        path: String,
        trusted: bool,
    },
    BluetoothConnect(String),
    BluetoothDisconnect(String),
    BluetoothRemove(String),
    WeatherRefresh,
    ScreenTimeReset,
    CalendarSyncNow,
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
