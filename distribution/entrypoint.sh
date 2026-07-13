#!/bin/sh
set -e

# Resolve _FILE variants for secret environment variables.
#
# For each secret variable (e.g. OPENAI_API_KEY), if the corresponding
# _FILE variant (OPENAI_API_KEY_FILE) is set, read the file contents
# into the base variable. This lets Kubernetes operators mount secrets
# as files instead of injecting them via env vars, avoiding exposure
# through /proc/1/environ and subprocess environments.
resolve_file_secret() {
  _rfs_var="$1"
  _rfs_file_var="${_rfs_var}_FILE"
  eval "_rfs_file_val=\${${_rfs_file_var}:-}"
  eval "_rfs_var_val=\${${_rfs_var}:-}"

  if [ -n "$_rfs_file_val" ] && [ -n "$_rfs_var_val" ]; then
    printf 'Error: both %s and %s are set (mutually exclusive)\n' \
      "$_rfs_var" "$_rfs_file_var" >&2
    exit 1
  fi

  if [ -n "$_rfs_file_val" ]; then
    if [ ! -f "$_rfs_file_val" ]; then
      printf 'Error: %s references %s, which is not a regular file\n' \
        "$_rfs_file_var" "$_rfs_file_val" >&2
      exit 1
    fi
    _rfs_content="$(cat "$_rfs_file_val")"
    eval "export ${_rfs_var}=\$_rfs_content"
    unset "$_rfs_file_var"
  fi
}

for _secret_var in \
    ANTHROPIC_API_KEY \
    AWS_ACCESS_KEY_ID \
    AWS_BEDROCK_BEARER_TOKEN \
    AWS_SECRET_ACCESS_KEY \
    AZURE_API_KEY \
    BRAVE_SEARCH_API_KEY \
    DOCLING_SERVE_API_KEY \
    GEMINI_ACCESS_TOKEN \
    GEMINI_API_KEY \
    MILVUS_TOKEN \
    OPENAI_API_KEY \
    PGVECTOR_PASSWORD \
    POSTGRES_PASSWORD \
    QDRANT_API_KEY \
    TAVILY_SEARCH_API_KEY \
    VLLM_API_TOKEN \
    VLLM_EMBEDDING_API_TOKEN \
    WATSONX_API_KEY \
; do
  resolve_file_secret "$_secret_var"
done
unset _secret_var

# Resolve config path
if [ -n "$RUN_CONFIG_PATH" ] && [ -f "$RUN_CONFIG_PATH" ]; then
  CONFIG="$RUN_CONFIG_PATH"
elif [ -n "$DISTRO_NAME" ]; then
  CONFIG="$DISTRO_NAME"
else
  CONFIG="/opt/app-root/config.yaml"
fi

# Optionally wrap with opentelemetry-instrument when OTEL_SERVICE_NAME is set.
# Logs export is intentionally omitted by default; set OTEL_LOGS_EXPORTER=otlp to enable.
if [ -n "$OTEL_SERVICE_NAME" ]; then
  exec opentelemetry-instrument \
    --traces_exporter=otlp \
    --metrics_exporter=otlp \
    --service_name="$OTEL_SERVICE_NAME" \
    -- \
    ogx run --insecure "$CONFIG" "$@"
fi

exec ogx run --insecure "$CONFIG" "$@"
