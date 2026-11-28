use std::collections::BTreeMap;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AppCategory {
    All,
    Development,
    Internet,
    Media,
    System,
    Utilities,
}

impl AppCategory {
    pub const ALL: &'static [Self] = &[
        Self::All,
        Self::Development,
        Self::Internet,
        Self::Media,
        Self::System,
        Self::Utilities,
    ];

    pub fn label(self) -> &'static str {
        match self {
            Self::All => "All",
            Self::Development => "Dev",
            Self::Internet => "Net",
            Self::Media => "Media",
            Self::System => "System",
            Self::Utilities => "Utils",
        }
    }

    pub fn matches_app(self, app: &DesktopApp) -> bool {
        match self {
            Self::All => true,
            Self::Development => app
                .categories
                .iter()
                .any(|c| matches!(c.as_str(), "Development" | "IDE" | "RevisionControl")),
            Self::Internet => app.categories.iter().any(|c| {
                matches!(
                    c.as_str(),
                    "Network" | "WebBrowser" | "Email" | "InstantMessaging"
                )
            }),
            Self::Media => app.categories.iter().any(|c| {
                matches!(
                    c.as_str(),
                    "AudioVideo" | "Audio" | "Video" | "Graphics" | "Photography"
                )
            }),
            Self::System => app
                .categories
                .iter()
                .any(|c| matches!(c.as_str(), "System" | "Settings" | "Monitor")),
            Self::Utilities => app.categories.iter().any(|c| {
                matches!(
                    c.as_str(),
                    "Utility" | "Accessories" | "Archiving" | "TextEditor"
                )
            }),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DesktopAction {
    pub id: String,
    pub name: String,
    pub exec: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DesktopApp {
    pub id: String,
    pub name: String,
    pub generic_name: String,
    pub comment: String,
    pub keywords: String,
    pub exec: String,
    pub icon: String,
    pub startup_wm_class: String,
    pub terminal: bool,
    pub categories: Vec<String>,
    pub actions: Vec<DesktopAction>,
}

impl DesktopApp {
    /// Parses `Exec=` into `(program, args)`, stripping XDG field codes and wrapping
    /// `Terminal=true` apps through `kaze-footclient -N -e`.
    pub fn build_command(&self) -> Option<(String, Vec<String>)> {
        build_exec_command(&self.exec, self.terminal)
    }

    pub fn build_action_command(&self, action_id: &str) -> Option<(String, Vec<String>)> {
        let act = self.actions.iter().find(|a| a.id == action_id)?;
        build_exec_command(&act.exec, self.terminal)
    }

    pub fn subtitle(&self) -> &str {
        if !self.generic_name.is_empty() && !self.generic_name.eq_ignore_ascii_case(&self.name) {
            &self.generic_name
        } else {
            &self.comment
        }
    }

    pub fn stem(&self) -> &str {
        self.id.strip_suffix(".desktop").unwrap_or(&self.id)
    }
}

pub fn build_exec_command(exec: &str, terminal: bool) -> Option<(String, Vec<String>)> {
    let parts = parse_desktop_exec(exec);
    let (program, args) = parts.split_first()?;
    if terminal {
        let mut wrapped = vec!["-N".to_string(), "-e".to_string(), program.clone()];
        wrapped.extend(args.iter().cloned());
        Some(("kaze-footclient".to_string(), wrapped))
    } else {
        Some((program.clone(), args.to_vec()))
    }
}

/// Finds a `.desktop` entry matching a Wayland/Hyprland `class` or `initialClass`.
pub fn find_desktop_app_for_class<'a>(
    apps: &'a [DesktopApp],
    wm_class: &str,
) -> Option<&'a DesktopApp> {
    let target = wm_class.trim();
    if target.is_empty() {
        return None;
    }
    let target_stem = target.strip_suffix(".desktop").unwrap_or(target);
    apps.iter()
        .find(|a| {
            a.stem().eq_ignore_ascii_case(target_stem)
                || (!a.startup_wm_class.is_empty()
                    && a.startup_wm_class.eq_ignore_ascii_case(target))
        })
        .or_else(|| {
            let lower = target_stem.to_ascii_lowercase();
            apps.iter().find(|a| {
                a.name.eq_ignore_ascii_case(target_stem)
                    || a.stem()
                        .to_ascii_lowercase()
                        .ends_with(&format!(".{lower}"))
            })
        })
}

/// Resolves an XDG icon name or file path to a readable raster/SVG icon file on disk.
pub fn resolve_icon_path(icon_name: &str) -> Option<PathBuf> {
    let trimmed = icon_name.trim();
    if trimmed.is_empty() {
        return None;
    }
    let direct = PathBuf::from(trimmed);
    if direct.is_absolute() && direct.is_file() {
        return Some(direct);
    }

    let mut roots = Vec::new();
    if let Some(xdg) = env::var_os("XDG_DATA_HOME").filter(|v| !v.is_empty()) {
        roots.push(PathBuf::from(xdg).join("icons"));
    } else if let Some(home) = env::var_os("HOME").filter(|v| !v.is_empty()) {
        roots.push(PathBuf::from(home).join(".local/share/icons"));
    }
    roots.push(PathBuf::from("/usr/local/share/icons"));
    roots.push(PathBuf::from("/usr/share/icons"));

    let themes = ["hicolor", "Papirus", "Adwaita", "breeze"];
    let sizes = ["64x64", "48x48", "128x128", "32x32", "24x24", "scalable"];
    let exts = ["png", "webp", "svg"];

    for root in &roots {
        for theme in themes {
            for size in sizes {
                for ext in exts {
                    let candidate = root
                        .join(theme)
                        .join(size)
                        .join("apps")
                        .join(format!("{trimmed}.{ext}"));
                    if candidate.is_file() {
                        return Some(candidate);
                    }
                }
            }
        }
    }

    let pixmaps = Path::new("/usr/share/pixmaps");
    for ext in exts {
        let candidate = pixmaps.join(format!("{trimmed}.{ext}"));
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

/// Returns standard XDG application directories ordered from lowest to highest precedence
/// so user overrides under `~/.local/share/applications` replace system entries of the same ID.
pub fn application_dirs() -> Vec<PathBuf> {
    let mut dirs = vec![
        PathBuf::from("/usr/share/applications"),
        PathBuf::from("/usr/local/share/applications"),
    ];
    if let Some(user_dir) = user_applications_dir() {
        dirs.push(user_dir);
    }
    dirs
}

pub fn user_applications_dir() -> Option<PathBuf> {
    if let Some(xdg) = env::var_os("XDG_DATA_HOME").filter(|v| !v.is_empty()) {
        let p = PathBuf::from(xdg);
        if p.is_absolute() {
            return Some(p.join("applications"));
        }
    }
    env::var_os("HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .map(|h| h.join(".local").join("share").join("applications"))
}

pub fn scan_applications() -> Vec<DesktopApp> {
    scan_applications_in(&application_dirs())
}

pub fn scan_applications_in(dirs: &[PathBuf]) -> Vec<DesktopApp> {
    let mut by_id: BTreeMap<String, Option<DesktopApp>> = BTreeMap::new();

    for dir in dirs {
        let Ok(entries) = fs::read_dir(dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("desktop") {
                continue;
            }
            let Some(file_name) = path.file_name().and_then(|n| n.to_str()) else {
                continue;
            };
            let id = file_name.to_string();
            let Ok(raw) = fs::read_to_string(&path) else {
                continue;
            };
            match parse_desktop_file(&id, &raw) {
                DesktopParse::App(app) => {
                    by_id.insert(id, Some(*app));
                }
                DesktopParse::Hidden => {
                    by_id.insert(id, None);
                }
                DesktopParse::Ignore => {}
            }
        }
    }

    let mut apps: Vec<DesktopApp> = by_id.into_values().flatten().collect();
    apps.sort_by(|a, b| {
        a.name
            .to_lowercase()
            .cmp(&b.name.to_lowercase())
            .then_with(|| a.id.cmp(&b.id))
    });
    apps
}

enum DesktopParse {
    App(Box<DesktopApp>),
    Hidden,
    Ignore,
}

enum Section {
    None,
    Entry,
    Action(String),
}

fn parse_desktop_file(id: &str, raw: &str) -> DesktopParse {
    let mut section = Section::None;
    let mut entry_type = String::new();
    let mut name = String::new();
    let mut generic_name = String::new();
    let mut comment = String::new();
    let mut keywords = String::new();
    let mut exec = String::new();
    let mut icon = String::new();
    let mut startup_wm_class = String::new();
    let mut terminal = false;
    let mut no_display = false;
    let mut hidden = false;
    let mut categories = Vec::new();
    let mut action_order: Vec<String> = Vec::new();
    let mut action_map: BTreeMap<String, (String, String)> = BTreeMap::new();

    for line in raw.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        if trimmed.starts_with('[') && trimmed.ends_with(']') {
            let header = &trimmed[1..trimmed.len() - 1];
            section = if header == "Desktop Entry" {
                Section::Entry
            } else if let Some(act_id) = header.strip_prefix("Desktop Action ") {
                Section::Action(act_id.trim().to_string())
            } else {
                Section::None
            };
            continue;
        }
        let Some((key, val)) = trimmed.split_once('=') else {
            continue;
        };
        let key = key.trim();
        let val = val.trim();
        match &section {
            Section::None => {}
            Section::Entry => match key {
                "Type" => entry_type = val.to_string(),
                "Name" => name = val.to_string(),
                "GenericName" => generic_name = val.to_string(),
                "Comment" => comment = val.to_string(),
                "Keywords" => keywords = val.replace(';', " "),
                "Exec" => exec = val.to_string(),
                "Icon" => icon = val.to_string(),
                "StartupWMClass" => startup_wm_class = val.to_string(),
                "Terminal" => terminal = val.eq_ignore_ascii_case("true"),
                "NoDisplay" => no_display = val.eq_ignore_ascii_case("true"),
                "Hidden" => hidden = val.eq_ignore_ascii_case("true"),
                "Categories" => {
                    categories = val
                        .split(';')
                        .map(str::trim)
                        .filter(|c| !c.is_empty())
                        .map(str::to_string)
                        .collect();
                }
                "Actions" => {
                    action_order = val
                        .split(';')
                        .map(str::trim)
                        .filter(|c| !c.is_empty())
                        .map(str::to_string)
                        .collect();
                }
                _ => {}
            },
            Section::Action(act_id) => {
                let entry = action_map.entry(act_id.clone()).or_default();
                match key {
                    "Name" => entry.0 = val.to_string(),
                    "Exec" => entry.1 = val.to_string(),
                    _ => {}
                }
            }
        }
    }

    if hidden || no_display {
        return DesktopParse::Hidden;
    }
    if entry_type != "Application" || name.is_empty() || exec.is_empty() {
        return DesktopParse::Ignore;
    }

    let mut actions = Vec::new();
    for act_id in action_order {
        if let Some((act_name, act_exec)) = action_map.remove(&act_id) {
            if !act_name.is_empty() && !act_exec.is_empty() {
                actions.push(DesktopAction {
                    id: act_id,
                    name: act_name,
                    exec: act_exec,
                });
            }
        }
    }

    DesktopParse::App(Box::new(DesktopApp {
        id: id.to_string(),
        name,
        generic_name,
        comment,
        keywords,
        exec,
        icon,
        startup_wm_class,
        terminal,
        categories,
        actions,
    }))
}

/// Tokenizes a Desktop Entry `Exec=` value following XDG quoting/escaping rules and strips
/// standard `%` field codes (`%f`, `%F`, `%u`, `%U`, `%i`, `%c`, `%k`, etc.).
pub fn parse_desktop_exec(exec: &str) -> Vec<String> {
    let mut raw_tokens = Vec::new();
    let mut current = String::new();
    let mut in_double = false;
    let mut in_single = false;
    let mut escaped = false;
    let mut has_token = false;

    for ch in exec.chars() {
        if escaped {
            current.push(ch);
            escaped = false;
            has_token = true;
            continue;
        }
        if in_double {
            match ch {
                '\\' => escaped = true,
                '"' => in_double = false,
                _ => current.push(ch),
            }
            has_token = true;
        } else if in_single {
            if ch == '\'' {
                in_single = false;
            } else {
                current.push(ch);
            }
            has_token = true;
        } else {
            match ch {
                '\\' => {
                    escaped = true;
                    has_token = true;
                }
                '"' => {
                    in_double = true;
                    has_token = true;
                }
                '\'' => {
                    in_single = true;
                    has_token = true;
                }
                c if c.is_whitespace() => {
                    if has_token {
                        raw_tokens.push(std::mem::take(&mut current));
                        has_token = false;
                    }
                }
                _ => {
                    current.push(ch);
                    has_token = true;
                }
            }
        }
    }
    if has_token {
        raw_tokens.push(current);
    }

    let mut cleaned = Vec::with_capacity(raw_tokens.len());
    for token in raw_tokens {
        if is_standalone_field_code(&token) {
            continue;
        }
        let stripped = strip_inline_field_codes(&token);
        if !stripped.is_empty() {
            cleaned.push(stripped);
        }
    }
    cleaned
}

fn is_standalone_field_code(tok: &str) -> bool {
    let bytes = tok.as_bytes();
    bytes.len() == 2
        && bytes[0] == b'%'
        && matches!(
            bytes[1],
            b'f' | b'F'
                | b'u'
                | b'U'
                | b'd'
                | b'D'
                | b'n'
                | b'N'
                | b'i'
                | b'c'
                | b'k'
                | b'v'
                | b'm'
        )
}

fn strip_inline_field_codes(tok: &str) -> String {
    let mut out = String::with_capacity(tok.len());
    let mut chars = tok.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '%' {
            match chars.peek().copied() {
                Some('%') => {
                    let _ = chars.next();
                    out.push('%');
                }
                Some(
                    'f' | 'F' | 'u' | 'U' | 'd' | 'D' | 'n' | 'N' | 'i' | 'c' | 'k' | 'v' | 'm',
                ) => {
                    let _ = chars.next();
                }
                _ => out.push('%'),
            }
        } else {
            out.push(ch);
        }
    }
    out
}

pub fn existing_watch_dirs() -> Vec<PathBuf> {
    application_dirs()
        .into_iter()
        .filter(|p| Path::new(p).is_dir())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::DirBuilderExt;

    #[test]
    fn parses_desktop_actions_icon_and_wm_class() {
        let dir = std::env::temp_dir().join(format!("kaze-core-desktop-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::DirBuilder::new()
            .mode(0o700)
            .recursive(true)
            .create(&dir)
            .expect("create dir");
        fs::write(
            dir.join("firefox.desktop"),
            "[Desktop Entry]\nType=Application\nName=Firefox\nExec=firefox %u\nIcon=firefox\nStartupWMClass=firefox\nActions=new-window;private;\n\n[Desktop Action new-window]\nName=New Window\nExec=firefox --new-window\n\n[Desktop Action private]\nName=Private Window\nExec=firefox --private-window\n",
        )
        .expect("write desktop");

        let apps = scan_applications_in(std::slice::from_ref(&dir));
        assert_eq!(apps.len(), 1);
        assert_eq!(apps[0].icon, "firefox");
        assert_eq!(apps[0].actions.len(), 2);
        assert_eq!(apps[0].actions[0].id, "new-window");
        assert_eq!(
            apps[0].build_action_command("private"),
            Some(("firefox".into(), vec!["--private-window".into()]))
        );
        assert!(find_desktop_app_for_class(&apps, "Firefox").is_some());

        let _ = fs::remove_dir_all(&dir);
    }
}
