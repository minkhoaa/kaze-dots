use std::env;
use std::process::Stdio;
use std::time::Duration;
use tokio::process::Command;

const MAX_HOOK_DEPTH: u32 = 3;

#[derive(Debug, Clone)]
pub struct HookRequest {
    pub command: String,
    pub timeout_secs: u64,
    pub event: String,
    pub old: Option<String>,
    pub new: Option<String>,
    pub value: Option<String>,
}

/// Runs a lifecycle hook asynchronously in its own process group (`setpgid(0, 0)`),
/// enforces `KAZE_HOOK_DEPTH < 3` against infinite recursion, and kills+reaps the
/// process group if it exceeds `timeout_secs` (leaving zero zombie processes).
pub async fn run_hook(req: HookRequest) {
    let cur_depth = env::var("KAZE_HOOK_DEPTH")
        .ok()
        .and_then(|s| s.parse::<u32>().ok())
        .unwrap_or(0);
    if cur_depth >= MAX_HOOK_DEPTH {
        eprintln!(
            "kaze-sys: skipping hook '{}' (KAZE_HOOK_DEPTH={} >= {MAX_HOOK_DEPTH})",
            req.event, cur_depth
        );
        return;
    }

    let mut cmd = Command::new("sh");
    cmd.args(["-c", &req.command])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .env("KAZE_HOOK_EVENT", &req.event)
        .env("KAZE_HOOK_DEPTH", (cur_depth + 1).to_string());
    if let Some(ref old) = req.old {
        cmd.env("KAZE_HOOK_OLD", old);
    }
    if let Some(ref new) = req.new {
        cmd.env("KAZE_HOOK_NEW", new);
    }
    if let Some(ref val) = req.value {
        cmd.env("KAZE_HOOK_VALUE", val);
    }

    // SAFETY: `setpgid(0, 0)` is async-signal-safe and isolates the hook process group
    // so a timeout cleanly kills all grandchild processes spawned by `sh -c`.
    unsafe {
        cmd.pre_exec(|| {
            libc::setpgid(0, 0);
            Ok(())
        });
    }

    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(err) => {
            eprintln!("kaze-sys: failed spawning hook '{}': {err}", req.event);
            return;
        }
    };

    let timeout = Duration::from_secs(req.timeout_secs.max(1));
    match tokio::time::timeout(timeout, child.wait()).await {
        Ok(Ok(_status)) => {}
        Ok(Err(err)) => {
            eprintln!("kaze-sys: hook '{}' wait error: {err}", req.event);
        }
        Err(_) => {
            if let Some(pid) = child.id() {
                if let Ok(pgid) = libc::pid_t::try_from(pid) {
                    // SAFETY: `pgid > 0` targets the isolated hook process group only.
                    unsafe {
                        libc::kill(-pgid, libc::SIGKILL);
                    }
                }
            }
            let _ = child.wait().await;
            eprintln!(
                "kaze-sys: hook '{}' timed out after {}s and was terminated",
                req.event,
                timeout.as_secs()
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test(flavor = "current_thread")]
    async fn hook_timeout_kills_and_reaps_without_blocking() {
        let start = std::time::Instant::now();
        run_hook(HookRequest {
            command: "sleep 30".into(),
            timeout_secs: 1,
            event: "started".into(),
            old: None,
            new: None,
            value: None,
        })
        .await;
        assert!(start.elapsed() < Duration::from_secs(4));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn hook_non_zero_exit_and_env_payload_complete_cleanly() {
        let marker = std::env::temp_dir().join(format!("kaze-hook-env-{}", std::process::id()));
        let _ = std::fs::remove_file(&marker);
        let cmd = format!(
            "printf '%s|%s|%s|%s|%s' \"$KAZE_HOOK_EVENT\" \"$KAZE_HOOK_OLD\" \"$KAZE_HOOK_NEW\" \"$KAZE_HOOK_VALUE\" \"$KAZE_HOOK_DEPTH\" > '{}'; exit 1",
            marker.display()
        );
        run_hook(HookRequest {
            command: cmd,
            timeout_secs: 5,
            event: "theme_mode_changed".into(),
            old: Some("dark".into()),
            new: Some("light".into()),
            value: Some("light".into()),
        })
        .await;
        let recorded = std::fs::read_to_string(&marker).expect("hook marker");
        assert_eq!(recorded, "theme_mode_changed|dark|light|light|1");
        let _ = std::fs::remove_file(&marker);
    }
}
