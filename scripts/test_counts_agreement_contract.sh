#!/usr/bin/env bash
set -euo pipefail

# The counts the action publishes are checked against the CLI in CI, on a bundle that carries a finding.
#
# Two halves:
#   1. Behaviour: scripts/assert_counts_match_cli.sh accepts counts equal to the CLI's own JSON report for the same
#      bundle, and refuses unequal counts, unreadable counts, a report without a summary, and a bundle without any
#      finding (0 == 0 proves nothing).
#   2. Wiring: the required sandbox job and both canary lanes run that script on the bundle the action reviewed, with
#      the outputs of the step that reviewed it. Read from the parsed workflow documents, never from their text.
#
# Usage: ASSAY_BIN_DIR=<dir holding a released `assay`> bash scripts/test_counts_agreement_contract.sh
# Without a CLI this fails; it never skips.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSERT="${ASSERT_SCRIPT:-$REPO_ROOT/scripts/assert_counts_match_cli.sh}"
FIXTURES="$REPO_ROOT/scripts/fixtures/cli-verdict"
SANITY="${SANITY_WORKFLOW:-$REPO_ROOT/.github/workflows/action-sanity.yml}"
CANARY="${CANARY_WORKFLOW:-$REPO_ROOT/.github/workflows/published-tag-canary.yml}"
failed=0

fail() {
  echo "FAIL: $*" >&2
  failed=$((failed + 1))
}

pass() {
  echo "PASS: $*"
}

if [[ -z "${ASSAY_BIN_DIR:-}" || ! -x "${ASSAY_BIN_DIR}/assay" ]]; then
  echo "FAIL: set ASSAY_BIN_DIR to a directory holding a released assay binary" >&2
  exit 2
fi
for tool in jq ruby; do
  command -v "$tool" >/dev/null || { echo "FAIL: $tool is required" >&2; exit 2; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home"
JQ_DIR="$(dirname "$(command -v jq)")"

# ---------------------------------------------------------------------------------------------------------------
# 1. Behaviour of the assertion
# ---------------------------------------------------------------------------------------------------------------

# Runs the assertion with the given CLI directory first on PATH. Prints nothing; returns the script's exit code.
run_assert() { # <cli dir> <errors> <warnings> <bundle>
  local code=0
  env -i HOME="$WORK/home" PATH="$1:$JQ_DIR:/usr/bin:/bin" FINDINGS_ERROR="$2" FINDINGS_WARN="$3" \
    bash "$ASSERT" "$4" > "$WORK/assert.log" 2>&1 || code=$?
  echo "$code"
}

expect_code() { # <label> <expected> <actual>
  if [[ "$3" == "$2" ]]; then
    pass "$1 (exit $3)"
  else
    fail "$1: expected exit $2, got $3"
    sed 's/^/    /' "$WORK/assert.log" >&2 || true
  fi
}

oracle() { # <bundle>: "<errors> <warnings>" from the CLI's own report
  env -i HOME="$WORK/home" PATH="$ASSAY_BIN_DIR:/usr/bin:/bin" "$ASSAY_BIN_DIR/assay" evidence lint --format json \
    --fail-on none "$1" 2>/dev/null | jq -er '"\(.summary.errors) \(.summary.warnings)"'
}

WARNING="$FIXTURES/warning.tar.gz"
CLEAN="$FIXTURES/clean.tar.gz"

if [[ ! -f "$ASSERT" ]]; then
  fail "behaviour: scripts/assert_counts_match_cli.sh does not exist"
else
  read -r O_ERR O_WARN <<<"$(oracle "$WARNING")"
  if [[ $((O_ERR + O_WARN)) -lt 1 ]]; then
    fail "behaviour: the warning fixture yields no finding with this CLI, so nothing below discriminates"
  else
    pass "behaviour: the oracle reports $O_ERR errors and $O_WARN warnings on the warning fixture (control)"
  fi

  expect_code "equal counts are accepted" 0 "$(run_assert "$ASSAY_BIN_DIR" "$O_ERR" "$O_WARN" "$WARNING")"
  expect_code "a warning count of zero is refused" 1 "$(run_assert "$ASSAY_BIN_DIR" "$O_ERR" 0 "$WARNING")"
  expect_code "an error count off by one is refused" 1 \
    "$(run_assert "$ASSAY_BIN_DIR" "$((O_ERR + 1))" "$O_WARN" "$WARNING")"
  expect_code "an empty count is refused" 1 "$(run_assert "$ASSAY_BIN_DIR" "" "$O_WARN" "$WARNING")"
  expect_code "a count that is not a number is refused" 1 \
    "$(run_assert "$ASSAY_BIN_DIR" "$O_ERR" "unavailable" "$WARNING")"

  read -r C_ERR C_WARN <<<"$(oracle "$CLEAN")"
  if [[ "$C_ERR $C_WARN" == "0 0" ]]; then
    expect_code "a bundle without findings is refused although 0 equals 0" 1 \
      "$(run_assert "$ASSAY_BIN_DIR" 0 0 "$CLEAN")"
  else
    fail "behaviour: the clean fixture yields findings with this CLI ($C_ERR, $C_WARN)"
  fi

  expect_code "a missing bundle is an error, not a mismatch" 2 \
    "$(run_assert "$ASSAY_BIN_DIR" "$O_ERR" "$O_WARN" "$WORK/absent.tar.gz")"

  # A file the CLI cannot report on: without a report there is nothing to compare with.
  printf 'not a bundle\n' > "$WORK/corrupt.tar.gz"
  expect_code "a bundle the CLI cannot report on is an error, not a pass" 2 \
    "$(run_assert "$ASSAY_BIN_DIR" "$O_ERR" "$O_WARN" "$WORK/corrupt.tar.gz")"

  mkdir -p "$WORK/no-cli"
  expect_code "a missing CLI is an error, not a pass" 2 "$(run_assert "$WORK/no-cli" "$O_ERR" "$O_WARN" "$WARNING")"

  # A CLI whose report carries no summary: the assertion has no oracle and must say so.
  mkdir -p "$WORK/no-summary"
  cat > "$WORK/no-summary/assay" <<SH
#!/usr/bin/env bash
"$ASSAY_BIN_DIR/assay" "\$@" | "$JQ_DIR/jq" 'del(.summary)'
SH
  chmod +x "$WORK/no-summary/assay"
  expect_code "a report without a summary is an error, not a pass" 2 \
    "$(run_assert "$WORK/no-summary" "$O_ERR" "$O_WARN" "$WARNING")"
fi

# ---------------------------------------------------------------------------------------------------------------
# 2. Wiring in the workflows
# ---------------------------------------------------------------------------------------------------------------

# One site: <workflow> <job> <uses of the reviewing step> <bundle argument> <required if: of both steps, or "">
# The reviewing step is found from the assertion's own env binding, so the test follows the outputs that are read.
check_site() {
  local label=$1 workflow=$2 job=$3 uses=$4 bundle=$5 cond=$6 out
  # shellcheck disable=SC2016 # Ruby compares literal workflow expressions.
  if out=$(ruby -ryaml -e '
    workflow, job_id, uses, bundle, cond = ARGV
    job = YAML.safe_load_file(workflow, aliases: false).fetch("jobs").fetch(job_id)
    steps = job.fetch("steps")
    abort("job has continue-on-error") if job.key?("continue-on-error")
    want_run = "bash scripts/assert_counts_match_cli.sh #{bundle}"
    hits = steps.each_index.select { |i| steps[i]["run"].to_s.strip == want_run }
    abort("expected exactly one step running `#{want_run}`, found #{hits.length}") unless hits.length == 1
    index = hits.first
    step = steps[index]
    extra = step.keys - %w[name shell env run if]
    abort("assertion step has unexpected keys: #{extra.join(", ")}") unless extra.empty?
    abort("assertion step must use shell: bash") unless step["shell"] == "bash"
    env = step["env"] || {}
    abort("assertion step env must be exactly FINDINGS_ERROR and FINDINGS_WARN, plus BUNDLE where used") unless
      (env.keys - %w[BUNDLE]).sort == %w[FINDINGS_ERROR FINDINGS_WARN]
    match = env["FINDINGS_ERROR"].to_s.match(/\A\$\{\{ steps\.([A-Za-z0-9_-]+)\.outputs\.findings_error \}\}\z/)
    abort("FINDINGS_ERROR must be one step output, got #{env["FINDINGS_ERROR"].inspect}") unless match
    id = match[1]
    abort("FINDINGS_WARN must read the same step") unless
      env["FINDINGS_WARN"] == "${{ steps.#{id}.outputs.findings_warn }}"
    source = steps.index { |s| s["id"] == id }
    abort("no step with id #{id}") unless source
    abort("the reviewing step must come before the assertion") unless source < index
    review = steps[source]
    abort("the reviewing step must be `uses: #{uses}`, got #{review["uses"].inspect}") unless review["uses"] == uses
    abort("the reviewing step has continue-on-error") if review.key?("continue-on-error")
    want_if = cond.empty? ? nil : cond
    abort("the assertion step if: must be #{want_if.inspect}, got #{step["if"].inspect}") unless step["if"] == want_if
    abort("the reviewing step if: must be #{want_if.inspect}, got #{review["if"].inspect}") unless
      review["if"] == want_if
    if env.key?("BUNDLE")
      abort("BUNDLE must be the sandbox bundle under runner.temp") unless
        env["BUNDLE"] == "${{ runner.temp }}/assay-coding-agent.tar.gz"
      abort("the reviewing step must produce that bundle with sandbox-command") unless
        review.dig("with", "sandbox-command").to_s != ""
    end
    abort("the reviewing step must gate on fail_on: error") unless review.dig("with", "fail_on") == "error"
  ' "$workflow" "$job" "$uses" "$bundle" "$cond" 2>&1); then
    pass "wiring: $label"
  else
    fail "wiring: $label: $out"
  fi
}

check_site "the required sandbox job compares the review step's counts with the CLI" \
  "$SANITY" default-discovery-sandbox "./" ".assay/evidence/nested/sandbox.tar.gz" ""
# shellcheck disable=SC2016 # "$BUNDLE" is the literal argument written in the workflow.
check_site "the @v3 canary compares the published action's counts with the CLI" \
  "$CANARY" assay-action-v3 "Rul1an/assay-action@v3" '"$BUNDLE"' "runner.os == 'Linux'"
# shellcheck disable=SC2016
check_site "the candidate lane compares the tagged action's counts with the CLI" \
  "$CANARY" assay-action-candidate "./" '"$BUNDLE"' ""

# The required sandbox job also runs the verdict contract and this contract with the CLI the action installed.
check_runs() { # <label> <exact run line>
  local out
  # shellcheck disable=SC2016 # Ruby reads its own arguments.
  if out=$(ruby -ryaml -e '
    job = YAML.safe_load_file(ARGV[0], aliases: false).fetch("jobs").fetch("default-discovery-sandbox")
    abort("the job has an if:") if job.key?("if")
    hits = job.fetch("steps").select { |s| s["run"].to_s.strip == ARGV[1] }
    abort("expected exactly one step running `#{ARGV[1]}`, found #{hits.length}") unless hits.length == 1
    extra = hits.first.keys - %w[name shell run]
    abort("step has unexpected keys: #{extra.join(", ")}") unless extra.empty?
  ' "$SANITY" "$2" 2>&1); then
    pass "wiring: $1"
  else
    fail "wiring: $1: $out"
  fi
}

# shellcheck disable=SC2016 # The run lines are compared as literal text.
check_runs "the required sandbox job runs the verdict contract with the installed CLI" \
  'ASSAY_BIN_DIR="$(dirname "$(command -v assay)")" bash scripts/test_cli_verdict_contract.sh'
# shellcheck disable=SC2016
check_runs "the required sandbox job runs this contract with the installed CLI" \
  'ASSAY_BIN_DIR="$(dirname "$(command -v assay)")" bash scripts/test_counts_agreement_contract.sh'

if [[ "$failed" -gt 0 ]]; then
  echo "$failed check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
