# 07 · The `boukensha.run` DSL (Python port)

Python port of [`ruby/07_the_run_dsl`](../../ruby/07_the_run_dsl/README.md).
Built on top of the [`06_the_logger`](../06_the_logger/README.md) port.

## What this step adds

A single top-level entry point: `boukensha.run()`.

Every previous step required manually creating and wiring together a
`Context`, `Registry`, `Backend`, `PromptBuilder`, `Client`, `Logger`, and
`Agent`. This step hides all of that behind one function call and an
optional `register` callback.

## The new primitive

### `boukensha.RunDSL`

A tiny host object passed to your `register` callback, exposing only one
method: `tool()`. This keeps the surface intentionally small and prevents
callers from reaching internal state — the Python equivalent of Ruby's
`instance_eval(&block)` DSL pattern, since Python has no direct analogue for
rebinding `self` inside a block.

### `boukensha.run()`

Accepts keyword arguments describing *what* to do; all plumbing is handled
internally.

| Option | Default | Description |
|--------|---------|--------------|
| `task` | *(required)* | The user message handed to the agent |
| `system` | task's system prompt | System prompt |
| `model` | task's configured model | Model name |
| `backend` | task's configured provider | `"anthropic"`, `"openai"`, `"gemini"`, `"ollama"`, or `"ollama_cloud"` |
| `api_key` | matching `*_API_KEY` env var | API key for the chosen backend |
| `ollama_host` | `"http://localhost:11434"` | Ollama base URL |
| `log` | `None` | Optional path override; defaults to `.boukensha/sessions/<session-id>.jsonl` |
| `max_output_tokens` | task's setting | Max tokens per API response |
| `register` | `None` | `Callable[[RunDSL], None]` used to register tools before the run |

## Before and after

**Step 5/6 — manual plumbing:**

```python
ctx = boukensha.Context(system="You are a MUD player assistant.")
registry = boukensha.Registry(ctx)
backend = boukensha.backends.Anthropic(api_key=os.environ["ANTHROPIC_API_KEY"], model="claude-haiku-4-5")
builder = boukensha.PromptBuilder(ctx, backend)
client = boukensha.Client(builder)
logger = boukensha.Logger()
agent = boukensha.Agent(context=ctx, registry=registry, builder=builder, client=client, logger=logger)

registry.tool("read_file", description="Read a file", parameters={"path": {"type": "string"}},
              block=lambda path: open(path).read())

ctx.add_message("user", "Read boukensha/__init__.py")
agent.run()
```

**Step 7 — just describe what you want:**

```python
def register(dsl):
    dsl.tool(
        "read_file",
        description="Read a file",
        parameters={"path": {"type": "string", "description": "File path"}},
        block=lambda path: open(path).read(),
    )

boukensha.run(task="Read boukensha/__init__.py", register=register)
```

## Run Example

```bash
./week1_baseline/bin/python/07_the_run_dsl
```

The example registers two tools (`read_file`, `list_directory`) and asks the
agent to list the directory then read a file. The logger prints each phase
to stdout and writes a session JSONL file under `.boukensha/sessions`.

## Differences from Ruby

- **`register(dsl)` callback function** replaces Ruby's `instance_eval(&block)`
  DSL — Python has no way to rebind `self` inside a block the way Ruby does,
  so the DSL object is passed as an explicit argument instead of becoming
  the implicit receiver.
- This Ruby version's `example.rb` has an actively-broken `BOUKENSHA_DIR`
  relative path (resolves to a nonexistent directory instead of the real
  repo-root `.boukensha`) — verified directly against the Ruby source. The
  Python port uses the correct path instead, since the broken one would
  make the demo fail outright rather than merely diverge cosmetically.
- Carries forward the standing decisions from earlier steps: `.yaml`/`.yml`
  fallback fix (Python-side only), no pytest suite, `uv`/hatchling,
  `requires-python >=3.14`.
