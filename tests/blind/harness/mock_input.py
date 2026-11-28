#!/usr/bin/env python3
"""Real compositor input injector (QMP host bridge + guest client + wtype)."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import socket
import socketserver
import subprocess
import threading
import time
from typing import Any

# QEMU QKeyCode table for printable ASCII
_ASCII_QCODES: dict[str, tuple[str, bool]] = {
    " ": ("spc", False),
    "\n": ("ret", False),
    "\t": ("tab", False),
    "-": ("minus", False),
    "_": ("minus", True),
    "=": ("equal", False),
    "+": ("equal", True),
    "[": ("bracket_left", False),
    "{": ("bracket_left", True),
    "]": ("bracket_right", False),
    "}": ("bracket_right", True),
    "\\": ("backslash", False),
    "|": ("backslash", True),
    ";": ("semicolon", False),
    ":": ("semicolon", True),
    "'": ("apostrophe", False),
    '"': ("apostrophe", True),
    "`": ("grave_accent", False),
    "~": ("grave_accent", True),
    ",": ("comma", False),
    "<": ("comma", True),
    ".": ("dot", False),
    ">": ("dot", True),
    "/": ("slash", False),
    "?": ("slash", True),
    "!": ("1", True),
    "@": ("2", True),
    "#": ("3", True),
    "$": ("4", True),
    "%": ("5", True),
    "^": ("6", True),
    "&": ("7", True),
    "*": ("8", True),
    "(": ("9", True),
    ")": ("0", True),
}
for _c in "abcdefghijklmnopqrstuvwxyz":
    _ASCII_QCODES[_c] = (_c, False)
    _ASCII_QCODES[_c.upper()] = (_c, True)
for _d in "0123456789":
    _ASCII_QCODES[_d] = (_d, False)


class _QmpSession:
    def __init__(self, qmp_sock: str):
        self._qmp_sock = qmp_sock
        self._lock = threading.Lock()
        self._sock: socket.socket | None = None
        self._wire: Any = None

    def _ensure_connected(self) -> None:
        if self._sock is not None:
            return
        sock = socket.socket(socket.AF_UNIX)
        sock.settimeout(5)
        sock.connect(self._qmp_sock)
        wire = sock.makefile("rwb")
        banner = json.loads(wire.readline())
        if "QMP" not in banner:
            raise RuntimeError("Socket is not a QEMU monitor")
        wire.write(json.dumps({"execute": "qmp_capabilities"}).encode() + b"\n")
        wire.flush()
        while True:
            reply = json.loads(wire.readline())
            if "error" in reply:
                raise RuntimeError(reply["error"])
            if "return" in reply:
                break
        self._sock = sock
        self._wire = wire

    def _invoke(self, name: str, **arguments: Any) -> None:
        with self._lock:
            for attempt in range(2):
                try:
                    self._ensure_connected()
                    self._wire.write(
                        json.dumps({"execute": name, "arguments": arguments}).encode() + b"\n"
                    )
                    self._wire.flush()
                    while True:
                        reply = json.loads(self._wire.readline())
                        if "error" in reply:
                            raise RuntimeError(reply["error"])
                        if "return" in reply:
                            return
                except OSError:
                    if self._wire is not None:
                        try:
                            self._wire.close()
                        except OSError:
                            pass
                    if self._sock is not None:
                        try:
                            self._sock.close()
                        except OSError:
                            pass
                    self._wire = None
                    self._sock = None
                    if attempt == 1:
                        raise

    def send_events(self, events: list[dict[str, Any]]) -> None:
        self._invoke("input-send-event", events=events)

    def move(self, x: int, y: int) -> None:
        x = max(0, min(1919, int(x)))
        y = max(0, min(1079, int(y)))
        self.send_events(
            [
                {"type": "abs", "data": {"axis": "x", "value": round(32767 * x / 1919)}},
                {"type": "abs", "data": {"axis": "y", "value": round(32767 * y / 1079)}},
            ]
        )

    def click(self, x: int, y: int, button: str = "left") -> None:
        self.move(x, y)
        time.sleep(0.05)
        self.send_events([{"type": "btn", "data": {"down": True, "button": button}}])
        time.sleep(0.06)
        self.send_events([{"type": "btn", "data": {"down": False, "button": button}}])

    def scroll(self, x: int, y: int, direction: str = "up", steps: int = 1) -> None:
        btn = "wheel-up" if direction == "up" else "wheel-down"
        self.move(x, y)
        time.sleep(0.04)
        for _ in range(max(1, int(steps))):
            self.send_events([{"type": "btn", "data": {"down": True, "button": btn}}])
            time.sleep(0.02)
            self.send_events([{"type": "btn", "data": {"down": False, "button": btn}}])
            time.sleep(0.04)

    def key(self, keys: list[str], hold: float = 0.06) -> None:
        self.send_events(
            [{"type": "key", "data": {"down": True, "key": {"type": "qcode", "data": k}}} for k in keys]
        )
        time.sleep(hold)
        self.send_events(
            [
                {"type": "key", "data": {"down": False, "key": {"type": "qcode", "data": k}}}
                for k in reversed(keys)
            ]
        )

    def type_ascii(self, text: str, delay: float = 0.02) -> None:
        for ch in text:
            if ch not in _ASCII_QCODES:
                raise ValueError(f"Unsupported ASCII character for QMP qcode: {ch!r}")
            qcode, need_shift = _ASCII_QCODES[ch]
            combo = ["shift", qcode] if need_shift else [qcode]
            self.key(combo, hold=0.025)
            if delay > 0:
                time.sleep(delay)


def _make_handler(qmp: _QmpSession):
    class _Handler(socketserver.StreamRequestHandler):
        def handle(self) -> None:
            for raw in self.rfile:
                line = raw.decode("utf-8", errors="replace").strip()
                if not line:
                    continue
                try:
                    req = json.loads(line)
                    op = req.get("op")
                    if op == "ping":
                        resp = {"ok": True}
                    elif op == "move":
                        qmp.move(req["x"], req["y"])
                        resp = {"ok": True}
                    elif op == "click":
                        qmp.click(req["x"], req["y"], req.get("button", "left"))
                        resp = {"ok": True}
                    elif op == "scroll":
                        qmp.scroll(
                            req["x"],
                            req["y"],
                            req.get("direction", "up"),
                            req.get("steps", 1),
                        )
                        resp = {"ok": True}
                    elif op == "key":
                        qmp.key(req["keys"], float(req.get("hold", 0.06)))
                        resp = {"ok": True}
                    elif op == "type_ascii":
                        qmp.type_ascii(req["text"], float(req.get("delay", 0.02)))
                        resp = {"ok": True}
                    else:
                        resp = {"ok": False, "error": f"unknown op {op}"}
                except Exception as exc:
                    resp = {"ok": False, "error": str(exc)}
                self.wfile.write((json.dumps(resp) + "\n").encode("utf-8"))
                self.wfile.flush()

    return _Handler


class _ThreadedTcpServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


def serve_qmp(qmp_sock: str, port_file: str | None) -> None:
    qmp = _QmpSession(qmp_sock)
    with _ThreadedTcpServer(("127.0.0.1", 0), _make_handler(qmp)) as srv:
        port = srv.server_address[1]
        if port_file:
            Path(port_file).write_text(f"{port}\n", encoding="utf-8")
        srv.serve_forever()


class InputClient:
    """Guest-side real input client communicating with host QMP bridge over SSH tunnel."""

    def __init__(self, host: str = "127.0.0.1", port: int | None = None):
        self.host = host
        if port is None:
            env_port = os.environ.get("KAZE_BLIND_QMP_PORT", "")
            port = int(env_port) if env_port.isdigit() else 19876
        self.port = port

    def _call(self, payload: dict[str, Any]) -> None:
        with socket.create_connection((self.host, self.port), timeout=10) as s:
            s.sendall((json.dumps(payload) + "\n").encode("utf-8"))
            line = s.makefile("r", encoding="utf-8").readline()
            resp = json.loads(line)
            if not resp.get("ok"):
                raise RuntimeError(resp.get("error", "QMP input bridge error"))

    def ping(self) -> bool:
        self._call({"op": "ping"})
        return True

    def move(self, x: int, y: int) -> None:
        self._call({"op": "move", "x": int(x), "y": int(y)})

    def click(self, x: int, y: int, button: str = "left") -> None:
        self._call({"op": "click", "x": int(x), "y": int(y), "button": button})

    def right_click(self, x: int, y: int) -> None:
        self.click(x, y, button="right")

    def scroll(self, x: int, y: int, direction: str = "up", steps: int = 1) -> None:
        self._call(
            {
                "op": "scroll",
                "x": int(x),
                "y": int(y),
                "direction": direction,
                "steps": int(steps),
            }
        )

    def key(self, *keys: str, hold: float = 0.06) -> None:
        self._call({"op": "key", "keys": list(keys), "hold": hold})

    def type_ascii(self, text: str, delay: float = 0.02) -> None:
        self._call({"op": "type_ascii", "text": text, "delay": delay})

    def type_unicode(self, text: str) -> None:
        subprocess.run(["wtype", "--", text], check=True, capture_output=True, text=True, timeout=5)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--serve-qmp", required=True)
    ap.add_argument("--port-file", default="")
    args = ap.parse_args()
    serve_qmp(args.serve_qmp, args.port_file or None)


if __name__ == "__main__":
    main()
