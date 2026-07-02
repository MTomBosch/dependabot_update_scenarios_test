#!/usr/bin/env bash
# Renovate update-scenario verification test
#
# Runs Renovate in github and dry-run full mode, then checks for every action/workflow
# reference whether the expected update would be done by checking the resulting json log file.
#
# HINT: If Renovate was already run in non-dry-run mode then some PRs already have been created that
#       Renovate is considering even in full dry run mode. To simulate a fresh Renovate run, simply
#       create a new branch and let Renovate run on that branch. Then no related PR will be found
#       for that branch and Renovate will simulate the creation of PRs for that branch in dry-run mode.
#
# Usage:
#   ./test_renovate_updates_dry_run_full.sh [log_file_path]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SCRIPT_NAME="$(basename "$0")"
SCRIPT_NAME_NO_SUFFIX="${SCRIPT_NAME%.*}"

LOG_FILE="${1:-${SCRIPT_NAME_NO_SUFFIX}.json.log}"
if [[ "${LOG_FILE}" != /* ]]; then
  LOG_FILE="${SCRIPT_DIR}/${LOG_FILE}"
fi

rm -f ./*.log

# Step 1: Run Renovate

echo "==> Running Renovate (--dry-run full, --log-format json)..."

export RENOVATE_BASE_BRANCHES="test_renovate_full_dry_run_mode"

"${SCRIPT_DIR}/run_renovate.sh" \
  --mode-github-org mtombosch \
  --dry-run full \
  --log-file  "${LOG_FILE}" \
  --log-format pretty \
  --log-level info \
  --include-pattern "mtombosch/dependabot_update_scenarios_test" \
  --config ./.github/renovate.json5

# Step 2: Materialize per-PR file snapshots and patches
"${SCRIPT_DIR}/apply_renovate_dry_run_changes.sh" "${LOG_FILE}"

# Step 3: Analyze changed/unchanged references and root causes
"${SCRIPT_DIR}/analyze_renovate_dry_run_references.sh" "${LOG_FILE}"

# Step 4: Validate expected update row pairs in generated patches
"${SCRIPT_DIR}/validate_pr_updates.sh"
