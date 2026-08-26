#!/usr/bin/env bash
# Structural contract for published-tag-canary.yml: scheduled @v3/@v2 stay
# floating; workflow_dispatch can pin an immutable candidate by SHA.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANARY="$REPO_ROOT/.github/workflows/published-tag-canary.yml"
failed=0
TMP_DIR=""

fail() {
  echo "FAIL: $*" >&2
  failed=$((failed + 1))
}

pass() {
  echo "PASS: $*"
}

assert_canary_contract() {
  local workflow="$1"
  # shellcheck disable=SC2016 # Ruby compares literal workflow expressions.
  ruby -ryaml -e '
    w = YAML.safe_load_file(ARGV.fetch(0), aliases: true)
    triggers = w["on"] || w[true]
    abort("workflow on: block missing") if triggers.nil?
    dispatch = triggers.fetch("workflow_dispatch").fetch("inputs")
    %w[candidate_ref expected_sha].each do |name|
      abort("workflow_dispatch missing #{name}") unless dispatch.key?(name)
    end

    jobs = w.fetch("jobs")
    v3 = jobs.fetch("assay-action-v3")
    v3_uses = v3.fetch("steps").map { |s| s["uses"] }.compact
    abort("scheduled v3 lane lost Rul1an/assay-action@v3") unless
      v3_uses.any? { |u| u.start_with?("Rul1an/assay-action@v3") }
    abort("scheduled v3 lane must not use ./candidate-action") if
      v3_uses.include?("./candidate-action")

    v2 = jobs.fetch("assay-action-v2")
    v2_uses = v2.fetch("steps").map { |s| s["uses"] }.compact
    abort("scheduled v2 lane lost Rul1an/assay-action@v2") unless
      v2_uses.any? { |u| u.start_with?("Rul1an/assay-action@v2") }

    candidate = jobs.fetch("assay-action-candidate")
    abort("candidate job must be dispatch-only") unless
      candidate.fetch("if").include?("workflow_dispatch") &&
      candidate.fetch("if").include?("candidate_ref") &&
      candidate.fetch("if").include?("expected_sha")

    steps = candidate.fetch("steps")
    checkout = steps.find do |step|
      uses = step["uses"].to_s
      uses.include?("actions/checkout") &&
        step.dig("with", "repository") == "Rul1an/assay-action" &&
        step.dig("with", "path") == "candidate-action" &&
        step.dig("with", "ref").to_s.include?("inputs.candidate_ref")
    end
    abort("candidate job must checkout Rul1an/assay-action at candidate_ref into candidate-action") if
      checkout.nil?

    bind = steps.find do |step|
      env = step["env"] || {}
      env.value?("${{ inputs.expected_sha }}") &&
        step.fetch("run", "").include?("rev-parse") &&
        step.fetch("run").include?("candidate-action")
    end
    abort("candidate job must bind resolved HEAD to expected_sha") if bind.nil?

    run = steps.find { |step| step["uses"] == "./candidate-action" }
    abort("candidate job must execute uses: ./candidate-action") if run.nil?
    abort("candidate uses: must not be a floating tag") if
      steps.any? { |step| step["uses"].to_s.start_with?("Rul1an/assay-action@") }

    id = run.fetch("id")
    assert_step = steps.find do |step|
      env = step["env"] || {}
      env.values.any? { |v| v.to_s.include?("steps.#{id}.outputs.evidence_state") } &&
        env.values.any? { |v| v.to_s.include?("steps.#{id}.outputs.verified") } &&
        env.values.any? { |v| v.to_s.include?("steps.#{id}.outputs.evidence_index_path") } &&
        env.values.any? { |v| v.to_s.include?("steps.#{id}.outputs.evidence_index_digest") }
    end
    abort("candidate job must assert evidence outputs from ./candidate-action") if assert_step.nil?
    body = assert_step.fetch("run")
    abort("candidate assert must recompute the index digest") unless
      body.include?("sha256") || body.include?("shasum")
    abort("candidate assert must parse complete and bundles") unless
      body.include?("complete") && body.include?("bundles")
  ' "$workflow"
}

mutate_expect_fail() {
  local name="$1"
  shift
  cp "$TMP_DIR/canary.yml.bak" "$CANARY"
  "$@"
  if assert_canary_contract "$CANARY" >/dev/null 2>&1; then
    cp "$TMP_DIR/canary.yml.bak" "$CANARY"
    echo "MUTATION DID NOT BITE: $name" >&2
    return 1
  fi
  cp "$TMP_DIR/canary.yml.bak" "$CANARY"
  echo "MUTATION BIT: $name"
}

mut_drop_candidate_ref() {
  python3 - "$CANARY" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
if "candidate_ref:" not in text:
    raise SystemExit("candidate_ref missing")
p.write_text(text.replace("candidate_ref:", "unused_ref:", 1))
PY
}

mut_candidate_uses_v3() {
  python3 - "$CANARY" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
if "uses: ./candidate-action" not in text:
    raise SystemExit("./candidate-action missing")
p.write_text(text.replace("uses: ./candidate-action", "uses: Rul1an/assay-action@v3", 1))
PY
}

mut_drop_sha_bind() {
  python3 - "$CANARY" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
if "rev-parse" not in text:
    raise SystemExit("sha bind missing")
p.write_text(text.replace("rev-parse", "rev-list", 1))
PY
}

mut_drop_output_asserts() {
  python3 - "$CANARY" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
needle = "evidence_index_digest"
if needle not in text:
    raise SystemExit("digest assert missing")
p.write_text(text.replace(needle, "unused_digest", 1))
PY
}

main() {
  TMP_DIR="$(mktemp -d)"
  trap 'cp -f "$TMP_DIR/canary.yml.bak" "$CANARY" 2>/dev/null || true; rm -rf "$TMP_DIR"' EXIT
  cp "$CANARY" "$TMP_DIR/canary.yml.bak"

  if ! assert_canary_contract "$CANARY"; then
    fail "published-tag-canary.yml immutable candidate contract"
  else
    pass "published-tag-canary.yml pins an immutable candidate job"
  fi

  if [[ "$failed" -ne 0 ]]; then
    echo "$failed published-tag canary check(s) failed" >&2
    exit 1
  fi

  if [[ "${SKIP_MUTATIONS:-0}" != "1" ]]; then
    if ! assert_canary_contract "$CANARY"; then
      echo "no-op control failed" >&2
      exit 1
    fi
    echo "MUTATION CONTROL: no-op stayed green"
    mutate_expect_fail "drop-candidate-ref" mut_drop_candidate_ref
    mutate_expect_fail "candidate-uses-floating-v3" mut_candidate_uses_v3
    mutate_expect_fail "drop-sha-bind" mut_drop_sha_bind
    mutate_expect_fail "drop-output-asserts" mut_drop_output_asserts
  fi

  echo "published-tag canary contract passed"
}

main "$@"
