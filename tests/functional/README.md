# Functional Tests

Functional tests for OGX distribution — Bruno API contracts + Jupyter notebook integration tests. Runs against any OGX deployment (local podman, Konflux ITS, RHOAI cluster).

## Quick Start

```bash
# Start OGX + PostgreSQL + vLLM locally in a podman pod, run all tests, clean up
cd tests/functional
./scripts/setup-server.sh --its
```

Or point to an existing deployment:

```bash
cd tests/functional
uv sync && cd bruno && npm ci && cd ..
export BASE_URL="http://localhost:8321"
export INFERENCE_MODEL="vllm-inference/llama-3-2-3b"
./scripts/run-tests-with-providers.sh
```

Reports land in `reports/` as JUnit XML (`bruno-crud.xml`, `notebooks.xml`).

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/setup-server.sh` | Start/stop local infra (podman). Use `--its` for full pod, `--start-only` / `--tests-only` / `--cleanup` for individual steps |
| `scripts/run-tests-with-providers.sh` | Run Bruno CRUD + notebook tests against a running server. Requires `BASE_URL` and `INFERENCE_MODEL` |
| `scripts/sync-client-version.sh` | Auto-sync `ogx-client` pip package to match the server version |
| `scripts/bruno_summary.py` | Convert Bruno JSON output to JUnit XML |

## Environment Variables

When using `setup-server.sh`, all variables are auto-discovered from the running OGX instance.

| Variable | Required | Description |
|---|---|---|
| `BASE_URL` | yes | OGX server URL (default: `http://localhost:8321`) |
| `INFERENCE_MODEL` | yes | Inference model name (e.g. `vllm-inference/llama-3-2-3b`) |
| `EMBEDDING_MODEL` | no | Embedding model name (skipped if unset) |
| `EMBEDDING_DIMENSION` | no | Embedding vector dimension (default: `768`) |
| `FILES_PROVIDER` | no | Files provider (skipped if unset) |
| `INFERENCE_PROVIDER` | no | Inference provider (skipped if unset) |
| `VECTOR_IO_PROVIDER` | no | Vector IO provider (skipped if unset) |
| `HEALTH_CHECK_TIMEOUT` | no | Seconds to wait for server readiness (default: `0`) |

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
├── bruno/                        # Bruno API tests (see bruno/README.md)
│   ├── ogx-api/                  # API test collections (numbered folders)
│   └── environments/             # Shared env config
├── notebooks/                    # Jupyter notebooks executed as pytest tests
├── tests/
│   └── test_notebooks.py         # pytest runner — executes notebooks as tests
├── scripts/                      # Test orchestration and helpers
└── pyproject.toml
```

## Konflux ITS

The Tekton pipeline deploys OGX + PostgreSQL + vLLM as sidecars, clones this repo, and runs `run-tests-with-providers.sh`. No separate test image — tests run directly from source. See `odh-konflux-central/integration-tests/ogx-core/pr-its-pipeline.yaml`.

## Writing Tests

### Bruno (API contracts)

Copy an existing `.bru` file, edit the request and assertions. Tests are auto-discovered by the runner. See `bruno/README.md`.

### Notebooks (feature scenarios)

Create `notebooks/test_<feature>.ipynb`. Use `ogx-client` for API calls and `assert` for validation. Auto-discovered by `tests/test_notebooks.py` — no registration needed.
