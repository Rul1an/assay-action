#!/usr/bin/env bash
set -euo pipefail

# Behavioral + structural contract for the additive v3 evidence index.
# Production owner: scripts/build_evidence_index.sh (one rule) plus action.yml
# wiring. Fake-assay stays on PATH; this file is also the mutation harness.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INDEX_SH="$REPO_ROOT/scripts/build_evidence_index.sh"
ACTION="$REPO_ROOT/action.yml"
SANITY="$REPO_ROOT/.github/workflows/action-sanity.yml"
failed=0
TMP_DIR=""

fail() {
  echo "FAIL: $*" >&2
  failed=$((failed + 1))
}

pass() {
  echo "PASS: $*"
}

require_file() {
  if [[ ! -f "$1" ]]; then
    echo "missing required file: $1" >&2
    exit 1
  fi
}

file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

require_output() {
  local file="$1"
  local expected="$2"
  if ! grep -Fqx -- "$expected" "$file"; then
    echo "$file must contain exactly: $expected" >&2
    echo "--- $file ---" >&2
    cat "$file" >&2 || true
    return 1
  fi
}

refuse_output() {
  local file="$1"
  local needle="$2"
  if grep -Fq -- "$needle" "$file"; then
    echo "$file must not contain: $needle" >&2
    echo "--- $file ---" >&2
    cat "$file" >&2 || true
    return 1
  fi
}

new_workspace() {
  local ws
  ws="$(mktemp -d "$TMP_DIR/ws.XXXXXX")"
  mkdir -p "$ws/.assay/evidence" "$ws/.assay-reports"
  printf '%s\n' "$ws"
}

write_bundle() {
  local path="$1"
  local payload="$2"
  mkdir -p "$(dirname "$path")"
  printf '%s' "$payload" >"$path"
}

run_index() {
  local ws="$1"
  local mode="$2"
  local bundles_file="$3"
  local sandbox="${4:-}"
  local out="$5"
  WORKSPACE="$ws" \
    EVIDENCE_MODE="$mode" \
    BUNDLES_FILE="$bundles_file" \
    SANDBOX_BUNDLE="$sandbox" \
    INDEX_PATH="$ws/.assay-reports/evidence-index.json" \
    LIST_PATH="$ws/.assay-reports/assay-bundles.txt" \
    GITHUB_OUTPUT="$out" \
    bash "$INDEX_SH" index
}

run_assert() {
  local ws="$1"
  WORKSPACE="$ws" \
    INDEX_PATH="$ws/.assay-reports/evidence-index.json" \
    bash "$INDEX_SH" assert
}

run_seal() {
  local ws="$1"
  local results="$2"
  local out="$3"
  WORKSPACE="$ws" \
    INDEX_PATH="$ws/.assay-reports/evidence-index.json" \
    INTEGRITY_RESULTS="$results" \
    GITHUB_OUTPUT="$out" \
    bash "$INDEX_SH" seal
}

run_finalize() {
  local out="$1"
  shift
  GITHUB_OUTPUT="$out" \
    bash "$INDEX_SH" finalize
}

assert_action_evidence_wiring() {
  local action_file="$1"
  # shellcheck disable=SC2016 # Ruby compares literal composite-action expressions.
  ruby -ryaml -e '
    action = YAML.safe_load_file(ARGV.fetch(0), aliases: true)
    inputs = action.fetch("inputs")
    outputs = action.fetch("outputs")
    steps = action.fetch("runs").fetch("steps")
    by_id = {}
    steps.each do |step|
      id = step["id"]
      next if id.nil?
      abort("duplicate step id #{id}") if by_id.key?(id)
      by_id[id] = step
    end

    mode = inputs.fetch("evidence_mode")
    abort("evidence_mode default must stay optional") unless mode.fetch("default") == "optional"
    abort("evidence_mode must name optional|required") unless
      mode.fetch("description").include?("optional") && mode.fetch("description").include?("required")

    %w[evidence_state evidence_index_path evidence_index_digest].each do |name|
      abort("missing output #{name}") unless outputs.key?(name)
      abort("#{name} must be finalized") unless
        outputs.fetch(name).fetch("value") == "${{ steps.finalize-evidence.outputs.#{name} }}"
    end
    abort("legacy verified must come from finalize-evidence") unless
      outputs.fetch("verified").fetch("value") ==
        "${{ steps.finalize-evidence.outputs.verified }}"

    discover = by_id.fetch("discover")
    abort("discover must receive evidence_mode") unless
      discover.fetch("env")["EVIDENCE_MODE"] == "${{ inputs.evidence_mode }}"
    abort("discover must receive the sandbox bundle") unless
      discover.fetch("env")["SANDBOX_BUNDLE"] ==
        "${{ steps.sandbox-governance.outputs.coding_agent_bundle }}"
    discover_run = discover.fetch("run")
    abort("discover still silently truncates with head -100") if
      discover_run.match?(/head\s+-n?\s*100\b/)
    abort("discover must call build_evidence_index.sh index") unless
      discover_run.include?("build_evidence_index.sh") && discover_run.include?("index")
    abort("discover still fail-opens find with || true") if
      discover_run.include?("|| true")
    abort("discover must not default empty evidence_mode to optional") if
      discover_run.include?("EVIDENCE_MODE:-optional")

    process = by_id.fetch("process")
    process_run = process.fetch("run")
    abort("process must assert indexed bytes before verify") unless
      process_run.include?("build_evidence_index.sh") && process_run.include?("assert")
    verify_at = process_run.index("assay evidence verify")
    assert_at = process_run.index("build_evidence_index.sh")
    abort("process lost assay evidence verify") if verify_at.nil?
    abort("byte assert must run before assay evidence verify") if
      assert_at.nil? || assert_at > verify_at
    abort("process must not invent a second VerifyLimits") if
      process_run.include?("VerifyLimits") || process_run.include?("max_bytes")
    # verified=true is the integrity result and must be written before lint.
    true_at = process_run.index("verified=true")
    lint_at = process_run.index("Lint all bundles")
    abort("process must record verified=true after integrity") if true_at.nil?
    abort("verified=true must be recorded before lint/policy") if
      lint_at.nil? || true_at > lint_at
    after_lint = process_run[lint_at..]
    abort("process must not flip verified false after integrity") if
      after_lint.include?("verified=false")
    abort("process must stay skipped when discovery is empty") unless
      process["if"] == "steps.discover.outputs.found == " + 39.chr + "true" + 39.chr
    abort("process must not invent a BUNDLES array") if
      process_run.include?("BUNDLES=()") || process_run.include?("BUNDLES+=(")
    lint_section = process_run[lint_at..]
    abort("lint pass must while-read BUNDLES_FILE, not $BUNDLES") unless
      lint_section.include?(%q{while IFS= read -r bundle || [ -n "$bundle" ];}) &&
      lint_section.include?(%q{done < "$BUNDLES_FILE"})
    abort("lint pass still iterates $BUNDLES") if
      lint_section.match?(/for bundle in (\$BUNDLES|"\$\{BUNDLES\[@\]\}")/)
    abort("process must not invent a second bundle parser") if
      process_run.include?("compgen -G") || process_run.include?("head -100")
    abort("process must ask sealed-ok after seal") unless
      process_run.include?("build_evidence_index.sh") && process_run.include?("sealed-ok")
    seal_at = process_run.index("sealed-ok")
    true_after_seal = process_run.index("verified=true")
    abort("sealed-ok must run before verified=true") if
      seal_at.nil? || true_after_seal.nil? || seal_at > true_after_seal

    finalize = by_id.fetch("finalize-evidence")
    abort("finalize-evidence must run if: always()") unless finalize["if"] == "always()"
    abort("finalize must receive discover.outcome") unless
      finalize.fetch("env")["DISCOVER_OUTCOME"] == "${{ steps.discover.outcome }}"
    finalize_run = finalize.fetch("run")
    abort("finalize must call build_evidence_index.sh finalize") unless
      finalize_run.include?("build_evidence_index.sh") && finalize_run.include?("finalize")
  ' "$action_file"
}

assert_no_second_fail_on_parser() {
  if [[ -e "$REPO_ROOT/scripts/apply_fail_on.sh" ]]; then
    echo "scripts/apply_fail_on.sh must not exist; the CLI owns fail_on" >&2
    return 1
  fi
  # shellcheck disable=SC2016 # Literal Action source, not a shell expansion.
  if grep -Fq -- 'case "$FAIL_ON"' "$ACTION"; then
    echo "bundle gate grew a local fail_on case" >&2
    return 1
  fi
}

assert_sanity_covers_additive_fields() {
  # shellcheck disable=SC2016 # Ruby compares literal composite-action expressions.
  ruby -ryaml -e '
    workflow = YAML.safe_load_file(ARGV.fetch(0), aliases: true)
    found = false
    workflow.fetch("jobs").each_value do |job|
      steps = job.fetch("steps")
      action = steps.find do |step|
        step["uses"] == "./" &&
          step.dig("with", "evidence_mode") == "required" &&
          step["continue-on-error"] == true
      end
      next if action.nil?
      id = action.fetch("id")
      outcome = "${{ steps.#{id}.outcome }}"
      assert_step = steps.find do |step|
        env = step["env"] || {}
        env.value?(outcome) && step.fetch("run", "").include?(%q{test "$})
      end
      abort("required-zero job must assert steps.#{id}.outcome") if assert_step.nil?
      env = assert_step.fetch("env")
      run = assert_step.fetch("run")
      abort("required-zero assert must compare outcome to failure") unless
        run.include?(%q{test "$OUTCOME" = "failure"})
      %w[evidence_state verified evidence_index_path evidence_index_digest].each do |name|
        abort("required-zero assert lost #{name}") unless
          env.values.any? { |value| value.to_s.include?(name) } || run.include?(name)
      end
      abort("required-zero assert must parse the index document") unless
        run.include?("complete") && run.include?("bundles")
      found = true
    end
    abort("action-sanity.yml must run ./ with evidence_mode=required and continue-on-error") unless found
  ' "$SANITY"
}

expect_invalid_mode() {
  local mode="$1"
  local label="$2"
  local ws bundles out
  ws="$(new_workspace)"
  bundles="$ws/bundles.txt"
  : >"$bundles"
  out="$ws/out.txt"
  : >"$out"
  if run_index "$ws" "$mode" "$bundles" "" "$out" >"$ws/log.txt" 2>&1; then
    fail "${label} evidence_mode was accepted"
    return
  fi
  if [[ -s "$out" ]] && grep -Fq -- "evidence_state=" "$out"; then
    fail "${label} evidence_mode wrote an evidence_state"
    return
  fi
  if [[ -f "$ws/.assay-reports/evidence-index.json" ]]; then
    fail "${label} evidence_mode wrote an index"
    return
  fi
}

test_unknown_mode() {
  expect_invalid_mode "sometimes" "unknown" || return
  pass "unknown evidence_mode fails closed"
}

test_empty_mode_fails_closed() {
  local before="$failed"
  expect_invalid_mode "" "empty"
  if [[ "$failed" -ne "$before" ]]; then
    return
  fi
  pass "empty evidence_mode fails closed"
}

test_whitespace_mode_fails_closed() {
  local before="$failed"
  expect_invalid_mode " " "whitespace"
  expect_invalid_mode $'\t' "tab"
  if [[ "$failed" -ne "$before" ]]; then
    return
  fi
  pass "whitespace evidence_mode fails closed"
}

test_discover_empty_mode_fails_closed() {
  local ws log
  ws="$(new_workspace)"
  log="$ws/discover.log"
  local status=0
  run_discover_fixture "$ws" "$log" "" || status=$?
  if [[ "$status" -eq 0 ]]; then
    fail "discover treated empty evidence_mode as optional"
    cat "$log" >&2 || true
    return
  fi
  if [[ -f "$ws/.assay-reports/evidence-index.json" ]]; then
    fail "empty evidence_mode published an index"
    return
  fi
  pass "discover empty evidence_mode fails closed"
}

test_optional_zero() {
  local ws bundles out
  ws="$(new_workspace)"
  bundles="$ws/bundles.txt"
  : >"$bundles"
  out="$ws/out.txt"
  : >"$out"
  if ! run_index "$ws" "optional" "$bundles" "" "$out" >"$ws/log.txt" 2>&1; then
    fail "optional + zero bundles failed the index step"
    return
  fi
  require_output "$out" "found=false" || { fail "optional + zero did not report found=false"; return; }
  require_output "$out" "count=0" || { fail "optional + zero lost count=0"; return; }
  require_output "$out" "evidence_state=absent" || { fail "optional + zero lost evidence_state=absent"; return; }
  require_output "$out" "verified=false" || { fail "optional + zero lost verified=false"; return; }
  if ! grep -E '^evidence_index_path=' "$out" | grep -Fq -- "evidence-index.json"; then
    fail "optional + zero lost evidence_index_path"
    return
  fi
  if ! grep -Eq '^evidence_index_digest=[0-9a-f]{64}$' "$out"; then
    fail "optional + zero lost evidence_index_digest"
    return
  fi
  if [[ ! -s "$ws/.assay-reports/evidence-index.json" ]]; then
    fail "optional + zero did not write a completed empty index"
    return
  fi
  if ! python3 -c '
import hashlib, json, sys
path = sys.argv[1]
raw = open(path, "rb").read()
d = json.loads(raw)
assert d.get("complete") is True, d
assert d.get("bundles") == []
digest = open(sys.argv[2], encoding="ascii").read().splitlines()
got = [line.split("=", 1)[1] for line in digest if line.startswith("evidence_index_digest=")][-1]
assert got == hashlib.sha256(raw).hexdigest(), (got, hashlib.sha256(raw).hexdigest())
' "$ws/.assay-reports/evidence-index.json" "$out"
  then
    fail "optional + zero must publish a completed empty index (bundles=[], complete=true)"
    return
  fi
  pass "optional + zero succeeds with absent and a completed empty index"
}

test_required_zero() {
  local ws bundles out
  ws="$(new_workspace)"
  bundles="$ws/bundles.txt"
  : >"$bundles"
  out="$ws/out.txt"
  : >"$out"
  if run_index "$ws" "required" "$bundles" "" "$out" >"$ws/log.txt" 2>&1; then
    fail "required + zero bundles succeeded"
    return
  fi
  require_output "$out" "evidence_state=absent" || { fail "required + zero lost evidence_state=absent"; return; }
  require_output "$out" "verified=false" || { fail "required + zero lost verified=false"; return; }
  pass "required + zero fails closed with absent"
}

test_101st_fail_closed() {
  local ws bundles out i
  ws="$(new_workspace)"
  bundles="$ws/bundles.txt"
  : >"$bundles"
  for i in $(seq 1 101); do
    write_bundle "$ws/.assay/evidence/b$(printf '%03d' "$i").tar.gz" "payload-$i"
    printf '%s\n' ".assay/evidence/b$(printf '%03d' "$i").tar.gz" >>"$bundles"
  done
  out="$ws/out.txt"
  : >"$out"
  if run_index "$ws" "optional" "$bundles" "" "$out" >"$ws/log.txt" 2>&1; then
    fail "101st bundle was accepted"
    return
  fi
  if [[ -f "$ws/.assay-reports/evidence-index.json" ]]; then
    if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); raise SystemExit(0 if d.get("complete") is True else 1)' \
      "$ws/.assay-reports/evidence-index.json" 2>/dev/null
    then
      fail "101st bundle published a complete index"
      return
    fi
  fi
  if grep -Fq -- "evidence_index_digest=" "$out"; then
    fail "101st bundle published an index digest"
    return
  fi
  pass "101st bundle fails closed without a complete index"
}

test_sandbox_parity() {
  local ws bundles out sandbox
  ws="$(new_workspace)"
  bundles="$ws/bundles.txt"
  write_bundle "$ws/.assay/evidence/discovered.tar.gz" "discovered-bytes"
  printf '%s\n' ".assay/evidence/discovered.tar.gz" >"$bundles"
  sandbox="$TMP_DIR/assay-coding-agent.tar.gz"
  write_bundle "$sandbox" "sandbox-bytes"
  out="$ws/out.txt"
  : >"$out"
  if ! run_index "$ws" "optional" "$bundles" "$sandbox" "$out" >"$ws/log.txt" 2>&1; then
    fail "sandbox union failed"
    return
  fi
  require_output "$out" "count=2" || { fail "sandbox bundle was omitted from the union"; return; }
  if ! python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
sources=sorted(b["source"] for b in d["bundles"])
paths=sorted(b["path"] for b in d["bundles"])
assert sources==["discovered","sandbox_command"], sources
assert d.get("complete") is False
assert all(b["integrity"]=="pending" for b in d["bundles"])
assert all("/" not in p[:1] and ".." not in p.split("/") for p in paths), paths
' "$ws/.assay-reports/evidence-index.json"
  then
    fail "sandbox bundle missing from the same index"
    return
  fi
  pass "sandbox bundle enters the same index"
}

test_mutation_between_index_and_verify() {
  local ws bundles out
  ws="$(new_workspace)"
  bundles="$ws/bundles.txt"
  write_bundle "$ws/.assay/evidence/live.tar.gz" "indexed-bytes"
  printf '%s\n' ".assay/evidence/live.tar.gz" >"$bundles"
  out="$ws/out.txt"
  : >"$out"
  if ! run_index "$ws" "optional" "$bundles" "" "$out" >"$ws/log.txt" 2>&1; then
    fail "index step failed before the mutation case"
    return
  fi
  write_bundle "$ws/.assay/evidence/live.tar.gz" "mutated-after-index"
  if run_assert "$ws" >"$ws/assert.log" 2>&1; then
    fail "between-index-and-verify mutation was accepted"
    return
  fi
  pass "between-index-and-verify mutation is refused"
}

test_determinism() {
  local ws bundles out digest_a digest_b
  ws="$(new_workspace)"
  bundles="$ws/bundles.txt"
  write_bundle "$ws/.assay/evidence/b.tar.gz" "same-bytes"
  write_bundle "$ws/.assay/evidence/a.tar.gz" "other-bytes"
  printf '%s\n' ".assay/evidence/b.tar.gz" ".assay/evidence/a.tar.gz" >"$bundles"
  out="$ws/out1.txt"
  : >"$out"
  if ! run_index "$ws" "optional" "$bundles" "" "$out"; then
    fail "first determinism run failed"
    return
  fi
  digest_a="$(file_sha256 "$ws/.assay-reports/evidence-index.json")"
  cp "$ws/.assay-reports/evidence-index.json" "$ws/index-a.json"
  rm -f "$ws/.assay-reports/evidence-index.json"
  out="$ws/out2.txt"
  : >"$out"
  if ! run_index "$ws" "optional" "$bundles" "" "$out"; then
    fail "second determinism run failed"
    return
  fi
  digest_b="$(file_sha256 "$ws/.assay-reports/evidence-index.json")"
  if [[ "$digest_a" != "$digest_b" ]]; then
    fail "index digest was not deterministic"
    return
  fi
  if ! cmp -s "$ws/index-a.json" "$ws/.assay-reports/evidence-index.json"; then
    fail "index bytes were not deterministic"
    return
  fi
  pass "index bytes and digest are deterministic"
}

test_safe_paths() {
  local ws bundles out
  ws="$(new_workspace)"
  bundles="$ws/bundles.txt"
  write_bundle "$TMP_DIR/escape.tar.gz" "nope"
  printf '%s\n' "../$(basename "$TMP_DIR")/escape.tar.gz" >"$bundles"
  out="$ws/out.txt"
  : >"$out"
  if run_index "$ws" "optional" "$bundles" "" "$out" >"$ws/log.txt" 2>&1; then
    fail "parent-path bundle was accepted"
    return
  fi
  printf '%s\n' "$TMP_DIR/escape.tar.gz" >"$bundles"
  if run_index "$ws" "optional" "$bundles" "" "$out" >"$ws/log2.txt" 2>&1; then
    fail "absolute out-of-workspace bundle was accepted"
    return
  fi
  pass "unsafe paths are rejected"
}

test_finalize_mapping() {
  local out
  out="$TMP_DIR/finalize-skipped.txt"
  : >"$out"
  if ! DISCOVER_OUTCOME="skipped" DISCOVER_FOUND="" PROCESS_VERIFIED="" \
    INDEX_PATH="" INDEX_DIGEST="" run_finalize "$out" >"$TMP_DIR/finalize-skipped.log" 2>&1
  then
    fail "finalize refused a skipped discovery"
    return
  fi
  refuse_output "$out" "evidence_state=absent" || { fail "finalize manufactured absent when discover never ran"; return; }
  refuse_output "$out" "evidence_state=" || { fail "finalize wrote evidence_state before discovery"; return; }

  out="$TMP_DIR/finalize-cancelled.txt"
  : >"$out"
  DISCOVER_OUTCOME="cancelled" run_finalize "$out"
  refuse_output "$out" "evidence_state=absent" || { fail "finalize manufactured absent on cancelled discover"; return; }

  out="$TMP_DIR/finalize-failed-empty.txt"
  : >"$out"
  DISCOVER_OUTCOME="failure" DISCOVER_FOUND="" PROCESS_VERIFIED="" \
    INDEX_PATH="" INDEX_DIGEST="" run_finalize "$out"
  refuse_output "$out" "evidence_state=absent" || {
    fail "finalize manufactured absent when discover failed before completing"
    return
  }
  refuse_output "$out" "evidence_state=" || {
    fail "finalize wrote evidence_state after a failed incomplete discover"
    return
  }
  refuse_output "$out" "verified=" || {
    fail "finalize wrote verified after a failed incomplete discover"
    return
  }

  out="$TMP_DIR/finalize-absent.txt"
  : >"$out"
  DISCOVER_OUTCOME="success" DISCOVER_FOUND="false" PROCESS_VERIFIED="" \
    INDEX_PATH=".assay-reports/evidence-index.json" INDEX_DIGEST="abc" \
    run_finalize "$out"
  require_output "$out" "evidence_state=absent" || { fail "finalize lost absent after a real empty discover"; return; }
  require_output "$out" "verified=false" || { fail "finalize lost verified=false for absent"; return; }

  out="$TMP_DIR/finalize-discovered.txt"
  : >"$out"
  DISCOVER_OUTCOME="success" DISCOVER_FOUND="true" PROCESS_VERIFIED="" \
    INDEX_PATH=".assay-reports/evidence-index.json" INDEX_DIGEST="abc" \
    run_finalize "$out"
  require_output "$out" "evidence_state=discovered" || { fail "finalize lost discovered before integrity"; return; }
  require_output "$out" "verified=false" || { fail "finalize lost verified=false for discovered"; return; }

  out="$TMP_DIR/finalize-verified.txt"
  : >"$out"
  DISCOVER_OUTCOME="success" DISCOVER_FOUND="true" PROCESS_VERIFIED="true" \
    PACK_STATUS="invalid_pack" \
    INDEX_PATH=".assay-reports/evidence-index.json" INDEX_DIGEST="abc" \
    run_finalize "$out"
  require_output "$out" "evidence_state=verified" || { fail "post-integrity pack failure lost evidence_state=verified"; return; }
  require_output "$out" "verified=true" || { fail "post-integrity pack failure flipped verified false"; return; }

  out="$TMP_DIR/finalize-rejected.txt"
  : >"$out"
  DISCOVER_OUTCOME="success" DISCOVER_FOUND="true" PROCESS_VERIFIED="false" \
    INDEX_PATH=".assay-reports/evidence-index.json" INDEX_DIGEST="abc" \
    run_finalize "$out"
  require_output "$out" "evidence_state=rejected" || { fail "integrity failure lost rejected"; return; }
  require_output "$out" "verified=false" || { fail "integrity failure lost verified=false"; return; }
  pass "finalize mapping preserves absent/discovered/verified/rejected"
}

test_seal_keeps_indexed_digest_binding() {
  local ws bundles out results
  ws="$(new_workspace)"
  bundles="$ws/bundles.txt"
  write_bundle "$ws/.assay/evidence/live.tar.gz" "indexed-bytes"
  printf '%s\n' ".assay/evidence/live.tar.gz" >"$bundles"
  out="$ws/out.txt"
  : >"$out"
  run_index "$ws" "optional" "$bundles" "" "$out"
  results="$ws/results.tsv"
  printf '%s\t%s\n' ".assay/evidence/live.tar.gz" "verified" >"$results"
  out="$ws/seal.txt"
  : >"$out"
  if ! run_seal "$ws" "$results" "$out"; then
    fail "seal after integrity failed"
    return
  fi
  if ! python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
assert d["complete"] is True
assert d["bundles"][0]["integrity"]=="verified"
assert d["bundles"][0]["sha256"]==sys.argv[2]
' "$ws/.assay-reports/evidence-index.json" "$(file_sha256 "$ws/.assay/evidence/live.tar.gz")"
  then
    fail "sealed index lost the exact-byte digest"
    return
  fi
  issued="$(grep -E '^evidence_index_digest=' "$out" | tail -n1 | cut -d= -f2-)"
  actual="$(file_sha256 "$ws/.assay-reports/evidence-index.json")"
  if [[ -z "$issued" || "$issued" != "$actual" ]]; then
    fail "sealed evidence_index_digest does not match SHA-256 of the final index bytes"
    return
  fi
  pass "seal keeps exact-byte SHA-256 after integrity"
}

extract_process_run() {
  local dest="$1"
  ruby -ryaml -e '
    action = YAML.safe_load_file(ARGV.fetch(0), aliases: true)
    step = action.fetch("runs").fetch("steps").find { |s| s["id"] == "process" }
    abort("missing process step") if step.nil?
    File.write(ARGV.fetch(1), step.fetch("run"))
  ' "$ACTION" "$dest"
}

install_sanity_assay() {
  local bin="$1"
  mkdir -p "$bin"
  cat >"$bin/assay" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "--version" ]; then
  echo "assay 3.35.0"
  exit 0
fi
if [ "${1:-}" = "evidence" ] && [ "${2:-}" = "verify" ]; then
  exit "${ASSAY_VERIFY_EXIT:-0}"
fi
if [ "${1:-}" = "evidence" ] && [ "${2:-}" = "lint" ] && [ "${3:-}" = "--format" ] && [ "${4:-}" = "json" ]; then
  printf '%s\n' '{"findings":[]}'
  exit 0
fi
if [ "${1:-}" = "evidence" ] && [ "${2:-}" = "lint" ] && [ "${3:-}" = "--format" ] && [ "${4:-}" = "sarif" ]; then
  printf '%s\n' '{"version":"2.1.0","$schema":"https://json.schemastore.org/sarif-2.1.0.json","runs":[{"tool":{"driver":{"name":"Assay Action Sanity","informationUri":"https://github.com/Rul1an/assay-action"}},"results":[]}]}'
  exit 0
fi
echo "unsupported assay sanity command: $*" >&2
exit 2
SH
  chmod +x "$bin/assay"
}

run_process_fixture() {
  local ws="$1"
  local raw_list="$2"
  local log="$3"
  local out="$ws/github-output.txt"
  local script="$TMP_DIR/process-step.sh"
  extract_process_run "$script"
  install_sanity_assay "$ws/bin"
  mkdir -p "$ws/.assay-reports" "$ws/tmp"
  : >"$out"
  local indexed="$ws/index-out.txt"
  : >"$indexed"
  if ! WORKSPACE="$ws" EVIDENCE_MODE="optional" BUNDLES_FILE="$raw_list" \
    INDEX_PATH="$ws/.assay-reports/evidence-index.json" \
    LIST_PATH="$ws/.assay-reports/assay-bundles.txt" \
    GITHUB_OUTPUT="$indexed" \
    bash "$INDEX_SH" index >"$ws/index.log" 2>&1
  then
    echo "index step failed before process" >&2
    cat "$ws/index.log" >&2
    return 1
  fi
  local list_path="$ws/.assay-reports/assay-bundles.txt"
  (
    cd "$ws"
    PATH="$ws/bin:$PATH" \
      ASSAY_VERIFY_EXIT="${ASSAY_VERIFY_EXIT:-0}" \
      GITHUB_WORKSPACE="$ws" \
      GITHUB_ACTION_PATH="$REPO_ROOT" \
      GITHUB_OUTPUT="$out" \
      BUNDLES_FILE="$list_path" \
      INDEX_PATH=".assay-reports/evidence-index.json" \
      RUNNER_TEMP="$ws/tmp" \
      FAIL_ON="error" \
      bash "$script"
  ) >"$log" 2>&1
}

last_verified() {
  grep -E '^verified=' "$1" | tail -n1 || true
}

extract_discover_run() {
  local dest="$1"
  ruby -ryaml -e '
    action = YAML.safe_load_file(ARGV.fetch(0), aliases: true)
    step = action.fetch("runs").fetch("steps").find { |s| s["id"] == "discover" }
    abort("missing discover step") if step.nil?
    File.write(ARGV.fetch(1), step.fetch("run"))
  ' "$ACTION" "$dest"
}

run_discover_fixture() {
  local ws="$1"
  local log="$2"
  local mode="${3-optional}"
  local script="$TMP_DIR/discover-step.sh"
  extract_discover_run "$script"
  mkdir -p "$ws/.assay-reports" "$ws/tmp"
  local out="$ws/github-output.txt"
  : >"$out"
  (
    cd "$ws"
    GITHUB_WORKSPACE="$ws" \
      GITHUB_ACTION_PATH="$REPO_ROOT" \
      GITHUB_OUTPUT="$out" \
      BUNDLES_PATTERN="" \
      EVIDENCE_MODE="$mode" \
      SANDBOX_BUNDLE="" \
      RUNNER_TEMP="$ws/tmp" \
      bash "$script"
  ) >"$log" 2>&1
}

test_process_lints_one_bundle() {
  local ws bundles log
  ws="$(new_workspace)"
  write_bundle "$ws/.assay/evidence/noop.tar.gz" ""
  bundles="$ws/raw.txt"
  printf '%s\n' ".assay/evidence/noop.tar.gz" >"$bundles"
  log="$ws/process.log"
  if ! run_process_fixture "$ws" "$bundles" "$log"; then
    fail "one-bundle lint-pass failed (list-file read)"
    cat "$log" >&2 || true
    return
  fi
  if ! grep -Fq -- "Linting: .assay/evidence/noop.tar.gz" "$log"; then
    fail "one-bundle lint-pass did not read the list file"
    return
  fi
  require_output "$ws/github-output.txt" "verified=true" || {
    fail "one-bundle process lost verified=true"
    return
  }
  pass "one bundle is linted via BUNDLES_FILE"
}

test_process_lints_path_with_space() {
  local ws bundles log
  ws="$(new_workspace)"
  write_bundle "$ws/.assay/evidence/no op.tar.gz" "space-bytes"
  bundles="$ws/raw.txt"
  printf '%s\n' ".assay/evidence/no op.tar.gz" >"$bundles"
  log="$ws/process.log"
  if ! run_process_fixture "$ws" "$bundles" "$log"; then
    fail "space-path lint-pass failed"
    cat "$log" >&2 || true
    return
  fi
  if ! grep -Fq -- "Linting: .assay/evidence/no op.tar.gz" "$log"; then
    fail "space-path was not linted as one list-file entry"
    return
  fi
  if grep -Fq -- "Linting: .assay/evidence/no" "$log" &&
    ! grep -Fq -- "Linting: .assay/evidence/no op.tar.gz" "$log"
  then
    fail "space-path was word-split before lint"
    return
  fi
  pass "path with a space is linted via BUNDLES_FILE"
}

test_empty_discovery_skips_process() {
  # shellcheck disable=SC2016 # Literal Action source, not a shell expansion.
  if ! grep -Fq -- "if: steps.discover.outputs.found == 'true'" "$ACTION"; then
    fail "process is no longer skipped when discovery is empty"
    return
  fi
  if grep -Fq -- "BUNDLES=()" "$ACTION"; then
    fail "empty discovery was patched with a BUNDLES array"
    return
  fi
  pass "empty discovery skips process instead of an empty array"
}

test_unsealed_pending_not_complete() {
  local ws bundles out
  ws="$(new_workspace)"
  write_bundle "$ws/.assay/evidence/a.tar.gz" "pending-bytes"
  bundles="$ws/bundles.txt"
  printf '%s\n' ".assay/evidence/a.tar.gz" >"$bundles"
  out="$ws/out.txt"
  : >"$out"
  if ! run_index "$ws" "optional" "$bundles" "" "$out"; then
    fail "index of one pending bundle failed"
    return
  fi
  if ! python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get("complete") is False, d
assert d["bundles"][0]["integrity"]=="pending"
' "$ws/.assay-reports/evidence-index.json"
  then
    fail "all-pending index was published as complete"
    return
  fi
  pass "all-pending index is not complete"
}

test_required_zero_unsealed() {
  local ws bundles out
  ws="$(new_workspace)"
  bundles="$ws/bundles.txt"
  : >"$bundles"
  out="$ws/out.txt"
  : >"$out"
  if run_index "$ws" "required" "$bundles" "" "$out" >"$ws/log.txt" 2>&1; then
    fail "required + zero succeeded"
    return
  fi
  require_output "$out" "evidence_state=absent" || { fail "required + zero lost absent"; return; }
  require_output "$out" "verified=false" || { fail "required + zero lost verified=false"; return; }
  if [[ ! -s "$ws/.assay-reports/evidence-index.json" ]]; then
    fail "required + zero lost the completed empty index"
    return
  fi
  if ! python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d.get("complete") is True; assert d.get("bundles")==[]' \
    "$ws/.assay-reports/evidence-index.json"
  then
    fail "required + zero must still emit a completed empty index"
    return
  fi
  pass "required + zero fails closed with a completed empty index"
}

test_verify_failure_seals_rejected() {
  local ws bundles log last
  ws="$(new_workspace)"
  write_bundle "$ws/.assay/evidence/bad.tar.gz" "reject-me"
  bundles="$ws/raw.txt"
  printf '%s\n' ".assay/evidence/bad.tar.gz" >"$bundles"
  log="$ws/process.log"
  local status=0
  ASSAY_VERIFY_EXIT=1 run_process_fixture "$ws" "$bundles" "$log" || status=$?
  if [[ "$status" -eq 0 ]]; then
    fail "failing assay evidence verify was treated as success"
    return
  fi
  last="$(last_verified "$ws/github-output.txt")"
  if [[ "$last" == "verified=true" ]]; then
    fail "published verified=true beside a rejected integrity row"
    return
  fi
  if [[ "$last" != "verified=false" ]]; then
    fail "verify failure did not emit verified=false (got ${last:-empty})"
    return
  fi
  if ! python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
assert d["bundles"][0]["integrity"]=="rejected"
assert d.get("complete") is True
' "$ws/.assay-reports/evidence-index.json"
  then
    fail "verify failure did not seal a rejected row"
    return
  fi
  if grep -Fq -- "verified=true" "$ws/github-output.txt"; then
    fail "verified=true was published in the same outputs as a rejected row"
    return
  fi
  pass "verify failure seals rejected and never publishes verified=true"
}

test_discovery_find_failure() {
  local ws log
  ws="$(new_workspace)"
  write_bundle "$ws/.assay/evidence/ok.tar.gz" "visible"
  mkdir -p "$ws/.assay/evidence/locked"
  write_bundle "$ws/.assay/evidence/locked/hidden.tar.gz" "hidden"
  chmod 000 "$ws/.assay/evidence/locked"
  log="$ws/discover.log"
  local status=0
  run_discover_fixture "$ws" "$log" "required" || status=$?
  chmod 755 "$ws/.assay/evidence/locked" 2>/dev/null || true
  if [[ "$status" -eq 0 ]]; then
    fail "discovery traversal error was fail-opened"
    cat "$log" >&2 || true
    return
  fi
  if [[ -f "$ws/.assay-reports/evidence-index.json" ]] &&
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); raise SystemExit(0 if d.get("complete") is True else 1)' \
      "$ws/.assay-reports/evidence-index.json" 2>/dev/null
  then
    fail "failed discovery published a complete prefix index"
    return
  fi
  pass "discovery traversal error fails closed"
}

run_positive_suite() {
  require_file "$INDEX_SH"
  require_file "$ACTION"
  require_file "$SANITY"
  assert_no_second_fail_on_parser || fail "second fail_on parser present"
  if ! assert_action_evidence_wiring "$ACTION"; then
    fail "action.yml evidence wiring"
  fi
  if ! assert_sanity_covers_additive_fields; then
    fail "action-sanity additive field coverage"
  fi
  test_unknown_mode
  test_empty_mode_fails_closed
  test_whitespace_mode_fails_closed
  test_discover_empty_mode_fails_closed
  test_optional_zero
  test_required_zero
  test_101st_fail_closed
  test_sandbox_parity
  test_mutation_between_index_and_verify
  test_determinism
  test_safe_paths
  test_finalize_mapping
  test_seal_keeps_indexed_digest_binding
  test_process_lints_one_bundle
  test_process_lints_path_with_space
  test_empty_discovery_skips_process
  test_unsealed_pending_not_complete
  test_required_zero_unsealed
  test_verify_failure_seals_rejected
  test_discovery_find_failure
  if [[ "$failed" -ne 0 ]]; then
    echo "$failed evidence-index check(s) failed" >&2
    return 1
  fi
}

restore_canonical() {
  if [[ -f "$TMP_DIR/action.yml.bak" ]]; then
    cp "$TMP_DIR/action.yml.bak" "$ACTION"
  fi
  if [[ -f "$TMP_DIR/index.sh.bak" ]]; then
    cp "$TMP_DIR/index.sh.bak" "$INDEX_SH"
  fi
  if [[ -f "$TMP_DIR/sanity.yml.bak" ]]; then
    cp "$TMP_DIR/sanity.yml.bak" "$SANITY"
  fi
}

mutate_expect_fail() {
  local name="$1"
  local status
  shift
  restore_canonical
  "$@"
  failed=0
  status=0
  if run_positive_suite >"$TMP_DIR/mutation-$name.log" 2>&1; then
    status=0
  else
    status=$?
  fi
  if [[ "$status" -eq 0 ]]; then
    restore_canonical
    echo "MUTATION DID NOT BITE: $name" >&2
    cat "$TMP_DIR/mutation-$name.log" >&2
    return 1
  fi
  restore_canonical
  echo "MUTATION BIT: $name"
}

mut_head_100() {
  python3 - "$ACTION" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
old = "find . \\( -path './.assay/evidence/*.tar.gz' -o -path './evidence/*.tar.gz' \\) -type f 2>/dev/null"
if old not in text:
    # Broader fallback: inject head -100 after the first find in discover.
    text = text.replace(" -type f 2>/dev/null", " -type f 2>/dev/null | head -100", 1)
else:
    text = text.replace(old, old + " | head -100", 1)
p.write_text(text)
PY
}

mut_omit_sandbox() {
  python3 - "$INDEX_SH" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
old = 'if [[ -n "${SANDBOX_BUNDLE:-}" && -f "$SANDBOX_BUNDLE" ]]; then'
if old not in text:
    raise SystemExit("sandbox union owner not found")
p.write_text(text.replace(old, "if false; then", 1))
PY
}

mut_unknown_mode() {
  python3 - "$INDEX_SH" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
text = text.replace('optional|required)', 'optional|required|*)')
# If the script uses a case arm, also rewrite unknown into optional.
text = text.replace('unknown evidence_mode', 'treating unknown evidence_mode as optional')
p.write_text(text)
PY
}

mut_empty_mode_defaults_optional() {
  python3 - "$ACTION" "$INDEX_SH" <<'PY'
from pathlib import Path
import sys
action = Path(sys.argv[1])
index = Path(sys.argv[2])
a = action.read_text()
if "EVIDENCE_MODE:-optional" in a:
    raise SystemExit("discover already defaults empty mode")
if 'EVIDENCE_MODE="${EVIDENCE_MODE}"' in a:
    a = a.replace(
        'EVIDENCE_MODE="${EVIDENCE_MODE}"',
        'EVIDENCE_MODE="${EVIDENCE_MODE:-optional}"',
        1,
    )
else:
    raise SystemExit("discover EVIDENCE_MODE assignment not found")
action.write_text(a)
s = index.read_text()
s = s.replace('case "${EVIDENCE_MODE:-}"', 'case "${EVIDENCE_MODE:-optional}"', 1)
s = s.replace('case "${EVIDENCE_MODE}"', 'case "${EVIDENCE_MODE:-optional}"', 1)
index.write_text(s)
PY
}

mut_manufacture_absent() {
  python3 - "$INDEX_SH" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
old = "# Discovery never ran. Do not manufacture absent.\n      exit 0"
if old not in text:
    raise SystemExit("finalize never-ran guard not found")
p.write_text(text.replace(
    old,
    'emit "evidence_state=absent"\n      emit "verified=false"\n      exit 0',
    1,
))
PY
}

mut_manufacture_absent_on_failed_empty() {
  python3 - "$INDEX_SH" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
old = '''  if [[ "${DISCOVER_FOUND:-}" == "" ]]; then
    exit 0
  fi'''
if old not in text:
    raise SystemExit("empty DISCOVER_FOUND guard not found")
p.write_text(text.replace(
    old,
    '''  if [[ "${DISCOVER_FOUND:-}" == "" ]]; then
    emit "evidence_state=absent"
    emit "verified=false"
    exit 0
  fi''',
    1,
))
PY
}

mut_flip_verified_after_integrity() {
  python3 - "$ACTION" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
old = 'echo "::error::$GATE_HITS bundle(s) have findings at or above \'$FAIL_ON\' ($ERRORS errors, $WARNS warnings)"'
if old in text:
    text = text.replace(
        old,
        old + '\n          echo "verified=false" >> $GITHUB_OUTPUT',
        1,
    )
else:
    text = text.replace(
        "exit 1\n        fi\n",
        'echo "verified=false" >> $GITHUB_OUTPUT\n          exit 1\n        fi\n',
        1,
    )
p.write_text(text)
PY
}

mut_allow_101() {
  python3 - "$INDEX_SH" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
text = text.replace("100", "10000")
p.write_text(text)
PY
}

mut_drop_sealed_ok_guard() {
  python3 - "$ACTION" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
old = """        if ! WORKSPACE="${GITHUB_WORKSPACE}" \\
          INDEX_PATH="$INDEX_PATH" \\
          bash "$GITHUB_ACTION_PATH/scripts/build_evidence_index.sh" sealed-ok; then
          echo "verified=false" >> $GITHUB_OUTPUT
          exit 2  # Distinct exit code for verification failure
        fi
"""
# Also bite the pre-fix FAILED counter if it is still present.
old_failed = '''        if [ "$FAILED" -gt 0 ]; then
          echo "verified=false" >> $GITHUB_OUTPUT
          exit 2  # Distinct exit code for verification failure
        fi
'''
if old in text:
    p.write_text(text.replace(old, "", 1))
elif old_failed in text:
    p.write_text(text.replace(old_failed, "", 1))
else:
    raise SystemExit("sealed-ok / FAILED guard not found")
PY
}

mut_restore_find_or_true() {
  python3 - "$ACTION" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
old = "find . \\( -path './.assay/evidence/*.tar.gz' -o -path './evidence/*.tar.gz' \\) -type f 2>/dev/null >> \"$RAW\""
if old not in text:
    raise SystemExit("discover find line not found")
if "|| true" in text[text.find(old):text.find(old)+len(old)+20]:
    raise SystemExit("find already fail-opens")
p.write_text(text.replace(old, old + " || true", 1))
PY
}

mut_hardcode_complete_true() {
  python3 - "$INDEX_SH" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
if "complete_from_rows" not in text:
    raise SystemExit("complete_from_rows not found")
text = text.replace(
    "complete = complete_from_rows(rows)",
    "complete = True",
)
text = text.replace(
    "doc['complete'] = complete_from_rows(doc['bundles'])",
    "doc['complete'] = True",
)
p.write_text(text)
PY
}

mut_lint_pass_uses_bundles_var() {
  python3 - "$ACTION" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
needle = "        # Lint all bundles (one at a time, aggregate results)"
idx = text.find(needle)
if idx < 0:
    raise SystemExit("lint pass not found")
rest = text[idx:]
old_loop = (
    '        while IFS= read -r bundle || [ -n "$bundle" ]; do\n'
    '          [ -z "$bundle" ] && continue\n'
    '          echo "Linting: $bundle"\n'
)
if old_loop not in rest:
    raise SystemExit("lint while-read not found")
p.write_text(
    text[:idx]
    + rest.replace(
        old_loop,
        '        for bundle in $BUNDLES; do\n          echo "Linting: $bundle"\n',
        1,
    )
)
PY
}

mut_seal_digest_constant() {
  python3 - "$INDEX_SH" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
old = 'emit "evidence_index_digest=$(file_sha256 "$dest")"'
if old not in text:
    raise SystemExit("sealed digest emission not found")
p.write_text(text.replace(
    old,
    'emit "evidence_index_digest=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"',
    1,
))
PY
}

mut_skip_assert() {
  python3 - "$INDEX_SH" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
# Make assert a no-op so a between-index mutation is accepted.
if 'assert)' in text or '"assert"' in text or "assert)" in text:
    text = text.replace("assert)", 'assert) exit 0 ;;\n  _disabled_assert)')
p.write_text(text)
PY
}

run_mutations() {
  cp "$ACTION" "$TMP_DIR/action.yml.bak"
  cp "$INDEX_SH" "$TMP_DIR/index.sh.bak"
  cp "$SANITY" "$TMP_DIR/sanity.yml.bak"
  trap 'restore_canonical; rm -rf "$TMP_DIR"' EXIT

  restore_canonical
  if ! run_positive_suite >"$TMP_DIR/mutation-noop.log" 2>&1; then
    echo "no-op control failed" >&2
    cat "$TMP_DIR/mutation-noop.log" >&2
    return 1
  fi
  echo "MUTATION CONTROL: no-op stayed green"

  mutate_expect_fail "restore-head-100" mut_head_100
  mutate_expect_fail "omit-sandbox" mut_omit_sandbox
  mutate_expect_fail "unknown-mode-accepted" mut_unknown_mode
  mutate_expect_fail "empty-mode-defaults-optional" mut_empty_mode_defaults_optional
  mutate_expect_fail "manufacture-absent" mut_manufacture_absent
  mutate_expect_fail "manufacture-absent-on-failed-empty" mut_manufacture_absent_on_failed_empty
  mutate_expect_fail "flip-verified-after-integrity" mut_flip_verified_after_integrity
  mutate_expect_fail "allow-101st" mut_allow_101
  mutate_expect_fail "accept-between-index-mutation" mut_skip_assert
  mutate_expect_fail "lint-pass-uses-BUNDLES" mut_lint_pass_uses_bundles_var
  mutate_expect_fail "drop-sealed-ok-guard" mut_drop_sealed_ok_guard
  mutate_expect_fail "restore-find-or-true" mut_restore_find_or_true
  mutate_expect_fail "hardcode-complete-true" mut_hardcode_complete_true
  mutate_expect_fail "seal-digest-constant" mut_seal_digest_constant
}

main() {
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT

  if [[ ! -f "$INDEX_SH" ]]; then
    echo "RED: $INDEX_SH does not exist yet" >&2
    exit 1
  fi

  run_positive_suite
  if [[ "$failed" -ne 0 ]]; then
    echo "$failed evidence-index check(s) failed" >&2
    exit 1
  fi

  if [[ "${SKIP_MUTATIONS:-0}" != "1" ]]; then
    run_mutations
  fi

  echo "evidence index contract passed"
}

main "$@"
