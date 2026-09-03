# frozen_string_literal: true

module Bellhop
  class Error < StandardError; end

  class ConfigurationError < Error; end

  # An agent is not connected, or does not advertise what you asked it to do.
  class AgentError < Error
    attr_reader :agent

    def initialize(message, agent: nil)
      super(message)
      @agent = agent
    end
  end

  # A non-2xx from the licensing API, or an unreachable one. A retryable
  # failure during pairing leaves the claim token unconsumed, so the operator
  # can try the same link again.
  class LicensingError < Error
    attr_reader :code, :status, :body

    def initialize(code:, status:, message: nil, body: nil)
      @code   = code || "unknown_error"
      @status = status
      @body   = body
      super(message.presence || @code)
    end

    def retryable?
      status.zero? || status == 402 || status >= 500
    end

    # The agent shows this to whoever is at the printer when a claim fails.
    def operator_message
      case code
      when "payment_required"
        "This app's Bellhop plan needs attention. Ask an administrator, then try this link again."
      when "agent_deactivated"
        "This agent was removed. Ask for a new pairing link."
      when "agent_limit_reached"
        "This app has no agent slots left. Ask an administrator, then try this link again."
      when "unreachable"
        "Could not reach the licensing service. Check the connection and try this link again."
      else
        "Could not license this agent right now. Try this link again in a moment."
      end
    end
  end
end
