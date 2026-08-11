require_relative "helper"
require "json"

# Product subagents (Explorer / Relocalizer) must append to the caller's session
# file when invoked via Boukensha.run_task — the same Amendment A contract
# test_delegated_session.rb covers for the historical room_inspector name.
class TestProductSubagents < Minitest::Test
  include McpTestHelper

  SETTINGS = <<~YAML
    tasks:
      explorer:
        provider: anthropic
        model: claude-haiku-4-5
        max_iterations: 4
        max_output_tokens: 256
        allow: []
      relocalizer:
        provider: anthropic
        model: claude-haiku-4-5
        max_iterations: 3
        max_output_tokens: 256
        allow: []
      player:
        provider: anthropic
        model: claude-haiku-4-5
        allow:
          - explore
          - relocalize
          - navigate
  YAML

  def teardown
    @fake&.stop
    Boukensha.reset_mcp_clients!
  end

  def test_explorer_run_task_nests_in_borrowed_logger
    assert_nested_task(Boukensha::Tasks::Explorer, "explorer", "map until bakery")
  end

  def test_relocalizer_run_task_nests_in_borrowed_logger
    assert_nested_task(Boukensha::Tasks::Relocalizer, "relocalizer", "disambiguate")
  end

  def test_player_allowlist_rejects_travel_move
    config_from(SETTINGS) do |cfg|
      perms = Boukensha.task_permissions(cfg, "player")
      refute perms.allow_tool?("tbamud__move"),
             "player must not travel via raw move"
      assert perms.allow_tool?("explore")
      assert perms.allow_tool?("relocalize")
      assert perms.allow_tool?("navigate")
    end
  end

  # ---------- the delegation boundary ------------------------------------

  # THE regression test, and the assertion whose absence let the bug ship.
  #
  # `run_task` used to build its Agent with no hooks, so a delegated subagent
  # could act on the world with none of it observed. For the Explorer — whose
  # entire job is to expand the map — that meant `after_tool` never fired,
  # `Hooks#movement_outcome` never ran, and a 30-move walk through 12 rooms
  # recorded exactly one. `before_model` never fired either, so it never got the
  # state block its own prompt tells it to follow the `?` frontier in: it walked
  # blind AND forgot, and because position never advanced, the next brief
  # re-planned from the same stale room and retraced the same street.
  #
  # The tests that existed covered logger nesting and the allowlist — both
  # perfectly green while the subagent's work went in the bin.
  def test_a_delegated_subagent_fires_hooks_for_its_own_tool_calls
    @fake = start_fake_mud
    spy = HookSpy.new

    with_settings(delegating_settings) do
      with_fake_client(FakeToolClient.new("tbamud__poll")) do
        Boukensha.run_task(Boukensha::Tasks::Explorer, "expand the map",
                           hooks: spy)
      end
    end

    assert_includes spy.fired, :after_tool,
                    "a subagent's tool call must reach the hooks — this is how a walk becomes a map"
    assert_equal ["tbamud__poll"], spy.tools_seen
    assert_includes spy.fired, :before_model,
                    "before_model is what hands the subagent its state block"
    assert_includes spy.fired, :before_tools
    assert_includes spy.fired, :before_turn
  end

  # The default path stays hookless, so every existing caller and test is
  # unchanged by the new parameter.
  def test_run_task_without_hooks_still_runs
    @fake = start_fake_mud

    result = with_settings(delegating_settings) do
      with_fake_client(FakeToolClient.new("tbamud__poll")) do
        Boukensha.run_task(Boukensha::Tasks::Explorer, "expand the map")
      end
    end

    assert_equal "done", result
  end

  # Hooks are per-INSTANCE state — position lives on them — so the delegation
  # must hand over the caller's own object rather than an equivalent one.
  # Passing a copy would leave the parent believing the character never moved,
  # which is the same failure by a different route.
  def test_the_subagent_receives_the_very_same_hooks_instance
    @fake = start_fake_mud
    spy = HookSpy.new

    with_settings(delegating_settings) do
      with_fake_client(FakeToolClient.new("tbamud__poll")) do
        Boukensha.run_task(Boukensha::Tasks::Explorer, "expand the map", hooks: spy)
      end
    end

    assert_equal [spy.object_id], spy.instances_seen.uniq
  end

  def test_task_default_prompts_resolve_per_task
    explorer = Boukensha::Tasks::Explorer.system_prompt(
      {}, default_prompts_dir: Boukensha::Config::PROMPTS_DIR
    )
    reloc = Boukensha::Tasks::Relocalizer.system_prompt(
      {}, default_prompts_dir: Boukensha::Config::PROMPTS_DIR
    )
    refute_nil explorer
    refute_nil reloc
    assert_includes explorer, "Explorer"
    assert_includes reloc, "Relocalizer"
  end

  private

  def assert_nested_task(task_class, task_name, input)
    Dir.mktmpdir do |dir|
      path   = File.join(dir, "session.jsonl")
      parent = Boukensha::Logger.new(session_id: "parent", log: path, task: "player")
      parent.turn(n: 0)

      result = with_settings(SETTINGS) do
        with_fake_client do
          Boukensha.run_task(task_class, input, logger: parent)
        end
      end
      assert_equal "{}", result

      parent.turn(n: 1)
      parent.close

      assert_equal ["session.jsonl"], Dir.children(dir).sort
      events = File.readlines(path).map { |l| JSON.parse(l) }
      phases = events.map { |e| e["phase"] }

      assert_equal 1, phases.count("session_start")
      assert_equal 1, phases.count("task_start")
      assert_equal 1, phases.count("task_end")

      sub = events.select { |e| e["task"] == task_name }
      assert_includes sub.map { |e| e["phase"] }, "response"
      assert_equal [1], sub.map { |e| e["depth"] }.uniq
      assert_equal ["player", 0], [events.last["task"], events.last["depth"]]
    end
  end

  def with_fake_client(fake = FakeClient.new)
    original = Boukensha::Client.method(:new)
    Boukensha::Client.define_singleton_method(:new) { |*| fake }
    yield
  ensure
    Boukensha::Client.singleton_class.send(:define_method, :new, original)
  end

  # The Explorer needs a real tool to call, so this grants it one and points the
  # daemon at the FakeMud socket the test spun up.
  def delegating_settings
    <<~YAML
      tasks:
        explorer:
          provider: anthropic
          model: claude-haiku-4-5
          max_iterations: 4
          max_output_tokens: 256
          allow:
            - poll
      mcp_servers:
        mud:
          command: #{mud_manager_command}
          args:    #{mud_manager_args.inspect}
          prefix:  tbamud
          env:
            MUD_HOST:     127.0.0.1
            MUD_PORT:     #{@fake.port}
            MUD_NAME:     Gandalf
            MUD_PASSWORD: secret
    YAML
  end

  # Records which of the five seam points fired, and which context object each
  # was handed — the subagent has its own Context, so this also proves the hooks
  # are operating on the delegate's turn and not the parent's.
  class HookSpy < Boukensha::Hooks
    attr_reader :fired, :tools_seen, :instances_seen

    def initialize
      @fired = []
      @tools_seen = []
      @instances_seen = []
    end

    def before_turn(context:)  = note(:before_turn)
    def before_model(context:) = note(:before_model)
    def before_tools(calls:, context:) = note(:before_tools)
    def after_turn(context:, text:)    = note(:after_turn)

    def after_tool(name:, args:, result:, context:)
      @tools_seen << name
      note(:after_tool)
    end

    private

    def note(phase)
      @fired << phase
      @instances_seen << object_id
      nil
    end
  end

  # One tool-use round, then stop — the smallest response pair that drives the
  # agent loop all the way through dispatch.
  class FakeToolClient
    def initialize(tool_name)
      @tool_name = tool_name
      @calls = 0
    end

    def call(**_opts)
      @calls += 1
      return end_turn if @calls > 1

      {
        "content" => [{ "type" => "tool_use", "id" => "tu_1",
                        "name" => @tool_name, "input" => {} }],
        "stop_reason" => "tool_use",
        "usage" => { "input_tokens" => 10, "output_tokens" => 5 }
      }
    end

    private

    def end_turn
      {
        "content" => [{ "type" => "text", "text" => "done" }],
        "stop_reason" => "end_turn",
        "usage" => { "input_tokens" => 10, "output_tokens" => 2 }
      }
    end
  end

  def with_settings(yaml)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "settings.yaml"), yaml)
      old = ENV["BOUKENSHA_DIR"]
      ENV["BOUKENSHA_DIR"] = dir
      Boukensha.instance_variable_set(:@config, nil)
      Boukensha.reset_mcp_clients!
      begin
        yield
      ensure
        old.nil? ? ENV.delete("BOUKENSHA_DIR") : ENV["BOUKENSHA_DIR"] = old
        Boukensha.instance_variable_set(:@config, nil)
        Boukensha.reset_mcp_clients!
      end
    end
  end

  class FakeClient
    def call(**_opts)
      {
        "content" => [{ "type" => "text", "text" => "{}" }],
        "stop_reason" => "end_turn",
        "usage" => { "input_tokens" => 12, "output_tokens" => 3 }
      }
    end
  end
end
