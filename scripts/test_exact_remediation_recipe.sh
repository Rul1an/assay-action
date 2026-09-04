#!/usr/bin/env bash
# Focused #44/#46: execute the exact bytes selected by action.yml's recipe load.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="$REPO_ROOT/action.yml"
README="$REPO_ROOT/README.md"
CANONICAL_REL="scripts/remediation_recipe.cmd"

die() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# Resolve the recipe path(s) actually cat'd by action.yml (production emission).
mapfile -t LOADED < <(
  grep -oE '\$GITHUB_ACTION_PATH/(scripts/[^"[:space:]]+)' "$ACTION" \
    | sed 's|^\$GITHUB_ACTION_PATH/||' \
    | sort -u
) || true
# Prefer lines that load remediation recipe specifically
mapfile -t RECIPE_LOADS < <(
  grep -E 'cat "\$GITHUB_ACTION_PATH/scripts/[^"]+"' "$ACTION" \
    | grep -E 'remediation|recipe' \
    | sed -n 's/.*cat "\$GITHUB_ACTION_PATH\/\([^"]*\)".*/\1/p' \
    | sort -u
) || true
if [[ "${#RECIPE_LOADS[@]}" -eq 0 ]]; then
  # fallback: any cat under scripts/*.cmd from action
  mapfile -t RECIPE_LOADS < <(
    grep -oE 'cat "\$GITHUB_ACTION_PATH/scripts/[^"]+\.cmd"' "$ACTION" \
      | sed -n 's/.*\$GITHUB_ACTION_PATH\/\(.*\)"/\1/p' \
      | sort -u
  ) || true
fi
[[ "${#RECIPE_LOADS[@]}" -ge 1 ]] || die "action.yml does not cat a scripts/*.cmd recipe path"
[[ "${#RECIPE_LOADS[@]}" -eq 1 ]] || die "action.yml loads multiple recipe paths: ${RECIPE_LOADS[*]}"
LOADED_REL="${RECIPE_LOADS[0]}"
[[ "$LOADED_REL" == "$CANONICAL_REL" ]] || die "action.yml loads '$LOADED_REL' but canonical is '$CANONICAL_REL' (one representation)"

RECIPE_FILE="$REPO_ROOT/$LOADED_REL"
[[ -f "$RECIPE_FILE" ]] || die "missing loaded recipe file $LOADED_REL"
RECIPE="$(cat "$RECIPE_FILE")"
[[ -n "$RECIPE" ]] || die "loaded recipe empty"
[[ "$RECIPE" != *$'\n'* ]] || die "loaded recipe must be one line"

# Decoy-resistant: the cat target must appear on a cat line, not only in a comment.
grep -E "cat \"\\\$GITHUB_ACTION_PATH/${LOADED_REL//\//\\/}\"" "$ACTION" >/dev/null \
  || die "action.yml lacks a real cat of $LOADED_REL"

grep -Fq -- "$RECIPE" "$README" || die "README.md does not embed the action-selected recipe bytes"
if grep -Fq -- "$RECIPE" "$ACTION"; then
  die "action.yml still hand-syncs the recipe literal; load $LOADED_REL only"
fi
# No second multi-line hand-synced recipe in README
if grep -n -- '--bundle .assay/evidence/nested/sandbox.tar.gz \\' "$README" >/dev/null 2>&1; then
  die "README still has a second multi-line executable recipe literal"
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
pass "action-selected recipe executes and produces bounded artifact"

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

mut_action="$TMP/action-noop.yml"
cp "$ACTION" "$mut_action"
printf '\n# noop comment for #46 control\n' >>"$mut_action"
grep -E "cat \"\\\$GITHUB_ACTION_PATH/${LOADED_REL//\//\\/}\"" "$mut_action" >/dev/null \
  || die "noop comment lost real cat of $LOADED_REL"
[[ "$(cat "$RECIPE_FILE")" == "$RECIPE" ]] || die "noop path mutated recipe bytes"
( cd "$(mktemp -d "$TMP/work.XXXXXX")" && PATH="$TMP/bin:$PATH" bash -c "$RECIPE" )
pass "noop/comment control keeps action-selected recipe bytes and exec green"

echo "exact remediation recipe contract passed"
