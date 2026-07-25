# 08 · The REPL Loop (Python port)

Python port of [`ruby/08_the_repl_loop`](../../ruby/08_the_repl_loop/README.md).
Built on top of the [`07_the_run_dsl`](../07_the_run_dsl/README.md) port.

|  | Step 7 | Step 8 |
|---|---|---|
| Entry point | `boukensha.run(task="…")` | `boukensha.repl()` |
| Turns | one | many |
| History | discarded | accumulates across turns |
| User interaction | none | stdin prompt |

## New Files

| File | Purpose |
|------|---------|
| `boukensha/repl.py` | `Repl` — the interactive session loop |
| `boukensha/version.py` | `VERSION` constant |

## New primitives

### `boukensha.Repl`

| Command | Effect |
|---------|--------|
| `/clear` | Wipe conversation history (tools stay registered) |
| `/help` | Print the command list |
| `/quiet` / `/loud` | Toggle logging output |
| `/exit` / `/quit` | Leave the REPL |
| Ctrl-D (EOF) | Leave the REPL |

### `boukensha.repl()`

Same signature as `boukensha.run()`, minus `task`. Register tools via the
`register` callback; the REPL loop takes over from there.

```python
def register(dsl):
    dsl.tool("read_file", description="Read a file from disk",
             parameters={"path": {"type": "string", "description": "File path"}},
             block=lambda path: open(path).read())

boukensha.repl(model="claude-haiku-4-5", register=register)
```

## Changes from step 7

### `Context.clear_messages()`
Wipes `messages` while keeping tools registered. Used by the REPL's
`/clear` command.

### `Agent.run()` — persists the final reply
Before this step, the agent returned the final text without adding it to
the context — fine for one-shot runs (context is thrown away anyway), but a
REPL needs the full transcript so subsequent turns see the prior exchange:

```python
# before — final text returned but NOT in context
return text

# now — final text added to context, then returned
self.context.add_message("assistant", text)
return text
```

### `Logger.turn(*, n)`
New method that prints a turn header at the start of each REPL turn, making
it easy to see where one conversation turn ends and the next begins.

## Running it

```bash
ANTHROPIC_API_KEY=your_key ./week1_baseline/bin/python/08_the_repl_loop
```

```
╔══════════════════════════════════════╗
║  BOUKENSHA REPL  —  MUD assistant   ║
║  type a command and press Enter     ║
╚══════════════════════════════════════╝

boukensha> list the files in the lib directory
…
boukensha> now read boukensha/agent.py and explain the loop
…
boukensha> /quiet
(logging suppressed — type /loud to re-enable)
boukensha> what was the first file I asked you about?
…
boukensha> /exit
Goodbye.
```

The last question demonstrates persistent history: the agent answers from
the accumulated transcript, not just the last message.

## Differences from Ruby

- **`Config._resolve_dir()` gained a third config-directory lookup tier**
  (checking `./.boukensha` relative to the current working directory) —
  this is a genuine change in this Ruby version, not a Python-side addition.
  It means the `bin/08_the_repl_loop` / `bin/python/08_the_repl_loop`
  wrapper scripts do **not** `cd` into the step directory before running
  (unlike every other step's wrapper) — they use
  `uv run --project <step-dir>` instead, so the config lookup sees the
  caller's actual working directory.
- **`Client` gained a friendlier 401 error message** — same behavior, more
  actionable text when `ANTHROPIC_API_KEY` is missing or wrong.
- Carries forward the standing decisions from earlier steps: `.yaml`/`.yml`
  fallback fix (Python-side only), no pytest suite, `uv`/hatchling,
  `requires-python >=3.14`.
