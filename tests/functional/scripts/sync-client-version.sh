#!/usr/bin/env bash
# shellcheck disable=SC2317
# Ensure the installed ogx-client matches the target server.
#
# Version source (in priority order):
#   1. Running server at BASE_URL/v1/version
#   2. build/build.env OGX_VERSION (same-repo fallback, no server needed)
#
# Requires: python3, uv. BASE_URL optional if build.env is available.

set -euo pipefail

if [[ "${SKIP_CLIENT_SYNC:-0}" == "1" ]]; then
  echo "Client version sync skipped (SKIP_CLIENT_SYNC=1)"
  return 0 2>/dev/null || exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_ROOT="$(cd "${REPO_ROOT}/../.." && pwd)"
PYPROJECT="${REPO_ROOT}/pyproject.toml"
BUILD_ENV="${DIST_ROOT}/build/build.env"

_server_version=""
if [[ -n "${BASE_URL:-}" ]]; then
  _server_version=$(curl -sf "${BASE_URL}/v1/version" | python3 -c "import json,sys; print(json.load(sys.stdin)['version'])" 2>/dev/null || true)
fi

if [[ -z "$_server_version" && -f "$BUILD_ENV" ]]; then
  _server_version=$(grep -oP '^OGX_VERSION=\K.*' "$BUILD_ENV" | sed 's/^v//' || true)
  if [[ -n "$_server_version" ]]; then
    echo "Using OGX version from build/build.env: ${_server_version}"
  fi
fi

if [[ -z "$_server_version" ]]; then
  echo "Warning: could not determine OGX version (no server at ${BASE_URL:-<unset>}, no build/build.env) — skipping client sync" >&2
  return 0 2>/dev/null || exit 0
fi

# Strip build metadata (e.g. 0.7.1+rhaiv.1 → 0.7.1)
_server_base="${_server_version%%+*}"
_server_major_minor="${_server_base%.*}"

_client_version=$(uv run --project "${REPO_ROOT}" python3 -c "import ogx_client; print(ogx_client.__version__)" 2>/dev/null || echo "0.0.0")
_client_major_minor="${_client_version%.*}"

if [[ "$_client_major_minor" == "$_server_major_minor" ]]; then
  echo "Client ${_client_version} matches server ${_server_version} (both ${_server_major_minor}.x)"
  return 0 2>/dev/null || exit 0
fi

if ! [[ "$_server_major_minor" =~ ^[0-9]+\.[0-9]+$ ]]; then
  echo "Error: unexpected server version format: ${_server_version}" >&2
  return 1 2>/dev/null || exit 1
fi

echo "Version mismatch: client=${_client_version}, server=${_server_version}"
echo "Updating pyproject.toml to require ogx-client~=${_server_major_minor}.0 ..."

# Update the version constraint in pyproject.toml
sed -i "s|\"ogx-client[^\"]*\"|\"ogx-client~=${_server_major_minor}.0\"|" "${PYPROJECT}"

# Re-sync the venv (updates uv.lock and installs the right version)
(cd "${REPO_ROOT}" && uv sync --quiet)

_new_version=$(uv run --project "${REPO_ROOT}" python3 -c "import ogx_client; print(ogx_client.__version__)" 2>/dev/null)
echo "Upgraded ogx-client: ${_client_version} -> ${_new_version}"
