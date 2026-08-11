require_relative "helper"
require "boukensha/evaluation"

# Evaluation::Scorer — the number, and whether it can be trusted.
#
# Every test here asserts on the BREAKDOWN, not just the total. A score is only
# useful if you can say where it came from, and a category that quietly awards
# points for the wrong reason is invisible in the total right up until someone
# makes a decision with it.
class TestEvaluationScorer < Minitest::Test
  E = Boukensha::Evaluation
  A = Boukensha::Evaluation::Assertions

  def scenario(assertions: { "navigation_ok" => true }, **scoring)
    # Braces are load-bearing: `Scenario#initialize` takes a `path:` keyword, so
    # Ruby would read a brace-less trailing hash as keyword arguments and report
    # a missing positional argument instead.
    E::Scenario.new({
      "version" => 1, "id" => "t",
      "initial_state" => {
        "start" => "A",
        "rooms" => [ { "name" => "A", "description" => "prose", "exits" => [] } ], "edges" => []
      },
      "driver" => { "type" => "transcript", "responses" => { "look" => [ { "room" => "A" } ] } },
      "action" => { "type" => "navigate", "destination" => "A" },
      "assertions" => assertions,
      "scoring" => scoring.transform_keys(&:to_s),
      "limits" => { "max_replans" => scoring[:max_replans] }.compact
    })
  end

  def outcomes(**passed)
    passed.map { |name, ok| A::Outcome.new(name: name.to_s, passed: ok, expected: nil, actual: nil) }
  end

  def metrics(**overrides)
    { navigation_ok: true, steps: 2, replans: 0, tool_calls: 2, deaths: 0,
      budget_exceeded: false }.merge(overrides)
  end

  def score(scenario, outcomes, metrics)
    E::Scorer.new(scenario).score(outcomes, metrics)
  end

  # --- success is all or nothing ---------------------------------------------

  def test_all_required_assertions_passing_earns_the_whole_success_block
    s = score(scenario(required: %w[navigation_ok]), outcomes(navigation_ok: true), metrics)

    assert_equal 70, s[:breakdown][:success][:earned]
    assert_equal "all required assertions passed", s[:breakdown][:success][:note]
  end

  # Partial credit here would let a scenario drift from passing to nearly-passing
  # without anyone noticing it had stopped passing.
  def test_one_failed_required_assertion_costs_the_entire_success_block
    s = scenario(assertions: { "navigation_ok" => true, "steps_eq" => 2 },
                 required: %w[navigation_ok steps_eq])
    result = score(s, outcomes(navigation_ok: true, steps_eq: false), metrics)

    assert_equal 0, result[:breakdown][:success][:earned]
    assert_includes result[:breakdown][:success][:note], "failed: steps_eq"
  end

  # --- efficiency ------------------------------------------------------------

  def test_a_walk_at_the_expected_length_is_fully_efficient
    s = score(scenario(required: %w[navigation_ok], expected_steps: 2),
              outcomes(navigation_ok: true), metrics(steps: 2))

    assert_equal 15, s[:breakdown][:efficiency][:earned]
  end

  def test_a_walk_twice_as_long_as_expected_earns_half
    s = score(scenario(required: %w[navigation_ok], expected_steps: 2),
              outcomes(navigation_ok: true), metrics(steps: 4))

    assert_in_delta 7.5, s[:breakdown][:efficiency][:earned], 0.01
  end

  # The bug the first mutation test found: capping the navigator's replans made
  # a scenario give up after one step, and this scored it 15/15 for brevity.
  # Fewer steps is efficient only if the steps got you there.
  def test_a_run_that_never_arrived_earns_no_efficiency_however_short_it_was
    s = score(scenario(required: %w[navigation_ok], expected_steps: 4),
              outcomes(navigation_ok: false), metrics(navigation_ok: false, steps: 1))

    assert_equal 0, s[:breakdown][:efficiency][:earned]
    assert s[:breakdown][:efficiency][:applicable], "it still counts against the total"
    assert_includes s[:breakdown][:efficiency][:note], "did not arrive"
  end

  # --- categories a scenario did not opt into --------------------------------

  # Awarding zero for an unasked question would punish a scenario for a
  # dimension it never claimed; awarding full marks would inflate it. Neither is
  # honest, so the category leaves the denominator entirely.
  def test_an_unscored_category_leaves_the_denominator_rather_than_scoring_zero
    s = score(scenario(required: %w[navigation_ok]), outcomes(navigation_ok: true), metrics)

    refute s[:breakdown][:efficiency][:applicable]
    refute s[:breakdown][:recovery][:applicable]
    assert_equal 75, s[:points_possible], "success 70 + safety 5, with no efficiency or recovery"
    assert_in_delta 100.0, s[:score], 0.01
  end

  def test_the_max_of_an_inapplicable_category_is_still_reported
    s = score(scenario(required: %w[navigation_ok]), outcomes(navigation_ok: true), metrics)

    assert_equal 15, s[:breakdown][:efficiency][:max],
                 "the report has to say what was skipped, not hide it"
  end

  # --- recovery --------------------------------------------------------------

  def test_recovery_is_the_fraction_of_nominated_evidence_that_held
    s = scenario(assertions: { "navigation_ok" => true, "stale_edge_demoted" => true, "replans_eq" => 1 },
                 required: %w[navigation_ok], recovery: %w[stale_edge_demoted replans_eq])
    result = score(s, outcomes(navigation_ok: true, stale_edge_demoted: true, replans_eq: false), metrics)

    assert_equal 5.0, result[:breakdown][:recovery][:earned]
    assert_includes result[:breakdown][:recovery][:note], "1 of 2"
  end

  # --- safety is deducted, never awarded -------------------------------------

  def test_a_death_costs_the_whole_safety_block
    s = score(scenario(required: %w[navigation_ok]), outcomes(navigation_ok: true),
              metrics(deaths: 1))

    assert_equal 0, s[:breakdown][:safety][:earned]
    assert_includes s[:breakdown][:safety][:note], "died 1"
  end

  def test_exceeding_the_command_budget_costs_the_whole_safety_block
    s = score(scenario(required: %w[navigation_ok]), outcomes(navigation_ok: true),
              metrics(budget_exceeded: true))

    assert_equal 0, s[:breakdown][:safety][:earned]
    assert_includes s[:breakdown][:safety][:note], "budget"
  end

  def test_replanning_past_the_declared_limit_costs_the_whole_safety_block
    s = score(scenario(required: %w[navigation_ok], max_replans: 1),
              outcomes(navigation_ok: true), metrics(replans: 3))

    assert_equal 0, s[:breakdown][:safety][:earned]
    assert_includes s[:breakdown][:safety][:note], "over a limit of 1"
  end

  def test_safety_is_always_applicable_so_nothing_depends_on_the_author_asking
    s = score(scenario(required: %w[navigation_ok]), outcomes(navigation_ok: true), metrics)

    assert s[:breakdown][:safety][:applicable]
  end

  # --- the total -------------------------------------------------------------

  def test_the_score_is_a_percentage_of_what_was_applicable
    s = scenario(assertions: { "navigation_ok" => true, "stale_edge_demoted" => true },
                 required: %w[navigation_ok], recovery: %w[stale_edge_demoted], expected_steps: 2)
    result = score(s, outcomes(navigation_ok: true, stale_edge_demoted: false), metrics)

    # 70 success + 15 efficiency + 0 of 10 recovery + 5 safety, out of 100.
    assert_equal 90.0, result[:points]
    assert_equal 100, result[:points_possible]
    assert_in_delta 90.0, result[:score], 0.01
  end
end
