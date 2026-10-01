"""Protect acceptance execution and evidence in both workflow entrances."""
import copy
import unittest

from ci_workflow_fixtures import WorkflowCheck, WorkflowFixtureMixin


class WorkflowAcceptanceTests(WorkflowFixtureMixin, unittest.TestCase):
    def test_acceptance_corpus_and_evidence_cannot_be_skipped_or_made_optional(self):
        checks = []
        for standalone in (False, True):
            for step_id in ('acceptance', 'acceptance_summary', 'acceptance_upload'):
                for mutation in ('remove', 'conditional', 'optional', 'duplicate', 'mask_failure', 'move'):
                    with self.subTest(standalone=standalone, step=step_id, mutation=mutation):
                        variant = copy.deepcopy(self.acceptance_workflow if standalone else self.workflow)
                        job = variant['jobs']['acceptance' if standalone else 'macos_verify']
                        step = next(s for s in job['steps'] if s.get('id') == step_id)
                        if mutation == 'remove':
                            job['steps'].remove(step)
                        elif mutation == 'conditional':
                            step['if'] = 'success()'
                        elif mutation == 'optional':
                            step['continue-on-error'] = True
                        elif mutation == 'duplicate':
                            job['steps'].insert(job['steps'].index(step) + 1, copy.deepcopy(step))
                        elif mutation == 'move':
                            job['steps'].remove(step)
                            job['steps'].append(step)
                        elif 'run' in step:
                            step['run'] += ' || true'
                        else:
                            step['with']['if-no-files-found'] = 'warn'
                        checks.append(WorkflowCheck(self.workflow, acceptance_workflow=variant, diagnostic='acceptance', label={'standalone': standalone, 'step': step_id, 'mutation': mutation}) if standalone else WorkflowCheck(variant, diagnostic='acceptance', label={'standalone': standalone, 'step': step_id, 'mutation': mutation}))
        self.check_workflows(checks)

    def test_acceptance_gate_rejects_fabricated_missing_or_ignored_outcomes(self):
        checks = []
        for standalone in (False, True):
            for binding in ('ACCEPTANCE_RESULT', 'ACCEPTANCE_SUMMARY_RESULT', 'ACCEPTANCE_UPLOAD_RESULT'):
                for mutation in ('fabricated', 'missing', 'ignored'):
                    with self.subTest(standalone=standalone, binding=binding, mutation=mutation):
                        variant = copy.deepcopy(self.acceptance_workflow if standalone else self.workflow)
                        job = variant['jobs']['acceptance' if standalone else 'macos_verify']
                        gate = next(s for s in job['steps'] if s['name'] in (
                            'Require Swift test evidence', 'Require acceptance evidence'))
                        if mutation == 'fabricated':
                            gate['env'][binding] = 'success'
                        elif mutation == 'missing':
                            gate['env'].pop(binding)
                        else:
                            gate['run'] = gate['run'].replace(f'test "${binding}" = success', 'true')
                        checks.append(WorkflowCheck(self.workflow, acceptance_workflow=variant, diagnostic=f'require {binding} success', label={'standalone': standalone, 'binding': binding, 'mutation': mutation}) if standalone else WorkflowCheck(variant, diagnostic=f'require {binding} success', label={'standalone': standalone, 'binding': binding, 'mutation': mutation}))
        self.check_workflows(checks)

    def test_acceptance_workflow_is_bounded_explicit_and_read_only(self):
        checks = []
        cases = ('job_timeout', 'step_timeout', 'fanout', 'matrix', 'retry', 'permissions', 'trigger', 'head',
                 'artifact_attempt', 'artifact_path', 'holdouts')
        for mutation in cases:
            with self.subTest(mutation=mutation):
                variant = copy.deepcopy(self.acceptance_workflow)
                job = variant['jobs']['acceptance']
                run = next(s for s in job['steps'] if s.get('id') == 'acceptance')
                upload = next(s for s in job['steps'] if s.get('id') == 'acceptance_upload')
                if mutation == 'job_timeout':
                    job.pop('timeout-minutes')
                elif mutation == 'step_timeout':
                    run['timeout-minutes'] = 30
                elif mutation == 'fanout':
                    variant['jobs']['retry'] = copy.deepcopy(job)
                elif mutation == 'matrix':
                    job['strategy'] = {'matrix': {'attempt': [1, 2]}}
                elif mutation == 'retry':
                    retry = copy.deepcopy(run)
                    retry['id'] = 'acceptance_retry'
                    retry['name'] = 'Retry scenarios'
                    job['steps'].append(retry)
                elif mutation == 'permissions':
                    variant['permissions']['contents'] = 'write'
                elif mutation == 'trigger':
                    variant['on']['pull_request'] = None
                elif mutation == 'head':
                    run['env']['SPOTTY_ACCEPTANCE_HEAD_SHA'] = 'HEAD'
                elif mutation == 'artifact_attempt':
                    upload['with']['name'] = 'acceptance-evidence-${{ github.run_id }}'
                elif mutation == 'artifact_path':
                    upload['with']['path'] += '/summary.json'
                else:
                    run['run'] = run['run'].replace('--corpus all', '--corpus representative')
                checks.append(WorkflowCheck(self.workflow, acceptance_workflow=variant, diagnostic='acceptance', label={'mutation': mutation}))
        self.check_workflows(checks)

    def test_acceptance_execution_remains_after_swift_checks_in_existing_lane(self):
        checks = []
        variant = copy.deepcopy(self.workflow)
        steps = variant['jobs']['macos_verify']['steps']
        acceptance = next(s for s in steps if s.get('id') == 'acceptance')
        steps.remove(acceptance)
        steps.insert(0, acceptance)
        checks.append(WorkflowCheck(variant, diagnostic='after Swift checks in its owning lane'))
        self.check_workflows(checks)
