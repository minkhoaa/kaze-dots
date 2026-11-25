#!/usr/bin/env python3
"""Single VM sample; never starts a portal, sets a theme, or sends a toast."""

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
    "kaze-waybar.service": "waybar",
    "kaze-wallpaper.service": "swaybg",
    "foot-server.service": "foot",
    "kaze-hypridle.service": "hypridle",
    "kaze-clipboard@text.service": "wl-paste",
    "kaze-clipboard@image.service": "wl-paste",
}
NOTIFICATIONS = {name: (f"{name}.service", name) for name in ("fnott", "mako")}
ON_DEMAND = {
    "kaze-record.service": "wf-recorder", "kaze-night.service": "hyprsunset", "kaze-inhibit.service": "systemd-inhibit",
}
SHELL_UNITS = CORE | dict(NOTIFICATIONS.values()) | ON_DEMAND
PORTALS = {
    "xdg-desktop-portal.service", "xdg-desktop-portal-gtk.service",
    "xdg-desktop-portal-hyprland.service", "xdg-document-portal.service",
    "xdg-permission-store.service",
}
PORTAL_COMMS = {"xdg-desktop-por", "xdg-document-po", "xdg-permission-"}
SESSION = PORTALS | {
    "dconf.service", "kaze-polkit.service", "kaze-fcitx5.service", "at-spi-dbus-bus.service", "gvfs-daemon.service",
}
SESSION_COMMS = PORTAL_COMMS | {"fcitx5", "polkit-mate-aut", "at-spi-bus-laun", "at-spi2-registr", "gvfsd", "gvfsd-fuse"}
UNIT_STARTING = "7d4958e842da4a758f6c1cdc7b36dcc5"  # systemd SD_MESSAGE_UNIT_STARTING
OUTSIDE = {
    "Hyprland", "Xwayland", "pipewire", "pipewire-pulse", "wireplumber",
    "systemd", "(sd-pam)", "dbus-broker", "dbus-broker-lau", "sshd-session", "sshd-auth",
}
KNOWN_PORTAL_PAIR = {"waybar": "0.16.0-3", "gtk3": "1:3.24.52-2"}
EXPECTED_UPSTREAM_FAIL = 10  # consumed by vm-verify.sh, not a strict T0 pass
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


def decode_workers(procs):
    return {pid: (comm, unit) for pid, (comm, unit, _) in procs.items() if comm == "bwrap" or comm.startswith("glycin")}


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
        # The isolated VM can read nondumpable same-UID workers such as
        # fusermount3. Only this read runs with privilege, after counter snapshots.
        contents = subprocess.run(["sudo", "-n", "/usr/bin/cat", str(path)], check=True,
                                  capture_output=True, text=True, timeout=2).stdout
    return next(int(line.split()[1]) for line in contents.splitlines() if line.startswith("Pss:"))


def snapshot_counters(procs):
    result = {}
    for pid in procs:
        try:
            result[pid] = counters(pid)
        except (OSError, ValueError, IndexError):
            pass  # Report the missing counters alongside the affected PID.
    return result


def probe(seconds, guest_sudo_pss=False, notifications="fnott", phase="T0"):
    core = CORE | dict([NOTIFICATIONS[notifications]])
    first, _ = owned_processes()
    start = time.monotonic()
    before = snapshot_counters(first)
    time.sleep(seconds)
    stop = time.monotonic()
    last, counts = owned_processes()
    after = snapshot_counters(last)
    err = []
    if phase == "T1_retained":
        for label, processes in (("start", first), ("end", last)):
            left = decode_workers(processes)
            print(f"T1_retained decode workers ({label}): {len(left)} {left}")
            if left:
                err.append(f"decode workers not reaped at {label} of T1_retained: {left}")

    def note(group, message, *, counters_only=False):
        # Warm portal threads can retire after a client closes. Their endpoint
        # PSS is still valid, but do not claim a complete CPU/CS total for them.
        if group in BUDGET_GROUPS and not (phase != "T0" and group == "session" and counters_only):
            err.append(message)
        else:
            print(f"WARN ({group}): {message}", file=sys.stderr)

    for group in ("shell", "session", "outside", "unclassified"):
        begun = {pid: desc[:2] for pid, desc in last.items() if desc[2] == group and first.get(pid) != desc}
        exited = {pid: desc[:2] for pid, desc in first.items() if desc[2] == group and last.get(pid) != desc}
        if begun or exited:
            note(group, f"PID set changed: started={begun}, exited={exited}; CPU/CS totals cover stable PIDs only")
    if counts != Counter(core.values()):
        err.append(f"unexpected daemon counts: {dict(counts)}")
    for unit, comm in core.items():
        if len([pid for pid, desc in last.items() if desc[:2] == (comm, unit)]) != 1:
            err.append(f"expected exactly one {comm} in {unit}")
    print(f"dt={stop - start:.2f}s")
    totals = defaultdict(lambda: [0.0, 0.0, 0.0])
    bar = portal_pss = 0.0
    for pid, (comm, unit, group) in sorted(last.items()):
        prefix = f"{group:12s} {pid:5d} {comm:<16s} {unit:<36s}"
        try:
            pss = pss_kib(pid, guest_sudo_pss) / 1024.0
        except (OSError, StopIteration, ValueError, subprocess.SubprocessError):
            note(group, f"PSS unavailable for {comm} [{pid}]; missing from subtotal")
            prefix += "  PSS n/a  "
        else:
            totals[group][0] += pss
            if comm == "waybar":
                bar += pss
            if group == "session" and unit in PORTALS:
                portal_pss += pss
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
    if any(desc[2] == "unclassified" for desc in last.values()):
        print("WARN: inspect unclassified same-UID PIDs before attributing all desktop costs", file=sys.stderr)
    portals = {unit if unit in PORTALS else comm for comm, unit, _ in (*first.values(), *last.values())
               if unit in PORTALS or comm in PORTAL_COMMS}
    combined = totals["shell"][0] + totals["session"][0]
    print(f"Summary: shell+session={combined:.2f} MiB, waybar={bar:.2f} MiB, live portals={','.join(sorted(portals)) or 'none'}")
    return totals, bar, portals, portal_pss, stop - start, err


def units_started_this_boot(units):
    # Unlike two /proc snapshots, the user journal catches activations that
    # ended during startup, settling or sampling. No D-Bus client calls here.
    log = subprocess.run([
        "journalctl", "--user", "--boot", "--no-pager", "--quiet", "--output=json", "--output-fields=USER_UNIT",
        f"MESSAGE_ID={UNIT_STARTING}", *(f"USER_UNIT={unit}" for unit in sorted(units)),
    ], check=True, capture_output=True, text=True, timeout=5)
    return {json.loads(line)["USER_UNIT"] for line in log.stdout.splitlines()}


def t0_issues(totals, waybar, portals, portal_pss, started, versions, allow_known):
    errors, expected = [], []
    shell, cpu, ctx = totals["shell"]
    combined = shell + totals["session"][0]
    for name, value, limit in (("shell PSS", shell, 55), ("Waybar PSS", waybar, 40),
                               ("idle CPU", cpu, 0.2), ("context switches/s", ctx, 5)):
        if value > limit:
            errors.append(f"{name}: {value:.2f} > {limit:.2f}")
    bar_unit = "kaze-waybar.service"
    if bar_unit not in started:
        errors.append(f"T0 journal check unavailable: no startup record for {bar_unit}")
    journal_portals = started & PORTALS
    known = (allow_known and bar_unit in started and portals == journal_portals == PORTALS
             and all(versions.get(pkg) == version for pkg, version in KNOWN_PORTAL_PAIR.items()))
    if early := portals | journal_portals:
        message = f"portal activation before first client probe: {', '.join(sorted(early))}"
        (expected if known else errors).append(message)
    if combined > 60:
        message = f"shell + active session PSS: {combined:.2f} > 60.00 MiB"
        if known and combined - portal_pss <= 60:
            expected.append(f"{message} ({portal_pss:.2f} MiB in the known portal units)")
        else:
            errors.append(message)
    return errors, expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=float, default=120)
    parser.add_argument("--phase", choices=("T0", "T1_retained", "T2"), default="T0")
    parser.add_argument("--notifications", choices=NOTIFICATIONS, default="fnott")
    parser.add_argument("--allow-known-t0-portal", action="store_true", help="report the known GTK3-only T0 failure separately")
    parser.add_argument("--guest-sudo-pss", action="store_true", help="use VM sudo only to read nondumpable same-UID PSS")
    args = parser.parse_args()
    if not math.isfinite(args.seconds) or args.seconds <= 0:
        parser.error("--seconds must be finite and positive")
    print(f"Phase: {args.phase}", flush=True)
    packages = subprocess.run(["pacman", "-Q", "hyprland", "waybar", "swaybg", "foot", args.notifications, "hypridle", "wl-clipboard",
                               "cliphist", "xdg-desktop-portal", "xdg-desktop-portal-gtk", "xdg-desktop-portal-hyprland", "gtk3",
                               "glib2", "gdk-pixbuf2", "dconf"], check=True, stdout=subprocess.PIPE, text=True).stdout
    print(packages, end="", flush=True)
    versions = dict(line.split(maxsplit=1) for line in packages.splitlines())
    # The cold login starts short-lived loader processes and GLib pool
    # threads. Keep them out of the steady window, not out of the PID totals.
    settle = 45 if args.phase == "T0" else 10
    print(f"settling for {settle}s", flush=True)
    time.sleep(settle)
    totals, waybar, portals, portal_pss, elapsed, errors = probe(args.seconds, args.guest_sudo_pss, args.notifications, args.phase)
    expected = []
    if args.phase == "T0":
        started = units_started_this_boot(PORTALS | {"kaze-waybar.service"})
        print(f"Portal unit starts this boot: {', '.join(sorted(started & PORTALS)) or 'none'}")
        bad, expected = t0_issues(totals, waybar, portals, portal_pss, started, versions, args.allow_known_t0_portal)
        errors.extend(bad)
    print("SAMPLE " + json.dumps({
        "phase": args.phase, "boot": Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
        "notification_daemon": args.notifications, "seconds": elapsed, "versions": versions,
        "totals_pss_mib_cpu_pct_cs_per_s": dict(totals), "waybar_mib": waybar,
        "portals": sorted(portals), "portal_mib": portal_pss, "errors": errors, "expected": expected,
    }, sort_keys=True))
    for err in expected:
        print(f"EXPECTED_UPSTREAM_FAIL: {err}", file=sys.stderr)
    for err in errors:
        print(f"FAIL: {err}", file=sys.stderr)
    if errors:
        return 1
    return EXPECTED_UPSTREAM_FAIL if expected else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, StopIteration, KeyError, ValueError, subprocess.SubprocessError) as exc:
        sys.exit(f"Invalid sample: {exc}")
