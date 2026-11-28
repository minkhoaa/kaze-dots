#!/usr/bin/env python3
"""Suite F: Spring animations & zero-idle, 4 layout presets, user.lua/kaze-share isolation, persistence."""

from __future__ import annotations

import hashlib
from pathlib import Path
import subprocess
import time

from runner import BlindContext, TestFailure


def test_f01_animation_motion_and_zero_idle(ctx: BlindContext) -> None:
    rc, _, err = ctx.proc.kaze_msg("layout-set", "island")
    ctx.require(rc == 0, f"layout-set island failed: {err}")
    ctx.require(
        ctx.proc.wait_layer("kaze-island", present=True, timeout=3.0) is not None,
        "kaze-island did not appear",
    )
    time.sleep(0.8)

    region = (560, 0, 800, 340)
    pid = ctx.proc.get_shell_pid()

    # Fire island-toggle and capture rapid frames over 450ms
    hashes: list[str] = []
    p = subprocess.Popen(["kaze-shell", "msg", "island-toggle"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    t_end = time.monotonic() + 0.48
    while time.monotonic() < t_end:
        img = ctx.vis.capture_ppm(region=region)
        h = ctx.vis.sha256_img(img)
        if not hashes or hashes[-1] != h:
            hashes.append(h)
        time.sleep(0.015)
    p.wait(timeout=3)
    ctx.require(
        len(set(hashes)) >= 3,
        f"expected >= 3 distinct intermediate animation frames during island-toggle, got {len(set(hashes))}",
    )

    # Wait for spring convergence (and avoid :00 clock rollover inside the 10s quiet check)
    time.sleep(2.0)
    if time.localtime().tm_sec >= 45:
        while time.localtime().tm_sec >= 45 or time.localtime().tm_sec <= 1:
            time.sleep(0.2)
    img_settled = ctx.vis.capture_ppm(region=region)
    t0_stat = ctx.proc.read_stat(pid)[1]
    w0 = time.monotonic()
    for _ in range(4):
        time.sleep(2.5)
        img_chk = ctx.vis.capture_ppm(region=region)
        ctx.require(
            ctx.vis.diff_stats(img_settled, img_chk, threshold=10)["changed_count"] == 0,
            "island surface kept redrawing after animation settled",
        )
    dt = time.monotonic() - w0
    t1_stat = ctx.proc.read_stat(pid)[1]
    cpu_pct = ((t1_stat - t0_stat) / ctx.proc.CLK_TCK) / dt * 100.0
    ctx.require(
        cpu_pct <= 0.05,
        f"post-animation idle CPU={cpu_pct:.3f}% exceeds <= 0.05% budget",
    )
    ctx.proc.kaze_msg("island-toggle")
    time.sleep(0.4)


def _get_int_opt(ctx: BlindContext, name: str) -> int:
    return int(ctx.proc.hypr_option(name)["int"])


def test_f02_four_presets_geometry(ctx: BlindContext) -> None:
    try:
        # 1. omarchy
        ctx.proc.kaze_msg("layout-set", "omarchy")
        bar_om = ctx.proc.wait_layer("kaze-bar-Virtual-1", present=True, timeout=3.0)
        ctx.require(bar_om is not None, "omarchy bar missing")
        ctx.require(bar_om["w"] == 42 and bar_om["x"] <= 16, f"omarchy bar geometry unexpected: {bar_om}")
        ctx.require(_get_int_opt(ctx, "decoration:rounding") == 0, "omarchy rounding != 0")
        time.sleep(0.25)
        ctx.save_artifact("preset-omarchy.png", output="Virtual-1")

        # 2. island
        ctx.proc.kaze_msg("layout-set", "island")
        isl = ctx.proc.wait_layer("kaze-island", present=True, timeout=3.0)
        ctx.require(isl is not None, "island layer missing")
        ctx.require(_get_int_opt(ctx, "decoration:rounding") == 12, "island rounding != 12")
        time.sleep(0.35)
        ctx.save_artifact("preset-island.png", output="Virtual-1")

        # 3. swiss
        ctx.proc.kaze_msg("layout-set", "swiss")
        bar_sw = ctx.proc.wait_layer("kaze-bar-Virtual-1", present=True, timeout=3.0)
        ctx.proc.wait_layer("kaze-island", present=False, timeout=2.0)
        ctx.require(bar_sw is not None, "swiss bar missing")
        ctx.require(bar_sw["h"] == 30 and bar_sw["y"] <= 16 and bar_sw["w"] >= 1880, f"swiss bar geometry unexpected: {bar_sw}")
        ctx.require(_get_int_opt(ctx, "decoration:rounding") == 0, "swiss rounding != 0")
        time.sleep(0.25)
        ctx.save_artifact("preset-swiss.png", output="Virtual-1")

        # 4. ghost + bar-peek on/off
        ctx.proc.kaze_msg("layout-set", "ghost")
        ctx.require(
            ctx.proc.wait_layer("kaze-bar-Virtual-1", present=False, timeout=3.0) is True,
            "ghost preset still showed persistent bar",
        )
        time.sleep(0.25)
        ctx.save_artifact("preset-ghost.png", output="Virtual-1")

        ctx.proc.kaze_msg("bar-peek", "on")
        bar_pk = ctx.proc.wait_layer("kaze-bar-Virtual-1", present=True, timeout=3.0)
        ctx.require(bar_pk is not None, "bar-peek on did not reveal bar in ghost preset")
        time.sleep(0.25)
        ctx.save_artifact("preset-ghost-peek.png", output="Virtual-1")

        ctx.proc.kaze_msg("bar-peek", "off")
        ctx.require(
            ctx.proc.wait_layer("kaze-bar-Virtual-1", present=False, timeout=3.0) is True,
            "bar-peek off did not hide bar in ghost preset",
        )

        # Verify layout-next cycles all 4 presets cleanly
        seen = set()
        for _ in range(4):
            ctx.proc.kaze_msg("layout-next")
            time.sleep(0.25)
            _, st, _ = ctx.proc.kaze_msg("layout-status")
            seen.add(st.strip())
        ctx.require(
            {"omarchy", "island", "swiss", "ghost"}.issubset(seen),
            f"layout-next did not cycle all 4 presets, saw {seen}",
        )
    finally:
        ctx.proc.kaze_msg("layout-set", "omarchy")
        ctx.proc.wait_layer("kaze-bar-Virtual-1", present=True, timeout=3.0)


def test_f03_user_lua_and_kaze_share_isolation(ctx: BlindContext) -> None:
    user_lua = Path.home() / ".config" / "hypr" / "user.lua"
    orig_user = user_lua.read_text(encoding="utf-8") if user_lua.exists() else None
    n = ctx.nonce("ulua")
    custom = f'return {{ kb_layout = "us", accel_profile = "flat" }} -- {n}\n'
    user_lua.write_text(custom, encoding="utf-8")
    expected_sha = hashlib.sha256(custom.encode("utf-8")).hexdigest()

    win_proc: subprocess.Popen | None = None
    addr: str | None = None
    try:
        subprocess.run(["kaze-display", "virtual-share", "9"], check=True, capture_output=True, text=True, timeout=10)
        time.sleep(0.35)

        win_proc = subprocess.Popen(
            ["kaze-footclient", "-T", f"blind-share-{n}", "-e", "sleep", "30"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        addr = None
        deadline = time.monotonic() + 4.0
        while time.monotonic() < deadline:
            for c in ctx.proc.hypr_json("clients"):
                if c.get("title") == f"blind-share-{n}":
                    addr = c.get("address")
                    break
            if addr:
                break
            time.sleep(0.1)
        ctx.require(addr is not None, "test foot client did not spawn")
        ctx.proc.move_window_to_workspace(addr, 9, silent=True)
        time.sleep(0.25)

        for _ in range(8):
            ctx.proc.kaze_msg("layout-next")
            time.sleep(0.2)
            ctx.require(
                not ctx.proc.find_layers(output="kaze-share"),
                f"unwanted layer(s) appeared on kaze-share: {ctx.proc.find_layers(output='kaze-share')}",
            )

        actual_sha = hashlib.sha256(user_lua.read_bytes()).hexdigest()
        ctx.require(actual_sha == expected_sha, "layout switching modified ~/.config/hypr/user.lua")

        share_mon = next((m for m in ctx.proc.hypr_json("monitors") if m["name"] == "kaze-share"), None)
        ctx.require(share_mon is not None, "kaze-share monitor disappeared during layout cycle")
        client = next((c for c in ctx.proc.hypr_json("clients") if c.get("address") == addr), None)
        ctx.require(client is not None, "test window on kaze-share disappeared")
        ctx.require(
            tuple(client["at"]) == (share_mon["x"], share_mon["y"])
            and tuple(client["size"]) == (share_mon["width"], share_mon["height"]),
            f"kaze-share window not edge-to-edge 0-gap: at={client['at']} size={client['size']} vs mon=({share_mon['x']},{share_mon['y']},{share_mon['width']}x{share_mon['height']})",
        )
    finally:
        if addr:
            ctx.proc.close_window_by_address(addr)
        if win_proc is not None and win_proc.poll() is None:
            win_proc.terminate()
            try:
                win_proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                win_proc.kill()
        subprocess.run(["kaze-display", "stop-virtual"], capture_output=True, timeout=8)
        if orig_user is None:
            user_lua.unlink(missing_ok=True)
        else:
            user_lua.write_text(orig_user, encoding="utf-8")
        ctx.proc.kaze_msg("layout-set", "omarchy")
        ctx.proc.wait_layer("kaze-bar-Virtual-1", present=True, timeout=3.0)


def test_f04_preset_persistence_across_restart(ctx: BlindContext) -> None:
    try:
        rc, _, err = ctx.proc.kaze_msg("layout-set", "swiss")
        ctx.require(rc == 0, f"layout-set swiss failed: {err}")
        ctx.require(ctx.proc.wait_layer("kaze-bar-Virtual-1", present=True, timeout=3.0) is not None, "swiss bar missing")
        time.sleep(0.3)

        subprocess.run(["systemctl", "--user", "restart", "kaze-shell.service"], check=True, timeout=10)
        ctx.wait_daemon_ready()
        bar = ctx.proc.wait_layer("kaze-bar-Virtual-1", present=True, timeout=4.0)
        ctx.require(bar is not None, "bar missing after restart")
        _, st, _ = ctx.proc.kaze_msg("layout-status")
        ctx.require(st.strip() == "swiss", f"layout-status after restart={st!r}, expected 'swiss'")
        ctx.require(bar["h"] == 30 and bar["w"] >= 1880, f"bar geometry after restart={bar}, expected swiss 30px top bar")
    finally:
        ctx.proc.kaze_msg("layout-set", "omarchy")
        ctx.proc.wait_layer("kaze-bar-Virtual-1", present=True, timeout=3.0)


TESTS = {
    "F01": test_f01_animation_motion_and_zero_idle,
    "F02": test_f02_four_presets_geometry,
    "F03": test_f03_user_lua_and_kaze_share_isolation,
    "F04": test_f04_preset_persistence_across_restart,
}
