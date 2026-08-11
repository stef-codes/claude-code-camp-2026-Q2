require_relative "helper"

# Routing to a room the agent has never stood in.
#
# `check(exits)` turns `n e s w` into `north - The Cozy Bakery`, so the agent
# routinely knows the NAME of a place it has never visited. On a real 71-room
# map every one of the 73 unwalked exits had a target_name — and every one of
# those names was unroutable, because `resolve` only ever looked at `rooms`.
# Asked for a room it could name and point at, `navigate` answered "no room
# called that in your map".
#
# The rule that keeps this honest: a visited room ALWAYS wins. A name off an
# exits line is weaker evidence than a room the agent has stood in, and it is
# only consulted when nothing real answers.
class TestRouteFinderFrontier < Minitest::Test
  M  = Boukensha::Mud::Memory
  F  = Boukensha::Mud::Memory::Fingerprint
  RF = Boukensha::Mud::RouteFinder

  def setup
    @store = M::Store.open(":memory:")
  rescue M::Store::Unavailable => e
    skip e.message
  end

  def teardown
    @store&.close
  end

  def room(name)
    @store.create_room(name: name, description: "prose for #{name}",
                       weak_fingerprint: F.weak(name: name, description: name, exit_dirs: %w[north]))
  end

  def link(from, direction, to)
    @store.record_exits!(from, dirs: [ direction ])
    @store.link_exit!(from, direction, to)
  end

  # An exit we have SEEN on an exits line but never walked: a target_name, no
  # target_room_id. This is the state 73 of 73 frontier exits were really in.
  def frontier(from, direction, name)
    @store.record_exits!(from, dirs: [ direction ], targets: { direction => name })
  end

  def finder = RF.new(@store)

  # --- the capability --------------------------------------------------------

  def test_a_named_but_unvisited_neighbour_is_routable
    a = room("A"); b = room("B")
    link(a, "north", b)
    frontier(b, "east", "The Cozy Bakery")

    route = finder.route(from: a, to: "The Cozy Bakery")

    assert route.ok, "the map knows exactly which room and which direction reaches it"
    assert_equal %w[north east], route.steps
    assert_equal "The Cozy Bakery", route.goal_name
  end

  # The last step lands somewhere nothing has ever described. Saying so is the
  # difference between a route and a guess — and Navigator reads this nil as
  # "no expectation" rather than as a surprise worth replanning on.
  def test_the_final_room_is_unknown_and_the_route_says_so
    a = room("A")
    frontier(a, "north", "Somewhere New")

    route = finder.route(from: a, to: "Somewhere New")

    assert route.provisional, "a goal resolved from an exits line is not a visited room"
    assert_nil route.goal_id
    assert_equal [ a, nil ], route.room_ids
  end

  def test_an_exit_leaving_the_room_we_are_standing_in_costs_no_search
    a = room("A")
    frontier(a, "north", "Next Door")

    route = finder.route(from: a, to: "Next Door")

    assert_equal %w[north], route.steps
  end

  # --- the fastest path, which is the whole point ----------------------------

  # This world repeats room names constantly — three of The Bazaar's own exits
  # are called The Bazaar. Every matching exit goes into one search, so the
  # answer is the cheapest, decided by the same Dijkstra as everything else.
  def test_the_nearest_of_several_exits_with_the_same_name_wins
    a = room("A"); b = room("B"); c = room("C")
    link(a, "north", b); link(b, "north", c)
    frontier(c, "east", "The Bazaar")   # three steps away
    frontier(a, "west", "The Bazaar")   # one step away

    route = finder.route(from: a, to: "The Bazaar")

    assert_equal %w[west], route.steps, "it must not walk three steps to reach the same name"
  end

  # A route's last step is spent leaving the map, so the search may only use the
  # remaining budget. Otherwise `max_steps` would quietly buy one more.
  def test_the_step_off_the_map_is_counted_against_max_steps
    a = room("A"); b = room("B")
    link(a, "north", b)
    frontier(b, "east", "Far Side")

    assert finder.route(from: a, to: "Far Side", max_steps: 2).ok
    refute finder.route(from: a, to: "Far Side", max_steps: 1).ok,
           "two steps cannot fit in a budget of one"
  end

  # --- what must NOT change --------------------------------------------------

  def test_a_visited_room_always_beats_a_name_off_an_exits_line
    a = room("A"); real = room("The Temple")
    link(a, "north", real)
    frontier(a, "east", "The Temple")   # an exit claiming the same name

    route = finder.route(from: a, to: "The Temple")

    assert_equal real, route.goal_id, "a room we have stood in is the stronger evidence"
    assert_equal %w[north], route.steps
    refute route.provisional
  end

  # The island: a visited room matches the name, but no walked path reaches it.
  # Before the fallback, this was no_route even with a named frontier exit one
  # step away — Dirt Road (#71) → "Edge of a Clearing".
  def test_unreachable_visited_room_falls_back_to_named_frontier
    island = room("Dirt Road")
    visited = room("Edge of a Clearing")
    elsewhere = room("Somewhere Else")
    link(elsewhere, "west", visited)
    frontier(island, "south", "Edge of a Clearing")

    route = finder.route(from: island, to: "Edge of a Clearing")

    assert route.ok, "a named exit one step away must beat giving up"
    assert route.provisional, "landing through an unwalked exit is unverified"
    assert_equal %w[south], route.steps
    assert_nil route.goal_id
  end

  def test_an_unroutable_frontier_name_still_fails_as_before
    a = room("A"); b = room("B")
    frontier(b, "east", "Unreachable")   # b is not connected to a

    route = finder.route(from: a, to: "Unreachable")

    refute route.ok
    assert_equal :unknown_destination, route.reason
  end

  def test_a_name_nothing_knows_still_fails
    a = room("A")
    frontier(a, "north", "The Cozy Bakery")

    route = finder.route(from: a, to: "Atlantis")

    refute route.ok
    assert_equal :unknown_destination, route.reason
  end

  # Same refusal `resolve` makes for rooms: two half-matches are a question for
  # the caller, not a coin flip on their behalf.
  def test_a_substring_matching_two_different_names_refuses_to_guess
    a = room("A")
    frontier(a, "north", "The Cozy Bakery")
    frontier(a, "east", "Hannah Bakery")

    route = finder.route(from: a, to: "bakery")

    refute route.ok, "two bakeries is a question, not a default"
  end

  def test_a_substring_matching_one_name_twice_is_not_ambiguous
    a = room("A"); b = room("B")
    link(a, "north", b)
    frontier(a, "east", "The Cozy Bakery")
    frontier(b, "east", "The Cozy Bakery")

    route = finder.route(from: a, to: "bakery")

    assert route.ok, "the same name reached two ways is one destination"
    assert_equal %w[east], route.steps
  end

  # --- the suggestion, which is what a failed navigate actually shows ---------

  # The case a user actually hits: "bakery" is ambiguous, so routing refuses —
  # and the refusal is only useful if it names the candidates it refused
  # between. Both are unvisited, so before this neither would have appeared.
  def test_did_you_mean_offers_places_known_only_as_an_exits_destination
    a = room("A")
    frontier(a, "north", "The Cozy Bakery")
    frontier(a, "east", "Hannah Bakery")

    route = finder.route(from: a, to: "bakery")

    refute route.ok
    offered = route.suggestions.map { |s| s[:name] }
    assert_includes offered, "The Cozy Bakery"
    assert_includes offered, "Hannah Bakery"
    assert route.suggestions.all? { |s| s[:unvisited] && s[:id].nil? },
           "an unvisited destination has no room id and should not pretend to"
  end

  # --- the walk ---------------------------------------------------------------

  # Half of this feature lives in Navigator: without the nil-expectation rule
  # the last step would look like a stale edge and trigger a replan every time.
  def test_the_walker_does_not_treat_the_unknown_last_step_as_a_surprise
    a = room("A"); b = room("B")
    link(a, "north", b)
    frontier(b, "east", "The Cozy Bakery")

    calls = []
    mud = lambda do |name, args = {}, _meta = {}|
      calls << [ name.sub("tbamud__", ""), args[:direction] ]
      "\e[0;33mThe Cozy Bakery\e[0m\r\n   Warm air.\r\n\e[0;36m[ Exits: w ]\e[0m\r\n\r\n100H 100M 100V > "
    end
    # The destination room does not exist when the route is planned — that is
    # the whole premise — so it is created on arrival, exactly as
    # Hooks#discover does when the agent walks somewhere new.
    arrivals = [ b ]
    nav = Boukensha::Mud::Navigator.new(call_tool: mud, store: @store,
                                        on_arrival: ->(*) { arrivals.shift || room("The Cozy Bakery") })

    result = nav.navigate(destination: "The Cozy Bakery", from: a)

    assert result[:ok], "walking off the map is the plan, not a failure"
    assert_equal 0, result[:replans], "an absent expectation is not a violated one"
    assert_equal %w[north east], result[:path]
    assert_equal [ %w[move north], %w[move east] ], calls
  end

  def test_the_rendered_line_says_the_destination_was_never_visited
    line = Boukensha::Mud::Navigator.render(
      ok: true, reason: :arrived, goal_name: "The Cozy Bakery", provisional: true,
      steps_planned: 2, steps_walked: 2, path: %w[north east]
    )

    assert_includes line, "The Cozy Bakery (unvisited)"
  end
end
