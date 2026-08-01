module Boukensha
  module Mud
    # Shortest path across the agent's OWN map. No MUD, no network, no round
    # trips — everything Mud::Navigator refuses to do, in the same way
    # Mud::RoomParser is the half of the survey that never talks to anything.
    #
    # The graph is `room_exits` exactly as it stands: `target_room_id` non-NULL
    # is an edge the agent has personally walked, NULL is the frontier. Nothing
    # here infers an edge it was not told about — see the two traps below, both
    # of which are properties of that table and not bugs to paper over.
    class RouteFinder
      # The six the daemon's `move` enum declares, which is also exactly what
      # `tools.navigate.allow` pins. `room_exits.direction` is whatever the MUD
      # printed, so it can hold `northeast` (RoomParser maps the `ne`
      # abbreviation) or outright junk — a real room in this world has an exit
      # whose direction is the literal string "(s)".
      #
      # Filtering here rather than in the walker is what guarantees a route can
      # never contain a step `move` would reject. A path is only a path if every
      # leg of it is walkable.
      WALKABLE = %w[north east south west up down].freeze

      # `steps`     the directions to walk, in order
      # `room_ids`  the rooms passed through, INCLUDING the start — so
      #             room_ids[i+1] is where steps[i] should land, which is the
      #             comparison the walker makes after every move
      # `ambiguous` the other rooms that also answered to this name
      Route = Struct.new(:ok, :reason, :steps, :room_ids, :goal_id, :goal_name,
                         :ambiguous, :suggestions, :frontier, keyword_init: true) do
        def length = steps ? steps.length : 0
      end

      def initialize(store)
        @store = store
      end

      # `to` may be a room id (Integer, or a String of digits) or a name.
      # `max_steps` caps the search radius; a route longer than this is reported
      # as :too_far rather than silently walked, because every step is a MUD
      # round trip the model is blocked on.
      def route(from:, to:, max_steps: 12)
        return failure(:unknown_destination, suggestions: suggest(to)) if from.nil?

        goals = resolve(to)
        return failure(:unknown_destination, suggestions: suggest(to)) if goals.empty?

        goal_ids = goals.map { |g| g[:id] }
        if goal_ids.include?(from)
          here = goals.find { |g| g[:id] == from }
          return Route.new(ok: true, reason: :already_here, steps: [], room_ids: [from],
                           goal_id: from, goal_name: here[:name], ambiguous: others(goals, from))
        end

        found = search(from, goal_ids, max_steps)
        unless found
          # Not a dead end for the caller — the frontier is where the map runs
          # out, and "go stand there and look" is the actionable next move.
          reason = reachable_within?(from, goal_ids) ? :too_far : :no_route
          return failure(reason, goal_id: goal_ids.first,
                         goal_name: goals.first[:name],
                         ambiguous: others(goals, nil),
                         frontier: frontier_from(from))
        end

        goal = goals.find { |g| g[:id] == found[:goal_id] }
        Route.new(ok: true, reason: :arrived, steps: found[:steps], room_ids: found[:room_ids],
                  goal_id: goal[:id], goal_name: goal[:name],
                  ambiguous: others(goals, goal[:id]))
      end

      private

      # TRAP 1 — the edges are DIRECTED and there is no opposite-direction map
      # anywhere in this codebase. Walking A north into B does not create
      # B south into A: the MUD is free to put the return exit elsewhere, or
      # nowhere. So the search runs over stored edges only, and a route existing
      # A→B while B→A fails is a true statement about what the agent has walked.
      # Inferring the reverse would be inventing knowledge, which is the one
      # thing this whole memory design refuses to do.
      #
      # Costs (week_2_plan Phase 7): `1 + danger*5 + failure_rate*3`. Hop count
      # still caps the search (`max_steps`); cost only breaks ties / prefers
      # safer edges among reachable paths.
      def search(from, goal_ids, max_steps)
        adjacency = adjacency_list
        targets   = goal_ids.to_a
        # prev[room] = [previous_room, direction_taken]
        prev  = { from => nil }
        cost  = { from => 0.0 }
        depth = { from => 0 }
        # Priority queue as a sorted array — maps are small (agent's own rooms).
        queue = [from]

        until queue.empty?
          queue.sort_by! { |n| cost[n] }
          current = queue.shift
          return unwind(prev, from, current) if targets.include?(current) && current != from
          next if depth[current] >= max_steps

          adjacency.fetch(current, EMPTY).each do |direction, target, edge_cost|
            next_depth = depth[current] + 1
            next if next_depth > max_steps

            next_cost = cost[current] + edge_cost
            next if cost.key?(target) && cost[target] <= next_cost

            prev[target]  = [current, direction]
            cost[target]  = next_cost
            depth[target] = next_depth
            queue << target unless queue.include?(target)
          end
        end
        nil
      end

      # Would a bigger budget have found it? Distinguishes "your map does not
      # connect these" from "it does, but not within max_steps" — different
      # advice for the caller, so worth the second traversal on the failure path
      # only. Unbounded, but the graph is the agent's own map: hundreds of nodes.
      def reachable_within?(from, goal_ids)
        adjacency = adjacency_list
        seen  = { from => true }
        queue = [from]
        until queue.empty?
          current = queue.shift
          adjacency.fetch(current, EMPTY).each do |_direction, target, _cost|
            next if seen.key?(target)
            return true if goal_ids.include?(target)

            seen[target] = true
            queue << target
          end
        end
        false
      end

      def unwind(prev, from, goal)
        steps    = []
        room_ids = [goal]
        cursor   = goal
        while (link = prev[cursor])
          parent, direction = link
          steps.unshift(direction)
          room_ids.unshift(parent)
          cursor = parent
        end
        { steps: steps, room_ids: room_ids, goal_id: goal }
      end

      # One query for the whole graph (Store#linked_exits), folded into
      # `{ room_id => [[direction, target, cost], …] }` with each list in a fixed
      # order. Determinism matters: a route is recomputed after a surprise
      # mid-walk, and a caller watching the agent must not see it pick a
      # different equally-short path on the replan.
      def adjacency_list
        @adjacency_list ||= @store.linked_exits.each_with_object({}) do |exit, out|
          direction = exit[:direction].to_s
          next unless WALKABLE.include?(direction)

          (out[exit[:room_id]] ||= []) << [direction, exit[:target_room_id], edge_cost(exit)]
        end.each_value { |edges| edges.sort_by!(&:first) }
      end

      # week_2_plan: `1 + danger*5 + failure_rate*3`.
      def edge_cost(exit)
        failures   = exit[:failure_count].to_i
        traversals = exit[:traversals].to_i
        danger     = exit[:danger].to_f
        attempts   = failures + traversals
        rate       = attempts.zero? ? 0.0 : failures.to_f / attempts
        1.0 + (danger * 5.0) + (rate * 3.0)
      end

      # TRAP 2 — duplicate rooms are load-bearing, not corruption. When more than
      # one weak-fingerprint candidate cannot be settled, Hooks#provisional
      # writes a NEW row, and nothing ever merges them (hooks.rb refuses that
      # resolver deliberately). So a name resolves to a SET, and the search stops
      # at whichever member the agent's own edges reach first — which is exactly
      # what "take me to Market Square" means. The rest ride along in
      # `ambiguous` so the answer can say so out loud.
      def resolve(to)
        if to.is_a?(Integer) || to.to_s.match?(/\A\d+\z/)
          room = @store.room(to.to_i)
          return room ? [room] : []
        end

        name  = to.to_s.strip
        exact = @store.rooms_by_name(name)
        return exact unless exact.empty?

        fuzzy = @store.search_rooms(name)
        # Only commit to a fuzzy match when it is unambiguous. Two half-matches
        # are a question for the caller, not a coin flip on their behalf.
        fuzzy.length == 1 ? fuzzy : []
      end

      def suggest(to)
        @store.search_rooms(to.to_s).map { |r| { id: r[:id], name: r[:name] } }
      rescue StandardError
        []
      end

      def others(goals, chosen_id)
        goals.reject { |g| g[:id] == chosen_id }.map { |g| { id: g[:id], name: g[:name] } }
      end

      def frontier_from(room_id)
        @store.frontier_exits_for(room_id).map do |exit|
          { direction: exit[:direction], target_name: exit[:target_name] }
        end
      rescue StandardError
        []
      end

      def failure(reason, **fields)
        Route.new(ok: false, reason: reason, steps: [], room_ids: [], **fields)
      end

      EMPTY = [].freeze
      private_constant :EMPTY
    end
  end
end
