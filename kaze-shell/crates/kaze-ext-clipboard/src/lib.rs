#![deny(clippy::unwrap_used)]

use kaze_core::crypto::{default_master_key_path, EncryptedRecordStore, MasterKey};
use kaze_core::layout::xdg_state_home;
use kaze_core::{
    t, Anchor, AppState, DirtyFlags, EdgeInsets, HitTarget, I18nKey, ImeEvent, IpcResult,
    KazeExtension, KeyboardMode, Layer, PaintCmd, PointerButton, Rect, ShellAction, ShellContext,
    SurfaceSpec, SystemEvent, TextAlign, TextInputOutcome, TextInputState,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

const SURFACE_ID: &str = "clipboard:main";
const NAMESPACE: &str = "kaze-clipboard";

const KEY_TAB: u32 = 0xff09;
const KEY_UP: u32 = 0xff52;
const KEY_DOWN: u32 = 0xff54;
const KEY_PAGE_UP: u32 = 0xff55;
const KEY_PAGE_DOWN: u32 = 0xff56;
const KEY_DELETE: u32 = 0xffff;
const KEY_P_LOWER: u32 = 0x0070;
const KEY_P_UPPER: u32 = 0x0050;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClipboardEntry {
    pub id: u64,
    pub sha256: [u8; 32],
    pub mime: String,
    pub payload: Vec<u8>,
    pub preview_text: String,
    pub is_image: bool,
    pub pinned: bool,
    pub timestamp: u64,
    #[serde(skip)]
    pub thumb_rgba: Option<(u32, u32, Arc<[u8]>)>,
}

pub fn default_clipboard_store_path() -> Result<PathBuf, String> {
    Ok(xdg_state_home()?.join("clipboard.enc"))
}

pub fn generate_thumbnail_rgba(payload: &[u8]) -> Option<(u32, u32, Arc<[u8]>)> {
    let img = image::load_from_memory(payload).ok()?;
    let w = img.width().max(1);
    let h = img.height().max(1);
    let resized = if w > 256 || h > 256 {
        img.thumbnail(256, 256)
    } else {
        img
    };
    let rgba = resized.to_rgba8();
    let tw = rgba.width();
    let th = rgba.height();
    let mut raw = rgba.into_raw();
    // Convert straight RGBA -> premultiplied RGBA for `PaintCmd::Image`.
    let (chunks, _) = raw.as_chunks_mut::<4>();
    for px in chunks {
        let a = u16::from(px[3]);
        if a < 255 {
            px[0] = ((u16::from(px[0]) * a + 127) / 255) as u8;
            px[1] = ((u16::from(px[1]) * a + 127) / 255) as u8;
            px[2] = ((u16::from(px[2]) * a + 127) / 255) as u8;
        }
    }
    Some((tw, th, Arc::from(raw)))
}

fn summarize_entry(
    mime: &str,
    bytes: &[u8],
    thumb: Option<&(u32, u32, Arc<[u8]>)>,
) -> (bool, String) {
    if mime.starts_with("image/") {
        let label = match thumb {
            Some((tw, th, _)) => format!(
                "Image ({mime} · {tw}×{th} · {} KiB)",
                (bytes.len() / 1024).max(1)
            ),
            None => format!("Image ({mime} · {} KiB)", (bytes.len() / 1024).max(1)),
        };
        (true, label)
    } else {
        let raw = String::from_utf8_lossy(bytes);
        let collapsed: String = raw.split_whitespace().collect::<Vec<_>>().join(" ");
        let preview = if collapsed.chars().count() > 120 {
            let truncated: String = collapsed.chars().take(120).collect();
            format!("{truncated}…")
        } else {
            collapsed
        };
        (false, preview)
    }
}

pub fn mime_is_ignored(mime: &str, ignore_mimes: &[String]) -> bool {
    let m = mime.trim().to_ascii_lowercase();
    ignore_mimes
        .iter()
        .any(|pat| m == pat.trim().to_ascii_lowercase())
}

pub struct ClipboardExtension {
    open: bool,
    entries: Vec<ClipboardEntry>,
    next_id: u64,
    input: TextInputState,
    filtered: Vec<usize>,
    selected: usize,
    scroll_offset: usize,
    cached_spec: Option<SurfaceSpec>,
    store_path: Option<PathBuf>,
    master_key: Option<MasterKey>,
}

impl Default for ClipboardExtension {
    fn default() -> Self {
        Self::new(None, None)
    }
}

impl ClipboardExtension {
    pub fn new(store_path: Option<PathBuf>, master_key: Option<MasterKey>) -> Self {
        let mut ext = Self {
            open: false,
            entries: Vec::new(),
            next_id: 1,
            input: TextInputState::new(false),
            filtered: Vec::new(),
            selected: 0,
            scroll_offset: 0,
            cached_spec: None,
            store_path,
            master_key,
        };
        ext.load_from_disk();
        ext
    }

    pub fn set_backing(&mut self, store_path: PathBuf, master_key: MasterKey) {
        self.store_path = Some(store_path);
        self.master_key = Some(master_key);
        self.load_from_disk();
    }

    pub fn entries(&self) -> &[ClipboardEntry] {
        &self.entries
    }

    fn load_from_disk(&mut self) {
        let (Some(ref path), Some(ref key)) = (&self.store_path, &self.master_key) else {
            return;
        };
        let (records, corrupted) = EncryptedRecordStore::load_records(path, key);
        if corrupted > 0 {
            eprintln!("kaze-clipboard: isolated {corrupted} corrupted record(s) from store");
        }
        let mut loaded = Vec::new();
        let mut max_id = 0u64;
        for rec in records {
            if let Ok(mut entry) = serde_json::from_slice::<ClipboardEntry>(&rec) {
                if entry.is_image {
                    entry.thumb_rgba = generate_thumbnail_rgba(&entry.payload);
                }
                max_id = max_id.max(entry.id);
                loaded.push(entry);
            }
        }
        self.entries = loaded;
        self.next_id = max_id + 1;
        if corrupted > 0 {
            self.save_to_disk();
        }
    }

    fn save_to_disk(&self) {
        let (Some(ref path), Some(ref key)) = (&self.store_path, &self.master_key) else {
            return;
        };
        let mut encoded = Vec::with_capacity(self.entries.len());
        for e in &self.entries {
            if let Ok(buf) = serde_json::to_vec(e) {
                encoded.push(buf);
            }
        }
        let slices: Vec<&[u8]> = encoded.iter().map(Vec::as_slice).collect();
        if let Err(err) = EncryptedRecordStore::save_records(path, key, &slices) {
            eprintln!("kaze-clipboard: failed persisting encrypted store: {err}");
        }
    }

    pub fn record_offer(&mut self, mime: &str, bytes: Vec<u8>, state: &AppState) -> bool {
        let cfg = &state.config.clipboard;
        if !cfg.enabled || bytes.is_empty() || bytes.len() > cfg.max_item_bytes {
            return false;
        }
        if mime_is_ignored(mime, &cfg.ignore_mimes) {
            return false;
        }
        let digest: [u8; 32] = Sha256::digest(&bytes).into();
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);

        if let Some(pos) = self.entries.iter().position(|e| e.sha256 == digest) {
            let mut existing = self.entries.remove(pos);
            existing.timestamp = now;
            self.entries.insert(0, existing);
            self.save_to_disk();
            return true;
        }

        let thumb_rgba = if mime.starts_with("image/") {
            generate_thumbnail_rgba(&bytes)
        } else {
            None
        };
        let (is_image, preview_text) = summarize_entry(mime, &bytes, thumb_rgba.as_ref());
        if preview_text.trim().is_empty() && !is_image {
            return false;
        }
        let id = self.next_id;
        self.next_id = self.next_id.saturating_add(1);
        self.entries.insert(
            0,
            ClipboardEntry {
                id,
                sha256: digest,
                mime: mime.to_string(),
                payload: bytes,
                preview_text,
                is_image,
                pinned: false,
                timestamp: now,
                thumb_rgba,
            },
        );

        let max_items = cfg.max_items.max(1);
        while self.entries.len() > max_items {
            if let Some(pos) = self.entries.iter().rposition(|e| !e.pinned) {
                self.entries.remove(pos);
            } else {
                break;
            }
        }
        self.save_to_disk();
        true
    }

    fn effective_query(&self) -> String {
        if self.input.preedit.is_empty() {
            self.input.text.clone()
        } else {
            let cur = self.input.cursor.min(self.input.text.len());
            format!(
                "{}{}{}",
                &self.input.text[..cur],
                self.input.preedit,
                &self.input.text[cur..]
            )
        }
    }

    fn refilter(&mut self, max_rows: usize) {
        let q = self.effective_query().trim().to_lowercase();
        self.filtered.clear();
        // Pinned items sort first if query is empty? Wait: preserve chronological MRU order,
        // or show [PIN] badge inline so newly copied items are always right at row 0.
        for (idx, entry) in self.entries.iter().enumerate() {
            if q.is_empty()
                || entry.preview_text.to_lowercase().contains(&q)
                || entry.mime.to_lowercase().contains(&q)
            {
                self.filtered.push(idx);
            }
        }
        if self.filtered.is_empty() {
            self.selected = 0;
            self.scroll_offset = 0;
        } else {
            self.selected = self.selected.min(self.filtered.len() - 1);
            self.clamp_scroll(max_rows);
        }
    }

    fn clamp_scroll(&mut self, max_rows: usize) {
        let rows = max_rows.max(1);
        if self.selected < self.scroll_offset {
            self.scroll_offset = self.selected;
        } else if self.selected >= self.scroll_offset + rows {
            self.scroll_offset = self.selected + 1 - rows;
        }
        let max_off = self.filtered.len().saturating_sub(rows);
        self.scroll_offset = self.scroll_offset.min(max_off);
    }

    fn move_selection(&mut self, delta: isize, max_rows: usize) {
        if self.filtered.is_empty() {
            return;
        }
        let len = self.filtered.len() as isize;
        self.selected = (self.selected as isize + delta).rem_euclid(len) as usize;
        self.clamp_scroll(max_rows);
    }

    fn open_overlay(&mut self, state: &AppState) -> DirtyFlags {
        self.open = true;
        self.input.clear();
        self.selected = 0;
        self.scroll_offset = 0;
        self.refilter(state.config.launcher.max_rows);
        self.rebuild(state);
        DirtyFlags::CLIPBOARD | DirtyFlags::LAYOUT
    }

    fn close_overlay(&mut self) -> DirtyFlags {
        if !self.open {
            return DirtyFlags::NONE;
        }
        self.open = false;
        self.input.clear();
        self.filtered.clear();
        self.selected = 0;
        self.scroll_offset = 0;
        self.cached_spec = None;
        DirtyFlags::CLIPBOARD | DirtyFlags::LAYOUT
    }

    fn select_by_index(&mut self, entry_idx: usize, ctx: &mut ShellContext) -> bool {
        if entry_idx >= self.entries.len() {
            return false;
        }
        let entry = self.entries[entry_idx].clone();
        ctx.push_action(ShellAction::SetClipboardSelection {
            mime: entry.mime.clone(),
            bytes: entry.payload.clone(),
        });
        let moved = self.entries.remove(entry_idx);
        self.entries.insert(0, moved);
        self.save_to_disk();
        true
    }

    fn toggle_pin_index(&mut self, entry_idx: usize) -> bool {
        if let Some(e) = self.entries.get_mut(entry_idx) {
            e.pinned = !e.pinned;
            self.save_to_disk();
            true
        } else {
            false
        }
    }

    fn delete_index(&mut self, entry_idx: usize) -> bool {
        if entry_idx < self.entries.len() {
            self.entries.remove(entry_idx);
            self.save_to_disk();
            true
        } else {
            false
        }
    }

    fn clear_history(&mut self, include_pinned: bool) {
        if include_pinned {
            self.entries.clear();
        } else {
            self.entries.retain(|e| e.pinned);
        }
        self.save_to_disk();
    }

    fn rebuild(&mut self, state: &AppState) {
        if !self.open || !state.config.clipboard.enabled {
            self.cached_spec = None;
            return;
        }
        self.cached_spec = Some(build_clipboard_surface(
            state,
            &self.input,
            &self.entries,
            &self.filtered,
            self.selected,
            self.scroll_offset,
        ));
    }
}

impl KazeExtension for ClipboardExtension {
    fn id(&self) -> &'static str {
        "clipboard"
    }

    fn on_init(&mut self, _ctx: &mut ShellContext) {
        if self.store_path.is_none() {
            if let Ok(path) = default_clipboard_store_path() {
                self.store_path = Some(path);
            }
        }
        if self.master_key.is_none() {
            if let Ok(key_path) = default_master_key_path() {
                if let Ok(key) = kaze_core::crypto::load_or_create_keyfile(&key_path) {
                    self.master_key = Some(key);
                }
            }
        }
        self.load_from_disk();
    }

    fn on_event(&mut self, event: &SystemEvent, ctx: &mut ShellContext) -> DirtyFlags {
        match event {
            SystemEvent::ClipboardOfferCaptured {
                mime,
                bytes,
                source_is_self,
            } => {
                if *source_is_self {
                    return DirtyFlags::NONE;
                }
                if self.record_offer(mime, bytes.clone(), ctx.state) && self.open {
                    self.refilter(ctx.state.config.launcher.max_rows);
                    self.rebuild(ctx.state);
                    return DirtyFlags::CLIPBOARD;
                }
                DirtyFlags::NONE
            }
            SystemEvent::ClipboardTextPasted { surface_id, text }
                if surface_id == SURFACE_ID && self.open =>
            {
                if self.input.paste_text(text) {
                    self.selected = 0;
                    self.refilter(ctx.state.config.launcher.max_rows);
                    self.rebuild(ctx.state);
                    return DirtyFlags::CLIPBOARD;
                }
                DirtyFlags::NONE
            }
            SystemEvent::PointerClick {
                surface_id,
                target_id,
                button,
            } if surface_id == SURFACE_ID => {
                if *button == PointerButton::Right {
                    return self.close_overlay();
                }
                if *button == PointerButton::Left {
                    if let Some(idx_str) = target_id.strip_prefix("clip:pin:") {
                        if let Ok(vis) = idx_str.parse::<usize>() {
                            if let Some(&entry_idx) = self.filtered.get(vis) {
                                self.toggle_pin_index(entry_idx);
                                self.refilter(ctx.state.config.launcher.max_rows);
                                self.rebuild(ctx.state);
                                return DirtyFlags::CLIPBOARD;
                            }
                        }
                    }
                    if let Some(idx_str) = target_id.strip_prefix("clip:row:") {
                        if let Ok(vis) = idx_str.parse::<usize>() {
                            if let Some(&entry_idx) = self.filtered.get(vis) {
                                self.select_by_index(entry_idx, ctx);
                                return self.close_overlay();
                            }
                        }
                    }
                }
                DirtyFlags::NONE
            }
            SystemEvent::PointerScroll {
                surface_id,
                delta_y,
                ..
            } if surface_id == SURFACE_ID => {
                let delta = if *delta_y > 0.0 { 1 } else { -1 };
                self.move_selection(delta, ctx.state.config.launcher.max_rows);
                self.rebuild(ctx.state);
                DirtyFlags::CLIPBOARD
            }
            SystemEvent::KeyInput { surface_id, key }
                if surface_id == SURFACE_ID && key.pressed =>
            {
                let max_rows = ctx.state.config.launcher.max_rows;
                if key.modifiers.alt && (key.keysym == KEY_P_LOWER || key.keysym == KEY_P_UPPER) {
                    if let Some(&entry_idx) = self.filtered.get(self.selected) {
                        self.toggle_pin_index(entry_idx);
                        self.refilter(max_rows);
                        self.rebuild(ctx.state);
                        return DirtyFlags::CLIPBOARD;
                    }
                    return DirtyFlags::NONE;
                }
                if key.modifiers.shift && key.keysym == KEY_DELETE {
                    if let Some(&entry_idx) = self.filtered.get(self.selected) {
                        self.delete_index(entry_idx);
                        self.refilter(max_rows);
                        self.rebuild(ctx.state);
                        return DirtyFlags::CLIPBOARD;
                    }
                    return DirtyFlags::NONE;
                }
                match key.keysym {
                    KEY_DOWN => {
                        self.move_selection(1, max_rows);
                        self.rebuild(ctx.state);
                        DirtyFlags::CLIPBOARD
                    }
                    KEY_UP => {
                        self.move_selection(-1, max_rows);
                        self.rebuild(ctx.state);
                        DirtyFlags::CLIPBOARD
                    }
                    KEY_TAB => {
                        self.move_selection(if key.modifiers.shift { -1 } else { 1 }, max_rows);
                        self.rebuild(ctx.state);
                        DirtyFlags::CLIPBOARD
                    }
                    KEY_PAGE_DOWN => {
                        self.move_selection(max_rows as isize, max_rows);
                        self.rebuild(ctx.state);
                        DirtyFlags::CLIPBOARD
                    }
                    KEY_PAGE_UP => {
                        self.move_selection(-(max_rows as isize), max_rows);
                        self.rebuild(ctx.state);
                        DirtyFlags::CLIPBOARD
                    }
                    _ => match self.input.handle_key(key, &ctx.state.config.input.keybinds) {
                        TextInputOutcome::Cancel => self.close_overlay(),
                        TextInputOutcome::Submit => {
                            if let Some(&entry_idx) = self.filtered.get(self.selected) {
                                self.select_by_index(entry_idx, ctx);
                            }
                            self.close_overlay()
                        }
                        TextInputOutcome::Copy(s) | TextInputOutcome::Cut(s) => {
                            ctx.push_action(ShellAction::SetClipboardText(s));
                            self.refilter(max_rows);
                            self.rebuild(ctx.state);
                            DirtyFlags::CLIPBOARD
                        }
                        TextInputOutcome::RequestPaste => {
                            ctx.push_action(ShellAction::RequestClipboardPaste {
                                surface_id: SURFACE_ID.to_string(),
                            });
                            DirtyFlags::NONE
                        }
                        TextInputOutcome::Changed => {
                            self.selected = 0;
                            self.refilter(max_rows);
                            self.rebuild(ctx.state);
                            DirtyFlags::CLIPBOARD
                        }
                        TextInputOutcome::None => DirtyFlags::NONE,
                    },
                }
            }
            SystemEvent::ImeInput { surface_id, ime } if surface_id == SURFACE_ID => {
                if self.input.handle_ime(ime) {
                    if matches!(
                        ime,
                        ImeEvent::Commit(_) | ImeEvent::DeleteSurrounding { .. }
                    ) {
                        self.selected = 0;
                    }
                    self.refilter(ctx.state.config.launcher.max_rows);
                    self.rebuild(ctx.state);
                    DirtyFlags::CLIPBOARD
                } else {
                    DirtyFlags::NONE
                }
            }
            SystemEvent::SurfaceClosed { surface_id }
            | SystemEvent::KeyboardFocusLost { surface_id }
                if surface_id == SURFACE_ID =>
            {
                self.close_overlay()
            }
            SystemEvent::ConfigReloaded
            | SystemEvent::LocaleChanged(_)
            | SystemEvent::ThemeChanged(_)
            | SystemEvent::LayoutPresetChanged(_) => {
                if !ctx.state.config.clipboard.enabled {
                    return self.close_overlay();
                }
                if self.open {
                    self.clamp_scroll(ctx.state.config.launcher.max_rows);
                    self.rebuild(ctx.state);
                    DirtyFlags::CLIPBOARD | DirtyFlags::THEME
                } else {
                    DirtyFlags::NONE
                }
            }
            _ => DirtyFlags::NONE,
        }
    }

    fn on_ipc(&mut self, cmd: &str, args: &[String], ctx: &mut ShellContext) -> IpcResult {
        match cmd {
            "clipboard-toggle" => {
                if !ctx.state.config.clipboard.enabled {
                    return IpcResult::Handled {
                        ok: false,
                        message: "clipboard history disabled in config".into(),
                        dirty: DirtyFlags::NONE,
                    };
                }
                if self.open {
                    let dirty = self.close_overlay();
                    IpcResult::Handled {
                        ok: true,
                        message: "closed".into(),
                        dirty,
                    }
                } else {
                    let dirty = self.open_overlay(ctx.state);
                    IpcResult::Handled {
                        ok: true,
                        message: "opened".into(),
                        dirty,
                    }
                }
            }
            "clipboard-list" => {
                if args.iter().any(|a| a == "--json") {
                    let list: Vec<_> = self
                        .entries
                        .iter()
                        .map(|e| {
                            serde_json::json!({
                                "id": e.id,
                                "mime": e.mime,
                                "pinned": e.pinned,
                                "is_image": e.is_image,
                                "bytes": e.payload.len(),
                                "preview": e.preview_text,
                            })
                        })
                        .collect();
                    let json = serde_json::to_string(&list).unwrap_or_else(|_| "[]".to_string());
                    return IpcResult::Handled {
                        ok: true,
                        message: json,
                        dirty: DirtyFlags::NONE,
                    };
                }
                let lines: Vec<String> = self
                    .entries
                    .iter()
                    .map(|e| {
                        format!(
                            "{}\t{}\t{}\t{}",
                            e.id,
                            if e.pinned { "PIN" } else { "-" },
                            e.mime,
                            e.preview_text
                        )
                    })
                    .collect();
                IpcResult::Handled {
                    ok: true,
                    message: lines.join("\n"),
                    dirty: DirtyFlags::NONE,
                }
            }
            "clipboard-select" => {
                let Some(id) = args.first().and_then(|s| s.parse::<u64>().ok()) else {
                    return IpcResult::Handled {
                        ok: false,
                        message: "usage: clipboard-select <id>".into(),
                        dirty: DirtyFlags::NONE,
                    };
                };
                if let Some(pos) = self.entries.iter().position(|e| e.id == id) {
                    self.select_by_index(pos, ctx);
                    let dirty = self.close_overlay();
                    IpcResult::Handled {
                        ok: true,
                        message: format!("selected {id}"),
                        dirty,
                    }
                } else {
                    IpcResult::Handled {
                        ok: false,
                        message: format!("clipboard entry {id} not found"),
                        dirty: DirtyFlags::NONE,
                    }
                }
            }
            "clipboard-pin" => {
                let Some(id) = args.first().and_then(|s| s.parse::<u64>().ok()) else {
                    return IpcResult::Handled {
                        ok: false,
                        message: "usage: clipboard-pin <id>".into(),
                        dirty: DirtyFlags::NONE,
                    };
                };
                if let Some(pos) = self.entries.iter().position(|e| e.id == id) {
                    self.toggle_pin_index(pos);
                    let pinned = self.entries[pos].pinned;
                    let dirty = if self.open {
                        self.rebuild(ctx.state);
                        DirtyFlags::CLIPBOARD
                    } else {
                        DirtyFlags::NONE
                    };
                    IpcResult::Handled {
                        ok: true,
                        message: format!("{id} pinned={pinned}"),
                        dirty,
                    }
                } else {
                    IpcResult::Handled {
                        ok: false,
                        message: format!("clipboard entry {id} not found"),
                        dirty: DirtyFlags::NONE,
                    }
                }
            }
            "clipboard-delete" => {
                let Some(id) = args.first().and_then(|s| s.parse::<u64>().ok()) else {
                    return IpcResult::Handled {
                        ok: false,
                        message: "usage: clipboard-delete <id>".into(),
                        dirty: DirtyFlags::NONE,
                    };
                };
                if let Some(pos) = self.entries.iter().position(|e| e.id == id) {
                    self.delete_index(pos);
                    let dirty = if self.open {
                        self.refilter(ctx.state.config.launcher.max_rows);
                        self.rebuild(ctx.state);
                        DirtyFlags::CLIPBOARD
                    } else {
                        DirtyFlags::NONE
                    };
                    IpcResult::Handled {
                        ok: true,
                        message: format!("deleted {id}"),
                        dirty,
                    }
                } else {
                    IpcResult::Handled {
                        ok: false,
                        message: format!("clipboard entry {id} not found"),
                        dirty: DirtyFlags::NONE,
                    }
                }
            }
            "clipboard-clear" => {
                let all = args.iter().any(|a| a == "--all");
                self.clear_history(all);
                let dirty = if self.open {
                    self.refilter(ctx.state.config.launcher.max_rows);
                    self.rebuild(ctx.state);
                    DirtyFlags::CLIPBOARD
                } else {
                    DirtyFlags::NONE
                };
                IpcResult::Handled {
                    ok: true,
                    message: if all {
                        "cleared all entries".into()
                    } else {
                        "cleared unpinned entries".into()
                    },
                    dirty,
                }
            }
            _ => IpcResult::Unhandled,
        }
    }

    fn surfaces(&self) -> Vec<SurfaceSpec> {
        self.cached_spec.iter().cloned().collect()
    }
}

fn build_clipboard_surface(
    state: &AppState,
    input: &TextInputState,
    entries: &[ClipboardEntry],
    filtered: &[usize],
    selected: usize,
    scroll_offset: usize,
) -> SurfaceSpec {
    let cfg = &state.config.launcher;
    let bar = &state.config.bar;
    let colors = state.palette.for_mode(state.theme_mode);
    let loc = state.locale;

    let bg = colors.surface_color().with_opacity(bar.background_opacity);
    let primary = colors.primary_color();
    let tertiary = colors.tertiary_color();
    let on_surface = colors.on_surface_color();
    let muted = colors.on_surface_variant_color();
    let outline_variant = colors.outline_variant_color();
    let surface_container = colors.surface_container_color();
    let surface_variant = colors.surface_variant_color();
    let selection_color = colors.secondary_color().with_opacity(0.35);

    let border_w = bar.border_width.max(2.0);
    let w = cfg.width.clamp(420, 960) as f32;
    let pad_x = border_w + 14.0;
    let input_h = 44.0f32;
    let divider_h = 1.0f32;
    let row_h = 48.0f32;
    let visible_rows = filtered.len().clamp(1, cfg.max_rows.max(1));
    let list_pad_y = 6.0f32;
    let total_h =
        (border_w * 2.0 + input_h + divider_h + list_pad_y * 2.0 + visible_rows as f32 * row_h)
            .ceil() as u32;

    let mut commands = Vec::with_capacity(visible_rows * 5 + 8);
    let mut hit_targets = Vec::with_capacity(visible_rows * 2);

    commands.push(PaintCmd::RoundedRect {
        rect: Rect::new(border_w, border_w, w - border_w * 2.0, input_h),
        radius: 0.0,
        fill: Some(surface_container),
        stroke: None,
        stroke_width: 0.0,
    });

    let prompt = t(loc, I18nKey::LauncherPromptClip).to_string();
    let prompt_w = ((prompt.chars().count() as f32) * 8.4 + 8.0).clamp(52.0, 140.0);
    let count_w = 64.0f32;
    let input_y = border_w + 10.0;

    commands.push(PaintCmd::RichText {
        rect: Rect::new(pad_x, input_y, prompt_w, 24.0),
        text: prompt,
        color: primary,
        size: 13.5,
        bold: true,
        align: TextAlign::Left,
        max_lines: 1,
    });

    let query_x = pad_x + prompt_w + 4.0;
    let query_w = (w - query_x - count_w - pad_x - 6.0).max(80.0);
    commands.push(PaintCmd::TextInputField {
        rect: Rect::new(query_x, input_y, query_w, 24.0),
        text: input.text.clone(),
        preedit: input.preedit.clone(),
        cursor_byte: input.cursor,
        selection: input.selection_range(),
        placeholder: t(loc, I18nKey::LauncherPlaceholderClip).to_string(),
        password_mode: false,
        color: on_surface,
        preedit_color: tertiary,
        selection_color,
        placeholder_color: muted,
        size: 13.0,
    });
    let safe_cur = input.cursor.min(input.text.len());
    let chars_before = input.text[..safe_cur].chars().count() + input.preedit.chars().count();
    let caret_x = (query_x + (chars_before as f32) * 7.8).min(query_x + query_w - 4.0);
    let ime_cursor_rect = Some(Rect::new(caret_x, input_y, 2.0, 24.0));

    commands.push(PaintCmd::Text {
        rect: Rect::new(w - pad_x - count_w, border_w, count_w, input_h),
        text: format!("{}/{}", filtered.len(), entries.len()),
        color: muted,
        size: 11.0,
        bold: false,
        align: TextAlign::Right,
    });

    let div_y = border_w + input_h;
    commands.push(PaintCmd::RoundedRect {
        rect: Rect::new(border_w, div_y, w - border_w * 2.0, divider_h),
        radius: 0.0,
        fill: Some(outline_variant),
        stroke: None,
        stroke_width: 0.0,
    });

    let list_y = div_y + divider_h + list_pad_y;
    if filtered.is_empty() {
        commands.push(PaintCmd::RichText {
            rect: Rect::new(pad_x, list_y + 10.0, w - pad_x * 2.0, row_h - 12.0),
            text: t(loc, I18nKey::ClipboardEmpty).to_string(),
            color: muted,
            size: 12.5,
            bold: false,
            align: TextAlign::Center,
            max_lines: 1,
        });
    } else {
        let end = (scroll_offset + visible_rows).min(filtered.len());
        for (vis_idx, &entry_idx) in filtered[scroll_offset..end].iter().enumerate() {
            let entry = &entries[entry_idx];
            let list_pos = scroll_offset + vis_idx;
            let ry = list_y + vis_idx as f32 * row_h;
            let row_rect = Rect::new(border_w + 4.0, ry, w - border_w * 2.0 - 8.0, row_h - 3.0);
            let is_sel = list_pos == selected;

            if is_sel {
                commands.push(PaintCmd::RoundedRect {
                    rect: row_rect,
                    radius: if bar.corner_radius > 0.0 { 4.0 } else { 0.0 },
                    fill: Some(surface_variant),
                    stroke: None,
                    stroke_width: 0.0,
                });
                commands.push(PaintCmd::RoundedRect {
                    rect: Rect::new(row_rect.x, row_rect.y, 3.0, row_rect.h),
                    radius: 0.0,
                    fill: Some(primary),
                    stroke: None,
                    stroke_width: 0.0,
                });
            }

            let mut text_x = row_rect.x + 12.0;
            if let Some((tw, th, ref rgba)) = entry.thumb_rgba {
                let thumb_box = 36.0f32;
                commands.push(PaintCmd::Image {
                    rect: Rect::new(text_x, ry + (row_h - thumb_box) * 0.5, thumb_box, thumb_box),
                    width: tw,
                    height: th,
                    rgba_premul: Arc::clone(rgba),
                });
                text_x += thumb_box + 10.0;
            }

            let pin_w = if entry.pinned { 74.0 } else { 28.0 };
            let text_w = (row_rect.x + row_rect.w - text_x - pin_w - 8.0).max(80.0);
            commands.push(PaintCmd::RichText {
                rect: Rect::new(text_x, ry + 5.0, text_w, 20.0),
                text: entry.preview_text.clone(),
                color: on_surface,
                size: 12.5,
                bold: is_sel,
                align: TextAlign::Left,
                max_lines: 1,
            });
            commands.push(PaintCmd::Text {
                rect: Rect::new(text_x, ry + 26.0, text_w, 14.0),
                text: format!("#{} · {}", entry.id, entry.mime),
                color: muted,
                size: 10.0,
                bold: false,
                align: TextAlign::Left,
            });

            let pin_rect = Rect::new(
                row_rect.x + row_rect.w - pin_w - 4.0,
                ry + 10.0,
                pin_w,
                24.0,
            );
            commands.push(PaintCmd::Text {
                rect: pin_rect,
                text: if entry.pinned {
                    t(loc, I18nKey::ClipboardPinned).to_string()
                } else {
                    "PIN".to_string()
                },
                color: if entry.pinned { tertiary } else { muted },
                size: 10.5,
                bold: entry.pinned,
                align: TextAlign::Right,
            });
            hit_targets.push(HitTarget {
                rect: pin_rect,
                id: format!("clip:pin:{list_pos}"),
            });
            hit_targets.push(HitTarget {
                rect: row_rect,
                id: format!("clip:row:{list_pos}"),
            });
        }
    }

    SurfaceSpec {
        id: SURFACE_ID.to_string(),
        namespace: NAMESPACE.to_string(),
        output: None,
        layer: Layer::Overlay,
        keyboard_interactivity: KeyboardMode::Exclusive,
        anchor: Anchor::TOP,
        exclusive_zone: 0,
        width: cfg.width.clamp(420, 960),
        height: total_h,
        margin: EdgeInsets {
            top: cfg.offset_y,
            ..EdgeInsets::default()
        },
        corner_radius: bar
            .corner_radius
            .max(state.layout_preset.overlay_corner_radius()),
        background: bg,
        border_color: primary,
        border_width: border_w,
        commands,
        hit_targets,
        animating: false,
        input_regions: None,
        ime_cursor_rect,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{ImageFormat, Rgba, RgbaImage};
    use kaze_core::Config;
    use std::io::Cursor;

    fn make_png(w: u32, h: u32) -> Vec<u8> {
        let img = RgbaImage::from_pixel(w, h, Rgba([0xe6, 0x19, 0x19, 0xff]));
        let mut cursor = Cursor::new(Vec::new());
        img.write_to(&mut cursor, ImageFormat::Png)
            .expect("png encode");
        cursor.into_inner()
    }

    #[test]
    fn rejects_secret_mime_and_oversized_50mib_items_without_storing() {
        let state = AppState::new(Config::default());
        let mut ext = ClipboardExtension::default();

        // Secret MIME rejected with 0 bytes stored.
        assert!(!ext.record_offer(
            "x-kde-passwordManagerHint",
            b"super-secret-password".to_vec(),
            &state
        ));
        assert!(ext.entries().is_empty());

        // 50 MiB item exceeds 10 MiB limit and is rejected cleanly.
        let huge = vec![b'A'; 50 * 1024 * 1024];
        assert!(!ext.record_offer("text/plain", huge, &state));
        assert!(ext.entries().is_empty());
    }

    #[test]
    fn creates_real_thumbnail_le_256px_and_deduplicates_sha256() {
        let mut state = AppState::new(Config::default());
        let mut ext = ClipboardExtension::default();
        let png = make_png(500, 500);
        assert!(ext.record_offer("image/png", png.clone(), &state));
        assert!(ext.record_offer("text/plain", b"hello".to_vec(), &state));
        // Duplicate PNG pushes existing entry back to index 0 without creating a 3rd entry.
        assert!(ext.record_offer("image/png", png, &state));
        assert_eq!(ext.entries().len(), 2);
        let first = &ext.entries()[0];
        let (tw, th, _) = first.thumb_rgba.as_ref().expect("thumbnail generated");
        assert!(*tw <= 256 && *th <= 256 && *tw > 0 && *th > 0);

        let mut ctx = ShellContext::new(&mut state);
        ext.on_ipc("clipboard-toggle", &[], &mut ctx);
        let specs = ext.surfaces();
        assert_eq!(specs.len(), 1);
        assert!(specs[0]
            .commands
            .iter()
            .any(|c| matches!(c, PaintCmd::Image { .. })));
    }

    #[test]
    fn pin_survives_250_inserts_and_clear_and_disk_store_has_zero_plaintext() {
        let dir = std::env::temp_dir().join("kaze-clipboard-5c-test");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("mkdir");
        let store_path = dir.join("clipboard.enc");
        let key = MasterKey::generate();

        let mut state = AppState::new(Config::default());
        let mut ext = ClipboardExtension::new(Some(store_path.clone()), Some(key.clone()));
        assert!(ext.record_offer("text/plain", b"PINNED_SECRET_TOKEN_XYZ".to_vec(), &state));
        let pinned_id = ext.entries()[0].id;
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_ipc("clipboard-pin", &[pinned_id.to_string()], &mut ctx);
        }

        for i in 0..250u32 {
            assert!(ext.record_offer("text/plain", format!("entry-item-{i}").into_bytes(), &state));
        }
        assert!(ext.entries().len() <= 200);
        assert!(ext.entries().iter().any(|e| e.id == pinned_id && e.pinned));

        // Verify zero plaintext leaks into encrypted store on disk!
        let disk_bytes = std::fs::read(&store_path).expect("read encrypted store");
        assert!(!disk_bytes
            .windows(b"PINNED_SECRET_TOKEN_XYZ".len())
            .any(|w| w == b"PINNED_SECRET_TOKEN_XYZ"));

        // `clipboard-clear` preserves pinned item; reload from disk still has it.
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_ipc("clipboard-clear", &[], &mut ctx);
        }
        assert_eq!(ext.entries().len(), 1);
        assert_eq!(ext.entries()[0].id, pinned_id);

        let reloaded = ClipboardExtension::new(Some(store_path.clone()), Some(key));
        assert_eq!(reloaded.entries().len(), 1);
        assert_eq!(reloaded.entries()[0].payload, b"PINNED_SECRET_TOKEN_XYZ");

        // `clipboard-clear --all` removes pinned item too.
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_ipc("clipboard-clear", &["--all".into()], &mut ctx);
        }
        assert!(ext.entries().is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
