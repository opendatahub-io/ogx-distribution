#!/bin/bash

set -uo pipefail

# Source common test utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/test_utils.sh"

LLAMA_STACK_BASE_URL="http://127.0.0.1:8321"

function start_and_wait_for_llama_stack_container {
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
    --env "POSTGRES_DB=${POSTGRES_DB:-llamastack}"
    --env "POSTGRES_USER=${POSTGRES_USER:-llamastack}"
    --env "POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-llamastack}"
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
      --env "GOOGLE_APPLICATION_CREDENTIALS=/run/secrets/gcp-credentials"
      --volume "$GOOGLE_APPLICATION_CREDENTIALS:/run/secrets/gcp-credentials:ro"
    )
  fi

  # Only add OpenAI configuration if OPENAI_API_KEY is set
  if [ -n "${OPENAI_API_KEY:-}" ]; then
    docker_args+=(--env "OPENAI_API_KEY=$OPENAI_API_KEY")
  fi

  docker_args+=(--name llama-stack "$IMAGE_NAME:${IMAGE_TAG:-$GITHUB_SHA}")

  # Start llama stack
  echo docker run "${docker_args[@]}"
  docker run "${docker_args[@]}"
  echo "Started Llama Stack container..."

  # Wait for llama stack to be ready by doing a health check
  echo "Waiting for Llama Stack server..."
  for i in {1..60}; do
    echo "Attempt $i to connect to Llama Stack..."
    resp=$(curl -fsS $LLAMA_STACK_BASE_URL/v1/health)
    if [ "$resp" == '{"status":"OK"}' ]; then
      echo "Llama Stack server is up!"
      return
    fi
    sleep 1
  done
  echo "Llama Stack server failed to start :("
  echo "Container logs:"
  docker logs llama-stack || true
  exit 1
}

function test_model_list {
  validate_model_parameter "$1"
  local model="$1"
  echo "===> Looking for model $model..."
  resp=$(curl -fsS $LLAMA_STACK_BASE_URL/v1/models)
  echo "Response: $resp"
  if echo "$resp" | grep -q "$model"; then
    echo "Model $model was found :)"
  else
    echo "Model $model was not found :("
    echo "Response: $resp"
    echo "Container logs:"
    docker logs llama-stack || true
    return 1
  fi
  return 0
}

function test_model_openai_inference {
  validate_model_parameter "$1"
  local model="$1"
  echo "===> Attempting to chat with model $model..."
  resp=$(curl -fsS $LLAMA_STACK_BASE_URL/v1/chat/completions -H "Content-Type: application/json" -d "{\"model\": \"$model\",\"messages\": [{\"role\": \"user\", \"content\": \"What color is grass?\"}], \"max_tokens\": 128, \"temperature\": 0.0}")
  if echo "$resp" | grep -q "green"; then
    echo "===> Inference is working :)"
    return 0
  else
    echo "===> Inference is not working :("
    echo "Response: $resp"
    echo "Container logs:"
    docker logs llama-stack || true
    return 1
  fi
}

function test_postgres_tables_exist {
  echo "===> Verifying PostgreSQL tables have been created..."

  # Expected tables created by llama-stack
  expected_tables=("llamastack_kvstore" "inference_store")

  # Retry for up to 10 seconds for tables to be created
  for i in {1..10}; do
    tables=$(docker exec postgres psql -U llamastack -d llamastack -t -c "SELECT tablename FROM pg_tables WHERE schemaname = 'public';" 2>/dev/null | tr -d ' ' | tr '\n' ' ')
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
  docker exec postgres psql -U llamastack -d llamastack -c "\dt" || true
  return 1
}

function test_postgres_populated {
  echo "===> Verifying PostgreSQL database has been populated..."

  # Check that chat_completions table has data (retry for up to 10 seconds)
  echo "Waiting for inference_store table to be populated..."
  for i in {1..10}; do
    inference_count=$(docker exec postgres psql -U llamastack -d llamastack -t -c "SELECT COUNT(*) FROM inference_store;" 2>/dev/null | tr -d ' ')
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
    docker exec postgres psql -U llamastack -d llamastack -c "\dt" || true
    echo "inference_store table contents:"
    docker exec postgres psql -U llamastack -d llamastack -t -c "SELECT COUNT(*) FROM inference_store;" || true
    return 1
  fi

  echo "===> PostgreSQL database verification passed :)"
  return 0
}

main() {
  echo "===> Starting smoke test..."
  start_and_wait_for_llama_stack_container

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

    # Verify PostgreSQL tables and data
    if ! test_postgres_tables_exist; then
      failed_checks+=("postgres:tables")
    fi
    if ! test_postgres_populated; then
      failed_checks+=("postgres:data")
    fi
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
