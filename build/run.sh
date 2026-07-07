#!/usr/bin/env bash
# Runs build.py inside a Linux container for consistent builds.

set -euo pipefail

IMAGE="quay.io/opendatahub/odh-midstream-python-base-3-12:latest"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Run as host user so the container can write to the mounted volume.
if command -v podman &>/dev/null; then
    runtime=podman
    user_flag="--userns=keep-id"
elif command -v docker &>/dev/null; then
    runtime=docker
    user_flag="--user=$(id -u):$(id -g)"
else
    echo "Error: podman or docker required" >&2
    exit 1
fi

exec "$runtime" run --rm \
    "$user_flag" \
    -v "$REPO_ROOT:/workspace:z" \
    -w /workspace \
    "$IMAGE" \
    uv run --with ruamel.yaml --with pydantic-settings build/build.py
