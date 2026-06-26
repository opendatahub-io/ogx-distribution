# Bruno API Tests

CRUD tests for OGX APIs — 26 requests, 54 assertions across 7 API groups.

## Quick start

### Bruno App (GUI)

1. Install [Bruno](https://www.usebruno.com/downloads) (MIT, [source](https://github.com/usebruno/bruno)) or the [VS Code / Cursor extension](https://marketplace.visualstudio.com/items?itemName=bruno-api-client.bruno)
2. Open collection: **File → Open Collection → `bruno/ogx-crud/`**
3. Select environment: top-right dropdown → **ogx**
4. Edit environment variables (click the gear icon next to the dropdown):
   - `base_url` — OGX server URL (default: `http://localhost:8321`)
   - `model` — inference model name (e.g. `vllm-inference/llama-3-2-3b`)
   - `vector_io_provider` — pgvector, milvus-remote, or qdrant-remote
   - `inference_provider` — vllm-inference, vertexai, openai, etc.
   - `files_provider` — meta-reference-files, s3
5. Run: right-click a folder → **Run** (or use the runner icon)

### Bruno CLI

```bash
cd tests/functional/bruno
npm ci
npx @usebruno/cli run ogx-crud \
  --env ogx \
  --env-var "baseUrl=http://localhost:8321" \
  --env-var "model=vllm-inference/llama-3-2-3b" \
  --env-var "vector_io_provider=pgvector" \
  --env-var "embedding_model=vllm-embedding/nomic-embed-text-v1-5" \
  --env-var "embedding_dimension=768"
```

### Via test runner script (recommended)

```bash
cd tests/functional
./scripts/setup-server.sh                    # start server + run all tests
./scripts/setup-server.sh --start-only       # start server only
./scripts/run-tests-with-providers.sh        # run tests against running server
```

The runner auto-discovers the model and providers from the running server.

## Environment setup

The environment file lives at `ogx-crud/environments/ogx.bru`. Variables are
placeholders — override them in the Bruno GUI or via `--env-var` on the CLI.

Do not add comments to `.bru` env files — Bruno's parser does not support them.

## API groups

| Folder | Endpoints |
|--------|-----------|
| 01-admin | GET /v1/version, /v1/health, /v1/providers, /v1/routes |
| 02-models | GET /v1/models, GET /v1/models/{id} |
| 03-inference | POST /v1/chat/completions, /v1/embeddings |
| 04-files | POST /v1/files, GET, DELETE |
| 05-vector-stores | POST /v1/vector_stores, attach file, search, GET, DELETE |
| 06-responses | POST /v1/responses, GET, DELETE |
| 07-file-processors | POST /v1alpha/file-processors/process, upload + process by ID |

## Provider matrix

See `config/providers-matrix.yaml` for supported provider combinations.
Set `VECTOR_IO_PROVIDER`, `INFERENCE_PROVIDER`, `FILES_PROVIDER` to test
different backends with the same CRUD tests.
