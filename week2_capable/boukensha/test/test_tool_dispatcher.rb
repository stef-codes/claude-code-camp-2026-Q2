require_relative "helper"

# Regression coverage for the bug that made every lifecycle hook a silent no-op
# in the only configuration that matters: a real REPL.
#
# `Boukensha.tool_dispatcher` builds a `body` lambda and uses it two ways —
# called directly when there is no logger, and passed as a BLOCK to
# `Logger#operation` when there is. That method does `yield frame`, with one
# argument, and a lambda enforces its arity even as a block. So a
# zero-parameter `body` raised
#
#   ArgumentError: wrong number of arguments (given 1, expected 0)
#
# on every logger-backed call. `Mud::Hooks#guard` catches it and writes one
# line to stderr, so nothing crashed: the room survey, the cold `look`, the
# score refresh and position tracking simply never happened, and the agent
# played the MUD with a permanently empty map.
#
# It survived a green suite and a live end-to-end run because BOTH took the
# other branch — tests and verification scripts build dispatchers without a
# logger. Which is exactly why the tests below pass one.
class TestToolDispatcher < Minitest::Test
  include McpTestHelper

  def setup
    Boukensha.reset_mcp_clients!
    @fake = start_fake_mud
  end

  def teardown
    @fake&.stop
    Boukensha.reset_mcp_clients!
  end

  def dispatcher_yaml
    <<~YAML
      tasks:
        player:
          allow:
            - tbamud__poll
      tools:
        probe:
          allow:
            - poll
            - "check(kind: score)"
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

  # THE regression test. Without the optional parameter on `body` this raises.
  def test_a_dispatcher_with_a_logger_can_actually_call_a_tool
    config_from(dispatcher_yaml) do |cfg|
      Dir.mktmpdir do |dir|
        logger = Boukensha::Logger.new(session_id: "test", log: File.join(dir, "s.jsonl"))
        call = Boukensha.tool_dispatcher("probe", logger: logger, initiator: "hook")

        result = call.call("tbamud__check", kind: "score")

        refute_nil result
        assert_kind_of String, result
      ensure
        logger&.close
      end
    end
  end

  # The branch that always worked, kept so a fix to the one above cannot be
  # made by breaking this one instead.
  def test_a_dispatcher_without_a_logger_still_calls_a_tool
    config_from(dispatcher_yaml) do |cfg|
      call = Boukensha.tool_dispatcher("probe", initiator: "hook")

      assert_kind_of String, call.call("tbamud__check", kind: "score")
    end
  end

  # The logger path must also still LOG — a fix that satisfied the arity by
  # bypassing Logger#operation would pass the first test and lose the
  # per-tool spans the monitor's session view is built on.
  def test_the_logger_path_records_the_call_inside_an_operation
    config_from(dispatcher_yaml) do |cfg|
      Dir.mktmpdir do |dir|
        path = File.join(dir, "s.jsonl")
        logger = Boukensha::Logger.new(session_id: "test", log: path)
        Boukensha.tool_dispatcher("probe", logger: logger, initiator: "hook")
                 .call("tbamud__check", kind: "score")
        logger.close

        records = File.readlines(path).map { |l| JSON.parse(l) }
        phases  = records.map { |r| r["phase"] }

        assert_includes phases, "operation_start"
        assert_includes phases, "tool_call"
        assert_includes phases, "tool_result"

        call = records.find { |r| r["phase"] == "tool_call" }
        assert_equal "hook", call["initiator"],
                     "the whole point of the dispatcher: this call was not chosen by the model"
      end
    end
  end
end
