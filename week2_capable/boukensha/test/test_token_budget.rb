require_relative "helper"

# The turn's token budget, and the delegation boundary it has to survive.
#
# The bug: `max_turn_tokens` was compared against `Context#turn_tokens`, and
# `Boukensha.run_task` builds every delegated subagent a fresh `Context`. So a
# subagent spent into a counter its parent never read AND got its own full
# allowance. Across the sessions on disk the player's cap could see as little as
# 15% of what its turn actually spent, and in this project's whole history no
# `max_tokens` limit has ever fired.
#
# The tests that would have caught it are the two marked THE BUG below.
class TestTokenBudget < Minitest::Test
  B = Boukensha::TokenBudget

  # A subagent, as `run_task` builds one: its own Context, its own Agent, run
  # from inside the parent's tool call.
  class Delegate
    def initialize(responses, max_turn_tokens: 60_000)
      @responses = responses
      @max = max_turn_tokens
    end

    def run
      ctx = Boukensha::Context.new(system: "delegate")
      pipe = FakePipe.new(ctx, *@responses)
      agent = Boukensha::Agent.new(context: ctx, registry: Boukensha::Registry.new(ctx),
                                   builder: pipe, client: pipe,
                                   logger: Boukensha::Logger.new(log: nil),
                                   max_turn_tokens: @max)
      @context = ctx
      agent.run
    end

    attr_reader :context
  end

  class FakePipe
    FakeBackend = Struct.new(:model)

    def initialize(context, *responses)
      @context = context
      @responses = responses
    end

    def backend = FakeBackend.new("fake-model")
    def to_api_payload(**_) = {}
    def parse_response(r) = { stop_reason: r["stop_reason"], content: r["content"] }
    def call(**_) = @responses.shift || TestTokenBudget.text("done", 1, 1)
  end

  def self.text(text, input = 10, output = 5)
    { "stop_reason" => "end_turn",
      "usage" => { "input_tokens" => input, "output_tokens" => output },
      "content" => [ { "type" => "text", "text" => text } ] }
  end

  def self.tool_use(name, input = 10, output = 5)
    { "stop_reason" => "tool_use",
      "usage" => { "input_tokens" => input, "output_tokens" => output },
      "content" => [ { "type" => "tool_use", "id" => "u1", "name" => name, "input" => {} } ] }
  end

  # A parent agent whose one tool delegates, exactly as the `explore` tool does.
  def parent_agent(responses:, delegate: nil, max_turn_tokens: 60_000, log: nil)
    ctx = Boukensha::Context.new(system: "parent")
    reg = Boukensha::Registry.new(ctx)
    reg.tool("delegate", description: "d") { |**_| delegate ? delegate.run.to_s : "no-op" }
    pipe = FakePipe.new(ctx, *responses)
    agent = Boukensha::Agent.new(context: ctx, registry: reg, builder: pipe, client: pipe,
                                 logger: Boukensha::Logger.new(log: log),
                                 max_turn_tokens: max_turn_tokens)
    [ agent, ctx ]
  end

  def limits_in(log)
    File.readlines(log).map { |l| JSON.parse(l) }.select { |r| r["phase"] == "limit_reached" }
  end

  def teardown
    Thread.current[B::KEY] = nil
  end

  # --- the ledger itself -----------------------------------------------------

  def test_a_budget_sums_input_and_output
    budget = B.new
    budget.add(10, 5)
    budget.add(3, 2)

    assert_equal 20, budget.spent
  end

  def test_nothing_is_ambient_at_rest
    assert_nil B.current, "a budget outside a turn would leak into the next one"
  end

  def test_with_installs_and_restores
    outer = B.new
    B.with(outer) do
      assert_same outer, B.current
      inner = B.new
      B.with(inner) { assert_same inner, B.current }
      assert_same outer, B.current, "the previous budget has to come back"
    end
    assert_nil B.current
  end

  # The TUI runs a whole turn on a background thread. Two concurrent turns
  # spending from one purse would be worse than not capping at all.
  def test_budgets_do_not_leak_across_threads
    seen = nil
    B.with(B.new) { Thread.new { seen = B.current }.join }

    assert_nil seen
  end

  # --- the agent -------------------------------------------------------------

  def test_a_root_agent_opens_its_own_budget_and_counts_its_own_spend
    agent, ctx = parent_agent(responses: [ self.class.text("done", 100, 20) ])
    agent.run

    assert_equal 120, ctx.turn_tokens
  end

  def test_a_root_agent_resets_between_turns
    agent, ctx = parent_agent(responses: [ self.class.text("one", 100, 20),
                                           self.class.text("two", 7, 3) ])
    agent.run
    agent.run

    assert_equal 10, ctx.turn_tokens, "a new turn starts from zero, not from the last one"
  end

  # THE BUG. The delegate's spend used to land in its own Context and be
  # invisible here; the parent's turn saw only its own two calls.
  def test_a_delegates_spend_lands_in_the_parents_ledger
    delegate = Delegate.new([ self.class.text("explored", 1_000, 500) ])
    agent, ctx = parent_agent(
      responses: [ self.class.tool_use("delegate", 100, 20), self.class.text("done", 100, 20) ],
      delegate: delegate
    )
    agent.run

    assert_equal 1_740, ctx.turn_tokens,
                 "120 + 120 from the parent, 1500 from the delegate — one turn, one total"
  end

  def test_a_delegate_shares_the_very_same_ledger_object
    delegate = Delegate.new([ self.class.text("explored", 1, 1) ])
    agent, ctx = parent_agent(
      responses: [ self.class.tool_use("delegate"), self.class.text("done") ], delegate: delegate
    )
    agent.run

    assert_same ctx.token_budget, delegate.context.token_budget
  end

  # THE OTHER HALF OF THE BUG. `Agent#run` resets the counter at the top of a
  # turn; a delegate doing that would erase everything the parent had spent.
  def test_a_delegate_does_not_reset_what_the_parent_has_already_spent
    delegate = Delegate.new([ self.class.text("explored", 0, 0) ])
    agent, ctx = parent_agent(
      responses: [ self.class.tool_use("delegate", 500, 100), self.class.text("done", 0, 0) ],
      delegate: delegate
    )
    agent.run

    assert_equal 600, ctx.turn_tokens, "the parent's 600 has to survive the delegation"
  end

  # The point of all of it: the ceiling now bounds the TURN. Before this, a
  # delegate's 60k allowance was handed out fresh at every delegation, so the
  # real worst case was max_iterations × max_turn_tokens.
  def test_the_turn_stops_once_parent_and_delegate_together_cross_the_ceiling
    log = File.join(Dir.mktmpdir, "s.jsonl")
    delegate = Delegate.new([ self.class.text("explored", 900, 0) ], max_turn_tokens: 1_000)
    agent, ctx = parent_agent(
      responses: [ self.class.tool_use("delegate", 100, 0),
                   self.class.text("still going", 100, 0),
                   self.class.text("and going", 100, 0) ],
      delegate: delegate, max_turn_tokens: 1_000, log: log
    )
    agent.run

    # 100 from the parent's first call plus 900 from inside the delegation. On
    # its own the parent would have spent 100 and run happily on.
    assert_operator ctx.turn_tokens, :>=, 1_000
    limit = limits_in(log).find { |r| r["kind"] == "max_tokens" }
    refute_nil limit, "the turn has to stop on max_tokens, which has never once " \
                      "fired in this project's real sessions"
    assert_equal 1_000, limit["max"]
  end

  # The delegate is the one that notices first, because it is the one making the
  # call that crosses the line. It winds itself down and hands control back —
  # the parent then trips on its own next check rather than starting more work.
  def test_the_delegate_itself_stops_when_the_shared_total_is_spent
    log = File.join(Dir.mktmpdir, "s.jsonl")
    delegate = Delegate.new([ self.class.text("explored", 900, 0) ], max_turn_tokens: 1_000)
    agent, = parent_agent(
      responses: [ self.class.tool_use("delegate", 999, 0), self.class.text("done", 0, 0) ],
      delegate: delegate, max_turn_tokens: 1_000, log: log
    )
    agent.run

    assert_equal 1, delegate.context.messages.count { |m| m.role == :assistant },
                 "the delegate should wind down immediately, not run its full allowance"
  end

  # A delegate run on its own — no parent, no ambient budget — must behave
  # exactly as it did before any of this existed.
  def test_a_delegate_run_standalone_owns_its_own_budget
    delegate = Delegate.new([ self.class.text("explored", 40, 10) ])
    delegate.run

    assert_equal 50, delegate.context.turn_tokens
    assert_nil B.current, "and it cleans up after itself"
  end
end
