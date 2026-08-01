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

  def with_fake_client
    original = Boukensha::Client.method(:new)
    fake     = FakeClient.new
    Boukensha::Client.define_singleton_method(:new) { |*| fake }
    yield
  ensure
    Boukensha::Client.singleton_class.send(:define_method, :new, original)
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
