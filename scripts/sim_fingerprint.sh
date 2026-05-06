#!/usr/bin/env bash
# Assay v2 fingerprint stability simulation.
#
# Covers 50 synthetic baseline/current pairs across no-op, additions, removals,
# message-only changes, native/SARIF shape mixing, location shifts, rule renames,
# edge cases, and mixed multi-deltas.
#
# Mirrors the v2 fingerprint from action.yml:
# fingerprint_version = v1-severity-rule-location.

set -euo pipefail

WORK=$(mktemp -d -t assay-fingerprint-sim-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FINGERPRINT_JQ='
def text($v): if $v == null then "" else ($v | tostring) end;
def location_value:
  if (.location? | type) == "object" then
    (.location.path // .location.file // .location.uri // .location.target // .location)
  else
    .location?
  end;
def location_line:
  if (.location? | type) == "object" then
    (.location.line // .location.start_line // .location.startLine // .location.region.startLine?)
  else
    null
  end;
def location_column:
  if (.location? | type) == "object" then
    (.location.column // .location.start_column // .location.startColumn // .location.region.startColumn?)
  else
    null
  end;
def location_canonical:
  text(location_value // .path // .file // .uri // .target // .physicalLocation.artifactLocation.uri? // .locations[0].physicalLocation.artifactLocation.uri?) as $path
  | text(location_line // .line // .start_line // .startLine // .region.startLine? // .physicalLocation.region.startLine? // .locations[0].physicalLocation.region.startLine?) as $line
  | text(location_column // .column // .start_column // .startColumn // .region.startColumn? // .physicalLocation.region.startColumn? // .locations[0].physicalLocation.region.startColumn?) as $column
  | if $path == "" then ""
    elif $line != "" and $column != "" then "\($path):\($line):\($column)"
    elif $line != "" then "\($path):\($line)"
    else $path
    end;
(.findings // [])[] |
[
  (.severity // ""),
  (.rule_id // .ruleId // .rule.id? // .rule.name? // .id // ""),
  location_canonical
] | @tsv
'

fp_keys() {
  jq -r "$FINGERPRINT_JQ" "$1" 2>/dev/null | sort -u
}

diff_pair() {
  local baseline="$1"
  local current="$2"
  local baseline_keys="$WORK/baseline.keys"
  local current_keys="$WORK/current.keys"
  local added
  local removed
  local unchanged

  fp_keys "$baseline" > "$baseline_keys"
  fp_keys "$current" > "$current_keys"
  added=$(comm -13 "$baseline_keys" "$current_keys" | sed '/^$/d' | wc -l | tr -d ' ')
  removed=$(comm -23 "$baseline_keys" "$current_keys" | sed '/^$/d' | wc -l | tr -d ' ')
  unchanged=$(comm -12 "$baseline_keys" "$current_keys" | sed '/^$/d' | wc -l | tr -d ' ')
  echo "$added $removed $unchanged"
}

native() {
  jq -nc --arg severity "$1" --arg rule "$2" --arg path "$3" --argjson line "$4" --arg message "${5:-default}" \
    '{severity:$severity, rule_id:$rule, location:{path:$path, line:$line}, message:$message}'
}

sarif() {
  jq -nc --arg severity "$1" --arg rule "$2" --arg path "$3" --argjson line "$4" --arg message "${5:-default}" \
    '{severity:$severity, ruleId:$rule, message:{text:$message}, locations:[{physicalLocation:{artifactLocation:{uri:$path}, region:{startLine:$line}}}]}'
}

bundle() {
  local out="$1"
  shift

  if [ "$#" -eq 0 ]; then
    jq -n '{findings:[]}' > "$out"
    return
  fi

  printf '%s\n' "$@" | jq -s '{findings: .}' > "$out"
}

scn_noop() {
  local seed="$1"
  local baseline="$2"
  local current="$3"
  local arr=()
  local k

  case "$seed" in
    1|2|3|4|5)
      for k in $(seq 1 "$seed"); do
        arr+=("$(native error "ASSAY-E$(printf %03d "$k")" "src/file_$k.rs" $((10 + k)) "msg-$k")")
      done
      bundle "$baseline" "${arr[@]}"
      cp "$baseline" "$current"
      ;;
    6|7|8)
      bundle "$baseline" \
        "$(native error "ASSAY-E001" "src/x.rs" 1 "dup-a")" \
        "$(native error "ASSAY-E001" "src/x.rs" 1 "dup-b")" \
        "$(native warning "ASSAY-W001" "src/y.rs" 2 "warn")"
      cp "$baseline" "$current"
      ;;
    9|10|11)
      bundle "$baseline" \
        "$(native error "ASSAY-A" "src/a.rs" 1 "A1")" \
        "$(native warning "ASSAY-B" "src/b.rs" 2 "B1")" \
        "$(native info "ASSAY-C" "src/c.rs" 3 "C1")"
      bundle "$current" \
        "$(native info "ASSAY-C" "src/c.rs" 3 "C2-changed")" \
        "$(native error "ASSAY-A" "src/a.rs" 1 "A2-changed")" \
        "$(native warning "ASSAY-B" "src/b.rs" 2 "B2-changed")"
      ;;
    12|13)
      bundle "$baseline" "$(native error "ASSAY-E001" "src/x.rs" 5 "via-native")"
      bundle "$current" "$(sarif error "ASSAY-E001" "src/x.rs" 5 "via-sarif")"
      ;;
    14|15)
      bundle "$baseline" \
        "$(native error "ASSAY-E001" "src/x.rs" 1 "old wording")" \
        "$(native warning "ASSAY-W001" "src/y.rs" 2 "old warning text")"
      bundle "$current" \
        "$(native error "ASSAY-E001" "src/x.rs" 1 "different wording $seed with timestamp 2026-05-06")" \
        "$(native warning "ASSAY-W001" "src/y.rs" 2 "wording rewritten")"
      ;;
  esac
}

scn_add_error() {
  local seed="$1"
  local baseline="$2"
  local current="$3"

  bundle "$baseline" "$(native warning "ASSAY-W001" "src/x.rs" 1 "stable")"
  bundle "$current" \
    "$(native warning "ASSAY-W001" "src/x.rs" 1 "stable")" \
    "$(native error "ASSAY-E$(printf %03d "$seed")" "src/new_$seed.rs" $((100 + seed)) "new-error")"
}

scn_add_warning() {
  local seed="$1"
  local baseline="$2"
  local current="$3"

  bundle "$baseline" "$(native error "ASSAY-E001" "src/x.rs" 1 "stable")"
  bundle "$current" \
    "$(native error "ASSAY-E001" "src/x.rs" 1 "stable")" \
    "$(native warning "ASSAY-W$(printf %03d "$seed")" "src/new_$seed.rs" $((100 + seed)) "new-warning")"
}

scn_add_info() {
  local seed="$1"
  local baseline="$2"
  local current="$3"

  bundle "$baseline" "$(native error "ASSAY-E001" "src/x.rs" 1 "stable")"
  bundle "$current" \
    "$(native error "ASSAY-E001" "src/x.rs" 1 "stable")" \
    "$(native info "ASSAY-I$(printf %03d "$seed")" "src/new_$seed.rs" $((100 + seed)) "new-info")"
}

scn_remove() {
  local seed="$1"
  local baseline="$2"
  local current="$3"

  bundle "$baseline" \
    "$(native error "ASSAY-E001" "src/keep.rs" 1 "stable")" \
    "$(native warning "ASSAY-W$(printf %03d "$seed")" "src/gone_$seed.rs" $((50 + seed)) "removed")"
  bundle "$current" "$(native error "ASSAY-E001" "src/keep.rs" 1 "stable")"
}

scn_msg_only() {
  local seed="$1"
  local baseline="$2"
  local current="$3"

  bundle "$baseline" "$(native error "ASSAY-E001" "src/x.rs" 42 "old wording $seed")"
  bundle "$current" "$(native error "ASSAY-E001" "src/x.rs" 42 "different message $seed with timestamp 2026-05-06")"
}

scn_shape_mix() {
  local seed="$1"
  local baseline="$2"
  local current="$3"

  bundle "$baseline" "$(native error "ASSAY-E001" "src/file_$seed.rs" $((10 + seed)) "via-native")"
  bundle "$current" "$(sarif error "ASSAY-E001" "src/file_$seed.rs" $((10 + seed)) "via-sarif")"
}

scn_line_shift() {
  local seed="$1"
  local baseline="$2"
  local current="$3"

  bundle "$baseline" "$(native error "ASSAY-E001" "src/x.rs" $((40 + seed)) "moved")"
  bundle "$current" "$(native error "ASSAY-E001" "src/x.rs" $((50 + seed)) "moved")"
}

scn_rule_rename() {
  local seed="$1"
  local baseline="$2"
  local current="$3"

  bundle "$baseline" "$(native error "ASSAY-OLD-$seed" "src/x.rs" 1 "renamed")"
  bundle "$current" "$(native error "ASSAY-NEW-$seed" "src/x.rs" 1 "renamed")"
}

scn_empty_baseline() {
  local baseline="$2"
  local current="$3"

  bundle "$baseline"
  bundle "$current" "$(native error "ASSAY-E001" "src/x.rs" 1 "first")"
}

scn_empty_current() {
  local baseline="$2"
  local current="$3"

  bundle "$baseline" "$(native error "ASSAY-E001" "src/x.rs" 1 "removed")"
  bundle "$current"
}

scn_mixed() {
  local seed="$1"
  local baseline="$2"
  local current="$3"

  bundle "$baseline" \
    "$(native error "ASSAY-A" "src/a.rs" 1 "A")" \
    "$(native warning "ASSAY-B" "src/b.rs" 2 "B")"
  bundle "$current" \
    "$(native error "ASSAY-A" "src/a.rs" 1 "A")" \
    "$(native error "ASSAY-C-$seed" "src/c.rs" 3 "C")" \
    "$(native warning "ASSAY-D-$seed" "src/d.rs" 4 "D")"
}

declare -a TESTS=()

add() {
  TESTS+=("$1|$2|$3|$4|$5|$6|$7")
}

n=0
for i in $(seq 1 5); do n=$((n + 1)); add "$(printf %02d "$n")-noop-$i" "no-op" 0 0 "$i" scn_noop "$i"; done
for i in $(seq 6 8); do n=$((n + 1)); add "$(printf %02d "$n")-noop-$i" "no-op" 0 0 2 scn_noop "$i"; done
for i in $(seq 9 11); do n=$((n + 1)); add "$(printf %02d "$n")-noop-$i" "no-op" 0 0 3 scn_noop "$i"; done
for i in $(seq 12 13); do n=$((n + 1)); add "$(printf %02d "$n")-noop-$i" "no-op" 0 0 1 scn_noop "$i"; done
for i in $(seq 14 15); do n=$((n + 1)); add "$(printf %02d "$n")-noop-$i" "no-op" 0 0 2 scn_noop "$i"; done
for i in $(seq 1 5); do n=$((n + 1)); add "$(printf %02d "$n")-add-error-$i" "addition" 1 0 1 scn_add_error "$i"; done
for i in $(seq 1 3); do n=$((n + 1)); add "$(printf %02d "$n")-add-warning-$i" "addition" 1 0 1 scn_add_warning "$i"; done
for i in $(seq 1 2); do n=$((n + 1)); add "$(printf %02d "$n")-add-info-$i" "addition" 1 0 1 scn_add_info "$i"; done
for i in $(seq 1 5); do n=$((n + 1)); add "$(printf %02d "$n")-remove-$i" "removal" 0 1 1 scn_remove "$i"; done
for i in $(seq 1 5); do n=$((n + 1)); add "$(printf %02d "$n")-message-$i" "stability" 0 0 1 scn_msg_only "$i"; done
for i in $(seq 1 5); do n=$((n + 1)); add "$(printf %02d "$n")-shape-$i" "stability" 0 0 1 scn_shape_mix "$i"; done
for i in $(seq 1 4); do n=$((n + 1)); add "$(printf %02d "$n")-line-shift-$i" "location-shift" 1 1 0 scn_line_shift "$i"; done
for i in $(seq 1 3); do n=$((n + 1)); add "$(printf %02d "$n")-rule-rename-$i" "rule-rename" 1 1 0 scn_rule_rename "$i"; done
n=$((n + 1)); add "$(printf %02d "$n")-empty-baseline" "edge" 1 0 0 scn_empty_baseline 0
n=$((n + 1)); add "$(printf %02d "$n")-empty-current" "edge" 0 1 0 scn_empty_current 0
n=$((n + 1)); add "$(printf %02d "$n")-mixed" "mixed" 2 1 1 scn_mixed 1

PASS=0
FAIL=0
RESULT_TSV="$WORK/results.tsv"
: > "$RESULT_TSV"

printf '%-26s  %-15s  %4s  %4s  %4s  %4s  %4s  %4s  %s\n' "ID" "CATEGORY" "EXP+" "GOT+" "EXP-" "GOT-" "EXP=" "GOT=" "RESULT"
printf '%s\n' "-------------------------------------------------------------------------------------------------"

for entry in "${TESTS[@]}"; do
  IFS='|' read -r id category exp_added exp_removed exp_unchanged generator seed <<EOF
$entry
EOF
  case_dir="$WORK/$id"
  baseline="$case_dir/baseline.json"
  current="$case_dir/current.json"
  result="pass"

  mkdir -p "$case_dir"
  "$generator" "$seed" "$baseline" "$current"
  read -r got_added got_removed got_unchanged <<EOF
$(diff_pair "$baseline" "$current")
EOF

  if [ "$got_added" = "$exp_added" ] && [ "$got_removed" = "$exp_removed" ] && [ "$got_unchanged" = "$exp_unchanged" ]; then
    PASS=$((PASS + 1))
  else
    result="FAIL"
    FAIL=$((FAIL + 1))
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$category" "$exp_added" "$got_added" "$exp_removed" "$got_removed" "$exp_unchanged" "$got_unchanged" "$result" >> "$RESULT_TSV"
  printf '%-26s  %-15s  %4s  %4s  %4s  %4s  %4s  %4s  %s\n' "$id" "$category" "$exp_added" "$got_added" "$exp_removed" "$got_removed" "$exp_unchanged" "$got_unchanged" "$result"
done

echo
echo "=== Summary ==="
echo "Total: $((PASS + FAIL))   Pass: $PASS   Fail: $FAIL"
echo
echo "Per category:"
awk -F '\t' '
{
  total[$2]++
  if ($9 == "pass") {
    passed[$2]++
  }
}
END {
  for (cat in total) {
    printf "  %-18s %d/%d\n", cat, (passed[cat] + 0), total[cat]
  }
}' "$RESULT_TSV" | sort

if [ "$FAIL" -gt 0 ]; then
  echo
  echo "Failed cases:"
  awk -F '\t' '$9 == "FAIL" { printf "  - %s (%s): expected +%s/-%s/=%s, got +%s/-%s/=%s\n", $1, $2, $3, $5, $7, $4, $6, $8 }' "$RESULT_TSV"
  exit 1
fi
