# frozen_string_literal: true

module KamalImageRetention
  class RegistryAPI
    ACCEPT = %w[application/vnd.oci.image.manifest.v1+json application/vnd.oci.image.index.v1+json
                application/vnd.docker.distribution.manifest.v2+json application/vnd.docker.distribution.manifest.list.v2+json].join(", ")

    def initialize(port)
      @http = Net::HTTP.new("127.0.0.1", port, nil)
      @http.open_timeout = 5
      @http.read_timeout = 45
    end

    def open
      attempts = 0
      begin
        @http.start
        request("")
      rescue IOError, SystemCallError, Net::HTTPBadResponse
        @http.finish if @http.started?
        raise if (attempts += 1) >= 30
        sleep 0.2
        retry
      end
      yield self
    ensure
      @http.finish if @http.started?
    end

    def request(path, method = "GET")
      response = @http.send_request(method, "/v2/#{path}", nil, "Accept" => ACCEPT)
      response.value
      response.body
    end

    def content(path, digest)
      body = request(path)
      raise "Unexpected digest for #{path}" unless "sha256:#{Digest::SHA256.hexdigest(body)}" == digest
      body
    end
  end
end
