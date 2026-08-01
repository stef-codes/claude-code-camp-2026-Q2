require_relative "helper"
require "boukensha/evaluation"
require "json"
require "open3"

# Evaluation::Runner — the three navigation scenarios, end to end, offline.
#
# What is actually being checked here is that the framework drives the REAL
# agent. The runner builds `Mud::Hooks` and calls `#navigate`, the same entry
# point the native `navigate` tool uses in a live session, so `resolve_position`,
# `link_arrival` and `demote_exit!` genuinely run. A harness that stubbed those
# would report the same numbers whether the code worked or not.
class TestEvaluationRunner < Minitest::Test
  E = Boukensha::Evaluation
  SCENARIOS = File.expand_path("../scenarios/navigation", __dir__)

  def setup
    store = Boukensha::Mud::Memory::Store.open(":memory:")
    store.close
  rescue Boukensha::Mud::Memory::Store::Unavailable => e
    skip e.message
  end

  def run_scenario(name) = E.run(File.join(SCENARIOS, "#{name}.yaml"))

  def scenario(**overrides)
    base = {
      "version" => 1, "id" => "t",
      "initial_state" => {
        "start" => "A",
        "rooms" => [ { "name" => "A", "description" => "prose about A", "exits" => %w[north] },
                     { "name" => "B", "description" => "prose about B", "exits" => %w[south] } ],
        "edges" => [ %w[A north B], %w[B south A] ]
      },
      "driver" => { "type" => "transcript",
                    "responses" => { "look" => [ { "room" => "A" } ], "poll" => "",
                                     "move:north" => [ { "room" => "B" } ] } },
      "action" => { "type" => "navigate", "destination" => "B" },
      "assertions" => { "navigation_ok" => true },
      "scoring" => { "required" => %w[navigation_ok] }
    }
    # Braces matter — see the note in test_evaluation_scorer.rb.
    E::Runner.new(E::Scenario.new(base.merge(overrides.transform_keys(&:to_s))))
  end

  # --- the three shipped scenarios -------------------------------------------

  def test_a_known_route_is_walked_exactly_and_costs_one_round_trip_per_step
    result = run_scenario("known_route")

    assert result.passed, result.to_s
    assert_equal "arrived", result.metrics[:reason]
    assert_equal 2, result.metrics[:steps]
    assert_equal 0, result.metrics[:replans]
    assert_equal "The Cozy Bakery", result.metrics[:final_room]
    # The narrow navigate allowlist is the point: a walk over known ground never
    # pays for a `look`.
    assert_equal %w[north east], result.metrics[:moves]
    assert_equal 2, result.metrics[:tool_calls]
    assert_in_delta 100.0, result.score[:score], 0.01
  end

  def test_a_blocked_exit_stops_the_walk_where_it_actually_is
    result = run_scenario("blocked_exit")

    assert result.passed, result.to_s
    refute result.metrics[:navigation_ok]
    assert_equal "blocked", result.metrics[:reason]
    assert_equal "Main Street", result.metrics[:final_room],
                 "a failed navigation still moved the character"
    assert_equal 1, result.metrics[:steps]
    assert_equal 2, result.metrics[:tool_calls], "it stops; it does not walk the rest of the route"
  end

  # The refusal has to survive as a fact about the map, not just as a sentence
  # in a log — this is the journal line `record_exit_failure!` wrote.
  def test_a_blocked_exit_is_recorded_against_the_edge_that_refused
    result = run_scenario("blocked_exit")

    assert_equal [ { room_id: 2, room: "Main Street", direction: "east" } ],
                 result.metrics[:blocked_exits]
  end

  def test_a_stale_edge_is_repaired_and_the_route_replanned_once
    result = run_scenario("stale_edge_recovery")

    assert result.passed, result.to_s
    assert_equal 1, result.metrics[:replans], "one surprise is recoverable; two is guessing"
    assert_equal "The Cozy Bakery", result.metrics[:final_room]
    assert_equal %w[north south], result.metrics[:moves],
                 "the second step comes from the replan, not the original route"
    assert_equal [ { room_id: 1, room: "Town Square", direction: "north" } ],
                 result.metrics[:repaired_edges]
  end

  # --- it is the real thing being driven -------------------------------------

  # Not an assertion about the scenario — an assertion that the runner is
  # driving code that has side effects on real memory. If this passed with a
  # stubbed arrival callback, every recovery assertion in the suite would be
  # theatre.
  def test_the_run_establishes_position_through_a_real_cold_look
    result = run_scenario("known_route")

    assert_equal 1, result.metrics[:setup_tool_calls],
                 "position comes from one cold look, resolved against the seeded map"
    assert_equal 3, result.metrics[:rooms], "the seeded rooms, and no accidental extras"
  end

  def test_a_transcript_that_puts_the_agent_somewhere_else_is_a_scenario_error
    runner = scenario("driver" => { "type" => "transcript",
                                    "responses" => { "look" => [ { "room" => "B" } ] } })

    e = assert_raises(E::Runner::Invalid) { runner.run }
    assert_includes e.message, "initial_state.start"
  end

  # --- fixture problems are never reported as agent results ------------------

  def test_an_unscripted_call_is_a_scenario_error_not_a_failed_run
    # Hooks#guard swallows every StandardError, so without the driver being
    # asked directly afterwards this would look exactly like a walk that stopped
    # early — a fixture bug wearing a regression's clothes.
    runner = scenario("driver" => { "type" => "transcript",
                                    "responses" => { "look" => [ { "room" => "A" } ] } })

    e = assert_raises(E::Scenario::Invalid) { runner.run }
    assert_includes e.message, "no scripted response for"
    assert_includes e.message, "move:north"
  end

  def test_a_response_naming_an_undeclared_room_is_a_scenario_error
    runner = scenario("driver" => { "type" => "transcript",
                                    "responses" => { "look" => [ { "room" => "A" } ],
                                                     "move:north" => [ { "room" => "Atlantis" } ] } })

    e = assert_raises(E::Scenario::Invalid) { runner.run }
    assert_includes e.message, "Atlantis"
  end

  # --- budgets ---------------------------------------------------------------

  def test_exceeding_the_command_budget_fails_the_run_and_says_so
    result = scenario("limits" => { "max_commands" => 1 }).run

    refute result.passed
    assert result.metrics[:budget_exceeded]
    assert_includes result.failure_reason, "command budget exceeded"
    assert_equal 0, result.score[:breakdown][:safety][:earned]
  end

  # --- the result artifact ---------------------------------------------------

  def test_the_result_serialises_with_its_version_metrics_and_breakdown
    data = JSON.parse(run_scenario("known_route").to_json)

    assert_equal E::Result::RESULT_VERSION, data["result_version"]
    assert_equal "known_route_to_bakery", data["scenario_id"]
    assert data["passed"]
    assert_equal 2, data["metrics"]["steps"]
    assert_equal 70, data["score_breakdown"]["success"]["earned"]
    assert_equal 7, data["assertions"].length
    assert data["assertions"].all? { |a| a.key?("expected") && a.key?("actual") },
           "an assertion result has to carry what it wanted and what it got"
  end

  # `passed` is every assertion; `required_passed` is the subset the score's 70
  # points hang on. Conflating them would let a scenario that arrived by a
  # wasteful route report success.
  def test_passed_and_required_passed_are_different_questions
    result = scenario("assertions" => { "navigation_ok" => true, "steps_eq" => 99 },
                      "scoring" => { "required" => %w[navigation_ok] }).run

    refute result.passed, "a declared assertion failed"
    assert result.required_passed, "but the required subset held"
    assert_equal 70, result.score[:breakdown][:success][:earned]
  end

  def test_two_runs_of_one_scenario_agree_on_everything_but_the_clock
    volatile = %w[started_at duration_ms]
    first  = JSON.parse(run_scenario("stale_edge_recovery").to_json).except(*volatile)
    second = JSON.parse(run_scenario("stale_edge_recovery").to_json).except(*volatile)

    assert_equal first, second, "results must be reproducible across repeated runs"
  end

  # --- the driver ------------------------------------------------------------

  def test_a_standing_string_answers_however_often_it_is_asked
    driver = E::TranscriptDriver.new({ "poll" => "" })

    3.times { assert_equal "", driver.to_proc.call("tbamud__poll", {}) }
  end

  def test_an_ordered_list_is_consumed_and_then_refuses_rather_than_repeating
    driver = E::TranscriptDriver.new({ "look" => [ "one", "two" ] })
    call = driver.to_proc

    assert_equal "one", call.call("tbamud__look", {})
    assert_equal "two", call.call("tbamud__look", {})
    e = assert_raises(E::TranscriptDriver::UnexpectedCall) { call.call("tbamud__look", {}) }
    assert_includes e.message, "exhausted"
  end

  def test_the_discriminating_argument_picks_the_response
    driver = E::TranscriptDriver.new({ "move:north" => [ "N" ], "move:south" => [ "S" ] })
    call = driver.to_proc

    assert_equal "S", call.call("tbamud__move", { direction: "south" })
    assert_equal "N", call.call("tbamud__move", { direction: "north" })
  end

  def test_an_unscripted_tool_never_gets_a_default_answer
    driver = E::TranscriptDriver.new({ "look" => [ "x" ] })

    assert_raises(E::TranscriptDriver::UnexpectedCall) { driver.to_proc.call("tbamud__flee", {}) }
  end

  # --- the CLI ---------------------------------------------------------------

  # The 0/1/2 split is the contract with CI: a typo in a fixture and a genuine
  # regression must never look the same to whatever reads the exit code.
  def test_the_cli_exits_zero_on_a_passing_scenario
    _out, status = cli("scenarios/navigation/known_route.yaml", "--json")

    assert_equal 0, status.exitstatus
  end

  def test_the_cli_exits_one_when_the_scenario_runs_and_fails
    Dir.mktmpdir do |dir|
      path = File.join(dir, "failing.yaml")
      data = YAML.safe_load_file(File.join(SCENARIOS, "known_route.yaml"))
      data["assertions"]["steps_eq"] = 99
      data["driver"]["fixture"] = File.expand_path("fixtures/evaluation/known_route.json", __dir__)
      File.write(path, YAML.dump(data))

      out, status = cli(path)
      assert_equal 1, status.exitstatus, out
      assert_includes out, "FAIL"
    end
  end

  def test_the_cli_exits_two_when_the_scenario_is_invalid
    _out, status = cli("scenarios/navigation/does-not-exist.yaml")

    assert_equal 2, status.exitstatus
  end

  def test_the_cli_writes_the_result_where_it_is_told_to
    Dir.mktmpdir do |dir|
      file = File.join(dir, "nested", "result.json")
      cli("scenarios/navigation/known_route.yaml", "--output", file)

      assert_path_exists file
      assert_equal "known_route_to_bakery", JSON.parse(File.read(file))["scenario_id"]
    end
  end

  def cli(*args)
    root = File.expand_path("..", __dir__)
    out, status = Open3.capture2e(RbConfig.ruby, File.join(root, "bin", "boukensha-eval"), *args,
                                  chdir: root)
    [ out, status ]
  end
end
