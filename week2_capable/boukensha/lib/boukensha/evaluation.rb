require_relative "evaluation/assertions"
require_relative "evaluation/result"
require_relative "evaluation/scenario"
require_relative "evaluation/scorer"
require_relative "evaluation/transcript_driver"
require_relative "evaluation/runner"

module Boukensha
  # Deterministic scenario evaluation.
  #
  # Evaluate behaviour by what was RECORDED, never by what a model said about
  # it. A scenario declares a small world, a scripted MUD, an action and a set
  # of assertions; the runner drives the real hooks against it offline and
  # scores the outcome from the store, the journal and the navigator's own
  # result hash. No live MUD, no API calls, no judge.
  #
  #   Boukensha::Evaluation.run("scenarios/navigation/known_route.yaml")
  #
  # NOT required by `boukensha.rb`, on purpose: this is a development tool, and
  # the agent's boot path should not pay for it. Require it explicitly.
  module Evaluation
    def self.run(path) = Runner.run(path)

    # Every `*.yaml` under a directory, sorted, so a suite has a stable order.
    def self.scenarios_in(dir) = Dir[File.join(dir, "**", "*.yaml")].sort
  end
end
