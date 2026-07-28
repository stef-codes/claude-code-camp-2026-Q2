# 11 · A Terminal UI (Python port)

Python port of [`ruby/11_tui`](../../ruby/11_tui/README.md). Built on top of
the [`10_standard_tool_library`](../10_standard_tool_library/README.md) port.

Ruby's TUI is built on [`charm`](https://github.com/charm-ruby/charm)
(bubbletea + lipgloss + bubbles) — a native Go/C binding with no Python
equivalent. This step is therefore a **from-scratch rebuild against
[Textual](https://textual.textualize.io/)**, not a literal translation of
`tui.rb`, aiming for full feature parity rather than a line-by-line port.
The plain REPL is still there and can be selected with `tui=False`.

The standard tool library is still **MCP** — boukensha ships no tools of
its own; every tool comes from an MCP server declared in `settings.yaml`.

## New Files

| File | Purpose |
|------|---------|
| `boukensha/tui.py` | `Tui` — the Textual-based terminal UI |

## Updated Files

| File | Change |
|------|--------|
| `boukensha/repl.py` | Refactored for composability: `on_output()`, `banner()`, `handle_command()`, `run_turn()` are now the public surface a front-end drives |
| `boukensha/__init__.py` | `repl()` gained a `tui: bool = True` keyword |
| `boukensha_loader.py` | `--no-tui` CLI flag, forwarded as `tui=False` |

## What's new

### `boukensha.Tui`

Wraps a `Repl` instance and replaces its raw `print`/`input` I/O with a
structured four-zone display:

```
┌──────────────────────────────────────────────┐
│  conversation viewport (scrollable)           │
├──────────────────────────────────────────────┤
│  ⟳ live progress line (hidden when idle)     │
├──────────────────────────────────────────────┤
│  boukensha> input box                         │
├──────────────────────────────────────────────┤
│  status line (always-on)                      │
└──────────────────────────────────────────────┘
```

The **progress line** shows a spinner, current action, iteration counter
(`n/MAX`), elapsed seconds, token counts (↑ in / ↓ out), and tool call count
while the agent is running. When idle it shows context usage and turn count.

The **status line** always shows: version · model · context tokens used ·
registered tool count · wall-clock time.

**Keyboard shortcuts:**

| Key | Action |
|-----|--------|
| `Enter` | Submit input or slash command |
| `Esc` | Interrupt the running agent turn |
| `Ctrl+L` | Clear conversation history |
| `PgUp` / `PgDn` | Scroll conversation viewport |
| `Ctrl+C` / `Ctrl+D` | Quit |

The agent runs on a background `threading.Thread` (mirroring Ruby's
`Thread.new`) so the UI stays responsive during long turns; `Logger.subscribe()`
streams structured events back to the UI thread for the live progress
display.

### `boukensha.repl()` — `tui` keyword

```python
boukensha.repl(tui=True)   # default — launches the Textual TUI
boukensha.repl(tui=False)  # falls back to the plain terminal REPL
```

The `--no-tui` CLI flag sets `tui=False` from the command line.

### `Repl` refactored for composability

`Repl` no longer hard-codes `print`/`input`. These methods let `Tui` (or any
other front-end) drive it:

| Method | Purpose |
|--------|---------|
| `on_output(callback)` | Route all REPL output through a callback instead of stdout |
| `handle_command(input_text)` | Process a slash command; returns `"quit"`, `"command"`, or `None` |
| `run_turn(input_text)` | Run one agent turn and route the result through `on_output` |

`banner()`, `logger`, `context`, `model`, and `version` are also exposed.

### `Logger.subscribe()`

```python
logger.subscribe(lambda event: ...)
```

Every structured log event (`iteration`, `tool_call`, `tool_result`,
`response`, etc.) is broadcast to all registered subscribers as well as
being written to the JSONL file. `Tui` uses this to update the live progress
line in real time without polling.

## Run the demo

The TUI is interactive, so it's run via the `boukensha` executable rather
than `examples/example.py` (that file is the one-shot `boukensha.run` demo,
carried over unchanged — it doesn't exercise the TUI).

```bash
# Offline, no API key, no live MUD — uses the daemon's built-in fake MUD:
uv run python examples/mcp_mud_demo.py --dry

# launch the Textual TUI via the wrapper (it already knows its own step
# path, so no BOUKENSHA_PATH is needed):
./week1_baseline/bin/python/11_tui

# plain REPL (no textual dependency exercised at runtime):
./week1_baseline/bin/python/11_tui --no-tui
```

The launcher finds its config directory via `BOUKENSHA_DIR`, then
`boukensha_dir` in `~/.boukensharc`, then `~/.boukensha`. In this repo the
config lives at the **repo-root** `.boukensha/` (there is no `~/.boukensha`),
so either set `~/.boukensharc` once (`boukensha_dir: /abs/path/to/repo/.boukensha`)
or prefix each run with `BOUKENSHA_DIR="$(pwd)/.boukensha"` from the repo root.

## Tests

```bash
uv run pytest
```

## Differences from Ruby

- **Textual, not charm** — see the intro above. Key implementation notes:
  - `Tui` runs the agent turn on a `threading.Thread`; `Esc` interrupts it
    via `ctypes.pythonapi.PyThreadState_SetAsyncExc`, a best-effort
    analogue of Ruby's `Thread#raise(Interrupt)` (Python has no first-class
    API for injecting an exception into another thread — like Ruby, this
    can only take effect at the next bytecode checkpoint, not instantly
    against blocking I/O).
  - The conversation viewport uses `markup=False` since none of its
    content (banner text, `[error]`/`[interrupted]` markers) is meant to
    be interpreted as Rich markup; the literal `[ready]` in the progress
    line is escaped (`\[ready]`) for the same reason.
  - `Repl`/`Logger` callbacks fire from two different threads (slash
    commands run inline on the UI thread; agent-turn events run on the
    background thread) — `Tui` checks `threading.current_thread()` and
    only uses `call_from_thread()` when actually crossing threads, since
    Textual raises if it's called from the app's own thread.
- Carries forward the standing decisions from earlier steps: `.yaml`/`.yml`
  fallback fix (Python-side only), pytest for the MCP-layer tests
  (unchanged from `10_standard_tool_library`), `uv`/hatchling,
  `requires-python >=3.14`.
