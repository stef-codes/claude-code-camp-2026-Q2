# Week 1 — Baseline MUD Agent (BOUKENSHA)

My goal for Week 1 was to actually *understand* the baseline agent framework
(BOUKENSHA — the 13-step build from `00_config` to `12_context`) and get it
playing the MUD, not just run someone else's code. This is a self-directed
run: I built my own syllabus/study plan to structure the learning
(https://syllabi-green.vercel.app/) instead of following a fixed track.

## What I set out to do

- Understand every layer of the baseline agent by rebuilding it, not reading it.
- Get the agent to actually connect to and play the MUD.
- Decision I made early: **port the reference Ruby implementation to Python,
  step by step.** Re-implementing something 1:1 forces you to understand every
  line — you can't hand-wave past the parts you don't get.

## What I built

- **Ported all 13 steps (00 → 12) from Ruby to Python.** Each step is its own
  `uv` project under `week1_baseline/python/NN_stepname/`. The full stack:
  config, the core structs, the tool registry, the prompt builder (5 provider
  backends), the API client, the agent loop, the logger, the run-DSL, the
  REPL, the global executable, the MCP tool library, a terminal UI, and
  context management.
- **Made `boukensha` a real global command** — `uv tool install --editable`
  of the final step, so I can type `boukensha` from anywhere and it runs my
  live source.
- **Wired the agent to the MUD** and confirmed it actually plays: it logged in
  and described its starting room ("The Cozy Bakery," exit east to "A Road
  Through The Plains"). Seeing the agent decide *on its own* to call a `look`
  tool and report the room was the payoff moment.

## How it actually works (the things that clicked)

- **Talking to LLM providers with raw REST, no SDK.** This was the point of
  the design, and it landed: every provider's request/response shape is
  different (Anthropic vs OpenAI vs Gemini vs Ollama). The agent loop stays
  sane because each backend normalizes into one common response contract — the
  loop never sees a raw provider payload.
- **The agent ships zero tools.** From step 10 on, BOUKENSHA is an MCP *host*:
  every capability the agent has comes from an MCP server declared in config.
  The big realization was that **MCP is a wire protocol (JSON-RPC over stdio),
  not a library.** That's *why* my Python agent can drive the Ruby MUD daemon
  with no binding between them — it just spawns it as a subprocess and trades
  JSON lines.
- **Context management is real engineering, not magic.** Step 12 tracks token
  usage against the model's real context window, auto-compacts old messages
  when it gets full, has two independent circuit breakers (iteration count and
  token spend), and normalizes each provider's "thinking" output into one
  reasoning format.

## Problems I hit and how I solved them

- **`tasks.player.model is required` on launch.** The command couldn't find my
  config. It looks in `~/.boukensha` by default, but my config lives at the
  repo root's `.boukensha/`. Fixed it with a `~/.boukensharc` pointing
  `boukensha_dir` at the real path. Lesson: config/env resolution is a top
  real-world failure mode — the code was fine, the *pathing* wasn't.
- **`boukensha: command not found`** even after installing. The tool's bin
  directory wasn't on my `PATH`; `uv tool update-shell` fixed it. A "global
  command" isn't global until PATH says so.
- **The agent flat-out refused to play the MUD**, claiming to be "a sandboxed
  AI with no network access." That was a lie the model made up — the real
  cause was that it **had no tools**: my `settings.yaml` had no `mcp_servers:`
  block, so there was literally nothing it could call, and it confabulated an
  excuse. A tool-less agent can only talk. This was the most instructive bug of
  the week: *tools define what an agent can do.*
- **The MUD bridge was missing entirely.** Digging in, my copy of
  `week0_explore/mud_manager` was a **stripped-down** version — just the telnet
  session and command builders, not the MCP server that exposes them. The full
  daemon existed in the upstream repo and had simply been left out of my fork.
  I synced it in, added the `mcp_servers:` config, and it worked end to end.
- **Textual TUI bugs (during the port).** Substituting Python's Textual for
  Ruby's `charm` surfaced three real bugs — an attribute name that collided
  with the framework's own, Rich-markup escaping on literal bracket text, and
  cross-thread UI calls. I only caught them by driving the UI through Textual's
  headless test harness, not by looking at it.

## What I learned

- **Tools define capability.** The model is just a text engine; what it can
  *do* is entirely the tools you give it. No tools = it can only converse (and
  will bluff about why).
- **MCP is language-agnostic plumbing.** Because it's stdio + JSON-RPC, the
  agent and its tool servers can be written in completely different languages.
- **Docker and MCP are unrelated layers.** Docker runs the MUD game server;
  MCP is how my agent talks to the daemon that telnets into it. Neither depends
  on the other.
- **Config/environment resolution causes more "it's broken" moments than the
  actual code.** Half my debugging was pathing and PATH, not logic.
- **Porting 1:1 is the best way to actually understand a framework.** I know
  this codebase far better than I would have from just running it.

## What's still rough / what's next

- **Optional Phase 2:** port the Ruby MUD daemon to Python too, for a
  single-language stack and to learn the MCP *server* side (I've only built the
  client side so far). Not required — the Ruby daemon works fine.
- **MUD credentials** are still the placeholder `dummy` character sitting in
  `settings.yaml`; I should swap in a real character and get the secrets out of
  the tracked config.
- Push the agent past "look" — actually navigate, fight, and complete a task in
  the MUD, and see where its lack of memory/planning shows.
