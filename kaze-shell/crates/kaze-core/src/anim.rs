/// Damped harmonic spring solver for frame-paced Wayland UI animations.
///
/// Convergence threshold (`|x - target| < 0.25 && |v| < 0.5`) hard-snaps to the
/// target and signals the surface to stop requesting `wl_surface.frame()` callbacks
/// so idle CPU returns strictly to `0.00%`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Spring {
    pub value: f32,
    pub velocity: f32,
    pub target: f32,
    pub stiffness: f32,
    pub damping: f32,
}

pub const SPRING_MAX_DT_SECS: f32 = 0.033;
pub const SPRING_POS_EPSILON: f32 = 0.25;
pub const SPRING_VEL_EPSILON: f32 = 0.5;

impl Spring {
    pub const fn new(initial: f32, stiffness: f32, damping: f32) -> Self {
        Self {
            value: initial,
            velocity: 0.0,
            target: initial,
            stiffness,
            damping,
        }
    }

    /// Snappy UI transition spring (~180ms settle, minimal overshoot).
    pub const fn snappy(initial: f32) -> Self {
        Self::new(initial, 360.0, 34.0)
    }

    /// Smooth morphing spring for pills / Dynamic Island (~240ms settle).
    pub const fn smooth(initial: f32) -> Self {
        Self::new(initial, 260.0, 28.0)
    }

    pub fn set_target(&mut self, target: f32) {
        self.target = target;
        if self.is_settled() {
            self.value = self.target;
            self.velocity = 0.0;
        }
    }

    pub fn snap(&mut self, value: f32) {
        self.value = value;
        self.target = value;
        self.velocity = 0.0;
    }

    pub fn is_settled(&self) -> bool {
        (self.value - self.target).abs() < SPRING_POS_EPSILON
            && self.velocity.abs() < SPRING_VEL_EPSILON
    }

    /// Advances the spring by `dt_secs` (clamped to `<= 33ms`).
    /// Returns `true` if still animating, or `false` once converged and hard-snapped.
    pub fn step(&mut self, dt_secs: f32) -> bool {
        if self.is_settled() {
            self.value = self.target;
            self.velocity = 0.0;
            return false;
        }
        if !dt_secs.is_finite() || dt_secs <= 0.0 {
            return true;
        }

        let dt = dt_secs.min(SPRING_MAX_DT_SECS);
        // Two semi-implicit Euler substeps keep stiff springs stable even at 33ms (30 FPS).
        let sub_dt = dt * 0.5;
        for _ in 0..2 {
            let disp = self.value - self.target;
            let acc = -self.stiffness * disp - self.damping * self.velocity;
            self.velocity += acc * sub_dt;
            self.value += self.velocity * sub_dt;
        }

        if self.is_settled() {
            self.value = self.target;
            self.velocity = 0.0;
            false
        } else {
            true
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spring_converges_and_hard_snaps_within_bounded_frames() {
        let mut s = Spring::snappy(0.0);
        assert!(!s.step(0.016));
        s.set_target(100.0);
        assert!(!s.is_settled());

        let mut frames = 0;
        while s.step(1.0 / 60.0) {
            frames += 1;
            assert!(frames < 120, "spring failed to settle within 2s");
        }
        assert!(frames >= 5, "spring should animate over multiple frames");
        assert_eq!(s.value, 100.0);
        assert_eq!(s.velocity, 0.0);
        assert!(s.is_settled());
        assert!(!s.step(1.0 / 60.0));
    }

    #[test]
    fn spring_clamps_large_dt_to_33ms_preventing_explosion() {
        let mut s1 = Spring::snappy(0.0);
        let mut s2 = Spring::snappy(0.0);
        s1.set_target(200.0);
        s2.set_target(200.0);

        s1.step(2.5);
        s2.step(SPRING_MAX_DT_SECS);
        assert_eq!(s1.value, s2.value);
        assert_eq!(s1.velocity, s2.velocity);
        assert!(s1.value.is_finite());
    }

    #[test]
    fn spring_handles_144hz_and_snap() {
        let mut s = Spring::smooth(180.0);
        s.set_target(420.0);
        let mut frames = 0;
        while s.step(1.0 / 144.0) {
            frames += 1;
            assert!(frames < 300, "144Hz spring must settle promptly");
        }
        assert_eq!(s.value, 420.0);
        s.snap(50.0);
        assert_eq!(s.value, 50.0);
        assert_eq!(s.target, 50.0);
        assert_eq!(s.velocity, 0.0);
        assert!(s.is_settled());
    }
}
