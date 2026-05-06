#!/usr/bin/env bash
# Experimental capability-surface differ.
#
# This is local tooling only. It is not exposed through action.yml and does not
# implement the ADR 0001 production baseline contract.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BASE_EVENTS="${1:?usage: diff_surface.sh <baseline events.ndjson|bundle.tar.gz|bundle-dir> <current events.ndjson|bundle.tar.gz|bundle-dir>}"
CURRENT_EVENTS="${2:?usage: diff_surface.sh <baseline events.ndjson|bundle.tar.gz|bundle-dir> <current events.ndjson|bundle.tar.gz|bundle-dir>}"
VERBOSE="${VERBOSE:-0}"

WORK=$(mktemp -d -t assay-capability-diff-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

bash "$HERE/extract_surface.sh" "$BASE_EVENTS" > "$WORK/base.surface"
bash "$HERE/extract_surface.sh" "$CURRENT_EVENTS" > "$WORK/current.surface"

BASE_COUNT=$(sed '/^$/d' "$WORK/base.surface" | wc -l | tr -d ' ')
CURRENT_COUNT=$(sed '/^$/d' "$WORK/current.surface" | wc -l | tr -d ' ')

if [ "$BASE_COUNT" -eq 0 ] && [ "$CURRENT_COUNT" -eq 0 ]; then
  echo "# Agent capability diff"
  echo
  echo "Capability diff skipped: no runtime capability events found."
  echo "This is expected for receipt-only or lifecycle-only bundles."
  exit 0
fi

comm -13 "$WORK/base.surface" "$WORK/current.surface" > "$WORK/added.surface"
comm -23 "$WORK/base.surface" "$WORK/current.surface" > "$WORK/removed.surface"

emit_dim() {
  local dim="$1"
  local title="$2"
  local marker="${3:-}"
  local added
  local removed

  added=$(awk -F '\t' -v dim="$dim" '$1 == dim { print $2 }' "$WORK/added.surface")
  removed=$(awk -F '\t' -v dim="$dim" '$1 == dim { print $2 }' "$WORK/removed.surface")

  if [ -z "$added" ] && [ -z "$removed" ]; then
    return
  fi

  echo "### $title${marker:+ $marker}"
  if [ -n "$added" ]; then
    echo "$added" | sed 's/^/  + /'
  fi
  if [ -n "$removed" ]; then
    echo "$removed" | sed 's/^/  - /'
  fi
  echo
}

emit_allow_aggregate() {
  local added_count
  local removed_count

  added_count=$(awk -F '\t' '$1 == "policy_allow" { count++ } END { print count + 0 }' "$WORK/added.surface")
  removed_count=$(awk -F '\t' '$1 == "policy_allow" { count++ } END { print count + 0 }' "$WORK/removed.surface")

  if [ "$added_count" -eq 0 ] && [ "$removed_count" -eq 0 ]; then
    return
  fi

  if [ "$VERBOSE" = "1" ]; then
    emit_dim "policy_allow" "Policy verdicts (allow)"
    return
  fi

  echo "### Policy verdicts (allow)"
  echo "  +${added_count} new, -${removed_count} removed (set VERBOSE=1 for details)"
  echo
}

echo "# Agent capability diff"
echo
emit_dim "net" "Network endpoints"
emit_dim "fs" "Filesystem paths"
emit_dim "proc" "Processes"
emit_dim "tool" "Tool calls"
emit_dim "policy_deny" "Policy verdicts (deny)" "[deny]"
emit_dim "policy_warn" "Policy verdicts (warn)"
emit_allow_aggregate

ADDED_COUNT=$(sed '/^$/d' "$WORK/added.surface" | wc -l | tr -d ' ')
REMOVED_COUNT=$(sed '/^$/d' "$WORK/removed.surface" | wc -l | tr -d ' ')
echo "Summary: +$ADDED_COUNT new, -$REMOVED_COUNT removed across capability dimensions."
