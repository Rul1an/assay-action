#!/usr/bin/env bash
# unique_stem <used-file> <bundle path>: print a report name stem for the bundle that no other
# bundle of this run has, and record it in <used-file>.
#
# Reports are named after the bundle's file name. Two bundles in different directories can share
# one, and the second report would then replace the first. The first bundle keeps the plain name
# (`b`), later ones get a number (`b-2`, `b-3`), skipping any name a bundle already holds.
#
# Sourced by the action's steps; one definition, so lint and pack reports are named by one rule.
unique_stem() {
  local used=$1 base stem n=1
  base=$(basename "$2" .tar.gz)
  stem=$base
  while grep -qxF -- "$stem" "$used" 2>/dev/null; do
    n=$((n + 1))
    stem="$base-$n"
  done
  printf '%s\n' "$stem" >> "$used"
  printf '%s\n' "$stem"
}
