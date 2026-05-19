# Google AI providers walkthrough

This document explains how to develop and test against Google's AI providers: [Vertex AI](https://ogx-ai.github.io/docs/next/providers/inference/remote_vertexai) and [Gemini](https://ogx-ai.github.io/docs/next/providers/inference/remote_gemini).

The purpose of this document is to provide lower-level debugging steps to understand and verify Vertex & Gemini behavior inside and outside of OGX.

## Authentication with gcloud

The [`gcloud` CLI](https://docs.cloud.google.com/sdk/docs/install-sdk) will write to `~/.config/gcloud` by default. Google's SDK (and OGX) will also read from this location by default. You can force the SDK to read the ADC (`application_default_credentials.json`) from another path with `$GOOGLE_APPLICATION_CREDENTIALS`.

For this demo, we will write OGX's credentials to a *temporary location*, using the `CLOUDSDK_CONFIG` variable. This will avoid clobbering any existing login settings in `~/.config/gcloud` so that you do not disrupt other Vertex-enabled applications you might have on your computer (like Claude Code).

```bash
export CLOUDSDK_CONFIG="/tmp/gcloud"

# When prompted, "Enter a project ID". For ODH OGX core developers, type "aaet-dev".
gcloud init

# Create application_default_credentials.json (ADC) for Vertex AI:
gcloud auth application-default login
```

## Vertex OpenAI API example without OGX

To make a simple OpenAI chat completion request (apart from OGX):

```bash
export CLOUDSDK_CONFIG="/tmp/gcloud"

# Choose "aaet-dev" if you are on the core OGX team.
VERTEX_AI_PROJECT=aaet-dev

curl -X POST \
  -H "Authorization: Bearer $(gcloud auth application-default print-access-token)" \
  -H "Content-Type: application/json" \
  "https://aiplatform.googleapis.com/v1beta1/projects/${VERTEX_AI_PROJECT}/locations/global/endpoints/openapi/chat/completions" \
  -d '{
        "model": "google/gemini-2.5-flash",
        "messages": [
          {
            "role": "system",
            "content": "You are a helpful assistant."
          },
          {
            "role": "user",
            "content": "Hello! Can you tell me a joke?"
          }
        ],
        "temperature": 1.0,
        "max_tokens": 256
      }'
```

## OGX from Git example

Run the `starter` distribution from Git. When you set `VERTEX_AI_PROJECT`, OGX will activate the `vertexai` provider.

```bash
uv venv
. .venv/bin/activate
uv pip install -e .
# See https://github.com/llamastack/llama-stack/issues/4672 for improving this:
ogx stack list-deps starter | xargs -L1 uv pip install

# Choose "aaet-dev" if you are on the core OGX team.
export VERTEX_AI_PROJECT=aaet-dev
export GOOGLE_APPLICATION_CREDENTIALS=/tmp/gcloud/application_default_credentials.json
ogx run starter
```

## Vertex OpenAI API examples with OGX

Verify that OGX reports the `vertexai` provider's `google` models as available:

```bash
curl -H "Content-Type: application/json" "http://localhost:8321/v1/models" | jq
```

Make a chat completion request through OGX to Google Vertex:

```bash
curl -X POST \
  -H "Content-Type: application/json" \
  "http://localhost:8321/v1/chat/completions" \
  -d '{
        "model": "vertexai/google/gemini-2.5-flash",
        "messages": [
          {
            "role": "system",
            "content": "You are a helpful assistant."
          },
          {
            "role": "user",
            "content": "Hello! Can you tell me a joke?"
          }
        ],
        "temperature": 1.0,
        "max_tokens": 256
      }'
```

## Gemini examples

OGX has both a ["Gemini"](https://ogx-ai.github.io/docs/next/providers/inference/remote_gemini) and "Vertex AI" provider. They are completely different APIs. The Gemini provider uses the `GEMINI_API_KEY` env var.

There are multiple ways to acquire a Gemini API key. Many developers acquire a key with [Google's web UI](https://ai.google.dev/gemini-api/docs/api-key). In this walkthrough, we will use the `gcloud` CLI with single-sign-on to acquire a short-lived OAuth access token (and assign it to `GEMINI_API_KEY`).

### Testing Gemini REST API with curl

Again, use the temporary location for Google auth:

```bash
export CLOUDSDK_CONFIG="/tmp/gcloud"
```

Retrieve an Application Default Credential (ADC) that has the `generative-language.retriever` oauth scope. This will write to `/tmp/gcloud/application_default_credentials.json`.

```bash
gcloud auth application-default login --scopes='https://www.googleapis.com/auth/cloud-platform,https://www.googleapis.com/auth/generative-language.retriever'
```

Obtain a short-lived OAuth access token from this ADC and assign it to `GEMINI_API_KEY`:

```bash
GEMINI_API_KEY=$(gcloud auth application-default print-access-token)
```

Making a chat request:

```bash
# Choose "aaet-dev" if you are on the core OGX team.
GEMINI_AI_PROJECT=aaet-dev

curl "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $GEMINI_API_KEY" \
  -H "x-goog-user-project: $GEMINI_AI_PROJECT" \
  -X POST -d '{
    "contents": [
      {
        "parts": [
          {
            "text": "Explain how AI works in a few words"
          }
        ]
      }
    ]
  }'
```

### Troubleshooting Gemini API

For troubleshooting, verify the oauth scopes for your access token, like so:

```bash
$ curl https://oauth2.googleapis.com/tokeninfo?access_token=$GEMINI_API_KEY
{
  "azp": "764086051850-6qr4p6gpi6hn506pt8ejuq83di341hur.apps.googleusercontent.com",
  "aud": "764086051850-6qr4p6gpi6hn506pt8ejuq83di341hur.apps.googleusercontent.com",
  "scope": "https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/generative-language.retriever",
  "exp": "1769115259",
  "expires_in": "3412",
  "access_type": "offline"
}
```
