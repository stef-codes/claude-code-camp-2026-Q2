# 05 · The Agent Loop (Python port)

Python port of [`ruby/05_agent_loop`](../../ruby/05_agent_loop/README.md).
Built on top of the [`04_api_client`](../04_api_client/README.md) port.

The Agent Loop is the heart of BOUKENSHA. Everything built before this — the
structs, the registry, the prompt builder, the client — was setup. The loop
is where the agent actually does work.

## New Files

| File | Purpose |
|------|---------|
| `boukensha/agent.py` | The agent loop — sends requests, dispatches tools, and knows when to stop |
| `boukensha/backends/openai.py` | OpenAI Chat Completions backend |
| `boukensha/backends/gemini.py` | Google Gemini backend |
| `boukensha/backends/ollama_cloud.py` | Ollama Cloud backend (hosted Ollama, authenticated with an API key) |

## Updated Files

| File | Change |
|------|--------|
| `boukensha/errors.py` | Added `LoopError` for runaway agents |
| `boukensha/context.py` | Carries the active task object alongside messages and tools |
| `boukensha/prompt_builder.py` | Added `parse_response()`, delegating to the backend |
| `boukensha/backends/anthropic.py` | Model configurable/validated via backend-owned metadata; added `parse_response()` |
| `boukensha/backends/ollama.py` | Model configurable/validated; added `parse_response()` and `_assistant_message()` |

## How It Works

```
send messages to API
        ↓
stop_reason == "tool_use"?
    yes → extract tool calls
        → dispatch each tool via Registry
        → inject results as tool_result messages
        → go back to top
    no  → return final text response
```

## `boukensha.Agent`

| Method | Description |
|--------|-------------|
| `run()` | Starts the loop and returns the final text response when the agent is done |

## Every Backend Speaks the Same Normalized Shape

Five providers means five different response formats — Anthropic nests tool
calls inside `content`, Ollama puts them in `message["tool_calls"]`, OpenAI
nests them under `choices[0]["message"]["tool_calls"]`, and Gemini calls
them `functionCall` parts. Rather than teach the Agent loop about each of
these, every backend implements `parse_response()`, converting its raw
response into one common shape:

```python
{
    "stop_reason": "tool_use" | "end_turn",
    "content": [
        {"type": "text", "text": "..."},
        {"type": "tool_use", "id": "...", "name": "...", "input": {...}},
    ],
}
```

`Agent` only ever sees this shape — it calls `self.builder.parse_response(response)`,
which delegates to the backend, and never inspects a raw provider response.

The conversion also runs in reverse: when conversation history is replayed
on the next request, Ollama, Ollama Cloud, OpenAI, and Gemini each rebuild a
provider-specific assistant message from the normalized `content` blocks via
a private `_assistant_message()`/`_assistant_parts()` method — the inverse
of `parse_response()`. Anthropic's `content` list doubles as both the
normalized shape and the wire format, so it needs no extra conversion.

**Tool call IDs aren't universal.** Anthropic and OpenAI assign every tool
call a unique `id`, echoed back in the `tool_result`. Ollama, Ollama Cloud,
and Gemini don't assign call ids at all — those backends reuse the tool's
`name` as its `id` and match the `tool_result` back to the call by name.

## Task Configuration

```yaml
tasks:
  player:
    provider: anthropic
    model: claude-haiku-4-5
    prompt_override:
      system: true
    max_iterations: 25
    max_output_tokens: 1024
```

`max_iterations` controls model round-trips per turn before wind-down;
`max_output_tokens` is passed to each model reply.

| Provider | Backend | Requires |
|---|---|---|
| `anthropic` | `backends.Anthropic` | `ANTHROPIC_API_KEY` |
| `openai` | `backends.OpenAI` | `OPENAI_API_KEY` |
| `gemini` | `backends.Gemini` | `GEMINI_API_KEY` |
| `ollama` | `backends.Ollama` | a local Ollama server (`host` defaults to `http://localhost:11434`) |
| `ollama_cloud` | `backends.OllamaCloud` | `OLLAMA_API_KEY` |

## Considerations

**The assistant message must be stored before the tool result.** The
Anthropic API requires the assistant's `tool_use` block to appear in the
message history before its corresponding `tool_result` — get the order
wrong and the API rejects the request. `Agent._handle_tool_calls()` handles
this ordering.

**The model can call multiple tools in one turn.** The loop iterates over
every `tool_use` block in a single response before making the next API call.

**`MAX_ITERATIONS` is a turn ceiling.** A poorly prompted agent can loop
forever if the model keeps calling tools. BOUKENSHA stops starting new work
after 25 iterations by default and makes one short wrap-up call with tools
disabled — bounding the turn while still returning a useful final response.

**The agent has no way to stop itself.** The model signals it is done via
`stop_reason: "end_turn"`. BOUKENSHA watches for that signal and exits the
loop; the agent never decides unilaterally to stop.

## Run Example

```bash
./week1_baseline/bin/python/05_agent_loop
```

## Differences from Ruby

- **Truncation lengths use Python slicing (`[:41]`/`[:61]`)**, the
  equivalent of Ruby's inclusive `[0..40]`/`[0..60]` ranges — both keep 41
  and 61 characters respectively.
- Carries forward the standing decisions from earlier steps: `.yaml`/`.yml`
  fallback fix (Python-side only), no pytest suite, `uv`/hatchling,
  `requires-python >=3.14`.
