#!/usr/bin/env bash
# Renovate update-scenario verification test
#
# Runs Renovate in dry-run lookup mode, then checks for every action/workflow
# reference whether the expected update (or intentional non-update) is present
# in the JSON output.
#
# Usage:
#   ./test_renovate_lookup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/renovate_lookup_test.json.log"

# ─── Step 1: Run Renovate ────────────────────────────────────────────────────
echo "==> Running Renovate (--dry-run lookup, --log-format json)..."
"${SCRIPT_DIR}/run_renovate.sh" \
  --mode-local \
  --dry-run lookup \
  --log-file  "${LOG_FILE}" \
  --log-format json

[[ -f "${LOG_FILE}" ]] || { echo "ERROR: log file '${LOG_FILE}' was not created." >&2; exit 1; }

# ─── Step 2: Extract packageFiles data from NDJSON log ───────────────────────
echo "==> Extracting 'packageFiles with updates' from log..."
# The log may contain a non-JSON preamble line, so use grep to isolate the
# target NDJSON line before handing it to jq.
PKG_DATA=$(grep '"packageFiles with updates"' "${LOG_FILE}" | jq '.config')

[[ "${PKG_DATA}" != "null" && -n "${PKG_DATA}" ]] || {
  echo "ERROR: Could not find 'packageFiles with updates' entry in the log." >&2
  exit 1
}

# ─── Step 3: Test helpers ────────────────────────────────────────────────────
PASS=0
FAIL=0

_pass() { printf "  \033[32mPASS\033[0m  %s\n" "$*"; (( PASS++ )) || true; }
_fail() { printf "  \033[31mFAIL\033[0m  %s\n" "$*"; (( FAIL++ )) || true; }

# Collect all dep objects matching a replaceString across all package file
# entries for the given manager.  Each returned object includes a synthetic
# "packageFile" field so callers can report which file failed.
_deps() {
  # $1 = manager key ("github-actions" or "regex")
  # $2 = replaceString to match
  echo "${PKG_DATA}" | jq -c \
    --arg m  "$1" \
    --arg rs "$2" \
    '[.[$m][]? | .packageFile as $pf | .deps[]? | select(.replaceString == $rs) | . + {packageFile: $pf}]'
}

# Assert: EVERY dep instance matching the replaceString has a non-major update
# with the exact expected newValue and newDigest.
assert_has_non_major_update() {
  local manager="$1" rs="$2" exp_value="$3" exp_digest="$4" desc="$5"
  local result
  result=$(
    _deps "${manager}" "${rs}" | jq -r \
      --arg ev "${exp_value}" \
      --arg ed "${exp_digest}" '
      ( . | length ) as $total |
      if $total == 0 then "no-match"
      else
        [ .[] |
          (.packageFile // "?") as $pf |
          ( [ .updates[]? |
              select(
                .bucket == "non-major" and
                (.newValue  // "") == $ev and
                (.newDigest // "") == $ed
              )
            ] | length > 0
          ) as $ok |
          {pf: $pf, ok: $ok}
        ] as $checks |
        if all($checks[]; .ok) then "ok:\($total)"
        else
          "failed-in:\([ $checks[] | select(.ok == false) | .pf ] | join(","))"
        end
      end'
  )
  if [[ "${result}" == ok:* ]]; then
    local n="${result#ok:}"
    _pass "${desc}  →  ${exp_value}  @  ${exp_digest}  (${n} instance(s) verified)"
  else
    _fail "${desc}  [expected ${exp_value} @ ${exp_digest} | ${result}]"
  fi
}

# Assert: dep has NO update in the "non-major" bucket.
# Covers both "skipped" refs and refs where Renovate found no applicable release.
assert_no_non_major_update() {
  local manager="$1" rs="$2" desc="$3"
  local count
  count=$(
    _deps "${manager}" "${rs}" | jq -r '
      [.[] | .updates[]? | select(.bucket == "non-major")] | length'
  )
  if (( count == 0 )); then
    _pass "${desc}"
  else
    _fail "${desc}  [expected NO non-major update, found ${count}]"
  fi
}

# Assert: dep has a non-empty skipReason field (Renovate deliberately skips it).
assert_skipped() {
  local manager="$1" rs="$2" desc="$3"
  local reason
  reason=$(
    _deps "${manager}" "${rs}" | jq -r '
      first(.[] | select((.skipReason // "") != "") | .skipReason) // "none"'
  )
  if [[ "${reason}" != "none" ]]; then
    _pass "${desc}  (skipReason: ${reason})"
  else
    _fail "${desc}  [expected skipReason to be set]"
  fi
}

# ─── Step 4: Test cases ──────────────────────────────────────────────────────
GA="github-actions"
RX="regex"

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo " github-actions manager – references that SHOULD receive a non-major update"
echo "════════════════════════════════════════════════════════════════════════════"

assert_has_non_major_update "${GA}" \
  "actions/setup-node@v3" \
  "v3.9.1" \
  "3235b876344d2a9aa001b8d1453c930bba69e610" \
  "actions/setup-node@v3  → latest compatible v3.x.y"

assert_has_non_major_update "${GA}" \
  "actions/cache@1bd1e32a3bdc45362d1e726936510720a7c30a57 # v4.2.0" \
  "v4.3.0" \
  "0057852bfaa89a56745cba8c7296529d2fc39830" \
  "actions/cache (pinned SHA, # v4.2.0)  → latest compatible v4.x"

assert_has_non_major_update "${GA}" \
  "actions/cache@1bd1e32a3bdc45362d1e726936510720a7c30a57 # 4.2.0" \
  "4.3.0" \
  "0057852bfaa89a56745cba8c7296529d2fc39830" \
  "actions/cache (pinned SHA, # 4.2.0 without 'v')  → latest compatible v4.x"

assert_has_non_major_update "${GA}" \
  "actions/cache@1bd1e32a3bdc45362d1e726936510720a7c30a57 # v4" \
  "v4.3.0" \
  "0057852bfaa89a56745cba8c7296529d2fc39830" \
  "actions/cache (pinned SHA, # v4 major-only comment)  → latest compatible v4.x"

assert_has_non_major_update "${GA}" \
  "actions/checkout@v6.0.0" \
  "v6.0.3" \
  "df4cb1c069e1874edd31b4311f1884172cec0e10" \
  "actions/checkout@v6.0.0  → latest compatible v6.x patch"

echo ""
echo "══════════════════════════════════════════════════════════════════════════"
echo " github-actions manager – references with NO applicable non-major update"
echo " (non-existent tag or branch/digest-only references)"
echo "══════════════════════════════════════════════════════════════════════════"

assert_no_non_major_update "${GA}" \
  "actions/cache@1bd1e32a3bdc45362d1e726936510720a7c30a57 # v4.7.12" \
  "actions/cache # v4.7.12  (non-existent tag → no non-major update found)"

assert_no_non_major_update "${GA}" \
  "actions/checkout@main" \
  "actions/checkout@main  (branch ref → only pinDigest, no non-major)"

assert_no_non_major_update "${GA}" \
  "mtombosch/cicd-workflows/.github/workflows/bzlmod-lock-check.yml@main" \
  "mtombosch/cicd-workflows@main  (branch ref → only pinDigest, no non-major)"

assert_no_non_major_update "${GA}" \
  "actions/reusable-workflows/.github/workflows/basic-validation.yml@main" \
  "actions/reusable-workflows@main  (branch ref → only pinDigest, no non-major)"

assert_no_non_major_update "${GA}" \
  "actions/reusable-workflows/.github/workflows/basic-validation.yml@95d9656793415e47f574f7967f3850ea3bf5a7ed # v1.0.0" \
  "actions/reusable-workflows@SHA # v1.0.0  (repo has no semver tags → no update)"

assert_no_non_major_update "${GA}" \
  "eclipse-score/cicd-workflows/.github/workflows/docs.yml@f4c434fa877c0f1ee98425fc3d3ccb0b24e5c77f # main" \
  "eclipse-score/cicd-workflows@SHA # main  (non-semver comment → only digest update, no non-major)"

echo ""
echo "══════════════════════════════════════════════════════════════════════════"
echo " github-actions manager – references SKIPPED (unversioned or unsupported)"
echo "══════════════════════════════════════════════════════════════════════════"

assert_skipped "${GA}" \
  "actions/checkout@8ade135a41bc03ea155e62e844d188df1ea18608" \
  "actions/checkout@SHA  (no version comment → unversioned-reference)"

assert_skipped "${GA}" \
  "mtombosch/cicd-actions/inter-repo-access@51883d9cd772bee5b7d139a2e6ffd8aeabca4224" \
  "mtombosch/cicd-actions@SHA  (no version comment → unversioned-reference)"

assert_skipped "${GA}" \
  "mtombosch/cicd-workflows/.github/workflows/copyright.yml@a2885534f75cf360ecb1b3c589778846bcd4e170" \
  "mtombosch/cicd-workflows/copyright@SHA  (no comment → unversioned-reference)"

assert_skipped "${GA}" \
  "actions/reusable-workflows/.github/workflows/basic-validation.yml@95d9656793415e47f574f7967f3850ea3bf5a7ed" \
  "actions/reusable-workflows@SHA  (comment 'main' stripped → unversioned-reference)"

echo ""
echo "════════════════════════════════════════════════════════════════════════════════════════"
echo " github-actions manager – prefix based tag refs DISABLED (handled by custom.regex only)"
echo "════════════════════════════════════════════════════════════════════════════════════════"

assert_skipped "${GA}" \
  "mtombosch/dependabot_update_scenarios_test/.github/actions/dummy-composite@150be11f8e18450c38116b01268b2b7119b87931 # dummy-composite/v1.0.0" \
  "dummy-composite (pinned SHA + path-prefixed tag) → disabled in github-actions manager"

assert_skipped "${GA}" \
  "mtombosch/dependabot_update_scenarios_test/.github/actions/dummy-composite@dummy-composite/v1.0.0" \
  "dummy-composite (tag-as-ref) → disabled in github-actions manager"

assert_skipped "${GA}" \
  "mtombosch/dependabot_update_scenarios_test/.github/workflows/dummy_reusable_workflow.yml@150be11f8e18450c38116b01268b2b7119b87931 # dummy-workflow/v1.1.0" \
  "dummy_reusable_workflow (pinned SHA + path-prefixed tag) → disabled in github-actions manager"

assert_skipped "${GA}" \
  "mtombosch/dependabot_update_scenarios_test/.github/workflows/dummy_reusable_workflow.yml@dummy-workflow/v1.1.0" \
  "dummy_reusable_workflow (tag-as-ref) → disabled in github-actions manager"

echo ""
echo "══════════════════════════════════════════════════════════════════════════════"
echo " custom.regex manager – prefix based tag refs MUST receive a non-major update"
echo " (covers both .github/workflows/ and .github/actions/ files)"
echo "══════════════════════════════════════════════════════════════════════════════"

assert_has_non_major_update "${RX}" \
  "uses: mtombosch/dependabot_update_scenarios_test/.github/actions/dummy-composite@150be11f8e18450c38116b01268b2b7119b87931 # dummy-composite/v1.0.0" \
  "dummy-composite/v1.2.0" \
  "49940a8c8dd7d60fc5a93c7e69b201c0e6af1d40" \
  "custom.regex: dummy-composite (pinned SHA) → update to latest dummy-composite/v1.x"

assert_has_non_major_update "${RX}" \
  "uses: mtombosch/dependabot_update_scenarios_test/.github/actions/dummy-composite@dummy-composite/v1.0.0" \
  "dummy-composite/v1.2.0" \
  "49940a8c8dd7d60fc5a93c7e69b201c0e6af1d40" \
  "custom.regex: dummy-composite (tag-as-ref) → update to latest dummy-composite/v1.x"

assert_has_non_major_update "${RX}" \
  "uses: mtombosch/dependabot_update_scenarios_test/.github/workflows/dummy_reusable_workflow.yml@150be11f8e18450c38116b01268b2b7119b87931 # dummy-workflow/v1.1.0" \
  "dummy-workflow/v1.3.0" \
  "49940a8c8dd7d60fc5a93c7e69b201c0e6af1d40" \
  "custom.regex: dummy_reusable_workflow (pinned SHA) → update to latest dummy-workflow/v1.x"

assert_has_non_major_update "${RX}" \
  "uses: mtombosch/dependabot_update_scenarios_test/.github/workflows/dummy_reusable_workflow.yml@dummy-workflow/v1.1.0" \
  "dummy-workflow/v1.3.0" \
  "49940a8c8dd7d60fc5a93c7e69b201c0e6af1d40" \
  "custom.regex: dummy_reusable_workflow (tag-as-ref) → update to latest dummy-workflow/v1.x"

# ─── Step 5: Summary ─────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════════════════════"
printf " Summary:  \033[32mPASS %d\033[0m  /  \033[31mFAIL %d\033[0m  /  TOTAL %d\n" \
  "${PASS}" "${FAIL}" "$(( PASS + FAIL ))"
echo "══════════════════════════════════════════════════════════════════════════"
echo ""

if (( FAIL > 0 )); then
  echo "Some tests failed." >&2
  exit 1
fi
echo "All tests passed."
