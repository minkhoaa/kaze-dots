#!/usr/bin/env python3
"""Single VM sample for kaze-dots (Noctalia); never starts a portal or sends a toast."""

import argparse
from collections import Counter, defaultdict
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import time

CORE = {
    "kaze-noctalia.service": "noctalia",
    "foot-server.service": "foot",
}
ON_DEMAND = {
    "kaze-record.service": "wf-recorder",
}
SHELL_UNITS = CORE | ON_DEMAND
PORTALS = {
    "xdg-desktop-portal.service", "xdg-desktop-portal-gtk.service",
    "xdg-desktop-portal-hyprland.service", "xdg-document-portal.service",
    "xdg-permission-store.service",
}
PORTAL_COMMS = {"xdg-desktop-por", "xdg-document-po", "xdg-permission-"}
SESSION = PORTALS | {
    "dconf.service", "kaze-fcitx5.service", "at-spi-dbus-bus.service", "gvfs-daemon.service",
}
SESSION_COMMS = PORTAL_COMMS | {"fcitx5", "at-spi-bus-laun", "at-spi2-registr", "gvfsd", "gvfsd-fuse"}
UNIT_STARTING = "7d4958e842da4a758f6c1cdc7b36dcc5"  # systemd SD_MESSAGE_UNIT_STARTING
OUTSIDE = {
    "Hyprland", "start-hyprland", "Xwayland", "pipewire", "pipewire-pulse", "wireplumber",
    "systemd", "(sd-pam)", "dbus-broker", "dbus-broker-lau", "sshd-session", "sshd-auth",
}
BUDGET_GROUPS = {"shell", "session"}
CLK = os.sysconf("SC_CLK_TCK")


def owned_processes():
    core_seen = Counter()
    procs = {}
    for proc in Path("/proc").iterdir():
        if not proc.name.isdigit():
            continue
        pid = int(proc.name)
        try:
            status = (proc / "status").read_text(errors="replace").splitlines()
            uid = next(int(line.split()[1]) for line in status if line.startswith("Uid:"))
            if uid != os.getuid():
                continue
            comm = next(line.partition("\t")[2] for line in status if line.startswith("Name:"))
        except (OSError, StopIteration):
            continue
        try:
            cgroup = (proc / "cgroup").read_text().splitlines()[0].split(":", 2)[-1]
        except (OSError, IndexError):
            cgroup = ""
        scopes = [item for item in reversed(cgroup.split("/")) if item.endswith((".service", ".scope"))]
        unit = next((item for item in scopes if item in SHELL_UNITS or item in SESSION), scopes[0] if scopes else "-")
        if comm in SHELL_UNITS.values():
            core_seen[comm] += 1
        if unit in SHELL_UNITS or comm in SHELL_UNITS.values():
            group = "shell"
        elif unit in SESSION or comm in SESSION_COMMS:
            group = "session"
        elif comm in OUTSIDE or pid == os.getpid():
            group = "outside"
        else:
            group = "unclassified"
        procs[pid] = (comm, unit, group)
    return procs, core_seen


def counters(pid):
    proc = Path("/proc") / str(pid)
    fields = (proc / "stat").read_text().rsplit(")", 1)[1].split()
    start_time = int(fields[19])
    ticks = int(fields[11]) + int(fields[12])
    threads = {}
    for task in (proc / "task").iterdir():
        threads[task.name] = sum(
            int(line.split()[1])
            for line in (task / "status").read_text().splitlines()
            if line.startswith(("voluntary_ctxt_switches:", "nonvoluntary_ctxt_switches:"))
        )
    return start_time, ticks, threads


def pss_kib(pid, guest_sudo_pss=False):
    path = Path("/proc") / str(pid) / "smaps_rollup"
    try:
        contents = path.read_text()
    except PermissionError:
        if not guest_sudo_pss:
            raise
        contents = subprocess.run(["sudo", "-n", "/usr/bin/cat", str(path)], check=True,
                                  capture_output=True, text=True, timeout=2).stdout
    return next(int(line.split()[1]) for line in contents.splitlines() if line.startswith("Pss:"))


def snapshot_counters(procs):
    result = {}
    for pid in procs:
        try:
            result[pid] = counters(pid)
        except (OSError, ValueError, IndexError):
            pass
    return result


def probe(seconds, guest_sudo_pss=False, phase="T0"):
    first, _ = owned_processes()
    start = time.monotonic()
    before = snapshot_counters(first)
    time.sleep(seconds)
    stop = time.monotonic()
    last, counts = owned_processes()
    after = snapshot_counters(last)
    err = []

    def note(group, message, *, counters_only=False):
        if group in BUDGET_GROUPS and not (phase != "T0" and group == "session" and counters_only):
            err.append(message)
        else:
            print(f"WARN ({group}): {message}", file=sys.stderr)

    for group in ("shell", "session", "outside", "unclassified"):
        begun = {pid: desc[:2] for pid, desc in last.items() if desc[2] == group and first.get(pid) != desc}
        exited = {pid: desc[:2] for pid, desc in first.items() if desc[2] == group and last.get(pid) != desc}
        if begun or exited:
            note(group, f"PID set changed: started={begun}, exited={exited}; CPU/CS totals cover stable PIDs only")
    if counts != Counter(CORE.values()):
        err.append(f"unexpected daemon counts: {dict(counts)}")
    for unit, comm in CORE.items():
        if len([pid for pid, desc in last.items() if desc[:2] == (comm, unit)]) != 1:
            err.append(f"expected exactly one {comm} in {unit}")
    print(f"dt={stop - start:.2f}s")
    totals = defaultdict(lambda: [0.0, 0.0, 0.0])
    noctalia_pss = 0.0
    for pid, (comm, unit, group) in sorted(last.items()):
        prefix = f"{group:12s} {pid:5d} {comm:<16s} {unit:<36s}"
        try:
            pss = pss_kib(pid, guest_sudo_pss) / 1024.0
        except (OSError, StopIteration, ValueError, subprocess.SubprocessError):
            note(group, f"PSS unavailable for {comm} [{pid}]; missing from subtotal")
            prefix += "  PSS n/a  "
        else:
            totals[group][0] += pss
            if comm == "noctalia":
                noctalia_pss += pss
            prefix += f" {pss:6.2f} MiB"
        if pid not in before or pid not in after:
            note(group, f"CPU/CS unavailable for {comm} [{pid}]: counters missing or PID changed")
            print(prefix + " CPU/CS unavailable")
            continue
        start1, cpu1, cs1 = after[pid]
        start0, cpu0, cs0 = before[pid]
        if start0 != start1 or cpu1 < cpu0 or cs0.keys() != cs1.keys() or any(cs1[tid] < cs0[tid] for tid in cs0):
            note(group, f"PID/thread identities changed for {comm} [{pid}]; CPU/CS unavailable", counters_only=True)
            print(prefix + " CPU/CS unavailable (changed threads)")
            continue
        cpu = (cpu1 - cpu0) / CLK / (stop - start) * 100
        ctx = sum(cs1[tid] - cs0[tid] for tid in cs0) / (stop - start)
        totals[group][1] += cpu
        totals[group][2] += ctx
        print(f"{prefix} {cpu:5.2f}% {ctx:5.2f} CS/s ({len(cs1)} threads)")
    for group in ("shell", "session", "outside", "unclassified"):
        pss, cpu, ctx = totals[group]
        print(f"{group:12s} total: {pss:.2f} MiB, {cpu:.2f}% CPU, {ctx:.2f} CS/s")
    portals = {unit if unit in PORTALS else comm for comm, unit, _ in (*first.values(), *last.values())
               if unit in PORTALS or comm in PORTAL_COMMS}
    combined = totals["shell"][0] + totals["session"][0]
    print(f"Summary: shell+session={combined:.2f} MiB, noctalia={noctalia_pss:.2f} MiB, live portals={','.join(sorted(portals)) or 'none'}")
    return totals, noctalia_pss, portals, stop - start, err


def units_started_this_boot(units):
    log = subprocess.run([
        "journalctl", "--user", "--boot", "--no-pager", "--quiet", "--output=json", "--output-fields=USER_UNIT",
        f"MESSAGE_ID={UNIT_STARTING}", *(f"USER_UNIT={unit}" for unit in sorted(units)),
    ], check=True, capture_output=True, text=True, timeout=5)
    return {json.loads(line)["USER_UNIT"] for line in log.stdout.splitlines()}


def t0_issues(totals, portals, started):
    errors = []
    shell, cpu, ctx = totals["shell"]
    combined = shell + totals["session"][0]
    for name, value, limit in (("shell PSS", shell, 100.0), ("shell+session PSS", combined, 105.0),
                               ("idle CPU", cpu, 0.20), ("context switches/s", ctx, 8.0)):
        if value > limit:
            errors.append(f"{name}: {value:.2f} > {limit:.2f}")
    if "kaze-noctalia.service" not in started:
        errors.append("T0 journal check unavailable: no startup record for kaze-noctalia.service")
    early = portals | (started & PORTALS)
    if early:
        errors.append(f"portal activation before first client probe: {', '.join(sorted(early))}")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=float, default=60)
    parser.add_argument("--phase", choices=("T0", "T1_retained", "T2"), default="T0")
    parser.add_argument("--guest-sudo-pss", action="store_true")
    args = parser.parse_args()
    if not math.isfinite(args.seconds) or args.seconds <= 0:
        parser.error("--seconds must be finite and positive")
    print(f"Phase: {args.phase}", flush=True)
    packages = subprocess.run(["pacman", "-Q", "hyprland", "noctalia", "foot",
                               "xdg-desktop-portal", "xdg-desktop-portal-gtk",
                               "xdg-desktop-portal-hyprland", "dconf"],
                              check=True, stdout=subprocess.PIPE, text=True).stdout
    print(packages, end="", flush=True)
    settle = 45 if args.phase == "T0" else 10
    print(f"settling for {settle}s", flush=True)
    time.sleep(settle)
    totals, _, portals, _, errors = probe(args.seconds, args.guest_sudo_pss, args.phase)
    if args.phase == "T0":
        started = units_started_this_boot(PORTALS | {"kaze-noctalia.service"})
        errors.extend(t0_issues(totals, portals, started))
    if errors:
        for e in errors:
            print(f"FAIL: {e}", file=sys.stderr)
        sys.exit(1)
    print(f"PASS: {args.phase}")


if __name__ == "__main__":
    main()
