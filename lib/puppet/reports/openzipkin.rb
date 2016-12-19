require 'puppet'
require 'puppet/network/http_pool'
require 'uri'
require 'json'

Puppet::Reports.register_report(:openzipkin) do

  desc <<-DESC
    Simple report processor that uploads trace objects to an OpenZipkin server.
  DESC

  def process
    Puppet.info "Starting Zipkin reporter."
    return if self.traces.nil? or self.traces.empty?

    # FIXME: Temporary use of the reporturl setting from the http processor.
    url = URI.parse(Puppet[:reporturl])
    headers = { "Content-Type" => "application/json" }
    options = {}
    if url.user && url.password
      options[:basic_auth] = {
        :user => url.user,
        :password => url.password
      }
    end
    use_ssl = url.scheme == 'https'

    Puppet.info "Shipping #{self.traces.length} spans to: #{url}"
    conn = Puppet::Network::HttpPool.http_instance(url.host, url.port, use_ssl)
    response = conn.post(url.path, JSON.generate(self.traces), headers, options)

    unless response.kind_of?(Net::HTTPSuccess)
      Puppet.err "Unable to submit report to #{url.to_s} [#{response.code}] #{response.msg}"
    end
  end
end
