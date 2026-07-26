#!/usr/bin/env bash
set -euo pipefail

BINARY="${1:-}"
EXPECTED_VERSION="${2:-}"

run_inspected_binary() {
  (
    unset GITHUB_OUTPUT GITHUB_PATH GITHUB_ENV GITHUB_STATE GITHUB_STEP_SUMMARY GITHUB_TOKEN
    "$@"
  )
}

if [[ ! -x "$BINARY" ]]; then
  echo "::error::Assay installation verification failed"
  exit 1
fi
if [[ -z "$EXPECTED_VERSION" || "$EXPECTED_VERSION" == *$'\n'* || "$EXPECTED_VERSION" == *$'\r'* ]]; then
  echo "::error::Assay installation verification received an invalid expected version"
  exit 1
fi

INSTALLED_STATUS=0
INSTALLED_OUTPUT="$(
  run_inspected_binary "$BINARY" --version 2>/dev/null
)" || INSTALLED_STATUS=$?
if [[ "$INSTALLED_STATUS" != "0" ]]; then
  echo "::error::Assay installation verification failed: binary exited with status ${INSTALLED_STATUS}"
  exit 1
fi
INSTALLED_VERSION=""
if [[ "$INSTALLED_OUTPUT" != *$'\n'* &&
  "$INSTALLED_OUTPUT" != *$'\r'* &&
  "$INSTALLED_OUTPUT" =~ ^assay[[:space:]]+([0-9A-Za-z.+-]+)$ ]]; then
  INSTALLED_VERSION="${BASH_REMATCH[1]}"
fi
if [[ "$INSTALLED_VERSION" != "$EXPECTED_VERSION" ]]; then
  echo "::error::Assay installation verification failed: expected ${EXPECTED_VERSION}, got ${INSTALLED_VERSION:-unknown}"
  exit 1
fi

printf '%s\n' "$(dirname "$BINARY")" >>"$GITHUB_PATH"
printf '%s\n' "$INSTALLED_OUTPUT"
echo "installed=true" >>"$GITHUB_OUTPUT"
