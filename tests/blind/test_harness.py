#!/usr/bin/env python3
"""Local unit tests for the blind test harness (oracles, redaction, no-SKIP enforcement)."""

from __future__ import annotations

import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

BLIND_DIR = Path(__file__).resolve().parent
if str(BLIND_DIR) not in sys.path:
    sys.path.insert(0, str(BLIND_DIR))

from harness import oracle_proc, oracle_visual
import runner


def _make_ppm(w: int, h: int, fill: tuple[int, int, int], patches: list[tuple[int, int, int, int, tuple[int, int, int]]] = ()) -> bytes:
    buf = bytearray(fill * (w * h))
    for x0, y0, x1, y1, rgb in patches:
        for y in range(y0, y1):
            for x in range(x0, x1):
                off = (y * w + x) * 3
                buf[off : off + 3] = bytes(rgb)
    return f"P6\n# comment\n{w} {h}\n255\n".encode("ascii") + bytes(buf)


class HarnessUnitTests(unittest.TestCase):
    def test_ppm_and_anti_swap_channel_oracle(self) -> None:
        raw_red = oracle_visual.parse_ppm(_make_ppm(40, 40, (20, 20, 24), [(10, 10, 20, 20, (230, 25, 25))]))
        raw_swapped = oracle_visual.parse_ppm(_make_ppm(40, 40, (20, 20, 24), [(10, 10, 20, 20, (25, 25, 230))]))
        raw_bg = oracle_visual.parse_ppm(_make_ppm(40, 40, (20, 20, 24)))

        self.assertEqual(oracle_visual.pixel_variance(raw_bg), 0.0)
        self.assertGreater(oracle_visual.pixel_variance(raw_red), 100.0)

        diff = oracle_visual.diff_stats(raw_bg, raw_red, threshold=14)
        self.assertEqual(diff["changed_count"], 100)
        self.assertEqual(diff["bbox"], (10, 10, 19, 19))

        ch_ok = oracle_visual.chromatic_stats(raw_red, indices=diff["changed_indices"], min_sat=50)
        self.assertGreater(ch_ok["mean_r"], 170)
        self.assertLess(ch_ok["mean_b"], 70)

        ch_bad = oracle_visual.chromatic_stats(raw_swapped, indices=diff["changed_indices"], min_sat=50)
        self.assertLess(ch_bad["mean_r"], 70)
        self.assertGreater(ch_bad["mean_b"], 170)

    def test_vertical_bands_separation(self) -> None:
        img_a = oracle_visual.parse_ppm(_make_ppm(20, 60, (10, 10, 10), [(5, 5, 15, 15, (220, 40, 40))]))
        img_b = oracle_visual.parse_ppm(_make_ppm(20, 60, (10, 10, 10), [(5, 35, 15, 45, (220, 40, 40))]))
        diff = oracle_visual.diff_stats(img_a, img_b, threshold=14)
        self.assertEqual(len(diff["y_bands"]), 2)
        self.assertLess(diff["y_bands"][0][3], diff["y_bands"][1][3])

    def test_wcag_contrast_and_theme_parser(self) -> None:
        self.assertAlmostEqual(oracle_visual.wcag_contrast_ratio((255, 255, 255), (0, 0, 0)), 21.0, places=2)
        self.assertLess(oracle_visual.wcag_contrast_ratio((120, 120, 120), (140, 140, 140)), 2.0)
        with tempfile.TemporaryDirectory() as td:
            ft = Path(td) / "foot"
            gtk = Path(td) / "gtk.css"
            ft.write_text("[colors-dark]\nforeground=f0f0f0\nbackground=101420\n", encoding="utf-8")
            gtk.write_text("@define-color theme_fg_color #f0f0f0;\n@define-color theme_bg_color #101420;\n", encoding="utf-8")
            ratio, _ = oracle_visual.check_theme_wcag(ft, gtk)
            self.assertGreater(ratio, 12.0)

    def test_proc_parsers(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            pdir = Path(td) / "123"
            (pdir / "task" / "123").mkdir(parents=True)
            (pdir / "fd").mkdir()
            (pdir / "smaps_rollup").write_text("Rss: 2048 kB\nPss: 1536 kB\n", encoding="utf-8")
            (pdir / "status").write_text("Name:\tkaze-shell\nThreads:\t3\n", encoding="utf-8")
            (pdir / "stat").write_text("123 (kaze-shell) S 1 1 1 0 -1 0 0 0 0 0 10 5 0 0 20 0 3 0 999 0 0\n", encoding="utf-8")
            (pdir / "task" / "123" / "status").write_text("voluntary_ctxt_switches:\t12\nnonvoluntary_ctxt_switches:\t3\n", encoding="utf-8")
            os.symlink("memfd:wayland-shm", pdir / "fd" / "3")
            os.symlink("/dev/null", pdir / "fd" / "4")

            real_path = Path
            with patch.object(oracle_proc, "Path", side_effect=lambda s: real_path(str(s).replace("/proc/123", str(pdir)))):
                self.assertEqual(oracle_proc.read_pss_kib(123), 1536)
                self.assertEqual(oracle_proc.read_threads(123), 3)
                self.assertEqual(oracle_proc.read_stat(123), (999, 15))
                self.assertEqual(oracle_proc.read_ctx_switches(123), 15)
                self.assertEqual(oracle_proc.read_fd_counts(123), (2, 1))

    def test_nonce_redaction_and_missing_test_is_fail(self) -> None:
        vault = runner.NonceVault()
        tok = vault.new("secret")
        redacted = vault.redact(f"Saw {tok} in /home/u/repo/tests/blind/suites/suite_a.py")
        self.assertNotIn(tok, redacted)
        self.assertIn("<NONCE>", redacted)
        self.assertNotIn("tests/blind/", redacted)

        with tempfile.TemporaryDirectory() as td:
            rep = Path(td) / "r.json"
            art = Path(td) / "art"
            rep.write_text(json.dumps({"results": [{"id": "A01", "status": "PASS", "symptom": ""}]}))
            ns = type("Args", (), {"merge_reports": [str(rep)], "artifacts_dir": str(art), "only": ""})()
            rc = runner.merge_reports(ns)
            self.assertEqual(rc, 1)
            txt = (art / "report.txt").read_text(encoding="utf-8")
            self.assertIn("A02 FAIL: test did not execute", txt)
            self.assertNotIn("SKIP", txt)


if __name__ == "__main__":
    unittest.main()
