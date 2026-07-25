from .config import Config
from .tasks.player import Player
from .tool import Tool
from .message import Message
from .context import Context
from .errors import UnknownToolError, ApiError, UnsupportedModelError
from .registry import Registry
from .prompt_builder import PromptBuilder
from .logger import Logger
from .client import Client
from .agent import Agent
from . import backends

__all__ = [
    "Config",
    "Player",
    "Tool",
    "Message",
    "Context",
    "UnknownToolError",
    "ApiError",
    "UnsupportedModelError",
    "Registry",
    "PromptBuilder",
    "Logger",
    "Client",
    "Agent",
    "backends",
    "config",
    "enable_quiet",
    "disable_quiet",
    "is_quiet",
    "enable_debug",
    "is_debug",
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
