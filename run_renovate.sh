#!/usr/bin/env bash
set -euo pipefail

trap 'echo Failed on line or function start line no: $LINENO at command: $BASH_COMMAND' ERR

# ─── Constants ───────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly REPO_DIR="$SCRIPT_DIR"
readonly _DEFAULT_RENOVATE_IMAGE="ghcr.io/renovatebot/renovate"
readonly _DEFAULT_RENOVATE_VERSION="43.226.1@sha256:1cc254d0011cf490e802d37ea637de5aafa83448c8c18d783658d22ba82c76b1"
readonly _DOWNLOADED_CONFIG_NAME=".renovate_downloaded_config.json5"

# ─── Exit codes ──────────────────────────────────────────────────────────────
readonly EXIT_USAGE=2          # usage / bad argument
readonly EXIT_NO_DOCKER=3      # docker not found
readonly EXIT_NO_TOKEN=4       # GITHUB_TOKEN not set
readonly EXIT_NO_GH=5          # gh CLI not found
readonly EXIT_NO_JQ=6          # jq not found
readonly EXIT_NO_CONFIG=7      # config file not found
readonly EXIT_RENOVATE_FAILED=8 # one or more Renovate runs failed

# ─── Usage ───────────────────────────────────────────────────────────────────
usage() {
  cat <<'EOF'
Run Renovate locally or for repositories in a GitHub organisation.

Usage:
  ./run_renovate.sh [options]

Modes (exactly one required):
  --mode-local             Run against local files (no PR creation, no file
                           changes, test config file)
  --mode-remote            Run against GitHub repositories listed in the
                           Renovate config file (repositories key). Renovate
                           is called once without an explicit repository
                           argument.
  --mode-github-org <organisation>
                           List all repositories in the organisation and run
                           Renovate for each one
                           Tip: use --include-pattern with an exact match to
                           target a single repository, e.g.
                           --include-pattern '^myorg/myrepo$'

Options (all modes):
  --config <value>         Renovate config to use (default: ./.github/renovate.json5)
                           Values starting with ./ are treated as a local path
                           relative to this script's directory.
                           Values without a ./ prefix are treated as a remote
                           GitHub file reference:
                           Format:  owner/repo/path/to/file@ref
                           Example: myorg/cfg/.github/renovate.json5@main
  --image <image>          Renovate container image
                           (default: ghcr.io/renovatebot/renovate)
  --version <tag>          Renovate image tag, optionally with SHA256 digest
                           for exact image pinning
                           (default: 43.226.1@sha256:...)
                           Examples: 43.226.1
                                     43.226.1@sha256:<digest>
  --dry-run <mode>         Set RENOVATE_DRY_RUN (e.g. lookup, extract, full)
  --log-level <level>      Renovate log level (default: info)
  --log-format <fmt>       Renovate log format: json or pretty (default: pretty)
  --log-file <path>        Write Renovate output to this file; overwritten
                           each run. In --mode-github-org mode the path is used as
                           a template: the file extension (if any) is stripped,
                           the repo name appended, and the extension restored.
                           Example: renovate.log  →  renovate_owner_repo.log
                           Omit to write logs to the current directory using
                           the default name pattern.
  -h, --help               Show this help

Options (--mode-github-org mode only):
  --include-pattern <re>   Regex applied to owner/repo name; only matching
                           repositories are included. Empty = include all.
  --exclude-pattern <re>   Regex applied to owner/repo name; matching
                           repositories are excluded (applied after
                           --include-pattern). Empty = exclude nothing.

Environment:
  GITHUB_TOKEN             Required for all modes (personal access token)

Examples:
  # Local config test (no PR creation, no file changes)
  GITHUB_TOKEN=*** ./run_renovate.sh --mode-local

  # Local config test (no PR creation, no file changes)
  GITHUB_TOKEN=*** ./run_renovate.sh --mode-local

  # Local dry-run including version lookup from remote
  GITHUB_TOKEN=*** ./run_renovate.sh --mode-local --dry-run lookup

  # Remote mode dry-run (repos listed in renovate config)
  GITHUB_TOKEN=*** ./run_renovate.sh --mode-remote --dry-run full

  # Dry-run for a single repository (exact-match include pattern)
  GITHUB_TOKEN=*** ./run_renovate.sh --mode-github-org myorg \
    --include-pattern '^myorg/myrepo$' \
    --dry-run full

  # Dry-run across all repos in an org, filtered by name pattern
  GITHUB_TOKEN=*** ./run_renovate.sh --mode-github-org myorg \
    --include-pattern '^myorg/service-' \
    --dry-run full

  # Real org-wide run with a centrally-managed remote config
  GITHUB_TOKEN=*** ./run_renovate.sh --mode-github-org myorg \
    --config myorg/renovate-config/.github/renovate.json5@main \
    --version 43.226.1@sha256:<digest>
EOF
}

# ─── Argument parsing ─────────────────────────────────────────────────────────
parse_args() {
  MODE=""
  ORG=""
  CONFIG_FILE=".github/renovate.json5"
  CONFIG_REF=""
  RENOVATE_IMAGE="$_DEFAULT_RENOVATE_IMAGE"
  RENOVATE_VERSION="$_DEFAULT_RENOVATE_VERSION"
  DRY_RUN_MODE=""
  LOG_LEVEL="${LOG_LEVEL:-info}"
  LOG_FORMAT="pretty"
  LOG_FILE=""
  INCLUDE_PATTERN=""
  EXCLUDE_PATTERN=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode-local)
        [[ -n "$MODE" ]] && { echo "Specify exactly one mode flag: --mode-local, --mode-remote, or --mode-github-org." >&2; usage; exit $EXIT_USAGE; }
        MODE="local"; shift ;;
      --mode-remote)
        [[ -n "$MODE" ]] && { echo "Specify exactly one mode flag: --mode-local, --mode-remote, or --mode-github-org." >&2; usage; exit $EXIT_USAGE; }
        MODE="remote"; shift ;;
      --mode-github-org)
        [[ -n "$MODE" ]] && { echo "Specify exactly one mode flag: --mode-local, --mode-remote, or --mode-github-org." >&2; usage; exit $EXIT_USAGE; }
        MODE="github-org"; ORG="$2"; shift 2 ;;
      --config)
        if [[ "$2" == ./* ]]; then
          CONFIG_FILE="${2#./}"
        else
          CONFIG_REF="$2"
        fi
        shift 2 ;;
      --image)            RENOVATE_IMAGE="$2";   shift 2 ;;
      --version)          RENOVATE_VERSION="$2"; shift 2 ;;
      --dry-run)          DRY_RUN_MODE="$2";     shift 2 ;;
      --log-level)        LOG_LEVEL="$2";        shift 2 ;;
      --log-format)
        [[ "$2" != "json" && "$2" != "pretty" ]] && {
          echo "Invalid --log-format value '$2'. Allowed values: json, pretty" >&2; usage; exit $EXIT_USAGE
        }
        LOG_FORMAT="$2"; shift 2 ;;
      --log-file)         LOG_FILE="$2";         shift 2 ;;
      --include-pattern)  INCLUDE_PATTERN="$2";  shift 2 ;;
      --exclude-pattern)  EXCLUDE_PATTERN="$2";  shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown argument: $1" >&2; usage; exit $EXIT_USAGE ;;
    esac
  done

  [[ -z "$MODE" ]] && {
    echo "Exactly one mode flag (--mode-local, --mode-remote, or --mode-github-org) is required." >&2
    usage; exit $EXIT_USAGE
  }
  echo "DEBUG TRACE BEFORE CALLING FUNCTION _apply_log_level_defaults"
  _apply_log_level_defaults
  return 0
}

# ─── Log-level defaults ───────────────────────────────────────────────────────
_apply_log_level_defaults() {
  if [[ "$MODE" == "local" && -z "$DRY_RUN_MODE" ]]; then
    LOG_LEVEL="debug"
    echo "================================================================"
    echo "Note: Local mode enabled; LOG_LEVEL automatically set to 'debug'"
    echo "================================================================"
  fi

  if [[ -n "$DRY_RUN_MODE" && "$DRY_RUN_MODE" != "null" ]]; then
    LOG_LEVEL="debug"
    echo "=================================================================="
    echo "Note: Dry-run mode enabled; LOG_LEVEL automatically set to 'debug'"
    echo "=================================================================="
  fi
}

# ─── Prerequisites ────────────────────────────────────────────────────────────
validate_prerequisites() {
  echo "::group::Tool versions"

  if ! command -v docker >/dev/null 2>&1; then
    echo "docker is required but not available in PATH" >&2
    echo "::endgroup::"
    exit $EXIT_NO_DOCKER
  fi
  echo "docker: $(docker --version)"

  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    echo "GITHUB_TOKEN environment variable must be set and non-empty" >&2
    echo "::endgroup::"
    exit $EXIT_NO_TOKEN
  fi

  if [[ "$MODE" == "github-org" || -n "$CONFIG_REF" ]]; then
    command -v gh >/dev/null 2>&1 || {
      echo "gh (GitHub CLI) is required for --mode-github-org mode and --config remote ref but is not in PATH" >&2
      echo "::endgroup::"
      exit $EXIT_NO_GH
    }
    echo "gh: $(gh --version | head -1)"

    command -v jq >/dev/null 2>&1 || {
      echo "jq is required for --mode-github-org mode but is not in PATH" >&2
      echo "::endgroup::"
      exit $EXIT_NO_JQ
    }
    echo "jq: $(jq --version)"
  fi

  echo "::endgroup::"
}

# ─── Config resolution ────────────────────────────────────────────────────────
resolve_config() {
  if [[ -n "$CONFIG_REF" ]]; then
    echo "DEBUG TRACE BEFORE CALLING FUNCTION _download_remote_config"
    _download_remote_config "$CONFIG_REF"
    CONFIG_FILE="$_DOWNLOADED_CONFIG_NAME"
  fi

  if [[ ! -f "$REPO_DIR/$CONFIG_FILE" ]]; then
    echo "Config file not found: $REPO_DIR/$CONFIG_FILE" >&2; exit $EXIT_NO_CONFIG
  fi
}

_download_remote_config() {
  local config_ref="$1" ref="" path_part owner repo_name file_path api_path

  if [[ "$config_ref" == *@* ]]; then
    ref="${config_ref##*@}"
    path_part="${config_ref%@*}"
  else
    path_part="$config_ref"
  fi

  owner="$(cut -d/ -f1    <<< "$path_part")"
  repo_name="$(cut -d/ -f2  <<< "$path_part")"
  file_path="$(cut -d/ -f3- <<< "$path_part")"

  api_path="repos/$owner/$repo_name/contents/$file_path"
  [[ -n "$ref" ]] && api_path="${api_path}?ref=${ref}"

  echo "Downloading Renovate config from: $owner/$repo_name/$file_path${ref:+ @ $ref}"
  GH_TOKEN="$GITHUB_TOKEN" gh api "$api_path" --jq '.content' \
    | base64 --decode > "$REPO_DIR/$_DOWNLOADED_CONFIG_NAME"
}

# ─── Docker environment ───────────────────────────────────────────────────────
build_docker_env() {
  DOCKER_ENV=(
    -e "LOG_LEVEL=$LOG_LEVEL"
    -e "LOG_FORMAT=$LOG_FORMAT"
    -e "RENOVATE_CONFIG_FILE=$CONFIG_FILE"
    -e "RENOVATE_GITHUB_COM_TOKEN=$GITHUB_TOKEN"
    -e "RENOVATE_TOKEN=$GITHUB_TOKEN"
  )

  if [[ -n "$DRY_RUN_MODE" ]]; then DOCKER_ENV+=( -e "RENOVATE_DRY_RUN=$DRY_RUN_MODE" ); fi

  # Only set proxy vars if non-empty to avoid overriding container defaults.
  # Use if/then/fi instead of [[ ]] && action: with set -e the overall exit code
  # of a [[ ]] && action compound is 1 when the condition is false, which causes
  # set -e to abort the script.
  if [[ -n "${all_proxy:-}"   ]]; then DOCKER_ENV+=( -e "all_proxy=${all_proxy}" );     fi
  if [[ -n "${ALL_PROXY:-}"   ]]; then DOCKER_ENV+=( -e "ALL_PROXY=${ALL_PROXY}" );     fi
  if [[ -n "${http_proxy:-}"  ]]; then DOCKER_ENV+=( -e "http_proxy=${http_proxy}" );   fi
  if [[ -n "${HTTP_PROXY:-}"  ]]; then DOCKER_ENV+=( -e "HTTP_PROXY=${HTTP_PROXY}" );   fi
  if [[ -n "${https_proxy:-}" ]]; then DOCKER_ENV+=( -e "https_proxy=${https_proxy}" ); fi
  if [[ -n "${HTTPS_PROXY:-}" ]]; then DOCKER_ENV+=( -e "HTTPS_PROXY=${HTTPS_PROXY}" ); fi
}

# ─── Output helper ────────────────────────────────────────────────────────────
# Run a command, optionally teeing combined stdout+stderr to a log file.
# Usage: _run_and_log <log-file-or-empty> <command> [args...]
_run_and_log() {
  local log="$1"; shift
  if [[ -n "$log" ]]; then
    "$@" 2>&1 | tee "$log"
    return "${PIPESTATUS[0]}"
  else
    "$@"
  fi
}

# ─── Mode: local ─────────────────────────────────────────────────────────────
run_local_mode() {
  local local_env=(
    -e "RENOVATE_PLATFORM=local"
    -e "RENOVATE_ONBOARDING=false"
    -e "RENOVATE_REQUIRE_CONFIG=ignored"
  )

  echo "Running in local test mode (no PR creation)."

  echo "::group::Renovate (local mode)"
  _run_and_log "$LOG_FILE" docker run --rm \
    --network host \
    -v "$REPO_DIR:/work" \
    -w /work \
    "${DOCKER_ENV[@]}" \
    "${local_env[@]}" \
    "$RENOVATE_IMAGE:$RENOVATE_VERSION" \
    renovate
  echo "::endgroup::"
}

# ─── Mode: remote ────────────────────────────────────────────────────────────
run_remote_mode() {
  echo "Running Renovate in remote mode (repositories from config)."

  echo "::group::Renovate (remote mode)"
  _run_and_log "$LOG_FILE" docker run --rm \
    --network host \
    -v "$REPO_DIR:/work" \
    -w /work \
    "${DOCKER_ENV[@]}" \
    -e "RENOVATE_PLATFORM=github" \
    "$RENOVATE_IMAGE:$RENOVATE_VERSION" \
    renovate
  echo "::endgroup::"
}

# ─── GitHub single-repository runner (internal, used by run_org_mode) ───────
# $1 = repository slug (owner/name)
# $2 = log file path (empty = no file logging)
run_github_single_repo() {
  local repo_slug="$1" log_file="${2:-}"

  echo "Running Renovate for repository: $repo_slug"

  _run_and_log "$log_file" docker run --rm \
    --network host \
    -v "$REPO_DIR:/work" \
    -w /work \
    "${DOCKER_ENV[@]}" \
    -e "RENOVATE_PLATFORM=github" \
    "$RENOVATE_IMAGE:$RENOVATE_VERSION" \
    renovate "$repo_slug"
}

# ─── Mode: org ────────────────────────────────────────────────────────────────
_list_org_repos() {
  echo "::group::Get Repositories"
  local repos_json

  echo "Getting all repos from the specified GH org..."
  repos_json=$(GH_TOKEN="$GITHUB_TOKEN" gh repo list "$ORG" \
    --json nameWithOwner \
    --limit 1000 \
    --jq '[.[].nameWithOwner]')

  echo "Applying include pattern as filter..."
  if [[ -n "$INCLUDE_PATTERN" ]]; then
    repos_json=$(jq --arg p "$INCLUDE_PATTERN" '[.[] | select(test($p; "i"))]' <<< "$repos_json")
  fi

  echo "Applying exclude pattern as filter..."
  if [[ -n "$EXCLUDE_PATTERN" ]]; then
    repos_json=$(jq --arg p "$EXCLUDE_PATTERN" '[.[] | select(test($p; "i") | not)]' <<< "$repos_json")
  fi

  echo "Final repositories to process: $(jq 'length' <<< "$repos_json")"
  jq -r '.[]' <<< "$repos_json"
  echo "::endgroup::"

  echo "$repos_json"
}

run_org_mode() {
  local repos_json repo safe_repo log_file exit_code
  local -a failed_repos=()

  echo "DEBUG TRACE BEFORE CALLING FUNCTION _list_org_repos"
  repos_json=$(_list_org_repos)

  while IFS= read -r repo; do
    safe_repo="${repo//\//_}"
    if [[ -n "$LOG_FILE" ]]; then
      local log_dir log_basename log_base log_ext
      log_dir="$(dirname "$LOG_FILE")"
      log_basename="$(basename "$LOG_FILE")"
      if [[ "$log_basename" == *.* ]]; then
        log_base="${log_basename%.*}"
        log_ext=".${log_basename##*.}"
      else
        log_base="$log_basename"
        log_ext=""
      fi
      log_file="${log_dir}/${log_base}_${safe_repo}${log_ext}"
    else
      log_file="${REPO_DIR}/renovate_${safe_repo}.log"
    fi

    # ::group:: / ::endgroup:: are GitHub Actions workflow commands that create
    # collapsible log sections in the Actions UI. They are harmless on a local
    # terminal — they simply print as literal text.
    echo "::group::Renovate: $repo"

    set +e
    echo "DEBUG TRACE BEFORE CALLING FUNCTION run_github_single_repo"
    run_github_single_repo "$repo" "$log_file"
    exit_code=$?
    set -e

    echo "::endgroup::"

    if [[ $exit_code -ne 0 ]]; then
      echo "::error::Renovate failed for $repo (exit code $exit_code)"
      failed_repos+=("$repo")
    fi
  done < <(jq -r '.[]' <<< "$repos_json")

  if [[ ${#failed_repos[@]} -gt 0 ]]; then
    echo "::error::Renovate failed for the following repositories:"
    for repo in "${failed_repos[@]}"; do
      echo "::error::  - $repo"
    done
    exit $EXIT_RENOVATE_FAILED
  fi

  echo "All repositories processed successfully."
}

# ─── Main ─────────────────────────────────────────────────────────────────────
echo "Call: $(printf '%q ' "$0" "$@")"

echo "::group::Env vars"
printenv | sort
echo "::endgroup::"

echo "DEBUG TRACE BEFORE CALLING FUNCTION parse_args"
parse_args "$@"
echo "DEBUG TRACE BEFORE CALLING FUNCTION validate_prerequisites"
validate_prerequisites
echo "DEBUG TRACE BEFORE CALLING FUNCTION resolve_config"
resolve_config
echo "DEBUG TRACE BEFORE CALLING FUNCTION build_docker_env"
build_docker_env

case "$MODE" in
  local)       echo "DEBUG TRACE BEFORE CALLING FUNCTION run_local_mode";  run_local_mode ;;
  remote)      echo "DEBUG TRACE BEFORE CALLING FUNCTION run_remote_mode"; run_remote_mode ;;
  github-org)  echo "DEBUG TRACE BEFORE CALLING FUNCTION run_org_mode";    run_org_mode ;;
esac
