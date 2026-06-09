# Testing

This document describes the testing strategy for the Open Data Hub OGX Distribution.

## Test Scripts

All test scripts live in the `tests/` directory:

| File | Purpose |
|------|---------|
| `smoke.sh` | Smoke tests against a running OGX container |
| `run_integration_tests.sh` | Integration tests using upstream ogx's pytest suite |
| `messages_agent_sdk.py` | Basic Claude Agent SDK session against the Messages API |
| `test_utils.sh` | Shared utility functions (e.g., `validate_model_parameter`) |

### Smoke Tests (`smoke.sh`)

Smoke tests verify the container image works end-to-end. The script:

1. **Starts the OGX container** with environment variables for inference models, embedding models, and database configuration, then waits up to 60 seconds for the `/v1/health` endpoint to return `OK`.
2. **Model listing** - Verifies each configured model appears in the `/v1/models` response.
3. **OpenAI-compatible inference** - Sends a chat completion request to `/v1/chat/completions` and validates the response.
4. **Messages API** - Sends a single-turn request to the Anthropic-compatible `/v1/messages` endpoint and validates the response shape (a `message` from the `assistant` with a non-empty text block).
5. **PostgreSQL verification** - Checks that expected database tables (`ogx_kvstore`, `inference_store`) exist, then verifies that `inference_store` is populated with data after inference.

Setting `MESSAGES_SMOKE_ONLY=true` runs **only** the Messages API check against `MESSAGES_SMOKE_MODEL` and assumes the container is already running (it does not start one). This mode is used by the `messages-openai.yml` workflow.

Models tested depend on available credentials:

| Model | Environment Variable | Always Tested |
|-------|---------------------|---------------|
| vLLM inference model (`vllm-inference/Qwen/Qwen3-0.6B`) | `VLLM_INFERENCE_MODEL` | Yes |
| Embedding model (`vllm-embedding/ibm-granite/granite-embedding-125m-english`) | `EMBEDDING_MODEL` | Yes (list only) |
| Vertex AI model (`vertexai/publishers/google/models/gemini-2.5-flash`) | `VERTEX_AI_PROJECT` | Only if set |
| OpenAI model (`openai/gpt-5-nano`) | `OPENAI_API_KEY` | Only if set |

#### Running locally

```bash
# Required environment variables
export VLLM_INFERENCE_MODEL="vllm-inference/Qwen/Qwen3-0.6B"
export EMBEDDING_MODEL="vllm-embedding/ibm-granite/granite-embedding-125m-english"
export VLLM_URL="http://localhost:8000/v1"
export VLLM_EMBEDDING_URL="http://localhost:8001/v1"
export IMAGE_NAME="quay.io/opendatahub/odh-ogx-core"
export IMAGE_TAG="latest"  # In CI, this is set to the commit SHA or source-{sha} tag

# Optional (enables additional model tests)
export VERTEX_AI_PROJECT="<project>"
export VERTEX_AI_LOCATION="us-central1"
export OPENAI_API_KEY="<key>"

./tests/smoke.sh
```

### Integration Tests (`run_integration_tests.sh`)

Integration tests run the upstream [ogx pytest suite](https://github.com/ogx/ogx) against the distribution's running server. The script:

1. **Extracts the ogx version** from `build/build.env` to ensure tests match the bundled version.
2. **Clones the ogx repository** at the matching version tag into `/tmp/ogx-integration-tests`.
3. **Runs `pytest`** against `tests/integration/inference/` with required test dependencies installed, pointing at `distribution/config.yaml`.
   - `ogx-client` is required.
   - `ollama` is explicitly installed because the upstream test fixtures import it unconditionally (see [ogx-ai/ogx#5880](https://github.com/ogx-ai/ogx/issues/5880)).

Tests are run for each configured inference model (vLLM, and optionally Vertex AI and OpenAI).

Some upstream tests are currently skipped, grouped by reason:

**Non-streaming tests need `max_tokens` to prevent model from rambling:**
- `test_text_chat_completion_non_streaming`
- `test_openai_chat_completion_non_streaming`

**Tool-calling tests not yet supported by our model/provider configuration:**
- `test_text_chat_completion_tool_calling_tools_not_in_request`
- `test_text_chat_completion_structured_output`
- `test_openai_chat_completion_with_tool_choice_none`
- `test_openai_chat_completion_with_tools`
- `test_openai_format_preserves_complex_schemas`
- `test_multiple_tools_with_different_schemas`
- `test_tool_with_complex_schema`
- `test_tool_without_schema`

**Requires vLLM >= v0.12.0** ([ogx/ogx#4984](https://github.com/ogx/ogx/issues/4984)):
- `test_openai_completion_guided_choice`

**`granite-embedding-125m-english` was not trained with Matryoshka Representation Learning**, so vLLM correctly rejects `dimensions` requests with a 400 error:
- `test_openai_embeddings_with_dimensions`
- `test_openai_embeddings_with_encoding_format_base64`

**Upstream schema bug** — defines `logprobs` as `bool`, should be `int` ([ogx/ogx#5253](https://github.com/ogx/ogx/issues/5253)):
- `test_openai_completion_logprobs`
- `test_openai_completion_logprobs_streaming`

#### Running locally

Prerequisites:

- A running OGX container (started by `smoke.sh` or manually) with a running vLLM inference endpoint and vLLM embedding endpoint behind it
- Environment variables:
  - **Required**: `VLLM_INFERENCE_MODEL`, `EMBEDDING_MODEL`, `VLLM_URL`, `VLLM_EMBEDDING_URL`
  - **Optional**: `VERTEX_AI_PROJECT`, `VERTEX_AI_LOCATION`, and `OPENAI_API_KEY` (enables additional model coverage)
- `uv` and `git` available on the system

```bash
./tests/run_integration_tests.sh
```

### Claude Agent SDK Session (`messages_agent_sdk.py`)

Drives a basic 3-turn conversation through the [Claude Agent SDK](https://github.com/anthropics/claude-agent-sdk-python), which talks to the server's Anthropic-compatible Messages API (`/v1/messages`). This proves the shipped image can serve a real Agent SDK session, not just a single request. Each turn references the previous one, so a broken session (no conversational continuity) surfaces as a failure rather than a silent pass.

Configuration (environment variables):

| Variable | Purpose |
|----------|---------|
| `ANTHROPIC_BASE_URL` | OGX server base URL (default `http://127.0.0.1:8321`) |
| `ANTHROPIC_API_KEY` | Sent to OGX but not validated for local providers (default `fake`) |
| `MESSAGES_AGENT_MODEL` | OGX model id passed through as the Anthropic `model` (e.g. `openai/gpt-4.1-nano`) |

#### Running locally

Prerequisites: Python 3.10+, Node.js, the Claude Code CLI, and the Agent SDK.

```bash
npm install -g @anthropic-ai/claude-code
uv venv && source .venv/bin/activate
uv pip install claude-agent-sdk anyio

export ANTHROPIC_BASE_URL="http://127.0.0.1:8321"
export ANTHROPIC_API_KEY="fake"
export MESSAGES_AGENT_MODEL="openai/gpt-4.1-nano"
python tests/messages_agent_sdk.py
```

## CI/CD Pipelines

Testing is automated via GitHub Actions workflows in `.github/workflows/`.

### Container Build, Test & Publish (`redhat-distro-container.yml`)

The main CI pipeline that builds, tests, and publishes the container image. It runs on:

- **Pull requests** to `main`, `rhoai-v*`, and `konflux-poc*` branches (when `distribution/`, `Containerfile`, `tests/`, or workflow files change)
- **Pushes** to `main` and `rhoai-v*` branches
- **Manual dispatch** (`workflow_dispatch`) to build from an arbitrary ogx commit. Intentionally skips all tests to allow building images for specific SHAs even when CI is failing on other commits
- **Nightly schedule** (6 AM UTC) to test the `main` branch of ogx

Pipeline steps:

1. **Build** the container image for AMD64 and ARM64. When MaaS (Model-as-a-Service) vLLM endpoints are configured, both architectures run the full test suite (smoke and integration tests) against remote inference endpoints. Without MaaS, ARM64 runs smoke tests using local vLLM containers but skips integration tests.
2. **Start vLLM inference** via the `setup-vllm` action using the pre-built `quay.io/opendatahub/vllm-cpu` image (CPU-based `Qwen3-0.6B` model)
3. **Start vLLM embedding** via the `setup-vllm` action using the same pre-built image (CPU-based `granite-embedding-125m-english` model)
4. **Start PostgreSQL** via the `setup-postgres` action
5. **Run smoke tests** (`tests/smoke.sh`)
6. **Run integration tests** (`tests/run_integration_tests.sh`)
7. **Publish** multi-arch image to `quay.io/opendatahub/odh-ogx-core` (on push to `main` or `rhoai-v*` branches when `distribution/` or `Containerfile` changed, or on manual dispatch)
8. **Notify Slack** on failure or successful publish

Logs from all containers (ogx, vLLM, PostgreSQL) and system info are uploaded as artifacts with 7-day retention.

> [!NOTE]
> The basic Messages API check (`/v1/messages`) runs as part of `smoke.sh`, so it is exercised on every PR via this pipeline against the locally-built vLLM model.

### Messages API + Claude Agent SDK (`messages-openai.yml`, `messages-vllm-maas.yml`)

Per-provider workflows that mirror their `responses-*.yml` counterparts. Each pulls the published image, boots it with the Messages API enabled and the provider's credentials set, then runs two distinct paths as separate steps so a failure clearly identifies which one broke:

1. **Messages API basic** - `smoke.sh` in `MESSAGES_SMOKE_ONLY` mode sends a single-turn `/v1/messages` request and asserts the response shape.
2. **Claude Agent SDK session** - `messages_agent_sdk.py` runs a 3-turn Agent SDK conversation against `/v1/messages`.

| Workflow | Provider | Path exercised |
|----------|----------|----------------|
| `messages-openai.yml` | OpenAI (`OPENAI_API_KEY`) | Anthropic ⇄ OpenAI translation |
| `messages-vllm-maas.yml` | vLLM MaaS (`MAAS_VLLM_URL` / `MAAS_VLLM_API_TOKEN`) | Native `/v1/messages` passthrough |

The model under test is resolved as `inputs.models` → `vars.TEST_MODELS_<PROVIDER>` (a repo Actions variable) → a hardcoded fallback, matching the `responses-*.yml` workflows. On `messages-vllm-maas.yml` the configured MaaS model can be small (e.g. `Qwen3-0.6B`), so the **Agent SDK session step is non-blocking** there (`continue-on-error`) — it still reports signal but won't fail the workflow on a small-model flake. The basic request step is blocking on both workflows.

Each is `workflow_call` + `workflow_dispatch`, and skips automatically when its credentials are not configured (e.g. fork PRs).

### Messages Weekly (`messages-weekly.yml`)

A dedicated weekly orchestrator (Sundays 23:00 UTC) that runs the per-provider messages workflows above. Kept separate from `responses-weekly.yml` because these are different APIs with different harnesses; the messages tests do not emit JUnit, so there is no shared report job to combine. Supports `workflow_dispatch` with per-provider toggles.

### Pre-commit (`pre-commit.yml`)

Runs on all pull requests and pushes to `main`. Executes the full pre-commit hook suite and verifies no files were changed or created:

- **Ruff** - Python linting and formatting
- **Shellcheck** - Shell script linting
- **Actionlint** - GitHub Actions workflow linting
- **Standard hooks** - merge conflict detection, trailing whitespace, large file checks, YAML/JSON/TOML validation, executable shebangs, private key detection, mixed line endings
- **Distribution Build** (`build/build.py`) - Regenerates `distribution/config.yaml` and `distribution/requirements.txt`
- **Distribution Documentation** (`build/gen_distro_docs.py`) - Regenerates `distribution/README.md`

### Semantic PR Titles (`semantic-pr.yml`)

Validates that pull request titles follow [Conventional Commits](https://www.conventionalcommits.org/) format (e.g., `feat:`, `fix:`, `docs:`).

### Update OGX Version (`update-ogx-version.yml`)

Triggered via `repository_dispatch` (type: `update-ogx-version`) from the opendatahub-io/ogx midstream repo when a new release is tagged. The workflow:

1. **Validates** the tag format (`vX.Y.Z[.W]+rhaiv.N`) and runs preflight checks (version not already set, branch doesn't exist)
2. **Updates** `CURRENT_OGX_VERSION` in `build/build.py`
3. **Runs pre-commit** to regenerate distribution artifacts (Containerfile, README)
4. **Opens a pull request** against `main` with the version bump
5. **Notifies Slack** with the PR link for review

### vLLM CPU Container (`vllm-cpu-container.yml`)

Builds, tests, and publishes pre-built vLLM CPU container images to `quay.io/opendatahub/vllm-cpu`. These images bundle inference and embedding models so the main CI pipeline doesn't need to download them each run. It runs on:

- **Pull requests** to `main`/`rhoai-v*`/`konflux-poc*` branches and **pushes** to `main`/`rhoai-v*` branches (when `vllm/Containerfile` or actions change)
- **Manual dispatch** with optional custom inference/embedding model parameters

### Test PR in Showroom (`test-pr-in-showroom.yml`)

Manually triggered workflow that builds and tests a PR's container image in an OpenShift showroom environment. Takes a PR number as input and optionally custom OLM catalog and operator images. Builds the image from the PR code, pushes it to an OpenShift internal registry, and runs the full showroom setup/test/cleanup cycle.

### Stale Bot (`stale_bot.yml`)

Automatically marks issues and PRs as stale after 60 days of inactivity and closes them after 30 more days. Runs daily at midnight UTC.
