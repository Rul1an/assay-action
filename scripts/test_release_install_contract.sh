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
set -euo pipefail

if [[ -n "${FAKE_CURL_INVOCATION_COUNTER:-}" ]]; then
  printf '1\n' >>"$FAKE_CURL_INVOCATION_COUNTER"
fi
if [[ -n "${FAKE_CURL_RECORD:-}" ]]; then
  printf '%s\n' "$*" >>"$FAKE_CURL_RECORD"
fi

args=("$@")
for i in "${!args[@]}"; do
  if [[ "${args[$i]}" == "-H" ]]; then
    next="${args[$((i + 1))]:-}"
    if [[ "$next" == Authorization:* || "$next" == authorization:* ]]; then
      echo "latest lookup sent an Authorization header" >&2
      exit 91
    fi
  fi
  if [[ "${args[$i]}" == Authorization:* || "${args[$i]}" == authorization:* ]]; then
    echo "latest lookup sent an Authorization header" >&2
    exit 91
  fi
done

if [[ "${FAKE_CURL_NETWORK_FAIL:-0}" == "1" ]]; then
  echo "simulated network failure" >&2
  exit 56
fi

if [[ "${FAKE_CURL_ENFORCE_CONTRACT:-1}" == "1" ]]; then
  joined=" $* "
  if [[ "$joined" != *" --max-redirs 3 "* ]]; then
    echo "curl missing exact --max-redirs 3" >&2
    exit 92
  fi
  if [[ "$joined" == *" --location-trusted "* ]]; then
    echo "curl must not use --location-trusted" >&2
    exit 93
  fi

  has_location=0
  has_proto=0
  has_proto_redir=0
  has_output_null=0
  has_write_effective=0
  target=""
  i=0
  while [[ "$i" -lt "${#args[@]}" ]]; do
    arg="${args[$i]}"
    case "$arg" in
      -L|--location) has_location=1 ;;
      --proto)
        i=$((i + 1))
        if [[ "${args[$i]:-}" == "=https" ]]; then
          has_proto=1
        fi
        ;;
      --proto-redir)
        i=$((i + 1))
        if [[ "${args[$i]:-}" == "=https" ]]; then
          has_proto_redir=1
        fi
        ;;
      -o|--output)
        i=$((i + 1))
        if [[ "${args[$i]:-}" == "/dev/null" ]]; then
          has_output_null=1
        fi
        ;;
      -w|--write-out)
        i=$((i + 1))
        if [[ "${args[$i]:-}" == "%{url_effective}" ]]; then
          has_write_effective=1
        fi
        ;;
      -*)
        if [[ "$arg" != --* && "$arg" == *L* ]]; then
          has_location=1
        fi
        ;;
      *)
        target="$arg"
        ;;
    esac
    i=$((i + 1))
  done

  if [[ "$has_location" != "1" ]]; then
    echo "curl missing HTTPS redirect following (-L)" >&2
    exit 94
  fi
  if [[ "$has_proto" != "1" || "$has_proto_redir" != "1" ]]; then
    echo "curl missing HTTPS-only --proto/--proto-redir =https" >&2
    exit 95
  fi
  if [[ "$has_output_null" != "1" ]]; then
    echo "curl must discard the response body to /dev/null" >&2
    exit 96
  fi
  if [[ "$has_write_effective" != "1" ]]; then
    echo "curl must write %{url_effective}" >&2
    exit 97
  fi
  if [[ "$target" != "https://github.com/Rul1an/assay/releases/latest" ]]; then
    echo "curl target must be the public releases/latest URL, got: ${target:-<empty>}" >&2
    exit 98
  fi
  if [[ "$joined" == *" api.github.com"* ]]; then
    echo "curl must not use the GitHub REST API" >&2
    exit 99
  fi
fi

printf '%s' "${FAKE_EFFECTIVE_URL:?}"
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

assert_latest_fail_closed() {
  local name="$1"
  local url="$2"
  local out="$TMP_DIR/latest-fail-$name.out"
  local log="$TMP_DIR/latest-fail-$name.log"
  : >"$out"
  if FAKE_EFFECTIVE_URL="$url" \
    GITHUB_OUTPUT="$out" PATH="$TMP_DIR/bin:$PATH" \
    bash "$REPO_ROOT/resolve-version.sh" latest >"$log" 2>&1
  then
    echo "latest accepted fail-closed case: $name ($url)" >&2
    exit 1
  fi
  if [[ -s "$out" ]]; then
    echo "latest wrote outputs before failing closed: $name" >&2
    cat "$out" >&2
    exit 1
  fi
}

run_latest_redirect_contract() {
  local candidate_tag="privileged-mcp-action-v0-candidate.2"
  local candidate_url="https://github.com/Rul1an/assay/releases/tag/${candidate_tag}"
  : >"$TMP_DIR/candidate.out"
  if FAKE_EFFECTIVE_URL="$candidate_url" GITHUB_OUTPUT="$TMP_DIR/candidate.out" \
    PATH="$TMP_DIR/bin:$PATH" \
    bash "$REPO_ROOT/resolve-version.sh" latest >"$TMP_DIR/candidate.log" 2>&1
  then
    echo "latest accepted a non-software release tag" >&2
    exit 1
  fi
  require_output "$TMP_DIR/candidate.log" \
    "::error::latest Assay release is not a stable software tag: $candidate_tag"
  if [[ -s "$TMP_DIR/candidate.out" ]]; then
    echo "non-software latest wrote version outputs" >&2
    exit 1
  fi

  : >"$TMP_DIR/curl-invocations.out"
  : >"$TMP_DIR/latest.out"
  FAKE_EFFECTIVE_URL="https://github.com/Rul1an/assay/releases/tag/v3.35.0" \
    FAKE_ASSAY_VERSION="3.35.0" \
    FAKE_CURL_INVOCATION_COUNTER="$TMP_DIR/curl-invocations.out" \
    GITHUB_TOKEN="must-not-be-transmitted" \
    GITHUB_OUTPUT="$TMP_DIR/latest.out" PATH="$TMP_DIR/bin:$PATH" \
    bash "$REPO_ROOT/resolve-version.sh" latest
  require_output "$TMP_DIR/latest.out" "resolved_version=v3.35.0"
  require_output "$TMP_DIR/latest.out" "resolved_version_plain=3.35.0"
  require_output "$TMP_DIR/latest.out" "skip_install=true"
  if [[ "$(wc -l <"$TMP_DIR/curl-invocations.out" | tr -d ' ')" != "1" ]]; then
    echo "latest resolution did not perform exactly one public redirect lookup" >&2
    exit 1
  fi

  # Positive: resolved tag is the one compared for install skip/reinstall.
  : >"$TMP_DIR/curl-unrelated.out"
  : >"$TMP_DIR/latest-unrelated.out"
  FAKE_EFFECTIVE_URL="https://github.com/Rul1an/assay/releases/tag/v3.35.0" \
    FAKE_ASSAY_VERSION="1.1.0" \
    FAKE_CURL_INVOCATION_COUNTER="$TMP_DIR/curl-unrelated.out" \
    GITHUB_OUTPUT="$TMP_DIR/latest-unrelated.out" PATH="$TMP_DIR/bin:$PATH" \
    bash "$REPO_ROOT/resolve-version.sh" latest \
    >"$TMP_DIR/latest-unrelated.log" 2>&1
  require_output "$TMP_DIR/latest-unrelated.out" "resolved_version=v3.35.0"
  require_output "$TMP_DIR/latest-unrelated.out" "resolved_version_plain=3.35.0"
  require_output "$TMP_DIR/latest-unrelated.out" "skip_install=false"
  if [[ "$(wc -l <"$TMP_DIR/curl-unrelated.out" | tr -d ' ')" != "1" ]]; then
    echo "already-installed unrelated version skipped latest resolution" >&2
    exit 1
  fi
  if ! grep -Fq -- "requested v3.35.0" "$TMP_DIR/latest-unrelated.log"; then
    echo "resolver notice lost coherence with the resolved latest tag" >&2
    exit 1
  fi

  assert_latest_fail_closed stay-on-latest \
    "https://github.com/Rul1an/assay/releases/latest"
  assert_latest_fail_closed http-scheme \
    "http://github.com/Rul1an/assay/releases/tag/v3.35.0"
  assert_latest_fail_closed wrong-host \
    "https://evil.example/Rul1an/assay/releases/tag/v3.35.0"
  assert_latest_fail_closed wrong-owner \
    "https://github.com/other/assay/releases/tag/v3.35.0"
  assert_latest_fail_closed wrong-repo \
    "https://github.com/Rul1an/other/releases/tag/v3.35.0"
  assert_latest_fail_closed wrong-path \
    "https://github.com/Rul1an/assay/releases/download/v3.35.0"
  assert_latest_fail_closed query \
    "https://github.com/Rul1an/assay/releases/tag/v3.35.0?suffix=1"
  assert_latest_fail_closed fragment \
    "https://github.com/Rul1an/assay/releases/tag/v3.35.0#details"
  assert_latest_fail_closed prerelease \
    "https://github.com/Rul1an/assay/releases/tag/v3.35.0-rc.1"
  assert_latest_fail_closed empty-tag \
    "https://github.com/Rul1an/assay/releases/tag/"

  : >"$TMP_DIR/network-fail.out"
  if FAKE_CURL_NETWORK_FAIL=1 FAKE_EFFECTIVE_URL="https://github.com/Rul1an/assay/releases/tag/v3.35.0" \
    GITHUB_OUTPUT="$TMP_DIR/network-fail.out" PATH="$TMP_DIR/bin:$PATH" \
    bash "$REPO_ROOT/resolve-version.sh" latest >"$TMP_DIR/network-fail.log" 2>&1
  then
    echo "latest succeeded despite network failure" >&2
    exit 1
  fi
  if [[ -s "$TMP_DIR/network-fail.out" ]]; then
    echo "network failure wrote version outputs" >&2
    exit 1
  fi

  # Explicit versions stay networkless.
  : >"$TMP_DIR/explicit-curl.out"
  FAKE_CURL_INVOCATION_COUNTER="$TMP_DIR/explicit-curl.out" \
    FAKE_ASSAY_VERSION="3.35.0" \
    GITHUB_OUTPUT="$TMP_DIR/explicit.out" PATH="$TMP_DIR/bin:$PATH" \
    bash "$REPO_ROOT/resolve-version.sh" "v3.35.0"
  require_output "$TMP_DIR/explicit.out" "resolved_version=v3.35.0"
  if [[ -s "$TMP_DIR/explicit-curl.out" ]]; then
    echo "explicit version invoked the network resolver" >&2
    exit 1
  fi
}

run_latest_redirect_contract

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

assert_fail_on_gate() {
  local action_file="$1"
  # shellcheck disable=SC2016 # Ruby compares literal composite-action expressions.
  ruby -ryaml -e '
    action = YAML.safe_load_file(ARGV.fetch(0), aliases: true)
    steps = action.fetch("runs").fetch("steps")
    by_id = {}
    steps.each do |step|
      id = step["id"]
      next if id.nil?
      abort("duplicate step id #{id}") if by_id.key?(id)
      by_id[id] = step
    end

    check = by_id.fetch("check-existing")
    env = check.fetch("env")
    abort("version-resolution step still exposes GITHUB_TOKEN") if env.key?("GITHUB_TOKEN")
    abort("version-resolution lost ASSAY_VERSION_INPUT") unless
      env == { "ASSAY_VERSION_INPUT" => "${{ inputs.version }}" }

    process_run = by_id.fetch("process").fetch("run")
    abort("bundle gate still has a local fail_on case") if process_run.include?(%q{case "$FAIL_ON"})
    abort("bundle lint must forward --fail-on \"$FAIL_ON\" to the CLI") unless
      process_run.include?(%q{--fail-on "$FAIL_ON"})
    abort("bundle lint must collect CLI gate hits") unless process_run.include?("GATE_HITS")
    abort("unrecognized fail_on must fail closed (Action exit 2)") unless
      process_run.include?("exit 2") && process_run.include?("Could not apply fail_on=")
    abort("bundle gate must not call apply_fail_on.sh") if process_run.include?("apply_fail_on.sh")

    fail_on = action.fetch("inputs").fetch("fail_on")
    abort("fail_on description must name the warning alias") unless
      fail_on.fetch("description").include?("warning")
    abort("fail_on default changed") unless fail_on.fetch("default") == "error"

    pack = by_id.fetch("pack-lint")
    abort("pack-lint must receive FAIL_ON") unless
      pack.fetch("env")["FAIL_ON"] == "${{ inputs.fail_on }}"
    pack_run = pack.fetch("run")
    abort("pack-lint must keep --fail-on none for load/config isolation") unless
      pack_run.include?("--fail-on none")
    abort("pack-lint must second-pass --fail-on \"$FAIL_ON\" --pack to the CLI") unless
      pack_run.include?(%q{--fail-on "$FAIL_ON"}) && pack_run.include?("--pack")
    abort("pack-lint must collect CLI pack gate hits") unless pack_run.include?("PACK_GATE_HITS")
    abort("pack gate must not call apply_fail_on.sh") if pack_run.include?("apply_fail_on.sh")
    abort("pack gate must not count SARIF levels") if pack_run.include?(%q{select((.level // "warning")})

    install = steps.find { |step| step["name"] == "Install Assay CLI" }
    abort("missing Install Assay CLI step") if install.nil?
    install_run = install.fetch("run")
    %w[--retry\ 3 --retry-delay\ 2 --retry-all-errors User-Agent:\ assay-action-installer].each do |needle|
      abort("archive download lost #{needle}") unless install_run.include?(needle)
    end
    curl_uses = install_run.scan(/curl "\$\{CURL_ARGS\[@\]\}"/)
    abort("expected both archive downloads to use CURL_ARGS, found #{curl_uses.length}") unless
      curl_uses.length == 2
  ' "$action_file"
}

assert_action_wiring "$REPO_ROOT/action.yml"
assert_fail_on_gate "$REPO_ROOT/action.yml"
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

for env_key in ASSAY_VERSION_INPUT EXPECTED_VERSION; do
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

cp "$REPO_ROOT/action.yml" "$TMP_DIR/action-fail-on-mutated.yml"
# shellcheck disable=SC2016 # Drop the CLI-owned threshold so the negative test can see it.
sed -i.bak 's/--fail-on "\$FAIL_ON"//' "$TMP_DIR/action-fail-on-mutated.yml"
if assert_fail_on_gate "$TMP_DIR/action-fail-on-mutated.yml"; then
  echo "fail_on gate accepted a missing CLI --fail-on forward" >&2
  exit 1
fi

cp "$REPO_ROOT/action.yml" "$TMP_DIR/action-pack-gate-mutated.yml"
sed -i.bak '/PACK_GATE_HITS/d' "$TMP_DIR/action-pack-gate-mutated.yml"
if assert_fail_on_gate "$TMP_DIR/action-pack-gate-mutated.yml"; then
  echo "fail_on gate accepted a missing pack second pass" >&2
  exit 1
fi


# --- issue #42 latest-redirect mutation harness ---
RESOLVER="$REPO_ROOT/resolve-version.sh"
cp "$RESOLVER" "$TMP_DIR/resolve-version.sh.bak"
trap 'cp "$TMP_DIR/resolve-version.sh.bak" "$RESOLVER"; rm -rf "$TMP_DIR"' EXIT

restore_resolver() {
  cp "$TMP_DIR/resolve-version.sh.bak" "$RESOLVER"
}

mutate_expect_fail() {
  local name="$1"
  shift
  restore_resolver
  "$@"
  # Subshell: run_latest_redirect_contract uses exit 1 on failure.
  if (run_latest_redirect_contract) >"$TMP_DIR/mutation-$name.log" 2>&1; then
    restore_resolver
    echo "MUTATION DID NOT BITE: $name" >&2
    cat "$TMP_DIR/mutation-$name.log" >&2
    exit 1
  fi
  restore_resolver
  echo "MUTATION BIT: $name"
}

mut_restore_api_only() {
  python3 - "$RESOLVER" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
start = text.find('if [[ "$VERSION" == "latest" ]]; then')
end = text.find('\nfi\n\ncase "$VERSION" in', start)
if start < 0 or end < 0:
    raise SystemExit("latest block not found")
end = end + len("\nfi")
replacement = r'''if [[ "$VERSION" == "latest" ]]; then
  CURL_ARGS=(
    --retry 3
    --retry-delay 2
    --retry-all-errors
    -fsSL
    -H "Accept: application/vnd.github+json"
    -H "User-Agent: assay-action-installer"
  )
  VERSION=$(
    curl "${CURL_ARGS[@]}" \
      "https://api.github.com/repos/$REPO/releases/latest" |
      sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
      head -n 1
  )
  if [[ -z "$VERSION" ]]; then
    echo "::error::Failed to fetch latest Assay version"
    exit 1
  fi
  if [[ ! "$VERSION" =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]]; then
    echo "::error::latest Assay release is not a stable software tag: $VERSION"
    exit 1
  fi
fi'''
p.write_text(text[:start] + replacement + text[end:])
PY
}
mut_raise_redirect_budget() {
  python3 - "$RESOLVER" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
if "--max-redirs 3" not in text:
    raise SystemExit("max-redirs 3 not found")
p.write_text(text.replace("--max-redirs 3", "--max-redirs 30", 1))
PY
}
mut_remove_redirect_budget() {
  python3 - "$RESOLVER" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
if "--max-redirs 3" not in text:
    raise SystemExit("max-redirs 3 not found")
p.write_text(text.replace("    --max-redirs 3\n", "", 1))
PY
}
mut_allow_http_redir() {
  python3 - "$RESOLVER" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
old = "--proto-redir '=https'"
if old not in text:
    raise SystemExit("proto-redir https not found")
p.write_text(text.replace(old, "--proto-redir '=http,https'", 1))
PY
}
mut_add_location_trusted() {
  python3 - "$RESOLVER" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
old = "    -fsSL\n"
if old not in text:
    raise SystemExit("-fsSL not found")
p.write_text(text.replace(old, "    -fsSL\n    --location-trusted\n", 1))
PY
}
mut_accept_url_prefix() {
  python3 - "$RESOLVER" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
old = '[[ "$EFFECTIVE_URL" =~ ^https://github\\.com/Rul1an/assay/releases/tag/([^/?#]+)$ ]]'
if old not in text:
    raise SystemExit("exact effective-URL match not found")
new = '[[ "$EFFECTIVE_URL" == https://github.com/Rul1an/assay/releases/tag/* ]] && VERSION="${EFFECTIVE_URL##*/}"'
text = text.replace(old, new, 1)
text = text.replace('    VERSION="${BASH_REMATCH[1]}"\n', '', 1)
p.write_text(text)
PY
}
mut_accept_prerelease_or_empty() {
  python3 - "$RESOLVER" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
old = 'if [[ ! "$VERSION" =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]]; then'
if old not in text:
    raise SystemExit("stable tag guard not found")
p.write_text(text.replace(old, "if false; then", 1))
PY
}
mut_hardcoded_fallback() {
  python3 - "$RESOLVER" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
old = '''  if [[ -z "$VERSION" ]]; then
    echo "::error::Failed to fetch latest Assay version"
    exit 1
  fi'''
if old not in text:
    raise SystemExit("empty-version fail-closed block not found")
new = '''  if [[ -z "$VERSION" ]]; then
    VERSION="v3.35.0"
  fi'''
p.write_text(text.replace(old, new, 1))
PY
}
mut_add_authorization() {
  python3 - "$RESOLVER" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
needle = '    -H "User-Agent: assay-action-installer"\n  )'
if needle not in text:
    raise SystemExit("User-Agent array close not found")
addition = '''    -H "User-Agent: assay-action-installer"
  )
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    CURL_ARGS+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi'''
p.write_text(text.replace(needle, addition, 1))
PY
}
mut_log_other_version() {
  python3 - "$RESOLVER" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
old = 'echo "resolved_version=$VERSION" >>"$GITHUB_OUTPUT"'
if old not in text:
    raise SystemExit("resolved_version output not found")
p.write_text(text.replace(old, 'echo "resolved_version=v9.9.9" >>"$GITHUB_OUTPUT"', 1))
PY
}
mut_skip_resolution_when_installed() {
  python3 - "$RESOLVER" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
marker = 'if [[ "$VERSION" == "latest" ]]; then'
if marker not in text:
    raise SystemExit("latest marker not found")
inject = '''ASSAY_BIN_EARLY="$(type -P assay || true)"
if [[ "$VERSION" == "latest" && -n "$ASSAY_BIN_EARLY" && -x "$ASSAY_BIN_EARLY" ]]; then
  EARLY_OUT="$("$ASSAY_BIN_EARLY" --version 2>/dev/null || true)"
  if [[ "$EARLY_OUT" =~ ^assay[[:space:]]+([0-9A-Za-z.+-]+)$ ]]; then
    VERSION="v${BASH_REMATCH[1]}"
  fi
fi
'''
p.write_text(text.replace(marker, inject + marker, 1))
PY
}

if (run_latest_redirect_contract) >"$TMP_DIR/mutation-noop.log" 2>&1; then
  echo "MUTATION CONTROL: no-op stayed green"
else
  echo "no-op control failed" >&2
  cat "$TMP_DIR/mutation-noop.log" >&2
  exit 1
fi

mutate_expect_fail "restore-api-only" mut_restore_api_only
mutate_expect_fail "raise-redirect-budget" mut_raise_redirect_budget
mutate_expect_fail "remove-redirect-budget" mut_remove_redirect_budget
mutate_expect_fail "allow-http-redir" mut_allow_http_redir
mutate_expect_fail "add-location-trusted" mut_add_location_trusted
mutate_expect_fail "accept-url-prefix" mut_accept_url_prefix
mutate_expect_fail "accept-prerelease-or-empty" mut_accept_prerelease_or_empty
mutate_expect_fail "hardcoded-fallback" mut_hardcoded_fallback
mutate_expect_fail "add-authorization" mut_add_authorization
mutate_expect_fail "log-other-version" mut_log_other_version
mutate_expect_fail "skip-resolution-when-installed" mut_skip_resolution_when_installed

if (run_latest_redirect_contract) >"$TMP_DIR/mutation-noop-last.log" 2>&1; then
  echo "MUTATION CONTROL: no-op stayed green after mutations"
else
  echo "no-op control failed after mutations" >&2
  cat "$TMP_DIR/mutation-noop-last.log" >&2
  exit 1
fi

restore_resolver

echo "release install contract passed"
