from __future__ import annotations

import json
import os
import subprocess


class McpError(Exception):
    pass


class Client:
    # Client is a minimal MCP-over-stdio client: it spawns an MCP server as a
    # subprocess, performs the initialize handshake, and lets you discover
    # and call the tools it advertises. It knows nothing about any
    # particular server — command, args, and env are the standard stdio
    # transport config.
    #
    #   client = Client.spawn(command="mud-manager", args=["--mcp"])
    #   for t in client.tools: print(t["name"])
    #   print(client.call_tool("look")["text"])
    #   client.close()
    PROTOCOL_VERSION = "2025-06-18"

    # command: executable to spawn. args: argv for it. env: extra
    # environment (e.g. a server's credentials — the stdio transport's
    # standard channel).
    @classmethod
    def spawn(cls, *, command: str, args: list | None = None, env: dict | None = None) -> "Client":
        return cls(command=command, args=args, env=env)

    def __init__(self, *, command: str, args: list | None = None, env: dict | None = None) -> None:
        cmd = [str(command), *[str(a) for a in (args or [])]]
        full_env = {**os.environ, **{str(k): str(v) for k, v in (env or {}).items()}}
        self._process = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=full_env,
            text=True,
            bufsize=1,
        )
        self._id = 0
        self.server_info = None
        self._handshake()
        self.tools = self._fetch_tools()

    # Call a tool. Returns {"text":, "error": (bool)}.
    def call_tool(self, name: str, arguments: dict | None = None) -> dict:
        res = self._request("tools/call", {"name": str(name), "arguments": arguments or {}})
        result = res.get("result")
        if result is None:
            raise McpError(f"tools/call error: {res.get('error')!r}")

        content = result.get("content") or []
        text = "\n".join(c["text"] for c in content if c.get("text") is not None)
        return {"text": text, "error": bool(result.get("isError"))}

    def close(self) -> None:
        try:
            if self._process.stdin:
                self._process.stdin.close()
        except Exception:
            pass
        self._process.wait()
        try:
            if self._process.stdout:
                self._process.stdout.close()
        except Exception:
            pass
        try:
            if self._process.stderr:
                self._process.stderr.close()
        except Exception:
            pass

    def _handshake(self) -> None:
        from .. import VERSION

        res = self._request(
            "initialize",
            {
                "protocolVersion": self.PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "boukensha", "version": VERSION},
            },
        )
        self.server_info = (res.get("result") or {}).get("serverInfo")
        self._notify("notifications/initialized")

    def _fetch_tools(self) -> list:
        res = self._request("tools/list")
        return (res.get("result") or {}).get("tools") or []

    def _request(self, method: str, params: dict | None = None) -> dict:
        self._id += 1
        request_id = self._id
        self._write({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params or {}})
        return self._read_until(request_id)

    def _notify(self, method: str, params: dict | None = None) -> None:
        self._write({"jsonrpc": "2.0", "method": method, "params": params or {}})

    def _write(self, obj: dict) -> None:
        self._process.stdin.write(json.dumps(obj) + "\n")
        self._process.stdin.flush()

    def _read_until(self, request_id: int) -> dict:
        while True:
            line = self._process.stdout.readline()
            if line == "":
                raise McpError(f"server closed the connection{self._stderr_detail()}")
            line = line.strip()
            if not line:
                continue
            msg = json.loads(line)
            if msg.get("id") == request_id:
                return msg
            # ignore server-initiated notifications / mismatched ids

    # Drains whatever the subprocess wrote to stderr before it died, so a
    # crash during spawn/handshake (bad interpreter version, missing
    # dependency, unhandled exception before the request loop starts) is
    # diagnosable instead of a bare "server closed the connection". stdout
    # hitting EOF means the process is exiting or has exited, so wait()
    # (bounded — it's already at EOF) reaps it and guarantees stderr is
    # fully flushed before the blocking read below.
    def _stderr_detail(self) -> str:
        try:
            self._process.wait()
            output = self._process.stderr.read() if self._process.stderr else ""
            return f" — stderr: {output.strip()}" if output and output.strip() else ""
        except (OSError, ValueError):
            return ""
