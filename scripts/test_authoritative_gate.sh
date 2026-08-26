#!/usr/bin/env bash
set -euo pipefail

# Dependency-free: no python, ruby, or YAML parser. Structural YAML lives in
# scripts/test_release_install_contract.sh (existing ruby -ryaml).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="$REPO_ROOT/action.yml"
failed=0

fail() {
  echo "FAIL: $*" >&2
  failed=$((failed + 1))
}

pass() {
  echo "PASS: $*"
}

if [[ -e "$REPO_ROOT/scripts/apply_fail_on.sh" ]]; then
  fail "scripts/apply_fail_on.sh must not exist; the CLI owns fail_on"
else
  pass "no second fail_on vocabulary"
fi

# shellcheck disable=SC2016 # Literal Action source, not a shell expansion.
if grep -Fq -- 'case "$FAIL_ON"' "$ACTION"; then
  fail "bundle gate still has a local fail_on case"
else
  pass "no local fail_on case"
fi

# shellcheck disable=SC2016 # Literal Action source, not a shell expansion.
if grep -Fq -- '--fail-on "$FAIL_ON"' "$ACTION"; then
  pass "CLI --fail-on forward is present"
else
  fail "bundle/pack lint must forward --fail-on to the CLI"
fi

if grep -Fq -- 'GATE_HITS' "$ACTION" && grep -Fq -- 'PACK_GATE_HITS' "$ACTION"; then
  pass "CLI gate hits are collected"
else
  fail "CLI gate hits must be collected for bundle and pack"
fi

if grep -Fq -- 'Could not apply fail_on=' "$ACTION"; then
  pass "unrecognized fail_on fails closed"
else
  fail "unrecognized fail_on must fail closed"
fi

# shellcheck disable=SC2016 # Literal Action source, not a shell expansion.
if grep -Fq -- 'GITHUB_TOKEN: ${{ github.token }}' "$ACTION"; then
  fail "version-resolution still exposes GITHUB_TOKEN"
else
  pass "version-resolution does not expose GITHUB_TOKEN"
fi

if grep -Fq -- '--retry-all-errors' "$ACTION" &&
  grep -Fq -- 'User-Agent: assay-action-installer' "$ACTION"; then
  pass "archive downloads keep retry-all-errors and User-Agent"
else
  fail "archive downloads lost retry-all-errors or User-Agent"
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/curl" <<'SH'
#!/usr/bin/env bash
if [[ " $* " == *" Authorization: "* ]]; then
  echo "unauthenticated latest lookup sent an Authorization header" >&2
  exit 91
fi
printf '{"tag_name":"v3.35.0"}\n'
SH
cat >"$TMP_DIR/bin/assay" <<'SH'
#!/usr/bin/env bash
printf 'assay 3.35.0\n'
SH
chmod +x "$TMP_DIR/bin/curl" "$TMP_DIR/bin/assay"
env -u GITHUB_TOKEN \
  GITHUB_OUTPUT="$TMP_DIR/latest.out" \
  PATH="$TMP_DIR/bin:$PATH" \
  bash "$REPO_ROOT/resolve-version.sh" latest
if ! grep -Fqx -- "resolved_version=v3.35.0" "$TMP_DIR/latest.out"; then
  fail "latest resolution without GITHUB_TOKEN lost the tag"
elif ! grep -Fqx -- "skip_install=true" "$TMP_DIR/latest.out"; then
  fail "latest resolution without GITHUB_TOKEN did not reuse the installed binary"
else
  pass "latest resolution works without GITHUB_TOKEN"
fi

if [[ "$failed" -ne 0 ]]; then
  echo "$failed authoritative-gate check(s) failed" >&2
  exit 1
fi
echo "authoritative gate contract passed"
