require_relative "helper"

# Weighted RouteFinder — prefer low-danger / low-failure edges (week_2_plan Phase 7).
class TestRouteFinderWeights < Minitest::Test
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

  def room(name)
    desc = "prose for #{name}"
    @store.create_room(name: name, description: desc,
                       weak_fingerprint: F.weak(name: name, description: desc, exit_dirs: %w[north]))
  end

  def link(from, direction, to)
    @store.record_exits!(from, dirs: [direction])
    @store.link_exit!(from, direction, to)
  end

  def test_avoids_a_high_danger_edge_when_a_safer_route_exists
    a = room("A"); b = room("B"); c = room("C"); d = room("D")
    # Short but dangerous: A →north→ D
    link(a, "north", d)
    @store.set_exit_danger!(a, "north", 2.0)
    # Longer but safe: A →east→ B →east→ C →north→ D
    link(a, "east", b)
    link(b, "east", c)
    link(c, "north", d)

    steps = @finder.route(from: a, to: "D").steps
    refute_equal %w[north], steps, "Dijkstra should avoid the dangerous shortcut"
    assert_equal %w[east east north], steps
  end

  def test_avoids_an_edge_with_repeated_failures
    a = room("A"); b = room("B"); goal = room("Goal")
    link(a, "north", goal)
    5.times { @store.record_exit_failure!(a, "north") }
    link(a, "east", b)
    link(b, "east", goal)

    assert_equal %w[east east], @finder.route(from: a, to: "Goal").steps
  end

  def test_unweighted_equal_cost_still_picks_a_shortest_hop_path
    a = room("A"); b = room("B"); c = room("C")
    link(a, "north", b); link(b, "north", c)
    link(a, "up", c)

    assert_equal %w[up], @finder.route(from: a, to: "C").steps
  end
end
