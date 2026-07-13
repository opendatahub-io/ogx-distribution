#!/bin/bash

set -uo pipefail

# Source common test utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/test_utils.sh"

OGX_BASE_URL="http://127.0.0.1:8321"

function start_and_wait_for_ogx_container {
  # Build docker run command with base arguments
  docker_args=(
    -d
    --pull=never
    --net=host
    -p 8321:8321
    --env "EMBEDDING_MODEL=$EMBEDDING_MODEL"
    --env "VLLM_URL=$VLLM_URL"
    --env "VLLM_EMBEDDING_URL=$VLLM_EMBEDDING_URL"
    --env "POSTGRES_HOST=${POSTGRES_HOST:-localhost}"
    --env "POSTGRES_PORT=${POSTGRES_PORT:-5432}"
    --env "POSTGRES_DB=${POSTGRES_DB:-ogx}"
    --env "POSTGRES_USER=${POSTGRES_USER:-ogx}"
    --env "POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-ogx}"
    --env "ENABLE_PGVECTOR=1"
    --env "PGVECTOR_HOST=${POSTGRES_HOST:-localhost}"
    --env "PGVECTOR_PORT=${POSTGRES_PORT:-5432}"
    --env "PGVECTOR_DB=${POSTGRES_DB:-ogx}"
    --env "PGVECTOR_USER=${POSTGRES_USER:-ogx}"
    --env "PGVECTOR_PASSWORD=${POSTGRES_PASSWORD:-ogx}"
  )

  # Conditionally add vLLM API token (needed for MaaS)
  if [ -n "${VLLM_API_TOKEN:-}" ]; then
    docker_args+=(--env "VLLM_API_TOKEN=$VLLM_API_TOKEN")
  fi

  # Conditionally add embedding configuration
  if [ -n "${VLLM_EMBEDDING_API_TOKEN:-}" ]; then
    docker_args+=(--env "VLLM_EMBEDDING_API_TOKEN=$VLLM_EMBEDDING_API_TOKEN")
  fi
  if [ -n "${EMBEDDING_PROVIDER:-}" ]; then
    docker_args+=(--env "EMBEDDING_PROVIDER=$EMBEDDING_PROVIDER")
  fi
  if [ -n "${EMBEDDING_PROVIDER_MODEL_ID:-}" ]; then
    docker_args+=(--env "EMBEDDING_PROVIDER_MODEL_ID=$EMBEDDING_PROVIDER_MODEL_ID")
  fi

  # Only add Vertex AI configuration if VERTEX_AI_PROJECT is set AND credentials file exists
  # (GCP auth step only runs on amd64, so credentials won't exist on arm64)
  if [ -n "${VERTEX_AI_PROJECT:-}" ] && [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ] && [ -f "$GOOGLE_APPLICATION_CREDENTIALS" ]; then
    docker_args+=(
      --env "VERTEX_AI_PROJECT=$VERTEX_AI_PROJECT"
      --env "VERTEX_AI_LOCATION=${VERTEX_AI_LOCATION:-global}"
      --env "GOOGLE_APPLICATION_CREDENTIALS=/run/secrets/gcp-credentials"
      --volume "$GOOGLE_APPLICATION_CREDENTIALS:/run/secrets/gcp-credentials:ro"
    )
  fi

  # Only add OpenAI configuration if OPENAI_API_KEY is set
  if [ -n "${OPENAI_API_KEY:-}" ]; then
    docker_args+=(--env "OPENAI_API_KEY=$OPENAI_API_KEY")
  fi

  # Only add Gemini configuration if GEMINI_API_KEY is set
  if [ -n "${GEMINI_API_KEY:-}" ]; then
    docker_args+=(
      --env "ENABLE_GEMINI=1"
      --env "GEMINI_API_KEY=$GEMINI_API_KEY"
    )
  fi

  # Only add Anthropic configuration if ANTHROPIC_API_KEY is set
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    docker_args+=(--env "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
  fi

  docker_args+=(--name ogx "$IMAGE_NAME:${IMAGE_TAG:-$GITHUB_SHA}")

  # Start ogx
  docker run "${docker_args[@]}"
  echo "Started OGX container..."

  # Wait for ogx to be ready by doing a health check
  echo "Waiting for OGX server..."
  for i in {1..60}; do
    echo "Attempt $i to connect to OGX..."
    resp=$(curl -fsS $OGX_BASE_URL/v1/health)
    if [ "$resp" == '{"status":"OK"}' ]; then
      echo "OGX server is up!"
      return
    fi
    sleep 1
  done
  echo "OGX server failed to start :("
  echo "Container logs:"
  docker logs ogx || true
  exit 1
}

function test_model_list {
  validate_model_parameter "$1"
  local model="$1"
  echo "===> Looking for model $model..."
  resp=$(curl -fsS $OGX_BASE_URL/v1/models)
  echo "Response: $resp"
  if echo "$resp" | grep -q "$model"; then
    echo "Model $model was found :)"
  else
    echo "Model $model was not found :("
    echo "Response: $resp"
    echo "Container logs:"
    docker logs ogx || true
    return 1
  fi
  return 0
}

function test_model_openai_inference {
  validate_model_parameter "$1"
  local model="$1"
  echo "===> Attempting to chat with model $model..."
  resp=$(curl -fsS $OGX_BASE_URL/v1/chat/completions -H "Content-Type: application/json" -d "{\"model\": \"$model\",\"messages\": [{\"role\": \"user\", \"content\": \"What color is grass?\"}], \"max_tokens\": 128, \"temperature\": 0.0}")
  if echo "$resp" | grep -q "green"; then
    echo "===> Inference is working :)"
    return 0
  else
    echo "===> Inference is not working :("
    echo "Response: $resp"
    echo "Container logs:"
    docker logs ogx || true
    return 1
  fi
}

function test_messages_basic {
  validate_model_parameter "$1"
  local model="$1"
  echo "===> Testing Messages API (/v1/messages) single-turn request for model $model..."
  # Anthropic-compatible Messages API. The anthropic-version header is required.
  resp=$(curl -fsS "$OGX_BASE_URL/v1/messages" \
    -H "Content-Type: application/json" \
    -H "anthropic-version: 2023-06-01" \
    -d "{\"model\": \"$model\", \"max_tokens\": 128, \"messages\": [{\"role\": \"user\", \"content\": \"What is 2+2? Reply with just the number.\"}]}")

  # Validate the Anthropic response shape: a `message` from the `assistant`
  # containing at least one non-empty text block.
  if echo "$resp" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data.get("type") == "message", "type=" + repr(data.get("type"))
assert data.get("role") == "assistant", "role=" + repr(data.get("role"))
content = data.get("content") or []
text_blocks = [b for b in content if b.get("type") == "text" and b.get("text")]
assert text_blocks, "no non-empty text blocks: " + repr(content)
'; then
    echo "===> Messages API is working :)"
    return 0
  else
    echo "===> Messages API is not working :("
    echo "Response: $resp"
    echo "Container logs:"
    docker logs ogx 2>/dev/null | tail -50 || true
    return 1
  fi
}

function test_postgres_tables_exist {
  echo "===> Verifying PostgreSQL tables have been created..."

  # Expected tables created by ogx
  expected_tables=("ogx_kvstore" "inference_store")

  # Retry for up to 10 seconds for tables to be created
  for i in {1..10}; do
    tables=$(docker exec postgres psql -U ogx -d ogx -t -c "SELECT tablename FROM pg_tables WHERE schemaname = 'public';" 2>/dev/null | tr -d ' ' | tr '\n' ' ')
    all_found=true
    for table in "${expected_tables[@]}"; do
      if ! echo "$tables" | grep -q "$table"; then
        all_found=false
        break
      fi
    done
    if [ "$all_found" = true ]; then
      echo "===> All expected tables found: ${expected_tables[*]}"
      echo "===> Available tables: $tables"
      return 0
    fi
    echo "Attempt $i: Waiting for tables to be created..."
    sleep 1
  done

  echo "===> PostgreSQL tables not created after 10s :("
  echo "Expected tables: ${expected_tables[*]}"
  echo "Available tables: $tables"
  docker exec postgres psql -U ogx -d ogx -c "\dt" || true
  return 1
}

function test_postgres_populated {
  echo "===> Verifying PostgreSQL database has been populated..."

  # Check that chat_completions table has data (retry for up to 10 seconds)
  echo "Waiting for inference_store table to be populated..."
  for i in {1..10}; do
    inference_count=$(docker exec postgres psql -U ogx -d ogx -t -c "SELECT COUNT(*) FROM inference_store;" 2>/dev/null | tr -d ' ')
    if [ -n "$inference_count" ] && [ "$inference_count" -gt 0 ]; then
      echo "===> inference_store table has $inference_count record(s)"
      break
    fi
    echo "Attempt $i: inference_store table not yet populated..."
    sleep 1
  done
  if [ -z "$inference_count" ] || [ "$inference_count" -eq 0 ]; then
    echo "===> PostgreSQL inference_store table is empty or doesn't exist after 10s :("
    echo "Tables in database:"
    docker exec postgres psql -U ogx -d ogx -c "\dt" || true
    echo "inference_store table contents:"
    docker exec postgres psql -U ogx -d ogx -t -c "SELECT COUNT(*) FROM inference_store;" || true
    return 1
  fi

  echo "===> PostgreSQL database verification passed :)"
  return 0
}

function test_file_processor_pypdf {
  echo "===> Verifying file processor (inline::pypdf) with sample PDF..."

  # Must match text embedded in tests/fixtures/sample.pdf (not guessable by an LLM).
  local expected_marker="OGX-RAG-SMOKE-7f3a9c2e8b1d4f06"
  local pdf_path="$SCRIPT_DIR/fixtures/sample.pdf"
  if [ ! -f "$pdf_path" ]; then
    echo "===> Sample PDF not found at $pdf_path :("
    return 1
  fi

  resp=$(curl -fsS "$OGX_BASE_URL/v1alpha/file-processors/process" -F "file=@$pdf_path;type=application/pdf")
  echo "Response: $resp"

  if ! echo "$resp" | grep -q '"processor"[[:space:]]*:[[:space:]]*"pypdf"'; then
    echo "===> File processor response missing pypdf metadata :("
    docker logs ogx 2>/dev/null | tail -50 || true
    return 1
  fi

  if ! echo "$resp" | grep -qF "$expected_marker"; then
    echo "===> File processor did not extract expected PDF marker ($expected_marker) :("
    docker logs ogx 2>/dev/null | tail -50 || true
    return 1
  fi

  echo "===> File processor (inline::pypdf) is working :)"
  return 0
}

function test_rag_file_ingestion {
  echo "===> Verifying RAG file ingestion pipeline (upload → vector store → index)..."

  local pdf_path="$SCRIPT_DIR/fixtures/sample.pdf"
  if [ ! -f "$pdf_path" ]; then
    echo "===> Sample PDF not found at $pdf_path :("
    return 1
  fi

  upload_resp=$(curl -fsS "$OGX_BASE_URL/v1/files" \
    -F "file=@$pdf_path;type=application/pdf" \
    -F "purpose=assistants")
  echo "Upload response: $upload_resp"

  file_id=$(echo "$upload_resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null)
  if [ -z "$file_id" ]; then
    echo "===> Failed to upload file :("
    docker logs ogx 2>/dev/null | tail -50 || true
    return 1
  fi
  echo "===> Uploaded file: $file_id"

  vs_resp=$(curl -fsS "$OGX_BASE_URL/v1/vector_stores" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"smoke-test-rag\",\"embedding_model\":\"$EMBEDDING_MODEL\"}")
  echo "Vector store response: $vs_resp"

  vs_id=$(echo "$vs_resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null)
  if [ -z "$vs_id" ]; then
    echo "===> Failed to create vector store :("
    docker logs ogx 2>/dev/null | tail -50 || true
    return 1
  fi
  echo "===> Created vector store: $vs_id"

  attach_resp=$(curl -fsS "$OGX_BASE_URL/v1/vector_stores/$vs_id/files" \
    -H "Content-Type: application/json" \
    -d "{\"file_id\":\"$file_id\"}")
  echo "Attach response: $attach_resp"

  attached_file_id=$(echo "$attach_resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
  if [ -z "$attached_file_id" ]; then
    echo "===> Failed to attach file to vector store :("
    docker logs ogx 2>/dev/null | tail -50 || true
    return 1
  fi

  echo "===> Polling file ingestion status..."
  for i in {1..30}; do
    status_resp=$(curl -fsS "$OGX_BASE_URL/v1/vector_stores/$vs_id/files/$attached_file_id" 2>/dev/null || echo '{}')
    file_status=$(echo "$status_resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null)

    if [ "$file_status" = "completed" ]; then
      echo "===> File ingestion completed successfully :)"
      return 0
    elif [ "$file_status" = "failed" ]; then
      echo "===> File ingestion failed :("
      echo "Status response: $status_resp"
      docker logs ogx 2>/dev/null | tail -50 || true
      return 1
    fi

    echo "  Attempt $i: status=$file_status, waiting..."
    sleep 1
  done

  echo "===> File ingestion timed out after 30s :("
  docker logs ogx 2>/dev/null | tail -50 || true
  return 1
}

function wait_for_ogx_health {
  echo "Waiting for OGX server..."
  for i in {1..60}; do
    if [ "$(curl -fsS "$OGX_BASE_URL/v1/health" 2>/dev/null)" == '{"status":"OK"}' ]; then
      echo "OGX server is up!"
      return 0
    fi
    sleep 1
  done
  echo "OGX server failed to become healthy :("
  docker logs ogx 2>/dev/null | tail -50 || true
  return 1
}

main() {
  # Messages-only mode: the container is already running (started elsewhere,
  # e.g. the setup-server action). Run just the Messages API smoke against
  # MESSAGES_SMOKE_MODEL and exit. Used by the messages-openai.yml workflow.
  if [ "${MESSAGES_SMOKE_ONLY:-false}" == "true" ]; then
    echo "===> Running Messages API smoke only (model: ${MESSAGES_SMOKE_MODEL:-<unset>})..."
    wait_for_ogx_health || exit 1
    if test_messages_basic "${MESSAGES_SMOKE_MODEL:-}"; then
      echo "===> Messages API smoke completed successfully!"
      return 0
    fi
    echo "===> Messages API smoke failed!"
    exit 1
  fi

  echo "===> Starting smoke test..."
  start_and_wait_for_ogx_container

  # Track failures
  failed_checks=()

  if [ "${SKIP_INFERENCE_TESTS:-false}" == "true" ]; then
    echo "===> SKIP_INFERENCE_TESTS is set, running container health and PostgreSQL verification only"
    echo "===> Skipping model list, inference, and data population checks (no vLLM available)"

    if ! test_postgres_tables_exist; then
      failed_checks+=("postgres:tables")
    fi
  else
    # Build list of models to test based on available configuration
    models_to_test=("$VLLM_INFERENCE_MODEL" "$EMBEDDING_MODEL")
    inference_models_to_test=("$VLLM_INFERENCE_MODEL")

    # Only include Vertex AI models if credentials are available
    if [ -n "${VERTEX_AI_PROJECT:-}" ] && [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ] && [ -f "$GOOGLE_APPLICATION_CREDENTIALS" ]; then
      echo "===> Vertex AI credentials available, including Vertex AI models in tests"
      models_to_test+=("$VERTEX_AI_INFERENCE_MODEL")
      inference_models_to_test+=("$VERTEX_AI_INFERENCE_MODEL")
    else
      echo "===> Vertex AI credentials not available, skipping Vertex AI models"
    fi

    # Only include OpenAI models if OPENAI_API_KEY is set
    if [ -n "${OPENAI_API_KEY:-}" ]; then
      echo "===> OPENAI_API_KEY is set, including OpenAI models in tests"
      models_to_test+=("$OPENAI_INFERENCE_MODEL")
      inference_models_to_test+=("$OPENAI_INFERENCE_MODEL")
    else
      echo "===> OPENAI_API_KEY is not set, skipping OpenAI models"
    fi

    # Only include Gemini models if GEMINI_API_KEY is set
    if [ -n "${GEMINI_API_KEY:-}" ]; then
      echo "===> GEMINI_API_KEY is set, including Gemini models in tests"
      models_to_test+=("$GEMINI_INFERENCE_MODEL")
      inference_models_to_test+=("$GEMINI_INFERENCE_MODEL")
    else
      echo "===> GEMINI_API_KEY is not set, skipping Gemini models"
    fi

    # Only include Anthropic models if ANTHROPIC_API_KEY is set
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
      echo "===> ANTHROPIC_API_KEY is set, including Anthropic models in tests"
      models_to_test+=("$ANTHROPIC_INFERENCE_MODEL")
      inference_models_to_test+=("$ANTHROPIC_INFERENCE_MODEL")
    else
      echo "===> ANTHROPIC_API_KEY is not set, skipping Anthropic models"
    fi

    echo "===> Testing model list for all models..."
    for model in "${models_to_test[@]}"; do
      if ! test_model_list "$model"; then
        failed_checks+=("model_list:$model")
      fi
    done

    echo "===> Testing inference for all models..."
    for model in "${inference_models_to_test[@]}"; do
      if ! test_model_openai_inference "$model"; then
        failed_checks+=("inference:$model")
      fi
    done

    # Basic Messages API (/v1/messages) smoke against the vLLM model.
    # Skipped on MaaS: the RHOAI 3scale (apicast) gateway only exposes
    # /v1/chat/completions and returns 403 "No Mapping Rule matched" for
    # /v1/messages, so native passthrough cannot succeed through it. Native
    # passthrough is covered deterministically against a local vLLM by
    # messages-vllm.yml; OpenAI translation by messages-openai.yml.
    #
    # Also temporarily skipped for local vLLM: upstream OGX bug
    # constructs a double "/v1/v1/messages" URL for the vLLM provider,
    # causing a 404. Re-enable once fixed upstream.
    # https://github.com/ogx-ai/ogx/issues/6290
    if [ "${USING_MAAS:-false}" == "true" ]; then
      echo "===> Skipping Messages API smoke (MaaS gateway has no /v1/messages route)"
    else
      echo "===> Skipping Messages API smoke (upstream OGX bug: double /v1 path, see ogx-ai/ogx#6290)"
    fi

    # Verify PostgreSQL tables and data
    if ! test_postgres_tables_exist; then
      failed_checks+=("postgres:tables")
    fi
    if ! test_postgres_populated; then
      failed_checks+=("postgres:data")
    fi
  fi

  if ! test_file_processor_pypdf; then
    failed_checks+=("file_processor:pypdf")
  fi

  if ! test_rag_file_ingestion; then
    failed_checks+=("rag:file_ingestion")
  fi

  # Report results
  if [ ${#failed_checks[@]} -eq 0 ]; then
    echo "===> Smoke test completed successfully!"
    return 0
  else
    echo "===> Smoke test failed for the following:"
    for failure in "${failed_checks[@]}"; do
      echo "  - $failure"
    done
    exit 1
  fi
}

main "$@"
exit 0
