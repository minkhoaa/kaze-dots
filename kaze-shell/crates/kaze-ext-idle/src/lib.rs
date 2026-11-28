#![deny(clippy::unwrap_used)]

use kaze_core::config::IdleStageProfileConfig;
use kaze_core::{
    AppState, DirtyFlags, IpcResult, KazeExtension, ShellAction, ShellContext, SurfaceSpec,
    SystemEvent,
};
use std::collections::HashSet;

const TIMER_DIM_FINAL: &str = "idle:dim-final";
const TIMER_SLEEP_LOCK_FAILSAFE: &str = "idle:sleep-lock-failsafe";

/// Native Wayland Idle Manager (`ext-idle-notify-v1` + DPMS + AC/Battery profiles + logind PrepareForSleep).
pub struct IdleExtension {
    configured_stages: Vec<(String, u64)>,
    pre_dim_brightness: Option<u8>,
    dimmed: bool,
    dpms_off: bool,
    custom_active: HashSet<String>,
    waiting_sleep_lock: bool,
}

impl Default for IdleExtension {
    fn default() -> Self {
        Self::new()
    }
}

impl IdleExtension {
    pub fn new() -> Self {
        Self {
            configured_stages: Vec::new(),
            pre_dim_brightness: None,
            dimmed: false,
            dpms_off: false,
            custom_active: HashSet::new(),
            waiting_sleep_lock: false,
        }
    }

    fn desired_stages(state: &AppState) -> Vec<(String, u64)> {
        if !state.config.idle.enabled {
            return Vec::new();
        }
        let prof = Self::active_profile(state);
        let mut stages = Vec::new();
        if prof.dim_timeout_secs > 0 {
            stages.push(("dim".into(), prof.dim_timeout_secs * 1000));
        }
        if prof.lock_timeout_secs > 0 {
            stages.push(("lock".into(), prof.lock_timeout_secs * 1000));
        }
        if prof.dpms_timeout_secs > 0 {
            stages.push(("dpms".into(), prof.dpms_timeout_secs * 1000));
        }
        if prof.suspend_timeout_secs > 0 {
            stages.push(("suspend".into(), prof.suspend_timeout_secs * 1000));
        }
        for (idx, c) in prof.custom_stages.iter().enumerate() {
            if c.timeout_secs > 0 && !c.on_timeout.trim().is_empty() {
                stages.push((format!("custom:{idx}"), c.timeout_secs * 1000));
            }
        }
        stages
    }

    fn active_profile(state: &AppState) -> &IdleStageProfileConfig {
        let on_battery =
            state.battery.present && !state.battery.ac_online && !state.battery.charging;
        if on_battery {
            &state.config.idle.behavior.battery
        } else {
            &state.config.idle.behavior.ac
        }
    }

    fn sync_stages(&mut self, ctx: &mut ShellContext) {
        let next = Self::desired_stages(ctx.state);
        if next != self.configured_stages {
            self.configured_stages = next.clone();
            ctx.push_action(ShellAction::ConfigureIdleTimeouts(next));
        }
    }

    fn is_inhibited(state: &AppState) -> bool {
        if state.caffeine_enabled {
            return true;
        }
        if state.config.idle.inhibit_on_audio && state.audio.streams.iter().any(|s| !s.muted) {
            return true;
        }
        false
    }

    fn restore_after_resume(&mut self, ctx: &mut ShellContext) {
        if self.dimmed {
            ctx.push_action(ShellAction::CancelTimer {
                id: TIMER_DIM_FINAL.into(),
            });
            if let Some(orig) = self.pre_dim_brightness.take() {
                ctx.push_action(ShellAction::BacklightSet(orig));
            }
            self.dimmed = false;
        }
        if self.dpms_off {
            ctx.push_action(ShellAction::SetOutputsDpms(true));
            self.dpms_off = false;
        }
        if !self.custom_active.is_empty() {
            let prof = Self::active_profile(ctx.state).clone();
            let active: Vec<String> = self.custom_active.drain().collect();
            for id in active {
                if let Some(idx) = id
                    .strip_prefix("custom:")
                    .and_then(|s| s.parse::<usize>().ok())
                {
                    if let Some(stage) = prof.custom_stages.get(idx) {
                        if let Some(ref cmd) = stage.on_resume {
                            ctx.push_action(ShellAction::SpawnCommand {
                                program: "sh".into(),
                                args: vec!["-c".into(), cmd.clone()],
                            });
                        }
                    }
                }
            }
        }
    }
}

impl KazeExtension for IdleExtension {
    fn id(&self) -> &'static str {
        "idle"
    }

    fn on_init(&mut self, ctx: &mut ShellContext) {
        self.sync_stages(ctx);
    }

    fn on_event(&mut self, event: &SystemEvent, ctx: &mut ShellContext) -> DirtyFlags {
        match event {
            SystemEvent::ConfigReloaded | SystemEvent::BatteryChanged(_) => {
                self.sync_stages(ctx);
                DirtyFlags::NONE
            }
            SystemEvent::IdleTimeout { id } => {
                if !ctx.state.config.idle.enabled || Self::is_inhibited(ctx.state) {
                    return DirtyFlags::NONE;
                }
                let prof = Self::active_profile(ctx.state).clone();
                match id.as_str() {
                    "dim" => {
                        if !self.dimmed && ctx.state.backlight.present {
                            let orig = ctx.state.backlight.percentage.max(1);
                            self.pre_dim_brightness = Some(orig);
                            self.dimmed = true;
                            let target = prof.dim_percent.clamp(1, orig);
                            let mid = ((u16::from(orig) + u16::from(target)) / 2) as u8;
                            ctx.push_action(ShellAction::BacklightSet(mid.max(target)));
                            ctx.push_action(ShellAction::ScheduleTimer {
                                id: TIMER_DIM_FINAL.into(),
                                after_ms: 750,
                            });
                        }
                    }
                    "lock" => {
                        ctx.push_action(ShellAction::LockSession);
                    }
                    "dpms" => {
                        if !self.dpms_off {
                            self.dpms_off = true;
                            ctx.push_action(ShellAction::SetOutputsDpms(false));
                        }
                    }
                    "suspend" => {
                        ctx.push_action(ShellAction::RunHook {
                            event: "suspending".into(),
                            old: None,
                            new: None,
                            value: None,
                        });
                        ctx.push_action(ShellAction::SystemPower("suspend".into()));
                    }
                    other => {
                        if let Some(idx) = other
                            .strip_prefix("custom:")
                            .and_then(|s| s.parse::<usize>().ok())
                        {
                            if let Some(stage) = prof.custom_stages.get(idx) {
                                self.custom_active.insert(id.clone());
                                ctx.push_action(ShellAction::SpawnCommand {
                                    program: "sh".into(),
                                    args: vec!["-c".into(), stage.on_timeout.clone()],
                                });
                            }
                        }
                    }
                }
                DirtyFlags::NONE
            }
            SystemEvent::IdleResumed { .. } => {
                self.restore_after_resume(ctx);
                DirtyFlags::NONE
            }
            SystemEvent::TimerFired { id } if id == TIMER_DIM_FINAL => {
                if self.dimmed && ctx.state.backlight.present {
                    let target = Self::active_profile(ctx.state).dim_percent.clamp(1, 100);
                    ctx.push_action(ShellAction::BacklightSet(target));
                }
                DirtyFlags::NONE
            }
            SystemEvent::PrepareForSleep(true) => {
                if ctx.state.config.idle.lock_before_sleep {
                    self.waiting_sleep_lock = true;
                    ctx.push_action(ShellAction::RunHook {
                        event: "suspending".into(),
                        old: None,
                        new: None,
                        value: None,
                    });
                    ctx.push_action(ShellAction::LockSession);
                    ctx.push_action(ShellAction::ScheduleTimer {
                        id: TIMER_SLEEP_LOCK_FAILSAFE.into(),
                        after_ms: 3000,
                    });
                } else {
                    ctx.push_action(ShellAction::ReleaseSleepInhibitor);
                }
                DirtyFlags::NONE
            }
            SystemEvent::PrepareForSleep(false) => {
                self.restore_after_resume(ctx);
                DirtyFlags::NONE
            }
            SystemEvent::LockWorkerCommitted => {
                if self.waiting_sleep_lock {
                    self.waiting_sleep_lock = false;
                    ctx.push_action(ShellAction::CancelTimer {
                        id: TIMER_SLEEP_LOCK_FAILSAFE.into(),
                    });
                    ctx.push_action(ShellAction::ReleaseSleepInhibitor);
                }
                DirtyFlags::NONE
            }
            SystemEvent::TimerFired { id } if id == TIMER_SLEEP_LOCK_FAILSAFE => {
                if self.waiting_sleep_lock {
                    self.waiting_sleep_lock = false;
                    ctx.push_action(ShellAction::ReleaseSleepInhibitor);
                }
                DirtyFlags::NONE
            }
            SystemEvent::SessionLockRequested => {
                ctx.push_action(ShellAction::LockSession);
                DirtyFlags::NONE
            }
            _ => DirtyFlags::NONE,
        }
    }

    fn on_ipc(&mut self, _cmd: &str, _args: &[String], _ctx: &mut ShellContext) -> IpcResult {
        IpcResult::Unhandled
    }

    fn surfaces(&self) -> Vec<SurfaceSpec> {
        Vec::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use kaze_core::{BacklightState, Config};

    #[test]
    fn dim_and_resume_restores_exact_pre_dim_brightness_from_80_to_15_to_80() {
        let mut state = AppState::new(Config::default());
        state.backlight = BacklightState {
            present: true,
            percentage: 80,
            device: "intel_backlight".into(),
        };
        let mut ext = IdleExtension::new();
        {
            let mut ctx = ShellContext::new(&mut state);
            ext.on_init(&mut ctx);
            ext.on_event(&SystemEvent::IdleTimeout { id: "dim".into() }, &mut ctx);
            assert!(ctx
                .actions
                .iter()
                .any(|a| matches!(a, ShellAction::BacklightSet(_))));
            ctx.actions.clear();
            ext.on_event(
                &SystemEvent::TimerFired {
                    id: TIMER_DIM_FINAL.into(),
                },
                &mut ctx,
            );
            assert!(ctx.actions.contains(&ShellAction::BacklightSet(20))); // default ac dim_percent=20

            ctx.actions.clear();
            ext.on_event(&SystemEvent::IdleResumed { id: "dim".into() }, &mut ctx);
            assert!(ctx.actions.contains(&ShellAction::BacklightSet(80)));
        }
    }

    #[test]
    fn sleep_inhibitor_waits_for_lock_committed_then_releases() {
        let mut state = AppState::new(Config::default());
        let mut ext = IdleExtension::new();
        let mut ctx = ShellContext::new(&mut state);

        ext.on_event(&SystemEvent::PrepareForSleep(true), &mut ctx);
        assert!(ctx.actions.contains(&ShellAction::LockSession));
        assert!(!ctx.actions.contains(&ShellAction::ReleaseSleepInhibitor));

        ctx.actions.clear();
        ext.on_event(&SystemEvent::LockWorkerCommitted, &mut ctx);
        assert!(ctx.actions.contains(&ShellAction::ReleaseSleepInhibitor));
    }
}
