#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'tmpdir'
require 'yaml'

root = File.expand_path('..', __dir__)
action = YAML.load_file(File.join(root, 'action.yml'))
steps = action.fetch('runs').fetch('steps').select { |step| step['id'] == 'coverage' }
abort 'Expected exactly one coverage step' unless steps.length == 1
script = steps.first.fetch('run')

# Catch duplicate zero output, lost deduplication and zero-decision arithmetic
# by executing the complete production step. Only the external stats CLI is stubbed.
cases = [
  ['empty', [], [], '0', '0/0'],
  ['duplicates', %w[a b a c], %w[b b], '33', '1/3'],
  ['no decisions', %w[a b], [], '0', '0/2'],
  ['blank entries', ['', ''], [''], '0', '0/0']
]
failures = []
cases.each do |name, observed, decided, percent, ratio|
  Dir.mktmpdir('assay-coverage-') do |dir|
    bin = File.join(dir, 'bin')
    Dir.mkdir(bin)
    stub = File.join(bin, 'assay')
    File.write(stub, <<~SH)
      #!/usr/bin/env bash
      set -euo pipefail
      [[ "$#" == 4 && "$1" == evidence && "$2" == stats && "$4" == --json ]] || exit 2
      cat "$3"
    SH
    File.chmod(0o755, stub)
    fixture = File.join(dir, 'stats.json')
    File.write(fixture, JSON.generate(tools_observed_list: observed, tools_with_decisions_list: decided))
    bundles = File.join(dir, 'bundles.txt')
    File.write(bundles, "#{fixture}\n")
    output = File.join(dir, 'output')
    env = { 'HOME' => dir, 'PATH' => "#{bin}:#{ENV.fetch('PATH')}",
            'RUNNER_TEMP' => dir, 'BUNDLES_FILE' => bundles, 'GITHUB_OUTPUT' => output }
    stdout, stderr, status = Open3.capture3(env, 'bash', '-c', script)
    actual_output = File.exist?(output) ? File.read(output) : nil
    unless status.success? && stderr.empty? &&
           stdout == "Coverage: #{percent}% (#{ratio} tools)\n" &&
           actual_output == "coverage_percent=#{percent}\n"
      failures << "#{name}: exit=#{status.exitstatus}, stdout=#{stdout.inspect}, stderr=#{stderr.inspect}, outputs=#{actual_output.inspect}"
    end
  end
end
abort failures.join("\n") unless failures.empty?
puts "coverage contract: #{cases.length} cases passed"
