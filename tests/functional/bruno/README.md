# Bruno collections

- **Environment:** `environments/ogx.bru` — set `base_url`, `model` (inference model name), `inference_provider`, `files_provider`, `vector_io_provider`.
- **Model:** All inference requests (chat completions, embeddings, etc.) must use the `model` variable so each inference provider (vLLM, Azure, Bedrock, etc.) is tested with the same model name. Set `INFERENCE_MODEL` when running via CLI or the provider-matrix script.
- **Provider-matrix runs:** Use `./local/scripts/run-tests-with-providers.sh` (or the container image) with `BASE_URL`, `INFERENCE_MODEL`, and optional `FILES_PROVIDER`, `INFERENCE_PROVIDER`, `VECTOR_IO_PROVIDER`. See `docs/providers-matrix.md` and `config/providers-matrix.yaml`.
- **Layout:** Put collections directly under `bruno/` (e.g. `files/`, `openresponses-acceptance/`). Version-specific state lives on **git branches**, not in version folders. The script runs `bruno/files` (isolated Files API) then all of `bruno/`.
