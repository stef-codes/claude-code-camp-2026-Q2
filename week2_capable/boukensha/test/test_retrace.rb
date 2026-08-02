require_relative "helper"

# Hooks#retrace — walk back along arrival breadcrumbs without inventing edges.
class TestRetrace < Minitest::Test
  M = Boukensha::Mud::Memory
  F = Boukensha::Mud::Memory::Fingerprint

  def setup
    @store = M::Store.open(":memory:")
  rescue M::Store::Unavailable => e
    skip e.message
  end

  def teardown
    @store&.close
  end

  def room(name, exits:)
    # Description must match look_text exactly — weak fingerprint is the join.
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

  def test_retrace_walks_opposite_when_no_return_edge_is_stored
    origin = room("Origin", exits: %w[north])
    neighbour = room("Neighbour", exits: %w[south])
    @store.link_exit!(origin, "north", neighbour)
    # No Neighbour→Origin link — retrace must try south as an action.

    responses = {
      "look" => look_text("Origin", %w[north]),
      "move:north" => look_text("Neighbour", %w[south]),
      "move:south" => look_text("Origin", %w[north])
    }
    mud = lambda do |name, args = {}, _meta = {}|
      tool = name.sub(/\A.*__/, "")
      key = args[:direction] ? "#{tool}:#{args[:direction]}" : tool
      responses.fetch(key) { raise "unexpected #{key}" }
    end

    hooks = Boukensha::Mud::Hooks.new(store: @store, call_tool: mud, warn_to: nil)
    hooks.before_model(context: Boukensha::Context.new(system: ""))
    assert_equal origin, hooks.current_room_id

    nav = hooks.navigate(destination: neighbour)
    assert nav[:ok], nav.inspect
    assert_equal neighbour, hooks.current_room_id
    assert_equal 1, hooks.trail.length

    result = hooks.retrace
    assert result[:ok], result.inspect
    assert_equal :retraced, result[:reason]
    assert_equal %w[south], result[:steps]
    assert_equal origin, hooks.current_room_id
    assert_empty hooks.trail

    # Return edge written only because the MUD confirmed the opposite move.
    back = @store.exit_at(neighbour, "south")
    assert_equal origin, back[:target_room_id]
  end

  def test_retrace_prefers_a_known_return_exit_over_opposite
    a = room("A", exits: %w[north])
    b = room("B", exits: %w[east]) # return is east, not south
    @store.link_exit!(a, "north", b)
    @store.link_exit!(b, "east", a)

    responses = {
      "look" => look_text("A", %w[north]),
      "move:north" => look_text("B", %w[east]),
      "move:east" => look_text("A", %w[north])
    }
    mud = lambda do |name, args = {}, _meta = {}|
      tool = name.sub(/\A.*__/, "")
      key = args[:direction] ? "#{tool}:#{args[:direction]}" : tool
      responses.fetch(key) { raise "unexpected #{key}" }
    end

    hooks = Boukensha::Mud::Hooks.new(store: @store, call_tool: mud, warn_to: nil)
    hooks.before_model(context: Boukensha::Context.new(system: ""))
    hooks.navigate(destination: b)

    result = hooks.retrace
    assert result[:ok], result.inspect
    assert_equal %w[east], result[:steps], "known return exit beats conventional opposite"
  end

  def test_empty_trail_fails_honestly
    room("Alone", exits: %w[north])
    mud = lambda do |name, _args = {}, _meta = {}|
      raise "unexpected #{name}" unless name.end_with?("look")

      look_text("Alone", %w[north])
    end
    hooks = Boukensha::Mud::Hooks.new(store: @store, call_tool: mud, warn_to: nil)
    hooks.before_model(context: Boukensha::Context.new(system: ""))

    result = hooks.retrace
    refute result[:ok]
    assert_equal :empty_trail, result[:reason]
  end
end
