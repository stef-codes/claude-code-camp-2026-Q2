from __future__ import annotations

from typing import Callable

from .errors import UnknownToolError
from .tool import Tool


class Registry:
    def __init__(self, context) -> None:
        self.context = context

    def tool(
        self,
        name: str,
        *,
        description: str,
        parameters: dict | None = None,
        block: Callable | None = None,
    ) -> Tool:
        tool = Tool(str(name), description, parameters or {}, block)
        self.context.register_tool(tool)
        return tool

    @property
    def tool_names(self):
        return list(self.context.tools.keys())

    def dispatch(self, name: str, args: dict | None = None):
        args = args or {}
        tool = self.context.tools.get(str(name))
        if tool is None:
            raise UnknownToolError(f"No tool registered as '{name}'")
        return tool.block(**args)
