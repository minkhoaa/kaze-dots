use std::f64::consts::PI;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SolarTransition {
    pub is_daytime: bool,
    pub next_transition_in: Duration,
    pub used_fallback: bool,
}

pub fn parse_hhmm_minutes(s: &str, default_mins: u32) -> u32 {
    let trimmed = s.trim();
    if let Some((hh, mm)) = trimmed.split_once(':') {
        if let (Ok(h), Ok(m)) = (hh.trim().parse::<u32>(), mm.trim().parse::<u32>()) {
            if h < 24 && m < 60 {
                return h * 60 + m;
            }
        }
    }
    default_mins
}

/// Computes local civil sunrise/sunset in minutes past local midnight `[0..1440)` using NOAA
/// solar declination equations. Returns `None` at polar latitudes or polar day/night (`|cosH| > 1`).
pub fn noaa_sunrise_sunset_local_minutes(
    lat_deg: f64,
    lon_deg: f64,
    day_of_year: u32,
    tz_offset_secs: i64,
) -> Option<(u32, u32)> {
    if !lat_deg.is_finite() || !lon_deg.is_finite() || lat_deg.abs() >= 66.5 {
        return None;
    }
    let doy = f64::from(day_of_year.clamp(1, 366));
    let gamma = (2.0 * PI / 365.0) * (doy - 1.0);
    let eqtime = 229.18
        * (0.000075
            + 0.001868 * gamma.cos()
            - 0.032077 * gamma.sin()
            - 0.014615 * (2.0 * gamma).cos()
            - 0.040849 * (2.0 * gamma).sin());
    let decl = 0.006918
        - 0.399912 * gamma.cos()
        + 0.070257 * gamma.sin()
        - 0.006758 * (2.0 * gamma).cos()
        + 0.000907 * (2.0 * gamma).sin()
        - 0.002697 * (3.0 * gamma).cos()
        + 0.00148 * (3.0 * gamma).sin();

    let lat_rad = lat_deg.to_radians();
    let zenith_rad = 90.833f64.to_radians();
    let denom = lat_rad.cos() * decl.cos();
    if denom.abs() < 1e-9 {
        return None;
    }
    let cos_ha = (zenith_rad.cos() / denom) - lat_rad.tan() * decl.tan();
    if !cos_ha.is_finite() || cos_ha.abs() > 1.0 {
        return None;
    }

    let ha_deg = cos_ha.acos().to_degrees();
    let sunrise_utc = 720.0 - 4.0 * (lon_deg + ha_deg) - eqtime;
    let sunset_utc = 720.0 - 4.0 * (lon_deg - ha_deg) - eqtime;
    let tz_mins = tz_offset_secs as f64 / 60.0;

    let sr_local = (sunrise_utc + tz_mins).rem_euclid(1440.0).round() as u32 % 1440;
    let ss_local = (sunset_utc + tz_mins).rem_euclid(1440.0).round() as u32 % 1440;
    Some((sr_local, ss_local))
}

pub fn evaluate_solar_at(
    lat_deg: f64,
    lon_deg: f64,
    day_of_year: u32,
    local_sec_of_day: u32,
    tz_offset_secs: i64,
    fallback_sunrise: &str,
    fallback_sunset: &str,
) -> SolarTransition {
    let (sr_min, ss_min, used_fallback) =
        match noaa_sunrise_sunset_local_minutes(lat_deg, lon_deg, day_of_year, tz_offset_secs) {
            Some((sr, ss)) if sr < ss => (sr, ss, false),
            _ => (
                parse_hhmm_minutes(fallback_sunrise, 6 * 60 + 30),
                parse_hhmm_minutes(fallback_sunset, 18 * 60),
                true,
            ),
        };
    let sr_sec = sr_min * 60;
    let ss_sec = ss_min * 60;
    let now_sec = local_sec_of_day.min(86_399);

    let (is_daytime, wait_secs) = if now_sec < sr_sec {
        (false, (sr_sec - now_sec).max(1))
    } else if now_sec < ss_sec {
        (true, (ss_sec - now_sec).max(1))
    } else {
        (false, (86_400 - now_sec + sr_sec).max(1))
    };

    SolarTransition {
        is_daytime,
        next_transition_in: Duration::from_secs(u64::from(wait_secs)),
        used_fallback,
    }
}

pub fn evaluate_solar_now(
    lat_deg: f64,
    lon_deg: f64,
    fallback_sunrise: &str,
    fallback_sunset: &str,
) -> SolarTransition {
    let now_secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as libc::time_t)
        .unwrap_or(0);
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    // SAFETY: valid pointers passed to POSIX `localtime_r`.
    unsafe {
        libc::localtime_r(&now_secs, &mut tm);
    }
    let doy = u32::try_from(tm.tm_yday).unwrap_or(0) + 1;
    let local_sec = u32::try_from(tm.tm_hour).unwrap_or(12) * 3600
        + u32::try_from(tm.tm_min).unwrap_or(0) * 60
        + u32::try_from(tm.tm_sec).unwrap_or(0);
    let tz_off = tm.tm_gmtoff;

    evaluate_solar_at(
        lat_deg,
        lon_deg,
        doy,
        local_sec,
        tz_off,
        fallback_sunrise,
        fallback_sunset,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn computes_hanoi_solar_times_and_polar_fallback_without_nan() {
        let hanoi = noaa_sunrise_sunset_local_minutes(21.0285, 105.8542, 80, 7 * 3600)
            .expect("Hanoi equinox solar times");
        // ~05:45..06:15 sunrise, ~17:45..18:15 sunset
        assert!((320..=390).contains(&hanoi.0), "sunrise mins={}", hanoi.0);
        assert!((1050..=1110).contains(&hanoi.1), "sunset mins={}", hanoi.1);

        // Polar latitudes (e.g. 78.0 N / -78.0 S) never produce NaN or infinite timers.
        for lat in [78.0f64, -78.0f64, 89.9f64] {
            let tr = evaluate_solar_at(lat, 15.0, 172, 12 * 3600, 0, "06:30", "18:00");
            assert!(tr.used_fallback);
            assert!(tr.is_daytime);
            assert!(tr.next_transition_in.as_secs() > 0);
            assert!(tr.next_transition_in.as_secs() <= 86_400);
        }
    }
}
