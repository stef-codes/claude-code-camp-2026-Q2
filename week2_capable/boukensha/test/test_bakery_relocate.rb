require_relative "helper"

# Immortal Relocate: bakery goal + no routable path → one goto, then look.
class TestBakeryRelocate < Minitest::Test
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

  # Survey discover() always spends check(exits) for target names.
  def exits_text(dirs_to_names)
    lines = dirs_to_names.map { |d, n| "#{d.to_s[0].upcase} - #{n}" }
    "#{lines.join("\r\n")}\r\n\r\n500H 100M 82V > "
  end

  def bakery_context(text)
    ctx = Boukensha::Context.new(system: "")
    ctx.add_message(:user, text)
    ctx
  end

  def test_bakery_goal_no_route_triggers_goto_then_look
    grass = room("Grasslands", exits: %w[north east south west])
    @store.update_player!(current_room_id: grass, hp: 500, mana: 100, move: 82)

    raws = []
    looks = [
      look_text("Grasslands", %w[north east south west]),
      look_text("The Bakery", %w[west])
    ]
    mud = lambda do |name, args = {}, _meta = {}|
      tool = name.sub(/\A.*__/, "")
      case tool
      when "look" then looks.shift || raise("extra look")
      when "check"
        exits_text("west" => "The Common Square")
      when "send_raw"
        raws << (args[:command] || args["command"])
        "You goto 3009.\r\n"
      else
        raise "unexpected #{name} #{args}"
      end
    end

    hooks = Boukensha::Mud::Hooks.new(
      store: @store, call_tool: mud, relocate_call_tool: mud,
      bakery_room_vnum: 3009, bakery_destination: "The Bakery", warn_to: nil
    )
    hooks.before_model(context: bakery_context("go to the bakery and tell me what's on the menu"))

    assert_equal ["goto 3009"], raws
    assert_empty looks, "expected cold look + post-goto look"
    bakery_id = hooks.current_room_id
    refute_nil bakery_id
    assert_match(/bakery/i, @store.room(bakery_id)[:name])
  end

  def test_non_bakery_goal_does_not_goto
    grass = room("Grasslands", exits: %w[north])
    @store.update_player!(current_room_id: grass, hp: 500, mana: 100, move: 82)

    raws = []
    mud = lambda do |name, args = {}, _meta = {}|
      tool = name.sub(/\A.*__/, "")
      case tool
      when "look" then look_text("Grasslands", %w[north])
      when "check" then exits_text("north" => "More Grass")
      when "send_raw"
        raws << (args[:command] || args["command"])
        "ok"
      else
        raise "unexpected #{name}"
      end
    end

    hooks = Boukensha::Mud::Hooks.new(
      store: @store, call_tool: mud, relocate_call_tool: mud,
      bakery_room_vnum: 3009, bakery_destination: "The Bakery", warn_to: nil
    )
    hooks.before_model(context: bakery_context("explore the field to the north"))

    assert_empty raws
    assert_equal grass, hooks.current_room_id
  end

  def test_routable_bakery_skips_goto
    grass = room("Grasslands", exits: %w[east])
    bakery = room("The Bakery", exits: %w[west])
    @store.link_exit!(grass, "east", bakery)
    @store.update_player!(current_room_id: grass, hp: 500, mana: 100, move: 82)

    raws = []
    mud = lambda do |name, args = {}, _meta = {}|
      tool = name.sub(/\A.*__/, "")
      case tool
      when "look" then look_text("Grasslands", %w[east])
      when "check" then exits_text("east" => "The Bakery")
      when "send_raw"
        raws << (args[:command] || args["command"])
        "ok"
      else
        raise "unexpected #{name}"
      end
    end

    hooks = Boukensha::Mud::Hooks.new(
      store: @store, call_tool: mud, relocate_call_tool: mud,
      bakery_room_vnum: 3009, bakery_destination: "The Bakery", warn_to: nil
    )
    hooks.before_model(context: bakery_context("visit the bakery menu please"))

    assert_empty raws, "navigate can reach bakery — no immortal goto"
    assert_equal grass, hooks.current_room_id
  end

  def test_second_before_model_does_not_goto_again
    grass = room("Grasslands", exits: %w[north])
    @store.update_player!(current_room_id: grass, hp: 500, mana: 100, move: 82)

    raws = []
    mud = lambda do |name, args = {}, _meta = {}|
      tool = name.sub(/\A.*__/, "")
      case tool
      when "look"
        if raws.any?
          look_text("The Bakery", %w[west])
        else
          look_text("Grasslands", %w[north])
        end
      when "check"
        exits_text("west" => "The Common Square")
      when "send_raw"
        raws << (args[:command] || args["command"])
        "You goto 3009.\r\n"
      else
        raise "unexpected #{name}"
      end
    end

    hooks = Boukensha::Mud::Hooks.new(
      store: @store, call_tool: mud, relocate_call_tool: mud,
      bakery_room_vnum: 3009, bakery_destination: "The Bakery", warn_to: nil
    )
    ctx = bakery_context("bakery menu")
    hooks.before_model(context: ctx)
    hooks.before_model(context: ctx)

    assert_equal ["goto 3009"], raws
  end
end
