// Rooms -> geometry. No React, no DOM: this is the only genuinely algorithmic
// code in web/, and keeping it a pure `rooms[] -> coordinates` function is what
// makes it testable (layout.test.ts) and keeps Map.tsx about rendering.
//
// The job is NOT graph layout in the dagre sense. A layered DAG layout assigns
// ranks and minimises crossings — it discards geometry in favour of its own
// ordering, and geometry is the only spatial information the agent actually
// has. If the agent walked north to get somewhere, that room goes above this
// one. Everything here follows from that.

import type { KnowledgeRoom, WorldOverlay, WorldVerdict } from "../../api/types";
import { truncate } from "../../format";

/** The eight planar directions, matching room_parser.rb's DIRECTIONS table —
 *  the only writer of `room_exits.direction`. Screen coords: +y is south. */
const V: Record<string, [number, number]> = {
  north: [ 0, -1 ],
  south: [ 0, 1 ],
  east: [ 1, 0 ],
  west: [ -1, 0 ],
  northeast: [ 1, -1 ],
  northwest: [ -1, -1 ],
  southeast: [ 1, 1 ],
  southwest: [ -1, 1 ],
};

// `up`, `down` and anything the parser passed through verbatim (room 26 has an
// exit whose direction is the literal string "(s)") are non-planar: they never
// consume a cell by vector and they must never throw.
const DIR_ORDER = [
  "north", "northeast", "east", "southeast",
  "south", "southwest", "west", "northwest",
  "up", "down",
];

/** Cell geometry, exported so the SVG edge layer and the CSS node boxes cannot
 *  disagree about where a room is. Mirrors --map-cell-* in index.css. */
export const CELL_W = 190;
export const CELL_H = 120;
export const GAP_X = 40;
export const GAP_Y = 40;
/** Blank columns between disconnected components. */
const COMPONENT_GUTTER = 2;

export const STEP_X = CELL_W + GAP_X;
export const STEP_Y = CELL_H + GAP_Y;

export interface PlacedNode {
  room: KnowledgeRoom;
  /** Grid cell, not pixels. Origin is the top-left of the packed extent. */
  cx: number;
  cy: number;
  component: number;
}

export interface PlacedEdge {
  from: number;
  to: number;
  direction: string;
  /** false = up/down/unrecognised token: the grid cannot express this move. */
  planar: boolean;
  /** true = the two rooms are not where this direction says they should be.
   *  The one place the picture stops matching the data, so it is said out loud. */
  displaced: boolean;
  traversals: number;
  /** The far room records an exit back to this one — absence means a one-way. */
  reciprocal: boolean;
  key: string;
  /** What the TRUE world says about this edge. Undefined when no overlay was
   *  passed, or when the world has nothing to say about these two rooms. */
  verdict?: WorldVerdict;
  /** Set only for a `wrong` verdict: why it is wrong. */
  verdictReason?: string;
  /** The room this direction really leads to, when the world can name one. */
  trueName?: string | null;
}

export interface FrontierStub {
  roomId: number;
  direction: string;
  /** The door's name from the autoexit line, or the direction if it had none. */
  label: string;
  /** true = planar direction into an empty cell, so it can be drawn as a stub
   *  arrow. false = draw a chip on the node instead; an arrow would either
   *  point at an existing room (implying a link that is not recorded) or point
   *  in a direction the grid does not have. */
  free: boolean;
  dx: number;
  dy: number;
  /** The name of the room actually behind this unwalked door, from the true
   *  world. The highest-value thing the overlay adds: it turns "there is a way
   *  north" into "north is the Windy Ridge". Undefined without an overlay. */
  truthLabel?: string;
  /** false = the true world offers several possibilities and `truthLabel` is a
   *  shortlist, not an answer. The UI must not render it as a fact. */
  truthCertain?: boolean;
}

/**
 * A room the agent has NOT found, one step beyond one it has.
 *
 * Deliberately not a `PlacedNode`: there is no `KnowledgeRoom` behind it and no
 * detail page to link to, because the agent has never been there. Rendering it
 * as anything a reader could click would promise a page that cannot exist.
 */
export interface GhostNode {
  key: string;
  fromRoomId: number;
  direction: string;
  /** The true room name, or null when the candidates disagree. */
  name: string | null;
  /** Every possibility. Length > 1 is exactly when `name` is null. */
  names: string[];
  vnums: number[];
  certain: boolean;
  /** true  = labels an exit the agent knows about but has not walked.
   *  false = the agent does not know this exit exists — usually a closed door,
   *          which tbaMUD omits from `[ Exits: ]` entirely. The most
   *          interesting thing on the map: a way out nothing in the agent's
   *          own memory hints at. */
  frontier: boolean;
  cx: number;
  cy: number;
  planar: boolean;
}

export interface MapLayout {
  nodes: PlacedNode[];
  edges: PlacedEdge[];
  stubs: FrontierStub[];
  /** Empty unless an overlay was passed. Never affects node placement. */
  ghosts: GhostNode[];
  /**
   * Extent in cells once ghosts are included.
   *
   * Nodes are anchored at 0,0, but a ghost north of the top row sits at cy -1,
   * so drawing ghosts needs a canvas that reaches into negative space. `originX`
   * and `originY` are ≤ 0 and say how far. They are reported rather than folded
   * into the node coordinates on purpose: folding would move every room the
   * moment the overlay poll landed, which is precisely the reshuffle the
   * placement comments above go to such lengths to avoid.
   */
  ghostBounds: { originX: number; originY: number; cols: number; rows: number };
  /** Extent in cells. Always anchored at 0,0 after component packing. */
  cols: number;
  rows: number;
  components: number;
  /** Placement collisions — geometry the map had to lie about. Surfaced. */
  displacedCount: number;
  /** Edges the true world contradicts outright. Surfaced next to
   *  `displacedCount`, because "the picture is bent" and "the agent believes
   *  something false" are different failures and deserve different counts. */
  wrongCount: number;
}

const cellKey = (x: number, y: number) => `${x},${y}`;

function dirRank(direction: string): number {
  const i = DIR_ORDER.indexOf(direction);
  return i === -1 ? DIR_ORDER.length : i;
}

// Fixed exit ordering so BFS visits neighbours in the same sequence on every
// tick. Without this the layout would reshuffle every 3s poll and nodes would
// teleport under the cursor.
function sortedExits(room: KnowledgeRoom) {
  return [ ...room.exits ].sort((a, b) => {
    const d = dirRank(a.direction) - dirRank(b.direction);
    return d !== 0 ? d : a.direction.localeCompare(b.direction);
  });
}

/** First free cell at increasing Chebyshev distance from (wx, wy), scanned in a
 *  fixed order. Ties resolve identically every run. */
function nearestFree(occupied: Map<string, number>, wx: number, wy: number): [ number, number ] {
  if (!occupied.has(cellKey(wx, wy))) return [ wx, wy ];
  for (let r = 1; r <= 512; r++) {
    for (let dy = -r; dy <= r; dy++) {
      for (let dx = -r; dx <= r; dx++) {
        if (Math.max(Math.abs(dx), Math.abs(dy)) !== r) continue;
        if (!occupied.has(cellKey(wx + dx, wy + dy))) return [ wx + dx, wy + dy ];
      }
    }
  }
  // Unreachable for any world that fits in memory, but a layout function must
  // not throw on the page that renders the agent's memory.
  return [ wx + 1024, wy ];
}

interface LocalNode {
  room: KnowledgeRoom;
  x: number;
  y: number;
}

/**
 * Place every room on an integer grid by walking its exits.
 *
 * Determinism is a hard requirement, not a nicety: the page repolls every 3s
 * and re-runs this on data that changes underneath it. Anchor is the lowest
 * room id (ids are assigned in discovery order, so id 1 is a stable landmark —
 * anchoring on the player would slide the whole world sideways every time the
 * agent walks through a door; keeping the player centred is the viewport's job).
 * No Object.keys iteration, no Set ordering, no clock.
 *
 * `overlay` is optional and purely additive. It decorates edges with the true
 * world's verdict, labels frontier stubs with what is really behind them, and
 * adds ghost cells for rooms the agent has not found — but it NEVER reaches the
 * placement above. Two reasons, and both are load-bearing. Determinism: node
 * positions must not shift when a slow 15s overlay poll lands between two 3s
 * knowledge polls, or the map would visibly rearrange itself for no reason the
 * reader can see. And honesty: the geometry is the agent's, so the truth is not
 * allowed to straighten it out. A map that quietly corrects itself against the
 * real world stops being a picture of what the agent believes.
 */
export function layoutRooms(rooms: KnowledgeRoom[], overlay?: WorldOverlay | null): MapLayout {
  const sorted = [ ...rooms ].sort((a, b) => a.id - b.id);
  const byId = new Map<number, KnowledgeRoom>();
  for (const room of sorted) byId.set(room.id, room);

  const placed = new Map<number, { x: number; y: number; component: number }>();
  const components: LocalNode[][] = [];

  for (const anchor of sorted) {
    if (placed.has(anchor.id)) continue;

    const component = components.length;
    const occupied = new Map<string, number>();
    const local: LocalNode[] = [];

    const put = (room: KnowledgeRoom, x: number, y: number) => {
      occupied.set(cellKey(x, y), room.id);
      placed.set(room.id, { x, y, component });
      local.push({ room, x, y });
    };

    put(anchor, 0, 0);
    const queue: number[] = [ anchor.id ];

    while (queue.length > 0) {
      const room = byId.get(queue.shift()!)!;
      const here = placed.get(room.id)!;

      for (const exit of sortedExits(room)) {
        const targetId = exit.target_room_id;
        if (targetId == null) continue;          // frontier — nothing to place
        if (placed.has(targetId)) continue;
        const target = byId.get(targetId);
        if (!target) continue;                   // target outside this payload

        const v = V[exit.direction];
        // A non-planar target goes in the nearest free cell to its source: a
        // stairwell drawn adjacent and explicitly styled as one beats leaving
        // the room floating in a component of its own.
        const [ wx, wy ] = v ? [ here.x + v[0], here.y + v[1] ] : [ here.x, here.y ];
        const [ x, y ] = nearestFree(occupied, wx, wy);
        put(target, x, y);
        queue.push(targetId);
      }
    }

    components.push(local);
  }

  // Pack components left-to-right by bounding box, in anchor-id order, with a
  // visible gutter. Islands are not a rendering failure — they are what
  // fingerprint mis-resolution looks like, and the room the resolver split in
  // two should be visibly floating.
  const nodes: PlacedNode[] = [];
  const coords = new Map<number, { cx: number; cy: number }>();
  let cursorX = 0;
  let rows = 0;

  for (let component = 0; component < components.length; component++) {
    const local = components[component];
    let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    for (const n of local) {
      if (n.x < minX) minX = n.x;
      if (n.y < minY) minY = n.y;
      if (n.x > maxX) maxX = n.x;
      if (n.y > maxY) maxY = n.y;
    }

    for (const n of local) {
      const cx = n.x - minX + cursorX;
      const cy = n.y - minY;
      nodes.push({ room: n.room, cx, cy, component });
      coords.set(n.room.id, { cx, cy });
    }

    cursorX += (maxX - minX + 1) + COMPONENT_GUTTER;
    rows = Math.max(rows, maxY - minY + 1);
  }

  nodes.sort((a, b) => a.room.id - b.room.id);
  const cols = Math.max(0, cursorX - (components.length > 0 ? COMPONENT_GUTTER : 0));

  const occupiedGlobal = new Set<string>();
  for (const n of nodes) occupiedGlobal.add(cellKey(n.cx, n.cy));

  // Which rooms record an exit back — computed from the exits already in hand,
  // so one-way styling costs no extra request.
  const backlinks = new Map<number, Set<number>>();
  for (const room of sorted) {
    for (const exit of room.exits) {
      if (exit.target_room_id == null) continue;
      let set = backlinks.get(exit.target_room_id);
      if (!set) backlinks.set(exit.target_room_id, (set = new Set()));
      set.add(room.id);
    }
  }

  // Overlay lookups, keyed the way the server keys them: room id + direction.
  // Empty maps when there is no overlay, so every access below is uniform and
  // the no-overlay path costs one Map.get that misses.
  const verdicts = new Map<string, WorldOverlay["verdicts"][number]>();
  const ghostsByEdge = new Map<string, WorldOverlay["ghosts"][number]>();
  for (const v of overlay?.verdicts ?? []) verdicts.set(`${v.room_id}:${v.direction}`, v);
  for (const g of overlay?.ghosts ?? []) ghostsByEdge.set(`${g.from_room_id}:${g.direction}`, g);

  const edges: PlacedEdge[] = [];
  const stubs: FrontierStub[] = [];
  let displacedCount = 0;
  let wrongCount = 0;

  for (const room of sorted) {
    const from = coords.get(room.id);
    if (!from) continue;

    for (const exit of sortedExits(room)) {
      const v = V[exit.direction];
      const planar = v !== undefined;

      if (exit.target_room_id == null) {
        // target_room_id IS the exploration frontier: a named door the agent
        // has seen and never walked through.
        const free = planar && !occupiedGlobal.has(cellKey(from.cx + v[0], from.cy + v[1]));
        const truth = ghostsByEdge.get(`${room.id}:${exit.direction}`);
        stubs.push({
          roomId: room.id,
          direction: exit.direction,
          label: exit.target_name ?? exit.direction,
          free,
          dx: planar ? v[0] : 0,
          dy: planar ? v[1] : 0,
          // The door's own name comes from the autoexit line and is the agent's;
          // this is the world's. When the world cannot settle on one room, the
          // shortlist is shown as a shortlist rather than as an answer.
          truthLabel: truth ? (truth.name ?? truth.names.join(" / ")) : undefined,
          truthCertain: truth?.certain,
        });
        continue;
      }

      const to = coords.get(exit.target_room_id);
      if (!to) continue;

      // Derived from the final coordinates rather than recorded at placement
      // time, so it also catches the second edge of a cycle that does not
      // close — the non-Euclidean geometry MUDs are full of.
      const displaced = planar && !(to.cx - from.cx === v[0] && to.cy - from.cy === v[1]);
      if (displaced) displacedCount++;

      const verdict = verdicts.get(`${room.id}:${exit.direction}`);
      if (verdict?.verdict === "wrong") wrongCount++;

      edges.push({
        from: room.id,
        to: exit.target_room_id,
        direction: exit.direction,
        planar,
        displaced,
        traversals: exit.traversals,
        reciprocal: backlinks.get(room.id)?.has(exit.target_room_id) ?? false,
        key: `${room.id}:${exit.direction}:${exit.target_room_id}`,
        verdict: verdict?.verdict,
        verdictReason: verdict?.reason,
        trueName: verdict?.true_name,
      });
    }
  }

  const ghosts = placeGhosts(overlay, coords, occupiedGlobal);

  return {
    nodes,
    edges,
    stubs,
    ghosts,
    ghostBounds: ghostBounds(ghosts, cols, rows),
    cols,
    rows,
    components: components.length,
    displacedCount,
    wrongCount,
  };
}

function ghostBounds(ghosts: GhostNode[], cols: number, rows: number) {
  let originX = 0, originY = 0, maxX = cols - 1, maxY = rows - 1;
  for (const g of ghosts) {
    if (g.cx < originX) originX = g.cx;
    if (g.cy < originY) originY = g.cy;
    if (g.cx > maxX) maxX = g.cx;
    if (g.cy > maxY) maxY = g.cy;
  }
  return { originX, originY, cols: maxX - originX + 1, rows: maxY - originY + 1 };
}

/**
 * Put the unfound rooms on the grid, without letting them touch the found ones.
 *
 * The occupancy map starts as a COPY of every real cell, so `nearestFree` can
 * push a ghost aside but a ghost can never push a room. That is the invariant
 * the whole overlay rests on: the agent's map owns the geometry, and the truth
 * is drawn into the gaps left over.
 *
 * Ghosts are per-edge, not per-room: two known rooms that both lead to one
 * unfound room produce two ghosts. That is deliberate for a first version — the
 * claim being drawn is "this way lies X", which is true from each side, and
 * merging them would mean choosing which source to place the survivor next to.
 */
function placeGhosts(
  overlay: WorldOverlay | null | undefined,
  coords: Map<number, { cx: number; cy: number }>,
  realCells: Set<string>,
): GhostNode[] {
  if (!overlay?.ghosts?.length) return [];

  const occupied = new Map<string, number>();
  for (const cell of realCells) occupied.set(cell, -1);

  // Fixed iteration order, independent of the server's, so a ghost lands in the
  // same cell on every poll. The server already sorts, but relying on a
  // response's order for placement stability is the kind of coupling that
  // breaks silently.
  const ordered = [ ...overlay.ghosts ].sort((a, b) => {
    const d = a.from_room_id - b.from_room_id;
    if (d !== 0) return d;
    const r = dirRank(a.direction) - dirRank(b.direction);
    return r !== 0 ? r : a.direction.localeCompare(b.direction);
  });

  const ghosts: GhostNode[] = [];
  for (const ghost of ordered) {
    const from = coords.get(ghost.from_room_id);
    if (!from) continue;

    const v = V[ghost.direction];
    const planar = v !== undefined;
    // `up`/`down` have no vector, exactly as they have none for a real edge:
    // placed adjacent to their source rather than dropped.
    const [ wx, wy ] = planar ? [ from.cx + v[0], from.cy + v[1] ] : [ from.cx, from.cy ];
    const [ cx, cy ] = nearestFree(occupied, wx, wy);
    occupied.set(cellKey(cx, cy), ghost.from_room_id);

    ghosts.push({
      key: ghost.key,
      fromRoomId: ghost.from_room_id,
      direction: ghost.direction,
      name: ghost.name,
      names: ghost.names,
      vnums: ghost.vnums,
      certain: ghost.certain,
      frontier: ghost.frontier,
      cx,
      cy,
      planar,
    });
  }

  return ghosts;
}

/** A room the MUD never named still needs something on its box. */
export function displayName(room: KnowledgeRoom): string {
  const name = (room.name ?? "").trim();
  if (name) return name;
  const descr = truncate(room.description, 40);
  return descr || `#${room.id}`;
}

/** Centre of a cell, in world pixels. */
export function cellCenter(cx: number, cy: number): { x: number; y: number } {
  return { x: cx * STEP_X + CELL_W / 2, y: cy * STEP_Y + CELL_H / 2 };
}

export function worldSize(layout: MapLayout): { width: number; height: number } {
  return {
    width: Math.max(0, layout.cols * STEP_X - GAP_X),
    height: Math.max(0, layout.rows * STEP_Y - GAP_Y),
  };
}

/** The canvas needed once ghosts are drawn, plus the pixel offset that brings
 *  negative ghost cells back into view. `offsetX/offsetY` are ≥ 0 and are zero
 *  whenever no ghost reaches above or left of the node grid. */
export function ghostWorldSize(layout: MapLayout): {
  width: number; height: number; offsetX: number; offsetY: number;
} {
  const b = layout.ghostBounds;
  return {
    width: Math.max(0, b.cols * STEP_X - GAP_X),
    height: Math.max(0, b.rows * STEP_Y - GAP_Y),
    offsetX: -b.originX * STEP_X,
    offsetY: -b.originY * STEP_Y,
  };
}
