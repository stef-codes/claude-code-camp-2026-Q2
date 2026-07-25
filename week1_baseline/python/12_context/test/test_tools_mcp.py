from __future__ import annotations

import pytest

from helper import mud_manager_args, mud_manager_command, skip_without_mud_manager

from boukensha import Context, Registry
from boukensha.tools import mcp

# boukensha.tools.mcp is the generic MCP host layer: point it at any MCP
# server and that server's tools become boukensha tools. These tests use
# the mud-manager daemon as "some MCP server" and deliberately never rely
# on it being a MUD.


def new_registry():
    ctx = Context(system="test")
    return ctx, Registry(ctx)


@skip_without_mud_manager
def test_register_populates_the_registry_from_discovery():
    ctx, registry = new_registry()
    client = mcp.register(registry, command=mud_manager_command(), args=mud_manager_args())
    try:
        assert len(client.tools) == len(ctx.tools)
        assert "look" in ctx.tools
        assert "You do: look" in registry.dispatch("look", {})
    finally:
        client.close()


@skip_without_mud_manager
def test_prefix_is_applied_locally_and_the_server_still_sees_bare_names():
    ctx, registry = new_registry()
    client = mcp.register(
        registry, command=mud_manager_command(), args=mud_manager_args(), prefix="tbamud"
    )
    try:
        assert "tbamud__look" in ctx.tools
        assert "look" not in ctx.tools
        # If the prefix leaked onto the wire the daemon would reject this as
        # an unknown tool; getting the MUD's response back proves it didn't.
        assert "You do: look" in registry.dispatch("tbamud__look", {})
        assert "You do: kill dragon" in registry.dispatch("tbamud__attack", {"target": "dragon"})
    finally:
        client.close()


@skip_without_mud_manager
def test_nil_prefix_yields_bare_names():
    ctx, registry = new_registry()
    client = mcp.register(registry, command=mud_manager_command(), args=mud_manager_args(), prefix=None)
    try:
        assert "look" in ctx.tools
        assert "tbamud__look" not in ctx.tools
    finally:
        client.close()


@skip_without_mud_manager
def test_schema_enum_is_surfaced_in_the_parameter_description():
    ctx, registry = new_registry()
    client = mcp.register(registry, command=mud_manager_command(), args=mud_manager_args())
    try:
        assert "north" in ctx.tools["move"].parameters["direction"]["description"]
    finally:
        client.close()


@skip_without_mud_manager
def test_colliding_tool_names_raise():
    _ctx, registry = new_registry()
    first = mcp.register(registry, command=mud_manager_command(), args=mud_manager_args(), prefix="tbamud")
    second = None
    try:
        with pytest.raises(ValueError, match=r"collision on 'tbamud__look'.*prefix"):
            second = mcp.register(
                registry, command=mud_manager_command(), args=mud_manager_args(), prefix="tbamud"
            )
    finally:
        first.close()
        if second:
            second.close()


@skip_without_mud_manager
def test_collision_with_an_existing_non_mcp_tool_raises():
    _ctx, registry = new_registry()
    registry.tool("look", description="pre-existing", block=lambda: "local")

    with pytest.raises(ValueError, match=r"collision on 'look'"):
        mcp.register(registry, command=mud_manager_command(), args=mud_manager_args())
