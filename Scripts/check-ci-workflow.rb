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
rust = jobs.fetch('rust_macos', {})
candidate_job = jobs.fetch('playback_candidate', {})
app = jobs.fetch('app_macos', {})
mac = jobs.fetch('macos', {})
workers = {'Rust checks' => rust, 'Playback candidate' => candidate_job, 'macOS app' => app}
workers.each do |name, job|
  check.call(job['name'] == name && job['runs-on'] == 'macos-26', "#{name} must remain on macos-26")
  check.call(Array(job['needs']) == ['policy'], "#{name} must depend only on policy so macOS work stays parallel")
end
check.call(rust['if'] == "needs.policy.outputs.rust_needed == 'true'", 'Rust job must follow explicit classification')
check.call(candidate_job['if'] == "needs.policy.outputs.rust_needed == 'true'", 'candidate job must follow explicit Rust classification')
check.call(app['if'] == "needs.policy.outputs.macos_needed == 'true'", 'app job must follow explicit macOS classification')
check.call(mac['name'] == 'macOS checks', 'required aggregate must retain the macOS checks name')
check.call(mac['runs-on'] == 'ubuntu-latest' && mac['timeout-minutes'].to_i.between?(1, 5), 'required aggregate must remain a short Linux job')
required_needs = %w[policy domain_linux rust_macos playback_candidate app_macos]
check.call(Array(mac['needs']).sort == required_needs.sort, 'aggregate must depend on every quality producer')
check.call(mac['if'] == 'always()', 'aggregate must run even after failures or intentional skips')
commands = {
  rust => {'rust' => 'SPOTTY_CHECK_SCOPE=rust ./Scripts/check.sh'},
  app => {'debug' => 'SPOTTY_CHECK_SCOPE=swift ./Scripts/check.sh', 'release' => './Scripts/compile-release-spotty.sh'},
}
commands.each do |job, expected|
  expected.each do |id, command|
    check.call(job.fetch('steps', []).any? { |s| s['id'] == id && s['run'] == command }, "#{id} verification command must run in its isolated job")
  end
end
workers.each_value do |job|
  worker_runs = job.fetch('steps', []).map { |step| step.fetch('run', '') }.join("\n")
  check.call(worker_runs.include?('xcode-select -s /Applications/Xcode_26.6.app'), "#{job['name']} must select the pinned Xcode")
end
check.call(app.fetch('steps', []).any? { |s| s.fetch('run', '').include?("grep -q 'Apple Swift version 6.3.3'") }, 'app job must verify the pinned Swift toolchain')
cbindgen_steps = rust.fetch('steps', []).select { |s| ['Cache pinned cbindgen', 'Install pinned cbindgen'].include?(s['name']) }
check.call(cbindgen_steps.length == 2 && cbindgen_steps.none? { |s| s.key?('if') }, 'Rust job must own unconditional pinned header parser setup')
check.call(app.fetch('steps', []).any? { |s| s['id'] == 'debug' && s.dig('env', 'SPOTTY_CHECK_REPEATS').to_s.include?("'3'") }, 'main must repeat boundary checks three times')
check.call(all_runs.include?('for tool in cargo rustc rustup; do'), 'Swift lane must block Rust tools')
check.call(all_runs.include?('command -v rg') && all_runs.include?('brew install ripgrep'), 'use runner ripgrep before installing it')
candidate = steps.find { |s| s['run'] == './Scripts/playback-candidate-needed.sh' } || {}
check.call(!candidate.empty?, 'candidate selection must compare engine inputs')
check.call(candidate.dig('env', 'INPUT_BASE_SHA') == '${{ github.event.pull_request.base.sha || github.event.before }}', 'candidate selection must receive the PR or push base SHA')
%w[Build Upload].each do |verb|
  step = candidate_job.fetch('steps', []).find { |s| s['name'].to_s.start_with?("#{verb} candidate playback") } || {}
  check.call(step['if'] == "steps.inputs.outputs.candidate_needed == 'true'", "#{verb} candidate must follow the candidate-needed decision")
end
candidate_script = File.read(File.join(__dir__, 'playback-candidate-needed.sh'))
check.call(candidate_script.include?('digest="$(./Backend/spotty-playback/source-input-digest.sh)"'), 'candidate selection must compute the engine source input digest')
check.call(candidate_script.include?('echo "candidate_needed=$candidate_needed" >> "$GITHUB_OUTPUT"'), 'candidate selection must publish its decision')
check.call(all_runs.include?('./Scripts/report-size.sh'), 'release size reporting must run')
caches = steps.select { |s| s.fetch('uses', '').start_with?('actions/cache@') }
check.call(caches.any? { |s| s.dig('with', 'key').to_s.include?("hashFiles('Package.swift', 'Package.resolved')") }, 'Swift cache must key package inputs')
check.call(caches.any? { |s| s.dig('with', 'key').to_s.include?("hashFiles('Backend/spotty-playback/Cargo.lock')") }, 'Rust cache must key Cargo.lock')
gate_steps = mac.fetch('steps', [])
gate = gate_steps.find { |s| s['name'] == 'Require every quality lane' } || {}
check.call(gate_steps.length == 1 && !gate.empty?, 'required aggregate must contain only the quality result gate')
{
  'POLICY_RESULT' => '${{ needs.policy.result }}',
  'DOMAIN_LINUX_RESULT' => '${{ needs.domain_linux.result }}',
  'RUST_NEEDED' => '${{ needs.policy.outputs.rust_needed }}',
  'MACOS_NEEDED' => '${{ needs.policy.outputs.macos_needed }}',
  'RUST_RESULT' => '${{ needs.rust_macos.result }}',
  'CANDIDATE_RESULT' => '${{ needs.playback_candidate.result }}',
  'APP_RESULT' => '${{ needs.app_macos.result }}',
}.each do |result, binding|
  check.call(gate.dig('env', result) == binding, "aggregate must bind #{result} to its actual producer")
end
check.call(gate.fetch('run', '').include?('test "$POLICY_RESULT" = success') && gate.fetch('run', '').include?('test "$DOMAIN_LINUX_RESULT" = success'), 'aggregate must require policy and Linux domain success')
check.call(gate.fetch('run', '').include?('true:success:success|false:skipped:skipped'), 'Rust and candidate skips must require an explicit negative classification')
check.call(gate.fetch('run', '').include?('true:success|false:skipped'), 'app skip must require an explicit negative classification')
abort(errors.map { |e| "CI invariant: #{e}" }.join("\n")) unless errors.empty?
puts 'CI workflow invariants passed'
