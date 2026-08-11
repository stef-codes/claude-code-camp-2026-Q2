require_relative "helper"

# Mud::Navigator: the walk, and what it refuses to keep walking through.
#
# The Navigator's whole dependency on the outside world is the injected
# `call_tool` lambda, so the entire walk is testable against a script with no
# MUD, no MCP and no network. What matters here is the sequence it issues (N
# moves and NOTHING else), and that it stops the moment the MUD stops agreeing.
class TestNavigator < Minitest::Test
  M  = Boukensha::Mud::Memory
  F  = Boukensha::Mud::Memory::Fingerprint
  NV = Boukensha::Mud::Navigator

  # A room reply shaped the way `complete?` requires: a name, an exits line and
  # a prompt. Anything missing one of those is a refusal, by construction.
  def arrival(name, dirs = "n e")
    "\e[0;33m#{name}\e[0m\r\n   Some prose about #{name}.\r\n" \
      "\e[0;36m[ Exits: #{dirs} ]\e[0m\r\n\r\n500H 100M 82V > "
  end

  REFUSAL_CLOSED = "The door is closed.\r\n\r\n500H 100M 82V > ".freeze
  REFUSAL_DARK   = "It is pitch black...\r\n\r\n500H 100M 82V > ".freeze

  # Records what was asked and replies from a queue, one per move.
  class FakeMud
    attr_reader :calls

    def initialize(replies)
      @replies = replies.dup
      @calls = []
    end

    def to_proc
      lambda do |name, args = {}, _meta = {}|
        @calls << [name.sub("tbamud__", ""), args]
        @replies.shift || ""
      end
    end

    def moves = @calls.select { |(n, _)| n == "move" }.map { |(_, a)| a[:direction] }
  end

  def setup
    @store = M::Store.open(":memory:")
  rescue M::Store::Unavailable => e
    skip e.message
  end

  def teardown
    @store&.close
  end

  def room(name, desc: "prose for #{name}")
    @store.create_room(name: name, description: desc,
                       weak_fingerprint: F.weak(name: name, description: desc, exit_dirs: %w[north]))
  end

  def link(from, direction, to)
    @store.record_exits!(from, dirs: [direction])
    @store.link_exit!(from, direction, to)
  end

  # Stands in for Hooks#navigator_arrival: the ONLY place identity is decided.
  # The script says which room each arrival resolves to.
  def arrivals(*ids)
    queue = ids.dup
    @absorbed = []
    lambda do |_look, _from, _direction, text = nil|
      @absorbed << text
      queue.shift
    end
  end

  def navigator(mud, on_arrival, **opts)
    NV.new(call_tool: mud.to_proc, store: @store, on_arrival: on_arrival, **opts)
  end

  # --- the happy path --------------------------------------------------------

  def test_a_clean_walk_issues_one_move_per_step_and_nothing_else
    a = room("A"); b = room("B"); c = room("C")
    link(a, "north", b); link(b, "east", c)

    mud = FakeMud.new([arrival("B"), arrival("C")])
    result = navigator(mud, arrivals(b, c)).navigate(destination: "C", from: a)

    assert result[:ok]
    assert_equal :arrived, result[:reason]
    assert_equal %w[north east], result[:path]
    assert_equal 2, result[:steps_walked]
    assert_equal c, result[:stopped_at]
    # The narrow allowlist is the point: a navigation never pays for a `look`.
    assert_equal %w[north east], mud.moves
    assert_equal %w[move move], mud.calls.map(&:first)
  end

  # The Navigator's moves bypass after_tool entirely (they go through a separate
  # Registry with no hooks), so the RAW text has to reach the arrival callback
  # or a whole walk's worth of HP readings, level-ups and deaths is discarded.
  # A parsed Look carries none of that, which is why both are passed.
  def test_the_raw_mud_text_reaches_the_arrival_callback
    a = room("A"); b = room("B")
    link(a, "north", b)

    reply = arrival("B")
    mud = FakeMud.new([reply])
    navigator(mud, arrivals(b)).navigate(destination: "B", from: a)

    assert_equal [reply], @absorbed,
                 "absorb_mud_text needs the raw text, not the parsed Look"
  end

  def test_walking_nowhere_costs_no_round_trips
    a = room("A")
    mud = FakeMud.new([])

    result = navigator(mud, arrivals).navigate(destination: "A", from: a)

    assert result[:ok]
    assert_equal :already_here, result[:reason]
    assert_empty mud.calls
  end

  # --- refusals --------------------------------------------------------------

  # The success whitelist means the Navigator needs to know no MUD strings at
  # all: anything that isn't a complete room stops the walk.
  def test_a_closed_door_stops_the_walk_and_quotes_the_mud_verbatim
    a = room("A"); b = room("B"); c = room("C")
    link(a, "north", b); link(b, "east", c)

    mud = FakeMud.new([arrival("B"), REFUSAL_CLOSED])
    result = navigator(mud, arrivals(b)).navigate(destination: "C", from: a)

    refute result[:ok]
    assert_equal :blocked, result[:reason]
    assert_equal 1, result[:steps_walked]
    assert_equal 2, result[:steps_planned]
    assert_equal b, result[:stopped_at], "it must say where the agent is actually left"
    assert_equal "The door is closed.", result[:blocked_by]
    assert_equal 2, mud.calls.length, "it stops; it does not try the rest of the route"
  end

  def test_darkness_stops_the_walk_too_without_a_rule_naming_it
    a = room("A"); b = room("B")
    link(a, "north", b)

    mud = FakeMud.new([REFUSAL_DARK])
    result = navigator(mud, arrivals).navigate(destination: "B", from: a)

    refute result[:ok]
    assert_equal :blocked, result[:reason]
    assert_equal "It is pitch black...", result[:blocked_by]
  end

  # --- a stale map -----------------------------------------------------------

  # A surprise is not a failure: Hooks#link_arrival has already repaired the bad
  # edge by the time we notice, so the walk replans from where it really is.
  def test_an_unexpected_arrival_replans_once_from_the_truth
    a = room("A"); b = room("B"); c = room("C"); x = room("X")
    link(a, "north", b); link(b, "east", c)
    link(x, "south", c)   # the way on from where we actually land

    # Step 1 lands in X, not B. Replan finds X→south→C.
    mud = FakeMud.new([arrival("X"), arrival("C")])
    result = navigator(mud, arrivals(x, c)).navigate(destination: "C", from: a)

    assert result[:ok], "a stale edge is recoverable, not fatal"
    assert_equal 1, result[:replans]
    assert_equal %w[north south], result[:path]
    assert_equal c, result[:stopped_at]
  end

  def test_a_second_surprise_gives_up_rather_than_guessing
    a = room("A"); b = room("B"); c = room("C"); x = room("X"); y = room("Y")
    link(a, "north", b); link(b, "east", c)
    link(x, "south", c)

    # Lands in X (replan), then the replanned step lands in Y. Enough.
    mud = FakeMud.new([arrival("X"), arrival("Y")])
    result = navigator(mud, arrivals(x, y)).navigate(destination: "C", from: a)

    refute result[:ok]
    assert_equal :lost, result[:reason]
    assert_equal y, result[:stopped_at]
  end

  # --- routing failures never cost a round trip ------------------------------

  def test_an_unroutable_destination_never_touches_the_mud
    a = room("A"); room("Faraway")
    mud = FakeMud.new([])

    result = navigator(mud, arrivals).navigate(destination: "Faraway", from: a)

    refute result[:ok]
    assert_equal :no_route, result[:reason]
    assert_empty mud.calls, "planning is free; only walking costs"
  end

  # --- the rendered line -----------------------------------------------------

  # This string is what the model actually reads, so every branch must say where
  # the agent ended up. A failed navigation still moved it.
  def test_render_states_the_outcome_and_the_position_in_every_branch
    ok = { ok: true, reason: :arrived, goal_name: "Market Square", goal_id: 7,
           steps_planned: 3, steps_walked: 3, path: %w[north east east] }
    assert_equal "navigate → Market Square (#7): 3 of 3 · north, east, east", NV.render(ok)

    blocked = { ok: false, reason: :blocked, goal_name: "The Temple", goal_id: 12,
                steps_planned: 5, steps_walked: 2, stopped_at: 4,
                stopped_at_name: "Main Street", blocked_by: "The door is closed." }
    line = NV.render(blocked)
    assert_includes line, "stopped after 2 of 5"
    assert_includes line, "Main Street (#4)"
    assert_includes line, '"The door is closed."'

    unknown = { ok: false, reason: :unknown_destination, destination: "bakery",
                suggestions: [{ id: 9, name: "The Cozy Bakery" }] }
    assert_includes NV.render(unknown), "did you mean: The Cozy Bakery (#9)?"

    no_route = { ok: false, reason: :no_route, destination: "X", goal_name: "X", goal_id: 3,
                 frontier: [{ direction: "east", target_name: "A Dark Alley" }] }
    assert_includes NV.render(no_route), "unexplored from here: east→A Dark Alley"
  end
end
