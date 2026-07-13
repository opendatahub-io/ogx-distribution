#!/usr/bin/env bash
# Runs build.py inside a Linux container for consistent builds.

set -euo pipefail

IMAGE="quay.io/opendatahub/odh-midstream-python-base-3-12:latest"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Run as host user so the container can write to the mounted volume.
if command -v podman &>/dev/null; then
    runtime=podman
    user_flags=(--userns=keep-id --user="$(id -u):$(id -g)")
elif command -v docker &>/dev/null; then
    runtime=docker
    user_flags=(--user="$(id -u):$(id -g)")
else
    echo "Error: podman or docker required" >&2
    exit 1
fi

# Forward any build.env variables that are set as env vars in the host environment.
env_flags=()
while IFS='=' read -r key _ || [[ -n "$key" ]]; do
    if [[ -n "$key" && ! "$key" =~ ^# && -n "${!key:-}" ]]; then
        env_flags+=(-e "$key")
    fi
done < "$REPO_ROOT/build/build.env"

exec "$runtime" run --rm \
    "${user_flags[@]}" \
    "${env_flags[@]}" \
    -v "$REPO_ROOT:/workspace:z" \
    -w /workspace \
    "$IMAGE" \
    uv run --with ruamel.yaml --with pydantic-settings --with pyyaml build/build.py
