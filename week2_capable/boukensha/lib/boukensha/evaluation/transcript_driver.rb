module Boukensha
  module Evaluation
    # The MUD, scripted. Stands where `Boukensha.tool_dispatcher` stands in a
    # real run, and is the entire reason a scenario needs no server, no MCP and
    # no network.
    #
    # KEYED, NOT ORDERED. The obvious design is a flat queue answered in order,
    # and it does not survive contact with the real hooks: `before_model`'s cold
    # start spends `look` and may spend `check(exits)`, `consider` and `examine`,
    # and `disambiguate` spends a `check(exits)` mid-walk whenever a weak
    # fingerprint is shared. A flat queue breaks the moment the code
    # legitimately asks a question the fixture author did not sequence — and it
    # breaks by handing over the WRONG answer, which is the worst possible
    # failure mode for a test harness.
    #
    # So responses are keyed by tool plus the argument that discriminates
    # (`move:north`, `check:exits`), exactly as test_mud_hooks.rb's FakeMud keys
    # them, and each key holds either:
    #
    #   an Array   consumed in order, one entry per call. Running out is an
    #              error, not a wrap-around.
    #   a String   a standing answer, returned every time. For genuinely
    #              idempotent reads — `poll` returning "" is the honest case.
    #
    # An unkeyed call raises. There is no default response, ever: a harness that
    # invents an answer is a harness that tests its own invention.
    class TranscriptDriver
      # The scenario is wrong, or the code asked something the author did not
      # anticipate. Either way the RUN is meaningless, so this is a scenario
      # error (exit 2), never a failed assertion (exit 1).
      class UnexpectedCall < StandardError; end

      # The agent asked for more round trips than the scenario allows. A real
      # failure of the run, not of the fixture.
      class BudgetExceeded < StandardError; end

      # Which argument names the thing being asked about, per tool.
      DISCRIMINATORS = %i[direction kind target].freeze

      attr_reader :calls, :error

      def initialize(responses, rooms: {}, max_commands: 50)
        @responses = responses.to_h { |k, v| [ k.to_s, v.is_a?(Array) ? v.dup : v ] }
        @rooms = rooms
        @max_commands = max_commands.to_i
        @calls = []
        @error = nil
      end

      # Matches the shape every other fake in this suite uses, so the hooks
      # cannot tell the difference.
      def to_proc
        lambda do |name, args = {}, _meta = {}|
          tool = name.to_s.sub(/\A.*__/, "")
          @calls << [ tool, args ]
          respond(tool, args || {})
        end
      end

      def budget_exceeded? = @error.is_a?(BudgetExceeded)

      # Hooks#guard swallows every StandardError, so a raise from in here never
      # reaches the runner on its own. The driver remembers it instead, and the
      # runner asks afterwards. Keeping the raise as well as the record matters:
      # it stops the walk at the point of the problem rather than letting it
      # continue against answers that were never scripted.
      def remember(error)
        @error ||= error
        raise error
      end

      private

      def respond(tool, args)
        remember(BudgetExceeded.new("scenario allows #{@max_commands} commands; " \
                                    "call #{@calls.length} was #{describe(tool, args)}")) if over_budget?

        key = keys_for(tool, args).find { |k| @responses.key?(k) }
        unless key
          remember(UnexpectedCall.new("no scripted response for #{describe(tool, args)} " \
                                      "(scripted: #{@responses.keys.sort.join(', ')})"))
        end

        render(@responses[key], key)
      end

      def over_budget? = @max_commands.positive? && @calls.length > @max_commands

      # Most specific first: `move:north` beats `move`.
      def keys_for(tool, args)
        args = args.is_a?(Hash) ? args : {}
        discriminator = DISCRIMINATORS.filter_map { |k| args[k] || args[k.to_s] }.first
        [ discriminator && "#{tool}:#{discriminator}", tool ].compact
      end

      def render(entry, key)
        entry = take(entry, key)

        case entry
        when String then entry
        when Hash   then render_entry(entry, key)
        else
          remember(UnexpectedCall.new("response for #{key.inspect} is a #{entry.class}; " \
                                      "expected a string or a {room:} / {text:} mapping"))
        end
      end

      def take(entry, key)
        return entry unless entry.is_a?(Array)

        remember(UnexpectedCall.new("responses for #{key.inspect} are exhausted; " \
                                    "the agent asked more times than the scenario scripted")) if entry.empty?
        entry.shift
      end

      # `{room: "Main Street"}` renders the room's own text from the scenario's
      # single declaration of it, which is what keeps the fixture's idea of a
      # room and the seeded map's idea of it from drifting apart. `{text: "..."}`
      # is the escape hatch for everything a room description cannot express —
      # a closed door, darkness, a death.
      def render_entry(entry, key)
        entry = entry.transform_keys(&:to_s)
        return entry["text"].to_s if entry.key?("text")

        room = @rooms[entry["room"].to_s]
        unless room
          remember(UnexpectedCall.new("response for #{key.inspect} names room " \
                                      "#{entry['room'].inspect}, which initial_state.rooms does not declare"))
        end
        room.text
      end

      def describe(tool, args)
        discriminator = keys_for(tool, args).first
        discriminator || tool
      end
    end
  end
end
