"""Recorder admission and lifetime checks without Instruments, a display, or an app."""
import json
from pathlib import Path
import signal
import subprocess
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

import profile_synthetic as profile


class SyntheticProfileTests(unittest.TestCase):
    def prepare(self, root):
        manifest = {"schemaVersion": 1, "runID": "synthetic-run"}
        process = {"pid": 42, "runID": manifest["runID"], "startIdentity": "synthetic-start", "executable": "/SyntheticDemo"}
        status = {
            **manifest, "pid": 42, "state": "measurement-ready", "failureCode": None,
            "window": {"visible": True, "miniaturized": False, "key": True, "width": 1200, "height": 800, "inspector": "queue"},
            "display": {"scale": 2, "maximumFramesPerSecond": 120, "reducedMotion": False},
        }
        for name, value in (("manifest", manifest), ("process", process), ("run-status", status)):
            profile.write_json(root / f"{name}.json", value)
        return manifest, process, status

    def test_missing_recorder_fails_before_native_probe_or_recorder_launch(self):
        with TemporaryDirectory() as directory, patch.object(profile.subprocess, "check_output", side_effect=FileNotFoundError), patch.object(profile.subprocess, "Popen") as recorder:
            with self.assertRaisesRegex(profile.InvalidRun, "recorder-unavailable"):
                profile.preflight(Path(directory))
            recorder.assert_not_called()

    def test_locked_unknown_inactive_and_missing_display_fail_preflight(self):
        cases = [
            ({"onConsole": True, "loginDone": True, "locked": True}, 1, "session-locked"),
            ({"onConsole": True, "loginDone": True, "locked": None}, 1, "session-unknown"),
            ({"onConsole": False, "loginDone": True, "locked": False}, 1, "session-inactive"),
            ({"onConsole": True, "loginDone": True, "locked": False}, 0, "display-unavailable"),
        ]
        for session, display, code in cases:
            with self.subTest(code=code), TemporaryDirectory() as directory:
                outputs = ["/Synthetic/xctrace", "Animation Hitches", "Xcode synthetic", "26.5", json.dumps({"schemaVersion": 1, "session": session, "displayCount": display})]
                with patch.object(profile, "command_output", side_effect=outputs):
                    with self.assertRaisesRegex(profile.InvalidRun, code):
                        profile.preflight(Path(directory))
                self.assertFalse((Path(directory) / "preflight.json").exists())

    def test_occluded_or_reused_pid_does_not_start_recorder(self):
        for matches, visible, reason in ((True, False, "window-ineligible"), (False, True, "process-identity-mismatch")):
            with self.subTest(reason=reason), TemporaryDirectory() as directory:
                root = Path(directory)
                _, _, status = self.prepare(root)
                status["window"]["visible"] = visible
                profile.write_json(root / "run-status.json", status)
                with patch.object(profile.browsing_process, "matches", return_value=matches), patch.object(profile.subprocess, "Popen") as recorder:
                    with self.assertRaisesRegex(profile.InvalidRun, reason):
                        profile.profile(root)
                    recorder.assert_not_called()
                self.assertEqual(profile.read_json(root / "profiler-state.json")["failureCode"], reason)
                self.assertFalse((root / "profiler-ready").exists())

    def run_recorder(self, *, finish_after=244, final_status="workload-finished", exit_early=False, save_timeout=False, export_failure=False, report_identity="synthetic-run"):
        directory = TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        manifest, process, status = self.prepare(root)
        clock = {"now": 0.0}
        calls = {"interrupts": [], "save_timeouts": [], "commands": [], "terminated": [], "killed": []}

        class Recorder:
            returncode = None

            def __init__(self, command, stdout, **kwargs):
                calls["commands"].append(command)
                self.deadline = float(command[command.index("--time-limit") + 1].removesuffix("s"))
                stdout.write("Ctrl-C to stop the recording\n")
                stdout.flush()
                (root / "animation.trace").mkdir()

            def poll(self):
                if exit_early or clock["now"] >= self.deadline:
                    self.returncode = 0
                return self.returncode

            def send_signal(self, value):
                calls["interrupts"].append(value)

            def terminate(self):
                calls["terminated"].append(True)
                self.returncode = -15

            def kill(self):
                calls["killed"].append(True)
                self.returncode = -9

            def wait(self, timeout):
                calls["save_timeouts"].append(timeout)
                if save_timeout and timeout == profile.RECORDER_SAVE_TIMEOUT_SECONDS:
                    raise subprocess.TimeoutExpired("synthetic recorder", timeout)
                if self.returncode is None:
                    self.returncode = 0
                return self.returncode

        def sleep(seconds):
            clock["now"] += seconds
            if clock["now"] >= finish_after:
                status["state"] = final_status
                profile.write_json(root / "run-status.json", status)
                profile.write_json(root / "report.json", {"passed": final_status != "failed", "launch": {"runID": report_identity}})

        def export(run_root):
            if export_failure:
                raise profile.InvalidRun("trace-export-failed")
            profile.write_json(run_root / "trace-summary.json", {"completeApplicationFrames": 100})

        self.addCleanup(patch.stopall)
        for target, name, kwargs in (
            (profile.browsing_process, "matches", {"return_value": True}),
            (profile, "preflight", {"return_value": {}}),
            (profile, "session_preflight", {"return_value": {}}),
            (profile.subprocess, "Popen", {"new": Recorder}),
            (profile.time, "monotonic", {"side_effect": lambda: clock["now"]}),
            (profile.time, "sleep", {"side_effect": sleep}),
            (profile, "export_trace", {"side_effect": export}),
        ):
            patch.object(target, name, **kwargs).start()
        return root, calls

    def test_long_workload_attaches_exact_pid_and_waits_for_save_and_export(self):
        root, calls = self.run_recorder()
        profile.profile(root)
        command = calls["commands"][0]
        self.assertEqual(command[command.index("--attach") + 1], "42")
        self.assertEqual(calls["interrupts"], [signal.SIGINT])
        self.assertEqual(calls["save_timeouts"], [profile.RECORDER_SAVE_TIMEOUT_SECONDS])
        self.assertTrue((root / "trace-summary.json").exists())
        state = profile.read_json(root / "profiler-state.json")
        self.assertEqual([item["state"] for item in state["history"]], ["preparing", "recording", "workload-finished", "saving", "complete"])

    def test_failed_incomplete_foreign_report_or_unsaved_trace_never_accepts_summary(self):
        for kwargs, reason in (
            ({"final_status": "failed", "finish_after": 1}, "workload-failed"),
            ({"report_identity": "another-run", "finish_after": 1}, "workload-failed"),
            ({"exit_early": True}, "recorder-ended-early"),
            ({"save_timeout": True, "finish_after": 1}, "recorder-save-failed"),
            ({"export_failure": True, "finish_after": 1}, "trace-export-failed"),
        ):
            with self.subTest(reason=reason):
                root, calls = self.run_recorder(**kwargs)
                with self.assertRaisesRegex(profile.InvalidRun, reason):
                    profile.profile(root)
                self.assertFalse((root / "trace-summary.json").exists())
                self.assertEqual(profile.read_json(root / "profiler-state.json")["failureCode"], reason)
                self.assertEqual(calls["killed"], [])
                if kwargs.get("exit_early"):
                    self.assertFalse((root / "profiler-ready").exists())
                patch.stopall()

    def test_report_file_alone_cannot_finish_workload(self):
        root, _ = self.run_recorder(finish_after=1, final_status="measurement-ready")
        with self.assertRaisesRegex(profile.InvalidRun, "workload-timeout"):
            profile.profile(root)
        self.assertTrue((root / "report.json").exists())
        self.assertFalse((root / "trace-summary.json").exists())

    def test_changed_conditions_during_recorder_start_never_release_workload(self):
        for reason in ("session-locked", "window-ineligible", "process-identity-mismatch", "app-not-ready"):
            with self.subTest(reason=reason):
                root, _ = self.run_recorder(finish_after=1)

                def after_attach():
                    if reason == "session-locked":
                        raise profile.InvalidRun(reason)
                    status = profile.read_json(root / "run-status.json")
                    if reason == "window-ineligible":
                        status["window"]["visible"] = False
                    elif reason == "app-not-ready":
                        status["state"] = "failed"
                    else:
                        profile.browsing_process.matches.return_value = False
                    profile.write_json(root / "run-status.json", status)

                with patch.object(profile, "session_preflight", side_effect=after_attach):
                    with self.assertRaisesRegex(profile.InvalidRun, reason):
                        profile.profile(root)
                self.assertFalse((root / "profiler-ready").exists())
                self.assertFalse((root / "trace-summary.json").exists())
                patch.stopall()


if __name__ == "__main__":
    unittest.main()
