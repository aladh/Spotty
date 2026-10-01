"""Failure sensitivity and exact ownership of the synthetic GUI runner; no GUI is launched."""
from copy import deepcopy
from functools import lru_cache
import json
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import Mock, patch

import browsing_provenance
import gui_regression as gui
from harness_fixtures import launch_manifest


@lru_cache(maxsize=8)
def fixture_png(width, height):
    def chunk(kind, data):
        return gui.struct.pack(">I", len(data)) + kind + data + gui.struct.pack(">I", gui.zlib.crc32(kind + data))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", gui.struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", gui.zlib.compress((b"\0" + b"\0" * (width * 3)) * height)) + chunk(b"IEND", b""))


class GUIRegressionChecks(unittest.TestCase):
    def fixture(self, root, signed_out=False, screen_size=(1920, 1080)):
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
        points = []
        for name in names:
            desired = gui.desired_body_size(name)
            target = {"width": min(desired["width"], gui.math.floor(screen_size[0])),
                      "height": min(desired["height"], gui.math.floor(screen_size[1] - 100))}
            width, height = target["width"], target["height"]
            png = fixture_png(width * 2, (height + 100) * 2)
            (directory / (name + ".png")).write_bytes(png)
            points.append({
                "name": name, "runID": manifest["runID"], "host": gui.HOST_ID,
                "sourceSHA256": manifest["source"]["sourceSHA256"],
                "buildProductSHA256": manifest["build"]["buildProductSHA256"],
                "playing": False, "commandCount": 0, "mutationAttempts": 0, "visible": True,
                "assertions": [{"name": key, "passed": True} for key in sorted(gui.required_assertions(name, signed_out))],
                "appActive": True, "keyWindow": name != "shell.inactive", "windowNumber": 12, "capturePointPixelScale": 2,
                "backingScale": 2, "windowFrame": {"x": -1920 + min(8, screen_size[0] - width),
                                                    "y": -300 + min(8, screen_size[1] - height - 100),
                                                    "width": width, "height": height + 100},
                "captureContentRect": {"x": 0, "y": 0, "width": width, "height": height + 100},
                "desiredBodySize": {"x": 0, "y": 0, **desired},
                "screenVisibleFrame": {"x": -1920, "y": -300, "width": screen_size[0], "height": screen_size[1]},
                "frameToBodyOverhead": {"x": 0, "y": 0, "width": 0, "height": 100},
                "requestedBodySize": {"x": 0, "y": 0, **target},
                "contentLayoutRect": {"x": 0, "y": 0, **target},
                "contentBounds": {"x": 0, "y": 0, "width": width, "height": height + 60},
                "pixelSamples": [{"name": key, "maximumRGB": 0, "meanRGB": 0, "minimumAlpha": 255, "pixelCount": 10, "pixelRect": {"x": 0, "y": 0, "width": 2, "height": 5}}
                                 for key in ("shell.home", "shell.search", "shell.history.back", "shell.history.forward")],
                "captures": [{"file": "shell-captures/" + name + ".png", "pixelWidth": width * 2, "pixelHeight": (height + 100) * 2,
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
        process.wait.side_effect = [subprocess.TimeoutExpired("TERM wait", 2), 0]
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
        self.assertEqual(process.wait.call_args_list, [unittest.mock.call(timeout=2), unittest.mock.call(timeout=2)])

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
                    point["pixelSamples"][0]["pixelRect"]["x"] = capture["pixelWidth"]
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

    def test_timeout_primary_survives_unverified_command_retirement(self):
        for owner in ("metadata", "bounded_command"):
            with self.subTest(owner=owner), TemporaryDirectory() as directory:
                process = Mock(pid=81)
                primary = subprocess.TimeoutExpired("primary operation", 3)
                process.communicate.side_effect = primary
                process.wait.side_effect = subprocess.TimeoutExpired("cleanup wait", 2)
                with (
                    patch.object(gui.subprocess, "Popen", return_value=process),
                    patch.object(gui.os, "killpg"),
                    patch.object(gui, "remaining", return_value=3),
                    self.assertRaises(subprocess.TimeoutExpired) as failed,
                ):
                    if owner == "metadata":
                        gui.metadata(Path(directory), 300, "source")
                    else:
                        process.wait.side_effect = [primary, subprocess.TimeoutExpired("term", 2),
                                                    subprocess.TimeoutExpired("kill", 2)]
                        gui.bounded_command(["synthetic"], Path(directory), Path(directory) / "command.log", 300)
                self.assertIs(failed.exception, primary)
                self.assertFalse(primary.cleanupFailure["verified"])
                self.assertEqual(primary.cleanupFailure["pid"], 81)
                self.assertEqual(len(primary.cleanupFailure["failures"]), 1)
                self.assertEqual(process.wait.call_count, 2 if owner == "metadata" else 3)

    def test_summary_retains_primary_timeout_and_unverified_retirement(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            snapshot = {"source": {"revision": "a" * 40}}
            primary = subprocess.TimeoutExpired("primary build", 3)
            primary.cleanupFailure = {"pid": 81, "verified": False, "failures": ["cleanup wait exceeded 2 seconds"]}
            with (
                patch.object(gui, "metadata", return_value=snapshot),
                patch.object(gui, "stable_source", return_value=snapshot["source"]),
                patch.object(gui, "build", side_effect=primary),
            ):
                self.assertEqual(gui.execute(root, root / "evidence"), 1)
            summary = gui.read_json(root / "evidence/summary.json")
            self.assertIn("primary build", summary["failure"])
            self.assertEqual(summary["cleanupFailure"], primary.cleanupFailure)
            self.assertFalse(summary["passed"])

    def test_display_target_admission_rejects_shrinkage_and_invalid_geometry(self):
        changes = (
            lambda point: point["desiredBodySize"].update(width=1000),
            lambda point: point["requestedBodySize"].update(width=1000),
            lambda point: point["screenVisibleFrame"].update(height=700),
            lambda point: point["screenVisibleFrame"].update(height=740),
            lambda point: point["screenVisibleFrame"].update(width=900),
            lambda point: point["screenVisibleFrame"].update(x=float("nan")),
            lambda point: point["frameToBodyOverhead"].update(width=-1),
            lambda point: point["frameToBodyOverhead"].update(height=float("inf")),
            lambda point: point["windowFrame"].update(x=0),
            lambda point: point["contentLayoutRect"].update(height=630),
        )
        for change in changes:
            with self.subTest(change=change), TemporaryDirectory() as directory:
                root = Path(directory)
                manifest, fixture, owned, names, report, shell, status = self.fixture(root)
                change(shell["checkpoints"][0])
                self.write_reports(root, report, shell, status)
                with self.assertRaises(ValueError):
                    gui.validate_reports(root, manifest, fixture, owned, names)
        with TemporaryDirectory() as directory:
            root = Path(directory)
            manifest, fixture, owned, names, report, shell, status = self.fixture(root, screen_size=(960, 740))
            with self.assertRaisesRegex(ValueError, "distinct size change"):
                gui.validate_reports(root, manifest, fixture, owned, names)

    def test_identical_observed_body_sizes_cannot_pass_tolerant_distinct_targets(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            manifest, fixture, owned, names, report, shell, status = self.fixture(root, screen_size=(963, 740))
            self.assertTrue(gui.validate_reports(root, manifest, fixture, owned, names)["passed"])
            minimum = next(point for point in shell["checkpoints"] if point["name"] == "home.minimum")
            resized = next(point for point in shell["checkpoints"] if point["name"] == "shell.resized")
            self.assertEqual(minimum["requestedBodySize"]["width"], 960)
            self.assertEqual(resized["requestedBodySize"]["width"], 963)
            minimum["contentBounds"]["width"] = 961
            resized["contentBounds"]["width"] = 961
            self.write_reports(root, report, shell, status)
            with self.assertRaisesRegex(ValueError, "observed body exercises a distinct size change"):
                gui.validate_reports(root, manifest, fixture, owned, names)

    def test_short_display_declared_width_only_resize_and_fractional_floor_pass(self):
        for screen_size in ((1440, 740), (1440, 770.7)):
            with self.subTest(screen_size=screen_size), TemporaryDirectory() as directory:
                root = Path(directory)
                manifest, fixture, owned, names, *_ = self.fixture(root, screen_size=screen_size)
                self.assertTrue(gui.validate_reports(root, manifest, fixture, owned, names)["passed"])

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

    def test_owned_app_exit_before_final_status_fails_without_waiting_deadline(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = launch_manifest()
            gui.write_json(root / "manifest.json", manifest)
            executable = root / "unique.app/Contents/MacOS/SpottyDemo"
            owned = {"pid": 42, "startIdentity": "Thu Oct 1 12:00:00 2026", "executable": str(executable)}
            process = Mock(pid=91)
            process.wait.return_value = 0

            def launch_host(*args, **kwargs):
                gui.write_json(root / "report.json", {"passed": True})
                gui.write_json(root / "run-status.json", {"state": "workload-running"})
                return process

            with (
                patch.object(gui.subprocess, "Popen", side_effect=launch_host) as launch,
                patch.object(gui.browsing_process, "discover", return_value=owned),
                patch.object(gui.browsing_process, "matches", return_value=False) as matches,
                patch.object(gui.browsing_process, "terminate") as terminate,
                patch.object(gui.time, "sleep") as sleep,
                self.assertRaisesRegex(RuntimeError, "exited before publishing final status"),
            ):
                gui.run_host(root, root, executable, manifest, root / "fixture.json", (), gui.time.monotonic() + 300)
            launch.assert_called_once()
            matches.assert_called_once_with(owned)
            terminate.assert_called_once_with(owned)
            sleep.assert_not_called()
            evidence = gui.read_json(root / "gui-evidence.json")
            self.assertFalse(evidence["passed"])
            self.assertIn("exited before publishing final status", evidence["failure"])

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

    hosted_environment = {"GITHUB_ACTIONS": "true", "CI": "true", "RUNNER_ENVIRONMENT": "github-hosted",
                          "RUNNER_OS": "macOS"}

    def display_report(self, pid=73):
        original = {"id": 1, "width": 1024, "height": 768, "pixelWidth": 1024, "pixelHeight": 768,
                    "refreshRate": 60, "desktopUsable": True}
        selected = {**original, "id": 2, "width": 1280, "height": 900, "pixelWidth": 1280, "pixelHeight": 900}
        def screen(width, height, visible_height):
            return {"displayID": 1, "backingScale": 1,
                    "frame": {"x": 0, "y": 0, "width": width, "height": height},
                    "visibleFrame": {"x": 0, "y": 60, "width": width, "height": visible_height}}
        return {"schemaVersion": 1, "ownerPID": pid, "displayID": 1, "phase": "ready",
                "originalMode": original, "selectedMode": selected, "observedMode": selected,
                "availableModes": [original, selected], "changed": True,
                "beforeScreens": [screen(1024, 768, 680)], "afterScreens": [screen(1280, 900, 800)]}

    def test_display_opt_in_refuses_local_and_self_hosted_before_build_or_launch(self):
        for environment in ({}, {**self.hosted_environment, "RUNNER_ENVIRONMENT": "self-hosted"}):
            with self.subTest(environment=environment), TemporaryDirectory() as directory:
                root = Path(directory)
                with (
                    patch.dict(gui.os.environ, environment, clear=True),
                    patch.object(gui, "metadata") as metadata,
                    patch.object(gui.subprocess, "Popen") as launch,
                ):
                    self.assertEqual(gui.execute(root, root / "output", qualify_hosted_display=True), 1)
                metadata.assert_not_called()
                launch.assert_not_called()
                summary = gui.read_json(root / "output/summary.json")
                self.assertIn("GitHub-hosted macOS CI", summary["failure"])
                self.assertFalse(summary["displayQualification"]["passed"])

    def test_display_admission_requires_advertised_logical_mode_and_visible_capacity(self):
        self.assertTrue(gui.validate_display_qualification(self.display_report(), 73)["passed"])
        mutations = (
            lambda report: report.update(ownerPID=99),
            lambda report: report.update(availableModes=[]),
            lambda report: report.update(availableModes=[report["originalMode"]]),
            lambda report: report["selectedMode"].update(width=1024),
            lambda report: report["selectedMode"].update(desktopUsable=False),
            lambda report: report["afterScreens"][0]["visibleFrame"].update(height=700),
            lambda report: report["afterScreens"][0]["frame"].update(width=1024),
        )
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                report = deepcopy(self.display_report())
                mutate(report)
                with self.assertRaises(ValueError):
                    gui.validate_display_qualification(report, 73)

    def test_no_advertised_mode_retains_initial_record_and_prevents_fixture_launch(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "output"
            snapshot = {"source": {"revision": "a" * 40}}
            process = Mock(pid=73)
            process.poll.return_value = None
            failure = self.display_report()
            failure.update(phase="failed", failure="No advertised desktop display mode provides at least 1280x900 logical points")
            failure["availableModes"] = [failure["originalMode"]]

            def launch_guardian(*args, **kwargs):
                gui.write_json(output / "hosted-display.json", failure)
                return process

            def inspect(*args, **kwargs):
                gui.write_json(output / "hosted-display-restored.json", {
                    "phase": "inspected", "displayID": 1, "originalMode": failure["originalMode"],
                    "beforeScreens": failure["beforeScreens"],
                })

            with (
                patch.dict(gui.os.environ, self.hosted_environment, clear=True),
                patch.object(gui, "metadata", return_value=snapshot),
                patch.object(gui, "stable_source", return_value=snapshot["source"]),
                patch.object(gui, "build", return_value=root / ".build/debug"),
                patch.object(gui, "compile_display_guardian", return_value=root / "guardian"),
                patch.object(gui.subprocess, "Popen", side_effect=launch_guardian) as launch,
                patch.object(gui, "bounded_command", side_effect=inspect) as inspect_command,
                patch.object(gui, "retire_command", return_value={"verified": True, "failures": []}) as retire,
                patch.object(gui, "assemble") as assemble,
                patch.object(gui, "run_host") as run_host,
            ):
                self.assertEqual(gui.execute(root, output, qualify_hosted_display=True), 1)
            launch.assert_called_once()
            retire.assert_called_once_with(process)
            assemble.assert_not_called()
            run_host.assert_not_called()
            self.assertEqual(gui.read_json(output / "hosted-display.json"), failure)
            summary = gui.read_json(output / "summary.json")
            self.assertIn("No advertised", summary["failure"])
            self.assertTrue(summary["displayRestoration"]["verified"])
            inspect_command.assert_called_once()

    def test_failed_readiness_after_mode_selection_records_post_exit_restoration_and_primary_error(self):
        for mismatch in (False, True):
            with self.subTest(mismatch=mismatch), TemporaryDirectory() as directory:
                root = Path(directory)
                output = root / "output"
                snapshot = {"source": {"revision": "a" * 40}}
                process = Mock(pid=73)
                process.poll.return_value = None
                failed = self.display_report()
                failed.update(phase="failed", failure="AppKit geometry did not stabilize", changed=True)

                def launch(*args, **kwargs):
                    gui.write_json(output / "hosted-display.json", failed)
                    return process

                def inspect(*args, **kwargs):
                    post = {"phase": "inspected", "displayID": 1, "originalMode": deepcopy(failed["originalMode"]),
                            "beforeScreens": deepcopy(failed["beforeScreens"])}
                    if mismatch:
                        post["originalMode"]["id"] = 99
                    gui.write_json(output / "hosted-display-restored.json", post)

                with (
                    patch.dict(gui.os.environ, self.hosted_environment, clear=True),
                    patch.object(gui, "metadata", return_value=snapshot),
                    patch.object(gui, "stable_source", return_value=snapshot["source"]),
                    patch.object(gui, "build", return_value=root / ".build/debug"),
                    patch.object(gui, "compile_display_guardian", return_value=root / "guardian"),
                    patch.object(gui.subprocess, "Popen", side_effect=launch) as launched,
                    patch.object(gui, "bounded_command", side_effect=inspect) as inspected,
                    patch.object(gui, "retire_command", return_value={"verified": True, "failures": []}) as retire,
                    patch.object(gui, "assemble") as assemble,
                ):
                    self.assertEqual(gui.execute(root, output, qualify_hosted_display=True), 1)
                launched.assert_called_once()
                retire.assert_called_once_with(process)
                inspected.assert_called_once()
                self.assertEqual(inspected.call_args.args[0][1], "--inspect")
                assemble.assert_not_called()
                self.assertEqual(gui.read_json(output / "hosted-display.json"), failed)
                summary = gui.read_json(output / "summary.json")
                self.assertEqual(summary["failure"], "Display qualification failed: AppKit geometry did not stabilize")
                self.assertEqual(summary["displayRestoration"]["verified"], not mismatch)
                self.assertFalse(summary["passed"])
                if mismatch:
                    self.assertIn("post-exit", summary["displayRestorationFailure"])
                else:
                    self.assertNotIn("displayRestorationFailure", summary)

    def test_display_guardian_exit_aborts_owned_fixture_without_another_launch(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = launch_manifest()
            gui.write_json(root / "manifest.json", manifest)
            executable = root / "unique.app/Contents/MacOS/SpottyDemo"
            owned = {"pid": 42, "startIdentity": "Thu Oct 1 12:00:00 2026", "executable": str(executable)}
            guardian = Mock(pid=73)
            guardian.poll.side_effect = [None, 0]
            wrapper = Mock(pid=91)
            wrapper.wait.return_value = 0
            with (
                patch.object(gui.subprocess, "Popen", return_value=wrapper) as launch,
                patch.object(gui.browsing_process, "discover", return_value=owned),
                patch.object(gui.browsing_process, "terminate") as terminate,
                patch.object(gui.time, "sleep") as sleep,
                self.assertRaisesRegex(RuntimeError, "display guardian exited"),
            ):
                gui.run_host(root, root, executable, manifest, root / "fixture", (), gui.time.monotonic() + 300,
                             guardian=guardian)
            launch.assert_called_once()
            terminate.assert_called_once_with(owned)
            sleep.assert_not_called()
            self.assertIn("display guardian exited", gui.read_json(root / "gui-evidence.json")["failure"])

    def test_display_restoration_requires_post_owner_exit_inspection(self):
        for mismatch in (False, True):
            with self.subTest(mismatch=mismatch), TemporaryDirectory() as directory:
                root = Path(directory)
                process = Mock(pid=73)
                process.poll.return_value = None
                process.wait.return_value = 0
                report = self.display_report()
                report.update(phase="restored", restorationAttempted=True, restorationVerified=True,
                              restoredMode=report["originalMode"])
                gui.write_json(root / "hosted-display.json", report)

                def inspect(*args, **kwargs):
                    post = {"phase": "inspected", "displayID": 1, "originalMode": deepcopy(report["originalMode"]),
                            "beforeScreens": deepcopy(report["beforeScreens"])}
                    if mismatch:
                        post["originalMode"]["id"] = 99
                    gui.write_json(root / "hosted-display-restored.json", post)

                with (
                    patch.object(gui, "bounded_command", side_effect=inspect) as command,
                    patch.object(gui, "retire_command", return_value={"verified": True, "failures": []}) as retire,
                ):
                    restored = gui.restore_display_guardian(process, root, root, root / "guardian")
                self.assertEqual(restored["verified"], not mismatch)
                command.assert_called_once()
                self.assertEqual(command.call_args.args[0][1], "--inspect")
                process.stdin.write.assert_called_once_with("restore\n")
                if mismatch:
                    retire.assert_called_once_with(process)
                    self.assertIn("post-exit", restored["failure"])
                else:
                    retire.assert_not_called()

    def test_display_restoration_timeout_is_unverified_and_cannot_mask_fixture_failure(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            process = Mock(pid=73)
            process.poll.return_value = None
            process.wait.side_effect = subprocess.TimeoutExpired("guardian restoration", 5)
            with patch.object(gui, "retire_command", return_value={"verified": False, "failures": ["kill wait"]}) as retire:
                restoration = gui.restore_display_guardian(process, root, root, root / "guardian")
            retire.assert_called_once_with(process)
            self.assertFalse(restoration["verified"])
            self.assertFalse(restoration["ownedGuardianRetirement"]["verified"])
            self.assertIn("guardian restoration", restoration["failure"])

            snapshot = {"source": {"revision": "a" * 40}}
            guardian = Mock(pid=73)
            guardian.poll.return_value = None
            output = root / "output"
            def start(*args, **kwargs):
                gui.write_json(output / "hosted-display.json", self.display_report())
                return guardian
            with (
                patch.dict(gui.os.environ, self.hosted_environment, clear=True),
                patch.object(gui, "metadata", return_value=snapshot),
                patch.object(gui, "stable_source", return_value=snapshot["source"]),
                patch.object(gui, "build", return_value=root / ".build/debug"),
                patch.object(gui, "compile_display_guardian", return_value=root / "guardian"),
                patch.object(gui, "start_display_guardian", side_effect=start),
                patch.object(gui, "assemble", side_effect=RuntimeError("primary fixture failure")),
                patch.object(gui, "restore_display_guardian", return_value=restoration),
            ):
                self.assertEqual(gui.execute(root, output, qualify_hosted_display=True), 1)
            summary = gui.read_json(output / "summary.json")
            self.assertEqual(summary["failure"], "primary fixture failure")
            self.assertIn("guardian restoration", summary["displayRestorationFailure"])
            self.assertFalse(summary["displayRestoration"]["verified"])

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
