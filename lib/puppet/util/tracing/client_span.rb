require 'opentracing'

module Puppet::Util
  module Tracing
    class ClientSpan < OpenTracing::Span

      attr_accessor :operation_name
      attr_accessor :start_time
      attr_accessor :parent
      attr_reader :tracer
      attr_reader :context
      attr_reader :logs
      attr_reader :tags
      attr_reader :duration

      def initialize(tracer:, context:)
        @tracer = tracer
        @context = context

        @parent = nil
        @logs = []
        @tags = []
      end

      def set_tag(key, value)
        tags.push({:key => key, :value => value, :endpoint => tracer.endpoint})

        self
      end

      def set_baggage_item(key, value)
        # Not implementing baggage.
        self
      end

      def get_baggage_item(key, value)
        nil
      end

      def log(event: nil, timestamp: Time.now, **fields)
        # Fields are ignored.
        logs.push({:value => event,
                   :timestamp => (timestamp.utc.to_f * 1E6).truncate,
                   :endpoint => tracer.endpoint})

        self
      end

      def finish(end_time: Time.now)
        @duration = ((end_time.to_f - start_time.to_f) * 1E6).truncate

        tracer.finish_span(self)

        self
      end

      def to_h
        h = {
          :traceId => context[:trace_id].to_s(16),
          :name => operation_name,
          :id => context[:id].to_s(16),
          :timestamp => (start_time.utc.to_f * 1E6).truncate,
          :duration => @duration,
          :annotations => logs,
          :binaryAnnotations => tags
        }

        h[:parentId] = context[:parent_id].to_s(16) if context[:parent_id]

        h
      end
    end
  end
end
