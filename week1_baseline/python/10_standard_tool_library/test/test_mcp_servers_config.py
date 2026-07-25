from __future__ import annotations

import pytest

from helper import config_from, mud_manager_args, mud_manager_command, skip_without_mud_manager

import boukensha
from boukensha import Context, Player, Registry
from boukensha.tools.mcp import CollisionError

# `mcp_servers:` in settings.yaml is what makes boukensha a general MCP
# host: plugging in a server is data, not code.


def new_registry():
    ctx = Context(task=Player, system="test")
    return ctx, Registry(ctx)


def test_parses_entries_and_applies_defaults():
    yaml_text = """
mcp_servers:
  mud:
    command: mud-manager
    args:    [--mcp]
    prefix:  tbamud
    env:
      MUD_HOST: your.mud.host
      MUD_PORT: 4000
  filesystem:
    command: npx
    required: false
"""
    with config_from(yaml_text) as cfg:
        mud = cfg.mcp_servers()["mud"]
        assert mud["command"] == "mud-manager"
        assert mud["args"] == ["--mcp"]
        assert mud["prefix"] == "tbamud"
        # env values are stringified — YAML would hand us 4000 as an int,
        # and the spawn environment only accepts strings.
        assert mud["env"] == {"MUD_HOST": "your.mud.host", "MUD_PORT": "4000"}
        assert mud["required"], "servers are required by default"

        fs = cfg.mcp_servers()["filesystem"]
        assert fs["args"] == []
        assert fs["env"] == {}
        assert fs["prefix"] is None
        assert not fs["required"]


def test_absent_block_is_empty():
    with config_from("tasks: {}") as cfg:
        assert cfg.mcp_servers() == {}


def test_required_server_that_fails_to_spawn_raises():
    yaml_text = """
mcp_servers:
  broken:
    command: boukensha-no-such-mcp-server-xyz
"""
    with config_from(yaml_text) as cfg:
        _ctx, registry = new_registry()
        with pytest.raises(RuntimeError, match=r"'broken' failed to start"):
            boukensha._register_mcp_servers(registry, cfg)


def test_optional_server_that_fails_to_spawn_warns_and_continues(capsys):
    yaml_text = """
mcp_servers:
  decorative:
    command: boukensha-no-such-mcp-server-xyz
    required: false
"""
    with config_from(yaml_text) as cfg:
        ctx, registry = new_registry()
        boukensha._register_mcp_servers(registry, cfg)
        captured = capsys.readouterr()
        assert "optional MCP server 'decorative' failed to start" in captured.out + captured.err
        assert len(ctx.tools) == 0


def _server_yaml(name: str, fake_port: int, extra: str = "") -> str:
    args_repr = repr(mud_manager_args())
    return f"""
mcp_servers:
  {name}:
    command: {mud_manager_command()}
    args:    {args_repr}
{extra}
    env:
      MUD_HOST:     127.0.0.1
      MUD_PORT:     {fake_port}
      MUD_NAME:     Gandalf
      MUD_PASSWORD: secret
"""


@skip_without_mud_manager
def test_optional_server_does_not_excuse_a_collision():
    with config_from(_server_yaml("unprefixed", 0, extra="    required: false")) as cfg:
        _ctx, registry = new_registry()
        registry.tool("look", description="pre-existing", block=lambda: "local")

        with pytest.raises(CollisionError):
            boukensha._register_mcp_servers(registry, cfg)


def test_mud_is_just_another_server():
    yaml_text = """
mcp_servers:
  mud:
    command: boukensha-no-such-mcp-server-xyz
"""
    with config_from(yaml_text) as cfg:
        _ctx, registry = new_registry()
        with pytest.raises(RuntimeError, match=r"'mud' failed to start"):
            boukensha._register_mcp_servers(registry, cfg)


@skip_without_mud_manager
def test_returns_a_tool_count_per_server():
    with config_from(_server_yaml("mud", 0, extra="    prefix: tbamud")) as cfg:
        _ctx, registry = new_registry()
        summary = boukensha._register_mcp_servers(registry, cfg)
        assert summary == {"mud": 26}
