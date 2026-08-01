module Boukensha
  module Mud
    # Active relocalization helper (week_2_plan Phase 8.1). Given several
    # candidate rooms, pick the walkable command whose predicted destinations
    # diverge most — so one move collapses the candidate set furthest.
    class Disambiguator
      # Keep in sync with RouteFinder::WALKABLE / the daemon's move enum.
      WALKABLE = %w[north east south west up down].freeze

      def initialize(store)
        @store = store
      end

      # `candidate_ids` — room ids still in play.
      # Returns `{ direction:, outcomes: { room_id => target_id_or_nil }, divergence: Integer }`
      # or nil when no candidate has a walkable exit that distinguishes them.
      def choose_disambiguating_action(candidate_ids)
        ids = Array(candidate_ids).map(&:to_i).uniq
        return nil if ids.size < 2

        best = nil
        WALKABLE.each do |direction|
          outcomes = {}
          ids.each do |id|
            edge = @store.exit_at(id, direction)
            outcomes[id] = edge && edge[:target_room_id]
          end
          # Divergence = distinct predicted destinations among candidates that
          # actually have this exit. Unknown/frontier (nil target) still counts
          # as a distinct outcome bucket when some candidates lack the exit.
          present = outcomes.select { |_id, target| !target.nil? || @store.exit_at(_id, direction) }
          next if present.size < 2

          buckets = present.values.uniq
          divergence = buckets.size
          next if divergence < 2

          candidate = { direction: direction, outcomes: outcomes, divergence: divergence }
          best = candidate if best.nil? || divergence > best[:divergence] ||
                              (divergence == best[:divergence] && direction < best[:direction])
        end
        best
      end

      # Human-readable shortlist for a Relocalizer brief.
      def suggest_actions(candidate_ids, limit: 3)
        ids = Array(candidate_ids).map(&:to_i).uniq
        ranked = WALKABLE.filter_map do |direction|
          outcomes = ids.to_h { |id| [id, @store.exit_at(id, direction)&.dig(:target_room_id)] }
          present  = outcomes.select { |id, _| @store.exit_at(id, direction) }
          next if present.size < 2

          buckets = present.values.uniq
          next if buckets.size < 2

          { direction: direction, divergence: buckets.size, outcomes: outcomes }
        end
        ranked.sort_by { |a| [-a[:divergence], a[:direction]] }.first(limit)
      end
    end
  end
end
