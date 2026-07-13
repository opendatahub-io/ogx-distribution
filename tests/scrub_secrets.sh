#!/bin/bash
# Scrub secret values from files before artifact upload (CWE-532).
#
# Usage: scrub_secrets.sh <glob> <ENV_VAR_NAME> [ENV_VAR_NAME ...]
#
# Each ENV_VAR_NAME is read from the environment.  Values shorter than
# 4 characters are silently skipped to avoid false-positive replacements.
#
# Example:
#   scrub_secrets.sh 'logs/*.log' VLLM_API_TOKEN OPENAI_API_KEY

set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: $0 <glob> <ENV_VAR_NAME> [ENV_VAR_NAME ...]" >&2
  exit 1
fi

glob_pattern="$1"
shift

python3 -c "
import os, glob, sys

var_names = sys.argv[1:]
secrets = [os.environ.get(v, '') for v in var_names]
secrets = [s for s in secrets if len(s) >= 4]

for f in glob.glob(sys.argv[0]):
    try:
        with open(f, 'r', errors='replace') as fh:
            content = fh.read()
        for s in secrets:
            content = content.replace(s, '***REDACTED***')
        with open(f, 'w') as fh:
            fh.write(content)
    except IsADirectoryError:
        pass
" "$glob_pattern" "$@"
