#!/bin/bash
# Tests for _FILE secret resolution in entrypoint.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRYPOINT="$SCRIPT_DIR/../distribution/entrypoint.sh"
FAILURES=0

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

setup_tmpdir() {
  TMPDIR_TEST="$(mktemp -d)"
}

teardown_tmpdir() {
  rm -rf "$TMPDIR_TEST"
}

# Source just the resolve_file_secret function from entrypoint.sh.
# We extract the function and the for-loop so we can test them in isolation
# without exec-ing ogx.
source_resolve_function() {
  eval "$(sed -n '/^resolve_file_secret()/,/^}$/p' "$ENTRYPOINT")"
}

echo "=== _FILE secret resolution tests ==="

# Test 1: _FILE populates the base variable
echo "--- Test: _FILE env var populates base variable ---"
(
  setup_tmpdir
  source_resolve_function
  echo -n "s3cret-key" > "$TMPDIR_TEST/api_key"
  unset OPENAI_API_KEY 2>/dev/null || true
  export OPENAI_API_KEY_FILE="$TMPDIR_TEST/api_key"
  resolve_file_secret OPENAI_API_KEY
  if [ "$OPENAI_API_KEY" = "s3cret-key" ]; then
    pass "base variable populated from file"
  else
    fail "expected 's3cret-key', got '$OPENAI_API_KEY'"
  fi
  teardown_tmpdir
) || fail "subshell exited with error"

# Test 2: _FILE variable is unset after resolution
echo "--- Test: _FILE variable is unset after resolution ---"
(
  setup_tmpdir
  source_resolve_function
  echo -n "tok" > "$TMPDIR_TEST/token"
  unset VLLM_API_TOKEN 2>/dev/null || true
  export VLLM_API_TOKEN_FILE="$TMPDIR_TEST/token"
  resolve_file_secret VLLM_API_TOKEN
  if [ -z "${VLLM_API_TOKEN_FILE:-}" ]; then
    pass "_FILE variable unset"
  else
    fail "_FILE variable still set: '$VLLM_API_TOKEN_FILE'"
  fi
  teardown_tmpdir
) || fail "subshell exited with error"

# Test 3: base variable preserved when no _FILE is set
echo "--- Test: base variable unchanged when _FILE is absent ---"
(
  source_resolve_function
  export POSTGRES_PASSWORD="inline-pass"
  unset POSTGRES_PASSWORD_FILE 2>/dev/null || true
  resolve_file_secret POSTGRES_PASSWORD
  if [ "$POSTGRES_PASSWORD" = "inline-pass" ]; then
    pass "base variable unchanged"
  else
    fail "expected 'inline-pass', got '$POSTGRES_PASSWORD'"
  fi
) || fail "subshell exited with error"

# Test 4: error when both base and _FILE are set
echo "--- Test: mutual exclusion error ---"
(
  setup_tmpdir
  source_resolve_function
  echo -n "file-val" > "$TMPDIR_TEST/key"
  export AZURE_API_KEY="env-val"
  export AZURE_API_KEY_FILE="$TMPDIR_TEST/key"
  if output=$(resolve_file_secret AZURE_API_KEY 2>&1); then
    fail "should have exited with error"
  else
    if echo "$output" | grep -q "mutually exclusive"; then
      pass "mutual exclusion detected"
    else
      fail "unexpected error: $output"
    fi
  fi
  teardown_tmpdir
) || pass "mutual exclusion detected (exit)"

# Test 5: error when _FILE references a missing file
echo "--- Test: missing file error ---"
(
  source_resolve_function
  unset MILVUS_TOKEN 2>/dev/null || true
  export MILVUS_TOKEN_FILE="/nonexistent/path/secret"
  if output=$(resolve_file_secret MILVUS_TOKEN 2>&1); then
    fail "should have exited with error"
  else
    if echo "$output" | grep -q "not a regular file"; then
      pass "missing file detected"
    else
      fail "unexpected error: $output"
    fi
  fi
) || pass "missing file detected (exit)"

# Test 6: trailing newlines in file are stripped (standard $(cat) behavior)
echo "--- Test: trailing newlines stripped ---"
(
  setup_tmpdir
  source_resolve_function
  printf 'my-api-key\n\n' > "$TMPDIR_TEST/key_with_newlines"
  unset BRAVE_SEARCH_API_KEY 2>/dev/null || true
  export BRAVE_SEARCH_API_KEY_FILE="$TMPDIR_TEST/key_with_newlines"
  resolve_file_secret BRAVE_SEARCH_API_KEY
  if [ "$BRAVE_SEARCH_API_KEY" = "my-api-key" ]; then
    pass "trailing newlines stripped"
  else
    fail "expected 'my-api-key', got '$BRAVE_SEARCH_API_KEY'"
  fi
  teardown_tmpdir
) || fail "subshell exited with error"

# Test 7: file content with special characters
echo "--- Test: special characters preserved ---"
(
  setup_tmpdir
  source_resolve_function
  # shellcheck disable=SC2016
  echo -n 'p@$$w0rd!#%^&*()' > "$TMPDIR_TEST/special"
  unset PGVECTOR_PASSWORD 2>/dev/null || true
  export PGVECTOR_PASSWORD_FILE="$TMPDIR_TEST/special"
  resolve_file_secret PGVECTOR_PASSWORD
  # shellcheck disable=SC2016
  if [ "$PGVECTOR_PASSWORD" = 'p@$$w0rd!#%^&*()' ]; then
    pass "special characters preserved"
  else
    fail "expected 'p@\$\$w0rd!#%^&*()', got '$PGVECTOR_PASSWORD'"
  fi
  teardown_tmpdir
) || fail "subshell exited with error"

# Test 8: noop when neither base nor _FILE is set
echo "--- Test: noop when neither is set ---"
(
  source_resolve_function
  unset WATSONX_API_KEY 2>/dev/null || true
  unset WATSONX_API_KEY_FILE 2>/dev/null || true
  resolve_file_secret WATSONX_API_KEY
  if [ -z "${WATSONX_API_KEY:-}" ]; then
    pass "noop when neither is set"
  else
    fail "variable should be unset, got '$WATSONX_API_KEY'"
  fi
) || fail "subshell exited with error"

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "All tests passed!"
  exit 0
else
  echo "$FAILURES test(s) failed!"
  exit 1
fi
