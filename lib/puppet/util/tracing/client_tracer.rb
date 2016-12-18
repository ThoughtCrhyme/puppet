require 'opentracing'
require 'puppet/util/tracing/client_span'

module Puppet::Util
  module Tracing
    class ClientTracer < OpenTracing::Tracer
      TRACE_ID_UPPER_BOUND = 2 ** 64

      attr_reader :trace_id
      attr_reader :current_span
      attr_reader :report
      attr_reader :endpoint

      def initialize(report)
        @report = report
        reset!
      end

      def reset!
        @current_span = nil
        @endpoint = {
          :serviceName => Puppet[:certname]
        }.freeze
        @trace_id = generate_id
      end

      # Start a new span
      # @param operation_name [String] The name of the operation represented by the span
      # @param child_of [Span] A span to be used as the ChildOf reference
      # @param start_time [Time] the start time of the span
      # @param tags [Hash] Starting tags for the span
      def start_span(operation_name, child_of: self.current_span, start_time: Time.now, tags: nil)
        context = {
          :trace_id => @trace_id,
          :id => generate_id,
          :sampling => 1
        }

        unless child_of.nil?
          context[:trace_id] = child_of.context[:trace_id]
          context[:parent_id] = child_of.context[:id]
          context[:sampling] = child_of.context[:sampling]
        end

        span = Puppet::Util::Tracing::ClientSpan.new(tracer: self, context: context)
        span.operation_name = operation_name
        span.start_time = start_time
        span.parent = child_of

        @current_span = span

        span
      end

      def inject(span_context, format, carrier)
        case format
        when OpenTracing::FORMAT_TEXT_MAP
          inject_http_headers!(span_context, carrier)
        else
          # Not implementing binary or other formats at this time.
          nil
        end
      end

      def extract(operation_name, format, carrier)
        OpenTracing::Span::NOOP_INSTANCE
      end

      def finish_span(span)
        # TODO: Log span to report.

        @current_span = span.parent
      end

      private

      def generate_id
        rand(TRACE_ID_UPPER_BOUND)
      end

      def inject_http_headers!(span_context, carrier)
        # TODO: Bail early if span_context is nil or contains no data.

        carrier['X-B3-TraceId'] = span_context[:trace_id].to_s(16)
        carrier['X-B3-SpanId'] = span_context[:id].to_s(16)

        carrier['X-B3-ParentSpanId'] = span_context[:parent_id].to_s(16) if span_context[:parent_id]
        carrier['X-B3-Sampled'] = span_context[:sampling].to_s if span_context[:sampling]

        carrier
      end
    end
  end
end
