use kaze_core::layout::xdg_state_home;
use kaze_core::theme::write_atomic;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy)]
pub struct EmojiEntry {
    pub glyph: &'static str,
    pub keywords: &'static str,
}

pub const BUILTIN_EMOJIS: &[EmojiEntry] = &[
    EmojiEntry { glyph: "😀", keywords: "grin smile happy vui cuoi" },
    EmojiEntry { glyph: "😂", keywords: "joy laugh tear cuoi ra nuoc mat haha" },
    EmojiEntry { glyph: "🥹", keywords: "grateful touched cam dong" },
    EmojiEntry { glyph: "😊", keywords: "blush smile friendly mim cuoi de thuong" },
    EmojiEntry { glyph: "😍", keywords: "heart eyes love yeu thich me" },
    EmojiEntry { glyph: "🥰", keywords: "love hearts yeu thuong am ap" },
    EmojiEntry { glyph: "😎", keywords: "cool sunglasses ngau kinh ram" },
    EmojiEntry { glyph: "🤔", keywords: "think hmm suy nghi ban khoan" },
    EmojiEntry { glyph: "🫡", keywords: "salute chao tuan lenh" },
    EmojiEntry { glyph: "😴", keywords: "sleep tired ngu buon ngu" },
    EmojiEntry { glyph: "😭", keywords: "cry sob khoc buon" },
    EmojiEntry { glyph: "😡", keywords: "angry mad gian du tuc" },
    EmojiEntry { glyph: "🤯", keywords: "mind blown shock bat ngo no nao" },
    EmojiEntry { glyph: "🥳", keywords: "party celebrate an mung sinh nhat" },
    EmojiEntry { glyph: "🙏", keywords: "pray thanks cam on xin chao" },
    EmojiEntry { glyph: "👍", keywords: "thumbs up ok like dong y tot" },
    EmojiEntry { glyph: "👎", keywords: "thumbs down no dislike khong thich" },
    EmojiEntry { glyph: "👏", keywords: "clap applause vo tay khen ngoi" },
    EmojiEntry { glyph: "🤝", keywords: "handshake deal bat tay hop tac" },
    EmojiEntry { glyph: "✌️", keywords: "peace victory chien thang" },
    EmojiEntry { glyph: "❤️", keywords: "red heart love trai tim yeu" },
    EmojiEntry { glyph: "💔", keywords: "broken heart that tinh tan vo" },
    EmojiEntry { glyph: "🔥", keywords: "fire hot lit lua chay nong" },
    EmojiEntry { glyph: "✨", keywords: "sparkles magic shine lap lanh" },
    EmojiEntry { glyph: "⭐", keywords: "star favorite ngoi sao yeu thich" },
    EmojiEntry { glyph: "🎉", keywords: "party popper confetti chuc mung" },
    EmojiEntry { glyph: "🚀", keywords: "rocket launch fast ten lua phong nhanh" },
    EmojiEntry { glyph: "⚡", keywords: "lightning flash fast power set nhanh dien" },
    EmojiEntry { glyph: "💡", keywords: "idea bulb light y tuong bong den" },
    EmojiEntry { glyph: "🔒", keywords: "lock security password khoa bao mat mat khau" },
    EmojiEntry { glyph: "🔓", keywords: "unlock mo khoa" },
    EmojiEntry { glyph: "🔑", keywords: "key chia khoa" },
    EmojiEntry { glyph: "💻", keywords: "laptop computer dev code may tinh lap trinh" },
    EmojiEntry { glyph: "🖥️", keywords: "desktop monitor man hinh" },
    EmojiEntry { glyph: "⌨️", keywords: "keyboard ban phim" },
    EmojiEntry { glyph: "🖱️", keywords: "mouse con chuot" },
    EmojiEntry { glyph: "📱", keywords: "phone mobile dien thoai" },
    EmojiEntry { glyph: "📷", keywords: "camera photo chup anh may anh" },
    EmojiEntry { glyph: "🎥", keywords: "video record camera quay phim" },
    EmojiEntry { glyph: "🎙️", keywords: "microphone mic audio micro thu am" },
    EmojiEntry { glyph: "🔊", keywords: "speaker volume sound loa am luong" },
    EmojiEntry { glyph: "🔇", keywords: "mute silence tat tieng im lang" },
    EmojiEntry { glyph: "🔔", keywords: "bell notification chuong thong bao" },
    EmojiEntry { glyph: "📋", keywords: "clipboard paste bang tam nho" },
    EmojiEntry { glyph: "📁", keywords: "folder directory thu muc" },
    EmojiEntry { glyph: "📄", keywords: "file document tap tin tai lieu" },
    EmojiEntry { glyph: "⚙️", keywords: "gear settings config cai dat cau hinh" },
    EmojiEntry { glyph: "🛠️", keywords: "tools wrench fix cong cu sua chua" },
    EmojiEntry { glyph: "🐛", keywords: "bug debug loi sau" },
    EmojiEntry { glyph: "✅", keywords: "check done pass hoan thanh dung xong" },
    EmojiEntry { glyph: "❌", keywords: "cross error wrong cancel sai loi huy" },
    EmojiEntry { glyph: "⚠️", keywords: "warning alert canh bao" },
    EmojiEntry { glyph: "☀️", keywords: "sun day light mat troi ngay nang" },
    EmojiEntry { glyph: "🌙", keywords: "moon night dark mat trang dem toi" },
    EmojiEntry { glyph: "🌧️", keywords: "rain weather mua thoi tiet" },
    EmojiEntry { glyph: "🌈", keywords: "rainbow cau vong" },
    EmojiEntry { glyph: "☕", keywords: "coffee caffeine ca phe" },
    EmojiEntry { glyph: "🍵", keywords: "tea matcha tra" },
    EmojiEntry { glyph: "🍜", keywords: "noodle pho ramen mi bun" },
    EmojiEntry { glyph: "🍕", keywords: "pizza food banh" },
    EmojiEntry { glyph: "🎧", keywords: "headphones music tai nghe nhac" },
    EmojiEntry { glyph: "🎵", keywords: "music note am nhac" },
    EmojiEntry { glyph: "🎮", keywords: "game controller tro choi" },
    EmojiEntry { glyph: "🇻🇳", keywords: "vietnam flag co viet nam" },
    EmojiEntry { glyph: "👨‍👩‍👧‍👦", keywords: "family parents children gia dinh" },
];

pub fn recent_emoji_path() -> Option<PathBuf> {
    xdg_state_home().ok().map(|d| d.join("recent_emoji.toml"))
}

pub fn load_recent_emojis(path: &Path) -> Vec<String> {
    let Ok(raw) = fs::read_to_string(path) else {
        return Vec::new();
    };
    #[derive(serde::Deserialize)]
    struct RecentDoc {
        #[serde(default)]
        recent: Vec<String>,
    }
    toml::from_str::<RecentDoc>(&raw)
        .map(|d| d.recent)
        .unwrap_or_default()
}

pub fn record_recent_emoji(path: &Path, glyph: &str) {
    let mut recent = load_recent_emojis(path);
    recent.retain(|g| g != glyph);
    recent.insert(0, glyph.to_string());
    recent.truncate(24);
    let quoted: Vec<String> = recent
        .iter()
        .map(|g| format!("\"{}\"", g.escape_default()))
        .collect();
    let body = format!("recent = [{}]\n", quoted.join(", "));
    let _ = write_atomic(path, &body);
}

pub fn search_emojis(query: &str, recent: &[String]) -> Vec<(&'static EmojiEntry, i32)> {
    let q = query.trim().to_ascii_lowercase();
    let mut results = Vec::new();
    for entry in BUILTIN_EMOJIS {
        let recent_bonus = recent
            .iter()
            .position(|g| g == entry.glyph)
            .map(|pos| 1000 - (pos as i32) * 10)
            .unwrap_or(0);
        if q.is_empty() {
            results.push((entry, recent_bonus));
            continue;
        }
        let tokens_match = q.split_whitespace().all(|tok| {
            entry.keywords.to_ascii_lowercase().contains(tok) || entry.glyph == tok
        });
        if tokens_match {
            let prefix_bonus = if entry
                .keywords
                .split_whitespace()
                .any(|w| w.starts_with(&q))
            {
                200
            } else {
                0
            };
            results.push((entry, recent_bonus + prefix_bonus + 50));
        }
    }
    results.sort_by_key(|a| std::cmp::Reverse(a.1));
    results
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn searches_english_and_vietnamese_keywords_and_recent_first() {
        let res = search_emojis("lua", &[]);
        assert!(res.iter().any(|(e, _)| e.glyph == "🔥"));

        let res_en = search_emojis("rocket", &[]);
        assert!(res_en.iter().any(|(e, _)| e.glyph == "🚀"));

        let res_recent = search_emojis("", &["☕".to_string()]);
        assert_eq!(res_recent.first().map(|(e, _)| e.glyph), Some("☕"));
    }
}
