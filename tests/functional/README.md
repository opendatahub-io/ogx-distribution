# Functional Tests

Functional tests for OGX distribution — Bruno API contracts + Jupyter notebook integration tests. Runs against any OGX deployment (local podman, GH Actions CI, Konflux ITS, RHOAI cluster).

## Quick Start

```bash
# 1. Start OGX + PostgreSQL locally (or point to an existing deployment)
export BASE_URL="http://localhost:8321"
export MODEL="vllm-inference/llama-3-2-3b"

# 2. Install deps
cd tests/functional
uv sync
cd bruno && npm ci && cd ..

# 3. Run
./scripts/run-tests-with-providers.sh
```

Reports land in `reports/` as JUnit XML (Bruno: `bruno-crud.xml`, notebooks: `notebooks.xml`).

## Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `BASE_URL` | **Yes** | — | OGX server URL (e.g. `http://localhost:8321`) |
| `MODEL` | **Yes** | — | Inference model name (e.g. `vllm-inference/llama-3-2-3b`, `openai/gpt-4.1-nano`) |
| `EMBEDDING_MODEL` | No | `""` | Embedding model name |
| `EMBEDDING_DIMENSION` | No | `768` | Embedding vector dimension |
| `FILES_PROVIDER` | No | `""` | Override files provider (e.g. `remote::s3`) |
| `INFERENCE_PROVIDER` | No | `""` | Override inference provider (e.g. `remote::azure`) |
| `VECTOR_IO_PROVIDER` | No | `""` | Override vector IO provider (e.g. `remote::pgvector`) |
| `HEALTH_CHECK_TIMEOUT` | No | `0` | Seconds to wait for server readiness (0 = skip, set to 600 in CI) |

Provider routing (which inference/vector/files backend to use) is configured **server-side** in the OGX config. These env vars are used for test selection and reporting, not provider routing.

## Test Layers

This directory is one of three test layers in `tests/`:

| Layer | Location | What it tests | Framework |
|---|---|---|---|
| Smoke | `tests/smoke.sh` | Health, models, basic inference, DB tables | Bash + curl |
| Integration | `tests/run_integration_tests.sh` | Upstream OGX pytest suite | pytest (cloned from upstream) |
| **Functional** | **`tests/functional/`** | API contracts, feature scenarios, provider coverage | Bruno + Jupyter + pytest |

## Structure

```
functional/
├── bruno/
│   ├── ogx-crud/               # Hand-written CRUD tests with assertions
│   │   ├── 01-admin/           #   health, version, providers
│   │   ├── 02-models/          #   list, get
│   │   ├── 03-inference/       #   chat completions
│   │   ├── 04-files/           #   CRUD
│   │   ├── 05-vector-stores/   #   CRUD
│   │   └── 06-responses/       #   create, list, get
│   ├── environments/           # Shared env config
│   ├── spec/                   # OpenAPI specifications
│   └── package.json            # @usebruno/cli
├── notebooks/
│   ├── test_basic_inference.ipynb
│   ├── test_file_processors.ipynb
│   ├── test_mcp_tooling.ipynb
│   ├── test_negative.ipynb
│   ├── test_openai_rag.ipynb
│   ├── test_openapi.ipynb
│   ├── test_rag.ipynb
│   ├── test_responses.ipynb
│   └── test_streaming_responses.ipynb
├── tests/
│   ├── test_notebooks.py       # pytest runner — executes notebooks as tests
│   └── unit/
├── scripts/
│   ├── run-tests-with-providers.sh   # Main test orchestrator
│   ├── setup-server.sh               # Local podman setup
│   ├── sync-client-version.sh        # Auto-sync ogx-client to server version
│   ├── bruno_summary.py              # Bruno JSON → JUnit XML converter
│   └── helpers.py                    # Shared notebook utilities
├── config/
│   ├── providers-matrix.yaml         # Available provider combinations
│   └── notebook_env.py               # Env var exports for notebooks
├── pyproject.toml
├── uv.lock
├── Containerfile
└── .env.example
```

## Running Tests

### Phase 1: Bruno CRUD Tests

Tests HTTP API contracts — create, list, get, delete across all API groups. Uses variable chaining (e.g. create a file → use its ID in subsequent requests).

```bash
cd bruno/ogx-crud
bru run . --env-var "baseUrl=$BASE_URL" --env-var "model=$MODEL"
```

### Phase 2: Notebook Tests

Jupyter notebooks executed as pytest test cases via `nbconvert.ExecutePreprocessor`. Each notebook contains assertions on response structure (not content — LLM output is non-deterministic).

```bash
export BASE_URL MODEL
uv run pytest tests/test_notebooks.py -v
```

### Both Phases (CI)

```bash
./scripts/run-tests-with-providers.sh
```

## CI Integration

### GitHub Actions

Functional tests reuse the existing distro CI actions (`setup-postgres`, `setup-server`, `setup-vllm`). A per-provider workflow swaps only the test execution step:

```yaml
- uses: ./.github/actions/setup-postgres
- uses: ./.github/actions/setup-server
  with:
    image_name: quay.io/opendatahub/odh-ogx-core
    image_tag: ${{ env.IMAGE_TAG }}
    extra_env: |
      OPENAI_API_KEY=${{ secrets.OPENAI_API_KEY }}
      EMBEDDING_MODEL=openai/text-embedding-3-small

- name: Install functional test deps
  run: |
    cd tests/functional && uv sync
    cd tests/functional/bruno && npm ci

- name: Run functional tests
  env:
    BASE_URL: http://127.0.0.1:8321
    MODEL: ${{ matrix.model }}
  run: tests/functional/scripts/run-tests-with-providers.sh
```

### Konflux ITS

The `Containerfile` builds a self-contained test runner image. Konflux ITS deploys OGX as a sidecar and runs the test container against it. See `.tekton/odh-ogx-core-its.yaml`.

### JUnit XML Output

Both test phases produce JUnit XML in `reports/`:
- `reports/bruno-crud.xml` — Bruno CRUD results
- `reports/notebooks.xml` — Notebook pytest results

Compatible with `dorny/test-reporter` (GH Actions), Tekton results (Konflux), and ReportPortal.

## Dev Onboarding — Writing Your First Test

You own a Strat feature? You own its tests. Here's how to add them in 15 minutes.

### 1. Get a running OGX server

**Option A — ITS mode (recommended, no external deps):**

```bash
cd tests/functional
./scripts/setup-server.sh --its --start-only
# Starts postgres + vLLM + OGX in a podman pod (~3 min)
# Prints BASE_URL, MODEL, EMBEDDING_MODEL when ready
```

**Option B — Point to existing deployment:**

```bash
export BASE_URL="http://localhost:8321"
export MODEL="vllm-inference/Qwen/Qwen3-0.6B"
```

### 2. Install deps (one time)

```bash
cd tests/functional
uv sync
cd bruno && npm ci && cd ..
```

### 3. Pick your test type

| When to use | Type | Time to write |
|---|---|---|
| Testing API contracts (CRUD, status codes, field validation) | **Bruno** | 5 min |
| Testing feature scenarios (RAG, multi-turn, tool use) | **Notebook** | 10 min |

### 4a. Write a Bruno test

Copy an existing `.bru` file, edit the request body and assertions:

```bash
# Example: adding a "Delete Response" test
cp bruno/ogx-crud/06-responses/Get\ Response.bru \
   bruno/ogx-crud/06-responses/Delete\ Response.bru
# Edit: change method to DELETE, update assertions
```

Key patterns:
- Save IDs with `bru.setEnvVar("response_id", res.getBody().id)` in Create
- Reference them with `{{response_id}}` in Get/Delete
- Assertions go in `script:post-response` blocks

### 4b. Write a notebook test

```bash
cp notebooks/test_responses.ipynb notebooks/test_<your_feature>.ipynb
```

Key patterns:
- Cell 1: imports + config from env vars (`os.environ.get("MODEL")`)
- Cell 2: setup (create client, check prerequisites)
- Cell 3+: test scenarios with `assert` statements
- Last cell: cleanup (delete resources)
- Auto-discovered by pytest — no registration needed

### 5. Run and verify

```bash
# Run everything
./scripts/setup-server.sh --its --tests-only

# Or run just your notebook
uv run pytest tests/test_notebooks.py -v -k "test_your_feature"

# Or run just Bruno
cd bruno/ogx-crud && bru run 06-responses/ \
  --env-var "baseUrl=http://localhost:8321" \
  --env-var "model=vllm-inference/Qwen/Qwen3-0.6B"
```

### 6. Cleanup

```bash
./scripts/setup-server.sh --its --cleanup
```

### Tips

- **Assert structure, not content** — LLM output is non-deterministic. Check field existence, types, status codes.
- **Use `ogx-client`** in notebooks, not raw `requests`. It matches the server version automatically.
- **Provider vars are auto-discovered** — don't hardcode `provider_id` values. Use the discovery pattern from existing notebooks.
- **Look at existing tests** — `test_responses.ipynb` and `test_rag.ipynb` are good templates for new feature tests.

## Contributing Tests

### Adding a Bruno CRUD test group

1. Create a new numbered folder in `bruno/ogx-crud/` (e.g. `07-agents/`)
2. Add `.bru` files following the CRUD pattern: Create → List → Get → Delete
3. Use variable chaining: `bru.setEnvVar("var_id", res.body.id)` to pass IDs between requests
4. Add assertions in `script:post-response` blocks

### Adding a notebook test

1. Create `notebooks/test_<feature>.ipynb`
2. Import config: `from config.notebook_env import base_url, model`
3. Use `ogx-client` for OGX calls, `openai` SDK for OpenAI-compatible endpoints
4. Add `assert` statements on response structure (field existence, types, array lengths)
5. The notebook is auto-discovered by `tests/test_notebooks.py`

## Provider Matrix

See `config/providers-matrix.yaml` for the full list. Current coverage:

| Provider type | Providers |
|---|---|
| Files | `inline::localfs`, `remote::s3` |
| Inference | `remote::vllm`, `remote::openai`, `remote::vertexai`, `remote::bedrock`, `remote::azure`, `remote::watsonx` |
| Vector IO | `inline::milvus`, `inline::faiss`, `remote::pgvector`, `remote::qdrant`, `remote::milvus` |
