# NLTK CVE-2026-81726 backport

This package recipe applies the minimal model-artifact guard patch to the immutable upstream commit in `package.json`. It does not change tokenizer code or the existing pathsec policy. The patch checksum is verified before building.

The container builds the wheel before resolving runtime dependencies. Both pip and uv receive the resulting direct-wheel constraint, so no installer can select an unpatched registry release. CI builds it from public upstream source and the patch in this repository; no unpublished package, local `.cve-work` files, private checkout, or publication credentials are needed.

Build and test on Python 3.12:

```sh
wheel=$(uv run --no-project distribution/nltk/build.py --output-dir .nltk-build | tail -1)
uv run --no-project --with "$wheel" --with pytest --with pytest-socket --with 'numpy<3' -m pytest distribution/nltk/test_cve.py --confcutdir=distribution/nltk -c /dev/null --disable-socket --allow-unix-socket -q
```

Local offline builds can pass `--source-repo /path/to/nltk --offline`. Build dependencies are pinned in `build-constraints.txt`. Wheel entries have fixed timestamps and are stored without zlib compression to keep lock hashes reproducible across build hosts.

`.github/workflows/nltk-backport.yml` builds twice, compares manifests, and tests the installed wheel. Generated wheels, staging checkouts, and manifests stay under ignored `.nltk-build*/` directories, not in the PR.

The lock generator resolves the built wheel, then writes its direct reference using the container's `/opt/app-root/nltk/wheels/` location. For a scoped backport refresh, run `uv run build/gen_lockfile.py --nltk-only`. This checks NLTK's runtime dependencies against the existing pins and updates only the NLTK entry and hash in both lock variants. It does not re-resolve the full product graph or move application source tags. A new patch must update the patch hash and local version in `package.json`.
