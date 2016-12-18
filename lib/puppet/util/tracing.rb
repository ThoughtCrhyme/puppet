require 'opentracing'
require 'puppet/util/tracing/noop_tracer'

module Puppet
  module Util
    module Tracing
      def self.tracer
        @tracer
      end

      def self.tracer=(tracer)
        OpenTracing.global_tracer = tracer
        @tracer = tracer
      end

      self.tracer = Puppet::Util::Tracing::NoopTracer.new if @tracer.nil?
    end
  end
end
