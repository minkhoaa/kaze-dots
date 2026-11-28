#!/usr/bin/env python3
"""Independent OS/compositor/D-Bus ground-truth oracles for kaze-shell blind tests."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import time
from typing import Any

CLK_TCK = os.sysconf("SC_CLK_TCK")
UNIT_STARTING_MSG_ID = "7d4958e842da4a758f6c1cdc7b36dcc5"
PORTAL_UNITS = {
    "xdg-desktop-portal.service",
    "xdg-desktop-portal-gtk.service",
    "xdg-desktop-portal-hyprland.service",
    "xdg-document-portal.service",
    "xdg-permission-store.service",
}
PORTAL_COMMS = {"xdg-desktop-por", "xdg-document-po", "xdg-permission-"}


def _read_proc_text(path: Path) -> str:
    try:
        return path.read_text(errors="replace")
    except PermissionError:
        res = subprocess.run(
            ["sudo", "-n", "/usr/bin/cat", str(path)],
            check=True,
            capture_output=True,
            text=True,
            timeout=2,
        )
        return res.stdout


def read_pss_kib(pid: int) -> int:
    text = _read_proc_text(Path(f"/proc/{pid}/smaps_rollup"))
    for line in text.splitlines():
        if line.startswith("Pss:"):
            return int(line.split()[1])
    raise ValueError(f"Pss: not found in /proc/{pid}/smaps_rollup")


def read_threads(pid: int) -> int:
    text = Path(f"/proc/{pid}/status").read_text(errors="replace")
    for line in text.splitlines():
        if line.startswith("Threads:"):
            return int(line.split()[1])
    raise ValueError(f"Threads: not found in /proc/{pid}/status")


def read_stat(pid: int) -> tuple[int, int]:
    """Return (start_time_ticks, utime_plus_stime_ticks)."""
    raw = Path(f"/proc/{pid}/stat").read_text(errors="replace")
    rparen = raw.rfind(")")
    if rparen == -1:
        raise ValueError(f"Malformed /proc/{pid}/stat")
    fields = raw[rparen + 2 :].split()
    ticks = int(fields[11]) + int(fields[12])
    start_time = int(fields[19])
    return start_time, ticks


def read_ctx_switches(pid: int) -> int:
    task_dir = Path(f"/proc/{pid}/task")
    total = 0
    for tid_dir in task_dir.iterdir():
        try:
            text = (tid_dir / "status").read_text(errors="replace")
        except (FileNotFoundError, ProcessLookupError):
            continue
        for line in text.splitlines():
            if line.startswith(("voluntary_ctxt_switches:", "nonvoluntary_ctxt_switches:")):
                total += int(line.split()[1])
    return total


def read_fd_counts(pid: int) -> tuple[int, int]:
    """Return (total_fd_count, memfd_count) directly from /proc/<pid>/fd."""
    fd_dir = Path(f"/proc/{pid}/fd")
    total = 0
    memfd = 0
    try:
        entries = list(fd_dir.iterdir())
        for entry in entries:
            total += 1
            try:
                target = os.readlink(entry)
                if "memfd:" in target:
                    memfd += 1
            except OSError:
                pass
        return total, memfd
    except PermissionError:
        res = subprocess.run(
            ["sudo", "-n", "/usr/bin/ls", "-l", str(fd_dir)],
            check=True,
            capture_output=True,
            text=True,
            timeout=2,
        )
        for line in res.stdout.splitlines():
            if " -> " in line:
                total += 1
                if "memfd:" in line.split(" -> ", 1)[1]:
                    memfd += 1
        return total, memfd


def read_comm(pid: int) -> str:
    return Path(f"/proc/{pid}/comm").read_text(errors="replace").strip()


def read_cmdline(pid: int) -> list[str]:
    raw = Path(f"/proc/{pid}/cmdline").read_bytes()
    return [part.decode("utf-8", errors="replace") for part in raw.split(b"\x00") if part]


def pid_alive(pid: int) -> bool:
    return Path(f"/proc/{pid}").exists()


def snapshot(pid: int) -> dict[str, Any]:
    start_time, ticks = read_stat(pid)
    fd_total, memfd = read_fd_counts(pid)
    return {
        "pid": pid,
        "start_time": start_time,
        "pss_kib": read_pss_kib(pid),
        "threads": read_threads(pid),
        "fd_total": fd_total,
        "memfd_count": memfd,
        "cpu_ticks": ticks,
        "ctx_switches": read_ctx_switches(pid),
    }


def measure_idle(pid: int, seconds: float) -> dict[str, Any]:
    threads_before = read_threads(pid)
    start0, ticks0 = read_stat(pid)
    cs0 = read_ctx_switches(pid)
    t0 = time.monotonic()
    time.sleep(seconds)
    dt = max(time.monotonic() - t0, 1e-6)
    alive = pid_alive(pid)
    if not alive:
        return {
            "pid_alive": False,
            "same_start_time": False,
            "cpu_pct": 999.0,
            "cs_per_sec": 999.0,
            "threads_before": threads_before,
            "threads_after": 0,
            "dt": dt,
        }
    start1, ticks1 = read_stat(pid)
    cs1 = read_ctx_switches(pid)
    threads_after = read_threads(pid)
    cpu_pct = ((ticks1 - ticks0) / CLK_TCK) / dt * 100.0
    cs_per_sec = (cs1 - cs0) / dt
    return {
        "pid_alive": True,
        "same_start_time": start0 == start1,
        "cpu_pct": cpu_pct,
        "cs_per_sec": cs_per_sec,
        "threads_before": threads_before,
        "threads_after": threads_after,
        "dt": dt,
    }


def runtime_dir() -> Path:
    r = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    return Path(r)


def session_env() -> dict[str, str]:
    res = subprocess.run(
        ["systemctl", "--user", "show-environment"],
        check=True,
        capture_output=True,
        text=True,
        timeout=5,
    )
    out: dict[str, str] = {}
    for line in res.stdout.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k] = v
    return out


def get_shell_pid() -> int:
    res = subprocess.run(
        ["systemctl", "--user", "show", "-p", "MainPID", "--value", "kaze-shell.service"],
        capture_output=True,
        text=True,
        timeout=5,
    )
    if res.returncode == 0:
        val = res.stdout.strip()
        if val.isdigit() and int(val) > 1:
            return int(val)
    pg = subprocess.run(["pgrep", "-x", "kaze-shell"], capture_output=True, text=True, timeout=5)
    pids = [int(x) for x in pg.stdout.split() if x.isdigit()]
    if len(pids) != 1:
        raise RuntimeError(f"Expected 1 kaze-shell PID, found {pids}")
    return pids[0]


def hypr_json(subcmd: str) -> Any:
    res = subprocess.run(
        ["hyprctl", "-j", *subcmd.split()],
        check=True,
        capture_output=True,
        text=True,
        timeout=5,
    )
    return json.loads(res.stdout)


def list_layers() -> list[dict[str, Any]]:
    data = hypr_json("layers")
    out: list[dict[str, Any]] = []
    for output_name, mon_info in data.items():
        levels = mon_info.get("levels", {}) if isinstance(mon_info, dict) else {}
        for level_str, items in levels.items():
            for item in items:
                out.append(
                    {
                        "output": output_name,
                        "level": int(level_str),
                        "x": int(item.get("x", 0)),
                        "y": int(item.get("y", 0)),
                        "w": int(item.get("w", 0)),
                        "h": int(item.get("h", 0)),
                        "namespace": str(item.get("namespace", "")),
                        "pid": int(item.get("pid", 0)),
                        "address": str(item.get("address", "")),
                    }
                )
    return out


def find_layers(
    namespace: str | None = None,
    prefix: str | None = None,
    output: str | None = None,
) -> list[dict[str, Any]]:
    layers = list_layers()
    res = []
    for layer in layers:
        if namespace is not None and layer["namespace"] != namespace:
            continue
        if prefix is not None and not layer["namespace"].startswith(prefix):
            continue
        if output is not None and layer["output"] != output:
            continue
        res.append(layer)
    return res


def wait_layer(
    namespace: str,
    present: bool = True,
    timeout: float = 4.0,
    interval: float = 0.05,
    output: str | None = None,
    prefix: bool = False,
) -> dict[str, Any] | bool | None:
    deadline = time.monotonic() + timeout
    while time.monotonic() <= deadline:
        matches = (
            find_layers(prefix=namespace, output=output)
            if prefix
            else find_layers(namespace=namespace, output=output)
        )
        if present and matches:
            return matches[0]
        if not present and not matches:
            return True
        time.sleep(interval)
    return None if present else False


def hypr_option(name: str) -> Any:
    return hypr_json(f"getoption {name}")


def bus_owner_pid(name: str) -> int | None:
    res = subprocess.run(
        ["busctl", "--user", "status", name],
        capture_output=True,
        text=True,
        timeout=5,
    )
    if res.returncode != 0:
        return None
    m = re.search(r"PID=(\d+)", res.stdout)
    return int(m.group(1)) if m else None


def active_portals() -> list[str]:
    found: set[str] = set()
    uid = os.getuid()
    for proc in Path("/proc").iterdir():
        if not proc.name.isdigit():
            continue
        try:
            status = (proc / "status").read_text(errors="replace").splitlines()
            puid = next(int(l.split()[1]) for l in status if l.startswith("Uid:"))
            if puid != uid:
                continue
            comm = next(l.partition("\t")[2] for l in status if l.startswith("Name:"))
            if comm in PORTAL_COMMS:
                found.add(comm)
            cg = (proc / "cgroup").read_text(errors="replace")
            for u in PORTAL_UNITS:
                if u in cg:
                    found.add(u)
        except (OSError, StopIteration, ValueError):
            continue
    j = subprocess.run(
        [
            "journalctl",
            "--user",
            "--boot",
            "--no-pager",
            "--quiet",
            "--output=json",
            "--output-fields=USER_UNIT",
            f"MESSAGE_ID={UNIT_STARTING_MSG_ID}",
            *(f"USER_UNIT={u}" for u in sorted(PORTAL_UNITS)),
        ],
        capture_output=True,
        text=True,
        timeout=5,
    )
    if j.returncode == 0:
        for line in j.stdout.splitlines():
            if not line.strip():
                continue
            try:
                u = json.loads(line).get("USER_UNIT")
                if u in PORTAL_UNITS:
                    found.add(u)
            except json.JSONDecodeError:
                pass
    return sorted(found)


def kaze_msg(*args: str, timeout: float = 5.0) -> tuple[int, str, str]:
    res = subprocess.run(
        ["kaze-shell", "msg", *args],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return res.returncode, res.stdout.strip(), res.stderr.strip()


def switch_workspace(ws: int | str) -> None:
    expr = f'hl.dispatch(hl.dsp.focus({{ workspace = "{ws}" }}))'
    subprocess.run(["hyprctl", "eval", expr], check=True, capture_output=True, text=True, timeout=5)


def move_window_to_workspace(address: str, ws: int | str, silent: bool = True) -> None:
    sil = "true" if silent else "false"
    expr = (
        f'for _, w in ipairs(hl.get_windows()) do '
        f'if w.address == "{address}" then '
        f'hl.dispatch(hl.dsp.window.move({{ workspace = "{ws}", window = w, silent = {sil} }})) '
        f'end end'
    )
    subprocess.run(["hyprctl", "eval", expr], check=True, capture_output=True, text=True, timeout=5)


def close_window_by_address(address: str) -> None:
    expr = (
        f'for _, w in ipairs(hl.get_windows()) do '
        f'if w.address == "{address}" then '
        f'hl.dispatch(hl.dsp.window.close({{ window = w }})) '
        f'end end'
    )
    subprocess.run(["hyprctl", "eval", expr], capture_output=True, text=True, timeout=5)
