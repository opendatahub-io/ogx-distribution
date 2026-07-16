# Copyright (c) Red Hat
# All rights reserved.
#
# This source code is licensed under the terms described in the LICENSE file in
# the root directory of this source tree.
"""Verify that entrypoint.sh _FILE list matches secrets in build.yaml."""

# /// script
# requires-python = ">=3.12"
# dependencies = ["pyyaml>=6,<7"]
# ///

import re
import sys
from pathlib import Path

from yaml import safe_load

_SECRET_FIELD_WORDS = {"password", "secret", "token", "credential"}
_SECRET_FIELD_SUBSTRINGS = {"api_key", "access_key"}
_SECRET_FIELD_EXCLUDE_SUFFIXES = ("_file", "_path", "_url", "_dir")


def _is_secret_field(field_name: str) -> bool:
    """Heuristic: does this YAML config field name hold a secret value?"""
    lower = field_name.lower()
    if lower.endswith(_SECRET_FIELD_EXCLUDE_SUFFIXES):
        return False
    words = set(lower.split("_"))
    if words & _SECRET_FIELD_WORDS:
        return True
    return any(sub in lower for sub in _SECRET_FIELD_SUBSTRINGS)


def _extract_secret_env_vars_from_yaml(yaml_path: Path) -> set[str]:
    """Walk build.yaml and return env var names referenced by secret fields."""
    env_ref = re.compile(r"\$\{env\.([^:}]+):[=+]")
    secrets: set[str] = set()

    def _walk(node, parent_key=""):
        if isinstance(node, dict):
            for key, value in node.items():
                _walk(value, parent_key=key)
        elif isinstance(node, list):
            for item in node:
                _walk(item, parent_key=parent_key)
        elif isinstance(node, str):
            if _is_secret_field(parent_key):
                for match in env_ref.finditer(node):
                    secrets.add(match.group(1))

    with open(yaml_path, encoding="utf-8") as f:
        data = safe_load(f)
    _walk(data)
    return secrets


def _extract_entrypoint_secrets(entrypoint_path: Path) -> set[str]:
    """Extract the secret var names from the entrypoint.sh for-loop."""
    text = entrypoint_path.read_text(encoding="utf-8")
    match = re.search(r"for _secret_var in\s*\\(.*?);\s*do", text, re.DOTALL)
    if not match:
        print(f"Error: could not find _secret_var loop in {entrypoint_path}")
        sys.exit(1)
    body = match.group(1).replace("\\", " ")
    return {v for v in body.split() if v}


def main():
    yaml_path = Path("build/build.yaml")
    entrypoint_path = Path("distribution/entrypoint.sh")

    yaml_secrets = _extract_secret_env_vars_from_yaml(yaml_path)
    entrypoint_secrets = _extract_entrypoint_secrets(entrypoint_path)

    missing_from_entrypoint = yaml_secrets - entrypoint_secrets
    extra_in_entrypoint = entrypoint_secrets - yaml_secrets

    if missing_from_entrypoint or extra_in_entrypoint:
        print(
            "Error: distribution/entrypoint.sh _FILE secret list is out of sync "
            "with build/build.yaml."
        )
        if missing_from_entrypoint:
            print(f"  Add to entrypoint.sh:    {sorted(missing_from_entrypoint)}")
        if extra_in_entrypoint:
            print(f"  Remove from entrypoint.sh: {sorted(extra_in_entrypoint)}")
        print(
            "\nWhen adding a new provider with secret fields (api_key, password, "
            "token, etc.) to build/build.yaml, also add the env var to the "
            "_FILE resolution loop in distribution/entrypoint.sh."
        )
        sys.exit(1)

    print(
        f"Verified {len(yaml_secrets)} secret env vars have _FILE support in entrypoint.sh"
    )


if __name__ == "__main__":
    main()
