# Notebook Tests

Jupyter notebooks executed as pytest test cases via `nbconvert.ExecutePreprocessor`. Each notebook runs to completion — any unhandled exception or failed `assert` fails the test. Notebooks are auto-discovered: add a `test_*.ipynb` file and the runner picks it up.

## Running locally

### Via test runner (recommended)

```bash
cd tests/functional
./scripts/setup-server.sh --its              # full: start infra, run tests, cleanup
./scripts/setup-server.sh --its --tests-only # run tests against already-running server
```

### Pytest (standalone)

Export the required env vars, then run:

```bash
cd tests/functional
export BASE_URL="http://localhost:8321"
export INFERENCE_MODEL="vllm-inference/llama-3-2-3b"
uv run pytest tests/test_notebooks.py -v
# Run a single notebook:
#   uv run pytest tests/test_notebooks.py -v -k "test_basic_inference"
```

## Environment variables

Notebooks read env vars directly via `os.environ.get`. The test runner script (`run-tests-with-providers.sh`) exports them automatically.

| Variable | Required | Description |
|----------|----------|-------------|
| `BASE_URL` | yes | OGX server URL (default: `http://localhost:8321`) |
| `INFERENCE_MODEL` | yes | Inference model name |
| `EMBEDDING_MODEL` | no | Embedding model name (skipped if unset) |
| `EMBEDDING_DIMENSION` | no | Embedding vector dimension (default: `768`) |
| `INFERENCE_PROVIDER` | no | Inference provider label (skipped if unset) |
| `FILES_PROVIDER` | no | Files provider label (skipped if unset) |
| `VECTOR_IO_PROVIDER` | no | Vector IO provider label (skipped if unset) |

## Writing a new notebook

1. Copy an existing notebook:

   ```bash
   cp notebooks/test_basic_inference.ipynb notebooks/test_<feature>.ipynb
   ```

2. Read env vars and import helpers in the first code cell:

   ```python
   import os
   from ogx_client import OgxClient
   from scripts.helpers import response_text

   base_url = os.environ.get("BASE_URL", "http://localhost:8321")
   model = os.environ.get("INFERENCE_MODEL", "")
   assert model, "INFERENCE_MODEL must be set"
   ```

3. Follow this cell structure:
   - **Cell 1** — imports + env var reads + assertions on required vars
   - **Cell 2+** — test scenarios with `assert` statements
   - **Last cell** — cleanup (delete created resources)

4. Assert structure, not content — LLM output is non-deterministic. Check field existence, types, status codes.

5. Every notebook must have at least one `assert` — enforced by `test_notebooks.py`.

6. No registration needed — `tests/test_notebooks.py` auto-discovers all `*.ipynb` files in this directory.
