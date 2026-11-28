#!/usr/bin/env python3
"""Suite B: T0 cold-boot budget, Bar geometry & color channel, clock, workspaces, hotplug."""

from __future__ import annotations

import json
from pathlib import Path
import re
import subprocess
import time

from runner import BlindContext, TestFailure


def test_b01_t0_cold_boot(ctx: BlindContext) -> None:
    portals = ctx.proc.active_portals()
    ctx.require(not portals, f"early portal(s) activated at T0: {portals}")

    pid = ctx.proc.get_shell_pid()
    threads = ctx.proc.read_threads(pid)
    ctx.require(threads <= 5, f"kaze-shell thread count {threads} > 5")

    sampler_path = ctx.repo_dir / "tests" / "vm" / "idle_sampler.py"
    res = subprocess.run(
        ["python3", "-u", str(sampler_path), "--phase", "T0", "--guest-sudo-pss"],
        capture_output=True,
        text=True,
        timeout=130,
    )
    ctx.require(
        res.returncode == 0,
        f"idle_sampler T0 failed: {(res.stderr or res.stdout).strip()}",
    )

    # Independent strict check for kaze-shell alone (<= 45 MiB without wallpaper, <= 60 MiB with)
    pss_kib = ctx.proc.read_pss_kib(pid)
    has_wall = bool(ctx.proc.find_layers(prefix="kaze-wallpaper-"))
    limit_mib = 60.0 if has_wall else 45.0
    pss_mib = pss_kib / 1024.0
    ctx.require(
        pss_mib <= limit_mib,
        f"kaze-shell T0 PSS={pss_mib:.2f} MiB exceeds budget <= {limit_mib:.0f} MiB",
    )


def _write_red_palette(path: Path) -> None:
    pal = {
        "version": 2,
        "base": "Kaze-BlindRed",
        "dark": {
            "primary": "#e61919",
            "on_primary": "#ffffff",
            "secondary": "#e61919",
            "on_secondary": "#ffffff",
            "tertiary": "#e61919",
            "on_tertiary": "#ffffff",
            "error": "#e61919",
            "on_error": "#ffffff",
            "surface": "#121216",
            "on_surface": "#f0f0f0",
            "surface_container": "#1a1a20",
            "on_surface_container": "#f0f0f0",
            "surface_variant": "#26262e",
            "on_surface_variant": "#b0b0b8",
            "outline": "#3a3a44",
            "outline_variant": "#2c2c34",
        },
        "light": {
            "primary": "#e61919",
            "on_primary": "#ffffff",
            "secondary": "#e61919",
            "on_secondary": "#ffffff",
            "tertiary": "#e61919",
            "on_tertiary": "#ffffff",
            "error": "#e61919",
            "on_error": "#ffffff",
            "surface": "#f4f4f6",
            "on_surface": "#141418",
            "surface_container": "#e8e8ec",
            "on_surface_container": "#141418",
            "surface_variant": "#dcdce2",
            "on_surface_variant": "#404048",
            "outline": "#b8b8c2",
            "outline_variant": "#d0d0d8",
        },
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(pal, indent=2), encoding="utf-8")


def test_b02_bar_geometry_and_color_channel(ctx: BlindContext) -> None:
    cfg_path = Path.home() / ".config" / "kaze-shell" / "config.toml"
    pal_path = Path.home() / ".config" / "kaze-shell" / "palettes" / "Kaze-BlindRed.json"
    original_cfg = cfg_path.read_text(encoding="utf-8")

    try:
        _write_red_palette(pal_path)
        updated = re.sub(
            r'(?m)^(palette\s*=\s*)"[^"]*"',
            r'\1"Kaze-BlindRed"',
            original_cfg,
            count=1,
        )
        updated = re.sub(r'(?m)^(mode\s*=\s*)"[^"]*"', r'\1"dark"', updated, count=1)
        cfg_path.write_text(updated, encoding="utf-8")
        time.sleep(0.45)
        ctx.proc.kaze_msg("templates-apply")
        time.sleep(0.3)

        bar = ctx.proc.wait_layer("kaze-bar-Virtual-1", present=True, timeout=3.0)
        ctx.require(bar is not None, "kaze-bar-Virtual-1 missing")
        ctx.require(bar["w"] == 42, f"bar width={bar['w']}px, expected 42px")
        ctx.require(bar["x"] <= 16, f"bar x={bar['x']}px, expected left edge (<= 16)")
        ctx.require(1040 <= bar["h"] <= 1080, f"bar height={bar['h']}px outside 1040..1080")

        ctx.proc.switch_workspace(1)
        time.sleep(0.25)
        full_img = ctx.vis.capture_ppm(output="Virtual-1")
        bar_region = (bar["x"], bar["y"], bar["w"], bar["h"])
        desk_region = (300, 300, bar["w"], 200)
        bar_mean = ctx.vis.mean_rgb(full_img, (bar["x"], bar["y"], bar["x"] + bar["w"] - 1, bar["y"] + 200))
        desk_mean = ctx.vis.mean_rgb(full_img, (300, 300, 300 + bar["w"] - 1, 500))
        ctx.require(
            sum(abs(a - b) for a, b in zip(bar_mean, desk_mean)) > 12.0,
            f"bar pixels indistinguishable from desktop background: bar={bar_mean}, desk={desk_mean}",
        )

        img_ws1 = ctx.vis.capture_ppm(region=bar_region)
        ctx.proc.switch_workspace(3)
        time.sleep(0.25)
        img_ws3 = ctx.vis.capture_ppm(region=bar_region)

        diff = ctx.vis.diff_stats(img_ws1, img_ws3, threshold=18)
        ctx.require(len(diff["y_bands"]) >= 2, "expected WS 1 and WS 3 indicators to produce 2 distinct diff bands")
        ws3_band = diff["y_bands"][-1]
        ws3_bbox = (0, ws3_band[0], bar["w"] - 1, ws3_band[1])
        chroma = ctx.vis.chromatic_stats(img_ws3, region_bbox=ws3_bbox, min_sat=50)
        ctx.require(
            chroma["count"] >= 10,
            f"no chromatic accent pixels found on active WS 3 indicator (bbox={ws3_bbox})",
        )
        ctx.require(
            chroma["mean_r"] > 170.0 and chroma["mean_b"] < 70.0,
            f"active workspace region mean RGB=({chroma['mean_r']:.0f}, {chroma['mean_g']:.0f}, {chroma['mean_b']:.0f}), "
            "expected high R (>170) / low B (<70) — suspected ARGB/ABGR color channel swap",
        )
    finally:
        try:
            ctx.proc.switch_workspace(1)
        except Exception:
            pass
        cfg_path.write_text(original_cfg, encoding="utf-8")
        pal_path.unlink(missing_ok=True)
        time.sleep(0.35)
        ctx.proc.kaze_msg("templates-apply")
        time.sleep(0.25)


def test_b03_clock_rollover_no_polling(ctx: BlindContext) -> None:
    bar = ctx.proc.wait_layer("kaze-bar-Virtual-1", present=True, timeout=3.0)
    ctx.require(bar is not None, "kaze-bar-Virtual-1 missing")
    pid = ctx.proc.get_shell_pid()

    # Align to start of a minute (sec <= 6)
    while True:
        sec = time.localtime().tm_sec
        if sec <= 6:
            break
        if sec >= 55:
            time.sleep(1.0)
        else:
            time.sleep(min(60 - sec + 0.2, 5.0))

    # Center third of vertical rail holds vclock
    clock_region = (bar["x"], bar["y"] + bar["h"] // 3, bar["w"], bar["h"] // 3)
    while time.localtime().tm_sec < 10:
        time.sleep(0.2)

    img_early = ctx.vis.capture_ppm(region=clock_region)
    cs0 = ctx.proc.read_ctx_switches(pid)
    t0 = time.monotonic()
    while time.localtime().tm_sec < 50:
        time.sleep(0.5)
    dt = max(time.monotonic() - t0, 1.0)
    cs_rate = (ctx.proc.read_ctx_switches(pid) - cs0) / dt
    img_late = ctx.vis.capture_ppm(region=clock_region)

    ctx.require(
        ctx.vis.diff_stats(img_early, img_late, threshold=12)["changed_count"] == 0,
        "clock region redrew spuriously between :10 and :50",
    )
    ctx.require(
        cs_rate <= 4.0,
        f"excessive wakeups during quiet minute interval: {cs_rate:.2f} CS/s (budget <= 4.0, suspected 1s clock polling)",
    )

    while time.localtime().tm_sec < 57:
        time.sleep(0.2)
    img_57 = ctx.vis.capture_ppm(region=clock_region)

    now_wall = time.time()
    next_min_wall = (int(now_wall) // 60 + 1) * 60.0
    while time.time() < next_min_wall - 0.05:
        time.sleep(0.03)

    changed_at: float | None = None
    deadline_wall = next_min_wall + 0.9
    while time.time() <= deadline_wall:
        snap = ctx.vis.capture_ppm(region=clock_region)
        if ctx.vis.diff_stats(img_57, snap, threshold=14)["changed_count"] >= 5:
            changed_at = time.time()
            break
        time.sleep(0.04)

    ctx.require(changed_at is not None, "clock pixels did not update across minute boundary (suspected frozen clock)")
    lag_ms = (changed_at - next_min_wall) * 1000.0
    ctx.require(lag_ms <= 500.0, f"clock minute rollover lag was {lag_ms:.0f}ms (budget <= 500ms)")


def test_b04_workspace_two_way(ctx: BlindContext) -> None:
    bar = ctx.proc.wait_layer("kaze-bar-Virtual-1", present=True, timeout=3.0)
    ctx.require(bar is not None, "kaze-bar-Virtual-1 missing")
    bar_region = (bar["x"], bar["y"], bar["w"], bar["h"])

    ctx.proc.switch_workspace(2)
    time.sleep(0.25)
    img_ws2 = ctx.vis.capture_ppm(region=bar_region)

    ctx.proc.switch_workspace(3)
    time.sleep(0.25)
    img_ws3 = ctx.vis.capture_ppm(region=bar_region)

    diff = ctx.vis.diff_stats(img_ws2, img_ws3, threshold=16)
    ctx.require(
        len(diff["y_bands"]) >= 2,
        f"expected 2 distinct workspace indicator bands between WS 2 and WS 3, got {len(diff['y_bands'])}",
    )
    ws2_band = diff["y_bands"][0]  # upper band is WS 2
    click_x = bar["x"] + ws2_band[2]
    click_y = bar["y"] + ws2_band[3]

    ctx.inp.click(click_x, click_y, button="left")
    deadline = time.monotonic() + 1.2
    active_id = None
    while time.monotonic() < deadline:
        active_id = ctx.proc.hypr_json("activeworkspace").get("id")
        if active_id == 2:
            break
        time.sleep(0.05)
    try:
        ctx.proc.switch_workspace(1)
    except Exception:
        pass
    ctx.require(
        active_id == 2,
        f"left-click on WS 2 bar button at ({click_x},{click_y}) left activeworkspace={active_id}, expected 2",
    )


def test_b05_display_slot_and_bar_hide_show(ctx: BlindContext) -> None:
    subprocess.run(["hyprctl", "output", "create", "headless", "kaze-share"], check=True, capture_output=True, timeout=5)
    try:
        ctx.require(
            ctx.proc.wait_layer("kaze-bar-kaze-share", present=True, timeout=4.0) is not None,
            "kaze-bar-kaze-share did not appear after headless output creation",
        )
        rc, _, err = ctx.proc.kaze_msg("bar-hide", "kaze-share")
        ctx.require(rc == 0, f"bar-hide kaze-share failed: {err}")
        ctx.require(
            ctx.proc.wait_layer("kaze-bar-kaze-share", present=False, timeout=3.0) is True,
            "kaze-bar-kaze-share stayed present after bar-hide",
        )
        v1 = ctx.proc.find_layers(namespace="kaze-bar-Virtual-1")
        ctx.require(bool(v1), "kaze-bar-Virtual-1 disappeared when hiding kaze-share bar")

        rc, _, err = ctx.proc.kaze_msg("bar-show", "kaze-share")
        ctx.require(rc == 0, f"bar-show kaze-share failed: {err}")
        ctx.require(
            ctx.proc.wait_layer("kaze-bar-kaze-share", present=True, timeout=3.0) is not None,
            "kaze-bar-kaze-share did not reappear after bar-show",
        )

        bar = v1[0]
        region = (bar["x"], bar["y"], bar["w"], bar["h"])
        ctx.proc.kaze_msg("display-status", "idle")
        time.sleep(0.2)
        img_idle = ctx.vis.capture_ppm(region=region)
        ctx.proc.kaze_msg("display-status", "virtual-share", "WS 9")
        time.sleep(0.25)
        img_active = ctx.vis.capture_ppm(region=region)
        changed = ctx.vis.diff_stats(img_idle, img_active, threshold=12)["changed_count"]
        ctx.require(changed > 4, "bar display slot pixels did not change on display-status virtual-share")
    finally:
        ctx.proc.kaze_msg("display-status", "idle")
        subprocess.run(["hyprctl", "output", "remove", "kaze-share"], capture_output=True, timeout=5)
        ctx.proc.wait_layer("kaze-bar-kaze-share", present=False, timeout=3.0)


def test_b06_hotplug_scale_transform_and_leak(ctx: BlindContext) -> None:
    # Warm up 1 cycle
    subprocess.run(["hyprctl", "output", "create", "headless", "kaze-share"], check=True, capture_output=True, timeout=5)
    ctx.proc.wait_layer("kaze-bar-kaze-share", present=True, timeout=4.0)
    subprocess.run(["hyprctl", "output", "remove", "kaze-share"], check=True, capture_output=True, timeout=5)
    ctx.proc.wait_layer("kaze-bar-kaze-share", present=False, timeout=4.0)
    time.sleep(0.5)

    pid0 = ctx.proc.get_shell_pid()
    snap0 = ctx.proc.snapshot(pid0)

    # Fractional scales and 90-degree rotation on headless output
    subprocess.run(["hyprctl", "output", "create", "headless", "kaze-scale-test"], check=True, capture_output=True, timeout=5)
    try:
        ctx.require(
            ctx.proc.wait_layer("kaze-bar-kaze-scale-test", present=True, timeout=4.0) is not None,
            "kaze-bar-kaze-scale-test did not appear",
        )
        subprocess.run(
            ["hyprctl", "eval", 'hl.monitor({ output = "kaze-scale-test", mode = "1920x1080@60", position = "5000x0", scale = 1.25 })'],
            check=True,
            capture_output=True,
            timeout=5,
        )
        time.sleep(0.4)
        l125 = ctx.proc.find_layers(namespace="kaze-bar-kaze-scale-test")
        ctx.require(bool(l125) and 830 <= l125[0]["h"] <= 870, f"unexpected bar height at scale 1.25: {l125}")

        subprocess.run(
            ["hyprctl", "eval", 'hl.monitor({ output = "kaze-scale-test", mode = "1920x1080@60", position = "5000x0", scale = 1.5 })'],
            check=True,
            capture_output=True,
            timeout=5,
        )
        time.sleep(0.4)
        l150 = ctx.proc.find_layers(namespace="kaze-bar-kaze-scale-test")
        ctx.require(bool(l150) and 690 <= l150[0]["h"] <= 725, f"unexpected bar height at scale 1.5: {l150}")

        subprocess.run(
            ["hyprctl", "eval", 'hl.monitor({ output = "kaze-scale-test", mode = "1920x1080@60", position = "5000x0", scale = 1.5, transform = 1 })'],
            check=True,
            capture_output=True,
            timeout=5,
        )
        time.sleep(0.4)
        lrot = ctx.proc.find_layers(namespace="kaze-bar-kaze-scale-test")
        ctx.require(bool(lrot) and 1240 <= lrot[0]["h"] <= 1285, f"unexpected bar height after 90deg transform: {lrot}")
    finally:
        subprocess.run(["hyprctl", "output", "remove", "kaze-scale-test"], capture_output=True, timeout=5)
        ctx.proc.wait_layer("kaze-bar-kaze-scale-test", present=False, timeout=4.0)

    # 20x create/remove cycle
    for _ in range(20):
        subprocess.run(["hyprctl", "output", "create", "headless", "kaze-share"], check=True, capture_output=True, timeout=5)
        ctx.require(
            ctx.proc.wait_layer("kaze-bar-kaze-share", present=True, timeout=4.0) is not None,
            "kaze-bar-kaze-share failed to appear during hotplug loop",
        )
        subprocess.run(["hyprctl", "output", "remove", "kaze-share"], check=True, capture_output=True, timeout=5)
        ctx.require(
            ctx.proc.wait_layer("kaze-bar-kaze-share", present=False, timeout=4.0) is True,
            "zombie kaze-bar-kaze-share remained after output removal",
        )

    time.sleep(1.0)
    pid1 = ctx.proc.get_shell_pid()
    ctx.require(pid1 == pid0, "daemon restarted during 20x hotplug loop")
    snap1 = ctx.proc.snapshot(pid1)
    ctx.require(
        snap1["memfd_count"] <= snap0["memfd_count"] + 1,
        f"memfd leaked across hotplug loop: {snap0['memfd_count']} -> {snap1['memfd_count']}",
    )
    pss_delta = snap1["pss_kib"] - snap0["pss_kib"]
    ctx.require(
        pss_delta <= 512,
        f"PSS grew by {pss_delta} KiB across 20x hotplug loop (budget <= 512 KiB)",
    )


TESTS = {
    "B01": test_b01_t0_cold_boot,
    "B02": test_b02_bar_geometry_and_color_channel,
    "B03": test_b03_clock_rollover_no_polling,
    "B04": test_b04_workspace_two_way,
    "B05": test_b05_display_slot_and_bar_hide_show,
    "B06": test_b06_hotplug_scale_transform_and_leak,
}
