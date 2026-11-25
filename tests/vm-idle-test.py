#!/usr/bin/env python3
"""Test the VM sampler's process attribution and T0 verdict without a desktop."""

from collections import Counter
from contextlib import redirect_stderr, redirect_stdout
import io
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import patch


sampler = runpy.run_path(Path(__file__).with_name("vm-idle.py"))


class IdleTest(unittest.TestCase):
    def test_same_uid_worker_in_unknown_scope_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc = Path(tmp)
            fixtures = {
                12: ("waybar", 1000, "app.slice/kaze-waybar.service"),
                13: ("glycin-image-rs", 1000, "app.slice/kaze-wallpaper.service/decoder.scope"),
                14: ("bwrap", 1000, "app.slice/unknown.scope"),
                15: ("at-spi-bus-laun", 1000, "app.slice/at-spi-dbus-bus.service"),
                16: ("pipewire", 1000, "session.slice/pipewire.service"),
                17: ("other-user", 1001, "session.scope"),
            }
            for pid, (comm, uid, cgroup) in fixtures.items():
                folder = proc / str(pid)
                folder.mkdir()
                (folder / "status").write_text(f"Name:\t{comm}\nUid:\t{uid}\t{uid}\t{uid}\t{uid}\n")
                (folder / "cgroup").write_text(f"0::/{cgroup}\n")
            collect = sampler["owned_processes"]
            with patch.dict(collect.__globals__, Path=lambda name: proc if name == "/proc" else Path(name)), \
                    patch("os.getuid", return_value=1000), patch("os.getpid", return_value=11):
                procs, counts = collect()
            self.assertEqual(procs, {
                12: ("waybar", "kaze-waybar.service", "shell"),
                13: ("glycin-image-rs", "kaze-wallpaper.service", "shell"),
                14: ("bwrap", "unknown.scope", "unclassified"),
                15: ("at-spi-bus-laun", "at-spi-dbus-bus.service", "session"),
                16: ("pipewire", "pipewire.service", "outside"),
            })
            self.assertEqual(counts, {"waybar": 1})

    def test_mako_is_exclusive_and_warm_portal_thread_churn_is_reported(self):
        probe = sampler["probe"]
        core = sampler["CORE"] | {"mako.service": "mako"}
        procs = {pid: (comm, unit, "shell") for pid, (unit, comm) in enumerate(core.items(), 12)}
        procs[40] = ("xdg-document-po", "xdg-document-portal.service", "session")
        before = {pid: (123, 0, {"1": 0, "2": 0}) for pid in procs}
        after = before | {40: (123, 0, {"1": 0})}
        with patch.dict(probe.__globals__, {
            "owned_processes": lambda: (procs, Counter(core.values())), "pss_kib": lambda *args: 1024,
        }), patch("time.sleep"), redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()) as warn:
            for phase in ("T0", "T1_retained"):
                snapshots = iter((before, after))
                with patch.dict(probe.__globals__, {"snapshot_counters": lambda _: next(snapshots)}):
                    totals, _, _, portal, _, errors = probe(1, notifications="mako", phase=phase)
                self.assertEqual(bool(errors), phase == "T0")
                self.assertEqual(portal, 1)
                self.assertEqual(totals["shell"][0], 7)
        self.assertIn("WARN (session): PID/thread identities changed", warn.getvalue())

    def test_nondumpable_pss_requires_explicit_guest_opt_in(self):
        read = sampler["pss_kib"]
        with patch.object(Path, "read_text", side_effect=PermissionError), \
                patch("subprocess.run") as command:
            with self.assertRaises(PermissionError):
                read(19)
            command.assert_not_called()
            command.return_value.stdout = "Pss: 123 kB\n"
            self.assertEqual(read(19, guest_sudo_pss=True), 123)
            self.assertEqual(command.call_args.args[0], ["sudo", "-n", "/usr/bin/cat", "/proc/19/smaps_rollup"])

    def verdict(self, *, shell=48, session=34, waybar=33, cpu=.01, ctx=.57, known=True, live=None, journal=None, allow=True):
        ports = sampler["PORTALS"]
        versions = sampler["KNOWN_PORTAL_PAIR"] if known else {}
        totals = {"shell": [shell, cpu, ctx], "session": [session, 0, 0]}
        started = {"kaze-waybar.service"} | (ports if journal is None else journal)
        return sampler["t0_issues"](totals, waybar, ports if live is None else live, 33, started, versions, allow)

    def test_known_stock_stack_is_expected_but_strict_is_failure(self):
        bad, expected = self.verdict()
        self.assertFalse(bad)
        self.assertEqual(len(expected), 2)
        for kwargs in ({"allow": False}, {"known": False}, {"live": set()}):
            bad, expected = self.verdict(**kwargs)
            self.assertEqual(len(bad), 2)
            self.assertFalse(expected)

    def test_unrelated_regressions_are_never_waived(self):
        for kwargs, reason in (({"shell": 56}, "shell PSS"), ({"cpu": .21}, "idle CPU"),
                               ({"waybar": 41}, "Waybar PSS"), ({"ctx": 5.1}, "context switches/s"),
                               ({"session": 46}, "shell + active session PSS")):
            bad, _ = self.verdict(**kwargs)
            self.assertTrue(any(line.startswith(reason) for line in bad), bad)

    def test_no_portal_is_a_real_pass(self):
        self.assertEqual(self.verdict(session=1, journal=set(), live=set()), ([], []))


if __name__ == "__main__":
    unittest.main()
