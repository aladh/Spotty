"""Prove discovery, suite ownership, and failure propagation with disposable repositories."""

import contextlib
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tempfile
import unittest

from script_tests import inventory, is_test


ROOT = Path(__file__).resolve().parents[1]
PASSING_PYTHON = "import unittest\nclass Example(unittest.TestCase):\n    def test_example(self):\n        self.assertTrue(True)\n"
PASSING_NODE = "const {test} = require('node:test'); test('example', () => {});\n"


@contextlib.contextmanager
def repository():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        for name in ("Scripts/test_existing_policy.py", "Scripts/test_playback_existing.py",
                     "Scripts/test_harness_existing.py",
                     "Scripts/test_swift_test_watchdog.py", "Scripts/agent-review-tests/publication_test.py"):
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(PASSING_PYTHON)
        (root / "Scripts/agent-review-tests/review.test.cjs").write_text(PASSING_NODE)
        shutil.copy(ROOT / "Scripts/script_tests.py", root / "Scripts/script_tests.py")
        yield root


def execute(root, group):
    return subprocess.run([sys.executable, "-B", str(root / "Scripts/script_tests.py"), group],
                          cwd=root, capture_output=True, text=True)


class ScriptTestCoverageTests(unittest.TestCase):
    def test_python_test_names_have_explicit_boundaries(self):
        for name in ("test.py", "test_feature.py", "feature_test.py", "test_helpers.py"):
            with self.subTest(name=name):
                self.assertTrue(is_test(PurePosixPath(name)))
        for name in ("testing_helper.py", "testimony.py", "helpers.py", "script_tests.py"):
            with self.subTest(name=name):
                self.assertFalse(is_test(PurePosixPath(name)))

    def test_current_repository_has_exactly_one_owner_per_test(self):
        groups = inventory(ROOT)
        files = [path for paths in groups.values() for path in paths]
        self.assertEqual(len(files), len(set(files)))
        self.assertIn(ROOT / "Scripts/test_documentation_policy.py", groups["policy"])
        for name in ("profile_synthetic", "trace_summary", "browsing_provenance"):
            self.assertIn(ROOT / f"Scripts/test_harness_{name}.py", groups["harness"])
        self.assertIn(ROOT / "Scripts/agent-review-tests/publication_test.py", groups["review"])
        self.assertIn(ROOT / "Scripts/agent-review-tests/review.test.mjs", groups["review"])

    def test_new_python_tests_run_without_policy_suffix_or_registration(self):
        with repository() as root:
            for name in ("test_new_feature.py", "another_test.py", "test.py"):
                (root / "Scripts" / name).write_text(PASSING_PYTHON)
            result = execute(root, "policy")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Ran 4 tests", result.stderr)
            self.assertIn("Scripts/test_new_feature.py", result.stdout)
            (root / "Scripts/test_new_feature.py").write_text(PASSING_PYTHON.replace("assertTrue(True)", "fail('new test ran')"))
            result = execute(root, "policy")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("new test ran", result.stderr)

    def test_new_node_tests_run_and_fail_the_review_suite(self):
        with repository() as root:
            (root / "Scripts/agent-review-tests/new.spec.cjs").write_text(PASSING_NODE)
            result = execute(root, "review")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Ran 1 test", result.stderr)  # Python publication tests also ran.
            (root / "Scripts/agent-review-tests/new.spec.cjs").write_text(
                "const {test} = require('node:test'); test('new failure', () => { throw Error('node test ran'); });\n")
            result = execute(root, "review")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("node test ran", result.stdout)

    def test_harness_helpers_have_an_independent_failing_owner(self):
        with repository() as root:
            path = root / "Scripts/test_harness_new.py"
            path.write_text(PASSING_PYTHON.replace("assertTrue(True)", "fail('harness test ran')"))
            groups = inventory(root)
            self.assertIn(path, groups["harness"])
            self.assertNotIn(path, groups["playback"])
            self.assertNotIn(path, groups["policy"])
            result = execute(root, "harness")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("harness test ran", result.stderr)
            self.assertEqual(execute(root, "playback").returncode, 0)

    def test_tests_outside_owned_roots_or_in_unsupported_languages_fail(self):
        for name in ("Scripts/nested/test_hidden.py", "Tools/test_new.py",
                     "Scripts/agent-review-tests/nested/hidden.test.js", "Scripts/agent-review-tests/new.test.ts"):
            with self.subTest(name=name), repository() as root:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("")
                with self.assertRaisesRegex(ValueError, "No CI script-test owner"):
                    inventory(root)

    def test_empty_suites_and_zero_python_discovery_fail(self):
        with repository() as root:
            (root / "Scripts/agent-review-tests/review.test.cjs").unlink()
            with self.assertRaisesRegex(ValueError, "both Python and Node"):
                inventory(root)
        with repository() as root:
            (root / "Scripts/test_existing_policy.py").unlink()
            with self.assertRaisesRegex(ValueError, "suite policy is empty"):
                inventory(root)
        with repository() as root:
            (root / "Scripts/test_existing_policy.py").write_text("# No tests\n")
            result = execute(root, "policy")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("No Python tests discovered in Scripts/test_existing_policy.py", result.stderr)

    def test_tracked_and_new_tests_are_checked_but_ignored_scratch_and_vendor_are_not(self):
        with repository() as root:
            subprocess.run(["git", "add", "Scripts/test_existing_policy.py"], cwd=root, check=True)
            (root / ".gitignore").write_text("Scripts/test_existing_policy.py\nscratch/\n")
            for name in ("scratch/test_local.py", "Backend/spotty-playback/vendor/librespot/test_upstream.py"):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("")
            groups = inventory(root)
            self.assertIn(root / "Scripts/test_existing_policy.py", groups["policy"])
            self.assertEqual(sum(map(len, groups.values())), 6)


if __name__ == "__main__":
    unittest.main()
