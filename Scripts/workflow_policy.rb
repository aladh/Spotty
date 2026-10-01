# Validate complete workflow inputs without filesystem or process side effects.
# Return diagnostics in rule order; malformed input raises rather than passing silently.
module WorkflowPolicy
  CACHE_SHA = '55cc8345863c7cc4c66a329aec7e433d2d1c52a9'
  UPLOAD_SHA = '043fb46d1a93c77aae656e7c1c64a875d1fc6a0a'
  DOWNLOAD_SHA = '3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c'
  VERIFY_JOBS = %w[macos_verify].freeze
  PHASES = %w[engine contracts tests release].freeze
  QUALITY_JOBS = %w[policy domain_linux playback_python macos_verify].freeze

  def self.one_step(check, steps, name)
    matches = steps.select { |step| step['name'] == name }
    check.call(matches.length == 1, "#{name} must run exactly once in its owning lane")
    matches.first || {}
  end

  def self.success_binding(check, gate, result, binding, label = 'aggregate')
    check.call(gate.dig('env', result) == binding && gate.fetch('run', '').lines.map(&:strip).include?("test \"$#{result}\" = success"),
               "#{label} must require #{result} success")
  end

  def self.case_table(check, gate, expression, expected, default, label)
    lines = gate.fetch('run', '').lines.map(&:strip)
    starts = lines.each_index.select { |index| lines[index] == "case \"$#{expression}\" in" }
    valid = starts.length == 1
    ending = valid && ((starts.first + 1)...lines.length).find { |index| lines[index] == 'esac' }
    valid &&= !!ending
    body = valid ? lines[(starts.first + 1)...ending].reject(&:empty?) : []
    cases = []
    defaults = 0
    body.each do |line|
      if line == default
        defaults += 1
      elsif (match = line.match(/\A([^)]*)\)\s*;;\z/))
        cases.concat(match[1].split('|'))
      else
        valid = false
      end
    end
    check.call(valid && defaults == 1 && cases.sort == expected.sort && cases.uniq.length == cases.length,
               "#{label} must retain its exact fail-closed truth table")
  end

  def self.gate_shell(check, gate, label)
    lines = gate.fetch('run', '').lines.map(&:strip).reject(&:empty?)
    check.call(lines.all? { |line| line.match?(/\A(?:test "\$[A-Z_]+" = success|case "\$[A-Z_]+(?::\$[A-Z_]+)*" in|esac|[^)]*\) ;;|\*\) echo "[^"]+" >&2; exit 1 ;;)\z/) },
               "#{label} must contain only fail-closed outcome checks")
  end

  def self.validate(workflow:, standalone:, policy_script:, candidate_script:, review_package:)
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
    check.call(policy_script.include?('"$ast_grep" scan --config sgconfig.yml Sources Backend/spotty-playback Scripts script Tests .github/workflows Package.swift'), 'local source scan must cover every policy root')
    policy_lines = policy_script.lines.map(&:strip)
    check.call(policy_lines.include?('python3 -B Scripts/script_tests.py policy'), 'source policy script must run the Python policy fixtures')
    check.call(policy_lines.include?('npm test --prefix Scripts/agent-review-tests'), 'source policy script must run the Python and Node reviewer fixtures')
    check.call(policy_lines.include?('python3 -B Scripts/documentation_policy.py'), 'source policy script must enforce documentation size limits')
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
    check.call(workflow['permissions'] == { 'contents' => 'read' }, 'CI must retain read-only contents permissions')
    triggers = workflow.fetch('on', workflow[true])
    check.call(triggers.is_a?(Hash) && triggers.keys.sort == %w[pull_request push] && triggers.dig('push', 'branches') == ['main'], 'CI must retain main-push and pull-request triggers')
    check.call(jobs.keys.sort == (QUALITY_JOBS + %w[quality_gate cache_publisher macos]).sort, 'CI must contain exactly the classified verification, quality, cache, and required lanes')
    check.call(jobs.values.all? { |job| job['runs-on'].is_a?(String) && !job['runs-on'].include?('${{') }, 'CI runner selection must remain static')
    macos_ids = jobs.select { |_id, job| job['runs-on'].to_s.downcase.include?('macos') }.keys
    check.call(macos_ids.sort == (VERIFY_JOBS + ['cache_publisher']).sort, 'CI must use one sequential macOS verification job and the downstream main cache publisher')
    jobs.each do |id, job|
      check.call(!job.key?('continue-on-error') && job.fetch('steps', []).none? { |step| step.key?('continue-on-error') }, "#{id} verification must propagate failures")
      check.call((%w[strategy secrets environment permissions] & job.keys).empty?, "#{id} must not add fanout, secrets, environments, or permission overrides")
      ids = job.fetch('steps', []).map { |step| step['id'] }.compact
      check.call(ids.uniq.length == ids.length, "#{id} step IDs must be unique")
      job.fetch('steps', []).select { |step| step.fetch('uses', '').start_with?('actions/checkout@') }.each do |step|
        check.call(step['uses'] == 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1' && step.dig('with', 'persist-credentials') == false && (step['id'] == 'engine_checkout' ? step['if'] == "needs.policy.outputs.rust_needed == 'true'" : !step.key?('if')), "#{id} checkout must retain its read-only pinned source contract")
      end
    end
    native = jobs.fetch('macos_verify', {})
    check.call(native['runs-on'] == 'macos-26', 'macos_verify macOS image must remain macos-26')
    check.call(Array(native['needs']) == ['policy'] && native['if'] == "needs.policy.result == 'success' && needs.policy.outputs.macos_needed == 'true'", 'macos_verify must start only after successful source policy and explicit classification')
    check.call(native.fetch('env', {}).values.none? { |value| value.to_s.include?('runner.') }, 'macos_verify job environment must not use unavailable runner context')
    check.call(native['name'] == 'macOS verification' && native['timeout-minutes'] == 120, 'native suite must retain its bounded unique producer job identity')
    native_steps = native.fetch('steps', [])
    boundaries = PHASES.map { |scope| native_steps.index { |step| step['id'] == "#{scope}_checkout" } }
    check.call(boundaries.none?(&:nil?) && boundaries == boundaries.sort && boundaries.uniq.length == PHASES.length && boundaries.first == 0,
               'native phases must retain ordered engine/contracts/tests/release checkout boundaries')
    check.call(native_steps.count { |step| step.fetch('uses', '').start_with?('actions/checkout@') } == PHASES.length,
               'native phases must retain exactly four fresh pinned checkouts')
    phases = PHASES.each_with_index.to_h do |scope, index|
      first = boundaries[index]
      last = boundaries[index + 1] || native_steps.length
      [scope, first && last && first < last ? native_steps[first...last] : []]
    end
    phases.each do |scope, lane_steps|
      rust_if = scope == 'engine' ? "needs.policy.outputs.rust_needed == 'true'" : nil
      initialize = one_step(check, lane_steps, 'Initialize timing evidence')
      initialize_command = "mkdir -p \"$RUNNER_TEMP/spotty-timings/#{scope}\"\necho \"SPOTTY_CI_TIMINGS_REPORT=$RUNNER_TEMP/spotty-timings/#{scope}/phases.jsonl\" >> \"$GITHUB_ENV\""
      check.call(initialize['run'].to_s.strip == initialize_command && initialize['if'] == rust_if && lane_steps.index(initialize) == 1,
                 "#{scope} must initialize required timing evidence immediately after checkout")
      xcode = one_step(check, lane_steps, 'Select Xcode 26.6')
      check.call(xcode['run'] == 'sudo xcode-select -s /Applications/Xcode_26.6.app' && xcode['if'] == rust_if,
                 "#{scope} must select the pinned Xcode before compilation")
      if scope == 'engine'
        lane_steps.each do |step|
          check.call(step.fetch('if', '').include?("needs.policy.outputs.rust_needed == 'true'"),
                     'every engine phase step must follow explicit Rust classification')
        end
      end
    end
    PHASES.each do |scope|
      checkout = phases.fetch(scope).first || {}
      check.call(checkout['id'] == "#{scope}_checkout" && checkout['name'] == "Check out #{scope} source" &&
                 checkout.dig('with', 'clean') == true && checkout.fetch('with', {}).keys.sort == %w[clean persist-credentials],
                 "#{scope} checkout must isolate the exact tested revision without overrides")
    end
    engine = native
    engine_steps = phases.fetch('engine')
    contracts_steps = phases.fetch('contracts')
    swift_steps = phases.fetch('tests')
    release_steps = phases.fetch('release')
    host_request = "github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository && contains(github.event.pull_request.labels.*.name, 'host-observation-evidence')"
    debug_command = <<~'SH'.strip
      case "$HOST_OBSERVATION_REQUESTED" in
        true)
          SPOTTY_CHECK_SCOPE=swift-compiled SPOTTY_CHECK_PHASE=tests python3 Scripts/swift_test_host_observation.py --timeout-seconds 840 --output-dir "$RUNNER_TEMP/spotty-host-observation" --build-root "$GITHUB_WORKSPACE/.build" -- ./Scripts/check.sh
          ;;
        false) SPOTTY_CHECK_SCOPE=swift-compiled SPOTTY_CHECK_PHASE=tests ./Scripts/check.sh ;;
        *) echo "Unknown host observation request" >&2; exit 1 ;;
      esac
    SH
    {
      'contracts' => ['contracts', 'Run Swift contracts', 'SPOTTY_CHECK_SCOPE=swift-compiled SPOTTY_CHECK_PHASE=contracts ./Scripts/check.sh'],
      'tests' => ['debug', 'Run checks', debug_command],
      'release' => ['release', 'Compile release Spotty with SPOTTY_DISTRIBUTION', './Scripts/compile-release-spotty.sh'],
      'engine' => ['rust', 'Run Rust checks', 'SPOTTY_CHECK_SCOPE=rust-compiled ./Scripts/check.sh'],
    }.each do |id, (step_id, name, command)|
      lane_steps = phases.fetch(id, [])
      matches = lane_steps.select { |step| step['id'] == step_id || step['name'] == name }
      step = matches.first || {}
      check.call(matches.length == 1 && step['id'] == step_id && step['run'].to_s.strip == command, "#{step_id} verification command must run once in its owning macOS lane")
      check.call(steps.count { |candidate| candidate['run'].to_s.strip == command } == 1, "#{step_id} verification must have exactly one CI owner")
      check.call(!step.key?('if'), "#{step_id} verification must not skip within its selected lane") unless step_id == 'rust'
      if %w[debug contracts].include?(step_id)
        check.call(step['timeout-minutes'] == 15, "#{name} must retain its 15-minute timeout")
      end
    end
    debug_step = swift_steps.find { |step| step['id'] == 'debug' } || {}
    check.call(debug_step.dig('env', 'SPOTTY_CHECK_REPEATS') == "${{ github.ref == 'refs/heads/main' && '3' || '1' }}", 'main must repeat boundary checks three times')
    check.call(debug_step.dig('env', 'HOST_OBSERVATION_REQUESTED') == "${{ #{host_request} }}", 'host observation must bind its trusted explicit request')
    %w[contracts tests release].each do |scope|
      id = scope
      lane = native
      lane_steps = phases.fetch(scope, [])
      tools = one_step(check, lane_steps, 'Show toolchains')
      check.call(tools.fetch('run', '').include?("grep -q 'Apple Swift version 6.3.3'") && !tools.key?('if'), "#{id} must verify the actual pinned Swift toolchain")
      blocked = one_step(check, lane_steps, 'Block Rust tools')
      check.call(blocked.fetch('run', '').include?('for tool in cargo rustc rustup; do') && !blocked.key?('if'), "#{id} must block Rust tools")
      install = one_step(check, lane_steps, 'Install verification tools')
      check.call(install.fetch('run', '').include?('command -v rg') && install.fetch('run', '').include?('brew install ripgrep'), "#{id} must use runner ripgrep before installation")
      identify = one_step(check, lane_steps, 'Identify Swift cache compatibility')
      command = "python3 Scripts/ci_cache_keys.py swift --lane #{scope} --revision \"$GITHUB_SHA\" --github-env \"$GITHUB_ENV\" --report \"$RUNNER_TEMP/spotty-timings/#{scope}/toolchain.json\""
      check.call(identify['run'].to_s.strip == command && !identify.key?('if'), "#{id} must identify its own exact compiler and build contract")
      check.call(lane.dig('outputs', "#{scope}_key") == "${{ steps.#{scope}_cache.outputs.cache-primary-key }}", "#{id} must export its actual cache identity")
      restore = one_step(check, lane_steps, 'Restore unchanged Swift input timestamps')
      snapshot = one_step(check, lane_steps, 'Snapshot Swift input timestamps')
      check.call(restore['run'] == 'python3 Scripts/ci_source_mtimes.py restore' && snapshot['run'] == 'python3 Scripts/ci_source_mtimes.py save' && !restore.key?('if') && !snapshot.key?('if') && lane_steps.index(restore).to_i < lane_steps.index(snapshot).to_i, "#{id} must preserve hash-checked source timestamp restoration before snapshot")
    end
    %w[Show\ Rust\ toolchain Restore\ pinned\ cbindgen Install\ pinned\ cbindgen Identify\ playback\ inputs Restore\ Rust\ verification\ products Run\ Rust\ checks Preflight\ public\ Cargo\ source\ proof].each do |name|
      step = one_step(check, engine_steps, name)
      check.call(step['if'] == "needs.policy.outputs.rust_needed == 'true'", "#{name} must follow explicit Rust classification")
    end
    source_proof = one_step(check, engine_steps, 'Preflight public Cargo source proof')
    source_proof_command = 'python3 Scripts/ci_cache_bundle.py preflight --scope rust-debug --revision "$GITHUB_SHA" --cargo-home "${CARGO_HOME:-$HOME/.cargo}"'
    check.call(source_proof['id'] == 'source_proof' && source_proof['run'].to_s.strip == source_proof_command, 'public Cargo source preflight must retain its exact proof command and outcome identity')
    check.call(steps.count { |step| step['run'].to_s.strip == source_proof_command } == 1, 'public Cargo source preflight must have exactly one CI owner')
    candidate = one_step(check, engine_steps, 'Identify playback inputs')
    check.call(candidate['id'] == 'inputs' && candidate['run'] == './Scripts/playback-candidate-needed.sh', 'candidate selection must retain its inputs step identity')
    check.call(candidate.dig('env', 'INPUT_BASE_SHA') == '${{ github.event.pull_request.base.sha || github.event.before }}', 'candidate selection must receive the PR or push base SHA')
    rust_identity = one_step(check, engine_steps, 'Identify Rust cache compatibility')
    check.call(rust_identity['run'].to_s.strip == 'python3 Scripts/ci_cache_keys.py rust --revision "$GITHUB_SHA" --github-env "$GITHUB_ENV" --report "$RUNNER_TEMP/spotty-timings/engine/toolchain.json"' && rust_identity['if'] == "needs.policy.outputs.rust_needed == 'true'", 'Rust Release cache must identify its actual SDK and compiler contract')
    rust_debug_identity = one_step(check, engine_steps, 'Identify Rust Debug cache compatibility')
    debug_identity_lines = rust_debug_identity.fetch('run', '').lines.map(&:strip)
    check.call(rust_debug_identity['shell'] == 'zsh {0}' && rust_debug_identity['if'] == "needs.policy.outputs.rust_needed == 'true'" &&
               debug_identity_lines.include?('source Scripts/swiftpm-env.sh') &&
               debug_identity_lines.include?('python3 Scripts/ci_cache_keys.py rust --revision "$GITHUB_SHA" --report "$RUNNER_TEMP/spotty-timings/engine/debug-toolchain.json"') &&
               debug_identity_lines.last.to_s.include?('RUST_DEBUG_TOOLCHAIN_KEY=') && debug_identity_lines.last.to_s.end_with?('>> "$GITHUB_ENV"'), 'Rust Debug cache must identify the actual verification SDK and publish its isolated key')
    candidate_steps = ['Restore Rust release build products', 'Restore unchanged Rust release input timestamps', 'Snapshot Rust release input timestamps', 'Build candidate playback XCFramework', 'Upload candidate playback artifact'].map do |name|
      step = one_step(check, engine_steps, name)
      check.call(step['if'] == "needs.policy.outputs.rust_needed == 'true' && steps.inputs.outputs.candidate_needed == 'true'", "#{name} must follow the candidate-needed decision")
      step
    end
    positions = [candidate, *candidate_steps].map { |step| engine_steps.index(step) }
    check.call(positions.none?(&:nil?) && positions == positions.sort && positions.uniq.length == positions.length, 'candidate selection, timestamps, build, and upload must remain ordered')
    proof_positions = [engine_steps.find { |step| step['name'] == 'Run Rust checks' }, source_proof, candidate_steps.first].map { |step| engine_steps.index(step) }
    check.call(proof_positions.none?(&:nil?) && proof_positions == proof_positions.sort && proof_positions.uniq.length == proof_positions.length, 'public Cargo source preflight must follow Rust verification and precede Release restoration')
    check.call(candidate_steps[3]['id'] == 'candidate_build', 'candidate build must retain its outcome identity')
    check.call(candidate_steps[4]['id'] == 'candidate_upload', 'candidate upload must retain its outcome identity')
    check.call(candidate_script.include?('digest="$(./Backend/spotty-playback/source-input-digest.sh)"'), 'candidate selection must compute the engine source input digest')
    check.call(candidate_script.include?('echo "candidate_needed=$candidate_needed" >> "$GITHUB_OUTPUT"'), 'candidate selection must publish its decision')
    {
      'candidate_needed' => 'inputs.outputs.candidate_needed', 'rust_result' => 'rust.outcome',
      'candidate_selection_result' => 'inputs.outcome', 'candidate_build_result' => 'candidate_build.outcome',
      'candidate_upload_result' => 'candidate_upload.outcome', 'cbindgen_key' => 'cbindgen_cache.outputs.cache-primary-key',
      'rust_debug_key' => 'rust_debug_cache.outputs.cache-primary-key', 'rust_release_key' => 'rust_release_cache.outputs.cache-primary-key',
    }.each do |output, binding|
      check.call(engine.dig('outputs', output) == "${{ steps.#{binding} }}", "engine must bind its actual #{output} output")
    end
    {'engine_result' => 'engine_gate.outcome', 'contracts_result' => 'contracts.outcome',
     'swift_result' => 'debug.outcome', 'release_result' => 'release.outcome'}.each do |output, binding|
      check.call(native.dig('outputs', output) == "${{ steps.#{binding} }}", "native job must bind its actual #{output} output")
    end
    expected_outputs = %w[engine_result contracts_result swift_result release_result contracts_key tests_key release_key
                          candidate_needed rust_result candidate_selection_result candidate_build_result candidate_upload_result
                          cbindgen_key rust_debug_key rust_release_key]
    check.call(native.fetch('outputs', {}).keys.sort == expected_outputs.sort,
               'native outputs must retain exactly the producer and consumer outcome/cache bindings')
    engine_gate = one_step(check, engine_steps, 'Require engine results')
    gate_shell(check, engine_gate, 'engine gate')
    check.call(engine_gate['id'] == 'engine_gate' && engine_gate['if'] == "always() && needs.policy.outputs.rust_needed == 'true'", 'engine outcome gate must run even after failures')
    success_binding(check, engine_gate, 'RUST_RESULT', '${{ steps.rust.outcome }}', 'engine gate')
    success_binding(check, engine_gate, 'SOURCE_PROOF_RESULT', '${{ steps.source_proof.outcome }}', 'engine gate')
    {'SELECTION_RESULT' => 'inputs.outcome', 'CANDIDATE_NEEDED' => 'inputs.outputs.candidate_needed', 'BUILD_RESULT' => 'candidate_build.outcome', 'UPLOAD_RESULT' => 'candidate_upload.outcome'}.each do |result, binding|
      check.call(engine_gate.dig('env', result) == "${{ steps.#{binding} }}", "engine gate must bind #{result} to its actual step")
    end
    case_table(check, engine_gate, 'SELECTION_RESULT:$CANDIDATE_NEEDED:$BUILD_RESULT:$UPLOAD_RESULT', %w[success:true:success:success success:false:skipped:skipped], '*) echo "Engine candidate results disagree with selection" >&2; exit 1 ;;', 'engine gate')
    cargo_evidence = one_step(check, engine_steps, 'Preserve Cargo timing evidence')
    cargo_command = "set -euo pipefail\nif [[ -d Backend/spotty-playback/target/cargo-timings ]]; then\n  cp -R Backend/spotty-playback/target/cargo-timings \"$RUNNER_TEMP/spotty-timings/engine/cargo\"\nelif [[ \"$CANDIDATE_BUILD_RESULT\" == success ]]; then\n  echo \"Successful timed Cargo build has no compiler timing report\" >&2\n  exit 1\nfi"
    check.call(cargo_evidence['if'] == "always() && needs.policy.outputs.rust_needed == 'true' && steps.inputs.outputs.candidate_needed == 'true'" && cargo_evidence.dig('env', 'CANDIDATE_BUILD_RESULT') == '${{ steps.candidate_build.outcome }}' && cargo_evidence['run'].to_s.strip == cargo_command, 'Cargo timing evidence must preserve diagnostics and fail successful candidates with missing reports')
    timing_upload_names = ['Upload engine timing evidence', 'Upload contracts timing evidence', 'Upload Swift timing evidence', 'Upload Release timing evidence']
    PHASES.zip(timing_upload_names).each do |scope, name|
      lane_steps = phases.fetch(scope, [])
      upload = one_step(check, lane_steps, name)
      check.call(upload['if'] == (scope == 'engine' ? "always() && needs.policy.outputs.rust_needed == 'true'" : 'always()') && upload['uses'] == "actions/upload-artifact@#{UPLOAD_SHA}" && upload['with'] == {'name' => "timings-#{scope}-${{ github.run_id }}-${{ github.run_attempt }}", 'path' => "${{ runner.temp }}/spotty-timings/#{scope}", 'if-no-files-found' => 'error', 'retention-days' => 7}, "#{scope} timing evidence must retain its required run-attempt archive")
      if scope == 'engine'
        positions = [engine_gate, cargo_evidence, upload].map { |step| lane_steps.index(step) }
        check.call(positions.none?(&:nil?) && positions == positions.sort && positions.uniq.length == positions.length, 'Cargo evidence must be preserved after the engine gate and before upload')
      end
    end
    swift_gate = one_step(check, swift_steps, 'Require Swift test evidence')
    gate_shell(check, swift_gate, 'Swift evidence gate')
    check.call(swift_gate['if'] == 'always()', 'Swift evidence gate must run even after failures')
    success_binding(check, swift_gate, 'CHECKS_RESULT', '${{ steps.debug.outcome }}', 'Swift evidence gate')
    selection_request = "github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository && contains(github.event.pull_request.labels.*.name, 'focused-selection-evidence')"
    selection_specs = {
      'focused_smoke' => {
        'name' => 'Prove focused test selection', 'timeout-minutes' => 5,
        'run' => 'python3 Scripts/focused_selection_evidence.py smoke --output "$RUNNER_TEMP/spotty-selection/smoke" --swift-version 6.3.3',
      },
      'selection_experiment' => {
        'name' => 'Collect supported-toolchain selection evidence', 'timeout-minutes' => 20,
        'if' => "success() && #{selection_request} && steps.acceptance.outcome == 'success' && steps.acceptance_summary.outcome == 'success' && steps.acceptance_upload.outcome == 'success'",
        'env' => { 'SELECTION_HEAD_SHA' => '${{ github.event.pull_request.head.sha }}' },
        'run' => 'python3 Scripts/focused_selection_evidence.py compatibility --source "$GITHUB_WORKSPACE" --head "$SELECTION_HEAD_SHA" --output "$RUNNER_TEMP/spotty-selection/compatibility" --swift-version 6.3.3',
      },
      'selection_upload' => {
        'name' => 'Upload focused selection evidence', 'if' => 'always()',
        'uses' => "actions/upload-artifact@#{UPLOAD_SHA}",
        'with' => {
          'name' => 'focused-selection-${{ github.run_id }}-${{ github.run_attempt }}',
          'path' => '${{ runner.temp }}/spotty-selection', 'if-no-files-found' => 'error', 'retention-days' => 7,
        },
      },
    }
    selection_specs.each do |id, fields|
      matches = swift_steps.select { |step| step['id'] == id || step['name'] == fields['name'] }
      check.call(matches.length == 1 && matches.first == fields.merge('id' => id), "#{id} must retain its bounded exact selection evidence contract")
    end
    positions = ['debug', 'focused_smoke', 'acceptance', 'acceptance_upload', 'selection_experiment', 'selection_upload'].map do |id|
      swift_steps.index { |step| step['id'] == id }
    end
    positions << swift_steps.index(swift_gate)
    check.call(positions.none?(&:nil?) && positions == positions.sort && positions.uniq.length == positions.length,
               'focused selection proof must follow Debug and preserve successful corpus ordering')
    success_binding(check, swift_gate, 'FOCUSED_SMOKE_RESULT', '${{ steps.focused_smoke.outcome }}', 'focused selection gate')
    success_binding(check, swift_gate, 'SELECTION_UPLOAD_RESULT', '${{ steps.selection_upload.outcome }}', 'focused selection gate')
    check.call(swift_gate.dig('env', 'SELECTION_EXPERIMENT_REQUESTED') == "${{ #{selection_request} }}" &&
               swift_gate.dig('env', 'SELECTION_EXPERIMENT_RESULT') == '${{ steps.selection_experiment.outcome }}',
               'focused selection gate must bind actual trusted request and outcome')
    case_table(check, swift_gate, 'SELECTION_EXPERIMENT_REQUESTED:$SELECTION_EXPERIMENT_RESULT', %w[true:success false:skipped], '*) echo "Focused selection evidence disagrees with request" >&2; exit 1 ;;', 'focused selection aggregate')
    host_upload = one_step(check, swift_steps, 'Upload executing-host observation')
    check.call(host_upload == {
      'name' => 'Upload executing-host observation', 'id' => 'host_observation_upload',
      'if' => "always() && #{host_request}", 'uses' => "actions/upload-artifact@#{UPLOAD_SHA}",
      'with' => { 'name' => 'test-host-observation-${{ github.run_id }}-${{ github.run_attempt }}',
                  'path' => '${{ runner.temp }}/spotty-host-observation', 'if-no-files-found' => 'error', 'retention-days' => 7 },
    }, 'host observation upload must retain trusted request and complete failed or successful evidence')
    check.call(swift_gate.dig('env', 'HOST_OBSERVATION_REQUESTED') == "${{ #{host_request} }}" &&
               swift_gate.dig('env', 'HOST_OBSERVATION_UPLOAD_RESULT') == '${{ steps.host_observation_upload.outcome }}',
               'host observation gate must bind actual request and upload outcome')
    case_table(check, swift_gate, 'HOST_OBSERVATION_REQUESTED:$HOST_OBSERVATION_UPLOAD_RESULT', %w[true:success false:skipped], '*) echo "Host observation evidence disagrees with request" >&2; exit 1 ;;', 'host observation aggregate')
    check.call(swift_steps.index(debug_step).to_i < swift_steps.index(host_upload).to_i &&
               swift_steps.index(host_upload).to_i < swift_steps.index(swift_gate).to_i,
               'host observation upload must follow its invocation and precede the outcome gate')
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
    acceptance_contract.call(swift_steps, swift_gate, '${{ github.event.pull_request.head.sha || github.sha }}')
    check.call(runs.count { |run| run.include?('acceptance_scenarios.py run') } == 1, 'CI acceptance corpus must have exactly one owner')
    acceptance_index = swift_steps.index { |step| step['id'] == 'acceptance' }
    debug_index = swift_steps.index(debug_step)
    check.call(acceptance_index && debug_index && debug_index < acceptance_index,
               'acceptance corpus must run after Swift checks in its owning lane')
    gui_spec = {
      'gui' => {
        'name' => 'Run Demo GUI regression', 'timeout-minutes' => 6,
        'env' => { 'GUI_REVISION' => '${{ github.sha }}' },
        'run' => './Scripts/check-gui-regression.sh --output "$RUNNER_TEMP/spotty-gui-regression" --expected-head "$GUI_REVISION" --qualify-hosted-display',
      },
      'gui_upload' => {
        'name' => 'Upload Demo GUI evidence', 'if' => "always() && steps.gui.outcome != 'skipped'",
        'uses' => "actions/upload-artifact@#{UPLOAD_SHA}",
        'with' => { 'name' => 'gui-regression-${{ github.run_id }}-${{ github.run_attempt }}',
                    'path' => '${{ runner.temp }}/spotty-gui-regression', 'if-no-files-found' => 'error', 'retention-days' => 7 },
      },
    }
    gui_positions = [debug_index, swift_steps.index { |step| step['id'] == 'acceptance_upload' }]
    gui_spec.each do |id, fields|
      matches = swift_steps.select { |step| step['id'] == id || step['name'] == fields['name'] }
      check.call(matches.length == 1 && matches.first == fields.merge('id' => id),
                 "#{id} GUI regression must retain its required bounded execution and evidence contract")
      gui_positions << swift_steps.index(matches.first)
    end
    gui_positions << swift_steps.index(swift_gate)
    check.call(gui_positions.none?(&:nil?) && gui_positions == gui_positions.sort && gui_positions.uniq.length == gui_positions.length,
               'GUI regression must follow Swift checks and upload before the outcome gate')
    check.call(runs.count { |run| run.include?('check-gui-regression.sh') } == 1,
               'GUI regression must execute once in its owning lane without retries')
    %w[GUI_RESULT GUI_UPLOAD_RESULT].zip(gui_spec.keys).each do |result, id|
      check.call(swift_gate.dig('env', result) == "${{ steps.#{id}.outcome }}" &&
                 swift_gate.fetch('run', '').lines.map(&:strip).include?("test \"$#{result}\" = success"),
                 "GUI regression aggregate must require #{result} success")
    end
    debug_evidence = one_step(check, swift_steps, 'Upload Swift test diagnostics')
    debug_evidence_spec = {
      'name' => 'Upload Swift test diagnostics',
      'if' => 'always()',
      'uses' => "actions/upload-artifact@#{UPLOAD_SHA}",
      'with' => {
        'name' => 'swift-test-diagnostics-${{ github.run_id }}-${{ github.run_attempt }}',
        'path' => '${{ runner.temp }}/spotty-swift-test-diagnostics',
        'if-no-files-found' => 'warn',
        'retention-days' => 7,
      },
    }
    check.call(debug_evidence == debug_evidence_spec,
               'Swift native test evidence must always retain its complete run-attempt archive with missing-log warnings')
    debug_evidence_index = swift_steps.index(debug_evidence)
    swift_gate_index = swift_steps.index(swift_gate)
    check.call(debug_index && debug_evidence_index && swift_gate_index && debug_index < debug_evidence_index && debug_evidence_index < swift_gate_index,
               'Swift native test evidence must be archived after checks and before their result gate')

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
    gate_shell(check, standalone_gate, 'standalone acceptance gate')
    check.call(standalone_gate_matches.length == 1 && standalone_gate['if'] == 'always()',
               'standalone acceptance must always require execution and evidence outcomes')
    acceptance_contract.call(standalone_steps, standalone_gate, '${{ github.sha }}')
    quality = jobs.fetch('quality_gate', {})
    check.call(quality['runs-on'] == 'ubuntu-latest' && quality['if'] == 'always()' && Array(quality['needs']).sort == QUALITY_JOBS.sort, 'quality aggregate must always require every classified and portable lane')
    gate = one_step(check, quality.fetch('steps', []), 'Require every quality lane')
    gate_shell(check, gate, 'quality aggregate')
    check.call(!gate.key?('if'), 'quality aggregate step must run unconditionally')
    %w[POLICY_RESULT DOMAIN_LINUX_RESULT PLAYBACK_PYTHON_RESULT].zip(%w[policy domain_linux playback_python]).each do |result, id|
      success_binding(check, gate, result, "${{ needs.#{id}.result }}")
    end
    {
      'MACOS_NEEDED' => 'policy.outputs.macos_needed', 'RUST_NEEDED' => 'policy.outputs.rust_needed',
      'MACOS_RESULT' => 'macos_verify.result', 'CONTRACTS_RESULT' => 'macos_verify.outputs.contracts_result', 'SWIFT_RESULT' => 'macos_verify.outputs.swift_result', 'RELEASE_RESULT' => 'macos_verify.outputs.release_result',
      'ENGINE_RESULT' => 'macos_verify.outputs.engine_result', 'RUST_RESULT' => 'macos_verify.outputs.rust_result',
      'CANDIDATE_SELECTION_RESULT' => 'macos_verify.outputs.candidate_selection_result', 'CANDIDATE_NEEDED' => 'macos_verify.outputs.candidate_needed',
      'CANDIDATE_BUILD_RESULT' => 'macos_verify.outputs.candidate_build_result', 'CANDIDATE_UPLOAD_RESULT' => 'macos_verify.outputs.candidate_upload_result',
    }.each do |result, binding|
      check.call(gate.dig('env', result) == "${{ needs.#{binding} }}", "quality aggregate must bind actual #{result}")
    end
    case_table(check, gate, 'MACOS_NEEDED:$MACOS_RESULT', %w[true:success false:skipped], '*) echo "macOS results disagree with verification selection" >&2; exit 1 ;;', 'native job aggregate')
    case_table(check, gate, 'MACOS_NEEDED:$RUST_NEEDED', %w[true:true true:false false:false], '*) echo "Invalid compiler verification selection" >&2; exit 1 ;;', 'compiler selection aggregate')
    case_table(check, gate, 'MACOS_NEEDED:$CONTRACTS_RESULT:$SWIFT_RESULT:$RELEASE_RESULT', %w[true:success:success:success false:::], '*) echo "Swift lane results disagree with verification selection" >&2; exit 1 ;;', 'Swift lane aggregate')
    case_table(check, gate, 'MACOS_NEEDED:$RUST_NEEDED:$ENGINE_RESULT:$RUST_RESULT:$CANDIDATE_SELECTION_RESULT:$CANDIDATE_NEEDED:$CANDIDATE_BUILD_RESULT:$CANDIDATE_UPLOAD_RESULT', %w[true:true:success:success:success:true:success:success true:true:success:success:success:false:skipped:skipped true:false:skipped:skipped:skipped::skipped:skipped false:false::::::], '*) echo "Rust or candidate results disagree with verification selection" >&2; exit 1 ;;', 'Rust and candidate aggregate')
    stable = jobs.fetch('macos', {})
    check.call(stable['name'] == 'macOS checks', 'required aggregate must retain the macOS checks name')
    check.call(stable['runs-on'] == 'ubuntu-latest', 'required aggregate must use its portable Ubuntu runner')
    check.call(stable['if'] == 'always()' && Array(stable['needs']).sort == %w[cache_publisher quality_gate], 'required aggregate must always join quality and cache publication')
    terminal = one_step(check, stable.fetch('steps', []), 'Require completed verification and cache publication')
    gate_shell(check, terminal, 'required aggregate')
    check.call(!terminal.key?('if'), 'required aggregate step must run unconditionally')
    success_binding(check, terminal, 'QUALITY_RESULT', '${{ needs.quality_gate.result }}', 'required aggregate')
    check.call(terminal.dig('env', 'MAIN_REF') == '${{ github.ref }}' && terminal.dig('env', 'CACHE_RESULT') == '${{ needs.cache_publisher.result }}', 'required aggregate must bind actual event and cache results')
    case_table(check, terminal, 'MAIN_REF:$CACHE_RESULT', %w[refs/heads/main:success refs/pull/*:skipped], '*) echo "Cache publication disagrees with verified event" >&2; exit 1 ;;', 'required cache aggregate')
    publisher = jobs.fetch('cache_publisher', {})
    check.call(publisher['runs-on'] == 'macos-26' && publisher['if'] == "github.ref == 'refs/heads/main' && needs.quality_gate.result == 'success'" && Array(publisher['needs']).sort == (VERIFY_JOBS + ['quality_gate']).sort, 'cache publisher must follow successful aggregate verification on main only')
    publisher_steps = publisher.fetch('steps', [])
    specs = {
      'contracts' => ['contracts', 'swift', 'contracts_cache', nil, '.build/*\n!.build/spotty-signing', '${{ needs.macos_verify.outputs.contracts_key }}'],
      'tests' => ['tests', 'swift', 'tests_cache', nil, '.build/*\n!.build/spotty-signing', '${{ needs.macos_verify.outputs.tests_key }}'],
      'release' => ['release', 'swift', 'release_cache', nil, '.build/*\n!.build/spotty-signing', '${{ needs.macos_verify.outputs.release_key }}'],
      'cbindgen' => ['engine', 'cbindgen', 'cbindgen_cache', "needs.policy.outputs.rust_needed == 'true'", '${{ runner.temp }}/spotty-cbindgen', '${{ needs.macos_verify.outputs.cbindgen_key }}'],
      'rust-debug' => ['engine', 'rust-debug', 'rust_debug_cache', "needs.policy.outputs.rust_needed == 'true'", '~/.cargo/git\n~/.cargo/registry\nBackend/spotty-playback/target/debug\nBackend/spotty-playback/target/.rustc_info.json', '${{ needs.macos_verify.outputs.rust_debug_key }}'],
      'rust-release' => ['engine', 'rust-release', 'rust_release_cache', "needs.policy.outputs.rust_needed == 'true' && steps.inputs.outputs.candidate_needed == 'true'", 'Backend/spotty-playback/target/aarch64-apple-darwin/release\nBackend/spotty-playback/target/release', '${{ needs.macos_verify.outputs.rust_release_key }}'],
    }
    restores = steps.select { |step| step.fetch('uses', '').start_with?('actions/cache/restore@') }
    saves = steps.select { |step| step.fetch('uses', '').start_with?('actions/cache/save@') }
    check.call(restores.length == specs.length && saves.length == specs.length && steps.none? { |step| step.fetch('uses', '').start_with?('actions/cache@') }, 'CI must retain exactly six explicit cache restores and publisher saves without implicit PR writes')
    specs.each do |name, (job_id, scope, restore_id, restore_if, paths, save_key)|
      lane_steps = phases.fetch(job_id, [])
      restore_matches = lane_steps.select { |step| step['id'] == restore_id }
      restore = restore_matches.first || {}
      expected_paths = paths.split('\n')
      check.call(restore_matches.length == 1 && restore['uses'] == "actions/cache/restore@#{CACHE_SHA}" && restore['if'] == restore_if && restore.dig('with', 'path').to_s.lines.map(&:strip) == expected_paths, "#{name} cache must retain its guarded restore paths")
      if scope == 'swift'
        ordered = ["Check out #{name} source", 'Identify Swift cache compatibility', 'Restore SwiftPM build directory',
                   'Restore unchanged Swift input timestamps', 'Snapshot Swift input timestamps',
                   { 'contracts' => 'Run Swift contracts', 'tests' => 'Run checks', 'release' => 'Compile release Spotty with SPOTTY_DISTRIBUTION' }.fetch(name)].map do |name|
          lane_steps.index { |step| step['name'] == name }
        end
        check.call(ordered.none?(&:nil?) && ordered == ordered.sort && ordered.uniq.length == ordered.length,
                   "#{name} must checkout, identify, restore, and snapshot its isolated build products in order")
        check.call(restore.dig('with', 'key') == '${{ env.SWIFT_CACHE_KEY }}' && restore.dig('with', 'restore-keys') == '${{ env.SWIFT_CACHE_PREFIX }}', "#{name} Swift cache must retain exact configuration-safe isolation")
      elsif name == 'rust-release'
        check.call(restore.dig('with', 'key') == '${{ env.RUST_RELEASE_COMPATIBILITY_KEY }}-${{ env.PLAYBACK_INPUT_DIGEST }}' && restore.dig('with', 'restore-keys') == '${{ env.RUST_RELEASE_COMPATIBILITY_KEY }}-', 'Rust release cache must retain exact inputs and bounded dependency compatibility')
      elsif name == 'rust-debug'
        key = restore.dig('with', 'key').to_s
        prefix = restore.dig('with', 'restore-keys').to_s
        check.call(key.include?('${{ env.RUST_DEBUG_TOOLCHAIN_KEY }}') && key.include?('${{ runner.arch }}') && key.include?("hashFiles('Backend/spotty-playback/Cargo.lock')") && key.end_with?('-${{ github.sha }}') && prefix == key.delete_suffix('${{ github.sha }}'), 'Rust verification cache must retain its actual Debug toolchain, architecture, and Cargo.lock isolation')
      else
        check.call(restore.dig('with', 'key') == 'macos-26-cbindgen-parser-v1-${{ runner.arch }}-${{ env.CBINDGEN_VERSION }}' && !restore.fetch('with', {}).key?('restore-keys'), 'cbindgen cache must retain its exact architecture and parser version')
      end
      export_if = "success() && github.ref == 'refs/heads/main'"
      export_if += " && needs.policy.outputs.rust_needed == 'true'" if job_id == 'engine'
      export_if += " && steps.inputs.outputs.candidate_needed == 'true'" if name == 'rust-release'
      export = one_step(check, lane_steps, "Export #{name} cache products")
      upload = one_step(check, lane_steps, "Upload #{name} cache products")
      export_command = "python3 Scripts/ci_cache_bundle.py export --scope #{scope} --archive \"$RUNNER_TEMP/spotty-cache/#{name}.tar.gz\" --revision \"$GITHUB_SHA\""
      export_command += ' --runner-temp "$RUNNER_TEMP"' if name == 'cbindgen'
      export_command += ' --cargo-home "${CARGO_HOME:-$HOME/.cargo}"' if name == 'rust-debug'
      check.call(export['if'] == export_if && export['run'].to_s.strip == export_command, "#{name} cache export must remain successful-main-only and revision-bound")
      check.call(upload['if'] == export_if && upload['uses'] == "actions/upload-artifact@#{UPLOAD_SHA}" && upload['with'] == {'name' => "cache-#{name}-${{ github.run_id }}-${{ github.run_attempt }}", 'path' => "${{ runner.temp }}/spotty-cache/#{name}.tar.gz", 'if-no-files-found' => 'error', 'retention-days' => 7}, "#{name} cache upload must retain attempt-bound complete products")
      check.call(lane_steps.index(export) && lane_steps.index(upload) && lane_steps.index(export) < lane_steps.index(upload), "#{name} cache export must precede its upload")
      verification_id = { 'engine' => 'engine_gate', 'contracts' => 'contracts', 'tests' => 'debug', 'release' => 'release' }.fetch(job_id)
      verification = lane_steps.find { |step| step['id'] == verification_id }
      check.call(verification && lane_steps.index(verification) < lane_steps.index(export).to_i,
                 "#{name} cache export must follow its successful verification")
      download = one_step(check, publisher_steps, "Download #{name} cache products")
      unpack = one_step(check, publisher_steps, "Restore #{name} owned cache products")
      save = one_step(check, publisher_steps, "Save #{name} validated cache")
      publish_if = name == 'rust-release' ? "needs.macos_verify.outputs.candidate_needed == 'true'" : nil
      check.call(download['if'] == publish_if && download['uses'] == "actions/download-artifact@#{DOWNLOAD_SHA}" && download['with'] == {'name' => "cache-#{name}-${{ github.run_id }}-${{ github.run_attempt }}", 'path' => "${{ runner.temp }}/spotty-cache/#{name}"}, "#{name} publisher must download the exact run-attempt export")
      unpack_command = "python3 Scripts/ci_cache_bundle.py restore --scope #{scope} --archive \"$RUNNER_TEMP/spotty-cache/#{name}/#{name}.tar.gz\" --revision \"$GITHUB_SHA\" --replace-owned-scope"
      unpack_command += ' --runner-temp "$RUNNER_TEMP"' if name == 'cbindgen'
      unpack_command = "mkdir -p \"${CARGO_HOME:-$HOME/.cargo}\"\n#{unpack_command} --cargo-home \"${CARGO_HOME:-$HOME/.cargo}\"" if name == 'rust-debug'
      check.call(unpack['if'] == publish_if && unpack['run'].to_s.strip == unpack_command, "#{name} publisher must validate revision and replace only its owned scope")
      check.call(save['if'] == publish_if && save['uses'] == "actions/cache/save@#{CACHE_SHA}" && save.dig('with', 'path').to_s.lines.map(&:strip) == expected_paths && save.dig('with', 'key') == save_key, "#{name} validated save must retain the producing lane's paths and exact key")
      positions = [download, unpack, save].map { |step| publisher_steps.index(step) }
      check.call(positions.none?(&:nil?) && positions == positions.sort && positions.uniq.length == positions.length, "#{name} publisher download, validation, and save must remain ordered")
    end
    check.call(saves.all? { |step| publisher_steps.include?(step) }, 'only the post-aggregate publisher may save caches')
    errors
  end
end
