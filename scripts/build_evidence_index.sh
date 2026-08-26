#!/usr/bin/env bash
# Sole producer of the bounded evidence index, path normalization, cap, and
# digest. Integrity verification stays with `assay evidence verify`.
set -euo pipefail

MAX_BUNDLES=100
SCHEMA="assay-action-evidence-index/v1"
SANDBOX_REL=".assay/sandbox-command/evidence.tar.gz"

WORKSPACE="${WORKSPACE:-${GITHUB_WORKSPACE:-$PWD}}"

emit() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s\n' "$1" >>"$GITHUB_OUTPUT"
  fi
}

die() {
  echo "::error::$*" >&2
  exit 1
}

die_config() {
  echo "::error::$*" >&2
  exit 2
}

file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

resolve_under_workspace() {
  local raw="$1"
  python3 -c '
import os, sys
workspace = os.path.realpath(sys.argv[1])
raw = sys.argv[2].replace("\\", "/")
if not raw or "://" in raw:
    raise SystemExit(1)
if raw.startswith("./"):
    raw = raw[2:]
if any(part == ".." for part in raw.split("/")):
    raise SystemExit(1)
if raw.startswith("/"):
    full = os.path.realpath(raw)
else:
    full = os.path.realpath(os.path.join(workspace, raw))
if full != workspace and not full.startswith(workspace + os.sep):
    raise SystemExit(1)
rel = os.path.relpath(full, workspace).replace("\\", "/")
if rel.startswith("..") or os.path.isabs(rel):
    raise SystemExit(1)
print(rel)
' "$WORKSPACE" "$raw"
}

index_abs() {
  local p="${INDEX_PATH:-}"
  if [[ -z "$p" ]]; then
    p="${WORKSPACE}/.assay-reports/evidence-index.json"
  elif [[ "$p" != /* ]]; then
    p="${WORKSPACE}/${p}"
  fi
  printf '%s\n' "$p"
}

index_rel() {
  python3 -c '
import os, sys
workspace = os.path.realpath(sys.argv[1])
full = os.path.realpath(sys.argv[2])
print(os.path.relpath(full, workspace).replace("\\", "/"))
' "$WORKSPACE" "$(index_abs)"
}

complete_from_rows_py() {
  cat <<'PY'
def complete_from_rows(rows):
    return all(
        r.get("integrity") in ("verified", "rejected") for r in rows
    )

def all_rows_verified(rows):
    return bool(rows) and all(r.get("integrity") == "verified" for r in rows)
PY
}

write_index_json() {
  local dest="$1"
  python3 -c "
$(complete_from_rows_py)
import json, sys
schema = sys.argv[1]
rows = []
for line in sys.stdin:
    line = line.rstrip('\n')
    if not line:
        continue
    path, sha, source, integrity = line.split('\t')
    rows.append({
        'integrity': integrity,
        'path': path,
        'sha256': sha,
        'source': source,
    })
rows.sort(key=lambda row: row['path'])
complete = complete_from_rows(rows)
doc = {'bundles': rows, 'complete': complete, 'schema': schema}
with open(sys.argv[2], 'w', encoding='ascii') as handle:
    handle.write(json.dumps(doc, sort_keys=True, separators=(',', ':')) + '\n')
" "$SCHEMA" "$dest"
}

validate_mode() {
  case "${EVIDENCE_MODE:-}" in
    optional|required) ;;
    *)
      die_config "Unknown evidence_mode '${EVIDENCE_MODE:-}'. Allowed: optional, required."
      ;;
  esac
}

cmd_index() {
  validate_mode
  local raw_file="${BUNDLES_FILE:-}"
  local list_path="${LIST_PATH:-}"
  local dest
  dest="$(index_abs)"
  mkdir -p "$(dirname "$dest")"
  if [[ -z "$list_path" ]]; then
    list_path="$(dirname "$dest")/assay-bundles.txt"
  elif [[ "$list_path" != /* ]]; then
    list_path="${WORKSPACE}/${list_path}"
  fi

  local staged=""
  local rows
  rows="$(mktemp)"
  local paths
  paths="$(mktemp)"
  # shellcheck disable=SC2064 # Expand now so the trap removes these temps.
  trap 'rm -f "$rows" "$paths"' RETURN

  if [[ -n "$raw_file" && -f "$raw_file" ]]; then
    while IFS= read -r raw || [[ -n "$raw" ]]; do
      [[ -z "$raw" ]] && continue
      local rel
      if ! rel="$(resolve_under_workspace "$raw")"; then
        die "Evidence path is not a normalized workspace-relative file: $raw"
      fi
      if [[ ! -f "${WORKSPACE}/${rel}" ]]; then
        die "Evidence bundle does not exist: $rel"
      fi
      printf '%s\n' "$rel" >>"$paths"
    done <"$raw_file"
  fi

  if [[ -n "${SANDBOX_BUNDLE:-}" && -f "$SANDBOX_BUNDLE" ]]; then
    mkdir -p "$(dirname "${WORKSPACE}/${SANDBOX_REL}")"
    cp "$SANDBOX_BUNDLE" "${WORKSPACE}/${SANDBOX_REL}"
    staged="$SANDBOX_REL"
    printf '%s\n' "$staged" >>"$paths"
  fi

  if [[ -s "$paths" ]]; then
    LC_ALL=C sort -u "$paths" -o "$paths"
  fi

  local count=0
  if [[ -s "$paths" ]]; then
    count="$(grep -c . "$paths")"
  fi
  if [[ "$count" -gt "$MAX_BUNDLES" ]]; then
    die "Evidence index refused the 101st bundle (maximum ${MAX_BUNDLES})."
  fi

  : >"$list_path"
  if [[ -s "$paths" ]]; then
    while IFS= read -r rel || [[ -n "$rel" ]]; do
      [[ -z "$rel" ]] && continue
      local digest source
      digest="$(file_sha256 "${WORKSPACE}/${rel}")"
      if [[ "$rel" == "$SANDBOX_REL" ]]; then
        source="sandbox_command"
      else
        source="discovered"
      fi
      printf '%s\t%s\t%s\t%s\n' "$rel" "$digest" "$source" "pending" >>"$rows"
      printf '%s\n' "$rel" >>"$list_path"
    done <"$paths"
  fi

  write_index_json "$dest" <"$rows"
  local digest
  digest="$(file_sha256 "$dest")"
  local rel_index
  rel_index="$(index_rel)"

  emit "bundles_file=${list_path}"
  emit "count=${count}"
  emit "evidence_index_path=${rel_index}"
  emit "evidence_index_digest=${digest}"
  if [[ "$count" -eq 0 ]]; then
    emit "found=false"
    emit "evidence_state=absent"
    emit "verified=false"
    if [[ "${EVIDENCE_MODE}" == "required" ]]; then
      die "evidence_mode=required but no evidence bundles were discovered."
    fi
    return 0
  fi
  emit "found=true"
  emit "evidence_state=discovered"
  emit "verified=false"
}

cmd_assert() {
  local dest
  dest="$(index_abs)"
  [[ -f "$dest" ]] || die "Evidence index does not exist: $dest"
  python3 -c '
import json, os, sys, hashlib
workspace = sys.argv[1]
index_path = sys.argv[2]
with open(index_path, encoding="ascii") as handle:
    doc = json.load(handle)
for row in doc.get("bundles", []):
    rel = row["path"]
    full = os.path.join(workspace, rel)
    if not os.path.isfile(full):
        raise SystemExit("missing " + rel)
    digest = hashlib.sha256(open(full, "rb").read()).hexdigest()
    if digest != row["sha256"]:
        raise SystemExit("mismatch " + rel)
' "$WORKSPACE" "$dest" || die "Indexed bundle bytes changed before verification."
}

cmd_seal() {
  local dest results="${INTEGRITY_RESULTS:-}"
  dest="$(index_abs)"
  [[ -f "$dest" ]] || die "Evidence index does not exist: $dest"
  [[ -n "$results" && -f "$results" ]] || die "Integrity results file is missing."
  local verdict
  verdict="$(
    python3 -c "
$(complete_from_rows_py)
import json, sys
index_path = sys.argv[1]
results_path = sys.argv[2]
with open(index_path, encoding='ascii') as handle:
    doc = json.load(handle)
status = {}
with open(results_path, encoding='ascii') as handle:
    for line in handle:
        line = line.rstrip('\n')
        if not line:
            continue
        path, integrity = line.split('\t')
        status[path] = integrity
for row in doc['bundles']:
    if row['path'] not in status:
        raise SystemExit('missing integrity result for ' + row['path'])
    row['integrity'] = status[row['path']]
doc['complete'] = complete_from_rows(doc['bundles'])
with open(index_path, 'w', encoding='ascii') as handle:
    handle.write(json.dumps(doc, sort_keys=True, separators=(',', ':')) + '\n')
print('verified' if all_rows_verified(doc['bundles']) else 'rejected')
" "$dest" "$results"
  )"
  emit "evidence_index_path=$(index_rel)"
  emit "evidence_index_digest=$(file_sha256 "$dest")"
  if [[ "$verdict" == "verified" ]]; then
    emit "verified=true"
  else
    emit "verified=false"
  fi
}

cmd_sealed_ok() {
  local dest
  dest="$(index_abs)"
  [[ -f "$dest" ]] || die "Evidence index does not exist: $dest"
  python3 -c "
$(complete_from_rows_py)
import json, sys
with open(sys.argv[1], encoding='ascii') as handle:
    doc = json.load(handle)
raise SystemExit(0 if all_rows_verified(doc.get('bundles', [])) else 1)
" "$dest"
}

cmd_finalize() {
  case "${DISCOVER_OUTCOME:-}" in
    success|failure) ;;
    skipped|cancelled|"")
      # Discovery never ran. Do not manufacture absent.
      exit 0
      ;;
    *)
      exit 0
      ;;
  esac

  if [[ "${DISCOVER_FOUND:-}" == "" ]]; then
    exit 0
  fi

  if [[ -n "${INDEX_PATH:-}" ]]; then
    emit "evidence_index_path=${INDEX_PATH}"
  fi
  if [[ -n "${INDEX_DIGEST:-}" ]]; then
    emit "evidence_index_digest=${INDEX_DIGEST}"
  fi

  if [[ "${DISCOVER_FOUND}" != "true" ]]; then
    emit "evidence_state=absent"
    emit "verified=false"
    return 0
  fi

  if [[ "${PROCESS_VERIFIED:-}" == "true" ]]; then
    emit "evidence_state=verified"
    emit "verified=true"
    return 0
  fi
  if [[ "${PROCESS_VERIFIED:-}" == "false" ]]; then
    emit "evidence_state=rejected"
    emit "verified=false"
    return 0
  fi
  emit "evidence_state=discovered"
  emit "verified=false"
}

case "${1:-}" in
  index) cmd_index ;;
  assert) cmd_assert ;;
  seal) cmd_seal ;;
  sealed-ok) cmd_sealed_ok ;;
  finalize) cmd_finalize ;;
  *)
    die_config "usage: build_evidence_index.sh index|assert|seal|sealed-ok|finalize"
    ;;
esac
