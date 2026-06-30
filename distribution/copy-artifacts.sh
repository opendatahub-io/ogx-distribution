#!/bin/bash
# Copy pre-fetched ML model artifacts into the correct cache directories.
# Artifacts must exist under ARTIFACTS_DIR (layout defined by artifacts.lock.yaml).
# In Konflux builds, Hermeto deposits them at /cachi2/output/deps/generic.
# In standard builds, fetch_artifacts.py downloads them first.
set -euo pipefail

ARTIFACTS_DIR="${1:-/cachi2/output/deps/generic}"
DOCLING_ARTIFACTS_PATH="${DOCLING_ARTIFACTS_PATH:-${APP_ROOT}/.cache/docling/models}"

copy_files() {
    local src_dir="$1" dest_dir="$2"
    shift 2
    for f in "$@"; do
        mkdir -p "${dest_dir}/$(dirname "$f")"
        cp "${src_dir}/${f}" "${dest_dir}/${f}"
    done
}

copy_tiktoken() {
    local cache_dir="${APP_ROOT}/.cache/tiktoken"
    mkdir -p "${cache_dir}"
    # Filename in the cache is the SHA-1 of the download URL
    cp "${ARTIFACTS_DIR}/tiktoken/cl100k_base.tiktoken" \
       "${cache_dir}/9b5ad71b2ce5302211f9c61530b329a4922fc6a4"
}

copy_granite_embedding() {
    # Recreate the HuggingFace hub cache layout so SentenceTransformer resolves it.
    local hf_cache="${HOME}/.cache/huggingface/hub"
    local model_dir="${hf_cache}/models--ibm-granite--granite-embedding-125m-english"
    local snapshot_dir="${model_dir}/snapshots/prefetched"
    mkdir -p "${snapshot_dir}/1_Pooling" "${model_dir}/refs"

    copy_files "${ARTIFACTS_DIR}/granite-embedding" "${snapshot_dir}" \
        config.json model.safetensors modules.json \
        sentence_bert_config.json special_tokens_map.json \
        tokenizer.json tokenizer_config.json \
        1_Pooling/config.json

    echo -n "prefetched" > "${model_dir}/refs/main"
}

copy_docling_heron() {
    copy_files "${ARTIFACTS_DIR}/docling-heron" \
        "${DOCLING_ARTIFACTS_PATH}/docling-project--docling-layout-heron" \
        config.json model.safetensors preprocessor_config.json
}

copy_docling_tableformer() {
    copy_files "${ARTIFACTS_DIR}/docling-models" \
        "${DOCLING_ARTIFACTS_PATH}/docling-project--docling-models" \
        model_artifacts/tableformer/accurate/tableformer_accurate.safetensors \
        model_artifacts/tableformer/accurate/tm_config.json
}

copy_docling_figclassifier() {
    copy_files "${ARTIFACTS_DIR}/docfigclassifier" \
        "${DOCLING_ARTIFACTS_PATH}/docling-project--DocumentFigureClassifier-v2.5" \
        config.json model.safetensors preprocessor_config.json
}

copy_rapidocr() {
    copy_files "${ARTIFACTS_DIR}/rapidocr" \
        "${DOCLING_ARTIFACTS_PATH}/RapidOcr" \
        onnx/PP-OCRv4/cls/ch_ppocr_mobile_v2.0_cls_mobile.onnx \
        onnx/PP-OCRv4/det/ch_PP-OCRv4_det_mobile.onnx \
        onnx/PP-OCRv4/det/en_PP-OCRv3_det_mobile.onnx \
        onnx/PP-OCRv4/rec/ch_PP-OCRv4_rec_mobile.onnx \
        onnx/PP-OCRv4/rec/en_PP-OCRv4_rec_mobile.onnx \
        paddle/PP-OCRv4/rec/ch_PP-OCRv4_rec_mobile/ppocr_keys_v1.txt \
        paddle/PP-OCRv4/rec/en_PP-OCRv4_rec_mobile/en_dict.txt \
        resources/fonts/FZYTK.TTF
}

copy_minilm_tokenizer() {
    copy_files "${ARTIFACTS_DIR}/minilm-tokenizer" \
        "${DOCLING_ARTIFACTS_PATH}/all-MiniLM-L6-v2" \
        tokenizer.json tokenizer_config.json
}

mkdir -p "${APP_ROOT}/.ogx" "${APP_ROOT}/.cache"

copy_tiktoken
copy_granite_embedding
copy_docling_heron
copy_docling_tableformer
copy_docling_figclassifier
copy_rapidocr
copy_minilm_tokenizer

chown -R 1001:0 "${DOCLING_ARTIFACTS_PATH}"
chmod -R g=u "${DOCLING_ARTIFACTS_PATH}"
