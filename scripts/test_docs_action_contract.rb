#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"
require "pathname"
require "tmpdir"
require "yaml"

class ContractError < StandardError; end

class DocsActionContract
  ACTION = "Rul1an/assay-action"
  HISTORICAL_CAPTURE_COMMIT = "d4bd4bf47f34bbcbca2067c430d1c732c41bbb5b"
  FORBIDDEN_EXECUTABLE_REFS = [HISTORICAL_CAPTURE_COMMIT].freeze

  Example = Struct.new(:name, :body, :malformed)

  def initialize(example_root:, contract_repo:)
    @example_root = Pathname(example_root)
    @contract_repo = Pathname(contract_repo)
    @contracts = {}
  end

  def validate!
    errors = []
    current_ref = current_major_ref(errors)
    recommended_ref = recommended_major_ref(errors)
    errors << "README recommended #{recommended_ref}, action.yml is #{current_ref}" if
      current_ref && recommended_ref && current_ref != recommended_ref

    readme_examples = markdown_examples
    primary = readme_examples.find { |example| active_selector?(example.body) }
    errors << "README has no executable #{ACTION} example" unless primary

    if primary && current_ref
      primary_refs = action_calls(primary, errors).map { |call| call.fetch("uses").split("@", 2).last }
      errors << "primary executable example must select @#{current_ref}" unless
        primary_refs == [current_ref]
    end

    readme_examples.each { |example| validate_example(example, errors) }
    header_examples.each do |example|
      calls = validate_example(example, errors)
      next unless current_ref

      calls.each do |call|
        ref = call.fetch("uses").split("@", 2).last
        errors << "#{example.name}: action header must select @#{current_ref}, got @#{ref}" unless
          ref == current_ref
      end
    end

    raise ContractError, errors.join("\n") unless errors.empty?
  end

  private

  def current_major_ref(errors)
    first_line = (@example_root / "action.yml").each_line.first
    match = first_line&.match(/\A# Assay GitHub Action v(\d+)\./)
    unless match
      errors << "action.yml must declare its major in the first line"
      return nil
    end
    "v#{match[1]}"
  end

  def recommended_major_ref(errors)
    matches = (@example_root / "README.md").read.scan(/Pin `@(v\d+)` for the current action\./).flatten
    unless matches.length == 1
      errors << "README must contain exactly one current-action recommendation"
      return nil
    end
    matches.first
  end

  def markdown_examples
    lines = (@example_root / "README.md").read.lines
    examples = []
    opening = nil
    body = []

    lines.each_with_index do |line, index|
      if opening
        if line.match?(/\A#{Regexp.escape(opening.fetch(:marker))}[ \t]*\r?\n?\z/)
          examples << Example.new(
            "README.md:#{opening.fetch(:line)}",
            body.join,
            false
          ) if opening.fetch(:yaml)
          opening = nil
          body = []
        else
          body << line
        end
        next
      end

      match = line.match(/\A(`{3,}|~{3,})[ \t]*(\S*)[ \t]*\r?\n?\z/)
      next unless match

      opening = {
        marker: match[1],
        yaml: %w[yaml yml].include?(match[2].downcase),
        line: index + 1
      }
    end

    if opening && opening.fetch(:yaml) && active_selector?(body.join)
      examples << Example.new("README.md:#{opening.fetch(:line)}", body.join, true)
    end
    examples
  end

  def header_examples
    examples = []
    body = nil
    start_line = nil

    (@example_root / "action.yml").read.lines.each_with_index do |line, index|
      break unless line.start_with?("#") || line.strip.empty?

      if line.match?(/\A# Usage \(/)
        examples << Example.new("action.yml:#{start_line}", body.join, false) if body
        body = []
        start_line = index + 1
        next
      end
      next unless body

      content = line.sub(/\A# ?/, "")
      if content.strip.empty?
        examples << Example.new("action.yml:#{start_line}", body.join, false)
        body = nil
        start_line = nil
      else
        body << content
      end
    end
    examples << Example.new("action.yml:#{start_line}", body.join, false) if body
    examples
  end

  def active_selector?(body)
    body.lines.any? do |line|
      line.match?(%r{\A\s*(?:-\s*)?uses:\s*#{Regexp.escape(ACTION)}@\S+\s*(?:#.*)?\z})
    end
  end

  def validate_example(example, errors)
    calls = action_calls(example, errors)
    calls.each do |call|
      uses = call.fetch("uses")
      ref = uses.split("@", 2).last
      if FORBIDDEN_EXECUTABLE_REFS.include?(ref)
        errors << "#{example.name}: #{uses} is forbidden in executable examples"
        next
      end
      inputs = contract_inputs(ref, example.name, errors)
      with = call.fetch("with", {})
      unless with.is_a?(Hash)
        errors << "#{example.name}: with must be a mapping for #{uses}"
        next
      end
      next unless inputs

      unknown = with.keys.map(&:to_s) - inputs
      errors << "#{example.name}: #{uses} does not define input(s): #{unknown.sort.join(", ")}" unless
        unknown.empty?
    end
    calls
  end

  def action_calls(example, errors)
    if example.malformed
      errors << "#{example.name}: executable YAML fence is not closed"
      return []
    end

    parsed = YAML.safe_load(example.body, aliases: true)
    calls = collect_calls(parsed)
    errors << "#{example.name}: executable selector was not parsed" if active_selector?(example.body) && calls.empty?
    calls
  rescue Psych::SyntaxError => error
    errors << "#{example.name}: cannot parse executable YAML fence: #{error.problem}"
    []
  end

  def collect_calls(node, calls = [])
    case node
    when Hash
      uses = node["uses"]
      calls << node if uses.is_a?(String) && uses.start_with?("#{ACTION}@")
      node.each_value { |value| collect_calls(value, calls) }
    when Array
      node.each { |value| collect_calls(value, calls) }
    end
    calls
  end

  def contract_inputs(ref, location, errors)
    return @contracts.fetch(ref) if @contracts.key?(ref)

    revision = if ref.match?(/\A[0-9a-f]{40}\z/)
                 "#{ref}^{commit}"
               elsif ref.match?(/\Av\d+(?:\.\d+\.\d+)?\z/)
                 "refs/tags/#{ref}^{commit}"
               end
    unless revision
      errors << "#{location}: unsupported action ref @#{ref}"
      return nil
    end

    oid = git("rev-parse", "--verify", revision).strip
    action = git("show", "#{oid}:action.yml")
    parsed = YAML.safe_load(action, aliases: true)
    inputs = parsed.fetch("inputs")
    unless inputs.is_a?(Hash)
      errors << "#{location}: #{ref} action.yml has no input mapping"
      return nil
    end
    @contracts[ref] = inputs.keys.map(&:to_s)
  rescue ContractError, KeyError, Psych::SyntaxError => error
    errors << "#{location}: cannot resolve @#{ref} action contract: #{error.message}"
    nil
  end

  def git(*arguments)
    output, error, status = Open3.capture3("git", "-C", @contract_repo.to_s, *arguments)
    raise ContractError, error.strip unless status.success?

    output
  end
end

def validate_root!(root, contract_repo)
  DocsActionContract.new(example_root: root, contract_repo: contract_repo).validate!
end

def write_fixture(root, readme, action)
  File.write(File.join(root, "README.md"), readme)
  File.write(File.join(root, "action.yml"), action)
end

def expect_invalid(label, readme, action, contract_repo, expected)
  Dir.mktmpdir("docs-contract-") do |root|
    write_fixture(root, readme, action)
    begin
      validate_root!(root, contract_repo)
    rescue ContractError => error
      raise "#{label}: wrong failure: #{error.message}" unless error.message.match?(expected)

      puts "PASS: #{label}"
      return
    end
  end
  raise "#{label}: mutation stayed green"
end

repo = Pathname(__dir__).parent
validate_root!(repo, repo)

readme = (repo / "README.md").read
action = (repo / "action.yml").read

v3_mode = readme.sub(
  /(uses: Rul1an\/assay-action@v3\n\s+with:\n)/,
  "\\1          mode: capture\n          run: echo historical\n"
)
expect_invalid("v3 rejects historical mode/run", v3_mode, action, repo, /mode|run/)

v2_mode = readme + <<~MARKDOWN

  ```yaml
  - uses: Rul1an/assay-action@v2
    with:
      mode: capture
      run: echo historical
  ```
MARKDOWN
expect_invalid("current v2 rejects historical mode/run", v2_mode, action, repo, /mode|run/)

v2_v3_only = readme + <<~MARKDOWN

  ```yaml
  - uses: Rul1an/assay-action@v2
    with:
      evidence_mode: required
  ```
MARKDOWN
expect_invalid("selected tag resolves its own contract", v2_v3_only, action, repo, /evidence_mode/)

missing_key = readme + <<~MARKDOWN

  ```yaml
  - uses: Rul1an/assay-action@v3
    with:
      not_an_input: true
  ```
MARKDOWN
expect_invalid("unknown with key fails", missing_key, action, repo, /not_an_input/)

recommended_drift = readme.sub("Pin `@v3` for the current action.", "Pin `@v2` for the current action.")
expect_invalid("recommended major drift fails", recommended_drift, action, repo, /recommended v2/)

malformed = readme + <<~MARKDOWN

  ```yaml
  - uses: Rul1an/assay-action@v3
    with: [
  ```
MARKDOWN
expect_invalid("malformed executable fence fails", malformed, action, repo, /cannot parse/)

historical_executable = readme + <<~MARKDOWN

  ```yaml
  - uses: Rul1an/assay-action@#{DocsActionContract::HISTORICAL_CAPTURE_COMMIT}
    with:
      mode: capture
      run: echo historical
  ```
MARKDOWN
expect_invalid(
  "historical capture commit is prose-only",
  historical_executable,
  action,
  repo,
  /forbidden in executable examples/
)

historical_comment = readme + <<~MARKDOWN

  Historical capture syntax existed only at
  `#{DocsActionContract::HISTORICAL_CAPTURE_COMMIT}`; neither current major exposes it.

  ```yaml
  # Historical text only, not executable:
  # - uses: Rul1an/assay-action@#{DocsActionContract::HISTORICAL_CAPTURE_COMMIT}
  #   with:
  #     mode: capture
  #     run: echo historical
  ```
MARKDOWN
Dir.mktmpdir("docs-contract-") do |root|
  write_fixture(root, historical_comment, action)
  validate_root!(root, repo)
end
puts "PASS: prose/comment-only history stays outside executable examples"

# ---------------------------------------------------------------------------
# Issue #40: one released-CLI remediation recipe + default-discovery journey
# Shared helper is used by acceptance AND mutations (producer vs consumer).
# ---------------------------------------------------------------------------

module ExecutableEvidenceRemediation
  # One shared remediation/discovery recipe across notice, summary, README, and
  # the hosted default-discovery journey. Nested under .assay/evidence/ so the
  # journey discriminates real discovery from a hardcoded flat default path.
  DISCOVERY_BUNDLE = ".assay/evidence/nested/sandbox.tar.gz"
  LEGACY_FLAT_BUNDLE = ".assay/evidence/sandbox.tar.gz"
  USE_CASE_DOC = "docs/use-cases/mcp-tool-call-audit-trail-in-github-actions.md"

  RECIPE = <<~'SH'.chomp.freeze
    mkdir -p .assay/sandbox .assay/evidence/nested
    assay sandbox --dry-run \
      --profile .assay/sandbox/profile.yaml \
      --bundle .assay/evidence/nested/sandbox.tar.gz \
      -- true
  SH

  REQUIRED_TOKENS = [
    "mkdir -p .assay/sandbox .assay/evidence/nested",
    "assay sandbox --dry-run",
    "--profile .assay/sandbox/profile.yaml",
    "--bundle .assay/evidence/nested/sandbox.tar.gz",
    "-- true"
  ].freeze

  FORBIDDEN_REMEDIATION = /Run 'assay run'|assay run --policy/

  module_function

  def recipe_tokens_in_order?(text)
    pos = 0
    REQUIRED_TOKENS.all? do |token|
      idx = text.index(token, pos)
      next false unless idx

      pos = idx + token.length
      true
    end
  end

  def remediation_surfaces(readme, action)
    notice = ""
    action.each_line do |line|
      if line.include?("::notice::") && line.include?("No evidence bundles found")
        notice = line
        break
      end
    end

    summary = ""
    if (match = action.match(/No Evidence Bundles Found.*?Bundles are written under.*?\n/m))
      summary = match[0]
    end

    readme_section = ""
    if (match = readme.match(/## How Evidence Bundles Fit\n.*?(?=\n## )/m))
      readme_section = match[0]
    end

    {
      "notice" => notice,
      "summary" => summary,
      "readme" => readme_section
    }
  end

  def validate_remediation!(readme, action)
    errors = []
    remediation_surfaces(readme, action).each do |name, text|
      errors << "#{name}: missing released remediation recipe tokens" unless recipe_tokens_in_order?(text)
      errors << "#{name}: forbidden non-executable assay run remediation" if text.match?(FORBIDDEN_REMEDIATION)
    end
    errors << "README must embed the exact released remediation recipe" unless readme.include?(RECIPE)
    # action.yml summary echoes the recipe line-by-line (YAML block indentation);
    # token order on the summary surface is the pin for the Action.
    # Primary README capture example must not teach the non-executable assay run recipe.
    if readme.match?(/sandbox-command:\s*assay run/)
      errors << "README sandbox-command still teaches non-executable assay run remediation"
    end
    if readme.match?(FORBIDDEN_REMEDIATION) || action.match?(FORBIDDEN_REMEDIATION)
      errors << "public surfaces still contain non-executable assay run remediation"
    end
    raise ContractError, errors.join("\n") unless errors.empty?
  end

  def journey_job(workflow_text)
    parsed = YAML.safe_load(workflow_text, aliases: true)
    jobs = parsed.fetch("jobs")
    # Prefer the dedicated job name; fall back to structural match so mutations
    # against producer/consumer still exercise the shared helper.
    if jobs.key?("default-discovery-sandbox")
      job = jobs.fetch("default-discovery-sandbox")
      steps = job.fetch("steps")
      producer = steps.find { |step| step["id"].to_s == "produce" || step["run"].to_s.include?("sandbox.tar.gz") && step["name"].to_s.downcase.include?("produce") }
      producer ||= steps.find { |step| step["run"].to_s.include?("sandbox.tar.gz") && !step["run"].to_s.include?("EVIDENCE_STATE") && step["uses"].nil? }
      consumer = steps.find { |step| step["uses"].to_s == "./" }
      return ["default-discovery-sandbox", job, producer, consumer]
    end
    jobs.each do |name, job|
      steps = job["steps"]
      next unless steps.is_a?(Array)

      producer = steps.find do |step|
        run = step["run"].to_s
        run.include?("assay sandbox --dry-run") && run.include?(DISCOVERY_BUNDLE)
      end
      consumer = steps.find do |step|
        step["uses"].to_s == "./" && (step.dig("with", "evidence_mode").to_s == "required")
      end
      return [name, job, producer, consumer] if producer && consumer
    end
    nil
  end

  def validate_journey!(workflow_text)
    errors = []
    found = journey_job(workflow_text)
    unless found
      raise ContractError, "action-sanity missing producer+required-consumer journey job"
    end
    name, job, producer, consumer = found
    steps = job.fetch("steps")

    unless job["runs-on"].to_s.include?("ubuntu")
      errors << "#{name}: journey must be Linux/ubuntu"
    end

    if producer.nil?
      errors << "#{name}: producer step missing (deleted or skipped)"
    else
      producer_run = producer["run"].to_s
      unless recipe_tokens_in_order?(producer_run)
        errors << "#{name}: producer must run the released remediation recipe"
      end
      if producer_run.match?(/\bcp\b/) || producer_run.include?("fixture")
        errors << "#{name}: producer must create a fresh bundle, not copy a fixture"
      end
      unless producer_run.include?("--bundle #{DISCOVERY_BUNDLE}")
        errors << "#{name}: producer bundle path must be #{DISCOVERY_BUNDLE}"
      end
      if producer_run.match?(%r{--bundle\s+(/tmp/|\.\./|evidence-out/)})
        errors << "#{name}: producer bundle path is outside discovery roots"
      end
    end

    if consumer.nil?
      errors << "#{name}: consumer action step missing"
      with = {}
    else
      with = consumer.fetch("with", {})
    end
    unless with.is_a?(Hash) && with["evidence_mode"].to_s == "required"
      errors << "#{name}: consumer must set evidence_mode: required"
    end
    if with.is_a?(Hash) && with.key?("bundles")
      errors << "#{name}: consumer must leave bundles unset for default auto-discovery"
    end

    install = steps.find do |step|
      run = step["run"].to_s
      name_l = step["name"].to_s.downcase
      (name_l.include?("install") && name_l.include?("assay")) ||
        (run.include?("releases/download") && run.include?("Rul1an/assay"))
    end
    if install.nil?
      errors << "#{name}: missing real released CLI install step"
    else
      install_run = install["run"].to_s
      if install_run.include?("cat >") && install_run.include?("bin/assay")
        errors << "#{name}: install must use released CLI, not a stub binary"
      end
      unless install_run.include?("releases/download") || install_run.include?("resolve-version")
        errors << "#{name}: install must follow the release download path"
      end
    end

    assert_step = steps.find do |step|
      run = step["run"].to_s
      run.include?("EVIDENCE_STATE") && run.include?("sandbox.tar.gz") && run.include?("INDEX_DIGEST")
    end
    if assert_step.nil?
      errors << "#{name}: missing assert step for discovered sandbox evidence"
    else
      run = assert_step.fetch("run")
      errors << "#{name}: assert must require evidence_state=verified" unless run.include?('EVIDENCE_STATE') && run.match?(/verified/)
      errors << "#{name}: assert must require non-empty evidence-index digest" unless run.include?("INDEX_DIGEST")
      errors << "#{name}: assert must bind discovered path #{DISCOVERY_BUNDLE}" unless run.include?(DISCOVERY_BUNDLE)
      unless run.match?(/integrity.+verified|["']verified["']/) && run.include?("integrity")
        errors << "#{name}: assert must require per-bundle integrity verified (not manufactured)"
      end
      unless run.include?("sha256") && (run.include?("PRODUCED") || run.include?("produced") || run.include?("BUNDLE_SHA"))
        errors << "#{name}: assert must bind index row sha256 to newly produced bundle"
      end
    end

    raise ContractError, errors.join("\n") unless errors.empty?
  end

  def validate_use_case_public_truth!(use_case)
    errors = []
    doc = use_case.to_s
    errors << "#{USE_CASE_DOC}: missing from public-contract inputs" if doc.strip.empty?

    # Stale mechanism claim: action runs under assay run / captures tool calls.
    if doc.match?(/under `assay run`|runs your test command under `assay run`/)
      errors << "#{USE_CASE_DOC}: still claims the action runs the command under assay run"
    end
    if doc.match?(/`assay run`\s*\([^)]*captures tool calls|assay run.*captures tool calls and other capability events/)
      errors << "#{USE_CASE_DOC}: overclaims tool-call capture via assay run"
    end

    # Required honest mechanism.
    unless doc.match?(/`assay sandbox`|assay sandbox/)
      errors << "#{USE_CASE_DOC}: must describe the assay sandbox mechanism"
    end

    # Do not claim the action captures MCP tool calls beyond the observed
    # filesystem/network(/process) sandbox surface.
    if doc.match?(/runs your test command under[^.\n]*(captures tool calls|tool-call capture)/i)
      errors << "#{USE_CASE_DOC}: must not claim tool-call capture beyond the observed sandbox surface"
    end

    raise ContractError, errors.join("\n") unless errors.empty?
  end

  def validate_quickstart_coherence!(readme)
    errors = []
    from_scratch = readme[ /## From Scratch\n.*?(?=\n## )/m ].to_s
    from_zero = readme[ /## From Zero To Evidence In CI\n.*?(?=\n## )/m ].to_s
    quickstart = "#{from_scratch}\n#{from_zero}"

    # Authoring = a policy.yaml fence or "start with a policy file" instruction,
    # not an honest "no separate policy.yaml is required" non-claim.
    authors_policy = from_scratch.match?(/```(?:ya?ml)\n(?:[^`]*\n)?#\s*policy\.yaml/) ||
                     from_scratch.match?(/Start with a small policy file/i)
    workflow_body = from_zero[ /```(?:ya?ml)\n(.*?)```/m, 1 ].to_s
    uses_sandbox_command = workflow_body.match?(/sandbox-command\s*:/)
    consumes_policy = workflow_body.match?(/policy\.yaml|\bpolicy\s*:/)

    if authors_policy && uses_sandbox_command && !consumes_policy
      errors << "From Scratch/From Zero: policy.yaml is authored but the quickstart workflow does not consume it (default sandbox-command / mcp-server-minimal path)"
    end

    if uses_sandbox_command
      unless quickstart.match?(/\.assay\/sandbox-command\/evidence\.tar\.gz/) ||
             readme.match?(/When `sandbox-command` is set[\s\S]*?\.assay\/sandbox-command\/evidence\.tar\.gz/)
        errors << "From Scratch/From Zero: sandbox-command quickstart must describe the default sandbox-command evidence path"
      end
    end

    raise ContractError, errors.join("\n") unless errors.empty?
  end

  def validate_public_contract!(readme, action, workflow, use_case)
    validate_remediation!(readme, action)
    validate_journey!(workflow)
    validate_use_case_public_truth!(use_case)
    validate_quickstart_coherence!(readme)
  end
end

def expect_remediation_invalid(label, readme, action, workflow, use_case, expected)
  begin
    ExecutableEvidenceRemediation.validate_public_contract!(readme, action, workflow, use_case)
  rescue ContractError => error
    raise "#{label}: wrong failure: #{error.message}" unless error.message.match?(expected)

    puts "PASS: #{label}"
    return
  end
  raise "#{label}: mutation stayed green"
end

workflow = (repo / ".github/workflows/action-sanity.yml").read
use_case = (repo / ExecutableEvidenceRemediation::USE_CASE_DOC).read
ExecutableEvidenceRemediation.validate_public_contract!(readme, action, workflow, use_case)
puts "PASS: released remediation recipe pinned across public surfaces"
puts "PASS: default-discovery sandbox journey pinned"
puts "PASS: use-case public truth + From Scratch/From Zero coherence pinned"

# Must-bite mutations (shared helper — not self-satisfying)
mut_notice = action.sub(
  /::notice::No evidence bundles found\.[^\n]*/,
  "::notice::No evidence bundles found. Run 'assay run' to generate them."
)
expect_remediation_invalid(
  "mutation restores Run 'assay run' notice",
  readme,
  mut_notice,
  workflow,
  use_case,
  /forbidden|assay run|missing released/
)

mut_summary = action.sub(
  "echo 'assay sandbox --dry-run \\'",
  "echo 'assay run --policy policy.yaml -- pytest'"
)
expect_remediation_invalid(
  "mutation restores assay run summary recipe",
  readme,
  mut_summary,
  workflow,
  use_case,
  /forbidden|missing released/
)

mut_readme_recipe = readme.sub(ExecutableEvidenceRemediation::RECIPE, "assay run --policy policy.yaml -- pytest tests/")
expect_remediation_invalid(
  "mutation restores assay run README remediation",
  mut_readme_recipe,
  action,
  workflow,
  use_case,
  /forbidden|missing released|exact released/
)

mut_wf_skip = workflow.sub(
  /assay sandbox --dry-run \\\n(?:.*\n)*?\s*-- true\n/,
  "echo skip producer\n"
)
expect_remediation_invalid(
  "mutation deletes producer sandbox step",
  readme,
  action,
  mut_wf_skip,
  use_case,
  /producer|journey/
)

mut_wf_fixture = workflow.sub(
  /assay sandbox --dry-run \\\n(?:.*\n)*?\s*-- true\n/,
  "cp fixtures/sandbox.tar.gz .assay/evidence/sandbox.tar.gz\n"
)
expect_remediation_invalid(
  "mutation copies fixture instead of producing",
  readme,
  action,
  mut_wf_fixture,
  use_case,
  /fixture|fresh|producer/
)

mut_wf_outside = workflow.sub(
  /--bundle \.assay\/evidence\/(?:nested\/)?sandbox\.tar\.gz/,
  "--bundle /tmp/outside-sandbox.tar.gz"
)
expect_remediation_invalid(
  "mutation sets output path outside discovery roots",
  readme,
  action,
  mut_wf_outside,
  use_case,
  /discovery|producer|journey|outside|missing/
)

mut_wf_bundles = workflow.sub(
  /evidence_mode:\s*required\n/,
  "evidence_mode: required\n          bundles: \".assay/evidence/*.tar.gz\"\n"
)
expect_remediation_invalid(
  "mutation adds explicit bundles input",
  readme,
  action,
  mut_wf_bundles,
  use_case,
  /bundles must be unset|auto-discovery/
)

mut_wf_mode = workflow.sub(
  /evidence_mode:\s*required\n/,
  "evidence_mode: optional\n"
)
expect_remediation_invalid(
  "mutation removes evidence_mode required",
  readme,
  action,
  mut_wf_mode,
  use_case,
  /evidence_mode|journey|producer/
)

mut_wf_verified2 = workflow.sub(
  'assert row["integrity"] == "verified"',
  "assert True  # manufactured verified"
)
expect_remediation_invalid(
  "mutation manufactures verified without per-bundle verification",
  readme,
  action,
  mut_wf_verified2,
  use_case,
  /integrity|per-bundle|manufactured|assert/
)

# Gap 3 discrimination: old flat discovery literal must not satisfy nested journey.
# Behavioral via shared helper (not self-satisfying local asserts).
if workflow.include?(ExecutableEvidenceRemediation::DISCOVERY_BUNDLE)
  mut_wf_flat = workflow.gsub(
    ExecutableEvidenceRemediation::DISCOVERY_BUNDLE,
    ExecutableEvidenceRemediation::LEGACY_FLAT_BUNDLE
  ).gsub(
    "mkdir -p .assay/sandbox .assay/evidence/nested",
    "mkdir -p .assay/sandbox .assay/evidence"
  )
  expect_remediation_invalid(
    "mutation substitutes old flat discovery bundle path",
    readme,
    action,
    mut_wf_flat,
    use_case,
    /producer|bundle path|discovery|assert|journey|nested/
  )

  mut_assert_flat = workflow.sub(
    %(assert row["path"] == "#{ExecutableEvidenceRemediation::DISCOVERY_BUNDLE}"),
    %(assert row["path"] == "#{ExecutableEvidenceRemediation::LEGACY_FLAT_BUNDLE}")
  )
  raise "expected nested discovery assert to be mutable" if mut_assert_flat == workflow
  expect_remediation_invalid(
    "mutation clears nested discovery assert to old flat path",
    readme,
    action,
    mut_assert_flat,
    use_case,
    /assert|bind discovered path|discovery|bundle/
  )
end

mut_use_case_run = use_case.sub(
  "`assay sandbox`",
  "`assay run`"
)
# Ensure stale assay-run overclaim present for the mutation even if doc already fixed.
unless mut_use_case_run.match?(/under `assay run`|captures tool calls/)
  mut_use_case_run = use_case + "\n\nThe action runs your test command under `assay run` (which captures tool calls and other capability events).\n"
end
expect_remediation_invalid(
  "mutation restores assay run use-case public truth",
  readme,
  action,
  workflow,
  mut_use_case_run,
  /assay run|tool-call|public truth|mcp-tool-call/
)

mut_scratch = readme.sub(
  "## From Scratch\n",
  "## From Scratch\n\nStart with a small policy file.\n\n```yaml\n# policy.yaml\nversion: \"2.0\"\n```\n\n"
)
expect_remediation_invalid(
  "mutation restores unused policy.yaml From Scratch authoring",
  mut_scratch,
  action,
  workflow,
  use_case,
  /policy\.yaml|does not consume|From Scratch|quickstart/
)

puts "docs action contract passed"
