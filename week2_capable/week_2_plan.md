# Bokensha Navigation Bot — Claude Code Build Plan

Source: architecture review recommending localization-first design (candidate-set localization,
directed graph with typed edges, replan-per-step navigation). Broken into session-sized chunks.

**Token estimate legend:**
- *Context* = rough size of what Claude Code needs to read/hold (existing files + this task's instructions)
- *Output* = rough size of code/response Claude Code will generate
- Each phase is sized to fit comfortably in one Claude Code session without needing to re-load large context mid-task

---

## Phase 0 — Project scaffold
**Goal:** repo structure, SQLite schema, config, no game logic yet.

| Step | Task | Context | Output |
|---|---|---|---|
| 0.1 | Init repo, `pyproject.toml`/`requirements.txt`, folder layout (`bokensha/{model,localize,graph,explore,mud,llm}`, `tests/`) | ~500 tok | ~800 tok |
| 0.2 | SQLite schema: `rooms`, `edges`, `observations` tables + migration script | ~800 tok | ~1.5k tok |
| 0.3 | Config loader (MUD host/port, thresholds like 0.35/0.30/0.20/0.15 weights, danger penalties) | ~500 tok | ~700 tok |

**Phase 0 total: ~1.8k context / ~3k output** — one session, trivial.

---

## Phase 1 — Parsing & data model
**Goal:** turn raw MUD text into structured data. This is step 1 of the doc's build order.

| Step | Task | Context | Output |
|---|---|---|---|
| 1.1 | `RoomObservation` dataclass + parser for title/exits/description from raw telnet text (with test fixtures of sample room text) | ~1k tok | ~2k tok |
| 1.2 | `MoveResult` enum + result classifier (moved/blocked/locked/interrupted/ambiguous) from command output text | ~1.5k tok (needs 1.1's dataclass) | ~1.8k tok |
| 1.3 | Unit tests for both parsers against 10–15 sample transcripts you paste in | ~2k tok (sample transcripts) | ~1.5k tok |

**Phase 1 total: ~4.5k context / ~5.3k output** — one session. Bring real MUD transcript samples; parser quality lives or dies on realistic fixtures.

---

## Phase 2 — Telnet/MUD connection layer
**Goal:** execute one move and classify its result (doc's step 2).

| Step | Task | Context | Output |
|---|---|---|---|
| 2.1 | Telnet client wrapper (connect, send command, read until prompt, handle ANSI stripping) | ~1k tok | ~2k tok |
| 2.2 | Wire parser (Phase 1) to live connection: send `north`, capture raw text, classify `MoveResult` | ~2.5k tok (needs 1.1, 1.2, 2.1) | ~1.2k tok |
| 2.3 | Manual smoke test script: connect, execute 5 moves, print classified results | ~1.5k tok | ~600 tok |

**Phase 2 total: ~5k context / ~3.8k output** — one session. Do this against the real MUD, not mocks — you need real edge cases for step 6.

---

## Phase 3 — Edge & room storage (directed graph)
**Goal:** persist rooms and directed transitions in SQLite (doc's step 3).

| Step | Task | Context | Output |
|---|---|---|---|
| 3.1 | `Edge` dataclass + repository layer (CRUD against `edges` table, keyed by `(source_id, command)` not room pairs) | ~1.5k tok (needs schema from 0.2) | ~2k tok |
| 3.2 | Room repository: create/get/update `RoomObservation` records, generate internal IDs (`room_001`...) | ~1.5k tok | ~1.5k tok |
| 3.3 | NetworkX graph builder: load edges from SQLite into a `DiGraph` with weights, sync-back on edge update | ~2k tok (needs 3.1) | ~2.5k tok |

**Phase 3 total: ~5k context / ~6k output** — one session.

---

## Phase 4 — Manual 5-room loop navigation (milestone #1)
**Goal:** the doc's explicit first milestone — inn → bakery → inn, zero LLM involvement.

| Step | Task | Context | Output |
|---|---|---|---|
| 4.1 | Hand-seed 5 rooms + edges directly into SQLite (a fixture/seed script) for a known loop | ~1k tok | ~1k tok |
| 4.2 | `execute_command()` — send command, classify result, update edge status (verified/blocked), advance `current_room` only on `MOVED` | ~2.5k tok (needs 2.2, 3.1) | ~1.5k tok |
| 4.3 | Dijkstra pathfinding wrapper over the NetworkX graph (`shortest_path(current, destination)`) — start simple, unweighted | ~1.5k tok | ~1k tok |
| 4.4 | Replan loop: execute path[0] only, re-localize/re-plan each step (doc's step 8 pattern) — **but localization is still "trust the position" here**, real localization comes in Phase 6 | ~2k tok (needs 4.2, 4.3) | ~1.8k tok |
| 4.5 | Integration test: run inn→bakery→inn end to end against the live MUD, assert edges get marked verified | ~1.5k tok | ~800 tok |

**Phase 4 total: ~8.5k context / ~6.1k output** — this is the milestone; give it its own session, possibly split 4.1–4.3 and 4.4–4.5 into two sessions if your MUD's inn/bakery area is unusually complex.

**⚠️ Do not proceed past this point until milestone #1 passes repeatedly.**

---

## Phase 5 — Frontier-based exploration (doc's step 5)
**Goal:** find and traverse unexplored exits automatically.

| Step | Task | Context | Output |
|---|---|---|---|
| 5.1 | Frontier tracker: query graph for `(room, unexplored_exit)` pairs | ~1.5k tok | ~1.2k tok |
| 5.2 | Nearest-frontier selection (closest room w/ unexplored exit, via existing Dijkstra) | ~1.5k tok | ~1k tok |
| 5.3 | Explore loop: navigate to frontier room → traverse the one unknown edge → record result → repeat | ~2k tok (needs 4.2–4.4, 5.1–5.2) | ~1.5k tok |
| 5.4 | (Optional, defer if time-boxed) `exploration_score` with information gain / danger penalty instead of pure nearest-frontier | ~1.5k tok | ~1.2k tok |

**Phase 5 total: ~6.5k context / ~4.9k output** — one session; 5.4 can be its own follow-up session later.

---

## Phase 6 — Duplicate-room candidate localization (doc's step 6, the hard part)
**Goal:** replace "trust current_room" with the candidate-set model. This is the core rewrite the review is really about.

| Step | Task | Context | Output |
|---|---|---|---|
| 6.1 | `location_candidates: dict[str, float]` structure + scoring function (title/exit/feature/transition match weights) | ~2k tok | ~1.8k tok |
| 6.2 | Candidate filtering after each move: narrow by commanded transition, compare new observation against candidate destinations | ~2.5k tok (needs 6.1, edge model) | ~2k tok |
| 6.3 | Wire candidate localization into the replan loop from 4.4, replacing the naive position tracking | ~3k tok (needs 4.4, 6.2) — **this is the riskiest merge, expect iteration** | ~2k tok |
| 6.4 | Test fixture: two rooms with identical title/exits, verify localizer disambiguates via transition match after 1–2 moves | ~1.5k tok | ~1k tok |

**Phase 6 total: ~9k context / ~6.8k output** — split into two sessions: (6.1–6.2) then (6.3–6.4), since 6.3 touches Phase 4 code and benefits from a fresh context focused only on that diff.

---

## Phase 7 — Weighted routing & danger avoidance (doc's step 7)
**Goal:** upgrade from unweighted Dijkstra to cost-aware routing.

| Step | Task | Context | Output |
|---|---|---|---|
| 7.1 | Edge cost function (`1 + danger*5 + failure_rate*3 + conditional_penalty`) wired into graph weights | ~1.5k tok | ~1k tok |
| 7.2 | Failure-rate tracking on edges (increment on blocked/locked/interrupted, decay or cap) | ~1.5k tok | ~1k tok |
| 7.3 | Re-test milestone-1 loop plus one deliberately dangerous route, confirm Dijkstra avoids it | ~1.5k tok | ~700 tok |

**Phase 7 total: ~4.5k context / ~2.7k output** — one session, low risk.

---

## Phase 8 — Active relocalization (doc's step 8)
**Goal:** when localization is ambiguous, choose a disambiguating action instead of wandering.

| Step | Task | Context | Output |
|---|---|---|---|
| 8.1 | `choose_disambiguating_action(candidates, graph)` — pick the command whose candidate outcomes diverge most | ~2.5k tok (needs 6.1–6.2) | ~1.8k tok |
| 8.2 | Relocalizing state: on ambiguous score, invoke 8.1 instead of normal replan; loop until one candidate wins | ~2.5k tok (needs 8.1, 6.3) | ~1.8k tok |
| 8.3 | Optional: wire a `recall`-style escape command as an anchor-of-last-resort if candidates never converge | ~1.5k tok | ~1k tok |

**Phase 8 total: ~6.5k context / ~4.6k output** — one session.

---

## Phase 9 — State machine wiring
**Goal:** make the mermaid state diagram real — Localizing/Navigating/Exploring/Relocalizing/Combat.

| Step | Task | Context | Output |
|---|---|---|---|
| 9.1 | State machine class (simple enum + transition table, not a full framework — you don't need one for 6 states) | ~2k tok (needs all prior modules' public interfaces) | ~2k tok |
| 9.2 | Combat/interrupt handling: detect interruption, pause navigation, resume on combat-end | ~2k tok | ~1.5k tok |
| 9.3 | End-to-end test: multi-room journey that includes at least one ambiguous room and one interrupted move | ~2k tok | ~1k tok |

**Phase 9 total: ~6k context / ~4.5k output** — one session.

---

## Phase 10 — LLM goal layer (doc's step 9, deliberately last)
**Goal:** translate natural language ("buy food") into a destination + task. The LLM never picks `north` directly.

| Step | Task | Context | Output |
|---|---|---|---|
| 10.1 | Goal parser: LLM call that maps intent → known room ID (or "need to discover") + post-arrival action | ~2k tok | ~1.5k tok |
| 10.2 | Wire goal → `navigate_to(room_id)` using Phase 4/6/8 machinery; LLM only ever calls this one function | ~2k tok (needs full navigation stack interfaces) | ~1.2k tok |
| 10.3 | Guardrail test: confirm LLM output never contains a raw movement command, only goal + optional room hint | ~1.5k tok | ~700 tok |

**Phase 10 total: ~5.5k context / ~3.4k output** — one session.

---

## Summary

| Phase | Sessions | Cumulative complexity |
|---|---|---|
| 0 Scaffold | 1 | trivial |
| 1 Parsing | 1 | low |
| 2 Telnet layer | 1 | low |
| 3 Graph storage | 1 | low-medium |
| 4 Milestone 1 (5-room loop) | 1–2 | **checkpoint — don't skip** |
| 5 Frontier exploration | 1 | medium |
| 6 Candidate localization | 2 | **highest risk, most iteration** |
| 7 Weighted routing | 1 | low |
| 8 Active relocalization | 1 | medium |
| 9 State machine | 1 | medium |
| 10 LLM goal layer | 1 | low |

**~13–14 Claude Code sessions total**, each self-contained enough to fit in a single context window with room to spare. Phase 6 is where to budget extra time and possibly extra sessions — it's the one place the review is pushing you to genuinely rearchitect rather than just add a module.

**Before every phase:** paste in the current file tree + relevant existing module signatures (not full file contents) rather than re-explaining the architecture — that's most of what keeps these context estimates low.