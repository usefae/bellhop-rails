# frozen_string_literal: true

require "net/http"
require "json"

module Bellhop
  # The licensing API, server to server. The agent never takes part: it only
  # sees the `credential` string these calls return, stored and handed over
  # verbatim. Read entitlements from `app`, never by parsing the credential.
  class Licensing
    TIMEOUT = 15

    def initialize(secret_key: nil, api_url: nil, server_host: nil)
      @secret_key  = secret_key  || Bellhop.config.secret_key!
      @api_url     = (api_url    || Bellhop.config.api_url).chomp("/")
      @server_host = server_host || Bellhop.config.server_host
    end

    # Pass `idempotency_key` from anything that retries (a job, a form that can
    # be double-submitted) and a replayed request answers with the original
    # agent instead of creating a second one.
    def create_agent(label, idempotency_key: nil)
      request(:post, "/agents", body: { label: label }, headers: { "Idempotency-Key" => idempotency_key }.compact)
    end

    # Mint a credential. Called while handling a claim, before the claim token
    # is consumed.
    def activate(remote_id)
      request(:post, "/agents/#{remote_id}/activate", body: { server_host: @server_host })
    end

    def renew(remote_id)
      request(:post, "/agents/#{remote_id}/renew", body: { server_host: @server_host })
    end

    # Idempotent. Frees the plan's agent slot.
    def deactivate(remote_id)
      request(:post, "/agents/#{remote_id}/deactivate")
    end

    def agents
      request(:get, "/agents")
    end

    # Your plan and entitlements.
    def app
      request(:get, "/app")
    end

    # Public and unauthenticated: the keys that sign credentials and webhooks.
    def signing_keys
      uri = URI.parse("#{@api_url}/.well-known/bellhop-keys.json")
      response = perform(Net::HTTP::Get.new(uri), uri)
      JSON.parse(response.body)
    rescue StandardError => e
      raise LicensingError.new(code: "keys_unavailable", status: 0, message: e.message)
    end

    private
      def request(method, path, body: nil, headers: {})
        uri = URI.parse("#{@api_url}/api/v1#{path}")

        klass = method == :post ? Net::HTTP::Post : Net::HTTP::Get
        http_request = klass.new(uri)
        http_request["Authorization"] = "Bearer #{@secret_key}"
        http_request["Accept"]        = "application/json"
        headers.each { |name, value| http_request[name] = value }
        if body
          http_request["Content-Type"] = "application/json"
          http_request.body = body.to_json
        end

        response = perform(http_request, uri)
        payload  = parse(response)

        unless response.is_a?(Net::HTTPSuccess)
          raise LicensingError.new(
            code:    payload["error"],
            message: payload["message"],
            status:  response.code.to_i,
            body:    payload
          )
        end

        payload
      end

      def perform(http_request, uri)
        Net::HTTP.start(
          uri.host, uri.port,
          use_ssl:      uri.scheme == "https",
          open_timeout: TIMEOUT,
          read_timeout: TIMEOUT
        ) { |http| http.request(http_request) }
      rescue StandardError => e
        raise LicensingError.new(code: "unreachable", status: 0, message: e.message)
      end

      def parse(response)
        JSON.parse(response.body.to_s)
      rescue JSON::ParserError
        {}
      end
  end
end
