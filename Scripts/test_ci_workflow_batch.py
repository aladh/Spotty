"""A failed or incomplete batch must never appear to validate every workflow variant."""
import json
import subprocess
import unittest
from unittest.mock import patch

from ci_workflow_fixtures import WorkflowCheck, WorkflowFixtureMixin


class WorkflowBatchTests(WorkflowFixtureMixin, unittest.TestCase):
    def test_missing_duplicate_reordered_or_malformed_results_fail(self):
        checks = [WorkflowCheck(self.workflow), WorkflowCheck(self.workflow)]
        valid = [{'id': 0, 'errors': []}, {'id': 1, 'errors': []}]
        for output in [[], valid[:1], valid + valid[:1], valid[::-1], valid[:1] * 2, [{'id': False, 'errors': []}, valid[1]],
                       [{'id': 0, 'errors': 'wrong'}, valid[1]],
                       [{'id': 0, 'errors': [False]}, valid[1]], {}, [None, valid[1]]]:
            with self.subTest(output=output):
                result = subprocess.CompletedProcess([], 0, stdout=json.dumps(output), stderr='')
                with patch('ci_workflow_fixtures.subprocess.run', return_value=result):
                    with self.assertRaises(AssertionError):
                        self.validate_workflows(checks)
        with patch('ci_workflow_fixtures.subprocess.run', return_value=subprocess.CompletedProcess([], 0, stdout='{')):
            with self.assertRaises(json.JSONDecodeError):
                self.validate_workflows(checks)

    def test_failed_worker_and_empty_batch_are_failures(self):
        with patch('ci_workflow_fixtures.subprocess.run', side_effect=subprocess.CalledProcessError(1, ['ruby'])):
            with self.assertRaises(subprocess.CalledProcessError):
                self.validate_workflows([WorkflowCheck(self.workflow)])
        with self.assertRaises(AssertionError):
            self.validate_workflows([])

    def test_case_retains_the_inputs_at_construction(self):
        workflow = {'jobs': {}}
        acceptance = {'jobs': {}}
        check = WorkflowCheck(workflow, acceptance_workflow=acceptance)
        workflow['jobs']['later'] = {}
        acceptance['jobs']['later'] = {}
        self.assertEqual(check.workflow, {'jobs': {}})
        self.assertEqual(check.acceptance_workflow, {'jobs': {}})
