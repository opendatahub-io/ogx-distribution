#!/usr/bin/env bash
# shellcheck disable=SC1091
# Run Bruno CRUD and notebook tests for a given provider combination.
# Requires: BASE_URL, INFERENCE_MODEL (inference model name).
# Optional: FILES_PROVIDER, INFERENCE_PROVIDER, VECTOR_IO_PROVIDER,
#           EMBEDDING_MODEL (for reporting/env).
#
# Example:
#   export BASE_URL="http://localhost:8321"
#   export INFERENCE_MODEL="vllm-inference/llama-3-2-3b"
#   ./scripts/run-tests-with-providers.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRUNO_DIR="${REPO_ROOT}/bruno"
NOTEBOOKS_DIR="${REPO_ROOT}/notebooks"
REPORTS_DIR="${REPO_ROOT}/reports"
EXIT_CODE=0

mkdir -p "${REPORTS_DIR}"

if [[ -z "${BASE_URL:-}" ]]; then
  echo "Error: BASE_URL is required (e.g. http://localhost:8321)" >&2
  exit 1
fi
if [[ -z "${INFERENCE_MODEL:-}" ]]; then
  echo "Error: INFERENCE_MODEL is required for inference tests (e.g. vllm-inference/llama-3-2-3b)" >&2
  exit 1
fi

export FILES_PROVIDER="${FILES_PROVIDER:-}"
export INFERENCE_PROVIDER="${INFERENCE_PROVIDER:-}"
export VECTOR_IO_PROVIDER="${VECTOR_IO_PROVIDER:-}"
export EMBEDDING_MODEL="${EMBEDDING_MODEL:-}"

# Wait for server to become healthy (opt-in via HEALTH_CHECK_TIMEOUT).
# Skipped when timeout is 0 or unset (local dev). Set to e.g. 600 in CI/Tekton.
_wait_for_server() {
  local timeout="${HEALTH_CHECK_TIMEOUT:-0}"
  if [[ "$timeout" -le 0 ]]; then
    return 0
  fi
  local url="${BASE_URL}/v1/health"
  local interval=2
  local max_interval=15
  local elapsed=0
  echo "Waiting for server at ${url} (timeout: ${timeout}s)..."
  while [[ "$elapsed" -lt "$timeout" ]]; do
    if curl -sf --connect-timeout 3 "${url}" >/dev/null 2>&1; then
      echo "  Server ready after ${elapsed}s"
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
    if [[ "$interval" -lt "$max_interval" ]]; then
      interval=$((interval * 2 > max_interval ? max_interval : interval * 2))
    fi
  done
  echo "Error: server at ${url} not ready after ${timeout}s — sidecar may have crashed" >&2
  return 1
}

_wait_for_server

source "$(dirname "${BASH_SOURCE[0]}")/sync-client-version.sh"

# Health-check helper: verify the server is reachable, restart port-forward if needed
_ensure_server() {
  if curl -sf --connect-timeout 3 "${BASE_URL}/v1/health" >/dev/null 2>&1; then
    return 0
  fi
  local ns="${OC_NAMESPACE-}"
  if [[ -z "$ns" ]]; then
    echo "  Server unreachable at ${BASE_URL} (port-forward disabled)" >&2
    return 1
  fi
  echo "  Server unreachable at ${BASE_URL} — attempting port-forward restart..."
  pkill -f "port-forward.*${ns}" 2>/dev/null || true
  sleep 1
  local svc="${OC_SERVICE:-svc/ogx-vllm-vertex-service}"
  local port="${BASE_URL##*:}"  # extract port from http://host:PORT
  oc port-forward -n "${ns}" "${svc}" "${port}:${port}" >/dev/null 2>&1 &
  sleep 4
  if curl -sf --connect-timeout 3 "${BASE_URL}/v1/health" >/dev/null 2>&1; then
    echo "  Port-forward restored"
    return 0
  fi
  echo "  Warning: could not restore connectivity to ${BASE_URL}" >&2
  return 1
}

echo ""
echo "=== Provider matrix test run ==="
echo "  BASE_URL           = ${BASE_URL}"
echo "  INFERENCE_MODEL              = ${INFERENCE_MODEL}"
echo "  EMBEDDING_MODEL    = ${EMBEDDING_MODEL}"
echo "  INFERENCE_PROVIDER = ${INFERENCE_PROVIDER}"
echo "  FILES_PROVIDER     = ${FILES_PROVIDER}"
echo "  VECTOR_IO_PROVIDER = ${VECTOR_IO_PROVIDER}"
echo ""

# ── Bruno CLI ────────────────────────────────────────────────────────────────
BRU=""
if [[ -x "${BRUNO_DIR}/node_modules/.bin/bru" ]]; then
  BRU="${BRUNO_DIR}/node_modules/.bin/bru"
elif command -v bru &>/dev/null; then
  BRU="bru"
elif command -v npm &>/dev/null && [[ -f "${BRUNO_DIR}/package.json" ]]; then
  echo "Installing Bruno CLI via npm ci..."
  (cd "${BRUNO_DIR}" && npm ci --ignore-scripts 2>&1) || echo "  Warning: npm ci failed"
  if [[ -x "${BRUNO_DIR}/node_modules/.bin/bru" ]]; then
    BRU="${BRUNO_DIR}/node_modules/.bin/bru"
  fi
fi

_env_vars=(
  --env-var "baseUrl=${BASE_URL}"
  --env-var "model=${INFERENCE_MODEL}"
  --env-var "embedding_model=${EMBEDDING_MODEL}"
  --env-var "embedding_dimension=${EMBEDDING_DIMENSION:-768}"
  --env-var "inference_provider=${INFERENCE_PROVIDER}"
  --env-var "files_provider=${FILES_PROVIDER}"
  --env-var "vector_io_provider=${VECTOR_IO_PROVIDER}"
)

# ── Phase 1: Bruno CRUD tests (fail-fast) ───────────────────────────────────
OGX_CRUD_DIR="${BRUNO_DIR}/ogx-crud"
if [[ -n "${BRU}" && -d "${OGX_CRUD_DIR}" ]]; then
  _ensure_server
  echo ">>> Phase 1: Bruno CRUD tests"
  _bruno_json=$(mktemp /tmp/bruno-results-XXXXXX.json)
  _bruno_log=$(mktemp /tmp/bruno-log-XXXXXX.txt)
  _bruno_exit=0
  BRUNO_TIMEOUT="${BRUNO_TIMEOUT:-600}"
  # shellcheck disable=SC2086
  (cd "${OGX_CRUD_DIR}" && timeout "${BRUNO_TIMEOUT}" $BRU run . -r "${_env_vars[@]}" --output "${_bruno_json}") \
    > "${_bruno_log}" 2>&1 || _bruno_exit=$?
  if [[ $_bruno_exit -eq 124 ]]; then
    echo "  Bruno CRUD tests timed out after ${BRUNO_TIMEOUT}s"
  fi
  # Display filtered output (strip proxy warnings and misleading built-in summary)
  grep -v -e "proxy" -e "Proxy" -e "getSystem" -e "at async" -e "at .*/node_modules/" -e "^$" < "${_bruno_log}" \
    | sed '/📊 Execution Summary/,/└.*┘/d' || true
  rm -f "${_bruno_log}"
  # Evaluate results: JSON output is authoritative, exit code catches crashes
  if [[ -s "${_bruno_json}" ]]; then
    if ! python3 "${REPO_ROOT}/scripts/bruno_summary.py" "${_bruno_json}" "${REPORTS_DIR}/bruno-crud.xml"; then
      EXIT_CODE=1
    fi
  elif [[ $_bruno_exit -ne 0 ]]; then
    echo "  Error: Bruno CLI crashed (exit code ${_bruno_exit}) with no test output"
    EXIT_CODE=1
  else
    echo "  Warning: no Bruno JSON output produced"
    EXIT_CODE=1
  fi
  rm -f "${_bruno_json}"
  if [[ $EXIT_CODE -ne 0 ]]; then
    echo "  CRUD tests failed — skipping notebooks (fail-fast)"
    exit "$EXIT_CODE"
  fi
  echo ""
else
  echo ">>> Phase 1: skipped (Bruno CLI not found)"
fi

# ── Phase 2: Notebooks ──────────────────────────────────────────────────────
if [[ -d "$NOTEBOOKS_DIR" ]]; then
  if ! curl -sf --connect-timeout 3 "${BASE_URL}/v1/health" >/dev/null 2>&1; then
    echo "Error: server at ${BASE_URL} is down after Phase 1 — skipping notebooks" >&2
    echo "  The server may have crashed (OOM, sidecar exit). Check sidecar logs." >&2
    exit 1
  fi
  echo ">>> Phase 2: Notebooks — pytest"
  export BASE_URL INFERENCE_MODEL FILES_PROVIDER INFERENCE_PROVIDER VECTOR_IO_PROVIDER EMBEDDING_MODEL
  export MODEL="${INFERENCE_MODEL}"
  export PYTHONPATH="${REPO_ROOT}:${PYTHONPATH:-}"
  if ! (cd "$REPO_ROOT" && uv run pytest tests/test_notebooks.py -v --tb=short --junitxml="${REPORTS_DIR}/notebooks.xml"); then
    EXIT_CODE=1
  fi
  echo ""
fi

echo "=== Done (exit ${EXIT_CODE}) ==="
exit $EXIT_CODE
