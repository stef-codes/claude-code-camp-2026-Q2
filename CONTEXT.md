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
A one-time immortal relocate performed outside the agent (e.g. goto/transfer), not exposed as a player tool.
_Avoid_: send_raw on the player, in-session teleport tool

**Provisional hop**:
A navigate step into a named destination that is known from an exits line but not yet visited; the route is marked provisional until arrival confirms the room.
_Avoid_: inventing a reverse edge, treating the frontier name as a confirmed visited room before walking

**Bakery visit recipe**:
The player-prompt procedure for a Bakery visit: prefer navigate to the Bakery name (provisional hop allowed), then shop list for the Menu. If navigate cannot reach it, fall back to explore for that bakery, then shop list.
_Avoid_: explore-first when navigate would work, composite visit tool

**Bakery name**:
Whatever bakery room the user asked for (verbatim or an unambiguous map match), not a single hard-coded title.
_Avoid_: assuming only “The Cozy Bakery”, inventing a bakery name not on the map or exits line
