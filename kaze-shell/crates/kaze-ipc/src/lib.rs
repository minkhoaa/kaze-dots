use serde::{Deserialize, Serialize};
use std::env;
use std::fs;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::fd::{AsFd, BorrowedFd};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::time::Duration;

const MAX_LINE_BYTES: usize = 64 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IpcRequest {
    pub cmd: String,
    #[serde(default)]
    pub args: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct IpcResponse {
    pub ok: bool,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<serde_json::Value>,
}

impl IpcResponse {
    pub fn ok(message: impl Into<String>) -> Self {
        Self {
            ok: true,
            message: message.into(),
            data: None,
        }
    }

    pub fn ok_data(message: impl Into<String>, data: serde_json::Value) -> Self {
        Self {
            ok: true,
            message: message.into(),
            data: Some(data),
        }
    }

    pub fn err(message: impl Into<String>) -> Self {
        Self {
            ok: false,
            message: message.into(),
            data: None,
        }
    }
}

pub fn default_socket_path() -> Result<PathBuf, String> {
    let runtime = env::var("XDG_RUNTIME_DIR")
        .ok()
        .filter(|v| !v.is_empty())
        .ok_or_else(|| "XDG_RUNTIME_DIR is not set".to_string())?;
    Ok(PathBuf::from(runtime).join("kaze").join("shell.sock"))
}

pub struct IpcServer {
    path: PathBuf,
    listener: UnixListener,
}

impl IpcServer {
    pub fn bind(path: PathBuf) -> Result<Self, String> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)
                .map_err(|e| format!("failed creating IPC dir {}: {e}", parent.display()))?;
            let _ = fs::set_permissions(parent, fs::Permissions::from_mode(0o700));
        }

        if path.exists() {
            match UnixStream::connect(&path) {
                Ok(_) => {
                    return Err(format!(
                        "another kaze-shell daemon is already listening on {}",
                        path.display()
                    ));
                }
                Err(_) => {
                    let _ = fs::remove_file(&path);
                }
            }
        }

        let listener = UnixListener::bind(&path)
            .map_err(|e| format!("failed binding {}: {e}", path.display()))?;
        let _ = fs::set_permissions(&path, fs::Permissions::from_mode(0o600));
        listener
            .set_nonblocking(true)
            .map_err(|e| format!("failed setting nonblocking on IPC listener: {e}"))?;

        Ok(Self { path, listener })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Accepts all queued client connections without blocking and handles each request via `handler`.
    pub fn accept_and_dispatch<F>(&self, mut handler: F)
    where
        F: FnMut(IpcRequest) -> IpcResponse,
    {
        loop {
            match self.listener.accept() {
                Ok((stream, _addr)) => {
                    handle_connection(stream, &mut handler);
                }
                Err(err) if err.kind() == io::ErrorKind::WouldBlock => break,
                Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
                Err(err) => {
                    eprintln!("kaze-ipc: accept error: {err}");
                    break;
                }
            }
        }
    }
}

impl AsFd for IpcServer {
    fn as_fd(&self) -> BorrowedFd<'_> {
        self.listener.as_fd()
    }
}

impl Drop for IpcServer {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

fn handle_connection<F>(mut stream: UnixStream, handler: &mut F)
where
    F: FnMut(IpcRequest) -> IpcResponse,
{
    let _ = stream.set_nonblocking(false);
    let _ = stream.set_read_timeout(Some(Duration::from_millis(250)));
    let _ = stream.set_write_timeout(Some(Duration::from_millis(250)));

    let resp = match read_request_line(&stream) {
        Ok(req) => handler(req),
        Err(msg) => IpcResponse::err(msg),
    };

    if let Ok(mut line) = serde_json::to_string(&resp) {
        line.push('\n');
        let _ = stream.write_all(line.as_bytes());
        let _ = stream.flush();
    }
}

fn read_request_line(stream: &UnixStream) -> Result<IpcRequest, String> {
    let mut reader = BufReader::new(stream.take(MAX_LINE_BYTES as u64));
    let mut line = String::new();
    let n = reader
        .read_line(&mut line)
        .map_err(|e| format!("read error: {e}"))?;
    if n == 0 {
        return Err("empty IPC request".to_string());
    }
    serde_json::from_str::<IpcRequest>(line.trim())
        .map_err(|e| format!("invalid JSON request: {e}"))
}

pub fn send_request(path: &Path, req: &IpcRequest) -> Result<IpcResponse, String> {
    let mut stream = UnixStream::connect(path)
        .map_err(|e| format!("cannot connect to {}: {e}", path.display()))?;
    let _ = stream.set_read_timeout(Some(Duration::from_secs(3)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(1)));

    let mut payload = serde_json::to_string(req).map_err(|e| format!("encode IPC request: {e}"))?;
    payload.push('\n');
    stream
        .write_all(payload.as_bytes())
        .map_err(|e| format!("write IPC request: {e}"))?;
    stream
        .flush()
        .map_err(|e| format!("flush IPC request: {e}"))?;

    let mut reader = BufReader::new(stream.take((MAX_LINE_BYTES * 4) as u64));
    let mut line = String::new();
    let n = reader
        .read_line(&mut line)
        .map_err(|e| format!("read IPC response: {e}"))?;
    if n == 0 {
        return Err("daemon closed connection without responding".to_string());
    }
    serde_json::from_str::<IpcResponse>(line.trim())
        .map_err(|e| format!("decode IPC response: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::DirBuilderExt;
    use std::thread;

    #[test]
    fn round_trips_ipc_request_and_response() {
        let dir = env::temp_dir().join(format!("kaze-ipc-test-{}", std::process::id()));
        let sock = dir.join("shell.sock");
        fs::DirBuilder::new()
            .mode(0o700)
            .create(&dir)
            .expect("private IPC fixture");

        let server = IpcServer::bind(sock.clone()).expect("bind server");
        let sock_client = sock.clone();
        let client_handle = thread::spawn(move || {
            send_request(
                &sock_client,
                &IpcRequest {
                    cmd: "ping".into(),
                    args: vec![],
                },
            )
        });

        for _ in 0..50 {
            let mut handled = false;
            server.accept_and_dispatch(|req| {
                handled = true;
                assert_eq!(req.cmd, "ping");
                IpcResponse::ok("pong")
            });
            if handled {
                break;
            }
            thread::sleep(Duration::from_millis(5));
        }

        let resp = client_handle
            .join()
            .expect("client thread")
            .expect("client response");
        assert!(resp.ok);
        assert_eq!(resp.message, "pong");

        drop(server);
        assert!(!sock.exists());
        let _ = fs::remove_dir_all(&dir);
    }
}
