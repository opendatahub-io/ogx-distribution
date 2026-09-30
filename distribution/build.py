#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
# All rights reserved.
#
# This source code is licensed under the terms described in the LICENSE file in
# the root directory of this source tree.

# Usage: ./distribution/build.py

import shutil
import subprocess
import sys
import os
import re
import shlex
from pathlib import Path

CURRENT_LLAMA_STACK_VERSION = "v0.7.3+rhaiv.0"
LLAMA_STACK_VERSION = os.getenv("LLAMA_STACK_VERSION", CURRENT_LLAMA_STACK_VERSION)
LLAMA_STACK_CLIENT_VERSION = (
    "0.7.3"  # Explicit version; set to None to auto-derive from LLAMA_STACK_VERSION
)
BASE_REQUIREMENTS = [
    f"llama-stack=={LLAMA_STACK_VERSION}",
]

# Constrain packages we are patching to ensure reliable and repeatable build
PINNED_DEPENDENCIES = [
    "'kfp-kubernetes==2.14.6'",
    "'pyarrow>=21.0.0'",
    "'botocore==1.35.88'",
    "'boto3==1.35.88'",
    "'aiobotocore==2.16.1'",
    "'ibm-cos-sdk-core==2.14.2'",
    "'ibm-cos-sdk==2.14.2'",
    "'setuptools==81.0.0'",  # due to bug in milvus-lite with unreleased fix: https://github.com/milvus-io/milvus-lite/pull/323
    "'pillow>=12.3.0'",  # CVE-2026-42311, CVE-2026-55379/55380/54060
    "'nltk>=3.10.0'",  # CVE-2026-54293, CVE-2026-12243
    "'mcp>=1.23.0,<2.0.0'",  # mcp 2.0 renamed McpError, breaks llama-stack 0.7.x
]

source_install_command_pypi_client = """RUN uv pip install --no-cache --no-deps git+https://github.com/opendatahub-io/llama-stack.git@{llama_stack_version}
RUN uv pip install --no-cache --no-deps llama-stack-client=={llama_stack_client_version}"""

source_install_command_git_client = """RUN uv pip install --no-cache --no-deps git+https://github.com/opendatahub-io/llama-stack.git@{llama_stack_version}
RUN uv pip install --no-cache --no-deps 'llama-stack-api@git+https://github.com/opendatahub-io/llama-stack.git@{llama_stack_version}#subdirectory=src/llama_stack_api'"""


def get_llama_stack_install(llama_stack_version):
    # Use explicit client version if set, otherwise derive from llama_stack_version
    # by removing +rhai suffix and restricting to x.y.z format (3 parts)
    if LLAMA_STACK_CLIENT_VERSION:
        llama_stack_client_version = LLAMA_STACK_CLIENT_VERSION
    else:
        # Remove +rhai suffix and restrict to x.y.z (e.g., v0.6.0.1+rhai0 -> v0.6.0)
        base_version = llama_stack_version.split("+")[0]
        llama_stack_client_version = ".".join(base_version.split(".")[:3])
    # If the version is a commit SHA or a short commit SHA, we need to install from source
    if is_install_from_source(llama_stack_version):
        print(f"Installing llama-stack from source: {llama_stack_version}")

        # Determine if client should come from PyPI or git
        # Version tags (v0.5.0+rhai0) use PyPI for client (stable release)
        # Branch names (main, release-0.5.x) use git for client (matching branch)
        if is_version_tag(llama_stack_version):
            # Version tag - use PyPI for client (stable release)
            template = source_install_command_pypi_client
        else:
            # Branch name - use git for client (matching branch)
            template = source_install_command_git_client

        return template.format(
            llama_stack_version=llama_stack_version,
            llama_stack_client_version=llama_stack_client_version,
        ).rstrip()


def is_version_tag(version_str):
    """Check if this looks like a version tag (e.g., v0.5.0, 0.5.0, v0.5.0+rhai0) vs a branch name (e.g., main, release-0.5.x)."""
    # Strip +rhai suffix if present
    base = version_str.split("+")[0]

    # Version tags typically start with 'v' followed by a digit, or just start with a digit
    # Examples: v0.5.0, v1.2.3, 0.5.0
    # Branch names: main, develop, release-0.5.x, feature/foo
    if base.startswith("v") and len(base) > 1 and base[1].isdigit():
        return True
    if base[0].isdigit():
        return True
    return False


def is_install_from_source(llama_stack_version):
    """Check if version string requires git install (branch/commit) vs PyPI (version tag)."""
    # Custom versions with +rhai suffix always install from source
    if "+rhai" in llama_stack_version:
        return True
    # Version tags (v0.5.0, 0.5.0) use PyPI
    if is_version_tag(llama_stack_version):
        return False
    # Everything else (branch names, commit SHAs) install from source
    return True


def check_command_installed(command, package_name=None):
    """Check if a command is installed and accessible."""
    if not shutil.which(command):
        if package_name:
            print(
                f"Error: {command} not found. Please run uv pip install {package_name}"
            )
        else:
            print(f"Error: {command} not found. Please install it.")
        sys.exit(1)


def check_llama_stack_version():
    """Check if the llama-stack version in BASE_REQUIREMENTS matches the installed version."""
    try:
        result = subprocess.run(
            ["llama stack --version"],
            shell=True,
            capture_output=True,
            text=True,
            check=True,
        )
        installed_version = result.stdout.strip()

        # Extract version from BASE_REQUIREMENTS
        expected_version = None
        for req in BASE_REQUIREMENTS:
            if req.startswith("llama-stack=="):
                expected_version = req.split("==")[1]
                break

        if expected_version and installed_version != expected_version:
            print("Error: llama-stack version mismatch!")
            print(f"  Expected: {expected_version}")
            print(f"  Installed: {installed_version}")
            print(
                "  If you just bumped the llama-stack version in BASE_REQUIREMENTS, you must update the version from .pre-commit-config.yaml"
            )
            sys.exit(1)

    except subprocess.CalledProcessError as e:
        print(f"Warning: Could not check llama-stack version: {e}")
        print("Continuing without version validation...")


def install_llama_stack_from_source(llama_stack_version):
    """Install llama-stack from source using git."""
    print("installing llama-stack from source...")
    try:
        result = subprocess.run(
            f"uv pip install git+https://github.com/opendatahub-io/llama-stack.git@{llama_stack_version}",
            shell=True,
            check=True,
            capture_output=True,
            text=True,
        )
        # Print stdout if there's any output
        if result.stdout:
            print(result.stdout)
    except subprocess.CalledProcessError as e:
        print(f"Error installing llama-stack: {e}")
        if e.stdout:
            print(f"stdout: {e.stdout}")
        if e.stderr:
            print(f"stderr: {e.stderr}")
        sys.exit(1)


def get_dependencies():
    """Execute the llama stack build command and capture dependencies."""
    cmd = "llama stack list-deps distribution/config.yaml"
    try:
        result = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, check=True
        )
        # Categorize and sort different types of pip install commands
        standard_deps = []
        torch_deps = []
        no_deps = []
        no_cache = []

        for line in result.stdout.splitlines():
            line = line.strip()
            if not line:  # Skip empty lines
                continue

            # New format: just packages, possibly with flags
            cmd_parts = ["RUN", "uv", "pip", "install"]
            packages_str = line

            # Parse packages and flags from the line
            # Use shlex.split to properly handle quoted package names
            parts_list = shlex.split(packages_str)
            packages = []
            flags = []
            extra_index_url = None

            i = 0
            while i < len(parts_list):
                if parts_list[i] == "--extra-index-url" and i + 1 < len(parts_list):
                    extra_index_url = parts_list[i + 1]
                    flags.extend([parts_list[i], parts_list[i + 1]])
                    i += 2
                elif parts_list[i] == "--index-url" and i + 1 < len(parts_list):
                    flags.extend([parts_list[i], parts_list[i + 1]])
                    i += 2
                elif parts_list[i] in ["--no-deps", "--no-cache"]:
                    flags.append(parts_list[i])
                    i += 1
                else:
                    packages.append(parts_list[i])
                    i += 1

            # Sort and deduplicate packages
            packages = sorted(set(packages))

            # Add quotes to packages with > or < to prevent bash redirection
            packages = [
                f"'{package}'" if (">" in package or "<" in package) else package
                for package in packages
            ]

            # Pin pymilvus to 2.6.9 to avoid gRPC crash
            # 2.6.10 crashes Milvus Lite gRPC init with empty dns:/// target
            packages = [
                "'pymilvus[milvus-lite]==2.6.9'"
                if "pymilvus[milvus-lite]" in package
                else "'pymilvus==2.6.9'"
                if "pymilvus" in package
                else package
                for package in packages
            ]

            # Convert namespace packages like llama_stack_provider_ragas.extra==0.5.1
            # to extras syntax llama_stack_provider_ragas[extra]==0.5.1
            # Only match .extra immediately before a version specifier (not in version numbers)
            #
            # We are not sending a patch to llama-stack upstream because not everyone python
            # sub-module is a package, we just handle this here instead for our own packages.
            # Even though pip will just show a warning if the extra does not exist
            packages = [
                re.sub(
                    r"\.([a-zA-Z_][a-zA-Z0-9_]*)(==|>=|<=|>|<|~=|!=)",
                    r"[\1]\2",
                    package,
                )
                for package in packages
            ]
            packages = sorted(set(packages))

            # Build the command based on flags
            if extra_index_url or "--index-url" in flags:
                # Torch dependencies with extra index URL
                full_cmd = " ".join(cmd_parts + flags + packages)
                torch_deps.append(full_cmd)
            elif "--no-deps" in flags:
                full_cmd = " ".join(cmd_parts + flags + packages)
                no_deps.append(full_cmd)
            elif "--no-cache" in flags:
                full_cmd = " ".join(cmd_parts + flags + packages)
                no_cache.append(full_cmd)
            else:
                # Standard dependencies with multi-line formatting
                formatted_packages = " \\\n    ".join(packages)
                full_cmd = f"{' '.join(cmd_parts)} \\\n    {formatted_packages}"
                standard_deps.append(full_cmd)

        # Combine all dependencies in specific order
        all_deps = []

        # Add pinned dependencies FIRST to ensure version compatibility
        if PINNED_DEPENDENCIES:
            pinned_packages = " \\\n    ".join(PINNED_DEPENDENCIES)
            pinned_cmd = f"RUN uv pip install --upgrade \\\n    {pinned_packages}"
            all_deps.append(pinned_cmd)

        all_deps.extend(sorted(standard_deps))  # Regular pip installs
        all_deps.extend(sorted(torch_deps))  # PyTorch specific installs
        all_deps.extend(sorted(no_deps))  # No-deps installs
        all_deps.extend(sorted(no_cache))  # No-cache installs

        result = "\n".join(all_deps)
        return result
    except subprocess.CalledProcessError as e:
        print(f"Error executing command: {e}")
        print(f"Command output: {e.output}")
        print(f"Command stderr: {e.stderr}")
        sys.exit(1)


def generate_containerfile(dependencies, llama_stack_install):
    """Generate Containerfile from template with dependencies."""
    template_path = Path("distribution/Containerfile.in")
    output_path = Path("distribution/Containerfile")

    if not template_path.exists():
        print(f"Error: Template file {template_path} not found")
        sys.exit(1)

    # Read template
    with open(template_path) as f:
        template_content = f.read()

    # Add warning message at the top
    warning = "# WARNING: This file is auto-generated. Do not modify it manually.\n# Generated by: distribution/build.py\n\n"

    # Process template using string formatting
    containerfile_content = warning + template_content.format(
        dependencies=dependencies.rstrip(),
        llama_stack_install_source=llama_stack_install if llama_stack_install else "",
    )

    # Remove any blank lines that result from empty substitutions
    containerfile_content = (
        "\n".join(line for line in containerfile_content.splitlines() if line.strip())
        + "\n"
    )

    # Write output
    with open(output_path, "w") as f:
        f.write(containerfile_content)

    print(f"Successfully generated {output_path}")


def main():
    check_command_installed("uv")
    install_llama_stack_from_source(LLAMA_STACK_VERSION)

    check_command_installed("llama", "llama-stack-client")

    # Do not perform version check if installing from source
    if not is_install_from_source(LLAMA_STACK_VERSION):
        print("Checking llama-stack version...")
        check_llama_stack_version()

    print("Getting dependencies...")
    dependencies = get_dependencies()

    print("Getting llama-stack install...")
    llama_stack_install = get_llama_stack_install(LLAMA_STACK_VERSION)

    print("Generating Containerfile...")
    generate_containerfile(dependencies, llama_stack_install)

    print("Done!")


if __name__ == "__main__":
    main()
