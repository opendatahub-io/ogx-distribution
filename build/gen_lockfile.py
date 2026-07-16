# Copyright (c) Red Hat
# All rights reserved.
#
# This source code is licensed under the terms described in the LICENSE file in
# the root directory of this source tree.

# /// script
# requires-python = ">=3.12"
# dependencies = ["pydantic-settings>=2,<3"]
# ///

import enum
import os
import re
import shlex
import subprocess
import sys
import tempfile
from collections.abc import Generator
from contextlib import contextmanager
from pathlib import Path
from typing import NamedTuple

from common import BuildConfig

OGX_GIT_REPO = "https://github.com/opendatahub-io/ogx.git"


class OgxRequirements(NamedTuple):
    ogx_api: str
    ogx: str


class LockfileType(enum.StrEnum):
    MIDSTREAM = "midstream"
    DOWNSTREAM = "downstream"


class IndexConfig(NamedTuple):
    index_url: str
    torch_backend: str | None = None


class LockfileConfig(NamedTuple):
    output_path: Path
    index_config: IndexConfig


def _resolve_ref_to_sha(repo_url: str, ref: str) -> str:
    """Resolve a git ref (tag or branch) to a commit SHA via git ls-remote.

    For annotated tags, returns the dereferenced commit SHA.
    """
    result = subprocess.run(
        ["git", "ls-remote", "--tags", "--heads", repo_url, ref],
        capture_output=True,
        text=True,
        check=True,
        timeout=30,
    )

    sha = None
    for line in result.stdout.strip().splitlines():
        line_sha, line_ref = line.split("\t", 1)
        if line_ref.endswith("^{}"):
            return line_sha
        sha = line_sha

    if sha is None:
        raise ValueError(f"Could not resolve ref {ref!r} in {repo_url}")

    return sha


def _get_ogx_requirements(version: str, install_from_source: bool) -> OgxRequirements:
    """Resolve ogx package specifiers.

    When installing from source, the git tag is resolved to an immutable
    commit SHA via git ls-remote.
    """
    if install_from_source:
        sha = _resolve_ref_to_sha(OGX_GIT_REPO, version)
        return OgxRequirements(
            ogx_api=f"ogx-api @ git+{OGX_GIT_REPO}@{sha}#subdirectory=src/ogx_api",
            ogx=f"ogx @ git+{OGX_GIT_REPO}@{sha}",
        )
    else:
        return OgxRequirements(
            ogx_api=f"ogx-api=={version.split('+')[0]}",
            ogx=f"ogx=={version}",
        )


def _run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess[str]:
    """Run a command, printing stdout/stderr on failure."""
    try:
        return subprocess.run(cmd, check=True, capture_output=True, text=True, **kwargs)
    except subprocess.CalledProcessError as e:
        print(f"Error running: {shlex.join(cmd)}")
        if e.stdout:
            print(f"stdout: {e.stdout}")
        if e.stderr:
            print(f"stderr: {e.stderr}")
        raise


@contextmanager
def _build_venv(
    packages: list[str],
    index_config: IndexConfig,
    constraints: Path | None = None,
) -> Generator[Path]:
    """Create a temporary venv with the given packages installed. Yields the venv path."""
    with tempfile.TemporaryDirectory() as tmpdir:
        venv_path = Path(tmpdir) / "venv"

        subprocess.run(
            ["uv", "venv", "--python", sys.executable, str(venv_path)],
            check=True,
            capture_output=True,
            text=True,
        )

        cmd = [
            "uv",
            "pip",
            "install",
            "--python",
            str(venv_path / "bin" / "python"),
            "--config-file",
            "/dev/null",
            "--default-index",
            index_config.index_url,
            *packages,
        ]
        if constraints:
            cmd.extend(["--constraint", str(constraints)])
        if index_config.torch_backend:
            cmd.extend(["--torch-backend", index_config.torch_backend])

        _run(cmd)
        yield venv_path


def _resolve_env_defaults(text):
    """Replace ${env.VAR:=default} and ${env.VAR:+value} templates.

    Pydantic validates build.yaml before env-var substitution, so
    non-string fields (e.g. integers) must contain plain values.
    Empty defaults are quoted to avoid YAML null interpretation.
    """

    def _replace_default(match):
        default = match.group(1)
        return f'"{default}"' if default == "" else default

    text = re.sub(r"\$\{env\.[^:}]+:=([^}]*)\}", _replace_default, text)
    text = re.sub(r"\$\{env\.[^:}]+:\+([^}]*)\}", r'"\1"', text)
    return text


def _get_dependencies(ogx_bin: Path) -> list[str]:
    """Execute the ogx list-deps command and return a list of package specifiers."""
    build_yaml = Path("build/build.yaml")
    resolved = _resolve_env_defaults(build_yaml.read_text())
    with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as tmp:
        tmp.write(resolved)
        tmp_path = tmp.name
    try:
        result = _run([str(ogx_bin), "stack", "list-deps", tmp_path])
    finally:
        os.unlink(tmp_path)

    packages = []
    for line in result.stdout.splitlines():
        parts = iter(shlex.split(line))
        for part in parts:
            match part:
                # stripped because base images either already add the torch index as an extra index url, or include torch builds in the default index
                case "--extra-index-url" | "--index-url":
                    next(parts, None)
                # stripped because base images already provide the correct torch build, so sentence-transformers can safely resolve its dependencies without this guard
                case "--no-deps":
                    continue
                case _:
                    packages.append(part)

    return packages


def _get_opentelemetry_packages(bootstrap_bin: Path) -> list[str]:
    """Run opentelemetry-bootstrap to discover instrumentation packages."""
    result = _run([str(bootstrap_bin), "-a", "requirements"])
    packages = []
    for line in result.stdout.splitlines():
        line = line.strip()
        if line and not any(
            pkg in line
            for pkg in (
                "opentelemetry-instrumentation-botocore",
                "opentelemetry-instrumentation-exceptions",
                "opentelemetry-instrumentation-system-metrics",
            )
        ):
            packages.append(line)
    return packages


def _compile_lockfile(
    requirements_path: Path,
    output_path: Path,
    index_config: IndexConfig,
) -> None:
    """Run uv pip compile to produce a pinned lock file with hashes."""
    cmd = [
        "uv",
        "pip",
        "compile",
        "--constraint",
        str(Path("distribution/constraints.txt")),
        "--python-platform",
        "linux",
        "--python-version",
        "3.12",
        "--generate-hashes",
        "--config-file",
        "/dev/null",
        "--default-index",
        index_config.index_url,
        "--emit-index-url",
        str(requirements_path),
        "-o",
        str(output_path),
    ]
    if index_config.torch_backend:
        cmd.extend(["--torch-backend", index_config.torch_backend])

    output_path.unlink(missing_ok=True)
    _run(cmd)

    print(f"Successfully generated {output_path}")


def _build_requirements(
    dependencies: list[str],
    ogx_reqs: OgxRequirements,
    otel_packages: list[str],
) -> list[str]:
    """Combine all package specifiers into a sorted requirements list."""
    all_packages = sorted(set(dependencies + otel_packages))
    return [*ogx_reqs, *all_packages]


def _write_temp_requirements(lines: list[str]) -> Path:
    """Write package lines to a temporary requirements file. Caller must clean up."""
    path = Path(tempfile.gettempdir()) / "requirements.txt"
    path.write_text("\n".join(lines) + "\n")
    return path


def _get_lockfile_targets(
    install_from_source: bool, rhai_index_url: str | None
) -> dict[LockfileType, LockfileConfig]:
    """Determine which lock files to generate based on build configuration."""
    targets = {}
    if install_from_source:
        targets[LockfileType.MIDSTREAM] = LockfileConfig(
            Path("distribution/requirements-lock.txt"),
            IndexConfig(
                index_url="https://pypi.org/simple",
                torch_backend="cpu",
            ),
        )
    if rhai_index_url:
        targets[LockfileType.DOWNSTREAM] = LockfileConfig(
            Path("distribution/requirements-lock-konflux.txt"),
            IndexConfig(index_url=rhai_index_url),
        )
    if not targets:
        print(
            "Error: OGX_INSTALL_FROM_SOURCE=false and RHAI_INDEX_URL is not set. "
            "At least one lock file target is required."
        )
        sys.exit(1)
    return targets


def main():
    if sys.platform != "linux":
        print(
            "Error: gen_lockfile.py must run on Linux (platform-specific wheel resolution).\n"
            "On macOS/Windows, run via the container wrapper: ./build/run_gen_lockfile.sh"
        )
        sys.exit(1)

    config = BuildConfig()
    ogx_reqs = _get_ogx_requirements(config.ogx_version, config.ogx_install_from_source)
    targets = _get_lockfile_targets(
        config.ogx_install_from_source, config.rhai_index_url
    )

    for name, target in targets.items():
        print(f"Generating {target.output_path}...")

        print("  Getting dependencies...")
        with _build_venv([*ogx_reqs], target.index_config) as venv:
            dependencies = _get_dependencies(venv / "bin" / "ogx")

        # Temporary: RHAI index doesn't have all markitdown[all] extras deps
        if name == LockfileType.DOWNSTREAM:
            dependencies = [
                re.sub(r"^markitdown\[.*\]", "markitdown", d) for d in dependencies
            ]

        print("  Discovering opentelemetry instrumentation packages...")
        with _build_venv(
            [*ogx_reqs] + dependencies,
            target.index_config,
            constraints=Path("distribution/constraints.txt"),
        ) as venv:
            otel_packages = _get_opentelemetry_packages(
                venv / "bin" / "opentelemetry-bootstrap"
            )

        requirements = _build_requirements(dependencies, ogx_reqs, otel_packages)

        print("  Compiling lock file...")
        tmp_path = _write_temp_requirements(requirements)
        try:
            _compile_lockfile(tmp_path, target.output_path, target.index_config)
        finally:
            os.unlink(tmp_path)


if __name__ == "__main__":
    main()
