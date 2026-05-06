#!/usr/bin/env bash
# Experimental capability-surface extractor.
#
# This is not part of the public action interface. It emits TSV:
# dimension<TAB>value
#
# Experimental schema may change in any commit. Do not rely on it in production
# CI. The production capability-diff mode remains blocked by ADR 0001 and ADR
# 0002.

set -euo pipefail

INPUT="${1:?usage: extract_surface.sh <events.ndjson|bundle.tar.gz|bundle-dir>}"
QUIET="${ASSAY_EXTRACT_SURFACE_QUIET:-0}"
WORK=$(mktemp -d -t assay-extract-surface-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

EVENTS="$WORK/events.ndjson"
SURFACE="$WORK/surface.tsv"

if [ -d "$INPUT" ]; then
  if [ -f "$INPUT/events.ndjson" ]; then
    cp "$INPUT/events.ndjson" "$EVENTS"
  else
    FOUND=$(find "$INPUT" -type f -name events.ndjson | sort | head -1 || true)
    if [ -z "$FOUND" ]; then
      echo "extract_surface: no events.ndjson found in directory: $INPUT" >&2
      exit 2
    fi
    cp "$FOUND" "$EVENTS"
  fi
else
  case "$INPUT" in
    *.tar|*.tar.gz|*.tgz)
      MEMBER=$(tar -tf "$INPUT" | awk '/(^|\/)events[.]ndjson$/ { print; exit }')
      if [ -z "$MEMBER" ]; then
        echo "extract_surface: no events.ndjson found in bundle: $INPUT" >&2
        exit 2
      fi
      tar -xOf "$INPUT" "$MEMBER" > "$EVENTS"
      ;;
    *)
      cp "$INPUT" "$EVENTS"
      ;;
  esac
fi

jq -r '
  . as $event |
  (.type) as $type |
  if $type == "assay.net.connect" then
    "net\t" + ($event.subject // "")
  elif $type == "assay.fs.access" then
    "fs\t" + ($event.subject // "")
  elif $type == "assay.process.exec" then
    "proc\t" + ($event.subject // "")
  elif $type == "assay.tool.decision" then
    "tool\t" + ($event.data.tool // $event.subject // "")
  elif $type == "assay.policy.evaluated" then
    ("policy_" + ($event.data.verdict // "unknown")) + "\t" +
    ($event.data.rule // "") + ":" + ($event.data.subject // $event.subject // "")
  else
    empty
  end
' "$EVENTS" | awk -F '\t' 'NF == 2 && $2 != "" { print }' | sort -u > "$SURFACE"

if [ ! -s "$SURFACE" ] && [ "$QUIET" != "1" ]; then
  echo "extract_surface: no runtime capability events found in: $INPUT" >&2
  echo "extract_surface: receipt-only or lifecycle-only bundles are expected to produce an empty surface." >&2
fi

cat "$SURFACE"
