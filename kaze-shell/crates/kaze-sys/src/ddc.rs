use kaze_core::BrightnessConfig;
use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::fd::AsRawFd;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;
use tokio::sync::mpsc;

const I2C_SLAVE: libc::c_ulong = 0x0703;
const DDC_ADDR: libc::c_ulong = 0x37;
const VCP_LUMINANCE: u8 = 0x10;
static LOGGED_MISSING_I2C: AtomicBool = AtomicBool::new(false);

pub fn encode_ddc_vcp_set(vcp_code: u8, value: u16) -> [u8; 7] {
    let hi = (value >> 8) as u8;
    let lo = (value & 0xff) as u8;
    // Host-to-monitor DDC/CI packet: [0x51, 0x84, 0x03, vcp, hi, lo, chk]
    // Checksum XOR seed includes write address (0x6e = 0x37 << 1).
    let mut chk = 0x6eu8;
    let mut pkt = [0x51u8, 0x84, 0x03, vcp_code, hi, lo, 0];
    for &b in &pkt[..6] {
        chk ^= b;
    }
    pkt[6] = chk;
    pkt
}

pub fn discover_i2c_buses() -> Vec<PathBuf> {
    let Ok(entries) = fs::read_dir("/dev") else {
        return Vec::new();
    };
    let mut paths: Vec<PathBuf> = entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.starts_with("i2c-"))
        })
        .collect();
    paths.sort();
    paths
}

fn write_vcp_blocking(dev_path: &PathBuf, pct: u8) -> Result<(), String> {
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .open(dev_path)
        .map_err(|e| format!("open {} failed: {e}", dev_path.display()))?;
    // SAFETY: valid open i2c device FD + `I2C_SLAVE` ioctl.
    let rc = unsafe { libc::ioctl(file.as_raw_fd(), I2C_SLAVE, DDC_ADDR) };
    if rc < 0 {
        return Err(format!("ioctl I2C_SLAVE on {} failed", dev_path.display()));
    }
    let pkt = encode_ddc_vcp_set(VCP_LUMINANCE, u16::from(pct.clamp(0, 100)));
    let mut f = file;
    f.write_all(&pkt)
        .map_err(|e| format!("i2c write {} failed: {e}", dev_path.display()))?;
    Ok(())
}

pub struct DdcRequest {
    pub monitor: String,
    pub pct: u8,
    pub cfg: BrightnessConfig,
}

/// Event-driven DDC/CI worker (0 polling): coalesces rapid slider drags over a 100ms window
/// and enforces a hard `< 500ms` timeout per I2C transaction so unplugged monitors never hang.
pub async fn run_ddc_task(mut rx: mpsc::UnboundedReceiver<DdcRequest>) {
    let mut pending: HashMap<String, (u8, BrightnessConfig)> = HashMap::new();
    loop {
        if pending.is_empty() {
            let Some(req) = rx.recv().await else {
                return;
            };
            pending.insert(req.monitor, (req.pct, req.cfg));
            continue;
        }

        // Coalesce burst slider events over 100ms before issuing I2C write.
        let sleep = tokio::time::sleep(Duration::from_millis(100));
        tokio::pin!(sleep);
        loop {
            tokio::select! {
                _ = &mut sleep => break,
                maybe_req = rx.recv() => {
                    match maybe_req {
                        Some(req) => {
                            pending.insert(req.monitor, (req.pct, req.cfg));
                        }
                        None => return,
                    }
                }
            }
        }

        let batch = std::mem::take(&mut pending);
        for (monitor, (raw_pct, cfg)) in batch {
            let buses = if let Some(mon_cfg) = cfg.monitors.get(&monitor) {
                let min = mon_cfg.min_pct.min(100);
                let max = if mon_cfg.max_pct == 0 { 100 } else { mon_cfg.max_pct.min(100) };
                let scaled = raw_pct.clamp(min, max.max(min));
                if let Some(bus_id) = mon_cfg.i2c_bus {
                    let p = PathBuf::from(format!("/dev/i2c-{bus_id}"));
                    if p.exists() { vec![(p, scaled)] } else { Vec::new() }
                } else {
                    discover_i2c_buses()
                        .into_iter()
                        .map(|p| (p, scaled))
                        .collect()
                }
            } else {
                discover_i2c_buses()
                    .into_iter()
                    .map(|p| (p, raw_pct.clamp(0, 100)))
                    .collect()
            };

            if buses.is_empty() {
                if !LOGGED_MISSING_I2C.swap(true, Ordering::Relaxed) {
                    // Silent graceful skip on VMs / hardware without accessible `/dev/i2c-*`.
                }
                continue;
            }

            for (bus_path, val) in buses {
                let fut = tokio::task::spawn_blocking(move || write_vcp_blocking(&bus_path, val));
                let _ = tokio::time::timeout(Duration::from_millis(450), fut).await;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ddc_vcp_packet_encodes_valid_xor_checksum() {
        let pkt = encode_ddc_vcp_set(VCP_LUMINANCE, 50);
        assert_eq!(pkt[..6], [0x51, 0x84, 0x03, 0x10, 0x00, 50]);
        let mut chk = 0x6eu8;
        for &b in &pkt {
            chk ^= b;
        }
        assert_eq!(chk, 0);
    }
}
