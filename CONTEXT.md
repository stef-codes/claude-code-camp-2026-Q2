# Boukensha (capable)

The week-2 MUD-playing agent: a player goal layer that delegates travel and reports about the world without inventing directions.

## Language

**Bakery visit**:
A player goal to reach a known bakery room and report its shop stock.
_Avoid_: find a bakery, explore for bread, discovery brief

**Menu**:
The goods a shopkeeper offers in the current room, as returned by a shop list.
_Avoid_: room description, baker examine text, inventory

**Known destination**:
A room the agent can name and route to on its own map (visited or otherwise already routable).
_Avoid_: frontier name alone when treated as “already found” without a route

**Relocate**:
An out-of-band move of the character to a better starting room so a Bakery visit does not depend on discovering a long unmapped path.
_Avoid_: explore, navigate (those are in-world travel), seed map

**Landmark**:
The Midgaard room chosen as the Relocate target, adjacent enough that a short in-world walk reaches the bakery.
_Avoid_: wilderness start, arbitrary remote room

**Operator relocate**:
An immortal Relocate (`goto` / transfer) that is not a player-facing teleport tool. Hooks may perform it automatically via allowlisted `send_raw` when the character is immortal, the goal is a Bakery visit, and there is no routable bakery on the map; an operator may still do it out-of-band the same way.
_Avoid_: exposing teleport to the player allowlist, inventing walk directions, using Relocate for non-bakery goals

**Provisional hop**:
A navigate step into a named destination that is known from an exits line but not yet visited; the route is marked provisional until arrival confirms the room.
_Avoid_: inventing a reverse edge, treating the frontier name as a confirmed visited room before walking

**Bakery visit recipe**:
The player-prompt procedure for a Bakery visit: prefer navigate to the Bakery name (provisional hop allowed), then shop list for the Menu. If Hooks already Relocated you to the bakery, shop list immediately. If navigate cannot reach it and you were not Relocated, fall back to explore for that bakery, then shop list.
_Avoid_: explore-first when navigate would work, composite visit tool, wandering cliffs when stranded off-map

**Bakery name**:
Whatever bakery room the user asked for (verbatim or an unambiguous map match), not a single hard-coded title. Settings pin Midgaard landmark `The Bakery` (#3009) for immortal Relocate only.
_Avoid_: assuming only “The Cozy Bakery”, inventing a bakery name not on the map or exits line

**Corpse loot**:
Taking coins and gear from a corpse with `get_item(item: "all", container: "corpse")` (`get all corpse`).
_Avoid_: `get_item(item: "corpse")` (picks up the corpse object; gold stays inside)
