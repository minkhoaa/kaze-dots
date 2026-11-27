use calloop::channel::Sender as CalloopSender;
use kaze_core::{AudioState, OsdKind, SystemEvent};
use std::env;
use std::fs;
use std::io;
use std::path::PathBuf;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use tokio::sync::mpsc;

// PulseAudio Native Protocol command opcodes (verified against PipeWire module-protocol-pulse/commands.h).
const PA_COMMAND_ERROR: u32 = 0;
const PA_COMMAND_REPLY: u32 = 2;
const PA_COMMAND_AUTH: u32 = 8;
const PA_COMMAND_SET_CLIENT_NAME: u32 = 9;
const PA_COMMAND_GET_SERVER_INFO: u32 = 20;
const PA_COMMAND_GET_SINK_INFO: u32 = 21;
const PA_COMMAND_GET_SOURCE_INFO: u32 = 23;
const PA_COMMAND_SUBSCRIBE: u32 = 35;
const PA_COMMAND_SET_SINK_VOLUME: u32 = 36;
const PA_COMMAND_SET_SINK_MUTE: u32 = 39;
const PA_COMMAND_SET_SOURCE_MUTE: u32 = 40;
const PA_COMMAND_SUBSCRIBE_EVENT: u32 = 66;

const PA_SUBSCRIPTION_MASK_SINK: u32 = 0x0001;
const PA_SUBSCRIPTION_MASK_SOURCE: u32 = 0x0002;
const PA_SUBSCRIPTION_MASK_SERVER: u32 = 0x0080;

const PA_INVALID_INDEX: u32 = 0xFFFF_FFFF;
const PA_VOLUME_NORM: u32 = 0x0001_0000; // 65536 = 100%
const PA_VOLUME_MAX_PCT: u8 = 150;
const PA_PROTOCOL_VERSION: u32 = 35;

const TAG_STRING: u8 = b't';
const TAG_STRING_NULL: u8 = b'N';
const TAG_U32: u8 = b'L';
const TAG_U8: u8 = b'B';
const TAG_U64: u8 = b'R';
const TAG_S64: u8 = b'r';
const TAG_SAMPLE_SPEC: u8 = b'a';
const TAG_ARBITRARY: u8 = b'x';
const TAG_BOOLEAN_TRUE: u8 = b'1';
const TAG_BOOLEAN_FALSE: u8 = b'0';
const TAG_TIMEVAL: u8 = b'T';
const TAG_USEC: u8 = b'U';
const TAG_CHANNEL_MAP: u8 = b'm';
const TAG_CVOLUME: u8 = b'v';
const TAG_PROPLIST: u8 = b'P';
const TAG_VOLUME: u8 = b'V';
const TAG_FORMAT_INFO: u8 = b'f';

#[derive(Debug, Clone, Copy)]
pub enum AudioCmd {
    StepVolume(i32),
    ToggleMute,
    ToggleMicMute,
}

#[derive(Default)]
struct TagWriter {
    buf: Vec<u8>,
}

impl TagWriter {
    fn put_u32(&mut self, v: u32) {
        self.buf.push(TAG_U32);
        self.buf.extend_from_slice(&v.to_be_bytes());
    }

    fn put_bool(&mut self, v: bool) {
        self.buf.push(if v {
            TAG_BOOLEAN_TRUE
        } else {
            TAG_BOOLEAN_FALSE
        });
    }

    fn put_string(&mut self, s: &str) {
        self.buf.push(TAG_STRING);
        self.buf.extend_from_slice(s.as_bytes());
        self.buf.push(0);
    }

    fn put_arbitrary(&mut self, bytes: &[u8]) {
        self.buf.push(TAG_ARBITRARY);
        self.buf
            .extend_from_slice(&(bytes.len() as u32).to_be_bytes());
        self.buf.extend_from_slice(bytes);
    }

    fn put_cvolume(&mut self, channels: &[u32]) {
        self.buf.push(TAG_CVOLUME);
        self.buf.push(channels.len().min(32) as u8);
        for &v in channels.iter().take(32) {
            self.buf.extend_from_slice(&v.to_be_bytes());
        }
    }

    fn put_proplist(&mut self, pairs: &[(&str, &str)]) {
        self.buf.push(TAG_PROPLIST);
        for (k, v) in pairs {
            let mut val_bytes = v.as_bytes().to_vec();
            val_bytes.push(0);
            self.put_string(k);
            self.put_u32(val_bytes.len() as u32);
            self.put_arbitrary(&val_bytes);
        }
        self.buf.push(TAG_STRING_NULL);
    }

    fn finish(self) -> Vec<u8> {
        self.buf
    }
}

struct TagReader<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> TagReader<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self { data, pos: 0 }
    }

    fn read_byte(&mut self) -> Option<u8> {
        let b = *self.data.get(self.pos)?;
        self.pos += 1;
        Some(b)
    }

    fn read_exact(&mut self, n: usize) -> Option<&'a [u8]> {
        let end = self.pos.checked_add(n)?;
        let slice = self.data.get(self.pos..end)?;
        self.pos = end;
        Some(slice)
    }

    fn read_u32_raw(&mut self) -> Option<u32> {
        let bytes: [u8; 4] = self.read_exact(4)?.try_into().ok()?;
        Some(u32::from_be_bytes(bytes))
    }

    fn read_u32(&mut self) -> Option<u32> {
        if self.read_byte()? != TAG_U32 {
            return None;
        }
        self.read_u32_raw()
    }

    fn read_string(&mut self) -> Option<Option<String>> {
        match self.read_byte()? {
            TAG_STRING_NULL => Some(None),
            TAG_STRING => {
                let rem = self.data.get(self.pos..)?;
                let nul = rem.iter().position(|&b| b == 0)?;
                let s = String::from_utf8_lossy(&rem[..nul]).into_owned();
                self.pos += nul + 1;
                Some(Some(s))
            }
            _ => None,
        }
    }

    fn read_bool(&mut self) -> Option<bool> {
        match self.read_byte()? {
            TAG_BOOLEAN_TRUE => Some(true),
            TAG_BOOLEAN_FALSE => Some(false),
            _ => None,
        }
    }

    fn read_cvolume(&mut self) -> Option<Vec<u32>> {
        if self.read_byte()? != TAG_CVOLUME {
            return None;
        }
        let n = usize::from(self.read_byte()?);
        let mut vols = Vec::with_capacity(n);
        for _ in 0..n {
            vols.push(self.read_u32_raw()?);
        }
        Some(vols)
    }

    fn skip_sample_spec(&mut self) -> Option<()> {
        if self.read_byte()? != TAG_SAMPLE_SPEC {
            return None;
        }
        self.read_exact(6)?; // format(1) + channels(1) + rate(4)
        Some(())
    }

    fn skip_channel_map(&mut self) -> Option<()> {
        if self.read_byte()? != TAG_CHANNEL_MAP {
            return None;
        }
        let n = usize::from(self.read_byte()?);
        self.read_exact(n)?;
        Some(())
    }

    #[allow(dead_code)]
    fn skip_any(&mut self) -> Option<()> {
        let tag = self.read_byte()?;
        match tag {
            TAG_STRING_NULL | TAG_BOOLEAN_TRUE | TAG_BOOLEAN_FALSE => Some(()),
            TAG_STRING => {
                let rem = self.data.get(self.pos..)?;
                let nul = rem.iter().position(|&b| b == 0)?;
                self.pos += nul + 1;
                Some(())
            }
            TAG_U8 => {
                self.read_exact(1)?;
                Some(())
            }
            TAG_U32 | TAG_VOLUME => {
                self.read_exact(4)?;
                Some(())
            }
            TAG_U64 | TAG_S64 | TAG_USEC | TAG_TIMEVAL => {
                self.read_exact(8)?;
                Some(())
            }
            TAG_SAMPLE_SPEC => {
                self.read_exact(6)?;
                Some(())
            }
            TAG_CHANNEL_MAP => {
                let n = usize::from(self.read_byte()?);
                self.read_exact(n)?;
                Some(())
            }
            TAG_CVOLUME => {
                let n = usize::from(self.read_byte()?);
                self.read_exact(n * 4)?;
                Some(())
            }
            TAG_ARBITRARY => {
                let n = self.read_u32_raw()? as usize;
                self.read_exact(n)?;
                Some(())
            }
            TAG_PROPLIST => {
                loop {
                    let key = self.read_string()?;
                    if key.is_none() {
                        break;
                    }
                    let _len = self.read_u32()?;
                    self.skip_any()?;
                }
                Some(())
            }
            TAG_FORMAT_INFO => {
                self.skip_any()?; // encoding
                self.skip_any()?; // proplist
                Some(())
            }
            _ => None,
        }
    }
}

pub fn volume_to_pct(cvolume: &[u32]) -> u8 {
    if cvolume.is_empty() {
        return 0;
    }
    let max_vol = cvolume.iter().copied().max().unwrap_or(0);
    let pct = ((f64::from(max_vol) / f64::from(PA_VOLUME_NORM)) * 100.0).round();
    pct.clamp(0.0, f64::from(PA_VOLUME_MAX_PCT)) as u8
}

pub fn pct_to_pa_volume(pct: u8) -> u32 {
    let clamped = pct.min(PA_VOLUME_MAX_PCT);
    ((f64::from(clamped) / 100.0) * f64::from(PA_VOLUME_NORM)).round() as u32
}

struct PulseConn {
    stream: UnixStream,
    next_tag: u32,
}

impl PulseConn {
    async fn connect() -> io::Result<Self> {
        let sock = pulse_socket_path().ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotFound,
                "XDG_RUNTIME_DIR/pulse/native unavailable",
            )
        })?;
        let stream = UnixStream::connect(sock).await?;
        let mut conn = Self {
            stream,
            next_tag: 1,
        };
        conn.handshake().await?;
        Ok(conn)
    }

    fn alloc_tag(&mut self) -> u32 {
        let t = self.next_tag;
        self.next_tag = self.next_tag.wrapping_add(1).max(1);
        t
    }

    async fn send_packet(&mut self, payload: &[u8]) -> io::Result<()> {
        let mut header = [0u8; 20];
        header[0..4].copy_from_slice(&(payload.len() as u32).to_be_bytes());
        header[4..8].copy_from_slice(&0xFFFF_FFFFu32.to_be_bytes());
        self.stream.write_all(&header).await?;
        self.stream.write_all(payload).await?;
        self.stream.flush().await
    }

    async fn read_packet(&mut self) -> io::Result<Vec<u8>> {
        let mut header = [0u8; 20];
        self.stream.read_exact(&mut header).await?;
        let len = u32::from_be_bytes([header[0], header[1], header[2], header[3]]) as usize;
        if len > 4 * 1024 * 1024 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "pulse packet exceeds 4 MiB safety limit",
            ));
        }
        let mut payload = vec![0u8; len];
        if len > 0 {
            self.stream.read_exact(&mut payload).await?;
        }
        Ok(payload)
    }

    /// Sends a command and reads packets until the matching `tag` reply arrives
    /// (ignoring interleaved `SUBSCRIBE_EVENT` notifications safely).
    async fn call(
        &mut self,
        cmd: u32,
        build_body: impl FnOnce(&mut TagWriter),
    ) -> io::Result<Vec<u8>> {
        let tag = self.alloc_tag();
        let mut w = TagWriter::default();
        w.put_u32(cmd);
        w.put_u32(tag);
        build_body(&mut w);
        self.send_packet(&w.finish()).await?;

        for _ in 0..64 {
            let pkt = self.read_packet().await?;
            let mut r = TagReader::new(&pkt);
            let Some(opcode) = r.read_u32() else {
                continue;
            };
            let Some(reply_tag) = r.read_u32() else {
                continue;
            };
            if opcode == PA_COMMAND_SUBSCRIBE_EVENT {
                continue;
            }
            if reply_tag == tag {
                if opcode == PA_COMMAND_ERROR {
                    let err_code = r.read_u32().unwrap_or(0);
                    return Err(io::Error::other(format!(
                        "pulse command {cmd} returned error code {err_code}"
                    )));
                }
                if opcode == PA_COMMAND_REPLY {
                    return Ok(pkt[r.pos..].to_vec());
                }
            }
        }
        Err(io::Error::new(
            io::ErrorKind::TimedOut,
            "missing pulse reply for tag",
        ))
    }

    async fn handshake(&mut self) -> io::Result<()> {
        let cookie = read_pulse_cookie();
        let _ = self
            .call(PA_COMMAND_AUTH, |w| {
                w.put_u32(PA_PROTOCOL_VERSION);
                w.put_arbitrary(&cookie);
            })
            .await?;

        let _ = self
            .call(PA_COMMAND_SET_CLIENT_NAME, |w| {
                w.put_proplist(&[("application.name", "kaze-shell")]);
            })
            .await?;

        let mask =
            PA_SUBSCRIPTION_MASK_SINK | PA_SUBSCRIPTION_MASK_SOURCE | PA_SUBSCRIPTION_MASK_SERVER;
        let _ = self
            .call(PA_COMMAND_SUBSCRIBE, |w| {
                w.put_u32(mask);
            })
            .await?;

        Ok(())
    }

    async fn get_server_defaults(&mut self) -> io::Result<(String, String)> {
        let body = self.call(PA_COMMAND_GET_SERVER_INFO, |_| {}).await?;
        parse_server_info(&body)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "invalid server info"))
    }

    async fn get_sink_info(&mut self, sink_name: &str) -> io::Result<(u32, Vec<u32>, bool)> {
        let body = self
            .call(PA_COMMAND_GET_SINK_INFO, |w| {
                w.put_u32(PA_INVALID_INDEX);
                w.put_string(sink_name);
            })
            .await?;
        parse_device_volume_mute(&body)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "invalid sink info"))
    }

    async fn get_source_info(&mut self, source_name: &str) -> io::Result<(u32, Vec<u32>, bool)> {
        let body = self
            .call(PA_COMMAND_GET_SOURCE_INFO, |w| {
                w.put_u32(PA_INVALID_INDEX);
                w.put_string(source_name);
            })
            .await?;
        parse_device_volume_mute(&body)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "invalid source info"))
    }

    async fn set_sink_volume(&mut self, sink_name: &str, cvolume: &[u32]) -> io::Result<()> {
        let _ = self
            .call(PA_COMMAND_SET_SINK_VOLUME, |w| {
                w.put_u32(PA_INVALID_INDEX);
                w.put_string(sink_name);
                w.put_cvolume(cvolume);
            })
            .await?;
        Ok(())
    }

    async fn set_sink_mute(&mut self, sink_name: &str, mute: bool) -> io::Result<()> {
        let _ = self
            .call(PA_COMMAND_SET_SINK_MUTE, |w| {
                w.put_u32(PA_INVALID_INDEX);
                w.put_string(sink_name);
                w.put_bool(mute);
            })
            .await?;
        Ok(())
    }

    async fn set_source_mute(&mut self, source_name: &str, mute: bool) -> io::Result<()> {
        let _ = self
            .call(PA_COMMAND_SET_SOURCE_MUTE, |w| {
                w.put_u32(PA_INVALID_INDEX);
                w.put_string(source_name);
                w.put_bool(mute);
            })
            .await?;
        Ok(())
    }

    async fn fetch_state(&mut self) -> io::Result<(AudioState, usize)> {
        let (sink_name, source_name) = self.get_server_defaults().await?;
        let mut channels = 2usize;
        let (volume_pct, muted) = if !sink_name.is_empty() {
            match self.get_sink_info(&sink_name).await {
                Ok((_idx, cvol, m)) => {
                    channels = cvol.len().max(1);
                    (volume_to_pct(&cvol), m)
                }
                Err(_) => (0, false),
            }
        } else {
            (0, false)
        };
        let mic_muted = if !source_name.is_empty() {
            self.get_source_info(&source_name)
                .await
                .map(|(_, _, m)| m)
                .unwrap_or(false)
        } else {
            false
        };
        Ok((
            AudioState {
                available: !sink_name.is_empty(),
                volume_pct,
                muted,
                mic_muted,
                sink_name,
                source_name,
            },
            channels,
        ))
    }
}

fn parse_server_info(body: &[u8]) -> Option<(String, String)> {
    let mut r = TagReader::new(body);
    let _pkg_name = r.read_string()?;
    let _pkg_ver = r.read_string()?;
    let _user = r.read_string()?;
    let _host = r.read_string()?;
    r.skip_sample_spec()?;
    let default_sink = r.read_string()?.unwrap_or_default();
    let default_source = r.read_string()?.unwrap_or_default();
    Some((default_sink, default_source))
}

fn parse_device_volume_mute(body: &[u8]) -> Option<(u32, Vec<u32>, bool)> {
    let mut r = TagReader::new(body);
    let index = r.read_u32()?;
    let _name = r.read_string()?;
    let _desc = r.read_string()?;
    r.skip_sample_spec()?;
    r.skip_channel_map()?;
    let _owner_module = r.read_u32()?;
    let cvol = r.read_cvolume()?;
    let mute = r.read_bool()?;
    Some((index, cvol, mute))
}

fn pulse_socket_path() -> Option<PathBuf> {
    let rt = env::var("XDG_RUNTIME_DIR").ok()?;
    if rt.is_empty() {
        return None;
    }
    Some(PathBuf::from(rt).join("pulse").join("native"))
}

fn read_pulse_cookie() -> Vec<u8> {
    if let Ok(xdg) = env::var("XDG_CONFIG_HOME") {
        if let Ok(bytes) = fs::read(PathBuf::from(xdg).join("pulse").join("cookie")) {
            if bytes.len() == 256 {
                return bytes;
            }
        }
    }
    if let Ok(home) = env::var("HOME") {
        for rel in [".config/pulse/cookie", ".pulse-cookie"] {
            if let Ok(bytes) = fs::read(PathBuf::from(&home).join(rel)) {
                if bytes.len() == 256 {
                    return bytes;
                }
            }
        }
    }
    vec![0u8; 256]
}

pub async fn run_audio_task(
    event_tx: CalloopSender<SystemEvent>,
    mut cmd_rx: mpsc::UnboundedReceiver<AudioCmd>,
) {
    let mut backoff = Duration::from_millis(250);
    let max_backoff = Duration::from_secs(5);
    let mut last_state: Option<AudioState> = None;

    loop {
        match PulseConn::connect().await {
            Ok(mut conn) => {
                backoff = Duration::from_millis(250);
                let mut sink_channels = 2usize;
                if let Ok((st, ch)) = conn.fetch_state().await {
                    sink_channels = ch;
                    if last_state.as_ref() != Some(&st) {
                        let _ = event_tx.send(SystemEvent::AudioChanged {
                            state: st.clone(),
                            trigger_osd: None,
                        });
                        last_state = Some(st);
                    }
                }

                loop {
                    tokio::select! {
                        pkt = conn.read_packet() => {
                            match pkt {
                                Ok(data) => {
                                    let mut r = TagReader::new(&data);
                                    if r.read_u32() == Some(PA_COMMAND_SUBSCRIBE_EVENT) {
                                        if let Ok((st, ch)) = conn.fetch_state().await {
                                            sink_channels = ch;
                                            let trigger = compute_osd_trigger(last_state.as_ref(), &st);
                                            if last_state.as_ref() != Some(&st) {
                                                let _ = event_tx.send(SystemEvent::AudioChanged {
                                                    state: st.clone(),
                                                    trigger_osd: trigger,
                                                });
                                                last_state = Some(st);
                                            }
                                        }
                                    }
                                }
                                Err(_) => break,
                            }
                        }
                        cmd = cmd_rx.recv() => {
                            let Some(cmd) = cmd else { return; };
                            if let Some(ref cur) = last_state {
                                if !cur.sink_name.is_empty() {
                                    let res = match cmd {
                                        AudioCmd::StepVolume(delta) => {
                                            let next_pct = (i32::from(cur.volume_pct) + delta)
                                                .clamp(0, i32::from(PA_VOLUME_MAX_PCT)) as u8;
                                            let cvol = vec![pct_to_pa_volume(next_pct); sink_channels.max(1)];
                                            conn.set_sink_volume(&cur.sink_name, &cvol).await
                                        }
                                        AudioCmd::ToggleMute => {
                                            conn.set_sink_mute(&cur.sink_name, !cur.muted).await
                                        }
                                        AudioCmd::ToggleMicMute => {
                                            if !cur.source_name.is_empty() {
                                                conn.set_source_mute(&cur.source_name, !cur.mic_muted).await
                                            } else {
                                                Ok(())
                                            }
                                        }
                                    };
                                    if res.is_err() {
                                        break;
                                    }
                                    // Immediately sync & notify even if server coalesces subscribe events.
                                    if let Ok((st, ch)) = conn.fetch_state().await {
                                        sink_channels = ch;
                                        let trigger = match cmd {
                                            AudioCmd::StepVolume(_) | AudioCmd::ToggleMute => Some(OsdKind::Volume),
                                            AudioCmd::ToggleMicMute => Some(OsdKind::Mic),
                                        };
                                        let _ = event_tx.send(SystemEvent::AudioChanged {
                                            state: st.clone(),
                                            trigger_osd: trigger,
                                        });
                                        last_state = Some(st);
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Err(_) => {
                // Wait with backoff, draining commands cleanly if PipeWire is not yet up.
                tokio::select! {
                    _ = tokio::time::sleep(backoff) => {
                        backoff = (backoff * 2).min(max_backoff);
                    }
                    cmd = cmd_rx.recv() => {
                        if cmd.is_none() {
                            return;
                        }
                    }
                }
            }
        }
    }
}

fn compute_osd_trigger(prev: Option<&AudioState>, next: &AudioState) -> Option<OsdKind> {
    let prev = prev?;
    if prev.volume_pct != next.volume_pct || prev.muted != next.muted {
        Some(OsdKind::Volume)
    } else if prev.mic_muted != next.mic_muted {
        Some(OsdKind::Mic)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn converts_pulse_cvolume_percentages_accurately() {
        assert_eq!(volume_to_pct(&[0, 0]), 0);
        assert_eq!(volume_to_pct(&[PA_VOLUME_NORM, PA_VOLUME_NORM]), 100);
        assert_eq!(volume_to_pct(&[PA_VOLUME_NORM / 2, PA_VOLUME_NORM / 2]), 50);
        assert_eq!(pct_to_pa_volume(100), PA_VOLUME_NORM);
        assert_eq!(pct_to_pa_volume(50), PA_VOLUME_NORM / 2);
        assert_eq!(volume_to_pct(&[pct_to_pa_volume(75)]), 75);
    }

    #[test]
    fn decodes_server_info_and_sink_info_tagstructs() {
        let mut sw = TagWriter::default();
        sw.put_string("PulseAudio (on PipeWire 1.2.0)");
        sw.put_string("15.0.0");
        sw.put_string("bench");
        sw.put_string("shell-bench");
        sw.buf.push(TAG_SAMPLE_SPEC);
        sw.buf.extend_from_slice(&[5, 2, 0, 0, 0xbb, 0x80]);
        sw.put_string("alsa_output.default");
        sw.put_string("alsa_input.default");
        let (sink, source) = parse_server_info(&sw.finish()).expect("server info");
        assert_eq!(sink, "alsa_output.default");
        assert_eq!(source, "alsa_input.default");

        let mut dw = TagWriter::default();
        dw.put_u32(42);
        dw.put_string("alsa_output.default");
        dw.put_string("Built-in Audio");
        dw.buf.push(TAG_SAMPLE_SPEC);
        dw.buf.extend_from_slice(&[5, 2, 0, 0, 0xbb, 0x80]);
        dw.buf.push(TAG_CHANNEL_MAP);
        dw.buf.extend_from_slice(&[2, 1, 2]);
        dw.put_u32(0);
        dw.put_cvolume(&[pct_to_pa_volume(65), pct_to_pa_volume(65)]);
        dw.put_bool(true);
        let (idx, vols, muted) = parse_device_volume_mute(&dw.finish()).expect("sink info");
        assert_eq!(idx, 42);
        assert_eq!(volume_to_pct(&vols), 65);
        assert!(muted);
    }
}
