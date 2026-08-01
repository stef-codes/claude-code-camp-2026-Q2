require_relative "helper"

# Mud::Mode coercion + StateBlock mode rendering.
class TestModeAndGuardrails < Minitest::Test
  def test_mode_coerce_falls_back_to_navigating
    assert_equal :localizing, Boukensha::Mud::Mode.coerce("localizing")
    assert_equal :relocalizing, Boukensha::Mud::Mode.coerce(:relocalizing)
    assert_equal :navigating, Boukensha::Mud::Mode.coerce("nope")
  end

  def test_state_block_shows_non_navigating_mode
    room = { name: "Bakery", visit_count: 1, description: "Smells good." }
    text = Boukensha::Mud::StateBlock.render(room: room, mode: :relocalizing, ambiguity: 2)
    assert_includes text, "[relocalizing]"
    assert_includes text, "uncertain — 2 candidates"
  end

  def test_state_block_omits_navigating_mode_tag
    room = { name: "Bakery", visit_count: 2, description: "" }
    text = Boukensha::Mud::StateBlock.render(room: room, mode: :navigating)
    refute_includes text, "[navigating]"
  end
end
