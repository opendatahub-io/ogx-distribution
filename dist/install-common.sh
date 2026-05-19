#!/bin/bash
set -euo pipefail

mkdir -p "${HOME}/.ogx" "${HOME}/.cache"

# Pre-cache tiktoken cl100k_base encoding to avoid runtime download
# from openaipublic.blob.core.windows.net (used by vector_store chunking)
export TIKTOKEN_CACHE_DIR="${HOME}/.cache/tiktoken"
python3 -c "import tiktoken; tiktoken.get_encoding('cl100k_base')"
