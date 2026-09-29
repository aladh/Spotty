"""Keep the file-loading and exit-status contract at the real workflow-check entrance."""
import copy
import subprocess
import unittest

from ci_workflow_fixtures import WorkflowFixtureMixin


class WorkflowCLITests(WorkflowFixtureMixin, unittest.TestCase):
    def test_default_and_explicit_acceptance_paths_use_the_complete_policy(self):
        for default in (False, True):
            with self.subTest(default=default):
                result = self.run_cli(self.workflow, default_acceptance=default)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, 'CI workflow invariants passed\n')
                self.assertEqual(result.stderr, '')
                acceptance = copy.deepcopy(self.acceptance_workflow)
                acceptance['permissions']['contents'] = 'write'
                result = self.run_cli(self.workflow, acceptance_workflow=acceptance, default_acceptance=default)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')
                self.assertEqual(result.stderr, 'CI invariant: standalone acceptance must have read-only contents permissions\n')

    def test_policy_failure_prints_ordered_diagnostics_and_fails(self):
        workflow = copy.deepcopy(self.workflow)
        workflow['jobs']['macos']['runs-on'] = 'macos-latest'
        workflow['jobs']['macos']['name'] = 'Other name'
        result = self.run_cli(workflow)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertEqual(result.stderr, 'CI invariant: macOS image must remain macos-26\n'
                         'CI invariant: required aggregate must retain the macOS checks name\n')

    def test_companion_assets_are_read_beside_the_entry_script(self):
        for edit, diagnostic in [
            (('check-source-policy.sh', 'python3 -B Scripts/documentation_policy.py', 'true'), 'documentation size limits'),
            (('playback-candidate-needed.sh', './Backend/spotty-playback/source-input-digest.sh)', 'echo stale)'),
             'compute the engine source input digest'),
            (('agent-review-tests/package.json', 'python3 -B ../script_tests.py review', 'node --test'),
             'complete reviewer suite'),
        ]:
            with self.subTest(asset=edit[0]):
                result = self.run_cli(self.workflow, script_edit=edit)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(diagnostic, result.stderr)
        self.assertEqual(self.run_cli(self.workflow).returncode, 0, 'Edited fixtures must not contaminate later calls')

    def test_missing_malformed_or_incomplete_workflow_never_passes(self):
        for content in (None, 'jobs: [', '{}'):
            with self.subTest(content=content):
                path = self.fixture_root / 'invalid.yml'
                if content is not None:
                    path.write_text(content)
                result = subprocess.run(
                    ['ruby', str(self.scripts / 'check-ci-workflow.rb'), str(path), str(path)],
                    text=True, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')
                self.assertTrue(result.stderr)
