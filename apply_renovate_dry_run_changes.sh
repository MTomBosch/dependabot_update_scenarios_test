#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <renovate_log_file>" >&2
  exit 2
fi

LOG_TEMPLATE="$1"
if [[ "${LOG_TEMPLATE}" != /* ]]; then
  LOG_TEMPLATE="${SCRIPT_DIR}/${LOG_TEMPLATE}"
fi

log_basename="$(basename "${LOG_TEMPLATE}")"
if [[ "${log_basename}" == *.* ]]; then
  log_base="${log_basename%.*}"
  log_ext=".${log_basename##*.}"
else
  log_base="${log_basename}"
  log_ext=""
fi

# In --mode-github-org, run_renovate.sh appends _owner_repo before extension.
LOG_FILE="$(find "${SCRIPT_DIR}" -maxdepth 1 -type f -name "${log_base}_*${log_ext}" -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2- || true)"
if [[ -z "${LOG_FILE}" ]]; then
  LOG_FILE="${LOG_TEMPLATE}"
fi

[[ -f "${LOG_FILE}" ]] || {
  echo "ERROR: Renovate dry-run log file not found: ${LOG_FILE}" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || {
  echo "ERROR: jq is required but not found in PATH" >&2
  exit 1
}

echo "==> Applying dry-run file contents from log: ${LOG_FILE}"

# Remove stale generated PR folders from prior runs.
find "${SCRIPT_DIR}" -maxdepth 1 -type d -name 'PR_*' -exec rm -rf {} +

tmp_entries="$(mktemp)"
trap 'rm -f "${tmp_entries}"' EXIT

# Extract branch/path/rawContents rows.
awk '
  BEGIN {
    current_branch = ""
    path = ""
    has_content_marker = 0
    in_files = 0
  }

  {
    if (match($0, /DRY-RUN: Would commit files to branch ([^ ]+)\. See debug logs/, m) ||
        match($0, /DRY-RUN: Would commit files to branch ([^ ]+) \(repository=/, m)) {
      current_branch = m[1]
      path = ""
      has_content_marker = 0
      in_files = 0
      next
    }

    if (current_branch != "" && $0 ~ /"files"[[:space:]]*:[[:space:]]*\[/) {
      in_files = 1
      next
    }

    if (current_branch != "" && in_files && match($0, /"path"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)"/, m)) {
      path = m[1]
      has_content_marker = 0
      next
    }

    if (current_branch != "" && in_files && path != "" && $0 ~ /"contents"[[:space:]]*:[[:space:]]*"\[content\]"/) {
      has_content_marker = 1
      next
    }

    if (current_branch != "" && in_files && path != "" && has_content_marker && match($0, /"rawContents"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)"/, m)) {
      printf("%s\t%s\t%s\n", current_branch, path, m[1])
      path = ""
      has_content_marker = 0
      next
    }

    if (in_files && $0 ~ /^[[:space:]]*\][[:space:]]*,?[[:space:]]*$/) {
      in_files = 0
      current_branch = ""
      path = ""
      has_content_marker = 0
    }
  }
' "${LOG_FILE}" > "${tmp_entries}"

snapshot_count=0
patch_count=0

while IFS=$'\t' read -r branch path raw_contents; do
  [[ -n "${branch}" && -n "${path}" ]] || continue

  safe_branch="${branch//\//_}"
  safe_branch="${safe_branch//./_}"
  pr_dir="${SCRIPT_DIR}/PR_${safe_branch}"
  target_file="${pr_dir}/${path}"
  patch_file="${target_file}.patch"

  mkdir -p "$(dirname "${target_file}")"

  new_tmp="$(mktemp)"
  old_tmp="$(mktemp)"

  printf '"%s"\n' "${raw_contents}" | jq -r . > "${new_tmp}"

  source_file="${SCRIPT_DIR}/${path}"
  if [[ -f "${source_file}" ]]; then
    cp "${source_file}" "${old_tmp}"
  else
    : > "${old_tmp}"
  fi

  cp "${new_tmp}" "${target_file}"
  snapshot_count=$((snapshot_count + 1))
  echo "  [${branch}] wrote: ${path}"

  diff -u "${old_tmp}" "${new_tmp}" > "${patch_file}" || true
  patch_count=$((patch_count + 1))
  echo "  [${branch}] patch: ${path}.patch"

  rm -f "${new_tmp}" "${old_tmp}"
done < "${tmp_entries}"

echo "==> Wrote ${snapshot_count} file snapshot(s) and ${patch_count} patch file(s) into PR_* folders."
