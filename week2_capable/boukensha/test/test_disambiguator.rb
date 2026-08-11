require_relative "helper"

# Mud::Disambiguator — choose the move that splits candidates furthest.
class TestDisambiguator < Minitest::Test
  M = Boukensha::Mud::Memory
  F = Boukensha::Mud::Memory::Fingerprint
  D = Boukensha::Mud::Disambiguator

  def setup
    @store = M::Store.open(":memory:")
  rescue M::Store::Unavailable => e
    skip e.message
  end

  def teardown
    @store&.close
  end

  def room(name)
    desc = "desc #{name}"
    @store.create_room(name: name, description: desc,
                       weak_fingerprint: F.weak(name: name, description: desc, exit_dirs: %w[north]))
  end

  def link(from, direction, to)
    @store.record_exits!(from, dirs: [direction])
    @store.link_exit!(from, direction, to)
  end

  def test_picks_the_direction_whose_destinations_diverge
    # Candidates A and B both have north→same room, but east→different rooms.
    a = room("A"); b = room("B")
    shared = room("Shared"); east_a = room("EastA"); east_b = room("EastB")
    link(a, "north", shared); link(b, "north", shared)
    link(a, "east", east_a);  link(b, "east", east_b)

    action = D.new(@store).choose_disambiguating_action([a, b])
    assert_equal "east", action[:direction]
    assert_equal 2, action[:divergence]
  end

  def test_suggest_actions_ranks_by_divergence
    a = room("A"); b = room("B")
    n1 = room("N1"); n2 = room("N2")
    e1 = room("E1"); e2 = room("E2")
    link(a, "north", n1); link(b, "north", n2)
    link(a, "east", e1);  link(b, "east", e2)

    suggestions = D.new(@store).suggest_actions([a, b])
    assert_equal %w[east north], suggestions.map { |s| s[:direction] }.sort
    assert suggestions.all? { |s| s[:divergence] == 2 }
  end

  def test_returns_nil_when_candidates_have_no_diverging_exit
    a = room("A"); b = room("B")
    shared = room("Shared")
    link(a, "north", shared); link(b, "north", shared)

    assert_nil D.new(@store).choose_disambiguating_action([a, b])
  end
end
