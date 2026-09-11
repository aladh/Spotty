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
check.call(policy_runs.include?('git show "$INPUT_BASE_SHA:Scripts/ci_rust_policy.py"') && policy_runs.include?('python3 "$trusted_policy"'), 'PR classification must execute the trusted base policy')
check.call(steps.any? { |s| s.fetch('uses', '').start_with?('ast-grep/action@') && s.dig('with', 'paths') == 'Sources Backend/spotty-playback/src Scripts .github/workflows' }, 'source scan must cover every policy root')
check.call(runs.include?('./Scripts/check-source-policy.sh --test-only'), 'source policy fixtures must run')
linux = jobs.values.find { |j| j['container'].to_s.start_with?('swift:') }
check.call(linux && linux.fetch('steps', []).any? { |s| s['run'] == 'swift build --target SpottyDomain' }, 'Linux must compile SpottyDomain')
check.call(linux && linux.fetch('steps', []).any? { |s| s['run'] == 'swift test --filter SpottyDomainTests' }, 'Linux must run domain tests')
mac = jobs.fetch('macos', {})
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
check.call(runs.include?('./Scripts/playback-candidate-needed.sh'), 'candidate selection must compare engine inputs')
caches = steps.select { |s| s.fetch('uses', '').start_with?('actions/cache@') }
check.call(caches.any? { |s| s.dig('with', 'key').to_s.include?("hashFiles('Package.swift', 'Package.resolved')") }, 'Swift cache must key package inputs')
check.call(caches.any? { |s| s.dig('with', 'key').to_s.include?("hashFiles('Backend/spotty-playback/Cargo.lock')") }, 'Rust cache must key Cargo.lock')
gate = steps.find { |s| s['name'] == 'Require every quality lane' } || {}
check.call(gate['if'] == 'always()', 'aggregate must run even after failures')
%w[POLICY_RESULT DOMAIN_LINUX_RESULT CHECKS_RESULT RELEASE_RESULT].each do |result|
  check.call(gate.fetch('env', {}).key?(result) && gate.fetch('run', '').include?("test \"$#{result}\" = success"), "aggregate must require #{result} success")
end
check.call(gate.fetch('run', '').include?('test "$RUST_NEEDED" = false') && gate.fetch('run', '').include?('test "$RUST_RESULT" = skipped') && gate.fetch('run', '').include?('test "$RUST_RESULT" = success'), 'Rust skip must require an explicit negative classification')
abort(errors.map { |e| "CI invariant: #{e}" }.join("\n")) unless errors.empty?
puts 'CI workflow invariants passed'
