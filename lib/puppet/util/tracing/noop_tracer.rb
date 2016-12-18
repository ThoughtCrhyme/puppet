require 'opentracing'

module Puppet::Util
  module Tracing
    class NoopTracer < OpenTracing::Tracer

      def inject(span_context, format, carrier)
        nil
      end

      def extract(operation_name, format, carrier)
        OpenTracing::Span::NOOP_INSTANCE
      end
    end
  end
end
