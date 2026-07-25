from __future__ import annotations

import sys

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
        self.turn_number = 0

    def start(self) -> None:
        print(self._banner())

        while True:
            print(self.PROMPT, end="")
            sys.stdout.flush()

            line = sys.stdin.readline()
            if line == "":
                break  # EOF / Ctrl-D

            input_text = line.strip()
            if not input_text:
                continue

            if input_text in ("/exit", "/quit"):
                print("Goodbye.")
                break
            elif input_text == "/help":
                print(self.HELP)
                continue
            elif input_text == "/quiet":
                from . import enable_quiet

                enable_quiet()
                print("(logging suppressed — type /loud to re-enable)")
                continue
            elif input_text == "/loud":
                from . import disable_quiet

                disable_quiet()
                print("(logging enabled)")
                continue
            elif input_text == "/clear":
                self.context.clear_messages()
                self.turn_number = 0
                print("(conversation history cleared)")
                continue

            self._run_turn(input_text)

    def _banner(self) -> str:
        ver = self.version or "?.?.?"
        pad = " " * (9 - len(ver))

        return (
            "\n"
            "╔══════════════════════════════════════╗\n"
            f"║  BOUKENSHA MUD Assistant (v{ver}){pad}║\n"
            "╚══════════════════════════════════════╝\n"
            f"  config:        {self.config_dir or '(default)'}\n"
            f"  provider:      {self.provider or '(default)'}\n"
            f"  model:         {self.model or '(default)'}\n"
            "\n"
            "  /quiet or /loud   toggle logging\n"
            "  /clear           reset conversation history\n"
            "  /exit or /quit    leave the REPL\n"
        )

    def _run_turn(self, input_text: str) -> None:
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
            print()
            print(result)
        except LoopError as e:
            print(f"\n[error] {e}")
        except ApiError as e:
            print(f"\n[error] API call failed: {e}")
