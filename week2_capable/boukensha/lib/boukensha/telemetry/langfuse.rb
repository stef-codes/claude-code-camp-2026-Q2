require "json"
require "net/http"
require "uri"

module Boukensha
  module Telemetry
    # Langfuse scores — the one thing that cannot ride the OTLP exporter.
    #
    # Traces go out over OTLP because that is a standard the whole telemetry
    # layer already speaks. Scores do not exist in OpenTelemetry at all: they
    # are a Langfuse concept, posted to its own REST endpoint and attached to a
    # trace id after the fact. So this is a small, deliberate second channel,
    # and it is the only vendor-specific HTTP in the codebase.
    #
    # What a score is FOR here: turning an outcome the agent already computes
    # into a number that can be tracked, alerted on and gated against. The
    # navigator already returns `ok`/`reason`; the explorer already returns how
    # many rooms it added; Hooks already knows whether it can name the room it
    # is standing in. None of that was leaving the machine as anything but prose
    # in a log. As a score it becomes a series: "how often does navigation
    # arrive", "how often is position ambiguous after a turn".
    #
    # Three properties this must have, because it runs inside a live agent:
    #
    #   never blocks    scores queue in memory and go out in one pass at
    #                   `flush`, which the Logger calls on close. An agent turn
    #                   never waits on Langfuse.
    #   never raises    a scoring failure is not an agent failure. Everything
    #                   is rescued and warned once.
    #   never required  with no credentials it is simply disabled, exactly as
    #                   the OTLP exporter is. The agent does not know or care.
    class Langfuse
      SCORES_PATH = "/api/public/scores".freeze
      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 10

      Score = Struct.new(:trace_id, :observation_id, :name, :value, :data_type, :comment,
                         keyword_init: true)

      # Same environment the OTLP exporter is configured from, so there is one
      # place to put credentials and no second thing to keep in sync.
      def self.from_env(env = ENV, warning_io: $stderr)
        public_key = env["LANGFUSE_PUBLIC_KEY"]
        secret_key = env["LANGFUSE_SECRET_KEY"]
        base_url   = env["LANGFUSE_BASE_URL"]
        return nil if [public_key, secret_key, base_url].any? { |v| v.nil? || v.to_s.strip.empty? }

        new(base_url: base_url, public_key: public_key, secret_key: secret_key,
            warning_io: warning_io)
      end

      def initialize(base_url:, public_key:, secret_key:, warning_io: $stderr)
        @uri = URI.parse(base_url.to_s.chomp("/") + SCORES_PATH)
        # `pack("m0")` is strict base64 with no trailing newline — the same thing
        # Base64.strict_encode64 does, without requiring the base64 gem, which
        # stopped being a default gem in Ruby 3.4 and would be a whole new
        # dependency for one line.
        @auth = [ "#{public_key}:#{secret_key}" ].pack("m0")
        @warning_io = warning_io
        @queue = []
        @mutex = Mutex.new
      end

      def enabled? = true

      # Queued, not sent. `trace_id` may legitimately be nil when telemetry is
      # off or no span is open — a score with nothing to attach to is dropped
      # rather than posted somewhere it cannot be found.
      def score(trace_id:, name:, value:, data_type: "NUMERIC", comment: nil, observation_id: nil)
        return if trace_id.nil? || name.nil? || value.nil?

        @mutex.synchronize do
          @queue << Score.new(trace_id: trace_id, observation_id: observation_id, name: name.to_s,
                              value: value, data_type: data_type, comment: comment)
        end
        nil
      end

      def pending = @mutex.synchronize { @queue.dup }

      # One pass, at the end. Partial failure is fine: each score is independent,
      # so a rejected one does not cost the rest.
      def flush
        pending_scores = @mutex.synchronize { @queue.tap { @queue = [] } }
        return 0 if pending_scores.empty?

        sent = 0
        http = Net::HTTP.new(@uri.host, @uri.port)
        http.use_ssl = @uri.scheme == "https"
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = READ_TIMEOUT
        http.start do |session|
          pending_scores.each { |s| sent += 1 if post(session, s) }
        end
        sent
      rescue StandardError => e
        warn_once(e)
        0
      end

      private

      def post(session, score)
        request = Net::HTTP::Post.new(@uri.path)
        request["Authorization"] = "Basic #{@auth}"
        request["Content-Type"] = "application/json"
        request.body = JSON.generate({
          traceId: score.trace_id,
          observationId: score.observation_id,
          name: score.name,
          value: score.value,
          dataType: score.data_type,
          comment: score.comment
        }.compact)

        response = session.request(request)
        return true if response.code.to_i.between?(200, 299)

        warn_once(RuntimeError.new("score #{score.name} rejected: HTTP #{response.code} #{response.body.to_s[0, 200]}"))
        false
      rescue StandardError => e
        warn_once(e)
        false
      end

      def warn_once(error)
        return if @warned

        @warned = true
        @warning_io.puts("boukensha: Langfuse scoring failed: #{error.class}: #{error.message}")
      end
    end
  end
end
