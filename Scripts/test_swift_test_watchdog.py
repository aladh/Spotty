import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


SCRIPT = Path(__file__).with_name("swift_test_watchdog.py")


class SwiftTestWatchdogTests(unittest.TestCase):
    def run_watchdog(self, command, timeout=2, env=None):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        diagnostics = Path(temporary.name)
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--lane", "fixture",
                "--repetition", "1",
                "--timeout-seconds", str(timeout),
                "--log-dir", str(diagnostics),
                "--",
                *command,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            env=env,
            timeout=10,
        )
        return result, diagnostics

    def test_success_is_propagated_and_logged(self):
        result, diagnostics = self.run_watchdog([sys.executable, "-c", "print('passed')"])
        self.assertEqual(result.returncode, 0)
        self.assertIn("passed", result.stdout)
        self.assertIn("status=0", (diagnostics / "fixture-repeat-1.log").read_text())

    def test_nonzero_status_is_propagated(self):
        result, _ = self.run_watchdog([sys.executable, "-c", "raise SystemExit(17)"])
        self.assertEqual(result.returncode, 17)

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
