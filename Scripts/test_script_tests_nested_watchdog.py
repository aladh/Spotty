"""Allow nested watchdogs to finish cleanup of their own process groups."""

import unittest
import signal

from script_test_fixtures import LifetimeFixtureMixin, ROOT


class ScriptTestNestedWatchdogTests(LifetimeFixtureMixin, unittest.TestCase):
    def test_nested_watchdog_finishes_its_own_group_cleanup_on_interruption(self):
        self.check_nested_watchdog(silent=False)

    def test_redirected_nested_watchdog_finishes_its_own_group_cleanup(self):
        self.check_nested_watchdog(silent=True)

    def check_nested_watchdog(self, silent):
        with self.fixture() as root:
            pid = root / "nested.pid"
            self.own_pid(pid)
            command = (
                "import os,signal,time\nfrom pathlib import Path\n"
                "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                "Path('nested.pid').write_text(str(os.getpid()))\ntime.sleep(60)\n"
            )
            watchdog = ROOT / "Scripts/swift_test_watchdog.py"
            redirect = ", stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL" if silent else ""
            (root / "Scripts/a_test.py").write_text(
                "import subprocess,sys\n"
                f"subprocess.run([sys.executable, {str(watchdog)!r}, '--lane', 'nested', '--repetition', '1', "
                f"'--timeout-seconds', '60', '--log-dir', 'diagnostics', '--', sys.executable, '-c', {command!r}]{redirect})\n")
            process = self.start(root)
            self.wait_for_file(pid, process)
            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 143, stdout + stderr)
            self.assertIn("status=143", (root / "diagnostics/nested-repeat-1.log").read_text())
            self.assert_stopped(pid)


if __name__ == "__main__":
    unittest.main()
