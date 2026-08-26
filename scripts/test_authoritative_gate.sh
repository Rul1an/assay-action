#!/usr/bin/env bash
set -euo pipefail

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
run = process["run"]
if 'case "$FAIL_ON"' in run:
    raise SystemExit("bundle gate still has a local fail_on case")
if '--fail-on "$FAIL_ON"' not in run:
    raise SystemExit("bundle lint must forward --fail-on \"$FAIL_ON\" to the CLI")
if "GATE_HITS" not in run:
    raise SystemExit("bundle lint must collect CLI gate hits")
if "exit 2" not in run or "Could not apply fail_on=" not in run:
    raise SystemExit("unrecognized fail_on must fail closed (Action exit 2)")
if "apply_fail_on.sh" in run:
    raise SystemExit("bundle gate must not call apply_fail_on.sh")

desc = action["inputs"]["fail_on"]["description"]
if "warning" not in desc:
    raise SystemExit("fail_on description must name the warning alias")
if action["inputs"]["fail_on"]["default"] != "error":
    raise SystemExit("fail_on default changed")

pack = by_id["pack-lint"]
if pack["env"].get("FAIL_ON") != "${{ inputs.fail_on }}":
    raise SystemExit("pack-lint must receive FAIL_ON")
pack_run = pack["run"]
if "--fail-on none" not in pack_run:
    raise SystemExit("pack-lint must keep --fail-on none for load/config isolation")
if '--fail-on "$FAIL_ON"' not in pack_run or "--pack" not in pack_run:
    raise SystemExit("pack-lint must second-pass --fail-on \"$FAIL_ON\" --pack to the CLI")
if "PACK_GATE_HITS" not in pack_run:
    raise SystemExit("pack-lint must collect CLI pack gate hits")
if "apply_fail_on.sh" in pack_run:
    raise SystemExit("pack gate must not call apply_fail_on.sh")
if 'select((.level // "warning")' in pack_run:
    raise SystemExit("pack gate must not count SARIF levels")

install = next((s for s in steps if s.get("name") == "Install Assay CLI"), None)
if install is None:
    raise SystemExit("missing Install Assay CLI step")
install_run = install["run"]
for needle in ("--retry 3", "--retry-delay 2", "--retry-all-errors", "User-Agent: assay-action-installer"):
    if needle not in install_run:
        raise SystemExit(f"archive download lost {needle}")
curl_uses = install_run.count('curl "${CURL_ARGS[@]}"')
if curl_uses != 2:
    raise SystemExit(f"expected both archive downloads to use CURL_ARGS, found {curl_uses}")
PY
then
  pass "action.yml CLI gate, token, pack, and curl wiring"
else
  fail "action.yml CLI gate, token, pack, or curl wiring"
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
