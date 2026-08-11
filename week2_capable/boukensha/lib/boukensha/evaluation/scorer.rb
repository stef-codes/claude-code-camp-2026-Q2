module Boukensha
  module Evaluation
    # One number, and the evidence for it.
    #
    # The score exists to make runs comparable over time; the BREAKDOWN exists
    # so the number is never the only thing you have. Every category reports
    # what it earned, what it could have earned, and why — because a score with
    # no derivation is a number people learn to ignore the first time it
    # disagrees with them.
    #
    # Categories that a scenario does not opt into are marked `applicable:
    # false` and leave the denominator. A blocked-exit scenario has no sensible
    # efficiency figure, and inventing one — awarding zero, or silently awarding
    # full marks — would make two scenarios' scores mean different things while
    # looking the same.
    class Scorer
      WEIGHTS = { success: 70, efficiency: 15, recovery: 10, safety: 5 }.freeze

      Category = Struct.new(:name, :earned, :max, :applicable, :note, keyword_init: true) do
        def to_h = { earned: earned.round(2), max: max, applicable: applicable, note: note }
      end

      def initialize(scenario)
        @scenario = scenario
      end

      def score(outcomes, metrics)
        by_name = outcomes.to_h { |o| [ o.name, o ] }

        categories = [
          success(by_name),
          efficiency(metrics),
          recovery(by_name),
          safety(metrics)
        ]

        applicable = categories.select(&:applicable)
        possible = applicable.sum(&:max)
        earned = applicable.sum(&:earned)

        { score: possible.zero? ? 0.0 : ((earned / possible.to_f) * 100).round(1),
          points: earned.round(2), points_possible: possible,
          breakdown: categories.to_h { |c| [ c.name, c.to_h ] } }
      end

      private

      # All or nothing, deliberately. "Reached the right room, but only after
      # walking through three wrong ones" is not 80% of a success — it is a
      # failure with a consolation prize, and partial credit here would let a
      # scenario drift red-to-amber without anyone noticing it stopped passing.
      def success(by_name)
        required = @scenario.required
        return Category.new(name: :success, earned: 0, max: WEIGHTS[:success], applicable: true,
                            note: "no required assertions declared") if required.empty?

        failed = required.reject { |name| by_name[name]&.passed }
        Category.new(name: :success, max: WEIGHTS[:success], applicable: true,
                     earned: failed.empty? ? WEIGHTS[:success] : 0,
                     note: failed.empty? ? "all required assertions passed" : "failed: #{failed.join(', ')}")
      end

      # Needs a yardstick. `expected_steps` is the best known route length for
      # this world, which only the scenario author knows.
      #
      # Only ever measured on a run that ARRIVED. The first mutation test caught
      # this: capping the navigator's replans made the stale-edge scenario give
      # up after one step, and an earlier version of this method scored that
      # 15/15 — "fewer steps than expected" is efficient only if the steps got
      # you there. A walk that stopped short is not a short walk.
      def efficiency(metrics)
        expected = @scenario.expected_steps
        return Category.new(name: :efficiency, earned: 0, max: WEIGHTS[:efficiency], applicable: false,
                            note: "scenario declares no scoring.expected_steps") if expected.nil?

        unless metrics[:navigation_ok]
          return Category.new(name: :efficiency, earned: 0, max: WEIGHTS[:efficiency], applicable: true,
                              note: "the run did not arrive; step count is not an efficiency")
        end

        actual = metrics[:steps].to_i
        ratio = if actual <= expected then 1.0
                elsif actual.zero? then 0.0
                else expected / actual.to_f
                end
        ratio = ratio.clamp(0.0, 1.0)
        Category.new(name: :efficiency, earned: ratio * WEIGHTS[:efficiency], max: WEIGHTS[:efficiency],
                     applicable: true, note: "#{actual} steps against an expected #{expected}")
      end

      # Recovery is scored ONLY from the assertions the scenario nominated as
      # recovery evidence, and each of those reads a state change the store
      # actually wrote. There is no path here for "the model said it recovered".
      def recovery(by_name)
        evidence = @scenario.recovery
        return Category.new(name: :recovery, earned: 0, max: WEIGHTS[:recovery], applicable: false,
                            note: "scenario declares no scoring.recovery evidence") if evidence.empty?

        passed = evidence.count { |name| by_name[name]&.passed }
        Category.new(name: :recovery, max: WEIGHTS[:recovery], applicable: true,
                     earned: (passed / evidence.size.to_f) * WEIGHTS[:recovery],
                     note: "#{passed} of #{evidence.size}: #{evidence.join(', ')}")
      end

      # Deductions, not awards — safety is the category you lose. Always
      # applicable: every run can be checked for having died or overrun, so
      # nothing here depends on the author remembering to ask.
      def safety(metrics)
        faults = []
        faults << "died #{metrics[:deaths]}×" if metrics[:deaths].to_i.positive?
        faults << "command budget exceeded" if metrics[:budget_exceeded]
        if @scenario.max_replans && metrics[:replans].to_i > @scenario.max_replans
          faults << "replanned #{metrics[:replans]}× over a limit of #{@scenario.max_replans}"
        end

        Category.new(name: :safety, max: WEIGHTS[:safety], applicable: true,
                     earned: faults.empty? ? WEIGHTS[:safety] : 0,
                     note: faults.empty? ? "no faults" : faults.join("; "))
      end
    end
  end
end
