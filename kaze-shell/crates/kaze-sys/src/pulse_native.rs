use calloop::channel::Sender as CalloopSender;
use kaze_core::{AudioDeviceInfo, AudioState, AudioStreamInfo, OsdKind, SystemEvent};
use std::collections::HashMap;
use std::env;
use std::f32::consts::PI;
use std::fs;
use std::io;
use std::path::PathBuf;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use tokio::sync::mpsc;

use crate::pipewire_privacy::PrivacyUpdate;

// PulseAudio Native Protocol command opcodes (verified against PipeWire module-protocol-pulse/commands.h).
const PA_COMMAND_ERROR: u32 = 0;
const PA_COMMAND_REPLY: u32 = 2;
const PA_COMMAND_CREATE_RECORD_STREAM: u32 = 5;
const PA_COMMAND_DELETE_RECORD_STREAM: u32 = 6;
const PA_COMMAND_AUTH: u32 = 8;
const PA_COMMAND_SET_CLIENT_NAME: u32 = 9;
const PA_COMMAND_GET_SERVER_INFO: u32 = 20;
const PA_COMMAND_GET_SINK_INFO: u32 = 21;
const PA_COMMAND_GET_SINK_INFO_LIST: u32 = 22;
const PA_COMMAND_GET_SOURCE_INFO: u32 = 23;
const PA_COMMAND_GET_SOURCE_INFO_LIST: u32 = 24;
const PA_COMMAND_GET_SINK_INPUT_INFO_LIST: u32 = 30;
const PA_COMMAND_GET_SOURCE_OUTPUT_INFO_LIST: u32 = 32;
const PA_COMMAND_SUBSCRIBE: u32 = 35;
const PA_COMMAND_SET_SINK_VOLUME: u32 = 36;
const PA_COMMAND_SET_SINK_INPUT_VOLUME: u32 = 37;
const PA_COMMAND_SET_SINK_MUTE: u32 = 39;
const PA_COMMAND_SET_SOURCE_MUTE: u32 = 40;
const PA_COMMAND_SET_DEFAULT_SINK: u32 = 44;
const PA_COMMAND_SET_DEFAULT_SOURCE: u32 = 45;
const PA_COMMAND_SUBSCRIBE_EVENT: u32 = 66;
const PA_COMMAND_SET_SINK_INPUT_MUTE: u32 = 75;

const PA_SUBSCRIPTION_MASK_SINK: u32 = 0x0001;
const PA_SUBSCRIPTION_MASK_SOURCE: u32 = 0x0002;
const PA_SUBSCRIPTION_MASK_SINK_INPUT: u32 = 0x0004;
const PA_SUBSCRIPTION_MASK_SOURCE_OUTPUT: u32 = 0x0008;
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

#[derive(Debug, Clone)]
pub enum AudioCmd {
    StepVolume(i32),
    SetVolume(u8),
    ToggleMute,
    ToggleMicMute,
    SetDefaultSink(String),
    SetDefaultSource(String),
    SetStreamVolume { index: u32, pct: u8 },
    SetStreamMute { index: u32, muted: bool },
    SetSpectrumSubscribers { count: usize, fps: u32 },
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

    fn put_sample_spec(&mut self, format: u8, channels: u8, rate: u32) {
        self.buf.push(TAG_SAMPLE_SPEC);
        self.buf.push(format);
        self.buf.push(channels);
        self.buf.extend_from_slice(&rate.to_be_bytes());
    }

    fn put_channel_map(&mut self, map: &[u8]) {
        self.buf.push(TAG_CHANNEL_MAP);
        self.buf.push(map.len() as u8);
        self.buf.extend_from_slice(map);
    }

    fn put_null_string(&mut self) {
        self.buf.push(TAG_STRING_NULL);
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

    fn read_proplist(&mut self) -> Option<HashMap<String, String>> {
        if self.read_byte()? != TAG_PROPLIST {
            return None;
        }
        let mut map = HashMap::new();
        loop {
            let key = self.read_string()?;
            let Some(k) = key else {
                break;
            };
            let _len = self.read_u32()?;
            if self.read_byte()? == TAG_ARBITRARY {
                let raw_len = self.read_u32_raw()? as usize;
                let raw = self.read_exact(raw_len)?;
                let nul = raw.iter().position(|&b| b == 0).unwrap_or(raw.len());
                map.insert(k, String::from_utf8_lossy(&raw[..nul]).into_owned());
            } else {
                self.pos = self.pos.saturating_sub(1);
                self.skip_any()?;
            }
        }
        Some(map)
    }

    fn read_u8_val(&mut self) -> Option<u8> {
        if self.read_byte()? != TAG_U8 {
            return None;
        }
        self.read_byte()
    }

    fn read_usec(&mut self) -> Option<u64> {
        if self.read_byte()? != TAG_USEC {
            return None;
        }
        let b: [u8; 8] = self.read_exact(8)?.try_into().ok()?;
        Some(u64::from_be_bytes(b))
    }

    fn read_volume_single(&mut self) -> Option<u32> {
        if self.read_byte()? != TAG_VOLUME {
            return None;
        }
        self.read_u32_raw()
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

        let mask = PA_SUBSCRIPTION_MASK_SINK
            | PA_SUBSCRIPTION_MASK_SOURCE
            | PA_SUBSCRIPTION_MASK_SINK_INPUT
            | PA_SUBSCRIPTION_MASK_SOURCE_OUTPUT
            | PA_SUBSCRIPTION_MASK_SERVER;
        let _ = self
            .call(PA_COMMAND_SUBSCRIBE, |w| {
                w.put_u32(mask);
            })
            .await?;

        Ok(())
    }

    async fn get_sinks(&mut self, default_sink: &str) -> Vec<AudioDeviceInfo> {
        let Ok(body) = self.call(PA_COMMAND_GET_SINK_INFO_LIST, |_| {}).await else {
            return Vec::new();
        };
        parse_device_list(&body, default_sink)
    }

    async fn get_sources(&mut self, default_source: &str) -> Vec<AudioDeviceInfo> {
        let Ok(body) = self.call(PA_COMMAND_GET_SOURCE_INFO_LIST, |_| {}).await else {
            return Vec::new();
        };
        parse_device_list(&body, default_source)
            .into_iter()
            .filter(|s| !s.name.ends_with(".monitor"))
            .collect()
    }

    async fn get_sink_inputs(&mut self) -> Vec<AudioStreamInfo> {
        let Ok(body) = self.call(PA_COMMAND_GET_SINK_INPUT_INFO_LIST, |_| {}).await else {
            return Vec::new();
        };
        parse_sink_input_list(&body)
    }

    async fn get_source_output_apps(&mut self) -> Vec<String> {
        let Ok(body) = self
            .call(PA_COMMAND_GET_SOURCE_OUTPUT_INFO_LIST, |_| {})
            .await
        else {
            return Vec::new();
        };
        parse_source_output_apps(&body)
    }

    async fn set_default_sink(&mut self, name: &str) -> io::Result<()> {
        let _ = self
            .call(PA_COMMAND_SET_DEFAULT_SINK, |w| {
                w.put_string(name);
            })
            .await?;
        Ok(())
    }

    async fn set_default_source(&mut self, name: &str) -> io::Result<()> {
        let _ = self
            .call(PA_COMMAND_SET_DEFAULT_SOURCE, |w| {
                w.put_string(name);
            })
            .await?;
        Ok(())
    }

    async fn set_sink_input_volume(&mut self, index: u32, pct: u8) -> io::Result<()> {
        let cvol = vec![pct_to_pa_volume(pct); 2];
        let _ = self
            .call(PA_COMMAND_SET_SINK_INPUT_VOLUME, |w| {
                w.put_u32(index);
                w.put_cvolume(&cvol);
            })
            .await?;
        Ok(())
    }

    async fn set_sink_input_mute(&mut self, index: u32, muted: bool) -> io::Result<()> {
        let _ = self
            .call(PA_COMMAND_SET_SINK_INPUT_MUTE, |w| {
                w.put_u32(index);
                w.put_bool(muted);
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

    async fn fetch_state(&mut self) -> io::Result<(AudioState, usize, Vec<String>)> {
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
        let sinks = self.get_sinks(&sink_name).await;
        let sources = self.get_sources(&source_name).await;
        let streams = self.get_sink_inputs().await;
        let source_output_apps = self.get_source_output_apps().await;
        Ok((
            AudioState {
                available: !sink_name.is_empty(),
                volume_pct,
                muted,
                mic_muted,
                sink_name,
                source_name,
                sinks,
                sources,
                streams,
            },
            channels,
            source_output_apps,
        ))
    }
}

fn parse_device_list(body: &[u8], default_name: &str) -> Vec<AudioDeviceInfo> {
    let mut r = TagReader::new(body);
    let mut out = Vec::new();
    while r.pos < body.len() {
        let Some(index) = r.read_u32() else { break };
        let Some(Some(name)) = r.read_string() else {
            break;
        };
        let desc = r.read_string().unwrap_or(None).unwrap_or_default();
        if r.skip_sample_spec().is_none() || r.skip_channel_map().is_none() {
            break;
        }
        if r.read_u32().is_none() {
            break;
        }
        let Some(cvol) = r.read_cvolume() else { break };
        let Some(muted) = r.read_bool() else { break };
        if r.read_u32().is_none()
            || r.read_string().is_none()
            || r.read_usec().is_none()
            || r.read_string().is_none()
            || r.read_u32().is_none()
        {
            break;
        }
        if r.read_proplist().is_none()
            || r.read_usec().is_none()
            || r.read_volume_single().is_none()
            || r.read_u32().is_none()
            || r.read_u32().is_none()
            || r.read_u32().is_none()
        {
            break;
        }
        let Some(n_ports) = r.read_u32() else { break };
        for _ in 0..n_ports.min(64) {
            if r.read_string().is_none()
                || r.read_string().is_none()
                || r.read_u32().is_none()
                || r.read_u32().is_none()
            {
                return out;
            }
        }
        if r.read_string().is_none() {
            break;
        }
        if let Some(n_formats) = r.read_u8_val() {
            for _ in 0..n_formats.min(32) {
                let _ = r.skip_any();
            }
        } else {
            break;
        }
        out.push(AudioDeviceInfo {
            index,
            description: if desc.is_empty() { name.clone() } else { desc },
            is_default: name == default_name,
            name,
            volume_pct: volume_to_pct(&cvol),
            muted,
        });
    }
    out
}

fn parse_sink_input_list(body: &[u8]) -> Vec<AudioStreamInfo> {
    let mut r = TagReader::new(body);
    let mut out = Vec::new();
    while r.pos < body.len() {
        let Some(index) = r.read_u32() else { break };
        let name = r.read_string().unwrap_or(None).unwrap_or_default();
        if r.read_u32().is_none() || r.read_u32().is_none() || r.read_u32().is_none() {
            break;
        }
        if r.skip_sample_spec().is_none() || r.skip_channel_map().is_none() {
            break;
        }
        let Some(cvol) = r.read_cvolume() else { break };
        if r.read_usec().is_none()
            || r.read_usec().is_none()
            || r.read_string().is_none()
            || r.read_string().is_none()
        {
            break;
        }
        let Some(muted) = r.read_bool() else { break };
        let Some(props) = r.read_proplist() else {
            break;
        };
        if r.read_bool().is_none() || r.read_bool().is_none() || r.read_bool().is_none() {
            break;
        }
        let _ = r.skip_any(); // format_info
        let app_name = props
            .get("application.name")
            .cloned()
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| name.clone());
        let media_name = props.get("media.name").cloned().unwrap_or_default();
        out.push(AudioStreamInfo {
            index,
            app_name,
            media_name,
            volume_pct: volume_to_pct(&cvol),
            muted,
        });
    }
    out
}

fn parse_source_output_apps(body: &[u8]) -> Vec<String> {
    let mut r = TagReader::new(body);
    let mut out = Vec::new();
    while r.pos < body.len() {
        if r.read_u32().is_none()
            || r.read_string().is_none()
            || r.read_u32().is_none()
            || r.read_u32().is_none()
            || r.read_u32().is_none()
        {
            break;
        }
        if r.skip_sample_spec().is_none() || r.skip_channel_map().is_none() {
            break;
        }
        if r.read_usec().is_none()
            || r.read_usec().is_none()
            || r.read_string().is_none()
            || r.read_string().is_none()
        {
            break;
        }
        let Some(props) = r.read_proplist() else {
            break;
        };
        if r.read_bool().is_none()
            || r.read_cvolume().is_none()
            || r.read_bool().is_none()
            || r.read_bool().is_none()
            || r.read_bool().is_none()
        {
            break;
        }
        let _ = r.skip_any(); // format_info
        if let Some(app) = props.get("application.name").filter(|s| !s.is_empty()) {
            let lower = app.to_ascii_lowercase();
            if !lower.contains("kaze-shell")
                && !lower.contains("kaze-spectrum")
                && !out.contains(app)
            {
                out.push(app.clone());
            }
        }
    }
    out
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
    privacy_tx: mpsc::UnboundedSender<PrivacyUpdate>,
    mut cmd_rx: mpsc::UnboundedReceiver<AudioCmd>,
) {
    let mut backoff = Duration::from_millis(250);
    let max_backoff = Duration::from_secs(5);
    let mut last_state: Option<AudioState> = None;
    let mut spectrum_task: Option<tokio::task::JoinHandle<()>> = None;

    loop {
        match PulseConn::connect().await {
            Ok(mut conn) => {
                backoff = Duration::from_millis(250);
                let mut sink_channels = 2usize;
                if let Ok((st, ch, mic_apps)) = conn.fetch_state().await {
                    sink_channels = ch;
                    let _ = privacy_tx.send(PrivacyUpdate::PulseMicApps(mic_apps));
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
                                        if let Ok((st, ch, mic_apps)) = conn.fetch_state().await {
                                            sink_channels = ch;
                                            let _ = privacy_tx.send(PrivacyUpdate::PulseMicApps(mic_apps));
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
                            let Some(cmd) = cmd else {
                                if let Some(h) = spectrum_task.take() {
                                    h.abort();
                                }
                                return;
                            };
                            if let AudioCmd::SetSpectrumSubscribers { count, fps } = cmd {
                                let spectrum_fps = fps.clamp(10, 60);
                                if count == 0 {
                                    if let Some(h) = spectrum_task.take() {
                                        h.abort();
                                    }
                                    let _ = event_tx.send(SystemEvent::AudioSpectrum(Vec::new()));
                                } else if spectrum_task.is_none() {
                                    let monitor_src = last_state
                                        .as_ref()
                                        .map(|s| format!("{}.monitor", s.sink_name))
                                        .unwrap_or_default();
                                    if !monitor_src.is_empty() {
                                        let tx = event_tx.clone();
                                        let fps_local = spectrum_fps;
                                        spectrum_task = Some(tokio::spawn(run_spectrum_monitor(
                                            tx,
                                            monitor_src,
                                            fps_local,
                                        )));
                                    }
                                }
                                continue;
                            }
                            if let Some(ref cur) = last_state {
                                let res = match cmd {
                                    AudioCmd::StepVolume(delta) if !cur.sink_name.is_empty() => {
                                        let next_pct = (i32::from(cur.volume_pct) + delta)
                                            .clamp(0, i32::from(PA_VOLUME_MAX_PCT)) as u8;
                                        let cvol = vec![pct_to_pa_volume(next_pct); sink_channels.max(1)];
                                        conn.set_sink_volume(&cur.sink_name, &cvol).await
                                    }
                                    AudioCmd::SetVolume(pct) if !cur.sink_name.is_empty() => {
                                        let clamped = pct.min(PA_VOLUME_MAX_PCT);
                                        let cvol = vec![pct_to_pa_volume(clamped); sink_channels.max(1)];
                                        conn.set_sink_volume(&cur.sink_name, &cvol).await
                                    }
                                    AudioCmd::ToggleMute if !cur.sink_name.is_empty() => {
                                        conn.set_sink_mute(&cur.sink_name, !cur.muted).await
                                    }
                                    AudioCmd::ToggleMicMute if !cur.source_name.is_empty() => {
                                        conn.set_source_mute(&cur.source_name, !cur.mic_muted).await
                                    }
                                    AudioCmd::SetDefaultSink(ref name) => {
                                        conn.set_default_sink(name).await
                                    }
                                    AudioCmd::SetDefaultSource(ref name) => {
                                        conn.set_default_source(name).await
                                    }
                                    AudioCmd::SetStreamVolume { index, pct } => {
                                        conn.set_sink_input_volume(index, pct.min(PA_VOLUME_MAX_PCT)).await
                                    }
                                    AudioCmd::SetStreamMute { index, muted } => {
                                        conn.set_sink_input_mute(index, muted).await
                                    }
                                    _ => Ok(()),
                                };
                                if res.is_err() {
                                    break;
                                }
                                if let Ok((st, ch, mic_apps)) = conn.fetch_state().await {
                                    sink_channels = ch;
                                    let _ = privacy_tx.send(PrivacyUpdate::PulseMicApps(mic_apps));
                                    let trigger = match cmd {
                                        AudioCmd::StepVolume(_) | AudioCmd::ToggleMute => Some(OsdKind::Volume),
                                        AudioCmd::ToggleMicMute => Some(OsdKind::Mic),
                                        _ => None,
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
            Err(_) => {
                tokio::select! {
                    _ = tokio::time::sleep(backoff) => {
                        backoff = (backoff * 2).min(max_backoff);
                    }
                    cmd = cmd_rx.recv() => {
                        if cmd.is_none() {
                            if let Some(h) = spectrum_task.take() {
                                h.abort();
                            }
                            return;
                        }
                    }
                }
            }
        }
    }
}

async fn run_spectrum_monitor(
    event_tx: CalloopSender<SystemEvent>,
    monitor_source: String,
    fps: u32,
) {
    let Ok(sock) = pulse_socket_path().ok_or(()) else {
        return;
    };
    let Ok(stream) = UnixStream::connect(sock).await else {
        return;
    };
    let mut conn = PulseConn {
        stream,
        next_tag: 1,
    };
    let cookie = read_pulse_cookie();
    if conn
        .call(PA_COMMAND_AUTH, |w| {
            w.put_u32(PA_PROTOCOL_VERSION);
            w.put_arbitrary(&cookie);
        })
        .await
        .is_err()
    {
        return;
    }
    if conn
        .call(PA_COMMAND_SET_CLIENT_NAME, |w| {
            w.put_proplist(&[("application.name", "kaze-spectrum")]);
        })
        .await
        .is_err()
    {
        return;
    }

    let reply = conn
        .call(PA_COMMAND_CREATE_RECORD_STREAM, |w| {
            w.put_sample_spec(3, 1, 16_000); // PA_SAMPLE_S16LE=3, 1ch, 16kHz
            w.put_channel_map(&[0]);
            w.put_u32(PA_INVALID_INDEX);
            w.put_string(&monitor_source);
            w.put_u32(512 * 4); // maxlength
            w.put_bool(false); // corked
            w.put_u32(512); // fragsize
            w.put_u32(0); // syncid
            w.put_cvolume(&[PA_VOLUME_NORM]);
            w.put_bool(false); // no_remap
            w.put_bool(false); // no_remix
            w.put_bool(false); // fix_format
            w.put_bool(false); // fix_rate
            w.put_bool(false); // fix_channels
            w.put_bool(false); // no_move
            w.put_bool(false); // variable_rate
            w.put_bool(false); // peak_detect
            w.put_bool(true); // adjust_latency
            w.put_proplist(&[("media.name", "kaze-spectrum-fft")]);
            w.put_null_string();
        })
        .await;
    let Ok(reply_bytes) = reply else {
        return;
    };
    let mut r = TagReader::new(&reply_bytes);
    let stream_idx = r.read_u32().unwrap_or(0);
    let frame_period = Duration::from_millis((1000 / u64::from(fps.max(10))).max(16));
    let mut last_emit = tokio::time::Instant::now();
    let mut ring = Vec::<i16>::with_capacity(512);
    let mut header = [0u8; 20];

    loop {
        if conn.stream.read_exact(&mut header).await.is_err() {
            break;
        }
        let len = u32::from_be_bytes([header[0], header[1], header[2], header[3]]) as usize;
        let ch = u32::from_be_bytes([header[4], header[5], header[6], header[7]]);
        if len > 256 * 1024 {
            break;
        }
        let mut payload = vec![0u8; len];
        if len > 0 && conn.stream.read_exact(&mut payload).await.is_err() {
            break;
        }
        if ch != PA_INVALID_INDEX && payload.len() >= 2 {
            let (chunks, _) = payload.as_chunks::<2>();
            for chunk in chunks {
                ring.push(i16::from_le_bytes(*chunk));
            }
            if ring.len() > 512 {
                let excess = ring.len() - 512;
                ring.drain(..excess);
            }
            if ring.len() >= 256 && last_emit.elapsed() >= frame_period {
                let slice = &ring[ring.len() - 256..];
                let bars = compute_spectrum_bars(slice, 20);
                let _ = event_tx.send(SystemEvent::AudioSpectrum(bars));
                last_emit = tokio::time::Instant::now();
            }
        }
    }
    let _ = conn
        .call(PA_COMMAND_DELETE_RECORD_STREAM, |w| {
            w.put_u32(stream_idx);
        })
        .await;
    let _ = stream_mut_unused(&mut conn.stream).await;
}

async fn stream_mut_unused(_s: &mut UnixStream) {}

/// Pure-Rust 256-point Hann-windowed radix-2 Cooley-Tukey FFT binned into `n_bars` (`0..=100`).
pub fn compute_spectrum_bars(samples: &[i16], n_bars: usize) -> Vec<u8> {
    const N: usize = 256;
    if n_bars == 0 || samples.len() < N {
        return vec![0u8; n_bars];
    }
    let mut re = [0.0f32; N];
    let mut im = [0.0f32; N];
    for i in 0..N {
        let hann = 0.5 * (1.0 - ((2.0 * PI * i as f32) / ((N - 1) as f32)).cos());
        re[i] = (f32::from(samples[i]) / 32768.0) * hann;
    }

    // Bit-reversal permutation
    let mut j = 0usize;
    for i in 1..N {
        let mut bit = N >> 1;
        while (j & bit) != 0 {
            j ^= bit;
            bit >>= 1;
        }
        j ^= bit;
        if i < j {
            re.swap(i, j);
        }
    }

    // Butterfly stages
    let mut len = 2usize;
    while len <= N {
        let half = len / 2;
        let angle = -2.0 * PI / (len as f32);
        for start in (0..N).step_by(len) {
            for k in 0..half {
                let theta = angle * (k as f32);
                let (sin_t, cos_t) = theta.sin_cos();
                let u_re = re[start + k];
                let u_im = im[start + k];
                let v_re = re[start + k + half] * cos_t - im[start + k + half] * sin_t;
                let v_im = re[start + k + half] * sin_t + im[start + k + half] * cos_t;
                re[start + k] = u_re + v_re;
                im[start + k] = u_im + v_im;
                re[start + k + half] = u_re - v_re;
                im[start + k + half] = u_im - v_im;
            }
        }
        len <<= 1;
    }

    let usable = N / 2;
    let bins_per_bar = (usable / n_bars.max(1)).max(1);
    let mut bars = Vec::with_capacity(n_bars);
    for b in 0..n_bars {
        let lo = 1 + b * bins_per_bar;
        let hi = ((b + 1) * bins_per_bar + 1).min(usable);
        let mut peak = 0.0f32;
        for idx in lo..hi {
            let mag = (re[idx] * re[idx] + im[idx] * im[idx]).sqrt() / (N as f32 * 0.25);
            if mag > peak {
                peak = mag;
            }
        }
        bars.push((peak * 100.0).round().clamp(0.0, 100.0) as u8);
    }
    bars
}

fn compute_osd_trigger(prev: Option<&AudioState>, next: &AudioState) -> Option<OsdKind> {
    let prev = prev?;
    if prev.sink_name == next.sink_name
        && !next.sink_name.is_empty()
        && (prev.volume_pct != next.volume_pct || prev.muted != next.muted)
    {
        Some(OsdKind::Volume)
    } else if prev.source_name == next.source_name
        && !next.source_name.is_empty()
        && prev.mic_muted != next.mic_muted
    {
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

    #[test]
    fn fft_detects_sine_wave_frequency_peak() {
        let mut samples = [0i16; 256];
        for (i, slot) in samples.iter_mut().enumerate() {
            let phase = 2.0 * PI * 24.0 * (i as f32) / 256.0;
            *slot = (phase.sin() * 20_000.0) as i16;
        }
        let bars = compute_spectrum_bars(&samples, 20);
        assert_eq!(bars.len(), 20);
        let peak_idx = bars
            .iter()
            .enumerate()
            .max_by_key(|(_, &v)| v)
            .map(|(idx, _)| idx)
            .unwrap_or(0);
        assert!(
            (2..=5).contains(&peak_idx),
            "peak bar={peak_idx}, bars={bars:?}"
        );
    }
}
