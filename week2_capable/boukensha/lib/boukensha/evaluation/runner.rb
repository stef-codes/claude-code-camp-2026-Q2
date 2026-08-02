require "time"
require_relative "assertions"
require_relative "result"
require_relative "scenario"
require_relative "scorer"
require_relative "transcript_driver"

module Boukensha
  module Evaluation
    # Run one scenario against the real agent.
    #
    # "Real" is the load-bearing word. This drives `Mud::Hooks#navigate` — the
    # same entry point the native `navigate` tool calls in a live session — so
    # `resolve_position`, `link_arrival`, `demote_exit!` and
    # `record_exit_failure!` all genuinely execute. The alternative, driving
    # `Mud::Navigator` directly with a stubbed `on_arrival`, would have the
    # HARNESS decide which room each arrival is; `edge_repaired` would then be
    # asserting about its own fixture, which is a test that can only pass.
    #
    # Everything the run touches is thrown away with it: an in-memory SQLite
    # store, an in-memory journal, no config, no files. Two runs of the same
    # scenario differ only in `started_at` and `duration_ms`.
    class Runner
      class Invalid < StandardError; end

      # Dispatch, not a case statement, so `explore` / `relocalize` /
      # `replay_session` are an entry each rather than a rewrite. Scenario
      # validation reads these keys, so an unsupported action is refused at load
      # time with the supported list in the message.
      ACTIONS = {
        "navigate" => ->(hooks, scenario) { hooks.navigate(destination: scenario.action[:destination]) }
      }.freeze

      # The Journal's interface, in memory.
      #
      # `Memory::Store` and `Mud::Hooks` both write to a journal through a duck
      # type — `upsert`, `event` — and the real one appends jsonl to a directory.
      # A scenario wants the events, not the file, and wants them without
      # touching the developer's disk. Recording the same two calls is the whole
      # of what the store asks for.
      class EventRecorder
        attr_reader :events

        def initialize = @events = []
        def upsert(stream:, key:, value:, **) = record(kind: "change", stream: stream.to_s, key: key.to_s, value: value)
        def event(stream:, op:, **fields) = record(fields.merge(kind: "event", stream: stream.to_s, op: op.to_s))
        def seed(stream:, values:) = nil
        def counters = { journal_lines: @events.length }
        def close = nil

        def events_for(stream, op)
          @events.select { |e| e[:kind] == "event" && e[:stream] == stream.to_s && e[:op] == op.to_s }
        end

        private

        def record(fields)
          @events << fields
          true
        end
      end

      def self.run(path) = new(Scenario.load(path)).run

      def initialize(scenario)
        @scenario = scenario
      end

      def run
        started_at = Time.now.utc
        clock = monotonic

        store = open_store
        journal = EventRecorder.new
        store.journal = journal

        begin
          room_ids = seed_map(store)
          driver = TranscriptDriver.new(@scenario.responses, rooms: @scenario.rooms_by_name,
                                        max_commands: @scenario.max_commands)
          hooks = build_hooks(store, driver, journal)

          establish_position!(hooks, store, driver)
          setup_calls = driver.calls.length

          result = ACTIONS.fetch(@scenario.action[:type]).call(hooks, @scenario)

          # Hooks#guard swallows every StandardError, so a fixture that ran out
          # of answers looks exactly like a walk that stopped early unless the
          # driver is asked directly. A scenario problem must never be reported
          # as an agent result.
          raise Scenario::Invalid, driver.error.message if driver.error.is_a?(TranscriptDriver::UnexpectedCall)

          metrics = collect(result, hooks: hooks, store: store, journal: journal,
                            driver: driver, setup_calls: setup_calls, room_ids: room_ids)
          outcomes = Assertions.evaluate_all(@scenario.assertions, metrics)

          Result.new(scenario: @scenario, assertions: outcomes, metrics: metrics,
                     score: Scorer.new(@scenario).score(outcomes, metrics),
                     started_at: started_at, duration_ms: ((monotonic - clock) * 1000).round,
                     failure_reason: failure_reason(metrics, driver))
        ensure
          store.close
        end
      end

      private

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def open_store
        Mud::Memory::Store.open(":memory:")
      rescue Mud::Memory::Store::Unavailable => e
        raise Invalid, "cannot run scenarios without a memory store: #{e.message}"
      end

      # The map the agent starts with, built through the store's own public API
      # rather than by loading SQL — the fixtures then survive a schema change,
      # and the rooms are fingerprinted by exactly the code that will look them
      # up again.
      #
      # Rooms are created `surveyed: true` because "navigate a route you already
      # know" is the scenario's premise: a room the agent has already stood in
      # spends nothing on arrival (Hooks#revisit), so the transcript needs only
      # the cold look and one entry per move.
      def seed_map(store)
        ids = {}
        @scenario.rooms.each do |room|
          look = Mud::RoomParser.parse_look(room.text)
          weak = Mud::Memory::Fingerprint.weak(name: look.name, description: look.description,
                                               exit_dirs: look.exit_dirs)
          targets = exit_targets(room)
          ids[room.name] = store.create_room(
            name: look.name, description: look.description, weak_fingerprint: weak,
            strong_fingerprint: Mud::Memory::Fingerprint.strong(weak, targets), surveyed: true
          )
          store.record_exits!(ids[room.name], dirs: look.exit_dirs, targets: targets)
        end

        @scenario.edges.each do |edge|
          store.link_exit!(ids.fetch(edge.from), edge.direction, ids.fetch(edge.to))
        end
        ids
      end

      def exit_targets(room)
        @scenario.edges.select { |e| e.from == room.name }
                 .to_h { |e| [ e.direction, e.to ] }
      end

      def build_hooks(store, driver, journal)
        Mud::Hooks.new(store: store, call_tool: driver.to_proc, journal: journal, warn_to: nil)
      end

      # Position is Hooks' property and has no setter — correctly, since a
      # position nobody observed is exactly the guess the memory layer exists to
      # refuse. So the scenario establishes it the way a real session does: one
      # cold `look`, resolved against the seeded map.
      def establish_position!(hooks, store, driver)
        hooks.before_model(context: Context.new(system: ""))
        raise Invalid, driver.error.message if driver.error

        actual = store.room(hooks.current_room_id)&.fetch(:name, nil)
        return if actual == @scenario.start

        raise Invalid, "#{@scenario.id}: the cold look resolved to #{actual.inspect}, " \
                       "but initial_state.start says #{@scenario.start.inspect} — " \
                       "check the `look` response in the transcript"
      end

      def collect(result, hooks:, store:, journal:, driver:, setup_calls:, room_ids:)
        result = {} unless result.is_a?(Hash)
        names = room_ids.invert
        final_id = hooks.current_room_id

        {
          navigation_ok: !!result[:ok],
          reason: result[:reason].to_s,
          steps: result[:steps_walked].to_i,
          steps_planned: result[:steps_planned].to_i,
          replans: result[:replans].to_i,
          tool_calls: driver.calls.length - setup_calls,
          setup_tool_calls: setup_calls,
          moves: driver.calls.drop(setup_calls).select { |(t, _)| t == "move" }
                       .map { |(_, a)| (a[:direction] || a["direction"]).to_s },
          final_room_id: final_id,
          final_room: names[final_id] || store.room(final_id)&.fetch(:name, nil),
          deaths: journal.events_for("milestone", "death").length,
          # Recovery evidence, straight off the store's own journal: these lines
          # exist only because `record_exit_failure!` / `demote_exit!` ran.
          blocked_exits: edges(journal.events_for("exit", "failure"), names),
          demoted_edges: edges(journal.events_for("exit", "demote"), names),
          # Where the map points NOW. The journal says what happened; this says
          # what is true afterwards, and the two are not the same question — a
          # walk can retarget an edge without demoting it, and (as a mutation
          # test showed) an assertion on the event alone will not notice if the
          # retarget stops happening.
          exits: exit_targets_now(store, room_ids, names),
          rooms: store.stats[:rooms],
          budget_exceeded: driver.budget_exceeded?
        }
      end

      # Every seeded room's exits, as the store holds them once the walk is
      # over: { "Town Square:north" => "Back Alley" }. An unlinked exit maps to
      # nil rather than being absent, so an assertion can tell "this edge points
      # nowhere" from "this edge does not exist".
      def exit_targets_now(store, room_ids, names)
        room_ids.each_with_object({}) do |(room_name, id), out|
          store.exits_for(id).each do |exit|
            out[Assertions.edge_key(room_name, exit[:direction])] = names[exit[:target_room_id]]
          end
        end
      end

      def edges(events, names)
        events.map do |e|
          { room_id: e[:room_id], room: names[e[:room_id]], direction: e[:direction] }
        end
      end

      def failure_reason(metrics, driver)
        return "command budget exceeded after #{driver.calls.length} calls" if metrics[:budget_exceeded]

        nil
      end
    end
  end
end
