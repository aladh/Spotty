"""Observe process completion independently of output pipes and bound retained output."""

import unittest
from script_test_fixtures import LifetimeFixtureMixin, PASSING_PYTHON, execute


class ScriptTestOutputLifetimeTests(LifetimeFixtureMixin, unittest.TestCase):
    def test_pipe_owning_descendant_cannot_outlive_successful_parent(self):
        with self.fixture() as root:
            pid = root / "child.pid"
            self.own_pid(pid)
            child = (
                "import os,signal,time\nfrom pathlib import Path\n"
                "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                "Path('child.pid').write_text(str(os.getpid()))\ntime.sleep(60)\n"
            )
            (root / "Scripts/a_test.py").write_text(
                f"import subprocess,sys\nsubprocess.Popen([sys.executable, '-c', {child!r}])\n" + PASSING_PYTHON)
            result = execute(root, "policy", "--timeout-seconds", "1")
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("Scripts/a_test.py timed out", result.stderr)
            self.assertIn("2 Python tests", result.stdout)
            self.assert_stopped(pid)

    def test_closed_pipes_do_not_complete_a_running_worker(self):
        with self.fixture() as root:
            pid = root / "worker.pid"
            self.own_pid(pid)
            (root / "Scripts/a_test.py").write_text(
                "import os,time\nfrom pathlib import Path\n"
                "Path('worker.pid').write_text(str(os.getpid()))\nos.close(1)\nos.close(2)\ntime.sleep(60)\n")
            result = execute(root, "policy", "--timeout-seconds", "1")
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("Scripts/a_test.py timed out", result.stderr)
            self.assert_stopped(pid)

    def test_large_unbroken_output_retains_late_failure_and_replaces_invalid_bytes(self):
        with self.fixture() as root:
            (root / "Scripts/a_test.py").write_text(
                "import os,unittest\nclass Example(unittest.TestCase):\n"
                "    def test_output(self):\n"
                "        for _ in range(48): os.write(1, b'x' * 65536)\n"
                "        os.write(1, b'late-output:\\xff\\n')\n"
                "        self.fail('late assertion failure')\n")
            result = execute(root, "policy")
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("earlier output bytes omitted", result.stdout)
            self.assertIn("late-output:\ufffd", result.stdout)
            self.assertIn("late assertion failure", result.stderr)
            self.assertLess(len(result.stdout.encode()), 1_100_000)

    def test_reporting_failure_cancels_other_active_workers(self):
        with self.fixture() as root:
            pid = root / "worker.pid"
            self.own_pid(pid)
            (root / "Scripts/a_test.py").write_text(
                "import os,time\nfrom pathlib import Path\n"
                "Path('worker.pid').write_text(str(os.getpid()))\ntime.sleep(60)\n")
            (root / "Scripts/b_test.py").write_text(
                "import time\nfrom pathlib import Path\n"
                "Path('writer-ready').touch()\n"
                "while not Path('release-writer').exists(): time.sleep(0.01)\n"
                "print('completed peer', flush=True)\n" + PASSING_PYTHON)
            process = self.start(root, "--jobs", "2")
            self.wait_for_file(pid, process)
            self.wait_for_file(root / "writer-ready", process)
            process.stdout.close()
            (root / "release-writer").touch()
            process.wait(timeout=10)
            self.assertNotEqual(process.returncode, 0)
            self.assert_stopped(pid)


if __name__ == "__main__":
    unittest.main()
