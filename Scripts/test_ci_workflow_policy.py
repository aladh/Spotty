"""Exercise workflow invariants against parsed variants, including the one-macOS-job cap."""
import copy
import json
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class WorkflowInvariantTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = json.loads(subprocess.check_output([
            'ruby', '-ryaml', '-rjson', '-e',
            'puts JSON.generate(YAML.safe_load(File.read(ARGV[0]), aliases: true))',
            str(ROOT / '.github/workflows/ci.yml')], text=True))

    def check_workflow(self, workflow, script_edit=None):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'workflow.yml'
            path.write_text(json.dumps(workflow))  # JSON is a YAML subset; layout is irrelevant.
            scripts = Path(temporary) / 'Scripts'
            scripts.mkdir()
            for name in ('check-ci-workflow.rb', 'check-source-policy.sh', 'playback-candidate-needed.sh'):
                shutil.copy2(ROOT / 'Scripts' / name, scripts / name)
            if script_edit:
                name, old, new = script_edit
                script = scripts / name
                self.assertIn(old, script.read_text())
                script.write_text(script.read_text().replace(old, new))
            return subprocess.run(['ruby', str(scripts / 'check-ci-workflow.rb'), str(path)],
                                  text=True, capture_output=True)

    def test_current_workflow_passes_and_additional_macos_lane_fails(self):
        result = self.check_workflow(self.workflow)
        self.assertEqual(result.returncode, 0, result.stderr)
        variant = copy.deepcopy(self.workflow)
        variant['jobs']['additional_macos'] = {'runs-on': 'macos-26', 'steps': [{'run': 'true'}]}
        result = self.check_workflow(variant)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('CI must use exactly one macOS runner job', result.stderr)

        variant = copy.deepcopy(self.workflow)
        variant['jobs']['dynamic_runner'] = {'runs-on': '${{ matrix.os }}', 'steps': [{'run': 'true'}]}
        result = self.check_workflow(variant)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('CI runner selection must remain static', result.stderr)

    def test_failures_name_the_broken_invariant(self):
        for kind, expected in [('runner', 'macOS image must remain macos-26'),
                               ('aggregate', 'aggregate must run even after failures'),
                               ('repeats', 'main must repeat boundary checks three times'),
                               ('cbindgen', 'header parser setup must follow explicit Rust classification'),
                               ('playback', 'Linux must run the playback script checks'),
                               ('playback_dependency', 'playback script checks must install their zsh fixture dependency'),
                               ('compiled_scope', 'rust verification command must run'),
                               ('job_gate', 'macOS must retain aggregate failure semantics')]:
            with self.subTest(kind=kind):
                variant = copy.deepcopy(self.workflow)
                steps = variant['jobs']['macos']['steps']
                if kind == 'runner':
                    variant['jobs']['macos']['runs-on'] = 'macos-latest'
                elif kind == 'aggregate':
                    next(s for s in steps if s['name'] == 'Require every quality lane')['if'] = 'success()'
                elif kind == 'repeats':
                    next(s for s in steps if s.get('id') == 'debug').pop('env')
                elif kind == 'cbindgen':
                    next(s for s in steps if s['name'] == 'Install pinned cbindgen').pop('if')
                elif kind == 'playback':
                    variant['jobs']['playback_python']['steps'][-1]['run'] = 'true'
                elif kind == 'playback_dependency':
                    variant['jobs']['playback_python']['steps'][-2]['run'] = 'zsh --version'
                elif kind == 'compiled_scope':
                    next(s for s in steps if s.get('id') == 'rust')['run'] = 'SPOTTY_CHECK_SCOPE=rust ./Scripts/check.sh'
                elif kind == 'job_gate':
                    variant['jobs']['macos']['if'] = "needs.policy.outputs.macos_needed == 'true'"
                result = self.check_workflow(variant)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)

    def test_swift_check_timeout_is_exact(self):
        for value in (None, 14, 16):
            with self.subTest(timeout=value):
                variant = copy.deepcopy(self.workflow)
                debug = next(s for s in variant['jobs']['macos']['steps']
                             if s.get('id') == 'debug')
                if value is None:
                    debug.pop('timeout-minutes')
                else:
                    debug['timeout-minutes'] = value
                result = self.check_workflow(variant)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Swift Run checks must retain its 15-minute timeout', result.stderr)


    def test_trusted_policy_and_candidate_bindings_are_preserved(self):
        cases = [
            ('Select Rust verification', 'run', '> "$trusted_policy"', '> "$other_policy"', 'trusted-policy export'),
            ('Select Rust verification', 'run', '--base "$INPUT_BASE_SHA"', '--base HEAD', 'trusted-policy execution'),
            ('Identify playback inputs', 'base', None, 'HEAD', 'candidate selection must receive'),
            ('Build candidate playback XCFramework', 'if', None, 'success()', 'Build candidate playback XCFramework must follow'),
            ('Upload candidate playback artifact', 'if', None, 'success()', 'Upload candidate playback artifact must follow'),
            ('Require every quality lane', 'outcome', None, 'success', 'aggregate must require CHECKS_RESULT'),
            ('Require every quality lane', 'playback_result', None, 'success', 'aggregate must require PLAYBACK_PYTHON_RESULT'),
        ]
        for name, field, old, new, expected in cases:
            with self.subTest(name=name, field=field):
                variant = copy.deepcopy(self.workflow)
                step = next(s for job in variant['jobs'].values() for s in job.get('steps', [])
                            if s['name'] == name)
                if field == 'base':
                    step['env']['INPUT_BASE_SHA'] = new
                elif field == 'outcome':
                    step['env']['CHECKS_RESULT'] = new
                elif field == 'playback_result':
                    step['env']['PLAYBACK_PYTHON_RESULT'] = new
                elif old:
                    self.assertIn(old, step[field])
                    step[field] = step[field].replace(old, new)
                else:
                    step[field] = new
                result = self.check_workflow(variant)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)

    def test_candidate_selection_and_outcomes_fail_closed(self):
        variant = copy.deepcopy(self.workflow)
        identify = next(s for s in variant['jobs']['macos']['steps']
                        if s['name'] == 'Identify playback inputs')
        identify.pop('id')
        result = self.check_workflow(variant)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('candidate selection must retain its inputs step identity', result.stderr)

        variant = copy.deepcopy(self.workflow)
        identify = next(s for s in variant['jobs']['macos']['steps']
                        if s['name'] == 'Identify playback inputs')
        identify['continue-on-error'] = True
        result = self.check_workflow(variant)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('macOS verification steps must fail without continue-on-error', result.stderr)

        for step_id in ('inputs', 'candidate_build', 'candidate_upload'):
            with self.subTest(duplicate_step_id=step_id):
                variant = copy.deepcopy(self.workflow)
                variant['jobs']['macos']['steps'].append({
                    'name': f'Duplicate {step_id}', 'id': step_id, 'run': 'echo duplicate',
                })
                result = self.check_workflow(variant)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('macOS step IDs must be unique', result.stderr)

        variant = copy.deepcopy(self.workflow)
        mac_steps = variant['jobs']['macos']['steps']
        identify = next(s for s in mac_steps if s['name'] == 'Identify playback inputs')
        mac_steps.remove(identify)
        variant['jobs']['playback_python']['steps'].append(identify)
        result = self.check_workflow(variant)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('candidate selection must run exactly once in the macOS job', result.stderr)

        variant = copy.deepcopy(self.workflow)
        mac_steps = variant['jobs']['macos']['steps']
        identify = next(s for s in mac_steps if s['name'] == 'Identify playback inputs')
        mac_steps.remove(identify)
        build_index = next(index for index, step in enumerate(mac_steps)
                           if step['name'] == 'Build candidate playback XCFramework')
        mac_steps.insert(build_index + 1, identify)
        result = self.check_workflow(variant)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('candidate selection must precede every candidate-dependent step', result.stderr)

        dependent_names = (
            'Cache Rust release build products',
            'Restore unchanged Rust release input timestamps',
            'Snapshot Rust release input timestamps',
            'Build candidate playback XCFramework',
            'Upload candidate playback artifact',
        )
        for name in dependent_names:
            with self.subTest(candidate_guard=name):
                variant = copy.deepcopy(self.workflow)
                step = next(s for s in variant['jobs']['macos']['steps'] if s['name'] == name)
                step['if'] = 'success()'
                result = self.check_workflow(variant)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f'{name} must follow the candidate-needed decision', result.stderr)

        for name, expected in (('Build candidate playback XCFramework', 'candidate build must retain its outcome identity'),
                               ('Upload candidate playback artifact', 'candidate upload must retain its outcome identity')):
            with self.subTest(candidate_id=name):
                variant = copy.deepcopy(self.workflow)
                next(s for s in variant['jobs']['macos']['steps'] if s['name'] == name).pop('id')
                result = self.check_workflow(variant)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)

        for binding in ('CANDIDATE_SELECTION_RESULT', 'CANDIDATE_NEEDED',
                        'CANDIDATE_BUILD_RESULT', 'CANDIDATE_UPLOAD_RESULT'):
            with self.subTest(candidate_binding=binding):
                variant = copy.deepcopy(self.workflow)
                gate = next(s for s in variant['jobs']['macos']['steps']
                            if s['name'] == 'Require every quality lane')
                gate['env'][binding] = 'success'
                result = self.check_workflow(variant)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f'aggregate must bind {binding} to its candidate step', result.stderr)

        for permissive in ('true:failure:success:true:success:success',
                           'true:success:success:true:skipped:skipped'):
            with self.subTest(permissive_case=permissive):
                variant = copy.deepcopy(self.workflow)
                gate = next(s for s in variant['jobs']['macos']['steps']
                            if s['name'] == 'Require every quality lane')
                valid = 'true:success:success:true:success:success'
                gate['run'] = gate['run'].replace(valid, f'{valid}|{permissive}')
                result = self.check_workflow(variant)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('aggregate must contain exactly the fail-closed Rust and candidate truth table',
                              result.stderr)

    def test_source_script_coverage_and_candidate_digest_are_preserved(self):
        cases = [
            ('check-source-policy.sh', 'scan --config sgconfig.yml Sources Backend/spotty-playback Scripts script Tests .github/workflows Package.swift',
             'scan --config sgconfig.yml Sources', 'local source scan must cover'),
            ('check-source-policy.sh', "-p 'test_*policy.py'", "-p 'missing*.py'", 'Python policy fixtures'),
            ('playback-candidate-needed.sh', './Backend/spotty-playback/source-input-digest.sh)',
             'echo stale)', 'compute the engine source input digest'),
            ('playback-candidate-needed.sh', 'echo "candidate_needed=$candidate_needed"',
             'echo "unused=$candidate_needed"', 'publish its decision'),
        ]
        for name, old, new, expected in cases:
            with self.subTest(name=name, old=old):
                result = self.check_workflow(self.workflow, (name, old, new))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)
