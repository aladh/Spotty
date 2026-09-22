"""Two-layout workflow orchestration uses fake existing launchers and owned processes."""
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import compare_synthetic_profiles
import profile_synthetic as profile

class LayoutWorkflowTests(unittest.TestCase):
    def test_prepares_both_variants_then_records_compares_and_terminates_only_owned(self):
        self.exercise(0)

    def test_second_capture_failure_preserves_invalid_result_and_owned_cleanup(self):
        self.exercise(1)

    def test_second_capture_preserves_precise_profiler_failure(self):
        self.exercise(1, status_code='trace-export-failed')

    def exercise(self, second_returncode, status_code=None):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            project = root / 'project'
            (project / 'Scripts').mkdir(parents=True)
            output = root / 'comparison'
            source = root / 'scenario.json'
            source.write_text('{"version":1,"trackCount":100}')
            calls = []

            def launch(command, *, cwd, env, timeout):
                index = len(calls)
                calls.append(command)
                for label, expected in (('synchronous', True), ('scheduled', False)):
                    fixture = json.loads((output / f'{label}.json').read_text())
                    self.assertEqual(fixture, {'version': 1, 'trackCount': 100, 'forceSynchronousLayout': expected})
                run_root = project / '.build/browsing-runs' / f'run{index}'
                run_root.mkdir(parents=True)
                profile.write_json(run_root / 'manifest.json', {'runID': f'run{index}'})
                profile.write_json(run_root / 'process.json', {'runID': f'run{index}', 'pid': index + 10, 'startIdentity':'synthetic', 'executable':'/SyntheticDemo'})
                if index and status_code:
                    profile.write_json(run_root / 'profiler-state.json', {
                        'schemaVersion': 1, 'state': 'failed', 'failureCode': status_code, 'runID': f'run{index}',
                    })
                Path(env['SPOTTY_BROWSING_RUN_ROOT_FILE']).write_text(str(run_root))
                return SimpleNamespace(returncode=second_returncode if index else 0)

            with patch.object(profile, '__file__', str(project / 'Scripts/profile_synthetic.py')), patch.object(profile.subprocess, 'run', side_effect=launch), patch.object(profile.browsing_process, 'terminate') as terminate, patch.object(compare_synthetic_profiles, 'compare', return_value={'schemaVersion':1,'classification':'comparable','reasonCodes':[]}) as compare:
                result = profile.compare_layouts(source, output)
            self.assertEqual(len(calls), 2)
            self.assertEqual([call.args[0]['pid'] for call in terminate.call_args_list], [10, 11])
            self.assertEqual(json.loads((output / 'comparison.json').read_text()), result)
            if second_returncode:
                compare.assert_not_called()
                self.assertEqual(result['classification'], 'invalid')
                self.assertEqual(result['reasonCodes'][0], f'right.{status_code or "capture-incomplete"}')
                self.assertIn('right.report-missing', result['reasonCodes'])
                self.assertEqual(result['failedCapture'], {'side': 'right', 'variant': 'scheduled'})
                self.assertEqual(set(result['runRoots']), {'synchronous', 'scheduled'})
            else:
                self.assertEqual(result['classification'], 'comparable')
                self.assertEqual(compare.call_args.args[2], 'layout.forceSynchronousLayout')

    def test_output_never_changes_relevant_source_between_variants(self):
        with TemporaryDirectory() as directory:
            project = Path(directory)
            with patch.object(profile, '__file__', str(project / 'Scripts/profile_synthetic.py')):
                with self.assertRaisesRegex(ValueError, 'ignored .build'):
                    profile.compare_layouts(project / 'input.json', project / 'output')
            self.assertFalse((project / 'output').exists())

    def test_capture_failure_retains_side_stage_and_missing_evidence(self):
        for side, code, has_manifest in (
            ('left', 'session-locked', False), ('right', 'trace-export-failed', True),
        ):
            with self.subTest(side=side, code=code), TemporaryDirectory() as directory:
                root = Path(directory)
                status = {'schemaVersion': 1, 'state': 'failed', 'failureCode': code}
                if has_manifest:
                    profile.write_json(root / 'manifest.json', {'runID': 'synthetic-run'})
                    status['runID'] = 'synthetic-run'
                profile.write_json(root / 'profiler-state.json', status)
                codes, failures = profile.capture_diagnostics(root, side, profile.InvalidRun('capture-incomplete'))
                self.assertEqual(codes[0], f'{side}.{code}')
                self.assertIn(f'{side}.report-missing', codes)
                self.assertIn({'code': f'{side}.report-missing'}, failures)

    def test_unbound_or_unknown_failure_text_cannot_become_a_reason_code(self):
        for value, run_id in (
            ('trace-export-failed', 'another-run'), ('synthetic-private-diagnostic', 'synthetic-run'),
            (['synthetic-private-diagnostic'], 'synthetic-run'),
        ):
            with self.subTest(value=value, run_id=run_id), TemporaryDirectory() as directory:
                root = Path(directory)
                profile.write_json(root / 'manifest.json', {'runID': 'synthetic-run'})
                profile.write_json(root / 'profiler-state.json', {
                    'schemaVersion': 1, 'state': 'failed', 'failureCode': value, 'runID': run_id,
                })
                codes, failures = profile.capture_diagnostics(root, 'right', profile.InvalidRun('capture-incomplete'))
                self.assertEqual(codes[0], 'right.capture-incomplete')
                self.assertNotIn('right.trace-export-failed', codes)
                self.assertNotIn('synthetic-private-diagnostic', json.dumps([codes, failures]))

    def test_missing_run_pointer_still_identifies_failed_side(self):
        codes, failures = profile.capture_diagnostics(None, 'left', profile.InvalidRun('capture-incomplete'))
        self.assertEqual(codes, ['left.capture-incomplete'])
        self.assertEqual(failures, [])

if __name__ == '__main__':
    unittest.main()
