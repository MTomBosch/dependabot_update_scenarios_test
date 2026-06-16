#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Run Renovate locally for this repository.

Usage:
  ./run_renovate_local.sh [options]

Options:
  --local                 Run against local filesystem (no PR creation no file changes, only config validation)
  --github                Run against GitHub repository and allow PR creation
  --repo <owner/name>     GitHub repository slug for --github mode
  --config <path>         Renovate config file (default: .github/renovate.json5)
  --image <image>         Renovate container image (default: ghcr.io/renovatebot/renovate)
  --version <tag>         Renovate image tag (default: 43.173.0)
  --dry-run <mode>        Set RENOVATE_DRY_RUN (e.g. extract, lookup, full)
  --log-level <level>     Renovate log level (default: info), automatically set to debug if --dry-run or --local is used
  --log-file <path>       Write all Renovate execution output to this file (optional; file is overwritten each run)
  -h, --help              Show this help

Environment:
  GITHUB_TOKEN            Required for all modes (GitHub personal access token)

Examples:
  # Local test mode, no PR creation, no file changes, used mainly for testing config file syntax and match pattern correctness
  ./run_renovate_local.sh --local

  # Local test mode including the computation what the next version would be (= lookup)
  ./run_renovate_local.sh --local --dry-run lookup

  # Fully simulated GitHub run with no PR creation (dry-run)
  ./run_renovate_local.sh --github --dry-run full

  # Full GitHub run (can create/update PRs)
  GITHUB_TOKEN=*** ./run_renovate_local.sh --github --repo etas-eng/vsps_dev_infra_arch_doc
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR"

MODE=""
CONFIG_FILE=".github/renovate.json5"
RENOVATE_IMAGE="ghcr.io/renovatebot/renovate"
RENOVATE_VERSION="43.173.0"
REPO_SLUG=""
DRY_RUN_MODE=""
LOG_LEVEL="${LOG_LEVEL:-info}"
LOG_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local)
      if [[ -n "$MODE" ]]; then
        echo "Specify only one mode flag: --local or --github" >&2
        usage
        exit 1
      fi
      MODE="local"
      shift
      ;;
    --github)
      if [[ -n "$MODE" ]]; then
        echo "Specify only one mode flag: --local or --github" >&2
        usage
        exit 1
      fi
      MODE="github"
      shift
      ;;
    --config)
      CONFIG_FILE="$2"
      shift 2
      ;;
    --image)
      RENOVATE_IMAGE="$2" 
      shift 2
      ;;
    --version)
      RENOVATE_VERSION="$2"
      shift 2
      ;;
    --repo)
      REPO_SLUG="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN_MODE="$2"
      shift 2
      ;;
    --log-level)
      LOG_LEVEL="$2"
      shift 2
      ;;
    --log-file)
      LOG_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$MODE" ]]; then
  echo "Either --local or --github must be specified." >&2
  usage
  exit 1
fi

if [[ -n "$DRY_RUN_MODE" && "$DRY_RUN_MODE" != "null" ]]; then
  LOG_LEVEL="debug"
  echo "==================================================================" >&2
  echo "Note: Dry-run mode enabled; LOG_LEVEL automatically set to 'debug'" >&2
  echo "==================================================================" >&2
fi

if [[ ! -f "$REPO_DIR/$CONFIG_FILE" ]]; then
  echo "Config file not found: $CONFIG_FILE" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required but not available in PATH" >&2
  exit 1
fi

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "GITHUB_TOKEN environment variable must be set and non-empty" >&2
  exit 1
fi

DOCKER_ENV=(
  -e "LOG_LEVEL=$LOG_LEVEL"
  -e "LOG_FORMAT=pretty"
  -e "RENOVATE_CONFIG_FILE=$CONFIG_FILE"
  -e "RENOVATE_GITHUB_COM_TOKEN=$GITHUB_TOKEN"
  -e "RENOVATE_TOKEN=$GITHUB_TOKEN"
)

if [[ -n "$DRY_RUN_MODE" ]]; then
  DOCKER_ENV+=( -e "RENOVATE_DRY_RUN=$DRY_RUN_MODE" )
fi

# Only set proxy related vars if they are non-empty to avoid accidentally overriding any defaults in the container with empty values.
[[ -n "${all_proxy:-}"    ]] && DOCKER_ENV+=( -e "all_proxy=${all_proxy}" )
[[ -n "${ALL_PROXY:-}"    ]] && DOCKER_ENV+=( -e "ALL_PROXY=${ALL_PROXY}" )
[[ -n "${http_proxy:-}"   ]] && DOCKER_ENV+=( -e "http_proxy=${http_proxy}" )
[[ -n "${HTTP_PROXY:-}"   ]] && DOCKER_ENV+=( -e "HTTP_PROXY=${HTTP_PROXY}" )
[[ -n "${https_proxy:-}"  ]] && DOCKER_ENV+=( -e "https_proxy=${https_proxy}" )
[[ -n "${HTTPS_PROXY:-}"  ]] && DOCKER_ENV+=( -e "HTTPS_PROXY=${HTTPS_PROXY}" )

# Run a command, optionally teeing combined stdout+stderr to LOG_FILE.
_run_cmd_and_log_to_file() {
  if [[ -n "$LOG_FILE" ]]; then
    "$@" 2>&1 | tee "$LOG_FILE"
    return "${PIPESTATUS[0]}"
  else
    "$@"
  fi
}

if [[ "$MODE" == "local" ]]; then
  # Local platform mode avoids remote PR operations and is suitable for behavior tests.
  DOCKER_ENV+=(
    -e "RENOVATE_PLATFORM=local"
    -e "RENOVATE_ONBOARDING=false"
    -e "RENOVATE_REQUIRE_CONFIG=ignored"
  )

  echo "Running in local test mode (no PR creation)."

  _run_cmd_and_log_to_file docker run --rm \
    --network host \
    -v "$REPO_DIR:/work" \
    -w /work \
    "${DOCKER_ENV[@]}" \
    "$RENOVATE_IMAGE:$RENOVATE_VERSION" \
    renovate

  exit $?
fi

if [[ -z "$REPO_SLUG" ]]; then
  REPO_SLUG="${GITHUB_REPOSITORY:-}"
fi

if [[ -z "$REPO_SLUG" ]]; then
  echo "Repository slug is required in --github mode. Use --repo <owner/name> or set GITHUB_REPOSITORY." >&2
  exit 1
fi

echo "Running in GitHub mode for repository: $REPO_SLUG"

_run_cmd_and_log_to_file docker run --rm \
  --network host \
  -v "$REPO_DIR:/work" \
  -w /work \
  "${DOCKER_ENV[@]}" \
  -e "RENOVATE_PLATFORM=github" \
  "$RENOVATE_IMAGE:$RENOVATE_VERSION" \
  renovate "$REPO_SLUG"
