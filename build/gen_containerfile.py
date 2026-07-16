# Copyright (c) Red Hat
# All rights reserved.
#
# This source code is licensed under the terms described in the LICENSE file in
# the root directory of this source tree.

# /// script
# requires-python = ">=3.12"
# dependencies = ["pydantic-settings>=2,<3"]
# ///

import base64
import sys
from pathlib import Path

from common import BuildConfig


def _generate_config_labels(version: str) -> str:
    """Generate OCI LABEL instruction with base64-encoded config.yaml."""
    config_path = Path("distribution/config.yaml")
    if not config_path.exists():
        print(f"Error: {config_path} not found")
        sys.exit(1)

    encoded = base64.b64encode(config_path.read_bytes()).decode("ascii")

    labels = [
        ("com.ogx.config.config.yaml", encoded),
        ("com.ogx.distribution.name", "rh"),
        ("com.ogx.distribution.version", version),
        ("com.ogx.distribution.default-config", "config.yaml"),
        ("com.ogx.distribution.configs", "config.yaml"),
        ("org.opencontainers.image.title", "OGX - rh"),
        ("org.opencontainers.image.version", version),
    ]

    first = f'LABEL {labels[0][0]}="{labels[0][1]}" \\'
    rest = [f'  {k}="{v}"' for k, v in labels[1:]]
    return first + "\n" + " \\\n".join(rest)


def main():
    config = BuildConfig()
    version = config.ogx_version

    template_path = Path("Containerfile.in")
    output_path = Path("Containerfile")

    if not template_path.exists():
        print(f"Error: Template file {template_path} not found")
        sys.exit(1)

    template_content = template_path.read_text(encoding="utf-8")
    placeholder_count = template_content.count("{config_labels}")
    if placeholder_count != 1:
        print(
            f"Error: Containerfile.in must contain exactly one '{{config_labels}}' placeholder, found {placeholder_count}"
        )
        sys.exit(1)

    warning = (
        "# WARNING: This file is auto-generated from Containerfile.in\n"
        "# by build/gen_containerfile.py - do not edit manually.\n"
    )

    # Use str.replace() to avoid format string injection from label content
    containerfile_content = warning + template_content
    containerfile_content = containerfile_content.replace(
        "{config_labels}", _generate_config_labels(version)
    )

    output_path.write_text(containerfile_content, encoding="utf-8")
    print(f"Successfully generated {output_path}")


if __name__ == "__main__":
    main()
