"""Environment-based configuration for notebooks.

Exports the same parameters used by Bruno and the test scripts,
read from environment variables via os.environ.get.
"""

import os

base_url = os.environ.get("BASE_URL") or os.environ.get(
    "OGX_BASE_URL", "http://localhost:8321"
)
model = os.environ.get("MODEL") or os.environ.get("MODEL_ID", "")
api_key = os.environ.get("API_KEY", "")
files_provider = os.environ.get("FILES_PROVIDER", "")
inference_provider = os.environ.get("INFERENCE_PROVIDER", "")
vector_io_provider = os.environ.get("VECTOR_IO_PROVIDER", "")
