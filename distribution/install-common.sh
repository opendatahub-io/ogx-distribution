#!/bin/bash
set -euo pipefail

mkdir -p "${APP_ROOT}/.ogx" "${APP_ROOT}/.cache"

# Pre-cache tiktoken cl100k_base encoding to avoid runtime download
# from openaipublic.blob.core.windows.net (used by vector_store chunking)
export TIKTOKEN_CACHE_DIR="${APP_ROOT}/.cache/tiktoken"
python3 -c "import tiktoken; tiktoken.get_encoding('cl100k_base')"

# Pre-download the embedding model
HF_HUB_DOWNLOAD_TIMEOUT="90" \
  HF_HUB_ETAG_TIMEOUT="90" \
  hf download ibm-granite/granite-embedding-125m-english

# Docling transitively pulls in opencv-python, which requires libGL.so.1
# (absent in the UBI base image). Replace with the headless variant.
uv pip uninstall opencv-python 2>/dev/null || true
uv pip install --force-reinstall opencv-python-headless

# Pre-download Docling standard pipeline models for offline file processing.
echo "Downloading docling models..." && \
  HF_HUB_DOWNLOAD_TIMEOUT="90" \
  HF_HUB_ETAG_TIMEOUT="90" \
  docling-tools models download -o "${DOCLING_ARTIFACTS_PATH}" \
    layout tableformer rapidocr picture_classifier && \
  chown -R 1001:0 "${DOCLING_ARTIFACTS_PATH}" && \
  chmod -R g=u "${DOCLING_ARTIFACTS_PATH}"

# Pre-download HybridChunker tokenizer (not managed by docling-tools).
# Uses from_pretrained() + save_pretrained() instead of hf download because
# HybridChunker only needs the tokenizer files (~1.5 MB), not the full
# model repo with weights (~80 MB).
HF_HUB_DOWNLOAD_TIMEOUT="90" \
  HF_HUB_ETAG_TIMEOUT="90" \
  TOKENIZER_PATH="${DOCLING_ARTIFACTS_PATH}/all-MiniLM-L6-v2" \
  python3 -c "import os; from transformers import AutoTokenizer; t = AutoTokenizer.from_pretrained('sentence-transformers/all-MiniLM-L6-v2'); t.save_pretrained(os.environ['TOKENIZER_PATH']); print('all-MiniLM-L6-v2 tokenizer saved')" && \
  chown -R 1001:0 "${DOCLING_ARTIFACTS_PATH}/all-MiniLM-L6-v2" && \
  chmod -R g=u "${DOCLING_ARTIFACTS_PATH}/all-MiniLM-L6-v2"
