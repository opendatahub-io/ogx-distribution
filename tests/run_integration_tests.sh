#!/usr/bin/env bash

set -exuo pipefail

# Configuration
WORK_DIR="/tmp/ogx-integration-tests"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common test utilities
# shellcheck source=/dev/null
source "$SCRIPT_DIR/test_utils.sh"

# Get repository and version from build.env
BUILD_ENV="$SCRIPT_DIR/../build/build.env"
OGX_VERSION=$(grep '^OGX_VERSION=' "$BUILD_ENV" | cut -d= -f2)
if [ -z "$OGX_VERSION" ]; then
    echo "Error: Could not extract OGX_VERSION from build.env"
    exit 1
fi
# Extract repo URL from build.py constant
OGX_REPO=$(grep 'OGX_GIT_REPO' "$SCRIPT_DIR/../build/build.py" | grep -o 'https://[^"]*')
if [ -z "$OGX_REPO" ]; then
    echo "Error: Could not extract OGX_GIT_REPO from build.py"
    exit 1
fi
# Strip .git suffix for cloning and leading v for version display
OGX_REPO=${OGX_REPO%.git}

function clone_ogx() {
    # Clone the repository if it doesn't exist
    if [ ! -d "$WORK_DIR" ]; then
        git clone "$OGX_REPO" "$WORK_DIR"
    fi

    # Checkout the specific tag
    cd "$WORK_DIR"
    # fetch origin incase we didn't clone a fresh repo
    git fetch origin
    checkout_to="$OGX_VERSION"
    if ! git checkout "$checkout_to"; then
        echo "Error: Could not checkout $checkout_to"
        echo "Available tags:"
        git tag | tail -10
        exit 1
    fi
}

function run_integration_tests() {
    validate_model_parameter "$1"
    local model="$1"
    echo "Running integration tests for model $model..."

    cd "$WORK_DIR"

    # Test to skip
    # TODO: re-enable the 2 chat_completion_non_streaming tests once they contain include max tokens (to prevent them from rambling)
    # test_openai_completion_guided_choice needs vllm  >= v0.12.0 https://github.com/llamastack/llama-stack/issues/4984
    # test_openai_embeddings_with_dimensions and test_openai_embeddings_with_encoding_format_base64
    # pass a `dimensions` parameter which requires matryoshka representation support.
    # granite-embedding-125m-english was not trained with Matryoshka Representation Learning,
    # so vLLM correctly rejects these requests with a 400 error. sentence-transformers silently
    # truncated without validation, masking the issue.
    # test_openai_completion_logprobs{,_streaming}: upstream schema defines logprobs as bool, should be int https://github.com/llamastack/llama-stack/issues/5253
    SKIP_TESTS="test_text_chat_completion_tool_calling_tools_not_in_request or test_text_chat_completion_structured_output or test_text_chat_completion_non_streaming or test_openai_chat_completion_non_streaming or test_openai_chat_completion_with_tool_choice_none or test_openai_chat_completion_with_tools or test_openai_format_preserves_complex_schemas or test_multiple_tools_with_different_schemas or test_tool_with_complex_schema or test_tool_without_schema or test_openai_completion_guided_choice or test_openai_embeddings_with_dimensions or test_openai_embeddings_with_encoding_format_base64 or test_openai_completion_logprobs or test_openai_completion_logprobs_streaming"

    # Dynamically determine the path to config.yaml from the original script directory
    STACK_CONFIG_PATH="$SCRIPT_DIR/../dist/config.yaml"
    if [ ! -f "$STACK_CONFIG_PATH" ]; then
        echo "Error: Could not find stack config at $STACK_CONFIG_PATH"
        exit 1
    fi

    uv venv --clear
    # shellcheck source=/dev/null
    source .venv/bin/activate
    uv pip install ogx-client ollama
    uv run pytest -s -v tests/integration/inference/ \
        --stack-config=server:"$STACK_CONFIG_PATH" \
        --text-model="$model" \
        --embedding-model="$EMBEDDING_MODEL" \
        -k "not ($SKIP_TESTS)"
}

function main() {
    echo "Starting ogx integration tests"
    echo "Configuration:"
    echo "  OGX_VERSION: $OGX_VERSION"
    echo "  OGX_REPO: $OGX_REPO"
    echo "  WORK_DIR: $WORK_DIR"
    echo "  VLLM_INFERENCE_MODEL: $VLLM_INFERENCE_MODEL"
    echo "  VERTEX_AI_INFERENCE_MODEL: $VERTEX_AI_INFERENCE_MODEL"
    echo "  OPENAI_INFERENCE_MODEL: $OPENAI_INFERENCE_MODEL"
    echo "  EMBEDDING_MODEL: $EMBEDDING_MODEL"
    echo "  VERTEX_AI_PROJECT: ${VERTEX_AI_PROJECT:-<not set>}"
    echo "  OPENAI_API_KEY: ${OPENAI_API_KEY:+<set>}"

    clone_ogx

    # Build list of models to test based on available configuration
    models_to_test=("$VLLM_INFERENCE_MODEL")

    # Only include Vertex AI models if credentials are available
    # (GCP auth step only runs on amd64, so credentials won't exist on arm64)
    if [ -n "${VERTEX_AI_PROJECT:-}" ] && [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ] && [ -f "$GOOGLE_APPLICATION_CREDENTIALS" ]; then
        echo "Vertex AI credentials available, including Vertex AI models in tests"
        models_to_test+=("$VERTEX_AI_INFERENCE_MODEL")
    else
        echo "Vertex AI credentials not available, skipping Vertex AI models"
    fi

    # Only include OpenAI models if OPENAI_API_KEY is set
    if [ -n "${OPENAI_API_KEY:-}" ]; then
        echo "OPENAI_API_KEY is set, including OpenAI models in tests"
        models_to_test+=("$OPENAI_INFERENCE_MODEL")
    else
        echo "OPENAI_API_KEY is not set, skipping OpenAI models"
    fi

    for model in "${models_to_test[@]}"; do
        run_integration_tests "$model"
    done
    echo "Integration tests completed successfully!"
}


main "$@"
exit 0
