use calloop::channel::Sender as CalloopSender;
use kaze_core::{SystemEvent, UserAccountState};
use std::env;
use std::path::PathBuf;
use zbus::{Connection, Proxy};

const ACCOUNTS_DEST: &str = "org.freedesktop.Accounts";
const ACCOUNTS_USER_IFACE: &str = "org.freedesktop.Accounts.User";

/// Queries `org.freedesktop.Accounts` (`/org/freedesktop/Accounts/User<UID>`) for
/// `IconFile`, `RealName`, and `UserName`, falling back cleanly to `~/.face` and initials.
pub async fn run_accounts_task(conn: Option<Connection>, event_tx: CalloopSender<SystemEvent>) {
    // SAFETY: `getuid` has no preconditions and always succeeds.
    let uid = unsafe { libc::getuid() };
    let fallback_user = env::var("USER").unwrap_or_else(|_| "user".to_string());
    let home = env::var_os("HOME").map(PathBuf::from);

    let state = if let Some(ref c) = conn {
        query_accounts_service(c, uid, &fallback_user, home.as_deref()).await
    } else {
        resolve_account_fallback(None, &fallback_user, &fallback_user, home.as_deref())
    };
    let _ = event_tx.send(SystemEvent::UserAccountChanged(state));
}

async fn query_accounts_service(
    conn: &Connection,
    uid: u32,
    fallback_user: &str,
    home: Option<&std::path::Path>,
) -> UserAccountState {
    let path = format!("/org/freedesktop/Accounts/User{uid}");
    let Ok(proxy) = Proxy::new(conn, ACCOUNTS_DEST, path.as_str(), ACCOUNTS_USER_IFACE).await
    else {
        return resolve_account_fallback(None, fallback_user, fallback_user, home);
    };

    let username = proxy
        .get_property::<String>("UserName")
        .await
        .ok()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| fallback_user.to_string());
    let real_name = proxy
        .get_property::<String>("RealName")
        .await
        .ok()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| username.clone());
    let icon_file = proxy.get_property::<String>("IconFile").await.ok();

    resolve_account_fallback(icon_file.as_deref(), &username, &real_name, home)
}

pub fn resolve_account_fallback(
    accounts_icon: Option<&str>,
    username: &str,
    real_name: &str,
    home: Option<&std::path::Path>,
) -> UserAccountState {
    let mut state = UserAccountState::from_username(username, real_name);
    if let Some(icon) = accounts_icon.map(str::trim).filter(|s| !s.is_empty()) {
        let p = PathBuf::from(icon);
        if p.is_file() {
            state.icon_path = Some(p);
            return state;
        }
    }
    if let Some(h) = home {
        let face = h.join(".face");
        if face.is_file() {
            state.icon_path = Some(face);
        }
    }
    state
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accounts_fallback_prefers_accounts_icon_then_dot_face_then_initials() {
        let dir = std::env::temp_dir().join(format!("kaze-acct-fb-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("mkdir");

        let acct_icon = dir.join("avatar.png");
        let face_icon = dir.join(".face");
        std::fs::write(&acct_icon, b"png").expect("write acct");
        std::fs::write(&face_icon, b"face").expect("write face");

        let s1 = resolve_account_fallback(acct_icon.to_str(), "khoa", "Khoa Nguyen", Some(&dir));
        assert_eq!(s1.icon_path.as_deref(), Some(acct_icon.as_path()));
        assert_eq!(s1.initials, "KN");

        let s2 = resolve_account_fallback(
            Some("/nonexistent/icon.png"),
            "khoa",
            "Khoa Nguyen",
            Some(&dir),
        );
        assert_eq!(s2.icon_path.as_deref(), Some(face_icon.as_path()));

        let _ = std::fs::remove_file(&face_icon);
        let s3 = resolve_account_fallback(None, "khoa", "Khoa", Some(&dir));
        assert_eq!(s3.icon_path, None);
        assert_eq!(s3.initials, "K");

        let _ = std::fs::remove_dir_all(&dir);
    }
}
