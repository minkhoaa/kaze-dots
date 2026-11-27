pub use crate::config::xdg_config_home;
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use crate::state::ThemeMode;
use crate::surface::Color;

static TMP_COUNTER: AtomicU64 = AtomicU64::new(0);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct TerminalColors {
    pub black: String,
    pub red: String,
    pub green: String,
    pub yellow: String,
    pub blue: String,
    pub magenta: String,
    pub cyan: String,
    pub white: String,
    pub bright_black: String,
    pub bright_red: String,
    pub bright_green: String,
    pub bright_yellow: String,
    pub bright_blue: String,
    pub bright_magenta: String,
    pub bright_cyan: String,
    pub bright_white: String,
    pub foreground: String,
    pub background: String,
    pub selection_fg: String,
    pub selection_bg: String,
    pub cursor: String,
    pub cursor_text: String,
}

impl Default for TerminalColors {
    fn default() -> Self {
        Self::kanagawa_dark()
    }
}

impl TerminalColors {
    pub fn kanagawa_dark() -> Self {
        Self {
            black: "#16161d".into(),
            red: "#c34043".into(),
            green: "#76946a".into(),
            yellow: "#c0a36e".into(),
            blue: "#7e9cd8".into(),
            magenta: "#957fb8".into(),
            cyan: "#6a9589".into(),
            white: "#c8c093".into(),
            bright_black: "#727169".into(),
            bright_red: "#e82424".into(),
            bright_green: "#98bb6c".into(),
            bright_yellow: "#e6c384".into(),
            bright_blue: "#7fb4ca".into(),
            bright_magenta: "#938aa9".into(),
            bright_cyan: "#7aa89f".into(),
            bright_white: "#dcd7ba".into(),
            foreground: "#dcd7ba".into(),
            background: "#1f1f28".into(),
            selection_fg: "#c8c093".into(),
            selection_bg: "#2d4f67".into(),
            cursor: "#c8c093".into(),
            cursor_text: "#1f1f28".into(),
        }
    }

    pub fn kanagawa_light() -> Self {
        Self {
            black: "#1f1f28".into(),
            red: "#c84053".into(),
            green: "#6f894e".into(),
            yellow: "#77713f".into(),
            blue: "#4d699b".into(),
            magenta: "#b35b79".into(),
            cyan: "#597b75".into(),
            white: "#545464".into(),
            bright_black: "#8a8980".into(),
            bright_red: "#d7474b".into(),
            bright_green: "#6e915f".into(),
            bright_yellow: "#836f4a".into(),
            bright_blue: "#6693bf".into(),
            bright_magenta: "#624c83".into(),
            bright_cyan: "#5e857a".into(),
            bright_white: "#43436c".into(),
            foreground: "#545464".into(),
            background: "#f2ecbc".into(),
            selection_fg: "#43436c".into(),
            selection_bg: "#c9cbd1".into(),
            cursor: "#43436c".into(),
            cursor_text: "#f2ecbc".into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct PaletteColors {
    pub primary: String,
    pub on_primary: String,
    pub secondary: String,
    pub on_secondary: String,
    pub tertiary: String,
    pub on_tertiary: String,
    pub error: String,
    pub on_error: String,
    pub surface: String,
    pub on_surface: String,
    pub surface_container: String,
    pub on_surface_container: String,
    pub surface_variant: String,
    pub on_surface_variant: String,
    pub outline: String,
    pub outline_variant: String,
    pub terminal: TerminalColors,
}

impl Default for PaletteColors {
    fn default() -> Self {
        Self::kanagawa_dark()
    }
}

impl PaletteColors {
    pub fn kanagawa_dark() -> Self {
        Self {
            primary: "#7e9cd8".into(),
            on_primary: "#16161d".into(),
            secondary: "#98bb6c".into(),
            on_secondary: "#16161d".into(),
            tertiary: "#e6c384".into(),
            on_tertiary: "#16161d".into(),
            error: "#e82424".into(),
            on_error: "#dcd7ba".into(),
            surface: "#1f1f28".into(),
            on_surface: "#dcd7ba".into(),
            surface_container: "#2a2a37".into(),
            on_surface_container: "#dcd7ba".into(),
            surface_variant: "#363646".into(),
            on_surface_variant: "#9cabca".into(),
            outline: "#54546d".into(),
            outline_variant: "#363646".into(),
            terminal: TerminalColors::kanagawa_dark(),
        }
    }

    pub fn kanagawa_light() -> Self {
        Self {
            primary: "#4d699b".into(),
            on_primary: "#f2ecbc".into(),
            secondary: "#6f894e".into(),
            on_secondary: "#f2ecbc".into(),
            tertiary: "#b35b79".into(),
            on_tertiary: "#f2ecbc".into(),
            error: "#c84053".into(),
            on_error: "#f2ecbc".into(),
            surface: "#f2ecbc".into(),
            on_surface: "#1f1f28".into(),
            surface_container: "#e7dba0".into(),
            on_surface_container: "#1f1f28".into(),
            surface_variant: "#dcd098".into(),
            on_surface_variant: "#545464".into(),
            outline: "#8a8980".into(),
            outline_variant: "#c7bc8a".into(),
            terminal: TerminalColors::kanagawa_light(),
        }
    }

    pub fn color(&self, hex: &str, fallback: Color) -> Color {
        Color::from_hex_or(hex, fallback)
    }

    pub fn primary_color(&self) -> Color {
        self.color(&self.primary, Color::rgba(0x7e, 0x9c, 0xd8, 0xff))
    }
    pub fn on_primary_color(&self) -> Color {
        self.color(&self.on_primary, Color::rgba(0x16, 0x16, 0x1d, 0xff))
    }
    pub fn secondary_color(&self) -> Color {
        self.color(&self.secondary, Color::rgba(0x98, 0xbb, 0x6c, 0xff))
    }
    pub fn tertiary_color(&self) -> Color {
        self.color(&self.tertiary, Color::rgba(0xe6, 0xc3, 0x84, 0xff))
    }
    pub fn error_color(&self) -> Color {
        self.color(&self.error, Color::rgba(0xe8, 0x24, 0x24, 0xff))
    }
    pub fn surface_color(&self) -> Color {
        self.color(&self.surface, Color::rgba(0x1f, 0x1f, 0x28, 0xff))
    }
    pub fn on_surface_color(&self) -> Color {
        self.color(&self.on_surface, Color::rgba(0xdc, 0xd7, 0xba, 0xff))
    }
    pub fn surface_container_color(&self) -> Color {
        self.color(&self.surface_container, Color::rgba(0x2a, 0x2a, 0x37, 0xff))
    }
    pub fn surface_variant_color(&self) -> Color {
        self.color(&self.surface_variant, Color::rgba(0x36, 0x36, 0x46, 0xff))
    }
    pub fn on_surface_variant_color(&self) -> Color {
        self.color(
            &self.on_surface_variant,
            Color::rgba(0x9c, 0xab, 0xca, 0xff),
        )
    }
    pub fn outline_color(&self) -> Color {
        self.color(&self.outline, Color::rgba(0x54, 0x54, 0x6d, 0xff))
    }
    pub fn outline_variant_color(&self) -> Color {
        self.color(&self.outline_variant, Color::rgba(0x36, 0x36, 0x46, 0xff))
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct ResolvedPalette {
    pub name: String,
    pub dark: PaletteColors,
    pub light: PaletteColors,
}

impl Default for ResolvedPalette {
    fn default() -> Self {
        Self::kanagawa()
    }
}

impl ResolvedPalette {
    pub fn kanagawa() -> Self {
        Self {
            name: "Kanagawa".into(),
            dark: PaletteColors::kanagawa_dark(),
            light: PaletteColors::kanagawa_light(),
        }
    }

    pub fn for_mode(&self, mode: ThemeMode) -> &PaletteColors {
        match mode {
            ThemeMode::Dark => &self.dark,
            ThemeMode::Light => &self.light,
        }
    }

    /// Loads a palette JSON (v2 format matching `config/noctalia/palettes/*.json`)
    /// from configured `palettes_dir`, `~/.config/kaze-shell/palettes`, or
    /// `~/.config/noctalia/palettes`, falling back cleanly to built-in Kanagawa.
    pub fn load(name: &str, custom_dir: Option<&Path>) -> Self {
        let mut search_dirs = Vec::new();
        if let Some(d) = custom_dir {
            search_dirs.push(d.to_path_buf());
        }
        match xdg_config_home() {
            Ok(home) => {
                search_dirs.push(home.join("kaze-shell").join("palettes"));
                search_dirs.push(home.join("noctalia").join("palettes"));
            }
            Err(err) => eprintln!("kaze-shell: skipping user palette directories: {err}"),
        }
        Self::load_from_dirs(name, &search_dirs)
    }

    fn load_from_dirs(name: &str, search_dirs: &[PathBuf]) -> Self {
        let file_name = format!("{name}.json");
        for dir in search_dirs {
            let candidate = dir.join(&file_name);
            let raw = match fs::read_to_string(&candidate) {
                Ok(raw) => raw,
                Err(err) if err.kind() == std::io::ErrorKind::NotFound => continue,
                Err(err) => {
                    eprintln!(
                        "kaze-shell: cannot read palette {}: {err}",
                        candidate.display()
                    );
                    continue;
                }
            };
            match serde_json::from_str::<Self>(&raw) {
                Ok(mut parsed) => {
                    if parsed.name.is_empty() {
                        parsed.name = name.to_string();
                    }
                    return parsed;
                }
                Err(err) => eprintln!("kaze-shell: invalid palette {}: {err}", candidate.display()),
            }
        }
        if name != "Kanagawa" {
            eprintln!("kaze-shell: no usable {name:?} palette; using built-in Kanagawa");
        }
        Self::kanagawa()
    }
}

#[derive(Debug, Clone)]
pub struct ThemePaths {
    pub hyprland: PathBuf,
    pub foot: PathBuf,
    pub gtk3: PathBuf,
    pub gtk4: PathBuf,
    pub btop: PathBuf,
}

impl ThemePaths {
    pub fn from_config_home(cfg_home: &Path) -> Self {
        Self {
            hyprland: cfg_home.join("hypr").join("kaze-theme.lua"),
            foot: cfg_home.join("foot").join("themes").join("kaze-shell"),
            gtk3: cfg_home.join("gtk-3.0").join("kaze-shell.css"),
            gtk4: cfg_home.join("gtk-4.0").join("kaze-shell.css"),
            btop: cfg_home
                .join("btop")
                .join("themes")
                .join("kaze-shell.theme"),
        }
    }

    pub fn default_paths() -> Result<Self, String> {
        Ok(Self::from_config_home(&xdg_config_home()?))
    }
}

#[derive(Debug, Clone)]
pub struct GeneratedTheme {
    pub hypr_active_border: String,
    pub hypr_inactive_border: String,
    pub hypr_eval_lua: String,
    pub btop_signaled: usize,
}

pub fn write_atomic(path: &Path, content: &str) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|e| format!("create_dir_all({}): {e}", parent.display()))?;
    }
    let seq = TMP_COUNTER.fetch_add(1, Ordering::Relaxed);
    let file_name = path.file_name().and_then(|n| n.to_str()).unwrap_or("tmp");
    let tmp_path = path.with_file_name(format!(".{file_name}.tmp.{}.{seq}", std::process::id()));
    let mut file =
        fs::File::create(&tmp_path).map_err(|e| format!("create({}): {e}", tmp_path.display()))?;
    file.write_all(content.as_bytes())
        .map_err(|e| format!("write({}): {e}", tmp_path.display()))?;
    file.sync_all()
        .map_err(|e| format!("sync({}): {e}", tmp_path.display()))?;
    drop(file);
    fs::rename(&tmp_path, path).map_err(|e| {
        let _ = fs::remove_file(&tmp_path);
        format!("rename({} -> {}): {e}", tmp_path.display(), path.display())
    })
}

fn bare_hex(hex: &str, fallback: &str) -> String {
    let trimmed = hex.trim().strip_prefix('#').unwrap_or(hex.trim());
    if trimmed.len() == 6 && trimmed.bytes().all(|b| b.is_ascii_hexdigit()) {
        trimmed.to_ascii_lowercase()
    } else {
        fallback.to_string()
    }
}

pub fn render_hyprland_lua(colors: &PaletteColors) -> (String, String, String, String) {
    let active = colors.primary_color().with_opacity(0.93).to_hypr_rgba();
    let inactive = colors
        .outline_variant_color()
        .with_opacity(0.80)
        .to_hypr_rgba();
    let secondary = colors.secondary_color().with_opacity(0.85).to_hypr_rgba();
    let error = colors.error_color().with_opacity(0.90).to_hypr_rgba();
    let surface = colors.surface_color().to_hypr_rgba();
    let on_surface = colors.on_surface_color().to_hypr_rgba();
    let outline = colors.outline_color().to_hypr_rgba();

    let eval_lua = format!(
        "hl.config({{ general = {{ [\"col.active_border\"] = \"{active}\", [\"col.inactive_border\"] = \"{inactive}\" }} }})"
    );

    let file_lua = format!(
        r#"-- Auto-generated by kaze-shell; do not edit manually.
local M = {{}}

M.colors = {{
    primary = "{active}",
    secondary = "{secondary}",
    error = "{error}",
    surface = "{surface}",
    on_surface = "{on_surface}",
    outline = "{outline}",
    outline_variant = "{inactive}",
}}

function M.apply_theme()
    if type(hl) ~= "table" or type(hl.config) ~= "function" then
        return
    end
    hl.config({{
        general = {{
            ["col.active_border"] = M.colors.primary,
            ["col.inactive_border"] = M.colors.outline_variant,
        }},
    }})
end

return M
"#
    );

    (file_lua, active, inactive, eval_lua)
}

pub fn render_foot_theme(palette: &ResolvedPalette, mode: ThemeMode) -> String {
    let active = palette.for_mode(mode);
    let render_section = |section: &str, c: &PaletteColors| -> String {
        let t = &c.terminal;
        format!(
            "[{section}]\n\
foreground={}\n\
background={}\n\
regular0={}\n\
regular1={}\n\
regular2={}\n\
regular3={}\n\
regular4={}\n\
regular5={}\n\
regular6={}\n\
regular7={}\n\
bright0={}\n\
bright1={}\n\
bright2={}\n\
bright3={}\n\
bright4={}\n\
bright5={}\n\
bright6={}\n\
bright7={}\n\
selection-foreground={}\n\
selection-background={}\n\
cursor={} {}\n",
            bare_hex(&t.foreground, "dcd7ba"),
            bare_hex(&t.background, "1f1f28"),
            bare_hex(&t.black, "16161d"),
            bare_hex(&t.red, "c34043"),
            bare_hex(&t.green, "76946a"),
            bare_hex(&t.yellow, "c0a36e"),
            bare_hex(&t.blue, "7e9cd8"),
            bare_hex(&t.magenta, "957fb8"),
            bare_hex(&t.cyan, "6a9589"),
            bare_hex(&t.white, "c8c093"),
            bare_hex(&t.bright_black, "727169"),
            bare_hex(&t.bright_red, "e82424"),
            bare_hex(&t.bright_green, "98bb6c"),
            bare_hex(&t.bright_yellow, "e6c384"),
            bare_hex(&t.bright_blue, "7fb4ca"),
            bare_hex(&t.bright_magenta, "938aa9"),
            bare_hex(&t.bright_cyan, "7aa89f"),
            bare_hex(&t.bright_white, "dcd7ba"),
            bare_hex(&t.selection_fg, "c8c093"),
            bare_hex(&t.selection_bg, "2d4f67"),
            bare_hex(&t.cursor_text, "1f1f28"),
            bare_hex(&t.cursor, "c8c093"),
        )
    };

    // Populate both colors-dark and colors-light with the active mode palette so
    // `foot --server` + `kaze-footclient` pick up Dark <-> Light toggles immediately.
    format!(
        "# Auto-generated by kaze-shell (palette={}, mode={})\n\n{}\n{}",
        palette.name,
        mode.as_str(),
        render_section("colors-dark", active),
        render_section("colors-light", active),
    )
}

pub fn render_gtk_css(colors: &PaletteColors) -> String {
    format!(
        "/* Auto-generated by kaze-shell; do not edit manually. */\n\
@define-color window_bg_color {};\n\
@define-color window_fg_color {};\n\
@define-color view_bg_color {};\n\
@define-color view_fg_color {};\n\
@define-color headerbar_bg_color {};\n\
@define-color headerbar_fg_color {};\n\
@define-color sidebar_bg_color {};\n\
@define-color sidebar_fg_color {};\n\
@define-color popover_bg_color {};\n\
@define-color popover_fg_color {};\n\
@define-color card_bg_color {};\n\
@define-color card_fg_color {};\n\
@define-color accent_bg_color {};\n\
@define-color accent_fg_color {};\n\
@define-color accent_color {};\n\
@define-color destructive_bg_color {};\n\
@define-color destructive_fg_color {};\n\
@define-color borders {};\n",
        colors.surface_color().to_hex_rgb(),
        colors.on_surface_color().to_hex_rgb(),
        colors.surface_color().to_hex_rgb(),
        colors.on_surface_color().to_hex_rgb(),
        colors.surface_container_color().to_hex_rgb(),
        colors.on_surface_color().to_hex_rgb(),
        colors.surface_container_color().to_hex_rgb(),
        colors.on_surface_color().to_hex_rgb(),
        colors.surface_container_color().to_hex_rgb(),
        colors.on_surface_color().to_hex_rgb(),
        colors.surface_variant_color().to_hex_rgb(),
        colors.on_surface_color().to_hex_rgb(),
        colors.primary_color().to_hex_rgb(),
        colors.on_primary_color().to_hex_rgb(),
        colors.primary_color().to_hex_rgb(),
        colors.error_color().to_hex_rgb(),
        colors
            .color(&colors.on_error, Color::rgba(0xff, 0xff, 0xff, 0xff))
            .to_hex_rgb(),
        colors.outline_variant_color().to_hex_rgb(),
    )
}

pub fn render_btop_theme(colors: &PaletteColors) -> String {
    let surface = colors.surface_color().to_hex_rgb();
    let on_surface = colors.on_surface_color().to_hex_rgb();
    let primary = colors.primary_color().to_hex_rgb();
    let secondary = colors.secondary_color().to_hex_rgb();
    let tertiary = colors.tertiary_color().to_hex_rgb();
    let error = colors.error_color().to_hex_rgb();
    let container = colors.surface_container_color().to_hex_rgb();
    let muted = colors.on_surface_variant_color().to_hex_rgb();
    let outline = colors.outline_variant_color().to_hex_rgb();

    format!(
        "# Auto-generated by kaze-shell\n\
theme[main_bg]=\"{surface}\"\n\
theme[main_fg]=\"{on_surface}\"\n\
theme[title]=\"{on_surface}\"\n\
theme[hi_fg]=\"{primary}\"\n\
theme[selected_bg]=\"{container}\"\n\
theme[selected_fg]=\"{primary}\"\n\
theme[inactive_fg]=\"{muted}\"\n\
theme[proc_misc]=\"{secondary}\"\n\
theme[cpu_box]=\"{outline}\"\n\
theme[mem_box]=\"{outline}\"\n\
theme[net_box]=\"{outline}\"\n\
theme[proc_box]=\"{outline}\"\n\
theme[div_line]=\"{outline}\"\n\
theme[temp_start]=\"{secondary}\"\n\
theme[temp_mid]=\"{tertiary}\"\n\
theme[temp_end]=\"{error}\"\n\
theme[cpu_start]=\"{secondary}\"\n\
theme[cpu_mid]=\"{primary}\"\n\
theme[cpu_end]=\"{error}\"\n\
theme[free_start]=\"{secondary}\"\n\
theme[free_mid]=\"{primary}\"\n\
theme[free_end]=\"{tertiary}\"\n\
theme[cached_start]=\"{primary}\"\n\
theme[cached_mid]=\"{tertiary}\"\n\
theme[cached_end]=\"{error}\"\n\
theme[available_start]=\"{secondary}\"\n\
theme[available_mid]=\"{primary}\"\n\
theme[available_end]=\"{tertiary}\"\n\
theme[used_start]=\"{tertiary}\"\n\
theme[used_mid]=\"{primary}\"\n\
theme[used_end]=\"{error}\"\n\
theme[download_start]=\"{secondary}\"\n\
theme[download_mid]=\"{primary}\"\n\
theme[download_end]=\"{tertiary}\"\n\
theme[upload_start]=\"{primary}\"\n\
theme[upload_mid]=\"{tertiary}\"\n\
theme[upload_end]=\"{error}\"\n"
    )
}

/// Sends `SIGUSR2` to running `btop` processes owned by the current UID (exact comm match, never `pkill -f`).
pub fn signal_btop_reload() -> usize {
    // SAFETY: `getuid` has no preconditions and always succeeds.
    let my_uid = unsafe { libc::getuid() };
    let Ok(entries) = fs::read_dir("/proc") else {
        return 0;
    };
    let mut signaled = 0usize;
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(pid_str) = name.to_str() else {
            continue;
        };
        let Ok(pid) = pid_str.parse::<libc::pid_t>() else {
            continue;
        };
        if pid <= 1 {
            continue;
        }
        let proc_dir = entry.path();
        let Ok(comm) = fs::read_to_string(proc_dir.join("comm")) else {
            continue;
        };
        if comm.trim() != "btop" {
            continue;
        }
        let Ok(status) = fs::read_to_string(proc_dir.join("status")) else {
            continue;
        };
        let owned = status
            .lines()
            .find(|l| l.starts_with("Uid:"))
            .and_then(|l| l.split_whitespace().nth(1))
            .and_then(|u| u.parse::<libc::uid_t>().ok())
            == Some(my_uid);
        if owned {
            // SAFETY: sending SIGUSR2 to a verified same-UID `btop` PID.
            if unsafe { libc::kill(pid, libc::SIGUSR2) } == 0 {
                signaled += 1;
            }
        }
    }
    signaled
}

pub fn generate_all_templates(
    palette: &ResolvedPalette,
    mode: ThemeMode,
    paths: &ThemePaths,
    notify_btop: bool,
) -> Result<GeneratedTheme, String> {
    let colors = palette.for_mode(mode);
    let (hypr_lua, hypr_active_border, hypr_inactive_border, hypr_eval_lua) =
        render_hyprland_lua(colors);
    let foot_ini = render_foot_theme(palette, mode);
    let gtk_css = render_gtk_css(colors);
    let btop_theme = render_btop_theme(colors);

    write_atomic(&paths.hyprland, &hypr_lua)?;
    write_atomic(&paths.foot, &foot_ini)?;
    write_atomic(&paths.gtk3, &gtk_css)?;
    write_atomic(&paths.gtk4, &gtk_css)?;
    write_atomic(&paths.btop, &btop_theme)?;

    let btop_signaled = if notify_btop { signal_btop_reload() } else { 0 };

    Ok(GeneratedTheme {
        hypr_active_border,
        hypr_inactive_border,
        hypr_eval_lua,
        btop_signaled,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::os::unix::fs::DirBuilderExt;

    #[test]
    fn palette_search_uses_first_parseable_file_then_builtin() -> std::io::Result<()> {
        let dir = std::env::temp_dir().join(format!("kaze-palette-test-{}", std::process::id()));
        fs::DirBuilder::new().mode(0o700).create(&dir)?;
        let dirs = [dir.clone(), dir.join("next")];
        fs::create_dir(&dirs[1])?;
        let first = dir.join("test.json");
        fs::write(&first, r#"{"name":"first"}"#)?;
        fs::write(dirs[1].join("test.json"), r#"{"name":"next"}"#)?;
        assert_eq!(ResolvedPalette::load_from_dirs("test", &dirs).name, "first");
        fs::write(&first, "not JSON")?;
        assert_eq!(ResolvedPalette::load_from_dirs("test", &dirs).name, "next");
        assert_eq!(
            ResolvedPalette::load_from_dirs("missing", &dirs),
            ResolvedPalette::kanagawa()
        );
        fs::remove_dir_all(dir)
    }

    #[test]
    fn generates_all_four_app_theme_targets() {
        let dir = std::env::temp_dir().join(format!("kaze-core-theme-test-{}", std::process::id()));
        fs::DirBuilder::new()
            .mode(0o700)
            .create(&dir)
            .expect("private theme fixture");
        let paths = ThemePaths::from_config_home(&dir);
        let pal = ResolvedPalette::kanagawa();

        let dark =
            generate_all_templates(&pal, ThemeMode::Dark, &paths, false).expect("dark templates");
        let hypr_dark = fs::read_to_string(&paths.hyprland).expect("hypr dark");
        let foot_dark = fs::read_to_string(&paths.foot).expect("foot dark");
        let gtk3_dark = fs::read_to_string(&paths.gtk3).expect("gtk3 dark");
        let gtk4_dark = fs::read_to_string(&paths.gtk4).expect("gtk4 dark");
        let btop_dark = fs::read_to_string(&paths.btop).expect("btop dark");

        assert!(hypr_dark.contains("col.active_border"));
        assert!(foot_dark.contains("[colors-dark]"));
        assert!(foot_dark.contains("background=1f1f28"));
        assert!(gtk3_dark.contains("@define-color window_bg_color #1f1f28;"));
        assert_eq!(gtk3_dark, gtk4_dark);
        assert!(btop_dark.contains("theme[main_bg]=\"#1f1f28\""));

        let light =
            generate_all_templates(&pal, ThemeMode::Light, &paths, false).expect("light templates");
        assert_ne!(dark.hypr_active_border, light.hypr_active_border);
        let foot_light = fs::read_to_string(&paths.foot).expect("foot light");
        assert!(foot_light.contains("background=f2ecbc"));

        let _ = fs::remove_dir_all(&dir);
    }
}
