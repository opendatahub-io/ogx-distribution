# AWS Bedrock walkthrough guide

*Note: This walkthrough does not use OGX. It explains how to use AWS Bedrock’s REST API directly with `curl`, using your own Bearer token. [OGX’s Bedrock provider](https://ogx-ai.github.io/en/latest/providers/inference/remote_bedrock.html) will abstract most of these steps away. The purpose of this document is to provide lower-level debugging steps to understand and verify behavior outside of OGX. For example, sometimes Amazon does not make Bedrock features available in all regions.*

1. Log into the AWS web console ([Red Hat-only SSO link](https://auth.redhat.com/auth/realms/EmployeeIDP/protocol/saml/clients/itaws))
2. Go to [https://console.aws.amazon.com/bedrock/](https://console.aws.amazon.com/bedrock/)
3. Generate a short-term (12h) API key. (Note the region, for example `us-west-2`) ([AWS docs about this](https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys-generate.html)).
4. On the terminal:
   ```shell
   export AWS_BEARER_TOKEN_BEDROCK=bedrock-api-key-ABCdef123…
   ```

# OpenAI API compatibility

You can use your bearer token with AWS Bedrock's OpenAI chat completions API ([docs](https://docs.aws.amazon.com/bedrock/latest/userguide/inference-chat-completions.html)). As of October 2025, AWS **only supports this API with `openai.gpt-oss` models, which are only available in `us-west-2`**. AWS may change this in the future.

```shell
curl -X POST https://bedrock-runtime.us-west-2.amazonaws.com/openai/v1/chat/completions \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $AWS_BEARER_TOKEN_BEDROCK" \
    -d '{
    "model": "openai.gpt-oss-20b-1:0",
    "messages": [
        {
            "role": "developer",
            "content": "You are a helpful assistant."
        },
        {
            "role": "user",
            "content": "Hello!"
        }
    ]
}'
```

# AWS Bedrock's own API

OGX does [not](https://github.com/llamastack/llama-stack/pull/3748) use this API. (`boto3` does, [docs](https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-meta.html).)

You can use your bearer token with AWS Bedrock's proprietary `/converse` API ([doc](https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys-use.html)).
(The region in this URL must match the region where you generated the Bearer token above.)

```shell
curl -X POST "https://bedrock-runtime.us-east-2.amazonaws.com/model/us.meta.llama3-1-8b-instruct-v1:0/converse" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $AWS_BEARER_TOKEN_BEDROCK" \
    -d '{
    "messages": [
        {
            "role": "user",
            "content": [{"text": "Hello"}]
        }
    ]
  }'
```

# Selecting a model

1. Ensure there is an [inference profile](https://us-east-2.console.aws.amazon.com/bedrock/home?region=us-east-2#/inference-profiles) for the model ([example](https://us-east-2.console.aws.amazon.com/bedrock/home?region=us-east-2#/inference-profiles/us.meta.llama3-1-8b-instruct-v1:0): `us.meta.llama3-1-8b-instruct-v1:0`)
2. Use that inference profile in your API calls.

# Using `invoke-model`

You can use the `aws` CLI with the `invoke-model` command ([docs](https://docs.aws.amazon.com/bedrock/latest/userguide/inference-invoke.html)):

```shell
aws bedrock-runtime invoke-model \
    --model-id us.meta.llama3-1-8b-instruct-v1:0 \
    --region us-east-2 \
    --cli-binary-format raw-in-base64-out \
    --body '{"prompt":"hello, how are you?","max_gen_len":10,"temperature":0.2,"top_p":0.9}' response.json

cat response.json
{"generation":" I'm doing great, thanks for asking! I","prompt_token_count":7,"generation_token_count":10,"stop_reason":"length"}
```

Oct 2025: The [inference profile for us.meta.llama3-1-8b-instruct-v1:0](https://us-east-2.console.aws.amazon.com/bedrock/home?region=us-east-2#/inference-profiles/us.meta.llama3-1-8b-instruct-v1:0) says it's available in `us-east-1`, `us-east-2`, and `us-west-2`, but I get `AccessDeniedException` unless I'm using `us-east-2`.
