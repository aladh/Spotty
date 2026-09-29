"""Reject invalid deadlines and bound hung Python and Node invocations."""

import unittest
from script_test_fixtures import LifetimeFixtureMixin, PASSING_PYTHON, execute


class ScriptTestDeadlineTests(LifetimeFixtureMixin, unittest.TestCase):
    def test_invalid_deadlines_fail_before_launch(self):
        with self.fixture() as root:
            marker = root / "launched"
            (root / "Scripts/a_test.py").write_text("from pathlib import Path\nPath('launched').touch()\n" + PASSING_PYTHON)
            for value in ("nan", "inf", "-inf", "0", "-1", "1e999"):
                with self.subTest(value=value):
                    result = execute(root, "policy", f"--timeout-seconds={value}")
                    self.assertEqual(result.returncode, 2)
                    self.assertIn("finite and positive", result.stderr)
                    self.assertFalse(marker.exists())

    def test_hung_python_times_out_and_serially_queued_files_still_run(self):
        with self.fixture() as root:
            (root / "Scripts/a_test.py").write_text("import time\ntime.sleep(60)\n")
            result = execute(root, "policy", "--jobs", "1", "--timeout-seconds", "1")
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("Scripts/a_test.py timed out after 1s", result.stderr)
            self.assertIn("test_example", result.stderr)
            self.assertIn("1 Python tests", result.stdout)

    def test_hung_node_uses_the_same_execution_deadline(self):
        with self.fixture() as root:
            (root / "Scripts/agent-review-tests/review.test.cjs").write_text("setInterval(() => {}, 1000);\n")
            result = execute(root, "review", "--timeout-seconds", "1")
            self.assertEqual(result.returncode, 124, result.stderr)
            self.assertIn("review Node invocation timed out after 1s", result.stderr)


if __name__ == "__main__":
    unittest.main()
