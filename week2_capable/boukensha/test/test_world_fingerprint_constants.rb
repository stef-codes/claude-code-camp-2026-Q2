require_relative "helper"

# The boukensha half of a two-project drift lock.
#
# mud_monitor draws the agent's earned map against the TRUE world parsed out of
# the `.wld` files, and the two are joined on `weak_fingerprint`. That join is
# exact — Fingerprint.weak consumes only the room name, its description and its
# sorted exit directions, and all three exist verbatim in the `.wld` source
# under a `normalize` that is just downcase → collapse whitespace → strip. So
# the same bytes hash the same whether they arrived down a socket or came out of
# a file.
#
# Nothing enforces that. The two projects share no code: mud_monitor is a Rails
# app with its own Gemfile and cannot load this library, so `World::Atlas`
# REIMPLEMENTS this hash. Duplication is the price of that boundary, and these
# literals are what stops the copies drifting apart in silence.
#
# The same values appear in
# `week2_capable/mud_monitor/api/test/support/world_fixtures.rb`. Touch
# `normalize` or the field order in `Fingerprint.weak` and BOTH suites fail —
# which is the entire point, because the alternative is a ghost layer that
# quietly matches nothing and looks merely like an unexplored world.
#
# If you are here because this test failed: do not edit the constants to match
# the new output. Decide whether the hash was meant to change, and if it was,
# update both projects together.
class TestWorldFingerprintConstants < Minitest::Test
  FP = Boukensha::Mud::Memory::Fingerprint

  ROOMS = {
    "6bb5a4cfe46602335c5488044fba746a4c2a7382fdbdd746ac6668952b449591" =>
      [ "Village Green", "A quiet green.", %w[north east] ],
    "e209296dc72ea87c76076af8c7b5b2b07d43cc64a47014d43e44d4d5efc7b756" =>
      [ "North Path", "A path north.", %w[north south] ],
    "bd325e8071c8e2d967c25817bad9fd24cc01a832f38e4a0f8afe8229a68f1cca" =>
      [ "Twin Hall", "Identical prose.", %w[north west] ],
    "2849dd22407e9dc3fe1fa9badb44fcce7e6d6567c53b764f40042ee09fcaba07" =>
      [ "Ale House", "Beer.", %w[south east up] ],
    "8ecf04f851a966287b68da249fe816f672f014303a735fb55ffa4f9e3bc66c67" =>
      [ "Phantom Chamber", "Not in this world.", [] ],
    # The same two rooms as the monitor sees them in the .wld source, where the
    # exit set is the TRUE one. Village Green gains a closed door the MUD never
    # prints in `[ Exits: ]`; Ale House loses an exit the agent invented. Both
    # must hash differently from their entries above — that difference is what
    # makes the monitor's name_desc fallback tier necessary rather than
    # decorative.
    "5fec5de9513c3b44e9a5ee10a1964b826f2a3ecd4c4839503679876d45afa591" =>
      [ "Village Green", "A quiet green.", %w[north east down] ],
    "6030cd4d6fa5abcf22d05a3a4d55acaa8d525c5eb1721e8af5f0e59f38e58d6a" =>
      [ "Ale House", "Beer.", %w[east south] ]
  }.freeze

  def test_the_constants_mud_monitor_pins_are_still_what_we_produce
    ROOMS.each do |expected, (name, description, exit_dirs)|
      actual = FP.weak(name: name, description: description, exit_dirs: exit_dirs)
      assert_equal expected, actual,
                   "#{name.inspect} with exits #{exit_dirs.sort.inspect} changed hash — " \
                   "week2_capable/mud_monitor/api/test/support/world_fixtures.rb pins this too"
    end
  end

  # The closed-door case, asserted here rather than only in the monitor: it is a
  # fact about THIS hash (exit dirs are an input) and it is why the monitor
  # cannot rely on the weak tier alone.
  def test_a_closed_door_changes_the_weak_fingerprint
    seen = FP.weak(name: "Village Green", description: "A quiet green.", exit_dirs: %w[north east])
    truth = FP.weak(name: "Village Green", description: "A quiet green.", exit_dirs: %w[north east down])

    refute_equal seen, truth
  end

  # Why the join survives the socket at all: the MUD wraps prose at whatever
  # width the client negotiated, so the line breaks belong to the connection and
  # not to the room.
  def test_wrapping_and_case_do_not_reach_the_hash
    assert_equal FP.weak(name: "Hall", description: "One two three.", exit_dirs: %w[north]),
                 FP.weak(name: "  hall ", description: "  One   two\n\n  three. ", exit_dirs: %w[north])
  end
end
