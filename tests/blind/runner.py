#!/usr/bin/env python3
"""Black-box blind test runner & report merger for kaze-shell."""

from __future__ import annotations

import argparse
import importlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import time
from typing import Any, Callable

BLIND_DIR = Path(__file__).resolve().parent
if str(BLIND_DIR) not in sys.path:
    sys.path.insert(0, str(BLIND_DIR))
sys.modules.setdefault("runner", sys.modules[__name__])

from harness import oracle_proc, oracle_visual
from harness.mock_input import InputClient

ALL_TEST_IDS: tuple[str, ...] = (
    # Suite A
    "A01", "A02", "A03", "A04", "A05", "A06", "A07", "A08", "A09",
    # Suite B
    "B01", "B02", "B03", "B04", "B05", "B06",
    # Suite C
    "C01", "C02", "C03", "C04",
    # Suite D
    "D01", "D02", "D03", "D04", "D05", "D06", "D07",
    # Suite E
    "E01", "E02", "E03", "E04", "E05", "E06",
    # Suite F
    "F01", "F02", "F03", "F04",
    # Suite G
    "G01", "G02", "G03", "G04",
    # Suite H
    "H01", "H02", "H03", "H04", "H05", "H06",
    # Suite I
    "I01", "I02", "I03",
)

REQUIRED_ARTIFACTS: tuple[str, ...] = (
    "preset-omarchy.png",
    "preset-island.png",
    "preset-swiss.png",
    "preset-ghost.png",
    "preset-ghost-peek.png",
    "island-floating.png",
    "island-notch.png",
    "control-center.png",
    "notify-vietnamese-emoji.png",
    "launcher-dmenu.png",
    "tray-menu.png",
)


class TestFailure(AssertionError):
    """Raised with an OS/oracle symptom description."""


class NonceVault:
    def __init__(self) -> None:
        self._nonces: list[str] = []

    def new(self, tag: str = "") -> str:
        tok = secrets.token_hex(5)
        self._nonces.append(tok)
        return f"{tag}-{tok}" if tag else tok

    def redact(self, text: str) -> str:
        out = str(text)
        for tok in sorted(self._nonces, key=len, reverse=True):
            out = out.replace(tok, "<NONCE>")
        out = re.sub(r"(/[^ \n'\"]*tests/blind/[^ \n'\"]*)", "<HARNESS_PATH>", out)
        out = re.sub(r"tests/blind/[^\s'\"]+", "<HARNESS_PATH>", out)
        out = re.sub(r"\s+", " ", out).strip()
        return out[:500]


class BlindContext:
    def __init__(self, artifacts_dir: Path, qmp_port: int | None = None) -> None:
        self.proc = oracle_proc
        self.vis = oracle_visual
        self.inp = InputClient(port=qmp_port)
        self.vault = NonceVault()
        self.artifacts_dir = artifacts_dir
        self.artifacts_dir.mkdir(parents=True, exist_ok=True)
        self.harness_dir = BLIND_DIR / "harness"
        self.repo_dir = BLIND_DIR.parent.parent

    def nonce(self, tag: str = "") -> str:
        return self.vault.new(tag)

    def save_artifact(
        self,
        name: str,
        region: tuple[int, int, int, int] | None = None,
        output: str | None = "Virtual-1",
    ) -> Path:
        return self.vis.capture_png(self.artifacts_dir / name, region=region, output=output)

    def require(self, cond: bool, symptom: str) -> None:
        if not cond:
            raise TestFailure(symptom)

    def ensure_default_state(self) -> None:
        if not self._daemon_alive():
            subprocess.run(
                ["systemctl", "--user", "restart", "kaze-shell.service"],
                capture_output=True,
                timeout=8,
            )
            self.wait_daemon_ready()
        for args in (
            ("launcher-close",),
            ("cc-close",),
            ("tray-menu-close",),
            ("notify-clear",),
            ("dnd-off",),
            ("wallpaper-clear",),
            ("caffeine-set", "off"),
            ("nightlight-set", "off"),
            ("island-clear", "all"),
            ("layout-set", "omarchy"),
            ("display-status", "idle"),
        ):
            try:
                self.proc.kaze_msg(*args, timeout=3.0)
            except Exception:
                pass
        subprocess.run(
            ["hyprctl", "output", "remove", "kaze-share"],
            capture_output=True,
            timeout=3,
        )
        try:
            self.proc.switch_workspace(1)
        except Exception:
            pass
        self.proc.wait_layer("kaze-bar-Virtual-1", present=True, timeout=4.0)

    def _daemon_alive(self) -> bool:
        try:
            rc, out, _ = self.proc.kaze_msg("ping", timeout=1.5)
            return rc == 0 and out == "pong"
        except Exception:
            return False

    def wait_daemon_ready(self, timeout: float = 6.0) -> int:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self._daemon_alive():
                try:
                    return self.proc.get_shell_pid()
                except Exception:
                    pass
            time.sleep(0.1)
        raise TestFailure("kaze-shell daemon did not respond to ping within timeout")


def _load_registry() -> dict[str, Callable[[BlindContext], None]]:
    reg: dict[str, Callable[[BlindContext], None]] = {}
    for letter in "abcdefghi":
        mod = importlib.import_module(f"suites.suite_{letter}")
        tests = getattr(mod, "TESTS", {})
        for tid, fn in tests.items():
            reg[tid] = fn
    return reg


def run_preflight(require_qmp: bool) -> int:
    required_bins = (
        "grim",
        "wl-paste",
        "wl-copy",
        "cliphist",
        "notify-send",
        "wpctl",
        "hyprctl",
        "busctl",
        "ldd",
        "readelf",
        "nm",
        "wtype",
        "tesseract",
        "fcitx5",
        "fcitx5-remote",
        "wl-mirror",
        "kaze-shell",
        "kaze-display",
        "kaze-keys",
        "kaze-doctor",
        "kaze-session",
        "footclient",
        "hyprlock",
        "hypridle",
    )
    missing_bins = [b for b in required_bins if shutil.which(b) is None]
    if not os.access("/usr/lib/hyprpolkitagent/hyprpolkitagent", os.X_OK):
        missing_bins.append("/usr/lib/hyprpolkitagent/hyprpolkitagent")
    if missing_bins:
        print(f"PREFLIGHT FAIL: missing binaries: {', '.join(missing_bins)}", file=sys.stderr)
        return 1
    for mod in ("dbus", "gi", "PIL"):
        try:
            importlib.import_module(mod)
        except Exception as exc:
            print(f"PREFLIGHT FAIL: missing Python module {mod}: {exc}", file=sys.stderr)
            return 1
    wp = subprocess.run(
        ["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"],
        capture_output=True,
        text=True,
        timeout=5,
    )
    if wp.returncode != 0:
        print(f"PREFLIGHT FAIL: wpctl default sink unavailable: {wp.stderr.strip()}", file=sys.stderr)
        return 1
    if require_qmp:
        try:
            InputClient().ping()
        except Exception as exc:
            print(f"PREFLIGHT FAIL: QMP input bridge unreachable: {exc}", file=sys.stderr)
            return 1
    print("PREFLIGHT PASS: all required blind-test tools and oracles available")
    return 0


def _select_ids(phase: str, only: str) -> list[str]:
    if only.strip():
        tokens = [t.strip().upper() for t in only.split(",") if t.strip()]
        selected: list[str] = []
        for tid in ALL_TEST_IDS:
            if tid in tokens or tid[0] in tokens:
                selected.append(tid)
        if not selected:
            raise SystemExit(f"No matching test IDs for --only={only!r}")
        if phase == "t0":
            return [t for t in selected if t == "B01"]
        if phase == "full":
            return [t for t in selected if t != "B01"]
        return selected
    if phase == "t0":
        return ["B01"]
    if phase == "full":
        return [t for t in ALL_TEST_IDS if t != "B01"]
    return list(ALL_TEST_IDS)


def run_tests(args: argparse.Namespace) -> int:
    reg = _load_registry()
    selected = _select_ids(args.phase, args.only)
    ctx = BlindContext(Path(args.artifacts_dir))
    results: list[dict[str, str]] = []

    for tid in selected:
        fn = reg.get(tid)
        if fn is None:
            results.append({"id": tid, "status": "FAIL", "symptom": "test case not registered"})
            continue
        if tid != "B01":
            try:
                ctx.ensure_default_state()
            except Exception as exc:
                results.append(
                    {
                        "id": tid,
                        "status": "FAIL",
                        "symptom": ctx.vault.redact(f"session recovery before test failed: {exc}"),
                    }
                )
                continue
        try:
            fn(ctx)
            results.append({"id": tid, "status": "PASS", "symptom": ""})
            print(f"{tid} PASS", flush=True)
        except TestFailure as exc:
            sym = ctx.vault.redact(str(exc))
            results.append({"id": tid, "status": "FAIL", "symptom": sym})
            print(f"{tid} FAIL: {sym}", flush=True)
        except Exception as exc:
            sym = ctx.vault.redact(f"unexpected {type(exc).__name__}: {exc}")
            results.append({"id": tid, "status": "FAIL", "symptom": sym})
            print(f"{tid} FAIL: {sym}", flush=True)

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps({"results": results}, indent=2), encoding="utf-8")
    return 0 if all(r["status"] == "PASS" for r in results) else 1


def merge_reports(args: argparse.Namespace) -> int:
    by_id: dict[str, dict[str, str]] = {}
    for rep in args.merge_reports:
        p = Path(rep)
        if not p.exists():
            continue
        data = json.loads(p.read_text(encoding="utf-8"))
        for item in data.get("results", []):
            tid = item.get("id", "")
            if tid:
                by_id[tid] = item

    expected_ids = _select_ids("all", args.only)
    lines: list[str] = ["=== Kaze Shell Blind Test Report ==="]
    pass_count = 0
    fail_count = 0
    for tid in expected_ids:
        rec = by_id.get(tid)
        if rec is None:
            fail_count += 1
            lines.append(f"{tid} FAIL: test did not execute")
        elif rec.get("status") == "PASS":
            pass_count += 1
            lines.append(f"{tid} PASS")
        else:
            fail_count += 1
            lines.append(f"{tid} FAIL: {rec.get('symptom', 'unspecified failure')}")

    art_dir = Path(args.artifacts_dir)
    if not args.only.strip():
        missing_arts = [
            name for name in REQUIRED_ARTIFACTS
            if not (art_dir / name).is_file() or (art_dir / name).stat().st_size == 0
        ]
        if missing_arts:
            fail_count += 1
            lines.append(f"ARTIFACTS FAIL: missing required evidence PNG(s): {', '.join(missing_arts)}")

    lines.append(f"Summary: {pass_count}/{len(expected_ids)} PASS, {fail_count} FAIL")
    report_text = "\n".join(lines) + "\n"
    print(report_text, end="")
    art_dir.mkdir(parents=True, exist_ok=True)
    (art_dir / "report.txt").write_text(report_text, encoding="utf-8")
    return 0 if fail_count == 0 else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--preflight", action="store_true")
    ap.add_argument("--require-qmp", action="store_true")
    ap.add_argument("--phase", choices=("all", "t0", "full"), default="all")
    ap.add_argument("--only", default="")
    ap.add_argument("--out", default="/tmp/blind-report.json")
    ap.add_argument("--artifacts-dir", default="/tmp/kaze-blind-artifacts")
    ap.add_argument("--merge-reports", nargs="+")
    args = ap.parse_args()

    if args.preflight:
        return run_preflight(args.require_qmp)
    if args.merge_reports:
        return merge_reports(args)
    return run_tests(args)


if __name__ == "__main__":
    sys.exit(main())
