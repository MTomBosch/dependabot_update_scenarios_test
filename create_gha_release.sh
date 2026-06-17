#!/usr/bin/env bash
# create_gha_release.sh — Create a GitHub release based on commits that touched
# specific files since a previous release.
#
# Usage:
#   create_gha_release.sh \
#     --files <patterns>          \
#     --next-release <tag>        \
#     [--previous-release <tag>]  \
#     [--include-merge-commits]   \
#     [--branch <name>]
#
# Arguments:
#   --files <patterns>
#       Required. Comma- or newline-separated glob patterns (git pathspecs) for
#       the files whose commit history should be included in the release notes.
#       Examples:  .github/workflows/*.yml
#                  ".github/workflows/*.yml,.github/actions/**"
#       Note: glob wildcards are handled natively by git. POSIX regular
#       expressions are NOT supported.
#
#   --next-release <tag>
#       Required. The git tag and GitHub release name to create. The tag is
#       applied to the current HEAD commit of the repository.
#
#   --previous-release <tag>
#       Optional. Git tag marking the start of the commit range (exclusive).
#       Commits from this tag up to HEAD are examined. Leave unset to examine
#       all commits reachable from HEAD. If the tag does not exist git will
#       abort with an error.
#
#   --include-merge-commits
#       Optional flag. When present, merge commits are included in the release
#       notes. When absent (default), merge commits are excluded (--no-merges
#       is passed to git log).
#
#   --branch <name>
#       Optional. Override the branch name used to decide whether to actually
#       create the release (only happens on "main"). When omitted the current
#       branch is detected automatically via git.
#
# Environment variables:
#   GITHUB_TOKEN   Required. Used to authenticate the gh CLI tool.
#
# Prerequisites:
#   git, gh (GitHub CLI), openssl
#
# Behaviour:
#   On the "main" branch:  identifies the relevant commits, creates a GitHub
#                          release and tag on the current HEAD.
#   On any other branch:   identifies the relevant commits and prints the
#                          release notes to stdout (dry-run; nothing is created).

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

usage() {
  sed -n '/^# Usage:/,/^[^#]/{ /^[^#]/d; s/^# \{0,3\}//; p }' "$0"
  exit 1
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------

[[ -n "${GITHUB_TOKEN:-}" ]] || die "Environment variable GITHUB_TOKEN is not set."

command -v git   >/dev/null 2>&1 || die "'git' is not installed or not on PATH."
command -v gh    >/dev/null 2>&1 || die "'gh' (GitHub CLI) is not installed or not on PATH."
command -v openssl >/dev/null 2>&1 || die "'openssl' is not installed or not on PATH."

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

ACTION_WORKFLOW_FILES=""
PREVIOUS_RELEASE=""
NEXT_RELEASE=""
INCLUDE_MERGE_COMMITS="false"
BRANCH_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --files)
      [[ $# -ge 2 ]] || die "--files requires a value."
      ACTION_WORKFLOW_FILES="$2"
      shift 2
      ;;
    --previous-release)
      [[ $# -ge 2 ]] || die "--previous-release requires a value."
      PREVIOUS_RELEASE="$2"
      shift 2
      ;;
    --next-release)
      [[ $# -ge 2 ]] || die "--next-release requires a value."
      NEXT_RELEASE="$2"
      shift 2
      ;;
    --include-merge-commits)
      INCLUDE_MERGE_COMMITS="true"
      shift
      ;;
    --branch)
      [[ $# -ge 2 ]] || die "--branch requires a value."
      BRANCH_OVERRIDE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$ACTION_WORKFLOW_FILES" ]] || die "--files is required."
[[ -n "$NEXT_RELEASE"          ]] || die "--next-release is required."

# ---------------------------------------------------------------------------
# Authenticate gh CLI
# ---------------------------------------------------------------------------

gh auth login --with-token <<< "$GITHUB_TOKEN" 2>/dev/null || true
# Verify authentication is working (also surfaces clear errors for bad tokens).
gh auth status >/dev/null

# ---------------------------------------------------------------------------
# Determine current branch
# ---------------------------------------------------------------------------

if [[ -n "$BRANCH_OVERRIDE" ]]; then
  CURRENT_BRANCH="$BRANCH_OVERRIDE"
  echo "Branch override specified: ${CURRENT_BRANCH}"
else
  # Try symbolic ref first (works on normal checkouts).
  CURRENT_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null)" || true

  if [[ -z "$CURRENT_BRANCH" ]]; then
    # Detached HEAD — try the GitHub Actions ref env var as a fallback.
    if [[ -n "${GITHUB_REF_NAME:-}" ]]; then
      CURRENT_BRANCH="$GITHUB_REF_NAME"
      echo "Detached HEAD detected; using GITHUB_REF_NAME: ${CURRENT_BRANCH}"
    else
      die "Could not determine the current branch (detached HEAD and GITHUB_REF_NAME is not set). Use --branch to override."
    fi
  fi
  echo "Detected branch: ${CURRENT_BRANCH}"
fi

# ---------------------------------------------------------------------------
# Parse file patterns
# ---------------------------------------------------------------------------

PATTERNS=()
while IFS= read -r line; do
  IFS=',' read -ra parts <<< "$line"
  for part in "${parts[@]}"; do
    part="${part#"${part%%[![:space:]]*}"}"   # ltrim
    part="${part%"${part##*[![:space:]]}"}"   # rtrim
    [[ -n "$part" ]] && PATTERNS+=("$part")
  done
done <<< "$ACTION_WORKFLOW_FILES"

[[ "${#PATTERNS[@]}" -gt 0 ]] || die "No file patterns resolved from --files."

# ---------------------------------------------------------------------------
# Build git log arguments
# ---------------------------------------------------------------------------

RANGE_ARGS=()
if [[ -n "$PREVIOUS_RELEASE" ]]; then
  RANGE_ARGS=("${PREVIOUS_RELEASE}..HEAD")
fi

MERGE_ARGS=()
if [[ "$INCLUDE_MERGE_COMMITS" != "true" ]]; then
  MERGE_ARGS=(--no-merges)
fi

echo "--- git log command ---"
echo "git log --format='- %s' ${MERGE_ARGS[*]+"${MERGE_ARGS[*]}"} ${RANGE_ARGS[*]+"${RANGE_ARGS[*]}"} -- ${PATTERNS[*]}"
echo "-----------------------"

# ---------------------------------------------------------------------------
# Collect release notes
# ---------------------------------------------------------------------------

RELEASE_NOTES="$(git log --format="- %s" "${MERGE_ARGS[@]}" "${RANGE_ARGS[@]}" -- "${PATTERNS[@]}")"

if [[ -z "$RELEASE_NOTES" ]]; then
  RELEASE_NOTES="No matching changes found."
fi

# ---------------------------------------------------------------------------
# Create release (main) or print notes (other branches)
# ---------------------------------------------------------------------------

HEAD_SHA="$(git rev-parse HEAD)"

if [[ "$CURRENT_BRANCH" == "main" ]]; then
  echo "On main branch — creating GitHub release '${NEXT_RELEASE}' at ${HEAD_SHA}."
  echo ""
  echo "Release notes:"
  echo "${RELEASE_NOTES}"
  echo ""
  GH_TOKEN="$GITHUB_TOKEN" gh release create "$NEXT_RELEASE" \
    --title "$NEXT_RELEASE" \
    --notes "$RELEASE_NOTES" \
    --target "$HEAD_SHA"
  echo "Release '${NEXT_RELEASE}' created successfully."
else
  echo "On branch '${CURRENT_BRANCH}' (not main) — dry run; no release or tag will be created."
  echo ""
  echo "Release that would be created: ${NEXT_RELEASE}"
  echo ""
  echo "Release notes:"
  echo "${RELEASE_NOTES}"
fi
