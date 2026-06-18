#!/usr/bin/env bash
set -euo pipefail

# ─── Exit codes ──────────────────────────────────────────────────────────────
readonly EXIT_USAGE=2                       # bad / missing argument
readonly EXIT_NO_TOKEN=3                    # GITHUB_TOKEN not set
readonly EXIT_NO_GIT=4                      # git not found
readonly EXIT_NO_GH=5                       # gh CLI not found
readonly EXIT_NO_BRANCH=7                   # cannot determine current branch
readonly EXIT_PREVIOUS_TAG_NOT_FOUND=8      # --previous-release tag does not exist
readonly EXIT_CREATE_TAG_FAILED=9           # failed to create the release tag
readonly EXIT_CREATE_RELEASE_FAILED=10      # failed to create the GitHub release
readonly EXIT_RELEASE_EXISTS=11             # GitHub release already exists
readonly EXIT_EMPTY_RELEASE_NOTES=12        # no matching commits found for release notes
readonly EXIT_NEXT_RELEASE_TAG_NOT_FOUND=13 # --notes-from-tag: NEXT_RELEASE tag does not exist

# ---------------------------------------------------------------------------
# Globals (populated by parse_args)
# ---------------------------------------------------------------------------
ACTION_WORKFLOW_FILES=""
PREVIOUS_RELEASE=""
NEXT_RELEASE=""
INCLUDE_MERGE_COMMITS="false"
DRY_RUN="false"
DRAFT="false"
BRANCH_OVERRIDE=""
NOTES_FROM_TAG="false"

# Populated by subsequent functions
CURRENT_BRANCH=""
PATTERNS=()
RANGE_ARGS=()
MERGE_ARGS=()
RELEASE_NOTES=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

usage() {
  cat <<'EOF'
Create a GitHub release based on commits that touched specific files since a
previous release.

Usage:
  create_gha_release.sh \
    --next-release <tag>                              \
    { --files <patterns> | --notes-from-tag }         \
    [--previous-release <tag>]                        \
    [--include-merge-commits]                         \
    [--dry-run]                                       \
    [--draft]                                         \
    [--branch <name>]

Arguments:
  --files <patterns>
      Required unless --notes-from-tag is used. Mutually exclusive with
      --notes-from-tag. Comma- or newline-separated glob patterns (git
      pathspecs) for the files whose commit history should be included in the
      release notes.
      Examples:  .github/workflows/*.yml
                 ".github/workflows/*.yml,.github/actions/**"
      Note: glob wildcards are handled natively by git. POSIX regular
      expressions are NOT supported.

  --next-release <tag>
      Required. The git tag and GitHub release name to create. When used with
      --notes-from-tag, the tag must already exist as an annotated git tag.
      Otherwise the tag is applied to the current HEAD commit.

  --previous-release <tag>
      Optional. Git tag marking the start of the commit range (exclusive).
      Commits from this tag up to HEAD are examined. Leave unset to examine
      all commits reachable from HEAD. If the tag does not exist git will
      abort with an error.
      Shall not be set if --notes-from-tag is used.

  --include-merge-commits
      Optional flag. When present, merge commits are included in the release
      notes. When absent (default), merge commits are excluded (--no-merges
      is passed to git log).
      Shall not be set if --notes-from-tag is used.

  --dry-run
      Optional flag. When present, behaves as if the current branch is not
      "main": prints what would be created but does not create the tag or the
      GitHub release.

  --draft
      Optional flag. When present, the GitHub release is created as a draft
      (not published). Has no effect in dry-run mode or on non-main branches.

  --branch <name>
      Optional. Override the branch name used to decide whether to actually
      create the release (only happens on "main"). When omitted the current
      branch is detected automatically via git.

  --notes-from-tag
      Optional flag. When present, release notes are taken from the annotated
      git tag message of --next-release instead of being generated from commit
      history. The tag must already exist as an annotated git tag. Mutually
      exclusive with --files, --previous-release, and --include-merge-commits.

  -h, --help  Show this help

Environment variables:
  GITHUB_TOKEN   Required. Used to authenticate the gh CLI tool.

Examples:
  # Create only release notes for first release for all actions
  GITHUB_TOKEN=*** ./create_gha_release.sh --files .github/actions/** --next-release v1.0.0 --dry-run

  # Create first release for all actions
  GITHUB_TOKEN=*** ./create_gha_release.sh --files .github/actions/** --next-release v1.0.0

  # Create new major release for one action
  GITHUB_TOKEN=*** ./create_gha_release.sh --files .github/actions/dummy-composite --previous-release dummy-composite/v1.2.0 --next-release dummy-composite/v2.0.0

  # Create a release using the annotated tag's message as release notes
  GITHUB_TOKEN=*** ./create_gha_release.sh --notes-from-tag --next-release v2.0.0
EOF
  exit 0
}

# ::endgroup:: is only meaningful inside a GitHub Actions workflow run.
# On a local terminal it would just print as noise, so suppress it.
_log_gha_endgroup() {
  if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
    echo "::endgroup::"
  fi
}

# ---------------------------------------------------------------------------
# Functions
# ---------------------------------------------------------------------------

validate_prerequisites() {
  echo "::group::Tool versions"
  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    echo "ERROR: Environment variable GITHUB_TOKEN is not set."
    _log_gha_endgroup
    exit $EXIT_NO_TOKEN
  fi
  if ! command -v git >/dev/null 2>&1; then
    echo "ERROR: 'git' is not installed or not on PATH."
    _log_gha_endgroup
    exit $EXIT_NO_GIT
  fi
  echo "git: $(git --version)"
  if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: 'gh' (GitHub CLI) is not installed or not on PATH."
    _log_gha_endgroup
    exit $EXIT_NO_GH
  fi
  echo "gh: $(gh --version | head -1)"
  _log_gha_endgroup
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --files)
        if [[ $# -lt 2 ]]; then echo "ERROR: --files requires a value."; exit $EXIT_USAGE; fi
        ACTION_WORKFLOW_FILES="$2"
        shift 2
        ;;
      --previous-release)
        if [[ $# -lt 2 ]]; then echo "ERROR: --previous-release requires a value."; exit $EXIT_USAGE; fi
        PREVIOUS_RELEASE="$2"
        shift 2
        ;;
      --next-release)
        if [[ $# -lt 2 ]]; then echo "ERROR: --next-release requires a value."; exit $EXIT_USAGE; fi
        NEXT_RELEASE="$2"
        shift 2
        ;;
      --include-merge-commits)
        INCLUDE_MERGE_COMMITS="true"
        shift
        ;;
      --dry-run)
        DRY_RUN="true"
        shift
        ;;
      --draft)
        DRAFT="true"
        shift
        ;;
      --branch)
        if [[ $# -lt 2 ]]; then echo "ERROR: --branch requires a value."; exit $EXIT_USAGE; fi
        BRANCH_OVERRIDE="$2"
        shift 2
        ;;
      --notes-from-tag)
        NOTES_FROM_TAG="true"
        shift
        ;;
      -h|--help)
        usage
        ;;
      *)
        echo "ERROR: Unknown argument: $1"
        exit $EXIT_USAGE
        ;;
    esac
  done

  if [[ -n "$ACTION_WORKFLOW_FILES" && "$NOTES_FROM_TAG" == "true" ]]; then
    echo "ERROR: --files ('${ACTION_WORKFLOW_FILES}') and --notes-from-tag are mutually exclusive."
    exit $EXIT_USAGE
  fi
  if [[ -n "$PREVIOUS_RELEASE" && "$NOTES_FROM_TAG" == "true" ]]; then
    echo "ERROR: --previous-release ('${PREVIOUS_RELEASE}') and --notes-from-tag are mutually exclusive."
    exit $EXIT_USAGE
  fi
  if [[ "$INCLUDE_MERGE_COMMITS" == "true" && "$NOTES_FROM_TAG" == "true" ]]; then
    echo "ERROR: --include-merge-commits and --notes-from-tag are mutually exclusive."
    exit $EXIT_USAGE
  fi
  if [[ -z "$ACTION_WORKFLOW_FILES" && "$NOTES_FROM_TAG" != "true" ]]; then
    echo "ERROR: --files is required (or use --notes-from-tag to take notes from the tag annotation)."
    exit $EXIT_USAGE
  fi
  if [[ -z "$NEXT_RELEASE" ]]; then
    echo "ERROR: --next-release is required."
    exit $EXIT_USAGE
  fi
}

detect_branch() {
  echo "::group::Detect branch"
  if [[ -n "$BRANCH_OVERRIDE" ]]; then
    CURRENT_BRANCH="$BRANCH_OVERRIDE"
    echo "Branch override specified: ${CURRENT_BRANCH}"
    _log_gha_endgroup
    return
  fi

  # Try symbolic ref first (works on normal checkouts).
  CURRENT_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null)" || true

  if [[ -z "$CURRENT_BRANCH" ]]; then
    # Detached HEAD — try the GitHub Actions ref env var as a fallback.
    if [[ -n "${GITHUB_REF_NAME:-}" ]]; then
      CURRENT_BRANCH="$GITHUB_REF_NAME"
      echo "Detached HEAD detected; using GITHUB_REF_NAME: ${CURRENT_BRANCH}"
    else
      echo "ERROR: Could not determine the current branch (detached HEAD and GITHUB_REF_NAME is not set). Use --branch to override."
      exit $EXIT_NO_BRANCH
    fi
  fi
  echo "Detected branch: ${CURRENT_BRANCH}"
  _log_gha_endgroup
}

resolve_file_patterns() {
  echo "::group::File patterns"
  while IFS= read -r line; do
    IFS=',' read -ra parts <<< "$line"
    for part in "${parts[@]}"; do
      part="${part#"${part%%[![:space:]]*}"}"
      part="${part%"${part##*[![:space:]]}"}"   # rtrim
      if [[ -n "$part" ]]; then PATTERNS+=("$part"); fi
    done
  done <<< "$ACTION_WORKFLOW_FILES"

  if [[ "${#PATTERNS[@]}" -eq 0 ]]; then
    echo "ERROR: No file patterns resolved from --files."
    exit $EXIT_USAGE
  fi
  echo "Resolved ${#PATTERNS[@]} pattern(s): ${PATTERNS[*]}"
  _log_gha_endgroup
}

build_git_log_args() {
  echo "::group::Build git log arguments"
  local upper_bound="HEAD"
  if git rev-parse --verify "refs/tags/${NEXT_RELEASE}" >/dev/null 2>&1; then
    upper_bound="$NEXT_RELEASE"
    echo "Tag '${NEXT_RELEASE}' already exists — using it as upper bound instead of HEAD."
  fi

  if [[ -n "$PREVIOUS_RELEASE" ]]; then
    if ! git rev-parse --verify "refs/tags/${PREVIOUS_RELEASE}" >/dev/null 2>&1; then
      echo "ERROR: Previous release tag '${PREVIOUS_RELEASE}' does not exist in this repository."
      exit $EXIT_PREVIOUS_TAG_NOT_FOUND
    fi
    RANGE_ARGS=("${PREVIOUS_RELEASE}..${upper_bound}")
  else
    # No lower bound — collect all commits from the beginning of the repository.
    RANGE_ARGS=("${upper_bound}")
  fi

  if [[ "$INCLUDE_MERGE_COMMITS" != "true" ]]; then
    MERGE_ARGS=(--no-merges)
  fi

  echo "--- git log command ---"
  echo "git log --format='- %s' ${MERGE_ARGS[*]+"${MERGE_ARGS[*]}"} ${RANGE_ARGS[*]+"${RANGE_ARGS[*]}"} -- ${PATTERNS[*]}"
  echo "-----------------------"
  _log_gha_endgroup
}

log_debug_commits() {
  echo "::group::Show all included and excluded (based on file patterns and merge commits) commits in specified history range"

  # Build a lookup set of full SHAs that touch the file patterns (included).
  declare -A _included_shas
  while IFS= read -r sha; do
    [[ -n "$sha" ]] && _included_shas["$sha"]=1
  done < <(git log --format="%H" "${MERGE_ARGS[@]}" "${RANGE_ARGS[@]}" -- "${PATTERNS[@]}")

  # Walk every commit in the range without any filters so that commits excluded
  # due to the file-pattern filter OR the merge filter appear as [excluded].
  local total=0 included_count=0
  while IFS= read -r line; do
    local full_sha rest short_sha subject marker
    full_sha="${line:0:40}"
    rest="${line:41}"
    short_sha="${rest%% *}"
    subject="${rest#* }"
    if [[ -n "${_included_shas[$full_sha]+x}" ]]; then
      marker="[included]"
      (( included_count++ )) || true
    else
      marker="    [excluded]"
    fi
    echo "  ${marker} ${short_sha} ${subject}"
    (( total++ )) || true
  done < <(git log --format="%H %h %s" "${RANGE_ARGS[@]}")

  echo ""
  echo "  ${included_count} of ${total} commit(s) included."
  _log_gha_endgroup
}

collect_release_notes() {
  echo "::group::Collect commits for release notes"
  local repo_url
  repo_url="$(GH_TOKEN="$GITHUB_TOKEN" gh repo view --json url --jq '.url')"
  RELEASE_NOTES="$(git log --format="- [%h](${repo_url}/commit/%H) %s" "${MERGE_ARGS[@]}" "${RANGE_ARGS[@]}" -- "${PATTERNS[@]}")"

  if [[ -z "$RELEASE_NOTES" ]]; then
    echo "ERROR: No matching commits found for the specified file patterns and commit range. Release notes would be empty."
    _log_gha_endgroup
    exit $EXIT_EMPTY_RELEASE_NOTES
  fi
  echo "Release notes successfully generated."
  _log_gha_endgroup
}

verify_tag_for_notes() {
  echo "::group::Verify tag for release notes"
  if ! git rev-parse --verify "refs/tags/${NEXT_RELEASE}" >/dev/null 2>&1; then
    echo "ERROR: Tag '${NEXT_RELEASE}' does not exist. With --notes-from-tag the tag must already exist as an annotated git tag."
    _log_gha_endgroup
    exit $EXIT_NEXT_RELEASE_TAG_NOT_FOUND
  fi
  echo "Tag '${NEXT_RELEASE}' exists."
  echo ""
  echo "Tag annotation:"
  git show --no-patch "${NEXT_RELEASE}"
  _log_gha_endgroup
}

check_next_release_tag() {
  echo "::group::Check next release tag and release"
  if GH_TOKEN="$GITHUB_TOKEN" gh release view "${NEXT_RELEASE}" \
       --json tagName --jq '.tagName' >/dev/null 2>/dev/null; then
    echo "ERROR: GitHub release '${NEXT_RELEASE}' already exists — aborting."
    _log_gha_endgroup
    exit $EXIT_RELEASE_EXISTS
  else
    echo "GitHub release '${NEXT_RELEASE}' does not exist yet."
  fi
  _log_gha_endgroup
}

ensure_tag_exists() {
  echo "::group::Ensure tag"
  local tag="$NEXT_RELEASE"
  local head_sha
  head_sha="$(git rev-parse HEAD)"

  if GH_TOKEN="$GITHUB_TOKEN" gh api "repos/{owner}/{repo}/git/ref/tags/${tag}" \
       --silent 2>/dev/null; then
    echo "Tag '${tag}' already exists — skipping tag creation."
  elif [[ "$CURRENT_BRANCH" != "main" || "$DRY_RUN" == "true" ]]; then
    echo "Tag '${tag}' does not exist — dry run; skipping tag creation."
  else
    echo "Tag '${tag}' does not exist — creating annotated tag at ${head_sha}."
    local tag_sha
    if ! tag_sha="$(GH_TOKEN="$GITHUB_TOKEN" gh api "repos/{owner}/{repo}/git/tags" \
      --method POST \
      --field "tag=${tag}" \
      --field "message=${RELEASE_NOTES}" \
      --field "object=${head_sha}" \
      --field "type=commit" \
      --jq '.sha')"; then
      echo "ERROR: Failed to create tag object for '${tag}'."
      exit $EXIT_CREATE_TAG_FAILED
    fi
    if ! GH_TOKEN="$GITHUB_TOKEN" gh api "repos/{owner}/{repo}/git/refs" \
      --method POST \
      --field "ref=refs/tags/${tag}" \
      --field "sha=${tag_sha}"; then
      echo "ERROR: Failed to create tag ref for '${tag}'."
      exit $EXIT_CREATE_TAG_FAILED
    fi
    echo "Annotated tag '${tag}' created at ${head_sha}."
  fi
  _log_gha_endgroup
}

publish_release() {
  echo "::group::Create release"
  local head_sha
  head_sha="$(git rev-parse HEAD)"

  if [[ "$CURRENT_BRANCH" == "main" && "$DRY_RUN" != "true" ]]; then
    echo "On main branch — creating GitHub release '${NEXT_RELEASE}' at ${head_sha}."
    echo ""
    if [[ "$NOTES_FROM_TAG" == "true" ]]; then
      echo "Release notes will be taken from the tag annotation of '${NEXT_RELEASE}'."
    else
      echo "Release notes:"
      echo ""
      echo "${RELEASE_NOTES}"
    fi
    echo ""
    local draft_flag=()
    if [[ "$DRAFT" == "true" ]]; then
      draft_flag=(--draft)
      echo "Draft mode enabled — Only draft release will be created, but not published."
    fi
    local notes_flag=()
    if [[ "$NOTES_FROM_TAG" == "true" ]]; then
      notes_flag=(--notes-from-tag)
    else
      notes_flag=(--notes "$RELEASE_NOTES")
    fi
    if ! GH_TOKEN="$GITHUB_TOKEN" gh release create "$NEXT_RELEASE" \
      --title "$NEXT_RELEASE" \
      "${notes_flag[@]}" \
      --target "$head_sha" \
      "${draft_flag[@]}"; then
      echo "ERROR: Failed to create GitHub release '${NEXT_RELEASE}'."
      exit $EXIT_CREATE_RELEASE_FAILED
    fi
    echo "Release '${NEXT_RELEASE}' created successfully."
  else
    if [[ "$DRY_RUN" == "true" && "$CURRENT_BRANCH" == "main" ]]; then
      echo "Dry run enabled — no release or tag will be created."
    else
      echo "On branch '${CURRENT_BRANCH}' (not main) — dry run; no release or tag will be created."
    fi
    echo ""
    echo "Release that would be created: ${NEXT_RELEASE}"
    echo ""
    if [[ "$NOTES_FROM_TAG" == "true" ]]; then
      echo "Release notes: taken from tag annotation of '${NEXT_RELEASE}' (see tag annotation printed above)."
    else
      echo "Release notes:"
      echo "${RELEASE_NOTES}"
    fi
  fi
  _log_gha_endgroup
}

# ---------------------------------------------------------------------------
# Main execution logic
# ---------------------------------------------------------------------------
echo "========================================================================"
echo "                            STARTING"
echo "========================================================================"
echo "Call: $(printf '%q ' "$0" "$@")"
validate_prerequisites
parse_args "$@"
detect_branch
if [[ "$NOTES_FROM_TAG" == "true" ]]; then
  verify_tag_for_notes
else
  resolve_file_patterns
fi
check_next_release_tag
if [[ "$NOTES_FROM_TAG" != "true" ]]; then
  build_git_log_args
  log_debug_commits
  collect_release_notes
fi
ensure_tag_exists
publish_release

echo "========================================================================"
echo "                            FINISHED"
echo "========================================================================"
