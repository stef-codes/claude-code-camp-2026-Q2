require_relative "helper"

class TestSpec < Minitest::Test
  def test_every_tool_has_name_description_and_schema
    MudManager::Mcp::Spec.mcp_tools.each do |t|
      assert t["name"].is_a?(String) && !t["name"].empty?
      assert t["description"].is_a?(String) && !t["description"].empty?
      assert_equal "object", t["inputSchema"]["type"]
    end
  end

  def test_enums_are_pulled_live_from_primitives
    move = MudManager::Mcp::Spec.mcp_tools.find { |t| t["name"] == "move" }
    assert_equal MudManager::Primitives::DIRECTIONS,
                 move["inputSchema"]["properties"]["direction"]["enum"]
  end

  def test_required_params_are_marked
    examine = MudManager::Mcp::Spec.mcp_tools.find { |t| t["name"] == "examine" }
    assert_includes examine["inputSchema"]["required"], "target"

    # look has no required params, so the key is omitted entirely
    look = MudManager::Mcp::Spec.mcp_tools.find { |t| t["name"] == "look" }
    refute look["inputSchema"].key?("required")
  end

  def test_surface_matches_boukensha_tools
    # The gameplay surface boukensha used to implement in-process as Tools::Mud
    # (now deleted — boukensha owns no tools) must all live here instead, since
    # this daemon is the only implementation left. Connection tools stay hidden
    # behind the boundary on purpose.
    expected = %w[look examine check move flee set_position track attack
                  skill_strike consider say tell channel_say get_item drop_item
                  put_item equip_item consume_item cast_spell use_magic_item
                  shop practice save_character send_raw]
    names = MudManager::Mcp::Spec.mcp_tools.map { |t| t["name"] }
    expected.each { |n| assert_includes names, n, "missing tool #{n}" }
    # plus the daemon additions
    assert_includes names, "poll"
    assert_includes names, "mud_status"
  end

  def test_primitives_json_roundtrips
    json = MudManager::Mcp::Spec.primitives_json
    data = JSON.parse(json)
    assert_equal MudManager::VERSION, data["version"]
    assert data["tools"]["attack"]["args"]["style"]["enum"].include?("murder")
    assert_equal true, data["tools"]["examine"]["args"]["target"]["required"]
  end

  # A preposition with no target used to build `look at`, which the MUD answers
  # with "Look at what?" — leaving the room description unreachable through the
  # `look` tool. Models hit this constantly: `target: "room"` fails as an
  # unknown object, and the retry `target: ""` left the preposition dangling.
  def test_look_drops_a_preposition_with_no_target
    assert_equal "look", MudManager::Primitives.look(preposition: "at").raw
    assert_equal "look", MudManager::Primitives.look(target: "", preposition: "at").raw
    assert_equal "look", MudManager::Primitives.look(target: "  ", preposition: "in").raw
    # A direction-as-preposition is the same shape and degrades the same way.
    assert_equal "look", MudManager::Primitives.look(preposition: "north").raw
  end

  # The dominant real-world failure: the model names the room as the target.
  # `look at room` is answered with "You do not see that here", so the room
  # description was unreachable through the tool and the agent fell back to
  # send_raw after burning iterations.
  def test_look_treats_room_synonyms_as_no_target
    %w[room here area surroundings].each do |alias_word|
      assert_equal "look", MudManager::Primitives.look(target: alias_word, preposition: "at").raw,
                   "target: #{alias_word.inspect} should degrade to a plain look"
      assert_equal "look", MudManager::Primitives.look(target: alias_word).raw
    end
    # Multi-word and mixed-case phrasings, including odd internal spacing.
    assert_equal "look", MudManager::Primitives.look(target: "The Room", preposition: "at").raw
    assert_equal "look", MudManager::Primitives.look(target: "current  room").raw
    assert_equal "look", MudManager::Primitives.look(target: " MY SURROUNDINGS ").raw
  end

  # The aliases must not swallow real objects whose names merely contain one.
  def test_look_keeps_targets_that_only_contain_an_alias_word
    assert_equal "look at room key", MudManager::Primitives.look(target: "room key", preposition: "at").raw
    assert_equal "look at areamap", MudManager::Primitives.look(target: "areamap", preposition: "at").raw
  end

  def test_look_still_builds_targeted_and_bare_forms
    assert_equal "look", MudManager::Primitives.look.raw
    assert_equal "look at baker", MudManager::Primitives.look(target: "baker", preposition: "at").raw
    assert_equal "look in bag", MudManager::Primitives.look(target: "bag", preposition: "in").raw
    # No preposition, just a target: the MUD treats `look <thing>` as examine.
    assert_equal "look sign", MudManager::Primitives.look(target: "sign").raw
  end
end
