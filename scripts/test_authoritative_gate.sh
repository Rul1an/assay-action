#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$REPO_ROOT/scripts/apply_fail_on.sh"
ACTION="$REPO_ROOT/action.yml"
failed=0

fail() {
  echo "FAIL: $*" >&2
  failed=$((failed + 1))
}

pass() {
  echo "PASS: $*"
}

expect_status() {
  local label="$1"
  local want="$2"
  shift 2
  local got=0
  "$@" >/tmp/assay-gate-out 2>/tmp/assay-gate-err || got=$?
  if [[ "$got" -ne "$want" ]]; then
    fail "$label (exit $got, want $want)"
    sed -n '1,8p' /tmp/assay-gate-err >&2 || true
    return
  fi
  pass "$label"
}

if [[ ! -x "$HELPER" ]]; then
  fail "scripts/apply_fail_on.sh must exist and be executable"
else
  expect_status "unknown fail_on fail-closed" 1 "$HELPER" "eror" 0 0 0
  expect_status "empty fail_on fail-closed" 1 "$HELPER" "" 0 0 0
  expect_status "warning alias is clean with no findings" 0 "$HELPER" "warning" 0 0 0
  expect_status "warning alias fails on warnings" 1 "$HELPER" "warning" 0 1 0
  expect_status "warn fails on warnings" 1 "$HELPER" "warn" 0 1 0
  expect_status "error ignores warnings" 0 "$HELPER" "error" 0 3 0
  expect_status "error fails on errors" 1 "$HELPER" "error" 1 0 0
  expect_status "info fails on info" 1 "$HELPER" "info" 0 0 1
  expect_status "none never fails on findings" 0 "$HELPER" "none" 9 9 9
  if "$HELPER" "eror" 0 0 0 >/tmp/assay-gate-out 2>/tmp/assay-gate-err; then
    fail "unknown fail_on must not exit 0"
  elif ! grep -q "unknown fail_on" /tmp/assay-gate-err /tmp/assay-gate-out; then
    fail "unknown fail_on must name the bad value"
  else
    pass "unknown fail_on names the bad value"
  fi
fi

if python3 - "$ACTION" <<'PY'
import sys
import yaml

action = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
steps = action["runs"]["steps"]
by_id = {}
for step in steps:
    sid = step.get("id")
    if not sid:
        continue
    if sid in by_id:
        raise SystemExit(f"duplicate step id {sid}")
    by_id[sid] = step

check = by_id["check-existing"]
env = check["env"]
if "GITHUB_TOKEN" in env:
    raise SystemExit("version-resolution step still exposes GITHUB_TOKEN")
if env != {"ASSAY_VERSION_INPUT": "${{ inputs.version }}"}:
    raise SystemExit("version-resolution lost ASSAY_VERSION_INPUT")

process = by_id["process"]
if '"$GITHUB_ACTION_PATH/scripts/apply_fail_on.sh"' not in process["run"]:
    raise SystemExit("bundle gate must call scripts/apply_fail_on.sh")
if 'case "$FAIL_ON"' in process["run"]:
    raise SystemExit("bundle gate still has a local fail_on case")

pack = by_id["pack-lint"]
if pack["env"].get("FAIL_ON") != "${{ inputs.fail_on }}":
    raise SystemExit("pack-lint must receive FAIL_ON")
if '"$GITHUB_ACTION_PATH/scripts/apply_fail_on.sh"' not in pack["run"]:
    raise SystemExit("pack-lint must call scripts/apply_fail_on.sh")
if "--fail-on none" not in pack["run"]:
    raise SystemExit("pack-lint must keep --fail-on none for load/config isolation")

install = next((s for s in steps if s.get("name") == "Install Assay CLI"), None)
if install is None:
    raise SystemExit("missing Install Assay CLI step")
run = install["run"]
for needle in ("--retry 3", "--retry-delay 2", "--retry-all-errors", "User-Agent: assay-action-installer"):
    if needle not in run:
        raise SystemExit(f"archive download lost {needle}")
curl_uses = run.count('curl "${CURL_ARGS[@]}"')
if curl_uses != 2:
    raise SystemExit(f"expected both archive downloads to use CURL_ARGS, found {curl_uses}")
PY
then
  pass "action.yml token, helper, pack, and curl wiring"
else
  fail "action.yml token, helper, pack, or curl wiring"
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
