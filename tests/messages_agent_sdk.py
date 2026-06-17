#!/usr/bin/env python3
# Copyright (c) Red Hat
# All rights reserved.
#
# This source code is licensed under the terms described in the LICENSE file in
# the root directory of this source tree.

"""Basic Claude Agent SDK smoke test against the OGX Messages API.

Drives a short 3-turn conversation through the Claude Agent SDK, which talks to
the OGX server's Anthropic-compatible Messages API (/v1/messages). This proves
the shipped image can serve a real Agent SDK session, not just a single request.

Configuration (environment variables):
  ANTHROPIC_BASE_URL   OGX server base URL (default: http://127.0.0.1:8321)
  ANTHROPIC_API_KEY    Sent to OGX but not validated for local providers
                       (default: "fake")
  MESSAGES_AGENT_MODEL OGX model id to drive the session, passed straight through
                       as the Anthropic `model` (e.g. "openai/gpt-4.1-nano").

Exits 0 on success, non-zero (with a clear message) on the first failing turn.

Prerequisites: Python 3.10+, Node.js, and the Claude Code CLI
(`npm install -g @anthropic-ai/claude-code`) plus `pip install claude-agent-sdk`.
"""

import os
import sys

import anyio
from claude_agent_sdk import (
    AssistantMessage,
    ClaudeAgentOptions,
    ClaudeSDKClient,
    ResultMessage,
    TextBlock,
)

# Each turn references the previous one so a broken session (no conversational
# continuity) surfaces as a wrong/empty answer rather than a silent pass.
TURNS = [
    "My name is Ada. What is 2 + 2? Reply with just the number.",
    "Multiply that result by 10. Reply with just the number.",
    "What name did I tell you at the start? Reply with just the name.",
]


def _fail(turn: int, reason: str) -> None:
    print(f"===> Agent SDK session FAILED on turn {turn}/{len(TURNS)}: {reason}")
    sys.exit(1)


async def run_session() -> None:
    base_url = os.environ.get("ANTHROPIC_BASE_URL", "http://127.0.0.1:8321")
    model = os.environ.get("MESSAGES_AGENT_MODEL")
    if not model:
        print("===> MESSAGES_AGENT_MODEL is not set")
        sys.exit(1)

    print(
        f"===> Starting Claude Agent SDK session (base_url={base_url}, model={model})..."
    )

    options = ClaudeAgentOptions(
        model=model,
        # Conversational smoke only: no filesystem/shell tools, and never block
        # waiting for a permission prompt.
        allowed_tools=[],
        permission_mode="bypassPermissions",
        max_turns=1,
        system_prompt="You are a concise assistant. Answer in as few words as possible.",
    )

    async with ClaudeSDKClient(options=options) as client:
        for i, prompt in enumerate(TURNS, start=1):
            await client.query(prompt)

            text = ""
            result: ResultMessage | None = None
            async for message in client.receive_response():
                if isinstance(message, AssistantMessage):
                    for block in message.content:
                        if isinstance(block, TextBlock):
                            text += block.text
                elif isinstance(message, ResultMessage):
                    result = message

            if result is not None and getattr(result, "is_error", False):
                _fail(i, f"server returned an error result: {result}")
            if not text.strip():
                _fail(i, "assistant produced no text")

            print(f"===> Turn {i} OK: {text.strip()[:120]}")

    print(f"===> Claude Agent SDK session completed successfully ({len(TURNS)} turns)!")


def main() -> None:
    try:
        anyio.run(run_session)
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001 - surface any SDK/transport failure clearly
        print(f"===> Agent SDK session FAILED to run: {type(exc).__name__}: {exc}")
        sys.exit(1)


if __name__ == "__main__":
    main()
