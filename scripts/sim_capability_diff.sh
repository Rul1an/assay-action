#!/usr/bin/env bash
# Experimental capability-diff simulation.
#
# Exercises the local experimental scripts only. This does not validate action
# runtime behavior and does not implement ADR 0001 production invariants.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d -t assay-capability-sim-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

event() {
  local data="${3:-}"
  if [ -z "$data" ]; then
    data="{}"
  fi
  jq -nc --arg type "$1" --arg subject "$2" --argjson data "$data" \
    '{type:$type, subject:$subject, data:$data}'
}

profile() {
  event "assay.profile.started" "profile:test" '{}'
}

receipt() {
  event "assay.receipt.promptfoo.assertion_component.v1" "receipt:test" '{"schema":"assay.receipt.promptfoo.assertion-component.v1"}'
}

net() {
  event "assay.net.connect" "$1" '{}'
}

fs_access() {
  event "assay.fs.access" "$1" '{}'
}

proc_exec() {
  event "assay.process.exec" "$1" '{}'
}

tool_decision() {
  jq -nc --arg tool "$1" --arg command "${2:-}" \
    '{type:"assay.tool.decision", subject:$tool, data:{tool:$tool, command:$command, verdict:"allow"}}'
}

policy_event() {
  jq -nc --arg verdict "$1" --arg rule "$2" --arg subject "$3" \
    '{type:"assay.policy.evaluated", subject:$subject, data:{verdict:$verdict, rule:$rule, subject:$subject}}'
}

bundle() {
  local out="$1"
  shift

  mkdir -p "$(dirname "$out")"
  if [ "$#" -eq 0 ]; then
    : > "$out"
    return
  fi
  printf '%s\n' "$@" > "$out"
}

run_diff() {
  local base="$1"
  local current="$2"
  VERBOSE="${VERBOSE:-0}" bash "$HERE/diff_surface.sh" "$base" "$current"
}

run_extract() {
  bash "$HERE/extract_surface.sh" "$1"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if ! printf '%s\n' "$haystack" | grep -F -- "$needle" >/dev/null; then
    echo "missing expected text: $needle" >&2
    return 1
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  if printf '%s\n' "$haystack" | grep -F -- "$needle" >/dev/null; then
    echo "unexpected text present: $needle" >&2
    return 1
  fi
}

record() {
  local name="$1"
  local status
  shift

  set +e
  ( set -e; "$@" )
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    PASS=$((PASS + 1))
    printf '%-34s pass\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '%-34s FAIL\n' "$name"
  fi
}

make_pair() {
  local name="$1"
  BASE="$WORK/$name/base.ndjson"
  CURRENT="$WORK/$name/current.ndjson"
}

case_receipt_skip() {
  make_pair receipt-skip
  bundle "$BASE" "$(receipt)"
  bundle "$CURRENT" "$(receipt)"
  out=$(run_diff "$BASE" "$CURRENT")
  assert_contains "$out" "Capability diff skipped: no runtime capability events found."
}

case_lifecycle_skip() {
  make_pair lifecycle-skip
  bundle "$BASE" "$(profile)"
  bundle "$CURRENT" "$(profile)"
  out=$(run_diff "$BASE" "$CURRENT")
  assert_contains "$out" "receipt-only or lifecycle-only bundles"
}

case_noop_runtime() {
  make_pair noop-runtime
  bundle "$BASE" "$(net api.example.com:443)" "$(fs_access /tmp/a.txt)" "$(proc_exec echo)"
  cp "$BASE" "$CURRENT"
  out=$(run_diff "$BASE" "$CURRENT")
  assert_contains "$out" "Summary: +0 new, -0 removed across capability dimensions."
  assert_not_contains "$out" "### Network endpoints"
}

case_add_net() {
  make_pair add-net
  bundle "$BASE" "$(net api.example.com:443)"
  bundle "$CURRENT" "$(net api.example.com:443)" "$(net api.openai.com:443)"
  out=$(run_diff "$BASE" "$CURRENT")
  assert_contains "$out" "### Network endpoints"
  assert_contains "$out" "+ api.openai.com:443"
}

case_add_fs() {
  make_pair add-fs
  bundle "$BASE" "$(fs_access /tmp/a.txt)"
  bundle "$CURRENT" "$(fs_access /tmp/a.txt)" "$(fs_access /etc/hosts)"
  out=$(run_diff "$BASE" "$CURRENT")
  assert_contains "$out" "### Filesystem paths"
  assert_contains "$out" "+ /etc/hosts"
}

case_add_proc() {
  make_pair add-proc
  bundle "$BASE" "$(proc_exec echo)"
  bundle "$CURRENT" "$(proc_exec echo)" "$(proc_exec curl)"
  out=$(run_diff "$BASE" "$CURRENT")
  assert_contains "$out" "### Processes"
  assert_contains "$out" "+ curl"
}

case_add_tool() {
  make_pair add-tool
  bundle "$BASE" "$(tool_decision fs.read)"
  bundle "$CURRENT" "$(tool_decision fs.read)" "$(tool_decision shell.exec)"
  out=$(run_diff "$BASE" "$CURRENT")
  assert_contains "$out" "### Tool calls"
  assert_contains "$out" "+ shell.exec"
}

case_add_policy_deny() {
  make_pair add-policy-deny
  bundle "$BASE" "$(policy_event allow filesystem /tmp/a.txt)"
  bundle "$CURRENT" "$(policy_event allow filesystem /tmp/a.txt)" "$(policy_event deny filesystem-sensitive /etc/hosts)"
  out=$(run_diff "$BASE" "$CURRENT")
  assert_contains "$out" "### Policy verdicts (deny) [deny]"
  assert_contains "$out" "+ filesystem-sensitive:/etc/hosts"
}

case_add_policy_warn() {
  make_pair add-policy-warn
  bundle "$BASE" "$(policy_event allow net api.example.com:443)"
  bundle "$CURRENT" "$(policy_event allow net api.example.com:443)" "$(policy_event warn broad-network api.openai.com:443)"
  out=$(run_diff "$BASE" "$CURRENT")
  assert_contains "$out" "### Policy verdicts (warn)"
  assert_contains "$out" "+ broad-network:api.openai.com:443"
}

case_allow_aggregate() {
  make_pair allow-aggregate
  bundle "$BASE" "$(policy_event allow net api.example.com:443)"
  bundle "$CURRENT" "$(policy_event allow net api.example.com:443)" "$(policy_event allow net api.openai.com:443)" "$(policy_event allow fs /tmp/b.txt)"
  out=$(run_diff "$BASE" "$CURRENT")
  assert_contains "$out" "### Policy verdicts (allow)"
  assert_contains "$out" "+2 new, -0 removed (set VERBOSE=1 for details)"
  assert_not_contains "$out" "+ net:api.openai.com:443"
}

case_allow_verbose() {
  make_pair allow-verbose
  bundle "$BASE" "$(policy_event allow net api.example.com:443)"
  bundle "$CURRENT" "$(policy_event allow net api.example.com:443)" "$(policy_event allow net api.openai.com:443)"
  out=$(VERBOSE=1 run_diff "$BASE" "$CURRENT")
  assert_contains "$out" "### Policy verdicts (allow)"
  assert_contains "$out" "+ net:api.openai.com:443"
}

case_remove_net() {
  make_pair remove-net
  bundle "$BASE" "$(net api.example.com:443)" "$(net api.old.com:443)"
  bundle "$CURRENT" "$(net api.example.com:443)"
  out=$(run_diff "$BASE" "$CURRENT")
  assert_contains "$out" "- api.old.com:443"
}

case_remove_fs() {
  make_pair remove-fs
  bundle "$BASE" "$(fs_access /tmp/a.txt)" "$(fs_access /etc/hosts)"
  bundle "$CURRENT" "$(fs_access /tmp/a.txt)"
  out=$(run_diff "$BASE" "$CURRENT")
  assert_contains "$out" "- /etc/hosts"
}

case_remove_proc() {
  make_pair remove-proc
  bundle "$BASE" "$(proc_exec echo)" "$(proc_exec curl)"
  bundle "$CURRENT" "$(proc_exec echo)"
  out=$(run_diff "$BASE" "$CURRENT")
  assert_contains "$out" "- curl"
}

case_remove_tool() {
  make_pair remove-tool
  bundle "$BASE" "$(tool_decision fs.read)" "$(tool_decision shell.exec)"
  bundle "$CURRENT" "$(tool_decision fs.read)"
  out=$(run_diff "$BASE" "$CURRENT")
  assert_contains "$out" "- shell.exec"
}

case_remove_policy_deny() {
  make_pair remove-policy-deny
  bundle "$BASE" "$(policy_event deny filesystem-sensitive /etc/hosts)" "$(policy_event allow net api.example.com:443)"
  bundle "$CURRENT" "$(policy_event allow net api.example.com:443)"
  out=$(run_diff "$BASE" "$CURRENT")
  assert_contains "$out" "- filesystem-sensitive:/etc/hosts"
}

case_mixed_delta() {
  make_pair mixed-delta
  bundle "$BASE" "$(net api.example.com:443)" "$(tool_decision fs.read)" "$(policy_event warn old-rule /tmp/old)"
  bundle "$CURRENT" "$(net api.example.com:443)" "$(tool_decision shell.exec)" "$(policy_event deny new-rule /etc/passwd)"
  out=$(run_diff "$BASE" "$CURRENT")
  assert_contains "$out" "+ shell.exec"
  assert_contains "$out" "+ new-rule:/etc/passwd"
  assert_contains "$out" "- fs.read"
  assert_contains "$out" "- old-rule:/tmp/old"
  assert_contains "$out" "Summary: +2 new, -2 removed across capability dimensions."
}

case_reorder_noop() {
  make_pair reorder-noop
  bundle "$BASE" "$(net api.example.com:443)" "$(fs_access /tmp/a.txt)" "$(tool_decision fs.read)"
  bundle "$CURRENT" "$(tool_decision fs.read)" "$(net api.example.com:443)" "$(fs_access /tmp/a.txt)"
  out=$(run_diff "$BASE" "$CURRENT")
  assert_contains "$out" "Summary: +0 new, -0 removed across capability dimensions."
}

case_duplicate_noop() {
  make_pair duplicate-noop
  bundle "$BASE" "$(net api.example.com:443)" "$(net api.example.com:443)" "$(tool_decision fs.read)"
  bundle "$CURRENT" "$(net api.example.com:443)" "$(tool_decision fs.read)" "$(tool_decision fs.read)"
  out=$(run_diff "$BASE" "$CURRENT")
  assert_contains "$out" "Summary: +0 new, -0 removed across capability dimensions."
}

case_tool_name_only() {
  make_pair tool-name-only
  bundle "$BASE" "$(tool_decision shell.exec "git status")"
  bundle "$CURRENT" "$(tool_decision shell.exec "git diff")"
  out=$(run_diff "$BASE" "$CURRENT")
  assert_contains "$out" "Summary: +0 new, -0 removed across capability dimensions."
}

case_empty_base_all_added() {
  make_pair empty-base
  bundle "$BASE"
  bundle "$CURRENT" "$(net api.example.com:443)" "$(tool_decision fs.read)"
  out=$(run_diff "$BASE" "$CURRENT")
  assert_contains "$out" "Summary: +2 new, -0 removed across capability dimensions."
}

case_empty_current_all_removed() {
  make_pair empty-current
  bundle "$BASE" "$(net api.example.com:443)" "$(tool_decision fs.read)"
  bundle "$CURRENT"
  out=$(run_diff "$BASE" "$CURRENT")
  assert_contains "$out" "Summary: +0 new, -2 removed across capability dimensions."
}

case_extractor_filters_empty_subjects() {
  make_pair empty-subject
  bundle "$BASE" "$(event "assay.net.connect" "" '{}')" "$(net api.example.com:443)"
  extracted=$(run_extract "$BASE")
  assert_contains "$extracted" $'net\tapi.example.com:443'
  line_count=$(printf '%s\n' "$extracted" | sed '/^$/d' | wc -l | tr -d ' ')
  if [ "$line_count" != "1" ]; then
    echo "expected one non-empty extracted surface item, got $line_count" >&2
    return 1
  fi
}

case_tar_bundle_input() {
  make_pair tar-bundle-input
  local base_dir="$WORK/tar-bundle-input/base-bundle"
  local current_dir="$WORK/tar-bundle-input/current-bundle"
  local base_tar="$WORK/tar-bundle-input/base.tar.gz"
  local current_tar="$WORK/tar-bundle-input/current.tar.gz"

  mkdir -p "$base_dir" "$current_dir"
  bundle "$base_dir/events.ndjson" "$(net api.example.com:443)"
  bundle "$current_dir/events.ndjson" "$(net api.example.com:443)" "$(tool_decision shell.exec)"
  (cd "$base_dir" && tar -czf "$base_tar" events.ndjson)
  (cd "$current_dir" && tar -czf "$current_tar" events.ndjson)

  out=$(run_diff "$base_tar" "$current_tar")
  assert_contains "$out" "+ shell.exec"
  assert_contains "$out" "Summary: +1 new, -0 removed across capability dimensions."
}

record "receipt-archetype-skip" case_receipt_skip
record "lifecycle-only-skip" case_lifecycle_skip
record "noop-runtime" case_noop_runtime
record "add-network" case_add_net
record "add-filesystem" case_add_fs
record "add-process" case_add_proc
record "add-tool" case_add_tool
record "add-policy-deny" case_add_policy_deny
record "add-policy-warn" case_add_policy_warn
record "allow-aggregate" case_allow_aggregate
record "allow-verbose" case_allow_verbose
record "remove-network" case_remove_net
record "remove-filesystem" case_remove_fs
record "remove-process" case_remove_proc
record "remove-tool" case_remove_tool
record "remove-policy-deny" case_remove_policy_deny
record "mixed-delta" case_mixed_delta
record "reorder-noop" case_reorder_noop
record "duplicate-noop" case_duplicate_noop
record "tool-name-only" case_tool_name_only
record "empty-base-all-added" case_empty_base_all_added
record "empty-current-all-removed" case_empty_current_all_removed
record "extractor-filters-empty-subjects" case_extractor_filters_empty_subjects
record "tar-bundle-input" case_tar_bundle_input

echo
echo "=== Summary ==="
echo "Total: $((PASS + FAIL))   Pass: $PASS   Fail: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
