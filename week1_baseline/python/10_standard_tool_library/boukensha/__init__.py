from __future__ import annotations

import os
import sys
from pathlib import Path
from typing import Callable

from .version import VERSION
from .config import Config
from .tasks.player import Player
from .tool import Tool
from .message import Message
from .context import Context
from .errors import UnknownToolError, ApiError, LoopError, UnsupportedModelError
from .registry import Registry
from .prompt_builder import PromptBuilder
from .logger import Logger
from .client import Client
from .agent import Agent
from .run_dsl import RunDSL
from .repl import Repl
from . import backends
from . import tools

__all__ = [
    "VERSION",
    "Config",
    "Player",
    "Tool",
    "Message",
    "Context",
    "UnknownToolError",
    "ApiError",
    "LoopError",
    "UnsupportedModelError",
    "Registry",
    "PromptBuilder",
    "Logger",
    "Client",
    "Agent",
    "RunDSL",
    "Repl",
    "backends",
    "tools",
    "config",
    "enable_quiet",
    "disable_quiet",
    "is_quiet",
    "enable_debug",
    "is_debug",
    "run",
    "repl",
]

_state = {"quiet": False, "debug": False, "config": None}


def config() -> Config:
    if _state["config"] is None:
        _state["config"] = Config()
    return _state["config"]


def enable_quiet() -> None:
    _state["quiet"] = True


def disable_quiet() -> None:
    _state["quiet"] = False


def is_quiet() -> bool:
    return _state["quiet"]


def enable_debug() -> None:
    _state["debug"] = True


def is_debug() -> bool:
    return _state["debug"]


# The top-level entry point. Wires together every primitive so the caller
# only has to describe *what* to do, not *how* to plumb it.
#
# The agent ships with NO tools of its own. Every tool it can call arrives
# over an MCP connection, declared in settings.yaml's `mcp_servers:` block
# (see Config.mcp_servers). Want file access? Point at a filesystem MCP
# server. Want to play a MUD? Point at `mud-manager --mcp`. Boukensha is the
# host; the servers own the tools.
#
#   result = boukensha.run(task="Summarise this repo")
#
# Options:
#   task:         (required) The user message to hand the agent.
#   system:       System prompt. Defaults to the player task's system prompt.
#   model:        Model name. Defaults to the player task's configured model.
#   backend:      "anthropic" (default), "openai", "gemini", "ollama", or "ollama_cloud".
#   api_key:      API key for the chosen backend. Defaults to the matching
#                 ANTHROPIC_API_KEY / OPENAI_API_KEY / GEMINI_API_KEY / OLLAMA_API_KEY
#                 env var (loaded from .boukensha/.env). Not needed for "ollama".
#   ollama_host:  Ollama base URL. Defaults to "http://localhost:11434".
#   log:          Optional JSONL path override. Defaults to .boukensha/sessions/<session-id>.jsonl.
#   max_output_tokens: Per-reply output cap. Defaults to the player task's setting.
#   working_dir:  Recorded on the Context as the agent's notion of "where it
#                 is". It registers nothing — an MCP server that touches the
#                 filesystem is rooted by its own spawn args.
#   register:     Optional callable(dsl: RunDSL) used to register extra tools
#                 before the run, in addition to whatever mcp_servers provides.
def run(
    *,
    task: str,
    system: str | None = None,
    model: str | None = None,
    backend: str | None = None,
    api_key: str | None = None,
    ollama_host: str = "http://localhost:11434",
    log: str | None = None,
    max_output_tokens: int | None = None,
    working_dir: str | None = None,
    register: Callable[[RunDSL], None] | None = None,
) -> str:
    if working_dir is None:
        working_dir = str(Path.cwd())

    cfg = config()  # loads .env; populates os.environ
    task_class = Player
    task_settings = cfg.tasks(task_class.task_name())

    if system is None:
        system = task_class.system_prompt(
            task_settings,
            user_prompts_dir=cfg.user_prompts_dir,
            default_prompts_dir=Config.PROMPTS_DIR,
        )
    if model is None:
        model = task_class.model(task_settings)
    if backend is None:
        backend = task_class.provider(task_settings)

    if api_key is None:
        api_key = {
            "anthropic": os.environ.get("ANTHROPIC_API_KEY"),
            "openai": os.environ.get("OPENAI_API_KEY"),
            "gemini": os.environ.get("GEMINI_API_KEY"),
            "ollama_cloud": os.environ.get("OLLAMA_API_KEY"),
        }.get(backend)

    ctx = Context(task=task_class, system=system, working_dir=working_dir)
    registry = Registry(ctx)

    _register_mcp_servers(registry, cfg)

    if register is not None:
        register(RunDSL(registry))

    if backend == "anthropic":
        be = backends.Anthropic(api_key=api_key, model=model)
    elif backend == "openai":
        be = backends.OpenAI(api_key=api_key, model=model)
    elif backend == "gemini":
        be = backends.Gemini(api_key=api_key, model=model)
    elif backend == "ollama":
        be = backends.Ollama(host=ollama_host, model=model)
    elif backend == "ollama_cloud":
        be = backends.OllamaCloud(api_key=api_key, model=model)
    else:
        raise ValueError(
            f"Unknown backend {backend!r}. "
            "Use 'anthropic', 'openai', 'gemini', 'ollama', or 'ollama_cloud'."
        )

    builder = PromptBuilder(ctx, be)
    client = Client(builder)
    effective_max_iterations = task_class.max_iterations(task_settings)
    effective_max_output_tokens = max_output_tokens or task_class.max_output_tokens(task_settings)
    logger = Logger(
        log=log,
        snapshot={
            "task": task_class.task_name(),
            "max_iterations": effective_max_iterations,
            "max_output_tokens": effective_max_output_tokens,
            "model": model,
            "provider": backend,
        },
    )
    agent = Agent(
        context=ctx,
        registry=registry,
        builder=builder,
        client=client,
        logger=logger,
        task_settings=task_settings,
        max_iterations=effective_max_iterations,
        max_output_tokens=effective_max_output_tokens,
    )

    ctx.add_message("user", task)
    try:
        return agent.run()
    finally:
        logger.close()


# Interactive REPL — see boukensha.run for full option documentation.
def repl(
    *,
    system: str | None = None,
    model: str | None = None,
    backend: str | None = None,
    api_key: str | None = None,
    ollama_host: str = "http://localhost:11434",
    log: str | None = None,
    max_output_tokens: int | None = None,
    working_dir: str | None = None,
    register: Callable[[RunDSL], None] | None = None,
) -> None:
    if working_dir is None:
        working_dir = str(Path.cwd())

    cfg = config()  # loads .env; populates os.environ
    task_class = Player
    task_settings = cfg.tasks(task_class.task_name())

    if system is None:
        system = task_class.system_prompt(
            task_settings,
            user_prompts_dir=cfg.user_prompts_dir,
            default_prompts_dir=Config.PROMPTS_DIR,
        )
    if model is None:
        model = task_class.model(task_settings)
    if backend is None:
        backend = task_class.provider(task_settings)

    if api_key is None:
        api_key = {
            "anthropic": os.environ.get("ANTHROPIC_API_KEY"),
            "openai": os.environ.get("OPENAI_API_KEY"),
            "gemini": os.environ.get("GEMINI_API_KEY"),
            "ollama_cloud": os.environ.get("OLLAMA_API_KEY"),
        }.get(backend)

    ctx = Context(task=task_class, system=system, working_dir=working_dir)
    registry = Registry(ctx)

    servers = _register_mcp_servers(registry, cfg)

    if register is not None:
        register(RunDSL(registry))

    if backend == "anthropic":
        be = backends.Anthropic(api_key=api_key, model=model)
    elif backend == "openai":
        be = backends.OpenAI(api_key=api_key, model=model)
    elif backend == "gemini":
        be = backends.Gemini(api_key=api_key, model=model)
    elif backend == "ollama":
        be = backends.Ollama(host=ollama_host, model=model)
    elif backend == "ollama_cloud":
        be = backends.OllamaCloud(api_key=api_key, model=model)
    else:
        raise ValueError(
            f"Unknown backend {backend!r}. "
            "Use 'anthropic', 'openai', 'gemini', 'ollama', or 'ollama_cloud'."
        )

    builder = PromptBuilder(ctx, be)
    client = Client(builder)
    effective_max_iterations = task_class.max_iterations(task_settings)
    effective_max_output_tokens = max_output_tokens or task_class.max_output_tokens(task_settings)
    logger = Logger(
        log=log,
        snapshot={
            "task": task_class.task_name(),
            "max_iterations": effective_max_iterations,
            "max_output_tokens": effective_max_output_tokens,
            "model": model,
            "provider": backend,
        },
    )

    repl_instance = Repl(
        context=ctx,
        registry=registry,
        builder=builder,
        client=client,
        logger=logger,
        task_settings=task_settings,
        max_iterations=effective_max_iterations,
        max_output_tokens=effective_max_output_tokens,
        config_dir=cfg.dir,
        provider=backend,
        model=model,
        version=VERSION,
        api_key=api_key,
        servers=servers,
    )
    try:
        repl_instance.start()
    except KeyboardInterrupt:
        print("\nInterrupted.")
    finally:
        logger.close()


# Register every server in settings.yaml's `mcp_servers:` block. This is the
# agent's ONLY source of tools — boukensha ships none of its own. Nothing
# here knows what any particular server does; a MUD daemon and a filesystem
# server are registered by the identical code path.
#
# A server marked required=False that fails to spawn is a warning, not a
# fatal error — the agent runs without its tools. A name collision is never
# excused that way: it means the config asks for two tools with one name,
# and answering by dropping one of them silently is the worst option
# available.
#
# Returns {server_name: tool_count} for the servers that came up.
def _register_mcp_servers(registry, cfg: Config) -> dict:
    summary = {}
    for name, entry in cfg.mcp_servers().items():
        try:
            client = tools.mcp.register(
                registry,
                command=entry["command"],
                args=entry["args"],
                env=entry["env"],
                prefix=entry["prefix"],
            )
            summary[name] = len(client.tools)
        except tools.mcp.CollisionError:
            raise
        except Exception as e:
            if entry["required"]:
                raise RuntimeError(f"boukensha: MCP server '{name}' failed to start: {e}") from e
            print(
                f"[boukensha] optional MCP server '{name}' failed to start: {e} "
                "— continuing without its tools",
                file=sys.stderr,
            )
    return summary
