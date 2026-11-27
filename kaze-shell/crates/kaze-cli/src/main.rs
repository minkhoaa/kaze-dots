#![deny(clippy::unwrap_used)]

mod daemon;

use kaze_core::Config;
use kaze_ipc::{default_socket_path, send_request, send_request_with_timeout, IpcRequest};
use std::env;
use std::io::{self, Read};
use std::path::PathBuf;
use std::process::ExitCode;

fn print_usage() {
    println!(
        "kaze-shell {}\n\n\
Usage:\n\
  kaze-shell daemon [--config PATH]\n\
  kaze-shell dmenu [-p|--prompt TEXT]\n\
  kaze-shell msg <command> [args...]\n\
  kaze-shell config validate [PATH]\n\
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
  reload                            Reload config.toml without restarting\n\
  status                            Print daemon JSON status",
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
        "config" => run_config_cmd(&args[1..]),
        other => {
            eprintln!("kaze-shell: unknown subcommand '{other}'");
            print_usage();
            ExitCode::from(2)
        }
    }
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
            let path = match &args[1..] {
                [] => match Config::default_path() {
                    Ok(p) => p,
                    Err(err) => {
                        eprintln!("kaze-shell config validate: {err}");
                        return ExitCode::FAILURE;
                    }
                },
                [single] => PathBuf::from(single),
                _ => {
                    eprintln!("Usage: kaze-shell config validate [PATH]");
                    return ExitCode::from(2);
                }
            };
            match Config::load_from_path(&path) {
                Ok(_) => {
                    println!("OK: {}", path.display());
                    ExitCode::SUCCESS
                }
                Err(err) => {
                    eprintln!("kaze-shell config validate: {err}");
                    ExitCode::FAILURE
                }
            }
        }
        _ => {
            eprintln!("Usage: kaze-shell config validate [PATH]");
            ExitCode::from(2)
        }
    }
}
