# 10 · A Standard Tool Library (Python port)

Python port of [`ruby/10_standard_tool_library`](../../ruby/10_standard_tool_library/README.md).
Built on top of the [`09_global_executable`](../09_global_executable/README.md) port.

The standard tool library is **MCP**.

Boukensha ships **no tools of its own**. It is an MCP *host*: every tool the
agent can call comes from an MCP server declared in `settings.yaml`. Want
file access? Plug in a filesystem server. Want to play a MUD? Plug in
`mud-manager --mcp`. An agent with an empty `mcp_servers:` block can only
talk.

> The directory is still named `10_standard_tool_library` from when this
> step shipped built-in filesystem/shell/MUD tool modules. Those are gone —
> the name is kept so the step ordering and every path that points here
> still resolves.

## New Files

| File | Purpose |
|------|---------|
| `boukensha/mcp/client.py` | Minimal MCP-over-stdio client |
| `boukensha/tools/mcp.py` | Registers a server's discovered tools into a `Registry` |
| `test/helper.py`, `test/test_mcp_client.py`, `test/test_mcp_servers_config.py`, `test/test_tools_mcp.py` | pytest suite for the above (see "Differences from Ruby") |
| `examples/mcp_mud_demo.py` | MCP-over-stdio demo against the `mud-manager` daemon |

## What's new

### `boukensha.mcp.Client`

A minimal MCP-over-stdio client: spawn a server, handshake, `tools/list`,
`tools/call`. It is server-agnostic — `command`/`args`/`env` is the
standard stdio transport config, the same triple every MCP host uses.

### `boukensha.tools.mcp`

The only thing left under `tools/`. Registers a server's discovered tools
into a registry, optionally scoping their names with a `prefix`.

```python
from boukensha.tools import mcp

client = mcp.register(
    registry,
    command="mud-manager", args=["--mcp"],
    env={"MUD_HOST": "localhost"},
    prefix="tbamud",          # the daemon's `look` registers as `tbamud__look`
)
```

Prefixing is applied **client-side**: the server still sees `look` on the
wire. It exists so two servers can't silently clobber each other's names —
a collision raises and names the fix (`mcp.CollisionError`).

### `mcp_servers:` in `settings.yaml`

Adding a capability is a config edit, not a code change:

```yaml
mcp_servers:
  mud:
    command: mud-manager
    args:    [--mcp]
    prefix:  tbamud
    env:                     # a stdio server's credentials travel by environment
      MUD_HOST:     your.mud.host
      MUD_NAME:     Gandalf
      MUD_PASSWORD: secret

  filesystem:
    command:  npx
    args:     [-y, "@modelcontextprotocol/server-filesystem", /tmp]
    prefix:   fs
    required: false          # can't start? warn and carry on
```

| Key | Default | Meaning |
|-----|---------|---------|
| `command` | — | Executable to spawn. Resolved by the OS, so a relative path depends on your cwd. |
| `args` | `[]` | Its argv. |
| `env` | `{}` | Extra environment. Servers inherit boukensha's environment; these keys override it. |
| `prefix` | none | Scopes discovered names (`fs` → `fs__read_file`). |
| `required` | `true` | `false` downgrades a failure to start into a warning. |

### What went away

| Gone | Replaced by |
|------|-------------|
| Built-in filesystem tools (`pwd`, `read_file`, `write_file`, `search_files`, …) | a filesystem MCP server. Trade-off: needs node/npx, and its root is fixed in `args:` instead of tracking `working_dir`. |
| Built-in shell tool (`run_command`) | a shell MCP server of your choosing. |
| Built-in MUD tool (embedded MUD session) | the `mud-manager --mcp` daemon, which wraps the same underlying MUD client. |
| the `mud:`/`working_dir:`/`allowed_commands:`/`shell_timeout:` arguments and `mud:` in settings.yaml | one `mcp_servers:` entry. |

`working_dir` survives on `boukensha.run()` / `.repl()`, but only as
`Context` metadata — it registers nothing.

## Run the demo

```bash
# Offline, no API key, no live MUD — uses the daemon's built-in fake MUD:
uv run python examples/mcp_mud_demo.py --dry

# Full run — needs ANTHROPIC_API_KEY and an mcp_servers: mud entry.
# Launch from the repo root so the example config's relative path resolves:
BOUKENSHA_DIR=.boukensha uv run --project week1_baseline/python/10_standard_tool_library \
  python week1_baseline/python/10_standard_tool_library/examples/example.py

# or via the global executable pointed at this step:
BOUKENSHA_PATH=~/Sites/boukensha/python/10_standard_tool_library boukensha
```

## Tests

```bash
uv run pytest
```

In this checkout, the `mud-manager` binary (`week0_explore/mud_manager`)
isn't built, so tests that need a live MCP server skip rather than fail —
same skip pattern as Ruby's own test suite would show.

## Differences from Ruby

- **pytest coverage carried over from Ruby's own test suite** for this
  step's MCP client/registration/config logic — this is where upstream
  Ruby itself first added tests, so Python's "no pytest" default (in effect
  through every prior step) is lifted here to match, continuing the
  exception started in `09_global_executable`.
- Carries forward the standing decisions from earlier steps: `.yaml`/`.yml`
  fallback fix (Python-side only), `uv`/hatchling, `requires-python >=3.14`.
