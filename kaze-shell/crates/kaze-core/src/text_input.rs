use crate::config::InputKeybindsConfig;
use crate::extension::{ImeEvent, KeyEvent};
use unicode_bidi::BidiInfo;
use unicode_segmentation::UnicodeSegmentation;
use zeroize::Zeroize;

const KEY_BACKSPACE: u32 = 0xff08;
const KEY_RETURN: u32 = 0xff0d;
const KEY_ESCAPE: u32 = 0xff1b;
const KEY_HOME: u32 = 0xff50;
const KEY_LEFT: u32 = 0xff51;
const KEY_RIGHT: u32 = 0xff53;
const KEY_END: u32 = 0xff57;
const KEY_KP_ENTER: u32 = 0xff8d;
const KEY_DELETE: u32 = 0xffff;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TextInputOutcome {
    None,
    Changed,
    Copy(String),
    Cut(String),
    RequestPaste,
    Submit,
    Cancel,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TextDirection {
    Ltr,
    Rtl,
}

#[derive(Debug, Clone, Default)]
pub struct TextInputState {
    pub text: String,
    pub cursor: usize,
    pub anchor: Option<usize>,
    pub preedit: String,
    pub preedit_cursor: (i32, i32),
    pub password_mode: bool,
}

impl Drop for TextInputState {
    fn drop(&mut self) {
        if self.password_mode {
            self.clear();
        }
    }
}

impl TextInputState {
    pub fn new(password_mode: bool) -> Self {
        Self {
            text: String::new(),
            cursor: 0,
            anchor: None,
            preedit: String::new(),
            preedit_cursor: (0, 0),
            password_mode,
        }
    }

    pub fn clear(&mut self) {
        if self.password_mode {
            self.text.zeroize();
            self.preedit.zeroize();
        } else {
            self.text.clear();
            self.preedit.clear();
        }
        self.cursor = 0;
        self.anchor = None;
        self.preedit_cursor = (0, 0);
    }

    pub fn clear_preedit(&mut self) {
        if self.password_mode {
            self.preedit.zeroize();
        } else {
            self.preedit.clear();
        }
        self.preedit_cursor = (0, 0);
    }

    pub fn set_text(&mut self, value: &str) {
        self.clear();
        self.text.push_str(value);
        self.cursor = self.text.len();
    }

    pub fn selection_range(&self) -> Option<(usize, usize)> {
        let a = self.anchor?;
        if a == self.cursor {
            None
        } else if a < self.cursor {
            Some((a, self.cursor))
        } else {
            Some((self.cursor, a))
        }
    }

    pub fn selected_text(&self) -> Option<&str> {
        let (s, e) = self.selection_range()?;
        self.text.get(s..e)
    }

    pub fn base_direction(&self) -> TextDirection {
        if self.text.is_empty() {
            return TextDirection::Ltr;
        }
        let info = BidiInfo::new(&self.text, None);
        if info.paragraphs.first().is_some_and(|p| p.level.is_rtl()) {
            TextDirection::Rtl
        } else {
            TextDirection::Ltr
        }
    }

    pub fn paste_text(&mut self, raw: &str) -> bool {
        let printable: String = raw
            .chars()
            .filter(|c| !c.is_control() || *c == ' ')
            .collect();
        if printable.is_empty() {
            return false;
        }
        self.insert_str(&printable);
        true
    }

    pub fn handle_ime(&mut self, ime: &ImeEvent) -> bool {
        match ime {
            ImeEvent::Preedit {
                text,
                cursor_begin,
                cursor_end,
            } => {
                self.preedit = text.clone();
                self.preedit_cursor = (*cursor_begin, *cursor_end);
                true
            }
            ImeEvent::Commit(committed) => {
                self.clear_preedit();
                let printable: String = committed.chars().filter(|c| !c.is_control()).collect();
                if !printable.is_empty() {
                    self.insert_str(&printable);
                }
                true
            }
            ImeEvent::DeleteSurrounding { before, after } => {
                self.delete_surrounding_bytes(*before as usize, *after as usize);
                true
            }
        }
    }

    pub fn handle_key(
        &mut self,
        key: &KeyEvent,
        keybinds: &InputKeybindsConfig,
    ) -> TextInputOutcome {
        if !key.pressed {
            return TextInputOutcome::None;
        }
        if key.keysym == KEY_ESCAPE {
            self.clear_preedit();
            return TextInputOutcome::Cancel;
        }
        if key.keysym == KEY_RETURN || key.keysym == KEY_KP_ENTER {
            self.clear_preedit();
            return TextInputOutcome::Submit;
        }

        if matches_binding(key, &keybinds.select_all) {
            self.anchor = Some(0);
            self.cursor = self.text.len();
            return TextInputOutcome::Changed;
        }
        if matches_binding(key, &keybinds.copy) {
            if self.password_mode {
                return TextInputOutcome::None;
            }
            if let Some(sel) = self.selected_text() {
                return TextInputOutcome::Copy(sel.to_string());
            }
            return TextInputOutcome::None;
        }
        if matches_binding(key, &keybinds.cut) {
            if self.password_mode {
                return TextInputOutcome::None;
            }
            if let Some(sel) = self.selected_text().map(str::to_string) {
                self.delete_selection();
                return TextInputOutcome::Cut(sel);
            }
            return TextInputOutcome::None;
        }
        if matches_binding(key, &keybinds.paste) {
            return TextInputOutcome::RequestPaste;
        }
        if matches_binding(key, &keybinds.clear_line) {
            if !self.text.is_empty() || !self.preedit.is_empty() {
                self.clear();
                return TextInputOutcome::Changed;
            }
            return TextInputOutcome::None;
        }
        if matches_binding(key, &keybinds.kill_to_end) {
            if self.cursor < self.text.len() {
                self.text.truncate(self.cursor);
                self.anchor = None;
                return TextInputOutcome::Changed;
            }
            return TextInputOutcome::None;
        }
        if matches_binding(key, &keybinds.delete_word)
            || (key.modifiers.ctrl && key.keysym == KEY_BACKSPACE)
        {
            return if self.delete_prev_word() {
                TextInputOutcome::Changed
            } else {
                TextInputOutcome::None
            };
        }
        if key.modifiers.ctrl && key.keysym == KEY_DELETE {
            return if self.delete_next_word() {
                TextInputOutcome::Changed
            } else {
                TextInputOutcome::None
            };
        }
        if matches_binding_opt(key, &keybinds.word_left, true) {
            self.move_cursor(
                prev_word_boundary(&self.text, self.cursor),
                key.modifiers.shift,
            );
            return TextInputOutcome::Changed;
        }
        if matches_binding_opt(key, &keybinds.word_right, true) {
            self.move_cursor(
                next_word_boundary(&self.text, self.cursor),
                key.modifiers.shift,
            );
            return TextInputOutcome::Changed;
        }

        match key.keysym {
            KEY_LEFT => {
                let target = if !key.modifiers.shift && self.selection_range().is_some() {
                    self.selection_range().map_or(self.cursor, |(s, _)| s)
                } else {
                    prev_grapheme_boundary(&self.text, self.cursor)
                };
                self.move_cursor(target, key.modifiers.shift);
                TextInputOutcome::Changed
            }
            KEY_RIGHT => {
                let target = if !key.modifiers.shift && self.selection_range().is_some() {
                    self.selection_range().map_or(self.cursor, |(_, e)| e)
                } else {
                    next_grapheme_boundary(&self.text, self.cursor)
                };
                self.move_cursor(target, key.modifiers.shift);
                TextInputOutcome::Changed
            }
            KEY_HOME => {
                self.move_cursor(0, key.modifiers.shift);
                TextInputOutcome::Changed
            }
            KEY_END => {
                self.move_cursor(self.text.len(), key.modifiers.shift);
                TextInputOutcome::Changed
            }
            KEY_BACKSPACE => {
                if !self.preedit.is_empty() {
                    let prev = prev_grapheme_boundary(&self.preedit, self.preedit.len());
                    self.preedit.truncate(prev);
                    return TextInputOutcome::Changed;
                }
                if self.delete_selection() {
                    return TextInputOutcome::Changed;
                }
                if self.cursor > 0 {
                    let prev = prev_grapheme_boundary(&self.text, self.cursor);
                    self.text.replace_range(prev..self.cursor, "");
                    self.cursor = prev;
                    self.anchor = None;
                    return TextInputOutcome::Changed;
                }
                TextInputOutcome::None
            }
            KEY_DELETE => {
                if self.delete_selection() {
                    return TextInputOutcome::Changed;
                }
                if self.cursor < self.text.len() {
                    let next = next_grapheme_boundary(&self.text, self.cursor);
                    self.text.replace_range(self.cursor..next, "");
                    self.anchor = None;
                    return TextInputOutcome::Changed;
                }
                TextInputOutcome::None
            }
            _ => {
                if key.modifiers.ctrl || key.modifiers.alt || key.modifiers.logo {
                    return TextInputOutcome::None;
                }
                if let Some(ref utf8) = key.utf8 {
                    let printable: String = utf8.chars().filter(|c| !c.is_control()).collect();
                    if !printable.is_empty() {
                        self.insert_str(&printable);
                        return TextInputOutcome::Changed;
                    }
                }
                TextInputOutcome::None
            }
        }
    }

    fn move_cursor(&mut self, target: usize, extend_selection: bool) {
        let clamped = target.min(self.text.len());
        if extend_selection {
            if self.anchor.is_none() {
                self.anchor = Some(self.cursor);
            }
        } else {
            self.anchor = None;
        }
        self.cursor = clamped;
    }

    fn delete_selection(&mut self) -> bool {
        let Some((s, e)) = self.selection_range() else {
            return false;
        };
        self.text.replace_range(s..e, "");
        self.cursor = s;
        self.anchor = None;
        true
    }

    fn insert_str(&mut self, s: &str) {
        self.delete_selection();
        let pos = self.cursor.min(self.text.len());
        self.text.insert_str(pos, s);
        self.cursor = pos + s.len();
        self.anchor = None;
    }

    fn delete_prev_word(&mut self) -> bool {
        if self.delete_selection() {
            return true;
        }
        if self.cursor == 0 {
            return false;
        }
        let target = prev_word_boundary(&self.text, self.cursor);
        self.text.replace_range(target..self.cursor, "");
        self.cursor = target;
        self.anchor = None;
        true
    }

    fn delete_next_word(&mut self) -> bool {
        if self.delete_selection() {
            return true;
        }
        if self.cursor >= self.text.len() {
            return false;
        }
        let target = next_word_boundary(&self.text, self.cursor);
        self.text.replace_range(self.cursor..target, "");
        self.anchor = None;
        true
    }

    fn delete_surrounding_bytes(&mut self, before: usize, after: usize) {
        self.delete_selection();
        let mut start = self.cursor.saturating_sub(before);
        while start > 0 && !self.text.is_char_boundary(start) {
            start -= 1;
        }
        let mut end = self.cursor.saturating_add(after).min(self.text.len());
        while end < self.text.len() && !self.text.is_char_boundary(end) {
            end += 1;
        }
        if start < end {
            self.text.replace_range(start..end, "");
            self.cursor = start;
        }
    }
}

pub fn prev_grapheme_boundary(s: &str, idx: usize) -> usize {
    let clamped = idx.min(s.len());
    s[..clamped]
        .grapheme_indices(true)
        .next_back()
        .map_or(0, |(pos, _)| pos)
}

pub fn next_grapheme_boundary(s: &str, idx: usize) -> usize {
    let clamped = idx.min(s.len());
    s[clamped..]
        .grapheme_indices(true)
        .nth(1)
        .map_or(s.len(), |(rel, _)| clamped + rel)
}

fn prev_word_boundary(s: &str, idx: usize) -> usize {
    let clamped = idx.min(s.len());
    let mut graphemes: Vec<(usize, &str)> = s[..clamped].grapheme_indices(true).collect();
    while let Some((_, g)) = graphemes.last() {
        if g.chars().all(char::is_whitespace) {
            graphemes.pop();
        } else {
            break;
        }
    }
    while let Some((_, g)) = graphemes.last() {
        if g.chars().all(char::is_whitespace) {
            break;
        }
        graphemes.pop();
    }
    graphemes.last().map_or(0, |(pos, g)| pos + g.len())
}

fn next_word_boundary(s: &str, idx: usize) -> usize {
    let clamped = idx.min(s.len());
    let mut iter = s[clamped..].grapheme_indices(true).peekable();
    while let Some((_, g)) = iter.peek() {
        if g.chars().all(char::is_whitespace) {
            iter.next();
        } else {
            break;
        }
    }
    while let Some(&(rel, g)) = iter.peek() {
        if g.chars().all(char::is_whitespace) {
            return clamped + rel;
        }
        iter.next();
    }
    s.len()
}

pub fn matches_binding(key: &KeyEvent, binding: &str) -> bool {
    matches_binding_opt(key, binding, false)
}

fn matches_binding_opt(key: &KeyEvent, binding: &str, allow_extra_shift: bool) -> bool {
    let mut need_ctrl = false;
    let mut need_alt = false;
    let mut need_shift = false;
    let mut need_logo = false;
    let mut target_key: Option<&str> = None;

    for part in binding.split('+').map(str::trim).filter(|p| !p.is_empty()) {
        match part.to_ascii_lowercase().as_str() {
            "ctrl" | "control" => need_ctrl = true,
            "alt" => need_alt = true,
            "shift" => need_shift = true,
            "super" | "logo" | "mod4" => need_logo = true,
            _ => target_key = Some(part),
        }
    }

    if key.modifiers.ctrl != need_ctrl
        || key.modifiers.alt != need_alt
        || key.modifiers.logo != need_logo
        || (!allow_extra_shift && key.modifiers.shift != need_shift)
        || (allow_extra_shift && need_shift && !key.modifiers.shift)
    {
        return false;
    }

    let Some(tk) = target_key else {
        return false;
    };
    match tk.to_ascii_lowercase().as_str() {
        "left" => key.keysym == KEY_LEFT,
        "right" => key.keysym == KEY_RIGHT,
        "home" => key.keysym == KEY_HOME,
        "end" => key.keysym == KEY_END,
        "backspace" => key.keysym == KEY_BACKSPACE,
        "delete" | "del" => key.keysym == KEY_DELETE,
        "tab" => key.keysym == 0xff09,
        "escape" | "esc" => key.keysym == KEY_ESCAPE,
        "return" | "enter" => key.keysym == KEY_RETURN || key.keysym == KEY_KP_ENTER,
        single if single.chars().count() == 1 => {
            let ch = single.chars().next().unwrap_or('\0');
            let lower = ch.to_ascii_lowercase() as u32;
            let upper = ch.to_ascii_uppercase() as u32;
            key.keysym == lower || key.keysym == upper
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::extension::KeyModifiers;

    fn key(keysym: u32, utf8: Option<&str>, mods: KeyModifiers) -> KeyEvent {
        KeyEvent {
            keysym,
            utf8: utf8.map(str::to_string),
            modifiers: mods,
            pressed: true,
        }
    }

    #[test]
    fn grapheme_backspace_deletes_whole_zwj_emoji_and_bidi_mixed_text() {
        let mut ti = TextInputState::new(false);
        let kb = InputKeybindsConfig::default();
        let sample = "Xin chào مرحبا 👨\u{200d}👩\u{200d}👧\u{200d}👦";
        assert!(ti.handle_ime(&ImeEvent::Commit(sample.into())));
        assert_eq!(ti.text, sample);

        // 1 Backspace must delete the entire ZWJ family emoji cluster cleanly without splitting!
        let out = ti.handle_key(&key(KEY_BACKSPACE, None, KeyModifiers::default()), &kb);
        assert_eq!(out, TextInputOutcome::Changed);
        assert_eq!(ti.text, "Xin chào مرحبا ");

        // Select all + Copy preserves exact UTF-8 bytes.
        ti.handle_key(
            &key(
                b'a' as u32,
                None,
                KeyModifiers {
                    ctrl: true,
                    ..KeyModifiers::default()
                },
            ),
            &kb,
        );
        let copy_out = ti.handle_key(
            &key(
                b'c' as u32,
                None,
                KeyModifiers {
                    ctrl: true,
                    ..KeyModifiers::default()
                },
            ),
            &kb,
        );
        assert_eq!(copy_out, TextInputOutcome::Copy("Xin chào مرحبا ".into()));
    }

    #[test]
    fn preedit_clears_on_escape_and_word_navigation_works() {
        let mut ti = TextInputState::new(false);
        let kb = InputKeybindsConfig::default();
        ti.set_text("hello vietnam");
        ti.handle_ime(&ImeEvent::Preedit {
            text: "đang".into(),
            cursor_begin: 0,
            cursor_end: 4,
        });
        assert_eq!(ti.preedit, "đang");
        let cancel = ti.handle_key(&key(KEY_ESCAPE, None, KeyModifiers::default()), &kb);
        assert_eq!(cancel, TextInputOutcome::Cancel);
        assert!(ti.preedit.is_empty());

        // Ctrl+Left jumps to start of "vietnam"
        ti.handle_key(
            &key(
                KEY_LEFT,
                None,
                KeyModifiers {
                    ctrl: true,
                    ..KeyModifiers::default()
                },
            ),
            &kb,
        );
        assert_eq!(ti.cursor, 6);

        // Ctrl+Shift+Right selects "vietnam" cleanly across word boundary.
        ti.handle_key(
            &key(
                KEY_RIGHT,
                None,
                KeyModifiers {
                    ctrl: true,
                    shift: true,
                    ..KeyModifiers::default()
                },
            ),
            &kb,
        );
        assert_eq!(ti.selected_text(), Some("vietnam"));
    }
}
