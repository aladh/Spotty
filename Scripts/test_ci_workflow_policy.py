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


    def test_trusted_policy_and_candidate_bindings_are_preserved(self):
        cases = [
            ('Select Rust verification', 'run', '> "$trusted_policy"', '> "$other_policy"', 'trusted-policy export'),
            ('Select Rust verification', 'run', '--base "$INPUT_BASE_SHA"', '--base HEAD', 'trusted-policy execution'),
            ('Identify playback inputs', 'base', None, 'HEAD', 'candidate selection must receive'),
            ('Build candidate playback XCFramework', 'if', None, 'success()', 'Build candidate must follow'),
            ('Upload candidate playback artifact', 'if', None, 'success()', 'Upload candidate must follow'),
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
