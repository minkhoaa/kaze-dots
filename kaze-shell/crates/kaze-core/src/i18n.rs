use std::env;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum Locale {
    #[default]
    En,
    Vi,
}

impl Locale {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::En => "en",
            Self::Vi => "vi",
        }
    }

    pub fn from_code(raw: &str) -> Option<Self> {
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            return None;
        }
        let base = trimmed
            .split(['.', '@', '_', '-'])
            .next()
            .unwrap_or("")
            .to_ascii_lowercase();
        match base.as_str() {
            "en" => Some(Self::En),
            "vi" => Some(Self::Vi),
            _ => None,
        }
    }

    pub fn resolve(config_locale: &str) -> Self {
        let lc_all = env::var("LC_ALL").ok();
        let lc_msg = env::var("LC_MESSAGES").ok();
        let lang = env::var("LANG").ok();
        Self::resolve_from(
            config_locale,
            lc_all.as_deref(),
            lc_msg.as_deref(),
            lang.as_deref(),
        )
    }

    pub fn resolve_from(
        config_locale: &str,
        lc_all: Option<&str>,
        lc_messages: Option<&str>,
        lang: Option<&str>,
    ) -> Self {
        for candidate in [
            Some(config_locale),
            lc_all,
            lc_messages,
            lang,
        ]
        .into_iter()
        .flatten()
        {
            let c = candidate.trim();
            if c.is_empty() || c.eq_ignore_ascii_case("C") || c.eq_ignore_ascii_case("POSIX") {
                continue;
            }
            if let Some(loc) = Self::from_code(c) {
                return loc;
            }
            // Explicit unsupported locale tag (e.g. `xx_YY`) falls back gracefully to `En`.
            return Self::En;
        }
        Self::En
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum I18nKey {
    ControlCenterTitle,
    QuickWifi,
    QuickBluetooth,
    QuickDnd,
    QuickNightLight,
    QuickCaffeine,
    QuickTheme,
    StateOn,
    StateOff,
    StateDark,
    StateLight,
    StateUnavailable,
    VolumeLabel,
    BrightnessLabel,
    OpLayout,
    OpDisplay,
    OpRecord,
    OpSettings,
    NotificationsHeader,
    NotificationsClearAll,
    NotificationsEmpty,
    PowerLock,
    PowerSuspend,
    PowerHibernate,
    PowerLogout,
    PowerReboot,
    PowerRebootUefi,
    PowerShutdown,
    ConfirmPrompt,
    LauncherPromptApps,
    LauncherPromptClip,
    LauncherPlaceholderApps,
    LauncherPlaceholderFilter,
    LauncherPlaceholderClip,
    LauncherNoMatches,
    ClipboardEmpty,
    ClipboardPinned,
    PolkitAuthenticate,
    PolkitCancel,
    PolkitCapsLock,
    LockUnlocking,
    LockWrongPassword,
    LockPasswordPlaceholder,
    SessionMenuTitle,
    CaptureHint,
    AnnotateSaved,
    ColorCopied,
}

impl I18nKey {
    pub const ALL: &'static [Self] = &[
        Self::ControlCenterTitle,
        Self::QuickWifi,
        Self::QuickBluetooth,
        Self::QuickDnd,
        Self::QuickNightLight,
        Self::QuickCaffeine,
        Self::QuickTheme,
        Self::StateOn,
        Self::StateOff,
        Self::StateDark,
        Self::StateLight,
        Self::StateUnavailable,
        Self::VolumeLabel,
        Self::BrightnessLabel,
        Self::OpLayout,
        Self::OpDisplay,
        Self::OpRecord,
        Self::OpSettings,
        Self::NotificationsHeader,
        Self::NotificationsClearAll,
        Self::NotificationsEmpty,
        Self::PowerLock,
        Self::PowerSuspend,
        Self::PowerHibernate,
        Self::PowerLogout,
        Self::PowerReboot,
        Self::PowerRebootUefi,
        Self::PowerShutdown,
        Self::ConfirmPrompt,
        Self::LauncherPromptApps,
        Self::LauncherPromptClip,
        Self::LauncherPlaceholderApps,
        Self::LauncherPlaceholderFilter,
        Self::LauncherPlaceholderClip,
        Self::LauncherNoMatches,
        Self::ClipboardEmpty,
        Self::ClipboardPinned,
        Self::PolkitAuthenticate,
        Self::PolkitCancel,
        Self::PolkitCapsLock,
        Self::LockUnlocking,
        Self::LockWrongPassword,
        Self::LockPasswordPlaceholder,
        Self::SessionMenuTitle,
        Self::CaptureHint,
        Self::AnnotateSaved,
        Self::ColorCopied,
    ];
}

pub fn t(locale: Locale, key: I18nKey) -> &'static str {
    match (locale, key) {
        (Locale::En, I18nKey::ControlCenterTitle) => "CONTROL CENTER",
        (Locale::Vi, I18nKey::ControlCenterTitle) => "TRUNG TÂM ĐIỀU KHIỂN",
        (Locale::En, I18nKey::QuickWifi) => "Wi-Fi",
        (Locale::Vi, I18nKey::QuickWifi) => "Wi-Fi",
        (Locale::En, I18nKey::QuickBluetooth) => "Bluetooth",
        (Locale::Vi, I18nKey::QuickBluetooth) => "Bluetooth",
        (Locale::En, I18nKey::QuickDnd) => "Do Not Disturb",
        (Locale::Vi, I18nKey::QuickDnd) => "Không làm phiền",
        (Locale::En, I18nKey::QuickNightLight) => "Night Light",
        (Locale::Vi, I18nKey::QuickNightLight) => "Ánh sáng đêm",
        (Locale::En, I18nKey::QuickCaffeine) => "Caffeine",
        (Locale::Vi, I18nKey::QuickCaffeine) => "Giữ màn hình",
        (Locale::En, I18nKey::QuickTheme) => "Theme",
        (Locale::Vi, I18nKey::QuickTheme) => "Giao diện",
        (Locale::En, I18nKey::StateOn) => "On",
        (Locale::Vi, I18nKey::StateOn) => "Bật",
        (Locale::En, I18nKey::StateOff) => "Off",
        (Locale::Vi, I18nKey::StateOff) => "Tắt",
        (Locale::En, I18nKey::StateDark) => "Dark",
        (Locale::Vi, I18nKey::StateDark) => "Tối",
        (Locale::En, I18nKey::StateLight) => "Light",
        (Locale::Vi, I18nKey::StateLight) => "Sáng",
        (Locale::En, I18nKey::StateUnavailable) => "N/A",
        (Locale::Vi, I18nKey::StateUnavailable) => "Không có",
        (Locale::En, I18nKey::VolumeLabel) => "Volume",
        (Locale::Vi, I18nKey::VolumeLabel) => "Âm lượng",
        (Locale::En, I18nKey::BrightnessLabel) => "Brightness",
        (Locale::Vi, I18nKey::BrightnessLabel) => "Độ sáng",
        (Locale::En, I18nKey::OpLayout) => "Layout",
        (Locale::Vi, I18nKey::OpLayout) => "Bố cục",
        (Locale::En, I18nKey::OpDisplay) => "Display",
        (Locale::Vi, I18nKey::OpDisplay) => "Màn hình",
        (Locale::En, I18nKey::OpRecord) => "Record",
        (Locale::Vi, I18nKey::OpRecord) => "Ghi hình",
        (Locale::En, I18nKey::OpSettings) => "Settings",
        (Locale::Vi, I18nKey::OpSettings) => "Cài đặt",
        (Locale::En, I18nKey::NotificationsHeader) => "Notifications",
        (Locale::Vi, I18nKey::NotificationsHeader) => "Thông báo",
        (Locale::En, I18nKey::NotificationsClearAll) => "Clear All",
        (Locale::Vi, I18nKey::NotificationsClearAll) => "Xóa tất cả",
        (Locale::En, I18nKey::NotificationsEmpty) => "No notifications",
        (Locale::Vi, I18nKey::NotificationsEmpty) => "Không có thông báo",
        (Locale::En, I18nKey::PowerLock) => "Lock",
        (Locale::Vi, I18nKey::PowerLock) => "Khóa",
        (Locale::En, I18nKey::PowerSuspend) => "Suspend",
        (Locale::Vi, I18nKey::PowerSuspend) => "Ngủ",
        (Locale::En, I18nKey::PowerHibernate) => "Hibernate",
        (Locale::Vi, I18nKey::PowerHibernate) => "Ngủ đông",
        (Locale::En, I18nKey::PowerLogout) => "Logout",
        (Locale::Vi, I18nKey::PowerLogout) => "Đăng xuất",
        (Locale::En, I18nKey::PowerReboot) => "Reboot",
        (Locale::Vi, I18nKey::PowerReboot) => "Khởi động lại",
        (Locale::En, I18nKey::PowerRebootUefi) => "Reboot to UEFI",
        (Locale::Vi, I18nKey::PowerRebootUefi) => "Vào UEFI",
        (Locale::En, I18nKey::PowerShutdown) => "Shutdown",
        (Locale::Vi, I18nKey::PowerShutdown) => "Tắt máy",
        (Locale::En, I18nKey::ConfirmPrompt) => "Click again to confirm",
        (Locale::Vi, I18nKey::ConfirmPrompt) => "Bấm lần nữa để xác nhận",
        (Locale::En, I18nKey::LauncherPromptApps) => "Apps > ",
        (Locale::Vi, I18nKey::LauncherPromptApps) => "Ứng dụng > ",
        (Locale::En, I18nKey::LauncherPromptClip) => "Clip > ",
        (Locale::Vi, I18nKey::LauncherPromptClip) => "Nhớ tạm > ",
        (Locale::En, I18nKey::LauncherPlaceholderApps) => "Type to launch (= calc, /emoji, /pan, /wall)...",
        (Locale::Vi, I18nKey::LauncherPlaceholderApps) => "Gõ để mở (= tính toán, /emoji, /pan, /wall)...",
        (Locale::En, I18nKey::LauncherPlaceholderFilter) => "Type to filter...",
        (Locale::Vi, I18nKey::LauncherPlaceholderFilter) => "Gõ để lọc...",
        (Locale::En, I18nKey::LauncherPlaceholderClip) => "Filter clipboard (Shift+Del removes)...",
        (Locale::Vi, I18nKey::LauncherPlaceholderClip) => "Lọc bộ nhớ tạm (Shift+Del xóa)...",
        (Locale::En, I18nKey::LauncherNoMatches) => "No matches",
        (Locale::Vi, I18nKey::LauncherNoMatches) => "Không tìm thấy kết quả",
        (Locale::En, I18nKey::ClipboardEmpty) => "Clipboard history is empty",
        (Locale::Vi, I18nKey::ClipboardEmpty) => "Lịch sử bộ nhớ tạm trống",
        (Locale::En, I18nKey::ClipboardPinned) => "Pinned",
        (Locale::Vi, I18nKey::ClipboardPinned) => "Đã ghim",
        (Locale::En, I18nKey::PolkitAuthenticate) => "Authenticate",
        (Locale::Vi, I18nKey::PolkitAuthenticate) => "Xác thực",
        (Locale::En, I18nKey::PolkitCancel) => "Cancel",
        (Locale::Vi, I18nKey::PolkitCancel) => "Hủy",
        (Locale::En, I18nKey::PolkitCapsLock) => "Caps Lock is ON",
        (Locale::Vi, I18nKey::PolkitCapsLock) => "Đang bật Caps Lock",
        (Locale::En, I18nKey::LockUnlocking) => "Verifying...",
        (Locale::Vi, I18nKey::LockUnlocking) => "Đang xác thực...",
        (Locale::En, I18nKey::LockWrongPassword) => "Authentication failed",
        (Locale::Vi, I18nKey::LockWrongPassword) => "Sai mật khẩu",
        (Locale::En, I18nKey::LockPasswordPlaceholder) => "Password...",
        (Locale::Vi, I18nKey::LockPasswordPlaceholder) => "Mật khẩu...",
        (Locale::En, I18nKey::SessionMenuTitle) => "Session",
        (Locale::Vi, I18nKey::SessionMenuTitle) => "Phiên làm việc",
        (Locale::En, I18nKey::CaptureHint) => "Drag to select · Enter confirm · Esc cancel",
        (Locale::Vi, I18nKey::CaptureHint) => "Kéo để chọn · Enter xác nhận · Esc hủy",
        (Locale::En, I18nKey::AnnotateSaved) => "Screenshot saved",
        (Locale::Vi, I18nKey::AnnotateSaved) => "Đã lưu ảnh chụp",
        (Locale::En, I18nKey::ColorCopied) => "Color copied",
        (Locale::Vi, I18nKey::ColorCopied) => "Đã chép mã màu",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn all_keys_have_non_empty_en_and_vi_translations() {
        for &key in I18nKey::ALL {
            assert!(!t(Locale::En, key).trim().is_empty(), "empty En for {key:?}");
            assert!(!t(Locale::Vi, key).trim().is_empty(), "empty Vi for {key:?}");
        }
    }

    #[test]
    fn locale_resolution_precedence_and_unknown_fallback() {
        assert_eq!(
            Locale::resolve_from("vi_VN.UTF-8", Some("en_US.UTF-8"), None, None),
            Locale::Vi
        );
        assert_eq!(
            Locale::resolve_from("", Some("vi_VN.UTF-8"), Some("en_US.UTF-8"), None),
            Locale::Vi
        );
        assert_eq!(
            Locale::resolve_from("", Some("C"), Some("vi"), Some("en_US.UTF-8")),
            Locale::Vi
        );
        assert_eq!(
            Locale::resolve_from("xx_YY", Some("vi_VN.UTF-8"), None, None),
            Locale::En
        );
    }
}
