#!/usr/bin/env bash
set -euo pipefail

FAIL_ON="${1:-}"
ERRORS="${2:-0}"
WARNS="${3:-0}"
INFOS="${4:-0}"

FAIL_ON="${FAIL_ON#"${FAIL_ON%%[![:space:]]*}"}"
FAIL_ON="${FAIL_ON%"${FAIL_ON##*[![:space:]]}"}"
case "$FAIL_ON" in
  warning) FAIL_ON="warn" ;;
esac

for labeled in "errors:$ERRORS" "warnings:$WARNS" "infos:$INFOS"; do
  name="${labeled%%:*}"
  value="${labeled#*:}"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    echo "::error::invalid $name count: ${value:-<empty>}" >&2
    exit 1
  fi
done

case "$FAIL_ON" in
  error)
    if [ "$ERRORS" -gt 0 ]; then
      echo "::error::$ERRORS error-level findings exceed threshold" >&2
      exit 1
    fi
    ;;
  warn)
    if [ "$ERRORS" -gt 0 ] || [ "$WARNS" -gt 0 ]; then
      echo "::error::$ERRORS errors, $WARNS warnings exceed threshold" >&2
      exit 1
    fi
    ;;
  info)
    if [ "$ERRORS" -gt 0 ] || [ "$WARNS" -gt 0 ] || [ "$INFOS" -gt 0 ]; then
      echo "::error::$ERRORS errors, $WARNS warnings, $INFOS info findings exceed threshold" >&2
      exit 1
    fi
    ;;
  none)
    ;;
  *)
    echo "::error::unknown fail_on value: ${FAIL_ON:-<empty>}" >&2
    exit 1
    ;;
esac
