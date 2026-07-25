# 03 · The Prompt Builder (Python port)

Python port of [`ruby/03_prompt_builder`](../../ruby/03_prompt_builder/README.md).
Built on top of the [`02_the_registry`](../02_the_registry/README.md) port.

Because LLM access, cost, and quality are constantly changing, BOUKENSHA
needs to switch between multiple LLM providers driving the agent loop.
`PromptBuilder` serializes `Context` into whichever API format the active
backend expects — it never calls the API itself, just prepares the payload.

Configuration is task-based, carried forward from the registry step: the
`player` task owns its provider, model, and prompt-override settings.

## New Files

| File | Purpose |
|------|---------|
| `boukensha/prompt_builder.py` | Delegates serialization to the active backend |
| `boukensha/tasks/base.py` | Abstract task helper for provider/model and prompt resolution |
| `boukensha/tasks/player.py` | The concrete player task used by the main loop |
| `prompts/system.md` | Default system prompt used when a task does not override it |
| `boukensha/backends/base.py` | Shared backend contract for model validation and metadata |
| `boukensha/backends/anthropic.py` | Serializes context into the Anthropic API format |
| `boukensha/backends/ollama.py` | Serializes context into the Ollama API format |
| `boukensha/backends/ollama_cloud.py` | Serializes context into the Ollama Cloud API format |
| `boukensha/backends/openai.py` | Serializes context into the OpenAI Chat Completions format |
| `boukensha/backends/gemini.py` | Serializes context into the Gemini `generateContent` format |

## How It Works

```
Context (Python objects)
        ↓
PromptBuilder
        ↓
Backend (Anthropic, OpenAI, Gemini, or Ollama)
        ↓
API payload (plain dicts and lists)
        ↓
POST to API
```

## `boukensha.PromptBuilder`

| Method | Description |
|--------|-------------|
| `to_messages()` | Delegates message serialization to the backend |
| `to_tools()` | Delegates tool serialization to the backend |
| `to_api_payload(*, max_output_tokens=1024, tools=None)` | Assembles the complete payload ready to POST |
| `headers` | The correct headers for the backend |
| `url` | The correct endpoint URL for the backend |

## Backends

Each API has its own conventions. Anthropic and Gemini are most alike
(system prompt as a top-level field), while OpenAI and Ollama share a
`function`-wrapped tool schema.

Backends also own their supported model table (`MODELS`) — a backend
refuses to configure with an unknown model, so `settings.yaml` cannot
silently select an unsupported or misspelled one. Each model entry carries
`context_window`, `cost_per_million.{input,output}`, `usage_unit`, and
optionally `usage_level`. Backend instances expose `context_window`,
`input_token_cost_per_million`, `output_token_cost_per_million`,
`usage_unit`, `usage_level`, and `estimate_cost(*, input_tokens, output_tokens)`.

| Provider | Backend | Endpoint | Requires |
|---|---|---|---|
| `anthropic` | `boukensha.backends.Anthropic` | `api.anthropic.com/v1/messages` | `ANTHROPIC_API_KEY` |
| `ollama` | `boukensha.backends.Ollama` | `localhost:11434/api/chat` | a local `ollama serve` |
| `ollama_cloud` | `boukensha.backends.OllamaCloud` | `ollama.com/api/chat` | `OLLAMA_API_KEY` |
| `openai` | `boukensha.backends.OpenAI` | `api.openai.com/v1/chat/completions` | `OPENAI_API_KEY` |
| `gemini` | `boukensha.backends.Gemini` | `generativelanguage.googleapis.com/.../generateContent` | `GEMINI_API_KEY` |

### System prompt placement

Anthropic and Gemini send the system prompt as a top-level field, separate
from the messages array. Ollama and OpenAI put it inside the messages array
as a `role: "system"` message.

### Tool results, tool definitions, message roles

All four shapes differ by provider — see `backends/*.py`'s `to_messages`/
`to_tools` for the exact wire format each one produces.

## Considerations

**The conversation is stateless.** The model has no memory between turns.
Every API call includes the entire history from the beginning; BOUKENSHA is
responsible for carrying that state.

**The agent only sees schemas.** A tool's `description` is the only thing
the agent uses to decide when to call it — the actual `block` never leaves
BOUKENSHA.

## Run Example

```bash
./week1_baseline/bin/python/03_prompt_builder
```

## Differences from Ruby

- **`model_info` classmethod renamed to `model_info_for`.** Ruby defines
  both a classmethod `model_info(model)` and a same-named instance method
  `model_info` (no args) — legal in Ruby's separate class/instance
  namespaces, impossible in Python's single namespace. The classmethod is
  `Base.model_info_for(model)`; the instance property stays `model_info`.
- **`backends` stays a submodule**, not flattened into the top-level
  `boukensha` namespace, mirroring Ruby's `Boukensha::Backends::X` nesting
  (`from boukensha import backends; backends.Anthropic(...)`).
- Carries forward the standing decisions from earlier steps: `.yaml`/`.yml`
  fallback fix (Python-side only), no pytest suite, `uv`/hatchling,
  `requires-python >=3.14`.
