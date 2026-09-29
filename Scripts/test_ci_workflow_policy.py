"""Protect CI topology, candidate decisions, toolchain and cache ownership."""
import copy
import unittest

from ci_workflow_fixtures import WorkflowCheck, WorkflowFixtureMixin


class WorkflowInvariantTests(WorkflowFixtureMixin, unittest.TestCase):
    def test_current_workflow_passes_and_additional_macos_lane_fails(self):
        checks = []
        checks.append(WorkflowCheck(self.workflow, diagnostic=None))
        variant = copy.deepcopy(self.workflow)
        variant['jobs']['additional_macos'] = {'runs-on': 'macos-26', 'steps': [{'run': 'true'}]}
        checks.append(WorkflowCheck(variant, diagnostic='CI must use exactly one macOS runner job'))

        variant = copy.deepcopy(self.workflow)
        variant['jobs']['dynamic_runner'] = {'runs-on': '${{ matrix.os }}', 'steps': [{'run': 'true'}]}
        checks.append(WorkflowCheck(variant, diagnostic='CI runner selection must remain static'))
        self.check_workflows(checks)

    def test_failures_name_the_broken_invariant(self):
        checks = []
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
                checks.append(WorkflowCheck(variant, diagnostic=expected, label={'kind': kind}))
        self.check_workflows(checks)

    def test_swift_check_timeout_is_exact(self):
        checks = []
        for value in (None, 14, 16):
            with self.subTest(timeout=value):
                variant = copy.deepcopy(self.workflow)
                debug = next(s for s in variant['jobs']['macos']['steps']
                             if s.get('id') == 'debug')
                if value is None:
                    debug.pop('timeout-minutes')
                else:
                    debug['timeout-minutes'] = value
                checks.append(WorkflowCheck(variant, diagnostic='Swift Run checks must retain its 15-minute timeout', label={'timeout': value}))
        self.check_workflows(checks)

    def test_trusted_policy_and_candidate_bindings_are_preserved(self):
        checks = []
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
                checks.append(WorkflowCheck(variant, diagnostic=expected, label={'name': name, 'field': field}))
        self.check_workflows(checks)

    def test_candidate_selection_and_outcomes_fail_closed(self):
        checks = []
        variant = copy.deepcopy(self.workflow)
        identify = next(s for s in variant['jobs']['macos']['steps']
                        if s['name'] == 'Identify playback inputs')
        identify.pop('id')
        checks.append(WorkflowCheck(variant, diagnostic='candidate selection must retain its inputs step identity'))

        variant = copy.deepcopy(self.workflow)
        identify = next(s for s in variant['jobs']['macos']['steps']
                        if s['name'] == 'Identify playback inputs')
        identify['continue-on-error'] = True
        checks.append(WorkflowCheck(variant, diagnostic='macOS verification steps must fail without continue-on-error'))

        for step_id in ('inputs', 'candidate_build', 'candidate_upload'):
            with self.subTest(duplicate_step_id=step_id):
                variant = copy.deepcopy(self.workflow)
                variant['jobs']['macos']['steps'].append({
                    'name': f'Duplicate {step_id}', 'id': step_id, 'run': 'echo duplicate',
                })
                checks.append(WorkflowCheck(variant, diagnostic='macOS step IDs must be unique', label={'duplicate_step_id': step_id}))

        variant = copy.deepcopy(self.workflow)
        mac_steps = variant['jobs']['macos']['steps']
        identify = next(s for s in mac_steps if s['name'] == 'Identify playback inputs')
        mac_steps.remove(identify)
        variant['jobs']['playback_python']['steps'].append(identify)
        checks.append(WorkflowCheck(variant, diagnostic='candidate selection must run exactly once in the macOS job'))

        variant = copy.deepcopy(self.workflow)
        mac_steps = variant['jobs']['macos']['steps']
        identify = next(s for s in mac_steps if s['name'] == 'Identify playback inputs')
        mac_steps.remove(identify)
        build_index = next(index for index, step in enumerate(mac_steps)
                           if step['name'] == 'Build candidate playback XCFramework')
        mac_steps.insert(build_index + 1, identify)
        checks.append(WorkflowCheck(variant, diagnostic='candidate selection must precede every candidate-dependent step'))

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
                checks.append(WorkflowCheck(variant, diagnostic=f'{name} must follow the candidate-needed decision', label={'candidate_guard': name}))

        for name, expected in (('Build candidate playback XCFramework', 'candidate build must retain its outcome identity'),
                               ('Upload candidate playback artifact', 'candidate upload must retain its outcome identity')):
            with self.subTest(candidate_id=name):
                variant = copy.deepcopy(self.workflow)
                next(s for s in variant['jobs']['macos']['steps'] if s['name'] == name).pop('id')
                checks.append(WorkflowCheck(variant, diagnostic=expected, label={'candidate_id': name}))

        for binding in ('CANDIDATE_SELECTION_RESULT', 'CANDIDATE_NEEDED',
                        'CANDIDATE_BUILD_RESULT', 'CANDIDATE_UPLOAD_RESULT'):
            with self.subTest(candidate_binding=binding):
                variant = copy.deepcopy(self.workflow)
                gate = next(s for s in variant['jobs']['macos']['steps']
                            if s['name'] == 'Require every quality lane')
                gate['env'][binding] = 'success'
                checks.append(WorkflowCheck(variant, diagnostic=f'aggregate must bind {binding} to its candidate step', label={'candidate_binding': binding}))

        for permissive in ('true:failure:success:true:success:success',
                           'true:success:success:true:skipped:skipped'):
            with self.subTest(permissive_case=permissive):
                variant = copy.deepcopy(self.workflow)
                gate = next(s for s in variant['jobs']['macos']['steps']
                            if s['name'] == 'Require every quality lane')
                valid = 'true:success:success:true:success:success'
                gate['run'] = gate['run'].replace(valid, f'{valid}|{permissive}')
                checks.append(WorkflowCheck(variant, diagnostic='aggregate must contain exactly the fail-closed Rust and candidate truth table', label={'permissive_case': permissive}))
        self.check_workflows(checks)

    def test_macos_caches_restore_on_prs_and_save_only_after_successful_main(self):
        checks = []
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
                checks.append(WorkflowCheck(variant, diagnostic=expected, label={'kind': kind}))

        variant = copy.deepcopy(self.workflow)
        steps = variant['jobs']['macos']['steps']
        save = next(s for s in steps if s['name'] == 'Save pinned cbindgen')
        gate_index = next(i for i, step in enumerate(steps)
                          if step['name'] == 'Require every quality lane')
        steps.remove(save)
        steps.insert(gate_index, save)
        checks.append(WorkflowCheck(variant, diagnostic='Save pinned cbindgen must run only after the aggregate passes'))

        variant = copy.deepcopy(self.workflow)
        steps = variant['jobs']['macos']['steps']
        steps.remove(next(s for s in steps if s['name'] == 'Save SwiftPM build directory'))
        checks.append(WorkflowCheck(variant, diagnostic='Save SwiftPM build directory must remain successful-main-only'))

        variant = copy.deepcopy(self.workflow)
        variant['jobs']['macos']['steps'].append({
            'name': 'Unexpected PR cache save',
            'if': "github.event_name == 'pull_request'",
            'uses': 'actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9',
            'with': {'path': '.build', 'key': '${{ github.sha }}'},
        })
        checks.append(WorkflowCheck(variant, diagnostic='macOS must contain exactly four paired cache restores and saves'))
        self.check_workflows(checks)
