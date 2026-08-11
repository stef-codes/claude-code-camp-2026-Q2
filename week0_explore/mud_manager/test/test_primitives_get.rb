# frozen_string_literal: true

require_relative "helper"
require "mud_manager/primitives"

# CircleMUD get parsing: a bare leading integer is the object name, not a count.
class TestPrimitivesGet < Minitest::Test
  P = MudManager::Primitives

  def test_get_all_corpse_ignores_count_one
    cmd = P.get("all", container: "corpse", count: 1)
    assert_equal "get all corpse", cmd.raw
  end

  def test_get_floor_item_omits_count_one
    cmd = P.get("small sword", count: 1)
    assert_equal "get small sword", cmd.raw
  end

  def test_get_floor_item_no_count
    cmd = P.get("gold coins")
    assert_equal "get gold coins", cmd.raw
  end

  def test_get_nth_match_uses_dotted_form
    cmd = P.get("sword", count: 2)
    assert_equal "get 2.sword", cmd.raw
  end

  def test_empty_container_string_treated_as_absent
    cmd = P.get("coins", container: "", count: 1)
    assert_equal "get coins", cmd.raw
  end
end
