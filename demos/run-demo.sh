#!/usr/bin/env bash
# Record a narrated mock-tier demo.
#   ./demos/run-demo.sh <name>
# names: s2-boot | s4-answer | s6-improve | s7-resume | deep-research | corporate-boot
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
export CL_SOURCE_REGISTRY="${ROOT}//:${CL_REPOSITORY_DEST}//:${CL_REPOSITORY_CLIENT_DIR}//"

if [[ "${1:-}" == "--inner" ]]; then
  shift
  NAME="${1:-}"
  LISP="${2:-}"
  LOG="${3:-}"
  RECORDER="${4:-unknown}"
  VERSION="${5:-unknown}"
  [[ -n "${NAME}" && -n "${LISP}" && -n "${LOG}" ]] || usage
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
    printf '\n'
    "${SBCL_BIN}" --noinform --non-interactive --disable-debugger --load "${LISP}"
  } 2>&1 | tee "${LOG}"
  status="${PIPESTATUS[0]}"
  set -e
  printf '%s\n' "${status}" >"${LOG}.status"
  exit "${status}"
fi

[[ $# -ge 1 ]] || usage
RAW="$1"

resolve_lisp() {
  local raw="$1"
  local stem="${raw%.lisp}"
  local candidates=(
    "${ROOT}/demos/${stem}.lisp"
    "${ROOT}/demos/${stem}-demo.lisp"
  )
  local c
  for c in "${candidates[@]}"; do
    if [[ -f "${c}" ]]; then
      printf '%s\n' "${c}"
      return 0
    fi
  done
  return 1
}

LISP="$(resolve_lisp "${RAW}")" || {
  printf 'run-demo: no demo script for %s\n' "${RAW}" >&2
  usage
}

REC_NAME="$(basename "${LISP}" .lisp)"
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
  deep-research-demo) ensure_searxng ;;
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

INNER=( "$0" --inner "${REC_NAME}" "${LISP}" "${LOG}" "${RECORDER}" "${VERSION}" )
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
