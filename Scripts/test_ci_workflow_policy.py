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
        cls.acceptance_workflow = json.loads(subprocess.check_output([
            'ruby', '-ryaml', '-rjson', '-e',
            'puts JSON.generate(YAML.safe_load(File.read(ARGV[0]), aliases: true))',
            str(ROOT / '.github/workflows/acceptance-scenarios.yml')], text=True))
        # Ruby's YAML 1.1 loader reads unquoted "on" as true; JSON must retain the intended key.
        cls.acceptance_workflow['on'] = cls.acceptance_workflow.pop('true')

    def check_workflow(self, workflow, script_edit=None, acceptance_workflow=None):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'workflow.yml'
            path.write_text(json.dumps(workflow))  # JSON is a YAML subset; layout is irrelevant.
            acceptance_path = Path(temporary) / 'acceptance.yml'
            acceptance_path.write_text(json.dumps(
                self.acceptance_workflow if acceptance_workflow is None else acceptance_workflow))
            scripts = Path(temporary) / 'Scripts'
            scripts.mkdir()
            for name in ('check-ci-workflow.rb', 'check-source-policy.sh', 'playback-candidate-needed.sh'):
                shutil.copy2(ROOT / 'Scripts' / name, scripts / name)
            (scripts / 'agent-review-tests').mkdir()
            shutil.copy2(ROOT / 'Scripts/agent-review-tests/package.json', scripts / 'agent-review-tests')
            if script_edit:
                name, old, new = script_edit
                script = scripts / name
                self.assertIn(old, script.read_text())
                script.write_text(script.read_text().replace(old, new))
            return subprocess.run(['ruby', str(scripts / 'check-ci-workflow.rb'), str(path), str(acceptance_path)],
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
                    next(s for s in variant['jobs']['playback_python']['steps']
                         if s.get('run') == 'python3 -B Scripts/script_tests.py playback')['run'] = 'true'
                elif kind == 'playback_dependency':
                    next(s for s in variant['jobs']['playback_python']['steps']
                         if s.get('name') == 'Install playback script dependencies')['run'] = 'zsh --version'
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

    def test_acceptance_corpus_and_evidence_cannot_be_skipped_or_made_optional(self):
        for standalone in (False, True):
            for step_id in ('acceptance', 'acceptance_summary', 'acceptance_upload'):
                for mutation in ('remove', 'conditional', 'optional', 'duplicate', 'mask_failure', 'move'):
                    with self.subTest(standalone=standalone, step=step_id, mutation=mutation):
                        variant = copy.deepcopy(self.acceptance_workflow if standalone else self.workflow)
                        job = variant['jobs']['acceptance' if standalone else 'macos']
                        step = next(s for s in job['steps'] if s.get('id') == step_id)
                        if mutation == 'remove':
                            job['steps'].remove(step)
                        elif mutation == 'conditional':
                            step['if'] = 'success()'
                        elif mutation == 'optional':
                            step['continue-on-error'] = True
                        elif mutation == 'duplicate':
                            job['steps'].append(copy.deepcopy(step))
                        elif mutation == 'move':
                            job['steps'].remove(step)
                            job['steps'].append(step)
                        elif 'run' in step:
                            step['run'] += ' || true'
                        else:
                            step['with']['if-no-files-found'] = 'warn'
                        result = (self.check_workflow(self.workflow, acceptance_workflow=variant)
                                  if standalone else self.check_workflow(variant))
                        self.assertNotEqual(result.returncode, 0, result.stdout)
                        self.assertIn('acceptance', result.stderr)

    def test_acceptance_gate_rejects_fabricated_missing_or_ignored_outcomes(self):
        for standalone in (False, True):
            for binding in ('ACCEPTANCE_RESULT', 'ACCEPTANCE_SUMMARY_RESULT', 'ACCEPTANCE_UPLOAD_RESULT'):
                for mutation in ('fabricated', 'missing', 'ignored'):
                    with self.subTest(standalone=standalone, binding=binding, mutation=mutation):
                        variant = copy.deepcopy(self.acceptance_workflow if standalone else self.workflow)
                        job = variant['jobs']['acceptance' if standalone else 'macos']
                        gate = next(s for s in job['steps'] if s['name'] in (
                            'Require every quality lane', 'Require acceptance evidence'))
                        if mutation == 'fabricated':
                            gate['env'][binding] = 'success'
                        elif mutation == 'missing':
                            gate['env'].pop(binding)
                        else:
                            gate['run'] = gate['run'].replace(f'test "${binding}" = success', 'true')
                        result = (self.check_workflow(self.workflow, acceptance_workflow=variant)
                                  if standalone else self.check_workflow(variant))
                        self.assertNotEqual(result.returncode, 0, result.stdout)
                        self.assertIn(f'require {binding} success', result.stderr)

    def test_acceptance_workflow_is_bounded_explicit_and_read_only(self):
        cases = ('job_timeout', 'step_timeout', 'fanout', 'matrix', 'retry', 'permissions', 'trigger', 'head',
                 'artifact_attempt', 'artifact_path', 'holdouts')
        for mutation in cases:
            with self.subTest(mutation=mutation):
                variant = copy.deepcopy(self.acceptance_workflow)
                job = variant['jobs']['acceptance']
                run = next(s for s in job['steps'] if s.get('id') == 'acceptance')
                upload = next(s for s in job['steps'] if s.get('id') == 'acceptance_upload')
                if mutation == 'job_timeout':
                    job.pop('timeout-minutes')
                elif mutation == 'step_timeout':
                    run['timeout-minutes'] = 30
                elif mutation == 'fanout':
                    variant['jobs']['retry'] = copy.deepcopy(job)
                elif mutation == 'matrix':
                    job['strategy'] = {'matrix': {'attempt': [1, 2]}}
                elif mutation == 'retry':
                    retry = copy.deepcopy(run)
                    retry['id'] = 'acceptance_retry'
                    retry['name'] = 'Retry scenarios'
                    job['steps'].append(retry)
                elif mutation == 'permissions':
                    variant['permissions']['contents'] = 'write'
                elif mutation == 'trigger':
                    variant['on']['pull_request'] = None
                elif mutation == 'head':
                    run['env']['SPOTTY_ACCEPTANCE_HEAD_SHA'] = 'HEAD'
                elif mutation == 'artifact_attempt':
                    upload['with']['name'] = 'acceptance-evidence-${{ github.run_id }}'
                elif mutation == 'artifact_path':
                    upload['with']['path'] += '/summary.json'
                else:
                    run['run'] = run['run'].replace('--corpus all', '--corpus representative')
                result = self.check_workflow(self.workflow, acceptance_workflow=variant)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn('acceptance', result.stderr)

    def test_acceptance_execution_remains_after_swift_checks_in_existing_lane(self):
        variant = copy.deepcopy(self.workflow)
        steps = variant['jobs']['macos']['steps']
        acceptance = next(s for s in steps if s.get('id') == 'acceptance')
        steps.remove(acceptance)
        steps.insert(0, acceptance)
        result = self.check_workflow(variant)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('after Swift checks and before Release compilation', result.stderr)

    def test_script_suites_cannot_be_removed_skipped_moved_or_made_optional(self):
        for job_id, command in (
            ('policy', 'npm ci --ignore-scripts --prefix Scripts/agent-review-tests'),
            ('policy', './Scripts/check-source-policy.sh --test-only'),
            ('playback_python', 'python3 -B Scripts/script_tests.py watchdog'),
            ('playback_python', 'python3 -B Scripts/script_tests.py playback'),
            ('playback_python', 'python3 -B Scripts/script_tests.py harness'),
        ):
            for mutation in ('remove', 'conditional', 'optional', 'move', 'duplicate', 'mask_failure'):
                with self.subTest(command=command, mutation=mutation):
                    variant = copy.deepcopy(self.workflow)
                    job = variant['jobs'][job_id]
                    step = next(s for s in job['steps'] if s.get('run') == command)
                    if mutation in ('remove', 'move'):
                        job['steps'].remove(step)
                        if mutation == 'move':
                            variant['jobs']['macos']['steps'].append(step)
                    elif mutation == 'conditional':
                        step['if'] = 'false'
                    elif mutation == 'optional':
                        step['continue-on-error'] = True
                    elif mutation == 'duplicate':
                        job['steps'].append(copy.deepcopy(step))
                    else:
                        step['run'] += ' || true'
                    result = self.check_workflow(variant)
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertIn(job_id, result.stderr)
        for job_id in ('policy', 'playback_python'):
            for key in ('if', 'continue-on-error'):
                with self.subTest(job=job_id, key=key):
                    variant = copy.deepcopy(self.workflow)
                    variant['jobs'][job_id][key] = True
                    result = self.check_workflow(variant)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('tests must run unconditionally', result.stderr)

    def test_reviewer_dependencies_must_be_installed_before_execution(self):
        variant = copy.deepcopy(self.workflow)
        steps = variant['jobs']['policy']['steps']
        install = next(s for s in steps if s.get('run') == 'npm ci --ignore-scripts --prefix Scripts/agent-review-tests')
        steps.remove(install)
        steps.append(install)
        result = self.check_workflow(variant)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('test setup and execution must remain ordered', result.stderr)

    def test_source_gate_syntax_check_cannot_be_skipped_or_moved_out_of_policy(self):
        for mutation in ('conditional', 'remove', 'move'):
            with self.subTest(mutation=mutation):
                variant = copy.deepcopy(self.workflow)
                steps = variant['jobs']['policy']['steps']
                scan = next(s for s in steps if s.get('uses', '').startswith('ast-grep/action@'))
                if mutation == 'conditional':
                    scan['if'] = 'false'
                else:
                    steps.remove(scan)
                    if mutation == 'move':
                        variant['jobs']['macos']['steps'].append(scan)
                result = self.check_workflow(variant)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('independent source scan must run once without a condition', result.stderr)


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
            'Restore Rust release build products',
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

    def test_macos_caches_restore_on_prs_and_save_only_after_successful_main(self):
        cases = (
            ('implicit_pr_save', 'Restore SwiftPM build directory', 'uses',
             'actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9',
             'macOS caches must restore without implicit PR saves'),
            ('pr_save', 'Save SwiftPM build directory', 'if',
             "success() && steps.swift_cache.outputs.cache-hit != 'true'",
             'Save SwiftPM build directory must remain successful-main-only'),
            ('failed_main_save', 'Save SwiftPM build directory', 'if',
             "github.ref == 'refs/heads/main' && steps.swift_cache.outputs.cache-hit != 'true'",
             'Save SwiftPM build directory must remain successful-main-only'),
            ('wrong_key', 'Save Rust verification products', 'key', '${{ github.sha }}',
             'Save Rust verification products must save the restored paths under its primary key'),
            ('candidate_save_without_selection', 'Save Rust release build products', 'if',
             "success() && github.ref == 'refs/heads/main' && steps.rust_release_cache.outputs.cache-hit != 'true'",
             'Save Rust release build products must remain successful-main-only'),
        )
        for kind, name, field, value, expected in cases:
            with self.subTest(kind=kind):
                variant = copy.deepcopy(self.workflow)
                step = next(s for s in variant['jobs']['macos']['steps'] if s['name'] == name)
                if field == 'key':
                    step['with']['key'] = value
                else:
                    step[field] = value
                result = self.check_workflow(variant)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)

        variant = copy.deepcopy(self.workflow)
        steps = variant['jobs']['macos']['steps']
        save = next(s for s in steps if s['name'] == 'Save pinned cbindgen')
        gate_index = next(i for i, step in enumerate(steps)
                          if step['name'] == 'Require every quality lane')
        steps.remove(save)
        steps.insert(gate_index, save)
        result = self.check_workflow(variant)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Save pinned cbindgen must run only after the aggregate passes', result.stderr)

        variant = copy.deepcopy(self.workflow)
        steps = variant['jobs']['macos']['steps']
        steps.remove(next(s for s in steps if s['name'] == 'Save SwiftPM build directory'))
        result = self.check_workflow(variant)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Save SwiftPM build directory must remain successful-main-only', result.stderr)

        variant = copy.deepcopy(self.workflow)
        variant['jobs']['macos']['steps'].append({
            'name': 'Unexpected PR cache save',
            'if': "github.event_name == 'pull_request'",
            'uses': 'actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9',
            'with': {'path': '.build', 'key': '${{ github.sha }}'},
        })
        result = self.check_workflow(variant)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('macOS must contain exactly four paired cache restores and saves', result.stderr)

    def test_source_script_coverage_and_candidate_digest_are_preserved(self):
        cases = [
            ('check-source-policy.sh', 'scan --config sgconfig.yml Sources Backend/spotty-playback Scripts script Tests .github/workflows Package.swift',
             'scan --config sgconfig.yml Sources', 'local source scan must cover'),
            ('check-source-policy.sh', 'python3 -B Scripts/script_tests.py policy', 'true', 'Python policy fixtures'),
            ('check-source-policy.sh', 'npm test --prefix Scripts/agent-review-tests', 'true', 'Python and Node reviewer fixtures'),
            ('check-source-policy.sh', 'python3 -B Scripts/documentation_policy.py', 'true', 'documentation size limits'),
            ('agent-review-tests/package.json', 'python3 -B ../script_tests.py review', 'node --test', 'complete reviewer suite'),
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
