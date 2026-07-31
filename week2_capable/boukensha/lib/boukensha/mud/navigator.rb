require_relative "room_parser"
require_relative "route_finder"
require_relative "../operation"

module Boukensha
  module Mud
    # The walk. Everything Mud::RouteFinder refuses to do — the same split
    # RoomParser and RoomSurvey have, and for the same reason: the part that
    # costs MUD round trips is separated from the part that can be tested
    # against a transcript with no MUD, no MCP and no network.
    #
    # It runs under its OWN allowlist (`tools.navigate.allow` in settings.yaml)
    # — `move`, pinned to the six directions, and nothing else. Deliberately
    # narrower than the survey's: no `look` (a move's own arrival text is all
    # this needs) and no `flee` (a route is a decision, not a panic).
    #
    # Unlike RoomSurvey this IS reachable from the model, because a destination
    # cannot be inferred from the world the way "a room we have never stood in"
    # can. It is registered as a native tool in boukensha_loader.rb, which keeps
    # the daemon's flat primitive surface intact: the MUD still only ever sees
    # one `move` per round trip.
    #
    # `on_arrival:` is how position stays Mud::Hooks' property. This class walks
    # and verifies; it never decides which room it is standing in.
    class Navigator
      # The span name in the session log AND the settings key its allowlist
      # lives under.
      NAME = "navigate".freeze

      # Every step is a blocking MUD round trip the model is waiting on, so the
      # ceiling is low and the model cannot raise it. Twelve is far enough to
      # cross a zone and short enough that a wrong route is cheap.
      DEFAULT_MAX_STEPS = 12

      # A surprise means the stored map was wrong. Hooks#link_arrival has
      # already repaired the edge by the time we notice, so one replan from
      # where we actually are is worth it; a second means the map is unreliable
      # enough that continuing is guessing.
      DEFAULT_MAX_REPLANS = 1

      def initialize(call_tool:, store:, on_arrival:, prefix: "tbamud__", logger: nil,
                     max_steps: DEFAULT_MAX_STEPS, max_replans: DEFAULT_MAX_REPLANS)
        @call_tool   = call_tool
        @store       = store
        @on_arrival  = on_arrival
        @prefix      = prefix
        @logger      = logger
        @max_steps   = max_steps
        @max_replans = max_replans
        @finder      = RouteFinder.new(store)
      end

      def navigate(destination:, from:)
        span { navigate!(destination: destination, from: from) }
      end

      # One line, at the density StateBlock writes at. This is what the model
      # actually reads, so it says where the agent ended up in every outcome —
      # a failed navigation still moved it, and an answer that omitted that
      # would be the most expensive kind of wrong.
      def self.render(result)
        return "navigate ✗ #{result[:reason]}" unless result.is_a?(Hash)

        goal = [result[:goal_name], result[:goal_id] && "(##{result[:goal_id]})"].compact.join(" ")
        if result[:ok]
          line = +"navigate → #{goal}: #{result[:steps_walked]} of #{result[:steps_planned]}"
          line << " · #{result[:path].join(', ')}" if result[:path]&.any?
          line << " · replanned once" if result[:replans].to_i.positive?
          line << ambiguity_note(result)
          return line
        end

        case result[:reason]
        when :unknown_destination
          note = suggestion_note(result[:suggestions])
          "navigate ✗ no room called #{result[:destination].inspect} in your map#{note}"
        when :no_position
          "navigate ✗ you do not know where you are yet; look first"
        when :no_route, :too_far
          why = if result[:reason] == :too_far
                  "reachable, but more than #{result[:max_steps]} steps away"
                else
                  "no route you have actually walked"
                end
          "navigate ✗ #{goal.empty? ? result[:destination].inspect : goal}: #{why}#{frontier_note(result[:frontier])}"
        else
          at = [result[:stopped_at_name], result[:stopped_at] && "(##{result[:stopped_at]})"].compact.join(" ")
          line = +"navigate ✗ #{goal}: stopped after #{result[:steps_walked]} of #{result[:steps_planned]}"
          line << " at #{at}" unless at.empty?
          line << " — #{result[:blocked_by].inspect}" if result[:blocked_by]
          line
        end
      end

      def self.ambiguity_note(result)
        others = result[:ambiguous]
        return "" if others.nil? || others.empty?

        " · note: #{others.length} other room#{'s' if others.length > 1} share that name"
      end
      private_class_method :ambiguity_note

      def self.suggestion_note(suggestions)
        return "" if suggestions.nil? || suggestions.empty?

        " · did you mean: #{suggestions.map { |s| "#{s[:name]} (##{s[:id]})" }.join(', ')}?"
      end
      private_class_method :suggestion_note

      def self.frontier_note(frontier)
        return "" if frontier.nil? || frontier.empty?

        unexplored = frontier.map { |f| [f[:direction], f[:target_name]].compact.join("→") }
        " · unexplored from here: #{unexplored.join(', ')}"
      end
      private_class_method :frontier_note

      private

      # The whole walk is ONE unit of automatic work. A reader seeing N separate
      # `move` calls is being told the agent chose to wander; the span is what
      # makes it one intention with N consequences.
      def span(&block)
        return @logger.operation(NAME, &block) if @logger

        Boukensha::Operation.open(NAME, &block)
      end

      def navigate!(destination:, from:)
        route = @finder.route(from: from, to: destination, max_steps: @max_steps)
        unless route.ok
          return result(route, from: from, destination: destination, ok: false,
                        reason: route.reason, steps_walked: 0)
        end
        return result(route, from: from, destination: destination, ok: true,
                      reason: :already_here, steps_walked: 0, path: []) if route.reason == :already_here

        walk(route, from: from, destination: destination, replans: 0)
      end

      def walk(route, from:, destination:, replans:)
        walked  = []
        current = from

        route.steps.each_with_index do |direction, index|
          text = call(:move, direction: direction)
          look = RoomParser.parse_look(text)

          # The whitelist is on SUCCESS, never a blacklist on failure — the same
          # test Hooks#movement_outcome trusts. A closed door, "It is pitch
          # black", a blocking mob, a forced flee: none of them produce a room
          # name plus an exits line plus a prompt, so all of them stop the walk
          # without this class knowing a single MUD string.
          unless look.complete?
            return result(route, from: from, destination: destination, ok: false,
                          reason: :blocked, steps_walked: walked.length, path: walked,
                          stopped_at: current, blocked_by: refusal(text), replans: replans)
          end

          # The RAW text goes with the parsed look: the callback has to absorb
          # HP, level-ups, deaths and departures out of it, and a parsed Look
          # carries none of those.
          arrived = @on_arrival.call(look, current, direction, text)
          walked << direction
          current = arrived

          expected = route.room_ids[index + 1]
          next if arrived.nil? || arrived == expected

          # The map was wrong. Hooks#link_arrival has ALREADY demoted the stale
          # edge and relinked it as a side effect of resolving where we are — so
          # walking a bad route repairs it. Replan from the truth.
          if replans >= @max_replans
            return result(route, from: from, destination: destination, ok: false,
                          reason: :lost, steps_walked: walked.length, path: walked,
                          stopped_at: current, replans: replans)
          end

          replanned = @finder.route(from: current, to: destination, max_steps: @max_steps)
          unless replanned.ok
            return result(replanned, from: from, destination: destination, ok: false,
                          reason: replanned.reason, steps_walked: walked.length,
                          path: walked, stopped_at: current, replans: replans + 1)
          end

          rest = walk(replanned, from: current, destination: destination, replans: replans + 1)
          rest[:steps_walked]  = walked.length + rest[:steps_walked].to_i
          rest[:steps_planned] = route.length
          rest[:path]          = walked + Array(rest[:path])
          return rest
        end

        result(route, from: from, destination: destination, ok: true, reason: :arrived,
               steps_walked: walked.length, path: walked, stopped_at: current, replans: replans)
      end

      # The MUD's own words for why it would not move us. Verbatim, because a
      # paraphrase is a guess and the model can act on the real thing ("The door
      # is closed." is an instruction to open it).
      def refusal(text)
        RoomParser.lines(text.to_s)
                  .reject { |l| l =~ RoomParser::PROMPT_LINE }
                  .map(&:strip).reject(&:empty?).first
      end

      def result(route, from:, destination:, ok:, reason:, steps_walked:, path: nil,
                 stopped_at: nil, blocked_by: nil, replans: 0)
        {
          ok: ok,
          reason: reason,
          destination: destination,
          from: from,
          goal_id: route.goal_id,
          goal_name: route.goal_name,
          steps_planned: route.length,
          steps_walked: steps_walked,
          max_steps: @max_steps,
          path: path,
          stopped_at: stopped_at,
          stopped_at_name: stopped_at && @store.room(stopped_at)&.fetch(:name, nil),
          blocked_by: blocked_by,
          ambiguous: route.ambiguous,
          suggestions: route.suggestions,
          frontier: route.frontier,
          replans: replans
        }.compact
      end

      def call(tool, **args)
        @call_tool.call("#{@prefix}#{tool}", args)
      end
    end
  end
end
