# 02 · The Tool Registry (Python port)

Python port of [`ruby/02_the_registry`](../../ruby/02_the_registry/README.md).
Built on top of the [`01_struct_skeleton`](../01_struct_skeleton/README.md)
port — `Tool`, `Message`, `Context` carry over unchanged.

The Tool Registry is how BOUKENSHA manages what capabilities the agent can
use. It has two jobs: storing tools, and dispatching them when asked. The
agent never calls a tool directly — it emits a structured request (name +
args), and the Registry looks the tool up and runs it.

## New Files

| File | Purpose |
|------|---------|
| `boukensha/registry.py` | `Registry` — registers tools and dispatches calls |
| `boukensha/errors.py` | `UnknownToolError` |

## `boukensha.Registry`

| Method | Description |
|--------|-------------|
| `tool(name, *, description, parameters=None, block=None)` | Registers a new tool on the context |
| `dispatch(name, args=None)` | Looks up a tool by name and calls it with the provided args |

## `boukensha.UnknownToolError`

Raised when `dispatch` is called with a name that has no registered tool — a
harness needs explicit error boundaries; an unrecognised tool name should
never silently fail.

```python
>>> registry.dispatch("flee")
UnknownToolError: No tool registered as 'flee'
```

## Run Example

```bash
./week1_baseline/bin/python/02_the_registry
```

Expected output (values from your `.boukensha/`):

```
=== BOUKENSHA Step 2: Tool Registry ===

Config:  #<Boukensha::Config dir=... tasks=player>
Context: #<Context task=player turns=0 tools=2>
Tools:
  #<Tool name=move description=Move the player in a direction (north, south, east, west, up, down) params=['direction']>
  #<Tool name=shout description=Shout a message so everyone in the zone can hear it params=['message']>

Dispatching 'shout' with message='dragon spotted'...
Result: DRAGON SPOTTED

Dispatching 'move' with direction='north'...
Result: You move north into a torch-lit corridor.

UnknownToolError caught: No tool registered as 'flee'
```

## Differences from Ruby

- **No string/symbol key translation needed.** Ruby's `dispatch` converts
  string keys (from JSON) to symbol keys before calling the block, since
  Ruby blocks expect symbol keyword args. Python has no such duality — the
  registered `block` is a plain callable invoked with `**args`, and dict
  keys stay strings throughout.
- Carries forward the standing decisions from `00_config`/`01_struct_skeleton`:
  `.yaml`/`.yml` fallback fix (Python-side only), no pytest suite for this
  step, `uv`/hatchling, `requires-python >=3.14`.
