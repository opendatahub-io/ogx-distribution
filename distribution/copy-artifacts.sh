#!/bin/bash
# Copy pre-fetched artifacts into the APP_ROOT cache tree.
#
# Artifact filenames in artifacts.lock.yaml are relative paths under APP_ROOT,
# so a recursive copy overlays them directly. In Konflux hermetic builds,
# Hermeto deposits them at /cachi2/output/deps/generic; in standard builds,
# fetch_artifacts.py downloads them first.
set -euo pipefail

ARTIFACTS_DIR="${1:-/cachi2/output/deps/generic}"

cp -r "${ARTIFACTS_DIR}/.cache" "${APP_ROOT}/.cache"

# HF hub cache requires a refs/main file to resolve the model by repo ID.
HF_GRANITE_DIR="${APP_ROOT}/.cache/huggingface/hub/models--ibm-granite--granite-embedding-125m-english"
mkdir -p "${HF_GRANITE_DIR}/refs"
echo -n "prefetched" > "${HF_GRANITE_DIR}/refs/main"
