require "test_helper"

module World
  class AtlasTest < ActiveSupport::TestCase
    include KnowledgeFixtures
    include WorldFixtures

    def atlas = Atlas.for_dir(Rails.application.config.x.mud_monitor.world_dir)

    # ---------- absence ---------------------------------------------------

    # Same rule as a knowledge file that does not exist: the world JSON is
    # generated and gitignored, so "nobody has run convert-world" is the normal
    # state of a fresh clone and must never be an error.
    test "a missing world dir is a state, not an error" do
      use_missing_world_dir

      assert_not atlas.ready?
      assert_equal 0, atlas.room_count
      assert_equal 0, atlas.zone_count
      assert_nil atlas.room(100)
      assert_equal [], atlas.true_directions([ 100 ])
      assert_nil atlas.destination([ 100 ], "north")
    end

    test "an empty world dir is also just empty" do
      use_world_dir(zones: {})

      assert_not atlas.ready?
      assert_equal 0, atlas.room_count
    end

    # ---------- loading ---------------------------------------------------

    test "reads every zone file and keys rooms by vnum" do
      use_world_dir

      assert atlas.ready?
      assert_equal 11, atlas.room_count
      assert_equal 2, atlas.zone_count
      assert_equal "Village Green", atlas.room(100).name
      assert_equal 1, atlas.room(100).zone
      assert_equal 2, atlas.room(200).zone
    end

    test "translates CircleMUD's numeric directions" do
      use_world_dir

      assert_equal({ "north" => 101, "east" => 102, "down" => 107 }, atlas.room(100).exits)
    end

    test "room_linked -1 is not an edge" do
      use_world_dir(zones: { 1 => [ { id: 300, name: "Dead End", desc: "Nothing.",
                                      exits: { "north" => Atlas::NO_ROOM, "south" => 301 } } ] })

      assert_equal({ "south" => 301 }, atlas.room(300).exits)
    end

    # One bad file must not cost the other 188 zones, which are still true.
    test "a malformed zone file is skipped, not fatal" do
      use_world_dir
      File.write(world_tmpdir.join("wld/broken.json"), "{not json")
      Atlas.reset!

      assert atlas.ready?
      assert_equal 11, atlas.room_count
    end

    # ---------- THE CROSS-PROJECT CONSTANT --------------------------------

    # The load-bearing assertion of the whole ghost layer. See the long note on
    # these constants in WorldFixtures: they come from boukensha's
    # Fingerprint.weak, and boukensha asserts the same literals from its side.
    # Two projects, one set of numbers, no shared code.
    test "weak fingerprints match boukensha's, computed from .wld source" do
      use_world_dir

      assert_equal WorldFixtures::FP_NORTH, atlas.room(101).weak_fingerprint
      assert_equal WorldFixtures::FP_TWIN,  atlas.room(102).weak_fingerprint
      assert_equal WorldFixtures::FP_VILLAGE_TRUE, atlas.room(100).weak_fingerprint
      assert_equal WorldFixtures::FP_ALE_TRUE, atlas.room(104).weak_fingerprint
    end

    # The MUD wraps prose at whatever width the client negotiated, so line
    # breaks belong to the connection and not to the room. This is why the
    # source file and the socket produce the same hash.
    test "normalize collapses the wrapping the connection introduced" do
      a = Atlas.weak_fingerprint(name: "Hall", description: "One two\nthree.", exit_dirs: %w[north])
      b = Atlas.weak_fingerprint(name: "  hall ", description: "  One   two\n\n  three. ", exit_dirs: %w[north])

      assert_equal a, b
    end

    test "exit direction order does not change the hash" do
      assert_equal Atlas.weak_fingerprint(name: "H", description: "D", exit_dirs: %w[west north]),
                   Atlas.weak_fingerprint(name: "H", description: "D", exit_dirs: %w[north west])
    end

    # ---------- matching --------------------------------------------------

    test "a unique fingerprint is the weak tier and names exactly one room" do
      use_world_dir

      hit = atlas.match(weak_fingerprint: WorldFixtures::FP_NORTH,
                        name: "North Path", description: "A path north.")

      assert_equal "weak", hit[:tier]
      assert_equal [ 101 ], hit[:vnums]
    end

    # 2,153 rooms of stock tbaMUD (17%) are in this position. Nothing can
    # separate 102 from 103 — same name, same prose, same exits — so both
    # survive and the caller is told so.
    test "identical rooms are ambiguous and BOTH candidates survive" do
      use_world_dir

      hit = atlas.match(weak_fingerprint: WorldFixtures::FP_TWIN,
                        name: "Twin Hall", description: "Identical prose.")

      assert_equal "ambiguous", hit[:tier]
      assert_equal [ 102, 103 ], hit[:vnums].sort
      assert_equal 2, atlas.ambiguous_room_count
    end

    # The closed-door case, and the reason the second tier has to exist:
    # tbaMUD omits a closed door from `[ Exits: ]`, so the agent's exit set is a
    # strict subset of the truth and the fingerprints cannot match.
    test "a closed door breaks the weak join and falls through to name_desc" do
      use_world_dir

      assert_not_equal WorldFixtures::FP_VILLAGE, atlas.room(100).weak_fingerprint,
                       "the fixture must actually exercise the fallback"

      hit = atlas.match(weak_fingerprint: WorldFixtures::FP_VILLAGE,
                        name: "Village Green", description: "A quiet green.")

      assert_equal "name_desc", hit[:tier]
      assert_equal [ 100 ], hit[:vnums]
    end

    test "a room this world does not contain matches nothing" do
      use_world_dir

      assert_nil atlas.match(weak_fingerprint: WorldFixtures::FP_PHANTOM,
                             name: "Phantom Chamber", description: "Not in this world.")
    end

    # ---------- destinations under ambiguity ------------------------------

    # The reduction that keeps the ghost layer useful even when identity is
    # unknown: two candidates disagree about the vnum east of them, but if they
    # agree on its NAME the name is still a fact.
    test "candidates that agree on a destination name yield a certain answer" do
      use_world_dir(zones: { 1 => [
        { id: 400, name: "Fork", desc: "Same.", exits: { "north" => 402 } },
        { id: 401, name: "Fork", desc: "Same.", exits: { "north" => 403 } },
        { id: 402, name: "Shrine", desc: "A.", exits: {} },
        { id: 403, name: "Shrine", desc: "B.", exits: {} }
      ] })

      dest = atlas.destination([ 400, 401 ], "north")

      assert_equal [ 402, 403 ], dest[:vnums]
      assert_equal "Shrine", dest[:name]
      assert dest[:certain], "different vnums, one name — the name is still known"
    end

    test "candidates that disagree on the name claim nothing, but list both" do
      use_world_dir

      dest = atlas.destination([ 102, 103 ], "north")

      assert_nil dest[:name], "must not pick one of two"
      assert_equal [ "Ale House", "Attic" ], dest[:names].sort
      assert_not dest[:certain]
      assert_equal [ 104, 106 ], dest[:vnums].sort
    end

    # A direction only one candidate offers is not a fact about "this room".
    test "true_directions is the intersection across candidates" do
      use_world_dir(zones: { 1 => [
        { id: 500, name: "Fork", desc: "Same.", exits: { "north" => 502, "east" => 502 } },
        { id: 501, name: "Fork", desc: "Same.", exits: { "north" => 502 } },
        { id: 502, name: "End", desc: "E.", exits: {} }
      ] })

      assert_equal %w[north], atlas.true_directions([ 500, 501 ])
      assert_equal %w[north east], atlas.true_directions([ 500 ])
    end

    test "zone_of refuses to answer when candidates span zones" do
      use_world_dir

      assert_equal 1, atlas.zone_of([ 100, 101 ])
      assert_nil atlas.zone_of([ 100, 200 ])
    end

    # ---------- memoization -----------------------------------------------

    test "the atlas is memoized per directory" do
      use_world_dir

      assert_same atlas, atlas
    end

    # 12,701 rooms is ~300ms of JSON parsing and the map polls this every 15s,
    # so a stale cache would be the difference between a live overlay and a lie.
    test "adding a zone file busts the cache" do
      use_world_dir
      before = atlas.room_count

      File.write(world_tmpdir.join("wld/3.json"),
                 JSON.generate([ parser_room({ id: 600, name: "New", desc: "N.", exits: {} }, 3) ]))

      assert_equal before + 1, atlas.room_count
      assert_equal 3, atlas.zone_count
    end

    test "deleting a zone file busts the cache" do
      use_world_dir
      before = atlas.room_count

      File.delete(world_tmpdir.join("wld/2.json"))

      assert_equal before - 1, atlas.room_count
    end
  end
end
