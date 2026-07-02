#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PATCH_FILES=()
while IFS= read -r file; do
  PATCH_FILES+=("$file")
done < <(find "${SCRIPT_DIR}" -type f -path "*/PR_*/*.patch" | sort)

if (( ${#PATCH_FILES[@]} == 0 )); then
  echo "ERROR: No patch files found under PR_* folders"
  echo "  search_root: ${SCRIPT_DIR}"
  exit 1
fi

extract_pairs() {
  local patch_file="$1"
  awk '
    BEGIN { waiting = 0 }
    /^-/ {
      if ($0 ~ /^--- /) next
      if ($0 ~ /^-[[:space:]]*uses:[[:space:]]+/) {
        old = substr($0, 2)
        waiting = 1
        next
      }
    }
    /^\+/ {
      if ($0 ~ /^\+\+\+ /) next
      if (waiting && $0 ~ /^\+[[:space:]]*uses:[[:space:]]+/) {
        newv = substr($0, 2)
        printf("%s\t%s\n", old, newv)
        waiting = 0
        next
      }
    }
  ' "$patch_file"
}

trim_leading_ws() {
  local value="$1"
  printf '%s' "${value#"${value%%[![:space:]]*}"}"
}

declare -A ACTUAL_NEW_BY_FILE_AND_OLD=()

for patch_file in "${PATCH_FILES[@]}"; do
  while IFS=$'\t' read -r old_line new_line; do
    if [[ -z "$old_line" ]]; then
      continue
    fi
    normalized_old="$(trim_leading_ws "$old_line")"
    normalized_new="$(trim_leading_ws "$new_line")"
    key="$patch_file|$normalized_old"
    ACTUAL_NEW_BY_FILE_AND_OLD[$key]="$normalized_new"
  done < <(extract_pairs "$patch_file")
done

failures=0
tests=0

validate_uses_ref_update() {
  local uses_path="$1"
  local previous_ref="$2"
  local expected_updated_ref="$3"
  local expected_old
  local expected_new

  expected_old="$(trim_leading_ws "uses: ${uses_path}@${previous_ref}")"
  expected_new="$(trim_leading_ws "uses: ${uses_path}@${expected_updated_ref}")"
  tests=$((tests + 1))

  for patch_file in "${PATCH_FILES[@]}"; do
    key="$patch_file|$expected_old"
    if [[ -n "${ACTUAL_NEW_BY_FILE_AND_OLD[$key]+x}" ]]; then
      actual_new="${ACTUAL_NEW_BY_FILE_AND_OLD[$key]}"
      if [[ "$actual_new" != "$expected_new" ]]; then
        echo "ERROR: Update pair mismatch"
        echo "  file: ${patch_file#"${SCRIPT_DIR}"/}"
        echo "  previous:         $expected_old"
        echo "  expected_updated: $expected_new"
        echo "  actual_updated:   $actual_new"
        failures=$((failures + 1))
      fi
    fi
  done
}

validate_no_uses_ref_update() {
  local uses_path="$1"
  local unchanged_ref="$2"
  local expected_old

  expected_old="$(trim_leading_ws "uses: ${uses_path}@${unchanged_ref}")"
  tests=$((tests + 1))

  for patch_file in "${PATCH_FILES[@]}"; do
    key="$patch_file|$expected_old"
    if [[ -n "${ACTUAL_NEW_BY_FILE_AND_OLD[$key]+x}" ]]; then
      actual_new="${ACTUAL_NEW_BY_FILE_AND_OLD[$key]}"
      echo "ERROR: Unexpected update for reference that should remain unchanged"
      echo "  file: ${patch_file#"${SCRIPT_DIR}"/}"
      echo "  expected_unchanged: $expected_old"
      echo "  unexpected_updated: $actual_new"
      failures=$((failures + 1))
    fi
  done
}

# Expected update checks captured from the current generated patch set.
validate_uses_ref_update "actions/cache" "1bd1e32a3bdc45362d1e726936510720a7c30a57 # v4.2.0" "0057852bfaa89a56745cba8c7296529d2fc39830 # v4.3.0"
validate_uses_ref_update "actions/cache" "1bd1e32a3bdc45362d1e726936510720a7c30a57 # 4.2.0" "0057852bfaa89a56745cba8c7296529d2fc39830 # 4.3.0"
validate_uses_ref_update "actions/cache" "1bd1e32a3bdc45362d1e726936510720a7c30a57 # v4" "0057852bfaa89a56745cba8c7296529d2fc39830 # v4.3.0"
validate_uses_ref_update "actions/checkout" "v6.0.0" "df4cb1c069e1874edd31b4311f1884172cec0e10 # v6.0.3"
validate_uses_ref_update "actions/checkout" "main" "4f1f4aec02e41874fa0262ea8ff5172d7978ad1e # main"
validate_uses_ref_update "actions/setup-node" "v3" "3235b876344d2a9aa001b8d1453c930bba69e610 # v3.9.1"
validate_uses_ref_update "actions/reusable-workflows/.github/workflows/basic-validation.yml" "main" "09976383aa8780d306ee271bd21bb77a54fad474 # main"
validate_uses_ref_update "mtombosch/cicd-workflows/.github/workflows/bzlmod-lock-check.yml" "main" "af347722c7ae3ed85518895c11268d96ac728f62 # main"

# Validate path prefix based tags
validate_uses_ref_update "mtombosch/dependabot_update_scenarios_test/.github/workflows/dummy_reusable_workflow.yml" "dummy-workflow/v1.1.0" "49940a8c8dd7d60fc5a93c7e69b201c0e6af1d40 # dummy-workflow/v1.3.0"
validate_uses_ref_update "mtombosch/dependabot_update_scenarios_test/.github/workflows/dummy_reusable_workflow.yml" "150be11f8e18450c38116b01268b2b7119b87931 # dummy-workflow/v1.1.0" "49940a8c8dd7d60fc5a93c7e69b201c0e6af1d40 # dummy-workflow/v1.3.0"
validate_uses_ref_update "mtombosch/dependabot_update_scenarios_test/.github/actions/dummy-composite" "dummy-composite/v1.0.0" "49940a8c8dd7d60fc5a93c7e69b201c0e6af1d40 # dummy-composite/v1.2.0"
validate_uses_ref_update "mtombosch/dependabot_update_scenarios_test/.github/actions/dummy-composite" "150be11f8e18450c38116b01268b2b7119b87931 # dummy-composite/v1.0.0" "49940a8c8dd7d60fc5a93c7e69b201c0e6af1d40 # dummy-composite/v1.2.0"

# Expected no-update checks captured from skipReason=unversioned-reference in the dry-run log.
validate_no_uses_ref_update "actions/cache" "1bd1e32a3bdc45362d1e726936510720a7c30a57 # v4.7.12"
validate_no_uses_ref_update "actions/checkout" "8ade135a41bc03ea155e62e844d188df1ea18608"
validate_no_uses_ref_update "actions/reusable-workflows/.github/workflows/basic-validation.yml" "95d9656793415e47f574f7967f3850ea3bf5a7ed # main - some arbitrary comment"
validate_no_uses_ref_update "actions/reusable-workflows/.github/workflows/basic-validation.yml" "95d9656793415e47f574f7967f3850ea3bf5a7ed # v1.0.0"
validate_no_uses_ref_update "mtombosch/cicd-actions/inter-repo-access" "51883d9cd772bee5b7d139a2e6ffd8aeabca4224"
validate_no_uses_ref_update "mtombosch/cicd-workflows/.github/workflows/copyright.yml" "a2885534f75cf360ecb1b3c589778846bcd4e170"

if (( failures > 0 )); then
  echo "validate_pr_updates: FAILED (${failures} mismatch(es), ${tests} test(s))"
  exit 1
fi

echo "validate_pr_updates: OK (${tests} test(s))"
