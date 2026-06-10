#!/usr/bin/env bash
#
# Start PostgreSQL + OGX containers, auto-discover the model, run tests.
#
# Usage:
#   ./scripts/setup-server.sh              # Full: start infra, run tests, cleanup
#   ./scripts/setup-server.sh --start-only # Start infra, discover model, print info
#   ./scripts/setup-server.sh --tests-only # Run tests against already-running server
#   ./scripts/setup-server.sh --cleanup    # Stop and remove containers
#   ./scripts/setup-server.sh --its        # Konflux ITS mode: podman pod + vLLM sidecars
#
# Options:
#   --start-only     Start PostgreSQL + OGX, then exit
#   --tests-only     Run tests against existing OGX server (uses BASE_URL or localhost:8321)
#   --cleanup        Remove containers and exit
#   --no-cleanup     In full mode, keep containers after tests
#   --its            ITS mode: use podman pod (shared localhost) with vLLM inference
#                    + embedding sidecars. Emulates the Konflux ITS Tekton pipeline.
#   --image IMAGE    Override OGX container image
#   --help           Show this help
#
# Infrastructure env vars (with defaults):
#   OGX_IMAGE   Container image (default: quay.io/rhoai/odh-ogx-core-rhel9:rhoai-3.5-ea.2)
#   OGX_PORT    Host port for OGX (default: 8321)
#   POSTGRES_IMAGE      Postgres image (default: postgres:17-alpine)
#   POSTGRES_USER       Postgres user (default: ogx)
#   POSTGRES_PASSWORD   Postgres password (default: ogx)
#   POSTGRES_DB         Postgres database (default: ogx)
#   POSTGRES_PORT       Host port for Postgres (default: 5432)
#   CLEANUP_DB          Clean DB on startup: true/false (default: false)
# INFERENCE_MODEL       Inference model (default: auto-discovered from server)
#
# ITS mode env vars (defaults match pr-its-pipeline.yaml):
#   VLLM_IMAGE          vLLM image (default: quay.io/opendatahub/vllm-cpu:Qwen3-0.6B-granite-embedding-125m-english)
#   VLLM_INFERENCE_MODEL       Inference model name (default: Qwen/Qwen3-0.6B)
#   VLLM_INFERENCE_MODEL_PATH  Model path in container (default: /root/.cache/Qwen/Qwen3-0.6B)
#   VLLM_EMBEDDING_MODEL       Embedding model name (default: ibm-granite/granite-embedding-125m-english)
#   VLLM_EMBEDDING_MODEL_PATH  Model path in container (default: /root/.cache/ibm-granite/granite-embedding-125m-english)
#
# Provider env vars (forwarded to OGX container if set):
#   VLLM_URL, VLLM_API_TOKEN, VLLM_TLS_VERIFY
#   VLLM_EMBEDDING_URL, VLLM_EMBEDDING_API_TOKEN, VLLM_EMBEDDING_TLS_VERIFY
#   INFERENCE_MODEL, EMBEDDING_MODEL, EMBEDDING_PROVIDER, EMBEDDING_PROVIDER_MODEL_ID
#   GOOGLE_CLOUD_PROJECT, VERTEX_AI_PROJECT, VERTEX_AI_LOCATION, GOOGLE_APPLICATION_CREDENTIALS
#   AWS_BEARER_TOKEN_BEDROCK, AWS_DEFAULT_REGION
#   ENABLE_KUBEFLOW_GARAK, ENABLE_SENTENCE_TRANSFORMERS, OGX_LOGGING
#

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────

OGX_IMAGE="${OGX_IMAGE:-quay.io/rhoai/odh-ogx-core-rhel9:rhoai-3.5-ea.2}"
OGX_PORT="${OGX_PORT:-8321}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-docker.io/pgvector/pgvector:pg17}"
POSTGRES_USER="${POSTGRES_USER:-ogx}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-ogx}"
POSTGRES_DB="${POSTGRES_DB:-ogx}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
CLEANUP_DB="${CLEANUP_DB:-false}"

CONTAINER_NAME_PG="postgres-local"
CONTAINER_NAME_OGX="ogx-local"
NETWORK_NAME="ogx-network"
VOLUME_NAME="postgres-data"

# ITS mode config (matches pr-its-pipeline.yaml)
ITS_MODE=false
POD_NAME="ogx-its-pod"
VLLM_IMAGE="${VLLM_IMAGE:-quay.io/opendatahub/vllm-cpu:Qwen3-0.6B-granite-embedding-125m-english}"
VLLM_INFERENCE_MODEL="${VLLM_INFERENCE_MODEL:-Qwen/Qwen3-0.6B}"
VLLM_INFERENCE_MODEL_PATH="${VLLM_INFERENCE_MODEL_PATH:-/root/.cache/Qwen/Qwen3-0.6B}"
VLLM_EMBEDDING_MODEL="${VLLM_EMBEDDING_MODEL:-ibm-granite/granite-embedding-125m-english}"
VLLM_EMBEDDING_MODEL_PATH="${VLLM_EMBEDDING_MODEL_PATH:-/root/.cache/ibm-granite/granite-embedding-125m-english}"

# Provider env vars forwarded to the OGX container (if set in calling env)
FORWARD_VARS=(
    INFERENCE_MODEL EMBEDDING_MODEL EMBEDDING_PROVIDER EMBEDDING_PROVIDER_MODEL_ID
    VLLM_TLS_VERIFY VLLM_EMBEDDING_TLS_VERIFY
    GOOGLE_CLOUD_PROJECT VERTEX_AI_PROJECT VERTEX_AI_LOCATION
    AWS_BEARER_TOKEN_BEDROCK AWS_DEFAULT_REGION
    OPENAI_API_KEY
    ENABLE_PGVECTOR PGVECTOR_HOST PGVECTOR_PORT PGVECTOR_DB PGVECTOR_USER PGVECTOR_PASSWORD
    ENABLE_KUBEFLOW_GARAK ENABLE_SENTENCE_TRANSFORMERS
    OGX_LOGGING
)

# Sensitive vars to mask in printed commands
SENSITIVE_KEYS_REGEX='^(POSTGRES_PASSWORD|PGVECTOR_PASSWORD|AWS_BEARER_TOKEN_BEDROCK|VLLM_API_TOKEN|VLLM_EMBEDDING_API_TOKEN|OPENAI_API_KEY)$'

# ── Colors ────────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# ── Parse args ────────────────────────────────────────────────────────────────

MODE="full"
DO_CLEANUP=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --start-only)  MODE="start-only"; shift ;;
        --tests-only)  MODE="tests-only"; shift ;;
        --cleanup)     MODE="cleanup"; shift ;;
        --no-cleanup)  DO_CLEANUP=false; shift ;;
        --its)         ITS_MODE=true; shift ;;
        --image)       OGX_IMAGE="$2"; shift 2 ;;
        --help|-h)
            sed -n '2,/^$/{ s/^# \?//; p }' "$0"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}" >&2
            echo "Run with --help for usage." >&2
            exit 1
            ;;
    esac
done

# ── Preflight checks ─────────────────────────────────────────────────────────

check_prerequisites() {
    local missing=()
    command -v podman &>/dev/null || missing+=("podman")
    command -v curl &>/dev/null   || missing+=("curl")
    command -v python3 &>/dev/null || missing+=("python3")

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${RED}Missing required tools: ${missing[*]}${NC}" >&2
        exit 1
    fi
}

# ── Functions ─────────────────────────────────────────────────────────────────

ensure_network() {
    if ! podman network exists "${NETWORK_NAME}" 2>/dev/null; then
        echo "Creating podman network: ${NETWORK_NAME}"
        podman network create "${NETWORK_NAME}"
    fi
}

# ── ITS mode helpers ─────────────────────────────────────────────────────────

wait_for_http() {
    local desc="$1" url="$2" timeout="$3"
    local interval=2 max_interval=15 elapsed=0

    echo -e "${BLUE}Waiting for ${desc} (timeout: ${timeout}s)...${NC}"
    while [[ "$elapsed" -lt "$timeout" ]]; do
        if curl -4 -sf --connect-timeout 3 "$url" >/dev/null 2>&1; then
            echo -e "${GREEN}  ${desc} ready (${elapsed}s)${NC}"
            return 0
        fi
        if (( elapsed % 30 == 0 && elapsed > 0 )); then
            echo -e "${YELLOW}  Still waiting for ${desc}... (${elapsed}s)${NC}"
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
        interval=$((interval < max_interval ? interval * 2 : max_interval))
    done
    echo -e "${RED}  ${desc} not ready after ${timeout}s${NC}" >&2
    return 1
}

create_pod() {
    echo -e "${GREEN}Creating pod: ${POD_NAME}${NC}"
    podman pod rm -f "$POD_NAME" 2>/dev/null || true
    podman pod create \
        --name "$POD_NAME" \
        -p "${OGX_PORT}:8321" \
        -p 8000:8000 \
        -p 8001:8001
}

start_vllm_inference() {
    echo -e "${GREEN}Starting vLLM inference (${VLLM_INFERENCE_MODEL})...${NC}"
    podman run -d \
        --pod "$POD_NAME" \
        --name "${POD_NAME}-vllm-inference" \
        "$VLLM_IMAGE" \
        --host 0.0.0.0 \
        --port 8000 \
        --enable-auto-tool-choice \
        --tool-call-parser hermes \
        --model "$VLLM_INFERENCE_MODEL_PATH" \
        --served-model-name "$VLLM_INFERENCE_MODEL" \
        --max-model-len 8192 \
        --gpu-memory-utilization 0.50

    wait_for_http "vLLM inference" "http://localhost:8000/health" 600
}

start_vllm_embedding() {
    echo -e "${GREEN}Starting vLLM embedding (${VLLM_EMBEDDING_MODEL})...${NC}"
    podman run -d \
        --pod "$POD_NAME" \
        --name "${POD_NAME}-vllm-embedding" \
        "$VLLM_IMAGE" \
        --host 0.0.0.0 \
        --port 8001 \
        --model "$VLLM_EMBEDDING_MODEL_PATH" \
        --served-model-name "$VLLM_EMBEDDING_MODEL" \
        --gpu-memory-utilization 0.05 \
        --hf-overrides '{"is_matryoshka": true}'

    wait_for_http "vLLM embedding" "http://localhost:8001/health" 600
}

# ── Standard mode functions ──────────────────────────────────────────────────

start_postgres() {
    echo -e "${GREEN}Starting PostgreSQL...${NC}"

    local pg_name pg_run_args=()
    if [[ "$ITS_MODE" == true ]]; then
        pg_name="${POD_NAME}-postgres"
        pg_run_args=(--pod "$POD_NAME" --name "$pg_name")
    else
        pg_name="${CONTAINER_NAME_PG}"
        podman rm -f "$pg_name" 2>/dev/null || true
        if ! podman volume exists "${VOLUME_NAME}" 2>/dev/null; then
            podman volume create "${VOLUME_NAME}"
        fi
        ensure_network
        pg_run_args=(
            --name "$pg_name"
            --network "${NETWORK_NAME}"
            -p "${POSTGRES_PORT}:5432"
            -v "${VOLUME_NAME}:/var/lib/postgresql/data/pgdata"
            -e "PGDATA=/var/lib/postgresql/data/pgdata"
        )
    fi

    podman run -d \
        "${pg_run_args[@]}" \
        -e "POSTGRES_DB=${POSTGRES_DB}" \
        -e "POSTGRES_USER=${POSTGRES_USER}" \
        -e "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}" \
        "${POSTGRES_IMAGE}"

    echo "Waiting for PostgreSQL..."
    for i in {1..30}; do
        if podman exec "$pg_name" pg_isready -U "${POSTGRES_USER}" >/dev/null 2>&1; then
            echo -e "${GREEN}PostgreSQL is ready.${NC}"

            if [[ "${CLEANUP_DB}" == "true" ]]; then
                echo "Cleaning up database..."
                if [[ "${POSTGRES_DB}" == "postgres" ]]; then
                    podman exec "$pg_name" psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
                        -c "DROP SCHEMA IF EXISTS public CASCADE;" 2>/dev/null || true
                    podman exec "$pg_name" psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
                        -c "CREATE SCHEMA public;" 2>/dev/null || true
                    podman exec "$pg_name" psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
                        -c "GRANT ALL ON SCHEMA public TO ${POSTGRES_USER};" 2>/dev/null || true
                else
                    podman exec "$pg_name" psql -U "${POSTGRES_USER}" -d postgres \
                        -c "DROP DATABASE IF EXISTS ${POSTGRES_DB};" 2>/dev/null || true
                    podman exec "$pg_name" psql -U "${POSTGRES_USER}" -d postgres \
                        -c "CREATE DATABASE ${POSTGRES_DB};"
                fi
                echo -e "${GREEN}Database cleaned up.${NC}"
            fi
            return 0
        fi
        if [[ $i -eq 30 ]]; then
            echo -e "${RED}PostgreSQL did not become ready within 30 seconds.${NC}" >&2
            podman logs "$pg_name" 2>&1 | tail -20
            exit 1
        fi
        sleep 1
    done
}

start_ogx() {
    echo -e "${GREEN}Starting OGX...${NC}"
    echo "Image: ${OGX_IMAGE}"

    local postgres_host RUN_ARGS=()

    if [[ "$ITS_MODE" == true ]]; then
        postgres_host="localhost"
        RUN_ARGS=(
            --pod "$POD_NAME"
            --name "${POD_NAME}-ogx"
            -e "POSTGRES_HOST=${postgres_host}"
            -e "POSTGRES_PORT=5432"
            -e "POSTGRES_DB=${POSTGRES_DB}"
            -e "POSTGRES_USER=${POSTGRES_USER}"
            -e "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}"
            -e "ENABLE_PGVECTOR=1"
            -e "PGVECTOR_HOST=${postgres_host}"
            -e "PGVECTOR_PORT=5432"
            -e "PGVECTOR_DB=${POSTGRES_DB}"
            -e "PGVECTOR_USER=${POSTGRES_USER}"
            -e "PGVECTOR_PASSWORD=${POSTGRES_PASSWORD}"
            -e "VLLM_URL=http://localhost:8000/v1"
            -e "VLLM_EMBEDDING_URL=http://localhost:8001/v1"
            -e "EMBEDDING_MODEL=${VLLM_EMBEDDING_MODEL}"
            -e "TRUSTYAI_LMEVAL_USE_K8S=False"
        )
    else
        postgres_host="${CONTAINER_NAME_PG}"

        if ! podman ps --format "{{.Names}}" | grep -q "^${CONTAINER_NAME_PG}$"; then
            echo -e "${RED}PostgreSQL container '${CONTAINER_NAME_PG}' is not running.${NC}" >&2
            exit 1
        fi

        podman rm -f "${CONTAINER_NAME_OGX}" 2>/dev/null || true
        ensure_network

        RUN_ARGS=(
            --name "${CONTAINER_NAME_OGX}"
            --network "${NETWORK_NAME}"
            -p "${OGX_PORT}:8321"
            -e "POSTGRES_HOST=${postgres_host}"
            -e "POSTGRES_PORT=5432"
            -e "POSTGRES_DB=${POSTGRES_DB}"
            -e "POSTGRES_USER=${POSTGRES_USER}"
            -e "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}"
        )

        # Forward VLLM_URL with /v1 suffix if needed
        if [[ -n "${VLLM_URL:-}" ]]; then
            local vllm_url="${VLLM_URL}"
            [[ "${vllm_url}" != */v1 ]] && vllm_url="${vllm_url}/v1"
            RUN_ARGS+=(-e "VLLM_URL=${vllm_url}")
        fi
        if [[ -n "${VLLM_API_TOKEN:-}" ]]; then
            RUN_ARGS+=(-e "VLLM_API_TOKEN=${VLLM_API_TOKEN}")
        fi

        # Forward VLLM_EMBEDDING_URL with /v1 suffix if needed
        if [[ -n "${VLLM_EMBEDDING_URL:-}" ]]; then
            local embed_url="${VLLM_EMBEDDING_URL}"
            [[ "${embed_url}" != */v1 ]] && embed_url="${embed_url}/v1"
            RUN_ARGS+=(-e "VLLM_EMBEDDING_URL=${embed_url}")
        fi
        if [[ -n "${VLLM_EMBEDDING_API_TOKEN:-}" ]]; then
            RUN_ARGS+=(-e "VLLM_EMBEDDING_API_TOKEN=${VLLM_EMBEDDING_API_TOKEN}")
        fi

        # Default pgvector connection to the same Postgres instance if enabled
        if [[ -n "${ENABLE_PGVECTOR:-}" ]]; then
            PGVECTOR_HOST="${PGVECTOR_HOST:-${postgres_host}}"
            PGVECTOR_PORT="${PGVECTOR_PORT:-5432}"
            PGVECTOR_DB="${PGVECTOR_DB:-${POSTGRES_DB}}"
            PGVECTOR_USER="${PGVECTOR_USER:-${POSTGRES_USER}}"
            PGVECTOR_PASSWORD="${PGVECTOR_PASSWORD:-${POSTGRES_PASSWORD}}"
            export PGVECTOR_HOST PGVECTOR_PORT PGVECTOR_DB PGVECTOR_USER PGVECTOR_PASSWORD
        fi

        # Mount GCP credentials via podman secret if the file exists
        if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]] && [[ -f "${GOOGLE_APPLICATION_CREDENTIALS}" ]]; then
            podman secret create --replace=true gcp-credentials "${GOOGLE_APPLICATION_CREDENTIALS}" >/dev/null 2>&1
            RUN_ARGS+=(
                --secret gcp-credentials
                -e "GOOGLE_APPLICATION_CREDENTIALS=/run/secrets/gcp-credentials"
            )
        fi

        # Forward remaining provider vars if set
        for var in "${FORWARD_VARS[@]}"; do
            if [[ -n "${!var:-}" ]]; then
                RUN_ARGS+=(-e "${var}=${!var}")
            fi
        done
    fi

    # Print sanitized command
    echo -e "${BLUE}podman run -d${NC}"
    for arg in "${RUN_ARGS[@]}"; do
        if [[ "$arg" =~ ^([A-Z0-9_]+)=(.*)$ ]]; then
            local env_key="${BASH_REMATCH[1]}"
            if [[ "$env_key" =~ $SENSITIVE_KEYS_REGEX ]]; then
                echo -e "  ${BLUE}${env_key}=********${NC}"
                continue
            fi
        fi
        echo -e "  ${BLUE}${arg}${NC}"
    done
    echo -e "  ${BLUE}${OGX_IMAGE}${NC}"

    podman run -d "${RUN_ARGS[@]}" "${OGX_IMAGE}"

    sleep 3
    wait_for_health
}

wait_for_health() {
    local health_url="http://localhost:${OGX_PORT}/v1/health"
    local max_attempts=60
    local ogx_container
    if [[ "$ITS_MODE" == true ]]; then
        ogx_container="${POD_NAME}-ogx"
    else
        ogx_container="${CONTAINER_NAME_OGX}"
    fi

    echo -e "${BLUE}Waiting for OGX health check...${NC}"

    for i in $(seq 1 $max_attempts); do
        local response http_code body
        response=$(curl -s -w "\n%{http_code}" "${health_url}" 2>/dev/null || echo -e "\n000")
        http_code=$(echo "$response" | tail -n1)
        body=$(echo "$response" | head -n-1)

        if [[ "$http_code" == "200" ]]; then
            if echo "$body" | grep -q '"status".*"OK"'; then
                echo -e "${GREEN}OGX is healthy!${NC}"
                return 0
            fi
        fi

        if (( i % 5 == 0 )); then
            echo -e "${YELLOW}  Attempt ${i}/${max_attempts}... (HTTP ${http_code})${NC}"
        fi
        sleep 2
    done

    echo -e "${RED}Health check failed after ${max_attempts} attempts.${NC}" >&2
    echo "Check logs: podman logs ${ogx_container}" >&2
    podman logs "${ogx_container}" 2>&1 | tail -30
    exit 1
}

discover_model() {
    if [[ -n "${INFERENCE_MODEL:-}" ]]; then
        echo "Using pre-set INFERENCE_MODEL=${INFERENCE_MODEL}"
        return 0
    fi

    local models_url="http://localhost:${OGX_PORT}/v1/models"
    echo "Discovering inference model from ${models_url}..."

    local response
    response=$(curl -sS "${models_url}") || {
        echo -e "${RED}Failed to query /v1/models${NC}" >&2
        exit 1
    }

    INFERENCE_MODEL=$(python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
for m in data.get('data', []):
    meta = m.get('custom_metadata', {}) or {}
    if meta.get('model_type') != 'embedding':
        print(m['id']); sys.exit(0)
print('')
" <<< "$response")

    if [[ -z "$INFERENCE_MODEL" ]]; then
        echo -e "${RED}No non-embedding model found on the server.${NC}" >&2
        echo "Response:" >&2
        python3 -m json.tool <<< "$response" 2>/dev/null || echo "$response" >&2
        exit 1
    fi

    export INFERENCE_MODEL
    echo -e "${GREEN}Discovered model: ${INFERENCE_MODEL}${NC}"
}

discover_embedding_model() {
    if [[ -n "${EMBEDDING_MODEL:-}" ]]; then
        echo "Using pre-set EMBEDDING_MODEL=${EMBEDDING_MODEL}"
        return 0
    fi

    local models_url="http://localhost:${OGX_PORT}/v1/models"
    echo "Discovering embedding model from ${models_url}..."

    local response
    response=$(curl -sS "${models_url}") || {
        echo -e "${YELLOW}Failed to query /v1/models for embedding — skipping${NC}" >&2
        return 0
    }

    EMBEDDING_MODEL=$(python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
for m in data.get('data', []):
    meta = m.get('custom_metadata', {}) or {}
    if meta.get('model_type') == 'embedding':
        print(m['id']); sys.exit(0)
print('')
" <<< "$response")

    if [[ -z "$EMBEDDING_MODEL" ]]; then
        echo -e "${YELLOW}No embedding model found on the server.${NC}"
        return 0
    fi

    export EMBEDDING_MODEL
    echo -e "${GREEN}Discovered embedding model: ${EMBEDDING_MODEL}${NC}"
}

discover_providers() {
    local providers_url="http://localhost:${OGX_PORT}/v1/providers"
    echo "Discovering providers from ${providers_url}..."

    local response
    response=$(curl -sS "${providers_url}" 2>/dev/null) || {
        echo -e "${YELLOW}Failed to query /v1/providers — skipping${NC}" >&2
        return 0
    }

    while IFS='=' read -r key value; do
        [[ -z "$key" ]] && continue
        export "$key=$value"
    done < <(python3 -c "
import json, sys, re
data = json.loads(sys.stdin.read()).get('data', [])
api_map = {}
for p in data:
    api = p.get('api', '')
    pid = p.get('provider_id', '')
    if api and pid and api not in api_map and re.fullmatch(r'[a-zA-Z0-9_.:-]+', pid):
        api_map[api] = pid
for k in ('inference', 'files', 'vector_io'):
    if k in api_map:
        print(f'{k.upper()}_PROVIDER={api_map[k]}')
" <<< "$response")

    export INFERENCE_PROVIDER="${INFERENCE_PROVIDER:-}"
    export FILES_PROVIDER="${FILES_PROVIDER:-}"
    export VECTOR_IO_PROVIDER="${VECTOR_IO_PROVIDER:-}"
    echo -e "${GREEN}Discovered providers: inference=${INFERENCE_PROVIDER} files=${FILES_PROVIDER} vector_io=${VECTOR_IO_PROVIDER}${NC}"
}

run_tests() {
    export BASE_URL="http://localhost:${OGX_PORT}"
    export INFERENCE_MODEL
    export EMBEDDING_MODEL="${EMBEDDING_MODEL:-}"
    export INFERENCE_PROVIDER="${INFERENCE_PROVIDER:-}"
    export FILES_PROVIDER="${FILES_PROVIDER:-}"
    export VECTOR_IO_PROVIDER="${VECTOR_IO_PROVIDER:-}"
    # MCP test server runs on the host; OGX in a container can't reach host's localhost.
    # Use host.containers.internal (podman's host gateway) for both pod and bridge modes.
    # In Konflux ITS (real Kubernetes pod), override to http://localhost:${MCP_PORT}.
    export MCP_SERVER_URL="${MCP_SERVER_URL:-http://host.containers.internal:${MCP_PORT:-8322}}"

    echo -e "${GREEN}Running functional tests...${NC}"
    echo "  BASE_URL=${BASE_URL}"
    echo "  INFERENCE_MODEL=${INFERENCE_MODEL}"
    echo "  EMBEDDING_MODEL=${EMBEDDING_MODEL}"
    echo "  MCP_SERVER_URL=${MCP_SERVER_URL}"

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    "${script_dir}/run-tests-with-providers.sh"
}

cleanup() {
    if [[ "$ITS_MODE" == true ]]; then
        echo -e "${YELLOW}Removing pod: ${POD_NAME}${NC}"
        podman pod rm -f "$POD_NAME" 2>/dev/null || true
        echo -e "${GREEN}Pod removed.${NC}"
    else
        echo -e "${YELLOW}Cleaning up containers...${NC}"
        for c in "${CONTAINER_NAME_OGX}" "${CONTAINER_NAME_PG}"; do
            podman rm -f "$c" 2>/dev/null || true
        done
        echo -e "${GREEN}Containers removed.${NC}"
        echo "Network '${NETWORK_NAME}' and volume '${VOLUME_NAME}' kept for fast restarts."
        echo "To remove: podman network rm ${NETWORK_NAME}; podman volume rm ${VOLUME_NAME}"
    fi
}

print_status() {
    echo ""
    echo "========================================"
    if [[ "$ITS_MODE" == true ]]; then
        echo -e "${GREEN}ITS pod is running: ${POD_NAME}${NC}"
    else
        echo -e "${GREEN}Infrastructure is running.${NC}"
    fi
    echo "========================================"
    echo "  OGX server:  http://localhost:${OGX_PORT}"
    if [[ "$ITS_MODE" == true ]]; then
        echo "  vLLM inference:  http://localhost:8000  (${VLLM_INFERENCE_MODEL})"
        echo "  vLLM embedding:  http://localhost:8001  (${VLLM_EMBEDDING_MODEL})"
    fi
    echo "  PostgreSQL:  localhost:${POSTGRES_PORT}"
    echo "  INFERENCE_MODEL:       ${INFERENCE_MODEL}"
    echo "  Image:       ${OGX_IMAGE}"
    echo ""
    echo "Run tests:"
    if [[ "$ITS_MODE" == true ]]; then
        echo "  ./scripts/setup-server.sh --its --tests-only"
    else
        echo "  ./scripts/setup-server.sh --tests-only"
    fi
    echo "  # or manually:"
    echo "  BASE_URL=http://localhost:${OGX_PORT} INFERENCE_MODEL=${INFERENCE_MODEL} ./scripts/run-tests-with-providers.sh"
    echo ""
    echo "Logs:"
    if [[ "$ITS_MODE" == true ]]; then
        echo "  podman logs -f ${POD_NAME}-ogx"
        echo "  podman logs -f ${POD_NAME}-vllm-inference"
        echo "  podman logs -f ${POD_NAME}-vllm-embedding"
    else
        echo "  podman logs -f ${CONTAINER_NAME_OGX}"
    fi
    echo ""
    echo "Cleanup:"
    if [[ "$ITS_MODE" == true ]]; then
        echo "  ./scripts/setup-server.sh --its --cleanup"
    else
        echo "  ./scripts/setup-server.sh --cleanup"
    fi

    if [[ "$ITS_MODE" == true ]]; then
        echo ""
        echo "Containers:"
        podman ps --filter "pod=${POD_NAME}" --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

check_prerequisites

case "$MODE" in
    cleanup)
        cleanup
        ;;

    tests-only)
        export BASE_URL="${BASE_URL:-http://localhost:${OGX_PORT}}"
        # Verify server is reachable
        if ! curl -fsS "${BASE_URL}/v1/health" >/dev/null 2>&1; then
            echo -e "${RED}No OGX server at ${BASE_URL}${NC}" >&2
            echo "Start one first, or run without --tests-only for full setup." >&2
            exit 1
        fi
        echo -e "${GREEN}Found running OGX at ${BASE_URL}${NC}"
        discover_model
        discover_embedding_model
        discover_providers
        run_tests
        ;;

    start-only)
        if [[ "$ITS_MODE" == true ]]; then
            create_pod
        fi
        start_postgres
        if [[ "$ITS_MODE" == true ]]; then
            start_vllm_inference
            start_vllm_embedding
        fi
        start_ogx
        discover_model
        discover_embedding_model
        discover_providers
        print_status
        ;;

    full)
        if [[ "$DO_CLEANUP" == true ]]; then
            trap cleanup EXIT
        fi
        if [[ "$ITS_MODE" == true ]]; then
            create_pod
        fi
        start_postgres
        if [[ "$ITS_MODE" == true ]]; then
            start_vllm_inference
            start_vllm_embedding
        fi
        start_ogx
        discover_model
        discover_embedding_model
        discover_providers
        run_tests
        echo -e "${GREEN}All tests passed!${NC}"
        ;;
esac
