# 06 · The Logger (Python port)

Python port of [`ruby/06_the_logger`](../../ruby/06_the_logger/README.md).
Built on top of the [`05_agent_loop`](../05_agent_loop/README.md) port.

`boukensha.Logger` records each agent run as structured JSON Lines. It's a
file logger, not user-facing display output.

## New Files

| File | Purpose |
|------|---------|
| `boukensha/logger.py` | `Logger` — writes structured JSONL events per session |

## Updated Files

| File | Change |
|------|--------|
| `boukensha/__init__.py` | Module-level state: `config()`, `enable_quiet()`/`disable_quiet()`/`is_quiet()`, `enable_debug()`/`is_debug()` |
| `boukensha/config.py` | Dropped `mud_*` helpers (not present in this Ruby version) |

## Session Logs

Each `Logger` instance creates a session id and writes one log file for that
session:

```
.boukensha/sessions/<session-id>.jsonl
```

Every line is a complete JSON object with `session_id`, `at`, and `phase`
fields, plus phase-specific data — grep/tail friendly and machine readable.

```json
{"phase": "session_start", "session_id": "20260528T143011Z-a1b2c3d4", "at": "2026-05-28T10:30:11-04:00"}
{"phase": "iteration", "n": 1, "session_id": "20260528T143011Z-a1b2c3d4", "at": "2026-05-28T10:30:11-04:00"}
```

Model response lines include the active task, provider, model, normalized
token counts, and estimated USD cost when the backend has token pricing
data:

```json
{"phase": "response", "task": "player", "provider": "anthropic", "model": "claude-haiku-4-5", "input_tokens": 1000, "output_tokens": 100, "cost_usd": 0.0015}
```

## Logger API

| Method | Phase | Logs |
|--------|-------|------|
| `iteration(*, n, max)` | `iteration` | loop counter |
| `prompt(*, messages, tools)` | `prompt` | messages, tools |
| `tool_call(*, name, args)` | `tool_call` | tool name and arguments |
| `tool_result(*, name, result, ok=True, error=None)` | `tool_result` | tool result |
| `response(*, text, usage=None, stop_reason=None, task=None, backend=None)` | `response` | response text, token usage, task/provider/model, estimated cost |
| `raw(*, data)` | `raw` | raw provider response, only when `boukensha.is_debug()` |

```python
logger = boukensha.Logger()
agent = boukensha.Agent(context=ctx, registry=registry, builder=builder, client=client, logger=logger)
```

You can also provide a session id or override the destination directory:

```python
boukensha.Logger(session_id="manual-session")
boukensha.Logger(dir="/tmp/boukensha-sessions")
```

For compatibility, `log=` still accepts an explicit file path, but normal
iteration usage should write under `.boukensha/sessions`.

## Debug Events

Call `boukensha.enable_debug()` before running the agent to include raw
provider responses in the log:

```python
boukensha.enable_debug()
```

## Run Example

```bash
./week1_baseline/bin/python/06_the_logger
```

## Differences from Ruby

- **Module-level state is a plain dict** (`_state = {"quiet": ..., "debug": ..., "config": ...}`)
  rather than Ruby's `@quiet`/`@debug`/`@config` class instance variables on
  the `Boukensha` module — same semantics, idiomatic Python storage.
- Carries forward the standing decisions from earlier steps: `.yaml`/`.yml`
  fallback fix (Python-side only), no pytest suite, `uv`/hatchling,
  `requires-python >=3.14`.
