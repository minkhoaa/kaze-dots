use std::f64::consts::{E, PI};

#[derive(Debug, Clone, PartialEq)]
pub struct CalcResult {
    pub input: String,
    pub display: String,
    pub copy_value: String,
    pub is_error: bool,
    pub is_offline_blocked: bool,
}

pub fn looks_like_math_expression(raw: &str) -> bool {
    let s = raw.trim();
    if s.is_empty() {
        return false;
    }
    if s.starts_with('=') || s.starts_with("/calc") {
        return true;
    }
    // Auto-detect arithmetic expression only if it starts with digit/`(`/minus and has an operator.
    let first = s.chars().next().unwrap_or(' ');
    (first.is_ascii_digit() || first == '(' || first == '-')
        && s.chars().any(|c| matches!(c, '+' | '-' | '*' | '/' | '^' | '%'))
        && !s.contains('/') // avoid path-like strings unless preceded by `=`
        || s.contains(" to ")
}

pub fn evaluate_calculator(raw: &str, offline_mode: bool) -> CalcResult {
    let expr = raw
        .trim()
        .strip_prefix('=')
        .or_else(|| raw.trim().strip_prefix("/calc"))
        .unwrap_or(raw)
        .trim();

    if expr.is_empty() {
        return CalcResult {
            input: raw.to_string(),
            display: "Calculator: e.g. = (12 + 8) * 3.5, = 0xff to dec, = 10 km to mi".into(),
            copy_value: String::new(),
            is_error: false,
            is_offline_blocked: false,
        };
    }

    if let Some((lhs, rhs)) = split_conversion(expr) {
        if let Some(res) = try_base_conversion(lhs, rhs) {
            return res;
        }
        if let Some(res) = try_unit_conversion(lhs, rhs) {
            return res;
        }
        if is_currency_pair(lhs, rhs) {
            if offline_mode {
                return CalcResult {
                    input: raw.to_string(),
                    display: "Offline mode enabled — currency lookup disabled".into(),
                    copy_value: String::new(),
                    is_error: true,
                    is_offline_blocked: true,
                };
            }
            return CalcResult {
                input: raw.to_string(),
                display: "Currency rates unavailable without cached feed".into(),
                copy_value: String::new(),
                is_error: true,
                is_offline_blocked: false,
            };
        }
        return CalcResult {
            input: raw.to_string(),
            display: format!("Unsupported conversion: {expr}"),
            copy_value: String::new(),
            is_error: true,
            is_offline_blocked: false,
        };
    }

    match parse_and_eval(expr) {
        Ok(val) if val.is_finite() => {
            let formatted = format_number(val);
            CalcResult {
                input: raw.to_string(),
                display: format!("= {formatted}"),
                copy_value: formatted,
                is_error: false,
                is_offline_blocked: false,
            }
        }
        Ok(_) => CalcResult {
            input: raw.to_string(),
            display: "Math error: result overflows finite f64 range".into(),
            copy_value: String::new(),
            is_error: true,
            is_offline_blocked: false,
        },
        Err(msg) => CalcResult {
            input: raw.to_string(),
            display: format!("Invalid expression: {msg}"),
            copy_value: String::new(),
            is_error: true,
            is_offline_blocked: false,
        },
    }
}

fn format_number(v: f64) -> String {
    if (v - v.round()).abs() < 1e-10 && v.abs() < 1e15 {
        format!("{}", v.round() as i64)
    } else {
        let s = format!("{v:.8}");
        s.trim_end_matches('0').trim_end_matches('.').to_string()
    }
}

fn split_conversion(expr: &str) -> Option<(&str, &str)> {
    let lower = expr.to_ascii_lowercase();
    let idx = lower.find(" to ").or_else(|| lower.find(" in "))?;
    let lhs = expr[..idx].trim();
    let rhs = expr[idx + 4..].trim();
    if lhs.is_empty() || rhs.is_empty() {
        return None;
    }
    Some((lhs, rhs))
}

fn parse_integer_literal(s: &str) -> Option<i128> {
    let t = s.trim();
    let (neg, body) = if let Some(rest) = t.strip_prefix('-') {
        (true, rest.trim())
    } else {
        (false, t)
    };
    let parsed = if let Some(hex) = body.strip_prefix("0x").or_else(|| body.strip_prefix("0X")) {
        i128::from_str_radix(hex, 16).ok()?
    } else if let Some(bin) = body.strip_prefix("0b").or_else(|| body.strip_prefix("0B")) {
        i128::from_str_radix(bin, 2).ok()?
    } else if let Some(oct) = body.strip_prefix("0o").or_else(|| body.strip_prefix("0O")) {
        i128::from_str_radix(oct, 8).ok()?
    } else {
        body.parse::<i128>().ok()?
    };
    Some(if neg { -parsed } else { parsed })
}

fn try_base_conversion(lhs: &str, rhs: &str) -> Option<CalcResult> {
    let target = rhs.trim().to_ascii_lowercase();
    if !matches!(target.as_str(), "dec" | "decimal" | "hex" | "bin" | "binary" | "oct" | "octal") {
        return None;
    }
    let val = parse_integer_literal(lhs)?;
    let out = match target.as_str() {
        "dec" | "decimal" => format!("{val}"),
        "hex" => {
            if val < 0 {
                format!("-0x{:x}", val.unsigned_abs())
            } else {
                format!("0x{val:x}")
            }
        }
        "bin" | "binary" => {
            if val < 0 {
                format!("-0b{:b}", val.unsigned_abs())
            } else {
                format!("0b{val:b}")
            }
        }
        "oct" | "octal" => {
            if val < 0 {
                format!("-0o{:o}", val.unsigned_abs())
            } else {
                format!("0o{val:o}")
            }
        }
        _ => return None,
    };
    Some(CalcResult {
        input: lhs.to_string(),
        display: format!("{lhs} → {out}"),
        copy_value: out,
        is_error: false,
        is_offline_blocked: false,
    })
}

fn try_unit_conversion(lhs: &str, rhs: &str) -> Option<CalcResult> {
    let split_idx = lhs
        .find(|c: char| !c.is_ascii_digit() && c != '.' && c != '-' && c != '+')
        .unwrap_or(lhs.len());
    let num_part = lhs[..split_idx].trim();
    let from_unit = lhs[split_idx..].trim();
    if num_part.is_empty() || from_unit.is_empty() {
        return None;
    }
    let val: f64 = num_part.parse().ok()?;
    let to_unit = rhs.trim();

    // Temperature
    let temp = match (from_unit.to_ascii_uppercase().as_str(), to_unit.to_ascii_uppercase().as_str()) {
        ("C", "F") => Some(val * 9.0 / 5.0 + 32.0),
        ("F", "C") => Some((val - 32.0) * 5.0 / 9.0),
        ("C", "K") => Some(val + 273.15),
        ("K", "C") => Some(val - 273.15),
        ("F", "K") => Some((val - 32.0) * 5.0 / 9.0 + 273.15),
        ("K", "F") => Some((val - 273.15) * 9.0 / 5.0 + 32.0),
        _ => None,
    };
    if let Some(res) = temp {
        let fmt = format_number(res);
        return Some(CalcResult {
            input: lhs.to_string(),
            display: format!("{lhs} → {fmt} {to_unit}"),
            copy_value: fmt,
            is_error: false,
            is_offline_blocked: false,
        });
    }

    // Factor-based units (length in meters, mass in grams, data in bytes)
    enum Dim {
        Len(f64),
        Mass(f64),
        Data(f64),
    }
    let dim_of = |u: &str| -> Option<Dim> {
        match u {
            "km" => Some(Dim::Len(1000.0)),
            "m" => Some(Dim::Len(1.0)),
            "cm" => Some(Dim::Len(0.01)),
            "mm" => Some(Dim::Len(0.001)),
            "mi" => Some(Dim::Len(1609.344)),
            "ft" => Some(Dim::Len(0.3048)),
            "in" => Some(Dim::Len(0.0254)),
            "kg" => Some(Dim::Mass(1000.0)),
            "g" => Some(Dim::Mass(1.0)),
            "lb" | "lbs" => Some(Dim::Mass(453.592_37)),
            "oz" => Some(Dim::Mass(28.349_523_125)),
            "B" => Some(Dim::Data(1.0)),
            "KiB" | "kib" => Some(Dim::Data(1024.0)),
            "MiB" | "mib" => Some(Dim::Data(1024.0 * 1024.0)),
            "GiB" | "gib" => Some(Dim::Data(1024.0 * 1024.0 * 1024.0)),
            "TiB" | "tib" => Some(Dim::Data(1024.0 * 1024.0 * 1024.0 * 1024.0)),
            "KB" | "kb" => Some(Dim::Data(1000.0)),
            "MB" | "mb" => Some(Dim::Data(1_000_000.0)),
            "GB" | "gb" => Some(Dim::Data(1_000_000_000.0)),
            _ => None,
        }
    };

    let factor = match (dim_of(from_unit), dim_of(to_unit)) {
        (Some(Dim::Len(a)), Some(Dim::Len(b))) => a / b,
        (Some(Dim::Mass(a)), Some(Dim::Mass(b))) => a / b,
        (Some(Dim::Data(a)), Some(Dim::Data(b))) => a / b,
        _ => return None,
    };
    let res = val * factor;
    let fmt = format_number(res);
    Some(CalcResult {
        input: lhs.to_string(),
        display: format!("{lhs} → {fmt} {to_unit}"),
        copy_value: fmt,
        is_error: false,
        is_offline_blocked: false,
    })
}

fn is_currency_pair(lhs: &str, rhs: &str) -> bool {
    let rhs_code = rhs.trim();
    if rhs_code.len() != 3 || !rhs_code.chars().all(|c| c.is_ascii_alphabetic()) {
        return false;
    }
    let split_idx = lhs
        .find(|c: char| !c.is_ascii_digit() && c != '.' && c != '-' && c != '+')
        .unwrap_or(lhs.len());
    let lhs_code = lhs[split_idx..].trim();
    lhs_code.len() == 3 && lhs_code.chars().all(|c| c.is_ascii_alphabetic())
}

#[derive(Debug, Clone, PartialEq)]
enum Tok {
    Num(f64),
    Ident(String),
    Op(char),
    LParen,
    RParen,
}

fn tokenize(input: &str) -> Result<Vec<Tok>, String> {
    let bytes = input.as_bytes();
    let mut i = 0;
    let mut out = Vec::new();
    while i < bytes.len() {
        let ch = bytes[i] as char;
        if ch.is_ascii_whitespace() {
            i += 1;
            continue;
        }
        if ch.is_ascii_digit() || ch == '.' {
            let start = i;
            i += 1;
            while i < bytes.len() {
                let c = bytes[i] as char;
                if c.is_ascii_digit() || c == '.' || c == 'e' || c == 'E' {
                    if (c == 'e' || c == 'E')
                        && i + 1 < bytes.len()
                        && (bytes[i + 1] == b'+' || bytes[i + 1] == b'-')
                    {
                        i += 2;
                        continue;
                    }
                    i += 1;
                } else {
                    break;
                }
            }
            let num: f64 = input[start..i]
                .parse()
                .map_err(|_| format!("bad number '{}'", &input[start..i]))?;
            out.push(Tok::Num(num));
            continue;
        }
        if ch.is_ascii_alphabetic() || ch == '_' {
            let start = i;
            i += 1;
            while i < bytes.len() && (bytes[i].is_ascii_alphanumeric() || bytes[i] == b'_') {
                i += 1;
            }
            out.push(Tok::Ident(input[start..i].to_ascii_lowercase()));
            continue;
        }
        match ch {
            '+' | '-' | '*' | '/' | '^' | '%' => {
                out.push(Tok::Op(ch));
                i += 1;
            }
            '(' => {
                out.push(Tok::LParen);
                i += 1;
            }
            ')' => {
                out.push(Tok::RParen);
                i += 1;
            }
            _ => return Err(format!("unexpected '{ch}'")),
        }
    }
    Ok(out)
}

fn parse_and_eval(expr: &str) -> Result<f64, String> {
    let tokens = tokenize(expr)?;
    let mut pos = 0usize;
    let val = parse_add(&tokens, &mut pos)?;
    if pos != tokens.len() {
        return Err("unexpected trailing tokens".into());
    }
    Ok(val)
}

fn parse_add(tokens: &[Tok], pos: &mut usize) -> Result<f64, String> {
    let mut lhs = parse_mul(tokens, pos)?;
    while let Some(Tok::Op(op @ ('+' | '-'))) = tokens.get(*pos) {
        *pos += 1;
        let rhs = parse_mul(tokens, pos)?;
        lhs = if *op == '+' { lhs + rhs } else { lhs - rhs };
    }
    Ok(lhs)
}

fn parse_mul(tokens: &[Tok], pos: &mut usize) -> Result<f64, String> {
    let mut lhs = parse_pow(tokens, pos)?;
    while let Some(Tok::Op(op @ ('*' | '/' | '%'))) = tokens.get(*pos) {
        *pos += 1;
        let rhs = parse_pow(tokens, pos)?;
        lhs = match op {
            '*' => lhs * rhs,
            '/' => {
                if rhs == 0.0 {
                    return Err("division by zero".into());
                }
                lhs / rhs
            }
            '%' => {
                if rhs == 0.0 {
                    return Err("modulo by zero".into());
                }
                lhs % rhs
            }
            _ => lhs,
        };
    }
    Ok(lhs)
}

fn parse_pow(tokens: &[Tok], pos: &mut usize) -> Result<f64, String> {
    let base = parse_unary(tokens, pos)?;
    if matches!(tokens.get(*pos), Some(Tok::Op('^'))) {
        *pos += 1;
        let exp = parse_pow(tokens, pos)?;
        return Ok(base.powf(exp));
    }
    Ok(base)
}

fn parse_unary(tokens: &[Tok], pos: &mut usize) -> Result<f64, String> {
    match tokens.get(*pos) {
        Some(Tok::Op('-')) => {
            *pos += 1;
            Ok(-parse_unary(tokens, pos)?)
        }
        Some(Tok::Op('+')) => {
            *pos += 1;
            parse_unary(tokens, pos)
        }
        _ => parse_primary(tokens, pos),
    }
}

fn parse_primary(tokens: &[Tok], pos: &mut usize) -> Result<f64, String> {
    match tokens.get(*pos).cloned() {
        Some(Tok::Num(n)) => {
            *pos += 1;
            Ok(n)
        }
        Some(Tok::Ident(name)) => {
            *pos += 1;
            if matches!(tokens.get(*pos), Some(Tok::LParen)) {
                *pos += 1;
                let arg = parse_add(tokens, pos)?;
                if !matches!(tokens.get(*pos), Some(Tok::RParen)) {
                    return Err("missing ')'".into());
                }
                *pos += 1;
                match name.as_str() {
                    "sin" => Ok(arg.sin()),
                    "cos" => Ok(arg.cos()),
                    "tan" => Ok(arg.tan()),
                    "sqrt" => {
                        if arg < 0.0 {
                            Err("sqrt of negative number".into())
                        } else {
                            Ok(arg.sqrt())
                        }
                    }
                    "log" | "log10" => {
                        if arg <= 0.0 {
                            Err("log of non-positive number".into())
                        } else {
                            Ok(arg.log10())
                        }
                    }
                    "ln" => {
                        if arg <= 0.0 {
                            Err("ln of non-positive number".into())
                        } else {
                            Ok(arg.ln())
                        }
                    }
                    "abs" => Ok(arg.abs()),
                    _ => Err(format!("unknown function '{name}'")),
                }
            } else {
                match name.as_str() {
                    "pi" => Ok(PI),
                    "e" => Ok(E),
                    _ => Err(format!("unknown symbol '{name}'")),
                }
            }
        }
        Some(Tok::LParen) => {
            *pos += 1;
            let inner = parse_add(tokens, pos)?;
            if !matches!(tokens.get(*pos), Some(Tok::RParen)) {
                return Err("missing ')'".into());
            }
            *pos += 1;
            Ok(inner)
        }
        _ => Err("expected expression".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn evaluates_arithmetic_functions_bases_units_and_edge_cases() {
        let r = evaluate_calculator("= (12 + 8) * 3.5", false);
        assert!(!r.is_error);
        assert_eq!(r.copy_value, "70");

        let s = evaluate_calculator("= sqrt(81) + abs(-3)", false);
        assert_eq!(s.copy_value, "12");

        let div_zero = evaluate_calculator("= 1 / 0", false);
        assert!(div_zero.is_error);
        assert!(!div_zero.display.is_empty());

        let overflow = evaluate_calculator("= 9999^999999", false);
        assert!(overflow.is_error);

        assert_eq!(evaluate_calculator("= 0xff to dec", false).copy_value, "255");
        assert_eq!(evaluate_calculator("= 42 to bin", false).copy_value, "0b101010");
        assert_eq!(evaluate_calculator("= 1024 MiB to GiB", false).copy_value, "1");
        assert_eq!(evaluate_calculator("= 30 C to F", false).copy_value, "86");
        assert_eq!(evaluate_calculator("= 10 km to mi", false).copy_value, "6.21371192");

        let offline = evaluate_calculator("= 100 USD to VND", true);
        assert!(offline.is_error);
        assert!(offline.is_offline_blocked);
    }
}
