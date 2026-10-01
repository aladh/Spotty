"""Failure sensitivity and exact ownership of the synthetic GUI runner; no GUI is launched."""
from copy import deepcopy
import json
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import Mock, patch

import browsing_provenance
import gui_regression as gui
from harness_fixtures import launch_manifest


class GUIRegressionChecks(unittest.TestCase):
    def fixture(self, root, signed_out=False):
        fixture = root / "fixture.json"
        scenario = {"version": 2, "mode": "signed-out" if signed_out else "browsing", "guiShellRegression": True, "forceSynchronousLayout": False}
        gui.write_json(fixture, scenario)
        manifest = launch_manifest()
        manifest.update(guiTestHost=True, runRoot=str(root))
        manifest["build"].update(configuration="debug", optimization="-Onone")
        manifest["fixture"]["sha256"] = browsing_provenance.sha256_file(fixture)
        workload = {key: value for key, value in scenario.items() if key != "forceSynchronousLayout"}
        manifest["fixture"]["workloadSHA256"] = gui.hashlib.sha256(
            json.dumps(workload, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        names = gui.FIXTURES["gui-signed-out" if signed_out else "gui-shell"]
        directory = root / "shell-captures"
        directory.mkdir()
        def chunk(kind, data):
            return gui.struct.pack(">I", len(data)) + kind + data + gui.struct.pack(">I", gui.zlib.crc32(kind + data))
        png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", gui.struct.pack(">IIBBBBB", 200, 200, 8, 2, 0, 0, 0))
               + chunk(b"IDAT", gui.zlib.compress((b"\0" + b"\0" * 600) * 200)) + chunk(b"IEND", b""))
        points = []
        for name in names:
            (directory / (name + ".png")).write_bytes(png)
            points.append({
                "name": name, "runID": manifest["runID"], "host": gui.HOST_ID,
                "sourceSHA256": manifest["source"]["sourceSHA256"],
                "buildProductSHA256": manifest["build"]["buildProductSHA256"],
                "playing": False, "commandCount": 0, "mutationAttempts": 0, "visible": True,
                "assertions": [{"name": key, "passed": True} for key in sorted(gui.required_assertions(name, signed_out))],
                "appActive": True, "keyWindow": name != "shell.inactive", "windowNumber": 12, "capturePointPixelScale": 2,
                "backingScale": 2, "windowFrame": {"width": 100, "height": 100},
                "captureContentRect": {"width": 100, "height": 100}, "requestedBodySize": {"width": 100, "height": 100},
                "pixelSamples": [{"name": key, "maximumRGB": 0, "meanRGB": 0, "minimumAlpha": 255, "pixelCount": 10, "pixelRect": {"x": 0, "y": 0, "width": 2, "height": 5}}
                                 for key in ("shell.home", "shell.search", "shell.history.back", "shell.history.forward")],
                "captures": [{"file": "shell-captures/" + name + ".png", "pixelWidth": 200, "pixelHeight": 200,
                              "source": "ScreenCaptureKit.currentProcess.own-window.12",
                              "byteCount": len(png),
                              "sha256": browsing_provenance.sha256_file(directory / (name + ".png"))}],
            })
        shell = {"launch": deepcopy(manifest), "host": gui.HOST_ID, "networkSandboxVerified": False,
                 "passed": True, "checkpoints": points}
        report = {"launch": deepcopy(manifest), "scenario": scenario, "shellRegression": shell,
                  "networkSandboxVerified": False, "passed": True,
                  "world": {"mutationAttempts": 0, "requests": {}}, "playback": {"commandCount": 0, "playing": False}}
        owned = {"pid": 42, "startIdentity": "Thu Oct 1 12:00:00 2026",
                 "executable": str(root / "host.app/Contents/MacOS/SpottyDemo")}
        status = {"runID": manifest["runID"], "pid": 42, "state": "workload-finished",
                  "syntheticDependencies": True, "engineUsedForPlayback": False,
                  "networkSandboxVerified": False, "commandCount": 0, "mutationAttempts": 0}
        gui.write_json(root / "manifest.json", manifest)
        self.write_reports(root, report, shell, status)
        return manifest, fixture, owned, names, report, shell, status

    def write_reports(self, root, report, shell, status):
        gui.write_json(root / "report.json", report)
        gui.write_json(root / "shell-regression.json", shell)
        gui.write_json(root / "run-status.json", status)

    def test_complete_fixture_reports_pass_and_bind_all_checkpoint_identity(self):
        for signed_out in (False, True):
            with self.subTest(signed_out=signed_out), TemporaryDirectory() as directory:
                root = Path(directory)
                manifest, fixture, owned, names, *_ = self.fixture(root, signed_out)
                result = gui.validate_reports(root, manifest, fixture, owned, names)
                self.assertTrue(result["passed"])
                self.assertEqual(result["checkpointCount"], 4 if signed_out else 8)

    def test_stale_or_mismatched_reports_and_incomplete_assertions_fail(self):
        changes = (
            lambda report, shell, status: report["launch"].update(runID="stale-run"),
            lambda report, shell, status: shell["launch"]["source"].update(sourceSHA256="e" * 64),
            lambda report, shell, status: shell["launch"]["fixture"].update(sha256="e" * 64),
            lambda report, shell, status: shell["checkpoints"][0].update(host="dev.spotty.demo"),
            lambda report, shell, status: shell["checkpoints"][0].update(runID="stale-run"),
            lambda report, shell, status: shell["checkpoints"][0].update(assertions=[]),
            lambda report, shell, status: shell["checkpoints"][0]["assertions"][0].update(passed=False),
            lambda report, shell, status: shell.update(checkpoints=[]),
            lambda report, shell, status: shell["checkpoints"].pop(),
            lambda report, shell, status: report["playback"].update(playing=True),
            lambda report, shell, status: report["world"].update(mutationAttempts=1),
            lambda report, shell, status: shell["checkpoints"][0].update(commandCount=1),
            lambda report, shell, status: shell.update(networkSandboxVerified=True),
            lambda report, shell, status: status.update(pid=999),
            lambda report, shell, status: shell["checkpoints"][0]["assertions"].pop(),
            lambda report, shell, status: shell["checkpoints"][0]["pixelSamples"][0].update(maximumRGB=13),
            lambda report, shell, status: shell["checkpoints"][0]["captures"][0].update(source="NSView.cacheDisplay"),
            lambda report, shell, status: shell["checkpoints"].append("malformed"),
            lambda report, shell, status: shell["checkpoints"][0]["captures"][0].update(sha256="bad"),
        )
        for change in changes:
            with self.subTest(change=change), TemporaryDirectory() as directory:
                root = Path(directory)
                manifest, fixture, owned, names, report, shell, status = self.fixture(root)
                change(report, shell, status)
                self.write_reports(root, report, shell, status)
                with self.assertRaises(ValueError):
                    gui.validate_reports(root, manifest, fixture, owned, names)

    def test_provenance_timeout_terminates_only_its_own_group_once(self):
        process = Mock(pid=81)
        process.communicate.side_effect = subprocess.TimeoutExpired("provenance", 3)
        process.poll.return_value = None
        with (
            patch.object(gui.subprocess, "Popen", return_value=process) as launch,
            patch.object(gui.os, "killpg") as kill,
            patch.object(gui, "remaining", return_value=3),
            self.assertRaises(subprocess.TimeoutExpired),
        ):
            gui.metadata(Path("/synthetic"), 300, "snapshot")
        launch.assert_called_once()
        self.assertTrue(launch.call_args.kwargs["start_new_session"])
        process.communicate.assert_called_once_with(timeout=3)
        self.assertEqual(kill.call_args_list, [unittest.mock.call(81, gui.signal.SIGTERM),
                                                unittest.mock.call(81, gui.signal.SIGKILL)])
        self.assertEqual(process.wait.call_count, 2)

    def test_exited_provenance_leader_still_retires_open_pipe_descendants(self):
        process = Mock(pid=81, returncode=0)
        process.poll.return_value = 0
        process.communicate.side_effect = subprocess.TimeoutExpired("descendant pipe", 3)
        with (
            patch.object(gui.subprocess, "Popen", return_value=process) as launch,
            patch.object(gui.os, "killpg") as kill,
            patch.object(gui, "remaining", return_value=3),
            self.assertRaises(subprocess.TimeoutExpired),
        ):
            gui.metadata(Path("/synthetic"), 300, "source")
        launch.assert_called_once()
        self.assertEqual(kill.call_args_list, [unittest.mock.call(81, gui.signal.SIGTERM),
                                               unittest.mock.call(81, gui.signal.SIGKILL)])

    def test_corrupt_png_header_dimension_and_roi_fail_closed(self):
        for problem in ("garbage", "dimensions", "bounds", "count"):
            with self.subTest(problem=problem), TemporaryDirectory() as directory:
                root = Path(directory)
                manifest, fixture, owned, names, report, shell, status = self.fixture(root)
                point = shell["checkpoints"][0]
                capture = point["captures"][0]
                if problem == "garbage":
                    image = root / capture["file"]
                    image.write_bytes(b"synthetic image")
                    capture.update(byteCount=image.stat().st_size, sha256=browsing_provenance.sha256_file(image))
                elif problem == "dimensions":
                    capture["pixelWidth"] = 1
                elif problem == "bounds":
                    point["pixelSamples"][0]["pixelRect"]["x"] = 200
                else:
                    point["pixelSamples"][0]["pixelCount"] = 11
                self.write_reports(root, report, shell, status)
                with self.assertRaises(ValueError):
                    gui.validate_reports(root, manifest, fixture, owned, names)

    def test_transparent_black_chrome_sample_is_rejected(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            manifest, fixture, owned, names, report, shell, status = self.fixture(root)
            shell["checkpoints"][0]["pixelSamples"][0]["minimumAlpha"] = 0
            self.write_reports(root, report, shell, status)
            with self.assertRaisesRegex(ValueError, "opaque chrome padding"):
                gui.validate_reports(root, manifest, fixture, owned, names)

    def test_wrong_expected_head_and_source_change_fail_before_build(self):
        source = {"revision": "a" * 40, "sourceSHA256": "b" * 64}
        with patch.object(gui.browsing_provenance, "source_identity", return_value=source):
            with self.assertRaisesRegex(ValueError, "expected head"):
                gui.stable_source(Path("/synthetic"), source, "f" * 40)
            with self.assertRaisesRegex(ValueError, "source changed"):
                gui.stable_source(Path("/synthetic"), {**source, "sourceSHA256": "f" * 64})

    def test_no_gui_timeout_is_one_attempt_and_retires_exact_owned_host(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = launch_manifest()
            gui.write_json(root / "manifest.json", manifest)
            executable = root / "unique.app/Contents/MacOS/SpottyDemo"
            owned = {"pid": 42, "startIdentity": "Thu Oct 1 12:00:00 2026", "executable": str(executable)}
            process = Mock(pid=91)
            process.wait.return_value = 0
            process.poll.return_value = None
            with (
                patch.object(gui.subprocess, "Popen", return_value=process) as launch,
                patch.object(gui.browsing_process, "discover", return_value=owned) as discover,
                patch.object(gui.browsing_process, "terminate") as terminate,
                patch.object(gui.time, "monotonic", side_effect=[0, 91]),
                patch.object(gui, "remaining", return_value=10),
                patch.object(gui.browsing_process, "matches", return_value=True),
                self.assertRaisesRegex(TimeoutError, "GUI may be unavailable"),
            ):
                gui.run_host(root, root, executable, manifest, root / "fixture.json", (), 300)
            launch.assert_called_once()
            self.assertEqual(launch.call_args.args[0], ["/usr/bin/open", "-W", "-n",
                             "--stdout", str(root / "runtime.stdout.log"),
                             "--stderr", str(root / "runtime.stderr.log"), str(executable.parent.parent.parent)])
            self.assertTrue(launch.call_args.kwargs["start_new_session"])
            discover.assert_called_once_with(executable, timeout=10)
            terminate.assert_called_once_with(owned)
            process.wait.assert_called_once_with(timeout=2)
            evidence = gui.read_json(root / "gui-evidence.json")
            self.assertFalse(evidence["passed"])
            self.assertEqual(evidence["openWrapperPID"], 91)
            self.assertEqual(evidence["ownedAppPID"], 42)
            self.assertIn("90-second", evidence["failure"])
            self.assertEqual(gui.read_json(root / "process.json")["runID"], manifest["runID"])

    def test_failed_validation_retains_original_partial_report_and_owned_cleanup(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = launch_manifest()
            gui.write_json(root / "manifest.json", manifest)
            executable = root / "unique.app/Contents/MacOS/SpottyDemo"
            owned = {"pid": 42, "startIdentity": "Thu Oct 1 12:00:00 2026", "executable": str(executable)}
            process = Mock(pid=91)
            process.wait.return_value = 0
            process.poll.return_value = None
            original = b'{"passed":true,"checkpoints":["home.default"]}'

            def launch_host(*args, **kwargs):
                (root / "report.json").write_bytes(original)
                gui.write_json(root / "run-status.json", {"state": "workload-finished"})
                return process

            with (
                patch.object(gui.subprocess, "Popen", side_effect=launch_host) as launch,
                patch.object(gui.browsing_process, "discover", return_value=owned),
                patch.object(gui.browsing_process, "terminate") as terminate,
                patch.object(gui, "validate_reports", side_effect=ValueError("missing checkpoint")),
                self.assertRaisesRegex(ValueError, "missing checkpoint"),
            ):
                gui.run_host(root, root, executable, manifest, root / "fixture.json", (), gui.time.monotonic() + 300)
            self.assertEqual((root / "report.json").read_bytes(), original)
            launch.assert_called_once()
            terminate.assert_called_once_with(owned)
            self.assertFalse(gui.read_json(root / "gui-evidence.json")["passed"])

    def test_failed_workload_report_does_not_wait_out_the_gui_deadline(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = launch_manifest()
            gui.write_json(root / "manifest.json", manifest)
            executable = root / "unique.app/Contents/MacOS/SpottyDemo"
            owned = {"pid": 42, "startIdentity": "Thu Oct 1 12:00:00 2026", "executable": str(executable)}
            process = Mock(pid=91)
            process.wait.return_value = 0

            def launch_host(*args, **kwargs):
                gui.write_json(root / "report.json", {"passed": False, "failure": "capture.own-window"})
                gui.write_json(root / "run-status.json", {"state": "failed"})
                return process

            with (
                patch.object(gui.subprocess, "Popen", side_effect=launch_host) as launch,
                patch.object(gui.browsing_process, "discover", return_value=owned),
                patch.object(gui.browsing_process, "terminate") as terminate,
                patch.object(gui.time, "sleep") as sleep,
                self.assertRaisesRegex(RuntimeError, "capture.own-window"),
            ):
                gui.run_host(root, root, executable, manifest, root / "fixture.json", (), gui.time.monotonic() + 300)
            launch.assert_called_once()
            terminate.assert_called_once_with(owned)
            sleep.assert_not_called()
            evidence = gui.read_json(root / "gui-evidence.json")
            self.assertIn("report.json", evidence["artifacts"])
            self.assertIn("capture.own-window", evidence["failure"])

    def test_failed_discovery_never_signals_an_unverified_app_and_reaps_wrapper(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            process = Mock(pid=91)
            process.wait.return_value = 0
            process.wait.side_effect = [subprocess.TimeoutExpired("open", 2), 0, 0]
            with (
                patch.object(gui.subprocess, "Popen", return_value=process) as launch,
                patch.object(gui.browsing_process, "discover", side_effect=RuntimeError("No exact app found")) as discover,
                patch.object(gui.browsing_process, "terminate") as app_terminate,
                patch.object(gui.os, "killpg") as kill,
                self.assertRaisesRegex(RuntimeError, "No exact app found"),
            ):
                gui.run_host(root, root, root / "unique.app/Contents/MacOS/SpottyDemo", launch_manifest(),
                             root / "fixture.json", (), gui.time.monotonic() + 300)
            launch.assert_called_once()
            discover.assert_called_once()
            app_terminate.assert_not_called()
            self.assertEqual(kill.call_args_list, [unittest.mock.call(91, gui.signal.SIGTERM),
                                                   unittest.mock.call(91, gui.signal.SIGKILL)])
            evidence = gui.read_json(root / "gui-evidence.json")
            self.assertFalse(evidence["passed"])
            self.assertTrue(evidence["appRetirementUnverified"])
            self.assertNotIn("ownedAppPID", evidence)
            self.assertEqual(evidence["openWrapperCleanup"], "owned wrapper reaped")

    def test_stale_output_rejects_launch_and_cleanup(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "report.json").write_text("prior success")
            with patch.object(gui.subprocess, "Popen") as launch, patch.object(gui.browsing_process, "terminate") as terminate:
                with self.assertRaisesRegex(ValueError, "fresh GUI"):
                    gui.run_host(root, root, root / "host", launch_manifest(), root / "fixture", (), 300)
            launch.assert_not_called()
            terminate.assert_not_called()
            with self.assertRaises(FileExistsError):
                gui.execute(root, root)

    def test_early_failure_and_trailing_source_change_are_retained(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "new-output"
            snapshot = {"source": {"revision": "a" * 40}}
            with (
                patch.object(gui, "metadata", return_value=snapshot),
                patch.object(gui, "stable_source", side_effect=[snapshot["source"], ValueError("source changed")]),
                patch.object(gui, "build", side_effect=RuntimeError("build failed")) as build,
            ):
                self.assertEqual(gui.execute(root, output), 1)
            build.assert_called_once()
            summary = gui.read_json(output / "summary.json")
            self.assertFalse(summary["passed"])
            self.assertFalse(summary["sourceStable"])
            self.assertEqual(summary["failure"], "build failed")
            self.assertEqual(summary["trailingFailure"], "source changed")
            self.assertEqual((output / "failure.log").read_text(), "build failed\n")


if __name__ == "__main__":
    unittest.main()
