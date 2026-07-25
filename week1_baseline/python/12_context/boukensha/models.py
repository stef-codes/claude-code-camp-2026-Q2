from __future__ import annotations

from . import backends

# Static model -> capability table.
#
# `context_window` is a known *model* fact — the physical input ceiling — not
# a value the user sets. The agent looks it up from its configured model id;
# the user never configures it in settings.yaml. Unknown models fall back to
# a conservative default so an unrecognised id can't silently assume a huge
# window.
#
# Built from every backend's own MODELS dict rather than hand-maintained
# separately, so a model added to a backend is automatically sized correctly
# here too. Table is built lazily on first use.
DEFAULT_CONTEXT_WINDOW = 32_000

_BACKEND_CLASSES = lambda: [  # noqa: E731 - mirrors Ruby's lambda constant
    backends.Anthropic,
    backends.OpenAI,
    backends.Gemini,
    backends.Ollama,
    backends.OllamaCloud,
]

_table: dict | None = None


def table() -> dict:
    global _table
    if _table is None:
        _table = {}
        for backend_cls in _BACKEND_CLASSES():
            _table.update(backend_cls.MODELS)
    return _table


def context_window(model) -> int:
    info = table().get(str(model))
    return info["context_window"] if info else DEFAULT_CONTEXT_WINDOW
