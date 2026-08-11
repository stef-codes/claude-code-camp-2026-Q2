require "opentelemetry-api"
require "opentelemetry-sdk"
require "opentelemetry/exporter/otlp"
require "json"

module Boukensha
  module Telemetry
    class OpenTelemetry
      KIND = {
        internal: ::OpenTelemetry::Trace::SpanKind::INTERNAL,
        client: ::OpenTelemetry::Trace::SpanKind::CLIENT,
        server: ::OpenTelemetry::Trace::SpanKind::SERVER,
        producer: ::OpenTelemetry::Trace::SpanKind::PRODUCER,
        consumer: ::OpenTelemetry::Trace::SpanKind::CONSUMER
      }.freeze

      class Span
        def initialize(span)
          @span = span
        end

        def trace_id
          @span.context.hex_trace_id if @span.context.valid?
        end

        def span_id
          @span.context.hex_span_id if @span.context.valid?
        end

        def set_attributes(attributes)
          attributes.each { |key, value| @span.set_attribute(key.to_s, value) unless value.nil? }
        end

        def add_event(name, attributes: {})
          @span.add_event(name.to_s, attributes: attributes.compact.transform_keys(&:to_s))
        end

        def record_exception(exception)
          @span.record_exception(exception)
        end

        def error!(exception = nil)
          @span.set_attribute("error.type", exception.class.name) if exception
          @span.status = ::OpenTelemetry::Trace::Status.error(exception&.message)
        end
      end

      def initialize(capture_content: false, content_max_bytes: 4096, warning_io: $stderr)
        @capture_content = capture_content
        @content_max_bytes = content_max_bytes
        @warning_io = warning_io
        configure_once
        @tracer = ::OpenTelemetry.tracer_provider.tracer("boukensha", Boukensha::VERSION)
      end

      def in_span(name, kind: :internal, attributes: {}, root: false)
        parent = root ? ::OpenTelemetry::Context.empty : ::OpenTelemetry::Context.current
        span = @tracer.start_span(name.to_s, with_parent: parent, kind: KIND.fetch(kind),
                                  attributes: clean(attributes))
        context = ::OpenTelemetry::Trace.context_with_span(span, parent_context: parent)
        ::OpenTelemetry::Context.with_current(context) { yield Span.new(span) }
      ensure
        span&.finish
      end

      def current_ids
        context = ::OpenTelemetry::Trace.current_span.context
        return {} unless context.valid?

        { trace_id: context.hex_trace_id, span_id: context.hex_span_id }
      end

      def propagation_carrier
        carrier = {}
        ::OpenTelemetry.propagation.inject(carrier)
        carrier
      end

      # Which logged phase supplies a span's INPUT, and which key inside the
      # event carries it. `request` deliberately outranks `prompt`: both fire on
      # the same `chat` span and the later write wins, and `request` is the
      # payload that actually went to the provider.
      INPUT_PHASES = {
        "prompt"    => :messages,
        "request"   => :messages,
        "tool_call" => :args
      }.freeze

      OUTPUT_PHASES = {
        "plan"        => :text,   # the preamble that accompanies a tool call
        "response"    => :text,
        "tool_result" => :result
      }.freeze

      # Everything else worth keeping, as observation metadata rather than I/O.
      METADATA_PHASES = %w[injected_context context_transform].freeze

      # Content goes out as span ATTRIBUTES, not span events, and that is the
      # whole point of this method.
      #
      # It used to write `span.add_event("boukensha.<phase>", …)`, which is
      # perfectly good OpenTelemetry and completely invisible in Langfuse:
      # Langfuse reads `langfuse.observation.input` / `.output` off span
      # attributes and does not look at events at all. So every prompt, model
      # response, tool call and tool result was being exported to a place the
      # backend never reads, and the UI showed empty input/output panes on every
      # trace — verified against the public API before this change, and the
      # reason turning `capture_content` on appeared to do nothing.
      #
      # The attribute names are the documented Langfuse OTel mapping. `session.id`
      # (set in Logger#operation) is already a recognised alias for
      # `langfuse.session.id`, which is why session grouping worked all along.
      def capture_event(event)
        phase = (event[:phase] || event["phase"]).to_s
        span = ::OpenTelemetry::Trace.current_span
        return unless span.context.valid?

        # A marker, not content: it says a reasoning block existed without
        # shipping it, so it stays on regardless of capture_content.
        if phase == "reasoning"
          span.add_event("boukensha.reasoning", attributes: { "boukensha.reasoning.present" => true })
          return
        end
        return unless @capture_content

        if (key = INPUT_PHASES[phase])
          write_content(span, "langfuse.observation.input", event, key)
        elsif (key = OUTPUT_PHASES[phase])
          write_content(span, "langfuse.observation.output", event, key)
        elsif METADATA_PHASES.include?(phase)
          write_content(span, "langfuse.observation.metadata.#{phase}", event, nil)
        end
      rescue StandardError => e
        warn_once(e)
      end

      # Attach input/output to the span that is open RIGHT NOW, for callers that
      # know what a span consumed and produced at the moment it runs.
      #
      # `capture_event` cannot do this job for the LLM call. `logger.prompt` and
      # `logger.request` fire before `call_model` opens the `chat` span and
      # `logger.response` fires after it closes, so all three land on the
      # enclosing `iteration` — which left the generation itself, the one
      # observation carrying the model name and the token usage, with empty
      # input and output. Verified against the Langfuse API before this existed:
      # 32 observations, I/O on `iteration` and on every tool, none on `chat`.
      def capture_io(input: nil, output: nil)
        return unless @capture_content

        span = ::OpenTelemetry::Trace.current_span
        return unless span.context.valid?

        write_content(span, "langfuse.observation.input", { value: input }, :value) unless input.nil?
        write_content(span, "langfuse.observation.output", { value: output }, :value) unless output.nil?
      rescue StandardError => e
        warn_once(e)
      end

      def force_flush(timeout: nil)
        ::OpenTelemetry.tracer_provider.force_flush(timeout: timeout)
      rescue StandardError => e
        warn_once(e)
        false
      end

      def shutdown(timeout: nil)
        ::OpenTelemetry.tracer_provider.shutdown(timeout: timeout)
      rescue StandardError => e
        warn_once(e)
        false
      end

      private

      # `key` picks the interesting field out of the event; nil means "the whole
      # event". A plain String is written as-is so Langfuse renders prose as
      # prose, and anything structured is JSON — the shape its input/output
      # viewer expects. Redaction and the byte cap apply either way, because
      # this is the boundary where content leaves the machine.
      def write_content(span, attribute, event, key)
        value = key ? (event[key] || event[key.to_s]) : event
        return if value.nil?

        value = redact(value, key&.to_s)
        text  = value.is_a?(String) ? value : JSON.generate(value)
        if text.bytesize > @content_max_bytes
          text = text.byteslice(0, @content_max_bytes).scrub
          span.set_attribute("boukensha.content.truncated", true)
        end
        span.set_attribute(attribute, text)
      end

      def configure_once
        return if self.class.instance_variable_get(:@configured)

        ::OpenTelemetry::SDK.configure do |config|
          config.service_name = ENV.fetch("OTEL_SERVICE_NAME", "boukensha")
        end
        self.class.instance_variable_set(:@configured, true)
      end

      def clean(attributes)
        attributes.compact.transform_keys(&:to_s).select do |_key, value|
          value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false ||
            (value.is_a?(Array) && value.all? { |item| item.is_a?(String) || item.is_a?(Numeric) })
        end
      end

      SECRET_KEY = /(authorization|api[_-]?key|token|password|secret|credential)/i
      SECRET_VALUE = /(Bearer\s+)[^\s]+|\bsk-[A-Za-z0-9_-]{8,}/i

      def redact(value, key = nil)
        return "[REDACTED]" if key&.match?(SECRET_KEY)

        case value
        when Hash
          value.each_with_object({}) { |(child_key, child), out| out[child_key] = redact(child, child_key.to_s) }
        when Array
          value.map { |child| redact(child) }
        when String
          value.gsub(SECRET_VALUE) { |match| match.start_with?("Bearer ") ? "Bearer [REDACTED]" : "[REDACTED]" }
        else
          value
        end
      end

      def warn_once(error)
        return if @warned

        @warned = true
        @warning_io.puts("boukensha: OpenTelemetry export failed: #{error.class}: #{error.message}")
      end
    end
  end
end
