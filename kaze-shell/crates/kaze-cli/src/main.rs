#![deny(clippy::unwrap_used)]

mod daemon;

use kaze_core::Config;
use kaze_ipc::{default_socket_path, send_request, send_request_with_timeout, IpcRequest};
use std::env;
use std::fs;
use std::io::{self, Read};
use std::os::unix::fs::{FileTypeExt, PermissionsExt};
use std::path::PathBuf;
use std::process::{Command, ExitCode, Stdio};

fn print_usage() {
    println!(
        "kaze-shell {}\n\n\
Usage:\n\
  kaze-shell daemon [--config PATH]\n\
  kaze-shell dmenu [-p|--prompt TEXT]\n\
  kaze-shell msg <command> [args...]\n\
  kaze-shell inspect\n\
  kaze-shell doctor [--offline] [--config PATH]\n\
  kaze-shell config validate [--strict] [--json] [PATH]\n\
  kaze-shell --help | --version\n\n\
IPC Commands (via `kaze-shell msg`):\n\
  ping                              Check daemon liveness\n\
  bar-hide [bar] [monitor]          Hide bar globally or on a specific output\n\
  bar-show [bar] [monitor]          Show bar globally or on a specific output\n\
  bar-peek [on|off]                 Temporarily reveal Ghost-mode bar with spring animation\n\
  layout-set <omarchy|island|swiss|ghost>  Switch active layout preset live\n\
  layout-next                       Cycle to the next layout preset\n\
  layout-list | layout-status       List available presets or print active preset\n\
  island-toggle                     Expand or collapse Dynamic Island\n\
  island-activity <id> <json>       Update a Dynamic Island Live Activity (display|record|<id>)\n\
  island-clear <id|all>             Clear a Dynamic Island Live Activity\n\
  island-style <floating|notch>     Switch Dynamic Island geometry style\n\
  cc-toggle | cc-open | cc-close    Toggle, open, or close Control Center\n\
  clipboard-toggle                  Toggle Clipboard History overlay (cliphist)\n\
  tray-list | tray-open-menu [id]   Inspect SNI tray items or open DBusMenu popup\n\
  wallpaper-set <path>              Set wallpaper & extract dynamic Dark/Light theme\n\
  wallpaper-next | wallpaper-clear  Cycle or clear wallpaper background\n\
  nightlight-toggle | nightlight-set <on|off|K>\n\
  caffeine-toggle | caffeine-set <on|off>\n\
  theme-mode-toggle                 Toggle Dark/Light mode & regenerate templates\n\
  templates-apply                   Regenerate Hyprland, Foot, GTK3/4, btop themes\n\
  display-status <mode> [detail]    Update Display Slot dot (idle|present|virtual-share|virtual-control|recording)\n\
  volume-up [step]                  Raise default sink volume (default 5%)\n\
  volume-down [step]                Lower default sink volume (default 5%)\n\
  volume-mute                       Toggle default sink mute\n\
  mic-mute                          Toggle default source mic mute\n\
  brightness-up [step]              Raise screen brightness (default 5%)\n\
  brightness-down [step]            Lower screen brightness (default 5%)\n\
  media <play-pause|next|prev|stop> Control active MPRIS player\n\
  dnd-status | dnd-on | dnd-off | dnd-toggle\n\
  notify-clear                      Dismiss active notification popups & unread badge\n\
  launcher-toggle | launcher-close  Toggle or close the App Launcher / dmenu overlay\n\
  offline-mode-status | offline-mode-toggle | offline-mode-set <on|off>\n\
  config-set <key> <value>          Write Layer-2 override in settings.toml\n\
  config-unset <key>                Remove Layer-2 override from settings.toml\n\
  reload                            Reload config.toml + settings.toml without restarting\n\
  inspect | status                  Print daemon JSON diagnostics",
        env!("CARGO_PKG_VERSION")
    );
}

fn main() -> ExitCode {
    let args: Vec<String> = env::args().skip(1).collect();
    let Some(subcmd) = args.first().map(String::as_str) else {
        print_usage();
        return ExitCode::from(2);
    };

    match subcmd {
        "-h" | "--help" | "help" => {
            print_usage();
            ExitCode::SUCCESS
        }
        "-V" | "--version" | "version" => {
            println!("kaze-shell {}", env!("CARGO_PKG_VERSION"));
            ExitCode::SUCCESS
        }
        "daemon" => run_daemon_cmd(&args[1..]),
        "dmenu" => run_dmenu_cmd(&args[1..]),
        "msg" => run_msg_cmd(&args[1..]),
        "inspect" => run_inspect_cmd(&args[1..]),
        "doctor" => run_doctor_cmd(&args[1..]),
        "config" => run_config_cmd(&args[1..]),
        other => {
            eprintln!("kaze-shell: unknown subcommand '{other}'");
            print_usage();
            ExitCode::from(2)
        }
    }
}

fn run_inspect_cmd(args: &[String]) -> ExitCode {
    if args.iter().any(|a| a == "-h" || a == "--help") {
        println!("Usage: kaze-shell inspect");
        return ExitCode::SUCCESS;
    }
    if !args.is_empty() {
        eprintln!("kaze-shell inspect: unexpected argument '{}'", args[0]);
        return ExitCode::from(2);
    }
    let sock = match default_socket_path() {
        Ok(p) => p,
        Err(err) => {
            eprintln!("kaze-shell inspect: {err}");
            return ExitCode::FAILURE;
        }
    };
    let req = IpcRequest {
        cmd: "inspect".to_string(),
        args: Vec::new(),
    };
    match send_request(&sock, &req) {
        Ok(resp) if resp.ok => {
            if let Some(data) = resp.data {
                if let Ok(pretty) = serde_json::to_string_pretty(&data) {
                    println!("{pretty}");
                    return ExitCode::SUCCESS;
                }
            }
            eprintln!("kaze-shell inspect: daemon returned empty payload");
            ExitCode::FAILURE
        }
        Ok(resp) => {
            eprintln!("kaze-shell inspect: {}", resp.message);
            ExitCode::FAILURE
        }
        Err(err) => {
            eprintln!("kaze-shell inspect: {err}");
            ExitCode::FAILURE
        }
    }
}

fn run_doctor_cmd(args: &[String]) -> ExitCode {
    let mut offline = false;
    let mut config_path: Option<PathBuf> = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "-h" | "--help" => {
                println!("Usage: kaze-shell doctor [--offline] [--config PATH]");
                return ExitCode::SUCCESS;
            }
            "--offline" => offline = true,
            "--config" => {
                i += 1;
                let Some(p) = args.get(i) else {
                    eprintln!("kaze-shell doctor: --config requires a path");
                    return ExitCode::from(2);
                };
                config_path = Some(PathBuf::from(p));
            }
            other => {
                eprintln!("kaze-shell doctor: unknown option '{other}'");
                return ExitCode::from(2);
            }
        }
        i += 1;
    }

    let mut fails = 0u32;

    // 1. Validate config.toml
    let cfg_path = match config_path {
        Some(p) => Ok(p),
        None => Config::default_path(),
    };
    let loaded_cfg = match cfg_path {
        Ok(path) => match Config::load_from_path(&path) {
            Ok(cfg) => {
                println!("[OK]   config: {}", path.display());
                Some(cfg)
            }
            Err(err) => {
                println!("[FAIL] config: {err}");
                fails += 1;
                None
            }
        },
        Err(err) => {
            println!("[FAIL] config: {err}");
            fails += 1;
            None
        }
    };

    // 2. Check configured font availability
    let font_hint = loaded_cfg
        .as_ref()
        .map(|c| c.bar.font.as_str())
        .unwrap_or("JetBrainsMono Nerd Font");
    let font_ok = Command::new("fc-match")
        .args(["-f", "%{file}", font_hint])
        .stdin(Stdio::null())
        .output()
        .is_ok_and(|out| out.status.success() && !out.stdout.is_empty());
    if font_ok {
        println!("[OK]   font: '{font_hint}' resolved via fontconfig");
    } else {
        println!("[WARN] font: '{font_hint}' could not be verified via fc-match");
    }

    if offline {
        println!("[OK]   runtime: skipped live IPC/D-Bus checks (--offline)");
        return if fails == 0 {
            ExitCode::SUCCESS
        } else {
            ExitCode::FAILURE
        };
    }

    // 3. Check IPC socket presence, permissions & connectivity
    let sock = match default_socket_path() {
        Ok(p) => Some(p),
        Err(err) => {
            println!("[FAIL] socket: {err}");
            fails += 1;
            None
        }
    };

    if let Some(ref sock_path) = sock {
        match fs::metadata(sock_path) {
            Ok(meta) if meta.file_type().is_socket() => {
                let mode = meta.permissions().mode() & 0o777;
                if mode & 0o077 == 0 {
                    println!("[OK]   socket: {} (mode {:04o})", sock_path.display(), mode);
                } else {
                    println!(
                        "[FAIL] socket: {} has overly permissive mode {:04o} (expected 0600)",
                        sock_path.display(),
                        mode
                    );
                    fails += 1;
                }
            }
            Ok(_) => {
                println!(
                    "[FAIL] socket: {} is not a UNIX socket",
                    sock_path.display()
                );
                fails += 1;
            }
            Err(err) => {
                println!("[FAIL] socket: {} unreachable ({err})", sock_path.display());
                fails += 1;
            }
        }

        // 4. Query daemon inspect JSON & verify D-Bus ownership + Hyprland + zero orphan noctalia
        let req = IpcRequest {
            cmd: "inspect".to_string(),
            args: Vec::new(),
        };
        match send_request(sock_path, &req) {
            Ok(resp) if resp.ok => {
                if let Some(data) = resp.data {
                    let pid = data["pid"].as_u64().unwrap_or(0);
                    let preset = data["layout_preset"].as_str().unwrap_or("unknown");
                    let surfaces = data["surface_count"].as_u64().unwrap_or(0);
                    let hypr_ok = data["hypr_connected"].as_bool().unwrap_or(false);
                    let notif_ok = data["notifications_bus_owned"].as_bool().unwrap_or(false);
                    let tray_ok = data["tray_bus_owned"].as_bool().unwrap_or(false);

                    println!("[OK]   daemon: pid={pid} preset={preset} surfaces={surfaces}");
                    if hypr_ok {
                        println!("[OK]   hyprland: IPC connected");
                    } else {
                        println!("[FAIL] hyprland: IPC disconnected");
                        fails += 1;
                    }
                    if notif_ok {
                        println!("[OK]   dbus: owns org.freedesktop.Notifications");
                    } else {
                        println!("[FAIL] dbus: does not own org.freedesktop.Notifications");
                        fails += 1;
                    }
                    if tray_ok {
                        println!("[OK]   dbus: owns org.kde.StatusNotifierWatcher");
                    } else {
                        println!("[FAIL] dbus: does not own org.kde.StatusNotifierWatcher");
                        fails += 1;
                    }
                } else {
                    println!("[FAIL] daemon: inspect returned empty data");
                    fails += 1;
                }
            }
            Ok(resp) => {
                println!("[FAIL] daemon: inspect error: {}", resp.message);
                fails += 1;
            }
            Err(err) => {
                println!("[FAIL] daemon: IPC query failed: {err}");
                fails += 1;
            }
        }
    }

    // 5. Ensure 0 orphan `noctalia` processes for current UID
    let orphan_noctalia = count_own_processes("noctalia");
    if orphan_noctalia == 0 {
        println!("[OK]   standalone: 0 orphan noctalia processes");
    } else {
        println!("[FAIL] standalone: found {orphan_noctalia} orphan noctalia process(es)");
        fails += 1;
    }

    if fails == 0 {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}

fn count_own_processes(target_comm: &str) -> usize {
    // SAFETY: `getuid` has no preconditions and always succeeds.
    let my_uid = unsafe { libc::getuid() };
    let Ok(entries) = fs::read_dir("/proc") else {
        return 0;
    };
    let mut count = 0usize;
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(pid_str) = name.to_str() else {
            continue;
        };
        if pid_str.parse::<u32>().is_err() {
            continue;
        }
        let proc_dir = entry.path();
        let Ok(comm) = fs::read_to_string(proc_dir.join("comm")) else {
            continue;
        };
        if comm.trim() != target_comm {
            continue;
        }
        let Ok(status) = fs::read_to_string(proc_dir.join("status")) else {
            continue;
        };
        let owned = status
            .lines()
            .find(|l| l.starts_with("Uid:"))
            .and_then(|l| l.split_whitespace().nth(1))
            .and_then(|u| u.parse::<libc::uid_t>().ok())
            == Some(my_uid);
        if owned {
            count += 1;
        }
    }
    count
}

fn run_dmenu_cmd(args: &[String]) -> ExitCode {
    let mut prompt = String::from("Select > ");
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "-h" | "--help" => {
                println!("Usage: kaze-shell dmenu [-p|--prompt TEXT]");
                return ExitCode::SUCCESS;
            }
            "-p" | "--prompt" => {
                i += 1;
                let Some(val) = args.get(i) else {
                    eprintln!("kaze-shell dmenu: {} requires a prompt string", args[i - 1]);
                    return ExitCode::from(2);
                };
                prompt = val.clone();
            }
            arg if arg.starts_with("--prompt=") => {
                prompt = arg.trim_start_matches("--prompt=").to_string();
            }
            other => {
                eprintln!("kaze-shell dmenu: unknown option '{other}'");
                return ExitCode::from(2);
            }
        }
        i += 1;
    }

    let mut payload = String::new();
    // Cap stdin payload slightly under IPC's 2 MiB JSON line cap to preserve framing safety.
    let mut handle = io::stdin().take(1_900_000);
    if let Err(err) = handle.read_to_string(&mut payload) {
        eprintln!("kaze-shell dmenu: failed reading stdin: {err}");
        return ExitCode::FAILURE;
    }

    let sock = match default_socket_path() {
        Ok(p) => p,
        Err(err) => {
            eprintln!("kaze-shell dmenu: {err}");
            return ExitCode::FAILURE;
        }
    };

    let req = IpcRequest {
        cmd: "dmenu-open".to_string(),
        args: vec![prompt, payload],
    };

    match send_request_with_timeout(&sock, &req, None) {
        Ok(resp) if resp.ok => {
            println!("{}", resp.message);
            ExitCode::SUCCESS
        }
        Ok(resp) => {
            if resp.message != "cancelled" && !resp.message.is_empty() {
                eprintln!("kaze-shell dmenu: {}", resp.message);
            }
            ExitCode::FAILURE
        }
        Err(err) => {
            eprintln!("kaze-shell dmenu: {err}");
            ExitCode::FAILURE
        }
    }
}

fn run_daemon_cmd(args: &[String]) -> ExitCode {
    let mut config_path: Option<PathBuf> = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--config" => {
                i += 1;
                let Some(p) = args.get(i) else {
                    eprintln!("kaze-shell daemon: --config requires a path");
                    return ExitCode::from(2);
                };
                config_path = Some(PathBuf::from(p));
            }
            other => {
                eprintln!("kaze-shell daemon: unknown option '{other}'");
                return ExitCode::from(2);
            }
        }
        i += 1;
    }

    let path = match config_path {
        Some(p) => p,
        None => match Config::default_path() {
            Ok(p) => p,
            Err(err) => {
                eprintln!("kaze-shell daemon: {err}");
                return ExitCode::FAILURE;
            }
        },
    };
    match daemon::run(path) {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("kaze-shell daemon: {err}");
            ExitCode::FAILURE
        }
    }
}

fn run_msg_cmd(args: &[String]) -> ExitCode {
    let Some((cmd, rest)) = args.split_first() else {
        eprintln!("kaze-shell msg: missing command (try `kaze-shell msg ping`)");
        return ExitCode::from(2);
    };

    let sock = match default_socket_path() {
        Ok(p) => p,
        Err(err) => {
            eprintln!("kaze-shell msg: {err}");
            return ExitCode::FAILURE;
        }
    };

    let req = IpcRequest {
        cmd: cmd.clone(),
        args: rest.to_vec(),
    };

    match send_request(&sock, &req) {
        Ok(resp) => {
            if let Some(data) = resp.data {
                if let Ok(pretty) = serde_json::to_string_pretty(&data) {
                    println!("{pretty}");
                }
            } else if !resp.message.is_empty() {
                if resp.ok {
                    println!("{}", resp.message);
                } else {
                    eprintln!("kaze-shell msg: {}", resp.message);
                }
            }
            if resp.ok {
                ExitCode::SUCCESS
            } else {
                ExitCode::FAILURE
            }
        }
        Err(err) => {
            eprintln!("kaze-shell msg: {err}");
            ExitCode::FAILURE
        }
    }
}

fn run_config_cmd(args: &[String]) -> ExitCode {
    match args.first().map(String::as_str) {
        Some("validate") => {
            let mut strict = false;
            let mut json_out = false;
            let mut path_arg: Option<PathBuf> = None;
            for a in &args[1..] {
                match a.as_str() {
                    "-h" | "--help" => {
                        println!("Usage: kaze-shell config validate [--strict] [--json] [PATH]");
                        return ExitCode::SUCCESS;
                    }
                    "--strict" => strict = true,
                    "--json" => json_out = true,
                    s if s.starts_with('-') => {
                        eprintln!("kaze-shell config validate: unknown option '{s}'");
                        return ExitCode::from(2);
                    }
                    s => {
                        if path_arg.is_some() {
                            eprintln!("Usage: kaze-shell config validate [--strict] [--json] [PATH]");
                            return ExitCode::from(2);
                        }
                        path_arg = Some(PathBuf::from(s));
                    }
                }
            }
            let path = match path_arg {
                Some(p) => p,
                None => match Config::default_path() {
                    Ok(p) => p,
                    Err(err) => {
                        eprintln!("kaze-shell config validate: {err}");
                        return ExitCode::FAILURE;
                    }
                },
            };
            let report = Config::validate_file(&path);
            let strict_fail = report.has_errors() || (strict && report.has_warnings());
            if json_out {
                let mut payload = serde_json::to_value(&report).unwrap_or_default();
                if let Some(obj) = payload.as_object_mut() {
                    obj.insert("strict".into(), serde_json::Value::Bool(strict));
                    obj.insert("ok".into(), serde_json::Value::Bool(!strict_fail));
                }
                if let Ok(s) = serde_json::to_string_pretty(&payload) {
                    println!("{s}");
                }
            } else {
                for w in &report.warnings {
                    eprintln!("kaze-shell config validate: warning: {}: {}", w.path, w.message);
                }
                for e in &report.errors {
                    if e.path.is_empty() {
                        eprintln!("kaze-shell config validate: error: {}", e.message);
                    } else {
                        eprintln!("kaze-shell config validate: error: {}: {}", e.path, e.message);
                    }
                }
                if !strict_fail {
                    println!("OK: {}", path.display());
                }
            }
            if strict_fail {
                ExitCode::FAILURE
            } else {
                ExitCode::SUCCESS
            }
        }
        _ => {
            eprintln!("Usage: kaze-shell config validate [--strict] [--json] [PATH]");
            ExitCode::from(2)
        }
    }
}
