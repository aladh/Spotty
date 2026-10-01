"""Keep the native suite serial while preserving phase products and evidence owners."""
import copy
import re
import unittest

from ci_workflow_fixtures import WorkflowCheck, WorkflowFixtureMixin


class SequentialNativeWorkflowTests(WorkflowFixtureMixin, unittest.TestCase):
    def test_native_runner_is_unique_and_publisher_cannot_overlap_it(self):
        jobs = self.workflow['jobs']
        native = {key for key, job in jobs.items() if job['runs-on'] == 'xcode-27'}
        self.assertEqual(native, {'macos_verify', 'cache_publisher'})
        self.assertIn('macos_verify', jobs['quality_gate']['needs'])
        self.assertEqual(set(jobs['cache_publisher']['needs']), {'quality_gate', 'macos_verify'})
        self.assertNotIn('strategy', jobs['macos_verify'])
        self.check_workflows([WorkflowCheck(self.workflow)])

    def test_every_phase_requires_a_clean_same_revision_checkout_in_order(self):
        checks = []
        for phase in ('engine', 'contracts', 'tests', 'release'):
            for mutation in ('missing', 'dirty', 'retargeted', 'reordered', 'conditional'):
                variant = copy.deepcopy(self.workflow)
                steps = variant['jobs']['macos_verify']['steps']
                step = self.phase_step(variant, phase, 'Check out ' + phase + ' source')
                if mutation == 'missing':
                    steps.remove(step)
                elif mutation == 'dirty':
                    step['with']['clean'] = False
                elif mutation == 'retargeted':
                    step['with']['ref'] = 'main'
                elif mutation == 'conditional':
                    step['if'] = 'success()'
                else:
                    steps.remove(step)
                    steps.append(step)
                checks.append(WorkflowCheck(variant, diagnostic=('phase-local condition' if mutation == 'conditional' and phase != 'engine' else 'checkout'),
                                            label={'phase': phase, 'mutation': mutation}))
        self.check_workflows(checks)

    def test_phase_cache_identities_and_export_order_cannot_cross_configurations(self):
        checks = []
        for phase in ('contracts', 'tests', 'release'):
            for mutation in ('key_output', 'missing_output', 'restore_after_checks', 'export_before_checks'):
                variant = copy.deepcopy(self.workflow)
                native = variant['jobs']['macos_verify']
                steps = native['steps']
                if mutation == 'key_output':
                    other = 'release' if phase != 'release' else 'tests'
                    native['outputs'][phase + '_key'] = '${{ steps.' + other + '_cache.outputs.cache-primary-key }}'
                    diagnostic = 'actual cache identity'
                elif mutation == 'missing_output':
                    native['outputs'].pop(phase + '_key')
                    diagnostic = 'actual cache identity'
                else:
                    target = ('Restore SwiftPM build directory' if mutation == 'restore_after_checks'
                              else 'Export ' + phase + ' cache products')
                    step = self.phase_step(variant, phase, target)
                    command = {'contracts': 'Run Swift contracts', 'tests': 'Run checks',
                               'release': 'Compile release Spotty with SPOTTY_DISTRIBUTION'}[phase]
                    verify = self.phase_step(variant, phase, command)
                    steps.remove(step)
                    steps.insert(steps.index(verify) + (1 if mutation == 'restore_after_checks' else 0), step)
                    diagnostic = ('isolated build products in order' if mutation == 'restore_after_checks'
                                  else 'successful verification')
                checks.append(WorkflowCheck(variant, diagnostic=diagnostic,
                                            label={'phase': phase, 'mutation': mutation}))
        self.check_workflows(checks)

    def test_all_native_outcomes_are_bound_and_timing_artifacts_are_phase_owned(self):
        checks = []
        for name in ('engine_result', 'contracts_result', 'swift_result', 'release_result'):
            variant = copy.deepcopy(self.workflow)
            variant['jobs']['macos_verify']['outputs'][name] = 'success'
            checks.append(WorkflowCheck(variant, diagnostic='actual ' + name))
        variant = copy.deepcopy(self.workflow)
        variant['jobs']['macos_verify']['outputs']['unexpected'] = 'success'
        checks.append(WorkflowCheck(variant, diagnostic='exactly the producer and consumer'))
        for phase, upload_name in (('engine', 'Upload engine timing evidence'),
                                   ('contracts', 'Upload contracts timing evidence'),
                                   ('tests', 'Upload Swift timing evidence'),
                                   ('release', 'Upload Release timing evidence')):
            variant = copy.deepcopy(self.workflow)
            step = self.phase_step(variant, phase, upload_name)
            step['with']['path'] = '${{ runner.temp }}/spotty-timings'
            checks.append(WorkflowCheck(variant, diagnostic='required run-attempt archive'))
        self.check_workflows(checks)

    def test_required_phase_conditions_cannot_skip_or_depend_on_earlier_failures(self):
        checks = []
        for phase in ('contracts', 'tests', 'release'):
            steps = self.workflow['jobs']['macos_verify']['steps']
            start = next(i for i, step in enumerate(steps) if step.get('id') == phase + '_checkout')
            end = next((i for i in range(start + 1, len(steps))
                        if steps[i].get('id', '').endswith('_checkout')), len(steps))
            for original in steps[start:end]:
                if not original.get('if', '').startswith('!cancelled()'):
                    continue
                for condition in (None, 'success()', 'false', 'always()'):
                    variant = copy.deepcopy(self.workflow)
                    step = next(step for step in variant['jobs']['macos_verify']['steps']
                                if step.get('id') == original['id'])
                    if condition is None:
                        step.pop('if')
                    else:
                        step['if'] = condition
                    checks.append(WorkflowCheck(variant, diagnostic='phase-local condition',
                                                label={'id': original['id'], 'condition': condition}))
        self.check_workflows(checks)

    def test_real_guards_restart_after_prior_failure_but_fail_fast_locally(self):
        # Execute the deliberately small guard grammar from the actual workflow, rather than
        # assuming GitHub's default success() is reset by a checkout (it is not).
        steps = self.workflow['jobs']['macos_verify']['steps']
        for failed_phase in ('engine', 'contracts', 'tests'):
            outcomes = {failed_phase + '_checkout': 'failure'}
            for step in steps:
                condition = step.get('if', '')
                if not condition.startswith('!cancelled()') or step.get('id') == 'selection_experiment':
                    continue
                self.assertRegex(condition, r"^!cancelled\(\)(?: && steps\.[a-z0-9_]+\.outcome == 'success')?$")
                dependency = re.search(r'steps\.([a-z0-9_]+)\.outcome', condition)
                allowed = dependency is None or outcomes.get(dependency[1]) == 'success'
                identity = step['id']
                phase = identity.split('_')[0]
                if identity == failed_phase + '_checkout':
                    outcomes[identity] = 'failure'
                else:
                    outcomes[identity] = 'success' if allowed else 'skipped'
                if identity.endswith('_checkout'):
                    self.assertTrue(allowed, identity)
            if failed_phase != 'tests':
                self.assertEqual(outcomes['debug'], 'success')
                self.assertEqual(outcomes['gui'], 'success')
            else:
                self.assertEqual(outcomes['debug'], 'skipped')
            self.assertEqual(outcomes['release'], 'success')

    def test_engine_checkout_exception_cannot_escape_native_job(self):
        checks = []
        for job_id in ('policy', 'domain_linux', 'playback_python', 'cache_publisher'):
            variant = copy.deepcopy(self.workflow)
            step = next(step for step in variant['jobs'][job_id]['steps']
                        if step.get('uses', '').startswith('actions/checkout@'))
            step['id'] = 'engine_checkout'
            step['if'] = "needs.policy.outputs.rust_needed == 'true'"
            checks.append(WorkflowCheck(variant, diagnostic='read-only pinned source contract'))
        self.check_workflows(checks)

    def test_duplicate_evidence_in_another_phase_is_rejected(self):
        checks = []
        for identity in ('gui_upload', 'acceptance_upload', 'selection_upload'):
            variant = copy.deepcopy(self.workflow)
            steps = variant['jobs']['macos_verify']['steps']
            original = next(step for step in steps if step.get('id') == identity)
            steps.append(copy.deepcopy(original))
            checks.append(WorkflowCheck(variant, diagnostic='step IDs must be unique'))
        self.check_workflows(checks)


if __name__ == '__main__':
    unittest.main()
