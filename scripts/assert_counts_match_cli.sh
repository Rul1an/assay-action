#!/usr/bin/env bash
set -euo pipefail

# Compare the finding counts the action published with the CLI's own report for the same bundle.
#
# Usage: FINDINGS_ERROR=<n> FINDINGS_WARN=<n> bash scripts/assert_counts_match_cli.sh <bundle>
#
# The oracle is `assay evidence lint --format json` from the `assay` on PATH, which in a job is the CLI the action
# installed. No expected number is written anywhere.
#
# Exit 0: the counts are equal and the bundle carries at least one error or warning.
# Exit 1: the counts differ, a published count is not a number, or the bundle carries no error or warning. A bundle
#         without findings is refused because 0 == 0 holds for an action that counts nothing.
# Exit 2: the comparison could not be made (no bundle, no CLI, no jq, or a report without a summary).

if [[ $# -ne 1 ]]; then
  echo "usage: FINDINGS_ERROR=<n> FINDINGS_WARN=<n> $0 <bundle>" >&2
  exit 2
fi
BUNDLE=$1

for tool in assay jq; do
  command -v "$tool" >/dev/null || { echo "::error::$tool is not on PATH; the counts cannot be compared" >&2; exit 2; }
done
if [[ ! -f "$BUNDLE" ]]; then
  echo "::error::No bundle at $BUNDLE; the counts cannot be compared" >&2
  exit 2
fi

# --fail-on none: the exit code then reports only whether the report could be produced.
if ! REPORT=$(assay evidence lint --format json --fail-on none "$BUNDLE"); then
  echo "::error::assay evidence lint could not report on $BUNDLE" >&2
  exit 2
fi
if ! ORACLE=$(jq -er '"\(.summary.errors) \(.summary.warnings)"' <<<"$REPORT" 2>/dev/null) \
  || ! [[ "$ORACLE" =~ ^[0-9]+\ [0-9]+$ ]]; then
  echo "::error::The CLI report for $BUNDLE carries no summary counts" >&2
  exit 2
fi
read -r CLI_ERRORS CLI_WARNS <<<"$ORACLE"

echo "CLI ($(assay --version)): errors=$CLI_ERRORS warnings=$CLI_WARNS"
echo "Action outputs:   errors=${FINDINGS_ERROR:-} warnings=${FINDINGS_WARN:-}"

status=0
if [[ "${FINDINGS_ERROR:-}" != "$CLI_ERRORS" ]]; then
  echo "::error::findings_error is '${FINDINGS_ERROR:-}', the CLI reports $CLI_ERRORS" >&2
  status=1
fi
if [[ "${FINDINGS_WARN:-}" != "$CLI_WARNS" ]]; then
  echo "::error::findings_warn is '${FINDINGS_WARN:-}', the CLI reports $CLI_WARNS" >&2
  status=1
fi
if [[ $((CLI_ERRORS + CLI_WARNS)) -lt 1 ]]; then
  echo "::error::The CLI reports no error or warning on $BUNDLE, so equal counts would prove nothing" >&2
  status=1
fi
exit "$status"
