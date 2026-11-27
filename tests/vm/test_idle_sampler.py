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


sampler = runpy.run_path(Path(__file__).with_name("idle_sampler.py"))


class IdleTest(unittest.TestCase):
    def test_same_uid_worker_in_unknown_scope_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc = Path(tmp)
            fixtures = {
                12: ("kaze-shell", 1000, "app.slice/kaze-shell.service"),
                13: ("foot", 1000, "app.slice/foot-server.service"),
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
                12: ("kaze-shell", "kaze-shell.service", "shell"),
                13: ("foot", "foot-server.service", "shell"),
                14: ("bwrap", "unknown.scope", "unclassified"),
                15: ("at-spi-bus-laun", "at-spi-dbus-bus.service", "session"),
                16: ("pipewire", "pipewire.service", "outside"),
            })
            self.assertEqual(counts, {"kaze-shell": 1, "foot": 1})

    def test_warm_portal_thread_churn_is_reported(self):
        probe = sampler["probe"]
        core = sampler["CORE"]
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
                    totals, _, portals, _, errors = probe(1, phase=phase)
                self.assertEqual(bool(errors), phase == "T0")
                self.assertEqual(portals, {"xdg-document-portal.service"})
                self.assertEqual(totals["shell"][0], 2)
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

    def verdict(self, *, shell=35.0, session=5.0, cpu=0.05, ctx=1.5, live=None, journal=None):
        totals = {"shell": [shell, cpu, ctx], "session": [session, 0.0, 0.0]}
        started = {"kaze-shell.service"} | (set() if journal is None else journal)
        return sampler["t0_issues"](totals, set() if live is None else live, started)

    def test_no_portal_within_budget_passes(self):
        self.assertEqual(self.verdict(), [])

    def test_early_portal_is_failure(self):
        bad = self.verdict(live={"xdg-desktop-portal.service"})
        self.assertTrue(any("portal activation" in line for line in bad), bad)

    def test_regressions_are_flagged(self):
        for kwargs, reason in (
            ({"shell": 76.0}, "shell PSS"),
            ({"cpu": 0.21}, "idle CPU"),
            ({"ctx": 4.1}, "context switches/s"),
            ({"shell": 70.0, "session": 6.0}, "shell+session PSS"),
        ):
            bad = self.verdict(**kwargs)
            self.assertTrue(any(line.startswith(reason) for line in bad), bad)


if __name__ == "__main__":
    unittest.main()
