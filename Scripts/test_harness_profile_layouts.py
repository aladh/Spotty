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

    def exercise(self, second_returncode):
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
                self.assertEqual(result['reasonCodes'], ['capture-incomplete'])
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

if __name__ == '__main__':
    unittest.main()
