"""Protect classified parallel lanes, candidate provenance, and cache publication."""
import copy
import unittest

from ci_workflow_fixtures import WorkflowCheck, WorkflowFixtureMixin

VERIFY = ('macos_engine', 'macos_contracts', 'macos_swift', 'macos_release')
CACHE_SCOPES = ('contracts', 'tests', 'release', 'cbindgen', 'rust-debug', 'rust-release')


class WorkflowInvariantTests(WorkflowFixtureMixin, unittest.TestCase):
    @staticmethod
    def step(workflow, job, name):
        return next(s for s in workflow['jobs'][job]['steps'] if s['name'] == name)

    def test_current_topology_passes_and_added_dynamic_or_missing_lanes_fail(self):
        checks = [WorkflowCheck(self.workflow)]
        for mutation in ('extra_macos', 'dynamic', 'missing', 'permissions', 'triggers'):
            variant = copy.deepcopy(self.workflow)
            if mutation == 'extra_macos':
                variant['jobs']['extra'] = {'runs-on': 'macos-26', 'steps': []}
                expected = 'exactly four macOS verification lanes'
            elif mutation == 'dynamic':
                variant['jobs']['macos_swift']['runs-on'] = '${{ matrix.os }}'
                expected = 'runner selection must remain static'
            elif mutation == 'missing':
                variant['jobs'].pop('macos_engine')
                expected = 'exactly the classified verification'
            elif mutation == 'permissions':
                variant['permissions']['contents'] = 'write'
                expected = 'read-only contents permissions'
            else:
                variant['on']['push']['branches'] = ['main', 'other']
                expected = 'main-push and pull-request triggers'
            checks.append(WorkflowCheck(variant, diagnostic=expected, label={'mutation': mutation}))
        self.check_workflows(checks)

    def test_every_verification_lane_requires_successful_policy_and_explicit_selection(self):
        checks = []
        for job in VERIFY:
            for mutation in ('runner', 'policy_failure', 'implicit_selection', 'missing_need', 'optional', 'fanout'):
                variant = copy.deepcopy(self.workflow)
                lane = variant['jobs'][job]
                expected = 'successful source policy and explicit classification'
                if mutation == 'runner':
                    lane['runs-on'] = 'macos-latest'
                    expected = 'macOS image must remain macos-26'
                elif mutation == 'policy_failure':
                    lane['if'] = lane['if'].split(' && ', 1)[1]
                elif mutation == 'implicit_selection':
                    lane['if'] = "needs.policy.result == 'success'"
                elif mutation == 'missing_need':
                    lane['needs'] = []
                elif mutation == 'optional':
                    lane['continue-on-error'] = True
                    expected = 'verification must propagate failures'
                else:
                    lane['strategy'] = {'matrix': {'attempt': [1, 2]}}
                    expected = 'must not add fanout'
                checks.append(WorkflowCheck(variant, diagnostic=expected, label={'job': job, 'mutation': mutation}))
        self.check_workflows(checks)

    def test_compiled_commands_timeouts_and_repeats_remain_owned_once(self):
        checks = []
        for job, name, outcome in (
            ('macos_contracts', 'Run Swift contracts', 'contracts'),
            ('macos_swift', 'Run checks', 'debug'),
            ('macos_release', 'Compile release Spotty with SPOTTY_DISTRIBUTION', 'release'),
            ('macos_engine', 'Run Rust checks', 'rust'),
        ):
            for mutation in ('command', 'duplicate', 'moved', 'masked', 'optional'):
                variant = copy.deepcopy(self.workflow)
                step = self.step(variant, job, name)
                if mutation == 'command':
                    step['run'] = 'true'
                elif mutation == 'duplicate':
                    variant['jobs']['playback_python']['steps'].append(copy.deepcopy(step))
                elif mutation == 'moved':
                    variant['jobs'][job]['steps'].remove(step)
                    variant['jobs']['playback_python']['steps'].append(step)
                elif mutation == 'masked':
                    step['run'] += ' || true'
                else:
                    step['continue-on-error'] = True
                expected = ('verification must propagate failures' if mutation == 'optional' else
                            'exactly one CI owner' if mutation == 'duplicate' else f'{outcome} verification command')
                checks.append(WorkflowCheck(variant, diagnostic=expected, label={'job': job, 'mutation': mutation}))
        for job, name in (('macos_swift', 'Run checks'), ('macos_contracts', 'Run Swift contracts')):
            for value in (None, 14, 16):
                variant = copy.deepcopy(self.workflow)
                step = self.step(variant, job, name)
                if value is None:
                    step.pop('timeout-minutes')
                else:
                    step['timeout-minutes'] = value
                checks.append(WorkflowCheck(variant, diagnostic='retain its 15-minute timeout'))
        variant = copy.deepcopy(self.workflow)
        self.step(variant, 'macos_swift', 'Run checks').pop('env')
        checks.append(WorkflowCheck(variant, diagnostic='repeat boundary checks three times'))
        self.check_workflows(checks)

    def test_trusted_policy_and_actual_candidate_outcomes_are_preserved(self):
        checks = []
        for mutation in ('policy_export', 'policy_execution', 'candidate_base', 'selection_id', 'build_id', 'upload_id'):
            variant = copy.deepcopy(self.workflow)
            if mutation.startswith('policy_'):
                step = self.step(variant, 'policy', 'Select Rust verification')
                old, new, expected = (('> "$trusted_policy"', '> "$other_policy"', 'trusted-policy export')
                                      if mutation == 'policy_export' else
                                      ('--base "$INPUT_BASE_SHA"', '--base HEAD', 'trusted-policy execution'))
                self.assertIn(old, step['run'])
                step['run'] = step['run'].replace(old, new)
            elif mutation == 'candidate_base':
                self.step(variant, 'macos_engine', 'Identify playback inputs')['env']['INPUT_BASE_SHA'] = 'HEAD'
                expected = 'candidate selection must receive'
            else:
                name, expected = {
                    'selection_id': ('Identify playback inputs', 'inputs step identity'),
                    'build_id': ('Build candidate playback XCFramework', 'candidate build must retain'),
                    'upload_id': ('Upload candidate playback artifact', 'candidate upload must retain'),
                }[mutation]
                self.step(variant, 'macos_engine', name).pop('id')
            checks.append(WorkflowCheck(variant, diagnostic=expected, label={'mutation': mutation}))
        for name in ('Restore Rust release build products', 'Restore unchanged Rust release input timestamps',
                     'Snapshot Rust release input timestamps', 'Build candidate playback XCFramework',
                     'Upload candidate playback artifact'):
            variant = copy.deepcopy(self.workflow)
            self.step(variant, 'macos_engine', name)['if'] = 'success()'
            checks.append(WorkflowCheck(variant, diagnostic=f'{name} must follow the candidate-needed decision'))
        for output in ('candidate_needed', 'rust_result', 'candidate_selection_result',
                       'candidate_build_result', 'candidate_upload_result'):
            variant = copy.deepcopy(self.workflow)
            variant['jobs']['macos_engine']['outputs'][output] = 'success'
            checks.append(WorkflowCheck(variant, diagnostic=f'actual {output} output'))
        for step_id in ('inputs', 'candidate_build', 'candidate_upload'):
            variant = copy.deepcopy(self.workflow)
            variant['jobs']['macos_engine']['steps'].append({'name': 'Duplicate', 'id': step_id, 'run': 'true'})
            checks.append(WorkflowCheck(variant, diagnostic='macos_engine step IDs must be unique'))
        variant = copy.deepcopy(self.workflow)
        steps = variant['jobs']['macos_engine']['steps']
        identify = self.step(variant, 'macos_engine', 'Identify playback inputs')
        steps.remove(identify)
        steps.append(identify)
        checks.append(WorkflowCheck(variant, diagnostic='candidate selection, timestamps, build, and upload must remain ordered'))
        self.check_workflows(checks)

    def test_outcome_gates_bind_real_results_and_reject_permissive_cases_or_shell(self):
        checks = []
        gates = (
            ('macos_engine', 'Require engine results'), ('macos_swift', 'Require Swift test evidence'),
            ('quality_gate', 'Require every quality lane'), ('macos', 'Require completed verification and cache publication'),
        )
        for job, name in gates:
            original = self.step(self.workflow, job, name)
            for result in original['env']:
                variant = copy.deepcopy(self.workflow)
                self.step(variant, job, name)['env'][result] = 'success'
                checks.append(WorkflowCheck(variant, diagnostic='must', label={'job': job, 'binding': result}))
            for mutation in ('ignored', 'conditional', 'disable_errors'):
                variant = copy.deepcopy(self.workflow)
                gate = self.step(variant, job, name)
                if mutation == 'conditional':
                    gate['if'] = 'success()'
                    expected = 'must run'
                elif mutation == 'disable_errors':
                    gate['run'] = 'set +e\n' + gate['run']
                    expected = 'only fail-closed outcome checks'
                else:
                    gate['run'] = gate['run'].replace('exit 1', 'exit 0').replace('= success', '= skipped')
                    expected = 'must'
                checks.append(WorkflowCheck(variant, diagnostic=expected, label={'job': job, 'mutation': mutation}))
        for valid, permissive, label in (
            ('true:true|true:false|false:false', 'false:true', 'compiler selection aggregate'),
            ('true:success:success:success|false:skipped:skipped:skipped', 'true:success:skipped:success', 'Swift lane aggregate'),
            ('true:success:success:success:true:success:success', 'true:success:failure:success:true:success:success', 'Rust and candidate aggregate'),
        ):
            variant = copy.deepcopy(self.workflow)
            gate = self.step(variant, 'quality_gate', 'Require every quality lane')
            self.assertIn(valid, gate['run'])
            gate['run'] = gate['run'].replace(valid, valid + '|' + permissive)
            checks.append(WorkflowCheck(variant, diagnostic=f'{label} must retain its exact fail-closed truth table'))
        self.check_workflows(checks)

    def test_focused_selection_proof_remains_exact_trusted_bounded_and_required(self):
        checks = [WorkflowCheck(self.workflow)]
        for name, identity in (
                ('Prove focused test selection', 'focused_smoke'),
                ('Collect supported-toolchain selection evidence', 'selection_experiment'),
                ('Upload focused selection evidence', 'selection_upload')):
            original = self.step(self.workflow, 'macos_swift', name)
            for mutation in ('removed', 'duplicated', 'optional', 'contract'):
                variant = copy.deepcopy(self.workflow)
                steps = variant['jobs']['macos_swift']['steps']
                step = self.step(variant, 'macos_swift', name)
                if mutation == 'removed':
                    steps.remove(step)
                elif mutation == 'duplicated':
                    steps.append(copy.deepcopy(step))
                elif mutation == 'optional':
                    step['continue-on-error'] = True
                elif 'run' in original:
                    step['run'] = original['run'].replace('6.3.3', '6.4')
                else:
                    step['with']['if-no-files-found'] = 'warn'
                checks.append(WorkflowCheck(variant, diagnostic=f'{identity} must retain',
                                            label={'identity': identity, 'mutation': mutation}))
        for clause in (
                "github.event_name == 'pull_request' && ",
                'github.event.pull_request.head.repo.full_name == github.repository && ',
                "steps.acceptance_upload.outcome == 'success'"):
            variant = copy.deepcopy(self.workflow)
            step = self.step(variant, 'macos_swift', 'Collect supported-toolchain selection evidence')
            step['if'] = step['if'].replace(clause, 'true')
            checks.append(WorkflowCheck(variant, diagnostic='selection_experiment must retain'))
        for name in ('Prove focused test selection', 'Collect supported-toolchain selection evidence'):
            variant = copy.deepcopy(self.workflow)
            steps = variant['jobs']['macos_swift']['steps']
            step = self.step(variant, 'macos_swift', name)
            steps.remove(step)
            steps.insert(0, step)
            checks.append(WorkflowCheck(variant, diagnostic='preserve successful corpus ordering'))
        variant = copy.deepcopy(self.workflow)
        gate = self.step(variant, 'macos_swift', 'Require Swift test evidence')
        gate['run'] = gate['run'].replace('true:success|false:skipped', 'true:success|true:skipped|false:skipped')
        checks.append(WorkflowCheck(variant, diagnostic='focused selection aggregate must retain its exact fail-closed truth table'))
        self.check_workflows(checks)

    def test_public_cargo_source_preflight_remains_required_before_release_work(self):
        checks = []
        for mutation in ('removed', 'command', 'identity', 'duplicate', 'moved', 'before_rust',
                         'after_release', 'condition', 'main_only', 'candidate_only', 'masked',
                         'optional', 'gate_binding', 'gate_omitted', 'gate_skipped'):
            variant = copy.deepcopy(self.workflow)
            steps = variant['jobs']['macos_engine']['steps']
            proof = self.step(variant, 'macos_engine', 'Preflight public Cargo source proof')
            expected = 'exact proof command and outcome identity'
            if mutation == 'removed':
                steps.remove(proof)
                expected = 'Preflight public Cargo source proof must run exactly once'
            elif mutation == 'command':
                proof['run'] = proof['run'].replace(' preflight ', ' export ')
            elif mutation == 'identity':
                proof['id'] = 'different_source_proof'
            elif mutation == 'duplicate':
                variant['jobs']['playback_python']['steps'].append(copy.deepcopy(proof))
                expected = 'public Cargo source preflight must have exactly one CI owner'
            elif mutation == 'moved':
                steps.remove(proof)
                variant['jobs']['playback_python']['steps'].append(proof)
                expected = 'Preflight public Cargo source proof must run exactly once'
            elif mutation in ('before_rust', 'after_release'):
                steps.remove(proof)
                anchor = self.step(variant, 'macos_engine', 'Run Rust checks' if mutation == 'before_rust'
                                   else 'Restore Rust release build products')
                steps.insert(steps.index(anchor) + (mutation == 'after_release'), proof)
                expected = 'follow Rust verification and precede Release restoration'
            elif mutation in ('condition', 'main_only', 'candidate_only'):
                proof['if'] = {'condition': 'success()', 'main_only': "github.ref == 'refs/heads/main'",
                               'candidate_only': "steps.inputs.outputs.candidate_needed == 'true'"}[mutation]
                expected = 'Preflight public Cargo source proof must follow explicit Rust classification'
            elif mutation == 'masked':
                proof['run'] += ' || true'
            elif mutation == 'optional':
                proof['continue-on-error'] = True
                expected = 'macos_engine verification must propagate failures'
            else:
                gate = self.step(variant, 'macos_engine', 'Require engine results')
                if mutation == 'gate_binding':
                    gate['env']['SOURCE_PROOF_RESULT'] = 'success'
                elif mutation == 'gate_omitted':
                    gate['run'] = gate['run'].replace('test "$SOURCE_PROOF_RESULT" = success\n', '')
                else:
                    gate['run'] = gate['run'].replace('test "$SOURCE_PROOF_RESULT" = success',
                                                      'test "$SOURCE_PROOF_RESULT" = skipped')
                expected = 'engine gate must require SOURCE_PROOF_RESULT success'
            checks.append(WorkflowCheck(variant, diagnostic=expected, label={'mutation': mutation}))
        self.check_workflows(checks)

    def test_main_only_cache_publisher_follows_the_complete_quality_join(self):
        checks = []
        for job, field in (('quality_gate', 'needs'), ('quality_gate', 'if'), ('cache_publisher', 'needs'),
                           ('cache_publisher', 'if'), ('macos', 'needs'), ('macos', 'if')):
            variant = copy.deepcopy(self.workflow)
            variant['jobs'][job][field] = [] if field == 'needs' else 'success()'
            checks.append(WorkflowCheck(variant, diagnostic={
                'quality_gate': 'always require every classified and portable lane',
                'cache_publisher': 'successful aggregate verification on main only',
                'macos': 'always join quality and cache publication',
            }[job]))
        for scope in CACHE_SCOPES:
            owner = {'contracts': 'macos_contracts', 'tests': 'macos_swift', 'release': 'macos_release'}.get(scope, 'macos_engine')
            for mutation in ('pr_export', 'failed_main_export', 'wrong_attempt', 'wrong_revision', 'wrong_key', 'wrong_scope', 'optional_download', 'before_validation'):
                variant = copy.deepcopy(self.workflow)
                export = self.step(variant, owner, f'Export {scope} cache products')
                upload = self.step(variant, owner, f'Upload {scope} cache products')
                unpack = self.step(variant, 'cache_publisher', f'Restore {scope} owned cache products')
                save = self.step(variant, 'cache_publisher', f'Save {scope} validated cache')
                if mutation == 'pr_export':
                    export['if'] = 'success()'
                    expected = 'successful-main-only and revision-bound'
                elif mutation == 'failed_main_export':
                    export['if'] = "always() && github.ref == 'refs/heads/main'"
                    expected = 'successful-main-only and revision-bound'
                elif mutation == 'wrong_attempt':
                    upload['with']['name'] = f'cache-{scope}-${{{{ github.run_id }}}}'
                    expected = 'attempt-bound complete products'
                elif mutation == 'wrong_revision':
                    unpack['run'] = unpack['run'].replace('"$GITHUB_SHA"', 'HEAD')
                    expected = 'validate revision and replace only its owned scope'
                elif mutation == 'wrong_key':
                    save['with']['key'] = '${{ github.sha }}'
                    expected = "producing lane's paths and exact key"
                elif mutation == 'wrong_scope':
                    unpack['run'] += ' --scope all'
                    expected = 'validate revision and replace only its owned scope'
                elif mutation == 'optional_download':
                    self.step(variant, 'cache_publisher', f'Download {scope} cache products')['if'] = 'false'
                    expected = 'exact run-attempt export'
                else:
                    steps = variant['jobs']['cache_publisher']['steps']
                    steps.remove(save)
                    steps.insert(0, save)
                    expected = 'download, validation, and save must remain ordered'
                checks.append(WorkflowCheck(variant, diagnostic=expected, label={'scope': scope, 'mutation': mutation}))
        variant = copy.deepcopy(self.workflow)
        save = self.step(variant, 'cache_publisher', 'Save contracts validated cache')
        variant['jobs']['cache_publisher']['steps'].remove(save)
        variant['jobs']['macos_contracts']['steps'].append(save)
        checks.append(WorkflowCheck(variant, diagnostic='only the post-aggregate publisher may save caches'))
        variant = copy.deepcopy(self.workflow)
        self.step(variant, 'macos_swift', 'Restore SwiftPM build directory')['uses'] = 'actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9'
        checks.append(WorkflowCheck(variant, diagnostic='without implicit PR writes'))
        self.check_workflows(checks)

    def test_each_cache_uses_configuration_compatible_roots_and_keys(self):
        checks = []
        for job in ('macos_contracts', 'macos_swift', 'macos_release'):
            for field in ('key', 'restore-keys'):
                variant = copy.deepcopy(self.workflow)
                self.step(variant, job, 'Restore SwiftPM build directory')['with'][field] = 'macos-swift-'
                checks.append(WorkflowCheck(variant, diagnostic='exact configuration-safe isolation'))
            variant = copy.deepcopy(self.workflow)
            self.step(variant, job, 'Restore SwiftPM build directory')['with']['path'] = '.build'
            checks.append(WorkflowCheck(variant, diagnostic='guarded restore paths'))
        for name, expected in (('Restore Rust verification products', 'actual Debug toolchain'),
                               ('Restore Rust release build products', 'bounded dependency compatibility'),
                               ('Restore pinned cbindgen', 'exact architecture and parser version')):
            variant = copy.deepcopy(self.workflow)
            self.step(variant, 'macos_engine', name)['with']['restore-keys'] = 'macos-'
            checks.append(WorkflowCheck(variant, diagnostic=expected))
        for job in ('macos_contracts', 'macos_swift', 'macos_release'):
            variant = copy.deepcopy(self.workflow)
            self.step(variant, job, 'Show toolchains')['run'] = 'swift --version'
            checks.append(WorkflowCheck(variant, diagnostic='actual pinned Swift toolchain'))
        variant = copy.deepcopy(self.workflow)
        self.step(variant, 'macos_engine', 'Identify Rust Debug cache compatibility')['run'] = 'echo RUST_DEBUG_TOOLCHAIN_KEY=guessed >> "$GITHUB_ENV"'
        checks.append(WorkflowCheck(variant, diagnostic='actual verification SDK'))
        self.check_workflows(checks)

    def test_timing_evidence_remains_required_and_available_before_compilation(self):
        checks = []
        for job, upload_name in (
            ('macos_engine', 'Upload engine timing evidence'),
            ('macos_contracts', 'Upload contracts timing evidence'),
            ('macos_swift', 'Upload Swift timing evidence'),
            ('macos_release', 'Upload Release timing evidence'),
        ):
            for mutation in ('missing_init', 'job_context', 'conditional_upload', 'optional_archive'):
                variant = copy.deepcopy(self.workflow)
                if mutation == 'missing_init':
                    steps = variant['jobs'][job]['steps']
                    steps.remove(self.step(variant, job, 'Initialize timing evidence'))
                    expected = 'initialize required timing evidence'
                elif mutation == 'job_context':
                    variant['jobs'][job].setdefault('env', {})['SPOTTY_CI_TIMINGS_REPORT'] = '${{ runner.temp }}/phases.jsonl'
                    expected = 'unavailable runner context'
                elif mutation == 'conditional_upload':
                    self.step(variant, job, upload_name)['if'] = 'success()'
                    expected = 'required run-attempt archive'
                else:
                    self.step(variant, job, upload_name)['with']['if-no-files-found'] = 'warn'
                    expected = 'required run-attempt archive'
                checks.append(WorkflowCheck(variant, diagnostic=expected, label={'job': job, 'mutation': mutation}))
        variant = copy.deepcopy(self.workflow)
        self.step(variant, 'macos_engine', 'Preserve Cargo timing evidence')['run'] += ' || true'
        checks.append(WorkflowCheck(variant, diagnostic='fail successful candidates with missing reports'))
        self.check_workflows(checks)

    def test_native_debug_evidence_upload_always_retains_the_complete_attempt(self):
        checks = []
        for mutation in ('removed', 'failure_only', 'no_attempt', 'partial_path', 'missing_error', 'moved'):
            variant = copy.deepcopy(self.workflow)
            steps = variant['jobs']['macos_swift']['steps']
            upload = self.step(variant, 'macos_swift', 'Upload Swift test diagnostics')
            if mutation == 'removed':
                steps.remove(upload)
            elif mutation == 'failure_only':
                upload['if'] = "always() && steps.debug.outcome == 'failure'"
            elif mutation == 'no_attempt':
                upload['with']['name'] = 'swift-test-diagnostics-${{ github.run_id }}'
            elif mutation == 'partial_path':
                upload['with']['path'] += '/native-events.jsonl'
            elif mutation == 'missing_error':
                upload['with']['if-no-files-found'] = 'error'
            else:
                steps.remove(upload)
                steps.insert(0, upload)
            expected = ('after checks and before their result gate' if mutation == 'moved' else
                        'complete run-attempt archive with missing-log warnings')
            checks.append(WorkflowCheck(variant, diagnostic=expected, label={'mutation': mutation}))
        self.check_workflows(checks)
