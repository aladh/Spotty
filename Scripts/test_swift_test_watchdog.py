import json
import os
from pathlib import Path
import resource
import signal
import subprocess
import sys
import tempfile
import time
import unittest


SCRIPT = Path(__file__).with_name("swift_test_watchdog.py")


class SwiftTestWatchdogTests(unittest.TestCase):
    def diagnostics(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        return Path(temporary.name)

    def arguments(self, command, diagnostics, timeout=2, require_tests=False):
        return [
            sys.executable, str(SCRIPT), "--lane", "fixture", "--repetition", "1",
            f"--timeout-seconds={timeout}", "--log-dir", str(diagnostics),
            *(["--require-tests"] if require_tests else []), "--", *command,
        ]

    def run_watchdog(self, command, timeout=2, env=None, diagnostics=None, preexec_fn=None, require_tests=False):
        diagnostics = diagnostics or self.diagnostics()
        result = subprocess.run(
            self.arguments(command, diagnostics, timeout, require_tests),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            env=env,
            timeout=10,
            preexec_fn=preexec_fn,
        )
        return result, diagnostics

    def test_required_execution_uses_completed_cases_across_all_products(self):
        positive = "✔ Test example() passed after 0.001 seconds."
        empty = "✔ Test run with 0 tests in 0 suites passed after 0.001 seconds."
        cases = [
            ("", 1),
            ("warning: No matching test cases were run", 1),
            (empty, 1),
            ("➜ Test example() skipped.\n✔ Test run with 1 test in 1 suite passed after 0.001 seconds.", 1),
            ("✔ Suite Examples passed after 0.001 seconds.", 1),
            ("◇ Test example() started.", 1),
            ("Executed 0 tests, with 0 failures (0 unexpected)", 1),
            (positive, 0),
            (positive + "\n" + empty, 0),
            (empty + "\n" + positive, 0),
            ("\x1b[32m" + positive + "\x1b[0m", 0),
            ("Executed 2 tests, with 0 failures (0 unexpected)", 1),
            ("Test Case '-[ExampleTests example]' skipped (0.001 seconds).", 1),
            ("Test Case '-[ExampleTests example]' passed (0.001 seconds).", 0),
            ("✔ Test example(value:) with 2 test cases passed after 0.001 seconds.", 0),
        ]
        for output, expected in cases:
            with self.subTest(output=output):
                result, _ = self.run_watchdog(
                    [sys.executable, "-c", f"print({output!r})"], require_tests=True)
                self.assertEqual(result.returncode, expected, result.stdout)
                if expected:
                    self.assertIn("no executed tests reported", result.stdout)

    def test_required_execution_preserves_command_failures(self):
        result, _ = self.run_watchdog(
            [sys.executable, "-c", "raise SystemExit(7)"], require_tests=True)
        self.assertEqual(result.returncode, 7, result.stdout)
        self.assertNotIn("no executed tests reported", result.stdout)

    def test_quiet_execution_requires_current_function_completion_events(self):
        function = {"kind": "test", "payload": {"kind": "function", "id": "example"}}
        suite = {"kind": "test", "payload": {"kind": "suite", "id": "suite"}}
        ended = {"kind": "event", "payload": {"kind": "testEnded", "testID": "example"}}
        suite_ended = {"kind": "event", "payload": {"kind": "testEnded", "testID": "suite"}}
        skipped = {"kind": "event", "payload": {"kind": "testSkipped", "testID": "example"}}
        for records, expected in (([function, ended], 0), ([suite, suite_ended], 1),
                                  ([function, skipped, suite, suite_ended], 1), ([ended], 1),
                                  ([suite, suite_ended, function, ended, suite_ended], 0), (None, 1)):
            with self.subTest(records=records):
                diagnostics = self.diagnostics()
                event_path = diagnostics / "fixture-repeat-1-events.jsonl"
                event_path.write_text("\n".join(json.dumps(item) for item in (function, ended)) + "\n")
                swift = diagnostics / "swift"
                data = None if records is None else "\n".join(json.dumps(item) for item in records) + "\n"
                swift.write_text(
                    f"#!{sys.executable}\nimport sys\nfrom pathlib import Path\n"
                    "if sys.argv[1:] == ['test', '--help-hidden']:\n"
                    "    print('--event-stream-output-path'); raise SystemExit(0)\n"
                    "path = Path(sys.argv[sys.argv.index('--event-stream-output-path') + 1])\n"
                    "assert not path.exists(), 'stale events must be removed before launching'\n"
                    f"data = {data!r}\n"
                    "if data is not None: path.write_text(data)\n"
                    "print('✔ Test run with 1 test passed after 0.001 seconds.')\n"
                )
                swift.chmod(0o755)
                result, _ = self.run_watchdog([str(swift), "test"], diagnostics=diagnostics, require_tests=True)
                self.assertEqual(result.returncode, expected, result.stdout)
                self.assertIn("event-stream=enabled", result.stdout)

    def sleeping_command(self, diagnostics, *, output=False, ignore_term=False):
        pid_path = diagnostics / "command.pid"

        def clean_fixture():
            if pid_path.exists():
                try:
                    os.killpg(int(pid_path.read_text()), signal.SIGKILL)
                except ProcessLookupError:
                    pass

        self.addCleanup(clean_fixture)
        handler = (
            "signal.signal(signal.SIGTERM, lambda *_: "
            f"pathlib.Path({str(diagnostics / 'cleanup-started')!r}).touch())\n"
        ) if ignore_term else ""
        program = (
            "import os,pathlib,signal,time\n"
            + handler
            + f"pathlib.Path({str(pid_path)!r}).write_text(str(os.getpid()))\n"
            "for _ in range(600):\n"
            "    time.sleep(0.1)\n"
            + ("    print('still running', flush=True)\n" if output else "")
        )
        return [sys.executable, "-c", program], pid_path

    def start_watchdog(self, command, diagnostics, timeout=30):
        process = subprocess.Popen(
            self.arguments(command, diagnostics, timeout),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )

        def stop():
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)

        self.addCleanup(process.stderr.close)
        self.addCleanup(process.stdout.close)
        self.addCleanup(stop)
        return process

    def wait_for_file(self, path, process):
        deadline = time.monotonic() + 5
        while not path.is_file() and process.poll() is None and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue(path.is_file(), f"fixture did not create {path.name}")

    def assert_command_stopped(self, pid_path):
        self.assertTrue(pid_path.is_file(), "fixture never started")
        with self.assertRaises(ProcessLookupError):
            os.kill(int(pid_path.read_text()), 0)

    def test_success_is_propagated_and_logged(self):
        result, diagnostics = self.run_watchdog([sys.executable, "-c", "print('passed')"])
        self.assertEqual(result.returncode, 0)
        self.assertIn("passed", result.stdout)
        self.assertIn("status=0", (diagnostics / "fixture-repeat-1.log").read_text())

    def test_nonzero_status_is_propagated(self):
        result, _ = self.run_watchdog([sys.executable, "-c", "raise SystemExit(17)"])
        self.assertEqual(result.returncode, 17)

    def test_invalid_timeouts_fail_before_launch(self):
        for timeout in ("nan", "inf", "-inf", "1e999", "0", "-1"):
            with self.subTest(timeout=timeout):
                diagnostics = self.diagnostics()
                marker = diagnostics / "launched"
                command = [sys.executable, "-c", f"from pathlib import Path; Path({str(marker)!r}).touch()"]
                result, _ = self.run_watchdog(command, timeout, diagnostics=diagnostics)
                self.assertEqual(result.returncode, 2, result.stdout)
                self.assertIn("--timeout-seconds must be finite and positive", result.stdout)
                self.assertFalse(marker.exists())

    def test_diagnostic_write_failure_preserves_timeout_and_cleans_command(self):
        diagnostics = self.diagnostics()
        (diagnostics / "fixture-repeat-1-process-tree.txt").mkdir()
        command, pid_path = self.sleeping_command(diagnostics)
        result, _ = self.run_watchdog(command, 0.5, diagnostics=diagnostics)
        self.assert_command_stopped(pid_path)
        self.assertEqual(result.returncode, 124, result.stdout)
        self.assertIn("diagnostics unavailable", result.stdout)

    def test_closed_output_pipe_cleans_command(self):
        diagnostics = self.diagnostics()
        command, pid_path = self.sleeping_command(diagnostics, output=True)
        process = self.start_watchdog(command, diagnostics)
        self.wait_for_file(pid_path, process)
        process.stdout.close()
        process.wait(timeout=10)
        self.assert_command_stopped(pid_path)
        self.assertNotEqual(process.returncode, 0)

    def test_closed_output_during_timeout_preserves_status(self):
        diagnostics = self.diagnostics()
        command, pid_path = self.sleeping_command(diagnostics)
        process = self.start_watchdog(command, diagnostics, timeout=0.5)
        self.wait_for_file(pid_path, process)
        process.stdout.close()
        process.wait(timeout=10)
        self.assert_command_stopped(pid_path)
        self.assertEqual(process.returncode, 124, process.stderr.read())
        self.assertIn("status=timeout", (diagnostics / "fixture-repeat-1.log").read_text())

    def test_full_log_during_timeout_preserves_status(self):
        diagnostics = self.diagnostics()
        sampler = diagnostics / "sampler"
        sampler.write_text(f"#!{sys.executable}\nprint('x' * 8192)\nraise SystemExit(9)\n")
        sampler.chmod(0o755)
        env = {**os.environ, "SPOTTY_SWIFT_TEST_SAMPLER": str(sampler)}
        command, pid_path = self.sleeping_command(diagnostics)

        def limit_log_size():
            resource.setrlimit(resource.RLIMIT_FSIZE, (4096, 4096))
            signal.signal(signal.SIGXFSZ, signal.SIG_IGN)

        result, _ = self.run_watchdog(command, 0.5, env, diagnostics, limit_log_size)
        self.assert_command_stopped(pid_path)
        self.assertEqual(result.returncode, 124, result.stdout)
        self.assertEqual((diagnostics / "fixture-repeat-1.log").stat().st_size, 4096)
        self.assertNotIn("Traceback", result.stdout)

    def test_diagnostic_short_writes_preserve_each_available_sink(self):
        message = "sampler detail é\n" * 1024
        expected = (message + "\n").encode()
        for stdout_chunk in (7, 0):
            with self.subTest(stdout_chunk=stdout_chunk):
                log_path = self.diagnostics() / "short-writes.log"
                program = (
                    "import sys\n"
                    f"sys.path.insert(0, {str(SCRIPT.parent)!r})\n"
                    "import swift_test_watchdog as watchdog\n"
                    "real_write = watchdog.os.write\n"
                    "def short_write(fd, data):\n"
                    f"    limit = {stdout_chunk} if fd == sys.stdout.fileno() else 11\n"
                    "    return real_write(fd, data[:limit])\n"
                    "watchdog.os.write = short_write\n"
                    f"with open({str(log_path)!r}, 'wb') as log:\n"
                    f"    watchdog.emit_diagnostic({message!r}, log)\n"
                )
                result = subprocess.run(
                    [sys.executable, "-B", "-c", program], capture_output=True, timeout=5,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                stdout_expected = expected if stdout_chunk else b""
                self.assertEqual(len(result.stdout), len(stdout_expected))
                self.assertEqual(result.stdout, stdout_expected)
                logged = log_path.read_bytes()
                self.assertEqual(len(logged), len(expected))
                self.assertEqual(logged, expected)

    def test_second_interrupt_during_cleanup_cannot_strand_command(self):
        for interrupt in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(interrupt=interrupt):
                diagnostics = self.diagnostics()
                command, pid_path = self.sleeping_command(diagnostics, ignore_term=True)
                process = self.start_watchdog(command, diagnostics)
                self.wait_for_file(pid_path, process)
                process.send_signal(signal.SIGTERM)
                self.wait_for_file(diagnostics / "cleanup-started", process)
                process.send_signal(interrupt)
                stdout, stderr = process.communicate(timeout=10)
                self.assert_command_stopped(pid_path)
                self.assertEqual(process.returncode, 143, stdout + stderr)

    def test_failed_diagnostic_tools_preserve_timeout_with_non_utf8_output(self):
        diagnostics = self.diagnostics()
        tools = diagnostics / "tools"
        tools.mkdir()
        for name, status in (("ps", 1), ("sampler", 9)):
            tool = tools / name
            tool.write_text(
                f"#!{sys.executable}\nimport sys\nsys.stdout.buffer.write(b'failure: \\xff')\n"
                f"raise SystemExit({status})\n"
            )
            tool.chmod(0o755)
        env = {**os.environ, "PATH": str(tools), "SPOTTY_SWIFT_TEST_SAMPLER": str(tools / "sampler")}
        command, pid_path = self.sleeping_command(diagnostics)
        result, _ = self.run_watchdog(command, 0.5, env, diagnostics)
        self.assert_command_stopped(pid_path)
        self.assertEqual(result.returncode, 124, result.stdout)
        self.assertIn("sampler failed with status 9: failure:", result.stdout)
        tree = (diagnostics / "fixture-repeat-1-process-tree.txt").read_text()
        self.assertIn("process tree unavailable (status 1): failure:", tree)

    def test_timeout_captures_tree_and_cleans_silent_descendant(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        pid_path = Path(temporary.name) / "child.pid"
        program = (
            "import pathlib,subprocess,sys,time; "
            "p=subprocess.Popen([sys.executable,'-c',"
            "'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)']); "
            f"pathlib.Path({str(pid_path)!r}).write_text(str(p.pid))"
        )
        result, diagnostics = self.run_watchdog([sys.executable, "-c", program], timeout=0.3)
        self.assertEqual(result.returncode, 124)
        self.assertTrue((diagnostics / "fixture-repeat-1-process-tree.txt").is_file())
        child_pid = int(pid_path.read_text())
        for _ in range(50):
            try:
                os.kill(child_pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.02)
        else:
            self.fail("silent descendant survived the owned process-group timeout")

    def test_interrupt_is_propagated_and_cleans_the_group(self):
        for interrupt, expected_status in ((signal.SIGINT, 130), (signal.SIGTERM, 143)):
            with self.subTest(interrupt=interrupt):
                temporary = tempfile.TemporaryDirectory()
                self.addCleanup(temporary.cleanup)
                diagnostics = Path(temporary.name)
                pid_path = diagnostics / "command.pid"
                command = (
                    "import os,pathlib,time; "
                    f"pathlib.Path({str(pid_path)!r}).write_text(str(os.getpid())); time.sleep(60)"
                )
                process = subprocess.Popen(
                    [
                        sys.executable, str(SCRIPT), "--lane", "interrupt", "--repetition", "1",
                        "--timeout-seconds", "30", "--log-dir", str(diagnostics), "--",
                        sys.executable, "-c", command,
                    ],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                )
                for _ in range(50):
                    if pid_path.is_file():
                        break
                    time.sleep(0.02)
                self.assertTrue(pid_path.is_file())
                process.send_signal(interrupt)
                stdout, _ = process.communicate(timeout=10)
                self.assertEqual(process.returncode, expected_status)
                self.assertIn("interrupted", stdout)
                with self.assertRaises(ProcessLookupError):
                    os.kill(int(pid_path.read_text()), 0)

    def test_unavailable_sampler_does_not_mask_timeout(self):
        env = os.environ.copy()
        env["SPOTTY_SWIFT_TEST_SAMPLER"] = "/definitely/missing/spotty-sampler"
        result, _ = self.run_watchdog([sys.executable, "-c", "import time; time.sleep(60)"], 0.2, env)
        self.assertEqual(result.returncode, 124)
        self.assertIn("sampler unavailable", result.stdout)

    def test_failing_sampler_does_not_mask_timeout(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        sampler = Path(temporary.name) / "sampler"
        sampler.write_text("#!/bin/sh\nexit 9\n")
        sampler.chmod(0o755)
        env = os.environ.copy()
        env["SPOTTY_SWIFT_TEST_SAMPLER"] = str(sampler)
        result, _ = self.run_watchdog([sys.executable, "-c", "import time; time.sleep(60)"], 0.2, env)
        self.assertEqual(result.returncode, 124)
        self.assertIn("sampler failed with status 9", result.stdout)


if __name__ == "__main__":
    unittest.main()
