#!/usr/bin/env bash
# Structural contract for published-tag-canary.yml: scheduled @v3/@v2 stay
# floating; workflow_dispatch on a v3.x.y tag plus expected_sha runs ./ .
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
    abort("workflow_dispatch must not accept candidate_ref") if dispatch.key?("candidate_ref")
    abort("workflow_dispatch missing expected_sha") unless dispatch.key?("expected_sha")

    jobs = w.fetch("jobs")
    v3 = jobs.fetch("assay-action-v3")
    v3_uses = v3.fetch("steps").map { |s| s["uses"] }.compact
    abort("scheduled v3 lane lost Rul1an/assay-action@v3") unless
      v3_uses.any? { |u| u.start_with?("Rul1an/assay-action@v3") }
    abort("scheduled v3 lane must not use a local action path") if
      v3_uses.any? { |u| u.start_with?("./") }

    v2 = jobs.fetch("assay-action-v2")
    v2_uses = v2.fetch("steps").map { |s| s["uses"] }.compact
    abort("scheduled v2 lane lost Rul1an/assay-action@v2") unless
      v2_uses.any? { |u| u.start_with?("Rul1an/assay-action@v2") }

    candidate = jobs.fetch("assay-action-candidate")
    gate = candidate.fetch("if")
    abort("candidate job must require workflow_dispatch") unless gate.include?("workflow_dispatch")
    abort("non-tag dispatch must not run the candidate job") unless
      gate.include?("github.ref_type") && gate.include?("tag")
    abort("candidate job must require nonempty expected_sha") unless gate.include?("expected_sha")
    abort("candidate job must not gate on candidate_ref") if gate.include?("candidate_ref")

    steps = candidate.fetch("steps")
    abort("candidate job must not mention candidate_ref") if
      steps.any? { |step| step.to_s.include?("candidate_ref") }
    abort("candidate job must not checkout an input-controlled ref") if
      steps.any? { |step|
        step["uses"].to_s.include?("actions/checkout") &&
          step.dig("with", "ref").to_s.include?("inputs.")
      }
    abort("candidate job must not use a secondary checkout path") if
      steps.any? { |step| step.dig("with", "path").to_s.include?("candidate") }

    checkout = steps.find do |step|
      step["uses"].to_s.include?("actions/checkout") &&
        step.dig("with", "persist-credentials") == false &&
        !step.dig("with", "ref") &&
        !step.dig("with", "repository") &&
        !step.dig("with", "path")
    end
    abort("candidate job must checkout the triggering ref with persist-credentials: false") if
      checkout.nil?

    bind = steps.find do |step|
      env = step["env"] || {}
      run = step.fetch("run", "")
      env.value?("${{ inputs.expected_sha }}") &&
        run.include?("rev-parse HEAD") &&
        !run.include?("candidate-action") &&
        (run.include?("ref_name") || run.include?("REF_NAME") || run.include?("GITHUB_REF_NAME")) &&
        run.match?(/v3\\\.\[0-9\]\+|v3\.x\.y|\^v3\\/) &&
        (run.include?(%q{test "$actual" = "$EXPECTED_SHA"}) ||
         run.include?(%q{test "$(git rev-parse HEAD)" = "$EXPECTED_SHA"}))
    end
    abort("candidate job must bind HEAD to expected_sha and the v3.x.y tag name") if bind.nil?

    run = steps.find { |step| step["uses"] == "./" }
    abort("candidate job must execute uses: ./") if run.nil?
    abort("bind step must run before uses: ./") if steps.index(bind) >= steps.index(run)
    abort("candidate uses: must not be a floating tag") if
      steps.any? { |step| step["uses"].to_s.start_with?("Rul1an/assay-action@") }
    abort("candidate uses: must not be ./candidate-action") if
      steps.any? { |step| step["uses"].to_s.include?("candidate-action") }

    id = run.fetch("id")
    assert_step = steps.find do |step|
      env = step["env"] || {}
      env.values.any? { |v| v.to_s.include?("steps.#{id}.outputs.evidence_state") } &&
        env.values.any? { |v| v.to_s.include?("steps.#{id}.outputs.verified") } &&
        env.values.any? { |v| v.to_s.include?("steps.#{id}.outputs.evidence_index_path") } &&
        env.values.any? { |v| v.to_s.include?("steps.#{id}.outputs.evidence_index_digest") }
    end
    abort("candidate job must assert evidence outputs from uses: ./") if assert_step.nil?
    body = assert_step.fetch("run")
    abort("candidate assert must compare a recomputed digest to the supplied digest arg") unless
      body.match?(/sha256\([^)]*\)\.hexdigest\(\)\s*==\s*sys\.argv\[2\]/)
    abort("candidate assert must pass INDEX_PATH into the digest check") unless
      body.match?(/\x27\s+"\$INDEX_PATH"\s+"\$INDEX_DIGEST"/)
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

mut_restore_candidate_ref_checkout() {
  python3 - "$CANARY" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
if "candidate_ref:" in text:
    raise SystemExit("candidate_ref already present")
text = text.replace(
    "      expected_sha:",
    "      candidate_ref:\n        description: injected\n        required: false\n        default: \"\"\n      expected_sha:",
    1,
)
old = "        with:\n          persist-credentials: false\n"
new = (
    "        with:\n"
    "          repository: Rul1an/assay-action\n"
    "          ref: ${{ inputs.candidate_ref }}\n"
    "          path: candidate-action\n"
    "          persist-credentials: false\n"
)
# Inject into the candidate job checkout only (last persist-credentials checkout).
idx = text.rfind(old)
if idx < 0:
    raise SystemExit("standard checkout block not found")
p.write_text(text[:idx] + new + text[idx + len(old) :])
PY
}

mut_drop_tag_gate() {
  python3 - "$CANARY" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
old = "github.ref_type == 'tag'"
if old not in text:
    old = 'github.ref_type == "tag"'
if old not in text:
    raise SystemExit("tag gate not found")
p.write_text(text.replace(old, "true", 1))
PY
}

mut_candidate_uses_v3() {
  python3 - "$CANARY" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
if "uses: ./" not in text.split("assay-action-candidate", 1)[-1]:
    raise SystemExit("uses: ./ missing from candidate job")
# Replace only the candidate-job local uses.
head, tail = text.split("assay-action-candidate", 1)
tail = tail.replace("uses: ./", "uses: Rul1an/assay-action@v3", 1)
p.write_text(head + "assay-action-candidate" + tail)
PY
}

mut_drop_sha_bind() {
  python3 - "$CANARY" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
if "rev-parse HEAD" not in text:
    raise SystemExit("sha bind missing")
p.write_text(text.replace("rev-parse HEAD", "rev-list --max-count=1 HEAD", 1))
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

mut_bind_after_run() {
  python3 - "$CANARY" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
marker = "  assay-action-candidate:"
idx = text.find(marker)
if idx < 0:
    raise SystemExit("candidate job missing")
head, tail = text[:idx], text[idx:]
bind = "      - name: Bind dispatch tag and SHA\n"
run = "      - name: Run immutable candidate action\n"
b = tail.find(bind)
r = tail.find(run)
if b < 0 or r < 0 or b > r:
    raise SystemExit("bind/run order not found")
# Move the bind step block to after the run step's `with:` block ends
# at the next step named Assert.
assert_at = tail.find("      - name: Assert candidate evidence outputs\n")
if assert_at < 0:
    raise SystemExit("assert step missing")
bind_block = tail[b:r]
without_bind = tail[:b] + tail[r:assert_at]
p.write_text(head + without_bind + bind_block + tail[assert_at:])
PY
}

mut_echo_instead_of_sha_compare() {
  python3 - "$CANARY" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
old = '          test "$actual" = "$EXPECTED_SHA"'
if old not in text:
    raise SystemExit("sha compare missing")
p.write_text(text.replace(old, '          echo "$actual"', 1))
PY
}

mut_digest_mention_only() {
  python3 - "$CANARY" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
old = "          assert hashlib.sha256(raw).hexdigest() == sys.argv[2]"
if old not in text:
    raise SystemExit("digest equality missing")
p.write_text(text.replace(old, "          hashlib.sha256  # mention only", 1))
PY
}

mut_hardcode_index_path() {
  python3 - "$CANARY" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
old = """          ' "$INDEX_PATH" "$INDEX_DIGEST"
"""
if old not in text:
    raise SystemExit("INDEX_PATH consume missing")
p.write_text(
    text.replace(
        old,
        '          \' ".assay-reports/evidence-index.json" "$INDEX_DIGEST"\n',
        1,
    )
)
PY
}

main() {
  TMP_DIR="$(mktemp -d)"
  trap 'cp -f "$TMP_DIR/canary.yml.bak" "$CANARY" 2>/dev/null || true; rm -rf "$TMP_DIR"' EXIT
  cp "$CANARY" "$TMP_DIR/canary.yml.bak"

  if ! assert_canary_contract "$CANARY"; then
    fail "published-tag-canary.yml immutable candidate contract"
  else
    pass "published-tag-canary.yml pins a tag-gated local candidate job"
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
    mutate_expect_fail "restore-candidate-ref-checkout" mut_restore_candidate_ref_checkout
    mutate_expect_fail "drop-tag-gate" mut_drop_tag_gate
    mutate_expect_fail "candidate-uses-floating-v3" mut_candidate_uses_v3
    mutate_expect_fail "drop-sha-bind" mut_drop_sha_bind
    mutate_expect_fail "drop-output-asserts" mut_drop_output_asserts
    mutate_expect_fail "bind-after-run" mut_bind_after_run
    mutate_expect_fail "echo-instead-of-sha-compare" mut_echo_instead_of_sha_compare
    mutate_expect_fail "digest-mention-only" mut_digest_mention_only
    mutate_expect_fail "hardcode-index-path" mut_hardcode_index_path
  fi

  echo "published-tag canary contract passed"
}

main "$@"
