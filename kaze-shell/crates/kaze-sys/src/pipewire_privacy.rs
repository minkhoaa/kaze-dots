use calloop::channel::Sender as CalloopSender;
use kaze_core::{PrivacyState, SystemEvent};
use std::collections::{BTreeSet, HashMap};
use std::env;
use std::io;
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream as StdUnixStream;
use std::path::PathBuf;
use std::time::Duration;
use tokio::io::unix::AsyncFd;

const PW_CORE_ID: u32 = 0;
const PW_REGISTRY_ID: u32 = 2;

const PW_CORE_METHOD_HELLO: u8 = 1;
const PW_CORE_METHOD_PONG: u8 = 3;
const PW_CORE_METHOD_GET_REGISTRY: u8 = 5;

const PW_CORE_EVENT_PING: u8 = 2;
const PW_REGISTRY_EVENT_GLOBAL: u8 = 0;
const PW_REGISTRY_EVENT_GLOBAL_REMOVE: u8 = 1;

const SPA_TYPE_NONE: u32 = 1;
const SPA_TYPE_BOOL: u32 = 2;
const SPA_TYPE_ID: u32 = 3;
const SPA_TYPE_INT: u32 = 4;
const SPA_TYPE_LONG: u32 = 5;
const SPA_TYPE_FLOAT: u32 = 6;
const SPA_TYPE_DOUBLE: u32 = 7;
const SPA_TYPE_STRING: u32 = 8;
const SPA_TYPE_BYTES: u32 = 9;
const SPA_TYPE_RECTANGLE: u32 = 10;
const SPA_TYPE_FRACTION: u32 = 11;
const SPA_TYPE_BITMAP: u32 = 12;
const SPA_TYPE_ARRAY: u32 = 13;
const SPA_TYPE_STRUCT: u32 = 14;
const SPA_TYPE_OBJECT: u32 = 15;
const SPA_TYPE_POD: u32 = 17;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PodVal {
    None,
    Bool(bool),
    Int(i32),
    Long(i64),
    String(String),
    Struct(Vec<PodVal>),
    Other,
}

fn align8(n: usize) -> usize {
    (n + 7) & !7
}

fn build_pw_message(id: u32, opcode: u8, seq: u32, payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(16 + payload.len());
    out.extend_from_slice(&id.to_le_bytes());
    let op_sz = (u32::from(opcode) << 24) | ((payload.len() as u32) & 0x00ff_ffff);
    out.extend_from_slice(&op_sz.to_le_bytes());
    out.extend_from_slice(&seq.to_le_bytes());
    out.extend_from_slice(&0u32.to_le_bytes());
    out.extend_from_slice(payload);
    out
}

fn build_pod_struct(fields: &[Vec<u8>]) -> Vec<u8> {
    let mut body = Vec::new();
    for f in fields {
        body.extend_from_slice(f);
    }
    let mut out = Vec::with_capacity(8 + body.len());
    out.extend_from_slice(&(body.len() as u32).to_le_bytes());
    out.extend_from_slice(&SPA_TYPE_STRUCT.to_le_bytes());
    out.extend_from_slice(&body);
    out
}

fn pod_int(v: i32) -> Vec<u8> {
    let mut out = Vec::with_capacity(16);
    out.extend_from_slice(&4u32.to_le_bytes());
    out.extend_from_slice(&SPA_TYPE_INT.to_le_bytes());
    out.extend_from_slice(&v.to_le_bytes());
    out.extend_from_slice(&0u32.to_le_bytes());
    out
}

pub fn build_hello_packet(seq: u32) -> Vec<u8> {
    let payload = build_pod_struct(&[pod_int(3)]);
    build_pw_message(PW_CORE_ID, PW_CORE_METHOD_HELLO, seq, &payload)
}

pub fn build_get_registry_packet(seq: u32, new_id: u32) -> Vec<u8> {
    let payload = build_pod_struct(&[pod_int(3), pod_int(new_id as i32)]);
    build_pw_message(PW_CORE_ID, PW_CORE_METHOD_GET_REGISTRY, seq, &payload)
}

pub fn build_pong_packet(seq: u32, ping_id: i32, ping_seq: i32) -> Vec<u8> {
    let payload = build_pod_struct(&[pod_int(ping_id), pod_int(ping_seq)]);
    build_pw_message(PW_CORE_ID, PW_CORE_METHOD_PONG, seq, &payload)
}

pub fn parse_pod(buf: &[u8]) -> Option<(PodVal, usize)> {
    if buf.len() < 8 {
        return None;
    }
    let size = u32::from_le_bytes([buf[0], buf[1], buf[2], buf[3]]) as usize;
    let ty = u32::from_le_bytes([buf[4], buf[5], buf[6], buf[7]]);
    let body_end = 8usize.checked_add(size)?;
    if buf.len() < body_end {
        return None;
    }
    let total = align8(body_end).min(buf.len());
    let body = &buf[8..body_end];
    let val = match ty {
        SPA_TYPE_NONE => PodVal::None,
        SPA_TYPE_BOOL if body.len() >= 4 => {
            PodVal::Bool(u32::from_le_bytes([body[0], body[1], body[2], body[3]]) != 0)
        }
        SPA_TYPE_INT | SPA_TYPE_ID if body.len() >= 4 => {
            PodVal::Int(i32::from_le_bytes([body[0], body[1], body[2], body[3]]))
        }
        SPA_TYPE_LONG if body.len() >= 8 => PodVal::Long(i64::from_le_bytes([
            body[0], body[1], body[2], body[3], body[4], body[5], body[6], body[7],
        ])),
        SPA_TYPE_STRING => {
            let nul = body.iter().position(|&b| b == 0).unwrap_or(body.len());
            PodVal::String(String::from_utf8_lossy(&body[..nul]).into_owned())
        }
        SPA_TYPE_STRUCT => {
            let mut fields = Vec::new();
            let mut pos = 0usize;
            while pos + 8 <= body.len() {
                let Some((item, step)) = parse_pod(&body[pos..]) else {
                    break;
                };
                fields.push(item);
                pos += step.max(8);
            }
            PodVal::Struct(fields)
        }
        SPA_TYPE_FLOAT | SPA_TYPE_DOUBLE | SPA_TYPE_BYTES | SPA_TYPE_RECTANGLE
        | SPA_TYPE_FRACTION | SPA_TYPE_BITMAP | SPA_TYPE_ARRAY | SPA_TYPE_OBJECT | SPA_TYPE_POD => {
            PodVal::Other
        }
        _ => PodVal::Other,
    };
    Some((val, total))
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct TrackedNode {
    media_class: String,
    app_name: String,
    node_name: String,
}

#[derive(Default)]
struct PipewireNodeTracker {
    nodes: HashMap<u32, TrackedNode>,
}

impl PipewireNodeTracker {
    fn handle_global(&mut self, pod: &PodVal) -> bool {
        let PodVal::Struct(fields) = pod else {
            return false;
        };
        let Some(PodVal::Int(id)) = fields.first() else {
            return false;
        };
        let Some(PodVal::String(iface)) = fields.get(2) else {
            return false;
        };
        if iface != "PipeWire:Interface:Node" {
            return false;
        }
        // Props dict encoded as Struct([Int(n_items), String(k), String(v), ...]) in protocol-native.
        let mut media_class = String::new();
        let mut app_name = String::new();
        let mut node_name = String::new();
        if let Some(PodVal::Struct(props)) = fields.get(4) {
            let mut idx = 1usize;
            while idx + 1 < props.len() {
                if let (PodVal::String(k), PodVal::String(v)) = (&props[idx], &props[idx + 1]) {
                    match k.as_str() {
                        "media.class" => media_class = v.clone(),
                        "application.name" => app_name = v.clone(),
                        "node.name" => node_name = v.clone(),
                        _ => {}
                    }
                }
                idx += 2;
            }
        }
        if media_class.starts_with("Stream/") {
            let uid = *id as u32;
            self.nodes.insert(
                uid,
                TrackedNode {
                    media_class,
                    app_name,
                    node_name,
                },
            );
            return true;
        }
        false
    }

    fn handle_remove(&mut self, pod: &PodVal) -> bool {
        let PodVal::Struct(fields) = pod else {
            return false;
        };
        let Some(PodVal::Int(id)) = fields.first() else {
            return false;
        };
        self.nodes.remove(&(*id as u32)).is_some()
    }

    fn compute_privacy(&self, hypr_screencast: bool, pulse_mic_apps: &[String]) -> PrivacyState {
        let mut mic: BTreeSet<String> = BTreeSet::new();
        let mut cam: BTreeSet<String> = BTreeSet::new();
        let mut share: BTreeSet<String> = BTreeSet::new();

        for app in pulse_mic_apps {
            if !is_self_app(app) {
                mic.insert(app.clone());
            }
        }

        for node in self.nodes.values() {
            let label = if !node.app_name.is_empty() {
                node.app_name.clone()
            } else if !node.node_name.is_empty() {
                node.node_name.clone()
            } else {
                continue;
            };
            if is_self_app(&label) {
                continue;
            }
            if node.media_class == "Stream/Input/Audio" {
                mic.insert(label);
            } else if node.media_class == "Stream/Input/Video" {
                let lower = format!("{} {}", node.app_name, node.node_name).to_ascii_lowercase();
                if lower.contains("xdg-desktop-portal")
                    || lower.contains("screencast")
                    || lower.contains("screen")
                    || lower.contains("pipewire-screen")
                {
                    share.insert(label);
                } else {
                    cam.insert(label);
                }
            }
        }

        if hypr_screencast && share.is_empty() {
            share.insert("Wayland Screencast".to_string());
        }

        PrivacyState {
            mic_apps: mic.into_iter().collect(),
            camera_apps: cam.into_iter().collect(),
            screenshare_apps: share.into_iter().collect(),
            noscreenshare_active: false,
        }
    }
}

fn is_self_app(name: &str) -> bool {
    let lower = name.trim().to_ascii_lowercase();
    lower.contains("kaze-shell") || lower.contains("kaze-spectrum")
}

fn pipewire_socket_path() -> Option<PathBuf> {
    let rt = env::var("XDG_RUNTIME_DIR").ok()?;
    if rt.is_empty() {
        return None;
    }
    Some(PathBuf::from(rt).join("pipewire-0"))
}

fn recv_with_fd_drain(fd: libc::c_int, buf: &mut [u8]) -> io::Result<usize> {
    let mut iov = libc::iovec {
        iov_base: buf.as_mut_ptr().cast(),
        iov_len: buf.len(),
    };
    let mut cmsg_space = [0usize; 32];
    let mut msg: libc::msghdr = unsafe { std::mem::zeroed() };
    msg.msg_iov = &mut iov;
    msg.msg_iovlen = 1;
    msg.msg_control = cmsg_space.as_mut_ptr().cast();
    msg.msg_controllen = std::mem::size_of_val(&cmsg_space);

    // SAFETY: valid `msghdr` and non-blocking PipeWire socket FD; drains `SCM_RIGHTS` FDs safely.
    let n = unsafe { libc::recvmsg(fd, &mut msg, libc::MSG_CMSG_CLOEXEC) };
    if n < 0 {
        return Err(io::Error::last_os_error());
    }

    // Close any transferred FDs immediately so the daemon never leaks PipeWire memfds.
    // SAFETY: walking CMSG headers returned by kernel in `msg`.
    unsafe {
        let mut cmsg = libc::CMSG_FIRSTHDR(&msg);
        while !cmsg.is_null() {
            if (*cmsg).cmsg_level == libc::SOL_SOCKET && (*cmsg).cmsg_type == libc::SCM_RIGHTS {
                let data_ptr = libc::CMSG_DATA(cmsg);
                let header_len = libc::CMSG_LEN(0) as usize;
                let data_len = ((*cmsg).cmsg_len as usize).saturating_sub(header_len);
                let n_fds = data_len / std::mem::size_of::<libc::c_int>();
                for i in 0..n_fds {
                    let mut rfd: libc::c_int = -1;
                    std::ptr::copy_nonoverlapping(
                        data_ptr.add(i * std::mem::size_of::<libc::c_int>()),
                        (&raw mut rfd).cast(),
                        std::mem::size_of::<libc::c_int>(),
                    );
                    if rfd >= 0 {
                        libc::close(rfd);
                    }
                }
            }
            cmsg = libc::CMSG_NXTHDR(&msg, cmsg);
        }
    }

    Ok(n as usize)
}

#[derive(Debug, Clone)]
pub enum PrivacyUpdate {
    HyprScreencast(bool),
    PulseMicApps(Vec<String>),
}

pub async fn run_privacy_task(
    event_tx: CalloopSender<SystemEvent>,
    mut rx: tokio::sync::mpsc::UnboundedReceiver<PrivacyUpdate>,
) {
    let mut tracker = PipewireNodeTracker::default();
    let mut hypr_screencast = false;
    let mut pulse_mic_apps: Vec<String> = Vec::new();
    let mut last_state = PrivacyState::default();

    loop {
        let Some(sock) = pipewire_socket_path() else {
            tokio::time::sleep(Duration::from_secs(2)).await;
            continue;
        };
        let Ok(std_stream) = StdUnixStream::connect(&sock) else {
            tokio::select! {
                _ = tokio::time::sleep(Duration::from_secs(2)) => continue,
                upd = rx.recv() => {
                    let Some(u) = upd else { return; };
                    match u {
                        PrivacyUpdate::HyprScreencast(v) => hypr_screencast = v,
                        PrivacyUpdate::PulseMicApps(v) => pulse_mic_apps = v,
                    }
                    let st = tracker.compute_privacy(hypr_screencast, &pulse_mic_apps);
                    if st != last_state {
                        let _ = event_tx.send(SystemEvent::PrivacyChanged(st.clone()));
                        last_state = st;
                    }
                    continue;
                }
            }
        };
        if std_stream.set_nonblocking(true).is_err() {
            tokio::time::sleep(Duration::from_secs(2)).await;
            continue;
        }
        // SAFETY: `std_stream` stays owned exclusively by `async_fd`.
        let Ok(async_fd) = (unsafe { AsyncFd::register(std_stream) }) else {
            tokio::time::sleep(Duration::from_secs(2)).await;
            continue;
        };

        let mut seq = 1u32;
        let hello = build_hello_packet(seq);
        seq += 1;
        let reg = build_get_registry_packet(seq, PW_REGISTRY_ID);
        seq += 1;
        {
            use std::io::Write;
            let _ = async_fd.get_ref().write_all(&hello);
            let _ = async_fd.get_ref().write_all(&reg);
        }

        let mut rx_buf = Vec::<u8>::with_capacity(16_384);
        let mut tmp = [0u8; 8192];

        loop {
            let mut changed = false;
            let mut disconnected = false;
            tokio::select! {
                upd = rx.recv() => {
                    let Some(u) = upd else { return; };
                    match u {
                        PrivacyUpdate::HyprScreencast(v) => hypr_screencast = v,
                        PrivacyUpdate::PulseMicApps(v) => pulse_mic_apps = v,
                    }
                    changed = true;
                }
                guard_res = async_fd.readable() => {
                    let Ok(mut guard) = guard_res else { break; };
                    match guard.try_io(|inner| recv_with_fd_drain(inner.as_raw_fd(), &mut tmp)) {
                        Ok(Ok(0)) => disconnected = true,
                        Ok(Ok(n)) => rx_buf.extend_from_slice(&tmp[..n]),
                        Ok(Err(_)) => disconnected = true,
                        Err(_would_block) => continue,
                    }
                }
            }

            while rx_buf.len() >= 16 {
                let id = u32::from_le_bytes([rx_buf[0], rx_buf[1], rx_buf[2], rx_buf[3]]);
                let op_sz = u32::from_le_bytes([rx_buf[4], rx_buf[5], rx_buf[6], rx_buf[7]]);
                let opcode = (op_sz >> 24) as u8;
                let size = (op_sz & 0x00ff_ffff) as usize;
                let msg_end = 16 + size;
                if rx_buf.len() < msg_end {
                    break;
                }
                let payload = rx_buf[16..msg_end].to_vec();
                rx_buf.drain(..msg_end);

                if let Some((pod, _)) = parse_pod(&payload) {
                    if id == PW_CORE_ID && opcode == PW_CORE_EVENT_PING {
                        if let PodVal::Struct(fields) = pod {
                            if let (Some(PodVal::Int(pid)), Some(PodVal::Int(pseq))) =
                                (fields.first(), fields.get(1))
                            {
                                use std::io::Write;
                                let pong = build_pong_packet(seq, *pid, *pseq);
                                seq = seq.wrapping_add(1);
                                let _ = async_fd.get_ref().write_all(&pong);
                            }
                        }
                    } else if id == PW_REGISTRY_ID && opcode == PW_REGISTRY_EVENT_GLOBAL {
                        if tracker.handle_global(&pod) {
                            changed = true;
                        }
                    } else if id == PW_REGISTRY_ID
                        && opcode == PW_REGISTRY_EVENT_GLOBAL_REMOVE
                        && tracker.handle_remove(&pod)
                    {
                        changed = true;
                    }
                }
            }

            if changed {
                let st = tracker.compute_privacy(hypr_screencast, &pulse_mic_apps);
                if st != last_state {
                    let _ = event_tx.send(SystemEvent::PrivacyChanged(st.clone()));
                    last_state = st;
                }
            }
            if disconnected {
                tracker.nodes.clear();
                break;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pod_string(s: &str) -> Vec<u8> {
        let mut body = s.as_bytes().to_vec();
        body.push(0);
        let mut out = Vec::with_capacity(8 + align8(body.len()));
        out.extend_from_slice(&(body.len() as u32).to_le_bytes());
        out.extend_from_slice(&SPA_TYPE_STRING.to_le_bytes());
        out.extend_from_slice(&body);
        while out.len() % 8 != 0 {
            out.push(0);
        }
        out
    }

    #[test]
    fn parses_pipewire_global_node_and_excludes_kaze_shell() {
        let props = build_pod_struct(&[
            pod_int(3),
            pod_string("media.class"),
            pod_string("Stream/Input/Audio"),
            pod_string("application.name"),
            pod_string("obs-studio"),
            pod_string("node.name"),
            pod_string("obs-mic"),
        ]);
        let global = build_pod_struct(&[
            pod_int(42),
            pod_int(0),
            pod_string("PipeWire:Interface:Node"),
            pod_int(3),
            props,
        ]);
        let (pod, _) = parse_pod(&global).expect("parse pod");
        let mut tracker = PipewireNodeTracker::default();
        assert!(tracker.handle_global(&pod));

        // Ensure `kaze-shell` monitor/capture streams are excluded from privacy alerts.
        let self_props = build_pod_struct(&[
            pod_int(2),
            pod_string("media.class"),
            pod_string("Stream/Input/Audio"),
            pod_string("application.name"),
            pod_string("kaze-shell"),
        ]);
        let self_global = build_pod_struct(&[
            pod_int(43),
            pod_int(0),
            pod_string("PipeWire:Interface:Node"),
            pod_int(3),
            self_props,
        ]);
        let (self_pod, _) = parse_pod(&self_global).expect("parse self pod");
        tracker.handle_global(&self_pod);

        let st = tracker.compute_privacy(false, &[]);
        assert_eq!(st.mic_apps, vec!["obs-studio".to_string()]);
    }
}
