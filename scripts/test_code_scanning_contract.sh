#!/usr/bin/env bash
set -euo pipefail

# What the action sends to code scanning is what the CLI found, for every bundle and for packs, under a category
# the action owns.
#
# GitHub reads a SARIF upload by run: one analysis per tool and category, and a run's own
# `automationDetails.id` wins over the `category` input of the upload action. The CLI writes an id that holds the
# bundle's run id and the CLI version, so left alone every run and every CLI upgrade opens a new category and the
# alerts of the old one never close. This test pins, on the bytes the action's own steps write:
#
#   1. `lint.sarif` is one run that carries the results of every bundle (it was the first bundle's file).
#   2. That run's category is the action's (`category` input, or the generated one), not the CLI's.
#   3. Pack findings get their own single-run file and their own category, and only pack rules' results.
#   4. Both files are uploaded by the pinned upload action, the pack one after the pack step.
#
# The expected results are read from the CLI's own SARIF for each bundle. No count is written here.
#
# Usage: ASSAY_BIN_DIR=<dir holding an `assay`> bash scripts/test_code_scanning_contract.sh

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${ACTION_FILE:-$REPO_ROOT/action.yml}"
FIXTURES="$REPO_ROOT/scripts/fixtures/cli-verdict"
failed=0

fail() {
  echo "FAIL: $*" >&2
  failed=$((failed + 1))
}

pass() {
  echo "PASS: $*"
}

check() { # <label> <command...>: pass when the command succeeds
  local label=$1
  shift
  if "$@"; then pass "$label"; else fail "$label"; fi
}

if [[ -z "${ASSAY_BIN_DIR:-}" || ! -x "${ASSAY_BIN_DIR}/assay" ]]; then
  echo "FAIL: set ASSAY_BIN_DIR to a directory holding an assay binary" >&2
  exit 2
fi
for tool in jq ruby; do
  command -v "$tool" >/dev/null || { echo "FAIL: $tool is required" >&2; exit 2; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home"

step_script() { # the run: script of one step, by id or name, from the parsed document
  ruby -ryaml -e '
    doc = YAML.safe_load_file(ARGV[0], aliases: false)
    step = doc.fetch("runs").fetch("steps").find { |s| s["id"] == ARGV[1] || s["name"] == ARGV[1] }
    abort("no step #{ARGV[1]} with a run script") unless step && step["run"]
    print step["run"]
  ' "$ACTION" "$1"
}

output_of() { # <github_output file> <key>
  grep -E "^$2=" "$1" | tail -n1 | cut -d= -f2- || true
}

assay_cli() {
  env -i HOME="$WORK/home" PATH="$ASSAY_BIN_DIR:/usr/bin:/bin" "$ASSAY_BIN_DIR/assay" "$@"
}

# One job: discover, process, the category step, and with a pack also pack-lint and the pack category step.
# Bundles are copied under distinct names so two bundles with findings exist.
run_job() { # <name> <user category or ""> <packs or ""> <bundle=fixture>...
  local name=$1 user_category=$2 packs=$3
  shift 3
  WS="$WORK/$name"
  mkdir -p "$WS/ws/.assay/evidence" "$WS/tmp"
  local pair
  for pair in "$@"; do
    mkdir -p "$(dirname "$WS/ws/.assay/evidence/${pair%%=*}")"
    cp "$FIXTURES/${pair#*=}" "$WS/ws/.assay/evidence/${pair%%=*}"
  done
  cp "$FIXTURES"/*.yaml "$WS/ws/"
  local base=(env -i HOME="$WORK/home" PATH="$ASSAY_BIN_DIR:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
    GITHUB_WORKSPACE="$WS/ws" GITHUB_ACTION_PATH="$REPO_ROOT" RUNNER_TEMP="$WS/tmp")
  local id
  for id in discover process sarif-category pack-lint pack-sarif; do
    : > "$WS/out.$id"
  done

  step_script discover > "$WS/discover.sh"
  (cd "$WS/ws" && "${base[@]}" GITHUB_OUTPUT="$WS/out.discover" BUNDLES_PATTERN="${BUNDLES_PATTERN-.assay/evidence/*.tar.gz}" \
    EVIDENCE_MODE=optional SANDBOX_BUNDLE="" bash "$WS/discover.sh") > "$WS/discover.log" 2>&1 \
    || { fail "$name: discover step failed"; return 1; }

  step_script process > "$WS/process.sh"
  (cd "$WS/ws" && "${base[@]}" GITHUB_OUTPUT="$WS/out.process" FAIL_ON=none \
    BUNDLES_FILE="$(output_of "$WS/out.discover" bundles_file)" \
    INDEX_PATH="$(output_of "$WS/out.discover" evidence_index_path)" \
    bash "$WS/process.sh") > "$WS/process.log" 2>&1 \
    || { fail "$name: process step failed"; sed 's/^/    /' "$WS/process.log" >&2; return 1; }
  REPORTS="$(output_of "$WS/out.process" reports_dir)"

  step_script sarif-category > "$WS/category.sh"
  (cd "$WS/ws" && "${base[@]}" GITHUB_OUTPUT="$WS/out.sarif-category" USER_CATEGORY="$user_category" \
    RUNNER_OS=Linux WORKFLOW_NAME=ci JOB_NAME=review REPORTS_DIR="$REPORTS" \
    LINT_SARIF_READY="$(output_of "$WS/out.process" lint_sarif_ready)" bash "$WS/category.sh") \
    > "$WS/category.log" 2>&1 || { fail "$name: category step failed"; return 1; }
  CATEGORY="$(output_of "$WS/out.sarif-category" category)"

  if [[ -n "$packs" ]]; then
    step_script pack-lint > "$WS/pack-lint.sh"
    (cd "$WS/ws" && "${base[@]}" GITHUB_OUTPUT="$WS/out.pack-lint" FAIL_ON=none PACKS="$packs" \
      BUNDLES_FILE="$(output_of "$WS/out.discover" bundles_file)" REPORTS_DIR="$REPORTS" \
      bash "$WS/pack-lint.sh") > "$WS/pack-lint.log" 2>&1 \
      || { fail "$name: pack step failed"; sed 's/^/    /' "$WS/pack-lint.log" >&2; return 1; }
    if step_script pack-sarif > "$WS/pack-sarif.sh" 2>/dev/null; then
      (cd "$WS/ws" && "${base[@]}" GITHUB_OUTPUT="$WS/out.pack-sarif" CATEGORY="$CATEGORY" REPORTS_DIR="$REPORTS" \
        bash "$WS/pack-sarif.sh") > "$WS/pack-sarif.log" 2>&1 || { fail "$name: pack SARIF step failed"; return 1; }
    fi
  fi
}

# The oracle: the CLI's own SARIF results for one bundle, as sorted "ruleId fingerprint" lines.
cli_results() { # <bundle path> [--pack <packs>]
  local bundle=$1
  shift
  (cd "$WS/ws" && assay_cli evidence lint --format sarif --fail-on none "$@" "$bundle" 2>/dev/null) \
    | jq -r '.runs[].results[] | "\(.ruleId) \(.partialFingerprints["assayLintFingerprint/v1"])"'
}

file_results() { # <sarif file>
  jq -r '.runs[].results[] | "\(.ruleId) \(.partialFingerprints["assayLintFingerprint/v1"])"' "$1"
}

same_lines() { # <expected> <actual>, compared as sorted multisets
  [[ "$(sort <<<"$1")" == "$(sort <<<"$2")" ]]
}

echo "CLI under test: $(assay_cli --version)"

# ---------------------------------------------------------------------------------------------------------------
# 1 and 2. Lint results of every bundle, in one run, under the action's category
# ---------------------------------------------------------------------------------------------------------------

# The clean bundle sorts first, so "the first bundle's file" carries no result at all.
if run_job lint "" "" a-clean.tar.gz=clean.tar.gz b-warn.tar.gz=warning.tar.gz c-warn.tar.gz=warning.tar.gz; then
  lint="$REPORTS/lint.sarif"
  want="$(for b in a-clean b-warn c-warn; do cli_results ".assay/evidence/$b.tar.gz"; done)"
  if [[ -z "$want" ]]; then
    fail "lint: the fixtures yield no result with this CLI, so nothing below discriminates"
  else
    pass "lint: the CLI reports $(wc -l <<<"$want" | tr -d ' ') results over three bundles (control)"
  fi
  check "lint: lint.sarif is one run" test "$(jq '.runs | length' "$lint")" = "1"
  if same_lines "$want" "$(file_results "$lint")"; then
    pass "lint: lint.sarif carries the results of every bundle"
  else
    fail "lint: lint.sarif has $(file_results "$lint" | grep -c . || true) results, the CLI reports $(grep -c . <<<"$want") over the bundles"
  fi
  check "lint: rules are listed once each" test \
    "$(jq '[.runs[].tool.driver.rules[].id] | length' "$lint")" = "$(jq '[.runs[].tool.driver.rules[].id] | unique | length' "$lint")"
  check "lint: no result points at a rule by position" test "$(jq '[.runs[].results[] | select(has("ruleIndex"))] | length' "$lint")" = "0"

  want_category="assay-ci-review-Linux"
  check "category: the generated category is the documented one" test "$CATEGORY" = "$want_category"
  got_id="$(jq -r '[.runs[].automationDetails.id] | join(",")' "$lint")"
  if [[ "$got_id" == "$want_category/" ]]; then
    pass "category: the run carries the action's category ($got_id)"
  else
    fail "category: the run carries '$got_id', so the category input of the upload is ignored (want '$want_category/')"
  fi
fi

if run_job user-category "team/evidence" "" b-warn.tar.gz=warning.tar.gz; then
  got_id="$(jq -r '[.runs[].automationDetails.id] | join(",")' "$REPORTS/lint.sarif")"
  check "category: a category the user sets is the one the run carries" test "$got_id" = "team/evidence/"
  check "category: the step says the file is ready to upload" test "$(output_of "$WS/out.sarif-category" ready)" = "true"
fi

# Two bundles with one file name in different directories are two bundles: each keeps its own report.
if BUNDLES_PATTERN="" run_job same-name "" "./failing-pack.yaml" b.tar.gz=clean.tar.gz nested/b.tar.gz=warning.tar.gz; then
  want="$(for b in b nested/b; do cli_results ".assay/evidence/$b.tar.gz"; done)"
  if same_lines "$want" "$(file_results "$REPORTS/lint.sarif")"; then
    pass "same name: lint.sarif carries each of two bundles named b.tar.gz once"
  else
    fail "same name: lint.sarif has $(file_results "$REPORTS/lint.sarif" | tr '\n' ';'), the CLI reports $(tr '\n' ';' <<<"$want")"
  fi
  want="$(for b in b nested/b; do cli_results ".assay/evidence/$b.tar.gz" --pack ./failing-pack.yaml; done | grep '^cli-verdict-fixture@1\.0\.0:' || true)"
  if same_lines "$want" "$(file_results "$REPORTS/pack-code-scanning.sarif" 2>/dev/null)"; then
    pass "same name: the pack file carries each of two bundles named b.tar.gz once"
  else
    fail "same name: the pack file does not carry both bundles' pack findings"
  fi
  check "same name: both per-bundle lint reports are kept" test "$(find "$REPORTS" -name 'lint-b*.sarif' | wc -l | tr -d ' ')" = "2"
  # The pack rule fires the same way on both bundles, so the merged results cannot tell one report read twice from
  # two reports. The files can.
  check "same name: both per-bundle pack reports are kept" test "$(find "$REPORTS" -name 'pack-lint-b*.sarif' | wc -l | tr -d ' ')" = "2"
  check "same name: the pack step lists two different reports" test "$(sort -u "$REPORTS/pack-sarif-files.list" | wc -l | tr -d ' ')" = "2"
fi

# The naming function on its own: every bundle of a run gets a name no other holds, the name is a plain file name
# whatever the bundle is called, and it returns for any input.
if [[ -f "$REPO_ROOT/scripts/unique_stem.sh" ]]; then
  stems="$(/bin/bash -c '
    source "$1"; used=$(mktemp); : > "$used"
    for bundle in a/b.tar.gz c/b.tar.gz d/b-2.tar.gz e/b.tar.gz "f/x y.tar.gz" "g/x y.tar.gz" $'"'"'h/n\nl.tar.gz'"'"' $'"'"'i/n\nl.tar.gz'"'"' "j/-rf.tar.gz"; do
      unique_stem "$used" "$bundle"
    done' _ "$REPO_ROOT/scripts/unique_stem.sh" 2>&1 &
    pid=$!; ( sleep 10; kill "$pid" 2>/dev/null ) & wait "$pid")" || true
  check "stem: nine bundles get nine names" test "$(grep -c . <<<"$stems")" = "9"
  check "stem: no two bundles share a name" test "$(sort -u <<<"$stems" | grep -c .)" = "9"
  check "stem: the first bundle keeps its name and the next one is numbered from 2" test \
    "$(sed -n '1p;2p' <<<"$stems" | tr '\n' ' ')" = "b b-2 "
  if grep -qvE '^[A-Za-z0-9._-]+$' <<<"$stems"; then
    fail "stem: a name holds a character that is not safe in a file name: $(grep -vE '^[A-Za-z0-9._-]+$' <<<"$stems" | head -n1)"
  else
    pass "stem: every name is a plain file name"
  fi
else
  fail "stem: scripts/unique_stem.sh does not exist"
fi

# A report left by an earlier use of the action in the same job is not this run's report. When this run's review
# step wrote none, the category step must not stamp the old file or call it ready.
step_script sarif-category > "$WORK/category-only.sh"
mkdir -p "$WORK/stale"
printf '%s' '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"assay-evidence-lint","rules":[]}},"results":[],"automationDetails":{"id":"old/"}}]}' > "$WORK/stale/lint.sarif"
: > "$WORK/stale/out"
env -i PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" GITHUB_OUTPUT="$WORK/stale/out" USER_CATEGORY="" RUNNER_OS=Linux \
  WORKFLOW_NAME=ci JOB_NAME=review REPORTS_DIR="$WORK/stale" LINT_SARIF_READY="" bash "$WORK/category-only.sh" \
  > "$WORK/stale/log" 2>&1 || true
if ! grep -q '^ready=true$' "$WORK/stale/out" && [[ "$(jq -r '.runs[0].automationDetails.id' "$WORK/stale/lint.sarif")" == "old/" ]]; then
  pass "stale: a lint.sarif this run did not write is neither stamped nor announced"
else
  fail "stale: an earlier run's lint.sarif was stamped or announced as this run's"
fi

# ---------------------------------------------------------------------------------------------------------------
# 3. Pack findings: their own file, their own category, pack rules only
# ---------------------------------------------------------------------------------------------------------------

if run_job pack "" "./failing-pack.yaml" a-clean.tar.gz=clean.tar.gz b-warn.tar.gz=warning.tar.gz; then
  pack="$REPORTS/pack-code-scanning.sarif"
  want="$(for b in a-clean b-warn; do cli_results ".assay/evidence/$b.tar.gz" --pack ./failing-pack.yaml; done | grep '^cli-verdict-fixture@1\.0\.0:' || true)"
  if [[ "$(grep -c . <<<"$want")" -ge 2 ]]; then
    pass "pack: the CLI reports a pack finding for each of two bundles (control)"
  else
    fail "pack: the fixture pack yields fewer than two findings, so merging is not exercised"
  fi
  if [[ ! -f "$pack" ]]; then
    fail "pack: no pack file for code scanning was written"
  else
    check "pack: the pack file is one run" test "$(jq '.runs | length' "$pack")" = "1"
    if same_lines "$want" "$(file_results "$pack")"; then
      pass "pack: the pack file carries the pack findings of every bundle, and only those"
    else
      fail "pack: the pack file has $(file_results "$pack" | grep -c . || true) results, the CLI reports $(grep -c . <<<"$want") pack findings"
    fi
    pack_id="$(jq -r '[.runs[].automationDetails.id] | join(",")' "$pack")"
    lint_id="$(jq -r '[.runs[].automationDetails.id] | join(",")' "$REPORTS/lint.sarif")"
    check "pack: the pack run has its own category under the action's" test "$pack_id" = "$CATEGORY/pack/"
    check "pack: lint and pack are two categories of one tool" test "$pack_id" != "$lint_id"
    check "pack: the pack metadata the summary reads is still published" test \
      "$(output_of "$WS/out.pack-lint" pack_applied)" = "cli-verdict-fixture@1.0.0"
  fi
fi

# The fixtures trip no built-in rule, so "pack rules only" is exercised on a pack report that holds one: the pack
# step's own SARIF for one bundle, with a built-in result added.
if step_script pack-sarif > "$WORK/pack-sarif-only.sh" 2>/dev/null; then
  mkdir -p "$WORK/mixed"
  (cd "$FIXTURES" && assay_cli evidence lint --format sarif --fail-on none --pack ./failing-pack.yaml warning.tar.gz 2>/dev/null) \
    | jq '.runs[0].results += [
        {"ruleId": "ASSAY-W001", "level": "warning", "message": {"text": "built-in"}},
        {"ruleId": "another-pack@2.0.0:X-1", "level": "warning", "message": {"text": "a rule of a pack that was not applied"}}]
        | .runs[0].tool.driver.rules += [{"id": "another-pack@2.0.0:X-1"}]' \
    > "$WORK/mixed/pack-lint-mixed.sarif"
  printf '%s\n' "$WORK/mixed/pack-lint-mixed.sarif" > "$WORK/mixed/pack-sarif-files.list"
  if env -i PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" GITHUB_ACTION_PATH="$REPO_ROOT" \
    GITHUB_OUTPUT="$WORK/mixed/out" CATEGORY="cat" REPORTS_DIR="$WORK/mixed" bash "$WORK/pack-sarif-only.sh" \
    > "$WORK/mixed/log" 2>&1; then
    check "pack: only results of the applied pack's rules are in the pack file" test \
      "$(jq -c '[.runs[0].results[].ruleId]' "$WORK/mixed/pack-code-scanning.sarif")" = '["cli-verdict-fixture@1.0.0:CLV-001"]'
    check "pack: only the applied pack's rules are in the pack file's rule list" test \
      "$(jq -c '[.runs[0].tool.driver.rules[].id]' "$WORK/mixed/pack-code-scanning.sarif")" = '["cli-verdict-fixture@1.0.0:CLV-001"]'
  else
    fail "pack: the pack SARIF step failed on a mixed report"
  fi
  # A report that does not name the packs it applied: the action cannot tell pack findings from others, and an
  # empty upload would close every open pack alert. It must not write or announce a file.
  mkdir -p "$WORK/unnamed"
  jq 'del(.runs[0].tool.driver.properties.assayPacks)' "$WORK/mixed/pack-lint-mixed.sarif" > "$WORK/unnamed/pack-lint-x.sarif"
  printf '%s\n' "$WORK/unnamed/pack-lint-x.sarif" > "$WORK/unnamed/pack-sarif-files.list"
  env -i PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" GITHUB_ACTION_PATH="$REPO_ROOT" \
    GITHUB_OUTPUT="$WORK/unnamed/out" CATEGORY="cat" REPORTS_DIR="$WORK/unnamed" bash "$WORK/pack-sarif-only.sh" \
    > "$WORK/unnamed/log" 2>&1 && unnamed_code=0 || unnamed_code=$?
  check "pack: a report that names no applied pack does not fail the job" test "$unnamed_code" = "0"
  if [[ ! -e "$WORK/unnamed/pack-code-scanning.sarif" ]] && ! grep -q '^ready=true$' "$WORK/unnamed/out" 2>/dev/null \
    && grep -q '::warning::' "$WORK/unnamed/log"; then
    pass "pack: a report that names no applied pack is not uploaded as an empty analysis, and says so"
  else
    fail "pack: a report that names no applied pack still produced an upload"
  fi
  # Two bundles whose reports name different packs: both packs' results are kept.
  mkdir -p "$WORK/twopacks"
  jq '.runs[0].tool.driver.properties.assayPacks = [{"name": "another-pack", "version": "2.0.0"}]' \
    "$WORK/mixed/pack-lint-mixed.sarif" > "$WORK/twopacks/pack-lint-b.sarif"
  cp "$WORK/mixed/pack-lint-mixed.sarif" "$WORK/twopacks/pack-lint-a.sarif"
  printf '%s\n' "$WORK/twopacks/pack-lint-a.sarif" "$WORK/twopacks/pack-lint-b.sarif" > "$WORK/twopacks/pack-sarif-files.list"
  env -i PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" GITHUB_ACTION_PATH="$REPO_ROOT" \
    GITHUB_OUTPUT="$WORK/twopacks/out" CATEGORY="cat" REPORTS_DIR="$WORK/twopacks" bash "$WORK/pack-sarif-only.sh" \
    > "$WORK/twopacks/log" 2>&1 || true
  check "pack: packs named by any bundle's report are kept, not only the first bundle's" test \
    "$(jq -c '[.runs[0].results[].ruleId] | unique' "$WORK/twopacks/pack-code-scanning.sarif" 2>/dev/null)" = '["another-pack@2.0.0:X-1","cli-verdict-fixture@1.0.0:CLV-001"]'
else
  fail "pack: the action has no pack-sarif step"
fi

# The status step after a process step that wrote no SARIF: nothing failed to upload, so it must not say so.
step_script sarif-status > "$WORK/status.sh"
: > "$WORK/status.out"
status_log="$(env -i PATH="/usr/bin:/bin" GITHUB_OUTPUT="$WORK/status.out" UPLOAD_OUTCOME=skipped IS_FORK_PR=false \
  SARIF_READY="" bash "$WORK/status.sh" 2>&1 || true)"
if grep -q '^uploaded=false$' "$WORK/status.out" && ! grep -qi 'upload failed' <<<"$status_log"; then
  pass "status: an upload skipped for lack of a SARIF file is not reported as a failed upload"
else
  fail "status: a skipped upload is reported as a failed one ($status_log)"
fi
status_log="$(env -i PATH="/usr/bin:/bin" GITHUB_OUTPUT="$WORK/status.out" UPLOAD_OUTCOME=skipped IS_FORK_PR=true \
  SARIF_READY="" bash "$WORK/status.sh" 2>&1 || true)"
check "status: on a fork pull request without a SARIF file the reason given is the missing file" grep -q 'No SARIF file was written' <<<"$status_log"
status_log="$(env -i PATH="/usr/bin:/bin" GITHUB_OUTPUT="$WORK/status.out" UPLOAD_OUTCOME=failure IS_FORK_PR=false \
  SARIF_READY="true" bash "$WORK/status.sh" 2>&1 || true)"
check "status: a failed upload is still reported as one (control)" grep -qi 'upload failed' <<<"$status_log"

# ---------------------------------------------------------------------------------------------------------------
# The merge itself refuses what it cannot merge honestly
# ---------------------------------------------------------------------------------------------------------------

MERGE="$REPO_ROOT/scripts/sarif_single_run.jq"
if [[ ! -f "$MERGE" ]]; then
  fail "merge: scripts/sarif_single_run.jq does not exist"
else
  one='{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"a","rules":[{"id":"R1"}]}},"results":[{"ruleId":"R1","ruleIndex":0}]}]}'
  other='{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"b","rules":[]}},"results":[]}]}'
  if printf '%s\n%s\n' "$one" "$other" | jq -s -f "$MERGE" >/dev/null 2>&1; then
    fail "merge: runs of two different tools were merged into one"
  else
    pass "merge: runs of two different tools are refused"
  fi
  if printf '%s\n' '{"version":"2.1.0","runs":[]}' | jq -s -f "$MERGE" >/dev/null 2>&1; then
    fail "merge: a log without runs produced a run"
  else
    pass "merge: a log without runs is refused"
  fi
  merged="$(printf '%s\n%s\n' "$one" "$one" | jq -s -c -f "$MERGE")"
  check "merge: two runs of one tool become one run with both results (control)" test \
    "$(jq -c '[(.runs | length), (.runs[0].results | length), (.runs[0].tool.driver.rules | length)]' <<<"$merged")" = "[1,2,1]"
  check "merge: a merged result keeps its rule id and loses its rule position" test \
    "$(jq -c '[.runs[0].results[] | [.ruleId, has("ruleIndex")]] | unique' <<<"$merged")" = '[["R1",false]]'
  note='{"descriptor":{"id":"N1"},"message":{"text":"rule not run"},"associatedRule":{"id":"R1","index":3}}'
  with_inv="$(jq -c --argjson note "$note" '.runs[0].invocations = [{"executionSuccessful": true, "workingDirectory": {"uri": "file:///w"}, "toolExecutionNotifications": [$note]}]' <<<"$one")"
  failed_inv="$(jq -c '.runs[0].invocations = [{"executionSuccessful": false}]' <<<"$one")"
  merged="$(printf '%s\n%s\n' "$with_inv" "$with_inv" | jq -s -c -f "$MERGE")"
  check "merge: every run's execution notifications are carried, without a rule position" test \
    "$(jq -c '[.runs[0].invocations | length, (.[0].toolExecutionNotifications | length), ([.[0].toolExecutionNotifications[].associatedRule | has("index")] | any)]' <<<"$merged")" = "[1,2,false]"
  check "merge: the first invocation keeps its other fields" test \
    "$(jq -r '.runs[0].invocations[0].workingDirectory.uri' <<<"$merged")" = "file:///w"
  check "merge: one failed execution makes the merged run a failed one" test \
    "$(printf '%s\n%s\n' "$with_inv" "$failed_inv" | jq -s -f "$MERGE" | jq '.runs[0].invocations[0].executionSuccessful')" = "false"
  check "merge: runs without invocations get none invented" test \
    "$(printf '%s\n%s\n' "$one" "$one" | jq -s -f "$MERGE" | jq '.runs[0] | has("invocations")')" = "false"
fi

# ---------------------------------------------------------------------------------------------------------------
# 4. Both files are uploaded, by the pinned upload action
# ---------------------------------------------------------------------------------------------------------------

# shellcheck disable=SC2016 # Ruby compares literal workflow expressions.
if out=$(ruby -ryaml -e '
  steps = YAML.safe_load_file(ARGV[0], aliases: false).fetch("runs").fetch("steps")
  uploads = steps.each_index.select { |i| steps[i]["uses"].to_s.start_with?("github/codeql-action/upload-sarif@") }
  abort("expected two SARIF uploads, found #{uploads.length}") unless uploads.length == 2
  lint, pack = uploads.map { |i| steps[i] }
  abort("the uploads must be pinned to one commit") unless
    lint["uses"] == pack["uses"] && lint["uses"].match?(/@[0-9a-f]{40}\z/)
  abort("the first upload must send lint.sarif") unless lint.dig("with", "sarif_file").to_s.end_with?("/.assay-reports/lint.sarif")
  abort("the second upload must send the pack file") unless
    pack.dig("with", "sarif_file").to_s.end_with?("/.assay-reports/pack-code-scanning.sarif")
  pack_step = steps.index { |s| s["id"] == "pack-lint" }
  stamp = steps.index { |s| s["id"] == "pack-sarif" }
  abort("no pack-sarif step") unless stamp
  abort("order must be pack-lint, pack-sarif, pack upload") unless pack_step < stamp && stamp < uploads[1]
  cond = pack["if"].to_s
  ["inputs.sarif == \x27true\x27", "inputs.pack != \x27\x27", "steps.pack-sarif.outputs.ready == \x27true\x27",
   "steps.pack-lint.outcome == \x27failure\x27",
   "github.event.pull_request.head.repo.full_name == github.repository"].each do |need|
    abort("the pack upload if: must include #{need}") unless cond.include?(need)
  end
  abort("the pack-sarif step must also run after a pack step that failed on its gate") unless
    steps[stamp]["if"].to_s.include?("steps.pack-lint.outcome == \x27failure\x27")
  abort("the pack upload must use the action category plus /pack") unless
    pack.dig("with", "category") == "${{ steps.sarif-category.outputs.category }}/pack"
  [lint, pack].each do |step|
    abort("an upload must not set continue-on-error") if step.key?("continue-on-error")
  end
  category = steps.find { |s| s["id"] == "sarif-category" }
  # A job that fails on its findings is the job whose findings must reach code scanning.
  [["the category step", category["if"].to_s], ["the lint upload", lint["if"].to_s]].each do |label, expr|
    abort("#{label} must also run after a process step that failed on its gate") unless
      expr.include?("steps.process.outcome == \x27failure\x27")
  end
  abort("the lint upload must wait for a stamped lint.sarif") unless
    lint["if"].to_s.include?("steps.sarif-category.outputs.ready == \x27true\x27")
  abort("the category step must receive the reports directory") unless
    steps.find { |s| s["id"] == "sarif-category" }.dig("env", "REPORTS_DIR") == "${{ steps.process.outputs.reports_dir }}"
' "$ACTION" 2>&1); then
  pass "wiring: lint and pack SARIF are both uploaded, the pack file after the pack step"
else
  fail "wiring: $out"
fi

if [[ "$failed" -gt 0 ]]; then
  echo "$failed check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
