#!/usr/bin/env python3
"""Suite I: Zero-Noctalia audit, apply.sh -> rollback.sh, and Chaos/Endurance Torture."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

from runner import BlindContext, TestFailure


def _pgrep_exact(name: str) -> list[int]:
    res = subprocess.run(["pgrep", "-x", name], capture_output=True, text=True, timeout=3)
    return [int(x) for x in res.stdout.split() if x.isdigit()]


def test_i01_zero_noctalia_and_session_boundaries(ctx: BlindContext) -> None:
    pac = subprocess.run(["pacman", "-Q", "noctalia"], capture_output=True, text=True, timeout=5)
    ctx.require(pac.returncode != 0, "noctalia package is installed")
    ctx.require(shutil.which("noctalia") is None, "noctalia found in PATH")
    ctx.require(not _pgrep_exact("noctalia"), "noctalia process is running")

    for cmd in (["kaze-doctor"], ["kaze-shell", "doctor"], ["kaze-shell", "inspect"]):
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        ctx.require(res.returncode == 0, f"{' '.join(cmd)} failed (rc={res.returncode}): {res.stderr.strip() or res.stdout.strip()}")

    shell_pid = ctx.proc.get_shell_pid()
    for unit in (
        "kaze-session.target",
        "kaze-shell.service",
        "kaze-hypridle.service",
        "kaze-polkit.service",
        "kaze-cliphist.service",
    ):
        st = subprocess.run(["systemctl", "--user", "is-active", unit], capture_output=True, text=True, timeout=5)
        ctx.require(st.stdout.strip() == "active", f"systemd user unit {unit} is {st.stdout.strip()!r}, expected 'active'")

    for proc_name in ("hypridle", "hyprpolkitagent", "wl-paste"):
        pids = _pgrep_exact(proc_name)
        ctx.require(bool(pids) and shell_pid not in pids, f"{proc_name} missing or sharing PID with kaze-shell: {pids}")

    # kaze-session lock triggers separate hyprlock process
    lock_p = subprocess.Popen(["kaze-session", "lock"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        lock_pids: list[int] = []
        deadline = time.monotonic() + 3.0
        while time.monotonic() < deadline:
            lock_pids = _pgrep_exact("hyprlock")
            if lock_pids:
                break
            time.sleep(0.05)
        ctx.require(bool(lock_pids), "kaze-session lock did not spawn hyprlock")
        ctx.require(shell_pid not in lock_pids, "hyprlock shares PID with kaze-shell")
    finally:
        subprocess.run(["pkill", "-USR1", "-x", "hyprlock"], capture_output=True, timeout=3)
        deadline = time.monotonic() + 3.0
        while time.monotonic() < deadline and _pgrep_exact("hyprlock"):
            time.sleep(0.05)
        if _pgrep_exact("hyprlock"):
            subprocess.run(["pkill", "-KILL", "-x", "hyprlock"], capture_output=True, timeout=2)
        lock_p.wait(timeout=3)


def test_i02_apply_and_rollback_lifecycle(ctx: BlindContext) -> None:
    n = ctx.nonce("rb")
    with tempfile.TemporaryDirectory() as td:
        base = Path(td)
        f_home = base / "home"
        f_cfg = base / "config"
        f_data = base / "data"
        f_cache = base / "cache"
        f_rt = base / "runtime"
        for d in (f_home, f_cfg / "hypr", f_cfg / "kaze-shell", f_cfg / "foot", f_cfg / "systemd" / "user", f_data, f_cache):
            d.mkdir(parents=True, exist_ok=True)
        f_rt.mkdir(mode=0o700, parents=True, exist_ok=True)

        seeded = {
            f_cfg / "kaze-shell" / "config.toml": f"# old kaze-shell {n}\n",
            f_cfg / "foot" / "foot.ini": f"# old foot {n}\n",
            f_cfg / "systemd" / "user" / "kaze-shell.service": f"# old unit {n}\n",
            f_home / ".zshrc": f"# old zshrc {n}\n",
            f_cfg / "hypr" / "user.lua": f"return {{}} -- user-{n}\n",
        }
        hashes = {}
        for p, content in seeded.items():
            p.write_text(content, encoding="utf-8")
            hashes[p] = hashlib.sha256(content.encode("utf-8")).hexdigest()

        env = dict(os.environ)
        env["HOME"] = str(f_home)
        env["XDG_CONFIG_HOME"] = str(f_cfg)
        env["XDG_DATA_HOME"] = str(f_data)
        env["XDG_CACHE_HOME"] = str(f_cache)
        env["XDG_RUNTIME_DIR"] = str(f_rt)

        apply_sh = ctx.repo_dir / "scripts" / "apply.sh"
        res_apply = subprocess.run([str(apply_sh), "--yes"], env=env, capture_output=True, text=True, timeout=20)
        ctx.require(res_apply.returncode == 0, f"apply.sh failed: {res_apply.stderr.strip()}")

        ctx.require((f_home / ".local" / "bin" / "kaze-shell").is_symlink(), "kaze-shell symlink not deployed by apply.sh")
        ctx.require((f_cfg / "systemd" / "user" / "kaze-shell.service").is_symlink(), "kaze-shell.service symlink missing")
        ctx.require((f_cfg / "kaze-shell" / "config.toml").is_file(), "kaze-shell/config.toml not seeded")

        last_bk = Path((f_cfg / "kaze" / "last-backup").read_text(encoding="utf-8").strip())
        rb_sh = last_bk / "rollback.sh"
        ctx.require(rb_sh.is_file(), "rollback.sh not generated")

        res_rb = subprocess.run([str(rb_sh), "--yes"], env=env, capture_output=True, text=True, timeout=20)
        ctx.require(res_rb.returncode == 0, f"rollback.sh failed: {res_rb.stderr.strip()}")

        for p, expected_hash in hashes.items():
            ctx.require(p.exists() and not p.is_symlink(), f"pre-existing file not restored as regular file: {p.name}")
            got = hashlib.sha256(p.read_bytes()).hexdigest()
            ctx.require(got == expected_hash, f"SHA-256 mismatch after rollback for {p.name}")

        ctx.require(not (f_home / ".local" / "bin" / "kaze-shell").exists(), "kaze-shell symlink survived rollback")
        ctx.require(not (f_cfg / "systemd" / "user" / "kaze-session.target").exists(), "kaze-session.target symlink survived rollback")


def test_i03_chaos_and_endurance_torture(ctx: BlindContext) -> None:
    # Warmup 1 cycle for allocator stabilization
    ctx.proc.kaze_msg("cc-open")
    ctx.proc.wait_layer("kaze-cc", present=True, timeout=2.0)
    ctx.proc.kaze_msg("cc-close")
    ctx.proc.wait_layer("kaze-cc", present=False, timeout=2.0)
    ctx.proc.kaze_msg("layout-set", "omarchy")
    ctx.proc.wait_layer("kaze-bar-Virtual-1", present=True, timeout=3.0)
    time.sleep(0.5)

    base_pid = ctx.proc.get_shell_pid()
    base_snap = ctx.proc.snapshot(base_pid)
    portals_before = set(ctx.proc.active_portals())

    try:
        # 1. 20x kaze-share hotplug interleaved with 10x hyprctl reload
        for i in range(20):
            subprocess.run(["hyprctl", "output", "create", "headless", "kaze-share"], check=True, capture_output=True, timeout=5)
            ctx.proc.wait_layer("kaze-bar-kaze-share", present=True, timeout=4.0)
            if i % 2 == 0:
                subprocess.run(["hyprctl", "reload"], check=True, capture_output=True, timeout=5)
                time.sleep(0.15)
            subprocess.run(["hyprctl", "output", "remove", "kaze-share"], check=True, capture_output=True, timeout=5)
            ctx.proc.wait_layer("kaze-bar-kaze-share", present=False, timeout=4.0)

        # 2. 20x layout-next
        for _ in range(20):
            ctx.proc.kaze_msg("layout-next")
            time.sleep(0.03)

        # 3. 30x cc-toggle
        ctx.proc.kaze_msg("layout-set", "omarchy")
        ctx.proc.wait_layer("kaze-bar-Virtual-1", present=True, timeout=3.0)
        for _ in range(30):
            ctx.proc.kaze_msg("cc-toggle")
            time.sleep(0.03)
        ctx.proc.kaze_msg("cc-close")
        ctx.proc.wait_layer("kaze-cc", present=False, timeout=2.0)

        # 4. 50x island-toggle
        ctx.proc.kaze_msg("layout-set", "island")
        ctx.proc.wait_layer("kaze-island", present=True, timeout=3.0)
        for _ in range(50):
            ctx.proc.kaze_msg("island-toggle")
            time.sleep(0.025)
        ctx.proc.kaze_msg("layout-set", "omarchy")
        ctx.proc.wait_layer("kaze-bar-Virtual-1", present=True, timeout=3.0)

        # 5. 30x notify-send (Vietnamese / Emoji / critical)
        for i in range(30):
            urg = "critical" if i % 10 == 9 else "normal"
            subprocess.run(
                ["notify-send", "-u", urg, "-t", "2000", f"Chaos #{i}", f"Tiếng Việt 🚀 {ctx.nonce('c')}"],
                capture_output=True,
                timeout=3,
            )
            time.sleep(0.02)
        ctx.proc.kaze_msg("notify-clear")
        ctx.proc.wait_layer("kaze-notify", present=False, timeout=2.0)

        # 6. 10x dmenu open + Esc
        for _ in range(10):
            dp = subprocess.Popen(
                ["kaze-shell", "dmenu"],
                stdin=subprocess.PIPE,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            dp.stdin.write(b"Item1\nItem2\n")
            dp.stdin.close()
            ctx.proc.wait_layer("kaze-launcher", present=True, timeout=2.0)
            ctx.inp.key("esc")
            dp.wait(timeout=3)
            ctx.proc.wait_layer("kaze-launcher", present=False, timeout=2.0)

        # 7. 10x mock_sni start/stop
        with tempfile.TemporaryDirectory() as td:
            for i in range(10):
                ready = Path(td) / f"r{i}"
                mp = subprocess.Popen(
                    [
                        "python3",
                        str(ctx.harness_dir / "mock_sni.py"),
                        "--profile",
                        "pixmap_green",
                        "--id",
                        f"chaos-tray-{i}",
                        "--ready",
                        str(ready),
                    ]
                )
                deadline = time.monotonic() + 2.5
                while time.monotonic() < deadline and not ready.exists():
                    time.sleep(0.03)
                time.sleep(0.1)
                mp.terminate()
                mp.wait(timeout=2)
                time.sleep(0.05)

        # Settle 10s, then run 60s idle_sampler (--phase T2)
        time.sleep(10.0)
        end_pid = ctx.proc.get_shell_pid()
        ctx.require(end_pid == base_pid, f"kaze-shell PID changed during torture: {base_pid} -> {end_pid}")

        end_snap = ctx.proc.snapshot(end_pid)
        ctx.require(end_snap["start_time"] == base_snap["start_time"], "kaze-shell restarted during torture")

        layers = ctx.proc.list_layers()
        zombies = [
            l["namespace"]
            for l in layers
            if l["namespace"] != "kaze-bar-Virtual-1"
        ]
        ctx.require(not zombies, f"zombie layers left after torture: {zombies}")

        ctx.require(
            end_snap["fd_total"] <= base_snap["fd_total"] + 2,
            f"FD leak after torture: {base_snap['fd_total']} -> {end_snap['fd_total']}",
        )
        ctx.require(
            end_snap["memfd_count"] <= base_snap["memfd_count"] + 2,
            f"memfd leak after torture: {base_snap['memfd_count']} -> {end_snap['memfd_count']}",
        )
        pss_delta = end_snap["pss_kib"] - base_snap["pss_kib"]
        ctx.require(
            pss_delta <= 3072,
            f"PSS grew by {pss_delta} KiB after torture (budget <= +3072 KiB)",
        )
        ctx.require(
            end_snap["pss_kib"] <= 61440,
            f"PSS after torture={end_snap['pss_kib']/1024:.2f} MiB exceeds 60 MiB cap",
        )

        # Measure 60s idle CPU & CS/s and verify 0 portals
        idle = ctx.proc.measure_idle(end_pid, 60.0)
        ctx.require(idle["pid_alive"] and idle["same_start_time"], "daemon died during post-torture idle check")
        ctx.require(idle["cpu_pct"] <= 0.20, f"post-torture idle CPU={idle['cpu_pct']:.2f}% > 0.20%")
        ctx.require(idle["cs_per_sec"] <= 4.0, f"post-torture CS/s={idle['cs_per_sec']:.2f} > 4.0")
        new_portals = sorted(set(ctx.proc.active_portals()) - portals_before)
        ctx.require(not new_portals, f"kaze-shell torture activated portal(s): {new_portals}")
    finally:
        subprocess.run(["hyprctl", "output", "remove", "kaze-share"], capture_output=True, timeout=3)
        ctx.proc.kaze_msg("notify-clear")
        ctx.proc.kaze_msg("cc-close")
        ctx.proc.kaze_msg("launcher-close")
        ctx.proc.kaze_msg("layout-set", "omarchy")


TESTS = {
    "I01": test_i01_zero_noctalia_and_session_boundaries,
    "I02": test_i02_apply_and_rollback_lifecycle,
    "I03": test_i03_chaos_and_endurance_torture,
}
