"""Exercise workflow invariants against parsed variants, including multiple macOS jobs."""
import copy
import json
from pathlib import Path
import subprocess
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

    def check_workflow(self, workflow):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'workflow.yml'
            path.write_text(json.dumps(workflow))  # JSON is a YAML subset; layout is irrelevant.
            return subprocess.run(['ruby', str(ROOT / 'Scripts/check-ci-workflow.rb'), str(path)],
                                  text=True, capture_output=True)

    def test_current_workflow_and_additional_macos_lane_pass(self):
        result = self.check_workflow(self.workflow)
        self.assertEqual(result.returncode, 0, result.stderr)
        variant = copy.deepcopy(self.workflow)
        variant['jobs']['additional_macos'] = {'runs-on': 'macos-26', 'steps': [{'run': 'true'}]}
        result = self.check_workflow(variant)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_failures_name_the_broken_invariant(self):
        for kind, expected in [('permissions', 'workflow permissions'),
                               ('checkout', 'checkout must disable persisted credentials'),
                               ('pin', 'action must use a full commit SHA'),
                               ('aggregate', 'aggregate must run even after failures'),
                               ('repeats', 'main must repeat boundary checks three times')]:
            with self.subTest(kind=kind):
                variant = copy.deepcopy(self.workflow)
                steps = variant['jobs']['macos']['steps']
                if kind == 'permissions':
                    variant['permissions'] = {'contents': 'write'}
                elif kind == 'checkout':
                    steps[0]['with']['persist-credentials'] = True
                elif kind == 'pin':
                    steps[0]['uses'] = 'actions/checkout@main'
                elif kind == 'aggregate':
                    next(s for s in steps if s['name'] == 'Require every quality lane')['if'] = 'success()'
                elif kind == 'repeats':
                    next(s for s in steps if s.get('id') == 'debug').pop('env')
                result = self.check_workflow(variant)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)
