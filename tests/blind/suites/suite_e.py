#!/usr/bin/env python3
"""Suite E: dmenu, edge-case stdin, App Launcher (.desktop + inotify), process detach, keyboard & IME."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import time

from runner import BlindContext, TestFailure


def _spawn_dmenu(stdin_bytes: bytes, *extra_args: str) -> subprocess.Popen[bytes]:
    return subprocess.Popen(
        ["kaze-shell", "dmenu", *extra_args],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def _run_dmenu_with_input(
    ctx: BlindContext,
    stdin_bytes: bytes,
    action_fn,
    *extra_args: str,
    step_name: str = "dmenu",
) -> tuple[int, bytes, bytes, float]:
    t0 = time.monotonic()
    proc = subprocess.Popen(
        ["kaze-shell", "dmenu", *extra_args],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert proc.stdin is not None
    try:
        proc.stdin.write(stdin_bytes)
        proc.stdin.close()
    except BrokenPipeError:
        pass

    layer = ctx.proc.wait_layer("kaze-launcher", present=True, timeout=2.0, interval=0.01)
    open_ms = (time.monotonic() - t0) * 1000.0
    if layer is None:
        proc.kill()
        _, err = proc.communicate(timeout=2)
        raise TestFailure(f"[{step_name}] kaze-launcher did not appear (stderr={err.decode(errors='replace')!r})")

    time.sleep(0.08)
    try:
        action_fn(layer)
        out, err = proc.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        ocr_txt = ""
        ime_st = ""
        try:
            tmp_p = Path("/tmp/kaze-blind-dmenu-timeout.png")
            ctx.vis.capture_png(tmp_p, region=(layer["x"], layer["y"], layer["w"], min(layer["h"], 90)))
            ocr_txt = " ".join(w["text"] for w in ctx.vis.ocr_words(tmp_p))
            tmp_p.unlink(missing_ok=True)
            ime_st = subprocess.run(["fcitx5-remote"], capture_output=True, text=True, timeout=1).stdout.strip()
        except Exception:
            pass
        proc.kill()
        proc.communicate(timeout=2)
        raise TestFailure(f"[{step_name}] dmenu did not submit within 5s (filter_ocr={ocr_txt!r}, fcitx5_state={ime_st!r})")
    except Exception:
        proc.kill()
        proc.communicate(timeout=2)
        raise
    finally:
        ctx.proc.wait_layer("kaze-launcher", present=False, timeout=2.0)
    return proc.returncode, out, err, open_ms


def test_e01_dmenu_select_and_cancel(ctx: BlindContext) -> None:
    pid0 = ctx.proc.get_shell_pid()
    # Warmup once
    rc_w, _, _, _ = _run_dmenu_with_input(
        ctx, b"Warm\n", lambda _l: ctx.inp.key("esc"), "--prompt", "Warm>"
    )
    ctx.require(rc_w == 1, f"warmup dmenu Esc returned {rc_w}")
    base_memfd = ctx.proc.snapshot(pid0)["memfd_count"]

    n = ctx.nonce("beta")
    payload = f"Alpha\nBeta-{n}\nGamma\n".encode("utf-8")

    def select_beta(_layer):
        ctx.save_artifact("launcher-dmenu.png", output="Virtual-1")
        ctx.inp.type_ascii("beta")
        time.sleep(0.08)
        ctx.inp.key("ret")

    rc, out, _err, open_ms = _run_dmenu_with_input(ctx, payload, select_beta, "--prompt", "Pick>")
    ctx.require(open_ms < 150.0, f"dmenu launch latency {open_ms:.1f}ms too high")
    ctx.require(rc == 0, f"dmenu select exited with {rc}, expected 0")
    ctx.require(out == f"Beta-{n}\n".encode("utf-8"), f"dmenu stdout mismatch: {out!r}")

    rc2, out2, _err2, _ = _run_dmenu_with_input(
        ctx, payload, lambda _l: ctx.inp.key("esc"), "--prompt", "Pick>"
    )
    ctx.require(rc2 == 1, f"dmenu Escape exited with {rc2}, expected 1")
    ctx.require(out2 == b"", f"dmenu Escape produced non-empty stdout: {out2!r}")
    end_memfd = ctx.proc.snapshot(pid0)["memfd_count"]
    ctx.require(end_memfd <= base_memfd + 1, f"memfd leaked after dmenu: {base_memfd} -> {end_memfd}")


def test_e02_dmenu_edge_inputs(ctx: BlindContext) -> None:
    pid0 = ctx.proc.get_shell_pid()

    # (a) Empty stdin
    p_empty = subprocess.Popen(
        ["kaze-shell", "dmenu"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    time.sleep(0.25)
    if ctx.proc.find_layers(namespace="kaze-launcher"):
        ctx.inp.key("esc")
    out_e, _ = p_empty.communicate(timeout=3)
    ctx.require(p_empty.returncode in (0, 1) and out_e == b"", f"empty stdin unexpected result rc={p_empty.returncode} out={out_e!r}")
    ctx.proc.wait_layer("kaze-launcher", present=False, timeout=2.0)

    # (b) No trailing newline
    n1 = ctx.nonce("only")
    rc, out, _, _ = _run_dmenu_with_input(ctx, f"OnlyOne-{n1}".encode("utf-8"), lambda _l: ctx.inp.key("ret"))
    ctx.require(rc == 0 and out == f"OnlyOne-{n1}\n".encode("utf-8"), f"no-newline input failed: rc={rc} out={out!r}")

    # (c) 10,000 lines performance + memory
    n2 = ctx.nonce("tgt")
    lines = [f"Item-{i:05d}" for i in range(9999)]
    lines.insert(5432, f"TargetUnique-{n2}")
    big_payload = ("\n".join(lines) + "\n").encode("utf-8")

    def filter_big(_layer):
        t0 = time.monotonic()
        ctx.inp.type_ascii("targetunique")
        filter_ms = (time.monotonic() - t0) * 1000.0
        time.sleep(0.08)
        ctx.inp.key("ret")
        ctx.require(filter_ms < 800.0, f"typing filter stalled: {filter_ms:.0f}ms")

    rc_b, out_b, _, _ = _run_dmenu_with_input(ctx, big_payload, filter_big)
    ctx.require(rc_b == 0 and out_b == f"TargetUnique-{n2}\n".encode("utf-8"), f"10k line filter failed: rc={rc_b} out={out_b!r}")

    # (d) Vietnamese, Nerd Font glyph, tab, quotes, backslash exact round-trip
    n3 = ctx.nonce("spec")
    special_line = f'󰍹  Tiếng Việt {n3}\t"quoted" \'single\' \\slash'
    payload_sp = f"Plain\n{special_line}\n".encode("utf-8")

    def pick_second(_layer):
        ctx.inp.key("down")
        time.sleep(0.05)
        ctx.inp.key("ret")

    rc_s, out_s, _, _ = _run_dmenu_with_input(ctx, payload_sp, pick_second)
    ctx.require(
        rc_s == 0 and out_s == (special_line + "\n").encode("utf-8"),
        f"special-char round-trip corrupted bytes: {out_s!r}",
    )

    # (e) Invalid flag -> exit code 2 + stderr
    bad = subprocess.run(["kaze-shell", "dmenu", "--bogus"], capture_output=True, text=True, timeout=3)
    ctx.require(bad.returncode == 2, f"invalid dmenu flag returned {bad.returncode}, expected 2")
    ctx.require(bool(bad.stderr.strip()), "invalid dmenu flag produced empty stderr")
    ctx.require(ctx.proc.get_shell_pid() == pid0, "daemon PID changed during dmenu edge tests")


def test_e03_concurrent_dmenu_and_helpers(ctx: BlindContext) -> None:
    pid0 = ctx.proc.get_shell_pid()
    p1 = subprocess.Popen(
        ["kaze-shell", "dmenu", "--prompt", "One>"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    p1.stdin.write(b"One\nTwo\n")
    p1.stdin.close()
    ctx.require(ctx.proc.wait_layer("kaze-launcher", present=True, timeout=2.0) is not None, "first dmenu failed to open")

    p2 = subprocess.Popen(
        ["kaze-shell", "dmenu", "--prompt", "Two>"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    p2.stdin.write(b"Three\nFour\n")
    p2.stdin.close()
    time.sleep(0.2)
    ctx.inp.key("esc")
    time.sleep(0.15)
    if ctx.proc.find_layers(namespace="kaze-launcher"):
        ctx.inp.key("esc")

    p1.communicate(timeout=3)
    p2.communicate(timeout=3)
    ctx.require(ctx.proc.wait_layer("kaze-launcher", present=False, timeout=2.0) is True, "launcher hung after concurrent dmenu")
    ctx.require(ctx.proc.get_shell_pid() == pid0, "daemon crashed on concurrent dmenu")

    # Test real Lua helpers kaze-display --menu and kaze-keys
    for helper_cmd in (["kaze-display", "--menu"], ["kaze-keys"]):
        hp = subprocess.Popen(helper_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        ctx.require(
            ctx.proc.wait_layer("kaze-launcher", present=True, timeout=2.5) is not None,
            f"{' '.join(helper_cmd)} did not open kaze-launcher",
        )
        time.sleep(0.1)
        ctx.inp.key("esc")
        _, herr = hp.communicate(timeout=4)
        ctx.require(hp.returncode == 0, f"{' '.join(helper_cmd)} exited {hp.returncode}: {herr.decode(errors='replace')}")
        ctx.proc.wait_layer("kaze-launcher", present=False, timeout=2.0)


def _write_desktop(path: Path, body: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body, encoding="utf-8")


def test_e04_desktop_inotify_and_exec_fields(ctx: BlindContext) -> None:
    apps_dir = Path.home() / ".local" / "share" / "applications"
    n = ctx.nonce("app")
    ok_marker = Path(f"/tmp/kaze-blind-ok-{n}")
    term_marker = Path(f"/tmp/kaze-blind-term-{n}")
    files = [
        apps_dir / f"blind-normal-{n}.desktop",
        apps_dir / f"blind-nodisp-{n}.desktop",
        apps_dir / f"blind-hidden-{n}.desktop",
        apps_dir / f"blind-term-{n}.desktop",
    ]
    pid0 = ctx.proc.get_shell_pid()

    try:
        _write_desktop(
            files[0],
            f"[Desktop Entry]\nType=Application\nName=BlindNormalApp {n}\nExec=/bin/sh -c \"touch {ok_marker}\" %u %F\nTerminal=false\n",
        )
        _write_desktop(
            files[1],
            f"[Desktop Entry]\nType=Application\nName=BlindNoDispApp {n}\nExec=/bin/sh -c \"touch /tmp/kaze-bad1-{n}\"\nNoDisplay=true\n",
        )
        _write_desktop(
            files[2],
            f"[Desktop Entry]\nType=Application\nName=BlindHiddenApp {n}\nExec=/bin/sh -c \"touch /tmp/kaze-bad2-{n}\"\nHidden=true\n",
        )
        _write_desktop(
            files[3],
            f"[Desktop Entry]\nType=Application\nName=BlindTermApp {n}\nExec=/bin/sh -c \"touch {term_marker}\"\nTerminal=true\n",
        )
        time.sleep(0.5)  # allow inotify scan without daemon restart
        ctx.require(ctx.proc.get_shell_pid() == pid0, "daemon restarted during .desktop creation")

        # Verify NoDisplay and Hidden do not launch
        for query, bad_marker in (
            (f"BlindNoDispApp {n}", Path(f"/tmp/kaze-bad1-{n}")),
            (f"BlindHiddenApp {n}", Path(f"/tmp/kaze-bad2-{n}")),
        ):
            ctx.proc.kaze_msg("launcher-toggle")
            ctx.proc.wait_layer("kaze-launcher", present=True, timeout=2.0)
            time.sleep(0.08)
            ctx.inp.type_ascii(query)
            time.sleep(0.1)
            ctx.inp.key("ret")
            time.sleep(0.25)
            ctx.proc.kaze_msg("launcher-close")
            ctx.proc.wait_layer("kaze-launcher", present=False, timeout=2.0)
            ctx.require(not bad_marker.exists(), f"hidden/NoDisplay desktop entry {query} was launched")

        # Launch Normal entry (%u %F stripped)
        ctx.proc.kaze_msg("launcher-toggle")
        ctx.proc.wait_layer("kaze-launcher", present=True, timeout=2.0)
        time.sleep(0.08)
        ctx.inp.type_ascii(f"BlindNormalApp {n}")
        time.sleep(0.12)
        ctx.inp.key("ret")
        ctx.proc.wait_layer("kaze-launcher", present=False, timeout=2.0)

        deadline = time.monotonic() + 3.0
        while time.monotonic() < deadline and not ok_marker.exists():
            time.sleep(0.05)
        ctx.require(ok_marker.exists(), "inotify-discovered .desktop app did not execute or failed on %u %F")

        # Launch Terminal=true entry (must execute via terminal)
        ctx.proc.kaze_msg("launcher-toggle")
        ctx.proc.wait_layer("kaze-launcher", present=True, timeout=2.0)
        time.sleep(0.08)
        ctx.inp.type_ascii(f"BlindTermApp {n}")
        time.sleep(0.12)
        ctx.inp.key("ret")
        ctx.proc.wait_layer("kaze-launcher", present=False, timeout=2.0)

        deadline = time.monotonic() + 3.0
        while time.monotonic() < deadline and not term_marker.exists():
            time.sleep(0.05)
        ctx.require(term_marker.exists(), "Terminal=true .desktop app did not execute")
    finally:
        for f in files:
            f.unlink(missing_ok=True)
        ok_marker.unlink(missing_ok=True)
        term_marker.unlink(missing_ok=True)
        Path(f"/tmp/kaze-bad1-{n}").unlink(missing_ok=True)
        Path(f"/tmp/kaze-bad2-{n}").unlink(missing_ok=True)
        ctx.proc.kaze_msg("launcher-close")


def _find_pid_by_env(needle: bytes) -> int | None:
    for p in Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            if needle in (p / "environ").read_bytes():
                return int(p.name)
        except OSError:
            continue
    return None


def test_e05_process_detachment(ctx: BlindContext) -> None:
    apps_dir = Path.home() / ".local" / "share" / "applications"
    n = ctx.nonce("detach")
    desktop = apps_dir / f"blind-detach-{n}.desktop"
    child_pid: int | None = None

    try:
        _write_desktop(
            desktop,
            f"[Desktop Entry]\nType=Application\nName=BlindDetach {n}\nExec=/usr/bin/env KAZE_BLIND_DETACH={n} sleep 90\nTerminal=false\n",
        )
        time.sleep(0.45)
        ctx.proc.kaze_msg("launcher-toggle")
        ctx.proc.wait_layer("kaze-launcher", present=True, timeout=2.0)
        time.sleep(0.08)
        ctx.inp.type_ascii(f"BlindDetach {n}")
        time.sleep(0.12)
        ctx.inp.key("ret")
        ctx.proc.wait_layer("kaze-launcher", present=False, timeout=2.0)

        marker = f"KAZE_BLIND_DETACH={n}".encode("utf-8")
        deadline = time.monotonic() + 3.0
        while time.monotonic() < deadline:
            child_pid = _find_pid_by_env(marker)
            if child_pid is not None:
                break
            time.sleep(0.05)
        ctx.require(child_pid is not None, "detached .desktop process did not spawn")

        old_pid = ctx.proc.get_shell_pid()
        subprocess.run(["kill", "-9", str(old_pid)], check=True, timeout=3)
        new_pid = ctx.wait_daemon_ready(timeout=6.0)
        ctx.require(new_pid != old_pid, "daemon did not restart after SIGKILL")
        ctx.proc.wait_layer("kaze-bar-Virtual-1", present=True, timeout=4.0)
        ctx.require(ctx.proc.pid_alive(child_pid), "launched app died when kaze-shell daemon was killed/restarted")
    finally:
        if child_pid is not None and ctx.proc.pid_alive(child_pid):
            try:
                os.kill(child_pid, 15)
            except OSError:
                pass
        desktop.unlink(missing_ok=True)
        ctx.proc.kaze_msg("launcher-close")


def test_e06_keyboard_nav_unicode_and_ime(ctx: BlindContext) -> None:
    n = ctx.nonce("ime")
    items = f"Alpha\nBeta-{n}\nTiếng Việt {n}\n".encode("utf-8")

    # 1. Wrap-around at top/bottom boundary + Down/Up + Ctrl+N/Ctrl+P + Backspace
    def nav_wrap_top(_l):
        ctx.inp.key("up")  # wraps from row 0 to last row (Tiếng Việt)
        ctx.inp.key("ret")

    rc0, out0, _, _ = _run_dmenu_with_input(ctx, items, nav_wrap_top, step_name="E06.wrap_top")
    ctx.require(rc0 == 0 and out0 == f"Tiếng Việt {n}\n".encode("utf-8"), f"Up wrap-around from top selected {out0!r}")

    def nav_keys(_l):
        ctx.inp.key("down")
        ctx.inp.key("down")
        ctx.inp.key("up")
        ctx.inp.key("ret")

    rc1, out1, _, _ = _run_dmenu_with_input(ctx, items, nav_keys, step_name="E06.down_up")
    ctx.require(rc1 == 0 and out1 == f"Beta-{n}\n".encode("utf-8"), f"Down/Up navigation selected {out1!r}")

    def nav_ctrl_np(_l):
        ctx.inp.key("ctrl", "n")
        ctx.inp.key("ctrl", "n")
        ctx.inp.key("ctrl", "p")
        ctx.inp.key("ret")

    rc2, out2, _, _ = _run_dmenu_with_input(ctx, items, nav_ctrl_np, step_name="E06.ctrl_np")
    ctx.require(rc2 == 0 and out2 == f"Beta-{n}\n".encode("utf-8"), f"Ctrl+N/P navigation selected {out2!r}")

    def type_backspace(_l):
        ctx.inp.type_ascii("alpx")
        ctx.inp.key("backspace")
        time.sleep(0.06)
        ctx.inp.key("ret")

    rc3, out3, _, _ = _run_dmenu_with_input(ctx, items, type_backspace, step_name="E06.backspace")
    ctx.require(rc3 == 0 and out3 == b"Alpha\n", f"Backspace editing selected {out3!r}")

    # 2. Direct Unicode via wtype
    def type_wtype(layer):
        reg = (layer["x"], layer["y"], layer["w"], layer["h"])
        img_before = ctx.vis.capture_ppm(region=reg)
        ctx.inp.type_unicode("Việt")
        time.sleep(0.12)
        img_after = ctx.vis.capture_ppm(region=reg)
        ctx.require(
            ctx.vis.diff_stats(img_before, img_after, threshold=12)["changed_count"] > 5,
            "typing Unicode via wtype produced no visual change in launcher",
        )
        ctx.inp.key("ret")

    rc4, out4, _, _ = _run_dmenu_with_input(ctx, items, type_wtype, step_name="E06.wtype")
    ctx.require(rc4 == 0 and out4 == f"Tiếng Việt {n}\n".encode("utf-8"), f"Unicode filter selected {out4!r}")

    # 3. fcitx5 text-input-v3 preedit + commit with bamboo Telex ("vieetj" -> "việt")
    fcitx_cfg_dir = Path.home() / ".config" / "fcitx5"
    fcitx_profile = fcitx_cfg_dir / "profile"
    fcitx_config = fcitx_cfg_dir / "config"
    started_fcitx = False
    fcitx_proc: subprocess.Popen | None = None
    try:
        if subprocess.run(["pgrep", "-x", "fcitx5"], capture_output=True).returncode != 0:
            fcitx_cfg_dir.mkdir(parents=True, exist_ok=True)
            if not fcitx_profile.exists():
                fcitx_profile.write_text(
                    "[Groups/0]\nName=Default\nDefault Layout=us\nDefaultIM=bamboo\n\n"
                    "[Groups/0/Items/0]\nName=keyboard-us\nLayout=\n\n"
                    "[Groups/0/Items/1]\nName=bamboo\nLayout=\n\n"
                    "[GroupOrder]\n0=Default\n",
                    encoding="utf-8",
                )
            if not fcitx_config.exists():
                fcitx_config.write_text(
                    "[Behavior]\nActiveByDefault=False\nShareInputState=All\n",
                    encoding="utf-8",
                )
            env = dict(os.environ)
            env["XMODIFIERS"] = "@im=fcitx"
            fcitx_proc = subprocess.Popen(["fcitx5"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            started_fcitx = True
            deadline = time.monotonic() + 4.0
            while time.monotonic() < deadline:
                if subprocess.run(["fcitx5-remote"], capture_output=True).returncode == 0:
                    break
                time.sleep(0.1)
            time.sleep(0.5)

        ime_items = f"Khác\nTiếng Việt {n}\n".encode("utf-8")

        def type_telex(_l):
            subprocess.run(["fcitx5-remote", "-s", "bamboo"], capture_output=True, timeout=2)
            subprocess.run(["fcitx5-remote", "-o"], capture_output=True, timeout=2)
            time.sleep(0.15)
            st_check = subprocess.run(["fcitx5-remote"], capture_output=True, text=True, timeout=2).stdout.strip()
            if st_check != "2":
                ctx.inp.key("ctrl_l", "spc")
                time.sleep(0.15)
            ctx.inp.type_ascii("vieetj", delay=0.06)
            time.sleep(0.2)
            ctx.inp.key("spc")
            time.sleep(0.2)
            ctx.inp.key("ret")
            if ctx.proc.wait_layer("kaze-launcher", present=False, timeout=0.6) is False:
                ctx.inp.key("ret")

        rc5, out5, _, _ = _run_dmenu_with_input(ctx, ime_items, type_telex, step_name="E06.fcitx5")
        ctx.require(
            rc5 == 0 and out5 == f"Tiếng Việt {n}\n".encode("utf-8"),
            f"fcitx5 text-input-v3 Vietnamese composition failed (rc={rc5}, out={out5!r})",
        )
    finally:
        subprocess.run(["fcitx5-remote", "-c"], capture_output=True, timeout=2)
        if started_fcitx and fcitx_proc is not None:
            fcitx_proc.terminate()
            try:
                fcitx_proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                fcitx_proc.kill()


TESTS = {
    "E01": test_e01_dmenu_select_and_cancel,
    "E02": test_e02_dmenu_edge_inputs,
    "E03": test_e03_concurrent_dmenu_and_helpers,
    "E04": test_e04_desktop_inotify_and_exec_fields,
    "E05": test_e05_process_detachment,
    "E06": test_e06_keyboard_nav_unicode_and_ime,
}
