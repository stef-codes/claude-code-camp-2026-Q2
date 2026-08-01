require "json"
require "net/http"
require "uri"

module Boukensha
  module Telemetry
    # Promote the runs that went wrong into a Langfuse dataset.
    #
    # The idea this implements: you accumulate an eval set for free just by
    # working normally. Every time the agent loses its position, fails to
    # localize, or plans a route it cannot walk, that turn is a regression case
    # worth keeping — and the session log already recorded it in full. Nothing
    # here asks the agent to do extra work; it reads what already happened.
    #
    # Why the SESSION LOG and not the Langfuse API: the jsonl is the record this
    # project owns, it is complete whether or not tracing was enabled, and it
    # holds the tool calls verbatim. Pulling traces back out of Langfuse to push
    # them into Langfuse would make the eval set depend on the thing being
    # evaluated.
    #
    # Selection is deliberately narrow. A dataset of everything is not a
    # dataset, it is a log — the value is that every item is a case somebody
    # would want to fix.
    class DatasetExport
      DEFAULT_DATASET = "boukensha-failures".freeze

      # Each rule answers "what went wrong", in the words the score already uses.
      # `score` events are written by Logger#score whether or not Langfuse is
      # configured, so this works on a machine that has never exported a trace.
      FAILURES = {
        "position.known"          => ->(v) { v.to_i.zero? },
        "localization.candidates" => ->(v) { v.to_i > 1 },
        "navigate.arrived"        => ->(v) { v.to_i.zero? },
        "explore.rooms_added"     => ->(v) { v.to_i.zero? }
      }.freeze

      Item = Struct.new(:session_id, :trace_id, :reason, :value, :comment, :input, :output,
                        keyword_init: true)

      # Pure: reads files, returns items, touches no network. Everything that
      # decides WHAT is worth keeping lives here so it can be tested and argued
      # with without credentials.
      def self.candidates(paths)
        Array(paths).flat_map { |path| from_session(path) }
      end

      def self.from_session(path)
        records = File.readlines(path).filter_map do |line|
          JSON.parse(line)
        rescue JSON::ParserError
          nil
        end

        # The turn's user instruction is the dataset item's input: an eval
        # replays "given this instruction, does the agent still fail?".
        #
        # It is NOT on the `turn` record — `Logger#turn` writes the turn NUMBER
        # and nothing else — so it is recovered from the `prompt` event's message
        # list. The state block is injected as a user message too, so those are
        # skipped: replaying "[here] The Bazaar (visit 5)…" as an instruction
        # would produce an eval case that tests nothing.
        last_turn = nil
        items = []
        records.each do |record|
          if record["phase"] == "prompt"
            spoken = Array(record["messages"]).select { |m| m["role"].to_s == "user" }
                                              .map { |m| m["content"].to_s }
                                              .reject { |c| c.start_with?("[here]") || c.strip.empty? }
            last_turn = spoken.last if spoken.any?
          end
          next unless record["phase"] == "score"

          rule = FAILURES[record["name"]]
          next unless rule&.call(record["value"])

          items << Item.new(
            session_id: record["session_id"], trace_id: record["trace_id"],
            reason: record["name"], value: record["value"], comment: record["comment"],
            input: last_turn, output: nil
          )
        end
        items
      rescue Errno::ENOENT
        []
      end

      def self.from_env(env = ENV, warning_io: $stderr)
        public_key = env["LANGFUSE_PUBLIC_KEY"]
        secret_key = env["LANGFUSE_SECRET_KEY"]
        base_url   = env["LANGFUSE_BASE_URL"]
        return nil if [ public_key, secret_key, base_url ].any? { |v| v.nil? || v.to_s.strip.empty? }

        new(base_url: base_url, public_key: public_key, secret_key: secret_key,
            warning_io: warning_io)
      end

      def initialize(base_url:, public_key:, secret_key:, warning_io: $stderr)
        @base_url = base_url.to_s.chomp("/")
        @auth = [ "#{public_key}:#{secret_key}" ].pack("m0")
        @warning_io = warning_io
      end

      # Creating a dataset that already exists is a no-op on Langfuse's side, so
      # this is safe to run repeatedly.
      def ensure_dataset(name, description: nil)
        post("/api/public/v2/datasets", { name: name, description: description }.compact)
      end

      def push(items, dataset: DEFAULT_DATASET)
        return 0 if items.empty?

        ensure_dataset(dataset, description: "Turns where the agent lost position, could not " \
                                             "localize, or failed to navigate or explore.")
        items.count do |item|
          post("/api/public/dataset-items", {
            datasetName: dataset,
            # `sourceTraceId` is what links the eval case back to the run it came
            # from, so a failing item is one click from the trace that produced it.
            sourceTraceId: item.trace_id,
            input: { instruction: item.input }.compact,
            metadata: { reason: item.reason, value: item.value, comment: item.comment,
                        session_id: item.session_id }.compact
          }.compact)
        end
      end

      private

      def post(path, body)
        uri = URI.parse(@base_url + path)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 5
        http.read_timeout = 10

        request = Net::HTTP::Post.new(uri.path)
        request["Authorization"] = "Basic #{@auth}"
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)

        response = http.request(request)
        return true if response.code.to_i.between?(200, 299)

        @warning_io.puts("boukensha: #{path} → HTTP #{response.code} #{response.body.to_s[0, 160]}")
        false
      rescue StandardError => e
        @warning_io.puts("boukensha: #{path} failed: #{e.class}: #{e.message}")
        false
      end
    end
  end
end
