#!/usr/bin/env python3
"""Suite G: Dynamic Island floating/notch styles, 3-state MPRIS, record/display activities, absorption."""

from __future__ import annotations

from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time

from runner import BlindContext, TestFailure


def _set_island_style(toml_text: str, style: str) -> str:
    out = re.sub(r'(?m)^(preset\s*=\s*)"[^"]*"', r'\1"island"', toml_text, count=1)
    lines = out.splitlines(keepends=True)
    in_island = False
    res = []
    for line in lines:
        s = line.strip()
        if s.startswith("["):
            in_island = (s == "[island]")
        elif in_island and re.match(r"^enabled\s*=", s):
            line = re.sub(r"^(enabled\s*=\s*)\S+", r"\1true", line)
        elif in_island and re.match(r"^style\s*=", s):
            line = re.sub(r'^(style\s*=\s*)"[^"]*"', rf'\1"{style}"', line)
        res.append(line)
    return "".join(res)


def _measure_island_pill_area(ctx: BlindContext, bg_strip) -> tuple[int, tuple[int, int, int, int]]:
    cur_strip = ctx.vis.capture_ppm(region=(400, 0, 1120, 320))
    diff = ctx.vis.diff_stats(bg_strip, cur_strip, threshold=14)
    if diff["bbox"] is None:
        return 0, (0, 0, 0, 0)
    x0, y0, x1, y1 = diff["bbox"]
    w = x1 - x0 + 1
    h = y1 - y0 + 1
    return w * h, (400 + x0, y0, 400 + x1, y1)


def test_g01_floating_vs_notch_and_virtual_exclusion(ctx: BlindContext) -> None:
    cfg_path = Path.home() / ".config" / "kaze-shell" / "config.toml"
    original = cfg_path.read_text(encoding="utf-8")

    try:
        subprocess.run(["kaze-display", "virtual-share", "9"], check=True, capture_output=True, text=True, timeout=10)
        # Capture pure desktop top edge in ghost mode for ground-truth pixel comparison
        ctx.proc.kaze_msg("layout-set", "ghost")
        ctx.proc.wait_layer("kaze-bar-Virtual-1", present=False, timeout=3.0)
        time.sleep(0.25)
        bg_top = ctx.vis.capture_ppm(region=(660, 0, 600, 12))

        ctx.proc.kaze_msg("layout-set", "island")
        ctx.require(ctx.proc.wait_layer("kaze-island", present=True, timeout=3.0) is not None, "kaze-island missing")

        # 1. Floating style -> top row y=0 must be desktop background (6-8px gap)
        cfg_path.write_text(_set_island_style(original, "floating"), encoding="utf-8")
        time.sleep(0.45)
        ctx.require(
            not ctx.proc.find_layers(namespace="kaze-island", output="kaze-share"),
            "kaze-island leaked onto kaze-share in floating mode",
        )
        isl_f = ctx.proc.find_layers(namespace="kaze-island", output="Virtual-1")
        ctx.require(bool(isl_f), "kaze-island missing on Virtual-1")
        top_f = ctx.vis.capture_ppm(region=(660, 0, 600, 12))
        row0_f = ctx.vis.mean_rgb(top_f, (200, 0, 400, 1))
        row0_bg = ctx.vis.mean_rgb(bg_top, (200, 0, 400, 1))
        if isl_f[0]["y"] == 0:
            ctx.require(
                sum(abs(a - b) for a, b in zip(row0_f, row0_bg)) < 12.0,
                f"floating island touched y=0 (no top margin gap): row0={row0_f} vs bg={row0_bg}",
            )
        ctx.save_artifact("island-floating.png", output="Virtual-1")

        # 2. Notch style -> flush to y=0 at top center
        cfg_path.write_text(_set_island_style(original, "notch"), encoding="utf-8")
        time.sleep(0.45)
        ctx.save_artifact("island-notch.png", output="Virtual-1")
        ctx.require(
            not ctx.proc.find_layers(namespace="kaze-island", output="kaze-share"),
            "kaze-island leaked onto kaze-share in notch mode",
        )
        isl_n = ctx.proc.find_layers(namespace="kaze-island", output="Virtual-1")
        ctx.require(bool(isl_n) and isl_n[0]["y"] == 0, f"notch island y={isl_n[0]['y'] if isl_n else None}, expected 0")
        top_n = ctx.vis.capture_ppm(region=(660, 0, 600, 12))
        row0_n = ctx.vis.mean_rgb(top_n, (220, 0, 380, 0))
        ctx.require(
            sum(abs(a - b) for a, b in zip(row0_n, row0_bg)) > 12.0,
            f"notch island did not flush to top edge y=0: row0={row0_n} vs bg={row0_bg}",
        )
    finally:
        cfg_path.write_text(original, encoding="utf-8")
        subprocess.run(["kaze-display", "stop-virtual"], capture_output=True, timeout=8)
        ctx.proc.kaze_msg("layout-set", "omarchy")
        ctx.proc.wait_layer("kaze-bar-Virtual-1", present=True, timeout=3.0)


def test_g02_three_state_lifecycle_and_mpris(ctx: BlindContext) -> None:
    for c in ctx.proc.hypr_json("clients"):
        if c.get("address"):
            ctx.proc.close_window_by_address(c["address"])
    ctx.inp.move(960, 540)
    ctx.proc.kaze_msg("layout-set", "ghost")
    ctx.proc.wait_layer("kaze-bar-Virtual-1", present=False, timeout=3.0)
    time.sleep(0.25)
    bg_strip = ctx.vis.capture_ppm(region=(400, 0, 1120, 320))

    ctx.proc.kaze_msg("layout-set", "island")
    ctx.require(ctx.proc.wait_layer("kaze-island", present=True, timeout=3.0) is not None, "kaze-island missing")
    time.sleep(0.45)

    area_col, bbox_col = _measure_island_pill_area(ctx, bg_strip)
    ctx.require(area_col > 200, f"Collapsed island rendered invisibly (area={area_col})")

    with tempfile.TemporaryDirectory() as td:
        log_file = Path(td) / "mpris.jsonl"
        ready = Path(td) / "mpris.ready"
        title = f"Bài hát Việt {ctx.nonce('song')}"
        mock = subprocess.Popen(
            [
                "python3",
                str(ctx.harness_dir / "mock_mpris.py"),
                "--bus-name",
                "org.mpris.MediaPlayer2.kaze_blind_test",
                "--title",
                title,
                "--artist",
                "Nghệ sĩ Việt",
                "--status",
                "Playing",
                "--log",
                str(log_file),
                "--ready",
                str(ready),
            ]
        )
        try:
            deadline = time.monotonic() + 3.0
            while time.monotonic() < deadline and not ready.exists():
                time.sleep(0.05)
            ctx.require(ready.exists(), "mock_mpris did not become ready")
            time.sleep(0.6)

            area_cmp, bbox_cmp = _measure_island_pill_area(ctx, bg_strip)
            ctx.require(
                area_cmp > area_col * 1.15,
                f"Compact MPRIS state did not grow beyond Collapsed ({area_col} -> {area_cmp})",
            )

            # Click island center via real QMP to expand
            cx = (bbox_cmp[0] + bbox_cmp[2]) // 2
            cy = (bbox_cmp[1] + bbox_cmp[3]) // 2
            ctx.inp.click(cx, cy, button="left")
            time.sleep(0.65)
            area_exp, bbox_exp = _measure_island_pill_area(ctx, bg_strip)
            ctx.require(
                area_exp > area_cmp * 1.4,
                f"Expanded state did not grow beyond Compact ({area_cmp} -> {area_exp})",
            )

            # Locate Play/Pause button by flipping status via SIGUSR1 and diffing expanded island
            exp_region = (
                bbox_exp[0],
                bbox_exp[1],
                bbox_exp[2] - bbox_exp[0] + 1,
                bbox_exp[3] - bbox_exp[1] + 1,
            )
            img_playing = ctx.vis.capture_ppm(region=exp_region)
            mock.send_signal(signal.SIGUSR1)  # Playing -> Paused
            time.sleep(0.35)
            img_paused = ctx.vis.capture_ppm(region=exp_region)
            diff_btn = ctx.vis.diff_stats(img_playing, img_paused, threshold=14)
            ctx.require(
                diff_btn["bbox"] is not None,
                "Expanded island did not update Play/Pause icon on MPRIS PlaybackStatus change",
            )
            bx0, by0, bx1, by1 = diff_btn["bbox"]
            # Try distinct changed bands (or bbox center) to locate Play/Pause button accurately
            candidates = [
                (exp_region[0] + b[2], exp_region[1] + b[3])
                for b in diff_btn["y_bands"]
            ]
            c_all = (exp_region[0] + (bx0 + bx1) // 2, exp_region[1] + (by0 + by1) // 2)
            if c_all not in candidates:
                candidates.append(c_all)

            log_offset = log_file.stat().st_size if log_file.exists() else 0
            got_playpause = False
            for btn_x, btn_y in candidates:
                ctx.inp.click(btn_x, btn_y, button="left")
                time.sleep(0.3)
                new_logs = log_file.read_text(encoding="utf-8")[log_offset:] if log_file.exists() else ""
                if '"PlayPause"' in new_logs:
                    got_playpause = True
                    break
                # Re-expand if a non-button click collapsed the island
                cur_area, _ = _measure_island_pill_area(ctx, bg_strip)
                if cur_area <= area_cmp * 1.2:
                    ctx.inp.click(cx, cy, button="left")
                    time.sleep(0.5)
            ctx.require(
                got_playpause,
                f"clicking Expanded island changed bands {candidates} did not invoke D-Bus PlayPause",
            )

            # Stop player -> verify collapses back to Collapsed cleanly (allowing auto_collapse_ms)
            mock.terminate()
            mock.wait(timeout=3)
            deadline = time.monotonic() + 5.5
            area_after = 0
            while time.monotonic() < deadline:
                area_after, _ = _measure_island_pill_area(ctx, bg_strip)
                if area_after <= area_col * 1.15:
                    break
                time.sleep(0.25)
            ctx.require(
                area_after <= area_col * 1.15,
                f"Island did not return to Collapsed size after MPRIS exit ({area_after} vs col={area_col})",
            )

            # Verify zero D-Bus Position polling in Collapsed state
            pos_before = log_file.read_text(encoding="utf-8").count('"Position"') if log_file.exists() else 0
            time.sleep(2.5)
            pos_after = log_file.read_text(encoding="utf-8").count('"Position"') if log_file.exists() else 0
            ctx.require(pos_after == pos_before, "unexpected Position polling in Collapsed state")
        finally:
            if mock.poll() is None:
                mock.kill()
                mock.wait(timeout=2)
            ctx.proc.kaze_msg("layout-set", "omarchy")
            ctx.proc.wait_layer("kaze-bar-Virtual-1", present=True, timeout=3.0)


def test_g03_live_activities_and_timer_cleanup(ctx: BlindContext) -> None:
    ctx.proc.kaze_msg("layout-set", "island")
    isl = ctx.proc.wait_layer("kaze-island", present=True, timeout=3.0)
    ctx.require(isl is not None, "kaze-island missing")
    pid = ctx.proc.get_shell_pid()

    try:
        now_s = int(time.time())
        rc1, _, e1 = ctx.proc.kaze_msg(
            "island-activity",
            "display",
            '{"mode":"virtual-share","ws":9,"control":false,"output":"kaze-share"}',
        )
        rc2, _, e2 = ctx.proc.kaze_msg(
            "island-activity",
            "record",
            f'{{"active":true,"started_at":{now_s},"audio":true,"gif":false}}',
        )
        ctx.require(rc1 == 0 and rc2 == 0, f"island-activity failed: {e1} / {e2}")
        time.sleep(1.5)

        reg = (600, 0, 720, 120)
        img1 = ctx.vis.capture_ppm(region=reg)
        time.sleep(1.25)
        img2 = ctx.vis.capture_ppm(region=reg)
        ctx.require(
            ctx.vis.diff_stats(img1, img2, threshold=12)["changed_count"] > 4,
            "record live activity timer did not advance visually over 1.25s",
        )

        ctx.proc.kaze_msg("island-clear", "record")
        ctx.proc.kaze_msg("island-clear", "display")
        time.sleep(1.5)

        idle = ctx.proc.measure_idle(pid, 10.0)
        ctx.require(
            idle["cpu_pct"] <= 0.10 and idle["cs_per_sec"] <= 4.0,
            f"1s record timer did not cancel cleanly after island-clear: CPU={idle['cpu_pct']:.2f}% CS/s={idle['cs_per_sec']:.2f}",
        )
    finally:
        ctx.proc.kaze_msg("island-clear", "all")
        ctx.proc.kaze_msg("layout-set", "omarchy")
        ctx.proc.wait_layer("kaze-bar-Virtual-1", present=True, timeout=3.0)


def test_g04_absorption_and_json_fuzz(ctx: BlindContext) -> None:
    ctx.proc.kaze_msg("layout-set", "island")
    ctx.require(ctx.proc.wait_layer("kaze-island", present=True, timeout=3.0) is not None, "kaze-island missing")
    pid0 = ctx.proc.get_shell_pid()
    reg = (560, 0, 800, 260)

    try:
        time.sleep(0.5)
        img_base = ctx.vis.capture_ppm(region=reg)

        # 1. Volume change absorbed into Island (no kaze-osd)
        subprocess.run(["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "0.65"], check=True, timeout=3)
        time.sleep(0.25)
        ctx.require(not ctx.proc.find_layers(namespace="kaze-osd"), "kaze-osd popped up despite absorb_osd=true in island preset")
        img_osd = ctx.vis.capture_ppm(region=reg)
        ctx.require(
            ctx.vis.diff_stats(img_base, img_osd, threshold=12)["changed_count"] > 10,
            "island did not visually display absorbed volume OSD",
        )
        time.sleep(2.0)

        # 2. Normal notification absorbed into Island (no kaze-notify)
        img_pre_n = ctx.vis.capture_ppm(region=reg)
        subprocess.run(
            ["notify-send", "-a", "BlindG04", "-u", "normal", "-t", "3000", "Normal Absorbed", ctx.nonce("abs")],
            check=True,
            timeout=3,
        )
        time.sleep(0.3)
        ctx.require(not ctx.proc.find_layers(namespace="kaze-notify"), "kaze-notify popped up despite absorb_notify=true")
        img_n = ctx.vis.capture_ppm(region=reg)
        ctx.require(
            ctx.vis.diff_stats(img_pre_n, img_n, threshold=12)["changed_count"] > 10,
            "island did not visually display absorbed normal notification",
        )
        time.sleep(3.2)

        # 3. DND on + critical notification must still surface prominently
        ctx.proc.kaze_msg("dnd-on")
        img_pre_c = ctx.vis.capture_ppm(region=reg)
        subprocess.run(
            ["notify-send", "-a", "BlindG04", "-u", "critical", "Critical Alert", ctx.nonce("crit")],
            check=True,
            timeout=3,
        )
        time.sleep(0.35)
        has_notify_layer = bool(ctx.proc.find_layers(namespace="kaze-notify"))
        island_changed = ctx.vis.diff_stats(img_pre_c, ctx.vis.capture_ppm(region=reg), threshold=12)["changed_count"] > 20
        ctx.require(
            has_notify_layer or island_changed,
            "critical notification was silently swallowed by DND in island preset",
        )
        ctx.proc.kaze_msg("notify-clear")
        ctx.proc.kaze_msg("dnd-off")

        # 4. Broken JSON to island-activity -> clean IPC error, same PID
        rc_bad, out_bad, err_bad = ctx.proc.kaze_msg("island-activity", "display", "{broken")
        ctx.require(
            rc_bad != 0 or "err" in (out_bad + err_bad).lower(),
            f"broken JSON to island-activity succeeded silently (rc={rc_bad}, out={out_bad!r})",
        )
        ctx.require(ctx.proc.get_shell_pid() == pid0, "daemon crashed on malformed island-activity JSON")
        rc_p, out_p, _ = ctx.proc.kaze_msg("ping")
        ctx.require(rc_p == 0 and out_p == "pong", "daemon unresponsive after malformed JSON")
    finally:
        ctx.proc.kaze_msg("notify-clear")
        ctx.proc.kaze_msg("dnd-off")
        subprocess.run(["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "0.50"], capture_output=True, timeout=3)
        ctx.proc.kaze_msg("layout-set", "omarchy")
        ctx.proc.wait_layer("kaze-bar-Virtual-1", present=True, timeout=3.0)


TESTS = {
    "G01": test_g01_floating_vs_notch_and_virtual_exclusion,
    "G02": test_g02_three_state_lifecycle_and_mpris,
    "G03": test_g03_live_activities_and_timer_cleanup,
    "G04": test_g04_absorption_and_json_fuzz,
}
