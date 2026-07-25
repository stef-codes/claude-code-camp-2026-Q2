"""
Step 10 — The agent owns no tools.

There is no `mud` argument and no tool registration here, because boukensha
has nothing of its own to register. Every tool this agent can call arrives
from an MCP server listed in settings.yaml's `mcp_servers:` block — the MUD
daemon, a filesystem server, anything that speaks MCP. Swapping what the
agent can do is a config edit, not a code change.

  python examples/example.py
  BOUKENSHA_DIR=/path/to/.boukensha python examples/example.py

Point BOUKENSHA_DIR at a config that has an `mcp_servers: mud:` entry (the
repo root's .boukensha does), and launch from the repo root so that entry's
relative command path resolves.
"""

from __future__ import annotations

import os

import boukensha

cfg = boukensha.config()
print(f"Config:  {cfg}")
print(f"Servers: {', '.join(cfg.mcp_servers().keys())}")
print(f"API key set? {os.environ.get('ANTHROPIC_API_KEY') is not None}")
print()

boukensha.run(
    task=(
        "Look at your surroundings, check your score, "
        "then look at the available exits and tell me what you see."
    )
    # system/model/api_key come from config automatically.
    # Tools come from mcp_servers — there is nothing to wire up here.
)
