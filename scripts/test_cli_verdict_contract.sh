#!/usr/bin/env bash
set -euo pipefail

# The action reports the verdict the CLI computed.
#
# This runs the action's own step scripts (discover, process, pack-lint), read out of action.yml by step id, with a
# real Assay CLI on real bundles. The expected values are not written here: they are read from the CLI's own JSON
# report for the same inputs, so the test cannot encode a belief about the CLI's output that the CLI does not hold.
#
# Usage: ASSAY_BIN_DIR=<dir holding a released `assay`> bash scripts/test_cli_verdict_contract.sh
# Without a CLI this fails; it never skips, because a skipped oracle reads as a pass.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="$REPO_ROOT/action.yml"
FIXTURES="$REPO_ROOT/scripts/fixtures/cli-verdict"
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

# The run: script of one step, selected by id from the parsed document (never by text position).
step_script() {
  ruby -ryaml -e '
    doc = YAML.safe_load_file(ARGV[0], aliases: false)
    step = doc.fetch("runs").fetch("steps").find { |s| s["id"] == ARGV[1] || s["name"] == ARGV[1] }
    abort("no step with id #{ARGV[1]}") unless step && step["run"]
    print step["run"]
  ' "$ACTION" "$1"
}

# Position of a step in the action, by id or (for steps without one) by name.
step_index() {
  ruby -ryaml -e '
    doc = YAML.safe_load_file(ARGV[0], aliases: false)
    index = doc.fetch("runs").fetch("steps").index { |s| s["id"] == ARGV[1] || s["name"] == ARGV[1] }
    abort("no step #{ARGV[1]}") unless index
    print index
  ' "$ACTION" "$1"
}

output_of() { # <github_output file> <key>: the last value written for the key
  grep -E "^$2=" "$1" | tail -n1 | cut -d= -f2-
}

assay_cli() {
  env -i HOME="$WORK/home" PATH="$ASSAY_BIN_DIR:/usr/bin:/bin" "$ASSAY_BIN_DIR/assay" "$@"
}

# One job: a workspace with the given bundles, the action's discover and process steps, and optionally pack-lint.
# Leaves outputs in $WS/out.discover, $WS/out.process, $WS/out.pack and exit codes in $WS/*.code.
run_job() { # <name> <fail_on> <packs or ""> <bundle>...
  local name=$1 fail_on=$2 packs=$3
  shift 3
  WS="$WORK/$name"
  mkdir -p "$WS/ws/.assay/evidence" "$WS/tmp" "$WORK/home"
  local bundle
  for bundle in "$@"; do
    cp "$FIXTURES/$bundle" "$WS/ws/.assay/evidence/$bundle"
  done
  cp "$FIXTURES"/*.yaml "$WS/ws/" 2>/dev/null || true
  step_script discover > "$WS/discover.sh"
  step_script process > "$WS/process.sh"
  step_script pack-lint > "$WS/pack-lint.sh"
  : > "$WS/out.discover"
  : > "$WS/out.process"
  : > "$WS/out.pack"
  local base=(env -i HOME="$WORK/home" PATH="${CLI_DIR:-$ASSAY_BIN_DIR}:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
    GITHUB_WORKSPACE="$WS/ws" GITHUB_ACTION_PATH="$REPO_ROOT" RUNNER_TEMP="$WS/tmp")

  (cd "$WS/ws" && "${base[@]}" GITHUB_OUTPUT="$WS/out.discover" BUNDLES_PATTERN=".assay/evidence/*.tar.gz" \
    EVIDENCE_MODE=optional SANDBOX_BUNDLE="" bash "$WS/discover.sh") > "$WS/discover.log" 2>&1 \
    || { fail "$name: discover step failed"; cat "$WS/discover.log" >&2; return 1; }

  set +e
  (cd "$WS/ws" && "${base[@]}" GITHUB_OUTPUT="$WS/out.process" FAIL_ON="$fail_on" \
    BUNDLES_FILE="$(output_of "$WS/out.discover" bundles_file)" \
    INDEX_PATH="$(output_of "$WS/out.discover" evidence_index_path)" \
    bash "$WS/process.sh") > "$WS/process.log" 2>&1
  echo $? > "$WS/process.code"
  set -e

  if [[ -n "$packs" ]]; then
    set +e
    (cd "$WS/ws" && "${base[@]}" GITHUB_OUTPUT="$WS/out.pack" FAIL_ON="$fail_on" PACKS="$packs" \
      BUNDLES_FILE="$(output_of "$WS/out.discover" bundles_file)" \
      REPORTS_DIR="$(output_of "$WS/out.process" reports_dir)" \
      bash "$WS/pack-lint.sh") > "$WS/pack.log" 2>&1
    echo $? > "$WS/pack.code"
    set -e
  fi
}

# The oracle: what the CLI itself reports for one bundle, as "<errors> <warnings> <infos>".
cli_counts() { # <fail_on> <bundle path> [--pack <packs>]
  local fail_on=$1 bundle=$2
  shift 2
  (cd "$(dirname "$bundle")/../.." && assay_cli evidence lint --format json --fail-on "$fail_on" "$@" "$bundle" 2>/dev/null) \
    | jq -r '"\(.summary.errors) \(.summary.warnings) \(.summary.infos)"'
}

# Leg 1: the counts the action publishes equal the CLI's summary, summed over bundles.
counts_case() { # <name> <fail_on> <bundle>...
  local name=$1 fail_on=$2
  shift 2
  run_job "$name" "$fail_on" "" "$@" || return 0
  local want_errors=0 want_warns=0 want_infos=0 bundle counts e w i
  for bundle in "$@"; do
    counts=$(cli_counts none "$WS/ws/.assay/evidence/$bundle")
    [[ "$counts" =~ ^[0-9]+\ [0-9]+\ [0-9]+$ ]] || { fail "$name: the oracle gave no counts for $bundle ('$counts')"; return 0; }
    read -r e w i <<<"$counts"
    want_errors=$((want_errors + e))
    want_warns=$((want_warns + w))
    want_infos=$((want_infos + i))
  done
  local got_errors got_warns got_infos
  got_errors=$(output_of "$WS/out.process" findings_error)
  got_warns=$(output_of "$WS/out.process" findings_warn)
  got_infos=$(output_of "$WS/out.process" findings_info || true)
  if [[ "$got_errors" == "$want_errors" && "$got_warns" == "$want_warns" ]]; then
    pass "$name: findings_error=$got_errors findings_warn=$got_warns equal the CLI summary"
  else
    fail "$name: action says errors=$got_errors warnings=$got_warns, the CLI says errors=$want_errors warnings=$want_warns"
  fi
  if [[ "$got_infos" == "$want_infos" ]]; then
    pass "$name: findings_info=$got_infos equals the CLI summary"
  else
    fail "$name: action says infos='$got_infos', the CLI says infos=$want_infos"
  fi
}

# Every output the README documents is one the action declares, bound to the step that computes it.
# shellcheck disable=SC2016 # Ruby compares a literal workflow expression.
if out=$(ruby -ryaml -e '
  declared = YAML.safe_load_file(ARGV[0], aliases: false).fetch("outputs")
  table = File.read(ARGV[1], encoding: "UTF-8").split(/^## Outputs$/, 2).fetch(1).split(/^## /, 2).first
  documented = table.scan(/^\| `([a-z_]+)` \|/).flatten
  abort("README documents no outputs") if documented.empty?
  missing = documented - declared.keys
  abort("README documents outputs the action does not declare: #{missing.join(", ")}") unless missing.empty?
  want = "${{ steps.process.outputs.findings_info }}"
  abort("findings_info must be #{want}") unless declared.dig("findings_info", "value") == want
' "$ACTION" "$REPO_ROOT/README.md" 2>&1); then
  pass "outputs: every output in the README is declared by the action"
else
  fail "outputs: $out"
fi

echo "CLI under test: $(assay_cli --version)"

# Control: a bundle without findings. It must pass on any action version, which shows the table discriminates by
# content rather than failing everything.
counts_case clean error clean.tar.gz
# A bundle with one warning, alone and next to the clean one.
counts_case warning error warning.tar.gz
counts_case two-bundles none clean.tar.gz warning.tar.gz

# The gate is the CLI's exit code and stays what it was: a warning does not gate at fail_on=error, and gates at
# fail_on=warn.
run_job gate-error error "" warning.tar.gz && {
  [[ "$(cat "$WS/process.code")" == "0" ]] && pass "gate: a warning passes fail_on=error" \
    || fail "gate: fail_on=error exited $(cat "$WS/process.code") on a warning"
}
run_job gate-warn warn "" warning.tar.gz && {
  [[ "$(cat "$WS/process.code")" == "1" ]] && pass "gate: a warning fails fail_on=warn" \
    || fail "gate: fail_on=warn exited $(cat "$WS/process.code") on a warning"
}

# A report that carries findings and no summary cannot be counted, and must not be published as clean. The
# wrapper below is the real CLI with the summary removed from its JSON report.
mkdir -p "$WORK/nosummary"
cat > "$WORK/nosummary/assay" <<SH
#!/usr/bin/env bash
if [[ " \$* " == *" --format json "* ]]; then
  out=\$("$ASSAY_BIN_DIR/assay" "\$@"); code=\$?
  printf '%s' "\$out" | jq 'del(.summary)'
  exit \$code
fi
exec "$ASSAY_BIN_DIR/assay" "\$@"
SH
chmod +x "$WORK/nosummary/assay"
CLI_DIR="$WORK/nosummary" run_job no-summary none "" warning.tar.gz && {
  if [[ "$(cat "$WS/process.code")" == "2" && -z "$(output_of "$WS/out.process" findings_warn)" ]]; then
    pass "no-summary: findings without a summary are refused, not published as zero"
  else
    fail "no-summary: exit $(cat "$WS/process.code"), findings_warn='$(output_of "$WS/out.process" findings_warn)'"
  fi
}
CLI_DIR="$WORK/nosummary" run_job no-summary-clean none "" clean.tar.gz && {
  [[ "$(cat "$WS/process.code")" == "0" && "$(output_of "$WS/out.process" findings_warn)" == "0" ]] \
    && pass "no-summary: a report without findings still counts zero (control)" \
    || fail "no-summary: the clean report exited $(cat "$WS/process.code")"
}

# A summary without an info count: the action has no number to publish, and zero would be one.
mkdir -p "$WORK/noinfos"
cat > "$WORK/noinfos/assay" <<SH
#!/usr/bin/env bash
if [[ " \$* " == *" --format json "* ]]; then
  out=\$("$ASSAY_BIN_DIR/assay" "\$@"); code=\$?
  printf '%s' "\$out" | jq 'del(.summary.infos)'
  exit \$code
fi
exec "$ASSAY_BIN_DIR/assay" "\$@"
SH
chmod +x "$WORK/noinfos/assay"
CLI_DIR="$WORK/noinfos" run_job no-infos none "" warning.tar.gz && {
  if grep -q '^findings_info=$' "$WS/out.process" && [[ "$(output_of "$WS/out.process" findings_warn)" == "1" ]]; then
    pass "no-infos: a summary without an info count leaves findings_info empty, and the other counts stand"
  else
    fail "no-infos: findings_info is '$(output_of "$WS/out.process" findings_info || true)' for a summary without an info count"
  fi
}

# Leg 2: a pack that fails. The CLI reports an error finding for it and no score; the action must not publish a
# score the CLI never computed.
run_job pack-fail none "./failing-pack.yaml" clean.tar.gz && {
  pack_json=$(cd "$WS/ws" && assay_cli evidence lint --format json --fail-on none --pack ./failing-pack.yaml \
    .assay/evidence/clean.tar.gz 2>/dev/null)
  pack_errors=$(echo "$pack_json" | jq -r '[.findings[] | select(.rule_id | endswith(":CLV-001"))] | length')
  if [[ "$pack_errors" == "1" ]]; then
    pass "pack: the CLI reports the failing pack rule as a finding (oracle)"
  else
    fail "pack: the oracle did not report the failing pack rule ($pack_errors)"
  fi
  [[ "$(cat "$WS/pack.code")" == "0" ]] && pass "pack: fail_on=none does not fail the pack step" \
    || fail "pack: the pack step exited $(cat "$WS/pack.code") under fail_on=none"
  [[ "$(output_of "$WS/out.pack" pack_status)" == "success" ]] && pass "pack: pack_status keeps its load-status meaning" \
    || fail "pack: pack_status is '$(output_of "$WS/out.pack" pack_status)'"
  [[ "$(output_of "$WS/out.pack" pack_applied)" == "cli-verdict-fixture@1.0.0" ]] \
    && pass "pack: pack_applied names the pack that was passed in" \
    || fail "pack: pack_applied is '$(output_of "$WS/out.pack" pack_applied)', not the pack that was passed in"
  cli_score=$(jq -r '[.runs[].properties.complianceScore?] | map(select(. != null)) | length' \
    "$(output_of "$WS/out.process" reports_dir)/pack-lint.sarif")
  got_score=$(output_of "$WS/out.pack" pack_score)
  if [[ "$cli_score" == "0" && -n "$got_score" ]]; then
    fail "pack: pack_score=$got_score although the CLI emitted no score for a pack with a failing rule"
  else
    pass "pack: pack_score carries only what the CLI emitted"
  fi
}

# A score the CLI does report must come through unchanged. The wrapper is the real CLI with a score added to its
# SARIF, because no released CLI emits one; without this, an action that always published an empty score would pass.
mkdir -p "$WORK/scored"
cat > "$WORK/scored/assay" <<SH
#!/usr/bin/env bash
if [[ " \$* " == *" --format sarif "* ]]; then
  out=\$("$ASSAY_BIN_DIR/assay" "\$@"); code=\$?
  printf '%s' "\$out" | jq '.runs[].properties.complianceScore = 80'
  exit \$code
fi
exec "$ASSAY_BIN_DIR/assay" "\$@"
SH
chmod +x "$WORK/scored/assay"
CLI_DIR="$WORK/scored" run_job pack-scored none "./failing-pack.yaml" clean.tar.gz && {
  [[ "$(output_of "$WS/out.pack" pack_score)" == "80" ]] \
    && pass "pack: a score the CLI reports is published unchanged" \
    || fail "pack: the CLI reported a score of 80, the action published '$(output_of "$WS/out.pack" pack_score)'"
}

# The main Job Summary runs on every job, also after the process step failed. It may say "Passed" only when that
# step succeeded, and it must not print a count that the step never published.
step_script "Write Job Summary" > "$WORK/job-summary.sh"
job_summary() { # <process outcome> <verified> <errors> <warnings>; prints the summary
  local out="$WORK/job-summary-$RANDOM.md"
  : > "$out"
  env -i PATH="/usr/bin:/bin" GITHUB_STEP_SUMMARY="$out" GITHUB_ACTION_PATH="$REPO_ROOT" FOUND=true COUNT=1 \
    PROCESS_OUTCOME="$1" VERIFIED="$2" VERIFIED_COUNT=1 FAILED_COUNT=0 ERRORS="$3" WARNS="$4" \
    SARIF_UPLOADED="" SARIF_ENABLED=false NEW_FINDINGS="" BASELINE_FOUND="" bash "$WORK/job-summary.sh"
  cat "$out"
}
summary_ok=$(job_summary success true 0 1)
if grep -q '^\*\*Status:\*\* Passed$' <<<"$summary_ok" && grep -q '^| Warnings | 1 |$' <<<"$summary_ok"; then
  pass "job summary: a successful process step with one warning shows Passed and the count (control)"
else
  fail "job summary: the successful case lost its status or its count"
fi
# The step stopped with exit 2 after verification: verified is already true and no count was published.
summary_broken=$(job_summary failure true "" "")
if grep -q 'Passed' <<<"$summary_broken"; then
  fail "job summary: shows Passed although the process step failed before publishing counts"
else
  pass "job summary: a failed process step never shows Passed"
fi
if grep -q '^| Errors | unavailable |$' <<<"$summary_broken" && grep -q '^| Warnings | unavailable |$' <<<"$summary_broken"; then
  pass "job summary: unpublished counts are shown as unavailable"
else
  fail "job summary: unpublished counts are shown as a number ($(grep -E '^\| (Errors|Warnings) ' <<<"$summary_broken" | tr '\n' ' '))"
fi
# The gate failed on a warning (fail_on=warn): zero errors, one warning, step outcome failure.
summary_gate=$(job_summary failure true 0 1)
if grep -q 'Passed' <<<"$summary_gate"; then
  fail "job summary: shows Passed although the gate failed the process step on a warning"
else
  pass "job summary: a gate failure on a warning never shows Passed"
fi

# The Job Summary shows the pack outputs. With no score from the CLI it must not print one.
step_script "Write v2.1 Job Summary additions" > "$WORK/summary.sh"
: > "$WORK/summary.md"
env -i PATH="/usr/bin:/bin" GITHUB_STEP_SUMMARY="$WORK/summary.md" PACK_APPLIED="cli-verdict-fixture@1.0.0" \
  RESOLVED_PACK_REFS="cli-verdict-fixture@1.0.0" PACK_SCORE="" PACK_ARTICLES="" PACK_STATUS="success" \
  PACK_ERROR_KIND="" PACK_DISCLAIMER="" ATTESTATION_ID="" ATTESTATION_URL="" ATTEST_ENABLED="false" \
  ATTEST_OUTCOME="" COVERAGE="" EVENT_NAME="pull_request" IS_DEFAULT_BRANCH="false" bash "$WORK/summary.sh"
if grep -q "cli-verdict-fixture@1.0.0" "$WORK/summary.md"; then
  pass "summary: the pack section is written (control)"
else
  fail "summary: the pack section is missing"
fi
if grep -Eq "[0-9]+%" "$WORK/summary.md"; then
  fail "summary: prints a score ($(grep -Eo "[0-9]+%" "$WORK/summary.md" | head -n1)) although none was reported"
else
  pass "summary: prints no score when none was reported"
fi

# Leg 4: pack rules the engine did not run. Such a rule produces no finding, so a pack that skipped it reads like a
# pack that ran it and passed. The CLI lists them as `skipped_rules` in its JSON report; the action must publish that
# list's size, name each rule, and say "not reported" for a CLI that has no such list. It must never publish zero
# for a list it was not given.
not_run_oracle() { # prints the number of distinct rules the CLI under test says it did not run, or "" if it does not say
  (cd "$WS/ws" && assay_cli evidence lint --format json --fail-on none --pack ./not-run-pack.yaml \
    .assay/evidence/clean.tar.gz 2>/dev/null) \
    | jq -r 'if has("skipped_rules") then (.skipped_rules | map(.rule_id) | unique | length) else "" end'
}
# Verdict of the real-CLI leg: prints "ok: ..." or "bad: ...". <want> is the oracle's answer ("" when the CLI has
# no list), <got> what the action published.
not_run_real_verdict() { # <want> <got> <pack step exit>
  local want=$1 got=$2 code=$3
  if [[ "$code" != "0" || "$got" != "$want" ]]; then
    echo "bad: action says '$got', the CLI under test says '$want' (pack step exit $code)"
  elif [[ -z "$want" ]]; then
    if [[ "${REQUIRE_SKIPPED_RULES:-0}" == "1" ]]; then
      echo "bad: the CLI under test reports no list of rules not run, and this run requires one"
    else
      echo "ok: the CLI under test has no list of rules not run and the action publishes none; the wrappers below cover the list"
    fi
  elif ! [[ "$want" =~ ^[0-9]+$ ]] || [[ "$want" -lt 1 ]]; then
    echo "bad: the CLI under test has the list but names no rule for the fixture pack ('$want'), so equal values prove nothing"
  else
    echo "ok: pack_rules_not_run='$got' equals what the CLI under test reports"
  fi
}

# The verdict of the real-CLI leg, checked on its own: an empty answer on both sides is acceptable only for a CLI
# that has no list, a CLI that has the list must name at least one rule for the fixture pack, and a run that
# requires the list (REQUIRE_SKIPPED_RULES=1, used with the latest CLI) refuses a CLI without one.
verdict_case() { # <label> <expected ok|bad> <require 0|1> <want> <got> <pack exit>
  local out
  if ! declare -F not_run_real_verdict >/dev/null; then
    fail "not run verdict: $1: the contract has no not_run_real_verdict"
    return 0
  fi
  out=$(REQUIRE_SKIPPED_RULES="$3" not_run_real_verdict "$4" "$5" "$6")
  if [[ "$out" == "$2:"* ]]; then
    pass "not run verdict: $1"
  else
    fail "not run verdict: $1: expected $2, got '$out'"
  fi
}
verdict_case "a CLI without the list and an empty output is accepted" ok 0 "" "" 0
verdict_case "a CLI with the list and an equal count is accepted (control)" ok 0 1 1 0
verdict_case "a CLI with the list that names no rule for the fixture pack is refused" bad 0 0 0 0
verdict_case "a count that differs from the CLI is refused" bad 0 1 0 0
verdict_case "an empty output for a CLI that has the list is refused" bad 0 1 "" 0
verdict_case "a failed pack step is refused" bad 0 1 1 3
verdict_case "a run that requires the list refuses a CLI without one" bad 1 "" "" 0
verdict_case "a run that requires the list accepts a CLI with one (control)" ok 1 1 1 0

run_job not-run-real none "./not-run-pack.yaml" clean.tar.gz && {
  want=$(not_run_oracle)
  got=$(output_of "$WS/out.pack" pack_rules_not_run || true)
  verdict=$(not_run_real_verdict "$want" "$got" "$(cat "$WS/pack.code")")
  if [[ "$verdict" == "ok:"* ]]; then
    pass "not run: ${verdict#ok: }"
  else
    fail "not run: ${verdict#bad: }"
  fi
}

# The two answers, each with a wrapper around the real CLI, so both are exercised whatever CLI is under test.
mkdir -p "$WORK/notrun-lists" "$WORK/notrun-silent"
cat > "$WORK/notrun-lists/assay" <<SH
#!/usr/bin/env bash
if [[ " \$* " == *" --format json "* && " \$* " == *" --pack "* ]]; then
  out=\$("$ASSAY_BIN_DIR/assay" "\$@"); code=\$?
  printf '%s' "\$out" | jq '.skipped_rules = [
    {"rule_id": "cli-verdict-not-run@1.0.0:CNR-001", "reason": "Unknown check type"},
    {"rule_id": "cli-verdict-not-run@1.0.0:CNR-900", "reason": "50% of a\\nsecond line"}]'
  exit \$code
fi
exec "$ASSAY_BIN_DIR/assay" "\$@"
SH
cat > "$WORK/notrun-silent/assay" <<SH
#!/usr/bin/env bash
if [[ " \$* " == *" --format json "* ]]; then
  out=\$("$ASSAY_BIN_DIR/assay" "\$@"); code=\$?
  printf '%s' "\$out" | jq 'del(.skipped_rules)'
  exit \$code
fi
exec "$ASSAY_BIN_DIR/assay" "\$@"
SH
chmod +x "$WORK/notrun-lists/assay" "$WORK/notrun-silent/assay"

pack_summary() { # <pack_rules_not_run> <file>; prints the pack section of the Job Summary
  local out="$WORK/pack-summary-$RANDOM.md"
  : > "$out"
  env -i PATH="/usr/bin:/bin" GITHUB_STEP_SUMMARY="$out" PACK_APPLIED="cli-verdict-not-run@1.0.0" \
    RESOLVED_PACK_REFS="cli-verdict-not-run@1.0.0" PACK_SCORE="" PACK_ARTICLES="" PACK_STATUS="success" \
    PACK_ERROR_KIND="" PACK_DISCLAIMER="" PACK_RULES_NOT_RUN="$1" PACK_RULES_NOT_RUN_FILE="$2" ATTESTATION_ID="" \
    ATTESTATION_URL="" ATTEST_ENABLED="false" ATTEST_OUTCOME="" COVERAGE="" EVENT_NAME="pull_request" \
    IS_DEFAULT_BRANCH="false" bash "$WORK/summary.sh"
  cat "$out"
}

CLI_DIR="$WORK/notrun-lists" run_job not-run-lists warn "./not-run-pack.yaml" clean.tar.gz && {
  got=$(output_of "$WS/out.pack" pack_rules_not_run || true)
  [[ "$got" == "2" ]] && pass "not run: two rules the CLI lists are published as 2" \
    || fail "not run: the CLI lists two rules, the action publishes '$got'"
  if grep -Fq '::warning title=Pack rule not run::Pack rule cli-verdict-not-run@1.0.0:CNR-001 was not run: Unknown check type.' "$WS/pack.log"; then
    pass "not run: each rule gets a warning annotation that names it and the reason"
  else
    fail "not run: no warning annotation names cli-verdict-not-run@1.0.0:CNR-001"
  fi
  # A reason is pack-controlled text inside a workflow command: one line, with % escaped.
  if grep -Fq 'CNR-900 was not run: 50%25 of a second line.' "$WS/pack.log" \
    && ! grep -q '^second line' "$WS/pack.log"; then
    pass "not run: a reason with a newline and a percent sign stays one escaped annotation"
  else
    fail "not run: a reason with a newline or a percent sign leaves its annotation"
  fi
  # The pack has a warning finding and the gate is warn: the step fails, and the rules are still disclosed.
  [[ "$(cat "$WS/pack.code")" == "1" ]] && pass "not run: the list is published although the gate fails the step" \
    || fail "not run: expected the gate to fail the pack step, got exit $(cat "$WS/pack.code")"
  listed=$(pack_summary "$got" "$(output_of "$WS/out.pack" pack_rules_not_run_file || true)")
  if grep -q '^- Rules not run: 2$' <<<"$listed" && grep -Fq 'cli-verdict-not-run@1.0.0:CNR-001' <<<"$listed" \
    && grep -Fq 'did not pass' <<<"$listed"; then
    pass "not run: the job summary gives the count, names the rules and says they did not pass"
  else
    fail "not run: the job summary does not list the rules that were not run"
  fi
}
CLI_DIR="$WORK/notrun-silent" run_job not-run-silent none "./not-run-pack.yaml" clean.tar.gz && {
  got=$(output_of "$WS/out.pack" pack_rules_not_run || true)
  if grep -q '^pack_rules_not_run=$' "$WS/out.pack"; then
    pass "not run: a CLI without the list leaves the count empty, not zero"
  else
    fail "not run: a CLI without the list is published as '$got'"
  fi
  silent=$(pack_summary "" "")
  grep -q '^- Rules not run: unknown, no list could be read from the CLI$' <<<"$silent" \
    && pass "not run: the job summary says the CLI does not report the list" \
    || fail "not run: the job summary is silent about a CLI that does not report the list"
}
none=$(pack_summary "0" "")
grep -q '^- Rules not run: 0$' <<<"$none" && pass "not run: a reported empty list is shown as 0 (control)" \
  || fail "not run: a reported empty list is not shown as 0"

# More shapes of the CLI's answer. Each wrapper is the real CLI with its pack JSON report changed by one jq
# program ($b is the bundle's file name), or failing outright.
notrun_wrapper() { # <name> <jq program, or "fail">
  mkdir -p "$WORK/$1"
  local answer
  if [[ "$2" == "fail" ]]; then
    answer='exit 7'
  else
    printf '%s\n' "$2" > "$WORK/$1/program.jq"
    answer="out=\$(\"$ASSAY_BIN_DIR/assay\" \"\$@\"); code=\$?
  printf '%s' \"\$out\" | jq --arg b \"\$(basename \"\${@: -1}\")\" -f \"$WORK/$1/program.jq\"
  exit \$code"
  fi
  cat > "$WORK/$1/assay" <<SH
#!/usr/bin/env bash
if [[ " \$* " == *" --format json "* && " \$* " == *" --pack "* ]]; then
  $answer
fi
exec "$ASSAY_BIN_DIR/assay" "\$@"
SH
  chmod +x "$WORK/$1/assay"
}
not_run_count() { output_of "$WS/out.pack" pack_rules_not_run || true; }
annotations() { grep -c '^::warning title=Pack rule not run::' "$WS/pack.log" || true; }

# One bundle answers and one does not: the total is unknown, and a partial count would read as complete.
# shellcheck disable=SC2016 # $b is a jq variable.
notrun_wrapper notrun-mixed 'if $b == "warning.tar.gz" then del(.skipped_rules) else .skipped_rules = [{"rule_id": "p@1:R1", "reason": "why"}] end'
CLI_DIR="$WORK/notrun-mixed" run_job not-run-mixed none "./not-run-pack.yaml" clean.tar.gz warning.tar.gz && {
  if grep -q '^pack_rules_not_run=$' "$WS/out.pack" && [[ "$(annotations)" == "0" ]]; then
    pass "not run: one bundle without the list leaves the total empty and names no rule"
  else
    fail "not run: a partial list is published as '$(not_run_count)' with $(annotations) annotation(s)"
  fi
}
# The same rule in two bundles, with two reasons: one rule, named once.
# shellcheck disable=SC2016
notrun_wrapper notrun-same '.skipped_rules = [{"rule_id": "p@1:R1", "reason": ("why in " + $b)}]'
CLI_DIR="$WORK/notrun-same" run_job not-run-same none "./not-run-pack.yaml" clean.tar.gz warning.tar.gz && {
  if [[ "$(not_run_count)" == "1" && "$(annotations)" == "1" ]]; then
    pass "not run: a rule that two bundles report is counted once and named once"
  else
    fail "not run: one rule in two bundles is published as '$(not_run_count)' with $(annotations) annotation(s)"
  fi
}
# The JSON call fails: there is no list, which is not an empty list.
notrun_wrapper notrun-fail fail
CLI_DIR="$WORK/notrun-fail" run_job not-run-fail none "./not-run-pack.yaml" clean.tar.gz && {
  if grep -q '^pack_rules_not_run=$' "$WS/out.pack" && [[ "$(cat "$WS/pack.code")" == "0" ]]; then
    pass "not run: a failed report call leaves the count empty and does not fail the step"
  else
    fail "not run: a failed report call gives '$(not_run_count)', pack step exit $(cat "$WS/pack.code")"
  fi
}
# A list that is not a list.
for shape in null '"all"' '{}'; do
  name="notrun-shape-$(printf '%s' "$shape" | tr -c 'a-z' '_')"
  notrun_wrapper "$name" ".skipped_rules = $shape"
  CLI_DIR="$WORK/$name" run_job "$name" none "./not-run-pack.yaml" clean.tar.gz && {
    if grep -q '^pack_rules_not_run=$' "$WS/out.pack" && [[ "$(cat "$WS/pack.code")" == "0" ]]; then
      pass "not run: skipped_rules = $shape leaves the count empty and does not fail the step"
    else
      fail "not run: skipped_rules = $shape gives '$(not_run_count)', pack step exit $(cat "$WS/pack.code")"
    fi
  }
done
# A rule without an id is still a rule that did not run: it keeps its line, and its reason stays the reason.
notrun_wrapper notrun-noid '.skipped_rules = [{"rule_id": "", "reason": "no id given"}, {"reason": "id missing"}]'
CLI_DIR="$WORK/notrun-noid" run_job not-run-noid none "./not-run-pack.yaml" clean.tar.gz && {
  if grep -Fq 'Pack rule (unnamed rule) was not run: no id given.' "$WS/pack.log" \
    && grep -Fq 'Pack rule (unnamed rule) was not run: id missing.' "$WS/pack.log" \
    && ! grep -q 'Pack rule no id given' "$WS/pack.log" && [[ "$(not_run_count)" == "2" ]]; then
    pass "not run: two rules without an id are both counted and named as unnamed, each with its reason"
  else
    fail "not run: a rule without an id is misread (count '$(not_run_count)'): $(grep -c 'Pack rule no id given' "$WS/pack.log" || true) annotation(s) take the reason for the id"
  fi
}

# Rules without an id cannot be told apart, so none is merged away: two with one reason are two rules. A rule whose
# real id is the display word for "no id" stays its own rule, and the list file keeps the id the CLI gave.
notrun_wrapper notrun-unnamed '.skipped_rules = [{"rule_id": "", "reason": "same"}, {"rule_id": "   ", "reason": "same"}, {"rule_id": "(unnamed rule)", "reason": "real id"}]'
CLI_DIR="$WORK/notrun-unnamed" run_job not-run-unnamed none "./not-run-pack.yaml" clean.tar.gz && {
  list="$(output_of "$WS/out.pack" pack_rules_not_run_file || true)"
  if [[ "$(not_run_count)" == "3" && "$(annotations)" == "3" ]] \
    && [[ "$(grep -c "$(printf '^\tsame$')" "$list" || true)" == "2" ]]; then
    pass "not run: unnamed rules are never merged, a blank id is unnamed, and the list file keeps the empty id"
  else
    fail "not run: three rules (two unnamed with one reason, one named like the display word) give count '$(not_run_count)', $(annotations) annotation(s)"
  fi
  # The job summary lists every one of them, the unnamed ones too.
  if [[ "$(pack_summary 3 "$list" | grep -c '^  - `(unnamed rule)`: ')" == "3" ]]; then
    pass "not run: the job summary lists the unnamed rules"
  else
    fail "not run: the job summary drops rules without an id"
  fi
}
# One rule in two bundles with two reasons: the reason of the first bundle in the list, whatever the locale sorts first.
# shellcheck disable=SC2016
notrun_wrapper notrun-order '.skipped_rules = [{"rule_id": "p@1:R1", "reason": (if $b == "clean.tar.gz" then "zz from clean" else "aa from warning" end)}]'
CLI_DIR="$WORK/notrun-order" run_job not-run-order none "./not-run-pack.yaml" clean.tar.gz warning.tar.gz && {
  first=$(basename "$(head -n1 "$(output_of "$WS/out.discover" bundles_file)")" .tar.gz)
  if [[ "$(annotations)" == "1" ]] && grep -q "was not run: .* from $first\." "$WS/pack.log"; then
    pass "not run: a rule with two reasons keeps the reason of the first bundle ($first)"
  else
    fail "not run: the kept reason is not the first bundle's ($first): $(grep -o 'was not run: [a-z ]*' "$WS/pack.log" | tr '\n' ';')"
  fi
}

# baseline_found says that a comparison was made. A restored directory without the baseline report is not one.
step_script baseline-diff > "$WORK/baseline-diff.sh"
baseline_found() { # <baseline report: yes|no|garbage|noruns> [current report: yes|garbage]; prints the output value
  local ws="$WORK/baseline-$1-$RANDOM"
  mkdir -p "$ws/.assay-baseline" "$ws/reports"
  echo '{"runs":[{"results":[]}]}' > "$ws/reports/lint.sarif"
  [[ "${2:-yes}" == "garbage" ]] && echo 'not json' > "$ws/reports/lint.sarif"
  case "$1" in
    yes) echo '{"runs":[{"results":[]}]}' > "$ws/.assay-baseline/lint.sarif" ;;
    garbage) echo 'not json' > "$ws/.assay-baseline/lint.sarif" ;;
    noruns) echo '{}' > "$ws/.assay-baseline/lint.sarif" ;;
  esac
  : > "$ws/out"
  (cd "$ws" && env -i PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" GITHUB_OUTPUT="$ws/out" \
    REPORTS_DIR="$ws/reports" bash "$WORK/baseline-diff.sh") > "$ws/log" 2>&1 || true
  output_of "$ws/out" baseline_found || true
}
[[ "$(baseline_found yes)" == "true" ]] && pass "baseline: a comparison with a baseline report publishes baseline_found=true (control)" \
  || fail "baseline: a comparison with a baseline report does not publish baseline_found=true"
[[ "$(baseline_found no)" == "false" ]] && pass "baseline: a directory without the baseline report publishes baseline_found=false" \
  || fail "baseline: no baseline report, yet baseline_found is '$(baseline_found no)'"
# A report that cannot be read was not compared either.
for case in "garbage yes" "noruns yes" "yes garbage"; do
  # shellcheck disable=SC2086 # two words on purpose
  got=$(baseline_found $case)
  [[ "$got" == "false" ]] && pass "baseline: an unreadable report (baseline/current: $case) publishes baseline_found=false" \
    || fail "baseline: an unreadable report (baseline/current: $case) publishes baseline_found='$got'"
done

# shellcheck disable=SC2016 # Ruby compares a literal workflow expression.
if out=$(ruby -ryaml -e '
  declared = YAML.safe_load_file(ARGV[0], aliases: false).fetch("outputs")
  want = "${{ steps.pack-lint.outputs.pack_rules_not_run }}"
  abort("pack_rules_not_run must be declared as #{want}") unless declared.dig("pack_rules_not_run", "value") == want
  abort("README does not document pack_rules_not_run") unless
    File.read(ARGV[1], encoding: "UTF-8").match?(/^\| `pack_rules_not_run` \|/)
' "$ACTION" "$REPO_ROOT/README.md" 2>&1); then
  pass "not run: pack_rules_not_run is a declared and documented output"
else
  fail "not run: $out"
fi

# Leg 3: the pack results leave the job. The pack step must run before the reports artifact is uploaded, so the
# artifact can hold the pack SARIF.
pack_at=$(step_index pack-lint)
artifact_at=$(step_index "Upload reports artifact")
if [[ "$pack_at" -lt "$artifact_at" ]]; then
  pass "order: the pack step runs before the reports artifact upload"
else
  fail "order: the pack step (position $pack_at) runs after the reports artifact upload (position $artifact_at)"
fi

if [[ "$failed" -gt 0 ]]; then
  echo "$failed check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
