use calloop::channel::Sender as CalloopSender;
use kaze_core::{DiskMountInfo, SysmonState, SystemEvent};
use std::fs;
use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::sync::mpsc;

#[derive(Default)]
struct CpuSample {
    total: u64,
    idle: u64,
}

#[derive(Default)]
struct NetSample {
    rx: u64,
    tx: u64,
}

/// Strictly on-demand `/proc` & `/sys` hardware sampler.
/// Sleeps indefinitely (`0.00%` CPU, `0` timers) whenever `subscribers == 0`.
pub async fn run_sysmon_task(
    event_tx: CalloopSender<SystemEvent>,
    mut cmd_rx: mpsc::UnboundedReceiver<usize>,
) {
    let mut subscribers = 0usize;
    let mut static_info_loaded = false;
    let mut base_state = SysmonState::default();
    let mut prev_cpus: Vec<CpuSample> = Vec::new();
    let mut prev_net: Option<NetSample> = None;

    loop {
        if subscribers == 0 {
            match cmd_rx.recv().await {
                Some(count) => {
                    subscribers = count;
                    if subscribers == 0 {
                        let _ = event_tx.send(SystemEvent::SysmonUpdated(SysmonState {
                            active: false,
                            ..base_state.clone()
                        }));
                    }
                    continue;
                }
                None => return,
            }
        }

        if !static_info_loaded {
            populate_static_info(&mut base_state);
            static_info_loaded = true;
        }

        let snap = collect_sample(&mut base_state, &mut prev_cpus, &mut prev_net);
        let _ = event_tx.send(SystemEvent::SysmonUpdated(snap));

        tokio::select! {
            maybe_count = cmd_rx.recv() => {
                match maybe_count {
                    Some(count) => {
                        subscribers = count;
                        if subscribers == 0 {
                            prev_cpus.clear();
                            prev_net = None;
                            let _ = event_tx.send(SystemEvent::SysmonUpdated(SysmonState {
                                active: false,
                                ..base_state.clone()
                            }));
                        }
                    }
                    None => return,
                }
            }
            _ = tokio::time::sleep(Duration::from_secs(1)) => {}
        }
    }
}

fn populate_static_info(state: &mut SysmonState) {
    if let Ok(os) = fs::read_to_string("/etc/os-release") {
        for line in os.lines() {
            if let Some(val) = line.strip_prefix("PRETTY_NAME=") {
                state.distro = val.trim_matches('"').to_string();
                break;
            }
        }
    }
    if let Ok(ver) = fs::read_to_string("/proc/sys/kernel/osrelease") {
        state.kernel = ver.trim().to_string();
    }
    if let Ok(cpu) = fs::read_to_string("/proc/cpuinfo") {
        for line in cpu.lines() {
            if let Some((_, val)) = line.split_once(':') {
                if line.starts_with("model name") {
                    state.cpu_model = val.trim().to_string();
                    break;
                }
            }
        }
    }
    state.gpu_model = read_gpu_name().unwrap_or_else(|| "Unknown GPU".to_string());
    state.install_age_days = read_install_age_days();
}

fn read_gpu_name() -> Option<String> {
    let entries = fs::read_dir("/sys/class/drm").ok()?;
    for entry in entries.flatten() {
        let name = entry.file_name();
        let s = name.to_string_lossy();
        if !s.starts_with("card") || s.contains('-') {
            continue;
        }
        let dev = entry.path().join("device");
        let vendor = fs::read_to_string(dev.join("vendor")).ok()?;
        let v = vendor.trim();
        let label = match v {
            "0x8086" => "Intel Graphics",
            "0x1002" => "AMD Radeon",
            "0x10de" => "NVIDIA GeForce",
            "0x1af4" | "0x1234" => "Virtual GPU",
            _ => "DRM GPU",
        };
        return Some(label.to_string());
    }
    None
}

fn read_install_age_days() -> Option<u64> {
    let now_secs = SystemTime::now().duration_since(UNIX_EPOCH).ok()?.as_secs();
    if let Ok(meta) = fs::metadata("/") {
        if let Ok(created) = meta.created() {
            if let Ok(age) = SystemTime::now().duration_since(created) {
                return Some(age.as_secs() / 86_400);
            }
        }
    }
    if let Ok(log) = fs::read_to_string("/var/log/pacman.log") {
        if let Some(first) = log.lines().next() {
            if let Some(ts) = first.strip_prefix('[') {
                if let Some((date_s, _)) = ts.split_once('T') {
                    if let Some(days) = days_since_ymd(date_s, now_secs) {
                        return Some(days);
                    }
                }
            }
        }
    }
    None
}

fn days_since_ymd(ymd: &str, now_secs: u64) -> Option<u64> {
    let mut parts = ymd.split('-');
    let y: i64 = parts.next()?.parse().ok()?;
    let m: i64 = parts.next()?.parse().ok()?;
    let d: i64 = parts.next()?.parse().ok()?;
    let days_epoch = days_from_civil(y, m, d);
    let now_days = (now_secs / 86_400) as i64;
    Some(now_days.saturating_sub(days_epoch).max(0) as u64)
}

fn days_from_civil(mut y: i64, m: i64, d: i64) -> i64 {
    y -= i64::from(m <= 2);
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (m + if m > 2 { -3 } else { 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

fn collect_sample(
    base: &mut SysmonState,
    prev_cpus: &mut Vec<CpuSample>,
    prev_net: &mut Option<NetSample>,
) -> SysmonState {
    base.active = true;
    if let Ok(up) = fs::read_to_string("/proc/uptime") {
        if let Some(secs_s) = up.split_whitespace().next() {
            base.uptime_secs = secs_s.parse::<f64>().unwrap_or(0.0) as u64;
        }
    }

    // CPU total + per-core
    let cur_cpus = read_cpu_samples();
    if prev_cpus.len() == cur_cpus.len() && !cur_cpus.is_empty() {
        let mut per_core = Vec::with_capacity(cur_cpus.len().saturating_sub(1));
        for (idx, (prev, cur)) in prev_cpus.iter().zip(cur_cpus.iter()).enumerate() {
            let dt = cur.total.saturating_sub(prev.total);
            let di = cur.idle.saturating_sub(prev.idle);
            let pct = if dt > 0 {
                ((dt.saturating_sub(di)) as f32 / dt as f32) * 100.0
            } else {
                0.0
            };
            if idx == 0 {
                base.cpu_pct = pct.clamp(0.0, 100.0);
                base.cpu_history.push(base.cpu_pct);
                if base.cpu_history.len() > 60 {
                    let drop_n = base.cpu_history.len() - 60;
                    base.cpu_history.drain(..drop_n);
                }
            } else {
                per_core.push(pct.clamp(0.0, 100.0));
            }
        }
        base.per_core_pct = per_core;
    }
    *prev_cpus = cur_cpus;

    // Memory / Swap / ZRAM
    if let Ok(mem) = fs::read_to_string("/proc/meminfo") {
        let mut total_kib = 0u64;
        let mut avail_kib = 0u64;
        let mut swap_total_kib = 0u64;
        let mut swap_free_kib = 0u64;
        for line in mem.lines() {
            if let Some((k, rest)) = line.split_once(':') {
                let val = rest
                    .split_whitespace()
                    .next()
                    .and_then(|s| s.parse::<u64>().ok())
                    .unwrap_or(0);
                match k {
                    "MemTotal" => total_kib = val,
                    "MemAvailable" => avail_kib = val,
                    "SwapTotal" => swap_total_kib = val,
                    "SwapFree" => swap_free_kib = val,
                    _ => {}
                }
            }
        }
        base.ram_total_mib = total_kib / 1024;
        base.ram_used_mib = total_kib.saturating_sub(avail_kib) / 1024;
        base.swap_total_mib = swap_total_kib / 1024;
        base.swap_used_mib = swap_total_kib.saturating_sub(swap_free_kib) / 1024;
    }
    base.zram_used_mib = read_zram_used_mib();
    base.temp_c = read_cpu_temp_c();

    // Net RX/TX bytes per sec
    if let Some(cur_n) = read_net_totals() {
        if let Some(prev_n) = prev_net.as_ref() {
            base.net_rx_bps = cur_n.rx.saturating_sub(prev_n.rx);
            base.net_tx_bps = cur_n.tx.saturating_sub(prev_n.tx);
        }
        *prev_net = Some(cur_n);
    }

    base.disks = read_disk_mounts();
    base.clone()
}

fn read_cpu_samples() -> Vec<CpuSample> {
    let Ok(raw) = fs::read_to_string("/proc/stat") else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for line in raw.lines() {
        if !line.starts_with("cpu") {
            break;
        }
        let mut parts = line.split_whitespace();
        let Some(tag) = parts.next() else { continue };
        if tag != "cpu" && !tag[3..].bytes().all(|b| b.is_ascii_digit()) {
            continue;
        }
        let nums: Vec<u64> = parts.filter_map(|s| s.parse::<u64>().ok()).collect();
        if nums.len() >= 4 {
            let idle = nums[3].saturating_add(*nums.get(4).unwrap_or(&0));
            let total: u64 = nums.iter().sum();
            out.push(CpuSample { total, idle });
        }
    }
    out
}

fn read_zram_used_mib() -> u64 {
    let Ok(entries) = fs::read_dir("/sys/block") else {
        return 0;
    };
    let mut total_bytes = 0u64;
    for entry in entries.flatten() {
        let name = entry.file_name();
        if !name.to_string_lossy().starts_with("zram") {
            continue;
        }
        if let Ok(stat) = fs::read_to_string(entry.path().join("mm_stat")) {
            if let Some(first) = stat.split_whitespace().next() {
                total_bytes = total_bytes.saturating_add(first.parse::<u64>().unwrap_or(0));
            }
        }
    }
    total_bytes / (1024 * 1024)
}

fn read_cpu_temp_c() -> Option<f32> {
    let entries = fs::read_dir("/sys/class/thermal").ok()?;
    let mut best: Option<f32> = None;
    for entry in entries.flatten() {
        if !entry
            .file_name()
            .to_string_lossy()
            .starts_with("thermal_zone")
        {
            continue;
        }
        let temp_raw = fs::read_to_string(entry.path().join("temp")).ok();
        let kind = fs::read_to_string(entry.path().join("type"))
            .unwrap_or_default()
            .to_ascii_lowercase();
        if let Some(val) = temp_raw.and_then(|s| s.trim().parse::<f32>().ok()) {
            let c = val / 1000.0;
            if (5.0..=125.0).contains(&c) {
                if kind.contains("x86_pkg") || kind.contains("cpu") || kind.contains("k10temp") {
                    return Some(c);
                }
                if best.is_none() {
                    best = Some(c);
                }
            }
        }
    }
    best
}

fn read_net_totals() -> Option<NetSample> {
    let raw = fs::read_to_string("/proc/net/dev").ok()?;
    let mut rx = 0u64;
    let mut tx = 0u64;
    for line in raw.lines().skip(2) {
        let Some((iface, rest)) = line.split_once(':') else {
            continue;
        };
        if iface.trim() == "lo" {
            continue;
        }
        let cols: Vec<u64> = rest
            .split_whitespace()
            .filter_map(|s| s.parse::<u64>().ok())
            .collect();
        if cols.len() >= 9 {
            rx = rx.saturating_add(cols[0]);
            tx = tx.saturating_add(cols[8]);
        }
    }
    Some(NetSample { rx, tx })
}

fn read_disk_mounts() -> Vec<DiskMountInfo> {
    let Ok(raw) = fs::read_to_string("/proc/self/mounts") else {
        return Vec::new();
    };
    let mut mounts = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for line in raw.lines() {
        let cols: Vec<&str> = line.split_whitespace().collect();
        if cols.len() < 3 {
            continue;
        }
        let dev = cols[0];
        let mp = cols[1];
        if !dev.starts_with("/dev/") || !seen.insert(mp.to_string()) {
            continue;
        }
        if let Some((used, total)) = statvfs_gib(Path::new(mp)) {
            if total > 0.1 {
                mounts.push(DiskMountInfo {
                    mount: mp.to_string(),
                    used_gib: used,
                    total_gib: total,
                });
            }
        }
        if mounts.len() >= 4 {
            break;
        }
    }
    mounts
}

fn statvfs_gib(path: &Path) -> Option<(f32, f32)> {
    let c_path = std::ffi::CString::new(path.to_str()?).ok()?;
    let mut vfs = std::mem::MaybeUninit::<libc::statvfs>::zeroed();
    // SAFETY: `c_path` is NUL-terminated and `vfs` is stack-allocated.
    let rc = unsafe { libc::statvfs(c_path.as_ptr(), vfs.as_mut_ptr()) };
    if rc != 0 {
        return None;
    }
    // SAFETY: `statvfs` succeeded and initialized `vfs`.
    let vfs = unsafe { vfs.assume_init() };
    let frsize = vfs.f_frsize as f64;
    let total = (vfs.f_blocks as f64) * frsize;
    let avail = (vfs.f_bavail as f64) * frsize;
    let used = (total - avail).max(0.0);
    let gib = 1024.0 * 1024.0 * 1024.0;
    Some(((used / gib) as f32, (total / gib) as f32))
}
