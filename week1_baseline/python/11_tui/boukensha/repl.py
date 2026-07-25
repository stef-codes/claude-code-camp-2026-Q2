from __future__ import annotations

import os
import sys
from typing import Callable

from .agent import Agent
from .errors import ApiError, LoopError


class Repl:
    # Repl is the interactive session loop.
    #
    # It wraps the same primitives as a single boukensha.run call, but instead
    # of running once it stays alive: it reads a task from the user, runs the
    # agent, prints the reply, and loops back to the prompt.
    #
    # The Context is shared across every turn so conversation history
    # accumulates naturally — the agent sees the full transcript each time it
    # is called.
    #
    # Built-in commands (not sent to the agent):
    #   /help    print the command list
    #   /quiet   suppress detailed logging
    #   /loud    re-enable logging
    #   /clear   wipe conversation history (tools stay registered)
    #   /exit    leave the REPL
    #   /quit    alias for /exit
    PROMPT = "boukensha> "

    HELP = (
        "Commands:\n"
        "  /quiet   suppress logging output\n"
        "  /loud    re-enable logging output\n"
        "  /clear   wipe conversation history (tools stay)\n"
        "  /exit    leave the REPL\n"
        "  /help    show this message"
    )

    def __init__(
        self,
        *,
        context,
        registry,
        builder,
        client,
        logger,
        config_dir: str | None = None,
        provider: str | None = None,
        model: str | None = None,
        version: str | None = None,
        api_key: str | None = None,
        servers: dict | None = None,
        task_settings: dict | None = None,
        max_iterations: int | None = None,
        max_output_tokens: int | None = None,
    ) -> None:
        self.context = context
        self.registry = registry
        self.builder = builder
        self.client = client
        self.logger = logger
        self.task_settings = task_settings
        self.max_iterations = max_iterations
        self.max_output_tokens = max_output_tokens
        self.config_dir = config_dir
        self.provider = provider
        self.model = model
        self.version = version
        self.api_key = api_key
        self.servers = servers
        self.turn_number = 0
        self._output_cb: Callable[[str], None] | None = None

    # Register a callback that receives every string the REPL would
    # otherwise print to stdout. When set, print is suppressed entirely and
    # all output is routed through the callback instead. Used by Tui.
    def on_output(self, callback: Callable[[str], None]) -> None:
        self._output_cb = callback

    def banner(self) -> str:
        key_status = (
            "✗ API key not set" if not self.api_key or not self.api_key.strip() else "✓ API key set"
        )
        provider_line = f"{self.provider or 'default'} ({self.model or 'default'})  {key_status}"
        config_exists = self.config_dir and os.path.isdir(self.config_dir)
        config_line = (
            self.config_dir if config_exists else f"{self.config_dir or '(default)'}  ✗ directory not found"
        )
        ver = self.version or "?.?.?"
        pad = " " * (9 - len(ver))
        servers_stat = self._servers_status_string()

        return (
            "\n"
            "╔══════════════════════════════════════╗\n"
            f"║  BOUKENSHA MUD Assistant (v{ver}){pad}║\n"
            "╚══════════════════════════════════════╝\n"
            f"  config:    {config_line}\n"
            f"  provider:  {provider_line}\n"
            f"  servers:   {servers_stat}\n"
            "\n"
            "  /quiet or /loud   toggle logging\n"
            "  /clear           reset conversation history\n"
            "  /exit or /quit    leave the REPL\n"
        )

    # Handle a slash command. Returns "quit", "command", or None (not a
    # command). Output is routed through the registered on_output callback
    # if present.
    def handle_command(self, input_text: str) -> str | None:
        if input_text in ("/exit", "/quit"):
            self._output("Goodbye.")
            return "quit"
        elif input_text == "/help":
            self._output(self.HELP)
            return "command"
        elif input_text == "/quiet":
            from . import enable_quiet

            enable_quiet()
            self._output("(logging suppressed — type /loud to re-enable)")
            return "command"
        elif input_text == "/loud":
            from . import disable_quiet

            disable_quiet()
            self._output("(logging enabled)")
            return "command"
        elif input_text == "/clear":
            self.context.clear_messages()
            self.turn_number = 0
            self._output("(conversation history cleared)")
            return "command"
        return None

    def run_turn(self, input_text: str) -> None:
        self.turn_number += 1
        self.logger.turn(n=self.turn_number)

        self.context.add_message("user", input_text)

        agent = Agent(
            context=self.context,
            registry=self.registry,
            builder=self.builder,
            client=self.client,
            logger=self.logger,
            task_settings=self.task_settings,
            max_iterations=self.max_iterations,
            max_output_tokens=self.max_output_tokens,
        )
        try:
            result = agent.run()
            # Print the final response outside of the logger so it is always
            # visible, even when boukensha.enable_quiet() is active.
            self._output("")
            self._output(result)
        except LoopError as e:
            self._output(f"\n[error] {e}")
        except ApiError as e:
            self._output(f"\n[error] API call failed: {e}")

    def start(self) -> None:
        self._output(self.banner())

        while True:
            if not self._output_cb:
                print(self.PROMPT, end="")
                sys.stdout.flush()

            line = sys.stdin.readline()
            if line == "":
                break  # EOF / Ctrl-D

            input_text = line.strip()
            if not input_text:
                continue

            result = self.handle_command(input_text)
            if result == "quit":
                break
            if result:
                continue

            self.run_turn(input_text)

    def _output(self, text: str) -> None:
        if self._output_cb:
            self._output_cb(str(text))
        else:
            print(text)

    # Build the MCP servers line shown in the banner. Every tool the agent
    # has came from one of these, so this doubles as "what can I actually
    # do?". No probing needed: a server that answers tools/list is already
    # connected, and one that didn't is either absent here or took the
    # agent down at boot.
    def _servers_status_string(self) -> str:
        if not self.servers:
            return "(none configured — the agent has no tools)"

        return "  ".join(f"{name} ({count})" for name, count in self.servers.items())
