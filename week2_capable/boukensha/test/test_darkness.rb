require_relative "helper"

# Pitch-black visibility: state block, explore refusal, hint-crumb retrace.
class TestDarkness < Minitest::Test
  M = Boukensha::Mud::Memory
  F = Boukensha::Mud::Memory::Fingerprint
  S = Boukensha::Mud::StateBlock

  PITCH_BLACK = "It is pitch black...\r\n\r\n500H 100M 82V > ".freeze

  def setup
    @store = M::Store.open(":memory:")
  rescue M::Store::Unavailable => e
    skip e.message
  end

  def teardown
    @store&.close
  end

  def room(name, exits:)
    desc = "Some prose about #{name}."
    id = @store.create_room(name: name, description: desc,
                            weak_fingerprint: F.weak(name: name, description: desc, exit_dirs: exits),
                            surveyed: true)
    @store.record_exits!(id, dirs: exits)
    id
  end

  def look_text(name, dirs)
    abbrev = { "north" => "n", "south" => "s", "east" => "e", "west" => "w" }
    short = Array(dirs).map { |d| abbrev[d] || d }.join(" ")
    "\e[0;33m#{name}\e[0m\r\n   Some prose about #{name}.\r\n" \
      "\e[0;36m[ Exits: #{short} ]\e[0m\r\n\r\n500H 100M 82V > "
  end

  def test_pitch_black_helper
    assert Boukensha::Mud::RoomParser.pitch_black?(PITCH_BLACK)
    refute Boukensha::Mud::RoomParser.pitch_black?(look_text("A", %w[north]))
  end

  def test_state_block_shows_dark_and_last_known
    out = S.render(
      room: nil,
      player: { hp: 500, mana: 100, move: 82, level: 34 },
      dark: true,
      last_known: {
        room_name: "Dirt Road", room_id: 71,
        from_name: "Edge of a Clearing", from_id: 70,
        direction: "north"
      }
    )

    assert_includes out, "[here] DARK — cannot see the room"
    assert_includes out, "last known: Dirt Road (#71) · arrived north from Edge of a Clearing (#70)"
    refute_includes out, "unknown — no room established yet"
  end

  def test_cold_pitch_black_sets_dark_and_renders_last_known
    origin = room("Edge of a Clearing", exits: %w[north])
    dirt   = room("Dirt Road", exits: %w[south])
    @store.link_exit!(origin, "north", dirt)
    @store.update_player!(current_room_id: dirt, prev_room_id: origin, last_direction: "north",
                          hp: 500, mana: 100, move: 82)

    mud = lambda do |name, _args = {}, _meta = {}|
      raise "unexpected #{name}" unless name.end_with?("look")

      PITCH_BLACK
    end
    hooks = Boukensha::Mud::Hooks.new(store: @store, call_tool: mud, warn_to: nil)
    ctx = Boukensha::Context.new(system: "")
    hooks.before_model(context: ctx)

    assert hooks.dark?
    assert_nil hooks.current_room_id
    assert_includes ctx.state_block, "DARK — cannot see the room"
    assert_includes ctx.state_block, "Dirt Road"
    assert_includes ctx.state_block, "Edge of a Clearing"
  end

  def test_scripted_explore_refuses_when_dark
    room("Alone", exits: %w[north])
    mud = lambda do |name, _args = {}, _meta = {}|
      return PITCH_BLACK if name.end_with?("look")

      raise "unexpected #{name}"
    end
    hooks = Boukensha::Mud::Hooks.new(store: @store, call_tool: mud, warn_to: nil)
    hooks.before_model(context: Boukensha::Context.new(system: ""))

    result = hooks.scripted_explore(max_rooms: 1)
    assert_equal :too_dark, result[:reason]
    refute result[:ok]
    assert_includes Boukensha::Mud::Explorer.render(result), "get light"
  end

  def test_hint_crumb_retrace_when_trail_empty_and_position_cold
    origin = room("Origin", exits: %w[north])
    neighbour = room("Neighbour", exits: %w[south])
    @store.link_exit!(origin, "north", neighbour)
    # No reverse link — retrace tries opposite south.
    @store.update_player!(current_room_id: neighbour, prev_room_id: origin,
                          last_direction: "north", hp: 500, mana: 100, move: 82)

    responses = {
      "look" => PITCH_BLACK, # cold start: dark, no live position
      "move:south" => look_text("Origin", %w[north])
    }
    mud = lambda do |name, args = {}, _meta = {}|
      tool = name.sub(/\A.*__/, "")
      key = args[:direction] ? "#{tool}:#{args[:direction]}" : tool
      responses.fetch(key) { raise "unexpected #{key}" }
    end

    hooks = Boukensha::Mud::Hooks.new(store: @store, call_tool: mud, warn_to: nil)
    hooks.before_model(context: Boukensha::Context.new(system: ""))
    assert hooks.dark?
    assert_nil hooks.current_room_id
    assert_empty hooks.trail

    result = hooks.retrace
    assert result[:ok], result.inspect
    assert_equal %w[south], result[:steps]
    assert_equal origin, hooks.current_room_id
    refute hooks.dark?
  end

  def test_hint_retrace_reports_too_dark_when_return_is_still_black
    origin = room("Origin", exits: %w[north])
    neighbour = room("Neighbour", exits: %w[south])
    @store.link_exit!(origin, "north", neighbour)
    @store.update_player!(current_room_id: neighbour, prev_room_id: origin,
                          last_direction: "north")

    mud = lambda do |name, args = {}, _meta = {}|
      tool = name.sub(/\A.*__/, "")
      return PITCH_BLACK if tool == "look" || tool == "move"

      raise "unexpected #{name} #{args}"
    end
    hooks = Boukensha::Mud::Hooks.new(store: @store, call_tool: mud, warn_to: nil)
    hooks.before_model(context: Boukensha::Context.new(system: ""))

    result = hooks.retrace
    refute result[:ok]
    assert_equal :too_dark, result[:reason]
    assert_includes Boukensha::Mud::Hooks.render_retrace(result), "too_dark"
  end

  def test_ensure_lit_uses_holylight_and_clears_dark
    dirt = room("Dirt Road", exits: %w[south])
    @store.update_player!(current_room_id: dirt, hp: 500, mana: 100, move: 82)

    looks = [PITCH_BLACK, look_text("Dirt Road", %w[south])]
    raws = []
    mud = lambda do |name, args = {}, _meta = {}|
      tool = name.sub(/\A.*__/, "")
      case tool
      when "look" then looks.shift || look_text("Dirt Road", %w[south])
      when "send_raw"
        raws << (args[:command] || args["command"])
        "HolyLight mode on.\r\n\r\n500H 100M 82V > "
      else
        raise "unexpected #{name} #{args}"
      end
    end

    hooks = Boukensha::Mud::Hooks.new(store: @store, call_tool: mud,
                                      illuminate_call_tool: mud, warn_to: nil)
    ctx = Boukensha::Context.new(system: "")
    hooks.before_model(context: ctx)

    refute hooks.dark?, "holylight should clear pitch black"
    assert_equal dirt, hooks.current_room_id
    assert_equal ["holylight"], raws
    assert_includes ctx.state_block, "Dirt Road"
    refute_includes ctx.state_block, "DARK"
  end

  def test_ensure_fed_eats_waybread_when_hungry
    dirt = room("Dirt Road", exits: %w[south])
    @store.update_player!(current_room_id: dirt, hp: 500, mana: 100, move: 82,
                          conditions: "hungry")

    eats = []
    mud = lambda do |name, args = {}, _meta = {}|
      tool = name.sub(/\A.*__/, "")
      case tool
      when "look" then look_text("Dirt Road", %w[south])
      when "consume_item"
        eats << [args[:mode] || args["mode"], args[:item] || args["item"]]
        "You eat the waybread.\r\n\r\n500H 100M 82V > "
      else
        raise "unexpected #{name} #{args}"
      end
    end

    hooks = Boukensha::Mud::Hooks.new(store: @store, call_tool: mud,
                                      illuminate_call_tool: mud, warn_to: nil)
    hooks.before_model(context: Boukensha::Context.new(system: ""))
    assert_equal [["eat", "waybread"]], eats
  end
end
