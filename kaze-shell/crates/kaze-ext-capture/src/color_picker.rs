#![deny(clippy::unwrap_used)]

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ColorFormat {
    #[default]
    Hex,
    Rgb,
    Hsl,
    Oklch,
}

impl ColorFormat {
    pub fn parse(raw: &str) -> Self {
        match raw.trim().to_ascii_lowercase().as_str() {
            "rgb" => Self::Rgb,
            "hsl" => Self::Hsl,
            "oklch" => Self::Oklch,
            _ => Self::Hex,
        }
    }

    pub fn next(self) -> Self {
        match self {
            Self::Hex => Self::Rgb,
            Self::Rgb => Self::Hsl,
            Self::Hsl => Self::Oklch,
            Self::Oklch => Self::Hex,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Self::Hex => "HEX",
            Self::Rgb => "RGB",
            Self::Hsl => "HSL",
            Self::Oklch => "OKLCH",
        }
    }
}

fn srgb_to_linear(c: u8) -> f64 {
    let x = f64::from(c) / 255.0;
    if x <= 0.04045 {
        x / 12.92
    } else {
        ((x + 0.055) / 1.055).powf(2.4)
    }
}

pub fn rgb_to_hsl(r: u8, g: u8, b: u8) -> (f64, f64, f64) {
    let rf = f64::from(r) / 255.0;
    let gf = f64::from(g) / 255.0;
    let bf = f64::from(b) / 255.0;
    let max = rf.max(gf).max(bf);
    let min = rf.min(gf).min(bf);
    let l = (max + min) * 0.5;
    if (max - min).abs() < 1e-12 {
        return (0.0, 0.0, l * 100.0);
    }
    let d = max - min;
    let s = if l > 0.5 {
        d / (2.0 - max - min)
    } else {
        d / (max + min)
    };
    let mut h = if (max - rf).abs() < 1e-12 {
        (gf - bf) / d + if gf < bf { 6.0 } else { 0.0 }
    } else if (max - gf).abs() < 1e-12 {
        (bf - rf) / d + 2.0
    } else {
        (rf - gf) / d + 4.0
    };
    h *= 60.0;
    (h, s * 100.0, l * 100.0)
}

/// Converts sRGB `(r, g, b)` to Björn Ottosson's OKLCH `(L in 0..1, C, H in degrees)`.
pub fn rgb_to_oklch(r: u8, g: u8, b: u8) -> (f64, f64, f64) {
    let lr = srgb_to_linear(r);
    let lg = srgb_to_linear(g);
    let lb = srgb_to_linear(b);

    let l = 0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb;
    let m = 0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb;
    let s = 0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb;

    let l_ = l.cbrt();
    let m_ = m.cbrt();
    let s_ = s.cbrt();

    let ok_l = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_;
    let ok_a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_;
    let ok_b = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_;

    let c = (ok_a * ok_a + ok_b * ok_b).sqrt();
    let mut h = ok_b.atan2(ok_a).to_degrees();
    if h < 0.0 {
        h += 360.0;
    }
    if c < 1e-6 {
        h = 0.0;
    }
    (ok_l, c, h)
}

pub fn format_color(r: u8, g: u8, b: u8, fmt: ColorFormat) -> String {
    match fmt {
        ColorFormat::Hex => format!("#{:02X}{:02X}{:02X}", r, g, b),
        ColorFormat::Rgb => format!("rgb({r}, {g}, {b})"),
        ColorFormat::Hsl => {
            let (h, s, l) = rgb_to_hsl(r, g, b);
            format!("hsl({:.0}, {:.0}%, {:.0}%)", h, s, l)
        }
        ColorFormat::Oklch => {
            let (l, c, h) = rgb_to_oklch(r, g, b);
            format!("oklch({:.2}% {:.3} {:.1})", l * 100.0, c, h)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn converts_e61919_across_hex_rgb_hsl_and_oklch_accurately() {
        let (r, g, b) = (230u8, 25u8, 25u8);
        assert_eq!(format_color(r, g, b, ColorFormat::Hex), "#E61919");
        assert_eq!(format_color(r, g, b, ColorFormat::Rgb), "rgb(230, 25, 25)");
        assert_eq!(format_color(r, g, b, ColorFormat::Hsl), "hsl(0, 80%, 50%)");

        let (l, c, h) = rgb_to_oklch(r, g, b);
        assert!((l - 0.577).abs() < 0.015, "L={l}");
        assert!((c - 0.223).abs() < 0.015, "C={c}");
        assert!((h - 27.4).abs() < 1.5, "H={h}");
    }
}
