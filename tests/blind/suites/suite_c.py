#!/usr/bin/env python3
"""Suite C: D-Bus 1-thread ceiling, graceful hardware absence, volume & OSD, slot clicks."""

from __future__ import annotations

from pathlib import Path
import re
import subprocess
import tempfile
import time

from runner import BlindContext, TestFailure


def _wpctl_volume() -> tuple[float, bool]:
    res = subprocess.run(
        ["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"],
        check=True,
        capture_output=True,
        text=True,
        timeout=3,
    )
    m = re.search(r"Volume:\s*([0-9.]+)", res.stdout)
    ctx_val = float(m.group(1)) if m else 0.0
    muted = "[MUTED]" in res.stdout
    return ctx_val, muted


def test_c01_thread_cap_and_dbus_resilience(ctx: BlindContext) -> None:
    pid0 = ctx.proc.get_shell_pid()
    t0 = ctx.proc.read_threads(pid0)
    ctx.require(t0 <= 5, f"thread count {t0} > 5 ceiling")

    with tempfile.TemporaryDirectory() as td:
        ready = Path(td) / "mpris.ready"
        log_file = Path(td) / "mpris.jsonl"
        mock = subprocess.Popen(
            [
                "python3",
                str(ctx.harness_dir / "mock_mpris.py"),
                "--title",
                ctx.nonce("Track"),
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
            ctx.require(ready.exists(), "mock_mpris did not register on D-Bus")
            time.sleep(0.3)
            mock.kill()
            mock.wait(timeout=3)
            time.sleep(0.3)

            ctx.require(ctx.proc.get_shell_pid() == pid0, "daemon crashed when D-Bus client died with SIGKILL")
            t1 = ctx.proc.read_threads(pid0)
            ctx.require(t1 <= 5, f"thread count grew to {t1} (> 5) after D-Bus disconnect")

            # Restart mock and verify daemon still recovers/tracks it cleanly
            ready.unlink(missing_ok=True)
            mock2 = subprocess.Popen(
                [
                    "python3",
                    str(ctx.harness_dir / "mock_mpris.py"),
                    "--title",
                    ctx.nonce("Track2"),
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
                time.sleep(0.3)
                rc, out, _ = ctx.proc.kaze_msg("ping")
                ctx.require(rc == 0 and out == "pong", "daemon unresponsive after D-Bus client restart")
                ctx.require(ctx.proc.read_threads(pid0) <= 5, "thread count exceeded 5 after D-Bus reconnect")
            finally:
                mock2.terminate()
                mock2.wait(timeout=3)
        finally:
            if mock.poll() is None:
                mock.kill()
                mock.wait(timeout=2)


def test_c02_missing_hardware_graceful(ctx: BlindContext) -> None:
    bats = list(Path("/sys/class/power_supply").glob("BAT*"))
    bls = list(Path("/sys/class/backlight").glob("*"))
    ctx.require(not bats, f"expected VM without battery, found {bats}")
    ctx.require(not bls, f"expected VM without backlight sysfs, found {bls}")

    pid0 = ctx.proc.get_shell_pid()
    for cmd in ("brightness-up", "brightness-down"):
        ctx.proc.kaze_msg(cmd, timeout=3.0)
    time.sleep(0.25)
    ctx.require(ctx.proc.get_shell_pid() == pid0, "daemon crashed on brightness command with no backlight")
    rc, out, _ = ctx.proc.kaze_msg("ping")
    ctx.require(rc == 0 and out == "pong", "daemon unresponsive after brightness command")

    bar = ctx.proc.wait_layer("kaze-bar-Virtual-1", present=True, timeout=3.0)
    ctx.require(bar is not None, "bar missing")
    png_path = Path("/tmp/kaze-blind-c02-bar.png")
    ctx.vis.capture_png(png_path, region=(bar["x"], bar["y"], bar["w"], bar["h"]))
    words = [w["text"] for w in ctx.vis.ocr_words(png_path)]
    png_path.unlink(missing_ok=True)
    bad_tokens = [w for w in words if "NaN" in w or w == "0%"]
    ctx.require(not bad_tokens, f"bar rendered bogus battery/sensor value(s): {bad_tokens}")

    # Verify journalctl does not spam repeated error lines over 2s
    t_start = time.strftime("%Y-%m-%d %H:%M:%S")
    time.sleep(2.0)
    j = subprocess.run(
        ["journalctl", "--user", "-u", "kaze-shell.service", "--since", t_start, "--no-pager", "-q"],
        capture_output=True,
        text=True,
        timeout=5,
    )
    lines = [l for l in j.stdout.splitlines() if l.strip()]
    ctx.require(len(lines) <= 5, f"log spam detected ({len(lines)} lines in 2s) with missing hardware")


def _wait_osd_region(ctx: BlindContext) -> dict:
    osd = ctx.proc.wait_layer("kaze-osd", present=True, timeout=1.5, interval=0.02)
    ctx.require(osd is not None, "kaze-osd layer did not appear")
    return osd


def test_c03_volume_osd_and_burst_timer(ctx: BlindContext) -> None:
    # Warm up OSD once so baseline memfd reflects steady pool
    subprocess.run(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "0"], check=True, timeout=3)
    subprocess.run(["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "0.40"], check=True, timeout=3)
    ctx.proc.wait_layer("kaze-osd", present=True, timeout=1.5)
    ctx.proc.wait_layer("kaze-osd", present=False, timeout=4.0)
    time.sleep(0.2)

    pid0 = ctx.proc.get_shell_pid()
    base_memfd = ctx.proc.snapshot(pid0)["memfd_count"]

    try:
        crops = []
        for args in (
            ["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "0.00"],
            ["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "0.50"],
            ["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "1.00"],
            ["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "1"],
        ):
            t_req = time.monotonic()
            subprocess.run(args, check=True, timeout=3)
            osd = ctx.proc.wait_layer("kaze-osd", present=True, timeout=0.6, interval=0.02)
            lat_ms = (time.monotonic() - t_req) * 1000.0
            ctx.require(osd is not None, f"kaze-osd did not appear after {' '.join(args)}")
            ctx.require(lat_ms < 250.0, f"kaze-osd appearance latency {lat_ms:.0f}ms too slow")
            time.sleep(0.12)
            crops.append(ctx.vis.capture_ppm(region=(osd["x"], osd["y"], osd["w"], osd["h"])))

        for i in range(len(crops)):
            for j in range(i + 1, len(crops)):
                d = ctx.vis.diff_stats(crops[i], crops[j], threshold=14)
                ctx.require(d["changed_count"] > 10, f"OSD states {i} and {j} rendered identically")

        # Burst 10 volume changes in 600ms, verify timer resets from last event
        subprocess.run(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "0"], check=True, timeout=3)
        for i in range(10):
            vol = f"0.{20 + i * 5:02d}"
            subprocess.run(["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", vol], check=True, timeout=3)
            t_last = time.monotonic()
            time.sleep(0.055)

        time.sleep(0.8)
        ctx.require(bool(ctx.proc.find_layers(namespace="kaze-osd")), "OSD timer did not reset on burst (disappeared < 0.8s after last change)")

        deadline = t_last + 4.0
        t_gone: float | None = None
        while time.monotonic() <= deadline:
            if not ctx.proc.find_layers(namespace="kaze-osd"):
                t_gone = time.monotonic()
                break
            time.sleep(0.05)
        ctx.require(t_gone is not None, "kaze-osd never auto-dismissed after burst")
        elapsed = t_gone - t_last
        ctx.require(1.0 <= elapsed <= 3.5, f"OSD auto-dismiss elapsed={elapsed:.2f}s outside 1.0..3.5s")

        time.sleep(0.2)
        end_memfd = ctx.proc.snapshot(pid0)["memfd_count"]
        ctx.require(
            end_memfd <= base_memfd + 1,
            f"memfd leaked after OSD cycle: {base_memfd} -> {end_memfd}",
        )
    finally:
        subprocess.run(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "0"], capture_output=True, timeout=3)
        subprocess.run(["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "0.50"], capture_output=True, timeout=3)
        ctx.proc.wait_layer("kaze-osd", present=False, timeout=4.0)


def test_c04_bar_slot_clicks_vol_and_notifications(ctx: BlindContext) -> None:
    bar = ctx.proc.wait_layer("kaze-bar-Virtual-1", present=True, timeout=3.0)
    ctx.require(bar is not None, "kaze-bar-Virtual-1 missing")
    region = (bar["x"], bar["y"], bar["w"], bar["h"])

    try:
        # Locate vol slot by diffing unmuted vs muted bar
        subprocess.run(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "0"], check=True, timeout=3)
        subprocess.run(["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "0.50"], check=True, timeout=3)
        ctx.proc.wait_layer("kaze-osd", present=False, timeout=4.0)
        time.sleep(0.25)
        bar_unmuted = ctx.vis.capture_ppm(region=region)

        subprocess.run(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "1"], check=True, timeout=3)
        ctx.proc.wait_layer("kaze-osd", present=False, timeout=4.0)
        time.sleep(0.25)
        bar_muted = ctx.vis.capture_ppm(region=region)

        diff_vol = ctx.vis.diff_stats(bar_unmuted, bar_muted, threshold=14)
        ctx.require(diff_vol["bbox"] is not None, "vol slot icon did not change visually on mute")
        bx0, by0, bx1, by1 = diff_vol["bbox"]
        vx = bar["x"] + (bx0 + bx1) // 2
        vy = bar["y"] + (by0 + by1) // 2

        # Right-click vol slot -> should unmute
        ctx.inp.right_click(vx, vy)
        time.sleep(0.3)
        _, muted1 = _wpctl_volume()
        ctx.require(not muted1, f"right-click on vol slot ({vx},{vy}) did not unmute sink")

        # Right-click again -> mute, then unmute via right-click
        ctx.inp.right_click(vx, vy)
        time.sleep(0.3)
        _, muted2 = _wpctl_volume()
        ctx.require(muted2, "second right-click on vol slot did not mute sink")
        ctx.inp.right_click(vx, vy)
        time.sleep(0.3)

        # Scroll up & down on vol slot
        v0, _ = _wpctl_volume()
        ctx.inp.scroll(vx, vy, direction="up", steps=2)
        time.sleep(0.3)
        v_up, _ = _wpctl_volume()
        ctx.require(v_up > v0 + 0.01, f"scroll up on vol slot did not increase volume ({v0} -> {v_up})")

        ctx.inp.scroll(vx, vy, direction="down", steps=2)
        time.sleep(0.3)
        v_down, _ = _wpctl_volume()
        ctx.require(v_down < v_up - 0.01, f"scroll down on vol slot did not decrease volume ({v_up} -> {v_down})")

        # Locate notifications slot by diffing dnd-off vs dnd-on (cursor away from bar)
        ctx.inp.move(960, 540)
        ctx.proc.kaze_msg("dnd-off")
        time.sleep(0.25)
        bar_dnd_off = ctx.vis.capture_ppm(region=region)
        ctx.proc.kaze_msg("dnd-on")
        time.sleep(0.25)
        bar_dnd_on = ctx.vis.capture_ppm(region=region)

        diff_dnd = ctx.vis.diff_stats(bar_dnd_off, bar_dnd_on, threshold=14)
        ctx.require(diff_dnd["bbox"] is not None, "notifications slot icon did not change visually on DND toggle")
        nx0, ny0, nx1, ny1 = diff_dnd["bbox"]
        nx = bar["x"] + (nx0 + nx1) // 2
        ny = bar["y"] + (ny0 + ny1) // 2

        ctx.inp.click(nx, ny, button="left")
        ctx.inp.move(960, 540)
        time.sleep(0.3)
        _, dnd_st, _ = ctx.proc.kaze_msg("dnd-status")
        ctx.require(dnd_st == "off", f"left-click on notifications slot ({nx},{ny}) left dnd-status={dnd_st!r}, expected 'off'")
        bar_after = ctx.vis.capture_ppm(region=region)
        ctx.require(
            ctx.vis.diff_stats(bar_dnd_off, bar_after, threshold=14)["changed_count"] <= 5,
            "notifications slot icon did not revert visually after left-click DND toggle",
        )
    finally:
        ctx.proc.kaze_msg("dnd-off")
        subprocess.run(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "0"], capture_output=True, timeout=3)
        subprocess.run(["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "0.50"], capture_output=True, timeout=3)
        ctx.proc.wait_layer("kaze-osd", present=False, timeout=4.0)


TESTS = {
    "C01": test_c01_thread_cap_and_dbus_resilience,
    "C02": test_c02_missing_hardware_graceful,
    "C03": test_c03_volume_osd_and_burst_timer,
    "C04": test_c04_bar_slot_clicks_vol_and_notifications,
}
