#!/bin/sh
set -e

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
    ogx stack run "$CONFIG" "$@"
fi

exec ogx stack run "$CONFIG" "$@"
