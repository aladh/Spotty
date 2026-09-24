#!/usr/bin/env ruby
# Parse topology first; report each protected invariant separately. Additional non-macOS lanes are allowed.
require 'yaml'
require 'json'

workflow = YAML.safe_load(File.read(ARGV.fetch(0)), permitted_classes: [], aliases: true)
jobs = workflow.fetch('jobs')
errors = []
check = ->(condition, message) { errors << message unless condition }
steps = jobs.values.flat_map { |job| job.fetch('steps', []) }
runs = steps.map { |step| step.fetch('run', '') }
all_runs = runs.join("\n")
policy = jobs.fetch('policy', {})
check.call(policy.dig('outputs', 'rust_needed'), 'policy must publish rust_needed')
check.call(policy.dig('outputs', 'macos_needed'), 'policy must publish macos_needed')
policy_runs = policy.fetch('steps', []).map { |s| s.fetch('run', '') }.join("\n")
policy_commands = policy_runs.lines.map(&:strip)
check.call(policy_commands.include?('git show "$INPUT_BASE_SHA:Scripts/ci_rust_policy.py" > "$trusted_policy"'), 'trusted-policy export must write the selected base policy to its execution path')
check.call(policy_commands.include?('python3 "$trusted_policy" --event "$EVENT_NAME" --base "$INPUT_BASE_SHA" >> "$GITHUB_OUTPUT"'), 'trusted-policy execution must receive event and base and publish its outputs')
policy_script = File.read(File.join(__dir__, 'check-source-policy.sh'))
check.call(policy_script.include?('"$ast_grep" scan --config sgconfig.yml Sources Backend/spotty-playback Scripts script Tests .github/workflows Package.swift'), 'local source scan must cover every policy root')
policy_lines = policy_script.lines.map(&:strip)
check.call(policy_lines.include?('python3 -B Scripts/script_tests.py policy'), 'source policy script must run the Python policy fixtures')
check.call(policy_lines.include?('npm test --prefix Scripts/agent-review-tests'), 'source policy script must run the Python and Node reviewer fixtures')
check.call(policy_lines.include?('python3 -B Scripts/documentation_policy.py'), 'source policy script must enforce documentation size limits')
review_package = JSON.parse(File.read(File.join(__dir__, 'agent-review-tests/package.json')))
check.call(review_package.dig('scripts', 'test') == 'python3 -B ../script_tests.py review', 'npm test must run the complete reviewer suite')
source_scans = policy.fetch('steps', []).select { |step| step.fetch('uses', '').start_with?('ast-grep/action@') }
check.call(source_scans.length == 1 && !source_scans.first.key?('if') && source_scans.first.dig('with', 'paths') == 'Sources Backend/spotty-playback Scripts script Tests .github/workflows Package.swift', 'independent source scan must run once without a condition and cover every policy root')
%w[policy playback_python].each do |id|
  job = jobs.fetch(id, {})
  check.call(!job.key?('if') && !job.key?('continue-on-error'), "#{id} tests must run unconditionally and fail the job")
  check.call(job.fetch('steps', []).none? { |step| step.key?('continue-on-error') }, "#{id} test steps must propagate failures")
end
required_test_steps = {
  'policy' => [
    'npm ci --ignore-scripts --prefix Scripts/agent-review-tests',
    './Scripts/check-source-policy.sh --test-only',
  ],
  'playback_python' => [
    'python3 -B Scripts/script_tests.py watchdog',
    'python3 -B Scripts/script_tests.py playback',
    'python3 -B Scripts/script_tests.py harness',
    './Scripts/format-swift-self-test.sh',
  ],
}
required_test_steps.each do |job_id, commands|
  job_steps = jobs.fetch(job_id, {}).fetch('steps', [])
  positions = []
  commands.each do |command|
    matches = job_steps.select { |step| step['run'] == command }
    check.call(matches.length == 1 && !matches.first.key?('if'), "#{job_id} must run #{command} once without a condition")
    positions << job_steps.index(matches.first)
  end
  check.call(positions.none?(&:nil?) && positions == positions.sort, "#{job_id} test setup and execution must remain ordered")
end
linux = jobs.values.find { |j| j['container'].to_s.start_with?('swift:') }
check.call(linux && linux.fetch('steps', []).any? { |s| s['run'] == 'swift build --target SpottyDomain' }, 'Linux must compile SpottyDomain')
check.call(linux && linux.fetch('steps', []).any? { |s| s['run'] == 'swift test --filter SpottyDomainTests' }, 'Linux must run domain tests')
playback_python = jobs.fetch('playback_python', {})
check.call(playback_python['name'] == 'Playback script checks' && playback_python['runs-on'] == 'ubuntu-latest', 'playback script checks must remain a portable Linux job')
playback_runs = playback_python.fetch('steps', []).map { |s| s.fetch('run', '') }.join("\n")
check.call(playback_runs.include?('apt-get install --no-install-recommends --yes zsh') && playback_runs.include?('zsh --version'), 'playback script checks must install their zsh fixture dependency')
check.call(playback_python.fetch('steps', []).any? { |s| s['run'] == 'python3 -B Scripts/script_tests.py playback' }, 'Linux must run the playback script checks')
mac = jobs.fetch('macos', {})
mac_steps = mac.fetch('steps', [])
check.call(jobs.values.all? { |job| job['runs-on'].is_a?(String) && !job['runs-on'].include?('${{') }, 'CI runner selection must remain static')
macos_jobs = jobs.values.select do |job|
  Array(job['runs-on']).any? { |label| label.to_s.downcase.include?('macos') }
end
check.call(macos_jobs == [mac], 'CI must use exactly one macOS runner job')
check.call(mac['runs-on'] == 'macos-26', 'macOS image must remain macos-26')
check.call(mac['name'] == 'macOS checks', 'required aggregate must retain the macOS checks name')
check.call(Array(mac['needs']).sort == %w[domain_linux playback_python policy], 'macOS must depend on policy, Linux domain, and playback script checks')
check.call(mac['if'] == "always() && needs.policy.outputs.macos_needed == 'true'", 'macOS must retain aggregate failure semantics while honoring docs-only skips')
check.call(mac_steps.none? { |step| step.key?('continue-on-error') }, 'macOS verification steps must fail without continue-on-error')
mac_step_ids = mac_steps.map { |step| step['id'] }.compact
check.call(mac_step_ids.uniq.length == mac_step_ids.length, 'macOS step IDs must be unique')
{'rust' => 'SPOTTY_CHECK_SCOPE=rust-compiled ./Scripts/check.sh', 'debug' => 'SPOTTY_CHECK_SCOPE=swift-compiled ./Scripts/check.sh', 'release' => './Scripts/compile-release-spotty.sh'}.each do |id, command|
  matches = mac_steps.select { |s| s['id'] == id }
  check.call(matches.length == 1 && matches[0]['run'] == command, "#{id} verification command must run once in the macOS job")
end
debug_step = mac_steps.find { |step| step['id'] == 'debug' } || {}
check.call(debug_step['timeout-minutes'] == 15, 'Swift Run checks must retain its 15-minute timeout')
mac_steps.each do |step|
  if step['id'] == 'rust'
    check.call(step['if'] == "needs.policy.outputs.rust_needed == 'true'", 'Rust execution must follow explicit classification')
  end
end
check.call(all_runs.include?('xcode-select -s /Applications/Xcode_26.6.app') && all_runs.include?("grep -q 'Apple Swift version 6.3.3'"), 'macOS must select and verify the pinned Swift toolchain')
cbindgen_steps = steps.select { |s| ['Restore pinned cbindgen', 'Install pinned cbindgen'].include?(s['name']) }
check.call(cbindgen_steps.length == 2 && cbindgen_steps.all? { |s| s['if'] == "needs.policy.outputs.rust_needed == 'true'" }, 'header parser setup must follow explicit Rust classification')
check.call(steps.any? { |s| s['id'] == 'debug' && s.dig('env', 'SPOTTY_CHECK_REPEATS').to_s.include?("'3'") }, 'main must repeat boundary checks three times')
check.call(all_runs.include?('for tool in cargo rustc rustup; do'), 'Swift lane must block Rust tools')
check.call(all_runs.include?('command -v rg') && all_runs.include?('brew install ripgrep'), 'use runner ripgrep before installing it')
candidate_matches = steps.select do |step|
  step['name'] == 'Identify playback inputs' || step['run'] == './Scripts/playback-candidate-needed.sh'
end
candidate = candidate_matches.first || {}
check.call(candidate_matches.length == 1 && mac_steps.include?(candidate), 'candidate selection must run exactly once in the macOS job')
check.call(candidate['name'] == 'Identify playback inputs' && candidate['id'] == 'inputs' && candidate['run'] == './Scripts/playback-candidate-needed.sh', 'candidate selection must retain its inputs step identity')
check.call(candidate['if'] == "needs.policy.outputs.rust_needed == 'true'", 'candidate selection must follow explicit Rust classification')
check.call(candidate.dig('env', 'INPUT_BASE_SHA') == '${{ github.event.pull_request.base.sha || github.event.before }}', 'candidate selection must receive the PR or push base SHA')
candidate_step_names = [
  'Restore Rust release build products',
  'Restore unchanged Rust release input timestamps',
  'Snapshot Rust release input timestamps',
  'Build candidate playback XCFramework',
  'Upload candidate playback artifact',
]
candidate_steps = []
candidate_step_names.each do |name|
  matches = mac_steps.select { |step| step['name'] == name }
  check.call(matches.length == 1, "#{name} must run once in the macOS job")
  step = matches.first
  check.call(step && step['if'] == "steps.inputs.outputs.candidate_needed == 'true'", "#{name} must follow the candidate-needed decision")
  candidate_steps << step if step
end
candidate_index = mac_steps.index(candidate)
check.call(candidate_index && candidate_steps.length == candidate_step_names.length && candidate_steps.all? { |step| candidate_index < mac_steps.index(step) }, 'candidate selection must precede every candidate-dependent step')
check.call(candidate_steps[3] && candidate_steps[3]['id'] == 'candidate_build', 'candidate build must retain its outcome identity')
check.call(candidate_steps[4] && candidate_steps[4]['id'] == 'candidate_upload', 'candidate upload must retain its outcome identity')
candidate_script = File.read(File.join(__dir__, 'playback-candidate-needed.sh'))
check.call(candidate_script.include?('digest="$(./Backend/spotty-playback/source-input-digest.sh)"'), 'candidate selection must compute the engine source input digest')
check.call(candidate_script.include?('echo "candidate_needed=$candidate_needed" >> "$GITHUB_OUTPUT"'), 'candidate selection must publish its decision')
check.call(all_runs.include?('./Scripts/report-size.sh'), 'release size reporting must run')
cache_restores = mac_steps.select { |s| s.fetch('uses', '').start_with?('actions/cache/restore@') }
check.call(cache_restores.any? { |s| s.dig('with', 'key').to_s.include?("hashFiles('Package.swift', 'Package.resolved')") }, 'Swift cache must key package inputs')
check.call(cache_restores.any? { |s| s.dig('with', 'key').to_s.include?("hashFiles('Backend/spotty-playback/Cargo.lock')") }, 'Rust cache must key Cargo.lock')
gate_matches = mac_steps.select { |s| s['name'] == 'Require every quality lane' }
gate = gate_matches.first || {}
check.call(gate_matches.length == 1, 'aggregate must run exactly once in the macOS job')
check.call(gate['if'] == 'always()', 'aggregate must run even after failures')
{
  'POLICY_RESULT' => '${{ needs.policy.result }}',
  'DOMAIN_LINUX_RESULT' => '${{ needs.domain_linux.result }}',
  'PLAYBACK_PYTHON_RESULT' => '${{ needs.playback_python.result }}',
  'CHECKS_RESULT' => '${{ steps.debug.outcome }}',
  'ACCEPTANCE_RESULT' => '${{ steps.acceptance.outcome }}',
  'ACCEPTANCE_SUMMARY_RESULT' => '${{ steps.acceptance_summary.outcome }}',
  'ACCEPTANCE_UPLOAD_RESULT' => '${{ steps.acceptance_upload.outcome }}',
  'RELEASE_RESULT' => '${{ steps.release.outcome }}'
}.each do |result, binding|
  check.call(gate.dig('env', result) == binding && gate.fetch('run', '').include?("test \"$#{result}\" = success"), "aggregate must require #{result} success")
end
acceptance_contract = lambda do |job_steps, result_gate, head_binding|
  check.call(job_steps.count { |step| step.fetch('run', '').include?('acceptance_scenarios.py run') } == 1,
             'acceptance corpus must execute once without implicit retries')
  spec = {
    'acceptance' => {
      'name' => 'Run acceptance scenarios',
      'timeout-minutes' => 10,
      'env' => { 'SPOTTY_ACCEPTANCE_HEAD_SHA' => head_binding },
      'run' => 'python3 Scripts/acceptance_scenarios.py run --corpus all --output "$RUNNER_TEMP/spotty-acceptance"',
    },
    'acceptance_summary' => {
      'name' => 'Summarize acceptance evidence',
      'if' => 'always()',
      'run' => 'python3 Scripts/acceptance_scenarios.py summary --output "$RUNNER_TEMP/spotty-acceptance" >> "$GITHUB_STEP_SUMMARY"',
    },
    'acceptance_upload' => {
      'name' => 'Upload acceptance evidence',
      'if' => 'always()',
      'uses' => 'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a',
      'with' => {
        'name' => 'acceptance-evidence-${{ github.run_id }}-${{ github.run_attempt }}',
        'path' => '${{ runner.temp }}/spotty-acceptance',
        'if-no-files-found' => 'error',
        'retention-days' => 7,
      },
    },
  }
  positions = []
  spec.each do |id, fields|
    matches = job_steps.select { |step| step['id'] == id || step['name'] == fields['name'] }
    expected = fields.merge('id' => id)
    check.call(matches.length == 1 && matches.first == expected, "#{id} must retain its single bounded execution and evidence contract")
    positions << job_steps.index(matches.first)
  end
  positions << job_steps.index(result_gate)
  check.call(positions.none?(&:nil?) && positions == positions.sort && positions.uniq.length == positions.length,
             'acceptance execution, summary, upload, and aggregate must remain ordered')
  %w[ACCEPTANCE_RESULT ACCEPTANCE_SUMMARY_RESULT ACCEPTANCE_UPLOAD_RESULT].zip(spec.keys).each do |result, id|
    check.call(result_gate.dig('env', result) == "${{ steps.#{id}.outcome }}" && result_gate.fetch('run', '').lines.map(&:strip).include?("test \"$#{result}\" = success"),
               "acceptance aggregate must require #{result} success")
  end
end
acceptance_contract.call(mac_steps, gate, '${{ github.event.pull_request.head.sha || github.sha }}')
acceptance_index = mac_steps.index { |step| step['id'] == 'acceptance' }
debug_index = mac_steps.index(debug_step)
release_index = mac_steps.index { |step| step['id'] == 'release' }
check.call(acceptance_index && debug_index && release_index && debug_index < acceptance_index && acceptance_index < release_index,
           'acceptance corpus must reuse the macOS lane after Swift checks and before Release compilation')

standalone_path = ARGV[1] || File.join(__dir__, '..', '.github', 'workflows', 'acceptance-scenarios.yml')
standalone = YAML.safe_load(File.read(standalone_path), permitted_classes: [], aliases: true)
triggers = standalone.fetch('on', standalone[true])
check.call(triggers.is_a?(Hash) && triggers.keys.sort == %w[workflow_call workflow_dispatch],
           'standalone acceptance must support only explicit dispatch and reusable calls')
check.call(standalone['permissions'] == { 'contents' => 'read' }, 'standalone acceptance must have read-only contents permissions')
standalone_jobs = standalone.fetch('jobs', {})
check.call(standalone_jobs.keys == ['acceptance'], 'standalone acceptance must run exactly one attempt without fanout')
standalone_job = standalone_jobs.fetch('acceptance', {})
check.call(standalone_job['runs-on'] == 'macos-26' && standalone_job['timeout-minutes'] == 20 &&
           (%w[strategy if continue-on-error secrets environment permissions] & standalone_job.keys).empty?,
           'standalone acceptance must retain its credential-free bounded macOS job')
standalone_steps = standalone_job.fetch('steps', [])
check.call(standalone_steps.none? { |step| step.key?('continue-on-error') }, 'standalone acceptance steps must propagate failure')
standalone_gate_matches = standalone_steps.select { |step| step['name'] == 'Require acceptance evidence' }
standalone_gate = standalone_gate_matches.first || {}
check.call(standalone_gate_matches.length == 1 && standalone_gate['if'] == 'always()',
           'standalone acceptance must always require execution and evidence outcomes')
acceptance_contract.call(standalone_steps, standalone_gate, '${{ github.sha }}')
{
  'CANDIDATE_SELECTION_RESULT' => '${{ steps.inputs.outcome }}',
  'CANDIDATE_NEEDED' => '${{ steps.inputs.outputs.candidate_needed }}',
  'CANDIDATE_BUILD_RESULT' => '${{ steps.candidate_build.outcome }}',
  'CANDIDATE_UPLOAD_RESULT' => '${{ steps.candidate_upload.outcome }}',
}.each do |result, binding|
  check.call(gate.dig('env', result) == binding, "aggregate must bind #{result} to its candidate step")
end
check.call(gate.dig('env', 'RUST_NEEDED') == '${{ needs.policy.outputs.rust_needed }}' && gate.dig('env', 'RUST_RESULT') == '${{ steps.rust.outcome }}', 'aggregate must bind the actual Rust decision and outcome')
candidate_cases = %w[true:success:success:true:success:success true:success:success:false:skipped:skipped false:skipped:skipped::skipped:skipped]
case_expression = 'case "$RUST_NEEDED:$RUST_RESULT:$CANDIDATE_SELECTION_RESULT:$CANDIDATE_NEEDED:$CANDIDATE_BUILD_RESULT:$CANDIDATE_UPLOAD_RESULT" in'
gate_lines = gate.fetch('run', '').lines.map(&:strip)
case_starts = gate_lines.each_index.select { |index| gate_lines[index] == case_expression }
case_body = []
case_structure_valid = case_starts.length == 1
if case_structure_valid
  case_end = ((case_starts[0] + 1)...gate_lines.length).find { |index| gate_lines[index] == 'esac' }
  case_structure_valid = !case_end.nil?
  case_body = gate_lines[(case_starts[0] + 1)...case_end].reject(&:empty?) if case_structure_valid
end
parsed_cases = []
default_cases = 0
case_body.each do |line|
  if line == '*) echo "Rust or candidate results disagree with verification selection" >&2; exit 1 ;;'
    default_cases += 1
  elsif (match = line.match(/\A((?:true|false)[^)]*)\)\s*;;\z/))
    parsed_cases.concat(match[1].split('|'))
  else
    case_structure_valid = false
  end
end
check.call(case_structure_valid && default_cases == 1 && parsed_cases.sort == candidate_cases.sort && parsed_cases.uniq.length == parsed_cases.length, 'aggregate must contain exactly the fail-closed Rust and candidate truth table')
cache_sha = '55cc8345863c7cc4c66a329aec7e433d2d1c52a9'
cache_specs = {
  'cbindgen_cache' => {
    restore_name: 'Restore pinned cbindgen',
    restore_if: "needs.policy.outputs.rust_needed == 'true'",
    save_name: 'Save pinned cbindgen',
    save_if: "success() && github.ref == 'refs/heads/main' && needs.policy.outputs.rust_needed == 'true' && steps.cbindgen_cache.outputs.cache-hit != 'true'",
  },
  'rust_debug_cache' => {
    restore_name: 'Restore Rust verification products',
    restore_if: "needs.policy.outputs.rust_needed == 'true'",
    save_name: 'Save Rust verification products',
    save_if: "success() && github.ref == 'refs/heads/main' && needs.policy.outputs.rust_needed == 'true' && steps.rust_debug_cache.outputs.cache-hit != 'true'",
  },
  'rust_release_cache' => {
    restore_name: 'Restore Rust release build products',
    restore_if: "steps.inputs.outputs.candidate_needed == 'true'",
    save_name: 'Save Rust release build products',
    save_if: "success() && github.ref == 'refs/heads/main' && steps.inputs.outputs.candidate_needed == 'true' && steps.rust_release_cache.outputs.cache-hit != 'true'",
  },
  'swift_cache' => {
    restore_name: 'Restore SwiftPM build directory',
    restore_if: nil,
    save_name: 'Save SwiftPM build directory',
    save_if: "success() && github.ref == 'refs/heads/main' && steps.swift_cache.outputs.cache-hit != 'true'",
  },
}
check.call(mac_steps.none? { |step| step.fetch('uses', '').start_with?('actions/cache@') }, 'macOS caches must restore without implicit PR saves')
cache_action_steps = mac_steps.select { |step| step.fetch('uses', '').start_with?('actions/cache') }
check.call(cache_action_steps.length == cache_specs.length * 2, 'macOS must contain exactly four paired cache restores and saves')
gate_index = mac_steps.index(gate)
cache_specs.each do |id, spec|
  restore_matches = mac_steps.select { |step| step['id'] == id && step['name'] == spec[:restore_name] }
  save_matches = mac_steps.select { |step| step['name'] == spec[:save_name] }
  restore = restore_matches.first || {}
  save = save_matches.first || {}
  check.call(restore_matches.length == 1 && restore['uses'] == "actions/cache/restore@#{cache_sha}" && restore['if'] == spec[:restore_if], "#{spec[:restore_name]} must remain the guarded restore owner")
  check.call(save_matches.length == 1 && save['uses'] == "actions/cache/save@#{cache_sha}" && save['if'] == spec[:save_if], "#{spec[:save_name]} must remain successful-main-only")
  check.call(save.dig('with', 'path') == restore.dig('with', 'path') && save.dig('with', 'key') == "${{ steps.#{id}.outputs.cache-primary-key }}", "#{spec[:save_name]} must save the restored paths under its primary key")
  check.call(gate_index && mac_steps.index(restore) && mac_steps.index(restore) < gate_index && mac_steps.index(save) && gate_index < mac_steps.index(save), "#{spec[:save_name]} must run only after the aggregate passes")
end
abort(errors.map { |e| "CI invariant: #{e}" }.join("\n")) unless errors.empty?
puts 'CI workflow invariants passed'
