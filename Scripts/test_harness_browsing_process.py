"""Exercise Demo process ownership without launching or signaling any process."""
import json
from pathlib import Path
import signal
import subprocess
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import ANY, patch

import browsing_process


class BrowsingProcessTests(unittest.TestCase):
    executable = "/synthetic/Spotty Demo.app/Contents/MacOS/SpottyDemo"
    started = "Tue Sep 22 12:00:00 2026"

    def record(self):
        return {"pid": 149, "startIdentity": self.started, "executable": self.executable}

    def test_capture_requires_stable_start_and_exact_kernel_executable(self):
        with (
            patch.object(browsing_process, "start_identity", return_value=self.started) as start,
            patch.object(browsing_process, "executable_path", return_value=self.executable),
        ):
            self.assertEqual(browsing_process.capture(149, self.executable), self.record())
        self.assertEqual(start.call_count, 2)
        for starts, executable in (
            ([self.started, "Tue Sep 22 12:00:01 2026"], self.executable),
            ([self.started], "/unrelated/SpottyDemo"),
        ):
            with (
                self.subTest(starts=starts, executable=executable),
                patch.object(browsing_process, "start_identity", side_effect=starts),
                patch.object(browsing_process, "executable_path", return_value=executable),
                self.assertRaises(ProcessLookupError),
            ):
                browsing_process.capture(149, self.executable)

    def test_ps_start_identity_is_locale_and_timezone_stable(self):
        result = subprocess.CompletedProcess([], 0, "Tue Sep 22 12:00:00 2026\n")
        with patch.object(browsing_process.subprocess, "run", return_value=result) as run:
            self.assertEqual(browsing_process.start_identity(149), self.started)
        self.assertEqual(run.call_args.args[0], ["/bin/ps", "-p", "149", "-o", "lstart="])
        self.assertEqual(run.call_args.kwargs["env"]["LC_ALL"], "C")
        self.assertEqual(run.call_args.kwargs["env"]["TZ"], "UTC")
        self.assertEqual(run.call_args.kwargs["timeout"], browsing_process.PROCESS_QUERY_TIMEOUT_SECONDS)
        for status, output in ((1, ""), (0, ""), (0, self.started + "\n" + self.started)):
            with (
                self.subTest(status=status, output=output),
                patch.object(browsing_process.subprocess, "run", return_value=subprocess.CompletedProcess([], status, output)),
                self.assertRaises(ProcessLookupError),
            ):
                browsing_process.start_identity(149)

    def test_matches_rejects_reused_pids_and_unavailable_or_changed_executables(self):
        for current in (
            {**self.record(), "startIdentity": "Tue Sep 22 12:00:01 2026"},
            {**self.record(), "executable": "/unrelated/SpottyDemo"},
        ):
            with self.subTest(current=current), patch.object(browsing_process, "capture", return_value=current):
                self.assertFalse(browsing_process.matches(self.record()))
        for error in (ProcessLookupError(), PermissionError(), subprocess.TimeoutExpired("ps", 2)):
            with self.subTest(error=error), patch.object(browsing_process, "capture", side_effect=error):
                self.assertFalse(browsing_process.matches(self.record()))
        with patch.object(browsing_process, "capture") as capture:
            for invalid in ({}, {**self.record(), "pid": -1}, {**self.record(), "pid": True}):
                self.assertFalse(browsing_process.matches(invalid))
            capture.assert_not_called()

    def test_discovery_selects_exact_executable_among_same_named_processes(self):
        with (
            patch.object(browsing_process, "process_ids", return_value=[149, 421, 999]),
            patch.object(browsing_process, "executable_path", side_effect=[self.executable, "/unrelated/SpottyDemo", ProcessLookupError()]),
            patch.object(browsing_process, "capture", return_value=self.record()) as capture,
        ):
            self.assertEqual(browsing_process.discover(self.executable), self.record())
        capture.assert_called_once_with(149, self.executable, deadline=ANY)

    def test_discovery_rejects_ambiguity_and_times_out_without_process(self):
        with (
            patch.object(browsing_process, "process_ids", return_value=[149, 421]),
            patch.object(browsing_process, "executable_path", return_value=self.executable),
            patch.object(browsing_process, "capture", return_value=self.record()),
            self.assertRaisesRegex(RuntimeError, "Multiple processes"),
        ):
            browsing_process.discover(self.executable)
        with (
            patch.object(browsing_process, "process_ids", return_value=[]),
            patch.object(browsing_process.time, "monotonic", side_effect=[0, 11]),
            self.assertRaisesRegex(RuntimeError, "did not launch"),
        ):
            browsing_process.discover(self.executable)

    def test_record_is_bound_to_manifest_run_and_written_atomically(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps({"runID": "synthetic-run"}))
            browsing_process.write_record(root, self.record())
            self.assertEqual(browsing_process.load_record(root), {**self.record(), "runID": "synthetic-run"})
            self.assertFalse((root / "process.json.tmp").exists())
            manifest.write_text(json.dumps({"runID": "different-run"}))
            with self.assertRaisesRegex(ValueError, "does not belong"):
                browsing_process.load_record(root)
            manifest.write_text("{}")
            with self.assertRaisesRegex(ValueError, "missing its runID"):
                browsing_process.write_record(root, self.record())

    def test_discovery_deadline_applies_during_inventory_and_before_returning_match(self):
        for executable in (self.executable, "/unrelated/SpottyDemo"):
            with (
                self.subTest(executable=executable),
                patch.object(browsing_process, "process_ids", return_value=[149] if executable == self.executable else [149, 421]),
                patch.object(browsing_process, "executable_path", return_value=executable) as read_path,
                patch.object(browsing_process, "capture", return_value=self.record()),
                patch.object(browsing_process.time, "monotonic", side_effect=[0, 0, 11]),
                self.assertRaisesRegex(RuntimeError, "before the deadline"),
            ):
                browsing_process.discover(self.executable)
            read_path.assert_called_once_with(149)
        result = subprocess.CompletedProcess([], 0, self.started)
        with (
            patch.object(browsing_process.time, "monotonic", return_value=9.5),
            patch.object(browsing_process.subprocess, "run", return_value=result) as run,
        ):
            browsing_process.start_identity(149, deadline=10)
        self.assertEqual(run.call_args.kwargs["timeout"], 0.5)

    def test_termination_never_signals_reused_pid_or_different_executable(self):
        for current in (
            {**self.record(), "startIdentity": "Tue Sep 22 12:00:01 2026"},
            {**self.record(), "executable": "/unrelated/SpottyDemo"},
        ):
            with (
                self.subTest(current=current),
                patch.object(browsing_process, "capture", return_value=current),
                patch.object(browsing_process.os, "kill") as kill,
            ):
                browsing_process.terminate(self.record())
                kill.assert_not_called()

    def test_termination_only_sends_term_to_verified_pid_and_stops_on_reuse(self):
        with (
            patch.object(browsing_process, "matches", side_effect=[True, True, False]),
            patch.object(browsing_process.os, "kill") as kill,
            patch.object(browsing_process.time, "sleep"),
        ):
            browsing_process.terminate(self.record())
        kill.assert_called_once_with(149, signal.SIGTERM)

    def test_termination_timeout_does_not_escalate_or_signal_unrelated_processes(self):
        with (
            patch.object(browsing_process, "matches", return_value=True),
            patch.object(browsing_process.os, "kill") as kill,
            patch.object(browsing_process.time, "monotonic", side_effect=[0, 6]),
            self.assertRaisesRegex(RuntimeError, "did not terminate"),
        ):
            browsing_process.terminate(self.record())
        kill.assert_called_once_with(149, signal.SIGTERM)


if __name__ == "__main__":
    unittest.main()
