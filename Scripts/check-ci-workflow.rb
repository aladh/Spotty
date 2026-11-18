#!/usr/bin/env ruby
# Load the checked repository inputs; the policy module owns all invariant diagnostics.
require 'yaml'
require 'json'
require_relative 'workflow_policy'

standalone_path = ARGV[1] || File.join(__dir__, '..', '.github', 'workflows', 'acceptance-scenarios.yml')
workflow = YAML.safe_load(File.read(ARGV.fetch(0)), permitted_classes: [], aliases: true)
standalone = YAML.safe_load(File.read(standalone_path), permitted_classes: [], aliases: true)
errors = if workflow.dig('jobs', 'macos_verify')
           WorkflowPolicy.validate(
             workflow: workflow,
             standalone: standalone,
             policy_script: File.read(File.join(__dir__, 'check-source-policy.sh')),
             candidate_script: File.read(File.join(__dir__, 'playback-candidate-needed.sh')),
             review_package: JSON.parse(File.read(File.join(__dir__, 'agent-review-tests/package.json')))
           )
         else
           WorkflowPolicy.validate_rune(workflow: workflow, standalone: standalone)
         end
abort(errors.map { |e| "CI invariant: #{e}" }.join("\n")) unless errors.empty?
puts 'CI workflow invariants passed'
