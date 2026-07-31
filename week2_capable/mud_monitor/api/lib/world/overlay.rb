module World
  # Draws the agent's earned map against the true one and reports the four
  # things that comparison can honestly say.
  #
  # Split out of Atlas on purpose: Atlas is a fact about the world and is
  # memoized for the process's lifetime, while this is a fact about one agent at
  # one moment and is rebuilt per request. Keeping them apart is also what lets
  # every rule below be tested without an HTTP request or a SQLite file.
  #
  # The governing rule is that a claim is only made when the evidence supports
  # it. Where a room's identity is ambiguous (see Atlas), every derived claim
  # degrades to "unverified" instead of guessing — a monitor that invents a
  # verdict is worse than one that admits it cannot tell.
  class Overlay
    def initialize(atlas:, rooms:)
      @atlas = atlas
      @rooms = Array(rooms)
    end

    def as_json
      return empty_payload unless @atlas.ready?

      mapping = build_mapping
      verdicts, ghosts = walk_edges(mapping)

      {
        world_ready: true,
        world: {
          rooms: @atlas.room_count,
          zones: @atlas.zone_count,
          # 17% of stock tbaMUD. Shipped so the UI can explain an "ambiguous"
          # badge as a property of the world, not a failure of the matcher.
          ambiguous_rooms: @atlas.ambiguous_room_count
        },
        mapping: mapping.values.sort_by { |m| m[:room_id] },
        verdicts: verdicts,
        ghosts: ghosts,
        coverage: coverage(mapping),
        unmatched: @rooms.map { |r| r[:id] } - mapping.keys
      }
    end

    private

    def empty_payload
      {
        world_ready: false,
        world: { rooms: 0, zones: 0, ambiguous_rooms: 0 },
        mapping: [], verdicts: [], ghosts: [], coverage: [],
        unmatched: @rooms.map { |r| r[:id] }
      }
    end

    def build_mapping
      @rooms.each_with_object({}) do |room, acc|
        hit = @atlas.match(
          weak_fingerprint: room[:weak_fingerprint],
          name: room[:name],
          description: room[:description]
        )
        next unless hit

        acc[room[:id]] = {
          room_id: room[:id],
          tier: hit[:tier],
          vnums: hit[:vnums],
          # A single candidate is the only case where "this room IS that room"
          # is a true statement. Everything downstream keys off this.
          certain: hit[:vnums].length == 1,
          zone: @atlas.zone_of(hit[:vnums])
        }
      end
    end

    # One pass over the true edges of every mapped room, producing both outputs:
    # a verdict where the agent has walked the edge, a ghost where it has not.
    def walk_edges(mapping)
      verdicts = []
      ghosts   = []

      @rooms.each do |room|
        map = mapping[room[:id]]
        next unless map

        vnums = map[:vnums]
        agent_exits = Array(room[:exits]).index_by { |e| e[:direction] }

        # Directions the candidates AGREE the room has. A direction only one
        # candidate offers is not a fact about "this room".
        @atlas.true_directions(vnums).each do |dir|
          dest = @atlas.destination(vnums, dir)
          next unless dest

          exit_row = agent_exits[dir]

          if exit_row && exit_row[:target_room_id]
            verdicts << verdict_for(room, dir, exit_row, dest, map, mapping)
          else
            ghosts << {
              key: "#{room[:id]}:#{dir}",
              from_room_id: room[:id],
              direction: dir,
              # nil when the candidates disagree about what lies that way. The
              # UI must not render one of them as if it were the answer — but
              # `names` lets it offer the shortlist instead of a shrug.
              name: dest[:name],
              names: dest[:names],
              vnums: dest[:vnums],
              certain: dest[:certain] && map[:certain],
              # true  → the agent knows this exit exists and has not walked it,
              #         so this labels an existing frontier stub.
              # false → the agent does not know the exit is there at all. That
              #         is usually a closed door: tbaMUD leaves those out of the
              #         `[ Exits: ]` line entirely.
              frontier: !exit_row.nil?
            }
          end
        end

        # The other direction of the comparison: an edge the agent believes in
        # that the true world does not give this room at all.
        agent_exits.each do |dir, exit_row|
          next if @atlas.true_directions(vnums).include?(dir)
          next unless exit_row[:target_room_id]
          # Only assertable when we know exactly which room this is; otherwise
          # some other candidate may well have that exit.
          next unless map[:certain]

          verdicts << {
            key: "#{room[:id]}:#{dir}",
            room_id: room[:id], direction: dir,
            target_room_id: exit_row[:target_room_id],
            verdict: "wrong", reason: "no_such_exit",
            true_name: nil, true_vnums: []
          }
        end
      end

      [ verdicts.sort_by { |v| [ v[:room_id], v[:direction] ] }, ghosts ]
    end

    # Four outcomes, not three, and the extra one is the whole honesty of this
    # feature.
    #
    # `dest[:vnums]` is the union, over every candidate identity of the SOURCE
    # room, of where this direction leads. `target_map[:vnums]` is every identity
    # the agent's target room could have. So the intersection answers "does any
    # consistent reading of the world make this edge true?" — which is a
    # NECESSARY condition for the edge being right, and not a sufficient one,
    # because no reading is checked for consistency across two edges at once.
    #
    #   empty intersection      → `wrong`, and this holds even under ambiguity:
    #                             if NO assignment of candidates satisfies the
    #                             edge, the agent is wrong no matter which room
    #                             it was really standing in. Ambiguity makes
    #                             confirming harder, not refuting.
    #   non-empty, both certain → `confirmed`. One reading exists and it is the
    #                             only reading. Proven.
    #   non-empty, ambiguous    → `consistent`. A reading exists. That is a
    #                             weaker claim and gets a weaker word, because
    #                             a non-empty intersection between two guessed
    #                             sets can be a coincidence of the guessing.
    #
    # This distinction came out of running the real map through it: the agent's
    # self-loop `#2 -north-> #2` intersects the truth only under the reading
    # "#2 is 31578", where north really does lead to another identical room. The
    # first version of this method called that "confirmed", which claimed more
    # than the evidence carries.
    def verdict_for(room, dir, exit_row, dest, map, mapping)
      target_map = mapping[exit_row[:target_room_id]]

      verdict, reason =
        if target_map.nil?
          # The agent walked somewhere this atlas cannot place. Says nothing
          # about whether the edge is right.
          [ "unverified", "target_unmatched" ]
        elsif (target_map[:vnums] & dest[:vnums]).empty?
          [ "wrong", "wrong_target" ]
        elsif map[:certain] && target_map[:certain]
          [ "confirmed", nil ]
        else
          [ "consistent", "ambiguous" ]
        end

      {
        key: "#{room[:id]}:#{dir}",
        room_id: room[:id],
        direction: dir,
        target_room_id: exit_row[:target_room_id],
        verdict: verdict,
        reason: reason,
        true_name: dest[:name],
        true_names: dest[:names],
        true_vnums: dest[:vnums]
      }.compact
    end

    # Only zones the agent has actually touched. All 189 with a zero would be
    # noise, and the denominator is what makes the numerator mean anything.
    def coverage(mapping)
      mapping.values.group_by { |m| m[:zone] }.filter_map do |zone, entries|
        next if zone.nil?

        { zone: zone, true_rooms: @atlas.rooms_in_zone(zone), known_rooms: entries.length }
      end.sort_by { |c| c[:zone] }
    end
  end
end
