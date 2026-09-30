"""Exercise timing I/O and shell behavior without a compiler or mandatory benchmark."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "Scripts/ci_timings.py"
HELPER = ROOT / "Scripts/ci-timings.sh"
spec = importlib.util.spec_from_file_location("ci_timings", SCRIPT)
timings = importlib.util.module_from_spec(spec)
spec.loader.exec_module(timings)


class TimingRecordTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.report = self.root / "nested/phase-times.jsonl"

    def start(self):
        return f"{time.monotonic_ns()}:{time.time_ns()}"

    def rows(self):
        return [json.loads(line) for line in self.report.read_text().splitlines()]

    def test_compact_appends_preserve_previous_rows_and_omit_commands_environment(self):
        previous = {"previous": True}
        self.report.parent.mkdir()
        self.report.write_text(json.dumps(previous) + "\n")
        timings.append_record(self.report, phase="swift.artifact.resolve", start=self.start(), status=17)
        rows = self.rows()
        self.assertEqual(rows[0], previous)
        self.assertEqual(rows[1]["phase"], "swift.artifact.resolve")
        self.assertEqual(rows[1]["status"], 17)
        self.assertGreaterEqual(rows[1]["elapsed_seconds"], 0)
        self.assertEqual(set(rows[1]), {"schema_version", "phase", "started_at_unix_seconds",
                                        "elapsed_seconds", "status"})

    def test_independent_recorders_append_complete_rows(self):
        processes = [subprocess.Popen([
            sys.executable, str(SCRIPT), "record", "--report", str(self.report),
            "--phase", f"parallel-{index}", "--start", self.start(), "--status", "0",
        ], stdout=subprocess.PIPE, stderr=subprocess.PIPE) for index in range(8)]
        for process in processes:
            stdout, stderr = process.communicate(timeout=10)
            self.assertEqual((process.returncode, stdout, stderr), (0, b"", b""))
        self.assertEqual({row["phase"] for row in self.rows()},
                         {f"parallel-{index}" for index in range(8)})

    def write_events(self, records):
        path = self.root / "events.jsonl"
        path.write_text("".join(json.dumps(record) + "\n" for record in records))
        return path

    def event(self, kind, instant):
        return {"kind": "event", "payload": {"kind": kind, "instant": {"absolute": instant}}}

    def test_swift_build_summary_and_complete_native_runs_have_explicit_attribution(self):
        log = self.root / "tests.log"
        log.write_text("planning details\nBuild complete! (1.25 secs.)\nBuild complete! (0.50 secs.)\n")
        events = self.write_events([
            {"kind": "test", "payload": {"kind": "function", "id": "test-one"}},
            self.event("runStarted", 10),
            {"kind": "event", "payload": {"kind": "testEnded", "testID": "test-one"}},
            self.event("runEnded", 12),
            self.event("runStarted", 13), self.event("runEnded", 16),
        ])
        timings.append_record(self.report, phase="swift.tests.debug.repeat-1", start=self.start(),
                              status=0, log_path=log, event_path=events)
        row = self.rows()[0]
        self.assertEqual(row["test_build_seconds"], 1.75)
        self.assertEqual(row["native_execution_seconds"], 5)
        self.assertEqual(row["native_completed_runs"], 2)
        self.assertEqual(row["native_completed_test_functions"], 1)
        self.assertTrue(row["native_events_complete"])
        self.assertEqual(row["watchdog_log"], str(log))
        self.assertEqual(row["native_events"], str(events))

    def test_actual_swift_633_and_64_build_summary_formats(self):
        log = self.root / "tests.log"
        for summary, seconds in (("Build complete! (117.03s)", 117.03),
                                 ("Build complete! (3.22 secs.)", 3.22)):
            with self.subTest(summary=summary):
                log.write_text(summary + "\n")
                observations = timings.test_observations(log, None)
                self.assertEqual(observations["test_build_seconds"], seconds)

    def test_partial_invalid_or_missing_native_events_never_imply_complete_execution(self):
        events = self.write_events([self.event("runStarted", 10), self.event("runEnded", 12),
                                    self.event("runStarted", 13)])
        with events.open("a") as stream:
            stream.write('{"unfinished":')
        observations = timings.test_observations(None, events)
        self.assertFalse(observations["native_events_complete"])
        self.assertEqual(observations["native_execution_seconds"], 2)
        self.assertEqual(observations["native_completed_runs"], 1)
        missing = timings.test_observations(None, self.root / "missing.jsonl")
        self.assertFalse(missing["native_events_available"])
        self.assertNotIn("native_execution_seconds", missing)

    def test_report_failure_is_small_and_does_not_expose_input(self):
        blocker = self.root / "file"
        blocker.write_text("occupied")
        result = subprocess.run([
            sys.executable, str(SCRIPT), "record", "--report", str(blocker / "secret.jsonl"),
            "--phase", "swift.format", "--start", self.start(), "--status", "23",
        ], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "ci-timings: timing report unavailable\n")


class ShellTimingTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        scripts = self.root / "Scripts"
        scripts.mkdir()
        shutil.copy(HELPER, scripts)
        shutil.copy(SCRIPT, scripts)
        self.report = self.root / "timings.jsonl"

    def run_shell(self, shell, body, *, enabled=True, report=None):
        environment = {**os.environ, "project_root": str(self.root)}
        environment.pop("SPOTTY_CI_TIMINGS_REPORT", None)
        if enabled:
            environment["SPOTTY_CI_TIMINGS_REPORT"] = str(report or self.report)
        script = ('set -euo pipefail\nsource "$project_root/Scripts/ci-timings.sh"\n'
                  'trap \'spotty_ci_timings_finish "$?"\' EXIT\n'
                  'if [[ -n "${ZSH_VERSION:-}" ]]; then\n'
                  'trap \'spotty_ci_timings_finish "$?"\' ZERR\nfi\n' + body)
        return subprocess.run([shell, "-c", script], env=environment,
                              capture_output=True, text=True, timeout=10)

    def shells(self):
        return [shell for name in ("bash", "zsh") if (shell := shutil.which(name))]

    def test_disabled_spans_do_not_launch_python_or_touch_output(self):
        (self.root / "Scripts/ci_timings.py").unlink()
        for shell in self.shells():
            with self.subTest(shell=shell):
                result = self.run_shell(shell, 'spotty_ci_timings_start phase\necho actual-output\n'
                                        'spotty_ci_timings_finish 0\n', enabled=False)
                self.assertEqual((result.returncode, result.stdout, result.stderr),
                                 (0, "actual-output\n", ""))
                self.assertFalse(self.report.exists())

    def test_shell_owned_function_failure_short_circuits_once_and_records_original_status(self):
        for shell in self.shells():
            with self.subTest(shell=shell):
                self.report.unlink(missing_ok=True)
                result = self.run_shell(shell, '''
owned_phase() { echo first-attempt; (exit 37); echo forbidden-after-failure; }
spotty_ci_timings_start phase
owned_phase
spotty_ci_timings_finish 0
''')
                self.assertEqual((result.returncode, result.stdout, result.stderr),
                                 (37, "first-attempt\n", ""))
                rows = [json.loads(line) for line in self.report.read_text().splitlines()]
                self.assertEqual(len(rows), 1)
                self.assertEqual(rows[0]["status"], 37)

    def test_command_substitution_output_and_cleanup_trap_are_preserved(self):
        for shell in self.shells():
            with self.subTest(shell=shell):
                self.report.unlink(missing_ok=True)
                result = self.run_shell(shell, '''
trap 'spotty_ci_timings_finish "$?"; echo cleanup >&2' EXIT
owner() { printf 'selected-framework'; }
spotty_ci_timings_start artifact-resolve
selected="$(owner)"
spotty_ci_timings_finish 0
printf '%s\\n' "$selected"
''')
                self.assertEqual((result.returncode, result.stdout, result.stderr),
                                 (0, "selected-framework\n", "cleanup\n"))
                rows = self.report.read_text().splitlines()
                self.assertEqual(len(rows), 1)

    def test_captured_function_failure_keeps_stdout_status_and_one_owner_record(self):
        for shell in self.shells():
            with self.subTest(shell=shell):
                self.report.unlink(missing_ok=True)
                result = self.run_shell(shell, '''
owner() { printf 'captured-output'; return 37; }
spotty_ci_timings_start captured-function
selected="$(owner)"
printf 'forbidden-after-failure\\n'
''')
                self.assertEqual((result.returncode, result.stdout, result.stderr), (37, "", ""))
                rows = [json.loads(line) for line in self.report.read_text().splitlines()]
                self.assertEqual(len(rows), 1)
                self.assertEqual(rows[0]["status"], 37)

    def test_timing_io_failure_does_not_replace_command_failure(self):
        blocker = self.root / "occupied"
        blocker.write_text("file")
        for shell in self.shells():
            with self.subTest(shell=shell):
                result = self.run_shell(shell, 'spotty_ci_timings_start phase\n(exit 29)\n',
                                        report=blocker / "timings.jsonl")
                self.assertEqual(result.returncode, 29)
                self.assertEqual(result.stdout, "")
                self.assertEqual(result.stderr, "ci-timings: timing report unavailable\n")

    @unittest.skipUnless(shutil.which("zsh"), "Release entry point requires zsh")
    def test_release_captured_resolver_failure_records_original_status_once(self):
        scripts = self.root / "Scripts"
        shutil.copy(ROOT / "Scripts/compile-release-spotty.sh", scripts)
        (scripts / "swiftpm-env.sh").write_text("# Toolchain-free environment fixture\n")
        (scripts / "playback-xcframework.sh").write_text(
            "spotty_playback_resolve_xcframework() { printf 'captured-artifact'; return 37; }\n")
        result = subprocess.run([shutil.which("zsh"), str(scripts / "compile-release-spotty.sh")],
                                env={**os.environ, "SPOTTY_CI_TIMINGS_REPORT": str(self.report)},
                                capture_output=True, text=True, timeout=10)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (37, "", ""))
        rows = [json.loads(line) for line in self.report.read_text().splitlines()]
        resolution = [row for row in rows if row["phase"] == "release.artifact.resolve"]
        self.assertEqual(len(resolution), 1)
        self.assertEqual(resolution[0]["status"], 37)


@unittest.skipUnless(shutil.which("zsh"), "playback build entry point requires zsh")
class CargoTimingFlagTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.backend = self.root / "Backend/spotty-playback"
        self.backend.mkdir(parents=True)
        shutil.copy(ROOT / "Backend/spotty-playback/build.sh", self.backend)
        (self.backend / "macos-deployment-target").write_text("26.0\n")
        self.cargo = self.root / "cargo-fixture"
        self.cargo.write_text(f'''#!{sys.executable}
import json, os, pathlib, sys
with pathlib.Path("cargo-calls.jsonl").open("a") as output:
    output.write(json.dumps(sys.argv[1:]) + "\\n")
if int(os.environ.get("FIXTURE_CARGO_STATUS", "0")):
    sys.exit(int(os.environ["FIXTURE_CARGO_STATUS"]))
archive = pathlib.Path("target/aarch64-apple-darwin/release/libspotty_playback.a")
archive.parent.mkdir(parents=True, exist_ok=True)
archive.write_bytes(b"fixture archive")
''')
        self.cargo.chmod(0o755)

    def run_build(self, *, enabled, status=0):
        environment = {**os.environ, "SPOTTY_CARGO": str(self.cargo),
                       "FIXTURE_CARGO_STATUS": str(status)}
        for name in ("RUSTFLAGS", "CARGO_ENCODED_RUSTFLAGS", "RUSTC_WRAPPER",
                     "RUSTC_WORKSPACE_WRAPPER", "MACOSX_DEPLOYMENT_TARGET",
                     "SPOTTY_CI_TIMINGS_REPORT"):
            environment.pop(name, None)
        if enabled:
            environment["SPOTTY_CI_TIMINGS_REPORT"] = str(self.root / "timings.jsonl")
        return subprocess.run([str(self.backend / "build.sh"), "--output", str(self.root / "output.a")],
                              env=environment, capture_output=True, text=True, timeout=10)

    def test_opt_in_retains_exact_locked_release_target_flags(self):
        expected = ["build", "--release", "--locked", "--target", "aarch64-apple-darwin"]
        for enabled in (False, True):
            with self.subTest(enabled=enabled):
                calls = self.backend / "cargo-calls.jsonl"
                calls.unlink(missing_ok=True)
                result = self.run_build(enabled=enabled)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual([json.loads(line) for line in calls.read_text().splitlines()],
                                 [expected + (["--timings"] if enabled else [])])
                self.assertEqual((self.root / "output.a").read_bytes(), b"fixture archive")

    def test_failed_cargo_is_not_retried_or_copied(self):
        result = self.run_build(enabled=True, status=41)
        self.assertEqual(result.returncode, 41, result.stderr)
        self.assertEqual(len((self.backend / "cargo-calls.jsonl").read_text().splitlines()), 1)
        self.assertFalse((self.root / "output.a").exists())


if __name__ == "__main__":
    unittest.main()
