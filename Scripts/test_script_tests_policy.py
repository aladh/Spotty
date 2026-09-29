"""Prove discovery, suite ownership, and isolated dispatch with disposable repositories."""

from pathlib import PurePosixPath
import subprocess
import unittest

from script_test_fixtures import ROOT, PASSING_PYTHON, PASSING_NODE, repository, execute
from script_tests import inventory, is_test


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
            self.assertEqual(result.stderr.count("Ran 1 test"), 4)
            self.assertIn("Scripts/test_new_feature.py", result.stdout)
            (root / "Scripts/test_new_feature.py").write_text(PASSING_PYTHON.replace("assertTrue(True)", "fail('new test ran')"))
            result = execute(root, "policy")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("new test ran", result.stderr)

    def test_python_files_do_not_share_process_globals_even_when_run_serially(self):
        with repository() as root:
            (root / "Scripts/a_test.py").write_text(
                "import builtins, os, unittest\nfrom pathlib import Path\n"
                "class Example(unittest.TestCase):\n"
                "    def test_example(self):\n"
                "        builtins.spotty_test_leak = True\n"
                "        Path('a.pid').write_text(str(os.getpid()))\n")
            (root / "Scripts/b_test.py").write_text(
                "import builtins, os, unittest\nfrom pathlib import Path\n"
                "class Example(unittest.TestCase):\n"
                "    def test_example(self):\n"
                "        self.assertFalse(hasattr(builtins, 'spotty_test_leak'))\n"
                "        Path('b.pid').write_text(str(os.getpid()))\n")
            result = execute(root, "policy", "--jobs", "1")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotEqual((root / "a.pid").read_text(), (root / "b.pid").read_text())

    def test_independent_files_can_make_progress_together(self):
        with repository() as root:
            for name, peer in (("a", "b"), ("b", "a")):
                (root / f"Scripts/{name}_test.py").write_text(
                    "import time, unittest\nfrom pathlib import Path\n"
                    "class Example(unittest.TestCase):\n"
                    "    def test_example(self):\n"
                    f"        Path('{name}.ready').touch()\n"
                    "        deadline = time.monotonic() + 5\n"
                    f"        while not Path('{peer}.ready').exists() and time.monotonic() < deadline:\n"
                    "            time.sleep(0.01)\n"
                    f"        self.assertTrue(Path('{peer}.ready').exists(), 'peer worker was starved')\n")
            result = execute(root, "policy", "--jobs", "2")
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_worker_crash_fails_the_lane_and_other_discovered_files_still_run(self):
        for status in (0, 17):
            with self.subTest(status=status), repository() as root:
                (root / "Scripts/a_test.py").write_text(f"import os\nos._exit({status})\n")
                result = execute(root, "policy")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("did not complete its tests" if status == 0 else "exited 17", result.stderr)
                self.assertIn("test_example", result.stderr)

    def test_worker_cannot_select_a_file_outside_its_lane(self):
        with repository() as root:
            result = execute(root, "policy", "--test-file", str(root / "Scripts/test_playback_existing.py"))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must belong", result.stderr)

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

    def test_non_utf8_index_entry_preserves_discovery_and_test_failures(self):
        with repository() as root:
            blob = subprocess.check_output(["git", "hash-object", "-w", "--stdin"], cwd=root, input=b"fixture\n").strip()
            subprocess.run(["git", "update-index", "-z", "--index-info"], cwd=root, check=True,
                           input=b"100644 " + blob + b"\tunknown-\xff\0")
            test = root / "Scripts/test_new\nfeature.py"
            test.write_text(PASSING_PYTHON.replace("assertTrue(True)", "fail('newline test ran')"))
            groups = inventory(root)
            self.assertEqual(sum(map(len, groups.values())), 7)
            self.assertIn(test, groups["policy"])
            result = execute(root, "policy")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("newline test ran", result.stderr)
            self.assertIn("Scripts/test_existing_policy.py", result.stdout)

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
