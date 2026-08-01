require_relative "helper"

# Mud::Localizer — scored candidate-set localization (week_2_plan Phase 6).
class TestLocalizer < Minitest::Test
  M = Boukensha::Mud::Memory
  F = Boukensha::Mud::Memory::Fingerprint
  L = Boukensha::Mud::Localizer

  Look = Struct.new(:name, :description, :exit_dirs, keyword_init: true)

  def setup
    @store = M::Store.open(":memory:")
  rescue M::Store::Unavailable => e
    skip e.message
  end

  def teardown
    @store&.close
  end

  def room(name, desc:, exits:, strong_targets: nil)
    weak = F.weak(name: name, description: desc, exit_dirs: exits)
    strong = strong_targets && F.strong(weak, strong_targets)
    id = @store.create_room(name: name, description: desc, weak_fingerprint: weak,
                            strong_fingerprint: strong)
    @store.record_exits!(id, dirs: exits, targets: strong_targets || {})
    id
  end

  def test_transition_match_disambiguates_identical_titles
    # Two rooms, same title/exits text, different arrival edges.
    a = room("Twisty Passage", desc: "A maze of twisty passages.", exits: %w[north south])
    b = room("Twisty Passage", desc: "A maze of twisty passages.", exits: %w[north south])
    origin = room("Foyer", desc: "You stand in a foyer.", exits: %w[east])
    @store.link_exit!(origin, "east", b)

    look = Look.new(name: "Twisty Passage", description: "A maze of twisty passages.",
                    exit_dirs: %w[north south])
    candidates = @store.rooms_by_weak(
      F.weak(name: look.name, description: look.description, exit_dirs: look.exit_dirs)
    )
    assert_equal 2, candidates.size

    scores = L.new(@store).score(look, candidates: candidates, from_id: origin, direction: "east")
    assert scores[b] > scores[a], "transition match should prefer the linked destination"
    assert_equal b, L.new(@store).pick(scores)
  end

  def test_exit_target_names_break_ties
    a = room("Square", desc: "Open square.", exits: %w[north east],
             strong_targets: { "north" => "Temple", "east" => "Street" })
    b = room("Square", desc: "Open square.", exits: %w[north east],
             strong_targets: { "north" => "Alley", "east" => "Gate" })

    look = Look.new(name: "Square", description: "Open square.", exit_dirs: %w[north east])
    candidates = [ @store.room(a), @store.room(b) ]
    scores = L.new(@store).score(look, candidates: candidates,
                                 exit_targets: { "north" => "Temple", "east" => "Street" })
    assert scores[a] > scores[b]
    assert_equal a, L.new(@store).pick(scores)
  end

  def test_pick_returns_nil_when_scores_are_too_close
    a = room("Hall", desc: "Long hall with tapestries.", exits: %w[north])
    b = room("Hall", desc: "Long hall with paintings.", exits: %w[north])
    look = Look.new(name: "Hall", description: "Long hall.", exit_dirs: %w[north])
    candidates = [ @store.room(a), @store.room(b) ]
    scores = L.new(@store).score(look, candidates: candidates)
    # Without transition or exit-target evidence, titles match equally — no winner.
    assert_nil L.new(@store).pick(scores, margin: 0.5)
  end
end
