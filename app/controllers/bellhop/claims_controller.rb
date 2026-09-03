# frozen_string_literal: true

module Bellhop
  # Pairing. Runs once per agent, in front of a person at a printer, and is
  # the only unauthenticated route the engine owns. The exchange itself lives
  # in Bellhop::ClaimExchange; this is the HTTP shell around it.
  class ClaimsController < ActionController::API
    before_action :enforce_rate_limit

    def create
      if params[:claim_token].blank?
        return fail_with(:bad_request, "invalid_request", "That pairing link is missing its claim token.")
      end

      result = ClaimExchange.perform(params[:claim_token])

      render json: {
        # Appears in this response and nowhere else.
        agent_token:  result.agent_token,
        agent_name:   result.agent.label,
        app_name:     result.agent.app_name.presence || Bellhop.config.app_name || "Bellhop",
        accent_color: result.agent.accent_color.presence || Bellhop.config.accent_color,
        credential:   result.activation["credential"],
        transports:   transports
      }.compact
    rescue ClaimExchange::ExpiredClaim
      fail_with(:not_found, "claim_expired", "That pairing link has expired. Ask for a new one.")
    rescue LicensingError => e
      Bellhop.logger.warn { "[bellhop] activation failed (#{e.code}); the claim token stays valid" }
      fail_with(:bad_gateway, e.code, e.operator_message)
    end

    private
      # Where to connect, most preferred first. This is the hook for moving
      # the socket to another host; the credential does not care where it is.
      def transports
        list = []
        list << { type: "websocket", url: Bellhop.config.socket_url } if Bellhop.cable_available?
        list << { type: "http", url: Bellhop.config.http_url }
        list
      end

      # The agent shows `message` to whoever is at the printer.
      def fail_with(status, code, message)
        render status: status, json: { error: { code: code, message: message } }
      end

      def enforce_rate_limit
        limit = Bellhop.config.claim_rate_limit
        return if limit.blank?

        key = "bellhop:claim:#{request.remote_ip}"
        Rails.cache.write(key, 0, expires_in: 1.minute, unless_exist: true)
        count = Rails.cache.increment(key, 1) || 1
        return if count <= limit

        fail_with(:too_many_requests, "too_many_requests", "Too many pairing attempts. Wait a minute and try again.")
      end
  end
end
