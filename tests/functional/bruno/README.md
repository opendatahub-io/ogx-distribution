# Bruno API Tests

CRUD tests for OGX APIs. Each numbered folder under `ogx-api/` covers an API group. Tests are auto-discovered — add a `.bru` file and the runner picks it up.

## Running locally

### Via test runner (recommended)

The test runner script starts a full local environment (OGX + PostgreSQL + vLLM) and runs all tests:

```bash
cd tests/functional
./scripts/setup-server.sh --its              # full: start infra, run tests, cleanup
./scripts/setup-server.sh --its --start-only # start infra only, print connection info
./scripts/setup-server.sh --its --tests-only # run tests against already-running server
./scripts/setup-server.sh --its --cleanup    # stop and remove containers
```

### Bruno CLI (standalone)

```bash
cd tests/functional/bruno
npm ci
# Uses defaults from ogx-api/environments/ogx.bru
npx @usebruno/cli run ogx-api --env ogx
# Override specific vars as needed:
#   --env-var "baseUrl=http://my-server:8321" --env-var "model=my-model"
```

### Bruno App (GUI)

1. Install [Bruno](https://www.usebruno.com/downloads) or the [VS Code extension](https://marketplace.visualstudio.com/items?itemName=bruno-api-client.bruno)
2. Open collection: **File → Open Collection → `bruno/ogx-api/`**
3. Select environment: top-right dropdown → **ogx**
4. Edit environment variables (`base_url`, `model`, provider labels)
5. Run: right-click a folder → **Run**

## Environment setup

The environment file lives at `ogx-api/environments/ogx.bru`. Variables are placeholders — override them in the Bruno GUI or via `--env-var` on the CLI.

Do not add comments to `.bru` env files — Bruno's parser does not support them.

## Konflux ITS

In Konflux, the Tekton pipeline clones this repo and runs `scripts/run-tests-with-providers.sh` directly — Bruno is installed via `npm ci` in the test step. No separate test image needed.

## Writing tests

- Every `.bru` file **must** contain at least one assertion — either a `tests {}` block or a `script:post-response` block with `expect()` calls. Files without assertions are caught by `scripts/lint_bruno.py`.
- All env vars (`model`, `embedding_model`, `inference_provider`, `files_provider`, `vector_io_provider`) are **required**. Do not skip assertions with `if (!var) { return; }` — assert the var is set, then assert the value.
- Use `tests {}` for declarative assertions. Use `script:post-response` when you need to chain variables with `bru.setEnvVar()`.

## Provider overrides

Set `VECTOR_IO_PROVIDER`, `INFERENCE_PROVIDER`, `FILES_PROVIDER` to test different backends with the same CRUD tests.
