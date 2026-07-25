# 00 · Configuration (Python port)

Python port of [`ruby/00_config`](../../ruby/00_config/README.md). Same
behavior and config schema as the Ruby version, ported idiomatically — see
the "Differences from Ruby" section below for the couple of deliberate
deviations.

We want to able to manage all configurations from an external file eg. `~/.boukensha/settings.yaml`
We want a dedicated class to handle configuration. eg. `boukensha.Config`
Please consider that as we add configuration in each iteration we will be updating the configuration schema and class.
We can hardcode defaults but we should not hardcode configurable values.

Configuration is organised by **task** — a role in the agentic loop bound to its
own LLM. week1_baseline only drives a single `player` task (the main loop), but
a more advanced loop will assign different LLMs to different tasks. A task is
either a "single-task" or a "multi-task" — the latter being a full agent.

## Design Considerations

We want to use the standard library as much as possible avoiding external packages. We need `pyyaml` to parse `settings.yaml`/`settings.yml` and `python-dotenv` to load `.env` files. Dependencies are managed with `uv`.

## Code Changes

| File | Purpose |
|------|---------|
| `boukensha/config.py` | `Config` class |
| `boukensha/tasks/base.py` | abstract `Base` (provider/model + prompt resolution) |
| `boukensha/tasks/player.py` | concrete `Player` (the main loop) |
| `boukensha/__init__.py` | top-level exports |
| `prompts/system.md` | default system prompt shipped with the library |
| `examples/example.py` | runnable smoke-test |
| `pyproject.toml` | `uv`/hatchling project + dependencies |

---

## Config directory resolution

The class looks for a `.boukensha/` directory in this order:

1. **`BOUKENSHA_DIR` env var** — set this to point at any directory you like.
2. **`~/.boukensha`** — the default location for a real install.

## Config directory structure

The class expects the following:

```
.boukensha/
  .env                 # stores credentials eg. LLMs APIs (never committed to repo)
  settings.yaml        # all non-secret settings (settings.yml also accepted)
  prompts/
    <task>/
      system.md        # per-task override for the default system prompt (optional)
```

---

## Tasks

`boukensha.tasks.base.Base` is an abstract stateless class. All behaviour is
expressed as classmethods that accept a `settings` dict — no instances are
created. Concrete subclasses define `_task_name`. For now only
`boukensha.tasks.player.Player` exists; future steps add per-turn ceilings
(`max_iterations`, `max_turn_tokens`, `max_output_tokens`,
`compaction_threshold`) — these are **not** read yet.

`Config.tasks()` returns the raw dict from `settings.yaml` under `tasks:`. Pass a
name to look up a specific task's settings dict, then pass it to the stateless
class:

```python
Player.provider(config.tasks("player"))
Player.system_prompt(
    config.tasks("player"),
    user_prompts_dir=config.user_prompts_dir,
    default_prompts_dir=Config.PROMPTS_DIR,
)
```

## System prompt resolution

Per task, `Player.system_prompt` is resolved in this order:

1. **`.boukensha/prompts/<task>/system.md`** — used when the task's
   `prompt_override.system` is `true` and the file exists.
2. **`prompts/system.md`** — the default system prompt shipped with the library.

(We no longer use a top-level `system.override`; override is now per-task via
`prompt_override.system`.)

## Configuration Schema

The following properties so far:
- `tasks`: a map of task name → task config (provider, model, prompt_override).
- `tasks.<name>.prompt_override.system`: when `true`, the task's
  `.boukensha/prompts/<name>/system.md` overrides the default system prompt.
- `mud`: MUD connection information for the main player.

```yaml
tasks:
  player:
    provider: anthropic        # provider name (string)
    model: claude-haiku-4-5
    prompt_override:
      system: true
mud:
  host: localhost
  port: 4000
  username: dummy
  password: helloworld
```

## Run Example

```bash
./week1_baseline/bin/python/00_config
```

(or, equivalently, `./week1_baseline/bin/00_config --python` / `BOUKENSHA_LANG=python ./week1_baseline/bin/00_config` from the language-aware wrapper.)

Expected output (values from your `.boukensha/`):

```
=== Boukensha Step 0: Configuration ===

Config dir:     /home/andrew/Sites/Claude-Code-Camp/.boukensha
Tasks:          player

-- player task --
Provider:       anthropic
Model:          claude-haiku-4-5
Prompt override?True
System prompt:  You are a MUD player assistant. Use the tools available to y...

MUD host:       localhost:4000
MUD user:       dummy

API key set?    True

#<Boukensha::Config dir=/home/andrew/Sites/Claude-Code-Camp/.boukensha tasks=player>
```

## Differences from Ruby

- **`.yaml` / `.yml`** — the Python port accepts either `settings.yaml` or
  `settings.yml` (tried in that order). This was a known Ruby limitation
  (hardcoded to `.yaml` only) that we chose to fix on the Python side only;
  the Ruby version is unchanged.
- **No string/symbol key duality** — Ruby's `YAML.safe_load` can hand back
  either string or symbol keys, so `Config#dig`/`#tasks` check both. Python's
  `yaml.safe_load` only ever produces `str` keys, so that dance isn't needed.
- **No test suite** — matches Ruby; `examples/example.py` is the only
  smoke test, no `pytest` coverage added for this step.

## Considerations

These are things we don't want fixed to not break:
- not scoped based on tasks
