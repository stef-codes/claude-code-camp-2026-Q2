module Boukensha
  # What a TURN cost, across every agent that ran inside it.
  #
  # The bug this exists to fix: `max_turn_tokens` was compared against
  # `Context#turn_tokens`, and `run_task` gives every delegated subagent a fresh
  # `Context` — so an `explore` spent its tokens into a counter the player never
  # read, AND got its own full allowance. Measured across the sessions on disk,
  # the player's cap could see as little as 15% of what its turn actually spent,
  # and no `max_tokens` limit has ever fired in this project's history. The
  # ceiling was not 60,000 tokens; it was 60,000 per agent, times however many
  # subagents the turn chose to start.
  #
  # So the ledger is the turn's property rather than any one agent's. It is
  # AMBIENT, following `Boukensha::Operation` — the same reason that class is
  # ambient applies here: the delegation boundary is `Boukensha.run_task`, and
  # every caller between the player's tool block and the subagent's Agent would
  # otherwise have to thread a budget through purely to pass it on. An ambient
  # ledger also covers delegation paths nobody has written yet, which a
  # hand-threaded parameter would silently miss.
  #
  # Thread-local, not global: the TUI runs a whole turn on a background thread,
  # and two concurrent turns must not spend from one purse.
  class TokenBudget
    KEY = :boukensha_token_budget

    # The budget of the turn currently in progress, or nil at rest — which is
    # exactly the test for "am I the root agent or a delegate".
    def self.current = Thread.current[KEY]

    # Install for the duration of a turn, restoring whatever was there. Nested
    # calls with the SAME budget are harmless no-ops, which is what lets an
    # agent open its turn without caring whether it is root or delegate.
    def self.with(budget)
      previous = Thread.current[KEY]
      Thread.current[KEY] = budget
      yield budget
    ensure
      Thread.current[KEY] = previous
    end

    def initialize
      @spent = 0
      @mutex = Mutex.new
    end

    def spent = @mutex.synchronize { @spent }

    def add(input, output)
      @mutex.synchronize { @spent += input.to_i + output.to_i }
    end

    def reset = @mutex.synchronize { @spent = 0 }
  end
end
