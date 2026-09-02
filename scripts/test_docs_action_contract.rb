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
puts "docs action contract passed"
