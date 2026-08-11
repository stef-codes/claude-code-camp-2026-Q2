require "json"
require "time"

module Boukensha
  module Evaluation
    # What one scenario run produced. Serialised as JSON so a run is an artifact
    # rather than a screenful of output — diffable, archivable, and comparable
    # against the same scenario a month later.
    #
    # `result_version` is here from the first commit for the same reason
    # `Scenario::SUPPORTED_VERSIONS` is: something will read these files back,
    # and it needs to know what it is holding.
    #
    # Two different notions of "did it pass", both reported, because conflating
    # them hides things:
    #
    #   passed          every declared assertion held. This is the exit code.
    #   required_passed the subset the scenario nominated as defining success.
    #                   This is what the score's 70 points hang on.
    #
    # A run where the agent arrived but took twice as many steps as it should
    # have is `required_passed: true, passed: false` — and that distinction is
    # the whole reason to write a scenario rather than a smoke test.
    class Result
      RESULT_VERSION = 1

      attr_reader :scenario, :assertions, :metrics, :score, :started_at, :duration_ms, :failure_reason

      def initialize(scenario:, assertions:, metrics:, score:, started_at:, duration_ms:,
                     failure_reason: nil)
        @scenario = scenario
        @assertions = assertions
        @metrics = metrics
        @score = score
        @started_at = started_at
        @duration_ms = duration_ms
        @failure_reason = failure_reason
      end

      def passed = @failure_reason.nil? && @assertions.all?(&:passed)

      def required_passed
        @scenario.required.empty? ||
          @scenario.required.all? { |name| @assertions.find { |a| a.name == name }&.passed }
      end

      def failures = @assertions.reject(&:passed)

      def to_h
        {
          result_version: RESULT_VERSION,
          scenario_id: @scenario.id,
          description: @scenario.description,
          passed: passed,
          required_passed: required_passed,
          score: @score[:score],
          started_at: @started_at.utc.iso8601,
          duration_ms: @duration_ms,
          metrics: @metrics,
          assertions: @assertions.map(&:to_h),
          score_breakdown: @score[:breakdown],
          points: @score[:points],
          points_possible: @score[:points_possible],
          failure_reason: @failure_reason
        }
      end

      def to_json(*args) = JSON.pretty_generate(to_h, *args)

      # The one-screen version. Says where the agent ended up in every branch,
      # the same rule Navigator.render follows: a failed run still moved it, and
      # a report that omits that is the most expensive kind of wrong.
      def to_s
        lines = [ format("%-7s %s  score %.1f (%s/%s)",
                         passed ? "PASS" : "FAIL", @scenario.id, @score[:score],
                         @score[:points], @score[:points_possible]) ]
        lines << "  #{@failure_reason}" if @failure_reason
        lines << "  ended in #{@metrics[:final_room].inspect} (##{@metrics[:final_room_id]}) " \
                 "after #{@metrics[:steps]} step#{'s' unless @metrics[:steps] == 1}, " \
                 "#{@metrics[:replans]} replan#{'s' unless @metrics[:replans] == 1}, " \
                 "#{@metrics[:tool_calls]} tool call#{'s' unless @metrics[:tool_calls] == 1}"
        @assertions.each do |a|
          lines << format("  %s %-24s expected %s, got %s",
                          a.passed ? "✓" : "✗", a.name, a.expected.inspect, a.actual.inspect)
        end
        @score[:breakdown].each do |name, c|
          lines << format("  %-11s %5.1f / %-3s %s", name, c[:earned],
                          c[:applicable] ? c[:max] : "n/a", c[:note])
        end
        lines.join("\n")
      end
    end
  end
end
