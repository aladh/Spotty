"""Controlled policy inputs, finite validation batches, and the real CLI adapter."""
import copy
from dataclasses import dataclass, field
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class WorkflowCheck:
    workflow: dict
    script_edit: tuple | None = None
    acceptance_workflow: dict | None = None
    diagnostic: str | None = None
    label: dict = field(default_factory=dict)

    def __post_init__(self):
        # Later mutations of a test's working dictionary must not rewrite an earlier case.
        object.__setattr__(self, 'workflow', copy.deepcopy(self.workflow))
        object.__setattr__(self, 'acceptance_workflow', copy.deepcopy(self.acceptance_workflow))


class WorkflowFixtureMixin:
    @classmethod
    def setUpClass(cls):
        temporary = tempfile.TemporaryDirectory(prefix='spotty-workflow-policy-')
        cls.addClassCleanup(temporary.cleanup)
        cls.fixture_root = Path(temporary.name)
        cls.scripts = cls.fixture_root / 'Scripts'
        cls.scripts.mkdir()
        for name in ('check-ci-workflow.rb', 'workflow_policy.rb', 'check-source-policy.sh',
                     'playback-candidate-needed.sh', 'agent-review-tests/package.json'):
            target = cls.scripts / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / 'Scripts' / name, target)
        cls.workflow, cls.acceptance_workflow = json.loads(subprocess.check_output([
            'ruby', '-ryaml', '-rjson', '-e',
            'puts JSON.generate(ARGV.map { |path| YAML.safe_load(File.read(path), aliases: true) })',
            str(ROOT / '.github/workflows/ci.yml'),
            str(ROOT / '.github/workflows/acceptance-scenarios.yml')], text=True))
        # Ruby's YAML 1.1 loader reads unquoted "on" as true; JSON retains the intended key.
        cls.acceptance_workflow['on'] = cls.acceptance_workflow.pop('true')

    def policy_inputs(self, check):
        assets = {name: (self.scripts / name).read_text() for name in (
            'check-source-policy.sh', 'playback-candidate-needed.sh', 'agent-review-tests/package.json')}
        if check.script_edit:
            name, old, new = check.script_edit
            self.assertIn(old, assets[name])
            assets[name] = assets[name].replace(old, new)
        return {
            'workflow': check.workflow,
            'standalone': self.acceptance_workflow if check.acceptance_workflow is None else check.acceptance_workflow,
            'policy_script': assets['check-source-policy.sh'],
            'candidate_script': assets['playback-candidate-needed.sh'],
            'review_package': json.loads(assets['agent-review-tests/package.json']),
        }

    def validate_workflows(self, checks):
        self.assertTrue(checks, 'A workflow batch must exercise at least one case')
        # One finite process per test; no server, persistent pipe, or separate validation rules.
        bridge = '''
require 'json'
require ARGV.fetch(0)
results = JSON.parse(STDIN.read).map.with_index do |inputs, id|
  { 'id' => id, 'errors' => WorkflowPolicy.validate(**inputs.transform_keys(&:to_sym)) }
end
puts JSON.generate(results)
'''
        result = subprocess.run(
            ['ruby', '-e', bridge, str(self.scripts / 'workflow_policy.rb')],
            input=json.dumps([self.policy_inputs(check) for check in checks]),
            text=True, capture_output=True, check=True)
        results = json.loads(result.stdout)
        self.assertIsInstance(results, list)
        self.assertEqual(len(results), len(checks), 'Every submitted variant must finish exactly once')
        for index, value in enumerate(results):
            self.assertIsInstance(value, dict)
            self.assertEqual(set(value), {'id', 'errors'})
            self.assertIs(type(value['id']), int)
            self.assertEqual(value['id'], index, 'Batch results must retain case identity and order')
            self.assertIsInstance(value['errors'], list)
            self.assertTrue(all(isinstance(error, str) for error in value['errors']))
        return [value['errors'] for value in results]

    def check_workflows(self, checks):
        results = self.validate_workflows(checks)
        for index, (check, errors) in enumerate(zip(checks, results, strict=True)):
            with self.subTest(index=index, **check.label):
                if check.diagnostic is None:
                    self.assertEqual(errors, [])
                else:
                    self.assertTrue(errors, 'The invalid variant must fail policy validation')
                    self.assertIn(check.diagnostic, '\n'.join(errors))

    def run_cli(self, workflow, script_edit=None, acceptance_workflow=None, *, default_acceptance=False):
        path = self.fixture_root / 'workflow.yml'
        path.write_text(json.dumps(workflow))
        acceptance_path = self.fixture_root / '.github/workflows/acceptance-scenarios.yml'
        acceptance_path.parent.mkdir(parents=True, exist_ok=True)
        acceptance_path.write_text(json.dumps(
            self.acceptance_workflow if acceptance_workflow is None else acceptance_workflow))

        def invoke(scripts):
            command = ['ruby', str(scripts / 'check-ci-workflow.rb'), str(path)]
            if not default_acceptance:
                command.append(str(acceptance_path))
            return subprocess.run(command, text=True, capture_output=True)

        if script_edit is None:
            return invoke(self.scripts)
        self.assertFalse(default_acceptance, 'Edited script fixtures use the explicit acceptance path')
        with tempfile.TemporaryDirectory(dir=self.fixture_root) as temporary:
            scripts = Path(temporary) / 'Scripts'
            shutil.copytree(self.scripts, scripts)
            name, old, new = script_edit
            script = scripts / name
            self.assertIn(old, script.read_text())
            script.write_text(script.read_text().replace(old, new))
            return invoke(scripts)
