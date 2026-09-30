"""Protect unconditional script-suite ownership, dependencies and source coverage."""
import copy
import unittest

from ci_workflow_fixtures import WorkflowCheck, WorkflowFixtureMixin


class WorkflowSuiteTests(WorkflowFixtureMixin, unittest.TestCase):
    def test_script_suites_cannot_be_removed_skipped_moved_or_made_optional(self):
        checks = []
        for job_id, command in (
            ('policy', 'npm ci --ignore-scripts --prefix Scripts/agent-review-tests'),
            ('policy', './Scripts/check-source-policy.sh --test-only'),
            ('playback_python', 'python3 -B Scripts/script_tests.py watchdog'),
            ('playback_python', 'python3 -B Scripts/script_tests.py playback'),
            ('playback_python', 'python3 -B Scripts/script_tests.py harness'),
            ('playback_python', './Scripts/format-swift-self-test.sh'),
        ):
            for mutation in ('remove', 'conditional', 'optional', 'move', 'duplicate', 'mask_failure'):
                with self.subTest(command=command, mutation=mutation):
                    variant = copy.deepcopy(self.workflow)
                    job = variant['jobs'][job_id]
                    step = next(s for s in job['steps'] if s.get('run') == command)
                    if mutation in ('remove', 'move'):
                        job['steps'].remove(step)
                        if mutation == 'move':
                            variant['jobs']['macos_contracts']['steps'].append(step)
                    elif mutation == 'conditional':
                        step['if'] = 'false'
                    elif mutation == 'optional':
                        step['continue-on-error'] = True
                    elif mutation == 'duplicate':
                        job['steps'].append(copy.deepcopy(step))
                    else:
                        step['run'] += ' || true'
                    checks.append(WorkflowCheck(variant, diagnostic=job_id, label={'command': command, 'mutation': mutation}))
        for job_id in ('policy', 'playback_python'):
            for key in ('if', 'continue-on-error'):
                with self.subTest(job=job_id, key=key):
                    variant = copy.deepcopy(self.workflow)
                    variant['jobs'][job_id][key] = True
                    checks.append(WorkflowCheck(variant, diagnostic='tests must run unconditionally', label={'job': job_id, 'key': key}))
        self.check_workflows(checks)

    def test_reviewer_dependencies_must_be_installed_before_execution(self):
        checks = []
        variant = copy.deepcopy(self.workflow)
        steps = variant['jobs']['policy']['steps']
        install = next(s for s in steps if s.get('run') == 'npm ci --ignore-scripts --prefix Scripts/agent-review-tests')
        steps.remove(install)
        steps.append(install)
        checks.append(WorkflowCheck(variant, diagnostic='test setup and execution must remain ordered'))
        self.check_workflows(checks)

    def test_source_gate_syntax_check_cannot_be_skipped_or_moved_out_of_policy(self):
        checks = []
        for mutation in ('conditional', 'remove', 'move'):
            with self.subTest(mutation=mutation):
                variant = copy.deepcopy(self.workflow)
                steps = variant['jobs']['policy']['steps']
                scan = next(s for s in steps if s.get('uses', '').startswith('ast-grep/action@'))
                if mutation == 'conditional':
                    scan['if'] = 'false'
                else:
                    steps.remove(scan)
                    if mutation == 'move':
                        variant['jobs']['macos_contracts']['steps'].append(scan)
                checks.append(WorkflowCheck(variant, diagnostic='independent source scan must run once without a condition', label={'mutation': mutation}))
        self.check_workflows(checks)

    def test_source_script_coverage_and_candidate_digest_are_preserved(self):
        checks = []
        cases = [
            ('check-source-policy.sh', 'scan --config sgconfig.yml Sources Backend/spotty-playback Scripts script Tests .github/workflows Package.swift',
             'scan --config sgconfig.yml Sources', 'local source scan must cover'),
            ('check-source-policy.sh', 'python3 -B Scripts/script_tests.py policy', 'true', 'Python policy fixtures'),
            ('check-source-policy.sh', 'npm test --prefix Scripts/agent-review-tests', 'true', 'Python and Node reviewer fixtures'),
            ('check-source-policy.sh', 'python3 -B Scripts/documentation_policy.py', 'true', 'documentation size limits'),
            ('agent-review-tests/package.json', 'python3 -B ../script_tests.py review', 'node --test', 'complete reviewer suite'),
            ('playback-candidate-needed.sh', './Backend/spotty-playback/source-input-digest.sh)',
             'echo stale)', 'compute the engine source input digest'),
            ('playback-candidate-needed.sh', 'echo "candidate_needed=$candidate_needed"',
             'echo "unused=$candidate_needed"', 'publish its decision'),
        ]
        for name, old, new, expected in cases:
            with self.subTest(name=name, old=old):
                checks.append(WorkflowCheck(self.workflow, (name, old, new), diagnostic=expected, label={'name': name, 'old': old}))
        self.check_workflows(checks)
