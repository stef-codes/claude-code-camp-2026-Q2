require_relative "helper"

# Mud::RouteFinder — shortest path across the agent's own map.
#
# Runs against Store.open(":memory:"). No MUD, no MCP, no network: a route is a
# pure function of what the store already believes.
class TestRouteFinder < Minitest::Test
  M = Boukensha::Mud::Memory
  F = Boukensha::Mud::Memory::Fingerprint
  RF = Boukensha::Mud::RouteFinder

  def setup
    @store = M::Store.open(":memory:")
    @finder = RF.new(@store)
  rescue M::Store::Unavailable => e
    skip e.message
  end

  def teardown
    @store&.close
  end

  def room(name, desc: "prose for #{name}", confidence: "confirmed")
    @store.create_room(name: name, description: desc, confidence: confidence,
                       weak_fingerprint: F.weak(name: name, description: desc, exit_dirs: %w[north]))
  end

  # An edge as the agent records it: the exit is seen first, then walked.
  def link(from, direction, to)
    @store.record_exits!(from, dirs: [direction])
    @store.link_exit!(from, direction, to)
  end

  # --- the happy path --------------------------------------------------------

  def test_routes_a_straight_line_and_reports_the_rooms_passed_through
    a = room("A"); b = room("B"); c = room("C")
    link(a, "north", b)
    link(b, "east", c)

    r = @finder.route(from: a, to: "C")

    assert r.ok
    assert_equal :arrived, r.reason
    assert_equal %w[north east], r.steps
    # room_ids INCLUDES the start, so room_ids[i+1] is where steps[i] must land
    # — the exact comparison the walker makes after each move.
    assert_equal [a, b, c], r.room_ids
    assert_equal c, r.goal_id
  end

  def test_prefers_the_shorter_of_two_routes
    a = room("A"); b = room("B"); c = room("C"); d = room("D")
    link(a, "north", b); link(b, "north", d)          # 2 steps
    link(a, "east", c); link(c, "east", d)            # also 2
    link(a, "up", d)                                  # 1 — this one

    assert_equal %w[up], @finder.route(from: a, to: "D").steps
  end

  def test_routing_to_where_you_already_stand_is_not_an_error
    a = room("A")
    r = @finder.route(from: a, to: "A")

    assert r.ok
    assert_equal :already_here, r.reason
    assert_empty r.steps
  end

  def test_accepts_a_room_id_as_well_as_a_name
    a = room("A"); b = room("B")
    link(a, "north", b)

    assert_equal %w[north], @finder.route(from: a, to: b).steps
    assert_equal %w[north], @finder.route(from: a, to: b.to_s).steps
  end

  # --- TRAP 1: edges are directed -------------------------------------------

  # The whole of trap 1 is a test that asserts the ABSENCE of an edge nobody
  # recorded. Walking A north into B tells you nothing about how to get back:
  # the MUD is free to put the return exit somewhere else, or nowhere. Inferring
  # `south` here would be inventing knowledge.
  def test_does_not_invent_the_reverse_of_a_walked_edge
    a = room("A"); b = room("B")
    link(a, "north", b)

    forward = @finder.route(from: a, to: "B")
    back    = @finder.route(from: b, to: "A")

    assert forward.ok, "the edge that was walked routes"
    refute back.ok, "the reverse was never walked and must not be assumed"
    assert_equal :no_route, back.reason
  end

  # A failed route is still useful: the frontier is where the map runs out, so
  # "I cannot take you there" comes with "…but these exits are unexplored".
  def test_a_failed_route_reports_the_frontier_it_could_explore
    a = room("A"); b = room("B")
    link(a, "north", b)
    @store.record_exits!(a, dirs: %w[east], targets: { "east" => "A Dark Alley" })

    r = @finder.route(from: a, to: "Nowhere In Particular")
    refute r.ok

    r2 = @finder.route(from: b, to: "A")
    refute r2.ok
    assert_equal :no_route, r2.reason
  end

  # --- TRAP 2: duplicate rooms are load-bearing ------------------------------

  # Hooks#provisional writes a NEW row when it cannot settle which of several
  # candidates it is standing in, and nothing ever merges them. So a name is a
  # SET, the search stops at whichever member the agent's edges reach first, and
  # the rest are reported rather than hidden.
  def test_a_duplicated_name_routes_to_the_nearest_and_names_the_others
    a    = room("A")
    b    = room("B")
    near = room("Market Square")
    far  = room("Market Square")
    link(a, "north", near)   # 1 step
    link(a, "east", b)
    link(b, "east", far)     # 2 steps

    r = @finder.route(from: a, to: "Market Square")

    assert r.ok
    assert_equal near, r.goal_id, "the reachable-soonest duplicate wins"
    assert_equal 1, r.steps.length
    assert_equal [far], r.ambiguous.map { |x| x[:id] }, "the other one is reported, not hidden"
  end

  def test_a_confirmed_room_outranks_a_provisional_one_of_the_same_name
    a = room("A")
    prov = room("The Temple", confidence: "provisional")
    conf = room("The Temple")
    # Both exactly one step away, so only the confidence ordering can break the tie.
    link(a, "north", prov)
    link(a, "east", conf)

    assert_equal conf, @finder.route(from: a, to: "The Temple").goal_id
  end

  def test_an_unknown_destination_suggests_near_misses
    room("The Cozy Bakery")
    a = room("A")

    r = @finder.route(from: a, to: "bakery")
    # A single fuzzy hit is unambiguous enough to act on.
    assert_equal :no_route, r.reason, "resolved the name, but no edge leads there"

    r2 = @finder.route(from: a, to: "zzzz")
    refute r2.ok
    assert_equal :unknown_destination, r2.reason
  end

  # --- the walkable filter ---------------------------------------------------

  # `room_exits.direction` holds whatever the MUD printed. A route containing a
  # direction `move` would reject is not a route, so the filter lives in the
  # finder — the walker should never have to second-guess a step it was handed.
  def test_never_routes_through_a_direction_move_cannot_accept
    a = room("A"); b = room("B"); c = room("C")
    link(a, "northeast", b)     # a real MUD direction; `move` still refuses it
    link(a, "(s)", c)           # literal junk, seen in this world's data

    refute @finder.route(from: a, to: "B").ok
    refute @finder.route(from: a, to: "C").ok
  end

  def test_max_steps_reports_too_far_rather_than_walking_forever
    ids = (0..5).map { |i| room("R#{i}") }
    ids.each_cons(2) { |from, to| link(from, "north", to) }

    assert @finder.route(from: ids.first, to: "R5", max_steps: 10).ok

    r = @finder.route(from: ids.first, to: "R5", max_steps: 2)
    refute r.ok
    # :too_far, not :no_route — the map DOES connect them, the budget did not.
    assert_equal :too_far, r.reason
  end

  # --- the cost lock ---------------------------------------------------------

  # The regression lock against a future `exits_for`-in-a-loop. `CountingDb`
  # counts every execute, and db_reads is how the session prices the agent's
  # real work — a BFS whose cost scales with the map would drown that signal.
  def test_a_route_across_a_large_map_costs_a_constant_number_of_reads
    ids = (0..49).map { |i| room("R#{i}") }
    ids.each_cons(2) { |from, to| link(from, "north", to) }

    before = @store.counters[:db_reads]
    r = @finder.route(from: ids.first, to: "R49", max_steps: 60)
    spent = @store.counters[:db_reads] - before

    assert r.ok
    assert_equal 49, r.steps.length
    assert_operator spent, :<=, 3,
                    "a 50-room route must not read per node (spent #{spent})"
  end
end
