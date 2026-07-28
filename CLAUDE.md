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
terminal REPL for step 11+. Steps 9+ have a pytest suite (`uv run pytest`).

### The global `boukensha` command (installed)

`boukensha` is installed globally as an **editable** install of step 12:
```bash
uv tool install --editable ./week1_baseline/python/12_context
```
Because it's editable, the tool venv imports straight from
`week1_baseline/python/12_context/` — any source edit there is reflected the
next time you run `boukensha`, no reinstall needed. To rebuild anyway (e.g.
after changing dependencies): `uv tool install --editable --reinstall …`.
To switch the global command to a different step, reinstall from that step's
dir, or set `BOUKENSHA_PATH` / `boukensha_path:` in `~/.boukensharc`.

The executable lives in uv's tool bin dir (`uv tool dir --bin` →
`~/.local/bin`). `uv tool update-shell` added that dir to PATH via a
generated `~/.zshenv` — if `boukensha` ever reports "not found", that's the
first thing to check. The non-idiomatic
`packages = ["boukensha", "boukensha_loader.py"]` in the step pyproject
builds fine under hatchling (verified), so no `force-include` workaround was
needed.

### Config-directory resolution (a common "why won't it run" trap)

The runtime config dir (`.env`, `settings.yaml`, `prompts/`) lives at the
**repo root** `.boukensha/`. Steps 9–12 resolve it in this order:
`BOUKENSHA_DIR` env var → `boukensha_dir:` in `~/.boukensharc` →
`~/.boukensha` (which does **not** exist on this machine).

The `bin/python/NN` wrappers `cd` into the step directory before launching,
so a bare `./week1_baseline/bin/python/12_context` will NOT find the
repo-root config on its own and dies with `tasks.player.model is required`.
Two fixes are in place / available:
- `~/.boukensharc` **is set up** with
  `boukensha_dir: /Users/stefanie/code/claude-code-camp-2026-Q2/.boukensha`,
  so the wrappers now work with no env var. If it goes missing, recreate it.
- Or prefix any run with `BOUKENSHA_DIR="$(pwd)/.boukensha"` from the repo
  root.

Note the placeholder `~/Sites/...` paths in some step READMEs are
illustrative, not literal for this machine. `boukensha` **is** now on `$PATH`
(editable install of step 12 — see the global-command section above); you can
also launch any step through its `bin/` wrapper.

## MUD tool — wired up and working

The agent can now play the MUD. `week0_explore/mud_manager/` was synced from
upstream `main` (it had been a stripped copy — only `session.rb` +
`primitives.rb`; the full MCP daemon under `bin/mud-manager` +
`lib/mud_manager/mcp/*` + `fake_mud.rb` + tests is now present). It's
stdlib-only Ruby; `bin/mud-manager` self-bootstraps its `$LOAD_PATH`, so no
`gem install`/`bundle` is needed.

`.boukensha/settings.yaml` now has an `mcp_servers: mud:` block that spawns
`ruby …/mud-manager --mcp` and registers its **26 tools** under the `tbamud`
prefix. Verified end to end: the global `boukensha` shows `servers: mud (26)`
and the agent autonomously calls `tbamud__look` etc. — it logged in as the
`dummy`/`helloworld` character (a real char on the running MUD) and described
the starting room ("The Cozy Bakery"). Cross-language works because MCP is a
stdio JSON-RPC protocol: Python agent spawns the Ruby daemon, no binding.

A future Python port of the daemon is optional (Phase 2 in the plan file) —
not needed for correctness.

## Known limitations in this environment

- Since the `mud-manager` binary is now present, the step 10–12 Python
  pytest tests that used to **skip** on its absence
  (`test/helper.py::mud_manager_available`) may now execute instead — I
  haven't re-run the full suites since the sync, so don't assume "12 skip"
  is still the baseline there.
- **Ruby can't actually run for steps 11 and 12** in this environment —
  the `charm` gem family (bubbletea, lipgloss, bubbles, etc.) was never
  `bundle install`ed and requires a Go toolchain to build natively, which
  isn't set up here. Verification for those steps' Ruby-side logic was
  done by requiring individual Ruby files directly (bypassing the
  `lib/boukensha.rb` top-level require chain that pulls in `tui.rb`) —
  see how `Config`/`Context`/`Models` were cross-checked this way if you
  need to do it again.
- The `ANTHROPIC_API_KEY` in `.boukensha/.env` is now a **working** key
  (verified: live agent turns succeed — `PONG` test + real MUD play). Earlier
  in the project history it was a placeholder that 401'd, so older notes that
  say "every live call 401s" are stale.

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
