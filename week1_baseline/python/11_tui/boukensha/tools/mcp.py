from __future__ import annotations

import atexit

from ..mcp.client import Client

# Mcp makes boukensha an MCP host: point it at any MCP server and every
# tool that server advertises becomes a boukensha tool. It knows nothing
# about any particular server — command/args/env is the standard stdio
# transport config, the same triple every other MCP host uses.
#
#   register(
#       registry, command="mud-manager", args=["--mcp"],
#       env={"MUD_HOST": "localhost"}, prefix="tbamud",
#   )
#
# `registry` is anything with the .tool surface — a Registry or the RunDSL
# yielded to a run/repl callback.
#
# prefix: scopes the discovered names ("tbamud" => tbamud__look). The
# prefix is a property of the server entry, supplied by config; this module
# applies whatever it is given. Names are only prefixed agent-side — the
# server still sees its own bare name on the wire.
SEPARATOR = "__"


# Two tools claiming one name. Always fatal, even for an optional server:
# this is a config contradiction, not a server being unreachable, and
# silently dropping the loser is the expensive failure.
class CollisionError(ValueError):
    pass


def register(
    registry,
    *,
    command: str,
    args: list | None = None,
    env: dict | None = None,
    prefix: str | None = None,
) -> Client:
    client = Client.spawn(command=command, args=args, env=env)

    # Close the server subprocess cleanly when the agent process exits.
    def _close_at_exit() -> None:
        try:
            client.close()
        except Exception:
            pass

    atexit.register(_close_at_exit)
    register_client(registry, client, prefix=prefix)
    return client


# Register an already-spawned client's tools. Returns the count.
def register_client(registry, client: Client, *, prefix: str | None = None) -> int:
    taken = list(registry.tool_names) if hasattr(registry, "tool_names") else []

    for tool in client.tools:
        remote = tool["name"]
        local = prefixed(remote, prefix)

        if local in taken:
            raise CollisionError(
                f"boukensha: MCP tool name collision on '{local}' — a tool by that "
                "name is already registered. Give this server a distinct `prefix:` "
                "in mcp_servers."
            )
        taken.append(local)

        registry.tool(
            local,
            description=str(tool.get("description") or ""),
            parameters=to_boukensha_params(tool.get("inputSchema")),
            block=_make_block(client, remote),
        )

    return len(client.tools)


def prefixed(name: str, prefix: str | None) -> str:
    p = (prefix or "").strip()
    return str(name) if not p else f"{p}{SEPARATOR}{name}"


# Convert an MCP inputSchema into boukensha's `parameters` shape
# ({name: {type:, description:}}). We list every property so the model can
# supply optional ones too (servers treat blanks as absent).
def to_boukensha_params(input_schema: dict | None) -> dict:
    props = (input_schema or {}).get("properties") or {}
    out = {}
    for pname, schema in props.items():
        desc = str(schema.get("description") or "")
        if schema.get("enum"):
            desc = f"{desc} (one of: {', '.join(schema['enum'])})".strip()
        out[pname] = {"type": schema.get("type") or "string", "description": desc}
    return out


def _make_block(client: Client, remote_name: str):
    # Boukensha hands us string-keyed kwargs already; the server also wants
    # strings. Blank/omitted values are normalized server-side.
    def block(**kwargs):
        result = client.call_tool(remote_name, {str(k): v for k, v in kwargs.items()})
        return f"error: {result['text']}" if result["error"] else result["text"]

    return block
