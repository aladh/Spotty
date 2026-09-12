"""Exercise workflow invariants against parsed variants, including multiple macOS jobs."""
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

    def test_current_workflow_and_additional_macos_lane_pass(self):
        result = self.check_workflow(self.workflow)
        self.assertEqual(result.returncode, 0, result.stderr)
        variant = copy.deepcopy(self.workflow)
        variant['jobs']['additional_macos'] = {'runs-on': 'macos-26', 'steps': [{'run': 'true'}]}
        result = self.check_workflow(variant)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_failures_name_the_broken_invariant(self):
        for kind, expected in [('runner', 'macOS app must remain on macos-26'),
                               ('aggregate', 'aggregate must run even after failures or intentional skips'),
                               ('repeats', 'main must repeat boundary checks three times'),
                               ('cbindgen', 'Rust job must own unconditional pinned header parser setup'),
                               ('serialized', 'macOS app must depend only on policy so macOS work stays parallel')]:
            with self.subTest(kind=kind):
                variant = copy.deepcopy(self.workflow)
                if kind == 'runner':
                    variant['jobs']['app_macos']['runs-on'] = 'macos-latest'
                elif kind == 'aggregate':
                    variant['jobs']['macos']['if'] = 'success()'
                elif kind == 'repeats':
                    steps = variant['jobs']['app_macos']['steps']
                    next(s for s in steps if s.get('id') == 'debug').pop('env')
                elif kind == 'cbindgen':
                    steps = variant['jobs']['rust_macos']['steps']
                    steps.remove(next(s for s in steps if s['name'] == 'Install pinned cbindgen'))
                elif kind == 'serialized':
                    variant['jobs']['app_macos']['needs'] = ['policy', 'rust_macos']
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
            ('Require every quality lane', 'app_result', None, 'success', 'aggregate must bind APP_RESULT'),
            ('Require every quality lane', 'candidate_result', None, 'success', 'aggregate must bind CANDIDATE_RESULT'),
        ]
        for name, field, old, new, expected in cases:
            with self.subTest(name=name, field=field):
                variant = copy.deepcopy(self.workflow)
                step = next(s for job in variant['jobs'].values() for s in job.get('steps', [])
                            if s['name'] == name)
                if field == 'base':
                    step['env']['INPUT_BASE_SHA'] = new
                elif field == 'app_result':
                    step['env']['APP_RESULT'] = new
                elif field == 'candidate_result':
                    step['env']['CANDIDATE_RESULT'] = new
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
