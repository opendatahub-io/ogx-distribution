# Copyright (c) Red Hat
# SPDX-License-Identifier: Apache-2.0
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent


def _run(command: list[str], env: dict[str, str] | None = None) -> None:
    subprocess.run(command, check=True, env=env)  # noqa: S603 (locally constructed argv, no shell)


def build(
    output: Path,
    source_repo: str = "https://github.com/nltk/nltk.git",
    offline: bool = False,
) -> Path:
    config = json.loads((HERE / "package.json").read_text())
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    wheels = output / "wheels"
    wheels.mkdir(exist_ok=True)
    if offline and not Path(source_repo).is_dir():
        raise ValueError("Failed to build NLTK offline: provide a local --source-repo")
    with tempfile.TemporaryDirectory(prefix="source-", dir=output) as temporary:
        work = Path(temporary)
        source = work / "source"
        _run(["git", "init", "--quiet", str(source)])
        _run(
            [
                "git",
                "-C",
                str(source),
                "fetch",
                "--quiet",
                "--depth=1",
                source_repo,
                config["base_commit"],
            ]
        )
        _run(
            [
                "git",
                "-C",
                str(source),
                "-c",
                "core.autocrlf=false",
                "checkout",
                "--quiet",
                "--detach",
                "FETCH_HEAD",
            ]
        )
        version_file = source / "nltk/VERSION"
        if version_file.read_text().strip() != config["base_version"]:
            raise ValueError(
                "Failed to build NLTK: base version does not match pinned source"
            )
        patch = HERE / "model-artifacts.patch"
        if hashlib.sha256(patch.read_bytes()).hexdigest() != config["patch_sha256"]:
            raise ValueError("Failed to build NLTK: patch checksum mismatch")
        _run(["git", "-C", str(source), "apply", "--check", str(patch)])
        _run(["git", "-C", str(source), "apply", str(patch)])
        version_file.write_text(config["version"] + "\n")
        command = [
            "uv",
            "build",
            "--wheel",
            "--python",
            sys.executable,
            "--build-constraints",
            str(HERE / "build-constraints.txt"),
            "--out-dir",
            str(work / "dist"),
            str(source),
        ]
        if offline:
            command.append("--offline")
        environment = dict(
            os.environ, SOURCE_DATE_EPOCH="946684800", PYTHONHASHSEED="0"
        )
        _run(command, env=environment)
        built = list((work / "dist").glob("*.whl"))
        if len(built) != 1:
            raise ValueError("Failed to build NLTK: expected one wheel")
        destination = wheels / built[0].name
        # Stored entries avoid platform-dependent zlib output in lock hashes.
        with (
            zipfile.ZipFile(built[0]) as original,
            zipfile.ZipFile(destination, "w") as archive,
        ):
            for name in sorted(original.namelist()):
                info = zipfile.ZipInfo(name, (2000, 1, 1, 0, 0, 0))
                info.external_attr = 0o100644 << 16
                archive.writestr(info, original.read(name))
    (output / "constraints.txt").write_text(f"nltk @ {destination.as_uri()}\n")
    (output / "manifest.json").write_text(
        json.dumps(
            {
                **config,
                "wheel": destination.name,
                "wheel_sha256": hashlib.sha256(destination.read_bytes()).hexdigest(),
            },
            indent=2,
        )
        + "\n"
    )
    return destination


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build the pinned NLTK CVE backport for dependency resolution and images"
    )
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--source-repo", default="https://github.com/nltk/nltk.git")
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()
    print(build(args.output_dir, args.source_repo, args.offline))


if __name__ == "__main__":
    main()
