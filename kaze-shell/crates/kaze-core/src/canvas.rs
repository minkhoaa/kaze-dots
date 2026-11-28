use serde::{Deserialize, Serialize};
use std::path::PathBuf;

pub const CANVAS_MIN_DIM: f32 = 32.0;
pub const CANVAS_UNDO_CAP: usize = 64;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CanvasLayer {
    #[default]
    Desktop,
    Lockscreen,
}

impl CanvasLayer {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Desktop => "desktop",
            Self::Lockscreen => "lockscreen",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "desktop" => Some(Self::Desktop),
            "lockscreen" | "lock" => Some(Self::Lockscreen),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CanvasWidgetKind {
    #[default]
    Clock,
    SystemMonitor,
    MediaPlayer,
    Weather,
    CalendarAgenda,
    TodoNote,
    Image,
    Sticker,
    QuickLaunch,
    HardwareStatus,
}

impl CanvasWidgetKind {
    pub const ALL: [Self; 10] = [
        Self::Clock,
        Self::SystemMonitor,
        Self::MediaPlayer,
        Self::Weather,
        Self::CalendarAgenda,
        Self::TodoNote,
        Self::Image,
        Self::Sticker,
        Self::QuickLaunch,
        Self::HardwareStatus,
    ];

    pub fn label(self) -> &'static str {
        match self {
            Self::Clock => "Clock",
            Self::SystemMonitor => "System Monitor",
            Self::MediaPlayer => "Media Player",
            Self::Weather => "Weather",
            Self::CalendarAgenda => "Calendar Agenda",
            Self::TodoNote => "Todo / Note",
            Self::Image => "Image",
            Self::Sticker => "Sticker",
            Self::QuickLaunch => "Quick Launch",
            Self::HardwareStatus => "Hardware Status",
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Clock => "clock",
            Self::SystemMonitor => "system_monitor",
            Self::MediaPlayer => "media_player",
            Self::Weather => "weather",
            Self::CalendarAgenda => "calendar_agenda",
            Self::TodoNote => "todo_note",
            Self::Image => "image",
            Self::Sticker => "sticker",
            Self::QuickLaunch => "quick_launch",
            Self::HardwareStatus => "hardware_status",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().replace('-', "_").as_str() {
            "clock" => Some(Self::Clock),
            "system_monitor" | "sysmon" => Some(Self::SystemMonitor),
            "media_player" | "media" => Some(Self::MediaPlayer),
            "weather" => Some(Self::Weather),
            "calendar_agenda" | "calendar" => Some(Self::CalendarAgenda),
            "todo_note" | "todo" | "note" => Some(Self::TodoNote),
            "image" | "photo" => Some(Self::Image),
            "sticker" | "svg" => Some(Self::Sticker),
            "quick_launch" | "launch" => Some(Self::QuickLaunch),
            "hardware_status" | "hardware" => Some(Self::HardwareStatus),
            _ => None,
        }
    }

    pub fn default_size(self) -> (f32, f32) {
        match self {
            Self::Clock => (240.0, 112.0),
            Self::SystemMonitor => (256.0, 144.0),
            Self::MediaPlayer => (272.0, 112.0),
            Self::Weather => (224.0, 112.0),
            Self::CalendarAgenda => (272.0, 160.0),
            Self::TodoNote => (240.0, 144.0),
            Self::Image => (208.0, 160.0),
            Self::Sticker => (112.0, 112.0),
            Self::QuickLaunch => (224.0, 96.0),
            Self::HardwareStatus => (240.0, 112.0),
        }
    }

    pub fn requires_sysmon(self) -> bool {
        matches!(self, Self::SystemMonitor)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct CanvasWidget {
    pub id: String,
    pub monitor_id: Option<String>,
    pub layer: CanvasLayer,
    pub kind: CanvasWidgetKind,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub rotation_deg: f32,
    pub flip_x: bool,
    pub flip_y: bool,
    pub z_index: i32,
    pub opacity: f32,
    pub title: String,
    pub text: String,
    pub path: Option<PathBuf>,
    pub command: Option<String>,
    pub color: Option<String>,
}

impl Default for CanvasWidget {
    fn default() -> Self {
        let (width, height) = CanvasWidgetKind::Clock.default_size();
        Self {
            id: String::new(),
            monitor_id: None,
            layer: CanvasLayer::Desktop,
            kind: CanvasWidgetKind::Clock,
            x: 64.0,
            y: 64.0,
            width,
            height,
            rotation_deg: 0.0,
            flip_x: false,
            flip_y: false,
            z_index: 0,
            opacity: 0.94,
            title: String::new(),
            text: String::new(),
            path: None,
            command: None,
            color: None,
        }
    }
}

impl CanvasWidget {
    pub fn normalize(&mut self) {
        if !self.x.is_finite() {
            self.x = 64.0;
        }
        if !self.y.is_finite() {
            self.y = 64.0;
        }
        if !self.width.is_finite() {
            self.width = self.kind.default_size().0;
        }
        if !self.height.is_finite() {
            self.height = self.kind.default_size().1;
        }
        self.width = self.width.max(CANVAS_MIN_DIM);
        self.height = self.height.max(CANVAS_MIN_DIM);
        if !self.rotation_deg.is_finite() {
            self.rotation_deg = 0.0;
        }
        self.rotation_deg = normalize_angle_deg(self.rotation_deg);
        if !self.opacity.is_finite() {
            self.opacity = 1.0;
        }
        self.opacity = self.opacity.clamp(0.1, 1.0);
        if let Some(ref mut mid) = self.monitor_id {
            let trimmed = mid.trim().to_string();
            if trimmed.is_empty() {
                self.monitor_id = None;
            } else {
                *mid = trimmed;
            }
        }
    }

    pub fn matches_output(&self, monitor_id: &str, output_name: &str, is_primary: bool) -> bool {
        match self.monitor_id.as_deref() {
            Some(target) if !target.is_empty() => target == monitor_id || target == output_name,
            _ => is_primary,
        }
    }
}

pub fn normalize_angle_deg(deg: f32) -> f32 {
    if !deg.is_finite() {
        return 0.0;
    }
    let mut rem = deg % 360.0;
    if rem < 0.0 {
        rem += 360.0;
    }
    rem
}

pub fn snap_rotation_15(deg: f32) -> f32 {
    normalize_angle_deg((deg / 15.0).round() * 15.0)
}

#[derive(Debug, Clone)]
pub struct UndoStack<T> {
    max_depth: usize,
    undo: Vec<T>,
    redo: Vec<T>,
}

impl<T: Clone> UndoStack<T> {
    pub fn new(max_depth: usize) -> Self {
        Self {
            max_depth: max_depth.max(1),
            undo: Vec::new(),
            redo: Vec::new(),
        }
    }

    pub fn push(&mut self, snapshot: T) {
        if self.undo.len() >= self.max_depth {
            self.undo.remove(0);
        }
        self.undo.push(snapshot);
        self.redo.clear();
    }

    pub fn undo(&mut self, current: T) -> Option<T> {
        let prev = self.undo.pop()?;
        if self.redo.len() >= self.max_depth {
            self.redo.remove(0);
        }
        self.redo.push(current);
        Some(prev)
    }

    pub fn redo(&mut self, current: T) -> Option<T> {
        let next = self.redo.pop()?;
        if self.undo.len() >= self.max_depth {
            self.undo.remove(0);
        }
        self.undo.push(current);
        Some(next)
    }

    pub fn can_undo(&self) -> bool {
        !self.undo.is_empty()
    }

    pub fn can_redo(&self) -> bool {
        !self.redo.is_empty()
    }

    pub fn undo_len(&self) -> usize {
        self.undo.len()
    }

    pub fn redo_len(&self) -> usize {
        self.redo.len()
    }

    pub fn clear(&mut self) {
        self.undo.clear();
        self.redo.clear();
    }
}

impl<T: Clone> Default for UndoStack<T> {
    fn default() -> Self {
        Self::new(CANVAS_UNDO_CAP)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn widget_normalization_enforces_min_bounds_and_monitor_matching() {
        let mut w = CanvasWidget {
            id: "w1".into(),
            monitor_id: Some("Dell:U2723QE:XYZ123".into()),
            x: 10.0,
            y: 20.0,
            width: 8.0,
            height: 4.0,
            rotation_deg: -45.0,
            opacity: 2.5,
            ..CanvasWidget::default()
        };
        w.normalize();
        assert_eq!(w.width, CANVAS_MIN_DIM);
        assert_eq!(w.height, CANVAS_MIN_DIM);
        assert_eq!(w.rotation_deg, 315.0);
        assert_eq!(w.opacity, 1.0);
        assert!(w.matches_output("Dell:U2723QE:XYZ123", "DP-1", false));
        assert!(!w.matches_output("Other:M:1", "HDMI-A-1", true));
        assert_eq!(snap_rotation_15(23.0), 30.0);
        assert_eq!(snap_rotation_15(-14.0), 345.0);
    }

    #[test]
    fn undo_stack_handles_64_cap_and_35_roundtrips() {
        let mut stack: UndoStack<usize> = UndoStack::new(CANVAS_UNDO_CAP);
        let mut cur = 0usize;
        for step in 1..=35 {
            stack.push(cur);
            cur = step;
        }
        assert_eq!(cur, 35);
        assert_eq!(stack.undo_len(), 35);
        for expected in (0..35).rev() {
            cur = stack.undo(cur).expect("undo step");
            assert_eq!(cur, expected);
        }
        assert!(!stack.can_undo());
        for expected in 1..=35 {
            cur = stack.redo(cur).expect("redo step");
            assert_eq!(cur, expected);
        }
        assert_eq!(cur, 35);

        // Exceeding cap drops oldest entries rather than panicking.
        for step in 36..=120 {
            stack.push(cur);
            cur = step;
        }
        assert_eq!(stack.undo_len(), CANVAS_UNDO_CAP);
    }
}
