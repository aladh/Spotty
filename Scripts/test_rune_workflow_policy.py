"""Exercise both workflow paths through the checked-in Ruby policy command."""
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class RuneWorkflowPolicyTests(unittest.TestCase):
    def check(self, workflow_edit=None, acceptance_edit=None):
        with tempfile.TemporaryDirectory(prefix="spotty workflow ") as directory:
            target = Path(directory)
            for name, edit in (("ci.yml", workflow_edit), ("acceptance-scenarios.yml", acceptance_edit)):
                original = (ROOT / ".github" / "workflows" / name).read_text()
                if edit is not None:
                    before, after = edit
                    self.assertIn(before, original)
                    original = original.replace(before, after, 1)
                (target / name).write_text(original)
            return subprocess.run(
                ["ruby", ROOT / "Scripts/check-ci-workflow.rb", target / "ci.yml",
                 target / "acceptance-scenarios.yml"], text=True, capture_output=True, timeout=10,
            )

    def test_both_current_workflows_pass(self):
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_linux_and_apple_cannot_drop_the_required_source_job(self):
        for lane, name in (("linux", "Linux tests and synthetic UI"), ("apple", "Apple Silicon verification")):
            with self.subTest(lane=lane):
                prefix = f"name: {name}\n    needs: "
                result = self.check(workflow_edit=(prefix + "policy", prefix + "[]"))
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn(f"CI {lane} must depend on source policy", result.stderr)

    def test_ci_keeps_the_main_push_and_pull_request_triggers(self):
        for edit in (("branches: [main]", "branches: [preview]"), ("  pull_request:\n", "")):
            with self.subTest(edit=edit):
                result = self.check(workflow_edit=edit)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("CI must run for main pushes and pull requests", result.stderr)

    def test_standalone_permission_cannot_allow_writes(self):
        for edit in (("contents: read", "contents: write"),
                     ("    runs-on: ubuntu-latest", "    permissions: { contents: write }\n    runs-on: ubuntu-latest")):
            with self.subTest(edit=edit):
                result = self.check(acceptance_edit=edit)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("standalone acceptance must keep the repository token read-only", result.stderr)

    def test_the_standalone_workflow_requires_the_real_artifact_upload_result(self):
        result = self.check(acceptance_edit=('test "$ACCEPTANCE_UPLOAD_RESULT" = success', "true"))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("must publish and require both corpus and artifact outcomes", result.stderr)

    def test_both_jobs_preserve_evidence_when_scenarios_fail(self):
        edit = ("if: always()", "if: success()")
        for edits in ({"workflow_edit": edit}, {"acceptance_edit": edit}):
            with self.subTest(edits=edits):
                result = self.check(**edits)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("must upload the run-attempt evidence even on failure", result.stderr)


if __name__ == "__main__":
    unittest.main()
