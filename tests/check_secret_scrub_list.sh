#!/bin/bash
# Ensure every secret-looking env var passed to the OGX container in smoke.sh
# is listed in the CI workflow's log-scrub step. Exits non-zero on drift.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SMOKE="$REPO_ROOT/tests/smoke.sh"
WORKFLOW="$REPO_ROOT/.github/workflows/redhat-distro-container.yml"

# Extract env var names passed via --env to the docker container in smoke.sh
smoke_vars=$(grep -oP '(?<=--env ")([A-Z_]+)(?==)' "$SMOKE" | sort -u)

# Filter to secret-looking names
secret_pattern='KEY|TOKEN|PASSWORD|SECRET|CREDENTIAL'
smoke_secrets=$(echo "$smoke_vars" | grep -E "$secret_pattern" || true)

if [ -z "$smoke_secrets" ]; then
  echo "No secret-looking env vars found in smoke.sh (unexpected)"
  exit 1
fi

# Extract the var names from the workflow's scrub list
scrub_vars=$(grep -oP "'[A-Z_]+'" "$WORKFLOW" \
  | tr -d "'" \
  | grep -E "$secret_pattern" \
  | sort -u)

missing=()
while IFS= read -r var; do
  if ! echo "$scrub_vars" | grep -qx "$var"; then
    missing+=("$var")
  fi
done <<< "$smoke_secrets"

if [ ${#missing[@]} -gt 0 ]; then
  echo "ERROR: Secret env var(s) passed to the OGX container in smoke.sh"
  echo "are missing from the CI log-scrub list in redhat-distro-container.yml:"
  for v in "${missing[@]}"; do
    echo "  - $v"
  done
  echo ""
  echo "Add them to the Python scrub snippet in the 'Gather logs' step."
  exit 1
fi

echo "All secret env vars in smoke.sh are in the CI log-scrub list."
