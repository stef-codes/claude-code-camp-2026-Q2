"""
Step 10 x mud-manager (MCP path).

boukensha has no MUD code at all. This points its generic MCP client at the
`mud-manager` daemon and registers whatever tools the daemon advertises —
exactly what the Ruby / Go / Rust / Java tracks do with their own SDKs.
Nothing in boukensha.tools.mcp knows what a MUD is; the daemon is just a
server, and this file is just a host.

Note the names: the daemon advertises `look`, but we pass prefix="tbamud",
so the agent sees `tbamud__look`. Prefixing is applied agent-side; the
daemon never hears about it. In a real run that prefix comes from config.

  # Self-contained smoke test — no API key, no live MUD (built-in fake MUD):
  python examples/mcp_mud_demo.py --dry

  # Full agent run — needs ANTHROPIC_API_KEY and a reachable MUD via MUD_* or
  # ~/.boukensha/settings.yaml (mud: host/port/username/password):
  python examples/mcp_mud_demo.py
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import boukensha
from boukensha import Context, Registry
from boukensha.tools import mcp

dry = "--dry" in sys.argv

# --- credentials (env / boukensha config), or a fake MUD for --dry --------
creds = {k: os.environ[k] for k in ("MUD_HOST", "MUD_PORT", "MUD_NAME", "MUD_PASSWORD") if k in os.environ}

if dry:
    mud_manager_root = Path(__file__).resolve().parents[4] / "week0_explore" / "mud_manager"
    daemon = mud_manager_root / "bin" / "mud-manager"

    # NOTE: this repo's checkout of week0_explore/mud_manager ships no
    # bin/mud-manager or fake-MUD test double (the Ruby original's own test
    # suite requires the same files and would skip here too — see
    # test/helper.py's skip_without_mud_manager). The --dry smoke test can't
    # run without them.
    if not daemon.exists():
        sys.exit(
            f"mcp_mud_demo.py --dry requires {daemon}\n"
            "and a fake-MUD test double, neither of which are present in this checkout."
        )

    import shutil
    import subprocess

    fake_env = {
        "MUD_HOST": "127.0.0.1",
        "MUD_PORT": "0",
        "MUD_NAME": "Gandalf",
        "MUD_PASSWORD": "secret",
    }

    ctx = Context(system="demo")
    registry = Registry(ctx)

    client = mcp.register(
        registry,
        command=shutil.which("ruby") or "ruby",
        args=[str(daemon), "--mcp"],
        env=fake_env,
        prefix="tbamud",
    )

    print(f"daemon: {client.server_info}")
    print(f"tools:  {len(ctx.tools)} — {', '.join(ctx.tools.keys())}")
    print()

    print(f"tbamud__look       => {registry.dispatch('tbamud__look', {})!r}")
    print(f"tbamud__attack orc => {registry.dispatch('tbamud__attack', {'target': 'orc'})!r}")
    print(f"bad cast           => {registry.dispatch('tbamud__cast_spell', {'spell': ''})!r}")

    client.close()
    print("\n[dry run OK — daemon + step 10 generic MCP layer working]")
    sys.exit(0)

# --- full agent run ---------------------------------------------------------
# Nothing to wire up: boukensha.run spawns whatever is in `mcp_servers:` and
# registers its tools. There is no mode to select and no MUD argument to
# pass, because the agent has no concept of a MUD. See examples/example.py —
# at this point the two demos are the same program.
boukensha.run(
    task=(
        "Look at your surroundings, check your score, then look at the exits "
        "and tell me what you see."
    )
)
