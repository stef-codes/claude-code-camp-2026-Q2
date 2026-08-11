require_relative "base"

module Boukensha
  module Tasks
    # Active relocalization subagent. Invoked when Hooks reports an ambiguous
    # position; the brief includes a scripted shortlist of disambiguating moves
    # so this agent picks among options rather than inventing a route.
    class Relocalizer < Base
      def self.task_name = "relocalizer"
    end
  end
end
