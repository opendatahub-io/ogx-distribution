#!/bin/bash
# Verify that the OCI config label on a built image matches distribution/config.yaml.
# Usage: ./tests/verify-config-label.sh <image>

set -euo pipefail

IMAGE="${1:-}"
LABEL_KEY="com.ogx.config.config.yaml"

if [ -z "$IMAGE" ]; then
  echo "Usage: $0 <image>"
  echo "Example: $0 quay.io/opendatahub/odh-ogx-core:latest"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="$SCRIPT_DIR/../distribution/config.yaml"

if [ ! -f "$CONFIG_PATH" ]; then
  echo "ERROR: $CONFIG_PATH not found"
  exit 1
fi

echo "Verifying OCI config label on image: $IMAGE"

# Extract the label from the image
LABEL_VALUE=$(docker inspect "$IMAGE" --format "{{index .Config.Labels \"$LABEL_KEY\"}}" 2>/dev/null || true)

if [ -z "$LABEL_VALUE" ]; then
  echo "ERROR: Label '$LABEL_KEY' not found on image"
  exit 1
fi

# Decode the label and compare with the source config
DECODED_LABEL=$(echo "$LABEL_VALUE" | base64 -d)
EXPECTED=$(cat "$CONFIG_PATH")

if [ "$DECODED_LABEL" = "$EXPECTED" ]; then
  echo "PASS: OCI config label matches distribution/config.yaml"
else
  echo "FAIL: OCI config label does not match distribution/config.yaml"
  echo ""
  echo "--- Expected (distribution/config.yaml) first 5 lines ---"
  echo "$EXPECTED" | head -5
  echo "--- Got (decoded label) first 5 lines ---"
  echo "$DECODED_LABEL" | head -5
  exit 1
fi

# Verify other metadata labels
echo "Checking metadata labels..."

VERSION_LABEL=$(docker inspect "$IMAGE" --format '{{index .Config.Labels "com.ogx.distribution.version"}}' 2>/dev/null || true)
NAME_LABEL=$(docker inspect "$IMAGE" --format '{{index .Config.Labels "com.ogx.distribution.name"}}' 2>/dev/null || true)

if [ -z "$VERSION_LABEL" ]; then
  echo "FAIL: Label 'com.ogx.distribution.version' not found"
  exit 1
fi
echo "  com.ogx.distribution.version=$VERSION_LABEL"

if [ -z "$NAME_LABEL" ]; then
  echo "FAIL: Label 'com.ogx.distribution.name' not found"
  exit 1
fi
echo "  com.ogx.distribution.name=$NAME_LABEL"

echo "PASS: All OCI config labels verified"
