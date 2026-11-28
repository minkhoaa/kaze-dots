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
            Self::Internet => app
                .categories
                .iter()
                .any(|c| matches!(c.as_str(), "Network" | "WebBrowser" | "Email" | "InstantMessaging")),
            Self::Media => app
                .categories
                .iter()
                .any(|c| matches!(c.as_str(), "AudioVideo" | "Audio" | "Video" | "Graphics" | "Photography")),
            Self::System => app
                .categories
                .iter()
                .any(|c| matches!(c.as_str(), "System" | "Settings" | "Monitor")),
            Self::Utilities => app
                .categories
                .iter()
                .any(|c| matches!(c.as_str(), "Utility" | "Accessories" | "Archiving" | "TextEditor")),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DesktopApp {
    pub id: String,
    pub name: String,
    pub generic_name: String,
    pub comment: String,
    pub keywords: String,
    pub exec: String,
    pub terminal: bool,
    pub categories: Vec<String>,
}

impl DesktopApp {
    /// Parses `Exec=` into `(program, args)`, stripping XDG field codes (`%u`, `%U`, `%f`, `%F`,
    /// `%i`, `%c`, `%k`, `%d`, `%D`, `%n`, `%N`, `%v`, `%m`) and wrapping `Terminal=true` apps
    /// through `kaze-footclient -N -e`.
    pub fn build_command(&self) -> Option<(String, Vec<String>)> {
        let parts = parse_desktop_exec(&self.exec);
        let (program, args) = parts.split_first()?;
        if self.terminal {
            let mut wrapped = vec!["-N".to_string(), "-e".to_string(), program.clone()];
            wrapped.extend(args.iter().cloned());
            Some(("kaze-footclient".to_string(), wrapped))
        } else {
            Some((program.clone(), args.to_vec()))
        }
    }

    pub fn subtitle(&self) -> &str {
        if !self.generic_name.is_empty() && !self.generic_name.eq_ignore_ascii_case(&self.name) {
            &self.generic_name
        } else {
            &self.comment
        }
    }
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
                    by_id.insert(id, Some(app));
                }
                DesktopParse::Hidden => {
                    // Higher-precedence `Hidden=true`/`NoDisplay=true` hides lower-precedence system entry.
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
    App(DesktopApp),
    Hidden,
    Ignore,
}

fn parse_desktop_file(id: &str, raw: &str) -> DesktopParse {
    let mut in_entry = false;
    let mut entry_type = String::new();
    let mut name = String::new();
    let mut generic_name = String::new();
    let mut comment = String::new();
    let mut keywords = String::new();
    let mut exec = String::new();
    let mut terminal = false;
    let mut no_display = false;
    let mut hidden = false;
    let mut categories = Vec::new();

    for line in raw.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        if trimmed.starts_with('[') && trimmed.ends_with(']') {
            in_entry = trimmed == "[Desktop Entry]";
            continue;
        }
        if !in_entry {
            continue;
        }
        let Some((key, val)) = trimmed.split_once('=') else {
            continue;
        };
        let key = key.trim();
        let val = val.trim();
        match key {
            "Type" => entry_type = val.to_string(),
            "Name" => name = val.to_string(),
            "GenericName" => generic_name = val.to_string(),
            "Comment" => comment = val.to_string(),
            "Keywords" => keywords = val.replace(';', " "),
            "Exec" => exec = val.to_string(),
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
            _ => {}
        }
    }

    if hidden || no_display {
        return DesktopParse::Hidden;
    }
    if entry_type != "Application" || name.is_empty() || exec.is_empty() {
        return DesktopParse::Ignore;
    }

    DesktopParse::App(DesktopApp {
        id: id.to_string(),
        name,
        generic_name,
        comment,
        keywords,
        exec,
        terminal,
        categories,
    })
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
    fn strips_field_codes_and_wraps_terminal_apps() {
        let parts = parse_desktop_exec("firefox --new-window %u --class=\"My App\" %F %%lit");
        assert_eq!(
            parts,
            vec!["firefox", "--new-window", "--class=My App", "%lit"]
        );

        let term_app = DesktopApp {
            id: "yazi.desktop".into(),
            name: "Yazi".into(),
            generic_name: "File Manager".into(),
            comment: String::new(),
            keywords: String::new(),
            exec: "yazi %u".into(),
            terminal: true,
            categories: vec!["System".into(), "Utility".into()],
        };
        let (prog, args) = term_app.build_command().expect("terminal command");
        assert_eq!(prog, "kaze-footclient");
        assert_eq!(args, vec!["-N", "-e", "yazi"]);
    }

    #[test]
    fn scans_desktop_files_respecting_nodisplay_hidden_and_user_override() {
        let root = std::env::temp_dir().join(format!("kaze-desktop-scan-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let sys_dir = root.join("sys");
        let usr_dir = root.join("usr");
        fs::DirBuilder::new()
            .mode(0o700)
            .recursive(true)
            .create(&sys_dir)
            .expect("create sys dir");
        fs::create_dir_all(&usr_dir).expect("create usr dir");

        fs::write(
            sys_dir.join("foot.desktop"),
            "[Desktop Entry]\nType=Application\nName=Foot\nExec=foot\n",
        )
        .expect("write foot");
        fs::write(
            sys_dir.join("hidden.desktop"),
            "[Desktop Entry]\nType=Application\nName=Hidden\nExec=true\nNoDisplay=true\n",
        )
        .expect("write hidden");
        fs::write(
            sys_dir.join("override.desktop"),
            "[Desktop Entry]\nType=Application\nName=SystemName\nExec=sys-app %U\n",
        )
        .expect("write override sys");
        fs::write(
            usr_dir.join("override.desktop"),
            "[Desktop Entry]\nType=Application\nName=UserName\nExec=user-app %f\n",
        )
        .expect("write override usr");
        fs::write(
            usr_dir.join("foot.desktop"),
            "[Desktop Entry]\nType=Application\nName=Foot\nExec=foot\nHidden=true\n",
        )
        .expect("hide foot");

        let apps = scan_applications_in(&[sys_dir, usr_dir]);
        assert_eq!(apps.len(), 1);
        assert_eq!(apps[0].name, "UserName");
        assert_eq!(
            apps[0].build_command(),
            Some(("user-app".to_string(), vec![]))
        );

        let _ = fs::remove_dir_all(&root);
    }
}
