module Boukensha
  module Mud
    # Explicit agent mode — week_2_plan Phase 9. Hooks owns the current value;
    # composites and native tools read it to decide whether travel, explore, or
    # relocalize is the right next action.
    module Mode
      LOCALIZING    = :localizing
      NAVIGATING    = :navigating
      EXPLORING     = :exploring
      RELOCALIZING  = :relocalizing
      COMBAT        = :combat

      ALL = [LOCALIZING, NAVIGATING, EXPLORING, RELOCALIZING, COMBAT].freeze

      module_function

      def coerce(value)
        sym = value.to_s.to_sym
        ALL.include?(sym) ? sym : NAVIGATING
      end
    end
  end
end
