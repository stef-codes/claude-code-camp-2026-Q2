require_relative "base"

module Boukensha
  module Tasks
    # Frontier exploration subagent. The player delegates open-ended "find X" /
    # "map N rooms" briefs here via the native `explore` tool; it may walk
    # unknown exits under its own allowlist. The parent never picks a travel
    # direction itself.
    class Explorer < Base
      def self.task_name = "explorer"
    end
  end
end
