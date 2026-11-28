use calloop::channel::Sender as CalloopSender;
use kaze_core::crypto::{
    check_network_allowed, default_master_key_path, load_or_create_keyfile, EncryptedRecordStore,
    MasterKey,
};
use kaze_core::layout::xdg_state_home;
use kaze_core::{CalendarConfig, CalendarEvent, CalendarSourceStatus, CalendarState, SystemEvent};
use notify::{EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::process::Command;
use tokio::sync::mpsc;

#[derive(Debug, Clone)]
pub enum CalendarCmd {
    Configure {
        cfg: CalendarConfig,
        offline_mode: bool,
        oauth_token: Option<String>,
    },
    SetOfflineMode(bool),
    SyncNow,
}

#[derive(Debug, Clone)]
pub struct ReminderTarget {
    pub fire_epoch_secs: u64,
    pub event_uid: String,
    pub title: String,
    pub mins_before: u32,
}

pub fn default_calendar_cache_path() -> Result<PathBuf, String> {
    Ok(xdg_state_home()?.join("kaze").join("calendar.enc"))
}

pub fn load_cached_calendar(path: &Path, key: &MasterKey) -> Option<CalendarState> {
    let (records, _) = EncryptedRecordStore::load_records(path, key);
    let first = records.first()?;
    serde_json::from_slice(first).ok()
}

pub fn save_cached_calendar(path: &Path, key: &MasterKey, state: &CalendarState) {
    if let Ok(bytes) = serde_json::to_vec(state) {
        let _ = EncryptedRecordStore::save_records(path, key, &[bytes.as_slice()]);
    }
}

/// Computes the earliest upcoming reminder timestamp so `daemon.rs` schedules ONE single `calloop` timer.
pub fn next_reminder_fire(
    state: &CalendarState,
    now_epoch_secs: u64,
    default_lead_mins: u32,
) -> Option<ReminderTarget> {
    let now_i = now_epoch_secs as i64;
    let mut best: Option<ReminderTarget> = None;
    for ev in &state.events {
        let lead_mins = ev.reminder_mins.unwrap_or(default_lead_mins);
        let fire_at = ev.start_epoch_secs - i64::from(lead_mins) * 60;
        let clamped_fire = fire_at.max(now_i);
        if ev.start_epoch_secs >= now_i && fire_at >= now_i - 30 {
            let candidate = ReminderTarget {
                fire_epoch_secs: clamped_fire as u64,
                event_uid: ev.uid.clone(),
                title: ev.title.clone(),
                mins_before: lead_mins,
            };
            if best
                .as_ref()
                .is_none_or(|b| candidate.fire_epoch_secs < b.fire_epoch_secs)
            {
                best = Some(candidate);
            }
        }
    }
    best
}

/// Pure-Rust RFC 5545 `.ics` parser handling `VEVENT`, `UID`, `SUMMARY`, `LOCATION`,
/// `DTSTART`, `DTEND`, basic `RRULE` (`DAILY`/`WEEKLY`/`MONTHLY` + `COUNT`/`UNTIL`),
/// and `VALARM` relative `TRIGGER` (`-PT...M` / `-PT...H`).
pub fn parse_ics_events(raw: &str, source_id: &str, default_lead_mins: u32) -> Vec<CalendarEvent> {
    let mut unfolded: Vec<String> = Vec::new();
    for line in raw.replace("\r\n", "\n").lines() {
        if let Some(rest) = line.strip_prefix(' ').or_else(|| line.strip_prefix('\t')) {
            if let Some(last) = unfolded.last_mut() {
                last.push_str(rest);
                continue;
            }
        }
        unfolded.push(line.to_string());
    }

    let mut out = Vec::new();
    let mut in_event = false;
    let mut in_alarm = false;
    let mut uid = String::new();
    let mut summary = String::new();
    let mut location = String::new();
    let mut dtstart: Option<(i64, bool)> = None;
    let mut dtend: Option<(i64, bool)> = None;
    let mut rrule = String::new();
    let mut alarm_mins: Option<u32> = None;

    for line in unfolded {
        let t = line.trim();
        if t.eq_ignore_ascii_case("BEGIN:VEVENT") {
            in_event = true;
            in_alarm = false;
            uid.clear();
            summary.clear();
            location.clear();
            dtstart = None;
            dtend = None;
            rrule.clear();
            alarm_mins = None;
            continue;
        }
        if t.eq_ignore_ascii_case("END:VEVENT") {
            if in_event {
                if let Some((start_secs, all_day)) = dtstart {
                    let end_secs = dtend.map_or(start_secs + 3600, |(e, _)| e);
                    let dur = (end_secs - start_secs).max(0);
                    let mut instances = expand_rrule(start_secs, &rrule);
                    if instances.is_empty() {
                        instances.push(start_secs);
                    }
                    for (idx, inst_start) in instances.into_iter().enumerate() {
                        let inst_uid = if idx == 0 {
                            uid.clone()
                        } else {
                            format!("{uid}#{idx}")
                        };
                        out.push(CalendarEvent {
                            uid: if inst_uid.is_empty() {
                                format!("{source_id}:{inst_start}")
                            } else {
                                inst_uid
                            },
                            source_id: source_id.to_string(),
                            title: if summary.is_empty() {
                                "(Untitled)".to_string()
                            } else {
                                summary.clone()
                            },
                            location: location.clone(),
                            start_epoch_secs: inst_start,
                            end_epoch_secs: inst_start + dur,
                            all_day,
                            reminder_mins: alarm_mins.or(Some(default_lead_mins)),
                        });
                    }
                }
            }
            in_event = false;
            in_alarm = false;
            continue;
        }
        if !in_event {
            continue;
        }
        if t.eq_ignore_ascii_case("BEGIN:VALARM") {
            in_alarm = true;
            continue;
        }
        if t.eq_ignore_ascii_case("END:VALARM") {
            in_alarm = false;
            continue;
        }
        let Some((lhs, val)) = t.split_once(':') else {
            continue;
        };
        let prop_name = lhs.split(';').next().unwrap_or(lhs).to_ascii_uppercase();
        if in_alarm {
            if prop_name == "TRIGGER" {
                alarm_mins = parse_valarm_trigger_mins(val);
            }
            continue;
        }
        match prop_name.as_str() {
            "UID" => uid = val.trim().to_string(),
            "SUMMARY" => summary = unescape_ics_text(val.trim()),
            "LOCATION" => location = unescape_ics_text(val.trim()),
            "DTSTART" => dtstart = parse_ics_datetime(val.trim()),
            "DTEND" => dtend = parse_ics_datetime(val.trim()),
            "RRULE" => rrule = val.trim().to_string(),
            _ => {}
        }
    }
    out
}

fn unescape_ics_text(s: &str) -> String {
    s.replace("\\n", " ")
        .replace("\\,", ",")
        .replace("\\;", ";")
        .replace("\\\\", "\\")
}

fn parse_valarm_trigger_mins(raw: &str) -> Option<u32> {
    let s = raw.trim().trim_start_matches('-').to_ascii_uppercase();
    let rest = s.strip_prefix("PT").or_else(|| s.strip_prefix('P'))?;
    if let Some(m) = rest.strip_suffix('M') {
        return m.parse::<u32>().ok();
    }
    if let Some(h) = rest.strip_suffix('H') {
        return h.parse::<u32>().ok().map(|v| v * 60);
    }
    if let Some(d) = rest.strip_suffix('D') {
        return d.parse::<u32>().ok().map(|v| v * 1440);
    }
    None
}

fn parse_ics_datetime(raw: &str) -> Option<(i64, bool)> {
    let clean = raw.trim().trim_end_matches('Z');
    if clean.len() == 8 && clean.chars().all(|c| c.is_ascii_digit()) {
        let y: i32 = clean[0..4].parse().ok()?;
        let m: u32 = clean[4..6].parse().ok()?;
        let d: u32 = clean[6..8].parse().ok()?;
        return Some((civil_to_epoch(y, m, d, 0, 0, 0), true));
    }
    if clean.len() >= 15 && clean.as_bytes()[8] == b'T' {
        let y: i32 = clean[0..4].parse().ok()?;
        let m: u32 = clean[4..6].parse().ok()?;
        let d: u32 = clean[6..8].parse().ok()?;
        let hh: u32 = clean[9..11].parse().ok()?;
        let mm: u32 = clean[11..13].parse().ok()?;
        let ss: u32 = clean[13..15].parse().ok()?;
        return Some((civil_to_epoch(y, m, d, hh, mm, ss), false));
    }
    None
}

/// Converts proleptic Gregorian UTC civil timestamp to Unix epoch seconds cleanly in pure Rust.
fn civil_to_epoch(year: i32, month: u32, day: u32, hh: u32, mm: u32, ss: u32) -> i64 {
    let y = i64::from(year) - if month <= 2 { 1 } else { 0 };
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let m = i64::from(month);
    let doy = (153 * (m + if m > 2 { -3 } else { 9 }) + 2) / 5 + i64::from(day) - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    days * 86_400 + i64::from(hh) * 3600 + i64::from(mm) * 60 + i64::from(ss)
}

fn expand_rrule(start_secs: i64, rrule: &str) -> Vec<i64> {
    if rrule.trim().is_empty() {
        return vec![start_secs];
    }
    let mut freq = "";
    let mut count: usize = 8;
    let mut until: Option<i64> = None;
    for part in rrule.split(';') {
        if let Some((k, v)) = part.split_once('=') {
            match k.trim().to_ascii_uppercase().as_str() {
                "FREQ" => freq = v.trim(),
                "COUNT" => count = v.trim().parse::<usize>().unwrap_or(8).clamp(1, 32),
                "UNTIL" => until = parse_ics_datetime(v.trim()).map(|(t, _)| t),
                _ => {}
            }
        }
    }
    let step_secs: i64 = match freq.to_ascii_uppercase().as_str() {
        "DAILY" => 86_400,
        "WEEKLY" => 7 * 86_400,
        "MONTHLY" => 30 * 86_400,
        _ => return vec![start_secs],
    };
    let mut out = Vec::new();
    for i in 0..count {
        let ts = start_secs + (i as i64) * step_secs;
        if until.is_some_and(|u| ts > u) {
            break;
        }
        out.push(ts);
    }
    out
}

pub fn load_vdir_events(
    dir: &Path,
    source_id: &str,
    lead_mins: u32,
) -> Result<Vec<CalendarEvent>, String> {
    let entries = fs::read_dir(dir).map_err(|e| format!("vdir read error: {e}"))?;
    let mut events = Vec::new();
    for entry in entries.flatten() {
        let p = entry.path();
        if p.extension().and_then(|e| e.to_str()) == Some("ics") {
            if let Ok(raw) = fs::read_to_string(&p) {
                events.extend(parse_ics_events(&raw, source_id, lead_mins));
            }
        }
    }
    Ok(events)
}

async fn sync_all_sources(
    cfg: &CalendarConfig,
    offline_mode: bool,
    oauth_token: Option<&str>,
    cache_path: Option<&Path>,
    master_key: Option<&MasterKey>,
) -> CalendarState {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let mut events = Vec::new();
    let mut sources = Vec::new();

    for (idx, vdir) in cfg.vdir_paths.iter().enumerate() {
        let id = format!("vdir:{idx}");
        match load_vdir_events(Path::new(vdir), &id, cfg.reminder_lead_mins) {
            Ok(mut evs) => {
                events.append(&mut evs);
                sources.push(CalendarSourceStatus {
                    id,
                    name: vdir.clone(),
                    kind: "vdir".into(),
                    ok: true,
                    last_sync_epoch_secs: now,
                    error: None,
                });
            }
            Err(err) => {
                sources.push(CalendarSourceStatus {
                    id,
                    name: vdir.clone(),
                    kind: "vdir".into(),
                    ok: false,
                    last_sync_epoch_secs: now,
                    error: Some(err),
                });
            }
        }
    }

    let remote_allowed = check_network_allowed(offline_mode).is_ok();
    for (idx, url) in cfg.ics_urls.iter().enumerate() {
        let id = format!("ics:{idx}");
        if !remote_allowed {
            sources.push(CalendarSourceStatus {
                id,
                name: url.clone(),
                kind: "ics".into(),
                ok: false,
                last_sync_epoch_secs: now,
                error: Some("offline_mode".into()),
            });
            continue;
        }
        match fetch_ics_url(url, None, None, None).await {
            Ok(raw) => {
                events.extend(parse_ics_events(&raw, &id, cfg.reminder_lead_mins));
                sources.push(CalendarSourceStatus {
                    id,
                    name: url.clone(),
                    kind: "ics".into(),
                    ok: true,
                    last_sync_epoch_secs: now,
                    error: None,
                });
            }
            Err(err) => sources.push(CalendarSourceStatus {
                id,
                name: url.clone(),
                kind: "ics".into(),
                ok: false,
                last_sync_epoch_secs: now,
                error: Some(err),
            }),
        }
    }

    for (idx, url) in cfg.caldav_urls.iter().enumerate() {
        let id = format!("caldav:{idx}");
        if !remote_allowed {
            sources.push(CalendarSourceStatus {
                id,
                name: url.clone(),
                kind: "caldav".into(),
                ok: false,
                last_sync_epoch_secs: now,
                error: Some("offline_mode".into()),
            });
            continue;
        }
        let cert =
            (!cfg.caldav_client_cert.trim().is_empty()).then_some(cfg.caldav_client_cert.as_str());
        let key =
            (!cfg.caldav_client_key.trim().is_empty()).then_some(cfg.caldav_client_key.as_str());
        match fetch_ics_url(url, cert, key, oauth_token).await {
            Ok(raw) => {
                events.extend(parse_ics_events(&raw, &id, cfg.reminder_lead_mins));
                sources.push(CalendarSourceStatus {
                    id,
                    name: url.clone(),
                    kind: "caldav".into(),
                    ok: true,
                    last_sync_epoch_secs: now,
                    error: None,
                });
            }
            Err(err) => sources.push(CalendarSourceStatus {
                id,
                name: url.clone(),
                kind: "caldav".into(),
                ok: false,
                last_sync_epoch_secs: now,
                error: Some(err),
            }),
        }
    }

    events.sort_by_key(|e| e.start_epoch_secs);
    let mut state = CalendarState { events, sources };
    if state.events.is_empty() {
        if let (Some(cp), Some(mk)) = (cache_path, master_key) {
            if let Some(cached) = load_cached_calendar(cp, mk) {
                state.events = cached.events;
            }
        }
    } else if let (Some(cp), Some(mk)) = (cache_path, master_key) {
        save_cached_calendar(cp, mk, &state);
    }
    state
}

async fn fetch_ics_url(
    url: &str,
    cert: Option<&str>,
    key: Option<&str>,
    bearer: Option<&str>,
) -> Result<String, String> {
    let mut args = vec![
        "-fsSL".to_string(),
        "--max-time".to_string(),
        "12".to_string(),
    ];
    if let (Some(c), Some(k)) = (cert, key) {
        args.push("--cert".to_string());
        args.push(c.to_string());
        args.push("--key".to_string());
        args.push(k.to_string());
    }
    if let Some(tok) = bearer {
        args.push("-H".to_string());
        args.push(format!("Authorization: Bearer {tok}"));
    }
    args.push(url.to_string());
    let out = Command::new("curl")
        .args(&args)
        .output()
        .await
        .map_err(|e| format!("curl error: {e}"))?;
    if !out.status.success() {
        return Err(format!("HTTP sync failed ({})", out.status));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

pub async fn run_calendar_task(
    event_tx: CalloopSender<SystemEvent>,
    mut cmd_rx: mpsc::UnboundedReceiver<CalendarCmd>,
    cache_path: Option<PathBuf>,
) {
    let mut cfg = CalendarConfig::default();
    let mut offline_mode = true;
    let mut oauth_token: Option<String> = None;
    let mut master_key: Option<MasterKey> = None;
    let mut cache_loaded = false;
    let (vdir_tx, mut vdir_rx) = mpsc::unbounded_channel::<()>();
    let mut _watcher: Option<RecommendedWatcher> = None;

    loop {
        let sleep_dur = if !cfg.enabled {
            Duration::from_secs(86400 * 365)
        } else {
            Duration::from_secs(cfg.sync_interval_mins.max(5) * 60)
        };
        let should_sync = tokio::select! {
            cmd = cmd_rx.recv() => {
                let Some(cmd) = cmd else { break; };
                match cmd {
                    CalendarCmd::Configure { cfg: next, offline_mode: om, oauth_token: tok } => {
                        cfg = next;
                        offline_mode = om;
                        oauth_token = tok;
                        if cfg.enabled {
                            if master_key.is_none() {
                                master_key = default_master_key_path()
                                    .ok()
                                    .and_then(|kp| load_or_create_keyfile(&kp).ok());
                            }
                            if !cache_loaded {
                                cache_loaded = true;
                                if let (Some(ref cp), Some(ref mk)) = (&cache_path, &master_key) {
                                    if let Some(cached) = load_cached_calendar(cp, mk) {
                                        let _ = event_tx.send(SystemEvent::CalendarUpdated(cached));
                                    }
                                }
                            }
                            _watcher = build_vdir_watcher(&cfg.vdir_paths, vdir_tx.clone());
                        } else {
                            _watcher = None;
                        }
                        cfg.enabled
                    }
                    CalendarCmd::SetOfflineMode(om) => {
                        offline_mode = om;
                        false
                    }
                    CalendarCmd::SyncNow => cfg.enabled,
                }
            }
            ev = vdir_rx.recv(), if cfg.enabled => ev.is_some(),
            _ = tokio::time::sleep(sleep_dur), if cfg.enabled => true,
        };
        if !should_sync {
            continue;
        }
        let st = sync_all_sources(
            &cfg,
            offline_mode,
            oauth_token.as_deref(),
            cache_path.as_deref(),
            master_key.as_ref(),
        )
        .await;
        let _ = event_tx.send(SystemEvent::CalendarUpdated(st));
    }
}

fn build_vdir_watcher(
    vdirs: &[String],
    tx: mpsc::UnboundedSender<()>,
) -> Option<RecommendedWatcher> {
    if vdirs.is_empty() {
        return None;
    }
    let mut watcher = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
        if let Ok(ev) = res {
            if matches!(
                ev.kind,
                EventKind::Modify(_) | EventKind::Create(_) | EventKind::Remove(_)
            ) {
                let _ = tx.send(());
            }
        }
    })
    .ok()?;
    let mut any = false;
    for dir in vdirs {
        let p = Path::new(dir);
        if p.is_dir() && watcher.watch(p, RecursiveMode::NonRecursive).is_ok() {
            any = true;
        }
    }
    if any {
        Some(watcher)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_ics_rrule_valarm_and_offline_cache_roundtrip() {
        let ics = "\
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:standup-1
SUMMARY:Daily Standup
LOCATION:Room 101
DTSTART:20261128T090000Z
DTEND:20261128T093000Z
RRULE:FREQ=DAILY;COUNT=3
BEGIN:VALARM
TRIGGER:-PT10M
END:VALARM
END:VEVENT
END:VCALENDAR";

        let events = parse_ics_events(ics, "local:0", 15);
        assert_eq!(events.len(), 3);
        assert_eq!(events[0].title, "Daily Standup");
        assert_eq!(events[0].reminder_mins, Some(10));
        assert_eq!(
            events[1].start_epoch_secs - events[0].start_epoch_secs,
            86_400
        );

        let st = CalendarState {
            events: events.clone(),
            sources: vec![],
        };
        let rem = next_reminder_fire(&st, (events[0].start_epoch_secs - 900) as u64, 15)
            .expect("reminder target");
        assert_eq!(rem.event_uid, "standup-1");
        assert_eq!(
            rem.fire_epoch_secs,
            (events[0].start_epoch_secs - 600) as u64
        );

        let dir = std::env::temp_dir().join(format!("kaze-cal-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let cache = dir.join("cal.enc");
        let mk = MasterKey::generate();
        save_cached_calendar(&cache, &mk, &st);
        let loaded = load_cached_calendar(&cache, &mk).expect("load encrypted cal");
        assert_eq!(loaded.events.len(), 3);
        let _ = fs::remove_dir_all(&dir);
    }
}
