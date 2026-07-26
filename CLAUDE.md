# CLAUDE.md

Context for Claude Code sessions working in this repo. This file exists
because a lot of work happened across prior sessions before this file was
created — read it before assuming you need to rediscover things from
scratch.

## What this repo is

The official repo for the Claude Code Camp (run by ExamPro). It's a
teaching framework: **BOUKENSHA**, a step-by-step MUD-playing agent
built up one capability at a time (config → structs → tool registry →
prompt building → API client → agent loop → logging → DSL → REPL → global
executable → MCP tools → TUI → context management).

Top-level layout:

```
week0_explore/     # CircleMUD Docker setup, mud_manager gem, exploration docs
week1_baseline/    # THE MAIN CONTENT — the 13-step agent build, Ruby + Python
week2_capable/     # (not yet started)
.boukensha/        # shared runtime config used by every step (.env, settings.yaml, prompts/)
docs/plans/        # port planning docs (see below)
```

`week1_baseline/ITERATIONS.md` has the original design brief for what the
week-1 baseline agent needed to cover.

## week1_baseline: the step structure

```
week1_baseline/
  ruby/NN_stepname/     # the original Ruby implementation (upstream, canonical)
  python/NN_stepname/   # a 1:1 Python port of the same step
  bin/NN_stepname            # language-aware dispatcher: ruby by default, --python or BOUKENSHA_LANG=python to switch
  bin/python/NN_stepname     # convenience wrapper that always runs the Python version
```

Steps, in order: `00_config`, `01_struct_skeleton`, `02_the_registry`,
`03_prompt_builder`, `04_api_client`, `05_agent_loop`, `06_the_logger`,
`07_the_run_dsl`, `08_the_repl_loop`, `09_global_executable`,
`10_standard_tool_library`, `11_tui`, `12_context`.

Each `python/NN_stepname/README.md` documents exactly what that step adds
over the previous one, and has a "Differences from Ruby" section calling
out every intentional deviation. **Read the step's own README before
touching its code** — this file only has the cross-cutting picture.

### Where the Ruby source came from

The user's fork didn't have steps past `01_struct_skeleton`. The rest
(`02` through `12`) were copied from the upstream template repo,
`github.com/omenking/claude-code-camp-2026-Q2`, branch `week_2`, via a
sparse shallow clone. If you need to re-diff against upstream, that's the
branch to use — it does not exist in this fork.

## The Python port

**Status: complete.** All 13 steps have a working Python implementation,
each verified against its Ruby counterpart. This was the single biggest
piece of work done in prior sessions — the summary below is the "how" and
"why," not a changelog.

### Porting methodology (apply this if extending further)

1. Diff the Ruby step against the *previous* Ruby step (not against the
   whole codebase) to find exactly what changed.
2. Copy the previous Python step forward as the starting point (`rsync`,
   minus `.venv`/`__pycache__`/`uv.lock`).
3. Apply only the delta identified in step 1 to the Python copy.
4. Verify: run the Python version live against the real `.boukensha/`
   config and compare against Ruby's actual behavior wherever Ruby can
   still run in this environment (it often can't — see Known
   Limitations). A live Anthropic API call failing with `401 invalid
   x-api-key` at the same point in both languages is the standard
   cross-language correctness signal used throughout (the configured key
   is a placeholder, not a real credential).

**Standing policy: preserve Ruby's exact behavior — bugs included —
unless a deviation is explicitly authorized, or the bug actively breaks
the demo** (in which case fix it and flag the deviation in that step's
README, don't silently diverge). Several genuine upstream Ruby quirks were
identified and *kept* this way (e.g. a dormant off-by-one in a
`PROMPTS_DIR` path in one step that never actually gets exercised; usage
extraction in `agent.py`/`agent.rb` for step 12 only reads the `"usage"`
key, so it's only accurate for the Anthropic/OpenAI backends — Gemini's
usage lives under a different key entirely, and that's how Ruby has it
too). Check a given step's README "Differences from Ruby" section before
assuming something is a Python-side bug — it might be intentional parity.

### Toolchain

- Python: `uv` + `hatchling`, `requires-python >= 3.14`. Install `uv` via
  `brew install uv` if missing.
- Each `python/NN_stepname/` is an independent `uv` project with its own
  `pyproject.toml` and `.venv`.
- pytest is used **only** where upstream Ruby itself added tests — that's
  `09_global_executable` onward (loader resolution, MCP client, MCP
  server config, MCP tool registration). Every step before that
  deliberately has no test suite, matching Ruby.
- Step 11 (`11_tui`) is **not** a literal port — Ruby's TUI is built on
  `charm` (a Go/C-backed bubbletea/lipgloss/bubbles binding) with no
  Python equivalent. The Python TUI is a from-scratch rebuild against
  [Textual](https://textual.textualize.io/), chosen for full feature
  parity (spinner, live progress, four-zone layout, keyboard shortcuts,
  background-thread agent execution) rather than a 1:1 code translation.
  This was an explicit user decision, not an assumption.

### How to run any step

```bash
./week1_baseline/bin/python/<step-name>
# or, via the language-aware dispatcher:
./week1_baseline/bin/<step-name> --python
BOUKENSHA_LANG=python ./week1_baseline/bin/<step-name>
```

Steps 7+ support the REPL/TUI directly; `--no-tui` falls back to a plain
terminal REPL for step 11+. Steps 9+ install as a `boukensha` executable
(`uv tool install .` inside that step's directory) and have a pytest
suite (`uv run pytest`).

All steps read config from `.boukensha/` at the repo root by default
(`BOUKENSHA_DIR` env var overrides this). That directory holds `.env`
(API keys — currently a placeholder, not a real key), `settings.yaml`,
and `prompts/`.

## Known limitations in this environment

- **The real `mud-manager` binary is absent** (`week0_explore/mud_manager`
  doesn't have it built in this checkout). Any test or demo that needs a
  live MCP MUD server skips gracefully rather than failing — this is
  expected, not a regression. Affects steps 10, 11, 12 (10 pass / 12 skip
  is the normal pytest result for each).
- **Ruby can't actually run for steps 11 and 12** in this environment —
  the `charm` gem family (bubbletea, lipgloss, bubbles, etc.) was never
  `bundle install`ed and requires a Go toolchain to build natively, which
  isn't set up here. Verification for those steps' Ruby-side logic was
  done by requiring individual Ruby files directly (bypassing the
  `lib/boukensha.rb` top-level require chain that pulls in `tui.rb`) —
  see how `Config`/`Context`/`Models` were cross-checked this way if you
  need to do it again.
- The configured `ANTHROPIC_API_KEY` in `.boukensha/.env` is not a real
  credential — every live-API check in this repo relies on getting a
  `401` at exactly the right point, not on a successful completion.

## Documentation debt / things worth knowing

- `docs/plans/python_port/` has the original per-step port plans for
  `00_config` and `01_struct_skeleton` (written and executed via
  `AskUserQuestion`-driven planning before the "port everything" request
  came in). Steps `02` onward were ported directly without individual
  plan docs, following the methodology above.
- Every `python/NN_stepname/README.md` was, at one point, a stale
  copy-paste of the `01_struct_skeleton` README (an artifact of the
  rsync-forward porting method — the file gets copied before it gets
  rewritten, and the rewrite step was originally skipped for steps 02–11).
  This has been fixed — every step's README is now accurate — but if you
  ever see a Python step's README describing `Tool`/`Message`/`Context`
  dataclasses when the step is clearly about something else, that stale-copy
  bug has recurred and needs the same fix: read the corresponding
  `ruby/NN_stepname/README.md`, diff it against the previous step's Ruby
  README, and rewrite.
