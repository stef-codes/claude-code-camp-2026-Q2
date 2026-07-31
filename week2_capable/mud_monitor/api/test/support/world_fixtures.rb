require "fileutils"
require "json"
require "tmpdir"

# Builds a tiny parsed-world tree, in the parser's own JSON format, plus the
# matching agent memory to draw against it.
#
# Built rather than committed, for the same reason KnowledgeFixtures builds its
# SQLite: the real thing is 29 MB of generated JSON across 189 files, which is
# neither reviewable nor something a test should depend on being present. Eleven
# rooms is enough to exercise every branch, and every one of them is here to
# cover a specific case rather than to look like a world:
#
#   100 Village Green   a CLOSED DOOR down to 107. tbaMUD leaves closed doors
#                       out of `[ Exits: ]`, so the agent's exit set is a strict
#                       subset of the truth and the weak fingerprint CANNOT
#                       match — this is the whole reason the name_desc tier
#                       exists, and the source of a "hidden" ghost.
#   101 North Path      matches on the weak fingerprint outright.
#   102 Twin Hall  ─┐   byte-identical name, prose and exit directions. Nothing
#   103 Twin Hall  ─┘   can separate them; both must survive as candidates.
#   104 Ale House       the agent holds three false beliefs about this room.
#   105..109            destinations, so the rooms above have somewhere to lead.
#   200 Far Tower       a second zone, so zone counting and coverage are real.
module WorldFixtures
  # CircleMUD's D0..D5.
  DIR = { "north" => 0, "east" => 1, "south" => 2, "west" => 3, "up" => 4, "down" => 5 }.freeze

  ZONE_1 = [
    { id: 100, name: "Village Green", desc: "A quiet green.",
      exits: { "north" => 101, "east" => 102, "down" => 107 } },
    { id: 101, name: "North Path", desc: "A path north.",
      exits: { "north" => 108, "south" => 100 } },
    { id: 102, name: "Twin Hall", desc: "Identical prose.",
      exits: { "north" => 104, "west" => 100 } },
    { id: 103, name: "Twin Hall", desc: "Identical prose.",
      exits: { "north" => 106, "west" => 105 } },
    { id: 104, name: "Ale House", desc: "Beer.",
      exits: { "east" => 109, "south" => 102 } },
    { id: 105, name: "Cellar", desc: "Dark.", exits: { "east" => 103 } },
    { id: 106, name: "Attic", desc: "Dusty.", exits: { "south" => 103 } },
    { id: 107, name: "Sealed Vault", desc: "Locked.", exits: { "up" => 100 } },
    { id: 108, name: "Windy Ridge", desc: "Windy.", exits: { "south" => 101 } },
    { id: 109, name: "Storeroom", desc: "Boxes.", exits: { "west" => 104 } }
  ].freeze

  ZONE_2 = [
    { id: 200, name: "Far Tower", desc: "Tall.", exits: {} }
  ].freeze

  # What the agent believes, against the world above.
  #
  #   1 Village Green  correct, but missing the closed door
  #   2 North Path     correct, with one unwalked exit north
  #   3 Twin Hall      genuinely ambiguous — could be 102 or 103
  #   4 Ale House      three wrong beliefs, one per failure mode
  #   5 Phantom Chamber  not in this world at all
  # THE CROSS-PROJECT CONSTANTS.
  #
  # These are not placeholders and they are not computed by this app. Each one
  # was produced by boukensha's own Boukensha::Mud::Memory::Fingerprint.weak
  # from the name, description and exit set of the agent room it sits on, and
  # pasted here verbatim. mud_monitor and boukensha share no code — the atlas
  # reimplements that hash because a Rails app cannot load another project's
  # Gemfile — so a literal is the only thing that can hold the two together.
  #
  # That is the entire point. If the atlas computed these itself the join test
  # would be a tautology: it would prove only that a function agrees with
  # itself. Written down, they mean the monitor reproduces, from `.wld` source
  # bytes, the exact hash the agent computed from what the MUD sent it.
  #
  # `weak_fingerprints_match_boukensha` in atlas_test.rb asserts these from the
  # `.wld` side, and test_world_fingerprint_constants.rb in boukensha asserts
  # the identical values from Fingerprint.weak. A change to `normalize` in
  # either project fails both suites, which is what makes the drift loud.
  FP_VILLAGE = "6bb5a4cfe46602335c5488044fba746a4c2a7382fdbdd746ac6668952b449591".freeze # [east north]
  FP_NORTH   = "e209296dc72ea87c76076af8c7b5b2b07d43cc64a47014d43e44d4d5efc7b756".freeze # [north south]
  FP_TWIN    = "bd325e8071c8e2d967c25817bad9fd24cc01a832f38e4a0f8afe8229a68f1cca".freeze # [north west]
  FP_ALE     = "2849dd22407e9dc3fe1fa9badb44fcce7e6d6567c53b764f40042ee09fcaba07".freeze # [east south up]
  FP_PHANTOM = "8ecf04f851a966287b68da249fe816f672f014303a735fb55ffa4f9e3bc66c67".freeze # []

  # The two rooms whose TRUE exit set differs from what the agent saw, so their
  # true fingerprints differ from the agent's above. Both must therefore fail the
  # weak join and fall through to the name_desc tier.
  FP_VILLAGE_TRUE = "5fec5de9513c3b44e9a5ee10a1964b826f2a3ecd4c4839503679876d45afa591".freeze # + closed door down
  FP_ALE_TRUE     = "6030cd4d6fa5abcf22d05a3a4d55acaa8d525c5eb1721e8af5f0e59f38e58d6a".freeze # without the phantom up

  AGENT_ROWS = <<~SQL.freeze
    DELETE FROM entity_sightings;
    DELETE FROM encounters;
    DELETE FROM room_exits;
    DELETE FROM rooms;

    INSERT INTO rooms (id, weak_fingerprint, confidence, name, description, first_seen_at, last_seen_at, visit_count) VALUES
      (1, '#{FP_VILLAGE}', 'confirmed',   'Village Green',   'A quiet green.',      '2026-07-30T00:00:00Z', '2026-07-30T00:00:00Z', 1),
      (2, '#{FP_NORTH}',   'confirmed',   'North Path',      'A path north.',       '2026-07-30T00:00:00Z', '2026-07-30T00:00:00Z', 1),
      (3, '#{FP_TWIN}',    'provisional', 'Twin Hall',       'Identical prose.',    '2026-07-30T00:00:00Z', '2026-07-30T00:00:00Z', 1),
      (4, '#{FP_ALE}',     'confirmed',   'Ale House',       'Beer.',               '2026-07-30T00:00:00Z', '2026-07-30T00:00:00Z', 1),
      (5, '#{FP_PHANTOM}', 'confirmed',   'Phantom Chamber', 'Not in this world.',  '2026-07-30T00:00:00Z', '2026-07-30T00:00:00Z', 1);

    INSERT INTO room_exits (room_id, direction, target_name, target_room_id, traversals, last_seen_at) VALUES
      -- correct, and the `down` door is absent exactly as the MUD reports it
      (1, 'north', 'North Path',  2,    1, '2026-07-30T00:00:00Z'),
      (1, 'east',  'Twin Hall',   3,    1, '2026-07-30T00:00:00Z'),
      -- one walked edge and one frontier
      (2, 'north', NULL,          NULL, 0, '2026-07-30T00:00:00Z'),
      (2, 'south', 'Village Green', 1,  1, '2026-07-30T00:00:00Z'),
      (3, 'north', NULL,          NULL, 0, '2026-07-30T00:00:00Z'),
      (3, 'west',  'Village Green', 1,  1, '2026-07-30T00:00:00Z'),
      -- south really leads to Twin Hall, not North Path: a flat contradiction
      (4, 'south', 'North Path',  2,    1, '2026-07-30T00:00:00Z'),
      -- east leads to a room the atlas cannot place
      (4, 'east',  'Phantom Chamber', 5, 1, '2026-07-30T00:00:00Z'),
      -- and `up` is an exit the true world does not give this room at all
      (4, 'up',    'Village Green', 1,  1, '2026-07-30T00:00:00Z');
  SQL

  def self.included(base)
    base.teardown { restore_world_dir }
  end

  # Writes the fixture world and points config at it. `zones:` lets a test build
  # a different world (or none at all) without touching the constants.
  def use_world_dir(zones: { 1 => ZONE_1, 2 => ZONE_2 })
    wld = world_tmpdir.join("wld")
    wld.mkpath
    zones.each do |number, rooms|
      File.write(wld.join("#{number}.json"), JSON.generate(rooms.map { |r| parser_room(r, number) }))
    end
    point_world_at(world_tmpdir)
  end

  # The "nobody has run convert-world" state, which must render as an empty
  # overlay and never as an error.
  def use_missing_world_dir
    point_world_at(world_tmpdir.join("absent"))
  end

  def world_tmpdir
    @world_tmpdir ||= Pathname.new(Dir.mktmpdir("world"))
  end

  def point_world_at(path)
    cfg = Rails.application.config.x.mud_monitor
    @previous_world_dir = cfg.world_dir unless defined?(@previous_world_dir)
    cfg.world_dir = Pathname.new(path)
    # The atlas memoizes on (dir, file count, newest mtime). Two tmpdirs created
    # in the same second with the same number of files would otherwise collide,
    # and a test would silently assert against the previous test's world.
    World::Atlas.reset!
    Pathname.new(path)
  end

  def restore_world_dir
    cfg = Rails.application.config.x.mud_monitor
    cfg.world_dir = @previous_world_dir if defined?(@previous_world_dir)
    World::Atlas.reset!
    FileUtils.remove_entry(@world_tmpdir) if @world_tmpdir&.directory?
  end

  # The subset of the parser's room shape that Atlas reads, plus the keys it
  # must tolerate and ignore.
  def parser_room(room, zone_number)
    {
      "id" => room[:id],
      "name" => room[:name],
      "desc" => room[:desc],
      "zone_number" => zone_number,
      "sector_type" => { "note" => "INSIDE", "value" => 0 },
      "flags" => [],
      "extra_descs" => [],
      "triggers" => [],
      "exits" => room[:exits].map do |dir, target|
        { "dir" => DIR.fetch(dir), "room_linked" => target, "desc" => "",
          "keywords" => [], "key_number" => -1,
          "door_flag" => { "note" => "NO_DOOR", "value" => 0 } }
      end
    }
  end

  # The agent's memory, keyed to the world above.
  #
  # Layered on top of the real knowledge seed rather than replacing it: that
  # file is a verbatim copy of boukensha's Schema DDL and is deliberately the
  # single place schema drift gets caught. Copying the DDL here would create a
  # second copy to rot.
  def use_agent_map(sql_extra: nil)
    use_knowledge_db(sql: File.read(KnowledgeFixtures::SEED_SQL) + AGENT_ROWS + (sql_extra || ""))
  end
end
