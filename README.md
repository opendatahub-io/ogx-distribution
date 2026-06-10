# Open Data Hub OGX Distribution

[![Build](https://github.com/opendatahub-io/ogx-distribution/actions/workflows/redhat-distro-container.yml/badge.svg?branch=main)](https://github.com/opendatahub-io/ogx-distribution/actions/workflows/redhat-distro-container.yml)

This directory contains the necessary files to build an Open Data Hub-compatible container image for [OGX](https://github.com/ogx-ai/ogx).

To learn more about the distribution image content, see the [README](distribution/README.md) in the `distribution/` directory.

## Build Instructions

### Prerequisites

- The `pre-commit` tool is [installed](https://pre-commit.com/#install)

### Generating the Containerfile

The Containerfile is auto-generated from a template. To generate it:

```
pre-commit run --all-files
```

This will:
- Install the dependencies (ogx etc) in a virtual environment
- Execute the build script `./distribution/build.py`

The build script will:
- Execute the `ogx` CLI to generate the dependencies
- Create a new `Containerfile` with the required dependencies

### Editing the Containerfile

The Containerfile is auto-generated from a template. To edit it, you can modify the template in `distribution/Containerfile.in` and run pre-commit again.

> [!WARNING]
> *NEVER* edit the generated `Containerfile` manually.

## Run Instructions

> [!TIP]
> Ensure you include any env vars you might need for providers in the container env - you can read more about that [here](distribution/README.md).

```bash
podman run -p 8321:8321 quay.io/opendatahub/odh-ogx-core:<tag>
```

### What image tag should I use?

Various tags are maintained for this image:

- `latest` will always point to the latest image that has been built off of a merge to the `main` branch
  - You can also pull an older image built off of `main` by using the SHA of the merge commit as the tag
- `rhoai-v*-latest` will always point to the latest image that has been built off of a merge to the corresponding `rhoai-v*` branch

You can see the source code that implements this build strategy [here](.github/workflows/redhat-distro-container.yml)

### Running with a custom run YAML

The distribution image allows you to run a custom run YAML file within it. To do so, run the image in the following way. The "path" mentioned should be the path to your custom run YAML file.

```bash
podman run \
  -p 8321:8321 \
  -v <path_on_host>:<path_in_container> \
  -e RUN_CONFIG_PATH=<path_in_container> \
  quay.io/opendatahub/odh-ogx-core:<tag>
```

> [!IMPORTANT]
> The distribution image ships with various dependencies already pre-installed. There is *no* guarantee that your custom run YAML will necessarily work with the included dependencies.

> [!NOTE]
> The container image includes pre-installed dependencies for more providers than are present in the default runtime configuration (`config.yaml`). Providers such as `inline::sentence-transformers`, `inline::milvus`, and `inline::faiss` are available as dependencies but are stripped from the default `config.yaml`. The full provider manifest is maintained in `build.yaml`. To use these dependency-only providers, pass a custom `config.yaml` at runtime (as shown above) that includes the desired provider definitions. See the [distribution README](distribution/README.md) for which providers are dependency-only.

## ARM64 Support

The distribution image supports both amd64 and arm64 architectures. CI runs the full test suite (build, smoke tests, and integration tests) on both architectures using multi-arch vLLM CPU images. When MaaS (Model-as-a-Service) endpoints are configured, they override the local vLLM containers on both architectures.

## Slack Build Notifications

Slack notifications are sent on successful image push (`push`/`workflow_dispatch`) and on build failures.

### Configuration

Add a repository secret (**Settings → Secrets and variables → Actions → New repository secret**):
- **Name:** `WH_SLACK_TEAM_LLS_CORE`
- **Value:** Slack webhook URL (e.g., `https://hooks.slack.com/services/...`)

To notify multiple channels, use comma-separated webhook URLs in `SLACK_WEBHOOK_URLS`.

### Local Testing

Preview the message format without sending:
```bash
IMAGE_NAME=quay.io/opendatahub/odh-ogx-core IMAGE_TAG=abc123 COMMIT_SHA=abc1234567890 \
  WORKFLOW_URL=https://github.com/... .github/actions/notify-slack/notify.sh --preview
```
