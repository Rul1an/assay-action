#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

require_output() {
  local file="$1"
  local expected="$2"
  if ! grep -Fqx -- "$expected" "$file"; then
    echo "$file must contain exactly: $expected" >&2
    exit 1
  fi
}

mkdir -p "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/curl" <<'SH'
#!/usr/bin/env bash
if [[ -n "${EXPECTED_AUTH_HEADER:-}" ]] &&
  [[ " $* " != *" -H ${EXPECTED_AUTH_HEADER} "* ]]; then
  echo "authenticated release lookup omitted the expected Authorization header" >&2
  exit 91
fi
printf '{"tag_name":"%s"}\n' "${FAKE_TAG:?}"
SH
cat >"$TMP_DIR/bin/assay" <<'SH'
#!/usr/bin/env bash
if [[ -n "${FAKE_CAPTURE_TOKEN_FILE:-}" ]]; then
  printf '%s' "${GITHUB_TOKEN:-}" >"$FAKE_CAPTURE_TOKEN_FILE"
fi
if [[ "${FAKE_MUTATE_ACTION_STATE:-0}" == "1" ]]; then
  [[ -z "${GITHUB_OUTPUT:-}" ]] ||
    printf 'resolved_version=v1\nresolved_version_plain=1.1.0\n' >>"$GITHUB_OUTPUT"
  [[ -z "${GITHUB_PATH:-}" ]] || printf '/tmp/untrusted\n' >>"$GITHUB_PATH"
  [[ -z "${GITHUB_ENV:-}" ]] || printf 'ASSAY_UNTRUSTED=1\n' >>"$GITHUB_ENV"
  [[ -z "${GITHUB_STATE:-}" ]] || printf 'assay_untrusted=1\n' >>"$GITHUB_STATE"
  [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || printf 'untrusted summary\n' >>"$GITHUB_STEP_SUMMARY"
fi
[[ -z "${FAKE_INVOCATION_COUNTER:-}" ]] || printf '1\n' >>"$FAKE_INVOCATION_COUNTER"
printf 'assay %s\n' "${FAKE_ASSAY_VERSION:-3.35.0}"
exit "${FAKE_ASSAY_EXIT:-0}"
SH
cat >"$TMP_DIR/bin/uname" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "-s" && -n "${FAKE_UNAME_S:-}" ]]; then
  printf '%s\n' "$FAKE_UNAME_S"
else
  /usr/bin/uname "$@"
fi
SH
chmod +x "$TMP_DIR/bin/curl" "$TMP_DIR/bin/assay" "$TMP_DIR/bin/uname"

FAKE_TAG="privileged-mcp-action-v0-candidate.2"
if FAKE_TAG="$FAKE_TAG" GITHUB_OUTPUT="$TMP_DIR/candidate.out" \
  PATH="$TMP_DIR/bin:$PATH" \
  bash "$REPO_ROOT/resolve-version.sh" latest >"$TMP_DIR/candidate.log" 2>&1
then
  echo "latest accepted a non-software release tag" >&2
  exit 1
fi
require_output "$TMP_DIR/candidate.log" \
  "::error::latest Assay release is not a stable software tag: $FAKE_TAG"

FAKE_TAG="v3.35.0" FAKE_ASSAY_VERSION="3.35.0" \
  GITHUB_TOKEN="release-lookup-token" \
  EXPECTED_AUTH_HEADER="Authorization: Bearer release-lookup-token" \
  GITHUB_OUTPUT="$TMP_DIR/latest.out" PATH="$TMP_DIR/bin:$PATH" \
  bash "$REPO_ROOT/resolve-version.sh" latest
require_output "$TMP_DIR/latest.out" "resolved_version=v3.35.0"
require_output "$TMP_DIR/latest.out" "resolved_version_plain=3.35.0"
require_output "$TMP_DIR/latest.out" "skip_install=true"

for state_file in output path env state summary; do
  : >"$TMP_DIR/child-$state_file.out"
done
: >"$TMP_DIR/child-invocations.out"
: >"$TMP_DIR/child-token.out"
FAKE_MUTATE_ACTION_STATE=1 FAKE_ASSAY_VERSION="3.35.0" \
  FAKE_INVOCATION_COUNTER="$TMP_DIR/child-invocations.out" \
  FAKE_CAPTURE_TOKEN_FILE="$TMP_DIR/child-token.out" \
  GITHUB_TOKEN="must-not-reach-inspected-binary" \
  GITHUB_OUTPUT="$TMP_DIR/child-output.out" \
  GITHUB_PATH="$TMP_DIR/child-path.out" \
  GITHUB_ENV="$TMP_DIR/child-env.out" \
  GITHUB_STATE="$TMP_DIR/child-state.out" \
  GITHUB_STEP_SUMMARY="$TMP_DIR/child-summary.out" \
  PATH="$TMP_DIR/bin:$PATH" \
  bash "$REPO_ROOT/resolve-version.sh" "v3.35.0"
require_output "$TMP_DIR/child-output.out" "resolved_version=v3.35.0"
require_output "$TMP_DIR/child-output.out" "resolved_version_plain=3.35.0"
require_output "$TMP_DIR/child-output.out" "skip_install=true"
if grep -Fqx -- "resolved_version=v1" "$TMP_DIR/child-output.out"; then
  echo "pre-existing binary mutated GITHUB_OUTPUT directly" >&2
  exit 1
fi
for state_file in path env state summary; do
  if [[ -s "$TMP_DIR/child-$state_file.out" ]]; then
    echo "pre-existing binary mutated GitHub Action state: $state_file" >&2
    exit 1
  fi
done
if [[ "$(wc -l <"$TMP_DIR/child-invocations.out" | tr -d ' ')" != "1" ]]; then
  echo "resolver invoked the inspected binary more than once" >&2
  exit 1
fi
if [[ -s "$TMP_DIR/child-token.out" ]]; then
  echo "resolver exposed GITHUB_TOKEN to the inspected binary" >&2
  exit 1
fi

: >"$TMP_DIR/failing-installed.out"
FAKE_ASSAY_VERSION="3.35.0" FAKE_ASSAY_EXIT=73 \
  GITHUB_OUTPUT="$TMP_DIR/failing-installed.out" PATH="$TMP_DIR/bin:$PATH" \
  bash "$REPO_ROOT/resolve-version.sh" "v3.35.0"
require_output "$TMP_DIR/failing-installed.out" "skip_install=false"

: >"$TMP_DIR/failing-verify.out"
: >"$TMP_DIR/failing-verify-path.out"
if FAKE_ASSAY_VERSION="3.35.0" FAKE_ASSAY_EXIT=73 \
  GITHUB_OUTPUT="$TMP_DIR/failing-verify.out" \
  GITHUB_PATH="$TMP_DIR/failing-verify-path.out" \
  bash "$REPO_ROOT/verify-install.sh" "$TMP_DIR/bin/assay" "3.35.0"
then
  echo "post-install verification accepted a failing binary" >&2
  exit 1
fi
if [[ -s "$TMP_DIR/failing-verify.out" || -s "$TMP_DIR/failing-verify-path.out" ]]; then
  echo "failing binary mutated verified installation outputs" >&2
  exit 1
fi

: >"$TMP_DIR/v2-darwin.out"
if FAKE_UNAME_S="Darwin" GITHUB_OUTPUT="$TMP_DIR/v2-darwin.out" \
  PATH="$TMP_DIR/bin:$PATH" \
  bash "$REPO_ROOT/resolve-version.sh" "v2" >"$TMP_DIR/v2-darwin.log" 2>&1
then
  echo "v2 was accepted on Darwin despite having no published macOS assets" >&2
  exit 1
fi
require_output "$TMP_DIR/v2-darwin.log" \
  "::error::Assay software alias v2 is Linux-only; use v2.1 or a newer release on macOS"

for CASE in "v1 1.1.0" "v2 2.12.0" "v2.1 2.1.0"; do
  read -r TAG BINARY_VERSION <<<"$CASE"
  FAKE_UNAME_S="Linux" FAKE_ASSAY_VERSION="$BINARY_VERSION" \
    GITHUB_OUTPUT="$TMP_DIR/${TAG}.out" \
    PATH="$TMP_DIR/bin:$PATH" \
    bash "$REPO_ROOT/resolve-version.sh" "$TAG"
  require_output "$TMP_DIR/${TAG}.out" "resolved_version=$TAG"
  require_output "$TMP_DIR/${TAG}.out" "resolved_version_plain=$BINARY_VERSION"
  require_output "$TMP_DIR/${TAG}.out" "skip_install=true"

  : >"$TMP_DIR/${TAG}-verify.out"
  : >"$TMP_DIR/${TAG}-path.out"
  FAKE_ASSAY_VERSION="$BINARY_VERSION" \
    GITHUB_OUTPUT="$TMP_DIR/${TAG}-verify.out" \
    GITHUB_PATH="$TMP_DIR/${TAG}-path.out" \
    bash "$REPO_ROOT/verify-install.sh" "$TMP_DIR/bin/assay" "$BINARY_VERSION"
  require_output "$TMP_DIR/${TAG}-verify.out" "installed=true"
done

: >"$TMP_DIR/verify-success.out"
: >"$TMP_DIR/verify-success-path.out"
: >"$TMP_DIR/verify-success-invocations.out"
FAKE_ASSAY_VERSION="3.35.0" \
  FAKE_INVOCATION_COUNTER="$TMP_DIR/verify-success-invocations.out" \
  GITHUB_OUTPUT="$TMP_DIR/verify-success.out" \
  GITHUB_PATH="$TMP_DIR/verify-success-path.out" \
  bash "$REPO_ROOT/verify-install.sh" "$TMP_DIR/bin/assay" "3.35.0"
require_output "$TMP_DIR/verify-success.out" "installed=true"
if [[ "$(wc -l <"$TMP_DIR/verify-success-invocations.out" | tr -d ' ')" != "1" ]]; then
  echo "successful verifier invoked the inspected binary more than once" >&2
  exit 1
fi

FAKE_ASSAY_VERSION="3.36.0-rc.1" GITHUB_OUTPUT="$TMP_DIR/prerelease.out" \
  PATH="$TMP_DIR/bin:$PATH" \
  bash "$REPO_ROOT/resolve-version.sh" "3.36.0-rc.1"
require_output "$TMP_DIR/prerelease.out" "resolved_version=v3.36.0-rc.1"
require_output "$TMP_DIR/prerelease.out" "resolved_version_plain=3.36.0-rc.1"

for INJECTED in $'3.35.0\nskip_install=true' $'3.35.0\rskip_install=true'; do
  : >"$TMP_DIR/injected.out"
  if GITHUB_OUTPUT="$TMP_DIR/injected.out" PATH="$TMP_DIR/bin:$PATH" \
    bash "$REPO_ROOT/resolve-version.sh" "$INJECTED" \
    >"$TMP_DIR/injected.log" 2>&1
  then
    echo "version input containing a line break was accepted" >&2
    exit 1
  fi
  if [[ -s "$TMP_DIR/injected.out" ]]; then
    echo "outputs were written before rejecting a line break" >&2
    exit 1
  fi
done

for state_file in output path env state summary; do
  : >"$TMP_DIR/mismatch-$state_file.out"
done
: >"$TMP_DIR/mismatch-invocations.out"
if FAKE_MUTATE_ACTION_STATE=1 FAKE_ASSAY_VERSION="2.1.0" \
  FAKE_INVOCATION_COUNTER="$TMP_DIR/mismatch-invocations.out" \
  GITHUB_OUTPUT="$TMP_DIR/mismatch-output.out" \
  GITHUB_PATH="$TMP_DIR/mismatch-path.out" \
  GITHUB_ENV="$TMP_DIR/mismatch-env.out" \
  GITHUB_STATE="$TMP_DIR/mismatch-state.out" \
  GITHUB_STEP_SUMMARY="$TMP_DIR/mismatch-summary.out" \
  bash "$REPO_ROOT/verify-install.sh" "$TMP_DIR/bin/assay" "2.1" \
  >"$TMP_DIR/mismatch.log" 2>&1
then
  echo "post-install verification accepted a version mismatch" >&2
  exit 1
fi
require_output "$TMP_DIR/mismatch.log" \
  "::error::Assay installation verification failed: expected 2.1, got 2.1.0"

MALFORMED_INSTALLED_VERSION=$'3.35.0\nx resolved_version=v1\nx resolved_version_plain=1.1.0'
: >"$TMP_DIR/malformed-installed.out"
FAKE_ASSAY_VERSION="$MALFORMED_INSTALLED_VERSION" \
  GITHUB_OUTPUT="$TMP_DIR/malformed-installed.out" \
  PATH="$TMP_DIR/bin:$PATH" \
  bash "$REPO_ROOT/resolve-version.sh" "v3.35.0" \
  >"$TMP_DIR/malformed-installed.log" 2>&1
require_output "$TMP_DIR/malformed-installed.out" "resolved_version=v3.35.0"
require_output "$TMP_DIR/malformed-installed.out" "resolved_version_plain=3.35.0"
require_output "$TMP_DIR/malformed-installed.out" "skip_install=false"
if grep -Fqx -- "resolved_version=v1" "$TMP_DIR/malformed-installed.out"; then
  echo "malformed installed-version output overwrote a validated output" >&2
  exit 1
fi
if grep -Fqx -- "resolved_version_plain=1.1.0" "$TMP_DIR/malformed-installed.out"; then
  echo "malformed installed-version output injected an output" >&2
  exit 1
fi
require_output "$TMP_DIR/malformed-installed.log" "Assay already installed: unknown"
for state_file in output path env state summary; do
  if [[ -s "$TMP_DIR/mismatch-$state_file.out" ]]; then
    echo "rejected binary mutated GitHub Action state: $state_file" >&2
    exit 1
  fi
done
if [[ "$(wc -l <"$TMP_DIR/mismatch-invocations.out" | tr -d ' ')" != "1" ]]; then
  echo "verifier invoked the inspected binary more than once" >&2
  exit 1
fi

assert_action_wiring() {
  local action_file="$1"
  # shellcheck disable=SC2016 # Ruby compares literal composite-action expressions.
  ruby -ryaml -e '
    action = YAML.safe_load_file(ARGV.fetch(0), aliases: true)
    steps = action.fetch("runs").fetch("steps")
    expected = {
      "check-existing" =>
        {
          "run" => %q{"$GITHUB_ACTION_PATH/resolve-version.sh" "$ASSAY_VERSION_INPUT"},
          "env" => {
            "ASSAY_VERSION_INPUT" => "${{ inputs.version }}",
            "GITHUB_TOKEN" => "${{ github.token }}",
          },
          "if" => nil,
        },
      "verify-install" =>
        {
          "run" =>
            %q{"$GITHUB_ACTION_PATH/verify-install.sh" "$HOME/.assay/bin/assay" "$EXPECTED_VERSION"},
          "env" => {
            "EXPECTED_VERSION" =>
              "${{ steps.check-existing.outputs.resolved_version_plain }}",
          },
          "if" => "steps.check-existing.outputs.skip_install != '\''true'\''",
        },
    }
    expected.each do |id, contract|
      matches = steps.select { |step| step["id"] == id }
      abort("expected exactly one #{id} step") unless matches.length == 1
      step = matches.first
      abort("#{id} step does not execute the required command") unless
        step.fetch("run").strip == contract.fetch("run")
      abort("#{id} step has incorrect environment wiring") unless
        step.fetch("env") == contract.fetch("env")
      abort("#{id} step has incorrect execution guard") unless
        step["if"] == contract.fetch("if")
    end
  ' "$action_file"
}

assert_action_wiring "$REPO_ROOT/action.yml"
cp "$REPO_ROOT/action.yml" "$TMP_DIR/action-mutated.yml"
# shellcheck disable=SC2016 # Mutate the literal command for the negative wiring test.
sed -i.bak \
  's|^[[:space:]]*"$GITHUB_ACTION_PATH/verify-install.sh".*$|        true|' \
  "$TMP_DIR/action-mutated.yml"
# Preserve the exact command elsewhere; only structural step placement counts.
# shellcheck disable=SC2016 # Inject the literal command into non-executable YAML text.
printf '\n# "$GITHUB_ACTION_PATH/verify-install.sh" "$HOME/.assay/bin/assay" "$EXPECTED_VERSION"\n' \
  >>"$TMP_DIR/action-mutated.yml"
if assert_action_wiring "$TMP_DIR/action-mutated.yml"; then
  echo "action wiring accepted a non-executing verification placeholder" >&2
  exit 1
fi

for env_key in ASSAY_VERSION_INPUT GITHUB_TOKEN EXPECTED_VERSION; do
  cp "$REPO_ROOT/action.yml" "$TMP_DIR/action-env-mutated.yml"
  sed -i.bak "s/^        ${env_key}:/        ${env_key}_MISSING:/" \
    "$TMP_DIR/action-env-mutated.yml"
  if assert_action_wiring "$TMP_DIR/action-env-mutated.yml"; then
    echo "action wiring accepted a mutated ${env_key} boundary" >&2
    exit 1
  fi
done

cp "$REPO_ROOT/action.yml" "$TMP_DIR/action-if-mutated.yml"
sed -i.bak \
  "s/^      if: steps.check-existing.outputs.skip_install != 'true'$/      if: always()/" \
  "$TMP_DIR/action-if-mutated.yml"
if assert_action_wiring "$TMP_DIR/action-if-mutated.yml"; then
  echo "action wiring accepted a mutated verification guard" >&2
  exit 1
fi

cp "$REPO_ROOT/action.yml" "$TMP_DIR/action-resolver-if-mutated.yml"
sed -i.bak '/id: check-existing/a\
      if: false
' "$TMP_DIR/action-resolver-if-mutated.yml"
if assert_action_wiring "$TMP_DIR/action-resolver-if-mutated.yml"; then
  echo "action wiring accepted a conditional version resolver" >&2
  exit 1
fi

echo "release install contract passed"
