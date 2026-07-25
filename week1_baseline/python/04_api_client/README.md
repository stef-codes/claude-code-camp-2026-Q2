# 04 · The API Client (Python port)

Python port of [`ruby/04_api_client`](../../ruby/04_api_client/README.md).
Built on top of the [`03_prompt_builder`](../03_prompt_builder/README.md) port.

The API Client takes the payload assembled by `PromptBuilder` and sends it
to the API. One HTTP POST, one response — no tool loop yet, just proving the
round trip works.

## New Files

| File | Purpose |
|------|---------|
| `boukensha/client.py` | Makes the HTTP request and parses the response |

## Updated Files

| File | Change |
|------|--------|
| `boukensha/errors.py` | Added `ApiError` for failed HTTP requests |
| `boukensha/config.py` | Reads `tasks.player` instead of top-level provider/model settings |
| `boukensha/backends/*.py` | Backends now own supported model tables with context windows and cost metadata |

## How It Works

```
PromptBuilder
      ↓
Client
      ↓
POST to API endpoint
      ↓
Raw JSON response
```

## `boukensha.Client`

| Method | Description |
|--------|-------------|
| `call(*, max_output_tokens=1024, tools=None)` | POSTs the payload and returns the parsed JSON response |

## No Dependencies

`Client` uses only Python's standard library (`urllib.request`, `ssl`,
`socket`, `http.client`). No third-party HTTP library — the HTTP call itself
is trivial and should be visible, not hidden behind a library.

## What the Response Looks Like

The raw response shape differs between backends. This is what
`client.call()` returns before any processing:

### Anthropic
```json
{
  "id": "msg_01XY",
  "type": "message",
  "role": "assistant",
  "content": [{"type": "text", "text": "Sure, let me read that file."}],
  "stop_reason": "end_turn",
  "usage": {"input_tokens": 42, "output_tokens": 18}
}
```

### Ollama
```json
{
  "model": "llama3.2",
  "message": {"role": "assistant", "content": "Sure, let me read that file."},
  "done_reason": "stop",
  "done": true
}
```

When the model wants to call a tool the response looks different: Anthropic
uses `stop_reason: "tool_use"` and adds a `tool_use` block to `content`;
Ollama adds a `tool_calls` array to `message`. Handling those differences is
the job of step 5 — the Agent Loop.

## Considerations

**The client raises `ApiError` on failure.** A non-2xx response — bad API
key, malformed payload, server error — surfaces explicitly rather than
returning a confusing `None` or partial response, and is retried with
exponential backoff for transient/retryable failures first (see
`Client.RETRYABLE_STATUS_CODES` / `Client.TRANSIENT_ERRORS`).

**SSL is handled automatically.** `Client` enables SSL for `https` endpoints
via the platform's default trust store; Ollama running locally uses plain
`http`, so no SSL is needed there.

## Run Example

```bash
./week1_baseline/bin/python/04_api_client
```

## Differences from Ruby

- **Retry/backoff logic lives in one `Client` class using `urllib.request`
  directly**, rather than Ruby's `net/http`; the retryable-status-code set
  and transient-error set are ported 1:1 (`408/409/429/500/502/503/504`,
  3 retries, exponential backoff from 0.5s).
- Carries forward the standing decisions from earlier steps: `.yaml`/`.yml`
  fallback fix (Python-side only), no pytest suite, `uv`/hatchling,
  `requires-python >=3.14`.
