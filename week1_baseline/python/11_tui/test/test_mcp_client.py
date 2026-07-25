from __future__ import annotations

import pytest

from helper import mud_manager_args, mud_manager_command, skip_without_mud_manager

from boukensha.mcp.client import Client

# Boukensha's mcp.Client is boukensha's own MCP-over-stdio client. It is
# server-agnostic: it takes a command, args, and env, and speaks the
# protocol. We point it at the mud-manager daemon because that is the MCP
# server this repo ships — nothing in the client knows that.


@pytest.fixture
def client():
    c = Client.spawn(command=mud_manager_command(), args=mud_manager_args(), env={})
    yield c
    c.close()


@skip_without_mud_manager
def test_handshake_reports_server_info(client):
    assert client.server_info["name"] == "mud-manager"
    assert client.server_info["version"] is not None


@skip_without_mud_manager
def test_tools_list_is_discovered(client):
    names = [t["name"] for t in client.tools]
    assert "look" in names
    assert "attack" in names
    # Discovery is the server's word, not ours — the client invents nothing.
    assert len(client.tools) > 1
    assert all("inputSchema" in t for t in client.tools)


@skip_without_mud_manager
def test_call_tool_reaches_the_mud(client):
    assert "You do: look" in client.call_tool("look")["text"]
    assert "You do: kill dragon" in client.call_tool("attack", {"target": "dragon"})["text"]


@skip_without_mud_manager
def test_tool_error_comes_back_as_data(client):
    # A tool-level failure is data (isError), not an exception — the agent
    # loop must be able to keep going.
    result = client.call_tool("move", {"direction": "sideways"})
    assert result["error"], "expected isError to be set"
    assert "argument_error" in result["text"]


def test_spawning_a_nonexistent_command_raises():
    with pytest.raises(FileNotFoundError):
        Client.spawn(command="boukensha-no-such-mcp-server-xyz")
