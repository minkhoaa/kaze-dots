#!/usr/bin/env python3
"""Inject real keyboard/tablet events into the isolated 1920x1080 QEMU guest."""
import argparse
import json
import socket
import time


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("socket")
    actions = p.add_subparsers(dest="action", required=True)
    key = actions.add_parser("key")
    key.add_argument("keys", nargs="+")
    key.add_argument("--seconds", type=float, default=.08)
    for name in ("move", "click", "drag"):
        pointer = actions.add_parser(name)
        pointer.add_argument("x", type=int)
        pointer.add_argument("y", type=int)
        if name == "drag":
            pointer.add_argument("end_x", type=int)
            pointer.add_argument("end_y", type=int)
    args = p.parse_args()

    with socket.socket(socket.AF_UNIX) as conn:
        conn.settimeout(5)
        conn.connect(args.socket)
        with conn.makefile("rwb") as wire:
            assert "QMP" in json.loads(wire.readline()), "not a QEMU monitor"

            def invoke(name, **arguments):
                wire.write(json.dumps({"execute": name, "arguments": arguments}).encode() + b"\n")
                wire.flush()
                while True:
                    reply = json.loads(wire.readline())
                    if "error" in reply:
                        raise RuntimeError(reply["error"])
                    if "return" in reply:
                        return

            def send(*events):
                invoke("input-send-event", events=list(events))

            def move(x, y):
                assert 0 <= x < 1920 and 0 <= y < 1080, "coordinates outside the test output"
                send(*({"type": "abs", "data": {"axis": axis, "value": round(32767 * pos / limit)}}
                       for axis, pos, limit in (("x", x, 1919), ("y", y, 1079))))

            invoke("qmp_capabilities")
            if args.action == "key":
                for down, keys in ((True, args.keys), (False, reversed(args.keys))):
                    send(*({"type": "key", "data": {"down": down, "key": {"type": "qcode", "data": key}}}
                           for key in keys))
                    if down:
                        time.sleep(args.seconds)
            else:
                move(args.x, args.y)
                if args.action != "move":
                    time.sleep(.1)
                    send({"type": "btn", "data": {"down": True, "button": "left"}})
                    time.sleep(.1)
                    if args.action == "drag":
                        move(args.end_x, args.end_y)
                        time.sleep(.1)
                    send({"type": "btn", "data": {"down": False, "button": "left"}})


if __name__ == "__main__":
    main()
