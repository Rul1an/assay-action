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

# The oracle: what the CLI itself reports for one bundle, as "<errors> <warnings>".
cli_counts() { # <fail_on> <bundle path> [--pack <packs>]
  local fail_on=$1 bundle=$2
  shift 2
  (cd "$(dirname "$bundle")/../.." && assay_cli evidence lint --format json --fail-on "$fail_on" "$@" "$bundle" 2>/dev/null) \
    | jq -r '"\(.summary.errors) \(.summary.warnings)"'
}

# Leg 1: the counts the action publishes equal the CLI's summary, summed over bundles.
counts_case() { # <name> <fail_on> <bundle>...
  local name=$1 fail_on=$2
  shift 2
  run_job "$name" "$fail_on" "" "$@" || return 0
  local want_errors=0 want_warns=0 bundle counts
  for bundle in "$@"; do
    counts=$(cli_counts none "$WS/ws/.assay/evidence/$bundle")
    [[ "$counts" =~ ^[0-9]+\ [0-9]+$ ]] || { fail "$name: the oracle gave no counts for $bundle ('$counts')"; return 0; }
    want_errors=$((want_errors + ${counts% *}))
    want_warns=$((want_warns + ${counts#* }))
  done
  local got_errors got_warns
  got_errors=$(output_of "$WS/out.process" findings_error)
  got_warns=$(output_of "$WS/out.process" findings_warn)
  if [[ "$got_errors" == "$want_errors" && "$got_warns" == "$want_warns" ]]; then
    pass "$name: findings_error=$got_errors findings_warn=$got_warns equal the CLI summary"
  else
    fail "$name: action says errors=$got_errors warnings=$got_warns, the CLI says errors=$want_errors warnings=$want_warns"
  fi
}

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
