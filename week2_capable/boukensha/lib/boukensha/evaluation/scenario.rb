require "yaml"
require "json"
require_relative "assertions"

module Boukensha
  module Evaluation
    # A scenario is a question about behaviour, written down.
    #
    # Everything here is declarative and every field is checked BEFORE anything
    # runs. That ordering is the whole point of a separate class: a scenario
    # with a typo in an assertion name must fail as a scenario problem (exit 2),
    # never as an agent problem (exit 1). A framework that quietly ignores an
    # assertion it does not recognise reports green for a case it never checked,
    # which is worse than having no framework at all.
    class Scenario
      class Invalid < StandardError; end

      # Bumped when the format changes in a way that would silently
      # mis-interpret an older file. An unknown version is refused rather than
      # guessed at.
      SUPPORTED_VERSIONS = [ 1 ].freeze

      DIRECTIONS = %w[north east south west up down].freeze

      # tbaMUD writes the autoexit line abbreviated, and RoomParser expands it
      # back out. Rendering it the short way keeps fixtures looking like the
      # thing they stand in for.
      ABBREV = { "north" => "n", "east" => "e", "south" => "s",
                 "west" => "w", "up" => "u", "down" => "d" }.freeze

      # A room in the scenario's world, and the MUD text that describes it.
      #
      # ONE declaration produces both the memory the agent starts with and the
      # text the MUD replies with, which is what removes an entire class of
      # fixture bug: a room seeded with one description and described with
      # another gets a different weak fingerprint, the agent fails to recognise
      # a room it has "already visited", and the scenario fails for a reason
      # that has nothing to do with the code under test.
      Room = Struct.new(:name, :description, :exits, keyword_init: true) do
        def text
          dirs = Array(exits).map { |d| ABBREV[d] || d }.join(" ")
          "\e[0;33m#{name}\e[0m\r\n   #{description}\r\n" \
            "\e[0;36m[ Exits: #{dirs} ]\e[0m\r\n\r\n100H 100M 100V > "
        end
      end

      Edge = Struct.new(:from, :direction, :to, keyword_init: true)

      attr_reader :id, :description, :path, :rooms, :edges, :frontier, :start, :action,
                  :assertions, :required, :recovery, :expected_steps,
                  :max_commands, :max_replans, :responses

      def self.load(path)
        raw = File.read(path)
        data = YAML.safe_load(raw, permitted_classes: [], aliases: false)
        raise Invalid, "#{path}: not a YAML mapping" unless data.is_a?(Hash)

        new(data, path: path)
      rescue Errno::ENOENT
        raise Invalid, "#{path}: no such scenario"
      rescue Psych::SyntaxError => e
        raise Invalid, "#{path}: malformed YAML — #{e.message}"
      end

      def initialize(data, path: nil)
        @path = path
        @data = stringify(data)

        check_version!
        @id          = required_field("id")
        @description = @data["description"].to_s
        load_world!
        load_action!
        load_limits!
        load_assertions!
        load_scoring!
        load_transcript!
      end

      def rooms_by_name = @rooms_by_name

      def room!(name)
        @rooms_by_name[name.to_s] or
          raise Invalid, "#{@id}: no room called #{name.inspect} in initial_state.rooms"
      end

      def to_h = { id: @id, description: @description, path: @path }

      private

      def check_version!
        version = @data["version"]
        return if SUPPORTED_VERSIONS.include?(version)

        raise Invalid, "unsupported scenario version #{version.inspect} " \
                       "(this build understands #{SUPPORTED_VERSIONS.join(', ')})"
      end

      def load_world!
        state = @data["initial_state"]
        raise Invalid, "#{@id}: initial_state is required" unless state.is_a?(Hash)

        declared = state["rooms"]
        raise Invalid, "#{@id}: initial_state.rooms must be a list" unless declared.is_a?(Array) && declared.any?

        @rooms = declared.each_with_index.map { |room, i| build_room(room, i) }
        @rooms_by_name = @rooms.to_h { |r| [ r.name, r ] }
        if @rooms_by_name.size != @rooms.size
          raise Invalid, "#{@id}: two rooms share a name; scenarios address rooms by name"
        end

        @edges = Array(state["edges"]).map { |edge| build_edge(edge) }
        # Named unwalked exits. `to` may be a room that exists (island: same
        # name, no walked path) or a name not yet visited — only `from` must
        # be a declared room, and the direction must appear on its exits line.
        @frontier = Array(state["frontier"]).map { |edge| build_frontier(edge) }
        @start = state["start"].to_s
        room!(@start)
      end

      def build_room(room, index)
        raise Invalid, "#{@id}: initial_state.rooms[#{index}] must be a mapping" unless room.is_a?(Hash)

        name = room["name"].to_s
        raise Invalid, "#{@id}: initial_state.rooms[#{index}] has no name" if name.empty?

        exits = Array(room["exits"]).map(&:to_s)
        unknown = exits - DIRECTIONS
        raise Invalid, "#{@id}: room #{name.inspect} has unknown exits #{unknown.inspect}" if unknown.any?

        Room.new(name: name, exits: exits,
                 description: room["description"].to_s.empty? ? "Prose about #{name}." : room["description"].to_s)
      end

      # Accepts either the terse list form `[A, north, B]` or the mapping form.
      def build_edge(edge)
        from, direction, to = edge.is_a?(Array) ? edge : edge.values_at("from", "direction", "to")
        e = Edge.new(from: from.to_s, direction: direction.to_s, to: to.to_s)
        raise Invalid, "#{@id}: edge #{edge.inspect} has an unknown direction" unless DIRECTIONS.include?(e.direction)

        room!(e.from)
        room!(e.to)
        # An edge the room does not list as an exit would be unreachable in the
        # real world and unroutable here — catch it now rather than as a
        # mysterious :no_route three layers down.
        unless room!(e.from).exits.include?(e.direction)
          raise Invalid, "#{@id}: edge #{e.from} #{e.direction} #{e.to} — " \
                         "#{e.from.inspect} does not list #{e.direction} among its exits"
        end
        e
      end

      def build_frontier(edge)
        from, direction, to = edge.is_a?(Array) ? edge : edge.values_at("from", "direction", "to")
        e = Edge.new(from: from.to_s, direction: direction.to_s, to: to.to_s)
        raise Invalid, "#{@id}: frontier #{edge.inspect} has an unknown direction" unless DIRECTIONS.include?(e.direction)
        raise Invalid, "#{@id}: frontier #{edge.inspect} has no target name" if e.to.empty?

        room!(e.from)
        unless room!(e.from).exits.include?(e.direction)
          raise Invalid, "#{@id}: frontier #{e.from} #{e.direction} → #{e.to} — " \
                         "#{e.from.inspect} does not list #{e.direction} among its exits"
        end
        e
      end

      def load_action!
        action = @data["action"]
        raise Invalid, "#{@id}: action is required" unless action.is_a?(Hash)

        type = action["type"].to_s
        unless Runner::ACTIONS.key?(type)
          raise Invalid, "#{@id}: unsupported action #{type.inspect} " \
                         "(this build supports #{Runner::ACTIONS.keys.join(', ')})"
        end

        @action = {
          type: type,
          destination: action["destination"].to_s,
          max_rooms: action["max_rooms"]&.to_i,
          goal_name: action["goal_name"]&.to_s
        }
        if type == "navigate" && @action[:destination].empty?
          raise Invalid, "#{@id}: action.destination is required"
        end
        if type == "retrace" && @action[:destination].empty?
          raise Invalid, "#{@id}: action.destination is required " \
                         "(navigate out to this room, then retrace)"
        end
      end

      def load_limits!
        limits = @data["limits"] || {}
        raise Invalid, "#{@id}: limits must be a mapping" unless limits.is_a?(Hash)

        # `max_commands` is enforced, by the driver, and is the only real budget
        # here. `max_steps` / `max_replans` deliberately are NOT injected into
        # the Navigator: its own DEFAULT_MAX_REPLANS is part of what a scenario
        # exists to check, and a scenario that supplied the bound would still
        # pass after someone raised it. They are assertions instead.
        @max_commands = (limits["max_commands"] || 50).to_i
        @max_replans  = limits["max_replans"]&.to_i
      end

      def load_assertions!
        declared = @data["assertions"]
        raise Invalid, "#{@id}: assertions are required" unless declared.is_a?(Hash) && declared.any?

        unknown = declared.keys.map(&:to_s) - Assertions::NAMES
        if unknown.any?
          raise Invalid, "#{@id}: unknown assertion#{'s' if unknown.size > 1} #{unknown.inspect}. " \
                         "Known: #{Assertions::NAMES.join(', ')}"
        end

        @assertions = declared.transform_keys(&:to_s)
      end

      def load_scoring!
        scoring = @data["scoring"] || {}
        raise Invalid, "#{@id}: scoring must be a mapping" unless scoring.is_a?(Hash)

        # Named, not re-stated. The pasted design had `scoring.required` repeat
        # the expected values from the assertions block; two copies of one
        # expectation is two things to keep in sync, and the copy that drifts is
        # the one nobody reads.
        @required = Array(scoring["required"]).map(&:to_s)
        @recovery = Array(scoring["recovery"]).map(&:to_s)
        missing = (@required + @recovery) - @assertions.keys
        if missing.any?
          raise Invalid, "#{@id}: scoring names #{missing.inspect}, which the assertions block does not declare"
        end

        @expected_steps = scoring["expected_steps"]&.to_i
      end

      def load_transcript!
        driver = @data["driver"] || {}
        raise Invalid, "#{@id}: driver must be a mapping" unless driver.is_a?(Hash)

        type = (driver["type"] || "transcript").to_s
        raise Invalid, "#{@id}: unsupported driver #{type.inspect}" unless type == "transcript"

        @responses = driver["fixture"] ? load_fixture(driver["fixture"]) : stringify(driver["responses"] || {})
        raise Invalid, "#{@id}: driver has no responses" unless @responses.is_a?(Hash) && @responses.any?
      end

      def load_fixture(relative)
        base = @path ? File.dirname(@path) : Dir.pwd
        file = File.expand_path(relative.to_s, base)
        data = JSON.parse(File.read(file))
        raise Invalid, "#{@id}: #{relative} has no `responses` mapping" unless data["responses"].is_a?(Hash)

        data["responses"]
      rescue Errno::ENOENT
        raise Invalid, "#{@id}: transcript fixture not found: #{relative}"
      rescue JSON::ParserError => e
        raise Invalid, "#{@id}: malformed transcript fixture #{relative} — #{e.message}"
      end

      def required_field(key)
        value = @data[key].to_s
        raise Invalid, "#{@path}: #{key} is required" if value.empty?

        value
      end

      def stringify(value)
        case value
        when Hash  then value.to_h { |k, v| [ k.to_s, stringify(v) ] }
        when Array then value.map { |v| stringify(v) }
        else value
        end
      end
    end
  end
end
