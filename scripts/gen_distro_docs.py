#!/usr/bin/env python3

import yaml
import re
from pathlib import Path


REPO_ROOT = Path(__file__).parent.parent


def extract_ogx_version():
    """Extract OGX version and repo owner from the Containerfile.

    Returns:
        tuple: (version, repo_owner) where repo_owner defaults to 'opendatahub-io'
    """
    containerfile_path = REPO_ROOT / "distribution" / "Containerfile"

    if not containerfile_path.exists():
        print(f"Error: {containerfile_path} not found")
        exit(1)

    try:
        with open(containerfile_path, "r") as file:
            content = file.read()

        # Check for "main" version in git URL format
        main_pattern = r"git\+https://github\.com/([^/]+)/ogx\.git@main"
        main_match = re.search(main_pattern, content)
        if main_match:
            repo_owner = main_match.group(1)
            return ("main", repo_owner)

        # Look for ogx version in pip install commands
        # Pattern matches: ogx==X.Y.Z or ogx==X.Y.ZrcN+rhaiM
        pattern = r"ogx==([0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?(?:rc[0-9]+)?(?:\+rhaiv\.[0-9]+)?)"
        match = re.search(pattern, content)

        if match:
            return (match.group(1), "opendatahub-io")

        # Look for git URL format: git+https://github.com/*/ogx.git@vVERSION or @VERSION
        git_pattern = r"git\+https://github\.com/([^/]+)/ogx\.git@v?([0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?(?:rc[0-9]+)?(?:\+rhaiv\.[0-9]+)?)"
        git_match = re.search(git_pattern, content)

        if git_match:
            return (git_match.group(2), git_match.group(1))

        print("Error: Could not find ogx version in Containerfile")
        exit(1)

    except Exception as e:
        print(f"Error reading Containerfile: {e}")
        exit(1)


def load_external_providers_info():
    """Load build.yaml and extract external provider information."""
    config_path = REPO_ROOT / "distribution" / "build.yaml"

    if not config_path.exists():
        print(f"Error: {config_path} not found")
        exit(1)

    try:
        with open(config_path, "r") as file:
            config_data = yaml.safe_load(file)

        providers = config_data.get("providers", {})

        # Create a mapping of provider_type to external info
        external_info = {}

        for _, provider_list in providers.items():
            if isinstance(provider_list, list):
                for provider in provider_list:
                    if isinstance(provider, dict) and "provider_type" in provider:
                        provider_type = provider["provider_type"]
                        module_field = provider.get("module", "")

                        if module_field:
                            # Extract version from module field (format: package_name==version)
                            if "==" in module_field:
                                # Handle cases like package[extra]==version
                                version_part = module_field.split("==")[-1]
                                external_info[provider_type] = (
                                    f"Yes (version {version_part})"
                                )
                            else:
                                external_info[provider_type] = "Yes"

        return external_info

    except Exception as e:
        print(f"Error: Error reading build.yaml: {e}")
        exit(1)


def load_runtime_provider_types():
    """Load config.yaml and return the set of provider_types in the runtime config."""
    config_path = REPO_ROOT / "distribution" / "config.yaml"

    if not config_path.exists():
        print(f"Error: {config_path} not found")
        exit(1)

    with open(config_path, "r") as file:
        config_data = yaml.safe_load(file)

    runtime_types = set()
    providers = config_data.get("providers", {})
    for _, provider_list in providers.items():
        if isinstance(provider_list, list):
            for provider in provider_list:
                if isinstance(provider, dict) and "provider_type" in provider:
                    runtime_types.add(provider["provider_type"])
    return runtime_types


def gen_distro_table(providers_data, runtime_provider_types=None):
    # Start with table header
    table_lines = [
        "| API | Provider | External? | Enabled by default? | How to enable |",
        "|-----|----------|-----------|---------------------|---------------|",
    ]

    external_providers = load_external_providers_info()

    # Create a list to collect all API-Provider pairs for sorting
    api_provider_pairs = []

    # Iterate through each API type and its providers
    for api_name, provider_list in providers_data.items():
        if isinstance(provider_list, list):
            for provider in provider_list:
                if isinstance(provider, dict) and "provider_type" in provider:
                    provider_type = provider["provider_type"]
                    provider_id = provider.get("provider_id", "")

                    # Check if provider_id contains the conditional syntax ${<something>:+<something>}
                    # This regex matches the pattern ${...} containing :+
                    conditional_match = re.search(
                        r"\$\{([^}]*:\+[^}]*)\}", str(provider_id)
                    )

                    is_dependency_only = (
                        runtime_provider_types is not None
                        and provider_type not in runtime_provider_types
                    )

                    if is_dependency_only:
                        enabled_by_default = "Dependency only*"
                        how_to_enable = "Requires a custom `config.yaml`"
                    elif conditional_match:
                        enabled_by_default = "❌"
                        env_var = conditional_match.group(1).split(":+")[0]
                        if env_var.startswith("env."):
                            env_var = env_var[4:]
                        how_to_enable = f"Set the `{env_var}` environment variable"
                    else:
                        enabled_by_default = "✅"
                        how_to_enable = "N/A"

                    notes = provider.get("notes", "")
                    if notes:
                        how_to_enable += f". {notes}"

                    external_status = external_providers.get(provider_type, "No")

                    api_provider_pairs.append(
                        (
                            api_name,
                            provider_type,
                            external_status,
                            enabled_by_default,
                            how_to_enable,
                        )
                    )

    # Sort first by API name, then by provider type
    api_provider_pairs.sort(key=lambda x: (x[0], x[1]))

    # Add sorted pairs to table
    for (
        api_name,
        provider_type,
        external_status,
        enabled_by_default,
        how_to_enable,
    ) in api_provider_pairs:
        table_lines.append(
            f"| {api_name} | {provider_type} | {external_status} | {enabled_by_default} | {how_to_enable} |"
        )

    return "\n".join(table_lines)


def gen_distro_docs():
    build_path = REPO_ROOT / "distribution" / "build.yaml"
    readme_path = REPO_ROOT / "distribution" / "README.md"

    if not build_path.exists():
        print(f"Error: {build_path} not found")
        return 1

    # extract OGX version and repo owner from Containerfile
    version, repo_owner = extract_ogx_version()

    # Determine the link based on whether version is a commit hash or a version tag
    # Commit hashes are 7-40 hex characters, version tags contain dots or other chars
    is_commit_hash = (
        len(version) >= 7
        and len(version) <= 40
        and all(c in "0123456789abcdef" for c in version.lower())
    )
    if is_commit_hash:
        version_link = f"https://github.com/{repo_owner}/ogx/commit/{version}"
        # Display short hash for readability
        version_display = version[:7]
    elif version == "main":
        version_link = f"https://github.com/{repo_owner}/ogx/tree/main"
        version_display = version
    else:
        version_link = f"https://github.com/{repo_owner}/ogx/releases/tag/v{version}"
        version_display = version

    # header section
    header = f"""<!-- This file is automatically generated by scripts/gen_distro_docs.py from build.yaml and config.yaml - do not update manually -->

# Open Data Hub OGX Distribution Image

This image contains the official Open Data Hub OGX distribution, with all the packages and configuration needed to run an OGX server in a containerized environment.

The image is currently shipping with the Open Data Hub version of OGX version [{version_display}]({version_link})

You can see an overview of the APIs and Providers the image ships with in the table below.

"""

    try:
        with open(build_path, "r") as file:
            build_data = yaml.safe_load(file)

        providers = build_data.get("providers", {})

        if not providers:
            print("Error: No providers found in build.yaml")
            return 1

        runtime_provider_types = load_runtime_provider_types()

        table_content = gen_distro_table(providers, runtime_provider_types)

        dep_only_note = (
            "\n\\* **Dependency only** providers are not included in the "
            "default runtime `config.yaml` but their dependencies are "
            "pre-installed in the container image. To use them, pass a "
            "custom `config.yaml` at runtime that includes the provider "
            "definitions.\n"
        )

        with open(readme_path, "w") as readme_file:
            readme_file.write(header + table_content + "\n" + dep_only_note)

        print(f"Successfully generated {readme_path}")
        print(
            "Ensure you have checked-in any changes to the README to git, or the pre-commit check using this script will fail"
        )
        return 0

    except Exception as e:
        print(f"Error: {e}")
        return 1


if __name__ == "__main__":
    exit(gen_distro_docs())
