use bitflags::bitflags;
use std::sync::Arc;

bitflags! {
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
    pub struct Anchor: u8 {
        const TOP    = 0b0001;
        const BOTTOM = 0b0010;
        const LEFT   = 0b0100;
        const RIGHT  = 0b1000;
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Layer {
    Background,
    Bottom,
    #[default]
    Top,
    Overlay,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum KeyboardMode {
    #[default]
    None,
    OnDemand,
    Exclusive,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct EdgeInsets {
    pub top: i32,
    pub right: i32,
    pub bottom: i32,
    pub left: i32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Color {
    pub r: u8,
    pub g: u8,
    pub b: u8,
    pub a: u8,
}

impl Color {
    pub const TRANSPARENT: Self = Self {
        r: 0,
        g: 0,
        b: 0,
        a: 0,
    };

    pub const fn rgba(r: u8, g: u8, b: u8, a: u8) -> Self {
        Self { r, g, b, a }
    }

    pub fn from_hex(hex: &str) -> Option<Self> {
        let s = hex.trim().strip_prefix('#').unwrap_or(hex.trim());
        match s.len() {
            6 => {
                let r = u8::from_str_radix(&s[0..2], 16).ok()?;
                let g = u8::from_str_radix(&s[2..4], 16).ok()?;
                let b = u8::from_str_radix(&s[4..6], 16).ok()?;
                Some(Self { r, g, b, a: 255 })
            }
            8 => {
                let r = u8::from_str_radix(&s[0..2], 16).ok()?;
                let g = u8::from_str_radix(&s[2..4], 16).ok()?;
                let b = u8::from_str_radix(&s[4..6], 16).ok()?;
                let a = u8::from_str_radix(&s[6..8], 16).ok()?;
                Some(Self { r, g, b, a })
            }
            _ => None,
        }
    }

    pub fn from_hex_or(hex: &str, fallback: Self) -> Self {
        Self::from_hex(hex).unwrap_or(fallback)
    }

    pub fn with_opacity(self, opacity: f32) -> Self {
        let clamped = opacity.clamp(0.0, 1.0);
        Self {
            a: (f32::from(self.a) * clamped).round() as u8,
            ..self
        }
    }

    pub fn to_hex_rgb(self) -> String {
        format!("#{:02x}{:02x}{:02x}", self.r, self.g, self.b)
    }

    pub fn to_hex_bare(self) -> String {
        format!("{:02x}{:02x}{:02x}", self.r, self.g, self.b)
    }

    pub fn to_hypr_rgba(self) -> String {
        format!(
            "rgba({:02x}{:02x}{:02x}{:02x})",
            self.r, self.g, self.b, self.a
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Rect {
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
}

impl Rect {
    pub const fn new(x: f32, y: f32, w: f32, h: f32) -> Self {
        Self { x, y, w, h }
    }

    pub fn contains(&self, px: f32, py: f32) -> bool {
        px >= self.x && px <= self.x + self.w && py >= self.y && py <= self.y + self.h
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum TextAlign {
    Left,
    #[default]
    Center,
    Right,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IconKind {
    Display,
    Wifi,
    Ethernet,
    WifiOff,
    Volume,
    VolumeMuted,
    MicMuted,
    Battery,
    BatteryCharging,
    Brightness,
    Bell,
    BellOff,
    Play,
    Pause,
    Prev,
    Next,
    Record,
    Cast,
    Close,
    Bluetooth,
    NightLight,
    Caffeine,
    ThemeMode,
    Sliders,
    Lock,
    Suspend,
    Reboot,
    PowerOff,
    Settings,
    Layout,
    Calendar,
    Weather,
    Cpu,
    Clock,
    Keyboard,
    LockKey,
    Camera,
    Clipboard,
    ColorPicker,
    Search,
    Windows,
    Shield,
    PowerProfile,
    Music,
    Plus,
    Undo,
    Redo,
    Trash,
    Pin,
    Vpn,
    Refresh,
    FlipH,
    FlipV,
    Rotate,
    Grid,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CornerPos {
    TopLeft,
    TopRight,
    BottomLeft,
    BottomRight,
}

#[derive(Debug, Clone, PartialEq)]
pub enum PaintCmd {
    RoundedRect {
        rect: Rect,
        radius: f32,
        fill: Option<Color>,
        stroke: Option<Color>,
        stroke_width: f32,
    },
    /// Hardware-notch pill flushed to the top edge with concave upper ear flares.
    NotchPill {
        rect: Rect,
        bottom_radius: f32,
        flare_radius: f32,
        fill: Color,
        stroke: Option<Color>,
        stroke_width: f32,
    },
    Circle {
        cx: f32,
        cy: f32,
        radius: f32,
        fill: Color,
    },
    Line {
        x1: f32,
        y1: f32,
        x2: f32,
        y2: f32,
        color: Color,
        width: f32,
    },
    /// Fast ASCII/numeric text rendered via `ab_glyph` + `memmap2` (zero cosmic-text overhead at T0).
    Text {
        rect: Rect,
        text: String,
        color: Color,
        size: f32,
        bold: bool,
        align: TextAlign,
    },
    /// Monospace-aligned digits (`tnum`) so changing clocks/meters never shift adjacent widgets.
    TabularText {
        rect: Rect,
        text: String,
        color: Color,
        size: f32,
        bold: bool,
        align: TextAlign,
    },
    /// Shaped Unicode text (Vietnamese diacritics + Color Emoji + font fallback) via lazy `cosmic-text`.
    RichText {
        rect: Rect,
        text: String,
        color: Color,
        size: f32,
        bold: bool,
        align: TextAlign,
        max_lines: u8,
    },
    MonitorIcon {
        rect: Rect,
        color: Color,
        stroke_width: f32,
    },
    Icon {
        rect: Rect,
        kind: IconKind,
        color: Color,
        stroke_width: f32,
        level: Option<u8>,
    },
    /// Premultiplied RGBA raster image (SNI tray icons, thumbnails).
    Image {
        rect: Rect,
        width: u32,
        height: u32,
        rgba_premul: Arc<[u8]>,
    },
    /// Styled raster image with saturation, theme colorization, shadow, opacity, and 2D transform.
    StyledImage {
        rect: Rect,
        width: u32,
        height: u32,
        rgba_premul: Arc<[u8]>,
        saturation: f32,
        colorize: Option<Color>,
        shadow: bool,
        opacity: f32,
        rotation_deg: f32,
        flip_x: bool,
        flip_y: bool,
    },
    /// Offscreen child paint list composited with 2D rotation, flip, and opacity.
    TransformedGroup {
        rect: Rect,
        rotation_deg: f32,
        flip_x: bool,
        flip_y: bool,
        opacity: f32,
        commands: Vec<PaintCmd>,
    },
    /// Concave bezel corner cut-out for Screen Corners.
    ConcaveCorner {
        corner: CornerPos,
        radius: f32,
        color: Color,
    },
    /// Polyline / polygon stroke or fill for audio waves, sparklines, and SVG paths.
    Polyline {
        points: Vec<(f32, f32)>,
        color: Color,
        width: f32,
        closed: bool,
        fill: Option<Color>,
    },
    /// Circular arc stroke for gauges, rings, and dials.
    Arc {
        cx: f32,
        cy: f32,
        radius: f32,
        start_deg: f32,
        sweep_deg: f32,
        color: Color,
        width: f32,
    },
    /// Full BiDi/RTL + grapheme-aware text input widget with selection, preedit underline, and caret.
    TextInputField {
        rect: Rect,
        text: String,
        preedit: String,
        cursor_byte: usize,
        selection: Option<(usize, usize)>,
        placeholder: String,
        password_mode: bool,
        color: Color,
        preedit_color: Color,
        selection_color: Color,
        placeholder_color: Color,
        size: f32,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub struct HitTarget {
    pub rect: Rect,
    pub id: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SurfaceSpec {
    pub id: String,
    pub namespace: String,
    pub output: Option<String>,
    pub layer: Layer,
    pub keyboard_interactivity: KeyboardMode,
    pub anchor: Anchor,
    pub exclusive_zone: i32,
    pub width: u32,
    pub height: u32,
    pub margin: EdgeInsets,
    pub corner_radius: f32,
    pub background: Color,
    pub border_color: Color,
    pub border_width: f32,
    pub commands: Vec<PaintCmd>,
    pub hit_targets: Vec<HitTarget>,
    /// When `true`, `kaze-ui` drives `SystemEvent::FrameTick` via `wl_surface.frame()`
    /// until all springs settle and flip this back to `false` (returning idle CPU to 0.00%).
    pub animating: bool,
    /// Optional explicit pointer input regions (click-through outside these rects).
    pub input_regions: Option<Vec<Rect>>,
    /// Logical cursor rectangle reported to `zwp_text_input_v3.set_cursor_rectangle` for IME popups.
    pub ime_cursor_rect: Option<Rect>,
    /// When `true`, `kaze-ui` forwards hover `PointerMotion` events for this surface.
    pub track_pointer_motion: bool,
}

impl SurfaceSpec {
    pub fn geometry_eq(&self, other: &Self) -> bool {
        self.namespace == other.namespace
            && self.output == other.output
            && self.layer == other.layer
            && self.keyboard_interactivity == other.keyboard_interactivity
            && self.anchor == other.anchor
            && self.exclusive_zone == other.exclusive_zone
            && self.width == other.width
            && self.height == other.height
            && self.margin == other.margin
            && self.input_regions == other.input_regions
    }
}
