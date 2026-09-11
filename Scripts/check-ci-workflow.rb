#!/usr/bin/env ruby
# Parse topology first; report each protected invariant separately. Additional lanes are allowed.
require 'yaml'

workflow = YAML.safe_load(File.read(ARGV.fetch(0)), permitted_classes: [], aliases: true)
jobs = workflow.fetch('jobs')
errors = []
check = ->(condition, message) { errors << message unless condition }
steps = jobs.values.flat_map { |job| job.fetch('steps', []) }
runs = steps.map { |step| step.fetch('run', '') }
all_runs = runs.join("\n")
check.call(workflow['permissions'] == {'contents' => 'read'}, 'workflow permissions must remain contents: read')
steps.select { |s| s['uses'] }.each do |step|
  check.call(step['uses'].match?(/@[0-9a-f]{40}\z/), "#{step['name']}: action must use a full commit SHA")
  if step['uses'].start_with?('actions/checkout@')
    check.call(step.dig('with', 'persist-credentials') == false, "#{step['name']}: checkout must disable persisted credentials")
  end
end
policy = jobs.fetch('policy', {})
check.call(policy.dig('outputs', 'rust_needed'), 'policy must publish rust_needed')
check.call(policy.dig('outputs', 'macos_needed'), 'policy must publish macos_needed')
policy_runs = policy.fetch('steps', []).map { |s| s.fetch('run', '') }.join("\n")
policy_commands = policy_runs.lines.map(&:strip)
check.call(policy_commands.include?('git show "$INPUT_BASE_SHA:Scripts/ci_rust_policy.py" > "$trusted_policy"'), 'trusted-policy export must write the selected base policy to its execution path')
check.call(policy_commands.include?('python3 "$trusted_policy" --event "$EVENT_NAME" --base "$INPUT_BASE_SHA" >> "$GITHUB_OUTPUT"'), 'trusted-policy execution must receive event and base and publish its outputs')
policy_script = File.read(File.join(__dir__, 'check-source-policy.sh'))
check.call(policy_script.include?('"$ast_grep" scan --config sgconfig.yml Sources Backend/spotty-playback/src Scripts .github/workflows'), 'local source scan must cover every policy root')
check.call(policy_script.include?("python3 -B -m unittest discover -s Scripts -p 'test_*policy.py'"), 'source policy script must run the Python policy fixtures')
check.call(steps.any? { |s| s.fetch('uses', '').start_with?('ast-grep/action@') && s.dig('with', 'paths') == 'Sources Backend/spotty-playback/src Scripts .github/workflows' }, 'source scan must cover every policy root')
check.call(runs.include?('./Scripts/check-source-policy.sh --test-only'), 'source policy fixtures must run')
linux = jobs.values.find { |j| j['container'].to_s.start_with?('swift:') }
check.call(linux && linux.fetch('steps', []).any? { |s| s['run'] == 'swift build --target SpottyDomain' }, 'Linux must compile SpottyDomain')
check.call(linux && linux.fetch('steps', []).any? { |s| s['run'] == 'swift test --filter SpottyDomainTests' }, 'Linux must run domain tests')
mac = jobs.fetch('macos', {})
check.call(mac['runs-on'] == 'macos-26', 'macOS image must remain macos-26')
check.call(mac['name'] == 'macOS checks', 'required aggregate must retain the macOS checks name')
check.call(Array(mac['needs']).include?('policy') && Array(mac['needs']).include?('domain_linux'), 'aggregate must depend on policy and Linux domain')
{'rust' => 'SPOTTY_CHECK_SCOPE=rust ./Scripts/check.sh', 'debug' => 'SPOTTY_CHECK_SCOPE=swift ./Scripts/check.sh', 'release' => './Scripts/compile-release-spotty.sh'}.each do |id, command|
  check.call(steps.any? { |s| s['id'] == id && s['run'] == command }, "#{id} verification command must run")
end
steps.each do |step|
  check.call(step['continue-on-error'] != true, "#{step['name']}: verification must fail closed")
  if step['id'] == 'rust'
    check.call(step['if'] == "needs.policy.outputs.rust_needed == 'true'", 'Rust execution must follow explicit classification')
  end
end
check.call(all_runs.include?('xcode-select -s /Applications/Xcode_26.6.app') && all_runs.include?("grep -q 'Apple Swift version 6.3.3'"), 'macOS must select and verify the pinned Swift toolchain')
check.call(steps.any? { |s| s['name'] == 'Install pinned cbindgen' && !s.key?('if') }, 'header parser must be installed for app-only PRs')
check.call(steps.any? { |s| s['id'] == 'debug' && s.dig('env', 'SPOTTY_CHECK_REPEATS').to_s.include?("'3'") }, 'main must repeat boundary checks three times')
check.call(all_runs.include?('for tool in cargo rustc rustup; do'), 'Swift lane must block Rust tools')
check.call(all_runs.include?('command -v rg') && all_runs.include?('brew install ripgrep'), 'use runner ripgrep before installing it')
check.call(!all_runs.match?(/brew install (swift-format|swiftlint)/), 'Swift formatting must use Xcode')
candidate = steps.find { |s| s['run'] == './Scripts/playback-candidate-needed.sh' } || {}
check.call(!candidate.empty?, 'candidate selection must compare engine inputs')
check.call(candidate.dig('env', 'INPUT_BASE_SHA') == '${{ github.event.pull_request.base.sha || github.event.before }}', 'candidate selection must receive the PR or push base SHA')
%w[Build Upload].each do |verb|
  step = steps.find { |s| s['name'].to_s.start_with?("#{verb} candidate playback") } || {}
  check.call(step['if'] == "steps.inputs.outputs.candidate_needed == 'true'", "#{verb} candidate must follow the candidate-needed decision")
end
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
  'CHECKS_RESULT' => '${{ steps.debug.outcome }}',
  'RELEASE_RESULT' => '${{ steps.release.outcome }}'
}.each do |result, binding|
  check.call(gate.dig('env', result) == binding && gate.fetch('run', '').include?("test \"$#{result}\" = success"), "aggregate must require #{result} success")
end
check.call(gate.dig('env', 'RUST_NEEDED') == '${{ needs.policy.outputs.rust_needed }}' && gate.dig('env', 'RUST_RESULT') == '${{ steps.rust.outcome }}', 'aggregate must bind the actual Rust decision and outcome')
check.call(gate.fetch('run', '').include?('test "$RUST_NEEDED" = false') && gate.fetch('run', '').include?('test "$RUST_RESULT" = skipped') && gate.fetch('run', '').include?('test "$RUST_RESULT" = success'), 'Rust skip must require an explicit negative classification')
abort(errors.map { |e| "CI invariant: #{e}" }.join("\n")) unless errors.empty?
puts 'CI workflow invariants passed'
