#!/usr/bin/env python3
"""Guest-only matched notification workload and Mako correctness gate."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import runpy
import struct
import subprocess as sp
import tempfile
import time
import zlib


IDLE = runpy.run_path(Path(__file__).with_name("vm-idle.py"))
workers = IDLE["decode_workers"]
APP = "org.freedesktop.Notifications"


def capture(*cmd):
    return sp.check_output(cmd, text=True, timeout=8)


def wait_for(check, label, seconds=6):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if check():
            return
        time.sleep(.04)
    raise RuntimeError(label)


def owner(daemon):
    procs, counts = IDLE["owned_processes"]()
    assert counts[daemon] == 1 and not counts["fnott" if daemon == "mako" else "mako"], counts
    pid = next(pid for pid, (comm, unit, _) in procs.items() if comm == daemon and unit == daemon + ".service")
    assert capture("busctl", "--user", "call", "org.freedesktop.DBus", "/org/freedesktop/DBus",
                   "org.freedesktop.DBus", "GetConnectionUnixProcessID", "s", APP).strip() == f"u {pid}"
    print(f"Exclusive {APP} owner: {daemon} pid={pid}", flush=True)
    return pid


def layer(pid):
    outputs = json.loads(capture("hyprctl", "-j", "layers"))
    return any(surface["pid"] == pid and surface["w"] > 0 and surface["h"] > 0 and surface["alpha"] > .1
               for output in outputs.values() for level in output["levels"].values() for surface in level)


def assert_reaped():
    left = workers(IDLE["owned_processes"]()[0])
    assert not left, f"leftover same-UID decode workers: {left}"


def write_icon(path):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    # An opaque 64x64 four-quadrant PNG; easily distinguishable in a toast at 32px.
    image = b"".join(b"\0" + (b"\xf5\x39\x7a" * 32 + b"\x2a\xef\x91" * 32 if y < 32 else
                              b"\x54\x68\xea" * 32 + b"\xff\xdb\x53" * 32) for y in range(64))
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">2I5B", 64, 64, 8, 2, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(image)) + chunk(b"IEND", b""))
    print("Icon SHA256:", hashlib.sha256(path.read_bytes()).hexdigest())


def payload(daemon, artifacts):
    pid = owner(daemon)
    assert not layer(pid), "toast present before T1"
    assert_reaped()
    unit = daemon + ".service"
    with tempfile.TemporaryDirectory() as temp:
        icon = Path(temp, "four-quadrants.png")
        write_icon(icon)
        for label, options in (("text", []), ("icon", ["-i", str(icon)])):
            before = IDLE["pss_kib"](pid) / 1024
            with sp.Popen(["notify-send", "-a", "Kaze QA", "-t", "2500", *options, "Kaze notification",
                           "The quick brown fox jumps over the lazy dog."]) as client:
                started = time.monotonic()
                peak_mib = peak_workers = peak_worker_mib = count = 0
                seen, unavailable = {}, set()
                while time.monotonic() - started < .75:
                    procs, _ = IDLE["owned_processes"]()
                    transient = workers(procs)
                    seen.update(transient)
                    peak_workers = max(peak_workers, len(transient))
                    pss = worker_pss = 0
                    for p, (_, u, _) in procs.items():
                        if u != unit and p not in transient:
                            continue
                        try:
                            kib = IDLE["pss_kib"](p)
                        except (OSError, StopIteration):
                            if p == pid:
                                raise
                            # A short-lived worker may exit before rollup can be read.
                            if p in transient:
                                unavailable.add(p)
                            continue
                        pss += kib / 1024
                        if p in transient:
                            worker_pss += kib / 1024
                    peak_mib = max(peak_mib, pss)
                    peak_worker_mib = max(peak_worker_mib, worker_pss)
                    count += 1
                    time.sleep(.004)
                assert client.wait(timeout=3) == 0
            wait_for(lambda: layer(pid), f"{daemon} {label} toast never mapped", 1)
            sp.run(["grim", str(artifacts / f"toast-{label}.png")], check=True, timeout=3)
            wait_for(lambda: not layer(pid), f"{daemon} {label} toast did not expire")
            left = workers(IDLE["owned_processes"]()[0])
            print("PEAK " + json.dumps({"daemon": daemon, "toast": label, "before_daemon_mib": before,
                  "peak_unit_plus_workers_mib": peak_mib, "peak_workers_mib": peak_worker_mib,
                  "peak_worker_count": peak_workers, "observed_workers": seen, "pss_missed_on_some_scans": sorted(unavailable),
                  "scans": count, "elapsed_s": .75, "workers_at_dismissal": left}), flush=True)


def mako_correctness(artifacts):
    pid = owner("mako")
    mode = "do-not-disturb"

    def modes():
        return set(capture("makoctl", "mode").splitlines())

    def run(*args):
        return capture("makoctl", *args)

    def toast(*args):
        return capture("notify-send", *args)

    # Check DND off and on with an unrelated mode, detecting any lost mode.
    run("mode", "-a", "qa-existing-mode")
    for enabled in (False, True):
        run("mode", "-a" if enabled else "-r", mode)
        before = modes()
        assert (mode in before) == enabled and "qa-existing-mode" in before
        run("reload")
        raw = modes()
        print(f"DND {'on' if enabled else 'off'}: modes before={sorted(before)} immediately after reload={sorted(raw)}")
        if mode in before and mode not in raw:
            run("mode", "-a", mode)  # Never toggle blindly or replace all modes.
        assert modes() == before, "reload changed an unrelated mode or enabled DND"

    assert mode in modes() and not layer(pid)
    toast("-a", "Kaze QA", "-t", "2500", "QA normal hidden")
    assert "QA normal hidden" in run("list"), "daemon did not accept the test notification"
    sp.run(["grim", str(artifacts / "mako-dnd-hidden.png")], check=True, timeout=3)
    assert not layer(pid), "normal notification visible in DND"
    wait_for(lambda: "QA normal hidden" in run("history"), "normal notification did not expire")

    def read_volume():
        result = sp.run(["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"], text=True, capture_output=True, timeout=5)
        return result.stdout if result.returncode == 0 and result.stdout.startswith("Volume:") else None

    volume = read_volume()
    sink = None
    if volume is None:
        # The headless guest may have no audio output. Add a disposable real
        # PipeWire/Pulse sink after telemetry, so this exercises kaze-osd itself.
        sink = capture("pactl", "load-module", "module-null-sink", "sink_name=kaze_qa").strip()
        capture("pactl", "set-default-sink", "kaze_qa")
        wait_for(read_volume, "test PipeWire sink did not become ready")
        volume = read_volume()
    try:
        sp.run(["kaze-osd", "vol-up"], check=True, timeout=5)
        wait_for(lambda: layer(pid), "actual volume OSD hidden by DND", 1)
        sp.run(["grim", str(artifacts / "mako-dnd-osd.png")], check=True, timeout=3)
        for i in range(12):
            toast("-a", "kaze-osd", "-u", "low", "-t", "1400", "-h", "int:value:30",
                  "-h", "string:x-canonical-private-synchronous:kaze-osd", f"QA OSD {i}")
        listing = run("list")
        assert listing.count("QA OSD") == 1 and "QA OSD 11" in listing, listing
    finally:
        if sink:
            capture("pactl", "unload-module", sink)
        else:
            v = volume.split()
            sp.run(["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", v[1]], check=True, timeout=3)
            sp.run(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "1" if "[MUTED]" in v else "0"], check=True, timeout=3)
    wait_for(lambda: not layer(pid), "OSD did not expire")
    toast("-a", "kaze-osd", "-t", "10000", "QA OSD dismissed")
    run("dismiss", "--all")
    assert "kaze-osd" not in run("history"), "expired or dismissed OSD leaked into history"
    run("mode", "-r", mode)
    assert mode not in modes()
    run("restore")
    restored = run("list")
    assert "QA normal hidden" in restored and "kaze-osd" not in restored, restored
    wait_for(lambda: layer(pid), "restored normal notification never visible", 1)
    run("dismiss", "--all")
    print("PASS: Mako DND hide + visible replacing OSD, no OSD history/restore, reload with DND on/off")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("action", choices=("owner", "payload", "reaped", "mako-correctness"))
    p.add_argument("daemon", choices=("fnott", "mako"))
    p.add_argument("--artifacts", type=Path, default=Path(os.environ["XDG_RUNTIME_DIR"], "kaze-qa"))
    args = p.parse_args()
    if args.action == "owner":
        owner(args.daemon)
    elif args.action == "reaped":
        assert_reaped()
    else:
        args.artifacts.mkdir(mode=0o700, exist_ok=True)
        if args.action == "payload":
            payload(args.daemon, args.artifacts)
        else:
            assert args.daemon == "mako"
            mako_correctness(args.artifacts)


if __name__ == "__main__":
    main()
