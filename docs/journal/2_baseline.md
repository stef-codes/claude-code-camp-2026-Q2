# Week 2 — Baseline MUD Agent (BOUKENSHA)

My goal for Week 2 was to build a more capable agent with memory and observability. 

## What I set out to do

- "Watch" what the agent does
- Consistently make it to the bakery
- Complete a quest. 

## What I built

- Langfuse Integration
- More Tool calling with 
- Accidental teleportation 
- Search algorithms


## Problems I hit and how I solved them (Letting Claude write out my problems.)

- **Stuck in the dark on Dirt Road (`002a65b`).** Outdoor night made every
  look “It is pitch black…”, explore refused, and the agent kept casting
  `light` on **waybread** after `create food`. On tbaMUD that ritual is a dead
  end (food isn’t a light target / isn’t holdable) — Dummy burned mana and
  filled inventory with loaves. Fix: treat darkness as a first-class state
  (`DARK` + last-known hints), refuse blind explore, and for immortal Dummy
  use `holylight` via Hooks `send_raw` instead. Lesson: “what works in a help
  file / another MUD” is not what this binary accepts — prove the ritual live.

- **“Go to the bakery” meant a cliff pilgrimage (`7483158`, then `1a0eae3`).**
  The player called **`explore`**, never **`navigate`**. Midgaard and the
  grasslands are map islands, so BFS had nothing to walk. Worse: Langfuse still
  served a short stale `boukensha-player-system`, so the local Bakery visit
  recipe never reached the model (`observability.prompts.enabled: true` beats
  the file). Fix: bake the navigate→shop-list recipe into the prompt, disable
  Langfuse prompt fetch until production is re-synced, and briefly tried
  immortal `goto 3009` — then turned auto-teleport **off** because I don’t
  want Relocate for this goal. Lesson: remote prompt management can silently
  erase your local rules; “find the bakery” is the wrong tool when the map is
  disconnected.

- **Couldn’t pick up loot / gold (`1a0eae3`).** The agent did `get_item(item:
  corpse)` (picked up the corpse) or passed `count: 1` so the daemon sent
  `get 1 sword`. CircleMUD reads that as “get object `1` from container
  `sword`” → “A small sword is not a container.” Fix: loot with
  `get all corpse` (`item: "all"`, `container: "corpse"`, omit count), and stop
  emitting a bare leading count in `Primitives#get`. Lesson: the tool schema’s
  “count” is not free-form English — one wrong integer rewrites the whole
  command grammar.

- **“Nearest quest” went to the post office.** Score said not on a quest; the
  agent kept `say`ing `"quest"` at the **head postmaster** (mail). The nearby
  quest is the **questmaster** in Sanctus Quest Room (~113): speech triggers
  (`say yes`, then `say hunt` / `find`), not the postmaster, and often not
  `quest list` either (that needs a QUESTMASTER-flagged mob). Boukensha also
  has no `quest` tool / no player `send_raw`. Lesson: “nearest NPC that sounds
  official” ≠ quest giver; verify the start command in-world before burning a
  turn budget.

- **Hit the action limit and invented a reset.** Wrap-up talks about an
  “action limit” (`max_iterations`, default 25). The model treated it like a
  MUD wait-state and wanted `send_raw` to “reset” it — which isn’t on the
  player allowlist and wouldn’t refill the budget anyway. Fix direction:
  surface `actions: N/MAX · L left` in the state block so the model can finish
  before wrap-up, and start a new user message when the turn is spent.


## What I learned

- Observability is key to understanding where I am ans where I want to go next. In the game and in development. 

- Instructions must be explicit. 

- Hallcincations are exponential when building an agent. 

## What's still rough / what's next

- **Next Phase :** 
- Experiment with the Anthropic SDK
- Try Langraph and Langchain 
- Build the "complete a quest' bath 
- Improve navigation 