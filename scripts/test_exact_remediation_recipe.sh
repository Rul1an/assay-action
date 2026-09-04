#!/usr/bin/env bash
# Focused #44 contract: exact public remediation recipe bytes are executed.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECIPE_FILE="$REPO_ROOT/scripts/remediation_recipe.cmd"
ACTION="$REPO_ROOT/action.yml"
README="$REPO_ROOT/README.md"

die() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[[ -f "$RECIPE_FILE" ]] || die "missing canonical recipe $RECIPE_FILE"
RECIPE="$(cat "$RECIPE_FILE")"
[[ -n "$RECIPE" ]] || die "canonical recipe empty"
[[ "$RECIPE" != *$'\n'* ]] || die "canonical recipe must be one line"

# action.yml must load the canonical file (single source); README embeds the bytes.
grep -Fq 'remediation_recipe.cmd' "$ACTION" || die "action.yml must read scripts/remediation_recipe.cmd"
grep -Fq -- "$RECIPE" "$README" || die "README.md does not embed the canonical recipe bytes"
# action must not keep a second hand-synced paste of the recipe one-liner.
if grep -Fq -- "$RECIPE" "$ACTION"; then
  die "action.yml still contains a hand-synced recipe paste; load remediation_recipe.cmd only"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat >"$TMP/bin/assay" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
for a in "$@"; do
  if [[ "$a" == --no-such-flag ]]; then
    echo "error: unexpected argument '--no-such-flag'" >&2
    exit 2
  fi
done
if [[ "${1:-}" != "sandbox" ]]; then
  echo "error: unknown subcommand '${1:-}'" >&2
  exit 2
fi
bundle=""; prev=""; saw_dd=0; cmd=""
for a in "$@"; do
  if [[ "$prev" == "--bundle" ]]; then bundle="$a"; fi
  if [[ "$a" == "--" ]]; then saw_dd=1; prev="$a"; continue; fi
  if [[ "$saw_dd" -eq 1 && -z "$cmd" ]]; then cmd="$a"; fi
  prev="$a"
done
[[ -n "$bundle" ]] || { echo "error: missing --bundle" >&2; exit 2; }
[[ "$saw_dd" -eq 1 && -n "$cmd" ]] || { echo "error: missing command after --" >&2; exit 2; }
mkdir -p "$(dirname "$bundle")"
: >"$bundle"
SH
chmod +x "$TMP/bin/assay"

work=$(mktemp -d "$TMP/work.XXXXXX")
( cd "$work" && PATH="$TMP/bin:$PATH" bash -c "$RECIPE" )
[[ -f "$work/.assay/evidence/nested/sandbox.tar.gz" ]] || die "valid recipe did not produce nested bundle"
pass "exact canonical recipe executes and produces bounded artifact"

set +e
out=$(cd "$(mktemp -d "$TMP/work.XXXXXX")" && PATH="$TMP/bin:$PATH" bash -c "$RECIPE --no-such-flag" 2>&1)
rc=$?
set -e
[[ "$rc" -ne 0 ]] || die "appended --no-such-flag stayed green"
[[ "$out" == *"--no-such-flag"* ]] || die "expected CLI error mentioning --no-such-flag"
pass "appended --no-such-flag fails"

trunc="${RECIPE% -- true}"
[[ "$trunc" != "$RECIPE" ]] || die "truncation setup failed"
set +e
( cd "$(mktemp -d "$TMP/work.XXXXXX")" && PATH="$TMP/bin:$PATH" bash -c "$trunc" ) >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] || die "truncated recipe stayed green"
pass "truncated recipe fails"

changed="${RECIPE/assay sandbox/assay run}"
[[ "$changed" != "$RECIPE" ]] || die "subcommand mutation setup failed"
set +e
( cd "$(mktemp -d "$TMP/work.XXXXXX")" && PATH="$TMP/bin:$PATH" bash -c "$changed" ) >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] || die "changed subcommand stayed green"
pass "changed subcommand fails"

# No-op/comment control: comment-only edit must not change executed recipe bytes.
mut_action="$TMP/action-noop.yml"
cp "$ACTION" "$mut_action"
printf '\n# noop comment for #44 control\n' >>"$mut_action"
grep -Fq 'remediation_recipe.cmd' "$mut_action" || die "noop comment lost canonical recipe load"
[[ "$(cat "$RECIPE_FILE")" == "$RECIPE" ]] || die "noop path mutated canonical recipe bytes"
( cd "$(mktemp -d "$TMP/work.XXXXXX")" && PATH="$TMP/bin:$PATH" bash -c "$RECIPE" )
pass "noop/comment control keeps canonical recipe bytes and exec green"

# Must-bite structural: docs cannot keep a second multi-line hand-synced recipe
# distinct from the canonical one-liner (checked via README containing only one-liner form)
if grep -n -- '--bundle .assay/evidence/nested/sandbox.tar.gz \\' "$README" >/dev/null 2>&1; then
  die "README still has a second multi-line executable recipe literal"
fi
pass "README has no second multi-line executable recipe literal"

echo "exact remediation recipe contract passed"
