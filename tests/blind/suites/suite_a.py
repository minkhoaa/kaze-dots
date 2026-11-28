#!/usr/bin/env python3
"""Suite A: Daemon lifecycle, binary purity, IPC fuzzing, Hyprland bridge, config & themes."""

from __future__ import annotations

import concurrent.futures
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import stat
import subprocess
import tempfile
import time

from runner import BlindContext, TestFailure


def test_a01_binary_purity(ctx: BlindContext) -> None:
    bin_path = shutil.which("kaze-shell")
    ctx.require(bin_path is not None, "kaze-shell binary not found in PATH")
    forbidden = re.compile(r"libgtk|libQt|libEGL|libGL\.|libvulkan|libwgpu", re.I)

    ldd = subprocess.run(["ldd", bin_path], capture_output=True, text=True, timeout=5)
    ctx.require(ldd.returncode == 0, f"ldd failed: {ldd.stderr.strip()}")
    bad_ldd = [l.strip() for l in ldd.stdout.splitlines() if forbidden.search(l)]
    ctx.require(not bad_ldd, f"forbidden dynamic libraries linked in ldd: {bad_ldd}")

    readelf = subprocess.run(["readelf", "-d", bin_path], capture_output=True, text=True, timeout=5)
    ctx.require(readelf.returncode == 0, f"readelf failed: {readelf.stderr.strip()}")
    bad_elf = [l.strip() for l in readelf.stdout.splitlines() if "NEEDED" in l and forbidden.search(l)]
    ctx.require(not bad_elf, f"forbidden NEEDED entries in ELF: {bad_elf}")

    nm = subprocess.run(["nm", "-D", bin_path], capture_output=True, text=True, timeout=5)
    ctx.require(nm.returncode == 0, f"nm -D failed: {nm.stderr.strip()}")
    bad_sym = [l.strip() for l in nm.stdout.splitlines() if re.search(r"gtk_init|QApplication|wgpu", l)]
    ctx.require(not bad_sym, f"forbidden UI runtime symbols found: {bad_sym[:3]}")

    ctx.require(shutil.which("noctalia") is None, "noctalia binary still present in PATH")
    pac = subprocess.run(["pacman", "-Q", "noctalia"], capture_output=True, text=True, timeout=5)
    ctx.require(pac.returncode != 0, "noctalia package still installed")
    pg = subprocess.run(["pgrep", "-x", "noctalia"], capture_output=True, text=True, timeout=5)
    ctx.require(not pg.stdout.strip(), "running noctalia process detected")
    svc = subprocess.run(
        ["systemctl", "--user", "is-active", "--quiet", "kaze-noctalia.service"],
        timeout=5,
    )
    ctx.require(svc.returncode != 0, "kaze-noctalia.service is active")


def test_a02_singleton_and_socket_perms(ctx: BlindContext) -> None:
    pid1 = ctx.proc.get_shell_pid()
    start1, _ = ctx.proc.read_stat(pid1)
    sock_path = ctx.proc.runtime_dir() / "kaze" / "shell.sock"
    ctx.require(sock_path.exists(), f"missing IPC socket {sock_path}")
    st = sock_path.stat()
    ctx.require(stat.S_ISSOCK(st.st_mode), "shell.sock is not a UNIX socket")
    mode = stat.S_IMODE(st.st_mode)
    ctx.require(mode == 0o600, f"shell.sock permissions are {oct(mode)}, expected 0o600")
    ctx.require(st.st_uid == os.getuid(), f"shell.sock uid={st.st_uid} != current uid={os.getuid()}")

    t0 = time.monotonic()
    dup = subprocess.run(
        ["kaze-shell", "daemon"],
        capture_output=True,
        text=True,
        timeout=3,
    )
    elapsed = time.monotonic() - t0
    ctx.require(dup.returncode != 0, "second kaze-shell daemon exited with 0 instead of failing")
    ctx.require(elapsed < 1.0, f"duplicate daemon took {elapsed:.2f}s to exit (expected < 1.0s)")

    pid_now = ctx.proc.get_shell_pid()
    start_now, _ = ctx.proc.read_stat(pid_now)
    ctx.require(pid_now == pid1 and start_now == start1, "original daemon PID changed after duplicate launch")
    rc, out, _ = ctx.proc.kaze_msg("ping")
    ctx.require(rc == 0 and out == "pong", "original daemon stopped responding after duplicate launch")


def test_a03_stale_socket_recovery(ctx: BlindContext) -> None:
    sock_path = ctx.proc.runtime_dir() / "kaze" / "shell.sock"
    subprocess.run(["systemctl", "--user", "stop", "kaze-shell.service"], check=True, timeout=8)
    try:
        proc = subprocess.Popen(
            ["kaze-shell", "daemon"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        deadline = time.monotonic() + 4.0
        while time.monotonic() < deadline:
            rc, out, _ = ctx.proc.kaze_msg("ping", timeout=1.0)
            if rc == 0 and out == "pong":
                break
            time.sleep(0.05)
        else:
            proc.kill()
            raise TestFailure("manual daemon failed to become ready for stale socket test")

        proc.kill()
        proc.wait(timeout=3)
        ctx.require(sock_path.exists(), "expected stale shell.sock to remain after SIGKILL")

        subprocess.run(["systemctl", "--user", "start", "kaze-shell.service"], check=True, timeout=8)
        ctx.wait_daemon_ready()
        layer = ctx.proc.wait_layer("kaze-bar-Virtual-1", present=True, timeout=4.0)
        ctx.require(layer is not None, "bar layer missing after recovering from stale socket")
    finally:
        subprocess.run(["systemctl", "--user", "start", "kaze-shell.service"], capture_output=True, timeout=8)
        ctx.wait_daemon_ready()


def test_a04_ipc_fuzz_and_concurrency(ctx: BlindContext) -> None:
    pid0 = ctx.proc.get_shell_pid()
    start0, _ = ctx.proc.read_stat(pid0)
    sock_path = str(ctx.proc.runtime_dir() / "kaze" / "shell.sock")
    bogus = ctx.nonce("bogus")

    payloads: list[bytes] = [
        b"",
        b"\n",
        b"\xff\xfe\x00\x80\xf0\x9f\n",
        b"A" * (1024 * 1024),
        f"{bogus}\n".encode("utf-8"),
        b"   \t  \n",
        b'{"json": [1,2,3]}\n',
        b"layout-set non_existent_preset\n",
        b"island-activity display {broken\n",
        b"ping\n",
    ] * 2  # 20 concurrent clients

    def hammer(idx: int, data: bytes) -> None:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(2.0)
            s.connect(sock_path)
            if idx % 5 == 0 and not data:
                # Immediate EOF
                return
            s.sendall(data)
            if idx % 3 == 0:
                s.shutdown(socket.SHUT_WR)
                try:
                    s.recv(4096)
                except OSError:
                    pass

    with concurrent.futures.ThreadPoolExecutor(max_workers=20) as pool:
        futs = [pool.submit(hammer, i, p) for i, p in enumerate(payloads)]
        for f in concurrent.futures.as_completed(futs, timeout=10.0):
            f.result()

    pid1 = ctx.proc.get_shell_pid()
    start1, _ = ctx.proc.read_stat(pid1)
    ctx.require(pid1 == pid0 and start1 == start0, "daemon restarted or crashed during IPC fuzzing")

    t0 = time.monotonic()
    rc, out, _ = ctx.proc.kaze_msg("ping", timeout=2.0)
    lat_ms = (time.monotonic() - t0) * 1000.0
    ctx.require(rc == 0 and out == "pong", f"ping failed after IPC fuzzing (rc={rc}, out={out!r})")
    ctx.require(lat_ms < 100.0, f"ping latency after fuzz was {lat_ms:.1f}ms (budget < 100ms)")


def test_a05_hyprland_socket2_recovery(ctx: BlindContext) -> None:
    pid0 = ctx.proc.get_shell_pid()
    start0, _ = ctx.proc.read_stat(pid0)
    ctx.proc.switch_workspace(1)
    time.sleep(0.2)
    bar = ctx.proc.wait_layer("kaze-bar-Virtual-1", present=True, timeout=3.0)
    ctx.require(bar is not None, "kaze-bar-Virtual-1 missing before reload test")
    region = (bar["x"], bar["y"], bar["w"], bar["h"])
    img_ws1 = ctx.vis.capture_ppm(region=region)

    for _ in range(10):
        subprocess.run(["hyprctl", "reload"], check=True, capture_output=True, timeout=5)
        time.sleep(0.2)

    pid1 = ctx.proc.get_shell_pid()
    start1, _ = ctx.proc.read_stat(pid1)
    ctx.require(pid1 == pid0 and start1 == start0, "daemon crashed or restarted across 10x hyprctl reload")

    ctx.proc.switch_workspace(4)
    deadline = time.monotonic() + 1.0
    changed = False
    while time.monotonic() < deadline:
        img_ws4 = ctx.vis.capture_ppm(region=region)
        if ctx.vis.diff_stats(img_ws1, img_ws4)["changed_count"] > 10:
            changed = True
            break
        time.sleep(0.05)
    try:
        ctx.proc.switch_workspace(1)
    except Exception:
        pass
    ctx.require(changed, "bar did not visually sync workspace 4 within 1s after 10x hyprctl reload")


def _replace_bar_thickness(toml_text: str, thickness: int) -> str:
    return re.sub(r"(?m)^(thickness\s*=\s*)\d+", rf"\g<1>{thickness}", toml_text, count=1)


def _wait_bar_width(ctx: BlindContext, expected_w: int, timeout: float = 0.5) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() <= deadline:
        layers = ctx.proc.find_layers(namespace="kaze-bar-Virtual-1")
        if layers and layers[0]["w"] == expected_w:
            return True
        time.sleep(0.03)
    return False


def test_a06_config_hot_reload_and_debounce(ctx: BlindContext) -> None:
    cfg_path = Path.home() / ".config" / "kaze-shell" / "config.toml"
    original = cfg_path.read_text(encoding="utf-8")
    pid0 = ctx.proc.get_shell_pid()

    try:
        # 1. Direct overwrite
        cfg_path.write_text(_replace_bar_thickness(original, 48), encoding="utf-8")
        ctx.require(_wait_bar_width(ctx, 48, 0.5), "bar thickness did not hot-reload to 48px within 500ms on direct write")
        ctx.require(ctx.proc.get_shell_pid() == pid0, "PID changed on direct config reload")

        # 2. Atomic write-temp + rename (new inode)
        tmp = cfg_path.with_name(f".blind-{ctx.nonce()}.tmp")
        tmp.write_text(_replace_bar_thickness(original, 44), encoding="utf-8")
        os.replace(tmp, cfg_path)
        ctx.require(_wait_bar_width(ctx, 44, 0.5), "bar thickness did not hot-reload to 44px within 500ms on atomic rename")
        ctx.require(ctx.proc.get_shell_pid() == pid0, "PID changed on atomic config reload")

        # 3. Symlink config.toml
        with tempfile.TemporaryDirectory() as td:
            target = Path(td) / "linked-config.toml"
            target.write_text(_replace_bar_thickness(original, 44), encoding="utf-8")
            cfg_path.unlink()
            cfg_path.symlink_to(target)
            time.sleep(0.15)
            target.write_text(_replace_bar_thickness(original, 46), encoding="utf-8")
            ctx.require(_wait_bar_width(ctx, 46, 0.6), "bar thickness did not hot-reload to 46px via symlinked config.toml")

        # Restore regular file and test debounce burst (5 writes in 30ms)
        cfg_path.unlink(missing_ok=True)
        cfg_path.write_text(_replace_bar_thickness(original, 46), encoding="utf-8")
        _wait_bar_width(ctx, 46, 0.5)
        cs_before = ctx.proc.read_ctx_switches(pid0)
        for val in (50, 52, 54, 56, 42):
            cfg_path.write_text(_replace_bar_thickness(original, val), encoding="utf-8")
            time.sleep(0.005)
        ctx.require(_wait_bar_width(ctx, 42, 0.6), "bar thickness did not settle to final debounced value 42px")
        time.sleep(0.3)
        cs_delta = ctx.proc.read_ctx_switches(pid0) - cs_before
        ctx.require(cs_delta < 500, f"config burst caused excessive context switches ({cs_delta})")
        ctx.require(ctx.proc.get_shell_pid() == pid0, "PID changed during config debounce burst")
    finally:
        cfg_path.unlink(missing_ok=True)
        cfg_path.write_text(original, encoding="utf-8")
        _wait_bar_width(ctx, 42, 1.0)


def test_a07_corrupt_partial_and_deleted_config(ctx: BlindContext) -> None:
    cfg_path = Path.home() / ".config" / "kaze-shell" / "config.toml"
    original = cfg_path.read_text(encoding="utf-8")
    pid0 = ctx.proc.get_shell_pid()
    start0, _ = ctx.proc.read_stat(pid0)

    try:
        # 1. Broken syntax
        cfg_path.write_text("[bar\nthickness = BROKEN_TOML\n", encoding="utf-8")
        time.sleep(0.35)
        ctx.require(ctx.proc.get_shell_pid() == pid0, "daemon crashed on broken TOML")
        layers = ctx.proc.find_layers(namespace="kaze-bar-Virtual-1")
        ctx.require(bool(layers) and layers[0]["w"] == 42, "daemon did not keep last known good 42px bar on broken TOML")

        # 2. Partial TOML missing half the sections
        cfg_path.write_text("[layout]\npreset = \"omarchy\"\n[bar]\nthickness = 46\n", encoding="utf-8")
        time.sleep(0.4)
        ctx.require(ctx.proc.get_shell_pid() == pid0, "daemon crashed on partial TOML")
        rc, out, _ = ctx.proc.kaze_msg("ping")
        ctx.require(rc == 0 and out == "pong", "daemon unresponsive after partial TOML")

        # 3. Deleted config.toml
        cfg_path.unlink()
        time.sleep(0.35)
        ctx.require(ctx.proc.get_shell_pid() == pid0, "daemon crashed when config.toml was deleted")
        rc, out, _ = ctx.proc.kaze_msg("ping")
        ctx.require(rc == 0 and out == "pong", "daemon unresponsive after config.toml deletion")

        # 4. Recreated valid config.toml should hot-reload again
        cfg_path.write_text(_replace_bar_thickness(original, 44), encoding="utf-8")
        ctx.require(_wait_bar_width(ctx, 44, 0.8), "hot-reload did not recover after config.toml was recreated")
        pid1 = ctx.proc.get_shell_pid()
        start1, _ = ctx.proc.read_stat(pid1)
        ctx.require(pid1 == pid0 and start1 == start0, "daemon PID/start_time changed during config fault test")
    finally:
        cfg_path.write_text(original, encoding="utf-8")
        _wait_bar_width(ctx, 42, 1.0)


def _spawn_sigusr2_watcher(comm_name: str, out_file: Path) -> subprocess.Popen[str]:
    script = """
import ctypes, signal, sys, time
from pathlib import Path
libc = ctypes.CDLL("libc.so.6", use_errno=True)
name = sys.argv[1].encode("utf-8")[:15] + b"\\x00"
libc.prctl(15, name, 0, 0, 0)
count = 0
out = Path(sys.argv[2])
out.write_text("0\\n")
def handler(_s, _f):
    global count
    count += 1
    out.write_text(f"{count}\\n")
signal.signal(signal.SIGUSR2, handler)
Path(sys.argv[3]).write_text("ready\\n")
while True:
    time.sleep(0.1)
"""
    ready_file = out_file.with_suffix(".ready")
    proc = subprocess.Popen(["python3", "-c", script, comm_name, str(out_file), str(ready_file)])
    deadline = time.monotonic() + 3.0
    while time.monotonic() < deadline:
        if ready_file.exists():
            return proc
        time.sleep(0.02)
    proc.kill()
    raise TestFailure(f"failed to start {comm_name} signal watcher helper")


def test_a08_atomic_theme_and_btop_sigusr2(ctx: BlindContext) -> None:
    targets = [
        Path.home() / ".config" / "hypr" / "kaze-theme.lua",
        Path.home() / ".config" / "foot" / "themes" / "kaze-shell",
        Path.home() / ".config" / "gtk-3.0" / "kaze-shell.css",
        Path.home() / ".config" / "gtk-4.0" / "kaze-shell.css",
        Path.home() / ".config" / "btop" / "themes" / "kaze-shell.theme",
    ]
    before_contents = {p: (p.read_text(errors="replace") if p.exists() else "") for p in targets}
    border_before = ctx.proc.hypr_option("general:col.active_border")

    with tempfile.TemporaryDirectory() as td:
        btop_cnt = Path(td) / "btop.cnt"
        fake_cnt = Path(td) / "fake.cnt"
        p_btop = _spawn_sigusr2_watcher("btop", btop_cnt)
        p_fake = _spawn_sigusr2_watcher("btop-fake", fake_cnt)
        try:
            ctx.require(ctx.proc.read_comm(p_btop.pid) == "btop", "helper comm was not set to 'btop'")
            ctx.require(ctx.proc.read_comm(p_fake.pid) == "btop-fake", "helper comm was not set to 'btop-fake'")

            rc, _, err = ctx.proc.kaze_msg("theme-mode-toggle", timeout=5.0)
            ctx.require(rc == 0, f"theme-mode-toggle failed: {err}")
            time.sleep(0.6)

            for p in targets:
                ctx.require(p.exists() and p.stat().st_size > 0, f"theme target missing/empty: {p}")
                after = p.read_text(errors="replace")
                ctx.require(after != before_contents[p], f"theme target did not update on mode toggle: {p.name}")
                leftover = [f.name for f in p.parent.iterdir() if ".tmp" in f.name or f.name.startswith(".kaze")]
                ctx.require(not leftover, f"leftover temp file(s) in {p.parent}: {leftover}")

            got_btop = int(btop_cnt.read_text().strip())
            got_fake = int(fake_cnt.read_text().strip())
            ctx.require(got_btop == 1, f"expected exact 1 SIGUSR2 to comm=='btop', got {got_btop}")
            ctx.require(got_fake == 0, f"expected 0 SIGUSR2 to comm=='btop-fake', got {got_fake}")

            border_after = ctx.proc.hypr_option("general:col.active_border")
            ctx.require(
                json.dumps(border_after, sort_keys=True) != json.dumps(border_before, sort_keys=True),
                "Hyprland general:col.active_border did not live-update after theme-mode-toggle",
            )
        finally:
            p_btop.kill()
            p_fake.kill()
            p_btop.wait(timeout=2)
            p_fake.wait(timeout=2)
            ctx.proc.kaze_msg("theme-mode-toggle")
            time.sleep(0.4)


def test_a09_clean_signal_shutdown(ctx: BlindContext) -> None:
    sock_path = ctx.proc.runtime_dir() / "kaze" / "shell.sock"
    subprocess.run(["systemctl", "--user", "stop", "kaze-shell.service"], check=True, timeout=8)
    try:
        for sig in (signal.SIGTERM, signal.SIGINT):
            proc = subprocess.Popen(
                ["kaze-shell", "daemon"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                start_new_session=True,
            )
            try:
                deadline = time.monotonic() + 4.0
                while time.monotonic() < deadline:
                    rc, out, _ = ctx.proc.kaze_msg("ping", timeout=1.0)
                    if rc == 0 and out == "pong":
                        break
                    time.sleep(0.05)
                else:
                    raise TestFailure(f"daemon did not start cleanly before {sig.name} test")

                t0 = time.monotonic()
                proc.send_signal(sig)
                rc = proc.wait(timeout=1.5)
                elapsed = time.monotonic() - t0
                ctx.require(elapsed < 1.0, f"{sig.name} shutdown took {elapsed:.2f}s (budget < 1s)")
                ctx.require(rc == 0, f"{sig.name} exited with code {rc} (expected 0)")
                ctx.require(not sock_path.exists(), f"stale shell.sock remained after {sig.name}")
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait(timeout=2)
    finally:
        subprocess.run(["systemctl", "--user", "start", "kaze-shell.service"], check=True, timeout=8)
        ctx.wait_daemon_ready()
        ctx.proc.wait_layer("kaze-bar-Virtual-1", present=True, timeout=4.0)


TESTS = {
    "A01": test_a01_binary_purity,
    "A02": test_a02_singleton_and_socket_perms,
    "A03": test_a03_stale_socket_recovery,
    "A04": test_a04_ipc_fuzz_and_concurrency,
    "A05": test_a05_hyprland_socket2_recovery,
    "A06": test_a06_config_hot_reload_and_debounce,
    "A07": test_a07_corrupt_partial_and_deleted_config,
    "A08": test_a08_atomic_theme_and_btop_sigusr2,
    "A09": test_a09_clean_signal_shutdown,
}
