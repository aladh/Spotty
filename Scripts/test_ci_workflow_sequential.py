"""Keep the native suite serial while preserving phase products and evidence owners."""
import copy
import unittest

from ci_workflow_fixtures import WorkflowCheck, WorkflowFixtureMixin


class SequentialNativeWorkflowTests(WorkflowFixtureMixin, unittest.TestCase):
    def test_native_runner_is_unique_and_publisher_cannot_overlap_it(self):
        jobs = self.workflow['jobs']
        native = {key for key, job in jobs.items() if job['runs-on'] == 'macos-26'}
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
                checks.append(WorkflowCheck(variant, diagnostic='checkout',
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
