from __future__ import annotations

from .message import Message
from .tool import Tool


class Context:
    def __init__(self, task=None, system: str | None = None) -> None:
        self.task = task
        self.system = system
        self.messages: list[Message] = []
        self.tools: dict[str, Tool] = {}

    def register_tool(self, tool: Tool) -> None:
        self.tools[tool.name] = tool

    def add_message(self, role: str, content: str, tool_use_id: str | None = None) -> None:
        self.messages.append(Message(role, content, tool_use_id))

    # Drop all conversation history, keeping tools and system prompt intact.
    # Used by the REPL's `/clear` command.
    def clear_messages(self) -> None:
        self.messages = []

    @property
    def tool_count(self) -> int:
        return len(self.tools)

    @property
    def turn_count(self) -> int:
        return len(self.messages)

    def __repr__(self) -> str:
        task_name = self.task.task_name() if self.task else ""
        return f"#<Context task={task_name} turns={self.turn_count} tools={self.tool_count}>"
