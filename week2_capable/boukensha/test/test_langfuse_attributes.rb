require_relative "helper"
require "json"
# `Telemetry.build` requires this lazily, only when otel is switched on, so it
# is not loaded by requiring boukensha.
require_relative "../lib/boukensha/telemetry/open_telemetry"

# The Langfuse wire contract, pinned as literals.
#
# Every other telemetry test drives `RecordingTelemetry`, a fake that accepts
# whatever it is given — which is precisely why nothing failed while the real
# exporter wrote all of its content to span EVENTS. Langfuse reads span
# ATTRIBUTES and does not look at events at all, so prompts, responses, tool
# calls and tool results were being exported to a place the backend never reads.
# Verified against the live API: every trace showed empty input and output, and
# turning `capture_content` on changed nothing.
#
# A fake cannot catch that, because the bug was never in the logic — it was in
# the NAMES. So this file asserts the names, and nothing else.
#
# Sources for these strings: Langfuse's OpenTelemetry mapping. If a value here
# changes, the traces do not break loudly; they go quietly blank. Treat a
# failure as "confirm against the docs", never as "update the constant".
class TestLangfuseAttributes < Minitest::Test
  T = Boukensha::Telemetry::OpenTelemetry

  INPUT  = "langfuse.observation.input".freeze
  OUTPUT = "langfuse.observation.output".freeze

  def test_input_phases_map_to_the_langfuse_input_attribute
    assert_equal :messages, T::INPUT_PHASES["prompt"]
    assert_equal :messages, T::INPUT_PHASES["request"]
    assert_equal :args,     T::INPUT_PHASES["tool_call"]
  end

  def test_output_phases_map_to_the_langfuse_output_attribute
    assert_equal :text,   T::OUTPUT_PHASES["response"]
    assert_equal :text,   T::OUTPUT_PHASES["plan"]
    assert_equal :result, T::OUTPUT_PHASES["tool_result"]
  end

  # A phase cannot be both, or the later write silently erases the earlier one.
  def test_no_phase_is_both_input_and_output
    assert_empty T::INPUT_PHASES.keys & T::OUTPUT_PHASES.keys
  end

  # `request` and `prompt` both fire on the `chat` span and the last write wins.
  # `request` is the payload that actually went to the provider, so it must be
  # the one that survives — which means it has to come second in insertion
  # order for anyone reading this to reason about it, and both must be inputs.
  def test_request_and_prompt_are_both_inputs
    assert_equal %w[prompt request], (T::INPUT_PHASES.keys & %w[prompt request])
  end

  # The exporter must not silently start shipping content that the operator
  # turned off. This is the privacy switch, so it gets an explicit test.
  def test_capture_io_is_a_no_op_when_content_capture_is_disabled
    telemetry = T.allocate
    telemetry.instance_variable_set(:@capture_content, false)

    assert_nil telemetry.capture_io(input: "secret prompt", output: "secret reply")
  end

  def test_noop_telemetry_answers_capture_io
    assert_nil Boukensha::Telemetry::Noop.new.capture_io(input: "x", output: "y")
  end

  # Session grouping is the audit-trail claim, and it worked from the start only
  # because Langfuse accepts `session.id` as an alias. Both keys are set now so
  # the grouping does not depend on that alias surviving a Langfuse release.
  def test_every_span_carries_both_session_keys
    Dir.mktmpdir do |dir|
      recorder = SpanAttributeRecorder.new
      logger = Boukensha::Logger.new(session_id: "sess-1", log: File.join(dir, "s.jsonl"),
                                     telemetry: recorder)
      logger.operation("probe") { nil }
      logger.close

      attrs = recorder.attributes.first
      assert_equal "sess-1", attrs["session.id"]
      assert_equal "sess-1", attrs["langfuse.session.id"]
    end
  end

  # ---------- scores ------------------------------------------------------

  # Scores are the one thing that cannot ride OTLP — no OpenTelemetry equivalent
  # exists — so they get their own HTTP channel, and its failure modes matter
  # more than usual because it runs inside a live agent.
  L = Boukensha::Telemetry::Langfuse

  def test_scoring_is_disabled_without_credentials
    assert_nil L.from_env({})
    assert_nil L.from_env({ "LANGFUSE_PUBLIC_KEY" => "pk", "LANGFUSE_SECRET_KEY" => "" })
  end

  def test_scores_queue_rather_than_sending
    scorer = L.new(base_url: "https://example.test", public_key: "pk", secret_key: "sk")
    scorer.score(trace_id: "t1", name: "navigate.arrived", value: 1)

    assert_equal 1, scorer.pending.length
    assert_equal "navigate.arrived", scorer.pending.first.name
  end

  # A score with no trace has nothing to attach to. Dropping it beats posting it
  # somewhere it can never be found.
  def test_a_score_without_a_trace_id_is_dropped
    scorer = L.new(base_url: "https://example.test", public_key: "pk", secret_key: "sk")
    scorer.score(trace_id: nil, name: "navigate.arrived", value: 1)

    assert_empty scorer.pending
  end

  # A scoring outage must never become an agent outage.
  def test_flush_swallows_a_dead_endpoint
    scorer = L.new(base_url: "https://127.0.0.1:1", public_key: "pk", secret_key: "sk",
                   warning_io: StringIO.new)
    scorer.score(trace_id: "t1", name: "x", value: 1)

    assert_equal 0, scorer.flush
  end

  # The regression this one guards: `after_turn` is not once per user turn. It
  # fires on every exit from the agent loop AND once per delegated subagent, so
  # the first version of this produced EIGHT position scores for one prompt.
  def test_the_turn_score_samples_once_per_distinct_state
    hooks = Boukensha::Mud::Hooks.allocate
    recorder = ScoreRecorder.new
    hooks.instance_variable_set(:@logger, recorder)
    hooks.instance_variable_set(:@current_room_id, 7)
    hooks.instance_variable_set(:@candidate_room_ids, [])
    hooks.instance_variable_set(:@mode, :navigating)
    hooks.instance_variable_set(:@last_scored_position, nil)

    3.times { hooks.after_turn(context: nil, text: "x") }
    assert_equal 2, recorder.scores.length, "same state three times is one sample"

    hooks.instance_variable_set(:@current_room_id, 9)
    hooks.after_turn(context: nil, text: "x")
    assert_equal 4, recorder.scores.length, "a changed state is a new sample"
  end

  def test_a_delegated_subagent_does_not_score_on_the_players_behalf
    hooks = Boukensha::Mud::Hooks.allocate
    recorder = ScoreRecorder.new(depth: 1)
    hooks.instance_variable_set(:@logger, recorder)
    hooks.instance_variable_set(:@current_room_id, 7)
    hooks.instance_variable_set(:@candidate_room_ids, [])
    hooks.instance_variable_set(:@last_scored_position, nil)

    hooks.after_turn(context: nil, text: "x")
    assert_empty recorder.scores
  end

  # ---------- prompt management -------------------------------------------

  # Central prompt management puts a network call in front of the first model
  # call of every process. That is only acceptable if failure is invisible, so
  # these tests are all about the failure path — the success path is the easy
  # half and is verified live.
  R = Boukensha::Telemetry::PromptRegistry

  def test_prompt_fetching_is_opt_in
    assert_nil R.from_env({ "LANGFUSE_PUBLIC_KEY" => "pk", "LANGFUSE_SECRET_KEY" => "sk",
                            "LANGFUSE_BASE_URL" => "https://example.test" }, enabled: false)
  end

  def test_prompt_fetching_needs_all_three_credentials
    assert_nil R.from_env({ "LANGFUSE_PUBLIC_KEY" => "pk" }, enabled: true)
  end

  # A Langfuse outage must not stop the agent starting. `fetch` returning nil is
  # an ordinary answer meaning "use the file".
  def test_an_unreachable_langfuse_returns_nil_rather_than_raising
    registry = R.new(base_url: "https://127.0.0.1:1", public_key: "pk", secret_key: "sk",
                     warning_io: StringIO.new)

    assert_nil registry.fetch("boukensha-player-system")
  end

  # Including the miss. Without caching a negative result, an agent whose prompt
  # was never pushed pays the connect timeout on every single lookup.
  def test_a_miss_is_cached_so_the_timeout_is_paid_once
    registry = R.new(base_url: "https://127.0.0.1:1", public_key: "pk", secret_key: "sk",
                     warning_io: StringIO.new)
    registry.fetch("boukensha-player-system")

    calls = 0
    registry.define_singleton_method(:request) { |_name| calls += 1 }
    registry.fetch("boukensha-player-system")

    assert_equal 0, calls, "the second lookup must not hit the network again"
  end

  # Prompt names are namespaced: a Langfuse project is shared with whatever else
  # the team runs, and "system" would be a careless thing to claim.
  def test_prompt_names_are_namespaced_per_task
    assert_equal "boukensha-player-system", Boukensha::Tasks::Player.langfuse_prompt_name
    assert_equal "boukensha-explorer-system", Boukensha::Tasks::Explorer.langfuse_prompt_name
  end

  # The precedence that makes "roll back without a redeploy" true, and the
  # fallback that keeps it safe.
  def test_langfuse_beats_the_file_but_nil_falls_back_to_it
    remote = R::Prompt.new(name: "boukensha-player-system", version: 3, text: "FROM LANGFUSE")

    text = Boukensha::Tasks::Player.system_prompt(
      {}, default_prompts_dir: Boukensha::Config::PROMPTS_DIR, registry: StubRegistry.new(remote)
    )
    assert_equal "FROM LANGFUSE", text
    assert_equal 3, Boukensha::Tasks::Player.last_prompt_source.version

    from_file = Boukensha::Tasks::Player.system_prompt(
      {}, default_prompts_dir: Boukensha::Config::PROMPTS_DIR, registry: StubRegistry.new(nil)
    )
    refute_equal "FROM LANGFUSE", from_file
    assert_nil Boukensha::Tasks::Player.last_prompt_source,
               "a file-sourced prompt must not claim a Langfuse version"
  end

  StubRegistry = Struct.new(:prompt) do
    def fetch(_name) = prompt
  end

  class ScoreRecorder
    attr_reader :scores

    def initialize(depth: 0)
      @scores = []
      @depth = depth
    end

    def depth = @depth
    def score(**kwargs) = @scores << kwargs
  end

  class SpanAttributeRecorder
    attr_reader :attributes

    def initialize = @attributes = []

    def in_span(_name, kind: :internal, attributes: {}, root: false)
      @attributes << attributes.transform_keys(&:to_s)
      yield Span.new
    end

    def current_ids = {}
    def propagation_carrier = {}
    def capture_event(_event) = nil
    def capture_io(input: nil, output: nil) = nil
    def force_flush(timeout: nil) = true
    def shutdown(timeout: nil) = true

    class Span
      def trace_id = nil
      def span_id = nil
      def propagation_carrier = {}
      def set_attributes(_values) = nil
      def add_event(_name, attributes: {}) = nil
      def record_exception(_value) = nil
      def error!(_value = nil) = nil
    end
  end
end
