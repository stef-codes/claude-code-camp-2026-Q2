module Boukensha
  module Evaluation
    # The vocabulary a scenario may assert in, and the only place that vocabulary
    # is defined. Scenario validation checks names against `NAMES`, so a typo is
    # refused before the run rather than ignored during it.
    #
    # Every check reads a RECORDED FACT — the navigator's own result hash, the
    # store, the journal, or the driver's call list. Nothing here interprets
    # prose, and nothing asks a model anything. That is the constraint that makes
    # a score reproducible.
    #
    # What is deliberately absent: `invalid_commands`. The navigate allowlist
    # pins `direction` to six values and validates every rule against the tool's
    # own schema at startup, so on this path the count cannot be anything but
    # zero. An assertion that cannot fail reads as a passing safety check while
    # checking nothing, which is a worse lie than an absent one.
    module Assertions
      Outcome = Struct.new(:name, :passed, :expected, :actual, keyword_init: true) do
        def to_h = { name: name, passed: passed, expected: expected, actual: actual }
      end

      # Each entry answers (metrics, expected) => [passed, actual_for_the_report].
      CHECKS = {
        # --- the verdict --------------------------------------------------
        "navigation_ok" => lambda { |m, want|
          [ !!m[:navigation_ok] == !!want, m[:navigation_ok] ]
        },
        # The navigator's own reason symbol: :arrived, :blocked, :lost,
        # :no_route, :already_here, :unknown_destination, :no_position.
        "reason" => lambda { |m, want|
          [ m[:reason].to_s == want.to_s, m[:reason] ]
        },

        # --- where it ended up --------------------------------------------
        #
        # `reached_*` and `final_*` are the SAME recorded fact under two names,
        # because the two read differently at the call site: a scenario that
        # expects to arrive says `reached_room`, one that expects to stop short
        # says `final_room`. Aliases, not two measurements — asserting both is
        # allowed and is simply redundant, never contradictory.
        "reached_room"    => ->(m, want) { [ m[:final_room].to_s == want.to_s, m[:final_room] ] },
        "final_room"      => ->(m, want) { [ m[:final_room].to_s == want.to_s, m[:final_room] ] },
        "reached_room_id" => ->(m, want) { [ m[:final_room_id] == want.to_i, m[:final_room_id] ] },
        "final_room_id"   => ->(m, want) { [ m[:final_room_id] == want.to_i, m[:final_room_id] ] },

        # --- cost ----------------------------------------------------------
        "steps_lte"      => ->(m, want) { [ m[:steps].to_i <= want.to_i, m[:steps] ] },
        "steps_eq"       => ->(m, want) { [ m[:steps].to_i == want.to_i, m[:steps] ] },
        "replans_lte"    => ->(m, want) { [ m[:replans].to_i <= want.to_i, m[:replans] ] },
        "replans_eq"     => ->(m, want) { [ m[:replans].to_i == want.to_i, m[:replans] ] },
        # Counts only the calls the ACTION made; the cold look that establishes
        # position is setup and is reported separately.
        "tool_calls_lte" => ->(m, want) { [ m[:tool_calls].to_i <= want.to_i, m[:tool_calls] ] },

        # --- safety ---------------------------------------------------------
        "deaths" => ->(m, want) { [ m[:deaths].to_i == want.to_i, m[:deaths] ] },

        # --- recovery, from state changes and nothing else -------------------
        #
        # Both of these read journal events emitted by the STORE
        # (`record_exit_failure!`, `demote_exit!`), so they are true only if the
        # code actually wrote the repair. Pass `true` for "it happened at all",
        # or a mapping to pin which edge.
        "blocked_exit_recorded" => lambda { |m, want|
          match_edge(m[:blocked_exits], want)
        },
        "edge_repaired" => lambda { |m, want|
          match_edge(m[:repaired_edges], want)
        }
      }.freeze

      NAMES = CHECKS.keys.freeze

      module_function

      def match_edge(recorded, want)
        recorded = Array(recorded)
        return [ recorded.any?, recorded ] if want == true
        return [ recorded.empty?, recorded ] if want == false

        want = want.transform_keys(&:to_s)
        hit = recorded.find do |edge|
          (want["room"].nil?      || edge[:room].to_s == want["room"].to_s) &&
            (want["direction"].nil? || edge[:direction].to_s == want["direction"].to_s)
        end
        [ !hit.nil?, recorded ]
      end

      def evaluate(name, metrics, expected)
        check = CHECKS.fetch(name.to_s)
        passed, actual = check.call(metrics, expected)
        Outcome.new(name: name.to_s, passed: !!passed, expected: expected, actual: actual)
      end

      def evaluate_all(assertions, metrics)
        assertions.map { |name, expected| evaluate(name, metrics, expected) }
      end
    end
  end
end
