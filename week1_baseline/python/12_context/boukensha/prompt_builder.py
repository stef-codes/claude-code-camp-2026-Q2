from __future__ import annotations


class PromptBuilder:
    def __init__(self, context, backend) -> None:
        self.context = context
        self.backend = backend

    def to_messages(self):
        return self.backend.to_messages(self.context.messages)

    def to_tools(self):
        return self.backend.to_tools(self.context.tools)

    def to_api_payload(self, *, max_output_tokens: int = 1024, tools: list | None = None) -> dict:
        return self.backend.to_payload(
            self.context, max_output_tokens=max_output_tokens, tools=tools
        )

    # Delegates to the backend, which normalizes a provider response into
    # the common shape documented in backends.base.Base.
    def parse_response(self, response: dict) -> dict:
        return self.backend.parse_response(response)

    @property
    def headers(self) -> dict:
        return self.backend.headers

    @property
    def url(self) -> str:
        return self.backend.url
