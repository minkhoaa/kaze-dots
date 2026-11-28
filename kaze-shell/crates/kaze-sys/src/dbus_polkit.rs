#![deny(clippy::unwrap_used)]

use calloop::channel::Sender as CalloopSender;
use kaze_core::{PolkitRequest, SystemEvent};
use std::collections::{HashMap, VecDeque};
use std::ffi::CStr;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, Command};
use tokio::sync::{mpsc, oneshot, Mutex};
use zbus::zvariant::{OwnedObjectPath, OwnedValue, Value};
use zbus::{Connection, Proxy};
use zeroize::Zeroizing;

const AGENT_OBJECT_PATH: &str = "/org/kaze/PolicyKit1/AuthenticationAgent";
const AUTHORITY_DEST: &str = "org.freedesktop.PolicyKit1";
const AUTHORITY_PATH: &str = "/org/freedesktop/PolicyKit1/Authority";
const AUTHORITY_IFACE: &str = "org.freedesktop.PolicyKit1.Authority";
const DEFAULT_HELPER_PATH: &str = "/usr/lib/polkit-1/polkit-agent-helper-1";

#[derive(Debug, zbus::DBusError)]
#[zbus(prefix = "org.freedesktop.PolicyKit1.Error")]
pub enum PolkitDBusError {
    #[zbus(error)]
    ZBus(zbus::Error),
    Cancelled(String),
    Failed(String),
}

pub enum PolkitCmd {
    SubmitPassword {
        cookie: String,
        user: String,
        password: Zeroizing<String>,
    },
    Cancel {
        cookie: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HelperLine {
    Prompt { msg: String, echo: bool },
    Error(String),
    Info(String),
    Success,
    Failure,
    Unknown,
}

pub fn parse_helper_line(line: &str) -> HelperLine {
    let trimmed = line.trim_end_matches(['\r', '\n']);
    if let Some(rest) = trimmed.strip_prefix("PAM_PROMPT_ECHO_OFF") {
        return HelperLine::Prompt {
            msg: rest.trim().to_string(),
            echo: false,
        };
    }
    if let Some(rest) = trimmed.strip_prefix("PAM_PROMPT_ECHO_ON") {
        return HelperLine::Prompt {
            msg: rest.trim().to_string(),
            echo: true,
        };
    }
    if let Some(rest) = trimmed.strip_prefix("PAM_ERROR_MSG") {
        return HelperLine::Error(rest.trim().to_string());
    }
    if let Some(rest) = trimmed.strip_prefix("PAM_TEXT_INFO") {
        return HelperLine::Info(rest.trim().to_string());
    }
    if trimmed == "SUCCESS" {
        return HelperLine::Success;
    }
    if trimmed == "FAILURE" {
        return HelperLine::Failure;
    }
    HelperLine::Unknown
}

fn resolve_uid_username(uid: u32) -> Option<String> {
    // SAFETY: `getpwuid` returns pointer to static passwd entry or null; immediately copied out.
    unsafe {
        let pw = libc::getpwuid(uid);
        if !pw.is_null() && !(*pw).pw_name.is_null() {
            if let Ok(name) = CStr::from_ptr((*pw).pw_name).to_str() {
                if !name.is_empty() {
                    return Some(name.to_string());
                }
            }
        }
    }
    None
}

pub fn extract_identities(identities: &[(String, HashMap<String, OwnedValue>)]) -> Vec<String> {
    let mut out = Vec::new();
    for (kind, details) in identities {
        if kind != "unix-user" {
            continue;
        }
        if let Some(val) = details.get("uid") {
            let uid = u32::try_from(val.clone()).ok().or_else(|| {
                i32::try_from(val.clone())
                    .ok()
                    .and_then(|v| u32::try_from(v).ok())
            });
            if let Some(u) = uid {
                if let Some(name) = resolve_uid_username(u) {
                    if !out.contains(&name) {
                        out.push(name);
                    }
                    continue;
                }
            }
        }
        if let Some(val) = details.get("name") {
            if let Ok(name) = String::try_from(val.clone()) {
                if !name.is_empty() && !out.contains(&name) {
                    out.push(name);
                }
            }
        }
    }
    if out.is_empty() {
        if let Ok(u) = std::env::var("USER") {
            if !u.is_empty() {
                out.push(u);
            }
        }
    }
    out
}

enum InternalMsg {
    Begin {
        request: PolkitRequest,
        reply: oneshot::Sender<Result<(), PolkitDBusError>>,
    },
    DbusCancel {
        cookie: String,
    },
}

struct PolkitAgentInterface {
    tx: mpsc::UnboundedSender<InternalMsg>,
}

#[zbus::interface(name = "org.freedesktop.PolicyKit1.AuthenticationAgent")]
impl PolkitAgentInterface {
    async fn begin_authentication(
        &self,
        action_id: String,
        message: String,
        icon_name: String,
        details: HashMap<String, String>,
        cookie: String,
        identities: Vec<(String, HashMap<String, OwnedValue>)>,
    ) -> Result<(), PolkitDBusError> {
        let mut sorted_details: Vec<(String, String)> = details.into_iter().collect();
        sorted_details.sort_by(|a, b| a.0.cmp(&b.0));
        let request = PolkitRequest {
            cookie,
            action_id,
            message,
            icon_name,
            identities: extract_identities(&identities),
            details: sorted_details,
        };
        let (reply_tx, reply_rx) = oneshot::channel();
        self.tx
            .send(InternalMsg::Begin {
                request,
                reply: reply_tx,
            })
            .map_err(|_| PolkitDBusError::Failed("Polkit agent stopped".into()))?;
        reply_rx
            .await
            .unwrap_or_else(|_| Err(PolkitDBusError::Cancelled("Authentication cancelled".into())))
    }

    async fn cancel_authentication(&self, cookie: String) -> zbus::fdo::Result<()> {
        let _ = self.tx.send(InternalMsg::DbusCancel { cookie });
        Ok(())
    }
}

async fn resolve_session_id(conn: &Connection) -> Option<String> {
    if let Ok(mgr) = Proxy::new(
        conn,
        "org.freedesktop.login1",
        "/org/freedesktop/login1",
        "org.freedesktop.login1.Manager",
    )
    .await
    {
        if let Ok(sess_path) = mgr
            .call::<_, _, OwnedObjectPath>("GetSessionByPID", &(std::process::id(),))
            .await
        {
            if let Ok(sess) = Proxy::new(
                conn,
                "org.freedesktop.login1",
                sess_path.as_str(),
                "org.freedesktop.login1.Session",
            )
            .await
            {
                if let Ok(id) = sess.get_property::<String>("Id").await {
                    if !id.is_empty() {
                        return Some(id);
                    }
                }
            }
        }
    }
    std::env::var("XDG_SESSION_ID")
        .ok()
        .filter(|s| !s.trim().is_empty())
}

struct PendingEntry {
    request: PolkitRequest,
    reply: oneshot::Sender<Result<(), PolkitDBusError>>,
}

struct ActiveHelper {
    cookie: String,
    child: Child,
    stdin: tokio::process::ChildStdin,
    prompt_received: bool,
    queued_password: Option<Zeroizing<String>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum HelperDone {
    Success,
    Failure,
}

async fn spawn_helper_process(
    helper_path: &Path,
    cookie: &str,
    user: &str,
) -> Result<(Child, tokio::process::ChildStdin, tokio::process::ChildStdout), String> {
    if !helper_path.exists() {
        return Err(format!("Helper missing: {}", helper_path.display()));
    }
    let mut cmd = Command::new(helper_path);
    cmd.arg(user)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    let mut child = cmd
        .spawn()
        .map_err(|e| format!("Failed spawning helper {}: {e}", helper_path.display()))?;
    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| "Helper stdin unavailable".to_string())?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| "Helper stdout unavailable".to_string())?;
    let line = format!("{cookie}\n");
    stdin
        .write_all(line.as_bytes())
        .await
        .map_err(|e| format!("Failed writing polkit cookie: {e}"))?;
    let _ = stdin.flush().await;
    Ok((child, stdin, stdout))
}

async fn send_password_to_helper(helper: &mut ActiveHelper, password: Zeroizing<String>) -> bool {
    let mut buf = Zeroizing::new(Vec::with_capacity(password.len() + 1));
    buf.extend_from_slice(password.as_bytes());
    buf.push(b'\n');
    helper.stdin.write_all(&buf).await.is_ok() && helper.stdin.flush().await.is_ok()
}

pub async fn run_polkit_task(
    sys_conn: Option<Connection>,
    event_tx: CalloopSender<SystemEvent>,
    cmd_rx: mpsc::UnboundedReceiver<PolkitCmd>,
) {
    let Some(conn) = sys_conn else {
        let _ = event_tx.send(SystemEvent::PolkitBusOwned(false));
        return;
    };
    let (internal_tx, internal_rx) = mpsc::unbounded_channel();
    let iface = PolkitAgentInterface { tx: internal_tx };
    if conn.object_server().at(AGENT_OBJECT_PATH, iface).await.is_err() {
        let _ = event_tx.send(SystemEvent::PolkitBusOwned(false));
        return;
    }

    let registered = register_with_authority(&conn).await;
    let _ = event_tx.send(SystemEvent::PolkitBusOwned(registered));

    run_polkit_coordinator(
        PathBuf::from(DEFAULT_HELPER_PATH),
        event_tx,
        cmd_rx,
        internal_rx,
    )
    .await;
}

async fn register_with_authority(conn: &Connection) -> bool {
    let Some(session_id) = resolve_session_id(conn).await else {
        return false;
    };
    let Ok(auth) = Proxy::new(conn, AUTHORITY_DEST, AUTHORITY_PATH, AUTHORITY_IFACE).await else {
        return false;
    };
    let mut subject_details: HashMap<&str, Value<'_>> = HashMap::new();
    subject_details.insert("session-id", Value::from(session_id));
    let subject = ("unix-session", subject_details);
    let locale = std::env::var("LANG").unwrap_or_else(|_| "en_US.UTF-8".to_string());
    auth.call::<_, _, ()>(
        "RegisterAuthenticationAgent",
        &(subject, locale, AGENT_OBJECT_PATH),
    )
    .await
    .is_ok()
}

async fn run_polkit_coordinator(
    helper_path: PathBuf,
    event_tx: CalloopSender<SystemEvent>,
    mut cmd_rx: mpsc::UnboundedReceiver<PolkitCmd>,
    mut internal_rx: mpsc::UnboundedReceiver<InternalMsg>,
) {
    let mut queue: VecDeque<PendingEntry> = VecDeque::new();
    let mut active: Option<PendingEntry> = None;
    let helper_slot: Arc<Mutex<Option<ActiveHelper>>> = Arc::new(Mutex::new(None));
    let (helper_evt_tx, mut helper_evt_rx) = mpsc::unbounded_channel::<(String, HelperDone)>();

    let activate_helper = |cookie: &str, user: &str, pw: Option<Zeroizing<String>>| {
        let h_path = helper_path.clone();
        let c_str = cookie.to_string();
        let u_str = user.to_string();
        let evt_tx = event_tx.clone();
        let done_tx = helper_evt_tx.clone();
        let slot = Arc::clone(&helper_slot);
        tokio::spawn(async move {
            match spawn_helper_process(&h_path, &c_str, &u_str).await {
                Ok((child, stdin, stdout)) => {
                    {
                        let mut guard = slot.lock().await;
                        *guard = Some(ActiveHelper {
                            cookie: c_str.clone(),
                            child,
                            stdin,
                            prompt_received: false,
                            queued_password: pw,
                        });
                    }
                    let mut lines = BufReader::new(stdout).lines();
                    let mut final_outcome = HelperDone::Failure;
                    while let Ok(Some(line)) = lines.next_line().await {
                        match parse_helper_line(&line) {
                            HelperLine::Prompt { msg, echo } => {
                                let mut guard = slot.lock().await;
                                if let Some(ref mut h) = *guard {
                                    if h.cookie == c_str {
                                        h.prompt_received = true;
                                        if let Some(pending_pw) = h.queued_password.take() {
                                            let _ = send_password_to_helper(h, pending_pw).await;
                                        }
                                    }
                                }
                                let _ = evt_tx.send(SystemEvent::PolkitPrompt {
                                    cookie: c_str.clone(),
                                    prompt: if msg.is_empty() {
                                        "Password".to_string()
                                    } else {
                                        msg
                                    },
                                    echo,
                                });
                            }
                            HelperLine::Error(msg) => {
                                let _ = evt_tx.send(SystemEvent::PolkitError {
                                    cookie: c_str.clone(),
                                    message: msg,
                                });
                            }
                            HelperLine::Info(_) => {}
                            HelperLine::Success => {
                                final_outcome = HelperDone::Success;
                                break;
                            }
                            HelperLine::Failure => {
                                final_outcome = HelperDone::Failure;
                                break;
                            }
                            HelperLine::Unknown => {}
                        }
                    }
                    {
                        let mut guard = slot.lock().await;
                        if let Some(mut h) = guard.take() {
                            if h.cookie == c_str {
                                let _ = h.child.wait().await;
                            } else {
                                *guard = Some(h);
                            }
                        }
                    }
                    let _ = done_tx.send((c_str, final_outcome));
                }
                Err(err) => {
                    let _ = evt_tx.send(SystemEvent::PolkitError {
                        cookie: c_str.clone(),
                        message: err,
                    });
                    let _ = done_tx.send((c_str, HelperDone::Failure));
                }
            }
        });
    };

    loop {
        tokio::select! {
            msg = internal_rx.recv() => {
                let Some(msg) = msg else { break; };
                match msg {
                    InternalMsg::Begin { request, reply } => {
                        let _ = event_tx.send(SystemEvent::PolkitBegin(request.clone()));
                        let entry = PendingEntry { request, reply };
                        if active.is_none() {
                            let c = entry.request.cookie.clone();
                            let u = entry.request.identities.first().cloned().unwrap_or_else(|| "root".into());
                            active = Some(entry);
                            activate_helper(&c, &u, None);
                        } else {
                            queue.push_back(entry);
                        }
                    }
                    InternalMsg::DbusCancel { cookie } => {
                        let _ = event_tx.send(SystemEvent::PolkitCancel { cookie: cookie.clone() });
                        if active.as_ref().is_some_and(|a| a.request.cookie == cookie) {
                            kill_active_helper(&helper_slot, &cookie).await;
                            if let Some(done) = active.take() {
                                let _ = done.reply.send(Err(PolkitDBusError::Cancelled("Cancelled".into())));
                            }
                            if let Some(next) = queue.pop_front() {
                                let c = next.request.cookie.clone();
                                let u = next.request.identities.first().cloned().unwrap_or_else(|| "root".into());
                                active = Some(next);
                                activate_helper(&c, &u, None);
                            }
                        } else {
                            cancel_in_queue(&mut queue, &cookie);
                        }
                    }
                }
            }
            cmd = cmd_rx.recv() => {
                let Some(cmd) = cmd else { break; };
                match cmd {
                    PolkitCmd::SubmitPassword { cookie, user, password } => {
                        if active.as_ref().is_some_and(|a| a.request.cookie == cookie) {
                            let mut guard = helper_slot.lock().await;
                            if let Some(ref mut h) = *guard {
                                if h.cookie == cookie {
                                    if h.prompt_received {
                                        let _ = send_password_to_helper(h, password).await;
                                    } else {
                                        h.queued_password = Some(password);
                                    }
                                    continue;
                                }
                            }
                            drop(guard);
                            activate_helper(&cookie, &user, Some(password));
                        }
                    }
                    PolkitCmd::Cancel { cookie } => {
                        if active.as_ref().is_some_and(|a| a.request.cookie == cookie) {
                            kill_active_helper(&helper_slot, &cookie).await;
                            if let Some(done) = active.take() {
                                let _ = done.reply.send(Err(PolkitDBusError::Cancelled("Cancelled by user".into())));
                            }
                            if let Some(next) = queue.pop_front() {
                                let c = next.request.cookie.clone();
                                let u = next.request.identities.first().cloned().unwrap_or_else(|| "root".into());
                                active = Some(next);
                                activate_helper(&c, &u, None);
                            }
                        } else {
                            cancel_in_queue(&mut queue, &cookie);
                        }
                    }
                }
            }
            res = helper_evt_rx.recv() => {
                let Some((cookie, outcome)) = res else { continue; };
                if !active.as_ref().is_some_and(|a| a.request.cookie == cookie) {
                    continue;
                }
                match outcome {
                    HelperDone::Success => {
                        if let Some(done) = active.take() {
                            let _ = done.reply.send(Ok(()));
                        }
                        let _ = event_tx.send(SystemEvent::PolkitComplete { cookie, success: true });
                        if let Some(next) = queue.pop_front() {
                            let c = next.request.cookie.clone();
                            let u = next.request.identities.first().cloned().unwrap_or_else(|| "root".into());
                            active = Some(next);
                            activate_helper(&c, &u, None);
                        }
                    }
                    HelperDone::Failure => {
                        let _ = event_tx.send(SystemEvent::PolkitComplete { cookie, success: false });
                    }
                }
            }
        }
    }
}

async fn kill_active_helper(slot: &Arc<Mutex<Option<ActiveHelper>>>, cookie: &str) {
    let mut guard = slot.lock().await;
    if let Some(mut h) = guard.take() {
        if h.cookie == cookie {
            let _ = h.child.kill().await;
            let _ = h.child.wait().await;
        } else {
            *guard = Some(h);
        }
    }
}

fn cancel_in_queue(queue: &mut VecDeque<PendingEntry>, cookie: &str) {
    let mut remaining = VecDeque::with_capacity(queue.len());
    while let Some(entry) = queue.pop_front() {
        if entry.request.cookie == cookie {
            let _ = entry
                .reply
                .send(Err(PolkitDBusError::Cancelled("Cancelled".into())));
        } else {
            remaining.push_back(entry);
        }
    }
    *queue = remaining;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_polkit_helper_protocol_lines_cleanly() {
        assert_eq!(
            parse_helper_line("PAM_PROMPT_ECHO_OFF Password: "),
            HelperLine::Prompt {
                msg: "Password:".into(),
                echo: false
            }
        );
        assert_eq!(
            parse_helper_line("PAM_PROMPT_ECHO_ON Username:"),
            HelperLine::Prompt {
                msg: "Username:".into(),
                echo: true
            }
        );
        assert_eq!(
            parse_helper_line("PAM_ERROR_MSG Authentication failure"),
            HelperLine::Error("Authentication failure".into())
        );
        assert_eq!(parse_helper_line("SUCCESS\n"), HelperLine::Success);
        assert_eq!(parse_helper_line("FAILURE\r\n"), HelperLine::Failure);
    }

    #[tokio::test]
    async fn missing_helper_emits_error_and_cancel_returns_cancelled() {
        let (ev_tx, ev_rx) = calloop::channel::channel();
        let (cmd_tx, cmd_rx) = mpsc::unbounded_channel();
        let (int_tx, int_rx) = mpsc::unbounded_channel();
        let handle = tokio::spawn(run_polkit_coordinator(
            PathBuf::from("/nonexistent/polkit-agent-helper-1"),
            ev_tx,
            cmd_rx,
            int_rx,
        ));

        let (reply_tx, reply_rx) = oneshot::channel();
        let _ = int_tx.send(InternalMsg::Begin {
            request: PolkitRequest {
                cookie: "cookie-1".into(),
                action_id: "org.freedesktop.policykit.exec".into(),
                message: "Auth".into(),
                icon_name: String::new(),
                identities: vec!["root".into()],
                details: Vec::new(),
            },
            reply: reply_tx,
        });

        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        let _ = cmd_tx.send(PolkitCmd::Cancel {
            cookie: "cookie-1".into(),
        });
        let res = reply_rx.await.expect("reply received");
        assert!(matches!(res, Err(PolkitDBusError::Cancelled(_))));
        drop(int_tx);
        drop(cmd_tx);
        let _ = handle.await;

        let mut events = Vec::new();
        while let Ok(ev) = ev_rx.try_recv() {
            events.push(ev);
        }
        assert!(events.iter().any(|e| matches!(e, SystemEvent::PolkitError { .. })));
    }
}
