"""Preserve interruption status while cleaning up only owned workers."""

import unittest
import signal
import subprocess
import sys

from script_test_fixtures import LifetimeFixtureMixin, PASSING_PYTHON


class ScriptTestInterruptionTests(LifetimeFixtureMixin, unittest.TestCase):
    def test_signals_stop_active_workers_without_admitting_queued_files(self):
        for interrupt in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(interrupt=interrupt), self.fixture() as root:
                for name in ("a", "b"):
                    self.own_pid(root / f"{name}.pid")
                    (root / f"Scripts/{name}_test.py").write_text(
                        "import os,time\nfrom pathlib import Path\n"
                        f"Path('{name}.pid').write_text(str(os.getpid()))\ntime.sleep(60)\n")
                (root / "Scripts/z_test.py").write_text(
                    "from pathlib import Path\nPath('queued').touch()\n" + PASSING_PYTHON)
                sentinel = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], start_new_session=True)
                try:
                    process = self.start(root, "--jobs", "2")
                    for name in ("a", "b"):
                        self.wait_for_file(root / f"{name}.pid", process)
                    process.send_signal(interrupt)
                    stdout, stderr = process.communicate(timeout=10)
                    self.assertEqual(process.returncode, 128 + interrupt, stdout + stderr)
                    for name in ("a", "b"):
                        self.assert_stopped(root / f"{name}.pid")
                    self.assertFalse((root / "queued").exists())
                    self.assertIsNone(sentinel.poll(), "cleanup must only signal owned groups")
                finally:
                    sentinel.kill()
                    sentinel.wait(timeout=5)

    def test_repeated_signals_preserve_the_first_status_and_finish_cleanup(self):
        with self.fixture() as root:
            pid = root / "worker.pid"
            self.own_pid(pid)
            (root / "Scripts/a_test.py").write_text(
                "import os,signal,time\nfrom pathlib import Path\n"
                "signal.signal(signal.SIGTERM, lambda *_: Path('cleanup-started').touch())\n"
                "Path('worker.pid').write_text(str(os.getpid()))\ntime.sleep(60)\n")
            process = self.start(root)
            self.wait_for_file(pid, process)
            process.send_signal(signal.SIGTERM)
            self.wait_for_file(root / "cleanup-started", process)
            process.send_signal(signal.SIGINT)
            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 143, stdout + stderr)
            self.assert_stopped(pid)

    def test_interruption_status_survives_a_closed_output_sink(self):
        with self.fixture() as root:
            pid = root / "worker.pid"
            self.own_pid(pid)
            (root / "Scripts/a_test.py").write_text(
                "import os,time\nfrom pathlib import Path\n"
                "Path('worker.pid').write_text(str(os.getpid()))\ntime.sleep(60)\n")
            process = self.start(root)
            self.wait_for_file(pid, process)
            process.stdout.close()
            process.send_signal(signal.SIGTERM)
            process.wait(timeout=10)
            self.assertEqual(process.returncode, 143, process.stderr.read())
            self.assert_stopped(pid)


if __name__ == "__main__":
    unittest.main()
