from __future__ import annotations


class PromptBuilder:
    def __init__(self, context, backend) -> None:
        self.context = context
        self.backend = backend

    def to_messages(self):
        return self.backend.to_messages(self.context.messages)

    def to_tools(self):
        return self.backend.to_tools(self.context.tools)

    def to_api_payload(self, *, max_output_tokens: int = 1024) -> dict:
        return self.backend.to_payload(self.context, max_output_tokens=max_output_tokens)

    @property
    def headers(self) -> dict:
        return self.backend.headers

    @property
    def url(self) -> str:
        return self.backend.url
