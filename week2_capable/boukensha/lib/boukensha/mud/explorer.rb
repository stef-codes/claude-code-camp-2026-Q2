require_relative "room_parser"
require_relative "route_finder"
require_relative "../operation"

module Boukensha
  module Mud
    # Scripted nearest-frontier loop (week_2_plan Phase 5). Walks one unknown
    # exit at a time, optionally after navigating to the nearest room that
    # still has frontier. Used when no open-ended judgment is needed; the LLM
    # `Tasks::Explorer` covers "find a bakery"-style briefs.
    class Explorer
      NAME = "explore".freeze
      DEFAULT_MAX_ROOMS = 5
      DEFAULT_MAX_STEPS = 12

      def initialize(call_tool:, store:, on_arrival:, navigate:, prefix: "tbamud__",
                     logger: nil, max_rooms: DEFAULT_MAX_ROOMS, max_steps: DEFAULT_MAX_STEPS)
        @call_tool  = call_tool
        @store      = store
        @on_arrival = on_arrival
        @navigate   = navigate
        @prefix     = prefix
        @logger     = logger
        @max_rooms  = max_rooms
        @max_steps  = max_steps
        @finder     = RouteFinder.new(store)
      end

      # Expand the map by walking up to `max_rooms` frontier exits starting
      # from `from`. Returns a compact status hash for the caller to render.
      def explore(from:, max_rooms: nil, goal_name: nil)
        span { explore!(from: from, max_rooms: max_rooms || @max_rooms, goal_name: goal_name) }
      end

      def self.render(result)
        return "explore ✗ #{result[:reason]}" unless result.is_a?(Hash)

        if result[:ok]
          line = +"explore ✓ #{result[:rooms_added]} new room#{'s' if result[:rooms_added].to_i != 1}"
          line << " · #{result[:steps].join(', ')}" if result[:steps]&.any?
          line << " · found #{result[:found]}" if result[:found]
          line
        elsif result[:reason].to_s == "too_dark"
          "explore ✗ too_dark — get light first: cast create food, then cast light on waybread " \
            "(not on yourself); hold the waybread if needed, then retry"
        else
          "explore ✗ #{result[:reason]}#{result[:detail] && " — #{result[:detail]}"}"
        end
      end

      private

      def span(&block)
        return @logger.operation(NAME, &block) if @logger

        Boukensha::Operation.open(NAME, &block)
      end

      def explore!(from:, max_rooms:, goal_name:)
        current = from
        steps   = []
        added   = 0
        found   = nil

        # If any exit line (or walked path) already answers the goal name,
        # navigate there instead of walking the frontier one room at a time.
        # RouteFinder's island fallback makes a named neighbour one provisional
        # step rather than no_route.
        if goal_name && (shortcut = try_goal_navigate(goal_name, from: current))
          return shortcut
        end

        max_rooms.times do
          if goal_name && (hit = name_match(current, goal_name))
            found = hit
            break
          end

          frontier = nearest_frontier(current, goal_name: goal_name)
          unless frontier
            return { ok: added.positive?, reason: added.positive? ? :budget_or_done : :no_frontier,
                     rooms_added: added, steps: steps, stopped_at: current, found: found }.compact
          end

          if frontier[:room_id] != current
            nav = @navigate.call(destination: frontier[:room_id])
            unless nav.is_a?(Hash) && nav[:ok]
              return { ok: false, reason: :navigate_failed, detail: nav.is_a?(Hash) ? nav[:reason] : nav,
                       rooms_added: added, steps: steps, stopped_at: current }.compact
            end
            current = nav[:stopped_at] || frontier[:room_id]
            steps.concat(Array(nav[:path]))
          end

          text   = call(:move, direction: frontier[:direction])
          look   = RoomParser.parse_look(text)
          unless look.complete?
            @store.record_exit_failure!(current, frontier[:direction]) if @store.respond_to?(:record_exit_failure!)
            return { ok: false, reason: :blocked, detail: frontier[:direction],
                     rooms_added: added, steps: steps, stopped_at: current }.compact
          end

          arrived = @on_arrival.call(look, current, frontier[:direction], text)
          steps << frontier[:direction]
          current = arrived || current
          added  += 1

          if goal_name && (hit = name_match(current, goal_name))
            found = hit
            break
          end
        end

        { ok: true, reason: found ? :found : :done, rooms_added: added, steps: steps,
          stopped_at: current, found: found }.compact
      end

      def try_goal_navigate(goal_name, from:)
        nav = @navigate.call(destination: goal_name)
        return nil unless nav.is_a?(Hash) && nav[:ok]

        stopped = nav[:stopped_at] || from
        hit = name_match(stopped, goal_name) || nav[:goal_name] || goal_name
        { ok: true, reason: :found, rooms_added: 0, steps: Array(nav[:path]),
          stopped_at: stopped, found: hit }.compact
      end

      # Closest room (by hop count) that still has an unwalked exit, preferring
      # the current room when it qualifies. Exit pick is ranked (goal → new →
      # alphabetical), never the bare first of an unsorted list.
      def nearest_frontier(from, goal_name: nil)
        here = @store.frontier_exits_for(from)
        if here.any?
          pick = pick_frontier(here, goal_name: goal_name)
          return { room_id: from, direction: pick[:direction], target_name: pick[:target_name] }
        end

        # BFS over linked edges until we find a room with frontier.
        adjacency = @finder.send(:adjacency_list)
        seen  = { from => true }
        queue = [from]
        until queue.empty?
          current = queue.shift
          frontier = @store.frontier_exits_for(current)
          if frontier.any?
            pick = pick_frontier(frontier, goal_name: goal_name)
            return { room_id: current, direction: pick[:direction], target_name: pick[:target_name] }
          end

          adjacency.fetch(current, []).each do |_dir, target, _cost|
            next if seen.key?(target)

            seen[target] = true
            queue << target
          end
        end
        nil
      end

      # Total order: goal-matching target_name, then names not already in the
      # rooms table, then everything else — each band alphabetical by direction
      # so a replan cannot silently flip between equally-good exits.
      def pick_frontier(exits, goal_name: nil)
        exits.min_by do |exit|
          name = exit[:target_name].to_s
          rank = if goal_name && target_matches_goal?(name, goal_name)
                   0
                 elsif !name.empty? && !known_room_name?(name)
                   1
                 else
                   2
                 end
          [ rank, exit[:direction].to_s ]
        end
      end

      def known_room_name?(name)
        @store.rooms_by_name(name.to_s).any?
      rescue StandardError
        false
      end

      def target_matches_goal?(target_name, goal_name)
        needle = goal_name.to_s.strip.downcase
        return false if needle.empty?

        target_name.to_s.downcase.include?(needle)
      end

      def name_match(room_id, goal_name)
        room = @store.room(room_id)
        return nil unless room

        needle = goal_name.to_s.strip.downcase
        room[:name].to_s.downcase.include?(needle) ? room[:name] : nil
      end

      def call(tool, **args)
        @call_tool.call("#{@prefix}#{tool}", args)
      end
    end
  end
end
