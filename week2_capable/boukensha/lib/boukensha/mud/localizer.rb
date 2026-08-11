module Boukensha
  module Mud
    # Candidate-set localization (week_2_plan Phase 6). Scores known rooms
    # against a fresh observation; identity stays `rooms.id`, never a guess.
    #
    # Default weights match the architecture review: title / exits / features /
    # commanded transition. A transition match is decisive when present — it is
    # the only signal that encodes "we walked HERE from THERE".
    class Localizer
      DEFAULT_WEIGHTS = {
        title: 0.35,
        exits: 0.30,
        feature: 0.20,
        transition: 0.15
      }.freeze

      # Observation is a duck-typed look: `#name`, `#description`, `#exit_dirs`.
      # `from_id`/`direction` are the commanded transition, when known.
      # `exit_targets` is optional `{ "north" => "The Temple", … }` from check(exits).
      def initialize(store, weights: DEFAULT_WEIGHTS)
        @store   = store
        @weights = DEFAULT_WEIGHTS.merge(weights.transform_keys(&:to_sym))
      end

      # Returns `{ room_id => score }` sorted high→low. Empty when there are no
      # candidates to score (caller should discover a new room).
      def score(observation, candidates:, from_id: nil, direction: nil, exit_targets: {})
        return {} if candidates.nil? || candidates.empty?

        candidates.each_with_object({}) do |room, out|
          out[room[:id]] = score_one(observation, room,
                                     from_id: from_id, direction: direction,
                                     exit_targets: exit_targets)
        end.sort_by { |_id, s| -s }.to_h
      end

      # Best room id when one candidate clearly wins; otherwise nil (ambiguous).
      # `margin` is the minimum lead the winner must hold over second place.
      def pick(scores, margin: 0.08)
        return nil if scores.nil? || scores.empty?
        return scores.keys.first if scores.size == 1

        ranked = scores.sort_by { |_id, s| -s }
        best_id, best = ranked[0]
        _second_id, second = ranked[1]
        (best - second) >= margin ? best_id : nil
      end

      private

      def score_one(observation, room, from_id:, direction:, exit_targets:)
        w = @weights
        total = 0.0
        total += w[:title] * title_match(observation, room)
        total += w[:exits] * exits_match(observation, room, exit_targets)
        total += w[:feature] * feature_match(observation, room)
        total += w[:transition] * transition_match(room, from_id, direction)
        total
      end

      def title_match(observation, room)
        a = observation.name.to_s.strip.downcase
        b = room[:name].to_s.strip.downcase
        return 1.0 if a == b
        return 0.5 if !a.empty? && (a.include?(b) || b.include?(a))

        0.0
      end

      def exits_match(observation, room, exit_targets)
        observed = Array(observation.exit_dirs).map(&:to_s).sort
        stored   = @store.exits_for(room[:id]).map { |e| e[:direction].to_s }.sort
        return 0.0 if observed.empty? && stored.empty?
        return 0.0 if observed.empty? || stored.empty?

        overlap = (observed & stored).size
        union   = (observed | stored).size
        base    = union.zero? ? 0.0 : overlap.to_f / union

        # Destination names from check(exits) settle almost every maze case.
        unless exit_targets.nil? || exit_targets.empty?
          named = 0
          checked = 0
          exit_targets.each do |dir, name|
            next if name.to_s.empty?

            checked += 1
            edge = @store.exit_at(room[:id], dir)
            named += 1 if edge && edge[:target_name].to_s.casecmp?(name.to_s)
          end
          return (base + (checked.zero? ? 0.0 : named.to_f / checked)) / 2.0
        end

        base
      end

      def feature_match(observation, room)
        a = observation.description.to_s.downcase.split(/\W+/).reject { |t| t.length < 4 }
        b = room[:description].to_s.downcase.split(/\W+/).reject { |t| t.length < 4 }
        return 0.0 if a.empty? || b.empty?

        overlap = (a & b).size
        overlap.to_f / [a.size, b.size].max
      end

      def transition_match(room, from_id, direction)
        return 0.0 unless from_id && direction

        known = @store.exit_at(from_id, direction)
        return 0.0 unless known && known[:target_room_id]

        known[:target_room_id] == room[:id] ? 1.0 : 0.0
      end
    end
  end
end
