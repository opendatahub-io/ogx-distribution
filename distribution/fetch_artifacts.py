# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "httpx>=0.28,<1",
#   "pyyaml>=6,<7",
# ]
# ///
"""Download artifacts defined in artifacts.lock.yaml with checksum verification."""

import asyncio
import hashlib
import sys
from pathlib import Path

import httpx
import yaml

MAX_CONCURRENT_DOWNLOADS = 8
DOWNLOAD_TIMEOUT_S = 180
CHUNK_SIZE = 256 * 1024


async def download_artifact(
    client: httpx.AsyncClient,
    url: str,
    expected_sha256: str,
    dest: Path,
    semaphore: asyncio.Semaphore,
) -> None:
    async with semaphore:
        if dest.exists():
            sha = hashlib.sha256(dest.read_bytes()).hexdigest()
            if sha == expected_sha256:
                print(f"Skipping {dest.name} (cached)")
                return

        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp = dest.with_suffix(dest.suffix + ".tmp")
        print(f"Downloading {dest.name}...")
        async with client.stream("GET", url, follow_redirects=True) as resp:
            resp.raise_for_status()
            sha = hashlib.sha256()
            with tmp.open("wb") as f:
                async for chunk in resp.aiter_bytes(chunk_size=CHUNK_SIZE):
                    f.write(chunk)
                    sha.update(chunk)
        actual = sha.hexdigest()
        if actual != expected_sha256:
            tmp.unlink(missing_ok=True)
            raise RuntimeError(
                f"Checksum mismatch for {dest.name}: "
                f"expected {expected_sha256}, got {actual}"
            )
        tmp.rename(dest)


async def main(lock_file: Path, output_dir: Path) -> None:
    lock = yaml.safe_load(lock_file.read_text())

    artifacts = lock["artifacts"]
    print(f"Fetching {len(artifacts)} artifacts to {output_dir}")

    # Reject absolute paths and traversal attempts in artifact filenames.
    resolved_output = output_dir.resolve()
    for a in artifacts:
        filename = a["filename"]
        if Path(filename).is_absolute() or ".." in Path(filename).parts:
            raise ValueError(f"Invalid artifact filename: {filename}")
        dest = (output_dir / filename).resolve()
        if not dest.is_relative_to(resolved_output):
            raise ValueError(f"Artifact path escapes output dir: {filename}")

    semaphore = asyncio.Semaphore(MAX_CONCURRENT_DOWNLOADS)
    async with httpx.AsyncClient(timeout=DOWNLOAD_TIMEOUT_S) as client:
        tasks = [
            download_artifact(
                client,
                a["download_url"],
                a["checksum"].removeprefix("sha256:"),
                output_dir / a["filename"],
                semaphore,
            )
            for a in artifacts
        ]
        await asyncio.gather(*tasks)

    print("All artifacts verified.")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <lock-file> <output-dir>", file=sys.stderr)
        sys.exit(2)
    asyncio.run(main(Path(sys.argv[1]), Path(sys.argv[2])))
