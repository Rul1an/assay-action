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
  # Issue #43: one source-of-truth stable pin for the required hosted proof.
  # The journey installs exactly this tag through the action's own shared
  # install path (resolve-version.sh), so the required gate is deterministic.
  PINNED_VERSION_ENV = "ASSAY_PINNED_VERSION"
  PINNED_VERSION_REF = "${{ env.ASSAY_PINNED_VERSION }}"
  STABLE_TAG = /\Av\d+[.]\d+[.]\d+\z/
  # "latest" as a standalone token. Deliberately does not match "ubuntu-latest".
  FLOATING_VERSION = /(?<![\w-])latest(?![\w-])/
  # Fingerprints of a job-local release downloader. Matched on release-path
  # shape, never on a bare hostname: this asks "does this shell fetch a release
  # itself?", it is not URL-origin sanitization and must not be read as such.
  SECOND_INSTALLER = %r{releases/download|tag_name|/repos/[^/\s"']+/[^/\s"']+/releases}
  USE_CASE_DOC = "docs/use-cases/mcp-tool-call-audit-trail-in-github-actions.md"

  RECIPE_FILE = "scripts/remediation_recipe.cmd"

  REQUIRED_TOKENS = [
    "mkdir -p .assay/sandbox .assay/evidence/nested",
    "assay sandbox --dry-run",
    "--profile .assay/sandbox/profile.yaml",
    "--bundle .assay/evidence/nested/sandbox.tar.gz",
    "-- true"
  ].freeze

  def self.canonical_recipe(repo_root)
    path = Pathname(repo_root) / RECIPE_FILE
    raise ContractError, "missing #{RECIPE_FILE}" unless path.file?

    recipe = path.read
    raise ContractError, "#{RECIPE_FILE} must be a single line" if recipe.include?("\n")
    raise ContractError, "#{RECIPE_FILE} empty" if recipe.strip.empty?

    recipe
  end

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

  def validate_remediation!(readme, action, recipe)
    errors = []
    unless recipe_tokens_in_order?(recipe)
      errors << "#{RECIPE_FILE}: missing released remediation recipe tokens"
    end
    surfaces = remediation_surfaces(readme, action)
    notice = surfaces.fetch("notice")
    summary = surfaces.fetch("summary")
    cat_needle = "cat \"$GITHUB_ACTION_PATH/#{RECIPE_FILE}\""
    unless action.include?(cat_needle)
      errors << "action.yml must cat #{RECIPE_FILE} (real load, not a decoy mention)"
    end
    # Count real cats of the canonical path — decoy comments do not count.
    real_cats = action.each_line.count { |line| line.include?(cat_needle) && !line.lstrip.start_with?("#") }
    if real_cats < 2
      errors << "action.yml must cat #{RECIPE_FILE} on both notice and summary emission paths"
    end
    unless notice.include?("$RECIPE") || notice.include?(cat_needle)
      errors << "notice: must emit via $RECIPE from #{RECIPE_FILE}"
    end
    unless summary.include?("$RECIPE") || summary.include?(cat_needle)
      errors << "summary: must emit via $RECIPE from #{RECIPE_FILE}"
    end
    if action.include?(recipe)
      errors << "action.yml still hand-syncs the recipe literal; load #{RECIPE_FILE} only"
    end
    errors << "README must embed the exact released remediation recipe" unless readme.include?(recipe)
    surfaces.each do |name, surf|
      errors << "#{name}: forbidden non-executable assay run remediation" if surf.match?(FORBIDDEN_REMEDIATION)
    end
    if readme.match?(/sandbox-command:\s*assay run/)
      errors << "README sandbox-command still teaches non-executable assay run remediation"
    end
    if readme.match?(FORBIDDEN_REMEDIATION) || action.match?(FORBIDDEN_REMEDIATION)
      errors << "public surfaces still contain non-executable assay run remediation"
    end
    if readme.match?(/assay sandbox --dry-run \\\n/)
      errors << "README still has a second multi-line executable recipe literal"
    end
    raise ContractError, errors.join("\n") unless errors.empty?
  end


  # The proof step is the ./ invocation that demands discovery. Fall back to the
  # last ./ step so a mutation that drops evidence_mode still reports the real
  # defect instead of silently selecting the install invocation.
  def required_consumer(steps)
    steps.find do |step|
      step["uses"].to_s == "./" && step.dig("with", "evidence_mode").to_s == "required"
    end || steps.reverse.find { |step| step["uses"].to_s == "./" }
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
      consumer = required_consumer(steps)
      return ["default-discovery-sandbox", job, producer, consumer]
    end
    jobs.each do |name, job|
      steps = job["steps"]
      next unless steps.is_a?(Array)

      producer = steps.find do |step|
        run = step["run"].to_s
        run.include?("assay sandbox --dry-run") && run.include?(DISCOVERY_BUNDLE)
      end
      consumer = required_consumer(steps)
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

    # Issue #43: the released CLI must arrive through the action's own shared
    # install path (resolve-version.sh + verify-install.sh, owned by #42). A
    # job-local downloader is a second installer and is rejected outright.
    install = steps.find do |step|
      step["uses"].to_s == "./" && step.dig("with", "version").to_s != ""
    end
    job_shell = steps.map { |step| step["run"].to_s }.join("\n")
    if install.nil?
      errors << "#{name}: missing pinned released-CLI install step through the action (uses: ./ with version)"
    end
    if job_shell.match?(SECOND_INSTALLER)
      errors << "#{name}: journey carries a second installer; reuse the action's shared install path"
    end
    if job_shell.include?("cat >") && job_shell.include?("bin/assay")
      errors << "#{name}: install must use the released CLI, not a stub binary"
    end
    if job_shell.match?(%r{\brm\b[^\n]*\.assay/evidence})
      errors << "#{name}: journey must not delete the produced bundle before the proof step"
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

  # Issue #43: the required proof must install one pinned stable tag, declared
  # once, and must never resolve a floating "latest". Declaring the pin is not
  # enough: the journey also asserts at runtime that the installed CLI is that
  # tag, so an ignored pin cannot stay green.
  def validate_pin!(workflow_text)
    errors = []
    parsed = YAML.safe_load(workflow_text, aliases: true)
    pin = parsed.fetch("env", {}).fetch(PINNED_VERSION_ENV, "").to_s
    if pin.empty?
      errors << "workflow must declare one #{PINNED_VERSION_ENV} pin for the required proof"
    elsif !pin.match?(STABLE_TAG)
      errors << "#{PINNED_VERSION_ENV} must be one stable vX.Y.Z tag, got #{pin.inspect}"
    end

    found = journey_job(workflow_text)
    raise ContractError, (errors << "action-sanity missing journey job").join("\n") unless found

    name, job, = found
    steps = job.fetch("steps")
    action_steps = steps.select { |step| step["uses"].to_s == "./" }
    if action_steps.empty?
      errors << "#{name}: journey must invoke the production action"
    end
    action_steps.each do |step|
      version = step.dig("with", "version").to_s
      next if version == PINNED_VERSION_REF

      errors << "#{name}: every ./ step must install the single pinned version " \
                "via #{PINNED_VERSION_REF}, got #{version.inspect}"
    end

    if YAML.dump(job).match?(FLOATING_VERSION)
      errors << "#{name}: journey must not resolve a floating latest; it installs #{PINNED_VERSION_ENV}"
    end

    version_assert = steps.any? do |step|
      run = step["run"].to_s
      run.include?("assay --version") && run.include?("PINNED")
    end
    unless version_assert
      errors << "#{name}: journey must assert the installed CLI matches the pin, " \
                "otherwise an ignored pin stays green"
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

  def validate_public_contract!(readme, action, workflow, use_case, repo_root:)
    recipe = ExecutableEvidenceRemediation.canonical_recipe(repo_root)
    validate_remediation!(readme, action, recipe)
    validate_journey!(workflow)
    validate_pin!(workflow)
    validate_use_case_public_truth!(use_case)
    validate_quickstart_coherence!(readme)
  end
end

def expect_remediation_invalid(label, readme, action, workflow, use_case, expected)
  begin
    ExecutableEvidenceRemediation.validate_public_contract!(readme, action, workflow, use_case, repo_root: Pathname(__dir__).parent)
  rescue ContractError => error
    raise "#{label}: wrong failure: #{error.message}" unless error.message.match?(expected)

    puts "PASS: #{label}"
    return
  end
  raise "#{label}: mutation stayed green"
end

workflow = (repo / ".github/workflows/action-sanity.yml").read
use_case = (repo / ExecutableEvidenceRemediation::USE_CASE_DOC).read
ExecutableEvidenceRemediation.validate_public_contract!(readme, action, workflow, use_case, repo_root: repo)
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
  'RECIPE="$(cat "$GITHUB_ACTION_PATH/scripts/remediation_recipe.cmd")"',
  "echo 'assay run --policy policy.yaml -- pytest'"
)
expect_remediation_invalid(
  "mutation restores assay run summary recipe",
  readme,
  mut_summary,
  workflow,
  use_case,
  /forbidden|assay run|summary|remediation_recipe|load|hand-sync/
)

mut_readme_recipe = readme.sub(ExecutableEvidenceRemediation.canonical_recipe(repo), "assay run --policy policy.yaml -- pytest tests/")
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

# Issue #43 must-bite mutations: the required proof must stay pinned, install
# through the shared path, keep its bundle, and honour the pin it declares.
mut_wf_pin_latest = workflow.sub(
  /^  ASSAY_PINNED_VERSION: v\d+[.]\d+[.]\d+$/,
  "  ASSAY_PINNED_VERSION: latest"
)
raise "workflow pin is not mutable" if mut_wf_pin_latest == workflow
expect_remediation_invalid(
  "mutation replaces the stable pin with latest",
  readme,
  action,
  mut_wf_pin_latest,
  use_case,
  /stable vX[.]Y[.]Z|ASSAY_PINNED_VERSION/
)

mut_wf_step_latest = workflow.sub(
  "version: #{ExecutableEvidenceRemediation::PINNED_VERSION_REF}",
  "version: latest"
)
raise "journey version reference is not mutable" if mut_wf_step_latest == workflow
expect_remediation_invalid(
  "mutation resolves latest at a journey step instead of the pin",
  readme,
  action,
  mut_wf_step_latest,
  use_case,
  /single pinned version|floating latest/
)

mut_wf_second_installer = workflow.sub(
  "      - name: Produce fresh sandbox evidence\n",
  "      - name: Install released Assay CLI\n" \
  "        shell: bash\n" \
  "        run: |\n" \
  "          set -euo pipefail\n" \
  "          curl -fsSL \"https://github.com/Rul1an/assay/releases/download/v1.0.0/a.tar.gz\" -o a.tar.gz\n" \
  "\n" \
  "      - name: Produce fresh sandbox evidence\n"
)
raise "journey step list is not mutable" if mut_wf_second_installer == workflow
expect_remediation_invalid(
  "mutation reintroduces a job-local installer",
  readme,
  action,
  mut_wf_second_installer,
  use_case,
  /second installer|shared install path/
)

mut_wf_ignored_pin = workflow.sub(
  'INSTALLED="$(assay --version)"',
  'INSTALLED="assay pinned"'
)
raise "installed-version probe is not mutable" if mut_wf_ignored_pin == workflow
expect_remediation_invalid(
  "mutation stops asserting the installed CLI matches the pin",
  readme,
  action,
  mut_wf_ignored_pin,
  use_case,
  /installed CLI matches the pin|ignored pin/
)

mut_wf_drop_bundle = workflow.sub(
  '          echo "Produced .assay/evidence/nested/sandbox.tar.gz sha256=$PRODUCED_SHA"',
  "          rm -f .assay/evidence/nested/sandbox.tar.gz"
)
raise "producer tail is not mutable" if mut_wf_drop_bundle == workflow
expect_remediation_invalid(
  "mutation deletes the produced bundle before the proof step",
  readme,
  action,
  mut_wf_drop_bundle,
  use_case,
  /delete the produced bundle/
)

# Control: a comment-only workflow edit changes no rule and must stay green.
noop_workflow = workflow.sub(
  "name: Action Sanity\n",
  "name: Action Sanity\n# no-op control comment: contracts must not key off comments\n"
)
raise "no-op control did not change the workflow text" if noop_workflow == workflow
ExecutableEvidenceRemediation.validate_public_contract!(
  readme, action, noop_workflow, use_case, repo_root: repo
)
puts "PASS: control: comment-only workflow edit keeps the journey contract green"

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

exact = repo / "scripts/test_exact_remediation_recipe.sh"
raise "missing #{exact}" unless exact.file?
helper = exact.read
# Independent pin: helper must actually execute action-selected bytes (not a stub exit 0).
unless helper.include?('bash -c "$RECIPE"') && helper.include?("--no-such-flag") && helper.include?("GITHUB_ACTION_PATH")
  raise "exact remediation helper no longer pins action-selected behavioral execution"
end
ok = system("bash", exact.to_s)
raise "exact remediation recipe contract failed" unless ok

# Independent behavioral execution (does not trust helper exit alone).
recipe = ExecutableEvidenceRemediation.canonical_recipe(repo)
raise "canonical recipe empty" if recipe.strip.empty?
Dir.mktmpdir("exact-recipe-") do |dir|
  bin = Pathname(dir) / "bin"
  bin.mkpath
  assay = bin / "assay"
  assay.write(<<~'SH')
    #!/usr/bin/env bash
    set -euo pipefail
    for a in "$@"; do
      if [[ "$a" == --no-such-flag ]]; then
        echo "error: unexpected argument '--no-such-flag'" >&2
        exit 2
      fi
    done
    if [[ "${1:-}" != "sandbox" ]]; then
      echo "error: unknown subcommand '${1:-}'" >&2
      exit 2
    fi
    bundle=""; prev=""; saw_dd=0; cmd=""
    for a in "$@"; do
      if [[ "$prev" == "--bundle" ]]; then bundle="$a"; fi
      if [[ "$a" == "--" ]]; then saw_dd=1; prev="$a"; continue; fi
      if [[ "$saw_dd" -eq 1 && -z "$cmd" ]]; then cmd="$a"; fi
      prev="$a"
    done
    [[ -n "$bundle" ]] || exit 2
    [[ "$saw_dd" -eq 1 && -n "$cmd" ]] || exit 2
    mkdir -p "$(dirname "$bundle")"
    : >"$bundle"
  SH
  assay.chmod(0o755)
  env = { "PATH" => "#{bin}:#{ENV.fetch("PATH")}" }
  work = Pathname(dir) / "work"
  work.mkpath
  ok_run = system(env, "bash", "-c", recipe, chdir: work.to_s)
  raise "independent exact recipe exec failed" unless ok_run
  raise "independent exact recipe missing nested bundle" unless (work / ".assay/evidence/nested/sandbox.tar.gz").file?
  bad_dir = Pathname(dir) / "bad"
  bad_dir.mkpath
  bad = system(env, "bash", "-c", "#{recipe} --no-such-flag", chdir: bad_dir.to_s, out: File::NULL, err: File::NULL)
  raise "independent --no-such-flag stayed green" if bad
end
puts "PASS: exact remediation recipe executes"
puts "PASS: independent docs-contract behavioral pin"

# Must-bite: stubbing the focused helper must not stay green.
stub_helper = exact.read
begin
  exact.write("#!/usr/bin/env bash\nexit 0\n")
  helper_now = exact.read
  begin
    unless helper_now.include?('bash -c "$RECIPE"') && helper_now.include?("--no-such-flag") && helper_now.include?("GITHUB_ACTION_PATH")
      raise ContractError, "exact remediation helper no longer pins action-selected behavioral execution"
    end
    raise "mutation stubs exact remediation helper: stayed green"
  rescue ContractError => error
    raise "mutation stubs exact remediation helper: wrong failure: #{error.message}" unless error.message.match?(/helper|behavioral|exact remediation/)
    puts "PASS: mutation stubs exact remediation helper"
  end
ensure
  exact.write(stub_helper)
end

puts "docs action contract passed"
