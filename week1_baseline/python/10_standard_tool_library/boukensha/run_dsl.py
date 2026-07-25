from __future__ import annotations

from typing import Callable


class RunDSL:
    # RunDSL is the object passed to the `register` callback of `boukensha.run`.
    # It exposes only `tool`, keeping the DSL surface intentionally small.
    def __init__(self, registry) -> None:
        self.registry = registry

    def tool(self, name: str, *, description: str, parameters: dict | None = None, block: Callable | None = None):
        return self.registry.tool(name, description=description, parameters=parameters, block=block)

    @property
    def tool_names(self):
        return self.registry.tool_names
