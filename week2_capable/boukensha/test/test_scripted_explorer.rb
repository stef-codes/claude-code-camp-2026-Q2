require_relative "helper"

# Scripted Mud::Explorer — nearest-frontier loop without an LLM.
class TestScriptedExplorer < Minitest::Test
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

  def room(name, exits: %w[north])
    desc = "prose for #{name}"
    id = @store.create_room(name: name, description: desc,
                            weak_fingerprint: F.weak(name: name, description: desc, exit_dirs: exits))
    @store.record_exits!(id, dirs: exits)
    id
  end

  def arrival(name, dirs = "s")
    "\e[0;33m#{name}\e[0m\r\n   Some prose about #{name}.\r\n" \
      "\e[0;36m[ Exits: #{dirs} ]\e[0m\r\n\r\n500H 100M 82V > "
  end

  def test_walks_a_frontier_exit_and_links_arrival
    a = room("Start", exits: %w[north])
    arrivals = []
    mud = lambda do |name, args|
      assert_equal "tbamud__move", name
      assert_equal "north", args[:direction]
      arrival("The Bakery", "s")
    end

    on_arrival = lambda do |look, from, direction, _text|
      arrivals << [look.name, from, direction]
      b = room(look.name, exits: look.exit_dirs)
      @store.link_exit!(from, direction, b)
      b
    end

    explorer = Boukensha::Mud::Explorer.new(
      call_tool: mud, store: @store, on_arrival: on_arrival,
      navigate: ->(**) { { ok: true, path: [], stopped_at: a } }
    )

    result = explorer.explore(from: a, max_rooms: 1)
    assert result[:ok], "expected ok, got #{result.inspect}"
    assert_equal 1, result[:rooms_added]
    assert_equal %w[north], result[:steps]
    assert_equal 1, arrivals.size
  end

  def test_render_ok_and_failure
    assert_includes Boukensha::Mud::Explorer.render(ok: true, rooms_added: 2, steps: %w[north east]),
                    "2 new rooms"
    assert_includes Boukensha::Mud::Explorer.render(ok: false, reason: :no_frontier),
                    "no_frontier"
  end
end
