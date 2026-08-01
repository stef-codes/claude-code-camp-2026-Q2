require_relative "helper"
require "boukensha/evaluation"

# Evaluation::Scenario — everything a scenario can get wrong, caught BEFORE the
# run.
#
# The ordering is the whole reason this class exists separately. A scenario with
# a typo in an assertion name must fail as a scenario problem, loudly, rather
# than run and report green for a case it silently never checked. Every test
# here is about a refusal.
class TestEvaluationScenario < Minitest::Test
  S = Boukensha::Evaluation::Scenario

  def scenario_hash(**overrides)
    {
      "version" => 1,
      "id" => "t",
      "description" => "a scenario",
      "initial_state" => {
        "start" => "A",
        "rooms" => [
          { "name" => "A", "description" => "prose about A", "exits" => %w[north] },
          { "name" => "B", "description" => "prose about B", "exits" => %w[south] }
        ],
        "edges" => [ %w[A north B], %w[B south A] ]
      },
      "driver" => { "type" => "transcript", "responses" => { "look" => [ { "room" => "A" } ] } },
      "action" => { "type" => "navigate", "destination" => "B" },
      "assertions" => { "navigation_ok" => true },
      "scoring" => { "required" => %w[navigation_ok] }
    }.merge(overrides.transform_keys(&:to_s))
  end

  def refuses(fragment, **overrides)
    e = assert_raises(S::Invalid) { S.new(scenario_hash(**overrides)) }
    assert_includes e.message, fragment
    e
  end

  # --- the happy path --------------------------------------------------------

  def test_a_valid_scenario_loads_every_field
    s = S.new(scenario_hash)

    assert_equal "t", s.id
    assert_equal "A", s.start
    assert_equal %w[A B], s.rooms.map(&:name)
    assert_equal "navigate", s.action[:type]
    assert_equal "B", s.action[:destination]
    assert_equal %w[navigation_ok], s.required
    assert_equal 50, s.max_commands, "an unstated command budget still has a ceiling"
  end

  # One declaration, two consumers: the seeded map and the MUD's replies. This
  # is what makes a fingerprint mismatch between the two impossible rather than
  # merely unlikely.
  def test_a_room_renders_the_mud_text_its_own_description_implies
    look = Boukensha::Mud::RoomParser.parse_look(S.new(scenario_hash).room!("A").text)

    assert look.complete?, "a room must render text RoomParser accepts as a room"
    assert_equal "A", look.name
    assert_equal %w[north], look.exit_dirs
  end

  def test_the_terse_and_verbose_edge_forms_mean_the_same_thing
    verbose = scenario_hash
    verbose["initial_state"] = verbose["initial_state"].merge(
      "edges" => [ { "from" => "A", "direction" => "north", "to" => "B" },
                   { "from" => "B", "direction" => "south", "to" => "A" } ]
    )

    assert_equal S.new(scenario_hash).edges.map(&:to_h), S.new(verbose).edges.map(&:to_h)
  end

  # --- refusals --------------------------------------------------------------

  def test_an_unknown_assertion_name_is_refused_with_the_known_ones_listed
    e = refuses("unknown assertion", assertions: { "reached_the_bakery" => true })

    assert_includes e.message, "navigation_ok", "the message has to say what IS allowed"
  end

  def test_an_unsupported_version_is_refused_rather_than_guessed_at
    refuses("unsupported scenario version", version: 2)
    refuses("unsupported scenario version", version: nil)
  end

  def test_a_missing_id_is_refused
    refuses("id is required", id: "")
  end

  def test_an_unsupported_action_lists_what_this_build_can_do
    e = refuses("unsupported action", action: { "type" => "explore", "destination" => "B" })

    assert_includes e.message, "navigate"
  end

  def test_an_action_without_a_destination_is_refused
    refuses("action.destination is required", action: { "type" => "navigate" })
  end

  def test_a_start_room_that_does_not_exist_is_refused
    state = scenario_hash["initial_state"].merge("start" => "Nowhere")
    refuses("no room called \"Nowhere\"", initial_state: state)
  end

  def test_an_edge_the_room_does_not_list_as_an_exit_is_refused
    # Otherwise this surfaces three layers down as a mysterious :no_route.
    state = scenario_hash["initial_state"].merge("edges" => [ %w[A east B] ])
    refuses("does not list east among its exits", initial_state: state)
  end

  def test_an_unknown_direction_is_refused
    state = scenario_hash["initial_state"].merge(
      "rooms" => [ { "name" => "A", "description" => "p", "exits" => %w[widdershins] } ]
    )
    refuses("unknown exits", initial_state: state)
  end

  def test_two_rooms_sharing_a_name_are_refused
    state = scenario_hash["initial_state"].merge(
      "rooms" => [ { "name" => "A", "description" => "one", "exits" => [] },
                   { "name" => "A", "description" => "two", "exits" => [] } ],
      "edges" => []
    )
    refuses("two rooms share a name", initial_state: state)
  end

  # `scoring.required` names assertions rather than restating their values, so
  # the two cannot drift. That only works if a name that is not declared is an
  # error.
  def test_scoring_that_names_an_undeclared_assertion_is_refused
    refuses("which the assertions block does not declare",
            scoring: { "required" => %w[steps_eq] })
  end

  def test_a_scenario_with_no_assertions_is_refused
    refuses("assertions are required", assertions: {})
  end

  # --- fixtures --------------------------------------------------------------

  def test_a_missing_transcript_fixture_is_refused
    refuses("transcript fixture not found",
            driver: { "type" => "transcript", "fixture" => "no/such/file.json" })
  end

  def test_a_malformed_transcript_fixture_is_refused
    Dir.mktmpdir do |dir|
      file = File.join(dir, "broken.json")
      File.write(file, "{ not json")
      path = File.join(dir, "s.yaml")
      File.write(path, YAML.dump(scenario_hash(
        driver: { "type" => "transcript", "fixture" => "broken.json" }
      )))

      e = assert_raises(S::Invalid) { S.load(path) }
      assert_includes e.message, "malformed transcript fixture"
    end
  end

  def test_malformed_yaml_is_refused_as_a_scenario_problem
    Dir.mktmpdir do |dir|
      path = File.join(dir, "s.yaml")
      File.write(path, "version: 1\n  id: [unclosed\n")
      assert_raises(S::Invalid) { S.load(path) }
    end
  end

  def test_a_missing_scenario_file_is_refused
    e = assert_raises(S::Invalid) { S.load("/nonexistent/scenario.yaml") }
    assert_includes e.message, "no such scenario"
  end

  # --- the shipped scenarios -------------------------------------------------

  # These are the files the definition of done names, so they are worth loading
  # in the suite rather than only through the CLI: a scenario that stops parsing
  # should fail here, with a parse error, not later with a confusing run.
  def test_every_shipped_scenario_parses
    paths = Boukensha::Evaluation.scenarios_in(File.expand_path("../scenarios", __dir__))

    assert_equal 3, paths.length, "the three navigation scenarios should be present"
    paths.each { |path| assert_kind_of S, S.load(path) }
  end
end
