# vLLM CPU Container Images

[![Build](https://github.com/opendatahub-io/ogx-distribution/actions/workflows/vllm-cpu-container.yml/badge.svg?branch=main)](https://github.com/opendatahub-io/ogx-distribution/actions/workflows/vllm-cpu-container.yml)

This directory contains a Containerfile based on the official [vllm/vllm-openai-cpu](https://hub.docker.com/r/vllm/vllm-openai-cpu) image with pre-downloaded HuggingFace models baked in at build time.

## Build Arguments

| Argument | Default | Description |
|---|---|---|
| `INFERENCE_MODEL` | *(required)* | HuggingFace model ID for inference |
| `EMBEDDING_MODEL` | *(required)* | HuggingFace model ID for embeddings |

## Building

```bash
docker build . \
    --build-arg INFERENCE_MODEL="Qwen/Qwen3-0.6B" \
    --build-arg EMBEDDING_MODEL="ibm-granite/granite-embedding-125m-english" \
    --tag vllm-cpu:Qwen3-0.6B-granite-embedding-125m-english \
    --file vllm/Containerfile
```

### Gated Models

For models that require authentication (e.g., gated models), provide your HuggingFace token using Docker build secrets:

```bash
export HF_TOKEN="your_huggingface_token_here"
docker build . \
    --build-arg INFERENCE_MODEL="Qwen/Qwen3-0.6B" \
    --build-arg EMBEDDING_MODEL="ibm-granite/granite-embedding-125m-english" \
    --secret id=hf_token,env=HF_TOKEN \
    --tag vllm-cpu:Qwen3-0.6B-granite-embedding-125m-english \
    --file vllm/Containerfile
```

> [!TIP]
> Using Docker build secrets is more secure than build arguments because secrets are not persisted in the image layers or visible in the build history.

## Running

The entrypoint is `vllm serve`, so pass model and serving arguments directly. The container can only serve one model at a time.

### Inference model

```bash
docker run -d \
    --name vllm-inference \
    --privileged=true \
    --net=host \
    vllm-cpu:Qwen3-0.6B-granite-embedding-125m-english \
    --host 0.0.0.0 \
    --port 8000 \
    --enable-auto-tool-choice \
    --tool-call-parser hermes \
    --model /root/.cache/Qwen/Qwen3-0.6B \
    --served-model-name Qwen/Qwen3-0.6B \
    --max-model-len 8192
```

### Embedding model

```bash
docker run -d \
    --name vllm-embedding \
    --privileged=true \
    --net=host \
    vllm-cpu:Qwen3-0.6B-granite-embedding-125m-english \
    --host 0.0.0.0 \
    --port 8001 \
    --model /root/.cache/ibm-granite/granite-embedding-125m-english \
    --served-model-name ibm-granite/granite-embedding-125m-english
```

> [!TIP]
> Additional vLLM arguments can be passed directly. Models are stored under `/root/.cache/<model_id>`.
