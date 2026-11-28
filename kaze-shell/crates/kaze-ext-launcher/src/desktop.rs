pub use kaze_core::desktop::{
    application_dirs, build_exec_command, existing_watch_dirs, find_desktop_app_for_class,
    parse_desktop_exec, resolve_icon_path, scan_applications, scan_applications_in,
    user_applications_dir, AppCategory, DesktopAction, DesktopApp,
};

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::DirBuilderExt;

    #[test]
    fn strips_field_codes_and_wraps_terminal_apps() {
        let parts = parse_desktop_exec("firefox --new-window %u --class=\"My App\" %F %%lit");
        assert_eq!(
            parts,
            vec!["firefox", "--new-window", "--class=My App", "%lit"]
        );

        let term_app = DesktopApp {
            id: "yazi.desktop".into(),
            name: "Yazi".into(),
            generic_name: "File Manager".into(),
            comment: String::new(),
            keywords: String::new(),
            exec: "yazi %u".into(),
            icon: String::new(),
            startup_wm_class: String::new(),
            terminal: true,
            categories: vec!["System".into(), "Utility".into()],
            actions: Vec::new(),
        };
        let (prog, args) = term_app.build_command().expect("terminal command");
        assert_eq!(prog, "kaze-footclient");
        assert_eq!(args, vec!["-N", "-e", "yazi"]);
    }

    #[test]
    fn scans_desktop_files_respecting_nodisplay_hidden_and_user_override() {
        let root = std::env::temp_dir().join(format!("kaze-desktop-scan-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let sys_dir = root.join("sys");
        let usr_dir = root.join("usr");
        fs::DirBuilder::new()
            .mode(0o700)
            .recursive(true)
            .create(&sys_dir)
            .expect("create sys dir");
        fs::create_dir_all(&usr_dir).expect("create usr dir");

        fs::write(
            sys_dir.join("foot.desktop"),
            "[Desktop Entry]\nType=Application\nName=Foot\nExec=foot\n",
        )
        .expect("write foot");
        fs::write(
            sys_dir.join("hidden.desktop"),
            "[Desktop Entry]\nType=Application\nName=Hidden\nExec=true\nNoDisplay=true\n",
        )
        .expect("write hidden");
        fs::write(
            sys_dir.join("override.desktop"),
            "[Desktop Entry]\nType=Application\nName=SystemName\nExec=sys-app %U\n",
        )
        .expect("write override sys");
        fs::write(
            usr_dir.join("override.desktop"),
            "[Desktop Entry]\nType=Application\nName=UserName\nExec=user-app %f\n",
        )
        .expect("write override usr");
        fs::write(
            usr_dir.join("foot.desktop"),
            "[Desktop Entry]\nType=Application\nName=Foot\nExec=foot\nHidden=true\n",
        )
        .expect("hide foot");

        let apps = scan_applications_in(&[sys_dir, usr_dir]);
        assert_eq!(apps.len(), 1);
        assert_eq!(apps[0].name, "UserName");
        assert_eq!(
            apps[0].build_command(),
            Some(("user-app".to_string(), vec![]))
        );

        let _ = fs::remove_dir_all(&root);
    }
}
