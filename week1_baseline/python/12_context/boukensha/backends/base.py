from __future__ import annotations

from ..errors import UnsupportedModelError


class Base:
    # Every backend's parse_response() returns:
    #   {"stop_reason": "tool_use" | "end_turn", "content": [<block>, ...]}
    # where each block is one of:
    #   {"type": "reasoning", "text": "...", "signature": "...", "redacted": bool}
    #   {"type": "text", "text": "..."}
    #   {"type": "tool_use", "id": ..., "name": ..., "input": {...}}
    # Reasoning blocks come first, matching Anthropic's native ordering.
    # "signature"/"redacted" are opaque carry-through for providers that
    # require the block echoed back unchanged (Anthropic thinking
    # signatures, Gemini thoughtSignature) — backends that don't accept
    # reasoning back in a request drop these blocks when rebuilding
    # assistant turns.
    MODELS: dict = {}

    @classmethod
    def models(cls) -> dict:
        if not cls.MODELS:
            raise NotImplementedError(f"{cls.__name__} must define MODELS")
        return cls.MODELS

    @classmethod
    def model_info_for(cls, model: str) -> dict | None:
        return cls.models().get(str(model))

    @classmethod
    def validate_model(cls, model: str) -> str:
        model = str(model)
        if cls.model_info_for(model):
            return model

        supported = ", ".join(sorted(cls.models().keys()))
        raise UnsupportedModelError(
            f"{cls.__name__} does not support model {model!r}. Supported models: {supported}"
        )

    def __init__(self) -> None:
        self.model: str | None = None
        self._model_info: dict = {}

    @property
    def model_info(self) -> dict:
        return self._model_info

    @property
    def context_window(self):
        return self._model_info["context_window"]

    @property
    def input_token_cost_per_million(self):
        return self._model_info["cost_per_million"]["input"]

    @property
    def output_token_cost_per_million(self):
        return self._model_info["cost_per_million"]["output"]

    @property
    def usage_unit(self):
        return self._model_info["usage_unit"]

    @property
    def usage_level(self):
        return self._model_info.get("usage_level")

    def estimate_cost(self, *, input_tokens: int, output_tokens: int) -> float | None:
        in_cost = self.input_token_cost_per_million
        out_cost = self.output_token_cost_per_million
        if in_cost is None or out_cost is None:
            return None

        return ((input_tokens * in_cost) + (output_tokens * out_cost)) / 1_000_000.0

    def _configure_model(self, model: str) -> None:
        self.model = self.validate_model(model)
        self._model_info = self.model_info_for(self.model)
