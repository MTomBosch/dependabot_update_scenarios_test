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

CHANGED_REPORT_FILE="${SCRIPT_DIR}/RENOVATE_CHANGED_REFERENCES.log"
UNCHANGED_REPORT_FILE="${SCRIPT_DIR}/RENOVATE_UNCHANGED_REFERENCES.log"

echo "==> Analyzing dry-run log: ${LOG_FILE}"

tmp_changed="$(mktemp)"
tmp_unchanged="$(mktemp)"
tmp_mismatch="$(mktemp)"
tmp_depmap="$(mktemp)"
tmp_refsmap="$(mktemp)"
tmp_mismatch_with_refs="$(mktemp)"
trap 'rm -f "${tmp_changed}" "${tmp_unchanged}" "${tmp_mismatch}" "${tmp_depmap}" "${tmp_refsmap}" "${tmp_mismatch_with_refs}"' EXIT

# Changed references: extracted from dry-run commit payload by branch and file path.
awk '
  BEGIN {
    current_branch = ""
    path = ""
    has_content_marker = 0
    in_files = 0
  }

  {
    if (match($0, /DRY-RUN: Would commit files to branch ([^ .]+)\./, m)) {
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
      printf("branch=%s\tpath=%s\n", current_branch, path)
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
' "${LOG_FILE}" | sort -u > "${tmp_changed}"

{
  echo "Renovate dry-run changed references report"
  echo "source_log=${LOG_FILE}"
  echo "generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo ""
  echo "[changed entries]"
  cat "${tmp_changed}"
} > "${CHANGED_REPORT_FILE}"

# Consistency mismatch base rows.
awk '
  {
    if (match($0, /Extracted ([^ ]+) after autoreplace has fewer deps than expected\..*branch=([^)]*)\)/, m)) {
      printf("consistencyMismatch=true\tpackageFile=%s\tbranch=%s\n", m[1], m[2])
      next
    }
    if (match($0, /depName mismatch \(.*packageFile=([^,]+), branch=([^)]*)\)/, m)) {
      printf("consistencyMismatch=true\tpackageFile=%s\tbranch=%s\n", m[1], m[2])
    }
  }
' "${LOG_FILE}" | sort -u > "${tmp_mismatch}"

# Branch/packageFile -> depName tuples for enrichment of mismatch entries.
awk '
  BEGIN {
    branch = ""
    dep = ""
  }

  {
    if (match($0, /"branchName"[[:space:]]*:[[:space:]]*"([^"]+)"/, m)) {
      branch = m[1]
    }
    if (match($0, /"depName"[[:space:]]*:[[:space:]]*"([^"]+)"/, m)) {
      dep = m[1]
    }
    if (match($0, /"packageFile"[[:space:]]*:[[:space:]]*"([^"]+)"/, m)) {
      pkg = m[1]
      if (branch != "" && dep != "" && pkg != "") {
        printf("%s\t%s\t%s\n", branch, pkg, dep)
      }
    }
  }
' "${LOG_FILE}" | sort -u > "${tmp_depmap}"

# Build branch/packageFile -> related references list (depName@currentValue).
awk '
  BEGIN {
    branch = ""
    dep = ""
    cur = ""
  }

  {
    if (match($0, /"branchName"[[:space:]]*:[[:space:]]*"([^"]+)"/, m)) {
      branch = m[1]
    }
    if (match($0, /"depName"[[:space:]]*:[[:space:]]*"([^"]+)"/, m)) {
      dep = m[1]
    }
    if (match($0, /"currentValue"[[:space:]]*:[[:space:]]*"([^"]+)"/, m)) {
      cur = m[1]
    }
    if (match($0, /"packageFile"[[:space:]]*:[[:space:]]*"([^"]+)"/, m)) {
      pkg = m[1]
      if (branch != "" && dep != "" && cur != "" && pkg != "") {
        printf("%s\t%s\t%s@%s\n", branch, pkg, dep, cur)
      }
    }
  }
' "${LOG_FILE}" | sort -u > "${tmp_refsmap}"

# Enrich mismatch rows with references list for both file and console output.
awk -F'\t' '
  NR == FNR {
    key = $1 "\t" $2
    if (refs[key] == "") {
      refs[key] = $3
    } else if (index("," refs[key] ",", "," $3 ",") == 0) {
      refs[key] = refs[key] "," $3
    }
    next
  }

  {
    branch = ""
    pkg = ""
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^branch=/) {
        branch = substr($i, length("branch=") + 1)
      } else if ($i ~ /^packageFile=/) {
        pkg = substr($i, length("packageFile=") + 1)
      }
    }

    key = branch "\t" pkg
    refsList = (refs[key] != "" ? refs[key] : "unknown")
    printf("%s\treferences=%s\n", $0, refsList)
  }
' "${tmp_refsmap}" "${tmp_mismatch}" > "${tmp_mismatch_with_refs}"

# Unchanged references and reasons.
{
  echo "Renovate dry-run unchanged references report"
  echo "source_log=${LOG_FILE}"
  echo "generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo ""

  echo "[skipReason: invalid-version|unversioned-reference|disabled]"
  awk '
    {
      if (match($0, /"packageFile"[[:space:]]*:[[:space:]]*"([^"]+)"/, m)) {
        pkg = m[1]
      }
      if (match($0, /"replaceString"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)"/, m)) {
        rep = m[1]
      }
      if (match($0, /"skipReason"[[:space:]]*:[[:space:]]*"(invalid-version|unversioned-reference|disabled)"/, m)) {
        reason = m[1]
        printf("skipReason=%s\tpackageFile=%s\treplaceString=%s\n", reason, pkg, rep)
      }
    }
  ' "${LOG_FILE}" | sort -u

  echo ""
  echo "[unsupported or unresolved references]"
  rg -n "unsupported/unversioned value|Could not determine new digest for update|Found no results from datasource that look like a version|No satisfying versions" "${LOG_FILE}" || true

  echo ""
  echo "[consistency mismatch: likely not-updated due to dep-count check]"
  cat "${tmp_mismatch_with_refs}"

  echo ""
  echo "[branches with update failure]"
  awk '
    {
      if (match($0, /Error updating branch: update failure.*branch=([^)]*)\)/, m)) {
        printf("updateFailure=true\tbranch=%s\n", m[1])
      }
    }
  ' "${LOG_FILE}" | sort -u
} > "${UNCHANGED_REPORT_FILE}"

changed_count="$(wc -l < "${tmp_changed}")"
unchanged_count="$(grep -c "^skipReason=" "${UNCHANGED_REPORT_FILE}" || true)"
mismatch_count="$(grep -c "^consistencyMismatch=true" "${UNCHANGED_REPORT_FILE}" || true)"

# Keep concise console summary for test script output.
echo "==> Changed references report: ${CHANGED_REPORT_FILE} (${changed_count} entries)"
echo "==> Unchanged references report: ${UNCHANGED_REPORT_FILE} (${unchanged_count} skipReason entries)"
if [[ "${mismatch_count}" -gt 0 ]]; then
  echo "==> Consistency mismatch detected: ${mismatch_count} branch/packageFile case(s)"
  echo "==> Related action/workflow references for mismatch cases:"
  awk -F'\t' '
    {
      branch = ""
      pkg = ""
      refsList = "unknown"
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^branch=/) {
          branch = substr($i, length("branch=") + 1)
        } else if ($i ~ /^packageFile=/) {
          pkg = substr($i, length("packageFile=") + 1)
        } else if ($i ~ /^references=/) {
          refsList = substr($i, length("references=") + 1)
        }
      }
      printf("   - branch=%s packageFile=%s references=%s\n", branch, pkg, refsList)
    }
  ' "${tmp_mismatch_with_refs}"
fi
