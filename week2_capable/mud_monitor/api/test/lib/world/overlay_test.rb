require "test_helper"

module World
  class OverlayTest < ActiveSupport::TestCase
    include KnowledgeFixtures
    include WorldFixtures

    def payload
      @payload ||= begin
        cfg = Rails.application.config.x.mud_monitor
        Knowledge::Reader.open(path: cfg.knowledge_db) do |reader|
          Overlay.new(atlas: Atlas.for_dir(cfg.world_dir), rooms: reader.rooms(limit: 100)).as_json
        end
      end
    end

    def mapping_for(room_id) = payload[:mapping].find { |m| m[:room_id] == room_id }
    def verdict_for(room_id, dir) = payload[:verdicts].find { |v| v[:room_id] == room_id && v[:direction] == dir }
    def ghost_for(room_id, dir) = payload[:ghosts].find { |g| g[:from_room_id] == room_id && g[:direction] == dir }

    def setup_world
      use_agent_map
      use_world_dir
    end

    # ---------- degradation ------------------------------------------------

    # The overlay decorates the map; it must never be able to blank it. Without
    # world JSON the payload is empty and well-formed, and every agent room is
    # reported as unmatched rather than silently dropped.
    test "no world means an empty overlay, not an error" do
      use_agent_map
      use_missing_world_dir

      assert_not payload[:world_ready]
      assert_equal [], payload[:mapping]
      assert_equal [], payload[:verdicts]
      assert_equal [], payload[:ghosts]
      assert_equal [ 1, 2, 3, 4, 5 ], payload[:unmatched].sort
    end

    test "no agent memory means an empty overlay against a real world" do
      use_missing_knowledge_db
      use_world_dir

      assert payload[:world_ready]
      assert_equal 11, payload[:world][:rooms]
      assert_equal [], payload[:mapping]
      assert_equal [], payload[:unmatched]
    end

    # ---------- mapping ----------------------------------------------------

    test "each tier is reported, and only a single candidate counts as certain" do
      setup_world

      assert_equal [ "weak", [ 101 ], true ], mapping_for(2).values_at(:tier, :vnums, :certain)
      assert_equal [ "ambiguous", [ 102, 103 ], false ], mapping_for(3).values_at(:tier, :vnums, :certain)
      assert_equal [ "name_desc", [ 100 ], true ], mapping_for(1).values_at(:tier, :vnums, :certain)
      assert_equal 1, mapping_for(1)[:zone]
    end

    test "a room the world does not contain is listed, not dropped" do
      setup_world

      assert_nil mapping_for(5)
      assert_equal [ 5 ], payload[:unmatched]
    end

    # ---------- verdicts: the four outcomes --------------------------------

    # Proven. One reading of the world exists and it is the only reading.
    test "confirmed requires BOTH ends to be certain" do
      setup_world

      v = verdict_for(1, "north")
      assert_equal "confirmed", v[:verdict]
      assert_equal "North Path", v[:true_name]
      assert_equal [ 101 ], v[:true_vnums]
    end

    # The distinction the real map forced. A non-empty intersection between two
    # GUESSED sets is not proof — it means no contradiction was found, which is
    # a weaker claim and gets a weaker word. Calling this "confirmed" would
    # claim more than the evidence carries.
    test "an ambiguous end downgrades a matching edge to consistent" do
      setup_world

      assert_equal "confirmed", verdict_for(1, "north")[:verdict]

      v = verdict_for(1, "east")
      assert_equal "consistent", v[:verdict], "target room 3 could be 102 or 103"
      assert_equal "ambiguous", v[:reason]

      assert_equal "consistent", verdict_for(3, "west")[:verdict], "source room 3 is the ambiguous end"
    end

    # The asymmetry that matters: ambiguity makes CONFIRMING harder but does not
    # make refuting harder. If no assignment of candidates satisfies the edge,
    # the agent is wrong whichever room it was really standing in.
    test "an empty intersection is wrong even when a candidate set is ambiguous" do
      setup_world

      v = verdict_for(4, "south")
      assert_equal "wrong", v[:verdict]
      assert_equal "wrong_target", v[:reason]
      assert_equal "Twin Hall", v[:true_name], "south really leads to Twin Hall, not North Path"
    end

    test "an edge the true world does not give this room at all is wrong" do
      setup_world

      v = verdict_for(4, "up")
      assert_equal "wrong", v[:verdict]
      assert_equal "no_such_exit", v[:reason]
    end

    # ...but only when we know which room it is. Some OTHER candidate may well
    # have that exit, and blaming the agent for our own ambiguity is exactly the
    # kind of invented verdict this class refuses to make.
    test "no_such_exit is never claimed against an ambiguous room" do
      use_world_dir
      use_agent_map(sql_extra: <<~SQL)
        INSERT INTO room_exits (room_id, direction, target_room_id, traversals, last_seen_at)
          VALUES (3, 'down', 1, 1, '2026-07-30T00:00:00Z');
      SQL

      assert_equal "ambiguous", mapping_for(3)[:tier]
      assert_nil verdict_for(3, "down"), "neither Twin Hall has a down exit, but we cannot say which room this is"
    end

    test "an edge into a room the atlas cannot place is unverified" do
      setup_world

      v = verdict_for(4, "east")
      assert_equal "unverified", v[:verdict]
      assert_equal "target_unmatched", v[:reason]
    end

    test "verdicts are only produced for edges the agent has actually walked" do
      setup_world

      assert_nil verdict_for(2, "north"), "a frontier exit is a ghost, not a verdict"
    end

    # ---------- ghosts ------------------------------------------------------

    # The highest-value pixel on the page: the real room behind an exit the
    # agent has found but not walked.
    test "an unwalked exit becomes a frontier ghost naming the true room" do
      setup_world

      g = ghost_for(2, "north")
      assert g[:frontier], "the agent knows this exit exists"
      assert_equal "Windy Ridge", g[:name]
      assert_equal [ 108 ], g[:vnums]
      assert g[:certain]
    end

    # A closed door is invisible in `[ Exits: ]`, so the agent does not merely
    # have an unwalked exit here — it does not know the exit exists.
    test "a closed door becomes a hidden ghost the agent has no exit for" do
      setup_world

      g = ghost_for(1, "down")
      assert_not g[:frontier], "the agent has no `down` exit at all"
      assert_equal "Sealed Vault", g[:name]
      assert g[:certain]
    end

    test "a ghost with disagreeing candidates offers the shortlist and names nothing" do
      setup_world

      g = ghost_for(3, "north")
      assert_nil g[:name]
      assert_equal [ "Ale House", "Attic" ], g[:names].sort
      assert_not g[:certain]
    end

    test "a walked exit is never also a ghost" do
      setup_world

      assert_nil ghost_for(1, "north")
      assert_nil ghost_for(2, "south")
    end

    # ---------- coverage ----------------------------------------------------

    # Only zones the agent has touched. All 189 with a zero would be noise, and
    # the denominator is what makes the numerator mean anything.
    test "coverage reports known against true, for touched zones only" do
      setup_world

      assert_equal [ { zone: 1, true_rooms: 10, known_rooms: 4 } ], payload[:coverage]
    end

    test "world stats carry the ambiguity of the world itself" do
      setup_world

      assert_equal 11, payload[:world][:rooms]
      assert_equal 2, payload[:world][:zones]
      assert_equal 2, payload[:world][:ambiguous_rooms]
    end
  end
end
