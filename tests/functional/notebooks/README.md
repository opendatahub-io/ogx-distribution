# Notebooks

Notebooks use the **same parameters** as Bruno: `base_url`, `model`, and optional provider labels. They are run **as tests** via pytest (see [Jupyter Notebooks as Test Cases](https://blog.iqmo.com/blog/python/jupyter_notebook_testing/)): each notebook is executed to completion; any unhandled exception or failed assertion fails the test.

## Test notebooks (split from `responses-api.ipynb`)

| Notebook | Purpose |
|----------|---------|
| **test_responses.ipynb** | Responses API: non-streaming + streaming; `responses.create`, iterate stream, assert status and content (e.g. Paris). |
| **test_rag.ipynb** | RAG: create vector store, upload doc, `responses.create` with `file_search`; assert answer. |
| **test_openapi.ipynb** | OpenAPI: OpenAI client pointed at OGX; `responses.create`; assert response. |

## Additional test notebooks

| Notebook | Purpose |
|----------|---------|
| **test_basic_inference.ipynb** | Temperature (0.0 deterministic vs 1.0); assert identical output for temp=0, non-empty for temp=1.0. |
| **test_streaming_responses.ipynb** | Streaming: iterate chunks, capture full message; assert chunk count and content (e.g. Paris). |
| **test_mcp_tooling.ipynb** | MCP tool-calling; agent calls tool and synthesizes result. Skips gracefully if MCP not available. |
| **test_negative.ipynb** | Invalid sampling (temp > 2.0) and non-existent MCP tool; assert API returns error. |

All use env: `BASE_URL` (default `http://localhost:8321`), `INFERENCE_MODEL` (required, no default). `test_mcp_tooling` uses optional `MCP_TOOL_GROUP`.

Notebooks that assert on response content use the shared **`response_text`** helper from **`scripts/helpers.py`** to extract text from Responses API objects (with an inline fallback if the script is not on `PYTHONPATH`). This keeps the QE pattern consistent: **QE Perspective** in the first markdown, **Setup** section with config and helper import, then implementation and assertions. No Langchain; minimal and readable. The original **responses-api.ipynb** is kept as a full demo and is **skipped** when running pytest (see `SKIP_NOTEBOOKS` in `tests/test_notebooks.py`).

## Reusing Bruno params in notebooks

When you run the test script (or the container image), it exports **env vars** (`BASE_URL`, `INFERENCE_MODEL`, etc.). Notebooks read them via **`config.notebook_env`** (which uses `os.environ.get` for all parameters).

### In your notebook (ipynb)

When run via the test script (or the container), the script sets `PYTHONPATH` to the repo root, so you can import directly. When run interactively, add the repo root to `sys.path` first (e.g. run from repo root, or add a cell that does the snippet below).

Add a cell at the top:

```python
# If not run via run-tests-with-providers.sh, add repo root to path (e.g. when running in Jupyter interactively)
import sys
from pathlib import Path
repo_root = Path.cwd()
while repo_root != repo_root.parent and not (repo_root / "config" / "notebook_env.py").exists():
    repo_root = repo_root.parent
if (repo_root / "config" / "notebook_env.py").exists():
    sys.path.insert(0, str(repo_root))

# Same params as Bruno (from env: BASE_URL, INFERENCE_MODEL, etc.)
from config.notebook_env import base_url, model, api_key, files_provider, inference_provider, vector_io_provider

# Use in requests
print(f"BASE_URL: {base_url}, INFERENCE_MODEL: {model}")
# e.g. requests.get(f"{base_url}/v1/...", ...)
```

**When run by the script:** The script exports `BASE_URL`, `INFERENCE_MODEL`, and provider vars, and sets `PYTHONPATH` to the repo root. `config.notebook_env` reads them with `os.environ.get`.

**When run interactively:** Set the same env vars (`BASE_URL`, `INFERENCE_MODEL`, etc.) before starting Jupyter so `config.notebook_env` can read them.

### Summary

All parameters come from **environment variables** (`BASE_URL`, `INFERENCE_MODEL`, `API_KEY`, `FILES_PROVIDER`, `INFERENCE_PROVIDER`, `VECTOR_IO_PROVIDER`). Bruno gets them via `--env-var`; notebooks get them via `config.notebook_env` (which uses `os.environ.get` for each).

## Running notebooks as tests

From the repo root (with `BASE_URL` and `INFERENCE_MODEL` set, and after `pip install -r requirements-test.txt`):

```bash
pytest tests/test_notebooks.py -v
```

Optional: use `pytest-xdist` for parallel runs: `pytest tests/test_notebooks.py -v -n auto`. To skip specific notebooks, add their filenames to `SKIP_NOTEBOOKS` in `tests/test_notebooks.py`.
