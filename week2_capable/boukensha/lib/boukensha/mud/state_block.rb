require_relative "room_parser"

module Boukensha
  module Mud
    # What the model is shown about where it is.
    #
    # This is not the room record. The record is five tables; this is four lines,
    # and the gap between them is the point — the model does not need the room's
    # first_seen_at, its fingerprints, or its prose for the fourth time.
    #
    #   [here] Market Square  (visit 2)
    #   exits: north→The Temple Square ✓ | east→Main Street ✓ | south→The Common Square ✓ | west→Main Street ?
    #   here: a cityguard (mob — "you could take him")
    #   you: 20/20hp 100mana 81mv · lvl 1 · 43 gold · standing
    #
    # Measured against what it replaces: the old `inspect_room` payload was ~230
    # tokens and PERMANENT (a tool_result, re-sent on every later call, once per
    # visit). This is ~45 tokens, transient, and there is only ever one copy.
    module StateBlock
      HEADER = "[here]".freeze

      module_function

      # `room`      — the rooms row (Hash), or nil if we genuinely don't know.
      # `exits`     — room_exits rows, in display order.
      # `here`      — live entity lines: [{ desc:, count:, kind:, threat:, threat_fresh:, encounters: }]
      # `player`    — the player_state row.
      # `events`    — lines from this iteration's poll. Rendered only if non-empty.
      # `first_visit` — send the prose once, and never again.
      # `candidates`  — look_candidates, only while the room is unexamined.
      # `ambiguity`   — how many rooms this could be, when it is more than one.
      # `dark`        — last look/move was pitch black; room is not established.
      # `last_known`  — optional hint from player_state (not live position):
      #                 { room_name:, room_id:, from_name:, from_id:, direction: }
      def render(room:, exits: [], here: [], player: {}, events: [], first_visit: false,
                 candidates: nil, ambiguity: nil, mode: nil, location_candidates: nil,
                 dark: false, last_known: nil)
        return nil if room.nil? && player.to_h.empty? && events.empty? && !dark

        lines = []
        lines << location_line(room, ambiguity, mode, dark: dark)
        lines << last_known_line(last_known) if dark && last_known
        lines << "  #{room[:description]}" if first_visit && room && !room[:description].to_s.empty?
        lines << exits_line(exits) if exits && !exits.empty?
        lines << here_line(here)   if here  && !here.empty?
        lines << candidates_line(candidates) if candidates && !candidates.empty?
        lines << scored_candidates_line(location_candidates) if location_candidates && !location_candidates.empty?
        lines << you_line(player)  if player && !player.to_h.empty?
        lines << events_line(events) if events && !events.empty?
        lines.compact.join("\n")
      end

      def location_line(room, ambiguity, mode = nil, dark: false)
        if dark && room.nil?
          return "#{HEADER} DARK — cannot see the room"
        end
        return "#{HEADER} (unknown — no room established yet)" if room.nil?

        parts = ["#{HEADER} #{room[:name]}"]
        visits = room[:visit_count].to_i
        parts << "(visit #{visits})" if visits > 1
        # A model told its location is ambiguous can act sensibly — walk a step
        # and look again. A model told a confident lie cannot.
        parts << "(uncertain — #{ambiguity} candidates)" if ambiguity.to_i > 1
        parts << "[#{mode}]" if mode && mode.to_sym != :navigating
        parts.join("  ")
      end

      # Hints from a previous process / last confirmed arrival — never claimed
      # as where the agent is standing right now.
      def last_known_line(info)
        info = info.transform_keys(&:to_sym)
        room = [info[:room_name], info[:room_id] && "(##{info[:room_id]})"].compact.join(" ")
        return "last known: #{room}" if info[:direction].to_s.empty? || info[:from_id].nil?

        from = [info[:from_name], "(##{info[:from_id]})"].compact.join(" ")
        "last known: #{room} · arrived #{info[:direction]} from #{from}"
      end

      # The one glyph that is genuinely new information: `✓` is a destination the
      # agent has stood in, `?` is the exploration frontier. Today it cannot tell
      # "east, which I've mapped" from "east, unknown" at all.
      #
      # Directions render in FULL, and that is the whole of the fix for the `d`
      # failure: this line used to abbreviate to match the MUD's own
      # `[ Exits: n e s w ]`, but the model reads it as a menu and copies a
      # value straight into `move.direction` — whose schema accepts only
      # north/east/south/west/up/down. One session lost an iteration to
      # `move(direction: "d")` for exactly that reason. The state block and the
      # tool schema now speak one grammar; the few extra tokens per refresh buy
      # back a failed round trip. Loosening the schema instead was rejected —
      # one canonical spelling is what keeps policy pinning, validation, memory
      # keys and logs consistent with each other.
      def exits_line(exits)
        rendered = exits.map do |e|
          dir  = e[:direction].to_s
          name = e[:target_name]
          mark = e[:target_room_id] ? "✓" : "?"
          name ? "#{dir}→#{name} #{mark}" : "#{dir} #{mark}"
        end
        "exits: #{rendered.join(' | ')}"
      end

      # From the LIVE parse plus the latest poll — never from entity_sightings.
      # Rendering presence from stored sightings would report the cityguard that
      # "The cityguard leaves east" just removed, which is the single worst
      # failure mode this design can have. The store contributes only judgement:
      # the remembered threat, and only while it was measured at the level the
      # player is still on.
      def here_line(here)
        rendered = here.map do |e|
          bits = []
          bits << e[:kind] if e[:kind]
          bits << "\"#{e[:threat]}\"" if e[:threat] && e[:threat_fresh]
          bits << "threat unknown at this level" if e[:threat] && !e[:threat_fresh]
          bits << e[:encounters] if e[:encounters]
          label = e[:count].to_i > 1 ? "#{e[:desc]} ×#{e[:count]}" : e[:desc]
          bits.empty? ? label : "#{label} (#{bits.join(' — ')})"
        end
        "here: #{rendered.join(' | ')}"
      end

      def candidates_line(candidates)
        "worth a look: #{Array(candidates).join(', ')}"
      end

      def scored_candidates_line(scores)
        ranked = scores.sort_by { |_id, s| -s }.first(5)
        rendered = ranked.map { |id, s| "##{id}=#{format('%.2f', s)}" }
        "candidates: #{rendered.join(' | ')} — call relocalize if still uncertain"
      end

      # Vitals cluster (they are read together and change together); everything
      # slower-moving is separated out.
      def you_line(p)
        vitals = []
        vitals << (p[:max_hp] ? "#{p[:hp]}/#{p[:max_hp]}hp" : "#{p[:hp]}hp") if p[:hp]
        vitals << "#{p[:mana]}mana" if p[:mana]
        vitals << "#{p[:move]}mv"   if p[:move]

        bits = []
        bits << vitals.join(" ") unless vitals.empty?
        bits << "lvl #{p[:level]}" if p[:level]
        bits << "#{p[:gold]} gold" if p[:gold]
        bits << p[:position] if p[:position]
        bits.empty? ? nil : "you: #{bits.join(' · ')}"
      end

      # True for one instant, so they ride in the block for exactly the iteration
      # they happened in and are never written to a table the agent later reads
      # as fact.
      def events_line(events)
        "just now: #{Array(events).join(' ')}"
      end

      # Every direction this block may print, spelled the way `move.direction`
      # accepts it. Exported so a test can assert the two vocabularies have not
      # drifted apart again.
      DIRECTIONS = RoomParser::DIRECTIONS.values.freeze
    end
  end
end
