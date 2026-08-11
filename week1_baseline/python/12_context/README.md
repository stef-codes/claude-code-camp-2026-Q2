# 12 · Context Management (Python port)

Python port of [`ruby/12_context`](../../ruby/12_context/README.md). Built on
top of the [`11_tui`](../11_tui/README.md) port — the Textual TUI, the MCP-host
tool model, and the REPL/Logger plumbing all carry forward unchanged except
where noted below.

When you call an LLM directly you are responsible for the context window.
There is no auto-compacting. This step adds proper token tracking, visual
warnings, and automatic compaction so the agent never silently blows past the
limit — on top of the MCP-host tool model and terminal UI carried forward
from earlier steps.

The standard tool library is **MCP**. Boukensha ships **no tools of its
own** — every tool the agent can call comes from an MCP server declared in
`settings.yaml`.

## What's new

### Accurate context tracking

`Context` now maintains two distinct token counts:

| Attribute | What it measures |
|-----------|-------------------|
| `context_window` | The model's maximum input token capacity, looked up from `models.context_window(model)` |
| `current_tokens` | Tokens actually used in the most recent API call (`usage["input_tokens"]` from the response) |

The `Agent` updates `current_tokens` after every API response (including
mid-turn tool-use calls), so the display always reflects what the next call
will actually send. `turn_tokens` is a separate, per-turn cumulative
input+output spend counter — the budget `max_turn_tokens` is checked against.

### `boukensha.models`

A static model → capability table built from every backend's own `MODELS`
dict, so `Context` can be sized correctly *before* a backend is constructed:

```python
from boukensha import models
models.context_window("gpt-5.5")  # => 1_000_000
```

Unknown models fall back to a conservative `DEFAULT_CONTEXT_WINDOW` (32,000)
rather than silently assuming a huge window.

### Context colour coding (TUI)

The progress and status lines colour the context indicator based on how full
the window is:

| Usage | Colour | Meaning |
|-------|--------|---------|
| < 70% | Grey | Normal |
| 70–84% | Yellow | Approaching limit |
| ≥ 85% | Red | Compaction imminent |

A `⚠` symbol also appears in the status bar at 85%+.

### Auto-compaction

At the start of each agent turn, if `current_tokens / context_window` is at
or above the configured `agent.compaction_threshold` (default `0.85`), the
`Agent` automatically compacts the context before making any API call:

```
[context compacted — 12 messages dropped to free space]
```

Compaction drops the oldest 40% of messages (keeping at least 2) and resets
`current_tokens` to 0. The first API call after compaction reports the true
new size.

### `Context.compact_messages()`

```python
dropped = context.compact_messages(target_fraction=0.60)
# => 12  (number of messages dropped)
```

### `/compact` command

Manual compaction from the REPL or TUI:

```
boukensha> /compact
(compacted context — 12 messages dropped)
```

### `Logger.compaction()` event

```json
{"phase": "compaction", "before": 172000, "dropped": 12, "context_window": 200000}
```

Emitted whenever auto- or manual compaction runs. The TUI subscribes to this
event to display the compaction notice in the conversation view.

### A second, independent circuit breaker: `max_turn_tokens`

`Agent` now stops a turn on whichever of two thresholds trips first: the
existing `max_iterations` (tool-call count) or `max_turn_tokens` (cumulative
input+output tokens spent this turn). Both read from `settings.yaml`'s
`agent:` block (`agent.max_iterations`, `agent.max_output_tokens`,
`agent.max_turn_tokens`, `agent.compaction_threshold`), with sane defaults
(25 / 1024 / 60,000 / 0.85) when the block is absent:

```python
Config.agent_max_iterations()        # 25
Config.agent_max_output_tokens()     # 1024
Config.agent_max_turn_tokens()       # 60_000
Config.agent_compaction_threshold()  # 0.85
```

### Reasoning/thinking normalization

Every backend now normalizes provider-specific "thinking" output into a
common `{"type": "reasoning"}` content block (see `backends/base.py`'s
module docstring for the full contract), so the agent's reasoning is a
first-class, loggable step regardless of provider:

- **Anthropic**: native `thinking`/`redacted_thinking` blocks, signature
  preserved for round-tripping.
- **Gemini**: `thought`/`thoughtSignature` parts.
- **Ollama** / **Ollama Cloud**: `message["thinking"]`.

`Logger.reasoning()` and `Logger.plan()` log these as their own event
types; `Agent._log_reasoning()` emits one `reasoning` event per block,
skipping empty non-redacted ones.

#### Normalized response contract

Every backend's `parse_response()` returns:

```python
{"stop_reason": "tool_use" | "end_turn", "content": [<block>, <block>, ...]}
```

where each block is one of:

```python
{"type": "reasoning", "text": "...", "signature": "...", "redacted": True}  # signature/redacted optional
{"type": "text", "text": "..."}
{"type": "tool_use", "id": ..., "name": ..., "input": {...}}
```

Reasoning blocks come first in `content`, before text and tool_use (matching
Anthropic's native ordering). Backends that don't accept reasoning back in a
request drop these blocks when rebuilding assistant turns.

### The OpenAI backend now targets `/v1/responses`

gpt-5.x rejects `reasoning_effort` + tools on `/v1/chat/completions`
("Please use /v1/responses"), so `backends/openai.py` migrated to the
Responses API. That changes more than the URL: messages become `input`
items, the system prompt becomes a top-level `instructions` string, tool
defs are flat (no `function:` wrapper), and tool results round-trip via
`function_call_output` items matched by `call_id` rather than a
`{"role": "tool"}` message. `MODELS` also changed shape (`gpt-5.5`,
`gpt-5.4-mini`, `gpt-5.4-nano`).

### `boukensha.run` / `boukensha.repl` — `context_window` keyword

Defaults to `models.context_window(model)`:

```python
boukensha.repl(context_window=128_000)  # override for a smaller model
```

### `Context` no longer takes a `task`

`Context.__init__` dropped its `task` parameter — nothing in this step reads
it, since per-turn limits now come from `Config.agent_*` rather than
per-task settings. `Context.__repr__` no longer shows a `task=` field.

## Run the demo

```bash
# Offline, no API key, no live MUD — uses the daemon's built-in fake MUD:
uv run python examples/mcp_mud_demo.py --dry

# One-shot demo:
uv run python examples/example.py

# Launch the interactive Textual TUI via the wrapper (it already knows its
# own step path, so no BOUKENSHA_PATH is needed):
./week1_baseline/bin/python/12_context

# plain REPL (no textual dependency exercised at runtime):
./week1_baseline/bin/python/12_context --no-tui
```

The launcher finds its config directory via `BOUKENSHA_DIR`, then
`boukensha_dir` in `~/.boukensharc`, then `~/.boukensha`. In this repo the
config lives at the **repo-root** `.boukensha/` (there is no `~/.boukensha`),
so either set `~/.boukensharc` once (`boukensha_dir: /abs/path/to/repo/.boukensha`)
or prefix each run with `BOUKENSHA_DIR="$(pwd)/.boukensha"` from the repo root.

### OpenTelemetry tracing (back-ported from week 2)

**Not part of the original step 12.** Ported forward from
`week2_capable/boukensha/lib/boukensha/telemetry/*` so the globally installed
`boukensha` can emit traces; upstream Ruby only grows this in week 2.

```
boukensha/telemetry/
  __init__.py         # build(config:) -> live exporter or Noop
  noop.py             # the null object every untraced session gets
  open_telemetry.py   # OTLP/HTTP exporter, GenAI semconv 1.37.0
```

Off by default. Enable in `settings.yaml`, endpoint via standard env vars:

```yaml
observability:
  otel:
    enabled: true
    capture_content: false   # metadata only; see the warning below
    content_max_bytes: 4096
```

`Logger.operation(name, kind:, attributes:, root:)` is a context manager
yielding a `Frame` whose `.set()` accumulates span attributes. The agent opens
three span types, matching Ruby's names and attributes:

| span | kind | key attributes |
|---|---|---|
| `invoke_agent <task>` | internal, trace root | `gen_ai.operation.name`, `gen_ai.agent.name` |
| `chat <model>` | client | `gen_ai.request.model`, `gen_ai.provider.name`, `gen_ai.usage.*` |
| `execute_tool <tool>` | client | `gen_ai.tool.name`, `boukensha.tool.full_name` |

Verified live against Langfuse Cloud: the trace tree types correctly
(AGENT / GENERATION / TOOL), and cost is derived from model + token counts
without emitting `gen_ai.usage.cost`.

> **`capture_content: true` sends prompts and tool payloads off-box.** It also
> will not fill Langfuse's input/output panes: content is written to span
> *events*, and Langfuse reads input/output from span *attributes*
> (`langfuse.observation.input` / `gen_ai.prompt`). Bridging that needs vendor
> attributes and is a deliberate break from the pinned semconv contract.

## Tests

```bash
uv run pytest
```

10 pass, 12 skip — the skips need the `mud-manager` binary from
`week0_explore/mud_manager`, which this checkout doesn't ship. **Stale on this
machine:** that binary is now present, so those tests execute instead of
skipping, and three fail because they assert the daemon's *fake* MUD replies
while a real MUD is reachable. Pre-existing and unrelated to telemetry —
verified by stashing.

## Differences from Ruby

- **Telemetry is a reduced port.** Ruby's `Logger#operation` also writes
  `operation_start`/`operation_end` JSONL records and mints correlation ids for
  the week-2 change-data-capture journal. Those belong to the `Operation`
  subsystem, which this step does not have, so `operation()` emits **spans
  only** — with tracing off, a session's JSONL is byte-identical to one written
  before the port. When tracing is on, the sole shape change is `trace_id` /
  `span_id` stamped on each line.
- **`Logger.current_task` is a single name, not a stack.** Ruby pushes/pops for
  delegated sub-runs; step 12 has no delegation.
- **`error!` → `error`** on both span classes: `!` is not a legal Python
  identifier.
- **`error.type` is the bare class name** (`ApiError`), where Ruby records the
  fully-qualified `Boukensha::ApiError`.
- **`force_flush`/`shutdown` keep Ruby's seconds-based timeout** and convert to
  the Python SDK's milliseconds internally. `TracerProvider.shutdown()` accepts
  no timeout in Python, so that argument is accepted and ignored.
- **The exporter is wired explicitly.** Ruby's `SDK.configure` installs a batch
  processor and OTLP exporter implicitly once the gem is required; Python has to
  construct `BatchSpanProcessor(OTLPSpanExporter())` by hand. The
  `proto-http` exporter is used, not `proto-grpc` — Langfuse does not accept
  OTLP/gRPC.
- **Redaction quirk preserved:** the `Bearer ` prefix test is case-*sensitive*
  while the pattern matching it is not, so `bearer abc` is replaced wholesale
  while `Bearer abc` keeps its scheme. That asymmetry is Ruby's.
- **Usage extraction reads only `"usage"`**, so `gen_ai.usage.*` is accurate for
  Anthropic/OpenAI and absent for Gemini — the same upstream limitation already
  documented below for token tracking.

- **`Agent._extract_text()` now joins with `"\n"`**, matching Ruby's
  `.join("\n")` exactly. An earlier Python step (before this one) had it
  joining with `""` — a pre-existing drift from Ruby, fixed here while
  rewriting `agent.py` for this step's token tracking.
- **`Agent._handle_tool_calls()` now always logs the `(tool use — N
  calls)` placeholder** as the response text, with any accompanying
  reasoning/preamble text logged separately via `Logger.plan()` — matching
  Ruby's `agent.rb` exactly. An earlier Python step had these two concerns
  conflated into one conditional; `Logger.plan()` didn't exist in Python
  before this step either. Both are added here.
- **Usage extraction uses `response.get("usage")` directly**, not a
  multi-provider-format normalizer. This matches Ruby's `agent.rb` exactly
  (`response["usage"]`), which means `current_tokens`/`turn_tokens` tracking
  is only accurate for Anthropic and OpenAI (both use an `"usage"` key with
  `input_tokens`/`output_tokens`) — Gemini's usage lives under
  `"usageMetadata"` and Ollama's is top-level, so compaction/turn-token
  tracking is inert for those two backends. This is a genuine upstream
  limitation, not a Python-side gap — ported as-is.
- Carries forward every standing decision from `00_config` onward:
  `.yaml`/`.yml` fallback fix (Python-side only), `uv`/hatchling,
  `requires-python >=3.14`, pytest for the pieces upstream Ruby itself
  tests (MCP client/registration/config — unchanged from `09_global_executable`).
