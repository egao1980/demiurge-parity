#!/usr/bin/env bash
# Record a narrated mock-tier demo.
#   ./demos/run-demo.sh <name>
# names: s2-boot | s4-answer | s6-improve | s7-resume | deep-research | corporate-boot
# Resolves demos/<name>/, isolates dest to .demo-oci, then:
#   product commands (ask/research/improve/ingest) → demiurge demo <dir>
#   boot/resume/corporate → demos/runner.lisp
# Wraps SBCL in `asciinema rec` when present, else script(1).
# Always tees demos/recordings/<version>/<name>.log
set -Eeuo pipefail

usage() {
  printf 'usage: %s <name>\n' "$(basename "$0")" >&2
  printf '  names: s2-boot | s4-answer | s6-improve | s7-resume | deep-research | corporate-boot\n' >&2
  exit 2
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PARENT="$(cd "${ROOT}/.." && pwd)"
cd "${ROOT}"

# Workspace .env carries LM_API_TOKEN / OPENAI_* (gitignored). Do not print values.
for dotenv in "${ROOT}/.env" "${ROOT}/../.env"; do
  if [[ -f "${dotenv}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${dotenv}"
    set +a
  fi
done

# Isolated dest — do not inherit a workspace-wide systems tree (version skew:
# shared dest can see demiurge 0.3.0/0.3.1 without /workflows). No trailing
# inherit colon. CI already installed deps; a set CL_REPOSITORY_DEST is left alone.
if [[ -z "${CL_REPOSITORY_DEST:-}" ]]; then
  export CL_REPOSITORY_DEST="${ROOT}/.demo-oci"
fi
export CL_REPOSITORY_CLIENT_DIR="${CL_REPOSITORY_CLIENT_DIR:-${HOME}/.local/share/cl-repository-client/cl-oci-0.16.0}"

# B8 needs demiurge/cli from demiurge-plan-vectors (B9). Never add a stale
# demiurge/ or demiurge-b4b checkout — those trees do not have the CLI.
PLAN_VECTORS="${PARENT}/demiurge-plan-vectors"
CLI_PROTOCOL="${PARENT}/cli-protocol"
export CL_SOURCE_REGISTRY="${PLAN_VECTORS}//:${CLI_PROTOCOL}//:${ROOT}//:${CL_REPOSITORY_DEST}//"

DEMIURGE_LISP="${PLAN_VECTORS}/scripts/demiurge.lisp"

if [[ "${1:-}" == "--inner" ]]; then
  shift
  NAME="${1:-}"
  DIR="${2:-}"
  LOG="${3:-}"
  RECORDER="${4:-unknown}"
  VERSION="${5:-unknown}"
  MODE="${6:-cli}"
  [[ -n "${NAME}" && -n "${DIR}" && -n "${LOG}" ]] || usage
  SBCL_BIN="${SBCL:-sbcl}"
  set +e
  {
    printf '=== demiurge-parity demo: %s ===\n' "${NAME}"
    printf 'date: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'version: %s\n' "${VERSION}"
    printf 'host: %s %s\n' "$(uname -s)" "$(uname -m)"
    printf 'sbcl: %s\n' "$(${SBCL_BIN} --version 2>/dev/null || printf 'unknown')"
    printf 'recorder: %s\n' "${RECORDER}"
    printf 'tier: %s\n' "${DEMIURGE_PARITY_TIER:-mock}"
    printf 'dir: %s\n' "${DIR}"
    printf 'mode: %s\n' "${MODE}"
    printf '\n'
    if [[ "${MODE}" == "runner" ]]; then
      "${SBCL_BIN}" --noinform --non-interactive --disable-debugger \
        --load "${SCRIPT_DIR}/prelude.lisp" \
        --load "${SCRIPT_DIR}/runner.lisp" \
        -- "${DIR}"
    else
      if [[ ! -f "${DEMIURGE_LISP}" ]]; then
        printf 'run-demo: missing %s (need demiurge-plan-vectors with B9 CLI)\n' \
          "${DEMIURGE_LISP}" >&2
        exit 1
      fi
      "${SBCL_BIN}" --noinform --non-interactive --disable-debugger \
        --load "${SCRIPT_DIR}/prelude.lisp" \
        --load "${DEMIURGE_LISP}" \
        -- demo "${DIR}"
    fi
  } 2>&1 | tee "${LOG}"
  status="${PIPESTATUS[0]}"
  set -e
  printf '%s\n' "${status}" >"${LOG}.status"
  exit "${status}"
fi

[[ $# -ge 1 ]] || usage
RAW="$1"

resolve_dir() {
  local raw="$1"
  local stem="${raw%.lisp}"
  stem="${stem%-demo}"
  local aliases=()
  case "${stem}" in
    s2) aliases+=(s2-boot) ;;
    s4) aliases+=(s4-answer) ;;
    s6) aliases+=(s6-improve) ;;
    s7) aliases+=(s7-resume) ;;
    research) aliases+=(deep-research) ;;
    corporate) aliases+=(corporate-boot) ;;
  esac
  local candidates=(
    "${ROOT}/demos/${stem}"
    "${ROOT}/demos/${raw}"
  )
  local a
  if ((${#aliases[@]})); then
    for a in "${aliases[@]}"; do
      candidates+=("${ROOT}/demos/${a}")
    done
  fi
  local c
  for c in "${candidates[@]}"; do
    if [[ -d "${c}" && -f "${c}/demo.toml" ]]; then
      printf '%s\n' "${c}"
      return 0
    fi
  done
  return 1
}

DIR="$(resolve_dir "${RAW}")" || {
  printf 'run-demo: no demo directory for %s\n' "${RAW}" >&2
  usage
}

REC_NAME="$(basename "${DIR}")"
peek_command() {
  local f="$1/demo.toml"
  [[ -f "${f}" ]] || { echo ask; return; }
  local c
  c="$(sed -n 's/^[[:space:]]*command[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "${f}" | head -n 1)"
  echo "${c:-ask}"
}

COMMAND="$(peek_command "${DIR}")"
MODE="cli"
case "${COMMAND}" in
  boot|resume|corporate|improve) MODE="runner" ;;
esac

VERSION="${DEMO_VERSION:-}"
if [[ -z "${VERSION}" ]]; then
  VERSION="$(sed -n 's/^[[:space:]]*:version "\([^"]*\)".*/\1/p' "${ROOT}/demiurge-parity.asd" | head -n 1)"
fi
[[ -n "${VERSION}" ]] || VERSION="unknown"

OUTDIR="${ROOT}/demos/recordings/${VERSION}"
mkdir -p "${OUTDIR}"
LOG="${OUTDIR}/${REC_NAME}.log"
CAST="${OUTDIR}/${REC_NAME}.cast"

ensure_searxng() {
  local mode="${DEMIURGE_PARITY_DEMO_WEBSEARCH:-auto}"
  if [[ "${CI:-}" == "true" || "${GITHUB_ACTIONS:-}" == "true" ]]; then
    return 0
  fi
  case "${mode}" in
    mock|scripted) return 0 ;;
  esac
  local url="${SEARXNG_URL:-${DEMIURGE_PARITY_SEARXNG:-http://127.0.0.1:8888}}"
  if curl -sS -m 2 -o /dev/null "${url}/search?q=ping&format=json"; then
    return 0
  fi
  command -v docker >/dev/null 2>&1 || return 0
  printf 'run-demo: starting SearXNG (docker compose --profile search)\n' >&2
  docker compose --profile search up -d --wait searxng
}

case "${REC_NAME}" in
  deep-research) ensure_searxng ;;
esac

SBCL_BIN="${SBCL:-sbcl}"
command -v "${SBCL_BIN}" >/dev/null 2>&1 || {
  printf 'run-demo: sbcl not on PATH (set SBCL=)\n' >&2
  exit 1
}

RECORDER="script"
if command -v asciinema >/dev/null 2>&1; then
  RECORDER="asciinema"
fi

INNER=( "$0" --inner "${REC_NAME}" "${DIR}" "${LOG}" "${RECORDER}" "${VERSION}" "${MODE}" )
INNER_CMD="$(printf '%q ' "${INNER[@]}")"

if [[ "${RECORDER}" == "asciinema" ]]; then
  asciinema rec --overwrite -c "${INNER_CMD}" "${CAST}"
else
  case "$(uname -s)" in
    Linux)
      script -q -e -c "${INNER_CMD}" "${CAST}"
      ;;
    *)
      script -q "${CAST}" "${INNER[@]}"
      ;;
  esac
fi

printf 'wrote %s\n' "${LOG}"
printf 'wrote %s\n' "${CAST}"

STATUS_FILE="${LOG}.status"
if [[ -f "${STATUS_FILE}" ]]; then
  STATUS="$(cat "${STATUS_FILE}")"
  rm -f "${STATUS_FILE}"
  if [[ "${STATUS}" != "0" ]]; then
    printf 'run-demo: %s failed (exit %s)\n' "${REC_NAME}" "${STATUS}" >&2
    exit "${STATUS}"
  fi
else
  printf 'run-demo: missing status file for %s\n' "${REC_NAME}" >&2
  exit 1
fi
