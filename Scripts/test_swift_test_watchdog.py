import json
import os
from pathlib import Path
import resource
import signal
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest import mock

import swift_test_watchdog as watchdog


SCRIPT = Path(__file__).with_name("swift_test_watchdog.py")


class SwiftTestWatchdogTests(unittest.TestCase):
    def setUp(self):
        # Timeout tests use synthetic samplers exclusively, including on macOS.
        sampler_environment = mock.patch.dict(os.environ, SPOTTY_SWIFT_TEST_SAMPLER="/usr/bin/false")
        sampler_environment.start()
        self.addCleanup(sampler_environment.stop)

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

    def test_second_interrupt_during_gated_diagnostics_preserves_the_first_status(self):
        for first, expected in ((signal.SIGINT, 130), (signal.SIGTERM, 143)):
            for second in (signal.SIGINT, signal.SIGTERM):
                with self.subTest(first=first, second=second):
                    diagnostics = self.diagnostics()
                    command, pid_path = self.sleeping_command(diagnostics)
                    entered = diagnostics / "diagnostics-entered"
                    release = diagnostics / "diagnostics-release"
                    driver = diagnostics / "gated-watchdog.py"
                    driver.write_text(
                        "import sys,time\nfrom pathlib import Path\n"
                        f"sys.path.insert(0, {str(SCRIPT.parent)!r})\n"
                        "import swift_test_watchdog as watchdog\n"
                        "original = watchdog.write_interruption_diagnostics\n"
                        "def gated(*arguments):\n"
                        f"    Path({str(entered)!r}).touch()\n"
                        "    deadline = time.monotonic() + 5\n"
                        f"    while not Path({str(release)!r}).exists():\n"
                        "        if time.monotonic() >= deadline: raise RuntimeError('diagnostics gate not released')\n"
                        "        time.sleep(.01)\n"
                        "    return original(*arguments)\n"
                        "watchdog.write_interruption_diagnostics = gated\n"
                        "raise SystemExit(watchdog.run(watchdog.parse_args()))\n"
                    )
                    process = subprocess.Popen(
                        [sys.executable, "-B", str(driver), *self.arguments(command, diagnostics, 30)[2:]],
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                    )

                    def stop(process=process, release=release):
                        release.touch()
                        if process.poll() is None:
                            process.terminate()
                        process.communicate(timeout=10)

                    self.addCleanup(process.stderr.close)
                    self.addCleanup(process.stdout.close)
                    self.addCleanup(stop)
                    self.wait_for_file(pid_path, process)
                    process.send_signal(first)
                    self.wait_for_file(entered, process)
                    # The second signal lands after diagnostics began, before cleanup.
                    # Release only this owned gate; no timing delay chooses the window.
                    process.send_signal(second)
                    release.touch()
                    stdout, stderr = process.communicate(timeout=10)
                    self.assert_command_stopped(pid_path)
                    self.assertEqual(process.returncode, expected, stdout + stderr)
                    self.assertIn(f"status={expected}", stdout)
                    self.assertTrue((diagnostics / "fixture-repeat-1-process-tree.txt").is_file())

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

    def fixture_wrapper(self, *, sampler_timeout=.5, classify_fixture=False):
        return (
            f"import sys; sys.path.insert(0, {str(SCRIPT.parent)!r}); "
            "import swift_test_watchdog as w; "
            f"w.SAMPLER_TIMEOUT_SECONDS={sampler_timeout!r}; "
            + ("w.host_role=lambda identity,command: 'synthetic fixture host' "
               "if '--fixture-host' in command.split() else None; " if classify_fixture else "")
            + "sys.argv=sys.argv[1:]; raise SystemExit(w.run(w.parse_args()))"
        )

    def start_wrapped_watchdog(self, command, diagnostics, timeout, *, classify_fixture=False):
        process = subprocess.Popen(
            [sys.executable, "-B", "-c", self.fixture_wrapper(classify_fixture=classify_fixture),
             *self.arguments(command, diagnostics, timeout)[1:]],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        self.addCleanup(process.stdout.close)
        self.addCleanup(process.stderr.close)

        def stop():
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)

        self.addCleanup(stop)
        return process

    def sampler_fixture(self, diagnostics, *, detached=False, successful=False):
        sampler = diagnostics / "sampler"
        child_path = diagnostics / "sampler-child.pid"
        sampler.write_text(
            f"#!{sys.executable}\n"
            "import os,pathlib,signal,subprocess,sys,time\n"
            "pathlib.Path(sys.argv[2]).write_text(sys.argv[1])\n"
            "child=subprocess.Popen([sys.executable,'-c',"
            "'import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(60)'],"
            f"start_new_session={detached!r},stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)\n"
            f"pathlib.Path({str(child_path)!r}).write_text(str(child.pid))\n"
            + ("time.sleep(.35)\n" if successful else
               "signal.signal(signal.SIGTERM,signal.SIG_IGN)\ntime.sleep(60)\n")
        )
        sampler.chmod(0o755)
        environment = mock.patch.dict(os.environ, SPOTTY_SWIFT_TEST_SAMPLER=str(sampler))
        environment.start()
        self.addCleanup(environment.stop)
        return child_path

    def remember_fixture_identity(self, pid_path):
        identity = watchdog.process_identity(int(pid_path.read_text()))
        self.assertIsNotNone(identity)

        def stop():
            if identity.same_process(watchdog.process_identity(identity.pid)):
                try:
                    os.kill(identity.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass

        self.addCleanup(stop)
        return identity

    def assert_fixture_gone(self, identity):
        deadline = time.monotonic() + 2
        while identity.same_process(watchdog.process_identity(identity.pid)) and time.monotonic() < deadline:
            time.sleep(.02)
        self.assertFalse(identity.same_process(watchdog.process_identity(identity.pid)),
                         f"owned fixture {identity.pid} survived cleanup")

    def test_sampler_timeout_joins_group_children(self):
        diagnostics = self.diagnostics()
        child_path = self.sampler_fixture(diagnostics)
        command, pid_path = self.sleeping_command(diagnostics)
        process = self.start_wrapped_watchdog(command, diagnostics, .3)
        self.wait_for_file(child_path, process)
        child = self.remember_fixture_identity(child_path)
        stdout, stderr = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 124, stdout + stderr)
        self.assertIn("sampler unavailable or timed out", stdout)
        self.assert_command_stopped(pid_path)
        self.assert_fixture_gone(child)

    def test_successful_sampler_joins_observed_detached_child_after_reaping(self):
        diagnostics = self.diagnostics()
        child_path = self.sampler_fixture(diagnostics, detached=True, successful=True)
        command, pid_path = self.sleeping_command(diagnostics)
        process = self.start_wrapped_watchdog(command, diagnostics, .3)
        self.wait_for_file(child_path, process)
        child = self.remember_fixture_identity(child_path)
        stdout, stderr = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 124, stdout + stderr)
        self.assertIn("sampled driver fallback; host attribution unavailable", stdout)
        self.assert_fixture_gone(child)
        self.assert_command_stopped(pid_path)

    def test_interrupt_during_sampler_cleans_sampler_children(self):
        for interrupt, status in ((signal.SIGINT, 130), (signal.SIGTERM, 143)):
            with self.subTest(interrupt=interrupt):
                diagnostics = self.diagnostics()
                child_path = self.sampler_fixture(diagnostics, detached=True)
                command, pid_path = self.sleeping_command(diagnostics)
                process = self.start_wrapped_watchdog(command, diagnostics, .3)
                self.wait_for_file(child_path, process)
                child = self.remember_fixture_identity(child_path)
                # Allow a launch-ancestry observation before the deliberate interrupt.
                time.sleep(.2)
                process.send_signal(interrupt)
                stdout, stderr = process.communicate(timeout=10)
                self.assertEqual(process.returncode, status, stdout + stderr)
                self.assert_fixture_gone(child)
                self.assert_command_stopped(pid_path)

    def test_closed_output_during_sampler_preserves_timeout_and_cleans_children(self):
        diagnostics = self.diagnostics()
        child_path = self.sampler_fixture(diagnostics, detached=True)
        command, pid_path = self.sleeping_command(diagnostics)
        process = self.start_wrapped_watchdog(command, diagnostics, .3)
        self.wait_for_file(child_path, process)
        child = self.remember_fixture_identity(child_path)
        process.stdout.close()
        process.wait(timeout=10)
        self.assertEqual(process.returncode, 124, process.stderr.read())
        self.assert_fixture_gone(child)
        self.assert_command_stopped(pid_path)

    def test_owned_detached_host_selected_and_unrelated_process_preserved(self):
        diagnostics = self.diagnostics()
        host_path = diagnostics / "host.pid"
        sentinel = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)",
                                     "--fixture-host"], start_new_session=True)

        def stop_sentinel():
            if sentinel.poll() is None:
                sentinel.kill()
            sentinel.wait(timeout=5)

        self.addCleanup(stop_sentinel)
        sampler = diagnostics / "sampler"
        sampler.write_text(f"#!{sys.executable}\nimport pathlib,sys\n"
                           "pathlib.Path(sys.argv[2]).write_text(sys.argv[1])\n")
        sampler.chmod(0o755)
        child_code = (
            "import os,pathlib,time; "
            f"pathlib.Path({str(host_path)!r}).write_text(str(os.getpid())); time.sleep(60)"
        )
        driver_code = (
            "import subprocess,sys,time; "
            f"subprocess.Popen([sys.executable,'-c',{child_code!r},'--fixture-host'],"
            "start_new_session=True); time.sleep(.4)"
        )
        with mock.patch.dict(os.environ, SPOTTY_SWIFT_TEST_SAMPLER=str(sampler)):
            process = self.start_wrapped_watchdog(
                [sys.executable, "-c", driver_code], diagnostics, .8, classify_fixture=True)
            self.wait_for_file(host_path, process)
            host = self.remember_fixture_identity(host_path)
            stdout, stderr = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 124, stdout + stderr)
        self.assertEqual((diagnostics / "fixture-repeat-1-sample.txt").read_text(), str(host.pid))
        self.assertIn(f"host PID {host.pid}", stdout)
        tree = json.loads((diagnostics / "fixture-repeat-1-process-tree.txt").read_text())
        record = next(row for row in tree["processes"] if row["pid"] == host.pid)
        self.assertNotEqual(record["pgid"], record["launchAncestry"][0])
        self.assertNotIn(sentinel.pid, [row["pid"] for row in tree["processes"]])
        self.assert_fixture_gone(host)
        self.assertIsNone(sentinel.poll(), "unrelated host-like process was killed")

    def test_timeout_artifact_keeps_native_attribution_separate_from_driver_output(self):
        diagnostics = self.diagnostics()
        swift = diagnostics / "swift"
        records = [
            {"kind": "test", "payload": {"kind": "function", "id": "completed"}},
            {"kind": "test", "payload": {"kind": "function", "id": "active"}},
            {"kind": "event", "payload": {"kind": "testEnded", "testID": "completed"}},
            {"kind": "event", "payload": {"kind": "testStarted", "testID": "active"}},
        ]
        data = "\n".join(json.dumps(record) for record in records) + "\n{\"kind\":"
        swift.write_text(
            f"#!{sys.executable}\nimport os,pathlib,sys,time\n"
            "if sys.argv[1:] == ['test', '--help-hidden']:\n"
            "    print('--event-stream-output-path'); raise SystemExit(0)\n"
            "path=pathlib.Path(sys.argv[sys.argv.index('--event-stream-output-path')+1])\n"
            f"path.write_text({data!r})\n"
            "print('driver-only output names a different function',flush=True)\n"
            "time.sleep(60)\n"
        )
        swift.chmod(0o755)
        result, _ = self.run_watchdog([str(swift), "test"], .3,
                                      diagnostics=diagnostics, require_tests=True)
        self.assertEqual(result.returncode, 124, result.stdout)
        tree = json.loads((diagnostics / "fixture-repeat-1-process-tree.txt").read_text())
        self.assertEqual(tree["nativeEvents"]["activeFunctions"], ["active"])
        self.assertEqual(tree["nativeEvents"]["lastStarted"]["testID"], "active")
        self.assertEqual(tree["nativeEvents"]["lastCompleted"]["testID"], "completed")
        self.assertEqual(tree["nativeEvents"]["partialRecords"], 1)
        self.assertEqual(tree["hostAttribution"], "unavailable; driver fallback")
        self.assertIn("driver fallback; host attribution unavailable", result.stdout)


    def test_timeout_and_interruption_retain_bundle_stream_before_owned_cleanup(self):
        for interruption in [None, signal.SIGTERM]:
            with self.subTest(interruption=interruption), \
                    tempfile.TemporaryDirectory(prefix="swiftpm-test-output-") as directory:
                root = Path(directory)
                bundle = root / "SyntheticTests.xctest"
                bundle.mkdir()
                events = root / "event-stream-0-SyntheticTests.jsonl"
                records = [
                    {"kind": "test", "payload": {"kind": "function", "id": "stalled"}},
                    {"kind": "event", "payload": {"kind": "testStarted", "testID": "stalled"}},
                ]
                code = (f"from pathlib import Path; import time; "
                        f"Path({str(events)!r}).write_text({''.join(json.dumps(r) + chr(10) for r in records)!r}); "
                        "time.sleep(60)")
                diagnostics = root / "diagnostics"
                process = self.start_wrapped_watchdog([
                    sys.executable, "-c", code, "--fixture-host", "--test-bundle-path", str(bundle),
                    "--event-stream-output-path", str(events),
                ], diagnostics, .5 if interruption is None else 5, classify_fixture=True)
                deadline = time.monotonic() + 3
                while not events.exists() and time.monotonic() < deadline:
                    time.sleep(.01)
                self.assertTrue(events.exists())
                if interruption is not None:
                    process.send_signal(interruption)
                stdout, stderr = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 124 if interruption is None else 143, stdout + stderr)
                tree = json.loads((diagnostics / "fixture-repeat-1-process-tree.txt").read_text())
                receipt = tree["bundleNativeEvents"][0]
                self.assertTrue(receipt["available"], receipt)
                self.assertEqual(receipt["nativeEvents"]["activeFunctions"], ["stalled"])
                self.assertEqual(Path(receipt["retainedPath"]).read_bytes(), events.read_bytes())


class InterruptReentryTests(unittest.TestCase):
    def test_post_fork_sampler_interrupt_retains_handle_and_joins_before_first_status(self):
        latch = watchdog.SignalLatch()
        handlers = {signal.SIGINT: latch.request, signal.SIGTERM: latch.request}
        original = dict(handlers)
        root = watchdog.ProcessIdentity(10, 1, 10, (1, 100), "/fixture-driver")
        owned = SimpleNamespace(observe=lambda **_: None, live=lambda: [root],
                                process=SimpleNamespace(pid=10), commands={})
        sampler = SimpleNamespace(pid=30, returncode=None, stdout=mock.Mock())
        forked, joined = [], []

        def post_fork_launch(*arguments, **keywords):
            forked.append(sampler.pid)
            # The child already exists, but Popen has not yet returned its handle.
            handlers[signal.SIGINT](signal.SIGINT, None)
            return sampler

        def cleanup():
            handlers[signal.SIGTERM](signal.SIGTERM, None)
            joined.append(sampler.pid)
            sampler.returncode = -signal.SIGTERM

        tracker = SimpleNamespace(cleanup=cleanup)
        with mock.patch.object(watchdog.signal, "getsignal", side_effect=handlers.get), \
                mock.patch.object(watchdog.signal, "signal", side_effect=lambda sig, handler: handlers.__setitem__(sig, handler)), \
                mock.patch.object(watchdog, "process_identity", return_value=root), \
                mock.patch.object(watchdog.subprocess, "Popen", side_effect=post_fork_launch), \
                mock.patch.object(watchdog, "OwnedProcesses", return_value=tracker), \
                mock.patch.dict(os.environ, SPOTTY_SWIFT_TEST_SAMPLER="/fixture-sampler"):
            with self.assertRaises(watchdog.TerminationRequested) as raised:
                watchdog.sample_helper(owned, Path("/unused"))
        self.assertEqual(raised.exception.signal_number, signal.SIGINT)
        self.assertEqual(forked, [30])
        self.assertEqual(joined, [30])
        self.assertEqual(handlers, original)
        sampler.stdout.close.assert_called_once()

    def run_interrupted(self, first, second, *, window="setup"):
        joins = []
        injected = False
        interrupted = False

        def original_int(number, frame):
            raise KeyboardInterrupt()

        def original_term(number, frame):
            raise watchdog.TerminationRequested(number)

        handlers = {signal.SIGINT: original_int, signal.SIGTERM: original_term}

        def install(number, handler):
            nonlocal injected
            # Deliver the opposite second signal during the first cleanup/catch
            # handler installation, before that install has masked either signal.
            matches = (window == "setup" or
                       (window == "restore" and joins and handler is original_term))
            if interrupted and not injected and matches:
                injected = True
                current = handlers[second]
                if callable(current):
                    current(second, None)
            handlers[number] = handler

        def observe(**keywords):
            nonlocal interrupted
            if not interrupted:
                interrupted = True
                handlers[first](first, None)

        process = SimpleNamespace(pid=10, returncode=None, stdout=mock.Mock())
        owned = SimpleNamespace(observe=observe)

        def cleanup():
            joins.extend([20, 10])  # Retained detached descendant, then direct join.
            process.returncode = -signal.SIGTERM

        owned.cleanup = cleanup
        with tempfile.TemporaryDirectory() as directory:
            args = SimpleNamespace(log_dir=Path(directory), lane="fixture", repetition=1,
                                   require_tests=False, event_stream_path=None, command=["fixture"],
                                   timeout_seconds=10)
            with mock.patch.object(watchdog.signal, "getsignal", side_effect=handlers.get), \
                    mock.patch.object(watchdog.signal, "signal", side_effect=install), \
                    mock.patch.object(watchdog.subprocess, "Popen", return_value=process), \
                    mock.patch.object(watchdog, "OwnedProcesses", return_value=owned), \
                    mock.patch.object(watchdog, "command_with_event_stream", return_value=(["fixture"], False)), \
                    mock.patch.object(watchdog, "write_interruption_diagnostics"), \
                    mock.patch.object(watchdog, "emit"), \
                    mock.patch.object(watchdog, "emit_diagnostic"), \
                    mock.patch.object(watchdog.selectors, "DefaultSelector", return_value=mock.Mock()), \
                    mock.patch.object(watchdog.time, "monotonic", return_value=0):
                try:
                    status = watchdog.run(args)
                except KeyboardInterrupt:
                    status = 130
                except watchdog.TerminationRequested as error:
                    status = 128 + error.signal_number
        self.assertTrue(injected)
        self.assertEqual(joins, [20, 10])
        self.assertEqual(handlers, {signal.SIGINT: original_int, signal.SIGTERM: original_term})
        self.assertEqual(status, 128 + first)

    def test_first_sigint_survives_sigterm_at_handler_installation(self):
        self.run_interrupted(signal.SIGINT, signal.SIGTERM)

    def test_first_sigterm_survives_sigint_at_handler_installation(self):
        self.run_interrupted(signal.SIGTERM, signal.SIGINT)

    def test_first_sigint_survives_sigterm_at_original_handler_restoration(self):
        self.run_interrupted(signal.SIGINT, signal.SIGTERM, window="restore")

    def test_first_sigterm_survives_default_sigint_at_original_handler_restoration(self):
        self.run_interrupted(signal.SIGTERM, signal.SIGINT, window="restore")

    def test_first_signal_during_default_handler_cleanup_setup_waits_for_both_owned_actions(self):
        for first, second in ((signal.SIGINT, signal.SIGTERM), (signal.SIGTERM, signal.SIGINT)):
            with self.subTest(first=first, second=second):
                def original_int(number, frame):
                    raise KeyboardInterrupt()

                def original_term(number, frame):
                    raise watchdog.TerminationRequested(number)

                original = {signal.SIGINT: original_int, signal.SIGTERM: original_term}
                handlers = dict(original)
                injected = []

                def install(number, handler):
                    if len(injected) < 2:
                        target = first if not injected else second
                        injected.append(target)
                        handlers[target](target, None)
                    handlers[number] = handler

                actions = []
                process = SimpleNamespace(pid=10, returncode=None)

                def wait(**keywords):
                    actions.append("direct-join")
                    process.returncode = -signal.SIGTERM

                process.wait = wait
                owned = object.__new__(watchdog.OwnedProcesses)
                owned.process = process
                owned.observe = lambda **_: None
                owned.live = lambda: []
                owned.signal = lambda number: actions.append(("retained-descendant-signal", number))
                with mock.patch.object(watchdog.signal, "getsignal", side_effect=handlers.get), \
                        mock.patch.object(watchdog.signal, "signal", side_effect=install), \
                        mock.patch.object(watchdog.time, "monotonic", return_value=0):
                    with self.assertRaises(watchdog.TerminationRequested) as raised:
                        watchdog.terminate_owned_group(process, owned)
                self.assertEqual(raised.exception.signal_number, first)
                self.assertEqual(injected, [first, second])
                self.assertEqual(actions, [("retained-descendant-signal", signal.SIGTERM),
                                           ("retained-descendant-signal", signal.SIGKILL), "direct-join"])
                self.assertEqual(handlers, original)

    def test_external_first_signal_latch_is_not_replaced_by_cleanup_only_signal(self):
        original = {signal.SIGINT: lambda *_: None, signal.SIGTERM: lambda *_: None}
        handlers = dict(original)
        actions = []
        process = SimpleNamespace(pid=10, returncode=None)

        def cleanup():
            actions.append("retained-descendant-cleanup")
            # An external controller already caught its first SIGINT. Its
            # handlers return for later signals; cleanup must retain that contract.
            handlers[signal.SIGTERM](signal.SIGTERM, None)
            actions.append("direct-join")
            process.returncode = -signal.SIGTERM

        owned = SimpleNamespace(cleanup=cleanup)
        with mock.patch.object(watchdog.signal, "getsignal", side_effect=handlers.get), \
                mock.patch.object(watchdog.signal, "signal", side_effect=lambda sig, handler: handlers.__setitem__(sig, handler)):
            watchdog.terminate_owned_group(process, owned)
        self.assertEqual(actions, ["retained-descendant-cleanup", "direct-join"])
        self.assertEqual(handlers, original)



class ProcessOwnershipTests(unittest.TestCase):
    def identity(self, pid, parent=1, group=10, usec=100, executable="/fixture"):
        return watchdog.ProcessIdentity(pid, parent, group, (1, usec), executable)

    def test_kernel_identity_has_high_resolution_birth_and_actual_relations(self):
        identity = watchdog.process_identity(os.getpid())
        self.assertIsNotNone(identity)
        self.assertEqual((identity.pid, identity.ppid, identity.pgid),
                         (os.getpid(), os.getppid(), os.getpgid(0)))
        self.assertTrue(identity.executable)
        self.assertTrue(identity.birth)
        if sys.platform == "darwin":
            self.assertEqual(len(identity.birth), 2)
            self.assertLess(identity.birth[1], 1_000_000)

    def test_reparented_and_execed_descendants_retained_but_reused_pids_excluded(self):
        root = self.identity(10)
        child = self.identity(20, parent=10)
        unrelated = self.identity(30)
        identities = {10: root, 20: child, 30: unrelated}
        rows = {pid: (value.ppid, value.pgid, "/fixture") for pid, value in identities.items()}
        process = SimpleNamespace(pid=10, returncode=None)
        with mock.patch.object(watchdog, "process_identity", side_effect=identities.get), \
                mock.patch.object(watchdog, "process_inventory", return_value=(rows, None)):
            owned = watchdog.OwnedProcesses(process)
            owned.observe(force=True)
            self.assertEqual(set(owned.identities), {10, 20})
            self.assertEqual(owned.ancestry[20], [10, 20])
            identities[20] = self.identity(20, parent=1, group=20, executable="/new-image")
            rows[20] = (1, 20, "/new-image")
            owned.observe(force=True)
            self.assertIn(20, [item.pid for item in owned.live()])
            self.assertEqual(owned.identities[20].executable, "/new-image")
            # Reuse within the very same second must not pass identity validation.
            identities[20] = self.identity(20, parent=1, group=20, usec=101)
            process.returncode = 0
            with mock.patch.object(watchdog.os, "kill") as kill, \
                    mock.patch.object(watchdog.os, "killpg") as killpg:
                owned.signal(signal.SIGKILL)
                kill.assert_not_called()
                killpg.assert_not_called()

    def test_reused_parent_cannot_recruit_new_children(self):
        identities = {10: self.identity(10)}
        with mock.patch.object(watchdog, "process_identity", side_effect=identities.get), \
                mock.patch.object(watchdog, "process_inventory") as inventory:
            owned = watchdog.OwnedProcesses(SimpleNamespace(pid=10, returncode=0))
            identities[10] = self.identity(10, usec=101)
            identities[20] = self.identity(20, parent=10, usec=102)
            inventory.return_value = ({20: (10, 10, "/fixture")}, None)
            owned.observe(force=True)
            self.assertNotIn(20, owned.identities)

    def test_sampler_refuses_reused_target_before_launch(self):
        root = self.identity(10)
        owned = SimpleNamespace(observe=lambda **_: None, live=lambda: [root], root=root,
                                process=SimpleNamespace(pid=10), commands={10: "driver"})
        with mock.patch.object(watchdog, "process_identity", side_effect=[root, self.identity(10, usec=101)]), \
                mock.patch.object(watchdog.subprocess, "Popen") as launch, \
                mock.patch.dict(os.environ, SPOTTY_SWIFT_TEST_SAMPLER="/fixture-sampler"):
            result = watchdog.sample_helper(owned, Path("/unused"))
        self.assertIn("sampler refused: target identity changed", result)
        launch.assert_not_called()

    def test_signals_revalidate_every_retained_descendant_and_never_reuse_reaped_root(self):
        identities = {10: self.identity(10), 20: self.identity(20, parent=10),
                      30: self.identity(30, parent=10)}
        rows = {pid: (item.ppid, item.pgid, "/fixture") for pid, item in identities.items()}
        with mock.patch.object(watchdog, "process_identity", side_effect=identities.get), \
                mock.patch.object(watchdog, "process_inventory", return_value=(rows, None)):
            process = SimpleNamespace(pid=10, returncode=0)
            owned = watchdog.OwnedProcesses(process)
            owned.observe(force=True)
            # Root and one descendant have been reaped and reused by unrelated work.
            identities[10] = self.identity(10, usec=101)
            identities[20] = self.identity(20, usec=101)
            with mock.patch.object(watchdog.os, "kill") as kill, \
                    mock.patch.object(watchdog.os, "killpg") as killpg:
                owned.signal(signal.SIGKILL)
            kill.assert_called_once_with(30, signal.SIGKILL)
            killpg.assert_not_called()

    def test_name_or_group_alone_never_proves_a_host(self):
        identity = self.identity(20, executable="/tmp/swiftpm-testing-helper")
        self.assertIsNone(watchdog.host_role(identity, "swiftpm-testing-helper"))
        helper = "/toolchain/libexec/swift/pm/swiftpm-testing-helper"
        identity = self.identity(20, executable=helper)
        self.assertIsNone(watchdog.host_role(identity, helper))
        self.assertIsNone(watchdog.host_role(identity, helper + " --test-bundle-path /tmp/not-a-bundle"))
        foreign = self.identity(20, executable="/tmp/swiftpm-testing-helper")
        self.assertIsNone(watchdog.host_role(foreign, helper + " --test-bundle-path /tmp/Actual.xctest"))

    def test_actual_swift64_loader_binary_operand_identifies_host(self):
        helper = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper"
        bundle = Path("/private/tmp/spotty-585-actual64-high-o01yl3zb/run/build/out/Products/Debug/OwnedHostObservationTests.xctest")
        binary = bundle / "Contents/MacOS/OwnedHostObservationTests"
        identity = self.identity(4503, executable=helper)
        # Actual once-only observation used the binary operand and repeated that
        # binary as a positional argument. Neither is a second bundle flag.
        command = f"{helper} --test-bundle-path {binary} {binary} --testing-library swift-testing"
        self.assertEqual(watchdog.host_role(identity, command), "SwiftPM test-bundle loader")
        self.assertEqual(watchdog.loader_test_bundle(command), bundle)

    def test_loader_bundle_directory_and_quoted_binary_have_one_normalizer(self):
        helper = "/toolchain/libexec/swift/pm/swiftpm-testing-helper"
        identity = self.identity(20, executable=helper)
        bundle = Path("/produced build/SpottyPackageTests.xctest")
        for operand in (bundle, bundle / "Contents/MacOS/SpottyPackageTests"):
            command = f'{helper} --test-bundle-path "{operand}"'
            self.assertEqual(watchdog.host_role(identity, command), "SwiftPM test-bundle loader")
            self.assertEqual(watchdog.loader_test_bundle(command), bundle)

    def test_loader_rejects_ambiguous_relative_or_arbitrary_bundle_children(self):
        helper = "/toolchain/libexec/swift/pm/swiftpm-testing-helper"
        identity = self.identity(20, executable=helper)
        commands = [
            f"{helper} --test-bundle-path relative.xctest",
            f"{helper} --test-bundle-path /build/A.xctest --test-bundle-path /build/B.xctest",
            f"{helper} --test-bundle-path /build/A.xctest --test-bundle-path=/build/B.xctest",
            f"{helper} --test-bundle-path /build/A.xctest/arbitrary-child",
            f"{helper} --test-bundle-path /build/A.xctest/Contents/MacOS/A/child",
            f"{helper} --test-bundle-path /build/A.xctest/Contents/Other/A",
            f"{helper} --test-bundle-path /build/A.xctest/Contents/MacOS/../A",
            f"{helper} --test-bundle-path /build/A.xctest/Contents/MacOS/Other",
            f"{helper} --test-bundle-path",
            f'{helper} --test-bundle-path "',
        ]
        for command in commands:
            with self.subTest(command=command):
                self.assertIsNone(watchdog.host_role(identity, command))
                self.assertIsNone(watchdog.loader_test_bundle(command))

    def test_actual_binary_host_candidate_is_selected_before_fresh_identity_refusal(self):
        root = self.identity(10)
        host = self.identity(4503, parent=10, group=4503,
                             executable="/toolchain/libexec/swift/pm/swiftpm-testing-helper")
        bundle = Path("/actual/build/OwnedHostObservationTests.xctest")
        command = f"swiftpm-testing-helper --test-bundle-path {bundle}/Contents/MacOS/OwnedHostObservationTests"
        owned = SimpleNamespace(observe=lambda **_: None, live=lambda: [root, host],
                                process=SimpleNamespace(pid=10), commands={4503: command})
        with mock.patch.object(watchdog, "process_identity", return_value=None), \
                mock.patch.object(watchdog.subprocess, "Popen") as launch:
            result = watchdog.sample_helper(owned, Path("/unused"))
        self.assertIn("host PID 4503 (SwiftPM test-bundle loader)", result)
        self.assertIn("sampler refused: target identity unavailable or changed", result)
        self.assertNotIn("driver fallback", result)
        launch.assert_not_called()

    def test_ambiguous_host_candidates_use_driver_fallback(self):
        root, first, second = self.identity(10), self.identity(20), self.identity(30)
        owned = SimpleNamespace(observe=lambda **_: None, live=lambda: [root, first, second],
                                process=SimpleNamespace(pid=10), commands={})
        with mock.patch.object(watchdog, "host_role", side_effect=lambda identity, _: "fixture host" if identity.pid != 10 else None), \
                mock.patch.object(watchdog, "process_identity", return_value=None), \
                mock.patch.object(watchdog.subprocess, "Popen") as launch:
            result = watchdog.sample_helper(owned, Path("/unused"))
        self.assertIn("driver fallback; host attribution unavailable (2 loader candidates)", result)
        launch.assert_not_called()

    def test_partial_native_stream_retains_active_and_last_function_events(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "events.jsonl"
            records = [
                {"kind": "test", "payload": {"kind": "function", "id": "finished"}},
                {"kind": "test", "payload": {"kind": "function", "id": "hanging"}},
                {"kind": "event", "payload": {"kind": "testStarted", "testID": "finished"}},
                {"kind": "event", "payload": {"kind": "testEnded", "testID": "finished"}},
                {"kind": "event", "payload": {"kind": "testStarted", "testID": "hanging"}},
            ]
            path.write_text("\n".join(json.dumps(record) for record in records) + "\n{\"kind\":")
            state = watchdog.native_event_state(path)
        self.assertEqual(state["activeFunctions"], ["hanging"])
        self.assertEqual(state["lastStarted"]["testID"], "hanging")
        self.assertEqual(state["lastCompleted"]["testID"], "finished")
        self.assertEqual(state["partialRecords"], 1)
        self.assertEqual(state["invalidRecords"], 0)

    def test_owned_loader_stream_is_retained_before_cleanup(self):
        with tempfile.TemporaryDirectory(prefix="swiftpm-test-output-") as directory:
            root = Path(directory)
            bundle = root / "GatewayTests.xctest"
            bundle.mkdir()
            events = root / "event-stream-2-GatewayTests.jsonl"
            events.write_text("\n".join(json.dumps(record) for record in [
                {"kind": "test", "payload": {"kind": "function", "id": "completed"}},
                {"kind": "test", "payload": {"kind": "function", "id": "stalled"}},
                {"kind": "event", "payload": {"kind": "testEnded", "testID": "completed"}},
                {"kind": "event", "payload": {"kind": "testStarted", "testID": "stalled"}},
            ]) + "\n")
            identity = watchdog.ProcessIdentity(20, 10, 20, (1,),
                "/toolchain/usr/libexec/swift/pm/swiftpm-testing-helper")
            command = f"helper --test-bundle-path {bundle} --event-stream-output-path {events}"
            owned = SimpleNamespace(live=lambda: [identity], commands={20: command})
            with mock.patch.object(watchdog, "process_identity", return_value=identity):
                receipts = watchdog.retain_bundle_events(owned, root / "retained")
            self.assertEqual(len(receipts), 1)
            self.assertTrue(receipts[0]["available"], receipts)
            self.assertEqual(Path(receipts[0]["retainedPath"]).read_bytes(), events.read_bytes())
            self.assertEqual(Path(receipts[0]["retainedPath"]).stat().st_mode & 0o777, 0o600)
            self.assertEqual((root / "retained").stat().st_mode & 0o777, 0o700)
            self.assertEqual(receipts[0]["nativeEvents"]["lastStarted"]["testID"], "stalled")
            self.assertEqual(receipts[0]["nativeEvents"]["lastCompleted"]["testID"], "completed")

            for invalid in [None, watchdog.ProcessIdentity(20, 10, 20, (2,), identity.executable),
                            watchdog.ProcessIdentity(20, 10, 20, (1,), "/other/helper")]:
                with self.subTest(identity=invalid), \
                        mock.patch.object(watchdog, "process_identity", return_value=invalid):
                    self.assertFalse(watchdog.retain_bundle_events(owned, root / "refused")[0]["available"])
            self.assertFalse((root / "refused").exists())
            with mock.patch.object(watchdog, "process_identity", side_effect=[identity, None]):
                self.assertFalse(watchdog.retain_bundle_events(owned, root / "refused")[0]["available"])

            external = root / "external.jsonl"
            external.write_text(events.read_text())
            for operand in [external, root / "event-stream-2-OtherTests.jsonl",
                            root / ".." / root.name / events.name]:
                owned.commands[20] = f"helper --test-bundle-path {bundle} --event-stream-output-path {operand}"
                with mock.patch.object(watchdog, "process_identity", return_value=identity):
                    self.assertFalse(watchdog.retain_bundle_events(owned, root / "refused")[0]["available"])
            owned.commands[20] = command
            events.unlink()
            events.symlink_to(external)
            with mock.patch.object(watchdog, "process_identity", return_value=identity):
                self.assertFalse(watchdog.retain_bundle_events(owned, root / "refused")[0]["available"])
            owned.live = lambda: []
            self.assertEqual(watchdog.retain_bundle_events(owned, root / "refused"), [])

    def test_loader_stream_directory_swap_cannot_retain_unrelated_events(self):
        for swap_before_directory_open in [True, False]:
            with self.subTest(before_directory_open=swap_before_directory_open), \
                    tempfile.TemporaryDirectory() as fixture, \
                    tempfile.TemporaryDirectory(prefix="swiftpm-test-output-") as directory:
                fixture = Path(fixture)
                root = Path(directory)
                moved = root.with_name(root.name + "-moved")
                bundle = fixture / "GatewayTests.xctest"
                bundle.mkdir()
                events = root / "event-stream-2-GatewayTests.jsonl"
                original_content = b'{"owned": true}\n'
                events.write_bytes(original_content)
                unrelated = fixture / "unrelated"
                unrelated.mkdir()
                (unrelated / events.name).write_bytes(b'{"unrelated": true}\n')
                identity = watchdog.ProcessIdentity(20, 10, 20, (1,),
                    "/toolchain/usr/libexec/swift/pm/swiftpm-testing-helper")
                command = f"helper --test-bundle-path {bundle} --event-stream-output-path {events}"
                owned = SimpleNamespace(live=lambda: [identity], commands={20: command})
                original_open = os.open
                swapped = False

                def swapping_open(path, flags, *args, **kwargs):
                    nonlocal swapped
                    directory_open = bool(flags & os.O_DIRECTORY)
                    if not swapped and (directory_open if swap_before_directory_open
                                        else Path(path).name == events.name):
                        root.rename(moved)
                        root.symlink_to(unrelated, target_is_directory=True)
                        swapped = True
                    return original_open(path, flags, *args, **kwargs)

                try:
                    with mock.patch.object(watchdog.os, "open", side_effect=swapping_open), \
                            mock.patch.object(watchdog, "process_identity", return_value=identity):
                        receipts = watchdog.retain_bundle_events(owned, fixture / "retained")
                    self.assertTrue(swapped, "fixture must swap between validation and file open")
                    self.assertEqual(len(receipts), 1)
                    if swap_before_directory_open:
                        self.assertFalse(receipts[0]["available"], receipts)
                        self.assertFalse((fixture / "retained").exists())
                    else:
                        self.assertTrue(receipts[0]["available"], receipts)
                        self.assertEqual(Path(receipts[0]["retainedPath"]).read_bytes(), original_content)
                finally:
                    if swapped:
                        root.unlink()
                        moved.rename(root)



if __name__ == "__main__":
    unittest.main()
