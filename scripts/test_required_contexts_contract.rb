#!/usr/bin/env ruby
# frozen_string_literal: true

# Issue #43: the executable default-discovery proof needs a stable *required*
# context, and the documented required set must not drift from the recorded
# live inventory. Branch protection is enforced by exact context names, so a
# rename or a quiet deletion silently un-gates main. One rule, one owner: this
# file owns agreement between CI-CONTRACT.md, the ruleset inventory, and the
# workflow jobs those contexts name.

require "json"
require "pathname"
require "yaml"

class RequiredContextError < StandardError; end

module RequiredContexts
  CONTRACT_FILE = "CI-CONTRACT.md"
  RULESET_FILE = ".github/rulesets/main-required-ci-contexts.json"
  WORKFLOW_FILE = ".github/workflows/action-sanity.yml"

  # The pinned Linux install-to-discovery proof promoted by issue #43.
  PINNED_PROOF_CONTEXT = "default-discovery-sandbox"

  # Deliberately advisory. Floating tags, cross-platform canaries, scheduled
  # posture jobs, and trusted-only lanes must never become merge gates: they
  # depend on external availability or on events a pull request cannot produce.
  ADVISORY_ONLY = %w[
    baseline-delta-trusted
    published-tag-canary
    canary-v3
    canary-v2
    scorecard
    analysis
  ].freeze

  # Anchors the live inventory list in CI-CONTRACT.md section 6.
  LIVE_ANCHOR = "Live required check contexts on main"

  # A context that looks like a workflow job id must resolve to a real job.
  JOB_ID_SHAPE = /\A[a-z0-9][a-z0-9-]*\z/

  module_function

  def documented_contexts(contract_text)
    index = contract_text.index(LIVE_ANCHOR)
    raise RequiredContextError, "#{CONTRACT_FILE}: missing live required-context inventory" if index.nil?

    contexts = []
    started = false
    contract_text[index..].each_line.drop(1).each do |line|
      if (match = line.match(/\A- `([^`]+)`\s*\z/))
        started = true
        contexts << match[1]
      elsif started
        break
      end
    end
    contexts
  end

  def ruleset_contexts(ruleset_text)
    doc = JSON.parse(ruleset_text)
    rule = doc.fetch("rules", []).find { |entry| entry["type"] == "required_status_checks" }
    raise RequiredContextError, "#{RULESET_FILE}: no required_status_checks rule" if rule.nil?

    rule.dig("parameters", "required_status_checks").to_a.map { |check| check.fetch("context") }
  end

  def validate!(contract_text, ruleset_text, workflow_text)
    errors = []
    documented = documented_contexts(contract_text)
    recorded = ruleset_contexts(ruleset_text)

    errors << "#{CONTRACT_FILE}: live required-context list is empty" if documented.empty?
    errors << "#{RULESET_FILE}: required-context inventory is empty" if recorded.empty?

    if documented.sort != recorded.sort
      only_doc = (documented - recorded).sort
      only_rule = (recorded - documented).sort
      errors << "required-context drift between #{CONTRACT_FILE} and #{RULESET_FILE}: " \
                "documented-only=#{only_doc.inspect} recorded-only=#{only_rule.inspect}"
    end

    unless documented.include?(PINNED_PROOF_CONTEXT)
      errors << "#{CONTRACT_FILE}: #{PINNED_PROOF_CONTEXT} must be a documented required context"
    end
    unless recorded.include?(PINNED_PROOF_CONTEXT)
      errors << "#{RULESET_FILE}: #{PINNED_PROOF_CONTEXT} must be a recorded required context"
    end

    jobs = YAML.safe_load(workflow_text, aliases: true).fetch("jobs")
    (documented | recorded).each do |context|
      next unless context.match?(JOB_ID_SHAPE)
      next if jobs.key?(context)

      errors << "#{context}: required context has no job in #{WORKFLOW_FILE}"
    end

    if jobs.key?(PINNED_PROOF_CONTEXT)
      job = jobs.fetch(PINNED_PROOF_CONTEXT)
      if job.key?("if")
        errors << "#{PINNED_PROOF_CONTEXT}: a required proof must not be conditional; " \
                  "a skipped job reports no context and cannot gate a merge"
      end
    else
      errors << "#{WORKFLOW_FILE}: missing #{PINNED_PROOF_CONTEXT} job"
    end

    ADVISORY_ONLY.each do |context|
      next unless documented.include?(context) || recorded.include?(context)

      errors << "#{context} must stay advisory; floating-tag, cross-platform, scheduled, " \
                "and trusted-only lanes are not merge gates"
    end

    raise RequiredContextError, errors.join("\n") unless errors.empty?
  end
end

repo = Pathname(__dir__).parent
contract = (repo / RequiredContexts::CONTRACT_FILE).read
ruleset = (repo / RequiredContexts::RULESET_FILE).read
workflow = (repo / RequiredContexts::WORKFLOW_FILE).read

RequiredContexts.validate!(contract, ruleset, workflow)
puts "PASS: required-context set agrees across contract, inventory, and workflow"

def expect_context_invalid(label, contract, ruleset, workflow, expected)
  begin
    RequiredContexts.validate!(contract, ruleset, workflow)
  rescue RequiredContextError => error
    raise "#{label}: wrong failure: #{error.message}" unless error.message.match?(expected)

    puts "PASS: #{label}"
    return
  end
  raise "#{label}: mutation stayed green"
end

def expect_context_valid(label, contract, ruleset, workflow)
  RequiredContexts.validate!(contract, ruleset, workflow)
  puts "PASS: #{label}"
rescue RequiredContextError => error
  raise "#{label}: control must stay green, got: #{error.message}"
end

proof = RequiredContexts::PINNED_PROOF_CONTEXT

mut_contract_drop = contract.sub(/^- `#{Regexp.escape(proof)}`\n/, "")
raise "documented #{proof} bullet is not mutable" if mut_contract_drop == contract
expect_context_invalid(
  "mutation removes the proof context from #{RequiredContexts::CONTRACT_FILE}",
  mut_contract_drop,
  ruleset,
  workflow,
  /documented required context|required-context drift/
)

mut_ruleset_drop = JSON.parse(ruleset).then do |doc|
  rule = doc.fetch("rules").find { |entry| entry["type"] == "required_status_checks" }
  rule["parameters"]["required_status_checks"] =
    rule["parameters"]["required_status_checks"].reject { |check| check["context"] == proof }
  JSON.pretty_generate(doc)
end
expect_context_invalid(
  "mutation removes the proof context from #{RequiredContexts::RULESET_FILE}",
  contract,
  mut_ruleset_drop,
  workflow,
  /recorded required context|required-context drift/
)

mut_workflow_conditional = workflow.sub(
  /^  #{Regexp.escape(proof)}:\n    runs-on:/,
  "  #{proof}:\n    if: github.event_name == 'schedule'\n    runs-on:"
)
raise "#{proof} job header is not mutable" if mut_workflow_conditional == workflow
expect_context_invalid(
  "mutation makes the required proof conditional",
  contract,
  ruleset,
  mut_workflow_conditional,
  /must not be conditional|skipped job/
)

mut_advisory_required = contract.sub(
  /^- `#{Regexp.escape(proof)}`\n/,
  "- `#{proof}`\n- `published-tag-canary`\n"
)
raise "advisory promotion is not expressible" if mut_advisory_required == contract
expect_context_invalid(
  "mutation promotes the floating-tag canary to a required context",
  mut_advisory_required,
  ruleset,
  workflow,
  /must stay advisory|required-context drift/
)

# Control: a comment-only edit changes no rule and must stay green.
expect_context_valid(
  "control: comment-only workflow edit stays green",
  contract,
  ruleset,
  workflow.sub(/\Aname: Action Sanity\n/, "name: Action Sanity\n# no-op control comment\n")
)

puts "PASS: required-context contract mutations all bite"
