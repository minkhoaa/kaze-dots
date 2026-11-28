use kaze_core::{HyprGeometrySpec, MonitorState, WindowGeometry, WorkspaceState};
use serde::Deserialize;
use std::env;
use std::fmt;
use std::io::{self, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

#[derive(Debug)]
pub enum HyprError {
    MissingEnv(&'static str),
    Io(io::Error),
    Json(serde_json::Error),
}

impl fmt::Display for HyprError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingEnv(var) => write!(f, "environment variable {var} is not set"),
            Self::Io(err) => write!(f, "hyprland socket I/O error: {err}"),
            Self::Json(err) => write!(f, "hyprland JSON decode error: {err}"),
        }
    }
}

impl std::error::Error for HyprError {}

impl From<io::Error> for HyprError {
    fn from(value: io::Error) -> Self {
        Self::Io(value)
    }
}

impl From<serde_json::Error> for HyprError {
    fn from(value: serde_json::Error) -> Self {
        Self::Json(value)
    }
}

#[derive(Debug, Clone)]
pub struct HyprPaths {
    pub command_sock: PathBuf,
    pub event_sock: PathBuf,
}

impl HyprPaths {
    pub fn from_env() -> Result<Self, HyprError> {
        let runtime = env::var("XDG_RUNTIME_DIR")
            .ok()
            .filter(|v| !v.is_empty())
            .ok_or(HyprError::MissingEnv("XDG_RUNTIME_DIR"))?;
        let sig = env::var("HYPRLAND_INSTANCE_SIGNATURE")
            .ok()
            .filter(|v| !v.is_empty())
            .ok_or(HyprError::MissingEnv("HYPRLAND_INSTANCE_SIGNATURE"))?;
        let base = PathBuf::from(runtime).join("hypr").join(sig);
        Ok(Self {
            command_sock: base.join(".socket.sock"),
            event_sock: base.join(".socket2.sock"),
        })
    }
}

/// Loose serde models with `#[serde(default)]` everywhere so upstream Hyprland
/// field additions or omissions never panic or crash deserialization.
#[derive(Debug, Clone, Deserialize, Default)]
#[serde(default)]
struct RawWorkspaceRef {
    id: i32,
    name: String,
}

#[derive(Debug, Clone, Deserialize, Default)]
#[serde(default)]
struct RawMonitor {
    id: i32,
    name: String,
    width: i32,
    height: i32,
    scale: f32,
    focused: bool,
    disabled: bool,
    #[serde(rename = "activeWorkspace")]
    active_workspace: RawWorkspaceRef,
}

#[derive(Debug, Clone, Deserialize, Default)]
#[serde(default)]
struct RawWorkspace {
    id: i32,
    name: String,
    monitor: String,
    windows: u32,
}

#[derive(Debug, Clone, Default)]
pub struct HyprSnapshot {
    pub monitors: Vec<MonitorState>,
    pub workspaces: Vec<WorkspaceState>,
    pub active_workspace_id: i32,
    pub focused_monitor: Option<String>,
}

#[derive(Debug, Clone)]
pub struct HyprClient {
    paths: HyprPaths,
    io_timeout: Duration,
}

impl HyprClient {
    pub fn new(paths: HyprPaths) -> Self {
        Self {
            paths,
            io_timeout: Duration::from_millis(500),
        }
    }

    pub fn from_env() -> Result<Self, HyprError> {
        Ok(Self::new(HyprPaths::from_env()?))
    }

    pub fn paths(&self) -> &HyprPaths {
        &self.paths
    }

    pub fn request(&self, command: &str) -> Result<String, HyprError> {
        let mut stream = UnixStream::connect(&self.paths.command_sock)?;
        let _ = stream.set_read_timeout(Some(self.io_timeout));
        let _ = stream.set_write_timeout(Some(self.io_timeout));
        stream.write_all(command.as_bytes())?;
        let _ = stream.shutdown(std::net::Shutdown::Write);
        let mut response = String::new();
        stream.read_to_string(&mut response)?;
        Ok(response)
    }

    pub fn dispatch(&self, args: &str) -> Result<String, HyprError> {
        self.request(&format!("/dispatch {args}"))
    }

    pub fn keyword(&self, key: &str, value: &str) -> Result<String, HyprError> {
        self.request(&format!("/keyword {key} {value}"))
    }

    pub fn eval(&self, lua_code: &str) -> Result<String, HyprError> {
        self.request(&format!("/eval {lua_code}"))
    }

    /// Switches workspace via Hyprland 0.57+ Lua `eval` with automatic fallback
    /// to legacy `/dispatch workspace <id>`.
    pub fn switch_workspace(&self, id: i32) -> Result<String, HyprError> {
        let lua = format!("hl.dispatch(hl.dsp.focus({{ workspace = \"{id}\" }}))");
        match self.eval(&lua) {
            Ok(resp) if !resp.contains("unknown request") && !resp.contains("error") => Ok(resp),
            _ => self.dispatch(&format!("workspace {id}")),
        }
    }

    /// Applies layout preset geometry in a single batched Hyprland Lua `/eval` call
    /// (with keyword fallback), strictly scoped to gaps/border/rounding/blur so
    /// `hypr/user.lua` monitor/input settings and edge-to-edge workspace rules remain intact.
    pub fn apply_layout_geometry(&self, geom: &HyprGeometrySpec) -> Result<String, HyprError> {
        let lua = format_layout_geometry_lua(geom);
        match self.eval(&lua) {
            Ok(resp) if !resp.contains("unknown request") && !resp.contains("error") => Ok(resp),
            _ => {
                let batch = format_layout_geometry_batch(geom);
                self.request(&batch)
            }
        }
    }

    pub fn set_privacy_noscreenshare(&self, patterns: &[String], enable: bool) {
        for (idx, pat) in patterns.iter().enumerate() {
            let trimmed = pat.trim();
            if trimmed.is_empty() {
                continue;
            }
            let escaped = trimmed.replace('\\', "\\\\").replace('"', "\\\"");
            let flag = if enable { "true" } else { "false" };
            let lua = format!(
                "hl.window_rule({{ name = \"kaze-privacy-{idx}\", match = {{ class = \"^{escaped}$\" }}, no_screen_share = {flag} }})"
            );
            let eval_ok = self
                .eval(&lua)
                .is_ok_and(|resp| !resp.contains("unknown request") && !resp.contains("error"));
            if !eval_ok {
                let effect = if enable { "noscreenshare" } else { "unset" };
                let _ = self.keyword("windowrule", &format!("{effect},^({trimmed})$"));
            }
        }
    }

    pub fn snapshot(&self) -> Result<HyprSnapshot, HyprError> {
        let monitors_raw = self.request("j/monitors")?;
        let workspaces_raw = self.request("j/workspaces")?;
        let active_raw = self.request("j/activeworkspace").unwrap_or_default();
        parse_snapshot(&monitors_raw, &workspaces_raw, &active_raw)
    }

    pub fn clients(&self) -> Result<Vec<WindowGeometry>, HyprError> {
        let raw = self.request("j/clients")?;
        parse_clients(&raw)
    }

    pub fn connect_event_stream(&self) -> Result<HyprEventStream, HyprError> {
        HyprEventStream::connect(&self.paths.event_sock)
    }
}

pub fn format_layout_geometry_lua(geom: &HyprGeometrySpec) -> String {
    let blur = if geom.blur_enabled { "true" } else { "false" };
    format!(
        "hl.config({{ general = {{ gaps_in = {}, gaps_out = {}, border_size = {} }}, decoration = {{ rounding = {}, blur = {{ enabled = {} }} }} }})",
        geom.gaps_in, geom.gaps_out, geom.border_size, geom.rounding, blur
    )
}

pub fn format_layout_geometry_batch(geom: &HyprGeometrySpec) -> String {
    let blur = if geom.blur_enabled { 1 } else { 0 };
    format!(
        "[[BATCH]]keyword general:gaps_in {};keyword general:gaps_out {};keyword general:border_size {};keyword decoration:rounding {};keyword decoration:blur:enabled {}",
        geom.gaps_in, geom.gaps_out, geom.border_size, geom.rounding, blur
    )
}

pub fn parse_snapshot(
    monitors_json: &str,
    workspaces_json: &str,
    active_ws_json: &str,
) -> Result<HyprSnapshot, HyprError> {
    let raw_monitors: Vec<RawMonitor> = serde_json::from_str(monitors_json)?;
    let raw_workspaces: Vec<RawWorkspace> = serde_json::from_str(workspaces_json)?;
    let active_ref: RawWorkspaceRef = serde_json::from_str(active_ws_json).unwrap_or_default();

    let focused_monitor = raw_monitors
        .iter()
        .find(|m| m.focused && !m.name.is_empty())
        .map(|m| m.name.clone());

    let monitors: Vec<MonitorState> = raw_monitors
        .into_iter()
        .map(|m| MonitorState {
            id: m.id,
            name: m.name,
            width: m.width,
            height: m.height,
            scale: if m.scale > 0.0 { m.scale } else { 1.0 },
            focused: m.focused,
            disabled: m.disabled,
            active_workspace_id: m.active_workspace.id,
        })
        .collect();

    let mut workspaces: Vec<WorkspaceState> = raw_workspaces
        .into_iter()
        .filter(|w| w.id > 0)
        .map(|w| WorkspaceState {
            id: w.id,
            name: w.name,
            monitor: w.monitor,
            windows: w.windows,
            urgent: false,
        })
        .collect();
    workspaces.sort_by_key(|w| w.id);

    let active_workspace_id = if active_ref.id > 0 {
        active_ref.id
    } else {
        monitors
            .iter()
            .find(|m| m.focused)
            .map(|m| m.active_workspace_id)
            .filter(|&id| id > 0)
            .unwrap_or(1)
    };

    Ok(HyprSnapshot {
        monitors,
        workspaces,
        active_workspace_id,
        focused_monitor,
    })
}

#[derive(Debug, Clone, Deserialize, Default)]
#[serde(default)]
struct RawClient {
    address: String,
    title: String,
    class: String,
    at: [i32; 2],
    size: [i32; 2],
    mapped: bool,
    hidden: bool,
    floating: bool,
    monitor: serde_json::Value,
    workspace: RawWorkspaceRef,
}

pub fn parse_clients(clients_json: &str) -> Result<Vec<WindowGeometry>, HyprError> {
    let raw: Vec<RawClient> = serde_json::from_str(clients_json)?;
    Ok(raw
        .into_iter()
        .filter(|c| c.mapped && !c.hidden && c.size[0] > 0 && c.size[1] > 0)
        .map(|c| WindowGeometry {
            address: c.address,
            title: c.title,
            class: c.class,
            workspace_id: c.workspace.id,
            monitor: match c.monitor {
                serde_json::Value::String(s) => s,
                serde_json::Value::Number(n) => n.to_string(),
                _ => String::new(),
            },
            x: c.at[0],
            y: c.at[1],
            w: c.size[0],
            h: c.size[1],
            floating: c.floating,
        })
        .collect())
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HyprEvent {
    WorkspaceV2 {
        id: i32,
        name: String,
    },
    Workspace {
        name: String,
    },
    FocusedMonV2 {
        monitor: String,
        workspace_id: i32,
    },
    FocusedMon {
        monitor: String,
        workspace_name: String,
    },
    CreateWorkspace {
        name: String,
    },
    DestroyWorkspace {
        name: String,
    },
    MoveWorkspace {
        name: String,
        monitor: String,
    },
    MonitorAdded {
        name: String,
    },
    MonitorRemoved {
        name: String,
    },
    WindowChanged,
    ConfigReloaded,
    Urgent {
        address: String,
    },
    Screencast {
        active: bool,
        owner: u32,
    },
    Other {
        kind: String,
        data: String,
    },
}

impl HyprEvent {
    pub fn parse_line(line: &str) -> Option<Self> {
        let trimmed = line.trim_end_matches(['\r', '\n']);
        let (kind, data) = trimmed.split_once(">>")?;
        let ev = match kind {
            "workspacev2" => {
                let (id_str, name) = data.split_once(',').unwrap_or((data, data));
                let id = id_str.parse::<i32>().unwrap_or(0);
                Self::WorkspaceV2 {
                    id,
                    name: name.to_string(),
                }
            }
            "workspace" => Self::Workspace {
                name: data.to_string(),
            },
            "focusedmonv2" => {
                let (mon, ws_str) = data.split_once(',').unwrap_or((data, "0"));
                Self::FocusedMonV2 {
                    monitor: mon.to_string(),
                    workspace_id: ws_str.parse::<i32>().unwrap_or(0),
                }
            }
            "focusedmon" => {
                let (mon, ws) = data.split_once(',').unwrap_or((data, ""));
                Self::FocusedMon {
                    monitor: mon.to_string(),
                    workspace_name: ws.to_string(),
                }
            }
            "createworkspace" | "createworkspacev2" => Self::CreateWorkspace {
                name: data.to_string(),
            },
            "destroyworkspace" | "destroyworkspacev2" => Self::DestroyWorkspace {
                name: data.to_string(),
            },
            "moveworkspace" | "moveworkspacev2" => {
                let mut parts = data.rsplitn(2, ',');
                let monitor = parts.next().unwrap_or("").to_string();
                let name = parts.next().unwrap_or(data).to_string();
                Self::MoveWorkspace { name, monitor }
            }
            "monitoradded" => Self::MonitorAdded {
                name: data.to_string(),
            },
            "monitoraddedv2" => {
                let name = data.split(',').nth(1).unwrap_or(data).to_string();
                Self::MonitorAdded { name }
            }
            "monitorremoved" => Self::MonitorRemoved {
                name: data.to_string(),
            },
            "monitorremovedv2" => {
                let name = data.split(',').nth(1).unwrap_or(data).to_string();
                Self::MonitorRemoved { name }
            }
            "openwindow" | "closewindow" | "movewindow" | "movewindowv2" => Self::WindowChanged,
            "configreloaded" => Self::ConfigReloaded,
            "urgent" => Self::Urgent {
                address: data.to_string(),
            },
            "screencast" => {
                let (state_s, owner_s) = data.split_once(',').unwrap_or((data, "0"));
                Self::Screencast {
                    active: state_s.trim() == "1",
                    owner: owner_s.trim().parse::<u32>().unwrap_or(0),
                }
            }
            _ => Self::Other {
                kind: kind.to_string(),
                data: data.to_string(),
            },
        };
        Some(ev)
    }

    pub fn requires_full_resync(&self) -> bool {
        matches!(
            self,
            Self::CreateWorkspace { .. }
                | Self::DestroyWorkspace { .. }
                | Self::MoveWorkspace { .. }
                | Self::MonitorAdded { .. }
                | Self::MonitorRemoved { .. }
                | Self::WindowChanged
                | Self::ConfigReloaded
        )
    }
}

/// Non-blocking reader around Hyprland `.socket2.sock` suitable for `calloop::generic::Generic`.
pub struct HyprEventStream {
    stream: UnixStream,
    buf: Vec<u8>,
}

impl HyprEventStream {
    pub fn connect(path: &std::path::Path) -> Result<Self, HyprError> {
        let stream = UnixStream::connect(path)?;
        stream.set_nonblocking(true)?;
        Ok(Self {
            stream,
            buf: Vec::with_capacity(4096),
        })
    }

    pub fn stream(&self) -> &UnixStream {
        &self.stream
    }

    /// Reads all immediately available events. Returns `Ok(None)` on EOF / disconnect.
    pub fn read_events(&mut self) -> Result<Option<Vec<HyprEvent>>, io::Error> {
        let mut tmp = [0u8; 4096];
        let mut eof = false;
        loop {
            match self.stream.read(&mut tmp) {
                Ok(0) => {
                    eof = true;
                    break;
                }
                Ok(n) => {
                    // Guard against unbounded line growth from malformed input.
                    if self.buf.len().saturating_add(n) > 256 * 1024 {
                        self.buf.clear();
                    }
                    self.buf.extend_from_slice(&tmp[..n]);
                }
                Err(err) if err.kind() == io::ErrorKind::WouldBlock => break,
                Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
                Err(err) => return Err(err),
            }
        }

        let mut events = Vec::new();
        while let Some(pos) = self.buf.iter().position(|&b| b == b'\n') {
            let line_bytes: Vec<u8> = self.buf.drain(..=pos).collect();
            let line = String::from_utf8_lossy(&line_bytes);
            if let Some(ev) = HyprEvent::parse_line(&line) {
                events.push(ev);
            }
        }

        if eof && events.is_empty() {
            Ok(None)
        } else {
            Ok(Some(events))
        }
    }
}

impl std::os::fd::AsFd for HyprEventStream {
    fn as_fd(&self) -> std::os::fd::BorrowedFd<'_> {
        self.stream.as_fd()
    }
}

/// Exponential backoff (100ms -> 2s) for resilient Hyprland socket2 reconnection.
#[derive(Debug, Clone)]
pub struct ReconnectBackoff {
    current: Duration,
    initial: Duration,
    max: Duration,
}

impl Default for ReconnectBackoff {
    fn default() -> Self {
        Self::new(Duration::from_millis(100), Duration::from_secs(2))
    }
}

impl ReconnectBackoff {
    pub fn new(initial: Duration, max: Duration) -> Self {
        Self {
            current: initial,
            initial,
            max,
        }
    }

    pub fn next_delay(&mut self) -> Duration {
        let delay = self.current;
        let doubled = self.current.saturating_mul(2);
        self.current = doubled.min(self.max);
        delay
    }

    pub fn reset(&mut self) {
        self.current = self.initial;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_loose_json_with_unknown_and_missing_fields() {
        let monitors = r#"[{"id":0,"name":"Virtual-1","width":1920,"height":1080,"focused":true,"activeWorkspace":{"id":2,"name":"2"},"futureField":{"nested":[1,2,3]}}]"#;
        let workspaces = r#"[{"id":1,"name":"1","monitor":"Virtual-1","windows":2,"brandNewFlag":true},{"id":2,"name":"2","monitor":"Virtual-1"}]"#;
        let active = r#"{"id":2,"name":"2","unknown":42}"#;

        let snap = parse_snapshot(monitors, workspaces, active).expect("loose json snapshot");
        assert_eq!(snap.monitors.len(), 1);
        assert_eq!(snap.monitors[0].name, "Virtual-1");
        assert_eq!(snap.monitors[0].scale, 1.0);
        assert_eq!(snap.active_workspace_id, 2);
        assert_eq!(snap.workspaces.len(), 2);
        assert_eq!(snap.workspaces[1].windows, 0);
    }

    #[test]
    fn parses_socket2_events_and_backoff_bounds() {
        assert_eq!(
            HyprEvent::parse_line("workspacev2>>3,3\n"),
            Some(HyprEvent::WorkspaceV2 {
                id: 3,
                name: "3".into()
            })
        );
        assert_eq!(
            HyprEvent::parse_line("monitoraddedv2>>1,kaze-share,Headless\n"),
            Some(HyprEvent::MonitorAdded {
                name: "kaze-share".into()
            })
        );
        assert_eq!(
            HyprEvent::parse_line("configreloaded>>\n"),
            Some(HyprEvent::ConfigReloaded)
        );
        assert_eq!(
            HyprEvent::parse_line("screencast>>1,0\n"),
            Some(HyprEvent::Screencast {
                active: true,
                owner: 0
            })
        );
        assert_eq!(
            HyprEvent::parse_line("screencast>>0,0\n"),
            Some(HyprEvent::Screencast {
                active: false,
                owner: 0
            })
        );

        let mut backoff = ReconnectBackoff::default();
        assert_eq!(backoff.next_delay(), Duration::from_millis(100));
        assert_eq!(backoff.next_delay(), Duration::from_millis(200));
        assert_eq!(backoff.next_delay(), Duration::from_millis(400));
        assert_eq!(backoff.next_delay(), Duration::from_millis(800));
        assert_eq!(backoff.next_delay(), Duration::from_millis(1600));
        assert_eq!(backoff.next_delay(), Duration::from_millis(2000));
        assert_eq!(backoff.next_delay(), Duration::from_millis(2000));
        backoff.reset();
        assert_eq!(backoff.next_delay(), Duration::from_millis(100));
    }

    #[test]
    fn layout_geometry_lua_only_touches_allowed_visual_keys() {
        let geom = kaze_core::LayoutPreset::Island.hypr_geometry();
        let lua = format_layout_geometry_lua(&geom);
        assert!(lua.contains("gaps_in = 6"));
        assert!(lua.contains("gaps_out = 10"));
        assert!(lua.contains("border_size = 2"));
        assert!(lua.contains("rounding = 12"));
        assert!(lua.contains("enabled = true"));
        assert!(!lua.contains("monitor"));
        assert!(!lua.contains("input"));
        assert!(!lua.contains("workspace_rule"));
    }
}
