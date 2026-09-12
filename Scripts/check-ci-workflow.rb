#!/usr/bin/env ruby
# Parse topology first; report each protected invariant separately. Additional non-macOS lanes are allowed.
require 'yaml'

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
check.call(policy_script.include?("python3 -B -m unittest discover -s Scripts -p 'test_*policy.py'"), 'source policy script must run the Python policy fixtures')
check.call(steps.any? { |s| s.fetch('uses', '').start_with?('ast-grep/action@') && s.dig('with', 'paths') == 'Sources Backend/spotty-playback Scripts script Tests .github/workflows Package.swift' }, 'source scan must cover every policy root')
check.call(runs.include?('./Scripts/check-source-policy.sh --test-only'), 'source policy fixtures must run')
linux = jobs.values.find { |j| j['container'].to_s.start_with?('swift:') }
check.call(linux && linux.fetch('steps', []).any? { |s| s['run'] == 'swift build --target SpottyDomain' }, 'Linux must compile SpottyDomain')
check.call(linux && linux.fetch('steps', []).any? { |s| s['run'] == 'swift test --filter SpottyDomainTests' }, 'Linux must run domain tests')
playback_python = jobs.fetch('playback_python', {})
check.call(playback_python['name'] == 'Playback script checks' && playback_python['runs-on'] == 'ubuntu-latest', 'playback script checks must remain a portable Linux job')
playback_runs = playback_python.fetch('steps', []).map { |s| s.fetch('run', '') }.join("\n")
check.call(playback_runs.include?('apt-get install --no-install-recommends --yes zsh') && playback_runs.include?('zsh --version'), 'playback script checks must install their zsh fixture dependency')
check.call(playback_python.fetch('steps', []).any? { |s| s['run'] == "python3 -B -m unittest discover -s Scripts -p 'test_playback_*.py'" }, 'Linux must run the playback script checks')
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
{'rust' => 'SPOTTY_CHECK_SCOPE=rust-compiled ./Scripts/check.sh', 'debug' => 'SPOTTY_CHECK_SCOPE=swift ./Scripts/check.sh', 'release' => './Scripts/compile-release-spotty.sh'}.each do |id, command|
  matches = mac_steps.select { |s| s['id'] == id }
  check.call(matches.length == 1 && matches[0]['run'] == command, "#{id} verification command must run once in the macOS job")
end
mac_steps.each do |step|
  if step['id'] == 'rust'
    check.call(step['if'] == "needs.policy.outputs.rust_needed == 'true'", 'Rust execution must follow explicit classification')
  end
end
check.call(all_runs.include?('xcode-select -s /Applications/Xcode_26.6.app') && all_runs.include?("grep -q 'Apple Swift version 6.3.3'"), 'macOS must select and verify the pinned Swift toolchain')
cbindgen_steps = steps.select { |s| ['Cache pinned cbindgen', 'Install pinned cbindgen'].include?(s['name']) }
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
  'Cache Rust release build products',
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
caches = steps.select { |s| s.fetch('uses', '').start_with?('actions/cache@') }
check.call(caches.any? { |s| s.dig('with', 'key').to_s.include?("hashFiles('Package.swift', 'Package.resolved')") }, 'Swift cache must key package inputs')
check.call(caches.any? { |s| s.dig('with', 'key').to_s.include?("hashFiles('Backend/spotty-playback/Cargo.lock')") }, 'Rust cache must key Cargo.lock')
gate = steps.find { |s| s['name'] == 'Require every quality lane' } || {}
check.call(gate['if'] == 'always()', 'aggregate must run even after failures')
{
  'POLICY_RESULT' => '${{ needs.policy.result }}',
  'DOMAIN_LINUX_RESULT' => '${{ needs.domain_linux.result }}',
  'PLAYBACK_PYTHON_RESULT' => '${{ needs.playback_python.result }}',
  'CHECKS_RESULT' => '${{ steps.debug.outcome }}',
  'RELEASE_RESULT' => '${{ steps.release.outcome }}'
}.each do |result, binding|
  check.call(gate.dig('env', result) == binding && gate.fetch('run', '').include?("test \"$#{result}\" = success"), "aggregate must require #{result} success")
end
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
check.call(candidate_cases.all? { |outcome| gate.fetch('run', '').include?(outcome) }, 'aggregate must fail closed over Rust selection and candidate outcomes')
abort(errors.map { |e| "CI invariant: #{e}" }.join("\n")) unless errors.empty?
puts 'CI workflow invariants passed'
