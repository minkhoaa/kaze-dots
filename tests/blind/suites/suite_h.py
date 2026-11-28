#!/usr/bin/env python3
"""Suite H: Control Center, Caffeine, Night Light, 2-step Power guard, Tray SNI+DBusMenu, Clipboard, Wallpaper."""

from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile
import time

from PIL import Image

from runner import BlindContext, TestFailure


def test_h01_control_center_two_way_and_pool_cleanup(ctx: BlindContext) -> None:
    # Warm up once
    ctx.proc.kaze_msg("cc-open")
    ctx.require(ctx.proc.wait_layer("kaze-cc", present=True, timeout=2.0) is not None, "kaze-cc failed to open")
    ctx.proc.kaze_msg("cc-close")
    ctx.require(ctx.proc.wait_layer("kaze-cc", present=False, timeout=2.0) is True, "kaze-cc failed to close")
    time.sleep(0.3)

    pid0 = ctx.proc.get_shell_pid()
    snap0 = ctx.proc.snapshot(pid0)

    try:
        ctx.inp.move(960, 540)
        ctx.proc.kaze_msg("dnd-off")
        ctx.proc.kaze_msg("cc-toggle")
        cc = ctx.proc.wait_layer("kaze-cc", present=True, timeout=2.0)
        ctx.require(cc is not None, "cc-toggle did not open kaze-cc")
        time.sleep(0.3)
        reg = (cc["x"], cc["y"], cc["w"], cc["h"])
        img_off = ctx.vis.capture_ppm(region=reg)
        ctx.save_artifact("control-center.png", output="Virtual-1")

        # External dnd-on must update CC pixels AND reveal exact DND tile coords
        ctx.proc.kaze_msg("dnd-on")
        time.sleep(0.3)
        img_on = ctx.vis.capture_ppm(region=reg)
        diff = ctx.vis.diff_stats(img_off, img_on, threshold=14)
        ctx.require(diff["bbox"] is not None, "CC did not visually update when dnd-on was sent externally")
        bx0, by0, bx1, by1 = diff["bbox"]
        click_x = cc["x"] + (bx0 + bx1) // 2
        click_y = cc["y"] + (by0 + by1) // 2

        ctx.inp.click(click_x, click_y, button="left")
        ctx.inp.move(960, 540)
        time.sleep(0.3)
        _, st, _ = ctx.proc.kaze_msg("dnd-status")
        ctx.require(st == "off", f"clicking CC DND tile at ({click_x},{click_y}) left dnd-status={st!r}")
        img_rev = ctx.vis.capture_ppm(region=reg)
        ctx.require(
            ctx.vis.diff_stats(img_off, img_rev, threshold=14)["changed_count"] <= 12,
            "CC DND tile did not revert visually after click",
        )

        ctx.proc.kaze_msg("cc-toggle")
        ctx.require(ctx.proc.wait_layer("kaze-cc", present=False, timeout=2.0) is True, "cc-toggle did not close kaze-cc")

        # 30x open/close cycle -> check memfd & PSS leak
        for _ in range(30):
            ctx.proc.kaze_msg("cc-toggle")
            ctx.proc.wait_layer("kaze-cc", present=True, timeout=2.0)
            ctx.proc.kaze_msg("cc-toggle")
            ctx.proc.wait_layer("kaze-cc", present=False, timeout=2.0)

        time.sleep(0.5)
        ctx.require(not ctx.proc.find_layers(namespace="kaze-cc"), "kaze-cc still present after close")
        snap1 = ctx.proc.snapshot(pid0)
        ctx.require(
            snap1["memfd_count"] <= snap0["memfd_count"] + 1,
            f"after 30x cc-toggle, /proc/{pid0}/fd memfd count grew from {snap0['memfd_count']} to {snap1['memfd_count']}",
        )
        pss_delta = snap1["pss_kib"] - snap0["pss_kib"]
        ctx.require(pss_delta <= 3072, f"CC toggle PSS grew by {pss_delta} KiB (> 3072 KiB)")
    finally:
        ctx.proc.kaze_msg("cc-close")
        ctx.proc.kaze_msg("dnd-off")


def _systemd_inhibitors() -> str:
    res = subprocess.run(["systemd-inhibit", "--list", "--no-pager"], capture_output=True, text=True, timeout=5)
    return res.stdout if res.returncode == 0 else ""


def _has_active_flag(val) -> bool:
    if isinstance(val, bool):
        return val
    if isinstance(val, str):
        return val.strip().lower() in ("on", "true", "active", "enabled")
    if isinstance(val, dict):
        return any(_has_active_flag(v) for v in val.values())
    if isinstance(val, list):
        return any(_has_active_flag(v) for v in val)
    return False


def test_h02_caffeine_and_nightlight(ctx: BlindContext) -> None:
    import json as _json
    try:
        ctx.inp.move(960, 540)
        ctx.proc.kaze_msg("caffeine-set", "off")
        ctx.proc.kaze_msg("nightlight-set", "off")
        ctx.proc.kaze_msg("cc-open")
        cc = ctx.proc.wait_layer("kaze-cc", present=True, timeout=2.0)
        ctx.require(cc is not None, "kaze-cc failed to open for H02")
        time.sleep(0.25)
        cc_reg = (cc["x"], cc["y"], cc["w"], cc["h"])

        # Caffeine: off -> on -> off verified via inspect + systemd-inhibit + CC visual state
        insp_before_raw = ctx.proc.kaze_msg("inspect")[1]
        insp_before = _json.loads(insp_before_raw) if insp_before_raw.startswith("{") else {}
        caf_before = {k: v for k, v in insp_before.items() if "caf" in k.lower() or "inhibit" in k.lower()}
        inhib_before = _systemd_inhibitors()
        img_caf_off = ctx.vis.capture_ppm(region=cc_reg)

        rc_on, out_on, _ = ctx.proc.kaze_msg("caffeine-set", "on")
        ctx.require(rc_on == 0 and "on" in out_on, f"caffeine-set on failed: {out_on!r}")
        time.sleep(0.25)
        insp_on_raw = ctx.proc.kaze_msg("inspect")[1]
        insp_on = _json.loads(insp_on_raw) if insp_on_raw.startswith("{") else {}
        caf_on = {k: v for k, v in insp_on.items() if "caf" in k.lower() or "inhibit" in k.lower()}
        inhib_on = _systemd_inhibitors()
        img_caf_on = ctx.vis.capture_ppm(region=cc_reg)

        has_inhibit_proc = ("kaze" in inhib_on.lower() and "kaze" not in inhib_before.lower()) or (
            "caffeine" in inhib_on.lower() and "caffeine" not in inhib_before.lower()
        )
        has_caf_inspect = _has_active_flag(caf_on) and not _has_active_flag(caf_before)
        ctx.require(
            has_inhibit_proc or has_caf_inspect,
            f"caffeine-set on showed no real inactive->active transition (inhib={inhib_on!r}, caf_before={caf_before}, caf_on={caf_on})",
        )
        ctx.require(
            ctx.vis.diff_stats(img_caf_off, img_caf_on, threshold=14)["changed_count"] > 10,
            "Control Center did not visually reflect caffeine-set on",
        )

        rc_off, out_off, _ = ctx.proc.kaze_msg("caffeine-set", "off")
        ctx.require(rc_off == 0 and "off" in out_off, f"caffeine-set off failed: {out_off!r}")
        time.sleep(0.25)
        insp_after_raw = ctx.proc.kaze_msg("inspect")[1]
        insp_after = _json.loads(insp_after_raw) if insp_after_raw.startswith("{") else {}
        caf_after = {k: v for k, v in insp_after.items() if "caf" in k.lower() or "inhibit" in k.lower()}
        inhib_after = _systemd_inhibitors()
        img_caf_after = ctx.vis.capture_ppm(region=cc_reg)

        ctx.require("caffeine" not in inhib_after.lower() and not _has_active_flag(caf_after), f"caffeine stayed active after off: caf_after={caf_after}")
        ctx.require(
            ctx.vis.diff_stats(img_caf_off, img_caf_after, threshold=14)["changed_count"] <= 12,
            "Control Center caffeine state did not revert visually after off",
        )

        # Night Light (3200K warm shift vs 6500K reset)
        img_nl_off = ctx.vis.capture_ppm(region=cc_reg)
        rc_nl, out_nl, _ = ctx.proc.kaze_msg("nightlight-set", "3200")
        ctx.require(rc_nl == 0 and "3200K" in out_nl, f"nightlight-set 3200 failed: {out_nl!r}")
        _, nl_st, _ = ctx.proc.kaze_msg("nightlight-status")
        ctx.require(nl_st == "on 3200K", f"nightlight-status={nl_st!r}, expected 'on 3200K'")
        time.sleep(0.35)

        gamma_proc = subprocess.run(["pgrep", "-x", "hyprsunset"], capture_output=True, text=True).stdout.strip()
        insp_nl = ctx.proc.kaze_msg("inspect")[1]
        ctx.require(
            bool(gamma_proc) or "3200" in insp_nl,
            "nightlight-set 3200K showed no active gamma/temperature state",
        )
        img_nl_on = ctx.vis.capture_ppm(region=cc_reg)
        ctx.require(
            ctx.vis.diff_stats(img_nl_off, img_nl_on, threshold=14)["changed_count"] > 10,
            "Control Center did not visually reflect nightlight-set 3200",
        )

        rc_tgl, out_tgl, _ = ctx.proc.kaze_msg("nightlight-toggle")
        ctx.require(rc_tgl == 0 and out_tgl == "off", f"nightlight-toggle off returned {out_tgl!r}")
        time.sleep(0.25)
        _, nl_off, _ = ctx.proc.kaze_msg("nightlight-status")
        ctx.require(nl_off == "off", f"nightlight-status after off={nl_off!r}")
        img_nl_after = ctx.vis.capture_ppm(region=cc_reg)
        ctx.require(
            ctx.vis.diff_stats(img_nl_off, img_nl_after, threshold=14)["changed_count"] <= 12,
            "Control Center nightlight state did not revert visually after off",
        )
    finally:
        ctx.proc.kaze_msg("cc-close")
        ctx.proc.kaze_msg("caffeine-set", "off")
        ctx.proc.kaze_msg("nightlight-set", "off")


def test_h03_power_bar_two_step_guard(ctx: BlindContext) -> None:
    try:
        ctx.proc.kaze_msg("cc-open")
        cc = ctx.proc.wait_layer("kaze-cc", present=True, timeout=2.0)
        ctx.require(cc is not None, "kaze-cc missing")
        time.sleep(0.35)

        reg = (cc["x"], cc["y"], cc["w"], cc["h"])
        img_before = ctx.vis.capture_ppm(region=reg)
        tmp_png = Path("/tmp/kaze-blind-h03-cc.png")
        ctx.vis.capture_png(tmp_png, region=reg)
        words = ctx.vis.ocr_words(tmp_png)
        tmp_png.unlink(missing_ok=True)

        target_btn = None
        for kw in ("reboot", "restart", "poweroff", "power", "shutdown", "off"):
            for w in words:
                if kw in w["text"].lower():
                    target_btn = (cc["x"] + w["x"] + w["w"] // 2, cc["y"] + w["y"] + w["h"] // 2)
                    break
            if target_btn:
                break

        if target_btn is None:
            # Fallback: scan bottom button row of Control Center across x slots for hover/arm response
            cand_y = cc["y"] + cc["h"] - 28
            for frac in (0.62, 0.78, 0.45, 0.88):
                cx = cc["x"] + int(cc["w"] * frac)
                ctx.inp.move(cx, cand_y)
                time.sleep(0.15)
                img_hov = ctx.vis.capture_ppm(region=reg)
                if ctx.vis.diff_stats(img_before, img_hov, threshold=12)["changed_count"] > 15:
                    target_btn = (cx, cand_y)
                    break

        ctx.require(target_btn is not None, "could not locate Reboot/Poweroff button in Control Center")
        ctx.inp.click(target_btn[0], target_btn[1], button="left")
        time.sleep(0.3)

        # Must NOT reboot/poweroff on single click; button must enter armed confirmation state
        ctx.require(ctx.proc.kaze_msg("ping")[1] == "pong", "system/shell disrupted on single power button click")
        img_armed = ctx.vis.capture_ppm(region=reg)
        armed_diff = ctx.vis.diff_stats(img_before, img_armed, threshold=14)
        ctx.require(
            armed_diff["changed_count"] > 10,
            "single click on Reboot/Poweroff did not change button visual confirmation state",
        )

        # Wait without clicking again -> must NOT reboot and should auto-revert confirmation
        time.sleep(4.2)
        ctx.require(ctx.proc.kaze_msg("ping")[1] == "pong", "daemon became unavailable after power button timeout")
        img_reverted = ctx.vis.capture_ppm(region=reg)
        mae_armed = armed_diff["mae"]
        mae_reverted = ctx.vis.diff_stats(img_before, img_reverted, threshold=14)["mae"]
        ctx.require(
            mae_reverted < mae_armed * 0.6 + 0.5,
            f"power confirmation state did not auto-revert after timeout (mae armed={mae_armed:.2f}, reverted={mae_reverted:.2f})",
        )
    finally:
        ctx.proc.kaze_msg("cc-close")


def _run_tray_mock(ctx: BlindContext, profile: str, menu_label: str, td: str):
    ready = Path(td) / f"{profile}.ready"
    log = Path(td) / f"{profile}.jsonl"
    proc = subprocess.Popen(
        [
            "python3",
            str(ctx.harness_dir / "mock_sni.py"),
            "--profile",
            profile,
            "--id",
            f"kaze-blind-{profile}",
            "--menu-label",
            menu_label,
            "--log",
            str(log),
            "--ready",
            str(ready),
        ]
    )
    deadline = time.monotonic() + 3.0
    while time.monotonic() < deadline and not ready.exists():
        time.sleep(0.05)
    ctx.require(ready.exists(), f"mock_sni ({profile}) failed to register")
    return proc, log


def test_h04_system_tray_sni_dbusmenu_and_corrupt(ctx: BlindContext) -> None:
    shell_pid = ctx.proc.get_shell_pid()
    watcher_pid = ctx.proc.bus_owner_pid("org.kde.StatusNotifierWatcher")
    ctx.require(
        watcher_pid == shell_pid,
        f"org.kde.StatusNotifierWatcher owned by PID {watcher_pid}, expected kaze-shell PID {shell_pid}",
    )

    bar = ctx.proc.wait_layer("kaze-bar-Virtual-1", present=True, timeout=3.0)
    ctx.require(bar is not None, "bar missing")
    bar_region = (bar["x"], bar["y"], bar["w"], bar["h"])
    bar_0 = ctx.vis.capture_ppm(region=bar_region)
    base_memfd = ctx.proc.snapshot(shell_pid)["memfd_count"]

    with tempfile.TemporaryDirectory() as td:
        # 1. Valid green #19E619 IconPixmap + Activate + DBusMenu Event + cleanup
        label = f"Act_{ctx.nonce('m')}"
        p1, log1 = _run_tray_mock(ctx, "pixmap_green", label, td)
        try:
            time.sleep(0.4)
            bar_1 = ctx.vis.capture_ppm(region=bar_region)
            diff = ctx.vis.diff_stats(bar_0, bar_1, threshold=14)
            ctx.require(diff["bbox"] is not None, "SNI green pixmap tray icon did not appear on bar")

            chroma = ctx.vis.chromatic_stats(bar_1, indices=diff["changed_indices"], min_sat=50)
            ctx.require(chroma["count"] >= 8, "tray pixmap rendered without expected green pixels")
            ctx.require(
                chroma["mean_g"] > 170.0 and chroma["mean_r"] < 90.0 and chroma["mean_b"] < 90.0,
                f"tray IconPixmap RGB=({chroma['mean_r']:.0f},{chroma['mean_g']:.0f},{chroma['mean_b']:.0f}), expected green (#19E619)",
            )

            bx0, by0, bx1, by1 = diff["bbox"]
            tx = bar["x"] + (bx0 + bx1) // 2
            ty = bar["y"] + (by0 + by1) // 2

            # Left-click -> Activate
            ctx.inp.click(tx, ty, button="left")
            time.sleep(0.3)
            ctx.require('"Activate"' in log1.read_text(encoding="utf-8"), "left-click on tray icon did not call SNI Activate")

            # Right-click -> open kaze-tray-menu -> click item 101 -> Event("clicked")
            ctx.inp.right_click(tx, ty)
            menu = ctx.proc.wait_layer("kaze-tray-menu", present=True, timeout=2.0)
            ctx.require(menu is not None, "right-click on tray icon did not open kaze-tray-menu")
            time.sleep(0.25)
            ctx.save_artifact("tray-menu.png", output="Virtual-1")

            ctx.inp.click(menu["x"] + menu["w"] // 2, menu["y"] + 22, button="left")
            ctx.require(
                ctx.proc.wait_layer("kaze-tray-menu", present=False, timeout=2.0) is True,
                "clicking tray menu item did not close kaze-tray-menu",
            )
            time.sleep(0.25)
            log_text = log1.read_text(encoding="utf-8")
            ctx.require(
                '"Event"' in log_text and '"clicked"' in log_text and "101" in log_text,
                f"clicking tray menu item did not send DBusMenu Event(101, 'clicked'): {log_text}",
            )
        finally:
            p1.terminate()
            p1.wait(timeout=3)

        time.sleep(0.4)
        bar_after = ctx.vis.capture_ppm(region=bar_region)
        ctx.require(
            ctx.vis.diff_stats(bar_0, bar_after, threshold=14)["changed_count"] <= 10,
            "tray slot icon remained after SNI app exited",
        )
        end_memfd = ctx.proc.snapshot(shell_pid)["memfd_count"]
        ctx.require(
            end_memfd <= base_memfd + 1,
            f"memfd leaked after tray menu cycle: {base_memfd} -> {end_memfd}",
        )

        # 2. AppIndicator IconName-only profile
        p2, _ = _run_tray_mock(ctx, "icon_name", "IconOnly", td)
        try:
            time.sleep(0.4)
            bar_2 = ctx.vis.capture_ppm(region=bar_region)
            ctx.require(
                ctx.vis.diff_stats(bar_0, bar_2, threshold=14)["changed_count"] > 5,
                "AppIndicator IconName-only tray item failed to render on bar",
            )
        finally:
            p2.terminate()
            p2.wait(timeout=3)
            time.sleep(0.3)

        # 3. Corrupt IconPixmap -> must NOT crash daemon
        p3, _ = _run_tray_mock(ctx, "corrupt_pixmap", "Corrupt", td)
        try:
            time.sleep(0.45)
            ctx.require(ctx.proc.get_shell_pid() == shell_pid, "daemon crashed on corrupt SNI IconPixmap")
            ctx.require(ctx.proc.kaze_msg("ping")[1] == "pong", "daemon unresponsive after corrupt SNI IconPixmap")
        finally:
            p3.terminate()
            p3.wait(timeout=3)


def test_h05_clipboard_history(ctx: BlindContext) -> None:
    subprocess.run(["cliphist", "wipe"], check=True, timeout=3)
    n = ctx.nonce("clip")
    ascii_item = f"ClipAscii-{n}"
    vn_item = f"Ghi chú {n}"

    with tempfile.TemporaryDirectory() as td:
        png_path = Path(td) / "tiny.png"
        Image.new("RGB", (32, 32), (25, 180, 230)).save(png_path, "PNG")

        try:
            subprocess.run(["wl-copy", ascii_item], check=True, timeout=3)
            time.sleep(0.4)
            subprocess.run(["wl-copy", vn_item], check=True, timeout=3)
            time.sleep(0.4)
            with png_path.open("rb") as fh:
                subprocess.run(["wl-copy", "--type", "image/png"], stdin=fh, check=True, timeout=3)
            time.sleep(0.45)

            cl = subprocess.run(["cliphist", "list"], check=True, capture_output=True, text=True, timeout=3).stdout
            ctx.require(ascii_item in cl and vn_item in cl, f"cliphist missing test entries: {cl!r}")

            # Open clipboard overlay -> verify [IMG] label & select Vietnamese item
            ctx.proc.kaze_msg("clipboard-toggle")
            overlay = ctx.proc.wait_layer("kaze-launcher", present=True, timeout=2.0)
            ctx.require(overlay is not None, "clipboard-toggle did not open kaze-launcher")
            time.sleep(0.25)

            ocr_png = Path(td) / "clip.png"
            ctx.vis.capture_png(ocr_png, region=(overlay["x"], overlay["y"], overlay["w"], overlay["h"]))
            words = " ".join(w["text"] for w in ctx.vis.ocr_words(ocr_png))
            ctx.require("IMG" in words or "img" in words.lower(), f"clipboard image item did not render [IMG] tag (ocr={words!r})")

            ctx.inp.type_ascii("Ghi")
            time.sleep(0.1)
            ctx.inp.key("ret")
            ctx.require(ctx.proc.wait_layer("kaze-launcher", present=False, timeout=2.0) is True, "clipboard overlay did not close after Enter")
            time.sleep(0.2)

            pasted = subprocess.run(["wl-paste", "--no-newline"], check=True, capture_output=True, text=True, timeout=3).stdout
            ctx.require(pasted == vn_item, f"clipboard selection pasted {pasted!r}, expected {vn_item!r}")

            # Re-open and Shift+Delete the Vietnamese entry
            ctx.proc.kaze_msg("clipboard-toggle")
            ctx.require(ctx.proc.wait_layer("kaze-launcher", present=True, timeout=2.0) is not None, "clipboard overlay did not reopen")
            time.sleep(0.2)
            ctx.inp.type_ascii("Ghi")
            time.sleep(0.1)
            ctx.inp.key("shift", "delete")
            time.sleep(0.2)
            ctx.inp.key("esc")
            ctx.proc.wait_layer("kaze-launcher", present=False, timeout=2.0)

            cl_after = subprocess.run(["cliphist", "list"], check=True, capture_output=True, text=True, timeout=3).stdout
            ctx.require(vn_item not in cl_after, "Shift+Delete did not remove entry from cliphist history")
        finally:
            subprocess.run(["pkill", "-x", "wl-copy"], capture_output=True, timeout=2)
            subprocess.run(["cliphist", "wipe"], capture_output=True, timeout=3)
            ctx.proc.kaze_msg("launcher-close")


def test_h06_wallpaper_palette_wcag_and_corrupt(ctx: BlindContext) -> None:
    pid0 = ctx.proc.get_shell_pid()
    foot_theme = Path.home() / ".config" / "foot" / "themes" / "kaze-shell"
    gtk3_css = Path.home() / ".config" / "gtk-3.0" / "kaze-shell.css"
    gtk4_css = Path.home() / ".config" / "gtk-4.0" / "kaze-shell.css"
    hypr_lua = Path.home() / ".config" / "hypr" / "kaze-theme.lua"
    btop_theme = Path.home() / ".config" / "btop" / "themes" / "kaze-shell.theme"

    with tempfile.TemporaryDirectory() as td:
        img = Image.new("RGB", (1920, 1080), (20, 56, 130))
        files = []
        for ext, fmt in (("png", "PNG"), ("jpg", "JPEG"), ("webp", "WEBP")):
            p = Path(td) / f"blue.{ext}"
            img.save(p, fmt)
            files.append(p)
        corrupt = Path(td) / "corrupt.png"
        corrupt.write_bytes(b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDRbroken")

        try:
            subprocess.run(["kaze-display", "virtual-share", "9"], check=True, capture_output=True, text=True, timeout=10)
            time.sleep(0.3)

            for p in files:
                rc, _, err = ctx.proc.kaze_msg("wallpaper-set", str(p))
                ctx.require(rc == 0, f"wallpaper-set {p.name} failed: {err}")
                wl = ctx.proc.wait_layer("kaze-wallpaper-Virtual-1", present=True, timeout=3.0)
                ctx.require(wl is not None and wl["level"] == 0, f"wallpaper layer missing or wrong level for {p.name}: {wl}")
                ctx.require(
                    not ctx.proc.find_layers(namespace="kaze-wallpaper-kaze-share"),
                    "wallpaper surface leaked onto kaze-share",
                )
                time.sleep(0.4)
                bg = ctx.vis.capture_ppm(region=(600, 400, 200, 200))
                mr, mg, mb = ctx.vis.mean_rgb(bg)
                ctx.require(
                    mb > mr + 40.0,
                    f"wallpaper {p.name} did not render blue desktop pixels: mean RGB=({mr:.0f},{mg:.0f},{mb:.0f})",
                )
                for target in (hypr_lua, foot_theme, gtk3_css, gtk4_css, btop_theme):
                    ctx.require(target.exists() and target.stat().st_size > 0, f"missing theme file {target}")
                    tmp_left = [x.name for x in target.parent.iterdir() if ".tmp" in x.name]
                    ctx.require(not tmp_left, f"temp file left behind in {target.parent}: {tmp_left}")

                min_ratio, ratios = ctx.vis.check_theme_wcag(foot_theme, gtk3_css)
                ctx.require(
                    min_ratio >= 4.5,
                    f"WCAG contrast ratio {min_ratio:.2f} < 4.5:1 on {p.name} ({ratios})",
                )

            # Settle 3s -> PSS <= 60 MiB (no raw 1080p decode buffers kept on heap)
            time.sleep(3.0)
            pss_mib = ctx.proc.read_pss_kib(pid0) / 1024.0
            ctx.require(pss_mib <= 60.0, f"PSS after wallpaper settle={pss_mib:.2f} MiB > 60 MiB")

            # Missing & corrupt image -> clean error, keep old wallpaper, no crash
            for bad in (Path(td) / "missing.png", corrupt):
                rc_b, out_b, err_b = ctx.proc.kaze_msg("wallpaper-set", str(bad))
                ctx.require(
                    rc_b != 0 or "err" in (out_b + err_b).lower(),
                    f"invalid wallpaper {bad.name} did not return error",
                )
                ctx.require(ctx.proc.get_shell_pid() == pid0, f"daemon crashed on invalid wallpaper {bad.name}")
                ctx.require(bool(ctx.proc.find_layers(namespace="kaze-wallpaper-Virtual-1")), "existing wallpaper lost after invalid image")
        finally:
            ctx.proc.kaze_msg("wallpaper-clear")
            subprocess.run(["kaze-display", "stop-virtual"], capture_output=True, timeout=8)


TESTS = {
    "H01": test_h01_control_center_two_way_and_pool_cleanup,
    "H02": test_h02_caffeine_and_nightlight,
    "H03": test_h03_power_bar_two_step_guard,
    "H04": test_h04_system_tray_sni_dbusmenu_and_corrupt,
    "H05": test_h05_clipboard_history,
    "H06": test_h06_wallpaper_palette_wcag_and_corrupt,
}
