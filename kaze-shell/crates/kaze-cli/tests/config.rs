use std::fs;
use std::io;
use std::os::unix::fs::DirBuilderExt;
use std::process::Command;

#[test]
fn validate_selects_one_file_without_using_the_host_environment() -> io::Result<()> {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_kaze-shell"));
    cmd.env_clear().args(["config", "validate"]);
    let no_home = cmd.output()?;
    assert!(!no_home.status.success());
    assert!(String::from_utf8_lossy(&no_home.stderr).contains("HOME"));

    let home = std::env::temp_dir().join(format!("kaze-config-test-{}", std::process::id()));
    fs::DirBuilder::new().mode(0o700).create(&home)?;
    let home_config = home.join(".config/kaze-shell/config.toml");
    cmd.env("HOME", &home).env("XDG_CONFIG_HOME", "");
    let missing_file = cmd.output()?;
    assert!(missing_file.status.success());
    assert_eq!(
        String::from_utf8_lossy(&missing_file.stdout).trim(),
        format!("OK: {}", home_config.display())
    );

    cmd.env("XDG_CONFIG_HOME", "relative");
    let relative = cmd.output()?;
    assert!(!relative.status.success());
    assert!(String::from_utf8_lossy(&relative.stderr).contains("XDG_CONFIG_HOME"));

    let xdg = home.join("xdg");
    let dir = xdg.join("kaze-shell");
    fs::create_dir_all(&dir)?;
    fs::write(dir.join("config.toml"), "[bar]\nthickness=1")?;
    cmd.env("XDG_CONFIG_HOME", xdg);
    let invalid = cmd.output()?;
    assert!(!invalid.status.success());
    assert!(String::from_utf8_lossy(&invalid.stderr).contains("bar.thickness"));

    let explicit = home.join("override.toml");
    fs::write(&explicit, "[bar]\nbackground_opacity=1.5")?;
    let selected = cmd.arg(&explicit).output()?;
    assert!(selected.status.success());
    assert_eq!(
        String::from_utf8_lossy(&selected.stdout).trim(),
        format!("OK: {}", explicit.display())
    );
    assert!(String::from_utf8_lossy(&selected.stderr).contains("bar.background_opacity"));

    let strict_out = Command::new(env!("CARGO_BIN_EXE_kaze-shell"))
        .args(["config", "validate", "--strict", "--json"])
        .arg(&explicit)
        .output()?;
    assert_eq!(strict_out.status.code(), Some(1));
    let strict_stdout = String::from_utf8_lossy(&strict_out.stdout);
    assert!(strict_stdout.contains("\"strict\": true"));
    assert!(strict_stdout.contains("bar.background_opacity"));

    let bad_flag = Command::new(env!("CARGO_BIN_EXE_kaze-shell"))
        .args(["config", "validate", "--bogus"])
        .output()?;
    assert_eq!(bad_flag.status.code(), Some(2));

    fs::remove_dir_all(home)
}
