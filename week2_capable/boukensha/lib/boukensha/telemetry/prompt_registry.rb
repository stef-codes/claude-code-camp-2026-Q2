require "json"
require "net/http"
require "uri"

module Boukensha
  module Telemetry
    # Prompts from Langfuse, with the file on disk as the floor.
    #
    # The point of central prompt management is that a prompt can be edited,
    # versioned and rolled back without a redeploy — and that a trace can say
    # WHICH version produced it, so a regression is attributable instead of
    # merely noticed.
    #
    # The cost is a network call on a path that previously touched only the
    # filesystem, and that trade is only acceptable if failure is invisible.
    # Three rules follow from that, and they are the whole design:
    #
    #   the file always wins ties   `fetch` returns nil on ANY failure — no
    #                               credentials, timeout, 404, malformed body —
    #                               and the caller falls back to the prompt it
    #                               shipped with. A Langfuse outage must not be
    #                               able to stop the agent from starting.
    #   one call per name           results are memoized for the process. The
    #                               prompt cannot change mid-session anyway, and
    #                               a per-turn fetch would put a network round
    #                               trip in front of every model call.
    #   fetching is opt-in          off unless `observability.prompts.enabled`
    #                               is set, so the default boot path stays
    #                               exactly as fast as it was.
    #
    # A miss is cached too. Without that, an agent whose prompt has not been
    # pushed to Langfuse would pay the timeout on every single lookup.
    class PromptRegistry
      OPEN_TIMEOUT = 2
      READ_TIMEOUT = 3

      Prompt = Struct.new(:name, :version, :text, :label, keyword_init: true)

      def self.from_env(env = ENV, enabled: false, warning_io: $stderr)
        return nil unless enabled

        public_key = env["LANGFUSE_PUBLIC_KEY"]
        secret_key = env["LANGFUSE_SECRET_KEY"]
        base_url   = env["LANGFUSE_BASE_URL"]
        return nil if [ public_key, secret_key, base_url ].any? { |v| v.nil? || v.to_s.strip.empty? }

        new(base_url: base_url, public_key: public_key, secret_key: secret_key,
            warning_io: warning_io)
      end

      def initialize(base_url:, public_key:, secret_key:, label: "production", warning_io: $stderr)
        @base_url = base_url.to_s.chomp("/")
        @auth = [ "#{public_key}:#{secret_key}" ].pack("m0")
        @label = label
        @warning_io = warning_io
        @cache = {}
        @mutex = Mutex.new
      end

      # Returns a Prompt, or nil — and nil is a perfectly ordinary answer meaning
      # "use the file".
      def fetch(name)
        @mutex.synchronize do
          return @cache[name] if @cache.key?(name)

          @cache[name] = request(name)
        end
      end

      private

      def request(name)
        uri = URI.parse("#{@base_url}/api/public/v2/prompts/#{URI.encode_www_form_component(name)}?label=#{@label}")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = READ_TIMEOUT

        req = Net::HTTP::Get.new(uri.request_uri)
        req["Authorization"] = "Basic #{@auth}"
        response = http.request(req)

        # 404 is the normal "this prompt only exists on disk" case and is not
        # worth a warning; anything else is worth saying once.
        return nil if response.code.to_i == 404
        unless response.code.to_i.between?(200, 299)
          warn_once(RuntimeError.new("prompt #{name}: HTTP #{response.code}"))
          return nil
        end

        body = JSON.parse(response.body)
        text = body["prompt"]
        # A chat-style prompt arrives as an array of messages; this agent wants a
        # single system string, so the parts are joined rather than guessed at.
        text = text.map { |m| m["content"] }.join("\n\n") if text.is_a?(Array)
        return nil if text.to_s.strip.empty?

        Prompt.new(name: body["name"] || name, version: body["version"], text: text,
                   label: @label)
      rescue StandardError => e
        warn_once(e)
        nil
      end

      def warn_once(error)
        return if @warned

        @warned = true
        @warning_io.puts("boukensha: Langfuse prompt fetch failed (#{error.message}) — using the prompt on disk")
      end
    end
  end
end
