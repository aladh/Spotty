"""Keep the native GUI lane mandatory, bounded, revision-bound, and evidence-preserving."""
import copy
import unittest

from ci_workflow_fixtures import WorkflowCheck, WorkflowFixtureMixin


class WorkflowGUITests(WorkflowFixtureMixin, unittest.TestCase):
    def test_gui_execution_and_evidence_cannot_be_optional_or_retried(self):
        checks = []
        for identity in ('gui', 'gui_upload'):
            for mutation in ('remove', 'conditional', 'optional', 'duplicate', 'move', 'mask_failure'):
                variant = copy.deepcopy(self.workflow)
                steps = variant['jobs']['macos_swift']['steps']
                step = next(item for item in steps if item.get('id') == identity)
                if mutation == 'remove':
                    steps.remove(step)
                elif mutation == 'conditional':
                    step['if'] = 'success()'
                elif mutation == 'optional':
                    step['continue-on-error'] = True
                elif mutation == 'duplicate':
                    steps.append(copy.deepcopy(step))
                elif mutation == 'move':
                    steps.remove(step)
                    steps.insert(0, step)
                elif 'run' in step:
                    step['run'] += ' || true'
                else:
                    step['with']['if-no-files-found'] = 'warn'
                checks.append(WorkflowCheck(variant, diagnostic='GUI regression',
                                            label={'step': identity, 'mutation': mutation}))
        self.check_workflows(checks)

    def test_gui_binding_deadline_and_original_artifacts_are_required(self):
        checks = []
        for mutation in ('revision', 'deadline', 'artifact_attempt', 'artifact_path', 'fabricated', 'ignored', 'missing_gui', 'missing_upload', 'before_acceptance'):
            variant = copy.deepcopy(self.workflow)
            steps = variant['jobs']['macos_swift']['steps']
            run = next(item for item in steps if item.get('id') == 'gui')
            upload = next(item for item in steps if item.get('id') == 'gui_upload')
            gate = next(item for item in steps if item['name'] == 'Require Swift test evidence')
            if mutation == 'revision':
                run['env']['GUI_REVISION'] = 'HEAD'
            elif mutation == 'deadline':
                run.pop('timeout-minutes')
            elif mutation == 'artifact_attempt':
                upload['with']['name'] = 'gui-regression-${{ github.run_id }}'
            elif mutation == 'artifact_path':
                upload['with']['path'] += '/summary.json'
            elif mutation == 'fabricated':
                gate['env']['GUI_RESULT'] = 'success'
            elif mutation == 'missing_gui':
                gate['env'].pop('GUI_RESULT')
            elif mutation == 'missing_upload':
                gate['env'].pop('GUI_UPLOAD_RESULT')
            elif mutation == 'before_acceptance':
                steps.remove(run)
                steps.insert(steps.index(next(item for item in steps if item.get('id') == 'acceptance')), run)
            else:
                gate['run'] = gate['run'].replace('test "$GUI_UPLOAD_RESULT" = success', 'true')
            checks.append(WorkflowCheck(variant, diagnostic='GUI regression', label={'mutation': mutation}))
        self.check_workflows(checks)
