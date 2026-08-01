# Boukensha observability

Boukensha emits OpenTelemetry traces and keeps its existing JSONL session log.
The instrumentation contract is pinned to **OpenTelemetry GenAI semantic
conventions 1.37.0**. Attribute changes require an explicit compatibility
review even when SDK dependencies are upgraded.

Two backends are supported and they are not alternatives so much as different
questions:

| | local collector (Jaeger / Tempo) | Langfuse Cloud |
| --- | --- | --- |
| answers | "where did the time go, what called what" | "what did the model see, what did it say, was it right" |
| needs | Docker | an account and two keys |
| gets you | span tree, latency, errors | the above **plus** prompts, responses, token cost, scores, prompt versions, datasets |

Langfuse is what this repo is currently pointed at, because agent debugging is
mostly a content problem. The local stack stays here and still works.

## Status

Everything below is built, live-verified against the Langfuse API, and covered
by `test/test_langfuse_attributes.rb`, which pins the literal attribute names —
the failure that motivated it was a naming failure, not a logic one.

| Capability | State |
| --- | --- |
| Nested spans following real control flow | done (predates this work) |
| Session grouping (`session.id`) | done (predates this work) |
| Prompts / responses / tool I/O visible in Langfuse | **fixed** — see below |
| Model + token usage on the generation span | done |
| Scores (`navigate.arrived`, `position.known`, …) | done |
| Prompt management with file fallback | done — `boukensha-player-system` v1 live |
| Dataset export from real failures | done — `bin/boukensha-dataset` |

## The bug that made tracing look useless

Content was written with `span.add_event(...)`. **Langfuse reads span
attributes and does not read span events at all**, so every trace showed
`input: EMPTY, output: EMPTY` and turning `capture_content` on appeared to do
nothing. The exporter now writes `langfuse.observation.input` / `.output`
(`telemetry/open_telemetry.rb`).

A second, quieter miss: `logger.prompt` / `request` fire *before* `call_model`
opens the `chat` span and `response` fires *after* it closes, so the one
observation carrying model and token usage had nothing to show. `capture_io`
puts the I/O on the generation where it belongs. A `chat` span now reads:

```
type: GENERATION | model: claude-haiku-4-5 | usage: in 3529, out 75
input : [{"role":"user","content":"look around and tell me who is here"}, …]
output: [{"type":"tool_use","name":"tbamud__check", …}]
```

### Attribute names Langfuse actually reads

Changing any of these silently empties a pane, which is why they are pinned in
a test rather than left to the exporter's judgement.

| Attribute | Set in |
| --- | --- |
| `langfuse.observation.input` / `.output` | `telemetry/open_telemetry.rb` |
| `langfuse.observation.metadata.<phase>` | `telemetry/open_telemetry.rb` |
| `langfuse.session.id` (alias `session.id`) | `logger.rb` |
| `langfuse.trace.name`, `langfuse.trace.tags` | `agent.rb` (root span only) |
| `langfuse.observation.prompt.name` / `.version` | `agent.rb` |

## Scores

Scores are the one thing that cannot ride OTLP — they are a Langfuse concept
posted to its own REST endpoint, so `telemetry/langfuse.rb` is the only
vendor-specific HTTP in the codebase. It queues in memory and flushes once when
the Logger closes: **never blocks a turn, never raises, disabled without
credentials.**

What is scored is what the agent already computed and previously threw away as
prose:

| Score | Meaning |
| --- | --- |
| `navigate.arrived` | BOOLEAN — did the route actually end where it was aimed |
| `navigate.steps` | how far it walked |
| `explore.rooms_added` | new rooms a delegated explore produced (0 is a failure) |
| `position.known` | can the agent name the room it is standing in |
| `localization.candidates` | how ambiguous that answer is (>1 is a failure) |

`after_turn` is **not** once per turn — it fires on every agent-loop exit and,
since delegated subagents share the parent's hooks, once more per subagent. The
first version wrote eight `position.known` samples for one prompt. It is now
guarded to depth 0 plus a state-change check: one sample per distinct state.

## Prompt management

With `observability.prompts.enabled`, system prompts are fetched from Langfuse
as `boukensha-<task>-system` at label `production` (`tasks/base.rb`), so a
prompt can be edited, versioned and rolled back in the UI **with no redeploy**,
and a trace records which version produced it.

Resolution order is Langfuse → user override under `prompts/` → the shipped
default. `PromptRegistry#fetch` returns `nil` on *any* failure — no credentials,
timeout, 404, malformed body — so a Langfuse outage cannot stop the agent
booting. Results are memoized for the process, **misses included**, or an
unpushed prompt would pay the timeout on every lookup.

Currently pushed: `boukensha-player-system` v1. `explorer` and `relocalizer`
still resolve from disk, which is the fallback path working as designed.

Push one with the API:

```sh
set -a && . .boukensha/.env && set +a
curl -sS -u "$LANGFUSE_PUBLIC_KEY:$LANGFUSE_SECRET_KEY" \
  -H 'content-type: application/json' \
  -d "$(jq -n --rawfile p .boukensha/prompts/explorer/system.md \
        '{name:"boukensha-explorer-system",type:"text",prompt:$p,labels:["production"]}')" \
  "$LANGFUSE_BASE_URL/api/public/v2/prompts"
```

## Dataset export

`bin/boukensha-dataset` promotes failed turns into a Langfuse dataset, so an
eval set accumulates for free just by working normally.

```sh
bin/boukensha-dataset --profile dummy          # dry run — what would be pushed
bin/boukensha-dataset --profile dummy --push   # actually send
```

Dry run is the default deliberately: it writes to a shared Langfuse project.

It reads the **session JSONL, not the Langfuse API** — pulling traces out of
Langfuse to push them back in would make the eval set depend on the thing being
evaluated, and the jsonl is complete whether or not tracing was on. Selection is
narrow on purpose (`DatasetExport::FAILURES`); a dataset of everything is a log.
Each item carries `sourceTraceId`, so a failing case is one click from the run
that produced it.

Dataset `boukensha-failures` currently holds one item — scoring only started
recently, so the count grows with use. Around 15–20 traces is where regression
testing starts being worth running.

## Langfuse Cloud setup

Credentials live in `.boukensha/.env`, which is gitignored — **never in YAML**.

```sh
LANGFUSE_PUBLIC_KEY=pk-lf-…
LANGFUSE_SECRET_KEY=sk-lf-…
LANGFUSE_BASE_URL=https://us.cloud.langfuse.com
OTEL_SERVICE_NAME=boukensha
OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=https://us.cloud.langfuse.com/api/public/otel/v1/traces
OTEL_EXPORTER_OTLP_TRACES_HEADERS=Authorization=Basic%20<base64 of public:secret>
```

The same three `LANGFUSE_*` keys configure traces, scores, prompts and dataset
export, so there is one place to put credentials and nothing to keep in sync.

Cloud over self-hosted is a deliberate call for a teaching repo: self-hosting
means Docker Compose with ClickHouse, Redis and blob storage. The free cloud
tier costs a signup.

```yaml
observability:
  otel:
    enabled: true
    capture_content: true    # prompts, responses and MUD transcripts leave the machine
    content_max_bytes: 4096
  prompts:
    enabled: true            # separate switch: this one makes a network call at boot
```

`capture_content: true` ships full prompts, model responses and MUD transcripts
to Langfuse Cloud. Redaction covers `authorization`, `api_key`/`api-key`,
`token`, `password`, `secret`, `credential` keys plus `Bearer …` and `sk-…`
values, capped at `content_max_bytes` per span. Set it `false` and only metadata
leaves the machine — model, provider, token counts, latency, span and tool
names.

`BOUKENSHA_OTEL_ENABLED`, `BOUKENSHA_OTEL_CAPTURE_CONTENT`,
`BOUKENSHA_OTEL_CONTENT_MAX_BYTES` and `BOUKENSHA_LANGFUSE_PROMPTS` override
YAML.

## Local collector stack

Still supported, and the better tool when the question is latency rather than
content. Only one profile should run at a time; every profile exposes the same
OTLP ports, so Boukensha configuration never changes.

| Profile | What starts | UI |
| --- | --- | --- |
| `debug` | Collector debug exporter and zPages | <http://localhost:55679/debug/tracez> |
| `jaeger` | Collector and Jaeger | <http://localhost:16686> |
| `tempo` | Collector, Tempo, and Grafana | <http://localhost:3001/explore> |
| `compare` | Collector fan-out, Jaeger, Tempo, and Grafana | both UIs |

From the repository root:

```sh
docker compose -f week2_capable/observability/docker-compose.yml --profile jaeger up
docker compose -f week2_capable/observability/docker-compose.yml --profile jaeger down
```

Add `--volumes` to also erase saved Tempo and Grafana development data.

Jaeger is the recommended first visual test; `debug` is the smallest transport
smoke test; `compare` sends each accepted batch to both backends so the same
JSONL `trace_id` can be checked in both UIs.

Point Boukensha at it instead of Langfuse:

```sh
export BOUKENSHA_OTEL_ENABLED=true
export OTEL_SERVICE_NAME=boukensha
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_TRACES_EXPORTER=otlp
```

Each top-level turn is a separate trace. Search `session.id` or
`boukensha.session_id` to find all turns in one session. In Grafana Explore,
select the provisioned Tempo data source:

```traceql
{ resource.service.name = "boukensha" }
```

All exposed ports bind to `127.0.0.1`; these development services have no
authentication and should not be exposed publicly. Grafana defaults to port
`3001` because the week 2 development environment may already use `3000`;
override with `BOUKENSHA_GRAFANA_PORT=3010`.

## Not done

- **LLM-as-a-judge scoring.** Every score here is deterministic — something the
  agent already knew. Judging subjective quality (was the route sensible, was
  the room description usefully summarised) is unimplemented.
- **`explorer` and `relocalizer` prompts are not in Langfuse**, so they cannot
  be rolled back from the UI. Push them with the curl above when wanted.
- **The dataset is not yet run as a regression suite** — items are collected,
  nothing replays them.
